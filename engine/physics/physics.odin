// Generic physics capability only.
//
// `physics:` is the Box3D binding for Odin. It is shaped to match the
// upstream `vendor:box3d` C API surface (PascalCase names, ID structs with
// the same fields, same enum values, by-value `[3]f32` / `[4]f32` returns
// where Box3D returns a `b3Vec3` / `b3Quat`) so a future swap to
// `import b3 "vendor:box3d"` is a near-no-op.
//
// The FFI itself stays scalar: the shim (engine/physics/physics_shim.c)
// packs `b3WorldId`/`b3BodyId`/`b3ShapeId`/`b3JointId` into `u64`, and these
// bindings pack/unpack at the boundary. So the *Odin-facing* types are the
// unpacked ID structs (matching `vendor:box3d`) while the *FFI* is packed
// `u64` (the scalar invariant). Both properties hold simultaneously.
//
// The one place this package does NOT match `vendor:box3d` is the def/hull
// constructors and setters. `vendor:box3d` has you fill a `b3WorldDef`/
// `b3BodyDef`/`b3ShapeDef`/`b3BoxHull`/`b3Sphere`/`b3Capsule` struct by value
// and pass it to the create call; here those structs are shim-owned C
// allocations exposed as opaque `distinct rawptr` handles (they have no
// `vendor:box3d` analogue), because the scalar FFI must not let C struct
// layout cross the boundary. The `Default*Def` / `*Def_Set*` / `Free*Def` /
// `Make*` / `Free*` / `Destroy*` procs below are the surface to change when
// swapping to `vendor:box3d` (you would fill the structs by value instead).
// This is confined to the def/hull constructors and setters; everything
// else (IDs, create/step/getters/runtime setters/joints) matches.

package physics

import "core:math"

// ─── Body type (mirrors b3BodyType) ───────────────────────────────────

Body_Type :: enum i32 {
	Static    = 0,
	Kinematic = 1,
	Dynamic   = 2,
}

// ─── Log sink (mirrors the shim's mode toggle) ─────────────────────────
// Box3D's b3Log routes solver ("unstable: ...") and CCD ("CCD stall: ...")
// diagnostics through a single handler.

Log_Sink :: enum i32 {
	Default = 0, // Box3D default: "Box3D: <msg>" to stdout
	Silent  = 1, // no-op (suppress the solver/CCD diagnostic flood)
}

// ─── IDs (mirrors b3WorldId / b3BodyId / b3ShapeId / b3JointId) ────────
// Same fields as the C structs. The bindings pack/unpack to `u64` at the
// FFI; Odin code treats these as opaque value types (compare via ==, zero =
// null). Do not read the fields — they are upstream's internal encoding.

WorldId :: struct {
	index1:     u16,
	generation: u16,
}

BodyId :: struct {
	index1:     i32,
	world0:     u16,
	generation: u16,
}

ShapeId :: struct {
	index1:     i32,
	world0:     u16,
	generation: u16,
}

JointId :: struct {
	index1:     i32,
	world0:     u16,
	generation: u16,
}

// ─── Opaque def/hull handles (shim-owned C allocations) ───────────────
// These are the shim's opaque pointers, not by-value structs (the one
// place this package does not match `vendor:box3d`). See the file header.

WorldDef :: distinct rawptr
BodyDef :: distinct rawptr
ShapeDef :: distinct rawptr
BoxHull :: distinct rawptr
Sphere :: distinct rawptr
Capsule :: distinct rawptr
HeightField :: distinct rawptr
Hull :: distinct rawptr

// ─── ID pack/unpack (FFI is packed u64) ───────────────────────────────

@(private)
pack_world :: proc(id: WorldId) -> u64 {
	return (u64(id.index1) << 16) | u64(id.generation)
}

@(private)
unpack_world :: proc(v: u64) -> WorldId {
	return {u16(v >> 16), u16(v)}
}

@(private)
pack_body :: proc(id: BodyId) -> u64 {
	return (u64(u32(id.index1)) << 32) | (u64(id.world0) << 16) | u64(id.generation)
}

@(private)
unpack_body :: proc(v: u64) -> BodyId {
	return {i32(v >> 32), u16(v >> 16), u16(v)}
}

// ShapeId has the same layout as BodyId; unpack through BodyId then rebuild a
// ShapeId (nominally distinct, no implicit conversion).
@(private)
unpack_shape :: proc(v: u64) -> ShapeId {
	b := unpack_body(v)
	return {b.index1, b.world0, b.generation}
}

@(private)
pack_shape :: proc(id: ShapeId) -> u64 {
	return pack_body({i32(id.index1), id.world0, id.generation})
}

// Packed form of a ShapeId — the same u64 the FFI passes and that
// Contact_Info.shape_a / shape_b carry. Lets an app correlate a shape it
// created (CreateHullShape & co. return the unpacked ShapeId) with the
// contact query's packed shape ids.
ShapeId_Pack :: proc(id: ShapeId) -> u64 {
	return pack_shape(id)
}

@(private)
pack_joint :: proc(id: JointId) -> u64 {
	return pack_body({i32(id.index1), id.world0, id.generation})
}

