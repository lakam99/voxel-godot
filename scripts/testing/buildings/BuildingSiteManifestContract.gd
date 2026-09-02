extends RefCounted

## SYNTHETIC SOURCE CONTRACT + frozen real-source diagnostic, never gameplay
## acceptance. The caller owns launch, watchdog and report writing. No scenes,
## generation, physical resolution, publication or source changes are invoked.
const Builder := preload("res://scripts/buildings/BuildingSiteManifestBuilder.gd")
const Blueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan := preload("res://scripts/buildings/FurnishingPlan.gd")
const Part := preload("res://scripts/buildings/BuildingPart.gd")
const Furniture := preload("res://scripts/buildings/FurnishingPart.gd")
const REFERENCE := "res://artifacts/citadel-runtime-integration/source-reference-01/reference.bin"
const SHA := "f949a4bcacdaf0c5e5fec060979f16eac1012493fe3a30e1a62b2a5a172f8aa2"


static func run(reference_path: String = REFERENCE) -> Dictionary:
	var checks := {}
	# Validate the exact store_var envelope before any other contract work.
	var real := _reference(reference_path, checks)
	if not real.get("manifest", {}).get("ready", false):
		return {"complete": true, "passed": false, "evidenceLevel": "source_contract_reference_preflight", "checks": checks, "reference": real}
	var edge_bp := Blueprint.new("exact-edge", 1)
	edge_bp.add_part({"id": "base", "kind": "foundation", "position": Vector3(0, 0.5, 0), "size": Vector3(2, 1, 2)})
	var edge_result := Builder.build(edge_bp, Plan.new("edge-furniture", 1, edge_bp.id), 1.0)
	_check(checks, "synthetic.exact_boundary_sample", edge_result.ready and edge_result.footprintCells == Rect2i(-1, -1, 3, 3))
	var bp := Blueprint.new("synthetic-source", 41)
	var plan := Plan.new("synthetic-furniture", 42, bp.id)
	var root := bp.add_part({"id": "root", "kind": "foundation", "position": Vector3(0, 0.5, 0),
		"rotation": Vector3(0, 0.37, 0), "size": Vector3(4, 1, 2)})
	var visual := bp.add_part({"id": "visual", "kind": "beam", "collision": false,
		"position": Vector3(-8, 5, 3), "rotation": Vector3(0.41, -0.62, 0.23), "size": Vector3(2, 3, 4)})
	plan.parts.append(Furniture.new({"id": "root", "position": Vector3(13, 2, -3),
		"occupiedSize": Vector3(3, 4, 2), "rotation": Vector3(-0.2, 0.7, 0.3)}))
	plan.protected_access_reservations.append(AABB(Vector3.ZERO, Vector3.ONE))
	var tree := {"id": "tree", "position": Vector3(24, 0, 0), "canopyRadius": 3.0, "height": 9.0,
		"rootButtressFootprints": [{"start": Vector3(24, 0, 0), "end": Vector3(29, 0, 0), "radiusStart": 0.5, "radiusEnd": 0.2}]}
	bp.recipe = {"urbanPoc": {"treePlacements": [tree]}, "typed": 1}
	var before := _source_bytes(bp, plan)
	var result := Builder.build(bp, plan)
	_check(checks, "synthetic.ready", result.ready)
	if result.ready:
		_check(checks, "synthetic.input_unchanged", before == _source_bytes(bp, plan))
		_check(checks, "synthetic.deterministic", result == Builder.build(bp, plan))
		_check(checks, "synthetic.signature_is_source_not_grid", result.sourceSignature == Builder.build(bp, plan, 2.0).sourceSignature)
		_check(checks, "synthetic.all_parts_and_namespaces", result.parts.size() == 3 and result.supportRootIds == ["root"])
		_check(checks, "synthetic.ground_contract", result.groundY == 0.0 and result.localGroundY == 0.0 and not result.publicationReady)
		var basis := Basis.from_euler(visual.rotation)
		var half := (basis.x.abs() * visual.size.x + basis.y.abs() * visual.size.y + basis.z.abs() * visual.size.z) * 0.5
		_check(checks, "synthetic.arbitrary_basis_eight_corners", result.parts[1].corners.size() == 8 and result.parts[1].bounds.is_equal_approx(AABB(visual.position - half, half * 2)))
		var expected := Blueprint.new().part_transform(root) * Vector3(-2, -0.5, -1)
		_check(checks, "synthetic.actual_bottom_corners", result.groundRoots[0].corners.size() == 4 and result.groundRoots[0].corners[0].is_equal_approx(expected))
		_check(checks, "synthetic.world_local_buttress_no_double_pose", result.trees[0].bounds.end.x == 29.5 and result.trees[0].height == 9.0)
		var rect: Rect2i = result.footprintCells
		var bounds: AABB = result.localBounds
		_check(checks, "synthetic.conservative_cells", rect.position.x * 1.35 <= bounds.position.x and rect.position.y * 1.35 <= bounds.position.z and rect.end.x * 1.35 >= bounds.end.x and rect.end.y * 1.35 >= bounds.end.z)
		_check(checks, "synthetic.outer_interpolation_samples", rect.has_point(Vector2i(ceili(bounds.end.x / 1.35), ceili(bounds.end.z / 1.35))) and rect.end.x == ceili(bounds.end.x / 1.35) + 1 and rect.end.y == ceili(bounds.end.z / 1.35) + 1 and result.cellSize == 1.35)
		_check(checks, "synthetic.deep_readonly", result.is_read_only() and result.parts.is_read_only() and result.parts[0].is_read_only() and result.parts[0].corners.is_read_only() and result.groundRoots[0].corners.is_read_only() and result.trees[0].rootButtressFootprints[0].is_read_only() and result.accessReservations.is_read_only())
		bp.recipe.typed = 1.0
		_check(checks, "synthetic.typed_identity", Builder.build(bp, plan).sourceSignature != result.sourceSignature)
		bp.recipe.typed = 1
		bp.recipe = {"typed": 1, "urbanPoc": bp.recipe.urbanPoc}
		_check(checks, "synthetic.dictionary_order_stable", Builder.build(bp, plan).sourceSignature == result.sourceSignature)
		plan.protected_access_reservations[0] = AABB(Vector3.ONE, Vector3.ONE)
		_check(checks, "synthetic.reservations_hashed_and_detached", Builder.build(bp, plan).sourceSignature != result.sourceSignature and result.accessReservations[0].position == Vector3.ZERO)
		plan.protected_access_reservations[0] = AABB(Vector3.ZERO, Vector3.ONE)
		tree.height = 10.0
		_check(checks, "synthetic.tree_semantics_hashed", Builder.build(bp, plan).sourceSignature != result.sourceSignature and result.trees[0].height == 9.0)
		tree.erase("height")
		_check(checks, "synthetic.unknown_height_explicit", Builder.build(bp, plan).unknownHeightTreeIds == ["tree"])
		tree["treeRequest"] = {"visualHeight": 12.0}
		_check(checks, "synthetic.request_height", Builder.build(bp, plan).trees[0].height == 12.0)
		bp.recipe["cycle"] = bp.recipe
		_check(checks, "synthetic.cyclic_source_bounded", Builder.build(bp, plan).reason == "source_value_limit_exceeded")
		bp.recipe.erase("cycle")
	for invalid in [0.0, -1.0, NAN, INF, 1e-300]:
		_check(checks, "synthetic.invalid_cell_size", not Builder.build(bp, plan, invalid).ready)
	_check(checks, "synthetic.invalid_source", not Builder.build({}, plan).ready)
	bp.parts.append(null)
	_check(checks, "synthetic.null_part_not_skipped", not Builder.build(bp, plan).ready)
	bp.parts.pop_back()
	bp.parts.append(root)
	_check(checks, "synthetic.duplicate_id", not Builder.build(bp, plan).ready)
	bp.parts.pop_back()
	root.position.y = 0.561
	_check(checks, "synthetic.missing_roots", Builder.build(bp, plan).reason == "missing_grounded_roots")
	root.position.y = 0.559
	_check(checks, "synthetic.inherited_ground_tolerance", Builder.build(bp, plan).ready)
	root.position.y = 0.5
	visual.size.x = -1.0
	_check(checks, "synthetic.invalid_size", not Builder.build(bp, plan).ready)
	visual.size.x = 2.0
	visual.rotation.x = NAN
	_check(checks, "synthetic.nonfinite_rotation", not Builder.build(bp, plan).ready)
	visual.rotation.x = 0.41
	var placements: Array = bp.recipe.urbanPoc.treePlacements
	placements.append(Vector3.ZERO)
	_check(checks, "synthetic.unknown_tree_not_skipped", not Builder.build(bp, plan).ready)
	placements.pop_back()
	placements.append(tree)
	_check(checks, "synthetic.duplicate_tree", not Builder.build(bp, plan).ready)
	placements.pop_back()
	tree.rootButtressFootprints.append({})
	_check(checks, "synthetic.malformed_buttress", not Builder.build(bp, plan).ready)
	tree.rootButtressFootprints.pop_back()
	bp.parts.resize(Builder.MAX_PARTS + 1)
	_check(checks, "synthetic.bounded_admission", Builder.build(bp, plan).reason == "part_limit_exceeded")
	return {"schema": "building-site-manifest-contract/v1", "evidenceLevel": "synthetic_source_contract_and_real_snapshot_diagnostic",
		"complete": true, "passed": not checks.values().has(false), "checks": checks, "reference": real,
		"doesNotProve": "No terrain support, profile, origin/apron choice, publisher mesh parity, collision, navigation, runtime budget, or live gameplay acceptance."}


