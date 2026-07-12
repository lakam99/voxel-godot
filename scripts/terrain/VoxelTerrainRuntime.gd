extends Node3D
class_name VoxelTerrainRuntime

const GENERATOR_SCRIPT := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
const CONTEXT_SCRIPT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const TERRAIN_SHADER := preload("res://shaders/voxel_terrain_authority.gdshader")

const CELL := 1.35
const GAME_CHUNK_SIZE := 28
const TERRAIN_COLLISION_LAYER := 2
const VIEW_DISTANCE := 112
const SECTION_SIZE := 16
const EDIT_SECTIONS_PER_FRAME := 1
const PUBLICATION_PROBES_PER_PHYSICS_FRAME := 2
const COLLISION_SURFACE_TOLERANCE := CELL * 2.5
const COLLISION_MESH_VERTICAL_MARGIN_CELLS := 4
const MATERIAL_IDS := {
	"air": 0, "grass": 1, "dirt": 2, "stone": 3, "sand": 4, "snow": 5,
	"deepStone": 6, "bedrock": 7, "clay": 8, "gravel": 9, "coalOre": 10,
	"ironOre": 11, "crystalOre": 12, "copperOre": 13, "mud": 14, "water": 15
}

var main
var terrain: VoxelTerrain
var viewer: VoxelViewer
var generator
var authority_ready := false
var published_mesh_blocks := {}
var configured_seed := ""
var last_volume_revision := -1
var applied_edit_signatures := {}
var pending_edit_sections := {}
var edit_batches_applied := 0
var desired_gameplay_chunks := {}
var pending_gameplay_chunks := {}
var published_gameplay_chunks := {}
var collision_probe_attempts := 0
var collision_probe_passes := 0

func setup(main_node) -> Dictionary:
	main = main_node
	configured_seed = String(main.get("seed_text"))
	if not required_classes_available():
		return {"ok": false, "reason": "voxel_tools_runtime_classes_missing"}
	var context = CONTEXT_SCRIPT.new()
	context.setup_from_main(main)
	for cell_value in context.initial_terrain_edits.keys():
		var state: Dictionary = context.initial_terrain_edits[cell_value]
		applied_edit_signatures[cell_value] = edit_signature(state)
	var service = volume_service()
	last_volume_revision = int(service.get("revision")) if service != null else -1
	generator = GENERATOR_SCRIPT.new()
	generator.setup(context)

	terrain = VoxelTerrain.new()
	terrain.name = "VoxelTerrainAuthority"
	terrain.set_meta("kind", "terrain")
	terrain.set_meta("geometry_source", "voxel_sdf_authority")
	terrain.set_meta("collision_source", "VoxelMesherTransvoxel")
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	terrain.set_format(format)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	mesher.mesh_optimization_enabled = false
	terrain.mesher = mesher
	terrain.generator = generator
	terrain.generate_collisions = true
	terrain.collision_layer = TERRAIN_COLLISION_LAYER
	terrain.collision_mask = 0
	terrain.mesh_block_size = 16
	terrain.max_view_distance = 128
	terrain.scale = Vector3.ONE * CELL
	var material := ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	terrain.material_override = material
	add_child(terrain)

	viewer = VoxelViewer.new()
	viewer.name = "VoxelTerrainViewer"
	viewer.view_distance = VIEW_DISTANCE
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	var player_value = main.get("player")
	if player_value is Node3D and is_instance_valid(player_value):
		(player_value as Node3D).add_child(viewer)
		viewer.position = Vector3.ZERO
	else:
		add_child(viewer)
	update_viewer_position()
	terrain.mesh_block_entered.connect(on_mesh_block_entered)
	terrain.mesh_block_exited.connect(on_mesh_block_exited)
	authority_ready = true
	return {"ok": true, "backend": "VoxelTerrain", "mesher": "VoxelMesherTransvoxel"}

func _process(_delta: float) -> void:
	if authority_ready:
		update_viewer_position()
		collect_volume_edit_changes()
		process_pending_edit_sections()

