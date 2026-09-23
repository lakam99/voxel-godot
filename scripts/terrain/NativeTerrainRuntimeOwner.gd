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
const OccupancySource = preload("res://scripts/terrain/NativeTerrainOccupancySource.gd")
const EditPlan = preload("res://scripts/terrain/NativeTerrainEditRepublicationPlan.gd")
const LegacyConverter = preload("res://scripts/terrain/NativeV2LegacyTerrainConverter.gd")

var _backend
var _admission
var _pages
var _planner
var _publisher
var _cells
var _numeric
var _occupancy
var _state := "new"
var _failure := ""
var _seed_text := ""
var _source_identity := {}
var _pending_edit_plan := {}
var _legacy_converter
var _legacy_main
var _legacy_terrain: VoxelTerrain
var _legacy_consumer_id := 0
var _legacy_priority := 0

func setup(main, terrain: VoxelTerrain, consumer_id: int, priority: int,
		save_snapshot = null) -> Dictionary:
	if _state != "new": return {"status":"failed", "reason":"owner_already_started"}
	if main == null or terrain == null or terrain.generator != null \
			or terrain.automatic_loading_enabled:
		return _setup_failure("manual_terrain_required")
	var structures = main.get("structure_system")
	_admission = structures.get("citadel_terrain_admission") if structures != null else null
	if _admission == null: return _setup_failure("site_admission_missing")
	var source: Dictionary = SourceRequest.from_main_with_current_volume(main) \
		if save_snapshot == null else SourceRequest.from_main_with_v2_save(main, save_snapshot)
	if source.get("reason") == "native_legacy_terrain_conversion_required":
		_legacy_converter = LegacyConverter.new()
		var started: Dictionary = _legacy_converter.setup(main, save_snapshot)
		if started.get("status") != "ready":
			return _setup_failure(String(started.get("reason", "legacy_conversion_failed")))
		_legacy_main = main
		_legacy_terrain = terrain
		_legacy_consumer_id = consumer_id
		_legacy_priority = priority
		_state = "converting"
		return {"status":"pending", "reason":"native_legacy_terrain_conversion_required"}
	if source.get("status") != "ready":
		return _setup_failure(String(source.get("reason", "native_source_request_failed")))
	return _activate(source, terrain, consumer_id, priority)

func _activate(source: Dictionary, terrain: VoxelTerrain, consumer_id: int,
		priority: int) -> Dictionary:
	_backend = ClassDB.instantiate("NativeWorldBackend")
	if _backend == null: return _setup_failure("native_backend_unavailable")
	var initialized: Dictionary = _backend.initialize_from_save_v2(source.request)
	if initialized.get("status") != "ready":
		return _setup_failure(String(initialized.get("reason", "native_initialize_failed")))
	_seed_text = String(source.request.seedText)
	_source_identity = initialized.get("sourceIdentity", {}).duplicate(true)
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
	_occupancy = OccupancySource.new()
	var occupancy_ready: Dictionary = _occupancy.bind(_cells)
	if occupancy_ready.get("status") != "ready":
		return _setup_failure(String(occupancy_ready.get("reason", "native_occupancy_source_failed")))
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
	if _state == "converting":
		var converted: Dictionary = _legacy_converter.advance()
		if converted.get("status") == "failed":
			return _setup_failure(String(converted.get("reason", "legacy_conversion_failed")))
		if converted.get("status") != "ready": return converted
		var resolved: Dictionary = _legacy_converter.resolved_save()
		if resolved.get("status") != "ready":
			return _setup_failure(String(resolved.get("reason", "legacy_conversion_export_failed")))
		var source: Dictionary = SourceRequest.from_main_with_v2_save(_legacy_main,
			resolved.save)
		if source.get("status") != "ready":
			return _setup_failure(String(source.get("reason", "legacy_conversion_import_failed")))
		var ready: Dictionary = _activate(source, _legacy_terrain, _legacy_consumer_id,
			_legacy_priority)
		_legacy_converter = null
		_legacy_main = null
		_legacy_terrain = null
		return ready
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

func read_occupancy(cell: Vector3i) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _occupancy.read_occupancy(cell)

