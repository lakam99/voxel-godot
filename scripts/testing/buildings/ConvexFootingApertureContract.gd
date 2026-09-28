extends SceneTree

## Independent SYNTHETIC solid-geometry checks only. No publisher, renderer,
## physical-support validator, navigation, live scene or gameplay acceptance.
## Run by main under its existing watchdog, never launched by this author.
const Cut = preload("res://scripts/buildings/ConvexFootingAperture.gd")
const TOL := 0.00003


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_CONVEX_FOOTING_APERTURE_REPORT")
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var rows: Array = []
	var cube: Dictionary = _solid("cube", Transform3D(Basis.IDENTITY.scaled(Vector3(2, 2, 2)), Vector3.ZERO))
	var untouched: Dictionary = _solid("bed_null_custom", Transform3D(Basis.IDENTITY.scaled(Vector3(3, 0.08, 4)), Vector3(10, 0.8, 0)), true)
	var through := AABB(Vector3(-0.5, -2, -0.5), Vector3(1, 4, 1))
	var cavity := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	rows.append(_positive("empty_cut_preserves_native_and_opaque_fields", [cube, untouched], [], 8.96))
	var remote: Dictionary = _solid("small_remote_native", Transform3D(Basis.from_euler(Vector3(0.02, 0.03, -0.015)).scaled(Vector3(0.12, 0.07, 0.58)), Vector3(67, 0.81, -23.1)))
	rows.append(_positive("small_remote_native_identity_not_inverse_cancellation", [remote], [], 0.004872))
	rows.append(_positive("disjoint_cut_preserves_native", [cube], [AABB(Vector3(3, 3, 3), Vector3.ONE)], 8.0))
	rows.append(_positive("face_contact_preserves_native", [cube], [AABB(Vector3(1, -0.5, -0.5), Vector3.ONE)], 8.0))
	rows.append(_positive("edge_contact_preserves_native", [cube], [AABB(Vector3(1, 1, -0.5), Vector3.ONE)], 8.0))
	rows.append(_positive("vertex_contact_preserves_native", [cube], [AABB(Vector3.ONE, Vector3.ONE)], 8.0))
	rows.append(_positive("central_through_aperture_four_survivors", [cube, untouched], [through], 6.96))
	rows.append(_positive("cut_bed_preserves_null_custom_data", [untouched], [AABB(Vector3(9.5, 0, -0.5), Vector3(1, 2, 1))], 0.88))
	rows.append(_positive("finite_internal_cavity_six_caps", [cube], [cavity], 7.0))
	rows.append(_positive("boundary_cut_half_volume", [cube], [AABB(Vector3(0, -2, -2), Vector3(2, 4, 4))], 4.0))
	rows.append(_positive("source_fully_removed_explicit_empty_union", [cube], [AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))], 0.0))
	var overlap_a := AABB(Vector3(-0.75, -2, -0.5), Vector3(1, 4, 1))
	var overlap_b := AABB(Vector3(-0.25, -2, -0.5), Vector3(1, 4, 1))
	rows.append(_positive("overlap_union_not_double_subtracted", [cube], [overlap_a, overlap_b], 5.0))
	rows.append(_replay(cube, overlap_a, overlap_b))
	# Central symmetry proves each arbitrary rotated box is halved by world x=0.
	for angles in [Vector3(0, 0.4, 0), Vector3(0.29, 0.61, -0.18), Vector3(-0.38, -0.77, 0.41)]:
		var rotated: Dictionary = _solid("tilted", Transform3D(Basis.from_euler(angles).scaled(Vector3(2, 1.5, 2.4)), Vector3.ZERO))
		rows.append(_positive("tilted_world_halfspace_" + str(angles), [rotated], [AABB(Vector3(0, -4, -4), Vector3(4, 8, 8))], 3.6))
	var diamond: Dictionary = _solid("diamond", Transform3D(Basis(Vector3.UP, PI / 4.0).scaled(Vector3(2, 1, 2)), Vector3.ZERO))
	rows.append(_positive("aabb_overlap_but_true_box_miss_native", [diamond], [AABB(Vector3(1.1, -0.2, 1.1), Vector3(0.2, 0.4, 0.2))], 4.0))
	# Coordinates/height representative of finish, but entirely synthetic geometry.
	var thin: Dictionary = _solid("thin_sett", Transform3D(Basis.from_euler(Vector3(0.02, 0.03, -0.015)).scaled(Vector3(0.8, 0.07, 0.58)), Vector3(51.13, 0.81, -23.1)))
	rows.append(_positive("thin_tilted_finish_real_caps", [thin], [AABB(Vector3(51.03, 0.7, -23.2), Vector3(0.2, 0.5, 0.2))]))
	rows.append(_witness_negative_controls(cube, cavity))
	rows.append(_critic_bounds_case())
	rows.append(_signed_overlap_controls())
	var negatives: Array = _negative_cases(cube, through)
	var report := {"evidenceLevel": "synthetic_convex_construction_geometry", "positiveCases": rows, "negativeCases": negatives,
		"passed": rows.all(func(row): return row.passed) and negatives.all(func(row): return row.passed),
		"elapsedMsec": Time.get_ticks_msec() - started,
		"scope": "Independent boundary tetrahedral volume, oriented closed convex faces, local/world coordinates, original containment, solid SAT disjointness from cuts and other fragments, deterministic replay and untouched descriptor bytes.",
		"limitations": "No actual settled-cobble publication, GPU, material/UV shader parity, structural bearing, collision integration, navigation or gameplay acceptance. Polyhedron caps include internal partition faces; publisher must consume solid union semantics. No engine launched by author."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if written and report.passed else 2)


