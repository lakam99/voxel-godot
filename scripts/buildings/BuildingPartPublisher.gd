extends RefCounted
class_name BuildingPartPublisher

## Scene publication for material-aware construction parts. It intentionally
## consumes only BuildingPart data: the visual recipe and collision shape share
## one record, and board/brick detail is instanced per parent part.

const ConstructionMaterialCatalogScript := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const SurfaceHistoryFieldScript := preload("res://scripts/buildings/SurfaceHistoryField.gd")
const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const BuildingGoodsGeometryScript := preload("res://scripts/buildings/BuildingGoodsGeometry.gd")
const BuildingDoorGeometryScript := preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const SettledCobbleGeometryScript := preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const PavingFootingAssemblyScript := preload("res://scripts/buildings/PavingFootingAssemblyRecipe.gd")
const MasonryWallGeometryScript := preload("res://scripts/buildings/MasonryWallGeometry.gd")
const MasonryAperturePublicationScript := preload("res://scripts/buildings/MasonryAperturePublication.gd")
const MAX_JOINTED_FINISHES := 4
const MAX_JOINTED_FEET := 16
const INCREMENTAL_STATIC_BATCH_INSTANCE_LIMIT := 12000
const MONUMENTAL_MASONRY_INSTANCE_BUDGET := 2400
# Temporary user-authorized bypass on the visuals branch (2026-08-30).
# Keep actual failures in reports; rendering does not certify structural safety.
const PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION := false

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
var static_visual_transform_count := 0
var incremental_progress_callback: Callable
var incremental_total_parts := 0
var incremental_published_parts := 0
var incremental_static_flush_count := 0
var paving_treatments: Array = []
var surface_history := SurfaceHistoryFieldScript.new()
var masonry_repair_clusters: Array[Dictionary] = []
var physical_integrity: Dictionary = {}
var raised_route_coverage: Dictionary = {}
var active_publication_started_usec := 0
var _paving_artifacts: Dictionary = {}
var _paving_source_parts: Dictionary = {}
var _paving_blueprint = null
var _paving_binding := PackedByteArray()
var _paving_history_binding := PackedByteArray()
var _paving_failure := ""
var _paving_prepared := false
var _paving_complete := false
var _masonry_preparation


func _init() -> void:
	unit_box = BoxMesh.new()
	unit_box.size = Vector3.ONE


func publish(blueprint, parent: Node3D, options: Dictionary = {}) -> Dictionary:
	if not begin_publication(blueprint, parent, options):
		return summary()
	while _masonry_preparation.state == "pending_budget":
		_masonry_preparation.advance(self)
	if _masonry_preparation.state != "ready": return summary()
	publish_part_batch(blueprint, parent, 0, blueprint.parts.size())
	return finish_publication(blueprint, parent)


func publish_incremental(blueprint, parent: Node3D, parts_per_frame := 6, options: Dictionary = {}) -> Dictionary:
	# Uses the same part records and publish_part path as synchronous publication.
	# Consumers with an on-screen loading state can spread a larger blueprint over
	# frames without inventing a second visual/collision publication authority.
	if not begin_publication(blueprint, parent, options):
		return summary()
	while _masonry_preparation.state == "pending_budget":
		_masonry_preparation.advance(self)
		report_incremental_progress("masonry_preparation")
		if _masonry_preparation.state == "pending_budget": await parent.get_tree().process_frame
	if _masonry_preparation.state != "ready": return summary()
	var frame_budget := maxi(1, parts_per_frame)
	var part_index := 0
	while part_index < blueprint.parts.size():
		part_index = publish_part_batch(blueprint, parent, part_index, frame_budget)
		if _publication_failed(): return summary()
		if part_index < blueprint.parts.size():
			report_incremental_progress("frame_budget")
			await parent.get_tree().process_frame
	return finish_publication(blueprint, parent)


func begin_publication(blueprint, parent: Node3D, options: Dictionary = {}) -> bool:
	clear_published()
	if blueprint == null or parent == null:
		return false
	raised_route_coverage = CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(blueprint)
	# Citadel route-publication requirements are retired on this visuals branch.
	# Keep the real diagnostic (including failures) without making it a renderer
	# prerequisite. Physical integrity is temporarily diagnostic-only by request.
	var structural_authority = options.get("structuralAuthorityBlueprint", blueprint)
	physical_integrity = structural_authority.validate_physical_integrity() if structural_authority != null and structural_authority.has_method("validate_physical_integrity") else {"passed": true, "checkedPartCount": 0, "checks": [], "violations": []}
	if PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION and not bool(physical_integrity.get("passed", false)):
		push_error("Building publication blocked by invalid physical recipe: %s" % JSON.stringify(physical_integrity.get("violations", [])))
		return false
	configure_publication_options(options)
	incremental_total_parts = blueprint.parts.size()
	incremental_published_parts = 0
	incremental_static_flush_count = 0
	source_blueprint_id = canonical_source_blueprint_id(blueprint)
	paving_treatments = blueprint.recipe.get("pavingTreatments", []) as Array
	surface_history.configure(blueprint.recipe, blueprint.parts)
	if not _prepare_paving_publication(blueprint): return false
	if not prepare_masonry_apertures(blueprint): return false
	active_publication_started_usec = Time.get_ticks_usec()
	return true


func publish_part_batch(blueprint, parent: Node3D, start_index: int, max_parts: int) -> int:
	if blueprint == null or parent == null:
		return start_index
	if not _paving_session_valid(blueprint): return start_index
	if _masonry_preparation != null and _masonry_preparation.state == "pending_budget":
		_masonry_preparation.advance(self)
		if _masonry_preparation.state != "ready": return start_index
	if _publication_failed(): return start_index
	var part_index := clampi(start_index, 0, blueprint.parts.size())
	var processed := 0
	while part_index < blueprint.parts.size() and processed < maxi(1, max_parts):
		var part = blueprint.parts[part_index]
		part_index += 1
		processed += 1
		if part == null:
			continue
		publish_part(part, parent)
		if _publication_failed(): return part_index - 1
		incremental_published_parts += 1
		if batch_static_parts and static_visual_transform_count >= INCREMENTAL_STATIC_BATCH_INSTANCE_LIMIT:
			flush_static_batches(parent)
			report_incremental_progress("static_batch_flush")
	return part_index


func finish_publication(blueprint, parent: Node3D) -> Dictionary:
	if blueprint == null or parent == null:
		return summary()
	if not _paving_session_valid(blueprint): return summary()
	if _masonry_preparation != null and (_masonry_preparation.state != "ready" or not _masonry_preparation._validate_all(self)): return summary()
	flush_static_batches(parent)
	report_incremental_progress("complete")
	publication_usec = Time.get_ticks_usec() - active_publication_started_usec if active_publication_started_usec > 0 else 0
	active_publication_started_usec = 0
	_paving_complete = incremental_published_parts == incremental_total_parts
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
	static_visual_transform_count = 0
	incremental_total_parts = 0
	incremental_published_parts = 0
	incremental_static_flush_count = 0
	paving_treatments.clear()
	surface_history.configure({})
	masonry_repair_clusters.clear()
	physical_integrity.clear()
	raised_route_coverage.clear()
	active_publication_started_usec = 0
	_paving_artifacts.clear()
	_paving_source_parts.clear()
	_paving_blueprint = null
	_paving_binding.clear()
	_paving_history_binding.clear()
	_paving_failure = ""
	_paving_prepared = false
	_paving_complete = false
	_masonry_preparation = null


