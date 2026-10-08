extends RefCounted
class_name ChunkPropVisualManifest

## Captures the outcome of the existing deterministic chunk-prop generator.
## This class never generates candidates and never advances a random stream.
const CONTENT_KINDS := ["trees_foliage", "props", "wildlife"]
const MAX_CANDIDATES_PER_CHUNK := 4096
const GAME_CHUNK_SIZE := 28
const DETAIL_RECEIPT_PUBLISHER_META := "visual_detail_receipt_publisher"
const FOLIAGE_DETAIL_TYPES := ["grass", "flowerStem", "flowerBloom", "reed", "scrub", "leafLitter"]
var _capture: Dictionary = {}


static func underground_visuals_required(player_y: float, surface_y: float,
		cell_scale: float) -> bool:
	if not is_finite(player_y) or not is_finite(surface_y) \
			or not is_finite(cell_scale) or cell_scale <= 0.0:
		return false
	return player_y < surface_y - cell_scale * 0.35


static func capture(chunk: Node3D, chunk_key: Vector2i, seed: String,
		source_revision: String, scan_complete: bool, cell_scale: float,
		surface_only: bool = false) -> Dictionary:
	if not is_instance_valid(chunk) or not chunk.is_inside_tree() or chunk.is_queued_for_deletion():
		return {"status": "pending", "reason": "chunk_prop_source_not_live"}
	if seed.strip_edges().is_empty() or not is_finite(cell_scale) or cell_scale <= 0.0:
		return {"status": "failed", "reason": "invalid_chunk_prop_source_identity"}
	if not scan_complete:
		return {"status": "pending", "reason": "chunk_prop_candidate_scan_incomplete",
			"chunk": chunk_key, "sourceIdentity": _source_identity(seed, chunk_key)}
	if source_revision.strip_edges().is_empty():
		return {"status": "failed", "reason": "invalid_chunk_prop_source_identity"}
	var candidates: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	var overflow: Array = [false]
	var source_issue: Array = ["", ""]
	var detail_ordinals := {}
	var observed_detail_batches := {}
	_collect_candidates(chunk, chunk, chunk_key, seed, cell_scale, candidates, seen_ids,
		overflow, source_issue, detail_ordinals, observed_detail_batches, surface_only)
	if String(source_issue[0]).is_empty() and chunk.has_meta("visual_detail_expected_batches"):
		source_issue[0] = _detail_batch_source_issue(
			chunk.get_meta("visual_detail_expected_batches"), observed_detail_batches)
	if not String(source_issue[0]).is_empty():
		return {"status": "pending", "reason": String(source_issue[0]), "retryable": true,
			"chunk": chunk_key, "candidateCount": candidates.size(),
			"candidateId": String(source_issue[1])}
	if bool(overflow[0]):
		return {"status": "pending", "reason": "chunk_prop_manifest_capacity", "retryable": true,
			"chunk": chunk_key, "candidateCount": candidates.size()}
	return _complete_capture_from_candidates(chunk, chunk_key, seed, source_revision,
		cell_scale, surface_only, candidates)


static func _complete_capture_from_candidates(chunk: Node3D, chunk_key: Vector2i,
		seed: String, source_revision: String, cell_scale: float,
		surface_only: bool, candidates: Array[Dictionary],
		prehashed_revision: String = "") -> Dictionary:
	var scope_revision := source_revision + (":surface" if surface_only else ":full")
	var candidate_source_revision := prehashed_revision
	if candidate_source_revision.is_empty():
		var stable_ids: Array[String] = []
		var candidates_by_id: Dictionary = {}
		for candidate: Dictionary in candidates:
			var candidate_id := String(candidate.candidateId)
			stable_ids.append(candidate_id)
			candidates_by_id[candidate_id] = candidate
		stable_ids.sort()
		var candidate_hasher := HashingContext.new()
		candidate_hasher.start(HashingContext.HASH_SHA256)
		for candidate_id: String in stable_ids:
			_hash_candidate(candidate_hasher, candidate_id, candidates_by_id[candidate_id])
		candidate_source_revision = scope_revision + ":sha256:" \
			+ candidate_hasher.finish().hex_encode()
	else:
		candidate_source_revision = scope_revision + ":" + prehashed_revision
	var by_kind := {}
	for kind: String in CONTENT_KINDS:
		by_kind[kind] = {"candidateCount": 0, "representedCount": 0, "pendingCount": 0,
			"candidateIds": [], "pendingIds": []}
	for candidate: Dictionary in candidates:
		var counts: Dictionary = by_kind[candidate.kind]
		counts.candidateCount = int(counts.candidateCount) + 1
		counts.candidateIds.append(String(candidate.candidateId))
		if bool(candidate.renderable):
			counts.representedCount = int(counts.representedCount) + 1
		else:
			counts.pendingCount = int(counts.pendingCount) + 1
			counts.pendingIds.append(String(candidate.candidateId))
	return {"status": "ready" if _all_represented(by_kind) else "pending",
		"reason": "" if _all_represented(by_kind) else "chunk_prop_visual_publication_pending",
		"chunk": chunk_key, "sourceIdentity": _source_identity(seed, chunk_key),
		"sourceRevision": candidate_source_revision, "scanRevision": source_revision,
		"seed": seed, "chunkInstanceId": chunk.get_instance_id(),
		"cellScale": cell_scale,
		"scanComplete": true, "candidateCount": candidates.size(), "byKind": by_kind,
		"candidates": candidates, "scanAuthority": "completed_production_surface_prop_spawn_state"
			if surface_only else "completed_production_chunk_prop_spawn_state",
		"surfaceOnly": surface_only}


