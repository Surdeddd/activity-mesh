.PHONY: help build build-daemon test vet lint shellcheck verify install clean test-mcp test-install test-archives

BIN_DIR := bin
CMD     := ./cmd/activity-log
WATCHER := ./cmd/activity-watcher
DAEMON  := ./server
# Version source: VERSION file (committed) → fallback `dev`. Override on the
# CLI for ad-hoc builds: `make build VERSION=0.2.1-rc.1`.
VERSION ?= $(shell cat VERSION 2>/dev/null || echo dev)

GO ?= go
GOFLAGS := -trimpath -ldflags="-s -w -X main.version=$(VERSION)"
# All three binaries are cgo-free (SQLite via modernc.org/sqlite, FTS5
# compiled in) — every target cross-compiles from any host.
export CGO_ENABLED := 0

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: $(BIN_DIR) ## Cross-compile CLI + watcher + daemon (mac arm/amd, linux arm/amd, win amd)
	GOOS=darwin  GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-darwin-arm64  $(CMD)
	GOOS=darwin  GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-darwin-amd64  $(CMD)
	GOOS=linux   GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-linux-amd64  $(CMD)
	GOOS=linux   GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-linux-arm64  $(CMD)
	GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-windows-amd64.exe $(CMD)
	GOOS=darwin  GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-watcher-darwin-arm64  $(WATCHER)
	GOOS=linux   GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-watcher-linux-amd64  $(WATCHER)
	GOOS=darwin  GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-mesh-daemon-darwin-arm64 $(DAEMON)
	GOOS=darwin  GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-mesh-daemon-darwin-amd64 $(DAEMON)
	GOOS=linux   GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-mesh-daemon-linux-amd64 $(DAEMON)

build-daemon: $(BIN_DIR) ## Build daemon for the current host only
	$(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-mesh-daemon-$(shell go env GOOS)-$(shell go env GOARCH) $(DAEMON)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

test: ## Run all tests
	$(GO) test -count=1 ./...

vet: ## Run go vet across all packages
	$(GO) vet ./...

lint: ## Run golangci-lint (requires brew install)
	@which golangci-lint > /dev/null 2>&1 || { echo "golangci-lint not installed; brew install golangci-lint"; exit 1; }
	golangci-lint run ./...

shellcheck: ## Run shellcheck across all bash scripts
	@find . -name '*.sh' -not -path './.git/*' -not -path './bin/*' -print0 | xargs -0 shellcheck --severity=warning

test-mcp: ## Run MCP server tests (node)
	node --test mcp/server_test.mjs

test-install: ## Hermetic bootstrap install test (temp HOME, local fake release)
	bash tests/install/test-bootstrap.sh

test-archives: ## Release archive content test (needs goreleaser; skips otherwise)
	bash tests/release/test-archives.sh

verify: vet test shellcheck test-mcp test-hooks ## Full verification — vet + test + shellcheck + mcp + hooks (CI parity)

install: ## Install binaries to /usr/local/bin (requires sudo)
	$(GO) build $(GOFLAGS) -o /usr/local/bin/activity-log $(CMD)
	$(GO) build $(GOFLAGS) -o /usr/local/bin/activity-watcher $(WATCHER)
	$(GO) build $(GOFLAGS) -o /usr/local/bin/activity-mesh-daemon $(DAEMON)

clean: ## Remove built binaries
	rm -rf $(BIN_DIR)

# Appended target — kept at the end (separate from Go `test`) to minimize merge conflicts.
.PHONY: test-hooks
test-hooks: ## Run Claude Code hook regression tests (plain bash, no deps)
	bash tests/hooks/run-tests.sh