func configure_publication_options(options: Dictionary) -> void:
	batch_static_parts = bool(options.get("batchStaticParts", false))
	var callback_value = options.get("progressCallback")
	incremental_progress_callback = callback_value as Callable if callback_value is Callable else Callable()


func canonical_source_blueprint_id(blueprint) -> String:
	var result := String(blueprint.id) if blueprint != null else ""
	if blueprint != null and blueprint.recipe is Dictionary:
		result = String((blueprint.recipe as Dictionary).get("sourceBlueprintId", result))
	return result




func publish_part(part, parent: Node3D) -> StaticBody3D:
	if not _paving_part_valid(part): return null
	if not _masonry_part_valid(part): return null
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
		collision.set_meta("building_semantic", part.semantic)
		collision.set_meta("building_collision_role", "blocking_part")
		body.add_child(collision)
		collision_count += 1
	# Some construction records are collision stringers beneath richer generated
	# geometry (for example a stair flight's visible treads).  They remain normal
	# source parts with real collision, but do not duplicate the finished visual.
	if bool(part.recipe.get("visual", true)):
		publish_visual(part, body)
	if bool(part.recipe.get("practicalLight", false)):
		publish_practical_light(part, body)
	if String(part.kind) == "door":
		add_door_interaction_proxy(body, part)
	recipe_build_usec += Time.get_ticks_usec() - started
	return body


func publish_static_part(part, parent: Node3D) -> void:
	if not _paving_part_valid(part): return
	if not _masonry_part_valid(part): return
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
		collision.set_meta("building_semantic", part.semantic)
		collision.set_meta("building_collision_role", "blocking_part")
		collision.position = part.position
		collision.rotation = part.rotation
		collision_body.add_child(collision)
		static_part_records[String(part.id)] = part.snapshot()
		collision_count += 1
	if bool(part.recipe.get("visual", true)):
		static_visual_collecting = true
		static_visual_part_transform = Transform3D(Basis.from_euler(part.rotation), part.position)
		publish_visual(part, parent)
		if bool(part.recipe.get("practicalLight", false)):
			publish_practical_light(part, parent)
		static_visual_collecting = false
		static_visual_part_transform = Transform3D.IDENTITY
	elif bool(part.recipe.get("practicalLight", false)):
		static_visual_collecting = true
		static_visual_part_transform = Transform3D(Basis.from_euler(part.rotation), part.position)
		publish_practical_light(part, parent)
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
	if not _paving_part_valid(part): return
	if not _masonry_part_valid(part): return
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


func publish_practical_light(part, parent: Node3D) -> void:
	var light := OmniLight3D.new()
	light.name = "RecipePracticalLight_%s" % String(part.id)
	light.light_color = Color(1.0, 0.58, 0.30)
	light.light_energy = float(part.recipe.get("lightEnergy", 1.5))
	light.omni_range = float(part.recipe.get("lightRange", 5.0))
	light.shadow_enabled = light.light_energy >= 1.70
	if static_visual_collecting:
		light.position = static_visual_part_transform.origin
	parent.add_child(light)