static func begin_capture(main: Object, chunk: Node3D, chunk_key: Vector2i,
		seed: String, source_revision: String, scan_complete: bool,
		cell_scale: float, surface_only: bool = false) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(chunk) \
			or not chunk.is_inside_tree() or chunk.is_queued_for_deletion():
		return {"status": "pending", "reason": "chunk_prop_source_not_live", "retryable": true}
	if seed.strip_edges().is_empty() or not is_finite(cell_scale) or cell_scale <= 0.0:
		return {"status": "failed", "reason": "invalid_chunk_prop_source_identity"}
	if not scan_complete:
		return {"status": "pending", "reason": "chunk_prop_candidate_scan_incomplete",
			"retryable": true}
	if source_revision.strip_edges().is_empty():
		return {"status": "failed", "reason": "invalid_chunk_prop_source_identity"}
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary or chunks_value.get(chunk_key) != chunk:
		return {"status": "pending", "reason": "chunk_prop_source_owner_changed",
			"retryable": true}
	var complete_key := "chunk_surface_candidate_scan_complete" if surface_only \
		else "chunk_prop_candidate_scan_complete"
	var revision_key := "chunk_surface_candidate_source_revision" if surface_only \
		else "chunk_prop_candidate_source_revision"
	if not bool(chunk.get_meta(complete_key, false)) \
			or String(chunk.get_meta(revision_key, "")) != source_revision:
		return {"status": "pending", "reason": "chunk_prop_candidate_scan_incomplete",
			"retryable": true}
	var child_refs: Array[WeakRef] = []
	var child_ids: Array[int] = []
	for child_value in chunk.get_children():
		var child := child_value as Node
		if not is_instance_valid(child) or child.is_queued_for_deletion():
			return {"status": "pending", "reason": "chunk_prop_source_owner_changed",
				"retryable": true}
		child_refs.append(weakref(child))
		child_ids.append(child.get_instance_id())
	var expected_batches: Variant = null
	if chunk.has_meta("visual_detail_expected_batches"):
		expected_batches = chunk.get_meta("visual_detail_expected_batches")
		if expected_batches is Array:
			expected_batches = (expected_batches as Array).duplicate(true)
	var candidates: Array[Dictionary] = []
	var materialized: Array[Dictionary] = []
	var job := ChunkPropVisualManifest.new()
	job._capture = {"main": weakref(main), "mainId": main.get_instance_id(),
		"chunk": weakref(chunk), "chunkId": chunk.get_instance_id(),
		"chunkKey": chunk_key, "seed": seed, "scanRevision": source_revision,
		"completeKey": complete_key, "revisionKey": revision_key,
		"removedRevision": int(main.get("removed_props_revision")),
		"cellScale": cell_scale, "surfaceOnly": surface_only,
		"childRefs": child_refs, "childIds": child_ids, "childCursor": 0,
		"decorChildren": [], "batchRefs": [], "batchCursor": 0,
		"activeBatch": {}, "candidates": candidates, "candidateById": {},
		"stableIds": [], "seenIds": {}, "detailOrdinals": {},
		"observedBatches": {}, "hashCursor": 0, "materializeCursor": 0,
		"materialized": materialized, "stage": "children",
		"expectedBatches": expected_batches}
	return {"status": "pending", "reason": "chunk_prop_bounded_capture_budget",
		"retryable": true, "job": job}


func advance(max_atoms: int = 16, max_usec: int = 2000) -> Dictionary:
	if _capture.is_empty():
		return {"status": "failed", "reason": "chunk_prop_bounded_job_missing"}
	var context: Dictionary = _capture_context()
	if context.is_empty():
		_capture.clear()
		return {"status": "pending", "reason": "chunk_prop_bounded_source_changed",
			"retryable": true}
	var chunk: Node3D = context.chunk
	var started := Time.get_ticks_usec()
	var processed := 0
	var limit := maxi(1, max_atoms)
	var deadline := maxi(1, max_usec)
	while processed < limit and (processed == 0 or Time.get_ticks_usec() - started < deadline):
		var stage := String(_capture.stage)
		if stage == "children":
			if not (_capture.activeBatch as Dictionary).is_empty():
				var batch_result: Dictionary = _capture_batch_instance()
				if batch_result.get("status") != "ready":
					_capture.clear()
					return batch_result
				processed += 1
				continue
			var batch_refs: Array = _capture.batchRefs
			var batch_cursor := int(_capture.batchCursor)
			if batch_cursor < batch_refs.size():
				var batch_ref := batch_refs[batch_cursor] as WeakRef
				_capture.batchCursor = batch_cursor + 1
				var batch := batch_ref.get_ref() as Node if batch_ref != null else null
				if not is_instance_valid(batch):
					_capture.clear()
					return {"status": "pending", "reason": "chunk_prop_bounded_source_changed",
						"retryable": true}
				if batch.has_meta("detail_type"):
					var begun: Dictionary = _capture_begin_batch(batch)
					if begun.get("status") != "ready":
						_capture.clear()
						return begun
				else:
					var collected: Dictionary = _capture_subtree(chunk, batch)
					if collected.get("status") != "ready":
						_capture.clear()
						return collected
				processed += 1
				continue
			var child_refs: Array = _capture.childRefs
			var child_cursor := int(_capture.childCursor)
			if child_cursor >= child_refs.size():
				var issue := _detail_batch_source_issue(_capture.expectedBatches,
					_capture.observedBatches) if _capture.expectedBatches != null else ""
				if not issue.is_empty():
					_capture.clear()
					return {"status": "pending", "reason": issue, "retryable": true}
				var hasher := HashingContext.new()
				hasher.start(HashingContext.HASH_SHA256)
				_capture.hasher = hasher
				_capture.stage = "hash"
				continue
			var child_ref := child_refs[child_cursor] as WeakRef
			_capture.childCursor = child_cursor + 1
			var child := child_ref.get_ref() as Node if child_ref != null else null
			if not is_instance_valid(child):
				_capture.clear()
				return {"status": "pending", "reason": "chunk_prop_bounded_source_changed",
					"retryable": true}
			if String(child.get_meta("kind", "")) == "decor" \
					and not child.has_meta("prop_id"):
				var batch_refs_next: Array[WeakRef] = []
				var batch_ids: Array[int] = []
				for batch_value in child.get_children():
					var batch_node := batch_value as Node
					batch_refs_next.append(weakref(batch_node))
					batch_ids.append(batch_node.get_instance_id())
				_capture.decorChildren.append({"root": weakref(child),
					"rootId": child.get_instance_id(), "childIds": batch_ids})
				_capture.batchRefs = batch_refs_next
				_capture.batchCursor = 0
			else:
				var collected: Dictionary = _capture_subtree(chunk, child)
				if collected.get("status") != "ready":
					_capture.clear()
					return collected
			processed += 1
			continue
		if stage == "hash":
			var ids: Array = _capture.stableIds
			var hash_cursor := int(_capture.hashCursor)
			if hash_cursor >= ids.size():
				_capture.sourceRevision = String(_capture.scanRevision) + ":sha256:" \
					+ (_capture.hasher as HashingContext).finish().hex_encode()
				_capture.erase("hasher")
				_capture.stage = "materialize"
				continue
			var id := String(ids[hash_cursor])
			_hash_candidate(_capture.hasher, id, _capture.candidateById[id])
			_capture.hashCursor = hash_cursor + 1
			processed += 1
			continue
		if stage == "materialize":
			var candidate_cursor := int(_capture.materializeCursor)
			var captured: Array = _capture.candidates
			if candidate_cursor >= captured.size():
				if not _capture_topology_current(chunk):
					_capture.clear()
					return {"status": "pending", "reason": "chunk_prop_bounded_source_changed",
						"retryable": true}
				var completed_candidates: Array[Dictionary] = _capture.materialized
				var complete := _complete_capture_from_candidates(chunk, _capture.chunkKey,
					String(_capture.seed), String(_capture.scanRevision), float(_capture.cellScale),
					bool(_capture.surfaceOnly), completed_candidates, String(_capture.sourceRevision))
				_capture.clear()
				return complete
			var materialized: Dictionary = _capture_materialize(captured[candidate_cursor])
			if materialized.is_empty():
				_capture.clear()
				return {"status": "pending", "reason": "chunk_prop_bounded_source_changed",
					"retryable": true}
			(_capture.materialized as Array).append(materialized)
			_capture.materializeCursor = candidate_cursor + 1
			processed += 1
			continue
		return {"status": "failed", "reason": "chunk_prop_bounded_stage_invalid"}
	return {"status": "pending", "reason": "chunk_prop_bounded_capture_budget",
		"retryable": true, "stage": _capture.stage,
		"candidateCount": (_capture.candidates as Array).size()}


