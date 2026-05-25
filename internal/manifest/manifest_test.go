package manifest

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoad_ValidMinimal(t *testing.T) {
	m, err := Load(filepath.Join("testdata", "valid-minimal.yaml"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m.Version != 1 {
		t.Errorf("version: want 1, got %d", m.Version)
	}
	if len(m.Tools) != 1 || m.Tools[0].ID != "git" {
		t.Errorf("tools: want [{id:git}], got %+v", m.Tools)
	}
	if m.Tools[0].Detect.Command != "git" {
		t.Errorf("detect.command: want 'git', got %q", m.Tools[0].Detect.Command)
	}
}

func TestLoad_ValidationErrors(t *testing.T) {
	cases := []struct {
		file string
		want string // case-insensitive substring expected in error message
	}{
		{"missing-version.yaml", "version"},
		{"unsupported-version.yaml", "unsupported manifest version"},
		{"missing-tools.yaml", "tools"},
		{"tool-missing-id.yaml", "missing required 'id'"},
		{"duplicate-tool-id.yaml", "duplicate tool id"},
		{"invalid-min-version.yaml", "invalid min_version"},
		{"missing-detect-command.yaml", "missing required detect.command"},
	}
	for _, tc := range cases {
		t.Run(tc.file, func(t *testing.T) {
			_, err := Load(filepath.Join("testdata", tc.file))
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.want)
			}
			if !strings.Contains(strings.ToLower(err.Error()), strings.ToLower(tc.want)) {
				t.Errorf("error %q did not contain %q", err.Error(), tc.want)
			}
		})
	}
}

func TestLoad_FileNotFound(t *testing.T) {
	_, err := Load(filepath.Join("testdata", "does-not-exist.yaml"))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestLoadDefault_UsesEmbeddedWhenNoEnvVar(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_MANIFEST", "")
	m, err := LoadDefault()
	if err != nil {
		t.Fatalf("LoadDefault from embedded: %v", err)
	}
	if m.Version != 1 {
		t.Errorf("embedded manifest version: want 1, got %d", m.Version)
	}
	if len(m.Tools) == 0 {
		t.Errorf("embedded manifest has no tools")
	}
}

func TestLoadDefault_HonorsEnvVarOverride(t *testing.T) {
	override := filepath.Join("testdata", "valid-minimal.yaml")
	t.Setenv("CA_BOOTSTRAP_MANIFEST", override)
	m, err := LoadDefault()
	if err != nil {
		t.Fatalf("LoadDefault with env override: %v", err)
	}
	if len(m.Tools) != 1 || m.Tools[0].ID != "git" {
		t.Errorf("env override didn't take effect; got %+v", m.Tools)
	}
}
