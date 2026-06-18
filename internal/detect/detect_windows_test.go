//go:build windows

package detect

import (
	"testing"
	"time"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// These exercise the Windows detector's primary path (LookPath + the shared
// runVersionProbe) and the missing-binary signal on a real Windows runner.
// The winget fallback's argument shape is covered OS-agnostically by
// TestWingetListArgs_NonInteractive in detect_test.go.

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
		t.Error("expected go to be found")
	}
	if r.Version == "" {
		t.Errorf("expected non-empty version, raw=%q", r.VersionRaw)
	}
}

func TestProbe_MissingBinary(t *testing.T) {
	// A name that is neither on PATH nor a real winget package. Bound the
	// winget fallback with a short probe timeout so a slow source can't
	// stretch the test; either way the result must be Found=false, no error.
	orig := probeTimeout
	probeTimeout = 3 * time.Second
	defer func() { probeTimeout = orig }()

	d := Default()
	r := d.Probe(manifest.Tool{
		ID:     "xyzzy-nonexistent",
		Detect: manifest.Detect{Command: "xyzzy-nonexistent"},
	})
	if r.Err != nil {
		t.Errorf("missing binary should NOT be an error: %v", r.Err)
	}
	if r.Found {
		t.Error("expected xyzzy-nonexistent NOT to be found")
	}
}
