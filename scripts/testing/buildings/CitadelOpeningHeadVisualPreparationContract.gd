extends SceneTree

## Actual worker-to-main publication preflight. No GPU/readback or visibility
## claim, no structural gate waiver, no alternative source/renderer.
const Preparation = preload("res://scripts/testing/buildings/CitadelOpeningHeadVisualPreparation.gd")
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Furnisher = preload("res://scripts/buildings/FurnishingPublisher.gd")
const CutInventory = preload("res://scripts/testing/buildings/CitadelOpeningHeadCutInventory.gd")
const HeadVisual = preload("res://scripts/testing/buildings/CitadelOpeningHeadRecipeVisual.gd")
var _thread: Thread
var _preparation
var _prepared: Dictionary = {}
var _checks: Dictionary = {}
var _path := ""
var _started := 0
var _publication: Dictionary = {}
var _furniture_root: Node3D
var _furnisher
var _expectation_only := false
var _review_plan: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	_path = OS.get_environment("VOXEL_OPENING_HEAD_PREPARATION_REPORT")
	var input := OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT")
	var sha := OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT_SHA256")
	_expectation_only = OS.get_environment("VOXEL_OPENING_HEAD_EXPECTATION_CAPTURE") == "1"
	var expectation_path := OS.get_environment("VOXEL_OPENING_HEAD_EXPECTATION_INPUT")
	var expectation_sha := OS.get_environment("VOXEL_OPENING_HEAD_EXPECTATION_SHA256")
	if not _path.is_absolute_path() or FileAccess.file_exists(_path) or not DirAccess.dir_exists_absolute(_path.get_base_dir()):
		quit(2)
		return
	_started = Time.get_ticks_msec()
	var cancelled := Preparation.new()
	cancelled.cancel()
	var negative: Dictionary = cancelled.prepare(input, sha)
	_checks["cancel_before_source_read_rejects"] = not negative.ready and negative.reason == "cancelled_or_deadline"
	_checks["missing_handoff_rejects"] = not Preparation.handoff_ready({})
	_preparation = Preparation.new()
	_thread = Thread.new()
	var operation: Callable = _preparation.capture_expectation.bind(input, sha) if _expectation_only else _preparation.prepare.bind(input, sha, expectation_path, expectation_sha)
	var start_error := _thread.start(operation)
	_checks["owned_worker_started"] = start_error == OK
	if start_error != OK:
		_thread = null
		_finish("worker_start_failed")
		return
	var frames := 0
	var max_gap := 0
	var last_frame := Time.get_ticks_msec()
	var last_progress := last_frame
	while _thread.is_alive():
		await process_frame
		frames += 1
		var now := Time.get_ticks_msec()
		max_gap = maxi(max_gap, now - last_frame)
		last_frame = now
		if now - last_progress >= 5000:
			print("OPENING_HEAD_PREPARATION ", JSON.stringify(_preparation.status()))
			last_progress = now
		if now - _started > Preparation.LIMIT_MSEC: _preparation.cancel()
	var result: Variant = _thread.wait_to_finish()
	_thread = null
	_prepared = result if result is Dictionary else {"ready": false, "reason": "invalid_worker_result"}
	_prepared["mainFramesDuringPreparation"] = frames
	_prepared["maxMainFrameGapMsec"] = max_gap
	_checks["preparation_ready"] = _prepared.get("ready", false)
	if not _checks.preparation_ready:
		_finish("preparation_failed")
		return
	var expected: Dictionary = _prepared.validationExpectation
	_checks["expectation_code_and_input_current"] = Preparation.expectation_current(expected, sha)
	var stale: Dictionary = expected.duplicate(true)
	stale.inputSha256 = "stale"
	_checks["stale_expectation_source_rejects"] = not Preparation.expectation_current(stale, sha)
	stale = expected.duplicate(true)
	stale.implementationIdentity = {}
	_checks["stale_expectation_code_rejects"] = not Preparation.expectation_current(stale, sha)
	if _expectation_only:
		_finish("expectation_complete")
		return
	_checks["wrong_expectation_artifact_hash_rejects"] = Preparation.read_expectation(expectation_path, "0".repeat(64), sha).is_empty()
	_checks["joined_worker_handoff_ready"] = Preparation.worker_handoff_ready(_prepared)
	_checks["pending_masonry_not_final_handoff"] = not Preparation.handoff_ready(_prepared)
	var job_identity: String = _prepared.unadvancedMasonryIdentity
	_prepared.unadvancedMasonryIdentity = "stale"
	_checks["changed_masonry_job_binding_rejects"] = not Preparation.worker_handoff_ready(_prepared)
	_prepared.unadvancedMasonryIdentity = job_identity
	_paving_controls(false)
	_checks["main_masonry_preparation_ready"] = await _preparation.complete_on_main(_prepared, self)
	if not _checks.main_masonry_preparation_ready:
		_finish("main_masonry_preparation_failed")
		return
	var b = _prepared.blueprint
	var parent: Node3D = _prepared.publicationRoot
	var publisher = _prepared.publisher
	var masonry_metrics: Dictionary = publisher._masonry_preparation.metrics
	_checks["one_actual_unit_box_read_for_entire_candidate"] = masonry_metrics.get("unitBoxArrayReadCount") == 1
	_checks["every_candidate_brick_uses_bound_snapshot"] = masonry_metrics.bricks > 0 and masonry_metrics.get("unitBoxTemplateHits") == masonry_metrics.bricks
	_checks["main_frames_advanced"] = frames > 0
	_checks["joined_private_handoff_ready"] = Preparation.handoff_ready(_prepared)
	_paving_controls(true)
	_cut_inventory_controls()
	_opening_head_plan_controls()
	var original: Vector3 = b.parts[0].position
	b.parts[0].position += Vector3.ONE
	_checks["changed_source_rejects"] = not Preparation.handoff_ready(_prepared)
	b.parts[0].position = original
	var geometry: Dictionary = _prepared.preparedGeometry
	_prepared.preparedGeometry = {}
	_checks["missing_resource_binding_rejects"] = not Preparation.handoff_ready(_prepared)
	_prepared.preparedGeometry = geometry
	var reservations: Array = _prepared.furniture.protected_access_reservations.duplicate()
	_prepared.furniture.protected_access_reservations.append(AABB(Vector3.ZERO, Vector3.ONE))
	_checks["changed_furniture_access_rejects"] = not Preparation.handoff_ready(_prepared)
	_prepared.furniture.protected_access_reservations.assign(reservations)
	_checks["exact_handoff_restored"] = Preparation.handoff_ready(_prepared)
	root.add_child(parent)
	_checks["already_attached_handoff_rejects"] = not Preparation.handoff_ready(_prepared)
	var index := 0
	var batches := 0
	var max_batch_usec := 0
	while index < b.parts.size() and Time.get_ticks_msec() - _started < 85000:
		var begin := Time.get_ticks_usec()
		var next: int = publisher.publish_part_batch(b, parent, index, 6)
		max_batch_usec = maxi(max_batch_usec, Time.get_ticks_usec() - begin)
		if next <= index or next > mini(index + 6, b.parts.size()): break
		index = next
		batches += 1
		await process_frame
	var published: Dictionary = publisher.finish_publication(b, parent) if index == b.parts.size() else publisher.summary()
	var artifact_bricks: int = 0
	for artifact: Dictionary in publisher._masonry_preparation._artifacts.values(): artifact_bricks += artifact.entries.size()
	_checks["published_snapshot_hits_match_actual_artifact_entries"] = artifact_bricks > 0 and masonry_metrics.bricks == artifact_bricks and masonry_metrics.get("unitBoxTemplateHits") == artifact_bricks
	_checks["publication_did_not_reread_unit_box"] = publisher._masonry_preparation.metrics.get("unitBoxArrayReadCount") == 1
	_checks["all_source_parts_published_in_order"] = index == b.parts.size() and publisher.published_part_count == b.parts.size() and publisher.incremental_published_parts == b.parts.size()
	_checks["paving_publication_complete"] = published.get("pavingFootingPublication", {}).get("complete", false)
	_checks["masonry_resources_transferred_exactly"] = Preparation.geometry_identity(publisher) == _prepared.preparedGeometry
	_furniture_root = Node3D.new()
	root.add_child(_furniture_root)
	_furnisher = Furnisher.new()
	await _furnisher.publish_incremental(_prepared.furniture, _furniture_root, 6)
	_checks["all_furniture_published"] = _furnisher.published_parts.size() == _prepared.furniture.parts.size() and _prepared.furniture.parts.size() == 152
	_checks["source_exact_after_publication"] = Plan.digest(b.snapshot()) == _prepared.expectedPublishedSourceDigest
	_checks["furniture_exact_after_publication"] = Plan.digest([_prepared.furniture.snapshot(), _prepared.furniture.protected_access_reservations]) == _prepared.furnitureDigest
	_checks["input_still_bound"] = FileAccess.get_sha256(input) == sha
	_publication = {"partCount": index, "furnitureCount": _furnisher.published_parts.size(), "batches": batches, "maxBatchUsec": max_batch_usec,
		"physicalGatePassed": published.physicalIntegrity.passed, "physicalViolationCount": published.physicalIntegrity.violations.size()}
	_finish("lifecycle_complete")

