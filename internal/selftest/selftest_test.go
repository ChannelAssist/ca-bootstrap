package selftest

import (
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

func find(results []Result, name string) (Result, bool) {
	for _, r := range results {
		if r.Name == name {
			return r, true
		}
	}
	return Result{}, false
}

func TestProbeWorkspaceWritable_OK(t *testing.T) {
	dir := t.TempDir()
	r := probeWorkspaceWritable(dir)
	if r.Status != StatusOK {
		t.Errorf("writable temp dir: got %s (%s), want ok", r.Status, r.Detail)
	}
}

func TestProbeLink_Mocked(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_SYMLINK_MOCK", "1")
	if r := probeLink(); r.Status != StatusOK {
		t.Errorf("mocked link probe: got %s, want ok", r.Status)
	}
}

func TestProbeLink_Real(t *testing.T) {
	// Real symlink create+remove in a temp dir — works on the unix test hosts.
	t.Setenv("CA_BOOTSTRAP_SYMLINK_MOCK", "")
	if r := probeLink(); r.Status != StatusOK {
		t.Errorf("real link probe: got %s (%s), want ok", r.Status, r.Detail)
	}
}

func TestProbePackageManager_Mock(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_PKGMGR_MOCK", "ok")
	if r := probePackageManager(); r.Status != StatusOK {
		t.Errorf("pkgmgr mock ok: got %s, want ok", r.Status)
	}
	t.Setenv("CA_BOOTSTRAP_PKGMGR_MOCK", "fail")
	if r := probePackageManager(); r.Status != StatusFail {
		t.Errorf("pkgmgr mock fail: got %s, want fail", r.Status)
	}
}

func TestProbeGhAuth_Mock(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:tester")
	if r := probeGhAuth(); r.Status != StatusOK {
		t.Errorf("gh authed: got %s (%s), want ok", r.Status, r.Detail)
	}
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "unauthed")
	if r := probeGhAuth(); r.Status != StatusFail {
		t.Errorf("gh unauthed: got %s, want fail", r.Status)
	}
}

// stubDetector reports a fixed set of tools as present.
type stubDetector struct{ present map[string]bool }

func (s stubDetector) Probe(t manifest.Tool) detect.Result {
	return detect.Result{ID: t.ID, Found: s.present[t.ID], Version: "1.0.0"}
}

func mockProbeManifest() *manifest.Manifest {
	return &manifest.Manifest{Tools: []manifest.Tool{{
		ID:       "mocktool",
		Optional: true,
		Install:  manifest.InstallSpec{Any: &manifest.InstallTarget{Type: "mock", ID: "success"}},
	}}}
}

func TestInstallRoundTrip_AbsentTool_OK(t *testing.T) {
	opts := Options{
		Full:        true,
		ProbeToolID: "mocktool",
		Manifest:    mockProbeManifest(),
		Detector:    stubDetector{present: map[string]bool{}}, // mocktool absent
	}
	r := InstallRoundTrip(opts)
	if r.Status != StatusOK {
		t.Errorf("round-trip of absent mock tool: got %s (%s), want ok", r.Status, r.Detail)
	}
}

func TestInstallRoundTrip_PresentTool_Skips(t *testing.T) {
	opts := Options{
		Full:        true,
		ProbeToolID: "mocktool",
		Manifest:    mockProbeManifest(),
		Detector:    stubDetector{present: map[string]bool{"mocktool": true}}, // already present
	}
	r := InstallRoundTrip(opts)
	if r.Status != StatusSkip {
		t.Errorf("round-trip when tool present: got %s (%s), want skip (never remove a present tool)", r.Status, r.Detail)
	}
}

func TestRun_FullAppendsRoundTrip(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_SYMLINK_MOCK", "1")
	t.Setenv("CA_BOOTSTRAP_PKGMGR_MOCK", "ok")
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:tester")
	opts := Options{
		Full:        true,
		ProbeToolID: "mocktool",
		Manifest:    mockProbeManifest(),
		Detector:    stubDetector{present: map[string]bool{}},
	}
	results := Run(opts)
	if _, ok := find(results, "install-round-trip"); !ok {
		t.Error("Run with Full=true should append the install-round-trip probe")
	}
	if AnyFailed(results) {
		t.Errorf("all-mocked full run should not have failures: %+v", results)
	}
}
