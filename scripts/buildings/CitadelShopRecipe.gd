extends RefCounted

## Shared source-only shop composition. Call on an owned loading worker.
## All work is private until ready: the input blueprint is never changed.
## Producers/planners are supplied by the owning citadel grammar, avoiding a
## dependency cycle or a testing/frozen-source authority. No publication here.
const FrozenBlueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const TerminalFrame = preload("res://scripts/buildings/TerminalShopFrameBuilder.gd")
const TerminalElevation = preload("res://scripts/buildings/TerminalShopElevationRecipe.gd")
const TerminalGoods = preload("res://scripts/buildings/TerminalShopGoodsPlacementRecipe.gd")
const Batch = preload("res://scripts/buildings/HouseholdLayoutBatchRecipe.gd")
const CanopyFrame = preload("res://scripts/buildings/MarketCanopyFrameBuilder.gd")
const StorageRecipe = preload("res://scripts/buildings/MarketStoragePlacementRecipe.gd")

static func prepare(source_b, furnishing_obstacles: Array, market_producer: Callable, terminal_producer: Callable, market_planner: Callable, terminal_planner: Callable, include_canopy_frames := true) -> Dictionary:
	if source_b == null or source_b.parts.size() > 10000 or furnishing_obstacles.size() > 4096:
		return {"ready": false, "reason": "invalid_or_oversized_shop_source"}
	for operation in [market_producer, terminal_producer, market_planner, terminal_planner]:
		if not operation.is_valid(): return {"ready": false, "reason": "invalid_grammar_operation"}
	for obstacle in furnishing_obstacles:
		if not obstacle is Dictionary or not obstacle.get("bounds") is AABB:
			return {"ready": false, "reason": "invalid_furnishing_obstacle"}
		var volume: AABB = obstacle.bounds
		if not volume.position.is_finite() or not volume.end.is_finite() or volume.size.x <= 0 or volume.size.y <= 0 or volume.size.z <= 0:
			return {"ready": false, "reason": "invalid_furnishing_obstacle"}
	var started := Time.get_ticks_usec()
	var source: Dictionary = source_b.snapshot()
	var b = copy_source(source)
	var specs: Array = b.recipe.get("urbanPoc", {}).get("marketStalls", [])
	if specs.is_empty() or specs.size() > Batch.MAX_HOUSEHOLDS:
		return {"ready": false, "reason": "invalid_household_specs"}
	var ids: Array = []
	var members: Dictionary = {}
	var households: Array = []
	var storage_layouts: Array = []
	for spec in specs:
		var variation := float(int(source.seed) % 19) / 100.0 - 0.09 + float(spec.get("variation", 0.0))
		var scratch = FrozenBlueprint.new("household_membership_only", int(source.seed), String(source.style))
		market_producer.call(scratch, Vector3.ZERO, float(spec.side), float(spec.depth), variation)
		var group_ids: Array = []
		var front := Vector3(0, 0, -float(spec.depth))
		for expected in scratch.parts:
			if not b.physical_parts_by_id.has(expected.id) or members.has(expected.id):
				return {"ready": false, "reason": "producer_membership_mismatch", "partId": expected.id}
			ids.append(expected.id)
			group_ids.append(expected.id)
			members[expected.id] = front
		households.append({"memberIds": group_ids, "front": front})
		if include_canopy_frames:
			var storage: Dictionary = StorageRecipe.place(b, group_ids, front)
			storage_layouts.append(storage)
			if not storage.ready:
				return {"ready": false, "reason": "storage_recipe_failed", "storage": storage}
	if ids.is_empty():
		return {"ready": false, "reason": "empty_producer_household"}
	# The mobile market cohort is positioned first. Terminal placement then
	# sees its actual final positions, never exclusions for obsolete canopies.
	# All later frame additions still require complete publisher clearance.
	var framed_source: Dictionary = b.snapshot()
	var original_bytes := var_to_bytes(b.snapshot())
	var furnishing_reservations: Array[Rect2] = []
	for obstacle in furnishing_obstacles:
		var bounds: AABB = obstacle.bounds
		furnishing_reservations.append(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z)))
	var plan: Dictionary = Batch.plan(b, households, market_planner, furnishing_reservations)
	if original_bytes != var_to_bytes(b.snapshot()):
		return {"ready": false, "reason": "shared_planner_mutated_source"}
	if not bool(plan.get("ready", false)):
		return {"ready": false, "reason": "shared_recipe_has_no_placement", "plan": plan}
	var changes: Array = []
	for placement in plan.households:
		var rigid: Transform3D = placement.transform
		placement["frontAfter"] = rigid.basis * (members[placement.memberIds[0]] as Vector3)
		for id in placement.memberIds:
			var part = b.find_part(id)
			var before: Transform3D = b.part_transform(part)
			var after := rigid * before
			part.position = after.origin
			part.rotation = after.basis.get_euler()
			changes.append({"partId": part.id, "before": before, "after": b.part_transform(part)})
	# No additions, pruning, furnishing regeneration or metadata corrections.
	# Verify every untouched field before publisher-derived validation caches.
	var preserved := true
	for index in range(framed_source.parts.size()):
		var old: Dictionary = framed_source.parts[index].duplicate(true)
		var current: Dictionary = b.parts[index].snapshot()
		if members.has(old.id):
			for key in ["position", "rotation"]:
				old.erase(key)
				current.erase(key)
		preserved = preserved and var_to_bytes(old) == var_to_bytes(current)
	preserved = preserved and var_to_bytes(b.recipe) == var_to_bytes(source.recipe) and var_to_bytes(b.rooms) == var_to_bytes(source.rooms)
	if not preserved:
		return {"ready": false, "reason": "source_preservation_failed"}
	var household_records: Dictionary = {}
	for id in ids:
		household_records[id] = var_to_bytes(b.find_part(id).snapshot())
	var terminal_variation := float(int(source.seed) % 19) / 100.0 - 0.09
	var terminals := prepare_terminal_frames(b, terminal_variation, furnishing_obstacles, plan.households, terminal_producer, terminal_planner)
	if not bool(terminals.get("ready", false)):
		var layout: Dictionary = terminals.get("layout", {}) as Dictionary
		if String(terminals.get("reason", "")) == "terminal_public_paving_unavailable" and String(layout.get("reason", "")) == "no_recipe_placement":
			var omission := omit_unplaceable_terminal_household(b, terminal_variation, terminal_producer)
			if not bool(omission.get("ready", false)):
				return {"ready": false, "reason": "terminal_omission_failed", "terminals": terminals, "omission": omission}
			terminals = {"ready": true, "omitted": true, "reason": "no_legal_public_paving", "layout": layout, "omission": omission}
		else:
			return {"ready": false, "reason": "terminal_recipe_failed", "terminals": terminals}
	for id in ids:
		if household_records[id] != var_to_bytes(b.find_part(id).snapshot()):
			return {"ready": false, "reason": "terminal_changed_household", "partId": id}
	var canopies: Array = []
	if include_canopy_frames:
		var builder: Script = CanopyFrame
		if not builder.has_method("add_frame_on_grounded_support"):
			return {"ready": false, "reason": "missing_grounded_canopy_recipe"}
		for placement in plan.households:
			var frame: Dictionary = builder.call("add_frame_on_grounded_support", b, placement.memberIds, placement.supportId)
			if not frame.get("ready", false):
				return {"ready": false, "reason": "canopy_recipe_failed", "frame": frame}
			# Provisional layout must cover EVERY added frame member in XZ.
			# Below-paving post depth is not access proof; retain it for contact
			# evidence, but never enlarge the accepted horizontal envelope here.
			for part in b.parts:
				if not frame.partIds.has(part.id):
					continue
				var bounds: AABB = b.transformed_part_bounds(part)
				var footprint := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
				if not (placement.footprint as Rect2).encloses(footprint):
					return {"ready": false, "reason": "canopy_exceeds_planned_footprint", "partId": part.id}
			placement["originalMemberIds"] = placement.memberIds.duplicate()
			placement["memberIds"] = frame.memberIds
			ids.append_array(frame.partIds)
			canopies.append(frame)
	b.physical_parts_by_id.clear()
	for part in b.parts:
		if b.physical_parts_by_id.has(part.id):
			return {"ready": false, "reason": "duplicate_composed_part"}
		b.physical_parts_by_id[part.id] = part

	return {"ready": true, "blueprint": b, "memberIds": ids,
		"plans": plan.households, "batchPlan": plan, "changes": changes,
		"householdOnlySourceFieldsPreservedBeforeCanopyJoints": preserved, "terminals": terminals,
		"canopies": canopies, "includesCanopyFrames": include_canopy_frames,
		"storageLayouts": storage_layouts, "preparationUsec": Time.get_ticks_usec() - started}


