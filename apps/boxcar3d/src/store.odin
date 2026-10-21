#+build !wasm32
// Data-path resolution (telemetry/crash logs), independent of cwd. DATA_DIR
// is populated by resolve_data_paths(); empty until then.
//
// Genomes are stored as .genome files under the data dir.
//
// Native only (files).


package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

DATA_DIR := ""

CAR_ID :: "fixed_car"

DIR_PERM :: os.Permissions {
	.Read_User,
	.Write_User,
	.Execute_User,
	.Read_Group,
	.Execute_Group,
	.Read_Other,
	.Execute_Other,
} // 0o755

// Sidecar metadata for a saved genome; the env pair makes a resumed run
// provably race the same world.
Genome_Meta :: struct {
	gen:      int, // run generation
	fitness:  f64, // best fitness
	n_wheels: int,
	env_seed: u64, // world raced (Env seed + line); 0 → no env recorded
	env_line: f32,
}

// Human-readable + diffable text format: a meta block (key=value) then one
// line per gene. 12 significant figures round-trip the f32 genes exactly
// via f64.
save_genome :: proc(path: string, genes: ^Genes, meta: Genome_Meta) -> bool {
	lines := make([dynamic]string, 0, 7 + N_VERTICES + N_WHEELS + N_WIDTHS + N_COLORS)
	append(&lines, "boxcar3d genome v5\n")
	append(&lines, fmt.aprintf("gen={}\n", meta.gen))
	append(&lines, fmt.aprintf("fitness={:.12g}\n", meta.fitness))
	append(&lines, fmt.aprintf("n_wheels={}\n", meta.n_wheels))
	append(&lines, fmt.aprintf("env_seed=0x{:x}\n", meta.env_seed))
	append(&lines, fmt.aprintf("env_line={:.12g}\n", meta.env_line))
	append(&lines, fmt.aprintf("chassis_density={:.12g}\n", genes.chassis_density))
	for v in genes.vertices {
		append(&lines, fmt.aprintf("v {:.12g} {:.12g}\n", v.angle, v.magnitude))
	}
	for w in genes.wheels {
		append(
			&lines,
			fmt.aprintf(
				"w {} {:.12g} {:.12g} {:.12g}\n",
				w.vertex,
				w.axle_angle,
				w.radius,
				w.density,
			),
		)
	}
	// Width profile: 8 vertex half-widths + the center (index 8).
	for x in genes.widths {
		append(&lines, fmt.aprintf("W {:.12g}\n", x))
	}
	// The 16 part-color slots (decimal 0-255).
	for c in genes.colors {
		append(&lines, fmt.aprintf("C {} {} {}\n", c[0], c[1], c[2]))
	}
	s := strings.concatenate(lines[:])
	delete(lines)
	ok := os.write_entire_file_from_string(path, s) == nil
	delete(s)
	return ok
}

// Locate a user-supplied artifact path, cwd-independent: anchored under
// DATA_DIR, again with a leading "data/" stripped (so "data/…" paths work
// from anywhere). ok=false → no match.
resolve_user_path :: proc(path: string) -> (string, bool) {
	if len(DATA_DIR) == 0 {return "", false}
	anchored := strings.concatenate({DATA_DIR, "/", path})
	if os.exists(anchored) {return anchored, true}
	delete(anchored)
	if strings.has_prefix(path, "data/") {
		rel := strings.concatenate({DATA_DIR, "/", path[5:]})
		if os.exists(rel) {return rel, true}
		delete(rel)
	}
	return "", false
}

