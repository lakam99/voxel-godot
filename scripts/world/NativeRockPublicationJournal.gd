extends RefCounted
class_name NativeRockPublicationJournal

const MAX_SOURCE_ATTEMPTS := 28

## Read-only observer of the production rock publication event. The body owns
## the published visual outcome; the pinned native stream owns its footprint.
## This component does not install or replace gameplay props or collision.

var _main: Object
var _backend: Object
var _page: Object
var _exclusions: Object
var _chunk_root: Node
var _ordinals_by_id: Dictionary = {}
var _rows_by_id: Dictionary = {}
var _pending_by_id: Dictionary = {}
var _pending_ids: Array[String] = []
var _max_callback_usec := 0
var _max_advance_usec := 0
var _last_failure := ""
var _generation := 0
var _source_ticket := 0
var _source_ready := false
var _invalidated_by_id: Dictionary = {}
var _max_prepare_capture_usec := 0
var _max_prepare_poll_usec := 0
var _max_prepare_worker_usec := 0
var _callback_samples: Array[int] = []
var _advance_samples: Array[int] = []
var _prepare_capture_samples: Array[int] = []
var _prepare_poll_samples: Array[int] = []

func bind(main: Object, backend: Object, page: Object, exclusions: Object,
		ordered: Dictionary = {}, chunk_root: Node = null) -> Dictionary:
	if _main != null or main == null or backend == null or page == null or exclusions == null \
			or chunk_root == null \
			or not main.has_signal("rock_published"):
		return {"status":"failed", "reason":"rock_journal_sources_not_ready"}
	var ordinals := {}
	for row in ordered.get("attempts", []):
		if row.get("feature", {}).get("kind") != "rock":
			continue
		var durable_id := String(row.feature.durableId)
		if durable_id.is_empty() or ordinals.has(durable_id):
			return {"status":"failed", "reason":"rock_journal_source_ids_invalid"}
		ordinals[durable_id] = int(row.ordinal)
	if not ordered.is_empty() and ordered.get("status") != "ready":
		return {"status":"failed", "reason":"ordered_source_not_ready"}
	_generation += 1
	_rows_by_id.clear()
	_pending_by_id.clear()
	_pending_ids.clear()
	_invalidated_by_id.clear()
	_callback_samples.clear()
	_advance_samples.clear()
	_prepare_capture_samples.clear()
	_prepare_poll_samples.clear()
	_main = main
	_backend = backend
	_page = page
	_exclusions = exclusions
	_chunk_root = chunk_root
	_ordinals_by_id = ordinals
	_main.rock_published.connect(_on_rock_published)
	_source_ready = not ordinals.is_empty()
	return {"status":"ready", "rockCount":ordinals.size(),
		"sourcePrepared":_source_ready, "generation":_generation, "productionCutover":false}

func prepare_source() -> Dictionary:
	if _backend == null or _page == null or _exclusions == null:
		return {"status":"failed", "reason":"rock_journal_not_bound"}
	var result: Dictionary = _backend.begin_rock_ordered_source_async(_page, _exclusions)
	if result.get("status") == "pending":
		_source_ticket = int(result.get("ticket", _source_ticket))
		_max_prepare_capture_usec = maxi(_max_prepare_capture_usec,
			int(result.get("captureUsec", 0)))
		_prepare_capture_samples.append(int(result.get("captureUsec", 0)))
	return result

func poll_source() -> Dictionary:
	if _backend == null or _source_ticket <= 0:
		return {"status":"failed", "reason":"rock_source_ticket_missing"}
	var started := Time.get_ticks_usec()
	var result: Dictionary = _backend.poll_rock_ordered_source_async(_source_ticket)
	_max_prepare_poll_usec = maxi(_max_prepare_poll_usec, Time.get_ticks_usec() - started)
	_prepare_poll_samples.append(Time.get_ticks_usec() - started)
	if result.get("status") == "ready":
		_max_prepare_worker_usec = maxi(_max_prepare_worker_usec, int(result.get("workerUsec", 0)))
		_ordinals_by_id.clear()
		for row in result.get("rocks", []):
			_ordinals_by_id[String(row.durableId)] = int(row.ordinal)
		_source_ready = true
		for durable_id in _pending_ids:
			if not _ordinals_by_id.has(durable_id):
				_invalidated_by_id[durable_id] = "published_rock_not_in_native_source"
	return result

