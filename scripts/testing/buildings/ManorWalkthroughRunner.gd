extends "res://scripts/testing/buildings/FurnishedCottageWalkthroughRunner.gd"

## Interactive ground-floor gate for the composed manor.  It deliberately
## reuses the established real player, BuildingPartPublisher collision and
## DoorPortalService rather than giving landmarks a separate interaction path.

const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")
const FurnishingPlanScript := preload("res://scripts/buildings/FurnishingPlan.gd")

var capture_view := "entry"


func _ready() -> void:
	read_arguments()
	build_world()
	build_hud()
	rebuild_fixture(false)
	spawn_player()
	# Capture placement exists only for headed visual inspection of a generated
	# level. It is deliberately unavailable to an interactive player and is not
	# reported as traversal evidence.
	if not report_path.is_empty() and capture_view != "entry":
		place_capture_player_for_view()
	update_hud()
	if not report_path.is_empty():
		call_deferred("write_automated_report")


func read_arguments() -> void:
	selected_seed = 208155
	selected_style = "timber"
	super.read_arguments()
	capture_path = OS.get_environment("VOXEL_MANOR_WALKTHROUGH_CAPTURE")
	report_path = OS.get_environment("VOXEL_MANOR_WALKTHROUGH_REPORT")
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		var argument := String(args[index])
		if argument == "--capture-path" and index + 1 < args.size():
			capture_path = String(args[index + 1])
		elif argument == "--report-path" and index + 1 < args.size():
			report_path = String(args[index + 1])
		elif argument == "--capture-view" and index + 1 < args.size():
			capture_view = String(args[index + 1]).strip_edges().to_lower()
	if capture_view not in ["entry", "stairs", "solar", "attic"]:
		capture_view = "entry"


func rebuild_fixture(reset_player := true) -> void:
	if is_rebuilding:
		return
	is_rebuilding = true
	if player != null and is_instance_valid(player):
		player.set_physics_process(false)
	set_loading("Clearing previous manor")
	if cottage_root != null and is_instance_valid(cottage_root):
		cottage_root.queue_free()
	if furnishing_root != null and is_instance_valid(furnishing_root):
		furnishing_root.queue_free()
	cottage_root = null
	furnishing_root = null
	front_door = null
	door_service = null

	set_loading("Sampling manor recipe for seed %d" % selected_seed)
	blueprint = LandmarkBuildingBlueprintBuilderScript.build(selected_seed, "manor", {
		"settlementTier": "town",
		"biome": "forest",
		"siteKey": "ridge-manor",
		"style": selected_style
	})

	set_loading("Publishing walkable manor shell")
	cottage_root = Node3D.new()
	cottage_root.name = "PublishedManorWalkthrough"
	add_child(cottage_root)
	building_publisher = BuildingPartPublisherScript.new()
	# The manor has a larger part count than the focused cottage fixture.  The
	# visual gate first proves the common collision/door contract synchronously;
	# future interactive furnishing work will move the complete landmark package
	# onto the established measured publication queue.
	building_publisher.publish(blueprint, cottage_root)

	# This pass validates entry, physical shell and circulation before manor
	# interiors are furnished.  An explicit empty plan preserves the ordinary
	# furnishing publication contract without inventing placeholder decor.
	furnishing_plan = FurnishingPlanScript.new("furnishing.%s.empty" % String(blueprint.id), selected_seed)
	furnishing_root = Node3D.new()
	furnishing_root.name = "PublishedManorWalkthroughFurnishings"
	add_child(furnishing_root)
	furnishing_publisher = FurnishingPublisherScript.new()
	# An empty plan has no frame-batched records to await. Publish it directly so
	# the fixture cannot retain its loading state waiting on a non-existent batch.
	furnishing_publisher.publish(furnishing_plan, furnishing_root)
	refresh_manor_lighting()

	set_loading("Registering manor entry door")
	front_door = find_front_door()
	door_service = DoorPortalServiceScript.new()
	door_service.setup(self, self)
	if front_door != null:
		door_service.register_door(front_door)
	if reset_player and player != null and is_instance_valid(player):
		place_player_at_entry()
		player.set_physics_process(true)
	is_rebuilding = false
	set_loading_visible(false)
	update_hud()


func refresh_manor_lighting() -> void:
	for child in get_children():
		if child is OmniLight3D and child.is_in_group("manor_walkthrough_light"):
			child.queue_free()
	if blueprint == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var width := float(recipe.get("width", 20.0))
	var depth := float(recipe.get("depth", 15.0))
	var floor_height := float(recipe.get("floorHeight", 3.55))
	for spec in [
		{"position": Vector3(-width * 0.10, 2.65, -depth * 0.18), "energy": 3.5, "range": 12.0, "color": Color(1.0, 0.48, 0.17)},
		{"position": Vector3(-width * 0.22, 2.35, depth * 0.10), "energy": 2.0, "range": 9.0, "color": Color(1.0, 0.62, 0.30)},
		{"position": Vector3(width * 0.18, floor_height + 2.30, -depth * 0.08), "energy": 1.4, "range": 8.0, "color": Color(1.0, 0.58, 0.26)},
		{"position": Vector3(width * 0.35, floor_height * 0.78, depth * 0.20), "energy": 2.2, "range": 8.0, "color": Color(1.0, 0.66, 0.34)},
		{"position": Vector3(width * 0.35, floor_height * 1.72, depth * 0.20), "energy": 1.8, "range": 7.0, "color": Color(1.0, 0.62, 0.30)}
	]:
		var light := OmniLight3D.new()
		light.position = spec.get("position", Vector3.ZERO) as Vector3
		light.light_energy = float(spec.get("energy", 1.0))
		light.omni_range = float(spec.get("range", 6.0))
		light.light_color = spec.get("color", Color.WHITE) as Color
		light.shadow_enabled = true
		light.add_to_group("manor_walkthrough_light")
		add_child(light)


