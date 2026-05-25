package detect

import "testing"

func TestVersionAtLeast(t *testing.T) {
	cases := []struct {
		name     string
		got, min string
		want     bool
	}{
		{"equal", "1.0.0", "1.0.0", true},
		{"got higher patch", "1.0.1", "1.0.0", true},
		{"got lower patch", "0.9.9", "1.0.0", false},
		{"got higher major", "2.0.0", "1.9.9", true},
		{"got two-part vs three-part min", "1.21", "1.20.0", true},
		{"three-part got vs two-part min", "3.10.4", "3.10", true},
		{"two-part below two-part", "3.10", "3.11", false},
		{"prerelease accepted", "1.0.0-beta.1", "1.0.0", true},
		{"empty min always true", "1.2.3", "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := VersionAtLeast(tc.got, tc.min)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Errorf("VersionAtLeast(%q, %q) = %v, want %v", tc.got, tc.min, got, tc.want)
			}
		})
	}
}

func TestVersionAtLeast_ParseErrors(t *testing.T) {
	if _, err := VersionAtLeast("not-a-version", "1.0.0"); err == nil {
		t.Error("expected error parsing non-numeric got")
	}
	if _, err := VersionAtLeast("1.0.0", "not-a-version"); err == nil {
		t.Error("expected error parsing non-numeric min")
	}
}

func TestExtractVersion(t *testing.T) {
	cases := []struct {
		name, raw, regex, want string
	}{
		{"go", "go version go1.21.5 darwin/arm64", `go(\d+\.\d+(?:\.\d+)?)`, "1.21.5"},
		{"git", "git version 2.43.0", `(\d+\.\d+\.\d+)`, "2.43.0"},
		{"make 2-part", "GNU Make 4.4\n...", `GNU Make (\d+\.\d+)`, "4.4"},
		{"default regex", "v3.2.1\n", "", "3.2.1"},
		{"no match returns empty", "no version here", `(\d+\.\d+\.\d+)`, ""},
		{"invalid regex returns empty", "1.0.0", "[unclosed", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ExtractVersion(tc.raw, tc.regex)
			if got != tc.want {
				t.Errorf("ExtractVersion(%q, %q) = %q, want %q", tc.raw, tc.regex, got, tc.want)
			}
		})
	}
}
