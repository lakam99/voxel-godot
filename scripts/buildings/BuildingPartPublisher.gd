extends RefCounted
class_name BuildingPartPublisher

## Scene publication for material-aware construction parts. It intentionally
## consumes only BuildingPart data: the visual recipe and collision shape share
## one record, and board/brick detail is instanced per parent part.

const ConstructionMaterialCatalogScript := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")

var unit_box: BoxMesh
var material_cache: Dictionary = {}
var published_nodes: Array = []
var published_part_count := 0
var collision_count := 0
var visual_batch_count := 0
var recipe_build_usec := 0
var publication_usec := 0
var source_blueprint_id := ""
var batch_static_parts := false
var static_collision_body: StaticBody3D
var static_part_records: Dictionary = {}
var static_visual_batches: Dictionary = {}
var static_visual_collecting := false
var static_visual_part_transform := Transform3D.IDENTITY
var building_navigation_manifest: Dictionary = {}


func _init() -> void:
	unit_box = BoxMesh.new()
	unit_box.size = Vector3.ONE


func publish(blueprint, parent: Node3D, options: Dictionary = {}) -> Dictionary:
	clear_published()
	if blueprint == null or parent == null:
		return summary()
	configure_publication_options(options)
	source_blueprint_id = canonical_source_blueprint_id(blueprint)
	var started := Time.get_ticks_usec()
	for part in blueprint.parts:
		if part == null:
			continue
		publish_part(part, parent)
	flush_static_batches(parent)
	publish_navigation_manifest(blueprint, parent)
	publication_usec = Time.get_ticks_usec() - started
	return summary()


func publish_incremental(blueprint, parent: Node3D, parts_per_frame := 6, options: Dictionary = {}) -> Dictionary:
	# Uses the same part records and publish_part path as synchronous publication.
	# Consumers with an on-screen loading state can spread a larger blueprint over
	# frames without inventing a second visual/collision publication authority.
	clear_published()
	if blueprint == null or parent == null:
		return summary()
	configure_publication_options(options)
	source_blueprint_id = canonical_source_blueprint_id(blueprint)
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
	flush_static_batches(parent)
	publish_navigation_manifest(blueprint, parent)
	publication_usec = Time.get_ticks_usec() - started
	return summary()


func clear_published() -> void:
	for node in published_nodes:
		if node != null and is_instance_valid(node):
			node.queue_free()
	published_nodes.clear()
	published_part_count = 0
	collision_count = 0
	visual_batch_count = 0
	recipe_build_usec = 0
	publication_usec = 0
	source_blueprint_id = ""
	batch_static_parts = false
	static_collision_body = null
	static_part_records.clear()
	static_visual_batches.clear()
	static_visual_collecting = false
	static_visual_part_transform = Transform3D.IDENTITY
	building_navigation_manifest.clear()


func configure_publication_options(options: Dictionary) -> void:
	batch_static_parts = bool(options.get("batchStaticParts", false))


func canonical_source_blueprint_id(blueprint) -> String:
	var result := String(blueprint.id) if blueprint != null else ""
	if blueprint != null and blueprint.recipe is Dictionary:
		result = String((blueprint.recipe as Dictionary).get("sourceBlueprintId", result))
	return result


func publish_part(part, parent: Node3D) -> StaticBody3D:
	var started := Time.get_ticks_usec()
	published_part_count += 1
	if batch_static_parts and String(part.kind) != "door":
		publish_static_part(part, parent)
		recipe_build_usec += Time.get_ticks_usec() - started
		return null
	var body := StaticBody3D.new()
	body.name = "ConstructionPart_%s" % String(part.id)
	body.position = part.position
	body.rotation = part.rotation
	body.set_meta("building_part_id", part.id)
	body.set_meta("building_part_kind", part.kind)
	body.set_meta("building_material", part.material_id)
	body.set_meta("building_semantic", part.semantic)
	body.set_meta("building_part_record", part.snapshot())
	parent.add_child(body)
	if String(part.kind) == "door":
		configure_door_leaf(body, part)
	published_nodes.append(body)
	if part.collision_enabled:
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = part.size
		collision.shape = shape
		collision.set_meta("building_part_id", part.id)
		collision.set_meta("building_part_kind", part.kind)
		body.add_child(collision)
		collision_count += 1
	# Some construction records are collision stringers beneath richer generated
	# geometry (for example a stair flight's visible treads).  They remain normal
	# source parts with real collision, but do not duplicate the finished visual.
	if bool(part.recipe.get("visual", true)):
		publish_visual(part, body)
	if String(part.kind) == "door":
		add_door_interaction_proxy(body, part.size)
	recipe_build_usec += Time.get_ticks_usec() - started
	return body


func publish_static_part(part, parent: Node3D) -> void:
	# Static construction records remain the source of visual and collision facts;
	# this only composes their publication under shared scene nodes. Doors keep
	# their individual bodies because DoorPortalService owns their interaction and
	# collision state.
	if part.collision_enabled:
		var collision_body := static_collision_batch(parent)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = part.size
		collision.shape = shape
		collision.set_meta("building_part_id", part.id)
		collision.set_meta("building_part_kind", part.kind)
		collision.position = part.position
		collision.rotation = part.rotation
		collision_body.add_child(collision)
		static_part_records[String(part.id)] = part.snapshot()
		collision_count += 1
	if bool(part.recipe.get("visual", true)):
		static_visual_collecting = true
		static_visual_part_transform = Transform3D(Basis.from_euler(part.rotation), part.position)
		publish_visual(part, parent)
		static_visual_collecting = false
		static_visual_part_transform = Transform3D.IDENTITY


func static_collision_batch(parent: Node3D) -> StaticBody3D:
	if static_collision_body != null and is_instance_valid(static_collision_body):
		return static_collision_body
	static_collision_body = StaticBody3D.new()
	static_collision_body.name = "ConstructionStaticCollisionBatch"
	static_collision_body.set_meta("building_part_kind", "batched_static")
	static_collision_body.set_meta("building_source_blueprint", source_blueprint_id)
	parent.add_child(static_collision_body)
	published_nodes.append(static_collision_body)
	return static_collision_body


