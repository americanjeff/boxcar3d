// Body_Model → Box3D bodies + wheel joints. Chassis: one dynamic compound
// body, a convex hull per surface face (the tetrahedron {origin, face}
// tiles the width-profile body, rigid by construction). Wheels: each hangs
// from the chassis on its own wheel joint (suspension DOF along the strut
// axis + spin DOF about the axle, no steering), filter-masked to NOT
// collide with the body or each other.

package main

import "core:math"
import b3 "engine:physics"

// Per-wheel suspension: one shock per wheel, no shared axle. Travel limits
// scale with wheel radius (frac × r); the joint spring IS the shock
// absorber (declarative).
SUSP_LOWER_FRAC :: f32(-0.2) // travel limit, fraction of wheel radius
SUSP_UPPER_FRAC :: f32(0.5) // travel limit, fraction of wheel radius
suspension_hertz :: f32(3.0)
suspension_damping_ratio :: f32(1.0)
STRUT_WHEEL_TRAVEL :: f32(0.5) // vertex → wheel center, along the strut axis

// Joint structural constraint stiffness; Box3D's default (60 Hz, ratio 2)
// lets a light wheel peel off its hub under impact. Do not raise the hertz
// past Box3D's 0.25 / substep-dt clamp without more substeps - the sim
// destabilizes.
JOINT_CONSTRAINT_HERTZ :: f32(120.0)
JOINT_CONSTRAINT_DAMP :: f32(4.0)
// Barrel (piston head) box half-extents (hu along the strut axis, hv in-plane,
// hw lateral z), on the chassis around each wheel's suspension anchor.
HEAD_HU, HEAD_HV, HEAD_HW :: f32(0.2), f32(0.1), f32(0.05) // 0.4×0.2×0.1 barrel

// Mass-scaled spin torque: per wheel, maxSpinTorque = total_mass ·
// mass_mult · g / n_on. No 1/r term: the spin-speed target (pid_drive_car),
// not the torque, is what r scales. Density/size genes change feel (inertia,
// collisions), not capability; mass_mult is the single tuning knob (the
// `--mass-mult` flag overrides it).
mass_mult := f32(1.5)

// Wheel density; the fallback for zero-density genome wheels.
WHEEL_DENSITY :: f32(12.0)

// Chassis triangle density: the fallback for zero-density genomes
// (Body_Model.chassis_density). The body is thin, so it needs enough
// density to carry real mass.
TRIANGLE_DENSITY :: f32(0.5)

// Contact friction, 10 on every fixture. Combined μ = √(f₁·f₂) = 10
// against the 10 terrain. Package var: the `--mu` / `--legacy-physics`
// flags override it; rolling resistance is fixed.
chassis_friction := f32(10.0)
wheel_friction := f32(10.0)
ROLLING_RESISTANCE :: f32(0.05)
// Restitution; the terrain's own value is 0.0.
chassis_restitution := f32(0.05)
wheel_restitution := f32(0.1)

// Shape filter categories. Chassis and wheels each collide only with the
// terrain (default category 0x1): wheels never hit the body or each other.
CAT_TERRAIN :: u64(0x1)
CAT_CHASSIS :: u64(0x2)
CAT_WHEEL :: u64(0x4)

// ─── Assembled bot ────────────────────────────────────────────────────
Wheel_Joint :: struct {
	wheel_l:      b3.BodyId, // left wheel body of the pair  (−Z)
	wheel_r:      b3.BodyId, // right wheel body of the pair (+Z)
	joint_l:      b3.JointId, // left spin joint
	joint_r:      b3.JointId, // right spin joint
	radius:       f32, // wheel radius from Body_Model (genome-derived); render scales the sphere mesh by this
	density:      f32, // wheel density (genome-derived); render shades the sphere by it
	spin_torque:  f32, // mass-scaled max spin torque (per wheel)
	// Render-only pose data (render draws the barrels from these frames).
	mount:        [3]f32, // mount vertex in the chassis frame
	strut_axis:   [3]f32, // strut axis in the chassis frame (gene axle_angle)
	z_half:       f32, // half-width at the mount vertex; the wheels sit at ±(z_half + radius) so their inboard points are coplanar with the mount corner
	z_center:     f32, // half-width at the polygon center (render: piston corner interpolates corner → center)
	mount_vertex: int, // sorted-ring index of the mount vertex - the chassis SEGMENT this pair hangs from (its break takes the pair with it)
}

