//go:build acceptance && windows

package acceptance

import "testing"

// holdSessionLock is the Windows stub. The lock-held acceptance test skips
// on Windows (TestUndo_LockHeld_ExitsOne via a runtime.GOOS guard) because
// the flock-based holder is POSIX-only; Windows LockFileEx semantics are
// covered by the internal/lock unit tests. This stub exists so the package
// compiles on Windows and skips defensively if it is ever reached.
func holdSessionLock(t *testing.T, lockPath string) {
	t.Helper()
	t.Skip("flock-based lock-holder is POSIX-only; Windows lock semantics covered in internal/lock unit tests")
}
