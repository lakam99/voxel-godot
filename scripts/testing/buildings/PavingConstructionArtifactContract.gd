extends "res://scripts/testing/buildings/ConvexFootingApertureContract.gd"

## Actual immutable source, proposed apertures, source/CPU construction contract.
## No frame assembly, global physical validation, accepted placement or collision
## changes. Inherit independent geometry witnesses, NOT the synthetic _run.
## Inputs: VOXEL_PAVING_ARTIFACT_SOURCE + _SOURCE_SHA256 (whole08 raw archive),
## VOXEL_PAVING_ARTIFACT_DIAGNOSIS + _DIAGNOSIS_SHA256 (blocked-bay02 JSON).
## Output: fresh absolute VOXEL_PAVING_ARTIFACT_REPORT JSON.
const Artifact = preload("res://scripts/buildings/PavingConstructionArtifact.gd")
const PavingGeometry = preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const FacadeSource = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Bearing = preload("res://scripts/buildings/FacadeBearingFrameBuilder.gd")
const CpuContract = preload("res://scripts/testing/buildings/CitadelMarketPublishedOverlapContract.gd")
const WHOLE08_SHA := "f7f748e9a0bcd88b9152882d90705190ff884bac473a126762a64d812c6413b0"
const DIAG02_SHA := "9e831f21be9499cc07d0c91e9f665272255316ef270b8a8952778bc21a94f6bc"
const COMPILE_LIMITS := {"maxFragments": 8192, "maxFragmentsPerSolid": 32,
	"maxFacesPerCell": 32, "maxVerticesPerFace": 32, "maxWork": 1000000}
const REPORT_FAILURE_ROWS := 16


func _run() -> void:
	var path := OS.get_environment("VOXEL_PAVING_ARTIFACT_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var report: Dictionary = _inspect_artifact()
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report["evidenceLevel"] = "actual_frozen_paving_source_and_CPU_descriptor_with_proposed_apertures"
	report["placementAccepted"] = false
	report["limitations"] = "Foot coordinates are a bounded diagnosis-derived proposal using EMPTY-obstacle offsets, NOT accepted frame placement. No other-frame/furniture clearance, footing support-chain, full physical gate, clipped mesh publication, shader/UV/GPU parity, collision/navigation or gameplay acceptance. Original collision/source records are unchanged. Faces describe closed convex solid unions, including internal partition caps."
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if written and report.get("passed", false) else 2)


