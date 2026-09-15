extends SceneTree

## Focused procedural civic-geometry contract. This verifies recipe records and
## exact contacts only; it does not prove publication, rendered quality, or play.
const Blueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const Castle := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Composer := preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")

const KEEP_FRONT_Z := -5.018
const FRONT_Z := -42.0
const BASE_Y := 0.62
const LANDMARK_CENTER := Vector3(-14.0, 0.0, -8.768)
const TOWER_WIDTH := 8.4
const TOWER_DEPTH := 9.0
const TOWER_HEIGHT := 17.0
const EPSILON := 0.025
const STRUCTURAL_RECIPES_KEY := "citadelStreetHouseStructuralRecipes"
const CIVIC_DECLARATION_ADDITIONS := {
	"facadeApertures": ["urban_civic_house_east_stone_facade", "urban_civic_house_east_upper_facade", "urban_civic_house_wall_stone_facade", "urban_civic_house_wall_upper_facade"],
	STRUCTURAL_RECIPES_KEY: ["urban_civic_house_east", "urban_civic_house_wall"],
	"citadelUrbanHomes": ["urban_civic_house_east", "urban_civic_house_wall"]}
const COMMONS_LOCAL_GEOMETRY_SIGNATURE := "4bc2d90341fb68a868def72131d3efd03b7fe421213774e0cd24dbbb9f1ea315"
const COMMONS_MEMBER_ORDER := [
	"urban_civic_commons_stone_00", "urban_civic_commons_stone_01", "urban_civic_commons_stone_02", "urban_civic_commons_stone_03",
	"urban_civic_commons_stone_04", "urban_civic_commons_stone_05", "urban_civic_commons_stone_06", "urban_civic_commons_stone_07",
	"urban_civic_commons_bench", "urban_civic_commons_bench_leg_-1", "urban_civic_commons_bench_leg_1",
	"urban_civic_commons_bench_back", "urban_civic_commons_bench_back_post_-1", "urban_civic_commons_bench_back_post_1"]
const COMMONS_VISUAL_BEAM_IDS := [
	"urban_civic_commons_bench_leg_-1", "urban_civic_commons_bench_leg_1",
	"urban_civic_commons_bench_back_post_-1", "urban_civic_commons_bench_back_post_1"]

var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var report_path := OS.get_environment("VOXEL_CITADEL_CIVIC_RECIPE_REPORT")
	if not report_path.is_absolute_path() or FileAccess.file_exists(report_path):
		quit(2)
		return
	var forward = build_fixture(false)
	var reversed = build_fixture(true)
	var forward_parts: Array = civic_parts(forward)
	var reversed_parts: Array = civic_parts(reversed)
	var forward_audit := audit_civic_parts(forward_parts)
	var reversed_audit := audit_civic_parts(reversed_parts)
	check("forward_civic_recipe_geometry_passes", bool(forward_audit.get("passed", false)))
	check("reversed_call_order_civic_recipe_geometry_passes", bool(reversed_audit.get("passed", false)))
	check("civic_signature_is_call_order_independent", civic_signature(forward_parts) == civic_signature(reversed_parts))
	check("noncivic_records_remain_byte_exact", noncivic_signature(forward) == noncivic_signature(reversed) and noncivic_signature(forward) == expected_noncivic_signature())
	check("furniture_and_reservations_remain_byte_exact", var_to_bytes(forward.recipe) == var_to_bytes(reversed.recipe) and var_to_bytes(forward.recipe) == var_to_bytes(expected_recipe()))
	var physical_fixture = Blueprint.new("civic_roof_physical_fixture", 208159, "civic")
	Composer.add_civic_landmark(physical_fixture, LANDMARK_CENTER, BASE_Y, 0.37)
	var physical_report: Dictionary = physical_fixture.validate_physical_integrity()
	var civic_roof_physical_ids: Array[String] = ["urban_civic_roof_left", "urban_civic_roof_right", "urban_civic_roof_bearing_-1", "urban_civic_roof_bearing_1"]
	for side in [-1, 1]:
		for level in range(4):
			civic_roof_physical_ids.append("urban_civic_roof_gable_%d_%02d" % [side, level])
	var failed_civic_roof_ids: Array = (physical_report.get("checks", []) as Array).filter(func(row): return civic_roof_physical_ids.has(String(row.partId)) and not bool(row.passed)).map(func(row): return String(row.partId))
	check("collision_bearing_civic_roof_has_complete_rooted_physical_chains", bool(physical_report.get("passed", false)) and failed_civic_roof_ids.is_empty())
	check("new_commons_back_exposes_bounded_readable_rectangle_and_old_clone_fails", bool(forward_audit.get("backReadability", false)) and bool(forward_audit.get("oldBackReadabilityRejected", false)) and bool(reversed_audit.get("backReadability", false)) and bool(reversed_audit.get("oldBackReadabilityRejected", false)))
	var layout_audits := [audit_commons_layout_overlap(208159), audit_commons_layout_overlap(208160)]
	for field: String in ["streetPartsByteExact", "streetRoomsByteExact", "streetRecipeRecordsByteExact", "changedExistingDeclarationRejected", "unexpectedDeclarationAdditionRejected"]:
		check(field, layout_audits.all(func(audit): return bool(audit.get(field, false))))
	var clear_layout_audit := audit_ground_level_street_policy()
	check("street_layout_has_no_recipe_authored_exterior_terraces", bool(clear_layout_audit.get("passed", false)))
	check("shared_street_row_geometry_is_deterministic_and_malformed_input_fails_closed", audit_street_row_geometry_contract())
	check("commons_recipe_tracks_generated_row_and_clears_two_seed_layouts", layout_audits.all(func(audit): return bool(audit.get("passed", false))))
	check("commons_fourteen_piece_local_geometry_is_seed_independent", layout_audits.size() == 2 and layout_audits[0].get("localGeometrySignature") == COMMONS_LOCAL_GEOMETRY_SIGNATURE and layout_audits[1].get("localGeometrySignature") == COMMONS_LOCAL_GEOMETRY_SIGNATURE)
	check("commons_member_source_order_is_canonical", layout_audits.all(func(audit): return audit.get("memberOrder", []) == COMMONS_MEMBER_ORDER))
	var commons_intent_audit := audit_commons_physical_intent_recipe()
	check("only_noncolliding_commons_support_beams_declare_visual_detail", bool(commons_intent_audit.get("passed", false)))
	check("fresh_commons_physical_validation_has_zero_failures", (commons_intent_audit.get("failedCommonsIds", []) as Array).is_empty())
	var unsupported_controls := audit_unsupported_beam_controls()
	check("unsupported_facade_beam_still_fails_exact_rooted_anchor_gate", bool(unsupported_controls.get("facadeControlPassed", false)))
	check("collision_bearing_visual_detail_still_fails_exact_collision_gate", bool(unsupported_controls.get("collisionControlPassed", false)))
	var missing_seat: Array = forward_parts.filter(func(part): return String(part.id) != "urban_civic_commons_bench")
	var missing_roof: Array = forward_parts.filter(func(part): return String(part.id) != "urban_civic_roof_right")
	check("missing_seat_fails_closed", not bool(audit_civic_parts(missing_seat).get("passed", true)))
	check("missing_roof_half_fails_closed", not bool(audit_civic_parts(missing_roof).get("passed", true)))
	var passed := checks.all(func(row): return bool(row.passed))
	var report := {"passed": passed, "checks": checks, "forwardAudit": forward_audit, "reversedAudit": reversed_audit, "layoutOverlapAudits": layout_audits, "groundLevelStreetPolicyAudit": clear_layout_audit, "commonsPhysicalIntentAudit": commons_intent_audit, "unsupportedBeamControls": unsupported_controls, "physicalRoofAudit": {"passed": physical_report.get("passed", false), "failedCivicRoofIds": failed_civic_roof_ids, "violations": physical_report.get("violations", [])}, "civicSignature": civic_signature(forward_parts), "evidenceLevel": "procedural_recipe_geometry_contract", "doesNotProve": "No scene publication, rendered image, gameplay, NPC or navigation acceptance."}
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("Civic recipe geometry contract: %s (%d checks)" % ["PASS" if passed else "FAIL", checks.size()])
	quit(0 if passed else 1)


