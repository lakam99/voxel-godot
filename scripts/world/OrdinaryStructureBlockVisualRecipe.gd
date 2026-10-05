extends RefCounted
class_name OrdinaryStructureBlockVisualRecipe

## Shared base-block visual recipe consumed by block creation and section capture.
## The returned resources stay on the main thread; section worker inputs receive
## only the sealed transform/color ABI and revision-bound resource bindings.

const SUPPORTED_BLOCK_TYPES: Array[String] = [
	"cobblestonePath", "stoneBlock", "woodBlock", "workbench", "bed",
	"traderStall", "spikeTrap", "copperVein", "ironVein"]
## Explicit completeness classification for block families emitted by
## StructureSystem. Static families may remain unsupported by the section
## adapter; those still pend instead of being treated as empty coverage.
const GENERATED_BLOCK_TYPE_FAMILIES := {
	"cobblestonePath":{"family":"section_static", "owner":"OrdinaryStructureBlockVisualRecipe"},
	"stoneBlock":{"family":"section_static", "owner":"OrdinaryStructureBlockVisualRecipe"},
	"woodBlock":{"family":"section_static", "owner":"OrdinaryStructureBlockVisualRecipe"},
	"glass":{"family":"section_static", "owner":"MainChunkTerrain.add_block_mesh (translucent layer pending)"},
	"chest":{"family":"separate_dynamic",
		"owner":"MainChunkTerrain.add_chest_visual and UtilityBlockSystem.open_block (state/interaction presentation)"},
	"furnace":{"family":"separate_dynamic",
		"owner":"MainChunkTerrain.add_furnace_visual and UtilityBlockSystem.open_block (state/interaction presentation)"},
	"workbench":{"family":"section_static", "owner":"MainChunkTerrain.add_workbench_visual"},
	"bed":{"family":"section_static", "owner":"MainChunkTerrain.add_bed_visual"},
	"traderStall":{"family":"section_static", "owner":"MainChunkTerrain.add_trader_stall_visual"},
	"campfire":{"family":"separate_dynamic",
		"owner":"MainChunkTerrain.add_campfire_visual and LocalLightRig (live flame/light presentation)"},
	"torch":{"family":"separate_dynamic",
		"owner":"MainChunkTerrain.add_torch_visual and LocalLightRig (live flame/light presentation)"},
	"spikeTrap":{"family":"section_static", "owner":"MainChunkTerrain.add_spike_trap_visual"},
	"copperVein":{"family":"section_static", "owner":"MainChunkTerrain.add_ore_block_visual"},
	"ironVein":{"family":"section_static", "owner":"MainChunkTerrain.add_ore_block_visual"},
	"door":{"family":"separate_dynamic",
		"owner":"DoorPortalService (pose/portal state); MainChunkTerrain.add_door_visual (live leaf/frame)"}
}
const RECIPE_SCHEMA := "ordinary-structure-base-block-visual/v1"
const UNSUPPORTED_OPTION_KEYS: Array[String] = [
	"windowAxis", "windowSide", "windowTrimMaterial", "torchVisualScale",
	"torchWallMount", "torchWallNormalX", "torchWallNormalZ",
	"torchWallSurfaceX", "torchWallSurfaceZ", "torchWallNormalWorldX",
	"torchWallNormalWorldZ", "torchWallAnchorCellX", "torchWallAnchorCellZ"
]


static func classify_generated_block_type(block_type: String) -> Dictionary:
	var value: Variant = GENERATED_BLOCK_TYPE_FAMILIES.get(block_type, null)
	var result: Dictionary
	if value is Dictionary:
		result = {"status":"classified", "blockType":block_type,
			"family":String(value.get("family", "")),
			"owner":String(value.get("owner", ""))}
	else:
		result = {"status":"unknown", "blockType":block_type,
			"family":"unknown", "owner":"",
			"reason":"ordinary_generated_block_family_unclassified"}
	result.make_read_only()
	return result


static func generated_block_type_inventory() -> Array[String]:
	var result: Array[String] = []
	for block_type_value: Variant in GENERATED_BLOCK_TYPE_FAMILIES:
		result.append(String(block_type_value))
	result.sort()
	result.make_read_only()
	return result


