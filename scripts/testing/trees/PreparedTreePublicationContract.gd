extends SceneTree

## Source/service contract only. Extracts the production publication functions
## unchanged into an isolated harness; navigation and overlap resolution are
## spies, not gameplay acceptance. Uses the real request builder and queue intake.
const MAIN_PATH := "res://scripts/MainPlaytestTools.gd"
const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const ComposerScript := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
var results: Array[Dictionary] = []
# Immutable pre-extraction implementation; never compare a committed change
# with itself after HEAD advances.
const BASELINE_REVISION := "11cf54badfaf2d822ad2ff218635cab6b33d8fe7"

class NavigationNotificationSpy extends RefCounted:
    var created_ids: Array[String] = []
    func notify_navigation_prop_created(prop_id: String, _body: Node3D) -> void:
        created_ids.append(prop_id)

func _initialize() -> void:
    call_deferred("run_contract")

func check(label: String, passed: bool) -> void:
    results.append({"name": label, "passed": passed})
    if not passed:
        push_error("Contract failed: " + label)

func function_source(source: String, function_name: String) -> String:
    source = source.replace("\r\n", "\n")
    var start := source.find("func " + function_name + "(")
    if start < 0:
        return ""
    var end := source.find("\nfunc ", start + 1)
    var text := source.substr(start, end - start if end >= 0 else -1)
    # Do not attach comments belonging to the following function.
    var comment := text.find("\n##")
    return text.substr(0, comment).strip_edges() + "\n" if comment >= 0 else text.strip_edges() + "\n"

func harness(source: String, prepared: bool) -> Node3D:
    var code := """extends Node3D
const TreeRuntimeRequestBuilderScript = preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const TreePublicationQueueScript = preload("res://scripts/environment/TreePublicationQueue.gd")
var biome_environment_catalog
var visual_asset_registry
var tree_runtime_request_builder
var tree_publication_queue
var player
var npc_system
var removed_props = {}
var seed_text = "prepared-contract-runtime-seed"
var exclusion_blocked = false
var exclusions = []
var visual_specs = []
var overlap_calls = 0
var fallback_calls = 0
func natural_tree_blocked_at_cell(x, z, trunk, canopy):
    exclusions.append([x, z, trunk, canopy])
    return exclusion_blocked
func resolve_player_tree_publication_overlap(_body):
    overlap_calls += 1
    return false
func add_tree_visual(body, prop_id, biome, spec):
    visual_specs.append(spec.duplicate(true))
    _production_add_tree_visual(body, prop_id, biome, spec)
func add_fallback_tree_visual(_body, _spec):
    fallback_calls += 1
"""
    var functions := ["tree_visual_spec", "tree_runtime_spec_for_prop", "add_tree_visual", "add_generated_tree_visual", "make_tree", "ensure_tree_publication_queue"]
    if prepared:
        functions.append_array(["make_tree_from_runtime_request", "_publish_tree_body", "_player_position_overlaps_tree_dimensions", "player_position_overlaps_generated_tree"])
    for function_name in functions:
        var text := function_source(source, function_name)
        if function_name == "add_tree_visual":
            text = text.replace("func add_tree_visual(", "func _production_add_tree_visual(")
        code += "\n" + text
    var script := GDScript.new()
    script.source_code = code
    var error := script.reload()
    check("harness_compiles_" + str(prepared), error == OK)
    if error != OK:
        return null
    var instance: Node3D = script.new()
    get_root().add_child(instance)
    instance.biome_environment_catalog = CatalogScript.new()
    check("catalog_ready_" + str(prepared), instance.biome_environment_catalog.setup())
    instance.tree_publication_queue = instance.ensure_tree_publication_queue()
    instance.npc_system = NavigationNotificationSpy.new()
    # Intake is real. Worker/renderer completion is intentionally outside this
    # bounded contract, so no physics/process frames are used for acceptance.
    instance.tree_publication_queue.set_process(false)
    return instance

func queued_requests(fixture) -> Array:
    var requests := []
    for task in fixture.tree_publication_queue.pending_tasks.values():
        requests.append(task.request.duplicate(true))
    return requests

