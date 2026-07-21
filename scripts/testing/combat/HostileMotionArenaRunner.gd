extends Node3D

## Standalone combat arena. Static hostiles retain the original motion fixture;
## authored profiles such as the wolf use the same contact/presentation runtime
## while their real CharacterBody3D movement is driven by a reusable behavior
## policy and motor executor.

const HostileMotionCombatSystemScript := preload("res://scripts/combat/runtime/HostileMotionCombatSystem.gd")
const MotionArenaOpponentCatalogScript := preload("res://scripts/testing/combat/MotionArenaOpponentCatalog.gd")
const MotionRecipeBuilderScript := preload("res://scripts/combat/motion/MotionRecipeBuilder.gd")
const PlayerDefenseControllerScript := preload("res://scripts/combat/runtime/PlayerDefenseController.gd")
const PlayerMotionCombatControllerScript := preload("res://scripts/combat/runtime/PlayerMotionCombatController.gd")
const LiveCollisionContactGeometryAdapterScript := preload("res://scripts/combat/runtime/LiveCollisionContactGeometryAdapter.gd")
const HostileBehaviorControllerScript := preload("res://scripts/combat/hostile/HostileBehaviorController.gd")
const SurvivalSystemScript := preload("res://scripts/SurvivalSystem.gd")

const PLAYER_MAX_HEALTH := 100.0
const PLAYER_MOVE_SPEED := 5.4
const LOOP_DELAY_SECONDS := 0.72
const MOUSE_SENSITIVITY := 0.0022
const ARENA_SEEDS := [1543, 7651]
const MOTION_PLANE_PROFILES: Array[String] = ["seeded", "lateral", "rising", "falling", "overhead"]
const STATIC_AUTO_VERIFY_DURATION_SECONDS := 2.0
const WOLF_AUTO_VERIFY_DURATION_SECONDS := 8.2
const ARENA_HALF_EXTENT := 18.0
const DEFAULT_WOLF_START_DISTANCE := 4.35

var player: CharacterBody3D
var player_head: Node3D
var camera: Camera3D
var opponent: Node3D
var opponent_definition: Dictionary = {}
var hostile_motion: HostileMotionCombatSystem
var arena_survival: SurvivalSystem
var player_defense
var arena_player_motion
var wolf: CharacterBody3D
var wolf_profile
var wolf_behavior
var wolf_health := 0.0
var wolf_contact_count := 0
var wolf_defeated := false
var health := PLAYER_MAX_HEALTH
var contact_count := 0
var loop_enabled := true
var motion_paused := false
var loop_delay_remaining := 0.0
var selected_seed_index := 0
var selected_plane_profile := "seeded"
var last_hit_text := "No contact yet - step into the sweep to test it."
var elapsed_since_hit := INF
var auto_verify_enabled := false
var auto_verify_elapsed := 0.0
var auto_verify_capture_path := ""
var auto_verify_capture_time := 0.48
var auto_verify_capture_requested := false
var auto_dodge_enabled := false
var auto_dodge_requested := false
var auto_attack_enabled := false
var auto_attack_requested := false
var auto_track_enabled := false
var auto_claw_enabled := false
var auto_punish_enabled := false
var auto_punish_requested := false
var wolf_start_distance := DEFAULT_WOLF_START_DISTANCE
var wolf_dodge_success := false
var wolf_recovery_punish_contact := false
var render_frame_count := 0
var worst_render_frame_ms := 0.0
var render_frames_over_50ms := 0
var observed_render_frame_count := 0
var observed_worst_render_frame_ms := 0.0
var observed_render_frames_over_50ms := 0

var health_label: Label
var health_bar: ProgressBar
var wolf_health_label: Label
var wolf_health_bar: ProgressBar
var motion_label: Label
var status_label: Label
var controls_label: Label


