package install

import (
	"fmt"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// NeedsElevation reports whether an install target requires elevated
// privileges (sudo on Unix, UAC on Windows). Heuristic per spec §2.C-5:
//
//   - apt, dnf            → yes (system package managers need root)
//   - winget --scope machine → yes; plain winget → no (user scope)
//   - snap               → yes (snapd socket needs root on most distros)
//   - brew               → no (user-owned prefix)
//   - npm global         → no (we assume a user-owned global prefix; the
//     install command will fail loudly if not, which is recoverable)
//   - script / command   → yes if the command text contains "sudo"
//   - mock               → no (handled separately)
func NeedsElevation(t manifest.InstallTarget) bool {
	switch strings.ToLower(t.Type) {
	case "apt", "dnf":
		return true
	case "snap":
		return true
	case "winget":
		return strings.Contains(strings.ToLower(t.Args), "--scope machine")
	case "brew", "npm", "mock", "":
		return false
	case "script", "command":
		return strings.Contains(t.Cmd, "sudo ") ||
			strings.Contains(t.Args, "sudo ") ||
			strings.Contains(t.URL, "sudo")
	default:
		return false
	}
}

// manualCommand renders a human-runnable command string for the given
// target — shown in the elevation prompt and in the manual-install
// summary for skipped tools.
func manualCommand(t manifest.InstallTarget) string {
	switch strings.ToLower(t.Type) {
	case "apt":
		return fmt.Sprintf("sudo apt-get install -y %s", t.ID)
	case "dnf":
		return fmt.Sprintf("sudo dnf install -y %s", t.ID)
	case "snap":
		classic := ""
		if t.Classic {
			classic = " --classic"
		}
		return fmt.Sprintf("sudo snap install %s%s", t.ID, classic)
	case "brew":
		cask := ""
		if t.Cask {
			cask = " --cask"
		}
		return fmt.Sprintf("brew install%s %s", cask, t.ID)
	case "winget":
		return fmt.Sprintf("winget install --id %s %s", t.ID, t.Args)
	case "npm":
		g := ""
		if t.Global {
			g = " -g"
		}
		return fmt.Sprintf("npm install%s %s", g, t.ID)
	case "script":
		return fmt.Sprintf("curl -fsSL %s | bash %s", t.URL, t.Args)
	case "command":
		return t.Cmd
	default:
		return fmt.Sprintf("(install %s manually)", t.ID)
	}
}
