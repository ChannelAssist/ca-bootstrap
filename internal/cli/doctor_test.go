package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// stubDetector returns canned results per tool ID. Missing IDs default
// to "not found" so writing tests is concise.
type stubDetector struct {
	results map[string]detect.Result
}

func (s stubDetector) Probe(t manifest.Tool) detect.Result {
	if r, ok := s.results[t.ID]; ok {
		r.ID = t.ID
		return r
	}
	return detect.Result{ID: t.ID, Found: false}
}

func TestRunDoctor_ClassifiesResults(t *testing.T) {
	m := &manifest.Manifest{Version: 1, Tools: []manifest.Tool{
		{ID: "ok-tool", Detect: manifest.Detect{Command: "ok-tool"}, MinVersion: "1.0.0"},
		{ID: "drift-tool", Detect: manifest.Detect{Command: "drift-tool"}, MinVersion: "2.0.0"},
		{ID: "missing-required", Detect: manifest.Detect{Command: "missing-required"}},
		{ID: "missing-optional", Detect: manifest.Detect{Command: "missing-optional"}, Optional: true},
	}}
	stub := stubDetector{results: map[string]detect.Result{
		"ok-tool":    {Found: true, Version: "1.5.0"},
		"drift-tool": {Found: true, Version: "1.0.0"}, // present but below min
	}}
	var out bytes.Buffer
	exit := runDoctor(&out, m, stub)
	if exit != 2 {
		t.Errorf("expected exit 2 (drift present), got %d", exit)
	}
	s := out.String()
	for _, want := range []string{"✓ ok-tool", "✗ drift-tool", "✗ missing-required", "⚠ missing-optional", "1 ok", "2 drift", "1 missing-optional"} {
		if !strings.Contains(s, want) {
			t.Errorf("doctor output missing %q. Full output:\n%s", want, s)
		}
	}
}

func TestRunDoctor_AllOK_ExitsZero(t *testing.T) {
	m := &manifest.Manifest{Version: 1, Tools: []manifest.Tool{
		{ID: "tool-a", Detect: manifest.Detect{Command: "tool-a"}},
	}}
	stub := stubDetector{results: map[string]detect.Result{
		"tool-a": {Found: true, Version: "1.0.0"},
	}}
	var out bytes.Buffer
	exit := runDoctor(&out, m, stub)
	if exit != 0 {
		t.Errorf("expected exit 0, got %d. Output:\n%s", exit, out.String())
	}
}

func TestRunDoctor_OnlyOptionalMissing_ExitsZero(t *testing.T) {
	m := &manifest.Manifest{Version: 1, Tools: []manifest.Tool{
		{ID: "present", Detect: manifest.Detect{Command: "present"}},
		{ID: "absent-opt", Detect: manifest.Detect{Command: "absent-opt"}, Optional: true},
	}}
	stub := stubDetector{results: map[string]detect.Result{
		"present": {Found: true, Version: "1.0.0"},
	}}
	var out bytes.Buffer
	exit := runDoctor(&out, m, stub)
	if exit != 0 {
		t.Errorf("optional-missing alone should not drift; expected exit 0, got %d", exit)
	}
}

func TestRunDoctor_BelowMinForOptional_DoesNotDrift(t *testing.T) {
	// Optional tool that's present but below min version: surfaces as
	// missing-optional warning (rather than drift), so exit stays 0.
	m := &manifest.Manifest{Version: 1, Tools: []manifest.Tool{
		{ID: "opt-below", Detect: manifest.Detect{Command: "opt-below"}, Optional: true, MinVersion: "5.0.0"},
	}}
	stub := stubDetector{results: map[string]detect.Result{
		"opt-below": {Found: true, Version: "1.0.0"},
	}}
	var out bytes.Buffer
	exit := runDoctor(&out, m, stub)
	if exit != 0 {
		t.Errorf("expected exit 0 (optional below-min ≠ drift), got %d", exit)
	}
}
