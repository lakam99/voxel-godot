extends RefCounted
class_name VisibleWorldReadiness

## Request-scoped accounting for visual representations. This book owns no
## geometry: publishers describe deterministic candidates and acknowledge an
## installed representation only after their own publication has committed.
const CONTENT_KINDS := ["terrain", "structures", "trees_foliage", "props", "wildlife"]
const REPRESENTATION_TIERS := ["near", "horizon"]
const MAX_SOURCES := 4096
const MAX_CANDIDATES := 250000
const MAX_FAILURES := 256

var _request_id := 0
var _seed := ""
var _world_revision := ""
var _view_revision := 0
var _bounds := Rect2i()
var _near_bounds := Rect2i()
var _view_center := Vector2()
var _view_radius := 0.0
var _view_active := false
var _source_set_sealed := false
var _sources: Dictionary = {}
var _candidate_count := 0
var _failure_rows: Array[Dictionary] = []
var _queue_diagnostics: Dictionary = {}
var _coverage_lag := 0.0


## A changed request, source revision, or view envelope starts a fresh visual
## demand. Revisions only advance; receipts from an older view cannot be reused.
func begin_view(request_id: int, seed: String, world_revision: String,
		bounds: Rect2i, near_bounds: Rect2i, view_center: Vector2, view_radius: float) -> Dictionary:
	if request_id <= 0 or seed.strip_edges().is_empty() or world_revision.strip_edges().is_empty() \
			or not _valid_bounds(bounds) or not _valid_bounds(near_bounds) or not bounds.encloses(near_bounds) \
		or not is_finite(view_radius) or view_radius <= 0.0:
		return {"status": "failed", "reason": "invalid_visual_view_demand", "viewRevision": _view_revision}
	var identity := {"requestId": request_id, "seed": seed, "worldRevision": world_revision,
		"bounds": bounds, "nearBounds": near_bounds, "viewCenter": view_center, "viewRadius": view_radius}
	var previous := {"requestId": _request_id, "seed": _seed, "worldRevision": _world_revision,
		"bounds": _bounds, "nearBounds": _near_bounds, "viewCenter": _view_center, "viewRadius": _view_radius}
	if not _view_active or identity != previous:
		_view_revision += 1
		_request_id = request_id
		_seed = seed
		_world_revision = world_revision
		_bounds = bounds
		_near_bounds = near_bounds
		_view_center = view_center
		_view_radius = view_radius
		_view_active = true
		_source_set_sealed = false
		_sources.clear()
		_candidate_count = 0
		_failure_rows.clear()
		_queue_diagnostics.clear()
		_coverage_lag = 0.0
	return {"status": "ready", "viewRevision": _view_revision, "requestId": _request_id,
		"worldRevision": _world_revision}


## Each declared source owns a complete half-open XZ footprint. The source may
## report an empty manifest only after finish_source() confirms enumeration.
func expect_source(source_id: String, kind: String, source_identity: String,
		source_revision: String, source_bounds: Rect2i, view_revision: int) -> Dictionary:
	if not _view_active or _source_set_sealed:
		return {"status": "failed", "reason": "visual_source_set_closed"}
	if view_revision != _view_revision:
		return {"status": "pending", "reason": "visual_view_revision_changed"}
	if source_id.strip_edges().is_empty() or source_identity.strip_edges().is_empty() \
			or source_revision.strip_edges().is_empty() or not CONTENT_KINDS.has(kind) \
			or not _valid_bounds(source_bounds) or not source_bounds.intersects(_bounds):
		return {"status": "failed", "reason": "invalid_visual_source_manifest"}
	if _sources.has(source_id):
		var old: Dictionary = _sources[source_id]
		var same: bool = String(old.kind) == kind and String(old.identity) == source_identity \
			and String(old.revision) == source_revision and old.bounds == source_bounds
		return {"status": "ready" if same else "failed",
			"reason": "" if same else "visual_source_identity_conflict", "sourceId": source_id}
	if _sources.size() >= MAX_SOURCES:
		return {"status": "pending", "reason": "visual_source_capacity", "retryable": true}
	_sources[source_id] = {"kind": kind, "identity": source_identity, "revision": source_revision,
		"bounds": source_bounds, "viewRevision": _view_revision, "complete": false,
		"failed": false, "failureReason": "", "candidates": {}}
	return {"status": "ready", "sourceId": source_id, "viewRevision": _view_revision}


