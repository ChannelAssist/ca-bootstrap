// Package repos clones the workspace repo set (legacy step 60). For
// each group in repos.yaml it prompts, then clones each repo into its
// destination under the workspace, skipping already-cloned repos and
// warning on path collisions that aren't valid clones.
//
// A clone seam (env var CA_BOOTSTRAP_CLONE_MOCK) lets acceptance tests
// and unattended runs exercise the clone/skip/fail paths without
// network access — mirroring the mock seams in internal/install and
// internal/ghauth. Mock grammar:
//
//	"ok"          → every clone succeeds (creates the dest dir)
//	"fail:<slug>" → the named repo fails; everything else succeeds
//	""            → real `gh repo clone`
package repos

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
	"github.com/ChannelAssist/ca-bootstrap/internal/prompt"
)

// cloneTimeout bounds a single clone. The legacy "large" monolith can
// take 10+ minutes, so this is generous; overridable in tests.
var cloneTimeout = 30 * time.Minute

// fetchTimeout bounds the best-effort fetch of an already-cloned repo.
// Much shorter than cloneTimeout — a fetch shouldn't take minutes, and
// a hung fetch must not stall the wizard.
var fetchTimeout = 2 * time.Minute

// Options drive Apply.
type Options struct {
	Out          io.Writer
	Prompter     prompt.Prompter
	WorkspaceDir string
	Session      *journal.Session
}

// Summary collects per-run aggregates.
type Summary struct {
	Cloned   int
	Fetched  int
	Skipped  int
	Mismatch int
	Failed   int
	Failures []string
}

// cloneState is the result of inspecting a destination path.
type cloneState int

const (
	stateAbsent   cloneState = iota // nothing there → clone
	stateMatches                    // a valid clone of the expected repo → skip
	stateMismatch                   // a path exists but isn't a clone of this repo → warn+skip
)

// Apply walks the repos manifest group by group, prompting and cloning.
// Returns ErrUserQuit if the user quits at a prompt. Clone failures are
// non-fatal (counted in the summary) so one unreachable repo doesn't
// abort the whole setup.
func Apply(m *manifest.ReposManifest, opts Options) (Summary, error) {
	var s Summary
	if opts.WorkspaceDir == "" {
		return s, errors.New("repos: workspace dir is empty")
	}

	for _, g := range m.Groups {
		allOptIn := true
		for _, r := range g.Repos {
			if !r.OptIn {
				allOptIn = false
				break
			}
		}
		groupDefault := "y"
		if allOptIn {
			groupDefault = "n"
		}
		fmt.Fprintf(opts.Out, "  Group: %s — %s\n", g.Name, g.Description)
		yes, err := opts.Prompter.YesNo("repos.group."+g.Name, groupDefault)
		if errors.Is(err, prompt.ErrQuit) || (opts.Prompter != nil && opts.Prompter.Quit()) {
			return s, ErrUserQuit
		}
		if err != nil {
			return s, fmt.Errorf("repos: group %s prompt: %w", g.Name, err)
		}
		if !yes {
			s.Skipped += len(g.Repos)
			fmt.Fprintf(opts.Out, "    ↷ %s skipped (%d repos)\n", g.Name, len(g.Repos))
			continue
		}

		for _, r := range g.Repos {
			if quit, err := opts.cloneRepo(r, m.DefaultProtocol, &s); err != nil {
				return s, err
			} else if quit {
				return s, ErrUserQuit
			}
		}
	}
	return s, nil
}

// cloneRepo handles one repo: collision checks, opt-in/membership
// gating, the clone itself, journaling, and partial-failure cleanup.
// Returns (quit, err).
func (opts Options) cloneRepo(r manifest.Repo, defaultProtocol string, s *Summary) (bool, error) {
	into := filepath.Join(opts.WorkspaceDir, r.Into)
	if !filepath.IsAbs(into) {
		return false, fmt.Errorf("repos: computed clone path %q is not absolute", into)
	}

	if r.RequiresMembership {
		// Private/member-only repo. Determining membership needs another
		// gh round-trip; for now skip with a note rather than fail a
		// non-member's run (members can clone it manually).
		fmt.Fprintf(opts.Out, "    ↷ %s skipped (requires org membership)\n", r.Repo)
		s.Skipped++
		return false, nil
	}

	switch checkClone(into, r.Repo) {
	case stateMatches:
		fmt.Fprintf(opts.Out, "    ↷ %s already cloned\n", r.Repo)
		if fetch(into) {
			s.Fetched++
		}
		return false, nil
	case stateMismatch:
		fmt.Fprintf(opts.Out, "    ⚠ %s — path exists but isn't a valid clone; skipping (%s)\n", r.Repo, into)
		s.Mismatch++
		return false, nil
	}

	// Absent → decide whether to clone.
	if r.OptIn {
		if r.Warn != "" {
			fmt.Fprintf(opts.Out, "    ⓘ %s\n", r.Warn)
		}
		ans, err := opts.Prompter.YesNo("repos.repo."+r.Repo, "n")
		if errors.Is(err, prompt.ErrQuit) || (opts.Prompter != nil && opts.Prompter.Quit()) {
			return true, nil
		}
		if err != nil {
			return false, fmt.Errorf("repos: %s prompt: %w", r.Repo, err)
		}
		if !ans {
			fmt.Fprintf(opts.Out, "    ↷ %s skipped\n", r.Repo)
			s.Skipped++
			return false, nil
		}
	}

	protocol := r.Protocol
	if protocol == "" {
		protocol = defaultProtocol
	}
	fmt.Fprintf(opts.Out, "    … cloning %s → %s\n", r.Repo, r.Into)
	preexisted := dirExists(into)
	if err := clone(r.Repo, into, r.Branch, protocol); err != nil {
		s.Failed++
		s.Failures = append(s.Failures, fmt.Sprintf("%s: %v", r.Repo, err))
		fmt.Fprintf(opts.Out, "    ✗ %s failed: %v\n", r.Repo, err)
		// Partial-failure cleanup: the slot was absent before this run,
		// so restore that state by removing the partial clone. Nothing
		// is journaled — the net effect on this path is zero, and
		// journaling a removal would make undo recreate a folder that
		// never existed before bootstrap ran. (We never remove a dir
		// that pre-existed, so user data is safe.)
		if !preexisted && dirExists(into) {
			_ = os.RemoveAll(into)
		}
		return false, nil
	}
	if opts.Session != nil {
		_ = opts.Session.Append(journal.Entry{
			Action: "clone_repo",
			Target: into,
			Before: map[string]string{"repo": r.Repo, "branch": r.Branch},
			Result: "ok",
		})
	}
	s.Cloned++
	fmt.Fprintf(opts.Out, "    ✓ %s cloned\n", r.Repo)
	return false, nil
}

