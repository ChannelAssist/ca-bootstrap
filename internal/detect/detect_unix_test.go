//go:build darwin || linux

package detect

import (
	"os/exec"
	"testing"
	"time"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// TestRunVersionProbe_Timeout proves a hanging --version probe can't
// wedge detection: with a short probeTimeout, a `sleep`-backed probe
// returns promptly with Found=false and a timeout error. Guards the
// fresh-Windows hang fix at the shared-probe layer (sleep is POSIX, so
// this lives in the unix-tagged test file).
func TestRunVersionProbe_Timeout(t *testing.T) {
	sleepPath, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip("sleep not available")
	}
	orig := probeTimeout
	probeTimeout = 150 * time.Millisecond
	defer func() { probeTimeout = orig }()

	tool := manifest.Tool{
		ID:     "sleepy",
		Detect: manifest.Detect{Command: "sleep", VersionFlag: "5"},
	}
	start := time.Now()
	r := runVersionProbe(sleepPath, tool)
	elapsed := time.Since(start)

	if r.Found {
		t.Error("expected Found=false when the probe times out")
	}
	if r.Err == nil {
		t.Error("expected a timeout error")
	}
	if elapsed > 2*time.Second {
		t.Errorf("probe ignored the timeout (took %s)", elapsed)
	}
}

func TestProbe_GoBinary(t *testing.T) {
	d := Default()
	r := d.Probe(manifest.Tool{
		ID:   "go",
		Name: "Go",
		Detect: manifest.Detect{
			Command:      "go",
			VersionFlag:  "version",
			VersionRegex: `go(\d+\.\d+(?:\.\d+)?)`,
		},
	})
	if r.Err != nil {
		t.Fatalf("unexpected probe error: %v", r.Err)
	}
	if !r.Found {
		t.Errorf("expected go to be found")
	}
	if r.Version == "" {
		t.Errorf("expected non-empty version, got raw=%q", r.VersionRaw)
	}
}

func TestProbe_MissingBinary(t *testing.T) {
	d := Default()
	r := d.Probe(manifest.Tool{
		ID:     "xyzzy-nonexistent",
		Detect: manifest.Detect{Command: "xyzzy-nonexistent"},
	})
	if r.Err != nil {
		t.Errorf("missing binary should NOT be an error: %v", r.Err)
	}
	if r.Found {
		t.Errorf("expected xyzzy-nonexistent NOT to be found")
	}
	if r.Version != "" {
		t.Errorf("expected empty version for missing binary, got %q", r.Version)
	}
}

func TestProbe_MultiArgVersionFlag(t *testing.T) {
	// `go env GOOS` is a multi-arg flag scenario (whitespace-split).
	// Asserts that detect splits version_flag on whitespace and passes
	// multiple args to exec.Command.
	d := Default()
	r := d.Probe(manifest.Tool{
		ID: "go-env",
		Detect: manifest.Detect{
			Command:      "go",
			VersionFlag:  "env GOOS",
			VersionRegex: `^(\w+)`,
		},
	})
	if r.Err != nil {
		t.Fatalf("unexpected probe error: %v", r.Err)
	}
	if !r.Found {
		t.Errorf("expected found=true")
	}
	if r.Version == "" {
		t.Errorf("expected non-empty GOOS, raw=%q", r.VersionRaw)
	}
}
