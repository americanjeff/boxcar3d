#!/usr/bin/env bash
# Convenience: build the engine for both targets, then one app for both targets.
#   ./tools/build.sh <app>      # build_engine native+wasm, then build_app native+wasm <app>
#   ./tools/build.sh <app> native   # engine native + app native only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: build.sh <app> [native|wasm]}"
TARGET="${2:-both}"

build_one() {
	local t="$1"
	"$ROOT/tools/build_engine.sh" "$t"
	"$ROOT/tools/build_app.sh" "$t" "$APP"
}

case "$TARGET" in
	both)   build_one native; build_one wasm ;;
	native) build_one native ;;
	wasm)   build_one wasm ;;
	*) echo "usage: build.sh <app> [native|wasm|both]" >&2; exit 1 ;;
esac