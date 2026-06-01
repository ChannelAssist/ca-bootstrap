package reversers

import (
	"github.com/ChannelAssist/ca-bootstrap/internal/install"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// ToolInstall reverses an install_success entry by running the
// matching uninstall through internal/install.Uninstall. Opt-in via
// undo.Options.IncludeTools — without it, the entry is listed but
// not actually reversed (other projects on the dev machine may depend
// on the installed tool). See spec §7.2.
type ToolInstall struct{}

// Reverse implements undo.Reverser.
func (ToolInstall) Reverse(e journal.Entry, opts undo.Options) undo.Outcome {
	// Spec §7.2 step 1 — missing method = fail loudly (can't dispatch).
	method := ""
	packageID := ""
	if e.After != nil {
		method = e.After["method"]
		packageID = e.After["package_id"]
	}
	if method == "" {
		return undo.Outcome{
			Status: "fail",
			Details: "install_success entry missing after.method — cannot dispatch uninstall; resolve manually for " +
				e.Target,
		}
	}

	// Step 2 — opt-in gate.
	if !opts.IncludeTools {
		return undo.Outcome{
			Status:  "skip",
			Details: e.Target + " install kept (pass --include-tools to uninstall)",
		}
	}

	// Step 3 — per-tool consent. Driven by an undo.uninstall.<tool>
	// answer in unattended mode; interactively a YesNo prompt.
	if opts.Prompter != nil {
		key := "undo.uninstall." + e.Target
		consent, err := opts.Prompter.YesNo(key, "n")
		if err != nil {
			return undo.Outcome{Status: "skip", Details: "user quit at consent prompt"}
		}
		if !consent {
			return undo.Outcome{Status: "skip", Details: "user declined to uninstall " + e.Target}
		}
	}

	// Step 4 — dispatch.
	if pkg := packageID; pkg == "" {
		// Fall back to the tool ID when package_id wasn't recorded.
		// Manifests usually set them equal, so the fallback gives
		// reasonable behavior without obscuring the missing field.
		pkg = e.Target
		packageID = pkg
	}
	if err := install.Uninstall(method, packageID); err != nil {
		return undo.Outcome{Status: "fail", Details: err.Error()}
	}
	return undo.Outcome{
		Status:  "ok",
		Details: "Uninstalled " + e.Target + " via " + method,
	}
}
