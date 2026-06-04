package manifest

// InstallSpec is the per-OS install block for a tool (manifest `install:`).
// alpha.1/alpha.2 ignored this (it was a yaml.Node); alpha.3's repair
// reads it to dispatch the right installer per platform.
//
// Schema mirrors the existing manifest entries:
//
//	install:
//	  windows: { type: winget, id: Git.Git }
//	  macos:   { type: brew, id: git, cask: true }
//	  linux:
//	    debian: { type: apt, id: git }
//	    rhel:   { type: dnf, id: git }
//	  any:     { type: script, url: "https://...", args: "..." }
type InstallSpec struct {
	Windows *InstallTarget `yaml:"windows,omitempty"`
	Macos   *InstallTarget `yaml:"macos,omitempty"`
	Linux   *LinuxInstall  `yaml:"linux,omitempty"`
	Any     *InstallTarget `yaml:"any,omitempty"`
}

// LinuxInstall handles the debian/rhel split OR an `any` fallback that
// applies to all Linux distros (e.g., a curl|bash script).
type LinuxInstall struct {
	Debian *InstallTarget `yaml:"debian,omitempty"`
	Rhel   *InstallTarget `yaml:"rhel,omitempty"`
	Any    *InstallTarget `yaml:"any,omitempty"`
	// A LinuxInstall may also be a flat target (type at this level) when
	// the manifest uses `linux: { type: snap, id: code }`. Captured via
	// the embedded fields below.
	Type    string `yaml:"type,omitempty"`
	ID      string `yaml:"id,omitempty"`
	Classic bool   `yaml:"classic,omitempty"`
}

// InstallTarget is one concrete install command spec.
type InstallTarget struct {
	Type        string   `yaml:"type"`                   // winget, brew, apt, dnf, snap, npm, script, command, mock
	ID          string   `yaml:"id,omitempty"`           // package id / npm pkg / mock outcome
	URL         string   `yaml:"url,omitempty"`          // for type: script
	Args        string   `yaml:"args,omitempty"`         // extra args
	Cmd         string   `yaml:"cmd,omitempty"`          // for type: command (raw command)
	Cask        bool     `yaml:"cask,omitempty"`         // brew --cask
	Global      bool     `yaml:"global,omitempty"`       // npm -g
	Classic     bool     `yaml:"classic,omitempty"`      // snap --classic
	RepoSetup   string   `yaml:"repo_setup,omitempty"`   // script to add a package repo first
	PostInstall []string `yaml:"post_install,omitempty"` // commands to run after the main install
}

// RequiresElevationField is an optional per-tool opt-in (manifest
// `requires_elevation: true`). When absent, elevation is inferred from
// the installer type (see internal/install/elevation.go).
