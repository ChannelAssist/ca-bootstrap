//go:build acceptance

// Package acceptance contains the 7 mandatory acceptance tests for
// ca-bootstrap v2.0.0-alpha.1 (spec §9.2). They MUST exist and fail
// before any non-test code in internal/ or cmd/ is committed.
//
// Run: go test -tags acceptance ./tests/acceptance/...
package acceptance

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"
)

// buildBinary compiles ca-bootstrap into a temp directory and returns
// the absolute path to the built binary. Each test gets its own build
// so ldflag values are deterministic across tests and there's no race
// on a shared binary location.
func buildBinary(t *testing.T) string {
	t.Helper()
	tmpDir := t.TempDir()
	binName := "ca-bootstrap"
	if runtime.GOOS == "windows" {
		binName += ".exe"
	}
	binPath := filepath.Join(tmpDir, binName)

	// Walk up from this test file to repo root so `go build` finds cmd/.
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	repoRoot := filepath.Join(cwd, "..", "..")

	cmd := exec.Command("go", "build",
		"-ldflags",
		"-X main.Version=2.0.0-test -X main.Commit=testcommit -X main.BuildTime=2026-05-25T00:00:00Z",
		"-o", binPath,
		"./cmd/ca-bootstrap")
	cmd.Dir = repoRoot
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("build failed: %v\nstderr: %s", err, stderr.String())
	}
	return binPath
}

// run invokes the binary with the given args and an optional manifest
// override via $CA_BOOTSTRAP_MANIFEST. Returns (stdout, stderr, exitCode).
// If manifest is empty, the env var is set to a path that definitely
// doesn't exist (so the "missing manifest" test can drive that branch
// without depending on the embedded default).
func run(t *testing.T, binPath string, manifest string, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(binPath, args...)
	if manifest != "" {
		cmd.Env = append(os.Environ(), "CA_BOOTSTRAP_MANIFEST="+manifest)
	} else {
		cmd.Env = append(os.Environ(), "CA_BOOTSTRAP_MANIFEST=/tmp/this-file-does-not-exist-2026-acceptance.yaml")
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exitCode := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		exitCode = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run failed: %v", err)
	}
	return stdout.String(), stderr.String(), exitCode
}

// fixture returns the absolute path to a testdata fixture by name.
func fixture(t *testing.T, name string) string {
	t.Helper()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	return filepath.Join(cwd, "testdata", name)
}

// ───────────────────────── the 7 tests ─────────────────────────

// TestVersion_PrintsSemverCommitAndBuildTime: spec §5.2.
//
// `ca-bootstrap version` must print exactly one line matching the regex
//
//	^ca-bootstrap (\S+) \(commit (\S+), built (\S+)\)$
//
// with the ldflag-injected values, then exit 0.
func TestVersion_PrintsSemverCommitAndBuildTime(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, "", "version")
	if exit != 0 {
		t.Fatalf("version: expected exit 0, got %d", exit)
	}
	pattern := regexp.MustCompile(`^ca-bootstrap (\S+) \(commit (\S+), built (\S+)\)\s*$`)
	if !pattern.MatchString(strings.TrimSpace(stdout)) {
		t.Errorf("version output did not match expected format.\ngot:\n%q", stdout)
	}
	if !strings.Contains(stdout, "2.0.0-test") {
		t.Errorf("version output missing ldflag-injected version.\ngot:\n%q", stdout)
	}
	if !strings.Contains(stdout, "testcommit") {
		t.Errorf("version output missing ldflag-injected commit.\ngot:\n%q", stdout)
	}
}

