package reversers

import (
	"errors"
	"io/fs"
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// CreateFile reverses a create_file entry (a config file the extras
// step wrote — e.g. a .code-workspace or a .vscode/*.json default) by
// removing it. These are tool-generated files, so removal is the
// expected reversal; absent → noop.
type CreateFile struct{}

// Reverse implements undo.Reverser.
func (CreateFile) Reverse(e journal.Entry, _ undo.Options) undo.Outcome {
	if e.Target == "" {
		return undo.Outcome{Status: "fail", Details: "create_file entry missing target"}
	}
	info, err := os.Stat(e.Target)
	if errors.Is(err, fs.ErrNotExist) {
		return undo.Outcome{Status: "noop", Details: "already absent: " + e.Target}
	}
	if err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	if info.IsDir() {
		return undo.Outcome{Status: "skip", Details: e.Target + " is a directory, not a file"}
	}
	if err := os.Remove(e.Target); err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	return undo.Outcome{Status: "ok", Details: "Removed " + e.Target}
}