// One shed chassis segment: a fire-and-forget dynamic body carrying the
// segment's hulls (+ strut boxes), spawned at the chassis's pose/velocity the
// moment it broke. The broken pair's old wheel bodies are NOT part of the
// debris body - they simply outlive their destroyed joint, jointless.
Debris :: struct {
	body: b3.BodyId,
	seg:  int, // which segment this shard carries (render: its faces)
}

Bot :: struct {
	chassis:         b3.BodyId, // compound hull body (one hull shape per surface triangle)
	wheels:          [dynamic]Wheel_Joint, // one per enabled genome wheel, in Body_Model order
	mass:            f32, // assembled chassis mass (hulls + strut boxes)
	// Total assembled mass (chassis + all wheel spheres), computed analytically
	// BEFORE any body is created (mass-scaled joint parameters need it).
	total_mass:      f32,
	chassis_density: f32, // effective chassis density (genome-derived); render shades the body by it
	// Segment = sorted-ring vertex i: it owns tris[4i..4i+3] (the two caps +
	// the two belt triangles) and the wheels mounted at it.
	seg_mass:        [8]f32, // analytical mass per segment (hulls + strut boxes)
	seg_wedge:       [8]bool, // segment carries a wedge hull (NOT a skipped degenerate wedge) - the break check only applies to these: a wheel-only segment is strut-box-mass, and its impulse/mass ratio would explode on trivial contact
	seg_shapes:      [8][dynamic]u64, // packed shape ids of the segment's hulls (contact → segment)
	broken:          [8]bool, // segment broke (shed as debris)
	n_breaks:        int, // segments broken so far (run fails at MAX_BREAKS)
	group_index:     i32, // shape filter group the rebuild must keep
	debris:          [dynamic]Debris, // shed segments, in break order
}

destroy_bot :: proc(bot: ^Bot) {
	if len(bot.wheels) > 0 {delete(bot.wheels)}
	for i in 0 ..< 8 {
		if len(bot.seg_shapes[i]) > 0 {delete(bot.seg_shapes[i])}
	}
	// Debris bodies are fire-and-forget, but the world owns them - retire
	// them before the world goes (destroy_sim calls this first).
	for d in bot.debris {b3.DestroyBody(d.body)}
	if len(bot.debris) > 0 {delete(bot.debris)}
	bot^ = {}
}

// Lowest point of the assembled bot in the body frame (relative to the COM
// at the origin), at yaw 0. Used to lift the spawn so the lowest point
// sits SPAWN_GAP above the terrain.
lowest_point_of :: proc(bm: ^Body_Model) -> f32 {
	lowest := f32(0.0)
	for t in bm.tris {
		for pt in t.points {
			if pt[1] < lowest {lowest = pt[1]}
		}
	}
	for w in bm.wheels {
		wb := w.pos[1] + STRUT_WHEEL_TRAVEL * w.strut_axis[1] - w.radius
		if wb < lowest {lowest = wb}
	}
	return lowest
}

// Build a quaternion that rotates the +x axis onto a target unit axis (used
// to orient the wheel-joint frame A so its x-axis = the strut axis).
quat_x_to :: proc(target: [3]f32) -> [4]f32 {
	// Rotate +x onto target about the axis cross(+x, target), angle acos(dot).
	if math.abs(target[0] - 1.0) < 1e-4 {return b3.QUAT_IDENTITY}
	axis := [3]f32{0.0, -target[2], target[1]} // (1,0,0) × target
	al := math.sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
	if al < 1e-4 {
		// target ≈ -x: rotate 180° about y.
		return b3.Quat_From_Axis_Angle({0.0, 1.0, 0.0}, f32(math.PI))
	}
	axis = {axis[0] / al, axis[1] / al, axis[2] / al}
	ang := math.acos(math.clamp(target[0], -1.0, 1.0))
	return b3.Quat_From_Axis_Angle(axis, f32(ang))
}

