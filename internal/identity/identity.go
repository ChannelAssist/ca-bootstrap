// Package identity manages per-folder git identity configuration
// (spec §5 step 3 and §2.B-4).
//
// Per-folder means we write to <workspace>/.git/config, NOT to the
// user's global ~/.gitconfig — onboarding hires expect ChannelAssist
// identity to apply ONLY inside the workspace.
package identity

import "fmt"

// SetWorkspaceIdentity writes user.name and user.email to the .git/config
// file inside workspaceRoot. Stub — Task 5.
func SetWorkspaceIdentity(workspaceRoot, name, email string) error {
	return fmt.Errorf("identity: SetWorkspaceIdentity not implemented (Task 5)")
}

// GetWorkspaceIdentity reads the current name and email from the
// .git/config inside workspaceRoot, returning empty strings if unset.
// Stub — Task 5.
func GetWorkspaceIdentity(workspaceRoot string) (name, email string, err error) {
	return "", "", fmt.Errorf("identity: GetWorkspaceIdentity not implemented (Task 5)")
}
