extends "res://scripts/testing/buildings/FurnishedCottageWalkthroughRunner.gd"

## The Town Hall walkthrough reuses the established real physics player and
## DoorPortalService consumer. Only its seed grammar and role-aware furnishing
## planner differ; there is no landmark-specific interaction implementation.

const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")
const LandmarkFurnishingPlannerScript := preload("res://scripts/buildings/LandmarkFurnishingPlanner.gd")

var capture_view := "entry"


func _ready() -> void:
	read_arguments()
	build_world()
	build_hud()
	await rebuild_fixture(false)
	spawn_player()
	place_capture_view()
	update_hud()
	if not report_path.is_empty():
		call_deferred("write_automated_report")


func read_arguments() -> void:
	selected_seed = 208154
	selected_style = "masonry"
	super.read_arguments()
	capture_path = OS.get_environment("VOXEL_TOWN_HALL_WALKTHROUGH_CAPTURE")
	report_path = OS.get_environment("VOXEL_TOWN_HALL_WALKTHROUGH_REPORT")
	capture_view = OS.get_environment("VOXEL_TOWN_HALL_WALKTHROUGH_CAPTURE_VIEW").strip_edges().to_lower()
	if capture_view not in ["entry", "public", "archive", "office", "store"]:
		capture_view = "entry"


func build_world() -> void:
	super.build_world()
	var public_light := OmniLight3D.new()
	public_light.name = "TownHallPublicWarmth"
	public_light.position = Vector3(-3.8, 2.95, -2.2)
	public_light.light_color = Color(1.0, 0.46, 0.15)
	public_light.light_energy = 2.45
	public_light.omni_range = 14.0
	public_light.shadow_enabled = true
	add_child(public_light)
	var archive_light := OmniLight3D.new()
	archive_light.name = "TownHallArchiveWarmth"
	archive_light.position = Vector3(-5.4, 2.55, 4.0)
	archive_light.light_color = Color(1.0, 0.66, 0.34)
	archive_light.light_energy = 1.35
	archive_light.omni_range = 7.0
	add_child(archive_light)
	var office_light := OmniLight3D.new()
	office_light.name = "TownHallOfficeWarmth"
	office_light.position = Vector3(5.2, 2.55, 4.0)
	office_light.light_color = Color(1.0, 0.62, 0.28)
	office_light.light_energy = 1.20
	office_light.omni_range = 7.0
	add_child(office_light)


func rebuild_fixture(reset_player := true) -> void:
	if is_rebuilding:
		return
	is_rebuilding = true
	if player != null and is_instance_valid(player):
		player.set_physics_process(false)
	set_loading("Clearing previous Town Hall")
	await get_tree().process_frame
	if cottage_root != null and is_instance_valid(cottage_root):
		cottage_root.queue_free()
	if furnishing_root != null and is_instance_valid(furnishing_root):
		furnishing_root.queue_free()
	cottage_root = null
	furnishing_root = null
	front_door = null
	door_service = null
	await get_tree().process_frame

	set_loading("Sampling civic recipe for seed %d" % selected_seed)
	blueprint = LandmarkBuildingBlueprintBuilderScript.build(selected_seed, "town_hall", {
		"settlementTier": "town",
		"biome": "temperate",
		"siteKey": "civic-square",
		"style": selected_style
	})
	await get_tree().process_frame

	set_loading("Publishing Town Hall shell")
	cottage_root = Node3D.new()
	cottage_root.name = "PublishedTownHallWalkthrough"
	add_child(cottage_root)
	building_publisher = BuildingPartPublisherScript.new()
	await building_publisher.publish_incremental(blueprint, cottage_root, 5)

	set_loading("Furnishing civic rooms")
	furnishing_plan = LandmarkFurnishingPlannerScript.build(blueprint, selected_seed * 7919 + 37)
	furnishing_root = Node3D.new()
	furnishing_root.name = "PublishedTownHallFurnishings"
	add_child(furnishing_root)
	furnishing_publisher = FurnishingPublisherScript.new()
	await furnishing_publisher.publish_incremental(furnishing_plan, furnishing_root, 4)
	refresh_room_lighting()

	set_loading("Registering civic entry door")
	front_door = find_front_door()
	door_service = DoorPortalServiceScript.new()
	door_service.setup(self, self)
	if front_door != null:
		door_service.register_door(front_door)
	await get_tree().process_frame
	if reset_player and player != null and is_instance_valid(player):
		place_player_at_entry()
		player.set_physics_process(true)
	is_rebuilding = false
	set_loading_visible(false)
	update_hud()


func place_player_at_entry() -> void:
	if player == null or blueprint == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var depth := float(recipe.get("depth", 15.0))
	player.position = Vector3(0.0, 0.04, -depth * 0.5 - 2.20)
	player.rotation.y = PI


