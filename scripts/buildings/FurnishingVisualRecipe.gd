extends RefCounted
class_name FurnishingVisualRecipe

## Value-only visual authority, shared by rendering and section support indexing.
static func build(source) -> Dictionary:
	var part = source
	if source is Dictionary:
		part = {"archetype":source.get("archetype",""),"occupied_size":source.get("occupiedSize",Vector3.ONE),
			"material_id":source.get("material","timber_board"),"recipe":source.get("recipe",{})}
	var result := {"schema":"furnishing-visual-recipe/v1","pieces":[],"lights":[]}
	publish_visual(part,result)
	var bounds := AABB()
	var initialized := false
	for piece: Dictionary in result.pieces:
		var support: AABB = piece.transform * AABB(Vector3.ONE * -0.5,Vector3.ONE)
		bounds = bounds.merge(support) if initialized else support
		initialized = true
	for light: Dictionary in result.lights:
		var extent := Vector3.ONE * float(light.range)
		var support := AABB(light.position - extent,extent * 2.0)
		bounds = bounds.merge(support) if initialized else support
		initialized = true
	result["visualSupportBounds"] = bounds
	for rows: Array in [result.pieces,result.lights]:
		for row: Dictionary in rows: row.make_read_only()
		rows.make_read_only()
	result.make_read_only()
	return result

static func publish_visual(part, parent: Dictionary) -> void:
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


static func publish_bed(part, parent: Dictionary) -> void:
	var blanket := String(part.recipe.get("blanket", "wool_rust"))
	add_box(parent, Vector3(2.22, 0.14, 1.26), Vector3(0.0, 0.30, 0.0), material_for("timber_beam", part), "BedFrame")
	for x in [-0.94, 0.94]:
		for z in [-0.50, 0.50]:
			add_box(parent, Vector3(0.13, 0.56, 0.13), Vector3(float(x), 0.28, float(z)), material_for("timber_beam", part), "BedLeg")
	add_box(parent, Vector3(0.16, 1.04, 1.34), Vector3(-1.02, 0.62, 0.0), material_for("timber_beam", part), "Headboard")
	add_box(parent, Vector3(2.04, 0.23, 1.12), Vector3(0.03, 0.51, 0.0), material_for("linen", part), "Mattress")
	add_box(parent, Vector3(1.16, 0.17, 1.14), Vector3(0.45, 0.67, 0.0), material_for(blanket, part), "Blanket")
	add_box(parent, Vector3(0.48, 0.12, 0.96), Vector3(-0.67, 0.69, 0.0), material_for("linen", part), "Pillow")


static func publish_table(part, parent: Dictionary) -> void:
	var width: float = float(part.occupied_size.x)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, 0.14, depth), Vector3(0.0, 0.78, 0.0), material_for("timber_board", part), "TableTop")
	for x in [-maxf(0.16, width * 0.5 - 0.17), maxf(0.16, width * 0.5 - 0.17)]:
		for z in [-maxf(0.14, depth * 0.5 - 0.16), maxf(0.14, depth * 0.5 - 0.16)]:
			add_box(parent, Vector3(0.13, 0.76, 0.13), Vector3(float(x), 0.38, float(z)), material_for("timber_beam", part), "TableLeg")
	add_box(parent, Vector3(maxf(0.32, width - 0.24), 0.10, 0.11), Vector3(0.0, 0.37, 0.0), material_for("timber_beam", part), "TableStretcher")


static func publish_bench(part, parent: Dictionary) -> void:
	var width: float = float(part.occupied_size.x)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, 0.12, depth), Vector3(0.0, 0.50, 0.0), material_for("timber_board", part), "BenchSeat")
	for x in [-maxf(0.18, width * 0.5 - 0.18), maxf(0.18, width * 0.5 - 0.18)]:
		add_box(parent, Vector3(0.13, 0.52, 0.13), Vector3(float(x), 0.26, 0.0), material_for("timber_beam", part), "BenchLeg")
	add_box(parent, Vector3(maxf(0.32, width - 0.22), 0.09, 0.10), Vector3(0.0, 0.26, 0.0), material_for("timber_beam", part), "BenchStretcher")