@(private)
unpack_joint :: proc(v: u64) -> JointId {
	b := unpack_body(v)
	return {b.index1, b.world0, b.generation}
}

// ─── Foreign declarations (scalar-in / struct-out shim) ───────────────
// Add a shim foreign decl here only if it exposes a generic Box3D capability
// an unrelated app would plausibly use. App-specific bodies/scenes/collision
// rules stay in the app and call these generic procs. `foreign { ... }` (no
// library name) declares the external C symbols; the linker resolves them
// from the shim + libbox3d archives passed via `-extra-linker-flags`.

@(default_calling_convention = "c")
foreign _ {
	@(link_name = "shim_new_world_def")
	new_world_def :: proc() -> WorldDef ---
	@(link_name = "shim_free_world_def")
	free_world_def :: proc(def: WorldDef) ---
	@(link_name = "shim_world_set_gravity")
	world_set_gravity :: proc(def: WorldDef, x, y, z: f32) ---
	@(link_name = "shim_world_set_contact_hertz")
	world_set_contact_hertz :: proc(def: WorldDef, hertz: f32) ---
	@(link_name = "shim_world_set_contact_damping_ratio")
	world_set_contact_damping_ratio :: proc(def: WorldDef, ratio: f32) ---
	@(link_name = "shim_world_set_restitution_threshold")
	world_set_restitution_threshold :: proc(def: WorldDef, threshold: f32) ---
	@(link_name = "shim_world_set_contact_speed")
	world_set_contact_speed :: proc(def: WorldDef, speed: f32) ---

	@(link_name = "shim_new_body_def")
	new_body_def :: proc() -> BodyDef ---
	@(link_name = "shim_free_body_def")
	free_body_def :: proc(def: BodyDef) ---
	@(link_name = "shim_body_set_type")
	body_set_type :: proc(def: BodyDef, type: Body_Type) ---
	@(link_name = "shim_body_set_position")
	body_set_position :: proc(def: BodyDef, x, y, z: f32) ---
	@(link_name = "shim_body_set_rotation")
	body_set_rotation :: proc(def: BodyDef, x, y, z, w: f32) ---
	@(link_name = "shim_body_set_linear_velocity")
	body_set_linear_velocity :: proc(def: BodyDef, x, y, z: f32) ---
	@(link_name = "shim_body_set_angular_velocity")
	body_set_angular_velocity :: proc(def: BodyDef, x, y, z: f32) ---
	@(link_name = "shim_body_set_enable_sleep")
	body_set_enable_sleep :: proc(def: BodyDef, flag: bool) ---
	@(link_name = "shim_body_set_awake")
	body_set_awake :: proc(def: BodyDef, flag: bool) ---
	@(link_name = "shim_body_set_allow_fast_rotation")
	body_set_allow_fast_rotation :: proc(def: BodyDef, flag: bool) ---
	@(link_name = "shim_body_set_is_bullet")
	body_set_is_bullet :: proc(def: BodyDef, flag: bool) ---

	@(link_name = "shim_new_shape_def")
	new_shape_def :: proc() -> ShapeDef ---
	@(link_name = "shim_free_shape_def")
	free_shape_def :: proc(def: ShapeDef) ---
	@(link_name = "shim_shape_set_density")
	shape_set_density :: proc(def: ShapeDef, density: f32) ---
	@(link_name = "shim_shape_set_friction")
	shape_set_friction :: proc(def: ShapeDef, friction: f32) ---
	@(link_name = "shim_shape_set_restitution")
	shape_set_restitution :: proc(def: ShapeDef, restitution: f32) ---
	@(link_name = "shim_shape_set_rolling_resistance")
	shape_set_rolling_resistance :: proc(def: ShapeDef, rr: f32) ---
	@(link_name = "shim_shape_set_filter")
	shape_set_filter :: proc(def: ShapeDef, category_bits: u64, mask_bits: u64, group_index: i32) ---
	@(link_name = "shim_shape_set_enable_speculative")
	shape_set_enable_speculative :: proc(def: ShapeDef, enable: bool) ---

	@(link_name = "shim_make_box_hull")
	make_box_hull :: proc(hx, hy, hz: f32) -> BoxHull ---
	@(link_name = "shim_free_box_hull")
	free_box_hull :: proc(hull: BoxHull) ---
	@(link_name = "shim_box_hull_get_base")
	box_hull_get_base :: proc(hull: BoxHull) -> rawptr ---

	@(link_name = "shim_make_sphere")
	make_sphere :: proc(radius: f32) -> Sphere ---
	@(link_name = "shim_free_sphere")
	free_sphere :: proc(s: Sphere) ---
	@(link_name = "shim_make_capsule")
	make_capsule :: proc(length, radius: f32) -> Capsule ---
	@(link_name = "shim_free_capsule")
	free_capsule :: proc(c: Capsule) ---
	@(link_name = "shim_create_hull")
	create_hull :: proc(points: rawptr, point_count: i32, max_vertex_count: i32) -> Hull ---
	@(link_name = "shim_destroy_hull")
	destroy_hull :: proc(hull: Hull) ---

	@(link_name = "shim_create_wave_heightfield")
	create_wave_heightfield :: proc(rowCount, columnCount: i32, sx, sy, sz, rowFreq, colFreq: f32) -> HeightField ---
	@(link_name = "shim_create_heightfield")
	create_heightfield :: proc(heights: rawptr, countX, countZ: i32, sx, sy, sz, minH, maxH: f32) -> HeightField ---
	@(link_name = "shim_destroy_heightfield")
	destroy_heightfield :: proc(hf: HeightField) ---

	@(link_name = "shim_create_world")
	create_world :: proc(def: WorldDef) -> u64 ---
	@(link_name = "shim_create_body")
	create_body :: proc(world: u64, def: BodyDef) -> u64 ---
	@(link_name = "shim_destroy_body")
	destroy_body :: proc(body: u64) ---
	@(link_name = "shim_create_hull_shape")
	create_hull_shape :: proc(body: u64, def: ShapeDef, hull: rawptr) -> u64 ---
	@(link_name = "shim_create_transformed_hull_shape")
	create_transformed_hull_shape :: proc(body: u64, def: ShapeDef, hull: rawptr, px, py, pz: f32, sx, sy, sz: f32) -> u64 ---
	@(link_name = "shim_create_sphere_shape")
	create_sphere_shape :: proc(body: u64, def: ShapeDef, s: Sphere) -> u64 ---
	@(link_name = "shim_create_capsule_shape")
	create_capsule_shape :: proc(body: u64, def: ShapeDef, c: Capsule) -> u64 ---
	@(link_name = "shim_create_heightfield_shape")
	create_heightfield_shape :: proc(body: u64, def: ShapeDef, hf: HeightField) -> u64 ---
	@(link_name = "shim_world_step")
	world_step :: proc(world: u64, dt: f32, substeps: i32) ---
	@(link_name = "shim_body_get_position")
	body_get_position :: proc(body: u64, x, y, z: ^f32) ---
	@(link_name = "shim_body_get_rotation")
	body_get_rotation :: proc(body: u64, x, y, z, w: ^f32) ---
	@(link_name = "shim_body_get_linear_velocity")
	body_get_linear_velocity :: proc(body: u64, x, y, z: ^f32) ---
	@(link_name = "shim_body_get_angular_velocity")
	body_get_angular_velocity :: proc(body: u64, x, y, z: ^f32) ---
	@(link_name = "shim_body_set_linear_velocity_runtime")
	body_set_linear_velocity_runtime :: proc(body: u64, x, y, z: f32) ---
	@(link_name = "shim_body_set_angular_velocity_runtime")
	body_set_angular_velocity_runtime :: proc(body: u64, x, y, z: f32) ---
	@(link_name = "shim_body_get_contacts")
	body_get_contacts :: proc(body: u64, out: rawptr, max_contacts: i32) -> i32 ---
	@(link_name = "shim_destroy_world")
	destroy_world :: proc(world: u64) ---

	@(link_name = "shim_create_wheel_joint")
	create_wheel_joint :: proc(world: u64, bodyA, bodyB: u64, apx, apy, apz, aqx, aqy, aqz, aqw: f32, bpx, bpy, bpz, bqx, bqy, bqz, bqw: f32, collideConnected: bool, enableSuspensionSpring: bool, suspensionHertz, suspensionDampingRatio: f32, enableSuspensionLimit: bool, lowerSuspension, upperSuspension: f32, enableSpinMotor: bool, maxSpinTorque, spinSpeed: f32, enableSteering: bool, steeringHertz, steeringDampingRatio, targetSteeringAngle, maxSteeringTorque: f32, enableSteeringLimit: bool, lowerSteering, upperSteering, constraintHertz, constraintDampingRatio: f32) -> u64 ---
	@(link_name = "shim_wheel_set_spin_motor_speed")
	wheel_set_spin_motor_speed :: proc(joint: u64, speed: f32) ---
	@(link_name = "shim_wheel_set_target_steering_angle")
	wheel_set_target_steering_angle :: proc(joint: u64, radians: f32) ---
	@(link_name = "shim_wheel_get_steering_angle")
	wheel_get_steering_angle :: proc(joint: u64) -> f32 ---

	@(link_name = "shim_create_weld_joint")
	create_weld_joint :: proc(world: u64, bodyA, bodyB: u64, apx, apy, apz, aqx, aqy, aqz, aqw: f32, bpx, bpy, bpz, bqx, bqy, bqz, bqw: f32, collideConnected: bool, linearHertz, angularHertz, linearDampingRatio, angularDampingRatio: f32) -> u64 ---

	@(link_name = "shim_create_prismatic_joint")
	create_prismatic_joint :: proc(world: u64, bodyA, bodyB: u64, apx, apy, apz, aqx, aqy, aqz, aqw: f32, bpx, bpy, bpz, bqx, bqy, bqz, bqw: f32, collideConnected: bool, enableSpring: bool, springHertz, springDampingRatio, targetTranslation: f32, enableLimit: bool, lowerTranslation, upperTranslation: f32, enableMotor: bool, maxMotorForce, motorSpeed, constraintHertz, constraintDampingRatio: f32) -> u64 ---
	@(link_name = "shim_prismatic_set_motor_speed")
	prismatic_set_motor_speed :: proc(joint: u64, speed: f32) ---
	@(link_name = "shim_prismatic_set_max_motor_force")
	prismatic_set_max_motor_force :: proc(joint: u64, force: f32) ---
	@(link_name = "shim_prismatic_set_target_translation")
	prismatic_set_target_translation :: proc(joint: u64, translation: f32) ---
	@(link_name = "shim_prismatic_set_spring_hertz")
	prismatic_set_spring_hertz :: proc(joint: u64, hertz: f32) ---
	@(link_name = "shim_prismatic_set_spring_damping_ratio")
	prismatic_set_spring_damping_ratio :: proc(joint: u64, damping_ratio: f32) ---
	@(link_name = "shim_prismatic_get_translation")
	prismatic_get_translation :: proc(joint: u64) -> f32 ---
	@(link_name = "shim_prismatic_get_speed")
	prismatic_get_speed :: proc(joint: u64) -> f32 ---

	@(link_name = "shim_create_revolute_joint")
	create_revolute_joint :: proc(world: u64, bodyA, bodyB: u64, apx, apy, apz, aqx, aqy, aqz, aqw: f32, bpx, bpy, bpz, bqx, bqy, bqz, bqw: f32, collideConnected: bool, enableSpring: bool, springHertz, springDampingRatio, targetAngle: f32, enableLimit: bool, lowerAngle, upperAngle: f32, enableMotor: bool, maxMotorTorque, motorSpeed, constraintHertz, constraintDampingRatio: f32) -> u64 ---
	@(link_name = "shim_revolute_set_motor_speed")
	revolute_set_motor_speed :: proc(joint: u64, speed: f32) ---
	@(link_name = "shim_revolute_get_angle")
	revolute_get_angle :: proc(joint: u64) -> f32 ---

	// Log sink: toggle Box3D's diagnostic output (the solver "unstable: ..."
	// and CCD "CCD stall: ..." lines route through b3Log). Scalar mode only —
	// the shim owns the handler functions (docs/FFI_WASM.md invariant 1).
	@(link_name = "shim_set_log_sink")
	set_log_sink :: proc(mode: i32) ---
}

