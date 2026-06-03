package steps

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// smallReposManifest points CA_BOOTSTRAP_REPOS at a one-group manifest.
func smallReposManifest(t *testing.T) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "repos.yaml")
	body := "version: 1\ngroups:\n  - name: core\n    repos:\n      - {repo: ChannelAssist/test-repo, into: ca-tools/test-repo, branch: main}\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CA_BOOTSTRAP_REPOS", p)
}

func TestRepos_Title(t *testing.T) {
	if (Repos{}).Title() != "Repository cloning" {
		t.Errorf("Title = %q", (Repos{}).Title())
	}
}

func TestRepos_WorkspaceEmpty_Errors(t *testing.T) {
	smallReposManifest(t)
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}}
	if _, err := (Repos{}).Run(ctx); err == nil {
		t.Error("expected error when workspace unset")
	}
}

func TestRepos_HappyClone_Mock(t *testing.T) {
	smallReposManifest(t)
	t.Setenv("CA_BOOTSTRAP_CLONE_MOCK", "ok")
	ws := t.TempDir()
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}, Workspace: ws}
	msg, err := (Repos{}).Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(msg, "cloned") {
		t.Errorf("summary = %q, want a clone count", msg)
	}
	if _, err := os.Stat(filepath.Join(ws, "ca-tools/test-repo", ".git")); err != nil {
		t.Errorf("repo not cloned: %v", err)
	}
}

func TestRepos_Declined_NoClone(t *testing.T) {
	smallReposManifest(t)
	t.Setenv("CA_BOOTSTRAP_CLONE_MOCK", "ok")
	ws := t.TempDir()
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: false}, Workspace: ws}
	if _, err := (Repos{}).Run(ctx); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(filepath.Join(ws, "ca-tools/test-repo")); !os.IsNotExist(err) {
		t.Errorf("declining the group must not clone; stat err=%v", err)
	}
}