// TestDoctor_AllToolsPresent_ExitsZero: spec §6.3.
//
// When every required tool is present and at or above min_version,
// doctor must exit 0 and print ✓ lines for each tool plus an "N ok"
// summary.
func TestDoctor_AllToolsPresent_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, fixture(t, "two-real-tools.yaml"), "doctor")
	if exit != 0 {
		t.Fatalf("doctor: expected exit 0 (no drift), got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "✓ go") {
		t.Errorf("doctor: expected ✓ line for go. got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "✓ git") {
		t.Errorf("doctor: expected ✓ line for git. got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "2 ok") {
		t.Errorf("doctor: expected '2 ok' in summary. got:\n%s", stdout)
	}
}

// TestDoctor_RequiredToolMissing_ExitsTwo: spec §6.3.
//
// One required tool not on PATH → exit 2 (drift), with a ✗ line and a
// drift count of 1.
func TestDoctor_RequiredToolMissing_ExitsTwo(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, fixture(t, "one-missing-required.yaml"), "doctor")
	if exit != 2 {
		t.Fatalf("doctor: expected exit 2 (drift), got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "✗ xyzzy-nonexistent") {
		t.Errorf("doctor: expected ✗ line for xyzzy-nonexistent. got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "1 drift") {
		t.Errorf("doctor: expected '1 drift' in summary. got:\n%s", stdout)
	}
}

// TestDoctor_RequiredToolBelowMin_ExitsTwo: spec §6.3.
//
// Required tool present but below min_version → exit 2 (drift). The
// drift message must echo the min_version so the user knows what's
// expected.
func TestDoctor_RequiredToolBelowMin_ExitsTwo(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, fixture(t, "one-impossibly-new.yaml"), "doctor")
	if exit != 2 {
		t.Fatalf("doctor: expected exit 2 (drift), got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "✗ go") {
		t.Errorf("doctor: expected ✗ line for go (below min). got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "99.0.0") {
		t.Errorf("doctor: expected min_version 99.0.0 echoed in drift message. got:\n%s", stdout)
	}
}

// TestDoctor_OptionalToolMissing_ExitsZeroWithWarning: spec §6.3.
//
// Missing tool with optional: true → ⚠ warning line, exit 0 (NOT exit 2).
// Optional tools never contribute to drift.
func TestDoctor_OptionalToolMissing_ExitsZeroWithWarning(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, fixture(t, "one-missing-optional.yaml"), "doctor")
	if exit != 0 {
		t.Fatalf("doctor: expected exit 0 (no required drift), got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "⚠ xyzzy-optional") {
		t.Errorf("doctor: expected ⚠ line for xyzzy-optional. got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "1 missing-optional") {
		t.Errorf("doctor: expected '1 missing-optional' in summary. got:\n%s", stdout)
	}
}

// TestDoctorDeep_AllProbesOK_ExitsZero (alpha.7): doctor --deep runs the
// capability self-test after detection; with detection clean and every safe
// probe mocked-ok, the exit stays 0 and the probes are reported.
func TestDoctorDeep_AllProbesOK_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	t.Setenv("CA_BOOTSTRAP_PKGMGR_MOCK", "ok")
	t.Setenv("CA_BOOTSTRAP_SYMLINK_MOCK", "1")
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:tester")
	stdout, _, exit := run(t, bin, fixture(t, "two-real-tools.yaml"), "doctor", "--deep")
	if exit != 0 {
		t.Fatalf("doctor --deep, all probes ok: expected exit 0, got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "Capability self-test") {
		t.Errorf("doctor --deep: expected a capability self-test section. got:\n%s", stdout)
	}
}

// TestDoctorDeep_PkgMgrUnreachable_ExitsTwo (alpha.7): a failed safe probe is
// drift-equivalent — exit 2 even when tool detection is clean.
func TestDoctorDeep_PkgMgrUnreachable_ExitsTwo(t *testing.T) {
	bin := buildBinary(t)
	t.Setenv("CA_BOOTSTRAP_PKGMGR_MOCK", "fail")
	t.Setenv("CA_BOOTSTRAP_SYMLINK_MOCK", "1")
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:tester")
	_, _, exit := run(t, bin, fixture(t, "two-real-tools.yaml"), "doctor", "--deep")
	if exit != 2 {
		t.Fatalf("doctor --deep, package manager unreachable: expected exit 2, got %d", exit)
	}
}

// TestDoctorDeepFull_RoundTrip_ExitsZero (alpha.7): doctor --deep --full runs
// a real install→uninstall round-trip on an absent probe tool (mocked here),
// reporting it without leaving anything installed.
func TestDoctorDeepFull_RoundTrip_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	t.Setenv("CA_BOOTSTRAP_PKGMGR_MOCK", "ok")
	t.Setenv("CA_BOOTSTRAP_SYMLINK_MOCK", "1")
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:tester")
	t.Setenv("CA_BOOTSTRAP_SELFTEST_PROBE", "mocktool")
	stdout, _, exit := run(t, bin, fixture(t, "selftest-full-mock.yaml"), "doctor", "--deep", "--full")
	if exit != 0 {
		t.Fatalf("doctor --deep --full, mock round-trip: expected exit 0, got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "install-round-trip") {
		t.Errorf("doctor --deep --full: expected the install-round-trip probe. got:\n%s", stdout)
	}
}

// TestDoctor_ManifestMissing_ExitsOneToStderr: spec §6.4.
//
// $CA_BOOTSTRAP_MANIFEST points at a nonexistent file → exit 1 (system
// error) with a clear "manifest" error on stderr (not stdout).
func TestDoctor_ManifestMissing_ExitsOneToStderr(t *testing.T) {
	bin := buildBinary(t)
	cmd := exec.Command(bin, "doctor")
	cmd.Env = append(os.Environ(), "CA_BOOTSTRAP_MANIFEST=/tmp/this-file-does-not-exist-2026.yaml")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exit := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		exit = exitErr.ExitCode()
	}
	if exit != 1 {
		t.Fatalf("doctor: expected exit 1 (system error), got %d", exit)
	}
	if !strings.Contains(strings.ToLower(stderr.String()), "manifest") {
		t.Errorf("doctor: expected stderr to mention 'manifest'. got stderr:\n%s\nstdout:\n%s", stderr.String(), stdout.String())
	}
}

// TestDoctor_ManifestParseError_ExitsOneToStderr: spec §6.4.
//
// Manifest YAML doesn't parse → exit 1 (system error), with a clear
// parse-error message on stderr.
func TestDoctor_ManifestParseError_ExitsOneToStderr(t *testing.T) {
	bin := buildBinary(t)
	_, stderr, exit := run(t, bin, fixture(t, "malformed.yaml"), "doctor")
	if exit != 1 {
		t.Fatalf("doctor: expected exit 1 (parse error), got %d. stderr:\n%s", exit, stderr)
	}
	lower := strings.ToLower(stderr)
	if !strings.Contains(lower, "parse") && !strings.Contains(lower, "yaml") {
		t.Errorf("doctor: expected stderr to mention 'parse' or 'yaml'. got:\n%s", stderr)
	}
}

// ─────────────────────── alpha.2 setup tests ───────────────────────
//
// Tests for `ca-bootstrap setup` per spec docs/specs/2026-05-25-go-v2-0-alpha-2-spec.md.
// All use --unattended --config since acceptance tests can't reliably
// drive interactive stdin. Workspace_root is patched into the config
// at runtime via a small templating helper so each test gets a clean
// t.TempDir().

// renderUnattendedConfig copies a fixture template into the test's
// temp dir and injects identity.workspace_root with the given path.
// Returns the path of the materialized file.
//
// The injection point matters: workspace_root must be a key UNDER
// identity (2-space indent, no intervening blank line) or yaml.v3
// will parse it as a top-level key and the unattended Prompter
// won't find it under identity.workspace_root.
func renderUnattendedConfig(t *testing.T, fixtureName, workspace string) string {
	t.Helper()
	src, err := os.ReadFile(fixture(t, fixtureName))
	if err != nil {
		t.Fatalf("read fixture %s: %v", fixtureName, err)
	}
	body := string(src)
	// Replace any existing `# workspace_root: ...` comment placeholder
	// or just append a workspace_root line immediately after the last
	// non-blank line under identity:. Simplest approach: split fixture
	// content + inject right after the "email:" line.
	if !strings.Contains(body, "workspace_root:") {
		// Forward-slash the path: a Windows path (C:\Users\...) inside a
		// double-quoted YAML scalar makes yaml.v3 read \U, \A, … as invalid
		// escape sequences. go-yaml then fails with its own error string,
		// quoted verbatim here (its spelling, not ours): `did not find
		// expected hexdecimal number`. Go's file ops accept forward slashes
		// on Windows, and the tests' Stat assertions (which join the original
		// path) resolve to the same location. Matches the smoke harness.
		wsYAML := filepath.ToSlash(workspace)
		emailLine := "  email: \"test@example.com\""
		body = strings.Replace(body, emailLine,
			emailLine+"\n  workspace_root: \""+wsYAML+"\"", 1)
	}
	dst := filepath.Join(t.TempDir(), fixtureName)
	if err := os.WriteFile(dst, []byte(body), 0644); err != nil {
		t.Fatalf("write rendered fixture: %v", err)
	}
	return dst
}

// runSetup is like run() but for the setup subcommand. Sets up:
//   - $CA_BOOTSTRAP_MANIFEST (override path)
//   - $HOME and %USERPROFILE% (so the journal lands in the test sandbox;
//     os.UserHomeDir() reads USERPROFILE on Windows, HOME elsewhere)
//   - $CA_BOOTSTRAP_ASCII=1 (so output is grep-able regardless of console)
//   - $CA_BOOTSTRAP_WSL_MOCK (so the Windows-only extras WSL offer is a
//     no-op instead of shelling out to the real, blocking `wsl --install`)
//
// Returns stdout, stderr, exit code.
func runSetup(t *testing.T, binPath string, manifestPath, configPath, fakeHome string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(binPath, "setup", "--unattended", "--config", configPath)
	env := append(os.Environ(),
		"CA_BOOTSTRAP_MANIFEST="+manifestPath,
		"HOME="+fakeHome,
		"USERPROFILE="+fakeHome,
		"CA_BOOTSTRAP_WSL_MOCK=has-ubuntu",
		"CA_BOOTSTRAP_ASCII=1",
		// Make the gh-auth step deterministic: pretend the user is
		// already authenticated, so setup never shells out to real gh
		// or prompts. The gh-auth-specific paths are covered separately.
		"CA_BOOTSTRAP_GH_MOCK=authed:acceptance-bot",
		// Make the repos step deterministic: a minimal one-group manifest
		// and a mocked clone, so setup never hits the network. The clone
		// paths are covered by unit tests + a dedicated repos test.
		"CA_BOOTSTRAP_REPOS="+fixture(t, "repos-core.yaml"),
		"CA_BOOTSTRAP_CLONE_MOCK=ok",
	)
	cmd.Env = env
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exit := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		exit = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run failed: %v", err)
	}
	return stdout.String(), stderr.String(), exit
}

func TestSetup_HappyPath_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-happy.yaml", workspace)
	stdout, stderr, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup happy path: expected exit 0, got %d\nstdout:\n%s\nstderr:\n%s", exit, stdout, stderr)
	}
}

func TestSetup_PrereqsDrift_Acknowledged_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-drift-acknowledge.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "one-missing-required.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup with acknowledged drift: expected exit 0, got %d", exit)
	}
}

func TestSetup_PrereqsDrift_Rejected_ExitsTwo(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-drift-reject.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "one-missing-required.yaml"), cfg, fakeHome)
	if exit != 2 {
		t.Fatalf("setup with rejected drift: expected exit 2, got %d", exit)
	}
}

