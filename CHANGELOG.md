# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **psql (PostgreSQL client) in the optional tools manifest** — `manifest/tools.yaml` now lists `psql` under `optional:` with `needed_by_groups: [cm-product]`. Required by `cm-currency-service`'s `make staging-seed-qa` (and any future staging op that pipes SQL into the staging Postgres). macOS installs via Homebrew `libpq` with a `post_install` `brew link --force --overwrite libpq` (libpq is keg-only); Windows uses winget `PostgreSQL.PostgreSQL.16`; Linux uses `postgresql-client` (debian) / `postgresql` (rhel). Tracks AB#39851; predecessor in-repo fix at [cm-currency-service#220](https://github.com/ChannelAssist/cm-currency-service/pull/220) (AB#39850).
