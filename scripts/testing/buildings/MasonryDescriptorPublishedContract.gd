extends "res://scripts/testing/buildings/CitadelOpeningHeadPublishedContract.gd"

## Descriptor/native publication parity only. No aperture or joint acceptance.
func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path := OS.get_environment("VOXEL_MASONRY_DESCRIPTOR_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var input := OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT")
	var sha := OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT_SHA256")
	var archive := _head_read(input, sha)
	var checks: Dictionary = {"bound_input": not archive.is_empty()}
	var rows: Array = []
	if not archive.is_empty():
		var b: Variant = HeadCopy.copy_blueprint(archive.afterSnapshot)
		var publisher: Variant = _configured_publisher(b)
		var original: PackedByteArray = var_to_bytes(b.snapshot())
		var ids: Array = archive.trimmedPanelIds.duplicate()
		ids.append_array(b.find_part(archive.headerId).recipe.physicalRequiredSeatPartIds)
		ids.sort()
		for id: String in ids:
			var part: Variant = b.find_part(id)
			var geometry: Dictionary = publisher.describe_masonry(part)
			var solids: Array = publisher.masonry_brick_solids(part, geometry)
			var repeated: Array = publisher.masonry_brick_solids(part, publisher.describe_masonry(part))
			var payload: Dictionary = _extract_overlap_payload(publisher, b, part, "descriptor_parity")
			var boxes: Array = payload.get("primitives", [])
			var exact: bool = boxes.size() == solids.size() + 1
			var material_keys: Dictionary = {}
			for index in range(solids.size()):
				var source: Dictionary = solids[index]
				material_keys[source.materialKey] = true
				if index + 1 >= boxes.size():
					exact = false
					break
				var actual: Dictionary = boxes[index + 1]
				exact = exact and actual.type == "box" and actual.transform == source.transform and actual.customData == source.customData
			checks[id + ":actual_transform_custom_data_exact"] = exact
			checks[id + ":repeat_exact"] = var_to_bytes(solids) == var_to_bytes(repeated)
			checks[id + ":material_keys_resolved"] = material_keys.keys().all(func(key): return publisher.material_cache.has(key))
			rows.append({"partId": id, "brickCount": solids.size(), "materialKeys": material_keys.keys(), "exact": exact})
			await process_frame
		checks["source_unchanged"] = original == var_to_bytes(b.snapshot()) and FileAccess.get_sha256(input) == sha
		checks["complete_scope"] = rows.size() == ids.size() and _stop_reason.is_empty()
	var passed: bool = checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": checks, "rows": rows, "inputPath": input, "inputSha256": sha,
		"evidenceLevel": "actual_CPU_native_box_descriptor_contract",
		"doesNotProve": "No aperture repair, joint, GPU drawing, visual appearance or integration acceptance; material payload parity is separately recorded."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)
