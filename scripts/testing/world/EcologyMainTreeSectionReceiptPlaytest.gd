extends "res://scripts/testing/world/EcologyMainRetirementPlaytest.gd"

const TREE_REPORT_SCHEMA := "ecology-main-tree-section-receipt/v1"
const TREE_OBSERVATION_SECONDS := 720.0
const TREE_DISCOVERY_SECONDS := 180.0
const TREE_PROGRESS_INTERVAL_FRAMES := 300
const TREE_DISCOVERY_SCAN_INTERVAL_FRAMES := 30

var selected_tree: Dictionary = {}
var selected_sections: Array[Vector3i] = []
var selected_receipt_revision := ""
var demand_requests: Array[Dictionary] = []
var tree_failure_reason := ""
var receipt_state_before_demand: Dictionary = {}
var discovery_telemetry: Dictionary = {}
var startup_tree_compiler_progress_history: Array[Dictionary] = []
const STARTUP_TREE_COMPILER_HISTORY_LIMIT := 64


func _ready() -> void:
	run_started_msec = Time.get_ticks_msec()
	seed_text = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	report_path = OS.get_environment("VOXEL_ECOLOGY_TREE_RECEIPT_REPORT")
	progress_path = OS.get_environment("VOXEL_ECOLOGY_TREE_RECEIPT_PROGRESS")
	call_deferred("_run")


## This is a publication-lifecycle diagnostic. It observes real Main producers
## and the production coordinator/native renderer without claiming startup,
## traversal, or gameplay readiness.
func _run() -> void:
	var ready_snapshot_bucket := _tree_snapshot_status_bucket({"status":"ready"})
	var stale_snapshot_bucket := _tree_snapshot_status_bucket({"status":"stale"})
	_check("production_ready_snapshot_status_is_admitted", ready_snapshot_bucket == "ready", {
		"inputStatus":"ready", "classifiedAs":ready_snapshot_bucket})
	_check("production_stale_snapshot_status_is_rejected_separately",
		stale_snapshot_bucket == "stale", {
		"inputStatus":"stale", "classifiedAs":stale_snapshot_bucket})
	if not checks.production_ready_snapshot_status_is_admitted.passed \
		or not checks.production_stale_snapshot_status_is_rejected_separately.passed:
		_finish()
		return
	_check("fixed_seed_and_tutorial_skipped", seed_text == "ecology-main-retirement-stage5" \
		and OS.get_environment("VOXEL_PLAYTEST") == "1", {
		"seed":seed_text, "playtest":OS.get_environment("VOXEL_PLAYTEST"),
		"userArguments":OS.get_cmdline_user_args()})
	if not checks.fixed_seed_and_tutorial_skipped.passed:
		_finish()
		return
	main = MainScene.instantiate() as Node3D
	if not is_instance_valid(main):
		_fail("production_main_instantiated", "Main.tscn failed to instantiate")
		_finish()
		return
	if main.has_signal("startup_loading_completed"):
		main.connect("startup_loading_completed", Callable(self, "_on_main_startup_completed"))
	if main.has_signal("startup_loading_failed"):
		main.connect("startup_loading_failed", Callable(self, "_on_main_startup_failed"))
	add_child(main)
	provider = main.get("ecology_static_section_provider") as Object
	coordinator = main.get("world_static_section_coordinator") as Object
	player = main.get("player") as CharacterBody3D
	camera = player.get("camera") as Camera3D if is_instance_valid(player) else null
	var launch_options: Dictionary = main.get("launch_options")
	_check("production_main_skips_tutorial", bool(launch_options.get("skipTutorial", false)),
		{"launchOptions":launch_options})
	_write_progress("main_running_targeted_tree_search", _startup_status())
	var discovery := await _wait_for_cross_section_tree()
	if discovery.get("status") != "ready":
		discovery_telemetry = discovery.get("scanTelemetry", {})
		_fail("real_compiled_cross_section_tree_found", JSON.stringify(discovery))
		_finish()
		return
	selected_tree = discovery
	discovery_telemetry = discovery.get("scanTelemetry", {})
	selected_sections.assign(discovery.get("sections", []))
	selected_receipt_revision = String(discovery.get("sourceRevision", ""))
	var pending_tree_telemetry := _main_pending_tree_publication_telemetry()
	var pending_rows: Array = pending_tree_telemetry.get("rows", [])
	for pending_row_value: Variant in pending_rows:
		if not pending_row_value is Dictionary:
			continue
		var pending_row: Dictionary = pending_row_value
		if String(pending_row.get("candidateId", "")) \
				== String(discovery.get("propId", "")):
			selected_tree["mainPendingTreeTelemetry"] = \
				pending_row.duplicate(true)
			break
	var selected_pending_tree: Dictionary = selected_tree.get("mainPendingTreeTelemetry", {})
	var telemetry_check := pending_tree_telemetry.duplicate(true)
	telemetry_check["selectedTreePropId"] = String(discovery.get("propId", ""))
	telemetry_check["selectedPendingCandidateId"] = String(
		selected_pending_tree.get("candidateId", ""))
	_check("main_pending_tree_ids_join_current_source_queue_receipt_telemetry",
		pending_tree_telemetry.get("status", "") == "available" \
		and String(selected_pending_tree.get("candidateId", "")) \
			== String(discovery.get("propId", "")) \
		and int(pending_tree_telemetry.get("reportedPendingCount", -1)) == pending_rows.size() \
		and int(pending_tree_telemetry.get("completeJoinCount", -1)) == pending_rows.size() \
		and not bool(pending_tree_telemetry.get("capped", true)) \
		and not bool(pending_tree_telemetry.get("rowsTruncated", true)),
		telemetry_check)
	if not checks.main_pending_tree_ids_join_current_source_queue_receipt_telemetry.passed:
		_finish()
		return
	_check("real_compiled_tree_has_multiple_owned_sections", selected_sections.size() >= 2, {
		"sourceId":discovery.get("sourceId", ""),
		"propId":discovery.get("propId", ""),
		"artifactGeneration":discovery.get("artifactGeneration", 0),
		"sourceRevision":selected_receipt_revision,
		"ownedSections":_sections_to_json(selected_sections),
		"sectionProof":"TreePublicationQueue compiled source manifest"})
	var body := discovery.get("body") as StaticBody3D
	var collision := discovery.get("collision") as CollisionShape3D
	var legacy_visual := discovery.get("legacyVisual") as Node3D
	_check("legacy_tree_visual_and_same_gameplay_owner_live_before_install",
		is_instance_valid(body) and is_instance_valid(collision) \
		and collision.get_parent() == body and not collision.disabled \
		and is_instance_valid(legacy_visual) and legacy_visual.is_visible_in_tree() \
		and String(body.get_meta("tree_visual_state", "")) == "published" \
		and String(body.get_meta("visual_source", "")) == "procedural_tree_recipe", {
		"bodyInstanceId":int(discovery.get("bodyInstanceId", 0)),
		"collisionInstanceId":int(discovery.get("collisionInstanceId", 0)),
		"visualState":body.get_meta("tree_visual_state", "") if is_instance_valid(body) else "",
		"visualSource":body.get_meta("visual_source", "") if is_instance_valid(body) else "",
		"legacyVisualPresent":is_instance_valid(legacy_visual)})
	if not checks.legacy_tree_visual_and_same_gameplay_owner_live_before_install.passed:
		_finish()
		return
	var initial_census := await _wait_for_tree_census(discovery)
	_check("production_roster_census_contains_exact_tree_revision",
		initial_census.get("status") == "complete" \
		and _census_covers_tree(initial_census, discovery, selected_sections),
		_census_summary(initial_census, discovery))
	if not checks.production_roster_census_contains_exact_tree_revision.passed:
		_finish()
		return
	# The complete census wait yields across physics frames. Revalidate the same
	# legacy representation immediately before capturing receipts and replaying
	# demand, so discovery-time visibility cannot be mistaken for retention.
	var pre_demand_body := discovery.get("body") as StaticBody3D
	var pre_demand_collision := discovery.get("collision") as CollisionShape3D
	var pre_demand_visual := discovery.get("legacyVisual") as Node3D
	var pre_demand_visual_live := is_instance_valid(pre_demand_body) \
		and is_instance_valid(pre_demand_collision) \
		and pre_demand_body.get_instance_id() == int(discovery.get("bodyInstanceId", 0)) \
		and pre_demand_collision.get_instance_id() == int(discovery.get("collisionInstanceId", 0)) \
		and pre_demand_collision.get_parent() == pre_demand_body \
		and not pre_demand_collision.disabled \
		and is_instance_valid(pre_demand_visual) \
		and pre_demand_visual.is_visible_in_tree() \
		and pre_demand_body.get_node_or_null("GeneratedTreeVisual") == pre_demand_visual \
		and String(pre_demand_body.get_meta("tree_visual_state", "")) == "published"
	_check("same_legacy_visual_and_gameplay_owner_still_live_immediately_before_demand",
		pre_demand_visual_live, {
		"bodyInstanceId":pre_demand_body.get_instance_id() \
			if is_instance_valid(pre_demand_body) else 0,
		"expectedBodyInstanceId":int(discovery.get("bodyInstanceId", 0)),
		"collisionInstanceId":pre_demand_collision.get_instance_id() \
			if is_instance_valid(pre_demand_collision) else 0,
		"expectedCollisionInstanceId":int(discovery.get("collisionInstanceId", 0)),
		"visualInstanceId":pre_demand_visual.get_instance_id() \
			if is_instance_valid(pre_demand_visual) else 0,
		"visualVisible":is_instance_valid(pre_demand_visual) \
			and pre_demand_visual.is_visible_in_tree(),
		"visualState":String(pre_demand_body.get_meta("tree_visual_state", "")) \
			if is_instance_valid(pre_demand_body) else "body_missing"})
	if not pre_demand_visual_live:
		_trace("pre_demand_legacy_visual_revalidation_failed", {
			"tree":_tree_identity_summary(discovery),
			"receiptState":_receipt_rows_cover_tree(discovery, selected_sections)})
		_finish()
		return
	receipt_state_before_demand = _receipt_rows_cover_tree(discovery,
		selected_sections)
	_trace("tree_receipt_state_before_demand_replay", receipt_state_before_demand)
	_write_progress("tree_receipt_state_before_demand_replay", {
		"tree":_tree_identity_summary(discovery),
		"receiptState":receipt_state_before_demand,
		"legacyVisualVisible":pre_demand_visual.is_visible_in_tree(),
		"bodyVisualState":String(pre_demand_body.get_meta("tree_visual_state", ""))})
	var demand_result := await _wait_for_real_sections(selected_sections)
	_check("exact_resident_sections_requested_through_main_terrain_callback",
		demand_result.get("status") == "requested", demand_result)
	if not checks.exact_resident_sections_requested_through_main_terrain_callback.passed:
		_finish()
		return
	var receipt_wait := await _wait_for_tree_receipt_closure(discovery,
		selected_sections, receipt_state_before_demand, TREE_OBSERVATION_SECONDS)
	_trace("tree_section_receipt_closure", receipt_wait)
	_check("all_owning_sections_have_current_native_receipt_for_exact_tree_revision",
		receipt_wait.get("status") == "ready" \
		and bool(receipt_wait.get("allReceiptsCurrent", false)) \
		and bool(receipt_wait.get("exactSourceRevisionInEveryReceipt", false)) \
		and bool(receipt_wait.get("providerCoverageCurrent", false)), receipt_wait)
	_check("old_tree_visual_retained_until_last_owning_receipt",
		bool(receipt_wait.get("orderingObserved", false)) \
		and bool(receipt_wait.get("legacyVisualRetainedUntilReceiptClosure", false)),
		receipt_wait)
	_check("replacement_ordering_observed_from_pending_partial_to_full_closure",
		bool(receipt_wait.get("orderingObserved", false)), {
		"reason":String(receipt_wait.get("orderingObservationReason", "")),
		"entryCurrentReceiptCount":int(receipt_state_before_demand.get(
			"currentReceiptCount", 0)),
		"requiredReceiptCount":selected_sections.size(),
		"postDemandPendingCheckpoint":receipt_wait.get("postDemandPendingCheckpoint", {}),
		"postDemandPartialCheckpoint":receipt_wait.get("postDemandPartialCheckpoint", {}),
		"postDemandPartialCheckpointValid":bool(receipt_wait.get(
			"postDemandPartialCheckpointValid", false)),
		"retirementTransition":receipt_wait.get("retirementTransition", {})})
	var retirement_transition: Dictionary = receipt_wait.get("retirementTransition", {})
	_check("tree_visual_state_transition_occurs_after_receipt_closure",
		not retirement_transition.is_empty() \
		and bool(retirement_transition.get("receiptsClosedAtTransition", false)) \
		and int(retirement_transition.get("currentReceiptCount", 0)) == selected_sections.size(),
		retirement_transition)
	if not checks.all_owning_sections_have_current_native_receipt_for_exact_tree_revision.passed:
		_finish()
		return
	var final_body := discovery.get("body") as StaticBody3D
	var final_collision := discovery.get("collision") as CollisionShape3D
	var same_body: bool = is_instance_valid(final_body) \
		and final_body.get_instance_id() == int(discovery.get("bodyInstanceId", 0)) \
		and final_body.get_parent() == discovery.get("chunk")
	var same_collision: bool = is_instance_valid(final_collision) \
		and final_collision.get_instance_id() == int(discovery.get("collisionInstanceId", 0)) \
		and final_collision.get_parent() == final_body and not final_collision.disabled
	var retired: bool = same_body \
		and String(final_body.get_meta("tree_visual_state", "")) == "section_owned" \
		and String(final_body.get_meta("visual_source", "")) == "chunk_owned_static_section" \
		and final_body.get_node_or_null("GeneratedTreeVisual") == null
	_check("same_tree_body_and_enabled_collider_survive_visual_retirement",
		same_body and same_collision and retired, {
		"sameBody":same_body, "sameCollision":same_collision,
		"sectionOwnedState":String(final_body.get_meta("tree_visual_state", "")) \
			if is_instance_valid(final_body) else "missing",
		"visualSource":String(final_body.get_meta("visual_source", "")) \
			if is_instance_valid(final_body) else "missing",
		"legacyVisualGone":final_body.get_node_or_null("GeneratedTreeVisual") == null \
			if is_instance_valid(final_body) else false,
		"bodyInstanceId":final_body.get_instance_id() if is_instance_valid(final_body) else 0,
		"collisionInstanceId":final_collision.get_instance_id() \
			if is_instance_valid(final_collision) else 0,
		"sourceId":discovery.get("sourceId", ""),
		"propId":discovery.get("propId", "")})
	var final_census := _current_tree_census(discovery)
	_check("current_native_receipts_still_match_post_retirement_census",
		final_census.get("status") == "complete" \
		and _census_covers_tree(final_census, discovery, selected_sections) \
		and _receipt_rows_cover_tree(discovery, selected_sections).get("complete", false), {
		"census":_census_summary(final_census, discovery),
		"receipts":_receipt_rows_cover_tree(discovery, selected_sections)})
	_finish()