func _solid(id: String, transform: Transform3D, null_custom := false) -> Dictionary:
	return {"id": id, "transform": transform, "materialKey": "cobble:test",
		"customData": null if null_custom else Color(0.0, 0.3721, 0.125, 0.875),
		"opaque": {"row": -7, "column": 13, "family": "synthetic", "packed": PackedInt32Array([5, 3, 9])}}


func _positive(label: String, solids: Array, cuts: Array[AABB], expected_remaining := -1.0) -> Dictionary:
	var before := var_to_bytes(solids)
	var cuts_before := var_to_bytes(cuts)
	var result: Dictionary = Cut.subtract_boxes(solids, cuts)
	var checks := {"completed": result.completed, "source_unchanged": var_to_bytes(solids) == before,
		"cuts_unchanged": var_to_bytes(cuts) == cuts_before}
	var proofs: Array = []
	if result.completed:
		checks["entry_count"] = result.entries.size() == solids.size()
		var sum := 0.0
		for index in range(result.entries.size()):
			var proof: Dictionary = _entry_proof(result.entries[index], solids[index], cuts)
			proofs.append(proof)
			sum += float(proof.volume)
		checks["all_independent_geometry_checks"] = proofs.all(func(proof): return proof.passed)
		checks["reported_remaining_matches_faces"] = absf(sum - result.remainingVolume) <= TOL * maxf(1.0, result.inputVolume)
		checks["reported_volume_conservation"] = absf(result.inputVolume - result.remainingVolume - result.removedVolume) <= TOL * maxf(1.0, result.inputVolume)
		if expected_remaining >= 0.0: checks["analytic_expected_volume"] = absf(sum - expected_remaining) <= TOL * maxf(1.0, expected_remaining)
		if label.contains("native") or label.begins_with("empty_cut"):
			checks["explicit_unchanged_native_cells"] = result.entries.all(func(entry): return entry.unchanged and entry.cells.size() == 1 and entry.cells[0].representation == "native_box")
		if label == "central_through_aperture_four_survivors": checks["four_survivors_and_untouched_neighbor"] = result.entries[0].cells.size() == 4 and result.entries[1].unchanged
		if label == "finite_internal_cavity_six_caps": checks["six_survivors"] = result.entries[0].cells.size() == 6
		if label == "source_fully_removed_explicit_empty_union": checks["removed_not_native_or_ambiguous"] = not result.entries[0].unchanged and result.entries[0].cells.is_empty() and result.entries[0].removedVolume > 0.0
	return {"label": label, "passed": checks.values().all(func(value): return value == true), "checks": checks,
		"reason": result.get("reason", ""), "work": result.work, "fragments": result.get("fragmentCount", 0), "geometry": proofs}