## Commit durable cell deltas through the same owner used for reads and saves.
## The returned plan describes work still needed for physical publication; it
## is never a collision/readiness receipt.
func commit_durable_cells(transaction_id: String, expected_revision: int,
		operations: Array, physical_probes: Dictionary = {}) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	if not _pending_edit_plan.is_empty():
		return {"status":"pending", "reason":"physical_edit_barrier_pending",
			"barrier":_pending_edit_plan.get("barrier", {})}
	if transaction_id.is_empty() or operations.is_empty() or operations.size() > 64:
		return {"status":"failed", "reason":"edit_request_invalid"}
	var before: Dictionary = _backend.status()
	if before.get("status") != "ready" or before.get("sourceIdentity") != _source_identity \
			or int(before.get("terrainDeltaRevision", -1)) != expected_revision:
		return {"status":"failed", "reason":"native_edit_revision_mismatch"}
	var cells: Array[Vector3i] = []
	var seen := {}
	for operation in operations:
		if not operation is Dictionary or not operation.get("cell") is Vector3i \
				or not String(operation.get("kind", "")) in ["set", "clear"]:
			return {"status":"failed", "reason":"edit_operation_invalid"}
		var cell: Vector3i = operation.cell
		if seen.has(cell) or operation.kind == "set" and not operation.get("state") is Dictionary:
			return {"status":"failed", "reason":"edit_operation_invalid"}
		seen[cell] = true
		cells.append(cell)
	var anticipated_sections: Array[Vector3i] = []
	var section_set := {}
	for cell in cells:
		var section := Vector3i(floori(float(cell.x) / 16.0),
			floori(float(cell.y) / 16.0), floori(float(cell.z) / 16.0))
		if not section_set.has(section):
			section_set[section] = true
			anticipated_sections.append(section)
	var planned: Dictionary = EditPlan.for_committed_cells(cells,
		anticipated_sections, expected_revision + 1,
		String(_source_identity.get("hex", "")))
	if planned.get("status") != "ready":
		return planned
	var request := {"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":transaction_id, "expectedRevision":expected_revision,
		"operations":operations}
	var receipt: Dictionary = _backend.commit_durable_cells(request)
	if receipt.get("status") != "ready" or receipt.get("commitStatus") != "committed":
		return {"status":receipt.get("status", "failed"),
			"reason":receipt.get("reason", receipt.get("commitStatus", "native_edit_rejected"))}
	var after: Dictionary = _backend.status()
	var revision := int(receipt.get("revision", -1))
	if after.get("status") != "ready" or after.get("sourceIdentity") != _source_identity \
			or revision != expected_revision + 1 \
			or int(after.get("terrainDeltaRevision", -1)) != revision:
		return _active_failure("native_edit_receipt_stale")
	var actual_sections: Array = receipt.get("affectedSections", [])
	if not receipt_matches_plan(actual_sections, planned):
		return _active_failure("native_edit_section_receipt_mismatch")
	_pending_edit_plan = planned
	var observed: Dictionary = _publisher.observe_committed_edit(
		planned.affectedMeshBlocks, physical_probes)
	if observed.get("status") != "ready":
		return _active_failure("native_edit_observation_failed")
	return {"status":"ready", "nativeRevision":revision,
		"affectedSections":receipt.get("affectedSections", []),
		"changedCells":cells, "publicationPlan":planned,
		"physicalReady":false, "blockedResidentMeshes":observed.get("blocked", 0)}

