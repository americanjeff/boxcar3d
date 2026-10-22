// Box3D binding for Odin, built on `vendor:box3d`.
//
// The sim runs on the Box3D copy that ships with the Odin toolchain
// (vendor/box3d, pinned by the toolchain version): this package maps the
// engine's scalar API onto `vendor:box3d`'s bindings instead of a C shim.
// ID structs are the same fields as upstream `b3WorldId` / `b3BodyId` /
// `b3ShapeId` / `b3JointId`; they cross as value types (compare via ==,
// zero = null) and are packed to `u64` only where the API exposes a packed
// form. Do not read the fields — they are upstream's internal encoding.
//
// Def and primitive handles (`WorldDef` & co.) are opaque pointers to
// toolchain-struct allocations owned by this package; the create calls read
// them synchronously and clone what they need, so the caller frees the
// handle after the create call.

package physics

import "core:c"
import "core:math"
import v3d "vendor:box3d"

// ─── Body type (mirrors b3BodyType) ───────────────────────────────────

Body_Type :: enum i32 {
	Static    = 0,
	Kinematic = 1,
	Dynamic   = 2,
}

// ─── Log sink ─────────────────────────────────────────────────────────
// Box3D's b3Log routes solver ("unstable: ...") and CCD ("CCD stall: ...")
// diagnostics through a single handler.

Log_Sink :: enum i32 {
	Default = 0, // Box3D default: "Box3D: <msg>" to stdout
	Silent  = 1, // no-op (suppress the solver/CCD diagnostic flood)
}

// ─── IDs (mirrors b3WorldId / b3BodyId / b3ShapeId / b3JointId) ────────

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

// ─── Opaque def/primitive handles (package-owned allocations) ─────────

WorldDef :: distinct rawptr
BodyDef :: distinct rawptr
ShapeDef :: distinct rawptr
BoxHull :: distinct rawptr
Sphere :: distinct rawptr
Capsule :: distinct rawptr
HeightField :: distinct rawptr
Hull :: distinct rawptr

// ─── ID pack/unpack (packed u64 form) ─────────────────────────────────

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

// Packed form of a ShapeId — the same u64 Contact_Info.shape_a / shape_b
// carry. Lets an app correlate a shape it created (CreateHullShape & co.
// return the unpacked ShapeId) with the contact query's packed shape ids.
ShapeId_Pack :: proc(id: ShapeId) -> u64 {
	return pack_shape(id)
}

@(private)
pack_joint :: proc(id: JointId) -> u64 {
	return pack_body({i32(id.index1), id.world0, id.generation})
}

// ─── Conversions to the vendor:box3d surface ──────────────────────────
// The toolchain's ID structs carry the same fields; the conversion is a
// field copy (the types are nominally distinct).

@(private)
to_v3d_world :: proc(id: WorldId) -> v3d.WorldId {
	return {id.index1, id.generation}
}

@(private)
from_v3d_world :: proc(id: v3d.WorldId) -> WorldId {
	return {id.index1, id.generation}
}

@(private)
to_v3d_body :: proc(id: BodyId) -> v3d.BodyId {
	return {id.index1, id.world0, id.generation}
}

@(private)
from_v3d_body :: proc(id: v3d.BodyId) -> BodyId {
	return {id.index1, id.world0, id.generation}
}

@(private)
to_v3d_shape :: proc(id: ShapeId) -> v3d.ShapeId {
	return {id.index1, id.world0, id.generation}
}

@(private)
from_v3d_shape :: proc(id: v3d.ShapeId) -> ShapeId {
	return {id.index1, id.world0, id.generation}
}

@(private)
to_v3d_joint :: proc(id: JointId) -> v3d.JointId {
	return {id.index1, id.world0, id.generation}
}

@(private)
from_v3d_joint :: proc(id: v3d.JointId) -> JointId {
	return {id.index1, id.world0, id.generation}
}

// Quaternion order: [4]f32 is (x, y, z, w); vendor:box3d's quaternion128
// matches the C b3Quat {v, s} layout (scalar part is .w). quaternion128 has
// no compound literal, so construct through the `quaternion` builtin
// (f32 args → 128-bit).
@(private)
to_v3d_quat :: proc(q: [4]f32) -> v3d.Quat {
	return quaternion(x = q[0], y = q[1], z = q[2], w = q[3])
}

