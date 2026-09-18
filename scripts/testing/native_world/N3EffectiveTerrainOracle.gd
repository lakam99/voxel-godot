extends RefCounted
class_name N3EffectiveTerrainOracle

const ContextScript := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const WorldScript := preload("res://scripts/WorldGenerationSystem.gd")

const SCHEMA := "n3-effective-terrain-oracle/v1"
const GOLDENS_SCHEMA := "n3-effective-terrain-goldens/v1"
const SAMPLE_SCHEMA := "n3-effective-terrain-oracle-samples/v1"
const GOLDENS_PATH := "res://scripts/testing/native_world/N3EffectiveTerrainGoldens.json"
const CELL := 1.35


static func load_goldens(path := GOLDENS_PATH) -> Dictionary:
	var file := FileAccess.open(String(path), FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "goldens_open_failed", "path": String(path)}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return {"ok": false, "reason": "goldens_json_invalid", "path": String(path)}
	var goldens: Dictionary = parsed
	if String(goldens.get("schema", "")) != GOLDENS_SCHEMA:
		return {"ok": false, "reason": "goldens_schema_invalid", "path": String(path)}
	var query_set = goldens.get("querySet")
	if not query_set is Dictionary \
			or String(query_set.get("schema", "")) != "n3-effective-terrain-query-set/v1" \
			or String(query_set.get("id", "")).is_empty():
		return {"ok": false, "reason": "goldens_query_set_invalid", "path": String(path)}
	if not goldens.get("world") is Dictionary or not goldens.get("queries") is Dictionary:
		return {"ok": false, "reason": "goldens_shape_invalid", "path": String(path)}
	for channel in _channel_names():
		if not goldens.queries.get(channel) is Array or goldens.queries[channel].is_empty():
			return {"ok": false, "reason": "goldens_channel_missing", "channel": channel}
		for ordinal in range(goldens.queries[channel].size()):
			var query = goldens.queries[channel][ordinal]
			if not query is Dictionary or int(query.get("ordinal", -1)) != ordinal \
					or String(query.get("id", "")).is_empty() or not query.has("input") or not query.get("expected") is Dictionary:
				return {"ok": false, "reason": "goldens_query_invalid", "channel": channel, "ordinal": ordinal}
	return goldens


static func build_world(seed: String, optional_profiles := [], overrides := {}) -> Dictionary:
	if seed.is_empty() or not optional_profiles is Array or not overrides is Dictionary:
		return {"ok": false, "reason": "world_input_invalid"}
	var context = ContextScript.new()
	context.seed_text = seed
	context.seed_hash = context.hash_string(seed)
	context.setup_noise()
	for key_value in overrides.keys():
		if not key_value is Vector2i:
			return {"ok": false, "reason": "town_override_key_invalid"}
		var value = overrides[key_value]
		context.pinned_town_regions[key_value] = value.duplicate(true) if value is Dictionary else {}
	var world = WorldScript.new()
	world.setup(context)
	context.set_generator(world)
	if not optional_profiles.is_empty():
		var admitted: Dictionary = world.configure_generated_site_profiles(optional_profiles)
		if not bool(admitted.get("ready", false)):
			return {"ok": false, "reason": "site_profiles_rejected", "details": admitted}
	return {
		"ok": true,
		"seed": seed,
		"context": context,
		"world": world,
		"volume": world.terrain_volume_service,
		"mutationsApplied": false,
		"forbiddenNativePathsUsed": false,
	}


static func town_overrides_from_goldens(goldens: Dictionary) -> Dictionary:
	var result := {}
	var rows = (goldens.get("world", {}) as Dictionary).get("townOverrides", [])
	if not rows is Array:
		return result
	for value in rows:
		if not value is Dictionary or not value.get("region") is Array or value.region.size() != 2:
			continue
		var region := Vector2i(int(value.region[0]), int(value.region[1]))
		if not bool(value.get("hasTown", false)):
			result[region] = {}
			continue
		result[region] = {
			"regionX": region.x,
			"regionZ": region.y,
			"centerX": int(value.get("center", [0, 0])[0]),
			"centerZ": int(value.get("center", [0, 0])[1]),
			"radius": int(value.get("radius", 0)),
			"level": float(value.get("level", 0.0)),
		}
	return result


