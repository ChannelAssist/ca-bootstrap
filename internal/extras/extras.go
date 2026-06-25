// Package extras implements the optional finishing-touches wizard step
// (legacy step 80): a VS Code multi-root workspace file, workspace
// .vscode/ defaults, a ca-claude-plugin activation symlink, ca-copilot
// usage notes, and (Windows-only) a WSL2 install offer. Each offer is
// independently confirmable and skippable.
//
// Seams for the bits that touch the OS:
//   - CA_BOOTSTRAP_SYMLINK_MOCK — symlink/junction creation is faked
//     (just makes the link path a dir) so tests don't need real links.
//   - CA_BOOTSTRAP_WSL_MOCK     — "has-ubuntu" / "no-ubuntu" / "" controls
//     the Windows WSL probe without a real wsl binary.
package extras

import (
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

//go:embed templates/dot-vscode
var embeddedVSCode embed.FS

var vscodeFiles = []string{"extensions.json", "settings.json", "launch.json", "tasks.json"}

// ErrUserQuit signals the user quit at a prompt (wizard → exit 130).
var ErrUserQuit = errors.New("extras: user quit")

// Options drive Apply.
type Options struct {
	Out          io.Writer
	Prompter     prompt.Prompter
	WorkspaceDir string
	HomeDir      string // ~ ; the Claude plugins dir lives under here
	Session      *journal.Session
}

// Summary lists the extras the user accepted.
type Summary struct{ Actions []string }

// Apply runs the five offers in order, each gated by its own prompt.
func Apply(opts Options) (Summary, error) {
	var s Summary
	if opts.WorkspaceDir == "" {
		return s, errors.New("extras: workspace dir is empty")
	}

	for _, offer := range []func(Options, *Summary) (bool, error){
		offerWorkspaceFile,
		offerVSCodeDefaults,
		offerClaudePlugin,
		offerCopilotInfo,
		offerWSL,
	} {
		if quit, err := offer(opts, &s); err != nil {
			return s, err
		} else if quit {
			return s, ErrUserQuit
		}
	}
	return s, nil
}

// ask is a small helper: prompt + uniform quit handling.
func (opts Options) ask(key, def string) (yes, quit bool, err error) {
	v, perr := opts.Prompter.YesNo(key, def)
	if errors.Is(perr, prompt.ErrQuit) || (opts.Prompter != nil && opts.Prompter.Quit()) {
		return false, true, nil
	}
	if perr != nil {
		return false, false, fmt.Errorf("extras: %s prompt: %w", key, perr)
	}
	return v, false, nil
}

// ---------- 1. VS Code multi-root workspace file ----------

func offerWorkspaceFile(opts Options, s *Summary) (bool, error) {
	yes, quit, err := opts.ask("extras.vscode_workspace_file", "y")
	if quit || err != nil {
		return quit, err
	}
	if !yes {
		fmt.Fprintln(opts.Out, "    ↷ workspace file skipped")
		return false, nil
	}
	repos := discoverClones(opts.WorkspaceDir)
	type folderRef struct {
		Path string `json:"path"`
	}
	doc := struct {
		Folders  []folderRef    `json:"folders"`
		Settings map[string]any `json:"settings"`
	}{Settings: map[string]any{}}
	for _, r := range repos {
		doc.Folders = append(doc.Folders, folderRef{Path: r})
	}
	body, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return false, fmt.Errorf("extras: marshal workspace file: %w", err)
	}
	dst := filepath.Join(opts.WorkspaceDir, "ChannelAssist.code-workspace")
	if err := os.WriteFile(dst, append(body, '\n'), 0o644); err != nil {
		return false, fmt.Errorf("extras: write workspace file: %w", err)
	}
	opts.journal("create_file", dst, nil)
	fmt.Fprintf(opts.Out, "    ✓ wrote %s (%d folders)\n", filepath.Base(dst), len(doc.Folders))
	s.Actions = append(s.Actions, "code-workspace")
	return false, nil
}

