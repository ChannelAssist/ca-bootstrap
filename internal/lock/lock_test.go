//go:build darwin || linux

package lock

import (
	"path/filepath"
	"testing"
)

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

	l2 := New(path)
	if err := l2.Acquire(); err == nil {
		t.Errorf("expected second Acquire to fail while first holds the lock")
		_ = l2.Release()
	}
}

func TestLock_ForceUnlockBreaksStaleLock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.lock")
	l1 := New(path)
	if err := l1.Acquire(); err != nil {
		t.Fatalf("first Acquire: %v", err)
	}
	// Simulate a "stale" holder by NOT releasing l1, then force-acquiring
	// with l2. On Unix, removing the file + re-creating gives l2 a fresh
	// inode to flock, so the force path succeeds.
	l2 := New(path)
	if err := l2.AcquireWithForce(); err != nil {
		t.Fatalf("AcquireWithForce: %v", err)
	}
	_ = l2.Release()
	_ = l1.Release()
}
