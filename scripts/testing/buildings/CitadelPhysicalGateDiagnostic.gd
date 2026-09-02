extends SceneTree

# Source-level structural diagnostic, never rendered/gameplay acceptance.
const CastleBuilder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const UrbanComposer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const FurniturePlanner = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var started := Time.get_ticks_msec()
	print("physical diagnostic: build seed208159 scale1.25")
	var blueprint = CastleBuilder.build(208159, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	blueprint = UrbanComposer.compose(blueprint, 208159)
	if blueprint == null:
		push_error("Citadel composition failed")
		quit(2)
		return
	print("physical diagnostic: validate")
	var report: Dictionary = blueprint.validate_physical_integrity()
	report["evidenceLevel"] = "source_structural_contract_only"
	report["seed"] = 208159
	report["scale"] = 1.25
	var selected: Array = []
	var selected_contacts: Dictionary = {}
	var failure_counts: Dictionary = {}
	for check in report["checks"]:
		if not check["passed"]:
			failure_counts[check["intent"]] = int(failure_counts.get(check["intent"], 0)) + 1
		if String(check["partId"]).begins_with("urban_row_00_left") or String(check["partId"]).begins_with("urban_bunting_rope"):
			var part = blueprint.find_part(check["partId"])
			selected.append(part.snapshot())
			if not check["passed"]:
				var contacts: Array = []
				for candidate in blueprint.structural_candidates_overlapping_part(part, 0.05):
					if candidate != part and blueprint.transformed_parts_overlap(part, candidate, 0.05):
						contacts.append({"id": candidate.id, "rooted": blueprint.has_rooted_support_chain(candidate, {})})
				selected_contacts[part.id] = contacts
	report["selectedParts"] = selected
	report["selectedGeometricContactsNotLoadProof"] = selected_contacts
	report["failureCounts"] = failure_counts
	report["contactContract"] = _contact_contract()
	# Hash concrete visible/collision fields, not evolving support inference records.
	var shape_records: Array = []
	for part in blueprint.parts:
		shape_records.append([part.id, part.kind, part.material_id, part.position, part.rotation, part.size, part.collision_enabled, part.semantic])
	report["shapeDigest"] = _digest(shape_records)
	var furniture = FurniturePlanner.build(blueprint, 208159 * 7919 + 37)
	report["furnitureDigest"] = _digest(furniture.snapshot())
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	var path := OS.get_environment("VOXEL_PHYSICAL_DIAGNOSTIC_REPORT")
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		push_error("Cannot write physical diagnostic report")
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("physical diagnostic: passed=", report["passed"], " failures=", failure_counts, " elapsedMsec=", report["elapsedMsec"])
	quit(0 if report["passed"] and report["contactContract"]["passed"] else 1)

func _contact_contract() -> Dictionary:
	var b = Blueprint.new()
	var horizontal = b.add_part({"id": "horizontal", "size": Vector3(4, 0.2, 0.2)})
	var vertical = b.add_part({"id": "vertical", "size": Vector3(0.2, 4, 0.2)})
	var checks: Dictionary = {}
	checks["cross_without_contained_corner"] = not b.transformed_part_corner_within(horizontal, vertical, 0.0) and not b.transformed_part_corner_within(vertical, horizontal, 0.0) and b.transformed_parts_overlap(horizontal, vertical, 0.0)
	checks["symmetric_cross"] = b.transformed_parts_overlap(vertical, horizontal, 0.0)
	vertical.position.z = 0.249
	checks["inside_existing_margin"] = b.transformed_parts_overlap(horizontal, vertical, 0.05)
	vertical.position.z = 0.251
	checks["outside_existing_margin"] = not b.transformed_parts_overlap(horizontal, vertical, 0.05)
	horizontal.rotation.z = PI * 0.25
	vertical.size = horizontal.size
	vertical.rotation = horizontal.rotation
	vertical.position = Vector3(-0.5, 0.5, 0.0)
	checks["overlapping_aabbs_separated_obbs"] = b.transformed_part_bounds(horizontal).intersects(b.transformed_part_bounds(vertical)) and not b.transformed_parts_overlap(horizontal, vertical, 0.05)
	vertical.position = Vector3.ZERO
	checks["invalid_margin_rejected"] = not b.transformed_parts_overlap(horizontal, vertical, NAN) and not b.transformed_parts_overlap(horizontal, vertical, INF) and not b.transformed_parts_overlap(horizontal, vertical, -0.05)
	vertical.position.x = NAN
	checks["nan_position_rejected"] = not b.transformed_parts_overlap(horizontal, vertical, 0.05) and not b.transformed_parts_overlap(vertical, horizontal, 0.05)
	vertical.position = Vector3.ZERO
	vertical.rotation.x = INF
	checks["infinite_rotation_rejected"] = not b.transformed_parts_overlap(horizontal, vertical, 0.05)
	vertical.rotation = Vector3.ZERO
	vertical.size.x = NAN
	checks["nan_size_rejected"] = not b.transformed_parts_overlap(horizontal, vertical, 0.05)
	vertical.size.x = 0.0
	checks["zero_size_rejected"] = not b.transformed_parts_overlap(horizontal, vertical, 0.05)
	vertical.size.x = -1.0
	checks["negative_size_rejected"] = not b.transformed_parts_overlap(horizontal, vertical, 0.05)
	var long_blueprint = Blueprint.new()
	long_blueprint.add_part({"id": "left", "kind": "foundation", "size": Vector3.ONE, "position": Vector3(-19.9, 0.5, 0.0)})
	long_blueprint.add_part({"id": "right", "kind": "foundation", "size": Vector3.ONE, "position": Vector3(19.9, 0.5, 0.0)})
	var beam = long_blueprint.add_part({"id": "long_attachment", "kind": "beam", "collision": false, "size": Vector3(40, 0.1, 0.1), "position": Vector3(0, 0.5, 0)})
	long_blueprint.resolve_physical_contracts()
	var anchors: Array = beam.recipe.get("physicalAnchorPartIds", [])
	checks["long_attachment_both_endpoints"] = anchors.has("left") and anchors.has("right") and anchors.size() == 2
	checks["long_attachment_rooted"] = long_blueprint.has_rooted_anchor_chain(beam, {})
	return {"passed": checks.values().all(func(value): return bool(value)), "checks": checks, "evidenceLevel": "synthetic_contact_contract"}

func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()
