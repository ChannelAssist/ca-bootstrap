package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard/steps"
)

var (
	setupUnattended bool
	setupConfig     string
)

var setupCmd = &cobra.Command{
	Use:   "setup",
	Short: "Interactive setup wizard: welcome + prereqs check + git identity",
	RunE: func(cmd *cobra.Command, args []string) error {
		exit := runSetup()
		os.Exit(exit)
		return nil // unreachable
	},
}

func init() {
	setupCmd.Flags().BoolVar(&setupUnattended, "unattended", false, "run without interactive prompts; requires --config")
	setupCmd.Flags().StringVar(&setupConfig, "config", "", "path to a YAML answer file (required when --unattended)")
	rootCmd.AddCommand(setupCmd)
}

// runSetup is the testable entry. Returns the exit code per spec §5.3.
func runSetup() int {
	// Build the Prompter — unattended (YAML-backed) or stdin.
	var prompter prompt.Prompter
	if setupUnattended {
		if setupConfig == "" {
			fmt.Fprintln(os.Stderr, "error: --unattended requires --config <path>")
			return 1
		}
		p, err := prompt.FromYAML(setupConfig)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error: load config:", err)
			return 1
		}
		prompter = p
	} else {
		prompter = prompt.New()
	}

	// Open the journal session.
	sess, err := journal.NewSession()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: open journal:", err)
		return 1
	}

	// Build the wizard Context. For unattended mode, pre-resolve the
	// workspace from identity.workspace_root so the identity step
	// doesn't need to prompt for it (the prompter would return the
	// YAML value either way, but pre-fetching keeps the Run path
	// uniform between interactive and unattended).
	ctx := &wizard.Context{
		Out:     os.Stdout,
		Prompt:  prompter,
		Session: sess,
	}
	if setupUnattended {
		if ws, err := prompter.Line("identity.workspace_root", ""); err == nil && ws != "" {
			ctx.Workspace = ws
		}
	}

	// Banner.
	fmt.Fprintln(os.Stdout, "ca-bootstrap — preparing your environment")

	stepList := []wizard.Step{
		steps.Welcome{},
		steps.Prereqs{},
		steps.GhAuth{},
		steps.Identity{},
		steps.Folders{},
		steps.Repos{},
		steps.Extras{},
	}
	exit := wizard.Run(stepList, ctx)
	_ = sess.End(exit)

	if exit == 0 {
		fmt.Fprintln(os.Stdout, "\nca-bootstrap setup complete.")
		fmt.Fprintln(os.Stdout, "Next: `ca-bootstrap repair` (alpha.3) to install missing tools.")
	}
	return exit
}
