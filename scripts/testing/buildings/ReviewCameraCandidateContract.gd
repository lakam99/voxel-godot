extends SceneTree

## Synthetic camera-selection contract. Standability/sightline dependencies are
## mocked explicitly; this does not prove a real pose, image or player access.
const Runner = preload("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")
const Visual = preload("res://scripts/testing/buildings/CitadelMarketRecipeVisual.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Composer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")

class SyntheticVisual extends Visual:
	var block_standoff := false
	func _ready() -> void: pass
	func review_line_is_clear(_from: Vector3, _target: Vector3) -> bool: return true
	func review_visual_line_is_clear(_from: Vector3, target: Vector3) -> bool:
		return not (block_standoff and target == Vector3(0, 1.5, 0.1))

class SyntheticRunner extends Runner:
	var support_allowed := true
	var support_calls := 0
	var synthetic_support_collider: Node
	var capsule_allowed := true
	var volume_allowed := true
	var physics_allowed := true
	var visual_allowed := true
	var near_composition_allowed := true
	func _ready() -> void: pass
	func exterior_support_for_review(horizontal: Vector3, _target_y: float, _minimum_y: float) -> Dictionary:
		support_calls += 1
		if not support_allowed:
			return {}
		if synthetic_support_collider == null:
			synthetic_support_collider = Node.new()
			synthetic_support_collider.name = "synthetic_support_narrow_domain"
			add_child(synthetic_support_collider)
		return {"position": Vector3(horizontal.x, 0, horizontal.z), "collider": synthetic_support_collider}
	func bounded_exterior_support_for_review(surface_candidate: Vector3, minimum_y: float) -> Dictionary:
		return exterior_support_for_review(surface_candidate, surface_candidate.y, minimum_y)
	func review_capsule_clearance(_feet: Vector3, _collider) -> Dictionary:
		return {"clear": capsule_allowed}
	func review_visual_volume_is_clear(_feet: Vector3) -> bool: return volume_allowed
	func review_line_is_clear(_from: Vector3, _target: Vector3) -> bool: return physics_allowed
	func review_visual_line_is_clear(_from: Vector3, _target: Vector3) -> bool: return visual_allowed
	func review_near_camera_visual_composition(_camera_position: Vector3, _target: Vector3) -> Dictionary:
		return {"clear": near_composition_allowed, "blockedSamples": 0 if near_composition_allowed else 8, "sampleCount": 8, "blockerIds": [] if near_composition_allowed else ["synthetic_foreground_blocker"]}
	func review_physics_line_blocker(_from: Vector3, _target: Vector3) -> Dictionary:
		return {} if physics_allowed else {"id": "synthetic_physics_blocker", "position": Vector3.ZERO}
	func review_visual_line_blocker(_from: Vector3, _target: Vector3) -> Dictionary:
		return {} if visual_allowed else {"id": "synthetic_visual_blocker", "position": Vector3.ZERO}

class CompositionOnlySyntheticRunner extends SyntheticRunner:
	# These unit cases isolate family/foreign-object exclusion, not framing.
	func generated_upper_framing_rejection(_camera_position: Vector3, _subject_bounds: AABB, _camera_target: Variant = null) -> String:
		return ""

class PerimeterChooserSyntheticRunner extends SyntheticRunner:
	var active_source: Dictionary = {}
	var predicate_counts: Dictionary = {}
	func reset_predicate_counts(source: Dictionary) -> void:
		active_source = source
		predicate_counts = {"support": 0, "capsule": 0, "visualVolume": 0, "physicsSightline": 0, "visualSightline": 0, "nearFieldComposition": 0, "subjectReadability": 0}
	func bounded_exterior_support_for_review(surface_candidate: Vector3, minimum_y: float) -> Dictionary:
		predicate_counts["support"] = int(predicate_counts.get("support", 0)) + 1
		return super.bounded_exterior_support_for_review(surface_candidate, minimum_y)
	func review_capsule_clearance(feet: Vector3, collider) -> Dictionary:
		predicate_counts["capsule"] = int(predicate_counts.get("capsule", 0)) + 1
		return super.review_capsule_clearance(feet, collider)
	func review_visual_volume_is_clear(feet: Vector3) -> bool:
		predicate_counts["visualVolume"] = int(predicate_counts.get("visualVolume", 0)) + 1
		return super.review_visual_volume_is_clear(feet)
	func review_line_is_clear(from: Vector3, target: Vector3) -> bool:
		predicate_counts["physicsSightline"] = int(predicate_counts.get("physicsSightline", 0)) + 1
		return super.review_line_is_clear(from, target)
	func review_visual_line_is_clear(from: Vector3, target: Vector3) -> bool:
		predicate_counts["visualSightline"] = int(predicate_counts.get("visualSightline", 0)) + 1
		return super.review_visual_line_is_clear(from, target)
	func review_near_camera_visual_composition(_camera_position: Vector3, _target: Vector3) -> Dictionary:
		predicate_counts["nearFieldComposition"] = int(predicate_counts.get("nearFieldComposition", 0)) + 1
		var clear := bool(active_source.get("compositionAllowed", true))
		return {"clear": clear, "blockedSamples": 0 if clear else 8, "sampleCount": 8, "blockerIds": [] if clear else ["synthetic_composition_blocker"]}
	func chooser_subject_readability_rejection(_camera_position: Vector3) -> String:
		predicate_counts["subjectReadability"] = int(predicate_counts.get("subjectReadability", 0)) + 1
		return "" if bool(active_source.get("readabilityAllowed", true)) else "generated_subject_family_not_readable"

class TelemetrySyntheticRunner extends Runner:
	var rejection_mode := ""
	var support_calls := 0
	func _ready() -> void: pass
	func exterior_support_for_review(horizontal: Vector3, _target_y: float, _minimum_y: float) -> Dictionary:
		support_calls += 1
		return {"position": Vector3(horizontal.x, 0.0, horizontal.z)}
	func bounded_exterior_support_for_review(surface_candidate: Vector3, _minimum_y: float) -> Dictionary:
		support_calls += 1
		return {"position": Vector3(surface_candidate.x, 0.0, surface_candidate.z)}
	func review_capsule_clearance(_feet: Vector3, _collider) -> Dictionary: return {"clear": true}
	func review_line_is_clear(_from: Vector3, _target: Vector3) -> bool: return true
	func review_visual_line_is_clear(_from: Vector3, _target: Vector3) -> bool: return true
	func review_visual_volume_is_clear(_feet: Vector3) -> bool:
		if rejection_mode != "visualVolume": return true
		_append_review_stage_rejection_evidence("visualVolume", {"subreason": "capsuleIntersection", "reason": "visual_volume", "selectedVisibleMember": "", "blockers": [_telemetry_provenance("foreign_blocker")]})
		return false
	func review_near_camera_visual_composition(_camera_position: Vector3, _target: Vector3) -> Dictionary:
		if rejection_mode != "nearFieldComposition": return {"clear": true, "blockedSamples": 0, "sampleCount": 8, "blockerIds": []}
		_append_review_stage_rejection_evidence("nearFieldComposition", {"subreason": "blockedNearFrustum", "reason": "near_field_composition", "selectedVisibleMember": "", "blockedSamples": 8, "sampleCount": 8, "blockers": [_telemetry_provenance("family_blocker")]})
		return {"clear": false, "blockedSamples": 8, "sampleCount": 8, "blockerIds": ["family_blocker"]}
	func generated_subject_readability_rejection(_camera_position: Vector3, _subject_ids: Array, _camera_target: Variant = null) -> String:
		if rejection_mode != "subjectRequirements": return ""
		_append_review_stage_rejection_evidence("subjectRequirements", {"subreason": "nearCameraComposition", "reason": "near_camera_visual_volume", "selectedVisibleMember": "family_blocker", "blockers": [_telemetry_provenance("family_blocker"), _telemetry_provenance("foreign_blocker")]})
		return "near_camera_visual_volume"
	func _telemetry_provenance(id: String) -> Dictionary:
		var record: Dictionary = (_review_visual_snapshot.get("byId", {}) as Dictionary).get(id, {}) as Dictionary
		return _review_record_rejection_provenance(record, _active_review_declared_subject_ids())

class NoTelemetrySyntheticRunner extends TelemetrySyntheticRunner:
	func _append_review_stage_rejection_evidence(_stage: String, _row: Dictionary) -> void: pass

class RealTelemetryRunner extends Runner:
	var support_calls := 0
	func _ready() -> void: pass
	func exterior_support_for_review(horizontal: Vector3, _target_y: float, _minimum_y: float) -> Dictionary:
		support_calls += 1
		return {"position": Vector3(horizontal.x, 0.0, horizontal.z)}
	func bounded_exterior_support_for_review(surface_candidate: Vector3, _minimum_y: float) -> Dictionary:
		support_calls += 1
		return {"position": Vector3(surface_candidate.x, 0.0, surface_candidate.z)}
	func review_capsule_clearance(_feet: Vector3, _collider) -> Dictionary: return {"clear": true}
	func review_line_is_clear(_from: Vector3, _target: Vector3) -> bool: return true
	func review_visual_line_is_clear(_from: Vector3, _target: Vector3) -> bool: return true

class RealNoTelemetryRunner extends RealTelemetryRunner:
	func _append_review_stage_rejection_evidence(_stage: String, _row: Dictionary) -> void: pass

class SubjectSubtypeSyntheticRunner extends RealTelemetryRunner:
	var subject_subtype := ""
	func review_near_camera_visual_composition(_camera_position: Vector3, _target: Vector3) -> Dictionary:
		return {"clear": true, "blockedSamples": 0, "sampleCount": 8, "blockerIds": []}
	func generated_upper_framing_rejection(_camera_position: Vector3, _subject_bounds: AABB, _camera_target: Variant = null) -> String:
		return "upper_frame_clipped" if subject_subtype == "upperFrame" else ""
	func generated_subject_visible_surface_evidence(_camera_position: Vector3, _part_ids: Array) -> Dictionary:
		if subject_subtype == "noReadableMember":
			return {"valid": false, "reason": "no_published_visible_subject_member"}
		return {"valid": true, "partId": "family_blocker", "surface": Vector3(0.0, 1.5, -0.25)}

class CompositionContextReadabilityRunner extends RealTelemetryRunner:
	func generated_upper_framing_rejection(_camera_position: Vector3, _subject_bounds: AABB, _camera_target: Variant = null) -> String:
		return ""
	func generated_subject_visible_surface_evidence(_camera_position: Vector3, part_ids: Array) -> Dictionary:
		return {"valid": not part_ids.is_empty(), "partId": String(part_ids[0]) if not part_ids.is_empty() else "", "surface": Vector3(0.0, 1.5, -0.25)}

class RequiredFamilyVisibilityRunner extends CompositionContextReadabilityRunner:
	var requested_visible_ids: Array = []
	var force_upper_clip := false
	func generated_upper_framing_rejection(_camera_position: Vector3, _subject_bounds: AABB, _camera_target: Variant = null) -> String:
		return "upper_frame_clipped" if force_upper_clip else ""
	func generated_part_visible_surface(_camera_position: Vector3, part_id: String) -> Vector3:
		requested_visible_ids.append(part_id)
		return Vector3.INF if part_id == "urban_civic_roof_right" else Vector3(0.0, 1.2, 0.0)
	func generated_cached_near_camera_visual_composition_rejection(_camera_position: Vector3, _subject_bounds: AABB, _subject_ids: Array, _selected_visible_member: String = "") -> String:
		return ""

class FamilyAuditSyntheticRunner extends SyntheticRunner:
	func exterior_support_for_review(horizontal: Vector3, target_y: float, minimum_y: float) -> Dictionary:
		var support: Dictionary = super.exterior_support_for_review(horizontal, target_y, minimum_y)
		if support.is_empty():
			return support
		var position: Vector3 = support.get("position", Vector3.ZERO) as Vector3
		position.y = maxf(0.0, horizontal.y - 1.58)
		support["position"] = position
		return support
	func generated_cached_near_camera_visual_composition_rejection(_camera_position: Vector3, _subject_bounds: AABB, _subject_ids: Array, _selected_visible_member: String = "") -> String:
		return ""

var _calls := 0
var _visible_surface_calls := 0
var _checks: Array = []
var _integration_points: Array = []

func _initialize() -> void: call_deferred("_run")

func _solve(r, predicate: Callable = Callable()) -> Dictionary:
	return r.solve_exterior_review_pose(Vector3(0, 1.58, 0), 5.0, 6.0, 2.0, 0, -INF, predicate)

func _run() -> void:
	var path := OS.get_environment("VOXEL_REVIEW_CAMERA_CANDIDATE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path):
		quit(2)
		return
	var r := SyntheticRunner.new()
	var original := _solve(r)
	_check("legacy_default_ready", original.ok)
	_calls = 0
	var accepted := _solve(r, _accept)
	_check("accept_preserves_first_pose", accepted.ok and accepted.cameraPosition == original.cameraPosition and _calls == 1)
	_calls = 0
	var refined := _solve(r, _reject_first)
	_check("reject_first_selects_next_original_candidate", refined.ok and refined.cameraPosition != original.cameraPosition and _calls == 2 and refined.rejectedCandidates.subjectRequirements == 1)
	_check("successful_selection_retains_rejection_reason", refined.rejectionExamples.size() == 1 and refined.rejectionExamples[0].reason == "subject:hidden_family")
	_calls = 0
	var rejected := _solve(r, _reject)
	_check("all_rejected_remains_failed_bounded_64", not rejected.ok and _calls == 64 and rejected.rejectedCandidates.subjectRequirements == 64 and rejected.rejectionExamples.size() == 8)
	_calls = 0
	var invalid := _solve(r, _invalid)
	_check("invalid_predicate_result_fails_closed", not invalid.ok and _calls == 64)
	for property in ["support_allowed", "capsule_allowed", "volume_allowed", "physics_allowed", "visual_allowed", "near_composition_allowed"]:
		r.set(property, false)
		_calls = 0
		var baseline_rejected := _solve(r, _accept)
		_check("predicate_cannot_waive_" + property, not baseline_rejected.ok and _calls == 0)
		r.set(property, true)
	_calls = 0
	var unframed: Dictionary = r.solve_exterior_review_pose(Vector3(0, 1.58, 0), 5.0, 6.0, 0.01, 0, -INF, _accept)
	_check("predicate_cannot_waive_frame_coverage", not unframed.ok and _calls == 0 and unframed.rejectedCandidates.frameCoverage == 64)
	r.free()
	_generated_exterior_evidence_checks()
	_generated_subject_derivation_checks()
	_critic_camera_controls()
	_underfoot_support_classification_checks()
	_terminal_predicate_checks()
	var passed := _checks.all(func(row): return row.passed)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify({"passed": passed, "checks": _checks,
		"pendingIntegrationPoints": _integration_points,
		"evidenceLevel": "synthetic_mocked_camera_selection_contract",
		"doesNotProve": "No real support, collision, visibility, scene publication, images or gameplay acceptance."}, "\t"))
	file.close()
	print("Camera candidate contract: %s (%d checks)" % ["PASS" if passed else "FAIL", _checks.size()])
	quit(0 if passed else 1)

