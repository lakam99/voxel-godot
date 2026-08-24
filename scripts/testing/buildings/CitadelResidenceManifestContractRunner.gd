extends SceneTree

## A focused data contract. It proves deterministic bed-to-citizen manifests
## from the shared castle and furnishing grammar; it does not prove physics,
## player traversal, door use, scheduling, or visual behaviour.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const CitadelResidenceManifestBuilderScript := preload("res://scripts/buildings/CitadelResidenceManifestBuilder.gd")
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")

const SEEDS: Array[int] = [208158, 208159, 306701, 724169]
const RESIDENT_ACCESS_RADIUS := NpcConstantsScript.DEFAULT_NPC_RADIUS
const RESIDENT_ACCESS_STEP := 0.32
const RESIDENT_ACCESS_SNAP_DISTANCE := 0.56

var failures: Array[String] = []
var report_path := ""


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/citadel-residence-manifest-contract.json")
	var contract_seeds := requested_seeds()
	var rows: Array[Dictionary] = []
	for seed in contract_seeds:
		rows.append(verify_seed(seed))
	var report := {
		"runnerId": "citadel_residence_manifest_contract",
		"evidenceLevel": "contract",
		"scope": "Deterministic semantic residences, bed assignments and published-door identifiers. It does not prove NPC physics, live pathfinding, player movement or visual gameplay.",
		"seeds": contract_seeds,
		"siteKey": requested_site_key(),
		"citadelScale": requested_citadel_scale(),
		"biome": requested_biome(),
		"passed": failures.is_empty(),
		"rows": rows,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func requested_seeds() -> Array[int]:
	var raw_seeds := OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_SEEDS").strip_edges()
	if raw_seeds.is_empty():
		return SEEDS.duplicate()
	var result: Array[int] = []
	for value in raw_seeds.split(",", false):
		var seed_text := String(value).strip_edges()
		if seed_text.is_valid_int():
			result.append(seed_text.to_int())
	return result if not result.is_empty() else SEEDS.duplicate()


func requested_site_key() -> String:
	return OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_SITE_KEY").strip_edges()

func requested_citadel_scale() -> float:
	var raw_scale := OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_SCALE").strip_edges()
	return maxf(0.1, raw_scale.to_float()) if raw_scale.is_valid_float() else 1.25

func requested_biome() -> String:
	var biome := OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_BIOME").strip_edges().to_lower()
	return biome if not biome.is_empty() else "forest"


func verify_seed(seed: int) -> Dictionary:
	var requested_site := requested_site_key()
	var castle = CastleCompoundBlueprintBuilderScript.build(seed, {
		"biome": requested_biome(),
		"siteKey": requested_site if not requested_site.is_empty() else "citadel-life" if seed == 724169 else "citadel-life-contract",
		"citadelScale": requested_citadel_scale()
	})
	if castle == null:
		check(false, "seed %d failed closed before publishing its complete castle blueprint" % seed)
		return {"seed": seed, "blueprintPublished": false}
	var layout_contract := verify_courtyard_layout_contract(castle, seed)
	var composition_mutations := verify_composition_mutations(castle, seed)
	var runtime_collision_publication := verify_runtime_collision_publication(castle, seed)
	var physical_integrity: Dictionary = castle.validate_physical_integrity()
	check(bool(physical_integrity.get("passed", false)), "seed %d has invalid physical construction records: %s" % [seed, JSON.stringify(physical_integrity.get("violations", []))])
	var furnishing_seed := seed * 7919 + 37
	var furnishing = CastleFurnishingPlannerScript.build(castle, furnishing_seed)
	var replay_furnishing = CastleFurnishingPlannerScript.build(castle, furnishing_seed)
	var manifest := CitadelResidenceManifestBuilderScript.build(castle, furnishing)
	var replay := CitadelResidenceManifestBuilderScript.build(castle, replay_furnishing)
	var building_navigation_manifest := BuildingNavigationManifestBuilderScript.build(castle)
	var support_by_id := {}
	var door_by_part_id := {}
	for support_value in building_navigation_manifest.get("supports", []) as Array:
		if support_value is Dictionary:
			var support: Dictionary = support_value
			support_by_id[String(support.get("id", ""))] = support
	for door_value in building_navigation_manifest.get("doors", []) as Array:
		if door_value is Dictionary:
			var door: Dictionary = door_value
			door_by_part_id[String(door.get("sourcePartId", ""))] = door
	check(
		CitadelResidenceManifestBuilderScript.deterministic_signature(manifest) == CitadelResidenceManifestBuilderScript.deterministic_signature(replay),
		"seed %d residence manifest did not replay deterministically" % seed
	)
	var source_bed_ids := {}
	var home_building_blockers := {}
	var access_reservations: Array[AABB] = furnishing.access_reservations_snapshot()
	check(not access_reservations.is_empty(), "seed %d castle furnishing lacks source access reservations" % seed)
	for part in furnishing.parts:
		if part == null:
			continue
		if String(part.archetype) in ["rug", "aisle_runner"]:
			continue
		var part_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation)
		check(not InteriorFurnishingLayoutScript.intersects_any(part_bounds, access_reservations), "seed %d furnishing %s occupies a protected castle access" % [seed, String(part.id)])
	for part in furnishing.parts:
		if part == null or String(part.archetype) != "bed":
			continue
		if not String(part.recipe.get("castleResidenceId", "")).is_empty():
			source_bed_ids[String(part.id)] = true
	check(not source_bed_ids.is_empty(), "seed %d did not expose any castle residence beds" % seed)
	check((manifest.get("missingDoors", []) as Array).is_empty(), "seed %d has courtyard residences without source door parts: %s" % [seed, JSON.stringify(manifest.get("missingDoors", []))])
	check((manifest.get("unassignedBeds", []) as Array).is_empty(), "seed %d has beds without a strict interior stand cell: %s" % [seed, JSON.stringify(manifest.get("unassignedBeds", []))])
	for residence_value in manifest.get("residences", []) as Array:
		if residence_value is Dictionary:
			var residence: Dictionary = residence_value
			check(int(residence.get("bedCount", 0)) > 0, "seed %d residence %s has no bed" % [seed, String(residence.get("residenceId", ""))])
	var seen_citizens := {}
	var assigned_bed_ids := {}
	var residences_without_beds: Array[Dictionary] = []
	for residence_value in manifest.get("residences", []) as Array:
		if not (residence_value is Dictionary):
			continue
		var residence: Dictionary = residence_value
		if int(residence.get("bedCount", 0)) > 0:
			continue
		var residence_id := String(residence.get("residenceId", ""))
		residences_without_beds.append(residence_without_bed_diagnostic(castle, residence_id))
	for citizen_value in manifest.get("citizens", []) as Array:
		if not citizen_value is Dictionary:
			continue
		var citizen: Dictionary = citizen_value
		var id := String(citizen.get("id", ""))
		var bed_id := String(citizen.get("bedPartId", ""))
		check(not id.is_empty() and not seen_citizens.has(id), "seed %d repeats/omits citizen id %s" % [seed, id])
		check(source_bed_ids.has(bed_id) and not assigned_bed_ids.has(bed_id), "seed %d does not maintain one citizen per bed %s" % [seed, bed_id])
		seen_citizens[id] = true
		assigned_bed_ids[bed_id] = true
		var home_cell: Vector2i = citizen.get("homeCell", Vector2i.ZERO)
		var interior_min: Vector2i = citizen.get("interiorMinCell", Vector2i.ZERO)
		var interior_max: Vector2i = citizen.get("interiorMaxCell", Vector2i.ZERO)
		var door_cell: Vector2i = citizen.get("doorCell", CitadelResidenceManifestBuilderScript.INVALID_CELL)
		var porch_cell: Vector2i = citizen.get("porchCell", CitadelResidenceManifestBuilderScript.INVALID_CELL)
		var porch_position: Vector3 = citizen.get("porchPosition", Vector3.INF)
		var porch_support_id := String(citizen.get("porchSupportId", ""))
		var door_interior_position: Vector3 = citizen.get("doorInteriorPosition", Vector3.INF)
		var door_exterior_position: Vector3 = citizen.get("doorExteriorPosition", Vector3.INF)
		var source_door: Dictionary = door_by_part_id.get(String(citizen.get("doorPartId", "")), {}) as Dictionary
		check(home_cell.x >= interior_min.x and home_cell.x <= interior_max.x and home_cell.y >= interior_min.y and home_cell.y <= interior_max.y, "seed %d citizen %s has home cell outside strict interior bounds" % [seed, id])
		check(home_cell != door_cell, "seed %d citizen %s stands on the home door cell" % [seed, id])
		check(porch_position.is_finite() and is_equal_approx(porch_position.x, float(porch_cell.x) * 1.35) and is_equal_approx(porch_position.z, float(porch_cell.y) * 1.35), "seed %d citizen %s has a porch position that does not match its porch cell" % [seed, id])
		check(not porch_support_id.is_empty() and support_by_id.has(porch_support_id), "seed %d citizen %s has no published support for its porch" % [seed, id])
		if support_by_id.has(porch_support_id):
			var porch_support: Dictionary = support_by_id[porch_support_id] as Dictionary
			var expected_porch_y := CitadelResidenceManifestBuilderScript.support_surface_y(porch_support, porch_position) + 0.04
			check(is_equal_approx(porch_position.y, expected_porch_y), "seed %d citizen %s porch height does not match its published support" % [seed, id])
		check(door_interior_position.is_finite() and not source_door.is_empty(), "seed %d citizen %s has no published interior door endpoint" % [seed, id])
		if not source_door.is_empty():
			check(bool(source_door.get("sourcePortalReady", false)), "seed %d citizen %s door %s did not bind both endpoints to published supports: %s" % [seed, id, String(citizen.get("doorPartId", "")), JSON.stringify(source_door.get("portalSupportResolution", {}))])
			var interior_support_id := String(source_door.get("interiorSupportId", ""))
			var exterior_support_id := String(source_door.get("exteriorSupportId", ""))
			check(not interior_support_id.is_empty() and support_by_id.has(interior_support_id), "seed %d citizen %s door lacks a published interior endpoint support" % [seed, id])
			check(not exterior_support_id.is_empty() and support_by_id.has(exterior_support_id), "seed %d citizen %s door lacks a published exterior endpoint support" % [seed, id])
			var expected_door_interior: Vector3 = source_door.get("interior", Vector3.INF) as Vector3
			check(door_interior_position.distance_to(expected_door_interior) <= 0.001, "seed %d citizen %s egress target does not match its published interior door endpoint" % [seed, id])
			var expected_door_exterior: Vector3 = source_door.get("exterior", Vector3.INF) as Vector3
			check(door_exterior_position.is_finite() and door_exterior_position.distance_to(expected_door_exterior) <= 0.001, "seed %d citizen %s departure target does not match its published exterior door endpoint" % [seed, id])
		var home_position: Vector3 = citizen.get("homePosition", Vector3(float(home_cell.x) * 1.35, float(citizen.get("level", 0.0)), float(home_cell.y) * 1.35)) as Vector3
		var home_blocker := furnishing_blocker_for_resident_position(furnishing, home_position)
		check(home_blocker.is_empty(), "seed %d citizen %s home stand cell overlaps furnishing %s" % [seed, id, home_blocker])
		home_building_blockers[id] = building_blockers_for_resident_position(castle, home_position)
		var access := CitadelResidenceManifestBuilderScript.furnishing_egress_path(citizen, furnishing, building_navigation_manifest, 1.35)
		check(bool(access.get("reachable", false)), "seed %d citizen %s has no collision-clear route from its published interior door endpoint to bed stand: %s" % [seed, id, JSON.stringify(access)])
		check(String(citizen.get("doorPortalId", "")).begins_with("building:%s:castle_" % String(castle.id)), "seed %d citizen %s has a portal id that cannot be produced by BuildingPartPublisher" % [seed, id])
	check(assigned_bed_ids.size() == source_bed_ids.size(), "seed %d assigned %d citizens to %d semantic beds" % [seed, assigned_bed_ids.size(), source_bed_ids.size()])
	return {
		"seed": seed,
		"layoutContract": layout_contract,
		"compositionMutations": composition_mutations,
		"runtimeCollisionPublication": runtime_collision_publication,
		"castleParts": castle.parts.size(),
		"physicalIntegrity": physical_integrity,
		"furnishingParts": furnishing.parts.size(),
		"residenceCount": (manifest.get("residences", []) as Array).size(),
		"bedCount": source_bed_ids.size(),
		"citizenCount": (manifest.get("citizens", []) as Array).size(),
		"homeBuildingBlockers": home_building_blockers,
		"unassignedBeds": (manifest.get("unassignedBeds", []) as Array).duplicate(),
		"unassignedBedDiagnostics": (manifest.get("unassignedBedDiagnostics", []) as Array).duplicate(true),
		"egressProfiles": egress_profiles_by_residence(furnishing),
		"egressDiagnostics": furnishing.egress_diagnostics.duplicate(true),
		"residencesWithoutBeds": residences_without_beds
	}

