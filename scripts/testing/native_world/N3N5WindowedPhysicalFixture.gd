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
			var canonical: Dictionary = facade.collision_artifact_row(block,
				layout.identity)
			if canonical.get("status") == "ready": rows.append(canonical.row)
	var root_3d := Node3D.new()
	root.add_child(root_3d)
	var coordinator = COORDINATOR.new()
	root_3d.add_child(coordinator)
	var coordinator_setup: Dictionary = coordinator.setup(broker, root_3d)
	var owner = OWNER.new()
	coordinator.add_child(owner)
	var bound: bool = owner.bind_source(facade)
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
	var published: Dictionary = {}
	if bound and rows.size() == window.get("blocks", []).size():
		published = await owner.publish({
			"schema":"n5-resident-collision-publication/v1",
			"identity":layout.identity, "residentBlocks":window.blocks,
			"affectedBlocks":window.blocks, "rows":rows}, barrier)
	var physical: Dictionary = owner.physical_receipt(layout.identity)
	var aggregate: Dictionary = coordinator.aggregate_readiness(layout.identity)
	var released: Dictionary = coordinator.release_barriers(layout.identity)
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
	var crossing_motion: Vector3 = bounds.get_center() - guard_actor.position
	var first_identity: Dictionary = layout.identity.duplicate(true)
	var old_hold: Dictionary = coordinator.begin_window_barrier(window,
		bounds, layout.identity)
	var old_barrier: RefCounted = old_hold.get("barrier")
	var old_census: Dictionary = old_hold.get("census", {})
	while old_census.get("status") == "pending":
		await process_frame
		old_census = old_barrier.census_progress(layout.identity)
	var edit_state := {"materialId":3, "biomeId":13, "fluidId":0,
		"solid":true, "density":1.5, "light":Vector2i.ZERO,
		"metadata":{"saveDelta":true,"source":"terrain_edit"},
		"blockId":"window-revision-edit", "editReason":"contract"}
	var committed: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"windowed-physical:revision-change",
		"expectedRevision":0,
		"operations":[{"kind":"set", "cell":Vector3i(1000,-1,1000),
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
	var replacement_hold: Dictionary = coordinator.begin_window_barrier(
		replacement_window, bounds, replacement_layout.identity)
	var replacement_barrier: RefCounted = replacement_hold.get("barrier")
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
	var replaced_old: Dictionary = await coordinator.retire_window(window.id)
	var denied_after_drain: bool = not coordinator.admit_motion(
		guard_actor, crossing_motion)
	var denied_placement_after: bool = not coordinator.admit_placement(
		guard_actor, Transform3D(Basis.IDENTITY, bounds.get_center()))
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
			var row_status: Dictionary = replacement_facade.collision_artifact_row(
				block, replacement_layout.identity)
			if row_status.get("status") == "ready":
				replacement_rows.append(row_status.row)
	var replacement_owner = OWNER.new()
	coordinator.add_child(replacement_owner)
	var replacement_bound: bool = replacement_owner.bind_source(
		replacement_facade)
	var replacement_registered: Dictionary = coordinator.register_window(
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
	var replacement_aggregate: Dictionary = coordinator.aggregate_readiness(
		replacement_layout.identity)
	var replacement_release: Dictionary = coordinator.release_barriers(
		replacement_layout.identity)
	var admitted_after_replacement: bool = coordinator.admit_motion(
		guard_actor, crossing_motion)
	var placement_after_replacement: bool = coordinator.admit_placement(
		guard_actor, Transform3D(Basis.IDENTITY, bounds.get_center()))
	var barriers_after_release: int = coordinator.active_barrier_count()
	guard_actor.queue_free()
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
	var retirement: Dictionary = await coordinator.retire_window(window.id)
	var drained: Dictionary = retirement.get("drain", {})
	var retired_facade: Dictionary = facade.collision_source_snapshot()
	var coordinator_drain: Dictionary = await coordinator.stop_and_drain()
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
		and registered.get("status") == "ready" \
		and initial_layout.get("status") == "pending" \
		and initial_aggregate.get("status") == "pending" \
		and required.get("blocks", []).size() == 2 \
		and layout.get("status") == "ready" and layout.windowCount == 1 \
		and snapshot.get("status") == "ready" \
		and rows.size() == 2 and solid_count == 1 and empty_count == 1 \
		and published.get("status") == "ready" \
		and missing_aggregate.get("status") == "pending" \
		and aggregate.get("status") == "ready" \
		and released.get("status") == "ready" and contact \
		and old_hold.get("status") == "ready" \
		and committed.get("commitStatus") == "committed" \
		and replacement_layout.get("status") == "ready" \
		and first_identity.sourceRevision == 0 \
		and replacement_layout.identity.sourceRevision == 1 \
		and replacement_layout.identity.cancellationEpoch \
			> first_identity.cancellationEpoch \
		and replacement_hold.get("status") == "ready" \
		and overlap_barriers == 2 \
		and denied_before_drain and denied_after_drain \
		and denied_placement_before and denied_placement_after \
		and premature_replacement_release.get("status") == "pending" \
		and replaced_old.get("status") == "ready" \
		and replaced_old.get("drain", {}).get("remainingBodies") == 0 \
		and replacement_snapshot.get("status") == "ready" \
		and replacement_bound and replacement_registered.get("status") == "ready" \
		and before_replacement_install.get("status") == "pending" \
		and replacement_published.get("status") == "ready" \
		and replacement_aggregate.get("status") == "ready" \
		and replacement_release.get("status") == "ready" \
		and admitted_after_replacement and placement_after_replacement \
		and barriers_after_release == 0 \
		and shifted.get("status") == "ready" \
		and changed_layout.get("status") == "ready" \
		and changed_layout.get("layoutToken") != layout.layoutToken \
		and old_facade_pending.get("status") == "pending" \
		and changed_aggregate.get("status") == "pending" \
		and changed_aggregate.get("reason") \
			== "obsolete_physical_window_retirement_pending" \
		and premature_retirement.get("status") == "failed" \
		and retirement_hold.get("status") == "ready" \
		and drained.get("status") == "ready" \
		and drained.get("windowToken") == old_token \
		and retirement.get("status") == "ready" \
		and retired_facade.get("status") == "failed" \
		and coordinator_drain.get("status") == "ready" \
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
		"solidCount":solid_count, "emptyCount":empty_count,
		"publication":published, "physicalReceipt":physical,
		"coordinatorSetup":coordinator_setup,
		"registered":registered, "missingAggregate":missing_aggregate,
		"aggregate":aggregate,
		"barrierReleased":released, "actorContact":contact,
		"sourceRevisionReplacement": {"oldIdentity":first_identity,
			"oldHold":old_hold.get("status"),
			"committed":committed, "newLayout":replacement_layout,
			"newHold":replacement_hold.get("status"),
			"overlapBarriers":overlap_barriers,
			"deniedBeforeDrain":denied_before_drain,
			"deniedPlacementBefore":denied_placement_before,
			"prematureRelease":premature_replacement_release,
			"oldOwnerRetired":replaced_old,
			"deniedAfterDrain":denied_after_drain,
			"deniedPlacementAfter":denied_placement_after,
			"newSnapshot":replacement_snapshot,
			"newOwnerRegistered":replacement_registered,
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
		"drained":drained, "retirement":retirement,
		"retiredFacade":retired_facade,
		"coordinatorDrain":coordinator_drain,
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