@(private)
from_v3d_quat :: proc(q: v3d.Quat) -> [4]f32 {
	return {q.x, q.y, q.z, q.w}
}

// ─── Log sink callbacks ───────────────────────────────────────────────
// The default sink (log_default_cb) is defined per-target in the
// target-suffixed files: physics_linux.odin (bare libc externs) and
// physics_js_wasm32.odin (the libc-shim owns those link names on wasm).
// The silent sink is target-agnostic and lives here.

@(private)
log_silent_cb :: proc "c" (message: rawptr) {
}

// ─── Public API (vendor:box3d-shaped, PascalCase) ────────────────────
// Add a generic physics capability here only if an unrelated app would
// plausibly use it. App-specific bodies/scenes/collision rules go in the app.

// World def (opaque handle + setters).
DefaultWorldDef :: proc() -> WorldDef {
	hd := new(v3d.WorldDef)
	hd^ = v3d.DefaultWorldDef()
	return WorldDef(rawptr(hd))
}

FreeWorldDef :: proc(def: WorldDef) {
	free(rawptr(def))
}

WorldDef_SetGravity :: proc(def: WorldDef, x, y, z: f32) {
	d := (^v3d.WorldDef)(rawptr(def))
	d.gravity = {x, y, z}
}

WorldDef_SetContactHertz :: proc(def: WorldDef, hertz: f32) {
	d := (^v3d.WorldDef)(rawptr(def))
	d.contactHertz = hertz
}

WorldDef_SetContactDampingRatio :: proc(def: WorldDef, ratio: f32) {
	d := (^v3d.WorldDef)(rawptr(def))
	d.contactDampingRatio = ratio
}

WorldDef_SetRestitutionThreshold :: proc(def: WorldDef, threshold: f32) {
	d := (^v3d.WorldDef)(rawptr(def))
	d.restitutionThreshold = threshold
}

WorldDef_SetContactSpeed :: proc(def: WorldDef, speed: f32) {
	d := (^v3d.WorldDef)(rawptr(def))
	d.contactSpeed = speed
}

DefaultBodyDef :: proc() -> BodyDef {
	hd := new(v3d.BodyDef)
	hd^ = v3d.DefaultBodyDef()
	return BodyDef(rawptr(hd))
}

FreeBodyDef :: proc(def: BodyDef) {
	free(rawptr(def))
}

BodyDef_SetType :: proc(def: BodyDef, type: Body_Type) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.type = v3d.BodyType(type)
}

BodyDef_SetPosition :: proc(def: BodyDef, x, y, z: f32) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.position = {x, y, z}
}

BodyDef_SetRotation :: proc(def: BodyDef, q: [4]f32) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.rotation = to_v3d_quat(q)
}

BodyDef_SetLinearVelocity :: proc(def: BodyDef, x, y, z: f32) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.linearVelocity = {x, y, z}
}

BodyDef_SetAngularVelocity :: proc(def: BodyDef, x, y, z: f32) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.angularVelocity = {x, y, z}
}

BodyDef_SetEnableSleep :: proc(def: BodyDef, flag: bool) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.enableSleep = flag
}

BodyDef_SetAwake :: proc(def: BodyDef, flag: bool) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.isAwake = flag
}

BodyDef_SetAllowFastRotation :: proc(def: BodyDef, flag: bool) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.allowFastRotation = flag
}

BodyDef_SetIsBullet :: proc(def: BodyDef, flag: bool) {
	d := (^v3d.BodyDef)(rawptr(def))
	d.isBullet = flag
}

DefaultShapeDef :: proc() -> ShapeDef {
	hd := new(v3d.ShapeDef)
	hd^ = v3d.DefaultShapeDef()
	return ShapeDef(rawptr(hd))
}

FreeShapeDef :: proc(def: ShapeDef) {
	free(rawptr(def))
}

ShapeDef_SetDensity :: proc(def: ShapeDef, density: f32) {
	d := (^v3d.ShapeDef)(rawptr(def))
	d.density = density
}

ShapeDef_SetFriction :: proc(def: ShapeDef, friction: f32) {
	d := (^v3d.ShapeDef)(rawptr(def))
	d.baseMaterial.friction = friction
}

