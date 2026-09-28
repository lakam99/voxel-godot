extends "res://scripts/testing/buildings/CitadelOpeningHeadPublishedContract.gd"

## Source collision + actual CPU render-envelope clearance, not GPU acceptance.
const ClearancePlan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const DoorGeometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const BandRecipe = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const CANDIDATE_PATH := "res://artifacts/citadel-visual-reset/opening-head-wired-batch-02/candidate.bin"
const CANDIDATE_SHA := "4c4427653fbd8245fe11467ec03702ba116a77f1da803d8f96ba9a6684f4936b"
const ORIGINAL_PATH := "res://artifacts/citadel-visual-reset/facade-aperture-manifest-02/source.bin"
const ORIGINAL_SHA := "e83098a950b7ad66d82eeff838f51cb912873f32bd3e8755931af52955a54219"
const MAX_CLEARANCE_ROWS := 4096
var _clearance_hits: Array = []
var _intended_contacts: Dictionary = {}
var _support_valid: Dictionary = {}
var _clearance_checks: Dictionary = {}
var _prior_header_panels: Dictionary = {}
var _support_blueprint
var _clearance_counts: Dictionary = {"sourceParts": 0, "visualParts": 0, "furnishings": 0, "doors": 0, "comparisons": 0, "renderPrimitives": 0}

