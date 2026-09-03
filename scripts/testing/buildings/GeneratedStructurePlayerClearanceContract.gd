extends SceneTree
## Real physics queries with a synthetic capsule/floor, never live movement.
const Clearance = preload("res://scripts/world/GeneratedStructurePlayerClearance.gd")
var checks := {}
var evidence := {}
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := OS.get_environment("STRUCTURE_PLAYER_CLEARANCE_OUTPUT")
	if output.is_empty(): quit(2); return
	var fixture := Node3D.new()
	root.add_child(fixture)
	var floor := StaticBody3D.new()
	floor.position.y = -0.5
	var box := BoxShape3D.new()
	box.size = Vector3(8,1,8)
	var floor_shape := CollisionShape3D.new()
	floor_shape.shape = box
	floor.add_child(floor_shape)
	fixture.add_child(floor)
	var body := CharacterBody3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.42
	capsule.height = 1.72
	var collider := CollisionShape3D.new()
	collider.name = "PlayerCollider"
	collider.position.y = 0.86
	collider.shape = capsule
	body.add_child(collider)
	fixture.add_child(body)
	await physics_frame
	await process_frame
	var original := body.global_transform
	evidence.contact = Clearance.inspect(body)
	checks.floor_contact_clear = evidence.contact.passed
	checks.query_does_not_move_body = body.global_transform == original
	body.position.y = -0.2
	await physics_frame
	await process_frame
	original = body.global_transform
	evidence.overlap = Clearance.inspect(body)
	checks.penetration_rejected = not evidence.overlap.passed
	checks.overlap_query_does_not_recover_body = body.global_transform == original
	body.position = Vector3(0,3,0)
	await physics_frame
	await process_frame
	evidence.clear = Clearance.inspect(body)
	checks.clear_capsule_passes = evidence.clear.passed
	collider.disabled = true
	checks.missing_capsule_rejected = not Clearance.inspect(body).passed
	fixture.free()
	await process_frame
	var passed: bool = not checks.values().has(false)
	var report := {"passed":passed,"checks":checks,"evidence":evidence,"sourceSha256":FileAccess.get_sha256("res://scripts/world/GeneratedStructurePlayerClearance.gd"),"evidenceLevel":"synthetic capsule with real physics queries; no actual player traversal or save acceptance"}
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("PLAYER CLEARANCE ",passed)
	quit(0 if passed else 1)
