// Package prompt provides the interactive stdin-based prompt model for
// ca-bootstrap (spec §7).
//
// **DESIGN INVARIANT** (spec §2.B-2): plain stdin only. No TUI library.
// No survey, no bubbletea, no termbox. The PS-era TUI bug class (six
// prior commits) is exactly what we're avoiding.
package prompt

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// Prompter abstracts interactive vs unattended prompting.
type Prompter interface {
	// YesNo asks a y/n question. defaultAnswer is returned when the
	// user just hits Enter; pass "y", "n", or "" (no default → must
	// answer explicitly).
	YesNo(question, defaultAnswer string) (bool, error)

	// Line asks for a free-form text answer. defaultAnswer is returned
	// on empty input.
	Line(question, defaultAnswer string) (string, error)

	// Quit reports whether the user asked to exit. After Quit() returns
	// true, callers should stop prompting and exit the wizard.
	Quit() bool
}

// ErrQuit is the sentinel error returned by stdinPrompter methods
// when the user types 'q'. Callers check this and short-circuit to
// the wizard's quit path.
var ErrQuit = errors.New("prompt: user requested quit")

// New returns the default stdin-backed Prompter. Reads from os.Stdin,
// writes prompt text to os.Stdout.
func New() Prompter {
	return newStdinPrompter(os.Stdin, os.Stdout)
}

// stdinPrompter is the default real-stdin implementation. The io.Reader
// abstraction lets tests inject bytes.Buffer.
type stdinPrompter struct {
	r       *bufio.Reader
	w       io.Writer
	quitted bool
}

func newStdinPrompter(r io.Reader, w io.Writer) *stdinPrompter {
	return &stdinPrompter{
		r: bufio.NewReader(r),
		w: w,
	}
}

func (p *stdinPrompter) YesNo(question, defaultAnswer string) (bool, error) {
	// Print question with default hint, read one line, validate, retry
	// up to a sane max so a wedged user doesn't loop forever.
	hint := "[y/n]"
	switch strings.ToLower(defaultAnswer) {
	case "y":
		hint = "[Y/n]"
	case "n":
		hint = "[y/N]"
	}
	for retries := 0; retries < 5; retries++ {
		fmt.Fprintf(p.w, "%s %s ", question, hint)
		line, err := p.r.ReadString('\n')
		if err != nil && line == "" {
			return false, fmt.Errorf("prompt: read: %w", err)
		}
		ans := strings.ToLower(strings.TrimSpace(line))
		if ans == "" {
			ans = strings.ToLower(defaultAnswer)
		}
		switch ans {
		case "y", "yes":
			return true, nil
		case "n", "no":
			return false, nil
		case "q", "quit":
			p.quitted = true
			return false, ErrQuit
		default:
			fmt.Fprintf(p.w, "  please answer y or n (q to quit)\n")
		}
	}
	return false, fmt.Errorf("prompt: too many invalid answers")
}

func (p *stdinPrompter) Line(question, defaultAnswer string) (string, error) {
	if defaultAnswer != "" {
		fmt.Fprintf(p.w, "%s [%s]: ", question, defaultAnswer)
	} else {
		fmt.Fprintf(p.w, "%s: ", question)
	}
	line, err := p.r.ReadString('\n')
	if err != nil && line == "" {
		return "", fmt.Errorf("prompt: read: %w", err)
	}
	ans := strings.TrimSpace(line)
	if strings.ToLower(ans) == "q" {
		p.quitted = true
		return "", ErrQuit
	}
	if ans == "" {
		return defaultAnswer, nil
	}
	return ans, nil
}

func (p *stdinPrompter) Quit() bool {
	return p.quitted
}

// writeFile is the test helper used by prompt_test.go. Real callers
// use os.WriteFile directly. Kept here to avoid a tests-only file
// since the unattended-from-YAML path needs file I/O.
func writeFile(path, body string) error {
	return os.WriteFile(path, []byte(body), 0o644)
}
