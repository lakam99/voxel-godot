extends SceneTree

## One reported broad rejection; frozen source-envelope diagnosis only.
## Inputs (absolute paths): VOXEL_FACADE_BLOCKED_SOURCE / _SOURCE_SHA256,
## VOXEL_FACADE_BLOCKED_INPUT_REPORT / _INPUT_REPORT_SHA256.
## Output: new VOXEL_FACADE_BLOCKED_REPORT JSON. No generation/publication.
const Recipe = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Frame = preload("res://scripts/buildings/FacadeBearingFrameBuilder.gd")
const MAX_BYTES := 268435456
const MAX_ROWS := 512
var _trace_work := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_FACADE_BLOCKED_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		push_error("Require fresh VOXEL_FACADE_BLOCKED_REPORT")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var result := _inspect()
	result["elapsedMsec"] = Time.get_ticks_msec() - started
	result["traceProjectionWork"] = _trace_work
	result["evidenceLevel"] = "single_report_selected_frozen_source_envelope_diagnostic"
	result["limitations"] = "No mesh intersection, structural acceptance, generation, global validation or new geometry. Exact first obstructing source AABB under recipe policy; rotated-part AABBs remain conservative. Footing helper failures without witness stay unknown. Other groups unexamined."
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(result, "\t"))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	print("Facade blocked bay diagnostic complete: ", result.get("diagnosticCompleted", false))
	quit(0 if written and result.get("diagnosticCompleted", false) else 2)


func _read_bound(prefix: String) -> Dictionary:
	var path := OS.get_environment(prefix).strip_edges().simplify_path()
	var sha := OS.get_environment(prefix + "_SHA256").strip_edges().to_lower()
	if not path.is_absolute_path() or sha.length() != 64 or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != sha: return {"ready": false, "reason": "missing_or_mismatched_sha", "input": prefix}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ready": false, "reason": "input_open_failed"}
	var length := file.get_length()
	if length <= 0 or length > MAX_BYTES:
		file.close()
		return {"ready": false, "reason": "input_size_limit"}
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	if not complete or FileAccess.get_sha256(path) != sha: return {"ready": false, "reason": "incomplete_or_changed_input"}
	return {"ready": true, "path": path, "sha256": sha, "bytes": bytes}


