extends RefCounted
class_name NativeWindowedCollisionReadiness

## Pure aggregate gate over the current N3 logical closure and N5 physical
## receipts. A caller must collect receipts from live window owners after
## source and actor admission checks; this does not install or retire shapes.
const LAYOUT_SCHEMA := "n3-mesh-window-layout/v1"
const MAX_WINDOW_BLOCKS := 4096
const MAX_AGGREGATE_WINDOWS := 128
const MAX_AGGREGATE_BLOCKS := 65536

static func begin_cursor(layout: Dictionary, receipts_by_window: Dictionary) -> Dictionary:
	if layout.get("status") != "ready" or layout.get("schema") != LAYOUT_SCHEMA \
			or not layout.get("requiredBlocks") is Array \
			or not layout.get("windows") is Array \
			or not layout.get("identity") is Dictionary \
			or not layout.get("sourceIdentity") is Dictionary \
			or String(layout.get("logicalClosureToken", "")).is_empty() \
			or String(layout.get("layoutToken", "")).is_empty() \
			or int(layout.get("logicalDemandRevision", -1)) < 0:
		return {"status":"failed", "reason":"logical_collision_layout_pending"}
	var required: Array = layout.requiredBlocks
	var windows: Array = layout.windows
	if required.is_empty() or required.size() > MAX_AGGREGATE_BLOCKS \
			or int(layout.get("requiredBlockCount", -1)) != required.size() \
			or windows.is_empty() or windows.size() > MAX_AGGREGATE_WINDOWS \
			or int(layout.get("windowCount", -1)) != windows.size() \
			or int(layout.get("windowEdgeBlocks", -1)) != 16 \
			or int(layout.get("maxWindowBlocks", -1)) != MAX_WINDOW_BLOCKS:
		return {"status":"failed", "reason":"logical_collision_layout_capacity_invalid"}
	return {"status":"pending", "phase":"required", "cursor":0,
		"layout":layout, "receipts":receipts_by_window,
		"required":required, "windows":windows, "requiredSet":{},
		"covered":{}, "seenIds":{}, "seenTokens":{}, "missing":[],
		"windowIndex":0, "blockCursor":0, "operations":0,
		"statusResult":{}, "globalRevision":int(layout.identity.get("sourceRevision", -1))}

