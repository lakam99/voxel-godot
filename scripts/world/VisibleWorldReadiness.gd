extends RefCounted
class_name VisibleWorldReadiness

## Request-scoped accounting for visual representations. This book owns no
## geometry: publishers describe deterministic candidates and acknowledge an
## installed representation only after their own publication has committed.
const CONTENT_KINDS := ["terrain", "structures", "trees_foliage", "props", "wildlife"]
const REPRESENTATION_TIERS := ["horizon", "near"]
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
var _terrain_source_footprints: Dictionary = {}
var _terrain_source_set_declared := false
var _candidate_count := 0
var _failure_rows: Array[Dictionary] = []
var _queue_diagnostics: Dictionary = {}
var _coverage_lag := 0.0
var _overlap_transfers: Dictionary = {}
var _coverage_geometry_revision := 0
var _cached_coverage_revision := -1
var _cached_coverage_bounds := Rect2i()
var _cached_coverage_gaps: Array[Dictionary] = []


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
		_terrain_source_footprints.clear()
		_terrain_source_set_declared = false
		_candidate_count = 0
		_failure_rows.clear()
		_queue_diagnostics.clear()
		_coverage_lag = 0.0
		_overlap_transfers.clear()
		_invalidate_coverage_geometry()
	return {"status": "ready", "viewRevision": _view_revision, "requestId": _request_id,
		"worldRevision": _world_revision}


