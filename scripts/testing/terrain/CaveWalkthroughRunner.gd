extends SceneTree

const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const COLLISION_GROUND_ALIGNMENT_TOLERANCE := 1.35 * 0.08

# Fixture placement occurs once, before the act phase. Thereafter only ordinary
# PlayerController movement input is issued; collision/readiness remain live.
var main
var player
var runtime
var recipe: Dictionary
var output := "res://artifacts/caves/walkthrough/"
var diagnostic := false
var trace: Array = []
var captures: Array = []
var capture_publication: Array[Dictionary] = []
var capture_expected_count := 0
var arrivals: Array = []
var view_audits: Array = []
var view_audit_summaries: Array[Dictionary] = []
var cave_dig_evidence: Dictionary = {}
var failures: Array = []
var optional_walk_failures: Array[Dictionary] = []
var pre_act_support: Dictionary = {}
var frame_times: Array = []
var ready := false
var startup_failure := ""
var diagnostic_streaming_owners_reenabled := false
var act_start := 0
var last_tick := 0
var sample_tick := 0
var seed_value := "cave-master-20260903"
var explicit_seed_override := false
var cave_region := Vector2i(0, -2)
var record_active := false
var record_busy := false
var last_record_ms := 0
var recorded_frames: Array = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	diagnostic = OS.get_environment("CAVE_DIAGNOSTIC") == "1"
	if diagnostic:
		output = "res://artifacts/caves/diagnostic/"
	if not OS.get_environment("CAVE_OUTPUT").is_empty():
		output = OS.get_environment("CAVE_OUTPUT")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	OS.set_environment("VOXEL_SAVE_PATH_OVERRIDE", ProjectSettings.globalize_path(output + "fixture-save.json"))
	if not OS.get_environment("CAVE_SEED").is_empty():
		seed_value = OS.get_environment("CAVE_SEED")
		explicit_seed_override = true
	if not OS.get_environment("CAVE_REGION_X").is_empty():
		cave_region.x = int(OS.get_environment("CAVE_REGION_X"))
	if not OS.get_environment("CAVE_REGION_Z").is_empty():
		cave_region.y = int(OS.get_environment("CAVE_REGION_Z"))
	OS.set_environment("VOXEL_TEST_SEED", seed_value if diagnostic or explicit_seed_override else "")
	root.size = Vector2i(1280, 720)
	root.title = "Cave Walkthrough"
	if diagnostic:
		OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "1")
		main = load("res://scenes/Main.tscn").instantiate()
		# Match the established focused underground visual fixture: keep the
		# diagnostic render neighborhood small and request fine cave-volume detail
		# before Main starts admitting broad surface streaming work.
		main.set("render_distance", 2)
		main.set("force_underground_volume_debug", true)
		main.set("force_underground_volume_fine_focus", true)
		root.add_child(main)
		await create_timer(2.0).timeout
	else:
		var menu = load("res://scenes/MainMenu.tscn").instantiate()
		root.add_child(menu)
		for _frame in range(8):
			await process_frame
		await capture("00-main-menu")
		var button: Button = menu.new_game_button
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = pressed
			event.position = button.get_global_rect().get_center()
			event.global_position = event.position
			root.push_input(event)
		var deadline := Time.get_ticks_msec() + 240000
		while not ready and startup_failure.is_empty() and Time.get_ticks_msec() < deadline:
			await process_frame
			if main == null and menu.active_main != null:
				main = menu.active_main
				main.startup_loading_completed.connect(func(): ready = true)
				main.startup_loading_failed.connect(func(message): startup_failure = message)
		if not ready:
			failures.append("normal_boot_failed:" + startup_failure)
			await finish()
			return
		await capture("01-normal-gameplay")
	player = main.player
	print("CAVE WALK: actual seed=", main.seed_text)
	runtime = main.voxel_terrain_runtime
	var requested_region := cave_region
	recipe = main.world_generation_system.cave_recipe_for_region(cave_region)
	if recipe.is_empty():
		for radius in range(1, 4):
			for rz in range(-radius, radius + 1):
				for rx in range(-radius, radius + 1):
					if recipe.is_empty() and maxi(absi(rx), absi(rz)) == radius:
						var candidate := requested_region + Vector2i(rx, rz)
						recipe = main.world_generation_system.cave_recipe_for_region(candidate)
						if not recipe.is_empty():
							cave_region = candidate
	if recipe.is_empty():
		failures.append("no_recipe")
		await finish()
		return
	player.set_physics_process(false)
	var outside: Vector3 = recipe.entry + recipe.outward * 4.0
	outside.y = main.world_generation_system.terrain_reference_surface_y_at(outside) + 0.3
	player.global_position = outside
	player.velocity = Vector3.ZERO
	player.automated_input = true
	player.automated_move = Vector3.ZERO
	player.automated_sprint = false
	main.inventory_system.add_item("torch", 1)
	for slot in range(main.inventory_system.slots.size()):
		if String(main.inventory_system.slots[slot].get("item", "")) == "torch":
			main.inventory_system.select(0)
			main.inventory_system.swap_with_active(slot)
			break
	main.held_item.refresh_active()
	main.time_of_day = fposmod(14.0 / 24.0 - 0.25, 1.0)
	main.weather_system.force_weather("clear", 0.0, 0.18, Vector3.ZERO)
	main.update_sky(0.0)
	main.ensure_voxel_terrain_authority()
	runtime = main.voxel_terrain_runtime
	if OS.get_environment("CAVE_CAPTURE_ONLY") == "1" and runtime != null \
			and runtime.has_method("full_vertical_cell_bounds") \
			and runtime.has_method("apply_vertical_cell_bounds"):
		# Fast boot bypasses the normal vertical-bound expansion gate. A deep
		# camera preview must include the same configured vertical world range or
		# it renders absent terrain as sky/void.
		var vertical_bounds: Vector2i = runtime.full_vertical_cell_bounds()
		runtime.apply_vertical_cell_bounds(vertical_bounds.x, vertical_bounds.y)
	if diagnostic:
		# Fast boot intentionally freezes Main's streaming scheduler. Resume its
		# ordinary chunk admission now that the fixture is staged, but keep the
		# diagnostic local: the full view-distance expansion is unrelated to the
		# cave route and would turn this into a broad world-loading run.
		main.set_process(true)
		main.set_process_unhandled_input(true)
		main.set_physics_process(true)
		diagnostic_streaming_owners_reenabled = true
	else:
		runtime.request_final_view_distance_expansion()
	look_toward(recipe.route[2])
	print("CAVE WALK: staged outside ", outside)
	var quiet := 0
	var requested_fixture_chunks := {}
	var fixture_collision_proof: Dictionary = {}
	for frame in range(7200):
		await process_frame
		fixture_collision_proof = runtime.collision_proof_for_motion(outside, outside, 0.42)
		if not bool(fixture_collision_proof.get("passed", false)) \
				and String(fixture_collision_proof.get("reason", "")) == "collision_chunk_publication_pending":
			var missing_chunk: Vector2i = fixture_collision_proof.get("missingChunk", Vector2i.ZERO)
			if not requested_fixture_chunks.has(missing_chunk):
				requested_fixture_chunks[missing_chunk] = true
				main.create_chunk(missing_chunk.x, missing_chunk.y, true)
		# Normal New Game continues publishing unrelated view-distance chunks.
		# Gate the act phase on the exact entrance collision proof above, not on
		# the entire world's streaming queue becoming idle.
		if bool(fixture_collision_proof.get("passed", false)):
			quiet += 1
		else:
			quiet = 0
		if quiet >= 45 and bool(fixture_collision_proof.get("passed", false)):
			break
		if frame % 600 == 0:
			print("CAVE WALK: loading blocks=", runtime.published_mesh_blocks.size(), " tasks=", runtime.voxel_engine_pending_task_count(), " collision=", fixture_collision_proof)
	if quiet < 45 or not bool(fixture_collision_proof.get("passed", false)):
		failures.append("terrain_publication_timeout:%s" % JSON.stringify({
			"quietFrames": quiet,
			"collisionProof": fixture_collision_proof,
			"requestedFixtureChunks": requested_fixture_chunks.keys(),
			"publication": runtime.gameplay_publication_diagnostics(requested_fixture_chunks.keys())
		}))
		await finish()
		return
	# Startup publication may take longer than an in-game daylight window. Restore
	# the walkthrough's controlled ordinary sky/weather immediately before the
	# visual act phase so capture lighting is deterministic.
	main.time_of_day = fposmod(14.0 / 24.0 - 0.25, 1.0)
	main.weather_system.force_weather("clear", 0.0, 0.18, Vector3.ZERO)
	main.update_sky(0.0)
	act_start = Time.get_ticks_msec()
	last_tick = Time.get_ticks_usec()
	main.runtime_perf_monitor.reset()
	if OS.get_environment("CAVE_RECORD") == "1":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output + "frames/"))
		record_active = true
		process_frame.connect(record_if_due)
	if OS.get_environment("CAVE_CAPTURE_ONLY") == "1":
		# Visual recapture mode: these are real runtime renders at fixture camera
		# positions, not evidence of traversal or collision readiness.
		var views: Array[Dictionary] = [
			{"label": "capture-exterior-entrance", "position": outside, "look": recipe.route[2]},
			{"label": "capture-interior-main-chamber", "position": recipe.route[6], "look": recipe.route[5]},
			{"label": "capture-interior-ceiling", "position": recipe.route[6], "look": recipe.route[6] + Vector3.UP * 4.0},
			{"label": "capture-interior-branch", "position": recipe.loop[2], "look": recipe.loop[1]},
			{"label": "05-branch-pan-left", "position": recipe.loop[2], "look": recipe.loop[1] + Vector3(-recipe.outward.z, 0.0, recipe.outward.x) * 4.0},
			{"label": "05-branch-pan-right", "position": recipe.loop[2], "look": recipe.loop[1] - Vector3(-recipe.outward.z, 0.0, recipe.outward.x) * 4.0}
		]
		for tier in range(recipe.depthLoops.size()):
			var tier_loop: Array = recipe.depthLoops[tier]
			var trunk_index := mini(4 + 2 * tier, recipe.deepRoute.size() - 1)
			views.append({"label": "diagnostic-depth-tier-%02d" % tier,
				"position": tier_loop[2], "look": recipe.deepRoute[trunk_index]})
		for link in recipe.depthTierLinks:
			var link_points: Array = link.points
			var from_tier := int(link.fromTier)
			var to_tier := int(link.toTier)
			# Capture the generated connector from both approaches. A single
			# midpoint view tends to frame only a dark opening and hides the
			# connector's direction and change in elevation.
			for direction_index in range(2):
				var sample_index := 3 if direction_index == 0 else link_points.size() - 4
				var next_index := sample_index + 1 if direction_index == 0 else sample_index - 1
				var view_from_tier := from_tier if direction_index == 0 else to_tier
				var view_to_tier := to_tier if direction_index == 0 else from_tier
				views.append({"label": "diagnostic-tier-link-%d-%d-from-%d" % [from_tier, to_tier, view_from_tier],
					"position": link_points[sample_index], "look": link_points[next_index],
					"fromTier": view_from_tier, "toTier": view_to_tier})
		capture_expected_count = views.size()
		for view in views:
			var view_position: Vector3 = view.position
			view_position.y += 0.15
			player.global_position = view_position
			player.velocity = Vector3.ZERO
			look_toward(view.look)
			record_active = false
			var publication: Dictionary = await wait_for_capture_terrain(view_position, String(view.label))
			capture_publication.append(publication)
			if not bool(publication.get("passed", false)):
				failures.append("capture_terrain_not_published:%s:%s" % [String(view.label), publication.get("reason", "unknown")])
				await finish()
				return
			record_active = OS.get_environment("CAVE_RECORD") == "1"
			await capture(String(view.label))
			if String(view.label).begins_with("diagnostic-tier-link-"):
				# Match visible connector openings against generated density and
				# published SDF/collision, especially when a distant opening looks
				# like sky. This is diagnostic evidence, not a traversal gate.
				view_audit_summaries.append(await audit_view_rays(String(view.label)))
			for _frame in range(18):
				await process_frame
			record_active = false
		await finish()
		return
	player.set_physics_process(true)
	# Fixture placement happens before the act phase. Align the actor to the
	# published terrain collider rather than the heightfield reference; entrance
	# carving can move the actual floor away from that reference. Then require a
	# real CharacterBody floor contact before issuing movement input.
	# Mesh collision and the terrain-ground provider are distinct contracts. Pick
	# the nearest point in a small, bounded area where they agree within the same
	# strict support tolerance used by the act-phase assertions. This is fixture
	# setup only; movement still begins outside the mouth and follows live input.
	var start_hit := {}
	var support_alignment_probe := {}
	var selected_outside := false
	var alignment_tolerance := COLLISION_GROUND_ALIGNMENT_TOLERANCE
	for ring in range(0, 5):
		if selected_outside:
			break
		for offset_x in range(-ring, ring + 1):
			if selected_outside:
				break
			for offset_z in range(-ring, ring + 1):
				if maxi(absi(offset_x), absi(offset_z)) != ring:
					continue
				var candidate_outside := outside + Vector3(float(offset_x) * 0.5, 0.0, float(offset_z) * 0.5)
				var candidate_hit := terrain_floor_hit(candidate_outside)
				if candidate_hit.is_empty():
					continue
				var provider_y := float(main.ground_y_near_position(candidate_outside))
				var alignment_error := absf(provider_y - float(candidate_hit.position.y))
				support_alignment_probe = {"candidate": vec(candidate_outside), "collisionY": candidate_hit.position.y,
					"providerY": provider_y, "alignmentError": alignment_error, "tolerance": alignment_tolerance}
				if alignment_error <= alignment_tolerance:
					outside = candidate_outside
					start_hit = candidate_hit
					selected_outside = true
					break
	if not selected_outside:
		failures.append("exterior_fixture_no_collision_aligned_surface:%s" % JSON.stringify(support_alignment_probe))
		await finish()
		return
	# Place the capsule just above the measured collider surface. A larger drop
	# offset can leave the custom terrain-grounded path hovering beyond the
	# runner's strict support-alignment tolerance before the act phase.
	outside.y = float(start_hit.position.y) + 0.05
	player.global_position = outside
	player.velocity = Vector3.ZERO
	player.terrain_grounded = false
	player.jump_snap_time = 0.0
	player.automated_move = Vector3.ZERO
	player.automated_sprint = false
	player.automated_jump = false
	for _frame in range(120):
		await physics_frame
		pre_act_support = collision_support()
		if bool(pre_act_support.get("supported", false)):
			break
	if not bool(pre_act_support.get("supported", false)):
		pre_act_support["supportAlignmentProbe"] = support_alignment_probe
		pre_act_support["playerPosition"] = vec(player.global_position)
		pre_act_support["velocity"] = vec(player.velocity)
		pre_act_support["terrainGrounded"] = player.terrain_grounded
		pre_act_support["collisionHold"] = player.get_meta("terrain_collision_hold", false)
		pre_act_support["collisionHoldReason"] = player.get_meta("terrain_collision_hold_reason", "")
		pre_act_support["lastMotionProof"] = player.last_terrain_collision_proof.duplicate(true)
		failures.append("exterior_fixture_not_grounded:%s" % JSON.stringify(pre_act_support))
		await finish()
		return
	await capture("02-exterior-entrance")
	var exterior_audit: Dictionary = await audit_view_rays("exterior-entrance", true)
	view_audit_summaries.append(exterior_audit)
	if not bool(exterior_audit.get("passed", false)):
		await finish()
		return
	var approach: Vector3 = recipe.entry + recipe.outward * 3.0
	approach.y = main.world_generation_system.terrain_reference_surface_y_at(approach)
	if not await walk_to(approach, "surface-approach"):
		await finish()
		return
	var route: Array = recipe.route
	for index in range(route.size()):
		if not await walk_to(route[index], "inbound-%d" % index):
			await finish()
			return
		if index == 2:
			var cave_support := collision_support()
			var cave_head: Dictionary = main.world_generation_system.sample_world(player.global_position + Vector3.UP * 1.0)
			if not bool(cave_support.get("supported", false)):
				failures.append("cave_route_not_grounded:%s" % JSON.stringify(cave_support))
			if bool(cave_head.get("solid", true)) or String(cave_head.get("biome", "")) != "underground_air":
				failures.append("cave_route_not_generated_air:%s" % JSON.stringify(cave_head))
			if not failures.is_empty():
				await finish()
				return
		if index in [1, 2, 3, 6]:
			look_toward(recipe.deepRoute[1] if index == 6 else route[mini(index + 2, 6)])
			await capture("03-inbound-%d" % index)
			if index == 3:
				view_audit_summaries.append(await audit_view_rays("inbound-%d" % index))
	player.pitch = 0.55
	player.camera.rotation.x = 0.55
	await capture("04-chamber-ceiling")
	look_toward(recipe.loop[2])
	await capture("04-chamber-junction")
	var loop: Array = recipe.loop
	for index in range(loop.size() - 2, -1, -1):
		if not await walk_to(loop[index], "branch-%d" % index):
			await finish()
			return
		look_toward(loop[index - 1] if index > 0 else route[2])
		await capture("05-branch-%d" % index)
	# The generated recipe contains a distinct deep trunk and a chamber loop at
	# every tier. Walk these with live input and real terrain support; the older
	# walkthrough only covered the shallow entrance loop and could not establish
	# that the advertised multi-level maze was actually traversable.
	var deep_route: Array = recipe.deepRoute
	var depth_loops: Array = recipe.depthLoops
	for index in range(1, deep_route.size()):
		if not await walk_to(deep_route[index], "depth-descent-%d" % index):
			await finish()
			return
		look_toward(deep_route[mini(index + 1, deep_route.size() - 1)])
		await capture("depth-trunk-%02d" % index)
		for tier in range(depth_loops.size()):
			var tier_anchor_index := 4 + 2 * tier
			if tier_anchor_index != index:
				continue
			var tier_loop: Array = depth_loops[tier]
			for loop_index in range(1, tier_loop.size()):
				if not await walk_to(tier_loop[loop_index], "depth-tier-%d-loop-%d" % [tier, loop_index]):
					await finish()
					return
			if not await walk_to(tier_loop[0], "depth-tier-%d-return-to-trunk" % tier):
				await finish()
				return
			look_toward(deep_route[mini(index + 1, deep_route.size() - 1)])
			await capture("depth-tier-%02d" % tier)
	# Traverse each authored cross-tier bypass in both directions while ascending
	# its source tier. The loop perimeter connects the trunk anchor to the portal;
	# reversing the real path verifies the same connection is physically usable.
	for index in range(deep_route.size() - 2, -1, -1):
		if not await walk_to(deep_route[index], "depth-ascent-%d" % index):
			await finish()
			return
		for link in recipe.depthTierLinks:
			var from_tier := int(link.fromTier)
			if 4 + 2 * from_tier != index:
				continue
			var link_points: Array = link.points
			var from_loop: Array = depth_loops[from_tier]
			if not await walk_to(from_loop[1], "tier-link-%d-%d-source-entrance" % [from_tier, int(link.toTier)]) \
					or not await walk_to(from_loop[2], "tier-link-%d-%d-source-corner" % [from_tier, int(link.toTier)]) \
					or not await walk_to(link_points[0], "tier-link-%d-%d-source-portal" % [from_tier, int(link.toTier)]):
				await finish()
				return
			for point_index in range(1, link_points.size()):
				if not await walk_to(link_points[point_index], "tier-link-%d-%d-down-%d" % [from_tier, int(link.toTier), point_index]):
					await finish()
					return
			look_toward(deep_route[4 + 2 * int(link.toTier)])
			await capture("tier-link-%d-%d" % [from_tier, int(link.toTier)])
			for point_index in range(link_points.size() - 2, -1, -1):
				if not await walk_to(link_points[point_index], "tier-link-%d-%d-up-%d" % [from_tier, int(link.toTier), point_index]):
					await finish()
					return
			if not await walk_to(from_loop[3], "tier-link-%d-%d-source-return-corner" % [from_tier, int(link.toTier)]) \
					or not await walk_to(from_loop[4], "tier-link-%d-%d-source-return-entrance" % [from_tier, int(link.toTier)]) \
					or not await walk_to(from_loop[0], "tier-link-%d-%d-source-return-trunk" % [from_tier, int(link.toTier)]):
				await finish()
				return
	# Revisit the chamber by ordinary movement and exercise the game's production
	# destroy_target -> queued excavation -> terrain-volume edit path in-place.
	if not await walk_to(route[6], "cave-digging-position"):
		await finish()
		return
	cave_dig_evidence = await dig_cave_wall()
	if not bool(cave_dig_evidence.get("passed", false)):
		failures.append("live_cave_dig_failed:%s" % JSON.stringify(cave_dig_evidence))
	# Retrace the generated route in reverse rather than cutting diagonally across
	# the chamber and cave walls. The player is at route[6] after the digging act.
	for index in range(5, -1, -1):
		if not await walk_to(route[index], "outbound-%d" % index):
			await finish()
			return
		if index == 1:
			look_toward(outside)
			await capture("06-looking-out")
	if await walk_to(outside, "returned-outside", true):
		look_toward(route[2])
		await capture("07-returned-exterior")
	await finish()

