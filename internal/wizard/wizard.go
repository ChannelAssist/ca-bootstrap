// Package wizard orchestrates multi-step interactive flows. Steps
// implement the Step interface; Run dispatches them in order, writing
// a journal entry per step. See spec §5.
package wizard

import (
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

// Step is one wizard step.
type Step interface {
	Title() string
	Run(ctx *Context) (result string, err error)
}

// Context is passed to every step. Holds shared dependencies (writer,
// prompter, journal session) plus state that flows between steps
// (Workspace is set by the identity step in alpha.2; future steps
// will read it).
type Context struct {
	Out       io.Writer
	Prompt    prompt.Prompter
	Session   *journal.Session
	Workspace string
}

// ErrDriftRejected is returned by the prereqs step when drift was
// found AND the user declined to continue. Wizard.Run maps this to
// exit code 2.
var ErrDriftRejected = errors.New("wizard: drift not acknowledged")

// Run executes the steps in order. Returns the exit code per spec §5.3:
//
//	0   — all steps completed successfully
//	1   — system error during a step
//	2   — drift rejected by user
//	130 — user quit (prompt.ErrQuit at any step)
func Run(steps []Step, ctx *Context) int {
	for i, step := range steps {
		fmt.Fprintf(ctx.Out, "\nStep %d/%d — %s\n", i+1, len(steps), step.Title())
		action := normalizeAction(step.Title())

		result, err := step.Run(ctx)
		switch {
		case errors.Is(err, prompt.ErrQuit):
			fmt.Fprintln(ctx.Out, "  (user quit)")
			_ = ctx.Session.Append(journal.Entry{Action: action, Result: "quit"})
			return 130
		case errors.Is(err, ErrDriftRejected):
			_ = ctx.Session.Append(journal.Entry{Action: action, Result: "drift_rejected"})
			return 2
		case err != nil:
			fmt.Fprintln(ctx.Out, "  error:", err)
			_ = ctx.Session.Append(journal.Entry{Action: action, Result: "error"})
			return 1
		default:
			if result != "" {
				fmt.Fprintln(ctx.Out, "  ✓ "+result)
			}
			_ = ctx.Session.Append(journal.Entry{Action: action, Result: "ok"})
		}
	}
	return 0
}

func normalizeAction(title string) string {
	// "Git identity" → "git_identity", "Prerequisites" → "prerequisites"
	return strings.ReplaceAll(strings.ToLower(title), " ", "_")
}
