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
		"bench":
			publish_bench(part, parent)
		"sideboard":
			publish_sideboard(part, parent)
		"lectern":
			publish_lectern(part, parent)
		"map_table":
			publish_map_table(part, parent)
		"workbench":
			publish_workbench(part, parent)
		"crate_stack":
			publish_crate_stack(part, parent)
		"barrel_stack":
			publish_barrel_stack(part, parent)
		"display_plinth":
			publish_display_plinth(part, parent)
		"dais":
			publish_dais(part, parent)
		"coat_rack":
			publish_coat_rack(part, parent)
		"planter":
			publish_planter(part, parent)
		"wall_sconce":
			publish_wall_sconce(part, parent)
		"wall_banner":
			publish_wall_banner(part, parent)
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
	var width: float = float(part.occupied_size.x)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, 0.14, depth), Vector3(0.0, 0.78, 0.0), material_for("timber_board", part), "TableTop")
	for x in [-maxf(0.16, width * 0.5 - 0.17), maxf(0.16, width * 0.5 - 0.17)]:
		for z in [-maxf(0.14, depth * 0.5 - 0.16), maxf(0.14, depth * 0.5 - 0.16)]:
			add_box(parent, Vector3(0.13, 0.76, 0.13), Vector3(float(x), 0.38, float(z)), material_for("timber_beam", part), "TableLeg")
	add_box(parent, Vector3(maxf(0.32, width - 0.24), 0.10, 0.11), Vector3(0.0, 0.37, 0.0), material_for("timber_beam", part), "TableStretcher")


func publish_bench(part, parent: Node3D) -> void:
	var width: float = float(part.occupied_size.x)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, 0.12, depth), Vector3(0.0, 0.50, 0.0), material_for("timber_board", part), "BenchSeat")
	for x in [-maxf(0.18, width * 0.5 - 0.18), maxf(0.18, width * 0.5 - 0.18)]:
		add_box(parent, Vector3(0.13, 0.52, 0.13), Vector3(float(x), 0.26, 0.0), material_for("timber_beam", part), "BenchLeg")
	add_box(parent, Vector3(maxf(0.32, width - 0.22), 0.09, 0.10), Vector3(0.0, 0.26, 0.0), material_for("timber_beam", part), "BenchStretcher")


func publish_sideboard(part, parent: Node3D) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, height * 0.78, depth), Vector3(0.0, height * 0.39, 0.0), material_for(part.material_id, part), "SideboardBody")
	add_box(parent, Vector3(width * 0.90, height * 0.19, 0.05), Vector3(0.0, height * 0.55, -depth * 0.53), material_for("timber_board", part), "SideboardDrawer")
	add_box(parent, Vector3(width * 1.06, 0.10, depth * 1.12), Vector3(0.0, height * 0.82, 0.0), material_for("timber_beam", part), "SideboardTop")
	for x in [-width * 0.25, width * 0.25]:
		add_sphere(parent, 0.055, Vector3(float(x), height * 0.54, -depth * 0.57), material_for("brass", part), "SideboardPull")


func publish_lectern(part, parent: Node3D) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	add_box(parent, Vector3(width * 0.86, 0.12, 0.50), Vector3(0.0, height * 0.87, -0.05), material_for("timber_board", part), "LecternTop", Vector3(deg_to_rad(-22.0), 0.0, 0.0))
	add_box(parent, Vector3(0.22, height * 0.74, 0.22), Vector3(0.0, height * 0.40, 0.0), material_for("timber_beam", part), "LecternStem")
	add_box(parent, Vector3(width, 0.12, 0.54), Vector3(0.0, 0.06, 0.0), material_for("timber_beam", part), "LecternBase")
	add_box(parent, Vector3(width * 0.62, 0.02, 0.34), Vector3(0.0, height * 0.92, -0.10), material_for("linen", part), "LecternBook")


func publish_map_table(part, parent: Node3D) -> void:
	publish_table(part, parent)
	var width: float = float(part.occupied_size.x)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width * 0.78, 0.018, depth * 0.68), Vector3(0.0, 0.858, 0.0), material_for("linen", part), "MapSheet")
	add_sphere(parent, 0.07, Vector3(width * 0.29, 0.90, -depth * 0.22), material_for("brass", part), "MapCompass")


func publish_workbench(part, parent: Node3D) -> void:
	publish_table(part, parent)
	var width: float = float(part.occupied_size.x)
	add_box(parent, Vector3(width * 0.20, 0.10, 0.16), Vector3(-width * 0.23, 0.89, -0.10), material_for("brass", part), "WorkbenchPlane")
	add_box(parent, Vector3(width * 0.16, 0.14, 0.12), Vector3(width * 0.17, 0.91, 0.12), material_for("timber_beam", part), "WorkbenchToolBlock")


func publish_crate_stack(part, parent: Node3D) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, height * 0.52, depth), Vector3(0.0, height * 0.26, 0.0), material_for("timber_board", part), "CrateLower")
	add_box(parent, Vector3(width * 0.76, height * 0.42, depth * 0.78), Vector3(-width * 0.08, height * 0.73, depth * 0.06), material_for("timber_beam", part), "CrateUpper")