func _capture_context() -> Dictionary:
	var main: Object = (_capture.main as WeakRef).get_ref()
	var chunk: Node3D = (_capture.chunk as WeakRef).get_ref() as Node3D
	if not is_instance_valid(main) or not is_instance_valid(chunk) \
			or main.get_instance_id() != int(_capture.mainId) \
			or chunk.get_instance_id() != int(_capture.chunkId) \
			or not chunk.is_inside_tree() or chunk.is_queued_for_deletion() \
			or not main.get("chunks") is Dictionary \
			or (main.get("chunks") as Dictionary).get(_capture.chunkKey) != chunk \
			or int(main.get("removed_props_revision")) != int(_capture.removedRevision) \
			or not bool(chunk.get_meta(String(_capture.completeKey), false)) \
			or String(chunk.get_meta(String(_capture.revisionKey), "")) != _capture.scanRevision:
		return {}
	return {"main": main, "chunk": chunk}


func _capture_topology_current(chunk: Node3D) -> bool:
	var direct: Array = chunk.get_children()
	if direct.size() != (_capture.childIds as Array).size(): return false
	for index in direct.size():
		if direct[index].get_instance_id() != int(_capture.childIds[index]): return false
	for record_value in _capture.decorChildren:
		var record: Dictionary = record_value
		var decor: Node = (record.root as WeakRef).get_ref() as Node
		if not is_instance_valid(decor) or decor.get_instance_id() != int(record.rootId):
			return false
		var children: Array = decor.get_children()
		if children.size() != (record.childIds as Array).size(): return false
		for index in children.size():
			if children[index].get_instance_id() != int(record.childIds[index]): return false
	return true


func _capture_subtree(chunk: Node3D, child: Node) -> Dictionary:
	var produced: Array[Dictionary] = []
	var overflow: Array = [false]
	var issue: Array = ["", ""]
	_collect_candidates(chunk, child, _capture.chunkKey, String(_capture.seed),
		float(_capture.cellScale), produced, _capture.seenIds, overflow, issue,
		_capture.detailOrdinals, _capture.observedBatches, bool(_capture.surfaceOnly))
	if bool(overflow[0]) or (_capture.candidates as Array).size() + produced.size() > MAX_CANDIDATES_PER_CHUNK:
		return {"status": "pending", "reason": "chunk_prop_manifest_capacity", "retryable": true}
	if not String(issue[0]).is_empty():
		return {"status": "pending", "reason": String(issue[0]), "retryable": true,
			"candidateId": String(issue[1])}
	for candidate in produced:
		_capture_add_candidate(candidate)
	return {"status": "ready"}


func _capture_begin_batch(node: Node) -> Dictionary:
	var batch := node as MultiMeshInstance3D
	if batch == null: return {"status": "pending", "reason": "chunk_detail_batch_type_invalid", "retryable": true}
	var detail_type := String(batch.get_meta("detail_type", ""))
	var publisher := batch.get_meta(DETAIL_RECEIPT_PUBLISHER_META, null) as Object
	if detail_type.is_empty() or not is_instance_valid(publisher) \
			or not publisher.has_method("candidate_count") \
			or not publisher.has_method("candidate_at") \
			or not publisher.has_method("source_identity") \
			or not publisher.has_method("visual_receipt_installed"):
		return {"status": "pending", "reason": "chunk_detail_batch_publisher_missing",
			"retryable": true}
	var identity: Dictionary = publisher.call("source_identity")
	if int(identity.get("batchInstanceId", 0)) != batch.get_instance_id() \
			or String(identity.get("detailType", "")) != detail_type:
		return {"status": "pending", "reason": "chunk_detail_batch_publisher_stale",
			"retryable": true}
	var count := int(publisher.call("candidate_count"))
	if count <= 0:
		return {"status": "pending", "reason": "chunk_detail_batch_candidates_missing",
			"retryable": true}
	var ordinal := int(_capture.detailOrdinals.get(detail_type, 0))
	_capture.detailOrdinals[detail_type] = ordinal + 1
	_capture.observedBatches[batch.get_instance_id()] = {
		"detailType": detail_type, "instanceCount": count}
	_capture.activeBatch = {"batch": weakref(batch), "batchId": batch.get_instance_id(),
		"publisher": weakref(publisher), "publisherId": publisher.get_instance_id(),
		"identity": identity, "detailType": detail_type, "ordinal": ordinal,
		"count": count, "index": 0}
	return {"status": "ready"}


func _capture_batch_instance() -> Dictionary:
	var active: Dictionary = _capture.activeBatch
	var batch: MultiMeshInstance3D = (active.batch as WeakRef).get_ref() as MultiMeshInstance3D
	var publisher: Object = (active.publisher as WeakRef).get_ref()
	if not is_instance_valid(batch) or not is_instance_valid(publisher) \
			or batch.get_instance_id() != int(active.batchId) \
			or publisher.get_instance_id() != int(active.publisherId) \
			or int(publisher.call("candidate_count")) != int(active.count):
		return {"status": "pending", "reason": "chunk_prop_bounded_source_changed",
			"retryable": true}
	var index := int(active.index)
	if index >= int(active.count):
		_capture.activeBatch = {}
		return {"status": "ready"}
	var instance: Dictionary = publisher.call("candidate_at", index)
	var transform: Transform3D = instance.get("instanceTransform", Transform3D.IDENTITY)
	if int(instance.get("instanceIndex", -1)) != index or not transform.is_finite():
		return {"status": "pending", "reason": "chunk_detail_batch_candidate_invalid",
			"retryable": true}
	var candidate := _detail_candidate_record(batch, publisher, _capture.chunkKey,
		String(_capture.seed), float(_capture.cellScale), String(active.detailType),
		int(active.ordinal), active.identity, instance)
	if (_capture.candidates as Array).size() >= MAX_CANDIDATES_PER_CHUNK:
		return {"status": "pending", "reason": "chunk_prop_manifest_capacity", "retryable": true}
	if (_capture.seenIds as Dictionary).has(candidate.candidateId):
		return {"status": "pending", "reason": "chunk_prop_candidate_id_duplicate",
			"retryable": true, "candidateId": candidate.candidateId}
	_capture.seenIds[candidate.candidateId] = true
	_capture_add_candidate(candidate)
	_capture.activeBatch.index = index + 1
	return {"status": "ready"}


func _capture_add_candidate(candidate: Dictionary) -> void:
	var sealed := candidate.duplicate()
	for field in ["owner", "representation", "detailPublisher", "horizonPublisher", "treePublisher",
			"horizonOrdinaryPublisher"]:
		if sealed.has(field):
			var object := sealed[field] as Object
			sealed[field] = weakref(object) if is_instance_valid(object) else null
	(_capture.candidates as Array).append(sealed)
	var id := String(sealed.candidateId)
	_capture.candidateById[id] = sealed
	var ids: Array = _capture.stableIds
	var low := 0
	var high := ids.size()
	while low < high:
		var middle := int((low + high) / 2)
		if String(ids[middle]) < id: low = middle + 1
		else: high = middle
	ids.insert(low, id)


