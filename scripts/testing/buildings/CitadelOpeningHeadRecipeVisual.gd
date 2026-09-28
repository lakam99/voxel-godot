extends "res://scripts/testing/buildings/CitadelFacadeRecipeVisual.gd"

## Staged inspection using the existing scene publisher and ray inspector.
## Each headed launch needs a separately reviewed stage grant. Daytime shards
## inspect source-derived exposed changes; no movement, repairs or acceptance.
const HeadPreparation = preload("res://scripts/testing/buildings/CitadelOpeningHeadVisualPreparation.gd")
const HeadCuts = preload("res://scripts/testing/buildings/CitadelOpeningHeadCutInventory.gd")
const HeadReview = preload("res://scripts/testing/buildings/CitadelOpeningHeadReviewPlan.gd")
var _contact_review_binding: Dictionary = {}

func _allowed_review_stages() -> Array:
	return ["publication_index", "daytime_shard"]

func _new_review_preparation():
	return HeadPreparation.new()

func _review_preparation_callable(provider) -> Callable:
	return provider.prepare.bind(OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT"),
		OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT_SHA256"),
		OS.get_environment("VOXEL_OPENING_HEAD_EXPECTATION_INPUT"),
		OS.get_environment("VOXEL_OPENING_HEAD_EXPECTATION_SHA256"))

func _complete_review_preparation() -> bool:
	if not HeadPreparation.worker_handoff_ready(_facade_prepared): return false
	return await _facade_preparation.complete_on_main(_facade_prepared, get_tree())

func _prepared_review_metadata() -> Dictionary:
	return {"preparation": _facade_prepared.preparation, "fixture": _facade_prepared.fixture,
		"houseProposals": _facade_prepared.houseProposals, "headlessPreflight": _headless_preflight,
		"bindings": {"candidate": {"path": _facade_prepared.inputPath, "sha256": _facade_prepared.inputSha256},
			"expectation": {"path": _facade_prepared.expectationPath, "sha256": _facade_prepared.expectationSha256}},
		"validationExpectation": _facade_prepared.validationExpectation,
		"clearanceStatus": "REJECTED_341_render_contacts_and_39_source_contacts_not_waived",
		"scope": "Prepared-resource transfer and actual renderer indexing only. No appearance or runtime performance acceptance." if _requested_stage == "publication_index" else "Source-derived daytime capture shard; images await inspection. No clearance, structural, runtime-performance or gameplay acceptance."}

func _source_exact() -> bool:
	if blueprint == null or furnishing_plan == null or _facade_prepared.is_empty(): return false
	if not _contact_review_binding.is_empty():
		for key: String in ["classifier", "clearance"]:
			var binding: Dictionary = _contact_review_binding[key]
			if FileAccess.get_sha256(binding.path) != binding.sha256: return false
	if FileAccess.get_sha256(_facade_prepared.inputPath) != _facade_prepared.inputSha256: return false
	if HeadPreparation.read_expectation(_facade_prepared.expectationPath, _facade_prepared.expectationSha256, _facade_prepared.inputSha256) != _facade_prepared.validationExpectation: return false
	return FacadePlan.digest(blueprint.snapshot()) == _facade_prepared.expectedPublishedSourceDigest and FacadePlan.digest([furnishing_plan.snapshot(), furnishing_plan.protected_access_reservations]) == _facade_prepared.furnitureDigest and HeadPreparation.geometry_identity(building_publisher) == _facade_prepared.preparedGeometry

func _prepared_cut_entries() -> Dictionary:
	var inventory: Dictionary = HeadCuts.collect(building_publisher)
	_review["cutInventory"] = {"ready": inventory.get("ready", false), "reason": inventory.get("reason", ""),
		"masonryMeshCount": inventory.get("masonryMeshCount", 0), "pavingMeshCount": inventory.get("pavingMeshCount", 0)}
	return inventory

