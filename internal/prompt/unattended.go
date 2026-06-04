package prompt

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// FromYAML returns an unattended Prompter backed by the answers in the
// given YAML file. Question strings are interpreted as dotted paths
// into the YAML tree, e.g. "welcome.consent" → answers["welcome"]["consent"].
func FromYAML(path string) (Prompter, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("prompt: config not found at %s", path)
		}
		return nil, fmt.Errorf("prompt: read config %s: %w", path, err)
	}
	var raw map[string]any
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("prompt: parse config %s: %w", path, err)
	}
	return &unattendedPrompter{answers: raw}, nil
}

type unattendedPrompter struct {
	answers map[string]any
}

// errKeyMissing is the sentinel for "the unattended config didn't
// provide an answer for this question." Lets callers distinguish
// missing-key from other failures.
var errKeyMissing = errors.New("prompt: unattended config missing required key")

func (p *unattendedPrompter) YesNo(question, defaultAnswer string) (bool, error) {
	v, ok := p.lookup(question)
	if !ok {
		return false, fmt.Errorf("%w: %s", errKeyMissing, question)
	}
	switch tv := v.(type) {
	case bool:
		return tv, nil
	case string:
		s := strings.ToLower(strings.TrimSpace(tv))
		return s == "true" || s == "y" || s == "yes", nil
	default:
		return false, fmt.Errorf("prompt: %s: expected bool, got %T", question, v)
	}
}

func (p *unattendedPrompter) Line(question, defaultAnswer string) (string, error) {
	v, ok := p.lookup(question)
	if !ok {
		return "", fmt.Errorf("%w: %s", errKeyMissing, question)
	}
	if s, ok := v.(string); ok {
		return s, nil
	}
	return fmt.Sprintf("%v", v), nil
}

func (p *unattendedPrompter) Quit() bool { return false }

// lookup walks a dotted-path question string ("welcome.consent")
// through the nested YAML map and returns the leaf value.
func (p *unattendedPrompter) lookup(dotted string) (any, bool) {
	keys := strings.Split(dotted, ".")
	var cur any = p.answers
	for _, k := range keys {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		v, ok := m[k]
		if !ok {
			return nil, false
		}
		cur = v
	}
	return cur, true
}
