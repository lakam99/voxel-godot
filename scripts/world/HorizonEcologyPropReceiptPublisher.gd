extends RefCounted
class_name HorizonEcologyPropReceiptPublisher

## Live receipt for a visual-only ordinary prop. The body owns this publisher;
## it holds weak references and checks installed geometry on every query.
var _body: WeakRef
var _main: WeakRef
var _body_id := 0
var _root_id := 0


func configure(body: Node3D, main: Node) -> void:
	_body = weakref(body)
	_main = weakref(main)
	_body_id = body.get_instance_id()
	_root_id = body.get_parent().get_instance_id() if body.get_parent() != null else 0


func visual_receipt_installed(source_identity: String, source_revision: String,
		_world_revision: String, view_revision: int, candidate_id: String,
		metadata: Dictionary, representation_id: String, tier: String) -> bool:
	var body := _body.get_ref() as Node3D if _body != null else null
	var main := _main.get_ref() as Node if _main != null else null
	if not is_instance_valid(body) or not is_instance_valid(main) \
			or body.get_instance_id() != _body_id or body.is_queued_for_deletion() \
			or not body.is_inside_tree() or not body.is_visible_in_tree():
		return false
	var owner := body.get_parent() as Node3D
	if not is_instance_valid(owner) or owner.get_instance_id() != _root_id \
			or owner.is_queued_for_deletion() or not owner.is_inside_tree() \
			or not bool(owner.get_meta("horizon_visual_only", false)):
		return false
	var scan_revision := String(owner.get_meta("chunk_surface_candidate_source_revision", ""))
	if source_identity.is_empty() or scan_revision.is_empty() \
			or not source_revision.begins_with(scan_revision + ":sha256:") \
			or view_revision <= 0 or tier != "horizon" \
			or candidate_id != String(body.get_meta("prop_id", "")) \
			or representation_id != "%s:installed" % candidate_id \
			or int(metadata.get("horizonOrdinaryBodyId", 0)) != _body_id \
			or int(metadata.get("horizonOrdinaryRootId", 0)) != _root_id:
		return false
	var player := main.get("player") as Node3D
	if not is_instance_valid(player):
		return false
	var runtime := main.get("voxel_terrain_runtime") as Object
	var viewer := runtime.get("viewer") as Object if is_instance_valid(runtime) else null
	if not is_instance_valid(viewer):
		return false
	var view_distance := float(viewer.get("view_distance"))
	if not is_finite(view_distance) or view_distance <= 0.0 \
			or Vector2(body.global_position.x, body.global_position.z).distance_to(
				Vector2(player.global_position.x, player.global_position.z)) > view_distance:
		return false
	var camera := player.get("camera") as Camera3D
	var eye := camera.global_position if is_instance_valid(camera) else player.global_position
	return _has_geometry_in_range(body, eye)


func _has_geometry_in_range(node: Node, eye: Vector3) -> bool:
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		if geometry.visible and geometry.is_visible_in_tree() \
				and geometry.visibility_range_end > 0.0 \
				and geometry.global_position.distance_to(eye) + 3.0 < geometry.visibility_range_end:
			if geometry is MeshInstance3D and (geometry as MeshInstance3D).mesh != null:
				return true
			if geometry is MultiMeshInstance3D and (geometry as MultiMeshInstance3D).multimesh != null:
				return true
	for child in node.get_children():
		if child is Node and _has_geometry_in_range(child, eye):
			return true
	return false
