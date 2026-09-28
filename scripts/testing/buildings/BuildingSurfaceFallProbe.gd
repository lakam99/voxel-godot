extends CharacterBody3D

var gravity := ProjectSettings.get_setting("physics/3d/default_gravity") as float


func _physics_process(delta: float) -> void:
	velocity.y -= gravity * delta
	move_and_slide()
