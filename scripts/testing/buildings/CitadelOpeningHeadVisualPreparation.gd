extends RefCounted

## Fixture-owned worker preparation. No recipe changes or alternate renderer.
## The caller must join the worker before touching any returned objects.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Furniture = preload("res://scripts/buildings/FurnishingPlan.gd")
const ExistingPreparation = preload("res://scripts/testing/buildings/CitadelFacadeVisualPreparation.gd")
const MAX_BYTES := 32 * 1024 * 1024
const LIMIT_MSEC := 60000
var _mutex := Mutex.new()
var _cancelled := false
var _stage := "not_started"
var _stage_started_usec := 0
var _completed_stage_usec: Dictionary = {}
var _masonry_metrics: Dictionary = {}

func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()

func status() -> Dictionary:
	_mutex.lock()
	var result := {"stage": _stage, "cancelled": _cancelled,
		"masonry": _masonry_metrics.duplicate(),
		"completedStageUsec": _completed_stage_usec.duplicate(),
		"currentStageUsec": Time.get_ticks_usec() - _stage_started_usec if _stage_started_usec > 0 else 0}
	_mutex.unlock()
	return result

func _continue(stage: String, started: int) -> bool:
	_mutex.lock()
	if stage != _stage:
		var now := Time.get_ticks_usec()
		if _stage_started_usec > 0:
			_completed_stage_usec[_stage] = int(_completed_stage_usec.get(_stage, 0)) + now - _stage_started_usec
		_stage_started_usec = now
		_stage = stage
	var result := not _cancelled and Time.get_ticks_msec() - started < LIMIT_MSEC
	_mutex.unlock()
	return result

func capture_expectation(input_path: String, input_sha: String) -> Dictionary:
	# Offline fixture evidence, never a second production validation authority.
	# Later runs still execute the normal publisher and compare with this frozen
	# expectation, rather than deriving their expected value from their own result.
	var started := Time.get_ticks_msec()
	if not _continue("bound_source", started): return _fail("cancelled_or_deadline")
	var archive := read_archive(input_path, input_sha)
	if archive.is_empty(): return _fail("invalid_bound_archive")
	var identity := validation_identity()
	if identity.is_empty(): return _fail("validation_identity_failed")
	var predicted = Copy.copy_blueprint(archive.afterSnapshot)
	if var_to_bytes(predicted.snapshot()) != var_to_bytes(archive.afterSnapshot): return _fail("inexact_prediction_copy")
	if not _continue("predict_raised_route_validation", started): return _fail("cancelled_or_deadline")
	Publisher.CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(predicted)
	if not _continue("predict_physical_validation", started): return _fail("cancelled_or_deadline")
	var physical: Dictionary = predicted.validate_physical_integrity()
	if not _continue("predicted_source_identity", started): return _fail("cancelled_or_deadline")
	var expectation := {"schema": 1, "inputSha256": input_sha,
		"sourceDigest": Plan.digest(archive.afterSnapshot), "postValidationDigest": Plan.digest(predicted.snapshot()),
		"implementationIdentity": identity, "engineVersion": Engine.get_version_info().string,
		"physicalGatePassed": physical.passed, "physicalViolationCount": physical.violations.size()}
	if FileAccess.get_sha256(input_path) != input_sha or validation_identity() != identity or not _continue("expectation_complete", started): return _fail("expectation_input_changed_or_deadline")
	return {"ready": true, "inputPath": input_path, "inputSha256": input_sha, "validationExpectation": expectation}

static func validation_identity() -> Dictionary:
	# Bind the actual preloaded validation/copy closure, including inherited scripts.
	var pending: Array = [Publisher, Copy]
	var visited: Dictionary = {}
	var identity: Dictionary = {}
	while not pending.is_empty():
		if visited.size() >= 512: return {}
		var script: Script = pending.pop_back()
		if script == null or visited.has(script): continue
		visited[script] = true
		var path := script.resource_path.get_slice("::", 0)
		if not path.is_empty():
			var sha := FileAccess.get_sha256(path)
			if sha.length() != 64: return {}
			identity[path] = sha
		var base := script.get_base_script()
		if base != null: pending.append(base)
		for value in script.get_script_constant_map().values():
			if value is Script: pending.append(value)
	return identity

