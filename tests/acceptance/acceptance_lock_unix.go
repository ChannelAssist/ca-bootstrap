//go:build acceptance && !windows

package acceptance

import (
	"os"
	"syscall"
	"testing"
)

// holdSessionLock takes a real exclusive advisory lock (flock) on the
// session.lock file and holds it for the rest of the test, so a spawned
// ca-bootstrap process finds the lock genuinely held by another owner.
// Stale-file presence alone does NOT register as held for flock (alpha.3
// spec §6.4), which is why the test must hold an actual lock.
//
// POSIX-only: syscall.Flock doesn't exist on Windows, so the windows build
// uses the stub in acceptance_lock_windows.go.
func holdSessionLock(t *testing.T, lockPath string) {
	t.Helper()
	f, err := os.OpenFile(lockPath, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatalf("open lock: %v", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		t.Fatalf("flock: %v", err)
	}
	t.Cleanup(func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	})
}
