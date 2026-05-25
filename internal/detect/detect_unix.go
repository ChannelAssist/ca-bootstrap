//go:build darwin || linux

package detect

import (
	"os/exec"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// unixDetector implements Detector for macOS and Linux. exec.LookPath
// answers "is it installed?"; the shared runVersionProbe answers
// "at what version?".
type unixDetector struct{}

// Default returns the Unix-flavored Detector. The Windows build tag
// selects a different implementation.
func Default() Detector {
	return unixDetector{}
}

// Probe attempts to find the tool's binary on PATH and parse its
// version via the shared helper. Missing-on-PATH is Found=false with
// no error (clean signal, not failure).
func (unixDetector) Probe(t manifest.Tool) Result {
	path, err := exec.LookPath(t.Detect.Command)
	if err != nil {
		return Result{ID: t.ID} // not on PATH
	}
	return runVersionProbe(path, t)
}