// checkClone classifies a destination path.
func checkClone(dest, expectedRepo string) cloneState {
	info, err := os.Stat(dest)
	if errors.Is(err, os.ErrNotExist) {
		return stateAbsent
	}
	if err != nil || !info.IsDir() {
		return stateMismatch
	}
	// Directory exists — is it a clone of the expected repo?
	if _, err := os.Stat(filepath.Join(dest, ".git")); err != nil {
		// Non-empty non-git dir is a collision; empty dir we can treat
		// as absent (clone into it).
		if entries, derr := os.ReadDir(dest); derr == nil && len(entries) == 0 {
			return stateAbsent
		}
		return stateMismatch
	}
	// Mock seam: a mock clone records its slug in .git/mock so re-runs
	// can exercise the already-cloned path without a real git remote.
	if os.Getenv("CA_BOOTSTRAP_CLONE_MOCK") != "" {
		b, err := os.ReadFile(filepath.Join(dest, ".git", "mock"))
		if err == nil && strings.EqualFold(strings.TrimSpace(string(b)), expectedRepo) {
			return stateMatches
		}
		return stateMismatch
	}
	out, err := exec.Command("git", "-C", dest, "remote", "get-url", "origin").Output()
	if err != nil {
		return stateMismatch
	}
	if remoteMatches(string(out), expectedRepo) {
		return stateMatches
	}
	return stateMismatch
}

// remoteMatches reports whether a git remote URL points at exactly the
// expected org/name slug. It compares the last two path segments
// case-insensitively rather than a substring, so e.g. ".github" does
// not falsely match a ".github-private" remote.
func remoteMatches(remoteURL, expected string) bool {
	norm := strings.TrimSpace(remoteURL)
	norm = strings.TrimSuffix(norm, ".git")
	norm = strings.TrimSuffix(norm, "/")
	norm = strings.ReplaceAll(norm, ":", "/") // git@github.com:org/name → .../org/name
	parts := strings.Split(norm, "/")
	if len(parts) < 2 {
		return false
	}
	gotSlug := parts[len(parts)-2] + "/" + parts[len(parts)-1]
	return strings.EqualFold(gotSlug, expected)
}

// fetch runs a best-effort `git fetch` in an already-cloned repo.
func fetch(dest string) bool {
	if os.Getenv("CA_BOOTSTRAP_CLONE_MOCK") != "" {
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout)
	defer cancel()
	return exec.CommandContext(ctx, "git", "-C", dest, "fetch", "--quiet").Run() == nil
}

// clone clones repoSlug into dest at branch. Honors the mock seam.
func clone(repoSlug, dest, branch, _ string) error {
	if mock := os.Getenv("CA_BOOTSTRAP_CLONE_MOCK"); mock != "" {
		return mockClone(mock, repoSlug, dest)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return fmt.Errorf("mkdir parent: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), cloneTimeout)
	defer cancel()
	args := []string{"repo", "clone", repoSlug, dest}
	if branch != "" {
		args = append(args, "--", "--branch", branch)
	}
	out, err := exec.CommandContext(ctx, "gh", args...).CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("clone timed out after %s", cloneTimeout)
	}
	if err != nil {
		return fmt.Errorf("%w (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// mockClone simulates a clone: creates a minimal cloned dir (with a
// .git marker so a re-run sees it as present) unless the seam names
// this slug as a failure.
func mockClone(mock, repoSlug, dest string) error {
	if slug, ok := strings.CutPrefix(mock, "fail:"); ok && slug == repoSlug {
		return errors.New("mock clone failure")
	}
	if err := os.MkdirAll(filepath.Join(dest, ".git"), 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dest, ".git", "mock"), []byte(repoSlug), 0o644)
}

func dirExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// ErrUserQuit signals the user quit at a prompt; the wizard maps it to
// exit 130.
var ErrUserQuit = errors.New("repos: user quit")
