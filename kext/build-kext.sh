#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ARCHS="${ARCHS:-$(uname -m)}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
KERNEL_HEADERS="$SDK_PATH/System/Library/Frameworks/Kernel.framework/Headers"
OUT_KEXT="$HERE/dist/kext/montserrat.kext"

echo "Building Montserrat VFS Kernel Extension..."
echo "Target Arch: $ARCHS"
echo "SDK:         $SDK_PATH"

rm -rf "$HERE/dist/kext"
mkdir -p "$OUT_KEXT/Contents/MacOS"

BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT

SLICES=()
for arch in $ARCHS; do
    echo "Compiling slice: $arch"
    clang -x c -c -target "$arch-apple-macos15.0" \
        -mkernel -fno-builtin -nostdinc \
        -isystem "$KERNEL_HEADERS" \
        -O2 -Wall \
        -o "$BUILD_TMP/montserrat_vfs_$arch.o" \
        "$HERE/kext/montserrat_vfs.c"

    clang -target "$arch-apple-macos15.0" \
        -Xlinker -kext -nostdlib \
        -Xlinker -export_dynamic \
        -o "$BUILD_TMP/montserrat_$arch" \
        "$BUILD_TMP/montserrat_vfs_$arch.o"

    SLICES+=("$BUILD_TMP/montserrat_$arch")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
    echo "Combining universal slices via lipo..."
    lipo -create "${SLICES[@]}" -output "$OUT_KEXT/Contents/MacOS/montserrat"
else
    cp -p "${SLICES[0]}" "$OUT_KEXT/Contents/MacOS/montserrat"
fi

cp -p "$HERE/kext/Info.plist" "$OUT_KEXT/Contents/Info.plist"

SIGN_ID="${SIGN_IDENTITY:--}"
echo "Signing kernel extension with identity: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$OUT_KEXT" 2>/dev/null || true

echo "Kernel extension built successfully at: $OUT_KEXT"