// Spawn orientation: roll about the body's forward axis (+x; 180° puts the
// belly down) followed by yaw about world +Y. Closed form for q_yaw ⊗ q_roll
// in the engine's (x, y, z, w) layout (see QUAT_IDENTITY) - degenerates to
// the plain yaw quat at roll = 0.
spawn_quat :: proc(yaw, roll: f32) -> [4]f32 {
	cy, sy := math.cos(yaw / 2), math.sin(yaw / 2)
	cr, sr := math.cos(roll / 2), math.sin(roll / 2)
	return {cy * sr, sy * cr, -sy * sr, cy * cr}
}

// Create one convex hull shape on `chassis` for the tetrahedron {origin,
// a, b, c}, which tiles the body (star-shaped from the genome center).
// Returns (mass = volume × density, the new shape id, and whether a shape
// was created, so the caller can track which segment a contact hit). Box3D
// returns a NULL hull for degenerate input (collinear / coplanar points):
// no shape is created and the mass contribution is 0.
add_tri_hull :: proc(
	chassis: b3.BodyId,
	a, b, c: [3]f32,
	group_index: i32,
	density: f32,
) -> (
	f32,
	b3.ShapeId,
	bool,
) {
	pts := [4][3]f32{{0.0, 0.0, 0.0}, a, b, c}
	hull := b3.Create_Hull(pts[:], 4)
	if b3.Hull_Base(hull) == nil {
		// Degenerate tetrahedron: nothing to collide. (fan_wedge_degenerate
		// keeps this from happening in practice.)
		return 0.0, b3.ShapeId{}, false
	}
	sd := b3.DefaultShapeDef()
	b3.ShapeDef_SetDensity(sd, density)
	b3.ShapeDef_SetFriction(sd, chassis_friction)
	b3.ShapeDef_SetRestitution(sd, chassis_restitution)
	b3.ShapeDef_SetFilter(sd, CAT_CHASSIS, CAT_TERRAIN, group_index)
	sid := b3.CreateTransformedHullShape(
		chassis,
		sd,
		b3.Hull_Base(hull),
		{0.0, 0.0, 0.0},
		{1.0, 1.0, 1.0},
	)
	b3.FreeShapeDef(sd)
	b3.Destroy_Hull(hull)
	// Tetrahedron volume = |a·(b×c)| / 6; mass = volume × density.
	cross := [3]f32 {
		b[1] * c[2] - b[2] * c[1],
		b[2] * c[0] - b[0] * c[2],
		b[0] * c[1] - b[1] * c[0],
	}
	vol := math.abs(a[0] * cross[0] + a[1] * cross[1] + a[2] * cross[2]) / 6.0
	return density * vol, sid, true
}

// Create one convex hull shape on `body` for the box centered at `center`
// with half-extents (hu, hv, hw) along the orthonormal axes (u, v, w): a
// box ORIENTED in the body frame (the engine's transformed-hull path is
// axis-aligned only). Chassis filtering - the strut boxes ride along with
// the chassis.
add_oriented_box :: proc(
	body: b3.BodyId,
	center, u, v, w: [3]f32,
	hu, hv, hw: f32,
	group_index: i32,
	density: f32,
) -> (
	f32,
	b3.ShapeId,
) {
	corners := [8][3]f32{}
	s2 := [2]f32{-1.0, 1.0}
	i := 0
	for su in s2 {
		for sv in s2 {
			for sw in s2 {
				corners[i][0] = center[0] + su * hu * u[0] + sv * hv * v[0] + sw * hw * w[0]
				corners[i][1] = center[1] + su * hu * u[1] + sv * hv * v[1] + sw * hw * w[1]
				corners[i][2] = center[2] + su * hu * u[2] + sv * hv * v[2] + sw * hw * w[2]
				i += 1
			}
		}
	}
	hull := b3.Create_Hull(corners[:], 8)
	sd := b3.DefaultShapeDef()
	b3.ShapeDef_SetDensity(sd, density)
	b3.ShapeDef_SetFriction(sd, chassis_friction)
	b3.ShapeDef_SetRestitution(sd, chassis_restitution)
	b3.ShapeDef_SetFilter(sd, CAT_CHASSIS, CAT_TERRAIN, group_index)
	sid := b3.CreateHullShape(body, sd, b3.Hull_Base(hull))
	b3.FreeShapeDef(sd)
	b3.Destroy_Hull(hull)
	return 8.0 * hu * hv * hw * density, sid
}

