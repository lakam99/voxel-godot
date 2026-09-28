extends "res://scripts/testing/buildings/PavingConstructionArtifactContract.gd"

## Actual source plus labelled synthetic through-dressing construction controls.
## Reuses the SHA-bound reader, actual proposal, CPU publisher class/history
## setup, and independent original-artifact witnesses. No extra SceneTree.
## Input ENV: same VOXEL_PAVING_ARTIFACT_SOURCE/_SOURCE_SHA256 and
## VOXEL_PAVING_ARTIFACT_DIAGNOSIS/_DIAGNOSIS_SHA256 as the parent contract.
## Output ENV: new absolute VOXEL_PAVING_FOOTING_CUT_REPORT JSON.
const FootCuts = preload("res://scripts/buildings/PavingFootingCutRecipe.gd")


func _run() -> void:
	var path := OS.get_environment("VOXEL_PAVING_FOOTING_CUT_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var synthetic: Dictionary = _through_synthetic()
	var actual: Dictionary = _through_actual()
	var report := {"passed": synthetic.passed and actual.get("passed", false), "synthetic": synthetic, "actual": actual,
		"evidenceLevel": "frozen_source_and_synthetic_finite_through_dressing_cut_recipe",
		"placementAccepted": false, "elapsedMsec": Time.get_ticks_msec() - started,
		"limitations": "Derives proposed cut prisms only. Original artifact is uncut. No final represented mesh, real-foot clearance, collision change, support/root proof, frame assembly, atomic frame+cut integration, shader/GPU or gameplay acceptance. Nominal .01 XZ joint is not a claim of exact realized mesh clearance. Main owns those next gates."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if written and report.passed else 2)


func _through_actual() -> Dictionary:
	var source_file: Dictionary = _bound_read("VOXEL_PAVING_ARTIFACT_SOURCE", WHOLE08_SHA, 33554432)
	if not source_file.completed: return source_file
	var diag_file: Dictionary = _bound_read("VOXEL_PAVING_ARTIFACT_DIAGNOSIS", DIAG02_SHA, 2097152)
	if not diag_file.completed: return diag_file
	var archive_value: Variant = bytes_to_var(source_file.bytes)
	var diag_value: Variant = JSON.parse_string(diag_file.bytes.get_string_from_utf8())
	if not archive_value is Dictionary or not diag_value is Dictionary: return {"reason": "invalid_archive_encoding"}
	var archive: Dictionary = archive_value
	var diag: Dictionary = diag_value
	if archive.get("schemaVersion") != 1 or archive.get("provenance") != "successful_full_facade_recipe_contract" or not archive.get("mainShardPassed", false): return {"reason": "invalid_source_provenance"}
	if not archive.get("beforeSnapshot") is Dictionary or not archive.get("furnitureSnapshot") is Dictionary or not archive.get("protectedReservations") is Array: return {"reason": "invalid_source_schema"}
	if not archive.beforeSnapshot.get("parts") is Array or not archive.beforeSnapshot.get("rooms") is Array or not archive.furnitureSnapshot.get("parts") is Array: return {"reason": "invalid_source_collections"}
	if archive.beforeSnapshot.parts.size() > 10000 or archive.beforeSnapshot.rooms.size() > 2048 or archive.furnitureSnapshot.parts.size() > 2048 or archive.protectedReservations.size() > 2048: return {"reason": "source_collection_limit"}
	if _archive_digest(archive.beforeSnapshot) != archive.get("sourceDigest") or _archive_digest({"furnitureParts": archive.furnitureSnapshot.parts, "reservedVolumes": archive.protectedReservations}) != archive.get("policyDigest"): return {"reason": "archive_digest_mismatch"}
	if not diag.get("diagnosticCompleted", false) or not diag.get("sourceUnchanged", false) or diag.get("artifactSha256") != source_file.sha256 or not diag.get("rows") is Array or diag.rows.size() > 512: return {"reason": "diagnosis_pairing_mismatch"}
	var b = FacadeSource.copy_blueprint(archive.beforeSnapshot)
	if _archive_digest(b.snapshot()) != archive.sourceDigest: return {"reason": "source_roundtrip_mismatch"}
	var proposal: Dictionary = _diagnosed_proposal(b, diag)
	if not proposal.get("completed", false): return proposal
	var source_before := var_to_bytes(b.snapshot())
	var furniture_before := var_to_bytes(archive.furnitureSnapshot)
	var reservations_before := var_to_bytes(archive.protectedReservations)
	var publisher = CpuContract.CpuMeshBatchPublisher.new()
	publisher.source_blueprint_id = publisher.canonical_source_blueprint_id(b)
	publisher.surface_history.configure(b.recipe, b.parts)
	publisher.paving_treatments = b.recipe.get("pavingTreatments", [])
	var history_before := _paving_history_digest(publisher.surface_history)
	# Describe ONCE. No repeated publisher construction or history sampling.
	var described: Dictionary = PavingGeometry.describe_source(proposal.part, publisher.surface_history, publisher.source_blueprint_id)
	var descriptor_before := var_to_bytes(described)
	var transform: Transform3D = b.part_transform(proposal.part)
	# Parent proposal.apertures are EXACT .36 x .20 x .36 foot boxes, with no
	# mortar expansion. This helper owns the separate intentional joint prism.
	var feet: Array[AABB] = proposal.apertures
	var feet_before := var_to_bytes(feet)
	var result: Dictionary = FootCuts.derive(described, transform, feet, FacadeSource.CLEARANCE)
	var checks: Dictionary = _through_checks(result, described, transform, feet, FacadeSource.CLEARANCE)
	var original_proof: Dictionary = {}
	if result.completed: original_proof = _artifact_proof(result.originalArtifact, described, transform, [], null)
	var preservation := {"sourceExact": var_to_bytes(b.snapshot()) == source_before,
		"descriptorExact": var_to_bytes(described) == descriptor_before, "feetExact": var_to_bytes(feet) == feet_before,
		"historyExact": _paving_history_digest(publisher.surface_history) == history_before,
		"furnitureExact": var_to_bytes(archive.furnitureSnapshot) == furniture_before,
		"reservationsExact": var_to_bytes(archive.protectedReservations) == reservations_before,
		"sourceFileExact": FileAccess.get_sha256(source_file.path) == source_file.sha256,
		"diagnosisFileExact": FileAccess.get_sha256(diag_file.path) == diag_file.sha256}
	return {"passed": checks.passed and original_proof.get("passed", false) and preservation.values().all(func(value): return value == true),
		"sourceSha256": source_file.sha256, "diagnosisSha256": diag_file.sha256, "pavingPartId": proposal.part.id,
		"proposal": proposal.report, "checks": checks, "result": _compact_through(result), "originalArtifactProof": original_proof,
		"preservation": preservation, "furnitureCount": archive.furnitureSnapshot.parts.size(), "descriptionBuildCount": 1,
		"recipeSha256": FileAccess.get_sha256("res://scripts/buildings/PavingFootingCutRecipe.gd"),
		"contractSha256": FileAccess.get_sha256("res://scripts/testing/buildings/PavingFootingCutRecipeContract.gd")}


func _through_synthetic() -> Dictionary:
	var described: Dictionary = _through_descriptor()
	var rows: Array = []
	for mode in ["axis", "tilted_distinct_parent"]:
		var transform := Transform3D.IDENTITY if mode == "axis" else Transform3D(Basis.from_euler(Vector3(0.12, 0.31, -0.09)), Vector3(5.3, 0.9, -3.2))
		var feet: Array[AABB] = [AABB(transform.origin + Vector3(-0.18, -0.04, -0.18), Vector3(0.36, 0.20, 0.36)),
			AABB(transform.origin + Vector3(0.82, -0.04, 0.82), Vector3(0.36, 0.20, 0.36))]
		var before := var_to_bytes(described)
		var feet_before := var_to_bytes(feet)
		var result: Dictionary = FootCuts.derive(described, transform, feet, 0.01)
		var proof: Dictionary = _through_checks(result, described, transform, feet, 0.01)
		rows.append({"mode": mode, "passed": proof.passed and before == var_to_bytes(described) and feet_before == var_to_bytes(feet), "proof": proof, "result": _compact_through(result)})
		var reordered: Array[AABB] = [feet[1], feet[0], feet[1]]
		var repeated: Dictionary = FootCuts.derive(described, transform, reordered, 0.01)
		var replay: Dictionary = FootCuts.derive(described, transform, result.feet if result.completed else feet, 0.01)
		rows.append({"mode": mode + "_duplicate_reorder_replay", "passed": result.completed and repeated.completed and replay.completed and var_to_bytes(result) == var_to_bytes(repeated) and var_to_bytes(result) == var_to_bytes(replay)})
	var negatives: Array = _through_negatives(described)
	return {"passed": rows.all(func(row): return row.passed) and negatives.all(func(row): return row.passed), "positiveCases": rows, "negativeCases": negatives}


func _through_descriptor() -> Dictionary:
	return {"ready": true, "bed": {"size": Vector3(4, 0.12, 4), "position": Vector3.ZERO, "materialId": "stone_foundation"},
		"regularTransforms": [Transform3D(Basis.from_euler(Vector3(0.19, 0.37, -0.12)).scaled(Vector3(0.8, 0.07, 0.6)), Vector3(0.3, 0.1, 0.1))],
		"regularCustomData": [Color(0, 0.1, 0.2, 0.3)], "regularIds": [Vector2i(1, 1)],
		"wornTransforms": [Transform3D(Basis.from_euler(Vector3(-0.13, -0.24, 0.09)).scaled(Vector3(0.7, 0.09, 0.5)), Vector3(1.2, 0.28, 1.1))],
		"wornCustomData": [Color(0, 0.7, 0.6, 0.2)], "wornIds": [Vector2i(1, 2)]}


func _through_checks(result: Dictionary, described: Dictionary, transform: Transform3D, input_feet: Array[AABB], joint: float) -> Dictionary:
	if not result.completed: return {"passed": false, "reason": result.reason, "detail": result.get("detail", "")}
	var checks := {"original_compile_once": result.originalCompileCount == 1,
		"original_descriptor_digest": result.originalArtifact.descriptorDigest == _value_digest(described),
		"source_transform_exact": result.originalArtifact.sourceTransform == transform,
		"original_remains_native_uncut": result.originalArtifact.canonicalApertures.is_empty() and result.originalArtifact.entries.all(func(entry): return entry.unchanged and entry.cells.size() == 1 and entry.cells[0].representation == "native_box"),
		"nominal_joint_exact": result.nominalJoint == joint, "input_feet_preserved": true, "complete_finish_extrema": true,
		"complete_tilted_geometry_inside_finite_Y": true, "geometry_derived_Y_padding": true,
		"nominal_XZ_expansion": true, "positive_represented_joint": true, "actual_finish_overlap_witness": result.overlapWitnesses.size() == result.feet.size()}
	var minimum := INF
	var maximum := -INF
	var represented_points: Array = []
	for entry in result.originalArtifact.entries:
		var bounds: AABB = entry.cells[0].bounds
		minimum = minf(minimum, float(bounds.position.y))
		maximum = maxf(maximum, float(bounds.end.y))
		var poly: Dictionary = _box_faces(entry.original.transform)
		represented_points.append_array(poly.vertices)
	var height: float = maximum - minimum
	checks.complete_finish_extrema = result.finishYMinimum == minimum and result.finishYMaximum == maximum and result.finishHeight == height
	checks.geometry_derived_Y_padding = result.nominalCutBottom == minimum - height and result.nominalCutTop == maximum + height
	for foot in input_feet: checks.input_feet_preserved = checks.input_feet_preserved and result.feet.has(foot)
	var expected_cuts: Array[AABB] = []
	var nominal_widths: Array = []
	for foot in result.feet:
		checks.input_feet_preserved = checks.input_feet_preserved and input_feet.has(foot)
		var expected := AABB(Vector3(float(foot.position.x) - joint, minimum - height, float(foot.position.z) - joint), Vector3(float(foot.size.x) + 2.0 * joint, height * 3.0, float(foot.size.z) + 2.0 * joint))
		if not expected_cuts.has(expected): expected_cuts.append(expected)
		checks.nominal_XZ_expansion = checks.nominal_XZ_expansion and result.apertures.has(expected)
		nominal_widths.append({"footWidth": foot.size.x, "apertureWidth": expected.size.x, "footHeightUnchanged": foot.size.y})
		# Decimal .36 + .01 + .01 has unavoidable float32 encoding; this check
		# concerns the declared width only, never a contact/clearance exemption.
		checks.nominal_XZ_expansion = checks.nominal_XZ_expansion and absf(expected.size.x - 0.38) <= 0.000001
		checks.positive_represented_joint = checks.positive_represented_joint and expected.position.x < foot.position.x and expected.end.x > foot.end.x and expected.position.z < foot.position.z and expected.end.z > foot.end.z
	for aperture in result.apertures:
		checks.nominal_XZ_expansion = checks.nominal_XZ_expansion and expected_cuts.has(aperture)
		for point in represented_points:
			checks.complete_tilted_geometry_inside_finite_Y = checks.complete_tilted_geometry_inside_finite_Y and aperture.position.y < point.y and aperture.end.y > point.y
	checks.nominal_XZ_expansion = checks.nominal_XZ_expansion and result.apertures.size() == expected_cuts.size()
	for witness in result.overlapWitnesses: checks.actual_finish_overlap_witness = checks.actual_finish_overlap_witness and witness.intersectionVolume > 0.0
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks, "nominalWidths": nominal_widths,
		"originalSolidCount": result.originalArtifact.entries.size(), "representedCornerCount": represented_points.size()}