func building_blockers_for_resident_position(castle, position: Vector3) -> Array[String]:
	var result: Array[String] = []
	var capsule := {"center": position + Vector3.UP * 0.81, "size": Vector3(0.68, 1.62, 0.68), "basis": Basis.IDENTITY}
	for part in castle.parts:
		if part == null or not bool(part.collision_enabled):
			continue
		var part_shape := {"center": part.position, "size": part.size, "basis": Basis.from_euler(part.rotation)}
		if CastleCompoundBlueprintBuilderScript.composition_parts_overlap(capsule, part_shape):
			result.append(String(part.id))
			if result.size() >= 12:
				break
	return result


func verify_courtyard_layout_contract(castle, seed: int) -> Dictionary:
	var residences: Array = castle.recipe.get("courtyardResidences", []) as Array
	var compound: Dictionary = castle.recipe.get("compound", {}) as Dictionary
	var grammar: Dictionary = compound.get("castleGrammar", castle.recipe.get("castleGrammar", {})) as Dictionary
	var sampled_program: Array = grammar.get("courtyardProgram", []) as Array
	check(residences.size() == sampled_program.size(), "seed %d published %d of %d sampled courtyard residences" % [seed, residences.size(), sampled_program.size()])
	check(residences.size() == int(castle.recipe.get("courtyardBuildingCount", -1)), "seed %d courtyard building count does not match its published residence list" % seed)
	var by_symmetry_group := {}
	var footprints: Array[Dictionary] = []
	for residence_value in residences:
		if not residence_value is Dictionary:
			continue
		var residence: Dictionary = residence_value
		var residence_id := String(residence.get("id", ""))
		var symmetry_group := String(residence.get("symmetryGroup", ""))
		var mirror_side := String(residence.get("mirrorSide", ""))
		var resolved_slot: Dictionary = residence.get("resolvedPairSlot", {}) as Dictionary
		var footprint: Dictionary = residence.get("collisionFootprint", {}) as Dictionary
		var footprint_center: Vector3 = footprint.get("center", Vector3.INF) as Vector3
		check(not residence_id.is_empty(), "seed %d publishes a courtyard residence without a stable id" % seed)
		check(not symmetry_group.is_empty() and mirror_side in ["left", "right"], "seed %d residence %s lost its sampled symmetry identity" % [seed, residence_id])
		check(not resolved_slot.is_empty() and resolved_slot.has("index") and resolved_slot.has("offset"), "seed %d residence %s has no deterministic resolved pair slot" % [seed, residence_id])
		check(footprint_center.is_finite() and float(footprint.get("width", 0.0)) > 0.0 and float(footprint.get("depth", 0.0)) > 0.0 and int(footprint.get("sourceCollisionPartCount", 0)) > 0, "seed %d residence %s has no source-collider-derived lot footprint" % [seed, residence_id])
		var published_footprint := published_residence_collision_footprint(castle, residence_id)
		check(not published_footprint.is_empty(), "seed %d residence %s publishes no source collision geometry" % [seed, residence_id])
		if not published_footprint.is_empty() and footprint_center.is_finite():
			check(footprint_contains(footprint, published_footprint, 0.02), "seed %d residence %s publishes collision outside its planned source footprint: planned=%s published=%s" % [seed, residence_id, JSON.stringify(footprint), JSON.stringify(published_footprint)])
		verify_published_composition_matches(castle, residence, seed)
		footprints.append({"residenceId": residence_id, "footprint": footprint})
		if not by_symmetry_group.has(symmetry_group):
			by_symmetry_group[symmetry_group] = {}
		(by_symmetry_group[symmetry_group] as Dictionary)[mirror_side] = {"residenceId": residence_id, "slot": resolved_slot}
	for symmetry_group_value in by_symmetry_group.keys():
		var symmetry_group := String(symmetry_group_value)
		var pair: Dictionary = by_symmetry_group[symmetry_group] as Dictionary
		check(pair.has("left") and pair.has("right"), "seed %d symmetry group %s did not preserve both sampled residences" % [seed, symmetry_group])
		if pair.has("left") and pair.has("right"):
			check((pair["left"] as Dictionary).get("slot", {}) == (pair["right"] as Dictionary).get("slot", {}), "seed %d symmetry group %s did not resolve as one mirrored pair" % [seed, symmetry_group])
	for first_index in range(footprints.size()):
		for second_index in range(first_index + 1, footprints.size()):
			var first: Dictionary = footprints[first_index]
			var second: Dictionary = footprints[second_index]
			check(not footprints_overlap(first.get("footprint", {}) as Dictionary, second.get("footprint", {}) as Dictionary), "seed %d planned residence colliders overlap between %s and %s" % [seed, String(first.get("residenceId", "")), String(second.get("residenceId", ""))])
	return {
		"sampledResidenceCount": sampled_program.size(),
		"publishedResidenceCount": residences.size(),
		"symmetryPairCount": by_symmetry_group.size(),
		"collisionFootprintCount": footprints.size()
	}


