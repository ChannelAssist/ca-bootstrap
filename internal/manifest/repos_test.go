package manifest

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func writeReposYAML(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "repos.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadReposDefault_ParsesEmbedded(t *testing.T) {
	m, err := LoadReposDefault()
	if err != nil {
		t.Fatalf("LoadReposDefault: %v", err)
	}
	if m.Version != 1 || len(m.Groups) == 0 {
		t.Fatalf("bad embedded repos manifest: version=%d groups=%d", m.Version, len(m.Groups))
	}
	if m.DefaultProtocol == "" {
		t.Error("default_protocol should default to https")
	}
	for _, g := range m.Groups {
		for _, r := range g.Repos {
			if r.Repo == "" || r.Into == "" {
				t.Errorf("group %s has a repo missing repo/into: %+v", g.Name, r)
			}
		}
	}
}

func TestParseRepos_RejectsMissingVersion(t *testing.T) {
	p := writeReposYAML(t, "groups:\n  - name: g\n    repos:\n      - {repo: a/b, into: x}\n")
	if _, err := LoadRepos(p); err == nil {
		t.Error("expected error for missing version")
	}
}

func TestParseRepos_RejectsMissingInto(t *testing.T) {
	p := writeReposYAML(t, "version: 1\ngroups:\n  - name: g\n    repos:\n      - {repo: a/b}\n")
	if _, err := LoadRepos(p); err == nil {
		t.Error("expected error for repo missing into")
	}
}

func TestParseRepos_RejectsDuplicateInto(t *testing.T) {
	p := writeReposYAML(t, "version: 1\ngroups:\n  - name: g\n    repos:\n      - {repo: a/b, into: x}\n      - {repo: a/c, into: x}\n")
	if _, err := LoadRepos(p); err == nil {
		t.Error("expected error for duplicate clone destination")
	}
}

func TestParseRepos_DefaultsProtocol(t *testing.T) {
	p := writeReposYAML(t, "version: 1\ngroups:\n  - name: g\n    repos:\n      - {repo: a/b, into: x}\n")
	m, err := LoadRepos(p)
	if err != nil {
		t.Fatal(err)
	}
	if m.DefaultProtocol != "https" {
		t.Errorf("default_protocol = %q, want https", m.DefaultProtocol)
	}
}

func TestLoadReposDefault_EnvOverride(t *testing.T) {
	p := writeReposYAML(t, "version: 1\ngroups:\n  - name: only\n    repos:\n      - {repo: a/b, into: x}\n")
	t.Setenv("CA_BOOTSTRAP_REPOS", p)
	m, err := LoadReposDefault()
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Groups) != 1 || m.Groups[0].Name != "only" {
		t.Errorf("override not honoured: %+v", m.Groups)
	}
}

func TestLoadRepos_NotFound(t *testing.T) {
	if _, err := LoadRepos(filepath.Join(t.TempDir(), "nope.yaml")); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}
