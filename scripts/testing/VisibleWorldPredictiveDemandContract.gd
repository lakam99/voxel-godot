extends SceneTree

const ControllerScript := preload("res://scripts/world/VisibleWorldDemandController.gd")
const TerrainManifestScript := preload("res://scripts/world/VoxelTerrainVisualManifest.gd")
const ReadinessScript := preload("res://scripts/world/VisibleWorldReadiness.gd")
const REPORT_ENV := "VOXEL_VISIBLE_PREDICTIVE_DEMAND_REPORT"

class TerrainRuntime extends RefCounted:
	var revision := "mock-world-1"
	func visible_mesh_source_identity() -> String: return "mock-native-source"
	func visible_mesh_world_revision() -> String: return revision
	func visible_mesh_source_revision(_block: Vector3i) -> String: return "mock-block-1"
	func visible_mesh_vertical_bounds() -> Vector2i: return Vector2i(0, 16)
	func visible_mesh_area_complete(_block: Vector3i) -> bool: return false
	func visible_mesh_block_has_geometry(_block: Vector3i) -> bool: return true
	func visible_mesh_receipt_is_current() -> bool: return false

class TerrainWork extends RefCounted:
	var revisit_count := 0
	func advance(_budget: int) -> Dictionary:
		return {"status": "ready", "pendingBlocks": 0}
	func needs_advance() -> bool: return false
	func revisit_candidate(_source_id: String, _candidate_id: String) -> bool:
		revisit_count += 1
		return true

class Ledger extends RefCounted:
	var full_bounds := Rect2i()
	var full_ready := false
	var full_queries := 0
	var stale_terrain_pending := false
	func region_readiness(_request_id: int, _seed: String, _world_revision: String,
			_view_revision: int, bounds: Rect2i) -> Dictionary:
		if bounds == full_bounds:
			full_queries += 1
			return {"status": "ready" if full_ready else "pending",
				"reason": "" if full_ready else "far_candidate_unrepresented",
				"byKind": {"terrain": {"pending": 1 if stale_terrain_pending else 0}}}
		return {"status": "ready", "reason": ""}
	func record_queue_diagnostics(_depth: int, _lag: float) -> void: pass
	func pending_candidate_diagnostics(_request_id: int, _seed: String,
			_world_revision: String, _view_revision: int, _bounds: Rect2i,
			_limit: int) -> Array[Dictionary]:
		if not stale_terrain_pending: return []
		return [{"kind": "terrain", "sourceId": "terrain-mesh:4,1,0",
			"candidateId": "terrain:4,1,0"}]

class HorizonPublisher extends RefCounted:
	var installed := true
	func visual_receipt_installed(_source_identity: String, _source_revision: String,
			_world_revision: String, _view_revision: int, _candidate_id: String,
			_metadata: Dictionary, _representation_id: String, _tier: String) -> bool:
		return installed

var checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_early_all_direction_demand()
	_test_full_view_promotion()
	_test_unsubmitted_chunk_sources_do_not_complete_view()
	_test_stale_native_receipt_without_signal()
	_test_bounded_chunk_diagnostics()
	_test_retained_chunk_keys()
	await _test_tree_receipt_handoff_across_views()
	var passed := true
	for check: Dictionary in checks:
		passed = passed and bool(check.passed)
	var report := {"schema": "visible-world-predictive-demand-contract/v1",
		"evidenceLevel": "synthetic_controller_contract", "passed": passed,
		"checkCount": checks.size(), "checks": checks,
		"scope": "Controller demand timing, full-view promotion and bounded diagnostics with fake publishers; no live ecology, native meshing or gameplay visual acceptance."}
	var report_path := OS.get_environment(REPORT_ENV)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Predictive demand report write failed")
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if passed else 1)

