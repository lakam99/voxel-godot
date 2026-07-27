extends RefCounted
class_name FurnishingPublisher

## Publishes one collision body per furnishing record. Fine visual pieces are
## intentionally children of that record: a chair's legs or a bed's pillows
## never become separate collision, save, or placement authorities.

const ConstructionMaterialCatalogScript := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")

var unit_box: BoxMesh
var unit_cylinder: CylinderMesh
var unit_sphere: SphereMesh
var material_cache: Dictionary = {}
var published_parts: Array = []
var collision_count := 0
var visual_piece_count := 0
var publication_usec := 0


func _init() -> void:
	unit_box = BoxMesh.new()
	unit_box.size = Vector3.ONE
	unit_cylinder = CylinderMesh.new()
	unit_cylinder.top_radius = 0.5
	unit_cylinder.bottom_radius = 0.5
	unit_cylinder.height = 1.0
	unit_cylinder.radial_segments = 8
	unit_sphere = SphereMesh.new()
	unit_sphere.radius = 0.5
	unit_sphere.height = 1.0
	unit_sphere.radial_segments = 8
	unit_sphere.rings = 4


func publish(plan, parent: Node3D) -> Dictionary:
	clear_published()
	if plan == null or parent == null:
		return summary()
	var started := Time.get_ticks_usec()
	for part in plan.parts:
		if part != null:
			publish_part(part, parent)
	publication_usec = Time.get_ticks_usec() - started
	return summary()


func publish_incremental(plan, parent: Node3D, parts_per_frame := 5) -> Dictionary:
	# Matches publish() exactly, but yields between bounded record batches. A
	# loading UI can therefore continue presenting frames while real furnishing
	# visuals and their collision bodies publish from the shared plan.
	clear_published()
	if plan == null or parent == null:
		return summary()
	var started := Time.get_ticks_usec()
	var frame_budget := maxi(1, parts_per_frame)
	var published_this_frame := 0
	for part in plan.parts:
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
	visual_piece_count = 0
	publication_usec = 0