static func expectation_current(value: Dictionary, input_sha: String) -> bool:
	return value.get("schema") == 1 and value.get("inputSha256") == input_sha and value.get("engineVersion") == Engine.get_version_info().string and value.get("implementationIdentity", {}) == validation_identity() and value.get("postValidationDigest", "").length() == 64 and value.get("sourceDigest", "").length() == 64

static func read_expectation(path: String, sha: String, input_sha: String) -> Dictionary:
	if not path.is_absolute_path() or sha.length() != 64 or FileAccess.get_sha256(path) != sha: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var count := file.get_length()
	if count <= 0 or count > 1024 * 1024:
		file.close()
		return {}
	var bytes := file.get_buffer(count)
	var complete := bytes.size() == count and file.get_error() == OK
	file.close()
	var report: Variant = JSON.parse_string(bytes.get_string_from_utf8()) if complete else null
	if not report is Dictionary or report.get("passed") != true or report.get("reason") != "expectation_complete" or not report.get("validationExpectation") is Dictionary or FileAccess.get_sha256(path) != sha: return {}
	var expected: Dictionary = report.validationExpectation
	return expected if expectation_current(expected, input_sha) else {}

func prepare(input_path: String, input_sha: String, expectation_path: String = "", expectation_sha: String = "") -> Dictionary:
	var started := Time.get_ticks_msec()
	if not _continue("bound_source", started): return _fail("cancelled_or_deadline")
	var archive := read_archive(input_path, input_sha)
	if archive.is_empty(): return _fail("invalid_bound_archive")
	var expected := read_expectation(expectation_path, expectation_sha, input_sha)
	if expected.is_empty() or expected.sourceDigest != Plan.digest(archive.afterSnapshot): return _fail("invalid_bound_validation_expectation")
	if not _continue("copy_source_and_furniture", started): return _fail("cancelled_or_deadline")
	var b = Copy.copy_blueprint(archive.afterSnapshot)
	if var_to_bytes(b.snapshot()) != var_to_bytes(archive.afterSnapshot): return _fail("inexact_blueprint_copy")
	var snapshot: Dictionary = archive.furnitureSnapshot
	var furniture = Furniture.new(snapshot.id, int(snapshot.seed), snapshot.sourceBlueprintId)
	furniture.egress_diagnostics = snapshot.egressDiagnostics.duplicate(true)
	for reservation in archive.protectedReservations: furniture.protected_access_reservations.append(reservation)
	for record in snapshot.parts:
		if furniture.add_part(record) == null: return _fail("furniture_access_copy")
	var furniture_digest := Plan.digest([snapshot, archive.protectedReservations])
	if Plan.digest([furniture.snapshot(), furniture.protected_access_reservations]) != furniture_digest: return _fail("inexact_furniture_copy")
	var expected_source: String = expected.postValidationDigest
	if not _continue("normal_publisher_begin", started): return _fail("cancelled_or_deadline")
	var parent := Node3D.new()
	parent.name = "ReviewedOpeningHeadPublication"
	var publisher := Publisher.new()
	var begin_started := Time.get_ticks_usec()
	var begun: bool = publisher.begin_publication(b, parent, {})
	var begin_usec := Time.get_ticks_usec() - begin_started
	if not _continue("verify_prepared_source", started):
		parent.free()
		return _fail("cancelled_or_deadline")
	var untouched := parent.get_parent() == null and not parent.is_inside_tree() and parent.get_child_count() == 0 and publisher.published_part_count == 0 and publisher.published_nodes.is_empty()
	var ready: bool = begun and publisher._masonry_preparation.state in ["pending_budget", "ready"] and untouched
	ready = ready and Plan.digest(b.snapshot()) == expected_source and FileAccess.get_sha256(input_path) == input_sha and _continue("geometry_identity", started)
	if not ready:
		parent.free()
		return _fail("preparation_handoff_rejected")
	var paving_proof := source_bound_paving_identity(publisher)
	var masonry_job := unadvanced_masonry_identity(publisher)
	if masonry_job.is_empty() or paving_proof.is_empty():
		parent.free()
		return _fail("prepared_geometry_identity_failed")
	var paving: Dictionary = paving_proof.identity
	if not _continue("worker_prepared", started):
		parent.free()
		return _fail("cancelled_or_deadline")
	return {"ready": true, "blueprint": b, "furniture": furniture, "publisher": publisher, "publicationRoot": parent, "preparedGeometry": {},
		"requiresMainMasonry": true, "preparedPaving": paving, "unadvancedMasonryIdentity": masonry_job, "preparationStartedMsec": started,
		"expectationPath": expectation_path, "expectationSha256": expectation_sha, "validationExpectation": expected,
		"inputPath": input_path, "inputSha256": input_sha, "fixture": archive.fixture,
		"houseProposals": archive.houseProposals, "expectedPublishedSourceDigest": expected_source,
		"furnitureDigest": furniture_digest, "preparation": {"beginUsec": begin_usec, "elapsedMsec": Time.get_ticks_msec() - started,
		"privateEmptyRoot": untouched, "masonry": publisher._masonry_preparation.metrics.duplicate(true)},
		"limitations": "Worker preparation only. No scene publication, GPU, visuals, integration or gameplay acceptance."}

