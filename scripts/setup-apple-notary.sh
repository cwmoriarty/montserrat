#!/bin/bash
set -euo pipefail

APPLE_ID="${APPLE_ID:-${1:-}}"
APP_PASSWORD="${APP_PASSWORD:-${2:-}}"
PROFILE_NAME="${PROFILE_NAME:-${3:-montserrat-notary}}"

DETECTED_TEAM_ID="$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -text -noout 2>/dev/null | grep -E "Subject:.*OU=" | sed -E 's/.*OU=([^,]+).*/\1/' || true)"
TEAM_ID="${TEAM_ID:-${DETECTED_TEAM_ID:-H6PKD5RFCR}}"

echo "=========================================="
echo " Apple Notary Service Credential Setup"
echo " Profile Name: $PROFILE_NAME"
echo " Team ID:      $TEAM_ID"
echo "=========================================="

if [ -z "$APPLE_ID" ]; then
    cat << 'EOF'
To notarize software outside the Mac App Store, Apple requires:
1. An Apple ID enrolled in the Apple Developer Program.
2. An App-Specific Password generated at:
   https://account.apple.com/account/manage (Security -> App-Specific Passwords)

EOF
    read -r -p "Enter your Apple ID email address: " APPLE_ID
fi

if [ -z "$APPLE_ID" ]; then
    echo "Error: Apple ID email cannot be empty."
    exit 1
fi

if [ -z "$APP_PASSWORD" ]; then
    echo "Enter your App-Specific Password (generated at appleid.apple.com):"
    read -r -s APP_PASSWORD
    echo
fi

if [ -z "$APP_PASSWORD" ]; then
    echo "Error: App-Specific Password cannot be empty."
    exit 1
fi

echo "==> Storing credentials in macOS Keychain under profile '$PROFILE_NAME'..."
xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD"

echo "==> Verifying authentication with Apple Notary Service..."
if xcrun notarytool history --keychain-profile "$PROFILE_NAME" >/dev/null; then
    echo "=========================================="
    echo " Notary Credentials Stored Successfully"
    echo " You can now execute: ./scripts/package-release.sh"
    echo "=========================================="
else
    echo "=========================================="
    echo " Verification Failed. Please check your credentials."
    echo "=========================================="
    exit 1
fi
