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
const ArtifactRequests = preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")
const ResidentCollisionOwner = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const MAX_OWNER_GENERATION := 0x7fffffffffffffff

static var _next_owner_generation := 1

var _backend
var _admission
var _pages
var _planner
var _publisher
var _cells
var _numeric
var _occupancy
var _artifact_requests
var _state := "new"
var _failure := ""
var _seed_text := ""
var _source_identity := {}
var _load_generation := 0
var _owner_generation := 0
var _pending_edit_plan := {}
var _legacy_converter
var _legacy_main
var _legacy_terrain: VoxelTerrain
var _legacy_consumer_id := 0
var _legacy_priority := 0
var _async_stop_requested := false
var _async_stop_receipt: Dictionary = {}

func setup(main, terrain: VoxelTerrain, consumer_id: int, priority: int,
		save_snapshot = null) -> Dictionary:
	if _state != "new": return {"status":"failed", "reason":"owner_already_started"}
	var inputs: Dictionary = _validate_setup_inputs(main, terrain, consumer_id)
	if inputs.get("status") != "ready":
		return _setup_failure(String(inputs.get("reason", "native_owner_inputs_invalid")))
	_admission = inputs.admission
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
	var backend = ClassDB.instantiate("NativeWorldBackend")
	if backend == null: return _setup_failure("native_backend_unavailable")
	var initialized: Dictionary = backend.initialize_from_save_v2(source.request)
	if initialized.get("status") != "ready":
		return _setup_failure(String(initialized.get("reason", "native_initialize_failed")))
	return _activate_initialized_backend(backend, terrain, consumer_id, priority,
		String(source.request.seedText), initialized, false, 0)

## Production loading prepares a private native candidate across frames. The
## owner consumes the committed transaction itself so backend transfer is
## single-use; a caller-authored receipt cannot replay an independently passed
## backend. Adoption never re-imports the save or consults script terrain.
func setup_from_committed_transaction(main, terrain: VoxelTerrain, transaction,
		commit_receipt: Dictionary, consumer_id: int, priority: int) -> Dictionary:
	if _state != "new": return {"status":"failed", "reason":"owner_already_started"}
	var inputs: Dictionary = _validate_setup_inputs(main, terrain, consumer_id)
	if inputs.get("status") != "ready":
		return _setup_failure(String(inputs.get("reason", "native_owner_inputs_invalid")))
	if transaction == null or not transaction.has_method("snapshot") \
			or not transaction.has_method("take_backend"):
		return _setup_failure("committed_transaction_missing")
	var transaction_state: Dictionary = transaction.call("snapshot")
	var generation := int(commit_receipt.get("generation", 0))
	if transaction_state.get("state") != "committed" \
			or commit_receipt.get("status") != "ready" \
			or commit_receipt.get("committed") != true \
			or generation <= 0 \
			or int(transaction_state.get("generation", 0)) != generation \
			or int(transaction_state.get("backendInstanceId", 0)) \
				!= int(commit_receipt.get("backendInstanceId", 0)) \
			or transaction_state.get("sourceIdentity") != commit_receipt.get("sourceIdentity"):
		return _setup_failure("committed_transaction_receipt_mismatch")
	if transaction_state.get("snapshotLeaseValid") != true:
		# The producer must retain its immutable save snapshot until this exact
		# ownership handoff. The native candidate is already committed, so consume
		# the single-use transfer and release it explicitly instead of leaving a
		# committed backend stranded in the transaction.
		var revoked_backend = transaction.call("take_backend")
		if revoked_backend == null or not revoked_backend.has_method("status"):
			return _setup_failure("committed_transaction_transfer_failed")
		return _transferred_backend_failure(revoked_backend,
			"committed_transaction_snapshot_lease_revoked")
	var backend = transaction.call("take_backend")
	if backend == null or not backend.has_method("status"):
		return _setup_failure("committed_transaction_transfer_failed")
	var initialized: Dictionary = backend.status()
	var expected_seed := String(main.get("seed_text"))
	var source_identity = initialized.get("sourceIdentity")
	if initialized.get("status") != "ready" \
			or String(initialized.get("sourceSeedText", "")) != expected_seed \
			or not source_identity is Dictionary \
			or (source_identity as Dictionary).is_empty() \
			or int(commit_receipt.get("backendInstanceId", 0)) != backend.get_instance_id() \
			or commit_receipt.get("sourceIdentity") != source_identity:
		return _transferred_backend_failure(backend, "initialized_backend_source_mismatch")
	_admission = inputs.admission
	return _activate_initialized_backend(backend, terrain, consumer_id, priority,
		expected_seed, initialized, true, generation)