func build_fixture(reverse_calls: bool):
	var blueprint = Blueprint.new("civic_recipe_fixture", 208159, "civic")
	blueprint.set_recipe(expected_recipe())
	blueprint.add_part({"id": "noncivic_sentinel", "kind": "decor", "material": "timber_board", "position": Vector3(91.0, 2.0, -37.0), "rotation": Vector3(0.1, 0.2, 0.3), "size": Vector3(1.0, 2.0, 3.0), "collision": false, "semantic": "noncivic_sentinel", "recipe": {"owner": "preserved", "reservationId": "sentinel-reservation"}})
	if reverse_calls:
		Composer.add_civic_landmark(blueprint, LANDMARK_CENTER, BASE_Y, 0.37)
		Composer.add_civic_commons(blueprint, FRONT_Z, KEEP_FRONT_Z, BASE_Y, 0.37, fixture_urban_layout())
	else:
		Composer.add_civic_commons(blueprint, FRONT_Z, KEEP_FRONT_Z, BASE_Y, 0.37, fixture_urban_layout())
		Composer.add_civic_landmark(blueprint, LANDMARK_CENTER, BASE_Y, 0.37)
	return blueprint


func expected_recipe() -> Dictionary:
	return {"furniturePlan": {"chairs": ["a", "b"], "seed": 208159}, "reservations": [{"id": "home-01", "cells": [Vector3i(1, 2, 3)]}], "durableMarker": "unchanged"}


func fixture_urban_layout() -> Dictionary:
	return {"rowCenterPhases": [0.72, 1.68, 2.62, 3.48]}


func complete_fixture_urban_layout() -> Dictionary:
	return {"rowCenterPhases": [0.72, 1.68, 2.62, 3.48], "laneCenters": [0.0, 1.8, 22.0, 12.0], "rowWidthBiases": [0.0, 0.0, 0.0, 0.0], "rowStoreyBonuses": [0, 0, 0, 0], "marketTerraceRise": 0.0, "marketStalls": [{"offset": Vector3(-5.8, 0.0, -2.55), "side": -1.0, "depth": -1.0, "variation": -0.018}, {"offset": Vector3(5.4, 0.0, 1.82), "side": 1.0, "depth": 1.0, "variation": 0.014}, {"offset": Vector3(-2.2, 0.0, 2.72), "side": -1.0, "depth": 1.0, "variation": 0.031}]}


func civic_parts(blueprint) -> Array:
	return blueprint.parts.filter(func(part): return String(part.id).begins_with("urban_civic_"))


func canonical_part(part) -> Dictionary:
	return {"id": String(part.id), "kind": String(part.kind), "material": String(part.material_id), "semantic": String(part.semantic), "position": part.position, "rotation": part.rotation, "size": part.size, "collision": bool(part.collision_enabled), "recipe": part.recipe.duplicate(true)}


func civic_signature(parts: Array) -> String:
	var records: Array[Dictionary] = []
	for part in parts:
		records.append(canonical_part(part))
	records.sort_custom(func(a, b): return String(a.id) < String(b.id))
	return Marshalls.raw_to_base64(var_to_bytes(records)).sha256_text()


func noncivic_signature(blueprint) -> String:
	var records: Array[Dictionary] = []
	for part in blueprint.parts:
		if not String(part.id).begins_with("urban_civic_"):
			records.append(canonical_part(part))
	records.sort_custom(func(a, b): return String(a.id) < String(b.id))
	return Marshalls.raw_to_base64(var_to_bytes(records)).sha256_text()


func expected_noncivic_signature() -> String:
	var fixture = Blueprint.new("expected_noncivic", 1, "test")
	fixture.add_part({"id": "noncivic_sentinel", "kind": "decor", "material": "timber_board", "position": Vector3(91.0, 2.0, -37.0), "rotation": Vector3(0.1, 0.2, 0.3), "size": Vector3(1.0, 2.0, 3.0), "collision": false, "semantic": "noncivic_sentinel", "recipe": {"owner": "preserved", "reservationId": "sentinel-reservation"}})
	return noncivic_signature(fixture)


