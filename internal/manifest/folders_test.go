package manifest

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// writeFoldersYAML writes body to a temp folders.yaml and returns its path.
func writeFoldersYAML(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "folders.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write temp folders.yaml: %v", err)
	}
	return p
}

func TestLoadFoldersDefault_ParsesEmbedded(t *testing.T) {
	m, err := LoadFoldersDefault()
	if err != nil {
		t.Fatalf("LoadFoldersDefault: %v", err)
	}
	if m.Version != 1 {
		t.Errorf("version = %d, want 1", m.Version)
	}
	if len(m.Folders) == 0 {
		t.Fatal("expected at least one folder in embedded manifest")
	}
	// Every folder must have a path; the embedded manifest is the
	// production source of truth, so this guards against a bad edit.
	for i, f := range m.Folders {
		if f.Path == "" {
			t.Errorf("folder[%d] has empty path", i)
		}
	}
}

func TestLoadFoldersDefault_NormalisesScalarRenamedFrom(t *testing.T) {
	m, err := LoadFoldersDefault()
	if err != nil {
		t.Fatalf("LoadFoldersDefault: %v", err)
	}
	// ca-tools-repo declares `renamed_from: ca-tools` (a scalar) in
	// the embedded manifest; it must normalise to a one-element slice.
	var found bool
	for _, f := range m.Folders {
		if f.Path == "ca-tools-repo" {
			found = true
			if len(f.RenamedFrom) != 1 || f.RenamedFrom[0] != "ca-tools" {
				t.Errorf("ca-tools-repo renamed_from = %v, want [ca-tools]", f.RenamedFrom)
			}
		}
	}
	if !found {
		t.Fatal("ca-tools-repo folder not present in embedded manifest")
	}
}

func TestLoadFolders_RenamedFromListPolymorphism(t *testing.T) {
	p := writeFoldersYAML(t, `version: 1
folders:
  - path: ca-prototypes
    renamed_from:
      - ca-experiments
      - experiments
`)
	m, err := LoadFolders(p)
	if err != nil {
		t.Fatalf("LoadFolders: %v", err)
	}
	got := m.Folders[0].RenamedFrom
	want := []string{"ca-experiments", "experiments"}
	if len(got) != len(want) {
		t.Fatalf("renamed_from = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("renamed_from[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestLoadFolders_NotFound_WrapsErrNotFound(t *testing.T) {
	_, err := LoadFolders(filepath.Join(t.TempDir(), "missing.yaml"))
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestParseFolders_RejectsMissingVersion(t *testing.T) {
	p := writeFoldersYAML(t, `folders:
  - path: ca-tools
`)
	if _, err := LoadFolders(p); err == nil {
		t.Error("expected error for missing version")
	}
}

func TestParseFolders_RejectsUnsupportedVersion(t *testing.T) {
	p := writeFoldersYAML(t, `version: 2
folders:
  - path: ca-tools
`)
	if _, err := LoadFolders(p); err == nil {
		t.Error("expected error for unsupported version 2")
	}
}

func TestParseFolders_RejectsEmptyFolders(t *testing.T) {
	p := writeFoldersYAML(t, `version: 1
folders: []
`)
	if _, err := LoadFolders(p); err == nil {
		t.Error("expected error for empty folders list")
	}
}

func TestParseFolders_RejectsMissingPath(t *testing.T) {
	p := writeFoldersYAML(t, `version: 1
folders:
  - description: no path here
`)
	if _, err := LoadFolders(p); err == nil {
		t.Error("expected error for folder missing path")
	}
}

func TestParseFolders_RejectsDuplicatePath(t *testing.T) {
	p := writeFoldersYAML(t, `version: 1
folders:
  - path: ca-tools
  - path: ca-tools
`)
	if _, err := LoadFolders(p); err == nil {
		t.Error("expected error for duplicate folder path")
	}
}

func TestLoadFoldersDefault_HonoursEnvOverride(t *testing.T) {
	p := writeFoldersYAML(t, `version: 1
folders:
  - path: only-this-one
`)
	t.Setenv("CA_BOOTSTRAP_FOLDERS", p)
	m, err := LoadFoldersDefault()
	if err != nil {
		t.Fatalf("LoadFoldersDefault with override: %v", err)
	}
	if len(m.Folders) != 1 || m.Folders[0].Path != "only-this-one" {
		t.Errorf("override not honoured; got %+v", m.Folders)
	}
}
