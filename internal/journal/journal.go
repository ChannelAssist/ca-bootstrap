package journal

// Session represents an open journal session.
//
// Implementation lands in Task 3 — this scaffold exists so Task 2's
// acceptance tests can reference the package symbols.
type Session struct {
	ID string
}

// NewSession creates a new session and records a session_start entry.
// Stub — Task 3.
func NewSession() (*Session, error) {
	return nil, errNotImplemented("NewSession")
}

// Append writes one Entry to the journal. Stub — Task 3.
func (s *Session) Append(e Entry) error {
	return errNotImplemented("Append")
}

// End writes a session_end entry with the given exit code. Stub — Task 3.
func (s *Session) End(exitCode int) error {
	return errNotImplemented("End")
}
