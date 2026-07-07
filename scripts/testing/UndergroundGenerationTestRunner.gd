extends SceneTree

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const SubsurfaceSystemScript := preload("res://scripts/SubsurfaceSystem.gd")

class FakeMain:
	const CELL := 1.35
	const MIN_HEIGHT := 4.0
	const MAX_HEIGHT := 120.0
	const WATER_LEVEL := 11.1
	const TOWN_REGION_CELLS := 280
	const TOWN_RADIUS_CELLS := 30

	var seed_text := "atlas-1492"
	var height_noise: FastNoiseLite
	var ridge_noise: FastNoiseLite
	var flat_noise: FastNoiseLite
	var moisture_noise: FastNoiseLite
	var temp_noise: FastNoiseLite
	var town_slope_apron_cache := {}
	var world_generation_system

	func _init() -> void:
		setup_noise()

	func setup_noise() -> void:
		height_noise = make_noise(13811, 0.018, 4)
		ridge_noise = make_noise(28191, 0.031, 4)
		flat_noise = make_noise(57831, 0.013, 3)
		moisture_noise = make_noise(77237, 0.010, 3)
		temp_noise = make_noise(91333, 0.009, 3)

	func make_noise(noise_seed: int, frequency: float, octaves: int) -> FastNoiseLite:
		var noise := FastNoiseLite.new()
		noise.seed = noise_seed
		noise.frequency = frequency
		noise.fractal_octaves = octaves
		noise.fractal_gain = 0.52
		return noise

	func town_region(_region_x: int, _region_z: int) -> Dictionary:
		return {}

	func noise01(noise: FastNoiseLite, x: float, z: float) -> float:
		return noise.get_noise_2d(x, z) * 0.5 + 0.5

	func smoothstep_range(value: float, low: float, high: float) -> float:
		if high == low:
			return 1.0 if value >= high else 0.0
		var t: float = clamp((value - low) / (high - low), 0.0, 1.0)
		return t * t * (3.0 - 2.0 * t)

	func hash01(text: String) -> float:
		return float(abs(hash_string("%s:%s" % [seed_text, text])) % 100000) / 100000.0

	func hash_string(text: String) -> int:
		var h := 2166136261
		for i in range(text.length()):
			h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
		return h

var results: Array[Dictionary] = []
var main
var world_generation
var subsurface
var seed := ""

func _init() -> void:
	call_deferred("run")

func run() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	main = FakeMain.new()
	main.seed_text = seed
	world_generation = WorldGenerationSystemScript.new()
	world_generation.setup(main)
	main.world_generation_system = world_generation
	subsurface = SubsurfaceSystemScript.new()
	subsurface.setup(main)
	test_sampler_ready()
	test_terrain_volume_section_authority()
	test_terrain_volume_section_payload_authority()
	test_terrain_volume_dirty_chunk_revision_queue()
	test_terrain_volume_light_channel()
	test_world_sample_determinism()
	test_underground_air_is_world_volume()
	test_world_bottom_bedrock()
	test_static_terrain_fluid_channels()
	test_subsurface_queries_use_volume()
	test_terrain_volume_occupancy_projection()
	test_subsurface_excavation_save_load()
	test_no_runtime_brush_authority()
	save_report()
	quit(0 if all_passed() else 1)

func test_sampler_ready() -> void:
	add_result(
		"underground_sampler_ready",
		world_generation != null \
			and world_generation.has_method("sample_cell") \
			and world_generation.has_method("sample_world") \
			and world_generation.has_method("density_at") \
			and world_generation.has_method("solid_at") \
			and world_generation.has_method("biome_at") \
			and world_generation.has_method("material_at") \
			and world_generation.has_method("get_cell_state") \
			and world_generation.has_method("set_cell_state") \
			and world_generation.has_method("apply_box_edit") \
			and world_generation.has_method("request_section") \
			and world_generation.has_method("section_payload_for_bounds") \
			and world_generation.has_method("save_section_delta") \
			and world_generation.has_method("load_section") \
			and world_generation.has_method("mark_section_dirty") \
			and world_generation.has_method("exposed_surface_cells") \
			and world_generation.has_method("terrain_occupancy_at_cell") \
			and world_generation.has_method("surface_projection_for_cell") \
			and world_generation.has_method("walkable_surface_cell_near") \
			and world_generation.has_method("terrain_volume_chunk_revision") \
			and world_generation.has_method("consume_terrain_volume_dirty_chunk_keys") \
			and world_generation.has_method("find_underground_air_sample"),
		"world generation exposes TerrainVolumeService-backed underground volume API"
	)

