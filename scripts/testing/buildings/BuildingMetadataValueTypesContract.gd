extends SceneTree
## Read-only service inventory: historical frozen source -> actual preparation
## -> the same collision-enabled, non-door part.snapshot() records published by
## BuildingPartPublisher. All loading, preparation, traversal and large releases
## occur on one owned worker. No Source rebuild, scene Nodes, or GPU resources.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Controls = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const INPUT_SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const SAMPLE_LIMIT := 8
const DEPTH_LIMIT := 128
const VALUE_TYPES := [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING,
	TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_RECT2, TYPE_RECT2I, TYPE_VECTOR3, TYPE_VECTOR3I,
	TYPE_TRANSFORM2D, TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_PLANE, TYPE_QUATERNION,
	TYPE_AABB, TYPE_BASIS, TYPE_TRANSFORM3D, TYPE_PROJECTION, TYPE_COLOR,
	TYPE_STRING_NAME, TYPE_NODE_PATH]
const PACKED_ELEMENTS := {TYPE_PACKED_BYTE_ARRAY:TYPE_INT, TYPE_PACKED_INT32_ARRAY:TYPE_INT,
	TYPE_PACKED_INT64_ARRAY:TYPE_INT, TYPE_PACKED_FLOAT32_ARRAY:TYPE_FLOAT,
	TYPE_PACKED_FLOAT64_ARRAY:TYPE_FLOAT, TYPE_PACKED_STRING_ARRAY:TYPE_STRING,
	TYPE_PACKED_VECTOR2_ARRAY:TYPE_VECTOR2, TYPE_PACKED_VECTOR3_ARRAY:TYPE_VECTOR3,
	TYPE_PACKED_COLOR_ARRAY:TYPE_COLOR, TYPE_PACKED_VECTOR4_ARRAY:TYPE_VECTOR4}

class Inventory extends RefCounted:
	var guard: Worker.RunState
	var types: Dictionary = {}
	var key_types: Dictionary = {}
	var packed_elements: Dictionary = {}
	var issues: Dictionary = {}
	var issue_paths: Dictionary = {}
	var object_classes: Dictionary = {}
	var values := 0
	var dictionary_keys := 0
	var dictionaries := 0
	var arrays := 0
	var mutable_containers := 0
	var packed_arrays := 0
	var objects := 0
	var resources := 0
	var cycles := 0
	var max_depth := 0
	var max_container_size := 0
	var unsafe_to_encode := 0
	var current_record_unsupported := false

	func count(table: Dictionary, key: String, amount := 1) -> void:
		table[key] = int(table.get(key, 0)) + amount

	func issue(kind: String, path: String) -> void:
		current_record_unsupported = true
		count(issues, kind)
		if not issue_paths.has(kind): issue_paths[kind] = []
		if issue_paths[kind].size() < SAMPLE_LIMIT: issue_paths[kind].append(path.left(384))

	func visit(value: Variant, path: String, ancestors: Array, is_key := false, depth := 0) -> bool:
		values += 1
		if values % 1024 == 0 and not guard.advance("metadata_value_inventory"): return false
		var kind := typeof(value)
		var name := type_string(kind)
		count(types, name)
		if is_key:
			dictionary_keys += 1
			count(key_types, name)
		max_depth = maxi(max_depth, depth)
		if kind == TYPE_DICTIONARY or kind == TYPE_ARRAY:
			if is_key: issue("container_dictionary_key", path)
			if kind == TYPE_DICTIONARY: dictionaries += 1
			else: arrays += 1
			if not value.is_read_only(): mutable_containers += 1
			max_container_size = maxi(max_container_size, value.size())
			for ancestor in ancestors:
				if is_same(value, ancestor):
					cycles += 1
					unsafe_to_encode += 1
					issue("container_cycle", path)
					return true
			if depth >= DEPTH_LIMIT:
				unsafe_to_encode += 1
				issue("depth_limit_uninspected", path)
				return true
			ancestors.append(value)
			var complete := true
			var index := 0
			if kind == TYPE_DICTIONARY:
				for key in value:
					if not visit(key, path + "{key#%d}" % index, ancestors, true, depth + 1):
						complete = false
						break
					var label := String(key).left(96) if key is String or key is StringName else "value#%d" % index
					if not visit(value[key], path + "." + label, ancestors, false, depth + 1):
						complete = false
						break
					index += 1
			else:
				for item in value:
					if not visit(item, path + "[%d]" % index, ancestors, false, depth + 1):
						complete = false
						break
					index += 1
			ancestors.pop_back()
			return complete
		if PACKED_ELEMENTS.has(kind):
			packed_arrays += 1
			count(packed_elements, type_string(PACKED_ELEMENTS[kind]), value.size())
			max_container_size = maxi(max_container_size, value.size())
			# Packed arrays are NOT accepted on assumptions about copy-on-write,
			# strong caller aliases, or read-only parent dictionaries. No mutation
			# probe is performed against actual records; exclusion is conservative.
			issue("packed_array_excluded:" + name, path)
			return true
		if kind == TYPE_OBJECT:
			objects += 1
			unsafe_to_encode += 1
			if is_instance_valid(value):
				count(object_classes, value.get_class())
				if value is Resource: resources += 1
			issue("object_or_resource", path)
			return true # Never traverse Object properties or invoke their scripts.
		if kind not in VALUE_TYPES:
			unsafe_to_encode += 1
			issue("unhandled_type:" + name, path)
		return true

	func report() -> Dictionary:
		return {"valueOccurrences":values, "typeCounts":types, "dictionaryKeyCount":dictionary_keys,
			"dictionaryKeyTypeCounts":key_types, "dictionaryCount":dictionaries, "arrayCount":arrays,
			"mutableArrayDictionaryCount":mutable_containers, "packedArrayCount":packed_arrays,
			"packedElementTypeCounts":packed_elements, "objectCount":objects, "resourceCount":resources,
			"objectClassCounts":object_classes, "cycleCount":cycles, "maxDepth":max_depth,
			"maxContainerElements":max_container_size, "unhandledCounts":issues, "unhandledExamples":issue_paths,
			"eligibleForRecursiveContainerFreeze":issues.is_empty(),
			"countSemantics":"Occurrences include dictionary keys and repeated aliases; active-path cycles stop traversal. Packed elements are counted separately by their fixed element type."}