static func publish_sideboard(part, parent: Dictionary) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, height * 0.78, depth), Vector3(0.0, height * 0.39, 0.0), material_for(part.material_id, part), "SideboardBody")
	add_box(parent, Vector3(width * 0.90, height * 0.19, 0.05), Vector3(0.0, height * 0.55, -depth * 0.53), material_for("timber_board", part), "SideboardDrawer")
	add_box(parent, Vector3(width * 1.06, 0.10, depth * 1.12), Vector3(0.0, height * 0.82, 0.0), material_for("timber_beam", part), "SideboardTop")
	for x in [-width * 0.25, width * 0.25]:
		add_sphere(parent, 0.055, Vector3(float(x), height * 0.54, -depth * 0.57), material_for("brass", part), "SideboardPull")


static func publish_lectern(part, parent: Dictionary) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	add_box(parent, Vector3(width * 0.86, 0.12, 0.50), Vector3(0.0, height * 0.87, -0.05), material_for("timber_board", part), "LecternTop", Vector3(deg_to_rad(-22.0), 0.0, 0.0))
	add_box(parent, Vector3(0.22, height * 0.74, 0.22), Vector3(0.0, height * 0.40, 0.0), material_for("timber_beam", part), "LecternStem")
	add_box(parent, Vector3(width, 0.12, 0.54), Vector3(0.0, 0.06, 0.0), material_for("timber_beam", part), "LecternBase")
	add_box(parent, Vector3(width * 0.62, 0.02, 0.34), Vector3(0.0, height * 0.92, -0.10), material_for("linen", part), "LecternBook")


static func publish_map_table(part, parent: Dictionary) -> void:
	publish_table(part, parent)
	var width: float = float(part.occupied_size.x)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width * 0.78, 0.018, depth * 0.68), Vector3(0.0, 0.858, 0.0), material_for("linen", part), "MapSheet")
	add_sphere(parent, 0.07, Vector3(width * 0.29, 0.90, -depth * 0.22), material_for("brass", part), "MapCompass")


static func publish_workbench(part, parent: Dictionary) -> void:
	publish_table(part, parent)
	var width: float = float(part.occupied_size.x)
	add_box(parent, Vector3(width * 0.20, 0.10, 0.16), Vector3(-width * 0.23, 0.89, -0.10), material_for("brass", part), "WorkbenchPlane")
	add_box(parent, Vector3(width * 0.16, 0.14, 0.12), Vector3(width * 0.17, 0.91, 0.12), material_for("timber_beam", part), "WorkbenchToolBlock")


static func publish_crate_stack(part, parent: Dictionary) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, height * 0.52, depth), Vector3(0.0, height * 0.26, 0.0), material_for("timber_board", part), "CrateLower")
	add_box(parent, Vector3(width * 0.76, height * 0.42, depth * 0.78), Vector3(-width * 0.08, height * 0.73, depth * 0.06), material_for("timber_beam", part), "CrateUpper")


static func publish_barrel_stack(part, parent: Dictionary) -> void:
	var radius := float(part.occupied_size.x) * 0.29
	add_cylinder(parent, radius, float(part.occupied_size.y) * 0.54, Vector3(-radius * 0.56, float(part.occupied_size.y) * 0.27, 0.0), material_for("timber_board", part), "BarrelLower")
	add_cylinder(parent, radius * 0.84, float(part.occupied_size.y) * 0.42, Vector3(radius * 0.30, float(part.occupied_size.y) * 0.70, 0.04), material_for("timber_beam", part), "BarrelUpper")


