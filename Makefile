# ca-bootstrap — developer onboarding tool.
#
# Common tasks:
#   make help          - show all targets
#   make smoke         - run a hermetic smoke test against /tmp
#   make test          - run Pester unit tests
#   make lint          - PSScriptAnalyzer + markdownlint
#   make format        - apply PSScriptAnalyzer auto-fix
#   make wiki-sync     - mirror docs/ to the GitHub Wiki working tree
#   make wiki-push     - commit + push wiki changes
#   make wiki-update   - sync + push (typical workflow)
#   make clean         - remove ephemeral state under /tmp/cab-* and ~/.ca-bootstrap/cache

SHELL := /bin/bash
BLUE   := \033[0;34m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
RESET  := \033[0m

# Pwsh executable; override with `make PWSH=pwsh-preview test`.
PWSH ?= pwsh

# Smoke test workspace (kept under /tmp so a wipe is harmless).
SMOKE_STATE     := /tmp/cab-smoke-state
SMOKE_WORKSPACE := /tmp/cab-smoke-workspace/ChannelAssistDev

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help (default target)
	@printf "$(BLUE)ca-bootstrap make targets$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-16s$(RESET) %s\n", $$1, $$2}'

.PHONY: smoke
smoke: ## Run an end-to-end smoke test against /tmp (no real workspace touched)
	@printf "$(BLUE)Running ca-bootstrap smoke test...$(RESET)\n"
	@rm -rf $(SMOKE_STATE) $(SMOKE_WORKSPACE)
	@# Use the keyed unattended fixture instead of positional stdin.
	@# The previous stdin-piped flow (tests/fixtures/smoke-answers.txt)
	@# broke every time the manifest grew a group, since each group
	@# adds a prompt. Keyed answers are stable across manifest churn:
	@# they reference group names, not prompt order.
	@CA_BOOTSTRAP_STATE=$(SMOKE_STATE) CA_BOOTSTRAP_WORKSPACE=$(SMOKE_WORKSPACE) \
		$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 setup \
		-Unattended -ConfigFile tests/fixtures/answers/hermetic.yaml
	@printf "$(GREEN)✓ Smoke test passed$(RESET)\n"

.PHONY: smoke-clean
smoke-clean: ## Remove smoke-test temp state
	@rm -rf $(SMOKE_STATE) $(SMOKE_WORKSPACE)
	@printf "$(GREEN)✓ Smoke state cleaned$(RESET)\n"

.PHONY: setup
setup: ## Run interactive setup wizard
ifeq ($(OS),Windows_NT)
	@$(PWSH) -NoLogo -NoProfile -Command "Write-Host 'This Makefile uses bash idioms that do not work on Windows native shells.' -ForegroundColor Yellow; Write-Host 'On Windows, use the PowerShell-native task runner instead:'; Write-Host ''; Write-Host '    .\\make.ps1 setup' -ForegroundColor Cyan; Write-Host ''; Write-Host '(WSL / Git Bash users: keep using make setup -- only cmd/pwsh need the redirect.)'"
	@exit 2
else
	@$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 setup $(ARGS); ec=$$?; \
		if [ $$ec -eq 1 ]; then \
			exit 0; \
		else \
			exit $$ec; \
		fi
endif
# ↑ Windows guard uses GNU make's `ifeq` so it's evaluated before any
# shell expansion — works even when cmd.exe / pwsh is the only available
# shell and bash isn't on PATH. The `$(OS)` variable is set to
# `Windows_NT` automatically by GNU make on Windows native (it's unset
# under WSL, so WSL users still hit the normal bash path below).
#
# Exit-code mapping below: ca-bootstrap.ps1 returns 1 when the user
# voluntarily quits (documented in docs/commands.md), but make's default
# failure message ("make: *** [setup] Error 1") makes that look like a
# crash. Map user-quit to exit 0 here so `make setup` returns silently
# on quit; real errors (exit 2+ for failed installs, etc.) still propagate.

.PHONY: doctor
doctor: ## Run doctor (exit 2 = drift found, not a make failure)
	@set +e; $(PWSH) -NoLogo -File ./ca-bootstrap.ps1 doctor $(ARGS); rc=$$?; \
	 if [ $$rc -eq 0 ] || [ $$rc -eq 2 ]; then exit 0; else exit $$rc; fi

.PHONY: repair
repair: ## Run repair. Pass ARGS, e.g. `make repair ARGS='--all'` or `make repair ARGS='--target dotnet-10'`
	@if [ -z "$(ARGS)" ]; then printf "$(YELLOW)Hint: pass ARGS, e.g. \`make repair ARGS=--all\`$(RESET)\n"; fi
	@$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 repair $(ARGS)

.PHONY: undo
undo: ## Run undo. `make undo ARGS='--target identity'` or `make undo ARGS='--force'`
	@$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 undo $(ARGS)

# ---------------------------------------------------------------------------
# Nuke + per-tool wrappers — friendlier surfaces around `undo` and `repair`
# so users don't have to remember the ARGS gymnastics. Logic stays in the
# PowerShell commands; these are just thin Makefile shims.
# ---------------------------------------------------------------------------

.PHONY: nuke
nuke: ## Full purge: undo every journaled action + remove ~/.ca-bootstrap/. Confirm-gated. INCLUDE_TOOLS=1 also uninstalls system tools (destructive). CONFIRM=1 skips prompt. DRY_RUN=1 prints the plan only.
	@chmod +x scripts/nuke.sh
	@INCLUDE_TOOLS=$(INCLUDE_TOOLS) CONFIRM=$(CONFIRM) DRY_RUN=$(DRY_RUN) PWSH=$(PWSH) ./scripts/nuke.sh

.PHONY: install-commit-hooks
install-commit-hooks: ## Install commitlint commit-msg hooks in every ChannelAssist clone with a commitlint config. WORKSPACE=path overrides default. WHATIF=1 to dry-run. FORCE=1 to overwrite foreign hooks.
	@$(PWSH) -NoLogo -File scripts/install-commit-hooks.ps1 \
		$(if $(WORKSPACE),-WorkspacePath '$(WORKSPACE)') \
		$(if $(WHATIF),-WhatIf) \
		$(if $(FORCE),-Force)

.PHONY: tool-list
tool-list: ## List every tool ID in manifest/tools.yaml (use these IDs with tool-install/tool-update/tool-remove).
	@$(PWSH) -NoLogo -Command "\
		. ./lib/ui.ps1; \
		. ./lib/yaml.ps1; \
		\$$m = Read-CABManifest -Path manifest/tools.yaml -Quiet; \
		Write-Host 'required:'; \
		@(\$$m.required) | ForEach-Object { Write-Host \"  \$$(\$$_.id)\" }; \
		Write-Host 'optional:'; \
		@(\$$m.optional) | ForEach-Object { Write-Host \"  \$$(\$$_.id)\" }"

.PHONY: tool-install
tool-install: ## Install or upgrade a single tool by ID, e.g. `make tool-install TOOL=dotnet-10`. Idempotent — no-op if at/above manifest min.
	@if [ -z "$(TOOL)" ]; then printf "$(RED)TOOL is required, e.g. make tool-install TOOL=dotnet-10. Use 'make tool-list' to see IDs.$(RESET)\n"; exit 2; fi
	@$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 repair --target $(TOOL)

.PHONY: tool-update
tool-update: tool-install ## Alias for tool-install (repair is version-aware: upgrades if below manifest min, no-op otherwise).

.PHONY: tool-remove
tool-remove: ## Uninstall a single tool by ID, e.g. `make tool-remove TOOL=dotnet-10`. Implicitly destructive (passes -Force -IncludeTools to undo).
	@if [ -z "$(TOOL)" ]; then printf "$(RED)TOOL is required, e.g. make tool-remove TOOL=dotnet-10. Use 'make tool-list' to see IDs.$(RESET)\n"; exit 2; fi
	@$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 undo --target tool.$(TOOL) -IncludeTools -Force

.PHONY: manifest-drift
manifest-drift: ## Show drift between manifest/repos.yaml and the live ChannelAssist org (exit 8 = drift found)
	@set +e; $(PWSH) -NoLogo -File ./ca-bootstrap.ps1 manifest-drift $(ARGS); rc=$$?; \
	 if [ $$rc -eq 0 ] || [ $$rc -eq 8 ]; then exit 0; else exit $$rc; fi

.PHONY: manifest-edit
manifest-edit: ## Interactively curate manifest/repos.yaml against the live org (add/remove repos)
	@$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 manifest-edit $(ARGS)

.PHONY: test
test: ## Run Pester unit tests under tests/
	@printf "$(BLUE)Running Pester tests...$(RESET)\n"
	@$(PWSH) -NoLogo -Command "Invoke-Pester -Path ./tests -Output Detailed -CI"

.PHONY: lint
lint: ## Run PSScriptAnalyzer and markdownlint
	@printf "$(BLUE)Linting PowerShell...$(RESET)\n"
	@$(PWSH) -NoLogo -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning -ExcludeRule PSAvoidUsingWriteHost,PSUseShouldProcessForStateChangingFunctions,PSAvoidUsingPositionalParameters | Format-Table"
	@if command -v markdownlint-cli2 >/dev/null 2>&1; then \
		printf "$(BLUE)Linting Markdown...$(RESET)\n"; \
		markdownlint-cli2 "**/*.md" "!wiki/**" "!.github/**"; \
	else \
		printf "$(YELLOW)markdownlint-cli2 not installed — skipping Markdown lint$(RESET)\n"; \
	fi

.PHONY: format
format: ## Apply PSScriptAnalyzer auto-fix where supported
	@$(PWSH) -NoLogo -Command "Get-ChildItem -Recurse -Include *.ps1,*.psm1 | ForEach-Object { Invoke-Formatter -ScriptDefinition (Get-Content -Raw \$$_.FullName) | Set-Content \$$_.FullName }"
	@printf "$(GREEN)✓ Formatted$(RESET)\n"

# ---------------------------------------------------------------------------
# Wiki sync — mirrors README, DESIGN, and docs/ into the GitHub Wiki.
# Same pattern as cm-platform-infra and Keystone.
# ---------------------------------------------------------------------------

WIKI_DIR := wiki

.PHONY: wiki-clone
wiki-clone: ## Clone the GitHub wiki repo into ./wiki (requires gh auth)
	@printf "$(BLUE)Cloning GitHub Wiki...$(RESET)\n"
	@chmod +x scripts/wiki-sync.sh
	@./scripts/wiki-sync.sh clone

.PHONY: wiki-sync
wiki-sync: ## Mirror README + DESIGN + docs/ into ./wiki (no push)
	@printf "$(BLUE)Syncing documentation to wiki working tree...$(RESET)\n"
	@chmod +x scripts/wiki-sync.sh
	@./scripts/wiki-sync.sh sync
	@printf "$(GREEN)✓ Documentation synced to wiki$(RESET)\n"

.PHONY: wiki-push
wiki-push: ## Commit and push wiki changes
	@printf "$(BLUE)Pushing wiki changes...$(RESET)\n"
	@chmod +x scripts/wiki-sync.sh
	@./scripts/wiki-sync.sh push

.PHONY: wiki-update
wiki-update: wiki-sync wiki-push ## Sync + push (typical workflow)

.PHONY: clean
clean: smoke-clean ## Remove caches and ephemeral state
	@rm -rf $(HOME)/.ca-bootstrap/cache
	@printf "$(GREEN)✓ Cleaned cache and smoke state$(RESET)\n"

# ---------------------------------------------------------------------------
# Release helpers
# ---------------------------------------------------------------------------

.PHONY: release
release: ## Cut a release. Requires the version constant on dev to already match VERSION (bump via PR first); for one-shot bump+release see `make release-full`
	@chmod +x scripts/release.sh
	@VERSION=$(VERSION) NOTES_FILE=$(NOTES_FILE) SKIP_SMOKE=$(SKIP_SMOKE) SKIP_TESTS=$(SKIP_TESTS) SKIP_MANIFEST_EDIT=$(SKIP_MANIFEST_EDIT) DRY_RUN=$(DRY_RUN) CONFIRM=$(CONFIRM) ./scripts/release.sh

.PHONY: release-dry-run
release-dry-run: ## Same as release but without writing/pushing anything (VERSION required)
	@chmod +x scripts/release.sh
	@DRY_RUN=1 VERSION=$(VERSION) NOTES_FILE=$(NOTES_FILE) ./scripts/release.sh

.PHONY: release-full
release-full: ## Bump dev's version + admin-merge bump PR + release in one shot. Skips review on the bump itself; use `make release` if you want the bump PR reviewed
	@chmod +x scripts/release-full.sh
	@VERSION=$(VERSION) NOTES_FILE=$(NOTES_FILE) SKIP_SMOKE=$(SKIP_SMOKE) SKIP_TESTS=$(SKIP_TESTS) SKIP_MANIFEST_EDIT=$(SKIP_MANIFEST_EDIT) DRY_RUN=$(DRY_RUN) CONFIRM=$(CONFIRM) ./scripts/release-full.sh

.PHONY: release-full-dry-run
release-full-dry-run: ## Dry-run release-full: validate the chain end-to-end without mutating
	@chmod +x scripts/release-full.sh
	@DRY_RUN=1 VERSION=$(VERSION) NOTES_FILE=$(NOTES_FILE) ./scripts/release-full.sh

.PHONY: tag
tag: ## Plain tag-and-push (no version bump, no release notes — prefer `make release`)
	@if [ -z "$(VERSION)" ]; then printf "$(RED)VERSION is required, e.g. make tag VERSION=v1.0.0$(RESET)\n"; exit 1; fi
	@git tag -a $(VERSION) -m "Release $(VERSION)"
	@git push origin $(VERSION)
	@printf "$(GREEN)✓ Tagged $(VERSION) and pushed$(RESET)\n"
