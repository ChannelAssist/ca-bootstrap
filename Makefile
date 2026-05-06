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

# Python detection: shared single-line shell snippet inlined into each
# Python-using recipe. Mirrors bootstrap.sh's detect_python so pyenv/
# conda envs that only ship `python` (no `python3` symlink) work here
# too. The snippet sets a shell variable `py` to the first 3.10+
# interpreter on PATH from the candidate list, or empty if none found.
# Recipes that follow it test `[ -z "$py" ]` and bail.
#
# Single-line on purpose. A multi-line `define … endef` would expand
# into multiple recipe lines, and recipe lines are normally fed to
# separate shell invocations — meaning `done` would land in a different
# shell from `for`, breaking the loop. Backslash-newline continuations
# can paper over this when used carefully, but a single-line variable
# is unambiguous.
#
# Why not `PY := $(shell …)`: that would run at parse time on every
# make invocation (including `make help`), and the nested parens in the
# Python expression confuse make's $(shell …) paren-balancing scanner —
# Makefile:NN unterminated-call error.
#
# Candidate order matches bootstrap.sh / Find-CABPython:
#   python3 → python3.13 → python3.12 → python3.11 → python3.10 → python
DETECT_PY = py=""; for cand in python3 python3.13 python3.12 python3.11 python3.10 python; do if command -v "$$cand" >/dev/null 2>&1; then ver=$$("$$cand" -c 'import sys; v=sys.version_info; print(v[0]*100+v[1])' 2>/dev/null || echo 0); if [ "$$ver" -ge 310 ] 2>/dev/null; then py="$$cand"; break; fi; fi; done
PY_CANDIDATES_HUMAN = python3 / python3.13 / python3.12 / python3.11 / python3.10 / python

# tui-install — every shell step in the recipe chains via `&&` so a
# non-zero exit (e.g. venv creation, pip install) stops the recipe
# instead of falling through to the success printf. The Darwin .pth
# cleanup is idempotent — `|| true` keeps the find from breaking the
# chain on non-Hatchling editable shims.
.PHONY: tui-install
tui-install: ## Install the cab-tui Python front-end into cab-tui/.venv
	@printf "$(BLUE)Installing cab-tui...$(RESET)\n"
	@$(DETECT_PY); \
	if [ -z "$$py" ]; then \
		printf "$(RED)No Python 3.10+ found on PATH (tried $(PY_CANDIDATES_HUMAN)). Install one first.$(RESET)\n"; \
		exit 1; \
	fi; \
	printf "  Using interpreter: $$py\n" && \
	venv_dir="cab-tui/.venv" && \
	{ \
		if [ -e "$$venv_dir/bin/python" ]; then existing_py="$$venv_dir/bin/python"; \
		elif [ -e "$$venv_dir/Scripts/python.exe" ]; then existing_py="$$venv_dir/Scripts/python.exe"; \
		else existing_py=""; fi; \
		if [ -n "$$existing_py" ]; then \
			ver=$$("$$existing_py" -c 'import sys; v=sys.version_info; print(v[0]*100+v[1])' 2>/dev/null || echo 0); \
			if [ "$$ver" -lt 310 ] 2>/dev/null; then \
				printf "$(YELLOW)  Existing $$venv_dir/ is Python <3.10; recreating...$(RESET)\n" && \
				rm -rf "$$venv_dir" && \
				existing_py=""; \
			fi; \
		fi; \
		if [ -z "$$existing_py" ]; then \
			printf "  Creating virtualenv at $$venv_dir/...\n" && \
			"$$py" -m venv "$$venv_dir"; \
		else true; \
		fi; \
	} && \
	{ \
		if [ -e "$$venv_dir/bin/python" ]; then venv_py="$$venv_dir/bin/python"; \
		else venv_py="$$venv_dir/Scripts/python.exe"; fi; \
		printf "  Installing into $$venv_dir/ (PEP 668 protects system Python)\n" && \
		"$$venv_py" -m pip install --upgrade pip --quiet 2>/dev/null; true; \
		"$$venv_py" -m pip install -e 'cab-tui[dev]' --quiet; \
	} && \
	{ \
		if [ "$$(uname -s)" = "Darwin" ]; then \
			find cab-tui/.venv -path "*site-packages/*.pth" -exec chflags nohidden {} \; 2>/dev/null || true; \
		fi; \
	} && \
	printf "$(GREEN)✓ cab-tui installed in cab-tui/.venv/; \`make setup\` will auto-launch the TUI$(RESET)\n"
	@# Install path: pip-into-venv. The orchestrator's Find-CABPython
	@# checks cab-tui/.venv first, so the venv-installed cab_tui is
	@# picked up without the user adding anything to PATH. This avoids
	@# PEP 668's EXTERNALLY-MANAGED block on Homebrew/system Pythons
	@# (which would otherwise refuse `pip install` and silently leave
	@# the orchestrator with a Python that can't import cab_tui).
	@# poetry.lock stays as the spec-of-record for strict reproducibility
	@# (`poetry install` into the same venv works — points at the same
	@# pyproject.toml). Hatchling's editable .pth gets a UF_HIDDEN
	@# clear on macOS so Python 3.14's site.py doesn't skip it (also
	@# covers poetry-core's cab_tui.pth — same hidden-flag bug, different
	@# filename).

