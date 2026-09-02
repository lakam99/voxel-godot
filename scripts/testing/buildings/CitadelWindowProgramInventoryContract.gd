extends SceneTree

## Small synthetic identity contract. No world, renderer, physics or Phase-B run.
const Blueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const BuildingPart := preload("res://scripts/buildings/BuildingPart.gd")
const FurnishingPlan := preload("res://scripts/buildings/FurnishingPlan.gd")
const FurnishingPart := preload("res://scripts/buildings/FurnishingPart.gd")
const Interior := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const Codec := preload("res://scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd")
const Copy := preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const HELPER_PATH := "res://scripts/testing/buildings/CitadelWindowProgramInventory.gd"
const PHASE_B_PATH := "res://scripts/testing/buildings/CitadelStructuralCompletionComposerPhaseBContract.gd"


func _initialize() -> void:
	var report_path := OS.get_environment("VOXEL_CITADEL_WINDOW_INVENTORY_REPORT").simplify_path()
	if not report_path.is_absolute_path() or report_path.begins_with("res://") or report_path.begins_with("user://") \
			or FileAccess.file_exists(report_path) or DirAccess.dir_exists_absolute(report_path) \
			or not DirAccess.dir_exists_absolute(report_path.get_base_dir()):
		quit(2)
		return
	# Dynamic loads let compile-guard failures become report checks. Never new()
	# Phase B: that would execute its independent checkpoint/acceptance workflow.
	var helper: Variant = load(HELPER_PATH)
	var phase_b: Variant = load(PHASE_B_PATH)
	var checks := {"helper_can_instantiate": helper is Script and helper.can_instantiate(),
		"phase_b_can_instantiate": phase_b is Script and phase_b.can_instantiate()}
	var cases := {}
	if checks.helper_can_instantiate:
		for count: int in [1, 3]:
			var fixture := _fixture(count)
			_check(helper, fixture, "valid_%d_windows" % count, "", checks, cases)
			var inventory: Dictionary = cases["valid_%d_windows" % count]
			var expected_ids: Array = []
			for index in range(count):
				expected_ids.append("window_%d" % index)
			checks["exact_counts_and_ids_%d" % count] = inventory.windowCount == count \
				and inventory.programPartCount == count * 2 and inventory.windowIds == expected_ids
		var extra := _fixture(2)
		extra.plan.add_part({"id": "ordinary_table", "archetype": "table", "roomId": "room_0"})
		# Archetypes alone are not program membership: ordinary plants/candles exist.
		extra.plan.add_part({"id": "ordinary_plant", "archetype": "pot_plant", "roomId": "room_0"})
		extra.plan.add_part({"id": "ordinary_candle", "archetype": "candle", "roomId": "room_0"})
		_check(helper, extra, "unrelated_furniture_allowed", "", checks, cases)
		checks["only_program_parts_counted"] = cases.unrelated_furniture_allowed.programPartCount == 4 and extra.plan.parts.size() == 7
		var spatial := _fixture(1)
		spatial.blueprint.parts[0].recipe.clear()
		spatial.blueprint.parts[0].position = Vector3(0.0, 2.0, 2.0)
		_check(helper, spatial, "current_spatial_room_api", "", checks, cases)
		_check(helper, _fixture(0), "empty_windows", "empty_windows", checks, cases)
		var controls := {
			"missing_member": "missing_program_member", "duplicate_member": "duplicate_furnishing_id",
			"orphan_member": "orphan_program_part", "wrong_role": "wrong_program_archetype",
			"wrong_member_id": "unexpected_program_part_id", "wrong_room": "program_room_mismatch",
			"missing_reference": "invalid_furnishing_window_id", "empty_reference": "invalid_furnishing_window_id",
			"numeric_reference": "invalid_furnishing_window_id", "hidden_semantic": "invalid_furnishing_window_id",
			"hidden_recipe_semantic": "invalid_furnishing_window_id", "hidden_schema": "invalid_furnishing_window_id",
			"duplicate_unrelated_id": "duplicate_furnishing_id", "empty_furniture_id": "invalid_furnishing_id",
			"duplicate_window": "duplicate_window_id", "empty_window_id": "invalid_window_id",
			"padded_window_id": "invalid_window_id", "missing_aperture": "missing_aperture",
			"duplicate_aperture": "duplicate_aperture", "orphan_aperture": "orphan_aperture",
			"wrong_aperture_room": "aperture_room_mismatch", "empty_aperture_id": "invalid_aperture",
			"numeric_aperture_id": "invalid_aperture", "invalid_aperture_room": "invalid_aperture",
			"missing_program": "", "malformed_program": "invalid_aperture_program",
			"malformed_apertures": "invalid_aperture_program", "malformed_aperture": "invalid_aperture",
			"malformed_blueprint_part": "invalid_blueprint_part", "null_blueprint_part": "invalid_blueprint_part",
			"malformed_furniture": "invalid_furnishing_part", "null_furniture": "invalid_furnishing_part",
			"malformed_room": "invalid_room", "malformed_bounds": "invalid_room",
			"numeric_room_id": "invalid_room", "duplicate_room": "duplicate_room_id",
			"invalid_room_bounds": "invalid_room_bounds", "malformed_declared_room": "invalid_window_binding",
			"malformed_inward": "invalid_window_binding", "malformed_offset": "invalid_window_binding",
			"unresolved_room": "unresolved_window_room", "nonfinite_position": "invalid_window_binding",
			"malformed_semantic": "invalid_furnishing_semantic",
			"room_limit": "input_limit", "furniture_limit": "input_limit",
			"window_limit": "window_limit", "aperture_limit": "aperture_limit", "source_limit": "input_limit"}
		for control: String in controls:
			var fixture := _fixture(2)
			_mutate(fixture, control)
			_check(helper, fixture, control, controls[control], checks, cases)
		for invalid: Variant in [null, {}, 7, RefCounted.new()]:
			var fixture := _fixture(1)
			var index := cases.size()
			var bad_blueprint: Dictionary = helper.inspect(invalid, fixture.plan)
			var bad_plan: Dictionary = helper.inspect(fixture.blueprint, invalid)
			checks["invalid_inputs_%d" % index] = bad_blueprint.ready == false and bad_blueprint.reason == "invalid_inputs" \
				and bad_plan.ready == false and bad_plan.reason == "invalid_inputs"
			cases["invalid_inputs_%d" % index] = {"blueprint": bad_blueprint, "plan": bad_plan}
		# Valid exact-cap inventories, not null-filled arrays masquerading as data.
		var exact_pairs := _fixture(2048)
		_check(helper, exact_pairs, "valid_exact_furniture_cap", "", checks, cases)
		checks["exact_furniture_cap_count"] = cases.valid_exact_furniture_cap.programPartCount == 4096
		exact_pairs.plan.add_part({"id": "overflow_table", "archetype": "table", "roomId": "room_0"})
		_check(helper, exact_pairs, "valid_furniture_cap_plus_one", "input_limit", checks, cases)
		var exact_rooms := _fixture(1)
		for index in range(1, 4096):
			exact_rooms.blueprint.rooms.append({"id": "spare_room_%d" % index,
				"bounds": AABB(Vector3(index * 10.0, 0, 0), Vector3(4, 4, 4))})
		_check(helper, exact_rooms, "valid_exact_room_cap", "", checks, cases)
		exact_rooms.blueprint.rooms.append({"id": "overflow_room", "bounds": AABB(Vector3(50000, 0, 0), Vector3(4, 4, 4))})
		_check(helper, exact_rooms, "valid_room_cap_plus_one", "input_limit", checks, cases)
		if checks.phase_b_can_instantiate:
			for control: String in ["malformed_declared_room", "malformed_inward", "malformed_offset", "missing_aperture"]:
				var fixture := _fixture(1)
				_mutate(fixture, control)
				var before := _state(fixture)
				var refused: Dictionary = phase_b.inspect_window_program(fixture.blueprint, fixture.plan)
				checks["caller_stops_" + control] = refused.get("ready") == false \
					and refused.get("auditPerformed") == false and not refused.has("audit") \
					and before == _state(fixture)
				cases["caller_stops_" + control] = refused
			var valid_caller := _fixture(2)
			var caller_before := _state(valid_caller)
			var inspected: Dictionary = phase_b.inspect_window_program(valid_caller.blueprint, valid_caller.plan)
			checks["caller_valid_runs_private_audit"] = inspected.get("ready") == true \
				and inspected.get("auditPerformed") == true and inspected.get("audit", {}).get("passed") == true \
				and inspected.get("planUnchanged") == true and caller_before == _state(valid_caller)
			# Match the real composer: derived aperture annotations live on its
			# private furnishing copy, not the unchanged authoritative blueprint.
			valid_caller.blueprint.recipe.erase("interiorProgram")
			caller_before = _state(valid_caller)
			var absent_cache: Dictionary = phase_b.inspect_window_program(valid_caller.blueprint, valid_caller.plan)
			checks["caller_absent_cache_uses_actual_windows_and_existing_pairs"] = absent_cache.get("ready") == true \
				and absent_cache.get("audit", {}).get("passed") == true and absent_cache.get("planUnchanged") == true \
				and absent_cache.inventory.apertureCachePresent == false and absent_cache.derivedInventory.apertureCachePresent == true \
				and absent_cache.derivedInventory.windowIds == ["window_0", "window_1"] and caller_before == _state(valid_caller)
			valid_caller.plan.parts.remove_at(0)
			caller_before = _state(valid_caller)
			var missing_pair: Dictionary = phase_b.inspect_window_program(valid_caller.blueprint, valid_caller.plan)
			checks["caller_absent_cache_never_repairs_missing_furniture"] = missing_pair.get("ready") == false \
				and missing_pair.get("auditPerformed") == false and missing_pair.inventory.reason == "missing_program_member" \
				and caller_before == _state(valid_caller)
	var diagnostic := {}
	checks["checkpoint_probe_rejects_oversize_before_read"] = _oversized_probe_control(report_path + ".oversized.bin")
	if checks.helper_can_instantiate and checks.phase_b_can_instantiate:
		diagnostic = _checkpoint_probe(phase_b, checks)
	var report := {"schema": "citadel_window_program_inventory_contract/v1",
		"passed": checks.values().all(func(value): return value == true), "checks": checks, "cases": cases,
		"checkpointDiagnostic": diagnostic,
		"scope": "Synthetic read-only inventory and script compile guards only; no Phase-B execution, publication, geometry, rendering, gameplay or NPC/navigation acceptance."}
	# A caller must supply a fresh absolute destination; never overwrite a report.
	if FileAccess.file_exists(report_path):
		quit(2)
		return
	var output := FileAccess.open(report_path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.flush()
	var write_error := output.get_error()
	output.close()
	quit(2 if write_error != OK else 0 if report.passed else 1)


func _checkpoint_probe(phase_b: Script, checks: Dictionary) -> Dictionary:
	var path := OS.get_environment("VOXEL_CITADEL_WINDOW_INVENTORY_CHECKPOINT")
	if path.is_empty(): return {}
	var expected_sha := OS.get_environment("VOXEL_CITADEL_WINDOW_INVENTORY_CHECKPOINT_SHA256").to_lower()
	var seed := int(OS.get_environment("VOXEL_CITADEL_WINDOW_INVENTORY_SEED"))
	var evidence := {"scope": "SHA-bound old-checkpoint window diagnostic only; NOT source/engine binding or Phase B acceptance", "path": path, "seed": seed}
	var read := _read_checkpoint_bounded(path)
	var bytes: PackedByteArray = read.get("bytes", PackedByteArray())
	checks["diagnostic:exact_input_sha"] = read.ready \
		and expected_sha.length() == 64 and Codec.sha256_bytes(bytes) == expected_sha and seed != 0
	if not checks["diagnostic:exact_input_sha"]: return evidence
	var decoded := Codec.decode_payload(bytes, expected_sha, seed)
	checks["diagnostic:decoded"] = decoded.ready
	if not decoded.ready: return evidence
	var payload: Dictionary = decoded.payload.payload
	var blueprint = Copy.copy_blueprint(payload.blueprintSnapshot)
	var stored: Dictionary = payload.furnishingSnapshot
	var plan := FurnishingPlan.new(stored.id, int(stored.seed), stored.sourceBlueprintId)
	for row: Dictionary in stored.parts: plan.parts.append(FurnishingPart.new(row))
	plan.protected_access_reservations.append_array(payload.furnishingReservations)
	plan.egress_diagnostics = stored.get("egressDiagnostics", {}).duplicate(true)
	checks["diagnostic:exact_reconstruction"] = Codec.hash_variant(blueprint.snapshot()) == payload.sectionHashes.blueprintSnapshot \
		and Codec.hash_variant(plan.snapshot()) == payload.sectionHashes.furnishingSnapshot
	if not checks["diagnostic:exact_reconstruction"]: return evidence
	var fixture := {"blueprint": blueprint, "plan": plan}
	var before := _state(fixture)
	var inspected: Dictionary = phase_b.inspect_window_program(blueprint, plan)
	checks["diagnostic:existing_pairs_and_private_audit"] = inspected.get("ready") == true \
		and inspected.get("audit", {}).get("passed") == true and inspected.get("planUnchanged") == true
	checks["diagnostic:source_unchanged"] = before == _state(fixture)
	evidence["sha256"] = expected_sha
	evidence["result"] = inspected
	return evidence


func _read_checkpoint_bounded(path: String) -> Dictionary:
	if not path.is_absolute_path(): return {"ready": false, "reason": "invalid_path"}
	var input := FileAccess.open(path, FileAccess.READ)
	if input == null: return {"ready": false, "reason": "open_failed"}
	var length := input.get_length()
	if length < Codec.FRAME_HEADER_BYTES or length > Codec.MAX_CHECKPOINT_BYTES:
		input.close()
		return {"ready": false, "reason": "length_limit"}
	var bytes := input.get_buffer(length)
	var complete := bytes.size() == length and input.get_error() == OK and input.get_length() == length
	input.close()
	return {"ready": true, "bytes": bytes} if complete else {"ready": false, "reason": "incomplete_read"}


func _oversized_probe_control(path: String) -> bool:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path): return false
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null: return false
	# Seek, then write one byte: no oversized buffer is allocated by the test.
	output.seek(Codec.MAX_CHECKPOINT_BYTES)
	output.store_8(0)
	output.flush()
	var written := output.get_error() == OK and output.get_length() == Codec.MAX_CHECKPOINT_BYTES + 1
	output.close()
	var rejected := _read_checkpoint_bounded(path)
	return written and rejected.get("ready") == false and rejected.get("reason") == "length_limit" and not rejected.has("bytes")


