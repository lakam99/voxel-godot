extends SceneTree

const COORDINATOR = preload("res://scripts/terrain/NativeWindowedCollisionCoordinator.gd")

class PendingOwner:
	extends Node3D
	var attempts := 0
	func physical_receipt(_identity: Dictionary) -> Dictionary:
		return {"ready":false}
	func stop_and_drain() -> Dictionary:
		attempts += 1
		if attempts == 1:
			return {"status":"pending", "reason":"physics_sync_pending"}
		return {"status":"ready", "drained":true,
			"remainingBodies":0, "windowToken":"fake-window"}

class FakeBroker:
	extends RefCounted
	var layout := {}
	func collision_window_layout() -> Dictionary:
		return layout.duplicate(true)
	func acknowledge_collision_window_retired(_token: String,
			_receipt: Dictionary) -> Dictionary:
		return {"status":"ready"}
	func claim_collision_window_retirement(_token: String,
			layout_token: String) -> Dictionary:
		return {"status":"ready", "leaseId":"stop-contract:%s" % layout_token}
	func validate_collision_window_retirement(_token: String,
			lease_id: String) -> Dictionary:
		return {"status":"ready", "leaseId":lease_id}
	func abort_collision_window_retirement(_token: String,
			_lease_id: String, owner_unchanged: bool) -> Dictionary:
		return {"status":"ready" if owner_unchanged else "failed"}

class FakeRetirementBroker:
	extends RefCounted
	var layout := {}
	var initial_layout := {}
	var lease_id := "retirement-lease"
	func collision_window_layout() -> Dictionary:
		return layout.duplicate(true)
	func acknowledge_collision_window_retired(token: String,
			receipt: Dictionary) -> Dictionary:
		if token != "leased-window" or receipt.get("retirementLeaseId") != lease_id:
			return {"status":"failed", "reason":"lease_receipt_mismatch"}
		layout = initial_layout.duplicate(true)
		return {"status":"ready", "retiredWindowToken":token}
	func claim_collision_window_retirement(token: String,
			layout_token: String) -> Dictionary:
		if token != "leased-window" or layout_token != "shifted-layout":
			return {"status":"failed", "reason":"unexpected_lease_claim"}
		return {"status":"ready", "leaseId":lease_id}
	func validate_collision_window_retirement(token: String,
			candidate_lease: String) -> Dictionary:
		return {"status":"ready" if token == "leased-window" \
			and candidate_lease == lease_id else "failed"}
	func abort_collision_window_retirement(_token: String,
			_lease: String, owner_unchanged: bool) -> Dictionary:
		return {"status":"ready" if owner_unchanged else "failed"}
	func reactivate_demand_while_leased() -> void:
		layout = {"status":"pending",
			"reason":"collision_window_retirement_leased",
			"layoutToken":"shifted-layout",
			"retiredWindowTokens":["leased-window"]}

