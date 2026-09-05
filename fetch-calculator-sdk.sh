#!/bin/bash
# Vendor SDK for personal/private builds. Public distribution requires a Soulver license.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=3.5.1
SHA=36e51abc2d22b2f1000ceeb4468cfa9ce74f4cf3fb79097f7f3e004b7bf9e7c7
DEST="$PWD/.build/dependencies"
mkdir -p "$DEST"
ZIP="$DEST/SoulverCore-$VERSION.zip"
if [[ ! -f "$ZIP" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 --output "$ZIP.partial" "https://github.com/soulverteam/SoulverCore/releases/download/$VERSION/SoulverCore.xcframework.zip"
  mv "$ZIP.partial" "$ZIP"
fi
printf '%s  %s\n' "$SHA" "$ZIP" | shasum -a 256 --check
mkdir -p "$DEST/SoulverCore-$VERSION"
unzip -q -o "$ZIP" -d "$DEST/SoulverCore-$VERSION"
