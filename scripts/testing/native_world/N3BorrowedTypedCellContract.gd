extends SceneTree

const EXTENSION_PATH := "res://addons/terrain_meshing_backend/terrain_meshing_backend.gdextension"
const REPORT_ENV := "VWB_BORROWED_TYPED_CELL_REPORT"
const PAGE_CELLS := 280
const MAX_FRAMES := 10000
const MAX_MSEC := 120000
const HEADER_KEYS := [
	"cell", "section", "localCell", "sourceLayer",
	"materialId", "biomeId", "fluidId", "solid", "density",
	"skyLight", "blockLight", "generated", "edited",
	"hasBlockId", "hasEditReason", "metadataOmitted",
	"blockIdOmitted", "editReasonOmitted",
]

var checks := {}
var observations := {}
var backend
var lease_issue := 0
var cell_issue := 0

func _init() -> void:
	call_deferred("run")

func check(label: String, valid: bool) -> void:
	checks[label] = bool(checks.get(label, true)) and valid

func expected(value: Dictionary, status: String, label: String) -> void:
	check(label, value.get("status") == status)

func expected_reason(value: Dictionary, status: String, reason: String, label: String) -> void:
	check(label, value.get("status") == status and value.get("reason") == reason)

func initialization() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"atlas-1492",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func find_ready_page() -> Dictionary:
	for page in [Vector2i.ZERO]:
		var pinned: Dictionary = backend.pin_effective_page(page)
		if pinned.get("status") == "ready":
			return {"page":page, "status":pinned.get("pageStatus", {})}
	for z in range(-12, 0):
		for x in range(-12, 0):
			var page := Vector2i(x, z)
			if backend.shaping_requests(page).get("status") != "ready":
				continue
			var pinned: Dictionary = backend.pin_effective_page(page)
			if pinned.get("status") == "ready":
				return {"page":page, "status":pinned.get("pageStatus", {})}
	return {}

func state(material_id: int, solid: bool, density: float, sky: int, block: int, source: String) -> Dictionary:
	return {"materialId":material_id,"biomeId":13,"fluidId":0,"solid":solid,
		"density":density,"light":Vector2i(sky, block),
		"metadata":{"source":source,"nested":[{"value":7.5}]},
		"blockId":"borrowed.cell." + source,"editReason":"borrowed_cell_contract"}

func layered_transaction(page: Vector2i) -> Dictionary:
	var overlay_cell := Vector3i(page.x * PAGE_CELLS + 5, 10, page.y * PAGE_CELLS + 7)
	var durable_cell := overlay_cell + Vector3i(1, 0, 0)
	return {"schema":"n3-native-typed-cell-transaction/v1",
		"transactionId":"borrowed-cell:layered","expectedRevision":0,
		"operations":[
			{"namespace":"durable_terrain","kind":"set","cell":overlay_cell,
				"state":state(3, true, 1.25, 4, 9, "durable_under_overlay")},
			{"namespace":"scene_overlay","kind":"set","cell":overlay_cell,
				"state":state(0, false, -0.75, 5, 13, "overlay")},
			{"namespace":"durable_terrain","kind":"set","cell":durable_cell,
				"state":state(3, true, 1.5, 6, 10, "durable_only")}]}

func later_transaction(cell: Vector3i, revision: int) -> Dictionary:
	return {"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"borrowed-cell:between-advance","expectedRevision":revision,
		"operations":[{"kind":"set","cell":cell,
			"state":state(3, true, 2.25, 8, 11, "later_writer")}]}

func seal_lease() -> void:
	if backend == null or lease_issue <= 0:
		return
	if cell_issue > 0:
		var cancelled_child: Dictionary = backend.cancel_borrowed_typed_cell(cell_issue)
		check("cleanup_child_cancel_accepted", cancelled_child.get("status") == "ready"
			and cancelled_child.get("reason") == "typed_cell_cancelled")
		var drained_child: Dictionary = backend.drain_borrowed_typed_cell(cell_issue)
		check("cleanup_child_drained", drained_child.get("status") == "ready"
			and drained_child.get("reason") == "typed_cell_drained")
		if drained_child.get("status") == "ready":
			cell_issue = 0
	if cell_issue == 0:
		var cancelled_lease: Dictionary = backend.cancel_borrowed_source_lease(lease_issue)
		check("cleanup_parent_cancel_accepted", cancelled_lease.get("status") == "ready")
		var drained_lease: Dictionary = backend.drain_borrowed_source_lease(lease_issue)
		check("cleanup_parent_drained", drained_lease.get("status") == "ready")
		if drained_lease.get("status") == "ready":
			lease_issue = 0

