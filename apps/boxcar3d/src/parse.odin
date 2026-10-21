#+build !wasm32
// Minimal CLI-arg parsers for the headless CLI. No core:strconv: parse_u64
// takes digits with an optional 0x prefix (seeds print in hex); parse_f32
// takes an optional '-' sign, digits, and an optional '.' fraction.

package main

parse_u64 :: proc(s: string) -> (u64, bool) {
	if len(s) == 0 {return 0, false}
	radix := 10
	i := 0
	if len(s) >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		radix = 16
		i = 2
	}
	if i >= len(s) {return 0, false}
	v: u64 = 0
	for ch in s[i:] {
		d := u64(0)
		switch {
		case ch >= '0' && ch <= '9':
			d = u64(ch - '0')
		case ch >= 'a' && ch <= 'f':
			d = u64(ch - 'a') + 10
		case ch >= 'A' && ch <= 'F':
			d = u64(ch - 'A') + 10
		case:
			return 0, false
		}
		if d >= u64(radix) {return 0, false}
		v = v * u64(radix) + d
	}
	return v, true
}

parse_f32 :: proc(s: string) -> (f32, bool) {
	if len(s) == 0 {return 0, false}
	neg := false
	i := 0
	if s[i] == '-' {
		neg = true
		i += 1
	}
	if i >= len(s) {return 0, false}
	whole: f32 = 0
	has_digit := false
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		whole = whole * 10 + f32(s[i] - '0')
		i += 1
		has_digit = true
	}
	frac: f32 = 0
	if i < len(s) && s[i] == '.' {
		i += 1
		scale: f32 = 0.1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			frac += f32(s[i] - '0') * scale
			scale *= 0.1
			i += 1
			has_digit = true
		}
	}
	if !has_digit {return 0, false}
	val := whole + frac
	if neg {val = -val}
	return val, true
}