func walk_to(target: Vector3, phase: String, sprint := false, optional := false) -> bool:
	var deadline := Time.get_ticks_msec() + 16000
	var sidestep_target := Vector3.INF
	var previous_position: Vector3 = player.global_position
	var stalled_ticks := 0
	var unsupported_arrival_ticks := 0
	print("CAVE WALK: ", phase, " target=", target)
	while Time.get_ticks_msec() < deadline:
		var offset: Vector3 = target - player.global_position
		offset.y = 0.0
		if offset.length() <= 1.0 and absf(player.global_position.y - target.y) <= 2.2:
			player.automated_move = Vector3.ZERO
			await physics_frame
			var support := collision_support()
			if bool(support.get("supported", false)):
				arrivals.append({"phase": phase, "position": vec(player.global_position), "target": vec(target), "support": support})
				return true
			unsupported_arrival_ticks += 1
			if unsupported_arrival_ticks >= 60:
				var reason := "waypoint_not_grounded:%s:%s" % [phase, JSON.stringify(support)]
				if optional:
					optional_walk_failures.append({"phase": phase, "reason": reason, "support": support})
				else:
					failures.append(reason)
				await capture("failed-unsupported-" + phase)
				return false
			continue
		look_toward(target)
		var wish := offset.normalized()
		# A player can sidestep a natural rock. Use actual obstruction rays and
		# ordinary input, never move a prop or overwrite the player's transform.
		if sidestep_target != Vector3.INF:
			var side_offset: Vector3 = sidestep_target - player.global_position
			side_offset.y = 0.0
			if side_offset.length() < 0.35:
				sidestep_target = Vector3.INF
			else:
				wish = side_offset.normalized()
		else:
			var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
			var eye: Vector3 = player.global_position + Vector3.UP * 0.8
			var query := PhysicsRayQueryParameters3D.create(eye, eye + wish * 1.8, 3, [player.get_rid()])
			var hit := space.intersect_ray(query)
			if not hit.is_empty() and not runtime.voxel_terrain_collider(hit.collider):
				for sign_value in [1.0, -1.0]:
					var side: Vector3 = Vector3(-wish.z, 0.0, wish.x) * sign_value
					var side_query := PhysicsRayQueryParameters3D.create(eye, eye + side * 2.0, 3, [player.get_rid()])
					if space.intersect_ray(side_query).is_empty():
						sidestep_target = player.global_position + side * 1.8
						wish = side
						print("CAVE WALK: sidestep natural obstruction ", hit.collider)
						break
		player.automated_move = wish
		player.automated_sprint = sprint
		if player.global_position.distance_to(previous_position) < 0.012:
			stalled_ticks += 1
		else:
			stalled_ticks = 0
		previous_position = player.global_position
		if stalled_ticks >= 90 and player.is_on_floor():
			player.automated_jump = true
			stalled_ticks = 0
			print("CAVE WALK: ordinary jump input at obstruction")
		await physics_frame
		var now := Time.get_ticks_usec()
		frame_times.append(float(now - last_tick) / 1000.0)
		last_tick = now
		sample_tick += 1
		if sample_tick % 6 == 0:
			trace.append({"elapsedMs": Time.get_ticks_msec() - act_start, "phase": phase, "position": vec(player.global_position), "wish": vec(player.automated_move), "velocity": vec(player.velocity), "onFloor": player.is_on_floor(), "support": collision_support(), "jumpRequested": player.automated_jump, "collisionHold": player.get_meta("terrain_collision_hold", false), "collisionReason": player.get_meta("terrain_collision_hold_reason", ""), "chunk": str(Vector3i((player.global_position / (16.0 * 1.35)).floor()))})
	player.automated_move = Vector3.ZERO
	if optional:
		optional_walk_failures.append({"phase": phase, "reason": "walk_timeout"})
	else:
		failures.append("walk_timeout:" + phase)
	for index in range(player.get_slide_collision_count()):
		var collision: KinematicCollision3D = player.get_slide_collision(index)
		print("CAVE WALK: blocked collider=", collision.get_collider(), " normal=", collision.get_normal(), " point=", collision.get_position())
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	for height in [0.2, 0.8, 1.6]:
		var origin: Vector3 = player.global_position + Vector3.UP * height
		var direction: Vector3 = target - player.global_position
		direction.y = 0.0
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction.normalized() * 3.0, 3, [player.get_rid()])
		print("CAVE WALK: obstruction ray ", height, " ", space.intersect_ray(query))
	await capture("failed-" + phase)
	return false

