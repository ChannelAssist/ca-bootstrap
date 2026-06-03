package reversers

import (
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/folders"
	"github.com/ChannelAssist/ca-bootstrap/internal/identity"
	"github.com/ChannelAssist/ca-bootstrap/internal/journal"
	"github.com/ChannelAssist/ca-bootstrap/internal/undo"
)

// fakePrompter answers every YesNo with a fixed value. Used to exercise
// the per-tool consent gate without real stdin.
type fakePrompter struct {
	answer bool
	quit   bool
}

func (f fakePrompter) YesNo(string, string) (bool, error) { return f.answer, nil }
func (f fakePrompter) Line(_, def string) (string, error) { return def, nil }
func (f fakePrompter) Quit() bool                         { return f.quit }

// ---- Identity ----

func TestIdentity_RestoresPreviousValues(t *testing.T) {
	ws := t.TempDir()
	if err := identity.SetWorkspaceIdentity(ws, "New Name", "new@example.com"); err != nil {
		t.Fatal(err)
	}
	e := journal.Entry{
		Action: "identity_set",
		Target: filepath.Join(ws, ".git", "config"),
		Before: map[string]string{"user.name": "Old Name", "user.email": "old@example.com"},
	}
	out := Identity{}.Reverse(e, undo.Options{})
	if out.Status != "ok" {
		t.Fatalf("status = %q (%s), want ok", out.Status, out.Details)
	}
	name, email, err := identity.GetWorkspaceIdentity(ws)
	if err != nil {
		t.Fatalf("GetWorkspaceIdentity: %v", err)
	}
	if name != "Old Name" || email != "old@example.com" {
		t.Errorf("restored identity = %q/%q, want Old Name/old@example.com", name, email)
	}
}

func TestIdentity_EmptyBefore_ClearsUserBlock(t *testing.T) {
	ws := t.TempDir()
	if err := identity.SetWorkspaceIdentity(ws, "Solo", "solo@example.com"); err != nil {
		t.Fatal(err)
	}
	e := journal.Entry{
		Action: "identity_set",
		Target: filepath.Join(ws, ".git", "config"),
		Before: map[string]string{},
	}
	out := Identity{}.Reverse(e, undo.Options{})
	if out.Status != "ok" {
		t.Fatalf("status = %q (%s), want ok", out.Status, out.Details)
	}
	name, email, _ := identity.GetWorkspaceIdentity(ws)
	if name != "" || email != "" {
		t.Errorf("expected cleared identity, got %q/%q", name, email)
	}
}

func TestIdentity_MissingTarget_Fails(t *testing.T) {
	out := Identity{}.Reverse(journal.Entry{Action: "identity_set"}, undo.Options{})
	if out.Status != "fail" {
		t.Errorf("status = %q, want fail", out.Status)
	}
}

// ---- ToolInstall ----

func toolEntry(target, method, pkg string) journal.Entry {
	return journal.Entry{
		Action: "install_success",
		Target: target,
		After:  map[string]string{"method": method, "package_id": pkg},
	}
}

func TestToolInstall_MissingMethod_Fails(t *testing.T) {
	e := journal.Entry{Action: "install_success", Target: "ripgrep"}
	out := ToolInstall{}.Reverse(e, undo.Options{IncludeTools: true})
	if out.Status != "fail" {
		t.Errorf("status = %q, want fail", out.Status)
	}
}

func TestToolInstall_DefaultSkipsWithoutIncludeTools(t *testing.T) {
	out := ToolInstall{}.Reverse(toolEntry("ripgrep", "mock", "ripgrep"), undo.Options{})
	if out.Status != "skip" {
		t.Errorf("status = %q, want skip", out.Status)
	}
}

func TestToolInstall_IncludeTools_ConsentYes_Uninstalls(t *testing.T) {
	out := ToolInstall{}.Reverse(
		toolEntry("ripgrep", "mock", "ripgrep"),
		undo.Options{IncludeTools: true, Prompter: fakePrompter{answer: true}},
	)
	if out.Status != "ok" {
		t.Errorf("status = %q (%s), want ok", out.Status, out.Details)
	}
}