func _capture_materialize(sealed: Dictionary) -> Dictionary:
	var candidate := sealed.duplicate()
	for field in ["owner", "representation", "detailPublisher", "horizonPublisher", "treePublisher",
			"horizonOrdinaryPublisher"]:
		if not candidate.has(field): continue
		var ref := candidate[field] as WeakRef
		candidate[field] = ref.get_ref() if ref != null else null
	var body := candidate.get("owner") as Node3D
	if not is_instance_valid(body) or body.is_queued_for_deletion() \
			or not body.is_inside_tree(): return {}
	if candidate.has("detailType"):
		var publisher := candidate.get("detailPublisher") as Object
		var batch := body as MultiMeshInstance3D
		if not is_instance_valid(publisher) or not publisher.has_method("candidate_at") \
				or not publisher.has_method("candidate_count") \
				or not publisher.has_method("source_identity") or batch == null \
				or batch.multimesh == null or batch.multimesh.mesh == null \
				or int(publisher.call("candidate_count")) <= int(candidate.detailInstanceIndex):
			return {}
		var identity: Dictionary = publisher.call("source_identity")
		if int(identity.get("batchInstanceId", 0)) != int(candidate.detailBatchInstanceId) \
				or int(identity.get("multimeshInstanceId", 0)) != int(candidate.detailMultimeshInstanceId) \
				or int(identity.get("meshInstanceId", 0)) != int(candidate.detailMeshInstanceId) \
				or float(identity.get("detailVisibilityEnd", -1.0)) != float(candidate.detailVisibilityEnd) \
				or String(identity.get("detailType", "")) != String(candidate.detailType) \
				or batch.multimesh.get_instance_id() != int(candidate.detailMultimeshInstanceId) \
				or batch.multimesh.mesh.get_instance_id() != int(candidate.detailMeshInstanceId) \
				or batch.multimesh.instance_count != int(publisher.call("candidate_count")) \
				or batch.visibility_range_end != float(candidate.detailVisibilityEnd):
			return {}
		var current: Dictionary = publisher.call("candidate_at", int(candidate.detailInstanceIndex))
		if current.get("instanceTransform") != candidate.detailInstanceTransform \
				or current.get("instanceColor") != candidate.detailInstanceColor \
				or current.get("instanceCustomData") != candidate.detailInstanceCustomData \
				or batch.multimesh.get_instance_transform(int(candidate.detailInstanceIndex)) \
					!= candidate.detailInstanceTransform \
				or (batch.multimesh.use_colors \
					and batch.multimesh.get_instance_color(int(candidate.detailInstanceIndex)) \
					!= candidate.detailInstanceColor) \
				or (batch.multimesh.use_custom_data \
					and batch.multimesh.get_instance_custom_data(int(candidate.detailInstanceIndex)) \
					!= candidate.detailInstanceCustomData) \
				or body.global_transform != candidate.detailBatchGlobalTransform:
			return {}
	else:
		if String(body.get_meta("prop_id", "")) != String(candidate.candidateId): return {}
		var position: Variant = body.get_meta("wildlife_home", Vector3.INF) \
			if String(candidate.kind) == "wildlife" else body.global_position
		if not position is Vector3 or not (position as Vector3).is_finite() \
				or Vector2(position.x / float(_capture.cellScale),
					position.z / float(_capture.cellScale)) != candidate.positionXZ:
			return {}
	if body.has_meta("tree_visual_state"):
		_refresh_tree_candidate(candidate, body)
	return candidate


static func _hash_candidate(candidate_hasher: HashingContext,
		candidate_id: String, candidate: Dictionary) -> void:
	# This revision describes the producer's candidate set. Publication
	# state and LOD are live receipt facts and must not restart all other
	# candidates in the chunk when one tree finishes its visual queue.
	for field: String in [candidate_id, String(candidate.kind),
			String.num(float(candidate.positionXZ.x), 6), String.num(float(candidate.positionXZ.y), 6),
			str(candidate.get("detailType", "")),
			str(candidate.get("detailInstanceIndex", -1)),
			str(candidate.get("detailInstanceTransform", "")),
			str(candidate.get("detailBatchGlobalTransform", "")),
			str(candidate.get("detailInstanceColor", "")),
			str(candidate.get("detailInstanceCustomData", "")),
			String.num(float(candidate.get("detailVisibilityEnd", 0.0)), 6)]:
		_update_candidate_hasher(candidate_hasher, field)
	if candidate.has("detailType"):
		_update_candidate_hasher_bytes(candidate_hasher, var_to_bytes([
				candidate.detailInstanceIndex, candidate.detailInstanceTransform,
				candidate.detailBatchGlobalTransform, candidate.detailInstanceColor,
				candidate.detailInstanceCustomData, candidate.detailVisibilityEnd]))