func publish_visual(part, parent: Node3D) -> void:
	match String(part.kind):
		"wall":
			if ConstructionMaterialCatalogScript.is_masonry_material(String(part.material_id)):
				publish_brick_wall(part, parent)
			else:
				publish_timber_wall(part, parent)
		"foundation":
			if ConstructionMaterialCatalogScript.is_cobble_material(String(part.material_id)):
				publish_settled_cobble(part, parent)
			elif ConstructionMaterialCatalogScript.is_masonry_material(String(part.material_id)):
				publish_brick_wall(part, parent)
			else:
				add_box_visual(parent, part.size, Vector3.ZERO, material_for(part), "Visual_foundation")
		"floor":
			publish_board_floor(part, parent)
		"beam":
			if String(part.material_id) in ["timber_beam", "timber_board"]:
				publish_aged_timber_beam(part, parent)
			else:
				add_box_visual(parent, part.size, Vector3.ZERO, material_for(part), "Visual_beam")
		"roof":
			publish_roof_shingles(part, parent)
		"door":
			if String(part.recipe.get("doorPresentation", "")) == "portcullis":
				publish_portcullis(part, parent)
			else:
				publish_door_boards(part, parent)
		"window":
			publish_window(part, parent)
		"barrel":
			publish_barrel(part, parent)
		"crate":
			publish_framed_crate(part, parent)
		"pennant":
			publish_cloth_pennant(part, parent)
		"ground_patch":
			publish_irregular_ground_patch(part, parent)
		"sack":
			publish_sack(part, parent)
		"pottery":
			publish_pottery(part, parent)
		"basket":
			publish_basket(part, parent)
		"tool_rack":
			publish_tool_rack(part, parent)
		_:
			add_box_visual(parent, part.size, Vector3.ZERO, material_for(part), "Visual_%s" % part.kind)


