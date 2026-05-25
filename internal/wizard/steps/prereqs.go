package steps

import "github.com/ChannelAssist/ca-bootstrap/internal/wizard"

// Prereqs is wizard step 2 — reuse detect+manifest to report drift.
// Stub — Task 7.
type Prereqs struct{}

func (Prereqs) Title() string                                  { return "Prerequisites" }
func (Prereqs) Run(ctx *wizard.Context) (string, error)        { return "", errStubStep("Prereqs") }
