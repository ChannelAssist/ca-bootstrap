//go:build windows

package detect

import (
	"errors"
	"os/exec"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// windowsDetector implements Detector for Windows. Primary path is
// the same as Unix (LookPath + CombinedOutput); fallback adds a
// `winget list` probe for tools installed via Microsoft Store or
// MSI that may not end up on PATH (Claude Desktop, some Electron
// apps, store-installed games-engines-as-dev-tools, etc.).
type windowsDetector struct{}

// Default returns the Windows-flavored Detector. The Unix build tag
// selects a different implementation.
func Default() Detector {
	return windowsDetector{}
}

// Probe attempts to find the tool's binary on PATH first, then falls
// back to `winget list --id <command>` if not found. Missing entirely
// is Found=false with no error.
func (windowsDetector) Probe(t manifest.Tool) Result {
	r := Result{ID: t.ID}

	// Primary: PATH lookup, same as Unix.
	if path, err := exec.LookPath(t.Detect.Command); err == nil {
		return runVersionAt(t, r, path)
	}

	// Fallback: probe winget for the manifest's command name as an id.
	// (alpha.1 doesn't parse install.windows.winget for a more precise
	// id; alpha.2+ may.)
	if wingetAvailable() && wingetHasPackage(t.Detect.Command) {
		// Found via winget but not on PATH. Can't run --version, so
		// Version is empty; doctor's display logic must tolerate that.
		r.Found = true
		r.VersionRaw = "winget: present (not on PATH)"
		return r
	}
	return r
}

// runVersionAt invokes <path> <version_flag tokens...> and parses the
// resulting output. Same semantics as detect_unix.go's inline block.
func runVersionAt(t manifest.Tool, r Result, path string) Result {
	versionFlag := t.Detect.VersionFlag
	if versionFlag == "" {
		versionFlag = "--version"
	}
	args := strings.Fields(versionFlag)

	cmd := exec.Command(path, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			r.Err = err
			return r
		}
	}
	r.Found = true
	r.VersionRaw = strings.TrimSpace(string(out))
	r.Version = ExtractVersion(r.VersionRaw, t.Detect.VersionRegex)
	return r
}

// wingetAvailable reports whether the `winget` binary is on PATH.
// winget ships with modern Windows (10/11) but can be removed.
func wingetAvailable() bool {
	_, err := exec.LookPath("winget")
	return err == nil
}

// wingetHasPackage runs `winget list --id <id> --exact` and reports
// whether the output indicates a hit. winget exits 0 even for no-match
// so we have to inspect the text.
func wingetHasPackage(id string) bool {
	cmd := exec.Command("winget", "list", "--id", id, "--exact")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return false
	}
	return !strings.Contains(string(out), "No installed package found")
}
