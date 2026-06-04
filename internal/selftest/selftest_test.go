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

// stubDetectorVer reports tools present at a fixed version (for min-version cases).
type stubDetectorVer struct {
	present map[string]bool
	version string
}

func (s stubDetectorVer) Probe(t manifest.Tool) detect.Result {
	return detect.Result{ID: t.ID, Found: s.present[t.ID], Version: s.version}
}

// TestInstallRoundTrip_PresentBelowMin_Skips locks in the review fix: a probe
// tool that is PRESENT but below its min version must still be skipped (it's
// the user's tool — uninstalling it would be destructive), even though it
// classifies as drift/missing-optional rather than OK.
func TestInstallRoundTrip_PresentBelowMin_Skips(t *testing.T) {
	m := &manifest.Manifest{Tools: []manifest.Tool{{
		ID:         "mocktool",
		Optional:   true,
		MinVersion: "99.0.0", // installed 1.0.0 is below this
		Install:    manifest.InstallSpec{Any: &manifest.InstallTarget{Type: "mock", ID: "success"}},
	}}}
	opts := Options{
		Full:        true,
		ProbeToolID: "mocktool",
		Manifest:    m,
		Detector:    stubDetectorVer{present: map[string]bool{"mocktool": true}, version: "1.0.0"},
	}
	if r := InstallRoundTrip(opts); r.Status != StatusSkip {
		t.Errorf("present-but-below-min probe tool: got %s (%s), want skip (never uninstall a tool the user has)", r.Status, r.Detail)
	}
}

// TestInstallRoundTrip_ElevationDeclined_Skips locks in the review fix: a
// declined elevation is the user's choice, not a host incapability, so it's a
// skip — not a fail that would force doctor to exit 2.
func TestInstallRoundTrip_ElevationDeclined_Skips(t *testing.T) {
	m := &manifest.Manifest{Tools: []manifest.Tool{{
		ID:       "mocktool",
		Optional: true,
		Install:  manifest.InstallSpec{Any: &manifest.InstallTarget{Type: "mock", ID: "needs-elevation"}},
	}}}
	opts := Options{
		Full:            true,
		ProbeToolID:     "mocktool",
		Manifest:        m,
		Detector:        stubDetector{present: map[string]bool{}}, // absent
		ElevationAction: "deny",
	}
	if r := InstallRoundTrip(opts); r.Status != StatusSkip {
		t.Errorf("declined elevation: got %s (%s), want skip (not a capability failure)", r.Status, r.Detail)
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