static func invoke_legacy_accent_fallback(recipe_visual_installed: bool,
		fallback: Callable) -> bool:
	if recipe_visual_installed or not fallback.is_valid():
		return false
	fallback.call()
	return true


static func resolve_shared_resources(main: Object, material_key: String) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method("block_visual_mesh") \
			or not main.has_method("block_visual_material"):
		return _pending("ordinary_block_visual_resource_authority_unavailable")
	var mesh := main.call("block_visual_mesh", material_key) as Mesh
	var material := main.call("block_visual_material", material_key) as Material
	if not is_instance_valid(mesh) or not is_instance_valid(material):
		return _pending("ordinary_block_visual_resource_unavailable", {
			"materialKey":material_key})
	return {"status":"ready", "mesh":mesh, "material":material}


static func resolve_base_shape(main: Object, block_type: String) -> Dictionary:
	if not SUPPORTED_BLOCK_TYPES.has(block_type):
		return _pending("ordinary_block_visual_type_not_supported", {
			"blockType":block_type})
	if not is_instance_valid(main) or not main.has_method("block_collision_profile"):
		return _pending("ordinary_block_visual_shape_authority_unavailable")
	var cell_size_value: Variant = main.get("CELL")
	if typeof(cell_size_value) not in [TYPE_INT, TYPE_FLOAT]:
		return _pending("ordinary_block_visual_cell_size_unavailable")
	var cell_size := float(cell_size_value)
	if not is_finite(cell_size) or cell_size <= 0.0:
		return _pending("ordinary_block_visual_cell_size_invalid")
	var profile_value: Variant = main.call("block_collision_profile", block_type)
	if not profile_value is Dictionary:
		return _pending("ordinary_block_visual_collision_profile_unavailable", {
			"blockType":block_type})
	var profile: Dictionary = profile_value
	var size_value: Variant = profile.get("size", Vector3.ONE * cell_size * 0.96)
	var offset_value: Variant = profile.get("offset", Vector3.ZERO)
	if not size_value is Vector3 or not offset_value is Vector3:
		return _pending("ordinary_block_visual_shape_invalid", {"blockType":block_type})
	var size: Vector3 = size_value
	var offset: Vector3 = offset_value
	if block_type == "cobblestonePath":
		size = Vector3(cell_size * 0.96, cell_size * 0.045, cell_size * 0.96)
		offset = Vector3.ZERO
	if not _finite_vector(size) or size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0 \
			or not _finite_vector(offset):
		return _pending("ordinary_block_visual_shape_non_finite", {"blockType":block_type})
	return {"status":"ready", "blockType":block_type, "size":size,
		"offset":offset, "cellSize":cell_size}


