#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT/scripts/build-libav.sh" "$@"
"$ROOT/scripts/build-app.sh"