## Re-admits one complete interior source from an older view in bounded slices.
## The caller must obtain current_identity/current_revision from the producer;
## this book cannot infer whether an explicit empty source changed upstream.
## A boundary source is rescanned by its producer because its old view may have
## excluded candidates now inside the new circle.
func transfer_complete_overlap_source(previous: VisibleWorldReadiness,
		source_id: String, current_identity: String, current_revision: String,
		view_revision: int, candidate_budget := 64) -> Dictionary:
	if previous == null or previous == self or not previous._view_active or not _view_active \
			or view_revision != _view_revision or _request_id != previous._request_id \
			or _seed != previous._seed or _world_revision != previous._world_revision:
		return {"status": "pending", "reason": "visual_overlap_request_revision_changed"}
	if source_id.is_empty() or current_identity.is_empty() or current_revision.is_empty():
		return {"status": "failed", "reason": "invalid_visual_overlap_source"}
	if not previous._sources.has(source_id):
		return {"status": "pending", "reason": "visual_overlap_source_missing"}
	var old_source: Dictionary = previous._sources[source_id]
	var footprint: Rect2i = old_source.bounds
	if not bool(old_source.complete) or bool(old_source.failed) \
			or String(old_source.identity) != current_identity \
			or String(old_source.revision) != current_revision:
		_abort_overlap_transfer(source_id)
		return {"status": "pending", "reason": "visual_overlap_source_revision_changed"}
	if not _footprint_inside_view(footprint) or not previous._footprint_inside_view(footprint):
		_abort_overlap_transfer(source_id)
		return {"status": "pending", "reason": "visual_overlap_boundary_requires_scan"}
	if String(old_source.kind) == "terrain" and (not _terrain_source_set_declared \
			or not previous._terrain_source_set_declared \
			or _terrain_source_footprints.get(source_id) != footprint \
			or previous._terrain_source_footprints.get(source_id) != footprint):
		return {"status": "pending", "reason": "visual_overlap_terrain_source_not_admitted"}
	var transfer: Dictionary = _overlap_transfers.get(source_id, {})
	if transfer.is_empty():
		if _sources.has(source_id):
			return {"status": "pending", "reason": "visual_overlap_source_already_started"}
		var declared := expect_source(source_id, String(old_source.kind), current_identity,
			current_revision, footprint, view_revision)
		if declared.get("status") != "ready": return declared
		transfer = {"previous": weakref(previous), "sourceIdentity": current_identity,
			"sourceRevision": current_revision, "viewRevision": view_revision,
			"candidateIds": old_source.candidates.keys(), "cursor": 0}
		_overlap_transfers[source_id] = transfer
	else:
		var old_ref: WeakRef = transfer.previous
		if old_ref.get_ref() != previous or String(transfer.sourceIdentity) != current_identity \
				or String(transfer.sourceRevision) != current_revision \
				or int(transfer.viewRevision) != view_revision \
				or not _sources.has(source_id):
			_abort_overlap_transfer(source_id)
			return {"status": "pending", "reason": "visual_overlap_transfer_changed"}
	var candidate_ids: Array = transfer.candidateIds
	var processed := 0
	while int(transfer.cursor) < candidate_ids.size() and processed < maxi(1, candidate_budget):
		var candidate_id := String(candidate_ids[int(transfer.cursor)])
		if not old_source.candidates.has(candidate_id):
			_abort_overlap_transfer(source_id)
			return {"status": "pending", "reason": "visual_overlap_candidate_changed"}
		var old_candidate: Dictionary = old_source.candidates[candidate_id]
		var metadata: Dictionary = old_candidate.get("metadata", {})
		var position: Vector2 = metadata.get("positionXZ", Vector2(INF, INF))
		if bool(old_candidate.failed) or not position.is_finite() or not candidate_in_view(position) \
				or not previous._candidate_receipt_current(old_source, old_candidate,
					previous._view_revision):
			_abort_overlap_transfer(source_id)
			return {"status": "pending", "reason": "visual_overlap_receipt_not_current"}
		var tier := "near" if _near_bounds.has_point(Vector2i(floori(position.x),
			floori(position.y))) else "horizon"
		var receipt: Dictionary = old_candidate.get("receipt", {})
		if _tier_rank(String(receipt.get("tier", ""))) < _tier_rank(tier):
			_abort_overlap_transfer(source_id)
			return {"status": "pending", "reason": "visual_overlap_tier_promotion_required"}
		var described := describe_candidate(source_id, candidate_id, tier, metadata)
		if described.get("status") != "ready":
			_abort_overlap_transfer(source_id)
			return {"status": "pending", "reason": "visual_overlap_candidate_rejected"}
		var accepted: Dictionary
		if receipt.has("publisher"):
			var publisher_ref: WeakRef = receipt.publisher
			var publisher: Object = publisher_ref.get_ref() if publisher_ref != null else null
			accepted = accept_publisher_receipt(source_id, candidate_id,
				String(receipt.representationId), String(receipt.tier), current_identity,
				current_revision, view_revision, publisher, StringName(receipt.validatorMethod))
		else:
			var owner_ref: WeakRef = receipt.get("owner") as WeakRef
			var representation_ref: WeakRef = receipt.get("representation") as WeakRef
			var owner: Node = owner_ref.get_ref() as Node if owner_ref != null else null
			var representation: Node3D = representation_ref.get_ref() as Node3D \
				if representation_ref != null else null
			accepted = accept_receipt(source_id, candidate_id,
				String(receipt.representationId), String(receipt.tier), current_identity,
				current_revision, view_revision, owner, representation)
		if accepted.get("status") != "ready" or not _candidate_receipt_current(
				_sources[source_id], _sources[source_id].candidates[candidate_id], view_revision):
			_abort_overlap_transfer(source_id)
			return {"status": "pending", "reason": "visual_overlap_receipt_not_current"}
		transfer.cursor = int(transfer.cursor) + 1
		processed += 1
	if int(transfer.cursor) < candidate_ids.size():
		return {"status": "pending", "reason": "visual_overlap_transfer_budget",
			"retryable": true, "copiedCandidates": int(transfer.cursor),
			"remainingCandidates": candidate_ids.size() - int(transfer.cursor)}
	var finished := finish_source(source_id, current_identity, current_revision, view_revision)
	if finished.get("status") != "ready":
		_abort_overlap_transfer(source_id)
		return finished
	_overlap_transfers.erase(source_id)
	return {"status": "ready", "sourceId": source_id,
		"copiedCandidates": candidate_ids.size(), "viewRevision": view_revision}


func _abort_overlap_transfer(source_id: String) -> void:
	if not _overlap_transfers.has(source_id): return
	_overlap_transfers.erase(source_id)
	if _sources.has(source_id):
		_candidate_count = maxi(0, _candidate_count - _sources[source_id].candidates.size())
		_sources.erase(source_id)
		_invalidate_coverage_geometry()


func _footprint_inside_view(footprint: Rect2i) -> bool:
	if not _bounds.encloses(footprint) or not _valid_bounds(footprint): return false
	# Check the whole half-open rectangle, not only cell centers: production
	# candidates may occupy any position inside a boundary cell.
	var xs := [float(footprint.position.x), float(footprint.end.x)]
	var ys := [float(footprint.position.y), float(footprint.end.y)]
	for x: float in xs:
		for y: float in ys:
			if Vector2(x, y).distance_to(_view_center) > _view_radius: return false
	return true


