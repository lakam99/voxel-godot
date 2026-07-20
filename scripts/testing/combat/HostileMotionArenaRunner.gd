extends Node3D

## Interactive, standalone visual fixture for the production hostile motion
## adapter. It intentionally avoids Main.tscn and tutorial-town state: a
## stationary hostile repeats one deterministic side-arc while a real
## CharacterBody3D player can enter and leave the live contact volume.

const HostileMotionCombatSystemScript := preload("res://scripts/combat/runtime/HostileMotionCombatSystem.gd")
const MotionArenaOpponentCatalogScript := preload("res://scripts/testing/combat/MotionArenaOpponentCatalog.gd")

const PLAYER_MAX_HEALTH := 100.0
const PLAYER_MOVE_SPEED := 5.4
const LOOP_DELAY_SECONDS := 0.72
const MOUSE_SENSITIVITY := 0.0022
const ARENA_SEEDS := [1543, 7651]
const AUTO_VERIFY_DURATION_SECONDS := 2.0

var player: CharacterBody3D
var player_head: Node3D
var camera: Camera3D
var opponent: StaticBody3D
var opponent_definition: Dictionary = {}
var hostile_motion: HostileMotionCombatSystem
var health := PLAYER_MAX_HEALTH
var contact_count := 0
var loop_enabled := true
var motion_paused := false
var loop_delay_remaining := 0.0
var selected_seed_index := 0
var last_hit_text := "No contact yet - step into the sweep to test it."
var elapsed_since_hit := INF
var auto_verify_enabled := false
var auto_verify_elapsed := 0.0
var auto_verify_capture_path := ""
var auto_verify_capture_requested := false

var health_label: Label
var health_bar: ProgressBar
var motion_label: Label
var status_label: Label
var controls_label: Label


func _ready() -> void:
	auto_verify_enabled = OS.get_environment("VOXEL_HOSTILE_MOTION_ARENA_AUTOVERIFY") == "1"
	auto_verify_capture_path = OS.get_environment("VOXEL_HOSTILE_MOTION_ARENA_CAPTURE")
	opponent_definition = MotionArenaOpponentCatalogScript.definition_for(requested_opponent_id())
	create_world()
	create_player()
	create_opponent()
	create_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	call_deferred("replay_motion")


func requested_opponent_id() -> String:
	var arguments := OS.get_cmdline_user_args()
	for index in range(arguments.size() - 1):
		if arguments[index] == "--arena-opponent":
			return arguments[index + 1]
	return MotionArenaOpponentCatalogScript.DEFAULT_OPPONENT_ID


func create_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("7aa5bb")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("d6e4ee")
	environment.ambient_light_energy = 0.72
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -32.0, 0.0)
	sun.light_color = Color("ffe6bd")
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)

	var ground_body := StaticBody3D.new()
	ground_body.name = "ArenaGround"
	var ground_collision := CollisionShape3D.new()
	var ground_shape := BoxShape3D.new()
	ground_shape.size = Vector3(42.0, 0.20, 42.0)
	ground_collision.shape = ground_shape
	ground_collision.position.y = -0.10
	ground_body.add_child(ground_collision)
	add_child(ground_body)
	var ground_visual := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(42.0, 42.0)
	ground_visual.mesh = ground_mesh
	ground_visual.material_override = material(Color("47654b"), 0.0)
	ground_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground_visual)

	for index in range(12):
		var marker := MeshInstance3D.new()
		var marker_mesh := CylinderMesh.new()
		marker_mesh.top_radius = 0.035
		marker_mesh.bottom_radius = 0.035
		marker_mesh.height = 0.75
		marker.mesh = marker_mesh
		marker.position = Vector3(-8.0 + float(index) * 1.45, 0.375, -3.9)
		marker.material_override = material(Color("ecd891"), 0.0)
		marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(marker)


func create_player() -> void:
	player = CharacterBody3D.new()
	player.name = "ArenaPlayer"
	# Starts inside the outer sweep without placing the stationary enemy in the
	# camera. From here the player can observe a hit, then step backwards or
	# sideways to test the actual capsule sweep.
	player.position = Vector3(0.0, 0.0, 2.35)
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.38
	shape.height = 1.78
	collision.shape = shape
	collision.position.y = 0.89
	player.add_child(collision)
	player_head = Node3D.new()
	player_head.name = "ArenaPlayerHead"
	player_head.position = Vector3(0.0, 1.50, 0.0)
	player.add_child(player_head)
	camera = Camera3D.new()
	camera.name = "ArenaCamera"
	camera.current = true
	camera.fov = 73.0
	camera.near = 0.05
	player_head.add_child(camera)
	add_child(player)


