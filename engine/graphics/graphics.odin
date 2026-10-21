// Generic draw primitives + render settings only.
// The app builds its own meshes in Odin and uploads them via the generic
// Register_Mesh / Append_Mesh below — this package never knows "terrain"
// exists.
//
// Scalar-in / struct-out render-FFI bindings. These only deal in floats,
// ints, plain arrays ([3]f32 / [4]f32 / []f32 / []u32), and the packed-u64
// Mesh_Handle. The shim (engine/graphics/render_shim.c) builds the
// renderer's C structs (b3Transform, Vec4, Sun, FrameInput, Mat4, MeshVertex)
// on the C side; no C struct layout crosses the FFI.
//
// Imported from the app as:  import gfx "engine:graphics"

package graphics

// ─── Enums mirrored from the renderer ─────────────────────────────────

// MeshKind (gfx/geometry_registry.h): tags a registered mesh for the edge
// overlay / debug classification. Does not affect solid drawing.
Mesh_Kind :: enum i32 {
	Unknown     = 0,
	Hull        = 1,
	Mesh        = 2,
	HeightField = 3,
}

// MeshMaterialMode (gfx/geometry_registry.h): packed into the instance
// buffer's material slot; the fragment shader branches on it.
Mesh_Material_Mode :: enum i32 {
	Solid       = 0, // MESH_MATERIAL_MODE_SOLID
	Ground_Grid = 1, // MESH_MATERIAL_MODE_GROUND_GRID
}

// TransparentShadowCast (gfx/draw_overlay.h).
Transparent_Shadow_Cast :: enum i32 {
	Full = 0, // TRANSPARENT_SHADOW_FULL
	None = 1, // TRANSPARENT_SHADOW_NONE
}

// ─── Mesh handle ──────────────────────────────────────────────────────
// A packed u64 token returned by Register_Mesh and passed back to Append_Mesh
// / Is_Mesh_Handle_Valid. Opaque to the app; the shim unpacks it to the
// renderer's MeshHandle (`{int index; uint32_t hash}`, packed as
// `index << 32 | hash`).
//
// The renderer's `IsMeshHandleValid(h)` accepts `h.index >= 0`, except the
// zero value (index 0, hash 0 — RegisterMesh asserts hash != 0, so it is
// never a real handle). The invalid sentinel MUST pack to index -1
// (0xFFFFFFFF in the high 32 bits), matching the renderer's
// `InvalidMeshHandle()` — never 0. See tests/mesh_handle/main.odin for the
// contract test.

Mesh_Handle :: distinct u64

// index = -1 (0xFFFFFFFF << 32), hash = 0. Matches renderer's
// InvalidMeshHandle() { -1, 0u } in geometry_registry.h.
Invalid_Mesh_Handle :: Mesh_Handle(0xFFFF_FFFF_0000_0000)

// ─── Foreign declarations (scalar-in / struct-out shim) ───────────────
// Add a shim foreign decl here only if it exposes a generic draw primitive /
// render setting an unrelated app would plausibly use. App-specific shapes /
// scenes / terrain formulas stay in the app (via Register_Mesh/Append_Mesh).
// The renderer fork + render_shim archive (libgraphics_<target>.a) is passed
// to the linker via -extra-linker-flags by the build scripts.