func _ready() -> void:
	auto_verify_enabled = OS.get_environment("VOXEL_HOSTILE_MOTION_ARENA_AUTOVERIFY") == "1"
	auto_verify_capture_path = OS.get_environment("VOXEL_HOSTILE_MOTION_ARENA_CAPTURE")
	auto_dodge_enabled = OS.get_environment("VOXEL_HOSTILE_MOTION_ARENA_AUTODODGE") == "1"
	auto_attack_enabled = OS.get_environment("VOXEL_WOLF_ARENA_AUTOATTACK") == "1"
	auto_track_enabled = OS.get_environment("VOXEL_WOLF_ARENA_AUTOTRACK") == "1"
	auto_claw_enabled = OS.get_environment("VOXEL_WOLF_ARENA_AUTOCLAW") == "1"
	auto_punish_enabled = OS.get_environment("VOXEL_WOLF_ARENA_AUTOPUNISH") == "1"
	wolf_start_distance = requested_wolf_start_distance()
	selected_seed_index = requested_seed_index()
	opponent_definition = MotionArenaOpponentCatalogScript.definition_for(requested_opponent_id())
	selected_plane_profile = requested_motion_profile()
	create_world()
	create_player()
	create_player_defense()
	create_opponent()
	create_player_motion_adapter()
	auto_verify_capture_time = requested_capture_time()
	create_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	call_deferred("replay_motion")


func requested_opponent_id() -> String:
	var arguments := OS.get_cmdline_user_args()
	for index in range(arguments.size() - 1):
		if arguments[index] == "--arena-opponent":
			return arguments[index + 1]
	return MotionArenaOpponentCatalogScript.DEFAULT_OPPONENT_ID


func requested_seed_index() -> int:
	# The command-line value selects ordinary arena replay seed data before any
	# profile/body/controller is constructed. It is not a second RNG authority
	# or a runtime reseed; interactive [1]/[2] controls remain unchanged.
	var arguments := OS.get_cmdline_user_args()
	for index in range(arguments.size() - 1):
		if arguments[index] == "--arena-seed-index":
			return clampi(arguments[index + 1].to_int(), 0, ARENA_SEEDS.size() - 1)
	return 0


func requested_motion_profile() -> String:
	var arguments := OS.get_cmdline_user_args()
	for index in range(arguments.size() - 1):
		if arguments[index] == "--motion-profile":
			return normalized_motion_profile(arguments[index + 1])
	return "seeded"


func requested_capture_time() -> float:
	var raw := OS.get_environment("VOXEL_HOSTILE_MOTION_ARENA_CAPTURE_TIME")
	var default_time := 3.35 if is_wolf_opponent() else 0.48
	return clampf(raw.to_float(), 0.02, auto_verify_duration() - 0.02) if not raw.is_empty() else default_time


func requested_wolf_start_distance() -> float:
	# This is pre-act arena setup, not a behavior override. It lets review start
	# inside the profile's legitimate claw band or its lunge band using the same
	# live target facts that ordinary play supplies.
	var raw := OS.get_environment("VOXEL_WOLF_ARENA_START_DISTANCE")
	return clampf(raw.to_float(), 2.34, 5.40) if not raw.is_empty() else DEFAULT_WOLF_START_DISTANCE


func normalized_motion_profile(value: String) -> String:
	var normalized := value.strip_edges().to_lower()
	return normalized if MOTION_PLANE_PROFILES.has(normalized) else "seeded"


func resolved_motion_profile() -> String:
	var seed := int(ARENA_SEEDS[selected_seed_index])
	return MotionRecipeBuilderScript.resolve_plane_profile(seed, selected_plane_profile)


func cycle_motion_profile(step: int) -> void:
	var index := MOTION_PLANE_PROFILES.find(selected_plane_profile)
	index = 0 if index < 0 else index
	selected_plane_profile = MOTION_PLANE_PROFILES[posmod(index + step, MOTION_PLANE_PROFILES.size())]
	replay_motion()


func is_wolf_opponent() -> bool:
	return String(opponent_definition.get("family", "")) == "authored_hostile"


func auto_verify_duration() -> float:
	return WOLF_AUTO_VERIFY_DURATION_SECONDS if is_wolf_opponent() else STATIC_AUTO_VERIFY_DURATION_SECONDS


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
	for wall in [
		Vector3(0.0, 1.0, -ARENA_HALF_EXTENT), Vector3(0.0, 1.0, ARENA_HALF_EXTENT),
		Vector3(-ARENA_HALF_EXTENT, 1.0, 0.0), Vector3(ARENA_HALF_EXTENT, 1.0, 0.0)
	]:
		add_arena_boundary(wall)