static func publish_display_plinth(part, parent: Dictionary) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	add_box(parent, Vector3(width, height * 0.18, width), Vector3(0.0, height * 0.09, 0.0), material_for("stone_foundation", part), "PlinthBase")
	add_box(parent, Vector3(width * 0.54, height * 0.72, width * 0.54), Vector3(0.0, height * 0.50, 0.0), material_for(part.material_id, part), "PlinthColumn")
	add_sphere(parent, width * 0.24, Vector3(0.0, height * 0.95, 0.0), material_for("brass", part), "PlinthCivicSeal", Vector3(1.0, 0.38, 1.0))


static func publish_dais(part, parent: Dictionary) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, height * 0.68, depth), Vector3(0.0, height * 0.34, 0.0), material_for(part.material_id, part), "DaisBody")
	add_box(parent, Vector3(width * 1.06, 0.12, depth * 1.10), Vector3(0.0, height * 0.72, 0.0), material_for("timber_board", part), "DaisTop")
	add_box(parent, Vector3(width * 0.42, height * 0.22, 0.34), Vector3(0.0, height * 0.15, -depth * 0.58), material_for("timber_beam", part), "DaisStep")


static func publish_coat_rack(part, parent: Dictionary) -> void:
	var height: float = float(part.occupied_size.y)
	add_cylinder(parent, 0.08, height * 0.86, Vector3(0.0, height * 0.43, 0.0), material_for(part.material_id, part), "CoatRackStem")
	add_cylinder(parent, 0.22, 0.08, Vector3(0.0, 0.04, 0.0), material_for("timber_board", part), "CoatRackBase")
	for angle in [0.0, PI * 0.5, PI, PI * 1.5]:
		add_box(parent, Vector3(0.28, 0.07, 0.07), Vector3(cos(angle) * 0.12, height * 0.78, sin(angle) * 0.12), material_for("timber_beam", part), "CoatRackHook", Vector3(0.0, angle, 0.0))


static func publish_planter(part, parent: Dictionary) -> void:
	var height: float = float(part.occupied_size.y)
	add_cylinder(parent, float(part.occupied_size.x) * 0.35, height * 0.46, Vector3(0.0, height * 0.23, 0.0), material_for(part.material_id, part), "PlanterPot")
	for angle in [0.0, 1.57, 3.14, 4.71]:
		_append(parent, "sphere", Vector3(0.16, 0.44, 0.09), Vector3(cos(angle) * 0.14, height * 0.72, sin(angle) * 0.14), Vector3(sin(angle) * 0.38, 0.0, -cos(angle) * 0.50), material_for("wool_moss", part), "PlanterLeaf")


static func publish_wall_sconce(part, parent: Dictionary) -> void:
	var mount_height := float(part.recipe.get("mountHeight", 2.12))
	add_box(parent, Vector3(0.12, 0.25, 0.14), Vector3(0.0, mount_height, -0.05), material_for("brass", part), "SconceArm")
	add_cylinder(parent, 0.07, 0.24, Vector3(0.0, mount_height + 0.12, -0.12), material_for("candle_wax", part), "SconceWax")
	add_sphere(parent, 0.065, Vector3(0.0, mount_height + 0.29, -0.12), material_for("candle_flame", part), "SconceFlame", Vector3(0.58, 1.28, 0.58))


static func publish_wall_banner(part, parent: Dictionary) -> void:
	var width: float = float(part.occupied_size.x)
	var height: float = float(part.occupied_size.y)
	var mount_height := float(part.recipe.get("mountHeight", 2.54))
	add_box(parent, Vector3(width * 1.18, 0.07, 0.10), Vector3(0.0, mount_height + height * 0.54, -0.02), material_for("timber_beam", part), "BannerTopRail")
	add_box(parent, Vector3(width * 1.18, 0.07, 0.10), Vector3(0.0, mount_height - height * 0.54, -0.02), material_for("timber_beam", part), "BannerBottomRail")
	add_box(parent, Vector3(width, height, 0.045), Vector3(0.0, mount_height, -0.07), material_for(part.material_id, part), "BannerCloth")
	add_sphere(parent, width * 0.16, Vector3(0.0, mount_height + height * 0.06, -0.115), material_for("brass", part), "BannerSeal", Vector3(1.0, 0.72, 0.20))


