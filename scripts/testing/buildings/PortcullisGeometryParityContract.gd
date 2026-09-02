extends "res://scripts/testing/buildings/CitadelChimneyPublishedContract.gd"

## Actual CPU publication capture/replay; no scene gameplay or visibility credit.
## Baseline MUST be captured with the original publisher before extraction.
const DoorBlueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const SourcePart = preload("res://scripts/buildings/BuildingPart.gd")
const OriginalPublisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const SharedDoor = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const ORIGINAL_SHA := "c3221aedbbf13b39cef367d4b3e42e43848ec78bf0362ead2a143edb15170095"
var _current_object_bindings: Array = []

class DoorLivePublisher extends "res://scripts/buildings/BuildingPartPublisher.gd":
	var actual_batches: Dictionary = {}
	func add_box_batch(parent: Node3D, transforms: Array, material: Material, node_name: String, custom: Array = []) -> MultiMeshInstance3D:
		var node := super.add_box_batch(parent, transforms, material, node_name, custom)
		if node != null: actual_batches[node] = transforms.duplicate(true)
		return node

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var output := OS.get_environment("VOXEL_PORTCULLIS_PARITY_REPORT")
	var source := OS.get_environment("VOXEL_PORTCULLIS_PARITY_SOURCE")
	var source_sha := OS.get_environment("VOXEL_PORTCULLIS_PARITY_SOURCE_SHA256")
	var baseline := OS.get_environment("VOXEL_PORTCULLIS_PARITY_BASELINE")
	var baseline_sha := OS.get_environment("VOXEL_PORTCULLIS_PARITY_BASELINE_SHA256")
	var mode := OS.get_environment("VOXEL_PORTCULLIS_PARITY_MODE")
	if mode not in ["baseline", "replay"] or not _fresh_path(output) or not baseline.is_absolute_path() or baseline == output or source_sha.length() != 64:
		quit(2)
		return
	var archive := _read_binary(source, source_sha)
	if not archive.get("afterSnapshot") is Dictionary:
		quit(2)
		return
	var current_sha := FileAccess.get_sha256("res://scripts/buildings/BuildingPartPublisher.gd")
	var reference: Dictionary = {}
	if mode == "baseline":
		if current_sha != ORIGINAL_SHA or not _fresh_path(baseline):
			quit(2)
			return
	else:
		reference = _read_binary(baseline, baseline_sha)
		if reference.get("schema") != "portcullis_publication_v1" or reference.get("publisherSha256") != ORIGINAL_SHA or reference.get("sourceSha256") != source_sha or not reference.get("rows") is Array:
			quit(2)
			return
	var b = Shops.copy_source(archive.afterSnapshot)
	var fixtures: Array = b.parts.filter(func(part): return part.kind == "door").map(func(part): return part.snapshot())
	var actual_count := fixtures.size()
	for size: Vector3 in [Vector3(0.6, 1.4, 0.08), Vector3(1.25, 2.5, 0.14), Vector3(4.32, 4.7, 0.18)]:
		for turned in [false, true]:
			for raised in [false, true]:
				fixtures.append(SourcePart.new({"id": "synthetic_door_%02d" % fixtures.size(), "kind": "door", "material": "ironwork" if raised else "painted_door",
					"position": Vector3(-14, 3.5, 8) if turned else Vector3.ZERO, "rotation": Vector3(0, 0.71, 0) if turned else Vector3.ZERO, "size": size,
					"recipe": {"variation": 0.013, "doorPresentation": "portcullis" if raised else "door", "doorMotion": "raise" if raised else "swing"}}).snapshot())
	if actual_count == 0 or fixtures.size() > 128:
		quit(2)
		return
	var fixture_digest := _stable_digest(fixtures)
	var publisher = _configured_publisher(b)
	var collider := ColliderPublisher.new()
	var live := DoorLivePublisher.new()
	live.source_blueprint_id = publisher.source_blueprint_id
	live.surface_history.configure(b.recipe, b.parts)
	var rows: Array = []
	var sweep_checks: Array = []
	var complete := true
	for record: Dictionary in fixtures:
		if not _within_budget():
			complete = false
			break
		var part := SourcePart.new(record)
		var visual := _extract_overlap_payload(publisher, b, part, "door_extraction_parity")
		var collision := _collision_payload(collider, part)
		var parent := Node3D.new()
		root.add_child(parent)
		var body = live.publish_part(part, parent)
		var hierarchy: Array = []
		if body != null: _door_nodes(body, "", hierarchy, body)
		complete = complete and body != null and _valid_payload(visual) and _valid_payload(collision) and not hierarchy.is_empty()
		rows.append({"partId": part.id, "visual": visual, "collision": collision, "hierarchy": hierarchy})
		if OS.get_environment("VOXEL_PORTCULLIS_CHECK_SWEEP") == "1" and part.recipe.get("doorPresentation") == "portcullis":
			var actual_boxes: Array = []
			_actual_door_boxes(body, body.get_node("DoorPivot"), false, live, actual_boxes)
			sweep_checks.append(_portcullis_sweep_check(part, actual_boxes, hierarchy))
		parent.free()
		live.published_nodes.clear()
		live.actual_batches.clear()
	var payload := {"schema": "portcullis_publication_v1", "sourceSha256": source_sha, "publisherSha256": ORIGINAL_SHA, "fixtureDigest": fixture_digest, "rows": rows}
	var checks := {"all_actual_and_varied_doors": complete and rows.size() == fixtures.size(), "source_unchanged": FileAccess.get_sha256(source) == source_sha,
		"publisher_unchanged_during_run": FileAccess.get_sha256("res://scripts/buildings/BuildingPartPublisher.gd") == current_sha}
	checks["current_live_interaction_parent_is_owning_body"] = _current_object_bindings.size() == fixtures.size() and _current_object_bindings.all(func(row): return row.passed)
	if mode == "replay":
		checks["exact_pre_extraction_geometry_material_collision_hierarchy_serializable_metadata"] = var_to_bytes(_canonical_value(payload)) == var_to_bytes(_canonical_value(reference))
		checks["baseline_unchanged"] = FileAccess.get_sha256(baseline) == baseline_sha
	if OS.get_environment("VOXEL_PORTCULLIS_CHECK_SWEEP") == "1":
		checks["shared_sweeps_match_actual_published_grille"] = not sweep_checks.is_empty() and sweep_checks.all(func(row): return row.passed)
	var passed: bool = checks.values().all(func(value): return value == true)
	if mode == "baseline" and passed:
		var file := FileAccess.open(baseline, FileAccess.WRITE)
		if file == null: passed = false
		else:
			var bytes := var_to_bytes(payload)
			file.store_buffer(bytes)
			file.flush()
			passed = file.get_error() == OK and file.get_position() == bytes.size()
			file.close()
			passed = passed and not _read_binary(baseline, FileAccess.get_sha256(baseline)).is_empty()
	var report := {"passed": passed, "mode": mode, "checks": checks, "rawByteEncodingEqual": var_to_bytes(payload) == var_to_bytes(reference) if mode == "replay" else true, "firstMismatch": _first_mismatch(reference, payload) if mode == "replay" else {}, "actualDoors": actual_count, "syntheticVariations": fixtures.size() - actual_count,
		"caseCount": rows.size(), "fixtureDigest": fixture_digest, "baselinePath": baseline, "baselineSha256": FileAccess.get_sha256(baseline),
		"sourceSha256": source_sha, "publisherSha256": current_sha, "sweepChecks": sweep_checks, "currentObjectBindings": _current_object_bindings, "baselineObjectBindingsAvailable": false, "elapsedMsec": Time.get_ticks_msec() - _started_msec,
		"limitations": "CPU publication parity preserves serializable metadata with dictionary iteration order excluded. Original binary serialized Object references as null: NO pre-extraction Object-reference parity claim. Current interaction_parent identity is separately checked alive. Static collector flattens nested lever parents; sweep checks instead use actual live hierarchy and captured batch arguments. No rendered appearance, door act, bearing fit or whole-world acceptance."}
	var report_file := FileAccess.open(output, FileAccess.WRITE)
	if report_file == null:
		quit(2)
		return
	report_file.store_string(JSON.stringify(report, "\t"))
	report_file.close()
	quit(0 if passed else 1)

