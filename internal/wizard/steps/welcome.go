// Package steps implements the three alpha.2 wizard steps:
// welcome (consent), prereqs (uses detect+manifest), identity
// (writes per-folder git config).
package steps

import (
	"fmt"

	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// Welcome is wizard step 1 — banner + Y/n consent.
type Welcome struct{}

func (Welcome) Title() string { return "Welcome" }

func (Welcome) Run(ctx *wizard.Context) (string, error) {
	fmt.Fprintln(ctx.Out, "")
	fmt.Fprintln(ctx.Out, "  Welcome to the ChannelAssist developer setup wizard.")
	fmt.Fprintln(ctx.Out, "  This will check installed tooling, configure your git")
	fmt.Fprintln(ctx.Out, "  identity for ChannelAssist repos, and (in a future")
	fmt.Fprintln(ctx.Out, "  release) clone the repos you need. Every step is")
	fmt.Fprintln(ctx.Out, "  optional. Quit any time with 'q'.")
	fmt.Fprintln(ctx.Out, "")
	// NOTE: prompt key is "welcome.consent" — this is what the unattended
	// YAML config looks up. The stdin Prompter prints it as-is; UX
	// compromise for alpha.2 (better to show key paths than to risk
	// drift between display text and YAML key path).
	ok, err := ctx.Prompt.YesNo("welcome.consent", "y")
	if err != nil {
		return "", err
	}
	if !ok {
		return "", prompt.ErrQuit
	}
	return "Consented.", nil
}
