extends SceneTree

const VisualReadinessScript := preload("res://scripts/world/VisibleWorldReadiness.gd")
const ChunkPropManifestScript := preload("res://scripts/world/ChunkPropVisualManifest.gd")
const HorizonEcologySourceScript := preload("res://scripts/world/HorizonEcologySource.gd")
const DetailBatchPublisherScript := preload("res://scripts/world/DetailBatchVisualReceiptPublisher.gd")
const TerrainVisualManifestScript := preload("res://scripts/world/VoxelTerrainVisualManifest.gd")
const StructureVisualManifestScript := preload("res://scripts/world/GeneratedStructureVisualManifest.gd")
const CitadelPlanScript := preload("res://scripts/world/CitadelPublicationPlan.gd")
const TerrainVolumeServiceScript := preload("res://scripts/TerrainVolumeService.gd")
const REPORT_ENV := "VOXEL_VISIBLE_WORLD_READINESS_REPORT"
const BOUNDS := Rect2i(-6, -6, 12, 12)
const NEAR_BOUNDS := Rect2i(-2, -2, 4, 4)
const VIEW_CENTER := Vector2(0.0, 0.0)
const VIEW_RADIUS := 6.0

class ReceiptPublisher extends RefCounted:
	var installed := true
	var validation_count := 0

	func visual_receipt_is_current(source_identity: String, source_revision: String,
		world_revision: String, view_revision: int, candidate_id: String,
		metadata: Dictionary, representation_id: String, tier: String) -> bool:
		validation_count += 1
		return installed and source_identity == "identity:props" and source_revision == "rev:1" \
			and world_revision == "world-3" and view_revision > 0 and candidate_id == "tree:stable-id" \
			and metadata.get("positionXZ") == Vector2(3.0, 1.0) \
			and representation_id == "tree-native-mesh:stable-id" and tier == "horizon"

class BenchmarkPublisher extends RefCounted:
	var installed := true
	var validation_count := 0

	func visual_receipt_is_current(_source_identity: String, _source_revision: String,
			_world_revision: String, _view_revision: int, _candidate_id: String,
			_metadata: Dictionary, _representation_id: String, _tier: String) -> bool:
		validation_count += 1
		return installed

class ScanMain extends "res://scripts/Main.gd":
	func hash01(_text: String) -> float:
		return 0.0

class HorizonMainFixture extends Node:
	var chunks := {}
	var chunk_root: Node3D
	var player: Node3D
	var voxel_terrain_runtime: Object
	var removed_props := {}
	var removed_props_revision := 0
	var world_generation_system: Object
	var visible_world_demand_controller: Object
	var scan_calls := 0

	func begin_chunk_prop_spawn_state(chunk: Node3D, _cx: int, _cz: int) -> Dictionary:
		return {"chunk": chunk}

	func process_chunk_prop_spawn_state(state: Dictionary, _props: int,
			_details: int, _budget_ms: float) -> bool:
		scan_calls += 1
		var chunk: Node3D = state.chunk
		chunk.set_meta("chunk_surface_candidate_scan_complete", true)
		return true

class HorizonPlayerFixture extends Node3D:
	var camera: Camera3D

class HorizonRuntimeFixture extends RefCounted:
	var viewer: Object

class HorizonViewerFixture extends RefCounted:
	var view_distance := 96

class UndergroundScanFixture extends RefCounted:
	var calls := 0
	func begin_exposed_underground_floor_scan(_chunk_key: Vector2i, _chunk_size: int) -> Dictionary:
		return {"revision": 1}
	func advance_exposed_underground_floor_scan(_state: Dictionary, _sample_budget: int,
			_time_budget_ms: float, _budget_start_usec: int) -> Dictionary:
		calls += 1
		var first := Vector3i(-28, -5, 0)
		return {"state": {"revision": calls}, "complete": calls == 2,
			"newCandidates": [first] if calls == 1 else [first, first, Vector3i(-27, -5, 0)],
			"processed": 1, "restarted": calls == 2}

class TerrainPublisherFixture extends RefCounted:
	signal visible_mesh_block_revision_changed(block_position: Vector3i, revision: int)
	var complete := false
	var has_geometry := false
	var block_revision := 1
	var owner_identity := "terrain-fixture-owner"
	var world_revision := "terrain-fixture-world"
	var vertical_bounds := Vector2i(0, 15)
	var block_complete: Dictionary = {}
	var block_geometry: Dictionary = {}
	var block_revisions: Dictionary = {}

	func visible_mesh_source_identity() -> String:
		return owner_identity

	func visible_mesh_world_revision() -> String:
		return world_revision

	func visible_mesh_source_revision(block: Vector3i) -> String:
		return "%s:%d:%d,%d,%d" % [world_revision, int(block_revisions.get(block, block_revision)),
			block.x, block.y, block.z]

	func visible_mesh_vertical_bounds() -> Vector2i:
		return vertical_bounds

	func visible_mesh_area_complete(block: Vector3i) -> bool:
		return bool(block_complete.get(block, complete))

	func visible_mesh_block_has_geometry(block: Vector3i) -> bool:
		return bool(block_geometry.get(block, has_geometry))

	func visible_mesh_receipt_is_current(source_identity: String, source_revision: String,
		current_world_revision: String, _view_revision: int, candidate_id: String,
		metadata: Dictionary, representation_id: String, tier: String) -> bool:
		var block: Vector3i = metadata.get("nativeBlock", Vector3i(-1, -1, -1))
		return visible_mesh_area_complete(block) and visible_mesh_block_has_geometry(block) \
			and source_identity == owner_identity \
			and source_revision == visible_mesh_source_revision(block) \
			and current_world_revision == world_revision \
			and candidate_id == "terrain:%d,%d,%d" % [block.x, block.y, block.z] \
			and representation_id == candidate_id + ":native_mesh" and tier in ["near", "horizon"]

class StructureWorldFixture extends Node:
	var blocks: Dictionary = {}

	func generated_structure_visual_blocks(bounds: Rect2i) -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for cell_value in blocks:
			var cell: Vector3i = cell_value
			if bounds.has_point(Vector2i(cell.x, cell.z)):
				result.append({"cell": cell, "owner": blocks[cell]})
		return result

class StructureReadinessFixture extends RefCounted:
	var physical_status := "ready"
	var description_status := "described"
	var revision := "structure-region-revision-1"
	var citadel_status := "described"
	var citadel_candidates: Array[Dictionary] = []
	var citadel_revision := "citadel-source-1"
	var ordinary_world: Node = null
	var ordinary_status := "described"
	var ordinary_revision := "ordinary-source-1"
	var ordinary_expected: Dictionary = {}
	var ordinary_removed: Dictionary = {}

	func region_publication_readiness(_bounds: Rect2i) -> Dictionary:
		return {"status": physical_status, "reason": "physical_fixture_" + physical_status}

	func region_dependency_requirements(_bounds: Rect2i) -> Dictionary:
		return {"status": description_status, "reason": "source_fixture_" + description_status}

	func region_dependency_revision(_bounds: Rect2i) -> String:
		return revision

	func region_dependency_scheduling_revision(_bounds: Rect2i) -> Array:
		return [revision,{"status":"described","source":"citadel-fixture"}]

	func region_citadel_visual_source(_bounds: Rect2i) -> Dictionary:
		return {"status":citadel_status,"descriptionComplete":citadel_status == "described",
			"reason":"citadel_fixture_" + citadel_status,
			"sourceRevision":citadel_revision,"candidates":citadel_candidates}

	func region_ordinary_visual_source(bounds: Rect2i) -> Dictionary:
		if ordinary_status != "described":
			return {"status":ordinary_status,"reason":"ordinary_fixture_" + ordinary_status}
		var candidates: Array[Dictionary] = []
		var world_blocks: Dictionary = ordinary_world.get("blocks") if is_instance_valid(ordinary_world) else {}
		var expected: Dictionary = ordinary_expected if not ordinary_expected.is_empty() else world_blocks
		for cell_value in expected:
			var cell: Vector3i = cell_value
			if not bounds.has_point(Vector2i(cell.x,cell.z)) or ordinary_removed.has(cell): continue
			var body := world_blocks.get(cell) as Node3D
			var representation: Node3D = StructureVisualManifestScript._visible_renderable(body) \
				if is_instance_valid(body) else null
			candidates.append({"candidateId":"structure-block:%d,%d,%d:stoneBlock" % [cell.x,cell.y,cell.z],
				"positionXZ":Vector2(float(cell.x)+0.5,float(cell.z)+0.5),
				"cell":cell,"owner":body,"representation":representation,
				"installed":is_instance_valid(representation)})
		return {"status":"described","reason":"","sourceRevision":ordinary_revision,
			"sourceCount":1 if not expected.is_empty() else 0,"candidateCount":candidates.size(),
			"candidates":candidates}

class CitadelVisualPublisherFixture extends RefCounted:
	var installed := false

	func visual_receipt_installed(_source_identity: String, _source_revision: String,
			_world_revision: String, _view_revision: int, candidate_id: String,
			metadata: Dictionary, representation_id: String, _tier: String) -> bool:
		return installed and candidate_id == "citadel:site-1:building:wall-1" \
			and String(metadata.get("citadelMemberId","")) == "building:wall-1" \
			and representation_id == "%s:scene:%d" % [candidate_id,get_instance_id()]

var _checks: Array[Dictionary] = []
var _passed := true


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	test_full_view_query_cost_split()
	test_coverage_cache_tracks_source_lifecycle()
	test_empty_manifest_requires_complete_source_coverage()
	test_exact_subregion_coverage_is_independent()
	test_circular_view_coverage_ignores_outside_corner_cells()
	await test_terrain_coverage_uses_admitted_mesh_footprints()
	test_incomplete_discovery_never_reports_empty_ready()
	test_candidate_must_belong_to_declared_source_footprint()
	await test_native_terrain_visual_manifest()
	test_native_terrain_scan_continues_past_pending_block()
	test_native_terrain_overlap_uses_current_installed_source()
	await test_generated_structure_visual_manifest()
	await test_ordinary_structure_visual_completion()
	await test_citadel_visual_member_source()
	test_citadel_visual_member_bucket_query()
	await test_surface_prop_source_completes_before_underground_scan()
	test_underground_floor_scan_revision_restart()
	await test_installed_detail_batch_receipts()
	await test_production_chunk_prop_manifest()
	test_horizon_ecology_owner_lifetime()
	test_horizon_ordinary_visual_range_receipt()
	await test_receipts_are_request_revision_tier_and_installation_bound()
	await test_bounded_overlap_transfer_revalidates_receipts()
	test_candidate_accounting_and_explicit_failure()
	write_report()
	quit(0 if _passed else 1)


