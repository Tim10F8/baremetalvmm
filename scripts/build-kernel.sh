#!/bin/bash
#
# build-kernel.sh - Build a Firecracker-compatible Linux kernel
#
# This script downloads, configures, and builds a Linux kernel suitable
# for use with Firecracker microVMs.
#
# Usage: build-kernel.sh --version <version> --name <name> [--output <dir>]
#
# Supported versions: 5.10, 6.1, 6.6
#

set -e

# Default values
OUTPUT_DIR="/var/lib/vmm/images/kernels"
VERSION=""
NAME=""
BUILD_DIR=""
CLEANUP=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $0 --version <version> --name <name> [--output <dir>]

Build a Firecracker-compatible Linux kernel from source.

Options:
  --version VERSION   Kernel version to build (required)
                      Supported: 5.10, 6.1, 6.6
  --name NAME         Name for the output kernel file (required)
  --output DIR        Output directory (default: /var/lib/vmm/images/kernels)
  --no-cleanup        Keep build directory after completion
  --help              Show this help message

Examples:
  $0 --version 6.1 --name kernel-6.1
  $0 --version 5.10 --name kernel-lts --output /custom/path
EOF
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_dependencies() {
    log_info "Checking build dependencies..."

    local missing=()

    # Check for required packages
    local packages=(
        "build-essential"
        "flex"
        "bison"
        "bc"
        "libelf-dev"
        "libssl-dev"
        "wget"
    )

    for pkg in "${packages[@]}"; do
        if ! dpkg -l "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    # Check for required commands
    local commands=("make" "gcc" "wget" "tar")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required packages: ${missing[*]}"
        log_info "Install them with: sudo apt-get install ${missing[*]}"
        exit 1
    fi

    log_info "All dependencies satisfied"
}

get_kernel_url() {
    local version="$1"
    local major_version="${version%%.*}"

    case "$version" in
        5.10)
            # Latest 5.10 LTS
            echo "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.209.tar.xz"
            ;;
        6.1)
            # Latest 6.1 LTS
            echo "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.119.tar.xz"
            ;;
        6.6)
            # Latest 6.6 LTS
            echo "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.61.tar.xz"
            ;;
        *)
            log_error "Unsupported kernel version: $version"
            log_info "Supported versions: 5.10, 6.1, 6.6"
            exit 1
            ;;
    esac
}

get_firecracker_config_url() {
    local arch="$(uname -m)"
    # Firecracker provides recommended configs in their repo
    echo "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-${arch}-6.1.config"
}

download_kernel() {
    local url="$1"
    local filename="$(basename "$url")"

    log_info "Downloading kernel source from $url"

    if [ -f "$BUILD_DIR/$filename" ]; then
        log_info "Source already downloaded"
    else
        wget -q --show-progress -O "$BUILD_DIR/$filename" "$url"
    fi

    log_info "Extracting kernel source..."
    tar -xf "$BUILD_DIR/$filename" -C "$BUILD_DIR"

    # Find the extracted directory
    local extracted_dir="$(ls -d "$BUILD_DIR"/linux-* | head -1)"
    echo "$extracted_dir"
}

create_kernel_config() {
    local kernel_dir="$1"
    local arch="$(uname -m)"

    log_info "Downloading Firecracker recommended kernel config..."

    cd "$kernel_dir"

    # Download Firecracker's recommended config
    local config_url="https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-${arch}-6.1.config"

    if ! wget -q -O .config "$config_url"; then
        log_warn "Failed to download Firecracker config, using defconfig as base"
        make defconfig
    fi

    log_info "Customizing kernel configuration..."

    # Ensure key options are set correctly
    # These are essential for Firecracker operation
    ./scripts/config --enable CONFIG_VIRTIO
    ./scripts/config --enable CONFIG_VIRTIO_MMIO
    ./scripts/config --enable CONFIG_VIRTIO_BLK
    ./scripts/config --enable CONFIG_VIRTIO_NET
    ./scripts/config --enable CONFIG_SERIAL_8250
    ./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
    ./scripts/config --enable CONFIG_EXT4_FS
    ./scripts/config --enable CONFIG_NET
    ./scripts/config --enable CONFIG_INET

    # Disable modules - we want everything built-in
    ./scripts/config --disable CONFIG_MODULES

    # Disable initramfs - we boot directly to rootfs
    ./scripts/config --disable CONFIG_BLK_DEV_INITRD

    # Update the config to resolve dependencies
    make olddefconfig
}

build_kernel() {
    local kernel_dir="$1"
    local nproc="$(nproc)"

    log_info "Building kernel with $nproc parallel jobs..."
    log_info "This may take 10-30 minutes depending on your system."

    cd "$kernel_dir"
    make -j"$nproc" vmlinux

    if [ ! -f vmlinux ]; then
        log_error "Kernel build failed - vmlinux not found"
        exit 1
    fi

    log_info "Kernel build complete"
}

install_kernel() {
    local kernel_dir="$1"
    local dest="$OUTPUT_DIR/$NAME"

    log_info "Installing kernel to $dest"

    mkdir -p "$OUTPUT_DIR"
    cp "$kernel_dir/vmlinux" "$dest"

    local size=$(du -h "$dest" | cut -f1)
    log_info "Kernel installed: $dest ($size)"
}

cleanup() {
    if [ "$CLEANUP" = true ] && [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        log_info "Cleaning up build directory..."
        rm -rf "$BUILD_DIR"
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --name)
            NAME="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --no-cleanup)
            CLEANUP=false
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments
if [ -z "$VERSION" ]; then
    log_error "--version is required"
    usage
fi

if [ -z "$NAME" ]; then
    log_error "--name is required"
    usage
fi

# Check if running as root (needed for some operations)
if [ "$(id -u)" -ne 0 ]; then
    log_warn "Running as non-root user. You may need root for final installation."
fi

# Create build directory
BUILD_DIR="$(mktemp -d -t vmm-kernel-build-XXXXXX)"
trap cleanup EXIT

log_info "Build directory: $BUILD_DIR"
log_info "Target kernel version: $VERSION"
log_info "Output name: $NAME"

# Main build process
check_dependencies

KERNEL_URL="$(get_kernel_url "$VERSION")"
KERNEL_DIR="$(download_kernel "$KERNEL_URL")"

create_kernel_config "$KERNEL_DIR"
build_kernel "$KERNEL_DIR"
install_kernel "$KERNEL_DIR"

log_info "Kernel '$NAME' built and installed successfully!"
echo ""
echo "Use it with: vmm create myvm --kernel $NAME"