class FakeRetirementOwner:
	extends Node3D
	var broker: FakeRetirementBroker
	var window: Dictionary
	var identity := {}
	var attempts := 0
	var installed := true
	func physical_receipt(request_identity: Dictionary) -> Dictionary:
		if not installed or request_identity != identity:
			return {"ready":false, "reason":"fake_collision_absent"}
		return _receipt(identity, window)
	func stop_and_drain() -> Dictionary:
		attempts += 1
		if attempts == 1:
			broker.reactivate_demand_while_leased()
			await get_tree().process_frame
			return {"status":"pending", "reason":"fake_physics_sync_pending"}
		installed = false
		return {"status":"ready", "drained":true,
			"remainingBodies":0, "windowToken":window.windowToken}
	func publish_again() -> Dictionary:
		installed = true
		return {"status":"ready"}
	static func _receipt(request_identity: Dictionary,
			member: Dictionary) -> Dictionary:
		return {"ready":true, "physicsFrame":10,
			"residentBlockCount":member.blocks.size(),
			"residentBlocks":member.blocks.duplicate(),
			"provenance":{"requestIdentity":request_identity.duplicate(true),
				"sourceIdentity":request_identity.sourceIdentity.duplicate(true),
				"membershipProvenance":{"authority":"pinned_demand",
					"demandRevision":1, "closureToken":member.closureToken,
					"windowToken":member.windowToken}}}

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var root_3d := Node3D.new()
	root.add_child(root_3d)
	var coordinator = COORDINATOR.new()
	root_3d.add_child(coordinator)
	var broker := FakeBroker.new()
	var window := {"id":Vector3i.ZERO, "windowToken":"fake-window",
		"blocks":[Vector3i.ZERO]}
	var identity := {"sourceRevision":1}
	broker.layout = {"status":"ready", "windows":[window],
		"identity":identity}
	var setup: Dictionary = coordinator.setup(broker, root_3d)
	var owner := PendingOwner.new()
	coordinator.add_child(owner)
	var registered: Dictionary = coordinator.register_window(window, owner)
	var bounds := AABB(Vector3.ZERO, Vector3.ONE)
	var first_hold: Dictionary = coordinator.begin_window_barrier(window,
		bounds, identity)
	var held: Dictionary = first_hold
	for index in range(64):
		held = coordinator.begin_window_barrier(window, bounds, identity)
	var cap: Dictionary = coordinator.begin_window_barrier(window, bounds,
		identity)
	var first_stop: Dictionary = await coordinator.stop_and_drain()
	var retained_child: bool = is_instance_valid(owner) and owner.get_parent() == coordinator
	var actor := CharacterBody3D.new()
	root_3d.add_child(actor)
	var motion_denied: bool = not coordinator.admit_motion(actor, Vector3.ONE)
	var placement_denied: bool = not coordinator.admit_placement(actor,
		Transform3D(Basis.IDENTITY, Vector3.ONE))
	var terminal_release: bool = held.barrier.release(identity)
	var second_stop: Dictionary = await coordinator.stop_and_drain()
	actor.queue_free()
	await process_frame
	var distinct_coordinator = COORDINATOR.new()
	root_3d.add_child(distinct_coordinator)
	var distinct_setup: Dictionary = distinct_coordinator.setup(broker, root_3d)
	var distinct_last: Dictionary = {}
	for index in range(distinct_coordinator.MAX_ACTIVE_BARRIERS):
		distinct_last = distinct_coordinator.begin_window_barrier(
			{"id":Vector3i(index, 0, 0), "windowToken":"distinct-%d" % index},
			bounds, identity)
	var distinct_cap: Dictionary = distinct_coordinator.begin_window_barrier(
		{"id":Vector3i(999, 0, 0), "windowToken":"distinct-overflow"},
		bounds, identity)
	var distinct_stop: Dictionary = await distinct_coordinator.stop_and_drain()
	var retirement_coordinator = COORDINATOR.new()
	root_3d.add_child(retirement_coordinator)
	var retirement_broker := FakeRetirementBroker.new()
	var source_identity := {"hex":"retirement-source"}
	var retirement_identity := {"ownerGeneration":8, "sourceRevision":0,
		"cancellationEpoch":1, "sourceEpoch":"8:retirement-source",
		"sourceIdentity":source_identity}
	var original_window := {"id":Vector3i.ZERO, "blocks":[Vector3i.ZERO],
		"windowToken":"leased-window", "closureToken":"leased-closure",
		"windowIndex":0, "identity":retirement_identity,
		"localCurrentProof":{"kind":"native_current_revision",
			"throughGlobalRevision":0, "digest":"leased-current"}}
	var shifted_window := {"id":Vector3i.ZERO, "blocks":[Vector3i.ZERO],
		"windowToken":"shifted-window", "closureToken":"shifted-closure",
		"windowIndex":0, "identity":retirement_identity,
		"localCurrentProof":{"kind":"native_current_revision",
			"throughGlobalRevision":0, "digest":"shifted-current"}}
	retirement_broker.initial_layout = _layout(original_window, retirement_identity,
		source_identity, "restored-layout")
	retirement_broker.layout = retirement_broker.initial_layout.duplicate(true)
	var retirement_setup: Dictionary = retirement_coordinator.setup(
		retirement_broker, root_3d)
	var retiring_owner := FakeRetirementOwner.new()
	retiring_owner.broker = retirement_broker
	retiring_owner.window = original_window
	retiring_owner.identity = retirement_identity
	retirement_coordinator.add_child(retiring_owner)
	var retiring_registered: Dictionary = retirement_coordinator.register_window(
		original_window, retiring_owner)
	retirement_broker.layout = _layout(shifted_window, retirement_identity,
		source_identity, "shifted-layout")
	retirement_broker.layout.retirementTelemetry = {
		"retiredWindowTokens":["leased-window"]}
	var retirement_actor := CharacterBody3D.new()
	retirement_actor.position = Vector3(4, 0.5, 0.5)
	var actor_shape := CollisionShape3D.new()
	var actor_sphere := SphereShape3D.new()
	actor_sphere.radius = 0.2
	actor_shape.shape = actor_sphere
	retirement_actor.add_child(actor_shape)
	var retirement_bounds := AABB(Vector3.ZERO, Vector3.ONE)
	var original_hold: Dictionary = retirement_coordinator.begin_window_barrier(
		original_window, retirement_bounds, retirement_identity)
	var original_barrier: RefCounted = original_hold.get("barrier")
	var original_census: Dictionary = original_hold.get("census", {})
	while original_census.get("status") == "pending":
		await process_frame
		original_census = original_barrier.census_progress(retirement_identity)
	var first_retire: Dictionary = await retirement_coordinator.retire_window(
		Vector3i.ZERO)
	var owner_preserved_after_pending: bool = retiring_owner.installed \
		and bool(retiring_owner.physical_receipt(retirement_identity).get("ready", false))
	var reactivated_pending: Dictionary = retirement_broker.collision_window_layout()
	var denied_while_leased: bool = not retirement_coordinator.admit_motion(
		retirement_actor, Vector3.ZERO)
	var second_retire: Dictionary = await retirement_coordinator.retire_window(
		Vector3i.ZERO)
	var no_owner_aggregate: Dictionary = retirement_coordinator.aggregate_readiness(
		retirement_identity)
	var denied_without_replacement: bool = not retirement_coordinator.admit_motion(
		retirement_actor, Vector3.ZERO)
	var reactivated_window: Dictionary = retirement_broker.layout.windows[0]
	var replacement_owner := FakeRetirementOwner.new()
	replacement_owner.broker = retirement_broker
	replacement_owner.window = reactivated_window
	replacement_owner.identity = retirement_identity
	replacement_owner.attempts = 1
	retirement_coordinator.add_child(replacement_owner)
	var replacement_registration: Dictionary = retirement_coordinator.register_window(
		reactivated_window, replacement_owner)
	var replacement_hold: Dictionary = retirement_coordinator.begin_window_barrier(
		reactivated_window, retirement_bounds, retirement_identity)
	var replacement_barrier: RefCounted = replacement_hold.get("barrier")
	var replacement_census: Dictionary = replacement_hold.get("census", {})
	while replacement_census.get("status") == "pending":
		await process_frame
		replacement_census = replacement_barrier.census_progress(retirement_identity)
	var replacement_install: Dictionary = replacement_owner.publish_again()
	var replacement_ready: Dictionary = retirement_coordinator.aggregate_readiness(
		retirement_identity)
	var replacement_release: Dictionary = retirement_coordinator.release_barriers(
		retirement_identity)
	root_3d.add_child(retirement_actor)
	var admitted_after_replacement: bool = retirement_coordinator.admit_motion(
		retirement_actor, Vector3.ZERO)
	var retirement_stop: Dictionary = await retirement_coordinator.stop_and_drain()
	retirement_actor.queue_free()
	root_3d.queue_free()
	var passed: bool = setup.get("status") == "ready" \
		and registered.get("status") == "ready" \
		and first_hold.get("status") == "ready" \
		and held.get("status") == "ready" \
		and cap.get("status") == "pending" \
		and cap.get("reason") == "window_barrier_retention_backpressure" \
		and first_stop.get("status") == "pending" \
		and first_stop.get("reason") == "physical_window_drain_pending" \
		and retained_child and motion_denied and placement_denied \
		and not terminal_release \
		and second_stop.get("status") == "ready" \
		and int(second_stop.get("remainingChildren", -1)) == 0 \
		and int(second_stop.get("activeBarriers", -1)) == 0 \
		and distinct_setup.get("status") == "ready" \
		and distinct_last.get("status") == "ready" \
		and distinct_cap.get("status") == "pending" \
		and distinct_cap.get("reason") == "window_barrier_retention_backpressure" \
		and distinct_stop.get("status") == "ready" \
		and retirement_setup.get("status") == "ready" \
		and retiring_registered.get("status") == "ready" \
		and original_hold.get("status") == "ready" \
		and first_retire.get("status") == "pending" \
		and first_retire.get("reason") == "physical_window_drain_pending" \
		and owner_preserved_after_pending \
		and reactivated_pending.get("status") == "pending" \
		and reactivated_pending.get("reason") == "collision_window_retirement_leased" \
		and denied_while_leased \
		and second_retire.get("status") == "ready" \
		and no_owner_aggregate.get("status") == "pending" \
		and denied_without_replacement \
		and replacement_registration.get("status") == "ready" \
		and replacement_install.get("status") == "ready" \
		and replacement_ready.get("status") == "ready" \
		and replacement_release.get("status") == "ready" \
		and admitted_after_replacement \
		and retirement_stop.get("status") == "ready"
	var report := {"schema":"n5-coordinator-stop-contract/v1",
		"passed":passed, "evidenceLevel":"synthetic coordinator lifecycle contract",
		"productionCutover":false, "firstHold":first_hold.get("status"),
		"retainedBarrierCount":coordinator.MAX_RETIRED_BARRIERS,
		"cap":cap, "firstStop":first_stop,
		"retainedChild":retained_child, "motionDenied":motion_denied,
		"placementDenied":placement_denied,
		"terminalRelease":terminal_release, "secondStop":second_stop,
		"distinctBarrierCap":distinct_cap, "distinctStop":distinct_stop}
	report["retirementLease"] = {"firstDrain":first_retire,
		"reactivatedLayout":reactivated_pending,
		"ownerPreservedAfterPending":owner_preserved_after_pending,
		"deniedWhileLeased":denied_while_leased,
		"secondDrain":second_retire,
		"noOwnerAggregate":no_owner_aggregate,
		"deniedWithoutReplacement":denied_without_replacement,
		"replacementAggregate":replacement_ready,
		"replacementRelease":replacement_release,
		"admittedAfterReplacement":admitted_after_replacement}
	var path := OS.get_environment("N5_COORDINATOR_STOP_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	quit(0 if passed else 1)

func _layout(window: Dictionary, identity: Dictionary,
		source_identity: Dictionary, layout_token: String) -> Dictionary:
	return {"status":"ready", "schema":"n3-mesh-window-layout/v1",
		"logicalDemandRevision":1, "logicalClosureToken":window.closureToken,
		"layoutToken":layout_token, "requiredBlockCount":window.blocks.size(),
		"requiredBlocks":window.blocks.duplicate(), "windowEdgeBlocks":16,
		"maxWindowBlocks":4096, "windowCount":1,
		"sourceIdentity":source_identity, "identity":identity,
		"windows":[window.duplicate(true)]}