func verify_published_composition_matches(castle, residence: Dictionary, seed: int) -> void:
	var residence_id := String(residence.get("id", ""))
	var descriptor: Dictionary = residence.get("compositionDescriptor", {}) as Dictionary
	var expected_ids := {}
	for planned_value in descriptor.get("collisionParts", []) as Array:
		var planned: Dictionary = planned_value as Dictionary
		var published_id := composition_published_part_id(residence_id, planned)
		expected_ids[published_id] = true
		var published = castle_part_by_id(castle, published_id)
		check(published != null and bool(published.collision_enabled), "seed %d residence %s did not publish planned collider %s" % [seed, residence_id, published_id])
		if published == null:
			continue
		var planned_center: Vector3 = planned.get("center", Vector3.INF) as Vector3
		var planned_size: Vector3 = planned.get("size", Vector3.ZERO) as Vector3
		var planned_basis: Basis = planned.get("basis", Basis.IDENTITY) as Basis
		check(published.position.distance_to(planned_center) <= 0.001 and published.size.distance_to(planned_size) <= 0.001 and Basis.from_euler(published.rotation).is_equal_approx(planned_basis), "seed %d residence %s published collider %s diverged from its composition descriptor" % [seed, residence_id, published_id])
	for part in castle.parts:
		if part == null or not bool(part.collision_enabled) or String(part.recipe.get("castleResidenceId", "")) != residence_id:
			continue
		check(expected_ids.has(String(part.id)), "seed %d residence %s published undeclared composed collider %s" % [seed, residence_id, String(part.id)])