## Re-evaluate only live presentation for a producer-validated candidate
## snapshot. Candidate IDs, positions and source revision remain the seeded
## capture; submit still decides view inclusion, required tier and receipts.
static func refresh_cached(snapshot: Dictionary, chunk: Node3D) -> Dictionary:
	if not bool(snapshot.get("scanComplete", false)) or not is_instance_valid(chunk) \
			or not chunk.is_inside_tree() or chunk.is_queued_for_deletion() \
			or int(snapshot.get("chunkInstanceId", 0)) != chunk.get_instance_id():
		return {"status": "pending", "reason": "cached_chunk_prop_source_changed"}
	var candidates: Array[Dictionary] = []
	var by_kind := {}
	for kind: String in CONTENT_KINDS:
		by_kind[kind] = {"candidateCount": 0, "representedCount": 0,
			"pendingCount": 0, "candidateIds": [], "pendingIds": []}
	for candidate_value in snapshot.get("candidates", []):
		if not candidate_value is Dictionary:
			return {"status": "pending", "reason": "cached_chunk_prop_candidate_invalid"}
		var candidate: Dictionary = candidate_value.duplicate()
		var candidate_id := String(candidate.get("candidateId", ""))
		var kind := String(candidate.get("kind", ""))
		var body := candidate.get("owner") as Node3D
		if candidate_id.is_empty() or not by_kind.has(kind) or not is_instance_valid(body) \
				or body.is_queued_for_deletion() or not body.is_inside_tree():
			return {"status": "pending", "reason": "cached_chunk_prop_candidate_owner_changed"}
		if candidate.has("detailType"):
			var batch := body as MultiMeshInstance3D
			if batch == null or not batch.has_meta(DETAIL_RECEIPT_PUBLISHER_META):
				return {"status": "pending", "reason": "cached_chunk_detail_publisher_missing"}
			var detail_publisher := batch.get_meta(DETAIL_RECEIPT_PUBLISHER_META) as Object
			if not is_instance_valid(detail_publisher):
				return {"status": "pending", "reason": "cached_chunk_detail_publisher_missing"}
			candidate.detailPublisher = detail_publisher
			candidate.renderable = _has_visible_renderable(batch)
			candidate.representation = batch if bool(candidate.renderable) else null
		else:
			var is_tree := body.has_meta("tree_visual_state")
			var tree_published := is_tree \
				and String(body.get_meta("tree_visual_state", "")) == "published"
			var renderable := _has_visible_renderable(body)
			var horizon_ordinary := body.get_parent() == chunk \
				and bool(chunk.get_meta("horizon_visual_only", false)) \
				and kind != "trees_foliage"
			if horizon_ordinary and not body.has_meta("horizon_ordinary_visual_publisher"):
				renderable = false
			if is_tree and not tree_published:
				renderable = false
			candidate.erase("horizonPublisher")
			candidate.erase("horizonSnapshot")
			# A far-LOD tree can be published by a chunk-owned batch after its
			# recipe completes. Validate that external installation even though the
			# gameplay body is already in the published state.
			var external_publisher_key := "static_chunk_render_publisher" if body.has_meta("static_chunk_render_publisher") else "horizon_visual_publisher"
			if is_tree and body.has_meta(external_publisher_key):
				var horizon_publisher := body.get_meta(external_publisher_key) as Object
				if is_instance_valid(horizon_publisher) and horizon_publisher.has_method("installed_snapshot"):
					var horizon_snapshot: Dictionary = horizon_publisher.call("installed_snapshot", body)
					if horizon_snapshot.get("status") == "ready" \
							and String(horizon_snapshot.get("propId", "")) == candidate_id \
							and int(horizon_snapshot.get("chunkInstanceId", 0)) == chunk.get_instance_id():
						renderable = true
						candidate.horizonPublisher = horizon_publisher
						candidate.horizonSnapshot = horizon_snapshot
			candidate.erase("horizonOrdinaryPublisher")
			if horizon_ordinary and body.has_meta("horizon_ordinary_visual_publisher"):
				candidate.horizonOrdinaryPublisher = body.get_meta("horizon_ordinary_visual_publisher")
				candidate.horizonOrdinaryBodyId = body.get_instance_id()
				candidate.horizonOrdinaryRootId = chunk.get_instance_id()
			candidate.renderable = renderable
			candidate.representation = body if renderable else null
			candidate.treeVisualState = String(body.get_meta("tree_visual_state", ""))
			candidate.treeRenderLodTier = String(body.get_meta("tree_render_lod_tier", ""))
			candidate.treeRecipeSignature = String(body.get_meta("tree_recipe_signature", ""))
			if is_tree: _refresh_tree_candidate(candidate, body)
		candidates.append(candidate)
		var counts: Dictionary = by_kind[kind]
		counts.candidateCount = int(counts.candidateCount) + 1
		counts.candidateIds.append(candidate_id)
		if bool(candidate.renderable):
			counts.representedCount = int(counts.representedCount) + 1
		else:
			counts.pendingCount = int(counts.pendingCount) + 1
			counts.pendingIds.append(candidate_id)
	var refreshed := snapshot.duplicate()
	refreshed.candidates = candidates
	refreshed.byKind = by_kind
	refreshed.status = "ready" if _all_represented(by_kind) else "pending"
	refreshed.reason = "" if refreshed.status == "ready" \
		else "chunk_prop_visual_publication_pending"
	return refreshed


