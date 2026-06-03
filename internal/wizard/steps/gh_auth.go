package steps

import (
	"errors"
	"fmt"

	"github.com/ChannelAssist/ca-bootstrap/internal/ghauth"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// GhAuth is the GitHub-authentication wizard step (legacy step 30). It
// runs after prereqs and before repo cloning, which needs an
// authenticated gh. Idempotent: an already-authenticated user is a
// positive ✓, not a skip.
type GhAuth struct{}

func (GhAuth) Title() string { return "GitHub authentication" }

func (GhAuth) Run(ctx *wizard.Context) (string, error) {
	user, authed, err := ghauth.Status()
	if err != nil {
		// gh not installed (prereqs already flagged it). Don't hard-fail
		// the whole wizard — identity/folders are still useful; cloning
		// will be unavailable until gh is installed + authed.
		fmt.Fprintf(ctx.Out, "    ⚠ %v\n", err)
		return "Skipped — gh unavailable; cloning will be limited.", nil
	}
	if authed {
		if user == "" {
			return "Authenticated to GitHub.", nil
		}
		fmt.Fprintf(ctx.Out, "    ✓ Logged in as %s\n", user)
		return "Logged in as " + user, nil
	}

	fmt.Fprintln(ctx.Out, "    You are not signed in to gh. The web flow opens a browser tab")
	fmt.Fprintln(ctx.Out, "    to sign in to GitHub (HTTPS protocol — no SSH key setup needed).")
	proceed, perr := ctx.Prompt.YesNo("gh-auth.login", "y")
	if errors.Is(perr, prompt.ErrQuit) {
		return "", perr
	}
	if perr != nil {
		return "", fmt.Errorf("gh-auth: prompt: %w", perr)
	}
	if !proceed {
		return "Skipped — run `gh auth login` before cloning.", nil
	}

	if err := ghauth.Login("https"); err != nil {
		return "", fmt.Errorf("gh-auth: login: %w", err)
	}
	// Re-read the login for the journal + summary.
	user, _, _ = ghauth.Status()
	if ctx.Session != nil {
		_ = ctx.Session.Append(journal.Entry{
			Action: "gh_auth_login",
			Target: user,
			After:  map[string]string{"protocol": "https"},
			Result: "ok",
		})
	}
	if user == "" {
		return "Signed in to GitHub.", nil
	}
	return "Logged in as " + user, nil
}
