extends "res://scripts/testing/world/EcologyMainHarvestReplayPlaytest.gd"

const OrdinaryProviderId := "ordinary-structures"
const OrdinarySeed := "ecology-main-retirement-stage5"
const OrdinaryGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const PlayerNavigator := preload("res://scripts/testing/player/LivePlaytestPlayerNavigator.gd")
const OrdinaryReceiptSchema := "ordinary-structure-main-section-replay/v1"
const StartupWaitSeconds := 180.0
const SourceWaitSeconds := 120.0
const ReceiptWaitSeconds := 300.0

var ordinary_provider: Object
var selected_cell := Vector3i.ZERO
var ordinary_selected_source_id := ""
var selected_block_type := ""
var selected_section := Vector3i.ZERO
var selected_body: StaticBody3D
var selected_visuals: Array[MeshInstance3D] = []
var selected_collision: CollisionShape3D
var saved_slot_path := ""


func _run() -> void:
	_check("fixed_seed_tutorial_free_main", seed_text == OrdinarySeed \
		and OS.get_environment("VOXEL_PLAYTEST") == "1", {
		"seed":seed_text, "expectedSeed":OrdinarySeed,
		"args":OS.get_cmdline_user_args()})
	main = MainScene.instantiate() as Node3D
	if not is_instance_valid(main):
		_fail("main_scene_instantiated", "Main.tscn failed to instantiate")
		_finish()
		return
	if main.has_signal("startup_loading_completed"):
		main.connect("startup_loading_completed", Callable(self, "_on_main_startup_completed"))
	if main.has_signal("startup_loading_failed"):
		main.connect("startup_loading_failed", Callable(self, "_on_main_startup_failed"))
	add_child(main)
	var launch_options: Dictionary = main.get("launch_options")
	_check("production_launch_skips_tutorial", bool(launch_options.get("skipTutorial", false)), launch_options)
	_write_progress("waiting_for_initial_main_gameplay_readiness", {
		"startupTimeoutSeconds":StartupWaitSeconds,
		"noProgressTimeoutSeconds":STARTUP_NO_PROGRESS_TIMEOUT_SECONDS})
	var startup_deadline := Time.get_ticks_msec() + int(StartupWaitSeconds * 1000.0)
	var startup_started := Time.get_ticks_msec()
	var startup_progress_started := startup_started
	var last_work_revision := int((main.get("startup_work_progress") as Object).get("completed_revision"))
	while is_inside_tree() and is_instance_valid(main) and not startup_completion_observed \
			and not startup_failure_observed and Time.get_ticks_msec() < startup_deadline:
		var work_progress: Object = main.get("startup_work_progress") as Object
		var current_work_revision := int(work_progress.get("completed_revision")) \
			if is_instance_valid(work_progress) else last_work_revision
		if current_work_revision > last_work_revision:
			last_work_revision = current_work_revision
			startup_progress_started = Time.get_ticks_msec()
		if Time.get_ticks_msec() - startup_progress_started >= int(STARTUP_NO_PROGRESS_TIMEOUT_SECONDS * 1000.0):
			_fail("main_startup_no_progress_timeout", JSON.stringify({
				"elapsedMsec":Time.get_ticks_msec() - startup_started,
				"noProgressTimeoutSeconds":STARTUP_NO_PROGRESS_TIMEOUT_SECONDS,
				"workRevision":current_work_revision,
				"readinessDomains":main.get("startup_readiness_domains"),
				"loadingFailure":main.get("startup_loading_failure_result")}))
			_finish()
			return
		if Engine.get_process_frames() % 300 == 0:
			_write_progress("waiting_for_initial_main_gameplay_readiness", {
				"readinessDomains":main.get("startup_readiness_domains"),
				"loadingFailure":main.get("startup_loading_failure_result")})
		await get_tree().process_frame
	var gameplay_ready := startup_completion_observed and not startup_failure_observed \
		and String(main.get("startup_readiness_domains").get("gameplay", {}).get("status", "")) == "ready"
	_check("initial_main_gameplay_ready_without_teleport", gameplay_ready, {
		"readinessDomains":main.get("startup_readiness_domains"),
		"loadingFailure":main.get("startup_loading_failure_result")})
	if not gameplay_ready:
		_finish()
		return
	coordinator = main.get("world_static_section_coordinator") as Object
	ordinary_provider = coordinator.call("provider_for_id", OrdinaryProviderId) \
		if coordinator.has_method("provider_for_id") else null
	if not is_instance_valid(ordinary_provider):
		ordinary_provider = main.get("ordinary_static_section_provider") as Object
	_check("ordinary_provider_is_production_registered", is_instance_valid(coordinator) \
		and is_instance_valid(ordinary_provider) \
		and String(ordinary_provider.get("_world_id")) == String(coordinator.get("_world_id")), {
		"coordinator":str(coordinator), "provider":str(ordinary_provider),
		"worldId":coordinator.get("_world_id") if is_instance_valid(coordinator) else ""})
	if not is_instance_valid(coordinator) or not is_instance_valid(ordinary_provider):
		_finish()
		return
	var production_roster: Object = coordinator.get("_source_roster") as Object
	var production_domains: Array = production_roster.get("_required_provider_ids") \
		if is_instance_valid(production_roster) else []
	_check("candidate_uses_full_production_provider_roster", production_domains.size() == 4 \
		and "terrain" in production_domains and "ordinary-structures" in production_domains \
		and "blueprint_buildings" in production_domains \
		and "ecology_and_static_props" in production_domains, {
		"requiredProviderIds":production_domains})
	if not checks.candidate_uses_full_production_provider_roster.passed:
		_finish()
		return
	var target_result := await _wait_for_startup_ordinary_source()
	_check("ordinary_source_inside_initial_candidate_region_has_live_visual_collision_and_identity",
		target_result.get("status") == "ready", target_result)
	if target_result.get("status") != "ready":
		_finish()
		return
	var owner_cell := Vector2i(selected_section.x, selected_section.z)
	var source_summary := {"sourceId":ordinary_selected_source_id, "cell":[selected_cell.x, selected_cell.y, selected_cell.z],
		"blockType":selected_block_type, "section":[selected_section.x, selected_section.y, selected_section.z],
		"bodyInstanceId":selected_body.get_instance_id(),
		"collisionInstanceId":selected_collision.get_instance_id(),
		"visualIds":_visual_id_rows(selected_visuals), "ownerCell":[owner_cell.x, owner_cell.y]}
	var view_before_path := before_path
	await _capture_viewport(view_before_path)
	var receipt_wait := await _wait_for_ordinary_receipt_and_retirement(ReceiptWaitSeconds)
	_check("production_candidate_native_receipt_precedes_recipe_visual_retirement",
		receipt_wait.get("status") == "ready" and bool(receipt_wait.get("receiptCurrent", false)) \
		and bool(receipt_wait.get("legacyVisualsHiddenAfterReceipt", false)), receipt_wait)
	if receipt_wait.get("status") != "ready":
		_finish()
		return
	var body_and_collision_still_live: bool = is_instance_valid(selected_body) \
		and main.get("blocks").get(selected_cell) == selected_body \
		and is_instance_valid(selected_collision) and not selected_collision.disabled
	_check("ordinary_block_and_collision_authority_survive_render_cutover", body_and_collision_still_live, {
		"bodyInstanceId":selected_body.get_instance_id() if is_instance_valid(selected_body) else 0,
		"collisionInstanceId":selected_collision.get_instance_id() if is_instance_valid(selected_collision) else 0,
		"blockMapOwnsBody":main.get("blocks").get(selected_cell) == selected_body})
	var unload_replay := await _exercise_owner_unload_replay(owner_cell, ReceiptWaitSeconds)
	_check("section_owner_unload_replay_reinstalls_current_candidate_without_touching_collision",
		unload_replay.get("status") == "ready", unload_replay)
	if unload_replay.get("status") != "ready":
		_finish()
		return
	var removal_key := _ordinary_removal_key(ordinary_selected_source_id, selected_cell, selected_block_type)
	var player := main.get("player") as CharacterBody3D
	var camera_node := player.get("camera") as Camera3D if is_instance_valid(player) else null
	var focus := selected_body.global_position + Vector3.UP * 0.45
	var navigator = PlayerNavigator.new()
	navigator.setup(main, player, camera_node, self)
	var movement: Dictionary = await navigator.go_to_position(
		selected_body.global_position + Vector3(0.0, 0.0, 2.2),
		{"label":"ordinary_structure_section_acceptance", "stopDistance":1.8,
			"timeout":45.0, "planTimeout":15.0}, false)
	_check("player_reaches_ordinary_block_through_shared_obstacle_aware_navigator",
		bool(movement.get("ok", false)), movement)
	if not bool(movement.get("ok", false)):
		_finish()
		return
	camera_node.look_at(focus, Vector3.UP)
	await _wait_frames(3)
	var hit: Dictionary = player.view_ray(8.0)
	_check("live_player_ray_selects_ordinary_collision_owner", hit.get("collider") == selected_body, {
		"colliderId":hit.get("collider", null).get_instance_id() if hit.get("collider", null) is Object else 0,
		"expectedBodyId":selected_body.get_instance_id(), "hitPosition":hit.get("position", Vector3.INF)})
	if hit.get("collider") != selected_body:
		_finish()
		return
	var strikes := 0
	var strikes_limit := 32
	var structure_system: Object = main.get("structure_system") as Object
	var removed_value: Dictionary = structure_system.get("removed_generated_structure_blocks")
	while strikes < strikes_limit and not removed_value.has(removal_key):
		main.call("destroy_target")
		strikes += 1
		await get_tree().physics_frame
		removed_value = structure_system.get("removed_generated_structure_blocks")
	_check("public_gameplay_destroy_records_ordinary_tombstone", removed_value.has(removal_key), {
		"removalKey":removal_key, "strikes":strikes,
		"sourceRevision":(main.get("structure_system") as Object).get("ordinary_visual_revision")})
	if not removed_value.has(removal_key):
		_finish()
		return
	var saved := bool(main.call("save_world", false))
	var snapshot: Dictionary = main.call("create_save_snapshot")
	var save_system: Object = main.get("save_system") as Object
	var disk_snapshot: Dictionary = save_system.call("load", seed_text) if is_instance_valid(save_system) else {}
	var snapshot_ids: Array = snapshot.get("removedGeneratedStructureBlocks", [])
	var disk_ids: Array = disk_snapshot.get("removedGeneratedStructureBlocks", [])
	saved_slot_path = String(save_system.call("_slot_path", seed_text)) if is_instance_valid(save_system) else ""
	_check("binary_main_save_and_disk_snapshot_retain_ordinary_tombstone", saved \
		and snapshot_ids.has(removal_key) and disk_ids.has(removal_key) \
		and FileAccess.file_exists(saved_slot_path), {
		"saved":saved, "removalKey":removal_key, "snapshotHasKey":snapshot_ids.has(removal_key),
		"diskHasKey":disk_ids.has(removal_key), "savePath":saved_slot_path,
		"saveBytes":FileAccess.get_file_as_bytes(saved_slot_path).size() if FileAccess.file_exists(saved_slot_path) else 0})
	if not checks.binary_main_save_and_disk_snapshot_retain_ordinary_tombstone.passed:
		_finish()
		return
	var loaded := bool(await main.call("try_load_world_staged", true))
	_check("staged_reload_succeeds", loaded, {"failure":main.get("startup_loading_failure_result")})
	if loaded:
		var reloaded_system: Object = main.get("structure_system") as Object
		var reloaded_sources: Dictionary = reloaded_system.get("ordinary_visual_sources")
		var reloaded_source: Dictionary = reloaded_sources.get(ordinary_selected_source_id, {})
		var reloaded_expected: Dictionary = reloaded_source.get("expected", {})
		_check("reload_keeps_tombstone_and_omits_generated_block", \
			(reloaded_system.get("removed_generated_structure_blocks") as Dictionary).has(removal_key) \
			and not reloaded_expected.has(selected_cell) and not (main.get("blocks") as Dictionary).has(selected_cell), {
			"removalKey":removal_key, "sourceRecord":reloaded_source,
			"bodyStillPresent":(main.get("blocks") as Dictionary).has(selected_cell)})
	_trace("ordinary_stage4_finish", {"source":source_summary, "receipt":receipt_wait,
		"unloadReplay":unload_replay, "savePath":saved_slot_path})
	_finish()


