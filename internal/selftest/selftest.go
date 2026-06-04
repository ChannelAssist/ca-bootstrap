// Package selftest implements doctor's capability self-test (alpha.7,
// AB#40270). Where detect answers "is tool X present at version Y",
// selftest answers "can this host actually DO the operations bootstrap
// depends on" — write the workspace, create a junction/symlink, reach the
// package manager, and authenticate to GitHub.
//
// The probes here are the cross-platform Go port of the real legs the
// PowerShell smoke harness exercised (dist/smoke-windows.ps1), so doctor and
// the smoke can share one source of truth. Every safe probe is
// non-destructive or self-reversing; the genuinely invasive install→uninstall
// round-trip lives in InstallRoundTrip and only runs under doctor --full.
package selftest

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/ghauth"
	"github.com/ChannelAssist/ca-bootstrap/internal/install"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

// Status is a probe outcome.
type Status string

const (
	StatusOK   Status = "ok"
	StatusFail Status = "fail"
	StatusSkip Status = "skip"
)

// Result is one capability probe's outcome.
type Result struct {
	Name   string
	Status Status
	Detail string
}

// Options configures a self-test run.
type Options struct {
	WorkspaceDir    string             // dir whose writability is tested; "" → os.TempDir()
	Full            bool               // also run the install→uninstall round-trip
	ProbeToolID     string             // --full probe tool id; "" → default ("kubectl" or $CA_BOOTSTRAP_SELFTEST_PROBE)
	Manifest        *manifest.Manifest // needed only for the --full round-trip
	Detector        detect.Detector    // needed only for the --full round-trip (absent-only guard)
	Out             io.Writer
	Prompter        prompt.Prompter
	ElevationAction string
}

// probeTimeout bounds the package-manager version command.
var probeTimeout = 15 * time.Second

// Run executes the safe capability probes and, when opts.Full is set, the
// install→uninstall round-trip. Returns one Result per probe, in a stable
// order.
func Run(opts Options) []Result {
	results := Capabilities(opts)
	if opts.Full {
		results = append(results, InstallRoundTrip(opts))
	}
	return results
}

// Capabilities runs the four safe, self-reversing probes.
func Capabilities(opts Options) []Result {
	return []Result{
		probeWorkspaceWritable(opts.WorkspaceDir),
		probeLink(),
		probePackageManager(),
		probeGhAuth(),
	}
}

// AnyFailed reports whether any result is a hard failure (skips don't count).
func AnyFailed(results []Result) bool {
	for _, r := range results {
		if r.Status == StatusFail {
			return true
		}
	}
	return false
}

// probeWorkspaceWritable writes and removes a temp file under dir (or the
// system temp dir when dir is empty/absent), proving bootstrap can create the
// workspace + clones there.
func probeWorkspaceWritable(dir string) Result {
	const name = "workspace-writable"
	target := dir
	if target == "" {
		target = os.TempDir()
	}
	if fi, err := os.Stat(target); err != nil || !fi.IsDir() {
		// No workspace yet (fresh machine) — fall back to temp so the probe
		// still validates the filesystem is writable somewhere sane.
		target = os.TempDir()
	}
	f, err := os.CreateTemp(target, ".ca-bootstrap-write-probe-*")
	if err != nil {
		return Result{name, StatusFail, fmt.Sprintf("cannot write in %s: %v", target, err)}
	}
	path := f.Name()
	_ = f.Close()
	if err := os.Remove(path); err != nil {
		return Result{name, StatusFail, fmt.Sprintf("wrote but could not remove %s: %v", path, err)}
	}
	return Result{name, StatusOK, "writable: " + target}
}

// probeLink creates and removes a symlink/junction in a fresh temp dir —
// the operation the extras step relies on for the ca-claude-plugin link
// (junction on Windows). Honors CA_BOOTSTRAP_SYMLINK_MOCK (same seam as
// extras) so tests don't touch the real filesystem link APIs.
func probeLink() Result {
	const name = "symlink/junction"
	if os.Getenv("CA_BOOTSTRAP_SYMLINK_MOCK") != "" {
		return Result{name, StatusOK, "ok (mocked)"}
	}
	base, err := os.MkdirTemp("", "ca-bootstrap-link-probe-*")
	if err != nil {
		return Result{name, StatusFail, "cannot create temp dir: " + err.Error()}
	}
	defer os.RemoveAll(base)
	target := filepath.Join(base, "target")
	if err := os.Mkdir(target, 0o755); err != nil {
		return Result{name, StatusFail, "cannot create link target: " + err.Error()}
	}
	link := filepath.Join(base, "link")
	if err := makeLink(target, link); err != nil {
		return Result{name, StatusFail, "cannot create link: " + err.Error()}
	}
	if _, err := os.Lstat(link); err != nil {
		return Result{name, StatusFail, "link not present after creation: " + err.Error()}
	}
	if err := os.Remove(link); err != nil {
		return Result{name, StatusFail, "cannot remove link: " + err.Error()}
	}
	return Result{name, StatusOK, "create+remove ok"}
}

