extends SceneTree

## Headless lifecycle proof, not visual or gameplay acceptance. The actual
## normal publisher prepares privately on a worker, then publishes on main.
const Preparation = preload("res://scripts/testing/buildings/CitadelFacadeVisualPreparation.gd")
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
var _thread: Thread
var _preparation
var _prepared: Dictionary = {}
var _checks: Array = []
var _path := ""
var _started := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_path = OS.get_environment("VOXEL_FACADE_VISUAL_PREPARATION_REPORT")
	if not _path.is_absolute_path() or _path.get_extension() != "json" or FileAccess.file_exists(_path) or not DirAccess.dir_exists_absolute(_path.get_base_dir()):
		quit(2)
		return
	_started = Time.get_ticks_msec()
	var cancelled := Preparation.new()
	cancelled.cancel()
	var rejected: Dictionary = cancelled.prepare()
	_check("cancel_before_source_read_rejects", not rejected.ready and rejected.reason == "cancelled_or_deadline")
	_preparation = Preparation.new()
	_thread = Thread.new()
	var error := _thread.start(_preparation.prepare)
	_check("owned_worker_started", error == OK)
	if error != OK:
		_thread = null
		_finish("worker_start")
		return
	var frames := 0
	var max_wait_gap := 0
	var last_frame := Time.get_ticks_msec()
	while _thread.is_alive():
		await process_frame
		frames += 1
		var now := Time.get_ticks_msec()
		max_wait_gap = maxi(max_wait_gap, now - last_frame)
		last_frame = now
		if now - _started > Preparation.LIMIT_MSEC: _preparation.cancel()
	var result: Variant = _thread.wait_to_finish()
	_thread = null
	_prepared = result if result is Dictionary else {"ready": false, "reason": "worker_result"}
	_prepared["observedMainFramesDuringPreparation"] = frames
	_prepared["maxMainFrameGapMsecDuringPreparation"] = max_wait_gap
	_check("actual_preparation_ready", bool(_prepared.get("ready", false)))
	if not _prepared.get("ready", false):
		_finish("preparation_rejected")
		return
	var parent: Node3D = _prepared.publicationRoot
	_check("joined_before_root_attachment", parent.get_parent() == null and not parent.is_inside_tree() and parent.get_child_count() == 0)
	_check("main_frames_advanced_during_work", frames > 0)
	_check("actual_joined_handoff_admitted", Preparation.handoff_ready(_prepared))
	var b = _prepared.blueprint
	var saved_position: Vector3 = b.parts[0].position
	b.parts[0].position += Vector3.ONE
	_check("stale_source_rejected_before_attachment", not Preparation.handoff_ready(_prepared))
	b.parts[0].position = saved_position
	var saved_geometry: Dictionary = _prepared.preparedGeometry
	_prepared.preparedGeometry = {}
	_check("missing_prepared_geometry_binding_rejected", not Preparation.handoff_ready(_prepared))
	_prepared.preparedGeometry = saved_geometry
	var saved_reservations: Array = _prepared.furniture.protected_access_reservations.duplicate()
	_prepared.furniture.protected_access_reservations.append(AABB(Vector3.ZERO, Vector3.ONE))
	_check("stale_access_rejected_before_attachment", not Preparation.handoff_ready(_prepared))
	_prepared.furniture.protected_access_reservations.assign(saved_reservations)
	_check("exact_handoff_restored", Preparation.handoff_ready(_prepared))
	root.add_child(parent)
	_check("second_attachment_rejected", not Preparation.handoff_ready(_prepared))
	var publisher = _prepared.publisher
	var part_index := 0
	var batch_count := 0
	var max_batch_usec := 0
	while part_index < b.parts.size() and Time.get_ticks_msec() - _started < 85000:
		var start := Time.get_ticks_usec()
		var next: int = publisher.publish_part_batch(b, parent, part_index, 6)
		max_batch_usec = maxi(max_batch_usec, Time.get_ticks_usec() - start)
		if next <= part_index or next > mini(part_index + 6, b.parts.size()): break
		part_index = next
		batch_count += 1
		await process_frame
	var summary: Dictionary = publisher.finish_publication(b, parent) if part_index == b.parts.size() else publisher.summary()
	_check("all_parts_published_in_six_part_batches", part_index == b.parts.size() and publisher.published_part_count == b.parts.size() and publisher.incremental_published_parts == b.parts.size())
	_check("paving_publication_complete", summary.get("pavingFootingPublication", {}).get("complete") == true)
	_check("same_bound_postpublication_source", Plan.digest(b.snapshot()) == _prepared.expectedPublishedSourceDigest)
	_check("same_furniture_and_access", Plan.digest([_prepared.furniture.snapshot(), _prepared.furniture.protected_access_reservations]) == _prepared.furnitureDigest)
	_check("source_inputs_and_publisher_dependencies_unchanged", Plan.inputs_current(_prepared.identity))
	_prepared["publication"] = {"partCount": part_index, "batchCount": batch_count, "maxBatchUsec": max_batch_usec,
		"paving": summary.get("pavingFootingPublication", {}), "physicalGatePassed": summary.physicalIntegrity.passed,
		"physicalViolationCount": summary.physicalIntegrity.get("violations", []).size()}
	_prepared["preparedGeometryAfterPublicationExact"] = Preparation.geometry_identity(publisher) == _prepared.preparedGeometry
	_check("prepared_mesh_resources_consumed_without_change", _prepared.preparedGeometryAfterPublicationExact)
	_finish("lifecycle_complete")

func _check(name: String, passed: bool) -> void:
	_checks.append({"name": name, "passed": passed})

func _cleanup() -> void:
	if _preparation != null: _preparation.cancel()
	if _thread != null and _thread.is_started():
		var result: Variant = _thread.wait_to_finish()
		if result is Dictionary: _prepared = result
	_thread = null
	if is_instance_valid(_prepared.get("publicationRoot")):
		_prepared.publisher.clear_published()
		_prepared.publicationRoot.free()
	for key in ["publicationRoot", "publisher", "blueprint", "furniture"]: _prepared.erase(key)

func _finish(reason: String) -> void:
	_cleanup()
	var report := {"passed": _checks.all(func(row): return row.passed), "reason": reason, "checks": _checks,
		"codeIdentity": {"plan": FileAccess.get_sha256("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd"), "preparation": FileAccess.get_sha256("res://scripts/testing/buildings/CitadelFacadeVisualPreparation.gd"), "contract": FileAccess.get_sha256(get_script().resource_path)},
		"preparation": _prepared.get("preparation", {}), "publication": _prepared.get("publication", {}),
		"mainFramesDuringPreparation": _prepared.get("observedMainFramesDuringPreparation", 0),
		"maxMainFrameGapMsecDuringPreparation": _prepared.get("maxMainFrameGapMsecDuringPreparation", 0),
		"preparationFailure": _prepared.get("reason", ""), "bindings": Plan.INPUTS,
		"elapsedMsec": Time.get_ticks_msec() - _started, "evidenceLevel": "headless_actual_source_worker_handoff_and_main_publication",
		"visualAcceptance": false, "headedLaunchApproved": false,
		"doesNotProve": "No GPU images, camera visibility, geometry payload recapture parity, player movement or physical gate zero. Batch maxima are observed, not asserted as a runtime budget pass."}
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("FACADE_VISUAL_PREPARATION ", JSON.stringify({"passed": report.passed, "reason": reason, "checks": _checks.size()}))
	quit(0 if report.passed else 1)

func _finalize() -> void:
	_cleanup()
