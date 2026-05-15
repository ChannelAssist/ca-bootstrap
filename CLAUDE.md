# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

See `README.md` for the canonical description of this repository's purpose.

## SDLC compliance

This repo follows the canonical ChannelAssist SDLC governed by the [SDLC Policy](https://channelassist.sharepoint.com/:w:/s/SecOps/IQDrDet6p11DSZ0JEQ5EoxwlATY3M780wzBX6lGpprsSmvU?e=3uLo7n) (§ section anchors referenced where applicable). Per ADR-0023 the repo is protected by the canonical 2-tier ruleset: `main-protection` (2 approvals + CODEOWNERS, no admin bypass) and `dev-protection` (1 approval + CODEOWNERS, admin bypass allowed for emergencies).

Branch model: `dev` (default) → `main` (release). Branch from `dev`, PR back into `dev`. Release-promotion PRs go `dev` → `main` (fast-track dance documented in `ca-fast-track-merger` from `ca-claude-plugin`).

## Commit hygiene

- Conventional Commits, signed (`git commit -S`), bisected (one logical change per commit)
- AI attribution footer (`Co-Authored-By: Claude <model> <noreply@anthropic.com>`) when AI-assisted
- `Refs: AB#<id>` footer when there's an Azure Boards work item
- Branch naming: `feature/<desc>-AB#<id>` or `bugfix/<desc>-AB#<id>` (`docs/` and `chore/` exceptions documented in `branch-name-check`)

## References

- [SDLC Policy](https://channelassist.sharepoint.com/:w:/s/SecOps/IQDrDet6p11DSZ0JEQ5EoxwlATY3M780wzBX6lGpprsSmvU?e=3uLo7n)
- ADR-0023 (canonical 2-tier branch protection)
- ADR-0018 (canonical 36-label taxonomy)
- ADR-0017 (`ca-*` naming prefix)


<!-- BEGIN: journal-snippet-sync (managed by ChannelAssist/Keystone) -->
## Engineering Journal — read every session, write when work warrants

There is a **cross-project engineering log** for the ChannelAssist org in the
Keystone repo at `content/journal/YYYY-q<N>.md` (one file per calendar quarter):

- **Repository:** [ChannelAssist/Keystone](https://github.com/ChannelAssist/Keystone)
- **Directory:** [`content/journal/`](https://github.com/ChannelAssist/Keystone/tree/dev/content/journal)
- **Index + format:** [`content/journal/README.md`](https://github.com/ChannelAssist/Keystone/blob/dev/content/journal/README.md)
- **Full guidance (read + write rules):** [Keystone `AGENTS.md` → "Engineering Journal"](https://github.com/ChannelAssist/Keystone/blob/dev/AGENTS.md#engineering-journal-read-this-every-session-write-to-it-when-work-warrants)

**Read** the current quarter's entry at the start of every non-trivial session in this repo — trials and tribulations, lessons learned, and major initiatives across the org. Many "did we already solve this?" questions resolve there in 60 seconds.

**Write** to the current quarter when ANY of: a debugging story took >1 iteration · an architectural decision was made · a near-miss was caught · a pattern recurred for the 2nd/3rd time across projects · an external system surprised you · the quarter is ending.

NOT journal-worthy: routine bugfixes, dependency bumps, nit-level review feedback.

**Redaction rule:** when an entry references a leaked credential, internal IP, or sensitive infrastructure identifier, use partial fingerprints (first 4 + last 4 chars) + a link to the access-controlled tracker. Never inline the actual value, even in narrative context.

To contribute: see [Keystone `content/journal/README.md`](https://github.com/ChannelAssist/Keystone/blob/dev/content/journal/README.md) for the manual-PR or `/journal` slash-command flow.
<!-- END: journal-snippet-sync -->
