// Package ghauth wraps the GitHub CLI (`gh`) authentication surface
// used by the setup wizard's gh-auth step (legacy step 30) and undo.
//
// A mock seam (env var CA_BOOTSTRAP_GH_MOCK) lets acceptance tests and
// unattended runs exercise the authed / unauthed / login-fail paths
// without a real `gh` binary or a browser device flow — mirroring the
// `mock` install type in internal/install.
package ghauth

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"time"
)

// statusTimeout bounds `gh auth status` so a wedged gh can't hang setup.
var statusTimeout = 8 * time.Second

// Status reports whether the user is authenticated to GitHub via gh.
// authed is false (with err nil) when gh is installed but logged out.
// err is non-nil only when gh is missing or the check itself failed.
func Status() (user string, authed bool, err error) {
	if mock := os.Getenv("CA_BOOTSTRAP_GH_MOCK"); mock != "" {
		return mockStatus(mock)
	}
	if _, err := exec.LookPath("gh"); err != nil {
		return "", false, errors.New("gh CLI not installed (install it via `ca-bootstrap repair --target gh`)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), statusTimeout)
	defer cancel()
	if err := exec.CommandContext(ctx, "gh", "auth", "status").Run(); err != nil {
		// Non-zero exit = not logged in (not an error condition).
		return "", false, nil
	}
	ctx2, cancel2 := context.WithTimeout(context.Background(), statusTimeout)
	defer cancel2()
	out, err := exec.CommandContext(ctx2, "gh", "api", "user", "--jq", ".login").Output()
	if err != nil {
		// Authenticated but couldn't read the login; still authed.
		return "", true, nil
	}
	return strings.TrimSpace(string(out)), true, nil
}

// Login runs the gh web/device auth flow over the given git protocol
// ("https" recommended). Interactive — opens a browser. Mocked when
// CA_BOOTSTRAP_GH_MOCK is set.
func Login(protocol string) error {
	if mock := os.Getenv("CA_BOOTSTRAP_GH_MOCK"); mock != "" {
		return mockLogin(mock)
	}
	cmd := exec.Command("gh", "auth", "login", "--git-protocol", protocol, "--web")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

// Logout reverses a login (used by undo's gh_auth_login reverser).
// Best-effort; a no-op when already logged out.
func Logout() error {
	if mock := os.Getenv("CA_BOOTSTRAP_GH_MOCK"); mock != "" {
		return nil
	}
	if _, err := exec.LookPath("gh"); err != nil {
		return nil
	}
	return exec.Command("gh", "auth", "logout").Run()
}

// mockStatus maps the env-var seam to a status result:
//
//	"authed:<user>" → logged in as <user>
//	"login-fail"    → logged out (so the login path is exercised)
//	anything else   → logged out
func mockStatus(mock string) (string, bool, error) {
	if u, ok := strings.CutPrefix(mock, "authed:"); ok {
		return u, true, nil
	}
	if mock == "gh-missing" {
		return "", false, errors.New("gh CLI not installed (mock)")
	}
	return "", false, nil
}

// mockLogin succeeds unless the seam is "login-fail".
func mockLogin(mock string) error {
	if mock == "login-fail" {
		return errors.New("mock gh auth login failed")
	}
	return nil
}
