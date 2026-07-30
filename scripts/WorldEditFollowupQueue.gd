extends RefCounted
class_name WorldEditFollowupQueue

const STRUCTURE_OFFSETS := [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1)
]

var main
var pending_edits: Array[Dictionary] = []
var pending_rewards: Array[Dictionary] = []
var pending_terrain_edits: Array[Dictionary] = []
var pending_terrain_keys := {}
var active_terrain_edit := {}
var active_light_state := {}
var structure_seed_cells: Array[Vector3i] = []
var structure_visited := {}
var structure_scan_cells: Array[Vector3i] = []
var structure_component: Array[Vector3i] = []
var structure_collapse_cells: Array[Vector3i] = []
var structure_phase := "idle"
var structure_base_bottom := INF
var structure_verify_index := 0
var structure_collapsed_count := 0
var structure_collapsed_center := Vector3.ZERO
var peak_enqueue_ms := 0.0
var peak_process_ms := 0.0
var peak_state_sync_ms := 0.0
var peak_light_begin_ms := 0.0
var peak_reward_unit_ms := 0.0
var peak_reward_item_ms := 0.0
var peak_reward_xp_ms := 0.0
var peak_reward_objective_ms := 0.0
var total_enqueued := 0
var total_completed := 0

func setup(main_node) -> void:
	main = main_node

func reset() -> void:
	pending_edits.clear()
	pending_rewards.clear()
	pending_terrain_edits.clear()
	pending_terrain_keys.clear()
	active_terrain_edit.clear()
	active_light_state.clear()
	structure_seed_cells.clear()
	structure_visited.clear()
	structure_scan_cells.clear()
	structure_component.clear()
	structure_collapse_cells.clear()
	structure_phase = "idle"
	structure_base_bottom = INF
	structure_verify_index = 0
	structure_collapsed_count = 0
	structure_collapsed_center = Vector3.ZERO

func enqueue_block_created(cell: Vector3i, block_type: String, block: Node, options: Dictionary = {}) -> void:
	var started_usec := Time.get_ticks_usec()
	pending_edits.append({
		"operation": "create",
		"cell": cell,
		"blockType": block_type,
		"block": block,
		"options": options.duplicate(true),
		"stateSynced": false
	})
	total_enqueued += 1
	peak_enqueue_ms = maxf(peak_enqueue_ms, float(Time.get_ticks_usec() - started_usec) / 1000.0)

func enqueue_block_removed(cell: Vector3i, block_type: String, state_synced := true, reason := "block_removed") -> void:
	var started_usec := Time.get_ticks_usec()
	pending_edits.append({
		"operation": "remove",
		"cell": cell,
		"blockType": block_type,
		"stateSynced": state_synced,
		"reason": reason
	})
	total_enqueued += 1
	peak_enqueue_ms = maxf(peak_enqueue_ms, float(Time.get_ticks_usec() - started_usec) / 1000.0)

func enqueue_reward(items: Array, xp_material := "", objective_material := "") -> void:
	var normalized_items: Array[Dictionary] = []
	for item_value in items:
		if not (item_value is Dictionary):
			continue
		var item: Dictionary = item_value
		var item_id := String(item.get("item", ""))
		var count := int(item.get("count", 0))
		if item_id != "" and count > 0:
			normalized_items.append({ "item": item_id, "count": count })
	pending_rewards.append({
		"items": normalized_items,
		"itemIndex": 0,
		"xpMaterial": String(xp_material),
		"objectiveMaterial": String(objective_material),
		"phase": "items"
	})

func enqueue_terrain_excavation(hit: Dictionary, collider: Node, fallback_material: String, target_id := "") -> bool:
	var started_usec := Time.get_ticks_usec()
	var key := String(target_id)
	if key == "":
		var position: Vector3 = hit.get("position", Vector3.ZERO)
		key = "terrain:%.3f,%.3f,%.3f" % [position.x, position.y, position.z]
	if pending_terrain_keys.has(key):
		return false
	pending_terrain_keys[key] = true
	pending_terrain_edits.append({
		"key": key,
		"hit": hit.duplicate(true),
		"collider": collider,
		"fallbackMaterial": fallback_material,
		"state": {}
	})
	total_enqueued += 1
	peak_enqueue_ms = maxf(peak_enqueue_ms, float(Time.get_ticks_usec() - started_usec) / 1000.0)
	return true