func audit_civic_parts(parts: Array) -> Dictionary:
	var by_id: Dictionary = {}
	var positive_finite := true
	for part in parts:
		var id := String(part.id)
		if id.is_empty() or by_id.has(id):
			return {"passed": false, "reason": "duplicate_or_empty_id"}
		by_id[id] = part
		positive_finite = positive_finite and part.position.is_finite() and part.rotation.is_finite() and part.size.is_finite() and part.size.x > 0.0 and part.size.y > 0.0 and part.size.z > 0.0
	var seating_ids := ["urban_civic_commons_bench", "urban_civic_commons_bench_back", "urban_civic_commons_bench_back_post_-1", "urban_civic_commons_bench_back_post_1", "urban_civic_commons_bench_leg_-1", "urban_civic_commons_bench_leg_1"]
	var roof_ids := ["urban_civic_roof_left", "urban_civic_roof_right", "urban_civic_roof_bearing_-1", "urban_civic_roof_bearing_1", "urban_civic_roof_ridge", "urban_civic_roof_eave_-1", "urban_civic_roof_eave_1"]
	var required_ids: Array = seating_ids + roof_ids
	for gable_side in [-1, 1]:
		for level in range(4):
			required_ids.append("urban_civic_roof_gable_%d_%02d" % [gable_side, level])
	var missing: Array[String] = []
	for id in required_ids:
		if not by_id.has(id):
			missing.append(id)
	if not missing.is_empty():
		return {"passed": false, "reason": "missing_required_members", "missing": missing}
	var seat = by_id["urban_civic_commons_bench"]
	var seat_bottom: float = float(seat.position.y) - float(seat.size.y) * 0.5
	var seat_top: float = float(seat.position.y) + float(seat.size.y) * 0.5
	var exact_seating_silhouette := is_equal_approx(float(seat.size.x), 4.0) and is_equal_approx(float(seat.size.y), 0.28) and is_equal_approx(float(seat.size.z), 0.72)
	var seating_contacts := true
	var common_support_bottom := INF
	for id in ["urban_civic_commons_bench_leg_-1", "urban_civic_commons_bench_leg_1"]:
		var leg = by_id[id]
		seating_contacts = seating_contacts and is_equal_approx(leg.position.y + leg.size.y * 0.5, seat_bottom)
		common_support_bottom = minf(common_support_bottom, leg.position.y - leg.size.y * 0.5)
	var back = by_id["urban_civic_commons_bench_back"]
	exact_seating_silhouette = exact_seating_silhouette and is_equal_approx(float(back.size.x), 4.0) and is_equal_approx(float(back.size.y), 1.10) and is_equal_approx(float(back.size.z), 0.18)
	var local_back_offset: Vector3 = (back.position - seat.position).rotated(Vector3.UP, -seat.rotation.y)
	seating_contacts = seating_contacts and is_equal_approx(back.position.y - back.size.y * 0.5, seat_top) and is_equal_approx(local_back_offset.z - back.size.z * 0.5, seat.size.z * 0.5)
	for id in ["urban_civic_commons_bench_back_post_-1", "urban_civic_commons_bench_back_post_1"]:
		var post = by_id[id]
		var local_post_offset: Vector3 = (post.position - seat.position).rotated(Vector3.UP, -seat.rotation.y)
		seating_contacts = seating_contacts and is_equal_approx(post.position.y - post.size.y * 0.5, common_support_bottom) and is_equal_approx(post.position.y + post.size.y * 0.5, back.position.y + back.size.y * 0.5) and is_equal_approx(local_post_offset.z - post.size.z * 0.5, seat.size.z * 0.5) and absf(local_post_offset.x) + post.size.x * 0.5 < back.size.x * 0.5
	var back_readability := back_exposes_review_rectangle(back, seat)
	var old_back_snapshot: Dictionary = back.snapshot()
	old_back_snapshot["size"] = Vector3(3.4, 0.72, 0.18)
	old_back_snapshot["position"] = Vector3(back.position.x, seat_top + 0.36, back.position.z)
	var old_fixture = Blueprint.new("old_commons_back_negative", 208159, "civic")
	var old_back = old_fixture.add_part(old_back_snapshot)
	var old_back_rejected := not back_exposes_review_rectangle(old_back, seat)
	var stones: Array = parts.filter(func(part): return String(part.semantic) == "citadel_civic_commons_stone")
	var seating: Array = parts.filter(func(part): return String(part.semantic) == "citadel_civic_commons_seating")
	var no_stone_intersections := stones.size() == 8
	for stone in stones:
		for member in seating:
			no_stone_intersections = no_stone_intersections and not world_bounds(stone).intersects(world_bounds(member))
	var commons_center := Vector3(28.0, BASE_Y + 0.244, KEEP_FRONT_Z - 18.0)
	var approach_axis: Vector3 = seat.recipe.get("clearApproachAxis", Vector3.ZERO) as Vector3
	var approach_side_axis := Vector3(-approach_axis.z, 0.0, approach_axis.x)
	var corridor_half_width: float = float(seat.size.x) * 0.5 + 0.35
	var corridor_offsets := [-corridor_half_width, -corridor_half_width * 0.5, 0.0, corridor_half_width * 0.5, corridor_half_width]
	var clear_sector := approach_axis.is_finite() and is_equal_approx(approach_axis.length(), 1.0) and approach_side_axis.is_finite()
	for offset_value in corridor_offsets:
		var approach_start := commons_center + approach_axis * 5.0 + approach_side_axis * float(offset_value) + Vector3.UP * 0.8
		var approach_end: Vector3 = (seat.position as Vector3) + approach_side_axis * float(offset_value)
		for stone in stones:
			clear_sector = clear_sector and world_bounds(stone).grow(0.18).intersects_segment(approach_start, approach_end) == null
	var roof_left = by_id["urban_civic_roof_left"]
	var roof_right = by_id["urban_civic_roof_right"]
	var left_endpoints := roof_endpoints(roof_left)
	var right_endpoints := roof_endpoints(roof_right)
	var left_eave: Vector3 = left_endpoints[0]
	var left_ridge: Vector3 = left_endpoints[1]
	if left_eave.y > left_ridge.y:
		var left_swap := left_eave
		left_eave = left_ridge
		left_ridge = left_swap
	var right_eave: Vector3 = right_endpoints[0]
	var right_ridge: Vector3 = right_endpoints[1]
	if right_eave.y > right_ridge.y:
		var right_swap := right_eave
		right_eave = right_ridge
		right_ridge = right_swap
	var tower_top_y := BASE_Y + TOWER_HEIGHT
	var left_angle := absf(roof_left.rotation.z)
	var right_angle := absf(roof_right.rotation.z)
	var left_contact_y: float = left_eave.y - cos(left_angle) * float(roof_left.size.y) * 0.5
	var right_contact_y: float = right_eave.y - cos(right_angle) * float(roof_right.size.y) * 0.5
	var ridge_meets := left_ridge.distance_to(right_ridge) <= EPSILON and absf(left_ridge.x - LANDMARK_CENTER.x) <= EPSILON
	var eaves_land := absf(left_contact_y - tower_top_y) <= EPSILON and absf(right_contact_y - tower_top_y) <= EPSILON
	var left_overhang := absf(left_eave.x - LANDMARK_CENTER.x) - TOWER_WIDTH * 0.5
	var right_overhang := absf(right_eave.x - LANDMARK_CENTER.x) - TOWER_WIDTH * 0.5
	var roof_rise := (left_ridge.y + right_ridge.y) * 0.5 - (left_eave.y + right_eave.y) * 0.5
	var bounded_roof := left_overhang >= 0.48 - EPSILON and left_overhang <= 0.72 + EPSILON and right_overhang >= 0.48 - EPSILON and right_overhang <= 0.72 + EPSILON and roof_rise / TOWER_WIDTH >= 0.32 and roof_rise / TOWER_WIDTH <= 0.46
	var opposed_faces: bool = bool(roof_left.rotation.z > 0.0 and roof_right.rotation.z < 0.0 and left_eave.x < LANDMARK_CENTER.x and right_eave.x > LANDMARK_CENTER.x)
	var seam_no_gap_or_crossing := ridge_meets and maxf(left_eave.x, left_ridge.x) <= LANDMARK_CENTER.x + EPSILON and minf(right_eave.x, right_ridge.x) >= LANDMARK_CENTER.x - EPSILON
	var ridge = by_id["urban_civic_roof_ridge"]
	var left_seam_projection: float = sin(left_angle) * float(roof_left.size.y) * 0.5
	var right_seam_projection: float = sin(right_angle) * float(roof_right.size.y) * 0.5
	var seam_volume_bounded: bool = bool(seam_no_gap_or_crossing and left_seam_projection <= float(ridge.size.x) * 0.5 + EPSILON and right_seam_projection <= float(ridge.size.x) * 0.5 + EPSILON)
	var ridge_framed: bool = bool(absf(ridge.position.x - LANDMARK_CENTER.x) <= EPSILON and absf(ridge.position.y - left_ridge.y) <= ridge.size.y * 0.5 + roof_left.size.y * 0.5 and is_equal_approx(ridge.size.z, roof_left.size.z) and is_equal_approx(ridge.size.z, roof_right.size.z))
	var eaves_aligned := true
	for side in [-1, 1]:
		var eave = by_id["urban_civic_roof_eave_%d" % side]
		var face = roof_left if side < 0 else roof_right
		var face_eave: Vector3 = left_eave if side < 0 else right_eave
		eaves_aligned = eaves_aligned and absf(eave.position.x - face_eave.x) <= EPSILON and absf(eave.position.y - face_eave.y) <= eave.size.y * 0.5 + face.size.y * 0.5 and is_equal_approx(eave.position.z, face.position.z) and is_equal_approx(eave.size.z, face.size.z)
	var bearing_contacts := true
	for side in [-1, 1]:
		var bearing = by_id["urban_civic_roof_bearing_%d" % side]
		var face = roof_left if side < 0 else roof_right
		var face_transform := Transform3D(Basis.from_euler(face.rotation), face.position)
		var inboard_quarter_bottom: Vector3 = face_transform * Vector3(float(side) * face.size.x * 0.25, -face.size.y * 0.5, 0.0)
		bearing_contacts = bearing_contacts and String(bearing.physical_intent) == "structural_mass" and bool(bearing.collision_enabled) and bearing.recipe.get("physicalRequiredSupportPartIds", []) == ["urban_civic_tower"] and absf(bearing.position.y - bearing.size.y * 0.5 - tower_top_y) <= EPSILON and absf(bearing.position.y + bearing.size.y * 0.5 - (tower_top_y + roof_rise * 0.25)) <= EPSILON and absf(inboard_quarter_bottom.x - bearing.position.x) <= bearing.size.x * 0.5 + EPSILON and absf(inboard_quarter_bottom.y - (bearing.position.y + bearing.size.y * 0.5)) <= EPSILON and absf(inboard_quarter_bottom.z - bearing.position.z) <= bearing.size.z * 0.5 + EPSILON and face.recipe.get("physicalRequiredSupportPartIds", []) == [String(bearing.id)] and String(face.physical_intent) == "structural_mass"
	var gable_contact := true
	for side in [-1, 1]:
		var lowest = by_id["urban_civic_roof_gable_%d_00" % side]
		var highest = by_id["urban_civic_roof_gable_%d_03" % side]
		gable_contact = gable_contact and lowest.position.y - lowest.size.y * 0.5 <= tower_top_y + EPSILON and highest.position.y + highest.size.y * 0.5 >= tower_top_y + roof_rise - EPSILON
		for level in range(4):
			var gable = by_id["urban_civic_roof_gable_%d_%02d" % [side, level]]
			var registered_end_z := LANDMARK_CENTER.z + float(side) * TOWER_DEPTH * 0.5
			var beneath_overhang: bool = bool(absf(gable.position.z - LANDMARK_CENTER.z) + gable.size.z * 0.5 <= TOWER_DEPTH * 0.5 + float(roof_left.recipe.get("roofOverhang", 0.0)) + EPSILON)
			var upper_fraction := float(gable.recipe.get("roofUpperFraction", -1.0))
			var allowed_width := maxf(ridge.size.x, float(roof_left.recipe.get("roofHalfRun", 0.0)) * 2.0 * (1.0 - upper_fraction))
			var expected_gable_support := "urban_civic_tower" if level == 0 else "urban_civic_roof_gable_%d_%02d" % [side, level - 1]
			gable_contact = gable_contact and absf(gable.position.z - registered_end_z) <= EPSILON and beneath_overhang and upper_fraction > 0.0 and gable.size.x <= allowed_width + EPSILON and String(gable.physical_intent) == "structural_mass" and bool(gable.collision_enabled) and gable.recipe.get("physicalRequiredSupportPartIds", []) == [expected_gable_support]
	var gables: Array = parts.filter(func(part): return String(part.semantic) == "citadel_civic_gable_closure")
	var bearings: Array = parts.filter(func(part): return String(part.semantic) == "citadel_civic_roof_bearing")
	var eave_members := [by_id["urban_civic_roof_eave_-1"], by_id["urban_civic_roof_eave_1"]]
	var collisions_ok := seating.all(func(part): return not bool(part.collision_enabled)) and stones.all(func(part): return not bool(part.collision_enabled)) and bool(roof_left.collision_enabled) and bool(roof_right.collision_enabled) and bearings.size() == 2 and bearings.all(func(part): return bool(part.collision_enabled)) and gables.size() == 8 and gables.all(func(part): return bool(part.collision_enabled)) and not bool(ridge.collision_enabled) and String(ridge.physical_intent) == "visual_detail" and eave_members.all(func(part): return not bool(part.collision_enabled) and String(part.physical_intent) == "visual_detail")
	var passed: bool = bool(positive_finite and exact_seating_silhouette and seating_contacts and back_readability and old_back_rejected and no_stone_intersections and clear_sector and ridge_meets and seam_no_gap_or_crossing and seam_volume_bounded and eaves_land and bounded_roof and opposed_faces and ridge_framed and eaves_aligned and bearing_contacts and gable_contact and collisions_ok)
	return {"passed": passed, "positiveFinite": positive_finite, "exactSeatingSilhouette": exact_seating_silhouette, "seatingContacts": seating_contacts, "backReadability": back_readability, "oldBackReadabilityRejected": old_back_rejected, "noStoneIntersections": no_stone_intersections, "clearApproachSector": clear_sector, "clearApproachRayCount": corridor_offsets.size(), "clearApproachHalfWidth": corridor_half_width, "stoneCount": stones.size(), "ridgeMeets": ridge_meets, "seamNoGapOrCrossing": seam_no_gap_or_crossing, "leftSeamProjection": left_seam_projection, "rightSeamProjection": right_seam_projection, "ridgeCapHalfWidth": ridge.size.x * 0.5, "seamVolumeBounded": seam_volume_bounded, "eavesLand": eaves_land, "eavesAligned": eaves_aligned, "bearingContacts": bearing_contacts, "bearingCount": bearings.size(), "leftOverhang": left_overhang, "rightOverhang": right_overhang, "roofRise": roof_rise, "boundedRoof": bounded_roof, "opposedFaces": opposed_faces, "ridgeFramed": ridge_framed, "gableContact": gable_contact, "collisionPolicy": collisions_ok}