func _wait_for_cross_section_tree() -> Dictionary:
	var last := {"status":"pending", "reason":"tree_queue_not_ready"}
	var last_scan_frame := -TREE_DISCOVERY_SCAN_INTERVAL_FRAMES
	var discovery_deadline_msec := Time.get_ticks_msec() \
		+ int(TREE_DISCOVERY_SECONDS * 1000.0)
	while is_inside_tree() and is_instance_valid(main) and main.is_inside_tree():
		var provider_value: Variant = main.get("ecology_static_section_provider")
		var coordinator_value: Variant = main.get("world_static_section_coordinator")
		var queue_value: Variant = main.get("tree_publication_queue")
		if is_instance_valid(provider_value) and is_instance_valid(coordinator_value) \
			and is_instance_valid(queue_value) \
			and provider_value.has_method("_current_tree_publications"):
			var frame := Engine.get_process_frames()
			if frame - last_scan_frame >= TREE_DISCOVERY_SCAN_INTERVAL_FRAMES:
				last = _find_cross_section_tree(provider_value, queue_value)
				last_scan_frame = frame
				if last.get("status") == "ready":
					return last
			if startup_failure_observed:
				# Preserve one final deterministic census after startup reports its
				# terminal failure, then stop this discovery diagnostic instead of
				# burning the later receipt observation window without a target.
				last = _find_cross_section_tree(provider_value, queue_value)
				if last.get("status") == "ready":
					return last
				last["diagnosticStopReason"] = "global_startup_failed_before_tree_selection"
				return {"status":"pending",
					"reason":"global_startup_failed_before_tree_selection",
					"scanTelemetry":last.get("scanTelemetry", {}),
					"lastDiscovery":last, "startup":_startup_status()}
		if startup_completion_observed \
			and String(_main_pending_tree_candidate_ids().get("status", "")) != "available":
			return {"status":"pending",
				"reason":"startup_completed_without_pending_tree_publication_telemetry",
				"scanTelemetry":last.get("scanTelemetry", {}),
				"lastDiscovery":last, "startup":_startup_status()}
		if Time.get_ticks_msec() >= discovery_deadline_msec:
			return {"status":"pending", "reason":"tree_discovery_watchdog_timeout",
				"scanTelemetry":last.get("scanTelemetry", {}),
				"lastDiscovery":last, "startup":_startup_status(),
				"discoveryTimeoutSeconds":TREE_DISCOVERY_SECONDS}
		if Engine.get_process_frames() % TREE_PROGRESS_INTERVAL_FRAMES == 0:
			_write_progress("waiting_for_real_compiled_cross_section_tree", {
				"discovery":last, "startup":_startup_status()})
		await get_tree().physics_frame
	return {"status":"pending", "reason":"main_scene_stopped_during_tree_discovery",
		"lastDiscovery":last, "startup":_startup_status()}


