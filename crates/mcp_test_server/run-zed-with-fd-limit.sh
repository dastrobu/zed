#!/bin/bash

# Wrapper script to run Zed with a limited file descriptor count
# This is safer than changing the global limit with ulimit

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Default FD limit
FD_LIMIT=${1:-256}

print_info "Running Zed with FD limit: $FD_LIMIT"
echo

# Check if we're in the zed repository
if [ ! -f "Cargo.toml" ] || ! grep -q "workspace" Cargo.toml; then
    print_error "This script must be run from the zed repository root"
    exit 1
fi

# Detect OS
OS="$(uname -s)"

case "$OS" in
    Linux*)
        # On Linux, we can use prlimit if available
        if command -v prlimit &> /dev/null; then
            print_success "Using prlimit (Linux)"
            print_info "Building Zed..."
            cargo build --release

            print_success "Starting Zed with FD limit $FD_LIMIT"
            exec prlimit --nofile=$FD_LIMIT:$FD_LIMIT ./target/release/zed
        else
            # Fallback to ulimit (affects current shell only)
            print_warning "prlimit not found, using ulimit (affects this shell only)"
            print_info "Building Zed..."
            cargo build --release

            print_success "Starting Zed with FD limit $FD_LIMIT"
            ulimit -n $FD_LIMIT
            exec ./target/release/zed
        fi
        ;;

    Darwin*)
        # On macOS, use launchctl limit or ulimit
        print_success "Detected macOS"

        # Store original limit
        ORIG_SOFT=$(ulimit -Sn)
        ORIG_HARD=$(ulimit -Hn)
        print_info "Original limits: soft=$ORIG_SOFT, hard=$ORIG_HARD"

        # Try to set the limit
        print_info "Building Zed..."
        cargo build --release

        print_success "Starting Zed with FD limit $FD_LIMIT"
        print_warning "This sets the limit for the Zed process and its children"

        # Set limit and run Zed
        ulimit -Sn $FD_LIMIT
        ulimit -Hn $FD_LIMIT

        # Run Zed
        exec ./target/release/zed
        ;;

    *)
        print_error "Unsupported OS: $OS"
        exit 1
        ;;
esac
