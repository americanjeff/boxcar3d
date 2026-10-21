// Share-link codec: one car (its genes, the Env it raced in, and the frame
// the sharer was looking at) packed into a URL fragment:
// #car=<base64url, no padding>. The whole car travels in the link: no
// server state, no files. Pure (no I/O, no renderer), so the native
// `sharelink` CLI and the headless smoke test exercise the exact bytes the
// browser ships.
//
// WIRE LAYOUT - 119 bytes: 117 field bytes + 2 checksum bytes (big-endian
// bits, MSB first). Fields are 929 bits; 7 pad bits zero them to a byte
// boundary before the checksum:
//   version         4 bits  (CAR_LINK_VERSION)
//   has_tick        1 bit
//   tick            20 bits (the sharer's frame, in ticks; 0 when absent)
//   env_seed        64 bits (the terrain the car raced)
//   env_line        16 bits (0..COURSE_MAX_LEN)
//   chassis_density 12 bits (CHASSIS_DENSITY_LO..HI)
//   vertices        8 × (angle 12 [0, TAU), magnitude 12 [MAG_LO, MAX_MAG])
//   wheels          8 × (mount 4 (15 = disabled), axle 12 [0, TAU),
//                   radius 12 [RAD_LO, MAX_RADIUS], density 12 [WHEEL_DENSITY_LO..HI])
//   widths          9 × 12 bits ([WIDTH_LO, WIDTH_HI])
//   colors          16 × (r4 g4 b4)
//   pad             7 bits (zero, byte-alignment)
//   checksum        16 bits (FNV-1 64 over the 117 field bytes, folded)
//
// 12-bit quantization is sub-millimetre on every range (the widest span,
// MAX_MAG − MAG_LO, is 2.95 m / 4095 ≈ 0.7 mm): the shared car is
// phenotypically identical; decode_genes is the single constraint point on
// the receiver side. 4-bit colors: 16 levels/channel (step 17/255).
// 119 bytes → 159 base64url chars → a ~185-char URL → a 53×53 QR code.

package main

import "core:strings"

CAR_LINK_VERSION :: u32(1)
CAR_LINK_FIELD_BITS :: 929
CAR_LINK_FIELD_BYTES :: 117 // (929 + 7 pad) / 8 - fields, byte-aligned
CAR_LINK_BYTES :: 119 // field bytes + 2 checksum bytes

// The site the links point at (fragment-only - the payload is a URL
// fragment, so it is never in server logs or referrers).
SHARELINK_BASE_URL :: "https://boxcar3d.com/"

// The env_line quantization span. `--course M` sets env_max_len = M for any
// M > 0, so a course beyond this span is silently clamped to it on share
// (the 16-bit env.line field cannot carry more).
COURSE_MAX_LEN :: f32(3200.0)

bit_writer :: struct {
	buf: []u8,
	pos: int,
}

// Push `n` low bits of `v`, MSB first.
bw_push :: proc(b: ^bit_writer, v: u64, n: int) {
	ensure(n > 0 && n <= 64)
	nn := u32(n)
	for i := u32(0); i < nn; i += 1 {
		by := b.pos >> 3
		bit := u32(7 - (b.pos & 7))
		if ((v >> (nn - 1 - i)) & 1) == 1 {
			b.buf[by] |= u8(u32(1) << bit)
		}
		b.pos += 1
	}
}

bit_reader :: struct {
	buf: []u8,
	pos: int,
}

// Pull `n` bits, MSB first.
br_pull :: proc(b: ^bit_reader, n: int) -> u64 {
	ensure(n > 0 && n <= 64)
	v := u64(0)
	for _ in 0 ..< n {
		by := b.pos >> 3
		bit := u32(7 - (b.pos & 7))
		v = v << 1
		if (b.buf[by] & u8(u32(1) << bit)) != 0 {v |= 1}
		b.pos += 1
	}
	return v
}

// Uniform 12-bit quantize into [lo, hi] (clamped to the span). Round-to-
// nearest, so a decoded value re-encodes to the same bits (q12(uq12(q)) ==
// q in f32, error < 1/4095 of a quantum): re-sharing is byte-identical.
q12 :: proc(v, lo, hi: f32) -> u16 {
	d := (v - lo) / (hi - lo)
	if d < 0 {d = 0}
	if d > 1 {d = 1}
	return u16(d * 4095 + 0.5)
}

uq12 :: proc(q: u64, lo, hi: f32) -> f32 {
	cq := q
	if cq > 4095 {cq = 4095}
	return lo + f32(cq) / 4095 * (hi - lo)
}

