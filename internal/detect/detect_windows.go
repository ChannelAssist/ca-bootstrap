//go:build windows

package detect

import (
	"context"
	"os/exec"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// windowsDetector implements Detector for Windows. Primary path is the
// same as Unix (LookPath + shared runVersionProbe); fallback adds a
// `winget list` probe for tools installed via Microsoft Store or MSI
// that may not end up on PATH (Claude Desktop, Electron apps, etc.).
type windowsDetector struct{}

// Default returns the Windows-flavored Detector. The Unix build tag
// selects a different implementation.
func Default() Detector {
	return windowsDetector{}
}

// Probe attempts to find the tool's binary on PATH first; if absent,
// falls back to `winget list --id <command>` for store-installed apps.
// Missing entirely is Found=false with no error.
func (windowsDetector) Probe(t manifest.Tool) Result {
	if path, err := exec.LookPath(t.Detect.Command); err == nil {
		return runVersionProbe(path, t)
	}
	if wingetAvailable() && wingetHasPackage(t.Detect.Command) {
		// Found via winget but not on PATH. Version unknown — doctor
		// will display this as "found, requires manual verification."
		return Result{ID: t.ID, Found: true, VersionRaw: "winget: present (not on PATH)"}
	}
	return Result{ID: t.ID}
}

func wingetAvailable() bool {
	_, err := exec.LookPath("winget")
	return err == nil
}

func wingetHasPackage(id string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "winget", wingetListArgs(id)...)
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		// winget wedged (e.g. an interactive prompt despite the flags,
		// or a slow source). Report "not present via winget" rather
		// than hang doctor.
		return false
	}
	if err != nil {
		return false
	}
	// winget list exits 0 even on no-match; check the body text.
	return !strings.Contains(string(out), "No installed package found")
}
