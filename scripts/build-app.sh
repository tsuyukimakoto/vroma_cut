#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT/scripts/check-build-tools.sh"
cd "$ROOT"
[ -f .build/libav/lib/libavformat.a ] || { echo 'Run scripts/build-libav.sh first.' >&2; exit 1; }
xcrun swift build -c release
BINARY=$(xcrun swift build -c release --show-bin-path)
APP="$ROOT/.build/Vroma Cut.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY/VromaCut" "$APP/Contents/MacOS/VromaCut.new"
mv -f "$APP/Contents/MacOS/VromaCut.new" "$APP/Contents/MacOS/VromaCut"
cp Resources/Info.plist "$APP/Contents/Info.plist.new"
mv -f "$APP/Contents/Info.plist.new" "$APP/Contents/Info.plist"
cp -R .build/libav/licenses "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/licenses/VromaCut-MIT.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
