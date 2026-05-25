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
