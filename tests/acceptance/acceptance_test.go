//go:build acceptance

// Package acceptance contains the 7 mandatory acceptance tests for
// ca-bootstrap v2.0.0-alpha.1 (spec §9.2). They MUST exist and fail
// before any non-test code in internal/ or cmd/ is committed.
//
// Run: go test -tags acceptance ./tests/acceptance/...
package acceptance

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
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
//   ^ca-bootstrap (\S+) \(commit (\S+), built (\S+)\)$
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
		emailLine := "  email: \"test@example.com\""
		body = strings.Replace(body, emailLine,
			emailLine+"\n  workspace_root: \""+workspace+"\"", 1)
	}
	dst := filepath.Join(t.TempDir(), fixtureName)
	if err := os.WriteFile(dst, []byte(body), 0644); err != nil {
		t.Fatalf("write rendered fixture: %v", err)
	}
	return dst
}

// runSetup is like run() but for the setup subcommand. Sets up:
//   - $CA_BOOTSTRAP_MANIFEST (override path)
//   - $HOME (so the journal lands in the test sandbox)
//   - $CA_BOOTSTRAP_ASCII=1 (so output is grep-able regardless of console)
// Returns stdout, stderr, exit code.
func runSetup(t *testing.T, binPath string, manifestPath, configPath, fakeHome string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(binPath, "setup", "--unattended", "--config", configPath)
	env := append(os.Environ(),
		"CA_BOOTSTRAP_MANIFEST="+manifestPath,
		"HOME="+fakeHome,
		"CA_BOOTSTRAP_ASCII=1",
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