func _generated_exterior_evidence_checks() -> void:
	var r := SyntheticRunner.new()
	root.add_child(r)
	var camera := Camera3D.new()
	r.add_child(camera)
	var target := Vector3(0.0, 1.58, 0.0)
	var camera_position := Vector3(0.0, 1.58, 6.0)
	camera.position = camera_position
	var pose := {
		"ok": true,
		"cameraPosition": camera_position,
		"supportPosition": Vector3(0.0, 0.055, 6.0),
		"subjectFrameFraction": 0.42,
		"rejectedCandidates": {},
		"rejectionExamples": []
	}
	# Build the fixture through the production runner's generated-exterior view
	# policy, then remove one required evidence fact at a time. The contract does
	# not reproduce the acceptance predicate locally.
	var valid: Dictionary = r.make_exterior_review_view_from_pose(
		"synthetic_generated_exterior", "generated exterior", target, 10.0, pose)
	var baseline: Dictionary = r.audit_review_camera_contract(valid, camera)
	_check("generated_exterior_complete_evidence_passes_fixture", baseline.passed)

	var missing_pose := valid.duplicate(true)
	missing_pose.erase("cameraPoseOk")
	var missing_pose_audit: Dictionary = r.audit_review_camera_contract(missing_pose, camera)
	_check("generated_exterior_missing_camera_pose_fails_closed", not missing_pose_audit.passed and not missing_pose_audit.cameraPose.ok)

	var missing_frame := valid.duplicate(true)
	missing_frame.erase("cameraPoseFrameFraction")
	var missing_frame_audit: Dictionary = r.audit_review_camera_contract(missing_frame, camera)
	_check("generated_exterior_missing_frame_evidence_fails_closed", not missing_frame_audit.passed and missing_frame_audit.subjectFrameFraction <= 0.0)

	var nonpositive_frame := valid.duplicate(true)
	nonpositive_frame["cameraPoseFrameFraction"] = 0.0
	var nonpositive_frame_audit: Dictionary = r.audit_review_camera_contract(nonpositive_frame, camera)
	_check("generated_exterior_nonpositive_frame_evidence_fails_closed", not nonpositive_frame_audit.passed)
	var dominant_frame := valid.duplicate(true)
	dominant_frame["cameraPoseFrameFraction"] = 1.01
	var dominant_frame_audit: Dictionary = r.audit_review_camera_contract(dominant_frame, camera)
	_check("generated_exterior_dominant_frame_evidence_fails_closed", not dominant_frame_audit.passed)

	r.physics_allowed = false
	var blocked_sightline_audit: Dictionary = r.audit_review_camera_contract(valid, camera)
	_check("generated_exterior_blocked_sightline_fails_closed", not blocked_sightline_audit.targetClear and not blocked_sightline_audit.passed)
	r.physics_allowed = true

	var optional_clear := valid.duplicate(true)
	optional_clear["requiresClear"] = false
	var optional_clear_audit: Dictionary = r.audit_review_camera_contract(optional_clear, camera)
	_check("generated_exterior_requires_clear_false_fails_closed", not optional_clear_audit.passed)
	r.free()

func _generated_subject_derivation_checks() -> void:
	var r := SyntheticRunner.new()
	r.blueprint = Blueprint.new("synthetic_generated_camera_subjects", 2, "test")
	r.blueprint.add_part({"id": "public_support", "kind": "foundation", "material": "stone_foundation", "position": Vector3(0.0, 0.31, 4.0), "size": Vector3(40.0, 0.62, 40.0), "collision": true})
	r.blueprint.add_part({"id": "urban_market_counter_b_00", "kind": "decor", "material": "timber_board", "position": Vector3(1.0, 1.50, 0.0), "size": Vector3(2.0, 0.20, 0.8), "collision": false})
	r.blueprint.add_part({"id": "urban_market_counter_a_00", "kind": "decor", "material": "timber_board", "position": Vector3(0.0, 1.50, 0.0), "size": Vector3(2.0, 0.20, 0.8), "collision": false})
	r.blueprint.add_part({"id": "urban_market_canopy_a", "kind": "decor", "material": "cloth", "position": Vector3(0.0, 3.20, 0.0), "size": Vector3(3.4, 0.12, 2.0), "collision": false})
	r.blueprint.add_part({"id": "urban_perimeter_alley_-1_00", "kind": "foundation", "material": "worn_cobble", "position": Vector3(-5.0, 0.78, 8.0), "size": Vector3(2.1, 0.10, 6.0), "collision": false, "semantic": "citadel_perimeter_alley"})
	r.blueprint.add_part({"id": "urban_perimeter_west_00_wall", "kind": "wall", "material": "brick", "position": Vector3(-8.0, 3.60, 8.0), "size": Vector3(0.8, 6.0, 7.0), "collision": true, "semantic": "citadel_urban_facade"})
	r.blueprint.add_part({"id": "urban_perimeter_aaa_closer_detail", "kind": "decor", "material": "timber", "position": Vector3(-5.2, 1.2, 8.0), "size": Vector3(0.2, 0.4, 0.2), "collision": false, "semantic": "citadel_household_sign"})
	r.blueprint.recipe["urbanPoc"] = {"marketTerraceRise": 99.0, "treePlacements": [
		{"id": "tree_far", "position": Vector3(18.0, 0.81, 0.0)},
		{"id": "tree_near", "position": Vector3(3.0, 0.81, 0.0)}]}
	for part in r.blueprint.parts:
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	var market: Dictionary = r.market_review_subject()
	_check("generated_market_subject_uses_final_members_and_real_support", market.valid and market.supportId == "public_support" and is_equal_approx(float(market.minimumSupportY), 0.44) and float(market.minimumSupportY) < 1.0)
	var tree: Dictionary = r.green_market_tree_subject(market)
	_check("green_market_tree_uses_nearest_final_market_subject_not_array_zero", tree.valid and tree.treeId == "tree_near" and tree.supportId == "public_support")
	var original_tree: Dictionary = tree.duplicate(true)
	(r.blueprint.recipe.urbanPoc.treePlacements as Array).reverse()
	_check("green_market_tree_selection_is_iteration_order_independent", var_to_bytes(original_tree) == var_to_bytes(r.green_market_tree_subject(market)))
	var perimeter: Dictionary = r.perimeter_lane_review_subject()
	_check("perimeter_subject_binds_generated_alley_facade_and_support", perimeter.valid and perimeter.alleyId == "urban_perimeter_alley_-1_00" and perimeter.facadeId == "urban_perimeter_west_00_wall" and perimeter.supportId == "public_support")
	_check("absent_gate_subject_fails_before_world_origin_pose_search", not bool(r.gate_threshold_review_view().cameraPoseOk) and r.gate_threshold_review_view().cameraPoseReason == "missing generated gate door subject")
	r.free()
	var unsupported := SyntheticRunner.new()
	unsupported.blueprint = Blueprint.new("synthetic_nearby_not_underlying", 3, "test")
	unsupported.blueprint.add_part({"id": "nearby_support", "kind": "foundation", "material": "stone", "position": Vector3(-1.8, 0.31, 0.0), "size": Vector3(1.0, 0.62, 4.0), "collision": true})
	unsupported.blueprint.add_part({"id": "urban_perimeter_alley_-1_00", "kind": "foundation", "material": "cobble", "position": Vector3(0.0, 0.78, 0.0), "size": Vector3(2.1, 0.10, 4.0), "collision": false, "semantic": "citadel_perimeter_alley"})
	unsupported.blueprint.add_part({"id": "urban_perimeter_west_00_wall", "kind": "wall", "material": "brick", "position": Vector3(-2.0, 3.0, 0.0), "size": Vector3(0.8, 5.0, 4.0), "collision": true, "semantic": "citadel_urban_facade"})
	unsupported.build_review_visual_snapshot()
	_check("nearby_but_not_underlying_perimeter_support_fails_closed", not bool(unsupported.perimeter_lane_review_subject().get("valid", false)))
	unsupported.free()

func _critic_camera_controls() -> void:
	_rejection_telemetry_controls()
	_civic_generated_subject_family_controls()
	_aligned_perimeter_composition_context_controls()
	_reversed_source_order_control()
	_blocked_first_perimeter_segment_control()
	_visual_composition_negative_controls()
	_bounded_perimeter_chooser_controls()
	var r := SyntheticRunner.new()
	root.add_child(r)
	r.blueprint = Blueprint.new("synthetic_missing_review_subject", 5, "test")
	var missing: Dictionary = r.make_part_review_view("missing_subject", "missing generated subject", "absent_subject_", "absent_semantic", 12.0, 4.0, 8.0, 2.0, 0)
	_check("missing_generated_subject_fails_before_pose_search", not missing.cameraPoseOk and missing.cameraPoseReason == "missing generated review subject" and missing.position == Vector3.ZERO)

	r.visual_allowed = false
	_visible_surface_calls = 0
	var blocked_job = r.begin_exterior_review_pose(Vector3(0.0, 1.58, 0.0), 5.0, 6.0, 2.0, 0, -INF, Callable(), _visible_surface_target)
	var blocked: Dictionary = r.advance_exterior_review_pose(blocked_job, 64)
	var blocked_examples: Array = blocked.pose.get("rejectionExamples", []) as Array
	_check("blocked_visible_surface_callback_has_no_valid_pose", blocked.complete and not blocked.pose.ok and _visible_surface_calls == 64 and blocked.pose.rejectedCandidates.visualSightline == 64)
	_check("blocked_visible_surface_records_blocker_provenance", blocked_examples.size() == 8 and blocked_examples[0].reason == "visual_sightline" and blocked_examples[0].blocker.id == "synthetic_visual_blocker" and blocked_examples[0].blocker.position is Vector3 and (blocked_examples[0].blocker.position as Vector3).is_finite())

	r.visual_allowed = true
	r.support_calls = 0
	var narrow_job = r.begin_exterior_review_pose_from_candidates(Vector3(0.0, 1.58, 0.0), [Vector3(0.0, 1.58, -6.0)], 2.0, -INF)
	var narrow: Dictionary = r.advance_exterior_review_pose(narrow_job, 64)
	_check("narrow_support_candidate_domain_selects_only_valid_pose", narrow.complete and narrow.pose.ok and r.support_calls == 1 and narrow.totalCandidatesEvaluated == 1 and narrow.pose.supportCollider == "synthetic_support_narrow_domain")
	_generated_view_telemetry_control(r, narrow)

	r.support_allowed = false
	r.support_calls = 0
	var empty_job = r.begin_exterior_review_pose(Vector3(0.0, 1.58, 0.0), 5.0, 6.0, 2.0, 0, -INF)
	var empty: Dictionary = r.advance_exterior_review_pose(empty_job, 64)
	_check("no_valid_pose_exhausts_bounded_domain_with_reason", empty.complete and not empty.pose.ok and empty.pose.reason == "no_standable_exterior_camera_pose" and empty.totalCandidatesEvaluated == 64 and r.support_calls == 64 and empty.pose.rejectedCandidates.support == 64)
	r.free()