static func publish_chair(part, parent: Dictionary) -> void:
	add_box(parent, Vector3(0.56, 0.12, 0.56), Vector3(0.0, 0.49, 0.0), material_for("timber_board", part), "ChairSeat")
	for x in [-0.20, 0.20]:
		for z in [-0.20, 0.20]:
			add_box(parent, Vector3(0.10, 0.50, 0.10), Vector3(float(x), 0.25, float(z)), material_for("timber_beam", part), "ChairLeg")
	add_box(parent, Vector3(0.54, 0.48, 0.10), Vector3(0.0, 0.76, 0.23), material_for("timber_beam", part), "ChairBack")


static func publish_cabinet(part, parent: Dictionary) -> void:
	var height: float = float(part.occupied_size.y)
	var width: float = float(part.occupied_size.x)
	var depth: float = float(part.occupied_size.z)
	add_box(parent, Vector3(width, height, depth), Vector3(0.0, height * 0.5, 0.0), material_for(part.material_id, part), "CabinetBody")
	add_box(parent, Vector3(width * 0.88, height * 0.39, 0.055), Vector3(0.0, height * 0.59, -depth * 0.53), material_for("timber_board", part), "CabinetDoor")
	add_box(parent, Vector3(width * 0.92, 0.08, depth * 1.10), Vector3(0.0, height * 0.98, 0.0), material_for("timber_beam", part), "CabinetTop")
	add_sphere(parent, 0.07, Vector3(width * 0.22, height * 0.58, -depth * 0.58), material_for("brass", part), "CabinetPull")


static func publish_hearth(part, parent: Dictionary) -> void:
	add_box(parent, Vector3(1.68, 1.50, 0.64), Vector3(0.0, 0.75, 0.0), material_for("fired_brick", part), "HearthBody")
	add_box(parent, Vector3(0.92, 0.78, 0.075), Vector3(0.0, 0.72, -0.36), material_for("mortar", part), "Firebox")
	add_box(parent, Vector3(0.58, 0.20, 0.055), Vector3(0.0, 0.58, -0.41), material_for("candle_flame", part), "HearthGlow")
	add_practical_light(parent, Vector3(0.0, 0.74, -0.26), Color(1.0, 0.42, 0.16), 1.65, 6.0)
	add_box(parent, Vector3(1.98, 0.15, 0.78), Vector3(0.0, 1.52, 0.0), material_for("timber_beam", part), "HearthMantel")
	add_box(parent, Vector3(0.40, 0.38, 0.45), Vector3(0.0, 1.75, 0.04), material_for("fired_brick", part), "HearthChimney")


static func publish_rug(part, parent: Dictionary) -> void:
	add_box(parent, Vector3(part.occupied_size.x, 0.035, part.occupied_size.z), Vector3(0.0, 0.02, 0.0), material_for(part.material_id, part), "WovenRug")
	add_box(parent, Vector3(part.occupied_size.x * 0.86, 0.018, part.occupied_size.z * 0.82), Vector3(0.0, 0.048, 0.0), material_for("linen", part), "RugInlay")


static func publish_shelf(part, parent: Dictionary) -> void:
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


static func publish_chest(part, parent: Dictionary) -> void:
	add_box(parent, Vector3(0.96, 0.52, 0.58), Vector3(0.0, 0.26, 0.0), material_for("timber_board", part), "ChestBody")
	add_box(parent, Vector3(1.02, 0.16, 0.64), Vector3(0.0, 0.58, 0.0), material_for("timber_beam", part), "ChestLid")
	add_box(parent, Vector3(0.12, 0.14, 0.05), Vector3(0.0, 0.34, -0.32), material_for("brass", part), "ChestLatch")
	for x in [-0.33, 0.33]:
		add_box(parent, Vector3(0.08, 0.62, 0.66), Vector3(float(x), 0.31, 0.0), material_for("brass", part), "ChestBand")


