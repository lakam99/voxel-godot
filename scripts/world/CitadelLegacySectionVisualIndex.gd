extends RefCounted
class_name CitadelLegacySectionVisualIndex

## Incremental, publisher-owned visual inventory used by section receipt ACKs.
## Nodes remain live main-thread objects; this index is never worker input.
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const DEFAULT_ADVANCE_USEC := 350
const MAX_ADVANCE_USEC := 1000

var _publishers: Dictionary = {}
var _scoped_queries: Dictionary = {}
var _advance_owner_cursor := 0


func clear() -> void:
	for owner_id_value: Variant in _publishers.keys():
		var owner_id := int(owner_id_value)
		_disconnect_watchers(_publishers[owner_id], owner_id)
	for query_value: Variant in _scoped_queries.values():
		var query: Dictionary = query_value
		_disconnect_watchers(query, int(query.get("ownerInstanceId", 0)))
	_publishers.clear()
	_scoped_queries.clear()
	_advance_owner_cursor = 0


func request_section(publisher: Object, section_key: Vector3i) -> Dictionary:
	if not _publisher_roster_available(publisher):
		return {"status":"pending", "reason":"legacy_visual_index_owner_unavailable",
			"retryable":true}
	var owner_id := publisher.get_instance_id()
	var state: Dictionary = _publishers.get(owner_id, {})
	if state.is_empty():
		state = {"owner":weakref(publisher), "ownerInstanceId":owner_id,
			"seenRoots":{}, "seenNodes":{}, "nodeRootIds":{}, "watchers":{}, "stack":[],
			"entriesBySection":{}, "invalidVisuals":[], "complete":false,
			"visitedCount":0}
		_publishers[owner_id] = state
	_sync_roots(state, publisher)
	if not bool(state.get("complete", false)):
		return {"status":"pending", "reason":"legacy_visual_index_preparing",
			"retryable":true, "indexedNodeCount":int(state.get("visitedCount", 0)),
			"pendingNodeCount":state.stack.size()}
	var live_roots := _live_root_ids(publisher)
	var visuals: Array[GeometryInstance3D] = []
	for invalid_value: Variant in state.get("invalidVisuals", []):
		var invalid_entry: Dictionary = invalid_value
		var invalid_visual := _entry_visual(invalid_entry)
		if _entry_is_current(invalid_entry, invalid_visual, live_roots) \
				and (invalid_visual.visible or _legacy_has_section_ownership(invalid_visual)):
			return {"status":"pending", "reason":"legacy_visual_index_bounds_unavailable",
				"retryable":true, "nodeInstanceId":int(invalid_entry.get("nodeInstanceId", 0))}
	var entries: Array = state.get("entriesBySection", {}).get(section_key, [])
	for entry_value: Variant in entries:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		var visual := _entry_visual(entry)
		if not _entry_is_current(entry, visual, live_roots) \
				or (not visual.visible and not _legacy_has_section_ownership(visual)):
			continue
		var current_bounds := visual.global_transform * visual.get_aabb()
		var indexed_bounds: AABB = entry.get("indexedBounds", AABB())
		if not _bounds_are_finite(current_bounds) or not indexed_bounds.encloses(current_bounds):
			_index_visual(state, visual, int(entry.get("rootInstanceId", 0)))
			return {"status":"pending", "reason":"legacy_visual_index_entry_changed",
				"retryable":true, "nodeInstanceId":visual.get_instance_id()}
		if SectionGrid.keys_intersecting_bounds(current_bounds).has(section_key):
			visuals.append(visual)
	visuals.make_read_only()
	return {"status":"ready", "sectionKey":section_key,
		"visuals":visuals, "indexedNodeCount":int(state.get("visitedCount", 0))}


