// The share handoff (the share glyph → the wasm DOM overlay in
// index_template.html). This module is the app side of the two JSON
// channels:
//
//   app → JS  (host.JS_Post, one JSON string per call):
//     which=0  "share open" - the tile roster: per car its pre-built #car=
//              URL + a small pre-built side-view image (raw RGBA, base64),
//              plus the hero's index. The overlay builds the popup from
//              this payload, so a tile click swaps URL/QR/link with no
//              wasm round-trip.
//     which=1  "share hero" - the large side-view image for the selected
//              car (re-posted on open + on each tile click; one-shot).
//
//   JS → app  (window globals, read back through the apphost shims):
//     __odm_share_open  0/1 - the overlay's open state (the driver freezes
//                        the whole sim while it is up; loop.odin).
//     __odm_share_car   the tapped tile index (read-and-clear; -1 = none).
//
// Every tile is a COMPLETE Car_Link (genes + env + tick - car_link.odin):
// the tick is the frame being looked at (the car's own sim clock at the
// share moment; the frozen row's terminal tick; the trophy's recorded
// moment), and the env is the world the car raced. The popup's full freeze
// (loop.odin) is what holds that frame stable.
//
// Native: the shims are no-ops, so this module is inert in the window
// (the share glyph is wasm-only UI).

package main

import fmt "core:fmt"
import "core:math"
import "core:strings"
import host "engine:apphost"

// The roster bound (solo: row grid + live car; pack: the lineup) + trophy.
SHARE_TILES_MAX :: SOLO_MAX + 1

// Image geometry (device px, drawn by the JS overlay + export card): tiles
// match the panel's supersampled portrait tile (ICON_SS×). The hero is one
// shared image (popup + card export at 1:1), 3:2 not the panel tile's
// 2.52:1 - the fitted bbox is often taller, so a squarer box fills the
// card instead of letterboxing.
SHARE_TILE_W :: 136
SHARE_TILE_H :: 54
SHARE_HERO_W :: 720
SHARE_HERO_H :: 480

share_tiles: [SHARE_TILES_MAX]Car_Link
share_urls: [SHARE_TILES_MAX]string
share_img: [SHARE_TILES_MAX][]u8
share_colors: [SHARE_TILES_MAX][N_COLORS][3]u8
share_broken: [SHARE_TILES_MAX][8]bool
share_trophy: [SHARE_TILES_MAX]bool
share_tile_n := 0
share_hero_idx := 0

// Standard base64, not the link's base64url: the data payload needs no
// custom decoding in the JS overlay's ImageData path.
@(rodata)
B64_STD_STR := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

share_b64 :: proc(data: []u8) -> string {
	n := len(data)
	rem := n % 3
	tail := 0
	if rem == 1 {
		tail = 2
	} else if rem == 2 {
		tail = 3
	}
	out := make([]u8, n/3*4 + tail, context.allocator)
	i := 0
	for k in 0 ..< n/3 {
		v := u32(data[k*3])<<16 | u32(data[k*3+1])<<8 | u32(data[k*3+2])
		out[i+0] = B64_STD_STR[(v>>18)&63]
		out[i+1] = B64_STD_STR[(v>>12)&63]
		out[i+2] = B64_STD_STR[(v>>6)&63]
		out[i+3] = B64_STD_STR[v&63]
		i += 4
	}
	if rem == 1 {
		v := u32(data[n-1]) << 16
		out[i+0] = B64_STD_STR[(v>>18)&63]
		out[i+1] = B64_STD_STR[(v>>12)&63]
	} else if rem == 2 {
		v := u32(data[n-2]) << 16 | u32(data[n-1]) << 8
		out[i+0] = B64_STD_STR[(v>>18)&63]
		out[i+1] = B64_STD_STR[(v>>12)&63]
		out[i+2] = B64_STD_STR[(v>>6)&63]
	}
	s, _ := strings.clone_from_bytes(out)
	delete(out)
	return s
}

// Release the roster's raster images (the URLs are small; the tiles'
// images are the bulk). Called before a rebuild and on cleanup.
share_release_tiles :: proc() {
	for i in 0 ..< share_tile_n {
		if len(share_img[i]) > 0 {delete(share_img[i])}
	}
	share_tile_n = 0
}