func _civic_generated_subject_family_controls() -> void:
	var forward := _civic_family_fixture(false)
	var reversed := _civic_family_fixture(true)
	var roof_context_semantics := ["citadel_civic_landmark", "citadel_civic_blind_recess", "citadel_civic_banner", "citadel_civic_roof_bearing", "citadel_civic_roof_framing", "citadel_civic_gable_closure"]
	var expected_roof_context: Array[String] = forward.civic_roof_context_part_ids()
	var roof_forward: Dictionary = forward.generated_review_subject_family("citadel_civic_roof", "urban_civic_roof_", 2, [], roof_context_semantics, "roof", expected_roof_context)
	var roof_reversed: Dictionary = reversed.generated_review_subject_family("citadel_civic_roof", "urban_civic_roof_", 2, [], roof_context_semantics, "roof", expected_roof_context)
	var commons_forward: Dictionary = forward.generated_review_subject_family("citadel_civic_commons_seating", "urban_civic_commons_bench", 6, ["urban_civic_commons_bench", "urban_civic_commons_bench_back"], ["citadel_civic_commons_stone"], "decor")
	var commons_reversed: Dictionary = reversed.generated_review_subject_family("citadel_civic_commons_seating", "urban_civic_commons_bench", 6, ["urban_civic_commons_bench", "urban_civic_commons_bench_back"], ["citadel_civic_commons_stone"], "decor")
	var expected_roof_composition: Array = expected_roof_context.duplicate()
	expected_roof_composition.append_array(["urban_civic_roof_left", "urban_civic_roof_right"])
	expected_roof_composition.sort()
	_check("civic_roof_family_uses_exact_sorted_roof_members", roof_forward.valid and roof_forward.subjectIds == ["urban_civic_roof_left", "urban_civic_roof_right"] and roof_forward.requiredVisiblePartIds == roof_forward.subjectIds and not (roof_forward.requiredVisiblePartIds as Array).has("urban_civic_tower"))
	_check("civic_roof_context_is_exact_complete_and_never_promoted", roof_forward.valid and roof_forward.compositionSubjectIds == expected_roof_composition and expected_roof_context.all(func(id): return (roof_forward.compositionSubjectIds as Array).has(id) and not (roof_forward.subjectIds as Array).has(id) and not (roof_forward.requiredVisiblePartIds as Array).has(id)))
	_check("civic_commons_family_requires_seat_and_back_not_stones_or_wall", commons_forward.valid and commons_forward.subjectIds == ["urban_civic_commons_bench", "urban_civic_commons_bench_back", "urban_civic_commons_bench_back_post_-1", "urban_civic_commons_bench_back_post_1", "urban_civic_commons_bench_leg_-1", "urban_civic_commons_bench_leg_1"] and commons_forward.requiredVisiblePartIds == ["urban_civic_commons_bench", "urban_civic_commons_bench_back"] and (commons_forward.compositionSubjectIds as Array).has("urban_civic_commons_stone_00") and not (commons_forward.requiredVisiblePartIds as Array).has("urban_civic_commons_stone_00"))
	_check("civic_family_derivation_is_reversed_source_order_byte_stable", var_to_bytes(roof_forward) == var_to_bytes(roof_reversed) and var_to_bytes(commons_forward) == var_to_bytes(commons_reversed))
	_check("commons_uses_actual_family_radius_not_legacy_inflated_fallback", float(commons_forward.get("subjectRadius", 99.0)) < 3.0 and is_equal_approx(float(commons_forward.get("subjectRadius", 0.0)), forward.generated_subject_frame_radius(commons_forward.bounds, 0.01)))
	var exact_seat_back_bounds := forward.generated_subject_bounds(["urban_civic_commons_bench", "urban_civic_commons_bench_back"])
	_check("commons_camera_target_is_inside_exact_seat_back_bounds_and_reversed_stable", exact_seat_back_bounds.has_point(commons_forward.focus) and commons_forward.focus == exact_seat_back_bounds.get_center() and commons_forward.focus == commons_reversed.focus)
	var missing := forward.generated_review_subject_family("missing_semantic", "missing_", 1, [], [], "decor")
	var count_mismatch := forward.generated_review_subject_family("citadel_civic_roof", "urban_civic_roof_", 3, [], [], "roof")
	var ambiguous := _ambiguous_civic_family_fixture()
	var ambiguous_result := ambiguous.generated_review_subject_family("citadel_civic_roof", "urban_civic_roof_", 2, [], [], "roof")
	_check("missing_count_mismatch_and_ambiguous_civic_families_fail_closed", not missing.valid and missing.reason == "invalid_generated_subject_family_count" and not count_mismatch.valid and count_mismatch.reason == "invalid_generated_subject_family_count" and not ambiguous_result.valid and ambiguous_result.reason == "ambiguous_generated_subject_family")
	var missing_context_fixture := _civic_family_fixture(false, "missing_ridge")
	var extra_context_fixture := _civic_family_fixture(false, "extra_gable")
	var missing_context := missing_context_fixture.generated_review_subject_family("citadel_civic_roof", "urban_civic_roof_", 2, [], roof_context_semantics, "roof", expected_roof_context)
	var extra_context := extra_context_fixture.generated_review_subject_family("citadel_civic_roof", "urban_civic_roof_", 2, [], roof_context_semantics, "roof", expected_roof_context)
	_check("missing_or_foreign_promised_roof_context_fails_closed", not missing_context.valid and missing_context.reason == "invalid_generated_subject_family_context" and not extra_context.valid and extra_context.reason == "invalid_generated_subject_family_context")

	var visibility := RequiredFamilyVisibilityRunner.new()
	visibility.blueprint = forward.blueprint
	visibility._review_visual_snapshot = forward._review_visual_snapshot
	var family_reason := visibility.generated_family_readability_rejection(Vector3(0.0, 1.58, -6.0), commons_forward.subjectIds, commons_forward.requiredVisiblePartIds, commons_forward.compositionSubjectIds)
	_check("wall_and_stones_cannot_satisfy_commons_visibility", family_reason.is_empty() and visibility.requested_visible_ids == ["urban_civic_commons_bench", "urban_civic_commons_bench_back"])
	visibility.force_upper_clip = true
	var clipped_reason := visibility.generated_family_readability_rejection(Vector3(0.0, 1.58, -6.0), roof_forward.subjectIds, roof_forward.requiredVisiblePartIds, roof_forward.compositionSubjectIds)
	_check("roof_family_clipping_rejects_before_wall_context_can_satisfy", clipped_reason == "upper_frame_clipped")
	visibility.force_upper_clip = false
	visibility.requested_visible_ids.clear()
	var hidden_half_reason := visibility.generated_family_readability_rejection(Vector3(0.0, 1.58, -6.0), roof_forward.subjectIds, roof_forward.requiredVisiblePartIds, roof_forward.compositionSubjectIds)
	_check("one_visible_one_hidden_roof_half_rejects_and_names_member", hidden_half_reason == "generated_required_subject_not_readable:urban_civic_roof_right" and visibility.requested_visible_ids == ["urban_civic_roof_left", "urban_civic_roof_right"])
	var invalid_required := visibility.generated_family_readability_rejection(Vector3(0.0, 1.58, -6.0), commons_forward.subjectIds, ["urban_civic_commons_stone_00"], commons_forward.compositionSubjectIds)
	_check("composition_member_cannot_be_promoted_to_required_subject", invalid_required == "ambiguous_subject_family")
	_civic_replacement_preserves_other_eight_bytes(forward)
	_civic_family_audit_serialization_controls(forward, roof_forward, commons_forward)
	visibility.free()
	ambiguous.free()
	missing_context_fixture.free()
	extra_context_fixture.free()
	forward.free()
	reversed.free()


func _civic_family_fixture(reverse_parts: bool, context_mutation: String = "") -> SyntheticRunner:
	var r := SyntheticRunner.new()
	r.blueprint = Blueprint.new("synthetic_civic_family", 81, "test")
	var source := Blueprint.new("recipe_shaped_civic_family", 81, "test")
	Composer.add_civic_landmark(source, Vector3.ZERO, 0.0, 0.37)
	Composer.add_civic_commons(source, -42.0, -5.018, 0.62, 0.37, {"rowCenterPhases": [0.72, 1.68, 2.62, 3.48]})
	var records: Array = source.parts.map(func(part): return part.snapshot())
	if context_mutation == "missing_ridge":
		records = records.filter(func(record): return String(record.id) != "urban_civic_roof_ridge")
	elif context_mutation == "extra_gable":
		records.append({"id": "foreign_civic_roof_gable", "kind": "wall", "material": "brick", "position": Vector3.ZERO, "size": Vector3.ONE, "collision": true, "semantic": "citadel_civic_gable_closure"})
	if reverse_parts:
		records.reverse()
	for record in records:
		var part = r.blueprint.add_part(record)
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	return r


func _civic_replacement_preserves_other_eight_bytes(r: SyntheticRunner) -> void:
	var ids := ["outer_approach", "gate_threshold", "inner_lane", "market_ground", "market_release", "civic_overview", "civic_commons", "perimeter_lane", "green_market_square", "tree_contact_paving"]
	var baseline: Array[Dictionary] = []
	for index in range(ids.size()):
		baseline.append({"id": ids[index], "source": "baseline_%02d" % index, "candidateBytes": PackedByteArray([index, index + 1])})
	var before: Array[PackedByteArray] = []
	for view in baseline:
		before.append(var_to_bytes(view))
	var civic_overview := {"id": "civic_overview", "source": "generated_roof_family"}
	var civic_commons := {"id": "civic_commons", "source": "generated_seating_family"}
	var replaced: Array[Dictionary] = r.replace_civic_review_views(baseline, civic_overview, civic_commons)
	var preserved := replaced.size() == baseline.size()
	for index in range(replaced.size()):
		if index not in [5, 6] and var_to_bytes(replaced[index]) != before[index]:
			preserved = false
	_check("civic_view_assembly_changes_only_two_and_preserves_other_eight_bytes", preserved and replaced[5] == civic_overview and replaced[6] == civic_commons)
	var malformed := baseline.duplicate(true)
	malformed[7]["id"] = "wrong_perimeter_id"
	_check("civic_view_assembly_fails_closed_on_other_view_identity_drift", r.replace_civic_review_views(malformed, civic_overview, civic_commons).is_empty())


func _civic_family_audit_serialization_controls(source_runner: SyntheticRunner, roof_source: Dictionary, commons_source: Dictionary) -> void:
	var r := FamilyAuditSyntheticRunner.new()
	r.blueprint = source_runner.blueprint
	r._review_visual_snapshot = source_runner._review_visual_snapshot
	root.add_child(r)
	var camera := Camera3D.new()
	r.add_child(camera)
	var roof_view := r.make_subject_review_view("civic_overview", "civic roofline", roof_source, 34.0, 8.0, 22.0, 0.01, 0)
	var commons_view := r.make_subject_review_view("civic_commons", "civic commons", commons_source, 16.0, 4.5, 10.0, 0.01, 0)
	var roof_pose_id := "synthetic_roof_family_pose_for_audit:reason=%s:rejections=%s:examples=%s:target=%s:support=%s" % [String(roof_view.get("cameraPoseReason", "")), JSON.stringify(roof_view.get("cameraPoseRejections", {})), JSON.stringify(roof_view.get("cameraPoseRejectionExamples", [])), str(roof_view.get("target")), str(roof_view.get("cameraPoseSupport"))]
	var commons_pose_id := "synthetic_commons_family_pose_for_audit:reason=%s:rejections=%s:examples=%s:target=%s:support=%s" % [String(commons_view.get("cameraPoseReason", "")), JSON.stringify(commons_view.get("cameraPoseRejections", {})), JSON.stringify(commons_view.get("cameraPoseRejectionExamples", [])), str(commons_view.get("target")), str(commons_view.get("cameraPoseSupport"))]
	_check(roof_pose_id, bool(roof_view.get("cameraPoseOk", false)))
	_check(commons_pose_id, bool(commons_view.get("cameraPoseOk", false)))
	if not bool(roof_view.get("cameraPoseOk", false)) or not bool(commons_view.get("cameraPoseOk", false)):
		r.free()
		return
	camera.global_position = roof_view.position
	camera.look_at(roof_view.target, Vector3.UP)
	var roof_audit: Dictionary = r.audit_review_camera_contract(roof_view, camera)
	var roof_evidence: Array = roof_audit.get("cameraRequiredVisibleEvidence", []) as Array
	_check("roof_family_audit_serializes_exact_lossless_provenance", roof_audit.passed and roof_audit.cameraTarget == roof_view.target and roof_audit.cameraSightlineTarget == roof_view.cameraPoseSightlineTarget and roof_audit.cameraSubjectIds == roof_source.subjectIds and roof_audit.cameraRequiredVisiblePartIds == ["urban_civic_roof_left", "urban_civic_roof_right"] and roof_audit.cameraCompositionSubjectIds == roof_source.compositionSubjectIds and roof_audit.cameraSubjectBounds == roof_source.bounds and roof_audit.cameraRequiredVisibleBounds == roof_source.requiredVisibleBounds and roof_audit.cameraSubjectFamilySignature == roof_source.familySignature and roof_audit.cameraFamilyEvidenceValid and roof_evidence.size() == 2 and roof_evidence.all(func(row): return bool(row.passed)))
	camera.global_position = commons_view.position
	camera.look_at(commons_view.target, Vector3.UP)
	var commons_audit: Dictionary = r.audit_review_camera_contract(commons_view, camera)
	var commons_bounds: AABB = commons_audit.cameraRequiredVisibleBounds
	_check("commons_family_audit_serializes_exact_seat_back_center_and_bounds", commons_audit.passed and commons_audit.cameraTarget == commons_bounds.get_center() and commons_bounds.has_point(commons_audit.cameraTarget) and commons_audit.cameraRequiredVisiblePartIds == ["urban_civic_commons_bench", "urban_civic_commons_bench_back"] and (commons_audit.cameraRequiredVisibleEvidence as Array).size() == 2 and (commons_audit.cameraRequiredVisibleEvidence as Array).all(func(row): return bool(row.passed)) and commons_audit.cameraRequiresExactRequiredVisibleTarget)
	for mutation in ["missing_signature", "unsorted_subjects", "required_not_subset", "missing_required_bounds", "target_outside_required_bounds"]:
		var malformed: Dictionary = commons_view.duplicate(true)
		match mutation:
			"missing_signature": malformed.erase("cameraSubjectFamilySignature")
			"unsorted_subjects":
				var unsorted_subjects: Array = (malformed.get("cameraSubjectIds", []) as Array).duplicate()
				unsorted_subjects.reverse()
				malformed["cameraSubjectIds"] = unsorted_subjects
			"required_not_subset": malformed.cameraRequiredVisiblePartIds = ["urban_civic_commons_stone_00"]
			"missing_required_bounds": malformed.erase("cameraRequiredVisibleBounds")
			"target_outside_required_bounds": malformed.target = Vector3(999.0, 999.0, 999.0)
		var malformed_audit: Dictionary = r.audit_review_camera_contract(malformed, camera)
		_check("malformed_family_audit_fails_closed_%s" % mutation, not malformed_audit.passed and not malformed_audit.cameraFamilyEvidenceValid)

	var nonfamily_view := {"id": "nonfamily", "subject": "unchanged", "target": Vector3(0.0, 1.58, 0.0), "maxDistance": 8.0, "requiresClear": true, "cameraPoseOk": true, "cameraPoseReason": "", "cameraPoseSupport": Vector3(0.0, 0.0, -6.0), "cameraPoseRejections": {}, "cameraPoseRejectionExamples": [], "cameraPoseFrameFraction": 0.42}
	camera.global_position = Vector3(0.0, 1.58, -6.0)
	camera.look_at(nonfamily_view.target, Vector3.UP)
	var nonfamily_audit: Dictionary = r.audit_review_camera_contract(nonfamily_view, camera)
	var expected_nonfamily := {"id": "nonfamily", "subject": "unchanged", "targetDistance": 6.0, "maximumDistance": 8.0, "requiresClear": true, "targetInFront": true, "targetClear": true, "cameraPose": {"ok": true, "reason": "", "support": Vector3(0.0, 0.0, -6.0), "rejectedCandidates": {}, "rejectionExamples": []}, "subjectFrameFraction": 0.42, "passed": true}
	_check("nonfamily_audit_bytes_remain_exact_without_family_fields", var_to_bytes(nonfamily_audit) == var_to_bytes(expected_nonfamily))
	r.free()


func _ambiguous_civic_family_fixture() -> SyntheticRunner:
	var r := _civic_family_fixture(false)
	var wrong = r.blueprint.add_part({"id": "foreign_roof", "kind": "roof", "material": "shingle", "position": Vector3.ZERO, "size": Vector3.ONE, "collision": false, "semantic": "citadel_civic_roof"})
	r.blueprint.physical_parts_by_id[wrong.id] = wrong
	r.build_review_visual_snapshot()
	return r

