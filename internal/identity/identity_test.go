package identity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSetWorkspaceIdentity_WritesGitConfig(t *testing.T) {
	workspace := t.TempDir()
	if err := SetWorkspaceIdentity(workspace, "Test User", "test@example.com"); err != nil {
		t.Fatalf("SetWorkspaceIdentity: %v", err)
	}
	cfgPath := filepath.Join(workspace, ".git", "config")
	body, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read %s: %v", cfgPath, err)
	}
	if !strings.Contains(string(body), "Test User") {
		t.Errorf("expected user.name in config. got:\n%s", body)
	}
	if !strings.Contains(string(body), "test@example.com") {
		t.Errorf("expected user.email in config. got:\n%s", body)
	}
}

func TestSetWorkspaceIdentity_CreatesGitDirIfMissing(t *testing.T) {
	workspace := t.TempDir()
	gitDir := filepath.Join(workspace, ".git")
	if _, err := os.Stat(gitDir); !os.IsNotExist(err) {
		t.Fatalf("expected .git to not exist before; stat err=%v", err)
	}
	if err := SetWorkspaceIdentity(workspace, "u", "e@x"); err != nil {
		t.Fatalf("SetWorkspaceIdentity: %v", err)
	}
	if _, err := os.Stat(gitDir); err != nil {
		t.Errorf("expected .git to exist after; err=%v", err)
	}
}

func TestSetWorkspaceIdentity_Idempotent(t *testing.T) {
	workspace := t.TempDir()
	for i := 0; i < 3; i++ {
		if err := SetWorkspaceIdentity(workspace, "u", "e@x"); err != nil {
			t.Fatalf("SetWorkspaceIdentity iter %d: %v", i, err)
		}
	}
	body, _ := os.ReadFile(filepath.Join(workspace, ".git", "config"))
	// Each key should appear at most once, even after 3 calls.
	if strings.Count(string(body), "name = u") > 1 {
		t.Errorf("user.name appears multiple times — not idempotent. got:\n%s", body)
	}
}

func TestGetWorkspaceIdentity_ReturnsWrittenValues(t *testing.T) {
	workspace := t.TempDir()
	if err := SetWorkspaceIdentity(workspace, "Alice", "alice@example.com"); err != nil {
		t.Fatalf("SetWorkspaceIdentity: %v", err)
	}
	name, email, err := GetWorkspaceIdentity(workspace)
	if err != nil {
		t.Fatalf("GetWorkspaceIdentity: %v", err)
	}
	if name != "Alice" {
		t.Errorf("name: want Alice, got %q", name)
	}
	if email != "alice@example.com" {
		t.Errorf("email: want alice@example.com, got %q", email)
	}
}

func TestGetWorkspaceIdentity_EmptyOnUnset(t *testing.T) {
	workspace := t.TempDir()
	// No SetWorkspaceIdentity call → config file doesn't exist.
	name, email, err := GetWorkspaceIdentity(workspace)
	if err != nil {
		t.Fatalf("GetWorkspaceIdentity: %v", err)
	}
	if name != "" || email != "" {
		t.Errorf("expected empty strings, got name=%q email=%q", name, email)
	}
}
