extends SceneTree

## Synthetic source occupancy only. Accepted contact is not collision clearance,
## a bearing, rendered concealment, publication proof, or live acceptance.
const Replacement = preload("res://scripts/buildings/OpeningHeadReplacementAdmission.gd")
const Band = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
var _checks: Dictionary = {}
var _results: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_HEAD_REPLACEMENT_ADMISSION_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var prior: Dictionary = _fixture(0.0)
	var prior_result: Dictionary = _probe("preexisting_overlap", prior)
	_checks["preexisting_overlap_admitted_not_clear"] = _contact(prior_result, "preexisting_source_overlap_retained") and prior_result.get("seamCells", []).is_empty()
	_checks["preexisting_overlap_removed_volume_proven"] = prior_result.get("contacts", []).size() == 1 and prior_result.contacts[0].removedCoverage.covered
	var seam: Dictionary = _fixture(1.0e-6)
	var seam_result: Dictionary = _probe("unchanged_cardinal_world_covers_seam", seam)
	_checks["seam_admitted_not_clear"] = _contact(seam_result, "declared_seam_fill_with_world_occupancy_nonregression")
	var left = seam.before.find_part("synthetic_panel_left")
	var right = seam.before.find_part("synthetic_panel_right")
	# Independently compute the represented Part faces, not a float32 AABB.
	var left_end: float = float(left.position.z) + float(left.size.z) * 0.5
	var right_start: float = float(right.position.z) - float(right.size.z) * 0.5
	var actual_gap: float = right_start - left_end
	_checks["represented_gap_positive_within_existing_policy"] = actual_gap > 0.0 and actual_gap <= Band.EDGE_EPS
	var expected: Array = [-0.125, 0.5, left_end, 0.125, 1.0, right_start]
	var cells: Array = seam_result.get("seamCells", [])
	_checks["gap_not_erased_exact_added_cell"] = cells.size() == 1 and cells[0] == expected
	var policy: Dictionary = Band.construction_seam_cells([-0.125, 0.5, -1.0, 0.125, 1.0, 1.0], [left, right])
	_checks["direct_seam_policy_same_nonempty_cell"] = policy.get("ready", false) and policy.get("addedSolidCells", []) == [expected]
	_checks["actual_cardinal_witness_recorded"] = seam_result.get("unchangedCardinalWitnessIds", []) == ["synthetic_witness"]
	var contacts: Array = seam_result.get("contacts", [])
	var proofs: Array = contacts[0].get("seamProofs", []) if contacts.size() == 1 else []
	_checks["finite_seam_has_both_positive_coverage_proofs"] = proofs.size() == 1 and proofs[0].cell == expected and proofs[0].declaredSeamCoverage.covered and proofs[0].unchangedWorldCoverage.covered
	_results["representedGap"] = {"requested": 1.0e-6, "actualScalarGap": actual_gap, "expectedCell": expected, "policy": policy}
	for mode: String in ["removed", "narrowed", "moved"]:
		var altered: Dictionary = _fixture(1.0e-6)
		var witness = altered.after.find_part("synthetic_witness")
		if mode == "removed":
			altered.after.parts.erase(witness)
			altered.after.physical_parts_by_id.erase(witness.id)
		elif mode == "narrowed": witness.size.z *= 0.5
		else: witness.position.x += 0.5
		_reject("world_witness_" + mode, altered)
	var oversized: Dictionary = _fixture(Band.EDGE_EPS * 4.0)
	_reject("oversized_undeclared_gap", oversized)
	var blocked: Dictionary = _fixture(1.0e-6)
	blocked.volumes = [AABB(Vector3(-0.05, 0.625, -0.6), Vector3(0.1, 0.125, 0.2))]
	_reject("protected_aperture_intersection", blocked)
	var extension: Dictionary = _fixture(1.0e-6)
	var extended_panel = extension.after.find_part("synthetic_panel_left")
	extended_panel.position.y = 0.75
	extended_panel.size.y = 1.0
	_reject("retained_panel_extends_old_volume", extension)
	var rotated: Dictionary = _fixture(1.0e-6, true)
	_reject("rotated_envelope_is_not_cardinal_coverage", rotated)
	# The rotated witness intersects the body, but its envelope alone cannot
	# supply the required positive unchanged-cardinal coverage of the seam.
	var rotated_part = rotated.before.find_part("synthetic_witness")
	var rotated_pose: Transform3D = rotated.before.part_transform(rotated_part) * Transform3D(Basis.from_scale(rotated_part.size), Vector3.ZERO)
	_checks["rotated_control_noncardinal"] = not Replacement.Admission._cardinal(rotated_pose.basis)
	_checks["rotated_control_actual_sat_not_clear"] = not Replacement.Admission.measure(Transform3D(Basis.from_scale(rotated.body.size), rotated.body.position), rotated_pose).clear
	var envelope_covers: bool = true
	for axis in range(3):
		var radius: float = (absf(float(rotated_pose.basis.x[axis])) + absf(float(rotated_pose.basis.y[axis])) + absf(float(rotated_pose.basis.z[axis]))) * 0.5
		envelope_covers = envelope_covers and float(rotated_pose.origin[axis]) - radius <= expected[axis] and float(rotated_pose.origin[axis]) + radius >= expected[axis + 3]
	_checks["rotated_envelope_covers_seam_but_is_insufficient"] = envelope_covers
	var reverse_input: Dictionary = _fixture(1.0e-6)
	reverse_input.ids.reverse()
	reverse_input.before.parts.reverse()
	reverse_input.after.parts.reverse()
	var reversed_result: Dictionary = _probe("reversed_panel_source_order", reverse_input)
	_checks["source_order_exact_determinism"] = var_to_bytes(seam_result) == var_to_bytes(reversed_result)
	_candidate_world_controls(expected)
	_local_witness_reuse_controls()
	_finish(path)