func _entry_proof(entry: Dictionary, original: Dictionary, cuts: Array[AABB]) -> Dictionary:
	var checks := {"original_descriptor_exact": var_to_bytes(entry.original) == var_to_bytes(original),
		"closed_convex_outward_faces": true, "world_local_roundtrip": true, "contained_in_original": true,
		"native_transform_and_corners_exact": true, "no_positive_cut_intersection": true, "no_uncertain_intersections": true, "pairwise_disjoint_interiors": true, "valid_face_provenance": true}
	var total := 0.0
	var polys: Array = []
	var intersection_rows: Array = []
	for cell in entry.cells:
		var poly: Dictionary = _cell_poly(cell)
		polys.append(poly)
		var proof: Dictionary = _poly_proof(poly)
		checks.closed_convex_outward_faces = checks.closed_convex_outward_faces and proof.passed
		total += float(proof.volume)
		if cell.representation == "native_box":
			# Native geometry IS the original transformed unit box. Re-inverting
			# tiny boxes at distant world origins adds cancellation to an identity
			# that can instead be proved exactly. Never trust `unchanged` alone:
			# require exact transform AND every represented canonical corner.
			var expected: Dictionary = _box_faces(original.transform)
			var native_exact: bool = var_to_bytes(cell.transform) == var_to_bytes(original.transform) and var_to_bytes(poly.vertices) == var_to_bytes(expected.vertices)
			checks.native_transform_and_corners_exact = checks.native_transform_and_corners_exact and native_exact
			checks.contained_in_original = checks.contained_in_original and native_exact
		else:
			# Changed-polyhedron containment stays strict and unchanged.
			for point in poly.vertices:
				var local: Vector3 = original.transform.affine_inverse() * point
				checks.contained_in_original = checks.contained_in_original and absf(local.x) <= 0.5 + TOL and absf(local.y) <= 0.5 + TOL and absf(local.z) <= 0.5 + TOL
		for cut in cuts:
			var cut_poly: Dictionary = _box_faces(Transform3D(Basis.IDENTITY.scaled(cut.size), cut.get_center()))
			var intersection: Dictionary = _sat_measure(poly, cut_poly)
			checks.no_positive_cut_intersection = checks.no_positive_cut_intersection and intersection.status != "positive_overlap"
			checks.no_uncertain_intersections = checks.no_uncertain_intersections and intersection.status != "uncertain"
			if intersection.status not in ["separated", "contact"] and intersection_rows.size() < 16:
				intersection_rows.append({"kind": "cell_vs_cut", "cellIndex": polys.size() - 1, "cut": str(cut), "measurement": intersection})
		if cell.representation == "convex_polyhedron":
			for face in cell.faces:
				checks.valid_face_provenance = checks.valid_face_provenance and _provenance_valid(face, original, cuts)
				checks.world_local_roundtrip = checks.world_local_roundtrip and face.worldVertices.size() == face.localVertices.size()
				for index in range(face.worldVertices.size()):
					checks.world_local_roundtrip = checks.world_local_roundtrip and (original.transform * face.localVertices[index]).distance_to(face.worldVertices[index]) <= TOL
	for i in range(polys.size()):
		for j in range(i + 1, polys.size()):
			var intersection: Dictionary = _sat_measure(polys[i], polys[j])
			checks.pairwise_disjoint_interiors = checks.pairwise_disjoint_interiors and intersection.status in ["separated", "contact"]
			checks.no_uncertain_intersections = checks.no_uncertain_intersections and intersection.status != "uncertain"
			if intersection.status not in ["separated", "contact"] and intersection_rows.size() < 16:
				intersection_rows.append({"kind": "cell_vs_cell", "cells": [i, j], "measurement": intersection})
	return {"passed": checks.values().all(func(value): return value == true), "checks": checks, "volume": total, "cellCount": entry.cells.size(), "intersectionRows": intersection_rows}


