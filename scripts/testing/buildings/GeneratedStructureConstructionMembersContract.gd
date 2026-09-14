extends "res://scripts/testing/buildings/GeneratedStructureRuntimeBindingsContract.gd"
## Synthetic real binding/capsule contract. No placement, live traversal,
## scene-publication receipt or physical clearance after loading is claimed.

class CountedBindings extends "res://scripts/world/GeneratedStructureRuntimeBindings.gd":
	var owner_reads: int = 0
	var player_reads: int = 0
	func available() -> bool:
		owner_reads += 1
		return super.available()
	func _construction_player_state() -> Dictionary:
		player_reads += 1
		return super._construction_player_state()
	func clear_counts() -> void:
		owner_reads = 0
		player_reads = 0

func _member_cells(bounds: AABB, cell: float) -> Rect2i:
	# Independently express the documented sample-node convention, then compare
	# the new batch to the existing public Rect2i API for every complete member.
	var low: Vector2i = Vector2i(floori(bounds.position.x/cell),floori(bounds.position.z/cell))
	var high: Vector2i = Vector2i(ceili(bounds.end.x/cell)+1,ceili(bounds.end.z/cell)+1)
	return Rect2i(low,high-low)

func _compare_members(c: Dictionary, label: String, members: Array) -> bool:
	var expected: bool = true
	for bounds: AABB in members:
		var allowed: bool = c.binding.construction_allowed(_member_cells(bounds,c.main.CELL))
		expected = expected and allowed
	var original: PackedByteArray = var_to_bytes(members)
	var pose: Transform3D = c.main.player.global_transform
	c.binding.clear_counts()
	var actual: bool = c.binding.construction_members_allowed(members)
	check(label+"_same_per_member_decision",actual==expected)
	check(label+"_one_owner_and_actor_validation",c.binding.owner_reads==1 and c.binding.player_reads==1)
	check(label+"_does_not_move_actor_or_mutate_members",pose==c.main.player.global_transform and original==var_to_bytes(members))
	return actual

