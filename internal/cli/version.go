package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

// versionCmd prints the build-time-injected version, commit, and build
// timestamp per spec §5. Exits 0 always.
var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print version, commit, and build time, then exit",
	RunE: func(cmd *cobra.Command, args []string) error {
		fmt.Printf("ca-bootstrap %s (commit %s, built %s)\n", version, commit, buildTime)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
