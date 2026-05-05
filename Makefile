.PHONY: build build-daemon test lint install clean

BIN_DIR := bin
CMD     := ./cmd/activity-log
DAEMON  := ./server
VERSION ?= dev

GO ?= go
GOFLAGS := -trimpath -ldflags="-s -w -X main.version=$(VERSION)"
DAEMON_TAGS := -tags sqlite_fts5

build: $(BIN_DIR)
	GOOS=darwin  GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-macos-arm64  $(CMD)
	GOOS=darwin  GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-macos-amd64  $(CMD)
	GOOS=linux   GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-linux-amd64  $(CMD)
	GOOS=linux   GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-linux-arm64  $(CMD)
	GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-windows-amd64.exe $(CMD)

# build-daemon: cgo required (mattn/go-sqlite3 + FTS5).
# Cross-compile darwin↔darwin works on Apple Silicon out of the box.
# Linux/Windows: build natively on target (or use zig cc / musl-cross).
build-daemon: $(BIN_DIR)
	CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 $(GO) build $(DAEMON_TAGS) $(GOFLAGS) -o $(BIN_DIR)/activity-mesh-daemon-darwin-arm64 $(DAEMON)
	CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 $(GO) build $(DAEMON_TAGS) $(GOFLAGS) -o $(BIN_DIR)/activity-mesh-daemon-darwin-amd64 $(DAEMON)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

test:
	CGO_ENABLED=1 $(GO) test $(DAEMON_TAGS) -count=1 ./...

lint:
	@which golangci-lint > /dev/null 2>&1 || { echo "golangci-lint not installed; brew install golangci-lint"; exit 1; }
	golangci-lint run ./...

vet:
	CGO_ENABLED=1 $(GO) vet $(DAEMON_TAGS) ./...

install:
	$(GO) build $(GOFLAGS) -o /usr/local/bin/activity-log $(CMD)
	CGO_ENABLED=1 $(GO) build $(DAEMON_TAGS) $(GOFLAGS) -o /usr/local/bin/activity-mesh-daemon $(DAEMON)

clean:
	rm -rf $(BIN_DIR)
