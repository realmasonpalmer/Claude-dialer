#!/usr/bin/env bash
# One time: makes a free signing certificate on this Mac, just for Clarity Live Coach.
# With it, macOS sees every update as the same app, so it remembers your permissions
# (microphone, call audio, Chrome, calendar, Keychain) instead of asking again.
set -euo pipefail

NAME="Clarity Live Coach Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Signing certificate is already set up."
    exit 0
fi

echo "Setting up a signing certificate (one time only)."
echo "macOS will ask for your Mac password. That's expected."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CONF
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

# Apple's built-in openssl, on purpose (other versions make files the Keychain can't import).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" -extensions ext >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout pass:clarity >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P clarity -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Signing certificate is ready."
