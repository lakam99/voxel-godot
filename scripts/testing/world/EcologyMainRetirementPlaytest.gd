extends Node

const MainScene := preload("res://scenes/Main.tscn")
const Adapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const REPORT_SCHEMA := "ecology-main-visual-retirement/v1"
const PROVIDER_ID := "ecology_and_static_props"
const FIXED_SEED := "ecology-main-retirement-stage5"
const OBSERVATION_LIMIT_SECONDS := 420.0

var main: Node3D
var provider: Object
var coordinator: Object
var player: CharacterBody3D
var camera: Camera3D
var checks: Dictionary = {}
var trace: Array[Dictionary] = []
var failures: Array[String] = []
var run_started_msec := 0
var seed_text := ""
var report_path := ""
var progress_path := ""
var before_path := ""
var after_path := ""
var finished := false
var startup_completion_observed := false
var startup_failure_observed := false
var startup_failure_message := ""


func _ready() -> void:
	run_started_msec = Time.get_ticks_msec()
	seed_text = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	report_path = OS.get_environment("VOXEL_ECOLOGY_MAIN_RETIREMENT_REPORT")
	progress_path = OS.get_environment("VOXEL_ECOLOGY_MAIN_RETIREMENT_PROGRESS")
	before_path = OS.get_environment("VOXEL_ECOLOGY_MAIN_RETIREMENT_BEFORE")
	after_path = OS.get_environment("VOXEL_ECOLOGY_MAIN_RETIREMENT_AFTER")
	call_deferred("_run")


