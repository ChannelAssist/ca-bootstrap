package reversers

import (
	"errors"
	"io/fs"
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// CreateFolder reverses a create_folder entry. Removes the folder if
// empty; refuses to remove a non-empty folder unless opts.Force.
// alpha.5 spec §7.1.
type CreateFolder struct{}

// Reverse implements undo.Reverser.
func (CreateFolder) Reverse(e journal.Entry, opts undo.Options) undo.Outcome {
	if e.Target == "" {
		return undo.Outcome{Status: "fail", Details: "create_folder entry missing target"}
	}
	info, err := os.Stat(e.Target)
	if errors.Is(err, fs.ErrNotExist) {
		return undo.Outcome{Status: "noop", Details: "already absent: " + e.Target}
	}
	if err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	if !info.IsDir() {
		return undo.Outcome{Status: "skip", Details: e.Target + " is not a directory"}
	}
	// Empty check.
	dirents, derr := os.ReadDir(e.Target)
	if derr != nil {
		return undo.Outcome{Status: "fail", Details: derr.Error()}
	}
	if len(dirents) > 0 && !opts.IncludeFolders {
		return undo.Outcome{
			Status:  "refused",
			Details: e.Target + " not empty — use --include-folders to override",
		}
	}
	if rerr := os.RemoveAll(e.Target); rerr != nil {
		return undo.Outcome{Status: "fail", Details: rerr.Error()}
	}
	return undo.Outcome{Status: "ok", Details: "Removed " + e.Target}
}
