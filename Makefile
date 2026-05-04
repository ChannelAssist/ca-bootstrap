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
	@CA_BOOTSTRAP_STATE=$(SMOKE_STATE) CA_BOOTSTRAP_WORKSPACE=$(SMOKE_WORKSPACE) \
		$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 setup < tests/fixtures/smoke-answers.txt
	@printf "$(GREEN)✓ Smoke test passed$(RESET)\n"

.PHONY: smoke-clean
smoke-clean: ## Remove smoke-test temp state
	@rm -rf $(SMOKE_STATE) $(SMOKE_WORKSPACE)
	@printf "$(GREEN)✓ Smoke state cleaned$(RESET)\n"

.PHONY: setup
setup: ## Run setup wizard (auto-detects cab-tui; pass ARGS=-NoTui to force CLI)
	@$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 setup $(ARGS)

.PHONY: setup-no-tui
setup-no-tui: ## Run setup wizard with the legacy Read-Host CLI (forces -NoTui)
	@$(PWSH) -NoLogo -File ./ca-bootstrap.ps1 setup -NoTui $(ARGS)

# Python detection — accept any 3.10+ interpreter on PATH. Mirrors
# bootstrap.sh's detect_python so pyenv/conda envs that only ship
# `python` (no `python3` symlink) work the same way here.
PY := $(shell \
	for cand in python3 python3.13 python3.12 python3.11 python3.10 python; do \
		if command -v $$cand >/dev/null 2>&1; then \
			ver=$$($$cand -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0"); \
			major=$${ver%.*}; minor=$${ver#*.}; \
			if [ "$$major" -ge 3 ] && [ "$$minor" -ge 10 ]; then echo $$cand; break; fi; \
		fi; \
	done)

.PHONY: tui-install
tui-install: ## Install the cab-tui Python front-end (poetry install, falls back to pip)
	@printf "$(BLUE)Installing cab-tui...$(RESET)\n"
	@if [ -z "$(PY)" ]; then \
		printf "$(RED)No Python 3.10+ found on PATH (tried python3 / python). Install one first.$(RESET)\n"; exit 1; \
	fi
	@printf "  Using interpreter: $(PY)\n"
	@# Prefer poetry when available (per SDLC); fall back to pip for
	@# the common case where it isn't on PATH yet.
	@if command -v poetry >/dev/null 2>&1; then \
		cd cab-tui && poetry install --quiet; \
	else \
		cd cab-tui && $(PY) -m pip install -e . --quiet; \
	fi
	@# Hatchling marks its editable .pth file with the macOS UF_HIDDEN flag,
	@# and Python 3.14's site.py skips hidden .pth files — meaning `import
	@# cab_tui` would fail from any CWD other than the cab-tui dir. Clearing
	@# the flag is the supported fix; PYTHONPATH workaround remains as
	@# defense-in-depth in lib/tui-rpc.ps1. Harmless on poetry installs
	@# (the .pth filename is different so the find is a no-op).
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		find cab-tui -path "*site-packages/_editable_impl_*.pth" -exec chflags nohidden {} \; 2>/dev/null || true; \
		find $$($(PY) -c "import site; print(site.getsitepackages()[0])" 2>/dev/null) \
			-name "_editable_impl_cab_tui.pth" -exec chflags nohidden {} \; 2>/dev/null || true; \
	fi
	@printf "$(GREEN)✓ cab-tui installed; \`make setup\` will now auto-launch the TUI$(RESET)\n"

.PHONY: tui-test
tui-test: ## Run the cab-tui pytest suite
	@printf "$(BLUE)Running cab-tui pytest suite...$(RESET)\n"
	@if [ -z "$(PY)" ]; then \
		printf "$(RED)No Python 3.10+ found on PATH.$(RESET)\n"; exit 1; \
	fi
	@cd cab-tui && $(PY) -m pytest -q

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

.PHONY: test
test: ## Run Pester unit tests under tests/
	@printf "$(BLUE)Running Pester tests...$(RESET)\n"
	@$(PWSH) -NoLogo -Command "Invoke-Pester -Path ./tests -Output Detailed -CI"

.PHONY: test-all
test-all: test tui-test ## Run both Pester (PowerShell) and pytest (cab-tui) suites

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
release: ## Cut a release: bump version constant, smoke + tests, commit, tag, push, GitHub release
	@chmod +x scripts/release.sh
	@VERSION=$(VERSION) NOTES_FILE=$(NOTES_FILE) SKIP_SMOKE=$(SKIP_SMOKE) SKIP_TESTS=$(SKIP_TESTS) FORCE_BRANCH=$(FORCE_BRANCH) DRY_RUN=$(DRY_RUN) ./scripts/release.sh

.PHONY: release-dry-run
release-dry-run: ## Same as release but without writing/pushing anything (VERSION required)
	@chmod +x scripts/release.sh
	@DRY_RUN=1 VERSION=$(VERSION) NOTES_FILE=$(NOTES_FILE) ./scripts/release.sh

.PHONY: tag
tag: ## Plain tag-and-push (no version bump, no release notes — prefer `make release`)
	@if [ -z "$(VERSION)" ]; then printf "$(RED)VERSION is required, e.g. make tag VERSION=v1.0.0$(RESET)\n"; exit 1; fi
	@git tag -a $(VERSION) -m "Release $(VERSION)"
	@git push origin $(VERSION)
	@printf "$(GREEN)✓ Tagged $(VERSION) and pushed$(RESET)\n"
