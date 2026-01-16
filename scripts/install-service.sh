#!/bin/bash
set -e

# VMM Systemd Service Installation Script
# This script installs the systemd service for VM auto-start on boot

SERVICE_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "VMM Service Installer"
echo "====================="

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Check if vmm is installed
if ! command -v vmm &> /dev/null; then
    echo "Error: vmm is not installed. Please run install.sh first."
    exit 1
fi

# Install systemd service
echo "Installing systemd service..."
cp "$SCRIPT_DIR/vmm.service" "$SERVICE_DIR/vmm.service"
systemctl daemon-reload

echo ""
echo "Systemd service installed!"
echo ""
echo "To enable auto-start on boot:"
echo "  sudo systemctl enable vmm"
echo ""
echo "To start the service now:"
echo "  sudo systemctl start vmm"
echo ""
echo "To check service status:"
echo "  sudo systemctl status vmm"
echo ""