func body_facts(body) -> Dictionary:
    if body == null:
        return {}
    var metadata := {}
    for key in body.get_meta_list():
        metadata[key] = body.get_meta(key)
    # Queue intake stamps wall-clock readiness, not deterministic tree content.
    metadata.erase("tree_collision_ready_usec")
    var collider: CollisionShape3D = body.get_child(0)
    return {"metadata": metadata, "position": body.position, "rotation": body.rotation,
        "radius": collider.shape.radius, "height": collider.shape.height, "center": collider.position,
        "trunkGroup": body.is_in_group("generated_tree_trunks")}

func run_contract() -> void:
    var source := FileAccess.get_file_as_string(MAIN_PATH)
    var project := ProjectSettings.globalize_path("res://")
    var baseline_output := []
    var baseline_exit := OS.execute("git", ["-C", project, "show", BASELINE_REVISION + ":scripts/MainPlaytestTools.gd"], baseline_output)
    check("baseline_source_available", baseline_exit == 0 and not baseline_output.is_empty())
    if baseline_exit != 0 or baseline_output.is_empty():
        finish()
        return
    var baseline := String(baseline_output[0])
    for name in ["tree_visual_spec", "tree_runtime_spec_for_prop", "resolve_player_tree_publication_overlap", "natural_tree_blocked_at_cell"]:
        check("unchanged_source_" + name, function_source(source, name) == function_source(baseline, name))
    var old_make := function_source(baseline, "make_tree")
    var new_make := function_source(source, "make_tree")
    check("ordinary_preparation_exclusion_source_unchanged", old_make.substr(0, old_make.find("    var body :=")) == new_make.substr(0, new_make.find("    return _publish_tree_body")))
    var shared := function_source(source, "_publish_tree_body")
    var shared_body := shared.substr(shared.find("    var body :=")).replace("    if resolve_player_overlap:\n        resolve_player_tree_publication_overlap(body)", "    resolve_player_tree_publication_overlap(body)")
    check("body_publication_extracted_without_copy_or_rewrite", shared_body == old_make.substr(old_make.find("    var body :=")))
    var prepared_source := function_source(source, "make_tree_from_runtime_request")
    check("prepared_uses_shared_path_no_ecology_or_relocation", prepared_source.contains("_publish_tree_body(") and not prepared_source.contains("tree_runtime_spec_for_prop(") and not prepared_source.contains("tree_visual_spec(") and not prepared_source.contains("resolve_player_tree_publication_overlap("))
    # Compile the actual production inheritance chain too; isolated extraction
    # alone cannot catch an interface signature or full-script parse failure.
    check("production_script_loads", load(MAIN_PATH) != null)
    var before = harness(baseline, false)
    var after = harness(source, true)
    if before == null or after == null:
        finish()
        return
    for biome in ["forest", "taiga", "snow", "savanna", "town"]:
        for blocked in [false, true]:
            before.exclusion_blocked = blocked
            after.exclusion_blocked = blocked
            var rng_before := RandomNumberGenerator.new()
            var rng_after := RandomNumberGenerator.new()
            rng_before.seed = 927461
            rng_after.seed = rng_before.seed
            var id := "%s-%s" % [biome, blocked]
            var old_body = before.make_tree(before, id, Vector3(11, 4, 8), biome, rng_before, Vector2i(8, 13))
            var new_body = after.make_tree(after, id, Vector3(11, 4, 8), biome, rng_after, Vector2i(8, 13))
            check("ordinary_exact_rng_spec_body_queue_" + id, rng_before.state == rng_after.state and before.visual_specs == after.visual_specs and before.exclusions == after.exclusions and body_facts(old_body) == body_facts(new_body) and queued_requests(before) == queued_requests(after) and before.overlap_calls == after.overlap_calls and before.npc_system.created_ids == after.npc_system.created_ids)
    before.biome_environment_catalog = null
    after.biome_environment_catalog = null
    var fallback_rng_before := RandomNumberGenerator.new()
    var fallback_rng_after := RandomNumberGenerator.new()
    fallback_rng_before.seed = 81
    fallback_rng_after.seed = 81
    var old_fallback = before.make_tree(before, "fallback", Vector3.ZERO, "forest", fallback_rng_before)
    var new_fallback = after.make_tree(after, "fallback", Vector3.ZERO, "forest", fallback_rng_after)
    check("ordinary_no_catalog_and_unspecified_cell_unchanged", fallback_rng_before.state == fallback_rng_after.state and body_facts(old_fallback) == body_facts(new_fallback) and before.visual_specs == after.visual_specs and before.fallback_calls == 1 and after.fallback_calls == 1 and before.exclusions == after.exclusions)
    before.free()
    after.free()
    test_prepared(source)
    test_detached_queue_lifecycle()
    finish()

