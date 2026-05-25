package steps

import "fmt"

// errStubStep is the placeholder error returned by every step stub
// until Task 7 implements the real bodies. Acceptance tests should
// see these in the failure paths, confirming the RED gate.
func errStubStep(name string) error {
	return fmt.Errorf("steps.%s: not implemented (Task 7 of alpha.2 plan)", name)
}
