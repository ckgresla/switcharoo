#!/bin/bash
# Build Switcharoo.app — single-file Swift binary in a minimal .app bundle.
#
# If the self-signed "Switcharoo Dev" identity is present, we sign with it so the
# Accessibility grant survives rebuilds. Otherwise we fall back to ad-hoc.
# Run ./setup-dev-cert.sh once to set up the stable identity.
set -euo pipefail
cd "$(dirname "$0")"

APP="Switcharoo.app"
IDENTITY="Switcharoo Dev"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O \
  -o "$APP/Contents/MacOS/Switcharoo" \
  Switcharoo.swift \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices

# Prefer the stable identity if it exists in the keychain. Self-signed certs
# are filtered out of `security find-identity -p codesigning -v` because
# they're untrusted, but `codesign` itself accepts them — so check by name
# and try the sign, falling back to ad-hoc on failure.
if security find-identity 2>/dev/null | grep -F -q "\"$IDENTITY\"" \
     && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Signed with stable identity \"$IDENTITY\""
else
    codesign --force --sign - "$APP"
    echo "Hint: run ./setup-dev-cert.sh to enable stable signing"
    echo "      (AX permission will persist across rebuilds)."
fi

# Kill any running instance so the next launch picks up this build.
pkill -x Switcharoo 2>/dev/null || true
sleep 0.2
open "$APP"
echo "Built and relaunched $APP"
