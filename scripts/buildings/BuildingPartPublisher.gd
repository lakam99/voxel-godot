extends RefCounted
class_name BuildingPartPublisher

## Scene publication for material-aware construction parts. It intentionally
## consumes only BuildingPart data: the visual recipe and collision shape share
## one record, and board/brick detail is instanced per parent part.

const ConstructionMaterialCatalogScript := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")

var unit_box: BoxMesh
var material_cache: Dictionary = {}
var published_parts: Array = []
var collision_count := 0
var visual_batch_count := 0
var recipe_build_usec := 0
var publication_usec := 0
var source_blueprint_id := ""


func _init() -> void:
	unit_box = BoxMesh.new()
	unit_box.size = Vector3.ONE


func publish(blueprint, parent: Node3D) -> Dictionary:
	clear_published()
	if blueprint == null or parent == null:
		return summary()
	source_blueprint_id = String(blueprint.id)
	var started := Time.get_ticks_usec()
	for part in blueprint.parts:
		if part == null:
			continue
		publish_part(part, parent)
	publication_usec = Time.get_ticks_usec() - started
	return summary()


func publish_incremental(blueprint, parent: Node3D, parts_per_frame := 6) -> Dictionary:
	# Uses the same part records and publish_part path as synchronous publication.
	# Consumers with an on-screen loading state can spread a larger blueprint over
	# frames without inventing a second visual/collision publication authority.
	clear_published()
	if blueprint == null or parent == null:
		return summary()
	source_blueprint_id = String(blueprint.id)
	var started := Time.get_ticks_usec()
	var frame_budget := maxi(1, parts_per_frame)
	var published_this_frame := 0
	for part in blueprint.parts:
		if part == null:
			continue
		publish_part(part, parent)
		published_this_frame += 1
		if published_this_frame >= frame_budget:
			published_this_frame = 0
			await parent.get_tree().process_frame
	publication_usec = Time.get_ticks_usec() - started
	return summary()


func clear_published() -> void:
	for node in published_parts:
		if node != null and is_instance_valid(node):
			node.queue_free()
	published_parts.clear()
	collision_count = 0
	visual_batch_count = 0
	recipe_build_usec = 0
	publication_usec = 0
	source_blueprint_id = ""


func publish_part(part, parent: Node3D) -> StaticBody3D:
	var started := Time.get_ticks_usec()
	var body := StaticBody3D.new()
	body.name = "ConstructionPart_%s" % String(part.id)
	body.position = part.position
	body.rotation = part.rotation
	body.set_meta("building_part_id", part.id)
	body.set_meta("building_part_kind", part.kind)
	body.set_meta("building_material", part.material_id)
	body.set_meta("building_semantic", part.semantic)
	body.set_meta("building_part_record", part.snapshot())
	if String(part.kind) == "door":
		configure_door_leaf(body, part)
	parent.add_child(body)
	published_parts.append(body)
	if part.collision_enabled:
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = part.size
		collision.shape = shape
		body.add_child(collision)
		collision_count += 1
	publish_visual(part, body)
	if String(part.kind) == "door":
		add_door_interaction_proxy(body, part.size)
	recipe_build_usec += Time.get_ticks_usec() - started
	return body


func publish_visual(part, parent: Node3D) -> void:
	match String(part.kind):
		"wall":
			if String(part.material_id) == "fired_brick":
				publish_brick_wall(part, parent)
			else:
				publish_timber_wall(part, parent)
		"floor":
			publish_board_floor(part, parent)
		"roof":
			publish_roof_shingles(part, parent)
		"door":
			publish_door_boards(part, parent)
		"window":
			publish_window(part, parent)
		_:
			add_box_visual(parent, part.size, Vector3.ZERO, material_for(part), "Visual_%s" % part.kind)