func test_terrain_volume_section_authority() -> void:
	var section: Dictionary = world_generation.call("request_section", Vector2i(0, 0), 0)
	var states: Dictionary = section.get("states", {}) if section.get("states", {}) is Dictionary else {}
	var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
	var material_ids: PackedStringArray = channels.get("materialIds", PackedStringArray())
	var biome_ids: PackedStringArray = channels.get("biomeIds", PackedStringArray())
	var fluid_ids: PackedStringArray = channels.get("fluidIds", PackedStringArray())
	var solid_cells: PackedByteArray = channels.get("solid", PackedByteArray())
	var density_values: PackedFloat32Array = channels.get("density", PackedFloat32Array())
	var sky_light: PackedByteArray = channels.get("skyLight", PackedByteArray())
	var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
	var metadata_by_index: Dictionary = channels.get("metadataByIndex", {}) if channels.get("metadataByIndex", {}) is Dictionary else {}
	var section_ready := int(section.get("sectionSize", 0)) == 16 and states.size() == 4096
	var channel_ready := int(section.get("channelSchema", 0)) == 1 \
		and material_ids.size() == 4096 \
		and biome_ids.size() == 4096 \
		and fluid_ids.size() == 4096 \
		and solid_cells.size() == 4096 \
		and density_values.size() == 4096 \
		and sky_light.size() == 4096 \
		and block_light.size() == 4096
	var cell := Vector3i(2, 8, 2)
	var before: Dictionary = world_generation.call("get_cell_state", cell)
	var edited: Dictionary = world_generation.call("set_cell_state", cell, {
		"material": "air",
		"biome": "underground_air",
		"solid": false,
		"fluid": "",
		"light": { "sky": 0, "block": 0 },
		"metadata": { "test": "terrain_volume_section_authority" }
	}, "contract_test")
	var after: Dictionary = world_generation.call("get_cell_state", cell)
	var section_after: Dictionary = world_generation.call("request_section", Vector2i(0, 0), 0)
	var channels_after: Dictionary = section_after.get("channels", {}) if section_after.get("channels", {}) is Dictionary else {}
	var material_ids_after: PackedStringArray = channels_after.get("materialIds", PackedStringArray())
	var solid_cells_after: PackedByteArray = channels_after.get("solid", PackedByteArray())
	var density_values_after: PackedFloat32Array = channels_after.get("density", PackedFloat32Array())
	var edited_index := int(cell.x) + 16 * (int(cell.y) + 16 * int(cell.z))
	var channel_edit_applied := edited_index >= 0 \
		and edited_index < material_ids_after.size() \
		and edited_index < solid_cells_after.size() \
		and edited_index < density_values_after.size() \
		and String(material_ids_after[edited_index]) == "air" \
		and int(solid_cells_after[edited_index]) == 0 \
		and float(density_values_after[edited_index]) < 0.0
	var box_min := Vector3i(3, 7, 2)
	var box_max := Vector3i(4, 7, 2)
	world_generation.call("apply_box_edit", box_min, box_max, {
		"material": "stone",
		"biome": "underground",
		"solid": true,
		"density": main.CELL,
		"fluid": "",
		"light": { "sky": 0, "block": 0 },
		"metadata": { "test": "terrain_volume_box_section_channel_authority" }
	}, "box_channel_contract")
	var section_after_box: Dictionary = world_generation.call("request_section", Vector2i(0, 0), 0)
	var channels_after_box: Dictionary = section_after_box.get("channels", {}) if section_after_box.get("channels", {}) is Dictionary else {}
	var material_ids_after_box: PackedStringArray = channels_after_box.get("materialIds", PackedStringArray())
	var solid_cells_after_box: PackedByteArray = channels_after_box.get("solid", PackedByteArray())
	var density_values_after_box: PackedFloat32Array = channels_after_box.get("density", PackedFloat32Array())
	var box_index := int(box_min.x) + 16 * (int(box_min.y) + 16 * int(box_min.z))
	var box_channel_edit_applied := box_index >= 0 \
		and box_index < material_ids_after_box.size() \
		and box_index < solid_cells_after_box.size() \
		and box_index < density_values_after_box.size() \
		and String(material_ids_after_box[box_index]) == "stone" \
		and int(solid_cells_after_box[box_index]) == 1 \
		and float(density_values_after_box[box_index]) > 0.0
	var sample_position := Vector3((float(cell.x) + 0.5) * main.CELL, (float(cell.y) + 0.5) * main.CELL, (float(cell.z) + 0.5) * main.CELL)
	var sample: Dictionary = world_generation.call("sample_world", sample_position)
	var section_key: Vector3i = after.get("sectionKey", Vector3i.ZERO)
	var delta: Dictionary = world_generation.call("save_section_delta", section_key)
	var restored = WorldGenerationSystemScript.new()
	restored.setup(main)
	restored.call("load_section", section_key, delta)
	var restored_state: Dictionary = restored.call("get_cell_state", cell)
	var exposed: Array = world_generation.call("exposed_surface_cells", Vector2i(0, 0))
	var passed := section_ready \
		and channel_ready \
		and bool(edited.get("edited", false)) \
		and bool(after.get("edited", false)) \
		and channel_edit_applied \
		and box_channel_edit_applied \
		and String(after.get("material", "")) == "air" \
		and not bool(after.get("solid", true)) \
		and String(sample.get("material", "")) == "air" \
		and not bool(sample.get("solid", true)) \
		and (delta.get("cells", []) is Array) \
		and (delta.get("cells", []) as Array).size() >= 1 \
		and String(restored_state.get("material", "")) == "air" \
		and not exposed.is_empty()
	add_result("terrain_volume_section_cell_delta_authority", passed, JSON.stringify(sanitize({
		"sectionReady": section_ready,
		"channelReady": channel_ready,
		"stateCount": states.size(),
		"materialChannelCount": material_ids.size(),
		"biomeChannelCount": biome_ids.size(),
		"solidChannelCount": solid_cells.size(),
		"densityChannelCount": density_values.size(),
		"channelEditApplied": channel_edit_applied,
		"boxChannelEditApplied": box_channel_edit_applied,
		"metadataChannelCount": metadata_by_index.size(),
		"before": before,
		"after": after,
		"sample": sample_signature(sample),
		"deltaCellCount": (delta.get("cells", []) as Array).size() if delta.get("cells", []) is Array else 0,
		"restored": restored_state,
		"exposedCount": exposed.size()
	})))
	world_generation.call("reset")