func _aligned_perimeter_composition_context_controls() -> void:
	var forward := _aligned_perimeter_context_fixture(false)
	var reversed := _aligned_perimeter_context_fixture(true)
	var forward_source := _aligned_perimeter_primary_source(forward)
	var reversed_source := _aligned_perimeter_primary_source(reversed)
	var sources_valid := bool(forward_source.get("valid", false)) and bool(reversed_source.get("valid", false))
	_check("aligned_perimeter_context_sources_valid:%s:%s" % [String(forward_source.get("reason", "")), String(reversed_source.get("reason", ""))], sources_valid)
	if not sources_valid:
		forward.free()
		reversed.free()
		return
	var primary_ids: Array = forward_source.get("subjectIds", []) as Array
	var visibility_ids: Array = forward_source.get("visibilityPartIds", []) as Array
	var context_ids: Array = forward_source.get("compositionSubjectIds", []) as Array
	var aligned_ids := ["urban_perimeter_west_01_door", "urban_perimeter_west_01_door_bracket", "urban_perimeter_west_01_wall"]
	var non_context_ids := ["urban_perimeter_east_00_door", "urban_perimeter_east_00_wall", "urban_perimeter_north_00_door", "urban_perimeter_north_00_wall", "foreign_perimeter_visual"]
	_check("aligned_perimeter_neighbor_family_is_composition_context_only", bool(forward_source.get("valid", false)) and aligned_ids.all(func(id): return context_ids.has(id)) and aligned_ids.all(func(id): return not primary_ids.has(id) and not visibility_ids.has(id)))
	_check("nonaligned_opposite_perpendicular_and_foreign_geometry_are_not_context", non_context_ids.all(func(id): return not context_ids.has(id)))
	var primary_alley: Dictionary = (forward._review_visual_snapshot.get("byId", {}) as Dictionary).get("urban_perimeter_alley_-1_00", {}) as Dictionary
	var expected_primary_bounds := forward.generated_subject_bounds(primary_ids).merge(forward.review_part_bounds(primary_alley))
	var neighbor_bounds := forward.generated_subject_bounds(aligned_ids)
	_check("composition_context_does_not_expand_primary_framing_or_visibility", primary_ids == visibility_ids and forward_source.get("bounds") == expected_primary_bounds and forward_source.get("focus") == _expected_perimeter_focus(forward, primary_alley, primary_ids) and not expected_primary_bounds.intersects(neighbor_bounds))
	_check("aligned_perimeter_context_telemetry_is_bounded_and_self_consistent", int(forward_source.get("compositionSubjectCount", 0)) == context_ids.size() and context_ids.size() <= Runner.MAX_PERIMETER_COMPOSITION_SUBJECTS and String(forward_source.get("compositionSubjectSignature", "")) == JSON.stringify(context_ids).sha256_text())

	var stable_keys := ["subjectIds", "visibilityPartIds", "bounds", "focus", "subjectRadius", "maximumDistance", "candidatePositions", "candidateDomain", "compositionSubjectIds", "compositionSubjectCount", "compositionSubjectSignature"]
	_check("reversed_perimeter_source_order_preserves_context_ids_and_signature", _selected_fields(forward_source, ["compositionSubjectIds", "compositionSubjectCount", "compositionSubjectSignature"]) == _selected_fields(reversed_source, ["compositionSubjectIds", "compositionSubjectCount", "compositionSubjectSignature"]))
	var forward_candidates: Array = forward_source.get("candidatePositions", []) as Array
	_check("reversed_perimeter_source_order_preserves_primary_and_candidate_domain", var_to_bytes(_selected_fields(forward_source, stable_keys)) == var_to_bytes(_selected_fields(reversed_source, stable_keys)) and forward_candidates.size() > 0 and forward_candidates.size() <= Runner.MAX_REVIEW_CAMERA_CANDIDATES)
	var forward_job = forward._begin_perimeter_source_camera_job(forward_source)
	var reversed_job = reversed._begin_perimeter_source_camera_job(reversed_source)
	_check("camera_job_declares_complete_composition_context_not_only_primary", forward_job._declared_subject_ids == context_ids and reversed_job._declared_subject_ids == (reversed_source.get("compositionSubjectIds", []) as Array) and context_ids.size() > primary_ids.size())
	var forward_progress: Dictionary = forward.advance_exterior_review_pose(forward_job, Runner.MAX_REVIEW_CAMERA_CANDIDATES)
	var reversed_progress: Dictionary = reversed.advance_exterior_review_pose(reversed_job, Runner.MAX_REVIEW_CAMERA_CANDIDATES)
	_check("reversed_perimeter_source_order_preserves_pose_outcome_ignoring_snapshot_revision", _camera_outcome_signature(forward_progress) == _camera_outcome_signature(reversed_progress))
	var overflow_forward: Dictionary = forward.aligned_perimeter_candidate_domain(primary_alley, forward_source.focus, 0.0, 50.0, primary_ids)
	var reversed_primary_alley: Dictionary = (reversed._review_visual_snapshot.get("byId", {}) as Dictionary).get("urban_perimeter_alley_-1_00", {}) as Dictionary
	var overflow_reversed: Dictionary = reversed.aligned_perimeter_candidate_domain(reversed_primary_alley, reversed_source.focus, 0.0, 50.0, reversed_source.subjectIds)
	var overflow_contributors: Array = overflow_forward.get("compositionSourceAlleyIds", []) as Array
	_check("aligned_source_ranked_beyond_final_64_does_not_expand_context", bool(overflow_forward.get("valid", false)) and int(overflow_forward.get("sourceAlleyCount", 0)) == 4 and (overflow_forward.get("candidates", []) as Array).size() == Runner.MAX_REVIEW_CAMERA_CANDIDATES and not overflow_contributors.has("urban_perimeter_alley_-1_99") and not (overflow_forward.get("compositionSubjectIds", []) as Array).has("urban_perimeter_west_99_wall"))
	_check("duplicate_final_position_retains_all_contributors_deterministically", overflow_contributors.has("urban_perimeter_alley_-1_00") and overflow_contributors.has("urban_perimeter_alley_-1_00_duplicate") and var_to_bytes(_selected_fields(overflow_forward, ["candidates", "compositionSourceAlleyIds", "compositionSubjectIds", "compositionSubjectCount", "compositionSubjectSignature"])) == var_to_bytes(_selected_fields(overflow_reversed, ["candidates", "compositionSourceAlleyIds", "compositionSubjectIds", "compositionSubjectCount", "compositionSubjectSignature"])))

	for blocker_id in ["same_orientation_lateral_blocker", "opposite_alignment_blocker", "perpendicular_alignment_blocker", "foreign_geometry_blocker"]:
		_check("noncontext_%s_remains_late_subject_blocker" % blocker_id, _noncontext_late_blocker_reason(blocker_id) == "near_camera_visual_volume")
	var visual_volume := _composition_context_stage_progress("visualVolume")
	var near_field := _composition_context_stage_progress("nearFieldComposition")
	_check("composition_context_cannot_waive_real_visual_volume", not bool((visual_volume.get("pose", {}) as Dictionary).get("ok", false)) and int(((visual_volume.get("pose", {}) as Dictionary).get("rejectedCandidates", {}) as Dictionary).get("visualVolume", 0)) == 1)
	_check("composition_context_cannot_waive_general_near_field", not bool((near_field.get("pose", {}) as Dictionary).get("ok", false)) and int(((near_field.get("pose", {}) as Dictionary).get("rejectedCandidates", {}) as Dictionary).get("nearFieldComposition", 0)) == 1)

	var valid_context: Dictionary = forward.validated_review_composition_subject_context(context_ids, primary_ids)
	var duplicate_ids: Array = context_ids.duplicate()
	duplicate_ids.append(context_ids[0] if not context_ids.is_empty() else "")
	var unsorted_ids: Array = context_ids.duplicate()
	unsorted_ids.reverse()
	var missing_primary_ids: Array = context_ids.filter(func(id): return not primary_ids.has(id))
	_check("empty_and_invalid_composition_context_fail_closed", forward.validated_review_composition_subject_context([], primary_ids).get("reason") == "empty_or_oversized_composition_subject_context" and forward.validated_review_composition_subject_context(duplicate_ids, primary_ids).get("reason") == "invalid_or_duplicate_composition_subject_id")
	_check("nondeterministic_composition_context_order_fails_closed", forward.validated_review_composition_subject_context(unsorted_ids, primary_ids).get("reason") == "nondeterministic_composition_subject_order")
	_check("composition_context_missing_primary_fails_closed", forward.validated_review_composition_subject_context(missing_primary_ids, primary_ids).get("reason") == "composition_subject_context_missing_primary_family")
	var mismatch_source: Dictionary = forward_source.duplicate(true)
	mismatch_source["compositionSubjectCount"] = int(mismatch_source.compositionSubjectCount) + 1
	var mismatch_job = forward._begin_perimeter_source_camera_job(mismatch_source)
	var mismatch: Dictionary = forward.advance_exterior_review_pose(mismatch_job, 1)
	var mismatch_reason := String(mismatch.get("reason", (mismatch.get("pose", {}) as Dictionary).get("reason", "")))
	_check("composition_context_telemetry_mismatch_fails_before_candidate_work", not bool(mismatch.get("valid", true)) and mismatch_reason == "composition_subject_context_telemetry_mismatch" and int(mismatch.get("totalCandidatesEvaluated", -1)) == 0)
	forward.clear_review_visual_snapshot()
	_check("composition_context_missing_snapshot_fails_closed", valid_context.valid and forward.validated_review_composition_subject_context(context_ids, primary_ids).get("reason") == "composition_subject_context_missing_snapshot_member")
	forward.free()
	reversed.free()