func publish_part(part, parent: Node3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Furnishing_%s" % String(part.id)
	body.position = part.position
	body.rotation = part.rotation
	body.set_meta("furnishing_part_id", part.id)
	body.set_meta("furnishing_room_id", part.room_id)
	body.set_meta("furnishing_archetype", part.archetype)
	body.set_meta("furnishing_material", part.material_id)
	body.set_meta("furnishing_semantic", part.semantic)
	body.set_meta("furnishing_part_record", part.snapshot())
	parent.add_child(body)
	published_parts.append(body)
	if part.collision_enabled:
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = part.occupied_size
		collision.shape = shape
		collision.position = Vector3(0.0, part.occupied_size.y * 0.5, 0.0)
		body.add_child(collision)
		collision_count += 1
	publish_visual(part, body)
	return body


func publish_visual(part, parent: Node3D) -> void:
	match String(part.archetype):
		"bed":
			publish_bed(part, parent)
		"table":
			publish_table(part, parent)
		"chair":
			publish_chair(part, parent)
		"cabinet":
			publish_cabinet(part, parent)
		"hearth":
			publish_hearth(part, parent)
		"rug":
			publish_rug(part, parent)
		"shelf":
			publish_shelf(part, parent)
		"chest":
			publish_chest(part, parent)
		"candle":
			publish_candle(part, parent)
		"pot_plant":
			publish_pot_plant(part, parent)
		"wall_art":
			publish_wall_art(part, parent)
		_:
			add_box(parent, part.occupied_size, Vector3(0.0, part.occupied_size.y * 0.5, 0.0), material_for(part.material_id, part), "Visual")


func publish_bed(part, parent: Node3D) -> void:
	var blanket := String(part.recipe.get("blanket", "wool_rust"))
	add_box(parent, Vector3(2.22, 0.14, 1.26), Vector3(0.0, 0.30, 0.0), material_for("timber_beam", part), "BedFrame")
	for x in [-0.94, 0.94]:
		for z in [-0.50, 0.50]:
			add_box(parent, Vector3(0.13, 0.56, 0.13), Vector3(float(x), 0.28, float(z)), material_for("timber_beam", part), "BedLeg")
	add_box(parent, Vector3(0.16, 1.04, 1.34), Vector3(-1.02, 0.62, 0.0), material_for("timber_beam", part), "Headboard")
	add_box(parent, Vector3(2.04, 0.23, 1.12), Vector3(0.03, 0.51, 0.0), material_for("linen", part), "Mattress")
	add_box(parent, Vector3(1.16, 0.17, 1.14), Vector3(0.45, 0.67, 0.0), material_for(blanket, part), "Blanket")
	add_box(parent, Vector3(0.48, 0.12, 0.96), Vector3(-0.67, 0.69, 0.0), material_for("linen", part), "Pillow")


func publish_table(part, parent: Node3D) -> void:
	add_box(parent, Vector3(1.56, 0.14, 1.06), Vector3(0.0, 0.78, 0.0), material_for("timber_board", part), "TableTop")
	for x in [-0.60, 0.60]:
		for z in [-0.37, 0.37]:
			add_box(parent, Vector3(0.13, 0.76, 0.13), Vector3(float(x), 0.38, float(z)), material_for("timber_beam", part), "TableLeg")
	add_box(parent, Vector3(1.32, 0.10, 0.11), Vector3(0.0, 0.37, 0.0), material_for("timber_beam", part), "TableStretcher")


func publish_chair(part, parent: Node3D) -> void:
	add_box(parent, Vector3(0.56, 0.12, 0.56), Vector3(0.0, 0.49, 0.0), material_for("timber_board", part), "ChairSeat")
	for x in [-0.20, 0.20]:
		for z in [-0.20, 0.20]:
			add_box(parent, Vector3(0.10, 0.50, 0.10), Vector3(float(x), 0.25, float(z)), material_for("timber_beam", part), "ChairLeg")
	add_box(parent, Vector3(0.54, 0.48, 0.10), Vector3(0.0, 0.76, 0.23), material_for("timber_beam", part), "ChairBack")


func publish_cabinet(part, parent: Node3D) -> void:
	var height: float = float(part.occupied_size.y)
	var width: float = float(part.occupied_size.x)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, height, depth), Vector3(0.0, height * 0.5, 0.0), material_for(part.material_id, part), "CabinetBody")
	add_box(parent, Vector3(width * 0.88, height * 0.39, 0.055), Vector3(0.0, height * 0.59, -depth * 0.53), material_for("timber_board", part), "CabinetDoor")
	add_box(parent, Vector3(width * 0.92, 0.08, depth * 1.10), Vector3(0.0, height * 0.98, 0.0), material_for("timber_beam", part), "CabinetTop")
	add_sphere(parent, 0.07, Vector3(width * 0.22, height * 0.58, -depth * 0.58), material_for("brass", part), "CabinetPull")


func publish_hearth(part, parent: Node3D) -> void:
	add_box(parent, Vector3(1.68, 1.50, 0.64), Vector3(0.0, 0.75, 0.0), material_for("fired_brick", part), "HearthBody")
	add_box(parent, Vector3(0.92, 0.78, 0.075), Vector3(0.0, 0.72, -0.36), material_for("mortar", part), "Firebox")
	add_box(parent, Vector3(0.58, 0.20, 0.055), Vector3(0.0, 0.58, -0.41), material_for("candle_flame", part), "HearthGlow")
	add_box(parent, Vector3(1.98, 0.15, 0.78), Vector3(0.0, 1.52, 0.0), material_for("timber_beam", part), "HearthMantel")
	add_box(parent, Vector3(0.40, 0.38, 0.45), Vector3(0.0, 1.75, 0.04), material_for("fired_brick", part), "HearthChimney")


func publish_rug(part, parent: Node3D) -> void:
	add_box(parent, Vector3(part.occupied_size.x, 0.035, part.occupied_size.z), Vector3(0.0, 0.02, 0.0), material_for(part.material_id, part), "WovenRug")
	add_box(parent, Vector3(part.occupied_size.x * 0.86, 0.018, part.occupied_size.z * 0.82), Vector3(0.0, 0.048, 0.0), material_for("linen", part), "RugInlay")