func _inspect_artifact() -> Dictionary:
	var source_file: Dictionary = _bound_read("VOXEL_PAVING_ARTIFACT_SOURCE", WHOLE08_SHA, 33554432)
	if not source_file.completed: return source_file
	var diag_file: Dictionary = _bound_read("VOXEL_PAVING_ARTIFACT_DIAGNOSIS", DIAG02_SHA, 2097152)
	if not diag_file.completed: return diag_file
	var archive_value: Variant = bytes_to_var(source_file.bytes) # No object deserialization.
	var diag_value: Variant = JSON.parse_string(diag_file.bytes.get_string_from_utf8())
	if not archive_value is Dictionary or not diag_value is Dictionary: return {"reason": "invalid_input_encoding"}
	var archive: Dictionary = archive_value
	var diag: Dictionary = diag_value
	if archive.get("schemaVersion") != 1 or archive.get("provenance") != "successful_full_facade_recipe_contract" or not archive.get("mainShardPassed", false): return {"reason": "invalid_source_provenance"}
	if not archive.get("beforeSnapshot") is Dictionary or not archive.get("furnitureSnapshot") is Dictionary or not archive.get("protectedReservations") is Array: return {"reason": "invalid_source_schema"}
	if not archive.beforeSnapshot.get("parts") is Array or not archive.beforeSnapshot.get("rooms") is Array or not archive.furnitureSnapshot.get("parts") is Array: return {"reason": "invalid_source_collections"}
	if archive.beforeSnapshot.parts.size() > 10000 or archive.beforeSnapshot.rooms.size() > 2048 or archive.furnitureSnapshot.parts.size() > 2048 or archive.protectedReservations.size() > 2048: return {"reason": "source_collection_limit"}
	if _archive_digest(archive.beforeSnapshot) != archive.get("sourceDigest") or _archive_digest({"furnitureParts": archive.furnitureSnapshot.parts, "reservedVolumes": archive.protectedReservations}) != archive.get("policyDigest"): return {"reason": "archive_content_digest_mismatch"}
	if not diag.get("diagnosticCompleted", false) or not diag.get("sourceUnchanged", false) or diag.get("artifactSha256") != source_file.sha256 or not diag.get("rows") is Array or diag.rows.size() > 512: return {"reason": "diagnosis_pairing_mismatch"}
	var b = FacadeSource.copy_blueprint(archive.beforeSnapshot)
	if _archive_digest(b.snapshot()) != archive.sourceDigest: return {"reason": "source_roundtrip_mismatch"}
	var proposal: Dictionary = _diagnosed_proposal(b, diag)
	if not proposal.get("completed", false): return proposal
	var part = proposal.part
	# Same actual CPU publisher class/configuration as the existing overlap
	# contract's _configured_publisher, without constructing another SceneTree
	# (which would create another root Window and randomize global RNG).
	var publisher = CpuContract.CpuMeshBatchPublisher.new()
	publisher.source_blueprint_id = publisher.canonical_source_blueprint_id(b)
	publisher.surface_history.configure(b.recipe, b.parts)
	publisher.paving_treatments = b.recipe.get("pavingTreatments", [])
	var source_before := var_to_bytes(b.snapshot())
	var furniture_before := var_to_bytes(archive.furnitureSnapshot)
	var reservations_before := var_to_bytes(archive.protectedReservations)
	var history_before := _paving_history_digest(publisher.surface_history)
	var described: Dictionary = PavingGeometry.describe_source(part, publisher.surface_history, publisher.source_blueprint_id)
	var descriptor_before := var_to_bytes(described)
	if not described.get("ready", false): return {"reason": "descriptor_not_ready"}
	var count: int = 1 + described.regularTransforms.size() + described.wornTransforms.size()
	if count > 8192 or count < 2 or described.regularTransforms.is_empty(): return {"reason": "descriptor_collection_limit_or_missing_regular_control"}
	var transform: Transform3D = b.part_transform(part)
	var cpu: Dictionary = _uncut_cpu_parity(publisher, part, described)
	var baseline: Dictionary = Artifact.compile(described, transform, [], COMPILE_LIMITS)
	if not baseline.completed: return {"reason": "uncut_compile_failed", "result": baseline, "uncutCpu": cpu}
	var baseline_check: Dictionary = _artifact_proof(baseline, described, transform, [], null)
	var cuts: Array[AABB] = proposal.apertures
	var candidate: Dictionary = Artifact.compile(described, transform, cuts, COMPILE_LIMITS)
	var cases: Array = [{"label": "uncut_actual_paving", "passed": baseline_check.passed and cpu.passed,
		"proof": baseline_check, "work": baseline.work, "uncutCpu": cpu}]
	if candidate.completed:
		var cut_check: Dictionary = _artifact_proof(candidate, described, transform, cuts, baseline)
		cases.append({"label": "proposed_finite_foot_apertures", "passed": cut_check.passed and candidate.changedSolidCount > 0 and not candidate.entries[0].unchanged,
			"proof": cut_check, "work": candidate.work, "changedSolidCount": candidate.changedSolidCount,
			"remainingVolume": candidate.remainingVolume, "removedVolume": candidate.removedVolume,
			"constructionDigest": candidate.constructionDigest})
		var reverse_cuts: Array[AABB] = cuts.duplicate()
		reverse_cuts.reverse()
		var duplicate_cuts: Array[AABB] = reverse_cuts.duplicate()
		duplicate_cuts.append_array(cuts)
		var reordered: Dictionary = Artifact.compile(described, transform, reverse_cuts, COMPILE_LIMITS)
		var duplicate: Dictionary = Artifact.compile(described, transform, duplicate_cuts, COMPILE_LIMITS)
		var first: Dictionary = Artifact.compile(described, transform, [cuts[0]], COMPILE_LIMITS)
		var replay_cuts: Array[AABB] = []
		if first.completed: replay_cuts.assign(first.canonicalApertures)
		replay_cuts.append_array(cuts)
		var replay: Dictionary = Artifact.compile(described, transform, replay_cuts, COMPILE_LIMITS)
		cases.append({"label": "duplicate_reordered_and_accumulated_replay", "passed": first.completed and _same_construction(candidate, reordered) and _same_construction(candidate, duplicate) and _same_construction(candidate, replay)})
	else:
		cases.append({"label": "proposed_finite_foot_apertures", "passed": false, "result": candidate})
	var extrema: Dictionary = _entry_extrema(baseline.entries[0])
	for entry in baseline.entries:
		var other: Dictionary = _entry_extrema(entry)
		for axis in range(3):
			extrema.minimum[axis] = minf(extrema.minimum[axis], other.minimum[axis])
			extrema.maximum[axis] = maxf(extrema.maximum[axis], other.maximum[axis])
	# Synthetic boundary control DERIVED from the actual complete finish bounds.
	# It touches the outermost world-X face; no authored empty-space coordinate.
	var touch_control: Dictionary = _touching_control(extrema)
	if not touch_control.completed: return touch_control
	var touching: AABB = touch_control.bounds
	var touch_result: Dictionary = Artifact.compile(described, transform, [touching], COMPILE_LIMITS)
	cases.append({"label": "actual_finish_boundary_touch_no_change", "passed": touch_result.completed and var_to_bytes(touch_result.get("entries")) == var_to_bytes(baseline.entries), "reason": touch_result.get("reason", "")})
	var failures: Array = _artifact_failures(described, transform, cuts)
	var preservation := {"sourceExact": var_to_bytes(b.snapshot()) == source_before,
		"descriptorExact": var_to_bytes(described) == descriptor_before,
		"historyExact": _paving_history_digest(publisher.surface_history) == history_before,
		"furnitureExact": var_to_bytes(archive.furnitureSnapshot) == furniture_before,
		"reservationsExact": var_to_bytes(archive.protectedReservations) == reservations_before,
		"sourceFileExact": FileAccess.get_sha256(source_file.path) == source_file.sha256,
		"diagnosisFileExact": FileAccess.get_sha256(diag_file.path) == diag_file.sha256}
	return {"passed": cases.all(func(row): return row.passed) and failures.all(func(row): return row.passed) and preservation.values().all(func(value): return value == true),
		"sourcePath": source_file.path, "sourceSha256": source_file.sha256, "diagnosisPath": diag_file.path, "diagnosisSha256": diag_file.sha256,
		"sourceDigest": archive.sourceDigest, "furnitureDigest": _value_digest(archive.furnitureSnapshot), "reservationDigest": _value_digest(archive.protectedReservations),
		"historyDigest": history_before, "descriptorDigest": baseline.descriptorDigest,
		"pavingPartId": part.id, "sourcePartCount": b.parts.size(), "furnitureCount": archive.furnitureSnapshot.parts.size(),
		"regularCount": described.regularTransforms.size(), "wornCount": described.wornTransforms.size(), "sourceSolidCount": count,
		"proposal": proposal.report, "cases": cases, "negativeCases": failures, "preservation": preservation,
		"scriptIdentity": {"contract": FileAccess.get_sha256(get_script().resource_path), "artifact": FileAccess.get_sha256("res://scripts/buildings/PavingConstructionArtifact.gd"),
			"geometry": FileAccess.get_sha256("res://scripts/buildings/SettledCobbleGeometry.gd"), "cut": FileAccess.get_sha256("res://scripts/buildings/ConvexFootingAperture.gd"),
			"publisher": FileAccess.get_sha256("res://scripts/buildings/BuildingPartPublisher.gd")}}