func _find_cross_section_tree(provider_value: Object, queue_value: Object) -> Dictionary:
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary:
		return {"status":"pending", "reason":"main_chunk_map_not_ready"}
	var publications: Dictionary = provider_value.call("_current_tree_publications", main)
	var fully_receipted_fallback: Dictionary = {}
	var compiled_queue_records: Variant = queue_value.get("compiled_tree_section_records")
	var compiled_queue_record_count: int = compiled_queue_records.size() \
		if compiled_queue_records is Array else 0
	var main_pending_telemetry := _main_pending_tree_candidate_ids()
	var main_pending_ids: Array = main_pending_telemetry.get("candidateIds", [])
	var main_pending_by_candidate: Dictionary = {}
	for main_pending_value: Variant in main_pending_ids:
		var main_pending_id := String(main_pending_value)
		if not main_pending_id.is_empty():
			main_pending_by_candidate[main_pending_id] = true
	var metrics := {"residentChunkCount":chunks_value.size(), "readySnapshotChunkCount":0,
		"incompleteSnapshotChunkCount":0, "snapshotCandidateCount":0,
		"publicationCount":publications.size(),
		"compiledQueueRecordCount":compiled_queue_record_count,
		"mainPendingTreeCandidateIds":main_pending_telemetry.get("candidateIds", []),
		"mainPendingTreeTelemetryStatus":main_pending_telemetry.get("status", "missing"),
		"mainPendingTreeReportedCount":main_pending_telemetry.get(
			"reportedPendingCount", 0),
		"nonTargetTreeCandidateCount":0,
		"treeCandidateCount":0, "compiledTreeCandidateCount":0,
		"snapshotStatusCounts":{"ready":0, "stale":0, "missing":0,
			"pending":0, "other":0},
		"snapshotReasonCounts":{}, "snapshotSamples":[],
		"sectionCardinality":{"0":0, "1":0, "2plus":0},
		"rejections":{}, "candidateProgress":[], "firstMultiSectionCandidate":"",
		"acceptedCandidateCount":0, "fullyReceiptedCandidateCount":0,
		"scanFrame":Engine.get_process_frames(),
		"scanElapsedMsec":Time.get_ticks_msec() - run_started_msec}
	var chunk_keys: Array[Vector2i] = []
	for chunk_key_value: Variant in chunks_value:
		if chunk_key_value is Vector2i:
			chunk_keys.append(chunk_key_value)
	chunk_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	for chunk_key: Vector2i in chunk_keys:
		var chunk := chunks_value[chunk_key] as Node3D
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			metrics.incompleteSnapshotChunkCount = int(metrics.incompleteSnapshotChunkCount) + 1
			_record_snapshot_scan_state(metrics, chunk_key, null, "missing",
				"chunk_owner_missing", 0, "", "")
			continue
		var snapshot_value: Variant = chunk.get_meta("static_ecology_source_value_snapshot", {})
		var snapshot_state := _tree_snapshot_status_bucket(snapshot_value)
		var snapshot_reason := ""
		var snapshot_owner_id := 0
		var snapshot_revision := ""
		var expected_revision := String(main.call("_ecology_chunk_source_revision", chunk_key)) \
			if main.has_method("_ecology_chunk_source_revision") else ""
		if snapshot_value is Dictionary:
			snapshot_reason = String(snapshot_value.get("reason",
				snapshot_value.get("statusReason", "")))
			snapshot_owner_id = int(snapshot_value.get("producerOwnerInstanceId", 0))
			snapshot_revision = String(snapshot_value.get("sourceRevision", ""))
		if snapshot_state == "ready" and snapshot_owner_id != chunk.get_instance_id():
			snapshot_state = "stale"
			snapshot_reason = "snapshot_producer_owner_mismatch"
		elif snapshot_state == "ready" and not expected_revision.is_empty() \
			and snapshot_revision != expected_revision:
			snapshot_state = "stale"
			snapshot_reason = "snapshot_source_revision_mismatch"
		if snapshot_reason.is_empty():
			snapshot_reason = snapshot_state + "_snapshot"
		_record_snapshot_scan_state(metrics, chunk_key, chunk, snapshot_state,
			snapshot_reason, snapshot_owner_id, snapshot_revision, expected_revision)
		if snapshot_state != "ready":
			metrics.incompleteSnapshotChunkCount = int(metrics.incompleteSnapshotChunkCount) + 1
			continue
		metrics.readySnapshotChunkCount = int(metrics.readySnapshotChunkCount) + 1
		var candidates: Array[Dictionary] = []
		for candidate_value: Variant in snapshot_value.get("candidates", []):
			if candidate_value is Dictionary:
				candidates.append(candidate_value)
		metrics.snapshotCandidateCount = int(metrics.snapshotCandidateCount) + candidates.size()
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_source := String(a.get("sourceId", ""))
			var b_source := String(b.get("sourceId", ""))
			if a_source != b_source: return a_source < b_source
			return String(a.get("propId", "")) < String(b.get("propId", "")))
		for candidate: Dictionary in candidates:
			if String(candidate.get("kind", "")) != "trees_foliage":
				continue
			metrics.treeCandidateCount = int(metrics.treeCandidateCount) + 1
			var prop_id := String(candidate.get("propId", ""))
			var source_id := String(candidate.get("sourceId", ""))
			if not main_pending_by_candidate.has(prop_id):
				metrics.nonTargetTreeCandidateCount = int(
					metrics.nonTargetTreeCandidateCount) + 1
				continue
			var candidate_key := source_id + "|" + prop_id
			var rejection := ""
			var publication_value: Variant = publications.get(prop_id, {})
			if prop_id.is_empty() or source_id.is_empty():
				rejection = "candidate_source_or_prop_id_missing"
			elif not publication_value is Dictionary or publication_value.is_empty():
				rejection = "no_current_publication_for_prop"
			elif not publication_value.has("compiled"):
				rejection = "publication_not_compiled"
			if not rejection.is_empty():
				_record_tree_candidate_progress(metrics, candidate, rejection)
				continue
			var publication: Dictionary = publication_value
			metrics.compiledTreeCandidateCount = int(metrics.compiledTreeCandidateCount) + 1
			var body := publication.get("body") as StaticBody3D
			if not is_instance_valid(body) or body.get_parent() != chunk \
				or String(body.get_meta("prop_id", "")) != prop_id \
				or String(body.get_meta("static_ecology_source_id", "")) != source_id \
				or not body.is_in_group("generated_tree_trunks") \
				or bool(body.get_meta("tree_publication_cancelled", false)):
				_record_tree_candidate_progress(metrics, candidate,
					"compiled_body_owner_or_source_mismatch")
				continue
			var record: Dictionary = publication.get("record", {})
			if int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
				or bool(record.get("rebuildPending", false)):
				_record_tree_candidate_progress(metrics, candidate,
					"compiled_record_stale_or_rebuild_pending")
				continue
			var sections_value: Variant = provider_value.call(
				"_tree_census_section_keys", publication)
			if not sections_value is Array:
				_record_tree_candidate_progress(metrics, candidate,
					"compiler_section_manifest_not_array")
				continue
			var sections: Array[Vector3i] = []
			for section_value: Variant in sections_value:
				if section_value is Vector3i and section_value not in sections:
					sections.append(section_value)
			var cardinality_key := "0" if sections.is_empty() else ("1" \
				if sections.size() == 1 else "2plus")
			metrics.sectionCardinality[cardinality_key] = int(
				metrics.sectionCardinality.get(cardinality_key, 0)) + 1
			if sections.size() < 2:
				_record_tree_candidate_progress(metrics, candidate,
					"compiler_manifest_owns_fewer_than_two_sections", sections)
				continue
			sections.sort_custom(_section_before)
			var source_revision := String(provider_value.call(
				"_tree_census_source_revision", candidate, publication))
			if source_revision.is_empty():
				_record_tree_candidate_progress(metrics, candidate,
					"provider_source_revision_unavailable", sections)
				continue
			var collision := _enabled_tree_collider(body)
			var visual := body.get_node_or_null("GeneratedTreeVisual") as Node3D
			if not is_instance_valid(collision) or not is_instance_valid(visual) \
				or not visual.is_visible_in_tree() \
				or String(body.get_meta("tree_visual_state", "")) != "published" \
				or String(body.get_meta("visual_source", "")) != "procedural_tree_recipe":
				_record_tree_candidate_progress(metrics, candidate,
					"legacy_visual_or_enabled_trunk_collider_missing", sections)
				continue
			var queue_record: Dictionary = queue_value.call(
				"compiled_tree_section_record_for_body", body)
			if queue_record.is_empty() \
				or int(queue_record.get("artifactGeneration", 0)) \
					!= int(publication.get("compiledRecord", {}).get("artifactGeneration", 0)):
				_record_tree_candidate_progress(metrics, candidate,
					"queue_compiled_record_missing_or_generation_mismatch", sections)
				continue
			# The queue's outer record binds recipe contentRevision; its compiled
			# source manifest carries the compiler sourceRevision. Require that
			# carried revision to match the ecology provider's computed revision.
			var compiled_output: Variant = queue_record.get("compiled", {})
			var compiled_sources: Variant = compiled_output.get("sources", []) \
				if compiled_output is Dictionary else []
			var queue_source_revision := ""
			if compiled_sources is Array:
				for source_manifest_value: Variant in compiled_sources:
					if source_manifest_value is Dictionary \
						and String(source_manifest_value.get("sourceId", "")) == source_id:
						queue_source_revision = String(source_manifest_value.get(
							"sourceRevision", ""))
						break
			if queue_source_revision.is_empty():
				_record_tree_candidate_progress(metrics, candidate,
					"queue_source_manifest_revision_missing", sections)
				continue
			if queue_source_revision != source_revision:
				_record_tree_candidate_progress(metrics, candidate,
					"queue_provider_source_revision_mismatch", sections)
				continue
			metrics.acceptedCandidateCount = int(metrics.acceptedCandidateCount) + 1
			if String(metrics.firstMultiSectionCandidate).is_empty():
				metrics.firstMultiSectionCandidate = candidate_key
			_record_tree_candidate_progress(metrics, candidate,
				"multi_section_candidate_selected_pending_receipts", sections, false)
			var found := {"status":"ready", "chunk":chunk, "chunkKey":chunk_key,
				"candidate":candidate, "publication":publication,
				"body":body, "bodyInstanceId":body.get_instance_id(),
				"collision":collision, "collisionInstanceId":collision.get_instance_id(),
				"legacyVisual":visual, "sourceId":source_id, "propId":prop_id,
				"sourceRevision":source_revision, "artifactGeneration":int(
					queue_record.get("artifactGeneration", 0)),
				"queueSourceRevision":queue_source_revision,
				"sections":sections,
				"compiledEvidence":"TreePublicationQueue compiled source record"}
			var entry_receipts := _receipt_rows_cover_tree(found, sections)
			found["entryReceiptState"] = entry_receipts
			found["scanTelemetry"] = metrics.duplicate(true)
			if not bool(entry_receipts.get("complete", false)):
				return found
			metrics.fullyReceiptedCandidateCount = int(
				metrics.fullyReceiptedCandidateCount) + 1
			_record_tree_candidate_progress(metrics, candidate,
				"multi_section_candidate_already_fully_receipted", sections, false)
			found["scanTelemetry"] = metrics.duplicate(true)
			if fully_receipted_fallback.is_empty():
				fully_receipted_fallback = found
	if not fully_receipted_fallback.is_empty():
		fully_receipted_fallback["scanTelemetry"] = metrics.duplicate(true)
		return fully_receipted_fallback
	return {"status":"pending",
		"reason":"no_live_published_compiled_tree_spans_main_pending_sections",
		"targetCandidateIds":main_pending_telemetry.get("candidateIds", []),
		"pendingTreeTelemetryStatus":main_pending_telemetry.get("status", "missing"),
		"residentChunkCount":chunks_value.size(), "publishedTreeCount":publications.size(),
		"scanTelemetry":metrics}


