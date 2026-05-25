// Package install dispatches tool installation per platform, reading
// the manifest's install block (spec §4-§5). The mock install type
// (type: mock) short-circuits to canned results so acceptance tests
// can exercise repair without mutating the real system.
//
// **DESIGN INVARIANT**: install never elevates silently. Commands that
// need sudo/UAC go through the elevation decision (prompt / allow /
// deny / skip) per spec §2.B-2.
package install

import (
	"fmt"
	"io"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

// Status is the outcome of an install attempt.
type Status int

const (
	Installed     Status = iota // installed successfully
	Failed                      // installer returned an error
	Skipped                     // user chose to skip (elevation skip)
	Declined                    // user declined elevation (→ repair exits 130)
	NotApplicable               // no install target for this OS
)

// Result captures one install attempt.
type Result struct {
	Tool      string
	Status    Status
	Err       error
	ManualCmd string // populated when Status==Skipped — the command the user should run
}

// Options carries dependencies + the elevation decision into Install.
type Options struct {
	Out      io.Writer
	Prompter prompt.Prompter
	// ElevationAction is "allow" | "deny" | "skip" | "prompt" (or "").
	// Empty/"prompt" means ask interactively via Prompter.
	ElevationAction string
}

// Installer dispatches an install for the current platform.
type Installer interface {
	Install(t manifest.Tool, opts Options) Result
}

// targetExecutor is the platform-specific hook: given a resolved
// InstallTarget, actually run it. Implemented in install_unix.go /
// install_windows.go.
type targetExecutor interface {
	exec(t manifest.Tool, target manifest.InstallTarget, elevated bool, opts Options) Result
	// pick returns the InstallTarget for the current OS/distro, or nil.
	pick(spec manifest.InstallSpec) *manifest.InstallTarget
}

// genericInstaller wires the shared flow (mock handling + elevation
// decision) to a platform-specific targetExecutor.
type genericInstaller struct {
	exe targetExecutor
}

func (g genericInstaller) Install(t manifest.Tool, opts Options) Result {
	target := g.exe.pick(t.Install)
	if target == nil {
		return Result{Tool: t.ID, Status: NotApplicable,
			Err: fmt.Errorf("no install target for this platform")}
	}

	// Mock short-circuit — used by acceptance tests.
	if target.Type == "mock" {
		return g.installMock(t, *target, opts)
	}

	needsElev := NeedsElevation(*target) || t.RequiresElevation
	if needsElev {
		switch g.decideElevation(t, *target, opts) {
		case elevDeny:
			return Result{Tool: t.ID, Status: Declined}
		case elevSkip:
			return Result{Tool: t.ID, Status: Skipped, ManualCmd: manualCommand(*target)}
		case elevAllow:
			return g.exe.exec(t, *target, true, opts)
		}
	}
	return g.exe.exec(t, *target, false, opts)
}

// installMock returns canned results for the `mock` install type.
func (g genericInstaller) installMock(t manifest.Tool, target manifest.InstallTarget, opts Options) Result {
	switch target.ID {
	case "fail":
		return Result{Tool: t.ID, Status: Failed, Err: fmt.Errorf("mock install failed")}
	case "success":
		return Result{Tool: t.ID, Status: Installed}
	case "needs-elevation":
		switch g.decideElevationRaw(opts) {
		case elevDeny:
			return Result{Tool: t.ID, Status: Declined}
		case elevSkip:
			return Result{Tool: t.ID, Status: Skipped, ManualCmd: "(mock) run the elevated install manually"}
		default: // allow
			return Result{Tool: t.ID, Status: Installed}
		}
	default:
		return Result{Tool: t.ID, Status: Failed, Err: fmt.Errorf("unknown mock id %q", target.ID)}
	}
}

type elevChoice int

const (
	elevAllow elevChoice = iota
	elevDeny
	elevSkip
)

// decideElevation resolves how to handle an elevation-needing install.
func (g genericInstaller) decideElevation(t manifest.Tool, target manifest.InstallTarget, opts Options) elevChoice {
	if c, ok := decideFromAction(opts.ElevationAction); ok {
		return c
	}
	// Interactive: show the command + a 3-way prompt.
	fmt.Fprintf(opts.Out, "  This requires elevated privileges.\n  Command: %s\n", manualCommand(target))
	return promptElevation(opts.Prompter)
}

// decideElevationRaw is the prompt path for the mock flow (no command text).
func (g genericInstaller) decideElevationRaw(opts Options) elevChoice {
	if c, ok := decideFromAction(opts.ElevationAction); ok {
		return c
	}
	return promptElevation(opts.Prompter)
}

func decideFromAction(action string) (elevChoice, bool) {
	switch strings.ToLower(strings.TrimSpace(action)) {
	case "allow", "yes", "y":
		return elevAllow, true
	case "deny", "no", "n":
		return elevDeny, true
	case "skip":
		return elevSkip, true
	}
	return elevAllow, false
}

// promptElevation asks a 3-way [Y/n/skip] question via the Prompter.
// Maps the two-method Prompter interface onto three outcomes: first a
// YesNo for allow-vs-not; on "no", a second YesNo for skip-vs-deny.
func promptElevation(p prompt.Prompter) elevChoice {
	allow, err := p.YesNo("repair.allow_elevation", "y")
	if err == nil && allow {
		return elevAllow
	}
	if p.Quit() {
		return elevDeny
	}
	skip, _ := p.YesNo("repair.skip_to_manual", "y")
	if skip {
		return elevSkip
	}
	return elevDeny
}
