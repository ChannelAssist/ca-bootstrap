// Package lock provides a cross-platform exclusive session lock so two
// `setup` / `repair` runs can't interleave journal writes (spec §6).
//
// Unix uses syscall.Flock; Windows uses LockFileEx. The lock is held
// for the lifetime of the process (released on Release() or process
// exit). ForceUnlock removes a stale lock file before acquiring.
package lock

// Lock is an exclusive session lock backed by a file.
type Lock interface {
	// Acquire takes the lock, returning an error if it's already held.
	Acquire() error
	// AcquireWithForce removes any existing lock file first, then acquires.
	AcquireWithForce() error
	// Release releases the lock and closes the underlying handle.
	Release() error
}

// New returns a platform-appropriate Lock backed by the file at path.
// (Implemented in lock_unix.go / lock_windows.go.)
