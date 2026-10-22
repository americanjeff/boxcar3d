package physics

import "core:c"

// Default log sink for native builds: plain libc calls (matches Box3D's
// own default: printf "Box3D: %s\n" to stdout). Bare externs, resolved
// by the system libc at final link. Not through a `system:c` foreign
// import — that would embed the toolchain's libc-shim and collide with
// the host libc. (The js_wasm32 variant lives in
// physics_js_wasm32.odin: the shim owns the write/strlen link names
// there.)
@(default_calling_convention = "c")
foreign _ {
	@(link_name = "write")
	lib_write :: proc(fd: c.int, buf: cstring, count: c.size_t) -> c.ssize_t ---
	@(link_name = "strlen")
	lib_strlen :: proc(s: cstring) -> c.size_t ---
}

@(private)
log_default_cb :: proc "c" (message: rawptr) {
	msg := cstring(message)
	lib_write(1, "Box3D: ", 8)
	lib_write(1, msg, lib_strlen(msg))
	lib_write(1, "\n", 1)
}
