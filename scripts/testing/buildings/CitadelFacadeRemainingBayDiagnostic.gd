extends SceneTree

## Separate source-only diagnostic; does not rerun or redefine the four-case
## acceptance contract. One actual producer invocation per case, at most eight
## applications of the unchanged adapter. No headers, publisher or traversal.
## VOXEL_FACADE_REMAINING_BAY_REPORT: new absolute JSON in an existing directory.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Recipe = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const MAX_CALLS := 8


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_FACADE_REMAINING_BAY_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		push_error("Require a new VOXEL_FACADE_REMAINING_BAY_REPORT path")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var cases: Array = []
	for side in [-1.0, 1.0]:
		for dimensions in [Vector3(7.2, 6.2, 9.45), Vector3(8.0, 9.3, 11.2)]:
			cases.append(_case(side, dimensions, cases.size()))
	var complete: bool = cases.all(func(row): return row.complete)
	var report := {"evidenceLevel": "actual_producer_repeated_bottom_bay_source_diagnostic", "complete": complete,
		"remainingBayDiagnostic": {"maxCallsPerCase": MAX_CALLS, "cases": cases},
		"physicalGatePassed": cases.all(func(row): return row.get("physicalGatePassed", false)),
		"elapsedMsec": Time.get_ticks_msec() - started,
		"limitations": "Completion means bounded observation and preservation checks succeeded, NOT a green physical gate. Four representative generated houses, not the frozen 163-panel inventory. Rejection is under the current bottom-bay policy, not universal impossibility. No header construction or publisher, visual, access or NPC acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	print("Remaining-bay diagnostic complete=", complete, " physicalGatePassed=", report.physicalGatePassed)
	quit(0 if written and complete else 2)


func _case(side: float, dimensions: Vector3, index: int) -> Dictionary:
	var b = Blueprint.new("actual_facade_%d" % index, 701 + index, "timber")
	b.set_recipe({"foundationHeight": 0.62, "courtyardResidences": []})
	var start_count: int = b.parts.size()
	Urban.add_street_house(b, "producer_%d" % index, Vector3(side * 7.0, 0, index * 3.0), dimensions.x, dimensions.z, dimensions.y, side, 0.62, "painted_brick_cream", float(index) * 0.01)
	# Capture the producer boundary once, without reimplementing its ID grammar.
	var producer_ids: Array = b.parts.slice(start_count).map(func(part): return part.id)
	var original: Dictionary = b.snapshot()
	var row := {"complete": false, "side": side, "dimensions": dimensions, "producerIds": producer_ids, "calls": []}
	var baseline := _physical(original)
	if not baseline.ready:
		row["reason"] = baseline
		return row
	row["beforePhysical"] = baseline.physical
	var furnishing = Furniture.build(Recipe.copy_blueprint(original), 813)
	if furnishing == null:
		row["reason"] = "furnishing_planner_failed"
		return row
	var furnishing_before: Dictionary = furnishing.snapshot()
	var policy := {"furnitureParts": furnishing_before.parts, "reservedVolumes": furnishing.protected_access_reservations.duplicate()}
	var policy_digest := _digest(policy)
	var members: Array = []
	var additions: Array = []
	var previous_failures: Array = Recipe.failed_ids(baseline.physical)
	var terminal: Dictionary = {}
	var stop_reason := "call_limit_reached"
	var checks := {"failure_atomic": true, "every_success_progressed": true, "no_new_failed_ids_each_call": true}
	for call_index in range(MAX_CALLS):
		var before_call := _digest(b.snapshot())
		var result: Dictionary = Recipe.add_one_bay(b, producer_ids, policy)
		# Keep authoritative rejection details and exact part IDs, including any
		# collision partId/otherId. No diagnostic substitute for adapter outcome.
		row.calls.append({"callIndex": call_index, "result": result})
		terminal = result
		if not result.ready:
			checks.failure_atomic = _digest(b.snapshot()) == before_call
			stop_reason = "adapter_rejected"
			break
		var current_failures: Array = Recipe.failed_ids(result.afterPhysical)
		var newly_resolved: Array = previous_failures.filter(func(id): return not current_failures.has(id))
		checks.no_new_failed_ids_each_call = checks.no_new_failed_ids_each_call and current_failures.all(func(id): return previous_failures.has(id))
		for id in result.memberIds:
			if not members.has(id): members.append(id)
		for id in result.partIds:
			if not additions.has(id): additions.append(id)
		row.calls.back()["newlyResolvedPartIds"] = newly_resolved
		if newly_resolved.is_empty():
			checks.every_success_progressed = false
			stop_reason = "no_progress"
			break
		previous_failures = current_failures
	var output: Dictionary = b.snapshot()
	var final := _physical(output)
	if not final.ready:
		row["reason"] = final
		return row
	var final_failures: Array = Recipe.failed_ids(final.physical)
	var initial_failures: Array = Recipe.failed_ids(baseline.physical)
	var panels: Array = b.parts.filter(func(part): return producer_ids.has(part.id) and part.semantic == "citadel_urban_facade" and part.kind == "wall" and part.collision_enabled)
	var remaining_ids: Array = panels.filter(func(part): return final_failures.has(part.id)).map(func(part): return part.id)
	var furnishing_after = Furniture.build(Recipe.copy_blueprint(output), 813)
	checks["all_original_source_preserved_except_declared_panel_contracts"] = _preserved(original, output, members, additions)
	checks["policy_exact"] = _digest(policy) == policy_digest
	checks["all_original_furniture_plan_parts_exact"] = furnishing_after != null and _digest(furnishing_before) == _digest(furnishing_after.snapshot())
	checks["furniture_reservations_exact"] = furnishing_after != null and _digest(furnishing.protected_access_reservations) == _digest(furnishing_after.protected_access_reservations)
	var contents_before := _contents(original)
	var contents_after := _contents(output)
	checks["nonempty_producer_household_contents_exact"] = not contents_before.is_empty() and _digest(contents_before) == _digest(contents_after)
	checks["no_new_final_failure_ids"] = final_failures.all(func(id): return initial_failures.has(id))
	row["checks"] = checks
	row["stopReason"] = stop_reason
	row["terminalAdapterReason"] = terminal.get("reason", "")
	row["afterPhysical"] = final.physical
	row["resolvedPartIds"] = initial_failures.filter(func(id): return not final_failures.has(id))
	row["remainingPartIds"] = final_failures
	row["resolvedFacadeIds"] = panels.filter(func(part): return initial_failures.has(part.id) and not final_failures.has(part.id)).map(func(part): return part.id)
	row["remainingFacadeIds"] = remaining_ids
	row["remainingPanels"] = _remaining(panels, remaining_ids, b.rooms, terminal, stop_reason)
	row["originalRooms"] = original.rooms
	row["addedParts"] = output.parts.filter(func(part): return additions.has(part.id))
	row["householdContentsBefore"] = contents_before
	row["householdContentsAfter"] = contents_after
	row["furnitureBefore"] = furnishing_before
	row["furnitureAfter"] = furnishing_after.snapshot() if furnishing_after != null else {}
	row["furnitureScope"] = "Street-house contents are original source parts. Courtyard furnishing plan can legitimately be empty; its equality is not furnished-interior proof. Every original non-selected source part is checked byte-exact, not just the named content categories."
	row["physicalGatePassed"] = final_failures.is_empty()
	# Only this explicit ordinary rejection ends the current recipe search.
	# A cap or another failure is incomplete, never proof of no eligible bay.
	row["complete"] = stop_reason == "adapter_rejected" and terminal.get("reason") == "no_clear_actual_bottom_bay" and terminal.get("attempts", []).size() < Recipe.MAX_ATTEMPTS and checks.values().all(func(value): return bool(value))
	return row


func _remaining(panels: Array, ids: Array, rooms: Array, terminal: Dictionary, stop_reason: String) -> Array:
	var rows: Array = []
	var datum := INF
	for panel in panels: datum = minf(datum, panel.position.y - panel.size.y * 0.5)
	for panel in panels:
		if not ids.has(panel.id): continue
		var bounds: AABB = Recipe.Frame._bounds(panel)
		var reasons: Array = []
		var attempts: Array = terminal.get("attempts", []).filter(func(attempt): return attempt.get("memberIds", []).has(panel.id))
		var accesses: Array = []
		for room in rooms:
			for access in room.get("accesses", []):
				if bounds.position.z < access.position.z + access.size.z * 0.5 + Recipe.CLEARANCE and bounds.end.z > access.position.z - access.size.z * 0.5 - Recipe.CLEARANCE: accesses.append(access)
		if absf(bounds.position.y - datum) >= Recipe.Frame.EPS: reasons.append("higher_row_outside_bottom_bay_adapter_scope")
		elif panel.recipe.has("physicalRequiredSeatPartIds"): reasons.append("existing_seat_contract_excluded_by_adapter")
		elif not accesses.is_empty(): reasons.append("whole_panel_crosses_declared_access_span_under_current_policy")
		for attempt in attempts: reasons.append(attempt.result.get("reason", "unreported_rejection"))
		if reasons.is_empty(): reasons.append("not_attempted_or_unexplained_by_adapter_no_eligibility_claim")
		if stop_reason == "call_limit_reached": reasons.append("eight_call_limit_prevents_exhaustion_claim")
		rows.append({"partId": panel.id, "source": panel.snapshot(), "bounds": bounds, "bottomRowDatum": datum,
			"reasons": reasons, "terminalAttempts": attempts, "accessSpanProjections": accesses,
			"scope": "Reasons describe current adapter exclusions or actual rejections; higher rows are not automatically classified as header-solvable."})
	return rows


func _physical(snapshot: Dictionary) -> Dictionary:
	var b = Recipe.copy_blueprint(snapshot)
	Recipe.clear_caches(b)
	var work: Dictionary = Recipe.validation_grid_work(b)
	if not work.ready: return work
	return {"ready": true, "physical": b.validate_physical_integrity()}


func _contents(snapshot: Dictionary) -> Array:
	return snapshot.parts.filter(func(part): return part.semantic in ["citadel_household_storage", "citadel_household_firewood", "citadel_household_tools", "citadel_household_window_box", "citadel_shopfront_goods"])


func _preserved(before: Dictionary, after: Dictionary, members: Array, additions: Array) -> bool:
	var a := before.duplicate(true)
	var c := after.duplicate(true)
	a.erase("parts")
	c.erase("parts")
	if _digest(a) != _digest(c) or after.parts.size() != before.parts.size() + additions.size(): return false
	for i in range(before.parts.size()):
		var old: Dictionary = before.parts[i].duplicate(true)
		var current: Dictionary = after.parts[i].duplicate(true)
		if members.has(old.id):
			for record in [old, current]:
				record.erase("physicalIntent")
				for key in record.recipe.keys():
					if String(key).begins_with("physical"): record.recipe.erase(key)
		if _digest(old) != _digest(current): return false
	return after.parts.slice(before.parts.size()).map(func(part): return part.id).all(func(id): return additions.has(id))


func _digest(value: Variant) -> String:
	return var_to_bytes(value).hex_encode().sha256_text()