func _actual_door_boxes(node: Node3D, pivot: Node3D, moving: bool, publisher, boxes: Array) -> void:
	moving = moving or node == pivot
	if node is MeshInstance3D:
		boxes.append({"type": "box" if node.mesh == publisher.unit_box else "invalid", "transform": node.global_transform, "moving": moving})
	elif node is MultiMeshInstance3D:
		if not publisher.actual_batches.has(node) or node.multimesh.mesh != publisher.unit_box:
			boxes.append({"type": "invalid", "transform": Transform3D.IDENTITY, "moving": moving})
		else:
			for pose: Transform3D in publisher.actual_batches[node]: boxes.append({"type": "box", "transform": node.global_transform * pose, "moving": moving})
	for child in node.get_children():
		if child is Node3D: _actual_door_boxes(child, pivot, moving, publisher, boxes)

func _portcullis_sweep_check(part, actual_boxes: Array, hierarchy: Array) -> Dictionary:
	var world := Transform3D(Basis.from_euler(part.rotation), part.position)
	var described := SharedDoor.portcullis_closed_primitives(part.size, world)
	var envelopes := SharedDoor.portcullis_sweep_bounds(part.size, world)
	var unmatched: Array = actual_boxes.duplicate(true)
	var failures: Array = []
	var offset: Vector3 = hierarchy[0].metadata.open_visual_offset
	var checked_corners := 0
	var stationary_count := 0
	var moving_count := 0
	for index in range(described.size()):
		var piece: Dictionary = described[index]
		var pose: Transform3D = piece.transform * Transform3D(Basis.from_scale(piece.size), Vector3.ZERO)
		var found := -1
		for item in range(unmatched.size()):
			if unmatched[item].type == "box" and unmatched[item].transform == pose and unmatched[item].moving == piece.moving:
				found = item
				break
		if found < 0:
			failures.append({"piece": piece.name, "reason": "descriptor_not_exact_actual_primitive"})
			continue
		var actual_pose: Transform3D = unmatched[found].transform
		unmatched.remove_at(found)
		if piece.moving: moving_count += 1
		else: stationary_count += 1
		if index >= envelopes.size():
			failures.append({"piece": piece.name, "reason": "missing_sweep"})
			continue
		var envelope: AABB = envelopes[index]
		for ratio: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var at := actual_pose
			if piece.moving: at.origin += (world.basis * offset) * ratio
			for corner in range(8):
				var point: Vector3 = at * AABB(Vector3.ONE * -0.5, Vector3.ONE).get_endpoint(corner)
				checked_corners += 1
				for axis in range(3):
					if point[axis] < envelope.position[axis] or point[axis] > envelope.end[axis]:
						if failures.size() < 8: failures.append({"piece": piece.name, "reason": "actual_translated_corner_outside_sweep", "ratio": ratio, "axis": axis, "point": point, "envelope": envelope})
	var passed: bool = failures.is_empty() and unmatched.is_empty() and described.size() == envelopes.size() and moving_count > 0 and stationary_count == 3 and offset == SharedDoor.raised_visual_offset(part.size)
	return {"partId": part.id, "passed": passed, "checkedCorners": checked_corners, "movingPieces": moving_count, "stationaryPieces": stationary_count, "unmatchedActualPieces": unmatched.size(), "failures": failures}

