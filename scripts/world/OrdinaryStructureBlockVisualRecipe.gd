extends RefCounted
class_name OrdinaryStructureBlockVisualRecipe

## Shared base-block visual recipe consumed by block creation and section capture.
## The returned resources stay on the main thread; section worker inputs receive
## only the sealed transform/color ABI and revision-bound resource bindings.

const SUPPORTED_BLOCK_TYPES: Array[String] = [
	"cobblestonePath", "stoneBlock", "woodBlock"]
const RECIPE_SCHEMA := "ordinary-structure-base-block-visual/v1"
const UNSUPPORTED_OPTION_KEYS: Array[String] = [
	"roofRole", "roofAxis", "roofSide", "roofMaterial", "roofTrimMaterial",
	"roofEdgeX", "roofEdgeZ", "roofAccent", "accentRole", "windowAxis",
	"windowSide", "cornerX", "cornerZ", "fenceAxis", "fenceTrimMaterial",
	"windowTrimMaterial", "cornerTrimMaterial", "torchVisualScale",
	"torchWallMount", "torchWallNormalX", "torchWallNormalZ",
	"torchWallSurfaceX", "torchWallSurfaceZ", "torchWallNormalWorldX",
	"torchWallNormalWorldZ", "torchWallAnchorCellX", "torchWallAnchorCellZ"
]


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
	var sealed_options := _seal_dictionary(options)
	var recipe_digest := _recipe_digest(block_type, sealed_options)
	if recipe_digest.is_empty():
		return _failed("ordinary_block_visual_recipe_digest_failed")
	var resources := resolve_shared_resources(main, block_type)
	if resources.get("status") != "ready":
		return resources
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
	var mesh_local_transform := Transform3D(Basis.from_scale(shape.size), shape.offset)
	var mesh: Mesh = resources.mesh
	var material: Material = resources.material
	var mesh_bounds := mesh.get_aabb()
	if not _finite_aabb(mesh_bounds):
		return _pending("ordinary_block_visual_mesh_bounds_invalid", {"blockType":block_type})
	var support_bounds: AABB = source_to_world * (mesh_local_transform * mesh_bounds)
	var payload := [RECIPE_SCHEMA, block_type, cell, sealed_options, recipe_digest,
		source_to_world, mesh_local_transform, mesh_bounds]
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(payload)) != OK:
		return _failed("ordinary_block_visual_content_digest_failed")
	return {"status":"ready", "schema":RECIPE_SCHEMA, "blockType":block_type,
		"cell":cell, "recipeDigest":recipe_digest,
		"contentDigest":context.finish().hex_encode(),
		"sourceToWorld":source_to_world,
		"meshLocalTransform":mesh_local_transform,
		"meshLocalBounds":mesh_bounds, "worldBounds":support_bounds,
		"mesh":mesh, "material":material,
		"size":shape.size, "offset":shape.offset}


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