func _opening_head_plan_controls() -> void:
	var publisher = _prepared.publisher
	var inventory: Dictionary = CutInventory.collect(publisher)
	var contacts := HeadVisual.read_review_contacts(OS.get_environment("VOXEL_OPENING_HEAD_CONTACT_INPUT"), OS.get_environment("VOXEL_OPENING_HEAD_CONTACT_SHA256"), _prepared.inputSha256)
	_checks["review_contacts_bound_to_same_candidate_clearance"] = contacts.get("ready", false)
	if not inventory.get("ready", false) or not contacts.get("ready", false): return
	var cuts: Array = []
	for entry: Dictionary in inventory.entries:
		var part = _prepared.blueprint.find_part(entry.partId)
		if not part.recipe.has("masonryApertureSource"): continue
		cuts.append({"key": entry.partId + "::" + String(entry.original.id), "partId": entry.partId, "bounds": entry.original.transform * entry.mesh.get_aabb()})
	var selected := OS.get_environment("VOXEL_OPENING_HEAD_REVIEW_HOUSE")
	_review_plan = HeadVisual.HeadReview.build(_prepared.blueprint.snapshot(), _prepared.houseProposals, [selected], cuts, contacts.contacts)
	_checks["source_derived_review_plan_ready"] = _review_plan.get("ready", false)
	_checks["all_three_actual_masonry_cuts_supplied_to_plan"] = cuts.size() == 3
	if _review_plan.get("ready", false):
		_checks["selected_shard_has_separate_street_detail_and_appearance_context"] = _review_plan.views.size() == 3 and _review_plan.views[0].role == "context" and _review_plan.views[1].role == "cut_detail" and _review_plan.views[2].role == "appearance_context"
		_checks["contacts_stay_explicitly_unresolved"] = not _review_plan.contactMappings.is_empty() and _review_plan.contactMappings.all(func(row: Dictionary) -> bool: return row.status == "RED_UNRESOLVED" and row.contactCleared == false)
		_checks["context_does_not_require_concealed_panels"] = _review_plan.views[0].targets.size() == 1

