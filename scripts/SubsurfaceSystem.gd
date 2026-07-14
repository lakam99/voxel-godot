extends RefCounted
class_name SubsurfaceSystem

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const EXCAVATION_RADIUS_CELLS := 1.35
const SURFACE_EXCAVATION_RADIUS_SCALE := 1.65
const SURFACE_HIT_SAMPLE_OFFSET_CELLS := 0.65
const WALL_HIT_SAMPLE_OFFSET_CELLS := 0.35
const LEGACY_BRUSH_TERRAIN_AUTHORITY_ENABLED := false

var main
var excavation_brushes: Array[Dictionary] = []
var excavation_sequence := 0
var world_volume_sampler

func setup(main_node) -> void:
	main = main_node
	world_volume_sampler = main.get("world_generation_system") if main != null else null
	if world_volume_sampler == null:
		world_volume_sampler = WorldGenerationSystemScript.new()
		world_volume_sampler.setup(main)

func sampler():
	var main_world_generation = main.get("world_generation_system") if main != null else null
	if main_world_generation != null:
		world_volume_sampler = main_world_generation
	if world_volume_sampler == null:
		world_volume_sampler = WorldGenerationSystemScript.new()
		world_volume_sampler.setup(main)
	return world_volume_sampler

func reset() -> void:
	excavation_brushes.clear()
	excavation_sequence = 0
	if sampler().has_method("reset_terrain_volume_authority"):
		sampler().call("reset_terrain_volume_authority")
	elif sampler().has_method("clear_excavation_brushes"):
		sampler().call("clear_excavation_brushes")

func subsurface_material_at(cell: Vector3i) -> String:
	if main == null:
		return "air"
	if main.has_method("world_material_at_cell"):
		return String(main.call("world_material_at_cell", cell))
	return String(sampler().material_at_cell3(cell)) if sampler().has_method("material_at_cell3") else "air"

func subsurface_is_solid(cell: Vector3i) -> bool:
	if sampler().has_method("get_cell_state"):
		var state_value = sampler().call("get_cell_state", cell)
		if state_value is Dictionary:
			return bool((state_value as Dictionary).get("solid", false))
	if main != null and main.has_method("terrain_occupancy_at_cell"):
		var occupancy_value = main.call("terrain_occupancy_at_cell", cell)
		if occupancy_value is Dictionary:
			return bool((occupancy_value as Dictionary).get("solid", false))
	var material_id := subsurface_material_at(cell)
	return material_id != "air" and material_id != "water" and material_id != "lava"

func subsurface_biome_at(cell: Vector3i) -> String:
	if main == null:
		return "plains"
	if main.has_method("biome_at_volume_cell"):
		return String(main.call("biome_at_volume_cell", cell))
	return String(sampler().biome_at_volume_cell(cell)) if sampler().has_method("biome_at_volume_cell") else "plains"

func break_target_for_hit(hit: Dictionary, _collider: Node, kind: String) -> Dictionary:
	var sample_pos := hit_sample_position(hit)
	var cell := solid_target_cell_for_hit(hit)
	var material_id := subsurface_material_at(cell)
	if material_id == "air":
		material_id = material_near_surface(sample_pos)
	var target_kind := "subsurface" if kind == "subsurface" else "terrain"
	return {
		"id": "%s:%d,%d,%d" % [target_kind, cell.x, cell.y, cell.z],
		"material": material_id,
		"cell3": cell
	}

