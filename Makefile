.PHONY: help build build-daemon test vet lint shellcheck verify install clean

BIN_DIR := bin
CMD     := ./cmd/activity-log
WATCHER := ./cmd/activity-watcher
DAEMON  := ./server
VERSION ?= dev

GO ?= go
GOFLAGS := -trimpath -ldflags="-s -w -X main.version=$(VERSION)"
DAEMON_TAGS := -tags sqlite_fts5

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: $(BIN_DIR) ## Cross-compile CLI + watcher (mac arm/amd, linux arm/amd, win amd) — no cgo
	GOOS=darwin  GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-darwin-arm64  $(CMD)
	GOOS=darwin  GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-darwin-amd64  $(CMD)
	GOOS=linux   GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-linux-amd64  $(CMD)
	GOOS=linux   GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-linux-arm64  $(CMD)
	GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-windows-amd64.exe $(CMD)
	GOOS=darwin  GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-watcher-darwin-arm64  $(WATCHER)
	GOOS=linux   GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-watcher-linux-amd64  $(WATCHER)

# build-daemon: cgo required (mattn/go-sqlite3 + FTS5).
# Cross-compile darwin↔darwin works on Apple Silicon out of the box.
# Linux/Windows: build natively on target (or use zig cc / musl-cross).
build-daemon: $(BIN_DIR) ## Build daemon natively (cgo+FTS5; cross-compile not portable)
	CGO_ENABLED=1 $(GO) build $(DAEMON_TAGS) $(GOFLAGS) -o $(BIN_DIR)/activity-mesh-daemon-$(shell go env GOOS)-$(shell go env GOARCH) $(DAEMON)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

test: ## Run all tests (with sqlite_fts5 tag for daemon+indexer)
	CGO_ENABLED=1 $(GO) test $(DAEMON_TAGS) -count=1 ./...

vet: ## Run go vet across all packages
	CGO_ENABLED=1 $(GO) vet $(DAEMON_TAGS) ./...

lint: ## Run golangci-lint (requires brew install)
	@which golangci-lint > /dev/null 2>&1 || { echo "golangci-lint not installed; brew install golangci-lint"; exit 1; }
	golangci-lint run ./...

shellcheck: ## Run shellcheck across all bash scripts
	@find . -name '*.sh' -not -path './.git/*' -not -path './bin/*' -print0 | xargs -0 shellcheck --severity=warning

verify: vet test shellcheck ## Full verification — vet + test + shellcheck (CI parity)

install: ## Install binaries to /usr/local/bin (requires sudo)
	$(GO) build $(GOFLAGS) -o /usr/local/bin/activity-log $(CMD)
	$(GO) build $(GOFLAGS) -o /usr/local/bin/activity-watcher $(WATCHER)
	CGO_ENABLED=1 $(GO) build $(DAEMON_TAGS) $(GOFLAGS) -o /usr/local/bin/activity-mesh-daemon $(DAEMON)

clean: ## Remove built binaries
	rm -rf $(BIN_DIR)
