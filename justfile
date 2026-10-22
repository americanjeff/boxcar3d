# System requirements:
#   native:  just, odin, gcc (C17), and the X11 + GL dev headers
#            the windowing shim links against (Debian/Ubuntu: libx11-dev
#            libxi-dev libxcursor-dev libgl1-mesa-dev).
#   fresh checkout: sokol-shdc on PATH - the generated shader headers are
#            gitignored (they embed absolute paths), so the first build
#            regenerates them. Prebuilt from floooh/sokol-tools-bin
#            (bin/<platform>/sokol-shdc), or build from floooh/sokol-tools.
#   wasm:    clang with a wasm32 target (any LLVM 16+).
#   deploy:  wrangler + Cloudflare auth (`wrangler login` once).
#   optional: python3 - re-baking the font atlas (apps/<app>/tools/bake_font.py)
#            and `python3 -m http.server` when serving a wasm build locally.
#   No version pins: rolling Odin dev (known good: dev-2026-10).
#
# App recipes take an optional [app]; without one they use the current
# directory (must be inside apps/<name>/). Native is the default target,
# `full` forces a clean app rebuild. The no-arg `default` and the
# intermediate steps (build/publish/engine/clean) are [private]: hidden
# from the list, still runnable by name.

set positional-arguments

[private]
default:
    @echo "  run [app] [full] [args...]  build (native) + run the app binary"
    @echo "  wasm [app]                   build the wasm output"
    @echo "  deploy [app]                 build wasm, stage, upload to Cloudflare Pages"

