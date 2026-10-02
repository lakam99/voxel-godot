extends SceneTree

const ControllerScript := preload("res://scripts/world/VisibleWorldDemandController.gd")
const TerrainManifestScript := preload("res://scripts/world/VoxelTerrainVisualManifest.gd")
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

var checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_early_all_direction_demand()
	_test_full_view_promotion()
	_test_stale_native_receipt_without_signal()
	_test_bounded_chunk_diagnostics()
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

func _check(name: String, passed: bool) -> void:
	checks.append({"name": name, "passed": passed})
