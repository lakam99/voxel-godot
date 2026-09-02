extends SceneTree

## SOURCE/SERVICE CONTRACT ONLY. No full castle build, publisher, actor or scene.
## cancellation: replay immutable real pre/post-opening geometry, reconstructing
## only missing producer metadata as in CitadelStructuralCompletionCurrentContract.
## parity: two ordinary add_street_house recipes, not hand-authored test geometry.
## Launch only after main authorizes the process-owning watchdog wrapper.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Structural = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const Facade = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")
const Heads = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const Lower = preload("res://scripts/buildings/LowerFacadeBearingRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Shop = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const ARCHIVE_SHA := "65149b8198ceaa52b19d27a1a8c2ee82edd5614e52bfd3d1e2cc65928e8b78cb"
const SOURCE_PATHS := [
	"res://scripts/buildings/CitadelStructuralCompletionRecipe.gd",
	"res://scripts/buildings/CitadelFacadeCompletionRecipe.gd",
	"res://scripts/buildings/OpeningHeadBandRecipe.gd",
	"res://scripts/buildings/LowerFacadeBearingRecipe.gd",
	"res://scripts/buildings/CitadelUrbanPocComposer.gd",
	"res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd",
	"res://scripts/testing/buildings/CitadelCompletionCancellationContract.gd",
]
const FORBIDDEN := ["candidate", "candidateSnapshot", "afterSnapshot", "beforeSnapshot",
	"snapshot", "blueprint", "proof", "_terminalProof", "state", "afterState", "stages",
	"accepted", "acceptedIds", "houseProposals", "furnitureSnapshot"]
var _checks: Dictionary = {}
var _cases: Array = []
var _fixture: Dictionary = {}
var _progress_path := ""
var _last_progress_key: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("CITADEL_COMPLETION_REPORT")
	_progress_path = OS.get_environment("CITADEL_COMPLETION_PROGRESS")
	var phase := OS.get_environment("CITADEL_COMPLETION_PHASE")
	if not _fresh_path(output) or not _fresh_path(_progress_path) or output == _progress_path or phase not in ["cancellation", "parity"]:
		quit(2)
		return
	var started := Time.get_ticks_usec()
	var hashes := _source_hashes()
	if phase == "cancellation":
		_cancellation()
	else:
		_parity()
	_checks["source_files_unchanged_during_run"] = hashes == _source_hashes()
	_checks["all_source_hashes_present"] = hashes.values().all(func(value): return String(value).length() == 64)
	var passed := not _checks.is_empty() and _checks.values().all(func(value): return value == true)
	var report := {"schema": "citadel_completion_cancellation_contract/v1", "phase": phase,
		"complete": true, "passed": passed, "checks": _checks, "cases": _cases,
		"fixture": _fixture, "sourceSha256": hashes, "engine": Engine.get_version_info(),
		"elapsedUsec": Time.get_ticks_usec() - started, "evidenceLevel": "source_service_contract_only",
		"doesNotProve": [
			"Both phases are required; cancellation replay alone does not prove successful continuation parity.",
			"No full CastleBuilder/compose_prepared/Site worker run, asynchronous queue cancellation, disposal or reuse proof.",
			"No bound on work inside an individual synchronous recipe/proof; timings are observations, not a latency guarantee.",
			"Archived geometry predates current production; fixture-only metadata reconstruction is not current whole-citadel equivalence.",
			"Small-recipe parity is not a full reference-snapshot regression or all-seed coverage.",
			"No rendering, physics traversal, terrain/publication, loading, save, NPC/navigation or headed acceptance. NPC baseline remains deferred."
		]}
	if not _write_json(output, report):
		quit(2)
		return
	print("CITADEL COMPLETION CONTRACT ", phase, ": ", "PASS" if passed else "FAIL", " checks=", JSON.stringify(_checks))
	quit(0 if passed else 1)

func _cancellation() -> void:
	var path := OS.get_environment("CITADEL_COMPLETION_ARCHIVE")
	var raw := _read_archive(path)
	_checks["archive_hash_and_canonical_payload_bound"] = not raw.is_empty()
	if raw.is_empty(): return
	var raw_bytes := var_to_bytes(raw)
	_fixture = {"kind": "immutable_opening_head_batch_06", "path": path, "sha256": ARCHIVE_SHA,
		"seed": raw.fixture.seed, "scale": raw.fixture.citadelScale,
		"beforePartCount": raw.beforeSnapshot.parts.size(), "afterPartCount": raw.afterSnapshot.parts.size(),
		"metadataReconstruction": "Only missing street-house manifest, through Manifest.declare; geometry/rooms remain byte-exact."}
	var before = Copy.copy_blueprint(raw.beforeSnapshot)
	var after = Copy.copy_blueprint(raw.afterSnapshot)
	var declared_before := _restore_manifest(before)
	var declared_after := _restore_manifest(after)
	_checks["both_archive_manifests_valid"] = declared_before and declared_after
	if not declared_before or not declared_after: return
	_checks["replay_does_not_rewrite_geometry_or_rooms"] = var_to_bytes(before.snapshot().parts) == var_to_bytes(raw.beforeSnapshot.parts) \
		and var_to_bytes(after.snapshot().parts) == var_to_bytes(raw.afterSnapshot.parts) \
		and var_to_bytes(before.rooms) == var_to_bytes(raw.beforeSnapshot.rooms) and var_to_bytes(after.rooms) == var_to_bytes(raw.afterSnapshot.rooms)
	var obstacles := Shop.furnishing_obstacles(raw.furnitureSnapshot, raw.protectedReservations)
	_checks["actual_furniture_obstacles_ready"] = obstacles.get("ready", false)
	if not obstacles.get("ready", false): return
	var policy := {"furnitureParts": raw.furnitureSnapshot.parts, "reservedVolumes": raw.protectedReservations,
		"protectedObstacles": obstacles.obstacles, "requiredHeadroom": 1.72}
	var membership := Copy.street_house_memberships(before)
	_checks["archive_has_multiple_real_houses"] = membership.ready and membership.houses.size() > 1
	if not membership.ready or membership.houses.size() < 2: return
	var first_house := String(membership.houses[0].prefix)
	var second_house := String(membership.houses[1].prefix)
	for api: String in ["structural", "later", "facade", "heads", "lower"]:
		_cancel_case(api + ":entry", api, after if api in ["later", "lower"] else before, policy, "", false)
	# Reject inside actual nested work, not a fabricated callback or a direct helper.
	for api: String in ["structural", "facade", "heads"]:
		_cancel_case(api + ":first_house_completed", api, before, policy, "opening_head_house_completed:" + first_house, false)
		_cancel_case(api + ":second_house", api, before, policy, "opening_head_house:" + second_house, false,
			"opening_head_house_completed:" + first_house)
	_cancel_case("lower:first_panel_completed", "lower", after, policy, "lower_facade_panel_completed:", true)
	_cancel_case("later:after_chimneys", "later", after, policy,
		OS.get_environment("CITADEL_COMPLETION_LATER_STAGE"), false)
	_checks["entire_archive_payload_unchanged"] = raw_bytes == var_to_bytes(raw)
	_checks["archive_file_unchanged"] = FileAccess.get_sha256(path) == ARCHIVE_SHA

func _restore_manifest(source) -> bool:
	if source.recipe.has(Manifest.KEY): return Manifest.read(source).get("ready", false)
	var membership := Copy.street_house_memberships(source)
	if not membership.ready: return false
	# Same explicit fixture replay grammar as CitadelStructuralCompletionCurrentContract.
	for house: Dictionary in membership.houses:
		var prefix := String(house.prefix)
		var sign := {}
		if Manifest.find_part(source, prefix + "_sign_arm") != null:
			sign = {"armId": prefix + "_sign_arm", "boardId": prefix + "_hanging_sign"}
		var declared := Manifest.declare(source, {"producerPrefix": prefix, "roomId": house.roomId,
			"doorId": house.doorId, "hoodId": prefix + "_door_hood",
			"threshold": {"id": prefix + "_door_threshold", "foundationId": prefix + "_foundation"},
			"bracketIds": [prefix + "_door_bracket_-66", prefix + "_door_bracket_66"],
			"chimney": {"id": prefix + "_chimney", "gableIds": [prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"],
				"upstreamIds": [prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"]},
			"facadeDeclarationKeys": [prefix + "_upper_facade"], "signAssembly": sign})
		if not declared.ready: return false
	return Manifest.read(source).get("ready", false)

func _cancel_case(name: String, api: String, source, policy: Dictionary, target: String, prefix: bool, prerequisite := "") -> void:
	var frozen := var_to_bytes(source.snapshot())
	var frozen_policy := var_to_bytes(policy)
	var aliases: Array = source.parts.duplicate()
	var trace := {"name": name, "target": target, "events": [], "rejected": false, "callbacksAfterRejection": 0,
		"startedUsec": Time.get_ticks_usec(), "rejectionIndex": -1}
	var callback := func(stage: String) -> bool:
		if trace.rejected: trace.callbacksAfterRejection += 1
		var reject: bool = target.is_empty() or (stage.begins_with(target) if prefix else stage == target)
		var allowed: bool = not trace.rejected and not reject
		if not allowed and not trace.rejected:
			trace.rejected = true
			trace.rejectionIndex = trace.events.size()
		trace.events.append({"stage": stage, "allowed": allowed, "elapsedUsec": Time.get_ticks_usec() - int(trace.startedUsec)})
		_note(name, stage, allowed)
		return allowed
	print("CITADEL COMPLETION CASE ", name)
	var result := _invoke(api, source, policy, callback, true)
	_checks[name + ":public_exact_cancelled"] = result == {"ready": false, "reason": "cancelled"}
	_checks[name + ":target_reached_once_and_no_later_callbacks"] = trace.rejected and trace.callbacksAfterRejection == 0 \
		and trace.events.size() == int(trace.rejectionIndex) + 1
	_checks[name + ":source_and_policy_byte_exact"] = frozen == var_to_bytes(source.snapshot()) and frozen_policy == var_to_bytes(policy)
	_checks[name + ":source_part_aliases_retained"] = _same_aliases(source.parts, aliases)
	if target.is_empty():
		var entries := {"structural": "structural_started", "later": "structural_later_started",
			"facade": "facade_started", "heads": "opening_heads_started", "lower": "lower_facade_started"}
		_checks[name + ":exact_entry_stage"] = trace.events.size() == 1 and trace.events[0].stage == entries[api]
	var leaks: Array = []
	_find_leaks(result, "$", leaks)
	_checks[name + ":no_snapshot_object_or_partial_success"] = leaks.is_empty()
	if not prerequisite.is_empty():
		_checks[name + ":prior_real_house_completed"] = trace.events.any(func(event): return event.stage == prerequisite and event.allowed)
	if target.begins_with("lower_facade_panel_completed:") and trace.rejected:
		var panel_id := String(trace.events.back().stage).trim_prefix(target)
		_checks[name + ":actual_source_panel_attempted"] = not panel_id.is_empty() and Manifest.find_part(source, panel_id) != null \
			and trace.events.any(func(event): return event.stage == "lower_facade_panel:" + panel_id and event.allowed)
	_cases.append({"name": name, "api": api, "target": target, "trace": trace, "result": result,
		"leaks": leaks, "elapsedUsec": Time.get_ticks_usec() - int(trace.startedUsec)})

func _parity() -> void:
	var source = Blueprint.new("completion_two_real_houses", 208159, "timber")
	source.set_recipe({"foundationHeight": 0.62, "courtyardResidences": []})
	for index in range(2):
		Urban.add_street_house(source, "completion_house_%02d" % index, Vector3(-7.0, 0.0, float(index) * 24.0),
			8.65, 9.45, 6.2, 1.0, 0.62, "painted_brick_cream", 0.05)
	var frames: Dictionary = Urban.add_roof_frames(source)
	_checks["real_two_house_roof_frames_ready"] = frames.get("ready", false)
	_checks["real_two_house_manifest_ready"] = Manifest.read(source).get("ready", false)
	_fixture = {"kind": "actual_add_street_house_and_roof_frames", "seed": 208159, "houseCount": 2,
		"partCount": source.parts.size(), "furniturePolicy": "Empty external furniture/reservations; producer household source parts retained."}
	if not frames.get("ready", false) or not Manifest.read(source).get("ready", false): return
	var policy := {"furnitureParts": [], "reservedVolumes": [], "protectedObstacles": [], "requiredHeadroom": 1.72}
	var heads := _parity_case("heads", source, policy)
	var facade := _parity_case("facade", source, policy)
	_parity_case("structural", source, policy)
	if heads.get("ready", false): _parity_case("lower", Copy.copy_blueprint(heads.candidateSnapshot), policy)
	else: _checks["lower_parity_input_ready"] = false
	if facade.get("ready", false): _parity_case("later", Copy.copy_blueprint(facade.afterSnapshot), policy)
	else: _checks["later_parity_input_ready"] = false
	_progress_semantics(source, policy, heads)
	_failure_controls(source, policy)

func _parity_case(api: String, source, policy: Dictionary) -> Dictionary:
	var frozen := var_to_bytes(source.snapshot())
	var frozen_policy := var_to_bytes(policy)
	var events: Array = []
	var callback := func(stage: String) -> bool:
		events.append(stage)
		_note("parity:" + api, stage, true)
		return true
	var started := Time.get_ticks_usec()
	# No normalization of results: complete typed output, including diagnostics.
	var legacy := _invoke(api, source, policy, Callable(), false)
	var explicit_empty := _invoke(api, source, policy, Callable(), true)
	var continued := _invoke(api, source, policy, callback, true)
	_checks[api + ":parity_requires_success_not_equal_failures"] = legacy.get("ready", false) and explicit_empty.get("ready", false) and continued.get("ready", false)
	_checks[api + ":all_result_bytes_exact"] = var_to_bytes(legacy) == var_to_bytes(explicit_empty) and var_to_bytes(legacy) == var_to_bytes(continued)
	_checks[api + ":continuation_exercised"] = not events.is_empty()
	_checks[api + ":parity_inputs_byte_exact"] = frozen == var_to_bytes(source.snapshot()) and frozen_policy == var_to_bytes(policy)
	_cases.append({"name": "parity:" + api, "stages": events, "ready": continued.get("ready", false),
		"failureReason": continued.get("reason", ""), "resultSha256": _digest(var_to_bytes(continued)),
		"elapsedUsec": Time.get_ticks_usec() - started})
	if continued.get("ready", false):
		var terminal := {"heads": "opening_heads_completed", "lower": "lower_facade_completed",
			"facade": "facade_completed", "later": "structural_later_completed", "structural": "structural_completed"}
		_cancel_case(api + ":final_precommit", api, source, policy, terminal[api], false)
	return legacy

func _progress_semantics(source, policy: Dictionary, expected: Dictionary) -> void:
	var calls: Array = []
	var progress := func(house: String) -> bool:
		calls.append(house)
		return false # Existing observer return value must remain ignored.
	var observed_policy := policy.duplicate(true)
	observed_policy["progressCallback"] = progress
	var frozen := var_to_bytes(observed_policy)
	var source_frozen := var_to_bytes(source.snapshot())
	var continuation_calls: Array = []
	var continuation := func(stage: String) -> bool:
		continuation_calls.append(stage)
		return true
	var without_continuation := Heads.prepare_all_first_rows(source, observed_policy)
	var first_calls := calls.duplicate()
	calls.clear()
	var result := Heads.prepare_all_first_rows(source, observed_policy, continuation)
	var expected_houses: Array = Copy.street_house_memberships(source).houses.map(func(house): return house.prefix)
	_checks["progress_false_is_observer_not_cancellation"] = expected.get("ready", false) and result.get("ready", false) \
		and var_to_bytes(result) == var_to_bytes(expected) and var_to_bytes(without_continuation) == var_to_bytes(expected)
	_checks["progress_sorted_house_sequence_unchanged"] = calls == expected_houses and first_calls == expected_houses
	_checks["progress_policy_and_source_preserved"] = frozen == var_to_bytes(observed_policy) and observed_policy.progressCallback == progress and source_frozen == var_to_bytes(source.snapshot())
	_checks["progress_and_continuation_both_invoked"] = not continuation_calls.is_empty() and calls.size() == 2
	# A normal void observer must also remain an observer, not a truth test.
	calls.clear()
	var void_progress := func(house: String) -> void: calls.append(house)
	observed_policy.progressCallback = void_progress
	var void_result := Heads.prepare_all_first_rows(source, observed_policy, continuation)
	_checks["void_progress_notifications_unchanged"] = var_to_bytes(void_result) == var_to_bytes(expected) and calls == expected_houses

func _failure_controls(source, policy: Dictionary) -> void:
	var allow := func(_stage: String) -> bool: return true
	var invalid_policy := {"progressCallback": 17}
	var reasons := {"structural": "invalid_structural_completion_input", "later": "invalid_later_completion_input",
		"facade": "invalid_facade_completion_input", "heads": "invalid_progress_callback"}
	var frozen := var_to_bytes(source.snapshot())
	for api: String in reasons:
		var omitted := _invoke(api, source, invalid_policy, Callable(), false)
		var continued := _invoke(api, source, invalid_policy, allow, true)
		_checks[api + ":genuine_failure_classification_preserved"] = not omitted.get("ready", true) \
			and omitted.get("reason") == reasons[api] and var_to_bytes(omitted) == var_to_bytes(continued)
	var lower_omitted := Lower.prepare_all_bottom_rows({}, policy)
	var lower_continued := Lower.prepare_all_bottom_rows({}, policy, allow)
	_checks["lower:genuine_failure_classification_preserved"] = lower_omitted == {"ready": false, "reason": "invalid_completion_source"} \
		and lower_continued == lower_omitted
	_checks["genuine_failure_source_preserved"] = frozen == var_to_bytes(source.snapshot())

func _invoke(api: String, source, policy: Dictionary, continuation: Callable, supply_third: bool) -> Dictionary:
	match api:
		"structural": return Structural.prepare(source, policy, continuation) if supply_third else Structural.prepare(source, policy)
		"later": return Structural.prepare_later(source, policy, continuation) if supply_third else Structural.prepare_later(source, policy)
		"facade": return Facade.prepare(source, policy, continuation) if supply_third else Facade.prepare(source, policy)
		"heads": return Heads.prepare_all_first_rows(source, policy, continuation) if supply_third else Heads.prepare_all_first_rows(source, policy)
		"lower":
			var snapshot: Dictionary = source.snapshot()
			var frozen := var_to_bytes(snapshot)
			var result := Lower.prepare_all_bottom_rows(snapshot, policy, continuation) if supply_third else Lower.prepare_all_bottom_rows(snapshot, policy)
			_checks["lower:actual_dictionary_argument_preserved_every_call"] = _checks.get("lower:actual_dictionary_argument_preserved_every_call", true) and frozen == var_to_bytes(snapshot)
			return result
	return {"ready": false, "reason": "unknown_contract_api"}

func _read_archive(path: String) -> Dictionary:
	if not path.is_absolute_path() or FileAccess.get_sha256(path) != ARCHIVE_SHA: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	if file.get_length() <= 0 or file.get_length() > 32 * 1024 * 1024:
		file.close()
		return {}
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var value: Variant = bytes_to_var(bytes)
	if not value is Dictionary or var_to_bytes(value) != bytes: return {}
	for key in ["beforeSnapshot", "afterSnapshot", "furnitureSnapshot", "fixture"]:
		if not value.get(key) is Dictionary: return {}
	if not value.get("protectedReservations") is Array or value.fixture.get("seed") != 208159 or value.fixture.get("citadelScale") != 1.25: return {}
	if not value.beforeSnapshot.get("parts") is Array or not value.afterSnapshot.get("parts") is Array: return {}
	return value

func _same_aliases(parts: Array, aliases: Array) -> bool:
	if parts.size() != aliases.size(): return false
	for index in range(parts.size()):
		if not is_same(parts[index], aliases[index]): return false
	return true

func _find_leaks(value: Variant, path: String, leaks: Array) -> void:
	if value is Object: leaks.append(path + ":object")
	elif value is Dictionary:
		for key in value:
			var next := path + "." + String(key)
			if String(key) in FORBIDDEN: leaks.append(next)
			_find_leaks(value[key], next, leaks)
	elif value is Array:
		for index in range(value.size()): _find_leaks(value[index], path + "[%d]" % index, leaks)

func _note(name: String, stage: String, allowed: bool) -> void:
	# Callers record every callback before this presentation-only coalescing.
	# A changed case, stage or decision always emits, including cancellation.
	var key := [name, stage, allowed]
	if key == _last_progress_key: return
	_last_progress_key = key
	print("CITADEL COMPLETION STAGE ", name, " ", stage, " allowed=", allowed)
	if not _write_json(_progress_path, {"case": name, "stage": stage, "allowed": allowed, "completedCases": _cases.size()}):
		_checks["progress_write_succeeded"] = false

func _fresh_path(path: String) -> bool:
	return path.is_absolute_path() and not FileAccess.file_exists(path) and DirAccess.dir_exists_absolute(path.get_base_dir())

func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(value, "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	return error == OK

func _source_hashes() -> Dictionary:
	var hashes := {}
	for path in SOURCE_PATHS: hashes[path] = FileAccess.get_sha256(path)
	return hashes

func _digest(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK: return ""
	return context.finish().hex_encode()
