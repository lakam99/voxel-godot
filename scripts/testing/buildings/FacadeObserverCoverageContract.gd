extends SceneTree
## Synthetic observer wiring only: mocked boxes, real camera projection.
## Never evidence of published citadel geometry, images or gameplay.
const Visual = preload("res://scripts/testing/buildings/CitadelFacadeRecipeVisual.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")

class MockObserver extends Visual:
	var boxes: Dictionary = {}
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func _exit_tree() -> void: pass
	func _published_bounds(id: String) -> AABB: return boxes.get(id, AABB())
	func _first_visual_hit(from: Vector3, target: Vector3) -> Dictionary:
		var best: Dictionary = {}
		var nearest := INF
		for id in boxes:
			var point: Variant = boxes[id].intersects_segment(from, target)
			if point == null: continue
			var distance: float = from.distance_squared_to(point)
			if distance < nearest:
				nearest = distance
				best = {"partId": id, "point": point}
		return best

var checks: Dictionary = {}
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var path := OS.get_environment("VOXEL_FACADE_OBSERVER_COVERAGE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var fixture := MockObserver.new()
	root.add_child(fixture)
	fixture._camera = Camera3D.new()
	fixture.add_child(fixture._camera)
	fixture._camera.fov = 62.0
	fixture._camera.global_position = Vector3(0, 1.3, 4)
	fixture._camera.look_at(Vector3(0, 0.2, 0), Vector3.UP)
	var foot := AABB(Vector3(-0.3, 0, -0.3), Vector3(0.6, 0.4, 0.6))
	fixture.boxes = {"foot": foot, "floor": AABB(Vector3(-1, -0.2, -1), Vector3(2, 0.2, 2))}
	checks["readable_foot_patch"] = fixture._patch_coverage("foot", foot)
	var spec := {"kind": "foot", "footId": "foot", "targets": ["foot"], "supportIds": ["floor"], "bounds": foot.grow(0.4)}
	var patch: AABB = fixture._adjacent_support_patch(spec, "floor")
	checks["adjacent_patch_outside_base"] = patch.position.z == foot.end.z and patch.size.x == foot.size.x and patch.end.y == 0.0
	checks["readable_foot_and_floor"] = fixture._distributed_view_coverage(spec)
	var readable_rows: Array = fixture._coverage_rows.duplicate(true)
	# Two foreground boxes leave a narrow central slit to the intended foot.
	fixture.boxes["left_occluder"] = AABB(Vector3(-2, -1, 1), Vector3(1.97, 3, 0.1))
	fixture.boxes["right_occluder"] = AABB(Vector3(0.03, -1, 1), Vector3(1.97, 3, 0.1))
	checks["foreground_slit_rejects"] = not fixture._patch_coverage("foot", foot)
	fixture.boxes.erase("left_occluder")
	fixture.boxes.erase("right_occluder")
	fixture.boxes["floor_cover"] = AABB(Vector3(-1, 0.005, 0.3), Vector3(2, 0.01, 0.7))
	checks["foot_cannot_substitute_hidden_floor"] = not fixture._distributed_view_coverage(spec)
	fixture.boxes.erase("floor_cover")
	fixture.boxes["base_cover"] = AABB(Vector3(-0.31, 0.01, 0.31), Vector3(0.62, 0.18, 0.04))
	checks["visible_floor_cannot_substitute_hidden_base_edge"] = not fixture._distributed_view_coverage(spec)
	fixture.boxes.erase("base_cover")
	fixture._ray_tests = fixture.MAX_RAY_TESTS
	checks["exhausted_ray_budget_rejects"] = not fixture._patch_coverage("foot", foot)
	fixture._ray_tests = 0
	fixture._state_error = "synthetic_invalid_binding"
	checks["invalid_binding_rejects"] = not fixture._patch_coverage("foot", foot)
	fixture._state_error = ""
	checks["geometry_unchanged"] = fixture.boxes == {"foot": foot, "floor": AABB(Vector3(-1, -0.2, -1), Vector3(2, 0.2, 2))}
	# Explicit synthetic connected assembly: no actual citadel or physics claim.
	fixture._camera.global_position = Vector3(0, 2.2, 4)
	fixture._camera.look_at(Vector3(0, 2.2, 0), Vector3.UP)
	fixture.boxes = {
		"post": AABB(Vector3(-0.15, 0, -0.15), Vector3(0.3, 2, 0.3)),
		"sill": AABB(Vector3(-0.5, 2, -0.2), Vector3(1, 0.2, 0.4)),
		"panel": AABB(Vector3(-0.5, 2.2, -0.15), Vector3(1, 1, 0.3))}
	var assembly := {"kind": "assembly", "assemblyPairs": [
		{"reviewBounds": AABB(Vector3(-1, 1.8, -1), Vector3(2, 0.8, 2)), "patches": [{"partId": "panel"}, {"partId": "sill"}]},
		{"reviewBounds": AABB(Vector3(-1, 1.6, -1), Vector3(2, 0.8, 2)), "patches": [{"partId": "sill"}, {"partId": "post"}]}]}
	checks["readable_connected_assembly"] = fixture._distributed_view_coverage(assembly)
	var assembly_rows: Array = fixture._coverage_rows.duplicate(true)
	var assembly_before := var_to_bytes([fixture.boxes, assembly])
	fixture.boxes["panel_left_mask"] = AABB(Vector3(-2, 2.2, 1), Vector3(1.97, 2, 0.1))
	fixture.boxes["panel_right_mask"] = AABB(Vector3(0.03, 2.2, 1), Vector3(1.97, 2, 0.1))
	checks["sliver_panel_assembly_rejects"] = not fixture._distributed_view_coverage(assembly)
	fixture.boxes.erase("panel_left_mask")
	fixture.boxes.erase("panel_right_mask")
	fixture.boxes["post_mask"] = AABB(Vector3(-1, 0, 1), Vector3(2, 1.99, 0.1))
	checks["occluded_assembly_participant_rejects"] = not fixture._distributed_view_coverage(assembly)
	fixture.boxes.erase("post_mask")
	checks["assembly_inputs_unchanged"] = assembly_before == var_to_bytes([fixture.boxes, assembly])
	fixture.blueprint = Blueprint.new("synthetic_assembly_review", 1, "timber")
	for id in ["panel", "sill", "post"]:
		var box: AABB = fixture.boxes[id]
		var seats: Array = ["sill"] if id == "panel" else (["post"] if id == "sill" else [])
		var facts: Array = []
		for seat in seats: facts.append(Seats.world_down_seat_fact(seat, Vector3(0, -box.size.y * 0.5, 0), Vector2(0.05, 0.05)))
		fixture.blueprint.add_part({"id": id, "kind": "wall" if id == "panel" else "beam", "material": "timber_beam",
			"semantic": "citadel_urban_facade" if id == "panel" else "facade_bearing_frame", "position": box.get_center(), "size": box.size,
			"recipe": {"physicalRequiredSeatPartIds": seats, "physicalRequiredSeatFacts": facts}})
		fixture._part_visuals[id] = [] # Explicit mock index; bounds come from boxes.
	var group := {"id": "synthetic_group", "partIds": ["sill", "post"], "servedIds": ["panel"], "bounds": fixture.boxes.panel.merge(fixture.boxes.post)}
	fixture._facade_prepared = {"groups": [group]}
	fixture._requested_stage = "assembly_review"
	fixture._selected_frame_id = "synthetic_group"
	var selected: Array = fixture._view_specs()
	checks["selected_inventory_exactly_one_assembly"] = selected.size() == 1 and selected[0].kind == "assembly" and selected[0].assemblyPairs.size() == 2
	if selected.size() == 1: checks["generated_graph_patches_readable"] = fixture._distributed_view_coverage(selected[0])
	fixture._selected_frame_id = "absent"
	checks["missing_selection_rejected"] = fixture._view_specs().is_empty()
	fixture._selected_frame_id = "synthetic_group"
	fixture._facade_prepared.groups.append(group)
	checks["ambiguous_selection_rejected"] = fixture._view_specs().is_empty()
	checks["crop_boundary_not_expanded"] = not fixture._owned_hit_in_patch("post", Vector3(0, 1.59, 0), AABB(Vector3(-0.15, 1.6, -0.15), Vector3(0.3, 0.4, 0.3)))
	var passed := not checks.values().has(false)
	var report := {"passed": passed, "checks": checks, "readableRows": fixture._json(readable_rows), "assemblyRows": fixture._json(assembly_rows),
		"evidence": "synthetic_mock_box_observer_wiring_not_citadel_visual_acceptance"}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		fixture.free()
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	fixture.free()
	print("Observer wiring checks=", checks.size(), " passed=", passed)
	quit(0 if passed and written else 2)