func _view_specs() -> Array:
	if _requested_stage != "daytime_shard": return []
	var selected := OS.get_environment("VOXEL_OPENING_HEAD_REVIEW_HOUSE").strip_edges()
	_contact_review_binding = read_review_contacts(OS.get_environment("VOXEL_OPENING_HEAD_CONTACT_INPUT"), OS.get_environment("VOXEL_OPENING_HEAD_CONTACT_SHA256"), _facade_prepared.inputSha256)
	if selected.is_empty() or not _contact_review_binding.get("ready", false): return []
	var inventory := HeadCuts.collect(building_publisher)
	if not inventory.get("ready", false): return []
	var cuts: Array = []
	var exact_by_key: Dictionary = {}
	for entry: Dictionary in inventory.entries:
		var part = blueprint.find_part(entry.partId)
		if part == null: return []
		if not part.recipe.has("masonryApertureSource"): continue
		var bound: Dictionary = _cut_meshes.get(entry.mesh.get_instance_id(), {})
		if bound.is_empty() or bound.partId != entry.partId or bound.instances.size() != 1: return []
		var instance: Dictionary = bound.instances[0]
		var primitive := _primitive({"node": instance.node, "partId": entry.partId}, instance.index)
		if primitive.is_empty(): return []
		var key: String = entry.partId + "::" + String(entry.original.id)
		if exact_by_key.has(key): return []
		exact_by_key[key] = primitive
		cuts.append({"key": key, "partId": entry.partId, "bounds": primitive.transform * primitive.localBounds})
	var plan := HeadReview.build(blueprint.snapshot(), _facade_prepared.houseProposals, [selected], cuts, _contact_review_binding.contacts)
	_review["openingHeadPlan"] = plan
	_review["contactBindings"] = {"classifier": _contact_review_binding.classifier, "clearance": _contact_review_binding.clearance, "candidateSha256": _contact_review_binding.candidateSha256}
	if not plan.get("ready", false): return []
	var specs: Array = plan.views.duplicate(true)
	for spec: Dictionary in specs:
		if spec.role in ["context", "appearance_context"] and not _merge_published_context(spec, plan.inventory.selectedClosureIds): return []
		if spec.has("exactCutKey"):
			if not exact_by_key.has(spec.exactCutKey): return []
			spec["exactPrimitive"] = exact_by_key[spec.exactCutKey]
	_expected_views = specs.size()
	_review["contextIncludesActualPublishedClosureBounds"] = true
	return specs

func _merge_published_context(spec: Dictionary, closure_ids: Array) -> bool:
	if closure_ids.is_empty() or not spec.get("bounds") is AABB or not _finite_box(spec.bounds): return false
	var combined: AABB = spec.bounds
	for id: String in closure_ids:
		if not _part_visuals.has(id): return false
		var actual := _published_bounds(id)
		if not _finite_box(actual): return false
		combined = combined.merge(actual)
	spec.bounds = combined
	return true

func _distributed_view_coverage(spec: Dictionary) -> bool:
	if not spec.has("exactCutKey"): return super._distributed_view_coverage(spec)
	if not spec.get("exactPrimitive") is Dictionary or not spec.get("cutBounds") is AABB or not _cut_meshes_exact(): return false
	return _patch_coverage(spec.exactPrimitive.partId, spec.cutBounds, null, spec.exactPrimitive)

func _choose_view(spec: Dictionary) -> Dictionary:
	var result: Dictionary = await super._choose_view(spec)
	if result.get("ok", false) or spec.get("kind") != "close_inspection" or _headless_preflight: return result
	var attempted: Dictionary = result.get("lastAttempt", {})
	if not diagnostic_pose_valid(attempted) or not _diagnostic_state_valid(): return result
	_camera.global_position = attempted.position
	_camera.look_at(attempted.target, Vector3.UP)
	for frame in range(8):
		await get_tree().process_frame
		if _finished or not _budget_reason().is_empty(): return result
	if not _diagnostic_state_valid(): return result
	if _diagnostic_stopped(): return result
	var picture := _read_diagnostic_image()
	if _diagnostic_stopped(): return result
	var path := screenshot_dir.path_join(spec.id + "_REJECTED_DIAGNOSTIC.png")
	if not picture.is_empty() and not FileAccess.file_exists(path) and picture.save_png(path) == OK:
		if _diagnostic_stopped(): return result
		# Deliberately not `captured`, `cameraPassed`, or an accepted-view row.
		result["rejectedDiagnostic"] = {"path": path, "pose": attempted,
			"fov": _camera.fov, "near": _camera.near, "far": _camera.far,
			"accepted": false, "scope": "Rejected attempted appearance pose only; no visibility, access, clearance or gate credit."}
	return result

