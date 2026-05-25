package steps

import "github.com/ChannelAssist/ca-bootstrap/internal/wizard"

// Identity is wizard step 3 — prompt for name/email + write
// <workspace>/.git/config. Stub — Task 7.
type Identity struct{}

func (Identity) Title() string                                  { return "Git identity" }
func (Identity) Run(ctx *wizard.Context) (string, error)        { return "", errStubStep("Identity") }