static func inventory_on_worker(guard: Worker.RunState) -> Dictionary:
	guard.begin_work()
	var report := {"schema":"building-metadata-value-types/v1", "complete":false,
		"evidence":"historical actual input -> real prepare_source -> pre-publication static collision snapshots",
		"sourcePath":INPUT, "sourceSha256":FileAccess.get_sha256(INPUT),
		"workerThreadId":OS.get_thread_caller_id(), "reason":""}
	if report.sourceSha256 != INPUT_SHA:
		report.reason = "source_hash_mismatch"
		return report
	var file := FileAccess.open(INPUT, FileAccess.READ)
	if file == null:
		report.reason = "source_open_failed"
		return report
	var source: Variant = file.get_var(false)
	file.close()
	if not source is Dictionary or source.get("status") != "prepared":
		report.reason = "invalid_source_envelope"
		return report
	# This SHA-bound fixture is the previously validated typed source; freezing
	# its inputs is preparation setup, not a new world/source generation pass.
	Controls.freeze(source)
	report["sourceIdentity"] = {"siteId":source.profile.siteId,
		"sourceSignature":source.profile.get("sourceSignature", ""),
		"blueprintId":source.blueprint.get("id", ""), "profileOrigin":str(source.profile.get("origin"))}
	var binding: Dictionary = {"siteId":source.profile.siteId, "sourceKey":"metadata-inventory:" + INPUT_SHA, "generation":1}
	var prepared: Dictionary = Preparation.prepare_source(source.blueprint, source.furnishingPlan, binding, guard.advance)
	if not prepared.get("ready", false):
		report.reason = String(prepared.get("reason", "preparation_failed"))
		return report
	var payload: Dictionary = prepared.prepared.take(binding)
	if payload.is_empty():
		report.reason = "prepared_holder_not_consumed"
		return report
	report["preparationUsec"] = payload.preparationUsec
	report["routeUsec"] = payload.routeUsec
	report["physicalUsec"] = payload.physicalUsec
	report["preparedPartCount"] = payload.blueprint.parts.size()
	var inventory := Inventory.new()
	inventory.guard = guard
	var records := 0
	var encoded := 0
	var encoded_skipped := 0
	var total_bytes := 0
	var max_bytes := 0
	var max_part := ""
	var unsupported_records := 0
	for part in payload.blueprint.parts:
		if not guard.advance("metadata_record_inventory"):
			report.reason = "cancelled"
			break
		if part == null or not part.collision_enabled or String(part.kind) == "door": continue
		# Exact publisher source record, after BOTH existing preparation resolutions.
		var record: Dictionary = part.snapshot()
		var unsafe_before := inventory.unsafe_to_encode
		inventory.current_record_unsupported = false
		if not inventory.visit(record, String(part.id), []):
			report.reason = "cancelled"
			break
		records += 1
		if inventory.current_record_unsupported: unsupported_records += 1
		if inventory.unsafe_to_encode != unsafe_before:
			encoded_skipped += 1
			continue # Never serialize cyclic/uninspected graphs or Object values.
		var size := var_to_bytes(record).size()
		encoded += 1
		total_bytes += size
		if size > max_bytes:
			max_bytes = size
			max_part = String(part.id)
	report["inventory"] = inventory.report()
	report["recordCount"] = records
	report["unsupportedRecordCount"] = unsupported_records
	report["encodedRecordCount"] = encoded
	report["encodedSkippedRecordCount"] = encoded_skipped
	report["totalRecordEncodedBytes"] = total_bytes
	report["maxRecordEncodedBytes"] = max_bytes
	report["maxRecordPartId"] = max_part
	report["sourceHashUnchanged"] = FileAccess.get_sha256(INPUT) == INPUT_SHA
	report["complete"] = report.reason.is_empty() and report.sourceHashUnchanged and records > 0 \
		and not inventory.issues.has("depth_limit_uninspected")
	report["limits"] = {"depth":DEPTH_LIMIT, "examplesPerIssue":SAMPLE_LIMIT,
		"packedArrays":"Excluded even where COW might isolate a particular operation; no caller-alias safety claim.",
		"scope":"Inventory describes exact prepared records, not already-frozen published caches or runtime acceptance. Array/Dictionary mutability alone is expected before copying/freezing; Objects, packed arrays, cycles and unsupported key/value types are excluded."}
	# All source, holder, snapshots and blueprint aliases are locals, never bound
	# into the Thread callable. They are released on this worker before it exits;
	# only the bounded scalar/count/path report crosses back to the main thread.
	return report