func _local_witness_reuse_controls() -> void:
	# The prepared witness belongs to one evaluate call. Reusing the same live
	# Blueprint objects after an actual edit must construct a new witness set.
	var fixture: Dictionary = _fixture(1.0e-6)
	var original: Dictionary = _probe("local_witness_initial",fixture)
	for source in [fixture.before,fixture.after]: source.find_part("synthetic_witness").position.x = 10.0
	var moved: Dictionary = _probe("local_witness_moved_between_calls",fixture)
	_checks["local_witness_edit_rebuilds_current_coverage"] = original.get("allAddedSeamsPreoccupied")==true \
		and moved.get("ready")==true and moved.get("allAddedSeamsPreoccupied")==false \
		and not moved.get("newWorldSeamCells",[]).is_empty() \
		and moved.get("unchangedCardinalWitnessIds")==original.get("unchangedCardinalWitnessIds")
	for source in [fixture.before,fixture.after]: source.find_part("synthetic_witness").position.x = 0.0
	var restored: Dictionary = _probe("local_witness_restored_between_calls",fixture)
	_checks["local_witness_restore_recovers_complete_typed_report"] = var_to_bytes(restored)==var_to_bytes(original)
	# This pose is admissible to SAT, but its positive X face is outside the
	# scalar occupancy domain. Preserve the original lazy consumption boundary:
	# with no seam/contact query the bad witness list is never consulted.
	var unused: Dictionary = _fixture(0.0)
	for source in [unused.before,unused.after]: source.find_part("synthetic_witness").position.x = 100000.0
	var unused_result: Dictionary = _probe("unused_out_of_domain_witness",unused)
	_checks["unused_invalid_world_bounds_do_not_add_early_failure"] = unused_result.get("ready")==true \
		and unused_result.get("allSeamWorldCoverage",[]).is_empty() and unused_result.get("contacts",[]).is_empty()
	var consumed: Dictionary = _fixture(1.0e-6)
	for source in [consumed.before,consumed.after]: source.find_part("synthetic_witness").position.x = 100000.0
	var consumed_result: Dictionary = _probe("queried_out_of_domain_witness",consumed)
	_checks["invalid_world_bounds_fail_at_original_cover_boundary"] = consumed_result.get("ready")==false \
		and consumed_result.get("reason")=="whole_seam_coverage_unresolved"
	_add(consumed.after,_record("synthetic_candidate_intrusion","wall",Vector3(0,0.75,0),Vector3(0.125,0.25,0.25)))
	var first_failure: Dictionary = _probe("candidate_intrusion_before_invalid_world_cover",consumed)
	_checks["witness_preparation_preserves_candidate_failure_order"] = first_failure.get("ready")==false \
		and first_failure.get("reason")=="candidate_foreign_collision_intrusion" \
		and first_failure.get("peerId")=="synthetic_candidate_intrusion"