func describe_candidate(source_id: String, candidate_id: String, required_tier: String,
		metadata: Dictionary = {}) -> Dictionary:
	if not _sources.has(source_id):
		return {"status": "failed", "reason": "visual_candidate_source_missing"}
	var source: Dictionary = _sources[source_id]
	if bool(source.complete) or bool(source.failed):
		return {"status": "failed", "reason": "visual_manifest_already_terminal"}
	if candidate_id.strip_edges().is_empty() or not REPRESENTATION_TIERS.has(required_tier):
		return {"status": "failed", "reason": "invalid_visual_candidate"}
	if not metadata.has("positionXZ") or not (metadata.positionXZ is Vector2):
		return {"status": "failed", "reason": "visual_candidate_position_missing"}
	var candidate_position: Vector2 = metadata.positionXZ
	var candidate_cell := Vector2i(floori(candidate_position.x), floori(candidate_position.y))
	var source_bounds: Rect2i = source.bounds
	if not _bounds.has_point(candidate_cell) or not source_bounds.has_point(candidate_cell) \
			or candidate_position.distance_to(_view_center) > _view_radius:
		return {"status": "failed", "reason": "visual_candidate_outside_source_or_view"}
	var expected_tier := "near" if _near_bounds.has_point(Vector2i(floori(candidate_position.x), floori(candidate_position.y))) else "horizon"
	if required_tier != expected_tier:
		return {"status": "failed", "reason": "visual_candidate_tier_mismatch",
			"expectedTier": expected_tier, "actualTier": required_tier}
	if source.candidates.has(candidate_id):
		return {"status": "failed", "reason": "duplicate_visual_candidate_id"}
	if _candidate_count >= MAX_CANDIDATES:
		return {"status": "pending", "reason": "visual_candidate_capacity", "retryable": true}
	source.candidates[candidate_id] = {"requiredTier": required_tier,
		"candidateId": candidate_id, "metadata": metadata.duplicate(true),
		"receipt": {}, "failed": false, "failureReason": ""}
	_candidate_count += 1
	return {"status": "ready", "candidateId": candidate_id}


## A publisher calls this after its deterministic source scan has fully
## completed. Empty sources are therefore explicit, revision-bound receipts.
func finish_source(source_id: String, source_identity: String, source_revision: String,
		view_revision: int) -> Dictionary:
	if not _sources.has(source_id):
		return {"status": "failed", "reason": "visual_finish_unknown_source"}
	var source: Dictionary = _sources[source_id]
	if view_revision != _view_revision or int(source.viewRevision) != view_revision \
			or String(source.identity) != source_identity or String(source.revision) != source_revision:
		return {"status": "pending", "reason": "visual_source_revision_changed"}
	if bool(source.failed):
		return {"status": "failed", "reason": String(source.failureReason)}
	source.complete = true
	return {"status": "ready", "sourceId": source_id, "candidateCount": source.candidates.size()}


func fail_source(source_id: String, reason: String, diagnostic: Dictionary = {}) -> Dictionary:
	if not _sources.has(source_id):
		return {"status": "failed", "reason": "visual_fail_unknown_source"}
	var source: Dictionary = _sources[source_id]
	source.failed = true
	source.complete = true
	source.failureReason = reason.strip_edges() if not reason.strip_edges().is_empty() else "visual_source_failed"
	_record_failure(source_id, "", String(source.kind), String(source.failureReason), diagnostic)
	return {"status": "failed", "reason": String(source.failureReason)}


## Close the deterministic source list only after every producer has declared
## its relevant coverage. This makes an entirely empty manifest meaningful.
func seal_source_set(view_revision: int) -> Dictionary:
	if not _view_active:
		return {"status": "failed", "reason": "visual_view_not_started"}
	if view_revision != _view_revision:
		return {"status": "pending", "reason": "visual_view_revision_changed"}
	var missing_kinds: Array[String] = []
	for kind: String in CONTENT_KINDS:
		if not _source_kind_covers_view(kind):
			missing_kinds.append(kind)
			continue
		for source_value in _sources.values():
			var source: Dictionary = source_value
			if String(source.kind) == kind and not bool(source.complete):
				missing_kinds.append(kind)
				break
	if not missing_kinds.is_empty():
		return {"status": "pending", "reason": "visual_source_coverage_incomplete",
			"missingKinds": missing_kinds, "retryable": true}
	_source_set_sealed = true
	return {"status": "ready", "sourceCount": _sources.size(), "viewRevision": _view_revision}