func _wait_for_startup_ordinary_source() -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(SourceWaitSeconds * 1000.0)
	var last := {"status":"pending", "reason":"no_initial_region_ordinary_source"}
	while is_inside_tree() and Time.get_ticks_msec() < deadline:
		last = _find_startup_ordinary_source()
		if last.get("status") == "ready":
			return last
		if Engine.get_process_frames() % 300 == 0:
			_write_progress("waiting_for_startup_ordinary_source", last)
		await get_tree().physics_frame
	return last


func _find_startup_ordinary_source() -> Dictionary:
	var system: Object = main.get("structure_system") as Object
	var source_rows: Variant = system.get("ordinary_visual_sources") if is_instance_valid(system) else null
	var blocks: Variant = main.get("blocks")
	if not source_rows is Dictionary or not blocks is Dictionary:
		return {"status":"pending", "reason":"ordinary_authority_maps_missing"}
	var player: CharacterBody3D = main.get("player") as CharacterBody3D
	var spawn_position := player.global_position if is_instance_valid(player) else Vector3.INF
	var candidates: Array[Dictionary] = []
	for source_value: Variant in source_rows:
		var source_id := String(source_value)
		var source: Dictionary = source_rows[source_value]
		if not bool(source.get("completed", false)):
			continue
		var expected: Variant = source.get("expected", {})
		if not expected is Dictionary:
			continue
		for cell_value: Variant in expected:
			if not cell_value is Vector3i:
				continue
			var cell: Vector3i = cell_value
			var body: StaticBody3D = blocks.get(cell) as StaticBody3D
			if not is_instance_valid(body) or body.is_queued_for_deletion() \
					or String(expected[cell]) != String(body.get_meta("block_type", "")):
				continue
			var world_position := body.global_position
			if world_position.distance_to(spawn_position) > 8.0:
				continue
			var tool_message := String(main.call("unmet_tool_requirement_message",
				String(body.get_meta("material", "")))) if main.has_method("unmet_tool_requirement_message") else "tool_requirement_api_missing"
			if not tool_message.is_empty():
				continue
			var visuals := _ordinary_recipe_visuals(body)
			var collision := _find_enabled_collision(body)
			if visuals.is_empty() or not is_instance_valid(collision) \
					or bool(visuals[0].get_meta("ordinary_structure_section_owned", false)):
				continue
			var section := OrdinaryGrid.key_for_world_position(world_position)
			candidates.append({"distance":world_position.distance_to(spawn_position),
				"sourceId":source_id, "cell":cell, "blockType":String(expected[cell]),
				"body":body, "visuals":visuals, "collision":collision, "section":section})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a.distance) != float(b.distance): return float(a.distance) < float(b.distance)
		return String(a.sourceId) < String(b.sourceId))
	if candidates.is_empty():
		return {"status":"pending", "reason":"no_live_ordinary_source_with_legacy_visuals_in_initial_spawn_region",
			"spawnPosition":[spawn_position.x, spawn_position.y, spawn_position.z],
			"sourceCount":source_rows.size(), "blockCount":blocks.size(), "maxDistance":8.0,
			"selectionConstraint":"target must be inside original startup region and within normal interaction reach"}
	var selected: Dictionary = candidates[0]
	ordinary_selected_source_id = selected.sourceId
	selected_cell = selected.cell
	selected_block_type = selected.blockType
	selected_body = selected.body
	selected_visuals = selected.visuals
	selected_collision = selected.collision
	selected_section = selected.section
	return {"status":"ready", "spawnPosition":[spawn_position.x, spawn_position.y, spawn_position.z],
		"distanceFromSpawn":selected.distance, "sourceId":ordinary_selected_source_id,
		"cell":[selected_cell.x, selected_cell.y, selected_cell.z],
		"blockType":selected_block_type, "section":[selected_section.x, selected_section.y, selected_section.z],
		"bodyInstanceId":selected_body.get_instance_id(),
		"collisionInstanceId":selected_collision.get_instance_id(),
		"visualCount":selected_visuals.size()}