func _cell_poly(cell: Dictionary) -> Dictionary:
	if cell.representation == "native_box": return _box_faces(cell.transform)
	var faces: Array = []
	var vertices: Array[Vector3] = []
	for face in cell.faces:
		faces.append(face.worldVertices)
		for point in face.worldVertices:
			if not vertices.has(point): vertices.append(point)
	return {"faces": faces, "vertices": vertices}


func _box_faces(transform: Transform3D) -> Dictionary:
	# Fixed independently authored cube topology, not utility corner/face helpers.
	var local := [Vector3(-0.5, -0.5, -0.5), Vector3(0.5, -0.5, -0.5), Vector3(0.5, 0.5, -0.5), Vector3(-0.5, 0.5, -0.5),
		Vector3(-0.5, -0.5, 0.5), Vector3(0.5, -0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5)]
	var vertices: Array[Vector3] = []
	for point in local: vertices.append(transform * point)
	var faces: Array = []
	for indices in [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [0, 1, 5, 4], [3, 7, 6, 2]]:
		var face: PackedVector3Array = []
		for index in indices: face.append(vertices[index])
		faces.append(face)
	return {"faces": faces, "vertices": vertices}


func _poly_proof(poly: Dictionary) -> Dictionary:
	var center := Vector3.ZERO
	for point in poly.vertices: center += point
	center /= float(poly.vertices.size())
	var volume := 0.0
	var closed := true
	var convex := true
	var outward := true
	var edges: Array = []
	for face in poly.faces:
		var area := Vector3.ZERO
		for index in range(1, face.size() - 1): area += (face[index] - face[0]).cross(face[index + 1] - face[0])
		if area.length_squared() == 0.0: return {"passed": false, "volume": 0.0}
		var normal: Vector3 = area.normalized()
		outward = outward and normal.dot(face[0] - center) > 0.0
		for point in face: convex = convex and absf(normal.dot(point - face[0])) <= TOL
		for point in poly.vertices: convex = convex and normal.dot(point - face[0]) <= TOL
		# Sum positive tetrahedra from interior centroid (independent reference).
		for index in range(1, face.size() - 1):
			volume += absf((face[0] - center).dot((face[index] - center).cross(face[index + 1] - center))) / 6.0
		for index in range(face.size()): edges.append([face[index], face[(index + 1) % face.size()]])
	for edge in edges:
		var reverse_count := 0
		for other in edges:
			if edge[0] == other[1] and edge[1] == other[0]: reverse_count += 1
		closed = closed and reverse_count == 1
	return {"passed": closed and convex and outward and volume > 0.0, "volume": volume}


func _sat_measure(a: Dictionary, b: Dictionary) -> Dictionary:
	# Independent convex SAT: face normals AND every edge cross product. Source
	# AABB overlap alone is deliberately insufficient (diamond negative control).
	# Signed overlap is never swallowed by TOL. Arbitrary projection directions
	# prove separation too; axis-aligned projections of represented float32
	# coordinates are exact in scalar float64, including exact cap contact.
	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var edge_sets: Array = []
	for poly in [a, b]:
		var edges: Array[Vector3] = []
		for face in poly.faces:
			var area := Vector3.ZERO
			for index in range(1, face.size() - 1): area += (face[index] - face[0]).cross(face[index + 1] - face[0])
			if area.length_squared() > 0.0: axes.append(area.normalized())
			for index in range(face.size()):
				var edge: Vector3 = face[(index + 1) % face.size()] - face[index]
				if edge.length_squared() > 0.0: edges.append(edge.normalized())
		edge_sets.append(edges)
	for ea in edge_sets[0]:
		for eb in edge_sets[1]:
			var cross: Vector3 = ea.cross(eb)
			if cross.length_squared() > 0.0: axes.append(cross.normalized())
	var minimum := INF
	var minimum_error := 0.0
	var minimum_axis := Vector3.ZERO
	var contact := false
	var uncertain := false
	for axis in axes:
		var amin := INF
		var amax := -INF
		var bmin := INF
		var bmax := -INF
		var magnitude := 0.0
		for point in a.vertices:
			var value: float = _projection64(point, axis)
			amin = minf(amin, value)
			amax = maxf(amax, value)
			magnitude = maxf(magnitude, _projection_magnitude(point, axis))
		for point in b.vertices:
			var value: float = _projection64(point, axis)
			bmin = minf(bmin, value)
			bmax = maxf(bmax, value)
			magnitude = maxf(magnitude, _projection_magnitude(point, axis))
		var exact_axis: bool = axis.abs() in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
		var error: float = 0.0 if exact_axis else magnitude * 0.000000000000004
		var overlap: float = minf(amax, bmax) - maxf(amin, bmin)
		if overlap < minimum:
			minimum = overlap
			minimum_error = error
			minimum_axis = axis
		if overlap < -error: return {"status": "separated", "signedOverlap": overlap, "projectionErrorBound": error, "axis": str(axis)}
		if overlap == 0.0 and exact_axis: contact = true
		elif overlap <= error: uncertain = true
	return {"status": "contact" if contact else ("uncertain" if uncertain else "positive_overlap"),
		"signedOverlap": minimum, "projectionErrorBound": minimum_error, "axis": str(minimum_axis)}


