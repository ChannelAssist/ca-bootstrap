// Package detect probes the host for installed tools and parses their
// versions per the manifest schema (spec §8).
//
// Detector is platform-agnostic. Concrete implementations live in
// detect_unix.go (//go:build darwin || linux) and detect_windows.go
// (//go:build windows). Default() returns the build-tag-selected
// implementation; tests pass in stub Detectors.
package detect

import "github.com/ChannelAssist/ca-bootstrap/internal/manifest"

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

// Default returns the platform-appropriate Detector. The concrete
// type is defined and selected by the per-platform source files
// (detect_unix.go, detect_windows.go) via Go build tags.
//
// Defined in this shared file but the underlying type comes from
// the platform file currently being compiled.