func publish_timber_wall(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var row_height := 0.34
	var rows := maxi(1, ceili(size.y / row_height))
	var transforms: Array[Transform3D] = []
	var axis_x := size.x >= size.z
	for row in range(rows):
		var height := size.y / float(rows)
		var board_size := Vector3(size.x, maxf(0.04, height - 0.026), size.z) if axis_x else Vector3(size.x, maxf(0.04, height - 0.026), size.z)
		var y := -size.y * 0.5 + height * (float(row) + 0.5)
		transforms.append(box_transform(Vector3(0.0, y, 0.0), board_size))
	add_box_batch(parent, transforms, material_for(part), "PlankCladding")


func publish_brick_wall(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var axis_x := size.x >= size.z
	var length := size.x if axis_x else size.z
	var brick_length := 0.62
	var brick_height := 0.255
	var rows := maxi(1, ceili(size.y / brick_height))
	var transforms: Array[Transform3D] = []
	# Mortar is published by the same part record, behind the physical brick
	# instances. Its thin axis is inset on both faces, so it cannot z-fight with
	# a brick surface while course gaps remain a material fact rather than a
	# texture.
	var mortar_size := size
	if axis_x:
		mortar_size.z = maxf(0.02, size.z - 0.036)
	else:
		mortar_size.x = maxf(0.02, size.x - 0.036)
	add_box_visual(parent, mortar_size, Vector3.ZERO, material_for_id("mortar", variation_for(part)), "MortarBed")
	for row in range(rows):
		var actual_height := size.y / float(rows)
		var offset := brick_length * 0.5 if row % 2 == 1 else 0.0
		var count := ceili((length + offset) / brick_length) + 1
		for column in range(count):
			var along := -length * 0.5 + brick_length * 0.5 + float(column) * brick_length - offset
			if along - brick_length * 0.5 < -length * 0.5 or along + brick_length * 0.5 > length * 0.5:
				continue
			var brick_size := Vector3(brick_length - 0.032, maxf(0.04, actual_height - 0.026), size.z) if axis_x else Vector3(size.x, maxf(0.04, actual_height - 0.026), brick_length - 0.032)
			var position := Vector3(along, -size.y * 0.5 + actual_height * (float(row) + 0.5), 0.0) if axis_x else Vector3(0.0, -size.y * 0.5 + actual_height * (float(row) + 0.5), along)
			transforms.append(box_transform(position, brick_size))
	add_box_batch(parent, transforms, material_for(part), "BrickCourses")


func publish_board_floor(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var board_width := 0.36
	var count := maxi(1, ceili(size.x / board_width))
	var transforms: Array[Transform3D] = []
	for index in range(count):
		var width := size.x / float(count)
		transforms.append(box_transform(Vector3(-size.x * 0.5 + width * (float(index) + 0.5), 0.0, 0.0), Vector3(maxf(0.04, width - 0.024), size.y, size.z)))
	add_box_batch(parent, transforms, material_for(part), "FloorBoards")


func publish_roof_shingles(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var shingle_width := 0.43
	var count := maxi(1, ceili(size.x / shingle_width))
	var transforms: Array[Transform3D] = []
	for index in range(count):
		var width := size.x / float(count)
		transforms.append(box_transform(Vector3(-size.x * 0.5 + width * (float(index) + 0.5), 0.0, 0.0), Vector3(maxf(0.04, width - 0.020), size.y, size.z)))
	add_box_batch(parent, transforms, material_for(part), "RoofShingles")


func publish_door_boards(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	pivot.position = Vector3(-size.x * 0.5, 0.0, 0.0)
	parent.add_child(pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	leaf.position = Vector3(size.x * 0.5, 0.0, 0.0)
	pivot.add_child(leaf)
	var count := 5
	var transforms: Array[Transform3D] = []
	for index in range(count):
		var width := size.x / float(count)
		transforms.append(box_transform(Vector3(-size.x * 0.5 + width * (float(index) + 0.5), 0.0, 0.0), Vector3(maxf(0.04, width - 0.018), size.y, size.z)))
	add_box_batch(leaf, transforms, material_for(part), "DoorBoards")
	# The frame, brace and handle belong to the same semantic door part; they make
	# the opening readable without creating a second collision authority.
	add_box_visual(leaf, Vector3(size.x * 0.86, 0.10, size.z * 1.22), Vector3(0.0, -size.y * 0.10, size.z * 0.40), material_for_id("timber_beam", variation_for(part)), "DoorBrace")
	var frame_material := material_for_id("timber_beam", variation_for(part))
	add_box_visual(parent, Vector3(0.14, size.y * 1.12, size.z * 1.55), Vector3(-size.x * 0.58, 0.0, 0.0), frame_material, "DoorFrameLeft")
	add_box_visual(parent, Vector3(0.14, size.y * 1.12, size.z * 1.55), Vector3(size.x * 0.58, 0.0, 0.0), frame_material, "DoorFrameRight")
	add_box_visual(parent, Vector3(size.x * 1.28, 0.14, size.z * 1.55), Vector3(0.0, size.y * 0.56, 0.0), frame_material, "DoorFrameTop")
	add_box_visual(leaf, Vector3(0.105, 0.105, 0.090), Vector3(size.x * 0.27, -0.04, -size.z * 0.70), material_for_id("brass", variation_for(part)), "DoorHandle")


func configure_door_leaf(body: StaticBody3D, part) -> void:
	# Match the established DoorPortal/DoorController leaf contract. The generic
	# controller owns swing state and collider disabling; this publisher only
	# provides a building-derived door leaf for it to operate on.
	var portal_id := "building:%s:%s" % [source_blueprint_id, String(part.id)]
	body.set_meta("block_type", "door")
	body.set_meta("open", false)
	body.set_meta("closed_rotation", body.rotation.y)
	body.set_meta("open_swing", -PI * 0.5)
	body.set_meta("door_portal_id", portal_id)
	body.set_meta("door_group_id", portal_id)
	body.set_meta("door_building_id", source_blueprint_id)
	body.set_meta("door_side", 0)
	body.set_meta("door_public_access", true)
	body.set_meta("door_policy", "private_home")
	body.set_meta("locked", false)
	body.set_meta("jammed", false)
	body.set_meta("destroyed", false)
	body.set_meta("unloaded", false)


func add_door_interaction_proxy(door: StaticBody3D, size: Vector3) -> void:
	var area := Area3D.new()
	area.name = "DoorInteraction"
	area.collision_layer = 1 << 10
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	area.set_meta("interaction_parent", door)
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x * 1.22, size.y * 1.04, maxf(0.52, size.z * 3.0))
	var collider := CollisionShape3D.new()
	collider.shape = shape
	area.add_child(collider)
	door.add_child(area)


func publish_window(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	add_box_visual(parent, size, Vector3.ZERO, material_for(part), "WindowGlass")
	var trim := material_for_id("timber_beam", variation_for(part))
	if size.x < size.z:
		add_box_visual(parent, Vector3(size.x * 1.6, size.y * 1.16, 0.10), Vector3(0.0, 0.0, -size.z * 0.53), trim, "WindowFrameNear")
		add_box_visual(parent, Vector3(size.x * 1.6, size.y * 1.16, 0.10), Vector3(0.0, 0.0, size.z * 0.53), trim, "WindowFrameFar")
	else:
		add_box_visual(parent, Vector3(0.10, size.y * 1.16, size.z * 1.6), Vector3(-size.x * 0.53, 0.0, 0.0), trim, "WindowFrameNear")
		add_box_visual(parent, Vector3(0.10, size.y * 1.16, size.z * 1.6), Vector3(size.x * 0.53, 0.0, 0.0), trim, "WindowFrameFar")


func add_box_batch(parent: Node3D, transforms: Array, material: Material, node_name: String) -> void:
	if transforms.is_empty():
		return
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.instance_count = transforms.size()
	multi_mesh.mesh = unit_box
	for index in range(transforms.size()):
		multi_mesh.set_instance_transform(index, transforms[index] as Transform3D)
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multi_mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	visual_batch_count += 1


func add_box_visual(parent: Node3D, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
	var visual := MeshInstance3D.new()
	visual.name = node_name
	visual.mesh = unit_box
	visual.position = position
	visual.scale = size
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(visual)
	visual_batch_count += 1


func box_transform(position: Vector3, size: Vector3) -> Transform3D:
	return Transform3D(Basis.from_scale(size), position)


func variation_for(part) -> float:
	return float(part.recipe.get("variation", 0.0))


func material_for(part) -> Material:
	return material_for_id(String(part.material_id), variation_for(part))


func material_for_id(material_id: String, variation := 0.0) -> Material:
	var key := "%s:%0.3f" % [material_id, variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var material: Material = ConstructionMaterialCatalogScript.create_material(material_id, variation)
	material_cache[key] = material
	return material


func summary() -> Dictionary:
	return {
		"publishedPartCount": published_parts.size(),
		"collisionPartCount": collision_count,
		"visualBatchCount": visual_batch_count,
		"recipeBuildUsec": recipe_build_usec,
		"publicationUsec": publication_usec
	}
