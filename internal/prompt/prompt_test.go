package prompt

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

func TestStdinPrompter_YesNo_DefaultYesOnEmpty(t *testing.T) {
	p := newStdinPrompter(bytes.NewBufferString("\n"), &bytes.Buffer{})
	got, err := p.YesNo("continue?", "y")
	if err != nil {
		t.Fatalf("YesNo: %v", err)
	}
	if !got {
		t.Errorf("expected default=y → true, got false")
	}
}

func TestStdinPrompter_YesNo_DefaultNoOnEmpty(t *testing.T) {
	p := newStdinPrompter(bytes.NewBufferString("\n"), &bytes.Buffer{})
	got, err := p.YesNo("delete?", "n")
	if err != nil {
		t.Fatalf("YesNo: %v", err)
	}
	if got {
		t.Errorf("expected default=n → false, got true")
	}
}

func TestStdinPrompter_YesNo_AcceptsYesAndNo(t *testing.T) {
	cases := []struct {
		input string
		want  bool
	}{
		{"y\n", true}, {"Y\n", true}, {"yes\n", true}, {"YES\n", true},
		{"n\n", false}, {"N\n", false}, {"no\n", false}, {"NO\n", false},
	}
	for _, tc := range cases {
		t.Run(strings.TrimSpace(tc.input), func(t *testing.T) {
			p := newStdinPrompter(bytes.NewBufferString(tc.input), &bytes.Buffer{})
			got, err := p.YesNo("?", "")
			if err != nil {
				t.Fatalf("YesNo: %v", err)
			}
			if got != tc.want {
				t.Errorf("input %q: want %v, got %v", tc.input, tc.want, got)
			}
		})
	}
}

func TestStdinPrompter_YesNo_QuitTriggersQuit(t *testing.T) {
	p := newStdinPrompter(bytes.NewBufferString("q\n"), &bytes.Buffer{})
	_, err := p.YesNo("?", "y")
	if err == nil {
		t.Errorf("expected an error or sentinel return on quit")
	}
	if !p.Quit() {
		t.Errorf("expected Quit() to report true after 'q' input")
	}
}

func TestStdinPrompter_Line_ReturnsDefaultOnEmpty(t *testing.T) {
	p := newStdinPrompter(bytes.NewBufferString("\n"), &bytes.Buffer{})
	got, err := p.Line("name?", "Peter")
	if err != nil {
		t.Fatalf("Line: %v", err)
	}
	if got != "Peter" {
		t.Errorf("expected default 'Peter', got %q", got)
	}
}

func TestStdinPrompter_Line_ReturnsInput(t *testing.T) {
	p := newStdinPrompter(bytes.NewBufferString("Alice\n"), &bytes.Buffer{})
	got, err := p.Line("name?", "default")
	if err != nil {
		t.Fatalf("Line: %v", err)
	}
	if got != "Alice" {
		t.Errorf("expected 'Alice', got %q", got)
	}
}

func TestUnattended_HappyPath(t *testing.T) {
	yamlPath := writeTempYAML(t, `
welcome:
  consent: true
prereqs:
  continue_with_drift: true
identity:
  name: Peter
  email: peter@example.com
`)
	p, err := FromYAML(yamlPath)
	if err != nil {
		t.Fatalf("FromYAML: %v", err)
	}
	got, err := p.YesNo("welcome.consent", "n")
	if err != nil {
		t.Fatalf("YesNo welcome.consent: %v", err)
	}
	if !got {
		t.Errorf("expected welcome.consent=true")
	}
	name, err := p.Line("identity.name", "")
	if err != nil {
		t.Fatalf("Line identity.name: %v", err)
	}
	if name != "Peter" {
		t.Errorf("expected 'Peter', got %q", name)
	}
}

func TestUnattended_MissingKey_Errors(t *testing.T) {
	yamlPath := writeTempYAML(t, `
welcome:
  consent: true
`)
	p, err := FromYAML(yamlPath)
	if err != nil {
		t.Fatalf("FromYAML: %v", err)
	}
	_, err = p.Line("identity.name", "")
	if err == nil {
		t.Errorf("expected error for missing key")
	}
}

func TestUnattended_FileNotFound(t *testing.T) {
	_, err := FromYAML("/tmp/this-yaml-does-not-exist-2026.yaml")
	if err == nil {
		t.Errorf("expected error for missing file")
	}
}

// writeTempYAML writes body to a t.TempDir() file and returns its path.
func writeTempYAML(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "config.yaml")
	if err := writeFile(p, body); err != nil {
		t.Fatalf("write yaml: %v", err)
	}
	return p
}
