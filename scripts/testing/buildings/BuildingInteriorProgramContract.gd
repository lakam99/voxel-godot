extends SceneTree

const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Interior = preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const FurnishingPlan = preload("res://scripts/buildings/FurnishingPlan.gd")

func _initialize() -> void:
	var report_path := OS.get_environment("VOXEL_INTERIOR_PROGRAM_REPORT").simplify_path()
	if not report_path.is_absolute_path() or FileAccess.file_exists(report_path) or not DirAccess.dir_exists_absolute(report_path.get_base_dir()):
		quit(2); return
	var room_a := {"id": "room_a", "bounds": AABB(Vector3.ZERO, Vector3(4.0, 4.0, 4.0))}
	var room_b := {"id": "room_b", "bounds": AABB(Vector3(4.30, 0.0, 0.0), Vector3(4.0, 4.0, 4.0))}
	var right_window := Vector3(4.48, 2.0, 2.0)
	var left_window := Vector3(-0.48, 2.0, 2.0)
	var duplicate_rooms := [room_a.duplicate(true), room_a.duplicate(true)]
	var blueprint = Blueprint.new("interior-contract", 17, "citadel")
	blueprint.rooms = [room_b.duplicate(true), room_a.duplicate(true)]
	blueprint.add_part({"id": "window_a", "kind": "window", "material": "window_glass", "position": right_window,
		"size": Vector3(0.1, 1.2, 0.9), "collision": false, "recipe": {"roomId": "room_a",
		"interiorInwardDirection": Vector3.LEFT, "interiorWallOffset": 0.48}})
	var first := Interior.ensure_recipe_program(blueprint)
	var second := Interior.ensure_recipe_program(blueprint)
	var clear_blueprint = Blueprint.new("clear-view-contract", 19, "citadel")
	clear_blueprint.rooms = [room_a.duplicate(true)]
	clear_blueprint.add_part({"id": "clear_window", "kind": "window", "material": "window_glass", "position": right_window,
		"size": Vector3(0.1, 1.2, 0.9), "collision": false, "recipe": {"roomId": "room_a",
		"interiorInwardDirection": Vector3.LEFT, "interiorWallOffset": 0.48, "interiorProgramMode": "clear_view"}})
	var clear_plan = FurnishingPlan.new("clear-view-plan", 19, clear_blueprint.id)
	var clear_program := Interior.apply_to_plan(clear_blueprint, clear_plan)
	var clear_audit := Interior.audit_plan(clear_blueprint, clear_plan)
	var blocked_plan = FurnishingPlan.new("blocked-view-plan", 19, clear_blueprint.id)
	var view_volume: AABB = (clear_program.apertures[0] as Dictionary).viewVolume
	blocked_plan.add_part({"id": "solid_window_blocker", "roomId": "room_a", "archetype": "cabinet",
		"position": view_volume.get_center(), "occupiedSize": Vector3(0.4, 0.8, 0.4), "collision": true})
	var blocked_audit := Interior.audit_plan(clear_blueprint, blocked_plan)
	var checks := {
		"declared_room_wins_over_room_order_and_overlap": Interior.room_for_window([room_b, room_a], right_window, "room_a", Vector3.LEFT, 0.48).get("id") == "room_a",
		"opposite_facade_boundary_is_accepted": Interior.room_for_window([room_a], left_window, "room_a", Vector3.RIGHT, 0.48).get("id") == "room_a",
		"missing_declared_room_fails_closed": Interior.room_for_window([room_a], right_window, "missing", Vector3.LEFT, 0.48).is_empty(),
		"duplicate_declared_room_fails_closed": Interior.room_for_window(duplicate_rooms, right_window, "room_a", Vector3.LEFT, 0.48).is_empty(),
		"invalid_direction_fails_closed": Interior.room_for_window([room_a], right_window, "room_a", Vector3(0.5, 0.0, -0.5), 0.48).is_empty(),
		"wrong_wall_offset_fails_closed": Interior.room_for_window([room_a], right_window, "room_a", Vector3.LEFT, 0.20).is_empty(),
		"outside_wall_span_fails_closed": Interior.room_for_window([room_a], Vector3(4.48, 2.0, 4.40), "room_a", Vector3.LEFT, 0.48).is_empty(),
		"ambiguous_legacy_spatial_match_fails_closed": Interior.room_for_window([room_a, room_a.duplicate(true)], Vector3(2.0, 2.0, 2.0)).is_empty(),
		"program_signature_is_deterministic": var_to_bytes(first) == var_to_bytes(second),
		"valid_window_emits_one_bound_aperture": (first.get("apertures", []) as Array).size() == 1 \
			and String((first.apertures[0] as Dictionary).get("windowId", "")) == "window_a" \
			and String((first.apertures[0] as Dictionary).get("roomId", "")) == "room_a",
		"clear_view_emits_no_window_ornaments": clear_program.get("publishedWindowCount") == 1 \
			and clear_program.get("publishedPartCount") == 0 and clear_plan.parts.is_empty() and clear_audit.get("passed", false),
		"clear_view_rejects_solid_furniture_in_view_volume": not blocked_audit.get("passed", true) \
			and (blocked_audit.get("violations", []) as Array).any(func(value): return String(value).contains("solid_window_blocker"))}
	var report := {"passed": checks.values().all(func(value): return value == true), "checks": checks,
		"schemaVersion": Interior.SCHEMA_VERSION,
		"scope": "Pure deterministic room/window recipe binding; no rendering, publication, gameplay, NPC or navigation claim."}
	var output := FileAccess.open(report_path, FileAccess.WRITE)
	if output == null: quit(2); return
	output.store_string(JSON.stringify(report, "\t")); output.close()
	quit(0 if report.passed else 1)