// ─── Public API (vendor:box3d-shaped, PascalCase) ────────────────────
// Add a generic physics capability here only if an unrelated app would
// plausibly use it. App-specific bodies/scenes/collision rules go in the app.

// World def (opaque handle + setters; vendor:box3d fills by value).
DefaultWorldDef :: proc() -> WorldDef {return new_world_def()}
FreeWorldDef :: proc(def: WorldDef) {free_world_def(def)}
WorldDef_SetGravity :: proc(def: WorldDef, x, y, z: f32) {world_set_gravity(def, x, y, z)}
WorldDef_SetContactHertz :: proc(def: WorldDef, hertz: f32) {world_set_contact_hertz(def, hertz)}
WorldDef_SetContactDampingRatio :: proc(
	def: WorldDef,
	ratio: f32,
) {world_set_contact_damping_ratio(def, ratio)}
WorldDef_SetRestitutionThreshold :: proc(
	def: WorldDef,
	threshold: f32,
) {world_set_restitution_threshold(def, threshold)}
WorldDef_SetContactSpeed :: proc(def: WorldDef, speed: f32) {world_set_contact_speed(def, speed)}

DefaultBodyDef :: proc() -> BodyDef {return new_body_def()}
FreeBodyDef :: proc(def: BodyDef) {free_body_def(def)}
BodyDef_SetType :: proc(def: BodyDef, type: Body_Type) {body_set_type(def, type)}
BodyDef_SetPosition :: proc(def: BodyDef, x, y, z: f32) {body_set_position(def, x, y, z)}
BodyDef_SetRotation :: proc(def: BodyDef, q: [4]f32) {body_set_rotation(
		def,
		q[0],
		q[1],
		q[2],
		q[3],
	)}