func add_arena_boundary(position: Vector3) -> void:
	var boundary := StaticBody3D.new()
	boundary.name = "ArenaBoundary"
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(36.0, 2.0, 0.45) if absf(position.z) > absf(position.x) else Vector3(0.45, 2.0, 36.0)
	collision.shape = shape
	boundary.position = position
	boundary.add_child(collision)
	add_child(boundary)


func create_player() -> void:
	player = CharacterBody3D.new()
	player.name = "ArenaPlayer"
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


func create_player_defense() -> void:
	arena_survival = SurvivalSystemScript.new()
	player_defense = PlayerDefenseControllerScript.new()


func create_opponent() -> void:
	var result: Dictionary = MotionArenaOpponentCatalogScript.instantiate_opponent(opponent_definition)
	opponent = result.get("body", null) as Node3D
	if opponent == null:
		push_error("Motion Arena could not instantiate opponent %s" % str(opponent_definition))
		return
	opponent.position = Vector3.ZERO
	add_child(opponent)
	if is_wolf_opponent():
		wolf = opponent as CharacterBody3D
		wolf_profile = opponent_definition.get("behaviorProfile", null)
		wolf_health = float(wolf_profile.max_health) if wolf_profile != null else 1.0
		wolf_behavior = HostileBehaviorControllerScript.new()
		wolf_behavior.setup(wolf_profile, int(ARENA_SEEDS[selected_seed_index]))

	hostile_motion = HostileMotionCombatSystemScript.new()
	hostile_motion.name = "ArenaHostileMotion"
	hostile_motion.motion_contact_resolved.connect(_on_motion_contact_resolved)
	hostile_motion.motion_finished.connect(_on_motion_finished)
	add_child(hostile_motion)


func create_player_motion_adapter() -> void:
	if not is_wolf_opponent():
		return
	arena_player_motion = PlayerMotionCombatControllerScript.new()
	arena_player_motion.name = "ArenaPlayerMotion"
	add_child(arena_player_motion)
	arena_player_motion.setup(player, null, int(ARENA_SEEDS[selected_seed_index]))
	arena_player_motion.configure_contact_adapter(Callable(self, "arena_player_motion_targets"), Callable(self, "resolve_arena_player_motion_contact"))
	arena_player_motion.hostile_contact_resolved.connect(_on_arena_player_hostile_contact)


func create_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 8
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.04, 0.07, 0.86)
	panel.position = Vector2(18.0, 18.0)
	panel.size = Vector2(590.0, 250.0 if is_wolf_opponent() else 214.0)
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
	if is_wolf_opponent():
		wolf_health_label = Label.new()
		wolf_health_label.position = Vector2(292.0, 72.0)
		wolf_health_label.add_theme_font_size_override("font_size", 17)
		wolf_health_label.add_theme_color_override("font_color", Color("f5dfac"))
		layer.add_child(wolf_health_label)
		wolf_health_bar = ProgressBar.new()
		wolf_health_bar.position = Vector2(292.0, 99.0)
		wolf_health_bar.size = Vector2(230.0, 17.0)
		wolf_health_bar.min_value = 0.0
		wolf_health_bar.max_value = maxf(1.0, wolf_health)
		wolf_health_bar.show_percentage = false
		layer.add_child(wolf_health_bar)
	motion_label = Label.new()
	motion_label.position = Vector2(36.0, 128.0)
	motion_label.add_theme_font_size_override("font_size", 15)
	motion_label.add_theme_color_override("font_color", Color("bcd6ee"))
	layer.add_child(motion_label)
	status_label = Label.new()
	status_label.position = Vector2(36.0, 180.0 if is_wolf_opponent() else 154.0)
	status_label.add_theme_font_size_override("font_size", 15)
	status_label.add_theme_color_override("font_color", Color("f6e9a5"))
	layer.add_child(status_label)
	controls_label = Label.new()
	controls_label.position = Vector2(26.0, 675.0)
	controls_label.add_theme_font_size_override("font_size", 15)
	controls_label.add_theme_color_override("font_color", Color("d1dfed"))
	controls_label.text = "WASD move | Mouse look | [F] player motion | [C] dodge | [R] replay | [Q]/[E] plane | [1]/[2] seed | [L] loop | [Space] pause | [H] reset HP/ST | [Esc] release mouse"
	layer.add_child(controls_label)