func _physics_process(_delta: float) -> void:
	if authority_ready:
		process_pending_gameplay_chunk_publications()


func _exit_tree() -> void:
	if viewer != null and is_instance_valid(viewer) and viewer.get_parent() != self:
		viewer.queue_free()

func update_viewer_position() -> void:
	if viewer == null or main == null:
		return
	var player_value = main.get("player")
	if player_value is Node3D and is_instance_valid(player_value):
		viewer.global_position = (player_value as Node3D).global_position

func required_classes_available() -> bool:
	for class_name_value in ["VoxelTerrain", "VoxelViewer", "VoxelMesherTransvoxel", "VoxelFormat"]:
		if not ClassDB.class_exists(class_name_value):
			return false
	return true

func on_mesh_block_entered(block_position: Vector3i) -> void:
	published_mesh_blocks[block_position] = true
	queue_loaded_block_edit_sections(block_position)

func on_mesh_block_exited(block_position: Vector3i) -> void:
	published_mesh_blocks.erase(block_position)

func stats() -> Dictionary:
	return {
		"ready": authority_ready,
		"publishedMeshBlocks": published_mesh_blocks.size(),
		"pendingEditSections": pending_edit_sections.size(),
		"editBatchesApplied": edit_batches_applied,
		"lastVolumeRevision": last_volume_revision,
		"appliedEditSignatures": applied_edit_signatures.size(),
		"desiredGameplayChunks": desired_gameplay_chunks.size(),
		"pendingGameplayChunks": pending_gameplay_chunks.size(),
		"publishedGameplayChunks": published_gameplay_chunks.size(),
		"collisionProbeAttempts": collision_probe_attempts,
		"collisionProbePasses": collision_probe_passes,
		"terrain": terrain.get_statistics() if terrain != null else {},
		"configuredSeed": configured_seed
	}

func collect_volume_edit_changes() -> void:
	var service = volume_service()
	if service == null:
		return
	var revision := int(service.get("revision"))
	if revision == last_volume_revision:
		return
	last_volume_revision = revision
	var current_signatures := {}
	var edited_value = service.get("edited_cells")
	var edited_cells: Dictionary = edited_value if edited_value is Dictionary else {}
	for cell_value in edited_cells.keys():
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		var state: Dictionary = edited_cells[cell] if edited_cells[cell] is Dictionary else {}
		if not state_affects_terrain_mesh(service, state):
			continue
		var signature := edit_signature(state)
		current_signatures[cell] = signature
		if String(applied_edit_signatures.get(cell, "")) != signature:
			queue_edit_change(cell, state, signature)
	for cell_value in applied_edit_signatures.keys():
		if current_signatures.has(cell_value):
			continue
		if cell_value is Vector3i:
			queue_edit_change(cell_value, {}, "")

func queue_loaded_block_edit_sections(block_position: Vector3i) -> void:
	var service = volume_service()
	if service == null:
		return
	var edited_value = service.get("edited_cells")
	if not (edited_value is Dictionary):
		return
	for cell_value in (edited_value as Dictionary).keys():
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		if section_key_for_cell(cell) != block_position:
			continue
		var state: Dictionary = edited_value[cell] if edited_value[cell] is Dictionary else {}
		if state_affects_terrain_mesh(service, state):
			var signature := edit_signature(state)
			if String(applied_edit_signatures.get(cell, "")) != signature:
				queue_edit_change(cell, state, signature)

func queue_edit_change(cell: Vector3i, state: Dictionary, signature: String) -> void:
	var section_key := section_key_for_cell(cell)
	var changes: Dictionary = pending_edit_sections.get(section_key, {}) if pending_edit_sections.get(section_key, {}) is Dictionary else {}
	changes[cell] = {"state": state.duplicate(true), "signature": signature}
	pending_edit_sections[section_key] = changes