BodyDef_SetLinearVelocity :: proc(def: BodyDef, x, y, z: f32) {body_set_linear_velocity(
		def,
		x,
		y,
		z,
	)}
BodyDef_SetAngularVelocity :: proc(def: BodyDef, x, y, z: f32) {body_set_angular_velocity(
		def,
		x,
		y,
		z,
	)}
BodyDef_SetEnableSleep :: proc(def: BodyDef, flag: bool) {body_set_enable_sleep(def, flag)}
BodyDef_SetAwake :: proc(def: BodyDef, flag: bool) {body_set_awake(def, flag)}
BodyDef_SetAllowFastRotation :: proc(def: BodyDef, flag: bool) {body_set_allow_fast_rotation(
		def,
		flag,
	)}
BodyDef_SetIsBullet :: proc(def: BodyDef, flag: bool) {body_set_is_bullet(def, flag)}

DefaultShapeDef :: proc() -> ShapeDef {return new_shape_def()}
FreeShapeDef :: proc(def: ShapeDef) {free_shape_def(def)}
ShapeDef_SetDensity :: proc(def: ShapeDef, density: f32) {shape_set_density(def, density)}
ShapeDef_SetFriction :: proc(def: ShapeDef, friction: f32) {shape_set_friction(def, friction)}
ShapeDef_SetRestitution :: proc(def: ShapeDef, restitution: f32) {shape_set_restitution(
		def,
		restitution,
	)}