// TestSetup_PrereqsDrift_OffersInstall verifies the alpha.6 behaviour: when a
// required tool is missing, the prereqs step OFFERS TO INSTALL it inline
// (rather than just telling the user to run repair). The mock installer can't
// make the fake binary detectable, so drift remains and continue_with_drift
// carries the run to exit 0 — but the install must have been attempted.
func TestSetup_PrereqsDrift_OffersInstall(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-prereqs-install.yaml", workspace)
	stdout, _, exit := runSetup(t, bin, fixture(t, "one-missing-required-mock.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup with accepted install offer: expected exit 0, got %d", exit)
	}
	if !strings.Contains(stdout, "Installing xyzzy-nonexistent") {
		t.Errorf("expected setup to attempt installing the missing tool. stdout:\n%s", stdout)
	}
	journalPath := filepath.Join(fakeHome, ".ca-bootstrap", "journal.ndjson")
	body, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatalf("read journal: %v", err)
	}
	if !strings.Contains(string(body), "install_attempt") || !strings.Contains(string(body), "xyzzy-nonexistent") {
		t.Errorf("expected journal to record an install_attempt for xyzzy-nonexistent. got:\n%s", body)
	}
}

// TestSetup_PrereqsInstall_MissingKey_ExitsOne is a regression guard: when the
// prereqs install offer is reached unattended but the prereqs.install_missing
// key is absent, the strict prompter's missing-key error must propagate as a
// config error (exit 1) — not get swallowed into a silent skip that falls
// through to continue_with_drift (which would let it exit 0).
func TestSetup_PrereqsInstall_MissingKey_ExitsOne(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-prereqs-missing-key.yaml", workspace)
	_, stderr, exit := runSetup(t, bin, fixture(t, "one-missing-required.yaml"), cfg, fakeHome)
	if exit != 1 {
		t.Fatalf("setup with missing prereqs.install_missing key: expected exit 1 (config error), got %d. stderr:\n%s", exit, stderr)
	}
}

// TestSetup_PrereqsInstall_ElevationDeclined_ExitsOneThirty verifies the
// unattended setup install path honours prereqs.elevation_action: a missing
// required tool whose install needs elevation, with elevation_action: deny,
// aborts at exit 130 — proving the action is threaded through and the install
// package's repair.* elevation prompt keys (absent from setup configs) are
// never reached (which would otherwise error → exit 1).
func TestSetup_PrereqsInstall_ElevationDeclined_ExitsOneThirty(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-prereqs-elevation-deny.yaml", workspace)
	_, stderr, exit := runSetup(t, bin, fixture(t, "one-elevation-required-mock.yaml"), cfg, fakeHome)
	if exit != 130 {
		t.Fatalf("setup, elevation-needing tool + elevation_action deny: expected exit 130, got %d. stderr:\n%s", exit, stderr)
	}
}

func TestSetup_QuitAtPrompt_ExitsOneThirty(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-quit.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 130 {
		t.Fatalf("setup with welcome consent=false: expected exit 130, got %d", exit)
	}
}

func TestSetup_ConfigMissing_ExitsOne(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	_, stderr, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), "/tmp/this-config-does-not-exist-2026.yaml", fakeHome)
	if exit != 1 {
		t.Fatalf("setup with missing config: expected exit 1, got %d. stderr:\n%s", exit, stderr)
	}
	if !strings.Contains(strings.ToLower(stderr), "config") {
		t.Errorf("setup: expected stderr to mention 'config'. got:\n%s", stderr)
	}
}

func TestSetup_WritesGitIdentityToWorkspace(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-happy.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup happy path: expected exit 0, got %d", exit)
	}
	gitConfig := filepath.Join(workspace, ".git", "config")
	body, err := os.ReadFile(gitConfig)
	if err != nil {
		t.Fatalf("read workspace .git/config: %v", err)
	}
	if !strings.Contains(string(body), "Test User") || !strings.Contains(string(body), "test@example.com") {
		t.Errorf("workspace .git/config missing identity. got:\n%s", body)
	}
}

func TestSetup_JournalRecordsSession(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-happy.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup happy path: expected exit 0, got %d", exit)
	}
	journalPath := filepath.Join(fakeHome, ".ca-bootstrap", "journal.ndjson")
	body, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatalf("read journal at %s: %v", journalPath, err)
	}
	for _, want := range []string{"session_start", "identity_set", "session_end"} {
		if !strings.Contains(string(body), want) {
			t.Errorf("journal missing %q. body:\n%s", want, body)
		}
	}
}

// ─────────────────────── alpha.3 repair tests ───────────────────────
//
// repair per docs/specs/2026-05-25-go-v2-0-alpha-3-spec.md. The
// elevation tests use --unattended --config to provide the
// elevation_action answer without interactive stdin. The mock install
// type (in fixture manifests) lets repair exercise install dispatch
// without mutating the real system. Lock acquire/release/force-unlock
// are unit-tested in internal/lock (flock can't be faked from a
// separate test process).

// runRepair invokes `repair --target <id>` with optional --unattended
// --config. Sets HOME + USERPROFILE to redirect the journal + lock into the
// sandbox (os.UserHomeDir() reads USERPROFILE on Windows, HOME elsewhere).
func runRepair(t *testing.T, binPath, manifestPath, target, configPath, fakeHome string) (string, string, int) {
	t.Helper()
	args := []string{"repair", "--target", target}
	if configPath != "" {
		args = append(args, "--unattended", "--config", configPath)
	}
	cmd := exec.Command(binPath, args...)
	cmd.Env = append(os.Environ(),
		"CA_BOOTSTRAP_MANIFEST="+manifestPath,
		"HOME="+fakeHome,
		"USERPROFILE="+fakeHome,
		"CA_BOOTSTRAP_ASCII=1",
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exit := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		exit = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run failed: %v", err)
	}
	return stdout.String(), stderr.String(), exit
}

func TestRepair_TargetNotInManifest_ExitsOne(t *testing.T) {
	bin := buildBinary(t)
	home := t.TempDir()
	_, stderr, exit := runRepair(t, bin, fixture(t, "two-real-tools.yaml"), "nonexistent-tool", "", home)
	if exit != 1 {
		t.Fatalf("expected exit 1 for unknown target, got %d. stderr:\n%s", exit, stderr)
	}
	if !strings.Contains(strings.ToLower(stderr), "not") {
		t.Errorf("expected stderr to explain target not found. got:\n%s", stderr)
	}
}

func TestRepair_AlreadyInstalled_ExitsZeroNoOp(t *testing.T) {
	bin := buildBinary(t)
	home := t.TempDir()
	// git is present on every test runner; two-real-tools.yaml lists it
	// with a low min_version, so repair should no-op with exit 0.
	stdout, _, exit := runRepair(t, bin, fixture(t, "two-real-tools.yaml"), "git", "", home)
	if exit != 0 {
		t.Fatalf("expected exit 0 for already-installed git, got %d. stdout:\n%s", exit, stdout)
	}
}

// TestRepair_NoTarget_NothingMissing_ExitsZero covers the alpha.6 default:
// `repair` with no --target scans for missing required tools and, when all are
// present, reports "nothing to repair" and exits 0 (no prompt, no install).
func TestRepair_NoTarget_NothingMissing_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	home := t.TempDir()
	stdout, _, exit := runRepair(t, bin, fixture(t, "two-real-tools.yaml"), "", "", home)
	if exit != 0 {
		t.Fatalf("repair (no target), all tools present: expected exit 0, got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(strings.ToLower(stdout), "nothing to repair") {
		t.Errorf("expected 'nothing to repair' message. got:\n%s", stdout)
	}
}

func TestRepair_InstallFailure_ExitsTwo(t *testing.T) {
	bin := buildBinary(t)
	home := t.TempDir()
	_, _, exit := runRepair(t, bin, fixture(t, "repair-mock-fail.yaml"), "mocktool", "", home)
	if exit != 2 {
		t.Fatalf("expected exit 2 for install failure, got %d", exit)
	}
}