func _physics_process(delta: float) -> void:
	if player_defense != null:
		player_defense.advance(delta)
	update_player_movement()
	if is_wolf_opponent():
		update_wolf_behavior(delta)
	else:
		update_static_motion_loop(delta)
	if not motion_paused:
		elapsed_since_hit += delta
	update_hud()
	if auto_verify_enabled:
		auto_verify_elapsed += delta
		if not auto_verify_capture_requested and not auto_verify_capture_path.is_empty() and auto_verify_elapsed >= auto_verify_capture_time:
			auto_verify_capture_requested = true
			capture_auto_verify()
		if auto_verify_elapsed >= auto_verify_duration():
			complete_auto_verify()


func _process(delta: float) -> void:
	# This is deliberately observation-only. The arena keeps all combat work in
	# the normal physics path; the review report records whether the headed loop
	# incurred a perceptible render-frame hitch on the current machine.
	render_frame_count += 1
	var frame_ms := maxf(0.0, delta) * 1000.0
	worst_render_frame_ms = maxf(worst_render_frame_ms, frame_ms)
	if frame_ms > 50.0:
		render_frames_over_50ms += 1
	# Asset/shader startup and the deliberate screenshot readback are not wolf
	# behavior work. Keep them in the raw counters, but separate them from the
	# steady-state behavior observation.
	if auto_verify_elapsed < 0.5 or auto_verify_capture_requested:
		return
	observed_render_frame_count += 1
	observed_worst_render_frame_ms = maxf(observed_worst_render_frame_ms, frame_ms)
	if frame_ms > 50.0:
		observed_render_frames_over_50ms += 1


func update_static_motion_loop(delta: float) -> void:
	if motion_paused or hostile_motion == null or opponent == null:
		return
	if not hostile_motion.is_motion_active(opponent):
		loop_delay_remaining = maxf(0.0, loop_delay_remaining - delta)
		if loop_enabled and loop_delay_remaining <= 0.0:
			replay_motion()


func update_wolf_behavior(delta: float) -> void:
	if motion_paused or wolf == null or wolf_behavior == null or wolf_defeated:
		return
	wolf_behavior.advance(delta, wolf, player, hostile_motion, arena_player_motion, {"center": Vector3.ZERO, "halfExtent": ARENA_HALF_EXTENT - 0.8})