func audit_commons_layout_overlap(seed: int) -> Dictionary:
	var castle = Castle.build(seed, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	if castle == null or not castle.recipe.get("castleGrammar") is Dictionary:
		return {"passed": false, "seed": seed, "reason": "missing_castle_grammar"}
	var grammar: Dictionary = (castle.recipe.castleGrammar as Dictionary).duplicate(true)
	var foundation_height := float(castle.recipe.get("foundationHeight", 0.62))
	var courtyard_depth := float(grammar.get("courtyardDepth", 84.0))
	var keep_depth := float(grammar.get("keepDepth", 28.0))
	var keep_center_z := courtyard_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14))
	var keep_front_z := keep_center_z - keep_depth * 0.5
	var front_z := -courtyard_depth * 0.5
	var layout := Composer.sample_urban_layout(seed, grammar, front_z, keep_front_z, foundation_height)
	var variation := float(seed % 19) / 100.0 - 0.09
	var fixture = Blueprint.new("commons_layout_%d" % seed, seed, "civic")
	fixture.set_recipe({"castleGrammar": grammar, "facadeApertures": {}, "urbanPoc": layout})
	var street_result: Dictionary = Composer.add_street_sequence(fixture, front_z, keep_front_z, foundation_height, variation, layout)
	if not bool(street_result.get("ready", false)):
		return {"passed": false, "seed": seed, "reason": "street_sequence_failed", "detail": street_result}
	var street_parts_before: Array = fixture.parts.map(func(part): return part.snapshot()).duplicate(true)
	var street_rooms_before: Array = fixture.rooms.duplicate(true)
	var street_recipe_before: Dictionary = fixture.recipe.duplicate(true)
	var quarter_result: Dictionary = Composer.add_civic_quarter(fixture, front_z, keep_front_z, foundation_height, variation, layout)
	if not bool(quarter_result.get("ready", false)):
		return {"passed": false, "seed": seed, "reason": "civic_quarter_failed", "detail": quarter_result}
	var commons_result: Dictionary = Composer.add_civic_commons(fixture, front_z, keep_front_z, foundation_height, variation, layout)
	if not bool(commons_result.get("ready", false)):
		return {"passed": false, "seed": seed, "reason": "civic_commons_failed", "detail": commons_result}
	var street_parts_exact: bool = fixture.parts.size() >= street_parts_before.size() and var_to_bytes(fixture.parts.slice(0, street_parts_before.size()).map(func(part): return part.snapshot())) == var_to_bytes(street_parts_before)
	var street_rooms_exact: bool = fixture.rooms.size() >= street_rooms_before.size() and var_to_bytes(fixture.rooms.slice(0, street_rooms_before.size())) == var_to_bytes(street_rooms_before)
	var street_recipe_exact := dictionary_preserves_existing_records(street_recipe_before, fixture.recipe)
	var street_recipe_reason := dictionary_preservation_failure(street_recipe_before, fixture.recipe)
	var street_byte_exact := street_parts_exact and street_rooms_exact and street_recipe_exact
	# Explicit synthetic oracle controls on detached copies of actual records.
	# Civic additions must never license changes to an existing street house.
	var changed_recipe: Dictionary = fixture.recipe.duplicate(true)
	var existing_prefix: String = String((street_recipe_before[STRUCTURAL_RECIPES_KEY] as Dictionary).keys().front())
	changed_recipe[STRUCTURAL_RECIPES_KEY][existing_prefix]["doorId"] = "synthetic_changed_existing_door"
	var changed_existing_rejected := not dictionary_preserves_existing_records(street_recipe_before, changed_recipe)
	var extra_recipe: Dictionary = fixture.recipe.duplicate(true)
	extra_recipe[STRUCTURAL_RECIPES_KEY]["synthetic_unexpected_house"] = {}
	var extra_declaration_rejected := not dictionary_preserves_existing_records(street_recipe_before, extra_recipe)
	var seating: Array = fixture.parts.filter(func(part): return String(part.semantic) == "citadel_civic_commons_seating")
	var commons: Array = fixture.parts.filter(func(part): return String(part.semantic).begins_with("citadel_civic_commons_"))
	var envelopes: Array = fixture.parts.filter(func(part): return is_collision_building_envelope(part))
	var new_overlaps := seating_envelope_overlaps(fixture, commons, envelopes)
	var commons_layout: Dictionary = Composer.civic_commons_layout(front_z, keep_front_z, foundation_height, layout)
	var row_geometry: Dictionary = commons_layout.rowGeometry as Dictionary
	var row_two_foundation_south_z := float((row_geometry.centers as Array)[2]) - (float((row_geometry.rowDepths as Array)[2]) + 0.28) * 0.5
	var row_two_foundation = fixture.parts.filter(func(part): return String(part.id) == "urban_row_02_right_foundation").front()
	var measured_foundation_south_z: float = world_bounds(row_two_foundation).position.z
	var back = seating.filter(func(part): return String(part.id) == "urban_civic_commons_bench_back").front()
	var measured_back_north_z: float = world_bounds(back).end.z
	var edge_clearance_ok := absf(row_two_foundation_south_z - measured_foundation_south_z) <= EPSILON and measured_back_north_z <= measured_foundation_south_z - 0.50 + EPSILON
	var commons_center: Vector3 = commons_layout.hub
	var boundary_delta_z := measured_foundation_south_z + 0.10 - measured_back_north_z
	var boundary_delta_x := world_bounds(row_two_foundation).get_center().x - world_bounds(back).get_center().x
	var boundary_delta_y := world_bounds(row_two_foundation).get_center().y - world_bounds(back).get_center().y
	var boundary_clone := clone_parts_translated(seating, Vector3(boundary_delta_x, boundary_delta_y, boundary_delta_z), "boundary_%d" % seed)
	var boundary_overlaps := seating_envelope_overlaps(fixture, boundary_clone, envelopes)
	var paving = fixture.parts.filter(func(part): return String(part.id) == "urban_civic_quarter_paving").front()
	var paving_bounds := world_bounds(paving)
	var commons_footprint: AABB = commons_layout.footprint
	var paving_margin := 0.25
	var expected_paving_north_z := keep_front_z + 8.0
	var expected_paving_south_z := minf(keep_front_z - 24.0, commons_footprint.position.z - paving_margin)
	var paving_formula_ok := is_equal_approx(paving_bounds.position.x, 19.0) and is_equal_approx(paving_bounds.size.x, 48.0) and absf(paving_bounds.end.z - expected_paving_north_z) <= EPSILON and absf(paving_bounds.position.z - expected_paving_south_z) <= EPSILON and absf(float(paving.size.z) - (expected_paving_north_z - expected_paving_south_z)) <= EPSILON and absf(float(paving.position.z) - (expected_paving_north_z + expected_paving_south_z) * 0.5) <= EPSILON
	var contained_by_paving := aabb_contains_aabb_xz_with_margin(paving_bounds, commons_footprint, paving_margin)
	var five_ray_corridor_clear := commons_approach_corridor_clear(commons, commons_center)
	var local_geometry_signature := commons_local_geometry_signature(commons, commons_center)
	var quarter_nonpaving_byte_exact := audit_civic_quarter_nonpaving_parity(front_z, keep_front_z, foundation_height, variation, layout)
	var passed := seating.size() == 6 and commons.size() == 14 and new_overlaps.is_empty() and edge_clearance_ok and not boundary_overlaps.is_empty() and contained_by_paving and paving_formula_ok and five_ray_corridor_clear and street_byte_exact and quarter_nonpaving_byte_exact and not local_geometry_signature.is_empty()
	return {"passed": passed, "seed": seed, "seatingCount": seating.size(), "commonsCount": commons.size(), "memberOrder": commons.map(func(part): return String(part.id)), "newOverlapIds": new_overlaps, "boundaryOverlapIds": boundary_overlaps, "negativeControlAuthority": "boundary_clone_at_generated_house_foundation", "envelopeCount": envelopes.size(), "frontZ": front_z, "keepFrontZ": keep_front_z, "rowTwoFoundationSouthZ": row_two_foundation_south_z, "measuredFoundationSouthZ": measured_foundation_south_z, "measuredBackNorthZ": measured_back_north_z, "edgeClearance": measured_foundation_south_z - measured_back_north_z, "edgeClearanceOk": edge_clearance_ok, "commonsHub": commons_center, "commonsFootprint": commons_footprint, "containedByCivicPaving": contained_by_paving, "pavingFormulaOk": paving_formula_ok, "pavingBounds": paving_bounds, "fiveRayApproachCorridorClear": five_ray_corridor_clear, "streetRecordsByteExact": street_byte_exact, "streetPartsByteExact": street_parts_exact, "streetRoomsByteExact": street_rooms_exact, "streetRecipeRecordsByteExact": street_recipe_exact, "streetRecipePreservationFailure": street_recipe_reason, "changedExistingDeclarationRejected": changed_existing_rejected, "unexpectedDeclarationAdditionRejected": extra_declaration_rejected, "expectedDeclarationAdditions": CIVIC_DECLARATION_ADDITIONS, "streetParityAuthority": "current_before_after_civic_insertion", "quarterNonpavingByteExact": quarter_nonpaving_byte_exact, "localGeometrySignature": local_geometry_signature}