static func publish_candle(part, parent: Dictionary) -> void:
	# A candle is one clean wax stem and flame. The old long holder cylinder made
	# a tabletop candle read as a duplicated lower half rather than a fixture.
	add_cylinder(parent, 0.078, 0.30, Vector3(0.0, 0.15, 0.0), material_for("candle_wax", part), "CandleWax")
	add_sphere(parent, 0.075, Vector3(0.0, 0.39, 0.0), material_for("candle_flame", part), "CandleFlame", Vector3(0.62, 1.34, 0.62))
	add_practical_light(parent, Vector3(0.0, 0.42, 0.0), Color(1.0, 0.56, 0.26), 0.55, 3.0)


static func add_practical_light(parent: Dictionary, position: Vector3, color: Color, energy: float, light_range: float) -> void:
	parent.lights.append({"position":position,"color":color,"energy":energy,"range":light_range})


static func publish_pot_plant(part, parent: Dictionary) -> void:
	add_cylinder(parent, 0.18, 0.30, Vector3(0.0, 0.15, 0.0), material_for("ceramic_glaze", part), "PlantPot")
	for angle in [0.0, 2.09, 4.18]:
		_append(parent, "sphere", Vector3(0.16, 0.46, 0.08), Vector3(cos(angle) * 0.12, 0.48, sin(angle) * 0.12), Vector3(sin(angle) * 0.36, 0.0, -cos(angle) * 0.44), material_for("wool_moss", part), "PlantLeaf")


static func publish_wall_art(part, parent: Dictionary) -> void:
	# The furnishing record owns the wall-facing yaw and mounts its local +Z
	# backing face on the declared wall surface. Local -Z remains the readable
	# painted face inside the room, without adding decor collision.
	var mount_height := float(part.recipe.get("mountHeight", 1.38))
	add_box(parent, Vector3(part.occupied_size.x * 1.14, part.occupied_size.y * 1.16, 0.08), Vector3(0.0, mount_height, 0.0), material_for("timber_beam", part), "ArtFrame")
	add_box(parent, Vector3(part.occupied_size.x, part.occupied_size.y, 0.045), Vector3(0.0, mount_height, -0.06), material_for("painted_decor", part), "ArtPanel")



static func material_for(material_id: String, part) -> Dictionary:
	return {"materialId":material_id,"variation":float(part.recipe.get("variation",0.0))}

static func _append(parent: Dictionary, primitive: String, size: Vector3, position: Vector3, rotation: Vector3, material: Dictionary, node_name: String) -> void:
	parent.pieces.append({"primitive":primitive,"name":node_name,
		"transform":Transform3D(Basis.from_euler(rotation).scaled_local(size),position),
		"materialId":material.materialId,"variation":material.variation})

static func add_box(parent: Dictionary, size: Vector3, position: Vector3, material: Dictionary, node_name: String, rotation := Vector3.ZERO) -> void:
	_append(parent,"box",size,position,rotation,material,node_name)

static func add_cylinder(parent: Dictionary, radius: float, height: float, position: Vector3, material: Dictionary, node_name: String) -> void:
	_append(parent,"cylinder",Vector3(radius*2.0,height,radius*2.0),position,Vector3.ZERO,material,node_name)

static func add_sphere(parent: Dictionary, radius: float, position: Vector3, material: Dictionary, node_name: String, scale_multiplier := Vector3.ONE) -> void:
	_append(parent,"sphere",Vector3.ONE*radius*2.0*scale_multiplier,position,Vector3.ZERO,material,node_name)