static func submit(manifest: Dictionary, readiness: Object, view_revision: int,
		near_bounds: Rect2i, viewer_world_position: Vector3) -> Dictionary:
	if not manifest.get("scanComplete", false):
		return {"status": "pending", "reason": manifest.get("reason", "chunk_prop_candidate_scan_incomplete")}
	if not is_instance_valid(readiness) or not readiness.has_method("expect_source") \
			or not readiness.has_method("describe_candidate") or not readiness.has_method("finish_source") \
			or not readiness.has_method("has_candidate") or not readiness.has_method("accept_receipt") \
			or not readiness.has_method("accept_publisher_receipt") \
			or not readiness.has_method("candidate_in_view"):
		return {"status": "failed", "reason": "visible_readiness_owner_contract_missing"}
	var chunk_key: Vector2i = manifest.get("chunk", Vector2i.ZERO)
	var chunk_bounds := Rect2i(chunk_key * GAME_CHUNK_SIZE, Vector2i.ONE * GAME_CHUNK_SIZE)
	var source_identity := String(manifest.get("sourceIdentity", ""))
	var source_revision := String(manifest.get("sourceRevision", ""))
	if source_identity.is_empty() or source_revision.is_empty():
		return {"status": "failed", "reason": "chunk_prop_manifest_identity_missing"}
	var source_ids := {}
	var pending_candidate_count := 0
	var submitted_candidate_count := 0
	var submitted_by_kind := {}
	for kind: String in CONTENT_KINDS:
		submitted_by_kind[kind] = {"candidateCount": 0, "representedCount": 0,
			"pendingCount": 0, "candidateIds": [], "pendingIds": []}
		var source_id := "%s:%s" % [source_identity, kind]
		source_ids[kind] = source_id
		var source_result: Dictionary = readiness.call("expect_source", source_id, kind,
			source_identity, source_revision, chunk_bounds, view_revision)
		if source_result.get("status") != "ready":
			return source_result
	for candidate_value in manifest.get("candidates", []):
		if not candidate_value is Dictionary: continue
		var candidate: Dictionary = candidate_value
		var candidate_id := String(candidate.get("candidateId", ""))
		var kind := String(candidate.get("kind", ""))
		if not source_ids.has(kind):
			return {"status": "failed", "reason": "chunk_prop_manifest_kind_invalid", "candidateId": candidate_id}
		var source_id := String(source_ids[kind])
		var position_xz: Vector2 = candidate.get("positionXZ", Vector2.ZERO)
		if not bool(readiness.call("candidate_in_view", position_xz)):
			continue
		if candidate.has("detailType"):
			# Decorative MultiMeshes are intentionally culled at their production
			# visibility range. Beyond it they are not an expected horizon detail.
			var detail_world_position: Vector3 = candidate.get("positionWorld", Vector3.INF)
			var visibility_end := float(candidate.get("detailVisibilityEnd", 0.0))
			if not viewer_world_position.is_finite() or not detail_world_position.is_finite() \
					or not is_finite(visibility_end) or visibility_end <= 0.0:
				return {"status": "failed", "reason": "detail_visibility_policy_invalid",
					"candidateId": candidate_id}
			# Godot applies GeometryInstance3D visibility ranges to the batch node's
			# origin, while the readiness ledger tracks each MultiMesh instance at its
			# own world position. An instance may be close enough while its whole batch
			# is culled, so only require a receipt when both policies include it.
			var batch_transform: Transform3D = candidate.get("detailBatchGlobalTransform", Transform3D.IDENTITY)
			if batch_transform.origin.distance_to(viewer_world_position) > visibility_end \
					or detail_world_position.distance_to(viewer_world_position) > visibility_end:
				continue
		var counts: Dictionary = submitted_by_kind[kind]
		counts.candidateCount = int(counts.candidateCount) + 1
		submitted_candidate_count += 1
		counts.candidateIds.append(candidate_id)
		var required_tier := "near" if near_bounds.has_point(Vector2i(floori(position_xz.x), floori(position_xz.y))) else "horizon"
		# Keep admission metadata stable for a source revision, but build publisher
		# proof from the current manifest observation on every submit. A native
		# chunk-owned tree page is a sibling of its gameplay body, so the body and
		# its current parent/signature identify the installation without retaining
		# Nodes or stale horizon-page placeholders in the readiness ledger.
		var metadata := {"positionXZ": position_xz,
			"sourceCandidateRenderable": bool(candidate.get("renderable", false)),
			"sourceCandidateTreeVisualState": String(candidate.get("treeVisualState", "")),
			"sourceCandidateTreeLodTier": String(candidate.get("treeRenderLodTier", ""))}
		if candidate.has("treePublisher"):
			var tree_owner: Variant = candidate.get("owner")
			metadata.merge({"candidateBodyInstanceId":tree_owner.get_instance_id() if is_instance_valid(tree_owner) else 0,
				"treeRecipeSignature":String(candidate.get("treeRecipeSignature", ""))})
		if candidate.has("horizonSnapshot"):
			var horizon: Dictionary = candidate.horizonSnapshot
			metadata.merge({"horizonBodyInstanceId": horizon.get("bodyInstanceId", 0),
				"horizonChunkInstanceId": horizon.get("chunkInstanceId", 0),
				"horizonBatchInstanceId": horizon.get("batchInstanceId", 0),
				"horizonGroupKey": horizon.get("groupKey", ""),
				"horizonPageIndex": horizon.get("pageIndex", -1),
				"horizonSlot": horizon.get("slot", -1),
				"horizonBodyGlobalTransform": horizon.get("bodyGlobalTransform", Transform3D.IDENTITY),
				"horizonBatchGlobalTransform": horizon.get("batchGlobalTransform", Transform3D.IDENTITY),
				"horizonVisibilityRange": horizon.get("visibilityRange", 0.0),
				"horizonInstanceTransforms": horizon.get("instanceTransforms", []),
				"horizonMeshInstanceIds": horizon.get("meshInstanceIds", []),
				"horizonMultimeshIds": horizon.get("multimeshIds", []),
				"horizonMeshResourceIds": horizon.get("meshResourceIds", []),
				"horizonMaterialIds": horizon.get("materialIds", [])})
			var candidate_owner := candidate.get("owner") as Node3D
			var chunk_owner := candidate_owner.get_parent() as Node3D if is_instance_valid(candidate_owner) else null
			metadata.merge({"candidateBodyInstanceId": candidate_owner.get_instance_id() if is_instance_valid(candidate_owner) else 0,
				"candidateChunkInstanceId": chunk_owner.get_instance_id() if is_instance_valid(chunk_owner) else 0,
				"treeRecipeSignature": String(candidate.get("treeRecipeSignature", ""))})
		if candidate.has("detailType"):
			metadata.merge({"detailType": candidate.detailType,
				"batchInstanceId": candidate.detailBatchInstanceId,
				"batchGlobalTransform": candidate.detailBatchGlobalTransform,
				"multimeshInstanceId": candidate.detailMultimeshInstanceId,
				"meshInstanceId": candidate.detailMeshInstanceId,
				"chunkInstanceId": manifest.chunkInstanceId,
				"instanceIndex": candidate.detailInstanceIndex,
				"instanceTransform": candidate.detailInstanceTransform,
				"instanceColor": candidate.detailInstanceColor,
				"instanceCustomData": candidate.detailInstanceCustomData,
				"detailVisibilityEnd": candidate.detailVisibilityEnd})
		if candidate.has("horizonOrdinaryPublisher"):
			metadata.merge({"horizonOrdinaryBodyId": candidate.horizonOrdinaryBodyId,
				"horizonOrdinaryRootId": candidate.horizonOrdinaryRootId})
		if not bool(readiness.call("has_candidate", source_id, candidate_id)):
			var described: Dictionary = readiness.call("describe_candidate", source_id, candidate_id,
				required_tier, metadata)
			if described.get("status") != "ready": return described
		if bool(candidate.get("renderable", false)):
			var candidate_owner := candidate.get("owner") as Node
			if required_tier == "horizon" and kind != "trees_foliage" \
					and is_instance_valid(candidate_owner) and candidate_owner.get_parent() != null \
					and bool(candidate_owner.get_parent().get_meta("horizon_visual_only", false)) \
					and not _has_geometry_in_view_range(candidate_owner, viewer_world_position):
				pending_candidate_count += 1
				counts.pendingCount = int(counts.pendingCount) + 1
				counts.pendingIds.append(candidate_id)
				continue
			if not _candidate_lod_satisfies_tier(candidate, required_tier):
				pending_candidate_count += 1
				counts.pendingCount = int(counts.pendingCount) + 1
				counts.pendingIds.append(candidate_id)
				continue
			var receipt: Dictionary
			if candidate.has("treePublisher"):
				receipt = readiness.call("accept_publisher_receipt", source_id, candidate_id,
					candidate_id + ":tree-publication", required_tier, source_identity,
					source_revision, view_revision, candidate.treePublisher, &"visual_receipt_installed")
			elif candidate.has("detailType"):
				var publisher := candidate.get("detailPublisher") as Object
				receipt = readiness.call("accept_publisher_receipt", source_id, candidate_id,
					"%s:installed" % candidate_id, required_tier,
					source_identity, source_revision, view_revision, publisher,
					&"visual_receipt_installed")
			elif required_tier == "horizon" and candidate.has("horizonSnapshot"):
				var publisher := candidate.get("horizonPublisher") as Object
				receipt = readiness.call("accept_publisher_receipt", source_id, candidate_id,
					"%s:horizon" % candidate_id, required_tier,
					source_identity, source_revision, view_revision, publisher,
					&"visual_receipt_installed", metadata)
			elif required_tier == "horizon" and candidate.has("horizonOrdinaryPublisher"):
				var publisher := candidate.get("horizonOrdinaryPublisher") as Object
				receipt = readiness.call("accept_publisher_receipt", source_id, candidate_id,
					"%s:installed" % candidate_id, required_tier,
					source_identity, source_revision, view_revision, publisher,
					&"visual_receipt_installed")
			else:
				var owner := candidate.get("owner") as Node
				var representation := candidate.get("representation") as Node3D
				receipt = readiness.call("accept_receipt", source_id, candidate_id,
					"%s:installed" % candidate_id, required_tier,
					source_identity, source_revision, view_revision, owner, representation)
			if receipt.get("status") == "failed": return receipt
			if receipt.get("status") != "ready":
				pending_candidate_count += 1
				counts.pendingCount = int(counts.pendingCount) + 1
				counts.pendingIds.append(candidate_id)
			else:
				counts.representedCount = int(counts.representedCount) + 1
		else:
			pending_candidate_count += 1
			counts.pendingCount = int(counts.pendingCount) + 1
			counts.pendingIds.append(candidate_id)
	for kind: String in CONTENT_KINDS:
		var finish: Dictionary = readiness.call("finish_source", String(source_ids[kind]),
			source_identity, source_revision, view_revision)
		if finish.get("status") != "ready": return finish
	return {"status": "pending" if pending_candidate_count > 0 else "ready",
		"reason": "chunk_prop_visual_publication_pending" if pending_candidate_count > 0 else "",
		"manifestSubmitted": true, "chunk": chunk_key, "sourceRevision": source_revision,
		"candidateCount": submitted_candidate_count,
		"pendingCount": pending_candidate_count,
		"byKind": submitted_by_kind,
		"sourceIds": source_ids}