func _run() -> void:
	_check("fixed_seed_and_no_tutorial_inputs", seed_text == FIXED_SEED \
		and OS.get_environment("VOXEL_PLAYTEST") == "1", {
		"seed":seed_text, "expectedSeed":FIXED_SEED,
		"playtest":OS.get_environment("VOXEL_PLAYTEST"),
		"userArguments":OS.get_cmdline_user_args()})
	main = MainScene.instantiate() as Node3D
	if not is_instance_valid(main):
		_fail("main_scene_instantiated", "Main.tscn failed to instantiate")
		_finish()
		return
	if main.has_signal("startup_loading_completed"):
		main.connect("startup_loading_completed", Callable(self, "_on_main_startup_completed"))
	if main.has_signal("startup_loading_failed"):
		main.connect("startup_loading_failed", Callable(self, "_on_main_startup_failed"))
	_write_progress("main_instantiated_waiting_for_startup_signal", {
		"scene":"res://scenes/Main.tscn", "launchOptions":main.get("launch_options")})
	add_child(main)
	var launch_options: Dictionary = main.get("launch_options")
	_check("production_main_skips_tutorial", bool(launch_options.get("skipTutorial", false)), {
		"launchOptions":launch_options, "scene":"res://scenes/Main.tscn"})
	var started_usec := Time.get_ticks_usec()
	while is_inside_tree() and is_instance_valid(main) and main.is_inside_tree() \
		and not startup_completion_observed and not startup_failure_observed:
		if Engine.get_process_frames() % 300 == 0:
			_write_progress("waiting_for_main_startup_readiness", {
				"elapsedUsec":Time.get_ticks_usec() - started_usec,
				"completionSignalObserved":startup_completion_observed,
				"failureSignalObserved":startup_failure_observed,
				"readinessDomains":main.get("startup_readiness_domains"),
				"loadingFailure":main.get("startup_loading_failure_result")})
		await get_tree().process_frame
	var gameplay_ready := startup_completion_observed and not startup_failure_observed \
		and String(main.get("startup_readiness_domains").get("gameplay", {}).get(
			"status", "")) == "ready"
	_write_progress("main_startup_signal_observed", {
		"ready":gameplay_ready, "elapsedUsec":Time.get_ticks_usec() - started_usec,
		"completionSignalObserved":startup_completion_observed,
		"failureSignalObserved":startup_failure_observed,
		"readinessDomains":main.get("startup_readiness_domains"),
		"failure":main.get("startup_loading_failure_result")})
	_trace("main_startup_readiness", {
		"ready":gameplay_ready, "elapsedUsec":Time.get_ticks_usec() - started_usec,
		"completionSignalObserved":startup_completion_observed,
		"failureSignalObserved":startup_failure_observed,
		"failureMessage":startup_failure_message,
		"failure":main.get("startup_loading_failure_result"),
		"readinessDomains":main.get("startup_readiness_domains")})
	_check("main_gameplay_startup_ready", gameplay_ready, {
		"failure":main.get("startup_loading_failure_result"),
		"readinessDomains":main.get("startup_readiness_domains")})
	if not gameplay_ready:
		_finish()
		return
	provider = main.get("ecology_static_section_provider") as Object
	coordinator = main.get("world_static_section_coordinator") as Object
	player = main.get("player") as CharacterBody3D
	camera = player.get("camera") as Camera3D if is_instance_valid(player) else null
	_check("production_ecology_provider_and_coordinator_live",
		is_instance_valid(provider) and is_instance_valid(coordinator) \
		and provider.get("_world_id") == coordinator.get("_world_id"), {
		"provider":str(provider), "coordinator":str(coordinator),
		"providerWorldId":provider.get("_world_id") if is_instance_valid(provider) else "",
		"coordinatorWorldId":coordinator.get("_world_id") if is_instance_valid(coordinator) else ""})
	if not is_instance_valid(provider) or not is_instance_valid(coordinator) \
			or not is_instance_valid(player) or not is_instance_valid(camera):
		_finish()
		return
	var pair := await _wait_for_live_legacy_pair()
	_check("real_multisection_detail_and_harvestable_prop_found",
		pair.get("status") == "ready", _pair_summary(pair))
	if pair.get("status") != "ready":
		_finish()
		return
	var census: Dictionary = pair.get("census", {})
	var detail: Dictionary = pair.detail
	var prop: Dictionary = pair.prop
	var sections: Array[Vector3i] = pair.sections
	var old_targets: Array[GeometryInstance3D] = []
	old_targets.append(detail.target as GeometryInstance3D)
	for target_value: Variant in prop.targets:
		if target_value is GeometryInstance3D:
			old_targets.append(target_value)
	var captured_units: Dictionary = provider.get("_latest_legacy_visual_units")
	var detail_unit_id := String(detail.unitId)
	var prop_unit_id := String(prop.unitId)
	var detail_unit: Dictionary = captured_units.get(detail_unit_id, {})
	var prop_unit: Dictionary = captured_units.get(prop_unit_id, {})
	var detail_unit_revision := String(detail_unit.get("unitRevision", ""))
	var prop_unit_revision := String(prop_unit.get("unitRevision", ""))
	var source_owner_evidence := _source_owner_evidence(detail, prop, census,
		sections, detail_unit, prop_unit)
	_check("roster_census_covers_exact_live_source_revisions",
		census.get("status") == "complete" and _census_covers_pair(
			census, detail, prop, sections), source_owner_evidence)
	if census.get("status") != "complete" or not _census_covers_pair(
			census, detail, prop, sections):
		_finish()
		return
	var all_old_visible := true
	for target: GeometryInstance3D in old_targets:
		all_old_visible = all_old_visible and is_instance_valid(target) \
			and target.visible and target.is_visible_in_tree() \
			and not bool(target.get_meta("ecology_section_owned", false))
	_check("legacy_visuals_visible_before_current_receipts", all_old_visible, {
		"detailVisible":detail.target.visible,
		"propVisualsVisible":_targets_visible(prop.targets),
		"owningSections":_sections_to_json(sections),
		"receiptsBefore":_receipt_rows(sections)})
	if not all_old_visible:
		_fail("live_legacy_visual_window_unavailable",
			"The selected Main sources were already hidden or section-owned; no legacy view was fabricated.")
		_finish()
		return
	var camera_setup := _aim_camera_at_pair(detail, prop)
	if camera_setup.get("status") != "ready":
		_fail("headed_camera_setup", JSON.stringify(camera_setup))
		_finish()
		return
	await _capture_viewport(before_path)
	_trace("legacy_visuals_visible_before_install", {
		"screenshot":before_path, "sources":source_owner_evidence,
		"targets":_target_identity_rows(old_targets),
		"camera":camera_setup, "nativeReceipts":_receipt_rows(sections)})
	# Move only the observation point to the selected generated sources so the
	# normal runtime loop admits visible section demand. This fixture does not
	# claim player traversal or NPC behavior.
	var original_player_position := player.global_position
	var original_physics_enabled := player.is_physics_processing()
	player.set_physics_process(false)
	player.velocity = Vector3.ZERO
	player.global_position = camera_setup.focus + Vector3.UP * 2.4
	_aim_camera_at_pair(detail, prop)
	await _wait_frames(3)
	var demand_wait := await _wait_for_receipts_and_retirement(sections, detail,
		prop, _dict_section_keys(detail.sections), _dict_section_keys(prop.sections),
		detail_unit_id, prop_unit_id, detail_unit_revision, prop_unit_revision,
		OBSERVATION_LIMIT_SECONDS)
	_trace("current_receipts_and_provider_retirement", demand_wait)
	var receipts_ready: bool = demand_wait.get("status") == "ready"
	_check("every_owning_section_has_current_native_receipt_before_retirement",
		receipts_ready and bool(demand_wait.get("allReceiptsCurrent", false)) \
		and bool(demand_wait.get("retirementAfterReceipts", false)) \
		and bool(demand_wait.get("sourceReceiptMembershipComplete", false)) \
		and bool(demand_wait.get("retirementRevisionMatches", false)), demand_wait)
	var body: StaticBody3D = prop.body
	var collision: CollisionShape3D = prop.collision
	var same_body: bool = is_instance_valid(body) and body.get_instance_id() == int(prop.bodyInstanceId) \
		and body.get_parent() == prop.chunk
	var same_collision := is_instance_valid(collision) \
		and collision.get_instance_id() == int(prop.collisionInstanceId) \
		and collision.get_parent() == body and not collision.disabled
	var prop_ids_unchanged := String(body.get_meta("static_ecology_source_id", "")) \
		== String(prop.sourceId) and String(body.get_meta("prop_id", "")) == String(prop.propId)
	_check("prop_body_collision_and_gameplay_ids_persist", same_body and same_collision \
		and prop_ids_unchanged, {"sameBody":same_body, "sameCollision":same_collision,
		"sourceId":body.get_meta("static_ecology_source_id", "") if is_instance_valid(body) else "",
		"propId":body.get_meta("prop_id", "") if is_instance_valid(body) else "",
		"expectedSourceId":prop.sourceId, "expectedPropId":prop.propId})
	var old_visuals_retired: bool = not detail.target.visible and _targets_hidden(prop.targets)
	_check("legacy_visuals_retired_after_all_current_receipts", old_visuals_retired, {
		"detailVisible":detail.target.visible,
		"propVisualsVisible":_targets_visible(prop.targets),
		"receipts":demand_wait.get("receipts", [])})
	_aim_camera_at_pair(detail, prop)
	await _capture_viewport(after_path)
	_trace("after_view_capture", {"screenshot":after_path,
		"oldTargets":_target_identity_rows(old_targets),
		"bodyInstanceId":body.get_instance_id() if is_instance_valid(body) else 0,
		"collisionInstanceId":collision.get_instance_id() if is_instance_valid(collision) else 0,
		"receipts":demand_wait.get("receipts", [])})
	player.global_position = original_player_position
	player.set_physics_process(original_physics_enabled)
	_finish()


