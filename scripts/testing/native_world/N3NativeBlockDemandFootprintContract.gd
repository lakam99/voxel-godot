extends SceneTree

const Footprint = preload("res://scripts/terrain/NativeVoxelBlockDemandFootprint.gd")
var checks := {}

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, valid: bool) -> void:
	checks[label] = valid

func _run() -> void:
	var center: Dictionary = Footprint.data_blocks_for_mesh_blocks([Vector3i.ZERO])
	var blocks: Array = center.get("blocks", [])
	_check("single_mesh_block_has_27_inputs", center.get("status") == "ready" and blocks.size() == 27)
	_check("negative_vertical_and_xz_halo", blocks.has(Vector3i(-1, -1, -1)))
	_check("upper_vertical_halo", blocks.has(Vector3i(1, 1, 1)))
	var adjacent: Dictionary = Footprint.data_blocks_for_mesh_blocks([Vector3i.ZERO, Vector3i(0, 1, 0), Vector3i.ZERO])
	var expanded: Array = adjacent.get("blocks", [])
	_check("adjacent_vertical_mesh_blocks_union_36", adjacent.get("status") == "ready" and expanded.size() == 36)
	_check("upper_y2_input_retained", expanded.has(Vector3i(0, 2, 0)))
	var reversed: Dictionary = Footprint.data_blocks_for_mesh_blocks([Vector3i(0, 1, 0), Vector3i.ZERO])
	_check("order_and_duplicate_independent", var_to_bytes(expanded) == var_to_bytes(reversed.get("blocks", [])))
	_check("empty_demand_fails_closed", Footprint.data_blocks_for_mesh_blocks([]).get("reason") == "mesh_block_demand_limit")
	var far: Array[Vector3i] = []
	for x in range(64):
		far.append(Vector3i(x * 4, 0, 0))
	_check("byte_budget_fails_closed", Footprint.data_blocks_for_mesh_blocks(far).get("reason") == "data_block_demand_limit")
	far.append(Vector3i(256, 0, 0))
	_check("mesh_budget_fails_closed", Footprint.data_blocks_for_mesh_blocks(far).get("reason") == "mesh_block_demand_limit")
	var passed := not checks.values().has(false)
	var report := {"schema":"n3-native-block-demand-footprint-contract/v1", "passed":passed,
		"evidenceLevel":"pure-demand-planner-contract", "productionCutover":false, "checks":checks}
	var path := OS.get_environment("VWB_BLOCK_FOOTPRINT_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if passed else 1)