func _record_tree_candidate_progress(metrics: Dictionary, candidate: Dictionary,
		stage: String, sections: Array[Vector3i] = [], rejection: bool = true) -> void:
	var rejections: Dictionary = metrics.get("rejections", {})
	if rejection:
		rejections[stage] = int(rejections.get(stage, 0)) + 1
	metrics["rejections"] = rejections
	var progress: Array = metrics.get("candidateProgress", [])
	if progress.size() < 12:
		progress.append({"sourceId":String(candidate.get("sourceId", "")),
			"propId":String(candidate.get("propId", "")), "stage":stage,
			"sectionCount":sections.size(), "sections":_sections_to_json(sections)})
	metrics["candidateProgress"] = progress


func _tree_snapshot_status_bucket(snapshot_value: Variant) -> String:
	if not snapshot_value is Dictionary:
		return "missing"
	var status := String(snapshot_value.get("status", ""))
	if status == "ready":
		return "ready"
	if status == "stale":
		return "stale"
	if status in ["pending", "in_progress"]:
		return "pending"
	return "missing" if status.is_empty() else "other"


func _record_snapshot_scan_state(metrics: Dictionary, chunk_key: Vector2i,
		chunk: Node3D, state: String, reason: String, snapshot_owner_id: int,
		snapshot_revision: String, expected_revision: String) -> void:
	var status_counts: Dictionary = metrics.get("snapshotStatusCounts", {})
	status_counts[state] = int(status_counts.get(state, 0)) + 1
	metrics["snapshotStatusCounts"] = status_counts
	var reason_key := state + ":" + reason
	var reason_counts: Dictionary = metrics.get("snapshotReasonCounts", {})
	reason_counts[reason_key] = int(reason_counts.get(reason_key, 0)) + 1
	metrics["snapshotReasonCounts"] = reason_counts
	var samples: Array = metrics.get("snapshotSamples", [])
	if samples.size() < 12:
		samples.append({"chunkKey":_vec2_to_json(chunk_key), "status":state,
			"reason":reason, "chunkOwnerInstanceId":chunk.get_instance_id() \
				if is_instance_valid(chunk) else 0,
			"snapshotProducerOwnerInstanceId":snapshot_owner_id,
			"snapshotSourceRevision":snapshot_revision,
			"expectedSourceRevision":expected_revision})
	metrics["snapshotSamples"] = samples


func _current_tree_census(tree: Dictionary) -> Dictionary:
	var coordinator_value: Variant = main.get("world_static_section_coordinator")
	if not is_instance_valid(coordinator_value):
		return {"status":"pending", "reason":"production_coordinator_unavailable"}
	return coordinator_value.call("capture_authoritative_source_census",
		tree.get("sections", []))


func _wait_for_tree_census(tree: Dictionary) -> Dictionary:
	var last := {"status":"pending", "reason":"tree_census_not_attempted"}
	while is_inside_tree() and is_instance_valid(main) and main.is_inside_tree():
		last = _current_tree_census(tree)
		if _census_covers_tree(last, tree, tree.get("sections", [])):
			return last
		if Engine.get_process_frames() % TREE_PROGRESS_INTERVAL_FRAMES == 0:
			_write_progress("waiting_for_complete_tree_source_census", {
				"census":_census_summary(last, tree), "startup":_startup_status()})
		await get_tree().physics_frame
	return last


func _census_covers_tree(census: Dictionary, tree: Dictionary,
		sections: Array[Vector3i]) -> bool:
	var provider_ids: Variant = census.get("sourceProviderIds", null)
	var revisions: Variant = census.get("sourceRevisions", null)
	var expected: Variant = census.get("expectedContributorsBySection", null)
	if census.get("status") != "complete" or not provider_ids is Dictionary \
		or not revisions is Dictionary or not expected is Dictionary:
		return false
	var source_id := String(tree.get("sourceId", ""))
	if String(provider_ids.get(source_id, "")) != PROVIDER_ID \
		or String(revisions.get(source_id, "")) != String(tree.get("sourceRevision", "")):
		return false
	for section: Vector3i in sections:
		var ids: Variant = expected.get(section, null)
		if not ids is Array or not ids.has(source_id):
			return false
	return true


func _request_real_sections(sections: Array[Vector3i]) -> Dictionary:
	var runtime: Variant = main.get("voxel_terrain_runtime")
	if not is_instance_valid(runtime):
		return {"status":"pending", "reason":"production_terrain_runtime_unavailable"}
	var published: Variant = runtime.get("published_mesh_blocks")
	var revisions: Variant = runtime.get("mesh_block_revisions")
	if not published is Dictionary or not revisions is Dictionary:
		return {"status":"pending", "reason":"production_terrain_mesh_revisions_unavailable"}
	if not main.has_method("on_visible_terrain_mesh_section_revision_changed"):
		return {"status":"failed", "reason":"Main terrain visibility callback missing"}
	var requested: Array[Dictionary] = []
	var revision_by_section: Dictionary = {}
	for section: Vector3i in sections:
		if not published.has(section):
			return {"status":"pending", "reason":"tree_section_has_no_resident_terrain_mesh",
				"section":_section_to_json(section)}
		var revision := int(revisions.get(section, 0))
		if revision <= 0:
			return {"status":"pending", "reason":"tree_section_terrain_revision_invalid",
				"section":_section_to_json(section), "revision":revision}
		revision_by_section[section] = revision
	for section: Vector3i in sections:
		var revision := int(revision_by_section[section])
		# Replay the real terrain-mesh publication callback for this exact resident
		# section. This is a section-publication lifecycle diagnostic, not traversal.
		main.call("on_visible_terrain_mesh_section_revision_changed", section, revision)
		requested.append({"section":_section_to_json(section), "terrainRevision":revision,
			"callback":"MainRuntimeTools.on_visible_terrain_mesh_section_revision_changed"})
	demand_requests = requested
	return {"status":"requested", "mode":"publication_lifecycle_diagnostic",
		"notTraversalOrGameplayAcceptance":true, "requests":requested}


func _wait_for_real_sections(sections: Array[Vector3i]) -> Dictionary:
	var last := {"status":"pending", "reason":"terrain_sections_not_attempted"}
	while is_inside_tree() and is_instance_valid(main) and main.is_inside_tree():
		last = _request_real_sections(sections)
		if last.get("status") != "pending":
			return last
		if Engine.get_process_frames() % TREE_PROGRESS_INTERVAL_FRAMES == 0:
			_write_progress("waiting_for_resident_tree_section_terrain", {
				"result":last, "tree":_tree_identity_summary(selected_tree),
				"startup":_startup_status()})
		await get_tree().physics_frame
	return last