## Resumable exact aggregate validator. Every array/map operation represented by
## a cursor step costs one unit; callers also stop at a CPU-time budget.
static func advance_cursor(state: Dictionary, max_operations: int,
		max_usec: int) -> Dictionary:
	if state.get("status") != "pending": return state
	if max_operations <= 0 or max_usec <= 0:
		return {"status":"failed", "reason":"collision_cursor_budget_invalid"}
	var started := Time.get_ticks_usec()
	var operations := 0
	var required: Array = state.required
	var windows: Array = state.windows
	var layout: Dictionary = state.layout
	var receipts: Dictionary = state.receipts
	while operations < max_operations and Time.get_ticks_usec() - started < max_usec:
		var phase := String(state.phase)
		if phase == "required":
			if int(state.cursor) >= required.size():
				state.phase = "window_header"
				state.windowIndex = 0
				operations += 1
				continue
			var block = required[int(state.cursor)]
			if not block is Vector3i or state.requiredSet.has(block):
				return _cursor_failure("logical_collision_membership_invalid", operations)
			state.requiredSet[block] = true
			state.cursor = int(state.cursor) + 1
		elif phase == "window_header":
			if int(state.windowIndex) >= windows.size():
				if state.covered.size() != state.requiredSet.size():
					return _cursor_failure("collision_window_union_incomplete", operations)
				if not (state.missing as Array).is_empty():
					return {"status":"pending", "reason":"collision_window_physics_pending",
						"missingWindowIds":state.missing,
						"requiredBlockCount":required.size(), "operations":operations}
				return {"status":"ready", "reason":"",
					"logicalDemandRevision":layout.logicalDemandRevision,
					"logicalClosureToken":layout.logicalClosureToken,
					"layoutToken":layout.layoutToken,
					"requiredBlockCount":required.size(),
					"windowCount":windows.size(), "operations":operations}
			var window = windows[int(state.windowIndex)]
			if not window is Dictionary or not window.get("id") is Vector3i \
					or not window.get("blocks") is Array \
					or not window.get("identity") is Dictionary \
					or not window.get("localCurrentProof") is Dictionary \
					or int(window.get("windowIndex", -1)) != int(state.windowIndex) \
					or String(window.get("windowToken", "")).is_empty() \
					or String(window.get("closureToken", "")).is_empty():
				return _cursor_failure("collision_window_invalid", operations)
			var id: Vector3i = window.id
			var token := String(window.windowToken)
			var blocks: Array = window.blocks
			var local_identity: Dictionary = window.identity
			var proof: Dictionary = window.localCurrentProof
			var local_revision := int(local_identity.get("sourceRevision", -1))
			if state.globalRevision < 0 or local_revision < 0 \
					or local_revision > int(state.globalRevision) \
					or int(local_identity.get("ownerGeneration", -1)) <= 0 \
					or local_identity.get("ownerGeneration") != layout.identity.get("ownerGeneration") \
					or String(local_identity.get("sourceEpoch", "")).is_empty() \
					or local_identity.get("sourceEpoch") != layout.identity.get("sourceEpoch") \
					or local_identity.get("sourceIdentity") != layout.sourceIdentity \
					or int(proof.get("throughGlobalRevision", -1)) != int(state.globalRevision) \
					or String(proof.get("digest", "")).is_empty() \
					or (proof.get("kind") != "native_current_revision" \
						and proof.get("kind") != "verified_native_affected_mesh_exclusion/v1") \
					or (local_revision < int(state.globalRevision) \
						and proof.get("kind") != "verified_native_affected_mesh_exclusion/v1"):
				return {"status":"pending", "reason":"collision_window_local_proof_stale",
					"windowId":id, "operations":operations}
			if state.seenIds.has(id) or state.seenTokens.has(token) \
					or blocks.is_empty() or blocks.size() > MAX_WINDOW_BLOCKS:
				return _cursor_failure("collision_window_membership_invalid", operations)
			state.seenIds[id] = true
			state.seenTokens[token] = true
			state.blockCursor = 0
			state.phase = "window_blocks"
		elif phase == "window_blocks":
			var window: Dictionary = windows[int(state.windowIndex)]
			var blocks: Array = window.blocks
			if int(state.blockCursor) >= blocks.size():
				state.phase = "receipt_header"
				operations += 1
				continue
			var block = blocks[int(state.blockCursor)]
			var id: Vector3i = window.id
			if not block is Vector3i or not state.requiredSet.has(block) \
					or state.covered.has(block) \
					or Vector3i(floori(float(block.x) / 16.0),
						floori(float(block.y) / 16.0),
						floori(float(block.z) / 16.0)) != id:
				return _cursor_failure("collision_window_union_invalid", operations)
			state.covered[block] = true
			state.blockCursor = int(state.blockCursor) + 1
		elif phase == "receipt_header":
			var window: Dictionary = windows[int(state.windowIndex)]
			var id: Vector3i = window.id
			if not receipts.get(id, {}) is Dictionary:
				return {"status":"pending", "reason":"collision_window_receipt_stale",
					"windowId":id, "operations":operations}
			var receipt: Dictionary = receipts.get(id, {})
			if not bool(receipt.get("ready", false)):
				(state.missing as Array).append(id)
				state.windowIndex = int(state.windowIndex) + 1
				state.phase = "window_header"
				operations += 1
				continue
			if not receipt.get("provenance") is Dictionary \
					or not receipt.provenance.get("membershipProvenance") is Dictionary:
				return {"status":"pending", "reason":"collision_window_receipt_stale",
					"windowId":id, "operations":operations}
			var provenance: Dictionary = receipt.provenance
			var membership: Dictionary = provenance.membershipProvenance
			if int(receipt.get("physicsFrame", -1)) < 0 \
					or provenance.get("requestIdentity") != window.identity \
					or provenance.get("sourceIdentity") != layout.sourceIdentity \
					or membership.get("authority") != "pinned_demand" \
					or membership.get("windowToken") != window.windowToken \
					or membership.get("closureToken") != window.closureToken \
					or int(receipt.get("residentBlockCount", -1)) != window.blocks.size() \
					or not receipt.get("residentBlocks") is Array \
					or receipt.residentBlocks.size() != window.blocks.size():
				return {"status":"pending", "reason":"collision_window_receipt_stale",
					"windowId":id, "operations":operations}
			state.blockCursor = 0
			state.phase = "receipt_blocks"
		elif phase == "receipt_blocks":
			var window: Dictionary = windows[int(state.windowIndex)]
			var receipt: Dictionary = receipts[window.id]
			if int(state.blockCursor) >= window.blocks.size():
				state.windowIndex = int(state.windowIndex) + 1
				state.phase = "window_header"
				operations += 1
				continue
			if receipt.residentBlocks[int(state.blockCursor)] \
					!= window.blocks[int(state.blockCursor)]:
				return {"status":"pending", "reason":"collision_window_receipt_stale",
					"windowId":window.id, "operations":operations}
			state.blockCursor = int(state.blockCursor) + 1
		operations += 1
	return {"status":"pending", "operations":operations,
		"maxOperations":max_operations,
		"maxStepUsec":max_usec}

static func _cursor_failure(reason: String, operations: int) -> Dictionary:
	return {"status":"failed", "reason":reason, "operations":operations}

