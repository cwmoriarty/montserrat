#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"

echo "Installing Montserrat to $PREFIX..."

"$HERE/scripts/build.sh"

mkdir -p "$PREFIX/bin" "$PREFIX/share/montserrat/engines/bin" "$PREFIX/share/montserrat/engines/sbin" "$PREFIX/share/montserrat/conf" "$PREFIX/share/montserrat/FSKit"

cp -p "$HERE/dist/bin/"* "$PREFIX/bin/"
cp -pP "$HERE/dist/engines/bin/"* "$PREFIX/share/montserrat/engines/bin/"
cp -p "$HERE/dist/engines/sbin/"* "$PREFIX/share/montserrat/engines/sbin/"
cp -p "$HERE/dist/conf/"* "$PREFIX/share/montserrat/conf/"
cp -p -R "$HERE/dist/FSKit/"* "$PREFIX/share/montserrat/FSKit/"

echo "Installed successfully to $PREFIX/bin."
echo "Binaries available: montserrat, montserratd, MontserratApp, MontserratFSKit.appex"
