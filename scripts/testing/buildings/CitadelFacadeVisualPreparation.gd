extends RefCounted

## Fixture-owned preparation only. A worker owns every object returned here
## until it is joined. The parent remains off-tree; normal publication APIs
## own all geometry and validation. No generated source or gate waiver added.
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const LIMIT_MSEC := 60000
var _mutex := Mutex.new()
var _cancelled := false
var _stage := "not_started"

func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()

func status() -> Dictionary:
	_mutex.lock()
	var result := {"stage": _stage, "cancelled": _cancelled}
	_mutex.unlock()
	return result

func _continue(stage: String, started: int) -> bool:
	_mutex.lock()
	_stage = stage
	var result: bool = not _cancelled and Time.get_ticks_msec() - started < LIMIT_MSEC
	_mutex.unlock()
	return result

func prepare() -> Dictionary:
	var started := Time.get_ticks_msec()
	if not _continue("bound_source", started): return _fail("cancelled_or_deadline")
	var review := Plan.load_review()
	if not review.get("ready", false): return review
	if not _continue("normal_publisher_begin", started): return _fail("cancelled_or_deadline")
	var parent := Node3D.new()
	parent.name = "ReviewedFacadePublication"
	var publisher := Publisher.new()
	var begin_started := Time.get_ticks_msec()
	var begun: bool = publisher.begin_publication(review.blueprint, parent, {})
	var begin_elapsed := Time.get_ticks_msec() - begin_started
	var untouched: bool = parent.get_parent() == null and not parent.is_inside_tree() and parent.get_child_count() == 0 and publisher.published_nodes.is_empty() and publisher.published_part_count == 0
	var post_digest: String = Plan.digest(review.blueprint.snapshot())
	var exact: bool = post_digest == review.expectedPublishedSourceDigest
	var policy_exact: bool = Plan.digest([review.furniture.snapshot(), review.furniture.protected_access_reservations]) == review.furnitureDigest
	var current: bool = Plan.inputs_current(review.identity)
	var allowed: bool = _continue("prepared", started)
	var telemetry := {"beginReady": begun, "beginElapsedMsec": begin_elapsed, "elapsedMsec": Time.get_ticks_msec() - started,
		"privateEmptyRootUnchanged": untouched, "postValidationDigest": post_digest, "boundPostValidationExact": exact,
		"furnitureAndReservationsExact": policy_exact, "inputsCurrent": current, "withinDeadline": allowed}
	if not begun or not untouched or not exact or not policy_exact or not current or not allowed:
		parent.free()
		return {"ready": false, "reason": "preparation_handoff_rejected", "telemetry": telemetry}
	review["publisher"] = publisher
	review["publicationRoot"] = parent
	review["preparation"] = telemetry
	review["preparedGeometry"] = geometry_identity(publisher)
	return review

static func handoff_ready(review: Dictionary) -> bool:
	if not review.get("ready", false) or not is_instance_valid(review.get("publicationRoot")) or not is_instance_valid(review.get("publisher")): return false
	var parent: Node3D = review.publicationRoot
	if parent.get_parent() != null or parent.is_inside_tree() or parent.get_child_count() != 0: return false
	if review.publisher.published_part_count != 0 or not review.publisher.published_nodes.is_empty(): return false
	if Plan.digest(review.blueprint.snapshot()) != review.expectedPublishedSourceDigest or Plan.digest([review.furniture.snapshot(), review.furniture.protected_access_reservations]) != review.furnitureDigest: return false
	if not Plan.inputs_current(review.identity): return false
	var now := geometry_identity(review.publisher)
	return not now.is_empty() and now == review.get("preparedGeometry", {})

static func geometry_identity(publisher) -> Dictionary:
	# Read exact prepared resources, including real arrays. Instance identity is
	# intentional: ownership transfers; no resource is rebuilt during handoff.
	var result: Dictionary = {}
	if publisher._paving_artifacts.size() > publisher.MAX_JOINTED_FINISHES: return {}
	for id in publisher._paving_artifacts:
		var prepared: Dictionary = publisher._paving_artifacts[id]
		var artifact: Dictionary = prepared.artifact
		if not publisher._paving_artifact_valid(artifact, publisher._paving_blueprint.find_part(id)): return {}
		var value: Dictionary = artifact.duplicate(true)
		for entry in value.entries:
			if not entry.has("mesh") or entry.mesh == null: continue
			var mesh: ArrayMesh = entry.mesh
			entry.mesh = {"instanceId": mesh.get_instance_id(), "arrays": mesh.surface_get_arrays(0), "primitive": mesh.surface_get_primitive_type(0)}
		result[id] = {"artifactDigest": Plan.digest(value), "bindingDigest": Plan.digest(prepared.sourceBinding)}
	return result

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