func publish_timber_wall(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var row_height := 0.34
	var rows := maxi(1, ceili(size.y / row_height))
	var transforms: Array[Transform3D] = []
	var horizontal_axis := 0 if size.x >= size.z else 2
	var horizontal_length := size[horizontal_axis]
	var depth_axis := 2 if horizontal_axis == 0 else 0
	var part_phase := float(posmod(String(part.id).hash(), 997)) / 997.0
	for row in range(rows):
		var height := size.y / float(rows)
		var y := -size.y * 0.5 + height * (float(row) + 0.5)
		var row_phase := fposmod(part_phase + float(row) * 0.317, 1.0)
		var cursor := -horizontal_length * 0.5 - (0.52 + row_phase * 0.74 if row % 2 == 1 else 0.0)
		var column := 0
		while cursor < horizontal_length * 0.5 - 0.03:
			var piece_phase := fposmod(sin(float(row + 1) * 17.137 + float(column + 1) * 43.771 + part_phase * 9.1) * 23171.31, 1.0)
			var nominal_length := lerpf(1.10, 2.35, piece_phase)
			var piece_start := maxf(cursor, -horizontal_length * 0.5)
			var piece_end := minf(cursor + nominal_length, horizontal_length * 0.5)
			if piece_end - piece_start >= 0.18:
				var board_size := size
				board_size[horizontal_axis] = maxf(0.14, piece_end - piece_start - 0.026)
				board_size.y = maxf(0.04, height - 0.026)
				var position := Vector3.ZERO
				position[horizontal_axis] = (piece_start + piece_end) * 0.5
				position[depth_axis] = (piece_phase - 0.5) * 0.022
				position.y = y + (piece_phase - 0.5) * 0.012
				var settlement_axis := Vector3.FORWARD if horizontal_axis == 0 else Vector3.RIGHT
				var settlement := (piece_phase - 0.5) * deg_to_rad(0.72)
				transforms.append(Transform3D(Basis(settlement_axis, settlement).scaled(board_size), position))
			cursor += nominal_length
			column += 1
	add_box_batch(parent, transforms, material_for(part), "PlankCladding")


func publish_aged_timber_beam(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var longest_axis := 0
	var longest_length := size.x
	if size.y > longest_length:
		longest_axis = 1
		longest_length = size.y
	if size.z > longest_length:
		longest_axis = 2
		longest_length = size.z
	var segment_count := 3 if longest_length > 1.05 else 1
	if segment_count == 1:
		add_box_visual(parent, size, Vector3.ZERO, material_for(part), "AgedTimberBeam")
		return
	var transforms: Array[Transform3D] = []
	var segment_length := longest_length / float(segment_count)
	var part_phase := float(posmod(String(part.id).hash(), 997)) / 997.0
	for segment_index in range(segment_count):
		var segment_phase := fposmod(part_phase + float(segment_index) * 0.371, 1.0)
		var resolved_size := size
		resolved_size[longest_axis] = segment_length + 0.045
		var axis_offset := -longest_length * 0.5 + segment_length * (float(segment_index) + 0.5)
		var position := Vector3.ZERO
		position[longest_axis] = axis_offset
		var bend := (segment_phase - 0.5) * deg_to_rad(1.15)
		var thickness_offset := sin(float(segment_index) * 1.9 + part_phase * TAU) * minf(0.018, longest_length * 0.004)
		var rotation_axis := Vector3.FORWARD if longest_axis in [0, 1] else Vector3.RIGHT
		if longest_axis == 0:
			position.y += thickness_offset
		elif longest_axis == 1:
			position.x += thickness_offset
		else:
			position.y += thickness_offset
		var basis := Basis(rotation_axis, bend).scaled(resolved_size * lerpf(0.985, 1.015, segment_phase))
		transforms.append(Transform3D(basis, position))
	add_box_batch(parent, transforms, material_for(part), "AgedTimberSegments")


func publish_brick_wall(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var transforms: Array[Transform3D] = []
	var material_id := String(part.material_id)
	var is_monumental_geometry := String(part.id).begins_with("castle_")
	var uses_aged_castle_stone := is_monumental_geometry and material_id == "stone_foundation"
	var is_rubble_foundation := material_id == "stone_foundation" and not is_monumental_geometry
	var unit_length := 1.18 if is_monumental_geometry else (0.88 if is_rubble_foundation else 0.68)
	var unit_height := 0.52 if is_monumental_geometry else (0.38 if is_rubble_foundation else 0.285)
	var joint_width := 0.018 if is_monumental_geometry else (0.030 if is_rubble_foundation else 0.022)
	var face_depth := 0.105 if is_monumental_geometry else (0.11 if is_rubble_foundation else 0.075)
	# Mortar is published by the same part record, behind the physical brick
	# instances. Its thin axis is inset on both faces, so it cannot z-fight with
	# a brick surface while course gaps remain a material fact rather than a
	# texture.
	var mortar_size := size
	mortar_size.x = maxf(0.02, size.x - 0.036)
	mortar_size.z = maxf(0.02, size.z - 0.036)
	var bed_material := material_for(part) if String(part.kind) == "foundation" else material_for_id("mortar", variation_for(part))
	add_box_visual(parent, mortar_size, Vector3.ZERO, bed_material, "MasonryBed")
	var top_surface_material := String(part.recipe.get("topSurfaceMaterial", ""))
	if String(part.kind) == "foundation" and not top_surface_material.is_empty():
		add_box_visual(parent, Vector3(maxf(0.08, size.x - 0.05), 0.028, maxf(0.08, size.z - 0.05)), Vector3(0.0, size.y * 0.5 + 0.014, 0.0), material_for_id(top_surface_material, variation_for(part) - 0.025), "FoundationTopSurface")
	append_brick_face_transforms(transforms, size, true, -1.0, unit_length, unit_height, joint_width, face_depth)
	append_brick_face_transforms(transforms, size, true, 1.0, unit_length, unit_height, joint_width, face_depth)
	append_brick_face_transforms(transforms, size, false, -1.0, unit_length, unit_height, joint_width, face_depth)
	append_brick_face_transforms(transforms, size, false, 1.0, unit_length, unit_height, joint_width, face_depth)
	var surface_material := material_for_id("aged_castle_stone", variation_for(part)) if uses_aged_castle_stone else material_for(part)
	add_box_batch(parent, transforms, surface_material, "BrickCourses", build_masonry_custom_data(transforms, part))


func publish_settled_cobble(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var material_id := String(part.material_id)
	var bed_height := maxf(0.045, size.y * 0.48)
	add_box_visual(parent, Vector3(size.x, bed_height, size.z), Vector3(0.0, -size.y * 0.5 + bed_height * 0.5, 0.0), material_for_id("drainage_stain", variation_for(part) - 0.04), "CobbleJointBed")
	var target_cell_x := 0.68 if material_id == "cobblestone" else 0.76
	var target_cell_z := 0.74 if material_id == "cobblestone" else 0.82
	var count_x := maxi(1, ceili(size.x / target_cell_x))
	var count_z := maxi(1, ceili(size.z / target_cell_z))
	var desired_count := count_x * count_z
	if desired_count > 1400:
		var expansion := sqrt(float(desired_count) / 1400.0)
		count_x = maxi(1, ceili(float(count_x) / expansion))
		count_z = maxi(1, ceili(float(count_z) / expansion))
	var cell_x := size.x / float(count_x)
	var cell_z := size.z / float(count_z)
	var stone_mesh := CylinderMesh.new()
	stone_mesh.top_radius = 0.5
	stone_mesh.bottom_radius = 0.53
	stone_mesh.height = 1.0
	stone_mesh.radial_segments = 8
	stone_mesh.rings = 1
	var transforms: Array[Transform3D] = []
	var custom_data: Array[Color] = []
	var part_phase := float(posmod(String(part.id).hash(), 1009)) / 1009.0
	for z_index in range(count_z):
		for x_index in range(count_x):
			var stable := fposmod(sin(float(x_index + 1) * 12.9898 + float(z_index + 1) * 78.233 + part_phase * 37.719) * 43758.5453, 1.0)
			var secondary := fposmod(sin(float(x_index + 1) * 41.173 + float(z_index + 1) * 19.317 + part_phase * 91.37) * 23171.31, 1.0)
			var broken := stable > (0.965 if material_id == "cobblestone" else 0.925)
			var stone_x := maxf(0.12, cell_x - lerpf(0.055, 0.11, stable)) * (0.70 if broken else 1.0)
			var stone_z := maxf(0.12, cell_z - lerpf(0.060, 0.12, secondary)) * (0.78 if broken else 1.0)
			var stone_height := maxf(0.07, size.y * lerpf(0.52, 0.76, secondary))
			var x := -size.x * 0.5 + cell_x * (float(x_index) + 0.5) + (secondary - 0.5) * minf(0.09, cell_x * 0.14)
			var z := -size.z * 0.5 + cell_z * (float(z_index) + 0.5) + (stable - 0.5) * minf(0.10, cell_z * 0.14)
			if broken:
				x += (stable - 0.5) * cell_x * 0.24
			var settlement := (stable - 0.5) * (0.055 if material_id == "cobblestone" else 0.085) - (0.035 if broken else 0.0)
			var y := size.y * 0.5 - stone_height * 0.48 + settlement
			var yaw := (secondary - 0.5) * deg_to_rad(15.0)
			var tilt := (stable - 0.5) * deg_to_rad(4.0 if material_id == "cobblestone" else 6.5)
			var basis := (Basis(Vector3.UP, yaw) * Basis(Vector3.FORWARD, tilt)).scaled(Vector3(stone_x, stone_height, stone_z))
			transforms.append(Transform3D(basis, Vector3(x, y, z)))
			custom_data.append(Color(stable, clampf(0.5 + settlement * 4.0, 0.0, 1.0), secondary, 1.0))
	add_mesh_batch(parent, stone_mesh, transforms, material_for(part), "SettledCobbleStones", custom_data)


func build_masonry_custom_data(transforms: Array[Transform3D], part) -> Array[Color]:
	var result: Array[Color] = []
	var min_y := INF
	var max_y := -INF
	var max_abs_x := 0.001
	var max_abs_z := 0.001
	for transform in transforms:
		min_y = minf(min_y, transform.origin.y)
		max_y = maxf(max_y, transform.origin.y)
		max_abs_x = maxf(max_abs_x, absf(transform.origin.x))
		max_abs_z = maxf(max_abs_z, absf(transform.origin.z))
	var height_range := maxf(0.001, max_y - min_y)
	var part_phase := float(posmod(String(part.id).hash(), 997)) / 997.0
	for index in range(transforms.size()):
		var origin := transforms[index].origin
		var height := clampf((origin.y - min_y) / height_range, 0.0, 1.0)
		var edge_proximity := maxf(absf(origin.x) / max_abs_x, absf(origin.z) / max_abs_z)
		var edge_exposure := smoothstep(0.72, 0.98, edge_proximity)
		var top_shelter := smoothstep(0.82, 1.0, height)
		var stable_piece := fposmod(sin(origin.x * 12.9898 + origin.y * 78.233 + origin.z * 37.719 + float(index) * 0.173 + part_phase * 11.0) * 43758.5453, 1.0)
		var exposure := clampf(0.28 + edge_exposure * 0.36 + stable_piece * 0.22 - top_shelter * 0.18, 0.06, 0.94)
		result.append(Color(stable_piece, height, exposure, 1.0))
	return result


func append_brick_face_transforms(transforms: Array[Transform3D], size: Vector3, axis_x: bool, face_sign: float, unit_length: float, unit_height: float, joint_width: float, face_depth: float) -> void:
	var length := size.x if axis_x else size.z
	var row := 0
	var consumed_height := 0.0
	while consumed_height < size.y - 0.001:
		var course_noise := fposmod(sin(float(row + 1) * 19.193) * 15731.743, 1.0)
		var monumental := unit_height > 0.40
		var actual_height := minf(size.y - consumed_height, unit_height * lerpf(0.78 if monumental else 0.84, 1.18 if monumental else 1.14, course_noise))
		var offset := unit_length * (0.46 + (course_noise - 0.5) * 0.13) if row % 2 == 1 else unit_length * (course_noise - 0.5) * (0.08 if monumental else 0.18)
		var cursor := -length * 0.5 - offset
		var column := 0
		while cursor < length * 0.5 - 0.04:
			var face_seed := 1.0 if axis_x else 17.0
			face_seed += 31.0 if face_sign > 0.0 else 0.0
			var piece_noise := fposmod(sin(float(row + 1) * 12.9898 + float(column + 1) * 78.233 + face_seed) * 43758.5453, 1.0)
			var second_noise := fposmod(sin(float(row + 1) * 39.3467 + float(column + 1) * 11.135 + face_seed) * 24634.6345, 1.0)
			var nominal_length := unit_length * lerpf(0.60 if monumental else 0.82, 1.42 if monumental else 1.16, piece_noise)
			var piece_start := maxf(cursor, -length * 0.5)
			var piece_end := minf(cursor + nominal_length, length * 0.5)
			if piece_end - piece_start < 0.12:
				cursor += nominal_length
				column += 1
				continue
			var along := (piece_start + piece_end) * 0.5
			var chip_factor := lerpf(0.90 if monumental else 0.92, 0.975 if monumental else 0.98, second_noise) if piece_noise > (0.92 if monumental else 0.93) else 1.0
			var resolved_length := maxf(0.08, piece_end - piece_start - joint_width) * chip_factor
			var resolved_height := maxf(0.04, (actual_height - joint_width * 0.72) * lerpf(0.94 if monumental else 0.90, 1.0, second_noise))
			var resolved_depth := face_depth * lerpf(0.90 if monumental else 0.78, 1.10 if monumental else 1.12, piece_noise)
			var brick_size := Vector3(resolved_length, resolved_height, resolved_depth) if axis_x else Vector3(resolved_depth, resolved_height, resolved_length)
			var along_jitter := (second_noise - 0.5) * (0.010 if monumental else 0.018)
			if chip_factor < 0.99:
				along_jitter += (unit_length - resolved_length) * (0.04 if second_noise > 0.5 else -0.04)
			var course_jitter := (piece_noise - 0.5) * (0.002 if monumental else 0.012)
			var resolved_y := -size.y * 0.5 + consumed_height + actual_height * 0.5 + course_jitter
			var face_displacement := (second_noise - 0.5) * (0.032 if monumental else 0.026)
			var face_position := face_sign * ((size.z if axis_x else size.x) * 0.5 + resolved_depth * 0.18 + face_displacement)
			var position := Vector3(along + along_jitter, resolved_y, face_position) if axis_x else Vector3(face_position, resolved_y, along + along_jitter)
			var settlement_angle := (second_noise - 0.5) * deg_to_rad(1.15 if monumental else 1.15)
			var settlement_basis := Basis(Vector3.FORWARD if axis_x else Vector3.RIGHT, settlement_angle).scaled(brick_size)
			transforms.append(Transform3D(settlement_basis, position))
			cursor += nominal_length
			column += 1
		consumed_height += actual_height
		row += 1


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
	var course_depth := 0.52
	var shingle_width := 0.64
	var course_count := maxi(1, ceili(size.x / course_depth))
	var shingle_count := maxi(1, ceili(size.z / shingle_width))
	var transforms: Array[Transform3D] = []
	for course_index in range(course_count):
		var resolved_course_depth := size.x / float(course_count)
		var row_offset := shingle_width * 0.5 if course_index % 2 == 1 else 0.0
		for shingle_index in range(shingle_count + 1):
			var resolved_width := size.z / float(shingle_count)
			var z := -size.z * 0.5 + resolved_width * (float(shingle_index) + 0.5) - row_offset
			var tile_start := maxf(-size.z * 0.5, z - resolved_width * 0.5)
			var tile_end := minf(size.z * 0.5, z + resolved_width * 0.5)
			if tile_end - tile_start < 0.08:
				continue
			z = (tile_start + tile_end) * 0.5
			var piece_noise := fposmod(sin(float(course_index + 1) * 41.17 + float(shingle_index + 1) * 13.71) * 31991.37, 1.0)
			var x := -size.x * 0.5 + resolved_course_depth * (float(course_index) + 0.5)
			var tile_size := Vector3(maxf(0.08, resolved_course_depth + 0.045), size.y * lerpf(0.88, 1.08, piece_noise), maxf(0.08, tile_end - tile_start - 0.025))
			transforms.append(box_transform(Vector3(x, (piece_noise - 0.5) * 0.018, z), tile_size))
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


func publish_portcullis(part, parent: Node3D) -> void:
	# A castle gate is a raised iron grille, not a painted plank wall.  It is
	# still one ordinary door part: the shared controller owns its closed
	# collision and lifts the same visual leaf clear when opened.
	var size: Vector3 = part.size
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	parent.add_child(pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	pivot.add_child(leaf)
	var bar_count := maxi(4, ceili(size.x / 0.30))
	var bar_width := minf(0.12, size.x / float(bar_count) * 0.48)
	var bars: Array[Transform3D] = []
	for index in range(bar_count):
		var x := -size.x * 0.5 + size.x * (float(index) + 0.5) / float(bar_count)
		bars.append(box_transform(Vector3(x, 0.0, 0.0), Vector3(bar_width, size.y, maxf(0.12, size.z * 1.35))))
	add_box_batch(leaf, bars, material_for(part), "PortcullisBars")
	for crossbar_ratio in [-0.30, 0.20]:
		add_box_visual(leaf, Vector3(size.x, 0.12, maxf(0.14, size.z * 1.45)), Vector3(0.0, size.y * crossbar_ratio, 0.0), material_for(part), "PortcullisCrossbar")
	publish_portcullis_lever(part, parent)


func publish_portcullis_lever(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var lever := Node3D.new()
	lever.name = "PortcullisLever"
	lever.position = Vector3(size.x * 0.5 + 0.42, -size.y * 0.24, -maxf(0.44, size.z * 2.60))
	parent.add_child(lever)
	add_box_visual(lever, Vector3(0.34, 0.46, 0.12), Vector3.ZERO, material_for_id("stone_foundation", variation_for(part)), "LeverMount")
	var arm_pivot := Node3D.new()
	arm_pivot.name = "LeverArmPivot"
	arm_pivot.rotation.z = -0.52
	lever.add_child(arm_pivot)
	add_box_visual(arm_pivot, Vector3(0.10, 0.58, 0.10), Vector3(0.0, 0.24, -0.09), material_for_id("ironwork", variation_for(part)), "LeverArm")
	add_box_visual(arm_pivot, Vector3(0.19, 0.19, 0.19), Vector3(0.0, 0.52, -0.09), material_for_id("brass", variation_for(part)), "LeverHandle")


func configure_door_leaf(body: StaticBody3D, part) -> void:
	# Match the established DoorPortal/DoorController leaf contract. The generic
	# controller owns swing state and collider disabling; this publisher only
	# provides a building-derived door leaf for it to operate on.
	var portal_id := "building:%s:%s" % [source_blueprint_id, String(part.id)]
	body.set_meta("block_type", "door")
	body.set_meta("open", false)
	body.set_meta("closed_rotation", body.rotation.y)
	body.set_meta("open_swing", -PI * 0.5)
	body.set_meta("door_motion", String(part.recipe.get("doorMotion", "swing")))
	body.set_meta("door_presentation", String(part.recipe.get("doorPresentation", "door")))
	body.set_meta("open_visual_offset", Vector3(0.0, part.size.y + 0.18, 0.0) if String(part.recipe.get("doorMotion", "swing")) == "raise" else Vector3.ZERO)
	body.set_meta("door_portal_id", portal_id)
	body.set_meta("door_group_id", portal_id)
	body.set_meta("door_building_id", source_blueprint_id)
	body.set_meta("door_side", door_side_for_world_transform(body.global_transform))
	body.set_meta("door_public_access", true)
	body.set_meta("door_policy", "private_home")
	body.set_meta("locked", false)
	body.set_meta("jammed", false)
	body.set_meta("destroyed", false)
	body.set_meta("unloaded", false)


func door_side_for_world_transform(transform: Transform3D) -> int:
	var forward := transform.basis * Vector3.FORWARD
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		return 0
	forward = forward.normalized()
	if absf(forward.x) > absf(forward.z):
		return 1 if forward.x > 0.0 else 3
	return 0 if forward.z >= 0.0 else 2


func add_door_interaction_proxy(door: StaticBody3D, size: Vector3) -> void:
	var area := Area3D.new()
	area.name = "DoorInteraction"
	area.collision_layer = 1 << 10
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	area.set_meta("interaction_parent", door)
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x * 1.26, size.y * 1.04, maxf(1.10, size.z * 4.0))
	var collider := CollisionShape3D.new()
	collider.shape = shape
	area.add_child(collider)
	door.add_child(area)


func publish_window(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var monumental := String(part.id).begins_with("castle_keep_") or String(part.id).begins_with("castle_gatehouse_")
	var trim := material_for_id("stone_foundation" if monumental else "timber_beam", variation_for(part) - 0.02)
	var recess := material_for_id("window_recess", variation_for(part))
	# A dark, oversized reveal breaks the glass away from the wall plane. It is
	# visual-only and belongs to the same opening part, so collision and navigation
	# still derive from the authored wall/opening records.
	if size.x < size.z:
		add_box_visual(parent, Vector3(size.x * 1.24, size.y * 1.20, size.z * 1.16), Vector3.ZERO, recess, "WindowReveal")
	else:
		add_box_visual(parent, Vector3(size.x * 1.16, size.y * 1.20, size.z * 1.24), Vector3.ZERO, recess, "WindowReveal")
	add_box_visual(parent, size, Vector3.ZERO, material_for(part), "WindowGlass")
	if size.x < size.z:
		add_box_visual(parent, Vector3(size.x * 1.62, size.y * 1.18, 0.14), Vector3(0.0, 0.0, -size.z * 0.58), trim, "WindowFrameNear")
		add_box_visual(parent, Vector3(size.x * 1.62, size.y * 1.18, 0.14), Vector3(0.0, 0.0, size.z * 0.58), trim, "WindowFrameFar")
		add_box_visual(parent, Vector3(size.x * 1.62, 0.15, size.z * 1.30), Vector3(0.0, size.y * 0.59, 0.0), trim, "WindowLintel")
		add_box_visual(parent, Vector3(size.x * 1.82, 0.17, size.z * 1.36), Vector3(0.0, -size.y * 0.59, 0.0), trim, "WindowSill")
		add_box_visual(parent, Vector3(size.x * 1.68, 0.075, size.z * 1.68), Vector3(0.0, 0.0, 0.0), trim, "WindowMullionHorizontal")
		add_box_visual(parent, Vector3(size.x * 1.68, size.y * 1.05, 0.075), Vector3(0.0, 0.0, 0.0), trim, "WindowMullionVertical")
	else:
		add_box_visual(parent, Vector3(0.14, size.y * 1.18, size.z * 1.62), Vector3(-size.x * 0.58, 0.0, 0.0), trim, "WindowFrameNear")
		add_box_visual(parent, Vector3(0.14, size.y * 1.18, size.z * 1.62), Vector3(size.x * 0.58, 0.0, 0.0), trim, "WindowFrameFar")
		add_box_visual(parent, Vector3(size.x * 1.30, 0.15, size.z * 1.62), Vector3(0.0, size.y * 0.59, 0.0), trim, "WindowLintel")
		add_box_visual(parent, Vector3(size.x * 1.36, 0.17, size.z * 1.82), Vector3(0.0, -size.y * 0.59, 0.0), trim, "WindowSill")
		add_box_visual(parent, Vector3(size.x * 1.68, 0.075, size.z * 1.68), Vector3(0.0, 0.0, 0.0), trim, "WindowMullionHorizontal")
		add_box_visual(parent, Vector3(0.075, size.y * 1.05, size.z * 1.68), Vector3(0.0, 0.0, 0.0), trim, "WindowMullionVertical")


func publish_barrel(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var radius := minf(size.x, size.z) * 0.46
	var stave_count := 12
	var stave_width := TAU * radius / float(stave_count) * 0.86
	var staves: Array[Transform3D] = []
	var hoops: Array[Transform3D] = []
	for stave_index in range(stave_count):
		var angle := TAU * float(stave_index) / float(stave_count)
		var position := Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)
		staves.append(oriented_box_transform(position, Vector3(stave_width, size.y, maxf(0.055, radius * 0.18)), angle))
		for hoop_y in [-size.y * 0.31, size.y * 0.31]:
			hoops.append(oriented_box_transform(position + Vector3(0.0, hoop_y, 0.0), Vector3(stave_width * 1.04, 0.075, maxf(0.065, radius * 0.20)), angle))
	add_box_batch(parent, staves, material_for_id("timber_board", variation_for(part)), "BarrelStaves")
	add_box_batch(parent, hoops, material_for_id("ironwork", variation_for(part)), "BarrelHoops")
	add_box_visual(parent, Vector3(radius * 1.52, 0.07, radius * 1.52), Vector3(0.0, size.y * 0.5 - 0.04, 0.0), material_for_id("timber_board", variation_for(part) - 0.02), "BarrelTop")


func publish_framed_crate(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var panel_material := material_for_id("timber_board", variation_for(part))
	var frame_material := material_for_id("timber_beam", variation_for(part) - 0.02)
	add_box_visual(parent, Vector3(size.x * 0.88, size.y * 0.76, size.z * 0.88), Vector3.ZERO, panel_material, "CratePanels")
	for x_sign in [-1.0, 1.0]:
		for z_sign in [-1.0, 1.0]:
			add_box_visual(parent, Vector3(0.095, size.y, 0.095), Vector3(x_sign * size.x * 0.43, 0.0, z_sign * size.z * 0.43), frame_material, "CrateCorner")
	for y_sign in [-1.0, 1.0]:
		add_box_visual(parent, Vector3(size.x, 0.09, 0.10), Vector3(0.0, y_sign * size.y * 0.43, size.z * 0.46), frame_material, "CrateFaceRail")
		add_box_visual(parent, Vector3(0.10, 0.09, size.z), Vector3(size.x * 0.46, y_sign * size.y * 0.43, 0.0), frame_material, "CrateSideRail")


func publish_cloth_pennant(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_normal(Vector3.FORWARD)
	surface.set_uv(Vector2(0.0, 0.0))
	surface.add_vertex(Vector3(-size.x * 0.5, size.y * 0.5, 0.0))
	surface.set_uv(Vector2(1.0, 0.0))
	surface.add_vertex(Vector3(size.x * 0.5, size.y * 0.5, 0.0))
	surface.set_uv(Vector2(0.5, 1.0))
	surface.add_vertex(Vector3(0.0, -size.y * 0.5, 0.0))
	var mesh := surface.commit()
	var visual := MeshInstance3D.new()
	visual.name = "ClothPennant"
	visual.mesh = mesh
	visual.material_override = material_for(part)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if static_visual_collecting:
		visual.transform = static_visual_part_transform
	parent.add_child(visual)
	visual_batch_count += 1


func publish_irregular_ground_patch(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var surface := SurfaceTool.new()
	var segment_count := 14
	var phase := float(posmod(String(part.id).hash(), 360)) * PI / 180.0
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_normal(Vector3.UP)
	for segment_index in range(segment_count):
		var angle_a := TAU * float(segment_index) / float(segment_count)
		var angle_b := TAU * float(segment_index + 1) / float(segment_count)
		var radius_a := 0.82 + sin(angle_a * 3.0 + phase) * 0.10 + sin(angle_a * 7.0 + phase * 0.7) * 0.06
		var radius_b := 0.82 + sin(angle_b * 3.0 + phase) * 0.10 + sin(angle_b * 7.0 + phase * 0.7) * 0.06
		var point_a := Vector3(cos(angle_a) * size.x * 0.5 * radius_a, 0.0, sin(angle_a) * size.z * 0.5 * radius_a)
		var point_b := Vector3(cos(angle_b) * size.x * 0.5 * radius_b, 0.0, sin(angle_b) * size.z * 0.5 * radius_b)
		surface.set_uv(Vector2(0.5, 0.5))
		surface.add_vertex(Vector3.ZERO)
		surface.set_uv(Vector2(0.5 + point_b.x / maxf(size.x, 0.01), 0.5 + point_b.z / maxf(size.z, 0.01)))
		surface.add_vertex(point_b)
		surface.set_uv(Vector2(0.5 + point_a.x / maxf(size.x, 0.01), 0.5 + point_a.z / maxf(size.z, 0.01)))
		surface.add_vertex(point_a)
	var mesh := surface.commit()
	var visual := MeshInstance3D.new()
	visual.name = "IrregularGroundPatch"
	visual.mesh = mesh
	visual.material_override = material_for(part)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if static_visual_collecting:
		visual.transform = static_visual_part_transform
	parent.add_child(visual)
	visual_batch_count += 1


func publish_sack(part, parent: Node3D) -> void:
	var body := CylinderMesh.new()
	body.top_radius = 0.34
	body.bottom_radius = 0.48
	body.height = 0.72
	body.radial_segments = 10
	add_mesh_visual(parent, body, Vector3(part.size.x, part.size.y, part.size.z), Vector3(0.0, -part.size.y * 0.08, 0.0), material_for(part), "ClothSackBody")
	var shoulder := CylinderMesh.new()
	shoulder.top_radius = 0.22
	shoulder.bottom_radius = 0.38
	shoulder.height = 0.28
	shoulder.radial_segments = 10
	add_mesh_visual(parent, shoulder, Vector3(part.size.x * 0.86, part.size.y * 0.42, part.size.z * 0.86), Vector3(0.0, part.size.y * 0.31, 0.0), material_for(part), "ClothSackShoulder")
	add_box_visual(parent, Vector3(part.size.x * 0.28, part.size.y * 0.08, part.size.z * 0.28), Vector3(0.0, part.size.y * 0.47, 0.0), material_for_id("timber_board", variation_for(part) - 0.04), "SackTie")
	add_box_visual(parent, Vector3(part.size.x * 0.82, part.size.y * 0.08, part.size.z * 0.76), Vector3(0.0, -part.size.y * 0.45, 0.0), material_for(part), "SackSettledBase")


func publish_pottery(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var body := CylinderMesh.new()
	body.top_radius = 0.34
	body.bottom_radius = 0.47
	body.height = 0.78
	body.radial_segments = 12
	add_mesh_visual(parent, body, Vector3(size.x, size.y, size.z), Vector3(0.0, -size.y * 0.06, 0.0), material_for(part), "PotteryBody")
	var neck := CylinderMesh.new()
	neck.top_radius = 0.32
	neck.bottom_radius = 0.38
	neck.height = 0.24
	neck.radial_segments = 12
	add_mesh_visual(parent, neck, Vector3(size.x * 0.72, size.y * 0.34, size.z * 0.72), Vector3(0.0, size.y * 0.38, 0.0), material_for(part), "PotteryNeck")


func publish_basket(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var body := CylinderMesh.new()
	body.top_radius = 0.50
	body.bottom_radius = 0.40
	body.height = 0.62
	body.radial_segments = 12
	add_mesh_visual(parent, body, Vector3(size.x, size.y, size.z), Vector3(0.0, -size.y * 0.10, 0.0), material_for(part), "WovenBasketBody")
	var rim := TorusMesh.new()
	rim.inner_radius = 0.37
	rim.outer_radius = 0.50
	rim.rings = 12
	rim.ring_segments = 6
	add_mesh_visual(parent, rim, Vector3(size.x, size.y * 0.24, size.z), Vector3(0.0, size.y * 0.30, 0.0), material_for_id("timber_beam", variation_for(part) - 0.02), "BasketRim")
	for side in [-1.0, 1.0]:
		add_box_visual(parent, Vector3(size.x * 0.10, size.y * 0.72, size.z * 0.10), Vector3(side * size.x * 0.34, size.y * 0.28, 0.0), material_for_id("timber_beam", variation_for(part)), "BasketHandlePost")
	add_box_visual(parent, Vector3(size.x * 0.78, size.y * 0.10, size.z * 0.10), Vector3(0.0, size.y * 0.62, 0.0), material_for_id("timber_beam", variation_for(part)), "BasketHandle")


func publish_tool_rack(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	add_box_visual(parent, Vector3(size.x, 0.12, size.z), Vector3(0.0, size.y * 0.30, 0.0), material_for_id("timber_beam", variation_for(part)), "ToolRackRail")
	for tool_index in range(4):
		var x := -size.x * 0.36 + float(tool_index) * size.x * 0.24
		add_box_visual(parent, Vector3(0.065, size.y * (0.55 + float(tool_index % 2) * 0.14), 0.07), Vector3(x, -size.y * 0.03, -size.z * 0.10), material_for_id("ironwork", variation_for(part)), "HangingTool%02d" % tool_index)
		add_box_visual(parent, Vector3(0.22, 0.09, 0.08), Vector3(x, -size.y * (0.31 + float(tool_index % 2) * 0.06), -size.z * 0.10), material_for_id("ironwork", variation_for(part)), "ToolHead%02d" % tool_index)


func add_mesh_visual(parent: Node3D, mesh: Mesh, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
	var visual := MeshInstance3D.new()
	visual.name = node_name
	visual.mesh = mesh
	visual.position = position
	visual.scale = size
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if static_visual_collecting:
		visual.transform = static_visual_part_transform * visual.transform
	parent.add_child(visual)
	visual_batch_count += 1


func add_box_batch(parent: Node3D, transforms: Array, material: Material, node_name: String, custom_data_override: Array = []) -> MultiMeshInstance3D:
	if transforms.is_empty():
		return null
	var custom_data := custom_data_override if custom_data_override.size() == transforms.size() else build_batch_custom_data(transforms)
	if static_visual_collecting:
		for index in range(transforms.size()):
			var transform_value = transforms[index]
			if transform_value is Transform3D:
				collect_static_visual_transform(static_visual_part_transform * (transform_value as Transform3D), material, custom_data[index] as Color)
		return null
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_custom_data = true
	multi_mesh.instance_count = transforms.size()
	multi_mesh.mesh = unit_box
	for index in range(transforms.size()):
		var instance_transform := transforms[index] as Transform3D
		multi_mesh.set_instance_transform(index, instance_transform)
		multi_mesh.set_instance_custom_data(index, custom_data[index] as Color)
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multi_mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	visual_batch_count += 1
	return instance


func add_mesh_batch(parent: Node3D, mesh: Mesh, transforms: Array, material: Material, node_name: String, custom_data_override: Array = []) -> MultiMeshInstance3D:
	if transforms.is_empty() or mesh == null:
		return null
	var custom_data := custom_data_override if custom_data_override.size() == transforms.size() else build_batch_custom_data(transforms)
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_custom_data = true
	multi_mesh.instance_count = transforms.size()
	multi_mesh.mesh = mesh
	for index in range(transforms.size()):
		var instance_transform := transforms[index] as Transform3D
		if static_visual_collecting:
			instance_transform = static_visual_part_transform * instance_transform
		multi_mesh.set_instance_transform(index, instance_transform)
		multi_mesh.set_instance_custom_data(index, custom_data[index] as Color)
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multi_mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	if static_visual_collecting:
		published_nodes.append(instance)
	visual_batch_count += 1
	return instance


func build_batch_custom_data(transforms: Array) -> Array[Color]:
	var result: Array[Color] = []
	var min_y := INF
	var max_y := -INF
	for transform_value in transforms:
		if transform_value is Transform3D:
			var origin := (transform_value as Transform3D).origin
			min_y = minf(min_y, origin.y)
			max_y = maxf(max_y, origin.y)
	var height_range := max_y - min_y
	for index in range(transforms.size()):
		var instance_transform := transforms[index] as Transform3D
		var origin := instance_transform.origin
		var stable_piece_tint := fposmod(sin(origin.x * 12.9898 + origin.y * 78.233 + origin.z * 37.719 + float(index) * 0.173) * 43758.5453, 1.0)
		var normalized_height := clampf((origin.y - min_y) / height_range, 0.0, 1.0) if height_range > 0.001 else 0.5
		var exposure := fposmod(sin(origin.x * 23.417 + origin.y * 7.913 + origin.z * 51.173 + float(index) * 0.271) * 19642.349, 1.0)
		result.append(Color(stable_piece_tint, normalized_height, exposure, 1.0))
	return result


func add_box_visual(parent: Node3D, size: Vector3, position: Vector3, material: Material, node_name: String) -> void:
	if static_visual_collecting:
		collect_static_visual_transform(static_visual_part_transform * box_transform(position, size), material, Color(0.5, 0.5, 0.5, 1.0))
		return
	var visual := MeshInstance3D.new()
	visual.name = node_name
	visual.mesh = unit_box
	visual.position = position
	visual.scale = size
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(visual)
	visual_batch_count += 1


func collect_static_visual_transform(transform: Transform3D, material: Material, custom_data := Color(0.5, 0.5, 0.5, 1.0)) -> void:
	if material == null:
		return
	var key := str(material.get_instance_id())
	var group: Dictionary = static_visual_batches.get(key, {}) if static_visual_batches.get(key, {}) is Dictionary else {}
	if group.is_empty():
		group = {"material": material, "transforms": [], "customData": []}
	var transforms: Array = group.get("transforms", []) as Array
	var custom_data_values: Array = group.get("customData", []) as Array
	transforms.append(transform)
	custom_data_values.append(custom_data)
	group["transforms"] = transforms
	group["customData"] = custom_data_values
	static_visual_batches[key] = group


func flush_static_batches(parent: Node3D) -> void:
	if static_visual_batches.is_empty() or parent == null:
		return
	var keys := static_visual_batches.keys()
	keys.sort()
	for key_value in keys:
		var group: Dictionary = static_visual_batches.get(key_value, {}) as Dictionary
		var transforms: Array = group.get("transforms", []) as Array
		var custom_data_values: Array = group.get("customData", []) as Array
		var material := group.get("material") as Material
		var instance := add_box_batch(parent, transforms, material, "ConstructionStaticVisualBatch", custom_data_values)
		if instance != null:
			published_nodes.append(instance)
	if static_collision_body != null and is_instance_valid(static_collision_body):
		static_collision_body.set_meta("building_part_records", static_part_records.duplicate(true))
	static_visual_batches.clear()


func publish_navigation_manifest(blueprint, parent: Node3D) -> void:
	# Navigation facts are derived from BuildingPart source records immediately
	# after their collision publication.  The manifest is intentionally data-only
	# so navigation can consume it without parsing meshes or inventing supports.
	building_navigation_manifest = BuildingNavigationManifestBuilderScript.build(blueprint, parent.global_transform)
	parent.set_meta("building_navigation_manifest", building_navigation_manifest.duplicate(true))
	if static_collision_body != null and is_instance_valid(static_collision_body):
		static_collision_body.set_meta("building_navigation_manifest", building_navigation_manifest.duplicate(true))


func box_transform(position: Vector3, size: Vector3) -> Transform3D:
	return Transform3D(Basis.from_scale(size), position)


func oriented_box_transform(position: Vector3, size: Vector3, yaw: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(size), position)


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
		"publishedPartCount": published_part_count,
		"publishedNodeCount": published_nodes.size(),
		"collisionPartCount": collision_count,
		"visualBatchCount": visual_batch_count,
		"batchedStaticParts": batch_static_parts,
		"staticRecordCount": static_part_records.size(),
		"navigationSupportCount": int(building_navigation_manifest.get("supportCount", 0)),
		"navigationVerticalLinkCount": int(building_navigation_manifest.get("verticalLinkCount", 0)),
		"navigationSupportSeamLinkCount": int(building_navigation_manifest.get("supportSeamLinkCount", 0)),
		"navigationInteriorPassageLinkCount": int(building_navigation_manifest.get("interiorPassageLinkCount", 0)),
		"navigationManifest": building_navigation_manifest.duplicate(true),
		"recipeBuildUsec": recipe_build_usec,
		"publicationUsec": publication_usec
	}
