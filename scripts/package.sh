#!/bin/bash
# Build an installer package for people who do not want to build from source.
#
#   scripts/package.sh        ->  dist/icloud-gcal-sync-<version>.pkg
#
# The package installs for the current user only (no administrator password): the program
# under ~/Library/Application Support/icloud-gcal-sync/bin and a LaunchAgent that starts it.
#
# SIGNING. macOS ties the calendar permission to the program's code signature, so every
# release must be signed with the SAME identity or users are asked for the permission again
# after each update. The identity is the self-signed one from make-signing-cert.sh, in
# "$APP_HOME/signing.keychain-db" on the machine that builds releases. Back up that file and
# signing.keychain.pass; whoever builds the next release needs them.
#
# The package is not signed or notarized by Apple (that needs a paid Developer ID), so
# macOS shows a warning when it is opened. The README explains how to open it.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
build_path="${SWIFT_BUILD_PATH:-$REPO_ROOT/.build}"

# One binary for Apple silicon and Intel.
build_args=(-c release --arch arm64 --arch x86_64 --product icloud-gcal-sync --build-path "$build_path")
swift build "${build_args[@]}"
# The products directory of a multi-architecture build differs between toolchains: ask for it.
bin="$(swift build "${build_args[@]}" --show-bin-path)/icloud-gcal-sync"
[ -f "$bin" ] || { echo "error: $bin was not built" >&2; exit 1; }
for arch in arm64 x86_64; do
  lipo "$bin" -verify_arch "$arch" || { echo "error: $arch missing from $bin" >&2; exit 1; }
  if ! otool -arch "$arch" -l "$bin" | grep -q 'sectname __info_plist'; then
    echo "error: the $arch slice has no embedded Info.plist; EventKit would refuse it" >&2
    exit 1
  fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The payload is only the program folder, installed into the application folder below the
# user's home. Shipping the parent folders too would let the installer reset the
# permissions of ~/Library.
payload="$work/payload/bin"
mkdir -p "$payload" "$work/scripts"
chmod 700 "$work/payload"   # becomes the application folder, which holds the Google token
cp "$bin" "$payload/icloud-gcal-sync"
cp scripts/pkg/uninstall.sh "$payload/uninstall.sh"
cp scripts/pkg/postinstall "$work/scripts/postinstall"
chmod 755 "$payload/icloud-gcal-sync" "$payload/uninstall.sh" "$work/scripts/postinstall"

"$REPO_ROOT/scripts/make-signing-cert.sh"
codesign -f -s "$SIGNING_NAME" --keychain "$SIGNING_KEYCHAIN" --identifier "$BUNDLE_ID" "$payload/icloud-gcal-sync"
codesign --verify --strict "$payload/icloud-gcal-sync"

# No extended attributes: they would be shipped as stray "._" files.
xattr -cr "$work/payload" "$work/scripts"
COPYFILE_DISABLE=1 pkgbuild --quiet --root "$work/payload" --identifier "$BUNDLE_ID.pkg" --version "$version" \
  --scripts "$work/scripts" --install-location "/Library/Application Support/icloud-gcal-sync" "$work/component.pkg"

# "For me only": everything lives in the user's home, so no administrator rights are asked for.
cat > "$work/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>icloud-gcal-sync</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
  <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" title="icloud-gcal-sync"><pkg-ref id="$BUNDLE_ID.pkg"/></choice>
  <pkg-ref id="$BUNDLE_ID.pkg" version="$version">component.pkg</pkg-ref>
</installer-gui-script>
XML

mkdir -p dist
out="$REPO_ROOT/dist/icloud-gcal-sync-$version.pkg"
productbuild --quiet --distribution "$work/distribution.xml" --package-path "$work" "$out"

echo "Built $out"
codesign -d -r- "$payload/icloud-gcal-sync" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
shasum -a 256 "$out" | sed 's/^/SHA-256: /'
