# ca-tools-repo

ChannelAssist tooling repos. Anything that builds, validates, deploys, or
onboards the rest of the workspace lives here.

## What lives here

- `ca-bootstrap` — the onboarding wizard you used to create this workspace.
- `ca-repo-template` — canonical template for scaffolding new ca-* repos.

## Tree

```
ca-tools-repo/
├── ca-bootstrap/      # interactive setup + doctor + repair + manifest tools
└── ca-repo-template/  # template for new ca-* repos
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