func request_structure_check(removed_cell: Vector3i) -> void:
	if structure_phase == "idle" and structure_seed_cells.is_empty():
		structure_visited.clear()
		structure_collapsed_count = 0
		structure_collapsed_center = Vector3.ZERO
	for offset in STRUCTURE_OFFSETS:
		var neighbor_cell: Vector3i = removed_cell + (offset as Vector3i)
		if not structure_seed_cells.has(neighbor_cell):
			structure_seed_cells.append(neighbor_cell)
	if structure_phase == "idle":
		structure_phase = "seed"

func process(frame_budget_ms := 0.5, max_work_units := 96) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var work_limit := maxi(1, max_work_units)
	var processed_work_units := 0
	var budget_usec := 0 if frame_budget_ms <= 0.0 else maxi(1, roundi(frame_budget_ms * 1000.0))
	if active_terrain_edit.is_empty() and not pending_terrain_edits.is_empty():
		active_terrain_edit = pending_terrain_edits.pop_front()
		begin_active_terrain_edit()
	if not active_terrain_edit.is_empty() and within_budget(started_usec, budget_usec):
		var remaining_ms := remaining_budget_ms(started_usec, budget_usec, frame_budget_ms)
		var terrain_state_value: Variant = active_terrain_edit.get("state", {})
		var terrain_state: Dictionary = terrain_state_value if terrain_state_value is Dictionary else {}
		var advanced: Dictionary = main.subsurface_system.advance_excavation(terrain_state, remaining_ms, min(8, work_limit))
		var next_state_value: Variant = advanced.get("state", terrain_state)
		active_terrain_edit["state"] = next_state_value if next_state_value is Dictionary else terrain_state
		processed_work_units += int(advanced.get("processedWorkUnits", 0))
		if bool(advanced.get("complete", false)):
			var result_value: Variant = advanced.get("result", {})
			var result: Dictionary = result_value if result_value is Dictionary else {}
			main.complete_terrain_excavation_followup(result, String(active_terrain_edit.get("fallbackMaterial", "")))
			pending_terrain_keys.erase(String(active_terrain_edit.get("key", "")))
			active_terrain_edit.clear()
			total_completed += 1
	if not pending_rewards.is_empty() and within_budget(started_usec, budget_usec):
		var reward_started_usec := Time.get_ticks_usec()
		process_reward_unit()
		peak_reward_unit_ms = maxf(peak_reward_unit_ms, float(Time.get_ticks_usec() - reward_started_usec) / 1000.0)
		processed_work_units += 1
	if not active_light_state.is_empty():
		var remaining_ms := remaining_budget_ms(started_usec, budget_usec, frame_budget_ms)
		var advanced: Dictionary = main.world_generation_system.call("advance_cell_light_update", active_light_state, remaining_ms, work_limit)
		var next_state_value: Variant = advanced.get("state", active_light_state)
		active_light_state = next_state_value if next_state_value is Dictionary else {}
		processed_work_units += int(advanced.get("processedWorkUnits", 0))
		if bool(advanced.get("complete", false)):
			active_light_state.clear()
			total_completed += 1
	if active_light_state.is_empty() and not pending_edits.is_empty() and within_budget(started_usec, budget_usec):
		var edit: Dictionary = pending_edits.pop_front()
		var state_sync_started_usec := Time.get_ticks_usec()
		apply_edit_state(edit)
		peak_state_sync_ms = maxf(peak_state_sync_ms, float(Time.get_ticks_usec() - state_sync_started_usec) / 1000.0)
		processed_work_units += 1
		var light_begin_started_usec := Time.get_ticks_usec()
		begin_edit_light_update(edit)
		peak_light_begin_ms = maxf(peak_light_begin_ms, float(Time.get_ticks_usec() - light_begin_started_usec) / 1000.0)
	while processed_work_units < work_limit and structure_phase != "idle" and within_budget(started_usec, budget_usec):
		process_structure_unit()
		processed_work_units += 1
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	peak_process_ms = maxf(peak_process_ms, elapsed_ms)
	return {
		"processedWorkUnits": processed_work_units,
		"elapsedMs": elapsed_ms,
		"pendingEdits": pending_edit_count(),
		"structurePending": structure_phase != "idle"
	}

func begin_active_terrain_edit() -> void:
	if main == null or main.subsurface_system == null or not main.subsurface_system.has_method("begin_excavation_from_hit"):
		pending_terrain_keys.erase(String(active_terrain_edit.get("key", "")))
		active_terrain_edit.clear()
		return
	var hit_value: Variant = active_terrain_edit.get("hit", {})
	var hit: Dictionary = hit_value if hit_value is Dictionary else {}
	var collider_value: Variant = active_terrain_edit.get("collider")
	var collider := collider_value as Node
	active_terrain_edit["state"] = main.subsurface_system.begin_excavation_from_hit(hit, collider)