static func _reference(path: String, checks: Dictionary) -> Dictionary:
	if not _check(checks, "reference.sha256", FileAccess.get_sha256(path) == SHA):
		return {"ready": false, "reason": "reference_hash_mismatch"}
	var file := FileAccess.open(path, FileAccess.READ)
	if not _check(checks, "reference.readable_bounded", file != null and file.get_length() <= 16777216):
		return {"ready": false, "reason": "reference_unreadable"}
	var artifact: Variant = file.get_var(false)
	var read_ok := file.get_error() == OK
	file.close()
	if not _check(checks, "reference.envelope", read_ok and artifact is Dictionary and artifact.get("identity") is Dictionary and artifact.get("handoff") is Dictionary):
		return {"ready": false, "reason": "invalid_reference"}
	var b: Dictionary = artifact.handoff.blueprint
	var f: Dictionary = artifact.handoff.furnishingPlan
	# Diagnostic reconstruction only: no production restore API exists. Use normal
	# part classes without add_part access filtering, then prove exact snapshots.
	var bp := Blueprint.new(b.id, b.seed, b.style)
	bp.recipe = b.recipe.duplicate(true)
	bp.rooms = b.rooms.duplicate(true)
	for snapshot: Dictionary in b.parts:
		var part := Part.new(snapshot)
		part.physical_intent = snapshot.physicalIntent
		bp.parts.append(part)
	var plan := Plan.new(f.id, f.seed, f.sourceBlueprintId)
	plan.egress_diagnostics = f.egressDiagnostics.duplicate(true)
	plan.protected_access_reservations.assign(f.accessReservations)
	for snapshot: Dictionary in f.parts:
		plan.parts.append(Furniture.new(snapshot))
	var fs := plan.snapshot()
	fs["accessReservations"] = plan.access_reservations_snapshot()
	if not _check(checks, "reference.reconstruction_exact", var_to_bytes(bp.snapshot()) == var_to_bytes(b) and var_to_bytes(fs) == var_to_bytes(f)):
		return {"ready": false, "reason": "reconstruction_changed_source"}
	var before := _source_bytes(bp, plan)
	var started := Time.get_ticks_usec()
	var result := Builder.build(bp, plan)
	var elapsed := Time.get_ticks_usec() - started
	_check(checks, "reference.manifest_ready", result.ready)
	_check(checks, "reference.input_unchanged", before == _source_bytes(bp, plan))
	if result.ready:
		_check(checks, "reference.all_parts", result.parts.size() == b.parts.size() + f.parts.size())
		_check(checks, "reference.all_trees", result.trees.size() == b.recipe.get("urbanPoc", {}).get("treePlacements", []).size())
		_check(checks, "reference.root_authority", result.groundRoots.size() == bp.parts.filter(func(part): return bp.is_grounded_structural_root(part)).size())
	return {"sha256": SHA, "identity": artifact.identity, "elapsedUsec": elapsed, "manifest": result}


static func _source_bytes(bp, plan) -> PackedByteArray:
	return var_to_bytes([bp.snapshot(), plan.snapshot(), plan.access_reservations_snapshot()])


static func _check(checks: Dictionary, label: String, condition: bool) -> bool:
	checks[label] = bool(checks.get(label, true)) and condition
	return condition
