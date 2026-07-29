extends Node3D

## Real-physics review fixture for the furniture/decor PoC. This scene keeps
## the construction and furnishing builders authoritative, then adds only a
## local player controller and the established DoorPortalService consumer.

const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const CottageFurnishingPlannerScript := preload("res://scripts/buildings/CottageFurnishingPlanner.gd")
const FurnishingPublisherScript := preload("res://scripts/buildings/FurnishingPublisher.gd")
const DoorPortalServiceScript := preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const CottagePocPlayerScript := preload("res://scripts/testing/buildings/CottagePocPlayer.gd")

const INTERACTION_LAYER := 1 << 10

var selected_seed := 207154
var selected_style := "timber"
var blueprint
var furnishing_plan
var building_publisher
var furnishing_publisher
var cottage_root: Node3D
var furnishing_root: Node3D
var player: CharacterBody3D
var door_service
var front_door: StaticBody3D
var status_label: Label
var interaction_text := ""
var loading_overlay: ColorRect
var loading_panel: ColorRect
var loading_label: Label
var loading_message := ""
var loading_elapsed := 0.0
var is_rebuilding := false
var capture_path := ""
var report_path := ""


func _ready() -> void:
	read_arguments()
	build_world()
	build_hud()
	await rebuild_fixture(false)
	spawn_player()
	update_hud()
	if not report_path.is_empty():
		call_deferred("write_automated_report")


func read_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size()):
		var argument := String(args[index])
		if argument == "--seed" and index + 1 < args.size():
			selected_seed = int(String(args[index + 1]))
		elif argument == "--style" and index + 1 < args.size():
			selected_style = String(args[index + 1]).strip_edges().to_lower()
	if selected_style not in ["timber", "masonry"]:
		selected_style = "timber"
	capture_path = OS.get_environment("VOXEL_FURNISHED_COTTAGE_WALKTHROUGH_CAPTURE")
	report_path = OS.get_environment("VOXEL_FURNISHED_COTTAGE_WALKTHROUGH_REPORT")


func build_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.17, 0.28, 0.36)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.35, 0.43, 0.52)
	environment.ambient_light_energy = 0.58
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -34.0, 0.0)
	sun.light_color = Color(0.92, 0.79, 0.60)
	sun.light_energy = 1.45
	sun.shadow_enabled = true
	add_child(sun)
	var ground_body := StaticBody3D.new()
	ground_body.name = "WalkthroughGround"
	var ground_shape := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(48.0, 0.5, 48.0)
	ground_shape.shape = ground_box
	ground_shape.position.y = -0.25
	ground_body.add_child(ground_shape)
	add_child(ground_body)
	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(48.0, 48.0)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.21, 0.34, 0.19)
	ground_material.roughness = 0.96
	ground.material_override = ground_material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	var hearth_light := OmniLight3D.new()
	hearth_light.position = Vector3(-3.28, 1.55, 2.20)
	hearth_light.light_color = Color(1.0, 0.34, 0.08)
	hearth_light.light_energy = 2.8
	hearth_light.omni_range = 8.0
	hearth_light.shadow_enabled = true
	add_child(hearth_light)


func rebuild_fixture(reset_player := true) -> void:
	if is_rebuilding:
		return
	is_rebuilding = true
	if player != null and is_instance_valid(player):
		player.set_physics_process(false)
	set_loading("Clearing previous cottage")
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

	set_loading("Sampling seed %d" % selected_seed)
	blueprint = CottageBlueprintBuilderScript.build(selected_seed, selected_style)
	await get_tree().process_frame

	set_loading("Publishing cottage shell")
	cottage_root = Node3D.new()
	cottage_root.name = "PublishedWalkthroughCottage"
	add_child(cottage_root)
	building_publisher = BuildingPartPublisherScript.new()
	await building_publisher.publish_incremental(blueprint, cottage_root, 5)

	set_loading("Furnishing generated rooms")
	furnishing_plan = CottageFurnishingPlannerScript.build(blueprint, selected_seed * 7919 + 37)
	furnishing_root = Node3D.new()
	furnishing_root.name = "PublishedWalkthroughFurnishings"
	add_child(furnishing_root)
	furnishing_publisher = FurnishingPublisherScript.new()
	await furnishing_publisher.publish_incremental(furnishing_plan, furnishing_root, 4)

	set_loading("Registering the front door")
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


func spawn_player() -> void:
	player = CottagePocPlayerScript.new() as CharacterBody3D
	add_child(player)
	place_player_at_entry()
	if player.has_signal("interaction_requested"):
		player.connect("interaction_requested", Callable(self, "request_focused_door_use"))


func place_player_at_entry() -> void:
	if player == null or blueprint == null:
		return
	var recipe: Dictionary = blueprint.recipe
	var door_x := float(recipe.get("doorX", 0.0))
	var depth := float(recipe.get("depth", 6.6))
	player.position = Vector3(door_x, 0.04, -depth * 0.5 - 2.05)
	player.rotation.y = PI