// Analytical mass of one wheel PAIR (two spheres): 2 × (4/3)·π·r³·ρ.
wheel_pair_mass :: proc(radius, density: f32) -> f32 {
	return 2.0 * (4.0 / 3.0) * math.PI * radius * radius * radius * density
}

// Add segment `seg`'s hulls to `body`: its 4 surface triangles
// (tris[4·seg..4·seg+3]) and the strut barrel of every wheel mounted at
// the segment's vertex. Returns the added mass. With `record`, the shape
// ids are packed into bot.seg_shapes[seg] - the contact→segment map the
// break check needs; the debris bodies don't track them.
add_segment_hulls :: proc(
	bot: ^Bot,
	body: b3.BodyId,
	bm: ^Body_Model,
	seg: int,
	record: bool,
	group_index: i32,
	density: f32,
) -> f32 {
	m := f32(0.0)
	// Degenerate segments (fan_wedge_degenerate) carry no tetrahedral
	// hulls. Their wheels (below) are unaffected: the strut boxes + wheel
	// bodies are independent shapes. A hull-less, wheel-less segment is
	// massless and can never trip the break check (0 impulse > 0 mass·K is
	// false), so no NaN path exists.
	if !bm.degenerate[seg] {
		for s in 0 ..< 4 {
			t := bm.tris[4 * seg + s]
			m2, sid, created := add_tri_hull(
				body,
				t.points[0],
				t.points[1],
				t.points[2],
				group_index,
				density,
			)
			m += m2
			if record && created {append(&bot.seg_shapes[seg], b3.ShapeId_Pack(sid))}
		}
	}
	for k in 0 ..< len(bm.wheels) {
		w := &bm.wheels[k]
		if w.mount_vertex != seg {continue}
		u := w.strut_axis
		v := [3]f32{u[1], -u[0], 0.0}
		zw := [3]f32{0.0, 0.0, 1.0}
		tw := w.z_half + w.radius
		sides := [2]f32{-tw, +tw}
		for z_off in sides {
			barrel := [3]f32 {
				w.pos[0] + STRUT_WHEEL_TRAVEL * u[0],
				w.pos[1] + STRUT_WHEEL_TRAVEL * u[1],
				z_off,
			}
			m2, sid := add_oriented_box(
				body,
				barrel,
				u,
				v,
				zw,
				HEAD_HU,
				HEAD_HV,
				HEAD_HW,
				group_index,
				density,
			)
			m += m2
			if record {append(&bot.seg_shapes[seg], b3.ShapeId_Pack(sid))}
		}
	}
	if record {bot.seg_mass[seg] = m}
	return m
}