func publish_timber_wall(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var row_height := 0.34
	var rows := maxi(1, ceili(size.y / row_height))
	var transforms: Array[Transform3D] = []
	var weathered_transforms: Array[Transform3D] = []
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
				var conditions := surface_history.conditions_at(part.position + position)
				var weathered := float(conditions.get("runoff", 0.0)) > 0.44
				if weathered:
					position[depth_axis] -= 0.014 + piece_phase * 0.016
					board_size.y *= lerpf(0.935, 0.985, piece_phase)
				var settlement_axis := Vector3.FORWARD if horizontal_axis == 0 else Vector3.RIGHT
				var settlement := (piece_phase - 0.5) * deg_to_rad(0.72)
				var transform := Transform3D(Basis(settlement_axis, settlement).scaled(board_size), position)
				if weathered:
					weathered_transforms.append(transform)
				else:
					transforms.append(transform)
			cursor += nominal_length
			column += 1
	add_box_batch(parent, transforms, material_for(part), "PlankCladding", build_facade_custom_data(transforms, part))
	if not weathered_transforms.is_empty():
		add_box_batch(parent, weathered_transforms, weathered_timber_material_for(part), "WeatheredPlankCladding", build_facade_custom_data(weathered_transforms, part))


func publish_aged_timber_beam(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	# Load-bearing joinery can opt into a straight profile: cosmetic segment
	# bending must not pull visible bearing faces away from their real seats.
	# Keep the same material and facade-condition custom-data pipeline.
	var preserve_faces = part.recipe.get("preserveBearingFaces", false)
	if preserve_faces is bool and preserve_faces:
		var joined: Array[Transform3D] = [box_transform(Vector3.ZERO, size)]
		add_box_batch(parent, joined, material_for(part), "BearingTimber", build_facade_custom_data(joined, part))
		return
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
	add_box_batch(parent, transforms, material_for(part), "AgedTimberSegments", build_facade_custom_data(transforms, part))


func publish_brick_wall(part, parent: Node3D) -> void:
	if not _masonry_part_valid(part): return
	var artifact: Dictionary = _masonry_preparation.artifact(part) if _masonry_preparation != null else {}
	var geometry: Dictionary = artifact.geometry if not artifact.is_empty() else describe_masonry(part)
	var size: Vector3 = part.size
	var bed_material := material_for_id("mortar", variation_for(part) - 0.035)
	add_box_visual(parent, geometry.mortarSize, Vector3.ZERO, bed_material, "MasonryBed")
	var top_surface_material := String(part.recipe.get("topSurfaceMaterial", ""))
	if String(part.kind) == "foundation" and not top_surface_material.is_empty():
		add_box_visual(parent, Vector3(maxf(0.08, size.x - 0.05), 0.028, maxf(0.08, size.z - 0.05)), Vector3(0.0, size.y * 0.5 + 0.014, 0.0), material_for_id(top_surface_material, variation_for(part) - 0.025), "FoundationTopSurface")
	var repair_profile: Dictionary = geometry.repairProfile
	if not repair_profile.is_empty():
		masonry_repair_clusters.append({"partId": String(part.id), "face": int(repair_profile.get("face", -1)), "centerY": float(repair_profile.get("centerY", 0.5)), "centerAlong": float(repair_profile.get("centerAlong", 0.5)), "radiusY": float(repair_profile.get("radiusY", 0.0)), "radiusAlong": float(repair_profile.get("radiusAlong", 0.0))})
	var surface_material := material_for_id(geometry.surfaceMaterialId, masonry_family_variation(part))
	if artifact.is_empty(): add_box_batch(parent, geometry.regularTransforms, surface_material, "BrickCourses", geometry.regularCustomData)
	else: _publish_masonry_group(parent, artifact, "regular", surface_material, "BrickCourses")
	if not geometry.repairTransforms.is_empty():
		var repair_material := masonry_repair_material_for(part, geometry.surfaceMaterialId)
		if artifact.is_empty(): add_box_batch(parent, geometry.repairTransforms, repair_material, "MasonryRepairCourses", geometry.repairCustomData)
		else: _publish_masonry_group(parent, artifact, "repair", repair_material, "MasonryRepairCourses")


func prepare_masonry_apertures(blueprint) -> bool:
	_masonry_preparation = MasonryAperturePublicationScript.new()
	return _masonry_preparation.begin(blueprint, self)


func _publication_failed() -> bool:
	return not _paving_failure.is_empty() or (_masonry_preparation != null and _masonry_preparation.state == "failed")


func _masonry_part_valid(part) -> bool:
	if _publication_failed(): return false
	if _masonry_preparation != null and _masonry_preparation.state == "pending_budget": return false
	if _masonry_preparation != null and not _masonry_preparation.validate_unit_source(self): return false
	if _masonry_preparation != null and not _masonry_preparation.accepts_source_member(part): return false
	var required: bool = part.recipe.has("masonryApertureSource") or (_masonry_preparation != null and _masonry_preparation.owns(part))
	if not required: return true
	if _masonry_preparation == null:
		_masonry_preparation = MasonryAperturePublicationScript.new()
		return _masonry_preparation._fail("unprepared_direct_masonry_publication")
	return _masonry_preparation.ready_for(part, self)


func _publish_masonry_group(parent: Node3D, artifact: Dictionary, group: String, material: Material, label: String) -> void:
	var transforms: Array = []
	var custom: Array = []
	for entry: Dictionary in artifact.entries:
		if entry.original.group != group: continue
		if entry.unchanged:
			transforms.append(entry.original.localTransform)
			custom.append(entry.original.customData)
			continue
		if not transforms.is_empty():
			add_box_batch(parent, transforms, material, label, custom)
			transforms = []
			custom = []
		var prepared: Dictionary = artifact.preparedMeshes[entry.original.id]
		if prepared.mesh != null:
			add_mesh_batch(parent, prepared.mesh, [entry.original.localTransform], material, label, [entry.original.customData])
	if not transforms.is_empty(): add_box_batch(parent, transforms, material, label, custom)


func describe_masonry(part) -> Dictionary:
	# One descriptor path for actual publication and recipe aperture construction.
	# Keep the existing course arithmetic, instance order and custom data exact.
	var size: Vector3 = part.size
	var transforms: Array[Transform3D] = []
	var repair_flags: Array[bool] = []
	var material_id := String(part.material_id)
	var is_monumental_geometry := String(part.id).begins_with("castle_")
	var uses_aged_castle_stone := is_monumental_geometry and material_id == "stone_foundation"
	var is_rubble_foundation := material_id == "stone_foundation" and not is_monumental_geometry
	var unit_length := 1.18 if is_monumental_geometry else (0.88 if is_rubble_foundation else 0.68)
	var unit_height := 0.52 if is_monumental_geometry else (0.38 if is_rubble_foundation else 0.285)
	if is_monumental_geometry:
		var estimated_instances := 2.0 * (size.x + size.z) * size.y / maxf(unit_length * unit_height, 0.001)
		if estimated_instances > float(MONUMENTAL_MASONRY_INSTANCE_BUDGET):
			var density_scale := sqrt(estimated_instances / float(MONUMENTAL_MASONRY_INSTANCE_BUDGET))
			unit_length *= density_scale
			unit_height *= density_scale
	var joint_width := 0.018 if is_monumental_geometry else (0.030 if is_rubble_foundation else 0.022)
	var face_depth := 0.105 if is_monumental_geometry else (0.11 if is_rubble_foundation else 0.075)
	# Mortar is published by the same part record, behind the physical brick
	# instances. Its thin axis is inset on both faces, so it cannot z-fight with
	# a brick surface while course gaps remain a material fact rather than a
	# texture.
	var mortar_size := MasonryWallGeometryScript.bed_size(size)
	var masonry_phase := float(posmod(String(part.id).hash(), 1009)) / 1009.0
	var repair_profile := masonry_repair_profile(part)
	append_brick_face_transforms(transforms, repair_flags, size, true, -1.0, unit_length, unit_height, joint_width, face_depth, masonry_phase, repair_profile, 0)
	append_brick_face_transforms(transforms, repair_flags, size, true, 1.0, unit_length, unit_height, joint_width, face_depth, masonry_phase, repair_profile, 1)
	append_brick_face_transforms(transforms, repair_flags, size, false, -1.0, unit_length, unit_height, joint_width, face_depth, masonry_phase, repair_profile, 2)
	append_brick_face_transforms(transforms, repair_flags, size, false, 1.0, unit_length, unit_height, joint_width, face_depth, masonry_phase, repair_profile, 3)
	var regular_transforms: Array[Transform3D] = []
	var repair_transforms: Array[Transform3D] = []
	for index in range(transforms.size()):
		var transform := transforms[index]
		if repair_flags[index]:
			repair_transforms.append(transform)
		else:
			regular_transforms.append(transform)
	var surface_material_id := "aged_castle_stone" if uses_aged_castle_stone else material_id
	var regular_custom_data := build_masonry_custom_data(regular_transforms, part)
	var repair_custom_data: Array[Color] = []
	if not repair_transforms.is_empty():
		var repair_custom_flags: Array[bool] = []
		repair_custom_flags.resize(repair_transforms.size())
		repair_custom_flags.fill(true)
		repair_custom_data = build_masonry_custom_data(repair_transforms, part, repair_custom_flags, repair_profile)
	return {"mortarSize": mortar_size, "regularTransforms": regular_transforms, "repairTransforms": repair_transforms,
		"regularCustomData": regular_custom_data, "repairCustomData": repair_custom_data,
		"surfaceMaterialId": surface_material_id, "repairProfile": repair_profile}


func masonry_brick_solids(part, geometry: Dictionary) -> Array:
	# Stable source identities describe the actual native unit-box instances.
	# Group-local ordinals are not old/new correspondence after re-coursing.
	var result: Array = []
	var frame := Transform3D(Basis.from_euler(part.rotation), part.position)
	for group: String in ["regular", "repair"]:
		var transforms: Array = geometry[group + "Transforms"]
		var custom: Array = geometry[group + "CustomData"]
		var material_key := "%s:%0.3f" % [geometry.surfaceMaterialId, masonry_family_variation(part)]
		if group == "repair": material_key = "masonry_repair:" + material_key
		for index in range(transforms.size()):
			result.append({"id": "%s:%s:%d" % [part.id, group, index], "group": group, "ordinal": index,
				"materialKey": material_key, "surfaceMaterialId": geometry.surfaceMaterialId, "customData": custom[index],
				"localTransform": transforms[index], "transform": frame * transforms[index]})
	return result


func publish_settled_cobble(part, parent: Node3D) -> void:
	if not _paving_part_valid(part): return
	if part.recipe.has("pavingFootingJoints"):
		_publish_jointed_paving(part, parent)
		return
	var geometry: Dictionary = SettledCobbleGeometryScript.describe_source(part, surface_history, source_blueprint_id)
	var bed: Dictionary = geometry.bed
	add_box_visual(parent, bed.size, bed.position, material_for_id(bed.materialId, variation_for(part) - 0.025), "CobbleJointBed")
	add_mesh_batch(parent, unit_box, geometry.regularTransforms, material_for(part), "SettledCobbleStones", geometry.regularCustomData)
	if not geometry.wornTransforms.is_empty():
		add_mesh_batch(parent, unit_box, geometry.wornTransforms, material_for_id("worn_cobble", variation_for(part) - 0.016), "WornSettledCobbleStones", geometry.wornCustomData)


func _paving_reject(reason: String) -> bool:
	if _paving_failure.is_empty(): _paving_failure = reason
	_paving_complete = false
	return false


func _prepare_paving_publication(b) -> bool:
	var finishes: Array = []
	for part in b.parts:
		if part != null and part.recipe.has("pavingFootingJoints"): finishes.append(part)
	# Preserve the legacy source/material path when no declaration is present.
	if finishes.is_empty(): return true
	if b.parts.size() > 10000 or finishes.size() > MAX_JOINTED_FINISHES: return _paving_reject("paving_collection_limit")
	var by_id: Dictionary = {}
	for part in b.parts:
		if part == null or part.id.is_empty() or by_id.has(part.id): return _paving_reject("paving_invalid_source_ids")
		by_id[part.id] = part
	var requests: Array = []
	var all_feet: Dictionary = {}
	# Validate ALL declarations and aggregate limits before any mesh preparation.
	for finish in finishes:
		var declaration: Variant = finish.recipe.pavingFootingJoints
		if not declaration is Dictionary or declaration.size() != 4 or not declaration.get("footPartIds") is Array or not (declaration.get("nominalJoint") is float or declaration.get("nominalJoint") is int): return _paving_reject("paving_invalid_declaration")
		for key in ["geometryDigest", "constructionDigest"]:
			if not declaration.get(key) is String or declaration[key].length() != 64 or not declaration[key].is_valid_hex_number(false): return _paving_reject("paving_invalid_committed_digest")
		var joint: float = declaration.nominalJoint
		if not is_finite(joint) or joint <= 0.0 or joint > PavingFootingAssemblyScript.FootCuts.MAX_JOINT or declaration.footPartIds.is_empty() or declaration.footPartIds.size() > MAX_JOINTED_FEET: return _paving_reject("paving_invalid_joint_or_feet")
		if finish.collision_enabled or finish.kind != "foundation" or not ConstructionMaterialCatalogScript.is_cobble_material(finish.material_id) or finish.recipe.get("visual", true) != true: return _paving_reject("paving_requires_visible_noncollision_finish")
		var feet: Array = []
		var seen: Dictionary = {}
		for id in declaration.footPartIds:
			if not id is String or id.is_empty() or id == finish.id or seen.has(id) or not by_id.has(id): return _paving_reject("paving_unresolved_or_duplicate_foot")
			seen[id] = true
			all_feet[id] = true
			feet.append(by_id[id])
		if all_feet.size() > MAX_JOINTED_FEET: return _paving_reject("paving_total_foot_limit")
		requests.append({"finish": finish, "feet": feet, "joint": joint})
	for request in requests:
		_paving_source_parts[request.finish.id] = request.finish
		for foot in request.feet: _paving_source_parts[foot.id] = foot
	_paving_blueprint = b
	var binding: PackedByteArray = _paving_source_binding(b)
	if binding.is_empty(): return _paving_reject("paving_invalid_source_binding")
	var staged: Dictionary = {}
	for request in requests:
		var result: Dictionary = PavingFootingAssemblyScript.prepare(b, [request.finish.id], request.feet, request.joint)
		if not bool(result.get("ready", false)): return _paving_reject("paving_prepare:" + String(result.get("reason", "unknown")))
		if not result.get("joints") is Dictionary or not result.joints.has(request.finish.id) or var_to_bytes(result.joints[request.finish.id]) != var_to_bytes(request.finish.recipe.pavingFootingJoints): return _paving_reject("paving_committed_geometry_mismatch")
		if not result.get("artifacts") is Dictionary or result.artifacts.size() != 1 or not result.artifacts.has(request.finish.id): return _paving_reject("paving_missing_finalized_artifact")
		var artifact: Dictionary = result.artifacts[request.finish.id]
		if not _paving_artifact_valid(artifact, request.finish): return _paving_reject("paving_invalid_finalized_artifact")
		staged[request.finish.id] = {"artifact": artifact, "sourceBinding": binding}
	if binding != _paving_source_binding(b): return _paving_reject("paving_preparation_mutated_source")
	_paving_artifacts = staged
	_paving_binding = binding
	_paving_history_binding = _paving_history_identity()
	_paving_prepared = true
	return true


func _paving_source_binding(b) -> PackedByteArray:
	if b == null or b.parts.size() > 10000: return PackedByteArray()
	var ids: Dictionary = {}
	var records: Array = []
	for part in b.parts:
		if part == null or part.id.is_empty() or ids.has(part.id): return PackedByteArray()
		ids[part.id] = true
		if _paving_source_parts.has(part.id) and _paving_source_parts[part.id] != part: return PackedByteArray()
		# These are exactly the part families consumed by History.configure.
		# Recipe is retained in full, including canonical ID, routes and trees.
		if _paving_source_parts.has(part.id) or part.recipe.has("pavingFootingJoints") or part.kind in ["door", "window"] or part.semantic.contains("eave") or bool(part.recipe.get("weatheringEave", false)):
			records.append(part.snapshot())
	for id in _paving_source_parts:
		if not ids.has(id): return PackedByteArray()
	return var_to_bytes([canonical_source_blueprint_id(b), b.recipe, ids.keys(), records])


func _paving_session_valid(b) -> bool:
	if not _paving_failure.is_empty(): return false
	if _paving_blueprint == null: return true
	if not _paving_prepared or b != _paving_blueprint or source_blueprint_id != canonical_source_blueprint_id(b) or _paving_binding != _paving_source_binding(b) or _paving_history_binding != _paving_history_identity(): return _paving_reject("paving_stale_preparation")
	return true


func _paving_history_identity() -> PackedByteArray:
	return var_to_bytes([surface_history.route_corridors, surface_history.tree_placements, surface_history.history_events, surface_history.history_event_cells])


func _paving_part_valid(part) -> bool:
	if not _paving_failure.is_empty(): return false
	# Feet have no finish artifact, but their exact source identity/pose owns the
	# aperture. Also recognize retained objects whose ID was changed after begin.
	var bound: bool = _paving_source_parts.has(part.id) or _paving_source_parts.find_key(part) != null
	var needs_artifact: bool = part.recipe.has("pavingFootingJoints") or _paving_artifacts.has(part.id)
	if not bound and not needs_artifact: return true
	if not _paving_prepared or _paving_source_parts.get(part.id) != part or (needs_artifact and not _paving_artifacts.has(part.id)): return _paving_reject("paving_unprepared_direct_publication")
	if not _paving_session_valid(_paving_blueprint): return false
	return true


func _paving_artifact_valid(artifact: Dictionary, part) -> bool:
	if artifact.get("completed") != true or artifact.get("stage") != "represented_publication_geometry" or not artifact.get("entries") is Array or artifact.entries.is_empty() or artifact.entries.size() > 8192: return false
	var source_transform: Transform3D = Transform3D(Basis.from_euler(part.rotation), part.position)
	if artifact.get("sourceTransform") != source_transform: return false
	var group_index: int = 0
	var ordinal: int = 0
	for entry in artifact.entries:
		if not entry is Dictionary or not entry.get("original") is Dictionary or not entry.get("unchanged") is bool: return false
		var original: Dictionary = entry.original
		var next_group: int = ["bed", "regular", "worn"].find(original.get("group"))
		if next_group < group_index or next_group < 0: return false
		if next_group != group_index:
			group_index = next_group
			ordinal = 0
		if original.get("ordinal") != ordinal or not original.get("localTransform") is Transform3D or original.get("transform") != source_transform * original.localTransform: return false
		ordinal += 1
		if group_index == 0:
			if ordinal != 1 or original.get("customData") != null or not original.get("materialKey") is String: return false
		elif not original.get("customData") is Color: return false
		if not entry.unchanged:
			if not entry.has("mesh") or not entry.get("cells") is Array: return false
			if entry.mesh == null:
				if not entry.cells.is_empty(): return false
			elif not entry.mesh is ArrayMesh or entry.mesh.get_surface_count() != 1: return false
	return artifact.entries[0].original.group == "bed"


func _publish_jointed_paving(part, parent: Node3D) -> void:
	var artifact: Dictionary = _paving_artifacts[part.id].artifact
	# No geometry recomputation or world-to-local round trip here. Artifacts are
	# privately owned after preparation and never supplied through source caches.
	var bed: Dictionary = artifact.entries[0]
	var local: Transform3D = bed.original.localTransform
	var bed_material: Material = material_for_id(bed.original.materialKey, variation_for(part) - 0.025)
	if bed.unchanged:
		add_box_visual(parent, Vector3(local.basis.x.x, local.basis.y.y, local.basis.z.z), local.origin, bed_material, "CobbleJointBed")
	elif bed.mesh != null:
		if static_visual_collecting:
			add_mesh_batch(parent, bed.mesh, [local], bed_material, "CobbleJointBed", [Color(0.5, 0.5, 0.5, 1.0)])
		else:
			add_mesh_visual(parent, bed.mesh, Vector3(local.basis.x.x, local.basis.y.y, local.basis.z.z), local.origin, bed_material, "CobbleJointBed")
	# Keep the original material evaluation order, including an empty regular
	# group and fully removed entries; never warm a new material during prepare.
	var regular_material: Material = material_for(part)
	for group in ["regular", "worn"]:
		var entries: Array = artifact.entries.filter(func(entry): return entry.original.group == group)
		if entries.is_empty(): continue
		var material: Material = regular_material if group == "regular" else material_for_id("worn_cobble", variation_for(part) - 0.016)
		var label: String = "SettledCobbleStones" if group == "regular" else "WornSettledCobbleStones"
		var transforms: Array = []
		var custom: Array = []
		for entry in entries:
			if entry.unchanged:
				transforms.append(entry.original.localTransform)
				custom.append(entry.original.customData)
				continue
			if not transforms.is_empty():
				add_mesh_batch(parent, unit_box, transforms, material, label, custom)
				transforms = []
				custom = []
			if entry.mesh != null:
				add_mesh_batch(parent, entry.mesh, [entry.original.localTransform], material, label, [entry.original.customData])
		if not transforms.is_empty(): add_mesh_batch(parent, unit_box, transforms, material, label, custom)


func paving_family_for(part) -> String:
	return SettledCobbleGeometryScript.family_for(part)


func paving_runs_along_x(part) -> bool:
	return SettledCobbleGeometryScript.runs_along_x(part)


func paving_region_phase(part) -> float:
	return SettledCobbleGeometryScript.region_phase(part, source_blueprint_id)


func paving_treatment_strength(world_position: Vector3) -> float:
	return float(surface_history.wear_contact_at(world_position).get("influence", 0.0))


func build_masonry_custom_data(transforms: Array[Transform3D], part, repair_flags: Array[bool] = [], repair_profile: Dictionary = {}) -> Array[Color]:
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
		var repair_cluster := repair_flags.size() == transforms.size() and repair_flags[index]
		result.append(history_custom_data(part.position + origin))
	return result


func build_facade_custom_data(transforms: Array[Transform3D], part) -> Array[Color]:
	var result: Array[Color] = []
	var min_y := INF
	var max_y := -INF
	for transform in transforms:
		min_y = minf(min_y, transform.origin.y)
		max_y = maxf(max_y, transform.origin.y)
	var height_range := maxf(0.001, max_y - min_y)
	var seed_phase := float(posmod(String(part.id).hash(), 4093)) / 4093.0
	for index in range(transforms.size()):
		var origin := transforms[index].origin
		var height := clampf((origin.y - min_y) / height_range, 0.0, 1.0)
		var stable := fposmod(sin(origin.x * 17.13 + origin.y * 43.77 + origin.z * 11.91 + seed_phase * 97.0) * 31757.13, 1.0)
		result.append(history_custom_data(part.position + origin))
	return result


func history_custom_data(world_position: Vector3) -> Color:
	var conditions := surface_history.conditions_at(world_position)
	var wear_contact := surface_history.wear_contact_at(world_position)
	var route_use := float(wear_contact.get("influence", 0.0))
	var route_lateral := float(wear_contact.get("lateral", 1.0))
	return Color(
		clampf(float(conditions.get("runoff", 0.0)), 0.0, 1.0),
		pack_route_history(route_use, route_lateral),
		clampf(float(conditions.get("rootDisturbance", 0.0)), 0.0, 1.0),
		clampf(float(conditions.get("canopyDeposit", 0.0)), 0.0, 1.0)
	)


func pack_route_history(influence: float, lateral: float) -> float:
	return SettledCobbleGeometryScript.pack_route_history(influence, lateral)


func append_brick_face_transforms(transforms: Array[Transform3D], repair_flags: Array[bool], size: Vector3, axis_x: bool, face_sign: float, unit_length: float, unit_height: float, joint_width: float, face_depth: float, masonry_phase: float, repair_profile: Dictionary, face_index: int) -> void:
	var length := size.x if axis_x else size.z
	var row := 0
	var consumed_height := 0.0
	while consumed_height < size.y - 0.001:
		var course_noise := fposmod(sin(float(row + 1) * 19.193 + masonry_phase * 71.713) * 15731.743, 1.0)
		var monumental := unit_height > 0.40
		var actual_height := minf(size.y - consumed_height, unit_height * lerpf(0.78 if monumental else 0.84, 1.18 if monumental else 1.14, course_noise))
		var offset := unit_length * (0.46 + (course_noise - 0.5) * 0.13) if row % 2 == 1 else unit_length * (course_noise - 0.5) * (0.08 if monumental else 0.18)
		var cursor := -length * 0.5 - offset
		var column := 0
		while cursor < length * 0.5 - 0.04:
			var face_seed := (1.0 if axis_x else 17.0) + masonry_phase * 113.0
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
			var normalized_y := (consumed_height + actual_height * 0.5) / maxf(size.y, 0.001)
			var normalized_along := along / maxf(length, 0.001) + 0.5
			var repair_cluster := masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along, row)
			var repair_perimeter := repair_cluster and (not masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along - 0.075, row) or not masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along + 0.075, row) or not masonry_repair_cluster_matches(repair_profile, face_index, normalized_y - 0.065, normalized_along, row - 1) or not masonry_repair_cluster_matches(repair_profile, face_index, normalized_y + 0.065, normalized_along, row + 1))
			var replacement := piece_noise > (0.79 if monumental else 0.84) and second_noise < 0.58
			var chip_factor := lerpf(0.80 if monumental else 0.84, 0.955 if monumental else 0.97, second_noise) if piece_noise > (0.87 if monumental else 0.90) else 1.0
			var resolved_length := maxf(0.08, piece_end - piece_start - joint_width) * chip_factor
			var resolved_height := maxf(0.04, (actual_height - joint_width * 0.72) * lerpf(0.90 if monumental else 0.86, 1.0, second_noise) * (0.90 if replacement else 1.0))
			var resolved_depth := face_depth * lerpf(0.84 if monumental else 0.72, 1.14 if monumental else 1.18, piece_noise) * (1.14 if replacement else 1.0)
			if repair_cluster:
				resolved_length *= lerpf(0.965, 1.0, second_noise)
				resolved_height *= lerpf(0.955, 1.0, piece_noise)
				resolved_depth *= lerpf(0.92, 1.06, second_noise)
				if repair_perimeter:
					resolved_length *= lerpf(0.955, 0.985, second_noise)
					resolved_height *= lerpf(0.955, 0.985, piece_noise)
					resolved_depth *= lerpf(0.90, 1.02, piece_noise)
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
			repair_flags.append(repair_cluster)
			cursor += nominal_length
			column += 1
		consumed_height += actual_height
		row += 1


