.PHONY: build test lint install clean

BIN_DIR := bin
CMD     := ./cmd/activity-log
VERSION ?= dev

GO ?= go
GOFLAGS := -trimpath -ldflags="-s -w -X main.version=$(VERSION)"

build: $(BIN_DIR)
	GOOS=darwin  GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-macos-arm64  $(CMD)
	GOOS=darwin  GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-macos-amd64  $(CMD)
	GOOS=linux   GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-linux-amd64  $(CMD)
	GOOS=linux   GOARCH=arm64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-linux-arm64  $(CMD)
	GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -o $(BIN_DIR)/activity-log-windows-amd64.exe $(CMD)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

test:
	$(GO) test -count=1 ./...

lint:
	@which golangci-lint > /dev/null 2>&1 || { echo "golangci-lint not installed; brew install golangci-lint"; exit 1; }
	golangci-lint run ./...

vet:
	$(GO) vet ./...

install:
	$(GO) build $(GOFLAGS) -o /usr/local/bin/activity-log $(CMD)

clean:
	rm -rf $(BIN_DIR)
