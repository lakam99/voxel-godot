extends SceneTree

const TreeQueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const MAX_PHASE_SECONDS := 90.0

var report_path := ""
var capture_dir := ""
var observations: Array[Dictionary] = []
var captures: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run_fixture")


func run_fixture() -> void:
	report_path = OS.get_environment("VOXEL_HORIZON_TREE_REPORT")
	capture_dir = OS.get_environment("VOXEL_HORIZON_TREE_CAPTURES")
	if report_path.is_empty() or capture_dir.is_empty():
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(capture_dir)
	var world := Node3D.new()
	world.name = "HorizonTreeFixtureWorld"
	get_root().add_child(world)
	var environment := WorldEnvironment.new()
	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color(0.28, 0.53, 0.78)
	sky.sky_horizon_color = Color(0.78, 0.86, 0.91)
	var world_environment := Environment.new()
	world_environment.background_mode = Environment.BG_SKY
	world_environment.sky = Sky.new()
	world_environment.sky.sky_material = sky
	world_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.environment = world_environment
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, -28.0, 0.0)
	sun.light_energy = 1.7
	world.add_child(sun)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 17.0, 72.0)
	camera.fov = 58.0
	world.add_child(camera)
	camera.look_at(Vector3(0.0, 9.0, 0.0))
	camera.current = true
	var ground := MeshInstance3D.new()
	ground.mesh = PlaneMesh.new()
	ground.scale = Vector3(170.0, 1.0, 170.0)
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.27, 0.42, 0.30)
	ground.material_override = ground_material
	world.add_child(ground)
	var chunk := Node3D.new()
	chunk.name = "GeneratedChunkFixture"
	world.add_child(chunk)
	var queue: TreePublicationQueue = TreeQueueScript.new()
	queue.name = "TreePublicationQueue"
	world.add_child(queue)
	var viewer := Node3D.new()
	viewer.position = Vector3(0.0, 0.0, 270.0)
	world.add_child(viewer)
	queue.set_viewer(viewer)
	queue.set_process(false)
	var first := tree_body("horizon-tree-first", Vector3(-11.0, 0.0, 0.0))
	var second := tree_body("horizon-tree-second", Vector3(11.0, 0.0, 0.0))
	chunk.add_child(first)
	chunk.add_child(second)
	var first_enqueued: bool = queue.enqueue(first, tree_request(first))
	var second_enqueued: bool = queue.enqueue(second, tree_request(second))
	var batch := chunk.get_node_or_null("HorizonEcologyTreeBatch") as Node3D
	var first_snapshot: Dictionary = batch.call("installed_snapshot", first) if batch != null else {}
	var second_snapshot: Dictionary = batch.call("installed_snapshot", second) if batch != null else {}
	var distinct_slots := first_enqueued and second_enqueued \
		and String(first_snapshot.get("status", "")) == "ready" \
		and String(second_snapshot.get("status", "")) == "ready" \
		and int(first_snapshot.get("batchInstanceId", 0)) == int(second_snapshot.get("batchInstanceId", -1)) \
		and int(first_snapshot.get("slot", -1)) != int(second_snapshot.get("slot", -1))
	observe("two_generated_tree_bodies_have_distinct_installed_batch_slots", distinct_slots,
		{"first": snapshot_summary(first_snapshot), "second": snapshot_summary(second_snapshot),
		"firstState": first.get_meta("tree_visual_state", ""),
		"secondState": second.get_meta("tree_visual_state", "")})
	await capture("horizon_pending")
	var slot_was_visible := first.get_node_or_null("GeneratedTreeVisual") == null \
		and second.get_node_or_null("GeneratedTreeVisual") == null \
		and String(first_snapshot.get("status", "")) == "ready"
	observe("horizon_capture_precedes_recipe_publication", slot_was_visible, {})
	queue.cancel_body_publication(second)
	var cancelled_snapshot: Dictionary = batch.call("installed_snapshot", second) if batch != null else {}
	var sibling_snapshot: Dictionary = batch.call("installed_snapshot", first) if batch != null else {}
	observe("cancelling_one_body_invalidates_only_its_slot",
		String(cancelled_snapshot.get("status", "")) != "ready" \
		and String(sibling_snapshot.get("status", "")) == "ready",
		{"cancelled": snapshot_summary(cancelled_snapshot), "sibling": snapshot_summary(sibling_snapshot)})
	await capture("sibling_after_cancellation")
	queue.set_process(true)
	var far_committed := await wait_for_tree(first, "published", "", MAX_PHASE_SECONDS)
	var far_tier := String(first.get_meta("tree_render_lod_tier", ""))
	observe("queued_tree_commits_its_distant_recipe", far_committed \
		and far_tier != "near" and first.get_node_or_null("GeneratedTreeVisual") != null,
		{"tier": far_tier, "state": first.get_meta("tree_visual_state", ""),
		"metrics": queue.metrics()})
	if far_committed:
		await capture("distant_recipe_published")
	viewer.position = Vector3(0.0, 0.0, 15.0)
	var near_committed := await wait_for_tree(first, "published", "near", MAX_PHASE_SECONDS)
	var old_horizon_released := batch == null or String((batch.call("installed_snapshot", first) as Dictionary).get("status", "")) != "ready"
	observe("approach_promotes_through_queue_to_near_recipe_without_horizon_slot",
		near_committed and old_horizon_released and first.get_node_or_null("GeneratedTreeVisual") != null,
		{"tier": first.get_meta("tree_render_lod_tier", ""),
		"state": first.get_meta("tree_visual_state", ""),
		"horizonSlot": snapshot_summary(batch.call("installed_snapshot", first) if batch != null else {}),
		"metrics": queue.metrics()})
	if near_committed:
		await capture("near_recipe_published")
	var passed := true
	for entry in observations:
		if not bool(entry.passed):
			passed = false
	var report := {"schema": "visible-world-horizon-tree-headed/v1", "finished": true,
		"passed": passed, "evidenceLevel": "headed_production_queue_fixture",
		"scope": "Real TreePublicationQueue, recipe worker, chunk-owned HorizonEcologyTreeBatch, renderer frames and screenshots. Does not prove seeded chunk enumeration, normal gameplay startup, traversal, or full-view readiness.",
		"checks": observations, "captures": captures,
		"queueSourceSha256": FileAccess.get_sha256("res://scripts/environment/TreePublicationQueue.gd"),
		"batchSourceSha256": FileAccess.get_sha256("res://scripts/world/HorizonEcologyTreeBatch.gd")}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	world.queue_free()
	quit(0 if passed else 1)