func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := OS.get_environment("BUILDING_METADATA_VALUE_TYPES_OUTPUT")
	if output.is_empty():
		print("METADATA VALUE TYPES requires BUILDING_METADATA_VALUE_TYPES_OUTPUT")
		quit(2)
		return
	var guard := Worker.RunState.new()
	var worker := Thread.new()
	var started := Time.get_ticks_msec()
	var error := worker.start(inventory_on_worker.bind(guard))
	if error != OK:
		print("METADATA VALUE TYPES worker start failed: ", error)
		quit(2)
		return
	var next_progress := started + 5000
	var timeout_requested := false
	while worker.is_alive():
		if Time.get_ticks_msec() - started > 75000 and not timeout_requested:
			timeout_requested = true
			guard.cancel()
		if Time.get_ticks_msec() >= next_progress:
			print("METADATA VALUE TYPES progress ", JSON.stringify(guard.snapshot()))
			next_progress = Time.get_ticks_msec() + 5000
		await process_frame
	var report: Dictionary = worker.wait_to_finish() # Join terminal worker only.
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report["ownedWorkerJoined"] = not worker.is_started()
	report["preparedAndInspectedOffMain"] = report.workerThreadId != OS.get_thread_caller_id()
	report["timeoutRequested"] = timeout_requested
	report["contractSha256"] = FileAccess.get_sha256("res://scripts/testing/buildings/BuildingMetadataValueTypesContract.gd")
	DirAccess.make_dir_recursive_absolute(output)
	var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	if file == null:
		print("METADATA VALUE TYPES report open failed: ", FileAccess.get_open_error())
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	var ok: bool = report.complete and report.ownedWorkerJoined and report.preparedAndInspectedOffMain and not timeout_requested
	print("METADATA VALUE TYPES complete=", ok, " records=", report.get("recordCount", 0),
		" maxRecordBytes=", report.get("maxRecordEncodedBytes", 0), " unsupportedRecords=", report.get("unsupportedRecordCount", 0))
	quit(0 if ok else 1)