func _diagnosed_proposal(b, diag: Dictionary) -> Dictionary:
	var selected: Dictionary = {}
	var selected_index := -1
	for index in range(diag.rows.size()):
		var row: Dictionary = diag.rows[index]
		if row.get("stage") == "footing_offsets" and row.get("insetResult", {}).get("ready", false) and row.get("footingWitness", {}).get("status") == "single_obstacle_alone_eliminates_a_foot_range":
			selected = row
			selected_index = index
			break
	if selected.is_empty() or not diag.get("memberIds") is Array or diag.memberIds.is_empty() or diag.memberIds.size() > Bearing.MAX_MEMBERS: return {"reason": "no_bounded_qualifying_diagnosis"}
	var by_id: Dictionary = {}
	for part in b.parts:
		if by_id.has(part.id): return {"reason": "duplicate_source_id"}
		by_id[part.id] = part
	var obstacle_id: String = selected.footingWitness.get("ownerId", "")
	var support_id: String = selected.get("supportId", "")
	if not by_id.has(obstacle_id) or not by_id.has(support_id): return {"reason": "missing_diagnosed_source"}
	var part = by_id[obstacle_id]
	var support = by_id[support_id]
	if part.collision_enabled or part.kind != "foundation" or part.recipe.get("pavingFamily", "").is_empty() or not support.collision_enabled: return {"reason": "not_diagnosed_decorative_paving_over_real_support"}
	var bounds: AABB
	for index in range(diag.memberIds.size()):
		var id: String = diag.memberIds[index]
		if not by_id.has(id): return {"reason": "missing_diagnosed_panel"}
		var panel = by_id[id]
		if panel.semantic != "citadel_urban_facade" or panel.rotation != Vector3.ZERO: return {"reason": "invalid_diagnosed_panel"}
		bounds = Bearing._bounds(panel) if index == 0 else bounds.merge(Bearing._bounds(panel))
	var doors: Array = b.parts.filter(func(value): return value.kind == "door" and value.id.begins_with(String(diag.get("ownerPrefix", "")) + "_") and value.recipe.has("roomId"))
	if doors.size() != 1: return {"reason": "ambiguous_source_owner_door"}
	var rooms: Array = b.rooms.filter(func(room): return room.get("id") == doors[0].recipe.roomId)
	if rooms.size() != 1: return {"reason": "ambiguous_source_owner_room"}
	var outward := Vector3(signf(bounds.get_center().x - rooms[0].bounds.get_center().x), 0, 0)
	if outward == Vector3.ZERO or not selected.get("normalCenter") is float or not is_finite(selected.normalCenter): return {"reason": "invalid_diagnosed_normal"}
	var interval: Dictionary = _reported_vector2(selected.insetResult.get("interval"))
	var recorded_offsets: Dictionary = _reported_vector2(selected.footingWitness.get("emptyObstacleOffsets"))
	if not interval.completed or not recorded_offsets.completed: return {"reason": "invalid_reported_interval"}
	var seat: AABB = Bearing._bounds(support)
	var center := Vector3(selected.normalCenter, bounds.position.y - Bearing.SILL_HEIGHT * 0.5, bounds.get_center().z)
	var empty_bounds: Array[AABB] = []
	var feet: Dictionary = Bearing._plan_footing_offsets_from_bounds(center, 2, bounds.size.z, outward, seat.end.y, empty_bounds, FacadeSource.CLEARANCE, seat, {"remaining": 131072}, interval.value)
	if not feet.ready or feet.offsets.distance_to(recorded_offsets.value) > 0.00002: return {"reason": "proposal_does_not_reproduce_reported_empty_obstacle_offsets", "result": feet}
	var cuts: Array[AABB] = []
	for placement in Bearing.footing_layout(center, 2, bounds.size.z, outward, feet.offsets):
		var foot_center: Vector3 = placement.footCenter
		foot_center.y = seat.end.y + Bearing.FOOT_HEIGHT * 0.5
		var size := Vector3(Bearing.FOOT_WIDTH, Bearing.FOOT_HEIGHT, Bearing.FOOT_WIDTH)
		var cut := AABB(foot_center - size * 0.5, size)
		if cut.position.x < seat.position.x or cut.end.x > seat.end.x or cut.position.z < seat.position.z or cut.end.z > seat.end.z: return {"reason": "proposal_foot_outside_reported_support_footprint"}
		cuts.append(cut)
	return {"completed": true, "part": part, "apertures": cuts,
		"report": {"diagnosisRow": selected_index, "pavingPartId": part.id, "supportId": support.id, "memberIds": diag.memberIds,
			"normalCenter": center.x, "insetInterval": str(interval.value), "postOffsets": str(feet.offsets),
			"footWidth": Bearing.FOOT_WIDTH, "footHeight": Bearing.FOOT_HEIGHT, "supportTop": seat.end.y,
			"apertures": cuts.map(func(cut): return {"position": [cut.position.x, cut.position.y, cut.position.z], "size": [cut.size.x, cut.size.y, cut.size.z]}),
			"status": "proposal_only_empty_obstacle_projection_not_placement_or_bearing_acceptance"}}