func begin_excavation_from_hit(hit: Dictionary, collider: Node = null) -> Dictionary:
	var sample_pos := hit_sample_position(hit)
	var hit_position: Vector3 = hit.get("position", sample_pos)
	var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
	if hit_normal.length_squared() < 0.001:
		hit_normal = Vector3.UP
	else:
		hit_normal = hit_normal.normalized()
	var surface_facing := hit_normal.y > 0.8
	var radius := float(main.CELL) * EXCAVATION_RADIUS_CELLS
	var edit_radius := radius * SURFACE_EXCAVATION_RADIUS_SCALE if surface_facing else radius
	excavation_sequence += 1
	var edit_id := "dig:%d" % excavation_sequence
	var target_cell := solid_target_cell_for_hit(hit)
	var fallback_material := subsurface_material_at(target_cell)
	var edit_center := surface_edit_center_for_hit(hit, target_cell) if surface_facing else sample_pos
	var volume_job := {}
	var edit_state := terrain_air_edit_state("player_dig")
	if surface_facing and sampler().has_method("begin_surface_deformation_edit_incremental"):
		volume_job = sampler().call("begin_surface_deformation_edit_incremental", edit_center, edit_radius, float(main.CELL) * 1.35, edit_state, edit_id)
	elif sampler().has_method("begin_sphere_edit_incremental"):
		volume_job = sampler().call("begin_sphere_edit_incremental", edit_center, edit_radius, edit_state, edit_id)
	return {
		"id": edit_id,
		"complete": false,
		"hit": hit.duplicate(true),
		"collider": collider,
		"center": edit_center,
		"radius": edit_radius,
		"fallbackMaterial": fallback_material,
		"surfaceFacing": surface_facing,
		"volumeJob": volume_job,
		"legacy": volume_job.is_empty()
	}

func advance_excavation(job: Dictionary, frame_budget_ms := 0.35, max_work_units := 8) -> Dictionary:
	if bool(job.get("complete", false)):
		return { "state": job, "complete": true, "processedWorkUnits": 0, "result": job.get("result", {}) }
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	var advance_start: int = monitor.begin_section("terrain_edit_incremental") if monitor != null else Time.get_ticks_usec()
	if bool(job.get("legacy", false)):
		var legacy_hit_value: Variant = job.get("hit", {})
		var legacy_hit: Dictionary = legacy_hit_value if legacy_hit_value is Dictionary else {}
		var legacy_result := excavate_from_hit(legacy_hit, job.get("collider") as Node)
		job["complete"] = true
		job["result"] = legacy_result
		if monitor != null:
			monitor.end_section("terrain_edit_incremental", advance_start)
		return { "state": job, "complete": true, "processedWorkUnits": 1, "result": legacy_result }
	var volume_job_value: Variant = job.get("volumeJob", {})
	var volume_job: Dictionary = volume_job_value if volume_job_value is Dictionary else {}
	var advanced: Dictionary = sampler().call("advance_incremental_terrain_edit", volume_job, frame_budget_ms, max_work_units)
	var next_volume_value: Variant = advanced.get("state", volume_job)
	volume_job = next_volume_value if next_volume_value is Dictionary else volume_job
	job["volumeJob"] = volume_job
	var complete := bool(advanced.get("complete", false))
	var result := {}
	if complete:
		result = finalize_incremental_excavation(job, volume_job)
		job["complete"] = true
		job["result"] = result
	if monitor != null:
		monitor.end_section("terrain_edit_incremental", advance_start)
	return {
		"state": job,
		"complete": complete,
		"processedWorkUnits": int(advanced.get("processedWorkUnits", 0)),
		"result": result
	}

func finalize_incremental_excavation(job: Dictionary, volume_job: Dictionary) -> Dictionary:
	var changed_value: Variant = volume_job.get("changedCells", [])
	var changed_cells: Array = changed_value if changed_value is Array else []
	var removed_value: Variant = volume_job.get("removedMaterials", {})
	var removed_materials: Dictionary = removed_value if removed_value is Dictionary else {}
	var center: Vector3 = job.get("center", Vector3.ZERO)
	var radius := float(job.get("radius", float(main.CELL) * EXCAVATION_RADIUS_CELLS))
	var affected := affected_surface_cells_for_cell3_edits(changed_cells, center, radius)
	if main != null and main.has_method("rebuild_chunks_for_cells"):
		main.call("rebuild_chunks_for_cells", affected, 0, true)
	else:
		for cell in affected:
			if main != null and main.has_method("rebuild_chunks_around_cell"):
				main.call("rebuild_chunks_around_cell", cell)
	var fallback_material := String(job.get("fallbackMaterial", ""))
	return {
		"id": String(job.get("id", "")),
		"authority": "terrainVolume",
		"affectedCells": affected,
		"affectedCells3": changed_cells,
		"primaryMaterial": primary_removed_material(removed_materials, fallback_material),
		"removedMaterials": removed_materials
	}