func test_terrain_volume_section_payload_authority() -> void:
	world_generation.call("reset")
	var edit_cell := Vector3i(34, -5, 34)
	var light_cell := edit_cell + Vector3i(1, 0, 0)
	world_generation.call("set_cell_state", edit_cell, {
		"material": "air",
		"biome": "underground_air",
		"solid": false,
		"fluid": "",
		"light": { "sky": 0, "block": 0 },
		"metadata": { "test": "payload_edit_before_section" }
	}, "payload_edit_before_section")
	world_generation.call("set_cell_light", light_cell, { "sky": 0, "block": 9 }, "payload_light_before_section")
	var payload_value = world_generation.call("section_payload_for_bounds", edit_cell - Vector3i(1, 1, 1), light_cell + Vector3i(1, 1, 1))
	var payload: Dictionary = payload_value if payload_value is Dictionary else {}
	var edit_state: Dictionary = world_generation.call("get_cell_state", edit_cell)
	var section_key: Vector3i = edit_state.get("sectionKey", Vector3i.ZERO)
	var section := payload_section_for_key(payload, section_key)
	var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
	var material_ids: PackedStringArray = channels.get("materialIds", PackedStringArray())
	var solid_cells: PackedByteArray = channels.get("solid", PackedByteArray())
	var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
	var edit_index := section_payload_local_index(edit_cell)
	var light_index := section_payload_local_index(light_cell)
	var edit_in_payload := edit_index >= 0 \
		and edit_index < material_ids.size() \
		and edit_index < solid_cells.size() \
		and String(material_ids[edit_index]) == "air" \
		and int(solid_cells[edit_index]) == 0
	var light_in_payload := light_index >= 0 \
		and light_index < block_light.size() \
		and int(block_light[light_index]) == 9
	var sections_value = payload.get("sections", [])
	var section_count := (sections_value as Array).size() if sections_value is Array else 0
	var passed := not payload.is_empty() \
		and section_count >= 1 \
		and not section.is_empty() \
		and edit_in_payload \
		and light_in_payload
	add_result("terrain_volume_section_payload_authority", passed, JSON.stringify(sanitize({
		"sectionKey": section_key,
		"sectionCount": section_count,
		"editIndex": edit_index,
		"lightIndex": light_index,
		"editInPayload": edit_in_payload,
		"lightInPayload": light_in_payload,
		"schemaVersion": int(payload.get("schemaVersion", 0))
	})))
	world_generation.call("reset")

