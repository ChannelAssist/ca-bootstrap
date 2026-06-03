package manifest

import (
	_ "embed"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

//go:embed repos.yaml
var embeddedReposManifest []byte

// ReposManifest is the top-level structure of repos.yaml — the repos to
// clone, grouped by destination folder (legacy step 60).
type ReposManifest struct {
	Version          int     `yaml:"version"`
	DefaultProtocol  string  `yaml:"default_protocol,omitempty"`
	CloneConcurrency int     `yaml:"clone_concurrency,omitempty"`
	Groups           []Group `yaml:"groups"`
}

// Group is a named set of repos cloned together (the unit of the
// group-level clone prompt).
type Group struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description,omitempty"`
	Repos       []Repo `yaml:"repos"`
}

// Repo is one clone target.
type Repo struct {
	Repo               string `yaml:"repo"`                          // org/name slug (required)
	Into               string `yaml:"into"`                          // path under the workspace (required)
	Branch             string `yaml:"branch,omitempty"`              // checkout branch (default: repo default)
	RequiresMembership bool   `yaml:"requires_membership,omitempty"` // skip when the user can't access it
	Large              bool   `yaml:"large,omitempty"`               // warn about size before cloning
	Warn               string `yaml:"warn,omitempty"`                // extra message at the prompt
	OptIn              bool   `yaml:"opt_in,omitempty"`              // not cloned by default; needs explicit yes
	Protocol           string `yaml:"protocol,omitempty"`            // https|ssh — overrides default_protocol
}

// LoadReposDefault returns the embedded repos.yaml unless
// $CA_BOOTSTRAP_REPOS overrides with a filesystem path.
func LoadReposDefault() (*ReposManifest, error) {
	if override := os.Getenv("CA_BOOTSTRAP_REPOS"); override != "" {
		return LoadRepos(override)
	}
	return parseRepos(embeddedReposManifest, "<embedded>")
}

// LoadRepos reads repos.yaml from the given filesystem path.
func LoadRepos(path string) (*ReposManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrNotFound, path)
		}
		return nil, fmt.Errorf("read repos manifest %s: %w", path, err)
	}
	return parseRepos(data, path)
}

func parseRepos(data []byte, source string) (*ReposManifest, error) {
	var m ReposManifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("repos manifest parse error (%s): %w", source, err)
	}
	if m.Version == 0 {
		return nil, fmt.Errorf("repos manifest %s: missing required 'version' field", source)
	}
	if m.Version != 1 {
		return nil, fmt.Errorf("unsupported repos manifest version %d (%s); only v1 is supported", m.Version, source)
	}
	if len(m.Groups) == 0 {
		return nil, fmt.Errorf("repos manifest %s: missing required 'groups' list", source)
	}
	if m.DefaultProtocol == "" {
		m.DefaultProtocol = "https"
	}
	seen := map[string]bool{}
	for gi, g := range m.Groups {
		if g.Name == "" {
			return nil, fmt.Errorf("group at index %d: missing required 'name'", gi)
		}
		for ri, r := range g.Repos {
			if r.Repo == "" {
				return nil, fmt.Errorf("group %s repo[%d]: missing required 'repo'", g.Name, ri)
			}
			if r.Into == "" {
				return nil, fmt.Errorf("group %s repo %s: missing required 'into'", g.Name, r.Repo)
			}
			if seen[r.Into] {
				return nil, fmt.Errorf("duplicate clone destination: %s", r.Into)
			}
			seen[r.Into] = true
		}
	}
	return &m, nil
}