func masonry_repair_profile(part) -> Dictionary:
	var largest_span := maxf(part.size.x, maxf(part.size.y, part.size.z))
	if String(part.kind) not in ["wall", "foundation"] or largest_span < 2.60 or part.size.y < 1.35:
		return {}
	var phase := float(posmod((source_blueprint_id + ":repair:" + String(part.id)).hash(), 4093)) / 4093.0
	var exterior_front := String(part.id).contains("front") or String(part.semantic).contains("facade")
	if phase < 0.34 and not exterior_front:
		return {}
	var runoff: float = float(surface_history.conditions_at(part.position + Vector3(0.0, part.size.y * 0.18, 0.0)).get("runoff", 0.0))
	return {"face": 0 if exterior_front else int(floor(phase * 17.0)) % 4, "centerY": lerpf(0.30, 0.68, fposmod(phase * 5.17, 1.0)) * (1.0 - runoff * 0.22), "centerAlong": lerpf(0.28, 0.72, fposmod(phase * 9.31, 1.0)), "radiusY": lerpf(0.075, 0.125, fposmod(phase * 13.73, 1.0)), "radiusAlong": lerpf(0.065, 0.115, fposmod(phase * 19.37, 1.0)), "edgePhase": phase}


func masonry_repair_cluster_at(part, origin: Vector3, repair_profile: Dictionary) -> bool:
	if repair_profile.is_empty():
		return false
	var face_index := 0
	var along: float = origin.x
	var length: float = part.size.x
	if absf(origin.x) > absf(origin.z):
		face_index = 2 if origin.x < 0.0 else 3
		along = origin.z
		length = part.size.z
	else:
		face_index = 0 if origin.z < 0.0 else 1
	var normalized_y := origin.y / maxf(part.size.y, 0.001) + 0.5
	var normalized_along := along / maxf(length, 0.001) + 0.5
	return masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along)


