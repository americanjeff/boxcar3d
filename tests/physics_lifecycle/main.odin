// E2E test — engine:physics lifecycle (mirrors the app's sim setup).
//
// Guards the `destroy_sim` ordering contract: the heightfield must outlive
// the shape that references it (`b3CreateHeightFieldShape` stores the
// `b3HeightFieldData*` by pointer, it does not clone it — see
// vendor/box3d/src/shape.c). The world's shape holds that pointer, so the
// world must be destroyed before the heightfield.
//
// This test mirrors the app's full sim lifecycle — create a wave heightfield
// + static ground + heightfield shape + dynamic body, step enough frames to
// generate heightfield contacts, then destroy in the contract order (world
// then heightfield). It locks the order in so a future change that swaps the
// calls (or a Box3D revision that dereferences the heightfield during
// `b3DestroyWorld`) is caught here, under a sanitizer, before it reaches the
// app.
//
// Build + run via tools/test.sh (needs libphysics_native.a built).

package main

import "core:fmt"
import "core:os"
import b3 "engine:physics"

TIME_STEP :: f32(1.0 / 60.0)
SUB_STEPS :: 4

// Terrain params kept inline so this test does not depend on an app
// package (which would import apphost).
TERRAIN_COLS :: 96
TERRAIN_ROWS :: 96
TERRAIN_CELL :: f32(2.0)
TERRAIN_AMP :: f32(3.0)
TERRAIN_BUMPS :: 6
TERRAIN_COL_FREQ :: f32(TERRAIN_BUMPS) / f32(TERRAIN_COLS - 1)
TERRAIN_ROW_FREQ :: f32(TERRAIN_BUMPS) / f32(TERRAIN_ROWS - 1)
TERRAIN_OFFSET :: [3]f32 {
	-TERRAIN_CELL * f32(TERRAIN_COLS - 1) / 2.0,
	0.0,
	-TERRAIN_CELL * f32(TERRAIN_ROWS - 1) / 2.0,
}
TERRAIN_SCALE :: [3]f32{TERRAIN_CELL, TERRAIN_AMP, TERRAIN_CELL}

main :: proc() {
	failures := 0

	// Build a world + a static ground carrying a wave heightfield + a dynamic
	// body, exactly as init_sim does, then step a few frames so contacts with
	// the heightfield are actually generated (this is the path that would
	// read the heightfield if Box3D ever does during teardown).
	world_def := b3.DefaultWorldDef()
	b3.WorldDef_SetGravity(world_def, 0, -10, 0)
	world := b3.CreateWorld(world_def)
	b3.FreeWorldDef(world_def)

	ground_def := b3.DefaultBodyDef()
	b3.BodyDef_SetPosition(ground_def, TERRAIN_OFFSET[0], TERRAIN_OFFSET[1], TERRAIN_OFFSET[2])
	ground := b3.CreateBody(world, ground_def)
	b3.FreeBodyDef(ground_def)

	hf := b3.CreateWave(
		TERRAIN_ROWS,
		TERRAIN_COLS,
		TERRAIN_SCALE[0],
		TERRAIN_SCALE[1],
		TERRAIN_SCALE[2],
		TERRAIN_ROW_FREQ,
		TERRAIN_COL_FREQ,
	)
	hf_sd := b3.DefaultShapeDef()
	b3.ShapeDef_SetDensity(hf_sd, 0)
	b3.ShapeDef_SetFriction(hf_sd, 0.7)
	b3.CreateHeightFieldShape(ground, hf_sd, hf)
	b3.FreeShapeDef(hf_sd)

	// A dynamic box dropped onto the terrain so the solver touches the
	// heightfield each step.
	box_def := b3.DefaultBodyDef()
	b3.BodyDef_SetType(box_def, .Dynamic)
	b3.BodyDef_SetPosition(box_def, 0.0, 4.0, 0.0)
	box := b3.CreateBody(world, box_def)
	b3.FreeBodyDef(box_def)
	hull := b3.MakeBoxHull(0.5, 0.5, 0.5)
	sd := b3.DefaultShapeDef()
	b3.ShapeDef_SetDensity(sd, 1.0)
	b3.CreateHullShape(box, sd, b3.BoxHull_Base(hull))
	b3.FreeShapeDef(sd)
	b3.FreeBoxHull(hull)

	for _ in 0 ..< 10 {
		b3.World_Step(world, TIME_STEP, SUB_STEPS)
	}
	pos := b3.Body_GetPosition(box)
	if pos[1] >= 4.0 {
		fmt.eprintf("FAIL: dynamic box did not fall (y=%.3f after 10 steps)\n", pos[1])
		failures += 1
	} else {
		fmt.println("PASS: dynamic box settled to y=", pos[1])
	}

	// ── Destroy the WORLD first (frees the shape that references the
	//    heightfield), THEN the heightfield. See the file header for why.
	b3.DestroyWorld(world)
	b3.DestroyHeightField(hf)

	if failures > 0 {
		fmt.eprintf("\n%d failure(s)\n", failures)
		os.exit(1)
	}
	fmt.println("\nAll physics_lifecycle checks passed.")
}
