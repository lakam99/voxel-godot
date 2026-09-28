extends SceneTree

const Plan = preload("res://scripts/terrain/NativeTerrainEditRepublicationPlan.gd")
var checks := {}

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, value: bool) -> void:
	checks[name] = value

func _run() -> void:
	var seam: Dictionary = Plan.for_committed_cells(
		[Vector3i(-1, -1, 15), Vector3i(0, 0, 16)],
		[Vector3i(-1, -1, 0), Vector3i(0, 0, 1)], 17, "seed:epoch-a")
	var replacement: Array = seam.get("replacementDataBlocks", [])
	var meshes: Array = seam.get("affectedMeshBlocks", [])
	var inputs: Array = seam.get("requiredInputBlocks", [])
	_check("negative_and_positive_seam_blocks", seam.get("status") == "ready"
		and replacement.size() == 2 and replacement.has(Vector3i(-1, -1, 0))
		and replacement.has(Vector3i(0, 0, 1)))
	_check("affected_mesh_halo", meshes.has(Vector3i(-2, -2, -1))
		and meshes.has(Vector3i(1, 1, 2)))
	_check("input_halo_extends_beyond_mesh", inputs.has(Vector3i(-3, -3, -2))
		and inputs.has(Vector3i(2, 2, 3)))
	var reverse: Dictionary = Plan.for_committed_cells(
		[Vector3i(0, 0, 16), Vector3i(-1, -1, 15), Vector3i(0, 0, 16)],
		[Vector3i(0, 0, 1), Vector3i(-1, -1, 0)], 17, "seed:epoch-a")
	_check("deterministic_and_duplicate_independent", var_to_bytes(seam) == var_to_bytes(reverse))
	var adjacent: Dictionary = Plan.for_committed_cells(
		[Vector3i.ZERO, Vector3i(16, 0, 0)], [Vector3i.ZERO, Vector3i(1, 0, 0)],
		18, "seed:epoch-a")
	var windows: Array = adjacent.get("subwindows", [])
	var window_union := {}
	var bounded := windows.size() > 1
	for window in windows:
		var actual: Dictionary = preload("res://scripts/terrain/NativeVoxelBlockDemandFootprint.gd").data_blocks_for_mesh_blocks(window.meshBlocks)
		bounded = bounded and actual.get("status") == "ready" and actual.blocks == window.dataBlocks \
			and window.dataBlocks.size() <= 128
		for block in window.dataBlocks:
			window_union[block] = true
	_check("adjacent_edit_partitioned_into_admittable_windows", bounded)
	var required_inputs: Array = adjacent.get("requiredInputBlocks", [])
	var complete_input_halo := window_union.size() == required_inputs.size()
	for block in required_inputs:
		complete_input_halo = complete_input_halo and window_union.has(block)
	_check("window_union_covers_complete_input_halo", complete_input_halo)
	var receipts: Array = []
	for window in windows:
		var block_receipts: Array = []
		for mesh_block in window.meshBlocks:
			block_receipts.append({"block":mesh_block, "generation":2, "physicalReady":true})
		receipts.append({"index":window.index, "token":window.token,
			"nativeRevision":18, "status":"ready", "meshBlockReceipts":block_receipts})
	var partial := receipts.duplicate(true)
	partial.pop_back()
	_check("activation_waits_for_all_subwindows", Plan.publication_barrier_status(adjacent, partial).get("status") == "pending")
	_check("complete_revision_barrier_activates", Plan.publication_barrier_status(adjacent, receipts).get("status") == "ready")
	var incomplete_mesh := receipts.duplicate(true)
	incomplete_mesh[0].meshBlockReceipts.pop_back()
	_check("one_missing_mesh_proof_blocks_activation", Plan.publication_barrier_status(adjacent, incomplete_mesh).get("status") == "failed")
	var stale := receipts.duplicate(true)
	stale[0].nativeRevision = 17
	_check("stale_revision_cannot_activate", Plan.publication_barrier_status(adjacent, stale).get("status") == "failed")
	var duplicate := receipts.duplicate(true)
	duplicate.append(receipts[0])
	_check("duplicate_subwindow_cannot_activate", Plan.publication_barrier_status(adjacent, duplicate).get("status") == "failed")
	var retry := Plan.for_committed_cells(
		[Vector3i.ZERO, Vector3i(16, 0, 0)], [Vector3i.ZERO, Vector3i(1, 0, 0)],
		19, "seed:epoch-a")
	_check("later_revision_rejects_prior_receipts", Plan.publication_barrier_status(retry, receipts).get("status") == "failed")
	_check("unbound_plan_cannot_activate", Plan.publication_barrier_status(
		Plan.for_committed_cells([Vector3i.ZERO], [Vector3i.ZERO]), []).get("status") == "failed")
	_check("mismatched_commit_receipt_fails_closed", Plan.for_committed_cells(
		[Vector3i(16, 0, 0)], [Vector3i.ZERO]).get("reason") == "changed_cell_absent_from_native_receipt")
	_check("empty_edit_cannot_publish", Plan.for_committed_cells([], [Vector3i.ZERO]).get("status") == "failed")
	_check("wrong_receipt_type_cannot_publish", Plan.for_committed_cells(
		[Vector3i.ZERO], ["0,0,0"]).get("reason") == "invalid_affected_section")
	var sparse: Array[Vector3i] = []
	var sparse_sections: Array = []
	for x in range(65):
		sparse.append(Vector3i(x * 160, 0, 0))
		sparse_sections.append(Vector3i(x * 10, 0, 0))
	_check("unbounded_transaction_fails_closed", Plan.for_committed_cells(
		sparse, sparse_sections).get("reason") == "changed_block_limit")
	var passed := not checks.values().has(false)
	var report := {"schema":"n3-terrain-edit-republication-plan-contract/v1",
		"passed":passed, "evidenceLevel":"pure-planner-contract",
		"productionCutover":false, "checks":checks}
	var path := OS.get_environment("VWB_EDIT_REPUBLICATION_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if passed else 1)