## Receipt admission binds to the exact candidate and source revisions. The
## publisher must provide its live installed owner and representation node;
## scene-node counts and metadata-only markers are never sufficient.
func accept_receipt(source_id: String, candidate_id: String, representation_id: String,
		tier: String, source_identity: String, source_revision: String, view_revision: int,
		owner: Node, representation: Node3D) -> Dictionary:
	if not _sources.has(source_id):
		return {"status": "pending", "reason": "visual_receipt_source_missing"}
	var source: Dictionary = _sources[source_id]
	if not source.candidates.has(candidate_id):
		return {"status": "failed", "reason": "visual_receipt_candidate_missing"}
	var candidate: Dictionary = source.candidates[candidate_id]
	if view_revision != _view_revision or int(source.viewRevision) != view_revision \
			or String(source.identity) != source_identity or String(source.revision) != source_revision:
		return {"status": "pending", "reason": "visual_receipt_revision_stale"}
	if String(representation_id).strip_edges().is_empty() or not REPRESENTATION_TIERS.has(tier):
		return {"status": "failed", "reason": "invalid_visual_representation_receipt"}
	if not is_instance_valid(owner) or not is_instance_valid(representation) \
			or not owner.is_inside_tree() or not representation.is_inside_tree() \
			or owner.is_queued_for_deletion() or representation.is_queued_for_deletion() \
			or not representation.visible or not _is_descendant_or_self(owner, representation) \
			or not _has_visible_renderable(representation):
		return {"status": "pending", "reason": "visual_representation_not_installed"}
	if _tier_rank(tier) < _tier_rank(String(candidate.requiredTier)):
		return {"status": "pending", "reason": "visual_representation_tier_insufficient"}
	candidate.receipt = {"representationId": representation_id, "tier": tier,
		"sourceIdentity": source_identity, "sourceRevision": source_revision,
		"worldRevision": _world_revision, "viewRevision": view_revision,
		"ownerInstanceId": owner.get_instance_id(), "owner": weakref(owner),
		"representationInstanceId": representation.get_instance_id(),
		"representation": weakref(representation)}
	candidate.receipt.erase("publisher")
	candidate.failed = false
	candidate.failureReason = ""
	return {"status": "ready", "candidateId": candidate_id, "tier": tier,
		"viewRevision": view_revision}


## Native render owners such as VoxelTerrain do not expose a MeshInstance3D
## child. They may receipt through their own source-of-truth validator, which
## is called both here and on every readiness query to reject stale installs.
func accept_publisher_receipt(source_id: String, candidate_id: String, representation_id: String,
		tier: String, source_identity: String, source_revision: String, view_revision: int,
		publisher: Object, validator_method: StringName) -> Dictionary:
	if not _sources.has(source_id) or not _sources[source_id].candidates.has(candidate_id):
		return {"status": "failed", "reason": "visual_receipt_candidate_missing"}
	var source: Dictionary = _sources[source_id]
	var candidate: Dictionary = source.candidates[candidate_id]
	if view_revision != _view_revision or int(source.viewRevision) != view_revision \
			or String(source.identity) != source_identity or String(source.revision) != source_revision:
		return {"status": "pending", "reason": "visual_receipt_revision_stale"}
	if not is_instance_valid(publisher) or not publisher.has_method(validator_method) \
			or not _valid_publisher_tier(candidate, tier) \
			or not _publisher_installation_valid(publisher, validator_method, source, candidate,
				representation_id, tier, view_revision):
		return {"status": "pending", "reason": "visual_publisher_receipt_not_current"}
	candidate.receipt = {"representationId": representation_id, "tier": tier,
		"sourceIdentity": source_identity, "sourceRevision": source_revision,
		"worldRevision": _world_revision, "viewRevision": view_revision,
		"publisherInstanceId": publisher.get_instance_id(), "publisher": weakref(publisher),
		"validatorMethod": validator_method}
	candidate.failed = false
	candidate.failureReason = ""
	return {"status": "ready", "candidateId": candidate_id, "tier": tier,
		"viewRevision": view_revision, "receiptAuthority": "publisher_validator"}


func fail_candidate(source_id: String, candidate_id: String, reason: String,
		diagnostic: Dictionary = {}) -> Dictionary:
	if not _sources.has(source_id) or not _sources[source_id].candidates.has(candidate_id):
		return {"status": "failed", "reason": "visual_fail_unknown_candidate"}
	var source: Dictionary = _sources[source_id]
	var candidate: Dictionary = source.candidates[candidate_id]
	candidate.failed = true
	candidate.failureReason = reason.strip_edges() if not reason.strip_edges().is_empty() else "visual_candidate_failed"
	_record_failure(source_id, candidate_id, String(source.kind), String(candidate.failureReason), diagnostic)
	return {"status": "failed", "reason": String(candidate.failureReason)}


