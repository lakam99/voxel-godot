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

var camera: Camera3D
var pitch := 0.0
var main: Node = null
var automated_input := false
var automated_move := Vector3.ZERO
var automated_sprint := false
var automated_jump := false
var physics_ticks := 0
var terrain_grounded := false
var max_upward_terrain_correction := 0.0
var max_downward_terrain_correction := 0.0
var airborne_obstacle_blocks := 0

func _ready() -> void:
    set_physics_process(true)

    camera = Camera3D.new()
    camera.name = "Camera3D"
    camera.current = true
    camera.fov = 72.0
    camera.position = Vector3(0.0, 1.65, 0.0)
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
    floor_snap_length = 0.32
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func handle_mouse_motion(relative: Vector2) -> void:
    rotate_y(-relative.x * MOUSE_SENSITIVITY)
    pitch = clamp(pitch - relative.y * MOUSE_SENSITIVITY, deg_to_rad(-82.0), deg_to_rad(82.0))
    camera.rotation.x = pitch

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
    var speed := SPRINT_SPEED if sprinting else WALK_SPEED
    var control := 1.0 if is_on_floor() or terrain_grounded else AIR_CONTROL
    velocity.x = lerp(velocity.x, wish.x * speed, min(1.0, ACCELERATION * control * delta))
    velocity.z = lerp(velocity.z, wish.z * speed, min(1.0, ACCELERATION * control * delta))

    var was_grounded := is_on_floor() or terrain_grounded
    var jumped := false
    var grounded := was_grounded
    if grounded:
        var jumping := automated_jump if automated_input else Input.is_key_pressed(KEY_SPACE)
        if jumping:
            velocity.y = JUMP_SPEED
            automated_jump = false
            terrain_grounded = false
            jumped = true
    else:
        velocity.y -= GRAVITY * delta

    var previous_position: Vector3 = global_position
    move_and_slide()
    apply_terrain_grounding(delta, was_grounded, jumped, previous_position)

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

func view_ray(max_distance: float) -> Dictionary:
    var origin := camera.global_position
    var end := origin + -camera.global_transform.basis.z * max_distance
    var query := PhysicsRayQueryParameters3D.create(origin, end)
    query.exclude = [self]
    return get_world_3d().direct_space_state.intersect_ray(query)