static func omit_unplaceable_terminal_household(blueprint, variation: float, terminal_producer: Callable) -> Dictionary:
	var scratch = FrozenBlueprint.new("terminal_omission_membership", blueprint.seed, blueprint.style)
	terminal_producer.call(scratch, Vector3.ZERO, variation)
	if scratch.parts.is_empty():
		return {"ready": false, "reason": "empty_terminal_membership"}
	var member_ids := {}
	for part in scratch.parts:
		if part == null or String(part.id).is_empty() or member_ids.has(String(part.id)):
			return {"ready": false, "reason": "invalid_terminal_membership"}
		member_ids[String(part.id)] = true
	# The optional row now owns a same-grade building foundation. If the whole
	# shop cannot be legally placed, remove that foundation with the shop rather
	# than leaving a purposeless civic slab behind.
	var foundation_count := 0
	for part in blueprint.parts:
		if part != null and String(part.semantic) == "citadel_terminal_shop_foundation":
			foundation_count += 1
			member_ids[String(part.id)] = true
	if foundation_count != 1:
		return {"ready": false, "reason": "terminal_foundation_membership_invalid", "foundationCount": foundation_count}
	var removed: Array[String] = []
	for index in range(blueprint.parts.size() - 1, -1, -1):
		var part = blueprint.parts[index]
		if part != null and member_ids.has(String(part.id)):
			removed.append(String(part.id))
			blueprint.parts.remove_at(index)
	for member_id in member_ids:
		blueprint.physical_parts_by_id.erase(String(member_id))
	removed.sort()
	if removed.size() != member_ids.size():
		return {"ready": false, "reason": "terminal_membership_missing", "expected": member_ids.keys(), "removed": removed}
	return {"ready": true, "removedPartIds": removed, "policy": "omit_complete_optional_household_when_generated_public_space_has_no_legal_footprint"}