func excavate_from_hit(hit: Dictionary, _collider: Node = null) -> Dictionary:
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	var excavate_start: int = monitor.begin_section("terrain_edit_excavate_from_hit") if monitor != null else Time.get_ticks_usec()
	var sample_pos := hit_sample_position(hit)
	var hit_position: Vector3 = hit.get("position", sample_pos)
	var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
	if hit_normal.length_squared() < 0.001:
		hit_normal = Vector3.UP
	else:
		hit_normal = hit_normal.normalized()
	var surface_facing := hit_normal.y > 0.8
	var radius := float(main.CELL) * EXCAVATION_RADIUS_CELLS
	var edit_radius := radius * SURFACE_EXCAVATION_RADIUS_SCALE if surface_facing else radius
	if terrain_volume_authority_available() and sampler().has_method("apply_sphere_edit"):
		excavation_sequence += 1
		var edit_id := "dig:%d" % excavation_sequence
		var target_cell := solid_target_cell_for_hit(hit)
		var edit_center := surface_edit_center_for_hit(hit, target_cell) if surface_facing else sample_pos
		var material_start: int = monitor.begin_section("terrain_edit_removed_material_scan") if monitor != null else Time.get_ticks_usec()
		var removed_materials := removed_material_counts_for_sphere(edit_center, edit_radius)
		var primary_material := primary_removed_material(removed_materials, subsurface_material_at(target_cell))
		if monitor != null:
			monitor.end_section("terrain_edit_removed_material_scan", material_start)
		var apply_start: int = monitor.begin_section("terrain_edit_apply_sphere") if monitor != null else Time.get_ticks_usec()
		var changed_value
		if surface_facing and sampler().has_method("apply_surface_deformation_edit"):
			changed_value = sampler().call("apply_surface_deformation_edit", edit_center, edit_radius, float(main.CELL) * 1.35, terrain_air_edit_state("player_dig"), edit_id)
		else:
			changed_value = sampler().call("apply_sphere_edit", edit_center, edit_radius, terrain_air_edit_state("player_dig"), edit_id)
		var changed_cells: Array = changed_value if changed_value is Array else []
		if monitor != null:
			monitor.increment_counter("terrain_edit_changed_cells", changed_cells.size())
			monitor.end_section("terrain_edit_apply_sphere", apply_start)
		var affected_start: int = monitor.begin_section("terrain_edit_affected_cells") if monitor != null else Time.get_ticks_usec()
		var affected := affected_surface_cells_for_cell3_edits(changed_cells, edit_center, edit_radius)
		if monitor != null:
			monitor.increment_counter("terrain_edit_affected_columns", affected.size())
			monitor.end_section("terrain_edit_affected_cells", affected_start)
		var rebuild_start: int = monitor.begin_section("terrain_edit_rebuild_queue") if monitor != null else Time.get_ticks_usec()
		if main != null and main.has_method("rebuild_chunks_for_cells"):
			main.call("rebuild_chunks_for_cells", affected, 0, true)
		else:
			for cell in affected:
				if main != null and main.has_method("rebuild_chunks_around_cell"):
					main.call("rebuild_chunks_around_cell", cell)
		if monitor != null:
			monitor.end_section("terrain_edit_rebuild_queue", rebuild_start)
			monitor.end_section("terrain_edit_excavate_from_hit", excavate_start)
		return {
			"id": edit_id,
			"authority": "terrainVolume",
			"affectedCells": affected,
			"affectedCells3": changed_cells,
			"primaryMaterial": primary_material,
			"removedMaterials": removed_materials
		}
	var brush := add_excavation_brush(sample_pos, float(main.CELL) * EXCAVATION_RADIUS_CELLS)
	var affected := affected_surface_cells_for_brush(brush)
	if main != null and main.has_method("rebuild_chunks_for_cells"):
		main.call("rebuild_chunks_for_cells", affected, 0, true)
	else:
		for cell in affected:
			if main != null and main.has_method("rebuild_chunks_around_cell"):
				main.call("rebuild_chunks_around_cell", cell)
	if monitor != null:
		monitor.end_section("terrain_edit_excavate_from_hit", excavate_start)
	return {
		"brush": brush,
		"affectedCells": affected
	}