func ready_lease(page: Vector2i) -> Dictionary:
	var begin: Dictionary = backend.begin_borrowed_source_lease(page)
	lease_issue = int(begin.get("issue", 0))
	check("parent_lease_begin", begin.get("status") == "pending" and lease_issue > 0)
	if lease_issue <= 0:
		return begin
	var started := Time.get_ticks_msec()
	var result: Dictionary = begin
	for frame in range(MAX_FRAMES):
		if Time.get_ticks_msec() - started > MAX_MSEC:
			break
		var offered := 1 if frame % 5 == 0 else 64
		result = backend.advance_borrowed_source_lease(lease_issue, offered)
		var consumed := int(result.get("consumedOps", -1))
		check("parent_advance_bounded", consumed >= 0 and consumed <= offered)
		if result.get("status") in ["ready", "failed"]:
			break
		await process_frame
	check("parent_lease_ready", result.get("status") == "ready")
	return result

func begin_cell(cell: Vector3i) -> Dictionary:
	var begin: Dictionary = backend.begin_borrowed_typed_cell(lease_issue, cell)
	cell_issue = int(begin.get("cellIssue", 0))
	check("child_begin_pending", begin.get("status") == "pending"
		and cell_issue > 0 and begin.get("leaseIssue") == lease_issue
		and begin.get("reason") == "borrowed_typed_cell_started"
		and begin.get("completeness") == "scalar_header_only")
	return begin

func ready_cell() -> Dictionary:
	var started := Time.get_ticks_msec()
	var result: Dictionary = {}
	var zero_seen := false
	var one_seen := false
	for frame in range(MAX_FRAMES):
		if Time.get_ticks_msec() - started > MAX_MSEC:
			break
		var offered := 0 if frame % 5 == 0 else (1 if frame % 5 == 1 else 64)
		result = backend.advance_borrowed_typed_cell(cell_issue, offered)
		var consumed := int(result.get("consumedOps", -1))
		check("child_advance_bounded", consumed >= 0 and consumed <= offered)
		if offered == 0:
			check("child_zero_quota_reason", result.get("status") == "pending"
				and result.get("reason") == "typed_cell_lookup_pending" and consumed == 0)
		if result.get("status") == "pending":
			var next_atomic := int(result.get("nextAtomicOps", -1))
			check("child_next_atomic_bounded", result.has("nextAtomicOps")
				and next_atomic >= 0 and next_atomic <= 64)
		var frame_work := int(result.get("sharedFrameWorkOps", -1))
		check("child_shared_frame_bounded", result.has("sharedFrameWorkOps")
			and frame_work >= 0 and frame_work <= 64)
		zero_seen = zero_seen or (offered == 0 and consumed == 0)
		one_seen = one_seen or (offered == 1 and consumed == 1)
		if result.get("status") in ["ready", "failed"]:
			break
		await process_frame
	check("child_zero_quota_observed", zero_seen)
	check("child_one_quota_observed", one_seen)
	check("child_reaches_ready", result.get("status") == "ready")
	if result.get("status") == "ready":
		check("child_ready_reason", result.get("reason") == "typed_cell_lookup_complete")
	return result

func drain_cell() -> void:
	if cell_issue <= 0:
		return
	var drained: Dictionary = backend.drain_borrowed_typed_cell(cell_issue)
	check("child_drain_ready", drained.get("status") == "ready"
		and drained.get("reason") == "typed_cell_drained")
	if drained.get("status") == "ready":
		cell_issue = 0

func check_ready_identity(result: Dictionary, parent: Dictionary) -> void:
	check("child_current_source_identity", result.get("sourceIdentity") == parent.get("sourceIdentity"))
	check("child_current_pin_identity", result.get("pinIdentity") == parent.get("pinIdentity"))
	check("child_current_revisions", result.get("terrainDeltaRevision") == parent.get("terrainDeltaRevision")
		and result.get("shapingRegistryRevision") == parent.get("shapingRegistryRevision"))
	check("child_scalar_header_label", result.get("completeness") == "scalar_header_only")

func check_present_header(result: Dictionary, cell: Vector3i, layer: String,
		material: int, solid: bool, density: float, sky: int, block: int) -> void:
	check("present_presence_" + layer, result.get("presence") == "present")
	var header: Dictionary = result.get("header", {})
	var exact_keys := header.size() == HEADER_KEYS.size()
	for key in HEADER_KEYS:
		exact_keys = exact_keys and header.has(key)
	check("present_exact_header_keys_" + layer, exact_keys)
	if not exact_keys:
		return
	check("present_cell_" + layer, header.cell == cell)
	check("present_section_" + layer, header.section == Vector3i(
		floori(float(cell.x) / 16.0), floori(float(cell.y) / 16.0), floori(float(cell.z) / 16.0)))
	check("present_local_cell_" + layer, header.localCell == Vector3i(
		posmod(cell.x, 16), posmod(cell.y, 16), posmod(cell.z, 16)))
	check("present_source_layer_" + layer, header.sourceLayer == layer)
	check("present_scalar_values_" + layer, header.materialId == material
		and header.biomeId == 13 and header.fluidId == 0
		and header.solid == solid and is_equal_approx(float(header.density), density)
		and header.skyLight == sky and header.blockLight == block
		and header.generated == false and header.edited == true)
	check("present_payload_explicitly_omitted_" + layer,
		header.hasBlockId == true and header.hasEditReason == true
		and header.metadataOmitted == true and header.blockIdOmitted == true
		and header.editReasonOmitted == true
		and not header.has("metadata") and not header.has("blockId") and not header.has("editReason"))

