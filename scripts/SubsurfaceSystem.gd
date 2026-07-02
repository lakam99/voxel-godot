extends RefCounted
class_name SubsurfaceSystem

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const EXCAVATION_RADIUS_CELLS := 1.35

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
	if sampler().has_method("clear_excavation_brushes"):
		sampler().call("clear_excavation_brushes")

func subsurface_material_at(cell: Vector3i) -> String:
	if main == null:
		return "air"
	if main.has_method("world_material_at_cell"):
		return String(main.call("world_material_at_cell", cell))
	return String(sampler().material_at_cell3(cell)) if sampler().has_method("material_at_cell3") else "air"

func subsurface_is_solid(cell: Vector3i) -> bool:
	return subsurface_material_at(cell) != "air"

func subsurface_biome_at(cell: Vector3i) -> String:
	if main == null:
		return "plains"
	if main.has_method("biome_at_volume_cell"):
		return String(main.call("biome_at_volume_cell", cell))
	return String(sampler().biome_at_volume_cell(cell)) if sampler().has_method("biome_at_volume_cell") else "plains"

func break_target_for_hit(hit: Dictionary, _collider: Node, kind: String) -> Dictionary:
	var sample_pos := hit_sample_position(hit)
	var cell := world_to_cell3(sample_pos)
	var material_id := subsurface_material_at(cell)
	if material_id == "air":
		material_id = material_near_surface(sample_pos)
	var target_kind := "subsurface" if kind == "subsurface" else "terrain"
	return {
		"id": "%s:%d,%d,%d" % [target_kind, cell.x, cell.y, cell.z],
		"material": material_id,
		"cell3": cell
	}

func excavate_from_hit(hit: Dictionary, _collider: Node = null) -> Dictionary:
	var sample_pos := hit_sample_position(hit)
	var brush := add_excavation_brush(sample_pos, float(main.CELL) * EXCAVATION_RADIUS_CELLS)
	var affected := affected_surface_cells_for_brush(brush)
	for cell in affected:
		if main != null and main.has_method("rebuild_chunks_around_cell"):
			main.call("rebuild_chunks_around_cell", cell)
	return {
		"brush": brush,
		"affectedCells": affected,
		"caveId": ""
	}

func add_excavation_brush(center: Vector3, radius: float, _cave_id := "") -> Dictionary:
	excavation_sequence += 1
	var brush := {
		"id": "dig:%d" % excavation_sequence,
		"center": center,
		"radius": radius
	}
	excavation_brushes.append(brush)
	if sampler().has_method("register_excavation_brush"):
		sampler().call("register_excavation_brush", brush)
	return brush

func snapshot() -> Dictionary:
	var brushes := []
	for brush in excavation_brushes:
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		brushes.append({
			"id": String(brush.get("id", "")),
			"x": center.x,
			"y": center.y,
			"z": center.z,
			"radius": float(brush.get("radius", float(main.CELL) * EXCAVATION_RADIUS_CELLS))
		})
	return {
		"version": 3,
		"excavationSequence": excavation_sequence,
		"excavationBrushes": brushes
	}

func restore(snapshot_value) -> void:
	excavation_brushes.clear()
	excavation_sequence = 0
	if sampler().has_method("clear_excavation_brushes"):
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
		excavation_brushes.append(brush)
		if sampler().has_method("register_excavation_brush"):
			sampler().call("register_excavation_brush", brush)
		for cell in affected_surface_cells_for_brush(brush):
			affected_lookup[cell] = true
	for cell in affected_lookup.keys():
		if main != null and main.has_method("rebuild_chunks_around_cell"):
			main.call("rebuild_chunks_around_cell", cell)

func ground_y_near_position(position: Vector3) -> float:
	var s := float(main.CELL)
	var base_cell_x := roundi(position.x / s)
	var base_cell_z := roundi(position.z / s)
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
	return position - normal * float(main.CELL) * 0.35

func world_to_cell3(position: Vector3) -> Vector3i:
	var cell_size := float(main.CELL)
	return Vector3i(roundi(position.x / cell_size), roundi(position.y / cell_size), roundi(position.z / cell_size))

func affected_surface_cells_for_brush(brush: Dictionary) -> Array[Vector2i]:
	var center: Vector3 = brush.get("center", Vector3.ZERO)
	var radius := float(brush.get("radius", float(main.CELL)))
	var cell_size := float(main.CELL)
	var center_cell := Vector2i(roundi(center.x / cell_size), roundi(center.z / cell_size))
	var cell_radius := ceili(radius / cell_size) + 2
	var cells: Array[Vector2i] = []
	for dz in range(-cell_radius, cell_radius + 1):
		for dx in range(-cell_radius, cell_radius + 1):
			if Vector2(float(dx), float(dz)).length() <= float(cell_radius):
				cells.append(center_cell + Vector2i(dx, dz))
	return cells