## Traverse only source roots admitted for this section. The publisher's sealed
## roster prevents an unknown root from being mistaken for an empty result.
func request_section_sources(publisher: Object, section_key: Vector3i,
		source_part_ids: Array, snapshot_only := false) -> Dictionary:
	if not is_instance_valid(publisher) \
			or not publisher.has_method("capture_legacy_visual_roots_for_section"):
		return request_section(publisher, section_key)
	var captured: Dictionary = publisher.call("capture_legacy_visual_roots_for_section",
		section_key, source_part_ids)
	if captured.get("status") != "ready":
		return captured
	var owner_id := publisher.get_instance_id()
	var normalized: Array[String] = []
	for part_value: Variant in captured.get("sourcePartIds", source_part_ids):
		if not part_value is String or String(part_value).is_empty():
			return {"status":"failed", "reason":"invalid_legacy_visual_source_part_id"}
		if String(part_value) not in normalized:
			normalized.append(String(part_value))
	normalized.sort()
	var query_key := var_to_str([owner_id, section_key, normalized])
	var query: Dictionary = _scoped_queries.get(query_key, {})
	var roster_revision := int(captured.get("rosterRevision", -1))
	if query.is_empty() or int(query.get("rosterRevision", -2)) != roster_revision:
		var stack: Array = []
		for root_value: Variant in captured.get("roots", []):
			if not root_value is Dictionary:
				return {"status":"pending", "reason":"legacy_visual_root_record_invalid",
					"retryable":true}
			var root_record: Dictionary = root_value
			var root: Variant = root_record.get("node")
			if not is_instance_valid(root) or not root is Node \
					or (root as Node).get_instance_id() != int(root_record.get("nodeInstanceId", 0)):
				return {"status":"pending", "reason":"legacy_visual_root_identity_stale",
					"retryable":true}
			stack.append({"node":root, "rootInstanceId":(root as Node).get_instance_id()})
		query = {"owner":weakref(publisher), "ownerInstanceId":owner_id,
			"sectionKey":section_key, "sourcePartIds":normalized,
			"queryKey":query_key,
			"rosterRevision":roster_revision,
			"supportRevision":int(captured.get("supportRevision", -1)),
			"supportTransformsByPart":captured.get("supportTransformsByPart", {}),
			"queryRevision":1, "rootInstanceIds":_root_ids(captured.get("roots", [])),
			"stack":stack, "seenNodes":{},
			"nodeRootIds":{}, "watchers":{}, "visuals":[], "invalidVisuals":[],
			"visitedCount":0, "complete":stack.is_empty()}
		_scoped_queries[query_key] = query
	if not bool(query.get("complete", false)):
		return {"status":"pending", "reason":"legacy_visual_section_scope_preparing",
			"retryable":true, "indexedNodeCount":int(query.get("visitedCount", 0)),
			"pendingNodeCount":query.get("stack", []).size()}
	if snapshot_only:
		var entries: Array = query.get("visuals", []).duplicate(false)
		entries.make_read_only()
		var snapshot := {"status":"ready", "publisherInstanceId":owner_id,
			"sectionKey":section_key, "sourcePartIds":normalized,
			"rosterRevision":roster_revision,
			"supportRevision":int(query.get("supportRevision", -1)),
			"queryKey":query_key, "queryRevision":int(query.get("queryRevision", 0)),
			"rootInstanceIds":query.get("rootInstanceIds", {}),
			"supportTransformsByPart":query.get("supportTransformsByPart", {}),
			"entries":entries, "indexedNodeCount":int(query.get("visitedCount", 0))}
		snapshot.make_read_only()
		return snapshot
	var current: Dictionary = publisher.call("capture_legacy_visual_roots_for_section",
		section_key, source_part_ids)
	if current.get("status") != "ready" \
			or int(current.get("rosterRevision", -1)) != roster_revision:
		_scoped_queries.erase(query_key)
		return {"status":"pending", "reason":"legacy_visual_section_scope_roster_changed",
			"retryable":true}
	var live_roots: Dictionary = {}
	for root_value: Variant in current.get("roots", []):
		if root_value is Dictionary:
			live_roots[int(root_value.get("nodeInstanceId", 0))] = true
	var visuals: Array[GeometryInstance3D] = []
	for entry_value: Variant in query.get("visuals", []):
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		var visual := _entry_visual(entry)
		if not _entry_is_current(entry, visual, live_roots) \
				or (not visual.visible and not _legacy_has_section_ownership(visual)):
			continue
		var bounds := visual.global_transform * visual.get_aabb()
		var indexed: AABB = entry.get("indexedBounds", AABB())
		if not _bounds_are_finite(bounds) or not indexed.encloses(bounds):
			_scoped_queries.erase(query_key)
			return {"status":"pending", "reason":"legacy_visual_index_entry_changed",
				"retryable":true, "nodeInstanceId":visual.get_instance_id()}
		if SectionGrid.keys_intersecting_bounds(bounds).has(section_key):
			visuals.append(visual)
	visuals.make_read_only()
	return {"status":"ready", "sectionKey":section_key, "visuals":visuals,
		"indexedNodeCount":int(query.get("visitedCount", 0)),
		"sourceRootCount":captured.get("roots", []).size()}