func refresh_room_lighting() -> void:
	for child in get_children():
		if child is OmniLight3D and child.is_in_group("town_hall_fixture_room_light"):
			child.queue_free()
	if blueprint == null:
		return
	var light_specs := {
		"public_hall": {"energy": 4.1, "range": 15.0, "color": Color(1.0, 0.46, 0.16)},
		"notice_archive": {"energy": 1.8, "range": 7.2, "color": Color(1.0, 0.62, 0.30)},
		"steward_office": {"energy": 1.7, "range": 7.0, "color": Color(1.0, 0.60, 0.28)},
		"civic_store": {"energy": 1.35, "range": 6.4, "color": Color(1.0, 0.50, 0.20)}
	}
	for raw_room in blueprint.rooms:
		if not raw_room is Dictionary:
			continue
		var room := raw_room as Dictionary
		var role := String(room.get("role", ""))
		if not light_specs.has(role):
			continue
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		var spec: Dictionary = light_specs[role] as Dictionary
		var light := OmniLight3D.new()
		light.name = "TownHallRoomLight_%s" % role
		light.position = Vector3(bounds.get_center().x, 3.10, bounds.get_center().z)
		light.light_color = spec.get("color", Color.WHITE) as Color
		light.light_energy = float(spec.get("energy", 1.0))
		light.omni_range = float(spec.get("range", 6.0))
		light.shadow_enabled = true
		light.add_to_group("town_hall_fixture_room_light")
		add_child(light)


func place_capture_view() -> void:
	if player == null or blueprint == null or report_path.is_empty():
		return
	var recipe: Dictionary = blueprint.recipe
	var depth := float(recipe.get("depth", 15.0))
	var width := float(recipe.get("width", 24.0))
	match capture_view:
		"public":
			# An overview belongs to the public room, not one selected furnishing.
			# This keeps visual evidence readable as the seeded civic layout grows
			# from a table cluster into multiple role-aware zones.
			player.position = Vector3(-width * 0.36, 0.04, -depth * 0.26)
			player.look_at(Vector3(0.0, 1.18, -depth * 0.04), Vector3.UP)
		"archive":
			place_player_for_furnishing("archive_shelf_a", Vector3(2.80, 0.04, -2.20), Vector3(-width * 0.30, 0.04, depth * 0.27))
		"office":
			place_player_for_furnishing("steward_desk", Vector3(-2.60, 0.04, -2.20), Vector3(width * 0.30, 0.04, depth * 0.27))
		"store":
			place_player_for_furnishing("store_shelf_a", Vector3(-2.40, 0.04, -1.80), Vector3(width * 0.34, 0.04, depth * 0.27))
		_:
			place_player_at_entry()


func place_player_for_furnishing(furnishing_id: String, offset: Vector3, fallback_position: Vector3) -> void:
	var target := Vector3.ZERO
	if furnishing_plan != null:
		for part in furnishing_plan.parts:
			if part != null and String(part.id) == furnishing_id:
				target = part.position
				break
	if target == Vector3.ZERO:
		player.position = fallback_position
		player.rotation.y = PI
		return
	player.position = target + offset
	player.look_at(Vector3(target.x, player.position.y, target.z), Vector3.UP)


func update_loading_label() -> void:
	if loading_label == null:
		return
	var dot_count := int(floor(loading_elapsed * 4.0)) % 4
	loading_label.text = "LOADING SEEDED TOWN HALL\n%s%s\n\nPublishing through frame-sized batches" % [loading_message, ".".repeat(dot_count)]


func update_hud() -> void:
	if status_label == null:
		return
	var door_state := "UNAVAILABLE"
	if door_service != null and front_door != null:
		var portal = door_service.portal_for_door(front_door)
		if portal != null:
			door_state = String(portal.state).to_upper()
	var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
	status_label.text = "TOWN HALL WALKTHROUGH  |  %s\nseed %d  -  %.1fm x %.1fm  -  %s  |  Door: %s\n[WASD] move  [Shift] sprint  [Space] jump  [E] use entry door  [R] next seed  [Shift+R] previous  [Esc] release mouse\n%s" % [selected_style.to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), room_program_label(), door_state, interaction_text]


func room_program_label() -> String:
	if blueprint == null:
		return "loading rooms"
	var labels: Array[String] = []
	for raw_room in blueprint.rooms:
		if not raw_room is Dictionary:
			continue
		var role := String((raw_room as Dictionary).get("role", "room")).replace("_", " ")
		labels.append(role)
	return " / ".join(labels)


func write_automated_report() -> void:
	# Startup evidence only: manual play remains necessary for collision, door,
	# room traversal, and visual-readability acceptance.
	for _frame in range(6):
		await get_tree().process_frame
	var report := {
		"runnerId": "town_hall_walkthrough",
		"evidenceLevel": "headed-fixture-startup",
		"status": "passed" if blueprint != null and furnishing_plan != null and front_door != null and not is_rebuilding else "failed",
		"seed": selected_seed,
		"style": selected_style,
		"captureView": capture_view,
		"recipe": blueprint.recipe if blueprint != null else {},
		"buildingPublication": building_publisher.summary() if building_publisher != null else {},
		"furnishingPublication": furnishing_publisher.summary() if furnishing_publisher != null else {},
		"loadingVisible": loading_overlay.visible if loading_overlay != null else false,
		"notes": "Confirms incremental startup publication of the real Town Hall collision, furnishing, and shared-door fixture. It does not automate player movement or door interaction."
	}
	if not capture_path.is_empty():
		get_viewport().get_texture().get_image().save_png(capture_path)
		report["capturePath"] = capture_path
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	get_tree().quit(0 if String(report.get("status", "failed")) == "passed" else 1)