## The native publisher owns the 3D block-center selection. Its admitted mesh
## blocks form the terrain coverage obligation for this view. Each block still
## needs a completed source and a current installed-mesh receipt.
func declare_terrain_mesh_source_set(footprints: Dictionary, view_revision: int) -> Dictionary:
	if not _view_active or view_revision != _view_revision:
		return {"status": "pending", "reason": "visual_view_revision_changed"}
	if footprints.is_empty() or footprints.size() > MAX_SOURCES:
		return {"status": "failed", "reason": "invalid_terrain_mesh_source_set"}
	var admitted: Dictionary = {}
	for source_id_value in footprints:
		if not source_id_value is String or String(source_id_value).strip_edges().is_empty() \
				or not footprints[source_id_value] is Rect2i:
			return {"status": "failed", "reason": "invalid_terrain_mesh_source_set"}
		var footprint: Rect2i = footprints[source_id_value]
		if not _valid_bounds(footprint) or not footprint.intersects(_bounds):
			return {"status": "failed", "reason": "invalid_terrain_mesh_source_set"}
		admitted[source_id_value] = footprint
	if _terrain_source_set_declared:
		if admitted == _terrain_source_footprints:
			return {"status": "ready", "sourceCount": admitted.size()}
		return {"status": "failed", "reason": "terrain_mesh_source_set_conflict"}
	if _source_set_sealed:
		return {"status": "failed", "reason": "visual_source_set_closed"}
	for source_id_value in _sources:
		var source: Dictionary = _sources[source_id_value]
		if String(source.kind) == "terrain" and (not admitted.has(source_id_value) \
				or admitted[source_id_value] != source.bounds):
			return {"status": "failed", "reason": "terrain_mesh_source_set_conflict"}
	_terrain_source_footprints = admitted
	_terrain_source_set_declared = true
	_invalidate_coverage_geometry()
	return {"status": "ready", "sourceCount": admitted.size()}


## Each declared source owns a complete half-open XZ footprint. The source may
## report an empty manifest only after finish_source() confirms enumeration.
func expect_source(source_id: String, kind: String, source_identity: String,
		source_revision: String, source_bounds: Rect2i, view_revision: int) -> Dictionary:
	if not _view_active:
		return {"status": "failed", "reason": "visual_source_set_closed"}
	if view_revision != _view_revision:
		return {"status": "pending", "reason": "visual_view_revision_changed"}
	if source_id.strip_edges().is_empty() or source_identity.strip_edges().is_empty() \
			or source_revision.strip_edges().is_empty() or not CONTENT_KINDS.has(kind) \
			or not _valid_bounds(source_bounds) or not source_bounds.intersects(_bounds):
		return {"status": "failed", "reason": "invalid_visual_source_manifest"}
	if kind == "terrain" and (not _terrain_source_set_declared \
			or not _terrain_source_footprints.has(source_id) \
			or _terrain_source_footprints[source_id] != source_bounds):
		return {"status": "failed", "reason": "terrain_mesh_source_not_admitted"}
	if _sources.has(source_id):
		var old: Dictionary = _sources[source_id]
		var same: bool = String(old.kind) == kind and String(old.identity) == source_identity \
			and String(old.revision) == source_revision and old.bounds == source_bounds
		if same:
			return {"status": "ready", "sourceId": source_id, "viewRevision": _view_revision}
		if String(old.kind) != kind or String(old.identity) != source_identity or old.bounds != source_bounds:
			return {"status": "failed", "reason": "visual_source_identity_conflict", "sourceId": source_id}
		_candidate_count = maxi(0, _candidate_count - old.candidates.size())
		_sources.erase(source_id)
		_source_set_sealed = false
	if _source_set_sealed:
		return {"status": "failed", "reason": "visual_source_set_closed"}
	if _sources.size() >= MAX_SOURCES:
		return {"status": "pending", "reason": "visual_source_capacity", "retryable": true}
	_sources[source_id] = {"kind": kind, "identity": source_identity, "revision": source_revision,
		"bounds": source_bounds, "viewRevision": _view_revision, "complete": false,
		"failed": false, "failureReason": "", "candidates": {}}
	_invalidate_coverage_geometry()
	return {"status": "ready", "sourceId": source_id, "viewRevision": _view_revision}


func has_candidate(source_id: String, candidate_id: String) -> bool:
	return _sources.has(source_id) and _sources[source_id].candidates.has(candidate_id)