func validate_section_source_entry(publisher: Object, snapshot: Dictionary,
		entry_index: int, part_id: String) -> Dictionary:
	if not snapshot.is_read_only() or not is_instance_valid(publisher) \
			or publisher.get_instance_id() != int(snapshot.get("publisherInstanceId", 0)) \
			or entry_index < 0 or entry_index >= snapshot.get("entries", []).size():
		return {"status":"pending", "reason":"legacy_visual_snapshot_identity_stale",
			"retryable":true}
	var query: Dictionary = _scoped_queries.get(String(snapshot.get("queryKey", "")), {})
	if query.is_empty() or not bool(query.get("complete", false)) \
			or int(query.get("queryRevision", -1)) != int(snapshot.get("queryRevision", -2)) \
			or int(query.get("rosterRevision", -1)) != int(snapshot.get("rosterRevision", -2)) \
			or int(query.get("supportRevision", -1)) != int(snapshot.get("supportRevision", -2)) \
			or int(publisher.call("published_node_roster_revision")) \
			!= int(snapshot.get("rosterRevision", -1)) \
			or int(publisher.call("published_source_support_revision")) \
			!= int(snapshot.get("supportRevision", -1)):
		return {"status":"pending", "reason":"legacy_visual_snapshot_revision_stale",
			"retryable":true}
	var support: Dictionary = snapshot.get("supportTransformsByPart", {})
	var support_record: Variant = support.get(part_id, null)
	if support_record is Dictionary:
		var parent_ref: Variant = support_record.get("parent")
		var parent: Variant = parent_ref.get_ref() if parent_ref is WeakRef else null
		if not is_instance_valid(parent) or not parent is Node3D \
				or parent.get_instance_id() != int(support_record.get("parentInstanceId", 0)) \
				or (parent as Node3D).global_transform != support_record.get("transform"):
			return {"status":"pending", "reason":"legacy_visual_support_transform_stale",
				"retryable":true, "sourcePartId":part_id}
	var entry: Variant = snapshot.entries[entry_index]
	if not entry is Dictionary:
		return {"status":"pending", "reason":"legacy_visual_snapshot_entry_invalid",
			"retryable":true}
	var visual := _entry_visual(entry)
	var root_id := int(entry.get("rootInstanceId", 0))
	if not is_instance_valid(visual) or visual.get_instance_id() != int(entry.get("nodeInstanceId", 0)) \
			or not visual.is_inside_tree() or visual.is_queued_for_deletion() \
			or not snapshot.get("rootInstanceIds", {}).has(root_id):
		return {"status":"pending", "reason":"legacy_visual_snapshot_node_stale",
			"retryable":true}
	if String(visual.get_meta("building_source_part_id", "")) != part_id:
		return {"status":"skipped", "reason":"legacy_visual_entry_other_source"}
	if not visual.visible and not _legacy_has_section_ownership(visual):
		return {"status":"skipped", "reason":"legacy_visual_entry_not_visible"}
	var bounds := visual.global_transform * visual.get_aabb()
	var indexed: AABB = entry.get("indexedBounds", AABB())
	if not _bounds_are_finite(bounds):
		return {"status":"pending", "reason":"legacy_visual_bounds_unavailable",
			"retryable":true, "nodeInstanceId":visual.get_instance_id()}
	if not indexed.encloses(bounds):
		query["queryRevision"] = int(query.get("queryRevision", 0)) + 1
		_scoped_queries[String(snapshot.get("queryKey", ""))] = query
		return {"status":"pending", "reason":"legacy_visual_bounds_changed",
			"retryable":true, "nodeInstanceId":visual.get_instance_id()}
	return {"status":"ready", "visual":visual, "nodeInstanceId":visual.get_instance_id(),
		"bounds":bounds,
		"intersectsSection":SectionGrid.keys_intersecting_bounds(bounds).has(
			 snapshot.get("sectionKey"))}