func dictionary_preserves_existing_records(before: Dictionary, after: Dictionary) -> bool:
	return dictionary_preservation_failure(before, after).is_empty()


func dictionary_preservation_failure(before: Dictionary, after: Dictionary) -> String:
	# Only the two civic houses and their four facade declarations may be added.
	# The composers prepend keyed declarations but append ordered home records;
	# every pre-existing record retains exact bytes and relative order.
	if after.keys().map(func(key): return String(key)) != before.keys().map(func(key): return String(key)):
		return "top_level_keys_changed"
	for key in before:
		if CIVIC_DECLARATION_ADDITIONS.has(key):
			var additions: Array = CIVIC_DECLARATION_ADDITIONS[key]
			if before[key] is Dictionary and after[key] is Dictionary:
				var old_records: Dictionary = before[key]
				var new_records: Dictionary = after[key]
				var actual_key_strings: Array = new_records.keys().map(func(record_key): return String(record_key))
				var addition_strings: Array = additions.map(func(record_key): return String(record_key))
				var old_key_strings: Array = old_records.keys().map(func(record_key): return String(record_key))
				var actual_additions: Array = actual_key_strings.filter(func(record_key): return addition_strings.has(record_key))
				var retained_keys: Array = actual_key_strings.filter(func(record_key): return not addition_strings.has(record_key))
				if actual_key_strings.size() != old_key_strings.size() + addition_strings.size() \
						or actual_additions != addition_strings or retained_keys != old_key_strings:
					return "keyed_additions_changed:%s" % key
				for record_key in old_records:
					if var_to_bytes(old_records[record_key]) != var_to_bytes(new_records[record_key]):
						return "existing_keyed_record_changed:%s:%s" % [key, record_key]
			elif before[key] is Array and after[key] is Array:
				var old_array: Array = before[key]
				var new_array: Array = after[key]
				if new_array.size() != old_array.size() + additions.size() \
						or var_to_bytes(new_array.slice(0, old_array.size())) != var_to_bytes(old_array):
					return "ordered_addition_extent_changed:%s" % key
				var added_ids: Array = new_array.slice(old_array.size()).map(func(record): return String((record as Dictionary).get("id", "")))
				if var_to_bytes(added_ids) != var_to_bytes(additions):
					return "ordered_addition_ids_changed:%s" % key
			else:
				return "record_container_type_changed:%s" % key
		elif var_to_bytes(before[key]) != var_to_bytes(after[key]):
			return "unapproved_record_changed:%s" % key
	return ""


