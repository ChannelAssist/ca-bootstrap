// Package journal is the append-only NDJSON action record at
// ~/.ca-bootstrap/journal.ndjson. See spec §6.
//
// alpha.2 surface: NewSession, Append, EndSession.
// alpha.4 will add: Iterate, Compact (for undo).
package journal

import "time"

// Entry is one journal record. See spec §6.1 for the schema.
type Entry struct {
	TS        time.Time         `json:"ts"`
	SessionID string            `json:"sessionID"`
	Action    string            `json:"action"`
	Target    string            `json:"target,omitempty"`
	Before    map[string]string `json:"before,omitempty"`
	After     map[string]string `json:"after,omitempty"`
	Result    string            `json:"result"`
}