static func _root_ids(root_values: Array) -> Dictionary:
	var result := {}
	for root_value: Variant in root_values:
		if root_value is Dictionary:
			result[int(root_value.get("nodeInstanceId", 0))] = true
	result.make_read_only()
	return result


func advance(max_nodes := 96, budget_usec := DEFAULT_ADVANCE_USEC) -> Dictionary:
	if max_nodes < 1 or budget_usec < 1 or budget_usec > MAX_ADVANCE_USEC:
		return {"status":"rejected", "reason":"invalid_legacy_visual_index_budget"}
	var started := Time.get_ticks_usec()
	var remaining := max_nodes
	var visited := 0
	var query_keys: Array = _scoped_queries.keys()
	var owner_ids: Array = _publishers.keys()
	if owner_ids.is_empty() and query_keys.is_empty():
		return {"status":"idle", "visitedNodeCount":0,
			"remainingBudget":remaining, "elapsedUsec":Time.get_ticks_usec() - started}
	var total_owners := owner_ids.size() + query_keys.size()
	var start_owner := posmod(_advance_owner_cursor, total_owners)
	var owners_visited := 0
	while owners_visited < total_owners and remaining > 0 \
			and Time.get_ticks_usec() - started < budget_usec:
		var slot := (start_owner + owners_visited) % total_owners
		var scoped := slot >= owner_ids.size()
		var query_key := String(query_keys[slot - owner_ids.size()]) if scoped else ""
		var state: Dictionary = _scoped_queries.get(query_key, {}) if scoped \
			else _publishers.get(int(owner_ids[slot]), {})
		var owner_id := int(state.get("ownerInstanceId", 0)) if scoped else int(owner_ids[slot])
		var owner_ref: Variant = state.get("owner")
		var publisher_value: Variant = owner_ref.get_ref() if owner_ref is WeakRef else null
		if not is_instance_valid(publisher_value):
			_disconnect_watchers(state, owner_id)
			if scoped: _scoped_queries.erase(query_key)
			else: _publishers.erase(owner_id)
			owners_visited += 1
			continue
		var publisher := publisher_value as Object
		if publisher.get_instance_id() != int(state.get("ownerInstanceId", 0)):
			_disconnect_watchers(state, owner_id)
			if scoped: _scoped_queries.erase(query_key)
			else: _publishers.erase(owner_id)
			owners_visited += 1
			continue
		if not scoped:
			_sync_roots(state, publisher)
		var stack: Array = state.get("stack", [])
		var owner_started := Time.get_ticks_usec()
		while not stack.is_empty() and remaining > 0 \
				and Time.get_ticks_usec() - started < budget_usec \
				and Time.get_ticks_usec() - owner_started < 450:
			var row: Dictionary = stack.pop_back()
			var node_value: Variant = row.get("node")
			if not is_instance_valid(node_value):
				continue
			var node := node_value as Node
			var node_id := node.get_instance_id()
			if state.seenNodes.has(node_id):
				continue
			state.seenNodes[node_id] = true
			state.nodeRootIds[node_id] = int(row.get("rootInstanceId", 0))
			state.visitedCount = int(state.get("visitedCount", 0)) + 1
			remaining -= 1
			visited += 1
			if scoped: _watch_scoped_children(state, node, query_key)
			else: _watch_children(state, publisher, node)
			if bool(node.get_meta("section_attachment_native_root", false)):
				continue
			if node is GeometryInstance3D:
				if scoped:
					var bounds := (node as GeometryInstance3D).global_transform * (node as GeometryInstance3D).get_aabb()
					var indexed_bounds := bounds.grow(3.0) if _has_door_ancestor(node) else bounds
					var visual_entry := {"visual":weakref(node),
						"nodeInstanceId":node_id,
						"rootInstanceId":int(row.get("rootInstanceId", 0)),
						"indexedBounds":indexed_bounds}
					visual_entry.make_read_only()
					state.visuals.append(visual_entry)
				else:
					_index_visual(state, node as GeometryInstance3D,
						int(row.get("rootInstanceId", 0)))
			for child: Node in node.get_children():
				stack.append({"node":child,
					"rootInstanceId":int(row.get("rootInstanceId", 0))})
		state["stack"] = stack
		state["complete"] = stack.is_empty()
		if scoped: _scoped_queries[query_key] = state
		else: _publishers[owner_id] = state
		owners_visited += 1
	_advance_owner_cursor = (start_owner + maxi(owners_visited, 1)) % total_owners
	return {"status":"advanced" if visited > 0 else "idle",
		"visitedNodeCount":visited, "remainingBudget":remaining,
		"elapsedUsec":Time.get_ticks_usec() - started}