func TestRepair_ElevationDeclined_ExitsOneThirty(t *testing.T) {
	bin := buildBinary(t)
	home := t.TempDir()
	cfg := fixture(t, "unattended-repair-deny.yaml")
	_, _, exit := runRepair(t, bin, fixture(t, "repair-mock-elevation.yaml"), "mocktool", cfg, home)
	if exit != 130 {
		t.Fatalf("expected exit 130 when elevation declined, got %d", exit)
	}
}

func TestRepair_ElevationSkipChosen_ExitsTwoWithManual(t *testing.T) {
	bin := buildBinary(t)
	home := t.TempDir()
	cfg := fixture(t, "unattended-repair-skip.yaml")
	stdout, _, exit := runRepair(t, bin, fixture(t, "repair-mock-elevation.yaml"), "mocktool", cfg, home)
	if exit != 2 {
		t.Fatalf("expected exit 2 when elevation skipped, got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(strings.ToLower(stdout), "manual") {
		t.Errorf("expected manual-install summary in output. got:\n%s", stdout)
	}
}

// ─────────────────────── alpha.4 undo tests ───────────────────────
//
// undo per docs/specs/2026-05-28-go-v2-0-alpha-4-spec.md. All tests
// seed a pre-populated journal.ndjson in fakeHome/.ca-bootstrap/ then
// invoke `ca-bootstrap undo` with appropriate flags. Tests stay
// black-box: they read/write the journal as raw NDJSON rather than
// importing internal/journal, so the test surface survives refactors
// of the internal representation.
//
// RED gate: these tests fail until alpha.4 phase C lands. Initial
// failure mode is `unknown command "undo" for "ca-bootstrap"` because
// the subcommand isn't wired into root yet.

// journalEntry is a local mirror of internal/journal.Entry used only
// for seeding the journal in tests. Kept independent of the internal
// type on purpose — acceptance tests should not import internal/.
type journalEntry struct {
	ID        string            `json:"id,omitempty"`
	TS        time.Time         `json:"ts"`
	SessionID string            `json:"sessionID"`
	Action    string            `json:"action"`
	Target    string            `json:"target,omitempty"`
	Before    map[string]string `json:"before,omitempty"`
	After     map[string]string `json:"after,omitempty"`
	Result    string            `json:"result"`
}

// seedJournal writes the given entries as NDJSON to
// fakeHome/.ca-bootstrap/journal.ndjson. Each entry becomes one line.
// Creates the .ca-bootstrap directory if needed.
func seedJournal(t *testing.T, fakeHome string, entries []journalEntry) string {
	t.Helper()
	dir := filepath.Join(fakeHome, ".ca-bootstrap")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("seedJournal: mkdir %s: %v", dir, err)
	}
	path := filepath.Join(dir, "journal.ndjson")
	var buf bytes.Buffer
	for _, e := range entries {
		line, err := json.Marshal(e)
		if err != nil {
			t.Fatalf("seedJournal: marshal entry: %v", err)
		}
		buf.Write(line)
		buf.WriteByte('\n')
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o600); err != nil {
		t.Fatalf("seedJournal: write %s: %v", path, err)
	}
	return path
}

// readJournal reads the NDJSON journal back as a slice of entries.
// Used by post-undo assertions to verify entry_undone markers were
// appended.
func readJournal(t *testing.T, journalPath string) []journalEntry {
	t.Helper()
	body, err := os.ReadFile(journalPath)
	if err != nil {
		t.Fatalf("readJournal: %v", err)
	}
	var out []journalEntry
	for _, line := range strings.Split(strings.TrimRight(string(body), "\n"), "\n") {
		if line == "" {
			continue
		}
		var e journalEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("readJournal: parse line %q: %v", line, err)
		}
		out = append(out, e)
	}
	return out
}

// writeWorkspaceGitConfig writes a minimal .git/config to workspace
// with the given user.name + user.email. Used to set up the pre-undo
// state so identity reversal has something to clear/restore.
func writeWorkspaceGitConfig(t *testing.T, workspace, name, email string) {
	t.Helper()
	gitDir := filepath.Join(workspace, ".git")
	if err := os.MkdirAll(gitDir, 0o755); err != nil {
		t.Fatalf("writeWorkspaceGitConfig: mkdir: %v", err)
	}
	body := "[user]\n\tname = " + name + "\n\temail = " + email + "\n"
	if err := os.WriteFile(filepath.Join(gitDir, "config"), []byte(body), 0o644); err != nil {
		t.Fatalf("writeWorkspaceGitConfig: write: %v", err)
	}
}

// runUndo invokes `ca-bootstrap undo` with optional extra args, setting
// HOME + USERPROFILE to redirect journal + lock into the sandbox
// (os.UserHomeDir() reads USERPROFILE on Windows, HOME elsewhere). Returns
// (stdout, stderr, exit).
func runUndo(t *testing.T, binPath, fakeHome string, extraArgs ...string) (string, string, int) {
	t.Helper()
	args := append([]string{"undo"}, extraArgs...)
	cmd := exec.Command(binPath, args...)
	cmd.Env = append(os.Environ(),
		"HOME="+fakeHome,
		"USERPROFILE="+fakeHome,
		"CA_BOOTSTRAP_ASCII=1",
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exit := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		exit = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("runUndo failed: %v", err)
	}
	return stdout.String(), stderr.String(), exit
}

// identityEntry builds an identity_set entry for use in seedJournal.
// Pass empty strings for Before to model "no prior identity recorded".
func identityEntry(id, sessionID, workspace, beforeName, beforeEmail, afterName, afterEmail string) journalEntry {
	return journalEntry{
		ID:        id,
		TS:        time.Date(2026, 5, 26, 12, 0, 0, 0, time.UTC),
		SessionID: sessionID,
		Action:    "identity_set",
		Target:    filepath.Join(workspace, ".git", "config"),
		Before:    map[string]string{"user.name": beforeName, "user.email": beforeEmail},
		After:     map[string]string{"user.name": afterName, "user.email": afterEmail},
		Result:    "ok",
	}
}

// installSuccessEntry builds an install_success entry, including the
// alpha.4 spec-amendment fields (after.method, after.package_id).
func installSuccessEntry(id, sessionID, toolID, method, packageID string) journalEntry {
	return journalEntry{
		ID:        id,
		TS:        time.Date(2026, 5, 26, 12, 1, 0, 0, time.UTC),
		SessionID: sessionID,
		Action:    "install_success",
		Target:    toolID,
		After:     map[string]string{"method": method, "package_id": packageID},
		Result:    "ok",
	}
}

// entryUndoneEntry builds an entry_undone marker referencing the
// reversed entry's ID. Used to test "already undone" behavior.
func entryUndoneEntry(id, sessionID, undoneID string) journalEntry {
	return journalEntry{
		ID:        id,
		TS:        time.Date(2026, 5, 27, 9, 0, 0, 0, time.UTC),
		SessionID: sessionID,
		Action:    "entry_undone",
		Target:    undoneID,
		Result:    "ok",
	}
}

// ──── the 19 alpha.4 acceptance tests ────

func TestUndo_NoJournal_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	// No journal file exists.
	stdout, _, exit := runUndo(t, bin, fakeHome)
	if exit != 0 {
		t.Fatalf("expected exit 0 when no journal, got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(strings.ToLower(stdout), "nothing") && !strings.Contains(strings.ToLower(stdout), "no reversible") {
		t.Errorf("expected stdout to say nothing/no reversible. got:\n%s", stdout)
	}
}

