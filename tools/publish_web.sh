#!/usr/bin/env bash
# Stage a clean, pushable web copy of one app's wasm build.
#
#   tools/publish_web.sh <app>
#
# Copies ONLY the files the web entry needs (REQUIRED below) + the about page
# (the entry's ? button; the app's own apps/<app>/web/about.html or the
# shared default) from apps/<app>/build/wasm/ into apps/<app>/build/web/ —
# a standalone directory that can be pushed to a site as-is. The dev dir
# (build/wasm/) keeps its probe pages, capture videos, and local server
# script; none of that ships.
#
# `just build <app> wasm` must have run first (`just publish <app>` does
# both). The stage is rebuilt from scratch on every run (rm -rf + copy), so
# it can never accumulate a stale extra file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR_NAME="${1:?usage: publish_web.sh <app>}"
APP_ROOT="$ROOT/apps/$APP_DIR_NAME"

[ -d "$APP_ROOT" ] || { echo "Error: app $APP_DIR_NAME not found ($APP_ROOT)" >&2; exit 1; }
# shellcheck source=/dev/null
. "$APP_ROOT/project.env"

SRC="$APP_ROOT/build/wasm"
OUT="$APP_ROOT/build/web"

# The publishable set, in one place: the single web entry (generated from
# tools/web/index_template.html by build_app.sh) + the Odin JS runtime + the
# two backend glue/wasm pairs. If the template ever references a new HTML
# asset, add it here — the reference check below then enforces it ships.
REQUIRED=(index.html odin.js index.js index.wasm index-gles.js index-gles.wasm vendor/qrcode-generator.js)

if [ ! -d "$SRC" ]; then
	echo "Error: $SRC is missing — run 'just build $APP_DIR_NAME wasm' first" >&2
	exit 1
fi
missing=0
for f in "${REQUIRED[@]}"; do
	[ -f "$SRC/$f" ] || { echo "Error: $SRC/$f is missing — run 'just build $APP_DIR_NAME wasm'" >&2; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1

rm -rf "$OUT"
mkdir -p "$OUT"
for f in "${REQUIRED[@]}"; do
	mkdir -p "$OUT/$(dirname "$f")"
	cp -f "$SRC/$f" "$OUT/$f"
done

# The entry's About button (index_template.html) links to about.html, hosted
# alongside the entry: the app's own apps/<app>/web/about.html when present,
# else the shared default. Any other file under apps/<app>/web/ (e.g. images
# the about page references) ships too.
WEB_DIR="$APP_ROOT/web"
EXTRA=()
if [ -d "$WEB_DIR" ] && [ -n "$(ls -A "$WEB_DIR")" ]; then
	for f in "$WEB_DIR"/* "$WEB_DIR"/.[!.]* "$WEB_DIR"/..?*; do
		[ -e "$f" ] || continue
		cp -rf "$f" "$OUT/$(basename "$f")"
		EXTRA+=("$(basename "$f")")
	done
fi
[ -f "$OUT/about.html" ] || { cp -f "$ROOT/tools/web/about_default.html" "$OUT/about.html"; EXTRA+=("about.html"); }

# Cloudflare Pages reads _* files as config, not content. The assets ship
# unversioned (index.wasm is rebuilt in place on every publish), so without
# this a browser would keep using a stale wasm next to a fresh js for up to 4
# hours after a deploy (Pages' default max-age). no-cache = conditional
# revalidation by ETag: one cheap check per load, and every publish lands
# immediately.
cat > "$OUT/_headers" <<'EOF'
*.js
Cache-Control: no-cache

*.wasm
Cache-Control: no-cache
EOF
EXTRA+=("_headers")

# Guard 1: every local asset index.html references must exist in the staged
# dir (catches a template that gained a <script src>/<link href> with no
# matching REQUIRED/EXTRA entry → a 404 on the site).
referenced="$(grep -oE '(src|href)="[^"]+"' "$OUT/index.html" \
	| sed -E 's/^(src|href)="//; s/"$//' \
	| grep -vE '^(https?:|data:|#|mailto:)' || true)"
for ref in $referenced; do
	[ -f "$OUT/$ref" ] || { echo "Error: index.html references '$ref' but it is not staged" >&2; exit 1; }
done

# Guard 2: the staged dir contains exactly the publishable set (base + the
# app's web content) — nothing more. A top-level entry passes when it is in
# the list, or is a parent directory of a listed (nested) path.
for f in "$OUT"/* "$OUT"/.[!.]* "$OUT"/..?*; do
	[ -e "$f" ] || continue
	b="$(basename "$f")"
	ok=0
	for want in "${REQUIRED[@]}" ${EXTRA[@]+"${EXTRA[@]}"}; do
		if [ "$b" = "$want" ] || [ "${want#"$b"/}" != "$want" ]; then ok=1; break; fi
	done
	[ "$ok" -eq 1 ] || { echo "Error: unexpected file in $OUT: $b" >&2; exit 1; }
done

echo ""
echo "✓ Web publish staged: $OUT/ ($((${#REQUIRED[@]} + ${#EXTRA[@]})) files, exactly the publishable set)"
for f in "${REQUIRED[@]}" ${EXTRA[@]+"${EXTRA[@]}"}; do
	du -h "$OUT/$f" | awk -v f="$f" '{printf "  %-16s %s\n", f, $1}'
done
echo "  Push this directory to a site as-is (rsync -a $OUT/ <host>:<site>/),"
echo "  or deploy it to Cloudflare Pages with 'just deploy $APP_DIR_NAME'."