func audit_ground_level_street_policy() -> Dictionary:
	# Explicit spacious geometry keeps packing independent from this policy test.
	var spacious_front := -60.0
	var layout := complete_fixture_urban_layout()
	layout["rowCenterPhases"] = [0.50, 1.65, 2.80, 3.95]
	var current = Blueprint.new("clear_street_current", 1, "test")
	current.set_recipe({"facadeApertures": {}})
	var outcome: Dictionary = Composer.add_street_sequence(current, spacious_front, KEEP_FRONT_Z, BASE_Y, 0.0, layout)
	var structural: Array = current.parts.filter(func(part):
		var id := String(part.id)
		return id.begins_with("urban_row_") and (id.ends_with("_foundation") or id.contains("_upper_shell_") or id.contains("_stone_shell_")))
	var overlaps: Array[String] = []
	var axis_aligned := true
	for a_index in range(structural.size()):
		var a = structural[a_index]
		axis_aligned = axis_aligned and a.rotation == Vector3.ZERO
		for b_index in range(a_index + 1, structural.size()):
			var b = structural[b_index]
			if String(a.id).substr(0, 12) == String(b.id).substr(0, 12):
				continue
			var ab: AABB = world_bounds(a)
			var bb: AABB = world_bounds(b)
			if minf(ab.end.x, bb.end.x) > maxf(ab.position.x, bb.position.x) and minf(ab.end.z, bb.end.z) > maxf(ab.position.z, bb.position.z):
				overlaps.append("%s:%s" % [a.id, b.id])
	var foundation_parts: Array = current.parts.filter(func(part): return String(part.id).begins_with("urban_row_") and String(part.id).ends_with("_foundation"))
	var forbidden_parts: Array = current.parts.filter(func(part):
		var id:=String(part.id)
		return id.begins_with("urban_street_climb_") or id.begins_with("urban_market_plaza_retaining") or id.begins_with("urban_upper_lane") or id.begins_with("urban_terrace_"))
	var plaza_parts: Array = current.parts.filter(func(part): return String(part.id) == "urban_market_plaza")
	var plaza = plaza_parts.front() if not plaza_parts.is_empty() else null
	var clear: bool = axis_aligned and structural.size() == 56 and overlaps.is_empty()
	var foundations_preserved := foundation_parts.size() == 8
	var foundations_at_datum := foundation_parts.all(func(part): return is_equal_approx(part.position.y + part.size.y * 0.5, BASE_Y))
	var no_forbidden_parts := forbidden_parts.is_empty()
	var plaza_is_visual_ground_patch: bool = plaza != null and not plaza.collision_enabled and String(plaza.kind) == "ground_patch"
	var policy: bool = foundations_preserved and foundations_at_datum and no_forbidden_parts and plaza_is_visual_ground_patch
	return {"passed": clear and bool(outcome.get("ready", false)) and policy,
		"evidenceLevel": "synthetic_explicit_spacing_actual_recipe_boxes", "layout": layout,"frontZ":spacious_front,"keepFrontZ":KEEP_FRONT_Z,
		"structuralCount": structural.size(), "structuralAxisAligned": axis_aligned,
		"structuralOverlapIds": overlaps, "independentlyClear": clear,
		"currentReady": outcome.get("ready", false), "foundationCount":foundation_parts.size(),
		"foundationsPreserved": foundations_preserved, "foundationsAtDatum": foundations_at_datum,
		"forbiddenPartIds":forbidden_parts.map(func(part):return String(part.id)), "noForbiddenParts": no_forbidden_parts,
		"plazaFound": plaza != null, "plazaKind": String(plaza.kind) if plaza != null else "",
		"plazaCollisionEnabled": bool(plaza.collision_enabled) if plaza != null else true,
		"plazaIsVisualGroundPatch": plaza_is_visual_ground_patch, "policyPassed":policy}


func audit_commons_physical_intent_recipe() -> Dictionary:
	var fixture = Blueprint.new("commons_physical_intent", 208159, "civic")
	var result: Dictionary = Composer.add_civic_commons(fixture, FRONT_Z, KEEP_FRONT_Z, BASE_Y, 0.37, fixture_urban_layout())
	if not bool(result.get("ready", false)):
		return {"passed": false, "reason": "commons_recipe_failed"}
	var commons: Array = fixture.parts.filter(func(part): return String(part.semantic).begins_with("citadel_civic_commons_"))
	var seating: Array = commons.filter(func(part): return String(part.semantic) == "citadel_civic_commons_seating")
	var explicit_ids: Array = commons.filter(func(part): return part.recipe.has("physicalIntent")).map(func(part): return String(part.id))
	var explicit_roles: Array = commons.filter(func(part): return part.recipe.has("physicalIntent")).map(func(part): return String(part.recipe.get("commonsRole", "")))
	var physical_report: Dictionary = fixture.validate_physical_integrity()
	var failed_commons_ids: Array = (physical_report.get("checks", []) as Array).filter(func(row): return String(row.partId).begins_with("urban_civic_commons_") and not bool(row.passed)).map(func(row): return String(row.partId))
	var exact_ids := explicit_ids == COMMONS_VISUAL_BEAM_IDS
	var exact_roles := explicit_roles == ["seat_support", "seat_support", "back_support", "back_support"]
	var declarations_valid := commons.filter(func(part): return part.recipe.has("physicalIntent")).all(func(part): return String(part.recipe.get("physicalIntent", "")) == "visual_detail" and String(part.physical_intent) == "visual_detail")
	return {"passed": commons.size() == 14 and seating.size() == 6 and seating.all(func(part): return not bool(part.collision_enabled)) and exact_ids and exact_roles and declarations_valid and failed_commons_ids.is_empty(), "explicitIds": explicit_ids, "explicitRoles": explicit_roles, "failedCommonsIds": failed_commons_ids, "violations": physical_report.get("violations", [])}


func audit_unsupported_beam_controls() -> Dictionary:
	var facade_fixture = Blueprint.new("unsupported_facade_beam", 1, "contract")
	facade_fixture.add_part({"id": "unsupported_facade_beam", "kind": "beam", "material": "timber_beam", "position": Vector3(0.0, 2.0, 0.0), "size": Vector3(0.2, 1.0, 0.2), "collision": false, "semantic": "contract_structural_joinery", "physicalIntent": "facade_attachment", "recipe": {"physicalIntent": "facade_attachment"}})
	var facade_report: Dictionary = facade_fixture.validate_physical_integrity()
	var facade_check: Dictionary = (facade_report.get("checks", []) as Array).front() as Dictionary
	var facade_violation := "unsupported_facade_beam facade_attachment has no rooted declared anchor"
	var facade_control_passed := not bool(facade_check.get("passed", true)) and String(facade_check.get("intent", "")) == "facade_attachment" and (facade_check.get("anchorPartIds", []) as Array).is_empty() and not bool(facade_check.get("reachesGroundRoot", true)) and (facade_report.get("violations", []) as Array).has(facade_violation)
	var collision_fixture = Blueprint.new("collision_visual_detail_beam", 1, "contract")
	collision_fixture.add_part({"id": "collision_visual_detail_beam", "kind": "beam", "material": "timber_beam", "position": Vector3(0.0, 0.5, 0.0), "size": Vector3(0.2, 1.0, 0.2), "collision": true, "semantic": "contract_structural_joinery", "physicalIntent": "visual_detail", "recipe": {"physicalIntent": "visual_detail"}})
	var collision_report: Dictionary = collision_fixture.validate_physical_integrity()
	var collision_check: Dictionary = (collision_report.get("checks", []) as Array).front() as Dictionary
	var collision_violation := "collision_visual_detail_beam visual_detail must not create gameplay collision"
	var collision_control_passed := not bool(collision_check.get("passed", true)) and String(collision_check.get("intent", "")) == "visual_detail" and bool(collision_check.get("collisionEnabled", false)) and (collision_report.get("violations", []) as Array).has(collision_violation)
	return {"facadeControlPassed": facade_control_passed, "facadeCheck": facade_check, "facadeViolations": facade_report.get("violations", []), "collisionControlPassed": collision_control_passed, "collisionCheck": collision_check, "collisionViolations": collision_report.get("violations", [])}


