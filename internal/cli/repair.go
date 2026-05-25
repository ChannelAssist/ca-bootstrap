package cli

import (
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
)

var (
	repairTarget      string
	repairUnattended  bool
	repairConfig      string
	repairForceUnlock bool
)

var repairCmd = &cobra.Command{
	Use:   "repair",
	Short: "Install a missing tool by id (read manifest install block)",
	RunE: func(cmd *cobra.Command, args []string) error {
		os.Exit(runRepair())
		return nil // unreachable
	},
}

func init() {
	repairCmd.Flags().StringVar(&repairTarget, "target", "", "tool id to install (required)")
	repairCmd.Flags().BoolVar(&repairUnattended, "unattended", false, "run without interactive prompts; requires --config")
	repairCmd.Flags().StringVar(&repairConfig, "config", "", "YAML answer file (for --unattended)")
	repairCmd.Flags().BoolVar(&repairForceUnlock, "ForceUnlock", false, "break a stale session lock before acquiring")
	rootCmd.AddCommand(repairCmd)
}

// runRepair implements `repair --target`. Returns the exit code per
// spec §5.4 (0 ok / 1 system error / 2 install-failed-or-skipped /
// 130 elevation declined).
func runRepair() int {
	if repairTarget == "" {
		fmt.Fprintln(os.Stderr, "error: --target <tool-id> is required")
		return 1
	}

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

	// Load manifest, find target.
	m, err := manifest.LoadDefault()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	tool, ok := findTool(m, repairTarget)
	if !ok {
		fmt.Fprintf(os.Stderr, "error: target %q not found in manifest\n", repairTarget)
		return 1
	}

	// Already installed? (no-op)
	det := detect.Default()
	if detect.Classify(tool, det.Probe(tool)) == detect.ClassOK {
		fmt.Printf("%s %s already installed; nothing to do.\n", glyphOK, tool.ID)
		return 0
	}

	// Prompter + elevation action.
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

	fmt.Printf("\nInstalling %s...\n", tool.ID)
	_ = sess.Append(journal.Entry{Action: "install_attempt", Target: tool.ID, Result: "start"})

	res := install.Default().Install(tool, opts)
	switch res.Status {
	case install.Installed:
		// Post-install verification (spec §5.1).
		if detect.Classify(tool, det.Probe(tool)) == detect.ClassOK {
			_ = sess.Append(journal.Entry{Action: "install_success", Target: tool.ID, Result: "ok"})
			fmt.Printf("%s %s installed.\n", glyphOK, tool.ID)
			exit = 0
		} else {
			_ = sess.Append(journal.Entry{Action: "install_failed", Target: tool.ID, Result: "verify_failed"})
			fmt.Printf("%s %s install ran but verification still shows drift.\n", glyphFail, tool.ID)
			exit = 2
		}
	case install.Failed:
		_ = sess.Append(journal.Entry{Action: "install_failed", Target: tool.ID, Result: "error"})
		fmt.Printf("%s %s install failed: %v\n", glyphFail, tool.ID, res.Err)
		exit = 2
	case install.Declined:
		_ = sess.Append(journal.Entry{Action: "install_skipped", Target: tool.ID, Result: "elevation_declined"})
		fmt.Println("  (elevation declined — quitting)")
		exit = 130
	case install.Skipped:
		_ = sess.Append(journal.Entry{Action: "manual_install_required", Target: tool.ID, Result: "skipped"})
		fmt.Printf("\nrepair complete (manual steps needed):\n  - %s: %s\n", tool.ID, res.ManualCmd)
		exit = 2
	case install.NotApplicable:
		fmt.Fprintf(os.Stderr, "error: no install target for %s on this platform\n", tool.ID)
		exit = 1
	}
	return exit
}

func findTool(m *manifest.Manifest, id string) (manifest.Tool, bool) {
	for _, t := range m.Tools {
		if t.ID == id {
			return t, true
		}
	}
	return manifest.Tool{}, false
}