func test_terrain_volume_dirty_chunk_revision_queue() -> void:
	var chunk_key := Vector2i(1, 1)
	var cell := Vector3i(18, -4, 18)
	var before_revision := int(world_generation.call("terrain_volume_chunk_revision", chunk_key, 16))
	world_generation.call("set_cell_state", cell, {
		"material": "air",
		"biome": "underground_air",
		"solid": false,
		"fluid": "",
		"light": { "sky": 0, "block": 0 },
		"metadata": { "test": "terrain_volume_dirty_chunk_revision_queue" }
	}, "dirty_chunk_contract")
	var after_revision := int(world_generation.call("terrain_volume_chunk_revision", chunk_key, 16))
	var dirty_chunks: Array = world_generation.call("consume_terrain_volume_dirty_chunk_keys", 16)
	var second_consume: Array = world_generation.call("consume_terrain_volume_dirty_chunk_keys", 16)
	var retained_revision := int(world_generation.call("terrain_volume_chunk_revision", chunk_key, 16))
	var passed := after_revision > before_revision \
		and dirty_chunks.has(chunk_key) \
		and second_consume.is_empty() \
		and retained_revision == after_revision
	add_result("terrain_volume_dirty_chunk_revision_queue", passed, JSON.stringify({
		"cell": sanitize(cell),
		"chunkKey": sanitize(chunk_key),
		"beforeRevision": before_revision,
		"afterRevision": after_revision,
		"retainedRevision": retained_revision,
		"dirtyChunks": sanitize(dirty_chunks),
		"secondConsumeCount": second_consume.size()
	}))
	world_generation.call("reset")

func test_terrain_volume_light_channel() -> void:
	var cell := Vector3i(3, 18, 3)
	if not world_generation.has_method("set_cell_light") or not world_generation.has_method("light_at_cell"):
		add_result("terrain_volume_light_channel", false, "missing light channel API")
		return
	world_generation.call("set_cell_light", cell, { "sky": 0, "block": 12 }, "contract_light")
	var light: Dictionary = world_generation.call("light_at_cell", cell)
	var neighbor_light: Dictionary = world_generation.call("light_at_cell", cell + Vector3i(1, 0, 0))
	var section: Dictionary = world_generation.call("request_section", Vector3i(0, 1, 0), 0)
	var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
	var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
	var local := Vector3i(posmod(cell.x, 16), posmod(cell.y, 16), posmod(cell.z, 16))
	var light_index := int(local.x) + 16 * (int(local.y) + 16 * int(local.z))
	var section_block_light := int(block_light[light_index]) if light_index >= 0 and light_index < block_light.size() else -1
	var snapshot: Dictionary = world_generation.call("save_terrain_volume_deltas") if world_generation.has_method("save_terrain_volume_deltas") else {}
	var section_count := array_size(snapshot.get("sections", []))
	var passed := int(light.get("block", 0)) == 12 and int(neighbor_light.get("block", 0)) == 11 and section_block_light == 12 and section_count == 0
	add_result("terrain_volume_light_channel", passed, JSON.stringify({
		"cell": sanitize(cell),
		"light": sanitize(light),
		"neighborLight": sanitize(neighbor_light),
		"sectionBlockLight": section_block_light,
		"materialDeltaSections": section_count
	}))
	world_generation.call("reset")

func test_world_sample_determinism() -> void:
	var cells: Array[Vector3i] = [
		Vector3i(0, 12, 0),
		Vector3i(18, 8, -24),
		Vector3i(-35, 20, 42),
		Vector3i(96, 16, 96)
	]
	var stable := true
	var signatures := []
	for cell in cells:
		var first: Dictionary = world_generation.call("sample_cell", cell)
		var second: Dictionary = world_generation.call("sample_cell", cell)
		var first_signature := sample_signature(first)
		var second_signature := sample_signature(second)
		stable = stable and JSON.stringify(first_signature) == JSON.stringify(second_signature)
		signatures.append(first_signature)
	add_result("underground_sample_determinism", stable, JSON.stringify(signatures))

