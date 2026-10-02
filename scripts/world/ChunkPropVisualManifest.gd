extends RefCounted
class_name ChunkPropVisualManifest

## Captures the outcome of the existing deterministic chunk-prop generator.
## This class never generates candidates and never advances a random stream.
const CONTENT_KINDS := ["trees_foliage", "props", "wildlife"]
const MAX_CANDIDATES_PER_CHUNK := 4096
const GAME_CHUNK_SIZE := 28


static func capture(chunk: Node3D, chunk_key: Vector2i, seed: String,
		source_revision: String, scan_complete: bool, cell_scale: float) -> Dictionary:
	if not is_instance_valid(chunk) or not chunk.is_inside_tree() or chunk.is_queued_for_deletion():
		return {"status": "pending", "reason": "chunk_prop_source_not_live"}
	if seed.strip_edges().is_empty() or not is_finite(cell_scale) or cell_scale <= 0.0:
		return {"status": "failed", "reason": "invalid_chunk_prop_source_identity"}
	if not scan_complete:
		return {"status": "pending", "reason": "chunk_prop_candidate_scan_incomplete",
			"chunk": chunk_key, "sourceIdentity": _source_identity(chunk, chunk_key)}
	if source_revision.strip_edges().is_empty():
		return {"status": "failed", "reason": "invalid_chunk_prop_source_identity"}
	var candidates: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	var overflow: Array = [false]
	_collect_candidates(chunk, chunk, chunk_key, cell_scale, candidates, seen_ids, overflow)
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
		for field: String in [candidate_id, String(candidate.kind), String(candidate.treeVisualState),
				String(candidate.treeRenderLodTier), String(candidate.treeRecipeSignature),
				String.num(float(candidate.positionXZ.x), 6), String.num(float(candidate.positionXZ.y), 6),
				"1" if bool(candidate.renderable) else "0"]:
			_update_candidate_hasher(candidate_hasher, field)
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
		"chunk": chunk_key, "sourceIdentity": _source_identity(chunk, chunk_key),
		"sourceRevision": candidate_source_revision, "scanRevision": source_revision,
		"seed": seed, "chunkInstanceId": chunk.get_instance_id(),
		"scanComplete": true, "candidateCount": candidates.size(), "byKind": by_kind,
		"candidates": candidates, "scanAuthority": "completed_production_chunk_prop_spawn_state"}


static func submit(manifest: Dictionary, readiness: Object, view_revision: int,
		near_bounds: Rect2i) -> Dictionary:
	if not manifest.get("scanComplete", false):
		return {"status": "pending", "reason": manifest.get("reason", "chunk_prop_candidate_scan_incomplete")}
	if not is_instance_valid(readiness) or not readiness.has_method("expect_source") \
			or not readiness.has_method("describe_candidate") or not readiness.has_method("finish_source") \
			or not readiness.has_method("has_candidate") or not readiness.has_method("accept_receipt") \
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
		var counts: Dictionary = submitted_by_kind[kind]
		counts.candidateCount = int(counts.candidateCount) + 1
		submitted_candidate_count += 1
		counts.candidateIds.append(candidate_id)
		var required_tier := "near" if near_bounds.has_point(Vector2i(floori(position_xz.x), floori(position_xz.y))) else "horizon"
		if not bool(readiness.call("has_candidate", source_id, candidate_id)):
			var described: Dictionary = readiness.call("describe_candidate", source_id, candidate_id,
				required_tier, {"positionXZ": position_xz})
			if described.get("status") != "ready": return described
		if bool(candidate.get("renderable", false)):
			if not _candidate_lod_satisfies_tier(candidate, required_tier):
				pending_candidate_count += 1
				counts.pendingCount = int(counts.pendingCount) + 1
				counts.pendingIds.append(candidate_id)
				continue
			var owner := candidate.get("owner") as Node
			var representation := candidate.get("representation") as Node3D
			var receipt: Dictionary = readiness.call("accept_receipt", source_id, candidate_id,
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


static func _collect_candidates(owner: Node, current: Node, chunk_key: Vector2i, cell_scale: float,
		candidates: Array[Dictionary], seen_ids: Dictionary, overflow: Array) -> void:
	if current.is_queued_for_deletion(): return
	if candidates.size() >= MAX_CANDIDATES_PER_CHUNK:
		overflow[0] = true
		return
	if current != owner and current.has_meta("prop_id"):
		var prop_id := String(current.get_meta("prop_id", ""))
		if prop_id.is_empty() or seen_ids.has(prop_id):
			overflow[0] = true
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
		if is_tree and not tree_published:
			renderable = false
		candidates.append({"candidateId": prop_id, "kind": kind,
			"positionXZ": Vector2(body.global_position.x / cell_scale, body.global_position.z / cell_scale),
			"owner": current, "representation": current if renderable else null,
			"renderable": renderable, "treeVisualState": String(current.get_meta("tree_visual_state", "")),
			"treeRenderLodTier": String(current.get_meta("tree_render_lod_tier", "")),
			"treeRecipeSignature": String(current.get_meta("tree_recipe_signature", "")),
			"chunk": chunk_key})
	for child in current.get_children():
		if child is Node:
			_collect_candidates(owner, child, chunk_key, cell_scale, candidates, seen_ids, overflow)
			if overflow[0]: return


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


static func _all_represented(by_kind: Dictionary) -> bool:
	for kind: String in CONTENT_KINDS:
		if int(by_kind[kind].pendingCount) > 0: return false
	return true


static func _candidate_lod_satisfies_tier(candidate: Dictionary, required_tier: String) -> bool:
	if String(candidate.get("kind", "")) != "trees_foliage": return true
	var lod_tier := String(candidate.get("treeRenderLodTier", ""))
	if required_tier == "near": return lod_tier == "near"
	return lod_tier in ["near", "mid", "far", "impostor"]


static func _update_candidate_hasher(hasher: HashingContext, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	var length := PackedByteArray()
	length.resize(4)
	length.encode_u32(0, bytes.size())
	hasher.update(length)
	if not bytes.is_empty(): hasher.update(bytes)


static func _source_identity(chunk: Node3D, chunk_key: Vector2i) -> String:
	return "chunk-props:%d,%d:%d" % [chunk_key.x, chunk_key.y, chunk.get_instance_id()]