func test_detached_queue_lifecycle() -> void:
    # Synthetic lifecycle contract using real queue intake and scene membership.
    # No workers, automatic processing, or gameplay acceptance in this fixture.
    var queue = load("res://scripts/environment/TreePublicationQueue.gd").new()
    get_root().add_child(queue)
    queue.set_process(false)
    var viewer := CharacterBody3D.new()
    get_root().add_child(viewer)
    queue.set_viewer(viewer)
    var parent := Node3D.new()
    var body := StaticBody3D.new()
    parent.add_child(body)
    var records: Array = ComposerScript.build_tree_placement_records([Vector3.ZERO], 72819)
    var request: Dictionary = records[0].treeRequest.duplicate(true)
    request.treeWorldPosition = Vector3.ZERO
    request.publicationPriority = 0.0
    check("detached_queue_intake_retained", queue.enqueue(body, request) and queue.pending_tasks.size() == 1)
    var task: Dictionary = queue.pending_tasks.values()[0]
    queue.refresh_collision_visibility_proxies()
    check("detached_body_not_live_collision_without_cancelling_task", not queue.body_is_collision_visibility_relevant(body) and not queue.body_is_collision_visible(body) and queue._publication_body(task) == body and queue.pending_tasks.size() == 1 and queue.cancelled_count == 0)
    get_root().add_child(parent)
    queue.refresh_collision_visibility_proxies()
    check("reattached_near_body_gets_collision_visibility_proxy", queue.body_is_collision_visibility_relevant(body) and queue.body_is_collision_visible(body) and body.get_node_or_null("TreeVisibilityProxy") != null)
    queue.remember_published_lod(body, task.request)
    parent.remove_child(body)
    queue.refresh_collision_visibility_proxies()
    queue.refresh_published_lods()
    check("parentless_detach_retains_lod_and_pending_recipe", queue.published_lod_records.size() == 1 and queue.pending_tasks.size() == 1 and queue._publication_body(task) == body and not queue.body_is_collision_visible(body))
    check("detached_pending_task_not_retiered", not queue.retier_task_for_current_viewer(task, body))
    parent.add_child(body)
    queue.refresh_published_lods()
    check("reattached_lod_and_visibility_resume_without_duplicate_request", queue.published_lod_records.size() == 1 and queue.pending_tasks.size() == 1 and queue.body_is_collision_visible(body))
    queue.set_viewer_motion_snapshot(Vector3.ZERO, Vector3.FORWARD, Vector3.FORWARD)
    get_root().remove_child(viewer)
    check("detached_viewer_invalidates_cached_live_position", queue.current_viewer_position() == Vector3.INF)
    queue.refresh_viewer_motion_snapshot()
    queue.refresh_collision_visibility_proxies()
    queue.refresh_published_lods()
    queue.selected_lod_tier(request)
    queue.effective_priority(task, Time.get_ticks_usec())
    queue.highest_priority_pending_sequence()
    check("detached_viewer_queries_preserve_retryable_queue", queue.viewer_motion_snapshot.is_empty() and queue.pending_tasks.size() == 1 and queue.cancelled_count == 0)
    get_root().add_child(viewer)
    check("reattached_viewer_resumes_live_queries", queue.current_viewer_position() == viewer.global_position and queue.body_is_collision_visibility_relevant(body))
    # A preassembled visual isolates publication ownership from recipe workers.
    # Parentless preparation may finish locally; reattachment makes it visible.
    var prepared_body := StaticBody3D.new()
    var visual := Node3D.new()
    visual.name = "GeneratedTreeVisual"
    var wood_root := Node3D.new()
    visual.add_child(wood_root)
    queue.enqueue_completed_task({"body": weakref(prepared_body), "request": task.request, "recipe": {}, "visual": visual, "woodRoot": wood_root, "renderStage": "commit"})
    for _attempt in range(4):
        if not queue.has_completed_tasks():
            break
        queue.publish_completed_recipes()
    check("parentless_prepared_visual_not_discarded", queue.cancelled_count == 0 and prepared_body.get_node_or_null("GeneratedTreeVisual") == visual and not queue.body_is_collision_visible(prepared_body))
    parent.add_child(prepared_body)
    check("reattached_prepared_visual_becomes_visible", queue.body_is_collision_visible(prepared_body))
    queue.cancel_body_publication(body)
    check("explicit_cancellation_still_invalidates_body", queue._publication_body(task) == null)
    queue.free()
    parent.free()
    viewer.free()

