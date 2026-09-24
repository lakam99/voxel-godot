extends SceneTree

const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const BROKER = preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")
const OWNER = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const COORDINATOR = preload("res://scripts/terrain/NativeWindowedCollisionCoordinator.gd")
const MEMORY_POLICY = preload("res://scripts/terrain/NativeCollisionMemoryPolicy.gd")
const MEMORY_ADMISSION = preload("res://scripts/terrain/NativeCollisionMemoryAdmission.gd")

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
		"two-window-fixture:%d" % Time.get_ticks_usec())
	return admission if setup.get("status") == "ready" else null

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var main = MAIN.new()
	main.seed_text = "n3-n5-two-window-startup"
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
	var planner_setup: Dictionary = planner.setup(92)
	var surface: float = main.world_generation_system.surface_y_for_cell(Vector3i.ZERO)
	var base_y := floori(float(floori(surface / main.CELL)) / 16.0)
	var far_position := Vector3(main.CELL * 512.0, 0, 0)
	var planned: Dictionary = planner.replace_sources(
		{"position":Vector3.ZERO, "distance":0},
		[{"kind":"secondary", "id":"far-window", "position":far_position,
			"distance":0}], [], [],
		Vector2i(base_y * 16, (base_y + 1) * 16))
	var required: Dictionary = planner.required_collision_mesh_blocks()
	var broker = BROKER.new()
	var broker_setup: Dictionary = broker.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL, 92,
		OWNER.MAX_RESIDENT)
	var requests := []
	for block: Vector3i in required.get("blocks", []):
		requests.append(broker.request_block(block))
	var layout: Dictionary = {}
	var last_advance: Dictionary = {}
	var max_advance_usec := 0
	for frame in range(800):
		var started := Time.get_ticks_usec()
		last_advance = broker.advance()
		max_advance_usec = maxi(max_advance_usec, Time.get_ticks_usec() - started)
		layout = broker.collision_window_layout()
		var all_ready: bool = layout.get("status") == "ready" \
			and layout.get("windowCount") == 2
		if all_ready:
			for window: Dictionary in layout.windows:
				var facade: Dictionary = broker.collision_window_source(window.id,
					layout.layoutToken)
				if facade.get("status") != "ready" \
						or facade.source.collision_source_snapshot().get("status") != "ready":
					all_ready = false
					break
		if all_ready or last_advance.get("status") == "failed": break
		await process_frame
	var root_3d := Node3D.new()
	root.add_child(root_3d)
	var coordinator = COORDINATOR.new()
	root_3d.add_child(coordinator)
	var memory_admission = _new_fixture_memory_admission("n3n5-two-window-fixture")
	var setup: Dictionary = coordinator.setup(broker, root_3d, memory_admission)
	var publications := []
	var rows_by_window := {}
	var owners := {}
	var barriers := {}
	var after_first: Dictionary = {}
	var premature_release: Dictionary = {}
	var solid_count := 0
	var empty_count := 0
	if layout.get("status") == "ready":
		for window: Dictionary in layout.windows:
			var facade_status: Dictionary = broker.collision_window_source(window.id,
				layout.layoutToken)
			var facade = facade_status.get("source")
			var rows: Array[Dictionary] = []
			for block: Vector3i in window.blocks:
				var canonical: Dictionary = facade.collision_artifact_row_snapshot(block,
					layout.identity)
				if canonical.get("status") == "ready": rows.append(canonical.row)
			rows_by_window[window.id] = rows
			var owner = OWNER.new()
			coordinator.add_child(owner)
			owner.bind_source(facade)
			coordinator.register_window(window, owner)
			owners[window.id] = owner
			var bounds: AABB = rows[0].bounds
			for row in rows:
				bounds = bounds.merge(row.bounds)
				if bool(row.expectedHit): solid_count += 1
				else: empty_count += 1
			var held: Dictionary = coordinator.begin_window_barrier(window,
				bounds, layout.identity)
			var barrier: RefCounted = held.barrier
			barriers[window.id] = barrier
			var census: Dictionary = held.census
			while census.get("status") == "pending":
				await process_frame
				census = barrier.census_progress(layout.identity)
			var publication: Dictionary = await owner.publish({
				"schema":"n5-resident-collision-publication/v1",
				"identity":layout.identity, "residentBlocks":window.blocks,
				"affectedBlocks":window.blocks, "rows":rows}, barrier)
			publications.append({"windowId":window.id, "result":publication})
			if publications.size() == 1:
				after_first = coordinator.aggregate_readiness(layout.identity)
				premature_release = coordinator.release_barriers(layout.identity)
	var aggregate: Dictionary = coordinator.aggregate_readiness(
		layout.get("identity", {}))
	var released: Dictionary = coordinator.release_barriers(layout.identity)
	var actor_contact := false
	for rows in rows_by_window.values():
		for row in rows:
			if not bool(row.expectedHit): continue
			var actor := CharacterBody3D.new()
			actor.collision_mask = 2
			actor.position = row.probeFrom
			var shape := CollisionShape3D.new()
			var sphere := SphereShape3D.new()
			sphere.radius = main.CELL * 0.05
			shape.shape = sphere
			actor.add_child(shape)
			root_3d.add_child(actor)
			await physics_frame
			actor_contact = actor.move_and_collide(row.probeTo - row.probeFrom) != null
			actor.queue_free()
			break
		if actor_contact: break
	await process_frame
	var held_window: Dictionary = layout.windows[0]
	var held_rows: Array = rows_by_window[held_window.id]
	var held_bounds: AABB = held_rows[0].bounds
	for row in held_rows:
		held_bounds = held_bounds.merge(row.bounds)
	var stop_hold: Dictionary = coordinator.begin_window_barrier(held_window,
		held_bounds, layout.identity)
	var stop_barrier: RefCounted = stop_hold.get("barrier")
	var stop_census: Dictionary = stop_hold.get("census", {})
	while stop_census.get("status") == "pending":
		await process_frame
		stop_census = stop_barrier.census_progress(layout.identity)
	var guard_actor := CharacterBody3D.new()
	guard_actor.position = held_bounds.position - Vector3(5, 0, 0)
	var guard_shape := CollisionShape3D.new()
	guard_shape.shape = SphereShape3D.new()
	guard_actor.add_child(guard_shape)
	root_3d.add_child(guard_actor)
	var denied_while_held: bool = not coordinator.admit_motion(guard_actor,
		held_bounds.get_center() - guard_actor.position)
	var coordinator_drain: Dictionary = await coordinator.stop_and_drain()
	var released_after_stop: bool = stop_barrier.release(layout.identity)
	var denied_after_stop: bool = not coordinator.admit_motion(guard_actor,
		held_bounds.get_center() - guard_actor.position)
	guard_actor.queue_free()
	var broker_stop: Dictionary = broker.stop()
	for frame in range(100):
		if broker_stop.get("status") == "ready": break
		await process_frame
		broker_stop = broker.drain_step()
	root_3d.queue_free()
	main.free()
	var publications_ready := publications.size() == 2
	for publication in publications:
		publications_ready = publications_ready \
			and publication.result.get("status") == "ready"
	var passed: bool = initialized.get("status") == "ready" \
		and page_setup.get("status") == "ready" \
		and planner_setup.get("status") == "ready" \
		and planned.get("status") == "ready" \
		and broker_setup.get("status") == "ready" \
		and setup.get("status") == "ready" \
		and required.get("blocks", []).size() == 4 \
		and layout.get("status") == "ready" and layout.windowCount == 2 \
		and solid_count >= 1 and empty_count >= 1 \
		and publications_ready \
		and after_first.get("status") == "pending" \
		and premature_release.get("status") == "pending" \
		and aggregate.get("status") == "ready" \
		and released.get("status") == "ready" and actor_contact \
		and stop_hold.get("status") == "ready" and denied_while_held \
		and coordinator_drain.get("status") == "ready" \
		and coordinator_drain.get("remainingChildren") == 0 \
		and coordinator_drain.get("activeBarriers") == 0 \
		and not released_after_stop and denied_after_stop \
		and broker_stop.get("status") == "ready"
	_finish(passed, {"required":required, "layout":layout,
		"maxAdvanceUsec":max_advance_usec, "lastAdvance":last_advance,
		"windowPublications":publications,
		"solidCount":solid_count, "emptyCount":empty_count,
		"afterFirstWindow":after_first,
		"prematureRelease":premature_release,
		"aggregate":aggregate, "released":released,
		"actorContact":actor_contact,
		"stopHold":stop_hold.get("status"),
		"deniedWhileHeld":denied_while_held,
		"releasedAfterStop":released_after_stop,
		"deniedAfterStop":denied_after_stop,
		"coordinatorDrain":coordinator_drain, "brokerStop":broker_stop})

func _finish(passed: bool, evidence: Dictionary) -> void:
	var report := {"schema":"n3-n5-two-window-startup-fixture/v1",
		"passed":passed, "evidenceLevel":"native source and real Godot physics fixture",
		"productionCutover":false, "evidence":evidence}
	var path := OS.get_environment("N3_N5_TWO_WINDOW_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	quit(0 if passed else 1)