func process_pending_edit_sections() -> void:
	if terrain == null or pending_edit_sections.is_empty():
		return
	var processed := 0
	for section_value in pending_edit_sections.keys():
		if processed >= EDIT_SECTIONS_PER_FRAME:
			break
		var section_key: Vector3i = section_value
		var changes: Dictionary = pending_edit_sections[section_key]
		if not apply_edit_batch(changes):
			continue
		pending_edit_sections.erase(section_key)
		processed += 1
		edit_batches_applied += 1

func apply_edit_batch(changes: Dictionary) -> bool:
	if changes.is_empty():
		return true
	var min_cell := Vector3i(2147483647, 2147483647, 2147483647)
	var max_cell := Vector3i(-2147483647, -2147483647, -2147483647)
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
		max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
	var size := max_cell - min_cell + Vector3i.ONE
	var tool = terrain.get_voxel_tool()
	if not bool(tool.is_area_editable(AABB(Vector3(min_cell), Vector3(size)))):
		return false
	var buffer := VoxelBuffer.new()
	buffer.create(size.x, size.y, size.z)
	var channels_mask := (1 << VoxelBuffer.CHANNEL_SDF) | (1 << VoxelBuffer.CHANNEL_INDICES) | (1 << VoxelBuffer.CHANNEL_DATA5)
	tool.copy(min_cell, buffer, channels_mask, false)
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		var change: Dictionary = changes[cell]
		var state: Dictionary = change.get("state", {}) if change.get("state", {}) is Dictionary else {}
		var sample := state if not state.is_empty() else generated_state_at_grid_cell(cell)
		var density := float(sample.get("density", -CELL))
		var material := String(sample.get("material", "air"))
		var material_id := int(MATERIAL_IDS.get(material, MATERIAL_IDS["stone"]))
		var local := cell - min_cell
		buffer.set_voxel_f(-density / CELL, local.x, local.y, local.z, VoxelBuffer.CHANNEL_SDF)
		buffer.set_voxel(material_id, local.x, local.y, local.z, VoxelBuffer.CHANNEL_INDICES)
		buffer.set_voxel(material_id, local.x, local.y, local.z, VoxelBuffer.CHANNEL_DATA5)
		var signature := String(change.get("signature", ""))
		if signature == "":
			applied_edit_signatures.erase(cell)
		else:
			applied_edit_signatures[cell] = signature
	tool.paste(min_cell, buffer, channels_mask)
	var affected_game_chunks := {}
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		affected_game_chunks[game_chunk_for_cell(cell)] = true
	for chunk_value in affected_game_chunks.keys():
		request_gameplay_chunk_republication(chunk_value)
	return true

func request_gameplay_chunk_publication(chunk_key: Vector2i) -> void:
	desired_gameplay_chunks[chunk_key] = true
	if not published_gameplay_chunks.has(chunk_key):
		pending_gameplay_chunks[chunk_key] = true

func request_gameplay_chunk_republication(chunk_key: Vector2i) -> void:
	if not desired_gameplay_chunks.has(chunk_key):
		return
	if published_gameplay_chunks.erase(chunk_key):
		notify_navigation_chunk_unloaded(chunk_key)
	pending_gameplay_chunks[chunk_key] = true

func release_gameplay_chunk(chunk_key: Vector2i) -> void:
	desired_gameplay_chunks.erase(chunk_key)
	pending_gameplay_chunks.erase(chunk_key)
	if published_gameplay_chunks.erase(chunk_key):
		notify_navigation_chunk_unloaded(chunk_key)

func gameplay_chunks_published(chunk_keys: Array) -> bool:
	for key_value in chunk_keys:
		if key_value is Vector2i and not published_gameplay_chunks.has(key_value):
			return false
	return true

func published_gameplay_chunk_count(chunk_keys: Array) -> int:
	var count := 0
	for key_value in chunk_keys:
		if key_value is Vector2i and published_gameplay_chunks.has(key_value):
			count += 1
	return count

