// Package cli wires the cobra root command and shared state for ca-bootstrap.
//
// Subcommands are added via init() functions in their own files
// (version.go, doctor.go, ...) so each is self-contained.
package cli

import (
	"github.com/spf13/cobra"
)

// Package-level build info — set by main.SetBuildInfo at program start.
// Subcommands like `version` read these.
var (
	version   = "dev"
	commit    = "unknown"
	buildTime = "unknown"
)

// SetBuildInfo is called from main() with ldflag-injected build metadata.
// Keeping this as a setter (vs exported vars) means main owns the
// injection contract; cli/ never imports main.
func SetBuildInfo(v, c, t string) {
	version = v
	commit = c
	buildTime = t
}

var rootCmd = &cobra.Command{
	Use:   "ca-bootstrap",
	Short: "ChannelAssist developer bootstrap",
	Long: `ca-bootstrap takes a fresh laptop to a working ChannelAssist
development environment.

v2.0.0-alpha.1 implements:
  ca-bootstrap version    Print version, commit, build time
  ca-bootstrap doctor     Diagnose installed tooling (read-only)

Future alphas add setup (alpha.2), repair (alpha.3), undo (alpha.4),
and self-update (beta.1). See docs/specs/2026-05-25-go-rewrite-pivot.md.`,
}

// Execute runs the cobra dispatcher. Returns non-nil if a subcommand
// signalled an exit-1-class error; subcommands handle their own
// exit-2 (drift) paths via os.Exit directly per spec §6.3.
func Execute() error {
	return rootCmd.Execute()
}
