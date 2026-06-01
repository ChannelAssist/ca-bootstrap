package reversers

import (
	"errors"
	"io/fs"
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// RenameFolder reverses a rename_folder entry by renaming `to` back to
// `from`. alpha.5 spec §7.2.
//
// Refuses to overwrite a path that has reappeared at `from` since the
// rename (likely user data the operator created).
type RenameFolder struct{}

// Reverse implements undo.Reverser.
func (RenameFolder) Reverse(e journal.Entry, _ undo.Options) undo.Outcome {
	from := e.Before["from"]
	to := e.Before["to"]
	if from == "" || to == "" {
		return undo.Outcome{
			Status:  "fail",
			Details: "rename_folder entry missing before.from / before.to",
		}
	}
	info, err := os.Stat(to)
	if errors.Is(err, fs.ErrNotExist) {
		return undo.Outcome{Status: "noop", Details: "renamed folder no longer present at " + to}
	}
	if err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	if !info.IsDir() {
		return undo.Outcome{Status: "skip", Details: to + " is not a directory"}
	}
	if _, ferr := os.Stat(from); ferr == nil {
		return undo.Outcome{
			Status:  "skip",
			Details: "a path already exists at " + from + "; cannot reverse rename",
		}
	}
	if rerr := os.Rename(to, from); rerr != nil {
		return undo.Outcome{Status: "fail", Details: rerr.Error()}
	}
	return undo.Outcome{Status: "ok", Details: "Reversed rename: " + to + " → " + from}
}
