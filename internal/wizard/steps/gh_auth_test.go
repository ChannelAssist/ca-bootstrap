package steps

import (
	"io"
	"strings"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/wizard"
)

// (stepPrompter is defined in folders_test.go — same package.)

func TestGhAuth_Title(t *testing.T) {
	if (GhAuth{}).Title() != "GitHub authentication" {
		t.Errorf("Title = %q", (GhAuth{}).Title())
	}
}

func TestGhAuth_AlreadyAuthed(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "authed:octocat")
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}}
	msg, err := (GhAuth{}).Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(msg, "octocat") {
		t.Errorf("summary = %q, want it to name the user", msg)
	}
}

func TestGhAuth_Unauthed_Consent_LogsIn(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "unauthed")
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}}
	msg, err := (GhAuth{}).Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if strings.Contains(strings.ToLower(msg), "skipped") {
		t.Errorf("expected a login summary, got %q", msg)
	}
}

func TestGhAuth_Unauthed_Declined_Skips(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "unauthed")
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: false}}
	msg, err := (GhAuth{}).Run(ctx)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(strings.ToLower(msg), "skip") {
		t.Errorf("summary = %q, want a skip message", msg)
	}
}

func TestGhAuth_LoginFailure_Errors(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "login-fail")
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}}
	if _, err := (GhAuth{}).Run(ctx); err == nil {
		t.Error("expected error when gh auth login fails")
	}
}

func TestGhAuth_GhMissing_SoftSkips(t *testing.T) {
	t.Setenv("CA_BOOTSTRAP_GH_MOCK", "gh-missing")
	ctx := &wizard.Context{Out: io.Discard, Prompt: stepPrompter{yes: true}}
	msg, err := (GhAuth{}).Run(ctx)
	if err != nil {
		t.Fatalf("gh-missing should soft-skip, got err %v", err)
	}
	if !strings.Contains(strings.ToLower(msg), "skip") {
		t.Errorf("summary = %q, want a skip message", msg)
	}
}
