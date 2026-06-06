#!/bin/bash
# Create a self-signed code-signing identity called "Switcharoo Dev" so the built
# binary has a stable designated signing requirement across rebuilds. Without
# this, every rebuild generates a new cdhash and macOS silently invalidates
# the Accessibility grant. With a stable signing identity, TCC matches the
# requirement string instead, and the AX grant survives rebuilds.
#
# To remove the identity later: security delete-identity -c "Switcharoo Dev" \
#                                   ~/Library/Keychains/login.keychain-db
set -euo pipefail

IDENTITY="Switcharoo Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null \
     | grep -F -q "\"$IDENTITY\""; then
    echo "Identity \"$IDENTITY\" already present. Nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing identity \"$IDENTITY\"..."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_ext

[req_dn]
CN = $IDENTITY

[v3_ext]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# Use macOS's bundled LibreSSL (at /usr/bin/openssl) rather than whatever's
# first on PATH. Homebrew's OpenSSL 3.x produces PKCS12 archives that macOS's
# `security import` can't verify (even with -legacy).
OPENSSL=/usr/bin/openssl

"$OPENSSL" req -x509 -newkey rsa:2048 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf" 2>/dev/null

# Non-empty password is required — macOS's `security import` rejects empty
# PKCS12 passwords. The password only guards the .p12 file in flight; once
# imported, the keychain stores the key with its own protection.
P12_PASS="switcharoo"

"$OPENSSL" pkcs12 -export \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -password "pass:$P12_PASS" -name "$IDENTITY"

# Import to login keychain. -T grants codesign and security tool access to the
# key. macOS may still prompt the first time codesign uses it — click Always
# Allow once and you're done.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security

echo
echo "Identity \"$IDENTITY\" created and imported into your login keychain."
echo "Verify with: security find-identity -p codesigning -v"
echo
echo "build.sh will now sign with this identity. The first codesign run may"
echo "prompt for keychain access — click 'Always Allow'."