func audit_street_row_geometry_contract() -> bool:
	var layout := fixture_urban_layout()
	var first: Dictionary = Composer.street_row_geometry(FRONT_Z, KEEP_FRONT_Z, layout)
	var second: Dictionary = Composer.street_row_geometry(FRONT_Z, KEEP_FRONT_Z, layout.duplicate(true))
	if not bool(first.get("ready", false)) or var_to_bytes(first) != var_to_bytes(second):
		return false
	var malformed_values := [{}, {"rowCenterPhases": [0.72, 1.68, 2.62]}, {"rowCenterPhases": [0.72, 1.68, NAN, 3.48]}, {"rowCenterPhases": [0.72, 1.68, "bad", 3.48]}]
	for malformed in malformed_values:
		if bool(Composer.street_row_geometry(FRONT_Z, KEEP_FRONT_Z, malformed).get("ready", false)):
			return false
	var malformed_street_cases: Array[Dictionary] = []
	var short_lane := complete_fixture_urban_layout()
	short_lane["laneCenters"] = [0.0, 1.8, 22.0]
	malformed_street_cases.append({"id": "short_lane", "layout": short_lane, "baseY": BASE_Y, "variation": 0.0})
	var wrong_width := complete_fixture_urban_layout()
	wrong_width["rowWidthBiases"] = [0.0, 0.0, 0.0, "bad"]
	malformed_street_cases.append({"id": "wrong_final_width", "layout": wrong_width, "baseY": BASE_Y, "variation": 0.0})
	var nan_width := complete_fixture_urban_layout()
	nan_width["rowWidthBiases"] = [0.0, 0.0, 0.0, NAN]
	malformed_street_cases.append({"id": "nan_final_width", "layout": nan_width, "baseY": BASE_Y, "variation": 0.0})
	var wrong_storey := complete_fixture_urban_layout()
	wrong_storey["rowStoreyBonuses"] = [0, 0, 0, "bad"]
	malformed_street_cases.append({"id": "wrong_final_storey", "layout": wrong_storey, "baseY": BASE_Y, "variation": 0.0})
	var nan_rise := complete_fixture_urban_layout()
	nan_rise["marketTerraceRise"] = NAN
	malformed_street_cases.append({"id": "nan_market_rise", "layout": nan_rise, "baseY": BASE_Y, "variation": 0.0})
	var artificial_rise := complete_fixture_urban_layout()
	artificial_rise["marketTerraceRise"] = 1.8
	malformed_street_cases.append({"id": "artificial_market_rise", "layout": artificial_rise, "baseY": BASE_Y, "variation": 0.0})
	var wrong_stalls := complete_fixture_urban_layout()
	wrong_stalls["marketStalls"] = "bad"
	malformed_street_cases.append({"id": "wrong_stall_collection", "layout": wrong_stalls, "baseY": BASE_Y, "variation": 0.0})
	var late_bad_stall := complete_fixture_urban_layout()
	var late_stalls: Array = (late_bad_stall.marketStalls as Array).duplicate(true)
	late_stalls.append({"offset": Vector3(NAN, 0.0, 0.0), "side": 1.0, "depth": -1.0, "variation": 0.0})
	late_bad_stall["marketStalls"] = late_stalls
	malformed_street_cases.append({"id": "nan_final_stall", "layout": late_bad_stall, "baseY": BASE_Y, "variation": 0.0})
	malformed_street_cases.append({"id": "nan_base", "layout": complete_fixture_urban_layout(), "baseY": NAN, "variation": 0.0})
	malformed_street_cases.append({"id": "nan_variation", "layout": complete_fixture_urban_layout(), "baseY": BASE_Y, "variation": NAN})
	for case_value in malformed_street_cases:
		var case: Dictionary = case_value as Dictionary
		if not street_sequence_rejects_atomically(String(case.id), case.layout as Dictionary, float(case.baseY), float(case.variation)):
			return false
	var malformed_layout := {"rowCenterPhases": [0.72, 1.68, NAN, 3.48]}
	if not civic_producer_rejects_atomically("commons_bad_layout", false, BASE_Y, 0.0, malformed_layout):
		return false
	if not civic_producer_rejects_atomically("quarter_bad_layout", true, BASE_Y, 0.0, malformed_layout):
		return false
	var valid_layout := complete_fixture_urban_layout()
	return civic_producer_rejects_atomically("commons_nan_base", false, NAN, 0.0, valid_layout) and civic_producer_rejects_atomically("quarter_nan_base", true, NAN, 0.0, valid_layout) and civic_producer_rejects_atomically("commons_nan_variation", false, BASE_Y, NAN, valid_layout) and civic_producer_rejects_atomically("quarter_nan_variation", true, BASE_Y, NAN, valid_layout)


func street_sequence_rejects_atomically(case_id: String, layout: Dictionary, base_y: float, variation: float) -> bool:
	var fixture = Blueprint.new("malformed_street_%s" % case_id, 1, "test")
	fixture.set_recipe({"sentinel": "unchanged"})
	var before := blueprint_content_signature(fixture)
	var outcome: Dictionary = Composer.add_street_sequence(fixture, FRONT_Z, KEEP_FRONT_Z, base_y, variation, layout)
	return not bool(outcome.get("ready", false)) and before == blueprint_content_signature(fixture)


func civic_producer_rejects_atomically(case_id: String, quarter: bool, base_y: float, variation: float, layout: Dictionary) -> bool:
	var fixture = Blueprint.new("malformed_civic_%s" % case_id, 1, "test")
	fixture.set_recipe({"sentinel": "unchanged"})
	var before := blueprint_content_signature(fixture)
	var outcome: Dictionary
	if quarter:
		outcome = Composer.add_civic_quarter(fixture, FRONT_Z, KEEP_FRONT_Z, base_y, variation, layout)
	else:
		outcome = Composer.add_civic_commons(fixture, FRONT_Z, KEEP_FRONT_Z, base_y, variation, layout)
	return not bool(outcome.get("ready", false)) and before == blueprint_content_signature(fixture)


func clone_parts_translated(parts: Array, translation: Vector3, fixture_id: String) -> Array:
	var clone_fixture = Blueprint.new(fixture_id, 1, "test")
	var clones: Array = []
	for part in parts:
		var snapshot: Dictionary = part.snapshot()
		snapshot["position"] = (snapshot.position as Vector3) + translation
		clones.append(clone_fixture.add_part(snapshot))
	return clones


func blueprint_content_signature(blueprint) -> String:
	var part_records: Array = blueprint.parts.map(func(part): return part.snapshot())
	var content := {"parts": part_records, "rooms": blueprint.rooms.duplicate(true), "recipe": blueprint.recipe.duplicate(true)}
	return Marshalls.raw_to_base64(var_to_bytes(content)).sha256_text()


func blueprint_content_signature_without_part(blueprint, excluded_id: String) -> String:
	var part_records: Array = blueprint.parts.filter(func(part): return String(part.id) != excluded_id).map(func(part): return part.snapshot())
	var content := {"parts": part_records, "rooms": blueprint.rooms.duplicate(true), "recipe": blueprint.recipe.duplicate(true)}
	return Marshalls.raw_to_base64(var_to_bytes(content)).sha256_text()