func stats() -> Dictionary:
	var complete := 0
	var visited := 0
	var pending := 0
	var largest_pending := 0
	var sample: Array[Dictionary] = []
	for owner_id_value: Variant in _publishers:
		var owner_id := int(owner_id_value)
		var state: Dictionary = _publishers[owner_id]
		var stack_size := int(state.get("stack", []).size())
		visited += int(state.get("visitedCount", 0))
		pending += stack_size
		largest_pending = maxi(largest_pending, stack_size)
		if bool(state.get("complete", false)):
			complete += 1
		elif sample.size() < 4:
			sample.append({"ownerInstanceId":owner_id,
				"indexedNodeCount":int(state.get("visitedCount", 0)),
				"pendingNodeCount":stack_size})
	return {"scopedQueryCount":_scoped_queries.size(),
		"completeScopedQueryCount":_count_complete_scoped_queries(),
		"ownerCount":_publishers.size(), "completeOwnerCount":complete,
		"indexedNodeCount":visited, "pendingNodeCount":pending,
		"largestPendingOwnerNodeCount":largest_pending, "pendingSample":sample}


func _count_complete_scoped_queries() -> int:
	var count := 0
	for query_value: Variant in _scoped_queries.values():
		if bool(query_value.get("complete", false)):
			count += 1
	return count


func _disconnect_watchers(state: Dictionary, owner_id: int) -> void:
	for node_id_value: Variant in state.get("watchers", {}).keys():
		var node_value: Variant = instance_from_id(int(node_id_value))
		if not is_instance_valid(node_value):
			continue
		var node := node_value as Node
		var query_key := String(state.get("queryKey", ""))
		var callback := Callable(self, "_on_scoped_child_entered").bind(query_key,
			node.get_instance_id()) if not query_key.is_empty() else \
			Callable(self, "_on_child_entered").bind(owner_id, node.get_instance_id())
		if node.child_entered_tree.is_connected(callback):
			node.child_entered_tree.disconnect(callback)


func _sync_roots(state: Dictionary, publisher: Object) -> void:
	var roots: Array = _publisher_roster_snapshot(publisher)
	for root_value: Variant in roots:
		if not is_instance_valid(root_value) or not root_value is Node:
			continue
		var root: Node = root_value
		var root_id := root.get_instance_id()
		if state.seenRoots.has(root_id):
			continue
		state.seenRoots[root_id] = true
		state.stack.append({"node":root, "rootInstanceId":root_id})
		state["complete"] = false


func _watch_children(state: Dictionary, publisher: Object, node: Node) -> void:
	var node_id := node.get_instance_id()
	if state.watchers.has(node_id):
		return
	state.watchers[node_id] = true
	var callback := Callable(self, "_on_child_entered").bind(
		int(state.get("ownerInstanceId", 0)), node_id)
	if not node.child_entered_tree.is_connected(callback):
		node.child_entered_tree.connect(callback)


func _on_child_entered(child: Node, owner_id: int, parent_id: int) -> void:
	var state: Dictionary = _publishers.get(owner_id, {})
	if state.is_empty() or not is_instance_valid(child):
		return
	var parent: Node = instance_from_id(parent_id) as Node
	if not is_instance_valid(parent):
		return
	var root_id := int(state.get("nodeRootIds", {}).get(parent_id, 0))
	state.stack.append({"node":child, "rootInstanceId":root_id})
	state["complete"] = false
	_publishers[owner_id] = state


