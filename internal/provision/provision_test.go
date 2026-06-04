package provision

import (
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// stubDetector reports a tool as present (with a version) iff its id is in
// the present map; anything else is treated as not found.
type stubDetector struct{ present map[string]string }

func (s stubDetector) Probe(t manifest.Tool) detect.Result {
	if v, ok := s.present[t.ID]; ok {
		return detect.Result{ID: t.ID, Found: true, Version: v}
	}
	return detect.Result{ID: t.ID, Found: false}
}

func ids(tools []manifest.Tool) []string {
	out := make([]string, len(tools))
	for i, t := range tools {
		out[i] = t.ID
	}
	return out
}

func TestMissing_RequiredVsOptional(t *testing.T) {
	m := &manifest.Manifest{Tools: []manifest.Tool{
		{ID: "req-present", Optional: false},
		{ID: "req-missing", Optional: false},
		{ID: "opt-missing", Optional: true},
		{ID: "opt-present", Optional: true},
	}}
	det := stubDetector{present: map[string]string{
		"req-present": "1.0.0",
		"opt-present": "2.0.0",
	}}

	// Required-only: just the missing required tool.
	got := ids(Missing(m, det, false))
	if len(got) != 1 || got[0] != "req-missing" {
		t.Errorf("Missing(includeOptional=false) = %v, want [req-missing]", got)
	}

	// Include optional: missing required + missing optional, manifest order.
	got = ids(Missing(m, det, true))
	want := []string{"req-missing", "opt-missing"}
	if len(got) != len(want) {
		t.Fatalf("Missing(includeOptional=true) = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("Missing(includeOptional=true)[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestMissing_AllPresent_Empty(t *testing.T) {
	m := &manifest.Manifest{Tools: []manifest.Tool{
		{ID: "a", Optional: false},
		{ID: "b", Optional: true},
	}}
	det := stubDetector{present: map[string]string{"a": "1.0.0", "b": "1.0.0"}}
	if got := Missing(m, det, true); len(got) != 0 {
		t.Errorf("Missing with all present = %v, want empty", ids(got))
	}
}

func TestSummary_AllOK(t *testing.T) {
	if !(Summary{Installed: []string{"x"}}).AllOK() {
		t.Error("Summary with only Installed should be AllOK")
	}
	if (Summary{Failed: []string{"x"}}).AllOK() {
		t.Error("Summary with a Failed entry should not be AllOK")
	}
	if (Summary{Skipped: []string{"x"}}).AllOK() {
		t.Error("Summary with a Skipped entry should not be AllOK")
	}
	if (Summary{Declined: true}).AllOK() {
		t.Error("Summary with Declined should not be AllOK")
	}
}