func _uncut_cpu_parity(publisher, part, described: Dictionary) -> Dictionary:
	var parent := Node3D.new()
	publisher.publish_settled_cobble(part, parent)
	var checks := {"bed_exact": false, "regular_exact": false, "worn_exact": described.wornTransforms.is_empty(), "only_expected_batches": true}
	var bed_count := 0
	for child in parent.get_children():
		if child is MeshInstance3D and not child is MultiMeshInstance3D:
			bed_count += 1
			checks.bed_exact = child.mesh is BoxMesh and child.mesh.size == Vector3.ONE and child.transform == Transform3D(Basis.IDENTITY.scaled(described.bed.size), described.bed.position) and child.material_override == publisher.material_for_id(described.bed.materialId, publisher.variation_for(part) - 0.025)
		elif not child is MultiMeshInstance3D: checks.only_expected_batches = false
	for capture in publisher.captured_mesh_batches.values():
		var group := "regular" if capture.nodeName == "SettledCobbleStones" else ("worn" if capture.nodeName == "WornSettledCobbleStones" else "")
		if group.is_empty():
			checks.only_expected_batches = false
			continue
		var expected_material = publisher.material_for(part) if group == "regular" else publisher.material_for_id("worn_cobble", publisher.variation_for(part) - 0.016)
		checks[group + "_exact"] = capture.mesh is BoxMesh and capture.mesh.size == Vector3.ONE and var_to_bytes(capture.transforms) == var_to_bytes(described[group + "Transforms"]) and var_to_bytes(capture.customDataOverride) == var_to_bytes(described[group + "CustomData"]) and capture.material == expected_material and not capture.collecting
	checks.bed_exact = checks.bed_exact and bed_count == 1
	parent.free()
	publisher.captured_mesh_batches.clear()
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks, "scope": "Actual original publish_settled_cobble CPU arguments and bed MeshInstance only; no GPU readback and no clipped publication."}


