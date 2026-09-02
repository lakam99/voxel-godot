extends SceneTree
## Actual prepared historical input plus explicitly synthetic compiler controls.
## All payloads, preparation, comparisons and disposal stay on one owned worker.
## No source generation, Nodes, publication, GPU or live acceptance.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Controls = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const BINDING := {"siteId":"metadata-contract", "sourceKey":"actual-source05", "generation":1}

class SyntheticPart extends RefCounted:
	var id := "synthetic"
	var kind := "wall"
	var collision_enabled := true
	var recipe: Dictionary = {}
	var snapshots := 0
	func snapshot() -> Dictionary:
		snapshots += 1
		# Deliberately returns caller aliases; production must isolate, not freeze.
		return {"id":id, "kind":kind, "recipe":recipe}

class SyntheticBlueprint extends RefCounted:
	var parts: Array = []

class Reject extends RefCounted:
	var target := ""
	var occurrence := 1
	var seen := 0
	var rejected := false
	var after_false := 0
	func advance(stage: String) -> bool:
		if rejected: after_false += 1
		if stage == target:
			seen += 1
			if seen == occurrence:
				rejected = true
				return false
		return true

static func all_frozen(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only(): return false
		for key in value:
			if typeof(key) > TYPE_NODE_PATH or not all_frozen(value[key]): return false
	elif value is Array:
		if not value.is_read_only(): return false
		for item in value:
			if not all_frozen(item): return false
	elif typeof(value) > TYPE_NODE_PATH:
		return false
	return true

static func byte_difference(expected: PackedByteArray, observed: PackedByteArray) -> Dictionary:
	var offsets: Array = []
	for index in mini(expected.size(), observed.size()):
		if expected[index] != observed[index] and offsets.size() < 24:
			offsets.append({"offset":index, "expected":expected[index], "observed":observed[index]})
	return {"expectedSize":expected.size(), "observedSize":observed.size(), "differences":offsets}

static func exact_bytes(value: Variant) -> PackedByteArray:
	# Test oracle uses native encode_var with initialized storage, not the
	# production binding helper. Explicit NodePath golden bytes below pin format.
	var bytes := PackedByteArray()
	bytes.resize(var_to_bytes(value).size())
	bytes.fill(0)
	bytes.encode_var(0, value)
	return bytes

static func synthetic(checks: Dictionary, diagnostics: Dictionary) -> void:
	var blueprint := SyntheticBlueprint.new()
	var first := SyntheticPart.new()
	first.id = "z-first"
	var typed_array: Array[int] = [3, 1, 2]
	var typed_dictionary: Dictionary[String, int] = {"z":2, "a":1}
	first.recipe = {"z":[{"inner":true}], "a":typed_array, "typed":typed_dictionary,
		"primitives":[null, false, 7, 1.5, &"name", NodePath("a/b"), Vector2(1,2), Vector3(1,2,3), Color.RED]}
	var second := SyntheticPart.new()
	second.id = "a-second"
	blueprint.parts = [first, second]
	var expected := exact_bytes(first.snapshot())
	first.snapshots = 0
	var output: Dictionary = Preparation._compile_static_records(blueprint)
	checks.synthetic_ready = output.ready
	checks.snapshot_once = first.snapshots == 1 and second.snapshots == 1
	var observed := exact_bytes(output.staticRecords[first.id])
	checks.typed_exact = observed == expected
	diagnostics["initialDifference"] = byte_difference(expected, observed)
	diagnostics["snapshotText"] = var_to_str(first.snapshot())
	diagnostics["frozenText"] = var_to_str(output.staticRecords[first.id])
	diagnostics["expectedHex"] = expected.hex_encode()
	diagnostics["observedHex"] = observed.hex_encode()
	var field_differences: Dictionary = {}
	for key in first.recipe:
		var original_bytes := var_to_bytes(first.recipe[key])
		var frozen_bytes := var_to_bytes(output.staticRecords[first.id].recipe[key])
		field_differences[key] = {"originalVsFrozen":byte_difference(original_bytes, frozen_bytes),
			"repeatOriginal":byte_difference(original_bytes, var_to_bytes(first.recipe[key])),
			"repeatFrozen":byte_difference(frozen_bytes, var_to_bytes(output.staticRecords[first.id].recipe[key]))}
	diagnostics["fields"] = field_differences
	checks.binding_exact = output.staticRecordBindings[first.id] == expected.hex_encode()
	checks.bindings_immutable_strings = typeof(output.staticRecordBindings[first.id]) == TYPE_STRING and all_frozen(output.staticRecordBindings)
	checks.map_order = output.staticRecords.keys() == [first.id, second.id] and output.staticRecordBindings.keys() == [first.id, second.id]
	checks.deep_frozen = all_frozen(output.staticRecords)
	checks.inputs_not_frozen = not first.recipe.is_read_only() and not first.recipe.z.is_read_only() and not typed_array.is_read_only()
	first.recipe.z[0].inner = false
	typed_array[0] = 99
	typed_dictionary.z = 88
	var after_mutation := exact_bytes(output.staticRecords[first.id])
	checks.caller_alias_isolated = after_mutation == expected
	diagnostics["afterMutationDifference"] = byte_difference(expected, after_mutation)
	var noop: Dictionary = Preparation._compile_static_records(blueprint, func(_stage: String) -> bool: return true)
	var empty: Dictionary = Preparation._compile_static_records(blueprint, Callable())
	var omitted: Dictionary = Preparation._compile_static_records(blueprint)
	var noop_bytes := exact_bytes([noop.staticRecords, noop.staticRecordBindings])
	var empty_bytes := exact_bytes([empty.staticRecords, empty.staticRecordBindings])
	var omitted_bytes := exact_bytes([omitted.staticRecords, omitted.staticRecordBindings])
	checks.default_empty_true_exact = noop_bytes == empty_bytes and empty_bytes == omitted_bytes
	diagnostics["modeDifference"] = byte_difference(noop_bytes, empty_bytes)
	diagnostics["omittedDifference"] = byte_difference(empty_bytes, omitted_bytes)
	var repeated_differences: Array = []
	for index in 32:
		var repeated := var_to_bytes(first.recipe.primitives)
		var again := var_to_bytes(first.recipe.primitives)
		if repeated != again and repeated_differences.size() < 4:
			repeated_differences.append(byte_difference(repeated, again))
	diagnostics["repeatedPrimitiveEncodingDifferences"] = repeated_differences
	var path := NodePath("a/b")
	var golden := "1600000002000080000000000000000001000000610000000100000062000000".hex_decode()
	checks.node_path_explicit_golden = exact_bytes(path) == golden
	var poison := golden.duplicate()
	poison.fill(165)
	poison.encode_var(0, path)
	var padding_offsets: Array = []
	for index in poison.size():
		if poison[index] != golden[index]: padding_offsets.append(index)
	diagnostics["nativeNodePathUnwrittenPaddingOffsets"] = padding_offsets
	checks.node_path_poison_only_padding = padding_offsets == [21,22,23,29,30,31] and bytes_to_var(poison) == path
	checks.node_path_binding_exact = Preparation.static_record_binding({"path":path}) == exact_bytes({"path":path}).hex_encode()
	var stable_binding := Preparation.static_record_binding({"path":path})
	var stable := true
	for index in 32: stable = stable and Preparation.static_record_binding({"path":path}) == stable_binding
	checks.node_path_repeated_binding_stable = stable
	checks.binding_distinguishes_string_name = Preparation.static_record_binding({"x":&"a"}) != Preparation.static_record_binding({"x":"a"})
	checks.binding_distinguishes_node_path = Preparation.static_record_binding({"x":path}) != Preparation.static_record_binding({"x":"a/b"})
	checks.binding_distinguishes_typed_array = Preparation.static_record_binding({"x":typed_array}) != Preparation.static_record_binding({"x":[99,1,2]})
	checks.binding_distinguishes_typed_dictionary = Preparation.static_record_binding({"x":typed_dictionary}) != Preparation.static_record_binding({"x":{"z":88,"a":1}})
	checks.binding_distinguishes_order = Preparation.static_record_binding({"z":1,"a":2}) != Preparation.static_record_binding({"a":2,"z":1})
	var door := SyntheticPart.new()
	door.id = "door"; door.kind = "door"
	var visual := SyntheticPart.new()
	visual.id = "visual"; visual.collision_enabled = false
	blueprint.parts = [door, visual, null]
	output = Preparation._compile_static_records(blueprint)
	checks.exclusions = output.ready and output.staticRecords.is_empty() and door.snapshots == 0 and visual.snapshots == 0
	var bad := SyntheticPart.new()
	var packed_cases: Array = [PackedByteArray([1]), PackedInt32Array([1]), PackedInt64Array([1]),
		PackedFloat32Array([1.0]), PackedFloat64Array([1.0]), PackedStringArray(["a"]),
		PackedVector2Array([Vector2.ZERO]), PackedVector3Array([Vector3.ZERO]),
		PackedColorArray([Color.RED]), PackedVector4Array([Vector4.ZERO])]
	var unsupported: Array = packed_cases + [Resource.new(), RefCounted.new(), RID(), Callable(), Signal()]
	for index in unsupported.size():
		bad.recipe = {"unsupported":unsupported[index]}
		bad.snapshots = 0
		blueprint.parts = [first, bad]
		output = Preparation._compile_static_records(blueprint)
		checks["unsupported_%d_omitted" % index] = output.ready and output.staticRecords.keys() == [first.id] \
			and output.staticRecordBindings.keys() == [first.id] and not bad.recipe.is_read_only() and bad.snapshots == 0
	var array_key: Array = [1]
	bad.recipe = {array_key:"not immutable key"}
	output = Preparation._compile_static_records(blueprint)
	checks.container_key_omitted = output.ready and not output.staticRecords.has(bad.id) and not array_key.is_read_only()
	var typed_objects: Array[Resource] = []
	bad.recipe = {"typedObjects":typed_objects}
	output = Preparation._compile_static_records(blueprint)
	checks.empty_object_typed_container_omitted = output.ready and not output.staticRecords.has(bad.id)
	var cycle: Array = []
	cycle.append(cycle)
	bad.recipe = {"cycle":cycle}
	output = Preparation._compile_static_records(blueprint)
	checks.cycle_omitted = output.ready and not output.staticRecords.has(bad.id) and not cycle.is_read_only()
	cycle.clear() # Break synthetic cycle explicitly on this worker.
	var deep: Array = []
	var cursor: Array = deep
	for index in Preparation.METADATA_MAX_DEPTH + 1:
		var child: Array = []
		cursor.append(child)
		cursor = child
	bad.recipe = {"deep":deep}
	output = Preparation._compile_static_records(blueprint)
	checks.depth_omitted = output.ready and not output.staticRecords.has(bad.id)
	bad.id = first.id
	output = Preparation._compile_static_records(blueprint)
	checks.duplicate_unsupported_id_failed_no_partial = output == {"ready":false,"reason":"duplicate_static_record_id"}
	blueprint.parts = [first, second]
	for stage in ["publication_metadata_started", "publication_metadata_part", "publication_metadata_walk", "publication_metadata_record_encoded", "publication_metadata_completed"]:
		var rejection := Reject.new()
		rejection.target = stage
		if stage in ["publication_metadata_part", "publication_metadata_walk", "publication_metadata_record_encoded"]: rejection.occurrence = 2
		output = Preparation._compile_static_records(blueprint, rejection.advance)
		checks[stage + "_cancelled_no_partial"] = output == {"ready":false,"reason":"cancelled"}
		checks[stage + "_no_later_callback"] = rejection.rejected and rejection.after_false == 0
	var small: Dictionary = Controls.source()
	for stage in ["publication_metadata_started", "publication_metadata_completed", "publication_preparation_ready"]:
		var rejection := Reject.new()
		rejection.target = stage
		output = Preparation.prepare_source(small.blueprint, small.furnishingPlan, BINDING, rejection.advance)
		checks[stage + "_public_cancel"] = output == {"ready":false,"reason":"cancelled"} and rejection.rejected and rejection.after_false == 0

static func run_worker(guard: Worker.RunState) -> Dictionary:
	guard.begin_work()
	var checks: Dictionary = {}
	var report := {"schema":"building-prepared-metadata/v1", "checks":checks,
		"workerThreadId":OS.get_thread_caller_id(), "sourceSha256":FileAccess.get_sha256(INPUT),
		"evidence":"Actual post-diagnostic prepared metadata plus synthetic isolation/cancellation controls; no scene/GPU/runtime acceptance."}
	checks.source_hash = report.sourceSha256 == SHA
	if not checks.source_hash: return report
	var diagnostics: Dictionary = {}
	synthetic(checks, diagnostics)
	report["syntheticDiagnostics"] = diagnostics
	if OS.get_environment("BUILDING_PREPARED_METADATA_SYNTHETIC_ONLY") == "1":
		report["evidence"] = "Synthetic-only compiler diagnosis; actual source not loaded or prepared."
		return report
	var file := FileAccess.open(INPUT, FileAccess.READ)
	if file == null:
		checks.source_open = false
		return report
	var source: Dictionary = file.get_var(false)
	file.close()
	Controls.freeze(source)
	var output: Dictionary = Preparation.prepare_source(source.blueprint, source.furnishingPlan, BINDING, guard.advance)
	checks.actual_prepared = output.get("ready", false)
	if not checks.actual_prepared: return report
	var wrong := BINDING.duplicate()
	wrong.generation += 1
	checks.wrong_binding_not_consumed = output.prepared.take(wrong).is_empty()
	var payload: Dictionary = output.prepared.take(BINDING)
	checks.correct_binding_consumed = not payload.is_empty()
	checks.one_shot = output.prepared.take(BINDING).is_empty()
	if payload.is_empty(): return report
	var count := 0
	var exact := true
	var encoded_exact := true
	var max_bytes := 0
	var order: Array = []
	for part in payload.blueprint.parts:
		if not guard.advance("metadata_contract_compare"):
			checks.cancelled = false
			return report
		if part == null or not part.collision_enabled or String(part.kind) == "door": continue
		count += 1
		order.append(String(part.id))
		var encoded := var_to_bytes(part.snapshot())
		max_bytes = maxi(max_bytes, encoded.size())
		exact = exact and payload.staticRecords.has(part.id) and var_to_bytes(payload.staticRecords.get(part.id)) == encoded
		encoded_exact = encoded_exact and payload.staticRecordBindings.get(part.id) == encoded.hex_encode()
	checks.actual_3159_records = count == 3159 and payload.staticRecords.size() == count and payload.staticRecordBindings.size() == count
	checks.actual_postdiagnostic_exact = exact
	checks.actual_encoded_bindings_exact = encoded_exact
	checks.actual_typed_order = payload.staticRecords.keys() == order and payload.staticRecordBindings.keys() == order
	checks.actual_deep_frozen = all_frozen(payload.staticRecords) and all_frozen(payload.staticRecordBindings)
	checks.actual_max_encoded_bytes = max_bytes == 6316
	checks.metadata_timed = payload.metadataPreparationUsec >= 0
	checks.source_hash_unchanged = FileAccess.get_sha256(INPUT) == SHA
	report["recordCount"] = count
	report["maxRecordEncodedBytes"] = max_bytes
	report["metadataPreparationUsec"] = payload.metadataPreparationUsec
	report["diagnosticPreparationUsec"] = payload.preparationUsec
	# Only small report data returns; all large payload aliases die on this worker.
	return report

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := OS.get_environment("BUILDING_PREPARED_METADATA_OUTPUT")
	if output.is_empty(): quit(2); return
	var worker := Thread.new()
	var guard := Worker.RunState.new()
	var started := Time.get_ticks_msec()
	if worker.start(run_worker.bind(guard)) != OK: quit(2); return
	var next_progress := started + 5000
	var timed_out := false
	while worker.is_alive():
		if Time.get_ticks_msec()-started > 75000:
			timed_out = true
			guard.cancel()
		if Time.get_ticks_msec() >= next_progress:
			print("PREPARED METADATA progress ", JSON.stringify(guard.snapshot()))
			next_progress = Time.get_ticks_msec() + 5000
		await process_frame
	var report: Dictionary = worker.wait_to_finish()
	report.checks.worker_joined = not worker.is_started()
	report.checks.off_main = report.workerThreadId != OS.get_thread_caller_id()
	report.checks.within_deadline = not timed_out
	var passed := 0
	for key in report.checks:
		if report.checks[key]: passed += 1
		else: print("PREPARED METADATA FAILURE ", key)
	report["passed"] = passed == report.checks.size()
	report["passedCount"] = passed
	report["checkCount"] = report.checks.size()
	report["elapsedMsec"] = Time.get_ticks_msec()-started
	report["preparationSha256"] = FileAccess.get_sha256("res://scripts/buildings/BuildingPublicationPreparation.gd")
	report["contractSha256"] = FileAccess.get_sha256("res://scripts/testing/buildings/BuildingPreparedMetadataContract.gd")
	DirAccess.make_dir_recursive_absolute(output)
	var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("PREPARED METADATA ", passed, "/", report.checks.size(), " records=", report.get("recordCount",0))
	quit(0 if report.passed else 1)
