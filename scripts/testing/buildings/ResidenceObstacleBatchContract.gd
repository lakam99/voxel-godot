extends SceneTree

## Synthetic descriptor geometry using the real overlap authority. The oracle
## calls the frozen d093c89 singleton API, not the new batch implementation.
## No Castle build, Nodes, physical publication or gameplay acceptance.
const Geometry = preload("res://scripts/buildings/CastleResidencePlacementGeometry.gd")
const Original = preload("res://artifacts/citadel-runtime-integration/residence-obstacle-original/CastleResidencePlacementGeometry.gd")
const ORIGINAL_SHA := "fcd37306189d0f1bdf40608bf9e3ff11c57e9aaf61458fb709b60b56b6901fee"
var output := ""
var deadline := 0
var checks: Dictionary = {}
var evidence: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output = OS.get_environment("RESIDENCE_OBSTACLE_BATCH_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.file_exists(output.get_basename()+".bin"):
		quit(2)
		return
	deadline = Time.get_ticks_msec()+30000
	var worker := Thread.new()
	if worker.start(_work) != OK:
		quit(2)
		return
	while worker.is_alive():
		await process_frame
	var report: Dictionary = worker.wait_to_finish()
	var saved: bool = _write(report)
	print("Residence obstacle batch checks=", checks.size(), " passed=", report.passed)
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var before: Dictionary = _hashes()
	checks["frozen_original_sha"] = FileAccess.get_sha256("res://artifacts/citadel-runtime-integration/residence-obstacle-original/CastleResidencePlacementGeometry.gd") == ORIGINAL_SHA
	if checks.frozen_original_sha:
		_parity_controls()
		_cancellation_controls()
		_mutation_controls()
		_benchmark()
	var after: Dictionary = _hashes()
	checks["source_hashes_unchanged"] = before == after
	checks["internal_deadline"] = _within_deadline()
	return {"passed":checks.values().all(func(value: Variant) -> bool: return value == true),
		"checks":checks, "evidence":evidence, "sourceHashesBefore":before, "sourceHashesAfter":after,
		"elapsedUsec":Time.get_ticks_usec()-started, "internalDeadlineSeconds":30,
		"oracleRevision":"d093c89; frozen script with LF normalization and class_name removed only",
		"scope":"Synthetic exact oriented descriptors; frozen original and current singleton versus batch. No generated-source or gameplay acceptance; timings observational, no ratio threshold."}

func _part(id: String, center: Vector3, size: Vector3 = Vector3(2,2,2), yaw: float = 0.0) -> Dictionary:
	return {"id":id, "center":center, "size":size, "basis":Basis(Vector3.UP,yaw)}

func _composition() -> Dictionary:
	return Geometry.refreshed_aggregate({"residenceId":"synthetic_residence",
		"collisionParts":[_part("wall",Vector3.ZERO)],
		"doorCorridor":_part("corridor",Vector3(0,0,4))})

func _obstacles() -> Array:
	return [_part("coincident",Vector3.ZERO), _part("tangent",Vector3(2,0,0)),
		_part("separated",Vector3(2.2,0,0)), _part("rotated",Vector3(1.5,0,0),Vector3(2,2,2),PI/4.0),
		_part("vertical_separation",Vector3(0,8,0)), _part("corridor",Vector3(0,0,4)),
		_part("distant",Vector3(1000,0,1000))]

func _legacy(composition: Dictionary, obstacles: Array, clearance: float) -> Array[int]:
	var indices: Array[int] = []
	for index: int in range(obstacles.size()):
		if not _within_deadline():
			checks["legacy_deadline"] = false
			return indices
		if Original.composition_overlaps_obstacles(composition,[obstacles[index]],clearance):
			indices.append(index)
	return indices

func _parity(name: String, composition: Dictionary, obstacles: Array, clearance: float) -> void:
	var original: PackedByteArray = var_to_bytes([composition,obstacles])
	var expected: Array[int] = _legacy(composition,obstacles,clearance)
	checks[name+"_legacy_whole_array_preserved"] = Geometry.composition_overlaps_obstacles(composition,obstacles,clearance) == Original.composition_overlaps_obstacles(composition,obstacles,clearance)
	var current_singletons: Array[int] = []
	for index: int in range(obstacles.size()):
		if Geometry.composition_overlaps_obstacles(composition,[obstacles[index]],clearance): current_singletons.append(index)
	checks[name+"_current_singletons_match_original"] = var_to_bytes(current_singletons) == var_to_bytes(expected)
	var trace: Array[int] = []
	var result: Dictionary = Geometry.composition_obstacle_overlap_indices(composition,obstacles,clearance,func() -> bool:
		trace.append(trace.size())
		return _within_deadline())
	var expected_trace: Array[int] = []
	for index: int in range(obstacles.size()): expected_trace.append(index)
	checks[name+"_ready"] = result.get("status") == "ready"
	checks[name+"_typed_ordered_indices"] = var_to_bytes(result.get("overlapIndices")) == var_to_bytes(expected)
	checks[name+"_comparisons"] = result.get("comparisons") == obstacles.size()
	# The zero-argument callback exposes ordinal visits, not obstacle identities.
	# Exact ordered output and singleton parity independently bind obstacle order.
	checks[name+"_callback_visits"] = var_to_bytes(trace) == var_to_bytes(expected_trace)
	checks[name+"_inputs_immutable"] = original == var_to_bytes([composition,obstacles])
	evidence[name] = {"expectedIndices":expected,"result":result,"callbackOrdinals":trace,"clearance":clearance}

func _parity_controls() -> void:
	var composition: Dictionary = _composition()
	var obstacles: Array = _obstacles()
	evidence["tinyInputs"] = {"composition":composition.duplicate(true),"obstacles":obstacles.duplicate(true)}
	_parity("ordinary",composition,obstacles,0.0)
	_parity("clearance",composition,obstacles,0.25)
	checks["fixture_coincident_overlaps"] = Geometry.composition_overlaps_obstacles(composition,[obstacles[0]],0.0)
	checks["fixture_tangent_separated"] = not Geometry.composition_overlaps_obstacles(composition,[obstacles[1]],0.0)
	checks["fixture_clearance_closes_gap"] = Geometry.composition_overlaps_obstacles(composition,[obstacles[2]],0.25)
	var rotated: Dictionary = composition.duplicate(true)
	rotated.collisionParts[0].basis = Basis(Vector3.UP,PI/3.0)
	rotated = Geometry.refreshed_aggregate(rotated)
	_parity("rotated_composition",rotated,obstacles,0.1)
	_parity("empty_obstacles",composition,[],0.0)
	_parity("empty_composition",{},obstacles,0.0)
	_parity("both_empty",{},[],0.0)
	var malformed: Dictionary = composition.duplicate(true)
	malformed.collisionParts[0].basis = Basis(Vector3(2,0,0),Vector3.UP,Vector3.BACK)
	_parity("malformed_composition_basis",malformed,obstacles,0.0)
	malformed = composition.duplicate(true)
	malformed.doorCorridor = {}
	_parity("malformed_corridor",malformed,obstacles,0.0)
	var malformed_obstacles: Array = obstacles.duplicate(true)
	malformed_obstacles.append(null)
	malformed_obstacles.append("not_a_descriptor")
	malformed_obstacles.append(_part("invalid_distant_size",Vector3(1000,0,1000),Vector3(-1,2,2)))
	var invalid_basis: Dictionary = _part("invalid_distant_basis",Vector3(1000,0,1000))
	invalid_basis.basis = Basis(Vector3.ZERO,Vector3.UP,Vector3.BACK)
	malformed_obstacles.append(invalid_basis)
	_parity("malformed_obstacles_including_distant",composition,malformed_obstacles,0.0)
	var default_result: Dictionary = Geometry.composition_obstacle_overlap_indices(composition,obstacles,0.0)
	checks["empty_continuation_exact"] = var_to_bytes(default_result) == var_to_bytes(evidence.ordinary.result)

func _cancellation_controls() -> void:
	for stop: int in [1,4,7]:
		var composition: Dictionary = _composition()
		var obstacles: Array = _obstacles()
		var original: PackedByteArray = var_to_bytes([composition,obstacles])
		var state: Dictionary = {"calls":0,"rejected":false,"afterFalse":0}
		var result: Dictionary = Geometry.composition_obstacle_overlap_indices(composition,obstacles,0.0,func() -> bool:
			if state.rejected: state.afterFalse += 1
			state.calls += 1
			state.rejected = state.calls >= stop or not _within_deadline()
			return not state.rejected)
		var label := "cancel_at_%d" % stop
		checks[label+"_terminal_no_partial"] = result == {"status":"cancelled"}
		checks[label+"_no_later_callbacks"] = state.calls == stop and state.afterFalse == 0
		checks[label+"_inputs_immutable"] = original == var_to_bytes([composition,obstacles])
		evidence[label] = {"result":result,"callbackState":state}

func _mutation_controls() -> void:
	for mode: String in ["composition_nested","obstacle_nested","obstacle_array"]:
		for trigger: int in [1,4,7]:
			var composition: Dictionary = _composition()
			var obstacles: Array = _obstacles()
			var state: Dictionary = {"calls":0,"mutated":false}
			var result: Dictionary = Geometry.composition_obstacle_overlap_indices(composition,obstacles,0.0,func() -> bool:
				state.calls += 1
				if state.calls == trigger:
					state.mutated = true
					match mode:
						"composition_nested": composition.collisionParts[0].center = Vector3(40,0,0)
						"obstacle_nested": obstacles[0].center = Vector3(50,0,0)
						"obstacle_array": obstacles.append(_part("callback_added",Vector3.ZERO))
				return _within_deadline())
			var label := "mutation_%s_at_%d" % [mode,trigger]
			checks[label+"_cancelled_no_partial"] = state.mutated and result == {"status":"cancelled"}
			checks[label+"_private_obstacle_count"] = state.calls == 7
			checks[label+"_caller_mutation_not_rolled_back"] = composition.collisionParts[0].center == Vector3(40,0,0) if mode == "composition_nested" else (obstacles[0].center == Vector3(50,0,0) if mode == "obstacle_nested" else obstacles.size() == 8)
			evidence[label] = {"result":result,"callbackState":state}

func _benchmark() -> void:
	var rows: Array[Dictionary] = []
	for pose: int in range(5):
		if not _within_deadline(): break
		var parts: Array[Dictionary] = []
		var yaw: float = float(pose)*0.17
		var basis := Basis(Vector3.UP,yaw)
		for index: int in range(200):
			parts.append(_part("part_%d"%index,basis*Vector3(float(index%20)*2.0,0,float(int(index/20.0))*2.0),Vector3(1,2,1),yaw))
		var composition: Dictionary = Geometry.refreshed_aggregate({"collisionParts":parts,"doorCorridor":_part("door",Vector3(0,0,-3))})
		var obstacles: Array = []
		for index: int in range(500):
			var center := Vector3(1000+index*3,0,1000)
			if index%10 == 0: center = basis*Vector3(float(int(index/10.0)%20)*2.0,0,float(index%7)*2.0)
			obstacles.append(_part("obstacle_%d"%index,center,Vector3(1,2,1),-yaw))
		var input_bytes: PackedByteArray = var_to_bytes([composition,obstacles])
		var started := Time.get_ticks_usec()
		var expected: Array[int] = _legacy(composition,obstacles,0.15)
		var legacy_usec: int = Time.get_ticks_usec()-started
		started = Time.get_ticks_usec()
		var result: Dictionary = Geometry.composition_obstacle_overlap_indices(composition,obstacles,0.15,_within_deadline)
		var batch_usec: int = Time.get_ticks_usec()-started
		checks["benchmark_pose_%d_exact"%pose] = result.get("status") == "ready" and result.get("comparisons") == 500 and var_to_bytes(expected) == var_to_bytes(result.get("overlapIndices"))
		checks["benchmark_pose_%d_immutable"%pose] = input_bytes == var_to_bytes([composition,obstacles])
		rows.append({"pose":pose,"yaw":yaw,"partCount":200,"obstacleCount":500,"legacyUsec":legacy_usec,"batchUsec":batch_usec,"expectedIndices":expected,"result":result})
	checks["benchmark_all_five_poses"] = rows.size() == 5
	evidence["benchmark"] = {"rows":rows,"order":"frozen original singleton then batch per pose; includes batch copying/binding; deadline callback included; no hard ratio assertion"}

func _within_deadline() -> bool:
	return Time.get_ticks_msec() < deadline

func _hashes() -> Dictionary:
	var result: Dictionary = {}
	var pending: Array[String] = [get_script().resource_path,"res://project.godot","res://tools/run-building-contract.ps1"]
	var regex := RegEx.create_from_string('["\'](res://[^"\'\\r\\n]+)["\']')
	while not pending.is_empty():
		var path: String = pending.pop_back()
		if result.has(path): continue
		var digest: String = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		result[path] = digest
		if digest.length() != 64:
			checks["source_hashes_valid"] = false
			continue
		if path.get_extension() != "gd": continue
		for matched: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dependency: String = matched.get_string(1)
			if dependency.get_extension() in ["gd","gdshader"]: pending.append(dependency)
	return result

func _write(report: Dictionary) -> bool:
	var file := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if file == null: return false
	file.store_var(report,false)
	file.flush()
	var saved: bool = file.get_error() == OK
	file.close()
	file = FileAccess.open(output,FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(_json(report),"\t",true,true))
	file.flush()
	saved = saved and file.get_error() == OK
	file.close()
	return saved

func _json(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array: return value.map(_json)
	if value is Vector3: return {"type":"Vector3","value":[value.x,value.y,value.z]}
	if value is Basis: return {"type":"Basis","x":_json(value.x),"y":_json(value.y),"z":_json(value.z)}
	return value