func _candidate_world_controls(expected_seam: Array) -> void:
	var moved_inside: Dictionary = _fixture(1.0e-6)
	var old_witness = moved_inside.before.find_part("synthetic_witness")
	old_witness.position.x = 10.0 # After retains x=0: old-clear cannot mask new intrusion.
	var old_pose: Transform3D = moved_inside.before.part_transform(old_witness) * Transform3D(Basis.from_scale(old_witness.size), Vector3.ZERO)
	var body_pose := Transform3D(Basis.from_scale(moved_inside.body.size), moved_inside.body.position)
	_checks["moved_inside_original_pose_actually_clear"] = Replacement.Admission.measure(body_pose, old_pose).clear
	_reject("old_clear_witness_moved_into_body", moved_inside)
	var moved_result: Dictionary = _results.old_clear_witness_moved_into_body
	_checks["moved_inside_candidate_intrusion_identified"] = moved_result.get("reason") == "candidate_foreign_collision_intrusion" and moved_result.get("peerId") == "synthetic_witness"
	var added_inside: Dictionary = _fixture(1.0e-6)
	_add(added_inside.after, _record("synthetic_new_inside", "wall", Vector3(0, 0.75, 0), Vector3(0.125, 0.25, 0.25)))
	_reject("candidate_only_collider_inside_body", added_inside)
	var added_result: Dictionary = _results.candidate_only_collider_inside_body
	_checks["candidate_only_intrusion_identified"] = added_inside.before.find_part("synthetic_new_inside") == null and added_result.get("reason") == "candidate_foreign_collision_intrusion" and added_result.get("peerId") == "synthetic_new_inside"
	var added_far: Dictionary = _fixture(1.0e-6)
	_add(added_far.after, _record("synthetic_new_far", "wall", Vector3(10, 0.75, 0), Vector3(0.25, 0.5, 2)))
	var far_result: Dictionary = _probe("candidate_only_far_collider", added_far)
	_checks["candidate_only_far_collider_allowed_and_counted"] = added_far.before.find_part("synthetic_new_far") == null and far_result.get("ready") == true and int(far_result.get("candidateChangedForeignCount", 0)) > 0
	_checks["far_addition_does_not_erase_existing_contact"] = _contact(far_result, "declared_seam_fill_with_world_occupancy_nonregression")
	var unoccupied: Dictionary = _fixture(1.0e-6)
	for b in [unoccupied.before, unoccupied.after]:
		var witness = b.find_part("synthetic_witness")
		b.parts.erase(witness)
		b.physical_parts_by_id.erase(witness.id)
	var unoccupied_result: Dictionary = _probe("seam_without_any_world_witness", unoccupied)
	_checks["unoccupied_seam_measurement_ready"] = unoccupied_result.get("ready") == true
	_checks["unoccupied_seam_new_world_cell_exact_nonempty"] = unoccupied_result.get("newWorldSeamCells", []) == [expected_seam] and unoccupied_result.get("seamCells", []) == [expected_seam]
	_checks["unoccupied_seam_not_whole_world_nonregression"] = unoccupied_result.get("allAddedSeamsPreoccupied") == false
	_checks["unoccupied_seam_has_no_hidden_witness"] = unoccupied_result.get("unchangedCardinalWitnessIds", []) == [] and unoccupied_result.get("testedForeignCount") == 0 and unoccupied_result.get("candidateChangedForeignCount") == 0
	var coverage: Array = unoccupied_result.get("allSeamWorldCoverage", [])
	_checks["unoccupied_seam_explicit_uncovered_proof"] = coverage.size() == 1 and coverage[0].cell == expected_seam and coverage[0].unchangedWorldCoverage.get("covered") == false and coverage[0].unchangedWorldCoverage.get("uncovered", []) == [expected_seam]
	_results["unoccupiedSeamEvidenceLimit"] = "A ready source measurement or clear source-box comparison does not certify whole-world occupancy nonregression. Nonempty newWorldSeamCells requires separate normal collision-clearance and visual/construction acceptance; neither is supplied by this synthetic fixture."

