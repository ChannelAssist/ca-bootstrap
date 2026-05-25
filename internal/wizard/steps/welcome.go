// Package steps implements the three alpha.2 wizard steps:
// welcome (consent), prereqs (reuses doctor's detection),
// identity (writes per-folder git config).
package steps

import "github.com/ChannelAssist/ca-bootstrap/internal/wizard"

// Welcome is wizard step 1 — banner + Y/n consent. Stub — Task 7.
type Welcome struct{}

func (Welcome) Title() string                                  { return "Welcome" }
func (Welcome) Run(ctx *wizard.Context) (string, error)        { return "", errStubStep("Welcome") }