## Candidate validation only. A caller-supplied Dictionary cannot attest to
## live collision or actor occupancy, so this never clears the edit barrier.
func inspect_edit_release_candidate(candidate: Dictionary) -> Dictionary:
	if _state != "active" or _pending_edit_plan.is_empty():
		return {"status":"failed", "reason":"pending_edit_missing"}
	var barrier: Dictionary = _pending_edit_plan.get("barrier", {})
	var current: Dictionary = _backend.status()
	if current.get("status") != "ready" or current.get("sourceIdentity") != _source_identity \
			or int(current.get("terrainDeltaRevision", -1)) != int(barrier.get("nativeRevision", -2)):
		return _active_failure("pending_edit_source_drift")
	if int(candidate.get("ownerInstanceId", 0)) != get_instance_id() \
			or candidate.get("sourceIdentity") != _source_identity \
			or candidate.get("sourceEpoch") != barrier.get("sourceEpoch") \
			or int(candidate.get("nativeRevision", -1)) != int(barrier.get("nativeRevision", -2)) \
			or candidate.get("barrierIdentity") != barrier.get("identity"):
		return {"status":"failed", "reason":"edit_release_identity_mismatch"}
	var windows = candidate.get("subwindowReceipts", null)
	if not windows is Array:
		return {"status":"failed", "reason":"edit_release_receipts_missing"}
	var checked: Dictionary = EditPlan.publication_barrier_status(_pending_edit_plan, windows)
	if checked.get("status") != "ready": return checked
	return {"status":"pending", "reason":"production_physical_owner_unbound",
		"barrierIdentity":barrier.identity}

## Native affectedSections is exactly the conservative one-block neighborhood
## of the edited sections. It must equal the preflighted mesh halo as a set.
static func receipt_matches_plan(sections: Array, plan: Dictionary) -> bool:
	if plan.get("status") != "ready": return false
	var expected: Array = plan.get("affectedMeshBlocks", [])
	if sections.size() != expected.size(): return false
	var seen := {}
	for section in sections:
		if not section is Vector3i or seen.has(section) or not expected.has(section):
			return false
		seen[section] = true
	return true

## The save facade must export the same native owner used by terrain reads.
## Neither VoxelTerrain blocks nor the former script volume are save sources.
func export_terrain_volume_v2() -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	var before: Dictionary = _backend.status()
	if before.get("status") != "ready" or before.get("sourceIdentity") != _source_identity:
		return {"status":"failed", "reason":"native_save_owner_changed"}
	var exported: Dictionary = _backend.export_terrain_volume_v2()
	var after: Dictionary = _backend.status()
	if exported.get("status") != "ready" or exported.get("saveSeedText") != _seed_text \
			or exported.get("sourceIdentity") != _source_identity \
			or int(exported.get("terrainDeltaRevision", -1)) != int(before.get("terrainDeltaRevision", -2)) \
			or after.get("sourceIdentity") != _source_identity \
			or int(after.get("terrainDeltaRevision", -1)) != int(before.get("terrainDeltaRevision", -2)):
		return {"status":"failed", "reason":"native_save_snapshot_stale_or_invalid"}
	var volume = exported.get("terrainVolume")
	if not volume is Dictionary or int(volume.get("schemaVersion", -1)) != 1 \
			or int(volume.get("sectionSize", -1)) != 16 \
			or int(volume.get("revision", -1)) != int(exported.get("persistedRevision", -2)):
		return {"status":"failed", "reason":"native_save_volume_invalid"}
	return {"status":"ready", "terrainVolume":volume, "nativeRevision":int(exported.terrainDeltaRevision),
		"sourceIdentity":_source_identity.duplicate(true), "saveSeedText":_seed_text}

func stop() -> Dictionary:
	if _state == "drained": return {"status":"ready", "drained":true}
	if _state == "converting":
		var cancelled: Dictionary = _legacy_converter.cancel()
		if cancelled.get("status") == "pending":
			_state = "stopping_conversion"
			return cancelled
		_release_owners()
		return {"status":"ready", "drained":true}
	if _state == "stopping_conversion": return drain_step()
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
	if _state == "stopping_conversion":
		var drained: Dictionary = _legacy_converter.advance()
		if drained.get("status") != "ready": return drained
		_release_owners()
		return {"status":"ready", "drained":true}
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
		"pendingEditBarrier":_pending_edit_plan.get("barrier", {}),
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
	_legacy_converter = null
	_legacy_main = null
	_legacy_terrain = null
	_publisher = null
	_cells = null
	_numeric = null
	_occupancy = null
	_planner = null
	_pages = null
	_backend = null
	_admission = null
	_seed_text = ""
	_source_identity.clear()
	_pending_edit_plan.clear()
	_state = "drained"
