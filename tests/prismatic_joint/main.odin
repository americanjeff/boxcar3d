// E2E test — engine:physics prismatic joint (shim surface).
//
// Guards the new b3CreatePrismaticJoint shim: create two dynamic boxes
// joined by a prismatic joint (limits + spring + per-frame P-motor), step
// enough frames that the slider moves, verify the translation stays finite
// and within the limits, then destroy the world. A silent shim failure
// (wrong packing, dropped def field) shows up here as a NaN or an
// out-of-range translation before the driving app reaches it.
//
// Build + run via tools/test.sh (needs libphysics_native.a built).

package main

import "core:fmt"
import "core:math"
import "core:os"
import b3 "engine:physics"

TIME_STEP :: f32(1.0 / 60.0)
SUB_STEPS :: 8
STEPS :: 300

// Limits + spring, per the driving strut use-case.
LOWER :: f32(-0.1)
UPPER :: f32(0.25)

mk_box_body :: proc(world: b3.WorldId, pos: [3]f32, half: f32, density: f32) -> b3.BodyId {
	bdef := b3.DefaultBodyDef()
	b3.BodyDef_SetType(bdef, .Dynamic)
	b3.BodyDef_SetPosition(bdef, pos[0], pos[1], pos[2])
	b3.BodyDef_SetEnableSleep(bdef, false)
	body := b3.CreateBody(world, bdef)
	b3.FreeBodyDef(bdef)
	sdef := b3.DefaultShapeDef()
	b3.ShapeDef_SetDensity(sdef, density)
	hull := b3.MakeBoxHull(half, half, half)
	b3.CreateHullShape(body, sdef, b3.BoxHull_Base(hull))
	b3.FreeShapeDef(sdef)
	b3.FreeBoxHull(hull)
	return body
}

main :: proc() {
	failures := 0

	// World with gravity, two 0.4/0.2 m boxes: a heavier "chassis" at the
	// origin and an "axle" hanging 0.3 below it, prismatic joint between
	// them with the slide axis vertical (frame A x-axis rotated to +y).
	wdef := b3.DefaultWorldDef()
	b3.WorldDef_SetGravity(wdef, 0, -10, 0)
	world := b3.CreateWorld(wdef)
	b3.FreeWorldDef(wdef)

	chassis := mk_box_body(world, {0, 0, 0}, 0.4, 5.0)
	axle := mk_box_body(world, {0, -0.3, 0}, 0.2, 20.0)

	// Frame A on the chassis at (0,-0.3,0), x-axis = +y (the slide axis);
	// frame B at the axle body's center. Joint translation starts at 0
	// (frame origins coincide). Limits [LOWER, UPPER], spring pulling back
	// toward translation 0, motor enabled and re-driven per frame below.
	joint := b3.CreatePrismaticJoint(
		{
			world              = world,
			bodyA              = chassis,
			bodyB              = axle,
			localFrameA_pos    = {0, -0.3, 0},
			localFrameA_rot    = b3.QUAT_X_TO_Y,
			localFrameB_pos    = {0, 0, 0},
			localFrameB_rot    = b3.QUAT_IDENTITY,
			collideConnected   = false,
			enableSpring       = true,
			springHertz        = 10.0,
			springDampingRatio = 1.0,
			targetTranslation  = 0.0,
			enableLimit        = true,
			lowerTranslation   = LOWER,
			upperTranslation   = UPPER,
			enableMotor        = true,
			maxMotorForce      = 0.0,
			motorSpeed         = 0.0,
		},
	)

	// Two phases: (A) the driving app's per-frame P-motor — the axle sags
	// under gravity toward translation 0; (B) a constant-velocity motor
	// drives the slider up into the upper limit, which must clamp it.
	// Both drive the setter + getter round trip on the live joint.
	min_t, max_t := f32(1e9), f32(-1e9)
	sag_min_t := f32(0.0)
	nan_seen := false
	for phase in 0 ..< 2 {
		for _ in 0 ..< STEPS / 2 {
			t := b3.PrismaticJoint_GetTranslation(joint)
			if phase == 0 {
				b3.PrismaticJoint_SetMotorSpeed(joint, -20.0 * t)
				b3.PrismaticJoint_SetMaxMotorForce(joint, 2000.0 * (1.0 + 40.0 * t * t))
			} else {
				b3.PrismaticJoint_SetMotorSpeed(joint, 0.5)
				b3.PrismaticJoint_SetMaxMotorForce(joint, 2000.0)
			}
			b3.World_Step(world, TIME_STEP, SUB_STEPS)
			pos := b3.Body_GetPosition(axle)
			if math.is_nan(pos[0]) || math.is_nan(pos[1]) || math.is_nan(pos[2]) {nan_seen = true}
			if math.is_nan(t) {nan_seen = true}
			if t < min_t {min_t = t}
			if t > max_t {max_t = t}
			if phase == 0 && t < sag_min_t {sag_min_t = t}
		}
	}
	b3.DestroyWorld(world)
	if nan_seen {
		fmt.eprintf("FAIL: NaN position or translation\n")
		failures += 1
	}
	// Phase A: the axle sags under gravity (t < 0); no sag at all means the
	// joint is not actually sliding.
	if sag_min_t > -1e-4 {
		fmt.eprintf("FAIL: joint never sagged (min t in phase A %.5f)\n", sag_min_t)
		failures += 1
	}
	// Phase B: the slider must reach the upper limit and be clamped there
	// (with solver tolerance).
	if max_t < UPPER - 0.05 {
		fmt.eprintf("FAIL: upper limit not reached (max t %.4f)\n", max_t)
		failures += 1
	}
	if max_t > UPPER + 0.05 {
		fmt.eprintf("FAIL: translation %.4f above upper limit %.4f\n", max_t, UPPER)
		failures += 1
	}
	// Limits must never be violated by more than solver tolerance.
	if min_t < LOWER - 0.05 {
		fmt.eprintf("FAIL: translation %.4f below lower limit %.4f\n", min_t, LOWER)
		failures += 1
	}

	if failures > 0 {
		fmt.eprintf("\n%d failure(s)\n", failures)
		os.exit(1)
	}
	fmt.println("\nAll prismatic_joint checks passed (300 steps, min_t=", min_t,
		", max_t=", max_t, ")")
}