// makeLink creates a directory junction on Windows (mklink /J — no admin
// needed) and a symlink elsewhere. Mirrors extras.makeLink so the capability
// probe matches what setup actually does.
func makeLink(target, linkPath string) error {
	if runtime.GOOS == "windows" {
		return exec.Command("cmd", "/c", "mklink", "/J", linkPath, target).Run()
	}
	return os.Symlink(target, linkPath)
}

// probePackageManager checks the platform package manager responds to a
// read-only version query within the timeout. Honors CA_BOOTSTRAP_PKGMGR_MOCK
// ("ok" | "fail") for tests.
func probePackageManager() Result {
	const name = "package-manager"
	if v := os.Getenv("CA_BOOTSTRAP_PKGMGR_MOCK"); v != "" {
		if v == "ok" {
			return Result{name, StatusOK, "ok (mocked)"}
		}
		return Result{name, StatusFail, "not reachable (mocked)"}
	}
	mgr, args := pkgManagerVersionCmd()
	if mgr == "" {
		return Result{name, StatusSkip, "no known package manager for this platform"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	if err := exec.CommandContext(ctx, mgr, args...).Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return Result{name, StatusFail, fmt.Sprintf("%s timed out after %s", mgr, probeTimeout)}
		}
		return Result{name, StatusFail, fmt.Sprintf("%s not reachable: %v", mgr, err)}
	}
	return Result{name, StatusOK, mgr + " reachable"}
}

// pkgManagerVersionCmd returns the per-platform package manager + a read-only
// version arg. On Linux it prefers apt-get, then dnf.
func pkgManagerVersionCmd() (string, []string) {
	switch runtime.GOOS {
	case "windows":
		return "winget", []string{"--version"}
	case "darwin":
		return "brew", []string{"--version"}
	case "linux":
		if _, err := exec.LookPath("apt-get"); err == nil {
			return "apt-get", []string{"--version"}
		}
		if _, err := exec.LookPath("dnf"); err == nil {
			return "dnf", []string{"--version"}
		}
		return "", nil
	default:
		return "", nil
	}
}

// probeGhAuth reports whether the GitHub CLI is authenticated — required to
// clone private repos. Reuses the ghauth wrapper (and its CA_BOOTSTRAP_GH_MOCK
// seam).
func probeGhAuth() Result {
	const name = "gh-auth"
	user, authed, err := ghauth.Status()
	if err != nil {
		return Result{name, StatusFail, "gh status failed: " + err.Error()}
	}
	if !authed {
		return Result{name, StatusFail, "not authenticated — run `gh auth login`"}
	}
	detail := "authenticated"
	if user != "" {
		detail += " as " + user
	}
	return Result{name, StatusOK, detail}
}

// InstallRoundTrip is the --full leg: install then uninstall a probe tool to
// prove the full install/uninstall path works on this host. It is absent-only
// — if the probe tool is already present it skips, so a real tool the user
// depends on is never removed.
func InstallRoundTrip(opts Options) Result {
	const name = "install-round-trip"
	if opts.Manifest == nil || opts.Detector == nil {
		return Result{name, StatusSkip, "no manifest/detector available"}
	}
	id := opts.ProbeToolID
	if id == "" {
		id = os.Getenv("CA_BOOTSTRAP_SELFTEST_PROBE")
	}
	if id == "" {
		id = "kubectl" // optional, not a required tool, modest size
	}
	var tool manifest.Tool
	found := false
	for _, t := range opts.Manifest.Tools {
		if t.ID == id {
			tool, found = t, true
			break
		}
	}
	if !found {
		return Result{name, StatusSkip, fmt.Sprintf("probe tool %q not in manifest", id)}
	}
	// Absent-only: never touch a tool the user actually has. "Absent" means
	// the binary isn't on the host at all — NOT merely below min version (a
	// present-but-old tool is still the user's; uninstalling it would be
	// destructive), so guard on Found, not on the OK/drift classification.
	if opts.Detector.Probe(tool).Found {
		return Result{name, StatusSkip, fmt.Sprintf("%s already present — not round-tripping (use an absent probe tool)", id)}
	}

	io.WriteString(out(opts), fmt.Sprintf("  install-round-trip: installing probe tool %s...\n", id))
	res := install.Default().Install(tool, install.Options{Out: out(opts), Prompter: opts.Prompter, ElevationAction: opts.ElevationAction})
	switch res.Status {
	case install.Installed:
		// fall through to the uninstall half below
	case install.Declined:
		// User declined elevation — a choice, not a host incapability.
		return Result{name, StatusSkip, fmt.Sprintf("elevation declined — skipped %s round-trip", id)}
	case install.Skipped:
		return Result{name, StatusSkip, fmt.Sprintf("manual install needed — skipped %s round-trip", id)}
	default: // Failed, NotApplicable
		return Result{name, StatusFail, fmt.Sprintf("install of %s did not succeed (status=%v)", id, res.Status)}
	}
	if err := install.Uninstall(res.Method, res.PackageID); err != nil {
		return Result{name, StatusFail, fmt.Sprintf("%s installed but uninstall failed: %v", id, err)}
	}
	return Result{name, StatusOK, "installed + uninstalled " + id}
}

func out(opts Options) io.Writer {
	if opts.Out != nil {
		return opts.Out
	}
	return io.Discard
}