static func evaluate(layout: Dictionary, receipts_by_window: Dictionary) -> Dictionary:
	if layout.get("status") != "ready" or layout.get("schema") != LAYOUT_SCHEMA \
			or not layout.get("requiredBlocks") is Array \
			or not layout.get("windows") is Array \
			or not layout.get("identity") is Dictionary \
			or not layout.get("sourceIdentity") is Dictionary \
			or String(layout.get("logicalClosureToken", "")).is_empty() \
			or String(layout.get("layoutToken", "")).is_empty() \
			or int(layout.get("logicalDemandRevision", -1)) < 0:
		return {"status":"pending", "reason":"logical_collision_layout_pending"}
	var required: Array = layout.requiredBlocks
	var windows: Array = layout.windows
	if required.is_empty() or int(layout.get("requiredBlockCount", -1)) != required.size() \
			or int(layout.get("windowCount", -1)) != windows.size() \
			or int(layout.get("windowEdgeBlocks", -1)) != 16 \
			or int(layout.get("maxWindowBlocks", -1)) != MAX_WINDOW_BLOCKS \
			or windows.is_empty():
		return {"status":"failed", "reason":"logical_collision_layout_invalid"}
	var required_set := {}
	for block in required:
		if not block is Vector3i or required_set.has(block):
			return {"status":"failed", "reason":"logical_collision_membership_invalid"}
		required_set[block] = true
	var covered := {}
	var seen_ids := {}
	var seen_tokens := {}
	var missing: Array[Vector3i] = []
	for window_index in range(windows.size()):
		var window = windows[window_index]
		if not window is Dictionary or not window.get("id") is Vector3i \
				or not window.get("blocks") is Array \
				or not window.get("identity") is Dictionary \
				or not window.get("localCurrentProof") is Dictionary \
				or int(window.get("windowIndex", -1)) != window_index \
				or String(window.get("windowToken", "")).is_empty() \
				or String(window.get("closureToken", "")).is_empty():
			return {"status":"failed", "reason":"collision_window_invalid"}
		var id: Vector3i = window.id
		var token: String = window.windowToken
		var blocks: Array = window.blocks
		var local_identity: Dictionary = window.identity
		var proof: Dictionary = window.localCurrentProof
		var global_revision := int(layout.identity.get("sourceRevision", -1))
		var local_revision := int(local_identity.get("sourceRevision", -1))
		if global_revision < 0 or local_revision < 0 \
				or local_revision > global_revision \
				or int(local_identity.get("ownerGeneration", -1)) <= 0 \
				or local_identity.get("ownerGeneration") != layout.identity.get("ownerGeneration") \
				or String(local_identity.get("sourceEpoch", "")).is_empty() \
				or local_identity.get("sourceEpoch") != layout.identity.get("sourceEpoch") \
				or local_identity.get("sourceIdentity") != layout.sourceIdentity \
				or int(proof.get("throughGlobalRevision", -1)) != global_revision \
				or String(proof.get("digest", "")).is_empty() \
				or (proof.get("kind") != "native_current_revision" \
					and proof.get("kind") != "verified_native_affected_mesh_exclusion/v1") \
				or (local_revision < global_revision \
					and proof.get("kind") != "verified_native_affected_mesh_exclusion/v1"):
			return {"status":"pending", "reason":"collision_window_local_proof_stale",
				"windowId":id}
		if seen_ids.has(id) or seen_tokens.has(token) or blocks.is_empty() \
				or blocks.size() > MAX_WINDOW_BLOCKS:
			return {"status":"failed", "reason":"collision_window_membership_invalid"}
		seen_ids[id] = true
		seen_tokens[token] = true
		for block in blocks:
			if not block is Vector3i or not required_set.has(block) or covered.has(block) \
					or Vector3i(floori(float(block.x) / 16.0),
						floori(float(block.y) / 16.0),
						floori(float(block.z) / 16.0)) != id:
				return {"status":"failed", "reason":"collision_window_union_invalid"}
			covered[block] = true
		if not receipts_by_window.get(id, {}) is Dictionary:
			return {"status":"pending", "reason":"collision_window_receipt_stale",
				"windowId":id}
		var receipt: Dictionary = receipts_by_window.get(id, {})
		if not bool(receipt.get("ready", false)):
			missing.append(id)
			continue
		if not receipt.get("provenance") is Dictionary \
				or not receipt.provenance.get("membershipProvenance") is Dictionary:
			return {"status":"pending", "reason":"collision_window_receipt_stale",
				"windowId":id}
		var provenance: Dictionary = receipt.get("provenance", {})
		var membership: Dictionary = provenance.get("membershipProvenance", {})
		if int(receipt.get("physicsFrame", -1)) < 0 \
				or provenance.get("requestIdentity") != local_identity \
				or provenance.get("sourceIdentity") != layout.sourceIdentity \
				or membership.get("authority") != "pinned_demand" \
				or membership.get("windowToken") != token \
				or membership.get("closureToken") != window.closureToken \
				or int(receipt.get("residentBlockCount", -1)) != blocks.size() \
				or receipt.get("residentBlocks") != blocks:
			return {"status":"pending", "reason":"collision_window_receipt_stale",
				"windowId":id}
	if covered.size() != required_set.size():
		return {"status":"failed", "reason":"collision_window_union_incomplete"}
	if not missing.is_empty():
		return {"status":"pending", "reason":"collision_window_physics_pending",
			"missingWindowIds":missing, "requiredBlockCount":required.size()}
	return {"status":"ready", "reason":"", "logicalDemandRevision":layout.logicalDemandRevision,
		"logicalClosureToken":layout.logicalClosureToken,
		"layoutToken":layout.layoutToken,
		"requiredBlockCount":required.size(), "windowCount":windows.size()}