func _artifact_proof(result: Dictionary, described: Dictionary, transform: Transform3D, cuts: Array[AABB], baseline: Variant) -> Dictionary:
	var checks := {"descriptor_digest": result.descriptorDigest == _value_digest(described), "source_transform_exact": result.sourceTransform == transform,
		"construction_digest": result.constructionDigest == _value_digest([described, transform, result.canonicalApertures]),
		"all_original_fields_exact": true, "all_cells_independently_valid": true, "untouched_entries_byte_exact": true, "nonintersecting_stones_not_changed": true}
	var originals: Array = []
	var bed_local := Transform3D(Basis.IDENTITY.scaled(described.bed.size), described.bed.position)
	originals.append({"id": "bed", "transform": transform * bed_local, "materialKey": described.bed.materialId,
		"customData": null, "group": "bed", "ordinal": 0, "localTransform": bed_local, "latticeId": null})
	for group in ["regular", "worn"]:
		for index in range(described[group + "Transforms"].size()):
			var lattice: Vector2i = described[group + "Ids"][index]
			originals.append({"id": "%s:%d:%d" % [group, lattice.x, lattice.y], "transform": transform * described[group + "Transforms"][index],
				"materialKey": group, "customData": described[group + "CustomData"][index], "group": group, "ordinal": index,
				"localTransform": described[group + "Transforms"][index], "latticeId": lattice})
	if result.entries.size() != originals.size(): return {"passed": false, "reason": "entry_count_mismatch"}
	var failures: Array = []
	var changed_ids: Array = []
	var changed_witnesses: Array = []
	var changed_failures: Array = []
	var changed_failure_count := 0
	var cell_count := 0
	var native_count := 0
	var polygon_count := 0
	var face_count := 0
	var volume := 0.0
	for index in range(originals.size()):
		var entry: Dictionary = result.entries[index]
		var original: Dictionary = originals[index]
		checks.all_original_fields_exact = checks.all_original_fields_exact and var_to_bytes(entry.original) == var_to_bytes(original)
		var original_poly: Dictionary = _box_faces(original.transform)
		var extrema: Dictionary = _point_extrema(original_poly.vertices)
		var relevant: Array[AABB] = []
		for cut in cuts:
			if _extrema_overlap_cut(extrema, cut): relevant.append(cut)
		# Cheap, independent broadphase removes only PROVEN separated cuts from
		# the expensive witness; EVERY cell still receives the inherited proof.
		if entry.cells.size() > 32: return {"passed": false, "reason": "witness_cell_limit"}
		var proof: Dictionary = _entry_proof(entry, original, relevant)
		checks.all_cells_independently_valid = checks.all_cells_independently_valid and proof.passed
		volume += float(proof.volume)
		if not proof.passed and failures.size() < REPORT_FAILURE_ROWS: failures.append({"id": original.id, "proof": proof})
		if relevant.is_empty(): checks.nonintersecting_stones_not_changed = checks.nonintersecting_stones_not_changed and entry.unchanged
		if entry.unchanged and baseline != null: checks.untouched_entries_byte_exact = checks.untouched_entries_byte_exact and var_to_bytes(entry) == var_to_bytes(baseline.entries[index])
		if not entry.unchanged:
			changed_ids.append(original.id)
			# Independent caps: native failures cannot consume the changed-solid
			# witness/failure budget. Counts always cover ALL changed entries.
			if changed_witnesses.size() < REPORT_FAILURE_ROWS: changed_witnesses.append({"id": original.id, "proof": proof})
			if not proof.passed:
				changed_failure_count += 1
				if changed_failures.size() < REPORT_FAILURE_ROWS: changed_failures.append({"id": original.id, "proof": proof})
		for cell in entry.cells:
			cell_count += 1
			if cell.representation == "native_box": native_count += 1
			else:
				polygon_count += 1
				face_count += cell.faces.size()
	checks["independent_remaining_volume"] = absf(volume - result.remainingVolume) <= TOL * maxf(1.0, result.inputVolume)
	checks["volume_conservation"] = absf(result.inputVolume - result.remainingVolume - result.removedVolume) <= TOL * maxf(1.0, result.inputVolume)
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks, "solidCount": originals.size(),
		"verifiedCellCount": cell_count, "nativeCellCount": native_count, "convexCellCount": polygon_count, "convexFaceCount": face_count,
		"changedIds": changed_ids, "changedWitnessRows": changed_witnesses, "changedFailureCount": changed_failure_count,
		"changedFailureRows": changed_failures, "changedWitnessRowsTruncated": changed_ids.size() > changed_witnesses.size(),
		"failureRows": failures, "remainingVolume": volume}


