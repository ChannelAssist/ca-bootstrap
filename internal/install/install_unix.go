//go:build darwin || linux

package install

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// Default returns the Unix installer (macOS + Linux).
func Default() Installer {
	return genericInstaller{exe: unixExecutor{}}
}

type unixExecutor struct{}

// pick selects the InstallTarget for the current OS/distro.
func (unixExecutor) pick(spec manifest.InstallSpec) *manifest.InstallTarget {
	if runtime.GOOS == "darwin" {
		if spec.Macos != nil {
			return spec.Macos
		}
		return spec.Any
	}
	// linux
	if spec.Linux != nil {
		li := spec.Linux
		if li.Any != nil {
			return li.Any
		}
		if isDebianLike() && li.Debian != nil {
			return li.Debian
		}
		if !isDebianLike() && li.Rhel != nil {
			return li.Rhel
		}
		// flat linux target (e.g. linux: { type: snap, id: code })
		if li.Type != "" {
			return &manifest.InstallTarget{Type: li.Type, ID: li.ID, Classic: li.Classic}
		}
	}
	return spec.Any
}

// exec builds and runs the install command, streaming output to opts.Out.
func (unixExecutor) exec(t manifest.Tool, target manifest.InstallTarget, elevated bool, opts Options) Result {
	cmdline, err := buildUnixCommand(target, elevated)
	if err != nil {
		return Result{Tool: t.ID, Status: Failed, Err: err}
	}
	fmt.Fprintf(opts.Out, "  Running: %s\n", cmdline)

	if err := runShell(cmdline, opts); err != nil {
		return Result{Tool: t.ID, Status: Failed, Err: err}
	}
	// post_install commands (best-effort; a failure here is still Failed).
	for _, pi := range target.PostInstall {
		fmt.Fprintf(opts.Out, "  Post-install: %s\n", pi)
		if err := runShell(pi, opts); err != nil {
			return Result{Tool: t.ID, Status: Failed, Err: fmt.Errorf("post_install: %w", err)}
		}
	}
	return Result{Tool: t.ID, Status: Installed}
}

// buildUnixCommand renders the shell command for a target. Prepends
// sudo when elevated.
func buildUnixCommand(t manifest.InstallTarget, elevated bool) (string, error) {
	sudo := ""
	if elevated {
		sudo = "sudo "
	}
	switch strings.ToLower(t.Type) {
	case "brew":
		cask := ""
		if t.Cask {
			cask = "--cask "
		}
		return fmt.Sprintf("brew install %s%s", cask, t.ID), nil // brew never elevated
	case "apt":
		return fmt.Sprintf("%sapt-get install -y %s", sudo, t.ID), nil
	case "dnf":
		return fmt.Sprintf("%sdnf install -y %s", sudo, t.ID), nil
	case "snap":
		classic := ""
		if t.Classic {
			classic = " --classic"
		}
		return fmt.Sprintf("%ssnap install %s%s", sudo, t.ID, classic), nil
	case "npm":
		g := ""
		if t.Global {
			g = "-g "
		}
		return fmt.Sprintf("npm install %s%s", g, t.ID), nil
	case "script":
		return fmt.Sprintf("curl -fsSL %s | bash %s", t.URL, t.Args), nil
	case "command":
		return t.Cmd, nil
	default:
		return "", fmt.Errorf("unsupported install type %q on unix", t.Type)
	}
}

// runShell runs a command line via `sh -c`, streaming stdout/stderr to
// opts.Out so the user sees install progress live (spec §2.C-9).
func runShell(cmdline string, opts Options) error {
	cmd := exec.Command("sh", "-c", cmdline)
	cmd.Stdout = opts.Out
	cmd.Stderr = opts.Out
	cmd.Stdin = os.Stdin // sudo password prompt needs the real tty
	return cmd.Run()
}

// isDebianLike returns true on Debian/Ubuntu-family distros (apt) and
// false on RHEL-family (dnf). Best-effort via /etc/os-release.
func isDebianLike() bool {
	data, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return true // default to apt; most ChannelAssist Linux is Ubuntu/WSL
	}
	s := strings.ToLower(string(data))
	if strings.Contains(s, "debian") || strings.Contains(s, "ubuntu") {
		return true
	}
	if strings.Contains(s, "rhel") || strings.Contains(s, "fedora") || strings.Contains(s, "centos") {
		return false
	}
	return true
}