static func resolve_member(main: Object, block_type: String, cell: Vector3i,
		options: Dictionary) -> Dictionary:
	if not SUPPORTED_BLOCK_TYPES.has(block_type):
		return _pending("ordinary_block_visual_type_not_supported", {"blockType":block_type})
	for option_key: String in UNSUPPORTED_OPTION_KEYS:
		if options.has(option_key):
			return _pending("ordinary_block_visual_option_not_supported", {
				"blockType":block_type, "option":option_key})
	if not is_instance_valid(main) or not main.has_method("block_shadow_policy"):
		return _pending("ordinary_block_visual_shadow_policy_authority_unavailable", {
			"blockType":block_type})
	var sealed_options := _seal_dictionary(options)
	var recipe_digest := _recipe_digest(block_type, sealed_options)
	if recipe_digest.is_empty():
		return _failed("ordinary_block_visual_recipe_digest_failed")
	var shape := resolve_base_shape(main, block_type)
	if shape.get("status") != "ready":
		return shape
	var block_root := main.get("block_root") as Node3D
	if not is_instance_valid(block_root):
		return _pending("ordinary_block_visual_root_unavailable")
	var cell_size := float(shape.cellSize)
	var position := Vector3(
		_float_option(options, "world_x", float(cell.x) * cell_size),
		_float_option(options, "world_y", float(cell.y) * cell_size),
		_float_option(options, "world_z", float(cell.z) * cell_size))
	var facing := _float_option(options, "facing", 0.0)
	if not _finite_vector(position) or not is_finite(facing):
		return _pending("ordinary_block_visual_source_transform_invalid", {"cell":cell})
	var source_to_world := block_root.global_transform * Transform3D(
		Basis(Vector3.UP, facing), position)
	var members: Array[Dictionary] = []
	var asset_capture := _generated_static_asset_members(main, block_type,
		cell_size, source_to_world)
	if asset_capture.get("status") == "ready":
		members = asset_capture.get("members", [])
	elif asset_capture.get("status") == "pending":
		return asset_capture
	else:
		var specs := _member_specs(block_type, options, shape)
		if specs.get("status") != "ready":
			return specs
		members = _resolve_procedural_members(main, block_type, cell,
			sealed_options, source_to_world, specs.get("members", []))
		if members.is_empty():
			return _pending("ordinary_block_visual_member_resources_unavailable", {
				"blockType":block_type})
	var member_payloads: Array = []
	if members.is_empty():
		return _failed("ordinary_block_visual_member_list_empty")
	for member_value: Variant in members:
		if not member_value is Dictionary or not member_value.is_read_only():
			return _failed("ordinary_block_visual_member_not_sealed")
		var member: Dictionary = member_value
		var mesh: Mesh = member.get("mesh") as Mesh
		var material: Material = member.get("material") as Material
		var mesh_local_transform: Transform3D = member.get("meshLocalTransform",
			Transform3D.IDENTITY)
		var mesh_bounds: AABB = member.get("meshLocalBounds", AABB())
		if not is_instance_valid(mesh) or not is_instance_valid(material) \
				or not _finite_aabb(mesh_bounds):
			return _pending("ordinary_block_visual_mesh_or_material_invalid", {
				"blockType":block_type, "segmentId":String(member.get("segmentId", ""))})
		member_payloads.append([String(member.segmentId), String(member.materialKey),
			mesh.get_class(), mesh.resource_path, mesh_local_transform, mesh_bounds,
			String(member.get("visualRole", "")), bool(member.get("castShadows", true))])
	members.make_read_only()
	var first: Dictionary = members[0]
	var payload := [RECIPE_SCHEMA, block_type, cell, sealed_options, recipe_digest,
		source_to_world, member_payloads]
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(payload)) != OK:
		return _failed("ordinary_block_visual_content_digest_failed")
	return {"status":"ready", "schema":RECIPE_SCHEMA, "blockType":block_type,
		"cell":cell, "recipeDigest":recipe_digest,
		"contentDigest":context.finish().hex_encode(),
		"sourceToWorld":source_to_world, "members":members,
		"meshLocalTransform":first.meshLocalTransform,
		"meshLocalBounds":first.meshLocalBounds,
		"worldBounds":first.worldBounds,
		"mesh":first.mesh, "material":first.material,
		"size":shape.size, "offset":shape.offset}


static func _resolve_procedural_members(main: Object, block_type: String,
		cell: Vector3i, options: Dictionary, source_to_world: Transform3D,
		specs: Array) -> Array[Dictionary]:
	var members: Array[Dictionary] = []
	for spec_value: Variant in specs:
		if not spec_value is Dictionary:
			return []
		var spec: Dictionary = spec_value
		var resources := resolve_shared_resources(main, String(spec.get("materialKey", "")))
		if resources.get("status") != "ready":
			return []
		var mesh: Mesh = resources.mesh
		var mesh_local_transform: Transform3D = spec.get("localTransform", Transform3D.IDENTITY)
		var mesh_bounds := mesh.get_aabb()
		if not _finite_aabb(mesh_bounds):
			return []
		var member := {"segmentId":String(spec.get("segmentId", "")),
			"visualName":String(spec.get("visualName", "")),
			"visualRole":String(spec.get("visualRole", "")),
			"materialKey":String(spec.get("materialKey", "")), "mesh":mesh,
			"material":resources.material, "meshLocalTransform":mesh_local_transform,
			"meshLocalBounds":mesh_bounds,
			"worldBounds":source_to_world * (mesh_local_transform * mesh_bounds),
			"castShadows":_block_material_cast_shadows(main,
				String(spec.get("materialKey", "")))}
		member.make_read_only()
		members.append(member)
	return members


