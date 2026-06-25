package steps

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

func TestExtras_Title(t *testing.T) {
	if (Extras{}).Title() != "Optional extras" {
		t.Errorf("Title = %q", (Extras{}).Title())
	}
}

func TestExtras_WorkspaceEmpty_Errors(t *testing.T) {
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: false}}
	if _, err := (Extras{}).Run(ctx); err == nil {
		t.Error("expected error when workspace unset")
	}
}

func TestExtras_AllDeclined(t *testing.T) {
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: false}, Workspace: t.TempDir()}
	msg, err := (Extras{}).Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(strings.ToLower(msg), "no extras") {
		t.Errorf("summary = %q, want 'No extras selected.'", msg)
	}
}

func TestExtras_Accepted(t *testing.T) {
	// Answers "yes" to every offer; on Windows that drives the extras WSL
	// offer into the real, blocking `wsl --install`. Mock WSL as already
	// present so the offer is a no-op (otherwise the test hangs to the 10m
	// timeout on the windows-latest runner).
	t.Setenv("CA_BOOTSTRAP_WSL_MOCK", "has-ubuntu")
	ws := t.TempDir()
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}, Workspace: ws}
	msg, err := (Extras{}).Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(msg, "code-workspace") {
		t.Errorf("summary = %q, want it to mention code-workspace", msg)
	}
	if _, err := os.Stat(filepath.Join(ws, "ChannelAssist.code-workspace")); err != nil {
		t.Errorf("workspace file not written: %v", err)
	}
}
