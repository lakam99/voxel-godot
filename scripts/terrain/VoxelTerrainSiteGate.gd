extends RefCounted
class_name VoxelTerrainSiteGate

## Main-thread owner of every native viewer's admitted footprint. Unadmitted
## viewers stay OFF TREE: turning off visuals/collisions still loads voxel data.
## A foreign viewer disables automatic loading synchronously on node_added.
const CELL := 1.35
const NATIVE_MAX_VIEW_DISTANCE := 128
# Conservative native-cell allowance: max view radius plus two maximum (32)
# mesh blocks. Includes grid rounding, data neighbours and mesher input padding.
const NATIVE_HALO_CELLS := 64
var _runtime: Node3D
var _terrain
var _admission
var _store
var _world
var _owned: Dictionary = {}
var _requests: Dictionary = {}
var _failure := ""
var _stopped := false
var _attached := 0
var _manual_data_mode := false

func setup(runtime: Node3D, terrain, admission, world, manual_data_mode: bool = false) -> void:
	_runtime = runtime
	_terrain = terrain
	_admission = admission
	_store = admission.profile_store
	_world = world
	_manual_data_mode = manual_data_mode
	_terrain.automatic_loading_enabled = false
	_runtime.get_tree().node_added.connect(_node_added)
	_scan_existing(_runtime.get_tree().root)

func current() -> bool:
	return _store == _admission.profile_store

static func footprint(position: Vector3, distance: int) -> Rect2i:
	# Taking the distance in cells as well as world units overestimates for this
	# game's 1.35 scale. Native distance is capped independently by the terrain.
	var radius := mini(NATIVE_MAX_VIEW_DISTANCE,maxi(0,distance)) + NATIVE_HALO_CELLS
	var center := Vector2i(floori(position.x / CELL),floori(position.z / CELL))
	return Rect2i(center-Vector2i.ONE*radius,Vector2i.ONE*(2*radius+1))

func request_viewer(viewer: Node3D, world_position: Vector3, distance: int) -> bool:
	if _stopped or not is_instance_valid(viewer): return false
	_owned[viewer.get_instance_id()] = weakref(viewer)
	_requests[viewer.get_instance_id()] = {"viewer":weakref(viewer),"position":world_position,"distance":distance}
	return _try_request(_requests[viewer.get_instance_id()])

func request_cells(bounds: Rect2i) -> Dictionary:
	if not _failure.is_empty(): return {"status":"failed","reason":_failure}
	if not current(): return {"status":"pending","reason":"terrain_generation_reset_pending"}
	return _admission.request_bounds(bounds)

func advance() -> void:
	if _stopped: return
	_admission.advance()
	if not current():
		_terrain.automatic_loading_enabled = false
		return
	_world.refresh_generated_site_profiles()
	for id in _requests.keys():
		var request: Dictionary = _requests[id]
		if request.viewer.get_ref() == null:
			_requests.erase(id)
			_owned.erase(id)
		else:
			_try_request(request)
	_terrain.automatic_loading_enabled = not _manual_data_mode and _failure.is_empty() and _attached > 0

func _try_request(request: Dictionary) -> bool:
	if not _failure.is_empty() or not current(): return false
	var result := request_cells(footprint(request.position,request.distance))
	if result.status == "failed":
		_failure = result.reason
		_terrain.automatic_loading_enabled = false
		return false
	if result.status != "ready": return false
	_world.refresh_generated_site_profiles()
	var viewer: Node3D = request.viewer.get_ref()
	if viewer == null: return false
	viewer.set("view_distance",request.distance)
	# Configure parent-relative transform BEFORE entering the tree, so the engine
	# never registers this admitted viewer at the old origin for one update.
	if not viewer.is_inside_tree():
		viewer.position = _runtime.to_local(request.position)
		_runtime.add_child(viewer)
		_attached += 1
	else:
		viewer.global_position = request.position
	return true

func remove_viewer(viewer: Node3D) -> void:
	if viewer == null or not is_instance_valid(viewer): return
	_requests.erase(viewer.get_instance_id())
	_owned.erase(viewer.get_instance_id())
	if viewer.get_parent() == _runtime:
		_runtime.remove_child(viewer)
		_attached = maxi(0,_attached-1)

func stop() -> void:
	if _stopped: return
	_stopped = true
	_terrain.automatic_loading_enabled = false
	if _runtime.get_tree().node_added.is_connected(_node_added):
		_runtime.get_tree().node_added.disconnect(_node_added)
	for id in _owned.keys():
		var viewer: Node3D = _owned[id].get_ref()
		if viewer != null: remove_viewer(viewer)
	_requests.clear()

func failure_reason() -> String:
	return _failure

func _node_added(node: Node) -> void:
	if node is VoxelViewer and not _owned.has(node.get_instance_id()):
		# node_added runs synchronously in add_child, before the next fixed-terrain
		# main-thread loading update. No periodic post-publication scan is relied on.
		_failure = "unowned_voxel_viewer"
		_terrain.automatic_loading_enabled = false

func _scan_existing(node: Node) -> void:
	_node_added(node)
	for child in node.get_children(): _scan_existing(child)
