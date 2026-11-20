#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ARCHS="${ARCHS:-$(uname -m)}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"

echo "=========================================="
echo " Building Montserrat (cwmoriarty/montserrat)"
echo " Target Arch: $ARCHS"
echo " Build Mode:  $BUILD_CONFIG"
echo "=========================================="

# 1. Setup Environment
"$HERE/scripts/setup-environment.sh"

# 2. Build Engines if not already present
if [ ! -x "$HERE/engines/out/bin/fuse2fs" ] || [ ! -x "$HERE/engines/out/bin/ntfs-3g" ]; then
    echo "==> Building Filesystem Engines (fuse2fs and ntfs-3g)..."
    (cd "$HERE/engines" && ARCHS="$ARCHS" ./build-engines.sh all)
else
    echo "==> Engines already compiled in engines/out"
fi

# 3. Build Swift CLI and Core Framework
echo "==> Building Swift Package ($BUILD_CONFIG)..."
(cd "$HERE" && swift build -c "$BUILD_CONFIG")

# 4. Prepare Staging / Distribution
DIST="$HERE/dist"
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/engines/bin" "$DIST/engines/sbin" "$DIST/conf" "$DIST/FSKit/MontserratFSKit.appex/Contents/MacOS"

find_bin() {
    local name="$1"
    for cand in \
        "$HERE/.build/out/Products/Release/$name" \
        "$HERE/.build/out/Products/Debug/$name" \
        "$HERE/.build/out/release/$name" \
        "$HERE/.build/release/$name" \
        "$HERE/.build/debug/$name"; do
        if [ -x "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

if bin="$(find_bin montserrat)"; then cp -p "$bin" "$DIST/bin/montserrat"; fi
if bin="$(find_bin montserratd)"; then cp -p "$bin" "$DIST/bin/montserratd"; fi
if bin="$(find_bin MontserratApp)"; then cp -p "$bin" "$DIST/bin/MontserratApp"; fi

if bin="$(find_bin MontserratFSKitExtension)"; then
    cp -p "$bin" "$DIST/FSKit/MontserratFSKit.appex/Contents/MacOS/MontserratFSKit"
    cp -p "$HERE/Sources/MontserratFSKit/Resources/Info.plist" "$DIST/FSKit/MontserratFSKit.appex/Contents/Info.plist"
    cp -p "$HERE/Sources/MontserratFSKit/Resources/Info.plist" "$DIST/FSKit/Info.plist"
    codesign -s - -f "$DIST/FSKit/MontserratFSKit.appex" 2>/dev/null || true
fi

cp -p "$HERE/engines/out/bin/fuse2fs" "$DIST/engines/bin/"
cp -p "$HERE/engines/out/bin/ntfs-3g" "$DIST/engines/bin/"
if [ -f "$HERE/engines/out/bin/btrfs-fuse" ]; then cp -p "$HERE/engines/out/bin/btrfs-fuse" "$DIST/engines/bin/"; fi
if [ -f "$HERE/engines/out/bin/xfs-fuse" ]; then cp -p "$HERE/engines/out/bin/xfs-fuse" "$DIST/engines/bin/"; fi
if [ -f "$HERE/engines/out/bin/f2fs-fuse" ]; then cp -p "$HERE/engines/out/bin/f2fs-fuse" "$DIST/engines/bin/"; fi
cp -p "$HERE/engines/out/sbin/mke2fs" "$DIST/engines/sbin/"
cp -p "$HERE/engines/out/sbin/e2fsck" "$DIST/engines/sbin/"
cp -p "$HERE/engines/out/sbin/mkntfs" "$DIST/engines/sbin/"
cp -p "$HERE/engines/conf/mke2fs.conf" "$DIST/conf/"

echo "=========================================="
echo " Build Succeeded"
echo " Binaries staged at: $DIST"
echo " CLI executable:     $DIST/bin/montserrat"
echo "=========================================="