func _projection64(point: Vector3, axis: Vector3) -> float:
	return float(point.x) * float(axis.x) + float(point.y) * float(axis.y) + float(point.z) * float(axis.z)


func _projection_magnitude(point: Vector3, axis: Vector3) -> float:
	return absf(float(point.x) * float(axis.x)) + absf(float(point.y) * float(axis.y)) + absf(float(point.z) * float(axis.z))


func _critic_bounds_case() -> Dictionary:
	var original: Dictionary = _solid("critic_inward_extent", Transform3D(Basis.IDENTITY.scaled(Vector3(1.1, 1, 1)), Vector3(0.1, 0, 0)))
	var corners: Dictionary = _box_faces(original.transform)
	var old_bounds := AABB(corners.vertices[0], Vector3.ZERO)
	var maximum := -INF
	for point in corners.vertices:
		old_bounds = old_bounds.expand(point)
		maximum = maxf(maximum, point.x)
	# Explicit critic numeric boundary, represented as float32 on assignment.
	var start := Vector3(0.6499999761581421, -1, -1)
	var cut := AABB(start, Vector3(1, 2, 2))
	var result: Dictionary = Cut.subtract_boxes([original], [cut])
	var enclosure := true
	var native: Dictionary = Cut.subtract_boxes([original], [])
	if native.completed:
		var bounds: AABB = native.entries[0].cells[0].bounds
		for point in corners.vertices:
			for axis in range(3): enclosure = enclosure and bounds.position[axis] <= point[axis] and bounds.end[axis] >= point[axis]
	else: enclosure = false
	return {"label": "critic_inward_AABB_extent_preserves_represented_corner_sliver", "passed": result.completed and native.completed and enclosure and maximum > start.x and not result.entries[0].unchanged and result.removedVolume > 0.0,
		"representedMaximumX": maximum, "oldExpandEndX": old_bounds.end.x, "cutStartX": start.x,
		"reason": result.get("reason", ""), "removedVolume": result.get("removedVolume", 0.0)}


func _signed_overlap_controls() -> Dictionary:
	var a: Dictionary = _box_faces(Transform3D.IDENTITY)
	var measurements: Array = []
	var passed := true
	for depth in [0.00002, 0.000001, 0.00000011920928955078125]:
		var b: Dictionary = _box_faces(Transform3D(Basis.IDENTITY, Vector3(1.0 - depth, 0, 0)))
		var measurement: Dictionary = _sat_measure(a, b)
		measurements.append(measurement)
		passed = passed and measurement.status == "positive_overlap" and measurement.signedOverlap > 0.0
	var contact: Dictionary = _sat_measure(a, _box_faces(Transform3D(Basis.IDENTITY, Vector3(1, 0, 0))))
	var basis := Basis(Vector3.UP, PI / 4.0)
	var uncertain: Dictionary = _sat_measure(_box_faces(Transform3D(basis, Vector3.ZERO)), _box_faces(Transform3D(basis, basis.x)))
	return {"label": "represented_sub_30um_overlap_not_silently_separated", "passed": passed and contact.status == "contact" and uncertain.status == "uncertain", "measurements": measurements, "contact": contact, "obliqueTouchUncertain": uncertain}


