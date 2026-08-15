extends Node3D

const NpcRouteLeaseExecutorScript := preload("res://scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd")

class ContactAuthority:
	extends RefCounted
	var unexpected_collisions: Array = []
	func begin_moving(_request_id: String, _reason := "") -> Dictionary:
		return {"ok": true}
	func report_segment_started(_request_id: String, _index: int, _details := {}) -> void:
		pass
	func report_unexpected_collision(_request_id: String, reason := "", details := {}) -> void:
		unexpected_collisions.append({"reason": reason, "details": details})

class InactiveCrowd:
	extends RefCounted
	func resolve_safe_velocity(_entry: Dictionary, _body: CharacterBody3D, desired_velocity: Vector3, _context := {}) -> Dictionary:
		return {"active": false, "safeVelocity": desired_velocity, "movementBlocked": false}

func _ready() -> void:
	var mover := _actor("DynamicContactMover", Vector3.ZERO)
	var blocker := _actor("DynamicContactBlocker", Vector3(0.69, 0.0, 0.0))
	var authority := ContactAuthority.new()
	var executor = NpcRouteLeaseExecutorScript.new()
	executor.setup(authority, null, null, InactiveCrowd.new())
	var lease := {
		"state": "ready",
		"leaseId": "dynamic-contact-lease",
		"waypoints": [Vector3(3.0, 0.0, 0.0)],
		"actions": {},
		"probeCertificate": {"ok": true, "authoritative": true}
	}
	var entry := {"id": "dynamic-contact-mover", "body": mover, "routeStatus": "moving", "routeLease": lease}
	for _frame in range(3):
		await get_tree().physics_frame
	var results: Array = []
	for _frame in range(4):
		results.append(executor.execute(entry, "dynamic-contact-request", lease, 1.0 / 60.0, {"speed": 2.6}))
		await get_tree().physics_frame
	var final_result: Dictionary = results[results.size() - 1]
	var generation := int(entry.get("_v2LeaseExecutorGeneration", -1))
	var passed := String(final_result.get("reason", "")) == "blocked_dynamic" \
		and String(final_result.get("classification", "")) == "motor_actor_contact" \
		and authority.unexpected_collisions.is_empty() \
		and String((entry.get("routeLease", {}) as Dictionary).get("leaseId", "")) == "dynamic-contact-lease" \
		and generation == 1
	var report := {
		"passed": passed,
		"results": results,
		"collisionReports": authority.unexpected_collisions,
		"generation": generation,
		"leaseId": String((entry.get("routeLease", {}) as Dictionary).get("leaseId", "")),
		"separation": mover.global_position.distance_to(blocker.global_position)
	}
	var report_path := ProjectSettings.globalize_path("res://artifacts/npc/reports/dynamic-contact.json")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
	print(JSON.stringify(report))
	get_tree().quit(0 if passed else 1)

func _actor(actor_name: String, position: Vector3) -> CharacterBody3D:
	var actor := CharacterBody3D.new()
	actor.name = actor_name
	actor.collision_layer = 4
	actor.collision_mask = 4
	actor.set_meta("npc_stable_id", actor_name)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.34
	capsule.height = 1.62
	collision.shape = capsule
	actor.add_child(collision)
	add_child(actor)
	actor.global_position = position
	return actor
