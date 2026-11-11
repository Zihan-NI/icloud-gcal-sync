#!/bin/bash
# Build, sign and verify dist/icloud-gcal-sync.
#   build.sh            sign with the stable local identity (calendar grant survives rebuilds)
#   build.sh --adhoc    sign ad hoc (grant is lost on the next rebuild)
# Env: SWIFT_BUILD_PATH overrides the SwiftPM build directory.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

adhoc=0
case "${1:-}" in
  "") ;;
  --adhoc) adhoc=1 ;;
  *) echo "usage: $0 [--adhoc]" >&2; exit 2 ;;
esac

# Package.swift embeds Support/Info.plist via a repo-relative path.
cd "$REPO_ROOT"

build_args=(-c release --product icloud-gcal-sync)
[ -n "${SWIFT_BUILD_PATH:-}" ] && build_args+=(--build-path "$SWIFT_BUILD_PATH")
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"

mkdir -p dist
cp -f "$bin_dir/icloud-gcal-sync" dist/icloud-gcal-sync
out="$REPO_ROOT/dist/icloud-gcal-sync"

# Without the embedded plist EventKit never shows the permission prompt.
if ! otool -l "$out" | grep -q 'sectname __info_plist'; then
  echo "error: $out has no __TEXT,__info_plist section" >&2
  exit 1
fi

if [ "$adhoc" = 1 ]; then
  echo "warning: ad-hoc signature; calendar permission will be lost on the next rebuild." >&2
  codesign -f -s - --identifier "$BUNDLE_ID" "$out"
else
  "$REPO_ROOT/scripts/make-signing-cert.sh"
  codesign -f -s "$SIGNING_NAME" --keychain "$SIGNING_KEYCHAIN" --identifier "$BUNDLE_ID" "$out"
fi

codesign --verify --strict "$out"
echo "Built $out"
codesign -d -r- "$out" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
