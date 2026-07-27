extends CharacterBody3D
class_name CottagePocPlayer

signal interaction_requested

const MOVE_SPEED := 4.4
const SPRINT_SPEED := 6.5
const JUMP_VELOCITY := 5.2
const MOUSE_SENSITIVITY := 0.0024

var camera: Camera3D
var camera_pitch: Node3D


func _ready() -> void:
	name = "CottagePocPlayer"
	collision_layer = 1
	collision_mask = 1
	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.32
	shape.height = 1.72
	collider.shape = shape
	collider.position = Vector3(0.0, 0.86, 0.0)
	add_child(collider)
	camera_pitch = Node3D.new()
	camera_pitch.name = "CameraPitch"
	camera_pitch.position = Vector3(0.0, 1.48, 0.0)
	add_child(camera_pitch)
	camera = Camera3D.new()
	camera.name = "PlayerCamera"
	camera.current = true
	camera.fov = 74.0
	camera.near = 0.05
	camera_pitch.add_child(camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	else:
		velocity.y = -0.1
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = JUMP_VELOCITY
	var input_direction := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	)
	var move_speed := SPRINT_SPEED if Input.is_key_pressed(KEY_SHIFT) else MOVE_SPEED
	var local_direction := Vector3(input_direction.x, 0.0, input_direction.y).normalized()
	var world_direction := global_transform.basis * local_direction
	velocity.x = move_toward(velocity.x, world_direction.x * move_speed, move_speed * 10.0 * delta)
	velocity.z = move_toward(velocity.z, world_direction.z * move_speed, move_speed * 10.0 * delta)
	move_and_slide()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		rotate_y(-motion.relative.x * MOUSE_SENSITIVITY)
		camera_pitch.rotation.x = clampf(camera_pitch.rotation.x - motion.relative.y * MOUSE_SENSITIVITY, deg_to_rad(-82.0), deg_to_rad(82.0))
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.keycode == KEY_E:
			interaction_requested.emit()