ShapeDef_SetRestitution :: proc(def: ShapeDef, restitution: f32) {
	d := (^v3d.ShapeDef)(rawptr(def))
	d.baseMaterial.restitution = restitution
}

ShapeDef_SetRollingResistance :: proc(def: ShapeDef, rr: f32) {
	d := (^v3d.ShapeDef)(rawptr(def))
	d.baseMaterial.rollingResistance = rr
}

ShapeDef_SetFilter :: proc(def: ShapeDef, category_bits: u64, mask_bits: u64, group_index: i32) {
	d := (^v3d.ShapeDef)(rawptr(def))
	d.filter = v3d.Filter {
		categoryBits = category_bits,
		maskBits     = mask_bits,
		groupIndex   = c.int(group_index),
	}
}

ShapeDef_SetEnableSpeculative :: proc(def: ShapeDef, enable: bool) {
	d := (^v3d.ShapeDef)(rawptr(def))
	d.enableSpeculativeContact = enable
}

// Hull / sphere / capsule constructors (opaque handles).
MakeBoxHull :: proc(hx, hy, hz: f32) -> BoxHull {
	hd := new(v3d.BoxHull)
	hd^ = v3d.MakeBoxHull(hx, hy, hz)
	return BoxHull(rawptr(hd))
}

FreeBoxHull :: proc(hull: BoxHull) {
	free(rawptr(hull))
}

// Base b3HullData of a box hull (first field, offset 0) — pass to
// CreateHullShape / CreateTransformedHullShape.
BoxHull_Base :: proc(hull: BoxHull) -> rawptr {
	return rawptr(hull)
}

MakeSphere :: proc(radius: f32) -> Sphere {
	hd := new(v3d.Sphere)
	hd.center = {0, 0, 0}
	hd.radius = radius
	return Sphere(rawptr(hd))
}

FreeSphere :: proc(s: Sphere) {
	free(rawptr(s))
}

// Axis along local X: the two hemisphere centers at ±length/2.
MakeCapsule :: proc(length, radius: f32) -> Capsule {
	hd := new(v3d.Capsule)
	hd.center1 = {-0.5 * length, 0.0, 0.0}
	hd.center2 = {0.5 * length, 0.0, 0.0}
	hd.radius = radius
	return Capsule(rawptr(hd))
}

FreeCapsule :: proc(c: Capsule) {
	free(rawptr(c))
}

// Generic convex hull from a point cloud (b3CreateHull). `points` is a slice
// of [3]f32 (x,y,z triplets); the world clones the hull on shape creation, so
// the caller may free immediately after CreateHullShape. Returns a Hull handle
// (NULL-typed) on degenerate input — check via `Hull_Base` (returns nil).
Create_Hull :: proc(points: [][3]f32, max_vertex_count: int) -> Hull {
	if len(points) == 0 {
		return Hull(nil)
	}
	h := v3d.CreateHull(raw_data(points), c.int(len(points)), c.int(max_vertex_count))
	return Hull(rawptr(h))
}

Destroy_Hull :: proc(hull: Hull) {
	v3d.DestroyHull((^v3d.HullData)(rawptr(hull)))
}

Hull_Base :: proc(hull: Hull) -> rawptr {
	return rawptr(hull)
}

// Heightfield (b3CreateWave — generic wave heightfield generator).
CreateWave :: proc(rowCount, columnCount: i32, sx, sy, sz, rowFreq, colFreq: f32) -> HeightField {
	hf := v3d.CreateWave(
		c.int(rowCount),
		c.int(columnCount),
		{sx, sy, sz},
		rowFreq,
		colFreq,
		false,
	)
	return HeightField(rawptr(hf))
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
	def := v3d.HeightFieldDef {
		heights             = raw_data(heights),
		materialIndices     = nil,
		scale               = {sx, sy, sz},
		countX              = c.int(countX),
		countZ              = c.int(countZ),
		globalMinimumHeight = minH,
		globalMaximumHeight = maxH,
		clockwiseWinding    = false,
	}
	hf := v3d.CreateHeightField(def)
	return HeightField(rawptr(hf))
}

DestroyHeightField :: proc(hf: HeightField) {
	v3d.DestroyHeightField((^v3d.HeightFieldData)(rawptr(hf)))
}

