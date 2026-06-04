package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/install"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/lock"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/provision"
)

var (
	repairTarget      string
	repairAll         bool
	repairUnattended  bool
	repairConfig      string
	repairForceUnlock bool
)

var repairCmd = &cobra.Command{
	Use:   "repair",
	Short: "Install missing tools (all required by default; --all adds optional; --target <id> for one)",
	RunE: func(cmd *cobra.Command, args []string) error {
		os.Exit(runRepair())
		return nil // unreachable
	},
}

func init() {
	repairCmd.Flags().StringVar(&repairTarget, "target", "", "install just this tool id (default: all missing required tools)")
	repairCmd.Flags().BoolVar(&repairAll, "all", false, "also install missing optional tools (not just required)")
	repairCmd.Flags().BoolVar(&repairUnattended, "unattended", false, "run without interactive prompts; requires --config")
	repairCmd.Flags().StringVar(&repairConfig, "config", "", "YAML answer file (for --unattended)")
	repairCmd.Flags().BoolVar(&repairForceUnlock, "ForceUnlock", false, "break a stale session lock before acquiring")
	rootCmd.AddCommand(repairCmd)
}

// runRepair implements `repair`. With no --target it installs every missing
// required tool (and optional ones too under --all); with --target <id> it
// installs that one tool. Returns the exit code per spec §5.4 (0 ok / 1 system
// error / 2 install-failed-or-skipped / 130 elevation declined).
func runRepair() int {
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: resolve home:", err)
		return 1
	}
	caDir := filepath.Join(home, ".ca-bootstrap")
	if err := os.MkdirAll(caDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "error: mkdir ~/.ca-bootstrap:", err)
		return 1
	}

	// Session lock (spec §6).
	lk := lock.New(filepath.Join(caDir, "session.lock"))
	if repairForceUnlock {
		err = lk.AcquireWithForce()
	} else {
		err = lk.Acquire()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	defer lk.Release()

	m, err := manifest.LoadDefault()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}

	// Prompter (shared by both paths).
	var prompter prompt.Prompter
	if repairUnattended {
		if repairConfig == "" {
			fmt.Fprintln(os.Stderr, "error: --unattended requires --config")
			return 1
		}
		p, perr := prompt.FromYAML(repairConfig)
		if perr != nil {
			fmt.Fprintln(os.Stderr, "error: load config:", perr)
			return 1
		}
		prompter = p
	} else {
		prompter = prompt.New()
	}

	sess, err := journal.NewSession()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: open journal:", err)
		return 1
	}
	exit := 0
	defer func() { _ = sess.End(exit) }()

	opts := install.Options{Out: os.Stdout, Prompter: prompter}
	if repairUnattended {
		if action, lerr := prompter.Line("repair.elevation_action", ""); lerr == nil {
			opts.ElevationAction = action
		}
	}

	det := detect.Default()
	if repairTarget != "" {
		exit = repairOne(m, det, sess, opts)
	} else {
		exit = repairMissing(m, det, sess, opts)
	}
	return exit
}

// repairMissing installs every missing required tool (and optional ones under
// --all) through the shared provision orchestrator.
func repairMissing(m *manifest.Manifest, det detect.Detector, sess *journal.Session, opts install.Options) int {
	missing := provision.Missing(m, det, repairAll)
	if len(missing) == 0 {
		scope := "required"
		if repairAll {
			scope = "required and optional"
		}
		fmt.Printf("%s All %s tools are present; nothing to repair.\n", glyphOK, scope)
		return 0
	}
	s, err := provision.InstallMissing(missing, det, sess, opts, "repair.install_missing")
	if err != nil {
		if errors.Is(err, prompt.ErrQuit) {
			fmt.Println("  (quit)")
			return 130
		}
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	switch {
	case s.Declined:
		return 130
	case len(s.Failed) > 0 || len(s.Skipped) > 0:
		return 2
	default:
		return 0
	}
}

// repairOne installs a single tool by id (the --target path).
func repairOne(m *manifest.Manifest, det detect.Detector, sess *journal.Session, opts install.Options) int {
	tool, ok := findTool(m, repairTarget)
	if !ok {
		fmt.Fprintf(os.Stderr, "error: target %q not found in manifest\n", repairTarget)
		return 1
	}

	// Already installed? (no-op)
	if detect.Classify(tool, det.Probe(tool)) == detect.ClassOK {
		fmt.Printf("%s %s already installed; nothing to do.\n", glyphOK, tool.ID)
		return 0
	}

	fmt.Printf("\nInstalling %s...\n", tool.ID)
	_ = sess.Append(journal.Entry{Action: "install_attempt", Target: tool.ID, Result: "start"})

	res := install.Default().Install(tool, opts)
	switch res.Status {
	case install.Installed:
		// Post-install verification (spec §5.1).
		if detect.Classify(tool, det.Probe(tool)) == detect.ClassOK {
			// alpha.4 spec §7.2: include after.method + after.package_id
			// so undo's tool reverser can dispatch the matching uninstall.
			_ = sess.Append(journal.Entry{
				Action: "install_success",
				Target: tool.ID,
				After:  map[string]string{"method": res.Method, "package_id": res.PackageID},
				Result: "ok",
			})
			fmt.Printf("%s %s installed.\n", glyphOK, tool.ID)
			return 0
		}
		_ = sess.Append(journal.Entry{Action: "install_failed", Target: tool.ID, Result: "verify_failed"})
		fmt.Printf("%s %s install ran but verification still shows drift.\n", glyphFail, tool.ID)
		return 2
	case install.Failed:
		_ = sess.Append(journal.Entry{Action: "install_failed", Target: tool.ID, Result: "error"})
		fmt.Printf("%s %s install failed: %v\n", glyphFail, tool.ID, res.Err)
		return 2
	case install.Declined:
		_ = sess.Append(journal.Entry{Action: "install_skipped", Target: tool.ID, Result: "elevation_declined"})
		fmt.Println("  (elevation declined — quitting)")
		return 130
	case install.Skipped:
		_ = sess.Append(journal.Entry{Action: "manual_install_required", Target: tool.ID, Result: "skipped"})
		fmt.Printf("\nrepair complete (manual steps needed):\n  - %s: %s\n", tool.ID, res.ManualCmd)
		return 2
	case install.NotApplicable:
		fmt.Fprintf(os.Stderr, "error: no install target for %s on this platform\n", tool.ID)
		return 1
	}
	return 0
}

func findTool(m *manifest.Manifest, id string) (manifest.Tool, bool) {
	for _, t := range m.Tools {
		if t.ID == id {
			return t, true
		}
	}
	return manifest.Tool{}, false
}
