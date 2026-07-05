# Makefile for ca-bootstrap (ChannelAssist dev-environment bootstrapper)
#
# Convention mirrors the ChannelAssist house style (see ca-keystone-studio,
# ca-command-and-control): colored sectioned help, `## help` comments parsed
# into the help target, bash-on-Windows compatibility via Git for Windows.
# This repo is a Go CLI, so targets wrap the go toolchain rather than dotnet
# or pnpm. Build + test commands mirror .github/workflows/ci.yml, and the
# cross-compile matrix + version stamping mirror .github/workflows/release.yml.
#
# Windows requires Git for Windows (provides sh.exe) and GNU Make:
#   choco install make  OR  scoop install make
# Recipe lines execute through Git Bash; native CMD is not supported.

# ---------------------------------------------------------------------------
# Shell + tooling detection
# ---------------------------------------------------------------------------
ifeq ($(OS),Windows_NT)
  SHELL := $(shell where sh 2>NUL || echo sh)
  .SHELLFLAGS := -c
endif

# ---------------------------------------------------------------------------
# Build metadata
# ---------------------------------------------------------------------------
BINARY  := ca-bootstrap
PKG     := ./cmd/ca-bootstrap
BIN_DIR := bin

# release.yml derives two distinct strings from the pushed tag, and this
# Makefile mirrors that split so local builds match the release exactly:
#   TAG     = the full tag incl. leading "v" (release.yml's ${GITHUB_REF_NAME})
#             — used verbatim in the build-all asset filenames.
#   VERSION = TAG with the leading "v" stripped (release.yml's ${...#v})
#             — used as the main.Version ldflag value.
# --match 'v[0-9]*' restricts describe to release tags (the pattern release.yml
# triggers on), so non-version tags like legacy/* are ignored — a slash in the
# describe output would otherwise corrupt the build-all filenames.
# Both are overridable on the command line (e.g. `make build VERSION=2.0.0-rc.1`).
TAG        ?= $(shell git describe --tags --match 'v[0-9]*' --always --dirty 2>/dev/null || echo dev)
VERSION    ?= $(patsubst v%,%,$(TAG))
COMMIT     ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_TIME ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS    := -s -w -X main.Version=$(VERSION) -X main.Commit=$(COMMIT) -X main.BuildTime=$(BUILD_TIME)

# Cross-compile matrix — the six per-platform binaries release.yml ships.
PLATFORMS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64