ShapeDef_SetRollingResistance :: proc(def: ShapeDef, rr: f32) {shape_set_rolling_resistance(
		def,
		rr,
	)}
ShapeDef_SetFilter :: proc(def: ShapeDef, category_bits: u64, mask_bits: u64, group_index: i32) {
	shape_set_filter(def, category_bits, mask_bits, group_index)
}
ShapeDef_SetEnableSpeculative :: proc(def: ShapeDef, enable: bool) {
	shape_set_enable_speculative(def, enable)
}

// Hull / sphere / capsule constructors (opaque handles).
MakeBoxHull :: proc(hx, hy, hz: f32) -> BoxHull {return make_box_hull(hx, hy, hz)}
FreeBoxHull :: proc(hull: BoxHull) {free_box_hull(hull)}
BoxHull_Base :: proc(hull: BoxHull) -> rawptr {return box_hull_get_base(hull)}

MakeSphere :: proc(radius: f32) -> Sphere {return make_sphere(radius)}
FreeSphere :: proc(s: Sphere) {free_sphere(s)}

MakeCapsule :: proc(length, radius: f32) -> Capsule {return make_capsule(length, radius)}
FreeCapsule :: proc(c: Capsule) {free_capsule(c)}

// Generic convex hull from a point cloud (b3CreateHull). `points` is a slice
// of [3]f32 (x,y,z triplets); the world clones the hull on shape creation, so
// the caller may free immediately after CreateHullShape. Returns a Hull handle
// (NULL-typed) on degenerate input — check via `Hull_Base` (returns nil).
Create_Hull :: proc(points: [][3]f32, max_vertex_count: int) -> Hull {
	if len(points) == 0 {return Hull(nil)}
	return create_hull(raw_data(points), i32(len(points)), i32(max_vertex_count))
}
Destroy_Hull :: proc(hull: Hull) {destroy_hull(hull)}
Hull_Base :: proc(hull: Hull) -> rawptr {return rawptr(hull)}

// Heightfield (b3CreateWave — generic wave heightfield generator).
CreateWave :: proc(rowCount, columnCount: i32, sx, sy, sz, rowFreq, colFreq: f32) -> HeightField {
	return create_wave_heightfield(rowCount, columnCount, sx, sy, sz, rowFreq, colFreq)
}
// Custom heightfield from an explicit grid of heights (countX × countZ,
// row-major: index = z * countX + x). The heights are copied by the engine
// (compressed to uint16), so the caller may free its array immediately after.
// `minH`/`maxH` are the quantization range the heights are clamped to.
CreateHeightFieldFromData :: proc(
	heights: []f32,
	countX, countZ: i32,
	sx, sy, sz, minH, maxH: f32,
) -> HeightField {
	return create_heightfield(raw_data(heights), countX, countZ, sx, sy, sz, minH, maxH)
}
DestroyHeightField :: proc(hf: HeightField) {destroy_heightfield(hf)}

// World / body / shape operations (match vendor:box3d names).
CreateWorld :: proc(def: WorldDef) -> WorldId {return unpack_world(create_world(def))}
CreateBody :: proc(world: WorldId, def: BodyDef) -> BodyId {return unpack_body(
		create_body(pack_world(world), def),
	)}
CreateHullShape :: proc(body: BodyId, def: ShapeDef, hull: rawptr) -> ShapeId {
	return unpack_shape(create_hull_shape(pack_body(body), def, hull))
}
// Attach a convex hull with a baked local transform (runtime compound body:
// one dynamic body + many transformed hulls = one rigid body, no welds).
// `local_pos` is the shape offset in the body's local frame; `scale` bakes a
// non-uniform scale into the hull (use {1,1,1} for an unscaled hull). The hull
// is cloned, so the caller may free it immediately after.
CreateTransformedHullShape :: proc(
	body: BodyId,
	def: ShapeDef,
	hull: rawptr,
	local_pos: [3]f32,
	scale: [3]f32,
) -> ShapeId {
	return unpack_shape(
		create_transformed_hull_shape(
			pack_body(body),
			def,
			hull,
			local_pos[0],
			local_pos[1],
			local_pos[2],
			scale[0],
			scale[1],
			scale[2],
		),
	)
}
CreateSphereShape :: proc(body: BodyId, def: ShapeDef, s: Sphere) -> ShapeId {
	return unpack_shape(create_sphere_shape(pack_body(body), def, s))
}
CreateCapsuleShape :: proc(body: BodyId, def: ShapeDef, c: Capsule) -> ShapeId {
	return unpack_shape(create_capsule_shape(pack_body(body), def, c))
}
// The heightfield must outlive the shape: destroy the shape (and world)
// before DestroyHeightField.
CreateHeightFieldShape :: proc(body: BodyId, def: ShapeDef, hf: HeightField) -> ShapeId {
	return unpack_shape(create_heightfield_shape(pack_body(body), def, hf))
}
World_Step :: proc(world: WorldId, dt: f32, substeps: i32) {world_step(
		pack_world(world),
		dt,
		substeps,
	)}
// Destroy a body and every shape and joint attached to it. Do not keep the
// body's shape/joint ids after this (Box3D frees them with the body).
DestroyBody :: proc(body: BodyId) {destroy_body(pack_body(body))}
DestroyWorld :: proc(world: WorldId) {destroy_world(pack_world(world))}

