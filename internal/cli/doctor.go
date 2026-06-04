package cli

import (
	"fmt"
	"io"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/selftest"
)

var (
	doctorDeep bool
	doctorFull bool
)

// Output glyphs. Default to UTF-8 (✓/✗/⚠). If $CA_BOOTSTRAP_ASCII is
// set (e.g. on a Windows console with an unusual code page), fall back
// to ASCII so the output remains readable.
var (
	glyphOK   = "✓"
	glyphFail = "✗"
	glyphWarn = "⚠"
)

func init() {
	if os.Getenv("CA_BOOTSTRAP_ASCII") != "" {
		glyphOK, glyphFail, glyphWarn = "[ok]", "[FAIL]", "[warn]"
	}
}

// doctorCmd diagnoses installed tooling against the (embedded or
// env-var-overridden) manifest. Read-only — never writes anywhere.
// Exit codes per spec §6.3:
//
//	0 - all required tools present and at min version (clean)
//	1 - system error (manifest missing/parse/probe-failure)
//	2 - drift found (one or more required tools missing or below min)
var doctorCmd = &cobra.Command{
	Use:   "doctor",
	Short: "Diagnose installed tooling against the manifest (read-only)",
	RunE: func(cmd *cobra.Command, args []string) error {
		m, err := manifest.LoadDefault()
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		det := detect.Default()
		exit := runDoctor(os.Stdout, m, det)
		// --full implies --deep.
		if doctorDeep || doctorFull {
			if runSelfTest(os.Stdout, m, det) {
				exit = 2 // a failed capability probe is drift-equivalent
			}
		}
		os.Exit(exit)
		return nil // unreachable; os.Exit short-circuits
	},
}

func init() {
	doctorCmd.Flags().BoolVar(&doctorDeep, "deep", false, "also run capability self-test probes (workspace write, link, package manager, gh auth)")
	doctorCmd.Flags().BoolVar(&doctorFull, "full", false, "with --deep, also run a real install→uninstall round-trip on a probe tool (invasive)")
	rootCmd.AddCommand(doctorCmd)
}

// runSelfTest runs the capability probes and prints them. Returns true if any
// probe hard-failed (skips don't count). Drives selftest with a real prompter
// and the live manifest/detector (the --full round-trip needs them).
func runSelfTest(w io.Writer, m *manifest.Manifest, d detect.Detector) bool {
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Capability self-test:")
	results := selftest.Run(selftest.Options{
		Full:     doctorFull,
		Manifest: m,
		Detector: d,
		Out:      w,
		Prompter: prompt.New(),
	})
	for _, r := range results {
		glyph := glyphOK
		switch r.Status {
		case selftest.StatusFail:
			glyph = glyphFail
		case selftest.StatusSkip:
			glyph = glyphWarn
		}
		fmt.Fprintf(w, "  %s %s\t%s\n", glyph, r.Name, r.Detail)
	}
	return selftest.AnyFailed(results)
}

// runDoctor probes every tool in the manifest, prints a report to w,
// and returns the exit code per spec §6.3.
//
// Pure function in the sense that it takes the manifest + Detector as
// parameters: doctor_test.go drives it with a stub Detector and a
// bytes.Buffer to assert on the output without spawning any processes.
func runDoctor(w io.Writer, m *manifest.Manifest, d detect.Detector) int {
	fmt.Fprintln(w, "Checking installed tooling against manifest/tools.yaml...")
	fmt.Fprintln(w)

	var okCount, driftCount, missingOptionalCount int
	for _, tool := range m.Tools {
		r := probeWithSpinner(w, tool.ID, func() detect.Result { return d.Probe(tool) })
		switch detect.Classify(tool, r) {
		case detect.ClassOK:
			minNote := ""
			if tool.MinVersion != "" {
				minNote = fmt.Sprintf("  (manifest min: %s)", tool.MinVersion)
			}
			fmt.Fprintf(w, "  %s %s\t%s%s\n", glyphOK, tool.ID, r.Version, minNote)
			okCount++
		case detect.ClassDrift:
			fmt.Fprintf(w, "  %s %s\t%s  (manifest min: %s)   → install %s\n",
				glyphFail, tool.ID, displayVersion(r), tool.MinVersion, tool.ID)
			driftCount++
		case detect.ClassMissingOptional:
			fmt.Fprintf(w, "  %s %s\tnot found                       → optional\n", glyphWarn, tool.ID)
			missingOptionalCount++
		}
	}
	fmt.Fprintln(w)
	fmt.Fprintf(w, "%d tools checked: %d ok, %d drift, %d missing-optional\n",
		len(m.Tools), okCount, driftCount, missingOptionalCount)
	if driftCount > 0 {
		return 2
	}
	return 0
}

// probeWithSpinner runs probe(), showing a transient in-place spinner
// labelled with the tool id while it runs — so a slow probe (e.g. az,
// or a winget fallback) reads as "working", not "hung". The spinner is
// drawn only when w is an interactive terminal; when output is piped or
// redirected (CI, the smoke script's capture) probe() runs silently and
// only the result line is emitted, keeping captured output clean.
//
// Overwrite uses a carriage return + space padding (no ANSI escapes) so
// it works on every Windows console, not just VT-capable ones.
func probeWithSpinner(w io.Writer, label string, probe func() detect.Result) detect.Result {
	if !isTerminal(w) {
		return probe()
	}
	frames := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	if os.Getenv("CA_BOOTSTRAP_ASCII") != "" {
		frames = []string{"-", "\\", "|", "/"}
	}
	done := make(chan detect.Result, 1)
	go func() { done <- probe() }()
	for i := 0; ; i++ {
		select {
		case r := <-done:
			fmt.Fprintf(w, "\r%-44s\r", "") // clear the spinner line
			return r
		case <-time.After(90 * time.Millisecond):
			fmt.Fprintf(w, "\r  %s %s  probing…", frames[i%len(frames)], label)
		}
	}
}

// isTerminal reports whether w is an interactive character device
// (a real console), so progress animation is suppressed when output is
// a pipe or file. A non-*os.File writer (e.g. the test bytes.Buffer)
// is treated as non-interactive.
func isTerminal(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

// displayVersion returns "not found" if no version was parsed, else the version.
func displayVersion(r detect.Result) string {
	if r.Version == "" {
		return "not found"
	}
	return r.Version
}
