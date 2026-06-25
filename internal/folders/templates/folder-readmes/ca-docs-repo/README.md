# ca-docs-repo

ChannelAssist documentation + org-level profile repos. Source-of-truth docs
that span multiple repos live here; code-adjacent docs live next to the code.

## What lives here

- `keystone` — the central engineering knowledge base (ADRs, journal, runbooks).
- `ca-keystone-runtime` — runtime/site for keystone (Astro Starlight).
- `ca-keystone-studio` — authoring/studio companion for keystone.
- `org-profile-public` — `ChannelAssist/.github` (public org README).
- `org-profile-private` — `ChannelAssist/.github-private` (members-only).

## Tree

```
ca-docs-repo/
├── keystone/              # ADRs, engineering journal, runbooks
├── ca-keystone-runtime/   # Astro Starlight site for keystone
├── ca-keystone-studio/    # keystone authoring/studio companion
├── org-profile-public/    # ChannelAssist/.github
└── org-profile-private/   # ChannelAssist/.github-private (members only)
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