// Log sink: toggle Box3D's diagnostic output. Call once at startup; affects
// every Box3D world in the process (the handler is a global in core.c).
Set_Log_Sink :: proc(mode: Log_Sink) {set_log_sink(i32(mode))}

// Body transform getters — by-value [3]f32 / [4]f32 (matches vendor:box3d
// returning b3Vec3 / b3Quat). The quaternion is (v.x, v.y, v.z, s).
Body_GetPosition :: proc(body: BodyId) -> [3]f32 {
	x, y, z: f32 = 0, 0, 0
	body_get_position(pack_body(body), &x, &y, &z)
	return {x, y, z}
}
Body_GetRotation :: proc(body: BodyId) -> [4]f32 {
	x, y, z, w: f32 = 0, 0, 0, 0
	body_get_rotation(pack_body(body), &x, &y, &z, &w)
	return {x, y, z, w}
}

// Runtime body velocity getters — by-value [3]f32 (matches vendor:box3d
// returning b3Vec3). Linear velocity is world-space; angular velocity is
// world-space (transform into the body frame for roll/pitch/yaw rates).
Body_GetLinearVelocity :: proc(body: BodyId) -> [3]f32 {
	x, y, z: f32 = 0, 0, 0
	body_get_linear_velocity(pack_body(body), &x, &y, &z)
	return {x, y, z}
}
Body_GetAngularVelocity :: proc(body: BodyId) -> [3]f32 {
	x, y, z: f32 = 0, 0, 0
	body_get_angular_velocity(pack_body(body), &x, &y, &z)
	return {x, y, z}
}

// Runtime setters (match vendor:box3d: b3Body_SetLinearVelocity etc.).
Body_SetLinearVelocity :: proc(body: BodyId, x, y, z: f32) {body_set_linear_velocity_runtime(
		pack_body(body),
		x,
		y,
		z,
	)}
Body_SetAngularVelocity :: proc(body: BodyId, x, y, z: f32) {body_set_angular_velocity_runtime(
		pack_body(body),
		x,
		y,
		z,
	)}

// Flattened touching-contact data for a body (mirrors the C shim_contact_*
// POD structs — same field order, so the buffer the shim fills is readable
// directly). The manifold normal points from shape A to shape B in world
// space; a height-field/mesh triangle index is per point (-1 if none).
// Returned data is a snapshot of the current step's contacts.

Contact_Point :: struct {
	ax, ay, az:     f32, // anchorA (world, relative to bodyA COM)
	bx, by, bz:     f32, // anchorB (world, relative to bodyB COM)
	separation:     f32, // negative if penetrating
	normal_impulse: f32, // impulse along the manifold normal
	triangle_index: i32, // height-field/mesh triangle, else -1
}

Contact_Manifold :: struct {
	nx, ny, nz:  f32, // world-space normal, shape A -> B
	point_count: i32,
	points:      [4]Contact_Point,
}

Contact_Info :: struct {
	shape_a:        u64, // packed shape id
	shape_b:        u64,
	manifold_count: i32,
	manifolds:      [8]Contact_Manifold,
}

// Returns the number of touching contacts written into `out` (<= len(out)).
Body_GetContacts :: proc(body: BodyId, out: []Contact_Info) -> i32 {
	return body_get_contacts(pack_body(body), &out[0], i32(len(out)))
}

WheelJoint_SetSpinMotorSpeed :: proc(joint: JointId, speed: f32) {wheel_set_spin_motor_speed(
		pack_joint(joint),
		speed,
	)}
WheelJoint_SetTargetSteeringAngle :: proc(
	joint: JointId,
	radians: f32,
) {wheel_set_target_steering_angle(pack_joint(joint), radians)}

// Achieved (current) wheel steering angle in radians (matches
// b3WheelJoint_GetSteeringAngle). Steer *rate* is obtained by
// finite-differencing this across steps (Box3D exposes no steering-rate
// getter), so the caller keeps the previous value.
WheelJoint_GetSteeringAngle :: proc(joint: JointId) -> f32 {
	return wheel_get_steering_angle(pack_joint(joint))
}

// The wheel joint suspends body B along local frame A's x-axis and spins
// it about local frame B's z-axis.

WheelJointDefParams :: struct {
	world:                  WorldId,
	bodyA:                  BodyId,
	bodyB:                  BodyId,
	localFrameA_pos:        [3]f32,
	localFrameA_rot:        [4]f32,
	localFrameB_pos:        [3]f32,
	localFrameB_rot:        [4]f32,
	collideConnected:       bool,
	enableSuspensionSpring: bool,
	suspensionHertz:        f32,
	suspensionDampingRatio: f32,
	enableSuspensionLimit:  bool,
	lowerSuspension:        f32,
	upperSuspension:        f32,
	enableSpinMotor:        bool,
	maxSpinTorque:          f32,
	spinSpeed:              f32,
	enableSteering:         bool,
	steeringHertz:          f32,
	steeringDampingRatio:   f32,
	targetSteeringAngle:    f32,
	maxSteeringTorque:      f32,
	enableSteeringLimit:    bool,
	lowerSteering:          f32,
	upperSteering:          f32,
	// Stiffness of the joint's structural constraints (point-to-line / twist /
	// collinearity), not the suspension spring; 0 leaves Box3D's default
	// (60 Hz, ratio 2), which visibly lets bodies drift off their joint axis
	// under impact. Box3D clamps hertz to 0.25 / substep-dt.
	constraintHertz:        f32,
	constraintDampingRatio: f32,
}