func _test_early_all_direction_demand() -> void:
	var controller = ControllerScript.new()
	var runtime := TerrainRuntime.new()
	var main := RefCounted.new()
	var old_ledger := Ledger.new()
	var current := {"ledger": old_ledger, "terrain": TerrainWork.new(),
		"requestId": 7, "seed": "pinned", "worldRevision": "mock-world-1",
		"viewRevision": 1, "demandRevision": 1,
		"center": Vector2.ZERO, "radius": 20.0,
		"bounds": Rect2i(-20, -20, 41, 41),
		"nearBounds": Rect2i(-30, -30, 60, 60)}
	controller._owners["player"] = {"current": current, "pending": {}}
	var near := Rect2i(9, -2, 4, 4)
	var before: Dictionary = controller.ensure(main, runtime, "player", 7,
		"pinned", "mock-world-1", Vector3(11, 0, 0), near, 20.0, 1.0, 4)
	_check("eleven_cell_lag_keeps_current", before.status == "ready"
		and (controller._owners.player.pending as Dictionary).is_empty())
	near = Rect2i(10, -2, 4, 4)
	var after: Dictionary = controller.ensure(main, runtime, "player", 7,
		"pinned", "mock-world-1", Vector3(12, 0, 0), near, 20.0, 1.0, 4)
	var state: Dictionary = controller._owners.player
	var pending: Dictionary = state.pending
	_check("twelve_cell_lag_starts_pending_without_replacing_current",
		after.status == "pending" and not pending.is_empty()
		and is_same((state.current as Dictionary).ledger, old_ledger))
	_check("predicted_view_keeps_configured_radius_and_all_directions",
		pending.get("radius", 0.0) == 20.0 and pending.get("center", Vector2.INF) == Vector2(12, 0)
		and pending.get("bounds", Rect2i()) == Rect2i(-8, -20, 41, 41)
		and pending.get("bounds", Rect2i()).has_point(Vector2i(12, -20))
		and pending.get("bounds", Rect2i()).has_point(Vector2i(12, 20))
		and pending.get("bounds", Rect2i()).has_point(Vector2i(-8, 0))
		and pending.get("bounds", Rect2i()).has_point(Vector2i(32, 0)))
	_check("predictive_demand_does_not_claim_source_ready",
		controller.full_view_readiness("player", 7, "pinned", "mock-world-1").status == "pending")

func _test_full_view_promotion() -> void:
	var controller = ControllerScript.new()
	var runtime := TerrainRuntime.new()
	var main := RefCounted.new()
	var structures := RefCounted.new()
	var old_ledger := Ledger.new()
	var next_ledger := Ledger.new()
	var full := Rect2i(-20, -20, 41, 41)
	var near := Rect2i(-4, -4, 8, 8)
	var empty_keys: Array[Vector2i] = []
	next_ledger.full_bounds = full
	var pending := {"ledger": next_ledger, "terrain": TerrainWork.new(),
		"requestId": 8, "seed": "pinned", "worldRevision": "mock-world-1",
		"viewRevision": 2, "demandRevision": 2, "bounds": full,
		"nearBounds": near, "center": Vector2.ZERO, "centerWorld": Vector3.ZERO,
		"chunkKeys": empty_keys, "propCursor": 0, "structureCursor": 0,
		"propSources": {}, "structureSources": {}, "missingChunkSources": {},
		"dirtyChunkKeys": [], "lastProp": {}, "lastStructure": {}, "overlapLedgers": []}
	controller._owners["player"] = {"current": {"ledger": old_ledger}, "pending": pending}
	var near_probe: Dictionary = next_ledger.region_readiness(8, "pinned", "mock-world-1", 2, near)
	var first: Dictionary = controller.advance(main, runtime, structures, "player", 4)
	var state: Dictionary = controller._owners.player
	_check("near_only_ready_cannot_promote", near_probe.status == "ready"
		and first.status == "pending" and first.reason == "far_candidate_unrepresented"
		and is_same((state.current as Dictionary).ledger, old_ledger)
		and not (state.pending as Dictionary).is_empty())
	next_ledger.full_ready = true
	var second: Dictionary = controller.advance(main, runtime, structures, "player", 4)
	state = controller._owners.player
	_check("full_view_receipts_promote_pending", second.status == "ready"
		and is_same((state.current as Dictionary).ledger, next_ledger)
		and (state.pending as Dictionary).is_empty() and next_ledger.full_queries >= 2)
	next_ledger.full_ready = false
	var invalidated: Dictionary = controller.advance(main, runtime, structures, "player", 4)
	_check("current_ready_requires_fresh_full_receipts", invalidated.status == "pending"
		and invalidated.reason == "far_candidate_unrepresented")
	runtime.revision = "mock-world-2"
	next_ledger.full_ready = true
	var changed: Dictionary = controller.advance(main, runtime, structures, "player", 4)
	_check("changed_world_cannot_borrow_old_full_receipts", changed.status == "pending"
		and changed.reason == "visual_world_revision_changed"
		and (controller._owners.player.current as Dictionary).is_empty())


