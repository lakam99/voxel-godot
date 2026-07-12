extends CharacterBody3D

const CharacterMotor3DScript := preload("res://scripts/npc_ai/motor/CharacterMotor3D.gd")
const CharacterMotorCommandScript := preload("res://scripts/npc_ai/contracts/CharacterMotorCommand.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")

const WALK_SPEED := 9.5
const SPRINT_SPEED := 15.5
const ACCELERATION := 14.0
const AIR_CONTROL := 0.42
const JUMP_SPEED := 8.9
const GRAVITY := 26.0
const MOUSE_SENSITIVITY := 0.0024
const TERRAIN_LANDING_DISTANCE := 0.18
const TERRAIN_WALKABLE_RISE := 1.55
const TERRAIN_WALKABLE_DROP := 1.55
const TERRAIN_ASCEND_SPEED := 8.5
const TERRAIN_DESCEND_SPEED := 7.25
const FLOOR_SNAP_LENGTH := 0.32
const JUMP_SNAP_SUPPRESSION := 0.24

var camera: Camera3D
var pitch := 0.0
var main: Node = null
var survival = null
var automated_input := false
var automated_move := Vector3.ZERO
var automated_sprint := false
var automated_jump := false
var physics_ticks := 0
var terrain_grounded := false
var max_upward_terrain_correction := 0.0
var max_downward_terrain_correction := 0.0
var airborne_obstacle_blocks := 0
var jump_snap_time := 0.0
var is_moving := false
var is_sprinting := false
var jumped_this_frame := false
var mouse_sensitivity := MOUSE_SENSITIVITY
var invert_y := false
var look_smoothing := 0.0
var smoothed_look_delta := Vector2.ZERO
var head_bob_enabled := true
var head_bob_phase := 0.0
var base_camera_position := Vector3(0.0, 1.65, 0.0)
var character_motor = CharacterMotor3DScript.new()
var motor_profile = CharacterMotorProfileScript.player_default()
var terrain_collision_hold_frames := 0
var last_terrain_collision_proof := {}

func _ready() -> void:
    set_physics_process(true)

    camera = Camera3D.new()
    camera.name = "Camera3D"
    camera.current = true
    camera.fov = 72.0
    camera.position = base_camera_position
    add_child(camera)

    var shape := CapsuleShape3D.new()
    shape.radius = 0.42
    shape.height = 1.72
    var collider := CollisionShape3D.new()
    collider.name = "PlayerCollider"
    collider.shape = shape
    collider.position.y = 0.86
    add_child(collider)

    floor_max_angle = deg_to_rad(46.0)
    floor_snap_length = FLOOR_SNAP_LENGTH
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func handle_mouse_motion(relative: Vector2) -> void:
    var look_delta := relative
    if look_smoothing > 0.001:
        var smoothing_weight := clampf(1.0 - look_smoothing, 0.18, 1.0)
        smoothed_look_delta = smoothed_look_delta.lerp(relative, smoothing_weight)
        look_delta = smoothed_look_delta
    var y_delta := -look_delta.y if invert_y else look_delta.y
    rotate_y(-look_delta.x * mouse_sensitivity)
    pitch = clamp(pitch - y_delta * mouse_sensitivity, deg_to_rad(-82.0), deg_to_rad(82.0))
    camera.rotation.x = pitch

func apply_camera_settings(settings: Dictionary) -> void:
    mouse_sensitivity = MOUSE_SENSITIVITY * float(settings.get("mouseSensitivity", 1.0))
    invert_y = bool(settings.get("invertY", false))
    look_smoothing = clampf(float(settings.get("lookSmoothing", 0.0)), 0.0, 0.82)
    head_bob_enabled = bool(settings.get("headBob", true))
    if camera:
        camera.fov = clampf(float(settings.get("fov", 72.0)), 58.0, 104.0)