// World / body / shape operations (match vendor:box3d names).
CreateWorld :: proc(def: WorldDef) -> WorldId {
	d := (^v3d.WorldDef)(rawptr(def))
	return from_v3d_world(v3d.CreateWorld(d^))
}

CreateBody :: proc(world: WorldId, def: BodyDef) -> BodyId {
	d := (^v3d.BodyDef)(rawptr(def))
	return from_v3d_body(v3d.CreateBody(to_v3d_world(world), d^))
}

CreateHullShape :: proc(body: BodyId, def: ShapeDef, hull: rawptr) -> ShapeId {
	d := (^v3d.ShapeDef)(rawptr(def))
	return from_v3d_shape(v3d.CreateHullShape(to_v3d_body(body), d^, (^v3d.HullData)(hull)))
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
	d := (^v3d.ShapeDef)(rawptr(def))
	return from_v3d_shape(
		v3d.CreateTransformedHullShape(
			to_v3d_body(body),
			d^,
			(^v3d.HullData)(hull),
			v3d.Transform{p = local_pos, q = v3d.Quat(1)},
			scale,
		),
	)
}

CreateSphereShape :: proc(body: BodyId, def: ShapeDef, s: Sphere) -> ShapeId {
	d := (^v3d.ShapeDef)(rawptr(def))
	return from_v3d_shape(v3d.CreateSphereShape(to_v3d_body(body), d^, (^v3d.Sphere)(rawptr(s))))
}

CreateCapsuleShape :: proc(body: BodyId, def: ShapeDef, c: Capsule) -> ShapeId {
	d := (^v3d.ShapeDef)(rawptr(def))
	return from_v3d_shape(v3d.CreateCapsuleShape(to_v3d_body(body), d^, (^v3d.Capsule)(rawptr(c))))
}

// The heightfield must outlive the shape: destroy the shape (and world)
// before DestroyHeightField.
CreateHeightFieldShape :: proc(body: BodyId, def: ShapeDef, hf: HeightField) -> ShapeId {
	d := (^v3d.ShapeDef)(rawptr(def))
	return from_v3d_shape(
		v3d.CreateHeightFieldShape(to_v3d_body(body), d^, (^v3d.HeightFieldData)(rawptr(hf))),
	)
}

World_Step :: proc(world: WorldId, dt: f32, substeps: i32) {
	v3d.World_Step(to_v3d_world(world), dt, c.int(substeps))
}

// Destroy a body and every shape and joint attached to it. Do not keep the
// body's shape/joint ids after this (Box3D frees them with the body).
DestroyBody :: proc(body: BodyId) {
	v3d.DestroyBody(to_v3d_body(body))
}

DestroyWorld :: proc(world: WorldId) {
	v3d.DestroyWorld(to_v3d_world(world))
}

// Log sink: toggle Box3D's diagnostic output. Call once at startup; affects
// every Box3D world in the process (the handler is a global in core.c).
Set_Log_Sink :: proc(mode: Log_Sink) {
	switch mode {
	case .Default:
		v3d.SetLogFcn(log_default_cb)
	case .Silent:
		v3d.SetLogFcn(log_silent_cb)
	}
}

// Body transform getters — by-value [3]f32 / [4]f32 (matches vendor:box3d
// returning b3Vec3 / b3Quat). The quaternion is (x, y, z, w).
Body_GetPosition :: proc(body: BodyId) -> [3]f32 {
	return v3d.Body_GetPosition(to_v3d_body(body))
}

Body_GetRotation :: proc(body: BodyId) -> [4]f32 {
	return from_v3d_quat(v3d.Body_GetRotation(to_v3d_body(body)))
}

// Runtime body velocity getters — by-value [3]f32 (matches vendor:box3d
// returning b3Vec3). Linear velocity is world-space; angular velocity is
// world-space (transform into the body frame for roll/pitch/yaw rates).
Body_GetLinearVelocity :: proc(body: BodyId) -> [3]f32 {
	return v3d.Body_GetLinearVelocity(to_v3d_body(body))
}

Body_GetAngularVelocity :: proc(body: BodyId) -> [3]f32 {
	return v3d.Body_GetAngularVelocity(to_v3d_body(body))
}