static func _private_source_exact(review: Dictionary) -> bool:
	if not review.get("ready", false) or not is_instance_valid(review.get("publicationRoot")) or not is_instance_valid(review.get("publisher")) or not is_instance_valid(review.get("blueprint")) or not is_instance_valid(review.get("furniture")): return false
	var parent: Node3D = review.publicationRoot
	var publisher = review.publisher
	if parent.get_parent() != null or parent.is_inside_tree() or parent.get_child_count() != 0 or publisher.published_part_count != 0 or not publisher.published_nodes.is_empty(): return false
	if FileAccess.get_sha256(review.get("inputPath", "")) != review.get("inputSha256", ""): return false
	if read_expectation(review.get("expectationPath", ""), review.get("expectationSha256", ""), review.get("inputSha256", "")) != review.get("validationExpectation", {}) or review.get("validationExpectation", {}).is_empty(): return false
	if Plan.digest(review.blueprint.snapshot()) != review.get("expectedPublishedSourceDigest") or Plan.digest([review.furniture.snapshot(), review.furniture.protected_access_reservations]) != review.get("furnitureDigest"): return false
	return true

static func unadvanced_masonry_identity(publisher) -> String:
	var job = publisher._masonry_preparation
	if job == null or job.state not in ["pending_budget", "ready"] or job.metrics.turns != 0 or job._part_cursor != 0 or job._brick_cursor != 0 or not job._current.is_empty() or not job._artifacts.is_empty(): return ""
	if job._unit_snapshot != null or job._unit_owner == null or job._unit_owner.get_ref() != publisher: return ""
	if not job.unit_source_pending_matches(publisher): return ""
	var requests: Array = []
	for request in job._requests:
		requests.append([request.part.get_instance_id(), request.source, request.record, request.key, request.volumes])
	return Plan.digest([job._context, job._unit_binding, job._source_count, job._source_order.map(func(part): return part.get_instance_id()), requests, job._declarations])