func _provenance_valid(face: Dictionary, original: Dictionary, cuts: Array[AABB]) -> bool:
	var provenance: Dictionary = face.provenance
	if provenance.kind == "original_face":
		var index: int = provenance.faceIndex
		if index < 0 or index >= 6: return false
		var axis: int = index / 2
		var value := -0.5 if index % 2 == 0 else 0.5
		for point in face.worldVertices:
			var local: Vector3 = original.transform.affine_inverse() * point
			if absf(local[axis] - value) > TOL: return false
		return true
	if provenance.kind != "cut_plane" or not cuts.has(provenance.aperture): return false
	var index: int = provenance.planeIndex
	if index < 0 or index >= 6: return false
	var axis: int = index / 2
	var cut: AABB = provenance.aperture
	var value: float = cut.end[axis] if index % 2 == 1 else cut.position[axis]
	for point in face.worldVertices:
		if point[axis] != value: return false
	var sign := 1.0 if index % 2 == 1 else -1.0
	if not provenance.insideHalfspace: sign = -sign
	return face.normal[axis] * sign >= 1.0 - TOL


func _replay(cube: Dictionary, a: AABB, b: AABB) -> Dictionary:
	var first: Dictionary = Cut.subtract_boxes([cube], [a, b])
	var reordered: Dictionary = Cut.subtract_boxes([cube], [b, a])
	var duplicate: Dictionary = Cut.subtract_boxes([cube], [b, a, a, b])
	var first_step: Dictionary = Cut.subtract_boxes([cube], [a])
	var replay_cuts: Array[AABB] = []
	if first_step.completed: replay_cuts.assign(first_step.canonicalApertures)
	replay_cuts.append(b)
	replay_cuts.append(a)
	var replay: Dictionary = Cut.subtract_boxes([cube], replay_cuts)
	var completed: bool = first.completed and reordered.completed and duplicate.completed and replay.completed and first_step.completed
	return {"label": "canonical_order_duplicates_and_original_descriptor_replay", "passed": completed and var_to_bytes(first.entries) == var_to_bytes(reordered.get("entries")) and var_to_bytes(first.entries) == var_to_bytes(duplicate.get("entries")) and var_to_bytes(first.entries) == var_to_bytes(replay.get("entries"))}


func _witness_negative_controls(cube: Dictionary, cavity: AABB) -> Dictionary:
	var valid: Dictionary = Cut.subtract_boxes([cube], [cavity])
	if not valid.completed: return {"label": "independent_witness_negative_controls", "passed": false}
	var forged: Dictionary = valid.entries[0].duplicate(true)
	# Putting the removed solid back must fail SAT even if reported totals lie.
	forged.cells.append({"representation": "native_box", "transform": Transform3D(Basis.IDENTITY, Vector3.ZERO)})
	var overlap_proof: Dictionary = _entry_proof(forged, cube, [cavity])
	var outside: Dictionary = valid.entries[0].duplicate(true)
	outside.cells.append({"representation": "native_box", "transform": Transform3D(Basis.IDENTITY, Vector3(8, 0, 0))})
	var outside_proof: Dictionary = _entry_proof(outside, cube, [cavity])
	var inverted: Dictionary = valid.entries[0].duplicate(true)
	inverted.cells[0].faces[0].worldVertices.reverse()
	var inverted_proof: Dictionary = _entry_proof(inverted, cube, [cavity])
	var changed_transform: Transform3D = cube.transform
	changed_transform.origin.x += 0.000001 # Below the old arithmetic tolerance.
	var forged_native := {"original": cube.duplicate(true), "unchanged": true,
		"cells": [{"representation": "native_box", "transform": changed_transform}]}
	var native_proof: Dictionary = _entry_proof(forged_native, cube, [])
	return {"label": "independent_witness_negative_controls", "passed": not overlap_proof.checks.no_positive_cut_intersection and not outside_proof.checks.contained_in_original and not inverted_proof.checks.closed_convex_outward_faces and not native_proof.passed and not native_proof.checks.native_transform_and_corners_exact,
		"forgedNativeTransformRejected": not native_proof.passed, "forgedNativeChecks": native_proof.checks}