func masonry_repair_cluster_matches(repair_profile: Dictionary, face_index: int, normalized_y: float, normalized_along: float, course_index := -1) -> bool:
	if repair_profile.is_empty() or int(repair_profile.get("face", -1)) != face_index:
		return false
	var radius_y := float(repair_profile.get("radiusY", 0.0))
	var vertical_ratio := absf(normalized_y - float(repair_profile.get("centerY", 0.5))) / maxf(radius_y, 0.001)
	if vertical_ratio > 1.0:
		return false
	var phase := float(repair_profile.get("edgePhase", 0.0))
	var resolved_course := course_index if course_index >= 0 else floori(normalized_y * 17.0)
	var row_noise := fposmod(sin(float(resolved_course + 1) * 19.193 + phase * 71.713) * 15731.743, 1.0)
	var center_along := float(repair_profile.get("centerAlong", 0.5)) + (row_noise - 0.5) * float(repair_profile.get("radiusAlong", 0.0)) * 1.35
	var taper := 0.46 + (1.0 - vertical_ratio) * 0.34 + (row_noise - 0.5) * 0.30
	var row_radius := maxf(0.045, float(repair_profile.get("radiusAlong", 0.0)) * taper)
	return absf(normalized_along - center_along) <= row_radius


func masonry_repair_patch_blend(part, origin: Vector3, repair_profile: Dictionary, stone_phase: float) -> float:
	if repair_profile.is_empty():
		return 0.70
	var face_index := 0
	var along: float = origin.x
	var length: float = part.size.x
	if absf(origin.x) > absf(origin.z):
		face_index = 2 if origin.x < 0.0 else 3
		along = origin.z
		length = part.size.z
	else:
		face_index = 0 if origin.z < 0.0 else 1
	if face_index != int(repair_profile.get("face", -1)):
		return 0.70
	var normalized_y := origin.y / maxf(part.size.y, 0.001) + 0.5
	var normalized_along := along / maxf(length, 0.001) + 0.5
	var vertical_ratio := absf(normalized_y - float(repair_profile.get("centerY", 0.5))) / maxf(float(repair_profile.get("radiusY", 0.0)), 0.001)
	var horizontal_ratio := absf(normalized_along - float(repair_profile.get("centerAlong", 0.5))) / maxf(float(repair_profile.get("radiusAlong", 0.0)), 0.001)
	var boundary := clampf(maxf(vertical_ratio, horizontal_ratio), 0.0, 1.0)
	var boundary_blend := smoothstep(0.48, 1.0, boundary)
	return clampf(0.96 - boundary_blend * 0.70 + (stone_phase - 0.5) * 0.18, 0.12, 1.0)


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
	var is_monumental := String(part.id).begins_with("castle_") or String(part.semantic).contains("civic")
	var course_run := 0.46 if is_monumental else 0.54
	var tile_span := 0.56 if is_monumental else 0.68
	var course_count := maxi(1, ceili(size.x / course_run))
	var tile_count := maxi(1, ceili(size.z / tile_span))
	var roof_phase := float(posmod((source_blueprint_id + ":roof:" + String(part.id)).hash(), 4093)) / 4093.0
	var left_slope := String(part.id).ends_with("_left") or String(part.id).contains("roof_left")
	var eave_sign := -1.0 if left_slope else 1.0
	var eave_x := eave_sign * size.x * 0.5
	var ridge_x := -eave_x
	var transforms: Array[Transform3D] = []
	var weathered_transforms: Array[Transform3D] = []
	for course_index in range(course_count):
		var course_t := (float(course_index) + 0.5) / float(course_count)
		var course_width := size.x / float(course_count)
		var row_offset := tile_span * 0.5 if course_index % 2 == 1 else 0.0
		row_offset += (fposmod(sin(float(course_index + 1) * 19.193 + roof_phase * 71.713) * 15731.743, 1.0) - 0.5) * tile_span * 0.18
		for tile_index in range(tile_count + 2):
			var slot_width := size.z / float(tile_count)
			var z := -size.z * 0.5 + slot_width * (float(tile_index) + 0.5) - row_offset
			var tile_start := maxf(-size.z * 0.5, z - slot_width * 0.5)
			var tile_end := minf(size.z * 0.5, z + slot_width * 0.5)
			if tile_end - tile_start < 0.08:
				continue
			z = (tile_start + tile_end) * 0.5
			var piece_noise := fposmod(sin(float(course_index + 1) * 41.17 + float(tile_index + 1) * 13.71 + roof_phase * 29.17) * 31991.37, 1.0)
			var secondary_noise := fposmod(sin(float(course_index + 1) * 11.73 + float(tile_index + 1) * 57.19 + roof_phase * 83.11) * 23171.31, 1.0)
			var x := lerpf(eave_x, ridge_x, course_t)
			var tile_size := Vector3(maxf(0.08, course_width * lerpf(1.04, 1.18, piece_noise)), size.y * lerpf(0.92, 1.16, secondary_noise), maxf(0.08, (tile_end - tile_start - 0.026) * lerpf(0.84, 1.0, piece_noise)))
			var tile_lift := (1.0 - course_t) * size.y * 0.52 + (piece_noise - 0.5) * 0.018
			var transform := Transform3D(Basis(Vector3.FORWARD, (secondary_noise - 0.5) * deg_to_rad(1.7)).scaled(tile_size), Vector3(x, tile_lift, z))
			var exposure := surface_history.history_for(part, part.position + transform.origin, course_t, piece_noise)
			if exposure > 0.58 and piece_noise > 0.78:
				weathered_transforms.append(transform)
			else:
				transforms.append(transform)
	var roof_material := material_for(part)
	add_box_batch(parent, transforms, roof_material, "RoofCourses", build_facade_custom_data(transforms, part))
	if not weathered_transforms.is_empty():
		add_box_batch(parent, weathered_transforms, material_for_id("roof_slate_weathered", variation_for(part) - 0.025), "RoofReplacementCourses", build_facade_custom_data(weathered_transforms, part))
	var cap_material := material_for_id("roof_slate_cap", variation_for(part) - 0.015)
	add_box_visual(parent, Vector3(0.18, maxf(0.10, size.y * 0.72), size.z + 0.14), Vector3(eave_x, size.y * 0.18, 0.0), cap_material, "RoofEaveCourse")
	add_box_visual(parent, Vector3(0.24, maxf(0.11, size.y * 0.82), size.z + 0.18), Vector3(ridge_x, size.y * 0.44, 0.0), cap_material, "RoofRidgeCap")