CreateWheelJoint :: proc(p: WheelJointDefParams) -> JointId {
	return unpack_joint(
		create_wheel_joint(
			pack_world(p.world),
			pack_body(p.bodyA),
			pack_body(p.bodyB),
			p.localFrameA_pos[0],
			p.localFrameA_pos[1],
			p.localFrameA_pos[2],
			p.localFrameA_rot[0],
			p.localFrameA_rot[1],
			p.localFrameA_rot[2],
			p.localFrameA_rot[3],
			p.localFrameB_pos[0],
			p.localFrameB_pos[1],
			p.localFrameB_pos[2],
			p.localFrameB_rot[0],
			p.localFrameB_rot[1],
			p.localFrameB_rot[2],
			p.localFrameB_rot[3],
			p.collideConnected,
			p.enableSuspensionSpring,
			p.suspensionHertz,
			p.suspensionDampingRatio,
			p.enableSuspensionLimit,
			p.lowerSuspension,
			p.upperSuspension,
			p.enableSpinMotor,
			p.maxSpinTorque,
			p.spinSpeed,
			p.enableSteering,
			p.steeringHertz,
			p.steeringDampingRatio,
			p.targetSteeringAngle,
			p.maxSteeringTorque,
		p.enableSteeringLimit,
		p.lowerSteering,
		p.upperSteering,
		p.constraintHertz,
		p.constraintDampingRatio,
	),
	)
}

// ─── Quaternion helper (matches b3MakeQuatFromAxisAngle) ─────────────

Quat_From_Axis_Angle :: proc(axis: [3]f32, radians: f32) -> [4]f32 {
	half := radians * 0.5
	s := math.sin(half)
	c := math.cos(half)
	return {axis[0] * s, axis[1] * s, axis[2] * s, c}
}

// 90° rotation about Z: maps +X → +Y.
QUAT_X_TO_Y :: [4]f32{0.0, 0.0, 0.70710678, 0.70710678}
QUAT_IDENTITY :: [4]f32{0.0, 0.0, 0.0, 1.0}

// Body B slides along frame A's x-axis; the rotation lock pins frame B's
// orientation to frame A's (not the bodies'). Both frames must share the
// same convention (localFrameB_rot = localFrameA_rot), or the solver drags
// body B out of its starting orientation. Joint translation is zero when
// the frame origins coincide in world space.

PrismaticJointDefParams :: struct {
	world:             WorldId,
	bodyA, bodyB:      BodyId,
	localFrameA_pos:   [3]f32,
	localFrameA_rot:   [4]f32, // x-axis = joint (slide) axis
	localFrameB_pos:   [3]f32,
	localFrameB_rot:   [4]f32,
	collideConnected:  bool,
	enableSpring:      bool,
	springHertz:       f32,
	springDampingRatio: f32,
	targetTranslation: f32,
	enableLimit:       bool,
	lowerTranslation:  f32,
	upperTranslation:  f32,
	enableMotor:       bool,
	maxMotorForce:     f32,
	motorSpeed:        f32,
	// Stiffness of the joint's structural (perpendicular + rotation-lock)
	// constraints; 0 leaves Box3D's default (60 Hz, ratio 2). See the wheel
	// joint's note for why a soft default lets bodies visibly drift off their
	// joint axis under impact.
	constraintHertz:        f32,
	constraintDampingRatio: f32,
}

CreatePrismaticJoint :: proc(p: PrismaticJointDefParams) -> JointId {
	return unpack_joint(
		create_prismatic_joint(
			pack_world(p.world),
			pack_body(p.bodyA),
			pack_body(p.bodyB),
			p.localFrameA_pos[0],
			p.localFrameA_pos[1],
			p.localFrameA_pos[2],
			p.localFrameA_rot[0],
			p.localFrameA_rot[1],
			p.localFrameA_rot[2],
			p.localFrameA_rot[3],
			p.localFrameB_pos[0],
			p.localFrameB_pos[1],
			p.localFrameB_pos[2],
			p.localFrameB_rot[0],
			p.localFrameB_rot[1],
			p.localFrameB_rot[2],
			p.localFrameB_rot[3],
			p.collideConnected,
			p.enableSpring,
			p.springHertz,
			p.springDampingRatio,
			p.targetTranslation,
			p.enableLimit,
			p.lowerTranslation,
			p.upperTranslation,
			p.enableMotor,
			p.maxMotorForce,
			p.motorSpeed,
			p.constraintHertz,
			p.constraintDampingRatio,
		),
	)
}