func TestUndo_EmptyJournal_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	// Journal exists but holds only bookkeeping (session_start/end) — no reversible entries.
	seedJournal(t, fakeHome, []journalEntry{
		{ID: "s1", TS: time.Now().UTC(), SessionID: "sess1", Action: "session_start", Result: "ok"},
		{ID: "s2", TS: time.Now().UTC(), SessionID: "sess1", Action: "session_end", Result: "exit_0"},
	})
	_, _, exit := runUndo(t, bin, fakeHome)
	if exit != 0 {
		t.Fatalf("expected exit 0 when only bookkeeping entries, got %d", exit)
	}
}

func TestUndo_IdentitySet_RestoresPreviousConfig(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	// Current state on disk: "New User". Journal says previous was "Old User".
	writeWorkspaceGitConfig(t, workspace, "New User", "new@example.com")
	seedJournal(t, fakeHome, []journalEntry{
		identityEntry("id-identity", "sess1", workspace,
			"Old User", "old@example.com",
			"New User", "new@example.com"),
	})
	// Unattended undo with --force so no prompt blocks.
	_, _, exit := runUndo(t, bin, fakeHome, "--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"), "--force")
	if exit != 0 {
		t.Fatalf("expected exit 0 for identity restore, got %d", exit)
	}
	body, err := os.ReadFile(filepath.Join(workspace, ".git", "config"))
	if err != nil {
		t.Fatalf("read .git/config: %v", err)
	}
	if !strings.Contains(string(body), "Old User") || !strings.Contains(string(body), "old@example.com") {
		t.Errorf(".git/config not restored to previous identity. got:\n%s", body)
	}
}

func TestUndo_IdentitySet_EmptyBefore_RemovesUserBlock(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	writeWorkspaceGitConfig(t, workspace, "Only User", "only@example.com")
	// Before is empty → identity was set on a clean workspace; undo should remove the [user] block.
	seedJournal(t, fakeHome, []journalEntry{
		identityEntry("id-identity", "sess1", workspace,
			"", "",
			"Only User", "only@example.com"),
	})
	_, _, exit := runUndo(t, bin, fakeHome, "--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"), "--force")
	if exit != 0 {
		t.Fatalf("expected exit 0 for empty-Before identity, got %d", exit)
	}
	body, _ := os.ReadFile(filepath.Join(workspace, ".git", "config"))
	if strings.Contains(string(body), "Only User") {
		t.Errorf("[user] block should have been removed but \"Only User\" still present. got:\n%s", body)
	}
}

func TestUndo_IdentitySet_AlreadyAbsent_NoOp(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	// No .git/config exists. Reverser should noop, not fail.
	seedJournal(t, fakeHome, []journalEntry{
		identityEntry("id-identity", "sess1", workspace,
			"Old User", "old@example.com",
			"New User", "new@example.com"),
	})
	_, _, exit := runUndo(t, bin, fakeHome, "--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"), "--force")
	if exit != 0 {
		t.Fatalf("expected exit 0 when .git/config already absent, got %d", exit)
	}
}

func TestUndo_ToolInstall_Default_Skips(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	// install_success entry present, but --include-tools NOT set → must not uninstall.
	seedJournal(t, fakeHome, []journalEntry{
		installSuccessEntry("id-tool", "sess1", "mocktool", "mock", "mocktool-pkg"),
	})
	stdout, _, exit := runUndo(t, bin, fakeHome, "--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"), "--force")
	if exit != 0 {
		t.Fatalf("expected exit 0 with tools opt-in not set, got %d", exit)
	}
	if !strings.Contains(strings.ToLower(stdout), "include-tools") && !strings.Contains(strings.ToLower(stdout), "skipped") && !strings.Contains(strings.ToLower(stdout), "kept") {
		t.Errorf("expected stdout to indicate tools were kept / require --include-tools. got:\n%s", stdout)
	}
}

func TestUndo_ToolInstall_IncludeTools_Uninstalls(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	seedJournal(t, fakeHome, []journalEntry{
		installSuccessEntry("id-tool", "sess1", "mocktool", "mock", "mocktool-pkg"),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force", "--include-tools",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 with mock uninstall, got %d", exit)
	}
	// Verify an entry_undone marker was appended targeting the install_success entry.
	entries := readJournal(t, filepath.Join(fakeHome, ".ca-bootstrap", "journal.ndjson"))
	found := false
	for _, e := range entries {
		if e.Action == "entry_undone" && e.Target == "id-tool" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected entry_undone marker targeting id-tool. journal:\n%+v", entries)
	}
}

func TestUndo_ToolInstall_MissingMethodField_Fails(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	// install_success entry without after.method — should fail per spec §7.2 step 1.
	seedJournal(t, fakeHome, []journalEntry{
		{
			ID:        "id-tool",
			TS:        time.Date(2026, 5, 26, 12, 1, 0, 0, time.UTC),
			SessionID: "sess1",
			Action:    "install_success",
			Target:    "mocktool",
			Result:    "ok",
			// No After.
		},
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force", "--include-tools",
	)
	if exit != 7 {
		t.Fatalf("expected exit 7 (partial failure) for missing method, got %d", exit)
	}
}

func TestUndo_InstallFailedEntry_NoOp(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	seedJournal(t, fakeHome, []journalEntry{
		{ID: "id-fail", TS: time.Now().UTC(), SessionID: "sess1", Action: "install_failed", Target: "mocktool", Result: "error"},
	})
	_, _, exit := runUndo(t, bin, fakeHome, "--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"), "--force")
	if exit != 0 {
		t.Fatalf("expected exit 0 (install_failed is not reversible / noop), got %d", exit)
	}
}

func TestUndo_AlreadyUndone_SkipsReversedEntry(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	writeWorkspaceGitConfig(t, workspace, "New User", "new@example.com")
	// identity_set followed by entry_undone targeting it → second undo run must skip.
	seedJournal(t, fakeHome, []journalEntry{
		identityEntry("id-identity", "sess1", workspace,
			"Old User", "old@example.com",
			"New User", "new@example.com"),
		entryUndoneEntry("id-marker", "sess2", "id-identity"),
	})
	_, _, exit := runUndo(t, bin, fakeHome, "--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"), "--force")
	if exit != 0 {
		t.Fatalf("expected exit 0 with no remaining reversible entries, got %d", exit)
	}
	// The .git/config should be UNCHANGED — still "New User", since the original undo already ran.
	body, _ := os.ReadFile(filepath.Join(workspace, ".git", "config"))
	if !strings.Contains(string(body), "New User") {
		t.Errorf("expected .git/config to remain at New User (already-undone entry should be skipped). got:\n%s", body)
	}
}

func TestUndo_TargetIdentity_ScopesOnly(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	writeWorkspaceGitConfig(t, workspace, "New User", "new@example.com")
	seedJournal(t, fakeHome, []journalEntry{
		identityEntry("id-identity", "sess1", workspace, "Old", "old@e", "New User", "new@example.com"),
		installSuccessEntry("id-tool", "sess1", "mocktool", "mock", "mocktool-pkg"),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--target", "identity",
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force", "--include-tools",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 with --target identity, got %d", exit)
	}
	// identity entry should have a marker; tool entry should NOT.
	entries := readJournal(t, filepath.Join(fakeHome, ".ca-bootstrap", "journal.ndjson"))
	identityUndone, toolUndone := false, false
	for _, e := range entries {
		if e.Action == "entry_undone" && e.Target == "id-identity" {
			identityUndone = true
		}
		if e.Action == "entry_undone" && e.Target == "id-tool" {
			toolUndone = true
		}
	}
	if !identityUndone {
		t.Errorf("expected entry_undone for id-identity, got none. journal:\n%+v", entries)
	}
	if toolUndone {
		t.Errorf("--target identity should not have reversed id-tool, but found entry_undone marker")
	}
}

