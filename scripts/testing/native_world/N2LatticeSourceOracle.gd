extends RefCounted
class_name N2LatticeSourceOracle

const ContextScript := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const WorldScript := preload("res://scripts/WorldGenerationSystem.gd")

const SCHEMA := "n2-lattice-source-oracle/v1"
const SEED := "atlas-1492"
const CELL := 1.35
const SAMPLE_MIN := Vector3i(-49, -17, -17)
const SAMPLE_MAX_EXCLUSIVE := Vector3i(-14, 34, 2)
const SAMPLE_SIZE := Vector3i(35, 51, 19)
const SAMPLE_COUNT := 33915
const TILE_A := Vector2i(-3, -1)
const TILE_B := Vector2i(-2, -1)

const MATERIAL_IDS := {
	"air": 0, "grass": 1, "dirt": 2, "stone": 3, "sand": 4,
	"snow": 5, "deepStone": 6, "bedrock": 7, "clay": 8,
	"gravel": 9, "coalOre": 10, "ironOre": 11, "crystalOre": 12,
	"copperOre": 13, "mud": 14, "water": 15
}
const MATERIAL_NAMES := ["air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock",
	"clay", "gravel", "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water"]
const BIOME_IDS := {
	"plains": 0, "forest": 1, "swamp": 2, "desert": 3,
	"savanna": 4, "snow": 5, "taiga": 6, "tundra": 7, "ocean": 8,
	"beach": 9, "town": 10, "underground": 11,
	"deep_underground": 12, "underground_air": 13, "alpine": 14
}
const BIOME_NAMES := ["plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra",
	"ocean", "beach", "town", "underground", "deep_underground", "underground_air", "alpine"]
const FLUID_IDS := {"": 0, "water": 1}
const FLUID_NAMES := ["", "water"]
const SOURCE_KIND_NAMES := ["generated", "typed_delta"]
const EDIT_COORDINATES := [
	Vector3i(-33, 12, -5), Vector3i(-32, 12, -5),
	Vector3i(-33, 12, -4), Vector3i(-32, 12, -4)
]
const NOISE_COORDINATES := [
	Vector3(0.0, 0.0, 0.0),
	Vector3(-49.0, -17.0, -17.0),
	Vector3(-32.0, -2.0, -5.0),
	Vector3(1048576.25, -524288.5, 262144.75)
]


func build_snapshot(serialized_delta_bytes: PackedByteArray = PackedByteArray(), source_revision := 1) -> Dictionary:
	if source_revision <= 0:
		return {"ok": false, "reason": "source_revision_must_be_positive"}
	var source := _world()
	if not bool(source.get("ok", false)):
		return source
	var edits_result := _decode_edits(serialized_delta_bytes)
	if not bool(edits_result.get("ok", false)):
		return edits_result
	var edits: Dictionary = edits_result.edits
	var samples: Array = []
	samples.resize(SAMPLE_COUNT)
	var by_coordinate := {}
	var ordinal := 0
	var world = source.world
	for y in range(SAMPLE_MIN.y, SAMPLE_MAX_EXCLUSIVE.y):
		for z in range(SAMPLE_MIN.z, SAMPLE_MAX_EXCLUSIVE.z):
			for x in range(SAMPLE_MIN.x, SAMPLE_MAX_EXCLUSIVE.x):
				var cell := Vector3i(x, y, z)
				var sampled := _sample(world, cell, edits.get(cell, {}), source_revision)
				if not bool(sampled.get("ok", false)):
					return sampled
				var row: Dictionary = sampled.sample
				row["ordinal"] = ordinal
				samples[ordinal] = row
				by_coordinate[_key(cell)] = row
				ordinal += 1
	if ordinal != SAMPLE_COUNT:
		return {"ok": false, "reason": "oracle_sample_count_mismatch", "actual": ordinal, "expected": SAMPLE_COUNT}
	var anchor_result := _anchors(by_coordinate, edits.is_empty())
	if not bool(anchor_result.get("ok", false)):
		return anchor_result
	var canonical_bytes := JSON.stringify(samples, "", false, true).to_utf8_buffer()
	var delta_record: Dictionary = edits_result.serialized
	return {
		"ok": true,
		"schema": SCHEMA,
		"seed": SEED,
		"ordering": "x_fastest_then_z_then_y",
		"bounds": {"minimum": _v3i(SAMPLE_MIN), "maximumExclusive": _v3i(SAMPLE_MAX_EXCLUSIVE), "size": _v3i(SAMPLE_SIZE)},
		"sampleCount": samples.size(),
		"samples": samples,
		"samplesSha256": _sha256(canonical_bytes),
		"deltas": delta_record,
		"anchors": anchor_result.anchors,
		"noiseFloatBits": _noise_fixtures(source.context),
		"sourceSemantics": "lattice_origin_direct_low_level_generation",
		"forbiddenOraclePathsUsed": false
	}