func look_toward(target: Vector3) -> void:
	var direction: Vector3 = target - player.global_position
	player.rotation.y = atan2(-direction.x, -direction.z)
	player.pitch = -0.06
	player.camera.rotation.x = -0.06

func collision_support() -> Dictionary:
	var feet: Vector3 = player.global_position
	var query := PhysicsRayQueryParameters3D.create(feet + Vector3.UP * 0.5, feet - Vector3.UP * 4.0, 3, [player.get_rid()])
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"supported": false}
	var gap: float = feet.y - hit.position.y
	var provided: float = main.ground_y_near_position(feet)
	var body_floor_contact: bool = bool(player.is_on_floor())
	var controller_grounded: bool = bool(player.terrain_grounded)
	var within_mesh_alignment: bool = gap >= -0.03 and gap <= COLLISION_GROUND_ALIGNMENT_TOLERANCE
	# A vertical ray under the capsule origin is not the physical contact point on
	# a slope: the capsule can be firmly grounded while that ray is lower along
	# the slope by more than the small cell-alignment tolerance. Prefer Godot's
	# actual CharacterBody floor contact/normal; use ray alignment only for the
	# terrain-grounded fallback when the physics body has no floor contact.
	var capsule_floor_normal: Vector3 = player.get_floor_normal()
	var body_contact_walkable := capsule_floor_normal.y >= cos(deg_to_rad(46.0))
	var ray_normal_walkable: bool = hit.normal.y >= cos(deg_to_rad(46.0))
	var grounded_support := body_floor_contact and body_contact_walkable
	var controller_support: bool = not body_floor_contact and controller_grounded and within_mesh_alignment and ray_normal_walkable
	return {"supported": runtime.voxel_terrain_collider(hit.collider) and (grounded_support or controller_support), "gap": gap, "alignmentTolerance": COLLISION_GROUND_ALIGNMENT_TOLERANCE, "rayAlignmentWithinTolerance": within_mesh_alignment, "height": hit.position.y, "normal": vec(hit.normal), "capsuleFloorNormal": vec(capsule_floor_normal), "bodyFloorContact": body_floor_contact, "controllerGrounded": controller_grounded, "collider": str(hit.collider), "terrain": runtime.voxel_terrain_collider(hit.collider), "providerDelta": provided - hit.position.y}

