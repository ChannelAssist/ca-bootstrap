// Package prompt provides the interactive stdin-based prompt model for
// ca-bootstrap (spec §7).
//
// Prompter is the interface; stdinPrompter is the default
// implementation. unattendedPrompter (in unattended.go) reads answers
// from a YAML-loaded map.
//
// **DESIGN INVARIANT** (spec §2.B-2): plain stdin only. No TUI library.
// No survey, no bubbletea, no termbox. The PS-era TUI bug class (six
// prior commits) is exactly what we're avoiding.
package prompt

import "fmt"

// Prompter abstracts interactive vs unattended prompting.
type Prompter interface {
	// YesNo asks a y/n question. defaultAnswer is the value returned
	// when the user just hits Enter; pass "y", "n", or "" (no default
	// → must answer explicitly).
	YesNo(question, defaultAnswer string) (bool, error)

	// Line asks for a free-form text answer. defaultAnswer is returned
	// when the user hits Enter without typing anything.
	Line(question, defaultAnswer string) (string, error)

	// Quit signals "user wants to exit" — typically because they hit
	// 'q' at a prompt or sent SIGINT. The Prompter doesn't actually
	// exit; the wizard caller checks Quit() and short-circuits.
	Quit() bool
}

// New returns the default stdin-backed Prompter. Stub — Task 4.
func New() Prompter {
	return &stubPrompter{}
}

type stubPrompter struct{}

func (*stubPrompter) YesNo(string, string) (bool, error) {
	return false, fmt.Errorf("prompt: stdinPrompter.YesNo not implemented (Task 4)")
}
func (*stubPrompter) Line(string, string) (string, error) {
	return "", fmt.Errorf("prompt: stdinPrompter.Line not implemented (Task 4)")
}
func (*stubPrompter) Quit() bool { return false }
