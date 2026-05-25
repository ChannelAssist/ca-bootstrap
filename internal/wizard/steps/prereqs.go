package steps

import (
	"fmt"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// Prereqs is wizard step 2 — uses detect+manifest to report drift,
// then prompts whether to continue if drift was found.
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
		switch classifyTool(tool, r) {
		case classOK:
			ok++
			fmt.Fprintf(ctx.Out, "    ✓ %s %s\n", tool.ID, r.Version)
		case classDrift:
			drift++
			fmt.Fprintf(ctx.Out, "    ✗ %s missing-or-below-min  → run `ca-bootstrap repair --target %s` later\n", tool.ID, tool.ID)
		case classMissingOptional:
			missingOptional++
			fmt.Fprintf(ctx.Out, "    ⚠ %s not found (optional)\n", tool.ID)
		}
	}
	fmt.Fprintf(ctx.Out, "  %d tools checked: %d ok, %d drift, %d missing-optional.\n", len(m.Tools), ok, drift, missingOptional)

	if drift == 0 {
		return fmt.Sprintf("All required tools OK (%d).", ok), nil
	}
	// Prompt key: "prereqs.continue_with_drift" (matches unattended YAML).
	cont, err := ctx.Prompt.YesNo("prereqs.continue_with_drift", "n")
	if err != nil {
		return "", err
	}
	if !cont {
		// Drift rejected — explicit error path the wizard maps to exit 2.
		return "", wizard.ErrDriftRejected
	}
	// Drift acknowledged.
	_ = prompt.ErrQuit // keep import meaningful — Quit handled by Prompter.YesNo above
	return "Acknowledged. Run `repair` (alpha.3) to install missing tools.", nil
}

type classification int

const (
	classOK classification = iota
	classDrift
	classMissingOptional
)

// classifyTool — mirrors internal/cli/doctor.go classify(); duplicated
// here to avoid a cyclic dep (cli → wizard → cli would form one).
// Refactor candidate: move to internal/detect or a shared utility
// pkg in alpha.3.
func classifyTool(t manifest.Tool, r detect.Result) classification {
	if !r.Found {
		if t.Optional {
			return classMissingOptional
		}
		return classDrift
	}
	if t.MinVersion != "" {
		ok, err := detect.VersionAtLeast(r.Version, t.MinVersion)
		if err != nil || !ok {
			if t.Optional {
				return classMissingOptional
			}
			return classDrift
		}
	}
	return classOK
}
