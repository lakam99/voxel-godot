extends SceneTree

const PLANNER := preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const BROKER := preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")
const PRODUCER := preload("res://scripts/terrain/NativeTerrainTriangleArtifactProducer.gd")

class SyncPathSpyPlanner:
	extends "res://scripts/terrain/NativeTerrainDemandPlanner.gd"
	var synchronous_layout_calls := 0
	func collision_mesh_window_layout() -> Dictionary:
		synchronous_layout_calls += 1
		return super.collision_mesh_window_layout()

class LayoutSource:
	extends RefCounted
	var snapshot := {}
	func status() -> Dictionary:
		return snapshot.duplicate(true)

const WORK_LIMIT := 256
var failures: Array[String] = []
var maximum_observed_work := 0
var total_work := 0
var advance_count := 0

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func _same_layout(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.get("requiredBlocks") != expected.get("requiredBlocks") \
			or actual.get("logicalDemandRevision") != expected.get("logicalDemandRevision") \
			or actual.get("logicalClosureToken") != expected.get("logicalClosureToken"):
		return false
	var left_windows: Array = actual.get("windows", [])
	var right_windows: Array = expected.get("windows", [])
	if left_windows.size() != right_windows.size(): return false
	for index in range(left_windows.size()):
		var left: Dictionary = left_windows[index]
		var right: Dictionary = right_windows[index]
		if left.get("id") != right.get("id") or left.get("blocks") != right.get("blocks") \
				or left.get("closureToken") != right.get("closureToken"):
			return false
	return true

func _drive(broker, label: String, expected_source_hex: String = "") -> Dictionary:
	for _index in range(1200):
		var result: Dictionary = broker._refresh_window_layout()
		var published: Dictionary = broker._window_layout
		if not expected_source_hex.is_empty() and not published.is_empty():
			check(String(published.get("sourceIdentity", {}).get("hex", ""))
				== expected_source_hex,
				"%s never publishes layout from stale source identity" % label)
		if result.get("status") == "ready": return result
		if result.has("workOps"):
			var work := int(result.get("workOps", -1))
			var maximum := int(result.get("maxWorkOps", -1))
			check(work >= 0 and maximum == WORK_LIMIT and work <= maximum,
				"%s step respects bounded planner work (%d/%d)" % [label, work, maximum])
			maximum_observed_work = maxi(maximum_observed_work, work)
			total_work += work
			advance_count += 1
		await process_frame
	check(false, "%s completes within bounded advances" % label)
	print("N3 staged consumer timeout state for %s: job=%s transaction=%s" % [
		label, JSON.stringify(broker._window_layout_job),
		JSON.stringify(broker._planner.collision_mesh_snapshot_transaction_state())])
	return {"status":"timeout"}

func _new_broker(planner, source, identity: Dictionary,
		owner_generation: int = 711):
	var broker = BROKER.new()
	var setup: Dictionary = broker.setup(source, RefCounted.new(), RefCounted.new(),
		planner, 1.35, owner_generation, 4096)
	broker._identity = identity.duplicate(true)
	return {"broker":broker, "setup":setup}

func _drain_stop(broker, label: String) -> Dictionary:
	var result: Dictionary = broker.request_stop()
	for _step in range(1200):
		if result.get("status") == "ready": return result
		result = broker.drain_step()
		if result.has("workOps"):
			var work := int(result.get("workOps", -1))
			var maximum := int(result.get("maxWorkOps", -1))
			check(work >= 0 and maximum == WORK_LIMIT and work <= maximum,
				"%s stop step respects layout work cap (%d/%d)" % [label, work, maximum])
			maximum_observed_work = maxi(maximum_observed_work, work)
			total_work += work
			advance_count += 1
		await process_frame
	check(false, "%s stop reaches drained terminal state" % label)
	return result

func _replace(planner, position: Vector3, distance: int, bounds: Vector2i) -> Dictionary:
	var viewers: Array[Dictionary] = []
	var retained: Array[Vector2i] = []
	var foreground: Array[Vector2i] = []
	return planner.replace_sources({"position":position, "distance":distance},
		viewers, retained, foreground, bounds)

func _drain_owned_snapshot(planner, kind: String, token: int, label: String) -> Dictionary:
	var result: Dictionary = {}
	var terminal: Dictionary = {}
	for _step in range(300):
		result = planner.advance_required_collision_mesh_blocks(token) \
			if kind == "requiredBlocks" else planner.advance_collision_mesh_window_layout(token)
		if result.has("workOps"):
			var work := int(result.get("workOps", -1))
			var maximum := int(result.get("maxWorkOps", -1))
			check(work >= 0 and maximum == WORK_LIMIT and work <= maximum,
				"%s advance respects bounded planner work (%d/%d)" % [label, work, maximum])
			maximum_observed_work = maxi(maximum_observed_work, work)
			total_work += work
			advance_count += 1
		if result.get("status") == "ready" or result.get("status") == "failed":
			terminal = result
		var owner: Dictionary = planner.collision_mesh_snapshot_transaction_state()
		if not terminal.is_empty() and not bool(owner.get("hasPendingRetirement", false)):
			return terminal
		if result.get("status") == "failed": return result
		await process_frame
	check(false, "%s reaches a terminal transaction result" % label)
	return {"status":"timeout"}

func _drain_producer_snapshot(producer, label: String) -> Dictionary:
	var result: Dictionary = {}
	for _step in range(300):
		result = producer.advance_demand_snapshot()
		if result.has("workOps"):
			var work := int(result.get("workOps", -1))
			var maximum := int(result.get("maxWorkOps", -1))
			check(work >= 0 and maximum > 0 and work <= maximum and maximum <= WORK_LIMIT + 1,
				"%s advance respects producer work budget (%d/%d)" % [label, work, maximum])
			maximum_observed_work = maxi(maximum_observed_work, work)
			total_work += work
			advance_count += 1
		if result.get("status") != "pending": return result
		await process_frame
	check(false, "%s reaches a terminal demand snapshot" % label)
	return {"status":"timeout"}

func run() -> void:
	var spy = SyncPathSpyPlanner.new()
	var reference = PLANNER.new()
	var spy_setup: Dictionary = spy.setup(711)
	var reference_setup: Dictionary = reference.setup(711)
	var first_position := Vector3(-1.35 * 512.0, 0.0, -1.35 * 32.0)
	var first_demand := _replace(spy, first_position, 128, Vector2i(-32,32))
	var reference_first_demand := _replace(reference, first_position, 128,
		Vector2i(-32,32))
	var reference_first: Dictionary = reference.collision_mesh_window_layout()
	var source = LayoutSource.new()
	source.snapshot = {"status":"ready", "terrainDeltaRevision":0,
		"shapingRegistryRevision":0,
		"sourceIdentity":{"hex":"consumer-source-a", "seedHash":"consumer-seed"}}
	var initial_identity := {"ownerGeneration":711, "sourceRevision":0,
		"cancellationEpoch":1, "sourceIdentity":source.snapshot.sourceIdentity.duplicate(true)}
	var binding: Dictionary = _new_broker(spy, source, initial_identity)
	var broker = binding.broker
	var first_step: Dictionary = broker._refresh_window_layout()
	var stale_was_in_flight: bool = first_step.get("status") == "pending" \
		and not broker._window_layout_job.is_empty()
	# Change the authoritative source identity after work has begun. The consumer
	# must cancel/drain that leased candidate before it starts the replacement.
	source.snapshot.sourceIdentity = {"hex":"consumer-source-b", "seedHash":"consumer-seed"}
	broker._identity = {"ownerGeneration":711, "sourceRevision":0,
		"cancellationEpoch":2, "sourceIdentity":source.snapshot.sourceIdentity.duplicate(true)}
	var first_result: Dictionary = await _drive(broker, "stale-source drain and retry",
		"consumer-source-b")
	var first_exact := _same_layout(broker._window_layout, reference_first)
	check(spy_setup.get("status") == "ready" and reference_setup.get("status") == "ready"
		and first_demand.get("status") == "ready"
		and reference_first_demand.get("status") == "ready"
		and stale_was_in_flight and first_result.get("status") == "ready"
		and first_exact,
		"negative-coordinate layout drains stale source work then matches sync reference exactly")
	check(broker._window_layout.get("sourceIdentity") == source.snapshot.sourceIdentity
		and broker._window_layout_job.is_empty()
		and spy._mesh_layout_lease == null
		and not spy._mesh_layout_builder.is_active()
		and not spy._mesh_layout_builder.has_pending_retirement(),
		"stale transaction does not publish and all cancellation lease/scratch drains before retry")
	var second_position := Vector3(-1.35 * 256.0, 0.0, 1.35 * 256.0)
	var second_demand := _replace(spy, second_position, 16, Vector2i(-16,32))
	var reference_second_demand := _replace(reference, second_position, 16,
		Vector2i(-16,32))
	var reference_second: Dictionary = reference.collision_mesh_window_layout()
	var second_result: Dictionary = await _drive(broker, "changed demand revision")
	check(second_demand.get("status") == "ready"
		and reference_second_demand.get("status") == "ready"
		and int(broker._window_layout.get("logicalDemandRevision", -1))
			> int(first_result.get("logicalDemandRevision", -1))
		and _same_layout(broker._window_layout, reference_second)
		and second_result.get("status") == "ready",
		"new demand revision atomically matches every synchronous-reference window/block")
	check(spy.synchronous_layout_calls == 0 and broker._window_layout_job.is_empty()
		and spy._mesh_layout_lease == null,
		"production broker consumer never invokes synchronous compatibility layout API")
	print("N3 staged consumer phase: shared producer/broker interleaving")
	# Reproduce the real shared-builder collision: the triangle producer owns a
	# required-block snapshot when the artifact broker asks for a layout. A
	# generic pending result must never be adopted as the broker's layout token.
	var shared_planner = SyncPathSpyPlanner.new()
	shared_planner.setup(714)
	var shared_demand := _replace(shared_planner, Vector3.ZERO, 0, Vector2i(0,0))
	var shared_source = LayoutSource.new()
	shared_source.snapshot = source.snapshot.duplicate(true)
	var shared_identity := {"ownerGeneration":714, "sourceRevision":0,
		"cancellationEpoch":1,
		"sourceIdentity":shared_source.snapshot.sourceIdentity.duplicate(true)}
	var shared_binding: Dictionary = _new_broker(shared_planner, shared_source,
		shared_identity, 714)
	var shared_broker = shared_binding.broker
	var shared_producer = PRODUCER.new()
	var producer_setup: Dictionary = shared_producer.setup(shared_source,
		RefCounted.new(), RefCounted.new(), shared_planner, 1.35,
		{"ownerGeneration":714, "sourceRevision":0, "cancellationEpoch":1,
			"sourceEpoch":"n3-staged-owner-interleaving"})
	var required_token := int(shared_producer._demand_snapshot_token)
	var blocked_layout: Dictionary = shared_broker._refresh_window_layout()
	var blocked_owner: Dictionary = blocked_layout.get("transaction", {})
	var shared_diagnostics: Dictionary = shared_planner.diagnostics()
	var broker_did_not_adopt_required: bool = blocked_layout.get("status") == "pending" \
		and shared_broker._window_layout_job.is_empty() \
		and String(blocked_owner.get("status", "")) == "active" \
		and String(blocked_owner.get("kind", "")) == "requiredBlocks" \
		and int(blocked_owner.get("token", 0)) == required_token \
		and int(blocked_owner.get("revision", -1)) == int(shared_diagnostics.demandRevision) \
		and String(blocked_owner.get("closureToken", "")) \
			== String(shared_diagnostics.closureToken)
	var required_result: Dictionary = await _drain_producer_snapshot(shared_producer,
		"real triangle producer required-block transaction")
	var shared_sync := PLANNER.new()
	shared_sync.setup(714)
	var shared_sync_demand := _replace(shared_sync, Vector3.ZERO, 0,
		Vector2i(0,0))
	var shared_reference: Dictionary = shared_sync.collision_mesh_window_layout()
	var shared_layout_result: Dictionary = await _drive(shared_broker,
		"retry after required-block owner completes")
	check(shared_demand.get("status") == "ready"
		and producer_setup.get("status") == "ready" and required_token > 0
		and broker_did_not_adopt_required and required_result.get("status") == "ready"
		and shared_sync_demand.get("status") == "ready"
		and shared_layout_result.get("status") == "ready"
		and _same_layout(shared_broker._window_layout, shared_reference),
		"requiredBlocks/layout interleaving rejects foreign token then retries to exact parity")
	print("N3 staged consumer phase: stop waits for foreign staged owner")
	var foreign_stop_planner = SyncPathSpyPlanner.new()
	foreign_stop_planner.setup(718)
	var foreign_stop_demand := _replace(foreign_stop_planner, Vector3.ZERO,
		0, Vector2i(0,0))
	var foreign_stop_source = LayoutSource.new()
	foreign_stop_source.snapshot = source.snapshot.duplicate(true)
	var foreign_stop_identity := {"ownerGeneration":718, "sourceRevision":0,
		"cancellationEpoch":1,
		"sourceIdentity":foreign_stop_source.snapshot.sourceIdentity.duplicate(true)}
	var foreign_stop_binding: Dictionary = _new_broker(foreign_stop_planner,
		foreign_stop_source, foreign_stop_identity, 718)
	var foreign_stop_producer = PRODUCER.new()
	var foreign_stop_setup: Dictionary = foreign_stop_producer.setup(
		foreign_stop_source, RefCounted.new(), RefCounted.new(), foreign_stop_planner,
		1.35, {"ownerGeneration":718, "sourceRevision":0,
			"cancellationEpoch":1, "sourceEpoch":"n3-staged-stop-foreign"})
	var foreign_stop_token := int(foreign_stop_producer._demand_snapshot_token)
	var foreign_stop_request: Dictionary = foreign_stop_binding.broker.stop()
	var foreign_stop_owner: Dictionary = foreign_stop_planner.collision_mesh_snapshot_transaction_state()
	var stop_waited_without_touching_foreign: bool = foreign_stop_request.get("status") == "pending" \
		and foreign_stop_binding.broker._async_stop_requested \
		and String(foreign_stop_owner.get("kind", "")) == "requiredBlocks" \
		and int(foreign_stop_owner.get("token", 0)) == foreign_stop_token \
		and String(foreign_stop_owner.get("status", "")) == "active"
	var foreign_stop_producer_result: Dictionary = await _drain_producer_snapshot(
		foreign_stop_producer, "producer transaction held during broker stop")
	var foreign_stop_drained: Dictionary = foreign_stop_binding.broker.drain_step()
	check(foreign_stop_demand.get("status") == "ready"
		and foreign_stop_setup.get("status") == "ready"
		and stop_waited_without_touching_foreign
		and foreign_stop_producer_result.get("status") == "ready"
		and foreign_stop_drained.get("status") == "ready"
		and not foreign_stop_planner.has_pending_collision_mesh_window_retirement(),
		"stop remains pending through foreign staged owner, then completes after owner drains")
	print("N3 staged consumer phase: producer orphan token retry")
	var producer_orphan_planner = SyncPathSpyPlanner.new()
	producer_orphan_planner.setup(717)
	var producer_orphan_demand := _replace(producer_orphan_planner, Vector3.ZERO,
		0, Vector2i(0,0))
	var producer_orphan_source = LayoutSource.new()
	producer_orphan_source.snapshot = source.snapshot.duplicate(true)
	var producer_orphan = PRODUCER.new()
	var producer_orphan_setup: Dictionary = producer_orphan.setup(
		producer_orphan_source, RefCounted.new(), RefCounted.new(),
		producer_orphan_planner, 1.35,
		{"ownerGeneration":717, "sourceRevision":0, "cancellationEpoch":1,
			"sourceEpoch":"n3-staged-producer-orphan"})
	var abandoned_producer_token := int(producer_orphan._demand_snapshot_token)
	producer_orphan_planner.cancel_required_collision_mesh_blocks(abandoned_producer_token)
	var abandoned_result: Dictionary = await _drain_owned_snapshot(
		producer_orphan_planner, "requiredBlocks", abandoned_producer_token,
		"cancelled producer demand snapshot")
	var foreign_after_abandon: Dictionary = producer_orphan_planner.begin_collision_mesh_window_layout()
	var foreign_after_abandon_token := int(foreign_after_abandon.get("token", 0))
	var foreign_after_abandon_result: Dictionary = await _drain_owned_snapshot(
		producer_orphan_planner, "layout", foreign_after_abandon_token,
		"foreign layout after abandoned producer token")
	var producer_orphan_retry: Dictionary = producer_orphan.advance_demand_snapshot()
	var producer_orphan_restarted: Dictionary = producer_orphan.advance_demand_snapshot()
	var restarted_token := int(producer_orphan_restarted.get("cause", {}).get("token", 0))
	var producer_orphan_result: Dictionary = await _drain_producer_snapshot(
		producer_orphan, "producer after proven orphan ownership loss")
	check(producer_orphan_setup.get("status") == "ready"
		and producer_orphan_demand.get("status") == "ready"
		and abandoned_producer_token > 0 and abandoned_result.get("status") == "ready"
		and foreign_after_abandon.get("status") == "pending"
		and foreign_after_abandon_token > 0
		and foreign_after_abandon_result.get("status") == "ready"
		and producer_orphan_retry.get("status") == "pending"
		and producer_orphan_retry.get("reason") == "triangle_demand_snapshot_orphan_released"
		and producer_orphan_restarted.get("status") == "pending"
		and restarted_token > foreign_after_abandon_token
		and producer_orphan_result.get("status") == "ready",
		"producer treats a proven foreign/idle token as retryable without consuming foreign layout")
	print("N3 staged consumer phase: foreign same-kind layout token")
	# Same-kind is not ownership either: an independent layout token may not be
	# adopted merely because its kind happens to match the broker's request.
	var same_kind_planner = SyncPathSpyPlanner.new()
	same_kind_planner.setup(715)
	_replace(same_kind_planner, Vector3.ZERO, 0, Vector2i(0,0))
	var same_kind_source = LayoutSource.new()
	same_kind_source.snapshot = source.snapshot.duplicate(true)
	var same_kind_identity := {"ownerGeneration":715, "sourceRevision":0,
		"cancellationEpoch":1,
		"sourceIdentity":same_kind_source.snapshot.sourceIdentity.duplicate(true)}
	var same_kind_binding: Dictionary = _new_broker(same_kind_planner,
		same_kind_source, same_kind_identity, 715)
	var same_kind_broker = same_kind_binding.broker
	var foreign_layout: Dictionary = same_kind_planner.begin_collision_mesh_window_layout()
	var foreign_token := int(foreign_layout.get("token", 0))
	var rejected_same_kind: Dictionary = same_kind_broker._refresh_window_layout()
	var same_kind_not_adopted: bool = same_kind_broker._window_layout_job.is_empty() \
		and int(rejected_same_kind.get("transaction", {}).get("token", 0)) == foreign_token
	var foreign_result: Dictionary = await _drain_owned_snapshot(same_kind_planner,
		"layout", foreign_token, "foreign same-kind layout")
	var same_kind_sync = PLANNER.new()
	same_kind_sync.setup(715)
	_replace(same_kind_sync, Vector3.ZERO, 0, Vector2i(0,0))
	var same_kind_reference: Dictionary = same_kind_sync.collision_mesh_window_layout()
	var same_kind_result: Dictionary = await _drive(same_kind_broker,
		"retry after foreign same-kind owner completes")
	check(foreign_layout.get("status") == "pending" and foreign_token > 0
		and same_kind_not_adopted and foreign_result.get("status") == "ready"
		and same_kind_result.get("status") == "ready"
		and _same_layout(same_kind_broker._window_layout, same_kind_reference),
		"same-kind foreign token is not adopted and broker retries to exact parity")
	print("N3 staged consumer phase: transferred layout orphan recovery")
	# A broker job may outlive its builder transaction if another legacy caller
	# consumes the transferred result. It must drain only its matching scratch,
	# discard that orphan result, and produce its own fresh matched result.
	var orphan_planner = SyncPathSpyPlanner.new()
	orphan_planner.setup(716)
	_replace(orphan_planner, Vector3(-1.35 * 256.0, 0.0, 1.35 * 256.0),
		16, Vector2i(-16,32))
	var orphan_source = LayoutSource.new()
	orphan_source.snapshot = source.snapshot.duplicate(true)
	var orphan_identity := {"ownerGeneration":716, "sourceRevision":0,
		"cancellationEpoch":1,
		"sourceIdentity":orphan_source.snapshot.sourceIdentity.duplicate(true)}
	var orphan_binding: Dictionary = _new_broker(orphan_planner, orphan_source,
		orphan_identity, 716)
	var orphan_broker = orphan_binding.broker
	var orphan_begin: Dictionary = orphan_broker._refresh_window_layout()
	var orphan_token := int(orphan_broker._window_layout_job.get("token", 0))
	var orphan_was_still_building: bool = not orphan_broker._window_layout_job.has("completed")
	var stolen_result: Dictionary = await _drain_owned_snapshot(orphan_planner,
		"layout", orphan_token, "externally consumed broker layout")
	var unpublished_before_retry: bool = orphan_broker._window_layout.is_empty()
	var orphan_recovery: Dictionary = await _drive(orphan_broker,
		"retry after transferred layout orphan")
	var orphan_sync = PLANNER.new()
	orphan_sync.setup(716)
	_replace(orphan_sync, Vector3(-1.35 * 256.0, 0.0, 1.35 * 256.0),
		16, Vector2i(-16,32))
	var orphan_reference: Dictionary = orphan_sync.collision_mesh_window_layout()
	check(orphan_begin.get("status") == "pending" and orphan_token > 0
		and orphan_was_still_building
		and stolen_result.get("status") == "ready" and unpublished_before_retry
		and orphan_recovery.get("status") == "ready"
		and _same_layout(orphan_broker._window_layout, orphan_reference)
		and not orphan_planner.has_pending_collision_mesh_window_retirement(),
		"transferred orphan result is never published; own scratch drains then retry matches")
	var mid_stop_planner = SyncPathSpyPlanner.new()
	mid_stop_planner.setup(712)
	_replace(mid_stop_planner, first_position, 128, Vector2i(-32,32))
	var mid_stop_identity := {"ownerGeneration":712, "sourceRevision":0,
		"cancellationEpoch":1,
		"sourceIdentity":source.snapshot.sourceIdentity.duplicate(true)}
	var mid_stop_binding: Dictionary = _new_broker(mid_stop_planner, source,
		mid_stop_identity, 712)
	var mid_stop_broker = mid_stop_binding.broker
	var mid_stop_begin: Dictionary = mid_stop_broker._refresh_window_layout()
	var direct_stop: Dictionary = mid_stop_broker.stop()
	var direct_stop_deferred: bool = direct_stop.get("status") == "pending" \
		and bool(mid_stop_broker._async_stop_requested) \
		and not mid_stop_broker._window_layout_job.is_empty() \
		and mid_stop_planner._mesh_layout_lease != null
	var mid_stop_result: Dictionary = await _drain_stop(mid_stop_broker,
		"mid-build layout cancellation")
	check(mid_stop_binding.setup.get("status") == "ready"
		and mid_stop_begin.get("status") == "pending" and direct_stop_deferred
		and mid_stop_result.get("status") == "ready"
		and mid_stop_planner._mesh_layout_lease == null
		and not mid_stop_planner._mesh_layout_builder.is_active()
		and not mid_stop_planner.has_pending_collision_mesh_window_retirement()
		and mid_stop_broker._window_layout_job.is_empty(),
		"stop cancels mid-build layout and drains lease/scratch before reporting ready")
	var transferred_planner = SyncPathSpyPlanner.new()
	transferred_planner.setup(713)
	_replace(transferred_planner, Vector3.ZERO, 0, Vector2i(0,0))
	var transferred_identity := {"ownerGeneration":713, "sourceRevision":0,
		"cancellationEpoch":1,
		"sourceIdentity":source.snapshot.sourceIdentity.duplicate(true)}
	var transferred_binding: Dictionary = _new_broker(transferred_planner, source,
		transferred_identity, 713)
	var transferred_broker = transferred_binding.broker
	var transferred_begin: Dictionary = transferred_broker._refresh_window_layout()
	var transferred_ready: bool = transferred_broker._window_layout_job.has("completed")
	var transferred_scratch := transferred_planner.has_pending_collision_mesh_window_retirement()
	var transferred_stop: Dictionary = await _drain_stop(transferred_broker,
		"transferred result scratch cancellation")
	check(transferred_binding.setup.get("status") == "ready"
		and transferred_begin.get("status") == "pending" and transferred_ready
		and transferred_scratch and transferred_stop.get("status") == "ready"
		and not transferred_planner.has_pending_collision_mesh_window_retirement()
		and transferred_planner._mesh_layout_lease == null
		and transferred_broker._window_layout_job.is_empty(),
		"stop drains transferred-result scratch before releasing the staged planner")
	var report := {"schema":"n3-staged-window-consumer-contract/v1",
		"passed":failures.is_empty(), "productionCutover":false,
		"evidenceLevel":"focused broker/planner service contract",
		"failures":failures, "metrics":{"workLimit":WORK_LIMIT,
			"maximumObservedWork":maximum_observed_work,
			"totalWork":total_work, "advanceCount":advance_count},
		"checks":{"staleCandidateDrained":stale_was_in_flight
			and not spy._mesh_layout_builder.is_active()
			and not spy.has_pending_collision_mesh_window_retirement(),
			"negativeCoordinateParity":first_exact,
			"changedRevisionParity":_same_layout(broker._window_layout, reference_second),
			"midBuildStopDrained":mid_stop_result.get("status") == "ready"
				and not mid_stop_planner.has_pending_collision_mesh_window_retirement(),
			"directStopRemainsPendingUntilDrain":direct_stop_deferred
				and mid_stop_result.get("status") == "ready",
		"transferredScratchStopDrained":transferred_stop.get("status") == "ready"
			and not transferred_planner.has_pending_collision_mesh_window_retirement(),
		"sharedBuilderOwnerInterleaving":broker_did_not_adopt_required
			and required_result.get("status") == "ready"
			and _same_layout(shared_broker._window_layout, shared_reference),
		"stopWaitsForeignTransaction":stop_waited_without_touching_foreign
			and foreign_stop_producer_result.get("status") == "ready"
			and foreign_stop_drained.get("status") == "ready",
		"producerOrphanTokenRetry":producer_orphan_retry.get("reason")
			== "triangle_demand_snapshot_orphan_released"
			and producer_orphan_restarted.get("status") == "pending"
			and restarted_token > foreign_after_abandon_token
			and producer_orphan_result.get("status") == "ready",
		"sameKindTokenOwnership":same_kind_not_adopted
			and foreign_result.get("status") == "ready"
			and _same_layout(same_kind_broker._window_layout, same_kind_reference),
		"orphanTransferredRetry":unpublished_before_retry
			and stolen_result.get("status") == "ready"
			and _same_layout(orphan_broker._window_layout, orphan_reference),
			"synchronousConsumerCalls":spy.synchronous_layout_calls},
		"doesNotProve":"No VoxelTerrain runtime wiring, physical collision publication, live gameplay, or production cutover."}
	var report_path := OS.get_environment("VWB_N3_STAGED_WINDOW_CONSUMER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