.PHONY: tui-test
tui-test: ## Run the cab-tui pytest suite
	@printf "$(BLUE)Running cab-tui pytest suite...$(RESET)\n"
	@# Prefer the cab-tui/.venv python ONLY when it actually has pytest
	@# installed. `bootstrap.sh` populates the same venv with a
	@# runtime-only install (no [dev] extras), so a bootstrapped repo
	@# would have a venv-python without pytest — we'd fail with
	@# "No module named pytest" if we used it unconditionally. Falling
	@# back to PATH lookup here lets users run `make tui-test` in either
	@# situation; for the bootstrapped case they can re-run
	@# `make tui-install` to add the [dev] extras.
	@# Absolute paths because we `cd cab-tui` before pytest runs.
	@repo_root="$$(pwd)"; \
	venv_py=""; \
	if [ -x "$$repo_root/cab-tui/.venv/bin/python" ]; then \
		venv_py="$$repo_root/cab-tui/.venv/bin/python"; \
	elif [ -x "$$repo_root/cab-tui/.venv/bin/python3" ]; then \
		venv_py="$$repo_root/cab-tui/.venv/bin/python3"; \
	elif [ -x "$$repo_root/cab-tui/.venv/Scripts/python.exe" ]; then \
		venv_py="$$repo_root/cab-tui/.venv/Scripts/python.exe"; \
	fi; \
	if [ -n "$$venv_py" ]; then \
		venv_ver=$$("$$venv_py" -c 'import sys; v=sys.version_info; print(v[0]*100+v[1])' 2>/dev/null || echo 0); \
		if [ "$$venv_ver" -lt 310 ] 2>/dev/null; then \
			printf "$(YELLOW)cab-tui/.venv is Python <3.10; falling back to PATH.$(RESET)\n"; \
			printf "$(YELLOW)  Run \`make tui-install\` to recreate the venv with the active interpreter.$(RESET)\n"; \
			venv_py=""; \
		fi; \
	fi; \
	if [ -n "$$venv_py" ] && "$$venv_py" -c 'import pytest' 2>/dev/null; then \
		py="$$venv_py"; \
	else \
		if [ -n "$$venv_py" ]; then \
			printf "$(YELLOW)cab-tui/.venv has no pytest (bootstrap installs runtime-only); falling back to PATH.$(RESET)\n"; \
			printf "$(YELLOW)  Run \`make tui-install\` to add [dev] extras to the venv.$(RESET)\n"; \
		fi; \
		$(DETECT_PY); \
	fi; \
	if [ -z "$$py" ]; then \
		printf "$(RED)No Python 3.10+ found (tried cab-tui/.venv/ then $(PY_CANDIDATES_HUMAN)).$(RESET)\n"; \
		exit 1; \
	fi; \
	cd cab-tui && "$$py" -m pytest -q

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
