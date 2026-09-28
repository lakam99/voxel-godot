extends "res://scripts/testing/buildings/CitadelOpeningHeadPublishedContract.gd"

const MasonryCuts = preload("res://scripts/buildings/MasonryApertureGeometry.gd")

## Actual recipe-derived brick preparation, not integrated publication acceptance.
func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path := OS.get_environment("VOXEL_MASONRY_CUT_REPORT")
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
		var original: PackedByteArray = var_to_bytes(b.snapshot())
		var publisher: Variant = _configured_publisher(b)
		var openings: Array = _head_apertures(b, String(archive.headerId).trim_suffix("_opening_head_band_000"))
		var volumes: Array[AABB] = []
		for opening: Dictionary in openings: volumes.append(opening.fullVolume)
		checks["bound_full_apertures"] = not volumes.is_empty()
		for id: String in archive.trimmedPanelIds:
			var part: Variant = b.find_part(id)
			var geometry: Dictionary = publisher.describe_masonry(part)
			var solids: Array = publisher.masonry_brick_solids(part, geometry)
			var frozen: PackedByteArray = var_to_bytes(solids)
			var started := Time.get_ticks_usec()
			var prepared: Dictionary = MasonryCuts.prepare(solids, volumes, publisher.unit_box)
			checks[id + ":prepared"] = prepared.get("ready") == true
			checks[id + ":immutable"] = frozen == var_to_bytes(solids)
			if prepared.get("ready") == true:
				checks[id + ":original_descriptors_exact"] = prepared.entries.size() == solids.size() and var_to_bytes(prepared.entries.map(func(entry): return entry.original)) == frozen
			var entry_rows: Array = []
			for entry: Dictionary in prepared.get("entries", []):
				if not entry.get("unchanged", true):
					var mesh_preparation: Dictionary = prepared.preparedMeshes[entry.original.id]
					var mesh: Variant = mesh_preparation.mesh
					var actual_world: Array = []
					var local_vertices: Array = []
					if mesh != null:
						for vertex: Vector3 in mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
							local_vertices.append(vertex)
							actual_world.append(entry.original.transform * vertex)
					entry_rows.append(_overlap_json({"id": entry.original.id, "constructionRemovedVolume": entry.get("removedVolume"), "cellCount": entry.get("cells", []).size(),
						"original": entry.original, "constructionFrameOrigin": entry.get("constructionFrameOrigin"),
						"localVertices": local_vertices, "emittedWorldVertices": actual_world, "faceProvenance": mesh_preparation.faceProvenance}))
			rows.append({"partId": id, "brickCount": solids.size(), "ready": prepared.get("ready", false),
				"reason": prepared.get("reason", ""), "elapsedUsec": Time.get_ticks_usec() - started,
				"changedEntries": entry_rows, "diagnostic": _overlap_json(prepared.get("diagnostic", {}))})
			if prepared.get("ready") != true: break
			await process_frame
		checks["complete_scope"] = rows.size() == archive.trimmedPanelIds.size()
		checks["source_immutable"] = original == var_to_bytes(b.snapshot()) and FileAccess.get_sha256(input) == sha
	var passed: bool = checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": checks, "rows": rows, "inputPath": input, "inputSha256": sha,
		"evidenceLevel": "actual_recipe_brick_cut_preparation_contract",
		"doesNotProve": "Not wired to production publication; no GPU drawing, visual appearance, joints, neighbours or integration acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)