func _negative_cases(cube: Dictionary, through: AABB) -> Array:
	var cases: Array = []
	for mode in ["zero_axis", "negative_determinant", "near_singular", "nan_transform", "huge_transform", "missing_transform", "duplicate_id", "empty_id", "invalid_custom", "nonfinite_custom", "missing_custom", "invalid_material", "non_dictionary", "zero_cut", "negative_cut", "nan_cut", "huge_cut", "collapsed_represented_cut", "invalid_limit", "unknown_limit", "work_limit", "fragment_limit", "per_solid_fragment_limit", "face_limit", "vertex_limit", "solid_limit", "aperture_limit", "late_invalid", "late_fragment_limit"]:
		var solids: Array = [cube.duplicate(true)]
		var cuts: Array[AABB] = [through]
		var limits: Dictionary = {}
		match mode:
			"zero_axis": solids[0].transform = Transform3D(Basis.IDENTITY.scaled(Vector3(0, 1, 1)), Vector3.ZERO)
			"negative_determinant": solids[0].transform = Transform3D(Basis.IDENTITY.scaled(Vector3(-1, 1, 1)), Vector3.ZERO)
			"near_singular": solids[0].transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(1, 0.000001, 0), Vector3(0, 0, 1)), Vector3.ZERO)
			"nan_transform": solids[0].transform = Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0))
			"huge_transform": solids[0].transform = Transform3D(Basis.IDENTITY, Vector3(1e20, 0, 0))
			"missing_transform": solids[0].erase("transform")
			"duplicate_id": solids.append(solids[0].duplicate(true))
			"empty_id": solids[0].id = ""
			"invalid_custom": solids[0].customData = Vector3.ONE
			"nonfinite_custom": solids[0].customData = Color(NAN, 0, 0, 1)
			"missing_custom": solids[0].erase("customData")
			"invalid_material": solids[0].materialKey = 4
			"non_dictionary": solids.append(null)
			"zero_cut": cuts = [AABB(Vector3.ZERO, Vector3(0, 1, 1))]
			"negative_cut": cuts = [AABB(Vector3.ZERO, Vector3(-1, 1, 1))]
			"nan_cut": cuts = [AABB(Vector3(NAN, 0, 0), Vector3.ONE)]
			"huge_cut": cuts = [AABB(Vector3(1e20, 0, 0), Vector3.ONE)]
			"collapsed_represented_cut": cuts = [AABB(Vector3(65536, 0, 0), Vector3(0.0001, 1, 1))]
			"invalid_limit": limits = {"maxWork": -1}
			"unknown_limit": limits = {"epsilon": 0.5}
			"work_limit": limits = {"maxWork": 32}
			"fragment_limit": limits = {"maxFragments": 1}
			"per_solid_fragment_limit": limits = {"maxFragmentsPerSolid": 1}
			"face_limit": limits = {"maxFacesPerCell": 4}
			"vertex_limit": limits = {"maxVerticesPerFace": 3}
			"solid_limit":
				limits = {"maxSolids": 1}
				solids.append(_solid("other", Transform3D.IDENTITY))
			"aperture_limit":
				limits = {"maxApertures": 1}
				cuts.append(through)
			"late_invalid": solids.append({"id": "broken"})
			"late_fragment_limit":
				limits = {"maxFragments": 4}
				solids.append(_solid("second", Transform3D(Basis.IDENTITY, Vector3(9, 0, 0))))
		var before := var_to_bytes(solids)
		var cuts_before := var_to_bytes(cuts)
		var limits_before := var_to_bytes(limits)
		var result: Dictionary = Cut.subtract_boxes(solids, cuts, limits)
		var reason_correct := true
		if mode == "work_limit": reason_correct = result.get("reason") == "work_limit_exceeded"
		if mode in ["fragment_limit", "per_solid_fragment_limit", "late_fragment_limit"]: reason_correct = result.get("reason") == "fragment_limit_exceeded"
		cases.append({"label": mode, "reason": result.get("reason", ""), "work": result.work,
			"passed": not result.completed and not result.has("entries") and reason_correct and before == var_to_bytes(solids) and cuts_before == var_to_bytes(cuts) and limits_before == var_to_bytes(limits)})
	return cases
