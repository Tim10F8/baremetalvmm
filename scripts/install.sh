#!/bin/bash
set -e

# VMM Installation Script
# This script installs the VMM binary and Firecracker

INSTALL_DIR="/usr/local/bin"
DATA_DIR="/var/lib/vmm"

echo "VMM Installer"
echo "============="

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Check for KVM
if [ ! -e /dev/kvm ]; then
    echo "Warning: /dev/kvm not found. KVM support is required."
    echo "Ensure your CPU supports virtualization and it's enabled in BIOS."
fi

# Build if vmm binary doesn't exist
if [ ! -f "./vmm" ]; then
    echo "Building VMM..."
    if command -v go &> /dev/null; then
        go build -o vmm ./cmd/vmm/
    else
        echo "Error: Go is not installed. Please build manually or install Go."
        exit 1
    fi
fi

# Install binary
echo "Installing vmm to $INSTALL_DIR..."
cp vmm "$INSTALL_DIR/vmm"
chmod +x "$INSTALL_DIR/vmm"

# Create data directories
echo "Creating data directories..."
mkdir -p "$DATA_DIR"/{config,vms,images/kernels,images/rootfs,mounts,sockets,logs,state}

# Download Firecracker if not present
FC_VERSION="v1.11.0"
FC_BIN="/usr/local/bin/firecracker"
if [ ! -f "$FC_BIN" ]; then
    echo "Downloading Firecracker $FC_VERSION..."
    ARCH=$(uname -m)
    curl -L -o /tmp/firecracker.tgz \
        "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz"
    tar -xzf /tmp/firecracker.tgz -C /tmp
    cp "/tmp/release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH}" "$FC_BIN"
    chmod +x "$FC_BIN"
    rm -rf /tmp/firecracker.tgz "/tmp/release-${FC_VERSION}-${ARCH}"
    echo "Firecracker installed to $FC_BIN"
fi

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Initialize VMM:     vmm config init"
echo "  2. Pull images:        sudo vmm image pull"
echo "  3. Create a VM:        sudo vmm create myvm --ssh-key ~/.ssh/id_ed25519.pub"
echo "  4. Start the VM:       sudo vmm start myvm"
echo "  5. SSH into the VM:    vmm ssh myvm"
echo ""
echo "Optional - To enable auto-start on boot, run:"
echo "  sudo ./scripts/install-service.sh"
echo ""