func frozen_edit_serialization() -> Dictionary:
	var records: Array = []
	for index in range(EDIT_COORDINATES.size()):
		var cell: Vector3i = EDIT_COORDINATES[index]
		records.append({
			"coordinate": _v3i(cell), "density": -CELL, "solid": false,
			"materialId": MATERIAL_IDS.air, "materialName": "air",
			"surfaceBiomeId": BIOME_IDS.swamp, "surfaceBiomeName": "swamp",
			"resolvedBiomeId": BIOME_IDS.underground_air,
			"resolvedBiomeName": "underground_air", "fluidId": FLUID_IDS[""], "fluid": "",
			"deltaId": "n2:seam-air:%d" % index, "deltaRevision": 1
		})
	var envelope := {
		"schema": "n2-typed-terrain-deltas/v1", "seed": SEED,
		"coordinateEncoding": "signed-int32-x-y-z", "densityEncoding": "ieee754-binary64",
		"records": records
	}
	var bytes := JSON.stringify(envelope, "", false, true).to_utf8_buffer()
	return {"schema": envelope.schema, "bytesBase64": Marshalls.raw_to_base64(bytes), "bytes": bytes, "sha256": _sha256(bytes), "records": records}


func native_request(delta_bytes: PackedByteArray) -> Dictionary:
	return {
		"schema": "n2-native-vertical-slice-request/v1",
		"seed": SEED,
		"lod": 0,
		"step": 1,
		"sampleBounds": {"minimum": _v3i(SAMPLE_MIN), "maximumExclusive": _v3i(SAMPLE_MAX_EXCLUSIVE)},
		"tileCores": [
			{"key": [TILE_A.x, TILE_A.y], "minimum": [-48, -16, -16], "maximumExclusive": [-32, 32, 0]},
			{"key": [TILE_B.x, TILE_B.y], "minimum": [-32, -16, -16], "maximumExclusive": [-16, 32, 0]}
		],
		"typedDeltaBytesBase64": "" if delta_bytes.is_empty() else Marshalls.raw_to_base64(delta_bytes),
		"blockers": [{
			"id": "n2:blocker:tile-b:-24,-10", "center": [-32.4, 16.497000000000003, -13.5],
			"size": [1.35, 2.7, 1.35], "semanticClass": "fixture_obstacle", "physicalIntent": "blocker"
		}],
		"caps": {"admittedRequests": 4, "inFlightBuilds": 1, "preparedResults": 1,
			"preparedBytes": 4194304, "installedBodies": 1, "installedShapes": 3,
			"collisionTriangles": 200000, "retiredShapeSets": 4}
	}