func test_full_view_query_cost_split() -> void:
	# A synthetic, live-receipt workload isolates query geometry from owner
	# validation. It is a cost diagnostic, never headed gameplay acceptance.
	var book = VisualReadinessScript.new()
	var bounds := Rect2i(-96, -96, 192, 192)
	var revision := int(book.begin_view(501, "cost-seed", "cost-world", bounds,
		Rect2i(-8, -8, 16, 16), Vector2.ZERO, 96.0).viewRevision)
	book.declare_terrain_mesh_source_set({"cost:terrain": bounds}, revision)
	book.expect_source("cost:terrain", "terrain", "cost-terrain-owner", "cost-rev-1",
		bounds, revision)
	var publisher := BenchmarkPublisher.new()
	for z in range(-20, 20):
		for x in range(20, 50):
			var candidate_id := "cost-terrain:%d,%d" % [x, z]
			var metadata := {"positionXZ": Vector2(float(x) + 0.5, float(z) + 0.5)}
			book.describe_candidate("cost:terrain", candidate_id, "horizon", metadata)
			book.accept_publisher_receipt("cost:terrain", candidate_id, candidate_id,
				"horizon", "cost-terrain-owner", "cost-rev-1", revision, publisher,
				&"visual_receipt_is_current")
	book.finish_source("cost:terrain", "cost-terrain-owner", "cost-rev-1", revision)
	for kind: String in ["structures", "trees_foliage", "props", "wildlife"]:
		for tile_z in range(-3, 4):
			for tile_x in range(-3, 4):
				var source_id := "cost:%s:%d,%d" % [kind, tile_x, tile_z]
				var footprint := Rect2i(tile_x * 32, tile_z * 32, 32, 32)
				book.expect_source(source_id, kind, source_id, "cost-rev-1", footprint, revision)
				book.finish_source(source_id, source_id, "cost-rev-1", revision)
	var geometry_usecs: Array[int] = []
	var receipt_usecs: Array[int] = []
	var last: Dictionary = {}
	for _sample in 12:
		last = book.region_readiness(501, "cost-seed", "cost-world", revision, bounds)
		geometry_usecs.append(int(last.get("coverageGeometryUsec", -1)))
		receipt_usecs.append(int(last.get("receiptValidationUsec", -1)))
	geometry_usecs.sort()
	receipt_usecs.sort()
	_check("full_view_query_reports_geometry_and_live_receipt_costs",
		last.get("status") == "ready" and int(last.get("candidateCount", 0)) == 1200
		and geometry_usecs[11] > 0 and receipt_usecs[11] > 0
		and int((last.get("receiptValidationByKindUsec", {}) as Dictionary).get("terrain", 0)) > 0
		and publisher.validation_count == 1200 * 13,
		{"samples": 12, "geometryP50Usec": geometry_usecs[6],
			"geometryP95Usec": geometry_usecs[11],
			"receiptP50Usec": receipt_usecs[6],
			"receiptP95Usec": receipt_usecs[11],
			"receiptValidationCount": publisher.validation_count})
	publisher.installed = false
	var validation_count_before := publisher.validation_count
	var retired: Dictionary = book.region_readiness(501, "cost-seed", "cost-world",
		revision, bounds)
	_check("cached_coverage_still_revalidates_all_live_receipts",
		retired.get("status") == "pending" and int(retired.get("pendingCount", 0)) == 1200
		and publisher.validation_count == validation_count_before + 1200,
		{"status": retired.get("status"), "pendingCount": retired.get("pendingCount"),
			"validationCount": publisher.validation_count})


