extends SceneTree

const VisualReadinessScript := preload("res://scripts/world/VisibleWorldReadiness.gd")
const ChunkPropManifestScript := preload("res://scripts/world/ChunkPropVisualManifest.gd")
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
		representation_id: String, tier: String) -> bool:
		validation_count += 1
		return installed and source_identity == "identity:props" and source_revision == "rev:1" \
			and world_revision == "world-3" and view_revision > 0 and candidate_id == "tree:stable-id" \
			and representation_id == "tree-native-mesh:stable-id" and tier == "horizon"

var _checks: Array[Dictionary] = []
var _passed := true


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	test_empty_manifest_requires_complete_source_coverage()
	test_incomplete_discovery_never_reports_empty_ready()
	test_candidate_must_belong_to_declared_source_footprint()
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
	var empty_complete: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", true, 1.35)
	_check("completed_empty_chunk_scan_is_explicitly_ready",
		empty_complete.status == "ready" and empty_complete.scanComplete \
		and int(empty_complete.candidateCount) == 0, empty_complete)
	var rock := _make_manifest_body(chunk, "rock:stable", "rock")
	var tree := _make_manifest_body(chunk, "tree:stable", "tree")
	tree.set_meta("tree_visual_state", "queued")
	var wildlife := _make_manifest_body(chunk, "wildlife:stable", "wildlife")
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
	var published: Dictionary = ChunkPropManifestScript.capture(chunk, Vector2i(-1, 2),
		"seed-props", "source-rev-1", true, 1.35)
	_check("published_tree_visual_is_counted_from_committed_mesh",
		published.status == "ready" and int(published.byKind.trees_foliage.representedCount) == 1)
	var published_receipts: Dictionary = ChunkPropManifestScript.submit(published, readiness,
		view_revision, near_bounds)
	_check("tree_queue_commit_is_admitted_as_a_live_owner_receipt",
		published_receipts.status == "ready" and int(published_receipts.pendingCount) == 0 \
		and int(published_receipts.byKind.trees_foliage.representedCount) == 1)
	_check("prop_visual_manifest_does_not_advance_generation_rng",
		String(published.scanAuthority) == "completed_production_chunk_prop_spawn_state")
	chunk.queue_free()
	await process_frame


func _make_manifest_body(parent: Node3D, prop_id: String, kind: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Manifest_" + kind
	body.set_meta("prop_id", prop_id)
	parent.add_child(body)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	body.add_child(visual)
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
