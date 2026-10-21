// Orbit camera: drag to orbit, scroll to zoom. Target follows the chassis
// body in solo and pop-viewer modes.

package main

import "core:math"

CAMERA_DISTANCE :: f32(16.0)
CAMERA_AZIMUTH :: f32(0.7)
CAMERA_ELEVATION :: f32(0.4)
CAMERA_FOV :: f32(55.0)
CAMERA_FOV_RAD :: CAMERA_FOV * (f32(math.PI) / 180.0)
CAMERA_NEAR :: f32(0.1)
CAMERA_FAR :: f32(2000.0)

Camera_State :: struct {
	azimuth:   f32,
	elevation: f32,
	distance:  f32,
	target:    [3]f32,
}

init_camera :: proc() -> Camera_State {
	return {
		azimuth = CAMERA_AZIMUTH,
		elevation = CAMERA_ELEVATION,
		distance = CAMERA_DISTANCE,
		target = {0.0, 1.0, 0.0},
	}
}

update_camera_orbit :: proc(cam: ^Camera_State, dx, dy, scroll: f32) {
	cam.azimuth -= dx * 0.005
	cam.elevation = math.clamp(cam.elevation + dy * 0.005, -1.4, 1.4)
	cam.distance = math.clamp(cam.distance - scroll, 6, 60)
}

follow_camera :: proc(cam: ^Camera_State, pos: [3]f32) {
	// NaN guard: a degenerate body can trip Box3D's solver and leave a body at
	// NaN. NaN is sticky; skip it and snap a corrupted target back to finite.
	if pos[0] != pos[0] || pos[1] != pos[1] || pos[2] != pos[2] {return}
	target := [3]f32{pos[0], pos[1] + 1.0, pos[2]}
	if cam.target[0] != cam.target[0] ||
	   cam.target[1] != cam.target[1] ||
	   cam.target[2] != cam.target[2] {
		cam.target = target
		return
	}
	alpha :: f32(0.1)
	cam.target[0] += (target[0] - cam.target[0]) * alpha
	cam.target[1] += (target[1] - cam.target[1]) * alpha
	cam.target[2] += (target[2] - cam.target[2]) * alpha
}

camera_position :: proc(cam: Camera_State) -> [3]f32 {
	cos_el := math.cos(cam.elevation)
	return {
		cam.target[0] + cam.distance * cos_el * math.sin(cam.azimuth),
		cam.target[1] + cam.distance * math.sin(cam.elevation),
		cam.target[2] + cam.distance * cos_el * math.cos(cam.azimuth),
	}
}

camera_basis :: proc(cam: Camera_State) -> (right, up, forward, eye: [3]f32) {
	eye = camera_position(cam)
	fwd := [3]f32{eye[0] - cam.target[0], eye[1] - cam.target[1], eye[2] - cam.target[2]}
	fl := math.sqrt(fwd[0] * fwd[0] + fwd[1] * fwd[1] + fwd[2] * fwd[2])
	if fl < 1e-6 {fl = 1e-6}
	forward = {fwd[0] / fl, fwd[1] / fl, fwd[2] / fl}
	d := forward[1]
	uu := [3]f32{-d * forward[0], 1.0 - d * forward[1], -d * forward[2]}
	ul := math.sqrt(uu[0] * uu[0] + uu[1] * uu[1] + uu[2] * uu[2])
	if ul < 1e-6 {ul = 1e-6}
	up = {uu[0] / ul, uu[1] / ul, uu[2] / ul}
	r := [3]f32 {
		up[1] * forward[2] - up[2] * forward[1],
		up[2] * forward[0] - up[0] * forward[2],
		up[0] * forward[1] - up[1] * forward[0],
	}
	rl := math.sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2])
	if rl < 1e-6 {rl = 1e-6}
	right = {r[0] / rl, r[1] / rl, r[2] / rl}
	return
}
