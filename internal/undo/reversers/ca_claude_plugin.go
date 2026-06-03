package reversers

import (
	"errors"
	"io/fs"
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// CaClaudePlugin reverses an install_ca_claude_plugin entry by removing
// the activation symlink/junction under ~/.claude/plugins. Only the
// link is removed — never the target repo. Absent → noop.
type CaClaudePlugin struct{}

// Reverse implements undo.Reverser.
func (CaClaudePlugin) Reverse(e journal.Entry, _ undo.Options) undo.Outcome {
	if e.Target == "" {
		return undo.Outcome{Status: "fail", Details: "install_ca_claude_plugin entry missing target"}
	}
	// Lstat so we inspect the link itself, not what it points at.
	if _, err := os.Lstat(e.Target); errors.Is(err, fs.ErrNotExist) {
		return undo.Outcome{Status: "noop", Details: "link already absent: " + e.Target}
	} else if err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	if err := os.Remove(e.Target); err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	return undo.Outcome{Status: "ok", Details: "Removed plugin link " + e.Target}
}
