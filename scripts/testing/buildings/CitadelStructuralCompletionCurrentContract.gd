extends SceneTree

## Bound integration of the production manifest consumer against the accepted
## gate-42 source. Manifest reconstruction is fixture setup only; production
## manifests are authored directly by add_street_house.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Completion = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const Shop = preload("res://scripts/buildings/CitadelShopRecipe.gd")
const PartyWalls = preload("res://scripts/buildings/MasonryPartyWallBearingRecipe.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var input := _read_bound("VOXEL_STRUCTURAL_CURRENT_INPUT", "VOXEL_STRUCTURAL_CURRENT_SHA")
	var expected := _read_bound("VOXEL_STRUCTURAL_CURRENT_EXPECTED", "VOXEL_STRUCTURAL_CURRENT_EXPECTED_SHA")
	if not input.ready or not expected.ready:
		quit(2); return
	var raw: Dictionary = input.value
	var expected_raw: Dictionary = expected.value
	var source = Copy.copy_blueprint(raw.afterSnapshot)
	source.recipe[Manifest.KEY] = {}
	var membership := Copy.street_house_memberships(source)
	if not membership.ready:
		quit(2); return
	for house: Dictionary in membership.houses:
		var prefix: String = house.prefix
		var sign := {}
		if _part(source, prefix + "_sign_arm") != null:
			sign = {"armId": prefix + "_sign_arm", "boardId": prefix + "_hanging_sign"}
		var declared := Manifest.declare(source, {"producerPrefix": prefix, "roomId": house.roomId,
			"doorId": house.doorId, "hoodId": prefix + "_door_hood",
			"threshold": {"id": prefix + "_door_threshold", "foundationId": prefix + "_foundation"},
			"bracketIds": [prefix + "_door_bracket_-66", prefix + "_door_bracket_66"],
			"chimney": {"id": prefix + "_chimney", "gableIds": [prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"],
				"upstreamIds": [prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"]},
			"facadeDeclarationKeys": [prefix + "_upper_facade"], "signAssembly": sign})
		if not declared.ready:
			quit(2); return
	# The bound archive predates producer-authored party-wall capability. Rebuild
	# that current recipe fact from semantic ownership and actual intersection.
	var facade_parts: Array = source.parts.filter(func(part): return part != null and part.semantic == "citadel_urban_facade")
	for part in source.parts:
		if part != null and part.semantic == "castle_keep_forecourt_pavilion" and facade_parts.any(func(panel):
			return source.transformed_part_bounds(part).intersects(source.transformed_part_bounds(panel))):
			if not PartyWalls.declare_party_wall_seat(part, true):
				quit(2); return
	var obstacles := Shop.furnishing_obstacles(raw.furnitureSnapshot, raw.protectedReservations)
	if not obstacles.ready:
		quit(2); return
	var completion_policy := {"protectedObstacles": obstacles.obstacles}
	var frozen_source := var_to_bytes(source.snapshot())
	var frozen_policy := var_to_bytes(completion_policy)
	var result := Completion.prepare_later(source, completion_policy)
	var checks := {}
	checks["production_consumer_ready_gate_zero"] = result.get("ready", false) and result.get("finalFailureCount") == 0
	checks["source_and_policy_immutable"] = frozen_source == var_to_bytes(source.snapshot()) and frozen_policy == var_to_bytes(completion_policy)
	checks["manifest_covers_every_house"] = Manifest.read(source).get("records", []).size() == membership.houses.size()
	var final_report := {"checks": [], "violations": []}
	if result.get("ready", false):
		var final = Copy.copy_blueprint(result.afterSnapshot)
		Copy.clear_caches(final)
		var grid := Copy.validation_grid_work(final)
		if grid.ready: final_report = final.validate_physical_integrity()
	checks["fresh_whole_validation_zero"] = final_report.violations.is_empty() and Copy.failed_ids(final_report).is_empty()
	var actual_snapshot: Dictionary = _without_derived_caches(result.get("afterSnapshot", {}))
	var expected_snapshot: Dictionary = _without_derived_caches(expected_raw.afterSnapshot)
	if actual_snapshot.get("recipe") is Dictionary: actual_snapshot.recipe.erase(Manifest.KEY)
	checks["exact_known_gate_zero_geometry_and_recipe"] = result.get("ready", false) and var_to_bytes(actual_snapshot) == var_to_bytes(expected_snapshot)
	checks["stage_order_and_dependency_retry"] = result.get("stages", []).size() == 6 \
		and result.stages.map(func(stage): return stage.kind) == ["chimney", "bracket_first", "sign", "party_wall", "bracket_retry", "threshold"] \
		and result.stages[1].pending.size() == 1 and result.stages[4].acceptedIds.size() == 1
	checks["threshold_stage_reuses_terminal_proof"] = result.get("stages", []).size() == 6 \
		and result.stages[5].globalPhysicalValidations == 2
	checks["furniture_and_reservations_bound_unchanged"] = raw.furnitureSnapshot.parts.size() == 152 \
		and var_to_bytes(raw.furnitureSnapshot) == var_to_bytes(input.value.furnitureSnapshot) \
		and var_to_bytes(raw.protectedReservations) == var_to_bytes(input.value.protectedReservations)
	var stale_source = Copy.copy_blueprint(source.snapshot())
	var stale_collection: Dictionary = stale_source.recipe.get(Manifest.KEY, {}).duplicate(true)
	var stale_prefixes: Array = stale_collection.keys()
	stale_prefixes.sort()
	var stale_record: Dictionary = stale_collection[stale_prefixes[0]].duplicate(true)
	stale_record["doorId"] = String(stale_record.doorId) + "_stale"
	stale_collection[stale_prefixes[0]] = stale_record
	stale_source.recipe[Manifest.KEY] = stale_collection
	var stale_frozen := var_to_bytes(stale_source.snapshot())
	var stale_policy_frozen := var_to_bytes(completion_policy)
	var stale_result := Completion.prepare_later(stale_source, completion_policy)
	checks["stale_manifest_rejected_without_commit_or_input_mutation"] = not stale_result.get("ready", false) \
		and stale_result.get("reason") == "structural_manifest_invalid" and not stale_result.has("afterSnapshot") \
		and stale_frozen == var_to_bytes(stale_source.snapshot()) and stale_policy_frozen == var_to_bytes(completion_policy)
	var unresolved_source = Copy.copy_blueprint(source.snapshot())
	for part in unresolved_source.parts:
		if part != null and part.semantic == "castle_keep_forecourt_pavilion":
			part.recipe.erase("physicalPartyWallBearingModes")
	var unresolved_frozen := var_to_bytes(unresolved_source.snapshot())
	var unresolved_policy_frozen := var_to_bytes(completion_policy)
	var unresolved_result := Completion.prepare_later(unresolved_source, completion_policy)
	checks["permitted_pending_stays_unresolved_without_commit_or_input_mutation"] = not unresolved_result.get("ready", false) \
		and unresolved_result.get("reason") == "structural_completion_unresolved" and not unresolved_result.has("afterSnapshot") \
		and unresolved_result.get("stages", []).any(func(stage): return stage.kind == "party_wall" and not stage.pending.is_empty()) \
		and unresolved_frozen == var_to_bytes(unresolved_source.snapshot()) and unresolved_policy_frozen == var_to_bytes(completion_policy)
	var passed: bool = checks.values().all(func(value): return value == true)
	var result_brief: Dictionary = result.duplicate(true)
	result_brief.erase("afterSnapshot")
	var report := {"passed": passed, "checks": checks, "stages": result.get("stages", []), "completion": result_brief,
		"finalFailureCount": Copy.failed_ids(final_report).size(),
		"exactDifferencePaths": _difference_paths(actual_snapshot, expected_snapshot),
		"scope": "Manifest-backed private source completion; no composer commit, publication, rendering or gameplay claim."}
	var output := FileAccess.open(OS.get_environment("VOXEL_STRUCTURAL_CURRENT_REPORT"), FileAccess.WRITE)
	if output != null: output.store_string(JSON.stringify(_json(report), "\t")); output.close()
	quit(0 if passed else 1)

func _part(source, id: String):
	for part in source.parts:
		if part.id == id: return part
	return null

func _without_derived_caches(snapshot: Dictionary) -> Dictionary:
	if snapshot.is_empty(): return {}
	var normalized = Copy.copy_blueprint(snapshot)
	Copy.clear_caches(normalized)
	return normalized.snapshot()

func _read_bound(path_key: String, sha_key: String) -> Dictionary:
	var path := OS.get_environment(path_key).simplify_path()
	var sha := OS.get_environment(sha_key).to_lower()
	if not path.is_absolute_path() or sha.length() != 64 or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != sha:
		return {"ready": false}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > 128 * 1024 * 1024: return {"ready": false}
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var value: Variant = bytes_to_var(bytes)
	return {"ready": value is Dictionary and var_to_bytes(value) == bytes, "value": value}

func _json(value: Variant) -> Variant:
	if value is Vector2: return [value.x, value.y]
	if value is Vector3: return [value.x, value.y, value.z]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key: Variant in value: result[String(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value

func _difference_paths(actual: Variant, expected: Variant, path := "snapshot", rows: Array = []) -> Array:
	if rows.size() >= 64: return rows
	if typeof(actual) != typeof(expected):
		rows.append({"path": path, "actualType": typeof(actual), "expectedType": typeof(expected)})
		return rows
	if actual is Dictionary:
		var keys: Array = actual.keys()
		for key in expected.keys():
			if not keys.has(key): keys.append(key)
		keys.sort_custom(func(a, b): return String(a) < String(b))
		for key in keys:
			if not actual.has(key) or not expected.has(key):
				rows.append({"path": "%s.%s" % [path, key], "actualHas": actual.has(key), "expectedHas": expected.has(key)})
			else: _difference_paths(actual[key], expected[key], "%s.%s" % [path, key], rows)
			if rows.size() >= 64: break
		return rows
	if actual is Array:
		if actual.size() != expected.size(): rows.append({"path": path, "actualSize": actual.size(), "expectedSize": expected.size()})
		for index in range(mini(actual.size(), expected.size())):
			_difference_paths(actual[index], expected[index], "%s[%d]" % [path, index], rows)
			if rows.size() >= 64: break
		return rows
	if actual != expected: rows.append({"path": path, "actual": str(actual), "expected": str(expected)})
	return rows