// 4-bit color: round to the nearest level (level q sits at c = q·17, so
// nearest = round(c/17) = (15c + 127)/255); q4(uq4(q)) == q by construction.
q4 :: proc(c: u8) -> u16 {
	return u16((u32(c) * 15 + 127) / 255)
}

uq4 :: proc(q: u64) -> u8 {
	cq := q
	if cq > 15 {cq = 15}
	return u8(cq * 17)
}

// @(rodata): indexed at runtime (a :: constant has no runtime address).
@(rodata) B64URL_STR := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

// base64url (RFC 4648 §5), no padding: the output length is exact (a 1-byte
// tail emits 2 chars, a 2-byte tail 3).
b64url_encode :: proc(src: []u8) -> string {
	rem := len(src) % 3
	tail := 0
	if rem == 1 {tail = 2}
	if rem == 2 {tail = 3}
	out := make([]u8, len(src)/3*4 + tail, context.allocator)
	k := 0
	for i := 0; i < len(src); i += 3 {
		left := len(src) - i
		v := u32(src[i]) << 16
		if left > 1 {v |= u32(src[i + 1]) << 8}
		if left > 2 {v |= u32(src[i + 2])}
		out[k] = u8(B64URL_STR[(v >> 18) & 63])
		k += 1
		if left >= 2 {
			out[k] = u8(B64URL_STR[(v >> 12) & 63])
			k += 1
			out[k] = u8(B64URL_STR[(v >> 6) & 63])
			k += 1
		}
		if left >= 3 {
			out[k] = u8(B64URL_STR[v & 63])
			k += 1
		}
	}
	ensure(k == len(out))
	// string(out) is a zero-copy view in this Odin - clone the bytes so the
	// result outlives the (deleted) buffer.
	s, _ := strings.clone_from_bytes(out)
	delete(out)
	return s
}

b64url_decode :: proc(s: string) -> ([]u8, bool) {
	lookup := [256]int{}
	for i in 0 ..< 256 {lookup[i] = -1}
	for c, i in B64URL_STR {lookup[u8(c)] = int(i)}
	out := make([]u8, len(s) / 4 * 3 + 3, context.allocator)
	n := 0
	v := u32(0)
	nbits := u32(0)
	for c in s {
		if c == '=' {continue} // tolerate padding
		if c > 127 {return nil, false}
		i := lookup[u8(c)]
		if i < 0 {return nil, false}
		v = (v << 6) | u32(i)
		nbits += 6
		if nbits >= 8 {
			nbits -= 8
			out[n] = u8((v >> nbits) & 0xFF)
			n += 1
			v &= (u32(1) << nbits) - 1
		}
	}
	return out[:n], true
}

// One shareable car: the genes, the world it raced in, and the frame the
// sharer was looking at (0 = no moment; the receiver runs from spawn).
Car_Link :: struct {
	genes: Genes,
	env:   Env,
	tick:  u32,
}

// FNV-1 64 of the field bytes (the add/multiply FNV of evolve.odin - this
// Odin has no binary XOR operator), folded to 16.
car_link_checksum :: proc(buf: []u8) -> u16 {
	h := u64(0xcbf29ce484222325)
	for x in buf {
		h += u64(x)
		h *= 0x100000001b3
	}
	return u16((h & 0xFFFF) + (h >> 16 & 0xFFFF) + (h >> 32 & 0xFFFF) + (h >> 48))
}

