#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT/scripts/check-build-tools.sh"
VERSION=8.0.3
EXPECTED=6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818
DEPS="$ROOT/.build/libav"
WORK="$ROOT/.build/libav-build"
ARCHIVE="${1:-$ROOT/.build/ffmpeg-$VERSION.tar.xz}"
JOBS=${VROMA_BUILD_JOBS:-4}
case "$JOBS" in ''|*[!0-9]*|0) echo 'VROMA_BUILD_JOBS must be a positive integer.' >&2; exit 1;; esac
[ "$#" -le 1 ] || { echo 'Usage: scripts/build-libav.sh [source.tar.xz]' >&2; exit 1; }
if [ "$#" -eq 1 ] && [ ! -f "$ARCHIVE" ]; then
  echo "Source archive not found: $ARCHIVE" >&2; exit 1
fi
mkdir -p "$ROOT/.build"
BUILD_KEY=$({
  shasum -a 256 "$ROOT/scripts/build-libav.sh"
  uname -m
  xcrun clang --version
  xcrun --sdk macosx --show-sdk-path
  xcrun --sdk macosx --show-sdk-version
} | shasum -a 256 | cut -d ' ' -f 1)
# Explicit archives must be checked even when an installed library can be reused.
if [ -f "$ARCHIVE" ]; then
  ACTUAL=$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)
  [ "$ACTUAL" = "$EXPECTED" ] || { echo 'FFmpeg archive checksum mismatch.' >&2; exit 1; }
fi
if [ "${VROMA_REBUILD_LIBAV:-0}" != 1 ] && [ -f "$DEPS/build-key" ] && [ "$(cat "$DEPS/build-key")" = "$BUILD_KEY" ]; then
  COMPLETE=1
  for item in lib/libavformat.a lib/libavcodec.a lib/libavutil.a include/libavformat/avformat.h config.h licenses/COPYING.LGPLv2.1 licenses/LICENSE.md; do
    [ -f "$DEPS/$item" ] || COMPLETE=0
  done
  if [ "$COMPLETE" = 1 ]; then printf 'Reusing FFmpeg %s: %s\n' "$VERSION" "$DEPS"; exit 0; fi
fi
if [ ! -f "$ARCHIVE" ]; then
  DOWNLOAD=$(mktemp "$ROOT/.build/ffmpeg-download.XXXXXX")
  trap 'rm -f "$DOWNLOAD"' EXIT HUP INT TERM
  curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$DOWNLOAD"
  ACTUAL=$(shasum -a 256 "$DOWNLOAD" | cut -d ' ' -f 1)
  [ "$ACTUAL" = "$EXPECTED" ] || { echo 'FFmpeg archive checksum mismatch.' >&2; exit 1; }
  mv "$DOWNLOAD" "$ARCHIVE"
  trap - EXIT HUP INT TERM
fi
mkdir -p "$WORK" "$DEPS"
rm -f "$DEPS/build-key"
tar -xJf "$ARCHIVE" -C "$WORK"
cd "$WORK/ffmpeg-$VERSION"
if [ -f ffbuild/config.mak ]; then make distclean > "$WORK/clean.log" 2>&1; fi
# x86 assembly is disabled so an Intel source build does not need external nasm.
if ! ./configure --prefix="$DEPS" --cc="xcrun --sdk macosx clang" \
  --disable-everything --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 \
  --disable-doc --disable-programs --disable-network --disable-shared --enable-static --disable-x86asm \
  --enable-pic --extra-cflags=-mmacosx-version-min=15.0 --extra-ldflags=-mmacosx-version-min=15.0 \
  --enable-demuxer=mov --enable-muxer=mp4 --enable-protocol=file \
  --enable-parser=hevc,aac --enable-decoder=hevc,aac > "$WORK/configure.log" 2>&1; then
  cat "$WORK/configure.log" >&2; exit 1
fi
for flag in CONFIG_GPL CONFIG_NONFREE CONFIG_VERSION3; do
  grep -q "^#define $flag 0$" config.h || { echo "Unexpected license configuration: $flag" >&2; exit 1; }
done
printf 'Building FFmpeg %s (logs: %s)\n' "$VERSION" "$WORK"
if ! make -j "$JOBS" > "$WORK/make.log" 2>&1; then tail -60 "$WORK/make.log" >&2; exit 1; fi
if ! make install > "$WORK/install.log" 2>&1; then tail -60 "$WORK/install.log" >&2; exit 1; fi
mkdir -p "$DEPS/licenses"
cp COPYING.LGPLv2.1 LICENSE.md "$DEPS/licenses/"
cp config.h "$DEPS/"
printf '%s\n' "$EXPECTED" > "$DEPS/source.sha256"
printf '%s\n' "$BUILD_KEY" > "$DEPS/build-key"
printf 'libav installed: %s\n' "$DEPS"
