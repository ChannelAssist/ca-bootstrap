package steps

import (
	"errors"
	"fmt"
	"path/filepath"

	"github.com/ChannelAssist/ca-bootstrap/internal/folders"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// Folders is wizard step 4 (alpha.5) — reads manifest/folders.yaml,
// creates required folders under the workspace, migrates renamed_from
// predecessors, and seeds per-folder READMEs. Optional folders are
// only touched when already on disk.
type Folders struct{}

// Title returns the step header text. Matches the PS-era "Folder
// structure" label so onboarding hires see consistent UX. Tests assert
// on this literal string to distinguish a real folders step from
// incidental output (e.g. /var/folders/... paths on macOS).
func (Folders) Title() string { return "Folder structure" }

func (Folders) Run(ctx *wizard.Context) (string, error) {
	if ctx.Workspace == "" {
		return "", errors.New("folders: workspace not set — identity step must run first")
	}
	if !filepath.IsAbs(ctx.Workspace) {
		return "", fmt.Errorf("folders: workspace %q is not absolute", ctx.Workspace)
	}

	m, err := manifest.LoadFoldersDefault()
	if err != nil {
		return "", fmt.Errorf("folders: load manifest: %w", err)
	}

	// Up-front Continue? confirm. Default yes. Unattended reads
	// `folders.continue` from the config; a `false` here means skip
	// the whole step (exit 0, no journal mutations).
	proceed, perr := ctx.Prompt.YesNo("folders.continue", "y")
	if errors.Is(perr, prompt.ErrQuit) {
		return "", perr
	}
	if perr != nil {
		return "", fmt.Errorf("folders: prompt: %w", perr)
	}
	if !proceed {
		return "Folders step declined (no changes).", nil
	}

	summary, err := folders.Apply(m, folders.Options{
		Out:          ctx.Out,
		WorkspaceDir: ctx.Workspace,
		Session:      ctx.Session,
	})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%d created, %d kept, %d renamed, %d README(s) seeded",
		summary.Created, summary.Kept, summary.Renamed, summary.SeededReadmes), nil
}
