package steps

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// stepPrompter answers folders.continue with a fixed value.
type stepPrompter struct{ yes bool }

func (p stepPrompter) YesNo(string, string) (bool, error) { return p.yes, nil }
func (p stepPrompter) Line(_, def string) (string, error) { return def, nil }
func (p stepPrompter) Quit() bool                         { return false }

// smallFoldersManifest points CA_BOOTSTRAP_FOLDERS at a one-folder
// manifest so the step's behaviour is deterministic in tests.
func smallFoldersManifest(t *testing.T) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "folders.yaml")
	body := "version: 1\nfolders:\n  - path: ca-tools\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CA_BOOTSTRAP_FOLDERS", p)
}

func TestFolders_Title(t *testing.T) {
	if got := (Folders{}).Title(); got != "Folder structure" {
		t.Errorf("Title = %q, want %q", got, "Folder structure")
	}
}

func TestFolders_WorkspaceEmpty_Errors(t *testing.T) {
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}}
	if _, err := (Folders{}).Run(ctx); err == nil {
		t.Error("expected error when workspace is unset")
	}
}

func TestFolders_WorkspaceNotAbsolute_Errors(t *testing.T) {
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}, Workspace: "relative/path"}
	if _, err := (Folders{}).Run(ctx); err == nil {
		t.Error("expected error when workspace is not absolute")
	}
}

func TestFolders_Declined_NoChanges(t *testing.T) {
	smallFoldersManifest(t)
	ws := t.TempDir()
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: false}, Workspace: ws}

	msg, err := (Folders{}).Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(strings.ToLower(msg), "declined") {
		t.Errorf("summary = %q, want a 'declined' message", msg)
	}
	if _, err := os.Stat(filepath.Join(ws, "ca-tools")); !os.IsNotExist(err) {
		t.Errorf("declining must not create folders; stat err=%v", err)
	}
}

func TestFolders_HappyPath_CreatesFolders(t *testing.T) {
	smallFoldersManifest(t)
	ws := t.TempDir()
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}, Workspace: ws}

	msg, err := (Folders{}).Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(msg, "created") {
		t.Errorf("summary = %q, want it to mention created count", msg)
	}
	if info, err := os.Stat(filepath.Join(ws, "ca-tools")); err != nil || !info.IsDir() {
		t.Errorf("ca-tools not created: err=%v", err)
	}
}
