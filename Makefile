# VMM Makefile for local development builds
# Injects version information via ldflags

VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
LDFLAGS := -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.date=$(DATE)

.PHONY: build clean install test

# Build the vmm binary with version info
build:
	go build -ldflags "$(LDFLAGS)" -o vmm ./cmd/vmm/

# Build without version info (faster, for quick iteration)
build-quick:
	go build -o vmm ./cmd/vmm/

# Install to /usr/local/bin (requires sudo)
install: build
	sudo cp vmm /usr/local/bin/vmm
	sudo chmod +x /usr/local/bin/vmm

# Clean build artifacts
clean:
	rm -f vmm

# Run tests
test:
	go test -v ./...

# Show version info that will be embedded
version-info:
	@echo "Version: $(VERSION)"
	@echo "Commit:  $(COMMIT)"
	@echo "Date:    $(DATE)"