// Runtime setters (match vendor:box3d: b3Body_SetLinearVelocity etc.).
Body_SetLinearVelocity :: proc(body: BodyId, x, y, z: f32) {
	v3d.Body_SetLinearVelocity(to_v3d_body(body), {x, y, z})
}

Body_SetAngularVelocity :: proc(body: BodyId, x, y, z: f32) {
	v3d.Body_SetAngularVelocity(to_v3d_body(body), {x, y, z})
}

// Flattened touching-contact data for a body. The manifold normal points
// from shape A to shape B in world space; a height-field/mesh triangle index
// is per point (-1 if none). Returned data is a snapshot of the current
// step's contacts.

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
	capacity := v3d.Body_GetContactCapacity(to_v3d_body(body))
	n := min(capacity, c.int(len(out)))
	if n <= 0 {
		return 0
	}
	buf := make([]v3d.ContactData, int(n))
	count := v3d.Body_GetContactData(to_v3d_body(body), raw_data(buf), n)
	for i in 0 ..< int(count) {
		d := buf[i]
		out[i].shape_a = pack_shape(from_v3d_shape(d.shapeIdA))
		out[i].shape_b = pack_shape(from_v3d_shape(d.shapeIdB))
		manifold_count := min(int(d.manifoldCount), int(len(out[i].manifolds)))
		out[i].manifold_count = i32(manifold_count)
		for j in 0 ..< manifold_count {
			m := d.manifolds[j]
			out[i].manifolds[j].nx = m.normal[0]
			out[i].manifolds[j].ny = m.normal[1]
			out[i].manifolds[j].nz = m.normal[2]
			point_count := min(int(m.pointCount), int(len(m.points)))
			out[i].manifolds[j].point_count = i32(point_count)
			for k in 0 ..< point_count {
				pt := m.points[k]
				out[i].manifolds[j].points[k] = Contact_Point {
					ax             = pt.anchorA[0],
					ay             = pt.anchorA[1],
					az             = pt.anchorA[2],
					bx             = pt.anchorB[0],
					by             = pt.anchorB[1],
					bz             = pt.anchorB[2],
					separation     = pt.separation,
					normal_impulse = pt.normalImpulse,
					triangle_index = i32(pt.triangleIndex),
				}
			}
		}
	}
	delete(buf)
	return i32(count)
}

WheelJoint_SetSpinMotorSpeed :: proc(joint: JointId, speed: f32) {
	v3d.WheelJoint_SetSpinMotorSpeed(to_v3d_joint(joint), speed)
}

WheelJoint_SetTargetSteeringAngle :: proc(joint: JointId, radians: f32) {
	v3d.WheelJoint_SetTargetSteeringAngle(to_v3d_joint(joint), radians)
}