func create_opponent() -> void:
	var result: Dictionary = MotionArenaOpponentCatalogScript.instantiate_static_opponent(opponent_definition)
	opponent = result.get("body", null) as StaticBody3D
	if opponent == null:
		push_error("Motion Arena could not instantiate opponent %s" % str(opponent_definition))
		return
	opponent.position = Vector3.ZERO
	add_child(opponent)

	hostile_motion = HostileMotionCombatSystemScript.new()
	hostile_motion.name = "ArenaHostileMotion"
	hostile_motion.motion_contact_resolved.connect(_on_motion_contact_resolved)
	hostile_motion.motion_finished.connect(_on_motion_finished)
	add_child(hostile_motion)


func create_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 8
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.04, 0.07, 0.86)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(498.0, 190.0)
	layer.add_child(panel)
	var title := Label.new()
	title.text = "HOSTILE MOTION ARENA  |  %s" % String(opponent_definition.get("displayName", "OPPONENT")).to_upper()
	title.position = Vector2(36.0, 34.0)
	title.add_theme_font_size_override("font_size", 23)
	title.add_theme_color_override("font_color", Color("e0f0ff"))
	layer.add_child(title)
	health_label = Label.new()
	health_label.position = Vector2(36.0, 72.0)
	health_label.add_theme_font_size_override("font_size", 17)
	health_label.add_theme_color_override("font_color", Color("f4c7c4"))
	layer.add_child(health_label)
	health_bar = ProgressBar.new()
	health_bar.position = Vector2(36.0, 99.0)
	health_bar.size = Vector2(230.0, 17.0)
	health_bar.min_value = 0.0
	health_bar.max_value = PLAYER_MAX_HEALTH
	health_bar.show_percentage = false
	layer.add_child(health_bar)
	motion_label = Label.new()
	motion_label.position = Vector2(36.0, 128.0)
	motion_label.add_theme_font_size_override("font_size", 15)
	motion_label.add_theme_color_override("font_color", Color("bcd6ee"))
	layer.add_child(motion_label)
	status_label = Label.new()
	status_label.position = Vector2(36.0, 154.0)
	status_label.add_theme_font_size_override("font_size", 15)
	status_label.add_theme_color_override("font_color", Color("f6e9a5"))
	layer.add_child(status_label)
	controls_label = Label.new()
	controls_label.position = Vector2(26.0, 675.0)
	controls_label.add_theme_font_size_override("font_size", 15)
	controls_label.add_theme_color_override("font_color", Color("d1dfed"))
	controls_label.text = "WASD move | Mouse look | [R] replay | [Space] pause | [L] loop | [1]/[2] seed | [H] reset HP | [Esc] release mouse"
	layer.add_child(controls_label)


func _physics_process(delta: float) -> void:
	update_player_movement()
	if not motion_paused:
		elapsed_since_hit += delta
		if not hostile_motion.is_motion_active(opponent):
			loop_delay_remaining = maxf(0.0, loop_delay_remaining - delta)
			if loop_enabled and loop_delay_remaining <= 0.0:
				replay_motion()
	update_hud()
	if auto_verify_enabled:
		auto_verify_elapsed += delta
		if not auto_verify_capture_requested and not auto_verify_capture_path.is_empty() and auto_verify_elapsed >= 0.48:
			auto_verify_capture_requested = true
			capture_auto_verify()
		if auto_verify_elapsed >= AUTO_VERIFY_DURATION_SECONDS:
			complete_auto_verify()


func update_player_movement() -> void:
	if player == null:
		return
	var input := Vector2.ZERO
	if Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input.x += 1.0
	if Input.is_key_pressed(KEY_W):
		input.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		input.y += 1.0
	var local_direction := Vector3(input.x, 0.0, input.y)
	if local_direction.length_squared() > 0.0001:
		local_direction = local_direction.normalized()
	var world_direction := local_direction.rotated(Vector3.UP, player.rotation.y)
	player.velocity.x = world_direction.x * PLAYER_MOVE_SPEED
	player.velocity.z = world_direction.z * PLAYER_MOVE_SPEED
	player.velocity.y = -0.2
	player.move_and_slide()