static func copy_source(source: Dictionary):
	var b = FrozenBlueprint.new(source.id, source.seed, source.style)
	b.recipe = source.recipe.duplicate(true)
	b.rooms = source.rooms.duplicate(true)
	for record in source.parts:
		var part = b.add_part(record)
		part.physical_intent = record.physicalIntent
		b.physical_parts_by_id[part.id] = part
	return b


static func furnishing_obstacles(snapshot: Dictionary, protected_reservations: Array) -> Dictionary:
	if not snapshot.get("parts") is Array or snapshot.parts.size() + protected_reservations.size() > 4096:
		return {"ready": false, "reason": "invalid_furnishing_collection"}
	var obstacles: Array = []
	for record in snapshot.parts:
		if not record is Dictionary or not record.get("position") is Vector3 or not record.get("rotation") is Vector3 or not record.get("occupiedSize") is Vector3 or not record.get("id") is String:
			return {"ready": false, "reason": "invalid_furnishing_record"}
		var size: Vector3 = record.occupiedSize
		if not record.position.is_finite() or not record.rotation.is_finite() or not size.is_finite() or size.x <= 0 or size.y <= 0 or size.z <= 0:
			return {"ready": false, "reason": "invalid_furnishing_geometry"}
		var transform := Transform3D(Basis.from_euler(record.rotation), record.position)
		var bounds: AABB = transform * AABB(Vector3(-size.x * 0.5, 0, -size.z * 0.5), size)
		obstacles.append({"id": "furnishing:" + String(record.id), "bounds": bounds})
	for index in range(protected_reservations.size()):
		var volume: Variant = protected_reservations[index]
		if not volume is AABB or not volume.position.is_finite() or not volume.end.is_finite() or volume.size.x <= 0 or volume.size.y <= 0 or volume.size.z <= 0:
			return {"ready": false, "reason": "invalid_furnishing_reservation"}
		obstacles.append({"id": "furnishing_access:%d" % index, "bounds": volume})
	return {"ready": true, "obstacles": obstacles}


