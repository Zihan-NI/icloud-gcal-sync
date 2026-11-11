#!/bin/bash
# Create (once) a dedicated keychain holding a self-signed code-signing identity.
#
# Why: calendar permission (TCC) is tied to the binary's designated requirement.
# With an ad-hoc signature that is the cdhash, so every rebuild loses the grant.
# Signed with one stable certificate it becomes `identifier "<id>" and certificate
# leaf = H"<hash>"`, which survives rebuilds.
#
# The keychain password is random and kept next to the keychain (mode 0600). That
# is acceptable: the key only signs this locally built tool, the password file is
# exactly as exposed as a key file readable by the user would be, and nothing is
# ever put in the login keychain.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkdir -p "$APP_HOME"
chmod 700 "$APP_HOME"

if [ -f "$SIGNING_KEYCHAIN" ]; then
  [ -f "$SIGNING_PASS_FILE" ] || {
    echo "error: $SIGNING_KEYCHAIN exists but $SIGNING_PASS_FILE is missing." >&2
    echo "Delete the keychain (security delete-keychain '$SIGNING_KEYCHAIN') and re-run." >&2
    exit 1
  }
  # A locked keychain (e.g. after reboot) makes codesign fail; unlocking is idempotent.
  security unlock-keychain -p "$(cat "$SIGNING_PASS_FILE")" "$SIGNING_KEYCHAIN"
  # find-identity (not find-certificate): the private key must be present too.
  # Without -v it also lists self-signed identities that macOS calls untrusted.
  if security find-identity -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null | grep -qF "\"$SIGNING_NAME\""; then
    echo "Signing identity '$SIGNING_NAME' already present."
    exit 0
  fi
  echo "Keychain exists without the identity; recreating it."
  security delete-keychain "$SIGNING_KEYCHAIN"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT   # removes key.pem / id.p12

umask 077
pass="$(/usr/bin/openssl rand -hex 24)"
printf '%s' "$pass" > "$SIGNING_PASS_FILE"
chmod 600 "$SIGNING_PASS_FILE"

cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGNING_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/id.p12" -passout "pass:$pass" -name "$SIGNING_NAME"

security create-keychain -p "$pass" "$SIGNING_KEYCHAIN"
# No lock timeout and no lock-on-sleep, so unattended rebuilds keep working.
security set-keychain-settings "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$pass" "$SIGNING_KEYCHAIN"
security import "$work/id.p12" -k "$SIGNING_KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a GUI "allow access" prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$SIGNING_KEYCHAIN" >/dev/null

echo "Created signing identity '$SIGNING_NAME' in $SIGNING_KEYCHAIN"
