# ca-docs

ChannelAssist documentation + org-level profile repos. Source-of-truth docs
that ride alongside code lives next to the code; everything cross-cutting
lives here.

## What lives here

- `keystone` — the central engineering knowledge base (ADRs, journal, runbooks).
- `keystone-runtime` — runtime/site for keystone (Astro Starlight).
- `org-profile-public` — `ChannelAssist/.github` (public org README).
- `org-profile-private` — `ChannelAssist/.github-private` (members-only).

## Tree

```
ca-docs/
├── keystone/              # ADRs, engineering journal, runbooks
├── keystone-runtime/      # Astro Starlight site for keystone
├── org-profile-public/    # ChannelAssist/.github
└── org-profile-private/   # ChannelAssist/.github-private (members only)
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
