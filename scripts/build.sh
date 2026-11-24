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

# 2. Build Engines if missing or missing requested arch slices
need_engines_build="false"
if [ ! -x "$HERE/engines/out/bin/fuse2fs" ] || [ ! -x "$HERE/engines/out/bin/ntfs-3g" ] || \
   [ ! -x "$HERE/engines/out/bin/legacyfs-mount" ] || [ ! -f "$HERE/engines/out/lib/libext2fs.a" ] || \
   [ ! -f "$HERE/engines/out/lib/liblegacyfs.a" ]; then
    need_engines_build="true"
else
    for archive in "$HERE/engines/out/lib/libext2fs.a" "$HERE/engines/out/lib/liblegacyfs.a"; do
        present_archs="$(lipo -archs "$archive" 2>/dev/null || true)"
        for req_arch in $ARCHS; do
            case " $present_archs " in
                *" $req_arch "*) ;;
                *) need_engines_build="true" ;;
            esac
        done
    done
fi

if [ "$need_engines_build" = "true" ]; then
    echo "==> Building Filesystem Engines (fuse2fs, ntfs-3g, and legacyfs)..."
    (cd "$HERE/engines" && ARCHS="$ARCHS" ./build-engines.sh all)
else
    echo "==> Engines already compiled in engines/out for ($ARCHS)"
fi

# 3. Build Swift CLI and Core Framework
SWIFT_ARCH_ARGS=()
for req_arch in $ARCHS; do
    SWIFT_ARCH_ARGS+=(--arch "$req_arch")
done

echo "==> Building Swift Package ($BUILD_CONFIG, archs: $ARCHS)..."
(cd "$HERE" && swift build -c "$BUILD_CONFIG" "${SWIFT_ARCH_ARGS[@]}")
SWIFT_BIN_DIR="$(cd "$HERE" && swift build -c "$BUILD_CONFIG" "${SWIFT_ARCH_ARGS[@]}" --show-bin-path 2>/dev/null || true)"

# 4. Prepare Staging / Distribution
DIST="$HERE/dist"
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/engines/bin" "$DIST/engines/sbin" "$DIST/conf" "$DIST/FSKit/MontserratFSKit.appex/Contents/MacOS"

find_bin() {
    local name="$1"
    for cand in \
        "${SWIFT_BIN_DIR:-}/$name" \
        "$HERE/.build/apple/Products/Release/$name" \
        "$HERE/.build/apple/Products/Debug/$name" \
        "$HERE/.build/out/Products/Release/$name" \
        "$HERE/.build/out/Products/Debug/$name" \
        "$HERE/.build/out/release/$name" \
        "$HERE/.build/release/$name" \
        "$HERE/.build/debug/$name"; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then
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
cp -p "$HERE/engines/out/bin/ntfsfix" "$DIST/engines/bin/"
cp -p "$HERE/engines/out/bin/legacyfs" "$DIST/engines/bin/"
cp -p "$HERE/engines/out/bin/legacyfs-mount" "$DIST/engines/bin/"
cp -pP "$HERE/engines/out/bin/fuse-"* "$DIST/engines/bin/"
cp -p "$HERE/engines/out/sbin/mke2fs" "$DIST/engines/sbin/"
cp -p "$HERE/engines/out/sbin/e2fsck" "$DIST/engines/sbin/"
cp -p "$HERE/engines/out/sbin/mkntfs" "$DIST/engines/sbin/"
cp -p "$HERE/engines/conf/mke2fs.conf" "$DIST/conf/"

echo "=========================================="
echo " Build Succeeded"
echo " Binaries staged at: $DIST"
echo " CLI executable:     $DIST/bin/montserrat"
echo "=========================================="
