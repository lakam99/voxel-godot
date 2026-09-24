extends SceneTree

const PLANNER := preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const BROKER := preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")

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
	for _index in range(30000):
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
	for _step in range(30000):
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
	var mid_stop_result: Dictionary = await _drain_stop(mid_stop_broker,
		"mid-build layout cancellation")
	check(mid_stop_binding.setup.get("status") == "ready"
		and mid_stop_begin.get("status") == "pending"
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
			"transferredScratchStopDrained":transferred_stop.get("status") == "ready"
				and not transferred_planner.has_pending_collision_mesh_window_retirement(),
			"synchronousConsumerCalls":spy.synchronous_layout_calls},
		"doesNotProve":"No VoxelTerrain runtime wiring, physical collision publication, live gameplay, or production cutover."}
	var report_path := OS.get_environment("VWB_N3_STAGED_WINDOW_CONSUMER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