func composition_published_part_id(residence_id: String, planned: Dictionary) -> String:
	var role := String(planned.get("role", ""))
	if role == "source":
		return "castle_%s__%s" % [residence_id, String(planned.get("sourcePartId", ""))]
	if role == "egress_underfill":
		return "castle_%s_%s" % [residence_id, String(planned.get("id", ""))]
	if role == "plinth":
		return "castle_%s_structural_plinth" % residence_id
	return String(planned.get("id", ""))


func verify_runtime_collision_publication(castle, seed: int) -> Dictionary:
	var expected := {}
	var residence_ids := {}
	for residence_value in castle.recipe.get("courtyardResidences", []) as Array:
		if not residence_value is Dictionary:
			continue
		var residence: Dictionary = residence_value
		var residence_id := String(residence.get("id", ""))
		residence_ids[residence_id] = true
		var composition_descriptor: Dictionary = residence.get("compositionDescriptor", {}) as Dictionary
		for planned_value in composition_descriptor.get("collisionParts", []) as Array:
			var planned: Dictionary = planned_value as Dictionary
			var published_part_id := composition_published_part_id(residence_id, planned)
			var expected_shape := planned.duplicate(true)
			expected_shape["publishedPartId"] = published_part_id
			expected_shape["collisionRole"] = "blocking_part"
			expected["%s|blocking_part" % published_part_id] = expected_shape
		for interaction_value in composition_descriptor.get("runtimeInteractionShapes", []) as Array:
			var interaction: Dictionary = interaction_value as Dictionary
			var door_part_id := "castle_%s__%s" % [residence_id, String(interaction.get("sourcePartId", ""))]
			var expected_interaction := interaction.duplicate(true)
			expected_interaction["publishedPartId"] = door_part_id
			expected_interaction["collisionRole"] = String(interaction.get("role", "door_interaction_proxy"))
			expected["%s|%s" % [door_part_id, String(expected_interaction.get("collisionRole", ""))]] = expected_interaction
	var subset = BuildingBlueprintScript.new("%s.residence-collision-runtime-contract" % String(castle.id), seed, String(castle.style))
	subset.set_recipe({"family": "residence_collision_runtime_contract", "sourceBlueprintId": String(castle.id)})
	for part in castle.parts:
		if part == null or not residence_ids.has(String(part.recipe.get("castleResidenceId", ""))):
			continue
		var snapshot: Dictionary = part.snapshot()
		var recipe: Dictionary = snapshot.get("recipe", {}) as Dictionary
		recipe["visual"] = false
		snapshot["recipe"] = recipe
		subset.add_part(snapshot)
	var publication_root := Node3D.new()
	publication_root.name = "CitadelResidenceCollisionRuntimeContract_%d" % seed
	get_root().add_child(publication_root)
	var publisher = BuildingPartPublisherScript.new()
	var summary: Dictionary = publisher.publish(subset, publication_root, {"batchStaticParts": true, "structuralAuthorityBlueprint": castle})
	var seen_counts := {}
	var unexpected_shapes: Array[String] = []
	var total_runtime_shape_count := 0
	for node_value in publication_root.find_children("*", "CollisionShape3D", true, false):
		var collision := node_value as CollisionShape3D
		if collision == null:
			continue
		total_runtime_shape_count += 1
		var part_id := String(collision.get_meta("building_part_id", ""))
		if part_id.is_empty():
			unexpected_shapes.append("<unowned:%s>" % String(collision.get_path()))
			continue
		var collision_role := String(collision.get_meta("building_collision_role", ""))
		var shape_key := "%s|%s" % [part_id, collision_role]
		if not expected.has(shape_key):
			unexpected_shapes.append(shape_key)
			continue
		var planned: Dictionary = expected[shape_key] as Dictionary
		var box := collision.shape as BoxShape3D
		var planned_center: Vector3 = planned.get("center", Vector3.INF) as Vector3
		var planned_size: Vector3 = planned.get("size", Vector3.ZERO) as Vector3
		var planned_basis: Basis = planned.get("basis", Basis.IDENTITY) as Basis
		var transform := collision.global_transform
		var matches := box != null and box.size.distance_to(planned_size) <= 0.001 and transform.origin.distance_to(planned_center) <= 0.001 and transform.basis.is_equal_approx(planned_basis)
		check(matches, "seed %d runtime collision shape %s diverged from its residence composition descriptor" % [seed, shape_key])
		seen_counts[shape_key] = int(seen_counts.get(shape_key, 0)) + 1
	check(unexpected_shapes.is_empty(), "seed %d BuildingPartPublisher emitted unexpected residence collision shapes: %s" % [seed, JSON.stringify(unexpected_shapes)])
	var duplicate_shape_ids: Array[String] = []
	for part_id_value in seen_counts.keys():
		if int(seen_counts[part_id_value]) != 1:
			duplicate_shape_ids.append(String(part_id_value))
	check(duplicate_shape_ids.is_empty(), "seed %d BuildingPartPublisher emitted duplicate residence collision shapes: %s" % [seed, JSON.stringify(duplicate_shape_ids)])
	check(seen_counts.size() == expected.size(), "seed %d BuildingPartPublisher emitted %d of %d planned residence collision shapes" % [seed, seen_counts.size(), expected.size()])
	check(total_runtime_shape_count == expected.size(), "seed %d BuildingPartPublisher emitted %d total runtime shapes for %d declared residence shapes" % [seed, total_runtime_shape_count, expected.size()])
	publication_root.free()
	var passed := unexpected_shapes.is_empty() and duplicate_shape_ids.is_empty() and seen_counts.size() == expected.size() and total_runtime_shape_count == expected.size()
	return {"passed": passed, "expectedShapeCount": expected.size(), "publishedShapeCount": seen_counts.size(), "totalRuntimeShapeCount": total_runtime_shape_count, "unexpectedShapeIds": unexpected_shapes, "duplicateShapeIds": duplicate_shape_ids, "publisherBlockingCollisionCount": int(summary.get("collisionPartCount", 0)), "publisherPartCount": int(summary.get("publishedPartCount", 0)), "completeTaggedResidenceSubsetPartCount": subset.parts.size()}


