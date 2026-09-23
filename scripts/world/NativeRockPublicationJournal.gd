extends RefCounted
class_name NativeRockPublicationJournal

## Read-only observer of the production rock publication event. The body owns
## the published visual outcome; the pinned native stream owns its footprint.
## This component does not install or replace gameplay props or collision.

var _main: Object
var _backend: Object
var _page: Object
var _exclusions: Object
var _ordinals_by_id: Dictionary = {}
var _rows_by_id: Dictionary = {}
var _pending_by_id: Dictionary = {}
var _pending_ids: Array[String] = []
var _max_callback_usec := 0
var _max_advance_usec := 0
var _last_failure := ""

func bind(main: Object, backend: Object, page: Object, exclusions: Object,
		ordered: Dictionary) -> Dictionary:
	if _main != null or main == null or backend == null or page == null or exclusions == null \
			or ordered.get("status") != "ready" or not main.has_signal("rock_published"):
		return {"status":"failed", "reason":"rock_journal_sources_not_ready"}
	var ordinals := {}
	for row in ordered.get("attempts", []):
		if row.get("feature", {}).get("kind") != "rock":
			continue
		var durable_id := String(row.feature.durableId)
		if durable_id.is_empty() or ordinals.has(durable_id):
			return {"status":"failed", "reason":"rock_journal_source_ids_invalid"}
		ordinals[durable_id] = int(row.ordinal)
	_main = main
	_backend = backend
	_page = page
	_exclusions = exclusions
	_ordinals_by_id = ordinals
	_main.rock_published.connect(_on_rock_published)
	return {"status":"ready", "rockCount":ordinals.size(), "productionCutover":false}

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
	_ordinals_by_id.clear()
	return {"status":"ready"}

func receipt(durable_id: String) -> Dictionary:
	return (_rows_by_id.get(durable_id, {}) as Dictionary).duplicate(true)

func status() -> Dictionary:
	return {"pending":_pending_ids.size(), "capacity":_ordinals_by_id.size(),
		"maxCallbackUsec":_max_callback_usec, "maxAdvanceUsec":_max_advance_usec,
		"lastFailure":_last_failure, "productionCutover":false}

## One projection may have variable native source cost. The caller chooses the
## item/time budget and schedules another advance while pending remains.
func advance(max_items: int = 1, max_usec: int = 2000) -> Dictionary:
	if _backend == null or max_items < 1 or max_usec < 1:
		return {"status":"failed", "reason":"rock_journal_not_bound_or_budget_invalid"}
	var started := Time.get_ticks_usec()
	var processed := 0
	while processed < max_items and not _pending_ids.is_empty():
		if processed > 0 and Time.get_ticks_usec() - started >= max_usec:
			break
		var durable_id: String = _pending_ids[0]
		var observed: Dictionary = _pending_by_id[durable_id]
		if not observed.colliderPresent:
			_last_failure = "published_rock_collider_missing"
			break
		var result: Dictionary = _backend.project_published_rock_footprint_shadow(
			_page, _exclusions, _ordinals_by_id[durable_id],
			observed.visualSource, observed.assetId)
		if result.get("status") != "ready":
			_last_failure = String(result.get("reason", "native_projection_pending"))
			break # Retain the exact observed outcome for retry after source readiness.
		result["observedBodyId"] = observed.bodyId
		result["observedDurableId"] = durable_id
		result["observedFromProductionEvent"] = true
		_rows_by_id[durable_id] = result
		_pending_ids.remove_at(0)
		_pending_by_id.erase(durable_id)
		processed += 1
		_last_failure = ""
	_max_advance_usec = maxi(_max_advance_usec, Time.get_ticks_usec() - started)
	return {"status":"ready" if _pending_ids.is_empty() else "pending",
		"processed":processed, "pending":_pending_ids.size(),
		"lastFailure":_last_failure, "elapsedUsec":Time.get_ticks_usec() - started}

func _on_rock_published(body: StaticBody3D) -> void:
	var started := Time.get_ticks_usec()
	if body == null or body.get_parent() == null or not body.is_inside_tree():
		return
	var durable_id := String(body.get_meta("prop_id", ""))
	if not _ordinals_by_id.has(durable_id):
		return
	var has_collider := false
	for child in body.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is SphereShape3D:
			has_collider = true
			break
	var observed := {"bodyId":body.get_instance_id(),
		"visualSource":String(body.get_meta("visual_source", "")),
		"assetId":String(body.get_meta("visual_asset_id", "")),
		"colliderPresent":has_collider}
	if not _pending_by_id.has(durable_id):
		_pending_ids.append(durable_id)
	_pending_by_id[durable_id] = observed
	_rows_by_id.erase(durable_id)
	_max_callback_usec = maxi(_max_callback_usec, Time.get_ticks_usec() - started)