func _fixture(gap: float, rotated_witness: bool = false) -> Dictionary:
	var before = Blueprint.new("synthetic_replacement_occupancy", 0, "timber")
	var after = Blueprint.new("synthetic_replacement_occupancy", 0, "timber")
	var ids: Array = []
	for side: float in [-1.0, 1.0]:
		var id: String = "synthetic_panel_left" if side < 0.0 else "synthetic_panel_right"
		ids.append(id)
		var center_z: float = side * (0.5 + gap * 0.25)
		var depth: float = 1.0 - gap * 0.5
		_add(before, _record(id, "wall", Vector3(0, 0.5, center_z), Vector3(0.25, 1, depth)))
		_add(after, _record(id, "wall", Vector3(0, 0.25, center_z), Vector3(0.25, 0.5, depth)))
	var witness: Dictionary = _record("synthetic_witness", "wall", Vector3(0, 0.75, 0), Vector3(0.25, 0.5, 2))
	if rotated_witness: witness.rotation = Vector3(0, PI * 0.25, 0)
	_add(before, witness)
	_add(after, witness)
	var body: Dictionary = _record("synthetic_header", "beam", Vector3(0, 0.75, 0), Vector3(0.25, 0.5, 2))
	return {"before": before, "after": after, "body": body, "ids": ids, "seats": [], "volumes": []}

func _record(id: String, kind: String, position: Vector3, size: Vector3) -> Dictionary:
	return {"id": id, "kind": kind, "material": "stone_foundation" if kind == "wall" else "timber", "position": position,
		"size": size, "rotation": Vector3.ZERO, "collision": true, "semantic": "synthetic_occupancy", "recipe": {"physicalIntent": "structural_mass"}}

func _add(b, record: Dictionary) -> void:
	var part = b.add_part(record)
	b.physical_parts_by_id[part.id] = part

func _probe(name: String, fixture: Dictionary) -> Dictionary:
	var before_bytes: PackedByteArray = _input_bytes(fixture)
	var result: Dictionary = Replacement.evaluate(fixture.before, fixture.after, fixture.body, fixture.ids, fixture.seats, fixture.volumes)
	_checks[name + "_caller_immutable"] = before_bytes == _input_bytes(fixture)
	var repeat: Dictionary = Replacement.evaluate(fixture.before, fixture.after, fixture.body, fixture.ids, fixture.seats, fixture.volumes)
	_checks[name + "_repeat_exact"] = var_to_bytes(result) == var_to_bytes(repeat) and before_bytes == _input_bytes(fixture)
	_results[name] = result
	return result

func _input_bytes(fixture: Dictionary) -> PackedByteArray:
	return var_to_bytes([fixture.before.snapshot(), fixture.after.snapshot(), fixture.body, fixture.ids, fixture.seats, fixture.volumes])

func _contact(result: Dictionary, classification: String) -> bool:
	var contacts: Array = result.get("contacts", [])
	return result.get("ready") == true and result.get("clear") == false and contacts.size() == 1 and contacts[0].get("classification") == classification

func _reject(name: String, fixture: Dictionary) -> void:
	var result: Dictionary = _probe(name, fixture)
	_checks[name + "_rejected"] = result.get("ready") == false and not String(result.get("reason", "")).is_empty() and not result.get("clear", false)

func _finish(path: String) -> void:
	var passed: bool = not _checks.is_empty() and _checks.values().all(func(v): return v == true)
	var report: Dictionary = {"passed": passed, "evidenceLevel": "synthetic_source_replacement_occupancy_only", "checks": _checks, "results": _results,
		"limitations": "Actual Blueprint/Part records, no physical validation or physics frames. Admitted old overlap/seam fill is explicitly not collision clear or bearing proof. New unoccupied seam cells do not establish whole-world occupancy nonregression and require separate normal collision-clearance and visual/construction acceptance. No real-house, rendered concealment, publication, GPU or live gameplay acceptance."}
	var bytes: PackedByteArray = JSON.stringify(report, "  ").to_utf8_buffer()
	if FileAccess.file_exists(path) or bytes.size() > 1024 * 1024:
		quit(2)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_length() == bytes.size()
	file.close()
	var hashing := HashingContext.new()
	written = written and hashing.start(HashingContext.HASH_SHA256) == OK
	if written:
		written = hashing.update(bytes) == OK
		if written: written = FileAccess.get_sha256(path) == hashing.finish().hex_encode()
	quit(0 if passed and written else 2)