func compare_packed_columns(expected: Array, source: Dictionary) -> Dictionary:
	var columns = source.get("columns")
	if not columns is Dictionary:
		return {"ok": false, "reason": "packed_source_columns_missing", "mismatches": []}
	var name_tables = source.get("nameTables")
	if not name_tables is Dictionary or not name_tables.get("materialNames") is PackedStringArray \
			or not name_tables.get("biomeNames") is PackedStringArray or not name_tables.get("fluidNames") is PackedStringArray \
			or not name_tables.get("sourceKindNames") is PackedStringArray:
		return {"ok": false, "reason": "packed_name_tables_missing_or_untyped", "mismatches": []}
	for table in [["materialNames", MATERIAL_NAMES], ["biomeNames", BIOME_NAMES], ["fluidNames", FLUID_NAMES], ["sourceKindNames", SOURCE_KIND_NAMES]]:
		var actual_names: PackedStringArray = name_tables[table[0]]
		var expected_names: Array = table[1]
		if actual_names.size() != expected_names.size():
			return {"ok": false, "reason": "packed_name_table_count_mismatch", "table": table[0], "mismatches": []}
		for name_index in range(expected_names.size()):
			if actual_names[name_index] != expected_names[name_index]:
				return {"ok": false, "reason": "packed_name_table_value_mismatch", "table": table[0], "index": name_index, "mismatches": []}
	var typed := columns.get("density") is PackedFloat64Array and columns.get("surfaceY") is PackedFloat64Array \
		and columns.get("surfaceYValid") is PackedByteArray and columns.get("solid") is PackedByteArray \
		and columns.get("materialIds") is PackedByteArray and columns.get("surfaceBiomeIds") is PackedByteArray \
		and columns.get("resolvedBiomeIds") is PackedByteArray and columns.get("fluidIds") is PackedByteArray \
		and columns.get("sourceKinds") is PackedByteArray and columns.get("sourceRevisions") is PackedInt32Array
	if not typed:
		return {"ok": false, "reason": "packed_source_column_type_invalid", "mismatches": []}
	for field in ["density", "surfaceY", "surfaceYValid", "solid", "materialIds", "surfaceBiomeIds", "resolvedBiomeIds", "fluidIds", "sourceKinds", "sourceRevisions"]:
		if columns[field].size() != expected.size():
			return {"ok": false, "reason": "packed_source_column_count_mismatch", "field": field, "expected": expected.size(), "actual": columns[field].size(), "mismatches": []}
	var sparse_sources := {}
	if source.get("generatedSourceId") != "generator:%s" % SEED:
		return {"ok": false, "reason": "packed_generated_source_id_invalid", "mismatches": []}
	if not source.get("sparseSources") is Array:
		return {"ok": false, "reason": "packed_sparse_sources_missing", "mismatches": []}
	for row in source.sparseSources:
		if not row is Dictionary or not row.has("ordinal") or not row.has("id") or not row.has("revision"):
			return {"ok": false, "reason": "packed_sparse_source_invalid", "mismatches": []}
		var ordinal := int(row.ordinal)
		if ordinal < 0 or ordinal >= expected.size() or sparse_sources.has(ordinal):
			return {"ok": false, "reason": "packed_sparse_source_ordinal_invalid", "mismatches": []}
		sparse_sources[ordinal] = row
	var mismatches: Array = []
	for index in range(expected.size()):
		var left: Dictionary = expected[index]
		var sparse: Dictionary = sparse_sources.get(index, {})
		for binary_field in ["surfaceYValid", "solid"]:
			if int(columns[binary_field][index]) != 0 and int(columns[binary_field][index]) != 1:
				return {"ok": false, "reason": "packed_boolean_column_value_invalid", "field": binary_field, "ordinal": index, "mismatches": []}
		if int(columns.sourceKinds[index]) != 0 and int(columns.sourceKinds[index]) != 1:
			return {"ok": false, "reason": "packed_source_kind_invalid", "ordinal": index, "mismatches": []}
		if int(columns.materialIds[index]) >= MATERIAL_NAMES.size() or int(columns.surfaceBiomeIds[index]) >= BIOME_NAMES.size() \
				or int(columns.resolvedBiomeIds[index]) >= BIOME_NAMES.size() or int(columns.fluidIds[index]) >= FLUID_NAMES.size():
			return {"ok": false, "reason": "packed_typed_id_out_of_range", "ordinal": index, "mismatches": []}
		if not sparse.is_empty() and int(sparse.revision) != int(columns.sourceRevisions[index]):
			return {"ok": false, "reason": "packed_sparse_source_revision_mismatch", "ordinal": index, "mismatches": []}
		var actual := {
			"density": float(columns.density[index]), "surfaceY": float(columns.surfaceY[index]),
			"surfaceYValid": int(columns.surfaceYValid[index]) != 0, "solid": int(columns.solid[index]) != 0,
			"materialId": int(columns.materialIds[index]), "surfaceBiomeId": int(columns.surfaceBiomeIds[index]),
			"resolvedBiomeId": int(columns.resolvedBiomeIds[index]), "fluidId": int(columns.fluidIds[index]),
			"sourceKind": "typed_delta" if int(columns.sourceKinds[index]) == 1 else "generated",
			"sourceId": String(sparse.get("id", source.generatedSourceId)), "sourceRevision": int(columns.sourceRevisions[index])
		}
		actual["materialName"] = String(name_tables.materialNames[actual.materialId])
		actual["surfaceBiomeName"] = String(name_tables.biomeNames[actual.surfaceBiomeId])
		actual["resolvedBiomeName"] = String(name_tables.biomeNames[actual.resolvedBiomeId])
		actual["fluid"] = String(name_tables.fluidNames[actual.fluidId])
		var expected_values := {"density": left.density, "surfaceY": left.surfaceY, "surfaceYValid": left.surfaceYValid,
			"solid": left.solid, "materialId": left.materialId, "materialName": left.materialName,
			"surfaceBiomeId": left.surfaceBiomeId, "surfaceBiomeName": left.surfaceBiomeName,
			"resolvedBiomeId": left.resolvedBiomeId, "resolvedBiomeName": left.resolvedBiomeName,
			"fluidId": int(FLUID_IDS[left.fluid]), "fluid": left.fluid,
			"sourceKind": left.sourceKind, "sourceId": left.sourceId, "sourceRevision": left.sourceRevision}
		for field in expected_values:
			if actual[field] != expected_values[field]:
				mismatches.append({"ordinal": index, "coordinate": left.coordinate, "field": field, "expected": expected_values[field], "actual": actual[field]})
				if mismatches.size() >= 64:
					return {"ok": false, "reason": "ordered_typed_sample_mismatch", "mismatches": mismatches}
	return {"ok": mismatches.is_empty(), "reason": "" if mismatches.is_empty() else "ordered_sample_mismatch", "mismatches": mismatches}