func TestUndo_TargetToolID_ScopesOnly(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	seedJournal(t, fakeHome, []journalEntry{
		installSuccessEntry("id-a", "sess1", "tool-a", "mock", "tool-a-pkg"),
		installSuccessEntry("id-b", "sess1", "tool-b", "mock", "tool-b-pkg"),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--target", "tool:tool-a",
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force", "--include-tools",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 with --target tool:tool-a, got %d", exit)
	}
	entries := readJournal(t, filepath.Join(fakeHome, ".ca-bootstrap", "journal.ndjson"))
	aUndone, bUndone := false, false
	for _, e := range entries {
		if e.Action == "entry_undone" && e.Target == "id-a" {
			aUndone = true
		}
		if e.Action == "entry_undone" && e.Target == "id-b" {
			bUndone = true
		}
	}
	if !aUndone {
		t.Errorf("expected entry_undone for id-a, got none")
	}
	if bUndone {
		t.Errorf("--target tool:tool-a should not have reversed id-b")
	}
}

func TestUndo_TargetUnknown_ExitsOneWithMsg(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	seedJournal(t, fakeHome, []journalEntry{
		installSuccessEntry("id-tool", "sess1", "mocktool", "mock", "mocktool-pkg"),
	})
	_, stderr, exit := runUndo(t, bin, fakeHome,
		"--target", "tool:does-not-exist",
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 1 {
		t.Fatalf("expected exit 1 for unknown target, got %d", exit)
	}
	if !strings.Contains(strings.ToLower(stderr), "no reversible") && !strings.Contains(strings.ToLower(stderr), "no match") && !strings.Contains(strings.ToLower(stderr), "not match") {
		t.Errorf("expected stderr to explain no match. got:\n%s", stderr)
	}
}

func TestUndo_LegacyEntryNoID_SkippedWithInfo(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	writeWorkspaceGitConfig(t, workspace, "Legacy User", "legacy@example.com")
	// Legacy entry — no ID field (the field is omitempty so the JSON line lacks "id").
	seedJournal(t, fakeHome, []journalEntry{
		{
			// No ID — legacy.
			TS:        time.Date(2026, 5, 20, 9, 0, 0, 0, time.UTC),
			SessionID: "sess-legacy",
			Action:    "identity_set",
			Target:    filepath.Join(workspace, ".git", "config"),
			Before:    map[string]string{"user.name": "Prior", "user.email": "prior@example.com"},
			After:     map[string]string{"user.name": "Legacy User", "user.email": "legacy@example.com"},
			Result:    "ok",
		},
	})
	stdout, _, exit := runUndo(t, bin, fakeHome, "--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"), "--force")
	if exit != 0 {
		t.Fatalf("expected exit 0 with legacy entry skipped, got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(strings.ToLower(stdout), "legacy") && !strings.Contains(strings.ToLower(stdout), "no id") && !strings.Contains(strings.ToLower(stdout), "skipping") {
		t.Errorf("expected stdout to note the legacy/no-id skip. got:\n%s", stdout)
	}
	// .git/config must remain untouched.
	body, _ := os.ReadFile(filepath.Join(workspace, ".git", "config"))
	if !strings.Contains(string(body), "Legacy User") {
		t.Errorf("legacy entry should NOT have been reversed; .git/config was modified. got:\n%s", body)
	}
}

func TestUndo_LockHeld_ExitsOne(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("flock-based lock-holder is POSIX-only; Windows lock semantics covered in internal/lock unit tests")
	}
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	seedJournal(t, fakeHome, []journalEntry{
		installSuccessEntry("id-tool", "sess1", "mocktool", "mock", "mocktool-pkg"),
	})
	// Acquire the lock in *this* test process via syscall.Flock so the
	// spawned ca-bootstrap undo finds it genuinely held. Stale-file
	// presence alone does NOT register as held for flock — alpha.3
	// spec §6.4 — so this test must hold a real advisory lock to
	// exercise the lock-busy code path.
	lockDir := filepath.Join(fakeHome, ".ca-bootstrap")
	if err := os.MkdirAll(lockDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	lockPath := filepath.Join(lockDir, "session.lock")
	// Hold a real advisory lock for the test's lifetime so the spawned
	// ca-bootstrap undo finds it genuinely held. POSIX-only (flock); the
	// Windows stub skips, matching the runtime.GOOS guard above.
	holdSessionLock(t, lockPath)

	_, stderr, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 1 {
		t.Fatalf("expected exit 1 when lock is held, got %d. stderr:\n%s", exit, stderr)
	}
	if !strings.Contains(strings.ToLower(stderr), "lock") {
		t.Errorf("expected stderr to mention lock state. got:\n%s", stderr)
	}
}

func TestUndo_ForceUnlock_ClearsExistingLock_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	seedJournal(t, fakeHome, []journalEntry{
		// Empty-Before identity is the simplest reversible action with no real side effects.
		identityEntry("id-identity", "sess1", t.TempDir(), "", "", "User", "user@e"),
	})
	// Seed a stale lock that --ForceUnlock will clear.
	lockDir := filepath.Join(fakeHome, ".ca-bootstrap")
	if err := os.MkdirAll(lockDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(lockDir, "session.lock"), nil, 0o600); err != nil {
		t.Fatalf("seed lock: %v", err)
	}
	_, _, exit := runUndo(t, bin, fakeHome,
		"--ForceUnlock",
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 with --ForceUnlock + stale lock, got %d", exit)
	}
}

func TestUndo_Unattended_RequiresForce(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	seedJournal(t, fakeHome, []journalEntry{
		installSuccessEntry("id-tool", "sess1", "mocktool", "mock", "mocktool-pkg"),
	})
	_, stderr, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		// --force OMITTED
	)
	if exit != 1 {
		t.Fatalf("expected exit 1 when --unattended without --force, got %d", exit)
	}
	if !strings.Contains(strings.ToLower(stderr), "--force") && !strings.Contains(strings.ToLower(stderr), "force") {
		t.Errorf("expected stderr to mention --force requirement. got:\n%s", stderr)
	}
}

func TestUndo_Unattended_WithForce_Runs(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	writeWorkspaceGitConfig(t, workspace, "User", "user@example.com")
	seedJournal(t, fakeHome, []journalEntry{
		identityEntry("id-identity", "sess1", workspace, "", "", "User", "user@example.com"),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 with --unattended --force, got %d", exit)
	}
}

func TestUndo_AuditSnapshot_Written(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	writeWorkspaceGitConfig(t, workspace, "User", "user@example.com")
	seedJournal(t, fakeHome, []journalEntry{
		identityEntry("id-identity", "sess1", workspace, "", "", "User", "user@example.com"),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 for audit snapshot test, got %d", exit)
	}
	// Look for a journal.ndjson.undone-<timestamp> file.
	dir := filepath.Join(fakeHome, ".ca-bootstrap")
	files, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir %s: %v", dir, err)
	}
	snapshotPattern := regexp.MustCompile(`^journal\.ndjson\.undone-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z$`)
	found := false
	for _, f := range files {
		if snapshotPattern.MatchString(f.Name()) {
			found = true
			break
		}
	}
	if !found {
		var names []string
		for _, f := range files {
			names = append(names, f.Name())
		}
		t.Errorf("expected an audit snapshot file matching %s. dir contents: %v", snapshotPattern, names)
	}
}

// ─────────────────────── alpha.5 folder-taxonomy tests ───────────────────────
//
// folder taxonomy producer + reversers per
// docs/specs/2026-05-28-go-v2-0-alpha-5-spec.md. Producer-side tests
// drive `setup --unattended` and assert on workspace filesystem state.
// Reverser-side tests seed journal entries (action: create_folder,
// rename_folder, seed_readme, remove_empty_folder) and drive `undo`
// to verify reversal behavior.

// folderCreateEntry builds a create_folder journal entry for use in
// seedJournal. Target is the full filesystem path of the created
// folder (matches what the alpha.5 producer emits).
func folderCreateEntry(id, sessionID, path string) journalEntry {
	return journalEntry{
		ID:        id,
		TS:        time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC),
		SessionID: sessionID,
		Action:    "create_folder",
		Target:    path,
		Result:    "ok",
	}
}

