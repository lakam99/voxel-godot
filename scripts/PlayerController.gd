extends CharacterBody3D

const WALK_SPEED := 9.5
const SPRINT_SPEED := 15.5
const ACCELERATION := 14.0
const AIR_CONTROL := 0.42
const JUMP_SPEED := 8.9
const GRAVITY := 26.0
const MOUSE_SENSITIVITY := 0.0024

var camera: Camera3D
var pitch := 0.0
var main: Node = null

func _ready() -> void:
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
    var forward := -global_transform.basis.z
    forward.y = 0.0
    forward = forward.normalized()
    var right := global_transform.basis.x
    right.y = 0.0
    right = right.normalized()

    var wish := Vector3.ZERO
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

    var speed := SPRINT_SPEED if Input.is_key_pressed(KEY_SHIFT) else WALK_SPEED
    var control := 1.0 if is_on_floor() else AIR_CONTROL
    velocity.x = lerp(velocity.x, wish.x * speed, min(1.0, ACCELERATION * control * delta))
    velocity.z = lerp(velocity.z, wish.z * speed, min(1.0, ACCELERATION * control * delta))

    if is_on_floor():
        if Input.is_key_pressed(KEY_SPACE):
            velocity.y = JUMP_SPEED
    else:
        velocity.y -= GRAVITY * delta

    move_and_slide()

func view_ray(max_distance: float) -> Dictionary:
    var origin := camera.global_position
    var end := origin + -camera.global_transform.basis.z * max_distance
    var query := PhysicsRayQueryParameters3D.create(origin, end)
    query.exclude = [self]
    return get_world_3d().direct_space_state.intersect_ray(query)