func _activate_initialized_backend(backend, terrain: VoxelTerrain, consumer_id: int,
		priority: int, expected_seed: String, initialized: Dictionary,
		adopted_committed_backend: bool, load_generation: int) -> Dictionary:
	if _backend != null or not _state in ["new", "converting"]:
		return _setup_failure("initialized_backend_adoption_state_invalid")
	_backend = backend
	_seed_text = expected_seed
	_source_identity = initialized.get("sourceIdentity", {}).duplicate(true)
	_load_generation = load_generation
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
	_owner_generation = _claim_owner_generation()
	if _owner_generation <= 0:
		return _setup_failure("native_owner_generation_exhausted")
	_artifact_requests = ArtifactRequests.new()
	var artifacts_ready: Dictionary = _artifact_requests.setup(_backend, _pages,
		_admission, _planner, DemandPlanner.CELL, _owner_generation,
		ResidentCollisionOwner.MAX_RESIDENT)
	if artifacts_ready.get("status") != "ready":
		return _setup_failure(String(artifacts_ready.get("reason", "native_artifact_requests_failed")))
	_publisher = BlockPublisher.new()
	var published: Dictionary = _publisher.setup(_backend, terrain, _pages, consumer_id, priority)
	if published.get("status") != "ready":
		return _setup_failure(String(published.get("reason", "native_publisher_failed")))
	_state = "active"
	return {"status":"ready", "backendInstanceId":_backend.get_instance_id(),
		"sourceIdentity":_source_identity.duplicate(true), "consumerId":consumer_id,
		"adoptedCommittedBackend":adopted_committed_backend,
		"loadGeneration":_load_generation, "ownerGeneration":_owner_generation,
		"sourceSeedText":_seed_text}

func _validate_setup_inputs(main, terrain: VoxelTerrain, consumer_id: int) -> Dictionary:
	if main == null or terrain == null or terrain.generator != null \
			or terrain.automatic_loading_enabled:
		return {"status":"failed", "reason":"manual_terrain_required"}
	if consumer_id <= 0:
		return {"status":"failed", "reason":"invalid_consumer_owner"}
	if terrain.get_format() == null:
		return {"status":"failed", "reason":"voxel_format_missing"}
	var structures = main.get("structure_system")
	var admission = structures.get("citadel_terrain_admission") if structures != null else null
	if admission == null:
		return {"status":"failed", "reason":"site_admission_missing"}
	return {"status":"ready", "admission":admission}

static func _claim_owner_generation() -> int:
	if _next_owner_generation <= 0 or _next_owner_generation > MAX_OWNER_GENERATION:
		return 0
	var claimed := _next_owner_generation
	if _next_owner_generation == MAX_OWNER_GENERATION:
		_next_owner_generation = 0
	else:
		_next_owner_generation += 1
	return claimed

func _transferred_backend_failure(backend, reason: String) -> Dictionary:
	# A committed staged import has no remaining import worker. If validation
	# fails after single-use transfer, explicitly retain then release that backend
	# here rather than leaving it orphaned or pretending the transaction owns it.
	_backend = backend
	_failure = reason
	_release_owners()
	_state = "failed"
	return {"status":"failed", "reason":reason, "cleanupComplete":true,
		"transferredBackendReleased":true}

func replace_demand(primary: Dictionary, other_viewers: Array[Dictionary],
		retained_chunks: Array[Vector2i], foreground_chunks: Array[Vector2i],
		vertical_bounds: Vector2i) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _planner.replace_sources(primary, other_viewers, retained_chunks,
		foreground_chunks, vertical_bounds)

## N5 may request a current source artifact, but this inert owner cannot claim
## physical collision readiness or install a shape.
func request_collision_artifact(block: Vector3i) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.request_block(block)

func required_collision_mesh_blocks() -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _planner.required_collision_mesh_blocks()

func collision_window_layout() -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.collision_window_layout()

func collision_window_source(window_id: Vector3i, layout_token: String) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.collision_window_source(window_id, layout_token)

func acknowledge_collision_window_retired(window_token: String,
		retirement_receipt: Dictionary) -> Dictionary:
	if not _state in ["active", "stopping_async"]:
		return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.acknowledge_collision_window_retired(window_token,
		retirement_receipt)

## N5 claims retirement through this facade so the runtime owner remains the
## source-of-truth boundary for every broker lease and drain acknowledgment.
func claim_collision_window_retirement(window_token: String,
		expected_layout_token: String) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.claim_collision_window_retirement(window_token,
		expected_layout_token)

func validate_collision_window_retirement(window_token: String,
		lease_id: String) -> Dictionary:
	if not _state in ["active", "stopping_async"]:
		return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.validate_collision_window_retirement(window_token,
		lease_id)

func abort_collision_window_retirement(window_token: String, lease_id: String,
		owner_unchanged: bool) -> Dictionary:
	if not _state in ["active", "stopping_async"]:
		return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.abort_collision_window_retirement(window_token,
		lease_id, owner_unchanged)

func advance_collision_artifacts() -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.advance()

func collision_source_snapshot() -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.collision_source_snapshot()

