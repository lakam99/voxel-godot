extends "res://scripts/testing/buildings/CitadelGablePurlinVisualProbe.gd"

## Unwired source/publisher contract. Inherits snapshot/copy/valid-box helpers,
## NOT the parent's _run. Does not compose, validate routes, or accept placement.
## Inputs: VOXEL_ROOF_INTEGRATION_BASELINE, VOXEL_MARKET_CANDIDATE_REPORT.
## Report supplies producer-derived membership only. The shared recipe chooses
## the transform afresh; diagnostic coordinates never prescribe placement.
## Output: VOXEL_MARKET_RIGID_REPORT (new absolute JSON path).
const MARKET_FROZEN_SHA := "7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5"
const UrbanRecipe = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const SOURCE_BASIS_EPS := 0.000001
const PAYLOAD_ARITHMETIC_EPS := 0.00001
var _rigid_path := ""


func _run() -> void:
	var started := Time.get_ticks_msec()
	var baseline := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE").strip_edges().simplify_path()
	var input_path := OS.get_environment("VOXEL_MARKET_CANDIDATE_REPORT").strip_edges().simplify_path()
	_rigid_path = OS.get_environment("VOXEL_MARKET_RIGID_REPORT").strip_edges().simplify_path()
	var report := {"evidenceLevel": "frozen_source_and_actual_publisher_payload_contract", "passed": false,
		"baselinePath": baseline, "baselineSha256": MARKET_FROZEN_SHA, "candidateReportPath": input_path,
		"candidateSelection": "Shared recipe recomputes transform from frozen geometry and producer-derived groups[2].allIds; report pose ignored",
		"placementAuthority": "CitadelUrbanPocComposer.plan_household_on_paving; source/payload contract only, no visual acceptance",
		"placementAccepted": false, "sourcePositionComparison": "exact expected transformed position",
		"sourceBasisArithmeticTolerance": SOURCE_BASIS_EPS, "payloadTransformArithmeticTolerance": PAYLOAD_ARITHMETIC_EPS,
		"doesNotProve": "No room/door/approach clearance, valid placement, headed appearance, GPU readback, live collision, navigation, general seeds, or whole-citadel gate. Material snapshots cover stored properties/shader parameters, not external texture pixels. World-position history custom-data changes remain explicit strict-preservation failures, not silently ignored. Transform tolerances concern floating-point composition only, never contact or clearance."}
	if not _rigid_path.is_absolute_path() or _rigid_path.get_extension().to_lower() != "json" or FileAccess.file_exists(_rigid_path):
		_rigid_path = ""
		_rigid_finish(report, "require_new_absolute_json_report_path")
		return
	if not baseline.is_absolute_path() or FileAccess.get_sha256(baseline) != MARKET_FROZEN_SHA or not input_path.is_absolute_path() or not FileAccess.file_exists(input_path):
		_rigid_finish(report, "missing_inputs_or_frozen_sha_mismatch")
		return
	var input_sha := FileAccess.get_sha256(input_path)
	var input = JSON.parse_string(FileAccess.get_file_as_string(input_path))
	if not input is Dictionary or String(input.get("baselineSha256", "")) != MARKET_FROZEN_SHA:
		_rigid_finish(report, "candidate_report_baseline_mismatch")
		return
	var groups: Array = input.get("groups", [])
	if groups.size() < 3:
		_rigid_finish(report, "candidate_or_household_missing")
		return
	var ids: Array = groups[2].get("allIds", [])
	if ids.size() != 39:
		_rigid_finish(report, "expected_39_ids")
		return
	var file := FileAccess.open(baseline, FileAccess.READ)
	if file == null:
		_rigid_finish(report, "frozen_open_failed")
		return
	var envelope = file.get_var(false)
	var read_ok := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not read_ok or not envelope is Dictionary or not envelope.get("output") is Dictionary:
		_rigid_finish(report, "invalid_frozen_envelope")
		return
	var frozen: Dictionary = envelope.output
	var record: Dictionary = frozen.get("sourceSnapshot", {})
	if record.is_empty():
		_rigid_finish(report, "missing_source_snapshot")
		return
	var before = Blueprint.new(record.id, record.seed, record.style)
	before.recipe = record.recipe.duplicate(true)
	before.rooms = record.rooms.duplicate(true)
	for part in record.parts:
		var loaded = before.add_part(part)
		before.physical_parts_by_id[String(loaded.id)] = loaded
	var candidate: Dictionary = UrbanRecipe.plan_household_on_paving(before, ids,
		Vector3(0.0, 0.0, -float(groups[2].layoutSpec.depth)))
	if not candidate.get("ready", false):
		report["candidate"] = candidate
		_rigid_finish(report, "shared_recipe_not_ready")
		return
	var rigid: Transform3D = candidate.transform
	var after = _copy_blueprint(before)
	var original: Dictionary = _part_records(before)
	var members: Dictionary = {}
	for value in ids:
		var id := String(value)
		if id.is_empty() or not original.has(id) or members.has(id):
			_rigid_finish(report, "missing_or_duplicate_household_id")
			return
		members[id] = true
	if original.size() != before.parts.size():
		_rigid_finish(report, "duplicate_frozen_source_id")
		return
	var before_digest := _stable_digest(before.snapshot())
	for part in after.parts:
		if not members.has(part.id):
			continue
		var transformed: Transform3D = rigid * before.part_transform(before.find_part(part.id))
		part.position = transformed.origin
		part.rotation = transformed.basis.get_euler()
	var staged_digest := _stable_digest(after.snapshot())
	var source_rows: Array = []
	var unexpected: Array = []
	for part in after.parts:
		var old: Dictionary = original[part.id]
		if not members.has(part.id):
			if _stable_digest(old) != _stable_digest(part.snapshot()):
				unexpected.append(part.id)
			continue
		var expected: Transform3D = rigid * before.part_transform(before.find_part(part.id))
		var actual: Transform3D = after.part_transform(part)
		var old_fields: Dictionary = old.duplicate(true)
		var new_fields: Dictionary = part.snapshot()
		for key in ["position", "rotation"]:
			old_fields.erase(key)
			new_fields.erase(key)
		source_rows.append({"partId": part.id, "kind": part.kind, "materialId": part.material_id,
			"size": part.size, "recipeDigest": _stable_digest(part.recipe), "expected": expected, "actual": actual,
			"positionExact": actual.origin == expected.origin,
			"basisError": _basis_error(actual.basis, expected.basis),
			"nonTransformFieldsExact": _stable_digest(old_fields) == _stable_digest(new_fields)})
	var relative := _relative_geometry(before, after, ids, rigid)
	var before_publisher = _configured_publisher(before)
	var after_publisher = _configured_publisher(after)
	var payload_rows: Array = []
	for value in ids:
		var id := String(value)
		var old_payload := _complete_payload(before_publisher, before, before.find_part(id))
		var new_payload := _complete_payload(after_publisher, after, after.find_part(id))
		payload_rows.append(_compare_payload(id, old_payload, new_payload, rigid))
	# Separate copies prevent a furnishing service's derived caches from being
	# confused with mutations made by the rigid transform under examination.
	var furniture_seed := int(frozen.fixture.furnitureSeed)
	var old_furniture = FurniturePlanner.build(_copy_blueprint(before), furniture_seed)
	var new_furniture = FurniturePlanner.build(_copy_blueprint(after), furniture_seed)
	var furniture := _furniture_parity(old_furniture, new_furniture)
	furniture["baselineMatchesFrozenFurniture"] = old_furniture != null and _stable_digest(old_furniture.snapshot()) == _stable_digest(frozen.get("furnitureSnapshot", {}))
	report["candidateReportSha256"] = input_sha
	report["candidate"] = candidate
	report["fixture"] = frozen.fixture
	report["rigidTransform"] = rigid
	report["householdIds"] = ids
	report["sourceMembers"] = source_rows
	report["relativeGeometry"] = relative
	report["unexpectedOtherSourceIds"] = unexpected
	report["publisherMembers"] = payload_rows
	report["furniture"] = furniture
	var checks := {
		"frozenSourceRoundtripExact": before_digest == _stable_digest(record),
		"all39SourceTransformsPreserved": source_rows.size() == 39 and source_rows.all(func(row): return row.positionExact and row.basisError <= SOURCE_BASIS_EPS and row.nonTransformFieldsExact),
		"relativeGeometryPreserved": bool(relative.passed), "otherSourcePartsExact": unexpected.is_empty(),
		"sourceOrderExact": before.parts.map(func(part): return part.id) == after.parts.map(func(part): return part.id),
		"blueprintHeaderRecipeRoomsExact": _stable_digest(_header(before)) == _stable_digest(_header(after)),
		"publisherGeometryPreserved": payload_rows.size() == 39 and payload_rows.all(func(row): return row.geometryPreserved),
		"publisherMaterialCountsPreserved": payload_rows.all(func(row): return row.materialCountsPreserved),
		"publisherCustomDataExact": payload_rows.all(func(row): return row.customDataExact),
		"nonBoxCoveragePresent": payload_rows.any(func(row): return int(row.before.nonBoxCount) > 0),
		"furnitureUnaffected": furniture.bothReady and int(furniture.beforePartCount) > 0 and furniture.snapshotsEqual and furniture.reservationsEqual,
		"servicesDidNotMutateSource": before_digest == _stable_digest(before.snapshot()) and staged_digest == _stable_digest(after.snapshot()),
		"inputFilesUnchanged": FileAccess.get_sha256(baseline) == MARKET_FROZEN_SHA and FileAccess.get_sha256(input_path) == input_sha}
	report["checks"] = checks
	report["passed"] = checks.values().all(func(value): return bool(value))
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	_rigid_finish(report, "contract_complete")