func test_coverage_cache_tracks_source_lifecycle() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(502, "cache-seed", "cache-world",
		BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	_declare_sources(book, revision, BOUNDS, "props")
	var missing: Dictionary = book.region_readiness(502, "cache-seed", "cache-world",
		revision, BOUNDS)
	book.expect_source("cache:props", "props", "cache-owner", "rev-1", BOUNDS, revision)
	var incomplete: Dictionary = book.region_readiness(502, "cache-seed", "cache-world",
		revision, BOUNDS)
	book.finish_source("cache:props", "cache-owner", "rev-1", revision)
	var complete: Dictionary = book.region_readiness(502, "cache-seed", "cache-world",
		revision, BOUNDS)
	_check("coverage_cache_updates_from_missing_to_complete_source",
		missing.get("status") == "pending" and incomplete.get("status") == "pending"
		and complete.get("status") == "ready")
	book.fail_source("cache:props", "source_retired")
	var failed: Dictionary = book.region_readiness(502, "cache-seed", "cache-world",
		revision, BOUNDS)
	book.expect_source("cache:props", "props", "cache-owner", "rev-2", BOUNDS, revision)
	var replaced: Dictionary = book.region_readiness(502, "cache-seed", "cache-world",
		revision, BOUNDS)
	book.finish_source("cache:props", "cache-owner", "rev-2", revision)
	var recovered: Dictionary = book.region_readiness(502, "cache-seed", "cache-world",
		revision, BOUNDS)
	_check("coverage_cache_invalidates_failed_and_replaced_source",
		failed.get("status") == "pending" and replaced.get("status") == "pending"
		and recovered.get("status") == "ready",
		{"failedGaps": failed.get("coverageGaps", []),
			"replacedGaps": replaced.get("coverageGaps", [])})


func test_horizon_ecology_owner_lifetime() -> void:
	var main := HorizonMainFixture.new()
	main.chunk_root = Node3D.new()
	root.add_child(main)
	main.add_child(main.chunk_root)
	var source = HorizonEcologySourceScript.new()
	var keys: Array[Vector2i] = [Vector2i(4, 0), Vector2i(5, 0)]
	source.retain_view(main, keys, keys, Rect2i(-2, -2, 4, 4), 1.35, 28, true)
	_check("horizon_owner_creation_is_one_per_slice", source.roots.size() == 1)
	source.retain_view(main, keys, keys, Rect2i(-2, -2, 4, 4), 1.35, 28, true)
	_check("horizon_owner_retains_both_view_sources", source.roots.size() == 2)
	_check("horizon_owner_uses_visual_only_roots",
		bool(source.source_for(keys[0]).get_meta("horizon_visual_only", false))
		and bool(source.source_for(keys[1]).get_meta("horizon_visual_only", false)))
	_check("horizon_owner_advances_seeded_producer_once",
		source.advance_one(main, keys, 1.0, 4, 8) == 1 and main.scan_calls == 1)
	source.retain_view(main, keys, [], Rect2i(-2, -2, 4, 4), 1.35, 28, false)
	_check("completed_view_keeps_horizon_roots", source.roots.size() == 2)
	source.retain_view(main, [], [], Rect2i(-2, -2, 4, 4), 1.35, 28, false)
	_check("horizon_owner_retires_one_stale_root_per_slice", source.roots.size() == 1)
	source.clear()
	main.queue_free()


func test_horizon_ordinary_visual_range_receipt() -> void:
	var main := HorizonMainFixture.new()
	main.chunk_root = Node3D.new()
	main.player = HorizonPlayerFixture.new()
	(main.player as HorizonPlayerFixture).camera = Camera3D.new()
	main.voxel_terrain_runtime = HorizonRuntimeFixture.new()
	(main.voxel_terrain_runtime as HorizonRuntimeFixture).viewer = HorizonViewerFixture.new()
	root.add_child(main)
	main.add_child(main.chunk_root)
	main.add_child(main.player)
	main.player.add_child((main.player as HorizonPlayerFixture).camera)
	var source = HorizonEcologySourceScript.new()
	var key := Vector2i(4, 0)
	var keys: Array[Vector2i] = [key]
	source.retain_view(main, keys, keys, Rect2i(-2, -2, 4, 4), 1.35, 28, true)
	var far_root := source.source_for(key)
	var body := StaticBody3D.new()
	body.set_meta("prop_id", "seed:ordinary")
	body.position.y = 60.0
	far_root.add_child(body)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	body.add_child(mesh)
	far_root.set_meta("chunk_surface_candidate_source_revision",
		"seed:1:%d:surface" % far_root.get_instance_id())
	source.refresh_ordinary_visual_ranges(main, key)
	var publisher := body.get_meta("horizon_ordinary_visual_publisher") as Object
	var metadata := {"horizonOrdinaryBodyId": body.get_instance_id(),
		"horizonOrdinaryRootId": far_root.get_instance_id()}
	var source_revision := String(far_root.get_meta("chunk_surface_candidate_source_revision")) + ":sha256:test"
	var outside: bool = publisher.call("visual_receipt_installed", "chunk-props:seed:4,0",
		source_revision, "world", 1, "seed:ordinary", metadata,
		"seed:ordinary:installed", "horizon")
	_check("retained_horizon_root_outside_player_range_has_no_live_receipt",
		far_root.is_inside_tree() and not outside and mesh.visibility_range_end <= 100.1)
	main.player.position = Vector3(60.0, 0.0, 0.0)
	source.refresh_ordinary_visual_ranges(main, key)
	var inside: bool = publisher.call("visual_receipt_installed", "chunk-props:seed:4,0",
		source_revision, "world", 1, "seed:ordinary", metadata,
		"seed:ordinary:installed", "horizon")
	_check("inside_horizontal_view_elevated_horizon_prop_has_live_receipt",
		inside and mesh.visibility_range_end > 100.0)
	source.clear()
	main.queue_free()


func test_empty_manifest_requires_complete_source_coverage() -> void:
	var book = VisualReadinessScript.new()
	var started: Dictionary = book.begin_view(11, "seed-a", "world-1", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS)
	var revision := int(started.get("viewRevision", 0))
	var open_result: Dictionary = book.region_readiness(11, "seed-a", "world-1", revision, BOUNDS)
	_check("unsealed_empty_source_set_is_pending", open_result.status == "pending")
	var missing_coverage: Dictionary = book.seal_source_set(revision)
	_check("empty_source_set_without_descriptors_cannot_seal",
		missing_coverage.status == "pending" and missing_coverage.missingKinds.size() == 5)
	_declare_sources(book, revision, BOUNDS)
	_check("empty_sources_only_ready_after_every_kind_is_described",
		book.seal_source_set(revision).status == "ready")
	var ready: Dictionary = book.region_readiness(11, "seed-a", "world-1", revision, BOUNDS)
	_check("complete_deterministic_empty_manifest_is_ready",
		ready.status == "ready" and int(ready.candidateCount) == 0 and int(ready.pendingCount) == 0)


func test_exact_subregion_coverage_is_independent() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(111, "seed-subregion", "world-subregion",
		BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	_declare_sources(book, revision, BOUNDS)
	var local := Rect2i(-5, -5, 4, 4)
	var local_state: Dictionary = book.region_readiness(111, "seed-subregion",
		"world-subregion", revision, local)
	var uncovered := Rect2i(1, 1, 4, 4)
	var missing_kind := VisualReadinessScript.new()
	var missing_revision := int(missing_kind.begin_view(112, "seed-subregion", "world-subregion",
		BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	_declare_sources(missing_kind, missing_revision, local)
	var missing_state: Dictionary = missing_kind.region_readiness(112, "seed-subregion",
		"world-subregion", missing_revision, uncovered)
	_check("complete_source_rectangles_prove_only_the_covered_subregion",
		local_state.status == "ready" and local_state.bounds == local
		and missing_state.status == "pending" and missing_state.reason == "visual_source_coverage_incomplete")


func test_circular_view_coverage_ignores_outside_corner_cells() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(113, "seed-circle", "world-circle",
		BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	var terrain_footprints: Dictionary = {}
	for z in range(BOUNDS.position.y, BOUNDS.end.y):
		var vertical_delta := (float(z) + 0.5) - VIEW_CENTER.y
		if absf(vertical_delta) > VIEW_RADIUS: continue
		var reach := sqrt(maxf(0.0, VIEW_RADIUS * VIEW_RADIUS - vertical_delta * vertical_delta))
		var row_start := maxi(BOUNDS.position.x, ceili(VIEW_CENTER.x - reach - 0.5))
		var row_end := mini(BOUNDS.end.x, floori(VIEW_CENTER.x + reach - 0.5) + 1)
		if row_end <= row_start: continue
		terrain_footprints["terrain:row:%d" % z] = Rect2i(row_start, z, row_end - row_start, 1)
	_check("native_terrain_source_footprints_admitted_before_row_receipts",
		book.declare_terrain_mesh_source_set(terrain_footprints, revision).status == "ready")
	for kind: String in VisualReadinessScript.CONTENT_KINDS:
		for z in range(BOUNDS.position.y, BOUNDS.end.y):
			var vertical_delta := (float(z) + 0.5) - VIEW_CENTER.y
			if absf(vertical_delta) > VIEW_RADIUS: continue
			var reach := sqrt(maxf(0.0, VIEW_RADIUS * VIEW_RADIUS - vertical_delta * vertical_delta))
			var row_start := maxi(BOUNDS.position.x, ceili(VIEW_CENTER.x - reach - 0.5))
			var row_end := mini(BOUNDS.end.x, floori(VIEW_CENTER.x + reach - 0.5) + 1)
			if row_end <= row_start: continue
			var source_bounds := Rect2i(row_start, z, row_end - row_start, 1)
			var source_id := "%s:row:%d" % [kind, z]
			book.expect_source(source_id, kind, source_id, "rev:1", source_bounds, revision)
			book.finish_source(source_id, source_id, "rev:1", revision)
	var circle_state: Dictionary = book.region_readiness(113, "seed-circle",
		"world-circle", revision, BOUNDS)
	_check("circular_view_requires_all_in_circle_sources_but_not_square_corner_sources",
		circle_state.status == "ready" and int(circle_state.candidateCount) == 0)


func test_terrain_coverage_uses_admitted_mesh_footprints() -> void:
	var book = VisualReadinessScript.new()
	var bounds := Rect2i(248, -90, 20, 20)
	var near_bounds := Rect2i(250, -82, 2, 2)
	var revision := int(book.begin_view(114, "terrain-footprint-seed", "terrain-footprint-world",
		bounds, near_bounds, Vector2(258.0, -81.0), 12.0).viewRevision)
	var mesh_source_id := "terrain-mesh:16,5,-5"
	var mesh_footprint := Rect2i(250, -82, 8, 8)
	var admitted: Dictionary = book.declare_terrain_mesh_source_set(
		{mesh_source_id: mesh_footprint}, revision)
	var described: Dictionary = book.expect_source(mesh_source_id, "terrain",
		"native-mesh-owner", "mesh-rev-1", mesh_footprint, revision)
	for kind: String in VisualReadinessScript.CONTENT_KINDS:
		if kind == "terrain": continue
		_expect_source(book, kind, revision, bounds)
		book.finish_source("source:" + kind, "identity:" + kind, "rev:1", revision)
	var pending_source: Dictionary = book.region_readiness(114, "terrain-footprint-seed",
		"terrain-footprint-world", revision, bounds)
	_check("admitted_native_mesh_block_remains_pending_until_source_finishes",
		admitted.status == "ready" and described.status == "ready"
		and pending_source.status == "pending")
	var candidate: Dictionary = book.describe_candidate(mesh_source_id, "terrain:16,5,-5",
		"horizon", {"positionXZ": Vector2(254.0, -78.0)})
	book.finish_source(mesh_source_id, "native-mesh-owner", "mesh-rev-1", revision)
	book.seal_source_set(revision)
	var pending_mesh: Dictionary = book.region_readiness(114, "terrain-footprint-seed",
		"terrain-footprint-world", revision, bounds)
	_check("flat_xz_edge_cell_outside_native_mesh_set_adds_no_terrain_obligation",
		candidate.status == "ready" and pending_mesh.status == "pending"
		and (pending_mesh.get("coverageGaps", []) as Array).is_empty()
		and int(pending_mesh.get("byKind", {}).get("terrain", {}).get("pending", 0)) == 1,
		{"pending": pending_mesh})
	var owner := Node3D.new()
	root.add_child(owner)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	owner.add_child(mesh)
	await process_frame
	var accepted: Dictionary = book.accept_receipt(mesh_source_id, "terrain:16,5,-5",
		"terrain:16,5,-5:native_mesh", "horizon", "native-mesh-owner", "mesh-rev-1",
		revision, owner, mesh)
	var ready: Dictionary = book.region_readiness(114, "terrain-footprint-seed",
		"terrain-footprint-world", revision, bounds)
	_check("admitted_mesh_receipt_completes_native_terrain_footprint",
		accepted.status == "ready" and ready.status == "ready"
		and int(ready.get("representedCount", 0)) == 1, {"ready": ready})
	owner.queue_free()
	await process_frame
	var retired: Dictionary = book.region_readiness(114, "terrain-footprint-seed",
		"terrain-footprint-world", revision, bounds)
	_check("retired_admitted_mesh_receipt_reopens_terrain_pending",
		retired.status == "pending"
		and int(retired.get("byKind", {}).get("terrain", {}).get("pending", 0)) == 1,
		{"retired": retired})


func test_incomplete_discovery_never_reports_empty_ready() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(12, "seed-b", "world-2", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	_declare_sources(book, revision, BOUNDS, "wildlife")
	var sealed: Dictionary = book.seal_source_set(revision)
	_check("missing_wildlife_enumeration_retries_instead_of_claiming_empty",
		sealed.status == "pending" and sealed.missingKinds == ["wildlife"])
	var query: Dictionary = book.region_readiness(12, "seed-b", "world-2", revision, BOUNDS)
	_check("incomplete_discovery_is_pending", query.status == "pending")


func test_candidate_must_belong_to_declared_source_footprint() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(121, "seed-b2", "world-2b", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	var declared := book.expect_source("props:east", "props", "props:east", "rev:1", Rect2i(0, -2, 2, 4), revision)
	_check("narrow_source_descriptor_succeeds", declared.status == "ready")
	var outside := book.describe_candidate("props:east", "rock:outside-source", "horizon",
		{"positionXZ": Vector2(3.0, 1.0)})
	_check("candidate_cannot_escape_its_declared_source_footprint",
		outside.status == "failed" and outside.reason == "visual_candidate_outside_source_or_view")


func test_surface_prop_source_completes_before_underground_scan() -> void:
	var chunk := Node3D.new()
	chunk.name = "SurfaceSourceFixture"
	root.add_child(chunk)
	await process_frame
	_make_manifest_body(chunk, "surface-seed:4,5:0", "rock")
	var unfinished_surface: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i.ZERO,
		"surface-seed", "surface-rev-1", false, 1.35, true)
	var completed_surface: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i.ZERO,
		"surface-seed", "surface-rev-1", true, 1.35, true)
	var unfinished_full: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i.ZERO,
		"surface-seed", "full-rev-1", false, 1.35)
	_check("surface_source_finishes_without_underground_scan_completion",
		unfinished_surface.status == "pending" and completed_surface.status == "ready" \
		and completed_surface.surfaceOnly and completed_surface.candidateCount == 1 \
		and unfinished_full.status == "pending",
		{"surface": completed_surface, "full": unfinished_full})
	_make_manifest_body(chunk, "surface-seed:underground:4,-5,5", "rock")
	var unchanged_surface: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i.ZERO,
		"surface-seed", "surface-rev-1", true, 1.35, true)
	var completed_full: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i.ZERO,
		"surface-seed", "full-rev-1", true, 1.35)
	_check("later_underground_publication_does_not_change_surface_manifest",
		unchanged_surface.sourceRevision == completed_surface.sourceRevision \
		and unchanged_surface.candidateCount == 1 and completed_full.candidateCount == 2,
		{"surfaceCandidates": unchanged_surface.candidateCount,
			"fullCandidates": completed_full.candidateCount})
	chunk.queue_free()
	await process_frame


func test_underground_floor_scan_revision_restart() -> void:
	var volume = TerrainVolumeServiceScript.new()
	var scan: Dictionary = volume.begin_exposed_underground_floor_scan(Vector2i.ZERO, 28)
	scan["columnIndex"] = 20
	volume.revision += 1
	var restarted: Dictionary = volume.advance_exposed_underground_floor_scan(scan, 1)
	_check("volume_floor_scan_exposes_source_revision_restart",
		bool(restarted.get("restarted", false))
		and int(restarted.state.get("revision", -1)) == volume.revision
		and int(restarted.state.get("columnIndex", -1)) == 0,
		{"restarted": restarted.get("restarted"), "state": restarted.get("state", {})})
	var main = ScanMain.new()
	var source := UndergroundScanFixture.new()
	main.world_generation_system = source
	var state := {"cx": -1, "cz": 0, "undergroundCandidates": [],
		"undergroundScanComplete": false, "undergroundIndex": 0}
	var first_complete: bool = main.scan_underground_prop_candidates_from_volume_service(state, 1)
	var first_candidates: Array = (state.get("undergroundCandidates", []) as Array).duplicate()
	var second_complete: bool = main.scan_underground_prop_candidates_from_volume_service(state, 1)
	var current_candidates: Array = state.get("undergroundCandidates", [])
	_check("restarted_volume_scan_replaces_prior_candidates_and_deduplicates_cells",
		not first_complete and first_candidates == [Vector3i(-28, -5, 0)]
		and second_complete and current_candidates == [Vector3i(-28, -5, 0), Vector3i(-27, -5, 0)]
		and source.calls == 2,
		{"first": first_candidates, "current": current_candidates, "calls": source.calls})
	main.free()


func test_installed_detail_batch_receipts() -> void:
	var chunk := Node3D.new()
	chunk.name = "DetailBatchReceiptFixture"
	root.add_child(chunk)
	var batch := MultiMeshInstance3D.new()
	batch.set_meta("detail_type", "grass")
	batch.visibility_range_end = 58.0
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.use_colors = true
	instances.use_custom_data = true
	instances.mesh = BoxMesh.new()
	instances.instance_count = 2
	instances.set_instance_transform(0, Transform3D.IDENTITY)
	instances.set_instance_transform(1, Transform3D(Basis.IDENTITY, Vector3(2.7, 0.0, 0.0)))
	instances.set_instance_color(0, Color(0.2, 0.8, 0.2))
	instances.set_instance_color(1, Color(0.4, 0.7, 0.3))
	instances.set_instance_custom_data(0, Color(0.1, 0.0, 0.0))
	instances.set_instance_custom_data(1, Color(0.2, 0.0, 0.0))
	batch.multimesh = instances
	chunk.add_child(batch)
	var missing_publisher: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i.ZERO,
		"detail-seed", "detail-scan-1", true, 1.35, true)
	_check("completed_detail_batch_requires_producer_snapshot",
		missing_publisher.status == "pending"
		and missing_publisher.reason == "chunk_detail_batch_publisher_missing")
	var publisher = DetailBatchPublisherScript.new()
	publisher.configure(batch, "grass")
	batch.set_meta("visual_detail_receipt_publisher", publisher)
	chunk.set_meta("visual_detail_expected_batches", [{"detailType": "grass",
		"batchInstanceId": batch.get_instance_id(), "instanceCount": 2}])
	await process_frame
	var manifest: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i.ZERO,
		"detail-seed", "detail-scan-1", true, 1.35, true)
	_check("installed_detail_instances_are_individual_foliage_candidates",
		manifest.status == "ready" and manifest.candidateCount == 2
		and manifest.byKind.trees_foliage.candidateCount == 2)
	var book = VisualReadinessScript.new()
	var bounds := Rect2i(0, 0, 28, 28)
	var revision := int(book.begin_view(97, "detail-seed", "detail-world-1",
		bounds, bounds, Vector2.ZERO, 5.0).viewRevision)
	var submitted: Dictionary = ChunkPropManifestScript.submit(manifest, book, revision,
		bounds, Vector3.ZERO)
	for kind: String in ["terrain", "structures"]:
		var source_id := "detail-fixture:%s" % kind
		if kind == "terrain":
			book.declare_terrain_mesh_source_set({source_id: bounds}, revision)
		book.expect_source(source_id, kind, source_id, "detail-fixture-rev-1", bounds, revision)
		book.finish_source(source_id, source_id, "detail-fixture-rev-1", revision)
	book.seal_source_set(revision)
	var ready: Dictionary = book.region_readiness(97, "detail-seed", "detail-world-1",
		revision, bounds)
	_check("installed_detail_receipts_revalidate_per_instance",
		submitted.status == "ready" and ready.status == "ready"
		and ready.byKind.trees_foliage.represented == 2,
		{"submit": submitted, "readiness": ready})
	instances.visible_instance_count = 1
	var hidden: Dictionary = book.region_readiness(97, "detail-seed", "detail-world-1",
		revision, bounds)
	_check("hidden_detail_instance_invalidates_its_receipt",
		hidden.status == "pending" and hidden.byKind.trees_foliage.pending == 1)
	instances.visible_instance_count = 2
	batch.position = Vector3(1.35, 0.0, 0.0)
	var moved: Dictionary = book.region_readiness(97, "detail-seed", "detail-world-1",
		revision, bounds)
	_check("moved_detail_batch_invalidates_its_instance_receipts",
		moved.status == "pending" and moved.byKind.trees_foliage.pending == 2,
		{"readiness": moved, "liveTransform": batch.global_transform})
	var distant_book = VisualReadinessScript.new()
	var distant_revision := int(distant_book.begin_view(98, "detail-seed", "detail-world-1",
		bounds, bounds, Vector2.ZERO, 5.0).viewRevision)
	var culled: Dictionary = ChunkPropManifestScript.submit(manifest, distant_book,
		distant_revision, bounds, Vector3(80.0, 0.0, 0.0))
	_check("detail_outside_existing_visibility_range_is_not_a_horizon_obligation",
		culled.status == "ready" and culled.candidateCount == 0)
	batch.queue_free()
	await process_frame
	var missing_batch: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i.ZERO,
		"detail-seed", "detail-scan-1", true, 1.35, true)
	_check("producer_batch_record_rejects_removed_decorative_visuals",
		missing_batch.status == "pending"
		and missing_batch.reason == "chunk_detail_batch_installation_missing",
		missing_batch)
	chunk.queue_free()
	await process_frame