static func prepare_terminal_frames(source_b, variation: float, furnishing_obstacles: Array, placed_households: Array, terminal_producer: Callable, terminal_planner: Callable) -> Dictionary:
	# Full transaction: failed goods/placement/any bay leaves caller unchanged.
	var b = FrozenBlueprint.new(source_b.id, source_b.seed, source_b.style)
	b.recipe = source_b.recipe.duplicate(true)
	b.rooms = source_b.rooms.duplicate(true)
	for part in source_b.parts:
		var copy = b.add_part(part.snapshot())
		copy.physical_intent = part.physical_intent
		b.physical_parts_by_id[copy.id] = copy
	var scratch = FrozenBlueprint.new("terminal_membership_only", b.seed, b.style)
	terminal_producer.call(scratch, Vector3.ZERO, variation)
	var ids: Array = []
	var prefixes: Array[String] = []
	for expected in scratch.parts:
		if b.find_part(expected.id) == null:
			return {"ready": false, "reason": "terminal_producer_member_missing", "partId": expected.id}
		ids.append(expected.id)
		# This is the existing builder's public prefix convention, not a named
		# bay exception. All bays come from add_terminal_shop_row itself.
		if expected.semantic == "citadel_terminal_shop_frame" and String(expected.id).ends_with("_lintel"):
			prefixes.append(String(expected.id).trim_suffix("_lintel"))
	prefixes.sort()
	if prefixes.is_empty():
		return {"ready": false, "reason": "no_terminal_frame_declarations"}
	var goods: Dictionary = TerminalGoods.apply(b, ids)
	if not goods.ready:
		return {"ready": false, "reason": "terminal_goods_placement_failed", "goods": goods}
	# Describe the complete real frame BEFORE reserving a footprint. This is
	# unbound geometry, not structural readiness: no fabricated support/root.
	var descriptions: Array = []
	for prefix in prefixes:
		var description: Dictionary = TerminalFrame.describe_frame(b, prefix)
		if not description.get("described", false):
			return {"ready": false, "reason": "terminal_frame_description_failed", "description": description}
		for record in description.records:
			var part = b.find_part(record.id)
			if part == null:
				part = b.add_part(record)
				b.physical_parts_by_id[part.id] = part
			else:
				part.position = record.position
				part.rotation = record.rotation
				part.size = record.size
				part.collision_enabled = record.collision
				part.recipe = record.recipe.duplicate(true)
			part.physical_intent = record.physicalIntent
		ids.append_array(description.partIds)
		descriptions.append(description)
	# Explicit recipe policy: intact row on public paving, with full customer
	# frontage. The rejected old-terrace search is NOT an active fallback.
	var reservations: Array[Rect2] = []
	# A later cohort must preserve the public space reserved by earlier ones,
	# not merely avoid their solid parts. Non-colliding shop decoration must
	# never be placed across an already promised customer approach.
	if placed_households.size() > Batch.MAX_HOUSEHOLDS:
		return {"ready": false, "reason": "household_reservation_limit"}
	for household in placed_households:
		if not household is Dictionary or not household.get("approach") is Rect2 or not household.get("circulationFootprint") is Rect2:
			return {"ready": false, "reason": "invalid_household_reservation"}
		reservations.append(household.approach)
		reservations.append(household.circulationFootprint)
	for obstacle in furnishing_obstacles:
		var bounds: AABB = obstacle.bounds
		reservations.append(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z)))
	var layout: Dictionary = terminal_planner.call(b, ids, Vector3.FORWARD, reservations)
	if not layout.ready:
		return {"ready": false, "reason": "terminal_public_paving_unavailable", "layout": layout}
	layout["priorHouseholdReservationCount"] = placed_households.size() * 2
	for id in ids:
		var part = b.find_part(id)
		var pose: Transform3D = layout.transform * b.part_transform(part)
		part.position = pose.origin
		part.rotation = pose.basis.get_euler()
	var planned_records: Dictionary = {}
	for id in ids: planned_records[id] = b.find_part(id).snapshot()
	# Preserve the exact transformed described records for the binding API.
	# Neither geometry nor local internal joint definitions are regenerated.
	for description in descriptions:
		description.records = description.memberIds.map(func(id): return b.find_part(id).snapshot())
		description.clothRecords = description.clothIds.map(func(id): return b.find_part(id).snapshot())
	var records: Dictionary = {}
	var members: Dictionary = {}
	for id in ids: members[id] = true
	for part in b.parts:
		var bounds: AABB = b.transformed_part_bounds(part)
		records[part.id] = {"part": part, "bounds": bounds, "footprint": Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))}
	var closure: Dictionary = TerminalElevation._support_closure(b, records, members, layout.supportId)
	if not closure.ready:
		return {"ready": false, "reason": "terminal_public_support_unproven", "layout": layout, "closure": closure}
	var elevation := {"ready": true, "supportId": layout.supportId, "standingY": layout.standingY,
		"upstreamIds": closure.partIds.filter(func(id): return id != layout.supportId), "supportClosure": closure,
		"policy": "intact_row_on_public_paving", "publicPavingPlan": layout}
	var setups: Array = []
	for description in descriptions:
		var frame: Dictionary = TerminalFrame.bind_described_frame_on_support(b, description, elevation.supportId, elevation.upstreamIds)
		setups.append({"prefix": description.prefix, "supportId": elevation.supportId, "construction": frame})
		if not bool(frame.get("ready", false)):
			return {"ready": false, "reason": "terminal_construction_failed", "elevation": elevation, "setups": setups}
	var post_ids: Array = []
	for description in descriptions: post_ids.append_array(description.postIds)
	for id in ids:
		var before: Dictionary = planned_records[id].duplicate(true)
		var after: Dictionary = b.find_part(id).snapshot()
		if post_ids.has(id):
			for key in ["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"]:
				before.recipe.erase(key)
				after.recipe.erase(key)
		if var_to_bytes(before) != var_to_bytes(after):
			return {"ready": false, "reason": "terminal_binding_changed_planned_record", "partId": id}
	layout["plannedRecordsPreservedThroughBinding"] = true
	# All fallible work is complete. Preserve upstream/source object identity.
	# Builders append authored records without publishing the lookup cache.
	var completed: Dictionary = {}
	for part in b.parts: completed[part.id] = part
	if not ids.all(func(id): return completed.has(id)):
		return {"ready": false, "reason": "terminal_transaction_incomplete"}
	# The provisional placement may not quietly gain geometry outside the
	# footprint that was checked against other households and reservations.
	for setup in setups:
		for id in setup.construction.partIds:
			var bounds: AABB = b.transformed_part_bounds(completed[id])
			var footprint := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
			if not (layout.footprint as Rect2).encloses(footprint):
				return {"ready": false, "reason": "terminal_frame_exceeds_planned_footprint", "partId": id, "footprint": footprint, "layout": layout}
	layout["completeFrameFootprintPreserved"] = true
	for id in ids:
		var changed = completed[id]
		var original = source_b.find_part(id)
		if original == null:
			var added = source_b.add_part(changed.snapshot())
			source_b.physical_parts_by_id[id] = added
			continue
		original.position = changed.position
		original.rotation = changed.rotation
		original.size = changed.size
		original.collision_enabled = changed.collision_enabled
		original.physical_intent = changed.physical_intent
		original.recipe = changed.recipe.duplicate(true)
	return {"ready": true, "setups": setups, "allIds": ids, "elevation": elevation, "goods": goods,
		"front": b.part_transform(b.find_part(prefixes[0] + "_lintel")).basis * Vector3.FORWARD,
		"seatSelection": "Shared public-paving household placement with full customer frontage; original world support closure and all frame joints must validate. No old-terrace fallback; no access or publisher clearance claim."}