func run() -> void:
	check("extension_descriptor_exists", ResourceLoader.exists(EXTENSION_PATH))
	var load_status := GDExtensionManager.LOAD_STATUS_ALREADY_LOADED if GDExtensionManager.is_extension_loaded(EXTENSION_PATH) else GDExtensionManager.load_extension(EXTENSION_PATH)
	check("extension_load_accepted", load_status in [GDExtensionManager.LOAD_STATUS_OK,
		GDExtensionManager.LOAD_STATUS_ALREADY_LOADED])
	check("extension_exact_path_loaded", EXTENSION_PATH in GDExtensionManager.get_loaded_extensions())
	check("backend_class_registered", ClassDB.class_exists("NativeWorldBackend"))
	if not bool(checks.backend_class_registered):
		finish()
		return
	backend = ClassDB.instantiate("NativeWorldBackend")
	check("backend_instantiated", backend != null)
	if backend == null:
		finish()
		return
	expected_reason(backend.begin_borrowed_typed_cell(1, Vector3i.ZERO),
		"failed", "ready_source_lease_required", "child_requires_parent")
	check("backend_initialized", backend.initialize(initialization()).get("status") == "ready")
	var located := find_ready_page()
	check("ready_page_found", not located.is_empty())
	if located.is_empty():
		finish()
		return
	var page: Vector2i = located.page
	var overlay_cell := Vector3i(page.x * PAGE_CELLS + 5, 10, page.y * PAGE_CELLS + 7)
	var durable_cell := overlay_cell + Vector3i(1, 0, 0)
	var absent_cell := overlay_cell + Vector3i(2, 0, 0)
	var later_cell := overlay_cell + Vector3i(3, 0, 0)
	var committed: Dictionary = backend.commit_typed_cells(layered_transaction(page))
	check("real_layered_commit", committed.get("status") == "ready"
		and committed.get("commitStatus") == "committed"
		and int(backend.status().get("terrainDeltaRevision", -1)) == 1)
	if not bool(checks.real_layered_commit):
		finish()
		return
	var parent: Dictionary = await ready_lease(page)
	if parent.get("status") != "ready":
		finish()
		return
	var outside := Vector3i((page.x + 1) * PAGE_CELLS, 10, page.y * PAGE_CELLS + 7)
	expected_reason(backend.begin_borrowed_typed_cell(lease_issue, outside),
		"failed", "cell_outside_primary_page",
		"outside_primary_page_rejected")
	begin_cell(absent_cell)
	if cell_issue <= 0:
		finish()
		return
	expected_reason(backend.drain_borrowed_source_lease(lease_issue),
		"pending", "borrowed_typed_cell_drain_required",
		"parent_drain_waits_for_child")
	expected_reason(backend.begin_borrowed_typed_cell(lease_issue, durable_cell),
		"pending", "prior_cell_not_drained",
		"second_child_refused")
	var absent: Dictionary = await ready_cell()
	check_ready_identity(absent, parent)
	check("absent_has_no_sparse_header", absent.get("presence") == "absent"
		and not absent.has("header"))
	drain_cell()
	begin_cell(durable_cell)
	if cell_issue <= 0:
		finish()
		return
	expected_reason(backend.drain_borrowed_typed_cell(cell_issue),
		"pending", "cancel_before_drain", "pending_child_requires_cancel_before_drain")
	var cancelled_issue := cell_issue
	var cancelled: Dictionary = backend.cancel_borrowed_typed_cell(cell_issue)
	check("direct_child_cancel", cancelled.get("status") == "ready"
		and cancelled.get("reason") == "typed_cell_cancelled")
	var after_cancel: Dictionary = backend.advance_borrowed_typed_cell(cell_issue, 64)
	check("direct_child_cancel_revokes_header", after_cancel.get("status") == "failed"
		and after_cancel.get("reason") == "cell_terminal_drain_required"
		and not after_cancel.has("header"))
	expected_reason(backend.begin_borrowed_typed_cell(lease_issue, durable_cell),
		"pending", "prior_cell_not_drained", "cancelled_child_blocks_rebegin_until_drain")
	drain_cell()
	begin_cell(durable_cell)
	check("direct_child_retry_new_issue", cell_issue > cancelled_issue)
	if cell_issue <= 0:
		finish()
		return
	var durable: Dictionary = await ready_cell()
	check_ready_identity(durable, parent)
	check_present_header(durable, durable_cell, "durable", 3, true, 1.5, 6, 10)
	drain_cell()
	begin_cell(overlay_cell)
	if cell_issue <= 0:
		finish()
		return
	var overlay: Dictionary = await ready_cell()
	check_ready_identity(overlay, parent)
	check_present_header(overlay, overlay_cell, "overlay", 0, false, -0.75, 5, 13)
	check("overlay_precedes_durable_at_same_cell", overlay.get("header", {}).get("sourceLayer") == "overlay")
	check("explicit_air_record_differs_from_absent", overlay.get("presence") == "present"
		and overlay.get("header", {}).get("solid") == false
		and absent.get("presence") == "absent")
	drain_cell()
	begin_cell(later_cell)
	if cell_issue <= 0:
		finish()
		return
	var first: Dictionary = backend.advance_borrowed_typed_cell(cell_issue, 1)
	check("stale_child_first_step_bounded", first.get("status") == "pending"
		and int(first.get("consumedOps", -1)) in [0, 1])
	var before_revision := int(backend.status().get("terrainDeltaRevision", -1))
	var changed: Dictionary = backend.commit_durable_cells(later_transaction(later_cell, before_revision))
	check("real_between_advance_writer", changed.get("status") == "ready"
		and changed.get("commitStatus") == "committed"
		and int(backend.status().get("terrainDeltaRevision", -1)) == before_revision + 1)
	await process_frame
	var stale: Dictionary = backend.advance_borrowed_typed_cell(cell_issue, 64)
	check("stale_child_fails_without_header", stale.get("status") == "failed"
		and stale.get("reason") in ["source_changed", "source_lease_not_ready"]
		and not stale.has("header"))
	drain_cell()
	var parent_stale: Dictionary = backend.advance_borrowed_source_lease(lease_issue, 64)
	check("parent_stale_after_writer", parent_stale.get("status") == "failed"
		and parent_stale.get("reason") == "source_changed")
	var old_lease := lease_issue
	seal_lease()
	check("parent_and_child_drained_after_stale", lease_issue == 0 and cell_issue == 0)
	parent = await ready_lease(page)
	if parent.get("status") != "ready":
		finish()
		return
	begin_cell(overlay_cell)
	if cell_issue <= 0:
		finish()
		return
	var old_child := cell_issue
	var parent_cancel: Dictionary = backend.cancel_borrowed_source_lease(lease_issue)
	var revoked: Dictionary = backend.advance_borrowed_typed_cell(old_child, 64)
	check("parent_cancel_revokes_child", parent_cancel.get("status") == "ready"
		and revoked.get("status") == "failed"
		and revoked.get("reason") == "cell_terminal_drain_required"
		and not revoked.has("header"))
	expected_reason(backend.drain_borrowed_source_lease(lease_issue),
		"pending", "borrowed_typed_cell_drain_required",
		"cancelled_parent_still_waits_for_child_drain")
	drain_cell()
	var parent_drain: Dictionary = backend.drain_borrowed_source_lease(lease_issue)
	check("parent_drains_after_child", parent_drain.get("status") == "ready")
	if parent_drain.get("status") == "ready":
		lease_issue = 0
	var child_replay: Dictionary = backend.advance_borrowed_typed_cell(old_child, 1)
	check("child_replay_rejected_after_drain", child_replay.get("status") == "failed"
		and child_replay.get("reason") == "cell_issue_mismatch")
	var parent_replay: Dictionary = backend.advance_borrowed_source_lease(old_lease, 1)
	check("parent_replay_rejected_after_drain", parent_replay.get("status") == "failed"
		and parent_replay.get("reason") == "lease_issue_mismatch")
	finish()

func finish() -> void:
	if lease_issue > 0:
		seal_lease()
	var failed: Array[String] = []
	for label in checks:
		if not bool(checks[label]):
			failed.append(String(label))
	var report := {"schema":"n3-borrowed-typed-cell-contract/v1",
		"passed":failed.is_empty() and lease_issue == 0 and cell_issue == 0,
		"evidenceLevel":"public NativeWorldBackend scalar_header_only service contract",
		"checks":checks,"failures":failed,"observations":observations,
		"drainedIssues":{"parent":lease_issue == 0,"child":cell_issue == 0},
		"limitations":{"fullGeneratedCellPayload":false,"metadataPayload":false,
			"shapingEffectiveTerrainParity":false,"gameplaySourceAuthority":false,
			"physicalPublication":false,"frameBudgetExhaustionObserved":false,
			"ownerResetReplayObserved":false}}
	var path := OS.get_environment(REPORT_ENV)
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