// The shareable cars at the share moment, panel order: the solo's finished
// rows (their terminal tick) + the live car (its clock), or the pack's
// lineup (each car's clock), then the trophy (the champion record) when
// it is valid.
share_build_tiles :: proc() {
	share_release_tiles()
	// The champion (when valid) owns the trophy tile; the SAME car must
	// not also appear as a plain tile. A finished row or the live car can
	// hold the record, so any plain push with the champion's genes is
	// skipped - the ★ tile stands in for it (and shares its recorded
	// moment).
	// Returns the new tile's index, -1 if capped out, -2 if deduped into
	// the trophy.
	push :: proc(link: Car_Link, colors: [N_COLORS][3]u8, broken: [8]bool, trophy: bool) -> int {
		if share_tile_n >= SHARE_TILES_MAX {return -1}
		if !trophy && pop_viewer.champion_valid &&
		   link.genes == pop_viewer.champion.genes {
			return -2
		}
		genes := link.genes
		g := decode_genes(&genes)
		share_tiles[share_tile_n] = link
		share_urls[share_tile_n] = strings.concatenate(
			{SHARELINK_BASE_URL, car_link_encode(link)})
		share_colors[share_tile_n] = colors
		share_broken[share_tile_n] = broken
		share_trophy[share_tile_n] = trophy
		share_img[share_tile_n] = car_icon_render_rgba(
			SHARE_TILE_W, SHARE_TILE_H, &g, colors, broken)
		share_tile_n += 1
		return share_tile_n - 1
	}
	// The popup's default selection: the CURRENT car - the solo's live car,
	// or the pack's lead. If it is the champion (deduped, -2) its
	// representative is the trophy tile; otherwise fall back to tile 0.
	hero := -1
	if view_mode == 1 {
		for i in 0 ..< solo.row_n {
			r := solo.rows[i]
			if solo.rows_gen != solo.last.index ||
			   r.car >= len(solo.last.pop) {
				continue // a foreign walk's row: its genome is gone
			}
			push(Car_Link {
				genes = solo.last.pop[r.car],
				env   = solo.last.env,
				tick  = u32(math.round(r.time / TIME_STEP)),
			}, r.colors, [8]bool{}, false)
		}
		if solo.active {
			hero = push(Car_Link {
				genes = solo.last.pop[solo.cur],
				env   = solo.last.env,
				tick  = u32(math.round(solo.car.sim_time / TIME_STEP)),
			}, solo.colors, solo.car.bot.broken, false)
		}
	} else {
		for i in 0 ..< pop_viewer.n {
			car := &pop_viewer.cars[i]
			if i == pop_viewer.lead_idx {
				hero = push(Car_Link {
					genes = car.genes,
					env   = pop_viewer.last.env,
					tick  = u32(math.round(car.sim.sim_time / TIME_STEP)),
				}, car.genes.colors, car.sim.bot.broken, false)
			} else {
				push(Car_Link {
					genes = car.genes,
					env   = pop_viewer.last.env,
					tick  = u32(math.round(car.sim.sim_time / TIME_STEP)),
				}, car.genes.colors, car.sim.bot.broken, false)
			}
		}
	}
	if pop_viewer.champion_valid {
		c := pop_viewer.champion
		champ := push(Car_Link {
			genes = c.genes,
			env   = c.env,
			tick  = c.tick,
		}, c.genes.colors, [8]bool{}, true)
		if hero == -2 && champ >= 0 {hero = champ}
	}
	if hero < 0 {hero = 0}
	share_hero_idx = hero
}

// The which=0 post: the tile roster (URLs + tile images + the hero index).
share_open_json :: proc() -> string {
	s: [dynamic]string
	append(&s, `{"hero":`)
	append(&s, fmt.aprintf("%d", share_hero_idx))
	append(&s, `,"tiles":[`)
	for i in 0 ..< share_tile_n {
		if i > 0 {append(&s, ",")}
		append(&s, `{"i":`)
		append(&s, fmt.aprintf("%d", i))
		append(&s, `,"u":"`)
		append(&s, share_urls[i])
		append(&s, `","img":"`)
		append(&s, share_b64(share_img[i][:]))
		append(&s, `","w":`)
		append(&s, fmt.aprintf("%d", SHARE_TILE_W))
		append(&s, `,"h":`)
		append(&s, fmt.aprintf("%d", SHARE_TILE_H))
		if share_trophy[i] {
			append(&s, `,"t":1`)
		}
		append(&s, `}`)
	}
	append(&s, `]}`)
	out := strings.concatenate(s[:])
	delete(s)
	return out
}

// The which=1 post: the selected car's hero image (its URL rides along so
// the overlay's card/QR stay consistent with the re-post).
share_hero_json :: proc(i: int) -> string {
	genes := share_tiles[i].genes
	g := decode_genes(&genes)
	pix := car_icon_render_rgba(
		SHARE_HERO_W, SHARE_HERO_H, &g, share_colors[i], share_broken[i])
	defer delete(pix)
	s: [dynamic]string
	append(&s, `{"i":`)
	append(&s, fmt.aprintf("%d", i))
	append(&s, `,"u":"`)
	append(&s, share_urls[i])
	append(&s, `","img":"`)
	append(&s, share_b64(pix[:]))
	append(&s, `","w":`)
	append(&s, fmt.aprintf("%d", SHARE_HERO_W))
	append(&s, `,"h":`)
	append(&s, fmt.aprintf("%d", SHARE_HERO_H))
	append(&s, `}`)
	out := strings.concatenate(s[:])
	delete(s)
	return out
}

// The share glyph: build the roster, open the overlay (which=0), post the
// initial hero (which=1). The driver's freeze edge (loop.odin) lands the
// same frame the popup opens, so the shared tick IS the displayed frame.
share_open_popup :: proc() {
	share_build_tiles() // sets share_hero_idx = the current car
	if share_tile_n == 0 {return}
	host.JS_Post(0, share_open_json())
	share_post_hero(share_hero_idx)
}

// A tile tap (the JS→app read-and-clear channel): re-post that car's hero.
share_post_hero :: proc(i: int) {
	ensure(i >= 0 && i < share_tile_n)
	share_hero_idx = i
	host.JS_Post(1, share_hero_json(i))
}