// Assemble the Body_Model into a compound rigid chassis body + wheel bodies
// + wheel joints at the given world spawn pose. `spawn_y` is the COM
// (genome-center) world Y (the caller computes it from terrain +
// lowest_point_of + SPAWN_GAP); the chassis origin is the genome center.
// `group_index`: 0 → default filtering; negative → all shapes share that
// group and never collide with each other (the pop viewer).
build_bot :: proc(
	world: b3.WorldId,
	bm: ^Body_Model,
	spawn_x, spawn_y, spawn_z, yaw: f32,
	roll: f32 = 0.0, // spawn roll about the forward axis (tip probe)
	group_index: i32 = 0,
) -> Bot {
	wheels := make([dynamic]Wheel_Joint, 0, len(bm.wheels))

	// One dynamic chassis body, origin at the genome center, spawned with the
	// drive yaw (nose +x at yaw 0).
	chassis_pos := [3]f32{spawn_x, spawn_y, spawn_z}
	chassis_rot := spawn_quat(yaw, roll)
	def := b3.DefaultBodyDef()
	b3.BodyDef_SetType(def, .Dynamic)
	b3.BodyDef_SetPosition(def, chassis_pos[0], chassis_pos[1], chassis_pos[2])
	b3.BodyDef_SetRotation(def, chassis_rot)
	b3.BodyDef_SetEnableSleep(def, false)
	chassis := b3.CreateBody(world, def)
	b3.FreeBodyDef(def)

	chassis_density := bm.chassis_density
	if chassis_density <= 0.0 {chassis_density = TRIANGLE_DENSITY}

	bot := Bot {
		chassis     = chassis,
		group_index = group_index,
	}

	// One hull per surface face, added per segment. Fixed per-segment
	// order, so the shape-id bookkeeping the break check uses (contact →
	// segment) is deterministic. Box3D clones the hull per shape.
	mass_total := f32(0.0)
	for i in 0 ..< 8 {
		bot.seg_wedge[i] = !bm.degenerate[i]
		mass_total += add_segment_hulls(&bot, chassis, bm, i, true, group_index, chassis_density)
	}

	// Total assembled mass, analytical and BEFORE the wheel bodies exist:
	// the chassis hulls (barrel boxes included) + one sphere pair per
	// enabled wheel. apply_breaks' rebuild keeps the same bookkeeping
	// (bot.mass + surviving wheel pairs).
	total_mass := mass_total
	for w in bm.wheels {
		d := w.density
		if d <= 0.0 {d = WHEEL_DENSITY}
		total_mass += wheel_pair_mass(w.radius, d)
	}

	// Wheels: each genome wheel becomes a left/right pair along the body
	// lateral z, each on its own chassis wheel joint. Both wheels in a pair
	// share one spin actuator; the pair is the unit the controller drives.
	// All pairs are powered.
	for i in 0 ..< len(bm.wheels) {
		w := &bm.wheels[i]
		d := w.density
		if d <= 0.0 {d = WHEEL_DENSITY}
		// Mass-scaled spin torque for this pair (see mass_mult).
		spin_torque := total_mass * mass_mult * gravity / f32(2 * len(bm.wheels))

		tw := w.z_half + w.radius // track half-width: mount depth + radius
		wl, jl := make_wheel(
			world,
			chassis,
			w^,
			-tw,
			chassis_pos,
			chassis_rot,
			group_index,
			d,
			spin_torque,
		)
		wr, jr := make_wheel(
			world,
			chassis,
			w^,
			+tw,
			chassis_pos,
			chassis_rot,
			group_index,
			d,
			spin_torque,
		)
		append(
			&wheels,
			Wheel_Joint {
				wheel_l = wl,
				joint_l = jl,
				wheel_r = wr,
				joint_r = jr,
				radius = w.radius,
				density = d,
				spin_torque = spin_torque,
				mount = w.pos,
				strut_axis = w.strut_axis,
				z_half = w.z_half,
				z_center = bm.heights[8],
				mount_vertex = w.mount_vertex,
			},
		)
	}

	bot.wheels = wheels
	bot.mass = mass_total
	bot.total_mass = total_mass
	bot.chassis_density = chassis_density
	return bot
}

