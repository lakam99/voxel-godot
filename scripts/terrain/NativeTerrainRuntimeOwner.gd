extends RefCounted
class_name NativeTerrainRuntimeOwner

## Inert N3 cutover component. The production runtime must install this only
## after turning off the script generator and automatic data loading. One
## NativeWorldBackend instance owns save-v2 terrain, shaping, block bytes and
## gameplay cell queries. There is deliberately no script-source fallback.
const SourceRequest = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PageAdmission = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const DemandPlanner = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const BlockPublisher = preload("res://scripts/terrain/NativeTerrainBlockPublisher.gd")
const CellSource = preload("res://scripts/terrain/NativeTerrainCellSource.gd")
const NumericSource = preload("res://scripts/terrain/NativeTerrainNumericSource.gd")

var _backend
var _admission
var _pages
var _planner
var _publisher
var _cells
var _numeric
var _state := "new"
var _failure := ""

func setup(main, terrain: VoxelTerrain, consumer_id: int, priority: int) -> Dictionary:
	if _state != "new": return {"status":"failed", "reason":"owner_already_started"}
	if main == null or terrain == null or terrain.generator != null \
			or terrain.automatic_loading_enabled:
		return _setup_failure("manual_terrain_required")
	var structures = main.get("structure_system")
	_admission = structures.get("citadel_terrain_admission") if structures != null else null
	if _admission == null: return _setup_failure("site_admission_missing")
	var source: Dictionary = SourceRequest.from_main_with_current_volume(main)
	if source.get("status") != "ready":
		return _setup_failure(String(source.get("reason", "native_source_request_failed")))
	_backend = ClassDB.instantiate("NativeWorldBackend")
	if _backend == null: return _setup_failure("native_backend_unavailable")
	var initialized: Dictionary = _backend.initialize_from_save_v2(source.request)
	if initialized.get("status") != "ready":
		return _setup_failure(String(initialized.get("reason", "native_initialize_failed")))
	_pages = PageAdmission.new()
	var page_ready: Dictionary = _pages.setup(_backend, _admission)
	if page_ready.get("status") != "ready":
		return _setup_failure(String(page_ready.get("reason", "native_shaping_bridge_failed")))
	_planner = DemandPlanner.new()
	var plan_ready: Dictionary = _planner.setup(consumer_id)
	if plan_ready.get("status") != "ready":
		return _setup_failure(String(plan_ready.get("reason", "native_demand_planner_failed")))
	_cells = CellSource.new()
	var cells_ready: Dictionary = _cells.bind(_backend)
	if cells_ready.get("status") != "ready":
		return _setup_failure(String(cells_ready.get("reason", "native_cell_source_failed")))
	_numeric = NumericSource.new()
	var numeric_ready: Dictionary = _numeric.bind(_backend)
	if numeric_ready.get("status") != "ready":
		return _setup_failure(String(numeric_ready.get("reason", "native_numeric_source_failed")))
	_publisher = BlockPublisher.new()
	var published: Dictionary = _publisher.setup(_backend, terrain, _pages, consumer_id, priority)
	if published.get("status") != "ready":
		return _setup_failure(String(published.get("reason", "native_publisher_failed")))
	_state = "active"
	return {"status":"ready", "backendInstanceId":_backend.get_instance_id(),
		"sourceIdentity":initialized.get("sourceIdentity", {}), "consumerId":consumer_id}

func replace_demand(primary: Dictionary, other_viewers: Array[Dictionary],
		retained_chunks: Array[Vector2i], foreground_chunks: Array[Vector2i],
		vertical_bounds: Vector2i) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _planner.replace_sources(primary, other_viewers, retained_chunks,
		foreground_chunks, vertical_bounds)

func advance() -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	# The same production site authority must advance its own source queue.
	var site: Dictionary = _admission.advance()
	if not String(site.get("failure", "")).is_empty():
		return _active_failure(String(site.failure))
	var delta: Dictionary = _planner.next_delta()
	if delta.get("status") == "failed": return _active_failure(String(delta.get("reason", "native_demand_failed")))
	if delta.get("status") == "ready":
		var accepted: Dictionary = _publisher.apply_data_block_delta(delta.addBlocks, delta.removeBlocks)
		if accepted.get("status") == "failed":
			return _active_failure(String(accepted.get("reason", "native_publisher_demand_failed")))
		var acknowledged: Dictionary = _planner.acknowledge_delta(int(delta.ticket),
			accepted.get("status") == "ready")
		if acknowledged.get("status") == "failed":
			return _active_failure(String(acknowledged.get("reason", "native_demand_ack_failed")))
	var publication: Dictionary = _publisher.pump()
	if publication.get("status") == "failed":
		return _active_failure(String(publication.get("reason", "native_publication_failed")))
	return {"status":"pending" if publication.get("status") == "pending"
		else "ready", "publication":publication, "demand":delta.get("status", "idle")}

func read_cell(cell: Vector3i) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _cells.read_cell(cell)

func read_cells(cells: Array[Vector3i]) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _cells.read_cells(cells)

func read_numeric_batch(world_positions: Array[Vector3], projection_cells: Array[Vector3i]) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _numeric.read_numeric_batch(world_positions, projection_cells)

func stop() -> Dictionary:
	if _state == "drained": return {"status":"ready", "drained":true}
	if _state == "new":
		_state = "drained"
		return {"status":"ready", "drained":true}
	if _publisher == null:
		_release_owners()
		return {"status":"ready", "drained":true}
	_state = "stopping"
	var stopped: Dictionary = _publisher.stop()
	if stopped.get("status") != "ready": return stopped
	return drain_step()

func drain_step() -> Dictionary:
	if _state != "stopping": return {"status":"failed", "reason":"stop_before_drain"}
	var stopped: Dictionary = _publisher.stop()
	if stopped.get("status") != "ready": return stopped
	var drained: Dictionary = _publisher.drain_step()
	if drained.get("status") == "ready":
		_release_owners()
		return {"status":"ready", "drained":true}
	return drained

func snapshot() -> Dictionary:
	return {"state":_state, "failure":_failure,
		"backendInstanceId":_backend.get_instance_id() if _backend != null else 0,
		"backend":_backend.status() if _backend != null else {},
		"planner":_planner.diagnostics() if _planner != null else {},
		"publisher":_publisher.snapshot() if _publisher != null else {}}

func _setup_failure(reason: String) -> Dictionary:
	_failure = reason
	_release_owners()
	_state = "failed"
	return {"status":"failed", "reason":reason}

func _active_failure(reason: String) -> Dictionary:
	_failure = reason
	_state = "failed"
	return {"status":"failed", "reason":reason}

func _release_owners() -> void:
	_publisher = null
	_cells = null
	_numeric = null
	_planner = null
	_pages = null
	_backend = null
	_admission = null
	_state = "drained"
