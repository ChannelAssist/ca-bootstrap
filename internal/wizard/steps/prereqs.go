package steps

import (
	"fmt"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/install"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/provision"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// Prereqs is wizard step 2 — detects tooling, then (when required tools are
// missing/below-min) offers to install them inline via the shared provision
// orchestrator, the same path `repair` uses. Tools that can't be installed
// fall back to the continue-with-drift gate.
type Prereqs struct{}

func (Prereqs) Title() string { return "Prerequisites" }

func (Prereqs) Run(ctx *wizard.Context) (string, error) {
	m, err := manifest.LoadDefault()
	if err != nil {
		return "", fmt.Errorf("load manifest: %w", err)
	}
	det := detect.Default()
	var ok, drift, missingOptional int
	for _, tool := range m.Tools {
		r := det.Probe(tool)
		switch detect.Classify(tool, r) {
		case detect.ClassOK:
			ok++
			fmt.Fprintf(ctx.Out, "    ✓ %s %s\n", tool.ID, r.Version)
		case detect.ClassDrift:
			drift++
			fmt.Fprintf(ctx.Out, "    ✗ %s missing-or-below-min\n", tool.ID)
		case detect.ClassMissingOptional:
			missingOptional++
			fmt.Fprintf(ctx.Out, "    ⚠ %s not found (optional)\n", tool.ID)
		}
	}
	fmt.Fprintf(ctx.Out, "  %d tools checked: %d ok, %d drift, %d missing-optional.\n", len(m.Tools), ok, drift, missingOptional)

	if drift == 0 {
		return fmt.Sprintf("All required tools OK (%d).", ok), nil
	}

	// Offer to install the missing required tools inline (the same install
	// path `repair` uses). Prompt key "prereqs.install_missing".
	missing := provision.Missing(m, det, false) // required-drift only
	opts := install.Options{Out: ctx.Out, Prompter: ctx.Prompt, ElevationAction: ctx.ElevationAction}
	summary, err := provision.InstallMissing(missing, det, ctx.Session, opts, "prereqs.install_missing")
	if err != nil {
		// Quit (→130) or a missing/invalid unattended key (→1). The wizard
		// maps prompt.ErrQuit and generic errors to the right exit codes.
		return "", err
	}
	if summary.Declined {
		// Elevation declined mid-install — abort like `repair` does (→130),
		// rather than silently dropping to the continue-with-drift gate.
		return "", prompt.ErrQuit
	}

	// InstallMissing already re-probed each tool post-install (its Installed
	// list = tools that now verify OK). If every missing tool installed, the
	// step succeeds — no need to re-scan the whole manifest.
	if summary.AllOK() {
		return "All required tools installed.", nil
	}

	// Still missing something (declined, failed, or no install method) — fall
	// back to the continue-with-drift gate (key "prereqs.continue_with_drift").
	cont, err := ctx.Prompt.YesNo("prereqs.continue_with_drift", "n")
	if err != nil {
		return "", err
	}
	if !cont {
		// Drift rejected — explicit error path the wizard maps to exit 2.
		return "", wizard.ErrDriftRejected
	}
	return "Acknowledged. Run `repair` later to install the rest.", nil
}
