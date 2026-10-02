extends RefCounted
class_name HorizonEcologySource

const ChunkPropVisualManifestScript := preload("res://scripts/world/ChunkPropVisualManifest.gd")
const HorizonEcologyPropReceiptPublisherScript := preload("res://scripts/world/HorizonEcologyPropReceiptPublisher.gd")

## Retains surface-only visual roots for view chunks without gameplay chunks.
## Candidate generation remains in Main's seeded chunk prop state machine.
var roots: Dictionary = {}
var states: Dictionary = {}
var promotion_cursor := 0
var validation_cursor := 0


func source_for(chunk_key: Vector2i) -> Node3D:
	var root := roots.get(chunk_key) as Node3D
	return root if is_instance_valid(root) and not root.is_queued_for_deletion() else null


func clear() -> void:
	for root_value in roots.values():
		var root := root_value as Node3D
		if is_instance_valid(root):
			root.queue_free()
	roots.clear()
	states.clear()
	promotion_cursor = 0
	validation_cursor = 0


func retain_view(main: Node, retained_keys: Array[Vector2i], ranked_keys: Array[Vector2i], near_bounds: Rect2i,
		cell_scale: float, chunk_size: int, allow_creation: bool) -> void:
	validate_one_source(main, chunk_size)
	var wanted := {}
	for key: Vector2i in retained_keys:
		wanted[key] = true
	for key_value in roots.keys():
		var key: Vector2i = key_value
		if not wanted.has(key):
			retire(key)
			break
	if not allow_creation:
		return
	for key: Vector2i in ranked_keys:
		if Rect2i(key * chunk_size, Vector2i.ONE * chunk_size).intersects(near_bounds):
			continue
		if source_for(key) != null:
			continue
		# Existing physical chunks have their own seeded producer and must not
		# acquire a second candidate owner.
		var chunks_value: Variant = main.get("chunks")
		if chunks_value is Dictionary and chunks_value.has(key):
			continue
		var chunk_root := main.get("chunk_root") as Node3D
		if not is_instance_valid(chunk_root):
			return
		var root := Node3D.new()
		root.name = "HorizonEcology_%d_%d" % [key.x, key.y]
		root.position = Vector3(key.x * chunk_size * cell_scale, 0.0,
			key.y * chunk_size * cell_scale)
		root.set_meta("horizon_visual_only", true)
		root.set_meta("horizon_chunk_revision", _chunk_revision(main, key, chunk_size))
		root.set_meta("horizon_removed_props_revision", int(main.get("removed_props_revision")))
		chunk_root.add_child(root)
		roots[key] = root
		states[key] = main.call("begin_chunk_prop_spawn_state", root, key.x, key.y)
		# One new owner per frame; its seeded scan then advances through the
		# same bounded prop slice as a gameplay chunk.
		break


func validate_one_source(main: Node, chunk_size: int) -> void:
	var keys := roots.keys()
	if keys.is_empty():
		return
	var key: Vector2i = keys[validation_cursor % keys.size()]
	validation_cursor += 1
	var root := source_for(key)
	if root == null:
		retire(key)
		return
	var changed := int(root.get_meta("horizon_chunk_revision", -1)) != \
		_chunk_revision(main, key, chunk_size)
	var removed_revision := int(main.get("removed_props_revision"))
	if not changed and int(root.get_meta("horizon_removed_props_revision", -1)) != removed_revision:
		var removed_value: Variant = main.get("removed_props")
		if removed_value is Dictionary:
			changed = _contains_removed_candidate(root, removed_value)
		root.set_meta("horizon_removed_props_revision", removed_revision)
	if changed:
		retire(key)
		var controller := main.get("visible_world_demand_controller") as Object
		if is_instance_valid(controller) and controller.has_method("mark_chunk_dirty"):
			controller.call("mark_chunk_dirty", "player", key)


func _chunk_revision(main: Node, key: Vector2i, chunk_size: int) -> int:
	var world := main.get("world_generation_system") as Object
	if is_instance_valid(world) and world.has_method("terrain_volume_chunk_revision"):
		return int(world.call("terrain_volume_chunk_revision", key, chunk_size))
	return -1


func _contains_removed_candidate(node: Node, removed: Dictionary) -> bool:
	if node.has_meta("prop_id") and removed.has(String(node.get_meta("prop_id"))):
		return true
	for child in node.get_children():
		if child is Node and _contains_removed_candidate(child, removed):
			return true
	return false


func advance_one(main: Node, ranked_keys: Array[Vector2i], budget_ms: float,
		prop_attempts: int, detail_attempts: int) -> int:
	for key: Vector2i in ranked_keys:
		if not states.has(key):
			continue
		var root := source_for(key)
		if root == null:
			retire(key)
			continue
		var state: Dictionary = states[key]
		if main.call("process_chunk_prop_spawn_state", state,
				prop_attempts, detail_attempts, budget_ms):
			states.erase(key)
		else:
			states[key] = state
		refresh_ordinary_visual_ranges(main, key)
		return 1
	return 0