@(default_calling_convention = "c")
foreign _ {
	@(link_name = "shim_init_renderer")
	init_renderer :: proc() ---
	@(link_name = "shim_shutdown_renderer")
	shutdown_renderer :: proc() ---
	@(link_name = "shim_set_sun")
	set_sun :: proc(dx, dy, dz, r, g, b, ambient, strength: f32) ---
	@(link_name = "shim_set_sky_turbidity")
	set_sky_turbidity :: proc(t: f32) ---
	@(link_name = "shim_set_exposure")
	set_exposure :: proc(ev: f32) ---
	@(link_name = "shim_set_ibl_enabled")
	set_ibl_enabled :: proc(enabled: i32) ---
	@(link_name = "shim_set_edge_overlay")
	set_edge_overlay :: proc(enabled, show_hulls, show_meshes, show_heightfields: i32, thickness_px, z_bias, hull_r, hull_g, hull_b, hull_a: f32) ---
	@(link_name = "shim_reset_frame_arena")
	reset_frame_arena :: proc() ---

	@(link_name = "shim_append_cube")
	append_cube_raw :: proc(px, py, pz, qx, qy, qz, qw, sx, sy, sz, r, g, b, a, metallic, roughness: f32) ---

	@(link_name = "shim_append_sphere")
	append_sphere_raw :: proc(px, py, pz, qx, qy, qz, qw, radius, r, g, b, a, metallic, roughness, pattern, cap_r, cap_g, cap_b, cap_threshold: f32) ---

	@(link_name = "shim_append_capsule")
	append_capsule_raw :: proc(px, py, pz, qx, qy, qz, qw, half_length, radius, r, g, b, a, metallic, roughness: f32) ---

	// verts: vertex_count * 6 contiguous floats (position.xyz, normal.xyz).
	// indices: index_count uint32s. Returns a packed Mesh_Handle.
	@(link_name = "shim_register_mesh")
	register_mesh_raw :: proc(hash: u32, verts: ^f32, vertex_count: i32, indices: ^u32, index_count: i32, kind: i32) -> u64 ---

	@(link_name = "shim_is_mesh_handle_valid")
	is_mesh_handle_valid_raw :: proc(handle: u64) -> i32 ---

	// edges: edge_count * 8 contiguous floats (endpoint0.xyz, flag0,
	// endpoint1.xyz, flag1) per edge. Registers a hull/crease edge list the
	// edge overlay draws as outlines; without it the overlay has nothing to
	// draw for this mesh.
	@(link_name = "shim_register_mesh_edges")
	register_mesh_edges_raw :: proc(handle: u64, edges: ^f32, edge_count: i32) ---

	// Look up a live mesh by content hash (packed handle, or the invalid
	// handle = index -1 if none).
	@(link_name = "shim_find_mesh")
	find_mesh_raw :: proc(hash: u32) -> u64 ---

	// Refcount a registered mesh (paired Add/Release); the slot + its GPU
	// buffers are freed when the count reaches 0.
	@(link_name = "shim_add_mesh_reference")
	add_mesh_reference_raw :: proc(handle: u64) ---

	@(link_name = "shim_release_mesh_reference")
	release_mesh_reference_raw :: proc(handle: u64) ---

	// Total registry entry count (diagnostics; the cap is 4096).
	@(link_name = "shim_get_mesh_entry_count")
	get_mesh_entry_count_raw :: proc() -> i32 ---

	@(link_name = "shim_append_mesh")
	append_mesh_raw :: proc(handle: u64, px, py, pz, qx, qy, qz, qw, sx, sy, sz, r, g, b, a, metallic, roughness: f32, material_mode: i32, grid_cell_size: f32, shadow_cast: i32) ---

	@(link_name = "shim_render_frame_camera")
	render_frame_camera :: proc(rx, ry, rz, ux, uy, uz, fx, fy, fz, ex, ey, ez, fov, near_p, far_p, time: f32, debugMode, disableShadows, disableAO, zUp: i32) ---

	@(link_name = "shim_get_framebuffer_size")
	get_framebuffer_size :: proc(w, h: ^i32) ---

	@(link_name = "shim_get_dpi_scale")
	get_dpi_scale :: proc(s: ^f32) ---

	@(link_name = "shim_get_gpu_oom")
	get_gpu_oom :: proc() -> i32 ---
}

// ─── Convenience wrappers (PascalCase, category_method) ──────────────

Init_Renderer :: proc() {init_renderer()}
Shutdown_Renderer :: proc() {shutdown_renderer()}

Set_Sun :: proc(dir: [3]f32, color: [3]f32, ambient, strength: f32) {
	set_sun(dir[0], dir[1], dir[2], color[0], color[1], color[2], ambient, strength)
}
Set_Sky_Turbidity :: proc(t: f32) {set_sky_turbidity(t)}
Set_Exposure :: proc(ev: f32) {set_exposure(ev)}
Set_Ibl_Enabled :: proc(enabled: bool) {set_ibl_enabled(i32(enabled))}