func unbind() -> Dictionary:
	if not _pending_ids.is_empty():
		return {"status":"failed", "reason":"rock_publication_intents_pending",
			"pending":_pending_ids.size()}
	if _main != null and is_instance_valid(_main) and _main.rock_published.is_connected(_on_rock_published):
		_main.rock_published.disconnect(_on_rock_published)
	_main = null
	_backend = null
	_page = null
	_exclusions = null
	_chunk_root = null
	_ordinals_by_id.clear()
	_rows_by_id.clear()
	_pending_by_id.clear()
	_pending_ids.clear()
	_invalidated_by_id.clear()
	_source_ticket = 0
	_source_ready = false
	_generation += 1
	return {"status":"ready"}

func receipt(durable_id: String) -> Dictionary:
	var row: Dictionary = _rows_by_id.get(durable_id, {})
	if int(row.get("generation", -1)) != _generation:
		return {}
	if row.get("status") == "ready":
		var body = row.bodyReference.get_ref() if row.get("bodyReference") is WeakRef else null
		var collider = row.colliderReference.get_ref() if row.get("colliderReference") is WeakRef else null
		if not is_instance_valid(body) or not is_instance_valid(collider) \
				or not body.is_inside_tree() or collider.get_parent() != body \
				or not (collider.shape is SphereShape3D) \
				or body.get_meta("prop_id", "") != durable_id \
				or body.get_meta("visual_source", "") != row.get("publishedVisualSource", "") \
				or body.get_meta("visual_asset_id", "") != row.get("publishedAssetId", ""):
			row = {"status":"failed", "reason":"published_rock_owner_or_collider_stale",
				"generation":_generation, "observedFromProductionEvent":true}
			_rows_by_id[durable_id] = row
	var snapshot := row.duplicate(true)
	snapshot.erase("bodyReference")
	snapshot.erase("colliderReference")
	return snapshot

func status() -> Dictionary:
	return {"pending":_pending_ids.size(), "capacity":_ordinals_by_id.size(),
		"maxCallbackUsec":_max_callback_usec, "maxAdvanceUsec":_max_advance_usec,
		"maxPrepareCaptureUsec":_max_prepare_capture_usec,
		"maxPreparePollUsec":_max_prepare_poll_usec,
		"maxPrepareWorkerUsec":_max_prepare_worker_usec,
		"callbackUsecSamples":_callback_samples.duplicate(),
		"advanceUsecSamples":_advance_samples.duplicate(),
		"prepareCaptureUsecSamples":_prepare_capture_samples.duplicate(),
		"preparePollUsecSamples":_prepare_poll_samples.duplicate(),
		"lastFailure":_last_failure, "productionCutover":false}

## One projection may have variable native source cost. The caller chooses the
## item/time budget and schedules another advance while pending remains.
func advance(max_items: int = 1, max_usec: int = 2000) -> Dictionary:
	if _backend == null or max_items < 1 or max_usec < 1:
		return {"status":"failed", "reason":"rock_journal_not_bound_or_budget_invalid"}
	if not _source_ready:
		return {"status":"pending", "reason":"rock_ordered_source_not_ready",
			"pending":_pending_ids.size()}
	var started := Time.get_ticks_usec()
	var processed := 0
	while processed < max_items and not _pending_ids.is_empty():
		if processed > 0 and Time.get_ticks_usec() - started >= max_usec:
			break
		var durable_id: String = _pending_ids[0]
		var observed: Dictionary = _pending_by_id[durable_id]
		var body = observed.bodyReference.get_ref() if observed.bodyReference is WeakRef else null
		var collider = observed.colliderReference.get_ref() if observed.colliderReference is WeakRef else null
		var invalid_reason := ""
		if not is_instance_valid(body) or not is_instance_valid(collider):
			invalid_reason = "observed_rock_body_invalidated"
		elif int(observed.generation) != _generation or not body.is_inside_tree() \
				or body.get_parent() == null or int(body.get_instance_id()) != int(observed.bodyId):
			invalid_reason = "observed_rock_body_stale"
		elif body.get_meta("prop_id", "") != durable_id \
				or body.get_meta("visual_source", "") != observed.visualSource \
				or body.get_meta("visual_asset_id", "") != observed.assetId:
			invalid_reason = "observed_rock_outcome_changed"
		elif collider.get_parent() != body or not (collider.shape is SphereShape3D):
			invalid_reason = "published_rock_collider_missing"
		if _invalidated_by_id.has(durable_id):
			invalid_reason = String(_invalidated_by_id[durable_id])
		if not invalid_reason.is_empty():
			_rows_by_id[durable_id] = {"status":"failed", "reason":invalid_reason,
				"generation":_generation, "observedFromProductionEvent":true}
			_pending_ids.remove_at(0)
			_pending_by_id.erase(durable_id)
			_invalidated_by_id.erase(durable_id)
			processed += 1
			continue
		var result: Dictionary = _backend.project_published_rock_footprint_shadow(
			_page, _exclusions, _ordinals_by_id[durable_id],
			observed.visualSource, observed.assetId)
		if result.get("status") != "ready":
			_last_failure = String(result.get("reason", "native_projection_pending"))
			break # Retain the exact observed outcome for retry after source readiness.
		result["observedBodyId"] = observed.bodyId
		result["observedColliderId"] = observed.colliderId
		result["observedDurableId"] = durable_id
		result["observedFromProductionEvent"] = true
		result["generation"] = _generation
		result["bodyReference"] = observed.bodyReference
		result["colliderReference"] = observed.colliderReference
		_rows_by_id[durable_id] = result
		_pending_ids.remove_at(0)
		_pending_by_id.erase(durable_id)
		processed += 1
		_last_failure = ""
	_max_advance_usec = maxi(_max_advance_usec, Time.get_ticks_usec() - started)
	_advance_samples.append(Time.get_ticks_usec() - started)
	return {"status":"ready" if _pending_ids.is_empty() else "pending",
		"processed":processed, "pending":_pending_ids.size(),
		"lastFailure":_last_failure, "elapsedUsec":Time.get_ticks_usec() - started}

