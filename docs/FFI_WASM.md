# FFI & WASM invariants for shim wrappers

The shared C shims (`engine/{graphics,apphost}/*_shim.c`) and their Odin
bindings are the scalar boundary between Odin and the vendored C (Sokol).
Physics has no C shim: `physics:` maps the engine's scalar API onto the
Odin toolchain's `vendor:box3d` bindings. Adding or changing a wrapper there
must hold the three invariants below. They are correctness rules, not style —
each has a silent failure mode (builds native but breaks wasm, or works until
teardown, or a sentinel that collides with a valid handle).

## 1. Scalar-in / struct-out

Only floats, ints, plain arrays, opaque pointers, and function pointers
cross the FFI; the shim builds the C structs (`Vec4`, `Sun`, `FrameInput`,
`Mat4`, `MeshVertex`) on the C side — no C struct layout or by-value struct
ABI crosses. One sanctioned exception: `physics:` passes the small Box3D ID
structs (`b3WorldId`/`b3BodyId`/`b3ShapeId`/`b3JointId`, ≤4 words) by value,
matching `vendor:box3d`'s binding style; the Odin-facing types are the ID
structs (compare via `==`, zero = null), packed to `u64` only where the API
exposes a packed form.

*Why:* a by-value C struct builds and runs native but breaks wasm. This
invariant is what makes the dual build tractable. (The ID-struct exception is
the same shape on both targets — verified on native and wasm — because it
mirrors the toolchain binding's own FFI, not a repo-defined one.)

## 2. Match the C side's ownership, lifetime, and invalid sentinels

When a wrapper hands a C object to Box3D or the renderer, know whether the
callee **clones** it or **holds the pointer**, and make the Odin-side
lifecycle match.

- `b3CreateHeightFieldShape` stores the `b3HeightFieldData*` by pointer (no
  clone), so the heightfield must outlive the world's shape — destroy the
  world before the heightfield (`DestroyWorld` before `DestroyHeightField`).
- Any "invalid" sentinel the Odin binding defines must pack to the same
  invalid value the C side defines: `Invalid_Mesh_Handle` must be index −1,
  matching the renderer's `InvalidMeshHandle()`, not index 0 (a valid first
  slot).

*Why:* the shim hides struct layout (and `physics:`'s def handles are opaque
pointers to toolchain-struct allocations), so these invariants don't enforce
themselves — the type system won't catch a mismatched lifetime or a sentinel
that collides with a valid handle.

## 3. Build + test on both targets

Every engine change must build native *and* wasm; `SOKOL_WGPU`-guarded code
only compiles on wasm, so a clean native build is not a sufficient check. Run
`tools/test.sh` (native e2e) and `tools/build_app.sh wasm <app>` before an
engine change is done.
