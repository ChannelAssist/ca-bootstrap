package folders

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// applyOpts returns Options writing to io.Discard with no journal
// session (journaling is exercised at the acceptance layer).
func applyOpts(workspace string) Options {
	return Options{Out: io.Discard, WorkspaceDir: workspace}
}

func reqFolder(path string) manifest.Folder { return manifest.Folder{Path: path} }

func TestApply_CreatesRequiredFolder(t *testing.T) {
	ws := t.TempDir()
	m := &manifest.FoldersManifest{Version: 1, Folders: []manifest.Folder{reqFolder("ca-tools-repo")}}

	s, err := Apply(m, applyOpts(ws))
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if s.Created != 1 {
		t.Errorf("Created = %d, want 1", s.Created)
	}
	if info, err := os.Stat(filepath.Join(ws, "ca-tools-repo")); err != nil || !info.IsDir() {
		t.Errorf("ca-tools-repo not created as dir: err=%v", err)
	}
	// ca-tools-repo has an embedded README template — it should be seeded.
	if s.SeededReadmes != 1 {
		t.Errorf("SeededReadmes = %d, want 1", s.SeededReadmes)
	}
	if _, err := os.Stat(filepath.Join(ws, "ca-tools-repo", "README.md")); err != nil {
		t.Errorf("README.md not seeded: %v", err)
	}
}

func TestApply_KeepsExistingFolder(t *testing.T) {
	ws := t.TempDir()
	if err := os.MkdirAll(filepath.Join(ws, "ca-tools-repo"), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &manifest.FoldersManifest{Version: 1, Folders: []manifest.Folder{reqFolder("ca-tools-repo")}}

	s, err := Apply(m, applyOpts(ws))
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if s.Kept != 1 || s.Created != 0 {
		t.Errorf("Kept=%d Created=%d, want Kept=1 Created=0", s.Kept, s.Created)
	}
}

func TestApply_OptionalMissingNotCreated(t *testing.T) {
	ws := t.TempDir()
	m := &manifest.FoldersManifest{Version: 1, Folders: []manifest.Folder{
		{Path: "ado-legacy", Optional: true},
	}}

	s, err := Apply(m, applyOpts(ws))
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if s.Created != 0 {
		t.Errorf("Created = %d, want 0 (optional + no predecessor)", s.Created)
	}
	if _, err := os.Stat(filepath.Join(ws, "ado-legacy")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("optional folder should not have been created; stat err=%v", err)
	}
}

func TestApply_MigratesPredecessor(t *testing.T) {
	ws := t.TempDir()
	// Operator already has the old name on disk with a marker file.
	oldDir := filepath.Join(ws, "experiments")
	if err := os.MkdirAll(oldDir, 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(oldDir, "keepme.txt")
	if err := os.WriteFile(marker, []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := &manifest.FoldersManifest{Version: 1, Folders: []manifest.Folder{
		{Path: "ca-experiments-repo", Optional: true, RenamedFrom: []string{"experiments"}},
	}}

	s, err := Apply(m, applyOpts(ws))
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if s.Renamed != 1 {
		t.Errorf("Renamed = %d, want 1", s.Renamed)
	}
	if _, err := os.Stat(oldDir); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("old dir should be gone after rename; stat err=%v", err)
	}
	// Migrated contents must survive the rename.
	if _, err := os.Stat(filepath.Join(ws, "ca-experiments-repo", "keepme.txt")); err != nil {
		t.Errorf("migrated content missing: %v", err)
	}
}

func TestApply_CollisionNonDirRequired_ReturnsErrCollision(t *testing.T) {
	ws := t.TempDir()
	// A regular file sits where a required folder must go.
	if err := os.WriteFile(filepath.Join(ws, "ca-tools-repo"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := &manifest.FoldersManifest{Version: 1, Folders: []manifest.Folder{reqFolder("ca-tools-repo")}}

	_, err := Apply(m, applyOpts(ws))
	var ce *ErrCollision
	if !errors.As(err, &ce) {
		t.Fatalf("expected *ErrCollision, got %v", err)
	}
}

func TestApply_SeedReadmeIdempotent(t *testing.T) {
	ws := t.TempDir()
	m := &manifest.FoldersManifest{Version: 1, Folders: []manifest.Folder{reqFolder("ca-docs-repo")}}

	if _, err := Apply(m, applyOpts(ws)); err != nil {
		t.Fatalf("first Apply: %v", err)
	}
	s2, err := Apply(m, applyOpts(ws))
	if err != nil {
		t.Fatalf("second Apply: %v", err)
	}
	if s2.SeededReadmes != 0 {
		t.Errorf("second run SeededReadmes = %d, want 0 (idempotent)", s2.SeededReadmes)
	}
	if s2.Kept != 1 {
		t.Errorf("second run Kept = %d, want 1", s2.Kept)
	}
}

func TestApply_EmptyWorkspace_Errors(t *testing.T) {
	m := &manifest.FoldersManifest{Version: 1, Folders: []manifest.Folder{reqFolder("ca-tools-repo")}}
	if _, err := Apply(m, Options{Out: io.Discard, WorkspaceDir: ""}); err == nil {
		t.Error("expected error for empty workspace dir")
	}
}

func TestTemplateHash_KnownFolder(t *testing.T) {
	h, err := TemplateHash("ca-tools-repo")
	if err != nil {
		t.Fatalf("TemplateHash: %v", err)
	}
	if len(h) != 64 { // sha256 hex
		t.Errorf("hash len = %d, want 64", len(h))
	}
}

func TestTemplateHash_UnknownFolder_NotExist(t *testing.T) {
	_, err := TemplateHash("no-such-folder")
	if !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("expected fs.ErrNotExist, got %v", err)
	}
}

func TestFolderNameFromTemplateKey(t *testing.T) {
	cases := map[string]string{
		"ca-tools-repo/README.md": "ca-tools-repo",
		"ca-docs-repo/README.md":  "ca-docs-repo",
		"README.md":               "", // no folder prefix
		"ca-tools-repo/other.txt": "", // wrong suffix
		"":                        "",
	}
	for in, want := range cases {
		if got := FolderNameFromTemplateKey(in); got != want {
			t.Errorf("FolderNameFromTemplateKey(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestTemplatesFS_ContainsKnownTemplate(t *testing.T) {
	if _, err := fs.Stat(TemplatesFS(), "ca-tools-repo/README.md"); err != nil {
		t.Errorf("expected ca-tools-repo/README.md in templates FS: %v", err)
	}
}