func _inspect() -> Dictionary:
	var source_file := _read_bound("VOXEL_FACADE_BLOCKED_SOURCE")
	if not source_file.ready: return source_file
	var report_file := _read_bound("VOXEL_FACADE_BLOCKED_INPUT_REPORT")
	if not report_file.ready: return report_file
	var decoded: Variant = bytes_to_var(source_file.bytes)
	var report_value: Variant = JSON.parse_string(report_file.bytes.get_string_from_utf8())
	if not decoded is Dictionary or not report_value is Dictionary: return {"reason": "invalid_input_encoding"}
	var archive: Dictionary = decoded
	var report: Dictionary = report_value
	if archive.get("schemaVersion") != 1 or archive.get("provenance") != "successful_full_facade_recipe_contract" or not report.get("passed", false) or not archive.get("mainShardPassed", false): return {"reason": "requires_successful_main_shard"}
	if not report.get("wholeCitadel") is Dictionary or not report.get("candidateArtifact") is Dictionary or not archive.get("beforeSnapshot") is Dictionary or not archive.get("furnitureSnapshot") is Dictionary or not archive.get("protectedReservations") is Array: return {"reason": "invalid_archive_schema"}
	var whole: Dictionary = report.wholeCitadel
	if report.candidateArtifact.get("sha256") != source_file.sha256 or whole.get("sourceDigest") != archive.get("sourceDigest") or whole.get("fixtureDigest") != archive.get("fixtureDigest") or whole.get("policyDigest") != archive.get("policyDigest"): return {"reason": "report_archive_pairing_mismatch"}
	if _digest(archive.beforeSnapshot) != archive.sourceDigest or _digest(archive.get("fixture")) != archive.fixtureDigest: return {"reason": "snapshot_digest_mismatch"}
	if not archive.get("contractIdentity") is Dictionary: return {"reason": "missing_contract_identity"}
	for identity_path in archive.contractIdentity:
		if FileAccess.get_sha256(identity_path) != archive.contractIdentity[identity_path]: return {"reason": "changed_contract_identity", "path": identity_path}
	if not archive.beforeSnapshot.get("parts") is Array or not archive.beforeSnapshot.get("rooms") is Array or not archive.furnitureSnapshot.get("parts") is Array: return {"reason": "invalid_source_collections"}
	if archive.beforeSnapshot.parts.size() > Frame.MAX_PARTS or archive.beforeSnapshot.rooms.size() > Frame.MAX_RESERVATIONS or archive.furnitureSnapshot.parts.size() + archive.protectedReservations.size() > Frame.MAX_RESERVATIONS: return {"reason": "source_collection_limit"}
	if _digest({"furnitureParts": archive.furnitureSnapshot.parts, "reservedVolumes": archive.protectedReservations}) != archive.policyDigest: return {"reason": "policy_digest_mismatch"}
	if not whole.get("batch") is Dictionary or not whole.batch.get("calls") is Array: return {"reason": "missing_batch_calls"}
	var selected: Dictionary = {}
	var prefix := ""
	var prior_successes := 0
	for call in whole.batch.calls:
		for attempt in call.get("attempts", []):
			if attempt.get("reason") == "no_clear_broad_bearing_region":
				selected = attempt
				prefix = call.prefix
				break
		if not selected.is_empty(): break
		if call.get("ready", false): prior_successes += 1
	if selected.is_empty(): return {"reason": "no_reported_broad_rejection"}
	# Do not pretend the initial snapshot represents a later private batch state.
	if prior_successes != 0: return {"reason": "selected_group_requires_intermediate_source_not_archived"}
	if not selected.get("memberIds") is Array or selected.memberIds.is_empty() or selected.memberIds.size() > Frame.MAX_MEMBERS or not selected.get("supportAttempts") is Array or selected.supportAttempts.size() > Recipe.MAX_BEARING_SURFACES: return {"reason": "invalid_selected_group"}
	var b = Recipe.copy_blueprint(archive.beforeSnapshot)
	if b.parts.size() > Frame.MAX_PARTS or b.rooms.size() > Frame.MAX_RESERVATIONS or _digest(b.snapshot()) != archive.sourceDigest: return {"reason": "invalid_source_size_or_roundtrip"}
	var by_id: Dictionary = {}
	var obstacle_rows: Array = []
	var obstacles: Array[AABB] = []
	for part in b.parts:
		if by_id.has(part.id): return {"reason": "duplicate_source_id"}
		by_id[part.id] = part
		var bounds: AABB = Frame._bounds(part)
		if not Frame._valid_bounds(bounds): return {"reason": "invalid_source_bounds"}
		_add_obstacle(obstacle_rows, obstacles, "source_part", part.id, bounds, AABB(bounds.position - Vector3(Recipe.CLEARANCE, 0, Recipe.CLEARANCE), bounds.size + Vector3(2 * Recipe.CLEARANCE, 0, 2 * Recipe.CLEARANCE)), part.rotation != Vector3.ZERO)
	var bay: Array = []
	for id in selected.memberIds:
		if not by_id.has(id) or bay.has(by_id[id]): return {"reason": "invalid_report_member"}
		bay.append(by_id[id])
	var bounds: AABB = Frame._bounds(bay[0])
	for panel in bay:
		if panel.semantic != "citadel_urban_facade" or panel.rotation != Vector3.ZERO or absf(panel.position.x - bay[0].position.x) > Frame.EPS: return {"reason": "nonplanar_report_members"}
		bounds = bounds.merge(Frame._bounds(panel))
	if bounds.size.z < 1.2 or bounds.size.z > 5.0: return {"reason": "unsupported_report_span"}
	var doors: Array = b.parts.filter(func(part): return part.id.begins_with(prefix + "_") and part.kind == "door" and part.recipe.has("roomId"))
	if doors.size() != 1: return {"reason": "ambiguous_owner_door"}
	var owner_rooms: Array = b.rooms.filter(func(room): return room.get("id") == doors[0].recipe.roomId)
	if owner_rooms.size() != 1: return {"reason": "ambiguous_owner_room"}
	var outward := Vector3(signf(bay[0].position.x - owner_rooms[0].bounds.get_center().x), 0, 0)
	if outward == Vector3.ZERO: return {"reason": "ambiguous_outward"}
	var reserved: Array = []
	for index in range(archive.protectedReservations.size()):
		var volume: Variant = archive.protectedReservations[index]
		if not volume is AABB or not Frame._valid_bounds(volume): return {"reason": "invalid_protected_reservation"}
		_add_reservation(reserved, obstacle_rows, obstacles, "protected_reservation", "protectedReservations[%d]" % index, volume)
	if not archive.furnitureSnapshot.get("parts") is Array: return {"reason": "invalid_furniture"}
	for record in archive.furnitureSnapshot.parts:
		var occupied: Dictionary = Frame.furnishing_bounds(record)
		if not occupied.ready: return occupied
		_add_reservation(reserved, obstacle_rows, obstacles, "furniture", String(record.get("id", "")), occupied.bounds)
	for room in b.rooms:
		if not room.get("bounds") is AABB or not room.get("accesses", []) is Array: return {"reason": "invalid_room"}
		if room.get("role", "") != "courtyard": _add_reservation(reserved, obstacle_rows, obstacles, "room", String(room.get("id", "")), room.bounds)
		for access in room.get("accesses", []):
			if not access.get("position") is Vector3 or not access.get("size") is Vector3: return {"reason": "invalid_access"}
			_add_reservation(reserved, obstacle_rows, obstacles, "access", String(room.get("id", "")) + "/" + String(access.get("id", "")), AABB(access.position - access.size * 0.5, access.size))
		if reserved.size() > Frame.MAX_RESERVATIONS: return {"reason": "reservation_limit"}
	if reserved.size() > Frame.MAX_RESERVATIONS: return {"reason": "reservation_limit"}
	var door_visuals: Dictionary = Frame.closed_door_reservations(b)
	if not door_visuals.ready: return door_visuals
	for primitive in door_visuals.records:
		_add_reservation(reserved, obstacle_rows, obstacles, "ordinary_door_primitive", primitive.partId + "/" + primitive.name, primitive.bounds)
	if reserved.size() > Frame.MAX_RESERVATIONS: return {"reason": "reservation_limit"}
	var minimum_top := INF
	for attempt in selected.supportAttempts:
		if not by_id.has(attempt.supportId): return {"reason": "missing_reported_support"}
		minimum_top = minf(minimum_top, Frame._bounds(by_id[attempt.supportId]).end.y)
	if not is_finite(minimum_top): return {"reason": "missing_reported_supports"}
	var query := AABB(Vector3(bounds.position.x - Frame.FOOT_WIDTH, minimum_top, bounds.position.z - Frame.FOOT_WIDTH), Vector3(bounds.size.x + 2 * Frame.FOOT_WIDTH, bounds.position.y - minimum_top, bounds.size.z + 2 * Frame.FOOT_WIDTH)).grow(2 * Recipe.CLEARANCE)
	var all_count := obstacles.size()
	var local_rows: Array = []
	var local_bounds: Array[AABB] = []
	var footing_bounds: Array[AABB] = []
	for obstacle in obstacle_rows:
		if not query.intersects(obstacle.testedBounds): continue
		local_rows.append(obstacle)
		local_bounds.append(obstacle.testedBounds)
		footing_bounds.append(obstacle.bounds if obstacle.ownerKind == "source_part" else obstacle.testedBounds)
	obstacle_rows = local_rows
	obstacles = local_bounds
	var budget := {"remaining": 131072 - all_count * 2}
	var rows: Array = []
	for support_attempt in selected.supportAttempts:
		var support_id: String = support_attempt.supportId
		if not by_id.has(support_id): return {"reason": "missing_reported_support"}
		var seat: AABB = Frame._bounds(by_id[support_id])
		var normal: Dictionary = Recipe._broad_normal_candidates(bounds, seat, outward, obstacles, budget)
		if not normal.ready:
			rows.append({"supportId": support_id, "supportBounds": seat, "stage": "normal_region", "result": normal})
			if String(normal.reason).contains("limit"): return {"reason": normal.reason, "rows": rows}
			continue
		for x in normal.centers:
			if rows.size() >= MAX_ROWS: return {"reason": "diagnostic_row_limit", "rows": rows}
			var center := Vector3(x, bounds.position.y - Frame.SILL_HEIGHT * 0.5, bounds.get_center().z)
			var size := Vector3(Frame.POST_WIDTH, Frame.SILL_HEIGHT, bounds.size.z)
			var row := {"supportId": support_id, "supportBounds": seat, "normalCenter": x, "stage": "sill"}
			var envelopes: Array = [AABB(center - size * 0.5, size)]
			var clear: Dictionary = Recipe._broad_envelopes_clear(envelopes, obstacles, budget)
			row["fullSpanResult"] = clear.duplicate(true)
			var inset: Dictionary = {}
			if not clear.ready and not String(clear.reason).contains("limit"):
				row["fullSpanObstacle"] = _first_obstacle(envelopes, obstacle_rows)
				row.stage = "inset_interval"
				inset = Recipe._inset_sill_interval(bounds, center.x, obstacles, budget)
				clear = inset
				row["insetResult"] = inset.duplicate(true)
				if inset.ready:
					var sill: AABB = envelopes[0]
					sill.position.z = inset.interval.x
					sill.size.z = inset.interval.y - inset.interval.x
					envelopes = [sill]
					row.stage = "inset_sill"
					clear = Recipe._broad_envelopes_clear(envelopes, obstacles, budget)
				elif inset.reason == "sill_obstacle_exceeds_end_repair_envelope":
					row["firstObstacle"] = _inset_obstacle(bounds, center.x, obstacle_rows)
			if clear.ready:
				row.stage = "footing_offsets"
				var feet: Dictionary = Frame._plan_footing_offsets_from_bounds(center, 2, bounds.size.z, outward, seat.end.y, footing_bounds, Recipe.CLEARANCE, seat, budget, inset.get("interval"))
				clear = feet
				if feet.ready:
					row.stage = "foot_post_envelopes"
					envelopes = []
					for placement in Frame.footing_layout(center, 2, bounds.size.z, outward, feet.offsets):
						var fc: Vector3 = placement.footCenter
						fc.y = seat.end.y + Frame.FOOT_HEIGHT * 0.5
						var fs := Vector3(Frame.FOOT_WIDTH, Frame.FOOT_HEIGHT, Frame.FOOT_WIDTH)
						envelopes.append(AABB(fc - fs * 0.5, fs))
						var bottom: float = seat.end.y + Frame.FOOT_HEIGHT
						var top: float = bounds.position.y - Frame.SILL_HEIGHT
						var pc: Vector3 = placement.postCenter
						pc.y = (bottom + top) * 0.5
						var ps := Vector3(Frame.POST_WIDTH, top - bottom, Frame.POST_WIDTH)
						envelopes.append(AABB(pc - ps * 0.5, ps))
					clear = Recipe._broad_envelopes_clear(envelopes, obstacles, budget)
				else:
					row["footingWitness"] = _isolated_footing_blocker(center, bounds, outward, seat, inset.get("interval"), obstacle_rows, footing_bounds, budget)
			row["result"] = clear
			if not clear.ready and row.stage in ["sill", "inset_sill", "foot_post_envelopes"] and not String(clear.reason).contains("limit"):
				row["firstObstacle"] = _first_obstacle(envelopes, obstacle_rows)
				if row.firstObstacle.get("reason") == "trace_work_limit": return {"reason": "trace_work_limit", "rows": rows}
			if clear.ready:
				# Do not call closure discovery: it performs local validation.
				row.stage = "support_closure_not_executed"
				row["witnessStatus"] = "geometry_clear_closure_unknown_no_validation_requested"
			rows.append(row)
			if not clear.ready and String(clear.get("reason", "")).contains("limit"): return {"reason": clear.reason, "rows": rows}
	var unchanged: bool = _digest(b.snapshot()) == archive.sourceDigest and FileAccess.get_sha256(source_file.path) == source_file.sha256 and FileAccess.get_sha256(report_file.path) == report_file.sha256
	return {"diagnosticCompleted": unchanged and budget.remaining >= 0 and _trace_work <= 131072, "sourceUnchanged": unchanged, "artifactSha256": source_file.sha256, "inputReportSha256": report_file.sha256, "ownerPrefix": prefix, "memberIds": selected.memberIds, "selection": "first reported no_clear_broad_bearing_region before any successful batch call", "reportedReason": selected.reason, "groupBounds": bounds, "outward": outward, "rows": rows, "localObstacles": obstacle_rows, "allObstacleCount": all_count, "localObstacleCount": obstacle_rows.size(), "queryBounds": query, "recipeProjectionWork": 131072 - budget.remaining}