# `full` clears the app's build/<target> first - use it when Odin's
# incremental cache may have left a stale binary.
[private]
build app="" target="native" full="no":
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="{{ justfile_directory() }}"
    INV="{{ invocation_directory() }}"
    APP="{{ app }}"
    TGT="{{ target }}"
    if [ -z "$APP" ]; then
        case "$INV" in
            "$ROOT"/apps/*) APP="${INV#"$ROOT"/apps/}"; APP="${APP%%/*}" ;;
            *) echo "Error: not inside apps/<name>/ (cwd=$INV). Pass an app name: just build <app> [target]" >&2; exit 1 ;;
        esac
    fi
    [ -d "$ROOT/apps/$APP" ] || { echo "Error: app '$APP' not found ($ROOT/apps/$APP)" >&2; exit 1; }
    case "$TGT" in native|wasm) ;; *) echo "Error: target must be native or wasm (got '$TGT')" >&2; exit 1 ;; esac

    ENGLIB="$ROOT/engine/lib"
    # ML archives are per-app: the app's project.env may set ML_LIBS to a
    # space-separated subset of "kann cmaes neat"; unset = all three.
    # No colon in ${ML_LIBS-...}: an empty-but-set ML_LIBS means "no ML
    # libs" for this app; the default applies only when project.env omits it.
    ML_LIBS="$( . "$ROOT/apps/$APP/project.env" && printf '%s' "${ML_LIBS-kann cmaes neat}" )"
    # shellcheck disable=SC2086  # intentional word-splitting of the lib list
    archs=(physics graphics $ML_LIBS)
    need=0
    for a in "${archs[@]}"; do
        [ -f "$ENGLIB/lib${a}_${TGT}.a" ] || { need=1; break; }
    done
    if [ "$need" -eq 0 ]; then
        # sort-then-tail (not sort|head): `sort` streams its full output after
        # reading all input; `head -1` exits after one line → SIGPIPE to `sort`
        # → under `pipefail`+`set -e` that becomes fatal exit 141 before the
        # build even runs. `tail -1` drains the pipe so `sort` exits cleanly.
        newest=$(find "$ROOT/engine" "$ROOT/vendor" -type f \( -name '*.c' -o -name '*.h' \) \
            -not -path "$ROOT/engine/lib/*" \
            -not -path "$ROOT/vendor/box3d/build_native/*" \
            -not -path "$ROOT/vendor/box3d/build_wasm/*" \
            -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
        oldest=$(for a in "${archs[@]}"; do stat -c %Y "$ENGLIB/lib${a}_${TGT}.a"; done | sort -rn | tail -1)
        if [ -n "$newest" ] && [ "${newest%.*}" -gt "$oldest" ]; then need=1; fi
    fi

    if [ "$need" -eq 1 ]; then
        echo "── engine/vendor sources newer than archives (or an archive is missing) - rebuilding engine ($TGT) ──"
        ML_LIBS="$ML_LIBS" "$ROOT/tools/build_engine.sh" "$TGT"
    else
        echo "── engine archives up to date ($TGT) - skipping engine ──"
    fi
    if [ "{{ full }}" = "full" ] || [ "{{ full }}" = "yes" ] || [ "{{ full }}" = "1" ] || [ "{{ full }}" = "clean" ]; then
        rm -rf "$ROOT/apps/$APP/build/$TGT"
        echo "── full rebuild: cleared $ROOT/apps/$APP/build/$TGT ──"
    fi
    "$ROOT/tools/build_app.sh" "$TGT" "$APP"

# Leading args may name an existing app and/or `full` (clean rebuild), in
# any order; all other args go to the binary unchanged. Without [app], the
# current directory must be apps/<name>/.
# just run [app] [full] [args...] - build (native, engine gated) and exec.
run *args:
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="{{ justfile_directory() }}"
    INV="{{ invocation_directory() }}"
    APP=""
    FULL="no"
    while [ $# -gt 0 ]; do
        case "$1" in
            full) FULL="full"; shift ;;
            *) if [ -z "$APP" ] && [ -d "$ROOT/apps/$1" ]; then APP="$1"; shift; else break; fi ;;
        esac
    done
    if [ -z "$APP" ]; then
        case "$INV" in
            "$ROOT"/apps/*) APP="${INV#"$ROOT"/apps/}"; APP="${APP%%/*}" ;;
            *) echo "Error: pass an app name or invoke from inside apps/<name>/ (cwd=$INV)" >&2; exit 1 ;;
        esac
    fi
    [ -d "$ROOT/apps/$APP" ] || { echo "Error: app '$APP' not found" >&2; exit 1; }
    just build "$APP" native "$FULL"
    # shellcheck source=/dev/null
    . "$ROOT/apps/$APP/project.env"
    exec "$ROOT/apps/$APP/build/native/$APP" "$@"

# `just build` already calls this when sources are stale; run it to force
# a rebuild after deleting archives or to bypass the gate.
[private]
engine target="native":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ target }}" in native|wasm) ;; *) echo "Error: target must be native or wasm" >&2; exit 1 ;; esac
    "{{ justfile_directory() }}/tools/build_engine.sh" "{{ target }}"

# Remove an app's build/<target> output (native default): equivalent to
# `just build <app> <target> full`, without the rebuild.
[private]
clean app="" target="native":
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="{{ justfile_directory() }}"
    INV="{{ invocation_directory() }}"
    APP="{{ app }}"
    TGT="{{ target }}"
    if [ -z "$APP" ]; then
        case "$INV" in
            "$ROOT"/apps/*) APP="${INV#"$ROOT"/apps/}"; APP="${APP%%/*}" ;;
            *) echo "Error: not inside apps/<name>/ (cwd=$INV). Pass an app name: just clean <app> [target]" >&2; exit 1 ;;
        esac
    fi
    [ -d "$ROOT/apps/$APP" ] || { echo "Error: app '$APP' not found ($ROOT/apps/$APP)" >&2; exit 1; }
    case "$TGT" in native|wasm) ;; *) echo "Error: target must be native or wasm (got '$TGT')" >&2; exit 1 ;; esac
    rm -rf "$ROOT/apps/$APP/build/$TGT"
    echo "── clean: removed $ROOT/apps/$APP/build/$TGT ──"

# Produces apps/<app>/build/wasm/ - index.html is the single entry, whose
# boot script picks the WebGPU glue (index.js/index.wasm) or the WebGL2
# fallback (index-gles.js/index-gles.wasm) per browser. The dev dir also
# keeps probe pages and capture media for local testing; `just publish`
# stages the clean copy (deploy adds the upload).
# just wasm [app] - build the wasm output for one app.
wasm app="":
    #!/usr/bin/env bash
    set -euo pipefail
    just build "{{ app }}" wasm

# Stages only the publishable files into apps/<app>/build/web/ - standalone,
# push as-is (no probe pages, no dev media). Re-stages from scratch every
# run, so it can never hold a stale extra.
[private]
publish app="":
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="{{ justfile_directory() }}"
    INV="{{ invocation_directory() }}"
    APP="{{ app }}"
    if [ -z "$APP" ]; then
        case "$INV" in
            "$ROOT"/apps/*) APP="${INV#"$ROOT"/apps/}"; APP="${APP%%/*}" ;;
            *) echo "Error: not inside apps/<name>/ (cwd=$INV). Pass an app name: just publish <app>" >&2; exit 1 ;;
        esac
    fi
    [ -d "$ROOT/apps/$APP" ] || { echo "Error: app '$APP' not found ($ROOT/apps/$APP)" >&2; exit 1; }
    just build "$APP" wasm
    "$ROOT/tools/publish_web.sh" "$APP"

# The first run creates the Cloudflare Pages project named after the app;
# re-deploys replace the site, and the staged _headers file keeps the
# unversioned js/wasm from going stale in browsers between deploys.
# just deploy [app] - publish, then upload to Cloudflare Pages.
deploy app="":
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="{{ justfile_directory() }}"
    INV="{{ invocation_directory() }}"
    APP="{{ app }}"
    if [ -z "$APP" ]; then
        case "$INV" in
            "$ROOT"/apps/*) APP="${INV#"$ROOT"/apps/}"; APP="${APP%%/*}" ;;
            *) echo "Error: 'just deploy' must be invoked from inside apps/<name>/. Pass an app name: just deploy <app>" >&2; exit 1 ;;
        esac
    fi
    [ -d "$ROOT/apps/$APP" ] || { echo "Error: app '$APP' not found ($ROOT/apps/$APP)" >&2; exit 1; }
    just publish "$APP"
    DIR="$ROOT/apps/$APP/build/web"
    # --branch main: jj's git shim reports a workspace-derived branch name, so
    # pin the production branch explicitly (projects are created with
    # --production-branch main below) - otherwise deploys land on a branch
    # alias instead of <project>.pages.dev.
    OUT="$(wrangler pages deploy "$DIR" --project-name "$APP" --branch main --commit-dirty=true 2>&1)" \
        && { printf '%s\n' "$OUT"; exit 0; }
    printf '%s\n' "$OUT"
    # Only a genuinely missing project gets auto-created - any other failure
    # (auth, rate limit, network) is reported as-is, not retried.
    grep -q 'does not exist' <<<"$OUT" || {
        echo "Error: wrangler pages deploy failed - see output above (auth errors: check 'wrangler whoami' and any CLOUDFLARE_API_TOKEN in your environment)" >&2
        exit 1
    }
    echo "── Cloudflare Pages project '$APP' not found - creating it ──"
    wrangler pages project create "$APP" --production-branch main
    wrangler pages deploy "$DIR" --project-name "$APP" --branch main --commit-dirty=true