func _wait_for_tree_receipt_closure(tree: Dictionary,
		sections: Array[Vector3i], entry_receipt_state: Dictionary,
		observation_seconds: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(observation_seconds * 1000.0)
	var latest := _receipt_rows_cover_tree(tree, sections)
	var post_demand_pending_checkpoint: Dictionary = {}
	var post_demand_partial_checkpoint: Dictionary = {}
	var retirement_transition: Dictionary = {}
	var visual_retained_until_closure := false
	var entry_was_incomplete := not bool(entry_receipt_state.get("complete", false))
	var previous_body_state := "published"
	while is_inside_tree() and Time.get_ticks_msec() < deadline:
		var body := tree.get("body") as StaticBody3D
		var collision := tree.get("collision") as CollisionShape3D
		var legacy := tree.get("legacyVisual") as Node3D
		latest = _receipt_rows_cover_tree(tree, sections)
		var receipts_closed := bool(latest.get("complete", false))
		var same_body: bool = is_instance_valid(body) \
			and body.get_instance_id() == int(tree.get("bodyInstanceId", 0)) \
			and body.get_parent() == tree.get("chunk")
		var same_collider: bool = is_instance_valid(collision) \
			and collision.get_instance_id() == int(tree.get("collisionInstanceId", 0)) \
			and collision.get_parent() == body and not collision.disabled
		var old_visual_live: bool = same_body and same_collider \
			and is_instance_valid(legacy) \
			and legacy.is_visible_in_tree() \
			and body.get_node_or_null("GeneratedTreeVisual") == legacy \
			and String(body.get_meta("tree_visual_state", "")) == "published"
		var current_receipt_count := int(latest.get("currentReceiptCount", 0))
		if not receipts_closed and old_visual_live:
			visual_retained_until_closure = true
			if post_demand_pending_checkpoint.is_empty():
				post_demand_pending_checkpoint = _receipt_checkpoint("after_demand_pending",
					latest, tree, body, collision, legacy)
		if current_receipt_count > 0 and current_receipt_count < sections.size() \
				and not receipts_closed and old_visual_live \
				and post_demand_partial_checkpoint.is_empty():
			post_demand_partial_checkpoint = _receipt_checkpoint("after_demand_partial",
				latest, tree, body, collision, legacy)
		if not receipts_closed and not old_visual_live:
			return {"status":"failed", "reason":"tree_visual_retired_before_all_current_receipts",
				"allReceiptsCurrent":false,
				"legacyVisualRetainedUntilReceiptClosure":false,
				"orderingObserved":entry_was_incomplete \
					and not post_demand_pending_checkpoint.is_empty(),
				"orderingObservationReason":"visual_hidden_while_receipts_pending",
				"entryReceiptState":entry_receipt_state,
				"postDemandPendingCheckpoint":post_demand_pending_checkpoint,
				"postDemandPartialCheckpoint":post_demand_partial_checkpoint,
				"receipts":latest, "bodyState":String(body.get_meta(
					"tree_visual_state", "")) if is_instance_valid(body) else "body_missing"}
		if is_instance_valid(body):
			var body_state := String(body.get_meta("tree_visual_state", ""))
			if body_state != previous_body_state:
				retirement_transition = {"frame":Engine.get_process_frames(),
					"from":previous_body_state, "to":body_state,
					"receiptsClosedAtTransition":receipts_closed,
					"currentReceiptCount":current_receipt_count,
					"requiredReceiptCount":sections.size(),
					"legacyVisualPresent":is_instance_valid(legacy),
					"receipts":latest}
				_trace("tree_visual_state_changed", {"from":previous_body_state,
					"to":body_state, "receipts":latest,
					"receiptClosureComplete":receipts_closed})
				previous_body_state = body_state
				if body_state == "section_owned" and not receipts_closed:
					return {"status":"failed",
						"reason":"tree_visual_state_changed_before_receipt_closure",
						"orderingObserved":false,
						"legacyVisualRetainedUntilReceiptClosure":false,
						"retirementTransition":retirement_transition,
						"entryReceiptState":entry_receipt_state,
						"postDemandPendingCheckpoint":post_demand_pending_checkpoint,
						"postDemandPartialCheckpoint":post_demand_partial_checkpoint}
		if receipts_closed and is_instance_valid(body) \
			and String(body.get_meta("tree_visual_state", "")) == "section_owned" \
			and body.get_node_or_null("GeneratedTreeVisual") == null:
			var partial_checkpoint_valid := _partial_receipt_checkpoint_is_valid(
				post_demand_partial_checkpoint)
			var ordering_observed := entry_was_incomplete \
				and not post_demand_pending_checkpoint.is_empty() \
				and partial_checkpoint_valid
			return {"status":"ready", "allReceiptsCurrent":true,
				"exactSourceRevisionInEveryReceipt":bool(latest.get("exactSourceRevision", false)),
				"providerCoverageCurrent":bool(latest.get("providerCoverageCurrent", false)),
				"legacyVisualRetainedUntilReceiptClosure":visual_retained_until_closure \
					and ordering_observed,
				"orderingObserved":ordering_observed,
				"orderingObservationReason":"observed_pending_partial_receipt_with_same_legacy_body_and_collider" \
					if ordering_observed else _ordering_observation_failure_reason(
						entry_was_incomplete, post_demand_pending_checkpoint,
						post_demand_partial_checkpoint),
				"entryReceiptState":entry_receipt_state,
				"postDemandPendingCheckpoint":post_demand_pending_checkpoint,
				"postDemandPartialCheckpoint":post_demand_partial_checkpoint,
				"postDemandPartialCheckpointValid":partial_checkpoint_valid,
				"retirementTransition":retirement_transition,
				"receiptCount":sections.size(), "receipts":latest.get("rows", []),
				"sourceId":tree.get("sourceId", ""),
				"sourceRevision":tree.get("sourceRevision", ""),
				"artifactGeneration":tree.get("artifactGeneration", 0)}
		if Engine.get_process_frames() % TREE_PROGRESS_INTERVAL_FRAMES == 0:
			_write_progress("waiting_for_all_current_tree_section_receipts", {
				"tree":_tree_identity_summary(tree), "receipts":latest,
				"legacyVisualVisible":is_instance_valid(legacy) and legacy.is_visible_in_tree(),
				"bodyState":String(body.get_meta("tree_visual_state", "")) \
					if is_instance_valid(body) else "body_missing",
				"startup":_startup_status()})
		await get_tree().physics_frame
	return {"status":"pending", "reason":"tree_native_receipt_closure_not_reached",
		"allReceiptsCurrent":bool(latest.get("complete", false)),
		"exactSourceRevisionInEveryReceipt":bool(latest.get("exactSourceRevision", false)),
		"providerCoverageCurrent":bool(latest.get("providerCoverageCurrent", false)),
		"legacyVisualRetainedUntilReceiptClosure":visual_retained_until_closure \
			and entry_was_incomplete and not post_demand_pending_checkpoint.is_empty(),
		"orderingObserved":entry_was_incomplete \
			and not post_demand_pending_checkpoint.is_empty() \
			and _partial_receipt_checkpoint_is_valid(post_demand_partial_checkpoint),
		"orderingObservationReason":_ordering_observation_failure_reason(
			entry_was_incomplete, post_demand_pending_checkpoint,
			post_demand_partial_checkpoint),
		"entryReceiptState":entry_receipt_state,
		"postDemandPendingCheckpoint":post_demand_pending_checkpoint,
		"postDemandPartialCheckpoint":post_demand_partial_checkpoint,
		"postDemandPartialCheckpointValid":_partial_receipt_checkpoint_is_valid(
			post_demand_partial_checkpoint),
		"retirementTransition":retirement_transition,
		"receipts":latest, "startup":_startup_status()}


func _receipt_checkpoint(kind: String, receipt_state: Dictionary, tree: Dictionary,
		body: StaticBody3D, collision: CollisionShape3D, legacy: Node3D) -> Dictionary:
	return {"kind":kind, "frame":Engine.get_process_frames(),
		"elapsedMsec":Time.get_ticks_msec() - run_started_msec,
		"currentReceiptCount":int(receipt_state.get("currentReceiptCount", 0)),
		"requiredReceiptCount":int(receipt_state.get("requiredReceiptCount", 0)),
		"legacyVisualVisible":is_instance_valid(legacy) and legacy.is_visible_in_tree(),
		"legacyVisualInstanceId":legacy.get_instance_id() \
			if is_instance_valid(legacy) else 0,
		"expectedLegacyVisualInstanceId":(tree.get("legacyVisual") as Node3D).get_instance_id() \
			if is_instance_valid(tree.get("legacyVisual")) else 0,
		"sameLegacyVisual":is_instance_valid(legacy) \
			and legacy == tree.get("legacyVisual") \
			and is_instance_valid(body) and body.get_node_or_null("GeneratedTreeVisual") == legacy,
		"sameBody":is_instance_valid(body) \
			and body.get_instance_id() == int(tree.get("bodyInstanceId", 0)) \
			and body.get_parent() == tree.get("chunk"),
		"bodyInstanceId":body.get_instance_id() if is_instance_valid(body) else 0,
		"expectedBodyInstanceId":int(tree.get("bodyInstanceId", 0)),
		"sameCollider":is_instance_valid(collision) \
			and collision.get_instance_id() == int(tree.get("collisionInstanceId", 0)) \
			and collision.get_parent() == body,
		"collisionInstanceId":collision.get_instance_id() \
			if is_instance_valid(collision) else 0,
		"expectedCollisionInstanceId":int(tree.get("collisionInstanceId", 0)),
		"colliderEnabled":is_instance_valid(collision) and not collision.disabled,
		"bodyVisualState":String(body.get_meta("tree_visual_state", "")) \
			if is_instance_valid(body) else "body_missing",
		"receipts":receipt_state.get("rows", [])}


func _partial_receipt_checkpoint_is_valid(checkpoint: Dictionary) -> bool:
	var current_count := int(checkpoint.get("currentReceiptCount", 0))
	var required_count := int(checkpoint.get("requiredReceiptCount", 0))
	var receipt_rows: Variant = checkpoint.get("receipts", null)
	if checkpoint.is_empty() or required_count < 2 \
			or current_count <= 0 or current_count >= required_count \
			or not receipt_rows is Array or receipt_rows.size() != required_count \
			or not bool(checkpoint.get("legacyVisualVisible", false)) \
		or not bool(checkpoint.get("sameLegacyVisual", false)) \
			or not bool(checkpoint.get("sameBody", false)) \
			or not bool(checkpoint.get("sameCollider", false)) \
			or not bool(checkpoint.get("colliderEnabled", false)) \
			or int(checkpoint.get("bodyInstanceId", 0)) \
				!= int(checkpoint.get("expectedBodyInstanceId", -1)) \
			or int(checkpoint.get("collisionInstanceId", 0)) \
				!= int(checkpoint.get("expectedCollisionInstanceId", -1)) \
			or int(checkpoint.get("legacyVisualInstanceId", 0)) \
				!= int(checkpoint.get("expectedLegacyVisualInstanceId", -1)) \
			or String(checkpoint.get("bodyVisualState", "")) != "published":
		return false
	var exact_current_count := 0
	for row_value: Variant in receipt_rows:
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if not bool(row.get("current", false)):
			continue
		if not bool(row.get("exactTreeSourceRevision", false)) \
				or not bool(row.get("providerCoverageCurrent", false)) \
				or int(row.get("generation", 0)) <= 0 \
				or String(row.get("contentManifestDigest", "")).is_empty():
			return false
		exact_current_count += 1
	return exact_current_count == current_count


func _ordering_observation_failure_reason(entry_was_incomplete: bool,
		pending_checkpoint: Dictionary, partial_checkpoint: Dictionary) -> String:
	if not entry_was_incomplete:
		return "all_target_receipts_current_before_demand_replay"
	if pending_checkpoint.is_empty():
		return "no_post_demand_pending_checkpoint_observed"
	if not _partial_receipt_checkpoint_is_valid(partial_checkpoint):
		return "no_post_demand_partial_receipt_checkpoint_observed"
	return ""


func _receipt_rows_cover_tree(tree: Dictionary,
		sections: Array[Vector3i]) -> Dictionary:
	var coordinator_value: Variant = main.get("world_static_section_coordinator")
	var provider_value: Variant = main.get("ecology_static_section_provider")
	if not is_instance_valid(coordinator_value) or not is_instance_valid(provider_value):
		return {"complete":false, "reason":"provider_or_coordinator_missing", "rows":[]}
	var receipts: Variant = coordinator_value.get("_production_candidate_receipts")
	var coverage_by_section: Variant = provider_value.get("_latest_coverage_by_section")
	var rows: Array[Dictionary] = []
	var every_current := true
	var exact_revision := true
	var provider_current := true
	var current_receipt_count := 0
	for section: Vector3i in sections:
		var receipt: Dictionary = receipts.get(section, {}) if receipts is Dictionary else {}
		var coverage := String(coverage_by_section.get(section, "")) \
			if coverage_by_section is Dictionary else ""
		var current := not receipt.is_empty() and bool(coordinator_value.call(
			"installed_section_receipt_is_current", section, receipt))
		var source_revisions: Variant = receipt.get("sourceRevisions", {})
		var revision_match := source_revisions is Dictionary \
			and String(source_revisions.get(String(tree.get("sourceId", "")), "")) \
			== String(tree.get("sourceRevision", ""))
		var coverage_match := false
		for row_value: Variant in receipt.get("providerCoverage", []):
			if row_value is Array and row_value.size() >= 2 \
				and String(row_value[0]) == PROVIDER_ID \
				and String(row_value[1]) == coverage and not coverage.is_empty():
				coverage_match = true
				break
		every_current = every_current and current
		if current:
			current_receipt_count += 1
		exact_revision = exact_revision and revision_match
		provider_current = provider_current and coverage_match
		rows.append({"section":_section_to_json(section), "current":current,
			"exactTreeSourceRevision":revision_match,
			"expectedSourceRevision":String(tree.get("sourceRevision", "")),
			"receiptSourceRevision":String(source_revisions.get(
				String(tree.get("sourceId", "")), "")) if source_revisions is Dictionary else "",
			"providerCoverageCurrent":coverage_match,
			"providerCoverageRevision":coverage,
			"generation":int(receipt.get("generation", 0)),
			"contentManifestDigest":String(receipt.get("contentManifestDigest", "")),
			"censusDigest":String(receipt.get("censusDigest", "")),
			"backendInstanceId":int(receipt.get("backendInstanceId", 0)),
			"chunkInstanceId":int(receipt.get("chunkInstanceId", 0)),
			"demandStage":String(coordinator_value.get(
				"_visible_section_demands").get(section, {}).get("stage", "missing"))})
	return {"complete":every_current and exact_revision and provider_current \
		and rows.size() == sections.size(),
		"allCurrent":every_current, "exactSourceRevision":exact_revision,
		"providerCoverageCurrent":provider_current, "rows":rows,
		"currentReceiptCount":current_receipt_count,
		"requiredReceiptCount":sections.size()}


func _current_tree_census_summary(tree: Dictionary) -> Dictionary:
	return _census_summary(_current_tree_census(tree), tree)


func _census_summary(census: Dictionary, tree: Dictionary) -> Dictionary:
	var revisions: Variant = census.get("sourceRevisions", {})
	var provider_ids: Variant = census.get("sourceProviderIds", {})
	var expected: Variant = census.get("expectedContributorsBySection", {})
	var source_id := String(tree.get("sourceId", ""))
	var per_section := []
	for section: Vector3i in tree.get("sections", []):
		var ids: Variant = expected.get(section, []) if expected is Dictionary else []
		per_section.append({"section":_section_to_json(section),
			"includesTree":ids is Array and ids.has(source_id)})
	return {"status":census.get("status", "missing"),
		"reason":census.get("reason", ""), "sourceId":source_id,
		"providerId":provider_ids.get(source_id, "") if provider_ids is Dictionary else "",
		"expectedRevision":tree.get("sourceRevision", ""),
		"censusRevision":revisions.get(source_id, "") if revisions is Dictionary else "",
		"sections":per_section,
		"censusDigest":String(census.get("censusDigest", ""))}


func _enabled_tree_collider(body: StaticBody3D) -> CollisionShape3D:
	for child: Node in body.get_children():
		if child is CollisionShape3D and not (child as CollisionShape3D).disabled:
			return child as CollisionShape3D
	return null


func _tree_identity_summary(tree: Dictionary) -> Dictionary:
	var pending_tree_telemetry: Dictionary = tree.get("mainPendingTreeTelemetry", {})
	return {"seed":seed_text, "sourceId":tree.get("sourceId", ""),
		"propId":tree.get("propId", ""),
		"mainPendingTreeCandidateId":String(pending_tree_telemetry.get("candidateId", "")),
		"chunkKey":_vec2_to_json(tree.get("chunkKey", Vector2i.ZERO)),
		"bodyInstanceId":tree.get("bodyInstanceId", 0),
		"collisionInstanceId":tree.get("collisionInstanceId", 0),
		"artifactGeneration":tree.get("artifactGeneration", 0),
		"sourceRevision":tree.get("sourceRevision", ""),
		"sections":_sections_to_json(tree.get("sections", []))}


func _startup_status() -> Dictionary:
	if not is_instance_valid(main):
		return {"state":"main_unavailable"}
	var domains: Variant = main.get("startup_readiness_domains")
	var failure: Variant = main.get("startup_loading_failure_result")
	var pending_tree_telemetry := _main_pending_tree_publication_telemetry()
	var compiler_progress := _live_tree_section_compiler_progress()
	_capture_startup_tree_compiler_progress(compiler_progress, pending_tree_telemetry)
	return {"completed":startup_completion_observed,
		"failed":startup_failure_observed,
		"failureMessage":startup_failure_message,
		"failure":_json_safe_report_value(failure),
		"failureSummary":String(failure.get("reason", startup_failure_message)) \
			if failure is Dictionary else str(failure),
		"pendingTreePublicationTelemetry":pending_tree_telemetry,
		"sectionCompilerCurrent":compiler_progress,
		"sectionCompilerProgressHistory":startup_tree_compiler_progress_history.duplicate(true),
		"gameplayStatus":domains.get("gameplay", {}).get("status", "missing") \
			if domains is Dictionary else "missing"}


## Capture the live compiler independently from Main's terminal readiness
## snapshot. These bounded samples distinguish increasing work, a stationary
## phase, candidate resets, and a missing continuation without asserting that
## any one timeout means the compiler is stalled.
func _live_tree_section_compiler_progress() -> Dictionary:
	if not is_instance_valid(main):
		return {"status":"main_unavailable"}
	var queue_value: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue_value) or not queue_value.has_method(
			"startup_tree_section_compile_diagnostics"):
		return {"status":"unavailable", "reason":"compiler_diagnostics_api_missing"}
	var value: Variant = queue_value.call("startup_tree_section_compile_diagnostics")
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {"status":"unavailable", "reason":"compiler_diagnostics_not_dictionary"}


