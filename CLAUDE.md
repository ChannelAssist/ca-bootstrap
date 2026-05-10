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
