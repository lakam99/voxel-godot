extends SceneTree
## Physics/publication contract; not live player input or gate traversal proof.
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Geometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
var checks: Dictionary={}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var publisher := Publisher.new()
	for index in range(2):
		var part := Part.new({"id":"gate_%d"%index,"kind":"door","material":"ironwork","size":Vector3(5+index,5,0.18),
			"position":Vector3(index*20,3,0),"rotation":Vector3(0,index*0.7,0),"recipe":{"doorPresentation":"portcullis","doorMotion":"raise"}})
		var before := var_to_bytes(part.snapshot())
		var door: StaticBody3D=publisher.publish_part(part,world)
		var area: Area3D=door.get_node("DoorInteraction")
		checks["same_owner_%d"%index]=area.get_meta("interaction_parent")==door
		checks["ray_only_%d"%index]=area.collision_mask==0 and not area.monitoring and area.get_child_count()==4
		var geometry := Geometry.describe_portcullis(part.size)
		var target: Vector3=geometry.leverPosition+Basis.from_euler(geometry.leverRotation)*geometry.handle.position
		for open_state in [false,true]:
			# Simulate only the existing controller's leaf transform/collider state.
			# This is not evidence of a door command being accepted.
			door.get_node("DoorPivot").position=Geometry.raised_visual_offset(part.size) if open_state else Vector3.ZERO
			for child in door.get_children():
				if child is CollisionShape3D: child.disabled=open_state
			await physics_frame
			await physics_frame
			var query := PhysicsRayQueryParameters3D.create(door.to_global(target+Vector3(0,0,-1)),door.to_global(target+Vector3(0,0,0.1)))
			query.collide_with_areas=true
			query.collide_with_bodies=true
			var hit := world.get_world_3d().direct_space_state.intersect_ray(query)
			checks["lever_ray_%d_%s"%[index,str(open_state)]]=hit.get("collider")==area
		checks["source_unchanged_%d"%index]=before==var_to_bytes(part.snapshot())
	var ordinary := Part.new({"id":"ordinary","kind":"door","size":Vector3(1,2,0.2),"position":Vector3(40,0,0)})
	var normal: StaticBody3D=publisher.publish_part(ordinary,world)
	checks.ordinary_proxy_unchanged=normal.get_node("DoorInteraction").get_child_count()==1
	world.free()
	publisher.published_nodes.clear()
	var passed := not checks.values().has(false)
	var file := FileAccess.open(OS.get_environment("PORTCULLIS_LEVER_REPORT"),FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify({"passed":passed,"checks":checks,"scope":"Physics ray/publication contract; not live input, gate commands or traversal acceptance."},"\t"))
	file.close()
	quit(0 if passed else 1)
