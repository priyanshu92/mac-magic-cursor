#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
output=".build/native-checks"
mkdir -p "$output"
target="$(uname -m)-apple-macos14.0"

# Compile the production sources directly: no copied implementation and no
# XCTest runtime or GUI launch is needed for these platform integration checks.
xcrun swiftc -swift-version 6 -target "$target" -emit-library -emit-module \
    -module-name MagicCursorCore Sources/MagicCursorCore/*.swift \
    -emit-module-path "$output/MagicCursorCore.swiftmodule" \
    -o "$output/libMagicCursorCore.dylib"
xcrun swiftc -swift-version 6 -target "$target" -parse-as-library \
    -I "$output" -L "$output" -lMagicCursorCore \
    -Xlinker -rpath -Xlinker @executable_path \
    Sources/MagicCursor/AppModel.swift \
    Sources/MagicCursor/ChatMessage.swift \
    Sources/MagicCursor/Speaker.swift \
    Sources/MagicCursor/SettingsStore.swift \
    Sources/MagicCursor/AssistantEngine.swift \
    Sources/MagicCursor/CaptureService.swift \
    Tests/MagicCursorNativeChecks/Checks.swift \
    -o "$output/MagicCursorNativeChecks"
"$output/MagicCursorNativeChecks" "$@"