func _wait_for_live_legacy_pair() -> Dictionary:
	var last_diagnostics: Dictionary = {}
	var deadline := Time.get_ticks_msec() + int(OBSERVATION_LIMIT_SECONDS * 1000.0)
	var last_signature := ""
	var unchanged := 0
	while is_inside_tree() and Time.get_ticks_msec() < deadline:
		var candidate_result := _discover_pair()
		if candidate_result.get("status") == "ready":
			return candidate_result
		last_diagnostics = candidate_result
		if Engine.get_process_frames() % 300 == 0:
			_write_progress("waiting_for_visible_legacy_pair", candidate_result)
		var signature := JSON.stringify(candidate_result)
		if signature == last_signature:
			unchanged += 1
		else:
			last_signature = signature
			unchanged = 0
		if unchanged % 60 == 0:
			_trace("waiting_for_real_pair", {"unchangedSamples":unchanged,
				"diagnostics":candidate_result})
		await get_tree().physics_frame
	return {"status":"pending", "reason":"live_ecology_pair_not_found_before_watchdog",
		"diagnostics":last_diagnostics}


func _discover_pair() -> Dictionary:
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary:
		return {"status":"pending", "reason":"main_resident_chunk_map_missing"}
	var detail_groups: Dictionary = {}
	var prop_candidates: Array[Dictionary] = []
	for chunk_key_value: Variant in chunks_value:
		if not chunk_key_value is Vector2i:
			continue
		var chunk_key: Vector2i = chunk_key_value
		var chunk := chunks_value[chunk_key] as Node3D
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			continue
		var snapshot_value: Variant = chunk.get_meta("static_ecology_source_value_snapshot", {})
		if not snapshot_value is Dictionary or snapshot_value.get("status") != "complete":
			continue
		var snapshot: Dictionary = snapshot_value
		for candidate_value: Variant in snapshot.get("candidates", []):
			if not candidate_value is Dictionary:
				continue
			var candidate: Dictionary = candidate_value
			var kind := String(candidate.get("kind", ""))
			if kind == "surface_detail":
				var mesh := provider.call("_detail_candidate_mesh_if_current", main,
					candidate) as Mesh
				var transform_value: Variant = candidate.get("transform", null)
				if not is_instance_valid(mesh) or not transform_value is Transform3D:
					continue
				var section_key: Vector3i = Adapter._surface_detail_census_section_key(
					mesh, chunk.global_transform, transform_value)
				var detail_type := String(candidate.get("detailType", ""))
				var unit_id := "decor:%d,%d:%s" % [chunk_key.x, chunk_key.y, detail_type]
				var group: Dictionary = detail_groups.get(unit_id, {
					"unitId":unit_id, "chunk":chunk, "chunkKey":chunk_key,
					"detailType":detail_type, "sourceIds":[], "sections":{},
					"sectionsBySource":{},
					"sourceRevisions":{}, "candidateRecords":[]})
				var detail_source_id := String(candidate.get("sourceId", ""))
				group.sourceIds.append(detail_source_id)
				group.sections[section_key] = true
				group.sectionsBySource[detail_source_id] = section_key
				group.sourceRevisions[detail_source_id] = \
					String(candidate.get("contentRevision", ""))
				group.candidateRecords.append(candidate)
				detail_groups[unit_id] = group
			elif kind == "realized_static_prop" and String(candidate.get("category", "")) \
					in ["surface_rocks", "ore", "forage"]:
				var source_id := String(candidate.get("sourceId", ""))
				var prop_id := String(candidate.get("propId", ""))
				var body := _find_prop_body(chunk, source_id, prop_id)
				if not is_instance_valid(body):
					continue
				var collision := _find_enabled_collision(body)
				var visual_targets := _visual_targets_for_source(body)
				if not is_instance_valid(collision) or visual_targets.is_empty() \
						or not _targets_visible(visual_targets) \
						or bool(visual_targets[0].get_meta("ecology_section_owned", false)):
					continue
				var sections: Dictionary = {}
				for member_value: Variant in candidate.get("renderMembers", []):
					if not member_value is Dictionary:
						continue
					var member: Dictionary = member_value
					var member_transform: Transform3D = member.get("transform", Transform3D.IDENTITY)
					var member_bounds: AABB = member.get("localBounds", AABB())
					var mesh_bounds: AABB = member_transform * member_bounds
					var world_transform: Transform3D = chunk.global_transform \
						* candidate.get("transform", Transform3D.IDENTITY) * member_transform
					sections[Grid.key_for_world_position(
						world_transform * mesh_bounds.get_center())] = true
				if sections.is_empty():
					continue
				prop_candidates.append({"unitId":"prop:%s" % source_id,
				"sourceId":source_id, "propId":prop_id, "candidate":candidate,
				"chunk":chunk, "chunkKey":chunk_key, "body":body,
				"bodyInstanceId":body.get_instance_id(), "collision":collision,
				"collisionInstanceId":collision.get_instance_id(),
				"targets":visual_targets, "sections":sections,
				"sourceRevision":String(candidate.get("contentRevision", ""))})
	for unit_id_value: Variant in detail_groups:
		var group: Dictionary = detail_groups[unit_id_value]
		var sections: Dictionary = group.sections
		if sections.size() < 2 or group.sourceIds.is_empty():
			continue
		var decor := group.chunk.get_node_or_null("DecorBatches") as Node
		if not is_instance_valid(decor):
			continue
		var target: MultiMeshInstance3D
		for child: Node in decor.get_children():
			if child is MultiMeshInstance3D and String(child.get_meta("detail_type", "")) \
					== String(group.detailType):
				target = child as MultiMeshInstance3D
				break
		if not is_instance_valid(target) or not target.visible \
				or not target.is_visible_in_tree() \
				or bool(target.get_meta("ecology_section_owned", false)):
			continue
		var sorted_sections: Array[Vector3i] = []
		for section_value: Variant in sections:
			sorted_sections.append(Vector3i(section_value))
		sorted_sections.sort_custom(_section_before)
		for prop: Dictionary in prop_candidates:
			if prop.chunk != group.chunk:
				continue
			var combined_sections := _union_sections(sorted_sections, prop.sections)
			var census: Dictionary = coordinator.call(
				"capture_authoritative_source_census", combined_sections)
			if census.get("status") != "complete" \
					or not _census_covers_pair(census, group, prop, combined_sections):
				continue
			var receipt_rows := _receipt_rows(combined_sections)
			if _all_receipts_current(receipt_rows):
				continue
			group["target"] = target
			group["unitId"] = String(group.unitId)
			return {"status":"ready", "detail":group, "prop":prop,
				"sections":combined_sections, "census":census,
				"receiptsBefore":receipt_rows}
	return {"status":"pending", "reason":"no_visible_multisection_detail_and_prop_pair",
		"residentChunkCount":chunks_value.size(),
		"detailBatchCount":detail_groups.size(), "eligiblePropCount":prop_candidates.size(),
		"visibleMultiSectionDetailCount":_visible_multisection_detail_count(detail_groups)}