func TestToolInstall_IncludeTools_ConsentNo_Skips(t *testing.T) {
	out := ToolInstall{}.Reverse(
		toolEntry("ripgrep", "mock", "ripgrep"),
		undo.Options{IncludeTools: true, Prompter: fakePrompter{answer: false}},
	)
	if out.Status != "skip" {
		t.Errorf("status = %q, want skip", out.Status)
	}
}

func TestToolInstall_UninstallFailure_Fails(t *testing.T) {
	// The mock uninstaller fails for package id "fail".
	out := ToolInstall{}.Reverse(
		toolEntry("badtool", "mock", "fail"),
		undo.Options{IncludeTools: true, Prompter: fakePrompter{answer: true}},
	)
	if out.Status != "fail" {
		t.Errorf("status = %q, want fail", out.Status)
	}
}

// ---- CreateFolder ----

func TestCreateFolder_Empty_Removes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ca-tools")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	out := CreateFolder{}.Reverse(journal.Entry{Action: "create_folder", Target: dir}, undo.Options{})
	if out.Status != "ok" {
		t.Fatalf("status = %q (%s), want ok", out.Status, out.Details)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("dir should be removed; stat err=%v", err)
	}
}

func TestCreateFolder_NonEmpty_Refused(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ca-tools")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "f.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := CreateFolder{}.Reverse(journal.Entry{Action: "create_folder", Target: dir}, undo.Options{})
	if out.Status != "refused" {
		t.Errorf("status = %q, want refused", out.Status)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Errorf("refused folder should still exist: %v", err)
	}
}

func TestCreateFolder_NonEmpty_IncludeFolders_Removes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ca-tools")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "f.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := CreateFolder{}.Reverse(
		journal.Entry{Action: "create_folder", Target: dir},
		undo.Options{IncludeFolders: true},
	)
	if out.Status != "ok" {
		t.Errorf("status = %q (%s), want ok", out.Status, out.Details)
	}
}

func TestCreateFolder_Absent_Noop(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "never-existed")
	out := CreateFolder{}.Reverse(journal.Entry{Action: "create_folder", Target: dir}, undo.Options{})
	if out.Status != "noop" {
		t.Errorf("status = %q, want noop", out.Status)
	}
}

func TestCreateFolder_MissingTarget_Fails(t *testing.T) {
	out := CreateFolder{}.Reverse(journal.Entry{Action: "create_folder"}, undo.Options{})
	if out.Status != "fail" {
		t.Errorf("status = %q, want fail", out.Status)
	}
}

// ---- RenameFolder ----

func TestRenameFolder_ReversesRename(t *testing.T) {
	ws := t.TempDir()
	from := filepath.Join(ws, "experiments")
	to := filepath.Join(ws, "ca-experiments")
	if err := os.MkdirAll(to, 0o755); err != nil {
		t.Fatal(err)
	}
	e := journal.Entry{Action: "rename_folder", Before: map[string]string{"from": from, "to": to}}
	out := RenameFolder{}.Reverse(e, undo.Options{})
	if out.Status != "ok" {
		t.Fatalf("status = %q (%s), want ok", out.Status, out.Details)
	}
	if _, err := os.Stat(from); err != nil {
		t.Errorf("expected folder back at %s: %v", from, err)
	}
	if _, err := os.Stat(to); !os.IsNotExist(err) {
		t.Errorf("expected %s gone after reverse; err=%v", to, err)
	}
}

func TestRenameFolder_DestGone_Noop(t *testing.T) {
	ws := t.TempDir()
	e := journal.Entry{Action: "rename_folder", Before: map[string]string{
		"from": filepath.Join(ws, "experiments"),
		"to":   filepath.Join(ws, "ca-experiments"),
	}}
	out := RenameFolder{}.Reverse(e, undo.Options{})
	if out.Status != "noop" {
		t.Errorf("status = %q, want noop", out.Status)
	}
}