func terrain_floor_hit(position: Vector3) -> Dictionary:
	var origin := position + Vector3.UP * 2.0
	var query := PhysicsRayQueryParameters3D.create(origin, origin - Vector3.UP * 96.0, 2, [player.get_rid()])
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not runtime.voxel_terrain_collider(hit.collider):
		return {}
	return hit

func dig_cave_wall() -> Dictionary:
	var inventory = main.inventory_system
	if inventory == null or player == null or not main.has_method("destroy_target"):
		return {"passed": false, "reason": "gameplay_dig_dependencies_missing"}
	var torch_slot := -1
	var pick_slot := -1
	for slot_index in range(inventory.slots.size()):
		var item_id := String(inventory.slots[slot_index].get("item", ""))
		if item_id == "torch":
			torch_slot = slot_index
			break
	if torch_slot < 0:
		return {"passed": false, "reason": "torch_not_equipped_before_dig"}
	var equipped_slot := int(inventory.selected_slot)
	if equipped_slot != torch_slot:
		return {"passed": false, "reason": "torch_not_active_at_cave_dig_start", "torchSlot": torch_slot, "selectedSlot": equipped_slot}
	if inventory.add_item("ironPickaxe", 1) <= 0:
		return {"passed": false, "reason": "could_not_stage_pickaxe"}
	for slot_index in range(inventory.slots.size()):
		if String(inventory.slots[slot_index].get("item", "")) == "ironPickaxe":
			pick_slot = slot_index
			break
	if pick_slot < 0:
		return {"passed": false, "reason": "pickaxe_slot_missing"}
	var directions: Array[Vector3] = []
	for index in range(24):
		var angle := TAU * float(index) / 24.0
		directions.append(Vector3(sin(angle), 0.0, -cos(angle)))
	var chosen_hit: Dictionary = {}
	var chosen_target: Dictionary = {}
	var ray_probe_summary: Array[Dictionary] = []
	for direction in directions:
		look_toward(player.global_position + direction * 5.0)
		await process_frame
		var hit: Dictionary = player.view_ray(18.0)
		if hit.is_empty():
			ray_probe_summary.append({"direction": vec(direction), "hit": false})
			continue
		var collider := hit.get("collider") as Node
		var kind := String(collider.get_meta("kind", "")) if collider != null else ""
		var probe: Dictionary = {"direction": vec(direction), "hit": true, "kind": kind, "terrain": collider != null and runtime.voxel_terrain_collider(collider), "position": vec(hit.get("position", Vector3.ZERO)), "distance": player.camera.global_position.distance_to(hit.get("position", player.camera.global_position))}
		if collider == null or not runtime.voxel_terrain_collider(collider):
			ray_probe_summary.append(probe)
			continue
		var target: Dictionary = main.break_target_for_hit(hit, collider, kind)
		var cell_value = target.get("cell3", Vector3i.ZERO)
		if not (cell_value is Vector3i):
			ray_probe_summary.append(probe)
			continue
		var cell: Vector3i = cell_value
		var source_state: Dictionary = main.world_generation_system.get_cell_state(cell)
		var material_id := String(target.get("material", ""))
		probe["material"] = material_id
		probe["cell"] = [cell.x, cell.y, cell.z]
		probe["solid"] = bool(source_state.get("solid", false))
		ray_probe_summary.append(probe)
		if not bool(source_state.get("solid", false)) or material_id not in ["stone", "deepStone"]:
			continue
		var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
		var flat_direction: Vector3 = hit_position - player.global_position
		flat_direction.y = 0.0
		var horizontal_distance: float = flat_direction.length()
		probe["horizontalDistance"] = horizontal_distance
		if horizontal_distance > 2.0:
			if flat_direction.length_squared() > 0.001:
				var approach_target: Vector3 = player.global_position + flat_direction.normalized() * maxf(0.0, horizontal_distance - 1.9)
				approach_target.y = player.global_position.y
				if not await walk_to(approach_target, "cave-dig-approach", true, true):
					continue
				look_toward(hit_position)
				await process_frame
				hit = player.view_ray(3.9)
				if hit.is_empty():
					continue
				collider = hit.get("collider") as Node
				if collider == null or not runtime.voxel_terrain_collider(collider):
					continue
				kind = String(collider.get_meta("kind", ""))
				target = main.break_target_for_hit(hit, collider, kind)
				if target.get("cell3", Vector3i.ZERO) != cell:
					continue
		if not main.hit_within_action_reach(hit):
			ray_probe_summary.append({"direction": vec(direction), "hit": true, "reason": "outside_gameplay_action_reach", "position": vec(hit.get("position", Vector3.ZERO))})
			continue
		chosen_hit = hit
		chosen_target = target
		chosen_target["sourceState"] = source_state.duplicate(true)
		break
	if chosen_hit.is_empty():
		return {"passed": false, "reason": "no_reachable_generated_stone_wall", "player": vec(player.global_position), "rayProbes": ray_probe_summary}
	var cell: Vector3i = chosen_target.cell3
	var material_id := String(chosen_target.material)
	var pre_dig_view_hit: Dictionary = player.view_ray(3.9)
	await capture("05-cave-wall-before-dig")
	# Keep the torch lit for the baseline image; swap only for the strikes.
	inventory.select(equipped_slot)
	inventory.swap_with_active(pick_slot)
	main.held_item.refresh_active()
	var drop_id := "stones"
	var inventory_before := int(inventory.count(drop_id))
	var strike_records: Array[Dictionary] = []
	var max_strikes := ItemCatalogScript.material_hardness(material_id) + 3
	for strike_index in range(max_strikes):
		var hit: Dictionary = player.view_ray(3.9)
		var collider := hit.get("collider") as Node if not hit.is_empty() else null
		if hit.is_empty() or collider == null or not runtime.voxel_terrain_collider(collider):
			break
		var current_target: Dictionary = main.break_target_for_hit(hit, collider, String(collider.get_meta("kind", "")))
		if current_target.get("cell3", Vector3i.ZERO) != cell:
			look_toward(player.global_position + (chosen_hit.position - player.global_position).normalized() * 5.0)
			await process_frame
			continue
		main.destroy_target()
		strike_records.append({"strike": strike_index + 1, "target": current_target.duplicate(true)})
		for _frame in range(4):
			await process_frame
			await physics_frame
			main.process_world_edit_followups()
		var after_state: Dictionary = main.world_generation_system.get_cell_state(cell)
		if bool(after_state.get("edited", false)) and not bool(after_state.get("solid", true)):
			break
	var pending_stats: Dictionary = {}
	for _frame in range(240):
		await process_frame
		await physics_frame
		pending_stats = main.world_edit_followup_stats()
		if int(pending_stats.get("pendingEdits", 0)) == 0 and int(pending_stats.get("pendingRewards", 0)) == 0:
			break
		main.process_world_edit_followups()
	var edited_state: Dictionary = main.world_generation_system.get_cell_state(cell)
	var deltas: Dictionary = main.world_generation_system.save_terrain_volume_deltas()
	var drop_count := int(inventory.count(drop_id))
	var delta_json := JSON.stringify(deltas)
	var saved_cell_signature := "\"cell\":[%d,%d,%d]" % [cell.x, cell.y, cell.z]
	var result := {
		"passed": bool(edited_state.get("edited", false)) and not bool(edited_state.get("solid", true)) and drop_count > inventory_before and delta_json.contains(saved_cell_signature),
		"cell": [cell.x, cell.y, cell.z],
		"material": material_id,
		"sourceState": chosen_target.sourceState,
		"editedState": edited_state,
		"saveDeltaContainsCell": delta_json.contains(saved_cell_signature),
		"drop": drop_id,
		"dropBefore": inventory_before,
		"dropAfter": drop_count,
		"activeItemDuringDig": String(inventory.active_stack().get("item", "")),
		"strikes": strike_records,
		"pendingStats": pending_stats,
		"torchSlotRestored": false
	}
	restore_torch_slot(inventory, equipped_slot, pick_slot)
	main.held_item.refresh_active()
	result["torchSlotRestored"] = String(inventory.active_stack().get("item", "")) == "torch"
	result["passed"] = bool(result["passed"]) and bool(result["torchSlotRestored"])
	var quiet_frames := 0
	for _frame in range(300):
		await process_frame
		if runtime.voxel_engine_pending_task_count() == 0:
			quiet_frames += 1
		else:
			quiet_frames = 0
		if quiet_frames >= 20:
			break
	result["terrainPublicationQuietFrames"] = quiet_frames
	for _frame in range(2):
		await physics_frame
	var post_dig_view_hit: Dictionary = player.view_ray(3.9)
	var post_dig_target: Dictionary = {}
	if not post_dig_view_hit.is_empty():
		var post_collider := post_dig_view_hit.get("collider") as Node
		if post_collider != null and runtime.voxel_terrain_collider(post_collider):
			post_dig_target = main.break_target_for_hit(post_dig_view_hit, post_collider, String(post_collider.get_meta("kind", "")))
	var post_cell: Variant = post_dig_target.get("cell3", Vector3i.ZERO)
	var collider_surface_changed: bool = post_dig_view_hit.is_empty() or not (post_cell is Vector3i) or post_cell != cell
	result["preDigViewHit"] = {"hit": not pre_dig_view_hit.is_empty(), "position": vec(pre_dig_view_hit.get("position", Vector3.ZERO)) if not pre_dig_view_hit.is_empty() else []}
	result["postDigViewHit"] = {"hit": not post_dig_view_hit.is_empty(), "target": post_dig_target, "position": vec(post_dig_view_hit.get("position", Vector3.ZERO)) if not post_dig_view_hit.is_empty() else []}
	result["colliderSurfaceChanged"] = collider_surface_changed
	result["passed"] = bool(result["passed"]) and collider_surface_changed
	await capture("05-cave-wall-dug")
	return result

