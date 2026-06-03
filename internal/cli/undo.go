package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/lock"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo/reversers"
)

var (
	undoTarget         string
	undoIncludeTools   bool
	undoIncludeFolders bool
	undoForce          bool
	undoForceUnlock    bool
	undoUnattended     bool
	undoConfig         string
)

var undoCmd = &cobra.Command{
	Use:   "undo",
	Short: "Reverse changes recorded in the action journal",
	RunE: func(cmd *cobra.Command, args []string) error {
		os.Exit(runUndo())
		return nil // unreachable
	},
}

func init() {
	undoCmd.Flags().StringVar(&undoTarget, "target", "",
		"scope: identity | tools | tool:<id>")
	undoCmd.Flags().BoolVar(&undoIncludeTools, "include-tools", false,
		"include install_success entries (uninstall the tool)")
	undoCmd.Flags().BoolVar(&undoIncludeFolders, "include-folders", false,
		"allow CreateFolder reverser to remove non-empty folders (matches PS-era)")
	undoCmd.Flags().BoolVar(&undoForce, "force", false,
		"required for --unattended; also skips the up-front confirm interactively")
	undoCmd.Flags().BoolVar(&undoForceUnlock, "ForceUnlock", false,
		"break a stale session lock before acquiring")
	undoCmd.Flags().BoolVar(&undoUnattended, "unattended", false,
		"run without interactive prompts; requires --config and --force")
	undoCmd.Flags().StringVar(&undoConfig, "config", "",
		"YAML answer file (for --unattended)")
	rootCmd.AddCommand(undoCmd)
}

// runUndo implements `undo`. Returns the exit code per spec §5.5.
func runUndo() int {
	// Unattended without --force is a hard error (spec §2.B.4).
	if undoUnattended && !undoForce {
		fmt.Fprintln(os.Stderr, "error: --force is required to undo non-interactively (refusing to reverse changes without explicit confirmation)")
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
	journalPath := filepath.Join(caDir, "journal.ndjson")

	// Session lock — spec §5.6.
	lk := lock.New(filepath.Join(caDir, "session.lock"))
	if undoForceUnlock {
		err = lk.AcquireWithForce()
	} else {
		err = lk.Acquire()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: session lock held:", err)
		return 1
	}
	defer lk.Release()

	// Build the prompter (interactive or YAML-backed).
	var prompter prompt.Prompter
	if undoUnattended {
		if undoConfig == "" {
			fmt.Fprintln(os.Stderr, "error: --unattended requires --config")
			return 1
		}
		p, perr := prompt.FromYAML(undoConfig)
		if perr != nil {
			fmt.Fprintln(os.Stderr, "error: load config:", perr)
			return 1
		}
		prompter = p
	} else {
		prompter = prompt.New()
	}

	fmt.Println("ca-bootstrap undo")

	// Open a journal session for writing entry_undone markers.
	// undo.Run handles the up-front "proceed?" prompt internally
	// (spec §5.1) so the "Reversible actions found" listing happens
	// first.
	sess, err := journal.NewSession()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: open journal:", err)
		return 1
	}
	exit := 0
	defer func() { _ = sess.End(exit) }()

	opts := undo.Options{
		Out:            os.Stdout,
		Prompter:       prompter,
		IncludeTools:   undoIncludeTools,
		IncludeFolders: undoIncludeFolders,
		Force:          undoForce,
		Target:         undoTarget,
	}
	dispatch := map[string]undo.Reverser{
		"identity_set":        reversers.Identity{},
		"install_success":     reversers.ToolInstall{},
		"gh_auth_login":       reversers.GhAuthLogin{},
		"clone_repo":          reversers.CloneRepo{},
		"create_folder":       reversers.CreateFolder{},
		"rename_folder":       reversers.RenameFolder{},
		"remove_empty_folder": reversers.RemoveEmptyFolder{},
		"seed_readme":         reversers.SeedReadme{},
	}

	summary, runErr := undo.Run(journalPath, sess, opts, dispatch)
	if errors.Is(runErr, undo.ErrUserQuit) {
		exit = 130
		return exit
	}
	if errors.Is(runErr, undo.ErrUserDeclined) {
		// User said no at the up-front prompt — clean exit.
		exit = 0
		return exit
	}
	if runErr != nil {
		fmt.Fprintln(os.Stderr, "error:", runErr)
		exit = 1
		return exit
	}

	// Audit snapshot — spec §6.3. Failure is warn, not fail.
	snapshotPath := journalPath + ".undone-" + time.Now().UTC().Format("2006-01-02T15-04-05Z")
	if err := copyFile(journalPath, snapshotPath); err != nil {
		fmt.Printf("  ⚠ audit snapshot failed: %v (continuing — primary journal already recorded the reversals)\n", err)
	} else {
		fmt.Printf("\n  Journal snapshot: %s\n", snapshotPath)
	}

	// Final summary.
	switch {
	case summary.Failed > 0:
		fmt.Printf("\n  ✗ %d reversed, %d skipped, %d failed\n",
			summary.Reversed, summary.Skipped, summary.Failed)
		for _, f := range summary.Failures {
			fmt.Println("    •", f)
		}
	default:
		fmt.Printf("\n  ✓ %d reversed, %d skipped\n", summary.Reversed, summary.Skipped)
	}

	exit = summary.ExitCode()
	return exit
}

// copyFile is a small helper for the audit snapshot. Keeping it local
// avoids pulling in io/ioutil or a shared util package for one call.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return nil
}
