extends "res://scripts/testing/world/EcologyMainRetirementPlaytest.gd"

const HARVEST_SCHEMA := "ecology-main-harvest-save-replay/v1"
const MAX_HARVEST_STRIKES := 32
const STARTUP_NO_PROGRESS_TIMEOUT_SECONDS := 90.0
const MAIN_STARTUP_TIMEOUT_SECONDS := 180.0
const POST_REPLAY_TIMEOUT_SECONDS := 240.0
const STARTUP_TREE_SECTION_CORRELATION_SCHEMA := "ecology-startup-tree-section-correlation/v1"
const STARTUP_TREE_SECTION_CORRELATION_LIMIT := 48
const STARTUP_TREE_QUEUE_SCAN_LIMIT := 512
const STARTUP_TREE_TIMELINE_SCAN_LIMIT := 256
const STARTUP_TREE_ADMISSION_DETAIL_NODE_LIMIT := 128
const STARTUP_TREE_ADMISSION_DETAIL_ENTRY_LIMIT := 16
const STARTUP_TREE_ADMISSION_DETAIL_STRING_LIMIT := 192
const STARTUP_TREE_ADMISSION_DETAIL_DEPTH_LIMIT := 4
const STARTUP_TREE_SECTION_ARTIFACT_CACHE_LIMIT := 256
const STARTUP_TREE_FIRST_REJECTION_CACHE_LIMIT := 256
const REPORT_JSON_NODE_LIMIT := 50000
const STARTUP_TREE_IDS: Array[String] = [
	"ecology-main-retirement-stage5:-2,-8:0",
	"ecology-main-retirement-stage5:-8,-4:14",
	"ecology-main-retirement-stage5:-9,-3:20",
	"ecology-main-retirement-stage5:-10,14:13",
	"ecology-main-retirement-stage5:-3,6:18",
	"ecology-main-retirement-stage5:-6,10:27"]

var harvest_capture_path := ""
var selected_source_id := ""
var selected_prop_id := ""
var selected_chunk_key := Vector2i.ZERO
var selected_world_position := Vector3.INF
var selected_sections: Array[Vector3i] = []
var control_source_id := ""
var control_prop_id := ""
var control_chunk_key := Vector2i.ZERO
var control_body_instance_id := 0
var control_collision_instance_id := 0
var saved_body_instance_id := 0
var saved_collision_instance_id := 0
var persisted_save_slot_path := ""
var startup_tree_section_artifact_cache: Dictionary = {}
var startup_tree_first_rejections: Dictionary = {}
var last_startup_tree_section_correlation: Dictionary = {}
var startup_tree_diagnostic_caches_capped := false


func _ready() -> void:
	harvest_capture_path = OS.get_environment("VOXEL_ECOLOGY_HARVEST_REPLAY_HARVESTED")
	super._ready()


## Add a bounded, fixed-ID correlation to the existing progress stream. This
## only reads the production provider/coordinator/queue state; it does not
## admit work or change readiness.
func _write_progress(phase: String, details: Dictionary) -> void:
	var correlated := details.duplicate(true)
	if is_instance_valid(main):
		last_startup_tree_section_correlation = _startup_tree_section_correlation()
		correlated["startupTreeSectionCorrelation"] = last_startup_tree_section_correlation.duplicate(true)
	super._write_progress(phase, correlated)


