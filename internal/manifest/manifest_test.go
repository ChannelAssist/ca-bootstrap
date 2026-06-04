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

func TestLoad_ParsesInstallBlock(t *testing.T) {
	// The embedded manifest has rich install blocks; load it and assert
	// a few representative tools parsed their install spec correctly.
	t.Setenv("CA_BOOTSTRAP_MANIFEST", "")
	m, err := LoadDefault()
	if err != nil {
		t.Fatalf("LoadDefault: %v", err)
	}
	byID := map[string]Tool{}
	for _, tool := range m.Tools {
		byID[tool.ID] = tool
	}

	// git: windows winget, macos brew, linux debian/rhel apt/dnf
	git, ok := byID["git"]
	if !ok {
		t.Fatal("git not in manifest")
	}
	if git.Install.Windows == nil || git.Install.Windows.Type != "winget" || git.Install.Windows.ID != "Git.Git" {
		t.Errorf("git windows install: want winget/Git.Git, got %+v", git.Install.Windows)
	}
	if git.Install.Macos == nil || git.Install.Macos.Type != "brew" {
		t.Errorf("git macos install: want brew, got %+v", git.Install.Macos)
	}
	if git.Install.Linux == nil || git.Install.Linux.Debian == nil || git.Install.Linux.Debian.Type != "apt" {
		t.Errorf("git linux debian install: want apt, got %+v", git.Install.Linux)
	}

	// pwsh macos: brew with cask:true
	pwsh, ok := byID["pwsh"]
	if !ok {
		t.Fatal("pwsh not in manifest")
	}
	if pwsh.Install.Macos == nil || !pwsh.Install.Macos.Cask {
		t.Errorf("pwsh macos should be cask:true, got %+v", pwsh.Install.Macos)
	}

	// dotnet-10 linux: any → script
	dotnet, ok := byID["dotnet-10"]
	if !ok {
		t.Fatal("dotnet-10 not in manifest")
	}
	if dotnet.Install.Linux == nil || dotnet.Install.Linux.Any == nil || dotnet.Install.Linux.Any.Type != "script" {
		t.Errorf("dotnet-10 linux any: want script, got %+v", dotnet.Install.Linux)
	}

	// claude-code: npm global:true
	cc, ok := byID["claude-code"]
	if !ok {
		t.Fatal("claude-code not in manifest")
	}
	if cc.Install.Windows == nil || cc.Install.Windows.Type != "npm" || !cc.Install.Windows.Global {
		t.Errorf("claude-code windows npm global, got %+v", cc.Install.Windows)
	}
}

// TestLoadDefault_RequiredToolSet guards the org's required prerequisites:
// these tools must NOT be optional in the embedded manifest. (Directed by
// Peter 2026-06-03 — az/gh/jq/git/make/copilot-cli are mandatory.)
func TestLoadDefault_RequiredToolSet(t *testing.T) {
	m, err := LoadDefault()
	if err != nil {
		t.Fatalf("LoadDefault: %v", err)
	}
	required := map[string]bool{"az": true, "gh": true, "jq": true, "git": true, "make": true, "copilot-cli": true}
	seen := map[string]bool{}
	for _, tool := range m.Tools {
		if required[tool.ID] {
			seen[tool.ID] = true
			if tool.Optional {
				t.Errorf("%s must be required (optional=false), got optional=true", tool.ID)
			}
		}
	}
	for id := range required {
		if !seen[id] {
			t.Errorf("required tool %q not found in manifest", id)
		}
	}
}
