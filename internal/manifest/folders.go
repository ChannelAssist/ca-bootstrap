package manifest

import (
	_ "embed"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

//go:embed folders.yaml
var embeddedFoldersManifest []byte

// FoldersManifest is the top-level structure of folders.yaml (the
// workspace folder taxonomy spec — alpha.5).
type FoldersManifest struct {
	Version  int      `yaml:"version"`
	RootName string   `yaml:"root_name,omitempty"`
	Folders  []Folder `yaml:"folders"`
}

// Folder is one workspace-folder entry.
//
// RenamedFrom is normalised to []string after parsing — the YAML
// accepts either a scalar (single predecessor) or a list (chain of
// predecessors, most-recent first). Use UnmarshalYAML to flatten.
type Folder struct {
	Path        string   `yaml:"path"`
	Description string   `yaml:"description,omitempty"`
	Optional    bool     `yaml:"optional,omitempty"`
	RenamedFrom []string `yaml:"-"` // populated by UnmarshalYAML below
}

// UnmarshalYAML handles the renamed_from polymorphism (scalar OR list).
// yaml.v3's default behavior would fail to unmarshal a scalar into
// []string; intercepting the unmarshal here normalises both forms.
func (f *Folder) UnmarshalYAML(node *yaml.Node) error {
	// Walk the mapping node's key/value pairs manually so we keep
	// access to the raw renamed_from node for polymorphic handling.
	if node.Kind != yaml.MappingNode {
		return fmt.Errorf("folder: expected mapping, got kind %d", node.Kind)
	}
	for i := 0; i < len(node.Content); i += 2 {
		key := node.Content[i]
		val := node.Content[i+1]
		switch key.Value {
		case "path":
			f.Path = val.Value
		case "description":
			f.Description = val.Value
		case "optional":
			if err := val.Decode(&f.Optional); err != nil {
				return fmt.Errorf("folder %s: optional: %w", f.Path, err)
			}
		case "renamed_from":
			switch val.Kind {
			case yaml.ScalarNode:
				f.RenamedFrom = []string{val.Value}
			case yaml.SequenceNode:
				var list []string
				if err := val.Decode(&list); err != nil {
					return fmt.Errorf("folder %s: renamed_from: %w", f.Path, err)
				}
				f.RenamedFrom = list
			default:
				return fmt.Errorf("folder %s: renamed_from must be a scalar or list", f.Path)
			}
		}
	}
	return nil
}

// LoadFoldersDefault returns the embedded folders.yaml unless
// $CA_BOOTSTRAP_FOLDERS is set (path override for tests + custom
// inventories).
func LoadFoldersDefault() (*FoldersManifest, error) {
	if override := os.Getenv("CA_BOOTSTRAP_FOLDERS"); override != "" {
		return LoadFolders(override)
	}
	return parseFolders(embeddedFoldersManifest, "<embedded>")
}

// LoadFolders reads folders.yaml from the given filesystem path.
func LoadFolders(path string) (*FoldersManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrNotFound, path)
		}
		return nil, fmt.Errorf("read folders manifest %s: %w", path, err)
	}
	return parseFolders(data, path)
}

func parseFolders(data []byte, source string) (*FoldersManifest, error) {
	var m FoldersManifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("folders manifest parse error (%s): %w", source, err)
	}
	if m.Version == 0 {
		return nil, fmt.Errorf("folders manifest %s: missing required 'version' field", source)
	}
	if m.Version != 1 {
		return nil, fmt.Errorf("unsupported folders manifest version %d (%s); only v1 is supported", m.Version, source)
	}
	if len(m.Folders) == 0 {
		return nil, fmt.Errorf("folders manifest %s: missing required 'folders' list", source)
	}
	seen := map[string]bool{}
	for i, f := range m.Folders {
		if f.Path == "" {
			return nil, fmt.Errorf("folder at index %d: missing required 'path'", i)
		}
		if seen[f.Path] {
			return nil, fmt.Errorf("duplicate folder path: %s", f.Path)
		}
		seen[f.Path] = true
	}
	return &m, nil
}