func TestRenameFolder_FromOccupied_Skips(t *testing.T) {
	ws := t.TempDir()
	from := filepath.Join(ws, "experiments")
	to := filepath.Join(ws, "ca-experiments")
	if err := os.MkdirAll(from, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(to, 0o755); err != nil {
		t.Fatal(err)
	}
	e := journal.Entry{Action: "rename_folder", Before: map[string]string{"from": from, "to": to}}
	out := RenameFolder{}.Reverse(e, undo.Options{})
	if out.Status != "skip" {
		t.Errorf("status = %q, want skip (from occupied)", out.Status)
	}
}

func TestRenameFolder_MissingBefore_Fails(t *testing.T) {
	out := RenameFolder{}.Reverse(journal.Entry{Action: "rename_folder"}, undo.Options{})
	if out.Status != "fail" {
		t.Errorf("status = %q, want fail", out.Status)
	}
}

// ---- SeedReadme ----

// writeTemplateReadme writes the embedded ca-tools template verbatim to
// dir/README.md so the on-disk hash matches what undo expects.
func writeTemplateReadme(t *testing.T, dir string) string {
	t.Helper()
	body, err := fs.ReadFile(folders.TemplatesFS(), "ca-tools/README.md")
	if err != nil {
		t.Fatalf("read embedded template: %v", err)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "README.md")
	if err := os.WriteFile(p, body, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func seedEntry(target string) journal.Entry {
	return journal.Entry{
		Action: "seed_readme",
		Target: target,
		Before: map[string]string{"template": "ca-tools/README.md"},
	}
}

func TestSeedReadme_TemplateMatch_Removes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ca-tools")
	p := writeTemplateReadme(t, dir)
	out := SeedReadme{}.Reverse(seedEntry(p), undo.Options{})
	if out.Status != "ok" {
		t.Fatalf("status = %q (%s), want ok", out.Status, out.Details)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("README should be removed; stat err=%v", err)
	}
}

func TestSeedReadme_Diverged_Skips(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ca-tools")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "README.md")
	if err := os.WriteFile(p, []byte("user edited this"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := SeedReadme{}.Reverse(seedEntry(p), undo.Options{})
	if out.Status != "skip" {
		t.Errorf("status = %q, want skip (diverged)", out.Status)
	}
	if _, err := os.Stat(p); err != nil {
		t.Errorf("diverged README must be preserved: %v", err)
	}
}

func TestSeedReadme_Absent_Noop(t *testing.T) {
	p := filepath.Join(t.TempDir(), "ca-tools", "README.md")
	out := SeedReadme{}.Reverse(seedEntry(p), undo.Options{})
	if out.Status != "noop" {
		t.Errorf("status = %q, want noop", out.Status)
	}
}

func TestSeedReadme_MissingTarget_Fails(t *testing.T) {
	out := SeedReadme{}.Reverse(journal.Entry{Action: "seed_readme"}, undo.Options{})
	if out.Status != "fail" {
		t.Errorf("status = %q, want fail", out.Status)
	}
}

// ---- RemoveEmptyFolder ----

func TestRemoveEmptyFolder_Recreates(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "gone")
	out := RemoveEmptyFolder{}.Reverse(journal.Entry{Action: "remove_empty_folder", Target: dir}, undo.Options{})
	if out.Status != "ok" {
		t.Fatalf("status = %q (%s), want ok", out.Status, out.Details)
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		t.Errorf("folder not recreated: err=%v", err)
	}
}

func TestRemoveEmptyFolder_AlreadyPresent_Noop(t *testing.T) {
	dir := t.TempDir()
	out := RemoveEmptyFolder{}.Reverse(journal.Entry{Action: "remove_empty_folder", Target: dir}, undo.Options{})
	if out.Status != "noop" {
		t.Errorf("status = %q, want noop", out.Status)
	}
}

func TestRemoveEmptyFolder_MissingTarget_Fails(t *testing.T) {
	out := RemoveEmptyFolder{}.Reverse(journal.Entry{Action: "remove_empty_folder"}, undo.Options{})
	if out.Status != "fail" {
		t.Errorf("status = %q, want fail", out.Status)
	}
}

// ---- GhAuthLogin ----

func TestGhAuthLogin_DefaultSkips(t *testing.T) {
	out := GhAuthLogin{}.Reverse(journal.Entry{Action: "gh_auth_login", Target: "octocat"}, undo.Options{})
	if out.Status != "skip" {
		t.Errorf("status = %q, want skip without --include-tools", out.Status)
	}
}

func TestGhAuthLogin_IncludeTools_LogsOut(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:octocat") // mock logout = noop ok
	out := GhAuthLogin{}.Reverse(journal.Entry{Action: "gh_auth_login", Target: "octocat"}, undo.Options{IncludeTools: true})
	if out.Status != "ok" {
		t.Errorf("status = %q (%s), want ok with --include-tools", out.Status, out.Details)
	}
}