func _test_unsubmitted_chunk_sources_do_not_complete_view() -> void:
	var controller = ControllerScript.new()
	var ledger := Ledger.new()
	var bounds := Rect2i(-20, -20, 41, 41)
	var chunk_key := Vector2i.ZERO
	ledger.full_bounds = bounds
	ledger.full_ready = true
	controller.adopt("player", 9, "pinned", "mock-world-1", ledger, 1,
		Vector2.ZERO, 20.0, bounds, Rect2i(-4, -4, 8, 8))
	var adopted: Dictionary = controller.full_view_readiness("player", 9,
		"pinned", "mock-world-1")
	_check("adopted_startup_ledger_cannot_replace_full_source_scan",
		adopted.status == "pending"
		and adopted.reason == "visual_full_view_source_not_started")
	controller._owners["player"] = {"current": {}, "pending": {
		"ledger": ledger, "terrain": TerrainWork.new(),
		"requestId": 9, "seed": "pinned",
		"worldRevision": "mock-world-1", "viewRevision": 1,
		"demandRevision": 2, "bounds": bounds,
		"chunkKeys": [chunk_key], "propSources": {},
		"structureSources": {chunk_key: true},
		"publicationComplete": false}}
	var incomplete: Dictionary = controller.full_view_readiness("player", 9,
		"pinned", "mock-world-1")
	_check("unsubmitted_chunk_source_cannot_make_full_view_ready",
		incomplete.status == "pending"
		and incomplete.reason == "visual_source_publication_pending"
		and int(incomplete.get("pendingChunkSourceCount", -1)) == 1)
	var view: Dictionary = controller._owners.player.pending
	view.propSources[chunk_key] = true
	view.publicationComplete = true
	var complete: Dictionary = controller.full_view_readiness("player", 9,
		"pinned", "mock-world-1")
	_check("submitted_chunk_sources_allow_receipt_validation",
		complete.status == "ready")

func _test_bounded_chunk_diagnostics() -> void:
	var controller = ControllerScript.new()
	var keys: Array[Vector2i] = []
	var missing := {}
	for x in range(12):
		var key := Vector2i(x, 0)
		keys.append(key)
		if x > 1: missing[key] = true
	controller._owners["player"] = {"current": {}, "pending": {
		"chunkKeys": keys, "propSources": {Vector2i(0, 0): true},
		"missingChunkSources": missing}}
	var pending_keys: Array[Vector2i] = controller.pending_chunk_source_keys("player", 3)
	var missing_keys: Array[Vector2i] = controller.missing_chunk_source_keys("player", 3)
	_check("pending_keys_follow_bounded_source_order",
		pending_keys == [Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)])
	_check("missing_keys_are_bounded_and_deterministic",
		missing_keys == [Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0)])
	_check("zero_diagnostic_limit_returns_no_keys",
		controller.pending_chunk_source_keys("player", 0).is_empty()
		and controller.missing_chunk_source_keys("player", 0).is_empty())

func _test_retained_chunk_keys() -> void:
	var controller = ControllerScript.new()
	var current_keys: Array[Vector2i] = [Vector2i(2, 0), Vector2i(0, 0)]
	var pending_keys: Array[Vector2i] = [Vector2i(1, 0), Vector2i(2, 0)]
	controller._owners["player"] = {"current": {
		"chunkKeys": current_keys, "publicationComplete": true}, "pending": {
		"chunkKeys": pending_keys, "publicationComplete": false}}
	_check("retained_keys_include_accepted_and_pending_views",
		controller.retained_chunk_keys("player") == [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)])
	controller._owners.player.pending = {}
	_check("retained_keys_survive_publication_completion",
		controller.retained_chunk_keys("player") == [Vector2i(0, 0), Vector2i(2, 0)]
		and controller.ranked_chunk_keys("player").is_empty())
	controller._owners.player.current.dirtyChunkKeys = [Vector2i(2, 0)]
	_check("completed_view_retries_dirty_far_source",
		controller.ranked_chunk_keys("player") == [Vector2i(2, 0)]
		and controller.retained_chunk_keys("player") == [Vector2i(0, 0), Vector2i(2, 0)])
	controller._owners.player.current = {"chunkKeys": pending_keys, "publicationComplete": true}
	_check("retained_keys_retire_superseded_view_only_after_rebase",
		controller.retained_chunk_keys("player") == [Vector2i(1, 0), Vector2i(2, 0)])

