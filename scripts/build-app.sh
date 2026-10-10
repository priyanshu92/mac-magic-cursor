#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    printf 'Usage: bash scripts/build-app.sh [release|debug]\n' >&2
    exit 2
fi

# Release builds are universal so the downloadable app runs on Apple silicon
# and Intel Macs. Debug builds stay native for faster iteration.
build_args=(-c "$configuration")
if [[ "$configuration" == "release" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}" --product MagicCursor
binary_directory="$(swift build "${build_args[@]}" --show-bin-path)"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
app="dist/Magic Cursor.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$binary_directory/MagicCursor" "$app/Contents/MacOS/MagicCursor"
# Ad-hoc signing with a stable designated requirement lets macOS keep the
# Screen Recording approval across rebuilds instead of tying it to a
# changing code hash.
codesign --force --sign - --identifier "$bundle_id" \
    --requirements "=designated => identifier \"$bundle_id\"" "$app"
printf '\nBuilt %s/%s\n' "$PWD" "$app"