// Encode as the URL fragment "#car=<base64url>".
car_link_encode :: proc(cl: Car_Link) -> string {
	vars := [CAR_LINK_BYTES]u8{}
	bw := bit_writer{buf = vars[:]}
	tick := cl.tick
	has_tick := u64(0)
	if tick != 0 {
		has_tick = 1
		if tick > 1048575 {tick = 1048575}
	}
	bw_push(&bw, u64(CAR_LINK_VERSION), 4)
	bw_push(&bw, has_tick, 1)
	bw_push(&bw, u64(tick), 20)
	bw_push(&bw, u64(cl.env.seed), 64)
	bw_push(&bw, u64(q12(cl.env.line, 0, COURSE_MAX_LEN)), 16)
	bw_push(&bw, u64(q12(cl.genes.chassis_density, CHASSIS_DENSITY_LO, CHASSIS_DENSITY_HI)), 12)
	for v in cl.genes.vertices {
		bw_push(&bw, u64(q12(wrap_angle(v.angle), 0, TAU)), 12)
		bw_push(&bw, u64(q12(v.magnitude, MAG_LO, MAX_MAG)), 12)
	}
	for w in cl.genes.wheels {
		mount := u64(15)
		if w.vertex >= 0 {mount = u64(w.vertex)}
		bw_push(&bw, mount, 4)
		bw_push(&bw, u64(q12(wrap_angle(w.axle_angle), 0, TAU)), 12)
		bw_push(&bw, u64(q12(w.radius, RAD_LO, MAX_RADIUS)), 12)
		bw_push(&bw, u64(q12(w.density, WHEEL_DENSITY_LO, WHEEL_DENSITY_HI)), 12)
	}
	for x in cl.genes.widths {
		bw_push(&bw, u64(q12(x, WIDTH_LO, WIDTH_HI)), 12)
	}
	for c in cl.genes.colors {
		bw_push(&bw, u64(q4(c[0])), 4)
		bw_push(&bw, u64(q4(c[1])), 4)
		bw_push(&bw, u64(q4(c[2])), 4)
	}
	// Zero-pad the 929 field bits to the 117-byte boundary, then checksum.
	bw_push(&bw, 0, CAR_LINK_FIELD_BYTES*8 - CAR_LINK_FIELD_BITS)
	bw_push(&bw, u64(car_link_checksum(vars[:CAR_LINK_FIELD_BYTES])), 16)
	ensure(bw.pos == CAR_LINK_BYTES*8)
	return strings.concatenate({"#car=", b64url_encode(vars[:])})
}

// Decode a fragment ("#car=<base64url>" or a bare payload). ok=false →
// wrong version, bad checksum, bad length, or invalid base64url - the
// caller falls back to a normal boot.
car_link_decode :: proc(frag: string) -> (Car_Link, bool) {
	body := frag
	if idx := strings.index(frag, "car="); idx >= 0 {
		body = frag[idx + len("car="):]
	}
	data, ok := b64url_decode(body)
	if !ok {return Car_Link{}, false}
	defer delete(data)
	if len(data) != CAR_LINK_BYTES {return Car_Link{}, false}
	want := u16(u64(data[CAR_LINK_FIELD_BYTES]) << 8 | u64(data[CAR_LINK_FIELD_BYTES + 1]))
	if car_link_checksum(data[:CAR_LINK_FIELD_BYTES]) != want {return Car_Link{}, false}
	br := bit_reader{buf = data}
	if u32(br_pull(&br, 4)) != CAR_LINK_VERSION {return Car_Link{}, false}
	has_tick := br_pull(&br, 1)
	tick := u32(br_pull(&br, 20))
	cl := Car_Link {
		tick = tick != 0 && has_tick != 0 ? tick : 0,
		env = Env {
			seed = u64(br_pull(&br, 64)),
			line = uq12(br_pull(&br, 16), 0, COURSE_MAX_LEN),
		},
	}
	cl.genes.chassis_density = uq12(br_pull(&br, 12), CHASSIS_DENSITY_LO, CHASSIS_DENSITY_HI)
	// Angles are re-wrapped: uq12(4095, 0, TAU) is TAU itself, and wrap_angle
	// normalizes it to 0 so a decoded car re-encodes to the same bits.
	for i in 0 ..< N_VERTICES {
		cl.genes.vertices[i].angle = wrap_angle(uq12(br_pull(&br, 12), 0, TAU))
		cl.genes.vertices[i].magnitude = uq12(br_pull(&br, 12), MAG_LO, MAX_MAG)
	}
	for i in 0 ..< N_WHEELS {
		mount := br_pull(&br, 4)
		cl.genes.wheels[i].vertex = mount == 15 ? -1 : int(mount)
		cl.genes.wheels[i].axle_angle = wrap_angle(uq12(br_pull(&br, 12), 0, TAU))
		cl.genes.wheels[i].radius = uq12(br_pull(&br, 12), RAD_LO, MAX_RADIUS)
		cl.genes.wheels[i].density = uq12(br_pull(&br, 12), WHEEL_DENSITY_LO, WHEEL_DENSITY_HI)
	}
	for i in 0 ..< N_WIDTHS {
		cl.genes.widths[i] = uq12(br_pull(&br, 12), WIDTH_LO, WIDTH_HI)
	}
	for i in 0 ..< N_COLORS {
		cl.genes.colors[i][0] = uq4(br_pull(&br, 4))
		cl.genes.colors[i][1] = uq4(br_pull(&br, 4))
		cl.genes.colors[i][2] = uq4(br_pull(&br, 4))
	}
	return cl, true
}
