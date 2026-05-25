# ado-legacy

Read-only TFVC checkouts of pre-modernization code. Reference-only — do not
commit to anything here.

This folder is **optional** and is only created when you opt in during
`ca-bootstrap.ps1 setup`.

## What lives here

Whatever TFVC mappings you set up against the legacy `channelassist-inc`
Azure DevOps project. Conventional sub-folders mirror the legacy team
project tree (e.g. `Bitnix`, `OldPlatform`, etc.).

## Tree

```
ado-legacy/
├── <legacy-team-project-1>/
└── <legacy-team-project-2>/
```

## Safety

This is a read-only reference. `ca-bootstrap` does not manage its contents
beyond creating the empty folder. If you populate it, those subdirectories
belong to **you and the TFVC mapping** — not to `ca-bootstrap`. The
[safety contract](https://github.com/ChannelAssist/ca-bootstrap/blob/dev/docs/commands.md) applies: ca-bootstrap will not
delete this folder or its contents without an explicit confirmation
prompt.

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
