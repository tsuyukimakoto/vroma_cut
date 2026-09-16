#!/bin/sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'Vroma Cut requires macOS.' >&2; exit 1; }
[ "$(sw_vers -productVersion | cut -d . -f 1)" -ge 15 ] || { echo 'macOS 15 or later is required.' >&2; exit 1; }
for tool in xcrun swift make curl tar shasum codesign; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing tool: $tool. Install Xcode and select its Command Line Tools." >&2; exit 1; }
done
xcrun --find clang >/dev/null
xcrun --sdk macosx --show-sdk-path >/dev/null
SWIFT_MAJOR=$(xcrun swift --version | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$SWIFT_MAJOR" ] && [ "$SWIFT_MAJOR" -ge 6 ] || { echo 'Select an Xcode toolchain with Swift 6 or later.' >&2; exit 1; }