static func site_profiles_from_goldens(goldens: Dictionary) -> Array:
	var profiles: Array = []
	var specs = (goldens.get("world", {}) as Dictionary).get("siteProfiles", [])
	if not specs is Array:
		return profiles
	for value in specs:
		if not value is Dictionary:
			continue
		var core_values = value.get("coreCells", [])
		if not core_values is Array or core_values.size() != 4:
			continue
		var core := Rect2i(int(core_values[0]), int(core_values[1]), int(core_values[2]), int(core_values[3]))
		var apron := int(value.get("apronCells", 0))
		var envelope := core.grow(apron)
		var support: Array = []
		var distances: Array = []
		for z in range(envelope.position.y, envelope.end.y):
			for x in range(envelope.position.x, envelope.end.x):
				var inside := core.has_point(Vector2i(x, z))
				support.append(1 if inside else 0)
				var dx := maxi(core.position.x - x, maxi(0, x - (core.end.x - 1)))
				var dz := maxi(core.position.y - z, maxi(0, z - (core.end.y - 1)))
				distances.append(float(Vector2(float(dx), float(dz)).length()))
		var level := float(value.get("level", 0.0))
		# Keep the synthetic root strictly inside the accepted cell-coordinate
		# bounds. Vector3 narrows to real_t while validation compares against the
		# binary64 cell product, so an exact mathematical edge can fall one ULP out.
		var low_x := float(core.position.x) * CELL + 0.01
		var low_z := float(core.position.y) * CELL + 0.01
		var high_x := float(core.end.x - 1) * CELL - 0.01
		var high_z := float(core.end.y - 1) * CELL - 0.01
		profiles.append({
			"version": 1,
			"worldSeed": String((goldens.get("world", {}) as Dictionary).get("seed", "")),
			"siteId": String(value.get("siteId", "")),
			"sourceSignature": String(value.get("sourceSignature", "")),
			"cellSize": CELL,
			"coreCells": core,
			"envelopeCells": envelope,
			"reservationCells": core,
			"origin": Vector3(low_x, level, low_z),
			"level": level,
			"apronCells": apron,
			"supportMask": support,
			"distanceCells": distances,
			"groundRootPoints": [
				Vector3(low_x, level, low_z), Vector3(high_x, level, low_z),
				Vector3(high_x, level, high_z), Vector3(low_x, level, high_z),
			],
		})
	return profiles


static func sample_all(world_bundle: Dictionary, goldens: Dictionary) -> Dictionary:
	if not bool(world_bundle.get("ok", false)) or String(goldens.get("schema", "")) != GOLDENS_SCHEMA:
		return {"ok": false, "reason": "sample_input_invalid"}
	var mutation_result := _apply_mutations(world_bundle, goldens)
	if not bool(mutation_result.get("ok", false)):
		return mutation_result
	var queries: Dictionary = goldens.queries
	var result := {
		"ok": true,
		"schema": SAMPLE_SCHEMA,
		"oracleSchema": SCHEMA,
		"seed": String(world_bundle.seed),
		"forbiddenNativePathsUsed": false,
	}
	result["surfaceColumns"] = _sample_surface_columns(world_bundle, queries.surfaceColumns)
	result["cellCenters"] = _sample_cell_centers(world_bundle, queries.cellCenters)
	result["latticeNumeric"] = _sample_lattice_numeric(world_bundle, queries.latticeNumeric)
	result["worldNumeric"] = _sample_world_numeric(world_bundle, queries.worldNumeric)
	result["surfaceProjectionNumeric"] = _sample_surface_projection_numeric(world_bundle, queries.surfaceProjectionNumeric)
	return result


