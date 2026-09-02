extends SceneTree

## Pure synthetic finite geometry: deliberately no support graph or root proof.
const Recipe = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const HALF := Vector3(0.04, 0.04, 0.07)
const PAD := 0.02
var _checks: Dictionary = {}
var _results: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_HEAD_DIRECT_SOCKET_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	_checks["existing_joint_dimensions"] = Recipe.HALF == HALF and Recipe.PAD == PAD
	_checks["actual_masonry_material_exists"] = Recipe.Materials.DEFINITIONS.has("stone_foundation") and Recipe.Materials.is_masonry_material("stone_foundation")
	var near_result: Dictionary = _positive("near_end", _fixture(-1.0))
	var far_result: Dictionary = _positive("far_end", _fixture(1.0))
	var mirror_ok: bool = near_result.get("ready", false) and far_result.get("ready", false)
	if mirror_ok:
		var near_socket: Vector3 = near_result.socket
		var far_socket: Vector3 = far_result.socket
		mirror_ok = far_socket == Vector3(near_socket.x, near_socket.y, -near_socket.z)
		mirror_ok = mirror_ok and far_result.coreBounds == _mirror_bounds(near_result.coreBounds) and far_result.bodyBounds == _mirror_bounds(near_result.bodyBounds)
		mirror_ok = mirror_ok and far_result.endDomain == [-near_result.endDomain[1], -near_result.endDomain[0]]
		var near_local: Vector3 = near_result.fact.localOverlapCenter
		mirror_ok = mirror_ok and far_result.fact.localOverlapCenter == Vector3(near_local.x, near_local.y, -near_local.z)
	_checks["mirror_exact_socket_bounds_and_domain"] = mirror_ok
	# The declared end zone is its FULL footprint, not its reduced masonry bed.
	var outer_zone: Dictionary = _fixture(1.0)
	outer_zone.masonry.position.z = 1.78
	var outer_result: Dictionary = _positive("full_declared_gable_footprint", outer_zone)
	_checks["full_footprint_positive_outside_gable_core"] = outer_result.get("ready", false) and float(outer_result.socket.z) > 1.675 and float(outer_result.socket.z) <= 1.75
	for mode: String in ["shifted_wrong_end", "opposite_half_wide_gable", "far_away", "thin_x", "thin_y", "thin_z", "nonmasonry", "noncollision", "wrong_kind"]:
		var fixture: Dictionary = _fixture(-1.0)
		match mode:
			"shifted_wrong_end": fixture.masonry.position.z = 1.5
			"opposite_half_wide_gable":
				fixture.gable.size.z = 8.0
				fixture.masonry.position.z = 1.5
			"far_away": fixture.masonry.position.x = 10.0
			"thin_x": fixture.masonry.size.x = 0.1
			"thin_y": fixture.masonry.size.y = 0.1
			"thin_z": fixture.masonry.size.z = 0.1
			"nonmasonry": fixture.masonry.material_id = "timber_beam"
			"noncollision": fixture.masonry.collision_enabled = false
			"wrong_kind": fixture.masonry.kind = "beam"
		_reject(mode, fixture)
	for member: String in ["body", "gable", "masonry"]:
		for mode: String in ["rotated", "degenerate", "nonfinite"]:
			var fixture: Dictionary = _fixture(-1.0)
			# Mutate the actual Part after construction; do not let Part's minimum
			# size coercion convert a deliberately degenerate control into a box.
			match mode:
				"rotated": fixture[member].rotation.y = PI * 0.25
				"degenerate": fixture[member].size = Vector3.ZERO
				"nonfinite": fixture[member].position.x = INF
			_reject(member + "_" + mode, fixture)
	for member: String in ["body", "gable"]:
		var no_collision: Dictionary = _fixture(-1.0)
		no_collision[member].collision_enabled = false
		_reject(member + "_noncollision", no_collision)
		var wrong_kind: Dictionary = _fixture(-1.0)
		wrong_kind[member].kind = "wall" if member == "body" else "beam"
		_reject(member + "_wrong_kind", wrong_kind)
	var ambiguous: Dictionary = _fixture(-1.0)
	ambiguous.gable.position.z = ambiguous.body.position.z
	_reject("ambiguous_declared_end", ambiguous)
	_finish(path)

func _fixture(side: float) -> Dictionary:
	return {"body": _part("synthetic_body", "beam", Vector3(0, 1, 0), Vector3(0.5, 0.5, 4), "timber_beam"),
		"gable": _part("synthetic_declared_gable", "wall", Vector3(0, 1, side * 1.5), Vector3(2, 2, 0.5)),
		"masonry": _part("synthetic_masonry", "wall", Vector3(0, 1, side * 1.5), Vector3(0.5, 1, 0.5))}

func _part(id: String, kind: String, position: Vector3, size: Vector3, material: String = "stone_foundation"):
	return Part.new({"id": id, "kind": kind, "position": position, "size": size, "material": material, "collision": true, "recipe": {}})