## Used by a producer before carrying a complete source into another view.
## An empty source still needs its current producer revision and installation
## state checked by that producer before it can be reused.
func complete_source_candidate_count(source_id: String, source_identity: String,
		source_revision: String) -> int:
	if not _sources.has(source_id): return -1
	var source: Dictionary = _sources[source_id]
	if not bool(source.complete) or bool(source.failed) \
			or String(source.identity) != source_identity \
			or String(source.revision) != source_revision:
		return -1
	return source.candidates.size()


func complete_source_candidate_position(source_id: String, candidate_id: String,
		source_identity: String, source_revision: String) -> Vector2:
	if complete_source_candidate_count(source_id, source_identity, source_revision) < 0:
		return Vector2(INF, INF)
	var source: Dictionary = _sources[source_id]
	if not source.candidates.has(candidate_id): return Vector2(INF, INF)
	var metadata: Dictionary = source.candidates[candidate_id].get("metadata", {})
	var position: Variant = metadata.get("positionXZ")
	return position if position is Vector2 else Vector2(INF, INF)


func candidate_in_view(position_xz: Vector2) -> bool:
	return _view_active and position_xz.is_finite() \
		and position_xz.distance_to(_view_center) <= _view_radius


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
		"valueOnlyDetailMetadata": _is_value_only_detail_metadata(metadata),
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
	if not bool(source.complete):
		source.complete = true
		_invalidate_coverage_geometry()
	return {"status": "ready", "sourceId": source_id, "candidateCount": source.candidates.size()}


func fail_source(source_id: String, reason: String, diagnostic: Dictionary = {}) -> Dictionary:
	if not _sources.has(source_id):
		return {"status": "failed", "reason": "visual_fail_unknown_source"}
	var source: Dictionary = _sources[source_id]
	source.failed = true
	source.complete = true
	source.failureReason = reason.strip_edges() if not reason.strip_edges().is_empty() else "visual_source_failed"
	_invalidate_coverage_geometry()
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
	_invalidate_coverage_geometry()
	_record_failure(source_id, candidate_id, String(source.kind), String(candidate.failureReason), diagnostic)
	return {"status": "failed", "reason": String(candidate.failureReason)}


func record_queue_diagnostics(queue_depth: int, coverage_lag: float) -> void:
	_queue_diagnostics["depth"] = maxi(0, queue_depth)
	_coverage_lag = maxf(0.0, coverage_lag) if is_finite(coverage_lag) else 0.0