func publish_shelf(part, parent: Node3D) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var depth: float = float(part.occupied_size.z)
	for x in [-width * 0.40, width * 0.40]:
		add_box(parent, Vector3(0.11, height, 0.11), Vector3(float(x), height * 0.5, 0.0), material_for("timber_beam", part), "ShelfPost")
	for y in [0.18, height * 0.52, height * 0.86]:
		add_box(parent, Vector3(width, 0.09, depth), Vector3(0.0, float(y), 0.0), material_for("timber_board", part), "ShelfBoard")
	for index in range(4):
		var book_material := "book_leather" if index % 2 == 0 else "painted_decor"
		add_box(parent, Vector3(0.10, 0.30 + 0.03 * index, depth * 0.48), Vector3(-width * 0.28 + index * 0.14, height * 0.70, -depth * 0.12), material_for(book_material, part), "ShelfBook")
	add_cylinder(parent, 0.12, 0.19, Vector3(width * 0.19, height * 0.72, 0.0), material_for("ceramic_glaze", part), "ShelfPot")


func publish_chest(part, parent: Node3D) -> void:
	add_box(parent, Vector3(0.96, 0.52, 0.58), Vector3(0.0, 0.26, 0.0), material_for("timber_board", part), "ChestBody")
	add_box(parent, Vector3(1.02, 0.16, 0.64), Vector3(0.0, 0.58, 0.0), material_for("timber_beam", part), "ChestLid")
	add_box(parent, Vector3(0.12, 0.14, 0.05), Vector3(0.0, 0.34, -0.32), material_for("brass", part), "ChestLatch")
	for x in [-0.33, 0.33]:
		add_box(parent, Vector3(0.08, 0.62, 0.66), Vector3(float(x), 0.31, 0.0), material_for("brass", part), "ChestBand")


func publish_candle(part, parent: Node3D) -> void:
	# A candle is one clean wax stem and flame. The old long holder cylinder made
	# a tabletop candle read as a duplicated lower half rather than a fixture.
	add_cylinder(parent, 0.078, 0.30, Vector3(0.0, 0.15, 0.0), material_for("candle_wax", part), "CandleWax")
	add_sphere(parent, 0.075, Vector3(0.0, 0.39, 0.0), material_for("candle_flame", part), "CandleFlame", Vector3(0.62, 1.34, 0.62))


func publish_pot_plant(part, parent: Node3D) -> void:
	add_cylinder(parent, 0.18, 0.30, Vector3(0.0, 0.15, 0.0), material_for("ceramic_glaze", part), "PlantPot")
	for angle in [0.0, 2.09, 4.18]:
		var leaf := MeshInstance3D.new()
		leaf.name = "PlantLeaf"
		leaf.mesh = unit_sphere
		leaf.scale = Vector3(0.16, 0.46, 0.08)
		leaf.position = Vector3(cos(angle) * 0.12, 0.48, sin(angle) * 0.12)
		leaf.rotation = Vector3(sin(angle) * 0.36, 0.0, -cos(angle) * 0.44)
		leaf.material_override = material_for("wool_moss", part)
		leaf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		parent.add_child(leaf)
		visual_piece_count += 1


func publish_wall_art(part, parent: Node3D) -> void:
	# The furnishing record owns the wall-facing yaw and mounts its local +Z
	# backing face on the declared wall surface. Local -Z remains the readable
	# painted face inside the room, without adding decor collision.
	var mount_height := float(part.recipe.get("mountHeight", 1.38))
	add_box(parent, Vector3(part.occupied_size.x * 1.14, part.occupied_size.y * 1.16, 0.08), Vector3(0.0, mount_height, 0.0), material_for("timber_beam", part), "ArtFrame")
	add_box(parent, Vector3(part.occupied_size.x, part.occupied_size.y, 0.045), Vector3(0.0, mount_height, -0.06), material_for("painted_decor", part), "ArtPanel")


func add_box(parent: Node3D, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = unit_box
	mesh.scale = size
	mesh.position = position
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mesh)
	visual_piece_count += 1


func add_cylinder(parent: Node3D, radius: float, height: float, position: Vector3, material: Material, node_name: String) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = unit_cylinder
	mesh.scale = Vector3(radius * 2.0, height, radius * 2.0)
	mesh.position = position
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mesh)
	visual_piece_count += 1


func add_sphere(parent: Node3D, radius: float, position: Vector3, material: Material, node_name: String, scale_multiplier := Vector3.ONE) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = unit_sphere
	mesh.scale = Vector3(radius * 2.0, radius * 2.0, radius * 2.0) * scale_multiplier
	mesh.position = position
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mesh)
	visual_piece_count += 1


func material_for(material_id: String, part) -> Material:
	var variation := float(part.recipe.get("variation", 0.0))
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
		"visualPieceCount": visual_piece_count,
		"publicationUsec": publication_usec
	}