func verify_composition_mutations(castle, seed: int) -> Dictionary:
	var residences: Array = castle.recipe.get("courtyardResidences", []) as Array
	var pilaster_rejected := false
	var neighbour_stair_rejected := false
	var manor_descriptor: Dictionary = {}
	var descriptors: Array[Dictionary] = []
	for residence_value in residences:
		if not residence_value is Dictionary:
			continue
		var descriptor: Dictionary = (residence_value as Dictionary).get("compositionDescriptor", {}) as Dictionary
		descriptors.append(descriptor)
		if not pilaster_rejected:
			var mutated := descriptor.duplicate(true)
			var corridor: Dictionary = mutated.get("doorCorridor", {}) as Dictionary
			for part_value in mutated.get("collisionParts", []) as Array:
				var part: Dictionary = part_value as Dictionary
				if String(part.get("semantic", "")) != "castle_residence_awning_pilaster":
					continue
				part["center"] = corridor.get("center", Vector3.ZERO)
				pilaster_rejected = not CastleCompoundBlueprintBuilderScript.residence_composition_is_valid(mutated)
				break
		if manor_descriptor.is_empty():
			for part_value in descriptor.get("collisionParts", []) as Array:
				if String((part_value as Dictionary).get("semantic", "")).contains("manor_stair"):
					manor_descriptor = descriptor
					break
	check(pilaster_rejected, "seed %d pre-publication composition validation accepted a pilaster inside its generated door corridor" % seed)
	var neighbour_descriptor: Dictionary = {}
	for descriptor in descriptors:
		if descriptor != manor_descriptor:
			neighbour_descriptor = descriptor
			break
	if not manor_descriptor.is_empty() and not neighbour_descriptor.is_empty():
		var mutated_neighbour := neighbour_descriptor.duplicate(true)
		var stair_center := Vector3.INF
		for part_value in manor_descriptor.get("collisionParts", []) as Array:
			var part: Dictionary = part_value as Dictionary
			if String(part.get("semantic", "")).contains("manor_stair"):
				stair_center = part.get("center", Vector3.INF) as Vector3
				break
		if stair_center.is_finite() and not (mutated_neighbour.get("collisionParts", []) as Array).is_empty():
			var intruder: Dictionary = (mutated_neighbour.get("collisionParts", []) as Array)[0] as Dictionary
			intruder["center"] = stair_center
			mutated_neighbour = CastleCompoundBlueprintBuilderScript.residence_composition_with_refreshed_aggregate(mutated_neighbour)
			neighbour_stair_rejected = CastleCompoundBlueprintBuilderScript.residence_compositions_overlap(manor_descriptor, mutated_neighbour, 0.0)
	var neighbour_stair_applicable := not manor_descriptor.is_empty()
	if neighbour_stair_applicable:
		check(neighbour_stair_rejected, "seed %d pre-publication pair validation accepted a neighbouring composed collider inside a manor stair support" % seed)
	return {"pilasterDoorCorridorRejected": pilaster_rejected, "neighbourManorStairApplicable": neighbour_stair_applicable, "neighbourManorStairRejected": neighbour_stair_rejected}


