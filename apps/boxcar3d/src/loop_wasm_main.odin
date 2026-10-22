#+build wasm32
// The bare-wasm entry: the odin driver's _start() runs this (the driver
// owns the heap — the libc-shim's malloc, JS memory-growth included — so
// no allocator swap here). web_boot ends in host.run_app, which on bare
// wasm reaches shim_run_app: the shim stores the callbacks and runs the
// init callback once, frames then arrive via shim_js_frame from the rAF
// loop. (Entry points must be file-level declarations, so this lives in
// its own #+build wasm32 file.)

package main

main :: proc() {
	web_boot(context)
}