func _wait_for_receipts_and_retirement(sections: Array[Vector3i], detail: Dictionary,
		prop: Dictionary, detail_sections: Array[Vector3i],
		prop_sections: Array[Vector3i], detail_unit_id: String, prop_unit_id: String,
		detail_unit_revision: String, prop_unit_revision: String,
		timeout_seconds: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var latest_receipts: Array[Dictionary] = []
	var started_usec := Time.get_ticks_usec()
	var last_section_current: Dictionary = {}
	var prior_target_visibility := [true, true]
	while is_inside_tree() and Time.get_ticks_msec() < deadline:
		latest_receipts = _receipt_rows(sections)
		for row: Dictionary in latest_receipts:
			var section_id := JSON.stringify(row.get("sectionKey", []))
			var current := bool(row.get("current", false))
			if not last_section_current.has(section_id) \
					or bool(last_section_current[section_id]) != current:
				last_section_current[section_id] = current
				_trace("section_native_receipt_state_changed", row)
		var current_count := 0
		for row: Dictionary in latest_receipts:
			if bool(row.get("current", false)):
				current_count += 1
		var detail_receipts_current := _receipts_current_for(latest_receipts, detail_sections)
		var prop_receipts_current := _receipts_current_for(latest_receipts, prop_sections)
		var detail_visible: bool = detail.target.visible
		var prop_visible := _targets_visible(prop.targets)
		if prior_target_visibility[0] != detail_visible \
				or prior_target_visibility[1] != prop_visible:
			_trace("legacy_visual_visibility_changed", {
				"detailVisible":detail_visible, "propVisible":prop_visible,
				"detailReceiptsCurrent":detail_receipts_current,
				"propReceiptsCurrent":prop_receipts_current,
				"receipts":latest_receipts})
		prior_target_visibility = [detail_visible, prop_visible]
		if not detail_visible and not detail_receipts_current:
			return {"status":"failed", "reason":"detail_hidden_before_all_owning_receipts_current",
				"allReceiptsCurrent":false, "retirementAfterReceipts":false,
				"receipts":latest_receipts, "demandStates":_demand_rows(sections)}
		if not prop_visible and not prop_receipts_current:
			return {"status":"failed", "reason":"prop_hidden_before_all_owning_receipts_current",
				"allReceiptsCurrent":false, "retirementAfterReceipts":false,
				"receipts":latest_receipts, "demandStates":_demand_rows(sections)}
		var targets_hidden: bool = not detail_visible and _targets_hidden(prop.targets)
		if current_count == sections.size() and targets_hidden:
			var retired_detail_revision := String(detail.target.get_meta(
				"ecology_retired_source_revision", ""))
			var retired_prop_revisions: Array[String] = []
			for target_value: Variant in prop.targets:
				if target_value is GeometryInstance3D:
					retired_prop_revisions.append(String(target_value.get_meta(
						"ecology_retired_source_revision", "")))
			var membership_current := _receipt_membership_covers_pair(latest_receipts,
				detail, prop)
			var retirement_revision_matches := retired_detail_revision == detail_unit_revision \
				and not detail_unit_revision.is_empty() \
				and not retired_prop_revisions.is_empty()
			for retired_revision: String in retired_prop_revisions:
				retirement_revision_matches = retirement_revision_matches \
					and retired_revision == prop_unit_revision
			return {"status":"ready", "elapsedUsec":Time.get_ticks_usec() - started_usec,
				"allReceiptsCurrent":true, "retirementAfterReceipts":true,
				"sourceReceiptMembershipComplete":membership_current,
				"retirementRevisionMatches":retirement_revision_matches,
				"detailUnitId":detail_unit_id, "propUnitId":prop_unit_id,
				"retiredDetailRevision":retired_detail_revision,
				"retiredPropRevisions":retired_prop_revisions,
				"detailSections":_sections_to_json(detail_sections),
				"propSections":_sections_to_json(prop_sections),
				"expectedDetailUnitRevision":detail_unit_revision,
				"expectedPropUnitRevision":prop_unit_revision,
				"receipts":latest_receipts}
		if Engine.get_process_frames() % 120 == 0:
			_trace("waiting_for_main_native_receipts", {"currentReceiptCount":current_count,
				"requiredReceiptCount":sections.size(),
				"detailVisible":detail.target.visible,
				"propVisualsVisible":_targets_visible(prop.targets),
				"receipts":latest_receipts})
		if Engine.get_process_frames() % 300 == 0:
			_write_progress("waiting_for_current_native_receipts", {
				"currentReceiptCount":current_count,
				"requiredReceiptCount":sections.size(),
				"detailVisible":detail.target.visible,
				"propVisualsVisible":_targets_visible(prop.targets),
				"receipts":latest_receipts,
				"demandStates":_demand_rows(sections)})
		await get_tree().physics_frame
	return {"status":"pending", "reason":"receipt_or_visual_retirement_stalled",
		"allReceiptsCurrent":latest_receipts.size() == sections.size() \
			and _all_receipts_current(latest_receipts),
		"retirementAfterReceipts":false, "elapsedUsec":Time.get_ticks_usec() - started_usec,
		"detailVisible":detail.target.visible,
		"propVisualsVisible":_targets_visible(prop.targets),
		"receipts":latest_receipts,
		"demandStates":_demand_rows(sections)}


func _receipt_rows(sections: Array[Vector3i]) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var receipt_map: Variant = coordinator.get("_production_candidate_receipts")
	var coverage_by_section: Variant = provider.get("_latest_coverage_by_section")
	for section_key: Vector3i in sections:
		var receipt: Dictionary = receipt_map.get(section_key, {}) if receipt_map is Dictionary else {}
		var coverage := String(coverage_by_section.get(section_key, "")) \
			if coverage_by_section is Dictionary else ""
		var current := not receipt.is_empty() and bool(coordinator.call(
			"installed_section_receipt_is_current", section_key, receipt)) \
			and _receipt_covers_provider(receipt, coverage)
		var state: Dictionary = coordinator.get("_visible_section_demands").get(
			section_key, {})
		rows.append({"sectionKey":_section_to_json(section_key),
			"current":current, "coverageRevision":coverage,
			"generation":int(receipt.get("generation", 0)),
			"censusDigest":String(receipt.get("censusDigest", "")),
			"contentManifestDigest":String(receipt.get("contentManifestDigest", "")),
			"backendInstanceId":int(receipt.get("backendInstanceId", 0)),
			"chunkInstanceId":int(receipt.get("chunkInstanceId", 0)),
			"providerCoverage":receipt.get("providerCoverage", []),
			"sourceRevisions":receipt.get("sourceRevisions", {}),
			"removalRevisions":receipt.get("removalRevisions", {}),
			"demandStage":String(state.get("stage", "missing")),
			"installedGeneration":int(state.get("installedGeneration", 0))})
	return rows


func _receipt_covers_provider(receipt: Dictionary, coverage: String) -> bool:
	if coverage.is_empty():
		return false
	for row_value: Variant in receipt.get("providerCoverage", []):
		if row_value is Array and row_value.size() >= 2 \
				and String(row_value[0]) == PROVIDER_ID:
			return String(row_value[1]) == coverage
	return false


func _receipt_membership_covers_pair(rows: Array[Dictionary], detail: Dictionary,
		prop: Dictionary) -> bool:
	var rows_by_section: Dictionary = {}
	for row: Dictionary in rows:
		rows_by_section[JSON.stringify(row.get("sectionKey", []))] = row
	for source_value: Variant in detail.get("sourceIds", []):
		var source_id := String(source_value)
		var section_key: Vector3i = detail.get("sectionsBySource", {}).get(source_id,
			Vector3i(2147483647, 2147483647, 2147483647))
		var row: Dictionary = rows_by_section.get(JSON.stringify(_section_to_json(section_key)), {})
		var receipt_revisions: Variant = row.get("sourceRevisions", null)
		var expected_revision := String(detail.get("sourceRevisions", {}).get(source_id, ""))
		if not bool(row.get("current", false)) or not receipt_revisions is Dictionary \
				or expected_revision.is_empty() \
				or String(receipt_revisions.get(source_id, "")) != expected_revision:
			return false
	var prop_source_id := String(prop.get("sourceId", ""))
	var expected_prop_revision := String(prop.get("sourceRevision", ""))
	for section_key: Vector3i in prop.get("sections", {}).keys():
		var row: Dictionary = rows_by_section.get(JSON.stringify(_section_to_json(section_key)), {})
		var receipt_revisions: Variant = row.get("sourceRevisions", null)
		if not bool(row.get("current", false)) or not receipt_revisions is Dictionary \
				or expected_prop_revision.is_empty() \
				or String(receipt_revisions.get(prop_source_id, "")) != expected_prop_revision:
			return false
	return not prop_source_id.is_empty()


func _census_covers_pair(census: Dictionary, detail: Dictionary, prop: Dictionary,
		sections: Array[Vector3i]) -> bool:
	var providers: Variant = census.get("sourceProviderIds", null)
	var revisions: Variant = census.get("sourceRevisions", null)
	var expected: Variant = census.get("expectedContributorsBySection", null)
	if not providers is Dictionary or not revisions is Dictionary or not expected is Dictionary:
		return false
	for source_value: Variant in detail.sourceIds:
		var source_id := String(source_value)
		if String(providers.get(source_id, "")) != PROVIDER_ID \
				or String(revisions.get(source_id, "")).is_empty():
			return false
	for source_id_value: Variant in detail.sourceIds:
		var source_id := String(source_id_value)
		var exact_section: Vector3i = detail.sectionsBySource.get(source_id,
			Vector3i(2147483647, 2147483647, 2147483647))
		if exact_section not in sections \
				or not (expected.get(exact_section, []) as Array).has(source_id):
			return false
	var prop_source_id := String(prop.sourceId)
	if String(providers.get(prop_source_id, "")) != PROVIDER_ID \
			or String(revisions.get(prop_source_id, "")).is_empty():
		return false
	for section_key: Vector3i in prop.sections:
		if section_key in sections and not (expected.get(section_key, []) as Array).has(prop_source_id):
			return false
	return true


func _source_owner_evidence(detail: Dictionary, prop: Dictionary, census: Dictionary,
		sections: Array[Vector3i], detail_unit: Dictionary, prop_unit: Dictionary) -> Dictionary:
	return {"worldId":String(census.get("worldId", "")), "seed":seed_text,
		"sections":_sections_to_json(sections),
		"detail":{"unitId":detail.unitId, "chunkKey":_vec2_to_json(detail.chunkKey),
			"detailType":detail.detailType, "sourceIds":detail.sourceIds,
			"sourceRevisions":detail.sourceRevisions,
			"sections":_sections_to_json(_dict_section_keys(detail.sections)),
			"targetInstanceId":detail.target.get_instance_id(),
			"unitRevision":String(detail_unit.get("unitRevision", "")),
			"requiredSections":_sections_to_json(detail_unit.get("requiredSections", []))},
		"prop":{"unitId":prop.unitId, "sourceId":prop.sourceId,
			"propId":prop.propId, "sourceRevision":prop.sourceRevision,
			"chunkKey":_vec2_to_json(prop.chunkKey),
			"ownerInstanceId":prop.chunk.get_instance_id(),
			"bodyInstanceId":prop.bodyInstanceId,
			"collisionInstanceId":prop.collisionInstanceId,
			"targetInstanceIds":_target_identity_rows(prop.targets),
			"sections":_sections_to_json(_dict_section_keys(prop.sections)),
			"unitRevision":String(prop_unit.get("unitRevision", ""))},
		"providerCoverageRevisions":census.get("providerCoverageRevisions", {}),
		"providerSnapshotRevisions":census.get("providerSnapshotRevisions", {}),
		"censusDigest":String(census.get("censusDigest", "")),
		"adapterCaptureStatus":String(census.get("status", ""))}


func _pair_summary(pair: Dictionary) -> Dictionary:
	if pair.get("status") != "ready":
		return pair
	var detail: Dictionary = pair.detail
	var prop: Dictionary = pair.prop
	return {"status":String(pair.get("status", "")),
		"worldId":String(pair.get("census", {}).get("worldId", "")),
		"sections":_sections_to_json(pair.get("sections", [])),
		"detailUnitId":String(detail.get("unitId", "")),
		"detailType":String(detail.get("detailType", "")),
		"detailSourceIds":detail.get("sourceIds", []),
		"detailSections":_sections_to_json(_dict_section_keys(detail.get("sections", {}))),
		"receiptsBefore":pair.get("receiptsBefore", []),
		"propUnitId":String(prop.get("unitId", "")),
		"propSourceId":String(prop.get("sourceId", "")),
		"propId":String(prop.get("propId", "")),
		"propSections":_sections_to_json(_dict_section_keys(prop.get("sections", {})))}


func _find_prop_body(root: Node, source_id: String, prop_id: String) -> StaticBody3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is StaticBody3D \
				and String(node.get_meta("static_ecology_source_id", "")) == source_id \
				and String(node.get_meta("prop_id", "")) == prop_id:
			return node as StaticBody3D
		stack.append_array(node.get_children())
	return null


func _find_enabled_collision(body: Node) -> CollisionShape3D:
	var stack: Array[Node] = [body]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is CollisionShape3D and not (node as CollisionShape3D).disabled:
			return node as CollisionShape3D
		stack.append_array(node.get_children())
	return null


func _visual_targets_for_source(body: Node) -> Array[GeometryInstance3D]:
	var result: Array[GeometryInstance3D] = []
	var stack: Array[Node] = []
	for child: Node in body.get_children():
		stack.append(child)
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is GeometryInstance3D and not bool(node.get_meta("ecology_section_owned", false)):
			result.append(node as GeometryInstance3D)
		stack.append_array(node.get_children())
	return result


func _aim_camera_at_pair(detail: Dictionary, prop: Dictionary) -> Dictionary:
	var target: Vector3 = (detail.target.global_position + prop.body.global_position) * 0.5
	var camera_origin: Vector3 = target + Vector3(8.0, 5.0, 9.0)
	camera.global_position = camera_origin
	camera.look_at(target, Vector3.UP)
	return {"status":"ready", "focus":target, "cameraPosition":camera_origin,
		"detailPosition":detail.target.global_position,
		"propPosition":prop.body.global_position}


func _capture_viewport(path: String) -> void:
	if path.is_empty():
		return
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		_fail("screenshot_capture", "viewport image unavailable: " + path)
		return
	var error := image.save_png(path)
	if error != OK:
		_fail("screenshot_capture", "Image.save_png failed: %s error=%d" % [path, error])


func _visible_multisection_detail_count(groups: Dictionary) -> int:
	var count := 0
	for group_value: Variant in groups.values():
		if group_value is Dictionary and (group_value.get("sections", {}) as Dictionary).size() >= 2:
			count += 1
	return count


func _targets_visible(targets: Array) -> bool:
	for value: Variant in targets:
		if value is GeometryInstance3D and (value as GeometryInstance3D).visible:
			return true
	return false


func _targets_hidden(targets: Array) -> bool:
	for value: Variant in targets:
		if value is GeometryInstance3D and (value as GeometryInstance3D).visible:
			return false
	return true


func _target_identity_rows(targets: Array) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for target_value: Variant in targets:
		if target_value is GeometryInstance3D:
			var target: GeometryInstance3D = target_value
			rows.append({"instanceId":target.get_instance_id(), "name":str(target.name),
				"visible":target.visible, "visibleInTree":target.is_visible_in_tree(),
				"sectionOwned":bool(target.get_meta("ecology_section_owned", false)),
				"retiredSourceRevision":String(target.get_meta(
					"ecology_retired_source_revision", ""))})
	return rows


func _demand_rows(sections: Array[Vector3i]) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var demands: Variant = coordinator.get("_visible_section_demands")
	for section_key: Vector3i in sections:
		var state: Dictionary = demands.get(section_key, {}) if demands is Dictionary else {}
		rows.append({"sectionKey":_section_to_json(section_key),
			"stage":String(state.get("stage", "missing")),
			"attempts":int(state.get("attempts", 0)),
			"lastReason":String(state.get("lastReason", "")),
			"lastInstallReason":String(state.get("lastInstallReason", ""))})
	return rows


func _all_receipts_current(rows: Array[Dictionary]) -> bool:
	for row: Dictionary in rows:
		if not bool(row.get("current", false)):
			return false
	return not rows.is_empty()


func _receipts_current_for(rows: Array[Dictionary], sections: Array[Vector3i]) -> bool:
	if sections.is_empty():
		return false
	for required: Vector3i in sections:
		var required_json := _section_to_json(required)
		var found := false
		for row: Dictionary in rows:
			if row.get("sectionKey", []) == required_json:
				found = bool(row.get("current", false))
				break
		if not found:
			return false
	return true


func _dict_section_keys(value: Variant) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if value is Dictionary:
		for key_value: Variant in value:
			if key_value is Vector3i:
				result.append(key_value)
	result.sort_custom(_section_before)
	return result


func _union_sections(a: Array[Vector3i], b: Dictionary) -> Array[Vector3i]:
	var result := a.duplicate()
	for key_value: Variant in b:
		if key_value is Vector3i and key_value not in result:
			result.append(key_value)
	result.sort_custom(_section_before)
	return result


func _section_before(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


func _section_to_json(key: Vector3i) -> Array[int]:
	return [key.x, key.y, key.z]


func _sections_to_json(sections: Array) -> Array:
	var result: Array = []
	for value: Variant in sections:
		if value is Vector3i:
			result.append(_section_to_json(value))
	return result


func _vec2_to_json(value: Vector2i) -> Array[int]:
	return [value.x, value.y]


func _trace(event: String, details: Dictionary) -> void:
	trace.append({"frame":Engine.get_process_frames(), "elapsedMsec":Time.get_ticks_msec() \
		- run_started_msec, "event":event, "details":details})


func _write_progress(phase: String, details: Dictionary) -> void:
	if progress_path.is_empty():
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"schema":REPORT_SCHEMA, "phase":phase,
		"frame":Engine.get_process_frames(), "elapsedMsec":Time.get_ticks_msec() \
			- run_started_msec, "details":details}, "  "))
	file.close()