func _startup_tree_section_correlation() -> Dictionary:
	var result := {"schema":STARTUP_TREE_SECTION_CORRELATION_SCHEMA,
		"fixedTreeIds":STARTUP_TREE_IDS.duplicate(), "sections":[],
		"sectionLimit":STARTUP_TREE_SECTION_CORRELATION_LIMIT,
		"capped":false}
	var provider_value: Variant = main.get("ecology_static_section_provider")
	var coordinator_value: Variant = main.get("world_static_section_coordinator")
	if not is_instance_valid(provider_value) or not is_instance_valid(coordinator_value):
		result["status"] = "production_provider_or_coordinator_unavailable"
		return result
	var queue_value: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue_value) or not provider_value.has_method("_tree_census_section_keys"):
		result["status"] = "tree_queue_or_section_owner_api_unavailable"
		return result
	var publications := _startup_target_tree_publications(queue_value)
	result["queueRecordsInspected"] = int(publications.get("inspectedRecords", 0))
	result["queueScanCapped"] = bool(publications.get("scanCapped", false))
	var publications_by_tree_id: Dictionary = publications.get("byTreeId", {})
	var demand_states: Variant = coordinator_value.get("_visible_section_demands")
	var candidate_jobs: Variant = coordinator_value.get("_production_candidate_jobs")
	var installed_receipts: Variant = coordinator_value.get("_installed_receipts")
	var committed_candidates: Variant = coordinator_value.get("_committed_candidates")
	var timeline_value: Variant = main.get("startup_loading_timeline")
	var timeline: Array = timeline_value if timeline_value is Array else []
	var timeline_start_index := maxi(0, timeline.size() - STARTUP_TREE_TIMELINE_SCAN_LIMIT)
	result["timelineRecordsInspected"] = timeline.size() - timeline_start_index
	result["timelineScanCapped"] = timeline_start_index > 0
	var rows: Array[Dictionary] = []
	var section_rows_emitted := 0
	for tree_id: String in STARTUP_TREE_IDS:
		var publication_value: Variant = publications_by_tree_id.get(tree_id, {})
		if not publication_value is Dictionary or publication_value.is_empty():
			rows.append({"treeId":tree_id, "status":"tree_publication_not_found"})
			continue
		var publication: Dictionary = publication_value
		var record_value: Variant = publication.get("record", null)
		var body_value: Variant = publication.get("body", null)
		if not record_value is Dictionary or not body_value is StaticBody3D:
			rows.append({"treeId":tree_id, "status":"tree_publication_record_or_body_unavailable"})
			continue
		var record: Dictionary = record_value
		var body: StaticBody3D = body_value
		var artifact_generation := int(record.get("artifactGeneration", 0))
		var body_instance_id := body.get_instance_id()
		var cache_key := "%s|%d|%d" % [tree_id, artifact_generation, body_instance_id]
		var section_keys: Array[Vector3i] = []
		if startup_tree_section_artifact_cache.has(cache_key):
			section_keys.assign(startup_tree_section_artifact_cache[cache_key])
		elif provider_value.has_method("_tree_census_section_keys"):
			var keys_value: Variant = provider_value.call(
				"_tree_census_section_keys", publication)
			if keys_value is Array:
				for key_value: Variant in keys_value:
					if key_value is Vector3i and key_value not in section_keys:
						section_keys.append(key_value)
			if startup_tree_section_artifact_cache.size() < \
					STARTUP_TREE_SECTION_ARTIFACT_CACHE_LIMIT:
				startup_tree_section_artifact_cache[cache_key] = section_keys.duplicate()
			else:
				startup_tree_diagnostic_caches_capped = true
		var record_sections: Array = []
		for section_key: Vector3i in section_keys:
			if section_rows_emitted >= STARTUP_TREE_SECTION_CORRELATION_LIMIT:
				result["capped"] = true
				break
			section_rows_emitted += 1
			var section_key_text := str(section_key)
			var demand: Dictionary = demand_states.get(section_key, {}) \
				if demand_states is Dictionary else {}
			var job: Dictionary = candidate_jobs.get(section_key, {}) \
				if candidate_jobs is Dictionary else {}
			var receipt: Dictionary = installed_receipts.get(section_key, {}) \
				if installed_receipts is Dictionary else {}
			var committed: Dictionary = committed_candidates.get(section_key, {}) \
				if committed_candidates is Dictionary else {}
			var session: Variant = job.get("session", null)
			var candidate: Dictionary = job.get("candidate", {}) \
				if job.get("candidate", {}) is Dictionary else {}
			var session_state := String(session.get("state", "")) \
				if is_instance_valid(session) and session is Object else ""
			var session_reason := String(session.get("reason")) \
				if is_instance_valid(session) and session is Object else ""
			var receipt_current := false
			if not receipt.is_empty() and coordinator_value.has_method(
					"installed_section_receipt_is_current"):
				receipt_current = bool(coordinator_value.call(
					"installed_section_receipt_is_current", section_key, receipt))
			var diagnostic_receipt := receipt.duplicate(false)
			diagnostic_receipt["current"] = receipt_current
			var section_row := {"treeId":tree_id,
				"sectionKey":[section_key.x, section_key.y, section_key.z],
				"providerAdmission":{"status":String(demand.get("lastStatus", "not_attempted")),
					"reason":String(demand.get("lastReason", "")),
					"attempts":int(demand.get("attempts", 0)),
					"details":_sanitize_startup_admission_value(
						demand.get("lastAdmissionDetails", {}))},
				"demandStage":String(demand.get("stage", "no_visible_demand")),
				"candidateJob":{"stage":String(job.get("stage", "none")),
					"generation":int(candidate.get("generation", job.get("generation", 0))),
					"contentManifestDigest":String(candidate.get("contentManifestDigest", "")),
					"censusDigest":String(candidate.get("censusDigest", "")),
					"sessionState":session_state, "sessionReason":session_reason},
				"installedReceipt":{"status":String(receipt.get("status", "missing")),
					"generation":int(receipt.get("generation", 0)),
					"contentManifestDigest":String(receipt.get("contentManifestDigest", "")),
					"censusDigest":String(receipt.get("censusDigest", "")),
					"current":receipt_current},
				"committedCandidate":{"generation":int(committed.get("generation", 0)),
					"contentManifestDigest":String(committed.get("contentManifestDigest", ""))}}
			var first_rejection_key := "%s|%s" % [tree_id, section_key_text]
			if not startup_tree_first_rejections.has(first_rejection_key):
				if startup_tree_first_rejections.size() >= \
						STARTUP_TREE_FIRST_REJECTION_CACHE_LIMIT:
					startup_tree_diagnostic_caches_capped = true
				else:
					var rejection := _first_tree_section_rejection(section_key_text,
						demand, job, diagnostic_receipt, timeline, timeline_start_index)
					if not rejection.is_empty():
						startup_tree_first_rejections[first_rejection_key] = rejection
			section_row["firstObservedRejectedTransition"] = \
				startup_tree_first_rejections.get(first_rejection_key, {})
			record_sections.append(section_row)
		rows.append({"treeId":tree_id, "status":"correlated" if not section_keys.is_empty()
			else "prepared_record_has_no_native_section_keys",
			"sourceId":String(record.get("sourceId", "")),
			"artifactGeneration":artifact_generation,
			"bodyInstanceId":body_instance_id,
			"bodyVisualState":String(body.get_meta("tree_visual_state", "")),
			"bodyOwnerChunkInstanceId":body.get_parent().get_instance_id() \
				if is_instance_valid(body.get_parent()) else 0,
			"queuePrepared":bool(publication.get("prepared", false)),
			"sections":record_sections})
		if rows.size() >= STARTUP_TREE_SECTION_CORRELATION_LIMIT:
			result["capped"] = true
			break
	result["status"] = "ready" if not rows.is_empty() else "target_tree_ids_not_seen"
	result["sections"] = rows
	var correlated_tree_count := 0
	for row: Dictionary in rows:
		if String(row.get("status", "")) == "correlated":
			correlated_tree_count += 1
	result["correlatedTreeCount"] = correlated_tree_count
	result["firstRejectedTransitionCount"] = startup_tree_first_rejections.size()
	result["diagnosticCachesCapped"] = startup_tree_diagnostic_caches_capped
	result["sectionArtifactCacheCount"] = startup_tree_section_artifact_cache.size()
	result["firstRejectionCacheCount"] = startup_tree_first_rejections.size()
	var safe_result: Variant = _sanitize_json_value(result, {
		"remainingNodes":8192, "maxEntries":64,
		"maxStringChars":256, "maxDepth":8}, 0)
	return safe_result if safe_result is Dictionary else {
		"schema":STARTUP_TREE_SECTION_CORRELATION_SCHEMA,
		"fixedTreeIds":STARTUP_TREE_IDS.duplicate(), "sections":[],
		"status":"diagnostic_sanitization_failed"}


func _startup_target_tree_publications(queue: Object) -> Dictionary:
	var by_tree_id := {}
	for tree_id: String in STARTUP_TREE_IDS:
		by_tree_id[tree_id] = {}
	var inspected := 0
	for collection_spec in [
		["prepared_section_value_records", "prepared"],
		["compiled_tree_section_records", "compiled"],
		["published_lod_records", "published_lod"]]:
		var collection_value: Variant = queue.get(String(collection_spec[0]))
		if not collection_value is Array:
			continue
		for value: Variant in collection_value:
			if inspected >= STARTUP_TREE_QUEUE_SCAN_LIMIT:
				return {"byTreeId":by_tree_id, "inspectedRecords":inspected,
					"scanCapped":true}
			inspected += 1
			var publication := _startup_tree_publication_from_record(value,
				String(collection_spec[1]))
			var tree_id := String(publication.get("treeId", ""))
			if not by_tree_id.has(tree_id):
				continue
			var existing: Dictionary = by_tree_id[tree_id]
			if existing.is_empty() or _startup_tree_publication_priority(
					String(publication.get("collection", ""))) > \
						_startup_tree_publication_priority(String(existing.get("collection", ""))):
				publication.erase("treeId")
				by_tree_id[tree_id] = publication
	return {"byTreeId":by_tree_id, "inspectedRecords":inspected,
		"scanCapped":inspected >= STARTUP_TREE_QUEUE_SCAN_LIMIT}


