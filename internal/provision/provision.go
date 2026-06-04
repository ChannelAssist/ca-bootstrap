// Package provision is the shared "install what's missing" orchestrator
// used by both `repair` (no --target) and the setup wizard's prerequisites
// step. It scans the manifest with a Detector, collects the tools that are
// missing or below their minimum version, asks a single batch confirmation,
// then installs each through the install dispatch — journaling every step so
// `undo` can reverse it.
//
// This is the single source of truth for "fix the tools," so `repair` and
// `setup` behave identically (alpha.6, AB#40272). Before alpha.6, `setup`
// only detected drift and told the user to run `repair` by hand, and `repair`
// required a --target id — neither actually fixed things end to end.
package provision

import (
	"fmt"
	"io"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/install"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// Missing scans the manifest with det and returns the tools that need
// installing — required tools that are missing/below-min are always included
// (they classify as ClassDrift); optional tools that are absent/below-min
// (ClassMissingOptional) are included only when includeOptional is true.
//
// Order follows the manifest so output is stable and predictable.
func Missing(m *manifest.Manifest, det detect.Detector, includeOptional bool) []manifest.Tool {
	var out []manifest.Tool
	for _, t := range m.Tools {
		switch detect.Classify(t, det.Probe(t)) {
		case detect.ClassDrift:
			out = append(out, t)
		case detect.ClassMissingOptional:
			if includeOptional {
				out = append(out, t)
			}
		}
	}
	return out
}

// Summary reports the outcome of an InstallMissing run.
type Summary struct {
	Installed []string // verified present after install
	Failed    []string // install errored, or ran but still shows drift, or no install target
	Skipped   []string // user declined the batch, or per-tool skip-to-manual
	Declined  bool     // elevation was declined → caller may exit 130
}

// AllOK reports whether every targeted tool ended up installed (nothing
// failed, skipped, or declined).
func (s Summary) AllOK() bool {
	return len(s.Failed) == 0 && len(s.Skipped) == 0 && !s.Declined
}

// InstallMissing installs every tool in tools through the platform install
// dispatch, after a single batch confirmation keyed by confirmKey (default
// "y"). Each tool is journaled: install_attempt at the start, then
// install_success (with after.method/after.package_id so undo can reverse it)
// when post-install detection confirms it, or install_failed otherwise.
//
// sess may be nil (no journaling — e.g. a dry inspection). opts supplies the
// output writer, prompter, and elevation action. Returns a Summary; the
// caller maps it to an exit code.
func InstallMissing(tools []manifest.Tool, det detect.Detector, sess *journal.Session, opts install.Options, confirmKey string) Summary {
	var s Summary
	if len(tools) == 0 {
		return s
	}
	out := opts.Out
	if out == nil {
		out = io.Discard
	}

	fmt.Fprintf(out, "  %d tool(s) missing or below minimum:\n", len(tools))
	for _, t := range tools {
		fmt.Fprintf(out, "    - %s (%s)\n", t.ID, displayName(t))
	}

	ok, err := opts.Prompter.YesNo(confirmKey, "y")
	if err != nil || !ok {
		for _, t := range tools {
			s.Skipped = append(s.Skipped, t.ID)
		}
		fmt.Fprintln(out, "  Skipped install; nothing changed.")
		return s
	}

	total := len(tools)
	for i, t := range tools {
		fmt.Fprintf(out, "\n  [%d/%d] Installing %s...\n", i+1, total, t.ID)
		if sess != nil {
			_ = sess.Append(journal.Entry{Action: "install_attempt", Target: t.ID, Result: "start"})
		}

		res := install.Default().Install(t, opts)
		switch res.Status {
		case install.Installed:
			if detect.Classify(t, det.Probe(t)) == detect.ClassOK {
				if sess != nil {
					_ = sess.Append(journal.Entry{
						Action: "install_success",
						Target: t.ID,
						After:  map[string]string{"method": res.Method, "package_id": res.PackageID},
						Result: "ok",
					})
				}
				fmt.Fprintf(out, "    installed %s.\n", t.ID)
				s.Installed = append(s.Installed, t.ID)
			} else {
				if sess != nil {
					_ = sess.Append(journal.Entry{Action: "install_failed", Target: t.ID, Result: "verify_failed"})
				}
				fmt.Fprintf(out, "    %s install ran but it still shows missing/below-min.\n", t.ID)
				s.Failed = append(s.Failed, t.ID)
			}
		case install.Failed:
			if sess != nil {
				_ = sess.Append(journal.Entry{Action: "install_failed", Target: t.ID, Result: "error"})
			}
			fmt.Fprintf(out, "    %s install failed: %v\n", t.ID, res.Err)
			s.Failed = append(s.Failed, t.ID)
		case install.Declined:
			if sess != nil {
				_ = sess.Append(journal.Entry{Action: "install_skipped", Target: t.ID, Result: "elevation_declined"})
			}
			fmt.Fprintln(out, "    elevation declined — stopping.")
			s.Declined = true
			s.Skipped = append(s.Skipped, t.ID)
			return s // a declined elevation aborts the batch
		case install.Skipped:
			if sess != nil {
				_ = sess.Append(journal.Entry{Action: "manual_install_required", Target: t.ID, Result: "skipped"})
			}
			fmt.Fprintf(out, "    %s needs a manual step: %s\n", t.ID, res.ManualCmd)
			s.Skipped = append(s.Skipped, t.ID)
		case install.NotApplicable:
			fmt.Fprintf(out, "    %s has no install method for this platform — install it manually.\n", t.ID)
			s.Failed = append(s.Failed, t.ID)
		}
	}
	return s
}

func displayName(t manifest.Tool) string {
	if t.Name != "" {
		return t.Name
	}
	return t.ID
}
