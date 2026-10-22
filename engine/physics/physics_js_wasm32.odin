package physics

import "base:runtime"
import "core:fmt"

// Default log sink for the bare-wasm build: the libc-shim owns the
// write/strlen link names there (the native sink's bare externs would
// be non-unique), so go through Odin's fmt instead — on this target the
// runtime's write reaches odin_env.write, which the JS glue routes to
// the console. The C-ABI callback has no context, so take the default.
@(private)
log_default_cb :: proc "c" (message: rawptr) {
	context = runtime.default_context()
	fmt.print("Box3D: %s\n", string(cstring(message)))
}
