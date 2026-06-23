extends CharacterBody3D

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
    if jump_snap_time > 0.0:
        jump_snap_time = max(0.0, jump_snap_time - delta)
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
    var body_grounded := is_on_floor() and jump_snap_time <= 0.0
    var control := 1.0 if body_grounded or terrain_grounded else AIR_CONTROL
    velocity.x = lerp(velocity.x, wish.x * speed, min(1.0, ACCELERATION * control * delta))
    velocity.z = lerp(velocity.z, wish.z * speed, min(1.0, ACCELERATION * control * delta))

    var was_grounded := body_grounded or terrain_grounded
    var jumped := false
    jumped_this_frame = false
    var grounded := was_grounded
    if grounded:
        var jumping := automated_jump if automated_input else Input.is_key_pressed(KEY_SPACE)
        if jumping:
            velocity.y = JUMP_SPEED
            automated_jump = false
            terrain_grounded = false
            jump_snap_time = JUMP_SNAP_SUPPRESSION
            jumped = true
            jumped_this_frame = true
    else:
        velocity.y -= GRAVITY * delta

    if jumped and main and main.has_method("height_at_world"):
        var jump_ground_y: float = main.call("height_at_world", global_position.x, global_position.z)
        global_position.y = max(global_position.y, jump_ground_y + 0.08)

    var previous_position: Vector3 = global_position
    floor_snap_length = 0.0 if velocity.y > 0.0 or jump_snap_time > 0.0 else FLOOR_SNAP_LENGTH
    move_and_slide()
    if jumped:
        global_position.y = max(global_position.y, previous_position.y + JUMP_SPEED * delta)
        velocity.y = max(velocity.y, JUMP_SPEED)
    apply_terrain_grounding(delta, was_grounded, jumped, previous_position)
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

func apply_terrain_grounding(delta: float, was_grounded: bool, jumped: bool, previous_position: Vector3) -> void:
    if not main or not main.has_method("height_at_world"):
        terrain_grounded = is_on_floor()
        return

    var ground_y: float = main.call("height_at_world", global_position.x, global_position.z)
    var distance_above_ground: float = global_position.y - ground_y

    if distance_above_ground < 0.0:
        var rise_needed: float = -distance_above_ground
        var previous_ground_y: float = main.call("height_at_world", previous_position.x, previous_position.z)
        var horizontal_move: float = Vector2(global_position.x - previous_position.x, global_position.z - previous_position.z).length()
        var obstacle_rise: float = ground_y - previous_ground_y
        if was_grounded and not jumped and rise_needed <= TERRAIN_WALKABLE_RISE:
            var old_y: float = global_position.y
            var max_rise: float = TERRAIN_ASCEND_SPEED * delta
            global_position.y = move_toward(global_position.y, ground_y, max_rise)
            var correction: float = max(0.0, global_position.y - old_y)
            if correction > max_upward_terrain_correction:
                max_upward_terrain_correction = correction
            velocity.y = 0.0
            terrain_grounded = true
            return

        if (not was_grounded or jumped) and horizontal_move > 0.001 and obstacle_rise > TERRAIN_WALKABLE_RISE:
            global_position.x = previous_position.x
            global_position.z = previous_position.z
            velocity.x = 0.0
            velocity.z = 0.0
            terrain_grounded = false
            airborne_obstacle_blocks += 1
            if velocity.y <= 0.0 and global_position.y <= previous_ground_y + TERRAIN_LANDING_DISTANCE:
                global_position.y = previous_ground_y
                velocity.y = 0.0
                terrain_grounded = true
            return

        if was_grounded and not jumped:
            global_position = Vector3(previous_position.x, max(previous_position.y, previous_ground_y), previous_position.z)
            velocity.x = 0.0
            velocity.y = 0.0
            velocity.z = 0.0
            terrain_grounded = true
            return

        global_position.y = ground_y
        velocity.y = max(velocity.y, 0.0)
        terrain_grounded = not jumped
        return

    if jumped:
        terrain_grounded = false
        return

    if jump_snap_time > 0.0:
        terrain_grounded = false
        return

    if was_grounded and velocity.y <= 0.0 and distance_above_ground <= TERRAIN_WALKABLE_DROP:
        var old_y: float = global_position.y
        var max_drop: float = TERRAIN_DESCEND_SPEED * delta
        global_position.y = move_toward(global_position.y, ground_y, max_drop)
        var correction: float = max(0.0, old_y - global_position.y)
        if correction > max_downward_terrain_correction:
            max_downward_terrain_correction = correction
        if global_position.y <= ground_y + 0.03:
            global_position.y = ground_y
            velocity.y = 0.0
            terrain_grounded = true
        else:
            terrain_grounded = true
        return

    if velocity.y <= 0.0 and distance_above_ground <= TERRAIN_LANDING_DISTANCE:
        global_position.y = ground_y
        velocity.y = 0.0
        terrain_grounded = true
    else:
        terrain_grounded = false

func view_ray(max_distance: float, include_areas := false) -> Dictionary:
    var origin := camera.global_position
    var end := origin + -camera.global_transform.basis.z * max_distance
    var query := PhysicsRayQueryParameters3D.create(origin, end)
    query.exclude = [self]
    query.collide_with_areas = include_areas
    query.collide_with_bodies = true
    return get_world_3d().direct_space_state.intersect_ray(query)