// Achieved (current) wheel steering angle in radians (matches
// b3WheelJoint_GetSteeringAngle). Steer *rate* is obtained by
// finite-differencing this across steps (Box3D exposes no steering-rate
// getter), so the caller keeps the previous value.
WheelJoint_GetSteeringAngle :: proc(joint: JointId) -> f32 {
	return v3d.WheelJoint_GetSteeringAngle(to_v3d_joint(joint))
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
	def := v3d.DefaultWheelJointDef()
	def.base.bodyIdA = to_v3d_body(p.bodyA)
	def.base.bodyIdB = to_v3d_body(p.bodyB)
	def.base.localFrameA = v3d.Transform {
		p = p.localFrameA_pos,
		q = to_v3d_quat(p.localFrameA_rot),
	}
	def.base.localFrameB = v3d.Transform {
		p = p.localFrameB_pos,
		q = to_v3d_quat(p.localFrameB_rot),
	}
	def.base.collideConnected = p.collideConnected
	if p.constraintHertz > 0.0 {
		def.base.constraintHertz = p.constraintHertz
	}
	if p.constraintDampingRatio > 0.0 {
		def.base.constraintDampingRatio = p.constraintDampingRatio
	}
	def.enableSuspensionSpring = p.enableSuspensionSpring
	def.suspensionHertz = p.suspensionHertz
	def.suspensionDampingRatio = p.suspensionDampingRatio
	def.enableSuspensionLimit = p.enableSuspensionLimit
	def.lowerSuspensionLimit = p.lowerSuspension
	def.upperSuspensionLimit = p.upperSuspension
	def.enableSpinMotor = p.enableSpinMotor
	def.maxSpinTorque = p.maxSpinTorque
	def.spinSpeed = p.spinSpeed
	def.enableSteering = p.enableSteering
	def.steeringHertz = p.steeringHertz
	def.steeringDampingRatio = p.steeringDampingRatio
	def.targetSteeringAngle = p.targetSteeringAngle
	def.maxSteeringTorque = p.maxSteeringTorque
	def.enableSteeringLimit = p.enableSteeringLimit
	def.lowerSteeringLimit = p.lowerSteering
	def.upperSteeringLimit = p.upperSteering
	return from_v3d_joint(v3d.CreateWheelJoint(to_v3d_world(p.world), def))
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
	world:                  WorldId,
	bodyA, bodyB:           BodyId,
	localFrameA_pos:        [3]f32,
	localFrameA_rot:        [4]f32, // x-axis = joint (slide) axis
	localFrameB_pos:        [3]f32,
	localFrameB_rot:        [4]f32,
	collideConnected:       bool,
	enableSpring:           bool,
	springHertz:            f32,
	springDampingRatio:     f32,
	targetTranslation:      f32,
	enableLimit:            bool,
	lowerTranslation:       f32,
	upperTranslation:       f32,
	enableMotor:            bool,
	maxMotorForce:          f32,
	motorSpeed:             f32,
	// Stiffness of the joint's structural (perpendicular + rotation-lock)
	// constraints; 0 leaves Box3D's default (60 Hz, ratio 2). See the wheel
	// joint's note for why a soft default lets bodies visibly drift off their
	// joint axis under impact.
	constraintHertz:        f32,
	constraintDampingRatio: f32,
}

CreatePrismaticJoint :: proc(p: PrismaticJointDefParams) -> JointId {
	def := v3d.DefaultPrismaticJointDef()
	def.base.bodyIdA = to_v3d_body(p.bodyA)
	def.base.bodyIdB = to_v3d_body(p.bodyB)
	def.base.localFrameA = v3d.Transform {
		p = p.localFrameA_pos,
		q = to_v3d_quat(p.localFrameA_rot),
	}
	def.base.localFrameB = v3d.Transform {
		p = p.localFrameB_pos,
		q = to_v3d_quat(p.localFrameB_rot),
	}
	def.base.collideConnected = p.collideConnected
	if p.constraintHertz > 0.0 {
		def.base.constraintHertz = p.constraintHertz
	}
	if p.constraintDampingRatio > 0.0 {
		def.base.constraintDampingRatio = p.constraintDampingRatio
	}
	def.enableSpring = p.enableSpring
	def.hertz = p.springHertz
	def.dampingRatio = p.springDampingRatio
	def.targetTranslation = p.targetTranslation
	def.enableLimit = p.enableLimit
	def.lowerTranslation = p.lowerTranslation
	def.upperTranslation = p.upperTranslation
	def.enableMotor = p.enableMotor
	def.maxMotorForce = p.maxMotorForce
	def.motorSpeed = p.motorSpeed
	return from_v3d_joint(v3d.CreatePrismaticJoint(to_v3d_world(p.world), def))
}

PrismaticJoint_SetMotorSpeed :: proc(joint: JointId, speed: f32) {
	v3d.PrismaticJoint_SetMotorSpeed(to_v3d_joint(joint), speed)
}

PrismaticJoint_SetMaxMotorForce :: proc(joint: JointId, force: f32) {
	v3d.PrismaticJoint_SetMaxMotorForce(to_v3d_joint(joint), force)
}

PrismaticJoint_SetTargetTranslation :: proc(joint: JointId, translation: f32) {
	v3d.PrismaticJoint_SetTargetTranslation(to_v3d_joint(joint), translation)
}

PrismaticJoint_SetSpringHertz :: proc(joint: JointId, hertz: f32) {
	v3d.PrismaticJoint_SetSpringHertz(to_v3d_joint(joint), hertz)
}

PrismaticJoint_SetSpringDampingRatio :: proc(joint: JointId, damping_ratio: f32) {
	v3d.PrismaticJoint_SetSpringDampingRatio(to_v3d_joint(joint), damping_ratio)
}

