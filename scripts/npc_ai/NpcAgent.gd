extends CharacterBody3D
class_name NpcAgent

var physics_tick_count := 0
var last_motor_state = null
var motor_profile = null

func _ready() -> void:
	set_physics_process(true)

func _physics_process(_delta: float) -> void:
	physics_tick_count += 1
	set_meta("npc_physics_ticks", physics_tick_count)

func configure_agent(profile) -> void:
	motor_profile = profile
	set_meta("npc_agent_body", true)