func _startup_tree_publication_from_record(value: Variant, collection: String) -> Dictionary:
	if not value is Dictionary:
		return {}
	var row: Dictionary = value
	var record: Dictionary = row
	var body_value: Variant = row.get("body", null)
	var compiled: Dictionary = {}
	if collection == "compiled":
		var record_value: Variant = row.get("record", {})
		if record_value is Dictionary:
			record = record_value
		var compiled_value: Variant = row.get("compiled", {})
		if compiled_value is Dictionary:
			compiled = compiled_value
		body_value = row.get("body", record.get("body", null))
	var body: StaticBody3D
	if body_value is WeakRef:
		body = (body_value as WeakRef).get_ref() as StaticBody3D
	elif body_value is StaticBody3D:
		body = body_value as StaticBody3D
	if not is_instance_valid(body):
		return {}
	var tree_id := String(record.get("propId", ""))
	if tree_id.is_empty():
		var request_value: Variant = record.get("request", {})
		if request_value is Dictionary:
			tree_id = String((request_value as Dictionary).get("treeId", ""))
	if tree_id.is_empty() or String(body.get_meta("prop_id", "")) != tree_id \
			or body.is_queued_for_deletion():
		return {}
	var publication := {"treeId":tree_id, "collection":collection,
		"record":record, "body":body, "prepared":collection == "prepared"}
	if not compiled.is_empty():
		publication["compiled"] = compiled
		publication["compiledRecord"] = row
	return publication


func _startup_tree_publication_priority(collection: String) -> int:
	match collection:
		"prepared": return 3
		"compiled": return 2
		"published_lod": return 1
	return 0


func _first_tree_section_rejection(section_key: String, demand: Dictionary,
		job: Dictionary, receipt: Dictionary, timeline: Array,
		timeline_start_index: int) -> Dictionary:
	for timeline_index: int in range(timeline_start_index, timeline.size()):
		var timeline_value: Variant = timeline[timeline_index]
		if not timeline_value is Dictionary:
			continue
		var metrics_value: Variant = (timeline_value as Dictionary).get("metrics", {})
		if not metrics_value is Dictionary:
			continue
		var publication_value: Variant = (metrics_value as Dictionary).get(
			"visibleSectionPublication", {})
		if not publication_value is Dictionary:
			continue
		var admission_value: Variant = (publication_value as Dictionary).get("lastAdmission", {})
		if not admission_value is Dictionary \
				or str(admission_value.get("sectionKey", "")) != section_key:
			continue
		var admission: Dictionary = admission_value
		if str(admission.get("status", "")) == "pending":
			return {"stage":"provider_admission", "source":"startup_loading_timeline",
				"frame":int((timeline_value as Dictionary).get("frame", -1)),
				"providerId":str(admission.get("providerId", "")),
				"reason":str(admission.get("providerReason", admission.get("reason", ""))),
				"result":_sanitize_startup_admission_value(admission)}
	if str(demand.get("lastStatus", "")) == "pending":
		var admission_details: Variant = demand.get("lastAdmissionDetails", {})
		var details: Dictionary = admission_details if admission_details is Dictionary else {}
		return {"stage":"provider_admission", "source":"current_demand_state",
			"providerId":str(details.get("providerId", "")),
			"reason":str(demand.get("lastReason", "")),
			"result":_sanitize_startup_admission_value(
				demand.get("lastAdmissionDetails", {}))}
	var session: Variant = job.get("session", null)
	if is_instance_valid(session) and session is Object \
			and str(session.get("state")) in ["pending", "failed"]:
		return {"stage":"native_install_session", "source":"current_candidate_job",
			"reason":str(session.get("reason", "")),
			"state":str(session.get("state", ""))}
	if not receipt.is_empty() and not bool(receipt.get("current", false)):
		return {"stage":"installed_receipt", "source":"current_receipt",
			"reason":"installed_receipt_not_current",
			"generation":int(receipt.get("generation", 0)),
			"contentManifestDigest":str(receipt.get("contentManifestDigest", ""))}
	return {}


func _sanitize_startup_admission_value(value: Variant) -> Variant:
	return _sanitize_json_value(value, {
		"remainingNodes":STARTUP_TREE_ADMISSION_DETAIL_NODE_LIMIT,
		"maxEntries":STARTUP_TREE_ADMISSION_DETAIL_ENTRY_LIMIT,
		"maxStringChars":STARTUP_TREE_ADMISSION_DETAIL_STRING_LIMIT,
		"maxDepth":STARTUP_TREE_ADMISSION_DETAIL_DEPTH_LIMIT}, 0)


func _sanitize_report_value(value: Variant) -> Variant:
	return _sanitize_json_value(value, {
		"remainingNodes":REPORT_JSON_NODE_LIMIT,
		"maxEntries":2048, "maxStringChars":4096, "maxDepth":16}, 0)


func _sanitize_json_value(value: Variant, budget: Dictionary, depth: int) -> Variant:
	var remaining := int(budget.get("remainingNodes", 0))
	if remaining <= 0:
		return "[omitted:node_limit]"
	budget["remainingNodes"] = remaining - 1
	var max_depth := int(budget.get("maxDepth", 0))
	if depth > max_depth:
		return "[omitted:depth_limit]"
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			return value if is_finite(float(value)) else null
		TYPE_STRING, TYPE_STRING_NAME:
			var text_value := String(value)
			var max_string := int(budget.get("maxStringChars", 0))
			return text_value.substr(0, max_string) if text_value.length() > max_string else text_value
		TYPE_VECTOR2:
			var vector2_value: Vector2 = value
			return [vector2_value.x, vector2_value.y] if vector2_value.is_finite() else null
		TYPE_VECTOR2I:
			var vector2i_value: Vector2i = value
			return [vector2i_value.x, vector2i_value.y]
		TYPE_VECTOR3:
			var vector3_value: Vector3 = value
			return [vector3_value.x, vector3_value.y, vector3_value.z] \
				if vector3_value.is_finite() else null
		TYPE_VECTOR3I:
			var vector3i_value: Vector3i = value
			return [vector3i_value.x, vector3i_value.y, vector3i_value.z]
		TYPE_ARRAY:
			var source_array: Array = value
			var result_array: Array = []
			var max_array_entries := int(budget.get("maxEntries", 0))
			for index: int in range(mini(source_array.size(), max_array_entries)):
				result_array.append(_sanitize_json_value(source_array[index], budget, depth + 1))
			if source_array.size() > max_array_entries:
				result_array.append("[omitted:entry_limit]")
			return result_array
		TYPE_DICTIONARY:
			var source_dictionary: Dictionary = value
			var result_dictionary := {}
			var max_dictionary_entries := int(budget.get("maxEntries", 0))
			var max_key_chars := int(budget.get("maxStringChars", 0))
			var emitted := 0
			for key: Variant in source_dictionary:
				if not key is String and not key is StringName:
					continue
				if emitted >= max_dictionary_entries:
					result_dictionary["_omitted"] = "entry_limit"
					break
				var safe_key := String(key).substr(0, max_key_chars)
				var collision_index := emitted
				while result_dictionary.has(safe_key):
					var suffix := "_%d" % collision_index
					safe_key = String(key).substr(0,
						maxi(0, max_key_chars - suffix.length())) + suffix
					collision_index += 1
				result_dictionary[safe_key] = _sanitize_json_value(
					source_dictionary[key], budget, depth + 1)
				emitted += 1
			return result_dictionary
		_:
			return "[omitted:%s]" % type_string(typeof(value))