// The inverse of save_genome. ok=false on a read error, an out-of-range C
// channel (outside 0-255), or a line-count mismatch (wrong number of
// v/w/W/C lines). Number-parse errors are discarded: malformed values
// silently load as 0. No W lines: the width profile is synthesized from
// the enabled-wheel x-span (corners at hw/2, center at hw) so the phenotype
// is unchanged. No C lines: all 16 part-color slots are filled with the
// hash-derived colour. No env lines: env_seed/env_line 0 - the caller
// falls back to its own run env.
load_genome :: proc(path: string) -> (Genes, Genome_Meta, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		// Retry anchored to the app's data dir (cwd-independent).
		alt, ok := resolve_user_path(path)
		if ok {
			data, err = os.read_entire_file_from_path(alt, context.allocator)
			delete(alt)
		}
		if err != nil {return {}, {}, false}
	}
	defer delete(data)
	// `string(data)` is ZERO-COPY: every line below aliases `data`'s bytes.
	// Consume everything before the single exit; never return these slices.
	lines := strings.split(string(data), "\n")
	defer delete(lines)
	meta := Genome_Meta{}
	genes := Genes{}
	nv := 0
	nw := 0
	nwid := 0
	ncol := 0
	for line in lines {
		t := strings.trim_space(line)
		if len(t) == 0 {continue}
		c := t[0]
		if c == 'v' || c == 'w' || c == 'W' || c == 'C' {
			parts := strings.split(t, " ")
			if c == 'v' && len(parts) >= 3 && nv < N_VERTICES {
				a, _ := strconv.parse_f64(parts[1])
				m, _ := strconv.parse_f64(parts[2])
				genes.vertices[nv].angle = f32(a)
				genes.vertices[nv].magnitude = f32(m)
				nv += 1
			} else if c == 'w' && len(parts) >= 5 && nw < N_WHEELS {
				vi, _ := strconv.parse_int(parts[1])
				a, _ := strconv.parse_f64(parts[2])
				r, _ := strconv.parse_f64(parts[3])
				d, _ := strconv.parse_f64(parts[4])
				genes.wheels[nw].vertex = vi
				genes.wheels[nw].axle_angle = f32(a)
				genes.wheels[nw].radius = f32(r)
				genes.wheels[nw].density = f32(d)
				nw += 1
			} else if c == 'W' && len(parts) >= 2 && nwid < N_WIDTHS {
				x, _ := strconv.parse_f64(parts[1])
				genes.widths[nwid] = f32(x)
				nwid += 1
			} else if c == 'C' && len(parts) >= 4 && ncol < N_COLORS {
				r, _ := strconv.parse_int(parts[1])
				gv, _ := strconv.parse_int(parts[2])
				b, _ := strconv.parse_int(parts[3])
				if r < 0 || r > 255 || gv < 0 || gv > 255 || b < 0 || b > 255 {
					return {}, {}, false
				}
				genes.colors[ncol] = [3]u8{u8(r), u8(gv), u8(b)}
				ncol += 1
			}
			delete(parts)
			continue
		}
		eq := strings.index(t, "=")
		if eq < 0 {continue}
		key := t[:eq]
		val := t[eq + 1:]
		switch key {
		case "gen":
			meta.gen, _ = strconv.parse_int(val)
		case "fitness":
			meta.fitness, _ = strconv.parse_f64(val)
		case "n_wheels":
			meta.n_wheels, _ = strconv.parse_int(val)
		case "chassis_density":
			cd, _ := strconv.parse_f64(val)
			genes.chassis_density = f32(cd)
		case "env_seed":
			meta.env_seed, _ = parse_u64(val)
		case "env_line":
			el, _ := strconv.parse_f64(val)
			meta.env_line = f32(el)
		case:
		}
	}
	if nv != N_VERTICES || nw != N_WHEELS {return {}, {}, false}
	if nwid != 0 && nwid != N_WIDTHS {return {}, {}, false}
	if nwid == 0 {
		// No width lines: synthesize the retired wheelbase coupling
		// (hw = enabled-wheel x-span / 2; span ≤ 2·MAX_MAG so hw ≤ 3.0).
		// Wide old genomes can exceed WIDTH_HI (2.0); decode_genes
		// (evolve.odin) clamps the widths and absorbs it.
		hw := f32(0.05)
		min_x := f32(1e9)
		max_x := f32(-1e9)
		for w in genes.wheels {
			if w.vertex < 0 {continue}
			v := &genes.vertices[w.vertex]
			x := math.cos(v.angle) * v.magnitude
			if x < min_x {min_x = x}
			if x > max_x {max_x = x}
		}
		if max_x > min_x {hw = (max_x - min_x) * 0.5}
		for i in 0 ..< N_VERTICES {genes.widths[i] = hw * 0.5}
		genes.widths[N_VERTICES] = hw
	}
	if ncol != 0 && ncol != N_COLORS {return {}, {}, false}
	if ncol == 0 {
		// No colour lines: fill all 16 slots with the hash-derived colour.
		cc := waypoint_color(int(genes_hash(&genes) % 10), 10, false, false)
		for s in 0 ..< N_COLORS {
			genes.colors[s] = [3]u8 {
				u8(int(cc[0] * 255.0)),
				u8(int(cc[1] * 255.0)),
				u8(int(cc[2] * 255.0)),
			}
		}
	}
	return genes, meta, true
}

// Resolve the data paths once, anchored to the app root (the dir containing
// project.env) found by walking up from the running executable. Idempotent;
// call before any telemetry/crash path (see run_main). Falls back to
// cwd-relative `data` if the app root can't be located.
resolve_data_paths :: proc() {
	if len(DATA_DIR) > 0 {return}
	root := "data"
	exe, err := os.read_link("/proc/self/exe", context.allocator)
	if err == nil {
		dir := exe
		// Drop the trailing "/<APP>" so we start from the exe's directory.
		if idx := strings.last_index(dir, "/"); idx >= 0 {dir = dir[:idx]}
		for {
			probe := strings.concatenate({dir, "/project.env"})
			found := os.exists(probe)
			delete(probe)
			if found {
				root = strings.concatenate({dir, "/data"})
				break
			}
			idx := strings.last_index(dir, "/")
			if idx < 0 {break}
			dir = dir[:idx]
			if len(dir) == 0 {break}
		}
		delete(exe)
	}
	DATA_DIR = root
	TEL_LOG = strings.concatenate({root, "/tel.log"})
	CRASH_LOG = strings.concatenate({root, "/crash.log"})
}