func update_player_movement() -> void:
	if player == null:
		return
	# Capture-only camera assistance: this follows the real wolf body's position
	# without moving either actor or participating in behavior/contact decisions.
	# It makes a headed review frame legible while the interactive fixture keeps
	# normal mouse look untouched.
	if auto_track_enabled and is_wolf_opponent() and wolf != null and not wolf_defeated:
		var track_direction := wolf.global_position - player.global_position
		track_direction.y = 0.0
		if track_direction.length_squared() > 0.0001:
			player.rotation.y = atan2(-track_direction.x, -track_direction.z)
	if auto_dodge_enabled and not auto_dodge_requested and player_defense != null and not player_defense.is_active():
		var dodge_ready := true
		if is_wolf_opponent() and wolf != null and wolf_behavior != null and hostile_motion != null:
			# Do not pre-spend a dodge in the wolf fixture. Wait for its real shared
			# motion wind-up so this verifies an actual committed-lunge reaction.
			var wolf_behavior_state: Dictionary = wolf_behavior.summary()
			var wolf_motion_state: Dictionary = hostile_motion.summary_for_body(wolf)
			dodge_ready = String(wolf_behavior_state.get("state", "")) == "commit" and String(wolf_motion_state.get("phase", "")) == "windup"
		if dodge_ready:
			auto_dodge_requested = request_arena_dodge()
	if player_defense != null and player_defense.is_active():
		player.velocity = player_defense.direction * PlayerDefenseControllerScript.DODGE_SPEED
		player.velocity.y = -0.2
		player.move_and_slide()
		return
	if auto_attack_enabled and is_wolf_opponent() and not auto_attack_requested and wolf != null and not wolf_defeated:
		var to_wolf := wolf.global_position - player.global_position
		to_wolf.y = 0.0
		var distance_to_wolf := to_wolf.length()
		var behavior: Dictionary = wolf_behavior.summary() if wolf_behavior != null else {}
		var wolf_state := String(behavior.get("state", ""))
		if distance_to_wolf > 2.62 and to_wolf.length_squared() > 0.0001:
			var auto_direction := to_wolf.normalized()
			# PlayerMotionCombat samples local -Z as forward, so auto-drive must
			# use the same facing convention as the live player body.
			player.rotation.y = atan2(-auto_direction.x, -auto_direction.z)
			player.velocity = auto_direction * PLAYER_MOVE_SPEED
			player.velocity.y = -0.2
			player.move_and_slide()
			return
		if wolf_state in ["orbit", "probe"]:
			# The auto fixture chooses the explicit lateral profile so its target
			# corridor is repeatable; manual review still cycles every plane profile.
			auto_attack_requested = request_player_motion("lateral")
			if auto_attack_requested:
				last_hit_text = "AUTO PLAYER MOTION  |  entering the shared predicted threat corridor"
			return
	if auto_claw_enabled and is_wolf_opponent() and wolf != null and not wolf_defeated and wolf_behavior != null:
		# Exercise the profile's real close-range choice by moving the actual
		# player body into the claw band during its ordinary probe window. Nothing
		# invokes a wolf action directly or suppresses collision/motor behavior.
		var claw_behavior: Dictionary = wolf_behavior.summary()
		var claw_state := String(claw_behavior.get("state", ""))
		var claw_delta := wolf.global_position - player.global_position
		claw_delta.y = 0.0
		if claw_state == "probe" and claw_delta.length() > 2.72 and claw_delta.length_squared() > 0.0001:
			var claw_direction := claw_delta.normalized()
			player.rotation.y = atan2(-claw_direction.x, -claw_direction.z)
			player.velocity = claw_direction * PLAYER_MOVE_SPEED
			player.velocity.y = -0.2
			player.move_and_slide()
			return
	if auto_punish_enabled and is_wolf_opponent() and wolf != null and not wolf_defeated and wolf_behavior != null and not auto_punish_requested:
		# Move through the normal player motor during the fixed recovery window,
		# then submit the ordinary player motion. Recovery policy deliberately
		# rejects evade, so any registered contact proves a genuine punish window.
		var punish_behavior: Dictionary = wolf_behavior.summary()
		var punish_state := String(punish_behavior.get("state", ""))
		if punish_state == "recovery":
			var punish_delta := wolf.global_position - player.global_position
			punish_delta.y = 0.0
			if punish_delta.length() > 2.42 and punish_delta.length_squared() > 0.0001:
				var punish_direction := punish_delta.normalized()
				player.rotation.y = atan2(-punish_direction.x, -punish_direction.z)
				player.velocity = punish_direction * PLAYER_MOVE_SPEED
				player.velocity.y = -0.2
				player.move_and_slide()
				return
			auto_punish_requested = request_player_motion("lateral")
			if auto_punish_requested:
				last_hit_text = "RECOVERY PUNISH  |  shared player motion committed during the wolf opening"
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


func request_arena_dodge() -> bool:
	if player_defense == null or arena_survival == null or player == null:
		return false
	var away := player.global_position - (opponent.global_position if opponent != null else Vector3.ZERO)
	away.y = 0.0
	away = away.normalized() if away.length_squared() > 0.0001 else Vector3.BACK
	var started: bool = player_defense.request(arena_survival, away, true)
	if started:
		last_hit_text = "DODGE  |  %.0f stamina spent  |  clear the active white sweep" % PlayerDefenseControllerScript.DODGE_STAMINA_COST
	return started