func _cut_inventory_controls() -> void:
	var publisher = _prepared.publisher
	var inventory: Dictionary = CutInventory.collect(publisher)
	_checks["prepared_cut_inventory_complete"] = inventory.get("ready", false)
	if not inventory.get("ready", false): return
	_checks["current_candidate_has_three_masonry_cut_meshes"] = inventory.masonryMeshCount == 3
	var fixture = HeadVisual.new()
	fixture.building_publisher = publisher
	fixture._requested_stage = "publication_index"
	_checks["index_stage_has_no_views_and_daytime_is_explicit"] = fixture._allowed_review_stages() == ["publication_index", "daytime_shard"] and fixture._view_specs().is_empty()
	var actual: Dictionary = fixture._prepared_cut_entries()
	_checks["inspector_consumes_exact_prepared_cut_inventory"] = actual == inventory
	_checks["opening_head_inspector_code_identity_bound"] = fixture._review_code_identity().has("res://scripts/testing/buildings/CitadelOpeningHeadRecipeVisual.gd")
	fixture.building_publisher = null
	fixture.free()
	var artifacts: Dictionary = publisher._masonry_preparation._artifacts
	var selected := ""
	for id: String in artifacts:
		if not artifacts[id].preparedMeshes.is_empty():
			selected = id
			break
	_checks["actual_masonry_negative_control_subject_present"] = not selected.is_empty()
	if selected.is_empty(): return
	var meshes: Dictionary = artifacts[selected].preparedMeshes
	var key: String = meshes.keys()[0]
	var mesh: Variant = meshes[key].mesh
	meshes[key].mesh = null
	_checks["missing_actual_masonry_cut_mesh_rejects"] = not CutInventory.collect(publisher).get("ready", false)
	meshes[key].mesh = mesh
	meshes["__synthetic_orphan_control"] = meshes[key]
	_checks["orphan_prepared_masonry_mesh_rejects"] = not CutInventory.collect(publisher).get("ready", false)
	meshes.erase("__synthetic_orphan_control")
	var retained: Dictionary = artifacts.duplicate()
	retained.erase(selected)
	publisher._masonry_preparation._artifacts = retained
	_checks["missing_actual_masonry_artifact_rejects"] = not CutInventory.collect(publisher).get("ready", false)
	publisher._masonry_preparation._artifacts = artifacts
	_checks["cut_control_source_and_resources_restored"] = CutInventory.collect(publisher) == inventory and Preparation.handoff_ready(_prepared)