func _run() -> void:
	var c: Dictionary = fixture()
	c.binding = CountedBindings.new()
	check("batch_configured",c.binding.configure(c.main))
	var local: AABB = AABB(Vector3(-1,0,-1),Vector3(2,2,2))
	var disjoint: Array = [AABB(Vector3(-21,0,-1),Vector3(2,2,2)),AABB(Vector3(19,0,-1),Vector3(2,2,2))]
	check("batch_missing_player_denied",not c.binding.construction_members_allowed(disjoint))
	check("empty_batch_missing_player_denied",not c.binding.construction_members_allowed([]))
	var player: CharacterBody3D = CharacterBody3D.new()
	c.main.add_child(player)
	c.main.player = player
	player.set_physics_process(true)
	check("batch_missing_collider_denied",not c.binding.construction_members_allowed(disjoint))
	var collider: CollisionShape3D = CollisionShape3D.new()
	collider.name = "PlayerCollider"
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.42
	capsule.height = 1.72
	collider.shape = capsule
	collider.position.y = 0.86
	player.add_child(collider)
	check("active_gap_between_members_remains_clear",_compare_members(c,"disjoint_gap",disjoint))
	check("enclosing_rectangle_would_incorrectly_block_gap",not c.binding.construction_allowed(_member_cells(disjoint[0].merge(disjoint[1]),c.main.CELL)))
	check("member_under_actor_denied",not _compare_members(c,"intersecting_member",[disjoint[0],local,disjoint[1]]))
	check("above_actor_keeps_existing_xz_footprint_rule",not _compare_members(c,"vertical_member",[AABB(Vector3(-1,100,-1),Vector3(2,2,2))]))
	check("sample_node_rounding_keeps_inclusive_edge",not _compare_members(c,"sample_edge",[AABB(Vector3(1.36,0,-0.1),Vector3(0.01,1,0.2))]))
	_compare_members(c,"negative_boundary",[AABB(Vector3(-2.8,0,-0.1),Vector3(0.1,1,0.2))])
	var many: Array = []
	for i: int in range(128): many.append(AABB(Vector3(50+i*4,0,-1),Vector3.ONE))
	check("large_clear_batch_still_one_validation",_compare_members(c,"many_members",many))
	check("empty_collision_obligations_allowed_after_actor_validation",_compare_members(c,"empty_valid",[]))
	player.position.x = 20.0*c.main.CELL
	check("outside_actor_allows_local_members",_compare_members(c,"outside",[local]))
	collider.position.x = -player.position.x
	check("batch_uses_collider_offset_center",not _compare_members(c,"offset",[local]))
	collider.position.x = 0.0
	player.position.x = -20.0*c.main.CELL
	check("negative_actor_allows_local_members",_compare_members(c,"negative_actor",[local]))
	player.position.x = 4.0*c.main.CELL
	check("batch_unscaled_outside",_compare_members(c,"unscaled",[local]))
	collider.scale = Vector3(8,1,2)
	check("batch_actual_scaled_radius_blocks",not _compare_members(c,"scaled",[local]))
	collider.rotation.y = PI*0.5
	check("batch_rotated_xz_scale_preserved",_compare_members(c,"rotated_scale",[local]))
	collider.scale = Vector3.ONE
	collider.rotation = Vector3.ZERO
	player.position = Vector3.ZERO
	player.set_physics_process(false)
	check("disabled_without_loading_keeps_overlap_denied",not _compare_members(c,"disabled_no_loading",[local]))
	c.main.startup_loading_active = true
	check("disabled_startup_loading_exception_preserved",_compare_members(c,"disabled_startup",[local]))
	c.main.startup_loading_active = false
	c.main.runtime_loading_active = true
	check("disabled_runtime_loading_exception_preserved",_compare_members(c,"disabled_runtime",[local]))
	player.set_physics_process(true)
	check("active_runtime_loading_still_protected",not _compare_members(c,"active_runtime_loading",[local]))
	c.main.runtime_loading_active = false
	c.main.startup_loading_active = true
	check("active_startup_loading_still_protected",not _compare_members(c,"active_startup_loading",[local]))
	player.set_physics_process(false)
	for value: Variant in [Rect2i(0,0,1,1),null,AABB(),AABB(Vector3.ZERO,Vector3(-1,1,1)),
		AABB(Vector3.ZERO,Vector3(1,0,1)),AABB(Vector3(INF,0,0),Vector3.ONE)]:
		check("malformed_member_loading_denied_"+str(checks.size()),not c.binding.construction_members_allowed([disjoint[0],value]))
	c.main.startup_loading_active = false
	collider.shape = BoxShape3D.new()
	check("batch_requires_actual_capsule",not c.binding.construction_members_allowed(disjoint))
	c.main.runtime_loading_active = true
	check("loading_still_requires_actual_capsule",not c.binding.construction_members_allowed(disjoint))
	collider.shape = capsule
	collider.rotation.x = 0.3
	check("batch_tilt_rejected_even_loading",not c.binding.construction_members_allowed(disjoint))
	collider.rotation = Vector3.ZERO
	var smart = c.autonomy.smart_objects
	c.autonomy.smart_objects = Smart.new()
	c.binding.clear_counts()
	check("batch_registry_replacement_rejected_before_actor_read",not c.binding.construction_members_allowed(disjoint)
		and c.binding.owner_reads==1 and c.binding.player_reads==0)
	c.autonomy.smart_objects = smart
	check("legacy_empty_rectangle_still_denied_in_loading",not c.binding.construction_allowed(Rect2i()))
	close(c,"construction_members")
	await process_frame
	var report: Dictionary = {"schema":"generated-structure-construction-members-contract/v1","complete":true,"passed":not checks.values().has(false),
		"checks":checks,"scope":"Synthetic actual capsule and runtime-owner binding; batch equivalence to public Rect2i guards, independent member footprints and one validation. No gameplay, geometry publication or final loading clearance."}
	var file: FileAccess = FileAccess.open(OS.get_environment("CONSTRUCTION_MEMBERS_REPORT"),FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("CONSTRUCTION MEMBERS COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