// discoverClones returns workspace-relative paths of two-level subdirs
// that look like clones (contain a .git entry). Sorted for determinism.
func discoverClones(workspace string) []string {
	var out []string
	groups, _ := os.ReadDir(workspace)
	for _, g := range groups {
		if !g.IsDir() || strings.HasPrefix(g.Name(), ".") {
			continue
		}
		subs, _ := os.ReadDir(filepath.Join(workspace, g.Name()))
		for _, sub := range subs {
			if !sub.IsDir() {
				continue
			}
			if _, err := os.Stat(filepath.Join(workspace, g.Name(), sub.Name(), ".git")); err == nil {
				out = append(out, g.Name()+"/"+sub.Name())
			}
		}
	}
	sort.Strings(out)
	return out
}

// ---------- 2. workspace .vscode/ defaults ----------

func offerVSCodeDefaults(opts Options, s *Summary) (bool, error) {
	yes, quit, err := opts.ask("extras.vscode_defaults", "y")
	if quit || err != nil {
		return quit, err
	}
	if !yes {
		fmt.Fprintln(opts.Out, "    ↷ .vscode/ defaults skipped")
		return false, nil
	}
	vscodeDir := filepath.Join(opts.WorkspaceDir, ".vscode")
	if _, err := os.Stat(vscodeDir); errors.Is(err, fs.ErrNotExist) {
		if err := os.MkdirAll(vscodeDir, 0o755); err != nil {
			return false, fmt.Errorf("extras: mkdir .vscode: %w", err)
		}
		opts.journal("create_folder", vscodeDir, nil)
	}
	var copied, skipped int
	for _, name := range vscodeFiles {
		dst := filepath.Join(vscodeDir, name)
		if _, err := os.Stat(dst); err == nil {
			skipped++
			continue
		}
		data, err := embeddedVSCode.ReadFile("templates/dot-vscode/" + name)
		if err != nil {
			fmt.Fprintf(opts.Out, "    ⚠ template %s missing — skipping\n", name)
			continue
		}
		if err := os.WriteFile(dst, data, 0o644); err != nil {
			return false, fmt.Errorf("extras: write %s: %w", dst, err)
		}
		opts.journal("create_file", dst, nil)
		copied++
	}
	fmt.Fprintf(opts.Out, "    ✓ .vscode/ defaults: %d written, %d already present\n", copied, skipped)
	if copied > 0 {
		s.Actions = append(s.Actions, "vscode-defaults")
	}
	return false, nil
}

// ---------- 3. ca-claude-plugin activation symlink ----------

func offerClaudePlugin(opts Options, s *Summary) (bool, error) {
	repoPath := filepath.Join(opts.WorkspaceDir, "ca-platform-repo", "ca-claude-plugin")
	if _, err := os.Stat(repoPath); err != nil {
		fmt.Fprintln(opts.Out, "    ⓘ ca-claude-plugin not cloned (skip — clone its group to enable)")
		return false, nil
	}
	yes, quit, err := opts.ask("extras.ca_claude_plugin", "y")
	if quit || err != nil {
		return quit, err
	}
	if !yes {
		fmt.Fprintln(opts.Out, "    ↷ ca-claude-plugin link skipped")
		return false, nil
	}
	home := opts.HomeDir
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	pluginsDir := filepath.Join(home, ".claude", "plugins")
	if err := os.MkdirAll(pluginsDir, 0o755); err != nil {
		return false, fmt.Errorf("extras: mkdir plugins dir: %w", err)
	}
	linkPath := filepath.Join(pluginsDir, "ca-claude-plugin")
	_ = os.Remove(linkPath) // refresh an existing link
	if err := makeLink(repoPath, linkPath); err != nil {
		fmt.Fprintf(opts.Out, "    ✗ plugin link failed: %v\n", err)
		return false, nil // non-fatal
	}
	opts.journal("install_ca_claude_plugin", linkPath, map[string]string{"target": repoPath})
	fmt.Fprintf(opts.Out, "    ✓ linked %s → %s\n", linkPath, repoPath)
	s.Actions = append(s.Actions, "ca-claude-plugin")
	return false, nil
}