func _aligned_perimeter_context_fixture(reverse_parts: bool) -> SyntheticRunner:
	var r := SyntheticRunner.new()
	r.blueprint = Blueprint.new("synthetic_aligned_perimeter_context", 75, "test")
	var records := [
		{"id": "public_support", "kind": "foundation", "material": "stone", "position": Vector3(5.0, 0.31, 12.0), "size": Vector3(50.0, 0.62, 50.0), "collision": true, "semantic": "public_support"},
		{"id": "urban_perimeter_alley_-1_00", "kind": "foundation", "material": "worn_cobble", "position": Vector3(0.0, 0.78, 0.0), "size": Vector3(2.1, 0.10, 6.0), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_west_00_wall", "kind": "wall", "material": "brick", "position": Vector3(-3.0, 3.0, 0.0), "size": Vector3(0.8, 5.0, 5.0), "collision": true, "semantic": "citadel_urban_facade"},
		{"id": "urban_perimeter_west_00_door", "kind": "door", "material": "timber", "position": Vector3(-2.5, 1.4, 0.0), "size": Vector3(0.14, 2.5, 1.25), "collision": true, "semantic": "citadel_urban_door"},
		{"id": "urban_perimeter_west_00_door_bracket", "kind": "beam", "material": "timber", "position": Vector3(-2.4, 2.5, 0.7), "size": Vector3(0.14, 0.76, 0.14), "collision": false, "semantic": "citadel_urban_door_joinery"},
		{"id": "urban_perimeter_alley_-1_00_duplicate", "kind": "foundation", "material": "worn_cobble", "position": Vector3(0.0, 0.78, 0.0), "size": Vector3(2.1, 0.10, 6.0), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_alley_-1_01", "kind": "foundation", "material": "worn_cobble", "position": Vector3(0.0, 0.78, 10.0), "size": Vector3(2.1, 0.10, 6.0), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_west_01_wall", "kind": "wall", "material": "brick", "position": Vector3(-3.0, 3.0, 10.0), "size": Vector3(0.8, 5.0, 5.0), "collision": true, "semantic": "citadel_urban_facade"},
		{"id": "urban_perimeter_west_01_door", "kind": "door", "material": "timber", "position": Vector3(-2.5, 1.4, 10.0), "size": Vector3(0.14, 2.5, 1.25), "collision": true, "semantic": "citadel_urban_door"},
		{"id": "urban_perimeter_west_01_door_bracket", "kind": "beam", "material": "timber", "position": Vector3(-2.4, 2.5, 10.7), "size": Vector3(0.14, 0.76, 0.14), "collision": false, "semantic": "citadel_urban_door_joinery"},
		{"id": "urban_perimeter_alley_-1_99", "kind": "foundation", "material": "worn_cobble", "position": Vector3(0.0, 0.78, 30.0), "size": Vector3(2.1, 0.10, 6.0), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_west_99_wall", "kind": "wall", "material": "brick", "position": Vector3(-3.0, 3.0, 30.0), "size": Vector3(0.8, 5.0, 5.0), "collision": true, "semantic": "citadel_urban_facade"},
		{"id": "urban_perimeter_alley_1_00", "kind": "foundation", "material": "worn_cobble", "position": Vector3(20.0, 0.78, 0.0), "size": Vector3(2.1, 0.10, 6.0), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_east_00_wall", "kind": "wall", "material": "brick", "position": Vector3(17.0, 3.0, 0.0), "size": Vector3(0.8, 5.0, 5.0), "collision": true, "semantic": "citadel_urban_facade"},
		{"id": "urban_perimeter_east_00_door", "kind": "door", "material": "timber", "position": Vector3(17.5, 1.4, 0.0), "size": Vector3(0.14, 2.5, 1.25), "collision": true, "semantic": "citadel_urban_door"},
		{"id": "urban_perimeter_alley_0_00", "kind": "foundation", "material": "worn_cobble", "position": Vector3(0.0, 0.78, 24.0), "size": Vector3(6.0, 0.10, 2.1), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_north_00_wall", "kind": "wall", "material": "brick", "position": Vector3(0.0, 3.0, 21.0), "size": Vector3(5.0, 5.0, 0.8), "collision": true, "semantic": "citadel_urban_facade"},
		{"id": "urban_perimeter_north_00_door", "kind": "door", "material": "timber", "position": Vector3(0.0, 1.4, 21.5), "size": Vector3(1.25, 2.5, 0.14), "collision": true, "semantic": "citadel_urban_door"},
		{"id": "foreign_perimeter_visual", "kind": "wall", "material": "stone", "position": Vector3(18.0, 2.0, 22.0), "size": Vector3(1.0, 3.0, 1.0), "collision": true, "semantic": "foreign_visual"}]
	if reverse_parts:
		records.reverse()
	for record in records:
		var part = r.blueprint.add_part(record)
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	return r

func _aligned_perimeter_primary_source(r) -> Dictionary:
	var by_id: Dictionary = r._review_visual_snapshot.get("byId", {}) as Dictionary
	return r.perimeter_lane_review_subject_for_alley(by_id.get("urban_perimeter_alley_-1_00", {}), 8.0, 18.0)

func _expected_perimeter_focus(r, alley: Dictionary, _primary_ids: Array) -> Vector3:
	var alley_bounds: AABB = r.review_part_bounds(alley)
	var facade: Dictionary = r.generated_perimeter_adjacent_facade(alley)
	var facade_bounds: AABB = r.review_part_bounds(facade)
	return Vector3((alley_bounds.get_center().x + facade_bounds.get_center().x) * 0.5, minf(facade_bounds.end.y - 0.25, facade_bounds.position.y + 2.8), (alley_bounds.get_center().z + facade_bounds.get_center().z) * 0.5)

func _selected_fields(source: Dictionary, keys: Array) -> Dictionary:
	var result := {}
	for key in keys:
		result[key] = source.get(key)
	return result

func _noncontext_late_blocker_reason(blocker_id: String) -> String:
	var r := CompositionContextReadabilityRunner.new()
	r.blueprint = Blueprint.new("synthetic_noncontext_late_blocker", 76, "test")
	for record in [
		{"id": "primary_subject", "kind": "wall", "material": "brick", "position": Vector3(0.0, 1.5, 0.0), "size": Vector3(2.0, 3.0, 0.5), "collision": true, "semantic": "citadel_urban_facade", "recipe": {"visual": true}},
		{"id": "aligned_context", "kind": "door", "material": "timber", "position": Vector3(0.0, 1.5, 1.0), "size": Vector3(0.2, 2.5, 1.0), "collision": true, "semantic": "citadel_urban_door", "recipe": {"visual": true}},
		{"id": blocker_id, "kind": "wall", "material": "stone", "position": Vector3(0.8, 2.0, -5.5), "size": Vector3(1.0, 1.0, 1.0), "collision": true, "semantic": "foreign_visual", "recipe": {"visual": true}}]:
		var part = r.blueprint.add_part(record)
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	var result := r.generated_any_subject_readability_rejection(Vector3(0.0, 1.58, -6.0), ["primary_subject"], ["aligned_context", "primary_subject"])
	r.free()
	return result

func _composition_context_stage_progress(stage: String) -> Dictionary:
	var r := RealTelemetryRunner.new()
	r.blueprint = Blueprint.new("synthetic_context_does_not_waive_%s" % stage, 77, "test")
	var blocker := {"id": "context_blocker", "kind": "beam", "material": "timber", "position": Vector3(0.0, 0.8, -6.0), "size": Vector3(0.2, 1.2, 0.2), "collision": true, "semantic": "citadel_urban_door_joinery", "recipe": {"visual": true}}
	if stage == "nearFieldComposition":
		blocker = {"id": "context_blocker", "kind": "wall", "material": "timber", "position": Vector3(0.0, 1.58, -4.5), "size": Vector3(5.0, 3.2, 0.2), "collision": true, "semantic": "citadel_urban_door", "recipe": {"visual": true}}
	for record in [
		{"id": "primary_subject", "kind": "wall", "material": "brick", "position": Vector3(0.0, 1.5, 0.0), "size": Vector3(2.0, 3.0, 0.5), "collision": true, "semantic": "citadel_urban_facade", "recipe": {"visual": true}},
		blocker]:
		var part = r.blueprint.add_part(record)
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	var primary_ids := ["primary_subject"]
	var context_ids := ["context_blocker", "primary_subject"]
	var context: Dictionary = r.validated_review_composition_subject_context(context_ids, primary_ids)
	var source := {"sourceId": "context_stage", "recipeClear": true, "focus": Vector3(0.0, 1.5, 0.0), "bounds": r.generated_subject_bounds(primary_ids), "candidatePositions": [Vector3(0.0, 0.0, -6.0)], "candidateDomain": {"type": "explicit_positions", "count": 1}, "subjectRadius": 2.0, "minimumSupportY": -INF, "subjectIds": primary_ids, "visibilityPartIds": primary_ids, "compositionSubjectIds": context.ids, "compositionSubjectCount": context.count, "compositionSubjectSignature": context.signature, "readabilityMode": "any", "visualSnapshotBinding": r.review_visual_snapshot_binding(), "visualSnapshotEpoch": r._review_visual_snapshot_epoch}
	var job = r._begin_perimeter_source_camera_job(source)
	var progress: Dictionary = r.advance_exterior_review_pose(job, 1)
	r.free()
	return progress

func _rejection_telemetry_controls() -> void:
	var expected_subreasons := {
		"visualVolume": "capsuleIntersection",
		"nearFieldComposition": "blockedNearFrustum",
		"subjectRequirements": "nearCameraComposition"}
	for stage_value in expected_subreasons:
		var stage := String(stage_value)
		var instrumented := _run_telemetry_fixture(stage, false, false)
		var control := _run_telemetry_fixture(stage, false, true)
		var evidence: Dictionary = _stage_rejection_evidence(instrumented)
		var rows: Array = evidence.get(stage, []) as Array
		_check("rejection_telemetry_preserves_%s_outcome_and_candidate_count" % stage, _camera_outcome_signature(instrumented) == _camera_outcome_signature(control) and int(instrumented.get("totalCandidatesEvaluated", -1)) == 8)
		_check("rejection_telemetry_%s_is_bounded_and_stage_specific" % stage, rows.size() == Runner.MAX_REVIEW_STAGE_REJECTION_EVIDENCE and _other_stage_rows_are_empty(evidence, stage))
		_check("rejection_telemetry_%s_uses_exact_schema" % stage, _telemetry_rows_match_schema(rows, String(expected_subreasons[stage])))
		_check("rejection_telemetry_%s_is_serializable_without_objects" % stage, not _contains_object(evidence) and not JSON.stringify(evidence).is_empty())
	_subject_rejection_subtype_controls()
	_real_rejection_provenance_controls()

	var forward := _run_telemetry_fixture("subjectRequirements", false, false)
	var reversed := _run_telemetry_fixture("subjectRequirements", true, false)
	var forward_rows: Array = _stage_rejection_evidence(forward).get("subjectRequirements", []) as Array
	var reversed_rows: Array = _stage_rejection_evidence(reversed).get("subjectRequirements", []) as Array
	var forward_blockers: Array = []
	var reversed_blockers: Array = []
	if not forward_rows.is_empty():
		forward_blockers = (forward_rows[0] as Dictionary).get("blockers", []) as Array
	if not reversed_rows.is_empty():
		reversed_blockers = (reversed_rows[0] as Dictionary).get("blockers", []) as Array
	_check("rejection_telemetry_provenance_order_is_source_order_independent", _ordered_blocker_identity(forward_blockers) == _ordered_blocker_identity(reversed_blockers) and _ordered_blocker_identity(forward_blockers) == ["family_blocker", "foreign_blocker"])
	_check("rejection_telemetry_classifies_family_and_foreign_blockers", forward_blockers.size() == 2 and bool((forward_blockers[0] as Dictionary).get("belongsToDeclaredSubjectFamily", false)) and not bool((forward_blockers[1] as Dictionary).get("belongsToDeclaredSubjectFamily", true)))

	var stale_runner: TelemetrySyntheticRunner = _telemetry_fixture_runner(false, false)
	var stale_source := _telemetry_source(stale_runner, "stale_source")
	var stale_job = stale_runner._begin_perimeter_source_camera_job(stale_source)
	stale_runner.clear_review_visual_snapshot()
	var stale_support_calls: int = stale_runner.support_calls
	var stale: Dictionary = stale_runner.advance_exterior_review_pose(stale_job, 8)
	_check("stale_camera_job_records_zero_work_and_zero_rejection_evidence", not stale.valid and stale.reason == "stale_camera_visual_snapshot_binding" and stale.candidatesEvaluated == 0 and stale.totalCandidatesEvaluated == 0 and stale_runner.support_calls == stale_support_calls and _all_stage_rows_are_empty(_stage_rejection_evidence(stale)))
	stale_runner.free()

func _run_telemetry_fixture(stage: String, reverse_parts: bool, suppress_telemetry: bool) -> Dictionary:
	if stage in ["visualVolume", "nearFieldComposition"]:
		return _run_real_telemetry_fixture(stage, reverse_parts, suppress_telemetry)
	var r: TelemetrySyntheticRunner = _telemetry_fixture_runner(reverse_parts, suppress_telemetry)
	r.rejection_mode = stage
	var source := _telemetry_source(r, "telemetry_source")
	var job = r._begin_perimeter_source_camera_job(source)
	var progress: Dictionary = r.advance_exterior_review_pose(job, 8)
	r.free()
	return progress

func _run_real_telemetry_fixture(stage: String, reverse_parts: bool, suppress_telemetry: bool) -> Dictionary:
	var r = RealNoTelemetryRunner.new() if suppress_telemetry else RealTelemetryRunner.new()
	r.blueprint = Blueprint.new("real_rejection_telemetry_%s" % stage, 74, "test")
	var records := [{"id": "family_blocker", "kind": "wall", "material": "brick", "position": Vector3(0.0, 1.5, 0.0), "size": Vector3(2.0, 3.0, 0.5), "collision": true, "semantic": "citadel_subject_family", "recipe": {"visual": true}}]
	if stage == "visualVolume":
		records.append_array([
			{"id": "capsule_alpha", "kind": "beam", "material": "timber", "position": Vector3(0.0, 0.80, -6.0), "size": Vector3(0.20, 1.20, 0.20), "collision": true, "semantic": "camera_volume_alpha", "recipe": {"visual": true}},
			{"id": "capsule_beta", "kind": "beam", "material": "timber", "position": Vector3(0.0, 0.80, -6.0), "size": Vector3(0.20, 1.20, 0.20), "collision": true, "semantic": "camera_volume_beta", "recipe": {"visual": true}}])
	else:
		records.append({"id": "near_blocker", "kind": "wall", "material": "timber", "position": Vector3(0.0, 1.58, -4.50), "size": Vector3(5.0, 3.2, 0.20), "collision": true, "semantic": "camera_near_frustum", "recipe": {"visual": true}})
	if reverse_parts:
		records.reverse()
	for record in records:
		var part = r.blueprint.add_part(record)
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	var source := _telemetry_source(r, "real_%s" % stage)
	if stage == "visualVolume":
		(source.subjectIds as Array).append("capsule_beta" if reverse_parts else "capsule_alpha")
	else:
		(source.subjectIds as Array).append("near_blocker")
	var job = r._begin_perimeter_source_camera_job(source)
	var progress: Dictionary = r.advance_exterior_review_pose(job, 8)
	r.free()
	return progress

func _real_rejection_provenance_controls() -> void:
	var visual_forward := _run_real_telemetry_fixture("visualVolume", false, false)
	var visual_reversed := _run_real_telemetry_fixture("visualVolume", true, false)
	var visual_forward_blocker := _first_stage_blocker(visual_forward, "visualVolume")
	var visual_reversed_blocker := _first_stage_blocker(visual_reversed, "visualVolume")
	_check("real_visual_volume_uses_source_order_first_blocker_semantics", String(visual_forward_blocker.get("blockerId", "")) == "capsule_alpha" and int(visual_forward_blocker.get("sourceOrdinal", -1)) == 1 and String(visual_reversed_blocker.get("blockerId", "")) == "capsule_beta" and int(visual_reversed_blocker.get("sourceOrdinal", -1)) == 0)
	var visual_bounds: Variant = visual_forward_blocker.get("bounds")
	_check("real_visual_volume_emits_exact_bounds_and_declared_family_classification", visual_bounds is AABB and (visual_bounds as AABB).is_equal_approx(AABB(Vector3(-0.10, 0.20, -6.10), Vector3(0.20, 1.20, 0.20))) and bool(visual_forward_blocker.get("belongsToDeclaredSubjectFamily", false)))

	var near_forward := _run_real_telemetry_fixture("nearFieldComposition", false, false)
	var near_reversed := _run_real_telemetry_fixture("nearFieldComposition", true, false)
	var near_forward_blocker := _first_stage_blocker(near_forward, "nearFieldComposition")
	var near_reversed_blocker := _first_stage_blocker(near_reversed, "nearFieldComposition")
	_check("real_near_field_uses_stable_blocker_id_under_reversed_source_order", String(near_forward_blocker.get("blockerId", "")) == "near_blocker" and String(near_reversed_blocker.get("blockerId", "")) == "near_blocker" and near_forward_blocker.get("bounds") == near_reversed_blocker.get("bounds"))
	var near_bounds: Variant = near_forward_blocker.get("bounds")
	_check("real_near_field_emits_actual_ordinal_bounds_and_declared_family_classification", int(near_forward_blocker.get("sourceOrdinal", -1)) == 1 and int(near_reversed_blocker.get("sourceOrdinal", -1)) == 0 and near_bounds is AABB and (near_bounds as AABB).is_equal_approx(AABB(Vector3(-2.50, -0.02, -4.60), Vector3(5.0, 3.2, 0.20))) and bool(near_forward_blocker.get("belongsToDeclaredSubjectFamily", false)))

func _first_stage_blocker(progress: Dictionary, stage: String) -> Dictionary:
	var rows: Array = _stage_rejection_evidence(progress).get(stage, []) as Array
	if rows.is_empty():
		return {}
	var blockers: Array = (rows[0] as Dictionary).get("blockers", []) as Array
	return blockers[0] as Dictionary if not blockers.is_empty() else {}

func _telemetry_fixture_runner(reverse_parts: bool, suppress_telemetry: bool) -> TelemetrySyntheticRunner:
	var r = NoTelemetrySyntheticRunner.new() if suppress_telemetry else TelemetrySyntheticRunner.new()
	r.blueprint = Blueprint.new("synthetic_rejection_telemetry", 72, "test")
	var records := [
		{"id": "family_blocker", "kind": "wall", "material": "brick", "position": Vector3(0.0, 1.5, 0.0), "size": Vector3(2.0, 3.0, 0.5), "collision": true, "semantic": "citadel_subject_family", "recipe": {"visual": true}},
		{"id": "foreign_blocker", "kind": "beam", "material": "timber", "position": Vector3(0.5, 2.0, -5.5), "size": Vector3(1.0, 1.0, 1.0), "collision": true, "semantic": "foreign_visual", "recipe": {"visual": true}}]
	if reverse_parts:
		records.reverse()
	for record in records:
		var part = r.blueprint.add_part(record)
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	return r

func _subject_rejection_subtype_controls() -> void:
	for subtype in ["upperFrame", "noReadableMember", "nearCameraComposition"]:
		var r := SubjectSubtypeSyntheticRunner.new()
		r.subject_subtype = subtype
		r.blueprint = Blueprint.new("synthetic_subject_rejection_%s" % subtype, 73, "test")
		for record in [
			{"id": "family_blocker", "kind": "wall", "material": "brick", "position": Vector3(0.0, 1.5, 0.0), "size": Vector3(2.0, 3.0, 0.5), "collision": true, "semantic": "citadel_subject_family", "recipe": {"visual": true}},
			{"id": "foreign_blocker", "kind": "beam", "material": "timber", "position": Vector3(0.8, 2.0, -5.5), "size": Vector3(1.0, 1.0, 1.0), "collision": true, "semantic": "foreign_visual", "recipe": {"visual": true}}]:
			var part = r.blueprint.add_part(record)
			r.blueprint.physical_parts_by_id[part.id] = part
		r.build_review_visual_snapshot()
		var source := _telemetry_source(r, "subject_subtype_%s" % subtype)
		source["readabilityMode"] = "any"
		var job = r._begin_perimeter_source_camera_job(source)
		var progress: Dictionary = r.advance_exterior_review_pose(job, 8)
		var rows: Array = _stage_rejection_evidence(progress).get("subjectRequirements", []) as Array
		var first: Dictionary = rows[0] as Dictionary if not rows.is_empty() else {}
		_check("subject_rejection_telemetry_distinguishes_%s" % subtype, not bool((progress.get("pose", {}) as Dictionary).get("ok", false)) and rows.size() == Runner.MAX_REVIEW_STAGE_REJECTION_EVIDENCE and String(first.get("subreason", "")) == subtype)
		if subtype == "nearCameraComposition":
			var blockers: Array = first.get("blockers", []) as Array
			_check("subject_near_camera_telemetry_names_selected_member_and_exact_foreign_blocker", String(first.get("selectedVisibleMember", "")) == "family_blocker" and blockers.size() == 1 and _ordered_blocker_identity(blockers) == ["foreign_blocker"] and not bool((blockers[0] as Dictionary).get("belongsToDeclaredSubjectFamily", true)))
		r.free()

func _telemetry_source(r, source_id: String) -> Dictionary:
	var candidates: Array = []
	for index in range(8):
		candidates.append(Vector3(float(index % 2) * 0.01, 0.0, -6.0 - float(index / 2) * 0.01))
	var subject_record: Dictionary = (r._review_visual_snapshot.get("byId", {}) as Dictionary).get("family_blocker", {}) as Dictionary
	var bounds: AABB = subject_record.get("worldBounds", AABB()) as AABB
	return {"sourceId": source_id, "recipeClear": true, "focus": bounds.get_center(), "bounds": bounds,
		"candidatePositions": candidates, "candidateDomain": {"type": "explicit_positions", "count": candidates.size(), "bounds": AABB(Vector3(-0.1, 0.0, -6.2), Vector3(0.3, 2.0, 0.3))},
		"subjectRadius": 2.0, "minimumSupportY": -INF, "subjectIds": ["family_blocker"],
		"visualSnapshotBinding": r.review_visual_snapshot_binding(), "visualSnapshotEpoch": r._review_visual_snapshot_epoch}

func _stage_rejection_evidence(progress: Dictionary) -> Dictionary:
	var phase_telemetry: Dictionary = progress.get("phaseTelemetry", {}) as Dictionary
	return phase_telemetry.get("stageRejectionEvidence", {}) as Dictionary

func _camera_outcome_signature(progress: Dictionary) -> Dictionary:
	var pose: Dictionary = progress.get("pose", {}) as Dictionary
	return {"valid": bool(progress.get("valid", false)), "complete": bool(progress.get("complete", false)),
		"candidatesEvaluated": int(progress.get("candidatesEvaluated", -1)), "totalCandidatesEvaluated": int(progress.get("totalCandidatesEvaluated", -1)),
		"poseOk": bool(pose.get("ok", false)), "poseReason": String(pose.get("reason", "")), "rejectedCandidates": (pose.get("rejectedCandidates", {}) as Dictionary).duplicate(true)}

func _other_stage_rows_are_empty(evidence: Dictionary, selected_stage: String) -> bool:
	for stage in ["visualVolume", "nearFieldComposition", "subjectRequirements"]:
		if stage != selected_stage and not (evidence.get(stage, []) as Array).is_empty():
			return false
	return true

func _all_stage_rows_are_empty(evidence: Dictionary) -> bool:
	return ["visualVolume", "nearFieldComposition", "subjectRequirements"].all(func(stage): return (evidence.get(stage, []) as Array).is_empty())

func _telemetry_rows_match_schema(rows: Array, expected_subreason: String) -> bool:
	var row_keys := ["subreason", "reason", "selectedVisibleMember", "blockers"]
	if expected_subreason == "blockedNearFrustum":
		row_keys = ["subreason", "reason", "selectedVisibleMember", "blockedSamples", "sampleCount", "blockers"]
	var blocker_keys := ["blockerId", "sourceOrdinal", "kind", "semantic", "bounds", "belongsToDeclaredSubjectFamily"]
	for row_value in rows:
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if not _same_key_set(row.keys(), row_keys) or String(row.get("subreason", "")) != expected_subreason:
			return false
		var blockers: Array = row.get("blockers", []) as Array
		if blockers.is_empty():
			return false
		for blocker_value in blockers:
			if not blocker_value is Dictionary:
				return false
			var blocker: Dictionary = blocker_value
			if not _same_key_set(blocker.keys(), blocker_keys) or String(blocker.get("blockerId", "")).is_empty() or int(blocker.get("sourceOrdinal", -1)) < 0 or not (blocker.get("bounds") is AABB):
				return false
	return true

func _same_key_set(actual: Array, expected: Array) -> bool:
	var actual_sorted := actual.duplicate()
	var expected_sorted := expected.duplicate()
	actual_sorted.sort()
	expected_sorted.sort()
	return actual_sorted == expected_sorted

func _ordered_blocker_identity(blockers: Array) -> Array:
	return blockers.map(func(blocker): return String((blocker as Dictionary).get("blockerId", "")))

func _contains_object(value: Variant) -> bool:
	if typeof(value) == TYPE_OBJECT:
		return true
	if value is Dictionary:
		return (value as Dictionary).values().any(func(item): return _contains_object(item))
	if value is Array:
		return (value as Array).any(func(item): return _contains_object(item))
	return false

func _visual_composition_negative_controls() -> void:
	var r := SyntheticRunner.new()
	root.add_child(r)
	var wall_bounds := AABB(Vector3(-1.5, 0.0, -0.05), Vector3(3.0, 4.0, 0.10))
	var upper_callback := Callable(r, "generated_upper_framing_rejection").bind(wall_bounds) if r.has_method("generated_upper_framing_rejection") else Callable(self, "_synthetic_upper_framing_rejection").bind(wall_bounds)
	if not r.has_method("generated_upper_framing_rejection"):
		_integration_points.append({"id": "upper_framing", "requiredRunnerMethod": "generated_upper_framing_rejection", "signature": "(camera_position: Vector3, subject_bounds: AABB) -> String"})
	var close_job = r.begin_exterior_review_pose_from_candidates(Vector3(0.0, 1.58, 0.0), [Vector3(0.0, 1.58, -0.90)], 2.0, -INF, upper_callback, _visible_surface_target)
	var close_result: Dictionary = r.advance_exterior_review_pose(close_job, 64)
	var close_examples: Array = close_result.pose.get("rejectionExamples", []) as Array
	_check("close_wall_clear_central_ray_fails_upper_framing", r.physics_allowed and r.visual_allowed and close_result.complete and not close_result.pose.ok and close_result.pose.rejectedCandidates.frameDominance == 1 and close_examples.size() == 1 and close_examples[0].reason == "frame_dominance")
	_check("generated_upper_framing_uses_actual_subject_bounds", r.generated_upper_framing_rejection(Vector3(0.0, 1.58, -0.90), wall_bounds) == "upper_frame_clipped")
	var reversed_wall_sources := [AABB(Vector3(-1.5, 0.0, -0.05), Vector3(1.5, 4.0, 0.10)), AABB(Vector3(0.0, 0.0, -0.05), Vector3(1.5, 4.0, 0.10))]
	var forward_wall_bounds := _merged_bounds(reversed_wall_sources)
	reversed_wall_sources.reverse()
	_check("upper_framing_source_order_is_deterministic", forward_wall_bounds == _merged_bounds(reversed_wall_sources) and _synthetic_upper_framing_rejection(Vector3(0.0, 1.58, -0.90), forward_wall_bounds) == _synthetic_upper_framing_rejection(Vector3(0.0, 1.58, -0.90), _merged_bounds(reversed_wall_sources)))
	var missing_upper_job = r.begin_exterior_review_pose_from_candidates(Vector3(0.0, 1.58, 0.0), [Vector3(0.0, 1.58, -6.0)], 2.0, -INF, Callable(r, "generated_upper_framing_rejection").bind(AABB()))
	var missing_upper: Dictionary = r.advance_exterior_review_pose(missing_upper_job, 64)
	_check("upper_framing_missing_subject_bounds_fails_closed", not missing_upper.pose.ok and missing_upper.pose.rejectionExamples[0].reason == "subject:missing_subject_bounds")
	# Observed failed roof bounds/candidate: horizon elevation is not clipping
	# when the real 62-degree camera is aimed up at the roof's centre.
	var roof_bounds := AABB(Vector3(-18.88291, 19.62, -0.668), Vector3(9.765823, 3.785618, 10.176))
	var roof_camera := Vector3(-14.0, 4.05, -17.58)
	_check("pitched_roof_is_not_rejected_by_horizon_elevation", r.generated_upper_framing_rejection(roof_camera, roof_bounds).is_empty())
	var camera := Camera3D.new()
	r.add_child(camera)
	camera.fov = 62.0
	camera.global_position = roof_camera
	camera.look_at(roof_bounds.get_center(), Vector3.UP)
	var projection := camera.get_camera_projection()
	var inverse := camera.global_transform.affine_inverse()
	var engine_upper_visible := true
	for corner_index in range(8):
		var local: Vector3 = inverse * roof_bounds.get_endpoint(corner_index)
		var clip: Vector4 = projection * Vector4(local.x, local.y, local.z, 1.0)
		engine_upper_visible = engine_upper_visible and clip.w > 0.0 and clip.y <= clip.w
	_check("pitched_roof_matches_real_camera_projection", engine_upper_visible and r.generated_upper_framing_for_transform(camera.global_transform, roof_bounds, camera.fov).is_empty())
	camera.look_at(roof_camera + Vector3.FORWARD, Vector3.UP)
	_check("opposite_aim_rejects_subject_behind_camera", not r.generated_upper_framing_for_transform(camera.global_transform, roof_bounds, camera.fov).is_empty())
	camera.look_at(Vector3(roof_bounds.get_center().x, roof_camera.y, roof_bounds.get_center().z), Vector3.UP)
	_check("level_camera_still_rejects_roof_above_frame", r.generated_upper_framing_for_transform(camera.global_transform, roof_bounds, camera.fov) == "upper_frame_clipped")
	var low_target := Vector3(roof_bounds.get_center().x, roof_camera.y, roof_bounds.get_center().z)
	_check("offcentre_target_matches_final_camera_rejection", r.generated_upper_framing_rejection(roof_camera, roof_bounds, low_target) == r.generated_upper_framing_for_transform(camera.global_transform, roof_bounds, camera.fov))
	_check("invalid_explicit_target_fails_closed", r.generated_upper_framing_rejection(roof_camera, roof_bounds, Vector3.INF) == "invalid_camera_aim")
	var final_view := {"id": "synthetic_roof", "target": roof_bounds.get_center(), "cameraSubjectBounds": roof_bounds, "requiresClear": true, "maxDistance": 100.0, "cameraPoseOk": true, "cameraPoseSupport": roof_camera - Vector3(0, 1.58, 0), "cameraPoseFrameFraction": 0.4}
	var final_audit: Dictionary = r.audit_review_camera_contract(final_view, camera)
	_check("final_camera_audit_rechecks_actual_pitch", not bool(final_audit.passed) and final_audit.get("cameraUpperFramingReason") == "upper_frame_clipped")
	camera.look_at(roof_bounds.get_center(), Vector3.UP)
	var aimed_audit: Dictionary = r.audit_review_camera_contract(final_view, camera)
	_check("same_final_metadata_passes_only_after_correct_camera_aim", bool(aimed_audit.passed) and aimed_audit.get("cameraUpperFramingReason") == "")
	for offset in [Vector3.ZERO, Vector3(120, -40, 75)]:
		var shifted := AABB(roof_bounds.position + offset, roof_bounds.size)
		_check("roof_framing_translation_invariant_%s" % offset, r.generated_upper_framing_rejection(roof_camera + offset, shifted).is_empty())
	_check("nonfinite_camera_fails_closed", r.generated_upper_framing_rejection(Vector3.INF, roof_bounds) == "invalid_camera_aim")
	_check("nonfinite_bounds_fail_closed", r.generated_upper_framing_rejection(roof_camera, AABB(Vector3.INF, Vector3.ONE)) == "missing_subject_bounds")
	camera.free()

	var subject_bounds := AABB(Vector3(-1.0, 0.0, -0.25), Vector3(2.0, 3.2, 0.5))
	var foreground_bounds := [
		AABB(Vector3(0.35, 0.60, -5.70), Vector3(1.60, 2.30, 0.60)),
		AABB(Vector3(4.0, 0.0, -3.0), Vector3(0.5, 0.5, 0.5))]
	var composition_callback := Callable(r, "generated_near_camera_visual_composition_rejection").bind(subject_bounds, foreground_bounds) if r.has_method("generated_near_camera_visual_composition_rejection") else Callable(self, "_synthetic_near_camera_visual_composition_rejection").bind(subject_bounds, foreground_bounds)
	if not r.has_method("generated_near_camera_visual_composition_rejection"):
		_integration_points.append({"id": "near_camera_visual_composition", "requiredRunnerMethod": "generated_near_camera_visual_composition_rejection", "signature": "(camera_position: Vector3, subject_bounds: AABB, foreground_bounds: Array[AABB]) -> String"})
	var overhang_job = r.begin_exterior_review_pose_from_candidates(Vector3(0.0, 1.58, 0.0), [Vector3(0.0, 1.58, -6.0)], 2.0, -INF, composition_callback, _visible_surface_target)
	var overhang: Dictionary = r.advance_exterior_review_pose(overhang_job, 64)
	var overhang_examples: Array = overhang.pose.get("rejectionExamples", []) as Array
	_check("off_axis_foreground_clear_central_ray_fails_near_camera_composition", r.physics_allowed and r.visual_allowed and overhang.complete and not overhang.pose.ok and overhang.pose.rejectedCandidates.subjectRequirements == 1 and overhang_examples.size() == 1 and overhang_examples[0].reason == "subject:near_camera_visual_volume")
	var forward_composition_reason := _synthetic_near_camera_visual_composition_rejection(Vector3(0.0, 1.58, -6.0), subject_bounds, foreground_bounds)
	foreground_bounds.reverse()
	_check("near_camera_composition_source_order_is_deterministic", forward_composition_reason == "near_camera_visual_volume" and forward_composition_reason == _synthetic_near_camera_visual_composition_rejection(Vector3(0.0, 1.58, -6.0), subject_bounds, foreground_bounds))
	var missing_foreground_job = r.begin_exterior_review_pose_from_candidates(Vector3(0.0, 1.58, 0.0), [Vector3(0.0, 1.58, -6.0)], 2.0, -INF, Callable(self, "_synthetic_near_camera_visual_composition_rejection").bind(subject_bounds, []))
	var missing_foreground: Dictionary = r.advance_exterior_review_pose(missing_foreground_job, 64)
	_check("near_camera_composition_missing_foreground_bounds_fails_closed", not missing_foreground.pose.ok and missing_foreground.pose.rejectionExamples[0].reason == "subject:missing_foreground_bounds")

	var overhang_bounds := AABB(Vector3(-1, 0, -6.2), Vector3(2.8, 3.2, 6.45))
	_check("near_family_crossing_camera_plane_is_not_full_frame_evidence", not r.generated_upper_framing_rejection(Vector3(0, 1.58, -6), overhang_bounds).is_empty())
	r.free()
	r = CompositionOnlySyntheticRunner.new()
	root.add_child(r)
	r.blueprint = Blueprint.new("same_family_foreground", 7, "test")
	var visible_wall = r.blueprint.add_part({"id": "perimeter_family_a_wall", "kind": "wall", "material": "brick", "position": Vector3(0.0, 1.6, 0.0), "size": Vector3(2.0, 3.2, 0.5), "collision": false, "recipe": {"visual": true}})
	var near_overhang = r.blueprint.add_part({"id": "perimeter_family_b_overhang", "kind": "beam", "material": "timber", "position": Vector3(0.8, 2.5, -5.7), "size": Vector3(2.0, 1.0, 1.0), "collision": false, "recipe": {"visual": true}})
	r.blueprint.add_part({"id": "distant_foreground", "kind": "wall", "material": "stone", "position": Vector3(20.0, 1.5, 20.0), "size": Vector3(1.0, 3.0, 1.0), "collision": false, "recipe": {"visual": true}})
	for part in r.blueprint.parts:
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	var family_ids: Array = [visible_wall.id, near_overhang.id]
	var family_reason := r.generated_any_subject_readability_rejection(Vector3(0.0, 1.58, -6.0), family_ids)
	_check("same_family_visible_member_and_near_sibling_are_not_self_obstruction", family_reason.is_empty())
	_check("same_sibling_omitted_from_declared_family_remains_blocker", r.generated_any_subject_readability_rejection(Vector3(0.0, 1.58, -6.0), [visible_wall.id]) == "near_camera_visual_volume")
	family_ids.reverse()
	_check("same_family_exclusion_is_order_independent", r.generated_any_subject_readability_rejection(Vector3(0.0, 1.58, -6.0), family_ids) == family_reason)
	var foreign_overhang = r.blueprint.add_part({"id": "foreign_near_overhang", "kind": "beam", "material": "timber", "position": Vector3(-0.8, 2.5, -5.7), "size": Vector3(2.0, 1.0, 1.0), "collision": false, "recipe": {"visual": true}})
	r.blueprint.physical_parts_by_id[foreign_overhang.id] = foreign_overhang
	r.build_review_visual_snapshot()
	_check("unrelated_foreign_visual_remains_near_camera_blocker", r.generated_any_subject_readability_rejection(Vector3(0.0, 1.58, -6.0), family_ids) == "near_camera_visual_volume")

	var single_member := SyntheticRunner.new()
	single_member.blueprint = Blueprint.new("single_member_foreground", 71, "test")
	var single_wall = single_member.blueprint.add_part({"id": "single_subject_wall", "kind": "wall", "material": "brick", "position": Vector3(0.0, 1.6, 0.0), "size": Vector3(2.0, 3.2, 0.5), "collision": false, "recipe": {"visual": true}})
	single_member.blueprint.add_part({"id": "single_distant_foreground", "kind": "wall", "material": "stone", "position": Vector3(20.0, 1.5, 20.0), "size": Vector3(1.0, 3.0, 1.0), "collision": false, "recipe": {"visual": true}})
	for part in single_member.blueprint.parts:
		single_member.blueprint.physical_parts_by_id[part.id] = part
	single_member.build_review_visual_snapshot()
	var single_ids := [single_wall.id]
	_check("single_member_any_readability_behavior_is_unchanged", single_member.generated_any_subject_readability_rejection(Vector3(0.0, 1.58, -6.0), single_ids) == single_member.generated_subject_readability_rejection(Vector3(0.0, 1.58, -6.0), single_ids))
	single_member.free()

	var nonvisual := SyntheticRunner.new()
	nonvisual.blueprint = Blueprint.new("nonvisual_subject_family", 8, "test")
	var hidden = nonvisual.blueprint.add_part({"id": "nonvisual_member", "kind": "wall", "material": "brick", "position": Vector3.ZERO, "size": Vector3.ONE, "collision": true, "recipe": {"visual": false}})
	nonvisual.blueprint.physical_parts_by_id[hidden.id] = hidden
	nonvisual.build_review_visual_snapshot()
	_check("all_nonvisual_subject_family_fails_closed", nonvisual.generated_any_subject_readability_rejection(Vector3(0.0, 1.58, -6.0), [hidden.id]) == "generated_subject_family_not_readable")
	nonvisual.free()

	var broad_bounds := AABB(Vector3(-15.0, 0.0, -20.0), Vector3(30.0, 3.0, 40.0))
	var broad_domain := r.generated_subject_radial_domain(broad_bounds, 12.0, 4.0, 8.0, 2.0)
	_check("horizontal_depth_dominant_family_expands_frame_radius", is_equal_approx(float(broad_domain.subjectRadius), 20.0) and float(broad_domain.maximumDistance) > 12.0)
	r.free()

func _synthetic_upper_framing_rejection(camera_position: Vector3, subject_bounds: AABB) -> String:
	if subject_bounds.size.x <= 0.0 or subject_bounds.size.y <= 0.0 or subject_bounds.size.z <= 0.0:
		return "missing_subject_bounds"
	var horizontal_distance := Vector2(camera_position.x, camera_position.z).distance_to(Vector2(subject_bounds.get_center().x, subject_bounds.get_center().z))
	var upper_angle := atan2(subject_bounds.end.y - camera_position.y, maxf(0.01, horizontal_distance))
	return "upper_frame_clipped" if upper_angle > deg_to_rad(31.0) else ""

func _synthetic_near_camera_visual_composition_rejection(camera_position: Vector3, subject_bounds: AABB, foreground_bounds: Array) -> String:
	if subject_bounds.size.x <= 0.0 or subject_bounds.size.y <= 0.0 or subject_bounds.size.z <= 0.0:
		return "missing_subject_bounds"
	if foreground_bounds.is_empty():
		return "missing_foreground_bounds"
	var ordered: Array = foreground_bounds.duplicate()
	ordered.sort_custom(func(a: AABB, b: AABB) -> bool:
		var a_key := "%.4f:%.4f:%.4f" % [a.position.x, a.position.y, a.position.z]
		var b_key := "%.4f:%.4f:%.4f" % [b.position.x, b.position.y, b.position.z]
		return a_key < b_key)
	for bounds_value in ordered:
		if not bounds_value is AABB:
			return "invalid_foreground_bounds"
		var bounds: AABB = bounds_value as AABB
		var closest := Vector3(clampf(camera_position.x, bounds.position.x, bounds.end.x), clampf(camera_position.y, bounds.position.y, bounds.end.y), clampf(camera_position.z, bounds.position.z, bounds.end.z))
		var distance := camera_position.distance_to(closest)
		var angular_span := 2.0 * atan(maxf(bounds.size.x, bounds.size.y) * 0.5 / maxf(distance, 0.01))
		if distance < 1.25 and angular_span > deg_to_rad(24.0):
			return "near_camera_visual_volume"
	return ""

func _merged_bounds(values: Array) -> AABB:
	var merged := AABB()
	var first := true
	for value in values:
		if not value is AABB:
			continue
		merged = value if first else merged.merge(value)
		first = false
	return merged

func _bounded_perimeter_chooser_controls() -> void:
	var source_cap := _runner_camera_limit("MAX_PERIMETER_REVIEW_SOURCES", 8)
	var candidate_cap := _runner_camera_limit("MAX_REVIEW_CAMERA_CANDIDATES", 64)
	_check("bounded_perimeter_chooser_declares_finite_caps", source_cap > 0 and source_cap <= 32 and candidate_cap > 0 and candidate_cap <= 64)
	var sources := [_chooser_source("perimeter_a", false, true, -6.0), _chooser_source("perimeter_b", true, true, -7.0)]
	var forward_runner := PerimeterChooserSyntheticRunner.new()
	root.add_child(forward_runner)
	var forward := _invoke_bounded_perimeter_chooser(forward_runner, sources, source_cap, candidate_cap)
	_check("first_recipe_clear_source_fails_composition_second_succeeds", forward.valid and forward.selectedSourceId == "perimeter_b" and forward.sourceTelemetry.size() == 2 and forward.sourceTelemetry[0].sourceId == "perimeter_a" and forward.sourceTelemetry[0].rejectedStage == "nearFieldComposition" and forward.sourceTelemetry[1].sourceId == "perimeter_b")
	var selected_telemetry: Dictionary = forward.sourceTelemetry[1] as Dictionary
	var selected_counts: Dictionary = selected_telemetry.predicateCounts as Dictionary
	_check("selected_perimeter_pose_ran_all_full_predicates", ["support", "capsule", "visualVolume", "physicsSightline", "visualSightline", "nearFieldComposition", "subjectReadability"].all(func(key): return int(selected_counts.get(key, 0)) > 0) and selected_telemetry.frameFloorChecked and selected_telemetry.frameCeilingChecked and float(forward.pose.subjectFrameFraction) >= Runner.MIN_REVIEW_SUBJECT_FRAME_FRACTION and float(forward.pose.subjectFrameFraction) <= Runner.MAX_REVIEW_SUBJECT_FRAME_FRACTION)
	_check("perimeter_chooser_candidate_counts_are_bounded", forward.sourceTelemetry.all(func(row): return int(row.candidateCount) > 0 and int(row.candidateCount) <= candidate_cap) and int(forward.totalCandidatesEvaluated) <= source_cap * candidate_cap)

	var reversed_sources: Array = sources.duplicate(true)
	reversed_sources.reverse()
	var reversed_runner := PerimeterChooserSyntheticRunner.new()
	root.add_child(reversed_runner)
	var reversed := _invoke_bounded_perimeter_chooser(reversed_runner, reversed_sources, source_cap, candidate_cap)
	_check("bounded_perimeter_chooser_reversed_input_is_byte_identical", var_to_bytes({"source": forward.selectedSourceId, "pose": forward.pose}) == var_to_bytes({"source": reversed.selectedSourceId, "pose": reversed.pose}))

	var invalid_runner := PerimeterChooserSyntheticRunner.new()
	root.add_child(invalid_runner)
	var invalid_sources := [_chooser_source("perimeter_a", false, true, -6.0), _chooser_source("perimeter_b", true, false, -7.0)]
	var invalid := _invoke_bounded_perimeter_chooser(invalid_runner, invalid_sources, source_cap, candidate_cap)
	_check("all_perimeter_sources_invalid_fails_closed_with_aggregate_telemetry", not invalid.valid and invalid.reason == "no_perimeter_review_source_has_valid_full_pose" and invalid.sourceTelemetry.size() == 2 and int(invalid.totalCandidatesEvaluated) <= invalid.sourceTelemetry.size() * candidate_cap and invalid.sourceTelemetry.all(func(row): return not bool(row.poseOk) and int(row.candidateCount) <= candidate_cap and not String(row.rejectedStage).is_empty()))

	var oversized_runner := PerimeterChooserSyntheticRunner.new()
	root.add_child(oversized_runner)
	var oversized_sources: Array = []
	for index in range(source_cap + 1):
		oversized_sources.append(_chooser_source("perimeter_%03d" % index, true, true, -6.0 - float(index) * 0.01))
	var work_before := oversized_runner.support_calls
	var oversized := _invoke_bounded_perimeter_chooser(oversized_runner, oversized_sources, source_cap, candidate_cap)
	_check("oversized_perimeter_source_collection_fails_before_scene_work", not oversized.valid and oversized.reason == "perimeter_review_source_cap_exceeded" and not oversized.sceneWorkStarted and oversized_runner.support_calls == work_before and oversized.sourceTelemetry.is_empty())
	forward_runner.free()
	reversed_runner.free()
	invalid_runner.free()
	oversized_runner.free()

func _chooser_source(id: String, composition_allowed: bool, readability_allowed: bool, candidate_z: float) -> Dictionary:
	return {"sourceId": id, "recipeClear": true, "focus": Vector3(0.0, 1.58, 0.0), "candidatePositions": [Vector3(0.0, 0.0, candidate_z)], "subjectRadius": 2.0, "minimumSupportY": -INF, "compositionAllowed": composition_allowed, "readabilityAllowed": readability_allowed}

func _invoke_bounded_perimeter_chooser(r: PerimeterChooserSyntheticRunner, sources: Array, source_cap: int, candidate_cap: int) -> Dictionary:
	if r.has_method("choose_bounded_perimeter_review_view"):
		return r.call("choose_bounded_perimeter_review_view", sources)
	_record_integration_point_once({"id": "bounded_perimeter_chooser", "requiredRunnerMethod": "choose_bounded_perimeter_review_view", "signature": "(eligible_sources: Array[Dictionary]) -> Dictionary"})
	return _synthetic_choose_bounded_perimeter_review_view(r, sources, source_cap, candidate_cap)

func _synthetic_choose_bounded_perimeter_review_view(r: PerimeterChooserSyntheticRunner, sources: Array, source_cap: int, candidate_cap: int) -> Dictionary:
	if sources.size() > source_cap:
		return {"valid": false, "reason": "perimeter_review_source_cap_exceeded", "sceneWorkStarted": false, "sourceTelemetry": [], "totalCandidatesEvaluated": 0}
	var ordered: Array = sources.duplicate(true)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary): return String(a.sourceId) < String(b.sourceId))
	var telemetry: Array = []
	var total_candidates := 0
	for source_value in ordered:
		var source: Dictionary = source_value as Dictionary
		var candidates: Array = source.get("candidatePositions", []) as Array
		if not bool(source.get("recipeClear", false)) or candidates.is_empty() or candidates.size() > candidate_cap:
			telemetry.append({"sourceId": String(source.get("sourceId", "")), "poseOk": false, "candidateCount": candidates.size(), "rejectedStage": "invalidRecipeOrCandidateDomain", "predicateCounts": {}, "frameFloorChecked": false, "frameCeilingChecked": false})
			continue
		r.reset_predicate_counts(source)
		var job = r.begin_exterior_review_pose_from_candidates(source.focus as Vector3, candidates, float(source.subjectRadius), float(source.minimumSupportY), Callable(r, "chooser_subject_readability_rejection"), _visible_surface_target)
		var progress: Dictionary = r.advance_exterior_review_pose(job, candidate_cap)
		total_candidates += int(progress.totalCandidatesEvaluated)
		var frame_checks_ran := int(r.predicate_counts.get("nearFieldComposition", 0)) > 0
		var rejected_stage := ""
		if not bool(progress.pose.get("ok", false)):
			if int(progress.pose.get("rejectedCandidates", {}).get("nearFieldComposition", 0)) > 0: rejected_stage = "nearFieldComposition"
			elif int(progress.pose.get("rejectedCandidates", {}).get("subjectRequirements", 0)) > 0: rejected_stage = "subjectReadability"
			else: rejected_stage = String(progress.pose.get("reason", "unknown"))
		telemetry.append({"sourceId": String(source.sourceId), "poseOk": bool(progress.pose.get("ok", false)), "candidateCount": candidates.size(), "candidatesEvaluated": int(progress.totalCandidatesEvaluated), "rejectedStage": rejected_stage, "predicateCounts": r.predicate_counts.duplicate(true), "frameFloorChecked": frame_checks_ran, "frameCeilingChecked": frame_checks_ran})
		if bool(progress.pose.get("ok", false)):
			return {"valid": true, "reason": "", "selectedSourceId": String(source.sourceId), "pose": progress.pose, "sourceTelemetry": telemetry, "totalCandidatesEvaluated": total_candidates, "sceneWorkStarted": true}
	return {"valid": false, "reason": "no_perimeter_review_source_has_valid_full_pose", "sourceTelemetry": telemetry, "totalCandidatesEvaluated": total_candidates, "sceneWorkStarted": not ordered.is_empty()}

func _runner_camera_limit(name: String, fallback: int) -> int:
	var probe = Runner.new()
	var constants: Dictionary = probe.get_script().get_script_constant_map()
	probe.free()
	if constants.has(name):
		return int(constants[name])
	_record_integration_point_once({"id": name, "requiredRunnerConstant": name, "maximum": fallback})
	return fallback

func _record_integration_point_once(record: Dictionary) -> void:
	if _integration_points.any(func(existing): return String(existing.get("id", "")) == String(record.get("id", ""))):
		return
	_integration_points.append(record)

func _blocked_first_perimeter_segment_control() -> void:
	var r := SyntheticRunner.new()
	r.blueprint = Blueprint.new("synthetic_perimeter_segment_selection", 6, "test")
	var records := [
		{"id": "public_support", "kind": "foundation", "material": "stone", "position": Vector3(0.0, 0.31, 5.0), "size": Vector3(30.0, 0.62, 30.0), "collision": true},
		{"id": "urban_perimeter_alley_-1_00", "kind": "foundation", "material": "cobble", "position": Vector3(0.0, 0.78, 0.0), "size": Vector3(2.1, 0.1, 5.0), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_west_00_wall", "kind": "wall", "material": "brick", "position": Vector3(-3.0, 3.0, 0.0), "size": Vector3(0.8, 5.0, 5.0), "collision": true, "semantic": "citadel_urban_facade"},
		{"id": "castle_terrace_blocker", "kind": "wall", "material": "stone", "position": Vector3(0.0, 1.5, 0.0), "size": Vector3(3.0, 3.0, 6.0), "collision": true},
		{"id": "urban_perimeter_alley_-1_01", "kind": "foundation", "material": "cobble", "position": Vector3(0.0, 0.78, 10.0), "size": Vector3(2.1, 0.1, 5.0), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_west_01_wall", "kind": "wall", "material": "brick", "position": Vector3(-3.0, 3.0, 10.0), "size": Vector3(0.8, 5.0, 5.0), "collision": true, "semantic": "citadel_urban_facade"}]
	for record in records:
		var part = r.blueprint.add_part(record)
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	var subject: Dictionary = r.perimeter_lane_review_subject()
	_check("blocked_first_perimeter_segment_selects_next_generated_segment", subject.valid and subject.alleyId == "urban_perimeter_alley_-1_01" and int(subject.candidateDomain.count) > 0 and int(subject.candidateDomain.count) <= 64)
	r.free()

func _reversed_source_order_control() -> void:
	var forward: SyntheticRunner = _source_order_fixture(false)
	var reversed: SyntheticRunner = _source_order_fixture(true)
	var forward_market: Dictionary = forward.market_review_subject()
	var reversed_market: Dictionary = reversed.market_review_subject()
	var forward_perimeter: Dictionary = forward.perimeter_lane_review_subject()
	var reversed_perimeter: Dictionary = reversed.perimeter_lane_review_subject()
	var forward_perimeter_subject := forward_perimeter.duplicate(true)
	var reversed_perimeter_subject := reversed_perimeter.duplicate(true)
	forward_perimeter_subject.erase("visualSnapshotBinding")
	forward_perimeter_subject.erase("visualSnapshotEpoch")
	reversed_perimeter_subject.erase("visualSnapshotBinding")
	reversed_perimeter_subject.erase("visualSnapshotEpoch")
	_check("reversed_source_order_preserves_generated_subjects", var_to_bytes(forward_market) == var_to_bytes(reversed_market) and var_to_bytes(forward_perimeter_subject) == var_to_bytes(reversed_perimeter_subject))
	_check("reversed_source_order_retains_distinct_snapshot_revisions", not String(forward_perimeter.get("visualSnapshotBinding", "")).is_empty() and not String(reversed_perimeter.get("visualSnapshotBinding", "")).is_empty() and String(forward_perimeter.get("visualSnapshotBinding", "")) != String(reversed_perimeter.get("visualSnapshotBinding", "")))
	forward.free()
	reversed.free()

func _source_order_fixture(reverse_source: bool) -> SyntheticRunner:
	var r := SyntheticRunner.new()
	r.blueprint = Blueprint.new("synthetic_source_order", 4, "test")
	var records := [
		{"id": "public_support", "kind": "foundation", "material": "stone", "position": Vector3(0.0, 0.31, 3.0), "size": Vector3(30.0, 0.62, 30.0), "collision": true},
		{"id": "urban_market_counter_b", "kind": "decor", "material": "timber", "position": Vector3(1.0, 1.5, 0.0), "size": Vector3(1.0, 0.2, 0.8), "collision": false},
		{"id": "urban_market_counter_a", "kind": "decor", "material": "timber", "position": Vector3(0.0, 1.5, 0.0), "size": Vector3(1.0, 0.2, 0.8), "collision": false},
		{"id": "urban_perimeter_alley_-1_00", "kind": "foundation", "material": "cobble", "position": Vector3(-4.0, 0.78, 7.0), "size": Vector3(2.1, 0.1, 5.0), "collision": false, "semantic": "citadel_perimeter_alley"},
		{"id": "urban_perimeter_west_00_wall", "kind": "wall", "material": "brick", "position": Vector3(-7.0, 3.0, 7.0), "size": Vector3(0.8, 5.0, 6.0), "collision": true, "semantic": "citadel_urban_facade"}]
	if reverse_source:
		records.reverse()
	for record in records:
		var part = r.blueprint.add_part(record)
		r.blueprint.physical_parts_by_id[part.id] = part
	r.build_review_visual_snapshot()
	return r

func _visible_surface_target(_camera_position: Vector3) -> Vector3:
	_visible_surface_calls += 1
	return Vector3(0.0, 1.58, 0.0)

func _generated_view_telemetry_control(r: SyntheticRunner, bounded_progress: Dictionary) -> void:
	var subject = r.blueprint.add_part({"id": "synthetic_narrow_subject", "kind": "decor", "material": "stone", "position": Vector3(0.0, 1.58, 0.0), "size": Vector3(2.0, 3.0, 2.0), "collision": false})
	r.blueprint.physical_parts_by_id[subject.id] = subject
	r.build_review_visual_snapshot()
	var bounds := r.review_part_bounds(subject)
	var source := {"valid": true, "focus": Vector3(0.0, 1.58, 0.0), "minimumSupportY": -INF,
		"subjectIds": [subject.id], "visibilityPartId": subject.id, "bounds": bounds,
		"supportId": "synthetic_declared_support", "supportIds": ["synthetic_declared_support"],
		"candidatePositions": [Vector3(0.0, 1.58, -6.0)],
		"candidateDomain": {"type": "explicit_positions", "count": 1, "bounds": AABB(Vector3(-0.1, 0.0, -6.1), Vector3(0.2, 2.0, 0.2))}}
	var view: Dictionary = r.make_subject_review_view("synthetic_bounded_evidence", "bounded generated subject", source, 10.0, 5.0, 6.0, 2.0, 0)
	var domain: Variant = view.get("cameraCandidateDomain")
	_check("generated_view_telemetry_records_subject_ids_and_bounds", view.get("cameraSubjectIds", []) == [subject.id] and view.get("cameraSubjectBounds") is AABB and (view.cameraSubjectBounds as AABB) == bounds)
	_check("generated_view_telemetry_records_candidate_domain_size_and_type", domain is Dictionary and int((domain as Dictionary).get("count", 0)) == 1 and String((domain as Dictionary).get("type", "")) == "explicit_positions")
	var bounded_pose: Dictionary = bounded_progress.get("pose", {}) as Dictionary
	_check("generated_view_telemetry_records_support_provenance", view.get("cameraDeclaredSupportIds", []) == ["synthetic_declared_support"] and view.cameraPoseSupport is Vector3 and (view.cameraPoseSupport as Vector3).is_finite() and String(bounded_pose.get("supportCollider", "")) == "synthetic_support_narrow_domain")

func _underfoot_support_classification_checks() -> void:
	var r := SyntheticRunner.new()
	var feet := Vector3(2.0, 0.81, -3.0)
	var support := StaticBody3D.new()
	support.set_meta("building_part_record", {"kind": "foundation", "position": Vector3(2.0, 0.38, -3.0), "rotation": Vector3.ZERO, "size": Vector3(3.0, 0.75, 3.0)})
	_check("exact_underfoot_construction_is_support", r.review_collider_is_underfoot_support(support, feet))
	support.set_meta("building_part_record", {"kind": "foundation", "position": Vector3(2.0, 1.25, -3.0), "rotation": Vector3.ZERO, "size": Vector3(3.0, 0.40, 3.0)})
	_check("raised_construction_remains_capsule_blocker", not r.review_collider_is_underfoot_support(support, feet))
	support.set_meta("building_part_record", {"kind": "wall", "position": Vector3(2.0, 0.38, -3.0), "rotation": Vector3.ZERO, "size": Vector3(3.0, 0.75, 3.0)})
	_check("wall_remains_capsule_blocker", not r.review_collider_is_underfoot_support(support, feet))
	support.set_meta("building_part_record", {"kind": "foundation", "position": Vector3(8.0, 0.38, -3.0), "rotation": Vector3.ZERO, "size": Vector3(2.0, 0.75, 2.0)})
	_check("out_of_footprint_surface_remains_capsule_blocker", not r.review_collider_is_underfoot_support(support, feet))
	support.free()
	r.free()

func _terminal_predicate_checks() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	root.add_child(viewport)
	var fixture := SyntheticVisual.new()
	viewport.add_child(fixture)
	fixture.blueprint = Blueprint.new("synthetic_camera_subject", 1, "test")
	var declarations := [
		["cloth", "decor", "citadel_terminal_shop_awning"],
		["bay_counter", "decor", "citadel_terminal_shop"],
		["goods", "pottery", "citadel_terminal_shop_goods"],
		["bay_wall_shelf", "decor", "citadel_terminal_shop"],
		["tools", "tool_rack", "citadel_terminal_shop_tools"],
		["sign", "sign", "citadel_terminal_shop_sign"],
		["bay_jamb_1", "beam", "citadel_terminal_shop_frame"],
		["rail", "beam", "terminal_awning_frame"],
		["bracket", "beam", "citadel_terminal_shop_joinery"],
		["standoff", "beam", "terminal_sign_mount"]]
	var ids: Array = []
	for row in declarations:
		var part = fixture.blueprint.add_part({"id": row[0], "kind": row[1], "semantic": row[2], "material": "timber_beam",
			"position": Vector3(0, 1.5, 0.1) if row[0] == "standoff" else Vector3(0, 1.5, 0), "size": Vector3.ONE * 0.1, "collision": false})
		fixture.blueprint.physical_parts_by_id[part.id] = part
		ids.append(row[0])
	var active := Camera3D.new()
	fixture.add_child(active)
	active.current = true
	var probe: Camera3D = fixture._make_terminal_review_probe()
	_check("probe_creation_preserves_active_camera", viewport.get_camera_3d() == active and not probe.current and probe.fov == 62.0 and is_equal_approx(probe.near, 0.05))
	var bounds := AABB(Vector3(-1, 0, -0.4), Vector3(2, 3, 0.8))
	var position := Vector3(0, 1.58, -6)
	var view := {"id": "synthetic_terminal", "target": bounds.get_center(), "maxDistance": 8.0, "requiresClear": true,
		"cameraPoseOk": true, "cameraPoseSupport": Vector3(position.x, 0.0, position.z), "cameraPoseFrameFraction": 0.5,
		"householdFrameBounds": bounds, "terminalReview": true, "terminalFront": Vector3.FORWARD,
		"terminalMemberIds": ids, "terminalSetup": {"prefix": "synthetic"}}
	fixture.block_standoff = true
	var rejected: String = fixture._terminal_camera_rejection(position, probe, bounds, Vector3.FORWARD, ids)
	var failed_audit: Dictionary = fixture.audit_review_camera_contract(view, probe)
	_check("clear_center_missing_standoff_rejects_shared_predicate_and_audit", rejected == "hidden_terminal_family" and failed_audit.targetClear and not failed_audit.passed and failed_audit.visibleMemberFamilies.signStandoff.is_empty())
	fixture.block_standoff = false
	var accepted: String = fixture._terminal_camera_rejection(position, probe, bounds, Vector3.FORWARD, ids)
	var audit: Dictionary = fixture.audit_review_camera_contract(view, probe)
	_check("eligible_predicate_matches_final_ten_family_audit", accepted.is_empty() and audit.passed and audit.completeTerminalBayFramed and audit.terminalFrontSide and audit.allRequiredFamiliesVisible and audit.visibleMemberFamilies.size() == 10)
	var missing: Array = ids.duplicate()
	missing.append("absent_member")
	_check("missing_member_fails_closed", fixture._terminal_camera_rejection(position, probe, bounds, Vector3.FORWARD, missing) == "hidden_terminal_family")
	_check("behind_subject_rejects", fixture._terminal_camera_rejection(Vector3(0, 1.58, 6), probe, bounds, Vector3.FORWARD, ids) == "behind_terminal")
	_check("too_close_full_frame_rejects", fixture._terminal_camera_rejection(Vector3(0, 1.58, -0.6), probe, bounds, Vector3.FORWARD, ids) == "incomplete_terminal_frame")
	probe.free()
	_check("probe_free_preserves_active_camera", viewport.get_camera_3d() == active)
	viewport.free()

func _check(id: String, passed: bool) -> void: _checks.append({"id": id, "passed": passed})
func _accept(_position: Vector3) -> String:
	_calls += 1
	return ""
func _reject_first(_position: Vector3) -> String:
	_calls += 1
	return "hidden_family" if _calls == 1 else ""
func _reject(_position: Vector3) -> String:
	_calls += 1
	return "hidden_family"
func _invalid(_position: Vector3) -> int:
	_calls += 1
	return 0
