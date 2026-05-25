// Package wizard orchestrates multi-step interactive flows. Steps
// implement the Step interface; Run dispatches them in order, writing
// a journal entry per step. See spec §5.
package wizard

import (
	"io"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

// Step is one wizard step. Title is shown in the "Step N/M — Title"
// header; Run executes the step and returns a result message + error.
type Step interface {
	Title() string
	Run(ctx *Context) (result string, err error)
}

// Context is passed to every step. Holds the shared dependencies
// (writer for output, journal session, prompter) plus any state a
// step needs to communicate downstream (e.g., the resolved workspace
// root from step 3 needs to be visible to a future step 4 that
// clones repos into it).
type Context struct {
	Out       io.Writer
	Prompt    prompt.Prompter
	Session   *journal.Session
	Workspace string // populated by the identity step in alpha.2; used by clone step in alpha.6
}

// Run executes the steps in order. Returns the final exit code per
// spec §5.3. Stub — Task 6.
func Run(steps []Step, ctx *Context) int {
	// Task 6 implements:
	//   - for each step: write header, call Run, write result, journal.Append
	//   - handle Quit() short-circuit (return 130)
	//   - handle SIGINT trap → Quit
	//   - handle exit codes 0 / 1 / 2 / 130 per spec §5.3
	_ = steps
	_ = ctx
	return 1 // placeholder; tests will assert against real codes
}
