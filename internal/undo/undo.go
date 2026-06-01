// Package undo reverses journal entries — the alpha.4 surface.
// See docs/specs/2026-05-28-go-v2-0-alpha-4-spec.md.
//
// undo is intentionally append-only with respect to the journal: a
// successful reversal appends an `entry_undone` entry whose Target is
// the reversed entry's ID, rather than mutating the original entry.
// This preserves the audit trail and keeps the NDJSON file format
// compatible with the alpha.2 journaling discipline.
package undo

import (
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

// Outcome describes the result of one reverser dispatch.
type Outcome struct {
	Status  string // "ok" | "noop" | "skip" | "refused" | "fail"
	Details string
}

// Options carry shared state into reversers + the orchestrator.
//
// alpha.5 split: Force is the unattended gate (--force on the CLI) —
// required by the CLI to undo non-interactively, NOT a destructive
// override. Reversers that need a "yes really, remove non-empty
// things" signal read IncludeFolders (--include-folders, matching the
// PS-era convention).
type Options struct {
	Out            io.Writer
	Prompter       prompt.Prompter
	IncludeTools   bool
	IncludeFolders bool
	Force          bool
	Target         string
}

// Reverser reverses one journal entry's effect. Implementations live
// in the reversers/ subpackage; the dispatch table is built by
// callers and passed into Run.
type Reverser interface {
	Reverse(entry journal.Entry, opts Options) Outcome
}

// Summary collects per-run aggregates for the orchestrator's caller.
type Summary struct {
	Reversed int
	Skipped  int
	Failed   int
	Failures []string
}

// ExitCode maps a Summary to the spec §5.5 exit codes. Per-failure
// runs return 7; everything else (incl. nothing-to-reverse) is 0.
func (s Summary) ExitCode() int {
	if s.Failed > 0 {
		return 7
	}
	return 0
}

// candidate pairs a reversible entry with the reverser that will
// handle it. Built during the filter pass; consumed in reverse order.
type candidate struct {
	e        journal.Entry
	reverser Reverser
}

// ErrUserDeclined is returned when the up-front "proceed?" prompt
// gets a no answer. The CLI layer maps this to exit 0 — declining is
// a clean, non-error outcome.
var ErrUserDeclined = errUserDeclined{}

type errUserDeclined struct{}

func (errUserDeclined) Error() string { return "undo: user declined" }

// ErrUserQuit is returned when the up-front prompt gets a quit. The
// CLI layer maps this to exit 130.
var ErrUserQuit = errUserQuit{}

type errUserQuit struct{}

func (errUserQuit) Error() string { return "undo: user quit" }

// Run walks the journal in reverse order, dispatches each reversible
// entry to its registered reverser, and appends an `entry_undone`
// marker on success. journalPath is typically
// $HOME/.ca-bootstrap/journal.ndjson; sess is the open writer session
// (created by the caller, which also handles its End()).
//
// Returns the summary plus a non-nil error for several exceptional
// cases that the CLI maps to specific exit codes (see ErrUserDeclined,
// ErrUserQuit, and the unknown-target error path).
//
// Up-front confirmation is integrated here (spec §5.1): after the
// candidate list is built and categories printed, the user is asked
// "proceed?". opts.Force bypasses this — matches the PS-era convention
// where --force / --target skip the up-front confirm but per-tool
// consent still gates each tool uninstall.
func Run(journalPath string, sess *journal.Session, opts Options, reversers map[string]Reverser) (Summary, error) {
	entries, err := journal.Read(journalPath)
	if err != nil {
		return Summary{}, fmt.Errorf("undo: read journal: %w", err)
	}
	if len(entries) == 0 {
		fmt.Fprintln(opts.Out, "  (no journal — nothing to reverse)")
		return Summary{}, nil
	}

	// Pass 1 — build the set of already-undone entry IDs.
	alreadyUndone := map[string]bool{}
	for _, e := range entries {
		if e.Action == "entry_undone" && e.Target != "" {
			alreadyUndone[e.Target] = true
		}
	}

	// Pass 2 — filter to reversible candidates.
	var cands []candidate
	legacySkipped := 0
	for _, e := range entries {
		r, isReg := reversers[e.Action]
		if !isReg {
			continue
		}
		if e.Result != "ok" {
			// install_failed / install_skipped etc. have no state to reverse.
			continue
		}
		if e.ID == "" {
			legacySkipped++
			fmt.Fprintf(opts.Out, "  ⓘ Skipping legacy entry (no id): %s [%s]\n",
				e.Action, e.TS.Format(time.RFC3339))
			continue
		}
		if alreadyUndone[e.ID] {
			continue
		}
		if !matchesTarget(e, opts.Target) {
			continue
		}
		cands = append(cands, candidate{e: e, reverser: r})
	}

	if opts.Target != "" && len(cands) == 0 {
		return Summary{Skipped: legacySkipped},
			fmt.Errorf("no reversible actions match target %q", opts.Target)
	}
	if len(cands) == 0 {
		fmt.Fprintln(opts.Out, "  (no reversible actions found)")
		return Summary{Skipped: legacySkipped}, nil
	}

	// Surface the category counts before reversing — same UX shape as PS-era.
	fmt.Fprintln(opts.Out, "\n  Reversible actions found:")
	for cat, n := range categorize(cands) {
		fmt.Fprintf(opts.Out, "    [%s] %d action(s)\n", cat, n)
	}
	fmt.Fprintln(opts.Out, "")

	// Up-front proceed prompt (spec §5.1). --force bypasses; --target
	// also bypasses (PS-era convention — a scoped undo is explicit
	// enough that the operator doesn't need a second confirmation).
	if !opts.Force && opts.Target == "" && opts.Prompter != nil {
		proceed, err := opts.Prompter.YesNo("undo.proceed", "n")
		if err == prompt.ErrQuit || (opts.Prompter.Quit()) {
			return Summary{Skipped: legacySkipped}, ErrUserQuit
		}
		if !proceed {
			fmt.Fprintln(opts.Out, "  (no changes made)")
			return Summary{Skipped: legacySkipped}, ErrUserDeclined
		}
	}

	summary := Summary{Skipped: legacySkipped}
	for i := len(cands) - 1; i >= 0; i-- {
		c := cands[i]
		ord := len(cands) - i
		fmt.Fprintf(opts.Out, "  [%d/%d] undo %s [%s]\n", ord, len(cands), c.e.Action, c.e.ID)
		out := c.reverser.Reverse(c.e, opts)
		switch out.Status {
		case "ok":
			summary.Reversed++
			fmt.Fprintf(opts.Out, "        ✓ %s\n", out.Details)
			_ = sess.Append(journal.Entry{
				Action: "entry_undone", Target: c.e.ID, Result: "ok",
			})
		case "noop":
			summary.Skipped++
			fmt.Fprintf(opts.Out, "        - noop: %s\n", out.Details)
			_ = sess.Append(journal.Entry{
				Action: "entry_undone", Target: c.e.ID, Result: "noop",
			})
		case "skip":
			summary.Skipped++
			fmt.Fprintf(opts.Out, "        - skip: %s\n", out.Details)
		case "refused":
			summary.Skipped++
			fmt.Fprintf(opts.Out, "        - refused: %s\n", out.Details)
		case "fail":
			summary.Failed++
			summary.Failures = append(summary.Failures,
				fmt.Sprintf("%s: %s", c.e.Action, out.Details))
			fmt.Fprintf(opts.Out, "        ✗ fail: %s\n", out.Details)
		}
	}

	return summary, nil
}

// matchesTarget returns true when the entry should be included given
// the user's --target value. Empty target matches everything.
//
// Recognised targets (spec §5.2):
//   - "identity"   → identity_set
//   - "tools"      → install_success
//   - "tool:<id>"  → install_success with Target == <id>
func matchesTarget(e journal.Entry, target string) bool {
	if target == "" {
		return true
	}
	switch {
	case target == "identity":
		return e.Action == "identity_set"
	case target == "tools":
		return e.Action == "install_success"
	case strings.HasPrefix(target, "tool:"):
		id := strings.TrimPrefix(target, "tool:")
		return e.Action == "install_success" && e.Target == id
	}
	return false
}

// categorize counts candidates by user-facing category. Keys are the
// short labels printed in the "Reversible actions found:" block.
func categorize(cands []candidate) map[string]int {
	out := map[string]int{}
	for _, c := range cands {
		switch c.e.Action {
		case "identity_set":
			out["identity"]++
		case "install_success":
			out["tools"]++
		default:
			out[c.e.Action]++
		}
	}
	return out
}