func pending_edit_count() -> int:
	return pending_edits.size() + pending_rewards.size() + pending_terrain_edits.size() \
		+ (0 if active_light_state.is_empty() else 1) + (0 if active_terrain_edit.is_empty() else 1)

func process_reward_unit() -> void:
	if pending_rewards.is_empty():
		return
	var reward: Dictionary = pending_rewards[0]
	var phase := String(reward.get("phase", "items"))
	if phase == "items":
		var items_value: Variant = reward.get("items", [])
		var items: Array = items_value if items_value is Array else []
		var item_index := int(reward.get("itemIndex", 0))
		if item_index < items.size():
			var item_value: Variant = items[item_index]
			reward["itemIndex"] = item_index + 1
			if item_value is Dictionary and main != null and main.inventory_system != null:
				var item_started_usec := Time.get_ticks_usec()
				var item: Dictionary = item_value
				main.inventory_system.add_item(String(item.get("item", "")), int(item.get("count", 0)))
				peak_reward_item_ms = maxf(peak_reward_item_ms, float(Time.get_ticks_usec() - item_started_usec) / 1000.0)
				pending_rewards[0] = reward
				return
		reward["phase"] = "xp"
		pending_rewards[0] = reward
		return
	if phase == "xp":
		var xp_material := String(reward.get("xpMaterial", ""))
		if xp_material != "" and main != null:
			var xp_started_usec := Time.get_ticks_usec()
			main.award_break_xp(xp_material)
			peak_reward_xp_ms = maxf(peak_reward_xp_ms, float(Time.get_ticks_usec() - xp_started_usec) / 1000.0)
		reward["phase"] = "objectives"
		pending_rewards[0] = reward
		return
	var objective_material := String(reward.get("objectiveMaterial", ""))
	if objective_material != "" and main != null:
		var objective_started_usec := Time.get_ticks_usec()
		main.complete_break_objectives(objective_material)
		peak_reward_objective_ms = maxf(peak_reward_objective_ms, float(Time.get_ticks_usec() - objective_started_usec) / 1000.0)
	pending_rewards.pop_front()

func apply_edit_state(edit: Dictionary) -> void:
	if main == null:
		return
	var operation := String(edit.get("operation", ""))
	var cell: Vector3i = edit.get("cell", Vector3i.ZERO)
	var block_type := String(edit.get("blockType", ""))
	if operation == "create":
		var block_value: Variant = edit.get("block")
		var block := block_value as Node
		if block == null or not is_instance_valid(block) or main.blocks.get(cell) != block:
			edit["cancelled"] = true
			return
		var options_value: Variant = edit.get("options", {})
		var options: Dictionary = options_value if options_value is Dictionary else {}
		main.sync_block_state_to_terrain(cell, block_type, options)
		block.set_meta("terrain_state_synced", true)
		edit["stateSynced"] = true
		return
	if operation == "remove" and bool(edit.get("stateSynced", true)):
		main.clear_block_state_from_terrain(cell, block_type, String(edit.get("reason", "block_removed")))

func begin_edit_light_update(edit: Dictionary) -> void:
	if main == null or bool(edit.get("cancelled", false)):
		total_completed += 1
		return
	var world_generation = main.world_generation_system
	if world_generation == null or not world_generation.has_method("begin_cell_light_update"):
		total_completed += 1
		return
	var operation := String(edit.get("operation", ""))
	var cell: Vector3i = edit.get("cell", Vector3i.ZERO)
	var block_type := String(edit.get("blockType", ""))
	var source_level := int(main.terrain_block_light_level(block_type))
	if source_level <= 0:
		total_completed += 1
		return
	var level: int = source_level if operation == "create" else 0
	var reason: String = "block_light_created:%s" % block_type if operation == "create" else "%s:%s" % [String(edit.get("reason", "block_removed")), block_type]
	var state_value: Variant = world_generation.call("begin_cell_light_update", cell, { "sky": 0, "block": level }, reason, 0)
	active_light_state = state_value if state_value is Dictionary else {}
	if active_light_state.is_empty() or bool(active_light_state.get("complete", false)):
		active_light_state.clear()
		total_completed += 1

