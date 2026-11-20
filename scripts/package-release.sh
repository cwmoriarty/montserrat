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
cp -R "$DIST/engines/"* "$APP_RESOURCES/engines/" 2>/dev/null || true
cp -R "$DIST/conf/"* "$APP_RESOURCES/conf/" 2>/dev/null || true

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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
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