func request_player_motion(plane_profile := "") -> bool:
	if arena_player_motion == null or wolf_defeated:
		return false
	var resolved_profile := selected_plane_profile if plane_profile.is_empty() else plane_profile
	var started: bool = arena_player_motion.begin_arc_motion(16.0, resolved_profile)
	if started:
		last_hit_text = "PLAYER MOTION  |  shared ribbon + predicted contact active"
	return started


func replay_motion() -> void:
	if is_wolf_opponent():
		reset_wolf_encounter()
		return
	if hostile_motion == null or opponent == null or player == null:
		return
	if hostile_motion.is_motion_active(opponent):
		hostile_motion.cancel_for_body(opponent)
	loop_delay_remaining = LOOP_DELAY_SECONDS
	var seed := int(ARENA_SEEDS[selected_seed_index])
	var damage := float(opponent_definition.get("testDamage", 16.0))
	var variant := String(opponent_definition.get("motionVariant", "arena"))
	hostile_motion.begin_arc_motion(opponent, player, "arena_player", damage, variant, seed, selected_plane_profile, true)


func reset_wolf_encounter() -> void:
	if wolf == null or wolf_profile == null:
		return
	if hostile_motion != null and hostile_motion.is_motion_active(wolf):
		hostile_motion.cancel_for_body(wolf)
	# Fixture reset happens before the review loop resumes. Runtime movement after
	# this point is exclusively through CharacterBody3D.move_and_slide().
	wolf.global_position = Vector3.ZERO
	wolf.velocity = Vector3.ZERO
	player.global_position = Vector3(0.0, 0.0, wolf_start_distance)
	player.velocity = Vector3.ZERO
	wolf_health = float(wolf_profile.max_health)
	wolf_contact_count = 0
	wolf_defeated = false
	wolf_dodge_success = false
	wolf_recovery_punish_contact = false
	if wolf_behavior != null:
		wolf_behavior.setup(wolf_profile, int(ARENA_SEEDS[selected_seed_index]))
	if arena_player_motion != null:
		arena_player_motion.clear_transient_state()
	health = PLAYER_MAX_HEALTH
	contact_count = 0
	auto_dodge_requested = false
	auto_attack_requested = false
	auto_punish_requested = false
	last_hit_text = "WOLF RESET  |  circle, probe, commit, recover, and evade are replayable from this seed."


func arena_player_motion_targets() -> Array:
	var result: Array = []
	if wolf == null or wolf_defeated or not is_instance_valid(wolf):
		return result
	var target_id := "arena_wolf:%d" % wolf.get_instance_id()
	for geometry in LiveCollisionContactGeometryAdapterScript.passive_spheres_for_body(wolf, target_id):
		result.append({
			"targetId": target_id,
			"geometry": geometry,
			"body": wolf,
			"variant": String(opponent_definition.get("motionVariant", "wolf"))
		})
	return result


func resolve_arena_player_motion_contact(target: Dictionary, _resolution: Dictionary, damage: float) -> Dictionary:
	var body = target.get("body") as Node3D
	if body != wolf or wolf_defeated:
		return {"defeated": false, "variant": "wolf", "position": Vector3.ZERO}
	wolf_health = maxf(0.0, wolf_health - maxf(0.0, damage))
	wolf_contact_count += 1
	var active_wolf_state := String(wolf_behavior.summary().get("state", "")) if wolf_behavior != null else ""
	wolf_recovery_punish_contact = wolf_recovery_punish_contact or active_wolf_state == "recovery"
	wolf_defeated = wolf_health <= 0.0
	if wolf_defeated:
		wolf.velocity = Vector3.ZERO
	last_hit_text = "WOLF HIT %d  |  %.1f damage  |  %s" % [wolf_contact_count, damage, "defeated" if wolf_defeated else "behavior will reassess"]
	return {
		"defeated": wolf_defeated,
		"variant": String(opponent_definition.get("motionVariant", "wolf")),
		"position": wolf.global_position + Vector3.UP * 0.62
	}


func _on_motion_contact_resolved(_source, target, _target_kind: String, damage: float, _variant: String, _resolution: Dictionary) -> void:
	if target != player:
		return
	health = maxf(0.0, health - damage)
	contact_count += 1
	elapsed_since_hit = 0.0
	last_hit_text = "CONTACT %d  |  %.1f damage  |  move out before the next swing" % [contact_count, damage]


