#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(git -C "$HERE" describe --tags --always 2>/dev/null || echo "1.0.0")}"
VERSION="${VERSION#v}"
DIST="$HERE/dist"
OUT_DIR="$HERE/dist/release"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-auto}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-montserrat-notary}"
ENTITLEMENTS="$HERE/Sources/MontserratApp/Montserrat.entitlements"
FSKIT_ENTITLEMENTS="$HERE/Sources/MontserratFSKit/MontserratFSKit.entitlements"
FSKIT_PROVISIONPROFILE_PATH="${FSKIT_PROVISIONPROFILE_PATH:-}"

echo "=========================================="
echo " Montserrat Release Packaging"
echo " Version:  $VERSION"
echo " Output:   $OUT_DIR"
echo "=========================================="

# 1. Automatic Identity Discovery
find_identity() {
    local query="$1"
    security find-identity -p codesigning -v 2>/dev/null | grep "$query" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true
}

if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(find_identity "Developer ID Application")"
    if [ -z "$SIGNING_IDENTITY" ]; then
        SIGNING_IDENTITY="$(find_identity "Apple Development")"
    fi
fi

if [ -z "$INSTALLER_IDENTITY" ]; then
    INSTALLER_IDENTITY="$(security find-identity -v 2>/dev/null | grep "Developer ID Installer" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Using Code Signing Identity: $SIGNING_IDENTITY"
else
    echo "==> No signing identity found in keychain. Falling back to ad-hoc signing."
fi

if [ -n "$INSTALLER_IDENTITY" ]; then
    echo "==> Using Installer Signing Identity: $INSTALLER_IDENTITY"
fi

# 2. Ensure binaries are built
if [ ! -x "$DIST/bin/montserrat" ] || [ ! -x "$DIST/bin/MontserratApp" ]; then
    echo "==> Building Montserrat release binaries..."
    "$HERE/scripts/build.sh"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# 3. Assemble Montserrat.app bundle
APP_BUNDLE="$OUT_DIR/Montserrat.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

echo "==> Creating macOS application bundle: Montserrat.app..."
mkdir -p "$APP_MACOS" "$APP_RESOURCES/bin" "$APP_RESOURCES/engines/bin" "$APP_RESOURCES/engines/sbin" "$APP_RESOURCES/conf"

cp -p "$DIST/bin/MontserratApp" "$APP_MACOS/MontserratApp"
cp -p "$DIST/bin/montserrat" "$APP_RESOURCES/bin/montserrat"
if [ -f "$DIST/bin/montserratd" ]; then
    cp -p "$DIST/bin/montserratd" "$APP_RESOURCES/bin/montserratd"
fi
cp -RP "$DIST/engines/"* "$APP_RESOURCES/engines/" 2>/dev/null || true
cp -R "$DIST/conf/"* "$APP_RESOURCES/conf/" 2>/dev/null || true

if [ -d "$DIST/FSKit/MontserratFSKit.appex" ]; then
    mkdir -p "$APP_CONTENTS/PlugIns"
    cp -R "$DIST/FSKit/MontserratFSKit.appex" "$APP_CONTENTS/PlugIns/"
fi

# Generate AppIcon.icns using CoreGraphics + iconutil
ICON_WORK="$(mktemp -d -t montserrat_icon)"
ICONSET_DIR="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
if swift - "$ICONSET_DIR" >/dev/null 2>&1 <<'SWIFT_ICON'
import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(px)
    let bgRect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let path = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.19, alpha: 1.0).setFill()
    path.fill()

    let bodyRect = NSRect(x: s * 0.22, y: s * 0.22, width: s * 0.56, height: s * 0.56)
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: s * 0.09, yRadius: s * 0.09)
    NSColor(calibratedRed: 0.24, green: 0.62, blue: 0.96, alpha: 1.0).setStroke()
    body.lineWidth = max(1.0, s * 0.05)
    body.stroke()

    let ledRect = NSRect(x: s * 0.34, y: s * 0.34, width: s * 0.32, height: s * 0.09)
    let led = NSBezierPath(roundedRect: ledRect, xRadius: s * 0.045, yRadius: s * 0.045)
    NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1.0).setFill()
    led.fill()

    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: outDir.appendingPathComponent(filename))
    }
}
SWIFT_ICON
then
    iconutil -c icns "$ICONSET_DIR" -o "$APP_RESOURCES/AppIcon.icns" 2>/dev/null || true
fi
rm -rf "$ICON_WORK"

ICON_PLIST_ENTRY=""
if [ -f "$APP_RESOURCES/AppIcon.icns" ]; then
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
fi

cat <<EOF > "$APP_CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MontserratApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.cwmoriarty.montserrat.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Montserrat</string>
    <key>CFBundleDisplayName</key>
    <string>Montserrat</string>
$ICON_PLIST_ENTRY
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2025 Chris Moriarty. MIT License.</string>
</dict>
</plist>
EOF

# 4. Codesign application bundle (inside-out signing)
sign_target() {
    local target="$1"
    if [ -n "$SIGNING_IDENTITY" ]; then
        if [ -f "$ENTITLEMENTS" ]; then
            codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$target"
        else
            codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$target"
        fi
    else
        codesign --force -s - "$target"
    fi
}