static func compare_to_goldens(actual: Dictionary, goldens: Dictionary) -> Dictionary:
	var mismatches: Array = []
	if not bool(actual.get("ok", false)):
		return {"ok": false, "reason": "oracle_sampling_failed", "mismatches": [actual]}
	for channel in _channel_names():
		var actual_rows = actual.get(channel)
		var expected_rows = (goldens.get("queries", {}) as Dictionary).get(channel)
		if not actual_rows is Array or not expected_rows is Array or actual_rows.size() != expected_rows.size():
			mismatches.append({"channel": channel, "field": "count", "expected": expected_rows.size() if expected_rows is Array else -1, "actual": actual_rows.size() if actual_rows is Array else -1})
			continue
		for index in range(expected_rows.size()):
			var left: Dictionary = actual_rows[index]
			var right: Dictionary = expected_rows[index]
			for field in ["ordinal", "id", "input"]:
				_compare_value(mismatches, channel, index, field, left.get(field), right.get(field))
			_compare_value(mismatches, channel, index, "expected", left.get("actual"), right.get("expected"))
			if mismatches.size() >= 128:
				break
	return {"ok": mismatches.is_empty(), "reason": "" if mismatches.is_empty() else "golden_mismatch", "mismatchCount": mismatches.size(), "mismatches": mismatches}


static func _sample_surface_columns(bundle: Dictionary, queries: Array) -> Array:
	var world = bundle.world
	var volume = bundle.volume
	var rows: Array = []
	for query in queries:
		var cell := _cell2(query.input.cell)
		var column := Vector3i(cell.x, 0, cell.y)
		var reference := float(world.terrain_reference_surface_y_for_cell(column))
		var deformed := float(world.terrain_deformed_surface_y_for_cell(column))
		var volume_surface := float(volume.surface_y_for_cell(column))
		rows.append(_row(query, {
			"requestedCell": [cell.x, cell.y],
			"sourceCell": [cell.x, cell.y],
			"referenceSurfaceY": reference,
			"referenceSurfaceYBits": _f64_bits(reference),
			"deformedSurfaceY": deformed,
			"deformedSurfaceYBits": _f64_bits(deformed),
			"volumeSurfaceY": volume_surface,
			"volumeSurfaceYBits": _f64_bits(volume_surface),
			"surfaceBiome": String(world.surface_biome_for_cell3(column)),
		}))
	return rows


static func _sample_cell_centers(bundle: Dictionary, queries: Array) -> Array:
	var world = bundle.world
	var rows: Array = []
	for query in queries:
		var cell := _cell3(query.input.cell)
		var state: Dictionary = world.get_cell_state(cell)
		var density := float(state.get("density", 0.0))
		var position := Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)
		var resolved: Vector3i = world.world_to_cell3(position)
		var light: Dictionary = state.get("light", {}) if state.get("light") is Dictionary else {}
		rows.append(_row(query, {
			"requestedCell": _v3i(cell),
			"sourceCell": _v3i(resolved),
			"positionBits": _v3_f32_bits(position),
			"material": String(state.get("material", "")),
			"blockId": String(state.get("blockId", "")),
			"biome": String(state.get("biome", "")),
			"solid": bool(state.get("solid", false)),
			"density": density,
			"densityBits": _f64_bits(density),
			"fluid": String(state.get("fluid", "")),
			"light": {"sky": int(light.get("sky", 0)), "block": int(light.get("block", 0))},
			"generated": bool(state.get("generated", false)),
			"edited": bool(state.get("edited", false)),
		}))
	return rows