static func _collect_candidates(owner: Node, current: Node, chunk_key: Vector2i, seed: String, cell_scale: float,
		candidates: Array[Dictionary], seen_ids: Dictionary, overflow: Array,
		source_issue: Array, detail_ordinals: Dictionary, observed_detail_batches: Dictionary,
		surface_only: bool) -> void:
	if current.is_queued_for_deletion(): return
	if candidates.size() >= MAX_CANDIDATES_PER_CHUNK:
		overflow[0] = true
		return
	if current != owner and current.has_meta("detail_type"):
		var batch := current as MultiMeshInstance3D
		if batch == null:
			source_issue[0] = "chunk_detail_batch_type_invalid"
			return
		var detail_type := String(batch.get_meta("detail_type", ""))
		var publisher: Object = null
		if batch.has_meta(DETAIL_RECEIPT_PUBLISHER_META):
			publisher = batch.get_meta(DETAIL_RECEIPT_PUBLISHER_META) as Object
		if detail_type.is_empty() or not is_instance_valid(publisher) \
				or not publisher.has_method("candidate_snapshot") \
				or not publisher.has_method("source_identity") \
				or not publisher.has_method("visual_receipt_installed"):
			source_issue[0] = "chunk_detail_batch_publisher_missing"
			return
		var identity: Dictionary = publisher.call("source_identity")
		if int(identity.get("batchInstanceId", 0)) != batch.get_instance_id() \
				or String(identity.get("detailType", "")) != detail_type:
			source_issue[0] = "chunk_detail_batch_publisher_stale"
			return
		var ordinal := int(detail_ordinals.get(detail_type, 0))
		detail_ordinals[detail_type] = ordinal + 1
		var snapshot: Array = publisher.call("candidate_snapshot")
		if snapshot.is_empty():
			source_issue[0] = "chunk_detail_batch_candidates_missing"
			return
		observed_detail_batches[batch.get_instance_id()] = {
			"detailType": detail_type, "instanceCount": snapshot.size()}
		for instance_value in snapshot:
			if not instance_value is Dictionary:
				source_issue[0] = "chunk_detail_batch_candidate_invalid"
				return
			var instance: Dictionary = instance_value
			var index := int(instance.get("instanceIndex", -1))
			var transform: Transform3D = instance.get("instanceTransform", Transform3D.IDENTITY)
			if index < 0 or not transform.is_finite():
				source_issue[0] = "chunk_detail_batch_candidate_invalid"
				return
			var candidate_id := "%s:detail:%d,%d:%s:%d:%d" % [seed,
				chunk_key.x, chunk_key.y, detail_type, ordinal, index]
			if seen_ids.has(candidate_id):
				source_issue[0] = "chunk_prop_candidate_id_duplicate"
				source_issue[1] = candidate_id
				return
			if candidates.size() >= MAX_CANDIDATES_PER_CHUNK:
				overflow[0] = true
				return
			seen_ids[candidate_id] = true
			candidates.append(_detail_candidate_record(batch, publisher, chunk_key, seed,
				cell_scale, detail_type, ordinal, identity, instance))
		return
	if current != owner and current.has_meta("prop_id"):
		var prop_id := String(current.get_meta("prop_id", ""))
		if surface_only and prop_id.begins_with("%s:underground:" % seed):
			return
		if prop_id.is_empty():
			source_issue[0] = "chunk_prop_candidate_id_missing"
			return
		if seen_ids.has(prop_id):
			source_issue[0] = "chunk_prop_candidate_id_duplicate"
			source_issue[1] = prop_id
			return
		seen_ids[prop_id] = true
		var kind := _content_kind(current)
		if kind.is_empty():
			# Generated items outside the visual-world domain remain owned by
			# their existing systems and are not silently misclassified.
			kind = "props"
		var body := current as Node3D
		var candidate_world_position := body.global_position
		if kind == "wildlife":
			# The existing movement home is recorded at seeded spawn. Current
			# body position can change without changing the generated candidate.
			candidate_world_position = current.get_meta("wildlife_home", Vector3.INF)
			if not candidate_world_position.is_finite():
				source_issue[0] = "chunk_wildlife_spawn_position_missing"
				source_issue[1] = prop_id
				return
		var is_tree := current.has_meta("tree_visual_state")
		var tree_published := is_tree and String(current.get_meta("tree_visual_state", "")) == "published"
		var renderable := _has_visible_renderable(current)
		var horizon_ordinary := current.get_parent() == owner \
			and bool(owner.get_meta("horizon_visual_only", false)) and kind != "trees_foliage"
		if horizon_ordinary and not current.has_meta("horizon_ordinary_visual_publisher"):
			renderable = false
		if is_tree and not tree_published:
			renderable = false
		var horizon_publisher: Object = null
		var horizon_snapshot := {}
		var external_publisher_key := "static_chunk_render_publisher" if current.has_meta("static_chunk_render_publisher") else "horizon_visual_publisher"
		if is_tree and current.has_meta(external_publisher_key):
			horizon_publisher = current.get_meta(external_publisher_key) as Object
			if is_instance_valid(horizon_publisher) and horizon_publisher.has_method("installed_snapshot"):
				horizon_snapshot = horizon_publisher.call("installed_snapshot", current)
				if horizon_snapshot.get("status") == "ready" \
						and String(horizon_snapshot.get("propId", "")) == prop_id \
						and int(horizon_snapshot.get("chunkInstanceId", 0)) == owner.get_instance_id():
					renderable = true
				else:
					horizon_snapshot = {}
		var candidate := {"candidateId": prop_id, "kind": kind,
			"positionXZ": Vector2(candidate_world_position.x / cell_scale,
				candidate_world_position.z / cell_scale),
			"owner": current, "representation": current if renderable else null,
			"renderable": renderable, "treeVisualState": String(current.get_meta("tree_visual_state", "")),
			"treeRenderLodTier": String(current.get_meta("tree_render_lod_tier", "")),
			"treeRecipeSignature": String(current.get_meta("tree_recipe_signature", "")),
			"chunk": chunk_key}
		if not horizon_snapshot.is_empty():
			candidate["horizonPublisher"] = horizon_publisher
			candidate["horizonSnapshot"] = horizon_snapshot
		if horizon_ordinary \
				and current.has_meta("horizon_ordinary_visual_publisher"):
			candidate["horizonOrdinaryPublisher"] = current.get_meta("horizon_ordinary_visual_publisher")
			candidate["horizonOrdinaryBodyId"] = current.get_instance_id()
			candidate["horizonOrdinaryRootId"] = owner.get_instance_id()
		if is_tree: _refresh_tree_candidate(candidate, body)
		candidates.append(candidate)
	for child in current.get_children():
		if child is Node:
			_collect_candidates(owner, child, chunk_key, seed, cell_scale, candidates, seen_ids,
				overflow, source_issue, detail_ordinals, observed_detail_batches, surface_only)
			if overflow[0] or not String(source_issue[0]).is_empty(): return