func process_pending_gameplay_chunk_publications() -> void:
	if pending_gameplay_chunks.is_empty() or main == null or not is_inside_tree():
		return
	var processed := 0
	for key_value in pending_gameplay_chunks.keys():
		if processed >= PUBLICATION_PROBES_PER_PHYSICS_FRAME:
			break
		var chunk_key: Vector2i = key_value
		if not desired_gameplay_chunks.has(chunk_key):
			pending_gameplay_chunks.erase(chunk_key)
			continue
		processed += 1
		collision_probe_attempts += 1
		var proof := collision_proof_for_game_chunk(chunk_key)
		if not bool(proof.get("passed", false)):
			continue
		pending_gameplay_chunks.erase(chunk_key)
		published_gameplay_chunks[chunk_key] = proof
		collision_probe_passes += 1
		notify_navigation_chunk_loaded(chunk_key)

func collision_proof_for_game_chunk(chunk_key: Vector2i) -> Dictionary:
	if terrain == null or get_world_3d() == null:
		return {"passed": false, "reason": "physics_world_missing"}
	var world_generation = main.get("world_generation_system")
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return {"passed": false, "reason": "surface_facade_missing"}
	var origin_x := float(chunk_key.x * GAME_CHUNK_SIZE) * CELL
	var origin_z := float(chunk_key.y * GAME_CHUNK_SIZE) * CELL
	var span := float(GAME_CHUNK_SIZE) * CELL
	var offsets := [
		Vector2(0.50, 0.50),
		Vector2(0.22, 0.22),
		Vector2(0.78, 0.22),
		Vector2(0.22, 0.78),
		Vector2(0.78, 0.78)
	]
	var hits := 0
	var matched := 0
	var samples := []
	var min_surface_cell_y := 2147483000
	var max_surface_cell_y := -2147483000
	var space := get_world_3d().direct_space_state
	for offset_value in offsets:
		var offset: Vector2 = offset_value
		var x := origin_x + span * offset.x
		var z := origin_z + span * offset.y
		var expected_y := float(world_generation.call("surface_y_at", Vector3(x, 0.0, z)))
		var expected_cell_y := floori(expected_y / CELL)
		min_surface_cell_y = mini(min_surface_cell_y, expected_cell_y)
		max_surface_cell_y = maxi(max_surface_cell_y, expected_cell_y)
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, expected_y + CELL * 48.0, z),
			Vector3(x, float(world_generation.call("world_bottom_cell_y")) * CELL - CELL * 2.0, z),
			TERRAIN_COLLISION_LAYER
		)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not voxel_terrain_collider(hit.get("collider")):
			samples.append({"x": snappedf(x, 0.01), "z": snappedf(z, 0.01), "expectedY": snappedf(expected_y, 0.01), "hit": false})
			continue
		hits += 1
		var hit_y := float((hit.get("position", Vector3.ZERO) as Vector3).y)
		var delta_y := absf(hit_y - expected_y)
		if delta_y <= COLLISION_SURFACE_TOLERANCE:
			matched += 1
		samples.append({"x": snappedf(x, 0.01), "z": snappedf(z, 0.01), "expectedY": snappedf(expected_y, 0.01), "hit": true, "hitY": snappedf(hit_y, 0.01), "deltaY": snappedf(delta_y, 0.01)})
	var mesh_area := AABB(
		Vector3(
			float(chunk_key.x * GAME_CHUNK_SIZE),
			float(min_surface_cell_y - COLLISION_MESH_VERTICAL_MARGIN_CELLS),
			float(chunk_key.y * GAME_CHUNK_SIZE)
		),
		Vector3(
			float(GAME_CHUNK_SIZE),
			float(max_surface_cell_y - min_surface_cell_y + COLLISION_MESH_VERTICAL_MARGIN_CELLS * 2 + 1),
			float(GAME_CHUNK_SIZE)
		)
	)
	var area_meshed := terrain.is_area_meshed(mesh_area)
	return {
		"passed": area_meshed and hits == offsets.size() and matched == offsets.size(),
		"areaMeshed": area_meshed,
		"meshArea": mesh_area,
		"hits": hits,
		"surfaceMatches": matched,
		"probeCount": offsets.size(),
		"samples": samples
	}