func publish_barrel_stack(part, parent: Node3D) -> void:
	var radius := float(part.occupied_size.x) * 0.29
	add_cylinder(parent, radius, float(part.occupied_size.y) * 0.54, Vector3(-radius * 0.56, float(part.occupied_size.y) * 0.27, 0.0), material_for("timber_board", part), "BarrelLower")
	add_cylinder(parent, radius * 0.84, float(part.occupied_size.y) * 0.42, Vector3(radius * 0.30, float(part.occupied_size.y) * 0.70, 0.04), material_for("timber_beam", part), "BarrelUpper")


func publish_display_plinth(part, parent: Node3D) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	add_box(parent, Vector3(width, height * 0.18, width), Vector3(0.0, height * 0.09, 0.0), material_for("stone_foundation", part), "PlinthBase")
	add_box(parent, Vector3(width * 0.54, height * 0.72, width * 0.54), Vector3(0.0, height * 0.50, 0.0), material_for(part.material_id, part), "PlinthColumn")
	add_sphere(parent, width * 0.24, Vector3(0.0, height * 0.95, 0.0), material_for("brass", part), "PlinthCivicSeal", Vector3(1.0, 0.38, 1.0))


func publish_dais(part, parent: Node3D) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, height * 0.68, depth), Vector3(0.0, height * 0.34, 0.0), material_for(part.material_id, part), "DaisBody")
	add_box(parent, Vector3(width * 1.06, 0.12, depth * 1.10), Vector3(0.0, height * 0.72, 0.0), material_for("timber_board", part), "DaisTop")
	add_box(parent, Vector3(width * 0.42, height * 0.22, 0.34), Vector3(0.0, height * 0.15, -depth * 0.58), material_for("timber_beam", part), "DaisStep")


func publish_coat_rack(part, parent: Node3D) -> void:
	var height: float = float(part.occupied_size.y)
	add_cylinder(parent, 0.08, height * 0.86, Vector3(0.0, height * 0.43, 0.0), material_for(part.material_id, part), "CoatRackStem")
	add_cylinder(parent, 0.22, 0.08, Vector3(0.0, 0.04, 0.0), material_for("timber_board", part), "CoatRackBase")
	for angle in [0.0, PI * 0.5, PI, PI * 1.5]:
		add_box(parent, Vector3(0.28, 0.07, 0.07), Vector3(cos(angle) * 0.12, height * 0.78, sin(angle) * 0.12), material_for("timber_beam", part), "CoatRackHook", Vector3(0.0, angle, 0.0))


func publish_planter(part, parent: Node3D) -> void:
	var height: float = float(part.occupied_size.y)
	add_cylinder(parent, float(part.occupied_size.x) * 0.35, height * 0.46, Vector3(0.0, height * 0.23, 0.0), material_for(part.material_id, part), "PlanterPot")
	for angle in [0.0, 1.57, 3.14, 4.71]:
		var leaf := MeshInstance3D.new()
		leaf.name = "PlanterLeaf"
		leaf.mesh = unit_sphere
		leaf.scale = Vector3(0.16, 0.44, 0.09)
		leaf.position = Vector3(cos(angle) * 0.14, height * 0.72, sin(angle) * 0.14)
		leaf.rotation = Vector3(sin(angle) * 0.38, 0.0, -cos(angle) * 0.50)
		leaf.material_override = material_for("wool_moss", part)
		leaf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		parent.add_child(leaf)
		visual_piece_count += 1


func publish_wall_sconce(part, parent: Node3D) -> void:
	var mount_height := float(part.recipe.get("mountHeight", 2.12))
	add_box(parent, Vector3(0.12, 0.25, 0.14), Vector3(0.0, mount_height, -0.05), material_for("brass", part), "SconceArm")
	add_cylinder(parent, 0.07, 0.24, Vector3(0.0, mount_height + 0.12, -0.12), material_for("candle_wax", part), "SconceWax")
	add_sphere(parent, 0.065, Vector3(0.0, mount_height + 0.29, -0.12), material_for("candle_flame", part), "SconceFlame", Vector3(0.58, 1.28, 0.58))


func publish_wall_banner(part, parent: Node3D) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var mount_height := float(part.recipe.get("mountHeight", 2.54))
	add_box(parent, Vector3(width * 1.18, 0.07, 0.10), Vector3(0.0, mount_height + height * 0.54, -0.02), material_for("timber_beam", part), "BannerTopRail")
	add_box(parent, Vector3(width * 1.18, 0.07, 0.10), Vector3(0.0, mount_height - height * 0.54, -0.02), material_for("timber_beam", part), "BannerBottomRail")
	add_box(parent, Vector3(width, height, 0.045), Vector3(0.0, mount_height, -0.07), material_for(part.material_id, part), "BannerCloth")
	add_sphere(parent, width * 0.16, Vector3(0.0, mount_height + height * 0.06, -0.115), material_for("brass", part), "BannerSeal", Vector3(1.0, 0.72, 0.20))


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


func add_box(parent: Node3D, size: Vector3, position: Vector3, material: Material, node_name: String, rotation := Vector3.ZERO) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = unit_box
	mesh.scale = size
	mesh.position = position
	mesh.rotation = rotation
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