func _test_stale_native_receipt_without_signal() -> void:
	var block := Vector3i(4, 1, 0)
	var manifest = TerrainManifestScript.new()
	var blocks: Array[Vector3i] = [block]
	manifest._active = true
	manifest._blocks = blocks
	manifest._block_indices = {block: 0}
	manifest._completed_blocks = {block: "represented"}
	manifest._represented_blocks = 1
	_check("completed_native_block_starts_without_revisit", not manifest.needs_advance())
	var admitted: bool = manifest.revisit_candidate("terrain-mesh:4,1,0", "terrain:4,1,0")
	_check("exact_stale_receipt_reopens_native_block_without_signal", admitted
		and manifest.needs_advance() and manifest._completed_blocks.is_empty()
		and manifest._represented_blocks == 0 and manifest._revisit_blocks == [block])
	var duplicate: bool = manifest.revisit_candidate("terrain-mesh:4,1,0", "terrain:4,1,0")
	_check("repeat_stale_receipt_keeps_single_revisit", duplicate
		and manifest._revisit_blocks == [block] and manifest._represented_blocks == 0)
	_check("unrelated_or_malformed_candidate_cannot_dirty_native_block",
		not manifest.revisit_candidate("terrain-mesh:4,1,1", "terrain:4,1,0")
		and not manifest.revisit_candidate("terrain-mesh:bad", "terrain:bad"))
	var controller = ControllerScript.new()
	var runtime := TerrainRuntime.new()
	var main := RefCounted.new()
	var structures := RefCounted.new()
	var ledger := Ledger.new()
	var work := TerrainWork.new()
	ledger.full_bounds = Rect2i(-20, -20, 41, 41)
	ledger.stale_terrain_pending = true
	var empty_keys: Array[Vector2i] = []
	controller._owners["player"] = {"current": {
		"ledger": ledger, "terrain": work, "requestId": 9, "seed": "pinned",
		"worldRevision": "mock-world-1", "viewRevision": 3, "demandRevision": 3,
		"bounds": ledger.full_bounds, "nearBounds": Rect2i(-4, -4, 8, 8),
		"center": Vector2.ZERO, "centerWorld": Vector3.ZERO,
		"chunkKeys": empty_keys, "propCursor": 0, "structureCursor": 0,
		"propSources": {}, "structureSources": {}, "missingChunkSources": {},
		"dirtyChunkKeys": [], "lastProp": {}, "lastStructure": {},
		"publicationComplete": true}, "pending": {}}
	var result: Dictionary = controller.advance(main, runtime, structures, "player", 4)
	_check("controller_requeues_exact_stale_terrain_receipt", result.status == "pending"
		and work.revisit_count > 0 and is_same(controller._owners.player.current.ledger, ledger))