func _first_mismatch(before: Variant, after: Variant, path: String = "root", depth: int = 0) -> Dictionary:
	if depth > 32: return {"path": path, "reason": "depth_limit"}
	if typeof(before) != typeof(after): return {"path": path, "reason": "type", "before": str(before), "after": str(after)}
	if before is Dictionary:
		if before.size() != after.size() or not before.keys().all(func(key): return after.has(key)): return {"path": path, "reason": "keys"}
		for key in before:
			var mismatch := _first_mismatch(before[key], after[key], path + "." + str(key), depth + 1)
			if not mismatch.is_empty(): return mismatch
	elif before is Array:
		if before.size() != after.size(): return {"path": path, "reason": "array_size"}
		for index in range(before.size()):
			var mismatch := _first_mismatch(before[index], after[index], path + "[%d]" % index, depth + 1)
			if not mismatch.is_empty(): return mismatch
	elif var_to_bytes(before) != var_to_bytes(after): return {"path": path, "reason": "value", "before": str(before), "after": str(after)}
	return {}

func _door_nodes(node: Node, parent_path: String, rows: Array, owner: Node) -> void:
	var path := parent_path + "/" + String(node.name)
	var metadata: Dictionary = {}
	var names: Array = []
	for key in node.get_meta_list(): names.append(String(key))
	names.sort()
	for key in names:
		var value: Variant = node.get_meta(key)
		if typeof(value) == TYPE_OBJECT:
			_current_object_bindings.append({"path": path, "key": key, "ownerPath": String(owner.name), "passed": is_instance_valid(value) and key == "interaction_parent" and value == owner})
			metadata[key] = null # Exact original binary representation, NOT identity proof.
		else: metadata[key] = value
	var record := {"path": path, "class": node.get_class(), "metadata": metadata}
	if node is Node3D: record["transform"] = node.transform
	if node is VisualInstance3D: record["layers"] = node.layers
	if node is GeometryInstance3D: record["castShadow"] = node.cast_shadow
	if node is CollisionObject3D:
		record["collisionLayer"] = node.collision_layer
		record["collisionMask"] = node.collision_mask
	if node is CollisionShape3D:
		record["disabled"] = node.disabled
		record["shapeType"] = node.shape.get_class()
		if node.shape is BoxShape3D: record["shapeSize"] = node.shape.size
	rows.append(record)
	for child in node.get_children(): _door_nodes(child, path, rows, owner)

func _fresh_path(path: String) -> bool:
	return path.is_absolute_path() and not FileAccess.file_exists(path) and DirAccess.dir_exists_absolute(path.get_base_dir())

func _read_binary(path: String, sha: String) -> Dictionary:
	if not path.is_absolute_path() or sha.length() != 64 or FileAccess.get_sha256(path) != sha: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var size := file.get_length()
	if size <= 0 or size > 32 * 1024 * 1024:
		file.close()
		return {}
	var bytes := file.get_buffer(size)
	var read_ok := file.get_error() == OK and bytes.size() == size
	file.close()
	var value: Variant = bytes_to_var(bytes)
	return value if read_ok and value is Dictionary and var_to_bytes(value) == bytes and FileAccess.get_sha256(path) == sha else {}
