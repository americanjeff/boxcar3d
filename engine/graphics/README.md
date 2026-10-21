# engine/graphics — PBR renderer + scalar FFI bindings

A GPU-accelerated physically-based renderer, exposed to Odin through a
small scalar-in / struct-out FFI.

## Layout

- `graphics.odin` — the `graphics:` Odin package. Foreign declarations for the
  C shim plus PascalCase convenience wrappers (`Append_Cube`, `Append_Sphere`,
  `Append_Capsule`, `Register_Mesh`, `Append_Mesh`, `Render_Frame`, `Set_Sun`,
  …) that deal only in scalars, `[3]f32`/`[4]f32` arrays, slices, and a packed
  `u64` `Mesh_Handle`. No C struct layout crosses the FFI.
- `render_shim.c` — the C-side shim. Builds the renderer's structs
  (`b3Transform`, `Vec4`, `Sun`, `FrameInput`, `Mat4`, `MeshVertex`) from the
  scalars Odin passes, owns the view/projection math, and calls the renderer.
- `renderer/gfx/` — the forked renderer itself (see **Attribution** below).
- `renderer/shaders/` — the generated GLSL shader headers consumed by
  `renderer/gfx/`.

## Features

The renderer provides a modern forward/deferred-ish PBR pipeline:

- **PBR shapes** — instanced cube / sphere / capsule proxies and a generic
  triangle-mesh upload path, fed by a ref-counted GPU **geometry registry**.
- **Image-based lighting** (IBL) — diffuse spherical harmonics + prefiltered
  specular, generated from the procedural sky.
- **Procedural Preetham sky** with adjustable turbidity.
- **Cascaded shadow maps** (CSM) for the directional sun.
- **Ground-truth ambient occlusion** (GTAO) via a depth pre-pass, trace, and
  upsample.
- **AgX tone mapping** with an exposure stop and a saturation knob.
- **Edge overlay** — per-shape silhouette edges for hulls, meshes, and
  heightfields, with separate opaque (MSAA) and post-transparent submission
  paths.
- **Highlight outlines / masks** — hover and select silhouette styles for
  picking feedback.
- **Text labels** — world- and screen-space label storage projected through
  the last rendered camera.
- **Debug render modes** — view-space depth, CSM cascade index, view-space
  normals, raw GTAO.
- A relative-render-frame **draw origin** world wrap keeps float coordinates
  small at planetary distances.

Apps drive it through a tiny, stateless API: append instances per frame into
a per-frame arena, then call `Render_Frame` with the camera basis; the shim
fills the projection and own the commit.

See `docs/FFI_WASM.md` for the scalar-FFI and ownership invariants the shim
maintains.

## Attribution

The renderer in `renderer/gfx/` and the generated shaders in
`renderer/shaders/` are forked from the Box3D sample renderer.

Original source:

- Repository: <https://github.com/erincatto/box3d>
- Sample renderer: [`samples/gfx/`](https://github.com/erincatto/box3d/tree/main/samples/gfx)
- Sample shaders: [`samples/shaders/`](https://github.com/erincatto/box3d/tree/main/samples/shaders)

`render_shim.c` and `graphics.odin` are local additions.