static func diagnostic_pose_valid(attempted: Dictionary) -> bool:
	return attempted.get("position") is Vector3 and attempted.position.is_finite() and attempted.get("target") is Vector3 and attempted.target.is_finite() and attempted.position.distance_squared_to(attempted.target) > 0.0001 and attempted.get("candidateIndex") is int and attempted.candidateIndex >= 0 and attempted.candidateIndex < 16 and attempted.get("framingPassed") is bool and attempted.get("missingCoverage") is Dictionary

func _diagnostic_state_valid() -> bool:
	if _diagnostic_stopped(): return false
	var valid := _hidden.is_empty() and _source_exact() and _cut_meshes_exact() and _before_state == _live_state_digest() and _visual_identity == _review_code_identity() and _initial_lighting == _lighting_snapshot()
	return valid and not _diagnostic_stopped()

func _diagnostic_stopped() -> bool:
	return _finished or not _budget_reason().is_empty() or not _state_error.is_empty()

func _read_diagnostic_image() -> Image:
	RenderingServer.force_draw(false)
	return get_viewport().get_texture().get_image()

func _extra_review_code_identity() -> Dictionary:
	var identity: Dictionary = {}
	for path: String in ["res://scripts/testing/buildings/CitadelOpeningHeadRecipeVisual.gd",
		"res://scripts/testing/buildings/CitadelOpeningHeadVisualPreparation.gd",
		"res://scripts/testing/buildings/CitadelOpeningHeadReviewPlan.gd",
		"res://scripts/testing/buildings/CitadelOpeningHeadCutInventory.gd",
		"res://scenes/testing/buildings/CitadelOpeningHeadRecipeVisual.tscn"]:
		identity[path] = FileAccess.get_sha256(path)
	return identity

static func read_review_contacts(path: String, sha: String, candidate_sha: String) -> Dictionary:
	if candidate_sha.length() != 64: return {}
	var report := _read_bound_review_json(path, sha)
	if report.get("measurementComplete") != true or report.get("acceptanceClaim") != false or report.get("candidateSHA256") != candidate_sha or not report.get("contacts") is Array: return {}
	if not report.get("inputs") is Dictionary or not report.inputs.get("clearance") is Dictionary: return {}
	var binding: Dictionary = report.inputs.clearance
	if not binding.get("path") is String or not binding.get("sha256") is String: return {}
	var clearance := _read_bound_review_json(binding.path, binding.sha256)
	if clearance.get("candidateSha256") != candidate_sha or not clearance.get("blockedOrUnresolved") is Array: return {}
	var raw: Array = clearance.blockedOrUnresolved
	if raw.size() > 4096 or report.contacts.size() > 4096: return {}
	var required: Dictionary = {}
	for index: int in range(raw.size()):
		if not raw[index] is Dictionary: return {}
		if raw[index].get("channel") == "CPU_neighbour_render_envelope": required[index] = true
	if required.is_empty(): return {}
	var seen: Dictionary = {}
	for row: Variant in report.contacts:
		if not row is Dictionary or not row.get("sourceArrayIndex") is float or not is_finite(row.sourceArrayIndex): return {}
		var index: int = int(row.sourceArrayIndex)
		if float(index) != row.sourceArrayIndex or not required.has(index) or seen.has(index): return {}
		if row.get("rowId") != binding.sha256 + ":blockedOrUnresolved:" + str(index) or row.get("inputRow") != raw[index]: return {}
		seen[index] = true
	if seen.size() != required.size(): return {}
	return {"ready": true, "contacts": report.contacts,
		"classifier": {"path": path, "sha256": sha}, "clearance": {"path": binding.path, "sha256": binding.sha256},
		"candidateSha256": candidate_sha, "clearanceAcceptance": false}

static func _read_bound_review_json(path: String, sha: String) -> Dictionary:
	if not path.is_absolute_path() or sha.length() != 64 or FileAccess.get_sha256(path) != sha: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var count := file.get_length()
	if count <= 0 or count > 64 * 1024 * 1024:
		file.close()
		return {}
	var bytes := file.get_buffer(count)
	var complete := bytes.size() == count and file.get_error() == OK
	file.close()
	var result: Variant = JSON.parse_string(bytes.get_string_from_utf8()) if complete else null
	return result if result is Dictionary and FileAccess.get_sha256(path) == sha else {}