// Shed the given segments off the chassis. Each broken segment becomes a
// fire-and-forget debris body (its hulls + strut boxes at the chassis's
// current pose and velocity); the chassis is rebuilt from the surviving
// segments at the SAME pose, and surviving wheel pairs get new bodies +
// joints at their rest position (the suspension excursion at the break is
// dropped). `segs`: unbroken, live indices, ascending. Broken pairs' OLD
// wheel bodies are NOT destroyed - Box3D kills a body's joints with the
// body, so they survive as jointless free debris. The caller records
// n_breaks and the failure at MAX_BREAKS.
apply_breaks :: proc(world: b3.WorldId, bm: ^Body_Model, bot: ^Bot, segs: []int) {
	chassis_pos := b3.Body_GetPosition(bot.chassis)
	chassis_rot := b3.Body_GetRotation(bot.chassis)
	lv := b3.Body_GetLinearVelocity(bot.chassis)
	av := b3.Body_GetAngularVelocity(bot.chassis)

	// 1. Debris bodies for each broken segment (ascending order).
	for s in segs {
		def := b3.DefaultBodyDef()
		b3.BodyDef_SetType(def, .Dynamic)
		b3.BodyDef_SetPosition(def, chassis_pos[0], chassis_pos[1], chassis_pos[2])
		b3.BodyDef_SetRotation(def, chassis_rot)
		b3.BodyDef_SetLinearVelocity(def, lv[0], lv[1], lv[2])
		b3.BodyDef_SetAngularVelocity(def, av[0], av[1], av[2])
		b3.BodyDef_SetEnableSleep(def, false)
		dep := b3.CreateBody(world, def)
		b3.FreeBodyDef(def)
		add_segment_hulls(nil, dep, bm, s, false, bot.group_index, bot.chassis_density)
		append(&bot.debris, Debris{body = dep, seg = s})
		bot.broken[s] = true
	}
	// The rebuild below must produce a body with at least one shape: a
	// shapeless, mass-0 dynamic body is a solver hazard. The caller's break
	// budget (check_breaks caps the batch below 8) guarantees this.
	survivors := 0
	for i in 0 ..< 8 {
		if !bot.broken[i] {survivors += 1}
	}
	ensure(survivors > 0)

	// 2. Retire surviving pairs' old wheels, then the old chassis itself
	//    (its remaining joints die with it).
	for w in bot.wheels {
		if bot.broken[w.mount_vertex] {continue}
		b3.DestroyBody(w.wheel_l)
		b3.DestroyBody(w.wheel_r)
	}
	b3.DestroyBody(bot.chassis)

	// 3. New chassis body at the same pose, from the surviving segments.
	def := b3.DefaultBodyDef()
	b3.BodyDef_SetType(def, .Dynamic)
	b3.BodyDef_SetPosition(def, chassis_pos[0], chassis_pos[1], chassis_pos[2])
	b3.BodyDef_SetRotation(def, chassis_rot)
	b3.BodyDef_SetLinearVelocity(def, lv[0], lv[1], lv[2])
	b3.BodyDef_SetAngularVelocity(def, av[0], av[1], av[2])
	b3.BodyDef_SetEnableSleep(def, false)
	nchassis := b3.CreateBody(world, def)
	b3.FreeBodyDef(def)
	bot.mass = f32(0.0)
	for i in 0 ..< 8 {
		if bot.broken[i] {continue}
		delete(bot.seg_shapes[i])
		bot.seg_shapes[i] = make([dynamic]u64, 0, 6)
		bot.seg_wedge[i] = !bm.degenerate[i]
		bot.mass += add_segment_hulls(
			bot,
			nchassis,
			bm,
			i,
			true,
			bot.group_index,
			bot.chassis_density,
		)
	}
	bot.chassis = nchassis

	// 4. Surviving pairs: fresh wheels + joints at the current chassis pose,
	//    with the recomputed mass-scaled spin torque (over the pairs still on).
	n_alive := 0
	for w in bot.wheels {
		if !bot.broken[w.mount_vertex] {n_alive += 1}
	}
	bot.total_mass = bot.mass
	for w in bot.wheels {
		if bot.broken[w.mount_vertex] {continue}
		bot.total_mass += wheel_pair_mass(w.radius, w.density)
	}
	torque := f32(0.0)
	if n_alive > 0 {torque = bot.total_mass * mass_mult * gravity / f32(2 * n_alive)}
	for i in 0 ..< len(bot.wheels) {
		w := &bot.wheels[i]
		if bot.broken[w.mount_vertex] {continue}
		tw := w.z_half + w.radius
		w.wheel_l, w.joint_l = make_wheel(
			world,
			nchassis,
			bm.wheels[i],
			-tw,
			chassis_pos,
			chassis_rot,
			bot.group_index,
			w.density,
			torque,
		)
		w.wheel_r, w.joint_r = make_wheel(
			world,
			nchassis,
			bm.wheels[i],
			+tw,
			chassis_pos,
			chassis_rot,
			bot.group_index,
			w.density,
			torque,
		)
		w.spin_torque = torque
	}
}

