package repos

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

// mapPrompter answers YesNo from a per-key map (falling back to def),
// and can simulate a quit.
type mapPrompter struct {
	answers map[string]bool
	def     bool
	quit    bool
}

func (p mapPrompter) YesNo(q, _ string) (bool, error) {
	if p.quit {
		return false, prompt.ErrQuit
	}
	if v, ok := p.answers[q]; ok {
		return v, nil
	}
	return p.def, nil
}
func (p mapPrompter) Line(_, def string) (string, error) { return def, nil }
func (p mapPrompter) Quit() bool                         { return p.quit }

func oneGroup(optIn bool) *manifest.ReposManifest {
	return &manifest.ReposManifest{
		Version: 1, DefaultProtocol: "https",
		Groups: []manifest.Group{{
			Name: "core",
			Repos: []manifest.Repo{
				{Repo: "ChannelAssist/test-repo", Into: "ca-tools/test-repo", Branch: "main", OptIn: optIn},
			},
		}},
	}
}

func opts(ws string, pr prompt.Prompter) Options {
	return Options{Out: io.Discard, Prompter: pr, WorkspaceDir: ws}
}

func TestApply_GroupSkip(t *testing.T) {
	ws := t.TempDir()
	s, err := Apply(oneGroup(false), opts(ws, mapPrompter{def: false}))
	if err != nil {
		t.Fatal(err)
	}
	if s.Skipped != 1 || s.Cloned != 0 {
		t.Errorf("group skip: Skipped=%d Cloned=%d, want 1/0", s.Skipped, s.Cloned)
	}
}

func TestApply_GroupClone_Mock(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_CLONE_MOCK", "ok")
	ws := t.TempDir()
	s, err := Apply(oneGroup(false), opts(ws, mapPrompter{def: true}))
	if err != nil {
		t.Fatal(err)
	}
	if s.Cloned != 1 {
		t.Fatalf("Cloned=%d, want 1", s.Cloned)
	}
	if _, err := os.Stat(filepath.Join(ws, "ca-tools/test-repo", ".git")); err != nil {
		t.Errorf("mock clone did not create the dest: %v", err)
	}
}

func TestApply_OptInDeclined(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_CLONE_MOCK", "ok")
	ws := t.TempDir()
	// group accepted (all opt-in → default n, so answer the group yes
	// explicitly), but the per-repo opt-in prompt declines.
	pr := mapPrompter{answers: map[string]bool{
		"repos.group.core":                   true,
		"repos.repo.ChannelAssist/test-repo": false,
	}}
	s, err := Apply(oneGroup(true), opts(ws, pr))
	if err != nil {
		t.Fatal(err)
	}
	if s.Cloned != 0 || s.Skipped != 1 {
		t.Errorf("opt-in declined: Cloned=%d Skipped=%d, want 0/1", s.Cloned, s.Skipped)
	}
}

func TestApply_CloneFailCleanup(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_CLONE_MOCK", "fail:ChannelAssist/test-repo")
	ws := t.TempDir()
	s, err := Apply(oneGroup(false), opts(ws, mapPrompter{def: true}))
	if err != nil {
		t.Fatal(err)
	}
	if s.Failed != 1 {
		t.Errorf("Failed=%d, want 1", s.Failed)
	}
	if _, err := os.Stat(filepath.Join(ws, "ca-tools/test-repo")); !os.IsNotExist(err) {
		t.Errorf("failed clone should be cleaned up; stat err=%v", err)
	}
}

func TestApply_Quit(t *testing.T) {
	ws := t.TempDir()
	_, err := Apply(oneGroup(false), opts(ws, mapPrompter{quit: true}))
	if err != ErrUserQuit {
		t.Errorf("err = %v, want ErrUserQuit", err)
	}
}

func TestApply_EmptyWorkspace_Errors(t *testing.T) {
	if _, err := Apply(oneGroup(false), opts("", mapPrompter{def: true})); err == nil {
		t.Error("expected error for empty workspace")
	}
}

func TestCheckClone_States(t *testing.T) {
	base := t.TempDir()

	// absent
	if got := checkClone(filepath.Join(base, "nope"), "a/b"); got != stateAbsent {
		t.Errorf("absent: got %v", got)
	}

	// non-git, non-empty dir → mismatch
	junk := filepath.Join(base, "junk")
	os.MkdirAll(junk, 0o755)
	os.WriteFile(filepath.Join(junk, "f"), []byte("x"), 0o644)
	if got := checkClone(junk, "a/b"); got != stateMismatch {
		t.Errorf("junk dir: got %v, want mismatch", got)
	}

	// real git repo with a matching remote → matches
	if _, err := exec.LookPath("git"); err == nil {
		repo := filepath.Join(base, "repo")
		os.MkdirAll(repo, 0o755)
		for _, args := range [][]string{
			{"-C", repo, "init", "-q"},
			{"-C", repo, "remote", "add", "origin", "https://github.com/ChannelAssist/test-repo.git"},
		} {
			if out, err := exec.Command("git", args...).CombinedOutput(); err != nil {
				t.Fatalf("git %v: %v (%s)", args, err, out)
			}
		}
		if got := checkClone(repo, "ChannelAssist/test-repo"); got != stateMatches {
			t.Errorf("matching clone: got %v, want matches", got)
		}
		if got := checkClone(repo, "ChannelAssist/other-repo"); got != stateMismatch {
			t.Errorf("wrong-remote clone: got %v, want mismatch", got)
		}
	}
}