func tree_body(id: String, position_value: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = id
	body.position = position_value
	body.set_meta("prop_id", id)
	var shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.height = 11.0
	cylinder.radius = 0.8
	shape.shape = cylinder
	shape.position.y = 5.5
	body.add_child(shape)
	return body


func tree_request(body: StaticBody3D) -> Dictionary:
	return {"treeId": String(body.get_meta("prop_id")),
		"worldSeed": "horizon-headed-fixture", "biome": "forest",
		"architecture": "broadleaf", "speciesGrammar": "bushy_oak",
		"growthStage": 0.80, "visualHeight": 20.0, "trunkRadius": 0.88,
		"canopyRadius": 8.0, "canopyDensity": 0.82,
		"treeWorldPosition": body.global_position,
		"publicationPriority": body.global_position.distance_squared_to(Vector3(0.0, 0.0, 270.0)),
		"biomeParameters": {"visibilityRange": 440.0}, "presentation": "runtime"}


func wait_for_tree(body: StaticBody3D, state: String, tier: String, seconds: float) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < int(seconds * 1000.0):
		if String(body.get_meta("tree_visual_state", "")) == state \
				and (tier.is_empty() or String(body.get_meta("tree_render_lod_tier", "")) == tier):
			return true
		await process_frame
	return false


func capture(stage: String) -> void:
	for _frame in range(4):
		await process_frame
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	var path := capture_dir.path_join("%s.png" % stage)
	var error := image.save_png(path)
	captures.append({"stage": stage, "path": path, "saved": error == OK,
		"size": [image.get_width(), image.get_height()]})
	observe("capture_%s_saved" % stage, error == OK and image.get_width() > 0 and image.get_height() > 0,
		{"path": path})


func snapshot_summary(snapshot: Dictionary) -> Dictionary:
	return {"status": snapshot.get("status", ""), "reason": snapshot.get("reason", ""),
		"bodyInstanceId": snapshot.get("bodyInstanceId", 0),
		"batchInstanceId": snapshot.get("batchInstanceId", 0),
		"pageIndex": snapshot.get("pageIndex", -1), "slot": snapshot.get("slot", -1)}


func observe(name: String, passed: bool, details: Dictionary) -> void:
	observations.append({"name": name, "passed": passed, "details": details})