func _on_motion_finished(source, _summary: Dictionary) -> void:
	loop_delay_remaining = LOOP_DELAY_SECONDS
	if is_wolf_opponent() and source == wolf and auto_dodge_enabled and auto_dodge_requested and contact_count == 0:
		# This is evaluated at the end of the exact shared lunge motion started by
		# the wolf. Later loop damage cannot retroactively change this proof.
		wolf_dodge_success = true


func _on_arena_player_hostile_contact(_body, _variant: String, _defeated: bool, _position: Vector3, _resolution: Dictionary) -> void:
	elapsed_since_hit = 0.0


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
			if arena_player_motion != null:
				arena_player_motion.set_physics_process(not motion_paused)
		KEY_R:
			motion_paused = false
			hostile_motion.set_physics_process(true)
			if arena_player_motion != null:
				arena_player_motion.set_physics_process(true)
			replay_motion()
		KEY_L:
			loop_enabled = not loop_enabled
		KEY_1:
			selected_seed_index = 0
			replay_motion()
		KEY_2:
			selected_seed_index = 1
			replay_motion()
		KEY_Q:
			cycle_motion_profile(-1)
		KEY_E:
			cycle_motion_profile(1)
		KEY_C:
			request_arena_dodge()
		KEY_F:
			request_player_motion()
		KEY_H:
			health = PLAYER_MAX_HEALTH
			contact_count = 0
			if is_wolf_opponent():
				reset_wolf_encounter()
			if arena_survival != null:
				arena_survival.stamina = arena_survival.max_stamina()
			last_hit_text = "HP reset - move in and out of the live sweep."
		_:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func update_hud() -> void:
	if health_label == null:
		return
	var distance := player.global_position.distance_to(opponent.global_position) if player != null and opponent != null else INF
	var active := hostile_motion != null and opponent != null and hostile_motion.is_motion_active(opponent)
	var active_summary: Dictionary = hostile_motion.summary_for_body(opponent) if active and hostile_motion != null and hostile_motion.has_method("summary_for_body") else {}
	var phase := String(active_summary.get("phase", ""))
	var phase_text := ("WIND-UP" if phase == "windup" else ("STRIKE" if phase in ["arc", "surge"] else ("RECOVERY" if phase == "recovery" else "SWING ACTIVE"))) if active else ("PAUSED" if motion_paused else "LOOP DELAY")
	var stamina := float(arena_survival.stamina) if arena_survival != null else 0.0
	var defense: Dictionary = player_defense.summary() if player_defense != null else {}
	health_label.text = "PLAYER HP  %.0f / %.0f   |   ST %.0f" % [health, PLAYER_MAX_HEALTH, stamina]
	health_bar.value = health
	var dodge_text := "DODGE ACTIVE" if bool(defense.get("active", false)) else ("Dodge ready" if float(defense.get("cooldown", 0.0)) <= 0.0 else "Dodge recovering")
	if is_wolf_opponent() and wolf_behavior != null:
		var behavior: Dictionary = wolf_behavior.summary()
		var intent: Dictionary = behavior.get("intent", {})
		var threat: Dictionary = behavior.get("threat", {})
		wolf_health_label.text = "WOLF HP  %.0f / %.0f" % [wolf_health, float(wolf_profile.max_health)]
		wolf_health_bar.value = wolf_health
		motion_label.text = "%s | %s  ->  %s | %.2fm / %.2fm | orbit %s | seed %d" % [
			String(behavior.get("state", "idle")).to_upper(), String(intent.get("kind", "hold")).to_upper(), phase_text,
			distance, float(wolf_profile.preferred_distance), "CW" if float(behavior.get("orbitDirection", 1.0)) < 0.0 else "CCW", int(ARENA_SEEDS[selected_seed_index])
		]
		var evade_text := "EVADE %s | cd %.2f | energy %.0f | threat %s" % [String(behavior.get("lastEvadeReason", "")), float(behavior.get("evadeCooldown", 0.0)), float(behavior.get("evadeStamina", 0.0)), String(threat.get("reason", "none"))]
		status_label.text = (last_hit_text if elapsed_since_hit < 2.8 else "Watch the probe before entering range; [F] starts a shared player motion.") + "  |  " + dodge_text + "  |  " + evade_text
	else:
		motion_label.text = "%s | %s | plane %s | seed %d | %.2fm | loop %s" % [phase_text, String(opponent_definition.get("id", "opponent")), resolved_motion_profile(), int(ARENA_SEEDS[selected_seed_index]), distance, "ON" if loop_enabled else "OFF"]
		status_label.text = (last_hit_text if elapsed_since_hit < 2.4 else "No contact - press C during wind-up to clear the white sweep.") + "  |  " + dodge_text


