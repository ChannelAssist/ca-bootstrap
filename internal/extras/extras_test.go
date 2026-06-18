package extras

import (
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

// fakePrompter answers from a per-key map (fallback def), optional quit.
type fakePrompter struct {
	answers map[string]bool
	def     bool
	quit    bool
}

func (p fakePrompter) YesNo(q, _ string) (bool, error) {
	if p.quit {
		return false, prompt.ErrQuit
	}
	if v, ok := p.answers[q]; ok {
		return v, nil
	}
	return p.def, nil
}
func (p fakePrompter) Line(_, def string) (string, error) { return def, nil }
func (p fakePrompter) Quit() bool                         { return p.quit }

func baseOpts(t *testing.T, pr prompt.Prompter) Options {
	t.Helper()
	// Neutralize the Windows-only WSL offer so no extras test shells out to the
	// real `wsl` binary. On windows-latest, Apply → offerWSL → wslInstall runs
	// `wsl --install -d Ubuntu`, which blocks and hung the suite to the 10m test
	// timeout. "has-ubuntu" makes offerWSL report already-installed and return
	// without prompting or installing. (No-op on non-Windows, where offerWSL
	// early-returns anyway.)
	t.Setenv("CA_BOOTSTRAP_WSL_MOCK", "has-ubuntu")
	return Options{Out: io.Discard, Prompter: pr, WorkspaceDir: t.TempDir(), HomeDir: t.TempDir()}
}

func TestApply_AllDeclined(t *testing.T) {
	o := baseOpts(t, fakePrompter{def: false})
	s, err := Apply(o)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Actions) != 0 {
		t.Errorf("declined all: Actions=%v, want none", s.Actions)
	}
	if _, err := os.Stat(filepath.Join(o.WorkspaceDir, "ChannelAssist.code-workspace")); !os.IsNotExist(err) {
		t.Error("workspace file should not be written when declined")
	}
}

func TestApply_WorkspaceFile(t *testing.T) {
	o := baseOpts(t, fakePrompter{answers: map[string]bool{"extras.vscode_workspace_file": true}})
	// Seed a couple of clones to discover.
	for _, r := range []string{"ca-tools/ca-bootstrap", "ca-docs/keystone"} {
		os.MkdirAll(filepath.Join(o.WorkspaceDir, r, ".git"), 0o755)
	}
	s, err := Apply(o)
	if err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(o.WorkspaceDir, "ChannelAssist.code-workspace"))
	if err != nil {
		t.Fatalf("workspace file not written: %v", err)
	}
	for _, want := range []string{"ca-tools/ca-bootstrap", "ca-docs/keystone", "\"folders\""} {
		if !contains(string(body), want) {
			t.Errorf("workspace file missing %q:\n%s", want, body)
		}
	}
	if !hasAction(s, "code-workspace") {
		t.Error("expected code-workspace action")
	}
}

func TestApply_VSCodeDefaults(t *testing.T) {
	o := baseOpts(t, fakePrompter{answers: map[string]bool{"extras.vscode_defaults": true}})
	if _, err := Apply(o); err != nil {
		t.Fatal(err)
	}
	for _, name := range vscodeFiles {
		if _, err := os.Stat(filepath.Join(o.WorkspaceDir, ".vscode", name)); err != nil {
			t.Errorf(".vscode/%s not written: %v", name, err)
		}
	}
}

func TestApply_VSCodeDefaults_PreservesExisting(t *testing.T) {
	o := baseOpts(t, fakePrompter{answers: map[string]bool{"extras.vscode_defaults": true}})
	vs := filepath.Join(o.WorkspaceDir, ".vscode")
	os.MkdirAll(vs, 0o755)
	os.WriteFile(filepath.Join(vs, "settings.json"), []byte("USER EDIT"), 0o644)
	if _, err := Apply(o); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(filepath.Join(vs, "settings.json"))
	if string(body) != "USER EDIT" {
		t.Error("existing .vscode/settings.json must be preserved, not overwritten")
	}
}

func TestApply_ClaudePluginLink_Mock(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_SYMLINK_MOCK", "1")
	o := baseOpts(t, fakePrompter{def: true})
	repoPath := filepath.Join(o.WorkspaceDir, "ca-platform", "ca-claude-plugin")
	os.MkdirAll(repoPath, 0o755)
	s, err := Apply(o)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(o.HomeDir, ".claude", "plugins", "ca-claude-plugin")); err != nil {
		t.Errorf("plugin link not created: %v", err)
	}
	if !hasAction(s, "ca-claude-plugin") {
		t.Error("expected ca-claude-plugin action")
	}
}

func TestApply_ClaudePlugin_SkippedWhenNotCloned(t *testing.T) {
	o := baseOpts(t, fakePrompter{def: true})
	// no ca-claude-plugin dir → offer is skipped without prompting
	s, err := Apply(o)
	if err != nil {
		t.Fatal(err)
	}
	if hasAction(s, "ca-claude-plugin") {
		t.Error("ca-claude-plugin should be skipped when not cloned")
	}
}

func TestApply_Quit(t *testing.T) {
	if _, err := Apply(baseOpts(t, fakePrompter{quit: true})); err != ErrUserQuit {
		t.Errorf("err = %v, want ErrUserQuit", err)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || indexOf(s, sub) >= 0)
}
func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
func hasAction(s Summary, a string) bool {
	for _, x := range s.Actions {
		if x == a {
			return true
		}
	}
	return false
}