// renameFolderEntry builds a rename_folder entry. The Before map
// carries from + to (the rename source and destination paths).
func renameFolderEntry(id, sessionID, from, to string) journalEntry {
	return journalEntry{
		ID:        id,
		TS:        time.Date(2026, 5, 28, 12, 1, 0, 0, time.UTC),
		SessionID: sessionID,
		Action:    "rename_folder",
		Before:    map[string]string{"from": from, "to": to},
		Result:    "ok",
	}
}

// seedReadmeEntry builds a seed_readme entry. Target = the README
// path on disk; Before.template = the embed key the producer copied
// from. The reverser hashes embedded bytes from the template key and
// compares to the on-disk file.
func seedReadmeEntry(id, sessionID, target, templateKey string) journalEntry {
	return journalEntry{
		ID:        id,
		TS:        time.Date(2026, 5, 28, 12, 2, 0, 0, time.UTC),
		SessionID: sessionID,
		Action:    "seed_readme",
		Target:    target,
		Before:    map[string]string{"template": templateKey},
		Result:    "ok",
	}
}

// removeEmptyFolderEntry builds a remove_empty_folder entry.
func removeEmptyFolderEntry(id, sessionID, path string) journalEntry {
	return journalEntry{
		ID:        id,
		TS:        time.Date(2026, 5, 28, 12, 3, 0, 0, time.UTC),
		SessionID: sessionID,
		Action:    "remove_empty_folder",
		Target:    path,
		Result:    "ok",
	}
}

// requiredFolders is the alpha.5 required-folder set (matches
// manifest/folders.yaml entries without optional:true). Tests assert
// on these; if folders.yaml changes, update here.
var requiredFolders = []string{
	"ca-tools-repo",
	"ca-docs-repo",
	"ca-platform-repo",
	"cm-product-repo",
	"ca-training-repo",
	"ca-work-dirs-repo",
}

func TestSetupFolders_HappyPath_CreatesAllRequired(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-folders-happy.yaml", workspace)
	_, stderr, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup with folders step: expected exit 0, got %d\nstderr:\n%s", exit, stderr)
	}
	for _, f := range requiredFolders {
		if _, err := os.Stat(filepath.Join(workspace, f)); err != nil {
			t.Errorf("expected required folder %q to exist: %v", f, err)
		}
		if _, err := os.Stat(filepath.Join(workspace, f, "README.md")); err != nil {
			t.Errorf("expected README in %q: %v", f, err)
		}
	}
}

func TestSetupFolders_Idempotent_KeepsExisting(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	// Pre-create one required folder with a custom file inside.
	preExisting := filepath.Join(workspace, "ca-tools-repo")
	if err := os.MkdirAll(preExisting, 0o755); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(preExisting, "sentinel.txt")
	if err := os.WriteFile(sentinel, []byte("preserve me"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := renderUnattendedConfig(t, "unattended-folders-happy.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup idempotent run: expected exit 0, got %d", exit)
	}
	if _, err := os.Stat(sentinel); err != nil {
		t.Errorf("pre-existing sentinel was destroyed: %v", err)
	}
	// Also asserts that the folders step ran (a sibling required folder exists with seeded README).
	if _, err := os.Stat(filepath.Join(workspace, "ca-docs-repo", "README.md")); err != nil {
		t.Errorf("sibling required folder ca-docs-repo/README.md missing — folders step didn't run: %v", err)
	}
}

func TestSetupFolders_OptionalNotCreated(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-folders-happy.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup expected exit 0, got %d", exit)
	}
	// First, confirm the folders step actually ran (a required folder exists).
	if _, err := os.Stat(filepath.Join(workspace, "ca-tools-repo", "README.md")); err != nil {
		t.Fatalf("folders step didn't run — ca-tools-repo/README.md missing: %v", err)
	}
	// Then assert the optional folder was NOT auto-created.
	if _, err := os.Stat(filepath.Join(workspace, "ca-experiments-repo")); !os.IsNotExist(err) {
		t.Errorf("optional folder ca-experiments-repo should not have been created (err=%v)", err)
	}
}