func test_underground_air_is_world_volume() -> void:
	var found: Dictionary = world_generation.call("find_underground_air_sample", 16, 4, 30)
	var sample: Dictionary = found.get("sample", {}) if found.has("sample") else {}
	var position: Vector3 = found.get("position", Vector3.ZERO)
	var by_world: Dictionary = world_generation.call("sample_world", position)
	var passed := not found.is_empty() \
		and String(sample.get("biome", "")) == "underground_air" \
		and String(sample.get("material", "")) == "air" \
		and not bool(sample.get("solid", true)) \
		and JSON.stringify(sample_signature(sample)) == JSON.stringify(sample_signature(by_world))
	add_result("underground_air_from_world_volume", passed, JSON.stringify(sanitize(found)))

func test_world_bottom_bedrock() -> void:
	var bottom_y := int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
	var bedrock_cell := Vector3i(0, bottom_y, 0)
	var bedrock_sample: Dictionary = world_generation.call("sample_cell", bedrock_cell)
	var above_cell := Vector3i(0, bottom_y + 6, 0)
	var above_sample: Dictionary = world_generation.call("sample_cell", above_cell)
	var passed := bool(bedrock_sample.get("solid", false)) \
		and String(bedrock_sample.get("material", "")) == "bedrock" \
		and bool(above_sample.get("solid", false)) \
		and String(above_sample.get("material", "")) != "air"
	add_result("underground_world_bottom_bedrock", passed, JSON.stringify({
		"bottomCellY": bottom_y,
		"bedrock": sample_signature(bedrock_sample),
		"above": sample_signature(above_sample)
	}))

func test_static_terrain_fluid_channels() -> void:
	var found := {}
	var bottom_y := int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
	for y in range(bottom_y + 3, 12):
		if not found.is_empty():
			break
		for z in range(-56, 57, 4):
			if not found.is_empty():
				break
			for x in range(-56, 57, 4):
				var cell := Vector3i(x, y, z)
				var sample: Dictionary = world_generation.call("sample_cell", cell)
				var fluid := String(sample.get("fluid", ""))
				if fluid == "":
					continue
				if bool(sample.get("solid", true)):
					continue
				found = {
					"cell": cell,
					"fluid": fluid,
					"sample": sample_signature(sample),
					"subsurfaceSolid": bool(subsurface.call("subsurface_is_solid", cell))
				}
				break
	var passed := not found.is_empty() and String(found.get("fluid", "")) in ["water", "lava"] and not bool(found.get("subsurfaceSolid", true))
	add_result("terrain_volume_static_fluid_channels", passed, JSON.stringify(sanitize(found)))

func test_subsurface_queries_use_volume() -> void:
	var surface := find_exposed_surface_cell(Vector2i(20, 20))
	var solid_cell: Vector3i = surface.get("solidCell", Vector3i.ZERO)
	var air_cell: Vector3i = surface.get("airCell", Vector3i.ZERO)
	var solid_material := String(subsurface.call("subsurface_material_at", solid_cell))
	var air_material := String(subsurface.call("subsurface_material_at", air_cell))
	var biome := String(subsurface.call("subsurface_biome_at", solid_cell))
	var passed := not surface.is_empty() \
		and solid_material != "" \
		and solid_material != "air" \
		and air_material == "air" \
		and biome != ""
	add_result(
		"subsurface_queries_use_3d_volume",
		passed,
		"solid=%s air=%s biome=%s cells=%s" % [solid_material, air_material, biome, JSON.stringify(sanitize(surface))]
	)

func test_terrain_volume_occupancy_projection() -> void:
	var surface := find_exposed_surface_cell(Vector2i(22, 22))
	if surface.is_empty():
		add_result("terrain_volume_occupancy_projection", false, "no exposed surface sample")
		return
	var air_cell: Vector3i = surface.get("airCell", Vector3i.ZERO)
	var solid_cell: Vector3i = surface.get("solidCell", Vector3i.ZERO)
	var occupancy: Dictionary = world_generation.call("terrain_occupancy_at_cell", air_cell)
	var projection: Dictionary = world_generation.call("surface_projection_for_cell", Vector3i(air_cell.x, air_cell.y, air_cell.z), 8, 16)
	var walkable: Dictionary = world_generation.call("walkable_surface_cell_near", Vector3i(air_cell.x, air_cell.y, air_cell.z), 8, 16)
	var projected_solid: Vector3i = projection.get("solidCell", Vector3i.ZERO)
	var passed := bool(occupancy.get("walkableAir", false)) \
		and bool(projection.get("found", false)) \
		and projected_solid == solid_cell \
		and bool(walkable.get("found", false)) \
		and bool(walkable.get("walkable", false))
	add_result("terrain_volume_occupancy_projection", passed, JSON.stringify(sanitize({
		"airCell": air_cell,
		"solidCell": solid_cell,
		"occupancy": occupancy,
		"projection": projection,
		"walkable": walkable
	})))