func record_queue_diagnostics(queue_depth: int, coverage_lag: float) -> void:
	_queue_diagnostics["depth"] = maxi(0, queue_depth)
	_coverage_lag = maxf(0.0, coverage_lag) if is_finite(coverage_lag) else 0.0


func region_readiness(request_id: int, seed: String, world_revision: String,
		view_revision: int, bounds: Rect2i) -> Dictionary:
	var result := {"status": "pending", "reason": "visual_manifest_incomplete", "requestId": _request_id,
		"bounds": _bounds, "worldRevision": _world_revision, "viewRevision": _view_revision,
		"candidateCount": 0, "representedCount": 0, "pendingCount": 0, "failedCount": 0,
		"byKind": {}, "tiers": {"near": {"candidate": 0, "represented": 0},
			"horizon": {"candidate": 0, "represented": 0}},
		"incompleteSources": [], "failures": _failure_rows.duplicate(true),
		"queue": _queue_diagnostics.duplicate(true), "coverageLag": _coverage_lag}
	for kind: String in CONTENT_KINDS:
		result.byKind[kind] = {"candidate": 0, "represented": 0, "pending": 0, "failed": 0,
			"incompleteDiscovery": 0}
	if not _view_active:
		result.reason = "visual_view_not_started"
		return result
	if request_id != _request_id or seed != _seed or world_revision != _world_revision \
			or view_revision != _view_revision or bounds != _bounds:
		result.reason = "visual_request_or_revision_changed"
		return result
	if not _source_set_sealed:
		result.reason = "visual_source_set_incomplete"
		return result
	var has_failure := false
	for source_id_value in _sources:
		var source: Dictionary = _sources[source_id_value]
		var kind := String(source.kind)
		var kind_counts: Dictionary = result.byKind[kind]
		if not bool(source.complete):
			kind_counts.incompleteDiscovery = int(kind_counts.incompleteDiscovery) + 1
			result.incompleteSources.append(String(source_id_value))
		if bool(source.failed): has_failure = true
		for candidate_id_value in source.candidates:
			var candidate: Dictionary = source.candidates[candidate_id_value]
			kind_counts.candidate = int(kind_counts.candidate) + 1
			result.candidateCount = int(result.candidateCount) + 1
			var required_tier := String(candidate.requiredTier)
			var tier_counts: Dictionary = result.tiers[required_tier]
			tier_counts.candidate = int(tier_counts.candidate) + 1
			if bool(candidate.failed):
				kind_counts.failed = int(kind_counts.failed) + 1
				result.failedCount = int(result.failedCount) + 1
				has_failure = true
				continue
			if _candidate_receipt_current(source, candidate, view_revision):
				kind_counts.represented = int(kind_counts.represented) + 1
				result.representedCount = int(result.representedCount) + 1
				tier_counts.represented = int(tier_counts.represented) + 1
			else:
				kind_counts.pending = int(kind_counts.pending) + 1
				result.pendingCount = int(result.pendingCount) + 1
		if not bool(source.complete):
			kind_counts.pending = int(kind_counts.pending) + 1
			result.pendingCount = int(result.pendingCount) + 1
	if has_failure:
		result.status = "failed"
		result.reason = "visual_candidate_failed"
	elif not result.incompleteSources.is_empty() or int(result.pendingCount) > 0:
		result.status = "pending"
		result.reason = "visual_representation_pending"
	else:
		result.status = "ready"
		result.reason = ""
	return result


func _candidate_receipt_current(source: Dictionary, candidate: Dictionary, view_revision: int) -> bool:
	var receipt: Dictionary = candidate.get("receipt", {})
	if receipt.is_empty() or int(receipt.get("viewRevision", -1)) != view_revision \
			or String(receipt.get("worldRevision", "")) != _world_revision \
			or String(receipt.get("sourceIdentity", "")) != String(source.identity) \
			or String(receipt.get("sourceRevision", "")) != String(source.revision) \
			or _tier_rank(String(receipt.get("tier", ""))) < _tier_rank(String(candidate.requiredTier)):
		return false
	if receipt.has("publisher"):
		var publisher_ref: WeakRef = receipt.get("publisher") as WeakRef
		var publisher: Object = publisher_ref.get_ref() if publisher_ref != null else null
		return is_instance_valid(publisher) \
			and publisher.get_instance_id() == int(receipt.get("publisherInstanceId", 0)) \
			and _publisher_installation_valid(publisher, StringName(receipt.validatorMethod), source,
				candidate, String(receipt.representationId), String(receipt.tier), view_revision)
	var owner_ref: WeakRef = receipt.get("owner") as WeakRef
	var representation_ref: WeakRef = receipt.get("representation") as WeakRef
	var owner: Node = owner_ref.get_ref() as Node if owner_ref != null else null
	var representation: Node3D = representation_ref.get_ref() as Node3D if representation_ref != null else null
	return is_instance_valid(owner) and is_instance_valid(representation) \
		and owner.get_instance_id() == int(receipt.get("ownerInstanceId", 0)) \
		and representation.get_instance_id() == int(receipt.get("representationInstanceId", 0)) \
		and owner.is_inside_tree() and representation.is_inside_tree() \
		and not owner.is_queued_for_deletion() and not representation.is_queued_for_deletion() \
		and representation.visible and _is_descendant_or_self(owner, representation) \
		and _has_visible_renderable(representation)


