#!/bin/bash
set -euo pipefail

# Builds the universal release app and zips it for a GitHub release.
cd "$(dirname "$0")/.."
bash scripts/build-app.sh release
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
archive="dist/Magic-Cursor-$version.app.zip"
rm -f "$archive"
# ditto preserves the bundle's code signature; plain zip can break it.
# --norsrc --noextattr leaves out local metadata such as com.apple.provenance,
# which would otherwise appear as stray ._ files in other unzip tools.
ditto -c -k --norsrc --noextattr --keepParent "dist/Magic Cursor.app" "$archive"
printf 'Packaged %s/%s\n' "$PWD" "$archive"