// makeLink creates a symlink (junction on Windows) from linkPath to
// target. Honors CA_BOOTSTRAP_SYMLINK_MOCK (fakes it as a directory).
func makeLink(target, linkPath string) error {
	if os.Getenv("CA_BOOTSTRAP_SYMLINK_MOCK") != "" {
		return os.MkdirAll(linkPath, 0o755)
	}
	if runtime.GOOS == "windows" {
		// Junctions don't require Developer Mode / elevation, unlike
		// Windows symlinks.
		return exec.Command("cmd", "/c", "mklink", "/J", linkPath, target).Run()
	}
	return os.Symlink(target, linkPath)
}

// ---------- 4. ca-copilot-plugin usage info ----------

func offerCopilotInfo(opts Options, s *Summary) (bool, error) {
	repoPath := filepath.Join(opts.WorkspaceDir, "ca-platform-repo", "ca-copilot-plugin")
	if _, err := os.Stat(repoPath); err != nil {
		fmt.Fprintln(opts.Out, "    ⓘ ca-copilot-plugin not cloned (skip — clone its group to enable)")
		return false, nil
	}
	yes, quit, err := opts.ask("extras.ca_copilot_plugin", "y")
	if quit || err != nil {
		return quit, err
	}
	if !yes {
		return false, nil
	}
	fmt.Fprintln(opts.Out, "    ⓘ ca-copilot-plugin cloned at:", repoPath)
	fmt.Fprintln(opts.Out, "      Copilot resolves custom agents per-repo from .github/agents/ and")
	fmt.Fprintln(opts.Out, "      prompts from .github/prompts/. No per-developer install — the sync")
	fmt.Fprintln(opts.Out, "      flow surfaces them in consumer repos. See ca-copilot-plugin/README.md.")
	opts.journal("show_ca_copilot_plugin_usage", repoPath, nil) // informational; no reverser
	s.Actions = append(s.Actions, "ca-copilot-plugin")
	return false, nil
}

// ---------- 5. WSL2 + Ubuntu (Windows-only) ----------

func offerWSL(opts Options, s *Summary) (bool, error) {
	if runtime.GOOS != "windows" {
		return false, nil // silent on non-Windows
	}
	if wslHasUbuntu() {
		fmt.Fprintln(opts.Out, "    ↷ WSL with Ubuntu already installed")
		return false, nil
	}
	yes, quit, err := opts.ask("extras.wsl", "n")
	if quit || err != nil {
		return quit, err
	}
	if !yes {
		fmt.Fprintln(opts.Out, "    ↷ WSL install skipped")
		return false, nil
	}
	if err := wslInstall(); err != nil {
		fmt.Fprintf(opts.Out, "    ✗ wsl install failed: %v\n", err)
		return false, nil // non-fatal
	}
	opts.journal("install_wsl", "Ubuntu", nil) // system install; not auto-reversed
	fmt.Fprintln(opts.Out, "    ✓ WSL install started (reboot, then `wsl -d Ubuntu` to finish setup)")
	s.Actions = append(s.Actions, "wsl")
	return false, nil
}

func wslHasUbuntu() bool {
	switch os.Getenv("CA_BOOTSTRAP_WSL_MOCK") {
	case "has-ubuntu":
		return true
	case "no-ubuntu":
		return false
	}
	out, err := exec.Command("wsl", "-l").Output()
	return err == nil && strings.Contains(string(out), "Ubuntu")
}

func wslInstall() error {
	if os.Getenv("CA_BOOTSTRAP_WSL_MOCK") != "" {
		return nil
	}
	return exec.Command("wsl", "--install", "-d", "Ubuntu").Run()
}

// journal appends an entry when a session is present (no-op otherwise).
func (opts Options) journal(action, target string, before map[string]string) {
	if opts.Session == nil {
		return
	}
	_ = opts.Session.Append(journal.Entry{
		Action: action, Target: target, Before: before, Result: "ok",
	})
}
