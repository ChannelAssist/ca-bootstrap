//go:build windows

package install

import (
	"strings"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// buildWindowsCommand is pure string logic but lives in a windows-tagged
// file, so it only ever compiles/runs on Windows. These tests pin the
// command shape for each supported install type plus the unsupported-type
// error, executed on a real Windows runner.

func TestBuildWindowsCommand_Winget(t *testing.T) {
	cmd, err := buildWindowsCommand(manifest.InstallTarget{Type: "winget", ID: "Git.Git"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, want := range []string{
		"winget install", "--id Git.Git", "--silent",
		"--accept-source-agreements", "--accept-package-agreements",
	} {
		if !strings.Contains(cmd, want) {
			t.Errorf("winget command missing %q; got %q", want, cmd)
		}
	}
}

func TestBuildWindowsCommand_NpmGlobal(t *testing.T) {
	cmd, err := buildWindowsCommand(manifest.InstallTarget{Type: "npm", ID: "@github/copilot", Global: true})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(cmd, "npm install -g @github/copilot") {
		t.Errorf("expected a global npm install, got %q", cmd)
	}
}

func TestBuildWindowsCommand_NpmLocal(t *testing.T) {
	cmd, err := buildWindowsCommand(manifest.InstallTarget{Type: "npm", ID: "leftpad"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Contains(cmd, "-g") {
		t.Errorf("a non-global npm install must omit -g, got %q", cmd)
	}
}

func TestBuildWindowsCommand_Command(t *testing.T) {
	cmd, err := buildWindowsCommand(manifest.InstallTarget{Type: "command", Cmd: "choco install foo"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cmd != "choco install foo" {
		t.Errorf("command type must pass Cmd through verbatim, got %q", cmd)
	}
}

func TestBuildWindowsCommand_Unsupported(t *testing.T) {
	if _, err := buildWindowsCommand(manifest.InstallTarget{Type: "brew", ID: "foo"}); err == nil {
		t.Error("expected an error for an unsupported install type on windows")
	}
}