static func _generated_static_asset_members(main: Object, block_type: String,
		cell_size: float, source_to_world: Transform3D) -> Dictionary:
	var registry: Variant = main.get("static_item_asset_registry")
	if registry == null or not is_instance_valid(registry) \
			or not registry.has_method("has_asset") or not registry.has_method("instantiate_item"):
		return {"status":"unavailable"}
	if not bool(registry.call("has_asset", block_type)):
		return {"status":"unavailable"}
	var asset_root := registry.call("instantiate_item", block_type) as Node3D
	if not is_instance_valid(asset_root):
		return _pending("ordinary_block_static_asset_instantiation_failed", {
			"blockType":block_type})
	asset_root.scale = Vector3.ONE * cell_size
	var root_transform: Transform3D = asset_root.transform
	var members: Array[Dictionary] = []
	var result := _collect_static_asset_members(asset_root, root_transform,
		block_type, source_to_world, "", members, true)
	asset_root.free()
	if result.get("status") != "ready":
		return result
	if members.is_empty():
		return _pending("ordinary_block_static_asset_has_no_mesh_members", {
			"blockType":block_type})
	members.make_read_only()
	return {"status":"ready", "members":members,
		"assetId":block_type}


static func _block_material_cast_shadows(main: Object, material_key: String) -> bool:
	if not is_instance_valid(main) or not main.has_method("block_shadow_policy"):
		return true
	return int(main.call("block_shadow_policy", material_key)) \
		!= GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _collect_static_asset_members(node: Node, node_to_root: Transform3D,
		asset_id: String, source_to_world: Transform3D, node_path: String,
		members: Array[Dictionary], parent_visible: bool) -> Dictionary:
	var visible_through_hierarchy := parent_visible
	if node is Node3D:
		visible_through_hierarchy = parent_visible and (node as Node3D).visible
	if node is GeometryInstance3D and not node is MeshInstance3D:
		return _pending("ordinary_block_static_asset_geometry_type_unsupported", {
			"assetId":asset_id, "nodePath":node_path, "class":node.get_class()})
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if not visible_through_hierarchy:
			return _pending("ordinary_block_static_asset_mesh_not_visible_in_source", {
				"assetId":asset_id, "nodePath":node_path,
				"nodeVisible":mesh_instance.visible,
				"visibleThroughHierarchy":visible_through_hierarchy})
		var mesh := mesh_instance.mesh
		if not is_instance_valid(mesh) or mesh.get_surface_count() != 1:
			return _pending("ordinary_block_static_asset_mesh_surface_unsupported", {
				"assetId":asset_id, "nodePath":node_path,
				"surfaceCount":mesh.get_surface_count() if is_instance_valid(mesh) else -1})
		var material: Material = mesh_instance.material_override
		if material == null:
			material = mesh_instance.get_surface_override_material(0)
		if material == null:
			material = mesh.surface_get_material(0)
		if not is_instance_valid(material):
			return _pending("ordinary_block_static_asset_surface_material_missing", {
				"assetId":asset_id, "nodePath":node_path})
		var local_bounds := mesh.get_aabb()
		var mesh_local_transform := node_to_root
		if not _finite_aabb(local_bounds):
			return _pending("ordinary_block_static_asset_mesh_bounds_invalid", {
				"assetId":asset_id, "nodePath":node_path})
		var segment_id := "asset:%s:%s:surface:0" % [asset_id, node_path]
		var material_key := "static-item:%s:%s" % [asset_id,
			String(material.resource_path)]
		var member := {"segmentId":segment_id,
			"visualName":mesh_instance.name, "visualRole":"generatedStaticAsset",
			"materialKey":material_key, "mesh":mesh, "material":material,
			"meshLocalTransform":mesh_local_transform,
			"meshLocalBounds":local_bounds,
			"worldBounds":source_to_world * (mesh_local_transform * local_bounds),
			"castShadows":mesh_instance.cast_shadow \
				!= GeometryInstance3D.SHADOW_CASTING_SETTING_OFF}
		member.make_read_only()
		members.append(member)
	for child_index in range(node.get_child_count()):
		var child: Node = node.get_child(child_index)
		if not child is Node3D:
			return _pending("ordinary_block_static_asset_nonspatial_child_unsupported", {
				"assetId":asset_id, "nodePath":node_path, "child":child.name})
		var child_path := String(child.name) + "#" + str(child_index)
		if not node_path.is_empty():
			child_path = node_path + "/" + child_path
		var child_transform: Transform3D = node_to_root * (child as Node3D).transform
		var child_result := _collect_static_asset_members(child,
			child_transform, asset_id, source_to_world, child_path, members,
			visible_through_hierarchy)
		if child_result.get("status") != "ready":
			return child_result
	return {"status":"ready"}


