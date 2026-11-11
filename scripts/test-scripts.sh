#!/bin/bash
# Self-test for the packaging scripts. Uses a throwaway ICLOUD_GCAL_SYNC_HOME and a
# tiny binary, never touches ~/Library/LaunchAgents or the login keychain.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
export ICLOUD_GCAL_SYNC_HOME="$tmp/home"
before="$(security list-keychains -d user)"
cleanup() {
  security delete-keychain "$ICLOUD_GCAL_SYNC_HOME/signing.keychain-db" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. cert creation is idempotent and does not change the search list.
"$here/make-signing-cert.sh" >/dev/null
sum1="$(shasum "$ICLOUD_GCAL_SYNC_HOME/signing.keychain-db" "$ICLOUD_GCAL_SYNC_HOME/signing.keychain.pass")"
out="$("$here/make-signing-cert.sh")"
[[ "$out" == *"already present"* ]] || fail "second run was not a no-op: $out"
[ "$sum1" = "$(shasum "$ICLOUD_GCAL_SYNC_HOME/signing.keychain-db" "$ICLOUD_GCAL_SYNC_HOME/signing.keychain.pass")" ] || fail "rerun modified files"
[ "$(stat -f %Lp "$ICLOUD_GCAL_SYNC_HOME/signing.keychain.pass")" = 600 ] || fail "pass file mode"
[ "$before" = "$(security list-keychains -d user)" ] || fail "search list changed"

# 2. same designated requirement, different cdhash across two builds.
# shellcheck source=lib.sh
. "$here/lib.sh"
for n in 1 2; do
  printf 'int main(void){return %s;}\n' "$n" > "$tmp/m$n.c"
  cc -o "$tmp/b$n" "$tmp/m$n.c"
  codesign -f -s "$SIGNING_NAME" --keychain "$SIGNING_KEYCHAIN" --identifier "$BUNDLE_ID" "$tmp/b$n" 2>/dev/null
done
[ "$(codesign -d -vvv "$tmp/b1" 2>&1 | grep '^CDHash')" != "$(codesign -d -vvv "$tmp/b2" 2>&1 | grep '^CDHash')" ] || fail "cdhash equal"
dr1="$(codesign -d -r- "$tmp/b1" 2>&1 | grep '^designated')"
[ "$dr1" = "$(codesign -d -r- "$tmp/b2" 2>&1 | grep '^designated')" ] || fail "designated requirement differs"
[[ "$dr1" == *"certificate leaf = H"* ]] || fail "DR is not certificate based: $dr1"

# 3. a locked keychain is unlocked by the script.
security lock-keychain "$SIGNING_KEYCHAIN"
"$here/make-signing-cert.sh" >/dev/null
codesign -f -s "$SIGNING_NAME" --keychain "$SIGNING_KEYCHAIN" --identifier "$BUNDLE_ID" "$tmp/b1" 2>/dev/null || fail "codesign after unlock"

# 4. dry runs print the plist and valid XML; purge refuses dangerous paths.
touch "$ICLOUD_GCAL_SYNC_HOME/token.json"
"$here/install.sh" --dry-run > "$tmp/dry.txt"
grep -q 'ICLOUD_GCAL_SYNC_HOME' "$tmp/dry.txt" || fail "env var missing from plist"
grep -q 'launchctl bootstrap' "$tmp/dry.txt" || fail "bootstrap not printed"
if ICLOUD_GCAL_SYNC_HOME=/ "$here/uninstall.sh" --purge --dry-run >/dev/null 2>&1; then fail "purge / allowed"; fi
if ICLOUD_GCAL_SYNC_HOME=relative "$here/uninstall.sh" --dry-run >/dev/null 2>&1; then fail "relative home allowed"; fi
echo "all script tests passed"