func region_readiness(request_id: int, seed: String, world_revision: String,
		view_revision: int, bounds: Rect2i) -> Dictionary:
	var result := {"status": "pending", "reason": "visual_manifest_incomplete", "requestId": _request_id,
		"bounds": bounds, "viewBounds": _bounds, "worldRevision": _world_revision, "viewRevision": _view_revision,
		"coverageGeometryUsec": 0, "receiptValidationUsec": 0,
		"receiptValidationByKindUsec": {},
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
			or view_revision != _view_revision or not _bounds.encloses(bounds) or not _valid_bounds(bounds):
		result.reason = "visual_request_or_revision_changed"
		return result
	var coverage_started_usec := Time.get_ticks_usec()
	var coverage_gaps := _source_coverage_gaps(bounds)
	result.coverageGeometryUsec = maxi(0, Time.get_ticks_usec() - coverage_started_usec)
	if not coverage_gaps.is_empty():
		result.reason = "visual_source_coverage_incomplete"
		result["coverageGaps"] = coverage_gaps
		return result
	var has_failure := false
	var receipt_started_usec := Time.get_ticks_usec()
	for source_id_value in _sources:
		var source: Dictionary = _sources[source_id_value]
		var source_bounds: Rect2i = source.bounds
		if not source_bounds.intersects(bounds): continue
		var source_started_usec := Time.get_ticks_usec()
		var kind := String(source.kind)
		var kind_counts: Dictionary = result.byKind[kind]
		if not bool(source.complete):
			kind_counts.incompleteDiscovery = int(kind_counts.incompleteDiscovery) + 1
			result.incompleteSources.append(String(source_id_value))
		if bool(source.failed): has_failure = true
		for candidate_id_value in source.candidates:
			var candidate: Dictionary = source.candidates[candidate_id_value]
			var candidate_position: Vector2 = candidate.get("metadata", {}).get("positionXZ", Vector2(INF, INF))
			if kind != "terrain" and not bounds.has_point(Vector2i(floori(candidate_position.x), floori(candidate_position.y))):
				continue
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
		var by_kind_timing: Dictionary = result.receiptValidationByKindUsec
		by_kind_timing[kind] = int(by_kind_timing.get(kind, 0)) \
			+ maxi(0, Time.get_ticks_usec() - source_started_usec)
	result.receiptValidationUsec = maxi(0, Time.get_ticks_usec() - receipt_started_usec)
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


func pending_candidate_diagnostics(request_id: int, seed: String,
		world_revision: String, view_revision: int, bounds: Rect2i,
		limit := 8) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if not _view_active or request_id != _request_id or seed != _seed \
			or world_revision != _world_revision or view_revision != _view_revision \
			or not _bounds.encloses(bounds):
		return rows
	for source_id_value in _sources:
		var source: Dictionary = _sources[source_id_value]
		if not (source.bounds as Rect2i).intersects(bounds): continue
		for candidate_id_value in source.candidates:
			var candidate: Dictionary = source.candidates[candidate_id_value]
			var position: Vector2 = candidate.get("metadata", {}).get("positionXZ", Vector2(INF, INF))
			if String(source.kind) != "terrain" \
					and not bounds.has_point(Vector2i(floori(position.x), floori(position.y))):
				continue
			if _candidate_receipt_current(source, candidate, view_revision): continue
			var receipt: Dictionary = candidate.get("receipt", {})
			rows.append({"sourceId": String(source_id_value),
				"candidateId": String(candidate_id_value), "kind": String(source.kind),
				"requiredTier": String(candidate.requiredTier),
				"receiptTier": String(receipt.get("tier", "")),
				"representationId": String(receipt.get("representationId", "")),
				"receiptMissing": receipt.is_empty()})
			if rows.size() >= maxi(1, limit): return rows
	return rows


func _source_coverage_gaps(bounds: Rect2i) -> Array[Dictionary]:
	# Source geometry and completion change only through the ledger mutation
	# methods. Keep one exact-bounds result; installed candidate receipts are
	# intentionally validated live by region_readiness on every query.
	if _cached_coverage_revision == _coverage_geometry_revision \
			and _cached_coverage_bounds == bounds:
		return _cached_coverage_gaps.duplicate(true)
	_cached_coverage_gaps = _compute_source_coverage_gaps(bounds)
	_cached_coverage_bounds = bounds
	_cached_coverage_revision = _coverage_geometry_revision
	return _cached_coverage_gaps.duplicate(true)


func _invalidate_coverage_geometry() -> void:
	_coverage_geometry_revision += 1
	_cached_coverage_revision = -1
	_cached_coverage_gaps.clear()


func _compute_source_coverage_gaps(bounds: Rect2i) -> Array[Dictionary]:
	# Exact row-wise union coverage avoids mistaking a pair of separated source
	# rectangles for a complete visual region. The bounded ledger caps demand.
	var gaps: Array[Dictionary] = []
	if bounds.get_area() > MAX_CANDIDATES:
		return [{"kind":"all", "reason":"visual_query_capacity", "area":bounds.get_area()}]
	for kind: String in CONTENT_KINDS:
		if kind == "terrain":
			if not _terrain_source_set_declared:
				gaps.append({"kind":kind, "reason":"terrain_mesh_source_set_missing"})
				continue
			for source_id_value in _terrain_source_footprints:
				var footprint: Rect2i = _terrain_source_footprints[source_id_value]
				if not footprint.intersects(bounds): continue
				var terrain_source: Dictionary = _sources.get(source_id_value, {})
				if terrain_source.is_empty() or String(terrain_source.kind) != kind \
						or terrain_source.bounds != footprint or not bool(terrain_source.complete) \
						or bool(terrain_source.failed):
					gaps.append({"kind":kind, "sourceId":String(source_id_value),
						"reason":"terrain_mesh_source_incomplete"})
					break
			continue
		var sources: Array[Dictionary] = []
		for source_value in _sources.values():
			var source: Dictionary = source_value
			if String(source.kind) == kind and source.bounds.intersects(bounds) \
					and bool(source.complete) and not bool(source.failed):
				sources.append(source)
		var first_gap := Vector2i(-1, -1)
		for z in range(bounds.position.y, bounds.end.y):
			var vertical_delta := (float(z) + 0.5) - _view_center.y
			if absf(vertical_delta) > _view_radius: continue
			var horizontal_reach := sqrt(maxf(0.0,
				_view_radius * _view_radius - vertical_delta * vertical_delta))
			var row_start := maxi(bounds.position.x, ceili(_view_center.x - horizontal_reach - 0.5))
			var row_end := mini(bounds.end.x, floori(_view_center.x + horizontal_reach - 0.5) + 1)
			if row_end <= row_start: continue
			var intervals: Array[Vector2i] = []
			for source: Dictionary in sources:
				var source_bounds: Rect2i = source.bounds
				if z >= source_bounds.position.y and z < source_bounds.end.y:
					intervals.append(Vector2i(maxi(row_start, source_bounds.position.x),
						mini(row_end, source_bounds.end.x)))
			intervals.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x)
			var covered_x := row_start
			for interval: Vector2i in intervals:
				if interval.x > covered_x: break
				covered_x = maxi(covered_x, interval.y)
				if covered_x >= row_end: break
			if covered_x < row_end:
				first_gap = Vector2i(covered_x, z)
				break
		if first_gap != Vector2i(-1, -1):
			gaps.append({"kind":kind, "firstUncoveredCell":first_gap,
				"completeSourcesIntersecting":sources.size()})
	return gaps


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
	if String(source.kind) == "trees_foliage" and is_instance_valid(owner) \
			and not _tree_lod_satisfies_tier(String(owner.get_meta("tree_render_lod_tier", "")),
				String(candidate.requiredTier)):
		return false
	return is_instance_valid(owner) and is_instance_valid(representation) \
		and owner.get_instance_id() == int(receipt.get("ownerInstanceId", 0)) \
		and representation.get_instance_id() == int(receipt.get("representationInstanceId", 0)) \
		and owner.is_inside_tree() and representation.is_inside_tree() \
		and not owner.is_queued_for_deletion() and not representation.is_queued_for_deletion() \
		and representation.visible and _is_descendant_or_self(owner, representation) \
		and _has_visible_renderable(representation)