func _world() -> Dictionary:
	var context = ContextScript.new()
	context.seed_text = SEED
	context.seed_hash = context.hash_string(SEED)
	context.setup_noise()
	if context.seed_hash != 1769472797:
		return {"ok": false, "reason": "legacy_seed_hash_mismatch", "actual": context.seed_hash}
	var world = WorldScript.new()
	world.setup(context)
	context.set_generator(world)
	return {"ok": true, "context": context, "world": world}


func _sample(world, cell: Vector3i, edit, snapshot_source_revision: int) -> Dictionary:
	var position := Vector3(cell) * CELL
	var density: float
	var material_name: String
	var surface_biome: String
	var resolved_biome: String
	var fluid := ""
	var source_kind := "generated"
	var source_id := "generator:%s" % SEED
	var source_revision := snapshot_source_revision
	var surface_y := 0.0
	var surface_y_valid := false
	if edit is Dictionary and not edit.is_empty():
		density = float(edit.get("density"))
		material_name = String(edit.get("materialName"))
		surface_biome = String(edit.get("surfaceBiomeName"))
		resolved_biome = String(edit.get("resolvedBiomeName"))
		fluid = String(edit.get("fluid"))
		source_kind = "typed_delta"
		source_id = String(edit.get("deltaId"))
		source_revision = int(edit.get("deltaRevision"))
	else:
		var base_surface_y := float(world.terrain_reference_surface_y_at(position))
		surface_y = float(world.terrain_deformed_surface_y_at(position))
		surface_y_valid = true
		density = float(world.density_from_components(position, surface_y, base_surface_y))
		surface_biome = String(world.surface_biome_for_cell3(Vector3i(cell.x, 0, cell.z)))
		var depth := maxf(0.0, base_surface_y - position.y)
		material_name = "air" if density < 0.0 else String(world.generated_solid_material_for_cell(cell, base_surface_y, surface_biome, depth))
		resolved_biome = String(world.biome_from_sample_components(position, density, surface_y, depth / CELL, surface_biome))
	if not is_finite(density) or not MATERIAL_IDS.has(material_name) or not BIOME_IDS.has(surface_biome) or not BIOME_IDS.has(resolved_biome):
		return {"ok": false, "reason": "missing_or_invalid_oracle_field", "coordinate": _v3i(cell), "density": density, "material": material_name, "surfaceBiome": surface_biome, "resolvedBiome": resolved_biome}
	var material_id := int(MATERIAL_IDS[material_name])
	return {"ok": true, "sample": {
		"coordinate": _v3i(cell), "density": density, "solid": density >= 0.0,
		"surfaceY": surface_y, "surfaceYValid": surface_y_valid,
		"materialId": material_id, "materialName": material_name,
		"surfaceBiomeId": int(BIOME_IDS[surface_biome]), "surfaceBiomeName": surface_biome,
		"resolvedBiomeId": int(BIOME_IDS[resolved_biome]), "resolvedBiomeName": resolved_biome,
		"fluid": fluid, "sourceKind": source_kind, "sourceId": source_id,
		"sourceRevision": source_revision, "sdf": -density / CELL,
		"indices": material_id, "data5": material_id
	}}


