extends RefCounted
class_name ChunkPropVisualManifest

## Captures the outcome of the existing deterministic chunk-prop generator.
## This class never generates candidates and never advances a random stream.
const CONTENT_KINDS := ["trees_foliage", "props", "wildlife"]
const MAX_CANDIDATES_PER_CHUNK := 4096
const GAME_CHUNK_SIZE := 28
const DETAIL_RECEIPT_PUBLISHER_META := "visual_detail_receipt_publisher"
const FOLIAGE_DETAIL_TYPES := ["grass", "flowerStem", "flowerBloom", "reed", "scrub", "leafLitter"]


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
		var candidate: Dictionary = candidates_by_id[candidate_id]
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
	var candidate_source_revision := source_revision + ":sha256:" + candidate_hasher.finish().hex_encode()
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
			if detail_world_position.distance_to(viewer_world_position) > visibility_end:
				continue
		var counts: Dictionary = submitted_by_kind[kind]
		counts.candidateCount = int(counts.candidateCount) + 1
		submitted_candidate_count += 1
		counts.candidateIds.append(candidate_id)
		var required_tier := "near" if near_bounds.has_point(Vector2i(floori(position_xz.x), floori(position_xz.y))) else "horizon"
		if not bool(readiness.call("has_candidate", source_id, candidate_id)):
			var metadata := {"positionXZ": position_xz}
			if candidate.has("horizonSnapshot"):
				var horizon: Dictionary = candidate.horizonSnapshot
				metadata.merge({"horizonBodyInstanceId": horizon.bodyInstanceId,
					"horizonChunkInstanceId": horizon.chunkInstanceId,
					"horizonBatchInstanceId": horizon.batchInstanceId,
					"horizonGroupKey": horizon.groupKey,
					"horizonPageIndex": horizon.pageIndex,
					"horizonSlot": horizon.slot,
					"horizonBodyGlobalTransform": horizon.bodyGlobalTransform,
					"horizonBatchGlobalTransform": horizon.batchGlobalTransform,
					"horizonVisibilityRange": horizon.visibilityRange,
					"horizonInstanceTransforms": horizon.instanceTransforms,
					"horizonMeshInstanceIds": horizon.meshInstanceIds,
					"horizonMultimeshIds": horizon.multimeshIds,
					"horizonMeshResourceIds": horizon.meshResourceIds,
					"horizonMaterialIds": horizon.materialIds})
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
			if candidate.has("detailType"):
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
					&"visual_receipt_installed")
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
			var world_position := batch.global_transform * transform.origin
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
			candidates.append({"candidateId": candidate_id,
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
				"detailPublisher": publisher})
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
		if is_tree and not tree_published and current.has_meta("horizon_visual_publisher"):
			horizon_publisher = current.get_meta("horizon_visual_publisher") as Object
			if is_instance_valid(horizon_publisher) and horizon_publisher.has_method("installed_snapshot"):
				horizon_snapshot = horizon_publisher.call("installed_snapshot", current)
				if horizon_snapshot.get("status") == "ready" \
						and String(horizon_snapshot.get("propId", "")) == prop_id \
						and int(horizon_snapshot.get("chunkInstanceId", 0)) == owner.get_instance_id():
					renderable = true
				else:
					horizon_snapshot = {}
		var candidate := {"candidateId": prop_id, "kind": kind,
			"positionXZ": Vector2(body.global_position.x / cell_scale, body.global_position.z / cell_scale),
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
		candidates.append(candidate)
	for child in current.get_children():
		if child is Node:
			_collect_candidates(owner, child, chunk_key, seed, cell_scale, candidates, seen_ids,
				overflow, source_issue, detail_ordinals, observed_detail_batches, surface_only)
			if overflow[0] or not String(source_issue[0]).is_empty(): return


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
