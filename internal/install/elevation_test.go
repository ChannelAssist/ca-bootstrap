package install

import (
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

func TestNeedsElevation(t *testing.T) {
	cases := []struct {
		name string
		t    manifest.InstallTarget
		want bool
	}{
		{"apt", manifest.InstallTarget{Type: "apt", ID: "jq"}, true},
		{"dnf", manifest.InstallTarget{Type: "dnf", ID: "jq"}, true},
		{"snap", manifest.InstallTarget{Type: "snap", ID: "code"}, true},
		{"brew", manifest.InstallTarget{Type: "brew", ID: "jq"}, false},
		{"winget user scope", manifest.InstallTarget{Type: "winget", ID: "Git.Git"}, false},
		{"winget machine scope", manifest.InstallTarget{Type: "winget", ID: "X", Args: "--scope machine"}, true},
		{"npm global", manifest.InstallTarget{Type: "npm", ID: "@x/y", Global: true}, false},
		{"script with sudo", manifest.InstallTarget{Type: "script", URL: "https://x", Args: "&& sudo y"}, true},
		{"script without sudo", manifest.InstallTarget{Type: "script", URL: "https://get.docker.com"}, false},
		{"mock", manifest.InstallTarget{Type: "mock", ID: "fail"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := NeedsElevation(tc.t); got != tc.want {
				t.Errorf("NeedsElevation(%+v) = %v, want %v", tc.t, got, tc.want)
			}
		})
	}
}

func TestManualCommand(t *testing.T) {
	cases := []struct {
		t    manifest.InstallTarget
		want string
	}{
		{manifest.InstallTarget{Type: "apt", ID: "jq"}, "sudo apt-get install -y jq"},
		{manifest.InstallTarget{Type: "brew", ID: "jq"}, "brew install jq"},
		{manifest.InstallTarget{Type: "brew", ID: "powershell", Cask: true}, "brew install --cask powershell"},
	}
	for _, tc := range cases {
		if got := manualCommand(tc.t); got != tc.want {
			t.Errorf("manualCommand(%+v) = %q, want %q", tc.t, got, tc.want)
		}
	}
}
