// The boxcar2d genome: the chromosome for the car body.
// Pure data, no physics, no Box3D; the source of truth for the car's shape
// - body_model.odin derives the phenotype (Body_Model) from it by a pure
// function.
//
// App content: the boxcar2d chromosome vocabulary + the fixed car.

package main

import "core:math"

// Chassis vertex. 8 vertices radiate from the center (body-frame origin,
// ≈ COM), connected to it as triangles (boxcar2d convention). Genome plane
// → body frame: x = forward, y = up; the polygon is the chassis centerline
// at z=0, widened laterally in body_model.odin.
Vertex :: struct {
	angle:     f32, // radians, direction from the center
	magnitude: f32, // distance from the center
}

// One wheel; `vertex == -1` disables it.
Wheel_Def :: struct {
	vertex:     int, // index into Genome.vertices; -1 = disabled
	axle_angle: f32, // axle orientation (radians)
	radius:     f32, // wheel radius (metres)
	density:    f32, // wheel density (kg/m³)
}

// Chassis width profile: half-widths in metres (lateral z). Index 0..7 is
// the half-width at each genome vertex, index 8 at the polygon center.
// The chassis width is a directly evolved axis.
N_WIDTHS :: 9

Genome :: struct {
	vertices:        [8]Vertex, // fixed count (boxcar2d convention)
	wheels:          [dynamic]Wheel_Def, // 0..N_WHEELS wheels; -1 vertex disables
	widths:          [N_WIDTHS]f32, // width profile (see above); center at [8]
	chassis_density: f32, // chassis hull density (kg/m³)
}

// Position of genome vertex `i` in the body frame (x = cos·mag, y = sin·mag,
// z = 0); the genome plane is forward × up.
genome_vertex_pos :: proc(genome: ^Genome, i: int) -> [3]f32 {
	v := genome.vertices[i]
	return {math.cos(v.angle) * v.magnitude, math.sin(v.angle) * v.magnitude, 0.0}
}

// Free a Genome's owned dynamic array (the wheels).
destroy_genome :: proc(genome: ^Genome) {
	if len(genome.wheels) > 0 {delete(genome.wheels)}
	genome^ = {}
}

// The fixed car: an elongated cross-section in the forward×up plane
// (~3.0 m long, ~1.6 m tall). Two powered wheels at distinct front/rear
// mounting positions on the bottom edge. Wheel order = actuator order.
//
//   vertices (CCW from nose, radians; 0° = forward +x, 90° = up +y):
//     0  front nose        ( 1.50,  0.00)
//     1  front-top         ( 0.90,  0.63)
//     2  top-front         ( 0.27,  0.75)
//     3  top-rear          (-0.27,  0.75)
//     4  rear-top          (-0.90,  0.63)
//     5  rear nose         (-1.50,  0.00)
//     6  rear-bottom       (-0.85, -0.85)   ← rear wheel mount
//     7  front-bottom      ( 0.85, -0.85)   ← front wheel mount
//
//	   wheels (actuator order): both powered.
//	     0: rear  wheel, vertex 6, axle ±z, radius 0.5
//	     1: front wheel, vertex 7, axle ±z, radius 0.5
//	   densities: chassis TRIANGLE_DENSITY, wheels WHEEL_DENSITY.
fixed_genome :: proc() -> Genome {
	g := Genome {
		vertices        = {
			{0.0, 1.5},
			{35.0 * math.PI / 180.0, 1.1},
			{70.0 * math.PI / 180.0, 0.8},
			{110.0 * math.PI / 180.0, 0.8},
			{145.0 * math.PI / 180.0, 1.1},
			{math.PI, 1.5},
			{225.0 * math.PI / 180.0, 1.2},
			{315.0 * math.PI / 180.0, 1.2},
		},
		wheels          = make([dynamic]Wheel_Def, 0, 2),
		// The wheelbase-coupled widths (hw = 1.7/2 = 0.85): the 8
		// corners at hw/2, the center at hw.
		widths          = {0.425, 0.425, 0.425, 0.425, 0.425, 0.425, 0.425, 0.425, 0.85},
		chassis_density = TRIANGLE_DENSITY,
	}
	append(
		&g.wheels,
		Wheel_Def{vertex = 6, axle_angle = 0.0, radius = 0.5, density = WHEEL_DENSITY},
	) // rear
	append(
		&g.wheels,
		Wheel_Def{vertex = 7, axle_angle = 0.0, radius = 0.5, density = WHEEL_DENSITY},
	) // front
	return g
}
