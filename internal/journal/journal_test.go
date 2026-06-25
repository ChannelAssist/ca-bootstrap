package journal

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withTestHome sets HOME to a t.TempDir() for the duration of the test
// so the journal lands in the sandbox rather than the real ~/.ca-bootstrap/.
func withTestHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	// os.UserHomeDir() reads %USERPROFILE% on Windows, not $HOME, so without
	// this the journal escapes the sandbox into the real profile dir on the
	// windows-latest runner (the read below then can't find it).
	t.Setenv("USERPROFILE", home)
	return home
}

func TestNewSession_ReturnsNonEmptyID(t *testing.T) {
	withTestHome(t)
	s, err := NewSession()
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	defer s.Close() // release the handle so t.TempDir cleanup can remove it on Windows
	if s == nil || s.ID == "" {
		t.Errorf("expected non-empty session ID, got %+v", s)
	}
}

func TestNewSession_WritesSessionStartEntry(t *testing.T) {
	home := withTestHome(t)
	s, err := NewSession()
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	defer s.Close() // release the handle so t.TempDir cleanup can remove it on Windows
	path := filepath.Join(home, ".ca-bootstrap", "journal.ndjson")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read journal: %v", err)
	}
	if !strings.Contains(string(body), "session_start") {
		t.Errorf("expected session_start entry. got:\n%s", body)
	}
	if !strings.Contains(string(body), s.ID) {
		t.Errorf("expected session ID %q in journal. got:\n%s", s.ID, body)
	}
}

func TestAppend_WritesOneLinePerEntry(t *testing.T) {
	home := withTestHome(t)
	s, err := NewSession()
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	defer s.Close() // release the handle so t.TempDir cleanup can remove it on Windows
	if err := s.Append(Entry{Action: "test_action", Target: "/tmp/x", Result: "ok"}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	if err := s.Append(Entry{Action: "another", Result: "ok"}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	path := filepath.Join(home, ".ca-bootstrap", "journal.ndjson")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read journal: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	// Expect: session_start + test_action + another = 3 lines.
	if len(lines) != 3 {
		t.Fatalf("expected 3 lines, got %d. body:\n%s", len(lines), body)
	}
	// Verify each line is valid JSON.
	for i, line := range lines {
		var e Entry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Errorf("line %d not valid JSON: %v\nline: %s", i, err, line)
		}
	}
}

func TestEnd_WritesSessionEndWithExitCode(t *testing.T) {
	home := withTestHome(t)
	s, err := NewSession()
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	defer s.Close() // no-op after End; guards the early-return paths on Windows
	if err := s.End(2); err != nil {
		t.Fatalf("End: %v", err)
	}
	path := filepath.Join(home, ".ca-bootstrap", "journal.ndjson")
	body, _ := os.ReadFile(path)
	if !strings.Contains(string(body), "session_end") {
		t.Errorf("expected session_end entry. got:\n%s", body)
	}
	if !strings.Contains(string(body), `"result":"exit_2"`) {
		t.Errorf("expected exit_2 result. got:\n%s", body)
	}
}

func TestAppend_PreservesFieldsInJSON(t *testing.T) {
	withTestHome(t)
	s, err := NewSession()
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	defer s.Close() // release the handle so t.TempDir cleanup can remove it on Windows
	e := Entry{
		Action: "git_config_set",
		Target: "/path/to/.git/config",
		Before: map[string]string{"user.name": ""},
		After:  map[string]string{"user.name": "Peter"},
		Result: "ok",
	}
	if err := s.Append(e); err != nil {
		t.Fatalf("Append: %v", err)
	}
	body, _ := os.ReadFile(filepath.Join(os.Getenv("HOME"), ".ca-bootstrap", "journal.ndjson"))
	for _, want := range []string{"git_config_set", "Peter", "user.name", "/path/to/.git/config"} {
		if !strings.Contains(string(body), want) {
			t.Errorf("expected %q in journal. got:\n%s", want, body)
		}
	}
}