func _inset_obstacle(panel: AABB, normal: float, obstacles: Array) -> Dictionary:
	# Adjudicate the rejecting predicate only; do not invent a new interval.
	var sill := AABB(Vector3(normal - Frame.POST_WIDTH * 0.5, panel.position.y - Frame.SILL_HEIGHT, panel.position.z), Vector3(Frame.POST_WIDTH, Frame.SILL_HEIGHT, panel.size.z))
	var limit: float = Frame.maximum_post_inset(panel.size.z)
	var left_limit: float = panel.position.z + limit - Frame.POST_WIDTH * 0.5 - Recipe.CLEARANCE
	var right_limit: float = panel.end.z - limit + Frame.POST_WIDTH * 0.5 + Recipe.CLEARANCE
	for obstacle in obstacles:
		_trace_work += 1
		if _trace_work > 131072: return {"reason": "trace_work_limit"}
		if not Frame._penetrates(sill, obstacle.testedBounds): continue
		if obstacle.testedBounds.end.z + Recipe.CLEARANCE <= left_limit or obstacle.testedBounds.position.z - Recipe.CLEARANCE >= right_limit: continue
		var witness: Dictionary = _first_obstacle([sill], [obstacle])
		witness["leftCutRequired"] = obstacle.testedBounds.end.z + Recipe.CLEARANCE
		witness["leftCutMaximum"] = left_limit
		witness["rightCutRequired"] = obstacle.testedBounds.position.z - Recipe.CLEARANCE
		witness["rightCutMinimum"] = right_limit
		return witness
	return {"reason": "no_matching_inset_rejection_witness"}


