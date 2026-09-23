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
		[Vector3i(-1, -1, 0), Vector3i(0, 0, 1)])
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
		[Vector3i(0, 0, 1), Vector3i(-1, -1, 0)])
	_check("deterministic_and_duplicate_independent", var_to_bytes(seam) == var_to_bytes(reverse))
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
