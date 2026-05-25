//go:build darwin || linux

package detect

import (
	"errors"
	"os/exec"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// unixDetector implements Detector for macOS and Linux. exec.LookPath
// answers "is it installed?"; running it with the version flag and
// regex-extracting answers "at what version?".
type unixDetector struct{}

// Default returns the Unix-flavored Detector. The Windows build tag
// selects a different implementation.
func Default() Detector {
	return unixDetector{}
}

// Probe attempts to find the tool's binary on PATH and parse its
// version. Missing-on-PATH is Found=false with no error (clean signal,
// not failure). Probe-time crashes propagate via Result.Err.
func (unixDetector) Probe(t manifest.Tool) Result {
	r := Result{ID: t.ID}

	if _, err := exec.LookPath(t.Detect.Command); err != nil {
		// Not on PATH — clean "absent" signal.
		return r
	}

	versionFlag := t.Detect.VersionFlag
	if versionFlag == "" {
		versionFlag = "--version"
	}
	// Whitespace-split so multi-word flags like "version --client"
	// (kubectl) or "env GOOS" become multiple args to exec.Command.
	args := strings.Fields(versionFlag)

	cmd := exec.Command(t.Detect.Command, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			// Failed to start the process — actual error.
			r.Err = err
			return r
		}
		// Exit non-zero is OK for version probes — some tools do that.
		// Fall through with the output we did get.
	}
	r.Found = true
	r.VersionRaw = strings.TrimSpace(string(out))
	r.Version = ExtractVersion(r.VersionRaw, t.Detect.VersionRegex)
	return r
}