func _valid_publisher_tier(candidate: Dictionary, tier: String) -> bool:
	return REPRESENTATION_TIERS.has(tier) and _tier_rank(tier) >= _tier_rank(String(candidate.requiredTier))


static func _tree_lod_satisfies_tier(lod_tier: String, required_tier: String) -> bool:
	if required_tier == "near": return lod_tier == "near"
	return lod_tier in ["near", "mid", "far", "impostor"]


func _publisher_installation_valid(publisher: Object, validator_method: StringName,
		source: Dictionary, candidate: Dictionary, representation_id: String, tier: String,
		view_revision: int) -> bool:
	if not is_instance_valid(publisher) or not publisher.has_method(validator_method) \
			or not _valid_publisher_tier(candidate, tier):
		return false
	var proof: Variant = publisher.call(validator_method, String(source.identity), String(source.revision),
		_world_revision, view_revision, String(candidate.candidateId),
		_publisher_metadata_copy(candidate.get("metadata", {}),
			bool(candidate.get("valueOnlyDetailMetadata", false))),
		representation_id, tier)
	return proof is bool and proof


static func _is_value_only_detail_metadata(metadata: Dictionary) -> bool:
	if not metadata.has("detailType") or not (metadata.get("detailType") is String) \
			or String(metadata.detailType).is_empty():
		return false
	for key in metadata:
		if not (key is String or key is StringName) \
				or typeof(metadata[key]) not in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT,
				TYPE_STRING, TYPE_STRING_NAME, TYPE_VECTOR2, TYPE_VECTOR2I,
				TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_TRANSFORM3D, TYPE_COLOR]:
			return false
	return true


static func _publisher_metadata_copy(metadata: Dictionary, value_only_detail: bool) -> Dictionary:
	# The schema is checked once on admission and the owned metadata is deep
	# copied there. Only immutable Variant values can take this shallow path.
	return metadata.duplicate() if value_only_detail else metadata.duplicate(true)


func _record_failure(source_id: String, candidate_id: String, kind: String, reason: String,
		diagnostic: Dictionary) -> void:
	if _failure_rows.size() >= MAX_FAILURES: return
	_failure_rows.append({"sourceId": source_id, "candidateId": candidate_id,
		"kind": kind, "reason": reason, "diagnostic": diagnostic.duplicate(true)})


func _source_kind_covers_view(kind: String) -> bool:
	if kind == "terrain":
		if not _terrain_source_set_declared: return false
		for source_id_value in _terrain_source_footprints:
			var terrain_source: Dictionary = _sources.get(source_id_value, {})
			if terrain_source.is_empty() or String(terrain_source.kind) != kind \
					or terrain_source.bounds != _terrain_source_footprints[source_id_value]:
				return false
		return true
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
