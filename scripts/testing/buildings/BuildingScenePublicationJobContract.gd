extends SceneTree
## Synthetic orchestration only: tiny real publishers, synthetic prepared proofs
## and tree callback. Not source preparation, live trees, doors, or gameplay.
const Job = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Fixtures = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")

class SyntheticTrees extends RefCounted:
	var published := 0
	var retired := 0
	var retired_ids: Dictionary = {}
	var retire_before_free := true
	var visual_state := "published"
	var defer_once := false
	var calls := 0
	var cancel_target: WeakRef
	var second_pending := false
	var bodies: Array[WeakRef] = []
	func publish(parent: Node3D, id: String, position: Vector3, _biome: String, _request: Dictionary, yaw: float) -> Dictionary:
		calls += 1
		if defer_once:
			defer_once = false
			return {"status":"deferred", "reason":"synthetic_overlap"}
		var body := StaticBody3D.new()
		body.position = position
		body.rotation.y = yaw
		body.set_meta("prop_id", id)
		var state := "queued" if second_pending and published == 1 else visual_state
		body.set_meta("tree_visual_state", state)
		parent.add_child(body)
		if state == "published":
			var visual := Node3D.new()
			visual.name = "GeneratedTreeVisual"
			body.add_child(visual)
		published += 1
		bodies.append(weakref(body))
		if cancel_target != null: cancel_target.get_ref().cancel()
		return {"status":"published", "reason":"visual_queued", "body":body}
	func retire(id: String, body: StaticBody3D) -> void:
		retire_before_free = retire_before_free and is_instance_valid(body) and body.get_parent() != null
		retired += 1
		retired_ids[id] = int(retired_ids.get(id, 0)) + 1

class FinishCanceller extends RefCounted:
	var target: WeakRef
	var calls := 0
	func progress(record: Dictionary) -> void:
		calls += 1
		if record.get("reason") == "complete": target.get_ref().cancel()

var checks: Dictionary = {}
var worker = Worker.new()
var parent: Node3D

func _initialize() -> void: call_deferred("_run")

func check(label: String, value: bool) -> void:
	checks[label] = value
	if not value: print("SCENE JOB CONTRACT FAILURE ", label)

func holder() -> Preparation.PreparedSource:
	var blueprint = Blueprint.new("synthetic-publication", 1, "timber")
	blueprint.add_part({"id":"tiny-post", "kind":"post", "material":"timber_beam",
		"size":Vector3(0.2, 1.0, 0.2), "position":Vector3(0, 0.5, 0)})
	blueprint.recipe["landscapeTrees"] = [
		{"id":"a", "position":Vector3(2, 0, 0), "rotationY":0.0, "treeRequest":{"biome":"town"}},
		{"id":"b", "position":Vector3(4, 0, 0), "rotationY":0.0, "treeRequest":{"biome":"town"}}]
	var result := Preparation.PreparedSource.new()
	result._binding = Fixtures.BINDING
	result._payload = {"blueprint":blueprint, "furnishingPlan":Plan.new("tiny", 1, blueprint.id),
		"physicalIntegrity":{"passed":true}, "raisedRouteCoverage":{"passed":true},
		"preparationUsec":0, "routeUsec":0, "physicalUsec":0}
	return result

func frozen_profile() -> Dictionary:
	var profile: Dictionary = Fixtures.profile()
	profile.origin = Vector3(10, 0, 20)
	Fixtures.freeze(profile)
	return profile

func start(job, trees, prepared = null, binding: Dictionary = Fixtures.BINDING) -> void:
	if prepared == null: prepared = holder()
	job.set_tree_retire_callback(trees.retire)
	job.begin(prepared, frozen_profile(), binding, parent, trees.publish)

