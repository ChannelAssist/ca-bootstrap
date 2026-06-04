package detect

import (
	"strings"
	"testing"
)

// TestWingetListArgs_NonInteractive guards the fresh-Windows hang fix:
// the winget presence probe MUST pass the source-agreement + no-interactivity
// flags, or a first-run winget call blocks on an interactive prompt and
// hangs doctor. Pure function — runs on any OS.
func TestWingetListArgs_NonInteractive(t *testing.T) {
	args := wingetListArgs("Git.Git")
	joined := strings.Join(args, " ")
	for _, want := range []string{
		"list", "--id", "Git.Git", "--exact",
		"--accept-source-agreements", "--disable-interactivity",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("wingetListArgs missing %q; got %v", want, args)
		}
	}
}
