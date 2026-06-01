// Package reversers holds the per-action reversers for the alpha.4
// undo command. Each reverser implements undo.Reverser; the CLI layer
// builds the dispatch map and passes it into undo.Run.
//
// Two reversers ship in alpha.4 (spec §2.B.1, §7): Identity (for
// identity_set entries) and ToolInstall (for install_success
// entries). Future alphas add reversers as new producing actions land.
package reversers

import (
	"path/filepath"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/identity"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// Identity reverses an identity_set entry by restoring the workspace
// .git/config's [user] block to the pre-set state (or removing it
// entirely when the Before snapshot was empty).
type Identity struct{}

// Reverse implements undo.Reverser. See spec §7.1.
func (Identity) Reverse(e journal.Entry, _ undo.Options) undo.Outcome {
	// Target is the full path to .git/config; recover the workspace
	// root from it.
	if e.Target == "" {
		return undo.Outcome{Status: "fail", Details: "identity_set entry missing target"}
	}
	// e.Target is workspaceRoot/.git/config — walk up two levels.
	gitDir := filepath.Dir(e.Target)
	workspaceRoot := filepath.Dir(gitDir)

	// Did the target file actually exist? If not, the workspace
	// .git/config has been removed by some other means — nothing to
	// reverse.
	beforeName := e.Before["user.name"]
	beforeEmail := e.Before["user.email"]

	if strings.TrimSpace(beforeName) == "" && strings.TrimSpace(beforeEmail) == "" {
		// Empty Before — identity was set on a clean workspace.
		// Remove the keys (and the [user] section if empty afterward).
		if err := identity.ClearWorkspaceIdentity(workspaceRoot); err != nil {
			return undo.Outcome{Status: "fail", Details: err.Error()}
		}
		return undo.Outcome{Status: "ok", Details: "Removed [user] block from workspace .git/config"}
	}

	if err := identity.RestoreWorkspaceIdentity(workspaceRoot, beforeName, beforeEmail); err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	return undo.Outcome{
		Status: "ok",
		Details: "Restored previous identity (user.name=" + beforeName +
			", user.email=" + beforeEmail + ")",
	}
}
