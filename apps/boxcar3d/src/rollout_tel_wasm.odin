#+build wasm32
// Wasm no-ops for the rollout tel boundary: evolve.odin calls these
// unconditionally - the symbols just need to exist. The real
// implementations live in rollout_telemetry.odin (!wasm32).


package main

tel_init :: proc(tel: ^Tel_Writer, dir: string, gen, car: int) {
	tel^ = {}
}

tel_sample :: proc(tel: ^Tel_Writer, sim: ^Sim_State, s_buf: []f32) {
}

tel_finish :: proc(tel: ^Tel_Writer) {
}