func castle_part_by_id(castle, part_id: String):
	for part in castle.parts:
		if part != null and String(part.id) == part_id:
			return part
	return null


func published_residence_collision_footprint(castle, residence_id: String) -> Dictionary:
	var minimum_x := INF
	var maximum_x := -INF
	var minimum_z := INF
	var maximum_z := -INF
	var part_count := 0
	for part in castle.parts:
		if part == null or not bool(part.collision_enabled) or String(part.recipe.get("castleResidenceId", "")) != residence_id:
			continue
		var basis := Basis.from_euler(part.rotation)
		var extent_x: float = absf(basis.x.x) * part.size.x * 0.5 + absf(basis.y.x) * part.size.y * 0.5 + absf(basis.z.x) * part.size.z * 0.5
		var extent_z: float = absf(basis.x.z) * part.size.x * 0.5 + absf(basis.y.z) * part.size.y * 0.5 + absf(basis.z.z) * part.size.z * 0.5
		minimum_x = minf(minimum_x, part.position.x - extent_x)
		maximum_x = maxf(maximum_x, part.position.x + extent_x)
		minimum_z = minf(minimum_z, part.position.z - extent_z)
		maximum_z = maxf(maximum_z, part.position.z + extent_z)
		part_count += 1
	if part_count == 0:
		return {}
	return {"center": Vector3((minimum_x + maximum_x) * 0.5, 0.0, (minimum_z + maximum_z) * 0.5), "width": maximum_x - minimum_x, "depth": maximum_z - minimum_z, "partCount": part_count}


