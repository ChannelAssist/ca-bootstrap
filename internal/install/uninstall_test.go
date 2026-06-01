package install

import (
	"strings"
	"testing"
)

// TestUninstall_RejectsFlagLikePackageID guards against argv flag
// smuggling: a package id beginning with '-' must be refused before
// any package manager is invoked.
func TestUninstall_RejectsFlagLikePackageID(t *testing.T) {
	err := Uninstall("apt", "--allow-anything")
	if err == nil {
		t.Fatal("expected error for flag-like package id")
	}
	if !strings.Contains(err.Error(), "manual removal required") {
		t.Errorf("error = %q, want it to mention manual removal required", err)
	}
}

func TestBuildUninstallCommand_RejectsLeadingDash(t *testing.T) {
	for _, m := range []string{"winget", "brew", "apt", "dnf", "snap", "npm"} {
		cmd, _ := buildUninstallCommand(m, "-rf")
		if cmd != "" {
			t.Errorf("%s: expected empty cmd for flag-like id, got %q", m, cmd)
		}
	}
}

// TestBuildUninstallCommand_OptionTerminator confirms the package
// managers that honor "--" get it immediately before the package id.
func TestBuildUninstallCommand_OptionTerminator(t *testing.T) {
	for _, m := range []string{"apt", "dnf", "npm"} {
		_, args := buildUninstallCommand(m, "jq")
		if len(args) < 2 || args[len(args)-2] != "--" || args[len(args)-1] != "jq" {
			t.Errorf("%s: expected args to end with [\"--\", \"jq\"], got %v", m, args)
		}
	}
}

// TestBuildUninstallCommand_NormalIDStillWorks ensures a well-formed
// package id dispatches as before.
func TestBuildUninstallCommand_NormalIDStillWorks(t *testing.T) {
	cmd, args := buildUninstallCommand("brew", "ripgrep")
	if cmd != "brew" || len(args) == 0 || args[len(args)-1] != "ripgrep" {
		t.Errorf("brew/ripgrep dispatch broken: cmd=%q args=%v", cmd, args)
	}
}