// Configure the edge overlay (per-shape hull/mesh/heightfield outlines).
// `enabled` is the master on/off; the show_* flags select which registered
// mesh kinds get outlines. `z_bias` nudges lines toward the camera in
// reverse Z (try ~5e-5 if edges z-fight). `hull_color` is straight
// (non-premultiplied) linear RGBA for hull-kind edges, which ignore the
// per-edge convexity flag. Kinds with no registered edges (see
// Register_Mesh_Edges) draw nothing regardless of their show_* flag.
Set_Edge_Overlay :: proc(
	enabled: bool,
	show_hulls: bool = true,
	show_meshes: bool = true,
	show_heightfields: bool = true,
	thickness_px: f32 = 1.5,
	z_bias: f32 = 1.0e-6,
	hull_color: [4]f32 = {0.5, 0.5, 0.5, 0.5},
) {
	set_edge_overlay(
		i32(enabled),
		i32(show_hulls),
		i32(show_meshes),
		i32(show_heightfields),
		thickness_px,
		z_bias,
		hull_color[0],
		hull_color[1],
		hull_color[2],
		hull_color[3],
	)
}

Reset_Frame_Arena :: proc() {reset_frame_arena()}

// Append a cube instance. `scale` is the cube's full side lengths (the unit
// proxy spans [-0.5, 0.5]). `color` is linear RGB; alpha is separate (1.0 =
// opaque). metallic/roughness in [0,1].
Append_Cube :: proc(
	pos: [3]f32,
	quat: [4]f32,
	scale: [3]f32,
	color: [3]f32,
	alpha, metallic, roughness: f32,
) {
	append_cube_raw(
		pos[0],
		pos[1],
		pos[2],
		quat[0],
		quat[1],
		quat[2],
		quat[3],
		scale[0],
		scale[1],
		scale[2],
		color[0],
		color[1],
		color[2],
		alpha,
		metallic,
		roughness,
	)
}

// Append a sphere instance. `radius` is the only scale. `pattern` switches
// the impostor's great-circle surface pattern: 1.0 = rings on (spin is
// visible, the default), 0.0 = plain matte sphere.
//
// The polar cap: `cap_color` recolors the region where the surface normal's
// component along the instance's local +z axis exceeds `cap_threshold` (the
// cosine of the cap's angular radius: 1.0 = no cap (the default), 0.0 = the
// +z hemisphere, -1.0 = the whole sphere). It is a recolored region of the
// SAME material, not flat paint: the cap color replaces the base albedo
// there, and the north/south hemisphere contrast + the surface pattern apply
// over it exactly as over the base color (the rings darken the cap color
// too). Orient the instance quat so local +z points where you want the cap.
Append_Sphere :: proc(
	pos: [3]f32,
	quat: [4]f32,
	radius: f32,
	color: [3]f32,
	alpha, metallic, roughness: f32,
	pattern: f32 = 1.0,
	cap_color: [3]f32 = {},
	cap_threshold: f32 = 1.0,
) {
	append_sphere_raw(
		pos[0],
		pos[1],
		pos[2],
		quat[0],
		quat[1],
		quat[2],
		quat[3],
		radius,
		color[0],
		color[1],
		color[2],
		alpha,
		metallic,
		roughness,
		pattern,
		cap_color[0],
		cap_color[1],
		cap_color[2],
		cap_threshold,
	)
}

// Append a capsule instance. The capsule's long axis is local +X; `half_length`
// is the distance from the center to either cap center. Pass a quaternion that
// orients +X into the world (e.g. 90° about Z to stand it upright).
Append_Capsule :: proc(
	pos: [3]f32,
	quat: [4]f32,
	half_length, radius: f32,
	color: [3]f32,
	alpha, metallic, roughness: f32,
) {
	append_capsule_raw(
		pos[0],
		pos[1],
		pos[2],
		quat[0],
		quat[1],
		quat[2],
		quat[3],
		half_length,
		radius,
		color[0],
		color[1],
		color[2],
		alpha,
		metallic,
		roughness,
	)
}