func test_production_chunk_prop_manifest() -> void:
	var chunk := Node3D.new()
	chunk.name = "ChunkManifestFixture"
	chunk.position = Vector3(-28.0 * 1.35, 0.0, 56.0 * 1.35)
	root.add_child(chunk)
	await process_frame
	var incomplete: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", false, 1.35)
	_check("incomplete_production_prop_scan_stays_pending",
		incomplete.status == "pending" and incomplete.reason == "chunk_prop_candidate_scan_incomplete")
	var unrevisioned_incomplete: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "", false, 1.35)
	_check("incomplete_prop_scan_without_final_revision_stays_retryable",
		unrevisioned_incomplete.status == "pending"
		and unrevisioned_incomplete.reason == "chunk_prop_candidate_scan_incomplete")
	var empty_complete: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", true, 1.35)
	_check("completed_empty_chunk_scan_is_explicitly_ready",
		empty_complete.status == "ready" and empty_complete.scanComplete \
		and int(empty_complete.candidateCount) == 0, empty_complete)
	var rock := _make_manifest_body(chunk, "rock:stable", "rock")
	var tree := _make_manifest_body(chunk, "tree:stable", "tree")
	var wildlife := _make_manifest_body(chunk, "wildlife:stable", "wildlife")
	var chunk_center_offset := Vector3(14.0 * 1.35, 0.0, 14.0 * 1.35)
	rock.position = chunk_center_offset
	tree.position = chunk_center_offset
	wildlife.position = chunk_center_offset
	tree.set_meta("tree_visual_state", "queued")
	wildlife.set_meta("wildlife_variant", "deer")
	var queued: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", true, 1.35)
	_check("candidate_set_is_bound_into_chunk_source_revision",
		queued.sourceRevision != empty_complete.sourceRevision)
	_check("chunk_manifest_uses_existing_prop_ids_and_classification",
		queued.candidateCount == 3 and int(queued.byKind.props.candidateCount) == 1 \
		and int(queued.byKind.trees_foliage.candidateCount) == 1 \
		and int(queued.byKind.wildlife.candidateCount) == 1)
	_check("queued_tree_remains_pending_after_spawn_scan",
		queued.status == "pending" and queued.byKind.trees_foliage.pendingIds == ["tree:stable"])
	var readiness = VisualReadinessScript.new()
	var view_bounds := Rect2i(-70, 14, 84, 84)
	var near_bounds := Rect2i(-28, 56, 28, 28)
	var view_revision := int(readiness.begin_view(92, "seed-props", "world-props-1",
		view_bounds, near_bounds, Vector2(-28.0, 56.0), 42.0).viewRevision)
	var submitted_pending_tree: Dictionary = ChunkPropManifestScript.submit(queued, readiness,
		view_revision, near_bounds, Vector3.ZERO)
	_check("completed_chunk_manifest_registers_real_candidates",
		submitted_pending_tree.status == "pending" and submitted_pending_tree.manifestSubmitted \
		and readiness.has_candidate(
			"%s:trees_foliage" % queued.sourceIdentity, "tree:stable"))
	_check("queued_tree_candidate_remains_unreceipted",
		readiness.region_readiness(92, "seed-props", "world-props-1", view_revision,
			view_bounds).status == "pending")
	var committed_tree_visual := MeshInstance3D.new()
	committed_tree_visual.name = "GeneratedTreeVisual"
	committed_tree_visual.mesh = BoxMesh.new()
	tree.add_child(committed_tree_visual)
	tree.set_meta("tree_visual_state", "published")
	tree.set_meta("tree_render_lod_tier", "near")
	var published: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", true, 1.35)
	_check("published_tree_visual_is_counted_from_committed_mesh",
		published.status == "ready" and int(published.byKind.trees_foliage.representedCount) == 1)
	var published_receipts: Dictionary = ChunkPropManifestScript.submit(published, readiness,
		view_revision, near_bounds, Vector3.ZERO)
	_check("tree_queue_commit_is_admitted_as_a_live_owner_receipt",
		published_receipts.status == "ready" and int(published_receipts.pendingCount) == 0 \
		and int(published_receipts.byKind.trees_foliage.representedCount) == 1)
	var lod_view_bounds := Rect2i(-28, 56, 28, 28)
	var lod_center := Vector2(-14.0, 70.0)
	var lod_radius := 13.5
	var dynamic_lod_readiness = VisualReadinessScript.new()
	var dynamic_lod_view_revision := int(dynamic_lod_readiness.begin_view(93, "seed-props", "world-props-1",
		lod_view_bounds, lod_view_bounds, lod_center, lod_radius).viewRevision)
	var accepted_near_manifest: Dictionary = ChunkPropManifestScript.submit(published,
		dynamic_lod_readiness, dynamic_lod_view_revision, lod_view_bounds, Vector3.ZERO)
	for kind: String in ["terrain", "structures"]:
		var empty_source_id := "lod-empty:%s" % kind
		if kind == "terrain":
			dynamic_lod_readiness.declare_terrain_mesh_source_set(
				{empty_source_id: lod_view_bounds}, dynamic_lod_view_revision)
		dynamic_lod_readiness.expect_source(empty_source_id, kind, "lod-empty:%s" % kind,
			"lod-empty-rev-1", lod_view_bounds, dynamic_lod_view_revision)
		dynamic_lod_readiness.finish_source(empty_source_id, "lod-empty:%s" % kind,
			"lod-empty-rev-1", dynamic_lod_view_revision)
	dynamic_lod_readiness.seal_source_set(dynamic_lod_view_revision)
	var accepted_near_state: Dictionary = dynamic_lod_readiness.region_readiness(93,
		"seed-props", "world-props-1", dynamic_lod_view_revision, lod_view_bounds)
	tree.set_meta("tree_render_lod_tier", "far")
	var demoted_tree_state: Dictionary = dynamic_lod_readiness.region_readiness(93,
		"seed-props", "world-props-1", dynamic_lod_view_revision, lod_view_bounds)
	_check("accepted_near_tree_receipt_invalidates_immediately_on_lod_demotion",
		accepted_near_manifest.status == "ready" and accepted_near_state.status == "ready" \
		and demoted_tree_state.status == "pending" \
		and int(demoted_tree_state.byKind.trees_foliage.pending) == 1,
		{"before": accepted_near_state, "after": demoted_tree_state})
	var far_tree_manifest: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", true, 1.35)
	_check("tree_lod_change_keeps_candidate_source_revision",
		far_tree_manifest.sourceRevision == published.sourceRevision)
	var near_lod_readiness = VisualReadinessScript.new()
	var near_lod_view_revision := int(near_lod_readiness.begin_view(94, "seed-props", "world-props-1",
		lod_view_bounds, lod_view_bounds, lod_center, lod_radius).viewRevision)
	var far_in_near: Dictionary = ChunkPropManifestScript.submit(far_tree_manifest,
		near_lod_readiness, near_lod_view_revision, lod_view_bounds, Vector3.ZERO)
	for kind: String in ["terrain", "structures"]:
		var empty_source_id := "lod-empty:%s" % kind
		if kind == "terrain":
			near_lod_readiness.declare_terrain_mesh_source_set(
				{empty_source_id: lod_view_bounds}, near_lod_view_revision)
		near_lod_readiness.expect_source(empty_source_id, kind, "lod-empty:%s" % kind,
			"lod-empty-rev-1", lod_view_bounds, near_lod_view_revision)
		near_lod_readiness.finish_source(empty_source_id, "lod-empty:%s" % kind,
			"lod-empty-rev-1", near_lod_view_revision)
	near_lod_readiness.seal_source_set(near_lod_view_revision)
	var near_lod_state: Dictionary = near_lod_readiness.region_readiness(94,
		"seed-props", "world-props-1", near_lod_view_revision, lod_view_bounds)
	_check("far_tree_lod_cannot_satisfy_near_detail_receipt",
		far_in_near.status == "pending" and int(near_lod_state.byKind.trees_foliage.pending) == 1,
		{"submit": far_in_near, "readiness": near_lod_state})
	var horizon_readiness = VisualReadinessScript.new()
	var horizon_near_bounds := Rect2i(-28, 56, 1, 1)
	var horizon_view_revision := int(horizon_readiness.begin_view(95, "seed-props", "world-props-1",
		lod_view_bounds, horizon_near_bounds, lod_center, lod_radius).viewRevision)
	var far_in_horizon: Dictionary = ChunkPropManifestScript.submit(far_tree_manifest,
		horizon_readiness, horizon_view_revision, horizon_near_bounds, Vector3.ZERO)
	for kind: String in ["terrain", "structures"]:
		var empty_source_id := "lod-empty:%s" % kind
		if kind == "terrain":
			horizon_readiness.declare_terrain_mesh_source_set(
				{empty_source_id: lod_view_bounds}, horizon_view_revision)
		horizon_readiness.expect_source(empty_source_id, kind, "lod-empty:%s" % kind,
			"lod-empty-rev-1", lod_view_bounds, horizon_view_revision)
		horizon_readiness.finish_source(empty_source_id, "lod-empty:%s" % kind,
			"lod-empty-rev-1", horizon_view_revision)
	horizon_readiness.seal_source_set(horizon_view_revision)
	var horizon_state: Dictionary = horizon_readiness.region_readiness(95,
		"seed-props", "world-props-1", horizon_view_revision, lod_view_bounds)
	_check("committed_far_tree_lod_can_satisfy_horizon_visual_receipt",
		far_in_horizon.status == "ready" and int(horizon_state.byKind.trees_foliage.represented) == 1,
		{"submit": far_in_horizon, "readiness": horizon_state})
	var edge_prop := _make_manifest_body(chunk, "rock:outside-view", "rock")
	edge_prop.position = Vector3(1.0 * 1.35, 0.0, 27.0 * 1.35)
	var edge_manifest: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-edge", true, 1.35)
	var clipped_readiness = VisualReadinessScript.new()
	var clipped_bounds := Rect2i(-28, 56, 28, 28)
	var clipped_center := Vector2(-14.0, 70.0)
	var clipped_revision := int(clipped_readiness.begin_view(96, "seed-props", "world-props-1",
		clipped_bounds, clipped_bounds, clipped_center, 10.0).viewRevision)
	var clipped_submit: Dictionary = ChunkPropManifestScript.submit(edge_manifest,
		clipped_readiness, clipped_revision, clipped_bounds, Vector3.ZERO)
	_check("chunk_edge_candidates_outside_view_are_not_false_blockers",
		clipped_submit.candidateCount == 3 and clipped_submit.byKind.props.candidateCount == 1 \
		and not clipped_readiness.has_candidate(
			"%s:props" % edge_manifest.sourceIdentity, "rock:outside-view"), clipped_submit)
	_check("prop_visual_manifest_does_not_advance_generation_rng",
		String(published.scanAuthority) == "completed_production_chunk_prop_spawn_state")
	var before_position_change: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-position", true, 1.35)
	rock.position.x += 1.35
	var after_position_change: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-position", true, 1.35)
	rock.position.x -= 1.35
	_check("candidate_position_change_advances_prop_source_revision",
		before_position_change.sourceRevision != after_position_change.sourceRevision)
	for index in range(128):
		var item := Node3D.new()
		item.set_meta("prop_id", "stable-prop-candidate-%04d" % index)
		var item_mesh := MeshInstance3D.new()
		item_mesh.mesh = BoxMesh.new()
		item.add_child(item_mesh)
		chunk.add_child(item)
	var bounded_revision_a: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", true, 1.35)
	var bounded_revision_b: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", true, 1.35)
	_check("large_chunk_candidate_revision_is_bounded_and_deterministic",
		bounded_revision_a.sourceRevision == bounded_revision_b.sourceRevision \
		and String(bounded_revision_a.sourceRevision).length() == "source-rev-1:sha256:".length() + 64 \
		and int(bounded_revision_a.candidateCount) == 132,
		{"revisionLength": String(bounded_revision_a.sourceRevision).length(),
		"candidateCount": bounded_revision_a.candidateCount})
	var duplicate_prop := _make_manifest_body(chunk, "rock:stable", "rock")
	var duplicate_manifest: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-duplicate", true, 1.35)
	_check("duplicate_prop_id_is_reported_separately_from_manifest_capacity",
		duplicate_manifest.status == "pending"
		and duplicate_manifest.reason == "chunk_prop_candidate_id_duplicate"
		and duplicate_manifest.candidateId == "rock:stable"
		and int(duplicate_manifest.candidateCount) < ChunkPropManifestScript.MAX_CANDIDATES_PER_CHUNK,
		duplicate_manifest)
	duplicate_prop.queue_free()
	var overfull_chunk := Node3D.new()
	root.add_child(overfull_chunk)
	for index in range(ChunkPropManifestScript.MAX_CANDIDATES_PER_CHUNK + 1):
		var prop := Node3D.new()
		prop.set_meta("prop_id", "capacity-prop-%d" % index)
		overfull_chunk.add_child(prop)
	var capacity_manifest: Dictionary = ChunkPropManifestScript.capture(overfull_chunk,
		Vector2i(0, 0), "seed-props", "source-rev-capacity", true, 1.35)
	_check("true_candidate_limit_retains_distinct_capacity_reason",
		capacity_manifest.status == "pending"
		and capacity_manifest.reason == "chunk_prop_manifest_capacity"
		and int(capacity_manifest.candidateCount) == ChunkPropManifestScript.MAX_CANDIDATES_PER_CHUNK,
		capacity_manifest)
	overfull_chunk.queue_free()
	chunk.queue_free()
	await process_frame


