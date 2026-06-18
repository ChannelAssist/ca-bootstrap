//go:build windows

package lock

import (
	"os"
	"path/filepath"
	"testing"
)

// These mirror the unix-tagged lock_test.go so the LockFileEx/UnlockFileEx
// implementation in lock_windows.go is actually executed on a Windows
// runner — previously it was only cross-compile-verified.

func TestLock_AcquireAndRelease(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.lock")
	l := New(path)
	if err := l.Acquire(); err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := l.Release(); err != nil {
		t.Fatalf("Release: %v", err)
	}
	// Re-acquire after release should succeed.
	if err := l.Acquire(); err != nil {
		t.Fatalf("re-Acquire after release: %v", err)
	}
	_ = l.Release()
}

func TestLock_SecondAcquireFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.lock")
	l1 := New(path)
	if err := l1.Acquire(); err != nil {
		t.Fatalf("first Acquire: %v", err)
	}
	defer l1.Release()

	// LockFileEx byte-range locks are enforced against every other handle,
	// including handles opened by the same process, so a second Acquire
	// must fail while l1 holds the lock.
	l2 := New(path)
	if err := l2.Acquire(); err == nil {
		t.Error("expected second Acquire to fail while first holds the lock")
		_ = l2.Release()
	}
}

func TestLock_ForceUnlockBreaksStaleLock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.lock")
	// A real stale lock is a file left behind by a *dead* process: the file
	// exists on disk but no live handle holds it (the holder's handle closed
	// on process exit). Model that — seed the file, then force-acquire.
	// (We don't simulate a still-live holder here: Windows keeps a deleted
	// file's name in a "delete pending" state until the last handle closes,
	// so os.Remove against a live handle can't free the name mid-process.)
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatalf("seed stale lock file: %v", err)
	}
	l := New(path)
	if err := l.AcquireWithForce(); err != nil {
		t.Fatalf("AcquireWithForce over stale file: %v", err)
	}
	_ = l.Release()
}