func footprint_contains(container: Dictionary, contained: Dictionary, tolerance: float) -> bool:
	var container_center: Vector3 = container.get("center", Vector3.ZERO) as Vector3
	var contained_center: Vector3 = contained.get("center", Vector3.ZERO) as Vector3
	return contained_center.x - float(contained.get("width", 0.0)) * 0.5 >= container_center.x - float(container.get("width", 0.0)) * 0.5 - tolerance \
		and contained_center.x + float(contained.get("width", 0.0)) * 0.5 <= container_center.x + float(container.get("width", 0.0)) * 0.5 + tolerance \
		and contained_center.z - float(contained.get("depth", 0.0)) * 0.5 >= container_center.z - float(container.get("depth", 0.0)) * 0.5 - tolerance \
		and contained_center.z + float(contained.get("depth", 0.0)) * 0.5 <= container_center.z + float(container.get("depth", 0.0)) * 0.5 + tolerance


func footprints_overlap(first: Dictionary, second: Dictionary) -> bool:
	var first_center: Vector3 = first.get("center", Vector3.ZERO) as Vector3
	var second_center: Vector3 = second.get("center", Vector3.ZERO) as Vector3
	return absf(first_center.x - second_center.x) < (float(first.get("width", 0.0)) + float(second.get("width", 0.0))) * 0.5 \
		and absf(first_center.z - second_center.z) < (float(first.get("depth", 0.0)) + float(second.get("depth", 0.0))) * 0.5


func egress_profiles_by_residence(furnishing) -> Dictionary:
	var profiles := {}
	if furnishing == null:
		return profiles
	for part in furnishing.parts:
		if part == null:
			continue
		var residence_id := String(part.recipe.get("castleResidenceId", "")).strip_edges()
		var profile := String(part.recipe.get("castleEgressProfile", "")).strip_edges()
		if residence_id.is_empty() or profile.is_empty():
			continue
		profiles[residence_id] = profile
	return profiles


func residence_without_bed_diagnostic(castle, residence_id: String) -> Dictionary:
	var recipe: Dictionary = {}
	for residence_value in castle.recipe.get("courtyardResidences", []) as Array:
		if residence_value is Dictionary and String((residence_value as Dictionary).get("id", "")) == residence_id:
			recipe = ((residence_value as Dictionary).get("residenceRecipe", {}) as Dictionary).duplicate(true)
			break
	var rooms: Array[Dictionary] = []
	for room_value in castle.rooms:
		if not (room_value is Dictionary):
			continue
		var room: Dictionary = room_value
		if not String(room.get("id", "")).begins_with("%s_" % residence_id):
			continue
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		rooms.append({
			"id": String(room.get("id", "")),
			"bounds": bounds,
			"accesses": room.get("accesses", [])
		})
	return {
		"residenceId": residence_id,
		"recipe": recipe,
		"rooms": rooms
	}


