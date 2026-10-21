#+build !wasm32
// Per-rollout channel logging.
//
// Gated by `evolve --tel DIR`: one CSV per car (car_g<gen>_c<i>.csv, ~30 Hz)
// sampled by the worker that runs the rollout, plus summary.tsv (one row
// per car) appended by the main thread after each eval join. The viewer
// path is never logged: its replays are bit-identical to the worker
// rollouts.
//
// Lifetime: the Tel_Writer is owned by the rollout owner; tel_finish is
// called INLINE at the single exit (not via defer), so it can never run
// after the owner's buffer is gone (see slot_finish, evolve.odin).
//
// Columns: attitude vs world up (uy/ly/fy), forward/lateral velocity,
// body-frame angular rates (sensors 7/9/11), wheel ground-contact count,
// lateral offset from the centerline (the track is straight along +x at
// z = 0), height above the terrain, bearing to the next waypoint (sensors
// 0/1, the exact values the controller saw), mean achieved steer, and the
// max wheel-contact normal impulse this step (the launch-energy signal).

package main

import "core:fmt"
import "core:os"
import "core:strings"
import b3 "engine:physics"

// Every 2 steps = 30 Hz at TIME_STEP (60 Hz). A 47 s rollout ≈ 1400 rows.
TEL_EVERY :: 2
TEL_CAP :: 2048 // preallocated line slots - a full rollout never regrows

TEL_CSV_HEADER := "t,x,uy,ly,fy,v_fwd,v_lat,w_yaw,w_roll,w_pitch,n_contacts,lat_offset,height,bear_sin,bear_cos,steer,impulse"

// Tel_Writer lives in evolve.odin (Rollout_Slot carries it); the real
// writers are here (native), the no-ops in rollout_tel_wasm.odin.

tel_init :: proc(tel: ^Tel_Writer, dir: string, gen, car: int) {
	tel^ = {}
	tel.dir = dir
	tel.gen = gen
	tel.car = car
	tel.lines = make([dynamic]string, 0, TEL_CAP)
	append(&tel.lines, TEL_CSV_HEADER, "\n")
}

// `s_buf` is this step's sensor vector: v_fwd/w_*/bearing come from it, so
// the log holds what the controller was handed.
tel_sample :: proc(tel: ^Tel_Writer, sim: ^Sim_State, s_buf: []f32) {
	tel._steps += 1
	if tel._steps % TEL_EVERY != 0 {return}
	cp := b3.Body_GetPosition(sim.bot.chassis)
	q := b3.Body_GetRotation(sim.bot.chassis)
	fwd, left := chassis_axes(q)
	uy := left[2] * fwd[0] - left[0] * fwd[2]
	v := b3.Body_GetLinearVelocity(sim.bot.chassis)
	v_lat := v[0] * left[0] + v[1] * left[1] + v[2] * left[2]

	// Wheels currently in contact (one contact query per wheel body; the
	// shim mallocs a small buffer per call - fine for a gated debug tool).
	// The same calls double as the impulse sample: the largest normal
	// impulse on any wheel contact this step (the launch-energy signal).
	cd := [1]b3.Contact_Info{}
	n_contacts := 0
	impulse := f32(0.0)
	for j in sim.bot.wheels {
		pair := [2]b3.BodyId{j.wheel_l, j.wheel_r}
		for wheel in pair {
			if n := b3.Body_GetContacts(wheel, cd[:]); n > 0 {
				n_contacts += 1
				c := cd[0]
				for m in 0 ..< c.manifold_count {
					mf := c.manifolds[m]
					for p in 0 ..< mf.point_count {
						if mf.points[p].normal_impulse > impulse {
							impulse = mf.points[p].normal_impulse
						}
					}
				}
			}
		}
	}

	steer := f32(0)
	if len(sim.prev_steer) > 0 {
		for s in sim.prev_steer {steer += s}
		steer /= f32(len(sim.prev_steer))
	}

	append(
		&tel.lines,
		fmt.aprintf(
			"{:.3f},{:.2f},{:.3f},{:.3f},{:.3f},{:.2f},{:.2f},{:.3f},{:.3f},{:.3f},{},{:.2f},{:.2f},{:.3f},{:.3f},{:.3f},{:.1f}\n",
			sim.sim_time,
			cp[0],
			uy,
			left[1],
			fwd[1],
			s_buf[6],
			v_lat,
			s_buf[7],
			s_buf[9],
			s_buf[11],
			n_contacts,
			cp[2], // lateral offset from the centerline
			cp[1] - terrain_height_p(sim.profile[:], cp[0], cp[2]),
			s_buf[0],
			s_buf[1],
			steer,
			impulse,
		),
	)
}

// Write the car's CSV whole and free the lines buffer.
tel_finish :: proc(tel: ^Tel_Writer) {
	if len(tel.lines) == 0 {return}
	p := fmt.aprintf("%s/car_g%d_c%d.csv", tel.dir, tel.gen, tel.car)
	if err := os.write_entire_file_from_string(p, strings.concatenate(tel.lines[:])); err != nil {
		fmt.eprintfln("tel: could not write {}", p)
	}
	delete(p)
	delete(tel.lines)
}

// One row per car, appended to the run's summary.tsv (whole-file read +
// rewrite).
// NOTE: `string([]u8)` is ZERO-COPY in this Odin version - the old-file
// bytes are copied into an owned `old` buffer that outlives the write and
// is never freed before concatenate.
tel_write_summary :: proc(dir: string, gen: int, res: []Eval_Result) {
	p := fmt.aprintf("%s/summary.tsv", dir)
	old := [dynamic]u8{}
	if data, err := os.read_entire_file_from_path(p, context.allocator); err == nil {
		old = make([dynamic]u8, len(data), context.allocator)
		copy(old[:], data[:])
		delete(data)
	}
	parts := make([dynamic]string, 0, len(res) + 1)
	if len(old) > 0 {
		append(&parts, string(old[:])) // aliases `old`, which outlives the write
	} else {
		append(
			&parts,
			"gen\tcar\tresult\tbest_x\tfail_time\tfitness\tflip_steps\tflip_entries\tbreaks\tmax_speed\tmax_jump\tmax_height\tmax_impulse\n",
		)
	}
	for i in 0 ..< len(res) {
		r := res[i]
		append(
			&parts,
			fmt.aprintf(
				"{}\t{}\t{}\t{:.2f}\t{:.3f}\t{:.12g}\t{}\t{}\t{}\t{:.2f}\t{:.3f}\t{:.2f}\t{:.1f}\n",
				gen,
				i,
				outcome_name(r.outcome),
				r.best_x,
				r.fail_time,
				r.fitness,
				r.flip_steps,
				r.n_flips,
				r.n_breaks,
				r.max_speed,
				r.max_jump,
				r.max_height,
				r.max_impulse,
			),
		)
	}
	if err := os.write_entire_file_from_string(p, strings.concatenate(parts[:])); err != nil {
		fmt.eprintfln("tel: could not write {}", p)
	}
	delete(p)
	delete(old)
	delete(parts)
}
