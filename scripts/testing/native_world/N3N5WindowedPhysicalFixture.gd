extends SceneTree

const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const BROKER = preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")
const OWNER = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const BARRIER = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")
const AGGREGATE = preload("res://scripts/terrain/NativeWindowedCollisionReadiness.gd")
const COORDINATOR = preload("res://scripts/terrain/NativeWindowedCollisionCoordinator.gd")
const MEMORY_POLICY = preload("res://scripts/terrain/NativeCollisionMemoryPolicy.gd")
const MEMORY_ADMISSION = preload("res://scripts/terrain/NativeCollisionMemoryAdmission.gd")
const EDIT_PLAN = preload("res://scripts/terrain/NativeTerrainEditRepublicationPlan.gd")
const ADMISSION_ROUTER = preload("res://scripts/terrain/NativeCollisionAdmissionRouter.gd")

class ArtifactKeyFaultSource extends RefCounted:
	var source
	var fault_block: Variant = null

	func _init(value) -> void:
		source = value

	func collision_source_snapshot() -> Dictionary:
		return source.collision_source_snapshot()

	func collision_source_ticket() -> Dictionary:
		return source.collision_source_ticket()

	func collision_source_ticket_current(ticket: String) -> bool:
		return source.collision_source_ticket_current(ticket)

	func collision_source_artifact_key(block: Vector3i, ticket: String) -> Dictionary:
		var result: Dictionary = source.collision_source_artifact_key(block, ticket)
		if block == fault_block and result.get("status") == "ready":
			result = result.duplicate(true)
			result.artifactKey = "fault:" + String(result.get("artifactKey", ""))
		return result

	func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
		return source.collision_artifact_row(block, identity)

	func collision_artifact_row_snapshot(block: Vector3i,
			identity: Dictionary) -> Dictionary:
		return source.collision_artifact_row_snapshot(block, identity)

class CancellationDriftBroker extends RefCounted:
	var window_token := ""

	func collision_window_layout() -> Dictionary:
		return {"status":"ready", "layoutToken":"synthetic-layout-drift",
			"windows":[], "retiredWindowTokens":[window_token],
			"retirementTelemetry":{"retiredWindowTokens":[window_token]}}

	func claim_collision_window_retirement(_token: String,
			_expected_layout_token: String, _physical_owner_epoch: String) -> Dictionary:
		return {"status":"pending", "reason":"synthetic_stale_retirement_lease"}

class AckPendingBroker extends RefCounted:
	var delegate: Object
	var pending_ack := true
	var first_ack := {}

	func _init(value: Object) -> void:
		delegate = value

	func collision_window_layout() -> Dictionary:
		return delegate.collision_window_layout()

	func claim_collision_window_retirement(token: String, layout_token: String,
			owner_epoch: String) -> Dictionary:
		return delegate.claim_collision_window_retirement(token, layout_token, owner_epoch)

	func validate_collision_window_retirement(token: String, lease_id: String,
			owner_epoch: String) -> Dictionary:
		return delegate.validate_collision_window_retirement(token, lease_id, owner_epoch)

	func acknowledge_collision_window_retired(token: String,
			receipt: Dictionary) -> Dictionary:
		if pending_ack:
			pending_ack = false
			first_ack = {"status":"pending", "reason":"fixture_ack_deferred_once"}
			return first_ack
		return delegate.acknowledge_collision_window_retired(token, receipt)

func _await_window_layout(broker, initial: Dictionary, label: String) -> Dictionary:
	var result := initial
	var steps := 0
	while result.get("status") != "ready" and steps < 30000:
		assert(result.get("status") != "failed",
			"%s staged layout failed: %s" % [label, str(result)])
		if result.has("workOps"):
			var work_ops := int(result.get("workOps", -1))
			var max_work_ops := int(result.get("maxWorkOps", -1))
			assert(work_ops >= 0 and max_work_ops == 256 and work_ops <= max_work_ops,
				"%s staged layout exceeds 256 operations (%d/%d)" % [label,
					work_ops, max_work_ops])
		result = broker.collision_window_layout()
		steps += 1
		await process_frame
	assert(result.get("status") == "ready",
		"%s staged layout did not become ready in bounded wait" % label)
	return result