func _candidate_is_rule_eligible(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var approach = value.get("frontApproach")
	var circulation = value.get("circulationEnvelopeConflicts")
	var trees = value.get("treeEnvelopeConflicts")
	# Missing evidence is not an empty reservation set or a passed approach.
	return approach is Dictionary and approach.get("passed", false) == true and circulation is Array and circulation.is_empty() and trees is Array and trees.is_empty()


func _copy_blueprint(source):
	var result = super._copy_blueprint(source)
	# find_part reads only this index; add_part does not populate it. Index
	# copied objects directly, including the independent furnishing inputs,
	# without running validation or changing any source recipe/support caches.
	for part in result.parts:
		result.physical_parts_by_id[String(part.id)] = part
	return result


func _configured_publisher(blueprint):
	var publisher = Publisher.new()
	publisher.source_blueprint_id = publisher.canonical_source_blueprint_id(blueprint)
	publisher.surface_history.configure(blueprint.recipe, blueprint.parts)
	publisher.paving_treatments = blueprint.recipe.get("pavingTreatments", [])
	return publisher


func _complete_payload(publisher, blueprint, part) -> Dictionary:
	var parent := Node3D.new()
	publisher.static_visual_collecting = true
	publisher.static_visual_part_transform = blueprint.part_transform(part)
	publisher.static_visual_batches.clear()
	publisher.static_visual_transform_count = 0
	publisher.publish_visual(part, parent)
	var result := {"primitives": [], "materialCounts": {}, "boxCount": 0, "nonBoxCount": 0, "errors": []}
	var group_index := 0
	for group in publisher.static_visual_batches.values():
		var material := _material_digest(group.material)
		var custom: Array = group.get("customData", [])
		if custom.size() != group.transforms.size():
			result.errors.append("box_custom_data_count_mismatch")
		for index in range(group.transforms.size()):
			result.primitives.append({"id": "box:%d:%d" % [group_index, index], "type": "box",
				"transform": group.transforms[index], "meshDigest": "unit_box", "materialDigests": [material],
				"customData": custom[index] if index < custom.size() else null})
			_count_material(result.materialCounts, material)
			result.boxCount += 1
		group_index += 1
	_collect_nonboxes(parent, Transform3D.IDENTITY, "", result)
	parent.free()
	return result


func _collect_nonboxes(parent: Node, accumulated: Transform3D, prefix: String, result: Dictionary) -> void:
	for child in parent.get_children():
		var transform := accumulated
		var path := prefix + "/" + String(child.name)
		if child is Node3D:
			transform = accumulated * child.transform
		if child is MultiMeshInstance3D:
			# These 39 parts currently publish non-box MeshInstance3Ds, not mesh
			# batches. Never silently trust dummy-renderer MultiMesh readback.
			result.errors.append("unsupported_nonbox_multimesh:" + path)
		elif child is MeshInstance3D:
			var mesh: Mesh = child.mesh
			if mesh == null or mesh.get_surface_count() == 0:
				result.errors.append("missing_nonbox_mesh:" + path)
				continue
			var surfaces: Array = []
			var materials: Array = []
			for index in range(mesh.get_surface_count()):
				# PrimitiveMesh exposes its generated arrays without depending on
				# dummy-renderer surface readback. Include mesh class in identity.
				var arrays: Array = (mesh as PrimitiveMesh).get_mesh_arrays() if mesh is PrimitiveMesh else mesh.surface_get_arrays(index)
				if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty():
					result.errors.append("nonbox_vertex_payload_unavailable:" + path)
				surfaces.append({"arrays": arrays})
				var material := _material_digest(child.get_active_material(index))
				materials.append(material)
				_count_material(result.materialCounts, material)
			result.primitives.append({"id": "mesh:" + path, "type": "mesh", "meshClass": mesh.get_class(),
				"transform": transform, "meshDigest": _stable_digest(surfaces), "materialDigests": materials,
				"surfaceCount": mesh.get_surface_count(), "meshBounds": mesh.get_aabb(), "castShadow": child.cast_shadow,
				"customData": null})
			result.nonBoxCount += 1
		_collect_nonboxes(child, transform, path, result)


func _compare_payload(id: String, before: Dictionary, after: Dictionary, rigid: Transform3D) -> Dictionary:
	var mismatches: Array = []
	var custom_changes: Array = []
	var material_changes: Array = []
	var maximum_origin_error := 0.0
	var maximum_basis_error := 0.0
	var same_count: bool = before.primitives.size() == after.primitives.size() and not before.primitives.is_empty()
	for index in range(mini(before.primitives.size(), after.primitives.size())):
		var old: Dictionary = before.primitives[index]
		var current: Dictionary = after.primitives[index]
		var expected: Transform3D = rigid * (old.transform as Transform3D)
		var actual: Transform3D = current.transform
		var origin_error := _vector_error(expected.origin, actual.origin)
		var basis_error := _basis_error(expected.basis, actual.basis)
		maximum_origin_error = maxf(maximum_origin_error, origin_error)
		maximum_basis_error = maxf(maximum_basis_error, basis_error)
		if old.id != current.id or old.type != current.type or old.meshDigest != current.meshDigest or old.get("meshClass") != current.get("meshClass") or old.get("castShadow") != current.get("castShadow") or not _valid_box(actual) or origin_error > PAYLOAD_ARITHMETIC_EPS or basis_error > PAYLOAD_ARITHMETIC_EPS:
			mismatches.append({"index": index, "beforeId": old.id, "afterId": current.id,
				"expectedTransform": expected, "actualTransform": actual, "originError": origin_error, "basisError": basis_error})
		if _stable_digest(old.customData) != _stable_digest(current.customData):
			custom_changes.append({"id": old.id, "before": old.customData, "after": current.customData})
		if _stable_digest(old.materialDigests) != _stable_digest(current.materialDigests):
			material_changes.append({"id": old.id, "before": old.materialDigests, "after": current.materialDigests})
	return {"partId": id, "before": before, "after": after,
		"geometryPreserved": same_count and mismatches.is_empty() and before.errors.is_empty() and after.errors.is_empty(),
		"materialCountsPreserved": same_count and material_changes.is_empty() and _stable_digest(before.materialCounts) == _stable_digest(after.materialCounts),
		"materialAssignmentChanges": material_changes,
		"customDataExact": same_count and custom_changes.is_empty(), "customDataChanges": custom_changes,
		"maxOriginError": maximum_origin_error, "maxBasisError": maximum_basis_error, "geometryMismatches": mismatches}


func _relative_geometry(before, after, ids: Array, rigid: Transform3D) -> Dictionary:
	var failures: Array = []
	var tested := 0
	var maximum_residual := 0.0
	for first in range(ids.size()):
		for second in range(first + 1, ids.size()):
			var a = before.find_part(ids[first])
			var b = before.find_part(ids[second])
			var new_a = after.find_part(ids[first])
			var new_b = after.find_part(ids[second])
			var expected: Vector3 = (rigid * b.position) - (rigid * a.position)
			var actual: Vector3 = new_b.position - new_a.position
			# R*(b-a) has a different floating-point evaluation order. Record its
			# residual; source positions above still require exact T*p equality.
			maximum_residual = maxf(maximum_residual, _vector_error(actual, rigid.basis * (b.position - a.position)))
			if actual != expected:
				failures.append([ids[first], ids[second]])
			tested += 1
	var expected_pairs := ids.size() * (ids.size() - 1) / 2
	return {"passed": ids.size() >= 2 and tested == expected_pairs and failures.is_empty(), "pairCount": tested, "expectedPairCount": expected_pairs, "failedPairs": failures,
		"maxDistributiveFloatResidual": maximum_residual, "orientationProof": "Each member basis independently compared with R*originalBasis in sourceMembers."}


func _header(blueprint) -> Dictionary:
	return {"id": blueprint.id, "seed": blueprint.seed, "style": blueprint.style, "recipe": blueprint.recipe, "rooms": blueprint.rooms}


func _input_vector(value: Variant) -> Vector3:
	if not value is Array or value.size() != 3:
		return Vector3.INF
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _vector_error(a: Vector3, b: Vector3) -> float:
	var difference := (a - b).abs()
	return maxf(difference.x, maxf(difference.y, difference.z))


func _basis_error(a: Basis, b: Basis) -> float:
	return maxf(_vector_error(a.x, b.x), maxf(_vector_error(a.y, b.y), _vector_error(a.z, b.z)))


func _count_material(counts: Dictionary, material: String) -> void:
	counts[material] = int(counts.get(material, 0)) + 1


func _material_digest(material: Variant) -> String:
	# Reuse the existing material/shader snapshot helper; remove only runtime
	# resource identities, which differ between independent publisher instances.
	return _stable_digest(_remove_resource_ids(_value_snapshot(material, {})))


func _remove_resource_ids(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			if key == "instanceId" and value.has("class") and value.has("path"):
				continue
			result[key] = _remove_resource_ids(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _remove_resource_ids(item))
	return value


func _stable_digest(value: Variant) -> String:
	return _digest(_canonical_value(value))


func _canonical_value(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key in keys:
			result[key] = _canonical_value(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _canonical_value(item))
	return value


func _report_value(value: Variant) -> Variant:
	if value is Transform3D:
		return {"origin": _report_value(value.origin), "basis": _report_value(value.basis)}
	if value is Basis:
		return [_report_value(value.x), _report_value(value.y), _report_value(value.z)]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is AABB:
		return {"position": _report_value(value.position), "size": _report_value(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _report_value(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _report_value(item))
	return value


func _rigid_finish(report: Dictionary, status: String) -> void:
	report["status"] = status
	var output := FileAccess.open(_rigid_path, FileAccess.WRITE) if not _rigid_path.is_empty() else null
	if output == null:
		push_error("Market rigid report unavailable: " + status)
		quit(2)
		return
	output.store_string(JSON.stringify(_report_value(report), "\t"))
	output.flush()
	var error := output.get_error()
	output.close()
	print("VOXEL_MARKET_RIGID_REPORT ", _rigid_path, " status=", status)
	quit(2 if error != OK else (0 if report.passed else 1))
