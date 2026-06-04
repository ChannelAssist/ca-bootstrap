//go:build windows

package install

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// Default returns the Windows installer.
func Default() Installer {
	return genericInstaller{exe: windowsExecutor{}}
}

type windowsExecutor struct{}

func (windowsExecutor) pick(spec manifest.InstallSpec) *manifest.InstallTarget {
	if spec.Windows != nil {
		return spec.Windows
	}
	return spec.Any
}

// exec runs the install command. When elevated, winget machine-scope
// installs trigger a UAC prompt naturally; for other commands we wrap
// in PowerShell Start-Process -Verb RunAs to request elevation.
func (windowsExecutor) exec(t manifest.Tool, target manifest.InstallTarget, elevated bool, opts Options) Result {
	cmdline, err := buildWindowsCommand(target)
	if err != nil {
		return Result{Tool: t.ID, Status: Failed, Err: err}
	}
	fmt.Fprintf(opts.Out, "  Running: %s\n", cmdline)

	var cmd *exec.Cmd
	if elevated {
		// Request UAC elevation via PowerShell Start-Process -Verb RunAs.
		ps := fmt.Sprintf("Start-Process -Wait -Verb RunAs -FilePath cmd -ArgumentList '/c %s'",
			strings.ReplaceAll(cmdline, "'", "''"))
		cmd = exec.Command("powershell", "-NoProfile", "-Command", ps)
	} else {
		cmd = exec.Command("cmd", "/c", cmdline)
	}
	cmd.Stdout = opts.Out
	cmd.Stderr = opts.Out
	cmd.Stdin = os.Stdin
	if err := cmd.Run(); err != nil {
		return Result{Tool: t.ID, Status: Failed, Err: err}
	}
	for _, pi := range target.PostInstall {
		fmt.Fprintf(opts.Out, "  Post-install: %s\n", pi)
		pc := exec.Command("cmd", "/c", pi)
		pc.Stdout = opts.Out
		pc.Stderr = opts.Out
		if err := pc.Run(); err != nil {
			return Result{Tool: t.ID, Status: Failed, Err: fmt.Errorf("post_install: %w", err)}
		}
	}
	return Result{Tool: t.ID, Status: Installed}
}

func buildWindowsCommand(t manifest.InstallTarget) (string, error) {
	switch strings.ToLower(t.Type) {
	case "winget":
		return fmt.Sprintf("winget install --id %s --silent --accept-source-agreements --accept-package-agreements %s",
			t.ID, t.Args), nil
	case "npm":
		g := ""
		if t.Global {
			g = "-g "
		}
		return fmt.Sprintf("npm install %s%s", g, t.ID), nil
	case "command":
		return t.Cmd, nil
	default:
		return "", fmt.Errorf("unsupported install type %q on windows", t.Type)
	}
}