func restore_torch_slot(inventory, equipped_slot: int, pick_slot: int) -> void:
	inventory.select(equipped_slot)
	inventory.swap_with_active(pick_slot)

func audit_view_rays(stage: String, enforce_alignment := false) -> Dictionary:
	# Match potential sky patches to both generated/edited density and the real
	# terrain collider. This diagnostic is outside movement timing/capture claims.
	var camera: Camera3D = player.camera
	var world = main.world_generation_system
	var density_hits := 0
	var collision_hits := 0
	var aligned_hits := 0
	var solid_origin_rays := 0
	var collision_publication_deferred_rays := 0
	var mismatches: Array[Dictionary] = []
	var pixels: Array[Vector2] = [Vector2(480, 160), Vector2(640, 160), Vector2(800, 160), Vector2(480, 240), Vector2(640, 240), Vector2(800, 240), Vector2(480, 320), Vector2(640, 320), Vector2(800, 320)]
	if stage == "inbound-3":
		pixels.append_array([Vector2(880, 20), Vector2(920, 20), Vector2(960, 50), Vector2(900, 80)])
	for pixel in pixels:
		var origin := camera.project_ray_origin(pixel)
		var direction := camera.project_ray_normal(pixel)
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 100.0, 2)
		var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)
		var density_distance := -1.0
		var published_sdf_distance := -1.0
		var density_probe_position := Vector3.ZERO
		var density_probe_value := NAN
		var distance := 0.0
		var previous_distance := 0.0
		var previous_sdf := published_sdf_at_world_position(origin, runtime.terrain.get_voxel_tool())
		var starts_in_solid := previous_sdf <= 0.0
		if starts_in_solid:
			solid_origin_rays += 1
			published_sdf_distance = 0.0
		while distance <= 100.0:
			if starts_in_solid:
				break
			var p := origin + direction * distance
			var published_sdf := published_sdf_at_world_position(p, runtime.terrain.get_voxel_tool())
			if published_sdf_distance < 0.0 and previous_sdf > 0.0 and published_sdf <= 0.0:
				var low := previous_distance
				var high := distance
				for _refine in range(7):
					var mid := (low + high) * 0.5
					if published_sdf_at_world_position(origin + direction * mid, runtime.terrain.get_voxel_tool()) > 0.0:
						low = mid
					else:
						high = mid
				published_sdf_distance = (low + high) * 0.5
			var cell := Vector3i((p / 1.35).floor())
			var density: float = world.density_from_components(p, world.terrain_deformed_surface_y_at(p), world.terrain_reference_surface_y_at(p))
			if world.terrain_volume_service.edited_cells.has(cell):
				density = float(world.get_cell_state(cell).density)
			if density >= 0.0 and density_distance < 0.0:
				density_distance = distance
				density_probe_position = p
				density_probe_value = density
			distance += 0.25
			previous_distance = distance - 0.25
			previous_sdf = published_sdf
		var collision_distance := -1.0
		if not hit.is_empty() and runtime.voxel_terrain_collider(hit.get("collider")):
			collision_distance = origin.distance_to(hit.position)
		var collision_expected_by_viewer := true
		if published_sdf_distance >= 0.0 and runtime.viewer != null and is_instance_valid(runtime.viewer):
			var expected_surface := origin + direction * published_sdf_distance
			var viewer_xz := Vector2(runtime.viewer.global_position.x, runtime.viewer.global_position.z)
			var surface_xz := Vector2(expected_surface.x, expected_surface.z)
			var required_view_distance: int = runtime.collision_publication_view_distance_requirement(viewer_xz.distance_to(surface_xz))
			collision_expected_by_viewer = required_view_distance <= int(runtime.viewer.view_distance)
		var collision_assessment_deferred := collision_distance < 0.0 and not collision_expected_by_viewer
		if collision_assessment_deferred:
			collision_publication_deferred_rays += 1
		if density_distance >= 0.0: density_hits += 1
		if collision_distance >= 0.0: collision_hits += 1
		var aligned := starts_in_solid or (published_sdf_distance < 0.0 and collision_distance < 0.0)
		if not starts_in_solid and published_sdf_distance >= 0.0 and collision_distance >= 0.0:
			aligned = absf(published_sdf_distance - collision_distance) <= 1.5
			if aligned: aligned_hits += 1
		if enforce_alignment and not aligned and not collision_assessment_deferred:
			var detail := {"pixel": [pixel.x, pixel.y], "densityHitDistance": density_distance,
				"publishedSdfHitDistance": published_sdf_distance,
				"collisionHitDistance": collision_distance, "reason": "published_sdf_collision_disagreement"}
			var ray_profile: Array[Dictionary] = []
			if not hit.is_empty() and collision_distance >= 0.0:
				var collision_point: Vector3 = hit.get("position", Vector3.ZERO)
				var collision_cell := Vector3i((collision_point / 1.35).floor())
				var collision_state: Dictionary = world.get_cell_state(collision_cell)
				var voxel_tool = runtime.terrain.get_voxel_tool()
				voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
				var published_sdf := float(voxel_tool.get_voxel_f(collision_cell))
				var direct_density := float(world.density_from_components(collision_point,
					world.terrain_deformed_surface_y_at(collision_point),
					world.terrain_reference_surface_y_at(collision_point)))
				var profile_distance := maxf(0.0, density_distance)
				while profile_distance <= collision_distance + 0.001:
					var profile_point := origin + direction * profile_distance
					var profile_cell := Vector3i((profile_point / 1.35).floor())
					var profile_density := float(world.density_from_components(profile_point,
						world.terrain_deformed_surface_y_at(profile_point),
						world.terrain_reference_surface_y_at(profile_point)))
					var voxel_grid_point := Vector3(profile_cell) * 1.35
					var grid_density := float(world.density_from_components(voxel_grid_point,
						world.terrain_deformed_surface_y_at(voxel_grid_point),
						world.terrain_reference_surface_y_at(voxel_grid_point)))
					if world.terrain_volume_service.edited_cells.has(profile_cell):
						profile_density = float(world.get_cell_state(profile_cell).density)
					ray_profile.append({"distance": snappedf(profile_distance, 0.001),
						"position": vec(profile_point), "density": profile_density,
						"sdfAtNearestCell": float(voxel_tool.get_voxel_f(profile_cell)),
						"voxelGridPoint": vec(voxel_grid_point), "sourceDensityAtVoxelGrid": grid_density,
						"expectedEncodedSdfAtVoxelGrid": -grid_density / 1.35,
						"publishedSdfAtVoxelGrid": float(voxel_tool.get_voxel_f(profile_cell)),
						"cell": {"x": profile_cell.x, "y": profile_cell.y, "z": profile_cell.z}})
					profile_distance += 0.5
				detail.merge({"origin": vec(origin), "direction": vec(direction),
					"collisionPoint": vec(collision_point), "collisionCell": {
						"x": collision_cell.x, "y": collision_cell.y, "z": collision_cell.z},
					"collisionCellState": collision_state, "directDensityAtCollision": direct_density,
					"publishedVoxelSdf": published_sdf,
					"densityProbePoint": vec(density_probe_position),
					"densityProbeValue": density_probe_value,
					"densityProbeCell": {
						"x": floori(density_probe_position.x / 1.35),
						"y": floori(density_probe_position.y / 1.35),
						"z": floori(density_probe_position.z / 1.35)},
					"publishedSdfAtDensityProbe": float(voxel_tool.get_voxel_f(Vector3i(
						floori(density_probe_position.x / 1.35),
						floori(density_probe_position.y / 1.35),
						floori(density_probe_position.z / 1.35)))),
					"rayDensitySdfProfile": ray_profile,
					"edited": bool(world.terrain_volume_service.edited_cells.has(collision_cell))}, true)
			mismatches.append(detail)
		view_audits.append({"stage": stage, "pixel": [pixel.x, pixel.y], "origin": vec(origin),
			"direction": vec(direction), "densityHitDistance": density_distance,
			"publishedSdfAtRayOrigin": previous_sdf, "startsInSolid": starts_in_solid,
			"publishedSdfHitDistance": published_sdf_distance,
			"collisionHitDistance": collision_distance, "aligned": aligned,
			"collisionExpectedByViewer": collision_expected_by_viewer,
			"collisionAssessmentDeferredByStreamingRange": collision_assessment_deferred})
		await process_frame
	last_tick = Time.get_ticks_usec()
	var result := {"stage": stage, "rayCount": pixels.size(), "densityHitCount": density_hits,
		"terrainCollisionHitCount": collision_hits, "alignedSurfaceHitCount": aligned_hits,
		"collisionPublicationDeferredRayCount": collision_publication_deferred_rays,
		"startsInSolidRayCount": solid_origin_rays,
		"mismatches": mismatches, "passed": mismatches.is_empty()}
	if enforce_alignment and (density_hits < 2 or collision_hits < 2 or aligned_hits < 2):
		result.passed = false
		result["reason"] = "insufficient_enclosed_mouth_rays"
		result["minimumAlignedSurfaceHits"] = 2
	if enforce_alignment and not bool(result.passed):
		failures.append("cave_exterior_density_collision_rays:%s" % JSON.stringify(result))
	return result