func process_structure_unit() -> void:
	if main == null:
		finish_structure_check()
		return
	if structure_phase == "collapse":
		if structure_collapse_cells.is_empty():
			reset_structure_component()
			return
		var collapse_cell: Vector3i = structure_collapse_cells.pop_back()
		var block_value: Variant = main.blocks.get(collapse_cell)
		var block := block_value as Node3D
		if block != null and is_instance_valid(block):
			structure_collapsed_center += block.global_position
			if bool(main.collapse_structure_block_deferred(block)):
				structure_collapsed_count += 1
		return
	if structure_phase == "verify":
		if structure_verify_index >= structure_component.size():
			reset_structure_component()
			return
		var verify_cell := structure_component[structure_verify_index]
		structure_verify_index += 1
		var verify_value: Variant = main.blocks.get(verify_cell)
		var verify_block := verify_value as Node3D
		if verify_block == null or not is_instance_valid(verify_block):
			return
		var block_type := String(verify_block.get_meta("block_type", ""))
		if main.is_structural_block_type(block_type) and main.block_bottom_y(verify_block) <= structure_base_bottom + main.CELL * 0.18 and not main.block_touches_terrain(verify_block):
			structure_collapse_cells = structure_component.duplicate()
			structure_phase = "collapse"
		return
	if structure_phase == "scan":
		if structure_scan_cells.is_empty():
			if structure_component.is_empty() or structure_base_bottom == INF:
				reset_structure_component()
			else:
				structure_verify_index = 0
				structure_phase = "verify"
			return
		var scan_cell: Vector3i = structure_scan_cells.pop_back()
		var scan_value: Variant = main.blocks.get(scan_cell)
		var scan_block := scan_value as Node3D
		if scan_block == null or not is_instance_valid(scan_block):
			return
		structure_component.append(scan_cell)
		var scan_type := String(scan_block.get_meta("block_type", ""))
		if main.is_structural_block_type(scan_type):
			structure_base_bottom = minf(structure_base_bottom, main.block_bottom_y(scan_block))
		for offset in STRUCTURE_OFFSETS:
			var neighbor_cell: Vector3i = scan_cell + (offset as Vector3i)
			if structure_visited.has(neighbor_cell) or not main.blocks.has(neighbor_cell):
				continue
			structure_visited[neighbor_cell] = true
			structure_scan_cells.append(neighbor_cell)
		return
	if structure_seed_cells.is_empty():
		finish_structure_check()
		return
	var seed_cell: Vector3i = structure_seed_cells.pop_back()
	if structure_visited.has(seed_cell) or not main.blocks.has(seed_cell):
		return
	structure_visited[seed_cell] = true
	structure_scan_cells = [seed_cell]
	structure_component.clear()
	structure_base_bottom = INF
	structure_phase = "scan"

func reset_structure_component() -> void:
	structure_scan_cells.clear()
	structure_component.clear()
	structure_collapse_cells.clear()
	structure_base_bottom = INF
	structure_verify_index = 0
	structure_phase = "seed"

func finish_structure_check() -> void:
	if structure_collapsed_count > 0:
		main.finalize_deferred_structure_collapse(structure_collapsed_count, structure_collapsed_center)
	structure_seed_cells.clear()
	structure_visited.clear()
	structure_scan_cells.clear()
	structure_component.clear()
	structure_collapse_cells.clear()
	structure_phase = "idle"
	structure_collapsed_count = 0
	structure_collapsed_center = Vector3.ZERO

func within_budget(started_usec: int, budget_usec: int) -> bool:
	return budget_usec <= 0 or Time.get_ticks_usec() - started_usec < budget_usec

func remaining_budget_ms(started_usec: int, budget_usec: int, fallback_ms: float) -> float:
	if budget_usec <= 0:
		return fallback_ms
	return maxf(0.01, float(budget_usec - (Time.get_ticks_usec() - started_usec)) / 1000.0)

func stats() -> Dictionary:
	return {
		"pendingEdits": pending_edit_count(),
		"pendingTerrainEdits": pending_terrain_edits.size() + (0 if active_terrain_edit.is_empty() else 1),
		"structurePending": structure_phase != "idle",
		"peakEnqueueMs": peak_enqueue_ms,
		"peakProcessMs": peak_process_ms,
		"peakStateSyncMs": peak_state_sync_ms,
		"peakLightBeginMs": peak_light_begin_ms,
		"peakRewardUnitMs": peak_reward_unit_ms,
		"peakRewardItemMs": peak_reward_item_ms,
		"peakRewardXpMs": peak_reward_xp_ms,
		"peakRewardObjectiveMs": peak_reward_objective_ms,
		"totalEnqueued": total_enqueued,
		"totalCompleted": total_completed
	}