func test_native_terrain_visual_manifest() -> void:
	var terrain_owner := TerrainPublisherFixture.new()
	var readiness = VisualReadinessScript.new()
	var bounds := Rect2i(4, 4, 8, 8)
	var view_revision := int(readiness.begin_view(151, "terrain-seed", terrain_owner.world_revision,
		bounds, bounds, Vector2(8.0, 8.0), 4.0).viewRevision)
	var manifest := TerrainVisualManifestScript.new()
	var begun: Dictionary = manifest.begin(terrain_owner, readiness, 151, "terrain-seed",
		terrain_owner.world_revision, view_revision, bounds, bounds, Vector3(8.0, 8.0, 8.0), 4.0)
	_check("native_terrain_manifest_plans_only_intersecting_mesh_blocks",
		begun.status == "ready" and int(begun.blockCount) == 1)
	var pending: Dictionary = manifest.advance(1)
	_check("native_terrain_source_stays_pending_until_area_is_meshed",
		pending.status == "pending" and pending.reason == "native_terrain_mesh_block_pending" \
		and int(pending.processedBlocks) == 0)
	terrain_owner.complete = true
	terrain_owner.has_geometry = true
	var represented: Dictionary = manifest.advance(1)
	_check("native_mesh_block_receipt_uses_runtime_validator",
		represented.status == "ready" and int(represented.representedMeshBlocks) == 1 \
		and readiness.has_candidate("terrain-mesh:0,0,0", "terrain:0,0,0"))
	terrain_owner.block_revision += 1
	terrain_owner.complete = false
	terrain_owner.visible_mesh_block_revision_changed.emit(Vector3i.ZERO, terrain_owner.block_revision)
	var invalidated: Dictionary = manifest.advance(1)
	_check("mesh_exit_rewalks_changed_source_and_waits_for_republication",
		invalidated.status == "pending" and invalidated.reason == "native_terrain_mesh_block_pending"
		and not readiness.has_candidate("terrain-mesh:0,0,0", "terrain:0,0,0"),
		{"progress": invalidated})
	var revised: Dictionary = manifest.begin(terrain_owner, readiness, 151, "terrain-seed",
		terrain_owner.world_revision, view_revision, bounds, bounds, Vector3(8.0, 8.0, 8.0), 4.0)
	_check("changed_native_mesh_block_revision_restarts_terrain_receipt",
		revised.status == "ready" and manifest.advance(1).status == "pending")
	var empty_readiness = VisualReadinessScript.new()
	var empty_revision := int(empty_readiness.begin_view(152, "terrain-seed", terrain_owner.world_revision,
		bounds, bounds, Vector2(8.0, 8.0), 4.0).viewRevision)
	var empty_manifest := TerrainVisualManifestScript.new()
	terrain_owner.complete = true
	terrain_owner.has_geometry = false
	empty_manifest.begin(terrain_owner, empty_readiness, 152, "terrain-seed",
		terrain_owner.world_revision, empty_revision, bounds, bounds, Vector3(8.0, 8.0, 8.0), 4.0)
	var completed_empty: Dictionary = empty_manifest.advance(1)
	_check("meshed_native_empty_block_finishes_explicit_empty_source",
		completed_empty.status == "ready" and int(completed_empty.completedEmptyBlocks) == 1 \
		and not empty_readiness.has_candidate("terrain-mesh:0,0,0", "terrain:0,0,0"))