func publish_door_boards(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var geometry: Dictionary = BuildingDoorGeometryScript.describe(size)
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	pivot.position = geometry.pivotPosition
	parent.add_child(pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	leaf.position = geometry.leafPosition
	pivot.add_child(leaf)
	var transforms: Array[Transform3D] = []
	for board in geometry.boards:
		transforms.append(box_transform(board.position, board.size))
	add_box_batch(leaf, transforms, material_for(part), "DoorBoards")
	# The frame, brace and handle belong to the same semantic door part; they make
	# the opening readable without creating a second collision authority.
	add_box_visual(leaf, geometry.brace.size, geometry.brace.position, material_for_id("timber_beam", variation_for(part)), "DoorBrace")
	var frame_material := material_for_id("timber_beam", variation_for(part))
	add_box_visual(parent, geometry.frameLeft.size, geometry.frameLeft.position, frame_material, "DoorFrameLeft")
	add_box_visual(parent, geometry.frameRight.size, geometry.frameRight.position, frame_material, "DoorFrameRight")
	add_box_visual(parent, geometry.frameTop.size, geometry.frameTop.position, frame_material, "DoorFrameTop")
	add_box_visual(leaf, geometry.handle.size, geometry.handle.position, material_for_id("brass", variation_for(part)), "DoorHandle")


func publish_portcullis(part, parent: Node3D) -> void:
	# A castle gate is a raised iron grille, not a painted plank wall.  It is
	# still one ordinary door part: the shared controller owns its closed
	# collision and lifts the same visual leaf clear when opened.
	var size: Vector3 = part.size
	var geometry: Dictionary = BuildingDoorGeometryScript.describe_portcullis(size)
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	parent.add_child(pivot)
	var leaf := Node3D.new()
	leaf.name = "DoorLeaf"
	pivot.add_child(leaf)
	var bars: Array[Transform3D] = []
	for bar in geometry.bars:
		bars.append(box_transform(bar.position, bar.size))
	add_box_batch(leaf, bars, material_for(part), "PortcullisBars")
	for crossbar in geometry.crossbars:
		add_box_visual(leaf, crossbar.size, crossbar.position, material_for(part), "PortcullisCrossbar")
	publish_portcullis_lever(part, parent)


func publish_portcullis_lever(part, parent: Node3D) -> void:
	var geometry: Dictionary = BuildingDoorGeometryScript.describe_portcullis(part.size)
	var lever := Node3D.new()
	lever.name = "PortcullisLever"
	lever.position = geometry.leverPosition
	parent.add_child(lever)
	add_box_visual(lever, geometry.mount.size, geometry.mount.position, material_for_id("stone_foundation", variation_for(part)), "LeverMount")
	var arm_pivot := Node3D.new()
	arm_pivot.name = "LeverArmPivot"
	arm_pivot.rotation = geometry.leverRotation
	lever.add_child(arm_pivot)
	add_box_visual(arm_pivot, geometry.arm.size, geometry.arm.position, material_for_id("ironwork", variation_for(part)), "LeverArm")
	add_box_visual(arm_pivot, geometry.handle.size, geometry.handle.position, material_for_id("brass", variation_for(part)), "LeverHandle")


func configure_door_leaf(body: StaticBody3D, part) -> void:
	# Match the established DoorPortal/DoorController leaf contract. The generic
	# controller owns swing state and collider disabling; this publisher only
	# provides a building-derived door leaf for it to operate on.
	var portal_id := "building:%s:%s" % [source_blueprint_id, String(part.id)]
	body.set_meta("block_type", "door")
	body.set_meta("open", false)
	body.set_meta("closed_rotation", body.rotation.y)
	body.set_meta("open_swing", BuildingDoorGeometryScript.DEFAULT_OPEN_SWING)
	body.set_meta("door_motion", String(part.recipe.get("doorMotion", "swing")))
	body.set_meta("door_presentation", String(part.recipe.get("doorPresentation", "door")))
	body.set_meta("open_visual_offset", BuildingDoorGeometryScript.raised_visual_offset(part.size) if String(part.recipe.get("doorMotion", "swing")) == "raise" else Vector3.ZERO)
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


func add_door_interaction_proxy(door: StaticBody3D, part) -> void:
	var size: Vector3 = part.size
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
	collider.set_meta("building_part_id", part.id)
	collider.set_meta("building_part_kind", part.kind)
	collider.set_meta("building_semantic", part.semantic)
	collider.set_meta("building_collision_role", "door_interaction_proxy")
	area.add_child(collider)
	door.add_child(area)


func publish_window(part, parent: Node3D) -> void:
	var size: Vector3 = part.size
	var monumental := String(part.id).begins_with("castle_keep_") or String(part.id).begins_with("castle_gatehouse_")
	var trim := material_for_id("stone_foundation" if monumental else "timber_beam", variation_for(part) - 0.02)
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
	_publish_goods_geometry(part, parent, "sack")


func publish_pottery(part, parent: Node3D) -> void:
	_publish_goods_geometry(part, parent, "pottery")


func publish_basket(part, parent: Node3D) -> void:
	_publish_goods_geometry(part, parent, "basket")


func _publish_goods_geometry(part, parent: Node3D, kind: String) -> void:
	for piece in BuildingGoodsGeometryScript.describe(kind, part.size):
		var mesh: Mesh = null
		if piece.primitive != "box":
			mesh = BuildingGoodsGeometryScript.create_mesh(piece)
		var request: Dictionary = piece.material
		var material: Material
		if request.mode == "part":
			material = material_for(part)
		elif request.has("subtract"):
			material = material_for_id(String(request.id), variation_for(part) - float(request.subtract))
		else:
			# Do not add a zero offset: retain bare variation_for evaluation,
			# including its signed-zero behavior and material request ordering.
			material = material_for_id(String(request.id), variation_for(part))
		if piece.primitive == "box":
			add_box_visual(parent, piece.size, piece.position, material, piece.nodeName)
		else:
			add_mesh_visual(parent, mesh, piece.size, piece.position, material, piece.nodeName)


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
	static_visual_transform_count += 1
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
	static_visual_transform_count = 0
	incremental_static_flush_count += 1


func report_incremental_progress(reason: String) -> void:
	if not incremental_progress_callback.is_valid():
		return
	incremental_progress_callback.call({
		"reason": reason,
		"publishedParts": incremental_published_parts,
		"totalParts": incremental_total_parts,
		"pendingStaticVisualInstances": static_visual_transform_count,
		"staticFlushCount": incremental_static_flush_count
	})


func box_transform(position: Vector3, size: Vector3) -> Transform3D:
	return Transform3D(Basis.from_scale(size), position)


func oriented_box_transform(position: Vector3, size: Vector3, yaw: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(size), position)


func variation_for(part) -> float:
	return float(part.recipe.get("variation", 0.0))


func masonry_family_variation(part) -> float:
	var tokens := String(part.id).split("_", false)
	var family_token_count := mini(4, tokens.size())
	var family_key := "_".join(tokens.slice(0, family_token_count))
	var family_index := posmod((source_blueprint_id + ":" + family_key).hash(), 5)
	var family_offsets := [-0.042, -0.021, 0.0, 0.018, 0.039]
	return variation_for(part) + float(family_offsets[family_index])


func masonry_event_weathering(part, transform: Transform3D, index: int) -> bool:
	var conditions := surface_history.conditions_at(part.position + transform.origin)
	var runoff := float(conditions.get("runoff", 0.0))
	return runoff >= 0.40


func weathered_masonry_material_for(part, material_id: String) -> Material:
	var variation := masonry_family_variation(part)
	var key := "weathered_masonry:%s:%0.3f" % [material_id, variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var material := ConstructionMaterialCatalogScript.create_material(material_id, variation)
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var definition := ConstructionMaterialCatalogScript.definition_for(material_id)
		var base: Color = definition.get("base", Color.WHITE) as Color
		var accent: Color = definition.get("accent", Color.WHITE) as Color
		shader_material.set_shader_parameter("base_color", base.darkened(0.17))
		shader_material.set_shader_parameter("accent_color", accent.darkened(0.10))
		shader_material.set_shader_parameter("age_strength", minf(1.0, float(definition.get("age", 0.60)) + 0.20))
		shader_material.set_shader_parameter("damp_strength", minf(1.0, float(definition.get("damp", 0.36)) + 0.18))
		shader_material.set_shader_parameter("moss_strength", minf(0.70, float(definition.get("moss", 0.10)) + 0.18))
	material_cache[key] = material
	return material


func weathered_timber_material_for(part) -> Material:
	var variation := variation_for(part)
	var material_id := String(part.material_id)
	var key := "weathered_timber:%s:%0.3f" % [material_id, variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var material := ConstructionMaterialCatalogScript.create_material(material_id, variation)
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var definition := ConstructionMaterialCatalogScript.definition_for(material_id)
		var base: Color = definition.get("base", Color.WHITE) as Color
		var accent: Color = definition.get("accent", Color.WHITE) as Color
		shader_material.set_shader_parameter("base_color", base.darkened(0.11))
		shader_material.set_shader_parameter("accent_color", accent.darkened(0.08))
		shader_material.set_shader_parameter("age_strength", minf(1.0, float(definition.get("age", 0.66)) + 0.17))
		shader_material.set_shader_parameter("damp_strength", minf(1.0, float(definition.get("damp", 0.22)) + 0.25))
	material_cache[key] = material
	return material


func material_for(part) -> Material:
	return material_for_id(String(part.material_id), variation_for(part))


func material_for_id(material_id: String, variation := 0.0) -> Material:
	var key := "%s:%0.3f" % [material_id, variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var material: Material = ConstructionMaterialCatalogScript.create_material(material_id, variation)
	material_cache[key] = material
	return material


func masonry_repair_material_for(part, host_material_id: String) -> Material:
	var host_variation := masonry_family_variation(part)
	var key := "masonry_repair:%s:%0.3f" % [host_material_id, host_variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var repair_material := ConstructionMaterialCatalogScript.create_material("repair_stone", host_variation + 0.035) as ShaderMaterial
	var host_definition := ConstructionMaterialCatalogScript.definition_for(host_material_id)
	var tint := clampf(host_variation, -0.12, 0.12)
	var host_base: Color = host_definition.get("base", Color.WHITE) as Color
	var host_accent: Color = host_definition.get("accent", Color.WHITE) as Color
	repair_material.set_shader_parameter("repair_strength", 1.0)
	repair_material.set_shader_parameter("repair_phase", float(posmod((source_blueprint_id + ":repair:" + String(part.id)).hash(), 4093)) / 4093.0)
	repair_material.set_shader_parameter("repair_host_base", host_base.lightened(maxf(0.0, tint)).darkened(maxf(0.0, -tint)))
	repair_material.set_shader_parameter("repair_host_accent", host_accent.lightened(maxf(0.0, tint * 0.7)).darkened(maxf(0.0, -tint * 0.7)))
	material_cache[key] = repair_material
	return repair_material


func summary() -> Dictionary:
	var result: Dictionary = {
		"publishedPartCount": published_part_count,
		"publishedNodeCount": published_nodes.size(),
		"collisionPartCount": collision_count,
		"visualBatchCount": visual_batch_count,
		"batchedStaticParts": batch_static_parts,
		"staticRecordCount": static_part_records.size(),
		"masonryRepairClusterCount": masonry_repair_clusters.size(),
		"masonryRepairClusters": masonry_repair_clusters.duplicate(true),
		"surfaceHistory": surface_history.summary(),
		"physicalIntegrity": physical_integrity.duplicate(true),
		"physicalIntegrityRequiredForPublication": PHYSICAL_INTEGRITY_REQUIRED_FOR_PUBLICATION,
		"raisedRouteCoverage": raised_route_coverage.duplicate(true),
		"raisedRouteCoverageRequiredForPublication": false,
		"recipeBuildUsec": recipe_build_usec,
		"publicationUsec": publication_usec
	}
	if _paving_blueprint != null or not _paving_failure.is_empty():
		result["pavingFootingPublication"] = {"prepared": _paving_prepared, "ready": _paving_prepared and _paving_failure.is_empty(),
			"complete": _paving_complete and _paving_failure.is_empty(), "reason": _paving_failure, "finishCount": _paving_artifacts.size()}
	if _masonry_preparation != null:
		result["masonryAperturePublication"] = {"state": _masonry_preparation.state, "reason": _masonry_preparation.reason, "metrics": _masonry_preparation.metrics.duplicate()}
	return result
