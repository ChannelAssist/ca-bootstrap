package reversers

import (
	"github.com/ChannelAssist/ca-bootstrap/internal/ghauth"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// GhAuthLogin reverses a gh_auth_login entry by logging out of gh.
// Account-level and affects every tool that uses gh, so it is opt-in
// via the same --include-tools gate as tool uninstalls: without it the
// login is left intact.
type GhAuthLogin struct{}

// Reverse implements undo.Reverser.
func (GhAuthLogin) Reverse(_ journal.Entry, opts undo.Options) undo.Outcome {
	if !opts.IncludeTools {
		return undo.Outcome{
			Status:  "skip",
			Details: "gh login left intact (account-level; pass --include-tools to `gh auth logout`)",
		}
	}
	if err := ghauth.Logout(); err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	return undo.Outcome{Status: "ok", Details: "Logged out of gh"}
}
