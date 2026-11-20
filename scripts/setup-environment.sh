#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Setting up Montserrat Environment ==="
echo "Operating System: $(sw_vers -productName) $(sw_vers -productVersion)"
echo "Darwin Kernel:    $(uname -r)"
echo "Architecture:     $(uname -m)"

# 1. Check Xcode and Swift
if ! command -v swift >/dev/null 2>&1; then
    echo "Error: swift compiler not found. Please install Xcode or Command Line Tools."
    exit 1
fi
echo "Swift:            $(swift --version | head -n 1)"
echo "Clang:            $(cc --version | head -n 1)"

# 2. Check FUSE-T
if [ -f "/usr/local/include/fuse3/fuse.h" ] && [ -e "/usr/local/lib/libfuse3.dylib" ]; then
    echo "FUSE-T:           Installed in /usr/local"
else
    echo "FUSE-T:           Not detected in /usr/local"
    echo "Please install FUSE-T via Homebrew:"
    echo "  brew install --cask macos-fuse-t/homebrew-cask/fuse-t"
fi

echo "=== Environment Setup Completed ==="