static func _sample_lattice_numeric(bundle: Dictionary, queries: Array) -> Array:
	var world = bundle.world
	var context = bundle.context
	var rows: Array = []
	for query in queries:
		var cell := _cell3(query.input.cell)
		# VoxelTerrainGenerator owns this channel. `Vector3(cell) * CELL`
		# deliberately crosses two float32 boundaries: integer-to-Vector3, then
		# Vector3 scalar multiplication. Do not route it through WGS's one-boundary
		# grid helper, which is a different production coordinate convention.
		var position := Vector3(cell) * CELL
		var saved_edit: Dictionary = context.initial_terrain_edits.get(cell, {}) \
				if context.initial_terrain_edits.get(cell, {}) is Dictionary else {}
		var base_surface_y := float(world.terrain_reference_surface_y_at(position))
		var surface_y := float(world.terrain_deformed_surface_y_at(position))
		var density: float
		var state: Dictionary
		if not saved_edit.is_empty():
			density = float(saved_edit.get("density", -CELL))
			state = saved_edit.duplicate(true)
		else:
			density = float(world.density_from_components(position, surface_y, base_surface_y))
			var surface_biome := String(world.surface_biome_for_cell3(Vector3i(cell.x, 0, cell.z)))
			var depth := maxf(0.0, base_surface_y - position.y)
			var material := "air" if density < 0.0 else String(world.generated_solid_material_for_cell(cell, base_surface_y, surface_biome, depth))
			var generated: Dictionary = world.generate_sample_without_volume(position)
			state = {
				"material": material,
				"biome": String(generated.get("biome", surface_biome)),
				"solid": density >= 0.0,
				"generated": true,
				"edited": false,
			}
		var underground_air := String(state.get("biome", "")) == "underground_air" \
				and not bool(state.get("solid", density >= 0.0))
		var value := Vector3(density, 0.0 if underground_air else INF, surface_y)
		rows.append(_row(query, _numeric_result(world, position, value, cell, state)))
	return rows


static func _sample_world_numeric(bundle: Dictionary, queries: Array) -> Array:
	var world = bundle.world
	var volume = bundle.volume
	var rows: Array = []
	for query in queries:
		var position := _position(query.input.position)
		var value: Vector3 = volume.numeric_sample_world(position)
		var source_cell: Vector3i = world.world_to_cell3(position)
		var state: Dictionary = volume.get_cell_state(source_cell)
		state = volume.terrain_mesh_payload_state(source_cell, state)
		rows.append(_row(query, _numeric_result(world, position, value, source_cell, state)))
	return rows


static func _sample_surface_projection_numeric(bundle: Dictionary, queries: Array) -> Array:
	var world = bundle.world
	var volume = bundle.volume
	var rows: Array = []
	for query in queries:
		var cell := _cell3(query.input.cell)
		# WorldGenerationSystem.volume_surface_numeric_sample_at_grid_cell owns
		# this channel and constructs each scalar product before Vector3's single
		# float32 storage boundary.
		var position := Vector3(float(cell.x) * CELL, float(cell.y) * CELL, float(cell.z) * CELL)
		var value: Vector3 = world.volume_surface_numeric_sample_at_grid_cell(cell)
		var state: Dictionary = volume.get_cell_state(cell)
		if not bool(state.get("edited", false)) or not world.terrain_state_affects_surface_projection(state):
			var generated: Dictionary = world.generate_sample_without_volume(position)
			state = {
				"material": String(generated.get("material", "air")),
				"generated": true,
				"edited": false,
			}
		rows.append(_row(query, _numeric_result(world, position, value, cell, state)))
	return rows


static func _numeric_result(world, position: Vector3, value: Vector3, requested_cell: Vector3i, state: Dictionary) -> Dictionary:
	var density := float(value.x)
	var surface := float(value.z)
	return {
		"positionBits": _v3_f32_bits(position),
		"requestedCell": _v3i(requested_cell),
		"sourceCell": _v3i(world.world_to_cell3(position)),
		"density": density,
		"densityBits": _f64_bits(density),
		"solid": density >= 0.0,
		"undergroundAirVoid": is_finite(value.y) and value.y == 0.0,
		"marker": "underground_air" if is_finite(value.y) and value.y == 0.0 else "none",
		"surfaceY": surface,
		"surfaceYBits": _f64_bits(surface),
		"material": String(state.get("material", "air")),
		"generated": bool(state.get("generated", true)),
		"edited": bool(state.get("edited", false)),
	}