func resident_access_path(citizen: Dictionary, furnishing, cell_size: float) -> Dictionary:
	var minimum: Vector2i = citizen.get("interiorMinCell", Vector2i.ZERO)
	var maximum: Vector2i = citizen.get("interiorMaxCell", Vector2i.ZERO)
	var start_cell: Vector2i = citizen.get("interiorLandingCell", minimum)
	var target_cell: Vector2i = citizen.get("homeCell", minimum)
	var level := float(citizen.get("level", 0.0))
	var minimum_position := Vector2((float(minimum.x) - 0.5) * cell_size + RESIDENT_ACCESS_RADIUS, (float(minimum.y) - 0.5) * cell_size + RESIDENT_ACCESS_RADIUS)
	var maximum_position := Vector2((float(maximum.x) + 0.5) * cell_size - RESIDENT_ACCESS_RADIUS, (float(maximum.y) + 0.5) * cell_size - RESIDENT_ACCESS_RADIUS)
	var columns := maxi(1, floori((maximum_position.x - minimum_position.x) / RESIDENT_ACCESS_STEP) + 1)
	var rows := maxi(1, floori((maximum_position.y - minimum_position.y) / RESIDENT_ACCESS_STEP) + 1)
	var free := {}
	var blocked_parts := {}
	for row in range(rows):
		for column in range(columns):
			var index := Vector2i(column, row)
			var position := Vector3(minimum_position.x + float(column) * RESIDENT_ACCESS_STEP, level, minimum_position.y + float(row) * RESIDENT_ACCESS_STEP)
			var blocker_id := furnishing_blocker_for_resident_position(furnishing, position)
			if blocker_id.is_empty():
				free[index] = position
			else:
				blocked_parts[blocker_id] = true
	var start_position := Vector3(float(start_cell.x) * cell_size, level, float(start_cell.y) * cell_size)
	var target_position := Vector3(float(target_cell.x) * cell_size, level, float(target_cell.y) * cell_size)
	var start := nearest_free_access_index(free, start_position)
	var target := nearest_free_access_index(free, target_position)
	if start == CitadelResidenceManifestBuilderScript.INVALID_CELL or target == CitadelResidenceManifestBuilderScript.INVALID_CELL:
		return {
			"reachable": false,
			"reason": "landing_or_bed_stand_has_no_clear_footprint",
			"landingReachable": start != CitadelResidenceManifestBuilderScript.INVALID_CELL,
			"bedStandReachable": target != CitadelResidenceManifestBuilderScript.INVALID_CELL,
			"blockedParts": blocked_parts.keys()
		}
	var frontier: Array[Vector2i] = [start]
	var visited := {start: true}
	var cursor := 0
	while cursor < frontier.size():
		var cell := frontier[cursor]
		cursor += 1
		if cell == target:
			return {"reachable": true, "blockedParts": blocked_parts.keys(), "visitedCellCount": visited.size()}
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next: Vector2i = cell + offset
			if next.x < 0 or next.x >= columns or next.y < 0 or next.y >= rows:
				continue
			if not free.has(next) or visited.has(next):
				continue
			visited[next] = true
			frontier.append(next)
	return {"reachable": false, "reason": "furnishing_access_disconnected", "blockedParts": blocked_parts.keys(), "visitedCellCount": visited.size()}


func nearest_free_access_index(free: Dictionary, position: Vector3) -> Vector2i:
	var result := CitadelResidenceManifestBuilderScript.INVALID_CELL
	var best_distance := INF
	for index_value in free.keys():
		if not (index_value is Vector2i):
			continue
		var index: Vector2i = index_value
		var candidate: Vector3 = free[index] as Vector3
		var distance := Vector2(candidate.x - position.x, candidate.z - position.z).length()
		if distance <= RESIDENT_ACCESS_SNAP_DISTANCE and distance < best_distance:
			result = index
			best_distance = distance
	return result


func furnishing_blocker_for_resident_position(furnishing, position: Vector3) -> String:
	for part in furnishing.parts:
		if part == null or not bool(part.collision_enabled):
			continue
		var part_base_y: float = part.position.y
		var part_top_y: float = part_base_y + part.occupied_size.y
		if part_top_y < position.y + 0.04 or part_base_y > position.y + 1.70:
			continue
		var bounds := InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, RESIDENT_ACCESS_RADIUS)
		if InteriorFurnishingLayoutScript.point_inside_horizontal_bounds(position, bounds):
			return String(part.id)
	return ""


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
