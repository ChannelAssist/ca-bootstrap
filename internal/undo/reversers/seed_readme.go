package reversers

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io/fs"
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/folders"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// SeedReadme reverses a seed_readme entry by removing the README, but
// only when the on-disk content's SHA-256 still matches the embedded
// template. Mismatched hashes mean the user edited the file —
// preserving the edits is safer than blind removal. alpha.5 spec §6.2.
type SeedReadme struct{}

// Reverse implements undo.Reverser.
func (SeedReadme) Reverse(e journal.Entry, _ undo.Options) undo.Outcome {
	if e.Target == "" {
		return undo.Outcome{Status: "fail", Details: "seed_readme entry missing target"}
	}
	templateKey := ""
	if e.Before != nil {
		templateKey = e.Before["template"]
	}
	if templateKey == "" {
		return undo.Outcome{Status: "fail", Details: "seed_readme entry missing before.template"}
	}

	// Target file present?
	info, err := os.Stat(e.Target)
	if errors.Is(err, fs.ErrNotExist) {
		return undo.Outcome{Status: "noop", Details: "README already absent: " + e.Target}
	}
	if err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	if !info.Mode().IsRegular() {
		return undo.Outcome{Status: "skip", Details: e.Target + " is not a regular file"}
	}

	// Hash the embedded template content.
	folderName := folders.FolderNameFromTemplateKey(templateKey)
	templateHash, terr := folders.TemplateHash(folderName)
	if errors.Is(terr, fs.ErrNotExist) {
		return undo.Outcome{
			Status:  "skip",
			Details: fmt.Sprintf("template no longer at recorded path (%s); preserving file %s", templateKey, e.Target),
		}
	}
	if terr != nil {
		return undo.Outcome{Status: "fail", Details: terr.Error()}
	}

	// Hash the on-disk content.
	body, rerr := os.ReadFile(e.Target)
	if rerr != nil {
		return undo.Outcome{Status: "fail", Details: rerr.Error()}
	}
	diskSum := sha256.Sum256(body)
	diskHash := fmt.Sprintf("%x", diskSum)

	if diskHash != templateHash {
		return undo.Outcome{
			Status:  "skip",
			Details: "README diverged from template (preserving user edits): " + e.Target,
		}
	}
	if rmerr := os.Remove(e.Target); rmerr != nil {
		return undo.Outcome{Status: "fail", Details: rmerr.Error()}
	}
	return undo.Outcome{Status: "ok", Details: "Removed seeded README: " + e.Target}
}