func _decode_edits(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty():
		return {"ok": true, "edits": {}, "serialized": {"schema": "n2-typed-terrain-deltas/v1", "byteLength": 0, "bytesBase64": "", "sha256": "", "records": []}}
	var decoded = JSON.parse_string(bytes.get_string_from_utf8())
	if not decoded is Dictionary or decoded.get("schema") != "n2-typed-terrain-deltas/v1" or decoded.get("seed") != SEED or not decoded.get("records") is Array:
		return {"ok": false, "reason": "invalid_typed_delta_envelope"}
	var edits := {}
	var delta_ids := {}
	for value in decoded.records:
		if not value is Dictionary or not value.get("coordinate") is Array or value.coordinate.size() != 3:
			return {"ok": false, "reason": "invalid_typed_delta_record"}
		var cell := Vector3i(int(value.coordinate[0]), int(value.coordinate[1]), int(value.coordinate[2]))
		if edits.has(cell) or not EDIT_COORDINATES.has(cell):
			return {"ok": false, "reason": "duplicate_or_out_of_scope_typed_delta", "coordinate": _v3i(cell)}
		for required in ["density", "solid", "materialId", "materialName", "surfaceBiomeId", "surfaceBiomeName", "resolvedBiomeId", "resolvedBiomeName", "fluidId", "fluid", "deltaId", "deltaRevision"]:
			if not value.has(required):
				return {"ok": false, "reason": "typed_delta_field_missing", "field": required, "coordinate": _v3i(cell)}
		var density := float(value.density)
		var delta_id := String(value.deltaId)
		var expected_index := EDIT_COORDINATES.find(cell)
		if not is_finite(density) or density != -CELL or bool(value.solid) != (density >= 0.0) or bool(value.solid):
			return {"ok": false, "reason": "typed_delta_density_or_solidity_invalid", "coordinate": _v3i(cell)}
		if String(value.materialName) != "air" or int(value.materialId) != MATERIAL_IDS.air \
				or String(value.surfaceBiomeName) != "swamp" or int(value.surfaceBiomeId) != BIOME_IDS.swamp \
				or String(value.resolvedBiomeName) != "underground_air" or int(value.resolvedBiomeId) != BIOME_IDS.underground_air \
				or String(value.fluid) != "" or int(value.fluidId) != FLUID_IDS[""]:
			return {"ok": false, "reason": "typed_delta_material_or_biome_identity_invalid", "coordinate": _v3i(cell)}
		if delta_id != "n2:seam-air:%d" % expected_index or delta_ids.has(delta_id) or int(value.deltaRevision) != 1:
			return {"ok": false, "reason": "typed_delta_id_or_revision_invalid", "coordinate": _v3i(cell)}
		delta_ids[delta_id] = true
		edits[cell] = value
	if edits.size() != EDIT_COORDINATES.size():
		return {"ok": false, "reason": "frozen_typed_delta_set_incomplete", "expected": EDIT_COORDINATES.size(), "actual": edits.size()}
	return {"ok": true, "edits": edits, "serialized": {"schema": decoded.schema, "byteLength": bytes.size(), "bytesBase64": Marshalls.raw_to_base64(bytes), "sha256": _sha256(bytes), "records": decoded.records}}


func _noise_fixtures(context) -> Array:
	var configurations := [
		["height", context.height_noise, 1769607420], ["ridge", context.ridge_noise, 1769813314],
		["flat", context.flat_noise, 1770035046], ["moisture", context.moisture_noise, 1770320130],
		["temperature", context.temp_noise, 1770510186]
	]
	var rows: Array = []
	for configuration in configurations:
		var noise: FastNoiseLite = configuration[1]
		for coordinate in NOISE_COORDINATES:
			var sample_2d := float(noise.get_noise_2d(coordinate.x, coordinate.z))
			var sample_3d := float(noise.get_noise_3d(coordinate.x, coordinate.y, coordinate.z))
			rows.append({"configuration": configuration[0], "seed": configuration[2], "coordinate": _v3(coordinate), "twoDBits": _float32_bits(sample_2d), "threeDBits": _float32_bits(sample_3d)})
	return rows


func _anchors(by_coordinate: Dictionary, baseline: bool) -> Dictionary:
	var required := [Vector3i(-20, 13, -2), Vector3i(-20, 13, -1), Vector3i(-33, -2, -5), Vector3i(-32, -2, -5)]
	for cell in required:
		if not by_coordinate.has(_key(cell)):
			return {"ok": false, "reason": "frozen_anchor_missing", "coordinate": _v3i(cell)}
	var rows := {}
	for cell in required:
		rows[_key(cell)] = by_coordinate[_key(cell)]
	if float(rows["-20,13,-2"].surfaceY) != 17.901000000000003 \
			or float(rows["-20,13,-1"].surfaceY) != 17.901000000000003:
		return {"ok": false, "reason": "frozen_surface_anchor_mismatch", "anchors": rows}
	# These coordinates were caves only under the retired noise-only native
	# pocket. The recipe field leaves them as generated underground rock; keep
	# that distinction frozen so stale synthetic holes cannot pass as caves.
	if float(rows["-33,-2,-5"].density) != 8.0 \
			or float(rows["-32,-2,-5"].density) != 8.0 \
			or not bool(rows["-33,-2,-5"].solid) or not bool(rows["-32,-2,-5"].solid) \
			or String(rows["-33,-2,-5"].materialName) != "stone" \
			or String(rows["-32,-2,-5"].materialName) != "stone" \
			or String(rows["-33,-2,-5"].resolvedBiomeName) != "underground" \
			or String(rows["-32,-2,-5"].resolvedBiomeName) != "underground":
		return {"ok": false, "reason": "retired_noise_pocket_is_not_recipe_cave", "anchors": rows}
	if baseline:
		for cell in EDIT_COORDINATES:
			if not by_coordinate.has(_key(cell)):
				return {"ok": false, "reason": "edit_anchor_missing", "coordinate": _v3i(cell)}
			rows[_key(cell)] = by_coordinate[_key(cell)]
			if float(rows[_key(cell)].density) != 0.3260338576977162 or not bool(rows[_key(cell)].solid) \
					or String(rows[_key(cell)].materialName) != "mud":
				return {"ok": false, "reason": "frozen_edit_anchor_mismatch", "coordinate": _v3i(cell), "actual": rows[_key(cell)]}
	return {"ok": true, "anchors": rows}


func _float32_bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_u32(0)


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(bytes)
	return context.finish().hex_encode()


func _key(cell: Vector3i) -> String:
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]


func _v3i(value: Vector3i) -> Array:
	return [value.x, value.y, value.z]


func _v3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