// Per-wheel suspension travel from REST (meters, signed along the strut
// axis: + = extension, − = compression), computed from poses - joint
// translation 0 is at the rest anchor, so this is the spring's live
// excursion (bounded by SUSP_{LOWER,UPPER}_FRAC × r).
suspension_travel :: proc(bot: ^Bot, pair: int, side: f32) -> f32 {
	w := bot.wheels[pair]
	body := w.wheel_l
	if side > 0 {body = w.wheel_r}
	pos, quat := b3.Body_GetPosition(bot.chassis), b3.Body_GetRotation(bot.chassis)
	wpos := b3.Body_GetPosition(body)
	// Rest anchor in world: chassis frame · (mount + STRUT_WHEEL_TRAVEL·u + side·(z_half + radius)·ẑ).
	anchor_local := [3]f32 {
		w.mount[0] + STRUT_WHEEL_TRAVEL * w.strut_axis[0],
		w.mount[1] + STRUT_WHEEL_TRAVEL * w.strut_axis[1],
		side * (w.z_half + w.radius),
	}
	rot := quat_rotv(quat, anchor_local)
	u := quat_rotv(quat, w.strut_axis)
	dx := wpos[0] - (pos[0] + rot[0])
	dy := wpos[1] - (pos[1] + rot[1])
	dz := wpos[2] - (pos[2] + rot[2])
	return dx * u[0] + dy * u[1] + dz * u[2]
}

// Set one pair wheel's spin-motor speed target (rad/s).
set_wheel_spin_speed :: proc(j: b3.JointId, speed: f32) {
	b3.WheelJoint_SetSpinMotorSpeed(j, speed)
}

// Per-frame angular damping on every bot body, preserving the wheels' spin
// component (their spin is the drive). Sphere wheels give no tire-like
// lateral slip stiffness, so a P steering loop hunts into a yaw limit
// cycle; the wheels carry ~half the yaw inertia (parallel-axis), so they
// are damped too - minus the spin-axis component the spin motor owns.
// Box3D semantics: w *= max(0, 1 - d·dt) per step.
damp_wobble :: proc(bot: ^Bot) {
	factor := 1.0 - BODY_ANGULAR_DAMPING * TIME_STEP
	if factor < 0.0 {factor = 0.0}
	damp_angular(bot.chassis, factor)
	for w in bot.wheels {
		damp_wheel(w.wheel_l, factor)
		damp_wheel(w.wheel_r, factor)
	}
}

// Damp a body's angular velocity about every axis.
damp_angular :: proc(id: b3.BodyId, factor: f32) {
	av := b3.Body_GetAngularVelocity(id)
	b3.Body_SetAngularVelocity(id, av[0] * factor, av[1] * factor, av[2] * factor)
}

// Damp a wheel's angular velocity EXCEPT along its spin axis (local +z):
// the spin motor owns that component; only the wobble components (yaw,
// kingpin/steer, precession) are damped.
damp_wheel :: proc(id: b3.BodyId, factor: f32) {
	av := b3.Body_GetAngularVelocity(id)
	spin := wheel_spin_axis(id)
	s := av[0] * spin[0] + av[1] * spin[1] + av[2] * spin[2]
	// w = spin component (kept) + damped remainder.
	b3.Body_SetAngularVelocity(
		id,
		spin[0] * s + (av[0] - spin[0] * s) * factor,
		spin[1] * s + (av[1] - spin[1] * s) * factor,
		spin[2] * s + (av[2] - spin[2] * s) * factor,
	)
}

// A wheel body's spin axis (local +z) in world space.
wheel_spin_axis :: proc(id: b3.BodyId) -> [3]f32 {
	q := b3.Body_GetRotation(id)
	qx, qy, qz, qw := q[0], q[1], q[2], q[3]
	// rot · (0,0,1)
	return [3]f32{2 * (qx * qz + qw * qy), 2 * (qy * qz - qw * qx), 1 - 2 * (qx * qx + qy * qy)}
}