func complete_auto_verify() -> void:
	auto_verify_enabled = false
	var dodge_state: Dictionary = player_defense.summary() if player_defense != null else {}
	var passed := false
	var notes := ""
	if is_wolf_opponent() and wolf_behavior != null:
		var behavior: Dictionary = wolf_behavior.summary()
		var transitions: Array = behavior.get("transitions", [])
		var observed: Dictionary = {}
		for transition in transitions:
			if transition is Dictionary:
				observed[String((transition as Dictionary).get("to", ""))] = true
		passed = observed.has("orbit") and observed.has("probe") and observed.has("commit") and observed.has("recovery") \
			and (not auto_attack_enabled or observed.has("evade")) \
			and (not auto_dodge_enabled or wolf_dodge_success) \
			and (not auto_punish_enabled or wolf_recovery_punish_contact)
		notes = "Wolf fixture uses the authored profile, pure intent policy, CharacterBody3D motor, shared forward/arc motion runtime and live player contact geometry. Headed visual review is still required for readability and evade observation."
	else:
		var dodged := auto_dodge_enabled and contact_count == 0 and int(dodge_state.get("serial", 0)) >= 1 and player != null and opponent != null and player.global_position.distance_to(opponent.global_position) >= 4.2
		var struck := not auto_dodge_enabled and contact_count >= 1 and health < PLAYER_MAX_HEALTH
		passed = dodged or struck
		notes = "The fixture uses the real hostile motion/contact adapter, shared PlayerDefenseController, SurvivalSystem stamina, and a CharacterBody3D capsule. Automated dodge presses the same isolated defense state before the active phase; manual review still requires a headed arena run."
	var report := {
		"runnerId": "hostile_motion_arena",
		"evidenceLevel": "standalone-runtime-fixture",
		"status": "passed" if passed else "failed",
		"contactCount": contact_count,
		"playerHealth": health,
		"opponentId": String(opponent_definition.get("id", "")),
		"requestedPlaneProfile": selected_plane_profile,
		"resolvedPlaneProfile": resolved_motion_profile(),
		"autoDodge": auto_dodge_enabled,
		"autoAttack": auto_attack_enabled,
		"autoAttackRequested": auto_attack_requested,
		"autoPunish": auto_punish_enabled,
		"autoPunishRequested": auto_punish_requested,
		"dodgeState": dodge_state,
		"playerDistance": player.global_position.distance_to(opponent.global_position) if player != null and opponent != null else INF,
		"seed": int(ARENA_SEEDS[selected_seed_index]),
		"capturePath": auto_verify_capture_path,
		"wolf": wolf_behavior.summary() if wolf_behavior != null else {},
		"wolfHealth": wolf_health,
		"wolfContactCount": wolf_contact_count,
		"wolfDodgeSuccess": wolf_dodge_success,
		"wolfRecoveryPunishContact": wolf_recovery_punish_contact,
		"performance": {
			"renderFrameCount": render_frame_count,
			"worstRenderFrameMs": worst_render_frame_ms,
			"renderFramesOver50ms": render_frames_over_50ms,
			"steadyStateRenderFrameCount": observed_render_frame_count,
			"steadyStateWorstRenderFrameMs": observed_worst_render_frame_ms,
			"steadyStateRenderFramesOver50ms": observed_render_frames_over_50ms
		},
		"notes": notes
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
