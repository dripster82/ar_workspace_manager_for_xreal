#!/bin/zsh
# One-time: create a self-signed code-signing certificate so the app keeps a STABLE
# signature across rebuilds. macOS ties Screen-Recording / Accessibility (TCC) grants to
# the code signature, so ad-hoc signing (which changes every build) forces re-approval each
# time. With this cert, grant the permissions once and they persist across rebuilds.
#
# Run once:  Scripts/make-signing-cert.sh
# Then build as usual; build-app.sh will pick it up automatically.
set -euo pipefail

NAME="VRDesktop Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" >/dev/null 2>&1
# -legacy: OpenSSL 3 defaults to a PKCS12 MAC that macOS `security` can't import.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:vrdesktop -name "$NAME" >/dev/null 2>&1

# -T /usr/bin/codesign pre-authorizes codesign to use the key without a keychain prompt.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P vrdesktop -T /usr/bin/codesign

echo "Created code-signing identity: $NAME"
echo "Now run Scripts/build-app.sh and grant permissions once — they'll stick across rebuilds."
