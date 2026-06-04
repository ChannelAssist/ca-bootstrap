package reversers

import (
	"errors"
	"io/fs"
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// CloneRepo reverses a clone_repo entry by removing the cloned working
// tree. A clone is a populated directory that may hold uncommitted
// work, so removal is opt-in via --include-folders (the same gate that
// guards non-empty folder removal). Without it the clone is left intact.
type CloneRepo struct{}

// Reverse implements undo.Reverser.
func (CloneRepo) Reverse(e journal.Entry, opts undo.Options) undo.Outcome {
	if e.Target == "" {
		return undo.Outcome{Status: "fail", Details: "clone_repo entry missing target"}
	}
	info, err := os.Stat(e.Target)
	if errors.Is(err, fs.ErrNotExist) {
		return undo.Outcome{Status: "noop", Details: "clone already absent: " + e.Target}
	}
	if err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	if !info.IsDir() {
		return undo.Outcome{Status: "skip", Details: e.Target + " is not a directory"}
	}
	if !opts.IncludeFolders {
		return undo.Outcome{
			Status:  "refused",
			Details: e.Target + " is a clone (may hold uncommitted work) — use --include-folders to remove",
		}
	}
	if err := os.RemoveAll(e.Target); err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	return undo.Outcome{Status: "ok", Details: "Removed clone " + e.Target}
}
