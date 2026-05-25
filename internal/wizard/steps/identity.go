package steps

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/ChannelAssist/ca-bootstrap/internal/identity"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// Identity is wizard step 3 — prompt for name/email + write per-folder
// git config inside the workspace.
type Identity struct{}

func (Identity) Title() string { return "Git identity" }

func (Identity) Run(ctx *wizard.Context) (string, error) {
	// Resolve workspace: from context (if pre-set by setup.go for the
	// unattended path) or from prompting via the canonical key.
	workspace := ctx.Workspace
	if workspace == "" {
		ws, err := ctx.Prompt.Line("identity.workspace_root", defaultWorkspace())
		if err != nil {
			return "", err
		}
		workspace = ws
	}
	if workspace == "" {
		return "", fmt.Errorf("identity: workspace is empty")
	}
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		return "", fmt.Errorf("identity: mkdir workspace %s: %w", workspace, err)
	}
	ctx.Workspace = workspace

	// Pre-fill from existing workspace config if any.
	curName, curEmail, _ := identity.GetWorkspaceIdentity(workspace)
	name, err := ctx.Prompt.Line("identity.name", curName)
	if err != nil {
		return "", err
	}
	email, err := ctx.Prompt.Line("identity.email", curEmail)
	if err != nil {
		return "", err
	}
	if name == "" || email == "" {
		return "", fmt.Errorf("identity: name and email are required (got name=%q, email=%q)", name, email)
	}
	if err := identity.SetWorkspaceIdentity(workspace, name, email); err != nil {
		return "", err
	}
	cfgPath := filepath.Join(workspace, ".git", "config")
	_ = ctx.Session.Append(journal.Entry{
		Action: "identity_set",
		Target: cfgPath,
		Before: map[string]string{"user.name": curName, "user.email": curEmail},
		After:  map[string]string{"user.name": name, "user.email": email},
		Result: "ok",
	})
	return fmt.Sprintf("Wrote workspace .git/config (%s).", cfgPath), nil
}

// defaultWorkspace returns a sensible default for interactive setup —
// matches the PS-era convention.
func defaultWorkspace() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Documents", "Projects", "ChannelAssistDev")
}
