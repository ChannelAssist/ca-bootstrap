// Package manifest loads and validates the tools manifest YAML.
//
// Default behavior: the manifest is embedded at build time
// (//go:embed below). $CA_BOOTSTRAP_MANIFEST overrides with a
// filesystem path; useful for tests and custom-inventory scenarios
// (spec §6.5).
package manifest

import (
	_ "embed"
	"errors"
	"fmt"
	"os"
	"regexp"

	"gopkg.in/yaml.v3"
)

// ErrNotFound is returned when the manifest file referenced by
// $CA_BOOTSTRAP_MANIFEST does not exist.
var ErrNotFound = errors.New("manifest not found")

//go:embed tools.yaml
var embeddedManifest []byte

// Manifest is the top-level structure of tools.yaml.
type Manifest struct {
	Version int    `yaml:"version"`
	Tools   []Tool `yaml:"tools"`
}

// Tool describes one entry in the manifest's tools list.
type Tool struct {
	ID         string `yaml:"id"`
	Name       string `yaml:"name,omitempty"`
	Optional   bool   `yaml:"optional,omitempty"`
	MinVersion string `yaml:"min_version,omitempty"`
	Detect     Detect `yaml:"detect"`
	// Install is the per-OS install spec. alpha.1/alpha.2 ignored it;
	// alpha.3's repair reads it to dispatch the right installer. Typed
	// (was yaml.Node) as of alpha.3 — see install_schema.go.
	Install InstallSpec `yaml:"install,omitempty"`
	// RequiresElevation is an explicit per-tool opt-in. When false (the
	// default), elevation is inferred from the installer type.
	RequiresElevation bool `yaml:"requires_elevation,omitempty"`
}

// Detect describes how to find a tool and parse its version.
type Detect struct {
	Command      string `yaml:"command"`
	VersionFlag  string `yaml:"version_flag,omitempty"`
	VersionRegex string `yaml:"version_regex,omitempty"`
}

// LoadDefault returns the embedded manifest unless $CA_BOOTSTRAP_MANIFEST
// is set, in which case it loads from that path.
func LoadDefault() (*Manifest, error) {
	if override := os.Getenv("CA_BOOTSTRAP_MANIFEST"); override != "" {
		return Load(override)
	}
	return parseAndValidate(embeddedManifest, "<embedded>")
}

// Load reads the manifest at the given filesystem path.
func Load(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrNotFound, path)
		}
		return nil, fmt.Errorf("read manifest %s: %w", path, err)
	}
	return parseAndValidate(data, path)
}

func parseAndValidate(data []byte, source string) (*Manifest, error) {
	var m Manifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("manifest parse error (%s): %w", source, err)
	}
	if m.Version == 0 {
		return nil, fmt.Errorf("manifest %s: missing required 'version' field", source)
	}
	if m.Version != 1 {
		return nil, fmt.Errorf("unsupported manifest version %d (%s); only v1 is supported", m.Version, source)
	}
	if len(m.Tools) == 0 {
		return nil, fmt.Errorf("manifest %s: missing required 'tools' list", source)
	}
	seen := make(map[string]bool)
	for i, t := range m.Tools {
		if t.ID == "" {
			return nil, fmt.Errorf("tool at index %d: missing required 'id'", i)
		}
		if seen[t.ID] {
			return nil, fmt.Errorf("duplicate tool id: %s", t.ID)
		}
		seen[t.ID] = true
		if t.MinVersion != "" && !semverRegex.MatchString(t.MinVersion) {
			return nil, fmt.Errorf("tool %s: invalid min_version %q", t.ID, t.MinVersion)
		}
		if t.Detect.Command == "" {
			return nil, fmt.Errorf("tool %s: missing required detect.command", t.ID)
		}
	}
	return &m, nil
}

// semverRegex accepts 2-part (e.g. "3.81" for GNU Make) and 3-part
// (e.g. "1.2.3-beta.1") versions. Prerelease/build metadata after a
// `-` or `+` is allowed for both forms. Tools that report
// 2-part versions are common (make, jq) so the strict 3-part rule
// from earlier was too tight.
var semverRegex = regexp.MustCompile(`^\d+\.\d+(?:\.\d+)?(?:[-+][\w.]+)?$`)