static func _apply_mutations(bundle: Dictionary, goldens: Dictionary) -> Dictionary:
	if bool(bundle.get("mutationsApplied", false)):
		return {"ok": true}
	var mutations = (goldens.get("world", {}) as Dictionary).get("mutations", [])
	if not mutations is Array:
		return {"ok": false, "reason": "mutations_invalid"}
	var volume = bundle.volume
	for value in mutations:
		if not value is Dictionary or not value.get("cell") is Array or not value.get("state") is Dictionary:
			return {"ok": false, "reason": "mutation_invalid"}
		var cell := _cell3(value.cell)
		var state: Dictionary = value.state.duplicate(true)
		if String(value.get("kind", "")) == "durable":
			var normalized: Dictionary = volume.set_cell_state(cell, state, String(value.get("reason", "oracle")), false)
			if volume.cell_state_affects_terrain_mesh(normalized):
				bundle.context.initial_terrain_edits[cell] = normalized.duplicate(true)
			else:
				bundle.context.initial_terrain_edits.erase(cell)
		elif String(value.get("kind", "")) == "sceneOverlay":
			volume.set_scene_block_overlay(cell, state, String(value.get("reason", "oracle")))
		else:
			return {"ok": false, "reason": "mutation_kind_invalid"}
	bundle["mutationsApplied"] = true
	return {"ok": true}


static func _row(query: Dictionary, actual: Dictionary) -> Dictionary:
	return {"ordinal": int(query.ordinal), "id": String(query.id), "input": query.input, "actual": actual}


static func _compare_value(mismatches: Array, channel: String, ordinal: int, field: String, actual, expected) -> void:
	_compare_recursive(mismatches, channel, ordinal, field, actual, expected)


static func _compare_recursive(mismatches: Array, channel: String, ordinal: int, path: String, actual, expected) -> void:
	if typeof(actual) in [TYPE_INT, TYPE_FLOAT] and typeof(expected) in [TYPE_INT, TYPE_FLOAT]:
		if (_exact_numeric_path(path) and actual == expected) \
				or (not _exact_numeric_path(path) and is_equal_approx(float(actual), float(expected))):
			return
	elif actual is Dictionary and expected is Dictionary:
		var left: Dictionary = actual
		var right: Dictionary = expected
		if left.size() == right.size():
			var complete := true
			for key in right:
				if not left.has(key):
					complete = false
					break
			if complete:
				for key in right:
					_compare_recursive(mismatches, channel, ordinal, "%s.%s" % [path, String(key)], left[key], right[key])
				return
	elif actual is Array and expected is Array:
		var left: Array = actual
		var right: Array = expected
		if left.size() == right.size():
			for index in range(right.size()):
				_compare_recursive(mismatches, channel, ordinal, "%s[%d]" % [path, index], left[index], right[index])
			return
	elif actual == expected:
		return
	mismatches.append({"channel": channel, "ordinal": ordinal, "field": path, "expected": expected, "actual": actual})


static func _exact_numeric_path(path: String) -> bool:
	return path == "ordinal" \
			or path.begins_with("input.cell[") \
			or path.begins_with("expected.requestedCell[") \
			or path.begins_with("expected.sourceCell[")


static func _channel_names() -> Array[String]:
	return ["surfaceColumns", "cellCenters", "latticeNumeric", "worldNumeric", "surfaceProjectionNumeric"]


static func _cell2(value) -> Vector2i:
	return Vector2i(int(value[0]), int(value[1]))


static func _cell3(value) -> Vector3i:
	return Vector3i(int(value[0]), int(value[1]), int(value[2]))


static func _position(value) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


static func _v3i(value: Vector3i) -> Array:
	return [value.x, value.y, value.z]


static func _f64_bits(value: float) -> String:
	return PackedFloat64Array([value]).to_byte_array().hex_encode()


static func _f32_bits(value: float) -> String:
	return PackedFloat32Array([value]).to_byte_array().hex_encode()


static func _v3_f32_bits(value: Vector3) -> Array:
	return [_f32_bits(value.x), _f32_bits(value.y), _f32_bits(value.z)]
