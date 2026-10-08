extends "res://scripts/testing/buildings/CitadelOpeningHeadPublishedContract.gd"

## Diagnostic only: actual masonry publication in full blueprint order through
## the selected house's two gables. Other part families cannot create repair keys.
func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path := OS.get_environment("VOXEL_MASONRY_ORDER_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var input := OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT")
	var sha := OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT_SHA256")
	var archive := _head_read(input, sha)
	var report := {"completed": false, "passed": false, "inputPath": input, "inputSha256": sha,
		"evidenceLevel": "actual_masonry_publication_material_order_diagnostic",
		"limitations": "Filters only production masonry-wall/foundation callers of masonry_repair_material_for in full blueprint order. No full-scene, physics, GPU, structural or visual acceptance."}
	var runs: Array = []
	if not archive.is_empty():
		var target_house := String(archive.headerId).trim_suffix("_opening_head_band_000")
		for key: String in ["beforeSnapshot", "afterSnapshot"]:
			var b: Variant = HeadCopy.copy_blueprint(archive[key])
			var frozen := var_to_bytes(b.snapshot())
			var publisher: Variant = _configured_publisher(b)
			if not publisher.prepare_masonry_apertures(b): break
			while publisher._masonry_preparation.state == "pending_budget" and _within_budget():
				publisher._masonry_preparation.advance(publisher)
				await process_frame
			if publisher._masonry_preparation.state != "ready": break
			var origins: Dictionary = {}
			var targets: Array = []
			var count := 0
			for part in b.parts:
				if not _within_budget(): break
				if part.kind not in ["wall", "foundation"] or not publisher.ConstructionMaterialCatalogScript.is_masonry_material(part.material_id) or part.recipe.get("visual", true) != true: continue
				var previous: Array = publisher.material_cache.keys()
				var parent := Node3D.new()
				publisher.static_visual_collecting = true
				publisher.static_visual_part_transform = b.part_transform(part)
				publisher.static_visual_batches.clear()
				publisher.static_visual_transform_count = 0
				publisher.publish_brick_wall(part, parent)
				if publisher._publication_failed():
					_stop_reason = publisher._masonry_preparation.reason
					parent.free()
					break
				for material_key: String in publisher.material_cache:
					if not material_key.begins_with("masonry_repair:") or previous.has(material_key): continue
					var material: ShaderMaterial = publisher.material_cache[material_key]
					origins[material_key] = {"firstRequestPartId": part.id, "repairPhase": material.get_shader_parameter("repair_phase"), "digest": _material_digest(material)}
				if part.id in [target_house + "_upper_shell_side_-1", target_house + "_upper_shell_side_1"]:
					var geometry: Dictionary = publisher.describe_masonry(part)
					var material_key := "masonry_repair:%s:%0.3f" % [geometry.surfaceMaterialId, publisher.masonry_family_variation(part)]
					targets.append({"partId": part.id, "key": material_key, "repairCount": geometry.repairTransforms.size(), "origin": origins.get(material_key, {})})
				parent.free()
				publisher.clear_published_node_roster()
				count += 1
				if targets.size() == 2: break
				if count % 16 == 0: await process_frame
			runs.append({"snapshot": key, "publishedMasonryParts": count, "targetMaterials": targets, "sourceImmutable": frozen == var_to_bytes(b.snapshot()), "reason": _stop_reason})
			if not _stop_reason.is_empty(): break
	report["runs"] = runs
	report.completed = runs.size() == 2 and runs.all(func(run): return run.targetMaterials.size() == 2 and run.sourceImmutable and run.reason.is_empty())
	if report.completed: report.passed = var_to_bytes(runs[0].targetMaterials) == var_to_bytes(runs[1].targetMaterials)
	report["elapsedMsec"] = Time.get_ticks_msec() - _started_msec
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if report.passed and written else 2)