func _capture_startup_tree_compiler_progress(compiler: Dictionary,
		pending_tree: Dictionary) -> void:
	var compiler_body: Variant = compiler.get("compiler", {})
	if not compiler_body is Dictionary:
		compiler_body = {}
	var pending_rows: Variant = pending_tree.get("rows", [])
	var stage_counts: Dictionary = pending_tree.get("queueStageCounts", {})
	var ids: Array = pending_tree.get("candidateIds", [])
	var sample := {"elapsedMsec":Time.get_ticks_msec() - run_started_msec,
		"pendingIds":ids.duplicate(), "pendingIdCount":ids.size(),
		"reportedPendingCount":int(pending_tree.get("reportedPendingCount", -1)),
		"pendingRowsTruncated":bool(pending_tree.get("rowsTruncated", false)),
		"queueStageCounts":stage_counts.duplicate(true),
		"rowCount":pending_rows.size(),
		"startedCount":int(compiler.get("startedCount", -1)),
		"completedCount":int(compiler.get("completedCount", -1)),
		"staleCount":int(compiler.get("staleCount", -1)),
		"lastAdvance":compiler.get("lastAdvance", {}).duplicate(true) \
			if compiler.get("lastAdvance", {}) is Dictionary else {},
		"compiler":compiler_body.duplicate(true)}
	var history := startup_tree_compiler_progress_history
	if not history.is_empty():
		var previous: Dictionary = history[history.size() - 1]
		var previous_compiler: Dictionary = previous.get("compiler", {})
		var current_candidate := String(compiler_body.get("activeCandidateId", ""))
		var previous_candidate := String(previous_compiler.get("activeCandidateId", ""))
		var current_units := int(compiler_body.get("workUnits", -1))
		var previous_units := int(previous_compiler.get("workUnits", -1))
		var completed_delta := int(compiler.get("completedCount", -1)) \
			- int(previous.get("completedCount", -1))
		sample["previousElapsedMsec"] = int(previous.get("elapsedMsec", -1))
		sample["candidateChanged"] = current_candidate != previous_candidate
		sample["completedCountDelta"] = completed_delta
		sample["workUnitsDelta"] = current_units - previous_units \
			if current_candidate == previous_candidate and current_units >= 0 \
				and previous_units >= 0 else -1
		sample["progressInterpretation"] = "candidate_changed_or_reset" \
			if current_candidate != previous_candidate else ( \
				"work_units_advanced" if int(sample["workUnitsDelta"]) > 0 else ( \
				"work_units_reset_same_candidate" if int(sample["workUnitsDelta"]) < 0 \
				and previous_units >= 0 else ( \
				"completed_count_advanced" if completed_delta > 0 else \
				"same_candidate_no_work_unit_delta")))
	else:
		sample["progressInterpretation"] = "first_sample"
	history.append(sample)
	while history.size() > STARTUP_TREE_COMPILER_HISTORY_LIMIT:
		history.pop_front()