static func _refresh_tree_candidate(candidate: Dictionary, body: Node3D) -> void:
	# A placeholder is not a completed recipe. Every tree representation uses
	# the queue's actual accepted installation, including external native roots.
	candidate.erase("horizonPublisher")
	candidate.erase("horizonSnapshot")
	candidate.erase("treePublisher")
	candidate["renderable"] = false
	candidate["representation"] = null
	var reference: Variant = body.get_meta("tree_publication_owner", null)
	var publisher: Variant = reference.get_ref() if reference is WeakRef else null
	if not is_instance_valid(publisher) or not publisher.has_method("tree_publication_proof"): return
	var proof: Dictionary = publisher.call("tree_publication_proof", body)
	if int(proof.get("bodyInstanceId", 0)) != body.get_instance_id(): return
	candidate["treePublisher"] = publisher
	candidate["renderable"] = bool(proof.get("installed", false))
	candidate["representation"] = body if candidate.renderable else null
	candidate["treeRenderLodTier"] = String(proof.get("tier", ""))
	candidate["treeRecipeSignature"] = String(proof.get("recipeSignature", ""))

static func _detail_candidate_record(batch: MultiMeshInstance3D, publisher: Object,
		chunk_key: Vector2i, seed: String, cell_scale: float,
		detail_type: String, ordinal: int, identity: Dictionary,
		instance: Dictionary) -> Dictionary:
	var index := int(instance.get("instanceIndex", -1))
	var transform: Transform3D = instance.get("instanceTransform", Transform3D.IDENTITY)
	var world_position := batch.global_transform * transform.origin
	var candidate_id := "%s:detail:%d,%d:%s:%d:%d" % [seed,
		chunk_key.x, chunk_key.y, detail_type, ordinal, index]
	return {"candidateId": candidate_id,
		"kind": "trees_foliage" if FOLIAGE_DETAIL_TYPES.has(detail_type) else "props",
		"positionXZ": Vector2(world_position.x / cell_scale, world_position.z / cell_scale),
		"positionWorld": world_position,
		"owner": batch, "representation": batch,
		"renderable": _has_visible_renderable(batch),
		"treeVisualState": "", "treeRenderLodTier": "",
		"treeRecipeSignature": "", "chunk": chunk_key,
		"detailType": detail_type, "detailInstanceIndex": index,
		"detailBatchGlobalTransform": batch.global_transform,
		"detailInstanceTransform": transform,
		"detailInstanceColor": instance.get("instanceColor", Color.WHITE),
		"detailInstanceCustomData": instance.get("instanceCustomData", Color.WHITE),
		"detailVisibilityEnd": float(identity.get("detailVisibilityEnd", 0.0)),
		"detailBatchInstanceId": int(identity.get("batchInstanceId", 0)),
		"detailMultimeshInstanceId": int(identity.get("multimeshInstanceId", 0)),
		"detailMeshInstanceId": int(identity.get("meshInstanceId", 0)),
		"detailPublisher": publisher}


static func _detail_batch_source_issue(expected_value: Variant,
		observed: Dictionary) -> String:
	if not expected_value is Array:
		return "chunk_detail_batch_expected_source_invalid"
	var expected: Array = expected_value
	var expected_ids := {}
	for record_value in expected:
		if not record_value is Dictionary:
			return "chunk_detail_batch_expected_source_invalid"
		var record: Dictionary = record_value
		var batch_id := int(record.get("batchInstanceId", 0))
		var detail_type := String(record.get("detailType", ""))
		var instance_count := int(record.get("instanceCount", 0))
		if batch_id <= 0 or detail_type.is_empty() or instance_count <= 0 \
				or expected_ids.has(batch_id):
			return "chunk_detail_batch_expected_source_invalid"
		expected_ids[batch_id] = true
		if not observed.has(batch_id):
			return "chunk_detail_batch_installation_missing"
		var installed: Dictionary = observed[batch_id]
		if String(installed.detailType) != detail_type \
				or int(installed.instanceCount) != instance_count:
			return "chunk_detail_batch_installation_changed"
	if observed.size() != expected_ids.size():
		return "chunk_detail_batch_unexpected_installation"
	return ""


static func _content_kind(node: Node) -> String:
	if node.has_meta("wildlife_variant"): return "wildlife"
	if node.has_meta("tree_visual_state") or node.is_in_group("generated_tree_trunks"):
		return "trees_foliage"
	return "props"


static func _has_visible_renderable(root_node: Node) -> bool:
	if root_node is GeometryInstance3D:
		var geometry := root_node as GeometryInstance3D
		if geometry.visible and geometry.is_visible_in_tree():
			if geometry is MeshInstance3D and (geometry as MeshInstance3D).mesh != null: return true
			if geometry is MultiMeshInstance3D and (geometry as MultiMeshInstance3D).multimesh != null: return true
	for child in root_node.get_children():
		if child is Node and _has_visible_renderable(child): return true
	return false


static func _has_geometry_in_view_range(root_node: Node, viewer_world_position: Vector3) -> bool:
	if not viewer_world_position.is_finite():
		return false
	if root_node is GeometryInstance3D:
		var geometry := root_node as GeometryInstance3D
		if geometry.visible and geometry.is_visible_in_tree():
			var end_distance := geometry.visibility_range_end
			if end_distance <= 0.0 or geometry.global_position.distance_to(viewer_world_position) + 3.0 < end_distance:
				if geometry is MeshInstance3D and (geometry as MeshInstance3D).mesh != null:
					return true
				if geometry is MultiMeshInstance3D and (geometry as MultiMeshInstance3D).multimesh != null:
					return true
	for child in root_node.get_children():
		if child is Node and _has_geometry_in_view_range(child, viewer_world_position):
			return true
	return false


static func _all_represented(by_kind: Dictionary) -> bool:
	for kind: String in CONTENT_KINDS:
		if int(by_kind[kind].pendingCount) > 0: return false
	return true


static func _candidate_lod_satisfies_tier(candidate: Dictionary, required_tier: String) -> bool:
	if String(candidate.get("kind", "")) != "trees_foliage": return true
	if candidate.has("detailType"): return true
	var lod_tier := String(candidate.get("treeRenderLodTier", ""))
	if required_tier == "near": return lod_tier == "near"
	if candidate.has("horizonSnapshot"): return true
	return lod_tier in ["near", "mid", "far", "impostor"]


static func _update_candidate_hasher(hasher: HashingContext, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	_update_candidate_hasher_bytes(hasher, bytes)


static func _update_candidate_hasher_bytes(hasher: HashingContext, bytes: PackedByteArray) -> void:
	var length := PackedByteArray()
	length.resize(4)
	length.encode_u32(0, bytes.size())
	hasher.update(length)
	if not bytes.is_empty(): hasher.update(bytes)


static func _source_identity(seed: String, chunk_key: Vector2i) -> String:
	return "chunk-props:%s:%d,%d" % [seed, chunk_key.x, chunk_key.y]