echo "==> Signing embedded binaries and helper engines..."
find "$APP_RESOURCES/bin" "$APP_RESOURCES/engines" -type f -perm +111 2>/dev/null | while read -r bin; do
    if file "$bin" | grep -q "Mach-O"; then
        sign_target "$bin"
    fi
done

if [ -d "$APP_CONTENTS/PlugIns/MontserratFSKit.appex" ]; then
    echo "==> Signing embedded FSKit extension..."
    APPEX_PATH="$APP_CONTENTS/PlugIns/MontserratFSKit.appex"
    if [ -n "$FSKIT_PROVISIONPROFILE_PATH" ] && [ -f "$FSKIT_PROVISIONPROFILE_PATH" ]; then
        echo "    Embedding provisioned FSKit profile: $FSKIT_PROVISIONPROFILE_PATH"
        cp -p "$FSKIT_PROVISIONPROFILE_PATH" "$APPEX_PATH/Contents/embedded.provisionprofile"
    fi
    if [ -n "$SIGNING_IDENTITY" ] && [ -f "$APPEX_PATH/Contents/embedded.provisionprofile" ] && [ -f "$FSKIT_ENTITLEMENTS" ]; then
        codesign --force --options runtime --entitlements "$FSKIT_ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$APPEX_PATH"
    else
        sign_target "$APPEX_PATH"
    fi
fi

echo "==> Signing main application executable..."
sign_target "$APP_MACOS/MontserratApp"

echo "==> Signing application bundle..."
sign_target "$APP_BUNDLE"

# 5. Create Distributable DMG
DMG_STAGING="$(mktemp -d -t montserrat_dmg)"
DMG_OUTPUT="$OUT_DIR/Montserrat-$VERSION.dmg"

echo "==> Assembling DMG staging directory..."
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
cp "$HERE/LICENSE" "$DMG_STAGING/LICENSE.txt"

echo "==> Generating compressed DMG: $DMG_OUTPUT..."
hdiutil create \
    -volname "Montserrat" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT" >/dev/null

rm -rf "$DMG_STAGING"

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Signing DMG image..."
    codesign --force --sign "$SIGNING_IDENTITY" "$DMG_OUTPUT"
fi

# 6. Create Installer PKG
PKG_STAGING="$(mktemp -d -t montserrat_pkg)"
PKG_OUTPUT="$OUT_DIR/Montserrat-$VERSION.pkg"

echo "==> Creating component package: $PKG_OUTPUT..."
mkdir -p "$PKG_STAGING/Applications"
cp -R "$APP_BUNDLE" "$PKG_STAGING/Applications/"

if [ -n "$INSTALLER_IDENTITY" ]; then
    echo "==> Building signed installer package..."
    pkgbuild \
        --root "$PKG_STAGING" \
        --identifier "com.cwmoriarty.montserrat.pkg" \
        --version "$VERSION" \
        --install-location "/" \
        --sign "$INSTALLER_IDENTITY" \
        "$PKG_OUTPUT" >/dev/null
else
    pkgbuild \
        --root "$PKG_STAGING" \
        --identifier "com.cwmoriarty.montserrat.pkg" \
        --version "$VERSION" \
        --install-location "/" \
        "$PKG_OUTPUT" >/dev/null
fi

rm -rf "$PKG_STAGING"

# 7. Notarization
should_notarize="false"
if [ "$NOTARIZE" = "true" ]; then
    should_notarize="true"
elif [ "$NOTARIZE" = "auto" ]; then
    if security find-generic-password -s "notarytool" -a "$KEYCHAIN_PROFILE" >/dev/null 2>&1 || \
       security find-generic-password -s "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
        should_notarize="true"
    fi
fi

if [ "$should_notarize" = "true" ]; then
    echo "==> Submitting DMG to Apple Notary Service (profile: $KEYCHAIN_PROFILE)..."
    if xcrun notarytool submit "$DMG_OUTPUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
        echo "==> Stapling notarization ticket to DMG..."
        xcrun stapler staple "$DMG_OUTPUT"
    else
        echo "Warning: Notarization of DMG reported issues."
    fi

    echo "==> Submitting PKG to Apple Notary Service (profile: $KEYCHAIN_PROFILE)..."
    if xcrun notarytool submit "$PKG_OUTPUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
        echo "==> Stapling notarization ticket to PKG..."
        xcrun stapler staple "$PKG_OUTPUT"
    else
        echo "Warning: Notarization of PKG reported issues."
    fi
else
    echo "==> Notarization profile not detected or requested. Skipping notary submission."
    echo "    To store Apple ID credentials, execute: ./scripts/setup-apple-notary.sh"
fi

# 8. Generate Checksums
echo "==> Calculating SHA-256 checksums..."
(
    cd "$OUT_DIR"
    shasum -a 256 "Montserrat-$VERSION.dmg" "Montserrat-$VERSION.pkg" > checksums.txt
)

echo "=========================================="
echo " Release Packaging Completed"
echo " Artifacts in: $OUT_DIR"
cat "$OUT_DIR/checksums.txt"
echo "=========================================="