// Current translation along the joint axis in meters (b3PrismaticJoint_GetTranslation).
PrismaticJoint_GetTranslation :: proc(joint: JointId) -> f32 {
	return v3d.PrismaticJoint_GetTranslation(to_v3d_joint(joint))
}

// Current translation speed in m/s (b3PrismaticJoint_GetSpeed).
PrismaticJoint_GetSpeed :: proc(joint: JointId) -> f32 {
	return v3d.PrismaticJoint_GetSpeed(to_v3d_joint(joint))
}

// A point on body B pinned to a point on body A; the only DOF is rotation
// about frame A's z-axis.
RevoluteJointDefParams :: struct {
	world:                  WorldId,
	bodyA:                  BodyId,
	bodyB:                  BodyId,
	localFrameA_pos:        [3]f32,
	localFrameA_rot:        [4]f32, // z-axis = hinge axis
	localFrameB_pos:        [3]f32,
	localFrameB_rot:        [4]f32,
	collideConnected:       bool,
	enableSpring:           bool,
	springHertz:            f32,
	springDampingRatio:     f32,
	targetAngle:            f32,
	enableLimit:            bool,
	lowerAngle:             f32,
	upperAngle:             f32,
	enableMotor:            bool,
	maxMotorTorque:         f32,
	motorSpeed:             f32,
	// Stiffness of the joint's structural (anchor + twist) constraints;
	// 0 leaves Box3D's default (60 Hz, ratio 2). See the wheel joint's note
	// for why a soft default lets bodies visibly drift off their joint axis
	// under impact.
	constraintHertz:        f32,
	constraintDampingRatio: f32,
}

CreateRevoluteJoint :: proc(p: RevoluteJointDefParams) -> JointId {
	def := v3d.DefaultRevoluteJointDef()
	def.base.bodyIdA = to_v3d_body(p.bodyA)
	def.base.bodyIdB = to_v3d_body(p.bodyB)
	def.base.localFrameA = v3d.Transform {
		p = p.localFrameA_pos,
		q = to_v3d_quat(p.localFrameA_rot),
	}
	def.base.localFrameB = v3d.Transform {
		p = p.localFrameB_pos,
		q = to_v3d_quat(p.localFrameB_rot),
	}
	def.base.collideConnected = p.collideConnected
	if p.constraintHertz > 0.0 {
		def.base.constraintHertz = p.constraintHertz
	}
	if p.constraintDampingRatio > 0.0 {
		def.base.constraintDampingRatio = p.constraintDampingRatio
	}
	def.targetAngle = p.targetAngle
	def.enableSpring = p.enableSpring
	def.hertz = p.springHertz
	def.dampingRatio = p.springDampingRatio
	def.enableLimit = p.enableLimit
	def.lowerAngle = p.lowerAngle
	def.upperAngle = p.upperAngle
	def.enableMotor = p.enableMotor
	def.maxMotorTorque = p.maxMotorTorque
	def.motorSpeed = p.motorSpeed
	return from_v3d_joint(v3d.CreateRevoluteJoint(to_v3d_world(p.world), def))
}

RevoluteJoint_SetMotorSpeed :: proc(joint: JointId, speed: f32) {
	v3d.RevoluteJoint_SetMotorSpeed(to_v3d_joint(joint), speed)
}

// Current angle in radians relative to the reference (targetAngle at rest).
RevoluteJoint_GetAngle :: proc(joint: JointId) -> f32 {
	return v3d.RevoluteJoint_GetAngle(to_v3d_joint(joint))
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
	def := v3d.DefaultWeldJointDef()
	def.base.bodyIdA = to_v3d_body(p.bodyA)
	def.base.bodyIdB = to_v3d_body(p.bodyB)
	def.base.localFrameA = v3d.Transform {
		p = p.localFrameA_pos,
		q = to_v3d_quat(p.localFrameA_rot),
	}
	def.base.localFrameB = v3d.Transform {
		p = p.localFrameB_pos,
		q = to_v3d_quat(p.localFrameB_rot),
	}
	def.base.collideConnected = p.collideConnected
	def.linearHertz = p.linearHertz
	def.angularHertz = p.angularHertz
	def.linearDampingRatio = p.linearDampingRatio
	def.angularDampingRatio = p.angularDampingRatio
	return from_v3d_joint(v3d.CreateWeldJoint(to_v3d_world(p.world), def))
}
