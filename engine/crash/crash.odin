// Generic crash diagnostics + telemetry ring.
//
// A fixed ring buffer of the last RING_CAP telemetry lines, with two escape
// hatches that turn it into a crash trail:
//   - `telemetry_flush_tick(dt)` (called ~1 Hz from the app's frame loop)
//     appends the ring to the app's tel.log and clears it, so even a hard kill
//     (SIGKILL, power loss) leaves the last second of state on disk. This is
//     gated on `tel_flush_on` (default off — apps opt in via a flag); the
//     ring is recorded either way, so the crash handler's trail is intact.
//   - `crash_install()` (called once at startup) installs SIGSEGV/SIGABRT/
//     SIGFPE/SIGILL handlers that append the ring to the app's crash.log using
//     async-signal-safe fwrite/fflush, then re-raise so the OS still produces
//     a core dump. `gdb <app> <core>` on that core gives the full backtrace.
//
// The app owns what a line *means*: it formats its own per-frame state into a
// string and calls `crash_record(line)`. This package only stores, flushes,
// and dumps those lines — it has no knowledge of the app's state. The log
// paths are app-specific, so `crash_install` takes them as parameters.
//
// Imported from the app as:  import crash "engine:crash"

package crash

import "base:runtime"
import "core:c/libc"
import "core:os"
import "core:strings"

// ─── Ring buffer of recent telemetry lines ────────────────────────────
// Fixed-size entries so the crash handler can dump them with raw fwrite
// (no allocation, no fmt — async-signal-safe). Written only from the main
// thread in normal context; read by the signal handler on the crashing
// thread. A torn entry (if the crash lands mid-write) is a cosmetic loss,
// not a hazard.
RING_CAP :: 256
RING_LINE_CAP :: 512
ring: [RING_CAP][RING_LINE_CAP]byte
ring_len: [RING_CAP]int
ring_head: int // next slot to write
ring_count: int // valid entries (0..RING_CAP)

// Pre-opened crash-log stream (fwrite/fflush in the handler are safe).
crash_file: ^libc.FILE
crash_installed: bool
// Process-lifetime cstrings for the log paths (allocated once at crash_install).
tel_log_cstr: cstring
crash_log_cstr: cstring

// Public toggle: apps gate per-frame recording on this (default on).
telemetry_on: bool = true

// Gate for the periodic tel.log flush (default off): the ring is always
// recorded (so the crash handler keeps the last-second trail for crash.log),
// but tel.log is only written when an app opts in.
tel_flush_on: bool = false

flush_accum: f32

// Push a pre-formatted line into the ring buffer (normal context).
crash_record :: proc(line: string) {
	l := line
	if len(l) > RING_LINE_CAP {l = l[:RING_LINE_CAP]}
	copy(ring[ring_head][:], l)
	ring_len[ring_head] = len(l)
	ring_head = (ring_head + 1) % RING_CAP
	if ring_count < RING_CAP {ring_count += 1}
}

// Append the ring buffer (oldest → newest) to `f` and clear it. Used by both
// the periodic flush (normal context) and the crash handler (signal context).
crash_dump_ring :: proc(f: ^libc.FILE) {
	for i in 0 ..< ring_count {
		idx := (ring_head - ring_count + i + RING_CAP) % RING_CAP
		n := ring_len[idx]
		if n > 0 {
			libc.fwrite(&ring[idx][0], 1, libc.size_t(n), f)
		}
	}
	libc.fflush(f)
	ring_count = 0
	ring_head = 0
}

// Async-signal-safe crash handler: dump the ring to crash.log, then re-raise
// with the default disposition so the OS produces a core dump for gdb.
crash_handler :: proc "c" (sig: i32) {
	context = runtime.default_context()
	if crash_file != nil {
		crash_dump_ring(crash_file)
	}
	libc.signal(sig, transmute(proc "c" (_: i32))libc.SIG_DFL)
	libc.raise(sig)
}

// Install the crash handlers + open the crash log. Call once at startup.
// `data_dir` is created if absent (e.g. "apps/<app>/data").
crash_install :: proc(tel_log, crash_log, data_dir: string) {
	if crash_installed {return}
	crash_installed = true
	os.mkdir_all(data_dir, DIR_PERM)
	tel_log_cstr = strings.clone_to_cstring(tel_log)
	crash_log_cstr = strings.clone_to_cstring(crash_log)
	crash_file = libc.fopen(crash_log_cstr, "a")
	libc.signal(libc.SIGSEGV, crash_handler)
	libc.signal(libc.SIGABRT, crash_handler)
	libc.signal(libc.SIGFPE, crash_handler)
	libc.signal(libc.SIGILL, crash_handler)
}

// Flush the ring to tel.log (gated on tel_flush_on).
telemetry_flush :: proc() {
	if !tel_flush_on {return}
	f := libc.fopen(tel_log_cstr, "a")
	if f == nil {return}
	crash_dump_ring(f)
	libc.fclose(f)
}

// Accumulate frame time and flush the ring ~1 Hz. Call once per frame with
// the frame dt.
telemetry_flush_tick :: proc(dt: f32) {
	flush_accum += dt
	if flush_accum >= 1.0 {
		flush_accum = 0.0
		telemetry_flush()
	}
}

DIR_PERM :: os.Permissions {
	.Read_User,
	.Write_User,
	.Execute_User,
	.Read_Group,
	.Execute_Group,
	.Read_Other,
	.Execute_Other,
}
