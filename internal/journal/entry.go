// Package journal is the append-only NDJSON action record at
// ~/.ca-bootstrap/journal.ndjson. See spec §6.
//
// alpha.2 surface: NewSession, Append, EndSession.
// alpha.4 adds: Entry.ID (populated at Append time), Read (parse the
// NDJSON file back into Entry slice for undo's reverse walk).
package journal

import "time"

// Entry is one journal record. See spec §6.1 for the schema.
//
// alpha.4 added ID (omitempty for backwards-compatibility with
// pre-alpha.4 journals; undo skips legacy entries that lack an ID).
type Entry struct {
	ID        string            `json:"id,omitempty"`
	TS        time.Time         `json:"ts"`
	SessionID string            `json:"sessionID"`
	Action    string            `json:"action"`
	Target    string            `json:"target,omitempty"`
	Before    map[string]string `json:"before,omitempty"`
	After     map[string]string `json:"after,omitempty"`
	Result    string            `json:"result"`
}