static func _member_specs(block_type: String, options: Dictionary,
		shape: Dictionary) -> Dictionary:
	var cell_size := float(shape.cellSize)
	var specs: Array[Dictionary] = []
	if block_type == "workbench":
		_append_spec(specs, "bench_top", "BenchTop", "generatedStaticUtility",
			"workbench", Vector3(cell_size * 1.18, cell_size * 0.16,
				cell_size * 0.92), Vector3(0.0, cell_size * 0.29, 0.0))
		_append_spec(specs, "bench_top_trim", "BenchTopTrim", "generatedStaticUtility",
			"door", Vector3(cell_size * 1.24, cell_size * 0.06,
				cell_size * 0.98), Vector3(0.0, cell_size * 0.41, 0.0))
		_append_spec(specs, "bench_lower_shelf", "BenchLowerShelf", "generatedStaticUtility",
			"workbench", Vector3(cell_size * 0.82, cell_size * 0.08,
				cell_size * 0.58), Vector3(0.0, -cell_size * 0.20, 0.0))
		for x_offset in [-0.43, 0.43]:
			for z_offset in [-0.31, 0.31]:
				_append_spec(specs, "bench_leg_%s_%s" % [str(x_offset), str(z_offset)],
					"BenchLeg", "generatedStaticUtility", "door",
					Vector3(cell_size * 0.10, cell_size * 0.58, cell_size * 0.10),
					Vector3(float(x_offset) * cell_size, -cell_size * 0.10,
						float(z_offset) * cell_size))
		for x_offset in [-0.28, 0.28]:
			_append_spec(specs, "bench_rail_%s" % str(x_offset), "BenchRail",
				"generatedStaticUtility", "door",
				Vector3(cell_size * 0.08, cell_size * 0.08, cell_size * 0.78),
				Vector3(float(x_offset) * cell_size, cell_size * 0.11, 0.0))
		_append_spec(specs, "bench_stone_tool", "BenchStoneTool", "generatedStaticUtility",
			"stoneBlock", Vector3(cell_size * 0.38, cell_size * 0.035,
				cell_size * 0.08), Vector3(-cell_size * 0.25,
				cell_size * 0.52, -cell_size * 0.22))
		_append_spec(specs, "bench_wood_tool", "BenchWoodTool", "generatedStaticUtility",
			"woodBlock", Vector3(cell_size * 0.08, cell_size * 0.04,
				cell_size * 0.34), Vector3(cell_size * 0.25,
				cell_size * 0.52, cell_size * 0.10))
		_append_spec(specs, "bench_stone_tool_small", "BenchStoneToolSmall",
			"generatedStaticUtility", "stoneBlock",
			Vector3(cell_size * 0.12, cell_size * 0.06, cell_size * 0.12),
			Vector3(cell_size * 0.34, cell_size * 0.53, -cell_size * 0.18))
	elif block_type == "bed":
		_append_spec(specs, "bed_frame", "BedFrame", "generatedStaticUtility", "door",
			Vector3(cell_size * 1.18, cell_size * 0.12, cell_size * 0.78),
			Vector3(0.0, -cell_size * 0.35, 0.0))
		for x_offset in [-0.48, 0.48]:
			for z_offset in [-0.30, 0.30]:
				_append_spec(specs, "bed_leg_%s_%s" % [str(x_offset), str(z_offset)],
					"BedLeg", "generatedStaticUtility", "door",
					Vector3(cell_size * 0.08, cell_size * 0.34, cell_size * 0.08),
					Vector3(float(x_offset) * cell_size, -cell_size * 0.49,
						float(z_offset) * cell_size))
		_append_spec(specs, "bed_pillow", "BedPillow", "generatedStaticUtility",
			"bedPillow", Vector3(cell_size * 1.10, cell_size * 0.18,
				cell_size * 0.72), Vector3(cell_size * 0.02,
				-cell_size * 0.21, 0.0))
		_append_spec(specs, "bed_blanket", "BedBlanket", "generatedStaticUtility",
			"bedBlanket", Vector3(cell_size * 0.74, cell_size * 0.20,
				cell_size * 0.74), Vector3(cell_size * 0.18,
				-cell_size * 0.12, 0.0))
		_append_spec(specs, "bed_headboard", "BedHeadboard", "generatedStaticUtility",
			"door", Vector3(cell_size * 0.16, cell_size * 0.56,
				cell_size * 0.82), Vector3(-cell_size * 0.57,
				-cell_size * 0.18, 0.0))
	elif block_type == "traderStall":
		_append_spec(specs, "stall_counter", "StallCounter", "generatedStaticUtility",
			"traderStall", Vector3(cell_size * 1.08, cell_size * 0.32,
				cell_size * 0.64), Vector3(0.0, -cell_size * 0.34, 0.0))
		for x_offset in [-0.45, 0.45]:
			for z_offset in [-0.30, 0.30]:
				_append_spec(specs, "stall_post_%s_%s" % [str(x_offset), str(z_offset)],
					"StallPost", "generatedStaticUtility", "traderStall",
					Vector3(cell_size * 0.07, cell_size * 1.05, cell_size * 0.07),
					Vector3(float(x_offset) * cell_size, cell_size * 0.06,
						float(z_offset) * cell_size))
		_append_spec(specs, "stall_canopy", "StallCanopy", "generatedStaticUtility",
			"traderCloth", Vector3(cell_size * 1.24, cell_size * 0.12,
				cell_size * 0.86), Vector3(0.0, cell_size * 0.62, 0.0))
		for index in range(-2, 3):
			var cloth_key := "traderClothLight" if index % 2 == 0 else "traderCloth"
			_append_spec(specs, "stall_valance_%d" % index, "StallValance",
				"generatedStaticUtility", cloth_key,
				Vector3(cell_size * 0.18, cell_size * 0.16, cell_size * 0.05),
				Vector3(float(index) * cell_size * 0.20, cell_size * 0.50,
					cell_size * 0.45))
		_append_spec(specs, "stall_crate", "TraderCrateVisual", "generatedStaticUtility",
			"woodBlock", Vector3(cell_size * 0.34, cell_size * 0.26,
				cell_size * 0.34), Vector3(-cell_size * 0.42,
				-cell_size * 0.02, -cell_size * 0.50))
		_append_spec(specs, "stall_barrel", "TraderBarrelVisual", "generatedStaticUtility",
			"door", Vector3(cell_size * 0.26, cell_size * 0.42,
				cell_size * 0.26), Vector3(cell_size * 0.44,
				-cell_size * 0.03, -cell_size * 0.48))
	elif block_type == "spikeTrap":
		_append_spec(specs, "trap_base", "TrapBase", "generatedStaticUtility",
			"spikeTrap", Vector3(cell_size * 0.86, cell_size * 0.10,
				cell_size * 0.86), Vector3(0.0, -cell_size * 0.44, 0.0))
		for x_offset in [-0.24, 0.0, 0.24]:
			for z_offset in [-0.24, 0.0, 0.24]:
				_append_spec(specs, "trap_spike_%s_%s" % [str(x_offset), str(z_offset)],
					"TrapSpike", "generatedStaticUtility", "anvil",
					Vector3(cell_size * 0.08, cell_size * 0.34, cell_size * 0.08),
					Vector3(float(x_offset) * cell_size, -cell_size * 0.24,
						float(z_offset) * cell_size), Vector3(0.35, 0.0, 0.35))
	elif block_type in ["copperVein", "ironVein"]:
		var seam_specs := [
			{"id":"a", "pos":Vector3(-shape.size.x * 0.22,
				shape.size.y * 0.18, -shape.size.z * 0.51),
				"size":Vector3(shape.size.x * 0.52, shape.size.y * 0.075,
					shape.size.z * 0.035), "rotation":0.18},
			{"id":"b", "pos":Vector3(shape.size.x * 0.18,
				-shape.size.y * 0.10, -shape.size.z * 0.51),
				"size":Vector3(shape.size.x * 0.66, shape.size.y * 0.075,
					shape.size.z * 0.035), "rotation":-0.24},
			{"id":"c", "pos":Vector3(shape.size.x * 0.02,
				shape.size.y * 0.34, -shape.size.z * 0.51),
				"size":Vector3(shape.size.x * 0.34, shape.size.y * 0.065,
					shape.size.z * 0.035), "rotation":0.55}]
		_append_spec(specs, "ore_base", "OreBase", "generatedStaticOre",
			"oreBase", shape.size, shape.offset)
		for seam_value: Variant in seam_specs:
			var seam: Dictionary = seam_value
			_append_spec(specs, "ore_seam_%s" % seam.id, "OreBlockSeam",
				"generatedStaticOre", block_type, seam.size,
				shape.offset + seam.pos, Vector3(0.0, 0.0, float(seam.rotation)))
		var glow_material := "ironOreGlow" if block_type == "ironVein" else "copperOreGlow"
		for x_offset in [-0.18, 0.16]:
			_append_spec(specs, "ore_glint_%s" % str(x_offset), "OreBlockGlint",
				"generatedStaticOre", glow_material,
				Vector3(shape.size.x * 0.10, shape.size.y * 0.10,
					shape.size.z * 0.045),
				shape.offset + Vector3(float(x_offset) * shape.size.x,
					shape.size.y * (0.04 if x_offset < 0.0 else 0.30),
					-shape.size.z * 0.52))
	elif options.has("roofRole") and block_type in ["woodBlock", "stoneBlock"]:
		var role := String(options.get("roofRole", "slope"))
		var axis := String(options.get("roofAxis", "x"))
		var roof_material := String(options.get("roofMaterial",
			"roofStone" if block_type == "stoneBlock" else "roofWood"))
		var trim_material := String(options.get("roofTrimMaterial",
			"trimStone" if block_type == "stoneBlock" else "trimWood"))
		if role not in ["slope", "ridge", "eave"] or axis not in ["x", "z"]:
			return _pending("ordinary_block_roof_role_or_axis_invalid", {
				"role":role, "axis":axis})
		_append_spec(specs, "roof_base", "RoofVisual_%s" % role, "roof",
			roof_material, Vector3(cell_size * 1.02, cell_size * 0.22,
				cell_size * 1.02), Vector3(0.0, -cell_size * 0.30, 0.0))
		if role == "ridge":
			var ridge_size := Vector3(cell_size * 1.16, cell_size * 0.18, cell_size * 0.30) \
				if axis == "x" else Vector3(cell_size * 0.30, cell_size * 0.18,
					cell_size * 1.16)
			_append_spec(specs, "roof_ridge_bar", "RoofRidgeCapVisual", "roof",
				roof_material, ridge_size, Vector3(0.0, -cell_size * 0.10, 0.0))
		var edge_x := int(options.get("roofEdgeX", 0))
		var edge_z := int(options.get("roofEdgeZ", 0))
		if abs(edge_x) > 1 or abs(edge_z) > 1:
			return _pending("ordinary_block_roof_edge_value_invalid", {
				"edgeX":edge_x, "edgeZ":edge_z})
		if edge_x != 0:
			_append_spec(specs, "roof_eave_x", "RoofEaveTrimX", "roofTrim",
				trim_material, Vector3(cell_size * 0.08, cell_size * 0.18, cell_size * 1.18),
				Vector3(float(edge_x) * cell_size * 0.57, -cell_size * 0.22, 0.0))
		if edge_z != 0:
			_append_spec(specs, "roof_eave_z", "RoofEaveTrimZ", "roofTrim",
				trim_material, Vector3(cell_size * 1.18, cell_size * 0.18, cell_size * 0.08),
				Vector3(0.0, -cell_size * 0.22, float(edge_z) * cell_size * 0.57))
		if String(options.get("roofAccent", "")) == "chimney":
			_append_spec(specs, "chimney_shaft", "ChimneyVisual", "chimney",
				trim_material, Vector3(cell_size * 0.34, cell_size * 0.90, cell_size * 0.34),
				Vector3(cell_size * 0.18, cell_size * 0.45, cell_size * 0.12))
			_append_spec(specs, "chimney_cap", "ChimneyCapVisual", "chimney",
				trim_material, Vector3(cell_size * 0.46, cell_size * 0.14, cell_size * 0.46),
				Vector3(cell_size * 0.18, cell_size * 0.96, cell_size * 0.12))
	else:
		_append_spec(specs, "base", "BlockVisual_%s" % block_type, "block",
			block_type, shape.size, shape.offset)
	var accent := String(options.get("accentRole", ""))
	if not accent.is_empty():
		if accent == "cornerTimber" and block_type == "woodBlock":
			var corner_x := int(options.get("cornerX", 1))
			var corner_z := int(options.get("cornerZ", 1))
			if abs(corner_x) != 1 or abs(corner_z) != 1:
				return _pending("ordinary_block_corner_sign_invalid", {
					"cornerX":corner_x, "cornerZ":corner_z})
			var trim_key := String(options.get("cornerTrimMaterial", "trimWood"))
			_append_spec(specs, "corner_timber_x", "CornerTimberX", "cornerTimber",
				trim_key, Vector3(cell_size * 0.10, cell_size * 1.04,
					cell_size * 0.16), Vector3(float(corner_x) * cell_size * 0.50,
					0.0, float(corner_z) * cell_size * 0.43))
			_append_spec(specs, "corner_timber_z", "CornerTimberZ", "cornerTimber",
				trim_key, Vector3(cell_size * 0.16, cell_size * 1.04,
					cell_size * 0.10), Vector3(float(corner_x) * cell_size * 0.43,
					0.0, float(corner_z) * cell_size * 0.50))
		elif accent == "fencePost" and block_type == "woodBlock":
			var axis := String(options.get("fenceAxis", "x"))
			if axis not in ["x", "z"]:
				return _pending("ordinary_block_fence_axis_invalid", {"axis":axis})
			var fence_trim := String(options.get("fenceTrimMaterial", "trimWood"))
			_append_spec(specs, "fence_post", "FencePostVisual", "fencePost",
				fence_trim, Vector3(cell_size * 0.18, cell_size * 1.08,
					cell_size * 0.18), Vector3.ZERO)
			for rail_index in range(2):
				var rail_axis := "x" if axis == "x" else "z"
				var rail_size := Vector3(cell_size * 1.04, cell_size * 0.12,
					cell_size * 0.14) if rail_axis == "x" else Vector3(
					cell_size * 0.14, cell_size * 0.12, cell_size * 1.04)
				_append_spec(specs, "fence_rail_%s" % rail_index,
					"FenceRailVisual", "fenceRail", fence_trim, rail_size,
					Vector3(0.0, (0.18 if rail_index == 0 else -0.18) * cell_size, 0.0))
		else:
			return _pending("ordinary_block_accent_not_supported", {
				"blockType":block_type, "accentRole":accent})
	return {"status":"ready", "members":specs}


