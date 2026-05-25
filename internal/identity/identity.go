// Package identity manages per-folder git identity configuration
// (spec §5 step 3, §2.B-4).
//
// Per-folder means we write to <workspace>/.git/config, NOT to the
// user's ~/.gitconfig — onboarding hires expect ChannelAssist
// identity to apply ONLY inside the workspace and any repos cloned
// inside it. Implementation note: when a user clones a repo INSIDE
// <workspace>, the resulting <workspace>/<repo>/.git takes precedence
// for that repo's identity per git's standard lookup, so the
// "degenerate" .git/ at the workspace root affects only git operations
// run from <workspace> itself (which is rare — users `cd` into repos).
package identity

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// SetWorkspaceIdentity writes user.name and user.email to the
// .git/config file inside workspaceRoot. Creates <workspaceRoot>/.git
// if missing. Idempotent — repeated calls update the values in place.
func SetWorkspaceIdentity(workspaceRoot, name, email string) error {
	gitDir := filepath.Join(workspaceRoot, ".git")
	if err := os.MkdirAll(gitDir, 0o755); err != nil {
		return fmt.Errorf("identity: mkdir %s: %w", gitDir, err)
	}
	cfgPath := filepath.Join(gitDir, "config")
	if err := setGitConfigKey(cfgPath, "user.name", name); err != nil {
		return err
	}
	if err := setGitConfigKey(cfgPath, "user.email", email); err != nil {
		return err
	}
	return nil
}

// GetWorkspaceIdentity reads the current name and email from the
// .git/config inside workspaceRoot. Returns empty strings (no error)
// if the config file doesn't exist or the keys are unset.
func GetWorkspaceIdentity(workspaceRoot string) (name, email string, err error) {
	cfgPath := filepath.Join(workspaceRoot, ".git", "config")
	if _, err := os.Stat(cfgPath); errors.Is(err, os.ErrNotExist) {
		return "", "", nil
	}
	n, err := readGitConfigKey(cfgPath, "user.name")
	if err != nil {
		return "", "", err
	}
	e, err := readGitConfigKey(cfgPath, "user.email")
	if err != nil {
		return n, "", err
	}
	return n, e, nil
}

// setGitConfigKey runs `git config --file <path> <key> <value>`.
// Idempotency comes for free — git config updates rather than appends.
func setGitConfigKey(cfgPath, key, value string) error {
	cmd := exec.Command("git", "config", "--file", cfgPath, key, value)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("identity: git config %s=%q: %w (output: %s)", key, value, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// readGitConfigKey runs `git config --file <path> --get <key>`. Returns
// "" with no error if the key is unset (git exits 1 in that case;
// we map that to empty).
func readGitConfigKey(cfgPath, key string) (string, error) {
	cmd := exec.Command("git", "config", "--file", cfgPath, "--get", key)
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
			// "key not found" — clean empty return.
			return "", nil
		}
		return "", fmt.Errorf("identity: git config --get %s: %w", key, err)
	}
	return strings.TrimSpace(string(out)), nil
}