func _test_tree_receipt_handoff_across_views() -> void:
	var source_id := "chunk-props:pinned:-3,0:trees_foliage"
	var candidate_id := "pinned:-59,3:1"
	var bounds := Rect2i(-61, 1, 5, 5)
	var source_bounds := Rect2i(-84, 0, 28, 28)
	var publisher := HorizonPublisher.new()
	var chunk := Node3D.new()
	root.add_child(chunk)
	var body := StaticBody3D.new()
	body.set_meta("prop_id", candidate_id)
	body.set_meta("tree_visual_state", "queued")
	body.set_meta("tree_render_lod_tier", "far")
	chunk.add_child(body)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	body.add_child(visual)
	await process_frame
	var current = _tree_handoff_ledger(source_id, candidate_id, bounds,
		source_bounds, publisher, body)
	var pending = _tree_handoff_ledger(source_id, candidate_id, bounds,
		source_bounds, publisher, body)
	var before_current: Dictionary = current.region_readiness(21, "pinned",
		"mock-world-1", 1, bounds)
	var before_pending: Dictionary = pending.region_readiness(21, "pinned",
		"mock-world-1", 1, bounds)
	_check("tree_horizon_receipt_previously_represented_in_both_views",
		before_current.status == "ready" and before_pending.status == "ready"
		and int(before_current.representedCount) == 1
		and int(before_pending.representedCount) == 1)
	body.set_meta("tree_visual_state", "published")
	publisher.installed = false
	var stale: Dictionary = current.region_readiness(21, "pinned",
		"mock-world-1", 1, bounds)
	_check("retired_horizon_slot_invalidates_old_receipt",
		stale.status == "pending" and int(stale.pendingCount) == 1
		and int(stale.representedCount) == 0)
	var controller = ControllerScript.new()
	var keys: Array[Vector2i] = [Vector2i(-3, 0)]
	controller._owners["player"] = {"current": {"ledger": current,
		"requestId": 21, "seed": "pinned", "worldRevision": "mock-world-1",
		"viewRevision": 1, "demandRevision": 1, "bounds": bounds,
		"nearBounds": bounds}, "pending": {"ledger": pending,
		"requestId": 21, "seed": "pinned", "worldRevision": "mock-world-1",
		"viewRevision": 1, "demandRevision": 2, "bounds": bounds,
		"nearBounds": bounds, "chunkKeys": keys, "dirtyChunkKeys": []}}
	var replacement := StaticBody3D.new()
	replacement.set_meta("prop_id", candidate_id)
	replacement.set_meta("tree_visual_state", "published")
	replacement.set_meta("tree_render_lod_tier", "far")
	chunk.add_child(replacement)
	var replacement_visual := MeshInstance3D.new()
	replacement_visual.mesh = BoxMesh.new()
	replacement.add_child(replacement_visual)
	var rejected: Dictionary = controller.handoff_published_tree("player",
		Vector2i(-3, 0), replacement)
	_check("tree_handoff_rejects_same_id_replacement_owner",
		rejected.status == "pending" and int(rejected.acceptedViews) == 0
		and current.region_readiness(21, "pinned", "mock-world-1", 1, bounds).status == "pending")
	var handoff: Dictionary = controller.handoff_published_tree("player",
		Vector2i(-3, 0), body)
	var after_current: Dictionary = current.region_readiness(21, "pinned",
		"mock-world-1", 1, bounds)
	var after_pending: Dictionary = pending.region_readiness(21, "pinned",
		"mock-world-1", 1, bounds)
	_check("published_tree_handoff_updates_adopted_and_pending_receipts",
		handoff.status == "ready" and int(handoff.acceptedViews) == 2
		and after_current.status == "ready" and after_pending.status == "ready"
		and int(after_current.representedCount) == 1
		and int(after_pending.representedCount) == 1)
	_check("published_tree_handoff_uses_exact_installed_representation",
		String(current._sources[source_id].candidates[candidate_id].receipt.representationId)
			== "%s:installed" % candidate_id
		and String(pending._sources[source_id].candidates[candidate_id].receipt.representationId)
			== "%s:installed" % candidate_id
		and controller._owners.player.pending.dirtyChunkKeys == keys)
	chunk.queue_free()
	await process_frame

func _tree_handoff_ledger(source_id: String, candidate_id: String, bounds: Rect2i,
		source_bounds: Rect2i, publisher: HorizonPublisher, body: StaticBody3D) -> Object:
	var ledger = ReadinessScript.new()
	ledger.begin_view(21, "pinned", "mock-world-1", bounds, Rect2i(-61, 1, 1, 1),
		Vector2(-59.0, 3.0), 2.0)
	ledger.declare_terrain_mesh_source_set({"terrain:test": bounds}, 1)
	for kind: String in ReadinessScript.CONTENT_KINDS:
		var id := source_id if kind == "trees_foliage" else "%s:test" % kind
		var footprint := source_bounds if kind == "trees_foliage" else bounds
		ledger.expect_source(id, kind, id, "rev:1", footprint, 1)
		if kind == "trees_foliage":
			ledger.describe_candidate(id, candidate_id, "horizon",
				{"positionXZ": Vector2(-59.0, 3.0),
				"horizonBodyInstanceId": body.get_instance_id(),
				"horizonChunkInstanceId": body.get_parent().get_instance_id()})
			ledger.accept_publisher_receipt(id, candidate_id,
				"%s:horizon" % candidate_id, "horizon", id, "rev:1", 1,
				publisher, &"visual_receipt_installed")
		ledger.finish_source(id, id, "rev:1", 1)
	return ledger

func _check(name: String, passed: bool) -> void:
	checks.append({"name": name, "passed": passed})