func _check(name: String, passed: bool, evidence: Variant = {}) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}
	if not passed and name not in failures:
		failures.append(name)


func _fail(name: String, reason: String) -> void:
	checks[name] = {"passed":false, "evidence":{"reason":reason}}
	if name not in failures:
		failures.append(name)
	_trace("failure", {"name":name, "reason":reason})


func _finish() -> void:
	if finished:
		return
	finished = true
	var passed := failures.is_empty()
	var final_world_id := String(coordinator.get("_world_id")) \
		if is_instance_valid(coordinator) else ""
	var report := {"schema":REPORT_SCHEMA, "status":"complete" if passed else "failed",
		"passed":passed, "seed":seed_text, "worldId":final_world_id, "tutorialSkipped":
			bool(main.get("launch_options").get("skipTutorial", false)) if is_instance_valid(main) else false,
		"checkCount":checks.size(), "checks":checks, "failures":failures,
		"trace":trace, "beforeScreenshot":before_path, "afterScreenshot":after_path,
		"progressPath":progress_path,
		"evidenceLevel":"headed Main.tscn production ecology source census, coordinator/native receipts, and legacy visual retirement",
		"doesNotProve":"Broad visual parity, gameplay harvest/save replay, collision response, unload/replay parity, traversal, performance, or full ecology cutover."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file == null:
			push_error("Could not write Ecology Main retirement report: " + report_path)
		else:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	print("Ecology Main retirement report: " + report_path)
	get_tree().quit(0 if passed else 1)


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _on_main_startup_completed() -> void:
	startup_completion_observed = true


func _on_main_startup_failed(message: String) -> void:
	startup_failure_observed = true
	startup_failure_message = message