func build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.02, 0.035, 0.060, 0.88)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(760.0, 136.0)
	layer.add_child(panel)
	status_label = Label.new()
	status_label.position = Vector2(38.0, 33.0)
	status_label.size = Vector2(730.0, 112.0)
	status_label.add_theme_font_size_override("font_size", 17)
	status_label.add_theme_color_override("font_color", Color("e7eff5"))
	layer.add_child(status_label)
	loading_overlay = ColorRect.new()
	loading_overlay.color = Color(0.015, 0.025, 0.045, 0.84)
	loading_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	loading_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(loading_overlay)
	loading_panel = ColorRect.new()
	loading_panel.color = Color(0.035, 0.065, 0.10, 0.96)
	loading_panel.position = Vector2(310.0, 260.0)
	loading_panel.size = Vector2(660.0, 164.0)
	layer.add_child(loading_panel)
	loading_label = Label.new()
	loading_label.position = Vector2(338.0, 300.0)
	loading_label.size = Vector2(604.0, 94.0)
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_label.add_theme_font_size_override("font_size", 24)
	loading_label.add_theme_color_override("font_color", Color("eef6ff"))
	layer.add_child(loading_label)
	set_loading_visible(false)
	update_hud()


func _process(delta: float) -> void:
	if is_rebuilding:
		loading_elapsed += delta
		update_loading_label()
		return
	if door_service != null and player != null:
		door_service.process(delta, [player])
	var door := focused_door()
	if door != null and door_service != null:
		var portal = door_service.portal_for_door(door)
		var is_open := portal != null and String(portal.state) == "open"
		interaction_text = "[E] Close door" if is_open else "[E] Open door"
	else:
		interaction_text = "Move to the painted front door"
	update_hud()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or is_rebuilding:
		return
	if event.keycode != KEY_R:
		return
	selected_seed += -1 if event.shift_pressed else 1
	interaction_text = "Rebuilding seed %d" % selected_seed
	rebuild_fixture(true)


func set_loading(message: String) -> void:
	loading_message = message
	loading_elapsed = 0.0
	set_loading_visible(true)
	update_loading_label()


func set_loading_visible(visible: bool) -> void:
	if loading_overlay != null:
		loading_overlay.visible = visible
	if loading_panel != null:
		loading_panel.visible = visible
	if loading_label != null:
		loading_label.visible = visible


func update_loading_label() -> void:
	if loading_label == null:
		return
	var dot_count := int(floor(loading_elapsed * 4.0)) % 4
	loading_label.text = "LOADING SEEDED COTTAGE\n%s%s\n\nPublishing in frame-sized batches" % [loading_message, ".".repeat(dot_count)]


func request_focused_door_use() -> void:
	var door := focused_door()
	if door == null or door_service == null or player == null:
		interaction_text = "Look at the painted front door to use it"
		return
	var portal = door_service.portal_for_door(door)
	var is_open := portal != null and String(portal.state) == "open"
	var result = door_service.request_door_state(door, not is_open, player, "player", {"actors": [player]})
	if result == null:
		interaction_text = "Door request was unavailable"
		return
	interaction_text = "Door %s" % String(result.reason).replace("_", " ")


func focused_door() -> StaticBody3D:
	if player == null or not player.has_method("get"):
		return null
	var camera: Camera3D = player.get("camera") as Camera3D
	if camera == null:
		return null
	var origin := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(origin, origin - camera.global_transform.basis.z * 2.75, INTERACTION_LAYER)
	query.collide_with_bodies = false
	query.collide_with_areas = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider := hit.get("collider") as Node if hit is Dictionary else null
	if collider != null and collider.has_meta("interaction_parent"):
		return collider.get_meta("interaction_parent") as StaticBody3D
	return null


func find_front_door() -> StaticBody3D:
	if cottage_root == null:
		return null
	for child in cottage_root.get_children():
		if child is StaticBody3D and String((child as StaticBody3D).get_meta("building_part_id", "")) == "front_door":
			return child as StaticBody3D
	return null


func update_hud() -> void:
	if status_label == null:
		return
	var door_state := "UNAVAILABLE"
	if door_service != null and front_door != null:
		var portal = door_service.portal_for_door(front_door)
		if portal != null:
			door_state = String(portal.state).to_upper()
	var recipe: Dictionary = blueprint.recipe if blueprint != null else {}
	status_label.text = "FURNISHED COTTAGE WALKTHROUGH  |  %s\nseed %d  -  %.1fm x %.1fm  -  %s  |  Door: %s\n[WASD] move  [Shift] sprint  [Space] jump  [E] use door  [R] next seed  [Shift+R] previous  [Esc] release mouse\n%s" % [selected_style.to_upper(), selected_seed, float(recipe.get("width", 0.0)), float(recipe.get("depth", 0.0)), String(recipe.get("furnishingProfile", "")), door_state, interaction_text]


func write_automated_report() -> void:
	# This is a headed fixture capture, not a substitute for the manual
	# collision/door walkthrough. It proves that the seed can publish through
	# the same incremental path without leaving the loading state stuck.
	for _frame in range(6):
		await get_tree().process_frame
	var report := {
		"runnerId": "furnished_cottage_walkthrough",
		"evidenceLevel": "headed-fixture-startup",
		"status": "passed" if blueprint != null and furnishing_plan != null and front_door != null and not is_rebuilding else "failed",
		"seed": selected_seed,
		"style": selected_style,
		"recipe": blueprint.recipe if blueprint != null else {},
		"buildingPublication": building_publisher.summary() if building_publisher != null else {},
		"furnishingPublication": furnishing_publisher.summary() if furnishing_publisher != null else {},
		"loadingVisible": loading_overlay.visible if loading_overlay != null else false,
		"notes": "Confirms startup publication of the real collision and shared-door walkthrough fixture. It does not automate player movement or door interaction."
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
