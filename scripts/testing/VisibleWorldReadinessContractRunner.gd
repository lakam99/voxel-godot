extends SceneTree

const VisualReadinessScript := preload("res://scripts/world/VisibleWorldReadiness.gd")
const ChunkPropManifestScript := preload("res://scripts/world/ChunkPropVisualManifest.gd")
const TerrainVisualManifestScript := preload("res://scripts/world/VoxelTerrainVisualManifest.gd")
const StructureVisualManifestScript := preload("res://scripts/world/GeneratedStructureVisualManifest.gd")
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

class TerrainPublisherFixture extends RefCounted:
	signal visible_mesh_block_revision_changed(block_position: Vector3i, revision: int)
	var complete := false
	var has_geometry := false
	var block_revision := 1
	var owner_identity := "terrain-fixture-owner"
	var world_revision := "terrain-fixture-world"
	var vertical_bounds := Vector2i(0, 15)

	func visible_mesh_source_identity() -> String:
		return owner_identity

	func visible_mesh_world_revision() -> String:
		return world_revision

	func visible_mesh_source_revision(block: Vector3i) -> String:
		return "%s:%d:%d,%d,%d" % [world_revision, block_revision, block.x, block.y, block.z]

	func visible_mesh_vertical_bounds() -> Vector2i:
		return vertical_bounds

	func visible_mesh_area_complete(_block: Vector3i) -> bool:
		return complete

	func visible_mesh_block_has_geometry(_block: Vector3i) -> bool:
		return has_geometry

	func visible_mesh_receipt_is_current(source_identity: String, source_revision: String,
		current_world_revision: String, _view_revision: int, candidate_id: String,
		metadata: Dictionary, representation_id: String, tier: String) -> bool:
		var block: Vector3i = metadata.get("nativeBlock", Vector3i(-1, -1, -1))
		return complete and has_geometry and source_identity == owner_identity \
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

	func region_publication_readiness(_bounds: Rect2i) -> Dictionary:
		return {"status": physical_status, "reason": "physical_fixture_" + physical_status}

	func region_dependency_requirements(_bounds: Rect2i) -> Dictionary:
		return {"status": description_status, "reason": "source_fixture_" + description_status}

	func region_dependency_revision(_bounds: Rect2i) -> String:
		return revision

var _checks: Array[Dictionary] = []
var _passed := true


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	test_empty_manifest_requires_complete_source_coverage()
	test_exact_subregion_coverage_is_independent()
	test_circular_view_coverage_ignores_outside_corner_cells()
	test_incomplete_discovery_never_reports_empty_ready()
	test_candidate_must_belong_to_declared_source_footprint()
	await test_native_terrain_visual_manifest()
	await test_generated_structure_visual_manifest()
	await test_production_chunk_prop_manifest()
	await test_receipts_are_request_revision_tier_and_installation_bound()
	test_candidate_accounting_and_explicit_failure()
	write_report()
	quit(0 if _passed else 1)


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
		view_revision, near_bounds)
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
		view_revision, near_bounds)
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
		dynamic_lod_readiness, dynamic_lod_view_revision, lod_view_bounds)
	for kind: String in ["terrain", "structures"]:
		var empty_source_id := "lod-empty:%s" % kind
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
	_check("tree_lod_change_advances_visual_source_revision",
		far_tree_manifest.sourceRevision != published.sourceRevision)
	var near_lod_readiness = VisualReadinessScript.new()
	var near_lod_view_revision := int(near_lod_readiness.begin_view(94, "seed-props", "world-props-1",
		lod_view_bounds, lod_view_bounds, lod_center, lod_radius).viewRevision)
	var far_in_near: Dictionary = ChunkPropManifestScript.submit(far_tree_manifest,
		near_lod_readiness, near_lod_view_revision, lod_view_bounds)
	for kind: String in ["terrain", "structures"]:
		var empty_source_id := "lod-empty:%s" % kind
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
		horizon_readiness, horizon_view_revision, horizon_near_bounds)
	for kind: String in ["terrain", "structures"]:
		var empty_source_id := "lod-empty:%s" % kind
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
		clipped_readiness, clipped_revision, clipped_bounds)
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
	_check("mesh_exit_invalidates_completed_manifest_immediately",
		invalidated.status == "pending" and invalidated.reason == "native_terrain_mesh_block_revision_changed")
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
	_check("lower_tier_does_not_satisfy_horizon", low_tier.status == "pending")
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
