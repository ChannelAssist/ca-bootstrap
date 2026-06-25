// Package folders implements the workspace folder taxonomy producer
// (alpha.5). For each entry in manifest/folders.yaml, ensures the
// folder exists under <workspace>, migrating a `renamed_from`
// predecessor into place when present, and seeding a per-folder
// README.md from an embedded template.
//
// See docs/specs/2026-05-28-go-v2-0-alpha-5-spec.md §5–§6.
package folders

import (
	"crypto/sha256"
	"embed"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

//go:embed templates/folder-readmes
var embeddedTemplates embed.FS

// TemplatesFS returns the embedded templates file system, rooted at
// the `templates/folder-readmes` directory. Exported for tests that
// want to inspect available templates without re-walking the embed.
func TemplatesFS() fs.FS {
	sub, err := fs.Sub(embeddedTemplates, "templates/folder-readmes")
	if err != nil {
		// Should never happen — the path is a literal at compile time.
		panic("folders: templates/folder-readmes not embedded: " + err.Error())
	}
	return sub
}

// Options drive Apply.
type Options struct {
	Out          io.Writer
	WorkspaceDir string
	Session      *journal.Session
}

// Summary collects per-run aggregates.
type Summary struct {
	Created       int
	Kept          int
	Renamed       int
	SeededReadmes int
}

// ErrCollision is returned when a required folder path exists but is
// not a directory. The operator must resolve manually.
type ErrCollision struct{ Path string }

func (e *ErrCollision) Error() string {
	return fmt.Sprintf("Path '%s' exists but is not a directory; resolve manually.", e.Path)
}

// Apply walks the folders manifest and reconciles each entry against
// the workspace. Required folders are created (or renamed from a
// predecessor); optional folders are only touched when already on
// disk. README seeding is idempotent.
//
// Mutating actions are journaled via opts.Session: `create_folder`,
// `rename_folder`, `seed_readme`. The alpha.4 undo dispatch reverses
// all three.
func Apply(m *manifest.FoldersManifest, opts Options) (Summary, error) {
	var s Summary
	if opts.WorkspaceDir == "" {
		return s, errors.New("folders: workspace dir is empty")
	}

	for _, f := range m.Folders {
		full := filepath.Join(opts.WorkspaceDir, f.Path)
		info, err := os.Stat(full)
		switch {
		case err == nil && info.IsDir():
			// Already a directory — keep.
			s.Kept++
		case err == nil && !info.IsDir():
			// Collision: file or symlink where a folder is required.
			if f.Optional {
				fmt.Fprintf(opts.Out, "    ⚠ Optional folder path '%s' exists but is not a directory — skipping README seed\n", full)
				continue
			}
			return s, &ErrCollision{Path: full}
		case errors.Is(err, fs.ErrNotExist):
			// Try a renamed_from migration first — works for required AND
			// optional folders. An on-disk predecessor signals the user
			// already has this folder under the old name; migrating
			// preserves their data even for opt-in folders.
			if pred := findPredecessor(opts.WorkspaceDir, f.RenamedFrom); pred != "" {
				if rerr := os.Rename(pred, full); rerr != nil {
					return s, fmt.Errorf("folders: rename %s → %s: %w", pred, full, rerr)
				}
				if opts.Session != nil {
					_ = opts.Session.Append(journal.Entry{
						Action: "rename_folder",
						Before: map[string]string{"from": pred, "to": full},
						Result: "ok",
					})
				}
				s.Renamed++
				fmt.Fprintf(opts.Out, "    ↻ %s  rename %s → %s\n", f.Path, filepath.Base(pred), f.Path)
			} else if f.Optional {
				// Optional + missing + no predecessor → skip entirely
				// (do not create). Continue to next folder.
				continue
			} else {
				// Required + missing + no predecessor → create fresh.
				if mkerr := os.MkdirAll(full, 0o755); mkerr != nil {
					return s, fmt.Errorf("folders: mkdir %s: %w", full, mkerr)
				}
				if opts.Session != nil {
					_ = opts.Session.Append(journal.Entry{
						Action: "create_folder",
						Target: full,
						Result: "ok",
					})
				}
				s.Created++
				fmt.Fprintf(opts.Out, "    + %s  created\n", f.Path)
			}
		default:
			return s, fmt.Errorf("folders: stat %s: %w", full, err)
		}

		// README seeding — runs for kept, created, and renamed folders.
		// Optional folders only reach here if they exist on disk.
		if seedRes, serr := seedReadme(opts, f.Path); serr != nil {
			fmt.Fprintf(opts.Out, "    ⚠ README seed for %s: %v\n", f.Path, serr)
		} else if seedRes {
			s.SeededReadmes++
		}
	}
	return s, nil
}

// findPredecessor walks the renamed_from list (already in most-recent
// → oldest order) and returns the absolute path of the first one that
// exists as a directory under workspace. Returns "" if none match.
func findPredecessor(workspace string, candidates []string) string {
	for _, name := range candidates {
		p := filepath.Join(workspace, name)
		if info, err := os.Stat(p); err == nil && info.IsDir() {
			return p
		}
	}
	return ""
}

// seedReadme copies the embedded template for folderName into
// <workspace>/<folderName>/README.md if the target doesn't exist.
// Journals a `seed_readme` entry on copy. Returns (seeded, err).
// Missing template → warn-level "no-template" path, returns (false, nil).
func seedReadme(opts Options, folderName string) (bool, error) {
	templateKey := folderName + "/README.md"
	fsys := TemplatesFS()

	templateBytes, err := fs.ReadFile(fsys, templateKey)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			fmt.Fprintf(opts.Out, "    ⚠ No README template for %s — skipping seed\n", folderName)
			return false, nil
		}
		return false, fmt.Errorf("read template %s: %w", templateKey, err)
	}

	targetPath := filepath.Join(opts.WorkspaceDir, folderName, "README.md")
	info, err := os.Stat(targetPath)
	switch {
	case err == nil && info.Mode().IsRegular():
		// Idempotent — keep existing README.
		return false, nil
	case err == nil && !info.Mode().IsRegular():
		return false, fmt.Errorf("target %s exists but is not a regular file", targetPath)
	case errors.Is(err, fs.ErrNotExist):
		// Proceed to write.
	default:
		return false, fmt.Errorf("stat %s: %w", targetPath, err)
	}

	// Ensure parent directory exists (it should, since Apply created
	// the folder, but Optional + pre-existing folder reaches here too).
	if mkerr := os.MkdirAll(filepath.Dir(targetPath), 0o755); mkerr != nil {
		return false, fmt.Errorf("mkdir %s: %w", filepath.Dir(targetPath), mkerr)
	}
	if werr := os.WriteFile(targetPath, templateBytes, 0o644); werr != nil {
		return false, fmt.Errorf("write %s: %w", targetPath, werr)
	}
	if opts.Session != nil {
		_ = opts.Session.Append(journal.Entry{
			Action: "seed_readme",
			Target: targetPath,
			Before: map[string]string{"template": templateKey},
			Result: "ok",
		})
	}
	return true, nil
}

// TemplateHash returns the SHA-256 hex digest of the embedded template
// at `<folderName>/README.md`. Used by undo's seed_readme reverser to
// verify the on-disk file still matches what was originally seeded
// (refuses to remove a user-edited README).
//
// Returns ("", os.ErrNotExist) when the template isn't embedded.
func TemplateHash(folderName string) (string, error) {
	templateKey := folderName + "/README.md"
	data, err := fs.ReadFile(TemplatesFS(), templateKey)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return fmt.Sprintf("%x", sum), nil
}

// FolderNameFromTemplateKey returns the folder name from a template
// key recorded in a seed_readme entry. E.g.
// "ca-tools-repo/README.md" → "ca-tools-repo". Returns "" if the key doesn't
// match the expected shape.
func FolderNameFromTemplateKey(key string) string {
	const suffix = "/README.md"
	if len(key) > len(suffix) && key[len(key)-len(suffix):] == suffix {
		return key[:len(key)-len(suffix)]
	}
	return ""
}