// Build and register a triangle mesh once, after the renderer is initialized.
// `verts` is `len(verts)/6` vertices, laid out as position.xyz, normal.xyz per
// vertex (6 contiguous floats each). `indices` is a uint32 index list. `kind`
// tags the mesh for the edge overlay (pass .Unknown if you don't care). The
// returned Mesh_Handle is kept by the app and passed to Append_Mesh each
// frame. Registration takes one reference: hold it for as long as you draw the
// mesh and Release_Mesh_Reference it when you stop (the slot is freed at
// refcount 0). Call Find_Mesh first to avoid registering identical geometry
// twice — see Find_Mesh.
Register_Mesh :: proc(hash: u32, verts: []f32, indices: []u32, kind: Mesh_Kind) -> Mesh_Handle {
	vp := raw_data(verts)
	if len(verts) == 0 {vp = nil}
	ip := raw_data(indices)
	if len(indices) == 0 {ip = nil}
	return Mesh_Handle(
		register_mesh_raw(hash, vp, i32(len(verts) / 6), ip, i32(len(indices)), i32(kind)),
	)
}

Is_Mesh_Handle_Valid :: proc(handle: Mesh_Handle) -> bool {
	return is_mesh_handle_valid_raw(u64(handle)) != 0
}

// Upload a hull/crease edge list for a mesh registered via Register_Mesh.
// Call once, right after Register_Mesh, before the first Append_Mesh.
// `edges` is a flat []f32 with 8 floats per edge (endpoint0.xyz, flag0,
// endpoint1.xyz, flag1); `len(edges)` must be a multiple of 8, and the edge
// count is derived as `len(edges) / 8`. `flag` = 0 concave / 1 convex crease
// / 2 flat — the edge overlay FS picks convex/concave/flat color from it
// (hull-kind batches ignore it — their color comes from hull_color in
// Set_Edge_Overlay, not the per-edge flag). The edge list
// lives for the renderer's lifetime; the app may free `edges` after this.
Register_Mesh_Edges :: proc(handle: Mesh_Handle, edges: []f32) {
	ep := raw_data(edges)
	if len(edges) == 0 {ep = nil}
	register_mesh_edges_raw(u64(handle), ep, i32(len(edges) / 8))
}

// Look up a registered mesh by content hash. Returns the handle of a live
// (refcount > 0) entry with that hash, or Invalid_Mesh_Handle if none.
// Register_Mesh does NOT dedup internally — every call takes a fresh slot —
// so look up first and register only on a miss; re-registering identical
// geometry accumulates duplicate slots toward the 4096-entry cap, at which
// point registration fails and geometry silently disappears. This is the
// registry's documented Find → Register lifecycle.
Find_Mesh :: proc(hash: u32) -> Mesh_Handle {
	return Mesh_Handle(find_mesh_raw(hash))
}

// Add a reference to a registered mesh (refcount += 1). Pair with
// Release_Mesh_Reference: the mesh's GPU buffers are destroyed — and its slot
// freed for the next tenant — only when its refcount reaches 0. A mesh drawn
// by several owners takes one reference per owner; release one when an owner
// is done. No-op for Invalid_Mesh_Handle.
Add_Mesh_Reference :: proc(handle: Mesh_Handle) {
	add_mesh_reference_raw(u64(handle))
}

// Drop a reference to a registered mesh (refcount -= 1); when its count
// reaches 0 the slot and its GPU buffers are freed. No-op for
// Invalid_Mesh_Handle. Do not release a handle another owner still draws.
Release_Mesh_Reference :: proc(handle: Mesh_Handle) {
	release_mesh_reference_raw(u64(handle))
}

// Total number of registry entries (the cap is 4096; at the cap,
// registration fails and geometry silently disappears). Handy for a
// diagnostic / HUD cap-proximity readout.
Get_Mesh_Entry_Count :: proc() -> i32 {
	return get_mesh_entry_count_raw()
}