## Confirms JSON parsing succeeds and the decoded tree contains only JSON-native
## values. It does not compare the decoded tree for lossless equality.
func _json_parse_yields_value_only_tree(value: Variant) -> bool:
	var encoded := JSON.stringify(value)
	if encoded.is_empty():
		return false
	var parser := JSON.new()
	if parser.parse(encoded) != OK:
		return false
	return _is_json_native_value(parser.data, {"remainingNodes":REPORT_JSON_NODE_LIMIT})


func _contains_sanitizer_marker(value: Variant, marker: String) -> bool:
	if value is String:
		return String(value) == marker
	if value is Array:
		for child: Variant in value:
			if _contains_sanitizer_marker(child, marker):
				return true
	elif value is Dictionary:
		for key: Variant in value:
			if _contains_sanitizer_marker(value[key], marker):
				return true
	return false


func _is_json_native_value(value: Variant, budget: Dictionary) -> bool:
	var remaining := int(budget.get("remainingNodes", 0))
	if remaining <= 0:
		return false
	budget["remainingNodes"] = remaining - 1
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_ARRAY:
			for entry: Variant in value:
				if not _is_json_native_value(entry, budget):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not key is String or not _is_json_native_value(value[key], budget):
					return false
			return true
		_:
			return false


func _run() -> void:
	run_started_msec = Time.get_ticks_msec()
	seed_text = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	report_path = OS.get_environment("VOXEL_ECOLOGY_HARVEST_REPLAY_REPORT")
	progress_path = OS.get_environment("VOXEL_ECOLOGY_HARVEST_REPLAY_PROGRESS")
	before_path = OS.get_environment("VOXEL_ECOLOGY_HARVEST_REPLAY_BEFORE")
	after_path = OS.get_environment("VOXEL_ECOLOGY_HARVEST_REPLAY_AFTER")
	_check("fixed_seed_and_tutorial_free_main", seed_text == FIXED_SEED \
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
	add_child(main)
	_write_progress("main_scene_instantiated", {
		"startupTimeoutSeconds":MAIN_STARTUP_TIMEOUT_SECONDS,
		"readinessDomains":main.get("startup_readiness_domains")})
	var launch_options: Dictionary = main.get("launch_options")
	_check("main_skips_tutorial", bool(launch_options.get("skipTutorial", false)), launch_options)
	var started_usec := Time.get_ticks_usec()
	var last_startup_progress_msec := 0
	var last_work_revision := int(main.get("startup_work_progress").get("completed_revision"))
	var last_work_progress_elapsed_msec := 0
	while is_inside_tree() and is_instance_valid(main) \
			and not startup_completion_observed and not startup_failure_observed:
		var startup_elapsed_msec := int((Time.get_ticks_usec() - started_usec) / 1000)
		var work_progress: Object = main.get("startup_work_progress") as Object
		var completed_work_revision := int(work_progress.get("completed_revision")) \
			if is_instance_valid(work_progress) else last_work_revision
		if completed_work_revision > last_work_revision:
			last_work_revision = completed_work_revision
			last_work_progress_elapsed_msec = startup_elapsed_msec
		if startup_elapsed_msec - last_startup_progress_msec >= 5000:
			last_startup_progress_msec = startup_elapsed_msec
			_write_progress("waiting_for_main_startup", {
				"elapsedMsec":startup_elapsed_msec,
				"startupTimeoutMsec":int(MAIN_STARTUP_TIMEOUT_SECONDS * 1000.0),
				"completedWorkRevision":completed_work_revision,
				"noProgressElapsedMsec":startup_elapsed_msec - last_work_progress_elapsed_msec,
				"readinessDomains":main.get("startup_readiness_domains"),
				"loadingFailure":main.get("startup_loading_failure_result")})
		if startup_elapsed_msec - last_work_progress_elapsed_msec \
				>= int(STARTUP_NO_PROGRESS_TIMEOUT_SECONDS * 1000.0):
			var progress_receipts_value: Variant = work_progress.get("receipts") \
				if is_instance_valid(work_progress) else []
			var progress_receipts: Array = progress_receipts_value \
				if progress_receipts_value is Array else []
			_check("main_startup_completed_before_bounded_no_progress_timeout", false, {
				"reason":"main_startup_no_completed_work",
				"startupElapsedMsec":startup_elapsed_msec,
				"noProgressElapsedMsec":startup_elapsed_msec - last_work_progress_elapsed_msec,
				"noProgressTimeoutMsec":int(STARTUP_NO_PROGRESS_TIMEOUT_SECONDS * 1000.0),
				"completedWorkRevision":completed_work_revision,
				"progressReceiptCount":progress_receipts.size(),
				"readinessDomains":main.get("startup_readiness_domains"),
				"loadingFailure":main.get("startup_loading_failure_result")})
			_write_progress("main_startup_no_progress_timeout", {
				"startupElapsedMsec":startup_elapsed_msec,
				"noProgressElapsedMsec":startup_elapsed_msec - last_work_progress_elapsed_msec,
				"completedWorkRevision":completed_work_revision,
				"progressReceiptCount":progress_receipts.size(),
				"readinessDomains":main.get("startup_readiness_domains"),
				"loadingFailure":main.get("startup_loading_failure_result")})
			_finish()
			return
		if startup_elapsed_msec >= int(MAIN_STARTUP_TIMEOUT_SECONDS * 1000.0):
			_check("main_startup_completed_before_bounded_timeout", false, {
				"reason":"main_startup_timeout",
				"elapsedMsec":startup_elapsed_msec,
				"startupTimeoutMsec":int(MAIN_STARTUP_TIMEOUT_SECONDS * 1000.0),
				"readinessDomains":main.get("startup_readiness_domains"),
				"loadingFailure":main.get("startup_loading_failure_result")})
			_write_progress("main_startup_timeout", {
				"elapsedMsec":startup_elapsed_msec,
				"readinessDomains":main.get("startup_readiness_domains"),
				"loadingFailure":main.get("startup_loading_failure_result")})
			_finish()
			return
		await get_tree().process_frame
	var gameplay_ready := startup_completion_observed and not startup_failure_observed \
		and String(main.get("startup_readiness_domains").get("gameplay", {}).get("status", "")) == "ready"
	_check("main_gameplay_ready", gameplay_ready, {
		"failure":main.get("startup_loading_failure_result"),
		"readinessDomains":main.get("startup_readiness_domains")})
	_write_progress("main_gameplay_ready" if gameplay_ready else "main_startup_failed", {
		"elapsedMsec":Time.get_ticks_msec() - run_started_msec,
		"readinessDomains":main.get("startup_readiness_domains"),
		"loadingFailure":main.get("startup_loading_failure_result")})
	if not gameplay_ready:
		_finish()
		return
	provider = main.get("ecology_static_section_provider") as Object
	coordinator = main.get("world_static_section_coordinator") as Object
	player = main.get("player") as CharacterBody3D
	camera = player.get("camera") as Camera3D if is_instance_valid(player) else null
	_check("production_provider_and_coordinator_bound", is_instance_valid(provider) \
		and is_instance_valid(coordinator) and provider.get("_world_id") == coordinator.get("_world_id"), {
		"providerWorldId":provider.get("_world_id") if is_instance_valid(provider) else "",
		"coordinatorWorldId":coordinator.get("_world_id") if is_instance_valid(coordinator) else ""})
	if not is_instance_valid(provider) or not is_instance_valid(coordinator) \
			or not is_instance_valid(player) or not is_instance_valid(camera):
		_finish()
		return

	var pair := await _wait_for_live_legacy_pair()
	_check("live_receipt_visible_generated_prop_found", pair.get("status") == "ready",
		_pair_summary(pair))
	if pair.get("status") != "ready":
		_finish()
		return
	var prop: Dictionary = pair.prop
	var candidate: Dictionary = prop.candidate
	selected_source_id = String(prop.get("sourceId", ""))
	selected_prop_id = String(prop.get("propId", ""))
	selected_chunk_key = prop.get("chunkKey", Vector2i.ZERO)
	selected_sections = _dict_section_keys(prop.get("sections", {}))
	var body := prop.get("body") as StaticBody3D
	var collision := prop.get("collision") as CollisionShape3D
	selected_world_position = body.global_position if is_instance_valid(body) else Vector3.INF
	var category := String(candidate.get("category", ""))
	var material_id := String(body.get_meta("material", "")) if is_instance_valid(body) else ""
	var tool_block := String(main.call("unmet_tool_requirement_message", material_id)) \
		if main.has_method("unmet_tool_requirement_message") else "gameplay_tool_check_missing"
	var drop_id := String(body.get_meta("drop", "")) if is_instance_valid(body) else ""
	_check("selected_prop_has_stable_identity_and_live_control_collider", \
		category in ["surface_rocks", "ore", "forage"] and not selected_source_id.is_empty() \
		and not selected_prop_id.is_empty() and is_instance_valid(body) \
		and body.get_meta("static_ecology_source_id", "") == selected_source_id \
		and body.get_meta("prop_id", "") == selected_prop_id \
		and is_instance_valid(collision) and collision.get_parent() == body and not collision.disabled \
		and not selected_sections.is_empty() and tool_block.is_empty(), {
		"category":category, "sourceId":selected_source_id, "propId":selected_prop_id,
		"chunkKey":_vec2_to_json(selected_chunk_key), "sections":_sections_to_json(selected_sections),
		"materialId":material_id, "toolRequirementBlock":tool_block,
		"drop":drop_id, "bodyInstanceId":body.get_instance_id() if is_instance_valid(body) else 0,
		"collisionInstanceId":collision.get_instance_id() if is_instance_valid(collision) else 0})
	if not checks["selected_prop_has_stable_identity_and_live_control_collider"].passed:
		_finish()
		return

	var control := _find_control_prop(selected_source_id)
	_check("independent_generated_control_prop_found", control.get("status") == "ready", control)
	if control.get("status") != "ready":
		_finish()
		return
	control_source_id = String(control.sourceId)
	control_prop_id = String(control.propId)
	control_chunk_key = control.chunkKey
	var control_body: StaticBody3D = control.body
	var control_collision: CollisionShape3D = control.collision
	control_body_instance_id = control_body.get_instance_id()
	control_collision_instance_id = control_collision.get_instance_id()

	var detail: Dictionary = pair.detail
	var detail_unit_id := String(detail.get("unitId", ""))
	var prop_unit_id := String(prop.get("unitId", ""))
	var units: Dictionary = provider.get("_latest_legacy_visual_units")
	var detail_unit: Dictionary = units.get(detail_unit_id, {})
	var prop_unit: Dictionary = units.get(prop_unit_id, {})
	var detail_revision := String(detail_unit.get("unitRevision", ""))
	var prop_revision := String(prop_unit.get("unitRevision", ""))
	var census: Dictionary = pair.get("census", {})
	_check("preharvest_source_census_and_owning_sections_current", census.get("status") == "complete" \
		and _census_covers_pair(census, detail, prop, pair.sections), {
		"sourceId":selected_source_id, "propId":selected_prop_id,
		"sections":_sections_to_json(pair.sections), "census":census,
		"receipts":_receipt_rows(pair.sections)})
	if not checks["preharvest_source_census_and_owning_sections_current"].passed:
		_finish()
		return

	var initial_receipt_wait: Dictionary = await _wait_for_receipts_and_retirement(
		pair.sections, detail, prop, _dict_section_keys(detail.sections),
		_dict_section_keys(prop.sections),
		detail_unit_id, prop_unit_id, detail_revision, prop_revision, 120.0)
	_check("preharvest_native_receipt_and_owner_body_current",
		initial_receipt_wait.get("status", "") == "ready"
		and is_instance_valid(body) and is_instance_valid(collision) and not collision.disabled,
		initial_receipt_wait)
	_write_progress("preharvest_receipts_current", initial_receipt_wait)
	if not checks["preharvest_native_receipt_and_owner_body_current"].passed:
		_finish()
		return

	var original_physics := player.is_physics_processing()
	player.set_physics_process(false)
	_aim_player_at_prop(body)
	await _wait_frames(3)
	var ray_range := float(main.call("monumental_tree_melee_ray_range")) \
		if main.has_method("monumental_tree_melee_ray_range") else 8.0
	var before_hit: Dictionary = player.view_ray(ray_range)
	var within_reach := bool(main.call("hit_within_action_reach", before_hit)) \
		if main.has_method("hit_within_action_reach") else false
	_check("real_gameplay_ray_targets_selected_prop", before_hit.get("collider") == body \
		and within_reach, {
		"sourceId":selected_source_id, "propId":selected_prop_id,
		"colliderInstanceId":before_hit.get("collider", null).get_instance_id() \
			if before_hit.get("collider", null) is Object else 0,
		"hitPosition":before_hit.get("position", Vector3.INF)})
	if not checks["real_gameplay_ray_targets_selected_prop"].passed:
		player.set_physics_process(original_physics)
		_finish()
		return
	await _capture_viewport(before_path)
	_trace("before_real_harvest_capture", {"path":before_path,
		"propId":selected_prop_id, "sourceId":selected_source_id,
		"bodyInstanceId":body.get_instance_id(), "collisionInstanceId":collision.get_instance_id(),
		"sections":_sections_to_json(selected_sections),
		"receipts":_receipt_rows(pair.sections)})

	var removed_before: Dictionary = main.get("removed_props")
	var revision_before := int(main.get("removed_props_revision"))
	var strikes := 0
	while strikes < MAX_HARVEST_STRIKES and not removed_before.has(selected_prop_id):
		# Calls the same public method invoked by MainWorldEntities on primary click.
		# Ray, tool/hardness, reward, tombstone and queue_free all remain production-owned.
		main.call("destroy_target")
		strikes += 1
		await get_tree().physics_frame
		removed_before = main.get("removed_props")
	var removed_revision := int(main.get("removed_props_revision"))
	_check("public_gameplay_harvest_records_durable_prop_id", removed_before.has(selected_prop_id) \
		and removed_revision > revision_before, {
		"invoke":"Main.destroy_target() public gameplay method",
		"strikes":strikes, "sourceId":selected_source_id, "propId":selected_prop_id,
		"removedPropsRevisionBefore":revision_before, "removedPropsRevisionAfter":removed_revision,
		"lastDestroyMetrics":main.get("last_destroy_target_metrics")})
	_write_progress("real_gameplay_harvest_recorded", {
		"propId":selected_prop_id, "sourceId":selected_source_id,
		"strikes":strikes, "removedPropsRevision":removed_revision,
		"passed":checks["public_gameplay_harvest_records_durable_prop_id"].passed})
	if not checks["public_gameplay_harvest_records_durable_prop_id"].passed:
		player.set_physics_process(original_physics)
		_finish()
		return
	await _wait_frames(2)
	_check("gameplay_owner_removes_harvested_body_and_keeps_control_body_live", \
		not is_instance_valid(body) and not is_instance_valid(collision) \
		and is_instance_valid(control_body) and control_body.get_instance_id() == control_body_instance_id \
		and is_instance_valid(control_collision) \
		and control_collision.get_instance_id() == control_collision_instance_id \
		and not control_collision.disabled, {
		"harvestedBodyGone":not is_instance_valid(body),
		"harvestedColliderGone":not is_instance_valid(collision),
		"controlPropId":control_prop_id,
		"controlBodyInstanceId":control_body.get_instance_id() if is_instance_valid(control_body) else 0,
		"controlCollisionInstanceId":control_collision.get_instance_id() \
			if is_instance_valid(control_collision) else 0})
	_trace("after_gameplay_harvest_before_replacement", {
		"harvestedPropId":selected_prop_id, "removedPropsRevision":removed_revision,
		"controlPropId":control_prop_id})

	var postharvest := await _wait_for_current_receipts_and_absence(
		pair.sections, selected_source_id, 90.0)
	_write_progress("harvested_source_absence_receipts", postharvest)
	_check("harvested_source_absent_with_current_native_replacement_receipts", \
		postharvest.get("status") == "ready", postharvest)
	if postharvest.get("status") != "ready":
		player.set_physics_process(original_physics)
		_finish()
		return
	await _capture_viewport(harvest_capture_path)
	_trace("after_harvest_receipt_capture", {"path":harvest_capture_path,
		"harvestedPropId":selected_prop_id, "removedPropsRevision":removed_revision,
		"receipts":postharvest.get("receipts", []),
		"controlPropId":control_prop_id})

	var saved := bool(main.call("save_world", false))
	var saved_snapshot: Dictionary = main.call("create_save_snapshot")
	var saved_ids: Array = saved_snapshot.get("removedProps", [])
	var save_base_path := OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges()
	var save_system: Object = main.get("save_system") as Object
	var persisted_slot_path := String(save_system.call("_slot_path", seed_text)) \
		if is_instance_valid(save_system) and save_system.has_method("_slot_path") else ""
	persisted_save_slot_path = persisted_slot_path
	var disk_snapshot: Dictionary = save_system.call("load", seed_text) if is_instance_valid(save_system) else {}
	var disk_ids: Array = disk_snapshot.get("removedProps", [])
	var expected_slot_prefix := save_base_path.trim_suffix(".bin") + "_slot_"
	var save_isolated_to_run := not save_base_path.is_empty() \
		and persisted_slot_path.begins_with(expected_slot_prefix) \
		and persisted_slot_path.get_base_dir() == save_base_path.get_base_dir()
	_check("isolated_main_save_contains_harvest_tombstone", saved \
		and saved_ids.has(selected_prop_id) and disk_ids.has(selected_prop_id) \
		and save_isolated_to_run and FileAccess.file_exists(persisted_slot_path), {
		"saveBasePath":save_base_path, "persistedSlotPath":persisted_slot_path,
		"saveIsolatedToRunDirectory":save_isolated_to_run,
		"saveReturned":saved, "snapshotIdsContainProp":saved_ids.has(selected_prop_id),
		"diskIdsContainProp":disk_ids.has(selected_prop_id),
		"savedBodyInstanceId":body.get_instance_id() if is_instance_valid(body) else 0,
		"saveFileBytes":FileAccess.get_file_as_bytes(persisted_slot_path).size() \
			if FileAccess.file_exists(persisted_slot_path) else 0})
	_write_progress("save_written_and_reopened", {
		"saveBasePath":save_base_path, "persistedSlotPath":persisted_slot_path,
		"saveIsolatedToRunDirectory":save_isolated_to_run,
		"diskIdsContainProp":disk_ids.has(selected_prop_id)})
	if not checks["isolated_main_save_contains_harvest_tombstone"].passed:
		player.set_physics_process(original_physics)
		_finish()
		return
	_trace("save_with_removed_prop", {"savePath":persisted_slot_path,
		"propId":selected_prop_id, "savedRevision":removed_revision,
		"diskRemovedPropsCount":disk_ids.size()})

	_write_progress("staged_reload_begin", {
		"savePath":persisted_slot_path, "propId":selected_prop_id})
	var loaded: bool = await main.call("try_load_world_staged", true)
	_write_progress("staged_reload_completed", {
		"loaded":loaded, "propId":selected_prop_id,
		"loadingFailure":main.get("startup_loading_failure_result")})
	_check("main_staged_save_load_succeeded", loaded, {
		"savingPropId":selected_prop_id, "loadingReason":main.get("startup_loading_failure_result"),
		"removedPropsAfterLoad":(main.get("removed_props") as Dictionary).keys()})
	if not loaded:
		player.set_physics_process(original_physics)
		_finish()
		return
	provider = main.get("ecology_static_section_provider") as Object
	coordinator = main.get("world_static_section_coordinator") as Object
	var loaded_removed: Dictionary = main.get("removed_props")
	var replay := await _wait_for_current_receipts_and_absence(
		pair.sections, selected_source_id, POST_REPLAY_TIMEOUT_SECONDS)
	var loaded_chunks: Dictionary = main.get("chunks")
	var loaded_chunk: Node3D = loaded_chunks.get(selected_chunk_key) as Node3D
	var loaded_control_chunk: Node3D = loaded_chunks.get(control_chunk_key) as Node3D
	var chunk_snapshot: Dictionary = loaded_chunk.get_meta("static_ecology_source_value_snapshot", {}) \
		if is_instance_valid(loaded_chunk) else {}
	var source_present_in_chunk := _snapshot_contains_prop(chunk_snapshot, selected_source_id, selected_prop_id)
	var body_after_replay := _find_prop_body(loaded_control_chunk, control_source_id, control_prop_id) \
		if is_instance_valid(loaded_control_chunk) else null
	var collider_after_replay := _find_enabled_collision(body_after_replay) \
		if is_instance_valid(body_after_replay) else null
	var census_after_replay: Dictionary = replay.get("census", {})
	_check("reload_preserves_tombstone_and_does_not_regenerate_harvested_prop", \
		loaded_removed.has(selected_prop_id) and not source_present_in_chunk \
		and replay.get("status") == "ready" \
		and not replay.get("capture", {}).get("sourceRevisions", {}).has(selected_source_id), {
		"propId":selected_prop_id, "sourceId":selected_source_id,
		"removedPropsAfterLoad":loaded_removed.keys(),
		"chunkKey":_vec2_to_json(selected_chunk_key), "controlChunkKey":_vec2_to_json(control_chunk_key),
		"chunkSnapshotStatus":chunk_snapshot.get("status", "missing"),
		"sourcePresentInRegeneratedChunk":source_present_in_chunk,
		"receiptStatus":replay.get("status", "missing"),
		"currentReceipts":replay.get("receipts", []),
		"censusStatus":census_after_replay.get("status", "missing")})
	_check("independent_control_prop_regenerates_with_live_body_and_collision", \
		is_instance_valid(body_after_replay) and is_instance_valid(collider_after_replay) \
		and not collider_after_replay.disabled \
		and body_after_replay.get_meta("prop_id", "") == control_prop_id \
		and body_after_replay.get_meta("static_ecology_source_id", "") == control_source_id, {
		"controlPropId":control_prop_id, "controlSourceId":control_source_id,
		"bodyInstanceIdAfterReload":body_after_replay.get_instance_id() \
			if is_instance_valid(body_after_replay) else 0,
		"oldBodyInstanceId":control_body_instance_id,
		"colliderInstanceIdAfterReload":collider_after_replay.get_instance_id() \
			if is_instance_valid(collider_after_replay) else 0,
		"oldColliderInstanceId":control_collision_instance_id})
	_write_progress("replay_checks_complete", {
		"harvestedPropAbsent":not source_present_in_chunk,
		"controlBodyLive":is_instance_valid(body_after_replay),
		"receiptStatus":replay.get("status", "missing"),
		"checkCount":checks.size()})
	if is_instance_valid(body_after_replay):
		var focus: Vector3 = selected_world_position.lerp(body_after_replay.global_position, 0.5)
		player.global_position = focus + Vector3(0.0, 1.2, 3.0)
		camera.global_position = player.global_position + Vector3.UP * 0.55
		camera.look_at(focus, Vector3.UP)
		await _wait_frames(3)
		await _capture_viewport(after_path)
		_trace("post_reload_control_capture", {"path":after_path,
			"harvestedPropId":selected_prop_id, "controlPropId":control_prop_id,
			"sourceAbsent":not source_present_in_chunk, "nativeReceipts":replay.get("receipts", [])})
	player.set_physics_process(original_physics)
	_finish()


func _aim_player_at_prop(body: StaticBody3D) -> void:
	var focus := body.global_position + Vector3.UP * 0.45
	player.global_position = focus + Vector3(0.0, 0.8, 2.5)
	player.velocity = Vector3.ZERO
	camera.global_position = player.global_position + Vector3(0.0, 0.65, 0.0)
	camera.look_at(focus, Vector3.UP)


func _find_control_prop(exclude_source_id: String) -> Dictionary:
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary:
		return {"status":"pending", "reason":"main_chunks_missing"}
	var removed: Dictionary = main.get("removed_props")
	for key_value: Variant in chunks_value:
		if not key_value is Vector2i:
			continue
		var key: Vector2i = key_value
		var chunk := chunks_value[key] as Node3D
		if not is_instance_valid(chunk) or key != selected_chunk_key:
			continue
		var snapshot: Dictionary = chunk.get_meta("static_ecology_source_value_snapshot", {})
		if snapshot.get("status") != "complete":
			continue
		for value: Variant in snapshot.get("candidates", []):
			if not value is Dictionary:
				continue
			var candidate: Dictionary = value
			if String(candidate.get("kind", "")) != "realized_static_prop":
				continue
			var source_id := String(candidate.get("sourceId", ""))
			var prop_id := String(candidate.get("propId", ""))
			if source_id.is_empty() or prop_id.is_empty() or source_id == exclude_source_id \
					or removed.has(prop_id):
				continue
			var body := _find_prop_body(chunk, source_id, prop_id)
			var collision := _find_enabled_collision(body)
			if is_instance_valid(body) and is_instance_valid(collision):
				return {"status":"ready", "sourceId":source_id, "propId":prop_id,
					"chunkKey":key, "body":body, "collision":collision,
					"category":candidate.get("category", "")}
	return {"status":"pending", "reason":"independent_generated_control_prop_not_found"}


func _snapshot_contains_prop(snapshot: Dictionary, source_id: String, prop_id: String) -> bool:
	for value: Variant in snapshot.get("candidates", []):
		if value is Dictionary and String(value.get("sourceId", "")) == source_id \
				and String(value.get("propId", "")) == prop_id:
			return true
	return false


func _wait_for_current_receipts_and_absence(sections: Array[Vector3i],
		source_id: String, timeout_seconds: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var last: Dictionary = {}
	while is_inside_tree() and Time.get_ticks_msec() < deadline:
		var receipts := _receipt_rows(sections)
		last = {"receipts":receipts}
		if Engine.get_process_frames() % 300 == 0 \
				and receipts.size() == sections.size() and _all_receipts_current(receipts):
			var capture: Dictionary = provider.call("capture_static_section_sources",
				String(provider.get("_world_id")), sections)
			var census: Dictionary = coordinator.call("capture_authoritative_source_census", sections)
			last["capture"] = capture
			last["census"] = census
			var source_absent: bool = capture.get("status") == "complete" \
				and not capture.get("sourceRevisions", {}).has(source_id)
			if source_absent and census.get("status") == "complete":
				return {"status":"ready", "capture":capture, "census":census,
					"receipts":receipts, "sourceAbsent":true}
		if Engine.get_process_frames() % 300 == 0:
			_write_progress("waiting_for_absence_and_current_receipts", {
				"sourceId":source_id, "last":last, "demands":_demand_rows(sections)})
		await get_tree().physics_frame
	return {"status":"pending", "reason":"source_absence_or_current_native_receipt_timeout",
		"capture":last.get("capture", {}), "census":last.get("census", {}),
		"receipts":last.get("receipts", []), "demandStates":_demand_rows(sections)}


func _finish() -> void:
	if finished:
		return
	finished = true
	_check("startup_tree_correlation_json_parse_value_only",
		_json_parse_yields_value_only_tree(last_startup_tree_section_correlation), {
			"fixedTreeIds":STARTUP_TREE_IDS.duplicate(),
			"correlationStatus":String(last_startup_tree_section_correlation.get("status", "not_emitted")),
			"sectionRowCount":(last_startup_tree_section_correlation.get("sections", []) as Array).size(),
			"verification":"JSON parse succeeded and decoded values are JSON-native; equality is not tested"})
	var long_admission_key := "k".repeat(STARTUP_TREE_ADMISSION_DETAIL_STRING_LIMIT + 20)
	var node_pressure: Array = []
	for _outer: int in range(16):
		var inner_values: Array = []
		for _inner: int in range(16):
			inner_values.append(1)
		node_pressure.append(inner_values)
	var admission_probe_source := {
		"position":Vector3(1.25, 2.5, 3.75), "unsupported":self,
		"nested":{"pending":true, "ids":["a", "b"],
			"objects":[self, Resource.new()]},
		"long":"x".repeat(STARTUP_TREE_ADMISSION_DETAIL_STRING_LIMIT + 20),
		"many":[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17],
		"deep":{"a":{"b":{"c":{"d":"cut off"}}}},
		"nodePressure":node_pressure}
	admission_probe_source[long_admission_key] = "bounded_key"
	var admission_probe: Variant = _sanitize_startup_admission_value(admission_probe_source)
	var bounded_long_key_found := false
	if admission_probe is Dictionary:
		for key: Variant in (admission_probe as Dictionary).keys():
			if String(key).begins_with("k") \
					and String(key).length() == STARTUP_TREE_ADMISSION_DETAIL_STRING_LIMIT:
				bounded_long_key_found = true
	var nested_probe: Dictionary = (admission_probe as Dictionary).get("nested", {}) \
		if admission_probe is Dictionary else {}
	var nested_objects: Array = nested_probe.get("objects", []) \
		if nested_probe.get("objects", []) is Array else []
	var deep_probe: Dictionary = (admission_probe as Dictionary).get("deep", {}) \
		if admission_probe is Dictionary else {}
	var deep_a: Dictionary = deep_probe.get("a", {}) if deep_probe.get("a", {}) is Dictionary else {}
	var deep_b: Dictionary = deep_a.get("b", {}) if deep_a.get("b", {}) is Dictionary else {}
	var deep_c: Dictionary = deep_b.get("c", {}) if deep_b.get("c", {}) is Dictionary else {}
	var many_probe: Array = (admission_probe as Dictionary).get("many", []) \
		if admission_probe is Dictionary else []
	_check("startup_tree_admission_sanitizer_bounded_json_parse_value_only",
		admission_probe is Dictionary \
			and (admission_probe as Dictionary).get("position", []) == [1.25, 2.5, 3.75] \
			and String((admission_probe as Dictionary).get("unsupported", "")) == "[omitted:Object]" \
			and String((admission_probe as Dictionary).get("long", "")).length() \
				== STARTUP_TREE_ADMISSION_DETAIL_STRING_LIMIT \
			and bounded_long_key_found \
			and many_probe.size() == STARTUP_TREE_ADMISSION_DETAIL_ENTRY_LIMIT + 1 \
			and nested_objects.size() == 2 \
			and String(nested_objects[0]) == "[omitted:Object]" \
			and String(nested_objects[1]) == "[omitted:Object]" \
			and String(deep_c.get("d", "")) == "[omitted:depth_limit]" \
			and _contains_sanitizer_marker(admission_probe, "[omitted:node_limit]") \
			and _json_parse_yields_value_only_tree(admission_probe), admission_probe)
	var passed := failures.is_empty()
	var world_id := String(coordinator.get("_world_id")) \
		if is_instance_valid(coordinator) else ""
	var report := {"schema":HARVEST_SCHEMA, "status":"complete" if passed else "failed",
		"passed":passed, "seed":seed_text, "worldId":world_id,
		"tutorialSkipped":bool(main.get("launch_options").get("skipTutorial", false)) \
			if is_instance_valid(main) else false,
		"checkCount":checks.size(), "checks":checks, "failures":failures,
		"trace":trace, "screenshots":{"beforeHarvest":before_path,
			"afterHarvest":harvest_capture_path, "afterSaveReload":after_path},
		"saveBasePath":OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE"),
		"savePath":persisted_save_slot_path,
		"propId":selected_prop_id, "sourceId":selected_source_id,
		"controlPropId":control_prop_id, "controlSourceId":control_source_id,
		"selectedWorldPosition":_vector3_to_json(selected_world_position),
		"evidenceLevel":"headed Main production prop harvest through destroy_target, isolated save and staged reload, authoritative absence and native receipts",
		"doesNotProve":"Broad headed parity or traversal, complete ecology-family census, other seeds/prop families, publisher retirement outside the selected sources, or runtime performance."}
	var sanitized_report: Variant = _sanitize_report_value(report)
	var report_parse_value_only := _json_parse_yields_value_only_tree(sanitized_report)
	_check("final_report_json_parse_value_only", report_parse_value_only, {
		"sanitizerNodeLimit":REPORT_JSON_NODE_LIMIT,
		"verification":"JSON parse succeeded and decoded values are JSON-native; equality is not tested",
		"serializedType":"Dictionary" if sanitized_report is Dictionary else type_string(typeof(sanitized_report))})
	passed = failures.is_empty()
	report["status"] = "complete" if passed else "failed"
	report["passed"] = passed
	report["checkCount"] = checks.size()
	report["checks"] = checks
	report["failures"] = failures
	sanitized_report = _sanitize_report_value(report)
	var report_text := JSON.stringify(sanitized_report, "  ")
	var report_parser := JSON.new()
	var final_report_value_only := report_parser.parse(report_text) == OK \
		and report_parser.data is Dictionary \
		and _is_json_native_value(report_parser.data, {"remainingNodes":REPORT_JSON_NODE_LIMIT})
	assert(final_report_value_only, "Ecology harvest report must round-trip as JSON-native values")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file == null:
			push_error("Could not write Main ecology harvest/replay report: " + report_path)
		else:
			file.store_string(report_text)
			file.close()
	_write_progress("finished", {"passed":passed, "checkCount":checks.size(),
		"failures":failures, "elapsedMsec":Time.get_ticks_msec() - run_started_msec})
	print("Ecology Main harvest/replay report: ", report_path)
	var exit_code := 0 if passed else 1
	if is_instance_valid(main) and main.has_method("request_graceful_quit"):
		main.call("request_graceful_quit", exit_code)
	else:
		get_tree().quit(exit_code)


func _vector3_to_json(value: Vector3) -> Variant:
	if not value.is_finite():
		return null
	return [value.x, value.y, value.z]
