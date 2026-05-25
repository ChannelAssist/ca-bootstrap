package journal

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Session represents an open journal session. Holds the session ID
// and the open file handle so subsequent Append calls don't have to
// re-open the file every time.
type Session struct {
	ID   string
	path string
	f    *os.File
}

// NewSession creates a new session, opens (or creates) the journal
// file at ~/.ca-bootstrap/journal.ndjson, writes a session_start
// entry, and returns the Session. Subsequent Appends + End writes
// land in the same file under the same sessionID.
func NewSession() (*Session, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("journal: resolve $HOME: %w", err)
	}
	dir := filepath.Join(home, ".ca-bootstrap")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("journal: mkdir %s: %w", dir, err)
	}
	path := filepath.Join(dir, "journal.ndjson")
	// 0600 (user-only): journal entries include git identity and may later
	// hold more sensitive state, so it must not be world-readable on
	// multi-user systems. (Addresses Copilot review on the alpha.2 spec.)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("journal: open %s: %w", path, err)
	}
	s := &Session{
		ID:   newID(),
		path: path,
		f:    f,
	}
	if err := s.write(Entry{Action: "session_start", Result: "ok"}); err != nil {
		_ = f.Close()
		return nil, err
	}
	return s, nil
}

// Append writes one Entry to the journal under this session.
// Each call is one POSIX write() of one line + '\n' — atomic at the
// line boundary so a crash mid-call leaves the previous lines intact.
func (s *Session) Append(e Entry) error {
	return s.write(e)
}

// End writes a session_end entry with the given exit code and closes
// the file handle. After End, the Session must not be used.
func (s *Session) End(exitCode int) error {
	if err := s.write(Entry{Action: "session_end", Result: fmt.Sprintf("exit_%d", exitCode)}); err != nil {
		_ = s.f.Close()
		return err
	}
	return s.f.Close()
}

// write marshals an Entry to JSON, prepends timestamp and sessionID
// if missing, and appends one line to the journal file.
func (s *Session) write(e Entry) error {
	if e.TS.IsZero() {
		e.TS = time.Now().UTC()
	}
	if e.SessionID == "" {
		e.SessionID = s.ID
	}
	line, err := json.Marshal(e)
	if err != nil {
		return fmt.Errorf("journal: marshal entry: %w", err)
	}
	if _, err := s.f.Write(append(line, '\n')); err != nil {
		return fmt.Errorf("journal: write to %s: %w", s.path, err)
	}
	return nil
}

// newID returns a short random session identifier. Not a full ULID
// (which would require monotonicity guarantees and time-prefix
// encoding); this is just a random hex string sufficient for
// per-session disambiguation in the journal.
func newID() string {
	var b [10]byte // 20 hex chars
	if _, err := rand.Read(b[:]); err != nil {
		// rand.Read on a healthy OS shouldn't fail; if it does, fall
		// back to a time-based string so we still have *some* unique
		// value rather than crashing the wizard.
		return fmt.Sprintf("ts-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}