func commons_local_geometry_signature(commons: Array, hub: Vector3) -> String:
	if commons.size() != 14 or not hub.is_finite():
		return ""
	var records: Array[Dictionary] = []
	for part in commons:
		var local_position: Vector3 = (part.position as Vector3) - hub
		local_position = Vector3(snappedf(local_position.x, 0.0001), snappedf(local_position.y, 0.0001), snappedf(local_position.z, 0.0001))
		records.append({"id": String(part.id), "kind": String(part.kind), "material": String(part.material_id), "positionFromHub": local_position, "size": part.size, "rotation": part.rotation, "collision": bool(part.collision_enabled), "semantic": String(part.semantic)})
	records.sort_custom(func(a, b): return String(a.id) < String(b.id))
	return Marshalls.raw_to_base64(var_to_bytes(records)).sha256_text()


func audit_civic_quarter_nonpaving_parity(front_z: float, keep_front_z: float, base_y: float, variation: float, urban_layout: Dictionary) -> bool:
	var current = Blueprint.new("current_quarter_parity", 1, "test")
	current.set_recipe({"facadeApertures": {}})
	var current_outcome: Dictionary = Composer.add_civic_quarter(current, front_z, keep_front_z, base_y, variation, urban_layout)
	if not bool(current_outcome.get("ready", false)):
		return false
	var legacy = Blueprint.new("legacy_quarter_parity", 1, "test")
	legacy.set_recipe({"facadeApertures": {}})
	add_legacy_civic_quarter(legacy, keep_front_z, base_y, variation)
	return blueprint_content_signature_without_part(current, "urban_civic_quarter_paving") == blueprint_content_signature_without_part(legacy, "urban_civic_quarter_paving")


func add_legacy_civic_quarter(blueprint, keep_front_z: float, base_y: float, variation: float) -> void:
	Composer.add_part(blueprint, "urban_civic_quarter_paving", "foundation", "cobblestone", Vector3(43.0, base_y + 0.18, keep_front_z - 8.0), Vector3(48.0, 0.08, 32.0), {"collision": false, "variation": variation - 0.025, "semantic": "citadel_civic_quarter_paving", "pavingFamily": "civic_setts", "pavingRegion": "citadel_courtyard", "pavingHeading": "x"})
	var houses := [
		{"id": "urban_civic_house_east", "center": Vector3(43.0, 0.0, keep_front_z - 2.5), "width": 10.2, "depth": 12.0, "height": 9.3, "material": "painted_brick_ochre"},
		{"id": "urban_civic_house_wall", "center": Vector3(56.0, 0.0, keep_front_z - 14.0), "width": 8.8, "depth": 10.4, "height": 7.2, "material": "painted_brick_sage"}
	]
	for house_value in houses:
		var house: Dictionary = house_value as Dictionary
		Composer.add_street_house(blueprint, String(house.get("id", "urban_civic_house")), house.get("center", Vector3.ZERO) as Vector3, float(house.get("width", 8.0)), float(house.get("depth", 9.0)), float(house.get("height", 7.0)), -1.0, base_y, String(house.get("material", "painted_brick_cream")), variation + float(String(house.get("id", "house")).hash() % 17) * 0.003)
	for route_index in range(3):
		var route_z := keep_front_z - 13.5 + float(route_index) * 5.2
		Composer.add_traffic_wear(blueprint, "urban_civic_quarter_route_%02d" % route_index, Vector3(37.8, base_y + 0.232, route_z), Vector2(27.0, 1.84), 0.0, variation - 0.04 + float(route_index) * 0.011, "citadel_civic_route_wear")


func aabb_contains_aabb_xz_with_margin(outer: AABB, inner: AABB, margin: float) -> bool:
	return inner.position.x >= outer.position.x + margin - EPSILON and inner.end.x <= outer.end.x - margin + EPSILON and inner.position.z >= outer.position.z + margin - EPSILON and inner.end.z <= outer.end.z - margin + EPSILON


func commons_approach_corridor_clear(commons: Array, commons_center: Vector3) -> bool:
	var seating: Array = commons.filter(func(part): return String(part.semantic) == "citadel_civic_commons_seating")
	var stones: Array = commons.filter(func(part): return String(part.semantic) == "citadel_civic_commons_stone")
	if seating.size() != 6 or stones.size() != 8:
		return false
	var seat = seating.filter(func(part): return String(part.id) == "urban_civic_commons_bench").front()
	var approach_axis: Vector3 = seat.recipe.get("clearApproachAxis", Vector3.ZERO) as Vector3
	if not approach_axis.is_finite() or not is_equal_approx(approach_axis.length(), 1.0):
		return false
	var side_axis := Vector3(-approach_axis.z, 0.0, approach_axis.x)
	var half_width: float = float(seat.size.x) * 0.5 + 0.35
	for offset in [-half_width, -half_width * 0.5, 0.0, half_width * 0.5, half_width]:
		var start := commons_center + approach_axis * 5.0 + side_axis * float(offset) + Vector3.UP * 0.8
		var finish := (seat.position as Vector3) + side_axis * float(offset)
		for stone in stones:
			if world_bounds(stone).grow(0.18).intersects_segment(start, finish) != null:
				return false
	return true


func is_collision_building_envelope(part) -> bool:
	if part == null or not bool(part.collision_enabled) or String(part.semantic).begins_with("citadel_civic_commons_"):
		return false
	return true


func seating_envelope_overlaps(fixture, seating: Array, envelopes: Array) -> Array[String]:
	var overlaps: Array[String] = []
	for member in seating:
		for envelope in envelopes:
			if fixture.transformed_parts_overlap(member, envelope, 0.0):
				var member_bounds: AABB = fixture.transformed_part_bounds(member)
				var envelope_bounds: AABB = fixture.transformed_part_bounds(envelope)
				# A floor/foundation ending at the member's bottom is legitimate
				# underfoot contact. A foundation rising through the member is an
				# enclosing building volume and remains a failure witness.
				if String(envelope.kind) in ["foundation", "floor", "ground_patch", "ramp"] and envelope_bounds.end.y <= member_bounds.position.y + EPSILON:
					continue
				var witness := "%s:%s" % [String(member.id), String(envelope.id)]
				if not overlaps.has(witness):
					overlaps.append(witness)
	overlaps.sort()
	return overlaps


func back_exposes_review_rectangle(back, seat) -> bool:
	var seat_top: float = float(seat.position.y) + float(seat.size.y) * 0.5
	var sample_y: float = seat_top + 0.82
	var local_y: float = sample_y - float(back.position.y)
	var half: Vector3 = back.size * 0.5
	var local_samples: Array[Vector3] = [Vector3(-1.75, local_y, -half.z), Vector3(1.75, local_y, -half.z)]
	var transform := Transform3D(Basis.from_euler(back.rotation), back.position)
	var world_samples: Array[Vector3] = []
	for local_point in local_samples:
		if absf(local_point.x) > half.x + EPSILON or absf(local_point.y) > half.y + EPSILON or not is_equal_approx(local_point.z, -half.z):
			return false
		var world_point := transform * local_point
		if not world_point.is_finite() or world_point.y <= seat_top + EPSILON:
			return false
		world_samples.append(world_point)
	return world_samples.size() == 2 and world_samples[0].distance_to(world_samples[1]) >= 3.50 - EPSILON and float(back.position.y) + half.y - seat_top >= 1.10 - EPSILON


func roof_endpoints(part) -> Array[Vector3]:
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	return [transform * Vector3(-part.size.x * 0.5, 0.0, 0.0), transform * Vector3(part.size.x * 0.5, 0.0, 0.0)]


func world_bounds(part) -> AABB:
	var basis := Basis.from_euler(part.rotation)
	var extent := Vector3(absf(basis.x.x) * part.size.x + absf(basis.y.x) * part.size.y + absf(basis.z.x) * part.size.z, absf(basis.x.y) * part.size.x + absf(basis.y.y) * part.size.y + absf(basis.z.y) * part.size.z, absf(basis.x.z) * part.size.x + absf(basis.y.z) * part.size.y + absf(basis.z.z) * part.size.z)
	return AABB(part.position - extent * 0.5, extent)


func check(id: String, passed: bool) -> void:
	checks.append({"id": id, "passed": passed})
