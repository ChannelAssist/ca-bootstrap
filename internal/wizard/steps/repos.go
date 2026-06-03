package steps

import (
	"errors"
	"fmt"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/repos"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// Repos is the repo-cloning wizard step (legacy step 60). Runs after
// folders: reads manifest/repos.yaml and clones each group's repos into
// the workspace, prompting per group (and per opt-in repo).
type Repos struct{}

func (Repos) Title() string { return "Repository cloning" }

func (Repos) Run(ctx *wizard.Context) (string, error) {
	if ctx.Workspace == "" {
		return "", errors.New("repos: workspace not set — earlier steps must run first")
	}

	m, err := manifest.LoadReposDefault()
	if err != nil {
		return "", fmt.Errorf("repos: load manifest: %w", err)
	}

	summary, err := repos.Apply(m, repos.Options{
		Out:          ctx.Out,
		Prompter:     ctx.Prompt,
		WorkspaceDir: ctx.Workspace,
		Session:      ctx.Session,
	})
	if errors.Is(err, repos.ErrUserQuit) {
		return "", prompt.ErrQuit
	}
	if err != nil {
		return "", err
	}

	msg := fmt.Sprintf("%d cloned, %d already-present, %d skipped, %d mismatched, %d failed",
		summary.Cloned, summary.Fetched, summary.Skipped, summary.Mismatch, summary.Failed)
	if summary.Failed > 0 {
		// Non-fatal: surface failures but let setup complete.
		fmt.Fprintf(ctx.Out, "  ⚠ %d repo(s) failed to clone:\n", summary.Failed)
		for _, f := range summary.Failures {
			fmt.Fprintf(ctx.Out, "    • %s\n", f)
		}
	}
	return msg, nil
}