func _new_fixture_memory_admission(epoch: String):
	var policy = MEMORY_POLICY.new()
	var configured: Dictionary = policy.configure({
		"maxVerticesPerRow":65536, "verticesPerShape":768,
		"rowEntryBytes":1, "bodyEntryBytes":1, "shapeEntryBytes":1,
		"physicsPayloadMultiplier":1, "maxRowsPerWindow":4096,
		"maxWindowChargedBytes":400000000,
		"maxAggregateChargedBytes":800000000,
		"maxReservations":8192})
	if configured.get("status") != "ready": return null
	var admission = MEMORY_ADMISSION.new()
	var setup: Dictionary = admission.setup(policy, epoch,
		"n3n5-fixture:%d" % Time.get_ticks_usec())
	return admission if setup.get("status") == "ready" else null

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var main = MAIN.new()
	main.seed_text = "n3-n5-windowed-physical"
	main.seed_hash = main.hash_string(main.seed_text)
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {},
		{"regionCells":main.STRUCTURE_REGION_CELLS,
			"spawnChance":main.STRUCTURE_SPAWN_CHANCE})
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var source_request: Dictionary = REQUEST.from_main_with_save_volume(main,
		{"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]})
	var backend = ClassDB.instantiate("NativeWorldBackend")
	if backend == null or source_request.get("status") != "ready":
		_finish(false, {"reason":"native_source_unavailable"})
		return
	var initialized: Dictionary = backend.initialize_from_save_v2(source_request.request)
	var pages = PAGES.new()
	var page_setup: Dictionary = pages.setup(backend,
		main.structure_system.citadel_terrain_admission)
	var planner = PLANNER.new()
	var planner_setup: Dictionary = planner.setup(91)
	var surface: float = main.world_generation_system.surface_y_for_cell(Vector3i.ZERO)
	var base_y := floori(float(floori(surface / main.CELL)) / 16.0)
	var planned: Dictionary = planner.replace_sources(
		{"position":Vector3.ZERO, "distance":0}, [], [], [],
		Vector2i(base_y * 16, (base_y + 1) * 16))
	var required: Dictionary = planner.required_collision_mesh_blocks()
	var broker = BROKER.new()
	var broker_setup: Dictionary = broker.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL, 91,
		OWNER.MAX_RESIDENT)
	var initial_layout: Dictionary = broker.collision_window_layout()
	var initial_aggregate: Dictionary = AGGREGATE.evaluate(initial_layout, {})
	var requested := []
	for block: Vector3i in required.get("blocks", []):
		requested.append(broker.request_block(block))
	var max_advance_usec := 0
	var last_advance: Dictionary = {}
	var layout: Dictionary = {}
	for frame in range(500):
		var started := Time.get_ticks_usec()
		last_advance = broker.advance()
		max_advance_usec = maxi(max_advance_usec, Time.get_ticks_usec() - started)
		layout = broker.collision_window_layout()
		if layout.get("status") == "ready" and layout.get("windows", []).size() == 1:
			var window: Dictionary = layout.windows[0]
			var facade_status: Dictionary = broker.collision_window_source(window.id,
				layout.layoutToken)
			if facade_status.get("status") == "ready" \
					and facade_status.source.collision_source_snapshot().get("status") == "ready":
				break
		if last_advance.get("status") == "failed": break
		await process_frame
	var window: Dictionary = layout.get("windows", [{}])[0]
	var facade_status: Dictionary = broker.collision_window_source(
		window.get("id", Vector3i.ZERO), String(layout.get("layoutToken", "")))
	var facade = facade_status.get("source")
	var snapshot: Dictionary = facade.collision_source_snapshot() \
		if facade != null else {}
	var rows: Array[Dictionary] = []
	if snapshot.get("status") == "ready":
		for block: Vector3i in window.blocks:
			var canonical: Dictionary = facade.collision_artifact_row_snapshot(block,
				layout.identity)
			if canonical.get("status") == "ready": rows.append(canonical.row)
	var root_3d := Node3D.new()
	root.add_child(root_3d)
	var coordinator = COORDINATOR.new()
	root_3d.add_child(coordinator)
	var memory_admission = _new_fixture_memory_admission("n3n5-windowed-fixture")
	var memory_configured := memory_admission != null
	var coordinator_setup: Dictionary = coordinator.setup(broker, root_3d,
		memory_admission)
	var owner = OWNER.new()
	coordinator.add_child(owner)
	var owner_source := ArtifactKeyFaultSource.new(facade)
	var bound: bool = owner.bind_source(owner_source)
	var registered: Dictionary = coordinator.register_window(window, owner)
	var bounds: AABB = rows[0].bounds if not rows.is_empty() \
		else AABB(Vector3.ZERO, Vector3.ONE)
	for row in rows: bounds = bounds.merge(row.bounds)
	var held: Dictionary = coordinator.begin_window_barrier(window, bounds,
		layout.get("identity", {}))
	var barrier: RefCounted = held.get("barrier")
	var census: Dictionary = held.get("census", {})
	while census.get("status") == "pending":
		await process_frame
		census = barrier.census_progress(layout.identity)
	var missing_aggregate: Dictionary = coordinator.aggregate_readiness(layout.identity)
	var unready_router = ADMISSION_ROUTER.new()
	var unready_router_setup: Dictionary = unready_router.setup(coordinator, layout.identity)
	var unready_main_bind := main.bind_native_collision_admission(root_3d,
		unready_router) if unready_router_setup.get("status") == "ready" else false
	var raw_barrier_rejected := not main.bind_native_collision_admission(root_3d,
		barrier)
	var published: Dictionary = {}
	if bound and rows.size() == window.get("blocks", []).size():
		published = await owner.publish({
			"schema":"n5-resident-collision-publication/v1",
			"identity":layout.identity, "residentBlocks":window.blocks,
			"affectedBlocks":window.blocks, "rows":rows}, barrier)
	var initial_memory: Dictionary = memory_admission.snapshot() \
		if memory_configured else {}
	var same_window_replacement: Dictionary = {}
	if published.get("status") == "ready":
		same_window_replacement = await owner.publish({
			"schema":"n5-resident-collision-publication/v1",
			"identity":layout.identity, "residentBlocks":window.blocks,
			"affectedBlocks":window.blocks, "rows":rows}, barrier)
	var same_window_memory: Dictionary = owner.memory_admission_receipt()
	var physical: Dictionary = owner.physical_receipt(layout.identity)
	var aggregate: Dictionary = coordinator.aggregate_readiness(layout.identity)
	var admission_router = ADMISSION_ROUTER.new()
	var router_setup: Dictionary = admission_router.setup(coordinator, layout.identity)
	var aggregate_main_bound := main.bind_native_collision_admission(root_3d,
		admission_router) if router_setup.get("status") == "ready" else false
	var facade_actor := CharacterBody3D.new()
	facade_actor.position = bounds.position - Vector3(5, 0, 0)
	var facade_actor_shape := CollisionShape3D.new()
	var facade_capsule := CapsuleShape3D.new()
	facade_capsule.radius = 0.35
	facade_capsule.height = 1.8
	facade_actor_shape.shape = facade_capsule
	facade_actor.add_child(facade_actor_shape)
	root_3d.add_child(facade_actor)
	await physics_frame
	var aggregate_motion_held := not main.native_collision_admit_motion(facade_actor,
		bounds.get_center() - facade_actor.position)
	var aggregate_early_unbind := main.unbind_native_collision_admission(root_3d)
	facade_actor.queue_free()
	var release_before_actor_deletion: Dictionary = coordinator.release_barriers(
		layout.identity)
	await process_frame
	var released: Dictionary = coordinator.release_barriers(layout.identity)
	var active_retirement: Dictionary = await coordinator.retire_window(window.id)
	var physical_after_active_rejection: Dictionary = owner.physical_receipt(
		layout.identity)
	var contact := false
	var solid_count := 0
	var empty_count := 0
	for row in rows:
		if not bool(row.expectedHit):
			empty_count += 1
			continue
		solid_count += 1
		var actor := CharacterBody3D.new()
		actor.collision_mask = 2
		actor.position = row.probeFrom
		var collision_shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = main.CELL * 0.05
		collision_shape.shape = sphere
		actor.add_child(collision_shape)
		root_3d.add_child(actor)
		await physics_frame
		contact = actor.move_and_collide(row.probeTo - row.probeFrom) != null
		actor.queue_free()
	await process_frame
	var guard_actor := CharacterBody3D.new()
	guard_actor.collision_mask = 2
	guard_actor.position = bounds.position - Vector3(5, 0, 0)
	var guard_shape := CollisionShape3D.new()
	var guard_sphere := SphereShape3D.new()
	guard_sphere.radius = main.CELL * 0.05
	guard_shape.shape = guard_sphere
	guard_actor.add_child(guard_shape)
	root_3d.add_child(guard_actor)
	var second_guard_actor := CharacterBody3D.new()
	second_guard_actor.collision_mask = 2
	second_guard_actor.position = bounds.position - Vector3(5, 0, 0)
	var second_guard_shape := CollisionShape3D.new()
	var second_guard_capsule := CapsuleShape3D.new()
	second_guard_capsule.radius = 0.35
	second_guard_capsule.height = 1.8
	second_guard_shape.shape = second_guard_capsule
	second_guard_actor.add_child(second_guard_shape)
	root_3d.add_child(second_guard_actor)
	var crossing_motion: Vector3 = bounds.get_center() - guard_actor.position
	var first_identity: Dictionary = layout.identity.duplicate(true)
	var first_window_token: String = window.windowToken
	var edit_state := {"materialId":3, "biomeId":13, "fluidId":0,
		"solid":true, "density":1.5, "light":Vector2i.ZERO,
		"metadata":{"saveDelta":true,"source":"terrain_edit"},
		"blockId":"window-revision-edit", "editReason":"contract"}
	var distant_cell := Vector3i(1000,-1,1000)
	var distant_commit: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"windowed-physical:verified-distant-edit",
		"expectedRevision":0,
		"operations":[{"kind":"set", "cell":distant_cell,
			"state":edit_state}]})
	var distant_plan: Dictionary = EDIT_PLAN.for_committed_cells(
		[distant_cell], distant_commit.get("affectedSections", []), 1,
		String(backend.status().get("sourceIdentity", {}).get("hex", "")))
	var verified_distant: Dictionary = broker.observe_verified_durable_edit(
		distant_commit, distant_plan)
	var retained_layout: Dictionary = {}
	for frame in range(300):
		broker.advance()
		retained_layout = broker.collision_window_layout()
		if retained_layout.get("status") == "ready" \
				and retained_layout.get("identity", {}).get("sourceRevision") == 1:
			break
		await process_frame
	var retained_window: Dictionary = retained_layout.get("windows", [{}])[0]
	var retained_proof: Dictionary = retained_window.get("localCurrentProof", {})
	var incomplete_proof_rejected: Dictionary = owner.physical_receipt_for_layout(
		retained_window.get("identity", {}), {}, retained_layout.get("identity", {}))
	var stale_proof := retained_proof.duplicate(true)
	stale_proof.throughGlobalRevision = 0
	var stale_proof_rejected: Dictionary = owner.physical_receipt_for_layout(
		retained_window.get("identity", {}), stale_proof,
		retained_layout.get("identity", {}))
	var foreign_global_identity: Dictionary = retained_layout.get("identity", {}).duplicate(true)
	foreign_global_identity.sourceIdentity = {"hex":"foreign-source"}
	var foreign_proof_rejected: Dictionary = owner.physical_receipt_for_layout(
		retained_window.get("identity", {}), retained_proof,
		foreign_global_identity)
	var relabelled_geometry_rejected: Dictionary = owner.physical_receipt_for_layout(
		retained_layout.get("identity", {}), retained_proof,
		retained_layout.get("identity", {}))
	owner_source.fault_block = retained_window.get("blocks", [Vector3i.ZERO])[0]
	var changed_key_rejected: Dictionary = owner.physical_receipt_for_layout(
		retained_window.get("identity", {}), retained_proof,
		retained_layout.get("identity", {}))
	owner_source.fault_block = null
	var retained_receipt: Dictionary = {}
	for frame in range(100):
		retained_receipt = owner.physical_receipt_for_layout(
			retained_window.get("identity", {}), retained_proof,
			retained_layout.get("identity", {}))
		if bool(retained_receipt.get("ready", false)): break
		await process_frame
	var retained_contact := false
	for row in rows:
		if not bool(row.expectedHit): continue
		var retained_actor := CharacterBody3D.new()
		retained_actor.collision_mask = 2
		retained_actor.position = row.probeFrom
		var retained_shape := CollisionShape3D.new()
		var retained_sphere := SphereShape3D.new()
		retained_sphere.radius = main.CELL * 0.05
		retained_shape.shape = retained_sphere
		retained_actor.add_child(retained_shape)
		root_3d.add_child(retained_actor)
		await physics_frame
		retained_contact = retained_actor.move_and_collide(
			row.probeTo - row.probeFrom) != null
		retained_actor.queue_free()
		await process_frame
		break
	var retained_aggregate: Dictionary = coordinator.aggregate_readiness(
		retained_layout.get("identity", {}))
	var retained_source: Dictionary = facade.collision_source_snapshot()
	if OS.get_environment("N3_N5_PROOF_REBIND_ONLY") == "1":
		var unhealthy_block: Vector3i = Vector3i.ZERO
		for row in rows:
			if bool(row.get("expectedHit", false)):
				unhealthy_block = row.block
				break
		var terminal_owner_shape_retirement: Dictionary = \
			owner.retire_collision_entry_shape(unhealthy_block, 0)
		var terminal_owner_receipt: Dictionary = {}
		for frame in range(40):
			terminal_owner_receipt = owner.physical_receipt_for_layout(
				retained_window.identity, retained_proof, retained_layout.identity)
			if terminal_owner_receipt.get("healthValidation", {}).get("status") == "failed":
				break
			await process_frame
		var terminal_owner_aggregate: Dictionary = {}
		for frame in range(40):
			terminal_owner_aggregate = coordinator.aggregate_readiness(
				retained_layout.identity)
			if terminal_owner_aggregate.get("status") == "failed": break
			await process_frame
		guard_actor.queue_free()
		await process_frame
		var focused_coordinator_drain: Dictionary = await coordinator.stop_and_drain()
		var focused_broker_stop: Dictionary = broker.stop()
		for frame in range(500):
			if focused_broker_stop.get("status") == "ready": break
			await process_frame
			focused_broker_stop = broker.drain_step()
		root_3d.queue_free()
		main.free()
		var rebind_scan: Dictionary = retained_receipt.get("sourceTicketRebind", {})
		var focused_passed: bool = initialized.get("status") == "ready" \
			and broker_setup.get("status") == "ready" \
			and coordinator_setup.get("status") == "ready" \
			and registered.get("status") == "ready" \
			and rows.size() == 2 and solid_count == 1 and empty_count == 1 \
			and published.get("status") == "ready" and contact \
			and distant_commit.get("commitStatus") == "committed" \
			and verified_distant.get("status") == "ready" \
			and retained_layout.get("identity", {}).get("sourceRevision") == 1 \
			and retained_window.get("identity", {}).get("sourceRevision") == 0 \
			and retained_proof.get("kind") \
				== "verified_native_affected_mesh_exclusion/v1" \
			and not bool(incomplete_proof_rejected.get("ready", false)) \
			and incomplete_proof_rejected.get("reason") \
				== "resident_local_current_proof_invalid" \
			and not bool(stale_proof_rejected.get("ready", false)) \
			and stale_proof_rejected.get("reason") \
				== "resident_local_current_proof_invalid" \
			and not bool(foreign_proof_rejected.get("ready", false)) \
			and foreign_proof_rejected.get("reason") \
				== "resident_local_current_proof_invalid" \
			and not bool(relabelled_geometry_rejected.get("ready", false)) \
			and relabelled_geometry_rejected.get("reason") \
				== "resident_collision_not_current" \
			and not bool(changed_key_rejected.get("ready", false)) \
			and changed_key_rejected.get("reason") \
				== "resident_rebind_artifact_mismatch" \
			and bool(retained_receipt.get("ready", false)) \
			and retained_receipt.get("provenance", {}).get("requestIdentity") \
				== retained_window.get("identity", {}) \
			and retained_receipt.get("provenance", {}).get("globalLayoutIdentity") \
				== retained_layout.get("identity", {}) \
			and retained_receipt.get("provenance", {}).get("localCurrentProof") \
				== retained_proof \
			and rebind_scan.get("status") == "ready" \
			and rebind_scan.get("localArtifactIdentity") \
				== retained_window.get("identity", {}) \
			and rebind_scan.get("globalLayoutIdentity") \
				== retained_layout.get("identity", {}) \
			and int(rebind_scan.get("validatedBlocks", -1)) \
				== retained_window.get("blocks", []).size() \
			and int(rebind_scan.get("maxOperations", -1)) \
				<= OWNER.SOURCE_REBIND_OPERATION_BUDGET \
			and int(rebind_scan.get("operationBudget", -1)) \
				== OWNER.SOURCE_REBIND_OPERATION_BUDGET \
			and int(rebind_scan.get("stepUsecBudget", -1)) \
				== OWNER.SOURCE_REBIND_STEP_USEC_BUDGET \
			and retained_contact and retained_aggregate.get("status") == "ready" \
			and terminal_owner_shape_retirement.get("status") == "pending" \
			and terminal_owner_receipt.get("healthValidation", {}).get("status") == "failed" \
			and terminal_owner_aggregate.get("status") == "failed" \
			and terminal_owner_aggregate.get("reason") \
				== "resident_collision_entry_unhealthy" \
			and focused_coordinator_drain.get("status") == "ready" \
			and focused_coordinator_drain.get("remainingChildren") == 0 \
			and focused_coordinator_drain.get("activeBarriers") == 0 \
			and focused_broker_stop.get("status") == "ready"
		_finish(focused_passed, {"mode":"proof-backed-source-ticket-rebind",
			"initial":{"layout":layout, "publication":published,
				"contact":contact, "aggregate":aggregate},
			"distantEdit":{"commit":distant_commit, "plan":distant_plan,
				"observed":verified_distant},
			"retained":{"layout":retained_layout, "source":retained_source,
				"negativeProofs":{"incomplete":incomplete_proof_rejected,
					"stale":stale_proof_rejected,
					"foreign":foreign_proof_rejected,
					"relabelledGeometry":relabelled_geometry_rejected,
					"changedArtifactKey":changed_key_rejected},
				"physical":retained_receipt,
				"actorContactAfterRebind":retained_contact,
				"aggregate":retained_aggregate},
			"terminalOwnerFailure":{"shapeRetirement":terminal_owner_shape_retirement,
				"physicalReceipt":terminal_owner_receipt,
				"aggregate":terminal_owner_aggregate},
			"drain":{"coordinator":focused_coordinator_drain,
				"broker":focused_broker_stop}})
		return
	layout = retained_layout
	window = retained_window
	# A second actor window can keep a multi-window release pending after the
	# first window's retired barrier has already released. Exercise that partial
	# lifecycle before replacing the first real physical owner below.
	var second_window := {"id":Vector3i(4, 0, 0),
		"windowToken":"fixture:second-actor-window"}
	var second_window_bounds := AABB(Vector3(512, 0, 512), Vector3(4, 4, 4))
	var second_window_actor := CharacterBody3D.new()
	second_window_actor.position = second_window_bounds.get_center()
	var second_window_shape := CollisionShape3D.new()
	var second_window_sphere := SphereShape3D.new()
	second_window_sphere.radius = 0.35
	second_window_shape.shape = second_window_sphere
	second_window_actor.add_child(second_window_shape)
	root_3d.add_child(second_window_actor)
	await physics_frame
	var second_window_hold: Dictionary = coordinator.begin_window_barrier(
		second_window, second_window_bounds, layout.identity)
	var first_old_hold: Dictionary = coordinator.begin_window_barrier(
		window, bounds, layout.identity)
	var first_old_barrier: RefCounted = first_old_hold.get("barrier")
	var first_rebind_hold: Dictionary = coordinator.begin_window_barrier(
		window, bounds, layout.identity)
	var second_window_clearance: Dictionary = second_window_hold.get("barrier").clearance(
		layout.identity)
	var partial_barrier_release: Dictionary = coordinator.release_barriers(layout.identity)
	var first_old_barrier_released: bool = not first_old_barrier.is_active()
	var first_old_record_removed := true
	for retired_record in coordinator._retired_barriers:
		if retired_record.get("barrier") == first_old_barrier:
			first_old_record_removed = false
	var owner_live_after_partial_release: bool = owner.is_inside_tree() \
		and owner._live.size() == window.get("blocks", []).size()
	second_window_actor.position = second_window_bounds.position + Vector3(8, 0, 8)
	await physics_frame
	var second_window_released: bool = second_window_hold.get("barrier").release(
		layout.identity)
	second_window_actor.queue_free()
	await process_frame
	var old_hold: Dictionary = coordinator.begin_window_barrier(window,
		bounds.grow(0.5), layout.identity)
	var old_barrier: RefCounted = old_hold.get("barrier")
	var old_barrier_bounds: AABB = bounds.grow(0.5)
	var old_census: Dictionary = old_hold.get("census", {})
	while old_census.get("status") == "pending":
		await process_frame
		old_census = old_barrier.census_progress(layout.identity)
	var committed: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"windowed-physical:revision-change",
		"expectedRevision":1,
		"operations":[{"kind":"set", "cell":Vector3i(0,base_y * 16,0),
			"state":edit_state}]})
	var replacement_layout: Dictionary = {}
	for frame in range(300):
		broker.advance()
		replacement_layout = broker.collision_window_layout()
		if replacement_layout.get("status") == "ready" \
				and replacement_layout.get("layoutToken") != layout.layoutToken:
			break
		await process_frame
	var replacement_window: Dictionary = replacement_layout.get("windows", [{}])[0]
	var original_replacement_layout: Dictionary = replacement_layout.duplicate(true)
	var affected_window_rebind_rejected: Dictionary = owner.physical_receipt_for_layout(
		retained_window.get("identity", {}),
		replacement_window.get("localCurrentProof", {}),
		replacement_layout.get("identity", {}))
	var replacement_hold: Dictionary = coordinator.begin_window_barrier(
		replacement_window, bounds, replacement_layout.identity)
	var replacement_barrier: RefCounted = replacement_hold.get("barrier")
	var replacement_barrier_bounds: AABB = bounds
	var initial_replacement_barrier_bounds: AABB = bounds
	var retired_old_barrier_record: Dictionary = coordinator._retired_barriers.back() \
		if not coordinator._retired_barriers.is_empty() else {}
	var retired_old_barrier_identity: Dictionary = retired_old_barrier_record.get(
		"identity", {})
	var incumbent_barrier_identity_differs_from_owner_identity: bool = \
		retired_old_barrier_identity != window.get("identity", {})
	var same_id_retired_barrier_token_matches_incumbent: bool = \
		retired_old_barrier_record.get("windowId") == window.id \
		and retired_old_barrier_record.get("windowToken") == window.windowToken
	var replacement_census: Dictionary = replacement_hold.get("census", {})
	while replacement_census.get("status") == "pending":
		await process_frame
		replacement_census = replacement_barrier.census_progress(
			replacement_layout.identity)
	var overlap_barriers: int = coordinator.active_barrier_count()
	var denied_before_drain: bool = not coordinator.admit_motion(
		guard_actor, crossing_motion)
	var denied_placement_before: bool = not coordinator.admit_placement(
		guard_actor, Transform3D(Basis.IDENTITY, bounds.get_center()))
	var premature_replacement_release: Dictionary = coordinator.release_barriers(
		replacement_layout.identity)
	var replacement_requests := []
	for block: Vector3i in replacement_window.blocks:
		replacement_requests.append(broker.request_block(block))
	var replacement_facade_status: Dictionary = {}
	var replacement_facade
	var replacement_snapshot: Dictionary = {}
	for frame in range(500):
		broker.advance()
		replacement_facade_status = broker.collision_window_source(
			replacement_window.id, replacement_layout.layoutToken)
		if replacement_facade_status.get("status") == "ready":
			replacement_facade = replacement_facade_status.source
			replacement_snapshot = replacement_facade.collision_source_snapshot()
			if replacement_snapshot.get("status") == "ready": break
		await process_frame
	var replacement_rows: Array[Dictionary] = []
	if replacement_snapshot.get("status") == "ready":
		for block: Vector3i in replacement_window.blocks:
			var row_status: Dictionary = replacement_facade.collision_artifact_row_snapshot(
				block, replacement_layout.identity)
			if row_status.get("status") == "ready":
				replacement_rows.append(row_status.row)
	var replacement_owner = OWNER.new()
	coordinator.add_child(replacement_owner)
	var replacement_bound: bool = replacement_owner.bind_source(replacement_facade)
	var cancelled_stage: Dictionary = coordinator.stage_window_replacement(
		replacement_window, replacement_owner)
	var pre_replacement_memory: Dictionary = memory_admission.snapshot() \
		if memory_configured else {}
	var cancelled_candidate_publish: Dictionary = {}
	if replacement_rows.size() == replacement_window.get("blocks", []).size():
		cancelled_candidate_publish = await replacement_owner.publish({
			"schema":"n5-resident-collision-publication/v1",
			"identity":replacement_layout.identity,
			"residentBlocks":replacement_window.blocks,
			"affectedBlocks":replacement_window.blocks,
			"rows":replacement_rows}, replacement_barrier)
	var cancelled_candidate_receipt: Dictionary = replacement_owner.physical_receipt(
		replacement_window.identity)
	var cancellation_drift_broker := CancellationDriftBroker.new()
	cancellation_drift_broker.window_token = String(replacement_window.windowToken)
	var original_cancel_broker: Object = coordinator._broker
	coordinator._broker = cancellation_drift_broker
	var cancellation_drift_negative: Dictionary = {}
	if cancelled_stage.get("status") == "ready":
		cancellation_drift_negative = await coordinator.cancel_staged_replacement(
			replacement_window.id, String(cancelled_stage.get("physicalOwnerEpoch", "")))
	coordinator._broker = original_cancel_broker
	var candidate_retained_after_drift_failure: bool = coordinator._staged_owners.has(
		replacement_window.id) and is_instance_valid(replacement_owner) \
		and not replacement_owner.is_queued_for_deletion()
	var cancellation_edit_state: Dictionary = edit_state.duplicate(true)
	cancellation_edit_state["materialId"] = 4
	cancellation_edit_state["blockId"] = "windowed-physical:cancellation-drift"
	var cancellation_drift_commit: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"windowed-physical:candidate-cancellation-drift",
		"expectedRevision":2,
		"operations":[{"kind":"set", "cell":Vector3i(0,base_y * 16,0),
			"state":cancellation_edit_state}]})
	var cancellation_drift_layout: Dictionary = {}
	for frame in range(300):
		broker.advance()
		cancellation_drift_layout = broker.collision_window_layout()
		if cancellation_drift_layout.get("status") == "ready" \
				and cancellation_drift_layout.get("identity", {}).get("sourceRevision") == 3 \
				and cancellation_drift_layout.get("layoutToken") \
				!= replacement_layout.get("layoutToken"):
			break
		await process_frame
	var cancelled_candidate_token := String(replacement_window.windowToken)
	var candidate_token_retired_after_drift: bool = cancellation_drift_layout.get(
		"retiredWindowTokens", cancellation_drift_layout.get("retirementTelemetry", {}) \
			.get("retiredWindowTokens", [])).has(cancelled_candidate_token)
	var candidate_record_retained_before_ack: bool = broker._window_records.has(
		cancelled_candidate_token)
	var ack_pending_broker := AckPendingBroker.new(broker)
	var original_ack_broker: Object = coordinator._broker
	coordinator._broker = ack_pending_broker
	var cancellation_ack_deferred: Dictionary = {}
	if cancelled_stage.get("status") == "ready":
		cancellation_ack_deferred = await coordinator.cancel_staged_replacement(
			replacement_window.id, String(cancelled_stage.get("physicalOwnerEpoch", "")))
	coordinator._broker = original_ack_broker
	var lease_after_deferred_ack := String(coordinator._staged_owners.get(
		replacement_window.id, {}).get("retirementLeaseId", ""))
	var candidate_record_retained_after_deferred_ack: bool = broker._window_records.has(
		cancelled_candidate_token)
	var ack_retry_edit_state: Dictionary = cancellation_edit_state.duplicate(true)
	ack_retry_edit_state["materialId"] = 5
	ack_retry_edit_state["blockId"] = "windowed-physical:ack-retry-layout-drift"
	var ack_retry_commit: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"windowed-physical:candidate-cancellation-ack-retry",
		"expectedRevision":3,
		"operations":[{"kind":"set", "cell":Vector3i(0,base_y * 16,0),
			"state":ack_retry_edit_state}]})
	var ack_retry_layout: Dictionary = {}
	for frame in range(300):
		broker.advance()
		ack_retry_layout = broker.collision_window_layout()
		if ack_retry_layout.get("status") == "ready" \
				and ack_retry_layout.get("identity", {}).get("sourceRevision") == 4 \
				and ack_retry_layout.get("layoutToken") != cancellation_drift_layout.get("layoutToken"):
			break
		await process_frame
	var candidate_retired_after_ack_layout_advance: bool = ack_retry_layout.get(
		"retiredWindowTokens", ack_retry_layout.get("retirementTelemetry", {}) \
			.get("retiredWindowTokens", [])).has(cancelled_candidate_token)
	var cancelled_candidate: Dictionary = {}
	if cancelled_stage.get("status") == "ready":
		cancelled_candidate = await coordinator.cancel_staged_replacement(
			replacement_window.id, String(cancelled_stage.get("physicalOwnerEpoch", "")))
	cancellation_drift_layout = ack_retry_layout
	var candidate_drain_before_ack: Dictionary = cancellation_ack_deferred.get(
		"drain", {}).get("drain", {})
	var cancelled_candidate_layout: Dictionary = cancellation_drift_layout.duplicate(true)
	var candidate_record_removed_after_ack: bool = not broker._window_records.has(
		cancelled_candidate_token)
	var old_registry_after_cancel: bool = coordinator._owners.get(window.id) == owner
	var old_owner_live_after_cancel: bool = owner.is_inside_tree() \
		and owner._live.size() == window.get("blocks", []).size()
	var old_solid_body_live_after_cancel := false
	for old_entry in owner._live.values():
		if not bool(old_entry.get("expectedHit", false)): continue
		var old_body = old_entry.get("body")
		old_solid_body_live_after_cancel = is_instance_valid(old_body) \
			and old_body.is_inside_tree() and not old_body.is_queued_for_deletion() \
			and old_body.get_parent() == owner
	var memory_after_candidate_cancel: Dictionary = memory_admission.snapshot() \
		if memory_configured else {}
	await process_frame
	replacement_layout = cancellation_drift_layout
	replacement_window = replacement_layout.get("windows", [{}])[0]
	replacement_hold = coordinator.begin_window_barrier(replacement_window,
		bounds, replacement_layout.identity)
	replacement_barrier = replacement_hold.get("barrier")
	replacement_barrier_bounds = bounds
	initial_replacement_barrier_bounds = bounds
	replacement_census = replacement_hold.get("census", {})
	while replacement_census.get("status") == "pending":
		await process_frame
		replacement_census = replacement_barrier.census_progress(
			replacement_layout.identity)
	replacement_requests = []
	for block: Vector3i in replacement_window.blocks:
		replacement_requests.append(broker.request_block(block))
	replacement_facade = null
	replacement_snapshot = {}
	for frame in range(500):
		broker.advance()
		var acquired: Dictionary = broker.collision_window_source(
			replacement_window.id, replacement_layout.layoutToken)
		if acquired.get("status") == "ready":
			replacement_facade = acquired.source
			replacement_snapshot = replacement_facade.collision_source_snapshot()
			if replacement_snapshot.get("status") == "ready": break
		await process_frame
	replacement_rows = []
	if replacement_snapshot.get("status") == "ready":
		for block: Vector3i in replacement_window.blocks:
			var row_status: Dictionary = replacement_facade.collision_artifact_row_snapshot(
				block, replacement_layout.identity)
			if row_status.get("status") == "ready":
				replacement_rows.append(row_status.row)
	replacement_owner = OWNER.new()
	coordinator.add_child(replacement_owner)
	replacement_bound = replacement_owner.bind_source(replacement_facade)
	var replacement_staged: Dictionary = coordinator.stage_window_replacement(
		replacement_window, replacement_owner)
	var before_replacement_install: Dictionary = coordinator.aggregate_readiness(
		replacement_layout.identity)
	var replacement_published: Dictionary = {}
	if replacement_rows.size() == replacement_window.get("blocks", []).size():
		replacement_published = await replacement_owner.publish({
			"schema":"n5-resident-collision-publication/v1",
			"identity":replacement_layout.identity,
			"residentBlocks":replacement_window.blocks,
			"affectedBlocks":replacement_window.blocks,
			"rows":replacement_rows}, replacement_barrier)
	var candidate_receipt: Dictionary = replacement_owner.physical_receipt(
		replacement_window.identity)
	var old_owner_live_through_candidate_ack: bool = owner.is_inside_tree() \
		and owner._live.size() == window.get("blocks", []).size()
	var old_owner_live_debug := {"ownerInsideTree":owner.is_inside_tree(),
		"liveEntryCount":owner._live.size(),
		"expectedEntryCount":window.get("blocks", []).size(),
		"bodies":[]}
	for old_entry in owner._live.values():
		var old_body = old_entry.get("body")
		old_owner_live_debug.bodies.append({"valid":is_instance_valid(old_body),
			"insideTree":is_instance_valid(old_body) and old_body.is_inside_tree(),
			"queued":is_instance_valid(old_body) and old_body.is_queued_for_deletion(),
			"expectedHit":bool(old_entry.get("expectedHit", false)),
			"parentIsOwner":is_instance_valid(old_body) and old_body.get_parent() == owner})
		if bool(old_entry.get("expectedHit", false)):
			old_owner_live_through_candidate_ack = old_owner_live_through_candidate_ack \
				and is_instance_valid(old_body) and old_body.is_inside_tree() \
				and not old_body.is_queued_for_deletion() and old_body.get_parent() == owner
		else:
			old_owner_live_through_candidate_ack = old_owner_live_through_candidate_ack \
				and not is_instance_valid(old_body) \
				and old_entry.get("shapes", []).is_empty()
	var old_epoch_before_switch := String(owner.retirement_owner_epoch())
	var old_registry_unchanged: bool = coordinator._owners.get(window.id) == owner
	var staged_layout_ticket := String(coordinator._staged_owners[window.id].layoutToken)
	coordinator._staged_owners[window.id].layoutToken = "drifted:" + staged_layout_ticket
	var drifted_ticket_commit: Dictionary = coordinator.commit_staged_replacement(
		replacement_window, replacement_owner, replacement_barrier)
	var old_registry_after_drift_rejection: bool = coordinator._owners.get(window.id) == owner
	coordinator._staged_owners[window.id].layoutToken = staged_layout_ticket
	var stale_candidate_window := replacement_window.duplicate(true)
	stale_candidate_window.windowToken = "stale:" + String(stale_candidate_window.windowToken)
	var stale_stage_commit: Dictionary = coordinator.commit_staged_replacement(
		stale_candidate_window, replacement_owner, replacement_barrier)
	var old_registry_after_rejected_commit: bool = coordinator._owners.get(window.id) == owner
	var replacement_switch: Dictionary = {}
	if replacement_published.get("status") == "ready" \
			and candidate_receipt.get("ready", false):
		replacement_switch = coordinator.commit_staged_replacement(
			replacement_window, replacement_owner, replacement_barrier)
	var replacement_aggregate: Dictionary = {"status":"pending"}
	for frame in range(120):
		replacement_aggregate = coordinator.aggregate_readiness(
			replacement_layout.identity)
		if replacement_aggregate.get("status") != "pending": break
		await process_frame
	var post_replacement_memory: Dictionary = memory_admission.snapshot() \
		if memory_configured else {}
	var displaced_owner_retained_after_switch: bool = coordinator._displaced_owners \
		.get(window.id, {}).get("owner") == owner \
		and owner.is_inside_tree() and owner._live.size() == window.blocks.size()
	var old_only_actor_position := Vector3(bounds.position.x - 0.25,
		bounds.get_center().y, bounds.get_center().z)
	guard_actor.position = old_only_actor_position
	second_guard_actor.position = bounds.position - Vector3(5, 0, 0)
	await physics_frame
	var old_only_old_barrier_clearance: Dictionary = old_barrier.clearance(layout.identity)
	var old_only_replacement_barrier_clearance: Dictionary = replacement_barrier.clearance(
		replacement_layout.identity)
	var initial_replacement_covers_old: bool = replacement_barrier.covers_bounds(
		replacement_layout.identity, old_barrier_bounds)
	var old_only_retirement: Dictionary = await coordinator.retire_displaced_window(window.id)
	var second_actor_still_outside_old_bounds: bool = not old_barrier_bounds.has_point(
		second_guard_actor.global_position)
	var second_actor_registered: bool = coordinator.register_moving_actor(second_guard_actor)
	var second_actor_motion_denied: bool = not coordinator.admit_motion(second_guard_actor,
		old_only_actor_position - second_guard_actor.position)
	var old_owner_live_during_old_only_hold: bool = owner.is_inside_tree() \
		and owner._live.size() == window.get("blocks", []).size()
	var old_solid_body_live_during_old_only_hold := false
	for old_entry in owner._live.values():
		if not bool(old_entry.get("expectedHit", false)): continue
		var old_body = old_entry.get("body")
		old_solid_body_live_during_old_only_hold = is_instance_valid(old_body) \
			and old_body.is_inside_tree() and not old_body.is_queued_for_deletion() \
			and old_body.get_parent() == owner
	var union_barrier_hold: Dictionary = coordinator.begin_window_barrier(
		replacement_window, old_barrier_bounds, replacement_layout.identity)
	var union_replacement_barrier: RefCounted = union_barrier_hold.get("barrier")
	var union_barrier_census: Dictionary = union_barrier_hold.get("census", {})
	while union_barrier_census.get("status") == "pending":
		await process_frame
		union_barrier_census = union_replacement_barrier.census_progress(
			replacement_layout.identity)
	var union_retirement_with_actor: Dictionary = await coordinator.retire_displaced_window(
		window.id)
	var old_owner_live_during_union_hold: bool = owner.is_inside_tree() \
		and owner._live.size() == window.get("blocks", []).size()
	for old_entry in owner._live.values():
		if not bool(old_entry.get("expectedHit", false)): continue
		var old_body = old_entry.get("body")
		old_owner_live_during_union_hold = old_owner_live_during_union_hold \
			and is_instance_valid(old_body) and old_body.is_inside_tree() \
			and not old_body.is_queued_for_deletion() and old_body.get_parent() == owner
	guard_actor.position = bounds.position - Vector3(5, 0, 0)
	second_guard_actor.position = bounds.position - Vector3(6, 0, 0)
	await physics_frame
	var union_replacement_clearance: Dictionary = union_replacement_barrier.clearance(
		replacement_layout.identity)
	var union_replacement_covers_old: bool = union_replacement_barrier.covers_bounds(
		replacement_layout.identity, old_barrier_bounds)
	replacement_barrier = union_replacement_barrier
	replacement_barrier_bounds = old_barrier_bounds
	var replaced_old: Dictionary = await coordinator.retire_displaced_window(window.id)
	var denied_after_drain: bool = not coordinator.admit_motion(
		guard_actor, crossing_motion)
	var denied_placement_after: bool = not coordinator.admit_placement(
		guard_actor, Transform3D(Basis.IDENTITY, bounds.get_center()))
	var replacement_release: Dictionary = coordinator.release_barriers(
		replacement_layout.identity)
	var admitted_after_replacement: bool = coordinator.admit_motion(
		guard_actor, crossing_motion)
	var placement_after_replacement: bool = coordinator.admit_placement(
		guard_actor, Transform3D(Basis.IDENTITY, bounds.get_center()))
	var barriers_after_release: int = coordinator.active_barrier_count()
	guard_actor.queue_free()
	second_guard_actor.queue_free()
	await process_frame
	owner = replacement_owner
	facade = replacement_facade
	layout = replacement_layout
	window = replacement_window
	rows = replacement_rows
	var shifted: Dictionary = planner.replace_sources(
		{"position":Vector3(main.CELL * 512.0, 0, 0), "distance":0},
		[], [], [], Vector2i(base_y * 16, (base_y + 1) * 16))
	var changed_layout: Dictionary = {}
	var changed_step: Dictionary = {}
	for frame in range(300):
		changed_step = broker.advance()
		changed_layout = broker.collision_window_layout()
		if changed_layout.get("status") == "ready" \
				and changed_layout.get("layoutToken") != layout.layoutToken:
			break
		await process_frame
	changed_layout = await _await_window_layout(broker, changed_layout,
		"changed source revision")
	var old_facade_pending: Dictionary = facade.collision_source_snapshot()
	var changed_aggregate: Dictionary = coordinator.aggregate_readiness(
		changed_layout.identity)
	var old_token: String = window.windowToken
	var premature_retirement: Dictionary = broker.acknowledge_collision_window_retired(
		old_token, {"windowToken":old_token, "drained":false,
			"remainingBodies":1})
	var retirement_hold: Dictionary = coordinator.begin_window_barrier(window,
		bounds, changed_layout.identity)
	var retirement_barrier: RefCounted = retirement_hold.get("barrier")
	var retirement_census: Dictionary = retirement_hold.get("census", {})
	while retirement_census.get("status") == "pending":
		await process_frame
		retirement_census = retirement_barrier.census_progress(changed_layout.identity)
	var drain_reversion := {}
	var reversion_callback := func(_window_id: Vector3i, _window_token: String,
			_lease_id: String) -> void:
		planner.replace_sources({"position":Vector3.ZERO, "distance":0},
			[], [], [], Vector2i(base_y * 16, (base_y + 1) * 16))
		drain_reversion["advance"] = broker.advance()
		drain_reversion["layout"] = broker.collision_window_layout()
	coordinator.window_retirement_drain_started.connect(reversion_callback,
		CONNECT_ONE_SHOT)
	var retirement: Dictionary = await coordinator.retire_window(window.id)
	var drained: Dictionary = retirement.get("drain", {})
	var reactivated_layout: Dictionary = {}
	for frame in range(300):
		broker.advance()
		reactivated_layout = broker.collision_window_layout()
		if reactivated_layout.get("status") == "ready" \
				and reactivated_layout.get("windowCount") == 1:
			break
		await process_frame
	var reactivated_window: Dictionary = reactivated_layout.get("windows", [{}])[0]
	var reactivated_requests := []
	for block: Vector3i in reactivated_window.get("blocks", []):
		reactivated_requests.append(broker.request_block(block))
	var reactivated_facade
	var reactivated_snapshot: Dictionary = {}
	for frame in range(500):
		broker.advance()
		var acquired: Dictionary = broker.collision_window_source(
			reactivated_window.get("id", Vector3i.ZERO),
			String(reactivated_layout.get("layoutToken", "")))
		if acquired.get("status") == "ready":
			reactivated_facade = acquired.source
			reactivated_snapshot = reactivated_facade.collision_source_snapshot()
			if reactivated_snapshot.get("status") == "ready": break
		await process_frame
	var reactivated_rows: Array[Dictionary] = []
	if reactivated_snapshot.get("status") == "ready":
		for block: Vector3i in reactivated_window.blocks:
			var row_status: Dictionary = reactivated_facade.collision_artifact_row_snapshot(
				block, reactivated_window.identity)
			if row_status.get("status") == "ready":
				reactivated_rows.append(row_status.row)
	var reactivated_owner = OWNER.new()
	coordinator.add_child(reactivated_owner)
	var reactivated_bound: bool = reactivated_owner.bind_source(reactivated_facade)
	var reactivated_registered: Dictionary = coordinator.register_window(
		reactivated_window, reactivated_owner)
	var reactivated_hold: Dictionary = coordinator.begin_window_barrier(
		reactivated_window, bounds, reactivated_layout.identity)
	var reactivated_barrier: RefCounted = reactivated_hold.get("barrier")
	var reactivated_census: Dictionary = reactivated_hold.get("census", {})
	while reactivated_census.get("status") == "pending":
		await process_frame
		reactivated_census = reactivated_barrier.census_progress(
			reactivated_layout.identity)
	var blocked_during_reversion: Dictionary = coordinator.aggregate_readiness(
		reactivated_layout.identity)
	var reactivated_publish: Dictionary = {}
	if reactivated_rows.size() == reactivated_window.get("blocks", []).size():
		reactivated_publish = await reactivated_owner.publish({
			"schema":"n5-resident-collision-publication/v1",
			"identity":reactivated_window.identity,
			"residentBlocks":reactivated_window.blocks,
			"affectedBlocks":reactivated_window.blocks,
			"rows":reactivated_rows}, reactivated_barrier)
	var reactivated_aggregate: Dictionary = coordinator.aggregate_readiness(
		reactivated_layout.identity)
	var reactivated_release: Dictionary = coordinator.release_barriers(
		reactivated_layout.identity)
	var retired_facade: Dictionary = facade.collision_source_snapshot()
	var coordinator_drain: Dictionary = await coordinator.stop_and_drain()
	var aggregate_unbound := main.unbind_native_collision_admission(root_3d)
	var final_memory: Dictionary = memory_admission.snapshot() \
		if memory_configured else {}
	var broker_stop: Dictionary = broker.stop()
	for frame in range(100):
		if broker_stop.get("status") == "ready": break
		await process_frame
		broker_stop = broker.drain_step()
	root_3d.queue_free()
	main.free()
	var passed: bool = initialized.get("status") == "ready" \
		and page_setup.get("status") == "ready" \
		and planner_setup.get("status") == "ready" \
		and planned.get("status") == "ready" \
		and broker_setup.get("status") == "ready" \
		and coordinator_setup.get("status") == "ready" \
		and memory_configured \
		and registered.get("status") == "ready" \
		and initial_layout.get("status") == "pending" \
		and initial_aggregate.get("status") == "pending" \
		and required.get("blocks", []).size() == 2 \
		and layout.get("status") == "ready" and layout.windowCount == 1 \
		and snapshot.get("status") == "ready" \
		and rows.size() == 2 and solid_count == 1 and empty_count == 1 \
		and published.get("status") == "ready" \
		and same_window_replacement.get("status") == "ready" \
		and int(initial_memory.get("totalChargedBytes", 0)) > 0 \
		and int(same_window_memory.get("lastCandidateAdmission", {}).get(
			"stateChargedBytes", {}).get("live_current", 0)) \
			>= int(initial_memory.get("totalChargedBytes", 0)) \
		and int(same_window_memory.get("lastCandidateAdmission", {}).get(
			"stateChargedBytes", {}).get("candidate_reserved", 0)) > 0 \
		and int(same_window_memory.get("ledger", {}).get("peakChargedBytes", 0)) \
			> int(initial_memory.get("totalChargedBytes", 0)) \
		and int(same_window_memory.get("lastCandidateAdmission", {}).get(
			"totalChargedBytes", 0)) \
			>= 2 * int(initial_memory.get("totalChargedBytes", 0)) \
		and missing_aggregate.get("status") == "pending" \
		and unready_router_setup.get("status") == "ready" and not unready_main_bind \
		and raw_barrier_rejected and router_setup.get("status") == "ready" \
		and aggregate_main_bound and aggregate_motion_held and not aggregate_early_unbind \
		and aggregate.get("status") == "ready" \
		and release_before_actor_deletion.get("status") == "pending" \
		and release_before_actor_deletion.get("reason") \
			== "window_actor_clearance_pending" \
		and released.get("status") == "ready" and contact \
		and active_retirement.get("status") == "pending" \
		and active_retirement.get("reason") == "physical_window_still_demanded" \
		and bool(physical_after_active_rejection.get("ready", false)) \
		and old_hold.get("status") == "ready" \
		and committed.get("commitStatus") == "committed" \
		and replacement_layout.get("status") == "ready" \
		and first_identity.sourceRevision == 0 \
		and distant_commit.get("commitStatus") == "committed" \
		and distant_plan.get("status") == "ready" \
		and verified_distant.get("status") == "ready" \
		and retained_window.get("windowToken") == first_window_token \
		and retained_window.get("identity", {}).get("sourceRevision") == 0 \
		and retained_window.get("localCurrentProof", {}).get("kind") == "verified_native_affected_mesh_exclusion/v1" \
		and not bool(incomplete_proof_rejected.get("ready", false)) \
		and incomplete_proof_rejected.get("reason") == "resident_local_current_proof_invalid" \
		and not bool(stale_proof_rejected.get("ready", false)) \
		and stale_proof_rejected.get("reason") == "resident_local_current_proof_invalid" \
		and not bool(foreign_proof_rejected.get("ready", false)) \
		and foreign_proof_rejected.get("reason") == "resident_local_current_proof_invalid" \
		and not bool(relabelled_geometry_rejected.get("ready", false)) \
		and relabelled_geometry_rejected.get("reason") == "resident_collision_not_current" \
		and not bool(changed_key_rejected.get("ready", false)) \
		and changed_key_rejected.get("reason") == "resident_rebind_artifact_mismatch" \
		and retained_source.get("status") == "ready" \
		and bool(retained_receipt.get("ready", false)) \
		and retained_contact \
		and retained_receipt.get("provenance", {}).get("requestIdentity") \
			== retained_window.get("identity", {}) \
		and retained_receipt.get("provenance", {}).get("globalLayoutIdentity") \
			== retained_layout.get("identity", {}) \
		and retained_receipt.get("provenance", {}).get("localCurrentProof") \
			== retained_proof \
		and retained_aggregate.get("status") == "ready" \
		and second_window_hold.get("status") == "ready" \
		and first_old_hold.get("status") == "ready" \
		and first_rebind_hold.get("status") == "ready" \
		and not bool(second_window_clearance.get("clear", false)) \
		and partial_barrier_release.get("status") == "pending" \
		and partial_barrier_release.get("reason") == "window_actor_clearance_pending" \
		and first_old_barrier_released and first_old_record_removed \
		and owner_live_after_partial_release and second_window_released \
		and original_replacement_layout.identity.sourceRevision == 2 \
		and not bool(affected_window_rebind_rejected.get("ready", false)) \
		and replacement_layout.identity.cancellationEpoch \
			> first_identity.cancellationEpoch \
		and replacement_hold.get("status") == "ready" \
		and overlap_barriers == 2 \
		and denied_before_drain and denied_after_drain \
		and denied_placement_before and denied_placement_after \
		and premature_replacement_release.get("status") == "pending" \
		and replacement_staged.get("status") == "ready" \
		and old_registry_unchanged and old_registry_after_rejected_commit \
		and cancelled_stage.get("status") == "ready" \
		and cancelled_candidate_publish.get("status") == "ready" \
		and cancellation_drift_negative.get("status") == "pending" \
		and cancellation_drift_negative.get("reason") \
			== "physical_window_candidate_retirement_lease_pending" \
		and candidate_retained_after_drift_failure \
		and cancellation_drift_commit.get("commitStatus") == "committed" \
		and cancellation_drift_layout.get("status") == "ready" \
		and candidate_token_retired_after_drift \
		and candidate_record_retained_before_ack \
		and candidate_drain_before_ack.get("drained", false) \
		and int(candidate_drain_before_ack.get("remainingBodies", -1)) == 0 \
		and cancelled_candidate_receipt.get("ready", false) \
		and cancelled_candidate.get("status") == "ready" \
		and cancelled_candidate.get("retirementLease", {}).get("status") == "ready" \
		and cancelled_candidate.get("leaseValidation", {}).get("status") == "ready" \
		and cancelled_candidate.get("acknowledgement", {}).get("status") == "ready" \
		and candidate_record_removed_after_ack \
		and old_registry_after_cancel and old_owner_live_after_cancel \
		and old_solid_body_live_after_cancel \
		and int(memory_after_candidate_cancel.get("totalChargedBytes", -1)) \
			== int(pre_replacement_memory.get("totalChargedBytes", -2)) \
		and drifted_ticket_commit.get("status") == "pending" \
		and old_registry_after_drift_rejection \
		and stale_stage_commit.get("status") == "failed" \
		and old_owner_live_through_candidate_ack \
		and old_epoch_before_switch == replacement_staged.get("oldOwnerEpoch") \
		and candidate_receipt.get("ready", false) \
		and replacement_switch.get("status") == "ready" \
		and displaced_owner_retained_after_switch \
		and replaced_old.get("status") == "ready" \
		and replaced_old.get("drain", {}).get("remainingBodies") == 0 \
		and replaced_old.get("windowToken") == replacement_staged.get("oldWindowToken") \
		and int(replaced_old.get("drain", {}).get("memoryAdmission", {}).get("reservationCount", -1)) == 0 \
		and replacement_snapshot.get("status") == "ready" \
		and replacement_bound and replacement_staged.get("status") == "ready" \
		and before_replacement_install.get("status") == "pending" \
		and replacement_published.get("status") == "ready" \
		and int(pre_replacement_memory.get("totalChargedBytes", 0)) > 0 \
		and int(post_replacement_memory.get("totalChargedBytes", 0)) \
			> int(pre_replacement_memory.get("totalChargedBytes", 0)) \
		and int(post_replacement_memory.get("peakChargedBytes", 0)) \
			> int(initial_memory.get("totalChargedBytes", 0)) \
		and int(final_memory.get("totalChargedBytes", -1)) == 0 \
		and int(final_memory.get("reservationCount", -1)) == 0 \
		and replacement_aggregate.get("status") == "ready" \
		and old_barrier_bounds != initial_replacement_barrier_bounds \
		and not initial_replacement_covers_old \
		and not bool(old_only_old_barrier_clearance.get("clear", false)) \
		and bool(old_only_replacement_barrier_clearance.get("clear", false)) \
		and old_only_retirement.get("status") == "pending" \
		and old_only_retirement.get("reason") \
			== "displaced_replacement_barrier_does_not_cover_old_bounds" \
		and old_owner_live_during_old_only_hold \
		and old_solid_body_live_during_old_only_hold \
		and union_barrier_hold.get("status") == "ready" \
		and union_retirement_with_actor.get("status") == "pending" \
		and union_retirement_with_actor.get("reason") \
			== "displaced_old_barrier_clearance_pending" \
		and old_owner_live_during_union_hold \
		and union_replacement_covers_old \
		and bool(union_replacement_clearance.get("clear", false)) \
		and replacement_release.get("status") == "ready" \
		and admitted_after_replacement and placement_after_replacement \
		and barriers_after_release == 0 \
		and shifted.get("status") == "ready" \
		and changed_layout.get("status") == "ready" \
		and changed_layout.get("layoutToken") != layout.layoutToken \
		and old_facade_pending.get("status") == "pending" \
		and changed_aggregate.get("status") == "pending" \
		and not String(changed_aggregate.get("reason", "")).is_empty() \
		and premature_retirement.get("status") == "failed" \
		and retirement_hold.get("status") == "ready" \
		and drained.get("status") == "ready" \
		and drained.get("windowToken") == old_token \
		and drain_reversion.get("layout", {}).get("status") == "pending" \
		and not String(drain_reversion.get("layout", {}).get("reason", "")).is_empty() \
		and blocked_during_reversion.get("status") == "pending" \
		and reactivated_layout.get("status") == "ready" \
		and reactivated_window.get("windowToken") == old_token \
		and reactivated_snapshot.get("status") == "ready" \
		and reactivated_rows.size() == reactivated_window.get("blocks", []).size() \
		and reactivated_bound and reactivated_registered.get("status") == "ready" \
		and reactivated_publish.get("status") == "ready" \
		and reactivated_aggregate.get("status") == "ready" \
		and reactivated_release.get("status") == "ready" \
		and retirement.get("status") == "ready" \
		and incumbent_barrier_identity_differs_from_owner_identity \
		and same_id_retired_barrier_token_matches_incumbent \
		and second_actor_still_outside_old_bounds and second_actor_registered \
		and second_actor_motion_denied \
		and cancellation_ack_deferred.get("status") == "pending" \
		and cancellation_ack_deferred.get("reason") \
			== "physical_window_candidate_retirement_ack_pending" \
		and not lease_after_deferred_ack.is_empty() \
		and candidate_record_retained_after_deferred_ack \
		and ack_retry_commit.get("status") == "ready" \
		and candidate_retired_after_ack_layout_advance \
		and cancelled_candidate.get("status") == "ready" \
		and retired_facade.get("status") == "failed" \
		and coordinator_drain.get("status") == "ready" \
		and aggregate_unbound \
		and coordinator_drain.get("remainingChildren") == 0 \
		and coordinator_drain.get("activeBarriers") == 0 \
		and broker_stop.get("status") == "ready"
	_finish(passed, {"initialLayout":initial_layout,
		"initialAggregate":initial_aggregate, "required":required,
		"brokerSetup":broker_setup, "lastAdvance":last_advance,
		"maxAdvanceUsec":max_advance_usec, "layout":layout,
		"facadeStatus":{"status":facade_status.get("status"),
			"windowToken":facade_status.get("windowToken")},
		"sourceSnapshot":snapshot, "rowCount":rows.size(),
		"mainAdmission":{"unreadyRouterSetup":unready_router_setup,
			"unreadyBindAccepted":unready_main_bind,
			"rawBarrierRejected":raw_barrier_rejected,
			"routerSetup":router_setup, "aggregateBindAccepted":aggregate_main_bound,
			"motionHeldDuringBarrier":aggregate_motion_held,
			"earlyUnbindAccepted":aggregate_early_unbind,
			"unboundAfterCoordinatorDrain":aggregate_unbound},
		"solidCount":solid_count, "emptyCount":empty_count,
		"publication":published, "physicalReceipt":physical,
		"initialMemory":initial_memory,
		"sameWindowReplacement":same_window_replacement,
		"sameWindowMemory":same_window_memory,
		"coordinatorSetup":coordinator_setup,
		"registered":registered, "missingAggregate":missing_aggregate,
		"aggregate":aggregate,
		"barrierReleaseBeforeActorDeletion":release_before_actor_deletion,
		"barrierReleased":released, "actorContact":contact,
		"activeRetirementRejected":active_retirement,
		"physicalAfterActiveRejection":physical_after_active_rejection,
		"verifiedDistantRetention":{"commit":distant_commit,
			"plan":distant_plan, "verified":verified_distant,
			"negativeProofs":{"incomplete":incomplete_proof_rejected,
				"stale":stale_proof_rejected,
				"foreign":foreign_proof_rejected,
				"relabelledGeometry":relabelled_geometry_rejected,
				"changedArtifactKey":changed_key_rejected},
			"layout":retained_layout, "physical":retained_receipt,
			"aggregate":retained_aggregate, "source":retained_source,
			"actorContactAfterRebind":retained_contact},
		"sourceRevisionReplacement": {"oldIdentity":first_identity,
			"partialReleaseLifecycle":{"secondWindowHold":second_window_hold.get("status"),
				"firstOldHold":first_old_hold.get("status"),
				"firstRebindHold":first_rebind_hold.get("status"),
				"secondWindowClearance":second_window_clearance,
				"partialRelease":partial_barrier_release,
				"firstOldBarrierReleased":first_old_barrier_released,
				"firstOldRecordRemoved":first_old_record_removed,
				"oldOwnerStillLive":owner_live_after_partial_release,
				"secondWindowReleased":second_window_released},
			"oldHold":old_hold.get("status"),
			"committed":committed, "newLayout":replacement_layout,
			"initialReplacementLayout":original_replacement_layout,
			"affectedWindowRebindRejected":affected_window_rebind_rejected,
			"newHold":replacement_hold.get("status"),
			"overlapBarriers":overlap_barriers,
			"deniedBeforeDrain":denied_before_drain,
			"deniedPlacementBefore":denied_placement_before,
			"prematureRelease":premature_replacement_release,
			"stagedCandidate":replacement_staged,
			"cancelledCandidate":{"stage":cancelled_stage,
				"publication":cancelled_candidate_publish,
				"receipt":cancelled_candidate_receipt,
				"layoutDriftNegative":{"evidenceLevel":"synthetic broker-response contract",
					"result":cancellation_drift_negative,
					"candidateTupleRetained":candidate_retained_after_drift_failure},
				"realBrokerLayoutDrift":{"commit":cancellation_drift_commit,
					"layout":cancelled_candidate_layout,
					"candidateTokenRetired":candidate_token_retired_after_drift,
					"brokerRecordPresentBeforeAck":candidate_record_retained_before_ack,
					"physicalDrainReceiptBeforeAck":candidate_drain_before_ack,
					"ackDeferred":cancellation_ack_deferred,
					"leaseRetainedAfterAckDeferred":lease_after_deferred_ack,
					"brokerRecordRetainedAfterAckDeferred": \
						candidate_record_retained_after_deferred_ack,
					"layoutAdvanceAfterAckDeferred":{"commit":ack_retry_commit,
						"layout":ack_retry_layout,
						"candidateStillRetired":candidate_retired_after_ack_layout_advance},
					"cancellation":cancelled_candidate,
					"brokerRecordRemovedAfterAck":candidate_record_removed_after_ack,
					"incumbentStillLive":old_owner_live_after_cancel,
					"incumbentSolidBodyLive":old_solid_body_live_after_cancel},
				"cancel":cancelled_candidate,
				"oldRegistryPreserved":old_registry_after_cancel,
				"oldOwnerStillLive":old_owner_live_after_cancel,
				"memoryAfterCancel":memory_after_candidate_cancel},
			"driftedTicketCommitRejected":drifted_ticket_commit,
			"oldRegistryPreservedAfterTicketDrift":old_registry_after_drift_rejection,
			"staleCommitRejected":stale_stage_commit,
			"oldRegistryUnchangedBeforeSwitch":old_registry_unchanged,
			"oldRegistryUnchangedAfterRejectedCommit":old_registry_after_rejected_commit,
			"oldOwnerLiveThroughCandidateAck":old_owner_live_through_candidate_ack,
			"oldOwnerLiveDebug":old_owner_live_debug,
			"oldOwnerEpochBeforeSwitch":old_epoch_before_switch,
			"candidateReceiptBeforeSwitch":candidate_receipt,
			"atomicSwitch":replacement_switch,
			"displacedOwnerRetainedAfterSwitch":displaced_owner_retained_after_switch,
			"oldOwnerRetired":replaced_old,
			"oldOnlyBarrierSafety":{"oldBounds":old_barrier_bounds,
				"replacementBounds":initial_replacement_barrier_bounds,
				"unionReplacementBounds":replacement_barrier_bounds,
				"initialReplacementCoversOldBounds":initial_replacement_covers_old,
				"actorPosition":old_only_actor_position,
				"secondActorOutsideOldBounds":second_actor_still_outside_old_bounds,
				"secondActorRegistered":second_actor_registered,
				"secondActorMotionDenied":second_actor_motion_denied,
				"oldBarrierClearance":old_only_old_barrier_clearance,
				"replacementBarrierClearance":old_only_replacement_barrier_clearance,
				"incumbentBarrierIdentityDiffersFromOwnerIdentity": \
					incumbent_barrier_identity_differs_from_owner_identity,
				"sameIdRetiredBarrierTokenMatchesIncumbent": \
					same_id_retired_barrier_token_matches_incumbent,
				"retirementDeferred":old_only_retirement,
				"oldOwnerStillLive":old_owner_live_during_old_only_hold,
				"oldSolidBodyStillLive":old_solid_body_live_during_old_only_hold,
				"unionRetirementWithActor":union_retirement_with_actor,
				"oldOwnerStillLiveDuringUnionHold":old_owner_live_during_union_hold},
			"deniedAfterDrain":denied_after_drain,
			"deniedPlacementAfter":denied_placement_after,
			"newSnapshot":replacement_snapshot,
			"newOwnerStaged":replacement_staged,
			"beforeInstall":before_replacement_install,
			"newPublication":replacement_published,
			"newAggregate":replacement_aggregate,
			"newRelease":replacement_release,
			"admittedAfterRelease":admitted_after_replacement,
			"placementAfterRelease":placement_after_replacement,
			"barriersAfterRelease":barriers_after_release},
		"shiftedDemand":shifted, "changedStep":changed_step,
		"changedLayout":changed_layout,
		"oldFacadePending":old_facade_pending,
		"changedAggregate":changed_aggregate,
		"prematureRetirement":premature_retirement,
		"drainReversion":drain_reversion,
		"blockedDuringReversion":blocked_during_reversion,
		"reactivatedLayout":reactivated_layout,
		"reactivatedSnapshot":reactivated_snapshot,
		"reactivatedPublication":reactivated_publish,
		"reactivatedAggregate":reactivated_aggregate,
		"reactivatedRelease":reactivated_release,
		"retirementHold":retirement_hold.get("status"),
		"reactivatedBound":reactivated_bound,
		"reactivatedRegistered":reactivated_registered,
		"reactivatedRowCount":reactivated_rows.size(),
		"reactivatedRequests":reactivated_requests,
		"drained":drained, "retirement":retirement,
		"retiredFacade":retired_facade,
		"coordinatorDrain":coordinator_drain,
		"memoryAdmissionConfigured":memory_configured,
		"preReplacementMemory":pre_replacement_memory,
		"postReplacementMemory":post_replacement_memory,
		"finalMemory":final_memory,
		"brokerStop":broker_stop})

func _finish(passed: bool, evidence: Dictionary) -> void:
	var report := {"schema":"n3-n5-windowed-physical-fixture/v1",
		"passed":passed, "evidenceLevel":"native source and real Godot physics fixture",
		"productionCutover":false, "evidence":evidence}
	var path := OS.get_environment("N3_N5_WINDOWED_PHYSICAL_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	quit(0 if passed else 1)