static func _append_spec(specs: Array[Dictionary], segment_id: String,
		visual_name: String, visual_role: String, material_key: String,
		size: Vector3, offset: Vector3, rotation: Vector3 = Vector3.ZERO) -> void:
	var spec := {"segmentId":segment_id, "visualName":visual_name,
		"visualRole":visual_role, "materialKey":material_key,
		"localTransform":Transform3D(Basis.from_euler(rotation).scaled(size), offset)}
	spec.make_read_only()
	specs.append(spec)


static func _recipe_digest(block_type: String, options: Dictionary) -> String:
	if block_type.is_empty() or not options.is_read_only():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes([
				"ordinary-structure-visual-recipe-input/v1", block_type, options])) != OK:
		return ""
	return context.finish().hex_encode()


static func _seal_dictionary(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key: Variant in value:
		result[key] = _seal_value(value[key])
	result.make_read_only()
	return result


static func _seal_value(value: Variant) -> Variant:
	if value is Dictionary:
		return _seal_dictionary(value)
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_seal_value(item))
		result.make_read_only()
		return result
	return value


static func _float_option(options: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = options.get(key, fallback)
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return NAN
	return float(value)


static func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _finite_aabb(value: AABB) -> bool:
	return _finite_vector(value.position) and _finite_vector(value.size) \
		and value.size.x > 0.0 and value.size.y > 0.0 and value.size.z > 0.0


static func _pending(reason: String, details: Dictionary = {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason}
	for key: Variant in details:
		result[key] = details[key]
	return result


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason}
