extends SceneTree

const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	checks["section_size_matches_terrain_mesh"] = Grid.SECTION_SIZE_CELLS == 16 \
		and is_equal_approx(Grid.SECTION_SIZE_METERS, 21.6)
	checks["negative_cell_uses_floor_division"] = Grid.key_for_cell(Vector3i(-1, -16, -17)) == Vector3i(-1, -1, -2)
	checks["cell_boundary_advances_section"] = Grid.key_for_cell(Vector3i(16, 32, 48)) == Vector3i(1, 2, 3)
	checks["world_to_cell_then_section"] = Grid.key_for_world_position(Vector3(-21.6, 0.0, 21.6)) == Vector3i(-1, 0, 1)
	checks["section_origin_uses_world_meters"] = Grid.origin_for_key(Vector3i(-1, 2, 3)).is_equal_approx(Vector3(-21.6, 43.2, 64.8))
	checks["sections_map_into_actual_stream_chunk"] = Grid.chunk_key_for_section(Vector3i(-1, 2, 3)) == Vector2i(-1, 1)
	checks["static_logical_owner_is_not_stream_chunk_key"] = Grid.chunk_key_for_section(Vector3i(2, 0, 0)) == Vector2i(1, 0) \
		and Grid.LOGICAL_OWNER_SIZE_CELLS == 32 and Grid.STREAM_CHUNK_SIZE_CELLS == 28
	checks["render_section_records_all_intersecting_stream_chunks"] = \
		Grid.stream_chunk_keys_intersecting_section(Vector3i(1, 0, 0)) == [Vector2i(0, 0), Vector2i(1, 0)] \
		and Grid.stream_chunk_keys_intersecting_section(Vector3i(-1, 0, 0)) == [Vector2i(-1, 0)]
	checks["logical_owner_key_uses_32_cell_grid"] = \
		Grid.logical_owner_cell_for_world_position(Vector3(40.0, 0.0, -1.0)) == Vector2i(0, -1)
	var one := Grid.keys_intersecting_bounds(AABB(Vector3.ZERO, Vector3(21.6, 21.6, 21.6)))
	checks["half_open_bounds_touch_one_section"] = one == [Vector3i.ZERO]
	var crossing := Grid.keys_intersecting_bounds(AABB(Vector3(21.5, -0.1, 0.0), Vector3(0.2, 0.2, 21.6)))
	checks["crossing_bounds_list_unique_section_dependencies"] = crossing == [
		Vector3i(0, -1, 0), Vector3i(1, -1, 0),
		Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	checks["zero_bounds_are_rejected"] = Grid.keys_intersecting_bounds(AABB(Vector3.ZERO, Vector3.ZERO)).is_empty()
	var report := {"schema":"static-render-section-grid-contract/v1", "checks":checks,
		"passed":not checks.values().has(false),
		"evidence":"pure spatial contract; no renderer publication or gameplay acceptance"}
	var report_path := OS.get_environment("STATIC_RENDER_SECTION_GRID_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("STATIC RENDER SECTION GRID ", JSON.stringify(report))
	quit(0 if report.passed else 1)
