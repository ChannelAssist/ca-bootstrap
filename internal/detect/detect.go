// Package detect probes the host for installed tools and parses their
// versions per the manifest schema (spec §8).
//
// Detector is platform-agnostic. Concrete implementations live in
// detect_unix.go (//go:build darwin || linux) and detect_windows.go
// (//go:build windows). Default() returns the build-tag-selected
// implementation; tests pass in stub Detectors.
package detect

import (
	"errors"
	"os/exec"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// Detector probes one tool against the host. Implementations are
// platform-specific.
type Detector interface {
	Probe(t manifest.Tool) Result
}

// Result captures the outcome of probing one tool.
type Result struct {
	ID         string
	Found      bool   // true if the binary was located on PATH (or via fallback)
	Version    string // semver-ish parsed from output; "" if Found=false
	VersionRaw string // raw stdout from the version probe; useful for debugging
	Err        error  // non-nil iff the probe failed unexpectedly
}

// runVersionProbe invokes <path> <version_flag tokens...> and parses
// the resulting output. Shared by both platform Detectors so the
// version-flag dispatch + regex-extract logic lives in one place.
//
// Semantics:
//   - Non-zero exit codes are tolerated (some tools exit !=0 from --version).
//   - "process can't start" failures propagate via r.Err.
//   - Empty Version means the regex didn't match; downstream display
//     handles this as "found but unknown version."
func runVersionProbe(path string, t manifest.Tool) Result {
	r := Result{ID: t.ID}
	versionFlag := t.Detect.VersionFlag
	if versionFlag == "" {
		versionFlag = "--version"
	}
	args := strings.Fields(versionFlag) // multi-word flags like "version --client"

	cmd := exec.Command(path, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			r.Err = err
			return r
		}
		// Non-zero exit OK — fall through with output we have.
	}
	r.Found = true
	r.VersionRaw = strings.TrimSpace(string(out))
	r.Version = ExtractVersion(r.VersionRaw, t.Detect.VersionRegex)
	return r
}

// Default returns the platform-appropriate Detector. The concrete
// type is defined and selected by the per-platform source files
// (detect_unix.go, detect_windows.go) via Go build tags.
