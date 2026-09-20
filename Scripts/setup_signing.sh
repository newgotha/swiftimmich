#!/bin/bash
# Creates a self-signed code-signing certificate ("SwiftImmich Local Signing") in your
# login keychain, once. build_and_install.sh signs with it, so the app has the same
# identity after every rebuild and the Keychain prompt for the saved API key stops
# coming back (an ad-hoc signature changes with every build, so macOS re-asks each time).
set -euo pipefail

NAME="SwiftImmich Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
    echo "\"$NAME\" already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="swiftimmich-$(uuidgen)"

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -name "$NAME" -passout "pass:$PASS" 2>/dev/null

# -T lets codesign use the private key without asking each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\" in your login keychain."
security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME" || true