func _artifact_failures(described: Dictionary, transform: Transform3D, cuts: Array[AABB]) -> Array:
	var rows: Array = []
	for mode in ["work_limit", "fragment_limit", "late_invalid_transform", "mismatched_custom_array", "duplicate_cross_group_lattice", "null_stone_custom", "invalid_bed", "invalid_aperture", "invalid_source_transform"]:
		var descriptor: Dictionary = described.duplicate(true)
		var input_transform := transform
		var apertures: Array[AABB] = cuts.duplicate()
		var limits: Dictionary = COMPILE_LIMITS.duplicate()
		match mode:
			"work_limit": limits.maxWork = 1
			"fragment_limit": limits.maxFragments = 1
			"late_invalid_transform": descriptor.regularTransforms[descriptor.regularTransforms.size() - 1] = Transform3D(Basis.IDENTITY.scaled(Vector3(0, 1, 1)), Vector3.ZERO)
			"mismatched_custom_array": descriptor.regularCustomData.pop_back()
			"duplicate_cross_group_lattice":
				descriptor.wornTransforms.append(descriptor.regularTransforms[0])
				descriptor.wornCustomData.append(descriptor.regularCustomData[0])
				descriptor.wornIds.append(descriptor.regularIds[0])
			"null_stone_custom":
				var untyped: Array = []
				untyped.assign(descriptor.regularCustomData)
				untyped[0] = null
				descriptor.regularCustomData = untyped
			"invalid_bed": descriptor.bed.size = Vector3.ZERO
			"invalid_aperture": apertures.append(AABB(Vector3.ZERO, Vector3.ZERO))
			"invalid_source_transform": input_transform = Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0))
		var before := var_to_bytes(descriptor)
		var cuts_before := var_to_bytes(apertures)
		var limits_before := var_to_bytes(limits)
		var result: Dictionary = Artifact.compile(descriptor, input_transform, apertures, limits)
		rows.append({"label": mode, "reason": result.get("reason", ""), "work": result.work,
			"passed": not result.completed and not result.has("entries") and var_to_bytes(descriptor) == before and var_to_bytes(apertures) == cuts_before and var_to_bytes(limits) == limits_before})
	return rows