func _fixture(count: int) -> Dictionary:
	var blueprint := Blueprint.new("window-inventory-contract", 17, "citadel")
	var plan := FurnishingPlan.new("window-inventory-plan", 17, blueprint.id)
	for index in range(count):
		var origin := Vector3(index * 10.0, 0.0, 0.0)
		var room_id := "room_%d" % index
		blueprint.rooms.append({"id": room_id, "bounds": AABB(origin, Vector3(4.0, 4.0, 4.0))})
		blueprint.add_part({"id": "window_%d" % index, "kind": "window", "collision": false,
			"position": origin + Vector3(-0.48, 2.0, 2.0), "size": Vector3(0.1, 1.2, 0.9),
			"recipe": {"roomId": room_id, "interiorInwardDirection": Vector3.RIGHT, "interiorWallOffset": 0.48}})
	# The only mutating Interior API call: construction before the inspect act.
	Interior.apply_to_plan(blueprint, plan)
	return {"blueprint": blueprint, "plan": plan}


func _check(helper: Script, fixture: Dictionary, label: String, reason: String, checks: Dictionary, cases: Dictionary) -> void:
	var before := _state(fixture)
	var source_objects: Array = fixture.blueprint.parts.duplicate()
	var furniture_objects: Array = fixture.plan.parts.duplicate()
	var result: Dictionary = helper.inspect(fixture.blueprint, fixture.plan)
	cases[label] = result
	checks[label] = result.ready == reason.is_empty() and result.reason == reason \
		and result.get("details") is Dictionary and result.get("windowIds") is Array \
		and result.get("windowCount") is int and result.get("programPartCount") is int
	checks[label + "_inputs_unchanged"] = before == _state(fixture) \
		and source_objects == fixture.blueprint.parts and furniture_objects == fixture.plan.parts
	checks[label + "_repeatable"] = var_to_bytes(result) == var_to_bytes(helper.inspect(fixture.blueprint, fixture.plan)) \
		and before == _state(fixture)


