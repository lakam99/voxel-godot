extends RefCounted

## Unwired source-only replacement proof. It never changes strict SAT clearance
## and never promotes a covering obstacle to a structural seat.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const ConstructionMath = preload("res://scripts/buildings/ConstructionSeamMath.gd")
const Occupancy = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const MAX_WORK := 250000

static func evaluate(before, after, body: Dictionary, replaced_ids: Array, seat_ids: Array, protected_volumes: Array) -> Dictionary:
	if before == null or after == null or before.parts.size() > 10000 or after.parts.size() > 10000 or replaced_ids.is_empty() or replaced_ids.size() > 512 or protected_volumes.size() > 2048: return _fail("invalid_source_limits")
	if not body.get("position") is Vector3 or not body.get("size") is Vector3 or not body.get("recipe") is Dictionary: return _fail("invalid_body_input")
	var candidate := Part.new(body)
	if not body.get("size") is Vector3 or candidate.size != body.size or candidate.kind != "beam" or candidate.rotation != Vector3.ZERO: return _fail("invalid_body")
	var bounds := _bounds(candidate)
	if not Occupancy.valid(bounds) or not Admission._valid(Transform3D(Basis.from_scale(candidate.size), candidate.position)): return _fail("invalid_body_bounds")
	var original: Array = []
	var original_boxes: Array = []
	var retained_boxes: Array = []
	var ids: Dictionary = {}
	for id: Variant in replaced_ids:
		if not id is String or ids.has(id): return _fail("invalid_replacement_ids")
		ids[id] = true
		var old = before.find_part(id)
		var retained = after.find_part(id)
		if old == null or retained == null or old.rotation != Vector3.ZERO or retained.rotation != Vector3.ZERO or old.kind != "wall" or retained.kind != "wall" or not old.collision_enabled or not retained.collision_enabled: return _fail("invalid_replacement_panel")
		var old_bounds := _bounds(old)
		var retained_bounds := _bounds(retained)
		if bounds[0] != old_bounds[0] or bounds[3] != old_bounds[3]: return _fail("body_outside_original_facade_plane")
		var inside := Occupancy.cover(retained_bounds, [old_bounds])
		if not inside.ready or not inside.covered: return _fail("retained_panel_expands_source")
		original.append(old)
		original_boxes.append(old_bounds)
		retained_boxes.append(retained_bounds)
	var removed := Occupancy.removed(original_boxes, retained_boxes)
	if not removed.ready: return removed
	var seams := ConstructionMath.construction_seam_cells(bounds, original)
	if not seams.ready: return seams
	for volume: Variant in protected_volumes:
		if not volume is AABB: return _fail("invalid_aperture_volume")
		var box := [float(volume.position.x), float(volume.position.y), float(volume.position.z), float(volume.end.x), float(volume.end.y), float(volume.end.z)]
		if not Occupancy.valid(box): return _fail("invalid_aperture_volume")
		if not Occupancy.intersection(bounds, box).is_empty(): return _fail("protected_aperture_blocked")
	var foreign: Array = []
	var witnesses: Array = []
	var unchanged_solids: Array = []
	var witness_ids: Array = []
	for peer in before.parts:
		if not peer.collision_enabled or replaced_ids.has(peer.id): continue
		var current = after.find_part(peer.id)
		var unchanged: bool = current != null and current.position == peer.position and current.rotation == peer.rotation and current.size == peer.size and current.collision_enabled == peer.collision_enabled
		var pose: Transform3D = before.part_transform(peer) * Transform3D(Basis.from_scale(peer.size), Vector3.ZERO)
		if not Admission._valid(pose): return _fail("invalid_foreign_pose")
		var peer_bounds := _pose_bounds(pose)
		if unchanged and Admission._cardinal(pose.basis):
			witnesses.append({"id": peer.id, "bounds": peer_bounds})
		if not seat_ids.has(peer.id): foreign.append({"id": peer.id, "pose": pose, "bounds": peer_bounds, "unchanged": unchanged})
	witnesses.sort_custom(func(a, b): return a.id < b.id)
	foreign.sort_custom(func(a, b): return a.id < b.id)
	for witness: Dictionary in witnesses:
		unchanged_solids.append(witness.bounds)
		witness_ids.append(witness.id)
	if unchanged_solids.size() > Occupancy.MAX_CELLS: return _fail("world_witness_limit")
	var contacts: Array = []
	var pose := Transform3D(Basis.from_scale(candidate.size), candidate.position)
	var work: int = removed.work + seams.work
	# Candidate-only additions and old-clear colliders moved into the proposal
	# cannot escape through an early clear result on their previous pose.
	var candidate_changed_count := 0
	for current in after.parts:
		if not current.collision_enabled or current.id == candidate.id or replaced_ids.has(current.id) or seat_ids.has(current.id): continue
		var previous = before.find_part(current.id)
		if previous != null and previous.position == current.position and previous.rotation == current.rotation and previous.size == current.size and previous.collision_enabled == current.collision_enabled: continue
		candidate_changed_count += 1
		work += 1
		if work > MAX_WORK: return _fail("replacement_work_limit")
		var current_pose: Transform3D = after.part_transform(current) * Transform3D(Basis.from_scale(current.size), Vector3.ZERO)
		var measured := Admission.measure(pose, current_pose)
		if not measured.valid or not measured.clear: return {"ready": false, "reason": "candidate_foreign_collision_intrusion", "peerId": current.id, "measurement": measured}
	var all_seam_coverage: Array = []
	var new_world_seams: Array = []
	for cell: Array in seams.addedSolidCells:
		var covered := Occupancy.cover(cell, unchanged_solids)
		if not covered.ready: return _fail("whole_seam_coverage_unresolved")
		work += covered.work
		if work > MAX_WORK: return _fail("replacement_work_limit")
		all_seam_coverage.append({"cell": cell, "unchangedWorldCoverage": covered})
		new_world_seams.append_array(covered.uncovered)
		if new_world_seams.size() > Occupancy.MAX_CELLS: return _fail("new_world_seam_cell_limit")
	var clear_count := 0
	for peer: Dictionary in foreign:
		work += 1
		if work > MAX_WORK: return _fail("replacement_work_limit")
		var measured := Admission.measure(pose, peer.pose)
		if not measured.valid: return _fail("invalid_source_measurement")
		if measured.clear:
			clear_count += 1
			continue
		if not peer.unchanged: return {"ready": false, "reason": "contacting_foreign_collision_source_changed", "peerId": peer.id}
		var overlap := Occupancy.intersection(bounds, peer.bounds)
		var prior := Occupancy.cover(overlap, removed.cells)
		if not prior.ready: return _fail("unresolved_foreign_intersection")
		work += prior.work
		if work > MAX_WORK: return _fail("replacement_work_limit")
		var proofs: Array = []
		for cell: Array in prior.uncovered:
			var declared := Occupancy.cover(cell, seams.addedSolidCells)
			var world := Occupancy.cover(cell, unchanged_solids)
			if not declared.ready or not world.ready: return _fail("seam_coverage_unresolved")
			work += declared.work + world.work
			if work > MAX_WORK: return _fail("replacement_work_limit")
			if not declared.covered or not world.covered: return {"ready": false, "reason": "new_or_undeclared_occupied_cell", "peerId": peer.id, "cell": cell, "declared": declared, "world": world}
			proofs.append({"cell": cell, "declaredSeamCoverage": declared, "unchangedWorldCoverage": world})
		contacts.append({"peerId": peer.id, "intersection": overlap, "removedCoverage": prior, "seamProofs": proofs,
			"classification": "preexisting_source_overlap_retained" if prior.covered else "declared_seam_fill_with_world_occupancy_nonregression"})
	return {"ready": true, "clear": contacts.is_empty(), "contacts": contacts, "removedCells": removed.cells, "seamCells": seams.addedSolidCells,
		"allSeamWorldCoverage": all_seam_coverage, "allAddedSeamsPreoccupied": new_world_seams.is_empty(), "newWorldSeamCells": new_world_seams,
		"candidateChangedForeignCount": candidate_changed_count,
		"testedForeignCount": foreign.size(), "clearForeignCount": clear_count, "protectedApertureCount": protected_volumes.size(),
		"unchangedCardinalWitnessIds": witness_ids, "work": work,
		"scope": "Original/candidate source collision admission only. Contact residuals prove old occupancy or declared seams within unchanged solids, not collision clearance. newWorldSeamCells explicitly records other declared seam additions: whole-body/world collision-union equality is NOT claimed. New seam additions still need separate visual/construction acceptance. Covering solids are not bearings. No rendered concealment, support, publication or live acceptance."}

static func _bounds(part) -> Array:
	return [float(part.position.x) - float(part.size.x) * 0.5, float(part.position.y) - float(part.size.y) * 0.5, float(part.position.z) - float(part.size.z) * 0.5,
		float(part.position.x) + float(part.size.x) * 0.5, float(part.position.y) + float(part.size.y) * 0.5, float(part.position.z) + float(part.size.z) * 0.5]

static func _pose_bounds(pose: Transform3D) -> Array:
	var radii: Array = []
	var result: Array = []
	for axis in range(3):
		var radius := 0.0
		for column in range(3): radius += absf(float(pose.basis[column][axis])) * 0.5
		radii.append(radius)
		result.append(float(pose.origin[axis]) - radius)
	for axis in range(3): result.append(float(pose.origin[axis]) + radii[axis])
	return result

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