func published_sdf_at_world_position(position: Vector3, voxel_tool) -> float:
	voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
	var grid := position / 1.35
	var base := Vector3i(floori(grid.x), floori(grid.y), floori(grid.z))
	var blend := grid - Vector3(base)
	var c000 := float(voxel_tool.get_voxel_f(base))
	var c100 := float(voxel_tool.get_voxel_f(base + Vector3i.RIGHT))
	var c010 := float(voxel_tool.get_voxel_f(base + Vector3i.UP))
	var c110 := float(voxel_tool.get_voxel_f(base + Vector3i.RIGHT + Vector3i.UP))
	var c001 := float(voxel_tool.get_voxel_f(base + Vector3i.BACK))
	var c101 := float(voxel_tool.get_voxel_f(base + Vector3i.RIGHT + Vector3i.BACK))
	var c011 := float(voxel_tool.get_voxel_f(base + Vector3i.UP + Vector3i.BACK))
	var c111 := float(voxel_tool.get_voxel_f(base + Vector3i.RIGHT + Vector3i.UP + Vector3i.BACK))
	var z0 := lerpf(lerpf(c000, c100, blend.x), lerpf(c010, c110, blend.x), blend.y)
	var z1 := lerpf(lerpf(c001, c101, blend.x), lerpf(c011, c111, blend.x), blend.y)
	return lerpf(z0, z1, blend.z)

func capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var path := output + label + ".png"
	root.get_texture().get_image().save_png(path)
	captures.append({"label": label, "path": path, "elapsedMs": Time.get_ticks_msec() - act_start, "position": vec(player.global_position) if player != null else [], "diagnosticFill": false})
	last_tick = Time.get_ticks_usec()
	print("CAVE WALK: capture ", label)

func record_if_due() -> void:
	if record_active and not record_busy and Time.get_ticks_msec() - last_record_ms >= 100:
		record_busy = true
		call_deferred("record_frame")

func record_frame() -> void:
	await RenderingServer.frame_post_draw
	last_record_ms = Time.get_ticks_msec()
	var path := output + "frames/%05d.jpg" % recorded_frames.size()
	root.get_texture().get_image().save_jpg(path, 0.80)
	recorded_frames.append({"path": ProjectSettings.globalize_path(path), "elapsedMs": last_record_ms - act_start})
	record_busy = false

func wait_for_capture_terrain(position: Vector3, label: String) -> Dictionary:
	var latest_proof: Dictionary = {}
	for frame in range(900):
		await process_frame
		if frame % 30 != 0:
			continue
		if runtime.has_method("update_viewer_position"):
			runtime.update_viewer_position()
		# This is a camera-preview gate, not a movement acceptance test. Require
		# the local VoxelTerrain mesh/collision area to exist, without waiting for
		# unrelated surface-chunk receipts or testing a player traversal.
		latest_proof = runtime.collision_mesh_ready_for_body_position(position, 0.42)
		if bool(latest_proof.get("passed", false)):
			return {"label": label, "passed": true, "frames": frame,
				"proof": latest_proof}
		if frame % 180 == 0:
			print("CAVE CAPTURE PUBLICATION ", label, " frame=", frame,
				" localTerrainProof=", latest_proof,
				" verticalBounds=", runtime.vertical_cell_bounds(),
				" terrain=", runtime.terrain.get_statistics() if runtime.terrain != null else {})
	return {"label": label, "passed": false, "frames": 900,
		"reason": latest_proof.get("reason", "capture_publication_timeout"),
		"proof": latest_proof, "verticalBounds": runtime.vertical_cell_bounds(),
		"terrain": runtime.terrain.get_statistics() if runtime.terrain != null else {}}

