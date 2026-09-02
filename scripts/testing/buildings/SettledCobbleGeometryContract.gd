extends "res://scripts/testing/buildings/CitadelChimneyPublishedContract.gd"

## CPU construction/publication parity only. Capture the existing publisher
## before extraction; replay identical source/order against that immutable file.
## No aperture, navigation, movement or visual acceptance is claimed here.
const Geometry = preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const SOURCE_SHA := "f7f748e9a0bcd88b9152882d90705190ff884bac473a126762a64d812c6413b0"
const OLD_PUBLISHER_SHA := "84c5814c91e6ac6e314672933ee54f75cb6942f9a89f6a40600e8b2b2a28f14b"

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var output := OS.get_environment("VOXEL_COBBLE_GEOMETRY_REPORT")
	var source_path := OS.get_environment("VOXEL_COBBLE_GEOMETRY_SOURCE")
	var reference_path := OS.get_environment("VOXEL_COBBLE_GEOMETRY_REFERENCE")
	var reference_sha := OS.get_environment("VOXEL_COBBLE_GEOMETRY_REFERENCE_SHA256")
	var publisher_sha := FileAccess.get_sha256("res://scripts/buildings/BuildingPartPublisher.gd")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()) or FileAccess.get_sha256(source_path) != SOURCE_SHA:
		quit(2)
		return
	var reference: Dictionary = {}
	if reference_path.is_empty():
		if publisher_sha != OLD_PUBLISHER_SHA:
			push_error("Pre-extraction capture requires original publisher")
			quit(2)
			return
	else:
		if not reference_path.is_absolute_path() or reference_sha.length() != 64 or FileAccess.get_sha256(reference_path) != reference_sha:
			quit(2)
			return
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(reference_path))
		if not parsed is Dictionary or not parsed.get("passed", false) or parsed.get("mode") != "pre_extraction_capture" or parsed.get("publisherSha256") != OLD_PUBLISHER_SHA or parsed.get("sourceSha256") != SOURCE_SHA:
			quit(2)
			return
		for row in parsed.cases: reference[row.partId] = row
	var file := FileAccess.open(source_path, FileAccess.READ)
	if file == null or file.get_length() > 33554432:
		quit(2)
		return
	var size := file.get_length()
	var bytes := file.get_buffer(size)
	var complete: bool = bytes.size() == size and file.get_error() == OK
	file.close()
	var archive: Variant = bytes_to_var(bytes)
	if not complete or not archive is Dictionary or archive.get("provenance") != "successful_full_facade_recipe_contract" or not archive.get("mainShardPassed", false):
		quit(2)
		return
	var b = Shops.copy_source(archive.beforeSnapshot)
	var source_digest := _stable_digest(b.snapshot())
	var publisher = _configured_publisher(b)
	var history_before := _history_identity(publisher.surface_history)
	var parts: Array = []
	for part in b.parts:
		if part.kind == "foundation" and publisher.ConstructionMaterialCatalogScript.is_cobble_material(part.material_id) and part.recipe.get("visual", true): parts.append(part)
	var actual_count := parts.size()
	# Explicit synthetic geometry variations; never presented as generated-world
	# coverage. Their publication order is fixed in the immutable oracle.
	var synthetic = b.get_script().new("synthetic_paving_dimensions", 41, b.style)
	for record in [
		{"id": "synthetic_negative_origin", "size": Vector3(3.7, 0.08, 4.1), "position": Vector3(-13.2, 0.8, -22.7), "rotation": Vector3.ZERO, "family": "civic_setts", "heading": "x"},
		{"id": "synthetic_rotated_tilted", "size": Vector3(6.5, 0.14, 2.8), "position": Vector3(4.2, 0.9, -3.3), "rotation": Vector3(0.08, 0.63, -0.04), "family": "lane_cobble", "heading": "z"},
		{"id": "synthetic_spacing_expansion", "size": Vector3(120, 0.08, 140), "position": Vector3(200, 0.8, -180), "rotation": Vector3.ZERO, "family": "civic_setts", "heading": "x"}]:
		parts.append(synthetic.add_part({"id": record.id, "kind": "foundation", "material": "cobblestone", "position": record.position, "size": record.size, "rotation": record.rotation, "collision": false, "recipe": {"pavingFamily": record.family, "pavingHeading": record.heading}}))
	var cases: Array = []
	var total_stones := 0
	var total_worn := 0
	var expected_order: Array = []
	var pack_exact := true
	for strength in [-1.0, 0.0, 0.033, 0.25, 0.5, 0.999, 1.0, 2.0]:
		for lateral in [-1.0, 0.0, 0.5, 1.0, 2.0]:
			pack_exact = pack_exact and Geometry.pack_route_history(strength, lateral) == publisher.pack_route_history(strength, lateral)
	for part in parts:
		expected_order.append(part.id)
		if not _within_budget(): break
		var source_before := _stable_digest(part.snapshot())
		var started := Time.get_ticks_usec()
		var described: Dictionary = Geometry.describe(part, publisher.surface_history, publisher.paving_family_for(part), publisher.paving_runs_along_x(part), publisher.paving_region_phase(part))
		var build_usec := Time.get_ticks_usec() - started
		var actual: Dictionary = _extract_overlap_payload(publisher, b, part, "paving_extraction")
		var materials_before: Dictionary = publisher.material_cache.duplicate()
		var comparison := _compare_descriptor(publisher, b, part, described, actual)
		comparison["material_audit_did_not_change_cache"] = materials_before == publisher.material_cache
		var row := {"partId": part.id, "synthetic": String(part.id).begins_with("synthetic_"), "checks": comparison,
			"descriptorDigest": _stable_digest(described), "visualPayloadDigest": _stable_digest(actual),
			"sourceUnchanged": source_before == _stable_digest(part.snapshot()), "buildUsec": build_usec,
			"regularCount": described.regularTransforms.size(), "wornCount": described.wornTransforms.size()}
		if not reference_path.is_empty():
			row.checks["immutable_pre_extraction_visual_exact"] = reference.has(part.id) and reference[part.id].visualPayloadDigest == row.visualPayloadDigest
			row.checks["immutable_pre_extraction_descriptor_exact"] = reference.has(part.id) and reference[part.id].descriptorDigest == row.descriptorDigest
		row["passed"] = row.sourceUnchanged and row.checks.values().all(func(value): return value == true)
		total_stones += described.regularTransforms.size() + described.wornTransforms.size()
		total_worn += described.wornTransforms.size()
		cases.append(row)
	var source_exact: bool = source_digest == _stable_digest(b.snapshot()) and FileAccess.get_sha256(source_path) == SOURCE_SHA
	var history_exact: bool = history_before == _history_identity(publisher.surface_history)
	var reference_exact: bool = reference_path.is_empty() or (reference.size() == cases.size() and FileAccess.get_sha256(reference_path) == reference_sha)
	var passed: bool = actual_count > 0 and cases.size() == parts.size() and cases.all(func(row): return row.passed) and pack_exact and source_exact and history_exact and reference_exact and _stop_reason.is_empty()
	var report := {"passed": passed, "evidenceLevel": "CPU_construction_and_publication_parity_plus_labelled_synthetic_geometry",
		"mode": "pre_extraction_capture" if reference_path.is_empty() else "immutable_reference_replay",
		"sourceSha256": SOURCE_SHA, "publisherSha256": publisher_sha, "geometrySha256": FileAccess.get_sha256("res://scripts/buildings/SettledCobbleGeometry.gd"),
		"referencePath": reference_path, "referenceSha256": reference_sha, "referenceUnchanged": reference_exact,
		"sourceUnchanged": source_exact, "historyUnchanged": history_exact, "historyIdentity": history_before,
		"actualPavingCount": actual_count, "syntheticCount": parts.size() - actual_count, "stoneCount": total_stones, "wornCount": total_worn,
		"packRouteHistoryExact": pack_exact, "caseOrder": expected_order, "cases": cases, "stopReason": _stop_reason,
		"elapsedMsec": Time.get_ticks_msec() - _started_msec,
		"doesNotProve": "No apertures, clipped solids, integrated physical gate, live movement, navigation, screenshots or full-world performance acceptance."}
	file = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_overlap_json(report), "\t"))
	file.close()
	quit(0 if passed else 1)

