extends "res://scripts/testing/TreePublicationQueueContractRunner.gd"
## Cancellation contract using the production queue and recipe worker. Actor
## motion, harvesting and finished tree imagery are deliberately not exercised.

func pump_worker(queue) -> bool:
	var deadline := Time.get_ticks_msec() + 10000
	while not queue.active.is_empty() and Time.get_ticks_msec() < deadline:
		queue.collect_completed_workers()
		OS.delay_msec(2) # Give the actual CPU worker time under fixed-FPS tests.
		await process_frame
	return queue.active.is_empty()

func run_contract() -> void:
	var output := OS.get_environment("TREE_PUBLICATION_CANCELLATION_OUTPUT")
	if output.is_empty(): quit(2); return
	var fixture := Node3D.new()
	root.add_child(fixture)
	var queue = TreePublicationQueueScript.new()
	fixture.add_child(queue)
	queue.set_process(false)
	var request := request_for("cancel-tree", "broadleaf", "bushy_oak", "forest")
	var pending := tree_body("cancel-tree")
	fixture.add_child(pending)
	add_result("real_pending_enqueue", queue.enqueue(pending, request), {})
	var receipt: Dictionary = queue.cancel_body_publication(pending)
	add_result("exact_instance_cancel_receipt", receipt.status == "cancelled" and receipt.bodyInstanceId == pending.get_instance_id(), receipt)
	add_result("same_instance_cannot_requeue", not queue.enqueue(pending, request), {})
	queue.start_pending_workers()
	add_result("cancelled_pending_never_starts_worker", queue.active.is_empty() and not queue.has_pending_tasks(), {})
	add_result("cancel_is_not_destruction", pending.is_inside_tree() and not pending.is_queued_for_deletion() and not pending.has_meta("destroyed"), {})
	var active := tree_body("cancel-tree")
	fixture.add_child(active)
	add_result("same_id_fresh_instance_can_enqueue", queue.enqueue(active, request), {})
	queue.start_pending_workers()
	add_result("actual_worker_started", queue.active.size() == 1, {})
	queue.cancel_body_publication(active)
	add_result("actual_worker_joined_normally", await pump_worker(queue), {})
	queue.publish_completed_recipes()
	await process_frame
	add_result("cancelled_worker_cannot_attach_visual", active.get_node_or_null("GeneratedTreeVisual") == null and queue.completed_count == 0 and queue.staged_publication_task.is_empty(), {})
	var staged := tree_body("cancel-tree")
	fixture.add_child(staged)
	add_result("fresh_instance_reuses_immutable_recipe", queue.enqueue(staged, request) and queue.completed_count == 1, {})
	queue.publish_completed_recipes()
	add_result("publication_staged_before_cancel", not queue.staged_publication_task.is_empty(), {})
	queue.cancel_body_publication(staged)
	queue.publish_completed_recipes()
	await process_frame
	add_result("staged_cancel_releases_unattached_visual", queue.staged_publication_task.is_empty() and staged.get_node_or_null("GeneratedTreeVisual") == null, {})
	var viewer := Node3D.new()
	fixture.add_child(viewer)
	queue.set_viewer(viewer)
	# Explicit synthetic LOD-record fixture; production record pruning is tested.
	queue.remember_published_lod(staged, request)
	queue.refresh_published_lods()
	add_result("cancelled_lod_cannot_reenqueue", queue.published_lod_records.is_empty() and not queue.has_pending_tasks(), {})
	queue.refresh_collision_visibility_proxies()
	add_result("cancelled_proxy_cannot_attach", staged.get_node_or_null("GeneratedTreeVisual") == null, {})
	var passed := true
	for result: Dictionary in results: passed = passed and result.passed
	var report := {"passed":passed, "results":results, "queue":queue.metrics(),
		"sourceSha256":FileAccess.get_sha256("res://scripts/environment/TreePublicationQueue.gd"),
		"evidenceLevel":"queue cancellation contract; actual recipe worker, synthetic LOD record; no finished imagery or live harvest"}
	fixture.free()
	await process_frame
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("TREE PUBLICATION CANCELLATION ",passed," checks=",results.size())
	quit(0 if passed else 1)