static func worker_handoff_ready(review: Dictionary) -> bool:
	return _private_source_exact(review) and review.get("requiresMainMasonry") == true and source_bound_paving_identity(review.publisher).get("identity") == review.get("preparedPaving") and not String(review.get("unadvancedMasonryIdentity", "")).is_empty() and unadvanced_masonry_identity(review.publisher) == review.unadvancedMasonryIdentity

func complete_on_main(review: Dictionary, tree: SceneTree) -> bool:
	# Mesh APIs run on their owning main thread, through the unchanged resumable
	# publisher. Join the private worker first; keep the root unattached throughout.
	if OS.get_thread_caller_id() != OS.get_main_thread_id() or not worker_handoff_ready(review): return _main_failure(review, "invalid_worker_to_main_handoff")
	var publisher = review.publisher
	var cadence := {"lastAdvanceEndUsec": -1, "betweenAdvanceUsec": 0, "maxBetweenAdvanceUsec": 0,
		"firstDrawnFrame": Engine.get_frames_drawn(), "actualDrawnFrames": 0}
	while true:
		# Account for the resumed frame BEFORE either terminal branch. The helper
		# consumes each last-end timestamp, so failure/completion cannot double count.
		if not record_cadence(cadence, Time.get_ticks_usec(), Engine.get_frames_drawn()): return _main_failure(review, "invalid_cadence_clock")
		_publish_masonry_metrics(review, publisher, cadence)
		if publisher._masonry_preparation.state != "pending_budget": break
		if not _continue("main_masonry_preparation", review.preparationStartedMsec): return _main_failure(review, "main_masonry_cancelled_or_deadline")
		publisher._masonry_preparation.advance(publisher)
		cadence.lastAdvanceEndUsec = Time.get_ticks_usec()
		_publish_masonry_metrics(review, publisher, cadence)
		await tree.process_frame
	if publisher._masonry_preparation.state != "ready" or not _private_source_exact(review) or source_bound_paving_identity(publisher).get("identity") != review.preparedPaving: return _main_failure(review, "main_masonry_binding_or_preparation_failed")
	if not _continue("geometry_identity", review.preparationStartedMsec): return _main_failure(review, "geometry_identity_cancelled_or_deadline")
	review.preparedGeometry = geometry_identity(publisher)
	review.requiresMainMasonry = false
	review.preparation.masonry = _masonry_metrics.duplicate(true)
	review.preparation.elapsedMsec = Time.get_ticks_msec() - int(review.preparationStartedMsec)
	if not _continue("prepared", review.preparationStartedMsec) or not handoff_ready(review): return _main_failure(review, "final_preparation_handoff_failed")
	return true

static func record_cadence(cadence: Dictionary, now_usec: int, drawn_frames: int) -> bool:
	if now_usec < 0 or drawn_frames < int(cadence.firstDrawnFrame): return false
	var previous: int = cadence.lastAdvanceEndUsec
	if previous >= 0:
		if now_usec < previous: return false
		var gap := now_usec - previous
		cadence.betweenAdvanceUsec += gap
		cadence.maxBetweenAdvanceUsec = maxi(cadence.maxBetweenAdvanceUsec, gap)
		cadence.lastAdvanceEndUsec = -1
	cadence.actualDrawnFrames = drawn_frames - int(cadence.firstDrawnFrame)
	return true

func _publish_masonry_metrics(review: Dictionary, publisher, cadence: Dictionary) -> void:
	_mutex.lock()
	_masonry_metrics = publisher._masonry_preparation.metrics.duplicate()
	for key: String in ["betweenAdvanceUsec", "maxBetweenAdvanceUsec", "actualDrawnFrames"]:
		_masonry_metrics[key] = cadence[key]
	_mutex.unlock()
	review.preparation.masonry = _masonry_metrics.duplicate()

func _main_failure(review: Dictionary, reason: String) -> bool:
	review.reason = reason
	review.preparationStatus = status()
	return false