func _paving_controls(final_handoff: bool) -> void:
	var phase := "final" if final_handoff else "worker"
	var publisher = _prepared.publisher
	var original: Dictionary = publisher._paving_artifacts
	var proof: Dictionary = Preparation.source_bound_paving_identity(publisher)
	_checks[phase + "_paving_required_by_source"] = not proof.is_empty() and not proof.requiredFinishIds.is_empty()
	if proof.is_empty() or proof.requiredFinishIds.is_empty(): return
	var masonry_before: Variant = Preparation.geometry_identity(publisher).get("masonry", {}) if final_handoff else Preparation.unadvanced_masonry_identity(publisher)
	var recorded_paving: Dictionary = _prepared.preparedPaving
	# Delete the actual inventory and its initial recorded baseline together.
	# Source declarations must independently reject this empty/empty case.
	publisher._paving_artifacts = {}
	_prepared.preparedPaving = {}
	_checks[phase + "_missing_actual_paving_rejects"] = Preparation.source_bound_paving_identity(publisher).is_empty() and not (Preparation.handoff_ready(_prepared) if final_handoff else Preparation.worker_handoff_ready(_prepared))
	publisher._paving_artifacts = original
	_prepared.preparedPaving = recorded_paving
	var first: String = proof.requiredFinishIds[0]
	var completed: Variant = original[first].artifact.completed
	original[first].artifact.completed = false
	_checks[phase + "_corrupt_actual_paving_rejects"] = Preparation.source_bound_paving_identity(publisher).is_empty() and not (Preparation.handoff_ready(_prepared) if final_handoff else Preparation.worker_handoff_ready(_prepared))
	original[first].artifact.completed = completed
	var masonry_after: Variant = Preparation.geometry_identity(publisher).get("masonry", {}) if final_handoff else Preparation.unadvanced_masonry_identity(publisher)
	_checks[phase + "_paving_controls_preserve_masonry"] = masonry_before == masonry_after
	_checks[phase + "_actual_paving_restored"] = Preparation.handoff_ready(_prepared) if final_handoff else Preparation.worker_handoff_ready(_prepared)

func _cleanup() -> void:
	if _preparation != null: _preparation.cancel()
	if _thread != null and _thread.is_started():
		var result: Variant = _thread.wait_to_finish()
		if result is Dictionary: _prepared = result
	_thread = null
	if is_instance_valid(_prepared.get("publicationRoot")):
		_prepared.publisher.clear_published()
		_prepared.publicationRoot.free()
	if is_instance_valid(_furniture_root): _furniture_root.free()
	if _furnisher != null: _furnisher.published_parts.clear()
	for key in ["publicationRoot", "publisher", "blueprint", "furniture"]: _prepared.erase(key)

func _finish(reason: String) -> void:
	var passed := reason == ("expectation_complete" if _expectation_only else "lifecycle_complete") and not _checks.is_empty() and _checks.values().all(func(value): return value == true)
	var preparation_status: Dictionary = _preparation.status() if _preparation != null else {}
	_cleanup()
	var report := {"passed": passed, "reason": reason, "checks": _checks, "preparation": _prepared.get("preparation", {}), "publication": _publication,
		"preparationFailure": _prepared.get("reason", ""), "elapsedMsec": Time.get_ticks_msec() - _started,
		"preparationStatus": preparation_status, "openingHeadReviewPlan": _review_plan,
		"validationExpectation": _prepared.get("validationExpectation", {}),
		"expectationPath": _prepared.get("expectationPath", ""), "expectationSha256": _prepared.get("expectationSha256", ""),
		"mainFramesDuringPreparation": _prepared.get("mainFramesDuringPreparation", 0), "maxMainFrameGapMsec": _prepared.get("maxMainFrameGapMsec", 0),
		"inputPath": _prepared.get("inputPath", ""), "inputSha256": _prepared.get("inputSha256", ""),
		"evidenceLevel": "offline_validation_expectation" if _expectation_only else "headless_actual_worker_handoff_and_main_publication", "visualAcceptance": false, "headedLaunchApproved": false,
		"limitations": "No GPU indexing/readback, screenshots, camera visibility, runtime budget acceptance, live gameplay, or gate zero. Physical gate failures remain diagnostic and explicit."}
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var wrote := file.get_error() == OK
	file.close()
	quit(0 if passed and wrote else 2)

func _finalize() -> void: _cleanup()