func collision_proof_for_world_position(world_position: Vector3, footprint_radius := 0.0) -> Dictionary:
	if terrain == null or get_world_3d() == null:
		return {"passed": false, "reason": "physics_world_missing"}
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return {"passed": false, "reason": "surface_facade_missing"}
	var radius := maxf(0.0, footprint_radius)
	var offsets: Array[Vector2] = [Vector2.ZERO]
	if radius > 0.0:
		offsets.append_array([
			Vector2(radius, 0.0),
			Vector2(-radius, 0.0),
			Vector2(0.0, radius),
			Vector2(0.0, -radius)
		])
	var samples: Array = []
	var center_matched := false
	var matched := 0
	var mesh_ready := collision_mesh_ready_for_world_position(world_position, radius)
	if not bool(mesh_ready.get("passed", false)):
		return {
			"passed": false,
			"reason": "collision_mesh_not_ready",
			"position": world_position,
			"footprintRadius": radius,
			"mesh": mesh_ready,
			"samples": []
		}
	var space := get_world_3d().direct_space_state
	for index in range(offsets.size()):
		var sample_x := world_position.x + offsets[index].x
		var sample_z := world_position.z + offsets[index].y
		var expected_y := float(world_generation.call("surface_y_at", Vector3(sample_x, 0.0, sample_z)))
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(sample_x, expected_y + CELL * 48.0, sample_z),
			Vector3(sample_x, float(world_generation.call("world_bottom_cell_y")) * CELL - CELL * 2.0, sample_z),
			TERRAIN_COLLISION_LAYER
		)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not voxel_terrain_collider(hit.get("collider")):
			samples.append({"offset": offsets[index], "expectedY": snappedf(expected_y, 0.01), "hit": false})
			continue
		var hit_y := float((hit.get("position", Vector3.ZERO) as Vector3).y)
		var delta_y := absf(hit_y - expected_y)
		var surface_matched := delta_y <= COLLISION_SURFACE_TOLERANCE
		if surface_matched:
			matched += 1
			if index == 0:
				center_matched = true
		samples.append({
			"offset": offsets[index],
			"expectedY": snappedf(expected_y, 0.01),
			"hit": true,
			"hitY": snappedf(hit_y, 0.01),
			"deltaY": snappedf(delta_y, 0.01),
			"surfaceMatched": surface_matched
		})
	return {
		"passed": center_matched and matched == samples.size(),
		"reason": "collision_ready" if center_matched and matched == samples.size() else "footprint_collision_not_ready",
		"position": world_position,
		"footprintRadius": radius,
		"mesh": mesh_ready,
		"matchedSamples": matched,
		"sampleCount": samples.size(),
		"samples": samples
	}


func collision_mesh_ready_for_world_position(world_position: Vector3, footprint_radius := 0.0) -> Dictionary:
	if terrain == null:
		return {"passed": false, "reason": "terrain_missing"}
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return {"passed": false, "reason": "surface_facade_missing"}
	var radius_cells := maxi(1, ceili(maxf(0.0, footprint_radius) / CELL) + 1)
	var local_position := terrain.to_local(world_position)
	var expected_y := float(world_generation.call("surface_y_at", world_position))
	var local_surface_y := terrain.to_local(Vector3(world_position.x, expected_y, world_position.z)).y
	var area := AABB(
		Vector3(
			floorf(local_position.x) - float(radius_cells),
			floorf(local_surface_y) - float(COLLISION_MESH_VERTICAL_MARGIN_CELLS),
			floorf(local_position.z) - float(radius_cells)
		),
		Vector3(
			float(radius_cells * 2 + 1),
			float(COLLISION_MESH_VERTICAL_MARGIN_CELLS * 2 + 1),
			float(radius_cells * 2 + 1)
		)
	)
	return {
		"passed": terrain.is_area_meshed(area),
		"area": area,
		"expectedY": expected_y
	}


