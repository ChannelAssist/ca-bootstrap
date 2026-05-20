# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`ChannelAssist/keystone-runtime` in the docs group** — `manifest/repos.yaml` now clones the Keystone runtime repo to `ca-docs/keystone-runtime` on `dev`, co-located with `ca-docs/keystone` (the Astro Starlight content). No special flags (public, default-included). Tracks AB#39913; sibling of the keystone-runtime scaffolding work (AB#39837, AB#39839, AB#39840, AB#39841) under Epic #38056 (AI Platform & Workflow Integration — 2026). Corrects an earlier draft of this entry that used the wrong slug (`ca-keystone-runtime`); the actual repo has no `ca-` prefix, matching the `docs` group's existing convention (`Keystone`, `.github`).

### Removed

- **Archived `ChannelAssist/nlp-learning-paths` from `ca-training` group** — `manifest/repos.yaml` no longer references this repo. Per policy, archived-on-GitHub repos don't belong in the clone manifest. Auto-detected and queued for removal by `manifest-edit` during release validation.

- **psql (PostgreSQL client) in the optional tools manifest** — `manifest/tools.yaml` now lists `psql` under `optional:` with `needed_by_groups: [cm-product]`. Required by `cm-currency-service`'s `make staging-seed-qa` (and any future staging op that pipes SQL into the staging Postgres). macOS installs via Homebrew `libpq` with a `post_install` `brew link --force --overwrite libpq` (libpq is keg-only); Windows uses winget `PostgreSQL.PostgreSQL.16`; Linux uses `postgresql-client` (debian) / `postgresql` (rhel). Tracks AB#39851; predecessor in-repo fix at [cm-currency-service#220](https://github.com/ChannelAssist/cm-currency-service/pull/220) (AB#39850).
