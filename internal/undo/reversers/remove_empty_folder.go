package reversers

import (
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// RemoveEmptyFolder reverses a remove_empty_folder entry by recreating
// the empty folder. The producer for these entries ships in alpha.6
// (clone-failure cleanup); the reverser is included in alpha.5 so the
// dispatch map is complete when the producer lands.
type RemoveEmptyFolder struct{}

// Reverse implements undo.Reverser.
func (RemoveEmptyFolder) Reverse(e journal.Entry, _ undo.Options) undo.Outcome {
	if e.Target == "" {
		return undo.Outcome{Status: "fail", Details: "remove_empty_folder entry missing target"}
	}
	info, err := os.Stat(e.Target)
	if err == nil {
		if info.IsDir() {
			return undo.Outcome{Status: "noop", Details: "folder already present at " + e.Target}
		}
		return undo.Outcome{Status: "skip", Details: e.Target + " exists but is not a directory"}
	}
	if mkerr := os.MkdirAll(e.Target, 0o755); mkerr != nil {
		return undo.Outcome{Status: "fail", Details: mkerr.Error()}
	}
	return undo.Outcome{Status: "ok", Details: "Recreated " + e.Target}
}
