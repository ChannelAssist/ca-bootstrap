// Package main is the entry point for ca-bootstrap.
//
// ca-bootstrap takes a fresh laptop to a working ChannelAssist development
// environment. It implements `version`, `doctor` (read-only), `setup`
// (wizard: prereqs, git identity, folder taxonomy), `repair` (install a
// missing tool), and `undo` (reverse journalled changes).
// See docs/specs/2026-05-25-go-rewrite-pivot.md for the roadmap.
package main

import (
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/cli"
)

// Build-time injected via -ldflags. Default values are "dev" sentinels so
// local `go build` produces something recognisable in bug reports.
var (
	Version   = "dev"
	Commit    = "unknown"
	BuildTime = "unknown"
)

func main() {
	cli.SetBuildInfo(Version, Commit, BuildTime)
	if err := cli.Execute(); err != nil {
		os.Exit(1)
	}
}