func _probe(name: String, fixture: Dictionary) -> Dictionary:
	var frozen: PackedByteArray = _input_bytes(fixture)
	var result: Dictionary = Recipe.direct_socket(fixture.body, fixture.gable, fixture.masonry)
	_checks[name + "_immutable"] = frozen == _input_bytes(fixture)
	var repeat: Dictionary = Recipe.direct_socket(fixture.body, fixture.gable, fixture.masonry)
	_checks[name + "_deterministic"] = var_to_bytes(result) == var_to_bytes(repeat) and frozen == _input_bytes(fixture)
	_results[name] = result
	return result

func _input_bytes(fixture: Dictionary) -> PackedByteArray:
	return var_to_bytes([fixture.body.snapshot(), fixture.gable.snapshot(), fixture.masonry.snapshot()])

func _positive(name: String, fixture: Dictionary) -> Dictionary:
	var result: Dictionary = _probe(name, fixture)
	_checks[name + "_ready"] = result.get("ready") == true
	_checks[name + "_complete_finite_geometry"] = _verify_geometry(result, fixture)
	return result

func _verify_geometry(result: Dictionary, fixture: Dictionary) -> bool:
	if not result.get("ready", false) or not result.get("socket") is Vector3 or not result.get("fact") is Dictionary: return false
	var socket: Vector3 = result.socket
	if not socket.is_finite(): return false
	var body: Array = _bounds(fixture.body.position, fixture.body.size)
	# Independent transcription of the existing core's represented dimensions.
	var core_size: Vector3 = fixture.masonry.size
	core_size.x = maxf(0.02, core_size.x - minf(0.16, core_size.x * 0.30))
	core_size.z = maxf(0.02, core_size.z - minf(0.16, core_size.z * 0.30))
	var core: Array = _bounds(fixture.masonry.position, core_size)
	var gable: Array = _bounds(fixture.gable.position, fixture.gable.size)
	if result.get("bodyBounds") != body or result.get("coreBounds") != core: return false
	for axis in range(3):
		var low: float = float(socket[axis]) - float(HALF[axis]) - PAD
		var high: float = float(socket[axis]) + float(HALF[axis]) + PAD
		if not is_finite(low) or not is_finite(high) or low >= high or low < body[axis] or high > body[axis + 3] or low < core[axis] or high > core[axis + 3]: return false
	var side: float = signf(fixture.gable.position.z - fixture.body.position.z)
	if float(socket.z) < gable[2] or float(socket.z) > gable[5]: return false
	if side < 0.0 and float(socket.z) + float(HALF.z) + PAD > float(fixture.body.position.z): return false
	if side > 0.0 and float(socket.z) - float(HALF.z) - PAD < float(fixture.body.position.z): return false
	var domain: Variant = result.get("endDomain")
	if not domain is Array or domain.size() != 2 or not is_finite(domain[0]) or not is_finite(domain[1]) or domain[0] > domain[1] or float(socket.z) < domain[0] or float(socket.z) > domain[1]: return false
	var fact: Dictionary = result.fact
	return fact.get("seatId") == fixture.masonry.id and fact.get("contactMode") == "housed_overlap" and fact.get("localSpanAxis") == "z" and fact.get("localOverlapCenter") == socket - fixture.body.position and fact.get("localOverlapHalfExtents") == HALF and fact.get("minimumLongitudinalEmbedment") == 0.12 and fact.get("minimumVerticalOverlap") == 0.04

func _bounds(center: Vector3, size: Vector3) -> Array:
	return [float(center.x) - float(size.x) * 0.5, float(center.y) - float(size.y) * 0.5, float(center.z) - float(size.z) * 0.5,
		float(center.x) + float(size.x) * 0.5, float(center.y) + float(size.y) * 0.5, float(center.z) + float(size.z) * 0.5]

func _mirror_bounds(bounds: Array) -> Array:
	return [bounds[0], bounds[1], -bounds[5], bounds[3], bounds[4], -bounds[2]]

func _reject(name: String, fixture: Dictionary) -> void:
	var result: Dictionary = _probe(name, fixture)
	_checks[name + "_rejected"] = result.get("ready") == false and not String(result.get("reason", "")).is_empty() and not result.has("fact")

func _finish(path: String) -> void:
	var passed: bool = not _checks.is_empty() and _checks.values().all(func(v): return v == true)
	var report: Dictionary = {"passed": passed, "NoRootProof": true, "evidenceLevel": "synthetic_finite_source_socket_geometry_only", "checks": _checks, "results": _results,
		"limitations": "No root/support-chain or bearing capacity proof. No physical validator, collision publication, rendered geometry, actual-house, GPU, physics frames or live gameplay acceptance. Bounds include the complete finite socket plus existing construction pad without tolerances."}
	var bytes: PackedByteArray = JSON.stringify(report, "  ").to_utf8_buffer()
	if FileAccess.file_exists(path) or bytes.size() > 1024 * 1024:
		quit(2)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_length() == bytes.size()
	file.close()
	var hashing := HashingContext.new()
	written = written and hashing.start(HashingContext.HASH_SHA256) == OK
	if written:
		written = hashing.update(bytes) == OK
		if written: written = FileAccess.get_sha256(path) == hashing.finish().hex_encode()
	quit(0 if passed and written else 2)