func test_subsurface_excavation_save_load() -> void:
	var surface := find_exposed_surface_cell(Vector2i(24, 24))
	if surface.is_empty():
		add_result("subsurface_excavation_save_load", false, "no exposed surface sample")
		return
	if subsurface.has_method("reset"):
		subsurface.call("reset")
	var solid_cell: Vector3i = surface.get("solidCell", Vector3i.ZERO)
	var center := Vector3((float(solid_cell.x) + 0.5) * main.CELL, (float(solid_cell.y) + 0.5) * main.CELL, (float(solid_cell.z) + 0.5) * main.CELL)
	var brush: Dictionary = subsurface.call("add_excavation_brush", center, main.CELL * 1.35)
	var air_after_brush := not bool(subsurface.call("subsurface_is_solid", solid_cell))
	var terrain_volume_delta: Dictionary = world_generation.call("save_terrain_volume_deltas") if world_generation.has_method("save_terrain_volume_deltas") else {}
	var terrain_volume_sections := array_size(terrain_volume_delta.get("sections", []))
	var snapshot: Dictionary = subsurface.call("snapshot")
	var saved_count := array_size(snapshot.get("excavationBrushes", []))
	var legacy_snapshot := {
		"version": 3,
		"excavationSequence": 1,
		"excavationBrushes": [{
			"id": String(brush.get("id", "dig:legacy")),
			"x": center.x,
			"y": center.y,
			"z": center.z,
			"radius": float(brush.get("radius", main.CELL * 1.35)),
			"mode": String(brush.get("mode", "volume")),
			"surfaceY": float(brush.get("surfaceY", center.y)),
			"surfaceTargetY": float(brush.get("surfaceTargetY", center.y)),
			"deformRadius": float(brush.get("deformRadius", brush.get("radius", main.CELL * 1.35)))
		}]
	}
	subsurface.call("reset")
	var solid_after_reset := bool(subsurface.call("subsurface_is_solid", solid_cell))
	if world_generation.has_method("load_terrain_volume_deltas"):
		world_generation.call("load_terrain_volume_deltas", terrain_volume_delta)
	var air_after_volume_restore := not bool(subsurface.call("subsurface_is_solid", solid_cell))
	subsurface.call("reset")
	subsurface.call("restore", legacy_snapshot)
	var air_after_legacy_restore := not bool(subsurface.call("subsurface_is_solid", solid_cell))
	add_result(
		"subsurface_excavation_save_load",
		air_after_brush \
			and solid_after_reset \
			and air_after_volume_restore \
			and air_after_legacy_restore \
			and saved_count == 0 \
			and String(snapshot.get("authority", "")) == "terrainVolume" \
			and terrain_volume_sections >= 1 \
			and String(brush.get("id", "")) != "",
		"brush=%s savedCount=%d authority=%s terrainVolumeSections=%d airAfterBrush=%s solidAfterReset=%s airAfterVolumeRestore=%s airAfterLegacyRestore=%s" % [JSON.stringify(sanitize(brush)), saved_count, String(snapshot.get("authority", "")), terrain_volume_sections, str(air_after_brush), str(solid_after_reset), str(air_after_volume_restore), str(air_after_legacy_restore)]
	)