func _history_identity(history) -> String:
	return _stable_digest([history.route_corridors, history.tree_placements, history.history_events, history.history_event_cells])

func _compare_descriptor(publisher, b, part, described: Dictionary, actual: Dictionary) -> Dictionary:
	var expected: Array = []
	var transform: Transform3D = b.part_transform(part)
	var bed: Dictionary = described.bed
	expected.append({"transform": transform * Transform3D(Basis.IDENTITY.scaled(bed.size), bed.position),
		"material": _material_digest(publisher.material_for_id(bed.materialId, publisher.variation_for(part) - 0.025)), "checkCustom": false})
	var ids: Dictionary = {}
	var ids_unique := true
	for group in ["regular", "worn"]:
		var transforms: Array = described[group + "Transforms"]
		var custom: Array = described[group + "CustomData"]
		var identities: Array = described[group + "Ids"]
		if transforms.size() != custom.size() or transforms.size() != identities.size(): return {"parallel_arrays": false}
		# The original publisher does not request a worn material for an empty
		# worn batch. Never prime its quantized material cache from the audit.
		if transforms.is_empty(): continue
		var material = publisher.material_for(part) if group == "regular" else publisher.material_for_id("worn_cobble", publisher.variation_for(part) - 0.016)
		for index in range(transforms.size()):
			ids_unique = ids_unique and not ids.has(identities[index])
			ids[identities[index]] = true
			expected.append({"transform": transform * transforms[index], "material": _material_digest(material), "custom": custom[index], "checkCustom": true})
	var checks := {"complete_payload": _valid_payload(actual), "exact_cardinality": expected.size() == actual.primitives.size(),
		"unique_row_column_identity": ids_unique, "ordered_transforms_exact": true, "materials_exact": true, "custom_data_exact": true}
	for index in range(mini(expected.size(), actual.primitives.size())):
		var got: Dictionary = actual.primitives[index]
		var want: Dictionary = expected[index]
		checks.ordered_transforms_exact = checks.ordered_transforms_exact and got.transform == want.transform
		checks.materials_exact = checks.materials_exact and got.materialDigests == [want.material]
		if want.checkCustom: checks.custom_data_exact = checks.custom_data_exact and got.customData == want.custom
	return checks
