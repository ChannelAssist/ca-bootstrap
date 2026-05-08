# Project Overview: ca-bootstrap

`ca-bootstrap` is the developer onboarding tool for ChannelAssist. It is a cross-platform CLI tool (written in PowerShell 7+) designed to take a fresh machine and configure it for development in one command. It automates the installation of prerequisite tools, GitHub authentication, creation of workspace directories, cloning of required repositories, and per-folder git identity configuration.

## Key Architectural Concepts

- **Idempotency**: Every step is safe to re-run. It detects existing states and only applies changes if needed.
- **Action Journal**: All setup changes are recorded in `~/.ca-bootstrap/journal.yaml`. This enables the `doctor` (diagnostic) and `undo` (reversal) commands.
- **Manifests as Data**: The tool is data-driven. Folders, repositories, and tools are defined in `manifest/*.yaml` files. Avoid modifying code when a manifest edit suffices.
- **Multi-Command CLI**: Driven by the orchestrator `ca-bootstrap.ps1`, supporting `setup` (default), `doctor`, `repair`, `undo`, `manifest-drift`, and `manifest-edit`.

## Building, Running, and Testing

The project uses a `Makefile` for common tasks.

- **Setup / Run**:
  - `make setup` - Run the full interactive onboarding wizard.
  - `make doctor` - Diagnose the current state against the expected manifest without making changes.
  - `make repair ARGS='--all'` - Fix issues identified by the doctor.
  - `make undo` - Interactively reverse changes made by the bootstrap tool.
- **Testing**:
  - `make smoke` - Run an end-to-end hermetic smoke test against `/tmp`.
  - `make test` - Run Pester unit tests located in `tests/`.
- **Code Quality**:
  - `make lint` - Run `PSScriptAnalyzer` for PowerShell and `markdownlint` for Markdown files.
  - `make format` - Apply automatic fixes using `PSScriptAnalyzer`.

## Development Conventions

- **Scripting Language**: Primary logic is in **PowerShell 7+** (`.ps1`). Shell bootstrapper scripts (`.sh`) are kept minimal.
- **Testing Practices**: All logic should be unit-tested using **Pester**. Tests reside in the `tests/` directory. Each step has an integration smoke test.
- **Branching Strategy**:
  - `dev`: Default branch for feature work and PRs.
  - `main`: Stable release branch. Only updated via fast-forward during a release.
- **Releasing**: Handled via `make release VERSION=X.Y.Z`, which bumps versions, runs checks, creates tags, and manages the GitHub release.
- **Documentation**: The project documentation lives in the `docs/` folder, as well as `README.md` and `DESIGN.md`. A GitHub Wiki is maintained via `make wiki-sync` / `make wiki-update`.
- **Adding Repos/Tools**: When adding a new repository to clone or a new prerequisite tool to install, edit `manifest/repos.yaml` or `manifest/tools.yaml` respectively. Only modify `steps/*.ps1` files if new core bootstrap capabilities are needed.