func test_prepared(source: String) -> void:
    var fixture = harness(source, true)
    if fixture == null:
        return
    var parent := Node3D.new()
    parent.position = Vector3(140, 17, -80)
    parent.rotation.y = 0.71
    fixture.add_child(parent)
    # Read the existing source recipe as a consumer. No building-source edits or
    # alternate sampler: the exact returned dictionary enters the generic API.
    var records: Array = ComposerScript.build_tree_placement_records([Vector3(8, 0, 6), Vector3(-4, 0, 9)], 72819)
    check("existing_source_has_requests", records.size() == 2 and records[1] is Dictionary and records[1].has("treeRequest"))
    if records.size() != 2 or not records[1] is Dictionary:
        fixture.free()
        return
    var record: Dictionary = records[1]
    var request: Dictionary = record.treeRequest
    var original := request.duplicate(true)
    var original_record := record.duplicate(true)
    fixture.exclusion_blocked = true
    # Request generation is forbidden after the source has produced its request.
    fixture.biome_environment_catalog = null
    var body_id := "durable-structure-tree-id"
    var outcome: Dictionary = fixture.make_tree_from_runtime_request(parent, body_id, record.position, "town", request, record.rotationY)
    check("prepared_publishes", outcome.status == "published" and outcome.body != null)
    if outcome.body == null:
        fixture.free()
        return
    var body: StaticBody3D = outcome.body
    var facts := body_facts(body)
    var queued: Array = queued_requests(fixture)
    var expected := original.duplicate(true)
    expected.worldPosition = parent.to_global(record.position)
    expected.worldRotationY = parent.global_basis.get_euler().y + record.rotationY
    expected.treeWorldPosition = body.global_position
    expected.publicationPriority = INF
    expected.renderLodTier = "near"
    check("source_record_and_request_immutable", request == original and record == original_record)
    check("queue_preserves_exact_recipe_except_explicit_world_binding", queued.size() == 1 and queued[0] == expected)
    # Godot physics shape properties are float32; request/metadata remain exact.
    check("dimensions_genetics_yaw_and_world_transform_exact", is_equal_approx(facts.radius, request.trunkRadius) and is_equal_approx(facts.height, request.collisionHeight) and body.get_meta("tree_visual_height") == request.visualHeight and body.get_meta("tree_canopy_radius") == request.canopyRadius and body.get_meta("tree_genetic_seed") == request.geneticSeed and body.global_position.is_equal_approx(expected.worldPosition) and body.basis.is_equal_approx(Basis(Vector3.UP, record.rotationY)))
    check("durable_id_harvest_and_recipe_identity_separate", body.get_meta("prop_id") == body_id and body.get_meta("drop") == "logs" and body.get_meta("drop_count") == 3 and queued[0].treeId == request.treeId and queued[0].worldSeed == request.worldSeed)
    check("prepared_no_ecology_exclusion_fallback_or_relocation", fixture.exclusions.is_empty() and fixture.tree_runtime_request_builder == null and fixture.fallback_calls == 0 and fixture.overlap_calls == 0)
    check("prepared_notifies_existing_navigation_hook_once", fixture.npc_system.created_ids == [body_id])
    var player := CharacterBody3D.new()
    fixture.add_child(player)
    player.global_position = body.global_position
    player.velocity = Vector3(1, 2, 3)
    fixture.player = player
    var player_position := player.global_position
    var child_count := parent.get_child_count()
    var pending_count := queued.size()
    var deferred: Dictionary = fixture.make_tree_from_runtime_request(parent, "retry-tree", record.position, "town", request, record.rotationY)
    check("overlap_defers_before_body_queue_and_durable_effects", deferred.status == "deferred" and deferred.reason == "player_overlap" and parent.get_child_count() == child_count and queued_requests(fixture).size() == pending_count and fixture.removed_props.is_empty() and player.global_position == player_position and player.velocity == Vector3(1, 2, 3) and fixture.npc_system.created_ids == [body_id])
    # Service fixture setup only, not movement or overlap-relocation acceptance.
    fixture.player = null
    var retry: Dictionary = fixture.make_tree_from_runtime_request(parent, "retry-tree", record.position, "town", request, record.rotationY)
    check("owner_can_retry_identical_request", retry.status == "published" and request == original)
    fixture.removed_props["removed-tree"] = true
    var removed_snapshot: Dictionary = fixture.removed_props.duplicate(true)
    var removed: Dictionary = fixture.make_tree_from_runtime_request(parent, "removed-tree", record.position, "town", request, record.rotationY)
    check("durable_removal_skips_without_writing_save_delta", removed.status == "skipped" and removed.reason == "removed_prop" and fixture.removed_props == removed_snapshot)
    var invalid := request.duplicate(true)
    invalid.trunkRadius = 0.01
    var rejected: Dictionary = fixture.make_tree_from_runtime_request(parent, "invalid-tree", record.position, "town", invalid, record.rotationY)
    check("unsupported_dimensions_rejected_not_clamped", rejected.status == "rejected" and rejected.reason == "unsupported_dimensions")
    var malformed := request.duplicate(true)
    malformed.collisionHeight = NAN
    var nonfinite: Dictionary = fixture.make_tree_from_runtime_request(parent, "nan-tree", record.position, "town", malformed, record.rotationY)
    check("nonfinite_dimensions_rejected", nonfinite.status == "rejected" and nonfinite.reason == "invalid_dimensions")
    var empty: Dictionary = fixture.make_tree_from_runtime_request(parent, "empty-tree", record.position, "town", {}, record.rotationY)
    check("empty_request_rejected_without_fallback", empty.status == "rejected" and empty.reason == "invalid_runtime_request" and fixture.fallback_calls == 0)
    var missing_parent: Dictionary = fixture.make_tree_from_runtime_request(null, "pending-tree", record.position, "town", request, record.rotationY)
    check("missing_parent_explicitly_retryable", missing_parent.status == "deferred" and missing_parent.reason == "parent_not_ready")
    parent.scale = Vector3.ONE * 2.0
    var scaled: Dictionary = fixture.make_tree_from_runtime_request(parent, "scaled-tree", record.position, "town", request, record.rotationY)
    check("scaled_parent_rejected_not_double_scaled", scaled.status == "rejected" and scaled.reason == "parent_not_rigid_upright")
    check("all_skips_and_rejections_leave_no_partial_publication", parent.get_child_count() == child_count + 1 and queued_requests(fixture).size() == pending_count + 1 and fixture.npc_system.created_ids == [body_id, "retry-tree"] and fixture.removed_props == removed_snapshot and request == original)
    fixture.free()

func finish() -> void:
    var passed := not results.is_empty()
    for result in results:
        passed = passed and bool(result.passed)
    var report := {"passed": passed, "complete": true, "evidenceLevel": "headless_source_service_contract",
        "baselineRevision": BASELINE_REVISION, "sourceRecipeSeed": 72819, "checks": results,
        "limitations": ["No live hookup, headed gameplay, collision traversal, harvest/save round-trip, NPC navigation or performance acceptance.", "Production functions execute in an extracted harness with overlap-resolution and navigation-notification spies; ordinary baseline is compared against pinned pre-extraction commit 11cf54b.", "Queue lifecycle checks use detached/reattached nodes and a synthetic preassembled visual with automatic processing disabled; recipe worker completion and screenshots are not tested."]}
    var path := OS.get_environment("VOXEL_PREPARED_TREE_CONTRACT_REPORT")
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write contract report: " + path)
        quit(2)
        return
    file.store_string(JSON.stringify(report, "\t"))
    file.close()
    print("PREPARED_TREE_CONTRACT ", "PASS" if passed else "FAIL", " checks=", results.size())
    quit(0 if passed else 1)
