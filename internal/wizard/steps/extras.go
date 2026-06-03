package steps

import (
	"errors"
	"fmt"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/extras"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// Extras is the optional finishing-touches wizard step (legacy step 80):
// VS Code workspace file + .vscode defaults, ca-claude-plugin link,
// ca-copilot usage notes, and a Windows-only WSL2 offer. Runs last.
type Extras struct{}

func (Extras) Title() string { return "Optional extras" }

func (Extras) Run(ctx *wizard.Context) (string, error) {
	if ctx.Workspace == "" {
		return "", errors.New("extras: workspace not set — earlier steps must run first")
	}
	summary, err := extras.Apply(extras.Options{
		Out:          ctx.Out,
		Prompter:     ctx.Prompt,
		WorkspaceDir: ctx.Workspace,
		Session:      ctx.Session,
	})
	if errors.Is(err, extras.ErrUserQuit) {
		return "", prompt.ErrQuit
	}
	if err != nil {
		return "", err
	}
	if len(summary.Actions) == 0 {
		return "No extras selected.", nil
	}
	return strings.Join(summary.Actions, ", ") + fmt.Sprintf(" (%d)", len(summary.Actions)), nil
}
