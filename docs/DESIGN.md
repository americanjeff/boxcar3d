# Design notes

This repo is one app (`apps/boxcar3d/`) plus the shared engine it is built
on (`engine/`), the build tooling (`tools/`), and the pinned third-party C
it links (`vendor/`). Everything builds for two targets from the same
sources: native Linux (OpenGL 4.5) and wasm (WebGPU, with a WebGL2
fallback).

This doc is the set of **policy decisions** that shaped the layout. The
FFI invariants themselves are in [FFI_WASM.md](FFI_WASM.md).

## The engine/app split

The boundary rule is a test of *kind*, not of usage:

> **Would an unrelated app plausibly want this?** If yes, it belongs in
> `engine/`. If it is specific to one app's game, it belongs in that app.

`engine/` therefore holds only generic capability — physics, the PBR
renderer, and the window/app host — and never game content. A shape specific to a game is generated in the app through the
engine's `register_mesh`/`append_mesh` API, not added to the engine. A
primitive used by one app today still belongs in the engine if it is
generic; a mesh used by every app still belongs in the app if it is game
content.

The practical consequence: the app directory is replaceable. Everything
the app needs from the shared world is expressed against the `engine:`
packages (`physics`, `graphics`, `apphost`) through scalar-FFI
bindings.

## The FFI boundary

Only scalars, plain arrays, opaque pointers, and function pointers cross
the Odin/C boundary; the C shim builds the C struct. The type system does
not enforce the rest. The three invariants — scalar-in/struct-out,
matching ownership/lifetime/sentinels, and build + test on both targets —
each have a *silent* failure mode. They, and the dual-target build
policy, are in [FFI_WASM.md](FFI_WASM.md); read that before touching a
shim.

## Dual-target build

- Two stages: `tools/build_engine.sh` compiles the shared C once into
  `engine/lib/*_<target>.a`; apps link the archives
  (`tools/build_app.sh`). The `just` wrapper rebuilds the engine only
  when a C source is newer than the archives.
- **A clean native build is not a sufficient check.** The
  `SOKOL_WGPU`-guarded code only compiles on wasm, so every engine change
  must build native *and* wasm: `tools/test.sh` for the native e2e,
  `just build <app> wasm` for the browser target.
- The wasm build links the same Odin object into **two** variants —
  WebGPU and WebGL2 — because sokol's backend is a compile-time macro.
  The single web entry (`index.html`) probes the browser at boot and
  loads the matching glue as an external script, so a shared link runs
  the best available backend on the recipient's machine.
- **WebGL2 policy:** ESSL 3.00 has neither compute shaders nor SSBOs.
  The fallback ships with the unsupported features **gated off** (the
  GTAO chain, for example) rather than half-ported. Porting a feature to
  WebGL2 is a deliberate, separate change.

## Upstream changes

Local edits to vendor code are marked `FORK (wasm/WGPU)`: two tracked
patches against `vendor/sokol` (`tools/patches/`, re-applied by
`vendor_sokol.sh`), plus shader edits in `vendor/box3d/samples/shaders/`.
`engine/graphics/renderer` is a forked, owned copy of the Box3D sample
renderer, edited in place.

## WebGPU / WebGL2: the silent-failure class

The browser target does not error; it renders wrong. Every workaround
carries a `FORK (wasm/WGPU)` marker at the fix site — in-tree comments,
or a header in `tools/patches/` for the two sokol edits. No runtime test
covers these paths (native is OpenGL; the wasm build is compile-only), so
a browser change is verified by running the wasm, not by a test.

## How to verify

- `boxcar3d smoke` — headless sim battery: terrain profile, evolution
  determinism, controller rollouts.
- `boxcar3d evalone <genome>` — one deterministic rollout; must print
  identical numbers every run.
- `tools/test.sh` — native e2e: mesh-handle sentinel, refcount
  lifecycle, physics destroy order.
- `just build <app> wasm` — browser target; the only build that compiles
  the SOKOL_WGPU-guarded paths.