## Lightweight ID-only read for repeated discovery scans. The detailed per-ID
## producer, census, section-admission and receipt joins are captured once in
## startup progress and the terminal report.
func _main_pending_tree_candidate_ids() -> Dictionary:
	if not is_instance_valid(main):
		return {"status":"main_unavailable", "candidateIds":[]}
	var domains_value: Variant = main.get("startup_readiness_domains")
	if not domains_value is Dictionary:
		return {"status":"readiness_domains_unavailable", "candidateIds":[]}
	var domains: Dictionary = domains_value
	var initial_value: Variant = domains.get("initial_region", {})
	if not initial_value is Dictionary:
		return {"status":"initial_region_unavailable", "candidateIds":[]}
	var initial_region: Dictionary = initial_value
	var metrics_value: Variant = initial_region.get("metrics", {})
	if not metrics_value is Dictionary:
		return {"status":"initial_region_metrics_unavailable", "candidateIds":[]}
	var metrics: Dictionary = metrics_value
	var payload_value: Variant = metrics.get("pendingVisualTreeCandidates", {})
	if not payload_value is Dictionary:
		return {"status":"not_emitted", "candidateIds":[]}
	var payload: Dictionary = payload_value
	var rows_value: Variant = payload.get("rows", [])
	var candidate_ids: Array[String] = []
	if rows_value is Array:
		for row_value: Variant in rows_value:
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			if String(row.get("kind", "")) == "trees_foliage":
				var candidate_id := String(row.get("candidateId", ""))
				if not candidate_id.is_empty() and candidate_id not in candidate_ids:
					candidate_ids.append(candidate_id)
	return {"status":"available" if not candidate_ids.is_empty() else "empty",
		"reportedPendingCount":int(payload.get("candidateCount",
			payload.get("pendingCount", candidate_ids.size()))),
		"capped":bool(payload.get("capped", false)),
		"rowsTruncated":bool(payload.get("rowsTruncated", false)),
		"candidateIds":candidate_ids}


## Main's bounded startup telemetry already joins each pending tree candidate to
## its current queue records and receipt. Retain those per-ID rows verbatim in
## both progress and terminal reports, including when startup times out before
## this fixture can select a compiled tree.
func _main_pending_tree_publication_telemetry() -> Dictionary:
	if not is_instance_valid(main):
		return {"status":"main_unavailable", "candidateIds":[], "rows":[]}
	var domains_value: Variant = main.get("startup_readiness_domains")
	if not domains_value is Dictionary:
		return {"status":"readiness_domains_unavailable", "candidateIds":[], "rows":[]}
	var domains: Dictionary = domains_value
	var initial_value: Variant = domains.get("initial_region", {})
	if not initial_value is Dictionary:
		return {"status":"initial_region_unavailable", "candidateIds":[], "rows":[]}
	var initial_region: Dictionary = initial_value
	var metrics_value: Variant = initial_region.get("metrics", {})
	if not metrics_value is Dictionary:
		return {"status":"initial_region_metrics_unavailable", "candidateIds":[], "rows":[]}
	var metrics: Dictionary = metrics_value
	var payload_value: Variant = metrics.get("pendingVisualTreeCandidates", {})
	if not payload_value is Dictionary:
		return {"status":"not_emitted", "reason":"pendingVisualTreeCandidates_missing",
			"candidateIds":[], "rows":[]}
	var payload: Dictionary = payload_value
	var source_rows_value: Variant = payload.get("rows", [])
	var rows: Array[Dictionary] = []
	var candidate_ids: Array[String] = []
	var queue_matched_count := 0
	var current_receipt_count := 0
	var missing_receipt_count := 0
	var complete_join_count := 0
	var section_join_count := 0
	var current_native_tree_receipt_count := 0
	var queue_stage_counts := {"section_recipe_input":0, "section_compile":0,
		"staged":0, "active":0, "pending":0, "completed":0,
		"section_compiled":0, "section_prepared":0, "section_acknowledged":0,
		"unmatched":0}
	var join_production_state := startup_failure_observed \
		or startup_completion_observed or finished
	if source_rows_value is Array:
		for source_row_value: Variant in source_rows_value:
			if not source_row_value is Dictionary:
				continue
			var source_row: Dictionary = source_row_value
			var row: Dictionary = source_row.duplicate(true)
			if String(row.get("kind", "")) != "trees_foliage":
				continue
			var candidate_id := String(row.get("candidateId", ""))
			var source_id := String(row.get("sourceId", ""))
			var queue_status := String(row.get("queueJoinStatus", ""))
			var queue_value: Variant = row.get("queue", null)
			var receipt_value: Variant = row.get("receipt", null)
			var joined := not candidate_id.is_empty() and not source_id.is_empty() \
				and not String(row.get("sourceRevision", "")).is_empty() \
				and not queue_status.is_empty() and queue_value is Array \
				and receipt_value is Dictionary
			row["telemetryJoinStatus"] = "complete" if joined else "incomplete_source_queue_receipt_join"
			if joined:
				complete_join_count += 1
			if not candidate_id.is_empty():
				candidate_ids.append(candidate_id)
			if queue_status == "matched":
				queue_matched_count += 1
			var observed_stages: Dictionary = {}
			if queue_value is Array:
				for queue_row_value: Variant in queue_value:
					if queue_row_value is Dictionary:
						var stage := String(queue_row_value.get("stage",
							queue_row_value.get("queueCollection", "")))
						if not stage.is_empty():
							observed_stages[stage] = true
			var exact_stage_join: Dictionary = row.get("exactTreeStageJoin", {})
			for stage: String in ["section_recipe_input", "section_compiled", "section_prepared"]:
				var stage_rows: Variant = exact_stage_join.get(stage, [])
				if stage_rows is Array and not (stage_rows as Array).is_empty():
					observed_stages[stage] = true
			var acknowledged_stage: Variant = exact_stage_join.get("section_acknowledged", {})
			if acknowledged_stage is Dictionary and not (acknowledged_stage as Dictionary).is_empty():
				observed_stages["section_acknowledged"] = true
			if observed_stages.is_empty():
				queue_stage_counts["unmatched"] = int(queue_stage_counts.unmatched) + 1
			else:
				for stage_value: Variant in observed_stages.keys():
					var stage_key := String(stage_value)
					if not queue_stage_counts.has(stage_key):
						queue_stage_counts[stage_key] = 0
					queue_stage_counts[stage_key] = int(queue_stage_counts[stage_key]) + 1
			if receipt_value is Dictionary:
				var receipt: Dictionary = receipt_value
				if bool(receipt.get("current", false)):
					current_receipt_count += 1
				if bool(receipt.get("missing", true)):
					missing_receipt_count += 1
			if join_production_state:
				var section_join := _pending_tree_production_section_join(row)
				row["productionSectionJoin"] = section_join
				if String(section_join.get("status", "")) == "joined":
					section_join_count += 1
					var native_receipts: Dictionary = section_join.get("nativeReceipts", {})
					if bool(native_receipts.get("complete", false)):
						current_native_tree_receipt_count += 1
			else:
				row["productionSectionJoin"] = {"status":"deferred_until_terminal_startup"}
			rows.append(row)
	return {"status":"available" if not rows.is_empty() else "empty",
		"reason":String(payload.get("reason", "")),
		"reportedPendingCount":int(payload.get("candidateCount",
			payload.get("pendingCount", rows.size()))),
		"reportedRowCount":rows.size(),
		"capped":bool(payload.get("capped", false)),
		"rowsTruncated":bool(payload.get("rowsTruncated", false)),
		"completeJoinCount":complete_join_count,
		"productionSectionJoinCount":section_join_count,
		"queueMatchedCount":queue_matched_count,
		"currentReceiptCount":current_receipt_count,
		"currentNativeTreeReceiptCount":current_native_tree_receipt_count,
		"missingReceiptCount":missing_receipt_count,
		"queueStageCounts":queue_stage_counts,
		"sectionCompiler":payload.get("sectionCompiler", {
			"status":"unavailable", "reason":"sectionCompiler_missing_from_Main_snapshot"}),
		"productionSectionJoinDeferred":not join_production_state,
		"candidateIds":candidate_ids, "rows":rows}