func _on_rock_published(body: StaticBody3D, collider: CollisionShape3D) -> void:
	var started := Time.get_ticks_usec()
	if body == null or body.get_parent() != _chunk_root or not body.is_inside_tree():
		return
	var durable_id := String(body.get_meta("prop_id", ""))
	if _source_ready and not _ordinals_by_id.has(durable_id):
		_rows_by_id[durable_id] = {"status":"failed", "reason":"published_rock_not_in_native_source",
			"generation":_generation, "observedFromProductionEvent":true}
		return
	if not _pending_by_id.has(durable_id) and _pending_ids.size() >= MAX_SOURCE_ATTEMPTS:
		_last_failure = "rock_publication_source_capacity_exceeded"
		return
	var observed := {"bodyId":body.get_instance_id(),
		"colliderId": collider.get_instance_id() if collider != null else 0,
		"visualSource":String(body.get_meta("visual_source", "")),
		"assetId":String(body.get_meta("visual_asset_id", "")),
		"bodyReference":weakref(body), "colliderReference":weakref(collider),
		"generation":_generation}
	if not _pending_by_id.has(durable_id):
		_pending_ids.append(durable_id)
	_pending_by_id[durable_id] = observed
	_rows_by_id.erase(durable_id)
	_invalidated_by_id.erase(durable_id)
	var body_id := body.get_instance_id()
	var collider_id := collider.get_instance_id() if collider != null else 0
	var generation := _generation
	body.tree_exiting.connect(_on_published_node_exiting.bind(
		durable_id, generation, body_id, collider_id, "body"), CONNECT_ONE_SHOT)
	if collider != null:
		collider.tree_exiting.connect(_on_published_node_exiting.bind(
			durable_id, generation, body_id, collider_id, "collider"), CONNECT_ONE_SHOT)
	_max_callback_usec = maxi(_max_callback_usec, Time.get_ticks_usec() - started)
	_callback_samples.append(Time.get_ticks_usec() - started)

func _on_published_node_exiting(durable_id: String, generation: int, body_id: int,
		collider_id: int, node_kind: String) -> void:
	if generation != _generation:
		return
	var reason := "observed_rock_body_exited" if node_kind == "body" \
		else "observed_rock_collider_exited"
	var observed: Dictionary = _pending_by_id.get(durable_id, {})
	if int(observed.get("bodyId", 0)) == body_id \
			and (node_kind == "body" or int(observed.get("colliderId", 0)) == collider_id):
		if not _invalidated_by_id.has(durable_id):
			_invalidated_by_id[durable_id] = reason + "_before_projection"
	var row: Dictionary = _rows_by_id.get(durable_id, {})
	if row.get("status") == "ready" and int(row.get("observedBodyId", 0)) == body_id \
			and (node_kind == "body" or int(row.get("observedColliderId", 0)) == collider_id):
		_rows_by_id[durable_id] = {"status":"failed", "reason":reason,
			"generation":_generation, "observedFromProductionEvent":true}