func _wait_for_ordinary_receipt_and_retirement(timeout_seconds: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var latest := {}
	while is_inside_tree() and Time.get_ticks_msec() < deadline:
		var receipt := _ordinary_receipt_for_section(selected_section)
		var visible_before_retirement := false
		var hidden := true
		for visual: MeshInstance3D in selected_visuals:
			visible_before_retirement = visible_before_retirement or visual.visible
			hidden = hidden and not visual.visible
		latest = {"section":[selected_section.x, selected_section.y, selected_section.z],
			"receipt":receipt, "receiptCurrent":bool(receipt.get("current", false)),
			"legacyVisualsVisible":visible_before_retirement, "legacyVisualsHidden":hidden,
			"visualIds":_visual_id_rows(selected_visuals)}
		if bool(receipt.get("current", false)) and hidden:
			latest["status"] = "ready"
			latest["legacyVisualsHiddenAfterReceipt"] = true
			return latest
		if bool(receipt.get("current", false)) and visible_before_retirement:
			latest["receiptCurrentButVisualsStillVisible"] = true
		if Engine.get_process_frames() % 300 == 0:
			_write_progress("waiting_for_ordinary_candidate_receipt", latest)
		await get_tree().physics_frame
	latest["status"] = "pending"
	latest["legacyVisualsHiddenAfterReceipt"] = false
	return latest


func _ordinary_receipt_for_section(section: Vector3i) -> Dictionary:
	var receipts: Variant = coordinator.get("_production_candidate_receipts")
	var receipt: Dictionary = receipts.get(section, {}) if receipts is Dictionary else {}
	var current := not receipt.is_empty() and bool(coordinator.call(
		"installed_section_receipt_is_current", section, receipt))
	var candidate_jobs: Variant = coordinator.get("_production_candidate_jobs")
	var job: Dictionary = candidate_jobs.get(section, {}) if candidate_jobs is Dictionary else {}
	var roster: Variant = coordinator.get("_source_roster")
	return {"current":current, "generation":int(receipt.get("generation", 0)),
		"contentManifestDigest":String(receipt.get("contentManifestDigest", "")),
		"censusDigest":String(receipt.get("censusDigest", "")),
		"providerCoverage":receipt.get("providerCoverage", []),
		"sourceRevision":String(receipt.get("sourceRevisions", {}).get(ordinary_selected_source_id, "")),
		"candidateStatus":String(job.get("stage", "missing")),
		"candidateManifest":String(job.get("candidate", {}).get("contentManifestDigest", "")),
		"rosterProviders":roster.get("_required_provider_ids", []) if is_instance_valid(roster) else []}


func _exercise_owner_unload_replay(owner_cell: Vector2i, timeout_seconds: float) -> Dictionary:
	var old_receipt := _ordinary_receipt_for_section(selected_section)
	var old_owner: Node3D = (main.get("static_section_render_owners") as Dictionary).get(owner_cell) as Node3D
	if not bool(old_receipt.get("current", false)) or not is_instance_valid(old_owner):
		return {"status":"blocked", "reason":"current_receipt_or_registered_native_owner_missing",
			"oldReceipt":old_receipt, "ownerValid":is_instance_valid(old_owner)}
	var old_backend_id := old_owner.get_node_or_null("ChunkRenderPacketBackend").get_instance_id() \
		if old_owner.has_node("ChunkRenderPacketBackend") else 0
	main.call("retire_static_section_render_owner", owner_cell)
	main.call("sync_static_section_render_owner_demands", {})
	await _wait_frames(2)
	main.call("sync_static_section_render_owner_demands", {owner_cell:true})
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var last := {}
	while is_inside_tree() and Time.get_ticks_msec() < deadline:
		var owner_result: Dictionary = main.call("get_static_section_render_owner", owner_cell, true)
		var current := _ordinary_receipt_for_section(selected_section)
		var body_live: bool = is_instance_valid(selected_body) and (main.get("blocks") as Dictionary).get(selected_cell) == selected_body \
			and is_instance_valid(selected_collision) and not selected_collision.disabled
		var new_owner := owner_result.get("owner") as Node3D
		var new_backend := owner_result.get("backend") as Node3D
		last = {"ownerResult":owner_result.get("status", ""), "oldOwnerId":old_owner.get_instance_id(),
			"oldBackendId":old_backend_id, "newOwnerId":new_owner.get_instance_id() if is_instance_valid(new_owner) else 0,
			"newBackendId":new_backend.get_instance_id() if is_instance_valid(new_backend) else 0,
			"receipt":current, "bodyAndCollisionLive":body_live}
		if is_instance_valid(new_owner) and is_instance_valid(new_backend) \
				and new_owner.get_instance_id() != old_owner.get_instance_id() \
				and new_backend.get_instance_id() != old_backend_id \
				and bool(current.get("current", false)) and body_live:
			return {"status":"ready", "unloadNotified":true, "reloadNotified":true,
				"oldReceipt":old_receipt, "oldOwnerId":old_owner.get_instance_id(),
				"oldBackendId":old_backend_id, "newOwnerId":new_owner.get_instance_id(),
				"newBackendId":new_backend.get_instance_id(), "replayedReceipt":current,
				"bodyAndCollisionLive":body_live}
		if Engine.get_process_frames() % 300 == 0:
			_write_progress("waiting_for_owner_unload_replay", last)
		await get_tree().physics_frame
	return {"status":"pending", "reason":"new_owner_receipt_not_replayed_before_deadline",
		"oldReceipt":old_receipt, "last":last}


func _ordinary_recipe_visuals(body: StaticBody3D) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	var pending: Array[Node] = body.get_children()
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is MeshInstance3D and node.has_meta("ordinary_structure_recipe_segment_id"):
			result.append(node as MeshInstance3D)
		pending.append_array(node.get_children())
	return result


func _visual_id_rows(visuals: Array[MeshInstance3D]) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for visual: MeshInstance3D in visuals:
		if is_instance_valid(visual):
			rows.append({"instanceId":visual.get_instance_id(), "visible":visual.visible,
				"sectionOwned":bool(visual.get_meta("ordinary_structure_section_owned", false)),
				"segmentId":String(visual.get_meta("ordinary_structure_recipe_segment_id", ""))})
	return rows


func _ordinary_removal_key(source_id: String, cell: Vector3i, block_type: String) -> String:
	var system: Object = main.get("structure_system") as Object
	return String(system.call("_ordinary_visual_block_key", source_id, cell, block_type))


func _finish() -> void:
	if finished:
		return
	finished = true
	var passed := failures.is_empty()
	var world_id := String(coordinator.get("_world_id")) if is_instance_valid(coordinator) else ""
	var report := {"schema":OrdinaryReceiptSchema, "status":"complete" if passed else "failed",
		"passed":passed, "seed":seed_text, "worldId":world_id,
		"tutorialSkipped":bool(main.get("launch_options").get("skipTutorial", false)) if is_instance_valid(main) else false,
		"checkCount":checks.size(), "checks":checks, "failures":failures, "trace":trace,
		"screenshots":{"before":before_path}, "savePath":saved_slot_path,
		"source":{"sourceId":ordinary_selected_source_id, "cell":[selected_cell.x, selected_cell.y, selected_cell.z],
			"blockType":selected_block_type, "section":[selected_section.x, selected_section.y, selected_section.z]},
		"evidenceLevel":"headed Main tutorial-free initial-spawn ordinary structure candidate receipt, section-owner unload/replay, gameplay tombstone save and staged reload",
		"doesNotProve":"The fixture proves only a short seeded route through the shared navigator, not broad natural exploration or traversal; owner unload/replay is controlled through Main retire/demand-sync hooks, not natural streaming unload. It does not prove all ordinary sources, structure kinds or seeds, visual parity, performance, or full migration acceptance."}
	var sanitized: Variant = _sanitize_report_value(report)
	var report_text := JSON.stringify(sanitized, "  ")
	var output_path := OS.get_environment("VOXEL_ORDINARY_MAIN_SECTION_REPLAY_REPORT")
	if not output_path.is_empty():
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		if file != null:
			file.store_string(report_text)
			file.close()
	_write_progress("finished", {"passed":passed, "checkCount":checks.size(), "failures":failures})
	print("Ordinary Main section replay report: ", output_path)
	var exit_code := 0 if passed else 1
	if is_instance_valid(main) and main.has_method("request_graceful_quit"):
		main.call("request_graceful_quit", exit_code)
	else:
		get_tree().quit(exit_code)