static func handoff_ready(review: Dictionary) -> bool:
	if not _private_source_exact(review) or review.get("requiresMainMasonry", true): return false
	var actual := geometry_identity(review.publisher)
	return not actual.is_empty() and actual == review.get("preparedGeometry", {})

static func geometry_identity(publisher) -> Dictionary:
	# The same resources must move from the worker to the renderer. Reuse the
	# established paving identity, and bind every prepared masonry mesh too.
	var paving_proof := source_bound_paving_identity(publisher)
	if paving_proof.is_empty(): return {}
	var paving: Dictionary = paving_proof.identity
	var preparation = publisher._masonry_preparation
	if preparation == null or preparation.state != "ready" or preparation._artifacts.size() > preparation.MAX_PARTS: return {}
	if not preparation.validate_unit_source(publisher): return {}
	var masonry: Dictionary = {}
	for id: String in preparation._artifacts:
		var artifact: Dictionary = preparation._artifacts[id].duplicate(true)
		for key: String in artifact.preparedMeshes:
			var entry: Dictionary = artifact.preparedMeshes[key]
			if entry.get("mesh") == null: continue
			var mesh: ArrayMesh = entry.mesh
			if mesh.get_surface_count() != 1: return {}
			entry.mesh = {"instanceId": mesh.get_instance_id(), "arrays": mesh.surface_get_arrays(0), "primitive": mesh.surface_get_primitive_type(0)}
		masonry[id] = Plan.digest(artifact)
	if masonry.size() != preparation.metrics.parts: return {}
	return {"paving": paving, "masonry": masonry}

static func source_bound_paving_identity(publisher) -> Dictionary:
	# Required membership comes from committed source, not surviving artifacts.
	# An empty inventory cannot certify a source that declares a jointed finish.
	var job = publisher._masonry_preparation
	if job == null or job._blueprint == null or job._blueprint.parts.size() > 10000: return {}
	var required: Dictionary = {}
	for part in job._blueprint.parts:
		if part == null: return {}
		if part.recipe.has("pavingFootingJoints"):
			if part.id.is_empty() or required.has(part.id): return {}
			required[part.id] = true
	if required.size() > publisher.MAX_JOINTED_FINISHES or required.size() != publisher._paving_artifacts.size(): return {}
	for id in required:
		if not publisher._paving_artifacts.has(id): return {}
	if not required.is_empty() and publisher._paving_blueprint != job._blueprint: return {}
	var identity: Dictionary = ExistingPreparation.geometry_identity(publisher)
	if identity.size() != required.size(): return {}
	for id in required:
		if not identity.has(id): return {}
	return {"ready": true, "identity": identity, "requiredFinishIds": required.keys()}

static func read_archive(path: String, sha: String) -> Dictionary:
	if not path.is_absolute_path() or sha.length() != 64 or sha.hex_decode().size() != 32 or FileAccess.get_sha256(path) != sha: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var count := file.get_length()
	if count <= 0 or count > MAX_BYTES:
		file.close()
		return {}
	var bytes := file.get_buffer(count)
	var complete := bytes.size() == count and file.get_error() == OK
	file.close()
	var value: Variant = bytes_to_var(bytes) if complete else null
	if not value is Dictionary or var_to_bytes(value) != bytes or FileAccess.get_sha256(path) != sha: return {}
	if not value.get("afterSnapshot") is Dictionary or not value.afterSnapshot.get("parts") is Array or value.afterSnapshot.parts.size() > 10000: return {}
	if not value.get("houseProposals") is Array or value.houseProposals.is_empty() or value.houseProposals.size() > 64: return {}
	if not value.get("furnitureSnapshot") is Dictionary or not value.furnitureSnapshot.get("parts") is Array or value.furnitureSnapshot.parts.size() > 1024: return {}
	if not value.furnitureSnapshot.get("egressDiagnostics") is Dictionary or not value.get("protectedReservations") is Array or not value.get("fixture") is Dictionary: return {}
	return value

func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason, "preparationStatus": status()}
