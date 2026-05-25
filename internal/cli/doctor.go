package cli

import (
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

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
		exit := runDoctor(os.Stdout, m, detect.Default())
		os.Exit(exit)
		return nil // unreachable; os.Exit short-circuits
	},
}

func init() {
	rootCmd.AddCommand(doctorCmd)
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
		r := d.Probe(tool)
		switch classify(tool, r) {
		case classOK:
			minNote := ""
			if tool.MinVersion != "" {
				minNote = fmt.Sprintf("  (manifest min: %s)", tool.MinVersion)
			}
			fmt.Fprintf(w, "  ✓ %s\t%s%s\n", tool.ID, r.Version, minNote)
			okCount++
		case classDrift:
			fmt.Fprintf(w, "  ✗ %s\t%s  (manifest min: %s)   → install %s\n",
				tool.ID, displayVersion(r), tool.MinVersion, tool.ID)
			driftCount++
		case classMissingOptional:
			fmt.Fprintf(w, "  ⚠ %s\tnot found                       → optional\n", tool.ID)
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

// classification is the result of evaluating one tool's Result against
// its manifest entry: OK, drift (required tool missing or below min),
// or missing-optional (optional tool absent or below min).
type classification int

const (
	classOK classification = iota
	classDrift
	classMissingOptional
)

func classify(t manifest.Tool, r detect.Result) classification {
	// Not on PATH (or winget fallback didn't find it).
	if !r.Found {
		if t.Optional {
			return classMissingOptional
		}
		return classDrift
	}
	// Found, but below min_version → drift (required) or warning (optional).
	if t.MinVersion != "" {
		ok, err := detect.VersionAtLeast(r.Version, t.MinVersion)
		if err != nil || !ok {
			if t.Optional {
				return classMissingOptional
			}
			return classDrift
		}
	}
	return classOK
}

// displayVersion returns "not found" if no version was parsed, else the version.
func displayVersion(r detect.Result) string {
	if r.Version == "" {
		return "not found"
	}
	return r.Version
}
