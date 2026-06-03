//go:build windows

package main

import "syscall"

// enableConsoleUTF8 sets the Windows console *output* code page to UTF-8
// (CP_UTF8 = 65001) so the UTF-8 glyphs the wizard prints (✓ ⚠ → — …)
// render correctly. conhost / Windows PowerShell default to a legacy OEM
// code page and otherwise show mojibake ("Γ£ô" for "✓").
//
// Best-effort: the return value is ignored. When stdout is a pipe the
// console code page is irrelevant (the raw UTF-8 bytes are already
// correct, and the consumer decodes them), and Windows Terminal is UTF-8
// already, so this is effectively a no-op there. The *input* code page is
// deliberately left untouched — prompt answers are ASCII (y/n, name,
// email) and changing the input CP can perturb console reads.
//
// Uses stdlib syscall (no x/sys/windows dependency) to honour the
// project's stdlib-plus-cobra/yaml-only policy.
func enableConsoleUTF8() {
	const cpUTF8 = 65001
	_, _, _ = syscall.NewLazyDLL("kernel32.dll").
		NewProc("SetConsoleOutputCP").Call(uintptr(cpUTF8))
}