// Append one instance of a registered mesh. `offset`/`scale` transform the
// baked vertices; `material_mode` selects solid vs. the procedural ground
// grid shader (grid_cell_size only matters for the grid mode — pass 0
// otherwise); `shadow_cast` controls transparent-shadow casting.
Append_Mesh :: proc(
	handle: Mesh_Handle,
	pos: [3]f32,
	quat: [4]f32,
	scale: [3]f32,
	color: [3]f32,
	alpha, metallic, roughness: f32,
	material_mode: Mesh_Material_Mode = .Solid,
	grid_cell_size: f32 = 0.0,
	shadow_cast: Transparent_Shadow_Cast = .Full,
) {
	append_mesh_raw(
		u64(handle),
		pos[0],
		pos[1],
		pos[2],
		quat[0],
		quat[1],
		quat[2],
		quat[3],
		scale[0],
		scale[1],
		scale[2],
		color[0],
		color[1],
		color[2],
		alpha,
		metallic,
		roughness,
		i32(material_mode),
		grid_cell_size,
		i32(shadow_cast),
	)
}

// Render one frame. `right`/`up`/`forward` are the orthonormal camera basis
// (forward = pivot->eye, +view-Z; right = cross(up, forward)). `eye` is the
// camera position. `time` is the clock the renderer uses for any
// time-animated effect — pass the simulation's accumulated time (NOT the
// wall clock) so visuals stay in lockstep with the physics and the renderer
// never has to know how the sim is stepped. The shim builds the view/proj
// Mat4 pair (reverse-Z) and the FrameInput, and calls RenderFrame.
Render_Frame :: proc(
	right, up, forward, eye: [3]f32,
	fov, near_p, far_p, time: f32,
	debug_mode: i32 = 0,
	disable_shadows: bool = false,
	disable_ao: bool = false,
	z_up: bool = false,
) {
	render_frame_camera(
		right[0],
		right[1],
		right[2],
		up[0],
		up[1],
		up[2],
		forward[0],
		forward[1],
		forward[2],
		eye[0],
		eye[1],
		eye[2],
		fov,
		near_p,
		far_p,
		time,
		debug_mode,
		i32(disable_shadows),
		i32(disable_ao),
		i32(z_up),
	)
}

Framebuffer_Size :: proc() -> (w, h: i32) {
	w, h = 0, 0
	get_framebuffer_size(&w, &h)
	return
}

// Device pixel ratio (framebuffer px per logical px); 1.0 on unscaled
// displays and before the window is up. UIs that draw in framebuffer
// pixels scale their layout by this to stay the same physical size.
Dpi_Scale :: proc() -> f32 {
	s: f32 = 0.0
	get_dpi_scale(&s)
	return s
}

// 1 once the GL context reported an out-of-memory error — usually a window
// resize whose new render targets didn't fit in the remaining VRAM. Latched
// for the process lifetime: the failed targets are unusable and a restart is
// the only recovery, so an app surfaces this (banner / error) instead of
// leaving a frozen window. Always false on non-GL backends (WebGPU reports
// exhaustion as device-lost, a different path).
Gpu_Oom :: proc() -> bool {
	return get_gpu_oom() != 0
}

// ─── 2D overlay (sokol_gl) ───────────────────────────────────────────
// Generic 2D + text overlay for HUDs and immediate-mode UI (microui).
// The app accumulates draw commands (rects, textured quads, clips) via
// these procs; Render_Frame flushes them after the scene. Separation test:
// any app with a HUD wants this. The app owns UI logic and atlas glyph
// lookup; this provides the generic 2D draw surface.

@(default_calling_convention = "c")
foreign _ {
	@(link_name = "shim_overlay_init")
	overlay_init :: proc() ---
	@(link_name = "shim_overlay_shutdown")
	overlay_shutdown :: proc() ---
	@(link_name = "shim_overlay_upload_atlas")
	overlay_upload_atlas_raw :: proc(w, h: i32, rgba: ^u8) ---
	@(link_name = "shim_overlay_upload_icons")
	overlay_upload_icons_raw :: proc(w, h: i32, rgba: ^u8) ---
	@(link_name = "shim_overlay_begin")
	overlay_begin_raw :: proc(fb_w, fb_h: i32) ---
	@(link_name = "shim_overlay_rect")
	overlay_rect_raw :: proc(x, y, w, h, r, g, b, a: f32) ---
	@(link_name = "shim_overlay_textured_quad")
	overlay_textured_quad_raw :: proc(x, y, w, h, u0, v0, u1, v1, r, g, b, a: f32) ---
	@(link_name = "shim_overlay_textured_quad_rot")
	overlay_textured_quad_rot_raw :: proc(cx, cy, w, h, angle, u0, v0, u1, v1, r, g, b, a: f32) ---
	@(link_name = "shim_overlay_set_sdf")
	overlay_set_sdf_raw :: proc(r, g, b, a, outline_w, spread: f32) ---
	@(link_name = "shim_overlay_sdf_quad")
	overlay_sdf_quad_raw :: proc(x, y, w, h, u0, v0, u1, v1, r, g, b, a: f32) ---
	@(link_name = "shim_overlay_clip")
	overlay_clip_raw :: proc(x, y, w, h: i32) ---
	@(link_name = "shim_overlay_noclip")
	overlay_noclip :: proc() ---
	@(link_name = "shim_overlay_end")
	overlay_end :: proc() ---
}