func place_player_at_entry() -> void:
	if player == null or blueprint == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var width := float(recipe.get("width", 20.0))
	var depth := float(recipe.get("depth", 15.0))
	var lower_center_x := -width * 0.06
	var lower_center_z := -depth * 0.10
	var lower_depth := depth * 0.64
	player.position = Vector3(lower_center_x, 0.04, lower_center_z - lower_depth * 0.5 - 2.10)
	player.rotation.y = PI


func place_capture_player_for_view() -> void:
	if player == null or blueprint == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var width := float(recipe.get("width", 20.0))
	var depth := float(recipe.get("depth", 15.0))
	var foundation_height := float(recipe.get("foundationHeight", 0.48))
	var floor_height := float(recipe.get("floorHeight", 3.55))
	var tower_span := clampf(snappedf(width * 0.23, 0.20), 4.00, 5.40)
	var tower_center := Vector3(width * 0.35, 0.0, depth * 0.20)
	var stair_run := LandmarkBuildingBlueprintBuilderScript.manor_stair_run(tower_span)
	var left_stair_x := tower_center.x - tower_span * 0.20
	match capture_view:
		"stairs":
			# The player starts on the same physical lower-floor entry pad used
			# by manual play; this is a camera setup, not an exposed movement key.
			player.position = Vector3(left_stair_x, foundation_height + 0.34, tower_center.z - stair_run * 0.5 + 0.22)
			player.rotation.y = PI
		"solar":
			player.position = Vector3(tower_center.x - tower_span * 0.16, foundation_height + floor_height + 0.34, tower_center.z - stair_run * 0.5 + 0.20)
			player.rotation.y = PI
		"attic":
			player.position = Vector3(tower_center.x - tower_span * 0.16, foundation_height + floor_height * 2.0 + 0.34, tower_center.z - stair_run * 0.5 + 0.20)
			player.rotation.y = PI
	if player.camera_pitch != null:
		player.camera_pitch.rotation.x = deg_to_rad(-12.0)


func find_front_door() -> StaticBody3D:
	if cottage_root == null:
		return null
	for child in cottage_root.get_children():
		if child is StaticBody3D and String((child as StaticBody3D).get_meta("building_part_id", "")) == "manor_main_lower_entry_door":
			return child as StaticBody3D
	return null


func update_loading_label() -> void:
	if loading_label == null:
		return
	var dot_count := int(floor(loading_elapsed * 4.0)) % 4
	loading_label.text = "LOADING SEEDED MANOR\n%s%s\n\nPublishing through frame-sized batches" % [loading_message, ".".repeat(dot_count)]


func update_hud() -> void:
	if status_label == null:
		return
	var door_state := "UNAVAILABLE"
	if door_service != null and front_door != null:
		var portal = door_service.portal_for_door(front_door)
		if portal != null:
			door_state = String(portal.state).to_upper()
	var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
	status_label.text = "MANOR WALKTHROUGH  |  %s\nseed %d  -  %.1fm x %.1fm  -  %d storeys  |  Door: %s\n[WASD] move  [Shift] sprint  [Space] jump  [E] use entry door  [R] next seed  [Shift+R] previous  [Esc] release mouse\nEvery level connects through the generated stair tower. %s" % [selected_style.to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), int(recipe.get("floorCount", 0)), door_state, interaction_text]


func write_automated_report() -> void:
	# Startup only. Manual traversal is the acceptance evidence for collision and
	# the shared door interaction sequence.
	for _frame in range(3):
		await get_tree().process_frame
	var report := {
		"runnerId": "manor_walkthrough",
		"evidenceLevel": "headed-fixture-startup",
		"status": "passed" if blueprint != null and front_door != null and not is_rebuilding else "failed",
		"seed": selected_seed,
		"style": selected_style,
		"captureView": capture_view,
		"recipe": blueprint.recipe if blueprint != null else {},
		"buildingPublication": building_publisher.summary() if building_publisher != null else {},
		"doorRegistered": front_door != null and door_service != null,
		"loadingVisible": loading_overlay.visible if loading_overlay != null else false,
		"notes": "Confirms startup of the shared manor collision and door fixture. Capture-view placement is visual inspection only; it does not automate player traversal or door interaction."
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