func drain(job, label: String) -> void:
	for index in range(1000):
		if job.status().retirementReady: break
		job.advance(4000)
	check(label + "_nodes_gone", job.own_node_root() == null and job.status().retirementReady)
	var payload: Dictionary = job.take_retirement_payload()
	check(label + "_retirement_once", not payload.is_empty() and job.take_retirement_payload().is_empty())
	worker.retire_external_payload(payload)
	payload = {}
	# The wrapper is the process watchdog; this is only a bounded worker drain.
	var deadline := Time.get_ticks_msec() + 5000
	while worker.poll().busy and Time.get_ticks_msec() < deadline: await process_frame
	check(label + "_worker_drained", not worker.poll().busy)

func _run() -> void:
	parent = Node3D.new()
	parent.position = Vector3(3, 0, 5)
	root.add_child(parent)
	var trees := SyntheticTrees.new()
	var job = Job.new()
	var prepared := holder()
	start(job, trees, prepared)
	check("begin_queues_without_nodes_or_consume", job.own_node_root() == null and not prepared._consumed)
	check("budget_zero_rejected", job.advance(0).status == "rejected")
	check("budget_4001_rejected", job.advance(4001).status == "rejected")
	check("bad_budgets_do_not_consume", not prepared._consumed and job.own_node_root() == null)
	job.cancel()
	check("cancel_immediately_not_ready", not job.status().sceneReady and job.status().status == "cancelled")
	prepared = null
	await drain(job, "cancel_before_begin")
	check("cancel_before_begin_no_callback", trees.calls == 0)

	job = Job.new()
	prepared = holder()
	var stale := Fixtures.BINDING.duplicate()
	stale.generation += 1
	start(job, trees, prepared, stale)
	job.advance(1)
	check("stale_holder_rejected_unconsumed", job.status().status == "failed" and not prepared._consumed)
	prepared = null
	await drain(job, "stale_holder")

	job = Job.new()
	start(job, trees)
	for index in range(100):
		job.advance(1)
		if job.status().buildingCursor > 0: break
	check("actual_part_collision_created", job._building.collision_count > 0)
	check("root_exact_world_origin", job.own_node_root().global_position.is_equal_approx(Vector3(10, 0, 20)))
	job.cancel()
	await drain(job, "cancel_after_collider")
	check("collider_cancel_no_tree_callback", trees.calls == 0)

	# The real publisher invokes its ordinary progress callback from finish.
	# That reentrant cancellation must not restore furniture_begin afterwards.
	trees = SyntheticTrees.new()
	job = Job.new()
	start(job, trees)
	job.advance(1)
	var finish_cancel := FinishCanceller.new()
	finish_cancel.target = weakref(job)
	job._building.incremental_progress_callback = finish_cancel.progress
	for index in range(100):
		job.advance(4000)
		if job.status().status == "cancelled": break
	check("finish_callback_cancel_preserves_teardown", job.status().status == "cancelled" and job.status().phase == "teardown")
	check("finish_callback_no_furniture_or_trees", job._furniture == null and trees.calls == 0)
	check("finish_callback_not_scene_ready", not job.status().sceneReady)
	await drain(job, "cancel_in_finish_callback")
	check("finish_callback_no_later_calls", finish_cancel.calls == 1 and trees.calls == 0)

	# Root-loss recovery before external tree registrations exist. After trees
	# are registered, an external owner must balance its hook BEFORE destroying
	# those bodies; the job cannot issue a before-free callback retroactively.
	job = Job.new()
	start(job, trees)
	job.advance(1)
	check("root_loss_fixture_has_no_children", job.own_node_root().get_child_count() == 0)
	job.own_node_root().free()
	job.advance(1)
	check("root_loss_is_explicit_failure", job.status().status == "failed" and job.status().reason == "publication_root_lost")
	check("root_loss_never_scene_ready", not job.status().sceneReady)
	await drain(job, "lost_root")

	trees = SyntheticTrees.new()
	job = Job.new()
	trees.cancel_target = weakref(job)
	start(job, trees)
	for index in range(100):
		job.advance(4000)
		if job.status().status == "cancelled": break
	check("reentrant_cancel_one_callback", trees.calls == 1 and trees.published == 1)
	await drain(job, "cancel_in_tree_callback")
	check("no_callback_after_cancel", trees.calls == 1)
	check("tree_retired_exactly_once_before_free", trees.retired == 1 and trees.retire_before_free and trees.retired_ids.values() == [1])

	trees = SyntheticTrees.new()
	trees.defer_once = true
	job = Job.new()
	start(job, trees)
	for index in range(100):
		job.advance(4000)
		if job.status().sceneReady: break
	check("deferred_tree_retained_and_completed", job.status().sceneReady and trees.calls == 3 and trees.published == 2)
	check("scene_not_gameplay_ready", not job.status().gameplayReady)
	check("both_tree_visuals_required", job.status().treeVisualsComplete == 2)
	job.cancel()
	await drain(job, "successful_scene")
	check("both_successful_trees_retired_once", trees.retired == 2 and trees.retired_ids.values() == [1, 1])

	# First tree was already observed complete; it disappears while the second
	# remains queued. Completion must revalidate the first weak reference too.
	trees = SyntheticTrees.new()
	trees.second_pending = true
	job = Job.new()
	start(job, trees)
	for index in range(100):
		job.advance(1)
		if job.status().phase == "tree_visuals" and job.status().treeVisualsComplete == 1: break
	check("disappearance_fixture_first_seen_second_pending", job.status().treeVisualsComplete == 1 and not job.status().sceneReady and trees.published == 2)
	var first: StaticBody3D = trees.bodies[0].get_ref() as StaticBody3D
	var second: StaticBody3D = trees.bodies[1].get_ref() as StaticBody3D
	# Simulate an external owner correctly balancing its own registration before
	# removal. This is not a harvest and writes no durable removed_props entry.
	trees.retire(String(first.get_meta("prop_id")), first)
	first.get_node("GeneratedTreeVisual").free()
	first.free()
	first = null
	var completed_visual := Node3D.new()
	completed_visual.name = "GeneratedTreeVisual"
	second.add_child(completed_visual)
	second.set_meta("tree_visual_state", "published")
	second = null
	completed_visual = null
	for index in range(100):
		job.advance(1)
		if job.status().status == "failed": break
	check("completed_tree_disappearance_invalidates_ready", job.status().status == "failed" and job.status().reason == "tree_body_lost_before_visual" and not job.status().sceneReady)
	await drain(job, "completed_tree_disappeared")
	check("surviving_tree_retired_once", trees.retired == 2 and trees.retired_ids.values() == [1, 1])

	for state: String in ["failed", "failed_fallback", ""]:
		trees = SyntheticTrees.new()
		trees.visual_state = state
		job = Job.new()
		start(job, trees)
		for index in range(100):
			job.advance(4000)
			if job.status().status == "failed": break
		check("bad_tree_state_" + state, job.status().status == "failed" and not job.status().sceneReady)
		await drain(job, "bad_tree_" + state)
	worker.request_shutdown()
	var deadline := Time.get_ticks_msec() + 5000
	while not worker.poll().shutdownComplete and Time.get_ticks_msec() < deadline: await process_frame
	check("shutdown_complete", worker.poll().shutdownComplete)
	check("parent_empty", parent.get_child_count() == 0)
	parent.free()
	var failures: Array = []
	for key: String in checks:
		if not checks[key]: failures.append(key)
	var report := {"evidence":"synthetic scene orchestration; no live gameplay", "checks":checks,
		"checkCount":checks.size(), "failureCount":failures.size(), "failures":failures}
	var output := OS.get_environment("BUILDING_SCENE_PUBLICATION_JOB_OUTPUT")
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(output)
		var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "\t"))
	print("SCENE_JOB_CONTRACT checks=", checks.size(), " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