// Build one wheel of a pair at lateral offset `z_off` (body frame,
// ±(z_half + radius)); the wheel hangs from the chassis on its own wheel
// joint. `parent_pos`/`parent_rot` are the parent's CURRENT pose (spawn at
// first build, live pose on a break rebuild). `density` in kg/m³;
// `max_spin_torque` is the mass-scaled spin torque (see mass_mult).
// Returns (wheel body, spin joint).
make_wheel :: proc(
	world: b3.WorldId,
	parent: b3.BodyId,
	w: Wheel_Mount,
	z_off: f32,
	parent_pos: [3]f32,
	parent_rot: [4]f32,
	group_index: i32,
	density: f32,
	max_spin_torque: f32,
) -> (
	b3.BodyId,
	b3.JointId,
) {
	// Wheel center in the parent frame - the joint's frame-A anchor below is
	// the same point, and the wheel body's origin must sit on it at spawn.
	wheel_center := [3]f32 {
		STRUT_WHEEL_TRAVEL * w.strut_axis[0],
		STRUT_WHEEL_TRAVEL * w.strut_axis[1],
		z_off,
	}
	wheel_center[0] += w.pos[0]
	wheel_center[1] += w.pos[1]
	world_off := quat_rotv(parent_rot, wheel_center)
	wpos := [3]f32 {
		parent_pos[0] + world_off[0],
		parent_pos[1] + world_off[1],
		parent_pos[2] + world_off[2],
	}

	wdef := b3.DefaultBodyDef()
	b3.BodyDef_SetType(wdef, .Dynamic)
	b3.BodyDef_SetPosition(wdef, wpos[0], wpos[1], wpos[2])
	// Orient the wheel body so its local +z (the axle) = world axle (the
	// parent rotation maps body +z to the world axle).
	b3.BodyDef_SetRotation(wdef, parent_rot)
	b3.BodyDef_SetAllowFastRotation(wdef, true)
	b3.BodyDef_SetEnableSleep(wdef, false)
	wbody := b3.CreateBody(world, wdef)
	b3.FreeBodyDef(wdef)

	// Physics wheel = a sphere (smooth rolling, no facet bounce).
	wsd := b3.DefaultShapeDef()
	b3.ShapeDef_SetDensity(wsd, density)
	b3.ShapeDef_SetFriction(wsd, wheel_friction)
	b3.ShapeDef_SetRestitution(wsd, wheel_restitution)
	b3.ShapeDef_SetRollingResistance(wsd, ROLLING_RESISTANCE)
	b3.ShapeDef_SetFilter(wsd, CAT_WHEEL, CAT_TERRAIN, group_index)
	sphere := b3.MakeSphere(w.radius)
	b3.CreateSphereShape(wbody, wsd, sphere)
	b3.FreeShapeDef(wsd)
	b3.FreeSphere(sphere)

	// The joint's frame A anchor in the parent's frame: the wheel's REST
	// center (the same point as the spawn position above).
	frame_a := [3]f32 {
		STRUT_WHEEL_TRAVEL * w.strut_axis[0],
		STRUT_WHEEL_TRAVEL * w.strut_axis[1],
		z_off,
	}
	frame_a[0] += w.pos[0]
	frame_a[1] += w.pos[1]

	// A wheel joint chassis → wheel with both DOFs: suspension (prismatic
	// along frame A x = the strut axis, spring + travel limits) and spin
	// (about frame B z = the axle, motor); steering disabled. The frame A
	// anchor is the wheel's REST center, so translation 0 = rest and the
	// limits are ± travel around it.
	// NOTE: a diagonal (vertex → inner-equator) suspension axis is NOT
	// representable - Box3D builds frame A orthonormal, so the suspension
	// axis must be ⊥ to the axle (frame A z = the lateral chassis z); the
	// diagonal piston is the VISUAL arrangement (render) over this
	// in-plane DOF.
	joint := b3.CreateWheelJoint(
		{
			world = world,
			bodyA = parent,
			bodyB = wbody,
			localFrameA_pos = frame_a,
			localFrameA_rot = quat_x_to(w.strut_axis),
			localFrameB_pos = {0.0, 0.0, 0.0},
			localFrameB_rot = b3.QUAT_IDENTITY,
			collideConnected = false,
			enableSuspensionSpring = true,
			suspensionHertz = suspension_hertz,
			suspensionDampingRatio = suspension_damping_ratio,
			enableSuspensionLimit = true,
			lowerSuspension = SUSP_LOWER_FRAC * w.radius,
			upperSuspension = SUSP_UPPER_FRAC * w.radius,
			constraintHertz = JOINT_CONSTRAINT_HERTZ,
			constraintDampingRatio = JOINT_CONSTRAINT_DAMP,
			enableSpinMotor = true,
			maxSpinTorque = max_spin_torque,
			spinSpeed = 0.0,
			enableSteering = false,
		},
	)
	return wbody, joint
}