func collision_proof_for_motion(from_position: Vector3, to_position: Vector3, footprint_radius := 0.42) -> Dictionary:
	var distance := Vector2(to_position.x - from_position.x, to_position.z - from_position.z).length()
	var sample_count := maxi(1, ceili(distance / maxf(CELL, footprint_radius * 2.0)))
	var proofs: Array = []
	for index in range(sample_count + 1):
		var weight := float(index) / float(sample_count)
		var sample_position := from_position.lerp(to_position, weight)
		var proof := collision_proof_for_world_position(sample_position, footprint_radius)
		proofs.append(proof)
		if not bool(proof.get("passed", false)):
			return {
				"passed": false,
				"reason": String(proof.get("reason", "collision_not_ready")),
				"failedSample": index,
				"sampleCount": sample_count + 1,
				"proofs": proofs
			}
	return {
		"passed": true,
		"reason": "collision_ready",
		"sampleCount": sample_count + 1,
		"proofs": proofs
	}

func voxel_terrain_collider(value) -> bool:
	if value == null or not is_instance_valid(value):
		return false
	if value == terrain:
		return true
	return value is Node and (value as Node).name == terrain.name

func notify_navigation_chunk_loaded(chunk_key: Vector2i) -> void:
	var npc_system = main.get("npc_system") if main != null else null
	if npc_system != null and npc_system.has_method("notify_navigation_chunk_loaded"):
		npc_system.call("notify_navigation_chunk_loaded", chunk_key)

func notify_navigation_chunk_unloaded(chunk_key: Vector2i) -> void:
	var npc_system = main.get("npc_system") if main != null else null
	if npc_system != null and npc_system.has_method("notify_navigation_chunk_unloaded"):
		npc_system.call("notify_navigation_chunk_unloaded", chunk_key)

func game_chunk_for_cell(cell: Vector3i) -> Vector2i:
	return Vector2i(
		floori(float(cell.x) / float(GAME_CHUNK_SIZE)),
		floori(float(cell.z) / float(GAME_CHUNK_SIZE))
	)

func generated_state_at_grid_cell(cell: Vector3i) -> Dictionary:
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("generate_sample_without_volume"):
		return {"density": -CELL, "material": "air"}
	var position := Vector3(cell) * CELL
	var sample: Dictionary = world_generation.call("generate_sample_without_volume", position)
	var density := float(sample.get("density", -CELL))
	var material := String(sample.get("material", "air"))
	if density >= 0.0 and world_generation.has_method("generated_solid_material_for_cell"):
		var surface_y := float(sample.get("baseSurfaceY", sample.get("surfaceY", position.y)))
		var surface_biome := String(world_generation.call("surface_biome_for_cell3", Vector3i(cell.x, 0, cell.z)))
		var depth := maxf(0.0, surface_y - position.y)
		material = String(world_generation.call("generated_solid_material_for_cell", cell, surface_y, surface_biome, depth))
	return {"density": density, "material": material}

func section_key_for_cell(cell: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(cell.x) / float(SECTION_SIZE)),
		floori(float(cell.y) / float(SECTION_SIZE)),
		floori(float(cell.z) / float(SECTION_SIZE))
	)

func volume_service():
	var world_generation = main.get("world_generation_system") if main != null else null
	return world_generation.get("terrain_volume_service") if world_generation != null else null

func state_affects_terrain_mesh(service, state: Dictionary) -> bool:
	if service != null and service.has_method("cell_state_affects_terrain_mesh"):
		return bool(service.call("cell_state_affects_terrain_mesh", state))
	return true

func edit_signature(state: Dictionary) -> String:
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	return "%s|%s|%.6f|%s|%s" % [
		String(state.get("material", "air")),
		str(bool(state.get("solid", false))),
		float(state.get("density", -CELL)),
		String(state.get("fluid", "")),
		String(metadata.get("source", ""))
	]