func test_native_terrain_scan_continues_past_pending_block() -> void:
	var terrain_owner := TerrainPublisherFixture.new()
	terrain_owner.block_complete[Vector3i(1, 0, 0)] = true
	terrain_owner.block_geometry[Vector3i(1, 0, 0)] = true
	var readiness = VisualReadinessScript.new()
	var bounds := Rect2i(0, 0, 32, 16)
	var center := Vector3(16.0, 8.0, 8.0)
	var revision := int(readiness.begin_view(153, "terrain-scan-seed", terrain_owner.world_revision,
		bounds, bounds, Vector2(center.x, center.z), 15.0).viewRevision)
	var manifest := TerrainVisualManifestScript.new()
	manifest.begin(terrain_owner, readiness, 153, "terrain-scan-seed",
		terrain_owner.world_revision, revision, bounds, bounds, center, 15.0)
	var first: Dictionary = manifest.advance(2)
	_check("terrain_scan_receipts_ready_block_beyond_unmeshed_frontier",
		first.status == "pending" and int(first.processedBlocks) == 1 \
		and int(first.pendingBlocks) == 1 \
		and readiness.has_candidate("terrain-mesh:1,0,0", "terrain:1,0,0"), first)
	terrain_owner.block_complete[Vector3i(0, 0, 0)] = true
	terrain_owner.block_geometry[Vector3i(0, 0, 0)] = true
	var finished: Dictionary = manifest.advance(1)
	_check("terrain_scan_retries_frontier_and_completes_without_restart",
		finished.status == "ready" and int(finished.processedBlocks) == 2, finished)


func test_native_terrain_overlap_uses_current_installed_source() -> void:
	var terrain_owner := TerrainPublisherFixture.new()
	terrain_owner.complete = true
	terrain_owner.has_geometry = true
	var bounds := Rect2i(-32, -32, 80, 80)
	var near_bounds := Rect2i(0, 0, 16, 16)
	var old := VisualReadinessScript.new()
	var old_center := Vector3(8.0, 8.0, 8.0)
	var old_revision := int(old.begin_view(154, "terrain-overlap-seed", terrain_owner.world_revision,
		bounds, near_bounds, Vector2(old_center.x, old_center.z), 32.0).viewRevision)
	var old_manifest := TerrainVisualManifestScript.new()
	old_manifest.begin(terrain_owner, old, 154, "terrain-overlap-seed",
		terrain_owner.world_revision, old_revision, bounds, near_bounds, old_center, 32.0)
	var old_complete: Dictionary = old_manifest.advance(64)
	var moved := VisualReadinessScript.new()
	var moved_center := Vector3(9.0, 8.0, 8.0)
	var moved_revision := int(moved.begin_view(154, "terrain-overlap-seed", terrain_owner.world_revision,
		bounds, near_bounds, Vector2(moved_center.x, moved_center.z), 32.0).viewRevision)
	var moved_manifest := TerrainVisualManifestScript.new()
	moved_manifest.begin(terrain_owner, moved, 154, "terrain-overlap-seed",
		terrain_owner.world_revision, moved_revision, bounds, near_bounds, moved_center, 32.0,
		[old])
	var moved_complete: Dictionary = moved_manifest.advance(64)
	_check("terrain_overlap_transfers_only_valid_installed_interior_blocks",
		old_complete.status == "ready" and moved_complete.status == "ready" \
		and int(moved_complete.transferredBlocks) > 0 \
		and moved.has_candidate("terrain-mesh:0,0,0", "terrain:0,0,0"), moved_complete)
	var central_source_revision := terrain_owner.visible_mesh_source_revision(Vector3i.ZERO)
	_check("terrain_overlap_rebuilds_center_dependent_candidate_metadata",
		moved.complete_source_candidate_position("terrain-mesh:0,0,0", "terrain:0,0,0",
			terrain_owner.owner_identity, central_source_revision) == Vector2(9.0, 8.0))


