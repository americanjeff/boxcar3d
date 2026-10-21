// E2E test — engine:graphics mesh-handle sentinel contract.
//
// The invalid sentinel must pack to renderer index -1, matching the
// renderer's InvalidMeshHandle() { -1, 0u }: IsMeshHandleValid accepts
// `h.index >= 0` with only the zero value (index 0, hash 0) additionally
// rejected, so -1 is the invalid marker that cannot collide with a
// registered mesh. This test runs the real binding path
// (`Is_Mesh_Handle_Valid` → `shim_is_mesh_handle_valid` →
// `IsMeshHandleValid`) against the real `libgraphics_native.a`, so it
// exercises the same C call the app makes.
//
// Pass = exit 0. Build + run via tools/test.sh (needs engine libs built).

package main

import "core:fmt"
import "core:os"
import gfx "engine:graphics"

main :: proc() {
	failures := 0

	// (1) The invalid sentinel MUST be invalid.
	if gfx.Is_Mesh_Handle_Valid(gfx.Invalid_Mesh_Handle) {
		fmt.eprintln("FAIL: gfx.Invalid_Mesh_Handle is reported valid (index should be -1)")
		failures += 1
	} else {
		fmt.println("PASS: Invalid_Mesh_Handle is invalid")
	}

	// (2) A handle with index 0 and a non-zero hash is the shape a
	//     successfully-registered *first* mesh has. It must be valid AND
	//     distinct from the invalid sentinel (which carries index -1).
	valid_first :: gfx.Mesh_Handle(0x0000_0000_0000_0001) // index 0, hash 1
	if !gfx.Is_Mesh_Handle_Valid(valid_first) {
		fmt.eprintln("FAIL: a real index-0/non-zero-hash handle is reported invalid")
		failures += 1
	} else {
		fmt.println("PASS: real index-0 handle is valid and distinct from the sentinel")
	}

	// (3) The sentinel must be a *different token* from any real first-mesh
	//     handle (this is what the app's `append_terrain` guard relies on when
	//     init_terrain_mesh has not run).
	if gfx.Invalid_Mesh_Handle == valid_first {
		fmt.eprintln("FAIL: Invalid_Mesh_Handle collides with a real handle")
		failures += 1
	} else {
		fmt.println("PASS: Invalid_Mesh_Handle != a real handle")
	}

	// (4) The zero value (index 0, hash 0) is never a real handle — RegisterMesh
	//     asserts hash != 0 — so it MUST be reported invalid. If it were valid
	//     it would read as slot 0 (the first registered mesh), and releasing a
	//     zero-initialized slot would free that mesh.
	zero_handle :: gfx.Mesh_Handle(0)
	if gfx.Is_Mesh_Handle_Valid(zero_handle) {
		fmt.eprintln("FAIL: the zero-value handle is reported valid (it must be invalid)")
		failures += 1
	} else {
		fmt.println("PASS: the zero-value handle is invalid")
	}

	if failures > 0 {
		fmt.eprintf("\n%d failure(s)\n", failures)
		os.exit(1)
	}
	fmt.println("\nAll mesh_handle checks passed.")
}