func surface_edit_center_for_hit(hit: Dictionary, target_cell: Vector3i) -> Vector3:
	var position: Vector3 = hit.get("position", Vector3.ZERO)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	if normal.length_squared() < 0.001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()
	var s := float(main.CELL) if main != null else 1.35
	var center := position - normal * s * 0.08
	center.x = position.x
	center.z = position.z
	var surface_y := position.y
	if sampler().has_method("surface_y_at"):
		surface_y = float(sampler().call("surface_y_at", position))
	if surface_y - position.y <= s * 1.15:
		center.y = surface_y
	else:
		center.y = position.y
	if center == Vector3.ZERO and target_cell != Vector3i.ZERO:
		center = Vector3((float(target_cell.x) + 0.5) * s, (float(target_cell.y) + 0.5) * s, (float(target_cell.z) + 0.5) * s)
	return center

func terrain_air_edit_state(source: String) -> Dictionary:
	return {
		"material": "air",
		"biome": "underground_air",
		"solid": false,
		"density": -float(main.CELL),
		"fluid": "",
		"light": { "sky": 0, "block": 0 },
		"metadata": {
			"source": source,
			"terrainMeshAffects": true,
			"deferSkyLight": true,
			"saveDelta": true
		}
	}

func solid_target_cell_for_hit(hit: Dictionary) -> Vector3i:
	var position: Vector3 = hit.get("position", Vector3.ZERO)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	if normal.length_squared() < 0.001:
		normal = Vector3.UP
	normal = normal.normalized()
	var s := float(main.CELL) if main != null else 1.35
	for offset in [0.35, 0.72, 1.08, 1.42, -0.12]:
		var cell := world_to_cell3(position - normal * s * float(offset))
		if subsurface_is_solid(cell):
			return cell
	var base := world_to_cell3(hit_sample_position(hit))
	if subsurface_is_solid(base):
		return base
	for direction_value in [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]:
		var direction: Vector3i = direction_value
		var neighbor: Vector3i = base + direction
		if subsurface_is_solid(neighbor):
			return neighbor
	return base

