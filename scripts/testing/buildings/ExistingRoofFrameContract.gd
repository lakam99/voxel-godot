extends SceneTree

## Synthetic source/geometry contract ONLY, not live gameplay acceptance.
## Uses the unmodified production builder and physical validator; no mocks.
## Run with --headless --path <worktree> --script res://scripts/testing/buildings/ExistingRoofFrameContract.gd
## VOXEL_EXISTING_ROOF_REPORT must name a writable JSON file in an existing directory.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const RoofBuilder = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const PREFIX := "contract_roof"
const WIDTH := 6.0
const DEPTH := 5.0
const EAVE_Y := 3.0
const RISE := 2.0
const OVERHANG := 0.4
const GABLE_STRIPS := 6


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var report_path := OS.get_environment("VOXEL_EXISTING_ROOF_REPORT").strip_edges()
	if report_path.is_empty():
		push_error("Synthetic roof contract requires VOXEL_EXISTING_ROOF_REPORT")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var cases: Array[Dictionary] = []
	cases.append(_roof_case("standard_roof_pass", "baseline", "", ""))
	# Remove or displace actual members, leaving declarations untouched.
	for suffix in ["ridge", "front_king_post", "back_king_post", "left_plate", "right_plate"]:
		var member_id := "%s_%s" % [PREFIX, suffix]
		var panel_id := PREFIX + ("_right" if suffix == "right_plate" else "_left")
		cases.append(_roof_case("remove_" + suffix, "remove", member_id, panel_id))
		cases.append(_roof_case("move_" + suffix, "move", member_id, member_id))
	cases.append(_roof_case("unroot_both_foundations", "unroot", "", PREFIX + "_left"))
	# These are duplicate IDs in assembly declarations, not a claim that the
	# production validator enforces global uniqueness of all blueprint part IDs.
	cases.append(_roof_case("duplicate_panel_member_ids", "duplicate_members", PREFIX + "_left", PREFIX + "_left"))
	cases.append(_roof_case("duplicate_ridge_post_ids", "duplicate_posts", PREFIX + "_ridge", PREFIX + "_left"))
	# An actual member-ID collision must also break this named assembly, though
	# it does not establish global duplicate detection for unrelated parts.
	cases.append(_roof_case("ridge_id_collides_with_plate", "duplicate_part_id", PREFIX + "_ridge", PREFIX + "_left"))
	cases.append(_roof_case("joint_outside_bearer_only", "outside_bearer", PREFIX + "_front_tie", PREFIX + "_front_tie"))
	cases.append(_roof_case("joint_outside_seat_only", "outside_seat", PREFIX + "_front_tie", PREFIX + "_front_tie"))
	cases.append(_cycle_case())
	var passed := cases.all(func(record: Dictionary) -> bool: return bool(record.get("passed", false)))
	var report := {
		"evidenceLevel": "synthetic_source_geometry_contract",
		"passed": passed,
		"caseCount": cases.size(),
		"builder": "res://scripts/buildings/GabledRoofFrameBuilder.gd",
		"validator": "res://scripts/buildings/BuildingBlueprint.gd::validate_physical_integrity",
		"parameters": {"width": WIDTH, "depth": DEPTH, "eaveY": EAVE_Y, "rise": RISE, "overhang": OVERHANG, "gableStripCount": GABLE_STRIPS},
		"cases": cases,
		"elapsedMsec": Time.get_ticks_msec() - started,
		"doesNotProve": "Live gameplay, rendered appearance, physics publication, navigation, real-world engineering safety, global blueprint ID uniqueness, or alternative gable-frame support. The cycle is an isolated two-member synthetic support contract."
	}
	var output := FileAccess.open(report_path, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write synthetic roof report: %s (error %s)" % [report_path, FileAccess.get_open_error()])
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("SYNTHETIC existing roof contract: ", "PASS" if passed else "FAIL", " cases=", cases.size(), " report=", report_path)
	quit(0 if passed else 1)


func _build_roof():
	var blueprint = Blueprint.new("synthetic_existing_roof", 208159, "timber")
	# Two separate, collision-backed wall bearers, each sitting on an actual
	# foundation whose bottom is y=0. No physicalRoot flags are manufactured.
	var plate_x := WIDTH * 0.5 - RoofBuilder.ROOF_PLATE_THICKNESS * 0.5
	for side in ["left", "right"]:
		var x := -plate_x if side == "left" else plate_x
		blueprint.add_part({
			"id": side + "_foundation", "kind": "foundation",
			"position": Vector3(x, 0.25, 0.0), "size": Vector3(1.0, 0.5, DEPTH + 0.4),
			"collision": true, "material": "stone_foundation"
		})
		blueprint.add_part({
			"id": side + "_wall", "kind": "wall",
			"position": Vector3(x, (EAVE_Y + 0.5) * 0.5, 0.0),
			"size": Vector3(0.8, EAVE_Y - 0.5, DEPTH + 0.2),
			"collision": true, "material": "stone_foundation",
			"recipe": {"physicalRequiredSupportPartIds": [side + "_foundation"]}
		})
	RoofBuilder.add_gabled_roof_frame(blueprint, {
		"prefix": PREFIX, "center": Vector3.ZERO,
		"width": WIDTH, "depth": DEPTH, "eaveY": EAVE_Y,
		"rise": RISE, "overhang": OVERHANG, "variation": 0.0,
		"gableStripCount": GABLE_STRIPS,
		"eaveBearingPartIds": ["left_wall", "right_wall"]
	})
	return blueprint


func _roof_case(case_id: String, mutation: String, target_id: String, expected_failed_id: String) -> Dictionary:
	# Fresh production records for each case: never reuse inferred roots/caches
	# from a previously validated blueprint after moving or removing supports.
	var blueprint = _build_roof()
	var target = _find(blueprint, target_id)
	var before: Dictionary = target.snapshot() if target != null else {}
	var setup_ok := mutation in ["baseline", "unroot"] or target != null
	if setup_ok:
		match mutation:
			"remove":
				blueprint.parts.erase(target)
			"move":
				target.position += Vector3(12.0, 0.0, 0.0)
			"unroot":
				for side in ["left", "right"]:
					_find(blueprint, side + "_foundation").position.y -= 2.0
			"duplicate_members":
				target.recipe["physicalRequiredRoofFramePartIds"] = [PREFIX + "_left_plate", PREFIX + "_left_plate"]
			"duplicate_posts":
				target.recipe["physicalRequiredRoofFramePostIds"] = [PREFIX + "_front_king_post", PREFIX + "_front_king_post"]
			"duplicate_part_id":
				target.id = PREFIX + "_left_plate"
			"outside_bearer", "outside_seat":
				var facts: Array = target.recipe["physicalRequiredSeatFacts"]
				var joint: Dictionary = facts[0]
				var center: Vector3 = joint["localOverlapCenter"]
				if mutation == "outside_bearer":
					# Above the thin tie, but still strictly inside the tall plate.
					center.y = 0.40
				else:
					# Middle of the tie: inside the bearer, far from its left seat.
					center.x = 0.0
				joint["localOverlapCenter"] = center
	var result: Dictionary = blueprint.validate_physical_integrity()
	var details: Dictionary = {}
	var failed_ids: Array[String] = []
	for check in result.get("checks", []):
		if not bool(check.get("passed", false)):
			failed_ids.append(String(check.get("partId", "")))
	var expects_pass := mutation == "baseline"
	if expects_pass:
		setup_ok = setup_ok and blueprint.parts.size() == 4 + 9 + GABLE_STRIPS * 2
		for side in ["left", "right"]:
			var foundation = blueprint.find_part(side + "_foundation")
			var wall = blueprint.find_part(side + "_wall")
			var panel = blueprint.find_part(PREFIX + "_" + side)
			var rooted := bool(foundation.recipe.get("physicalRoot", false)) and blueprint.has_rooted_support_chain(wall, {})
			var assembly_valid: bool = blueprint.has_valid_roof_frame_assembly(panel)
			details[side] = {"wallRootedOnFoundation": rooted, "assemblyValid": assembly_valid}
			setup_ok = setup_ok and rooted and assembly_valid
	elif mutation == "unroot":
		var root_count := 0
		for part in blueprint.parts:
			root_count += int(bool(part.recipe.get("physicalRoot", false)))
		details["rootCount"] = root_count
		setup_ok = setup_ok and root_count == 0
	elif mutation in ["outside_bearer", "outside_seat"] and target != null:
		var joint: Dictionary = target.recipe["physicalRequiredSeatFacts"][0]
		var seat = blueprint.find_part(String(joint["seatId"]))
		details = blueprint.housed_overlap_diagnostics(target, seat, joint)
		setup_ok = setup_ok and bool(details.get("rootedSeat", false))
		setup_ok = setup_ok and bool(details.get("insideBearer", false)) == (mutation == "outside_seat")
		setup_ok = setup_ok and bool(details.get("insideSeat", false)) == (mutation == "outside_bearer")
	var passed := setup_ok and bool(result.get("passed", false)) == expects_pass
	if not expects_pass:
		passed = passed and failed_ids.has(expected_failed_id)
	print("SYNTHETIC roof case ", case_id, ": ", "PASS" if passed else "FAIL")
	return {"id": case_id, "passed": passed, "setupPassed": setup_ok,
		"expectedValidatorPass": expects_pass, "expectedFailedPartId": expected_failed_id,
		"mutation": mutation, "targetId": target_id, "targetBefore": before,
		"targetAfter": target.snapshot() if target != null and mutation != "remove" else {},
		"diagnostics": details, "failedPartIds": failed_ids, "validation": result}


func _cycle_case() -> Dictionary:
	# Isolate the actual generic support recursion with two overlapping members
	# referencing one another and no foundation/root. Do not inject resolved
	# support caches or replace any validator method.
	var blueprint = Blueprint.new("synthetic_cyclic_only_support", 208159, "timber")
	for member_id in ["cycle_a", "cycle_b"]:
		blueprint.add_part({"id": member_id, "kind": "beam", "collision": true,
			"position": Vector3(0.0, 2.0, 0.0), "size": Vector3(1.0, 1.0, 1.0),
			"recipe": {"physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": ["cycle_b" if member_id == "cycle_a" else "cycle_a"]}})
	var result: Dictionary = blueprint.validate_physical_integrity()
	var first = blueprint.find_part("cycle_a")
	var second = blueprint.find_part("cycle_b")
	var overlaps: bool = blueprint.transformed_parts_overlap(first, second, 0.0)
	var rooted_a: bool = blueprint.has_rooted_support_chain(first, {})
	var rooted_b: bool = blueprint.has_rooted_support_chain(second, {})
	var passed := overlaps and not rooted_a and not rooted_b and not bool(result.get("passed", true))
	passed = passed and (result.get("checks", []) as Array).size() == 2
	passed = passed and (result.get("checks", []) as Array).all(func(check: Dictionary) -> bool: return not bool(check.get("passed", true)))
	print("SYNTHETIC roof support cycle: ", "PASS" if passed else "FAIL")
	return {"id": "cyclic_only_support_rejected", "passed": passed,
		"expectedValidatorPass": false, "overlappingMembers": overlaps,
		"rootedA": rooted_a, "rootedB": rooted_b, "validation": result}


func _find(blueprint, part_id: String):
	# Before validation the production lookup cache has not been populated.
	for part in blueprint.parts:
		if String(part.id) == part_id:
			return part
	return null