func _physics_process(delta: float) -> void:
    physics_ticks += 1
    var forward := -global_transform.basis.z
    forward.y = 0.0
    forward = forward.normalized()
    var right := global_transform.basis.x
    right.y = 0.0
    right = right.normalized()

    var wish := Vector3.ZERO
    if automated_input:
        wish = automated_move
    else:
        if Input.is_key_pressed(KEY_W):
            wish += forward
        if Input.is_key_pressed(KEY_S):
            wish -= forward
        if Input.is_key_pressed(KEY_D):
            wish += right
        if Input.is_key_pressed(KEY_A):
            wish -= right
    if wish.length_squared() > 0.001:
        wish = wish.normalized()

    var sprinting := automated_sprint if automated_input else Input.is_key_pressed(KEY_SHIFT)
    if sprinting and survival != null and survival.has_method("can_sprint"):
        sprinting = survival.can_sprint()
    is_moving = wish.length_squared() > 0.001
    is_sprinting = sprinting and is_moving
    var speed := SPRINT_SPEED if sprinting else WALK_SPEED
    var jumping := automated_jump if automated_input else Input.is_key_pressed(KEY_SPACE)
    if main != null and main.has_method("terrain_collision_motion_proof"):
        var predicted_position := global_position + wish * speed * delta
        var collision_proof: Dictionary = main.call("terrain_collision_motion_proof", global_position, predicted_position, 0.42)
        last_terrain_collision_proof = collision_proof
        if not bool(collision_proof.get("passed", false)):
            terrain_collision_hold_frames += 1
            velocity = Vector3.ZERO
            is_moving = false
            is_sprinting = false
            terrain_grounded = false
            set_meta("terrain_collision_hold", true)
            set_meta("terrain_collision_hold_reason", String(collision_proof.get("reason", "collision_not_ready")))
            update_camera_feel(delta)
            return
    set_meta("terrain_collision_hold", false)
    set_meta("terrain_collision_hold_reason", "")
    var command = CharacterMotorCommandScript.from_direction(wish, speed, jumping, sprinting)
    command.terrain_grounded = terrain_grounded
    command.grounded_hint = is_on_floor()
    command.jump_snap_time = jump_snap_time
    var motor_state = character_motor.call("apply", self, command, motor_profile, delta, main)
    terrain_grounded = bool(motor_state.get("terrain_grounded"))
    jump_snap_time = float(motor_state.get("jump_snap_time"))
    jumped_this_frame = bool(motor_state.get("jumped"))
    if jumped_this_frame:
        automated_jump = false
    max_upward_terrain_correction = maxf(max_upward_terrain_correction, float(motor_state.get("upward_terrain_correction")))
    max_downward_terrain_correction = maxf(max_downward_terrain_correction, float(motor_state.get("downward_terrain_correction")))
    if bool(motor_state.get("airborne_obstacle_blocked")):
        airborne_obstacle_blocks += 1
    update_camera_feel(delta)

func update_camera_feel(delta: float) -> void:
    if camera == null:
        return
    var bob := 0.0
    if head_bob_enabled and is_moving and (terrain_grounded or is_on_floor()):
        head_bob_phase += delta * (12.0 if is_sprinting else 8.0)
        bob = sin(head_bob_phase) * (0.045 if is_sprinting else 0.030)
    else:
        head_bob_phase = lerpf(head_bob_phase, 0.0, min(1.0, delta * 4.0))
    var target_position := base_camera_position + Vector3(0.0, bob, 0.0)
    camera.position = camera.position.lerp(target_position, min(1.0, delta * 12.0))

func view_ray(max_distance: float, include_areas := false) -> Dictionary:
    var origin := camera.global_position
    var end := origin + -camera.global_transform.basis.z * max_distance
    var query := PhysicsRayQueryParameters3D.create(origin, end)
    query.exclude = [self]
    query.collide_with_areas = include_areas
    query.collide_with_bodies = true
    return get_world_3d().direct_space_state.intersect_ray(query)