## Join Main's exact pending candidate IDs to the current committed ecology
## producer record, provider source revision, section census/admission and any
## accepted native receipt. This is observational only: it does not request or
## mutate section work, and absent joins remain explicit in the report.
func _pending_tree_production_section_join(telemetry_row: Dictionary) -> Dictionary:
	var candidate_id := String(telemetry_row.get("candidateId", ""))
	var source_id := String(telemetry_row.get("sourceId", ""))
	var result := {"status":"pending", "candidateId":candidate_id,
		"sourceId":source_id,
		"telemetryChunkSourceRevision":String(telemetry_row.get("sourceRevision", "")),
		"providerTreeSourceRevision":"", "producerPublication":"unavailable",
		"sections":[], "census":{}, "sectionAdmission":[], "nativeReceipts":{}}
	if candidate_id.is_empty() or source_id.is_empty():
		result["reason"] = "pending_candidate_identity_missing"
		return result
	if not is_instance_valid(provider) or not provider.has_method("_current_tree_publications"):
		result["reason"] = "ecology_tree_publication_index_unavailable"
		return result
	var publication_index: Dictionary = provider.call("_current_tree_publications", main)
	var publication_value: Variant = publication_index.get(candidate_id, {})
	if not publication_value is Dictionary or (publication_value as Dictionary).is_empty():
		result["producerPublication"] = "no_current_publication_for_candidate_id"
		result["reason"] = "pending_candidate_not_joined_to_committed_tree_record"
		return result
	var publication: Dictionary = publication_value
	result["producerPublication"] = "matched"
	var body := publication.get("body", null) as StaticBody3D
	var record_value: Variant = publication.get("record", {})
	var record: Dictionary = record_value if record_value is Dictionary else {}
	var chunks_value: Variant = main.get("chunks")
	var chunk_key_value: Variant = telemetry_row.get("chunkKey", null)
	var chunk: Node3D
	if chunk_key_value is Array and (chunk_key_value as Array).size() == 2 \
			and chunks_value is Dictionary:
		var chunk_key := Vector2i(int(chunk_key_value[0]), int(chunk_key_value[1]))
		chunk = (chunks_value as Dictionary).get(chunk_key) as Node3D
	var body_owner_matches := is_instance_valid(body) and is_instance_valid(chunk) \
		and body.get_parent() == chunk \
		and String(body.get_meta("prop_id", "")) == candidate_id \
		and String(body.get_meta("static_ecology_source_id", "")) == source_id \
		and int(record.get("bodyInstanceId", 0)) == body.get_instance_id()
	result["producerIdentity"] = {"bodyInstanceId":body.get_instance_id() \
		if is_instance_valid(body) else 0,
		"chunkInstanceId":chunk.get_instance_id() if is_instance_valid(chunk) else 0,
		"bodyOwnerMatchesCandidate":body_owner_matches,
		"artifactGeneration":int(record.get("artifactGeneration", 0)),
		"publicationPrepared":bool(publication.get("prepared", false)),
		"publicationCompiled":publication.has("compiled")}
	if not body_owner_matches:
		result["producerPublication"] = "publication_owner_or_source_mismatch"
		result["reason"] = "tree_record_body_chunk_or_source_identity_mismatch"
		return result
	var source_candidate := _pending_tree_source_candidate(chunk, candidate_id)
	if source_candidate.is_empty():
		result["reason"] = "pending_candidate_missing_from_current_chunk_source_snapshot"
		return result
	if not provider.has_method("_tree_census_source_revision") \
			or not provider.has_method("_tree_census_section_keys"):
		result["reason"] = "tree_census_api_unavailable"
		return result
	var producer_revision := String(provider.call("_tree_census_source_revision",
		source_candidate, publication))
	var sections_value: Variant = provider.call("_tree_census_section_keys", publication)
	if not sections_value is Array:
		result["reason"] = "tree_section_ownership_unavailable"
		return result
	var sections: Array[Vector3i] = []
	for section_value: Variant in sections_value:
		if section_value is Vector3i and section_value not in sections:
			sections.append(section_value)
	sections.sort_custom(_section_before)
	result["providerTreeSourceRevision"] = producer_revision
	result["revisionDomains"] = {"telemetry":String(telemetry_row.get(
		"sourceRevision", "")), "treeProducer":producer_revision,
		"comparison":"chunk_readiness_and_tree_producer_revisions_are_distinct"}
	result["sections"] = _sections_to_json(sections)
	result["treeRecipeRevision"] = String(record.get("contentRevision", ""))
	result["treeQueueGeneration"] = int(record.get("artifactGeneration", 0))
	if sections.is_empty() or producer_revision.is_empty():
		result["reason"] = "tree_producer_revision_or_owned_sections_missing"
		return result
	var tree_identity := {"sourceId":source_id,
		"sourceRevision":producer_revision, "sections":sections}
	var census := _current_tree_census(tree_identity)
	result["census"] = _census_summary(census, tree_identity)
	result["censusCoversExactTreeRevision"] = _census_covers_tree(
		census, tree_identity, sections)
	var coordinator_value: Variant = main.get("world_static_section_coordinator")
	if is_instance_valid(coordinator_value):
		var demands_value: Variant = coordinator_value.get("_visible_section_demands")
		var demand_rows: Array[Dictionary] = []
		if demands_value is Dictionary:
			for section: Vector3i in sections:
				var demand_value: Variant = (demands_value as Dictionary).get(section, {})
				var demand: Dictionary = demand_value if demand_value is Dictionary else {}
				demand_rows.append({"section":_section_to_json(section),
					"stage":String(demand.get("stage", "missing")),
					"queued":bool(demand.get("queued", false)),
					"lastStatus":String(demand.get("lastStatus", "")),
					"lastReason":String(demand.get("lastReason", "")),
					"blockedReason":String(demand.get("blockedReason", "")),
					"lastAdmissionDetails":_json_safe_report_value(
						demand.get("lastAdmissionDetails", {}))})
		result["sectionAdmission"] = demand_rows
	result["nativeReceipts"] = _receipt_rows_cover_tree(tree_identity, sections)
	result["status"] = "joined"
	result["reason"] = ""
	return result


func _pending_tree_source_candidate(chunk: Node3D, candidate_id: String) -> Dictionary:
	if not is_instance_valid(chunk):
		return {}
	var snapshot_value: Variant = chunk.get_meta("static_ecology_source_value_snapshot", {})
	if not snapshot_value is Dictionary or String(snapshot_value.get("status", "")) != "ready":
		return {}
	for candidate_value: Variant in snapshot_value.get("candidates", []):
		if not candidate_value is Dictionary:
			continue
		var candidate: Dictionary = candidate_value
		if String(candidate.get("kind", "")) == "trees_foliage" \
				and String(candidate.get("propId", "")) == candidate_id:
			return candidate
	return {}


func _json_safe_report_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return value
		TYPE_FLOAT:
			return value if is_finite(float(value)) else str(value)
		TYPE_DICTIONARY:
			var result := {}
			for key: Variant in value:
				result[String(key)] = _json_safe_report_value(value[key])
			return result
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, \
		TYPE_PACKED_VECTOR4_ARRAY:
			var result: Array = []
			for item: Variant in value:
				result.append(_json_safe_report_value(item))
			return result
		TYPE_VECTOR2:
			return {"x":value.x, "y":value.y}
		TYPE_VECTOR2I:
			return {"x":value.x, "y":value.y}
		TYPE_RECT2:
			return {"position":_json_safe_report_value(value.position),
				"size":_json_safe_report_value(value.size)}
		TYPE_RECT2I:
			return {"position":_json_safe_report_value(value.position),
				"size":_json_safe_report_value(value.size)}
		TYPE_VECTOR3:
			return {"x":value.x, "y":value.y, "z":value.z}
		TYPE_VECTOR3I:
			return {"x":value.x, "y":value.y, "z":value.z}
		TYPE_VECTOR4:
			return {"x":value.x, "y":value.y, "z":value.z, "w":value.w}
		TYPE_TRANSFORM2D:
			return {"x":_json_safe_report_value(value.x),
				"y":_json_safe_report_value(value.y),
				"origin":_json_safe_report_value(value.origin)}
		TYPE_TRANSFORM3D:
			return {"basis":_json_safe_report_value(value.basis),
				"origin":_json_safe_report_value(value.origin)}
		TYPE_AABB:
			return {"position":_json_safe_report_value(value.position),
				"size":_json_safe_report_value(value.size)}
		TYPE_BASIS:
			return {"x":_json_safe_report_value(value.x),
				"y":_json_safe_report_value(value.y),
				"z":_json_safe_report_value(value.z)}
		TYPE_QUATERNION:
			return {"x":value.x, "y":value.y, "z":value.z, "w":value.w}
		TYPE_PLANE:
			return {"normal":_json_safe_report_value(value.normal), "d":value.d}
		TYPE_PROJECTION:
			return {"x":_json_safe_report_value(value.x),
				"y":_json_safe_report_value(value.y),
				"z":_json_safe_report_value(value.z),
				"w":_json_safe_report_value(value.w)}
		TYPE_COLOR:
			return {"r":value.r, "g":value.g, "b":value.b, "a":value.a}
		TYPE_STRING_NAME, TYPE_NODE_PATH, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL:
			return str(value)
		TYPE_OBJECT:
			if value == null:
				return null
			if not is_instance_valid(value):
				return {"class":"Object", "instanceId":0, "valid":false}
			var object_result := {"class":value.get_class(),
				"instanceId":value.get_instance_id()}
			if value is Resource and not (value as Resource).resource_path.is_empty():
				object_result["resourcePath"] = (value as Resource).resource_path
			return object_result
		_:
			return str(value)


func _section_before(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


func _finish() -> void:
	if finished:
		return
	finished = true
	var passed := failures.is_empty()
	var report := {"schema":TREE_REPORT_SCHEMA,
		"status":"complete" if passed else "failed", "passed":passed,
		"seed":seed_text, "worldId":String(coordinator.get("_world_id")) \
			if is_instance_valid(coordinator) else "",
		"tutorialSkipped":bool(main.get("launch_options").get("skipTutorial", false)) \
			if is_instance_valid(main) else false,
		"globalStartup":_startup_status(),
		"pendingTreePublicationTelemetry":_main_pending_tree_publication_telemetry(),
		"discoveryTelemetry":discovery_telemetry,
		"checkCount":checks.size(), "checks":checks, "failures":failures,
		"tree":_tree_identity_summary(selected_tree) if not selected_tree.is_empty() else {},
		"demandRequests":demand_requests, "trace":trace,
		"evidenceLevel":"headed Main production queue/ecology/coordinator/native section publication lifecycle diagnostic",
		"mode":"not traversal/gameplay acceptance",
		"doesNotProve":"Global startup readiness, player traversal, harvest/save/reload, unload/replay, full ecology parity, performance, or complete migration."}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	if is_instance_valid(main):
		main.queue_free()
	print("Ecology Main tree section receipt report: " + report_path)
	get_tree().quit(0 if passed else 1)