func _isolated_footing_blocker(center: Vector3, panel: AABB, outward: Vector3, seat: AABB, interval: Variant, owners: Array, obstacles: Array[AABB], budget: Dictionary) -> Dictionary:
	# Bounded diagnostic isolation using the SAME solver: an obstacle that
	# alone eliminates an end-foot range is sufficient evidence of blockage,
	# never a claim that removing it would make the full construction valid.
	var empty: Array[AABB] = []
	var baseline: Dictionary = Frame._plan_footing_offsets_from_bounds(center, 2, panel.size.z, outward, seat.end.y, empty, Recipe.CLEARANCE, seat, budget, interval)
	if not baseline.ready: return {"status": "support_or_policy_alone_rejects", "result": baseline}
	for index in range(obstacles.size()):
		var single: Array[AABB] = [obstacles[index]]
		var result: Dictionary = Frame._plan_footing_offsets_from_bounds(center, 2, panel.size.z, outward, seat.end.y, single, Recipe.CLEARANCE, seat, budget, interval)
		if result.ready: continue
		if String(result.reason).contains("work_limit"): return result
		var witness: Dictionary = owners[index].duplicate(true)
		witness["status"] = "single_obstacle_alone_eliminates_a_foot_range"
		witness["result"] = result
		witness["footingTestedBounds"] = obstacles[index]
		witness["emptyObstacleOffsets"] = baseline.offsets
		return witness
	return {"status": "combined_obstacles_block_no_single_owner_proven"}