func _valid_publisher_tier(candidate: Dictionary, tier: String) -> bool:
	return REPRESENTATION_TIERS.has(tier) and _tier_rank(tier) >= _tier_rank(String(candidate.requiredTier))


func _publisher_installation_valid(publisher: Object, validator_method: StringName,
		source: Dictionary, candidate: Dictionary, representation_id: String, tier: String,
		view_revision: int) -> bool:
	if not is_instance_valid(publisher) or not publisher.has_method(validator_method) \
			or not _valid_publisher_tier(candidate, tier):
		return false
	var proof: Variant = publisher.call(validator_method, String(source.identity), String(source.revision),
		_world_revision, view_revision, String(candidate.candidateId),
		representation_id, tier)
	return proof is bool and proof


func _record_failure(source_id: String, candidate_id: String, kind: String, reason: String,
		diagnostic: Dictionary) -> void:
	if _failure_rows.size() >= MAX_FAILURES: return
	_failure_rows.append({"sourceId": source_id, "candidateId": candidate_id,
		"kind": kind, "reason": reason, "diagnostic": diagnostic.duplicate(true)})


func _source_kind_covers_view(kind: String) -> bool:
	# Prove coverage only for integer cells intersecting the configured view
	# disk. The rect is a broad-phase envelope; its unseen corners are excluded.
	for z in range(_bounds.position.y, _bounds.end.y):
		var first_required := _bounds.position.x
		var last_required := _bounds.end.x
		var dz := maxf(0.0, absf(float(z) + 0.5 - _view_center.y) - 0.5)
		if dz > _view_radius: continue
		var half_width := sqrt(maxf(0.0, _view_radius * _view_radius - dz * dz))
		first_required = maxi(first_required, int(floor(_view_center.x - half_width)))
		last_required = mini(last_required, int(ceil(_view_center.x + half_width)))
		if last_required <= first_required: continue
		var spans: Array[Vector2i] = []
		for source_value in _sources.values():
			var source: Dictionary = source_value
			if String(source.kind) != kind: continue
			var footprint: Rect2i = source.bounds
			if z < footprint.position.y or z >= footprint.end.y: continue
			var first_x := maxi(first_required, footprint.position.x)
			var last_x := mini(last_required, footprint.end.x)
			if last_x > first_x: spans.append(Vector2i(first_x, last_x))
		spans.sort_custom(func(a: Vector2i, b: Vector2i):
			return a.x < b.x if a.x != b.x else a.y > b.y)
		var covered_to := first_required
		for span: Vector2i in spans:
			if span.x > covered_to: return false
			covered_to = maxi(covered_to, span.y)
			if covered_to >= last_required: break
		if covered_to < last_required: return false
	return true


static func _is_descendant_or_self(owner: Node, node: Node) -> bool:
	var current := node
	while current != null:
		if current == owner: return true
		current = current.get_parent()
	return false


static func _has_visible_renderable(root_node: Node) -> bool:
	if root_node is GeometryInstance3D:
		var geometry := root_node as GeometryInstance3D
		if geometry.visible and geometry.is_visible_in_tree():
			if geometry is MeshInstance3D and (geometry as MeshInstance3D).mesh != null:
				return true
			if geometry is MultiMeshInstance3D and (geometry as MultiMeshInstance3D).multimesh != null:
				return true
	for child in root_node.get_children():
		if child is Node and _has_visible_renderable(child): return true
	return false


static func _tier_rank(tier: String) -> int:
	return REPRESENTATION_TIERS.find(tier) if REPRESENTATION_TIERS.has(tier) else -1


static func _valid_bounds(bounds: Rect2i) -> bool:
	return bounds.size.x > 0 and bounds.size.y > 0 \
		and bounds.position.x <= 2147483647 - bounds.size.x \
		and bounds.position.y <= 2147483647 - bounds.size.y
