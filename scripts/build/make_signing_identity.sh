#!/usr/bin/env bash
#
# make_signing_identity.sh — create the stable self-signed code-signing identity
# the Intel-fork build/release scripts use to sign osaurus.app.
#
# WHY THIS EXISTS
# Ad-hoc signing (`codesign --sign -`) gives the app no stable identity, so its
# designated requirement is the per-build cdhash — different every build. macOS
# Keychain pins each "Always Allow" grant to that requirement, so every app
# update looked like "a different app" and re-prompted for ALL keychain items
# (RemoteProvider, MCP, Storage Key, Master Key). Signing with ONE stable
# self-signed cert makes the requirement constant
# (`identifier "com.dinoki.osaurus" and certificate leaf = H"<cert>"`), so the
# grant sticks across updates. No Apple Developer account, no notarization — the
# sovereign path. (Gatekeeper still treats it as an unidentified developer on
# first open; this only fixes the keychain re-prompt, not Gatekeeper.)
#
# Run ONCE per signing machine. Idempotent: re-running when the identity already
# exists is a no-op. Lives only on the build machine; Rosy verifies the embedded
# signature, so the cert never has to leave here.
#
set -euo pipefail

IDENTITY_NAME="${OSAURUS_SIGN_IDENTITY:-Osaurus Intel Code Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "✓ Signing identity '$IDENTITY_NAME' already exists — nothing to do."
  security find-identity -p codesigning 2>/dev/null | grep "$IDENTITY_NAME"
  exit 0
fi

echo "→ Creating self-signed code-signing identity '$IDENTITY_NAME' (10-year)…"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cert.conf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY_NAME
O = Osaurus Intel (self-signed)
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config cert.conf >/dev/null 2>&1

# `-legacy`: OpenSSL 3.x defaults to a PBKDF2/AES p12 that macOS `security`
# cannot import; the legacy PBE is what the Keychain accepts.
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 \
  -passout pass:transit -name "$IDENTITY_NAME" >/dev/null 2>&1

# `-T /usr/bin/codesign`: pre-authorize codesign to use the private key so
# signing doesn't pop a keychain prompt on every build.
security import id.p12 -k "$KEYCHAIN" -P transit -T /usr/bin/codesign >/dev/null

echo "✓ Identity created and imported. It will show as NOT_TRUSTED (self-signed) —"
echo "  that is expected and does NOT block codesign from signing with it."
security find-identity -p codesigning 2>/dev/null | grep "$IDENTITY_NAME"