func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
	if _state != "active": return {"status":"failed", "reason":"owner_not_active"}
	return _artifact_requests.collision_artifact_row(block, identity)

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
	var artifact_observed: Dictionary = _artifact_requests.observe_verified_durable_edit(
		receipt, planned)
	if artifact_observed.get("status") != "ready":
		return _active_failure("native_artifact_edit_observation_failed")
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
	if _state == "active":
		return request_stop()
	if _state == "stopping_async":
		return drain_step()
	if _publisher == null:
		_release_owners()
		return {"status":"ready", "drained":true}
	_state = "stopping"
	if _artifact_requests != null:
		var artifact_stopped: Dictionary = _artifact_requests.stop()
		if artifact_stopped.get("status") != "ready": return artifact_stopped
	var stopped: Dictionary = _publisher.stop()
	if stopped.get("status") != "ready": return stopped
	return drain_step()

## Non-blocking shutdown request for composed runtimes. Retirement proceeds one
## bounded owner drain step at a time; unlike stop(), this never spins until all
## queued blocks/windows have been released.
func request_stop() -> Dictionary:
	if _state == "drained": return {"status":"ready", "drained":true}
	if _state == "stopping_async":
		return {"status":"pending", "reason":"native_owner_retirement_in_progress"}
	if _state != "active": return {"status":"failed", "reason":"native_owner_not_active_for_async_stop"}
	_async_stop_requested = true
	_state = "stopping_async"
	var artifacts: Dictionary = _artifact_requests.request_stop()
	if artifacts.get("status") == "failed":
		_failure = String(artifacts.get("reason", "native_artifact_stop_request_failed"))
		return {"status":"failed", "reason":_failure}
	var publisher: Dictionary = _publisher.request_stop()
	if publisher.get("status") == "failed":
		_failure = String(publisher.get("reason", "native_publisher_stop_request_failed"))
		return {"status":"failed", "reason":_failure}
	return {"status":"pending", "reason":"native_owner_retirement_requested",
		"ownerGeneration":_owner_generation, "sourceIdentity":_source_identity.duplicate(true)}

func drain_step() -> Dictionary:
	if _state == "stopping_async":
		var artifact_step: Dictionary = _artifact_requests.drain_step()
		if artifact_step.get("status") == "failed":
			return artifact_step
		if artifact_step.get("status") != "ready":
			return {"status":"pending", "reason":"native_artifact_retirement_pending",
				"artifactStep":artifact_step}
		var publisher_step: Dictionary = _publisher.drain_step()
		if publisher_step.get("status") == "failed": return publisher_step
		if publisher_step.get("status") != "ready":
			return {"status":"pending", "reason":"native_block_retirement_pending",
				"publisherStep":publisher_step}
		var retired_generation := _owner_generation
		var retired_source := _source_identity.duplicate(true)
		_async_stop_receipt = {"status":"ready", "drained":true,
			"physicalBlocksUnloaded":publisher_step.get("physicalBlocksUnloaded") == true,
			"nativeWorkersDrained":artifact_step.get("nativeWorkersDrained") == true
				and publisher_step.get("nativeWorkersDrained") == true,
			"demandReleased":publisher_step.get("remainingDemanded") == 0
				and publisher_step.get("remainingRequested") == 0
				and publisher_step.get("remainingInserted") == 0
				and publisher_step.get("remainingOrphaned") == 0,
			"leasesReleased":artifact_step.get("leasesReleased") == true
				and artifact_step.get("windowSourcesReleased") == true,
			"ownerGeneration":retired_generation, "sourceIdentity":retired_source}
		if not _async_stop_receipt.physicalBlocksUnloaded \
				or not _async_stop_receipt.nativeWorkersDrained \
				or not _async_stop_receipt.demandReleased \
				or not _async_stop_receipt.leasesReleased:
			return {"status":"failed", "reason":"native_owner_retirement_receipt_incomplete",
				"retirementReceipt":_async_stop_receipt}
		_release_owners()
		return _async_stop_receipt.duplicate(true)
	if _state == "stopping_conversion":
		var drained: Dictionary = _legacy_converter.advance()
		if drained.get("status") != "ready": return drained
		_release_owners()
		return {"status":"ready", "drained":true}
	if _state != "stopping": return {"status":"failed", "reason":"stop_before_drain"}
	if _artifact_requests != null:
		var artifact_drained: Dictionary = _artifact_requests.drain_step()
		if artifact_drained.get("status") != "ready": return artifact_drained
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
		"ownerGeneration":_owner_generation,
		"sourceIdentity":_source_identity.duplicate(true),
		"planner":_planner.diagnostics() if _planner != null else {},
		"publisher":_publisher.snapshot() if _publisher != null else {},
		"artifactRequests":_artifact_requests.snapshot() if _artifact_requests != null else {},
		"asyncStopReceipt":_async_stop_receipt.duplicate(true)}

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
	_artifact_requests = null
	_planner = null
	_pages = null
	_backend = null
	_admission = null
	_seed_text = ""
	_source_identity.clear()
	_pending_edit_plan.clear()
	_state = "drained"
