extends SceneTree

## SYNTHETIC source/publication contract only, not rendered/gameplay acceptance.
## Run with VOXEL_TIMBER_BEARING_REPORT pointing to a writable JSON file.
## No MultiMesh instance transform/custom-data readback: dummy renderer data is
## not evidence. The spy records arguments then calls the real implementation.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const ARITHMETIC_EPSILON := 0.00001


class RecordingPublisher:
	extends "res://scripts/buildings/BuildingPartPublisher.gd"
	var batches: Array = []
	var boxes: Array = []
	var returned_batch_nodes: Array = []

	func add_box_batch(parent: Node3D, transforms: Array, material: Material, node_name: String, custom_data_override: Array = []) -> MultiMeshInstance3D:
		batches.append({"transforms": transforms.duplicate(true), "material": material,
			"customData": custom_data_override.duplicate(true), "nodeName": node_name})
		var node := super.add_box_batch(parent, transforms, material, node_name, custom_data_override)
		returned_batch_nodes.append(node)
		return node

	func add_box_visual(parent: Node3D, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
		# The unchanged short-beam path is not a batch. Observe its actual input
		# too, and still execute the production single-mesh publication.
		boxes.append({"size": size, "position": position, "material": material, "nodeName": node_name})
		super.add_box_visual(parent, size, position, material, node_name)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_TIMBER_BEARING_REPORT").strip_edges()
	if path.is_empty():
		push_error("Set VOXEL_TIMBER_BEARING_REPORT")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var shapes := {
		"long_x": Vector3(3.2, 0.24, 0.38),
		"long_y": Vector3(0.28, 3.6, 0.24),
		"long_z": Vector3(0.24, 0.60, 5.8),
		"short": Vector3(0.28, 0.80, 0.24),
		"threshold_short": Vector3(0.28, 1.05, 0.24),
		"threshold_long": Vector3(0.28, 1.0501, 0.24)
	}
	var cases: Array = []
	var parity: Array = []
	for shape_id in shapes:
		var by_path: Dictionary = {}
		for publication in ["direct", "static"]:
			var records: Dictionary = {}
			for flag in ["absent", "false", "true", "integer_one", "string_true"]:
				var record := _exercise(String(shape_id), shapes[shape_id], publication, flag)
				records[flag] = record
				cases.append(record)
			var absent: Dictionary = records["absent"]["payload"]
			for flag in ["false", "integer_one", "string_true"]:
				parity.append({"id": "%s_%s_absent_equals_%s" % [shape_id, publication, flag],
					"passed": _digest(absent) == _digest(records[flag]["payload"])})
			by_path[publication] = records
		for flag in ["absent", "false", "true", "integer_one", "string_true"]:
			var direct: Dictionary = by_path["direct"][flag]["payload"]
			var collected: Dictionary = by_path["static"][flag]["payload"]
			# Legacy direct short beams are MeshInstance3D, with no instance
			# custom data. Static short boxes intentionally have neutral data.
			var custom_parity := true
			if flag == "true" or _is_long(shapes[shape_id]):
				custom_parity = _digest(direct.customData) == _digest(collected.customData)
			parity.append({"id": "%s_%s_direct_static_parity" % [shape_id, flag],
				"passed": _transforms_approx(direct.worldTransforms, collected.worldTransforms) and _digest(direct.materialValues) == _digest(collected.materialValues) and custom_parity})
	var checks := {
		"all_sixty_publication_cases_pass": cases.size() == 60 and cases.all(func(record): return bool(record.passed)),
		"absent_false_nonboolean_and_path_parity": not parity.is_empty() and parity.all(func(record): return bool(record.passed))
	}
	var passed := checks.values().all(func(value): return bool(value))
	var report := {"evidenceLevel": "synthetic_source_publication_contract", "passed": passed,
		"checks": checks, "cases": cases, "parity": parity, "elapsedMsec": Time.get_ticks_msec() - started,
		"arithmeticEpsilon": ARITHMETIC_EPSILON,
		"epsilonPurpose": "Transform multiplication/inversion rounding only; no spatial contact margin is applied.",
		"legacyOracle": "Frozen pre-opt-in three-segment transform formula; expected material and facade data use the real publisher services. It creates expected arrays only, never publishes replacement geometry.",
		"doesNotProve": "No GPU drawing or MultiMesh transform/custom-data readback, live collision/movement, full frame joinery, roofing contact or gameplay acceptance. The spy records inputs and calls super; static payloads come from actual static_visual_batches. Material comparison covers stored material/shader values and external-resource identity/path, not external texture pixels. No production profile-selection policy outside these synthetic beam records is certified."}
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write timber bearing report: %s" % path)
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("SYNTHETIC timber bearing profile: ", "PASS" if passed else "FAIL", " report=", path)
	quit(0 if passed else 1)


func _exercise(shape_id: String, size: Vector3, publication: String, flag: String) -> Dictionary:
	var recipe := {"variation": 0.05, "physicalIntent": "structural_mass"}
	match flag:
		"false": recipe["preserveBearingFaces"] = false
		"true": recipe["preserveBearingFaces"] = true
		"integer_one": recipe["preserveBearingFaces"] = 1
		"string_true": recipe["preserveBearingFaces"] = "true"
	# Identity is identical across flag/path controls; no frame-specific role or
	# ID is supplied, so the option must work as a generic beam profile.
	var part = Part.new({"id": "timber_contract_" + shape_id, "kind": "beam", "material": "timber_beam",
		"position": Vector3(3.75, 5.5, -7.125), "rotation": Vector3(0.13, -0.27, 0.09),
		"size": size, "collision": true, "recipe": recipe})
	var source_before: Dictionary = part.snapshot()
	var publisher := RecordingPublisher.new()
	publisher.source_blueprint_id = "synthetic_timber_profile"
	# Nontrivial deterministic history exercises facade data rather than only
	# checking a count of neutral/default colors. This is real history input.
	publisher.surface_history.configure({"landscapeTrees": [{"id": "synthetic_history_tree",
		"position": part.position + Vector3(1.3, 0.0, 0.7), "canopyRadius": 4.4}]}, [part])
	publisher.batch_static_parts = publication == "static"
	var expected_material: Material = publisher.material_for(part)
	var authority := Transform3D(Basis.from_euler(part.rotation), part.position)
	var exact_local := Transform3D(Basis.from_scale(size), Vector3.ZERO)
	var legacy: Array = _legacy_long_transforms(String(part.id), size) if _is_long(size) else [exact_local]
	var expected: Array[Transform3D] = []
	if flag == "true":
		expected.append(exact_local)
	else:
		for transform in legacy:
			expected.append(transform)
	var uses_batch := flag == "true" or _is_long(size)
	var expected_custom: Array = publisher.build_facade_custom_data(expected, part) if uses_batch else [Color(0.5, 0.5, 0.5, 1.0)] if publication == "static" else []
	var parent := Node3D.new()
	# Use normal publish_part entry points, including actual collision shapes.
	var direct_body = publisher.publish_part(part, parent)
	var locals: Array = []
	var authored_custom: Array = []
	var material_matches := true
	for batch in publisher.batches:
		locals.append_array(batch.transforms)
		authored_custom.append_array(batch.customData)
		material_matches = material_matches and batch.material == expected_material
	for box in publisher.boxes:
		locals.append(Transform3D(Basis.from_scale(box.size), box.position))
		material_matches = material_matches and box.material == expected_material
	var world: Array = []
	var custom: Array = []
	if publication == "static":
		for group in publisher.static_visual_batches.values():
			world.append_array(group.transforms)
			custom.append_array(group.customData)
			material_matches = material_matches and group.material == expected_material
	else:
		if direct_body != null:
			for transform in locals:
				world.append(direct_body.transform * transform)
		custom = authored_custom.duplicate()
	var expected_world: Array = []
	for transform in expected:
		expected_world.append(authority * transform)
	var collision_body = publisher.static_collision_body if publication == "static" else direct_body
	var collision_checks: Array = []
	if collision_body != null:
		for child in collision_body.get_children():
			if child is CollisionShape3D:
				var shape = child.shape
				var collision_transform: Transform3D = collision_body.transform * child.transform
				collision_checks.append(shape is BoxShape3D and shape.size == size and _transform_approx(collision_transform, authority))
	var bounds: Dictionary = _bearing_bounds(world, authority, size) if flag == "true" else {"applicable": false}
	var super_path_ok := false
	if publication == "static":
		super_path_ok = direct_body == null and publisher.static_visual_batches.size() == 1
	elif uses_batch:
		super_path_ok = publisher.returned_batch_nodes.size() == 1 and publisher.returned_batch_nodes[0] is MultiMeshInstance3D
	else:
		super_path_ok = direct_body != null and direct_body.get_children().any(func(child): return child is MeshInstance3D)
	var checks := {
		"source_record_unchanged": _digest(source_before) == _digest(part.snapshot()),
		"actual_super_publication_executed": super_path_ok,
		"expected_batch_vs_short_box_path": publisher.batches.size() == (1 if uses_batch else 0) and publisher.boxes.size() == (0 if uses_batch else 1),
		"exact_local_payload_matches_oracle": _array_exact(locals, expected),
		"world_payload_matches_authority_transform": world.size() == expected.size() and _transforms_approx(world, expected_world),
		"material_uses_actual_material_for": material_matches and expected_material != null,
		"custom_data_matches_real_facade_or_short_default": _array_exact(custom, expected_custom),
		"batch_custom_data_count": not uses_batch or authored_custom.size() == expected.size(),
		"collision_shape_and_transform_unchanged": collision_checks.size() == 1 and bool(collision_checks[0]),
		"bearing_faces_match_nominal_geometry": flag != "true" or bool(bounds.get("passed", false))
	}
	var passed := checks.values().all(func(value): return bool(value))
	var result := {"id": "%s_%s_%s" % [shape_id, publication, flag], "passed": passed, "checks": checks,
		"flagCase": flag, "publication": publication, "authoritativeSize": size,
		"expectedPrimitiveCount": expected.size(), "actualPrimitiveCount": world.size(), "bearingBounds": bounds,
		"payload": {"localTransforms": locals, "worldTransforms": world, "customData": custom, "materialValues": _material_values(expected_material)},
		"expectedLocalTransforms": expected, "expectedCustomData": expected_custom}
	parent.free()
	print("SYNTHETIC timber ", result.id, ": ", "PASS" if passed else "FAIL")
	return result


func _legacy_long_transforms(part_id: String, size: Vector3) -> Array[Transform3D]:
	# Frozen mathematical oracle from the pre-profile publisher. This is not a
	# publisher override, and none of these expected records are rendered.
	var axis := 0
	var length := size.x
	if size.y > length:
		axis = 1
		length = size.y
	if size.z > length:
		axis = 2
		length = size.z
	var transforms: Array[Transform3D] = []
	var segment_length := length / 3.0
	var part_phase := float(posmod(part_id.hash(), 997)) / 997.0
	for index in range(3):
		var phase := fposmod(part_phase + float(index) * 0.371, 1.0)
		var segment_size := size
		segment_size[axis] = segment_length + 0.045
		var position := Vector3.ZERO
		position[axis] = -length * 0.5 + segment_length * (float(index) + 0.5)
		var bend := (phase - 0.5) * deg_to_rad(1.15)
		var offset := sin(float(index) * 1.9 + part_phase * TAU) * minf(0.018, length * 0.004)
		if axis == 1:
			position.x += offset
		else:
			position.y += offset
		var rotation_axis := Vector3.FORWARD if axis in [0, 1] else Vector3.RIGHT
		var basis := Basis(rotation_axis, bend).scaled(segment_size * lerpf(0.985, 1.015, phase))
		transforms.append(Transform3D(basis, position))
	return transforms


func _bearing_bounds(world: Array, authority: Transform3D, size: Vector3) -> Dictionary:
	if world.size() != 1:
		return {"applicable": true, "passed": false, "reason": "requires_one_exact_box"}
	var actual: Transform3D = world[0]
	var inverse := authority.affine_inverse()
	var maximum_corner_error := 0.0
	var top_error := 0.0
	var bottom_error := 0.0
	var corners: Array = []
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var unit := Vector3(x, y, z)
				var nominal_local := size * unit
				var actual_world := actual * unit
				var expected_world := authority * nominal_local
				var actual_local := inverse * actual_world
				maximum_corner_error = maxf(maximum_corner_error, actual_world.distance_to(expected_world))
				if y < 0.0:
					bottom_error = maxf(bottom_error, absf(actual_local.y + size.y * 0.5))
				else:
					top_error = maxf(top_error, absf(actual_local.y - size.y * 0.5))
				corners.append({"actualWorld": actual_world, "authoritativeWorld": expected_world})
	return {"applicable": true, "passed": maximum_corner_error <= ARITHMETIC_EPSILON and top_error <= ARITHMETIC_EPSILON and bottom_error <= ARITHMETIC_EPSILON,
		"maximumWorldCornerError": maximum_corner_error, "localTopFaceError": top_error, "localBottomFaceError": bottom_error,
		"corners": corners, "spatialContactMargin": 0.0}


func _is_long(size: Vector3) -> bool:
	return maxf(size.x, maxf(size.y, size.z)) > 1.05


func _transforms_approx(first: Array, second: Array) -> bool:
	if first.size() != second.size() or first.is_empty():
		return false
	for index in range(first.size()):
		if not _transform_approx(first[index], second[index]):
			return false
	return true


func _array_exact(first: Array, second: Array) -> bool:
	# Compare elements, not Array typing metadata in Variant serialization.
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		if first[index] != second[index]:
			return false
	return true


func _transform_approx(first: Transform3D, second: Transform3D) -> bool:
	for delta in [first.origin - second.origin, first.basis.x - second.basis.x, first.basis.y - second.basis.y, first.basis.z - second.basis.z]:
		if not delta.is_finite() or delta.length() > ARITHMETIC_EPSILON:
			return false
	return true


func _material_values(material: Material) -> Dictionary:
	if material == null:
		return {"missing": true}
	var result := {"class": material.get_class(), "properties": {}}
	for property in material.get_property_list():
		var name := String(property.name)
		if (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0 and not name.begins_with("shader_parameter/"):
			continue
		var value = material.get(name)
		if value is Shader:
			value = {"class": value.get_class(), "path": value.resource_path, "code": value.code}
		elif value is Resource:
			value = {"class": value.get_class(), "path": value.resource_path}
		result.properties[name] = value
	return result


func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()
