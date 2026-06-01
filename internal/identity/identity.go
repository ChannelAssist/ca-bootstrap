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
	"bytes"
	"errors"
	"fmt"
	"io"
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

// RestoreWorkspaceIdentity overwrites the workspace .git/config [user]
// block with the supplied name and email. Used by alpha.4 undo to
// reverse an identity_set entry whose Before recorded a prior identity.
//
// If both name and email are empty, falls through to
// ClearWorkspaceIdentity (the "no prior identity" case — undo should
// remove the keys rather than write empty strings).
//
// If the workspace .git/config does not exist, returns nil (noop —
// nothing to restore).
func RestoreWorkspaceIdentity(workspaceRoot, name, email string) error {
	cfgPath := filepath.Join(workspaceRoot, ".git", "config")
	if _, err := os.Stat(cfgPath); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if name == "" && email == "" {
		return ClearWorkspaceIdentity(workspaceRoot)
	}
	if err := setGitConfigKey(cfgPath, "user.name", name); err != nil {
		return err
	}
	if err := setGitConfigKey(cfgPath, "user.email", email); err != nil {
		return err
	}
	return nil
}

// ClearWorkspaceIdentity removes user.name and user.email from the
// workspace .git/config. Used by alpha.4 undo when an identity_set
// entry's Before is empty (i.e., the identity was set on a clean
// workspace; undo should remove the keys, not restore empty values).
//
// After the unset, the [user] section header may remain with no keys
// underneath. We strip an empty trailing [user] section as a tidiness
// pass so the file matches "as-if identity_set never ran" — git is
// happy with either form but tests assert on the raw file body.
func ClearWorkspaceIdentity(workspaceRoot string) error {
	cfgPath := filepath.Join(workspaceRoot, ".git", "config")
	if _, err := os.Stat(cfgPath); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	// Best-effort unsets — errors when keys are already unset are
	// fine (git exits 5 for "key not found in --unset"). Treat as noop.
	_ = exec.Command("git", "config", "--file", cfgPath, "--unset", "user.name").Run()
	_ = exec.Command("git", "config", "--file", cfgPath, "--unset", "user.email").Run()
	// Tidy: drop an empty [user] section header (no keys under it).
	return tidyEmptySection(cfgPath, "user")
}

// tidyEmptySection rewrites cfgPath, removing a section header line
// (e.g. `[user]`) if no key=value lines follow it before the next
// section or EOF. Leaves all other content untouched.
func tidyEmptySection(cfgPath, section string) error {
	f, err := os.Open(cfgPath)
	if err != nil {
		return fmt.Errorf("identity: open %s: %w", cfgPath, err)
	}
	body, err := io.ReadAll(f)
	_ = f.Close()
	if err != nil {
		return fmt.Errorf("identity: read %s: %w", cfgPath, err)
	}

	wantHeader := []byte("[" + section + "]")
	lines := bytes.Split(body, []byte("\n"))
	out := make([][]byte, 0, len(lines))
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if bytes.Equal(bytes.TrimSpace(line), wantHeader) {
			// Peek forward: if every line until the next section or
			// EOF is blank, this section is empty — drop the header.
			empty := true
			for j := i + 1; j < len(lines); j++ {
				peek := bytes.TrimSpace(lines[j])
				if len(peek) == 0 {
					continue
				}
				if bytes.HasPrefix(peek, []byte("[")) {
					break // next section
				}
				empty = false
				break
			}
			if empty {
				continue // drop the header
			}
		}
		out = append(out, line)
	}
	return os.WriteFile(cfgPath, bytes.Join(out, []byte("\n")), 0o644)
}
