extends SceneTree

const PLANNER := preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const LEASE := preload("res://scripts/terrain/NativeTerrainDemandRequestLease.gd")
const MESH_LEASE := preload("res://scripts/terrain/NativeTerrainMeshLayoutRequestLease.gd")
const MESH_BUILDER := preload("res://scripts/terrain/NativeTerrainCollisionMeshLayoutBuilder.gd")
const WORK_LIMIT := 256

var failures: Array[String] = []
var observed_max_work_ops := 0
var total_work_ops := 0
var advance_count := 0

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func _new_lease(primary: Dictionary, viewers: Array[Dictionary],
		retained: Array[Vector2i], foreground: Array[Vector2i],
		bounds: Vector2i, revision: int = 1):
	var lease = LEASE.new()
	return lease if lease.acquire(RefCounted.new(), primary, viewers,
		retained, foreground, bounds, revision) else null

func _accepted_snapshot(planner) -> Dictionary:
	return {"sources":planner._sources.duplicate(true),
		"meshSources":planner._mesh_sources.duplicate(true),
		"desired":planner._desired.duplicate(true),
		"priority":planner._desired_priority.duplicate(true),
		"required":planner._required_mesh_blocks.duplicate(true),
		"applied":planner._applied.duplicate(true),
		"revision":planner._demand_revision, "closure":planner._closure_token}

func _assert_snapshot(planner, expected: Dictionary, label: String) -> void:
	check(planner._sources == expected.sources
		and planner._mesh_sources == expected.meshSources
		and planner._desired == expected.desired
		and planner._desired_priority == expected.priority
		and planner._required_mesh_blocks == expected.required
		and planner._applied == expected.applied
		and planner._demand_revision == expected.revision
		and planner._closure_token == expected.closure, label)

func _sum_breakdown(value: Dictionary) -> int:
	var sum := 0
	for count in value.get("workBreakdown", {}).values(): sum += int(count)
	return sum

func _step(planner, accepted_while_pending: Dictionary = {}) -> Dictionary:
	var result: Dictionary = planner.advance_replace_sources()
	var work_ops := int(result.get("workOps", -1))
	advance_count += 1
	check(work_ops >= 0 and work_ops <= WORK_LIMIT
		and int(result.get("maxWorkOps", -1)) == WORK_LIMIT,
		"each advance, including terminal ticks, respects the hard work bound")
	check(_sum_breakdown(result) == work_ops,
		"reported work breakdown exactly accounts for every operation")
	observed_max_work_ops = maxi(observed_max_work_ops, work_ops)
	total_work_ops += maxi(0, work_ops)
	if not accepted_while_pending.is_empty() and (result.get("status") != "ready"
			or result.get("cancelled", false)):
		_assert_snapshot(planner, accepted_while_pending,
			"accepted sources, desired/applied sets and closure stay unchanged while candidate is pending")
	return result

func _layout_step(planner, accepted_snapshot: Dictionary = {}) -> Dictionary:
	var result: Dictionary = planner.advance_collision_mesh_window_layout()
	var work_ops := int(result.get("workOps", -1))
	advance_count += 1
	check(work_ops >= 0 and work_ops <= WORK_LIMIT
		and int(result.get("maxWorkOps", -1)) == WORK_LIMIT,
		"layout advance, including terminal ticks, respects the hard work bound")
	check(_sum_breakdown(result) == work_ops,
		"layout work breakdown exactly accounts for every operation")
	observed_max_work_ops = maxi(observed_max_work_ops, work_ops)
	total_work_ops += maxi(0, work_ops)
	if not accepted_snapshot.is_empty():
		_assert_snapshot(planner, accepted_snapshot,
			"layout construction and cancellation leave accepted demand unchanged")
	return result

func _drive(planner, snapshot: Dictionary = {}, max_advances := 20000) -> Dictionary:
	var result := {}
	for _index in range(max_advances):
		result = _step(planner, snapshot)
		if result.get("status") == "ready" or result.get("status") == "failed" \
				or (result.get("status") == "pending" and result.get("retryable", false)):
			return result
		await process_frame
	return {"status":"timeout", "reason":"demand_replacement_contract_timeout"}

func _drive_layout(planner, snapshot: Dictionary = {}, max_advances := 20000) -> Dictionary:
	var result := {}
	for _index in range(max_advances):
		result = _layout_step(planner, snapshot)
		if result.get("status") == "ready" or result.get("status") == "failed":
			return result
		await process_frame
	return {"status":"timeout", "reason":"mesh_layout_contract_timeout"}