func replay_motion() -> void:
	if hostile_motion == null or opponent == null or player == null:
		return
	if hostile_motion.is_motion_active(opponent):
		hostile_motion.cancel_for_body(opponent)
	loop_delay_remaining = LOOP_DELAY_SECONDS
	var seed := int(ARENA_SEEDS[selected_seed_index])
	var damage := float(opponent_definition.get("testDamage", 16.0))
	var variant := String(opponent_definition.get("motionVariant", "arena"))
	hostile_motion.begin_side_arc_motion(opponent, player, "arena_player", damage, variant, seed)


func _on_motion_contact_resolved(_source, target, _target_kind: String, damage: float, _variant: String, _resolution: Dictionary) -> void:
	if target != player:
		return
	health = maxf(0.0, health - damage)
	contact_count += 1
	elapsed_since_hit = 0.0
	last_hit_text = "CONTACT %d  |  %.1f damage  |  move out before the next swing" % [contact_count, damage]


func _on_motion_finished(_source, _summary: Dictionary) -> void:
	loop_delay_remaining = LOOP_DELAY_SECONDS


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		player.rotate_y(-motion.relative.x * MOUSE_SENSITIVITY)
		player_head.rotate_x(-motion.relative.y * MOUSE_SENSITIVITY)
		player_head.rotation.x = clampf(player_head.rotation.x, deg_to_rad(-72.0), deg_to_rad(72.0))
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		KEY_SPACE:
			motion_paused = not motion_paused
			hostile_motion.set_physics_process(not motion_paused)
		KEY_R:
			motion_paused = false
			hostile_motion.set_physics_process(true)
			replay_motion()
		KEY_L:
			loop_enabled = not loop_enabled
		KEY_1:
			selected_seed_index = 0
			replay_motion()
		KEY_2:
			selected_seed_index = 1
			replay_motion()
		KEY_H:
			health = PLAYER_MAX_HEALTH
			contact_count = 0
			last_hit_text = "HP reset - move in and out of the live sweep."
		_:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func update_hud() -> void:
	if health_label == null:
		return
	var distance := player.global_position.distance_to(opponent.global_position) if player != null and opponent != null else INF
	var active := hostile_motion != null and hostile_motion.is_motion_active(opponent)
	var phase_text := "SWING ACTIVE" if active else ("PAUSED" if motion_paused else "LOOP DELAY")
	health_label.text = "PLAYER HP  %.0f / %.0f" % [health, PLAYER_MAX_HEALTH]
	health_bar.value = health
	motion_label.text = "%s | %s | seed %d | distance %.2fm | loop %s" % [phase_text, String(opponent_definition.get("id", "opponent")), int(ARENA_SEEDS[selected_seed_index]), distance, "ON" if loop_enabled else "OFF"]
	status_label.text = last_hit_text if elapsed_since_hit < 2.4 else "No contact - dodge by leaving the white arc before it reaches your capsule."


func complete_auto_verify() -> void:
	auto_verify_enabled = false
	var passed := contact_count >= 1 and health < PLAYER_MAX_HEALTH
	var report := {
		"runnerId": "hostile_motion_arena",
		"evidenceLevel": "standalone-runtime-fixture",
		"status": "passed" if passed else "failed",
		"contactCount": contact_count,
		"playerHealth": health,
		"opponentId": String(opponent_definition.get("id", "")),
		"seed": int(ARENA_SEEDS[selected_seed_index]),
		"capturePath": auto_verify_capture_path,
		"notes": "The real hostile motion/contact adapter struck the fixture's CharacterBody3D capsule. This automated fixture does not prove manual dodging."
	}
	var report_path := OS.get_environment("VOXEL_HOSTILE_MOTION_ARENA_REPORT")
	if not report_path.is_empty():
		var report_file := FileAccess.open(report_path, FileAccess.WRITE)
		if report_file != null:
			report_file.store_string(JSON.stringify(report, "\t"))
			report_file.close()
	get_tree().quit(0 if passed else 1)


func capture_auto_verify() -> void:
	await RenderingServer.frame_post_draw
	if auto_verify_capture_path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(auto_verify_capture_path.get_base_dir())
	var image := get_viewport().get_texture().get_image()
	image.save_png(auto_verify_capture_path)


func material(color: Color, emission_energy: float) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = 0.85
	if emission_energy > 0.0:
		result.emission_enabled = true
		result.emission = color * emission_energy
	return result