func refresh_ordinary_visual_ranges(main: Node, key: Vector2i) -> void:
	var root := source_for(key)
	if root == null:
		return
	var player := main.get("player") as Node3D
	var runtime := main.get("voxel_terrain_runtime") as Object
	if not is_instance_valid(player) or not is_instance_valid(runtime):
		return
	var viewer := runtime.get("viewer") as Object
	if not is_instance_valid(viewer):
		return
	var view_distance := float(viewer.get("view_distance"))
	if not is_finite(view_distance) or view_distance <= 0.0:
		return
	var camera := player.get("camera") as Camera3D
	var eye := camera.global_position if is_instance_valid(camera) else player.global_position
	var anchor: Vector3 = root.get_meta("horizon_range_anchor", Vector3.INF)
	if anchor.is_finite() and anchor.distance_squared_to(eye) < 64.0 \
			and is_equal_approx(float(root.get_meta("horizon_range_distance", -1.0)), view_distance) \
			and int(root.get_meta("horizon_range_child_count", -1)) == root.get_child_count():
		return
	for child in root.get_children():
		if not child is Node3D or not child.has_meta("prop_id") \
				or child.has_meta("tree_visual_state"):
			continue
		var body := child as Node3D
		var horizontal := Vector2(body.global_position.x, body.global_position.z).distance_to(
			Vector2(eye.x, eye.z))
		# Controller source membership uses the player's horizontal view circle.
		# Extend only bodies in that circle enough for vertical camera separation
		# and the small camera/mesh offset. Old view receipts may become pending
		# when the player leaves their actual draw range.
		var end_distance := view_distance + 4.0
		if horizontal <= view_distance + 1.0:
			end_distance = maxf(end_distance, body.global_position.distance_to(eye) + 4.0)
		_set_geometry_range(body, end_distance)
		if not body.has_meta("horizon_ordinary_visual_publisher"):
			var publisher = HorizonEcologyPropReceiptPublisherScript.new()
			publisher.configure(body, main)
			body.set_meta("horizon_ordinary_visual_publisher", publisher)
	root.set_meta("horizon_range_anchor", eye)
	root.set_meta("horizon_range_distance", view_distance)
	root.set_meta("horizon_range_child_count", root.get_child_count())


func _set_geometry_range(node: Node, end_distance: float) -> void:
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		geometry.visibility_range_end = end_distance
		geometry.visibility_range_end_margin = 12.0
	for child in node.get_children():
		if child is Node:
			_set_geometry_range(child, end_distance)


func retire_promoted_one(main: Node, near_bounds: Rect2i, seed: String,
		cell_scale: float, chunk_size: int) -> bool:
	var keys := roots.keys()
	if keys.is_empty():
		return false
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary:
		return false
	var physical_chunks: Dictionary = chunks_value
	for offset in keys.size():
		var index := (promotion_cursor + offset) % keys.size()
		var key: Vector2i = keys[index]
		var chunk := physical_chunks.get(key) as Node3D
		if not is_instance_valid(chunk) or chunk.is_queued_for_deletion():
			continue
		var surface_only := not Rect2i(key * chunk_size,
			Vector2i.ONE * chunk_size).intersects(near_bounds)
		var marker := "chunk_surface_candidate_scan_complete" if surface_only \
			else "chunk_prop_candidate_scan_complete"
		var revision_marker := "chunk_surface_candidate_source_revision" if surface_only \
			else "chunk_prop_candidate_source_revision"
		if not bool(chunk.get_meta(marker, false)):
			continue
		promotion_cursor = (index + 1) % keys.size()
		var manifest: Dictionary = ChunkPropVisualManifestScript.capture(chunk, key,
			seed, String(chunk.get_meta(revision_marker, "")), true, cell_scale, surface_only)
		if manifest.get("status") != "ready":
			return false
		if not surface_only:
			for candidate_value in manifest.get("candidates", []):
				if not candidate_value is Dictionary:
					continue
				var candidate: Dictionary = candidate_value
				var position_xz: Vector2 = candidate.get("positionXZ", Vector2.INF)
				if String(candidate.get("kind", "")) == "trees_foliage" \
						and not candidate.has("detailType") \
						and position_xz.is_finite() \
						and near_bounds.has_point(Vector2i(floori(position_xz.x), floori(position_xz.y))) \
						and String(candidate.get("treeRenderLodTier", "")) != "near":
					return false
		retire(key)
		var controller := main.get("visible_world_demand_controller") as Object
		if is_instance_valid(controller) and controller.has_method("mark_chunk_dirty"):
			controller.call("mark_chunk_dirty", "player", key)
		return true
	return false


func retire(chunk_key: Vector2i) -> void:
	var root := source_for(chunk_key)
	if root != null:
		root.queue_free()
	roots.erase(chunk_key)
	states.erase(chunk_key)