func _required_step(planner, snapshot: Dictionary = {}) -> Dictionary:
	var result: Dictionary = planner.advance_required_collision_mesh_blocks()
	var work_ops := int(result.get("workOps", -1))
	advance_count += 1
	check(work_ops >= 0 and work_ops <= WORK_LIMIT
		and int(result.get("maxWorkOps", -1)) == WORK_LIMIT,
		"required-block advance, including terminal ticks, respects the hard work bound")
	check(_sum_breakdown(result) == work_ops,
		"required-block work breakdown exactly accounts for every operation")
	observed_max_work_ops = maxi(observed_max_work_ops, work_ops)
	total_work_ops += maxi(0, work_ops)
	if not snapshot.is_empty():
		_assert_snapshot(planner, snapshot,
			"required-block copy/sort and cancellation leave accepted demand unchanged")
	return result

func _drive_required(planner, snapshot: Dictionary = {}, max_advances := 20000) -> Dictionary:
	var result := {}
	for _index in range(max_advances):
		result = _required_step(planner, snapshot)
		if result.get("status") == "ready" or result.get("status") == "failed":
			return result
		await process_frame
	return {"status":"timeout", "reason":"required_blocks_contract_timeout"}

func _make_request(primary: Dictionary = {}, viewers: Array[Dictionary] = [],
		retained: Array[Vector2i] = [], foreground: Array[Vector2i] = [],
		bounds := Vector2i.ZERO, revision := 1) -> Dictionary:
	var lease = _new_lease(primary, viewers, retained, foreground, bounds, revision)
	return {"primary":primary, "viewers":viewers, "retained":retained,
		"foreground":foreground, "bounds":bounds, "revision":revision, "lease":lease}

func _begin(planner, request: Dictionary) -> Dictionary:
	return planner.begin_replace_sources(request.primary, request.viewers,
		request.retained, request.foreground, request.bounds,
		request.lease, request.revision)

func _begin_sync(planner, request: Dictionary) -> Dictionary:
	return planner.replace_sources(request.primary, request.viewers,
		request.retained, request.foreground, request.bounds)