func removed_material_counts_for_sphere(center: Vector3, radius: float) -> Dictionary:
	var counts := {}
	var s := float(main.CELL) if main != null else 1.35
	var min_cell := Vector3i(floori((center.x - radius) / s), floori((center.y - radius) / s), floori((center.z - radius) / s))
	var max_cell := Vector3i(ceili((center.x + radius) / s), ceili((center.y + radius) / s), ceili((center.z + radius) / s))
	var radius_sq := radius * radius
	for z in range(min_cell.z, max_cell.z + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			for x in range(min_cell.x, max_cell.x + 1):
				var cell := Vector3i(x, y, z)
				var cell_center := Vector3((float(x) + 0.5) * s, (float(y) + 0.5) * s, (float(z) + 0.5) * s)
				if cell_center.distance_squared_to(center) > radius_sq:
					continue
				var state := {}
				if sampler().has_method("get_cell_state"):
					var state_value = sampler().call("get_cell_state", cell)
					state = state_value if state_value is Dictionary else {}
				var material_id := String(state.get("material", subsurface_material_at(cell)))
				var solid := bool(state.get("solid", material_id != "air"))
				if not solid or material_id == "" or material_id == "air":
					continue
				counts[material_id] = int(counts.get(material_id, 0)) + 1
	return counts

func primary_removed_material(counts: Dictionary, fallback: String) -> String:
	if fallback != "" and fallback != "air":
		return fallback
	var best_material := ""
	var best_count := -1
	for material_value in counts.keys():
		var material_id := String(material_value)
		var count := int(counts.get(material_id, 0))
		if count > best_count:
			best_material = material_id
			best_count = count
	return best_material if best_material != "" else "dirt"

func affected_surface_cells_for_cell3_edits(changed_cells: Array, fallback_center: Vector3, fallback_radius: float) -> Array[Vector2i]:
	var lookup := {}
	for value in changed_cells:
		if value is Vector3i:
			var cell: Vector3i = value
			lookup[Vector2i(cell.x, cell.z)] = true
	if lookup.is_empty():
		return affected_surface_cells_for_brush({ "center": fallback_center, "radius": fallback_radius })
	var cells: Array[Vector2i] = []
	for key_value in lookup.keys():
		cells.append(key_value)
	return cells

func add_excavation_brush(center: Vector3, radius: float) -> Dictionary:
	excavation_sequence += 1
	var brush := {
		"id": "dig:%d" % excavation_sequence,
		"center": center,
		"radius": radius
	}
	var surface_y := center.y
	var sample_source: Object = sampler()
	if sample_source != null and sample_source.has_method("surface_y_at"):
		surface_y = float(sample_source.call("surface_y_at", center))
	var surface_depth := surface_y - center.y
	if surface_depth <= radius * 1.45:
		var cell_size := float(main.CELL) if main != null else radius
		brush["mode"] = "surface_deform"
		brush["surfaceY"] = surface_y
		brush["surfaceTargetY"] = minf(surface_y - cell_size * 0.95, center.y - cell_size * 0.45)
		brush["deformRadius"] = radius * 2.35
	else:
		brush["mode"] = "volume"
	if LEGACY_BRUSH_TERRAIN_AUTHORITY_ENABLED and not terrain_volume_authority_available():
		excavation_brushes.append(brush)
	if sampler().has_method("register_excavation_brush"):
		sampler().call("register_excavation_brush", brush)
	return brush

func snapshot() -> Dictionary:
	if terrain_volume_authority_available() or not LEGACY_BRUSH_TERRAIN_AUTHORITY_ENABLED:
		return {
			"version": 4,
			"authority": "terrainVolume",
			"excavationSequence": excavation_sequence,
			"excavationBrushes": []
		}
	var brushes := []
	for brush in excavation_brushes:
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var entry := {
			"id": String(brush.get("id", "")),
			"x": center.x,
			"y": center.y,
			"z": center.z,
			"radius": float(brush.get("radius", float(main.CELL) * EXCAVATION_RADIUS_CELLS))
		}
		if brush.has("mode"):
			entry["mode"] = String(brush.get("mode", ""))
		if brush.has("surfaceY"):
			entry["surfaceY"] = float(brush.get("surfaceY", center.y))
		if brush.has("surfaceTargetY"):
			entry["surfaceTargetY"] = float(brush.get("surfaceTargetY", center.y))
		if brush.has("deformRadius"):
			entry["deformRadius"] = float(brush.get("deformRadius", brush.get("radius", 0.0)))
		brushes.append(entry)
	return {
		"version": 3,
		"excavationSequence": excavation_sequence,
		"excavationBrushes": brushes
	}

func restore(snapshot_value) -> void:
	excavation_brushes.clear()
	excavation_sequence = 0
	if sampler().has_method("reset_terrain_volume_authority"):
		sampler().call("reset_terrain_volume_authority")
	elif sampler().has_method("clear_excavation_brushes"):
		sampler().call("clear_excavation_brushes")
	var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
	excavation_sequence = max(0, int(state.get("excavationSequence", 0)))
	var brushes_value = state.get("excavationBrushes", [])
	if not (brushes_value is Array):
		return
	var affected_lookup := {}
	for entry_value in brushes_value:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var brush := {
			"id": String(entry.get("id", "dig:%d" % (excavation_sequence + 1))),
			"center": Vector3(float(entry.get("x", 0.0)), float(entry.get("y", 0.0)), float(entry.get("z", 0.0))),
			"radius": float(entry.get("radius", float(main.CELL) * EXCAVATION_RADIUS_CELLS))
		}
		if entry.has("mode"):
			brush["mode"] = String(entry.get("mode", ""))
		if entry.has("surfaceY"):
			brush["surfaceY"] = float(entry.get("surfaceY", brush["center"].y))
		if entry.has("surfaceTargetY"):
			brush["surfaceTargetY"] = float(entry.get("surfaceTargetY", brush["center"].y))
		if entry.has("deformRadius"):
			brush["deformRadius"] = float(entry.get("deformRadius", brush["radius"]))
		if LEGACY_BRUSH_TERRAIN_AUTHORITY_ENABLED and not terrain_volume_authority_available():
			excavation_brushes.append(brush)
		if sampler().has_method("register_excavation_brush"):
			sampler().call("register_excavation_brush", brush)
		for cell in affected_surface_cells_for_brush(brush):
			affected_lookup[cell] = true
	var affected_cells := affected_lookup.keys()
	if main != null and main.has_method("rebuild_chunks_for_cells"):
		main.call("rebuild_chunks_for_cells", affected_cells, 0, true)
	else:
		for cell in affected_cells:
			if main != null and main.has_method("rebuild_chunks_around_cell"):
				main.call("rebuild_chunks_around_cell", cell)

func ground_y_near_position(position: Vector3) -> float:
	var s := float(main.CELL)
	var base_cell_x := floori(position.x / s)
	var base_cell_z := floori(position.z / s)
	var start_y := roundi((position.y + s * 2.0) / s)
	var end_y := roundi((position.y - s * 14.0) / s)
	for y in range(start_y, end_y - 1, -1):
		var solid_cell := Vector3i(base_cell_x, y, base_cell_z)
		var air_cell := Vector3i(base_cell_x, y + 1, base_cell_z)
		if subsurface_is_solid(solid_cell) and not subsurface_is_solid(air_cell):
			return float(y + 1) * s
	return NAN

func is_air_at_world(world_pos: Vector3) -> bool:
	return bool(sampler().call("is_air_at_world", world_pos)) if sampler().has_method("is_air_at_world") else not bool(sampler().call("solid_at", world_pos))

func terrain_volume_authority_available() -> bool:
	var sample_source = sampler()
	return sample_source != null and sample_source.has_method("save_terrain_volume_deltas") and sample_source.has_method("set_cell_state")

func material_near_surface(world_pos: Vector3) -> String:
	if sampler().has_method("material_at"):
		var probe := world_pos
		for _i in range(10):
			var material_id := String(sampler().call("material_at", probe))
			if material_id != "air":
				return material_id
			probe.y -= float(main.CELL)
	return "dirt"

func hit_sample_position(hit: Dictionary) -> Vector3:
	var position: Vector3 = hit.get("position", Vector3.ZERO)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	if normal.length_squared() < 0.001:
		normal = Vector3.UP
	normal = normal.normalized()
	var offset_cells := SURFACE_HIT_SAMPLE_OFFSET_CELLS if normal.y >= 0.55 else WALL_HIT_SAMPLE_OFFSET_CELLS
	return position - normal * float(main.CELL) * offset_cells

func world_to_cell3(position: Vector3) -> Vector3i:
	var cell_size := float(main.CELL)
	return Vector3i(floori(position.x / cell_size), floori(position.y / cell_size), floori(position.z / cell_size))

func affected_surface_cells_for_brush(brush: Dictionary) -> Array[Vector2i]:
	var center: Vector3 = brush.get("center", Vector3.ZERO)
	var radius := maxf(float(brush.get("radius", float(main.CELL))), float(brush.get("deformRadius", 0.0)))
	var cell_size := float(main.CELL)
	var center_cell := Vector2i(roundi(center.x / cell_size), roundi(center.z / cell_size))
	var cell_radius := ceili(radius / cell_size) + 2
	var cells: Array[Vector2i] = []
	for dz in range(-cell_radius, cell_radius + 1):
		for dx in range(-cell_radius, cell_radius + 1):
			if Vector2(float(dx), float(dz)).length() <= float(cell_radius):
				cells.append(center_cell + Vector2i(dx, dz))
	return cells