func TestSetupFolders_RenamedFrom_MigratesPredecessor(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	// ca-experiments-repo has renamed_from: experiments. Seed `experiments/` with content.
	// (ca-experiments-repo is optional in folders.yaml, so this exercises optional rename.)
	old := filepath.Join(workspace, "experiments")
	if err := os.MkdirAll(old, 0o755); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(old, "carryover.txt")
	if err := os.WriteFile(sentinel, []byte("must survive rename"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := renderUnattendedConfig(t, "unattended-folders-happy.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup with rename: expected exit 0, got %d", exit)
	}
	if _, err := os.Stat(filepath.Join(workspace, "ca-experiments-repo", "carryover.txt")); err != nil {
		t.Errorf("rename should have moved 'experiments/carryover.txt' → 'ca-experiments-repo/carryover.txt': %v", err)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Errorf("old path 'experiments' should be gone after rename (err=%v)", err)
	}
}

func TestSetupFolders_CollisionNonDirectory_ExitsOne(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	// Write a regular file where a required folder needs to go.
	if err := os.WriteFile(filepath.Join(workspace, "ca-tools-repo"), []byte("not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := renderUnattendedConfig(t, "unattended-folders-happy.yaml", workspace)
	stdout, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit == 0 {
		t.Fatalf("expected non-zero exit on collision, got 0")
	}
	// Wizard step errors flow to ctx.Out (stdout) via wizard.go's
	// `fmt.Fprintln(ctx.Out, "  error:", err)` path. Assert there.
	if !strings.Contains(strings.ToLower(stdout), "not a directory") &&
		!strings.Contains(strings.ToLower(stdout), "exists") {
		t.Errorf("expected stdout to mention the collision. got:\n%s", stdout)
	}
}

func TestSetupFolders_SkipReadmeWhenAlreadyExists(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	// Pre-create ca-tools-repo/README.md with custom content.
	if err := os.MkdirAll(filepath.Join(workspace, "ca-tools-repo"), 0o755); err != nil {
		t.Fatal(err)
	}
	sentinel := "# Custom README — keep me\n"
	readmePath := filepath.Join(workspace, "ca-tools-repo", "README.md")
	if err := os.WriteFile(readmePath, []byte(sentinel), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := renderUnattendedConfig(t, "unattended-folders-happy.yaml", workspace)
	_, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup: expected exit 0, got %d", exit)
	}
	// Confirm folders step ran (a sibling required folder's README exists).
	if _, err := os.Stat(filepath.Join(workspace, "ca-docs-repo", "README.md")); err != nil {
		t.Fatalf("folders step didn't run — ca-docs-repo/README.md missing: %v", err)
	}
	body, _ := os.ReadFile(readmePath)
	if string(body) != sentinel {
		t.Errorf("pre-existing README was overwritten. got:\n%s", body)
	}
}

func TestSetupFolders_ContinueDeclined_ExitsZeroSkip(t *testing.T) {
	bin := buildBinary(t)
	workspace := t.TempDir()
	fakeHome := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-folders-decline.yaml", workspace)
	stdout, _, exit := runSetup(t, bin, fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("declined folders step should exit 0, got %d", exit)
	}
	// No required folder should be created.
	for _, f := range requiredFolders {
		if _, err := os.Stat(filepath.Join(workspace, f)); err == nil {
			t.Errorf("folder %q should not have been created when folders.continue=false", f)
		}
	}
	// stdout must show the folders step ran (and was declined) — distinguishes
	// the GREEN-state "skip" path from the RED-state "step not present" path.
	// "Folder structure" is the step title (matches PS-era); checking that
	// avoids false positives from incidental "folder" mentions in temp paths
	// (e.g. /var/folders/... on macOS).
	if !strings.Contains(stdout, "Folder structure") {
		t.Errorf("expected stdout to print the 'Folder structure' step header. got:\n%s", stdout)
	}
}

// ── undo / reverser side ──

func TestUndo_CreateFolder_Empty_Removes(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	folder := filepath.Join(workspace, "ca-tools-repo")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	seedJournal(t, fakeHome, []journalEntry{
		folderCreateEntry("id-folder", "sess1", folder),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 for empty-folder undo, got %d", exit)
	}
	if _, err := os.Stat(folder); !os.IsNotExist(err) {
		t.Errorf("empty folder should have been removed (err=%v)", err)
	}
}

func TestUndo_CreateFolder_NonEmpty_Refused(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	folder := filepath.Join(workspace, "ca-tools-repo")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	// Put a file inside so the folder is non-empty.
	if err := os.WriteFile(filepath.Join(folder, "leave-me.txt"), []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	seedJournal(t, fakeHome, []journalEntry{
		folderCreateEntry("id-folder", "sess1", folder),
	})
	stdout, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force", // --force = unattended gate, NOT the destructive-folder override
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 with refused folder, got %d. stdout:\n%s", exit, stdout)
	}
	// Folder should still be on disk; reverser refuses non-empty by default.
	if _, err := os.Stat(folder); err != nil {
		t.Errorf("non-empty folder was incorrectly removed: %v", err)
	}
	// stdout must mention the "not empty" / "use --force" path from the
	// CreateFolder reverser. Generic "refused" can leak in via t.TempDir()
	// paths (test name embedded), so we check for the reverser's
	// literal detail string instead.
	low := strings.ToLower(stdout)
	if !strings.Contains(low, "not empty") && !strings.Contains(low, "use --force") {
		t.Errorf("expected stdout to indicate non-empty refusal from CreateFolder reverser. got:\n%s", stdout)
	}
}

func TestUndo_RenameFolder_ReverseRename(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	from := filepath.Join(workspace, "experiments")
	to := filepath.Join(workspace, "ca-experiments-repo")
	// Simulate a previous renamed_from migration: `to` exists, `from` does not.
	if err := os.MkdirAll(to, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(to, "data.txt"), []byte("payload"), 0o644); err != nil {
		t.Fatal(err)
	}
	seedJournal(t, fakeHome, []journalEntry{
		renameFolderEntry("id-rename", "sess1", from, to),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 for rename reversal, got %d", exit)
	}
	if _, err := os.Stat(from); err != nil {
		t.Errorf("rename should have moved back to %s: %v", from, err)
	}
	if _, err := os.Stat(to); !os.IsNotExist(err) {
		t.Errorf("destination %s should be empty after rename reversal", to)
	}
}

func TestUndo_RenameFolder_DestGone_NoOp(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	from := filepath.Join(workspace, "experiments")
	to := filepath.Join(workspace, "ca-experiments-repo")
	// Neither path exists.
	seedJournal(t, fakeHome, []journalEntry{
		renameFolderEntry("id-rename", "sess1", from, to),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 (noop) when destination already gone, got %d", exit)
	}
	// Verify the noop produced an entry_undone marker — that distinguishes
	// the GREEN-state noop reverser from RED-state "action not registered".
	entries := readJournal(t, filepath.Join(fakeHome, ".ca-bootstrap", "journal.ndjson"))
	found := false
	for _, e := range entries {
		if e.Action == "entry_undone" && e.Target == "id-rename" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected entry_undone marker for id-rename (noop should still mark entry as handled). journal:\n%+v", entries)
	}
}

func TestUndo_SeedReadme_TemplateMatch_Removes(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-folders-happy.yaml", workspace)
	_, _, exit := runSetup(t, buildBinary(t), fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup precondition failed (exit %d)", exit)
	}
	readmePath := filepath.Join(workspace, "ca-tools-repo", "README.md")
	// Precondition: setup actually seeded the README. In RED this fails,
	// which is the point — without alpha.5 the test can't proceed.
	if _, err := os.Stat(readmePath); err != nil {
		t.Fatalf("precondition failed: ca-tools-repo/README.md not seeded by setup (err=%v)", err)
	}
	_, _, exit = runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("undo expected exit 0, got %d", exit)
	}
	if _, err := os.Stat(readmePath); !os.IsNotExist(err) {
		t.Errorf("README that hash-matched the template should have been removed (err=%v)", err)
	}
}

func TestUndo_SeedReadme_Diverged_Skipped(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	cfg := renderUnattendedConfig(t, "unattended-folders-happy.yaml", workspace)
	_, _, exit := runSetup(t, buildBinary(t), fixture(t, "two-real-tools.yaml"), cfg, fakeHome)
	if exit != 0 {
		t.Fatalf("setup precondition failed (exit %d)", exit)
	}
	readmePath := filepath.Join(workspace, "ca-tools-repo", "README.md")
	// Precondition — same as the match test.
	if _, err := os.Stat(readmePath); err != nil {
		t.Fatalf("precondition failed: ca-tools-repo/README.md not seeded by setup (err=%v)", err)
	}
	if err := os.WriteFile(readmePath, []byte("# User-edited content — preserve me\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	stdout, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("undo with diverged README: expected exit 0 (skip not fail), got %d", exit)
	}
	if _, err := os.Stat(readmePath); err != nil {
		t.Errorf("user-edited README should have been preserved: %v", err)
	}
	if !strings.Contains(strings.ToLower(stdout), "diverged") &&
		!strings.Contains(strings.ToLower(stdout), "preserv") {
		t.Errorf("expected stdout to mention the divergence/preservation. got:\n%s", stdout)
	}
}

func TestUndo_RemoveEmptyFolder_Recreates(t *testing.T) {
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	folder := filepath.Join(workspace, "ca-tools-repo")
	// Folder does not exist; the entry says it was previously removed.
	seedJournal(t, fakeHome, []journalEntry{
		removeEmptyFolderEntry("id-removed", "sess1", folder),
	})
	_, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("expected exit 0 for remove_empty_folder recreation, got %d", exit)
	}
	if _, err := os.Stat(folder); err != nil {
		t.Errorf("folder should have been recreated: %v", err)
	}
}

func TestUndo_AuditSnapshot_FailureWarnsNotFails(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX-only: relies on chmod to force a copy failure")
	}
	bin := buildBinary(t)
	fakeHome := t.TempDir()
	workspace := t.TempDir()
	writeWorkspaceGitConfig(t, workspace, "User", "user@example.com")
	seedJournal(t, fakeHome, []journalEntry{
		identityEntry("id-identity", "sess1", workspace, "", "", "User", "user@example.com"),
	})
	// Pre-create session.lock so the binary can OPEN it for write
	// (file already exists; flock on an existing fd doesn't need dir
	// write perm). After the chmod, *creating* new files in the dir
	// (the snapshot copy) fails — that's the failure we're exercising.
	dir := filepath.Join(fakeHome, ".ca-bootstrap")
	if err := os.WriteFile(filepath.Join(dir, "session.lock"), nil, 0o600); err != nil {
		t.Fatalf("seed lock: %v", err)
	}
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	defer func() { _ = os.Chmod(dir, 0o755) }() // let TempDir cleanup work

	stdout, _, exit := runUndo(t, bin, fakeHome,
		"--unattended", "--config", fixture(t, "unattended-undo-proceed.yaml"),
		"--force",
	)
	if exit != 0 {
		t.Fatalf("snapshot failure should be warn-not-fail; got exit %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(strings.ToLower(stdout), "snapshot") {
		t.Errorf("expected stdout to mention the snapshot failure/warning. got:\n%s", stdout)
	}
}
