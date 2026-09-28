extends "res://scripts/testing/buildings/CitadelSceneLifecycleContract.gd"
## Synthetic tiny source, real publication worker/jobs/publishers. Verifies the
## pre-reset ownership fence, not Main gameplay or NPC behavior acceptance.

func reset_case(complete: bool) -> void:
	var label := "complete" if complete else "partial"
	var c := setup_scene(not complete)
	bind_scene(c, label + "_bound")
	if complete:
		await wait_scene(c, REGION, "scene_ready", label + "_constructed")
	else:
		await wait_phase(c, "tree_visuals", label + "_tree_wait")
	var started: int = c.service.stats().sceneStartedCount
	check(label + "_owns_scene_before_reset", c.service.requires_scene_retirement())
	c.service.begin_world_reset()
	check(label + "_reset_pending", c.service.stats().worldResetPending)
	check(label + "_not_ready_before_cleanup", not c.service.world_reset_ready())
	c.service.begin_world_reset() # Idempotent; cannot discard old cleanup claims.
	var deadline := Time.get_ticks_msec() + 6000
	while not c.service.world_reset_ready() and Time.get_ticks_msec() < deadline:
		# Normal observer traffic cannot reopen dispatch during the drain.
		c.service.advance(bounds(), true)
		await process_frame
	check(label + "_drain_complete", c.service.world_reset_ready())
	check(label + "_scene_gone", not c.service.requires_scene_retirement() and c.parent.get_child_count() == 0)
	check(label + "_no_republication", c.service.stats().sceneStartedCount == started)
	check(label + "_tree_callback_balanced", c.trees.calls == 1 and c.trees.retired == 1 and c.trees.balanced)
	check(label + "_old_tree_freed", c.trees.bodies.size() == 1 and c.trees.bodies[0].get_ref() == null)
	for index in range(6):
		c.service.advance(bounds(), true)
		await process_frame
	check(label + "_fence_retained_after_drain", c.service.world_reset_ready() and c.service.stats().sceneStartedCount == started)
	# Seed/configuration changes must NOT reopen dispatch before registry reset.
	c.service.configure(c.admission)
	check(label + "_configuration_keeps_fence", c.service.stats().worldResetPending)
	check(label + "_configuration_requires_fresh_poll", not c.service.world_reset_ready())
	c.service.advance(bounds(), true)
	check(label + "_configuration_cannot_start_scene", c.service.stats().sceneStartedCount == started)
	c.service.complete_world_reset()
	c.service.advance(bounds(), true)
	check(label + "_explicit_completion_reopens", not c.service.stats().worldResetPending)
	if not complete: c.trees.release_visuals()
	# Reuse a fresh tiny source with completed visual acknowledgement.
	c.admission._sources[REGION] = scene_source(REGION, false)
	await wait_scene(c, REGION, "scene_ready", label + "_new_scene")
	check(label + "_new_scene_once", c.service.stats().sceneStartedCount == started + 1)
	metrics[label] = c.service.stats()
	await finish_case(c, label + "_finish")

func _run() -> void:
	var output := OS.get_environment("CITADEL_WORLD_RESET_OUTPUT")
	if output.is_empty(): quit(2); return
	var started := Time.get_ticks_usec()
	await reset_case(true)
	await reset_case(false)
	var inflight := setup_scene()
	bind_scene(inflight, "inflight_bound")
	inflight.service.advance(bounds(), true)
	check("inflight_preparation_dispatched", inflight.service.stats().dispatchCount == 1)
	inflight.service.begin_world_reset()
	check("inflight_cached_idle_cannot_ack_drain", not inflight.service.world_reset_ready())
	var deadline := Time.get_ticks_msec() + 6000
	while not inflight.service.world_reset_ready() and Time.get_ticks_msec() < deadline:
		inflight.service.advance(bounds(), true)
		await process_frame
	check("inflight_cancel_drained", inflight.service.world_reset_ready())
	inflight.admission._generation += 1 # Synthetic external source revision.
	inflight.service.advance(bounds(), true)
	check("automatic_configuration_keeps_fence", inflight.service.stats().worldResetPending and inflight.service.stats().sceneStartedCount == 0)
	await finish_case(inflight, "inflight_finish")
	var c := setup_scene(true)
	bind_scene(c, "main_helper_bound")
	await wait_phase(c, "tree_visuals", "main_helper_partial")
	var main_result: bool = await c.owner.retire_generated_scenes_before_world_reset()
	check("main_helper_drained", main_result and c.service.world_reset_ready())
	check("main_helper_callback_before_return", c.trees.calls == 1 and c.trees.retired == 1 and c.parent.get_child_count() == 0)
	check("main_helper_loading_feedback", not c.owner.startup_loading_timeline.is_empty())
	await finish_case(c, "main_helper_finish")
	var failures: Array = []
	for name: String in checks:
		if not checks[name]: failures.append(name)
	var report := {"passed":failures.is_empty(), "checks":checks, "failures":failures,
		"metrics":metrics, "elapsedUsec":Time.get_ticks_usec()-started,
		"evidenceLevel":"synthetic source/service pre-reset lifecycle; no Main/NPC/gameplay acceptance"}
	var source_hashes := {}
	for path: String in [get_script().resource_path, "res://scripts/world/CitadelPublicationService.gd", "res://scripts/MainCore.gd", "res://scripts/MainSaveState.gd", "res://scripts/buildings/BuildingScenePublicationJob.gd"]:
		source_hashes[path] = FileAccess.get_sha256(path)
	report["sourceSha256"] = source_hashes
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "\t")); file.close()
	print("CITADEL WORLD RESET checks=", checks.size(), " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