func _add_obstacle(rows: Array, obstacles: Array[AABB], kind: String, id: String, raw: AABB, tested: AABB, conservative := false) -> void:
	rows.append({"ownerKind": kind, "ownerId": id, "bounds": raw, "testedBounds": tested, "rotatedAabbConservative": conservative})
	obstacles.append(tested)


func _add_reservation(reserved: Array, rows: Array, obstacles: Array[AABB], kind: String, id: String, volume: AABB) -> void:
	reserved.append(volume)
	_add_obstacle(rows, obstacles, kind, id, volume, volume.grow(Recipe.CLEARANCE))


func _first_obstacle(envelopes: Array, obstacles: Array) -> Dictionary:
	for index in range(envelopes.size()):
		var envelope: AABB = envelopes[index]
		for obstacle in obstacles:
			_trace_work += 1
			if _trace_work > 131072: return {"reason": "trace_work_limit"}
			if not Frame._penetrates(envelope, obstacle.testedBounds): continue
			var row: Dictionary = obstacle.duplicate(true)
			row["envelopeIndex"] = index
			row["envelopeBounds"] = envelope
			row["overlapMin"] = envelope.position.max(obstacle.testedBounds.position)
			row["overlapMax"] = envelope.end.min(obstacle.testedBounds.end)
			row["signedRawOverlap"] = envelope.end.min(obstacle.bounds.end) - envelope.position.max(obstacle.bounds.position)
			return row
	return {"reason": "no_matching_obstacle_witness"}


func _digest(value: Variant) -> String:
	return var_to_bytes(value).hex_encode().sha256_text()