Overlay_Init :: proc() {overlay_init()}
Overlay_Shutdown :: proc() {overlay_shutdown()}

// Upload a font/icon atlas as RGBA8. The app converts the baked 1-byte/px
// atlas (alpha or SDF value) to RGBA (the value in every channel) before
// calling.
Overlay_Upload_Atlas :: proc(w, h: i32, rgba: []u8) {
	overlay_upload_atlas_raw(w, h, raw_data(rgba))
}

// Upload (or re-upload) the second overlay texture — the app's icon atlas.
// RGBA8, whole-image each call.
Overlay_Upload_Icons :: proc(w, h: i32, rgba: []u8) {
	overlay_upload_icons_raw(w, h, raw_data(rgba))
}

// Begin an overlay frame: ortho projection, full viewport.
Overlay_Begin :: proc(fb_w, fb_h: i32) {overlay_begin_raw(fb_w, fb_h)}

// Draw a filled colored rect.
Overlay_Rect :: proc(x, y, w, h: f32, color: [4]f32) {
	overlay_rect_raw(x, y, w, h, color[0], color[1], color[2], color[3])
}

// Draw a textured quad (atlas region) with color modulation (plain alpha).
Overlay_Textured_Quad :: proc(x, y, w, h, u0, v0, u1, v1: f32, color: [4]f32) {
	overlay_textured_quad_raw(x, y, w, h, u0, v0, u1, v1, color[0], color[1], color[2], color[3])
}

// Set the SDF text parameters: outline color (straight 0..1) plus outline
// width and field spread in DESIGN px. Applied to every subsequent
// Overlay_Sdf_Quad.
Overlay_Set_Sdf :: proc(r, g, b, a, outline_w, spread: f32) {
	overlay_set_sdf_raw(r, g, b, a, outline_w, spread)
}

// Draw one SDF glyph quad: the engine's SDF pipeline thresholds the font
// atlas's distance field with fwidth antialiasing and draws the outline
// band. x/y/w/h are framebuffer px (top-left origin), the uvs bound the
// glyph's field region (ink + spread), color is the ink (straight 0..1).
// No-op before the first Overlay_Upload_Atlas.
Overlay_Sdf_Quad :: proc(x, y, w, h, u0, v0, u1, v1: f32, color: [4]f32) {
	overlay_sdf_quad_raw(x, y, w, h, u0, v0, u1, v1, color[0], color[1], color[2], color[3])
}

// Draw a textured quad from the icon atlas (the second overlay texture),
// rotated about its center by `angle` radians (positive = the quad's right
// edge tilts up, a sprite's "nose up"), with color modulation. No-op before
// the first Overlay_Upload_Icons.
Overlay_Textured_Quad_Rot :: proc(cx, cy, w, h, angle: f32, u0, v0, u1, v1: f32, color: [4]f32) {
	overlay_textured_quad_rot_raw(
		cx,
		cy,
		w,
		h,
		angle,
		u0,
		v0,
		u1,
		v1,
		color[0],
		color[1],
		color[2],
		color[3],
	)
}

// Set scissor clip rect (origin top-left, Y down).
Overlay_Clip :: proc(x, y, w, h: i32) {overlay_clip_raw(x, y, w, h)}

// Mark overlay commands ready — flushed by the next Render_Frame.
Overlay_End :: proc() {overlay_end()}