PrismaticJoint_SetMotorSpeed :: proc(joint: JointId, speed: f32) {
	prismatic_set_motor_speed(pack_joint(joint), speed)
}
PrismaticJoint_SetMaxMotorForce :: proc(joint: JointId, force: f32) {
	prismatic_set_max_motor_force(pack_joint(joint), force)
}
PrismaticJoint_SetTargetTranslation :: proc(joint: JointId, translation: f32) {
	prismatic_set_target_translation(pack_joint(joint), translation)
}
PrismaticJoint_SetSpringHertz :: proc(joint: JointId, hertz: f32) {
	prismatic_set_spring_hertz(pack_joint(joint), hertz)
}
PrismaticJoint_SetSpringDampingRatio :: proc(joint: JointId, damping_ratio: f32) {
	prismatic_set_spring_damping_ratio(pack_joint(joint), damping_ratio)
}

// Current translation along the joint axis in meters (b3PrismaticJoint_GetTranslation).
PrismaticJoint_GetTranslation :: proc(joint: JointId) -> f32 {
	return prismatic_get_translation(pack_joint(joint))
}

// Current translation speed in m/s (b3PrismaticJoint_GetSpeed).
PrismaticJoint_GetSpeed :: proc(joint: JointId) -> f32 {
	return prismatic_get_speed(pack_joint(joint))
}

// A point on body B pinned to a point on body A; the only DOF is rotation
// about frame A's z-axis.
RevoluteJointDefParams :: struct {
	world:                WorldId,
	bodyA:                BodyId,
	bodyB:                BodyId,
	localFrameA_pos:      [3]f32,
	localFrameA_rot:      [4]f32, // z-axis = hinge axis
	localFrameB_pos:      [3]f32,
	localFrameB_rot:      [4]f32,
	collideConnected:     bool,
	enableSpring:         bool,
	springHertz:          f32,
	springDampingRatio:   f32,
	targetAngle:          f32,
	enableLimit:          bool,
	lowerAngle:           f32,
	upperAngle:           f32,
	enableMotor:          bool,
	maxMotorTorque:       f32,
	motorSpeed:           f32,
	// Stiffness of the joint's structural (anchor + twist) constraints;
	// 0 leaves Box3D's default (60 Hz, ratio 2). See the wheel joint's note
	// for why a soft default lets bodies visibly drift off their joint axis
	// under impact.
	constraintHertz:        f32,
	constraintDampingRatio: f32,
}

CreateRevoluteJoint :: proc(p: RevoluteJointDefParams) -> JointId {
	return unpack_joint(
		create_revolute_joint(
			pack_world(p.world),
			pack_body(p.bodyA),
			pack_body(p.bodyB),
			p.localFrameA_pos[0],
			p.localFrameA_pos[1],
			p.localFrameA_pos[2],
			p.localFrameA_rot[0],
			p.localFrameA_rot[1],
			p.localFrameA_rot[2],
			p.localFrameA_rot[3],
			p.localFrameB_pos[0],
			p.localFrameB_pos[1],
			p.localFrameB_pos[2],
			p.localFrameB_rot[0],
			p.localFrameB_rot[1],
			p.localFrameB_rot[2],
			p.localFrameB_rot[3],
			p.collideConnected,
			p.enableSpring,
			p.springHertz,
			p.springDampingRatio,
			p.targetAngle,
			p.enableLimit,
			p.lowerAngle,
			p.upperAngle,
			p.enableMotor,
			p.maxMotorTorque,
			p.motorSpeed,
			p.constraintHertz,
			p.constraintDampingRatio,
		),
	)
}

RevoluteJoint_SetMotorSpeed :: proc(joint: JointId, speed: f32) {
	revolute_set_motor_speed(pack_joint(joint), speed)
}

// Current angle in radians relative to the reference (targetAngle at rest).
RevoluteJoint_GetAngle :: proc(joint: JointId) -> f32 {
	return revolute_get_angle(pack_joint(joint))
}

// Rigidly connects two bodies with optional damped springs. hertz 0 = max
// stiffness; damping ratio 1 = critical damping.

WeldJointDefParams :: struct {
	world:                                   WorldId,
	bodyA, bodyB:                            BodyId,
	localFrameA_pos:                         [3]f32,
	localFrameA_rot:                         [4]f32,
	localFrameB_pos:                         [3]f32,
	localFrameB_rot:                         [4]f32,
	collideConnected:                        bool,
	linearHertz, angularHertz:               f32,
	linearDampingRatio, angularDampingRatio: f32,
}

CreateWeldJoint :: proc(p: WeldJointDefParams) -> JointId {
	return unpack_joint(
		create_weld_joint(
			pack_world(p.world),
			pack_body(p.bodyA),
			pack_body(p.bodyB),
			p.localFrameA_pos[0],
			p.localFrameA_pos[1],
			p.localFrameA_pos[2],
			p.localFrameA_rot[0],
			p.localFrameA_rot[1],
			p.localFrameA_rot[2],
			p.localFrameA_rot[3],
			p.localFrameB_pos[0],
			p.localFrameB_pos[1],
			p.localFrameB_pos[2],
			p.localFrameB_rot[0],
			p.localFrameB_rot[1],
			p.localFrameB_rot[2],
			p.localFrameB_rot[3],
			p.collideConnected,
			p.linearHertz,
			p.angularHertz,
			p.linearDampingRatio,
			p.angularDampingRatio,
		),
	)
}