func _same_construction(a: Dictionary, b: Dictionary) -> bool:
	return b.completed and a.constructionDigest == b.constructionDigest and var_to_bytes(a.entries) == var_to_bytes(b.entries) and var_to_bytes(a.canonicalApertures) == var_to_bytes(b.canonicalApertures)


func _entry_extrema(entry: Dictionary) -> Dictionary:
	var poly: Dictionary = _box_faces(entry.original.transform)
	return _point_extrema(poly.vertices)


func _point_extrema(points: Array) -> Dictionary:
	# Independent scalar extrema: never round a max back through AABB.size/end.
	var minimum: Array[float] = [INF, INF, INF]
	var maximum: Array[float] = [-INF, -INF, -INF]
	for point in points:
		for axis in range(3):
			minimum[axis] = minf(minimum[axis], float(point[axis]))
			maximum[axis] = maxf(maximum[axis], float(point[axis]))
	return {"minimum": minimum, "maximum": maximum}


func _extrema_overlap_cut(extrema: Dictionary, cut: AABB) -> bool:
	for axis in range(3):
		if extrema.minimum[axis] >= float(cut.end[axis]) or extrema.maximum[axis] <= float(cut.position[axis]): return false
	return true


func _touching_control(extrema: Dictionary) -> Dictionary:
	var origin := Vector3(extrema.maximum[0], extrema.minimum[1], extrema.minimum[2])
	var size := Vector3(Bearing.FOOT_WIDTH, extrema.maximum[1] - extrema.minimum[1], extrema.maximum[2] - extrema.minimum[2])
	var result := AABB(origin, size)
	# Only this SYNTHETIC boundary control extends outward in Y/Z. Its X start
	# remains the EXACT represented maximum. The two proposed foot cuts above
	# receive no enlargement. This independent calculation uses a conservative
	# relative step, not the production bit-increment implementation.
	for axis in [1, 2]:
		for step in range(4):
			if float(result.end[axis]) >= extrema.maximum[axis]: break
			size[axis] = float(size[axis]) * (1.0 + 0.0000002384185791015625)
			result.size = size
		if float(result.end[axis]) < extrema.maximum[axis]: return {"completed": false, "reason": "touch_control_extent_not_representable"}
	return {"completed": true, "bounds": result}


func _reported_vector2(value: Variant) -> Dictionary:
	if not value is String or value.length() > 96: return {"completed": false}
	var regex := RegEx.new()
	regex.compile("^\\((-?[0-9]+(?:\\.[0-9]+)?), (-?[0-9]+(?:\\.[0-9]+)?)\\)$")
	var found := regex.search(value)
	if found == null: return {"completed": false}
	var vector := Vector2(found.get_string(1).to_float(), found.get_string(2).to_float())
	return {"completed": vector.is_finite(), "value": vector}


func _bound_read(prefix: String, required_sha: String, max_bytes: int) -> Dictionary:
	var path := OS.get_environment(prefix).strip_edges().simplify_path()
	var sha := OS.get_environment(prefix + "_SHA256").strip_edges().to_lower()
	if not path.is_absolute_path() or sha != required_sha or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != sha: return {"completed": false, "reason": "missing_or_mismatched_sha", "input": prefix}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"completed": false, "reason": "input_open_failed"}
	var length := file.get_length()
	if length <= 0 or length > max_bytes:
		file.close()
		return {"completed": false, "reason": "input_size_limit"}
	var bytes := file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	if not complete or FileAccess.get_sha256(path) != sha: return {"completed": false, "reason": "input_changed_or_incomplete"}
	return {"completed": true, "bytes": bytes, "sha256": sha, "path": path}


func _value_digest(value: Variant) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()


func _archive_digest(value: Variant) -> String:
	return var_to_bytes(value).hex_encode().sha256_text()


func _paving_history_digest(history) -> String:
	return _value_digest([history.route_corridors, history.tree_placements, history.history_events, history.history_event_cells])