# ---------------------------------------------------------------------------
# ANSI color codes (used by help + status messages)
# ---------------------------------------------------------------------------
RED=\033[0;31m
GREEN=\033[0;32m
YELLOW=\033[0;33m
BLUE=\033[0;34m
MAGENTA=\033[0;35m
CYAN=\033[0;36m
BOLD=\033[1m
RESET=\033[0m

# ---------------------------------------------------------------------------
# Help target — parsed from `## description` comments after each target name
# ---------------------------------------------------------------------------
.PHONY: help
help: ## Display this help message
	@echo ""
	@echo "$(BOLD)$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(RESET)"
	@echo "$(BOLD)$(CYAN)  ca-bootstrap — Available Make Targets$(RESET)"
	@echo "$(BOLD)$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(RESET)"
	@echo ""
	@echo "$(BOLD)Build & run:$(RESET)"
	@grep -E '^[a-zA-Z0-9_-]+:.*## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; /^(build|build-all|install|run):/ {printf "  $(YELLOW)%-16s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)Quality gates:$(RESET)"
	@grep -E '^[a-zA-Z0-9_-]+:.*## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; /^(fmt|vet|tidy|test|test-acceptance|verify):/ {printf "  $(YELLOW)%-16s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)Utility:$(RESET)"
	@grep -E '^[a-zA-Z0-9_-]+:.*## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; /^(clean|help):/ {printf "  $(YELLOW)%-16s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(RESET)"
	@echo ""

# ---------------------------------------------------------------------------
# Build & run
# ---------------------------------------------------------------------------
.PHONY: build
build: ## Build the binary for the host platform into bin/ (version-stamped)
	@echo "$(BOLD)$(BLUE)Building $(BINARY) $(VERSION) ($(COMMIT))...$(RESET)"
	@mkdir -p $(BIN_DIR)
	@go build -trimpath -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/$(BINARY) $(PKG)
	@echo "$(BOLD)$(GREEN)✓ Built $(BIN_DIR)/$(BINARY)$(RESET)"

.PHONY: build-all
build-all: ## Cross-compile the six release binaries into bin/ (matches release.yml)
	@echo "$(BOLD)$(BLUE)Cross-compiling $(BINARY) $(TAG) for all platforms...$(RESET)"
	@mkdir -p $(BIN_DIR)
	@for platform in $(PLATFORMS); do \
	  goos="$${platform%/*}"; goarch="$${platform#*/}"; \
	  out="$(BIN_DIR)/$(BINARY)_$(TAG)_$${goos}_$${goarch}"; \
	  [ "$$goos" = windows ] && out="$${out}.exe"; \
	  echo "  $(YELLOW)$${goos}/$${goarch}$(RESET) -> $$out"; \
	  GOOS="$$goos" GOARCH="$$goarch" go build -trimpath -ldflags "$(LDFLAGS)" -o "$$out" $(PKG) || exit 1; \
	done
	@echo "$(BOLD)$(GREEN)✓ Cross-compile complete ($(BIN_DIR)/)$(RESET)"

.PHONY: install
install: ## Install the binary onto your PATH via 'go install' (version-stamped)
	@echo "$(BOLD)$(BLUE)Installing $(BINARY) $(VERSION) to $$(go env GOBIN 2>/dev/null || echo $$(go env GOPATH)/bin)...$(RESET)"
	@go install -trimpath -ldflags "$(LDFLAGS)" $(PKG)
	@echo "$(BOLD)$(GREEN)✓ Installed $(BINARY)$(RESET)"

.PHONY: run
run: ## Build + run the CLI on the host (pass args with ARGS="...")
	@go run -ldflags "$(LDFLAGS)" $(PKG) $(ARGS)

# ---------------------------------------------------------------------------
# Quality gates — mirror .github/workflows/ci.yml
# ---------------------------------------------------------------------------
.PHONY: fmt
fmt: ## Format all Go source (gofmt -w)
	@echo "$(BOLD)$(BLUE)Formatting...$(RESET)"
	@gofmt -l -w .
	@echo "$(BOLD)$(GREEN)✓ Formatted$(RESET)"

.PHONY: vet
vet: ## Run go vet across all packages
	@echo "$(BOLD)$(BLUE)Vetting...$(RESET)"
	@go vet ./...
	@echo "$(BOLD)$(GREEN)✓ Vet clean$(RESET)"

.PHONY: tidy
tidy: ## Tidy go.mod / go.sum
	@echo "$(BOLD)$(BLUE)Tidying modules...$(RESET)"
	@go mod tidy
	@echo "$(BOLD)$(GREEN)✓ Modules tidy$(RESET)"

.PHONY: test
test: ## Run unit tests (go test -count=1 ./...)
	@echo "$(BOLD)$(BLUE)Running unit tests...$(RESET)"
	@go test -count=1 ./...

.PHONY: test-acceptance
test-acceptance: ## Run acceptance tests (-tags acceptance ./tests/acceptance/...)
	@echo "$(BOLD)$(BLUE)Running acceptance tests...$(RESET)"
	@go test -tags acceptance -count=1 ./tests/acceptance/...

.PHONY: verify
verify: ## Run the full CI gate: vet + build all packages + unit + acceptance (mirrors ci.yml)
	@$(MAKE) --no-print-directory vet
	@echo "$(BOLD)$(BLUE)Compiling all packages (go build ./...)...$(RESET)"
	@go build ./...
	@echo "$(BOLD)$(GREEN)✓ All packages compile$(RESET)"
	@$(MAKE) --no-print-directory build
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory test-acceptance
	@echo "$(BOLD)$(GREEN)✓ All gates passed$(RESET)"

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------
.PHONY: clean
clean: ## Remove build artifacts (bin/) and clear the go build/test cache
	@echo "$(BOLD)$(RED)Cleaning build artifacts...$(RESET)"
	@rm -rf $(BIN_DIR)
	@go clean -cache -testcache 2>/dev/null || true
	@echo "$(BOLD)$(GREEN)✓ Clean complete$(RESET)"

.DEFAULT_GOAL := help
