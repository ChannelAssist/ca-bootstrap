package undo

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
)

// --- test doubles ---

// fakeReverser records the IDs it was asked to reverse (in call order)
// and returns a fixed Outcome.
type fakeReverser struct {
	out   Outcome
	calls *[]string
}

func (f fakeReverser) Reverse(e journal.Entry, _ Options) Outcome {
	*f.calls = append(*f.calls, e.ID)
	return f.out
}

type fakePrompter struct {
	answer bool
	quit   bool
}

func (f fakePrompter) YesNo(string, string) (bool, error) { return f.answer, nil }
func (f fakePrompter) Line(_, def string) (string, error) { return def, nil }
func (f fakePrompter) Quit() bool                         { return f.quit }

// writeJournal marshals entries (one JSON object per line) to path.
func writeJournal(t *testing.T, path string, entries []journal.Entry) {
	t.Helper()
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	for _, e := range entries {
		if err := enc.Encode(e); err != nil {
			t.Fatalf("encode entry: %v", err)
		}
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o600); err != nil {
		t.Fatalf("write journal: %v", err)
	}
}

// newSession opens a journal session rooted at a temp HOME and returns
// (session, sessionJournalPath).
func newSession(t *testing.T) (*journal.Session, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	sess, err := journal.NewSession()
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	return sess, filepath.Join(home, ".ca-bootstrap", "journal.ndjson")
}

// --- pure helpers ---

