package journal

import "fmt"

// errNotImplemented is the placeholder error returned by every stub
// method until the real implementation lands in Task 3. Tests that
// fail because of it confirm the RED gate is intact.
func errNotImplemented(fn string) error {
	return fmt.Errorf("journal: %s not implemented (Task 3 of alpha.2 plan)", fn)
}