class DoorCapture:
	extends "res://scripts/buildings/BuildingPartPublisher.gd"
	var captured_boxes: Dictionary = {}
	func add_box_batch(parent: Node3D, transforms: Array, material: Material, node_name: String, custom_data_override: Array = []) -> MultiMeshInstance3D:
		var node: MultiMeshInstance3D = super.add_box_batch(parent, transforms, material, node_name, custom_data_override)
		if node != null: captured_boxes[node.get_instance_id()] = transforms.duplicate()
		return node

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path: String = OS.get_environment("VOXEL_OPENING_HEAD_CLEARANCE_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var candidate_path: String = OS.get_environment("VOXEL_OPENING_HEAD_CLEARANCE_INPUT")
	var candidate_sha: String = OS.get_environment("VOXEL_OPENING_HEAD_CLEARANCE_INPUT_SHA256").to_lower()
	if candidate_path.is_empty() and candidate_sha.is_empty():
		candidate_path = CANDIDATE_PATH
		candidate_sha = CANDIDATE_SHA
	elif not candidate_path.is_absolute_path() or candidate_sha.length() != 64 or candidate_sha.hex_decode().size() != 32:
		quit(2)
		return
	var report: Dictionary = {"passed": false, "evidenceLevel": "whole_candidate_source_collision_and_CPU_render_envelope_clearance",
		"candidatePath": candidate_path, "candidateSha256": candidate_sha, "originalPath": ORIGINAL_PATH, "originalSha256": ORIGINAL_SHA,
		"limitations": "Source boxes certify only source collision geometry. CPU publication bounds include actual mesh-resource envelopes, not shader displacement/GPU geometry. Positive envelope intersections remain blocked/unresolved, never accepted as clear. Swing uses a conservative full-rotation envelope (covers the entire commanded arc, may overreject); raises use the continuous translation envelope. No physics movement, navigation, live door interaction, assembled scene, engineering capacity or gameplay acceptance."}
	var candidate: Dictionary = _clearance_read(candidate_path, candidate_sha)
	var original: Dictionary = _clearance_read(ORIGINAL_PATH, ORIGINAL_SHA)
	var plan_source: Dictionary = ClearancePlan.read_input("candidate")
	if candidate.is_empty() or original.is_empty() or plan_source.is_empty():
		_finish_clearance(path, report, "invalid_bound_inputs")
		return
	var source_check: Dictionary = original.afterSnapshot.duplicate(true)
	source_check.recipe.erase("facadeApertures")
	_clearance_checks["original_matches_existing_plan_reader"] = ClearancePlan.digest(source_check) == ClearancePlan.digest(plan_source.afterSnapshot)
	_clearance_checks["candidate_before_and_furniture_exact"] = ClearancePlan.digest(candidate.beforeSnapshot) == ClearancePlan.digest(original.afterSnapshot) and ClearancePlan.digest(candidate.furnitureSnapshot) == ClearancePlan.digest(original.furnitureSnapshot) and ClearancePlan.digest(candidate.protectedReservations) == ClearancePlan.digest(original.protectedReservations)
	var b = HeadCopy.copy_blueprint(candidate.afterSnapshot)
	var before = HeadCopy.copy_blueprint(original.afterSnapshot)
	var frozen: String = ClearancePlan.digest([candidate, original, b.snapshot()])
	var headers: Array = []
	var houses: Dictionary = HeadCopy.street_house_memberships(before)
	var actual_houses: Array = []
	if not candidate.get("houseProposals") is Array or candidate.houseProposals.size() != 16 or not houses.ready:
		_finish_clearance(path, report, "invalid_header_membership")
		return
	for proposal: Dictionary in candidate.houseProposals:
		var header = b.find_part(String(proposal.get("headerId", "")))
		if header == null or headers.has(header) or before.find_part(header.id) != null or header.rotation != Vector3.ZERO or header.recipe.get("preserveBearingFaces") != true or not b.has_finite_positive_bounds(header):
			_finish_clearance(path, report, "invalid_header_geometry")
			return
		headers.append(header)
		actual_houses.append(proposal.house)
		var connection_ids: Variant = proposal.get("connectionIds", [])
		if not connection_ids is Array or connection_ids.size() > 2:
			_finish_clearance(path, report, "invalid_connection_membership")
			return
		for id: Variant in connection_ids:
			if not id is String:
				_finish_clearance(path, report, "invalid_connection_id")
				return
			var connection = b.find_part(id)
			if connection == null or headers.has(connection) or before.find_part(id) != null or connection.kind != "beam" or connection.semantic != "citadel_opening_head_connection" or not connection.id.begins_with(header.id + "_connection_") or connection.rotation != Vector3.ZERO or not connection.collision_enabled or connection.recipe.get("preserveBearingFaces") != true or not b.has_finite_positive_bounds(connection):
				_finish_clearance(path, report, "invalid_connection_geometry")
				return
			headers.append(connection)
		_prior_header_panels[header.id] = []
		for id: String in proposal.trimmedPanelIds:
			var old_panel = before.find_part(id)
			if old_panel == null or not _axis_aligned(before.part_transform(old_panel)):
				_finish_clearance(path, report, "invalid_prior_panel_geometry")
				return
			_prior_header_panels[header.id].append({"bounds": _source_box_bounds(before.part_transform(old_panel), old_panel.size), "id": id})
	_clearance_checks["all16_source_houses"] = actual_houses == houses.houses.map(func(h): return h.prefix)
	var added_ids: Array = b.parts.filter(func(p): return before.find_part(p.id) == null).map(func(p): return p.id)
	_clearance_checks["every_added_framing_piece_examined"] = headers.size() == added_ids.size() and headers.all(func(h): return added_ids.has(h.id))
	_clearance_checks["all152_furnishings"] = candidate.furnitureSnapshot.parts.size() == 152
	_clearance_checks["synthetic_blocked_controls"] = _clearance_controls()
	# Normal publication resolves physical contracts. Run that same authority
	# on a private proof copy, leaving measured source and render inputs exact.
	_support_blueprint = HeadCopy.copy_blueprint(b.snapshot())
	var physical: Dictionary = _support_blueprint.validate_physical_integrity()
	report["privateSupportValidationFailureCount"] = physical.violations.size()
	var publisher = _configured_publisher(b)
	if not publisher._prepare_paving_publication(b) or not publisher.prepare_masonry_apertures(b):
		_finish_clearance(path, report, "publication_preparation_rejected")
		return
	while publisher._masonry_preparation.state == "pending_budget" and _within_budget():
		publisher._masonry_preparation.advance(publisher)
		await process_frame
	if publisher._masonry_preparation.state != "ready":
		_finish_clearance(path, report, "masonry_preparation_failed")
		return
	var executed: Array = []
	for part in b.parts:
		if not _within_budget(): break
		if not b.has_finite_positive_bounds(part):
			_stop_reason = "invalid_neighbour_geometry"
			break
		_clearance_counts.sourceParts += 1
		if part.collision_enabled:
			_compare_clearance(b, headers, part, [{"bounds": _source_box_bounds(b.part_transform(part), part.size), "name": "authoritative_part_box"}], "source_collision")
		if bool(part.recipe.get("visual", true)):
			var rows: Array = _render_envelopes(publisher, b, part)
			_compare_clearance(b, headers, part, rows, "CPU_neighbour_render_envelope")
			_clearance_counts.visualParts += 1
		if part.kind == "door":
			var swept: Dictionary = _door_sweep(part)
			if not swept.ready: _stop_reason = "unsupported_door_sweep:" + part.id
			else: _compare_clearance(b, headers, part, swept.rows, "continuous_door_sweep_envelope", false)
			_clearance_counts.doors += 1
		executed.append(part.id)
		if executed.size() % 32 == 0: await process_frame
	var furnisher = Furnisher.new()
	for record: Dictionary in candidate.furnitureSnapshot.parts:
		if not _within_budget(): break
		var part = FurnishingPlanScript.FurnishingPartScript.new(record)
		if var_to_bytes(part.snapshot()) != var_to_bytes(record):
			_stop_reason = "furniture_copy_not_exact"
			break
		var parent: Node3D = Node3D.new()
		furnisher.publish_part(part, parent)
		var rows: Array = _node_envelopes(parent, Transform3D.IDENTITY, null)
		if rows.is_empty(): _stop_reason = "missing_furnishing_geometry:" + part.id
		_compare_clearance(b, headers, part, rows, "CPU_furnishing_visual_and_collision", false)
		parent.free()
		furnisher.published_parts.clear()
		_clearance_counts.furnishings += 1
		if _clearance_counts.furnishings % 16 == 0: await process_frame
	_clearance_checks["all_source_order_executed"] = executed == b.parts.map(func(p): return p.id)
	_clearance_checks["all_furniture_examined"] = _clearance_counts.furnishings == 152
	_clearance_checks["all_doors_examined"] = _clearance_counts.doors == b.parts.filter(func(p): return p.kind == "door").size()
	_clearance_checks["inputs_immutable"] = frozen == ClearancePlan.digest([candidate, original, b.snapshot()]) and FileAccess.get_sha256(candidate_path) == candidate_sha and FileAccess.get_sha256(ORIGINAL_PATH) == ORIGINAL_SHA
	report["executedSourceOrderDigest"] = ClearancePlan.digest(executed)
	report["headerIds"] = headers.map(func(h): return h.id)
	_finish_clearance(path, report, "measurement_complete")

func _clearance_read(path: String, sha: String) -> Dictionary:
	# Same raw, round-trip-exact envelope checks as the existing Plan reader.
	if FileAccess.get_sha256(path) != sha: return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var length: int = file.get_length()
	if length < 1 or length > ClearancePlan.MAX_INPUT:
		file.close()
		return {}
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	var value: Variant = bytes_to_var(bytes) if complete else null
	if not value is Dictionary or var_to_bytes(value) != bytes or FileAccess.get_sha256(path) != sha: return {}
	return value

func _render_envelopes(publisher, b, part) -> Array:
	var parent: Node3D = Node3D.new()
	publisher.static_visual_collecting = true
	publisher.static_visual_part_transform = b.part_transform(part)
	publisher.static_visual_batches.clear()
	publisher.captured_mesh_batches.clear()
	publisher.static_visual_transform_count = 0
	publisher.publish_visual(part, parent)
	var rows: Array = []
	for group: Dictionary in publisher.static_visual_batches.values():
		for pose: Transform3D in group.transforms: rows.append({"bounds": _source_box_bounds(pose, Vector3.ONE), "name": "actual_box"})
	rows.append_array(_node_envelopes(parent, Transform3D.IDENTITY, publisher))
	parent.free()
	publisher.published_nodes.clear()
	publisher.captured_mesh_batches.clear()
	publisher.static_visual_batches.clear()
	if publisher._publication_failed() or rows.is_empty(): _stop_reason = "incomplete_neighbour_publication:" + part.id
	_clearance_counts.renderPrimitives += rows.size()
	return rows

func _node_envelopes(parent: Node, frame: Transform3D, capture, depth: int = 0) -> Array:
	var rows: Array = []
	if depth > 32:
		_stop_reason = "geometry_depth_limit"
		return rows
	for child in parent.get_children():
		if child is Area3D: continue # Interaction volumes are not blocking collision.
		var pose: Transform3D = frame * child.transform if child is Node3D else frame
		if child is MeshInstance3D:
			if child.mesh == null: _stop_reason = "missing_actual_mesh"
			else: rows.append({"bounds": _source_box_bounds(pose, child.mesh.size) if child.mesh is BoxMesh else _payload_intervals(pose, child.mesh.get_aabb()), "name": String(child.name)})
		elif child is CollisionShape3D and not child.disabled:
			if child.shape is BoxShape3D: rows.append({"bounds": _source_box_bounds(pose, child.shape.size), "name": "actual_collision_box"})
			else: _stop_reason = "unsupported_collision_shape"
		elif child is MultiMeshInstance3D:
			var data: Dictionary = capture.captured_mesh_batches.get(child.get_instance_id(), {}) if capture is CpuMeshBatchPublisher else {}
			var transforms: Array = []
			var mesh: Mesh = child.multimesh.mesh if child.multimesh != null else null
			if capture is DoorCapture: transforms = capture.captured_boxes.get(child.get_instance_id(), [])
			elif not data.is_empty(): transforms = data.transforms
			if mesh == null or transforms.is_empty(): _stop_reason = "uncaptured_multimesh_geometry"
			else:
				for local: Transform3D in transforms:
					var world: Transform3D = pose * (data.partTransform * local if data.get("collecting", false) else local)
					rows.append({"bounds": _source_box_bounds(world, mesh.size) if mesh is BoxMesh else _payload_intervals(world, mesh.get_aabb()), "name": String(child.name)})
		rows.append_array(_node_envelopes(child, pose, capture, depth + 1))
	return rows

func _source_box_bounds(pose: Transform3D, size: Vector3) -> Array:
	return _head_local_bounds(pose, Vector3.ZERO, size * 0.5) if _axis_aligned(pose) else _payload_intervals(pose, AABB(-size * 0.5, size))

func _compare_clearance(b, headers: Array, part, rows: Array, channel: String, supports: bool = true) -> void:
	# Union exact represented endpoints, without narrowing through float32 AABB
	# construction. A disjoint whole-part envelope rejects all enclosed primitives.
	var envelope: Array = []
	for row: Dictionary in rows:
		if not _valid_intervals(row.bounds):
			_stop_reason = "invalid_clearance_bounds"
			return
		if envelope.is_empty(): envelope = row.bounds.duplicate()
		else:
			for axis in range(3):
				envelope[axis] = minf(envelope[axis], row.bounds[axis])
				envelope[axis + 3] = maxf(envelope[axis + 3], row.bounds[axis + 3])
	if envelope.is_empty(): return
	for header in headers:
		if supports and header == part: continue
		var target: Array = _source_box_bounds(b.part_transform(header), header.size)
		if not _valid_intervals(target):
			_stop_reason = "invalid_header_bounds"
			return
		if not _head_intersects(target, envelope): continue
		for row: Dictionary in rows:
			_clearance_counts.comparisons += 1
			if _clearance_counts.comparisons > MAX_PRIMITIVE_TESTS:
				_stop_reason = "clearance_comparison_limit"
				return
			if not _valid_intervals(row.bounds):
				_stop_reason = "invalid_clearance_bounds"
				return
			if not _head_intersects(target, row.bounds): continue # Exact face touching is not penetration.
			var key: String = header.id + "->" + part.id
			if supports and _is_declared_support_contact(b, header, part):
				var proof: Dictionary = _support_valid[key]
				var overlap: Array = _overlap_bounds(target, row.bounds)
				if _contains_intervals(proof.allowedSourceOverlap, overlap):
					if not _intended_contacts.has(key): _intended_contacts[key] = {"headerId": header.id, "partId": part.id, "finiteSeatProof": proof, "actualOverlaps": []}
					_intended_contacts[key].actualOverlaps.append({"channel": channel, "primitive": row.name, "bounds": overlap})
					continue
			if _clearance_hits.size() >= MAX_CLEARANCE_ROWS:
				_stop_reason = "clearance_report_limit"
				return
			var prior: Dictionary = _head_cover(_overlap_bounds(target, row.bounds), _prior_header_panels.get(header.id, [])) if _prior_header_panels.has(header.id) else {}
			_clearance_hits.append({"headerId": header.id, "obstacleId": part.id, "channel": channel, "primitive": row.name, "headerBounds": target, "obstacleBounds": row.bounds,
				"priorTrimmedPanelSourceCoverage": prior, "priorCoverageScope": "Diagnostic only: original source boxes, not old rendered geometry. Does not waive the intersection.",
				"classification": "blocked_or_conservative_envelope_unresolved"})

func _is_declared_support_contact(b, header, part) -> bool:
	var key: String = header.id + "->" + part.id
	if _support_valid.has(key): return _support_valid[key].valid
	var evidence: Dictionary = {"valid": false, "evidenceLevel": "shared_source_finite_seat_geometry_not_published_capacity"}
	if _support_blueprint != null:
		var checked_header = _support_blueprint.find_part(header.id)
		var checked_part = _support_blueprint.find_part(part.id)
		if checked_header == null or checked_part == null or HeadDeclaration._geometry(checked_header) != HeadDeclaration._geometry(header) or HeadDeclaration._geometry(checked_part) != HeadDeclaration._geometry(part): return false
		b = _support_blueprint
		header = checked_header
		part = checked_part
	for pair: Array in [[header, part], [part, header]]:
		var facts: Variant = pair[0].recipe.get("physicalRequiredSeatFacts", [])
		var ids: Variant = pair[0].recipe.get("physicalRequiredSeatPartIds", [])
		if not facts is Array or not ids is Array: continue
		for fact: Variant in facts:
			if not fact is Dictionary or fact.get("seatId") != pair[1].id or not ids.has(pair[1].id): continue
			if not _axis_aligned(b.part_transform(header)) or not _axis_aligned(b.part_transform(part)) or not b.has_rooted_bearer_seat(pair[0], fact): continue
			var overlap: Array = _overlap_bounds(_source_box_bounds(b.part_transform(header), header.size), _source_box_bounds(b.part_transform(part), part.size))
			if not _valid_intervals(overlap): continue
			var proof: Dictionary = b.housed_overlap_diagnostics(pair[0], pair[1], fact) if fact.get("contactMode") == "housed_overlap" else b.gravity_bearing_diagnostics(pair[0], pair[1], fact)
			evidence.merge({"valid": true, "bearerId": pair[0].id, "seatId": pair[1].id, "fact": fact.duplicate(true), "geometry": proof, "allowedSourceOverlap": overlap}, true)
	_support_valid[key] = evidence
	return evidence.valid

func _overlap_bounds(a: Array, c: Array) -> Array:
	if not _valid_intervals(a) or not _valid_intervals(c): return []
	return [maxf(a[0], c[0]), maxf(a[1], c[1]), maxf(a[2], c[2]), minf(a[3], c[3]), minf(a[4], c[4]), minf(a[5], c[5])]

func _door_sweep(part) -> Dictionary:
	# Query actual publisher metadata and actual leaf nodes, not copied dimensions.
	var publisher = DoorCapture.new()
	var parent: Node3D = Node3D.new()
	root.add_child(parent)
	var body: StaticBody3D = publisher.publish_part(part, parent)
	if body == null:
		parent.free()
		return {"ready": false}
	var pivot: Node3D = body.get_node_or_null("DoorPivot")
	var rows: Array = _node_envelopes(body, body.transform, publisher)
	var valid: bool = pivot != null and _stop_reason.is_empty()
	if valid:
		var leaf: Array = _node_envelopes(pivot, Transform3D.IDENTITY, publisher)
		var motion: String = String(body.get_meta("door_motion", ""))
		if leaf.is_empty() or motion not in ["swing", "raise"]: valid = false
		var pivot_world: Transform3D = body.transform * pivot.transform
		for row: Dictionary in leaf:
			var bounds: Array = row.bounds
			if not _valid_intervals(bounds):
				valid = false
				continue
			var enclosing: AABB = _outward_sweep_box(bounds)
			var low: Vector3 = enclosing.position
			var high: Vector3 = enclosing.end
			if motion == "swing":
				var angle: float = float(body.get_meta("open_swing", NAN))
				if not is_finite(angle): valid = false
				# L1 radius bounds every XZ rotation, including all intermediate angles.
				var radius: float = BandRecipe._next_float32_up(maxf(absf(low.x), absf(high.x)) + maxf(absf(low.z), absf(high.z)))
				low.x = -radius
				low.z = -radius
				high.x = radius
				high.z = radius
			else:
				var offset: Variant = body.get_meta("open_visual_offset")
				if not offset is Vector3 or not offset.is_finite():
					valid = false
					continue
				low = low.min(low + offset)
				high = high.max(high + offset)
			rows.append({"bounds": _payload_intervals(pivot_world, AABB(low, high - low)), "name": "continuous_" + motion + ":" + row.name})
	if String(part.recipe.get("doorPresentation", "door")) == "door":
		valid = valid and pivot != null and pivot.position == DoorGeometry.describe(part.size).pivotPosition
	parent.free()
	publisher.published_nodes.clear()
	return {"ready": valid, "rows": rows}

func _outward_sweep_box(bounds: Array) -> AABB:
	# Directed representation rounding of a conservative envelope, never a
	# clearance tolerance or a moved source/door. Preserve both declared limits.
	var low: Vector3 = Vector3(bounds[0], bounds[1], bounds[2])
	var high: Vector3 = Vector3(bounds[3], bounds[4], bounds[5])
	for axis: int in range(3):
		if float(low[axis]) > bounds[axis]: low[axis] = -BandRecipe._next_float32_up(-float(low[axis]))
		if float(high[axis]) < bounds[axis + 3]: high[axis] = BandRecipe._next_float32_up(float(high[axis]))
	var result: AABB = AABB(low, high - low)
	for axis: int in range(3):
		if float(result.position[axis]) + float(result.size[axis]) < bounds[axis + 3] or result.end[axis] < high[axis]: result.size[axis] = BandRecipe._next_float32_up(float(result.size[axis]))
	return result

func _clearance_controls() -> bool:
	var b = Blueprint.new("synthetic_clearance_controls", 0, "timber")
	var header = b.add_part({"id": "synthetic_header", "kind": "beam", "position": Vector3.ZERO, "size": Vector3.ONE})
	var neighbour = b.add_part({"id": "synthetic_unrelated_neighbour", "kind": "wall", "position": Vector3.ZERO, "size": Vector3.ONE})
	var row: Array = [{"bounds": [-0.25, -0.25, -0.25, 0.25, 0.25, 0.25], "name": "synthetic_blocker"}]
	var start: int = _clearance_hits.size()
	_compare_clearance(b, [header], neighbour, row, "synthetic_blocked_neighbour")
	var furnishing = FurnishingPlanScript.FurnishingPartScript.new({"id": "synthetic_blocked_furnishing", "archetype": "chair", "position": Vector3(0, -0.1, 0), "occupiedSize": Vector3.ONE * 0.2})
	var furnisher = Furnisher.new()
	var parent: Node3D = Node3D.new()
	furnisher.publish_part(furnishing, parent)
	_compare_clearance(b, [header], furnishing, _node_envelopes(parent, Transform3D.IDENTITY, null), "synthetic_blocked_furnishing", false)
	parent.free()
	furnisher.published_parts.clear()
	var door = b.add_part({"id": "synthetic_blocked_door", "kind": "door", "position": Vector3.ZERO, "size": Vector3(0.5, 0.5, 0.1)})
	var sweep: Dictionary = _door_sweep(door)
	if sweep.ready: _compare_clearance(b, [header], door, sweep.rows, "synthetic_blocked_swept_door", false)
	var channels: Array = _clearance_hits.slice(start).map(func(hit): return hit.channel)
	var passed: bool = channels.has("synthetic_blocked_neighbour") and channels.has("synthetic_blocked_furnishing") and channels.has("synthetic_blocked_swept_door") and not _is_declared_support_contact(b, header, neighbour)
	_clearance_hits.resize(start)
	var seat = b.add_part({"id": "synthetic_rooted_seat", "kind": "wall", "size": Vector3.ONE,
		"recipe": {"physicalIntent": "structural_root", "physicalRoot": true}})
	var supported = b.add_part({"id": "synthetic_supported_header", "kind": "beam", "size": Vector3.ONE, "position": Vector3(0, 0.999, 0),
		"recipe": {"physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": [seat.id],
		"physicalRequiredSeatFacts": [{"seatId": seat.id, "loadDirection": "world_down", "seatFace": "max_y", "localPatchCenter": Vector3(0, -0.5, 0), "localPatchHalfExtents": Vector2(0.1, 0.1)}]}})
	# This synthetic blueprint was made through add_part, not the normal copy
	# or resolve path that builds the lookup consumed by the seat validator.
	for source in b.parts: b.physical_parts_by_id[source.id] = source
	var positive := _is_declared_support_contact(b, supported, seat)
	var missing = b.add_part({"id": "synthetic_unreachable_seat", "kind": "wall", "position": Vector3(4, 0, 0), "size": Vector3.ONE,
		"recipe": {"physicalIntent": "structural_root", "physicalRoot": true}})
	supported.recipe.physicalRequiredSeatPartIds = [missing.id]
	supported.recipe.physicalRequiredSeatFacts[0].seatId = missing.id
	b.physical_parts_by_id[missing.id] = missing
	var forged := _is_declared_support_contact(b, supported, missing)
	return passed and positive and not forged

func _finish_clearance(path: String, report: Dictionary, status: String) -> void:
	_clearance_checks["complete_bounded_geometry_coverage"] = status == "measurement_complete" and _within_budget()
	_clearance_checks["no_unallowed_or_unresolved_intersection"] = _clearance_hits.is_empty()
	var passed: bool = _clearance_checks.values().all(func(value): return value == true)
	report.merge({"passed": passed, "status": status, "stopReason": _stop_reason, "checks": _clearance_checks, "counts": _clearance_counts,
		"blockedOrUnresolved": _clearance_hits, "intendedSupportContacts": _intended_contacts.values(), "elapsedMsec": Time.get_ticks_msec() - _started_msec, "publishedGPUAcceptance": false}, true)
	var bytes: PackedByteArray = JSON.stringify(_overlap_json(report), "  ").to_utf8_buffer()
	if bytes.size() > 32 * 1024 * 1024 or FileAccess.file_exists(path):
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
	quit(0 if passed and written else 2)