func finish() -> void:
	record_active = false
	while record_busy:
		await process_frame
	if not recorded_frames.is_empty():
		var concat := "ffconcat version 1.0\n"
		for index in range(recorded_frames.size()):
			var frame: Dictionary = recorded_frames[index]
			concat += "file '%s'\n" % String(frame.path).replace("\\", "/")
			var duration := float(recorded_frames[index + 1].elapsedMs - frame.elapsedMs) / 1000.0 if index + 1 < recorded_frames.size() else 0.1
			concat += "duration %.4f\n" % duration
		FileAccess.open(output + "frames.ffconcat", FileAccess.WRITE).store_string(concat)
	var sorted := frame_times.duplicate()
	sorted.sort()
	var capture_only := OS.get_environment("CAVE_CAPTURE_ONLY") == "1"
	var report := {"evidenceLevel": "diagnostic_visual_capture_only" if capture_only else ("diagnostic_live_physics_with_cave_dig" if diagnostic else "headed_gameplay_fixture_with_cave_dig"), "captureOnly": capture_only, "captureMode": "diagnostic_local_volume_focus" if capture_only and diagnostic else "standard", "liveWalkCompleted": not capture_only and failures.is_empty(), "liveCaveDigCompleted": bool(cave_dig_evidence.get("passed", false)), "caveDigEvidence": cave_dig_evidence, "normalMenuNewGame": ready, "diagnosticStartup": diagnostic, "tutorialTownStartup": "excluded_by_diagnostic_fast_boot" if diagnostic else ("normal_new_game_path" if ready else "not_started"), "diagnosticStreamingOwnersReenabled": diagnostic_streaming_owners_reenabled, "seed": seed_value, "region": str(cave_region), "fixturePlacementBeforeAct": true, "preActSupport": pre_act_support, "actTeleports": 0, "forcedCollisionReadiness": false, "lighting": "ordinary held torch and game sky", "passed": failures.is_empty() and (not capture_only or (captures.size() == capture_expected_count and capture_publication.size() == capture_expected_count)), "failures": failures, "optionalWalkFailures": optional_walk_failures, "captures": captures, "trace": trace, "frameSamples": sorted.size(), "p95PhysicsIntervalMs": sorted[floori(sorted.size() * 0.95)] if not sorted.is_empty() else 0, "maxPhysicsIntervalMs": sorted.back() if not sorted.is_empty() else 0, "runtimePerformance": main.runtime_perf_monitor.summary() if main != null else {}}
	if capture_only:
		report["capturePublication"] = capture_publication
	report["arrivals"] = arrivals
	report["viewRayAudit"] = view_audits
	report["viewRayAuditSummaries"] = view_audit_summaries
	report["recordedFrames"] = recorded_frames
	report["recordingOverheadPresent"] = not recorded_frames.is_empty()
	report["requestedSeed"] = seed_value
	if main != null:
		report["seed"] = main.seed_text
		var world = main.world_generation_system
		report["groundQueries"] = {"count": world.ground_query_count, "totalMs": float(world.ground_query_total_usec) / 1000.0, "maxMs": float(world.ground_query_max_usec) / 1000.0}
		var cave_cache_stats: Dictionary = world.cave_field.cache_stats()
		report["recipeConstruction"] = {"count": int(cave_cache_stats.get("recipe_build_count", 0)), "totalMs": float(cave_cache_stats.get("recipe_build_total_usec", 0)) / 1000.0, "maxMs": float(cave_cache_stats.get("recipe_build_max_usec", 0)) / 1000.0, "cacheEvictions": int(cave_cache_stats.get("cache_evictions", 0))}
		world = null
	FileAccess.open(output + "report.json", FileAccess.WRITE).store_string(JSON.stringify(report, "  "))
	print("CAVE WALK: finished failures=", failures)
	if main != null:
		main.set_process(false)
		main.set_physics_process(false)
	if player != null:
		player.set_physics_process(false)
	if runtime != null:
		runtime.begin_shutdown()
	await create_timer(1.0).timeout
	if main != null:
		main.queue_free()
	main = null
	player = null
	runtime = null
	for _frame in range(4):
		await process_frame
	quit(0 if failures.is_empty() else 1)

func vec(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