func _watch_scoped_children(state: Dictionary, node: Node, query_key: String) -> void:
	var node_id := node.get_instance_id()
	if state.watchers.has(node_id):
		return
	state.watchers[node_id] = true
	var callback := Callable(self, "_on_scoped_child_entered").bind(query_key, node_id)
	if not node.child_entered_tree.is_connected(callback):
		node.child_entered_tree.connect(callback)


func _on_scoped_child_entered(child: Node, query_key: String, parent_id: int) -> void:
	var state: Dictionary = _scoped_queries.get(query_key, {})
	if state.is_empty() or not is_instance_valid(child):
		return
	var parent := instance_from_id(parent_id) as Node
	if not is_instance_valid(parent):
		return
	var root_id := int(state.get("nodeRootIds", {}).get(parent_id, 0))
	state.stack.append({"node":child, "rootInstanceId":root_id})
	state.complete = false
	state.queryRevision = int(state.get("queryRevision", 0)) + 1
	_scoped_queries[query_key] = state


func _index_visual(state: Dictionary, visual: GeometryInstance3D,
		root_instance_id: int) -> void:
	var bounds := visual.global_transform * visual.get_aabb()
	var entry := {"visual":weakref(visual), "nodeInstanceId":visual.get_instance_id(),
		"rootInstanceId":root_instance_id, "indexedBounds":bounds}
	if not _bounds_are_finite(bounds):
		state.invalidVisuals.append(entry)
		return
	# Door leaves can swing within their declared owner, so reserve a small
	# conservative envelope and still check their live AABB on every ACK.
	var indexed_bounds := bounds.grow(3.0) if _has_door_ancestor(visual) else bounds
	entry["indexedBounds"] = indexed_bounds
	var sections: Array[Vector3i] = SectionGrid.keys_intersecting_bounds(indexed_bounds)
	if sections.is_empty() or sections.size() > 256:
		state.invalidVisuals.append(entry)
		return
	for section_key: Vector3i in sections:
		if not state.entriesBySection.has(section_key):
			state.entriesBySection[section_key] = []
		state.entriesBySection[section_key].append(entry)


func _has_door_ancestor(node: Node) -> bool:
	var cursor := node
	while is_instance_valid(cursor):
		if String(cursor.get_meta("building_part_kind", "")) == "door":
			return true
		cursor = cursor.get_parent()
	return false


func _live_root_ids(publisher: Object) -> Dictionary:
	var result := {}
	for value: Variant in _publisher_roster_snapshot(publisher):
		if is_instance_valid(value) and value is Node:
			result[(value as Node).get_instance_id()] = true
	return result


static func _publisher_roster_available(publisher: Object) -> bool:
	return is_instance_valid(publisher) \
		and (publisher.has_method("published_node_roster_snapshot") \
			or publisher.get("published_parts") is Array)


static func _publisher_roster_snapshot(publisher: Object) -> Array:
	if not is_instance_valid(publisher): return []
	if publisher.has_method("published_node_roster_snapshot"):
		return publisher.call("published_node_roster_snapshot")
	var parts: Variant = publisher.get("published_parts")
	if not parts is Array: return []
	var snapshot: Array = parts.duplicate()
	snapshot.make_read_only()
	return snapshot


static func _entry_visual(entry: Dictionary) -> GeometryInstance3D:
	var reference: Variant = entry.get("visual")
	var visual: Object = reference.get_ref() if reference is WeakRef else null
	return visual as GeometryInstance3D if is_instance_valid(visual) else null


static func _entry_is_current(entry: Dictionary, visual: GeometryInstance3D,
		live_roots: Dictionary) -> bool:
	if not is_instance_valid(visual) or visual.get_instance_id() != int(entry.get("nodeInstanceId", 0)) \
			or not visual.is_inside_tree() or visual.is_queued_for_deletion():
		return false
	var root_id := int(entry.get("rootInstanceId", 0))
	return root_id > 0 and live_roots.has(root_id)


static func _bounds_are_finite(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0


static func _legacy_has_section_ownership(visual: GeometryInstance3D) -> bool:
	return bool(visual.get_meta("citadel_section_owned", false))
