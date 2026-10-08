extends SceneTree

## Producer + published-physics contract for player-sized standing capsules at
## switchback landings. No world streaming, route, NPC, or traversal claim.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var output := OS.get_environment("CITADEL_STAIR_CAPSULE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):
		quit(2)
		return
	var blueprint = Blueprint.new("keep_stair_capsule",1,"stone")
	# Exact current keep-stair scale/location from the failing generated candidate:
	# its stairwell depth is clipped by the palace floor plan, unlike the older
	# spacious standalone fixture.
	Castle.add_switchback_stair_flights(blueprint,"castle_keep_stair",Vector3(18.89,0.0,31.0605),4.3,3.943,0.82,3.7666667,2,"stone_foundation",0.0,"castle_keep_stair")
	var before := var_to_bytes(blueprint.snapshot())
	var by_id := {}
	for part in blueprint.parts: by_id[String(part.id)]=part
	var world := Node3D.new()
	# Reproduce the kilometre-scale transform from the failing live candidate;
	# origin-local probes do not exercise the same float32 contact tolerance.
	world.position=Vector3(-1291.95,39.15,1063.8)
	root.add_child(world)
	var publisher := Publisher.new()
	for part in blueprint.parts: publisher.publish_part(part,world)
	await physics_frame
	await physics_frame
	var capsule := CapsuleShape3D.new()
	capsule.radius=0.42
	capsule.height=1.72
	var observations := []
	var adjacent_count := 0
	var blockers := []
	var probe_surface = null
	for part in blueprint.parts:
		if part.semantic not in ["castle_keep_stair_landing","castle_keep_stair_exit"]: continue
		if probe_surface==null: probe_surface=part
		var lateral: float = (part.size.x+0.18)*0.20
		for offset: float in [-lateral,0.0,lateral]:
			var expected: Vector3 = world.global_transform*(part.position+Vector3(offset,part.size.y*0.5,0.0))
			var space := world.get_world_3d().direct_space_state
			var support := space.intersect_ray(PhysicsRayQueryParameters3D.create(expected+Vector3.UP*0.24,expected-Vector3.UP*0.24))
			var row_blockers := []
			var adjacent := []
			if support.is_empty():
				row_blockers.append("missing_walkable_support")
			else:
				var query := PhysicsShapeQueryParameters3D.new()
				query.shape=capsule
				var slope_lift := capsule.radius*(1.0/maxf(float(support.normal.y),0.01)-1.0)
				query.transform=Transform3D(Basis.IDENTITY,support.position+Vector3.UP*(capsule.height*0.5+slope_lift+0.02))
				for hit: Dictionary in space.intersect_shape(query,32):
					var collider: CollisionObject3D=hit.collider
					var owner: Object=collider.shape_owner_get_owner(collider.shape_find_owner(hit.shape))
					var id := String(owner.get_meta("building_part_id","unknown")) if owner!=null else "unknown"
					if Castle.stair_transition_connects_support(by_id.get(id),String(part.id)):
						adjacent.append(id)
						adjacent_count+=1
					else: row_blockers.append(id)
			blockers.append_array(row_blockers)
			observations.append({"supportId":part.id,"offset":offset,"adjacentSurfaces":adjacent,"blockers":row_blockers})
	var positive_source_unchanged := before==var_to_bytes(blueprint.snapshot())
	var negative_control := false
	if probe_surface!=null:
		var fake = blueprint.add_part({"id":"unrelated_capsule_blocker","kind":"wall","material":"stone_foundation",
			"position":probe_surface.position+Vector3(0.0,0.70,0.0),"size":Vector3(0.30,1.20,0.30),"collision":true,"semantic":"negative_control"})
		publisher.publish_part(fake,world)
		await physics_frame
		var expected: Vector3 = world.global_transform*(probe_surface.position+Vector3(0.0,probe_surface.size.y*0.5,0.0))
		var support := world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(expected+Vector3.UP*0.24,expected-Vector3.UP*0.24))
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape=capsule
		query.transform=Transform3D(Basis.IDENTITY,support.position+Vector3.UP*(capsule.height*0.5+0.02))
		for hit: Dictionary in world.get_world_3d().direct_space_state.intersect_shape(query,32):
			var collider: CollisionObject3D=hit.collider
			var owner: Object=collider.shape_owner_get_owner(collider.shape_find_owner(hit.shape))
			var id := String(owner.get_meta("building_part_id","unknown")) if owner!=null else "unknown"
			if id==fake.id and not Castle.stair_transition_connects_support(fake,String(probe_surface.id)):
				negative_control=true
	var checks := {"all_landings_clear_except_declared_adjacent_carriages":blockers.is_empty(),
		"wide_keep_exercises_adjacent_carriage_contact":adjacent_count>0,
		"unrelated_capsule_blocker_is_rejected":negative_control,
		"source_unchanged_by_positive_probe":positive_source_unchanged}
	var passed := checks.values().all(func(value):return bool(value))
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify({"passed":passed,"checks":checks,"observations":observations,"adjacentContactCount":adjacent_count,
		"scope":"Generated keep stair and published collision with player-sized capsule; no streaming, route, NPC, or traversal acceptance."},"\t"))
	file.close()
	world.free()
	publisher.clear_published_node_roster()
	quit(0 if passed else 1)