func test_no_runtime_brush_authority() -> void:
	var surface := find_exposed_surface_cell(Vector2i(26, 26))
	if surface.is_empty():
		add_result("terrain_volume_no_runtime_brush_authority", false, "no exposed surface sample")
		return
	if subsurface.has_method("reset"):
		subsurface.call("reset")
	var solid_cell: Vector3i = surface.get("solidCell", Vector3i.ZERO)
	var center := Vector3((float(solid_cell.x) + 0.5) * main.CELL, (float(solid_cell.y) + 0.5) * main.CELL, (float(solid_cell.z) + 0.5) * main.CELL)
	var edit_record: Dictionary = subsurface.call("add_excavation_brush", center, main.CELL * 1.35)
	var air_after_edit := not bool(subsurface.call("subsurface_is_solid", solid_cell))
	var volume_delta: Dictionary = world_generation.call("save_terrain_volume_deltas") if world_generation.has_method("save_terrain_volume_deltas") else {}
	var section_count := array_size(volume_delta.get("sections", []))
	var edit_count := int(world_generation.call("terrain_volume_edit_count", true)) if world_generation.has_method("terrain_volume_edit_count") else 0
	var world_brush_count := array_size(world_generation.get("excavation_brushes"))
	var subsurface_brush_count := array_size(subsurface.get("excavation_brushes"))
	var passed := air_after_edit \
		and section_count >= 1 \
		and edit_count > 0 \
		and world_brush_count == 0 \
		and subsurface_brush_count == 0
	add_result(
		"terrain_volume_no_runtime_brush_authority",
		passed,
		"record=%s sections=%d editCount=%d worldBrushes=%d subsurfaceBrushes=%d airAfterEdit=%s" % [JSON.stringify(sanitize(edit_record)), section_count, edit_count, world_brush_count, subsurface_brush_count, str(air_after_edit)]
	)
	if subsurface.has_method("reset"):
		subsurface.call("reset")

func find_exposed_surface_cell(column: Vector2i) -> Dictionary:
	var bottom_y := int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
	for y in range(96, bottom_y, -1):
		var air_cell := Vector3i(column.x, y + 1, column.y)
		var solid_cell := Vector3i(column.x, y, column.y)
		var air_sample: Dictionary = world_generation.call("sample_cell", air_cell)
		var solid_sample: Dictionary = world_generation.call("sample_cell", solid_cell)
		if not bool(air_sample.get("solid", true)) and bool(solid_sample.get("solid", false)):
			return {
				"airCell": air_cell,
				"solidCell": solid_cell,
				"airSample": sample_signature(air_sample),
				"solidSample": sample_signature(solid_sample)
			}
	return {}

func sample_signature(sample: Dictionary) -> Dictionary:
	return {
		"density": snapped_float(float(sample.get("density", 0.0))),
		"solid": bool(sample.get("solid", false)),
		"biome": String(sample.get("biome", "")),
		"material": String(sample.get("material", "")),
		"fluid": String(sample.get("fluid", "")),
		"surface": bool(sample.get("surface", false))
	}

func payload_section_for_key(payload: Dictionary, section_key: Vector3i) -> Dictionary:
	var sections_value = payload.get("sections", [])
	if not (sections_value is Array):
		return {}
	for section_value in sections_value:
		if not (section_value is Dictionary):
			continue
		var section: Dictionary = section_value
		if section.get("sectionKey", Vector3i.ZERO) == section_key:
			return section
	return {}

func section_payload_local_index(cell: Vector3i) -> int:
	var local := Vector3i(posmod(cell.x, 16), posmod(cell.y, 16), posmod(cell.z, 16))
	return int(local.x) + 16 * (int(local.y) + 16 * int(local.z))

func snapped_float(value: float) -> float:
	return snappedf(value, 0.001)

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func all_passed() -> bool:
	for result in results:
		if not bool(result.get("passed", false)):
			return false
	return true

func save_report() -> void:
	var report := {
		"schemaVersion": 3,
		"runnerId": "underground_generation_contract",
		"testId": "underground_volume_generation_contract",
		"seed": seed,
		"finished": true,
		"passed": all_passed(),
		"evidenceLevel": "contract",
		"scope": "Authoritative 3D solid/air/biome/material underground generation and excavation contracts; not headed visual acceptance.",
		"resultCount": results.size(),
		"failureCount": failure_count(),
		"results": results
	}
	var report_path := OS.get_environment("VOXEL_UNDERGROUND_GENERATION_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/underground/underground-generation-report.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify(report, "  "))

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func array_size(value) -> int:
	return value.size() if value is Array else 0

func sanitize(value):
	if value is Vector2i:
		return { "x": value.x, "z": value.y }
	if value is Vector3i:
		return { "x": value.x, "y": value.y, "z": value.z }
	if value is Vector3:
		return { "x": snapped_float(value.x), "y": snapped_float(value.y), "z": snapped_float(value.z) }
	if value is Array:
		var result := []
		for item in value:
			result.append(sanitize(item))
		return result
	if value is Dictionary:
		var dict := {}
		for key in value.keys():
			dict[String(key)] = sanitize(value[key])
		return dict
	return value