func TestMatchesTarget(t *testing.T) {
	id := journal.Entry{Action: "identity_set"}
	tool := journal.Entry{Action: "install_success", Target: "ripgrep"}
	cases := []struct {
		name   string
		e      journal.Entry
		target string
		want   bool
	}{
		{"empty matches all", id, "", true},
		{"identity matches identity_set", id, "identity", true},
		{"identity excludes tools", tool, "identity", false},
		{"tools matches install_success", tool, "tools", true},
		{"tool:id matches matching target", tool, "tool:ripgrep", true},
		{"tool:id excludes other id", tool, "tool:fd", false},
		{"unknown target matches nothing", id, "bogus", false},
	}
	for _, c := range cases {
		if got := matchesTarget(c.e, c.target); got != c.want {
			t.Errorf("%s: matchesTarget = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestCategorize(t *testing.T) {
	cands := []candidate{
		{e: journal.Entry{Action: "identity_set"}},
		{e: journal.Entry{Action: "install_success"}},
		{e: journal.Entry{Action: "install_success"}},
		{e: journal.Entry{Action: "create_folder"}},
	}
	got := categorize(cands)
	if got["identity"] != 1 || got["tools"] != 2 || got["create_folder"] != 1 {
		t.Errorf("categorize = %v", got)
	}
}

func TestExitCode(t *testing.T) {
	if (Summary{Failed: 1}).ExitCode() != 7 {
		t.Error("Failed>0 should map to exit 7")
	}
	if (Summary{Reversed: 3}).ExitCode() != 0 {
		t.Error("no failures should map to exit 0")
	}
}

// --- Run ---

func TestRun_EmptyJournal_NoError(t *testing.T) {
	sess, _ := newSession(t)
	defer sess.End(0)
	missing := filepath.Join(t.TempDir(), "nope.ndjson")
	s, err := Run(missing, sess, Options{Out: io.Discard}, nil)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if s.Reversed != 0 || s.Failed != 0 {
		t.Errorf("expected zero summary, got %+v", s)
	}
}

func TestRun_WalkOrderReversed(t *testing.T) {
	sess, _ := newSession(t)
	defer sess.End(0)
	jp := filepath.Join(t.TempDir(), "journal.ndjson")
	writeJournal(t, jp, []journal.Entry{
		{ID: "first", Action: "identity_set", Result: "ok"},
		{ID: "second", Action: "identity_set", Result: "ok"},
		{ID: "third", Action: "identity_set", Result: "ok"},
	})
	var calls []string
	rev := map[string]Reverser{"identity_set": fakeReverser{out: Outcome{Status: "ok"}, calls: &calls}}

	_, err := Run(jp, sess, Options{Out: io.Discard, Force: true}, rev)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	want := []string{"third", "second", "first"} // reverse of file order
	if len(calls) != len(want) {
		t.Fatalf("calls = %v, want %v", calls, want)
	}
	for i := range want {
		if calls[i] != want[i] {
			t.Errorf("call[%d] = %q, want %q", i, calls[i], want[i])
		}
	}
}

func TestRun_LegacyEntryNoID_Skipped(t *testing.T) {
	sess, _ := newSession(t)
	defer sess.End(0)
	jp := filepath.Join(t.TempDir(), "journal.ndjson")
	writeJournal(t, jp, []journal.Entry{
		{Action: "identity_set", Result: "ok"}, // no ID → legacy
	})
	var calls []string
	rev := map[string]Reverser{"identity_set": fakeReverser{out: Outcome{Status: "ok"}, calls: &calls}}

	s, err := Run(jp, sess, Options{Out: io.Discard, Force: true}, rev)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(calls) != 0 {
		t.Errorf("legacy entry should not be reversed; calls=%v", calls)
	}
	if s.Skipped != 1 {
		t.Errorf("Skipped = %d, want 1", s.Skipped)
	}
}

func TestRun_AlreadyUndone_Skipped(t *testing.T) {
	sess, _ := newSession(t)
	defer sess.End(0)
	jp := filepath.Join(t.TempDir(), "journal.ndjson")
	writeJournal(t, jp, []journal.Entry{
		{ID: "abc", Action: "identity_set", Result: "ok"},
		{Action: "entry_undone", Target: "abc", Result: "ok"}, // already reversed
	})
	var calls []string
	rev := map[string]Reverser{"identity_set": fakeReverser{out: Outcome{Status: "ok"}, calls: &calls}}

	_, err := Run(jp, sess, Options{Out: io.Discard, Force: true}, rev)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(calls) != 0 {
		t.Errorf("already-undone entry should be skipped; calls=%v", calls)
	}
}

func TestRun_NonOkEntry_Skipped(t *testing.T) {
	sess, _ := newSession(t)
	defer sess.End(0)
	jp := filepath.Join(t.TempDir(), "journal.ndjson")
	writeJournal(t, jp, []journal.Entry{
		{ID: "x", Action: "identity_set", Result: "fail"}, // not a successful action
	})
	var calls []string
	rev := map[string]Reverser{"identity_set": fakeReverser{out: Outcome{Status: "ok"}, calls: &calls}}

	_, err := Run(jp, sess, Options{Out: io.Discard, Force: true}, rev)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(calls) != 0 {
		t.Errorf("non-ok entry should not be reversed; calls=%v", calls)
	}
}

func TestRun_TargetNoMatch_Errors(t *testing.T) {
	sess, _ := newSession(t)
	defer sess.End(0)
	jp := filepath.Join(t.TempDir(), "journal.ndjson")
	writeJournal(t, jp, []journal.Entry{
		{ID: "x", Action: "identity_set", Result: "ok"},
	})
	rev := map[string]Reverser{"identity_set": fakeReverser{out: Outcome{Status: "ok"}, calls: new([]string)}}

	_, err := Run(jp, sess, Options{Out: io.Discard, Target: "tools"}, rev)
	if err == nil {
		t.Error("expected error when --target matches no reversible actions")
	}
}

func TestRun_DeclineAtPrompt_ReturnsErrUserDeclined(t *testing.T) {
	sess, _ := newSession(t)
	defer sess.End(0)
	jp := filepath.Join(t.TempDir(), "journal.ndjson")
	writeJournal(t, jp, []journal.Entry{
		{ID: "x", Action: "identity_set", Result: "ok"},
	})
	var calls []string
	rev := map[string]Reverser{"identity_set": fakeReverser{out: Outcome{Status: "ok"}, calls: &calls}}

	_, err := Run(jp, sess, Options{Out: io.Discard, Prompter: fakePrompter{answer: false}}, rev)
	if err != ErrUserDeclined {
		t.Errorf("err = %v, want ErrUserDeclined", err)
	}
	if len(calls) != 0 {
		t.Errorf("nothing should be reversed when declined; calls=%v", calls)
	}
}

func TestRun_AppendsEntryUndoneMarker(t *testing.T) {
	sess, sessPath := newSession(t)
	jp := filepath.Join(t.TempDir(), "journal.ndjson")
	writeJournal(t, jp, []journal.Entry{
		{ID: "target-id", Action: "identity_set", Result: "ok"},
	})
	var calls []string
	rev := map[string]Reverser{"identity_set": fakeReverser{out: Outcome{Status: "ok"}, calls: &calls}}

	s, err := Run(jp, sess, Options{Out: io.Discard, Force: true}, rev)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if s.Reversed != 1 {
		t.Fatalf("Reversed = %d, want 1", s.Reversed)
	}
	// Close the session so the marker is flushed, then read it back.
	if err := sess.End(0); err != nil {
		t.Fatalf("End: %v", err)
	}
	entries, err := journal.Read(sessPath)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	var found bool
	for _, e := range entries {
		if e.Action == "entry_undone" && e.Target == "target-id" {
			found = true
		}
	}
	if !found {
		t.Error("expected an entry_undone marker referencing target-id")
	}
}