func run() -> void:
	var planner = PLANNER.new()
	check(planner.setup(71).get("status") == "ready", "planner initializes incremental replacement authority")
	var empty_snapshot := _accepted_snapshot(planner)
	var initial_request := _make_request(
		{"position":Vector3.ZERO, "distance":80}, [], [], [], Vector2i(-16, 48))
	var initial_begin: Dictionary = _begin(planner, initial_request)
	check(initial_begin.get("status") == "pending"
		and initial_begin.get("reason") == "replacement_started",
		"empty accepted plan starts a leased incremental replacement")
	var initial: Dictionary = await _drive(planner, empty_snapshot)
	check(initial.get("status") == "ready"
		and int(initial.get("desiredDataBlocks", 0)) == 1183
		and int(initial.get("requiredMeshBlocks", 0)) == 605
		and int(initial.get("demandRevision", 0)) == 1,
		"first candidate atomically publishes exact 13x13x7 data and 11x11x5 mesh demand")
	check(advance_count > 2 and observed_max_work_ops == WORK_LIMIT,
		"large initial candidate spans multiple advances and exercises the full work budget")
	var first_accepted := _accepted_snapshot(planner)

	# Exact canonical closure semantics remain the same as the compatibility API.
	var sync_planner = PLANNER.new()
	sync_planner.setup(71)
	var sync_result: Dictionary = sync_planner.replace_sources(
		initial_request.primary, [], [], [], initial_request.bounds)
	check(sync_result.get("status") == "ready"
		and sync_result.get("closureToken") == initial.get("closureToken")
		and sync_result.get("demandRevision") == initial.get("demandRevision"),
		"incremental merge-sort/hash preserves the compatibility closure token exactly")

	# Establish real applied state, then prove accepted facts remain visible while
	# a nonempty replacement is only partially constructed.
	var first_delta: Dictionary = planner.next_delta()
	check(first_delta.get("status") == "ready", "initial plan emits a publisher delta")
	if first_delta.has("ticket"):
		planner.acknowledge_delta(int(first_delta.ticket), true)
	var nonempty_snapshot := _accepted_snapshot(planner)
	var move_request := _make_request(
		{"position":Vector3(400, 0, -200), "distance":32}, [], [], [],
		Vector2i(-64, 128), 2)
	var move_begin: Dictionary = _begin(planner, move_request)
	check(move_begin.get("status") == "pending", "prior nonempty plan begins replacement")
	var moved: Dictionary = await _drive(planner, nonempty_snapshot)
	check(moved.get("status") == "ready"
		and int(moved.get("desiredDataBlocks", 0)) > 0
		and int(moved.get("demandRevision", 0)) == 2
		and planner._applied == nonempty_snapshot.applied,
		"accepted plan swaps atomically while applied physical state is retained")
	var accepted_diagnostics: Dictionary = planner.diagnostics()
	check(accepted_diagnostics.get("demandRevision") == planner._demand_revision
		and accepted_diagnostics.get("closureToken") == planner._closure_token
		and accepted_diagnostics.get("requiredMeshBlocks") == planner._required_mesh_blocks.size(),
		"planner diagnostics retain N3 demand identity fields")

	# A revised request supersedes and boundedly retires an in-progress candidate.
	var before_supersede := _accepted_snapshot(planner)
	var abandoned_request := _make_request(
		{"position":Vector3(-900, 0, 300), "distance":64}, [], [], [],
		Vector2i(-32, 96), 3)
	var abandoned_begin: Dictionary = _begin(planner, abandoned_request)
	for _index in range(3):
		var step: Dictionary = _step(planner, before_supersede)
		check(step.get("status") == "pending", "superseded candidate remains unpublished")
	var replacement_request := _make_request(
		{}, [], [Vector2i(-1, 0)], [], Vector2i(32, 32), 4)
	var replacement_begin: Dictionary = _begin(planner, replacement_request)
	check(replacement_begin.get("reason") == "replacement_supersede_drain_pending"
		and replacement_begin.get("supersededToken") == abandoned_begin.get("token"),
		"new request supersedes the old candidate while retaining it for drain")
	var replacement_snapshot := _accepted_snapshot(planner)
	var replacement: Dictionary = await _drive(planner, replacement_snapshot)
	check(replacement.get("status") == "ready"
		and int(replacement.get("token", 0)) == int(replacement_begin.get("token", -1))
		and planner._sources.has("chunk:retained:-1:0"),
		"superseding request survives old-candidate retirement and becomes accepted")
	var negative_source: Dictionary = planner._sources.get("chunk:retained:-1:0", {})
	var negative_blocks := negative_source.keys()
	var has_negative := false
	var has_lower_input := false
	var has_upper_input := false
	for block: Vector3i in negative_blocks:
		has_negative = has_negative or block.x < 0 or block.z < 0
		has_lower_input = has_lower_input or block.y == 1
		has_upper_input = has_upper_input or block.y == 3
	var negative_mesh: Dictionary = planner._mesh_sources.get("chunk:retained:-1:0", {})
	check(has_negative and has_lower_input and has_upper_input
		and negative_mesh.has(Vector3i(-2, 2, 0)),
		"negative chunk coordinates and lower/upper data-input halos surround the y=2 mesh layer")

	# Explicit cancellation drains candidate-owned data one bounded entry at a
	# time and leaves accepted and applied facts intact.
	var before_cancel := _accepted_snapshot(planner)
	var cancel_request := _make_request(
		{"position":Vector3(1200, 0, 1200), "distance":96}, [], [], [],
		Vector2i(-64, 128), 5)
	var cancel_begin: Dictionary = _begin(planner, cancel_request)
	var partial_cancel: Dictionary = _step(planner, before_cancel)
	var cancel_started: Dictionary = planner.cancel_replace_sources(int(cancel_begin.token))
	check(partial_cancel.get("status") == "pending"
		and cancel_started.get("status") == "pending"
		and cancel_started.get("acceptedPlanRetained") == true,
		"cancellation enters explicit candidate retirement rather than dropping demands")
	var cancelled: Dictionary = await _drive(planner, before_cancel)
	check(cancelled.get("status") == "ready" and cancelled.get("cancelled") == true,
		"cancel returns terminal acknowledgement after bounded drain")

	# Cancellation during merge-sort must explicitly retire both large scratch
	# arrays rather than dropping them with the job dictionary.
	var before_sort_cancel := _accepted_snapshot(planner)
	var sort_cancel_request := _make_request(
		{"position":Vector3(0, 0, 0), "distance":80}, [], [], [],
		Vector2i(-16, 48), 6)
	var sort_cancel_begin: Dictionary = _begin(planner, sort_cancel_request)
	var saw_scratch_work := false
	for _index in range(20000):
		var sort_step: Dictionary = _step(planner, before_sort_cancel)
		var job: Dictionary = planner._replacement._job
		if String(job.get("phase", "")) in ["sort", "sortClear"] \
				and (not job.get("sortSrc", []).is_empty()
					or not job.get("sortDst", []).is_empty()):
			saw_scratch_work = true
			break
		await process_frame
	check(saw_scratch_work, "cancellation fixture reaches live merge-sort scratch arrays")
	var sort_cancel_started: Dictionary = planner.cancel_replace_sources(
		int(sort_cancel_begin.token))
	var sort_cancelled: Dictionary = await _drive(planner, before_sort_cancel)
	check(sort_cancel_started.get("status") == "pending"
		and sort_cancelled.get("status") == "ready"
		and sort_cancelled.get("cancelled") == true
		and planner._replacement._job.get("sortSrc", []).is_empty()
		and planner._replacement._job.get("sortDst", []).is_empty(),
		"sort cancellation drains every scratch entry within the counted per-step budget")
	_assert_snapshot(planner, before_sort_cancel,
		"sort cancellation preserves the previously accepted plan and applied frontier")

	# Capacity is retained/retryable; a smaller request supersedes it without
	# replacing the last accepted plan early.
	var before_capacity := _accepted_snapshot(planner)
	var over: Array[Dictionary] = []
	for index in range(5):
		over.append({"kind":"secondary", "id":"far-%d" % index,
			"position":Vector3(float(index * 2000), 0, 4000), "distance":128})
	var capacity_request := _make_request({}, over, [], [], Vector2i(0, 256), 7)
	var capacity_begin: Dictionary = _begin(planner, capacity_request)
	var capacity: Dictionary = await _drive(planner, before_capacity)
	check(capacity.get("status") == "pending"
		and capacity.get("reason") == "desired_union_capacity"
		and capacity.get("retryable") == true,
		"union capacity is explicit and retryable without mutating the accepted plan")
	_assert_snapshot(planner, before_capacity, "capacity exhaustion preserves last accepted plan")
	var retry_request := _make_request(
		{"position":Vector3.ZERO, "distance":8}, [], [], [], Vector2i(0, 32), 8)
	var retry_begin: Dictionary = _begin(planner, retry_request)
	check(retry_begin.get("reason") == "replacement_supersede_drain_pending"
		and retry_begin.get("supersededToken") == capacity_begin.get("token"),
		"capacity retry supersedes the retained oversized candidate without dropping demand")
	var retry: Dictionary = await _drive(planner, before_capacity)
	check(retry.get("status") == "ready"
		and int(retry.get("token", 0)) == int(retry_begin.get("token", -1)),
		"smaller capacity retry publishes after bounded oversized-candidate retirement")

	# Revoke the source revision mid-build; the mixed candidate must never publish.
	var before_revoke := _accepted_snapshot(planner)
	var revoked_request := _make_request(
		{"position":Vector3.ZERO, "distance":64}, [], [], [], Vector2i(-32, 96), 9)
	var revoked_begin: Dictionary = _begin(planner, revoked_request)
	_step(planner, before_revoke)
	revoked_request.lease.invalidate()
	var revoked: Dictionary = await _drive(planner, before_revoke)
	check(revoked.get("status") == "failed"
		and revoked.get("reason") == "demand_request_lease_revoked",
		"same-revision payload lease revocation prevents mixed-source publication")
	_assert_snapshot(planner, before_revoke,
		"revoked request drain preserves accepted and applied state")

	# The staged window-layout builder reproduces the compatibility layout
	# exactly, and cancellation/retry leaves the accepted demand snapshot alone.
	var layout_request := _make_request(
		{"position":Vector3.ZERO, "distance":80}, [], [], [], Vector2i(-16, 48), 1)
	var sync_layout_planner = PLANNER.new()
	sync_layout_planner.setup(91)
	_begin_sync(sync_layout_planner, layout_request)
	var expected_layout: Dictionary = sync_layout_planner.collision_mesh_window_layout()
	var layout_planner = PLANNER.new()
	layout_planner.setup(91)
	_begin_sync(layout_planner, layout_request)
	var before_layout := _accepted_snapshot(layout_planner)
	var layout_begin: Dictionary = layout_planner.begin_collision_mesh_window_layout()
	check(layout_begin.get("status") == "pending"
		and layout_begin.get("reason") == "mesh_layout_started",
		"logical mesh layout starts under a revision/token-bound planner lease")
	for _index in range(2):
		var partial_layout: Dictionary = _layout_step(layout_planner, before_layout)
		check(partial_layout.get("status") == "pending",
			"large mesh layout remains pending across bounded construction steps")
		await process_frame
	var cancelled_layout_begin: Dictionary = layout_planner.cancel_collision_mesh_window_layout(
		int(layout_begin.token))
	var cancelled_layout: Dictionary = await _drive_layout(layout_planner, before_layout)
	check(cancelled_layout_begin.get("status") == "pending"
		and cancelled_layout.get("status") == "ready"
		and cancelled_layout.get("cancelled") == true,
		"layout cancellation incrementally retires partial buckets and sort scratch")
	var retry_layout_begin: Dictionary = layout_planner.begin_collision_mesh_window_layout()
	var retry_layout: Dictionary = await _drive_layout(layout_planner, before_layout)
	check(retry_layout_begin.get("status") == "pending"
		and retry_layout.get("status") == "ready"
		and retry_layout.get("layout") == expected_layout,
		"layout retry matches every legacy schema, sorted block, window, and closure token")
	var layout_retire_steps := 0
	while layout_planner._mesh_layout_builder.has_pending_retirement() \
			and layout_retire_steps < 20000:
		_layout_step(layout_planner, before_layout)
		layout_retire_steps += 1
		await process_frame
	check(not layout_planner._mesh_layout_builder.has_pending_retirement(),
		"transferred layout scratch is released incrementally after atomic publication")

	# Full demanded-mesh enumeration now uses the same bounded incremental
	# snapshot machinery while preserving the compatibility method's exact list.
	var required_snapshot := _accepted_snapshot(layout_planner)
	var expected_required: Dictionary = layout_planner.required_collision_mesh_blocks()
	var required_begin: Dictionary = layout_planner.begin_required_collision_mesh_blocks()
	check(required_begin.get("status") == "pending",
		"required-block enumeration begins under a revision/token-bound lease")
	for _index in range(2):
		var partial_required: Dictionary = _required_step(layout_planner, required_snapshot)
		check(partial_required.get("status") == "pending",
			"required-block snapshot remains pending across bounded construction steps")
		await process_frame
	var cancelled_required_begin: Dictionary = layout_planner.cancel_required_collision_mesh_blocks(
		int(required_begin.token))
	var cancelled_required: Dictionary = await _drive_required(layout_planner, required_snapshot)
	check(cancelled_required_begin.get("status") == "pending"
		and cancelled_required.get("status") == "ready"
		and cancelled_required.get("cancelled") == true,
		"required-block cancellation incrementally drains copied and bucket entries")
	var required_retire_steps := 0
	while layout_planner._mesh_layout_builder.has_pending_retirement() \
			and required_retire_steps < 20000:
		_required_step(layout_planner, required_snapshot)
		required_retire_steps += 1
		await process_frame
	check(not layout_planner._mesh_layout_builder.has_pending_retirement(),
		"cancelled required-block scratch fully retires before another snapshot begins")
	var retry_required_begin: Dictionary = layout_planner.begin_required_collision_mesh_blocks()
	var retry_required: Dictionary = await _drive_required(layout_planner, required_snapshot)
	check(retry_required_begin.get("status") == "pending"
		and retry_required.get("status") == "ready"
		and retry_required.get("blocks") == expected_required.get("blocks")
		and retry_required.get("revision") == expected_required.get("revision")
		and retry_required.get("closureToken") == expected_required.get("closureToken"),
		"required-block retry exactly matches synchronous sorted blocks and revision identity")
	while layout_planner._mesh_layout_builder.has_pending_retirement() \
			and required_retire_steps < 40000:
		_required_step(layout_planner, required_snapshot)
		required_retire_steps += 1
		await process_frame
	check(not layout_planner._mesh_layout_builder.has_pending_retirement(),
		"published required-block builder scratch retires incrementally")

	# Revoking the accepted request lease during a snapshot must fail that
	# candidate without changing the last accepted demand identity.
	var before_required_revoke := _accepted_snapshot(layout_planner)
	var revoked_required_begin: Dictionary = layout_planner.begin_required_collision_mesh_blocks()
	_required_step(layout_planner, before_required_revoke)
	layout_planner._mesh_layout_lease.invalidate()
	var revoked_required: Dictionary = await _drive_required(layout_planner,
		before_required_revoke)
	check(revoked_required_begin.get("status") == "pending"
		and revoked_required.get("status") == "failed"
		and revoked_required.get("reason") == "mesh_layout_snapshot_revoked",
		"required-block builder rejects revoked demand revision/token leases")
	check(not layout_planner._mesh_layout_builder.has_pending_retirement(),
		"revoked required-block candidate is fully drained before returning terminal failure")

	# Exercise the required-set hard capacity separately with a bounded builder
	# fixture; no planner accepted state is altered by this synthetic input.
	var oversized_order: Array[Vector3i] = []
	for block_index in range(32769):
		oversized_order.append(Vector3i(block_index, 0, 0))
	var capacity_lease = MESH_LEASE.new()
	capacity_lease.acquire(oversized_order, 1, "capacity-fixture")
	var capacity_builder = MESH_BUILDER.new()
	var mesh_capacity_begin: Dictionary = capacity_builder.begin_required_blocks(
		oversized_order, 1, "capacity-fixture", capacity_lease)
	var mesh_capacity_result := {}
	var capacity_advances := 0
	while capacity_advances < 1000:
		mesh_capacity_result = capacity_builder.advance()
		capacity_advances += 1
		var capacity_work := int(mesh_capacity_result.get("workOps", -1))
		check(capacity_work >= 0 and capacity_work <= WORK_LIMIT
			and int(mesh_capacity_result.get("maxWorkOps", -1)) == WORK_LIMIT,
			"capacity and retirement advances respect the hard work bound")
		check(_sum_breakdown(mesh_capacity_result) == capacity_work,
			"capacity work breakdown exactly accounts for every operation")
		observed_max_work_ops = maxi(observed_max_work_ops, capacity_work)
		total_work_ops += maxi(0, capacity_work)
		if mesh_capacity_result.get("status") == "failed": break
		await process_frame
	check(mesh_capacity_begin.get("status") == "pending"
		and mesh_capacity_result.get("status") == "failed"
		and mesh_capacity_result.get("reason") == "mesh_window_capacity_invalid"
		and not capacity_builder.has_pending_retirement(),
		"required-block total capacity rejects oversized input after fully bounded drain")

	var report := {"schema":"n3-terrain-demand-replacement-contract/v1",
		"passed":failures.is_empty(), "productionCutover":false,
		"evidenceLevel":"focused incremental pure planner contract",
		"failures":failures, "metrics":{"workLimit":WORK_LIMIT,
			"observedMaxWorkOps":observed_max_work_ops,
			"totalWorkOps":total_work_ops, "advanceCount":advance_count},
		"checks":{"initialPlanAtomic":initial.get("status") == "ready",
			"closureTokenMatchesSynchronous":sync_result.get("closureToken") == initial.get("closureToken"),
			"capacityRetained":capacity.get("reason") == "desired_union_capacity",
			"cancelDrained":cancelled.get("cancelled", false),
			"sortScratchCancelDrained":sort_cancelled.get("cancelled", false)
				and planner._replacement._job.get("sortSrc", []).is_empty()
				and planner._replacement._job.get("sortDst", []).is_empty(),
			"negativeCoordinatesAndVerticalHalo":has_negative and has_lower_input and has_upper_input,
			"revocationRejected":revoked.get("reason") == "demand_request_lease_revoked",
			"layoutCancelAndRetry":cancelled_layout.get("cancelled", false)
				and retry_layout.get("layout") == expected_layout,
			"layoutRetirementDrained":not layout_planner._mesh_layout_builder.has_pending_retirement(),
			"requiredBlocksCancelAndRetry":cancelled_required.get("cancelled", false)
				and retry_required.get("blocks") == expected_required.get("blocks"),
			"requiredBlocksRevisionLeaseRejected":revoked_required.get("reason") == "mesh_layout_snapshot_revoked",
			"requiredBlocksCapacityDrained":mesh_capacity_result.get("reason") == "mesh_window_capacity_invalid"
				and not capacity_builder.has_pending_retirement()},
		"boundedWorkFollowUps":[
			"Production consumers still call the synchronous required_collision_mesh_blocks() compatibility method; migrate NativeTerrainTriangleArtifactProducer and NativeTerrainArtifactRequests to the staged API before VTR wiring.",
			"The legacy collision_mesh_window_layout() compatibility method remains synchronous. Migrate callers to begin/advance_collision_mesh_window_layout() before VTR wiring."],
		"doesNotProve":"No VoxelTerrain/runtime integration, page/queue admission, publication/collision, or headed gameplay/performance acceptance."}
	var report_path := OS.get_environment("VWB_TERRAIN_DEMAND_REPLACEMENT_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