func _through_negatives(described: Dictionary) -> Array:
	var rows: Array = []
	for mode in ["zero_Y", "negative_size", "nonfinite_foot", "huge_foot", "collapsed_foot", "empty_feet", "too_many_feet", "zero_joint", "negative_joint", "nonfinite_joint", "joint_above_policy", "unrelated_XZ", "unrelated_Y", "joint_only_overlap", "AABB_only_overlap", "invalid_descriptor", "solid_limit", "bad_source_transform", "late_unrelated_foot"]:
		var descriptor: Dictionary = described.duplicate(true)
		var transform := Transform3D.IDENTITY
		var feet: Array[AABB] = [AABB(Vector3(-0.18, -0.04, -0.18), Vector3(0.36, 0.20, 0.36))]
		var joint := 0.01
		match mode:
			"zero_Y": feet[0] = AABB(Vector3.ZERO, Vector3(0.36, 0, 0.36))
			"negative_size": feet[0] = AABB(Vector3.ZERO, Vector3(-0.36, 0.20, 0.36))
			"nonfinite_foot": feet[0] = AABB(Vector3(NAN, 0, 0), Vector3.ONE)
			"huge_foot": feet[0] = AABB(Vector3(1e20, 0, 0), Vector3.ONE)
			"collapsed_foot": feet[0] = AABB(Vector3(65536, 0, 0), Vector3(0.0001, 1, 1))
			"empty_feet": feet.clear()
			"too_many_feet":
				while feet.size() <= FootCuts.MAX_FEET: feet.append(feet[0])
			"zero_joint": joint = 0.0
			"negative_joint": joint = -0.01
			"nonfinite_joint": joint = NAN
			"joint_above_policy": joint = 0.0501
			"unrelated_XZ": feet[0] = AABB(Vector3(8, -0.04, 8), Vector3(0.36, 0.20, 0.36))
			"unrelated_Y": feet[0] = AABB(Vector3(-0.18, 4, -0.18), Vector3(0.36, 0.20, 0.36))
			"joint_only_overlap": feet[0] = AABB(Vector3(2.005, -0.04, -0.18), Vector3(0.36, 0.20, 0.36))
			"AABB_only_overlap":
				descriptor.bed.size = Vector3(2, 0.12, 2)
				for group in ["regular", "worn"]:
					for suffix in ["Transforms", "CustomData", "Ids"]: descriptor[group + suffix] = []
				transform = Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3.ZERO)
				feet[0] = AABB(Vector3(1.15, -0.04, 1.15), Vector3(0.1, 0.20, 0.1))
			"invalid_descriptor": descriptor.ready = false
			"solid_limit":
				for suffix in ["Transforms", "CustomData", "Ids"]: descriptor["regular" + suffix].resize(Cut.HARD_LIMITS.maxSolids)
			"bad_source_transform": transform = Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0))
			"late_unrelated_foot": feet.append(AABB(Vector3(8, -0.04, 8), Vector3(0.36, 0.20, 0.36)))
		var before := var_to_bytes(descriptor)
		var feet_before := var_to_bytes(feet)
		var result: Dictionary = FootCuts.derive(descriptor, transform, feet, joint)
		var reason_correct := true
		if mode in ["unrelated_XZ", "unrelated_Y", "joint_only_overlap", "AABB_only_overlap", "late_unrelated_foot"]: reason_correct = result.get("reason") == "foot_has_no_actual_finish_overlap"
		if mode == "too_many_feet": reason_correct = result.get("reason") == "foot_collection_limit"
		if mode == "solid_limit": reason_correct = result.get("detail") == "solid_limit_exceeded"
		rows.append({"mode": mode, "reason": result.get("reason", ""), "detail": result.get("detail", ""), "work": result.work,
			"passed": not result.completed and not result.has("apertures") and not result.has("originalArtifact") and reason_correct and var_to_bytes(descriptor) == before and var_to_bytes(feet) == feet_before})
	return rows


func _compact_through(result: Dictionary) -> Dictionary:
	if not result.completed: return result
	return {"completed": true, "feet": result.feet.map(func(value): return str(value)), "apertures": result.apertures.map(func(value): return str(value)),
		"nominalJoint": result.nominalJoint, "finishYMinimum": result.finishYMinimum, "finishYMaximum": result.finishYMaximum,
		"finishHeight": result.finishHeight, "nominalCutBottom": result.nominalCutBottom, "nominalCutTop": result.nominalCutTop,
		"originalCompileCount": result.originalCompileCount, "work": result.work, "overlapWitnesses": result.overlapWitnesses,
		"descriptorDigest": result.originalArtifact.descriptorDigest, "constructionDigest": result.originalArtifact.constructionDigest}