func _make_manifest_body(parent: Node3D, prop_id: String, kind: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Manifest_" + kind
	body.set_meta("prop_id", prop_id)
	parent.add_child(body)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	body.add_child(visual)
	return body


func test_generated_structure_visual_manifest() -> void:
	var world := StructureWorldFixture.new()
	world.name = "GeneratedStructureVisualFixture"
	root.add_child(world)
	var structure_system := StructureReadinessFixture.new()
	structure_system.ordinary_world = world
	var bounds := NEAR_BOUNDS
	var readiness = VisualReadinessScript.new()
	var view_revision := int(readiness.begin_view(160, "structure-seed", "structure-world-1",
		BOUNDS, bounds, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	var first_block := _make_structure_visual_block(Vector3i.ZERO, true)
	world.add_child(first_block)
	world.blocks[Vector3i.ZERO] = first_block
	var first: Dictionary = StructureVisualManifestScript.submit(world, structure_system,
		readiness, 160, view_revision, bounds, bounds)
	_check("generated_structure_receipt_requires_current_physical_source",
		first.status == "ready" and first.physicalPublication.status == "ready" \
		and first.candidateCount == 1 and first.representedCount == 1, first)
	var incomplete_block := _make_structure_visual_block(Vector3i(1, 0, 0), false)
	world.add_child(incomplete_block)
	world.blocks[Vector3i(1, 0, 0)] = incomplete_block
	var incomplete: Dictionary = StructureVisualManifestScript.submit(world, structure_system,
		readiness, 160, view_revision, bounds, bounds)
	_check("generated_structure_without_installed_mesh_remains_pending",
		incomplete.status == "pending" and incomplete.candidateCount == 2 \
		and incomplete.representedCount == 1 and incomplete.pendingCount == 1,
		incomplete)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	incomplete_block.add_child(mesh)
	var completed: Dictionary = StructureVisualManifestScript.submit(world, structure_system,
		readiness, 160, view_revision, bounds, bounds)
	_check("generated_structure_receipts_recover_after_mesh_installation",
		completed.status == "ready" and completed.representedCount == 2, completed)
	var outside_circle := _make_structure_visual_block(Vector3i(6, 0, 0), false)
	world.add_child(outside_circle)
	world.blocks[Vector3i(6, 0, 0)] = outside_circle
	var circular_completed: Dictionary = StructureVisualManifestScript.submit(world,
		structure_system, readiness, 160, view_revision, BOUNDS, bounds)
	_check("generated_structure_square_corner_outside_circle_is_not_a_visual_candidate",
		circular_completed.status == "ready" and circular_completed.candidateCount == 2 \
		and circular_completed.representedCount == 2, circular_completed)
	var pending_physical := StructureReadinessFixture.new()
	pending_physical.ordinary_world = world
	pending_physical.physical_status = "pending"
	var withheld_readiness = VisualReadinessScript.new()
	var withheld_revision := int(withheld_readiness.begin_view(161, "structure-seed",
		"structure-world-1", BOUNDS, bounds, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	var withheld: Dictionary = StructureVisualManifestScript.submit(world, pending_physical,
		withheld_readiness, 161, withheld_revision, bounds, bounds)
	_check("structure_visual_source_is_not_declared_before_physical_source_completion",
		withheld.status == "pending" and withheld.physicalPublication.status == "pending" \
		and not withheld_readiness.has_candidate(
			"generated-structure-blocks:%s" % str(bounds),
			"structure-block:0,0,0:stoneBlock"), withheld)
	var horizon_readiness = VisualReadinessScript.new()
	var horizon_revision := int(horizon_readiness.begin_view(162, "structure-seed",
		"structure-world-1", BOUNDS, bounds, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	var horizon: Dictionary = StructureVisualManifestScript.submit(world, pending_physical,
		horizon_readiness, 162, horizon_revision, BOUNDS, bounds, false)
	_check("horizon_structure_visual_uses_complete_source_without_physical_publication",
		horizon.status == "ready" and horizon.candidateCount == 2 \
		and horizon.representedCount == 2 and horizon.physicalPublication.is_empty(), horizon)
	pending_physical.description_status = "pending"
	var unknown_readiness = VisualReadinessScript.new()
	var unknown_revision := int(unknown_readiness.begin_view(163, "structure-seed",
		"structure-world-1", BOUNDS, bounds, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	var unknown: Dictionary = StructureVisualManifestScript.submit(world, pending_physical,
		unknown_readiness, 163, unknown_revision, BOUNDS, bounds, false)
	_check("horizon_structure_empty_source_waits_for_source_description",
		unknown.status == "pending" and not unknown_readiness.has_candidate(
			"generated-structure-blocks:%s" % str(BOUNDS),
			"structure-block:0,0,0:stoneBlock"), unknown)
	world.queue_free()
	await process_frame


func test_ordinary_structure_visual_completion() -> void:
	var world := StructureWorldFixture.new()
	root.add_child(world)
	var system := StructureReadinessFixture.new()
	system.ordinary_world = world
	system.physical_status = "pending"
	var cell := Vector3i.ZERO
	var body := _make_structure_visual_block(cell,true)
	world.add_child(body)
	world.blocks[cell] = body
	system.ordinary_expected[cell] = true
	var readiness = VisualReadinessScript.new()
	var view_revision := int(readiness.begin_view(165,"ordinary-seed","ordinary-world-1",
		BOUNDS,NEAR_BOUNDS,VIEW_CENTER,VIEW_RADIUS).viewRevision)
	system.ordinary_status = "pending"
	var undisclosed: Dictionary = StructureVisualManifestScript.submit(world,system,readiness,
		165,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("ordinary_live_block_waits_for_producer_description",
		undisclosed.status == "pending" and undisclosed.reason == "ordinary_fixture_pending",
		undisclosed)
	system.ordinary_status = "described"
	var live: Dictionary = StructureVisualManifestScript.submit(world,system,readiness,
		165,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("ordinary_current_live_visual_receipt_is_accepted",
		live.status == "ready" and live.candidateCount == 1 and live.representedCount == 1,
		live)
	world.blocks.erase(cell)
	system.ordinary_revision = "ordinary-source-2"
	var absent_owner: Dictionary = StructureVisualManifestScript.submit(world,system,readiness,
		165,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("ordinary_missing_emitted_owner_cannot_be_empty_success",
		absent_owner.status == "pending" and absent_owner.candidateCount == 1
		and absent_owner.pendingCount == 1,absent_owner)
	system.ordinary_removed[cell] = true
	system.ordinary_revision = "ordinary-source-3"
	var edited: Dictionary = StructureVisualManifestScript.submit(world,system,readiness,
		165,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("ordinary_durable_edit_has_revised_empty_source",
		edited.status == "ready" and edited.candidateCount == 0
		and edited.sourceRevision != live.sourceRevision,edited)
	system.ordinary_removed.clear()
	system.ordinary_revision = "ordinary-source-4"
	var restored: Dictionary = StructureVisualManifestScript.submit(world,system,readiness,
		165,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("ordinary_restored_emission_requires_live_owner_again",
		restored.status == "pending" and restored.candidateCount == 1
		and restored.sourceRevision != edited.sourceRevision,restored)
	world.queue_free()
	await process_frame


func test_citadel_visual_member_source() -> void:
	var world := StructureWorldFixture.new()
	root.add_child(world)
	var structure_system := StructureReadinessFixture.new()
	structure_system.physical_status = "pending"
	var publisher := CitadelVisualPublisherFixture.new()
	var readiness = VisualReadinessScript.new()
	var view_revision := int(readiness.begin_view(164,"citadel-seed","citadel-world-1",
		BOUNDS,NEAR_BOUNDS,VIEW_CENTER,VIEW_RADIUS).viewRevision)
	var pending_description: Dictionary = StructureVisualManifestScript.submit(world,structure_system,
		readiness,164,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("citadel_completed_empty_description_can_be_ready",
		pending_description.status == "ready" and pending_description.candidateCount == 0,
		pending_description)
	structure_system.citadel_status = "pending"
	var missing: Dictionary = StructureVisualManifestScript.submit(world,structure_system,
		readiness,164,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("citadel_description_pending_cannot_finish_empty_source",
		missing.status == "pending" and missing.reason == "citadel_fixture_pending",missing)
	structure_system.citadel_status = "described"
	structure_system.citadel_candidates = [{"candidateId":"citadel:site-1:building:wall-1",
		"memberId":"building:wall-1","positionXZ":Vector2(0.5,0.5),
		"binding":{"siteId":"site-1"},"sourceSignature":"immutable-source-1",
		"publisher":publisher}]
	var unpublished: Dictionary = StructureVisualManifestScript.submit(world,structure_system,
		readiness,164,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("citadel_described_member_needs_installed_scene_receipt",
		unpublished.status == "pending" and unpublished.candidateCount == 1 \
		and unpublished.pendingCount == 1 and unpublished.representedCount == 0,unpublished)
	publisher.installed = true
	var published: Dictionary = StructureVisualManifestScript.submit(world,structure_system,
		readiness,164,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("citadel_member_receipt_is_visual_only_when_physical_pending",
		published.status == "ready" and published.candidateCount == 1 \
		and published.representedCount == 1 and published.physicalPublication.is_empty(),published)
	publisher.installed = false
	var revoked: Dictionary = StructureVisualManifestScript.submit(world,structure_system,
		readiness,164,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("citadel_member_receipt_revoked_when_scene_installation_lost",
		revoked.status == "pending" and revoked.representedCount == 0,revoked)
	var replacement := CitadelVisualPublisherFixture.new()
	structure_system.citadel_candidates[0].publisher = replacement
	var replaced: Dictionary = StructureVisualManifestScript.submit(world,structure_system,
		readiness,164,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("citadel_replacement_scene_cannot_borrow_prior_member_receipt",
		replaced.status == "pending" and replaced.representedCount == 0,replaced)
	replacement.installed = true
	var restored: Dictionary = StructureVisualManifestScript.submit(world,structure_system,
		readiness,164,view_revision,NEAR_BOUNDS,NEAR_BOUNDS,false)
	_check("citadel_replacement_scene_receipts_its_own_member",
		restored.status == "ready" and restored.representedCount == 1,restored)
	world.queue_free()
	await process_frame


func test_citadel_visual_member_bucket_query() -> void:
	var plan = CitadelPlanScript.new()
	plan.binding = {"siteId":"site-1"}
	plan.output_signature = "fixture-immutable-source"
	for index in range(512):
		var member_id := "building:member-%d" % index
		var world_z := 1.0+float(index/16)
		plan.member_records.append({"memberId":member_id,"groupId":"group-1",
			"bounds":AABB(Vector3(1.0+float(index%16),0.0,world_z),
				Vector3(0.5,1.0,0.5)),"visual":true})
		var bucket_key := "0,%d" % floori(world_z/CitadelPlanScript.BUCKET_WORLD_SIZE)
		if not plan.member_buckets.has(bucket_key): plan.member_buckets[bucket_key] = []
		plan.member_buckets[bucket_key].append(index)
	var started := Time.get_ticks_usec()
	var query: Dictionary = plan.visual_member_requirements(Rect2i(0,0,28,28))
	var elapsed := Time.get_ticks_usec()-started
	_check("citadel_visual_source_queries_complete_exact_immutable_member_bucket",
		query.status == "described" and query.descriptionComplete \
		and query.members.size() == 512 and int(query.queryMemberCandidateCount) == 512,
		{"candidateCount":query.get("queryMemberCandidateCount",-1),
			"memberCount":query.get("members",[]).size(),"elapsedUsec":elapsed,
			"evidenceLevel":"synthetic_member_bucket_query_not_live_scene_cost"})


func _make_structure_visual_block(cell: Vector3i, with_mesh: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("generated", true)
	body.set_meta("player_placed", false)
	body.set_meta("cell", cell)
	body.set_meta("block_type", "stoneBlock")
	if with_mesh:
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		body.add_child(mesh)
	return body


func test_receipts_are_request_revision_tier_and_installation_bound() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(13, "seed-c", "world-3", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	for kind: String in VisualReadinessScript.CONTENT_KINDS:
		_expect_source(book, kind, revision, BOUNDS)
		if kind == "props":
			_check("candidate_declaration_succeeds",
			book.describe_candidate("source:props", "tree:stable-id", "horizon", {"positionXZ": Vector2(3.0, 1.0)}).status == "ready")
			_check("candidate_without_position_is_rejected",
				book.describe_candidate("source:props", "tree:no-position", "horizon").reason == "visual_candidate_position_missing")
			_check("candidate_outside_view_is_rejected",
				book.describe_candidate("source:props", "tree:outside", "horizon", {"positionXZ": Vector2(30.0, 30.0)}).reason == "visual_candidate_outside_source_or_view")
			_check("candidate_wrong_tier_is_rejected",
				book.describe_candidate("source:props", "tree:wrong-tier", "near", {"positionXZ": Vector2(3.0, 1.0)}).reason == "visual_candidate_tier_mismatch")
		_check("source_enumeration_receipt_succeeds",
			book.finish_source("source:" + kind, "identity:" + kind, "rev:1", revision).status == "ready")
	_check("source_set_seals_after_full_kind_coverage", book.seal_source_set(revision).status == "ready")
	var borrowed: Dictionary = book.region_readiness(99, "seed-c", "world-3", revision, BOUNDS)
	_check("another_request_cannot_borrow_readiness", borrowed.status == "pending")
	var pending: Dictionary = book.region_readiness(13, "seed-c", "world-3", revision, BOUNDS)
	_check("queued_candidate_remains_pending_and_accounted",
		pending.status == "pending" and int(pending.candidateCount) == 1 and int(pending.pendingCount) == 1 \
		and int(pending.byKind.props.candidate) == 1 and int(pending.byKind.props.represented) == 0)
	var native_publisher := ReceiptPublisher.new()
	var native_receipt := book.accept_publisher_receipt("source:props", "tree:stable-id",
		"tree-native-mesh:stable-id", "horizon", "identity:props", "rev:1", revision,
		native_publisher, &"visual_receipt_is_current")
	_check("native_publisher_receipt_uses_owner_validator", native_receipt.status == "ready")
	_check("native_publisher_receipt_is_revalidated_for_readiness",
		book.region_readiness(13, "seed-c", "world-3", revision, BOUNDS).status == "ready" \
		and native_publisher.validation_count >= 2)
	native_publisher.installed = false
	var stale_native: Dictionary = book.region_readiness(13, "seed-c", "world-3", revision, BOUNDS)
	_check("native_publisher_receipt_invalidates_when_installation_changes",
		stale_native.status == "pending" and int(stale_native.pendingCount) == 1)
	native_publisher.installed = true

	var owner := Node3D.new()
	owner.name = "ReceiptOwner"
	root.add_child(owner)
	var representation := MeshInstance3D.new()
	representation.name = "InstalledHorizon"
	representation.mesh = BoxMesh.new()
	owner.add_child(representation)
	await process_frame
	var empty_representation := Node3D.new()
	empty_representation.name = "EmptyRepresentation"
	owner.add_child(empty_representation)
	var empty_receipt: Dictionary = book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:empty",
		"horizon", "identity:props", "rev:1", revision, owner, empty_representation)
	_check("visible_empty_node_is_not_a_visual_receipt",
		empty_receipt.status == "pending" and empty_receipt.reason == "visual_representation_not_installed")
	var stale: Dictionary = book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:horizon",
		"horizon", "identity:props", "stale-revision", revision, owner, representation)
	_check("stale_source_revision_is_rejected", stale.status == "pending")
	var low_tier: Dictionary = book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:near",
		"near", "identity:props", "rev:1", revision, owner, representation)
	_check("near_receipt_satisfies_horizon_candidate", low_tier.status == "ready")
	var near_book = VisualReadinessScript.new()
	var near_revision := int(near_book.begin_view(131, "seed-c", "world-3", BOUNDS,
		NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	near_book.expect_source("near:props", "props", "near:owner", "rev:1",
		Rect2i(-1, -1, 2, 2), near_revision)
	near_book.describe_candidate("near:props", "near:rock", "near",
		{"positionXZ": Vector2(0.0, 0.0)})
	var weak_near: Dictionary = near_book.accept_receipt("near:props", "near:rock",
		"near:rock:horizon", "horizon", "near:owner", "rev:1",
		near_revision, owner, representation)
	_check("horizon_receipt_cannot_satisfy_near_candidate",
		weak_near.status == "pending" and weak_near.reason == "visual_representation_tier_insufficient",
		weak_near)
	var strong_near: Dictionary = near_book.accept_receipt("near:props", "near:rock",
		"near:rock:near", "near", "near:owner", "rev:1",
		near_revision, owner, representation)
	_check("near_receipt_satisfies_near_candidate", strong_near.status == "ready",
		strong_near)
	var detached: Node3D = Node3D.new()
	root.add_child(detached)
	var unowned: Dictionary = book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:unowned",
		"horizon", "identity:props", "rev:1", revision, owner, detached)
	_check("uninstalled_representation_cannot_be_accepted", unowned.status == "pending")
	_check("committed_horizon_receipt_is_accepted",
		book.accept_receipt("source:props", "tree:stable-id", "tree:stable-id:horizon",
			"horizon", "identity:props", "rev:1", revision, owner, representation).status == "ready")
	var represented: Dictionary = book.region_readiness(13, "seed-c", "world-3", revision, BOUNDS)
	_check("accepted_receipt_counts_in_the_candidate_kind_and_tier",
		represented.status == "ready" and int(represented.byKind.props.represented) == 1 \
		and int(represented.tiers.horizon.represented) == 1)
	owner.queue_free()
	await process_frame
	var replaced: Dictionary = book.region_readiness(13, "seed-c", "world-3", revision, BOUNDS)
	_check("removed_owner_invalidates_receipt", replaced.status == "pending" and int(replaced.pendingCount) == 1)
	var old_revision := revision
	revision = int(book.begin_view(13, "seed-c", "world-4", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	_check("world_source_change_advances_view_revision", revision > old_revision)
	_check("old_receipt_cannot_cross_source_revision",
		book.region_readiness(13, "seed-c", "world-3", old_revision, BOUNDS).status == "pending")
	_check("new_revision_starts_pending_without_old_candidates",
		book.region_readiness(13, "seed-c", "world-4", revision, BOUNDS).status == "pending")
	detached.queue_free()
	await process_frame


func test_bounded_overlap_transfer_revalidates_receipts() -> void:
	var source_bounds := Rect2i(2, 0, 2, 2)
	var old = VisualReadinessScript.new()
	var old_revision := int(old.begin_view(200, "overlap-seed", "overlap-world",
		BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	old.expect_source("overlap:props", "props", "overlap-owner", "overlap-rev-1",
		source_bounds, old_revision)
	var owner := Node3D.new()
	root.add_child(owner)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	owner.add_child(visual)
	await process_frame
	for index in 2:
		var candidate_id := "overlap-prop:%d" % index
		old.describe_candidate("overlap:props", candidate_id, "horizon",
			{"positionXZ": Vector2(2.5 + float(index), 0.5)})
		old.accept_receipt("overlap:props", candidate_id, candidate_id + ":installed",
			"horizon", "overlap-owner", "overlap-rev-1", old_revision, owner, visual)
	old.finish_source("overlap:props", "overlap-owner", "overlap-rev-1", old_revision)
	var shifted_bounds := Rect2i(-5, -6, 12, 12)
	var shifted_center := Vector2(1.0, 0.0)
	var shifted = VisualReadinessScript.new()
	shifted.begin_view(200, "overlap-seed", "overlap-world", BOUNDS,
		NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS)
	var shifted_revision := int(shifted.begin_view(200, "overlap-seed", "overlap-world",
		shifted_bounds, NEAR_BOUNDS, shifted_center, VIEW_RADIUS).viewRevision)
	var first: Dictionary = shifted.transfer_complete_overlap_source(old, "overlap:props",
		"overlap-owner", "overlap-rev-1", shifted_revision, 1)
	_check("overlap_transfer_is_bounded_and_retryable",
		first.status == "pending" and first.reason == "visual_overlap_transfer_budget" \
		and first.remainingCandidates == 1 and shifted.has_candidate("overlap:props", "overlap-prop:0"), first)
	var completed: Dictionary = shifted.transfer_complete_overlap_source(old, "overlap:props",
		"overlap-owner", "overlap-rev-1", shifted_revision, 1)
	_check("complete_interior_source_reaccepts_all_receipts_in_new_view_revision",
		completed.status == "ready" and completed.copiedCandidates == 2 \
		and completed.viewRevision == shifted_revision and shifted_revision > old_revision \
		and shifted.has_candidate("overlap:props", "overlap-prop:1"), completed)
	var wrong_request = VisualReadinessScript.new()
	var wrong_revision := int(wrong_request.begin_view(201, "overlap-seed", "overlap-world",
		shifted_bounds, NEAR_BOUNDS, shifted_center, VIEW_RADIUS).viewRevision)
	var borrowed: Dictionary = wrong_request.transfer_complete_overlap_source(old,
		"overlap:props", "overlap-owner", "overlap-rev-1", wrong_revision)
	_check("overlap_transfer_never_borrows_another_request",
		borrowed.status == "pending" and not wrong_request.has_candidate(
			"overlap:props", "overlap-prop:0"), borrowed)
	var changed = VisualReadinessScript.new()
	var changed_revision := int(changed.begin_view(200, "overlap-seed", "overlap-world",
		shifted_bounds, NEAR_BOUNDS, shifted_center, VIEW_RADIUS).viewRevision)
	var stale: Dictionary = changed.transfer_complete_overlap_source(old,
		"overlap:props", "overlap-owner", "overlap-rev-2", changed_revision)
	_check("overlap_transfer_requires_current_source_revision",
		stale.status == "pending" and not changed.has_candidate(
			"overlap:props", "overlap-prop:0"), stale)
	var promoted = VisualReadinessScript.new()
	var promoted_near := Rect2i(2, 0, 2, 2)
	var promoted_revision := int(promoted.begin_view(200, "overlap-seed", "overlap-world",
		shifted_bounds, promoted_near, shifted_center, VIEW_RADIUS).viewRevision)
	var tier_changed: Dictionary = promoted.transfer_complete_overlap_source(old,
		"overlap:props", "overlap-owner", "overlap-rev-1", promoted_revision)
	_check("overlap_transfer_leaves_new_near_tier_for_publisher",
		tier_changed.status == "pending" and tier_changed.reason == "visual_overlap_tier_promotion_required" \
		and not promoted.has_candidate("overlap:props", "overlap-prop:0"), tier_changed)
	var boundary_bounds := Rect2i(5, 0, 2, 2)
	old.expect_source("overlap:boundary", "props", "boundary-owner", "boundary-rev-1",
		boundary_bounds, old_revision)
	old.finish_source("overlap:boundary", "boundary-owner", "boundary-rev-1", old_revision)
	var boundary: Dictionary = changed.transfer_complete_overlap_source(old,
		"overlap:boundary", "boundary-owner", "boundary-rev-1", changed_revision)
	_check("view_clipped_source_must_be_rescanned_even_when_empty",
		boundary.status == "pending" and boundary.reason == "visual_overlap_boundary_requires_scan",
		boundary)
	var empty_bounds := Rect2i(-2, 0, 2, 2)
	old.expect_source("overlap:empty", "props", "empty-owner", "empty-rev-1",
		empty_bounds, old_revision)
	old.finish_source("overlap:empty", "empty-owner", "empty-rev-1", old_revision)
	var empty: Dictionary = changed.transfer_complete_overlap_source(old,
		"overlap:empty", "empty-owner", "empty-rev-1", changed_revision)
	_check("complete_interior_empty_source_transfers_only_with_matching_revision",
		empty.status == "ready" and empty.copiedCandidates == 0, empty)
	owner.queue_free()
	await process_frame
	var retired = VisualReadinessScript.new()
	var retired_revision := int(retired.begin_view(200, "overlap-seed", "overlap-world",
		shifted_bounds, NEAR_BOUNDS, shifted_center, VIEW_RADIUS).viewRevision)
	var stale_owner: Dictionary = retired.transfer_complete_overlap_source(old,
		"overlap:props", "overlap-owner", "overlap-rev-1", retired_revision)
	_check("retired_representation_cannot_transfer_to_new_ledger",
		stale_owner.status == "pending" and stale_owner.reason == "visual_overlap_receipt_not_current" \
		and not retired.has_candidate("overlap:props", "overlap-prop:0"), stale_owner)


func test_candidate_accounting_and_explicit_failure() -> void:
	var book = VisualReadinessScript.new()
	var revision := int(book.begin_view(14, "seed-d", "world-5", BOUNDS, NEAR_BOUNDS, VIEW_CENTER, VIEW_RADIUS).viewRevision)
	for kind: String in VisualReadinessScript.CONTENT_KINDS:
		_expect_source(book, kind, revision, BOUNDS)
		if kind == "props":
			book.describe_candidate("source:props", "rock:stable-id", "near", {"positionXZ": Vector2(-1.0, 0.0)})
			book.fail_candidate("source:props", "rock:stable-id", "publisher_rejected", {"stage": "install"})
		if kind != "props":
			book.finish_source("source:" + kind, "identity:" + kind, "rev:1", revision)
	var unsealed: Dictionary = book.seal_source_set(revision)
	_check("covered_but_incomplete_source_cannot_seal", unsealed.status == "pending")
	book.finish_source("source:props", "identity:props", "rev:1", revision)
	book.seal_source_set(revision)
	var failed: Dictionary = book.region_readiness(14, "seed-d", "world-5", revision, BOUNDS)
	_check("explicit_candidate_failure_is_not_pending_or_empty",
		failed.status == "failed" and int(failed.candidateCount) == 1 and int(failed.failedCount) == 1 \
		and int(failed.byKind.props.failed) == 1)
	_check("failure_diagnostics_are_source_scoped",
		failed.failures.size() == 1 and failed.failures[0].sourceId == "source:props")


func _declare_sources(book, revision: int, bounds: Rect2i, skip_kind := "") -> void:
	for kind: String in VisualReadinessScript.CONTENT_KINDS:
		if kind == skip_kind: continue
		_expect_source(book, kind, revision, bounds)
		book.finish_source("source:" + kind, "identity:" + kind, "rev:1", revision)


func _expect_source(book, kind: String, revision: int, bounds: Rect2i) -> void:
	if kind == "terrain":
		_check("native_terrain_source_footprint_admitted",
			book.declare_terrain_mesh_source_set({"source:terrain": bounds}, revision).status == "ready")
	var result: Dictionary = book.expect_source("source:" + kind, kind, "identity:" + kind,
		"rev:1", bounds, revision)
	_check("source_descriptor_" + kind, result.status == "ready")


func _check(name: String, passed: bool, details: Dictionary = {}) -> void:
	if not passed: _passed = false
	_checks.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])


func write_report() -> void:
	var path := OS.get_environment(REPORT_ENV).strip_edges()
	if path.is_empty(): path = ProjectSettings.globalize_path("res://artifacts/visible-world-readiness-contract.json")
	var directory := path.get_base_dir()
	if directory != "": DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_passed = false
		push_error("could not write visual readiness contract report: " + path)
		return
	file.store_string(JSON.stringify({"schema": "visible-world-readiness-contract/v1",
		"complete": true, "passed": _passed and not _checks.is_empty(), "checkCount": _checks.size(),
		"failureCount": _checks.filter(func(row: Dictionary): return not bool(row.passed)).size(),
		"checks": _checks, "evidenceLevel": "synthetic_owner_receipt_contract",
		"scope": "Request, manifest coverage, tier, installation, revision, and candidate-accounting contracts; no live world visual acceptance."}, "\t"))
	file.close()