func _state(fixture: Dictionary) -> PackedByteArray:
	# Do not use production snapshot() on deliberately malformed array rows.
	return var_to_bytes({"recipe": fixture.blueprint.recipe, "rooms": fixture.blueprint.rooms,
		"parts": _rows(fixture.blueprint.parts), "furniture": _rows(fixture.plan.parts),
		"reservations": fixture.plan.protected_access_reservations, "egress": fixture.plan.egress_diagnostics})


func _rows(rows: Array) -> Array:
	return rows.map(func(row): return row.snapshot() if row is BuildingPart or row is FurnishingPart else row)


func _mutate(fixture: Dictionary, control: String) -> void:
	var blueprint: Blueprint = fixture.blueprint
	var plan: FurnishingPlan = fixture.plan
	var apertures: Array = blueprint.recipe.interiorProgram.apertures
	match control:
		"missing_member": plan.parts.remove_at(0)
		"duplicate_member": plan.parts.append(FurnishingPart.new(plan.parts[0].snapshot()))
		"orphan_member": plan.parts[0].recipe.interiorProgramWindowId = "absent"
		"wrong_role": plan.parts[0].archetype = "candle"
		"wrong_member_id": plan.parts[0].id = "interior_window_window_0_other"
		"wrong_room": plan.parts[0].room_id = "room_1"
		"missing_reference": plan.parts[0].recipe.erase("interiorProgramWindowId")
		"empty_reference": plan.parts[0].recipe.interiorProgramWindowId = ""
		"numeric_reference": plan.parts[0].recipe.interiorProgramWindowId = 5
		"hidden_semantic", "hidden_recipe_semantic", "hidden_schema":
			var part := FurnishingPart.new({"id": "hidden_extra", "archetype": "candle"})
			if control == "hidden_semantic": part.semantic = "window_sill_candle"
			if control == "hidden_recipe_semantic": part.recipe.semantic = "window_sill_plant"
			if control == "hidden_schema": part.recipe.interiorProgramSchemaVersion = Interior.SCHEMA_VERSION
			plan.parts.append(part)
		"duplicate_unrelated_id":
			plan.add_part({"id": "ordinary_table", "archetype": "table"})
			plan.add_part({"id": "ordinary_table", "archetype": "table"})
		"empty_furniture_id": plan.parts[0].id = ""
		"duplicate_window": blueprint.parts.append(BuildingPart.new(blueprint.parts[0].snapshot()))
		"empty_window_id": blueprint.parts[0].id = ""
		"padded_window_id": blueprint.parts[0].id = " window_0 "
		"missing_aperture": apertures.remove_at(0)
		"duplicate_aperture": apertures.append(apertures[0].duplicate(true))
		"orphan_aperture": apertures[0].windowId = "absent"
		"wrong_aperture_room": apertures[0].roomId = "room_1"
		"empty_aperture_id": apertures[0].windowId = ""
		"numeric_aperture_id": apertures[0].windowId = 7
		"invalid_aperture_room": apertures[0].roomId = []
		"missing_program": blueprint.recipe.erase("interiorProgram")
		"malformed_program": blueprint.recipe.interiorProgram = 7
		"malformed_apertures": blueprint.recipe.interiorProgram.apertures = {}
		"malformed_aperture": apertures[0] = null
		"malformed_blueprint_part": blueprint.parts[0] = {"kind": "window"}
		"null_blueprint_part": blueprint.parts[0] = null
		"malformed_furniture": plan.parts[0] = {"id": "not_an_object"}
		"null_furniture": plan.parts[0] = null
		"malformed_room": blueprint.rooms[0] = 7
		"malformed_bounds": blueprint.rooms[0].bounds = []
		"numeric_room_id": blueprint.rooms[0].id = 7
		"duplicate_room": blueprint.rooms.append(blueprint.rooms[0].duplicate(true))
		"invalid_room_bounds": blueprint.rooms[0].bounds = AABB()
		"malformed_declared_room": blueprint.parts[0].recipe.roomId = []
		"malformed_inward": blueprint.parts[0].recipe.interiorInwardDirection = "right"
		"malformed_offset": blueprint.parts[0].recipe.interiorWallOffset = {}
		"unresolved_room": blueprint.parts[0].recipe.roomId = "absent"
		"nonfinite_position": blueprint.parts[0].position.x = NAN
		"malformed_semantic": plan.parts[0].recipe.semantic = []
		"room_limit": blueprint.rooms.resize(4097)
		"furniture_limit": plan.parts.resize(4097)
		"aperture_limit": apertures.resize(4097)
		"source_limit": blueprint.parts.resize(10001)
		"window_limit":
			# 4095 additions + the initial two exceed the inclusive 4096 bound.
			for index in range(4095):
				blueprint.add_part({"id": "extra_%d" % index, "kind": "window"})
