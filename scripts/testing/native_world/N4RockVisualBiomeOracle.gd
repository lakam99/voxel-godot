extends SceneTree

# Direct Godot service oracle. No gameplay scene or native backend is involved.
const WorldOracle := preload("res://scripts/testing/native_world/N3EffectiveTerrainOracle.gd")
const MainTools := preload("res://scripts/Main.gd")
const EnvironmentCatalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const VisualRegistry := preload("res://scripts/visual/VisualAssetRegistry.gd")
const CELL := 1.35

func _row(main: Node3D, parent: Node3D, label: String, local: Vector3) -> Dictionary:
	var world_anchor: Vector3 = parent.global_transform * local
	var cell := Vector3i(main.world_to_cell(world_anchor.x), main.world_to_cell(world_anchor.y), main.world_to_cell(world_anchor.z))
	var expected := String(main.world_generation_system.surface_biome_for_cell3(cell))
	var actual := String(main.prop_biome_for_position(parent, local))
	return {
		"label": label, "local": [local.x, local.y, local.z],
		"chunkOrigin": [parent.global_position.x, parent.global_position.y, parent.global_position.z],
		"worldAnchor": [world_anchor.x, world_anchor.y, world_anchor.z],
		"worldAnchorBits": [PackedFloat32Array([world_anchor.x]).to_byte_array().decode_u32(0),
			PackedFloat32Array([world_anchor.z]).to_byte_array().decode_u32(0)],
		"lookupCell": [cell.x, cell.y, cell.z], "visualBiome": actual,
		"surfaceBiome": expected, "passed": actual == expected,
	}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var town := {Vector2i(0, 0): {"regionX": 0, "regionZ": 0, "centerX": 0, "centerZ": 0, "radius": 8, "level": 20.0}}
	var bundle: Dictionary = WorldOracle.build_world("atlas-1492", [], town)
	if not bool(bundle.get("ok", false)):
		push_error("N4 rock visual biome world setup failed: %s" % str(bundle))
		quit(1)
		return
	var main: Node3D = MainTools.new()
	main.world_generation_system = bundle.world
	var parent := Node3D.new()
	root.add_child(parent)
	var rows: Array[Dictionary] = []
	parent.global_position = Vector3.ZERO
	for value in [-0.675001, -0.675, -0.674999, 0.674999, 0.675, 0.675001]:
		rows.append(_row(main, parent, "half_cell_%s" % str(value), Vector3(value, 17.0, value)))
	for chunk in [Vector2i(-2, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(9, -7)]:
		parent.global_position = Vector3(float(chunk.x * 28) * CELL, 0.0, float(chunk.y * 28) * CELL)
		for offset in [Vector2i(2, 2), Vector2i(26, 26)]:
			rows.append(_row(main, parent, "chunk_%s_offset_%s" % [str(chunk), str(offset)],
				Vector3(float(offset.x) * CELL, 17.0, float(offset.y) * CELL)))
	parent.global_position = Vector3.ZERO
	rows.append(_row(main, parent, "town_core", Vector3(0.0, 17.0, 0.0)))
	var shore := {"ocean": Vector2i(2147483647, 0), "beach": Vector2i(2147483647, 0)}
	for z in range(-512, 513, 8):
		if shore.ocean.x != 2147483647 and shore.beach.x != 2147483647:
			break
		for x in range(-512, 513, 8):
			var biome := String(bundle.world.surface_biome_for_cell3(Vector3i(x, 0, z)))
			if shore.has(biome) and shore[biome].x == 2147483647:
				shore[biome] = Vector2i(x, z)
	for kind in ["ocean", "beach"]:
		var cell: Vector2i = shore[kind]
		if cell.x != 2147483647:
			rows.append(_row(main, parent, kind, Vector3(float(cell.x) * CELL, 17.0, float(cell.y) * CELL)))
	var edit_surface := float(bundle.world.terrain_surface_y_at(Vector3(36.0 * CELL, 0.0, 36.0 * CELL)))
	var edit_cell := Vector3i(36, floori(edit_surface / CELL) + 2, 36)
	var source_biome := String(bundle.world.surface_biome_for_cell3(edit_cell))
	var edit_biome := "desert" if source_biome != "desert" else "forest"
	var edited: Dictionary = bundle.volume.set_cell_state(edit_cell, {
		"density": 2.0, "solid": true, "material": "stone", "biome": edit_biome,
		"metadata": {"source": "terrain_edit"}, "saveDelta": true,
	}, "n4_rock_visual_oracle", false)
	rows.append(_row(main, parent, "edited_surface_visual", Vector3(float(edit_cell.x) * CELL, 17.0, float(edit_cell.z) * CELL)))
	var spawn: Dictionary = main.surface_volume_spawn_sample_at_cell(edit_cell.x, edit_cell.z)
	var environment = EnvironmentCatalog.new()
	var assets = VisualRegistry.new()
	var asset_ready: bool = environment.setup()
	assets.environment_catalog = environment
	asset_ready = assets.load_manifest() and asset_ready
	var asset_rows: Array[Dictionary] = []
	for query in [
		{"biome": "forest", "id": "atlas-1492:10,20:3"},
		{"biome": "swamp", "id": "atlas-1492:10,20:3"},
		{"biome": "desert", "id": "atlas-1492:10,20:3"},
		{"biome": "future_biome", "id": "atlas-1492:10,20:3"},
		{"biome": "forest", "id": "世界🌲:10,20:3"},
	]:
		var biome: String = query.biome
		var durable_id: String = query.id
		var selected: String = assets.select_rock_asset_id(biome, durable_id)
		var record: Dictionary = assets.asset_record(selected)
		var size: Vector3 = assets.asset_size(selected)
		asset_rows.append({"biome": biome, "durableId": durable_id, "selectedAssetId": selected,
			"assetSize": [size.x, size.y, size.z], "rockScale": assets.rock_scale_for_biome(biome),
			"tags": record.get("biomeTags", []),
			"stableHash": assets.stable_hash("rock:%s:%s" % [biome, durable_id])})
	var disabled_selected: String = asset_rows[0].selectedAssetId
	assets.disable_asset_for_test(disabled_selected)
	var disabled_still_selected := assets.select_rock_asset_id("forest", "atlas-1492:10,20:3") == disabled_selected
	var disabled_cannot_instantiate := assets.instantiate_asset(disabled_selected) == null
	var report := {"schema": "n4-rock-visual-biome-oracle/v1", "seed": "atlas-1492",
		"rows": rows, "shoreCells": shore, "editedCell": [edit_cell.x, edit_cell.y, edit_cell.z],
		"editedState": edited, "editedSpawn": spawn, "assetRows": asset_rows,
		"assetReady": asset_ready, "disabledStillSelected": disabled_still_selected,
		"disabledCannotInstantiate": disabled_cannot_instantiate,
		"passed": rows.all(func(row: Dictionary) -> bool: return bool(row.passed))
			and [rows[0].lookupCell[0], rows[1].lookupCell[0], rows[2].lookupCell[0],
				rows[3].lookupCell[0], rows[4].lookupCell[0], rows[5].lookupCell[0]] == [-1, -1, 0, 0, 1, 1]
			and shore.ocean.x != 2147483647 and shore.beach.x != 2147483647
			and rows[14].visualBiome == "town" and rows[15].visualBiome == "ocean"
			and rows[16].visualBiome == "beach"
			and String(rows.back().visualBiome) == source_biome
			and bool(spawn.get("found", false)) and String(spawn.get("biome", "")) == edit_biome
			and asset_ready and asset_rows.size() == 5
			and asset_rows.all(func(row: Dictionary) -> bool: return not String(row.selectedAssetId).is_empty())
			and disabled_still_selected and disabled_cannot_instantiate}
	var output_path := OS.get_environment("N4_ROCK_VISUAL_BIOME_ORACLE_REPORT")
	if not output_path.is_empty():
		var output := FileAccess.open(output_path, FileAccess.WRITE)
		if output == null:
			push_error("N4 rock visual biome report open failed")
			quit(1)
			return
		output.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	root.remove_child(parent)
	parent.free()
	main.free()
	quit(0 if report.passed else 1)
