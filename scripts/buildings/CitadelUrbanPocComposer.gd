extends RefCounted
class_name CitadelUrbanPocComposer

const MARKET_LANE_X := 22.0
const MARKET_TERRACE_RISE := 1.8
const STREET_FOUNDATION_EXTRA := 0.28
const STREET_UPPER_EXTRA := 0.62
const STREET_UPPER_SHIFT := 0.31
const StreetOpeningLayout := preload("res://scripts/buildings/StreetHouseOpeningLayout.gd")
const STREET_ROOM_INSET := StreetOpeningLayout.ROOM_INSET
const STREET_WINDOW_WIDTH := StreetOpeningLayout.WINDOW_WIDTH
const DEFAULT_LANE_CENTERS := [0.0, 1.8, MARKET_LANE_X, 12.0]
const DEFAULT_ROW_WIDTH_BIASES := [0.0, 0.0, 0.0, 0.0]
const RowDepthPacking := preload("res://scripts/buildings/StreetRowDepthPacking.gd")
const CivicInfill := preload("res://scripts/buildings/CivicHouseInfillRecipe.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const BiomeEnvironmentCatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const GablePurlinFrameBuilderScript := preload("res://scripts/buildings/GablePurlinFrameBuilder.gd")
const RigidHouseholdLayoutRecipeScript := preload("res://scripts/buildings/RigidHouseholdLayoutRecipe.gd")
const ShopRecipeScript := preload("res://scripts/buildings/CitadelShopRecipe.gd")
const ShopFurnitureScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const FacadeBearingRecipeScript := preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const FacadeApertureDeclarationScript := preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const StreetHouseStructuralManifestScript := preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const StructuralCompletionRecipeScript := preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const BuntingManifest := preload("res://scripts/buildings/CitadelBuntingAssemblyManifest.gd")
const ExteriorBunting := preload("res://scripts/buildings/CitadelExteriorBuntingDomain.gd")
const RetainedBearingRecipeScript := preload("res://scripts/buildings/RetainedSurfaceBearingRecipe.gd")
const DoorGeometryScript := preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const TerminalSupport := preload("res://scripts/buildings/TerminalShopElevationRecipe.gd")
const MAX_TERMINAL_SUPPORT_PROOFS := 128
const MAX_TERMINAL_SUPPORT_RECORD_VISITS := 16000000
const FacadePartition = preload("res://scripts/buildings/FacadePartitionGeometry.gd")
const FacadeBlueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")


static func plan_household_on_paving(blueprint, member_ids: Array, front: Vector3, additional_reservations: Array[Rect2] = [], search_radius: float = 25.0, approach_width: float = 1.8, support_eligibility: Callable = Callable()) -> Dictionary:
	# Recipe adapter: derive eligible surfaces and fixed ecology reservations.
	# This does not move parts and is not yet invoked by compose().
	if blueprint == null or blueprint.parts.size() > RigidHouseholdLayoutRecipeScript.MAX_PARTS or member_ids.size() > RigidHouseholdLayoutRecipeScript.MAX_COLLECTION or not _layout_radius_valid(approach_width):
		return {"ready": false, "reason": "invalid_or_oversized_source"}
	var members: Dictionary = {}
	for id in member_ids:
		if not id is String or id.is_empty() or members.has(id):
			return {"ready": false, "reason": "invalid_or_duplicate_member"}
		members[id] = true
	var envelope := AABB()
	var first := true
	for part in blueprint.parts:
		if part == null or not RigidHouseholdLayoutRecipeScript._valid_part(part):
			return {"ready": false, "reason": "invalid_source_part"}
		if not members.has(part.id):
			continue
		var bounds := RigidHouseholdLayoutRecipeScript._bounds(blueprint.part_transform(part), part.size)
		envelope = bounds if first else envelope.merge(bounds)
		first = false
	if first:
		return {"ready": false, "reason": "missing_household"}
	var center := Vector2(envelope.get_center().x, envelope.get_center().z)
	var minimum_span := minf(envelope.size.x, envelope.size.z)
	var paving_ids: Array[String] = []
	var radius := search_radius
	for part in blueprint.parts:
		# Market households belong on declared public paving. A structural
		# terrace's decorative top material is not an access declaration.
		if not is_primary_tree_paving(part):
			continue
		if not part.collision_enabled or part.rotation != Vector3.ZERO:
			continue
		var rect := Rect2(Vector2(part.position.x - part.size.x * 0.5, part.position.z - part.size.z * 0.5), Vector2(part.size.x, part.size.z)).grow(-0.1)
		if rect.size.x < minimum_span or rect.size.y < minimum_span or center.distance_to(center.clamp(rect.position, rect.end)) > radius:
			continue
		if support_eligibility.is_valid():
			var proof: Dictionary = support_eligibility.call(part.id)
			if not proof.get("ready", false):
				# Only a completed negative coverage proof is ordinary ineligibility.
				# Invalid input and exhausted proof limits must remain failures.
				if proof.get("reason") == "incomplete_rooted_support_coverage":
					continue
				return {"ready": false, "reason": "paving_support_proof_failed", "supportId": part.id, "proof": proof}
		paving_ids.append(part.id)
	var reservations: Array[Rect2] = []
	reservations.append_array(additional_reservations)
	var urban = blueprint.recipe.get("urbanPoc", {})
	if not urban is Dictionary or not urban.get("treePlacements", []) is Array:
		return {"ready": false, "reason": "invalid_ecology_collection"}
	var trees: Array = urban.get("treePlacements", [])
	if trees.size() > RigidHouseholdLayoutRecipeScript.MAX_COLLECTION:
		return {"ready": false, "reason": "ecology_collection_limit_exceeded"}
	var root_count := 0
	for tree in trees:
		if not tree is Dictionary or not tree.get("position") is Vector3 or not tree.position.is_finite() or not _layout_radius_valid(tree.get("canopyRadius")) or not tree.get("rootButtressFootprints", []) is Array:
			return {"ready": false, "reason": "invalid_ecology_tree"}
		var position: Vector3 = tree.position
		var tree_radius := float(tree.canopyRadius)
		var rect := Rect2(Vector2(position.x, position.z) - Vector2.ONE * tree_radius, Vector2.ONE * tree_radius * 2.0)
		root_count += tree.get("rootButtressFootprints", []).size()
		if root_count > RigidHouseholdLayoutRecipeScript.MAX_COLLECTION:
			return {"ready": false, "reason": "ecology_collection_limit_exceeded"}
		for root in tree.get("rootButtressFootprints", []):
			if not root is Dictionary or not root.get("start") is Vector3 or not root.get("end") is Vector3 or not root.start.is_finite() or not root.end.is_finite() or not _layout_radius_valid(root.get("radiusStart")) or not _layout_radius_valid(root.get("radiusEnd")):
				return {"ready": false, "reason": "invalid_ecology_root"}
			# TreeSpawnService.interactionFacts already applies world pose.
			var start: Vector3 = root.start
			var end: Vector3 = root.end
			var root_radius := maxf(float(root.radiusStart), float(root.radiusEnd))
			rect = rect.merge(Rect2(Vector2(start.x, start.z), Vector2.ZERO).expand(Vector2(end.x, end.z)).grow(root_radius))
		reservations.append(rect)
	return RigidHouseholdLayoutRecipeScript.plan(blueprint, member_ids, {"pavingPartIds": paving_ids,
		"reservedFootprints": reservations, "front": front, "searchRadius": radius,
		"clearance": 0.1, "circulation": 0.8, "approachLength": 3.8, "approachWidth": approach_width, "gridStep": 0.25})


static func plan_terminal_shop_household(blueprint, member_ids: Array, front: Vector3, reservations: Array[Rect2]) -> Dictionary:
	# One intact multi-counter household. Reserve its FULL frontage for customer
	# use, unlike a market stall's single narrow approach. Geometry/RNG unchanged.
	if blueprint == null or not blueprint.recipe.get("castleGrammar") is Dictionary:
		return {"ready": false, "reason": "missing_courtyard_extent"}
	var grammar: Dictionary = blueprint.recipe.castleGrammar
	if not _layout_radius_valid(grammar.get("courtyardWidth")) or not _layout_radius_valid(grammar.get("courtyardDepth")):
		return {"ready": false, "reason": "missing_courtyard_extent"}
	if member_ids.is_empty() or member_ids.size() > RigidHouseholdLayoutRecipeScript.MAX_COLLECTION or blueprint.parts.size() > RigidHouseholdLayoutRecipeScript.MAX_PARTS:
		return {"ready": false, "reason": "invalid_terminal_membership"}
	if not front.is_finite() or front.y != 0.0 or absf(front.x) + absf(front.z) != 1.0 or front.length_squared() != 1.0:
		return {"ready": false, "reason": "terminal_front_must_be_cardinal"}
	var minimum := INF
	var maximum := -INF
	var axis := 0 if absf(front.z) == 1.0 else 2
	var seen: Dictionary = {}
	for id in member_ids:
		if not id is String or id.is_empty() or seen.has(id):
			return {"ready": false, "reason": "invalid_terminal_member_id"}
		seen[id] = true
		var part = blueprint.find_part(id)
		if part == null or not RigidHouseholdLayoutRecipeScript._valid_part(part):
			return {"ready": false, "reason": "invalid_terminal_member"}
		var bounds: AABB = blueprint.transformed_part_bounds(part)
		minimum = minf(minimum, bounds.position[axis])
		maximum = maxf(maximum, bounds.end[axis])
	var records: Dictionary = {}
	for part in blueprint.parts:
		if part == null or not RigidHouseholdLayoutRecipeScript._valid_part(part) or String(part.id).is_empty() or records.has(part.id):
			return {"ready": false, "reason": "invalid_terminal_support_source"}
		var bounds: AABB = blueprint.transformed_part_bounds(part)
		if not TerminalSupport._bounded(bounds):
			return {"ready": false, "reason": "invalid_terminal_support_bounds", "partId": part.id}
		records[part.id] = {"part": part, "bounds": bounds, "footprint": Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))}
	# Prove eligibility before the ordered placement search. Rejected paving
	# stays in the full source as geometry/obstacles. The selected, transformed
	# row is independently revalidated by CitadelShopRecipe before binding.
	var proof_count := [0]
	var eligibility := func(id: String) -> Dictionary:
		if proof_count[0] >= MAX_TERMINAL_SUPPORT_PROOFS:
			return {"ready": false, "reason": "terminal_support_proof_limit", "completedProofs": proof_count[0]}
		# Each closure can scan the complete record map for every context
		# member. Charge that conservative bound, including rejected surfaces,
		# before starting the next proof; per-closure grid/closure guards remain.
		if (proof_count[0] + 1) * records.size() * TerminalSupport.MAX_SUPPORT_CONTEXT > MAX_TERMINAL_SUPPORT_RECORD_VISITS:
			return {"ready": false, "reason": "terminal_support_work_limit", "completedProofs": proof_count[0]}
		proof_count[0] += 1
		return TerminalSupport._support_closure(blueprint, records, seen, id)
	return plan_household_on_paving(blueprint, member_ids, front, reservations,
		maxf(float(grammar.courtyardWidth), float(grammar.courtyardDepth)) * 0.5, maximum - minimum, eligibility)


static func _layout_radius_valid(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) > 0.0


static func plan_courtyard_household(blueprint, member_ids: Array, front: Vector3, reservations: Array[Rect2]) -> Dictionary:
	# Batch placement must consider the generated courtyard, not an old
	# diagnostic's fixed neighbourhood radius. No new paving is invented.
	if blueprint == null or not blueprint.recipe.get("castleGrammar") is Dictionary:
		return {"ready": false, "reason": "missing_courtyard_extent"}
	var grammar: Dictionary = blueprint.recipe.castleGrammar
	if not _layout_radius_valid(grammar.get("courtyardWidth")) or not _layout_radius_valid(grammar.get("courtyardDepth")):
		return {"ready": false, "reason": "missing_courtyard_extent"}
	var width := float(grammar.courtyardWidth)
	var depth := float(grammar.courtyardDepth)
	return plan_household_on_paving(blueprint, member_ids, front, reservations, maxf(width, depth) * 0.5)


static func compose(blueprint, seed: int):
	return _compose(blueprint, seed, {})


static func compose_prepared(blueprint, seed: int, diagnostic_callback: Callable = Callable(), raw_stage_observer: Callable = Callable()) -> Dictionary:
	var handoff: Dictionary = {}
	var result = _compose(blueprint, seed, handoff, diagnostic_callback, raw_stage_observer)
	if result == null:
		handoff["ready"] = false
		handoff["reason"] = String(handoff.get("reason", "citadel_composition_failed"))
		return handoff
	handoff["blueprint"] = result
	handoff["ready"] = true
	return handoff


static func _emit_compose_diagnostic(callback: Callable, stage: String) -> bool:
	if not callback.is_valid():
		return true
	return callback.call(stage) == true


static func prepare_furnishings(blueprint, seed: int) -> Dictionary:
	var source = ShopRecipeScript.copy_source(blueprint.snapshot())
	var plan = ShopFurnitureScript.build(source, seed * 7919 + 37)
	if plan == null: return {"ready": false, "reason": "citadel_furnishings_incomplete"}
	return {"ready": true, "furnishingPlan": plan, "interiorProgram": source.recipe.get("interiorProgram", {}).duplicate(true)}


static func _compose(blueprint, seed: int, handoff: Dictionary, diagnostic_callback: Callable = Callable(), raw_stage_observer: Callable = Callable()):
	if blueprint == null:
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "base_layout_started"):
		return null
	var retained_parts: Array = []
	var retired_roots: Array = []
	for part in blueprint.parts:
		var part_id := String(part.id) if part != null else ""
		if part_id.begins_with("castle_courtyard_") and part_id not in ["castle_courtyard_foundation", "castle_courtyard_paving"]:
			if blueprint.is_grounded_structural_root(part): retired_roots.append(part.snapshot())
			continue
		if part_id.begins_with("castle_residence_") or part_id.begins_with("castle_route_frontage_") or part_id.begins_with("castle_sightline_screen_") or part_id.begins_with("castle_gate_market_") or part_id.begins_with("castle_route_neck_"):
			if blueprint.is_grounded_structural_root(part): retired_roots.append(part.snapshot())
			continue
		if part != null and String(part.kind) == "foundation" and (part_id.begins_with("castle_terrace_block_") or part_id.begins_with("castle_district_processional_")):
			part.recipe["topSurfaceMaterial"] = "worn_cobble"
		retained_parts.append(part)
	blueprint.parts = retained_parts
	blueprint.rooms = blueprint.rooms.filter(func(room): return not bool((room as Dictionary).get("castleCourtyardResidence", false)) and not bool((room as Dictionary).get("castleResidenceRoom", false)))
	var recipe: Dictionary = blueprint.recipe.duplicate(true) as Dictionary
	recipe["courtyardResidences"] = []
	recipe["citadelUrbanHomes"] = []
	var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
	var foundation_height := float(recipe.get("foundationHeight", 0.62))
	var courtyard_depth := float(grammar.get("courtyardDepth", 84.0))
	var keep_depth := float(grammar.get("keepDepth", 28.0))
	var keep_center_z := courtyard_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14))
	var keep_front_z := keep_center_z - keep_depth * 0.5
	var front_z := -courtyard_depth * 0.5
	var street_rear_z := street_rear_boundary(blueprint,keep_front_z)
	if not is_finite(street_rear_z):
		handoff["reason"]="invalid_street_keep_boundary"
		return null
	var urban_layout := sample_urban_layout(seed, grammar, front_z, keep_front_z, foundation_height,street_rear_z)
	recipe["urbanPoc"] = urban_layout
	recipe["pavingTreatments"] = paving_treatments(urban_layout, front_z, keep_front_z)
	blueprint.set_recipe(recipe)
	var manifest_reset := reset_street_house_structural_manifest(blueprint)
	if not manifest_reset.ready:
		push_error("Citadel street-house structural manifest reset failed")
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "base_layout_completed"):
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "street_and_civic_started"):
		return null
	var variation := float(seed % 19) / 100.0 - 0.09
	var street_sequence := add_street_sequence(blueprint, front_z, keep_front_z, foundation_height, variation, urban_layout)
	if not street_sequence.get("ready", false):
		handoff["reason"] = "citadel_street_sequence_failed"
		handoff["streetSequenceFailure"] = street_sequence
		return null
	add_civic_landmark(blueprint, Vector3(-14.0, 0.0, keep_front_z - 4.0), foundation_height + 2.0, variation)
	add_terraced_edge(blueprint, Vector3(17.5, 0.0, keep_front_z - 9.0), foundation_height, variation)
	var infill_environment := _civic_infill_environment(blueprint,grammar,front_z,keep_front_z,foundation_height,variation,urban_layout,diagnostic_callback)
	if not infill_environment.ready:
		handoff["reason"]=infill_environment.reason
		return null
	var civic_quarter := add_civic_quarter(blueprint, front_z, keep_front_z, foundation_height, variation, urban_layout,infill_environment.blueprint,diagnostic_callback)
	if not bool(civic_quarter.get("ready", false)):
		handoff["reason"] = "citadel_civic_quarter_failed"
		handoff["civicQuarterFailure"] = civic_quarter
		return null
	handoff["civicInfill"]=civic_quarter.get("infill",{})
	var civic_commons := add_civic_commons(blueprint, front_z, keep_front_z, foundation_height, variation, urban_layout)
	if not civic_commons.get("ready", false):
		handoff["reason"] = "citadel_civic_commons_failed"
		handoff["civicCommonsFailure"] = civic_commons
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "street_and_civic_completed"):
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "perimeter_dressing_bunting_trees_started"):
		return null
	# Lower-level builders mutate this private source or return an Array. A
	# terminal per-call latch distinguishes cancellation from an empty result.
	var landscape_cancel := {"stopped": false}
	var landscape_continuation := Callable()
	if diagnostic_callback.is_valid():
		landscape_continuation = func(stage: String) -> bool:
			if landscape_cancel.stopped: return false
			var permitted: bool = diagnostic_callback.call(stage) == true
			landscape_cancel.stopped = not permitted
			return permitted
	var perimeter_ready := add_perimeter_neighborhoods(blueprint, grammar, keep_front_z, foundation_height, variation, landscape_continuation)
	if landscape_cancel.stopped:
		handoff["reason"] = "cancelled"
		return null
	if not perimeter_ready:
		handoff["reason"] = "perimeter_house_opening_layout_failed"
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "landscape_manifest_started"): return null
	var structural_manifest := StreetHouseStructuralManifestScript.read(blueprint)
	if not structural_manifest.ready:
		push_error("Citadel street-house structural manifest failed: %s" % String(structural_manifest.get("reason", "unknown")))
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "landscape_service_yard_started"): return null
	add_civic_service_yard(blueprint, Vector3(37.0, foundation_height, keep_front_z - 8.5), variation)
	if not _emit_compose_diagnostic(diagnostic_callback, "landscape_dressing_started"): return null
	add_dressing_clusters(blueprint, front_z, keep_front_z, foundation_height, variation)
	if not _emit_compose_diagnostic(diagnostic_callback, "landscape_bunting_started"): return null
	if not add_bunting_lines(blueprint, front_z, keep_front_z, foundation_height, variation, urban_layout):
		handoff["reason"] = "citadel_bunting_declaration_failed"
		return null
	var selection_status := {}
	var selected_tree_sites := select_open_paving_tree_sites(blueprint, seed, landscape_continuation, selection_status)
	if landscape_cancel.stopped:
		handoff["reason"] = "cancelled"
		return null
	if selection_status.has("reason"):
		handoff["reason"] = selection_status.reason
		return null
	if not selected_tree_sites.is_empty():
		var tree_records := build_tree_placement_records(selected_tree_sites, seed, landscape_continuation)
		if landscape_cancel.stopped:
			handoff["reason"] = "cancelled"
			return null
		tree_records = retain_home_clear_tree_records(blueprint, tree_records)
		urban_layout["treePlacements"] = tree_records
		recipe["urbanPoc"] = urban_layout
		recipe["landscapeTrees"] = urban_layout["treePlacements"]
		# Preserve declarations emitted after the earlier recipe copy was made.
		recipe["facadeApertures"] = blueprint.recipe.get("facadeApertures", {}).duplicate(true)
		recipe[StreetHouseStructuralManifestScript.KEY] = blueprint.recipe.get(StreetHouseStructuralManifestScript.KEY, {}).duplicate(true)
		recipe[BuntingManifest.KEY] = blueprint.recipe.get(BuntingManifest.KEY, []).duplicate(true)
		recipe["citadelMarketHousePair"] = blueprint.recipe.get("citadelMarketHousePair", {}).duplicate(true)
		recipe["citadelUrbanHomes"] = blueprint.recipe.get("citadelUrbanHomes", []).duplicate(true)
		blueprint.set_recipe(recipe)
	if not _emit_compose_diagnostic(diagnostic_callback, "perimeter_dressing_bunting_trees_completed"):
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "roof_frames_started"):
		return null
	var roof_frames := add_roof_frames(blueprint)
	if not bool(roof_frames.get("ready", false)):
		push_error("Citadel roof composition failed: %s" % JSON.stringify(roof_frames))
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "roof_frames_completed"):
		return null
	# Furniture remains owned by its existing seeded planner. Use an independent
	# source copy so its interior-program annotations do not mutate this recipe.
	# Callers must keep this bounded but expensive composition on a loading worker.
	if not _emit_compose_diagnostic(diagnostic_callback, "prepare_furnishings_started"):
		return null
	var prepared_furnishings := prepare_furnishings(blueprint, seed)
	if not prepared_furnishings.ready:
		push_error("Citadel shop preparation requires complete generated furnishings")
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "prepare_furnishings_completed"):
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "furnishing_obstacles_started"):
		return null
	var furniture = prepared_furnishings.furnishingPlan
	var frozen_furniture := var_to_bytes(furniture.snapshot())
	var frozen_furniture_reservations := var_to_bytes(furniture.protected_access_reservations)
	var reservations := shop_furnishing_obstacles(furniture)
	if not reservations.ready:
		push_error("Citadel shop furnishing reservations are invalid")
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "furnishing_obstacles_completed"):
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "shop_recipe_prepare_started"):
		return null
	var shops := ShopRecipeScript.prepare(blueprint, reservations.obstacles,
		add_market_stall_household, add_terminal_shop_row, plan_courtyard_household, plan_terminal_shop_household)
	if not shops.ready:
		handoff["reason"] = String(shops.get("reason", "citadel_shop_composition_failed"))
		handoff["shopFailure"] = shops
		push_error("Citadel shop composition failed: %s" % String(shops.get("reason", "unknown")))
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "shop_recipe_prepare_completed"):
		return null
	# Only a complete private result reaches the caller. Retain every existing
	# record object and source order; append the recipe's actual new frame parts.
	if not _emit_compose_diagnostic(diagnostic_callback, "shop_merge_started"):
		return null
	var terminal_omission: Dictionary = shops.get("terminals", {}).get("omission", {}) as Dictionary
	var omitted_part_ids: Array = terminal_omission.get("removedPartIds", []) as Array
	if not omitted_part_ids.is_empty():
		var omitted_set: Dictionary = {}
		for omitted_id_value in omitted_part_ids:
			var omitted_id := String(omitted_id_value)
			if omitted_id.is_empty() or omitted_set.has(omitted_id):
				handoff["reason"] = "citadel_shop_omission_invalid"
				return null
			omitted_set[omitted_id] = true
		var removed_count := 0
		for index in range(blueprint.parts.size() - 1, -1, -1):
			var source_part = blueprint.parts[index]
			if source_part != null and omitted_set.has(String(source_part.id)):
				blueprint.parts.remove_at(index)
				blueprint.physical_parts_by_id.erase(String(source_part.id))
				removed_count += 1
		if removed_count != omitted_set.size():
			handoff["reason"] = "citadel_shop_omission_source_mismatch"
			handoff["shopOmission"] = {"expected": omitted_set.keys(), "removedCount": removed_count}
			return null
		handoff["shopOmission"] = terminal_omission.duplicate(true)
	var originals: Dictionary = {}
	for part in blueprint.parts: originals[part.id] = part
	for part in shops.blueprint.parts:
		if not originals.has(part.id):
			blueprint.add_part(part.snapshot())
			continue
		var original = originals[part.id]
		original.position = part.position
		original.rotation = part.rotation
		original.size = part.size
		original.collision_enabled = part.collision_enabled
		original.physical_intent = part.physical_intent
		original.recipe = part.recipe.duplicate(true)
	if not _emit_compose_diagnostic(diagnostic_callback, "shop_merge_completed"):
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "retained_paving_prepare_started"):
		return null
	var retained_paving := prepare_retained_paving(blueprint, retired_roots, reservations.obstacles, diagnostic_callback)
	if retained_paving.get("reason", "") == "cancelled":
		handoff["reason"] = "cancelled"
		return null
	if not retained_paving.get("ready", false):
		handoff["reason"] = "citadel_retained_paving_failed"
		handoff["retainedPavingFailure"] = retained_paving
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "retained_paving_prepare_completed"):
		return null
	if not retained_paving.get("unchanged", false):
		var retained_commit := _commit_retained_paving(blueprint, retained_paving.afterSnapshot)
		if not retained_commit.ready:
			handoff["reason"] = "citadel_retained_paving_commit_failed"
			handoff["retainedPavingFailure"] = retained_commit
			return null
		handoff["retainedPaving"] = {"retiredRootCount": retired_roots.size(),
			"surfaceIds": retained_paving.selectedIds, "addedPartIds": retained_paving.emitted.map(func(row): return row.part.id)}
	# The same generic house/seat recipe used by the reviewed candidate runs
	# against this generated source and the unchanged furnishing reservations.
	# It stages atomically; no fixture artifact, seed-specific placement or
	# physical-pass override participates in production composition.
	settle_household_ground_dressing(blueprint)
	if not _emit_compose_diagnostic(diagnostic_callback, "structural_completion_prepare_started"):
		return null
	_time(raw_stage_observer,"structuralCompletion",true)
	var structural_completion := StructuralCompletionRecipeScript.prepare(blueprint, {
		"furnitureParts": furniture.snapshot().parts,
		"reservedVolumes": furniture.protected_access_reservations,
		"protectedObstacles": reservations.obstacles}, diagnostic_callback, raw_stage_observer)
	_time(raw_stage_observer,"structuralCompletion",false)
	if structural_completion.get("reason", "") == "cancelled":
		handoff["reason"] = "cancelled"
		return null
	if not structural_completion.get("ready", false):
		var failure_evidence: Dictionary = structural_completion.duplicate(true)
		failure_evidence.erase("afterSnapshot")
		handoff["reason"] = "citadel_structural_completion_failed"
		handoff["structuralCompletionFailure"] = failure_evidence
		push_error("Citadel structural completion failed: %s" % String(structural_completion.get("reason", "incomplete")))
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "structural_completion_prepare_completed"):
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "structural_commit_started"):
		return null
	var committed := _commit_structural_completion(blueprint, structural_completion.afterSnapshot)
	if not committed.ready:
		push_error("Citadel structural completion commit failed: %s" % String(committed.reason))
		return null
	var furniture_bytes_exact := frozen_furniture == var_to_bytes(furniture.snapshot())
	var reservation_bytes_exact := frozen_furniture_reservations == var_to_bytes(furniture.protected_access_reservations)
	if not furniture_bytes_exact or not reservation_bytes_exact:
		push_error("Citadel structural completion mutated the furnishing authority")
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "structural_commit_completed"):
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "perimeter_bearing_started"):
		return null
	var perimeter_bearing := append_perimeter_alley_outer_bearing(blueprint)
	if not perimeter_bearing.get("ready", false):
		handoff["reason"] = "citadel_perimeter_alley_bearing_failed"
		handoff["perimeterAlleyBearing"] = perimeter_bearing
		return null
	if not _emit_compose_diagnostic(diagnostic_callback, "perimeter_bearing_completed"):
		return null
	var civic_clearance := CivicInfill.validate_composed(blueprint,civic_quarter.infill,furniture,foundation_height,diagnostic_callback)
	if not civic_clearance.ready:
		handoff["reason"]="citadel_final_civic_clearance_failed"
		handoff["civicClearanceFailure"]=civic_clearance
		return null
	handoff["civicClearance"]=civic_clearance
	handoff["furnishingPlan"] = furniture
	handoff["interiorProgram"] = prepared_furnishings.interiorProgram
	handoff["furnishingPreservation"] = {"ready": true, "furnitureBytesExact": furniture_bytes_exact,
		"reservationBytesExact": reservation_bytes_exact}
	var completion_evidence: Dictionary = structural_completion.duplicate(true)
	completion_evidence.erase("afterSnapshot")
	completion_evidence["commit"] = committed
	handoff["structuralCompletion"] = completion_evidence
	handoff["perimeterAlleyBearing"] = perimeter_bearing
	return blueprint


static func shop_furnishing_obstacles(furniture) -> Dictionary:
	if furniture == null:
		return {"ready": false, "reason": "missing_furnishing_plan"}
	# Urban-home furniture is already enclosed by the house geometry consumed by
	# the exterior household planner.  Keep every doorway reservation, plus any
	# furnishing not owned by an enclosed urban home, so market placement cannot
	# use a home entry while avoiding redundant interior obstacle rectangles.
	var snapshot: Dictionary = furniture.snapshot()
	var exterior_parts: Array = []
	for record_value in snapshot.get("parts", []) as Array:
		if not record_value is Dictionary:
			return {"ready": false, "reason": "invalid_furnishing_record"}
		var record: Dictionary = record_value as Dictionary
		var recipe: Dictionary = record.get("recipe", {}) as Dictionary
		if String(recipe.get("citadelUrbanHomeId", "")).is_empty():
			exterior_parts.append(record)
	snapshot["parts"] = exterior_parts
	return ShopRecipeScript.furnishing_obstacles(snapshot, furniture.protected_access_reservations)


static func _time(observer: Callable, stage: String, beginning: bool) -> void:
	if observer.is_valid(): observer.call(stage,beginning)


static func append_perimeter_alley_outer_bearing(blueprint) -> Dictionary:
	if blueprint == null:
		return {"ready": false, "reason": "missing_blueprint"}
	var finishes: Array = blueprint.parts.filter(func(part): return part != null and String(part.semantic) == "citadel_perimeter_alley")
	finishes.sort_custom(func(a, b): return String(a.id) < String(b.id))
	if finishes.is_empty():
		return {"ready": false, "reason": "missing_perimeter_alley_finishes"}
	var added_ids: Array[String] = []
	for finish in finishes:
		var side := signf(finish.position.x)
		if is_zero_approx(side) or not finish.collision_enabled or finish.size.x < 1.20 or finish.size.z < 1.20:
			return {"ready": false, "reason": "invalid_perimeter_alley_finish", "finishId": String(finish.id)}
		var strip_width := minf(0.50, finish.size.x * 0.25)
		var local_center := Vector3(side * (finish.size.x * 0.5 - strip_width * 0.5), -finish.size.y * 0.5 - 0.05, 0.0)
		var finish_transform := Transform3D(Basis.from_euler(finish.rotation), finish.position)
		var strip_id := String(finish.id) + "_outer_bearing"
		if blueprint.find_part(strip_id) != null:
			return {"ready": false, "reason": "duplicate_perimeter_alley_bearing", "bearingId": strip_id}
		add_part(blueprint, strip_id, "foundation", "stone_foundation", finish_transform * local_center, Vector3(strip_width, 0.10, finish.size.z), {"rotation": finish.rotation, "collision": true, "visual": false, "variation": float(finish.recipe.get("variation", 0.0)) - 0.01, "semantic": "citadel_perimeter_alley_outer_bearing", "physicalIntent": "walkable_surface"})
		added_ids.append(strip_id)
	return {"ready": added_ids.size() == finishes.size(), "count": added_ids.size(), "bearingIds": added_ids}


static func reset_street_house_structural_manifest(blueprint) -> Dictionary:
	if blueprint == null or not blueprint.recipe is Dictionary:
		return {"ready": false, "reason": "invalid_manifest_reset_source"}
	blueprint.recipe[StreetHouseStructuralManifestScript.KEY] = {}
	return {"ready": true}


static func prepare_retained_paving(blueprint, retired_roots: Array, furnishing_obstacles: Array, continuation: Callable = Callable()) -> Dictionary:
	if not _emit_compose_diagnostic(continuation, "retained_paving_inputs"): return {"ready": false, "reason": "cancelled"}
	# Input provenance is captured by the sole prune decision above. No removed
	# geometry is inferred from a later fixture, seed, or name reconstruction.
	if blueprint == null or blueprint.rooms.size() > 4096 or furnishing_obstacles.size() > 4096:
		return {"ready": false, "reason": "retained_paving_input_limit"}
	var work := FacadeBearingRecipeScript.validation_grid_work(blueprint)
	if not work.ready: return work
	var protected: Array = []
	for obstacle in furnishing_obstacles:
		if not _emit_compose_diagnostic(continuation, "retained_paving_furnishing"): return {"ready": false, "reason": "cancelled"}
		if not obstacle is Dictionary or not obstacle.get("bounds") is AABB:
			return {"ready": false, "reason": "invalid_retained_paving_furnishing"}
		protected.append(obstacle.bounds)
	for room in blueprint.rooms:
		if not _emit_compose_diagnostic(continuation, "retained_paving_room"): return {"ready": false, "reason": "cancelled"}
		if not room is Dictionary or not room.get("bounds") is AABB or not RetainedBearingRecipeScript.valid_box(room.bounds) or not room.get("accesses", []) is Array:
			return {"ready": false, "reason": "invalid_retained_paving_room"}
		# Shared facade recipes reserve interiors, not a courtyard's entire ground.
		if room.get("role", "") != "courtyard": protected.append(room.bounds)
		if protected.size() + room.get("accesses", []).size() > 4096:
			return {"ready": false, "reason": "retained_paving_reservation_limit"}
		for access in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3:
				return {"ready": false, "reason": "invalid_retained_paving_access"}
			protected.append(AABB(access.position - access.size * 0.5, access.size))
	var targets: Array = []
	for part in blueprint.parts:
		if not _emit_compose_diagnostic(continuation, "retained_paving_part"): return {"ready": false, "reason": "cancelled"}
		if part.semantic == "castle_courtyard_paving" and part.collision_enabled: targets.append(part.id)
		if part.kind != "door": continue
		var sweep: Array = []
		if part.recipe.get("doorPresentation", "") == "portcullis":
			if ceili(part.size.x / 0.30) + protected.size() + 5 > 4096:
				return {"ready": false, "reason": "retained_paving_door_limit"}
			sweep = DoorGeometryScript.portcullis_sweep_bounds(part.size, blueprint.part_transform(part))
		else:
			var angle: Variant = part.recipe.get("openSwing", DoorGeometryScript.DEFAULT_OPEN_SWING)
			if not (angle is float or angle is int): return {"ready": false, "reason": "invalid_retained_paving_door_angle"}
			for primitive in DoorGeometryScript.ordinary_sweep_bounds(part.size, blueprint.part_transform(part), float(angle)):
				sweep.append(primitive.bounds)
		if sweep.is_empty(): return {"ready": false, "reason": "invalid_retained_paving_door"}
		protected.append_array(sweep)
		if protected.size() > 4096: return {"ready": false, "reason": "retained_paving_reservation_limit"}
	for volume in protected:
		if not _emit_compose_diagnostic(continuation, "retained_paving_reserved_volume"): return {"ready": false, "reason": "cancelled"}
		if not volume is AABB or not RetainedBearingRecipeScript.valid_box(volume):
			return {"ready": false, "reason": "invalid_retained_paving_reserved_volume"}
	return RetainedBearingRecipeScript.prepare(blueprint, retired_roots, targets, protected, continuation)


static func _commit_retained_paving(blueprint, snapshot: Dictionary) -> Dictionary:
	if blueprint == null or not snapshot.get("parts") is Array or not snapshot.get("rooms") is Array or not snapshot.get("recipe") is Dictionary:
		return {"ready": false, "reason": "invalid_retained_paving_snapshot"}
	var count: int = blueprint.parts.size()
	if snapshot.parts.size() < count or snapshot.parts.size() > count + RetainedBearingRecipeScript.MAX_FRAGMENTS:
		return {"ready": false, "reason": "invalid_retained_paving_part_count"}
	if var_to_bytes(snapshot.parts.slice(0,count)) != var_to_bytes(blueprint.part_snapshots()) or var_to_bytes(snapshot.rooms) != var_to_bytes(blueprint.rooms) or var_to_bytes(snapshot.recipe) != var_to_bytes(blueprint.recipe):
		return {"ready": false, "reason": "retained_paving_changed_existing_source"}
	# The existing transactional commit validates the complete result before
	# mutation, preserving original part objects and their ordered records.
	return _commit_structural_completion(blueprint, snapshot)


static func _commit_structural_completion(blueprint, snapshot: Dictionary) -> Dictionary:
	if blueprint == null or not snapshot.get("parts") is Array or not snapshot.get("rooms") is Array or not snapshot.get("recipe") is Dictionary:
		return {"ready": false, "reason": "invalid_structural_completion_snapshot"}
	var snapshot_work := {"nodes": 0}
	if not _snapshot_value_is_bounded(snapshot.rooms, 0, snapshot_work) or not _snapshot_value_is_bounded(snapshot.recipe, 0, snapshot_work):
		return {"ready": false, "reason": "invalid_structural_completion_snapshot_values",
			"validationReason": snapshot_work.get("reason", "unknown"), "validationNodes": snapshot_work.nodes}
	var records: Array = snapshot.parts
	var existing_count: int = blueprint.parts.size()
	if records.size() < existing_count or var_to_bytes(snapshot.rooms) != var_to_bytes(blueprint.rooms):
		return {"ready": false, "reason": "structural_completion_removed_or_changed_owned_records"}
	var seen: Dictionary = {}
	for index in range(records.size()):
		var record: Variant = records[index]
		if not _structural_completion_record_valid(record, snapshot_work) or seen.has(record.id):
			return {"ready": false, "reason": "invalid_structural_completion_part_inventory"}
		seen[record.id] = true
		if index < existing_count and blueprint.parts[index].id != record.id:
			return {"ready": false, "reason": "structural_completion_reordered_existing_parts"}
	# Every potentially failing check is complete before the sole commit below.
	for index in range(existing_count):
		var original = blueprint.parts[index]
		var record: Dictionary = records[index]
		original.kind = String(record.kind)
		original.material_id = String(record.material)
		original.position = record.position
		original.rotation = record.rotation
		original.size = record.size
		original.collision_enabled = bool(record.collision)
		original.semantic = String(record.semantic)
		original.physical_intent = String(record.physicalIntent)
		original.recipe = record.recipe.duplicate(true)
	for index in range(existing_count, records.size()):
		blueprint.add_part(records[index])
	blueprint.set_recipe(snapshot.recipe.duplicate(true))
	blueprint.physical_parts_by_id.clear()
	for part in blueprint.parts: blueprint.physical_parts_by_id[part.id] = part
	return {"ready": true, "existingPartCount": existing_count, "addedPartCount": records.size() - existing_count}


static func _structural_completion_record_valid(value: Variant, work: Dictionary) -> bool:
	if not value is Dictionary:
		return false
	var record: Dictionary = value
	if not record.has_all(["id", "kind", "material", "position", "rotation", "size", "collision", "semantic", "physicalIntent", "recipe"]):
		return false
	if not record.id is String or record.id.is_empty() or record.id != record.id.strip_edges() \
			or not record.kind is String or record.kind.is_empty() or not record.material is String or record.material.is_empty() \
			or not record.semantic is String or record.semantic.is_empty() or not record.physicalIntent is String:
		return false
	if not record.position is Vector3 or not record.rotation is Vector3 or not record.size is Vector3 \
			or not record.position.is_finite() or not record.rotation.is_finite() or not record.size.is_finite() \
			or record.size.x <= 0.0 or record.size.y <= 0.0 or record.size.z <= 0.0 \
			or typeof(record.collision) != TYPE_BOOL or not record.recipe is Dictionary:
		return false
	return _snapshot_value_is_bounded(record.recipe, 0, work)


static func _snapshot_value_is_bounded(value: Variant, depth: int, work: Dictionary) -> bool:
	work.nodes = int(work.get("nodes", 0)) + 1
	if work.nodes > 1000000 or depth > 32:
		work["reason"] = "node_limit" if work.nodes > 1000000 else "depth_limit"
		return false
	match typeof(value):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			work["reason"] = "unsafe_type_%d" % typeof(value)
			return false
		TYPE_VECTOR2:
			if not (value as Vector2).is_finite(): work["reason"] = "nonfinite_vector2"; return false
		TYPE_VECTOR3:
			if not (value as Vector3).is_finite(): work["reason"] = "nonfinite_vector3"; return false
		TYPE_QUATERNION:
			if not (value as Quaternion).is_finite(): work["reason"] = "nonfinite_quaternion"; return false
		TYPE_COLOR:
			var color: Color = value
			if not (is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and is_finite(color.a)): work["reason"] = "nonfinite_color"; return false
		TYPE_RECT2:
			var rect: Rect2 = value
			if not rect.position.is_finite() or not rect.size.is_finite(): work["reason"] = "nonfinite_rect2"; return false
		TYPE_AABB:
			var bounds: AABB = value
			if not bounds.position.is_finite() or not bounds.size.is_finite(): work["reason"] = "nonfinite_aabb"; return false
		TYPE_TRANSFORM3D:
			var transform: Transform3D = value
			if not transform.origin.is_finite() or not transform.basis.x.is_finite() or not transform.basis.y.is_finite() or not transform.basis.z.is_finite(): work["reason"] = "nonfinite_transform3d"; return false
		TYPE_ARRAY:
			for child: Variant in value:
				if not _snapshot_value_is_bounded(child, depth + 1, work): return false
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not _snapshot_value_is_bounded(key, depth + 1, work) or not _snapshot_value_is_bounded(value[key], depth + 1, work): return false
	return true


static func add_roof_frames(blueprint) -> Dictionary:
	# Preserve source order. Roof pairing is a grammar obligation, not a
	# seed-specific repair; every declared urban roof must belong to one pair.
	if blueprint == null:
		return {"ready": false, "reason": "missing_blueprint"}
	var members: Dictionary = {}
	var prefixes: Array[String] = []
	for part in blueprint.parts:
		if part.semantic != "citadel_urban_roof":
			continue
		var part_id := String(part.id)
		if members.has(part_id):
			return {"ready": false, "reason": "duplicate_roof_id", "partId": part_id}
		members[part_id] = true
		if part_id.ends_with("_roof_left"):
			prefixes.append(part_id.trim_suffix("_roof_left"))
		elif not part_id.ends_with("_roof_right"):
			return {"ready": false, "reason": "unrecognized_roof_pair", "partId": part_id}
	if prefixes.is_empty() or members.size() != prefixes.size() * 2:
		return {"ready": false, "reason": "incomplete_roof_collection"}
	for prefix in prefixes:
		if not members.has(prefix + "_roof_right"):
			return {"ready": false, "reason": "missing_roof_partner", "prefix": prefix}
	var added_ids: Array = []
	for prefix in prefixes:
		var outcome: Dictionary = GablePurlinFrameBuilderScript.add_frame(blueprint,
			[prefix + "_roof_left", prefix + "_roof_right"],
			[prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"],
			prefix + "_purlin_frame")
		if not bool(outcome.get("ready", false)):
			return {"ready": false, "reason": "roof_frame_setup_failed", "prefix": prefix, "detail": outcome}
		added_ids.append_array(outcome.partIds)
	return {"ready": true, "frameCount": prefixes.size(), "partIds": added_ids}


static func build_tree_placement_records(sites: Array, seed: int, continuation: Callable = Callable()) -> Array:
	if not _emit_compose_diagnostic(continuation, "landscape_tree_records_started"): return []
	var catalog = BiomeEnvironmentCatalogScript.new()
	if not catalog.setup():
		return sites.duplicate(true)
	var profile = catalog.profile_for_biome("town")
	if profile == null:
		return sites.duplicate(true)
	var request_builder = TreeRuntimeRequestBuilderScript.new()
	var tree_service = TreeSpawnServiceScript.new()
	var records: Array = []
	for index in range(sites.size()):
		if not _emit_compose_diagnostic(continuation, "landscape_tree_recipe"): return []
		var position: Vector3 = sites[index] as Vector3
		var tree_id := "citadel-urban-tree-%d:%d,%d:%02d" % [seed, roundi(position.x), roundi(position.z), index]
		var rotation_y := float(index) * 1.17
		var request: Dictionary = request_builder.build(profile, "town", tree_id, 6.2 + float(index % 3) * 0.9, Vector2i(roundi(position.x), roundi(position.z)), str(seed))
		request["treeId"] = tree_id
		request["worldSeed"] = str(seed)
		request["biome"] = "town"
		request["presentation"] = "runtime"
		request["worldPosition"] = position
		request["worldRotationY"] = rotation_y
		var tree_recipe: Dictionary = tree_service.build_recipe(request)
		var interaction_facts: Dictionary = tree_recipe.get("interactionFacts", {}) as Dictionary
		records.append({
			"id": tree_id,
			"position": position,
			"rotationY": rotation_y,
			"canopyRadius": float(tree_recipe.get("canopyRadius", 3.4)),
			"rootButtressFootprints": interaction_facts.get("rootButtresses", []) as Array,
			"treeRequest": request
		})
	if not _emit_compose_diagnostic(continuation, "landscape_tree_records_completed"): return []
	return records


static func retain_home_clear_tree_records(blueprint, records: Array) -> Array:
	# Candidate selection uses a cheap trunk-scale index.  Acceptance uses the
	# generated recipe's actual canopy radius, so a large seeded tree cannot be
	# retained through a house envelope or another retained canopy.
	var homes: Array = blueprint.recipe.get("citadelUrbanHomes", []) as Array
	var retained: Array = []
	for record_value in records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value as Dictionary
		var position: Vector3 = record.get("position", Vector3.INF) as Vector3
		var radius := float(record.get("canopyRadius", 0.0))
		if not position.is_finite() or radius <= 0.0:
			continue
		var home_clear := true
		for home_value in homes:
			if not home_value is Dictionary:
				continue
			var home: Dictionary = home_value as Dictionary
			var origin: Vector3 = home.get("origin", Vector3.INF) as Vector3
			var width := float(home.get("interiorWidth", 0.0))
			var depth := float(home.get("interiorDepth", 0.0))
			if not origin.is_finite() or width <= 0.0 or depth <= 0.0:
				home_clear = false
				break
			var closest_x := clampf(position.x, origin.x - width * 0.5, origin.x + width * 0.5)
			var closest_z := clampf(position.z, origin.z - depth * 0.5, origin.z + depth * 0.5)
			if Vector2(position.x - closest_x, position.z - closest_z).length() < radius + 0.40:
				home_clear = false
				break
		if not home_clear:
			continue
		var separated := true
		for retained_value in retained:
			var other: Dictionary = retained_value as Dictionary
			var other_position: Vector3 = other.get("position", Vector3.INF) as Vector3
			var other_radius := float(other.get("canopyRadius", 0.0))
			if Vector2(position.x - other_position.x, position.z - other_position.z).length() < radius + other_radius + 0.80:
				separated = false
				break
		if separated:
			retained.append(record)
	return retained


static func add_seeded_room_life(blueprint, seed: int, variation: float) -> void:
	for room_value in blueprint.rooms:
		if not room_value is Dictionary:
			continue
		var room: Dictionary = room_value as Dictionary
		var room_id := String(room.get("id", "")).strip_edges()
		var role := String(room.get("role", "")).strip_edges()
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		if room_id.is_empty() or bounds.size.x < 1.8 or bounds.size.z < 1.8 or bounds.size.y < 1.5 or role == "interior_passage":
			continue
		var phase := stable_unit(seed, "interior:%s" % room_id)
		var floor_y := bounds.position.y + 0.04
		var inset_x := minf(0.72, bounds.size.x * 0.20)
		var inset_z := minf(0.72, bounds.size.z * 0.20)
		var furnishing_x := lerpf(bounds.position.x + inset_x, bounds.end.x - inset_x, phase)
		var furnishing_z := lerpf(bounds.position.z + inset_z, bounds.end.z - inset_z, fposmod(phase * 2.71, 1.0))
		var opposite_x := lerpf(bounds.end.x - inset_x, bounds.position.x + inset_x, phase)
		var opposite_z := lerpf(bounds.end.z - inset_z, bounds.position.z + inset_z, fposmod(phase * 3.83, 1.0))
		var prefix := "interior_%s" % room_id
		add_part(blueprint, "%s_barrel" % prefix, "barrel", "timber_board", Vector3(furnishing_x, floor_y + 0.44, furnishing_z), Vector3(0.70, 0.88, 0.70), {"collision": false, "variation": variation + phase * 0.025, "semantic": "interior_storage", "roomId": room_id, "roomRole": role})
		add_part(blueprint, "%s_crate" % prefix, "crate", "timber_board", Vector3(opposite_x, floor_y + 0.32, opposite_z), Vector3(0.74, 0.64, 0.68), {"collision": false, "variation": variation - phase * 0.018, "semantic": "interior_storage", "roomId": room_id, "roomRole": role})
		add_part(blueprint, "%s_sack" % prefix, "sack", "linen", Vector3(furnishing_x + (opposite_x - furnishing_x) * 0.24, floor_y + 0.28, furnishing_z + (opposite_z - furnishing_z) * 0.24), Vector3(0.58, 0.56, 0.52), {"collision": false, "variation": variation + 0.012, "semantic": "interior_supplies", "roomId": room_id, "roomRole": role})
		add_part(blueprint, "%s_pottery" % prefix, "pottery", "ceramic_glaze", Vector3(opposite_x + (furnishing_x - opposite_x) * 0.18, floor_y + 0.24, opposite_z + (furnishing_z - opposite_z) * 0.18), Vector3(0.32, 0.44, 0.32), {"collision": false, "variation": variation - 0.014, "semantic": "interior_tableware", "roomId": room_id, "roomRole": role})
		var light_position := bounds.get_center() + Vector3((phase - 0.5) * minf(0.72, bounds.size.x * 0.16), minf(2.20, bounds.size.y * 0.58), (fposmod(phase * 5.19, 1.0) - 0.5) * minf(0.72, bounds.size.z * 0.16))
		add_part(blueprint, "%s_lamp" % prefix, "decor", "candle_flame", light_position, Vector3(0.15, 0.25, 0.15), {"collision": false, "variation": variation, "semantic": "interior_practical_light", "roomId": room_id, "roomRole": role, "practicalLight": true, "lightEnergy": 1.38 + phase * 0.48, "lightRange": 4.4 + phase * 1.4})


static func select_open_paving_tree_sites(blueprint, seed: int, continuation: Callable = Callable(), selection_status: Dictionary = {}) -> Array[Vector3]:
	if not _emit_compose_diagnostic(continuation, "landscape_tree_selection_started"): return []
	var source_bytes := var_to_bytes(blueprint.snapshot())
	var index = _tree_site_index(blueprint)
	var candidates: Array[Dictionary] = []
	for paving_part: Dictionary in index.paving:
		var half: Vector3 = paving_part.size * 0.5
		for factor_x in [-0.78, -0.52, -0.26, 0.0, 0.26, 0.52, 0.78]:
			for factor_z in [-0.78, -0.52, -0.26, 0.0, 0.26, 0.52, 0.78]:
				if not _emit_compose_diagnostic(continuation, "landscape_tree_candidate"): return []
				var position: Vector3 = paving_part.position + Vector3(factor_x * maxf(0.40, half.x - 1.10), half.y + 0.05, factor_z * maxf(0.40, half.z - 1.10))
				if not index.site_open(position) or not index.clear_run(position):
					continue
				var key := "%d:%s:%d,%d" % [seed, String(paving_part.id), int(round(factor_x * 100.0)), int(round(factor_z * 100.0))]
				candidates.append({"position": position, "score": stable_unit(seed, "tree-open-paving:%s" % key), "id": key})
	if not _emit_compose_diagnostic(continuation, "landscape_tree_sort_started"): return []
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a.get("score", 0.0)), float(b.get("score", 0.0))):
			return String(a.get("id", "")) < String(b.get("id", ""))
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)
	var result: Array[Vector3] = []
	for candidate in candidates:
		if not _emit_compose_diagnostic(continuation, "landscape_tree_spacing"): return []
		var position: Vector3 = (candidate as Dictionary).get("position", Vector3.ZERO) as Vector3
		var separated := true
		for existing in result:
			if Vector2(position.x - existing.x, position.z - existing.z).length() < 8.0:
				separated = false
				break
		if separated:
			result.append(position)
		if result.size() >= 4:
			break
	if not _emit_compose_diagnostic(continuation, "landscape_tree_selection_completed"): return []
	if source_bytes!=var_to_bytes(blueprint.snapshot()):
		selection_status["reason"]="tree_selection_source_changed"
		return []
	return result

static func _tree_site_index(blueprint):
	var index = preload("res://scripts/buildings/CitadelTreeSiteIndex.gd").new()
	for part in blueprint.parts:
		if part==null: continue
		if is_primary_tree_paving(part): index.paving.append({"id":String(part.id),"position":part.position,"size":part.size})
		var bounds := AABB(part.position-part.size*0.5,part.size)
		if _tree_site_blocker(part): index.add_bounds(index.sites,bounds)
		if _tree_sample_blocker(part): index.add_bounds(index.samples,bounds)
	return index

static func _tree_site_blocker(part) -> bool:
	return part!=null and String(part.material_id) not in ["cobblestone","worn_cobble"] and bool(part.recipe.get("visual",true)) and not part.size.y<0.20

static func _tree_sample_blocker(part) -> bool:
	return part!=null and String(part.kind) not in ["foundation","floor","ground_patch","ramp","stair_tread"] and bool(part.recipe.get("visual",true))


static func is_primary_tree_paving(part) -> bool:
	if part == null or String(part.kind) != "foundation" or String(part.material_id) not in ["cobblestone", "worn_cobble"]:
		return false
	return String(part.semantic) in ["castle_courtyard_paving", "citadel_market_plaza", "citadel_perimeter_alley"]


static func tree_site_is_open(blueprint, position: Vector3) -> bool:
	var site_bounds := AABB(position - Vector3(1.90, 0.05, 1.90), Vector3(3.80, 8.0, 3.80))
	for part in blueprint.parts:
		if not _tree_site_blocker(part):
			continue
		if AABB(part.position - part.size * 0.5, part.size).intersects(site_bounds):
			return false
	return true


static func tree_site_has_clear_paving_run(blueprint, position: Vector3) -> bool:
	for direction in [Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 0.0, 1.0)]:
		var shaded := primary_paving_surface_at(blueprint, position + direction * 2.1)
		var open := primary_paving_surface_at(blueprint, position + direction * 6.2)
		if shaded == Vector3.INF or open == Vector3.INF:
			continue
		if tree_paving_sample_is_open(blueprint, shaded) and tree_paving_sample_is_open(blueprint, open):
			return true
	return false


static func primary_paving_surface_at(blueprint, point: Vector3) -> Vector3:
	for part in blueprint.parts:
		if not is_primary_tree_paving(part):
			continue
		var half: Vector3 = part.size * 0.5
		if point.x < part.position.x - half.x or point.x > part.position.x + half.x or point.z < part.position.z - half.z or point.z > part.position.z + half.z:
			continue
		return Vector3(point.x, part.position.y + half.y + 0.04, point.z)
	return Vector3.INF


static func tree_paving_sample_is_open(blueprint, point: Vector3) -> bool:
	var sample_bounds := AABB(point - Vector3(0.72, 0.02, 0.72), Vector3(1.44, 2.40, 1.44))
	for part in blueprint.parts:
		if not _tree_sample_blocker(part):
			continue
		if AABB(part.position - part.size * 0.5, part.size).intersects(sample_bounds):
			return false
	return true


static func add_perimeter_neighborhoods(blueprint, grammar: Dictionary, keep_front_z: float, base_y: float, variation: float, continuation: Callable = Callable()) -> bool:
	var courtyard_width := float(grammar.get("courtyardWidth", 104.0))
	var courtyard_depth := float(grammar.get("courtyardDepth", 96.0))
	var side_x: float = courtyard_width * 0.5 - 7.3
	var start_z := keep_front_z + 7.0
	var end_z := courtyard_depth * 0.5 - 9.0
	var row_count := 3
	var materials: Array[String] = ["painted_brick_ochre", "painted_brick_sage", "painted_brick_rose", "painted_brick_cream"]
	for side in [-1.0, 1.0]:
		for row_index in range(row_count):
			if not _emit_compose_diagnostic(continuation, "landscape_perimeter_house"): return false
			var ratio := float(row_index) / float(maxi(1, row_count - 1))
			var center_z: float = lerpf(start_z, end_z, ratio) + side * float(row_index % 2) * 0.55
			var width: float = 6.5 + float((row_index + int(side) + 4) % 3) * 0.42
			var depth: float = 8.2 + float((row_index * 2 + int(side) + 6) % 3) * 0.48
			var height: float = 6.4 + float((row_index + (1 if side > 0.0 else 0)) % 2) * 2.9
			var material := materials[(row_index + (2 if side > 0.0 else 0)) % materials.size()]
			var alley_x: float = side * (side_x - width * 0.5 - 1.15)
			var local_base_y := perimeter_site_support_top(blueprint, Vector3(alley_x, base_y, center_z), base_y)
			if not add_street_house(blueprint, "urban_perimeter_%s_%02d" % ["east" if side > 0.0 else "west", row_index], Vector3(side * side_x, 0.0, center_z), width, depth, height, -side, local_base_y, material, variation + side * 0.018 + float(row_index) * 0.011): return false
			var alley_id := "urban_perimeter_alley_%d_%02d" % [int(side), row_index]
			add_part(blueprint, alley_id, "foundation", "worn_cobble", Vector3(alley_x, local_base_y + 0.16, center_z), Vector3(2.1, 0.10, depth * 0.82), {"collision": true, "navigationRole": "walkable_support", "variation": variation - 0.04 + float(row_index) * 0.008, "semantic": "citadel_perimeter_alley", "pavingFamily": "lane_cobbles", "pavingRegion": alley_id, "pavingHeading": "z"})
	return true


static func perimeter_site_support_top(blueprint, site: Vector3, fallback_y: float) -> float:
	var result := fallback_y
	for part in blueprint.parts:
		if part == null or not bool(part.collision_enabled) or String(part.kind) != "foundation":
			continue
		var id := String(part.id)
		if not id.begins_with("castle_terrace_block_") and not id.begins_with("castle_compound_foundation_segment_"):
			continue
		var inverse := Transform3D(Basis.from_euler(part.rotation), part.position).affine_inverse()
		var local := inverse * site
		var half: Vector3 = part.size * 0.5
		if absf(local.x) > half.x or absf(local.z) > half.z:
			continue
		var basis := Basis.from_euler(part.rotation)
		var top_extent: float = (absf(basis.x.y) * part.size.x + absf(basis.y.y) * part.size.y + absf(basis.z.y) * part.size.z) * 0.5
		result = maxf(result, part.position.y + top_extent)
	return result


static func street_rear_boundary(source, keep_front_z: float) -> float:
	# Retained keep geometry includes the entrance landing and projecting towers,
	# not just the hall's nominal front. Reserve it before any urban row exists.
	if not source is CivicInfill.Blueprint or not is_finite(keep_front_z): return NAN
	var rear := keep_front_z-5.0
	var found_keep := false
	for part in source.parts:
		if part==null or not part.collision_enabled or not String(part.id).begins_with("castle_keep_"): continue
		var bounds: AABB=source.transformed_part_bounds(part)
		if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x<=0.0 or bounds.size.y<=0.0 or bounds.size.z<=0.0: return NAN
		found_keep=true
		rear=minf(rear,bounds.position.z-CivicInfill.CLEARANCE)
	return rear if found_keep else NAN


static func sample_urban_layout(seed: int, grammar: Dictionary, front_z: float, keep_front_z: float, foundation_height: float, street_rear_z: float = INF) -> Dictionary:
	var market_lane_x := lerpf(17.5, 25.0, stable_unit(seed, "market-lane"))
	var market_terrace_rise := lerpf(1.45, 2.15, stable_unit(seed, "market-rise"))
	var lane_centers: Array[float] = [
		lerpf(-1.4, 1.1, stable_unit(seed, "lane-0")),
		lerpf(0.6, 3.4, stable_unit(seed, "lane-1")),
		market_lane_x,
		lerpf(8.5, 15.0, stable_unit(seed, "lane-3"))
	]
	var row_center_phases: Array[float] = []
	var row_width_biases: Array[float] = []
	var row_storey_bonuses: Array[int] = []
	var nominal_phases := [0.72, 1.68, 2.62, 3.48]
	for row_index in range(4):
		row_center_phases.append(float(nominal_phases[row_index]) + lerpf(-0.075, 0.075, stable_unit(seed, "row-phase-%d" % row_index)))
		row_width_biases.append(lerpf(-0.48, 0.62, stable_unit(seed, "row-width-%d" % row_index)))
		row_storey_bonuses.append(1 if stable_unit(seed, "row-storey-%d" % row_index) > 0.72 else 0)
	var stall_specs := [
		{"side": -1.0, "depth": -1.0, "base": Vector3(-5.5, 0.0, -2.35)},
		{"side": 1.0, "depth": 1.0, "base": Vector3(5.2, 0.0, 1.75)},
		{"side": -1.0, "depth": 1.0, "base": Vector3(-2.0, 0.0, 2.55)}
	]
	var market_stalls: Array[Dictionary] = []
	for stall_index in range(stall_specs.size()):
		var stall: Dictionary = stall_specs[stall_index] as Dictionary
		var base_offset: Vector3 = stall.get("base", Vector3.ZERO) as Vector3
		var offset := base_offset + Vector3(lerpf(-0.58, 0.58, stable_unit(seed, "stall-x-%d" % stall_index)), 0.0, lerpf(-0.42, 0.42, stable_unit(seed, "stall-z-%d" % stall_index)))
		market_stalls.append({"offset": offset, "side": stall.get("side", 1.0), "depth": stall.get("depth", 1.0), "variation": lerpf(-0.035, 0.035, stable_unit(seed, "stall-material-%d" % stall_index))})
	# Reserve the existing keep approach without expanding a short courtyard.
	var rear_z := minf(keep_front_z-5.0,street_rear_z)
	var usable_depth := rear_z-front_z
	var market_z := front_z + usable_depth * 0.655
	var market_tree_y := foundation_height + market_terrace_rise + 0.345
	var courtyard_width := float(grammar.get("courtyardWidth", 104.0))
	var perimeter_x := maxf(33.0, courtyard_width * 0.5 - 8.0)
	var tree_placements: Array = market_edge_tree_sites(seed, market_lane_x, market_z, market_tree_y, market_stalls)
	tree_placements.append_array([
		Vector3(-perimeter_x + lerpf(-1.2, 1.2, stable_unit(seed, "tree-west-x")), foundation_height + 0.145, keep_front_z + lerpf(12.0, 18.5, stable_unit(seed, "tree-west-z"))),
		Vector3(perimeter_x - lerpf(0.5, 3.5, stable_unit(seed, "tree-rear-x")), foundation_height + 0.145, keep_front_z + lerpf(21.0, 29.0, stable_unit(seed, "tree-rear-z")))
	])
	return {
		"schemaVersion": 2,
		"layoutSeed": seed,
		"populationEvidence": "not_included_in_architecture_material_fixture",
		"referenceIntent": "dense_fortified_northern_city",
		"marketLaneX": market_lane_x,
		"marketTerraceRise": market_terrace_rise,
		"laneCenters": lane_centers,
		"rowCenterPhases": row_center_phases,
		"rowWidthBiases": row_width_biases,
		"rowStoreyBonuses": row_storey_bonuses,
		"marketStalls": market_stalls,
		"treePlacements": tree_placements,
		"frontZ": front_z,
		"keepFrontZ": keep_front_z,
		"streetRearZ": rear_z,
		"captureRoute": ["outer_approach", "gate_threshold", "inner_lane", "market_release", "civic_overview"]
	}


static func market_edge_tree_sites(seed: int, lane_x: float, market_z: float, surface_y: float, market_stalls: Array) -> Array[Vector3]:
	var candidates: Array[Dictionary] = []
	for side in [-1.0, 1.0]:
		for depth_index in [-1.0, 1.0]:
			var position := Vector3(lane_x + side * lerpf(6.85, 7.65, stable_unit(seed, "tree-edge-x-%d-%d" % [int(side), int(depth_index)])), surface_y, market_z + depth_index * lerpf(7.40, 10.20, stable_unit(seed, "tree-edge-z-%d-%d" % [int(side), int(depth_index)])))
			var clear := true
			for stall_value in market_stalls:
				var offset: Vector3 = (stall_value as Dictionary).get("offset", Vector3.ZERO) as Vector3
				if Vector2(position.x - lane_x - offset.x, position.z - market_z - offset.z).length() < 4.10:
					clear = false
					break
			if clear:
				candidates.append({"position": position, "score": stable_unit(seed, "tree-edge-score-%d-%d" % [int(side), int(depth_index)])})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("score", 0.0)) > float(b.get("score", 0.0)))
	var result: Array[Vector3] = []
	for candidate in candidates.slice(0, mini(2, candidates.size())):
		result.append((candidate as Dictionary).get("position", Vector3.ZERO) as Vector3)
	return result


static func city_tree_placements(blueprint) -> Array[Vector3]:
	var urban_layout: Dictionary = blueprint.recipe.get("urbanPoc", {}) as Dictionary
	var sampled_placements: Array[Vector3] = []
	for placement_value in urban_layout.get("treePlacements", []):
		if placement_value is Vector3:
			sampled_placements.append(placement_value as Vector3)
		elif placement_value is Dictionary:
			sampled_placements.append((placement_value as Dictionary).get("position", Vector3.ZERO) as Vector3)
	if not sampled_placements.is_empty():
		return sampled_placements
	var grammar: Dictionary = blueprint.recipe.get("castleGrammar", {}) as Dictionary
	var foundation_height := float(blueprint.recipe.get("foundationHeight", 0.62))
	var courtyard_depth := float(grammar.get("courtyardDepth", 84.0))
	var keep_depth := float(grammar.get("keepDepth", 28.0))
	var keep_center_z := courtyard_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14))
	var front_z := -courtyard_depth * 0.5
	var keep_front_z := keep_center_z - keep_depth * 0.5
	return [
		Vector3(-7.0, foundation_height + 2.0, keep_front_z - 10.0),
		Vector3(48.0, foundation_height + 0.145, keep_front_z - 7.0),
		Vector3(-44.0, foundation_height + 0.145, keep_front_z + 15.5),
		Vector3(45.0, foundation_height + 0.145, keep_front_z + 25.0)
	]


static func street_row_geometry(front_z: float, keep_front_z: float, urban_layout: Dictionary) -> Dictionary:
	if not is_finite(front_z) or not is_finite(keep_front_z) or keep_front_z <= front_z:
		return {"ready": false, "reason": "invalid_street_depth_bounds"}
	var center_phases_value: Variant = urban_layout.get("rowCenterPhases")
	if not center_phases_value is Array or (center_phases_value as Array).size() != 4:
		return {"ready": false, "reason": "invalid_row_center_phases"}
	var center_phases: Array = center_phases_value as Array
	# House minimum dimensions are enforced below, not by extending into the keep.
	var rear_value: Variant=urban_layout.get("streetRearZ",keep_front_z-5.0)
	if not (rear_value is int or rear_value is float) or not is_finite(float(rear_value)):
		return {"ready":false,"reason":"invalid_street_rear_boundary"}
	var usable_depth := minf(keep_front_z-5.0,float(rear_value))-front_z
	var segment_depth := usable_depth / 4.0
	if not is_finite(usable_depth) or not is_finite(segment_depth) or segment_depth <= 0.0:
		return {"ready": false, "reason": "invalid_street_segment_depth"}
	var centers: Array[float] = []
	var row_depths: Array[float] = []
	for row_index in range(center_phases.size()):
		var center_phase_value: Variant = center_phases[row_index]
		if not (center_phase_value is int or center_phase_value is float) or not is_finite(float(center_phase_value)):
			return {"ready": false, "reason": "invalid_row_center_phase", "rowIndex": row_index}
		var center_z := front_z + segment_depth * float(center_phase_value)
		var row_depth := segment_depth * (0.82 if row_index == 1 else 0.90)
		if not is_finite(center_z) or not is_finite(row_depth) or row_depth <= 0.0:
			return {"ready": false, "reason": "invalid_street_row_geometry", "rowIndex": row_index}
		centers.append(center_z)
		row_depths.append(row_depth)
	# Jitter changes centre separation, not the size of the houses. Bind their
	# depths to the represented structural footprint before any house, aperture,
	# room, furniture or civic-edge consumer is generated. Roof overhangs are not
	# solid house envelopes and do not force the dense roofline apart.
	var lanes: Variant = urban_layout.get("laneCenters", DEFAULT_LANE_CENTERS)
	var biases: Variant = urban_layout.get("rowWidthBiases", DEFAULT_ROW_WIDTH_BIASES)
	var bonuses: Variant = urban_layout.get("rowStoreyBonuses", [0,0,0,0])
	if not lanes is Array or lanes.size() != 4 or not biases is Array or biases.size() != 4 or not bonuses is Array or bonuses.size()!=4:
		return {"ready": false, "reason": "invalid_row_packing_inputs"}
	var rows: Array = []
	for index in range(centers.size()):
		if not bonuses[index] is int or bonuses[index]<0 or bonuses[index]>4:
			return {"ready": false, "reason": "invalid_row_storey_bonus", "rowIndex": index}
		for value in [lanes[index], biases[index]]:
			if not (value is int or value is float) or not is_finite(float(value)):
				return {"ready": false, "reason": "invalid_row_packing_number", "rowIndex": index}
		var envelopes: Array = []
		var minimum_depth := 0.0
		for side in [-1, 1]:
			minimum_depth=maxf(minimum_depth,StreetOpeningLayout.minimum_depth(_street_row_house_height(index,side,bonuses[index])))
			var width := _street_row_house_width(index, side, float(biases[index]))
			if width <= STREET_ROOM_INSET * 2.0:
				return {"ready": false, "reason": "invalid_row_house_width", "rowIndex": index}
			var center_x := _street_row_house_x(index, side, float(lanes[index]), width)
			envelopes.append_array(_street_house_packing_sections(center_x, width, float(-side)))
		rows.append({"id": str(index), "centerZ": centers[index], "depth": row_depths[index],
			"minimumDepth": minimum_depth, "envelopes": envelopes})
	var packing := RowDepthPacking.fit(rows)
	if not packing.get("ready", false):
		return {"ready": false, "reason": "street_row_packing_failed", "detail": packing}
	for index in range(row_depths.size()): row_depths[index] = float(packing.rowDepths[str(index)])
	return {"ready": true, "usableDepth": usable_depth, "segmentDepth": segment_depth, "centers": centers, "rowDepths": row_depths,
		"structuralPacking": packing}


static func _street_row_house_height(index: int, side: int, bonus: int) -> float:
	return 3.1 * float(2 + ((index + (1 if side > 0 else 0)) % 2) + bonus)

static func _street_row_house_width(index: int, side: int, bias: float) -> float:
	return 7.4 + float((index + side + 5) % 3) * 0.9 + bias


static func _street_row_house_x(index: int, side: int, lane_x: float, width: float) -> float:
	var lane_width := 5.8 if index != 2 else 16.0
	return lane_x + float(side) * (lane_width * 0.5 + width * 0.5)


static func _street_house_packing_sections(center_x: float, width: float, street_side: float) -> Array:
	# Match the stored Vector3 construction used by add_street_house and
	# add_recessed_facade_mass. These are conservative XZ structural sections,
	# not renderer bounds or a new collision authority. Foundations overhang in
	# Z; shell walls stay within the nominal depth. Existing clear rows are kept.
	var stored_center := Vector3(center_x, 0.0, 0.0).x
	var upper_width := width + STREET_UPPER_EXTRA
	var upper_center := stored_center + street_side * STREET_UPPER_SHIFT
	var thickness := minf(0.30, minf(0.72, upper_width * 0.16) * 0.48)
	var result: Array = []
	for section in [
		[stored_center, width + STREET_FOUNDATION_EXTRA, STREET_FOUNDATION_EXTRA * 0.5, 0.0],
		[upper_center, maxf(0.42, upper_width - thickness * 2.0), 0.0, thickness],
		[upper_center - street_side * (upper_width * 0.5 - thickness * 0.5), thickness, 0.0, 0.0],
		[upper_center + street_side * (upper_width * 0.5 - thickness * 0.5), thickness, 0.0, 0.0]]:
		var represented := Vector2(float(section[0]), float(section[1]))
		result.append({"minimumX": float(represented.x) - float(represented.y) * 0.5,
			"maximumX": float(represented.x) + float(represented.y) * 0.5, "zOverhang": float(section[2]), "boundaryThickness": float(section[3])})
	return result


static func street_sequence_input(front_z: float, keep_front_z: float, base_y: float, variation: float, urban_layout: Dictionary) -> Dictionary:
	var row_geometry := street_row_geometry(front_z, keep_front_z, urban_layout)
	if not bool(row_geometry.get("ready", false)):
		return row_geometry
	if not is_finite(base_y) or not is_finite(variation):
		return {"ready": false, "reason": "invalid_street_sequence_scalar"}
	var array_specs := [
		{"key": "laneCenters", "default": DEFAULT_LANE_CENTERS, "integer": false},
		{"key": "rowWidthBiases", "default": DEFAULT_ROW_WIDTH_BIASES, "integer": false},
		{"key": "rowStoreyBonuses", "default": [0, 0, 0, 0], "integer": true}
	]
	var normalized_arrays: Dictionary = {}
	for spec_value in array_specs:
		var spec: Dictionary = spec_value as Dictionary
		var key := String(spec.key)
		var value: Variant = urban_layout.get(key, spec.default)
		if not value is Array or (value as Array).size() != 4:
			return {"ready": false, "reason": "invalid_street_sequence_array", "key": key}
		var normalized: Array = []
		for index in range(4):
			var item: Variant = (value as Array)[index]
			if bool(spec.integer):
				if not item is int or int(item) < 0 or int(item) > 4:
					return {"ready": false, "reason": "invalid_street_sequence_integer", "key": key, "index": index}
				normalized.append(int(item))
			else:
				if not (item is int or item is float) or not is_finite(float(item)):
					return {"ready": false, "reason": "invalid_street_sequence_number", "key": key, "index": index}
				normalized.append(float(item))
		normalized_arrays[key] = normalized
	var rise_value: Variant = urban_layout.get("marketTerraceRise", MARKET_TERRACE_RISE)
	if not (rise_value is int or rise_value is float) or not is_finite(float(rise_value)) or float(rise_value) <= 0.0:
		return {"ready": false, "reason": "invalid_market_terrace_rise"}
	var stalls_value: Variant = urban_layout.get("marketStalls", [])
	if not stalls_value is Array:
		return {"ready": false, "reason": "invalid_market_stalls_collection"}
	var source_stalls: Array = stalls_value as Array
	if source_stalls.is_empty():
		source_stalls = [
			{"offset": Vector3(-5.8, 0.0, -2.55), "side": -1.0, "depth": -1.0, "variation": -0.018},
			{"offset": Vector3(5.4, 0.0, 1.82), "side": 1.0, "depth": 1.0, "variation": 0.014},
			{"offset": Vector3(-2.2, 0.0, 2.72), "side": -1.0, "depth": 1.0, "variation": 0.031}
		]
	if source_stalls.size() > 16:
		return {"ready": false, "reason": "market_stalls_limit"}
	var normalized_stalls: Array[Dictionary] = []
	var stall_keys: Dictionary = {}
	for stall_index in range(source_stalls.size()):
		var stall_value: Variant = source_stalls[stall_index]
		if not stall_value is Dictionary:
			return {"ready": false, "reason": "invalid_market_stall", "index": stall_index}
		var stall: Dictionary = stall_value as Dictionary
		var offset_value: Variant = stall.get("offset", Vector3.ZERO)
		var side_value: Variant = stall.get("side", 1.0)
		var depth_value: Variant = stall.get("depth", 1.0)
		var stall_variation_value: Variant = stall.get("variation", 0.0)
		if not offset_value is Vector3 or not (offset_value as Vector3).is_finite() \
				or not (side_value is int or side_value is float) or not is_finite(float(side_value)) or not is_equal_approx(absf(float(side_value)), 1.0) \
				or not (depth_value is int or depth_value is float) or not is_finite(float(depth_value)) or not is_equal_approx(absf(float(depth_value)), 1.0) \
				or not (stall_variation_value is int or stall_variation_value is float) or not is_finite(float(stall_variation_value)):
			return {"ready": false, "reason": "invalid_market_stall_geometry", "index": stall_index}
		var stall_key := "%d_%d" % [int(float(side_value)), int(float(depth_value))]
		if stall_keys.has(stall_key):
			return {"ready": false, "reason": "duplicate_market_stall_key", "index": stall_index, "key": stall_key}
		stall_keys[stall_key] = true
		normalized_stalls.append({"offset": offset_value as Vector3, "side": float(side_value), "depth": float(depth_value), "variation": float(stall_variation_value)})
	return {"ready": true, "rowGeometry": row_geometry, "laneCenters": normalized_arrays.laneCenters, "rowWidthBiases": normalized_arrays.rowWidthBiases, "rowStoreyBonuses": normalized_arrays.rowStoreyBonuses, "marketTerraceRise": float(rise_value), "marketStalls": normalized_stalls, "baseY": base_y, "variation": variation}


static func add_street_sequence(blueprint, front_z: float, keep_front_z: float, base_y: float, variation: float, urban_layout: Dictionary) -> Dictionary:
	var prepared := street_sequence_input(front_z, keep_front_z, base_y, variation, urban_layout)
	if not bool(prepared.get("ready", false)):
		return prepared
	var row_geometry: Dictionary = prepared.rowGeometry as Dictionary
	var segment_depth := float(row_geometry.segmentDepth)
	var centers: Array[float] = []
	centers.assign(row_geometry.centers as Array)
	var lane_centers: Array = prepared.laneCenters as Array
	var market_terrace_rise := float(prepared.marketTerraceRise)
	var prepared_base_y := float(prepared.baseY)
	var prepared_variation := float(prepared.variation)
	var elevations: Array[float] = [prepared_base_y, prepared_base_y, prepared_base_y + market_terrace_rise, prepared_base_y + market_terrace_rise * 2.0]
	var row_width_biases: Array = prepared.rowWidthBiases as Array
	var row_storey_bonuses: Array = prepared.rowStoreyBonuses as Array
	var row_depths: Array[float] = []
	row_depths.assign(row_geometry.rowDepths as Array)
	var palette: Array[String] = ["painted_brick_cream", "painted_brick_sage", "painted_brick_rose", "painted_brick_ochre", "painted_brick_azure", "painted_brick_plum"]
	for row_index in range(centers.size()):
		var row_z := float(centers[row_index])
		var lane_x := float(lane_centers[row_index])
		var row_depth := float(row_depths[row_index])
		for side in [-1, 1]:
			var width := _street_row_house_width(row_index, side, float(row_width_biases[row_index]))
			var wall_height := _street_row_house_height(row_index, side, int(row_storey_bonuses[row_index]))
			var center_x := _street_row_house_x(row_index, side, lane_x, width)
			var material := palette[(row_index * 2 + (1 if side > 0 else 0)) % palette.size()]
			if not add_street_house(blueprint, "urban_row_%02d_%s" % [row_index, "right" if side > 0 else "left"], Vector3(center_x, 0.0, row_z), width, row_depth, wall_height, float(-side), elevations[row_index], material, prepared_variation + float(row_index) * 0.012):
				return {"ready": false, "reason": "street_house_opening_layout_failed"}
	var plaza_z := centers[2]
	var market_y := elevations[2]
	# The same row selected for the market owns its opposing house association.
	# Bunting consumers receive these producer IDs, never infer a seed/position.
	blueprint.recipe["citadelMarketHousePair"] = {"leftHouseId":"urban_row_%02d_left"%2,
		"rightHouseId":"urban_row_%02d_right"%2,"plazaPartId":"urban_market_plaza"}
	add_grounded_foundation(blueprint, "urban_market_plaza_retaining", Vector3(lane_centers[2], 0.0, plaza_z), 18.0, segment_depth * 0.82, market_y + 0.24, prepared_variation - 0.05, "citadel_market_plaza_retaining")
	add_part(blueprint, "urban_market_plaza", "foundation", "cobblestone", Vector3(lane_centers[2], market_y + 0.27, plaza_z), Vector3(17.88, 0.10, segment_depth * 0.80), {"navigationRole": "walkable_support", "variation": prepared_variation - 0.04, "semantic": "citadel_market_plaza", "pavingFamily": "civic_setts", "pavingRegion": "citadel_courtyard", "pavingHeading": "x"})
	add_street_climb(blueprint, float(lane_centers[2]), centers[1] + row_depths[1] * 0.48, centers[2] - row_depths[2] * 0.46, prepared_base_y, market_terrace_rise, prepared_variation)
	add_street_climb(blueprint, float(lane_centers[3]), centers[2] + row_depths[2] * 0.48, centers[3] - row_depths[3] * 0.46, market_y, market_terrace_rise, prepared_variation)
	# Raised houses need a raised street as well. Carry the upper flight onto a
	# grounded lane through the destination row, including both entry thresholds.
	var upper_from_z := centers[2] + row_depths[2] * 0.48
	var upper_step_run := maxf(0.48, (centers[3] - row_depths[3] * 0.46 - upper_from_z) / 8.0)
	var upper_lane_start := upper_from_z + upper_step_run * 8.0
	var upper_lane_end := centers[3] + row_depths[3] * 0.5
	add_grounded_foundation(blueprint, "urban_upper_lane", Vector3(float(lane_centers[3]), 0.0, (upper_lane_start + upper_lane_end) * 0.5), 6.4, upper_lane_end - upper_lane_start, elevations[3], prepared_variation, "citadel_upper_lane")
	blueprint.parts.back().recipe.navigationRole = "walkable_support"
	add_market_stalls(blueprint, Vector3(float(lane_centers[2]), market_y + 0.24, plaza_z), prepared_variation, prepared.marketStalls as Array)
	add_terminal_shop_row(blueprint, Vector3(float(lane_centers[2]), market_y + 0.24, plaza_z + segment_depth * 0.34), prepared_variation)
	return {"ready": true, "rowGeometry": row_geometry}


static func add_lane_edge_age(blueprint, prefix: String, lane_x: float, row_z: float, lane_width: float, row_depth: float, surface_y: float, variation: float) -> void:
	return


static func street_house_roof_rise(design_center: Vector3) -> float:
	return 3.2 + fmod(absf(design_center.x + design_center.z), 1.6)


static func add_street_house(blueprint, prefix: String, center: Vector3, width: float, depth: float, wall_height: float, street_side: float, ground_y: float, material: String, variation: float, sampled_roof_rise: float = -1.0) -> bool:
	var opening_layout := StreetOpeningLayout.prepare(depth, wall_height)
	if not opening_layout.ready: return false
	var window_offset: float = opening_layout.windowOffset
	var upper_width := width + STREET_UPPER_EXTRA
	var upper_center_x := center.x + street_side * STREET_UPPER_SHIFT
	var facade_x := upper_center_x + street_side * (upper_width * 0.5 + 0.14)
	# The partitioned wall thickness extends inward from this plane. The older
	# facade_x is a presentation offset, not a mounting surface for upper trim.
	var upper_facade_x := upper_center_x + street_side * upper_width * 0.5
	# Keep the stone/painted-masonry course break out of the first upper-window
	# opening only when the sampled strip is too thin for the ordinary housed
	# bearing recipe. This derives the proportion from shared construction limits:
	# a 7.6 cm sliver is raised to the sill, while a valid 34.6 cm terrace course
	# remains unchanged and may use its ordinary support or party-wall contract.
	var base_height := StreetOpeningLayout.stone_base_height(wall_height)
	var room_id := "%s_interior" % prefix
	var interior_inward := Vector3(-street_side, 0.0, 0.0)
	var room_facade_x := upper_center_x + street_side * (upper_width * 0.5 - 0.34)
	var window_wall_offset := absf(facade_x - room_facade_x)
	add_grounded_foundation(blueprint, "%s_foundation" % prefix, center, width + STREET_FOUNDATION_EXTRA, depth + STREET_FOUNDATION_EXTRA, ground_y, variation - 0.02, "citadel_urban_house_foundation")
	blueprint.rooms.append({
		"id": room_id,
		"bounds": AABB(Vector3(upper_center_x - upper_width * 0.5 + STREET_ROOM_INSET, ground_y + 0.18, center.z - depth * 0.5 + STREET_ROOM_INSET), Vector3(upper_width - STREET_ROOM_INSET * 2.0, wall_height - 0.22, depth - STREET_ROOM_INSET * 2.0)),
		"wallMountInset": 0.30,
		"citadelUrbanRoom": true,
		"accesses": [{"id": "%s_entry" % prefix, "kind": "exterior_door", "position": Vector3(facade_x - street_side * 0.84, ground_y + 0.72, center.z), "size": Vector3(StreetOpeningLayout.ACCESS_WIDTH, 2.18, StreetOpeningLayout.ACCESS_WIDTH)}]
	})
	add_part(blueprint, "%s_interior_floor" % prefix, "floor", "timber_board", Vector3(upper_center_x - street_side * 0.16, ground_y + 0.11, center.z), Vector3(maxf(0.8, upper_width - 0.74), 0.20, maxf(0.8, depth - 0.74)), {"variation": variation - 0.015, "semantic": "citadel_urban_interior_floor", "physicalIntent": "walkable_surface"})
	var floor_count := maxi(2, roundi(wall_height / 3.1))
	var upper_openings: Array[Dictionary] = [{"centerY": ground_y + 1.25, "height": 2.5, "centerZ": center.z, "width": StreetOpeningLayout.DOOR_WIDTH}]
	for floor_index in range(1, floor_count):
		var opening_y := ground_y + float(floor_index) * 2.75
		for window_index in [-1, 1]:
			upper_openings.append({"centerY": opening_y, "height": 1.46, "centerZ": center.z + float(window_index) * window_offset, "width": STREET_WINDOW_WIDTH})
	var stone_mass := add_recessed_facade_mass(blueprint, "%s_stone" % prefix, center.x, center.z, width, depth, ground_y, ground_y + base_height, street_side, "stone_foundation", variation, [{"centerY": ground_y + 1.25, "height": 2.5, "centerZ": center.z, "width": StreetOpeningLayout.DOOR_WIDTH}], "citadel_urban_stone_base")
	if not stone_mass.ready: return false
	var upper_mass := add_recessed_facade_mass(blueprint, "%s_upper" % prefix, upper_center_x, center.z, upper_width, depth, ground_y + base_height, ground_y + wall_height, street_side, material, variation, upper_openings, "citadel_urban_facade")
	if not upper_mass.ready: return false
	for floor_index in range(1, floor_count):
		var floor_y := ground_y + float(floor_index) * 2.75
		for window_index in [-1, 1]:
			var window_z := center.z + float(window_index) * window_offset
			var window_phase := posmod(prefix.hash() + floor_index * 17 + window_index * 31, 5)
			var window_material := "window_warm_glass" if window_phase in [0, 1, 3] else "window_glass"
			add_part(blueprint, "%s_window_%02d_%d" % [prefix, floor_index, window_index], "window", window_material, Vector3(facade_x, floor_y, window_z), Vector3(0.10, 1.18, 0.88), {"collision": false, "variation": variation, "semantic": "citadel_urban_window", "roomId": room_id, "interiorInwardDirection": interior_inward, "interiorWallOffset": window_wall_offset, "interiorProgramMode": "clear_view"})
	for corner_z in [center.z - depth * 0.5 + 0.18, center.z + depth * 0.5 - 0.18]:
		add_part(blueprint, "%s_frame_%d" % [prefix, int(round(corner_z * 10.0))], "beam", "timber_beam", Vector3(upper_facade_x + street_side * 0.05, ground_y + wall_height * 0.58, corner_z), Vector3(0.24, wall_height * 0.82, 0.24), {"collision": false, "variation": variation, "semantic": "citadel_urban_frame"})
	for intermediate_z in [center.z - depth * 0.31, center.z + depth * 0.31]:
		add_part(blueprint, "%s_upper_stud_%d" % [prefix, int(round(intermediate_z * 10.0))], "beam", "timber_beam", Vector3(upper_facade_x + street_side * 0.06, ground_y + base_height + (wall_height - base_height) * 0.55, intermediate_z), Vector3(0.22, (wall_height - base_height) * 0.78, 0.22), {"collision": false, "variation": variation + (intermediate_z - center.z) * 0.004, "semantic": "citadel_urban_structural_frame"})
	for floor_index in range(1, maxi(2, roundi(wall_height / 3.1))):
		add_part(blueprint, "%s_floor_beam_%02d" % [prefix, floor_index], "beam", "timber_beam", Vector3(upper_facade_x + street_side * 0.06, ground_y + float(floor_index) * 3.05, center.z), Vector3(0.24, 0.24, depth + 0.28), {"collision": false, "variation": variation, "semantic": "citadel_urban_frame"})
	for brace_sign in [-1.0, 1.0]:
		add_part(blueprint, "%s_street_brace_%d" % [prefix, int(brace_sign)], "beam", "timber_beam", Vector3(upper_facade_x + street_side * 0.07, ground_y + 2.15, center.z + brace_sign * minf(depth * 0.28, 2.35)), Vector3(0.18, 2.45, 0.18), {"rotation": Vector3(brace_sign * deg_to_rad(31.0), 0.0, 0.0), "collision": false, "variation": variation + brace_sign * 0.018, "semantic": "citadel_urban_brace"})
	for gable_sign in [-1.0, 1.0]:
		var gable_z: float = center.z + gable_sign * (depth * 0.5 + 0.04)
		if wall_height > 5.6:
			for window_sign in [-1.0, 1.0]:
				var gable_window_material := "window_warm_glass" if posmod(prefix.hash() + int(gable_sign * 7.0) + int(window_sign * 13.0), 4) != 0 else "window_glass"
				add_part(blueprint, "%s_gable_recess_%d_%d" % [prefix, int(gable_sign), int(window_sign)], "decor", "window_recess", Vector3(upper_center_x + window_sign * upper_width * 0.22, ground_y + minf(5.05, wall_height * 0.58), gable_z + gable_sign * 0.015), Vector3(0.88, 1.14, 0.10), {"collision": false, "variation": variation, "semantic": "citadel_urban_gable_blind_recess"})
	add_part(blueprint, "%s_door_recess" % prefix, "decor", "window_recess", Vector3(facade_x - street_side * 0.18, ground_y + 1.30, center.z), Vector3(0.12, 2.66, 1.56), {"collision": false, "variation": variation - 0.03, "semantic": "citadel_urban_door_reveal"})
	add_part(blueprint, "%s_door" % prefix, "door", "painted_door", Vector3(facade_x - street_side * 0.10, ground_y + 1.25, center.z), StreetOpeningLayout.DOOR_SIZE, {"rotation": Vector3(0.0, -street_side * PI * 0.5, 0.0), "collision": true, "variation": variation, "semantic": "citadel_urban_door", "roomId": room_id})
	add_part(blueprint, "%s_door_lintel" % prefix, "beam", "timber_beam", Vector3(upper_facade_x + street_side * 0.03, ground_y + 2.64, center.z), Vector3(0.24, 0.22, 1.82), {"collision": false, "variation": variation - 0.015, "semantic": "citadel_urban_door_joinery"})
	add_part(blueprint, "%s_door_hood" % prefix, "decor", "roof_shingle", Vector3(facade_x + street_side * 0.58, ground_y + 2.84, center.z), Vector3(1.28, 0.16, 2.08), {"rotation": Vector3(0.0, 0.0, street_side * deg_to_rad(-12.0)), "collision": false, "variation": variation - 0.025, "semantic": "citadel_urban_door_hood"})
	for bracket_z in [-0.66, 0.66]:
		add_part(blueprint, "%s_door_bracket_%d" % [prefix, int(bracket_z * 100.0)], "beam", "timber_beam", Vector3(facade_x + street_side * 0.31, ground_y + 2.53, center.z + bracket_z), Vector3(0.14, 0.76, 0.14), {"rotation": Vector3(0.0, 0.0, street_side * deg_to_rad(-42.0)), "collision": false, "variation": variation + bracket_z * 0.008, "semantic": "citadel_urban_door_joinery"})
	add_part(blueprint, "%s_door_threshold" % prefix, "foundation", "worn_cobble", Vector3(facade_x + street_side * 0.43, ground_y + 0.07, center.z), Vector3(0.92, 0.14, 1.58), {"collision": false, "variation": variation - 0.04, "semantic": "citadel_threshold_wear"})
	var lantern_z := center.z + minf(depth * 0.22, 1.55)
	add_part(blueprint, "%s_lantern_frame" % prefix, "decor", "ironwork", Vector3(facade_x + street_side * 0.16, ground_y + 2.35, lantern_z), Vector3(0.18, 0.48, 0.34), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_frame"})
	add_part(blueprint, "%s_lantern_flame" % prefix, "decor", "candle_flame", Vector3(facade_x + street_side * 0.20, ground_y + 2.34, lantern_z), Vector3(0.10, 0.20, 0.12), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_flame"})
	var household_phase := float(posmod(prefix.hash(), 997)) / 997.0
	var household_start: int = blueprint.parts.size()
	var clutter_x := facade_x + street_side * 0.22
	var clutter_z := center.z + lerpf(-minf(depth * 0.31, 2.05), minf(depth * 0.25, 1.65), household_phase)
	if household_phase > 0.18:
		add_part(blueprint, "%s_household_barrel" % prefix, "barrel", "timber_board", Vector3(clutter_x, ground_y + 0.45, clutter_z), Vector3(0.66, 0.90, 0.66), {"collision": false, "variation": variation - 0.025, "semantic": "citadel_household_storage"})
	if household_phase < 0.84:
		add_part(blueprint, "%s_household_crate" % prefix, "crate", "timber_board", Vector3(clutter_x, ground_y + 0.31, clutter_z + lerpf(0.58, 0.96, household_phase)), Vector3(0.58, 0.62, 0.58), {"collision": false, "variation": variation + 0.018, "semantic": "citadel_household_storage"})
	var firewood_count := 3 + int(round(household_phase * 5.0))
	# "beam" selects the timber visual; stored fuel is not building joinery.
	for log_index in range(firewood_count):
		var log_row := log_index / 3
		var log_column := log_index % 3
		add_part(blueprint, "%s_firewood_%02d" % [prefix, log_index], "beam", "timber_board", Vector3(clutter_x + street_side * 0.08, ground_y + 0.10 + float(log_row) * 0.14, clutter_z + 0.92 + float(log_column) * 0.23), Vector3(0.13, 0.13, 0.78), {"rotation": Vector3(0.0, float(log_column - 1) * deg_to_rad(4.0), 0.0), "collision": false, "variation": variation + float(log_index) * 0.009, "semantic": "citadel_household_firewood", "physicalIntent": "visual_detail"})
	if household_phase > 0.42:
		var sign_z := center.z + lerpf(-0.72, 0.88, household_phase)
		add_part(blueprint, "%s_sign_arm" % prefix, "beam", "timber_beam", Vector3(facade_x + street_side * 0.38, ground_y + 2.70, sign_z), Vector3(0.12, 0.12, 1.05), {"collision": false, "variation": variation, "semantic": "citadel_household_sign"})
		add_part(blueprint, "%s_hanging_sign" % prefix, "sign", "painted_decor", Vector3(facade_x + street_side * 0.40, ground_y + 2.28, sign_z + 0.42), Vector3(0.12, 0.72, 0.62), {"collision": false, "variation": variation + 0.03, "semantic": "citadel_household_sign"})
	var window_box_z := center.z - window_offset
	add_part(blueprint, "%s_window_box" % prefix, "crate", "timber_board", Vector3(facade_x + street_side * 0.16, ground_y + 1.90, window_box_z), Vector3(0.36, 0.28, 1.14), {"collision": false, "variation": variation + 0.03, "semantic": "citadel_household_window_box"})
	if household_phase > 0.30:
		add_part(blueprint, "%s_household_tool_rack" % prefix, "tool_rack", "ironwork", Vector3(facade_x + street_side * 0.24, ground_y + 1.78, center.z - lerpf(1.65, 2.30, household_phase)), Vector3(0.20, 1.28, 1.12), {"rotation": Vector3(0.0, street_side * PI * 0.5, 0.0), "collision": false, "variation": variation, "semantic": "citadel_household_tools"})
	if household_phase < 0.58:
		add_part(blueprint, "%s_household_basket" % prefix, "basket", "timber_board", Vector3(clutter_x + street_side * 0.08, ground_y + 0.26, clutter_z - 0.62), Vector3(0.54, 0.44, 0.54), {"rotation": Vector3(0.0, household_phase * TAU, 0.0), "collision": false, "variation": variation + 0.02, "semantic": "citadel_household_storage"})
	else:
		add_part(blueprint, "%s_household_sack" % prefix, "sack", "linen", Vector3(clutter_x + street_side * 0.10, ground_y + 0.38, clutter_z - 0.56), Vector3(0.48, 0.72, 0.44), {"rotation": Vector3(0.0, household_phase * TAU, 0.0), "collision": false, "variation": variation - 0.015, "semantic": "citadel_household_storage"})
	if household_phase > 0.60:
		var bay_z := center.z + lerpf(-depth * 0.22, depth * 0.22, household_phase)
		var bay_y := ground_y + minf(wall_height * 0.66, 5.1)
		add_part(blueprint, "%s_projecting_bay_backing" % prefix, "wall", material, Vector3(facade_x + street_side * 0.16, bay_y, bay_z), Vector3(1.18, 2.20, 1.76), {"collision": true, "variation": variation + 0.012, "semantic": "citadel_household_projecting_bay_backing", "physicalIntent": "structural_mass", "requiresStructuralSupport": true})
		add_part(blueprint, "%s_projecting_bay" % prefix, "wall", material, Vector3(facade_x + street_side * 0.42, bay_y, bay_z), Vector3(0.78, 2.05, 2.20), {"collision": false, "variation": variation + 0.025, "semantic": "citadel_household_projecting_bay", "physicalIntent": "facade_attachment", "physicalRequiredAnchorPartIds": ["%s_projecting_bay_backing" % prefix]})
		add_part(blueprint, "%s_projecting_bay_window" % prefix, "window", "window_glass", Vector3(facade_x + street_side * 0.84, bay_y + 0.08, bay_z), Vector3(0.12, 1.22, 1.10), {"collision": false, "variation": variation, "semantic": "citadel_household_projecting_bay", "roomId": room_id, "interiorInwardDirection": interior_inward, "interiorWallOffset": window_wall_offset + 0.84, "interiorProgramMode": "clear_view"})
		add_part(blueprint, "%s_projecting_bay_roof" % prefix, "decor", "roof_shingle", Vector3(facade_x + street_side * 0.44, bay_y + 1.20, bay_z), Vector3(1.12, 0.18, 2.62), {"rotation": Vector3(0.0, 0.0, street_side * deg_to_rad(-8.0)), "collision": false, "variation": variation - 0.02, "semantic": "citadel_household_projecting_bay"})
	# Residential lanes reserve their frontage for entry. Commercial stalls are
	# produced only by the marketplace layout, which owns their clear footprint.
	if household_phase > 0.26 and household_phase < 0.86:
		add_part(blueprint, "%s_masonry_repair" % prefix, "decor", "limewash_repair", Vector3(facade_x + street_side * 0.052, ground_y + 2.05 + household_phase * 1.25, center.z + lerpf(depth * 0.28, -depth * 0.24, household_phase)), Vector3(0.09, 1.05 + household_phase * 0.55, 1.18 + (1.0 - household_phase) * 0.72), {"collision": false, "variation": variation - 0.05, "semantic": "citadel_masonry_repair"})
	add_part(blueprint, "%s_eave" % prefix, "beam", "timber_beam", Vector3(facade_x + street_side * 0.22, ground_y + wall_height, center.z), Vector3(0.34, 0.30, depth + 0.54), {"collision": false, "variation": variation, "semantic": "citadel_urban_eave"})
	var roof_rise := street_house_roof_rise(center) if sampled_roof_rise < 0.0 else sampled_roof_rise
	var slope_length := sqrt(pow(upper_width * 0.5 + 0.70, 2.0) + roof_rise * roof_rise)
	var roof_angle := atan2(roof_rise, upper_width * 0.5 + 0.70)
	var roof_y := ground_y + wall_height + roof_rise * 0.5
	add_part(blueprint, "%s_roof_left" % prefix, "roof", "roof_shingle", Vector3(upper_center_x - upper_width * 0.25, roof_y, center.z), Vector3(slope_length, 0.28, depth + 1.20), {"rotation": Vector3(0.0, 0.0, roof_angle), "variation": variation, "semantic": "citadel_urban_roof"})
	add_part(blueprint, "%s_roof_right" % prefix, "roof", "roof_shingle", Vector3(upper_center_x + upper_width * 0.25, roof_y, center.z), Vector3(slope_length, 0.28, depth + 1.20), {"rotation": Vector3(0.0, 0.0, -roof_angle), "variation": variation, "semantic": "citadel_urban_roof"})
	add_part(blueprint, "%s_chimney" % prefix, "wall", "stone_foundation", Vector3(upper_center_x - upper_width * 0.22, ground_y + wall_height + roof_rise * 0.72, center.z + depth * 0.18), Vector3(0.72, roof_rise + 1.0, 0.72), {"variation": variation, "semantic": "citadel_urban_chimney"})
	# Ground clutter leaves the doorway approach clear even without a collider.
	# Street support is resolved after all lanes and paving have been composed.
	var entry_clearance := AABB(Vector3(facade_x - 1.5, ground_y, center.z - StreetOpeningLayout.ACCESS_WIDTH * 0.5), Vector3(3.0, 2.5, StreetOpeningLayout.ACCESS_WIDTH))
	for part_index in range(blueprint.parts.size() - 1, household_start - 1, -1):
		var detail = blueprint.parts[part_index]
		if not detail.semantic in ["citadel_household_storage", "citadel_household_firewood"]: continue
		var bounds: AABB = blueprint.transformed_part_bounds(detail)
		if bounds.intersects(entry_clearance):
			blueprint.parts.remove_at(part_index)
	var sign_assembly := {}
	if StreetHouseStructuralManifestScript.find_part(blueprint, prefix + "_sign_arm") != null:
		sign_assembly = {"armId": prefix + "_sign_arm", "boardId": prefix + "_hanging_sign"}
	var declaration := StreetHouseStructuralManifestScript.declare(blueprint, {
		"producerPrefix": prefix,
		"roomId": room_id,
		"doorId": prefix + "_door",
		"hoodId": prefix + "_door_hood",
		"threshold": {"id": prefix + "_door_threshold", "foundationId": prefix + "_foundation"},
		"bracketIds": [prefix + "_door_bracket_-66", prefix + "_door_bracket_66"],
		"chimney": {"id": prefix + "_chimney",
			"gableIds": [prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"],
			"upstreamIds": [prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"]},
		"facadeDeclarationKeys": [prefix + "_upper_facade"],
		"signAssembly": sign_assembly
	})
	if not declaration.ready:
		push_error("Citadel street-house declaration failed for %s: %s" % [prefix, String(declaration.get("reason", "unknown"))])
	else:
		var homes: Array = blueprint.recipe.get("citadelUrbanHomes", []) as Array
		homes.append({
			"id": prefix,
			"roomId": room_id,
			"doorId": prefix + "_door",
			"origin": Vector3(upper_center_x, ground_y, center.z),
			"interiorWidth": upper_width - STREET_ROOM_INSET * 2.0,
			"interiorDepth": depth - STREET_ROOM_INSET * 2.0,
			"interiorHeight": wall_height - 0.22,
			"streetSide": street_side
		})
		blueprint.recipe["citadelUrbanHomes"] = homes
	return declaration.ready


static func add_recessed_facade_mass(target, prefix: String, center_x: float, center_z: float, width: float, depth: float, bottom_y: float, top_y: float, street_side: float, material: String, variation: float, openings: Array[Dictionary], semantic: String) -> Dictionary:
	var blueprint = FacadeBlueprint.new(target.id, target.seed, target.style)
	var recess_depth := minf(0.72, width * 0.16)
	var facade_thickness := minf(0.30, recess_depth * 0.48)
	var wall_height := top_y - bottom_y
	var wall_y := (bottom_y + top_y) * 0.5
	var back_x := center_x - street_side * (width * 0.5 - facade_thickness * 0.5)
	add_part(blueprint, "%s_shell_back" % prefix, "wall", material, Vector3(back_x, wall_y, center_z), Vector3(facade_thickness, wall_height, depth), {"variation": variation - 0.008, "semantic": "%s_shell" % semantic})
	var gable_sides: Array[float] = [-1.0, 1.0]
	for gable_side in gable_sides:
		var side_z := center_z + gable_side * (depth * 0.5 - facade_thickness * 0.5)
		add_part(blueprint, "%s_shell_side_%d" % [prefix, int(gable_side)], "wall", material, Vector3(center_x, wall_y, side_z), Vector3(maxf(0.42, width - facade_thickness * 2.0), wall_height, facade_thickness), {"variation": variation + gable_side * 0.008, "semantic": "%s_shell" % semantic})
	var facade_center_x := center_x + street_side * (width * 0.5 - facade_thickness * 0.5)
	var result := add_partitioned_street_facade(blueprint, "%s_facade" % prefix, facade_center_x, center_z, depth, bottom_y, top_y, facade_thickness, material, variation, openings, semantic)
	if not result.ready: return result
	for part in blueprint.parts: target.add_part(part.snapshot())
	var declarations: Dictionary = target.recipe.get("facadeApertures", {}).duplicate()
	declarations.merge(blueprint.recipe.facadeApertures)
	target.recipe["facadeApertures"] = declarations
	return result


static func add_partitioned_street_facade(blueprint, prefix: String, facade_x: float, center_z: float, depth: float, bottom_y: float, top_y: float, thickness: float, material: String, variation: float, openings: Array[Dictionary], semantic: String) -> Dictionary:
	var staged = FacadeBlueprint.new(blueprint.id, blueprint.seed, blueprint.style)
	# Emit opening semantics from the same inputs that partition the wall.
	# Consumers must not rediscover intended windows/doors from floating-point
	# gaps between emitted masonry cells. This adds no geometry or RNG requests.
	var declared_openings: Array = []
	for opening_index in range(openings.size()):
		var opening: Dictionary = openings[opening_index]
		var opening_y := float(opening.get("centerY", (bottom_y + top_y) * 0.5))
		var opening_z := float(opening.get("centerZ", center_z))
		var opening_height := float(opening.get("height", 0.0))
		var opening_width := float(opening.get("width", 1.0))
		declared_openings.append({"id": "%s_opening_%03d" % [prefix, opening_index], "input": opening.duplicate(true),
			"fullVolume": AABB(Vector3(facade_x - thickness * 0.5, opening_y - opening_height * 0.5, opening_z - opening_width * 0.5), Vector3(thickness, opening_height, opening_width))})
	var declaration := {"producerPrefix": prefix, "semantic": semantic,
		"wallDomain": AABB(Vector3(facade_x - thickness * 0.5, bottom_y, center_z - depth * 0.5), Vector3(thickness, top_y - bottom_y, depth)),
		"openings": declared_openings}
	var z_edges: Array[float] = [center_z - depth * 0.5, center_z + depth * 0.5]
	var y_edges: Array[float] = [bottom_y, top_y]
	for opening in openings:
		var opening_center_z := float(opening.get("centerZ", center_z))
		var opening_width := float(opening.get("width", 1.0))
		var opening_center_y := float(opening.get("centerY", (bottom_y + top_y) * 0.5))
		var opening_height := float(opening.get("height", 1.0))
		z_edges.append(clampf(opening_center_z - opening_width * 0.5, z_edges[0], z_edges[1]))
		z_edges.append(clampf(opening_center_z + opening_width * 0.5, z_edges[0], z_edges[1]))
		y_edges.append(clampf(opening_center_y - opening_height * 0.5, bottom_y, top_y))
		y_edges.append(clampf(opening_center_y + opening_height * 0.5, bottom_y, top_y))
	z_edges.sort()
	y_edges.sort()
	var panel_index := 0
	for y_index in range(y_edges.size() - 1):
		var cell_bottom := y_edges[y_index]
		var cell_top := y_edges[y_index + 1]
		if cell_top - cell_bottom < 0.035:
			continue
		for z_index in range(z_edges.size() - 1):
			var cell_near := z_edges[z_index]
			var cell_far := z_edges[z_index + 1]
			if cell_far - cell_near < 0.035:
				continue
			var cell_y := (cell_bottom + cell_top) * 0.5
			var cell_z := (cell_near + cell_far) * 0.5
			var inside_opening := false
			for opening in openings:
				if absf(cell_y - float(opening.get("centerY", cell_y))) < float(opening.get("height", 0.0)) * 0.5 - 0.001 and absf(cell_z - float(opening.get("centerZ", cell_z))) < float(opening.get("width", 0.0)) * 0.5 - 0.001:
					inside_opening = true
					break
			if inside_opening:
				continue
			var bounds_low_y := cell_bottom
			var bounds_high_y := cell_top
			var bounds_low_z := cell_near
			var bounds_high_z := cell_far
			for opening_index in range(openings.size()):
				var opening: Dictionary = openings[opening_index]
				var volume: AABB = declared_openings[opening_index].fullVolume
				var opening_y := float(opening.get("centerY", (bottom_y + top_y) * 0.5))
				var opening_z := float(opening.get("centerZ", center_z))
				var half_height := float(opening.get("height", 0.0)) * 0.5
				var half_width := float(opening.get("width", 1.0)) * 0.5
				# Preserve the existing partition topology, but use the declared
				# stored aperture faces when an adjacent edge rounds outward.
				if cell_top <= opening_y - half_height: bounds_high_y = minf(bounds_high_y, volume.position.y)
				if cell_bottom >= opening_y + half_height: bounds_low_y = maxf(bounds_low_y, volume.end.y)
				if cell_far <= opening_z - half_width: bounds_high_z = minf(bounds_high_z, volume.position.z)
				if cell_near >= opening_z + half_width: bounds_low_z = maxf(bounds_low_z, volume.end.z)
			var vertical := FacadePartition.interval(bounds_low_y, bounds_high_y)
			var lateral := FacadePartition.interval(bounds_low_z, bounds_high_z)
			if not vertical.ready or not lateral.ready:
				return {"ready": false, "reason": "unrepresentable_facade_partition", "panelIndex": panel_index, "vertical": vertical, "lateral": lateral}
			add_part(staged, "%s_%03d" % [prefix, panel_index], "wall", material, Vector3(facade_x, vertical.center, lateral.center), Vector3(thickness, vertical.size, lateral.size), {"variation": variation + float(posmod(panel_index, 5) - 2) * 0.004, "semantic": semantic})
			var part = staged.parts.back()
			var actual: AABB = staged.transformed_part_bounds(part)
			if part.position.y != vertical.center or part.size.y != vertical.size or part.position.z != lateral.center or part.size.z != lateral.size or actual.position.y < bounds_low_y or actual.end.y > bounds_high_y or actual.position.z < bounds_low_z or actual.end.z > bounds_high_z:
				return {"ready": false, "reason": "constructed_facade_partition_changed", "panelIndex": panel_index}
			panel_index += 1
	declaration = FacadeApertureDeclarationScript.seal(declaration, staged.parts)
	for part in staged.parts: blueprint.add_part(part.snapshot())
	var declarations: Dictionary = blueprint.recipe.get("facadeApertures", {}).duplicate()
	declarations[prefix] = declaration
	blueprint.recipe["facadeApertures"] = declarations
	return {"ready": true, "partCount": staged.parts.size()}


static func add_street_climb(blueprint, center_x: float, from_z: float, to_z: float, base_y: float, rise: float, variation: float) -> void:
	var step_count := 8
	var tread_depth := maxf(0.48, (to_z - from_z) / float(step_count))
	for step_index in range(step_count):
		var step_top_y := base_y + rise * float(step_index + 1) / float(step_count)
		add_part(blueprint, "urban_street_climb_%d_%02d" % [int(round(base_y * 100.0)), step_index], "stair_tread", "cobblestone", Vector3(center_x, step_top_y * 0.5, from_z + tread_depth * (float(step_index) + 0.5)), Vector3(6.4, step_top_y, tread_depth + 0.03), {"variation": variation, "semantic": "citadel_street_climb", "pavingFamily": "lane_cobbles", "pavingRegion": "urban_street_climb_%d" % int(round(base_y * 100.0)), "pavingHeading": "z"})


static func add_market_stalls(blueprint, center: Vector3, variation: float, stalls: Array) -> void:
	for stall_value in stalls:
		var stall: Dictionary = stall_value as Dictionary
		add_market_stall_household(blueprint, center + (stall.get("offset", Vector3.ZERO) as Vector3), float(stall.get("side", 1.0)), float(stall.get("depth", 1.0)), variation + float(stall.get("variation", 0.0)))


static func add_terminal_shop_row(blueprint, center: Vector3, variation: float) -> void:
	for bay_index in range(3):
		var bay_x := center.x - 4.6 + float(bay_index) * 4.6
		var bay_key := "terminal_%02d" % bay_index
		var cloth_material := "wool_rust" if bay_index == 0 else ("linen" if bay_index == 1 else "wool_moss")
		add_part(blueprint, "urban_%s_recess" % bay_key, "decor", "window_recess", Vector3(bay_x, center.y + 1.30, center.z + 0.08), Vector3(3.30, 2.35, 0.12), {"collision": false, "variation": variation - 0.04, "semantic": "citadel_terminal_shop_recess"})
		for frame_side in [-1.0, 1.0]:
			add_part(blueprint, "urban_%s_jamb_%d" % [bay_key, int(frame_side)], "beam", "timber_beam", Vector3(bay_x + frame_side * 1.68, center.y + 1.34, center.z - 0.01), Vector3(0.20, 2.68, 0.22), {"collision": false, "variation": variation + frame_side * 0.018, "semantic": "citadel_terminal_shop_frame"})
			add_part(blueprint, "urban_%s_bracket_%d" % [bay_key, int(frame_side)], "beam", "timber_beam", Vector3(bay_x + frame_side * 1.48, center.y + 2.18, center.z - 0.48), Vector3(0.15, 1.18, 0.15), {"rotation": Vector3(frame_side * deg_to_rad(38.0), 0.0, 0.0), "collision": false, "variation": variation + frame_side * 0.018, "semantic": "citadel_terminal_shop_joinery"})
			add_part(blueprint, "urban_%s_shutter_%d" % [bay_key, int(frame_side)], "decor", "timber_board", Vector3(bay_x + frame_side * 1.30, center.y + 1.42, center.z - 0.08), Vector3(0.52, 1.72, 0.10), {"rotation": Vector3(0.0, frame_side * deg_to_rad(8.0), frame_side * deg_to_rad(1.5)), "collision": false, "variation": variation + frame_side * 0.026, "semantic": "citadel_terminal_shop_shutter"})
		add_part(blueprint, "urban_%s_lintel" % bay_key, "beam", "timber_beam", Vector3(bay_x, center.y + 2.62, center.z - 0.02), Vector3(3.58, 0.24, 0.24), {"collision": false, "variation": variation - 0.02, "semantic": "citadel_terminal_shop_frame"})
		for strip_index in range(7):
			var strip_x := bay_x - 1.68 + float(strip_index) * 0.56
			var strip_material := "linen" if strip_index == 1 + bay_index else cloth_material
			add_part(blueprint, "urban_%s_awning_%02d" % [bay_key, strip_index], "decor", strip_material, Vector3(strip_x, center.y + 2.50 + absf(float(strip_index) - 3.0) * 0.026, center.z - 0.72), Vector3(0.54, 0.075, 2.18), {"rotation": Vector3(deg_to_rad(-11.0), 0.0, 0.0), "collision": false, "variation": variation + float(strip_index) * 0.007, "semantic": "citadel_terminal_shop_awning"})
		add_part(blueprint, "urban_%s_counter" % bay_key, "decor", "timber_board", Vector3(bay_x, center.y + 0.76, center.z - 1.34), Vector3(3.28, 0.16, 0.68), {"collision": false, "variation": variation + float(bay_index) * 0.012, "semantic": "citadel_terminal_shop"})
		add_part(blueprint, "urban_%s_wall_shelf" % bay_key, "decor", "timber_board", Vector3(bay_x, center.y + 1.44, center.z + 0.03), Vector3(3.18, 0.14, 0.42), {"collision": false, "variation": variation, "semantic": "citadel_terminal_shop"})
		add_part(blueprint, "urban_%s_tool_rack" % bay_key, "tool_rack", "ironwork", Vector3(bay_x - 0.90, center.y + 1.86, center.z - 0.03), Vector3(1.05, 1.15, 0.18), {"collision": false, "variation": variation, "semantic": "citadel_terminal_shop_tools"})
		add_part(blueprint, "urban_%s_lantern_flame" % bay_key, "decor", "candle_flame", Vector3(bay_x + 1.02, center.y + 1.92, center.z - 0.20), Vector3(0.10, 0.18, 0.10), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_flame"})
		add_part(blueprint, "urban_%s_sign_arm" % bay_key, "beam", "timber_beam", Vector3(bay_x - 1.18 + float(bay_index) * 0.16, center.y + 3.16, center.z - 0.08), Vector3(1.16, 0.12, 0.12), {"collision": false, "variation": variation - 0.02, "semantic": "citadel_terminal_shop_sign"})
		add_part(blueprint, "urban_%s_sign" % bay_key, "sign", "painted_decor", Vector3(bay_x - 0.66 + float(bay_index) * 0.16, center.y + 2.78, center.z - 0.16), Vector3(0.82, 0.72, 0.10), {"rotation": Vector3(0.0, 0.0, deg_to_rad(float(bay_index - 1) * 4.0)), "collision": false, "variation": variation + float(bay_index) * 0.018, "semantic": "citadel_terminal_shop_sign"})
		for goods_index in range(4):
			var goods_x := bay_x - 1.18 + float(goods_index) * 0.76
			var goods_selector := (bay_index * 2 + goods_index) % 4
			var goods_kind := "sack" if goods_selector == 0 else ("basket" if goods_selector in [1, 2] else "pottery")
			var goods_material := "linen" if goods_kind == "sack" else ("timber_board" if goods_kind == "basket" else "ceramic_glaze")
			var goods_y := center.y + (0.31 if goods_kind in ["sack", "basket"] else 1.02)
			var goods_z := center.z - 1.34 + float(goods_index % 2) * 0.48
			var goods_size := Vector3(0.46, 0.72, 0.42) if goods_kind == "sack" else Vector3(0.48, 0.46, 0.48)
			add_part(blueprint, "urban_%s_goods_%02d" % [bay_key, goods_index], goods_kind, goods_material, Vector3(goods_x, goods_y, goods_z), goods_size, {"rotation": Vector3(0.0, deg_to_rad(float(goods_index - 2) * 8.0), 0.0), "collision": false, "variation": variation + float(goods_index) * 0.015, "semantic": "citadel_terminal_shop_goods"})
		add_traffic_wear(blueprint, "urban_%s_wear" % bay_key, Vector3(bay_x, center.y + 0.042, center.z - 2.46), Vector2(2.75, 3.20), 0.0, variation - 0.04, "citadel_terminal_shop_wear")


static func add_civic_service_yard(blueprint, center: Vector3, variation: float) -> void:
	for route_index in range(3):
		var route_z := center.z - 4.0 + float(route_index) * 3.9
		add_traffic_wear(blueprint, "urban_civic_route_wear_%02d" % route_index, Vector3(center.x - 1.0 + float(route_index % 2) * 0.68, center.y + 0.232, route_z), Vector2(12.8, 1.72 + float(route_index % 2) * 0.18), 0.0, variation - 0.05 + float(route_index) * 0.011, "citadel_civic_route_wear")
	var shed_center := center + Vector3(4.2, 0.0, 1.2)
	for post_side in [-1.0, 1.0]:
		var post_id := "urban_civic_shed_post_%d" % int(post_side)
		add_part(blueprint, post_id, "beam", "timber_beam", shed_center + Vector3(post_side * 2.0, 1.30, -0.72), Vector3(0.22, 2.60, 0.22), {"collision": false, "variation": variation + post_side * 0.018, "semantic": "citadel_civic_service_shed"})
		# These small diagonal strips only articulate the shed silhouette. The posts
		# own the real rooted structure; do not classify a non-colliding trim strip
		# as another load-bearing or gameplay-collision authority.
		add_part(blueprint, "urban_civic_shed_brace_%d" % int(post_side), "beam", "timber_beam", shed_center + Vector3(post_side * 1.70, 2.10, -0.72), Vector3(0.15, 1.08, 0.15), {"rotation": Vector3(0.0, 0.0, post_side * deg_to_rad(38.0)), "collision": false, "variation": variation, "semantic": "citadel_civic_service_shed", "physicalIntent": "visual_detail"})
	for roof_strip in range(8):
		add_part(blueprint, "urban_civic_shed_roof_%02d" % roof_strip, "decor", "timber_board", shed_center + Vector3(-2.05 + float(roof_strip) * 0.58, 2.54 + float(roof_strip % 3) * 0.018, 0.0), Vector3(0.56, 0.10, 2.25), {"rotation": Vector3(deg_to_rad(-9.0), 0.0, 0.0), "collision": false, "variation": variation + float(roof_strip) * 0.011, "semantic": "citadel_civic_service_shed"})
	for storage_index in range(5):
		var storage_x := shed_center.x - 1.55 + float(storage_index % 3) * 0.88
		var storage_z := shed_center.z + 0.48 + float(storage_index / 3) * 0.76
		var storage_kind := "barrel" if storage_index in [0, 4] else "crate"
		add_part(blueprint, "urban_civic_storage_%02d" % storage_index, storage_kind, "timber_board", Vector3(storage_x, center.y + (0.46 if storage_kind == "barrel" else 0.34), storage_z), Vector3(0.70, 0.92 if storage_kind == "barrel" else 0.68, 0.70), {"rotation": Vector3(0.0, deg_to_rad(float(storage_index - 2) * 7.0), 0.0), "collision": false, "variation": variation + float(storage_index) * 0.015, "semantic": "citadel_civic_service_storage"})
	# These are loose yard supplies, not the nearby shed's structural frame.
	for log_index in range(12):
		var log_row := log_index / 4
		var log_column := log_index % 4
		add_part(blueprint, "urban_civic_firewood_%02d" % log_index, "beam", "timber_board", center + Vector3(-4.8 + float(log_column) * 0.25, 0.10 + float(log_row) * 0.15, 2.8), Vector3(0.14, 0.14, 0.92), {"rotation": Vector3(0.0, deg_to_rad(float(log_column - 2) * 3.0), 0.0), "collision": false, "variation": variation + float(log_index) * 0.007, "semantic": "citadel_civic_firewood", "physicalIntent": "visual_detail"})


static func _recipe_geometry_bounds(position: Vector3, rotation: Vector3, size: Vector3) -> AABB:
	var basis := Basis.from_euler(rotation)
	var extent := Vector3(
		absf(basis.x.x) * size.x + absf(basis.y.x) * size.y + absf(basis.z.x) * size.z,
		absf(basis.x.y) * size.x + absf(basis.y.y) * size.y + absf(basis.z.y) * size.z,
		absf(basis.x.z) * size.x + absf(basis.y.z) * size.y + absf(basis.z.z) * size.z)
	return AABB(position - extent * 0.5, extent)


static func civic_commons_layout(front_z: float, keep_front_z: float, base_y: float, urban_layout: Dictionary) -> Dictionary:
	var row_geometry := street_row_geometry(front_z, keep_front_z, urban_layout)
	if not bool(row_geometry.get("ready", false)):
		return row_geometry
	if not is_finite(base_y):
		return {"ready": false, "reason": "invalid_civic_commons_base_y"}
	var bench_yaw := deg_to_rad(-11.0)
	var seat_size := Vector3(4.0, 0.28, 0.72)
	var back_height := 1.10
	var back_size := Vector3(seat_size.x, back_height, 0.18)
	var back_local_z := 0.45
	var back_basis := Basis.from_euler(Vector3(0.0, bench_yaw, 0.0))
	var back_center_shift := Vector3(0.0, 0.0, back_local_z).rotated(Vector3.UP, bench_yaw)
	var back_world_half_z := (absf(back_basis.x.z) * back_size.x + absf(back_basis.y.z) * back_size.y + absf(back_basis.z.z) * back_size.z) * 0.5
	var back_north_extent := back_center_shift.z + back_world_half_z
	var row_centers: Array = row_geometry.centers as Array
	var row_depths: Array = row_geometry.rowDepths as Array
	var row_two_foundation_south_z := float(row_centers[2]) - (float(row_depths[2]) + STREET_FOUNDATION_EXTRA) * 0.5
	var bench_center_z := row_two_foundation_south_z - 0.50 - back_north_extent
	if not is_finite(back_north_extent) or back_north_extent <= 0.0 or not is_finite(bench_center_z):
		return {"ready": false, "reason": "invalid_civic_commons_clearance_geometry"}
	var local_bench_offset := Vector3(0.8, 0.0, 1.80)
	var bench_center := Vector3(28.8, base_y + 0.244, bench_center_z)
	var hub := bench_center - local_bench_offset
	var approach_axis := -Vector3(local_bench_offset.x, 0.0, local_bench_offset.z).normalized()
	var side_axis := Vector3(-approach_axis.z, 0.0, approach_axis.x)
	var members: Array[Dictionary] = []
	for side_index in [-1, 1]:
		for side_slot in range(4):
			var stone_index := (0 if side_index < 0 else 4) + side_slot
			var phase := fposmod(sin(float(stone_index + 3) * 12.73) * 17357.19, 1.0)
			var along := -1.65 + float(side_slot) * 1.1
			members.append({"id": "urban_civic_commons_stone_%02d" % stone_index, "kind": "decor", "material": "stone_foundation", "position": hub + side_axis * float(side_index) * (3.10 + phase * 0.55) + approach_axis * along + Vector3.UP * (0.13 + phase * 0.08), "rotation": Vector3(phase * 0.11, bench_yaw + phase * 0.24, (phase - 0.5) * 0.16), "size": Vector3(0.36 + phase * 0.52, 0.24 + phase * 0.22, 0.32 + (1.0 - phase) * 0.46), "semantic": "citadel_civic_commons_stone", "commonsRole": "side_bank", "clearApproachAxis": approach_axis, "variationOffset": -0.04 + phase * 0.03})
	var seat_center := bench_center + Vector3.UP * 0.64
	members.append({"id": "urban_civic_commons_bench", "kind": "decor", "material": "timber_board", "position": seat_center, "rotation": Vector3(0.0, bench_yaw, 0.0), "size": seat_size, "semantic": "citadel_civic_commons_seating", "commonsRole": "seat", "clearApproachAxis": approach_axis, "variationOffset": -0.02})
	for leg_side in [-1.0, 1.0]:
		var leg_offset := Vector3(leg_side * 1.18, 0.25, 0.0).rotated(Vector3.UP, bench_yaw)
		members.append({"id": "urban_civic_commons_bench_leg_%d" % int(leg_side), "kind": "beam", "material": "timber_beam", "position": bench_center + leg_offset, "rotation": Vector3(0.0, bench_yaw, 0.0), "size": Vector3(0.22, 0.50, 0.56), "semantic": "citadel_civic_commons_seating", "commonsRole": "seat_support", "physicalIntent": "visual_detail", "variationOffset": 0.0})
	var seat_top_y := seat_center.y + seat_size.y * 0.5
	var back_center_y := seat_top_y + back_height * 0.5
	var back_offset := Vector3(0.0, back_center_y - bench_center.y, back_local_z).rotated(Vector3.UP, bench_yaw)
	members.append({"id": "urban_civic_commons_bench_back", "kind": "decor", "material": "timber_board", "position": bench_center + back_offset, "rotation": Vector3(0.0, bench_yaw, 0.0), "size": back_size, "semantic": "citadel_civic_commons_seating", "commonsRole": "backrest", "variationOffset": -0.015})
	var post_bottom_y := bench_center.y
	var post_top_y := back_center_y + back_height * 0.5
	var post_height := post_top_y - post_bottom_y
	var post_center_y := (post_bottom_y + post_top_y) * 0.5
	for post_side in [-1.0, 1.0]:
		var post_offset := Vector3(post_side * 1.30, post_center_y - bench_center.y, back_local_z).rotated(Vector3.UP, bench_yaw)
		members.append({"id": "urban_civic_commons_bench_back_post_%d" % int(post_side), "kind": "beam", "material": "timber_beam", "position": bench_center + post_offset, "rotation": Vector3(0.0, bench_yaw, 0.0), "size": Vector3(0.18, post_height, 0.18), "semantic": "citadel_civic_commons_seating", "commonsRole": "back_support", "physicalIntent": "visual_detail", "variationOffset": 0.0})
	var footprint := AABB()
	for member_index in range(members.size()):
		var member: Dictionary = members[member_index]
		var bounds := _recipe_geometry_bounds(member.position as Vector3, member.rotation as Vector3, member.size as Vector3)
		if member_index == 0:
			footprint = bounds
		else:
			footprint = footprint.merge(bounds)
	if members.size() != 14 or not footprint.position.is_finite() or not footprint.size.is_finite() or footprint.size.x <= 0.0 or footprint.size.z <= 0.0:
		return {"ready": false, "reason": "invalid_civic_commons_footprint"}
	return {"ready": true, "rowGeometry": row_geometry, "hub": hub, "benchCenter": bench_center, "localBenchOffset": local_bench_offset, "approachAxis": approach_axis, "sideAxis": side_axis, "members": members, "footprint": footprint, "rowTwoFoundationSouthZ": row_two_foundation_south_z, "backNorthExtent": back_north_extent, "clearance": 0.50}


static func _civic_infill_environment(source, grammar: Dictionary, front_z: float, keep_front_z: float, base_y: float, variation: float, layout: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	# These independent producers are replayed only into a private planning
	# source. Actual publication order stays unchanged. Trees, roof frames and
	# furnishings are dependent and still run once after resolved house placement.
	var preview = FacadeBearingRecipeScript.copy_blueprint(source.snapshot())
	if not _emit_compose_diagnostic(continuation,"civic_infill_preview"): return {"ready":false,"reason":"cancelled"}
	var commons := add_civic_commons(preview,front_z,keep_front_z,base_y,variation,layout)
	if not commons.ready: return commons
	var stopped := {"value":false}
	var callback := func(stage: String) -> bool:
		if stopped.value: return false
		stopped.value=not _emit_compose_diagnostic(continuation,stage)
		return not stopped.value
	var perimeter_ready := add_perimeter_neighborhoods(preview,grammar,keep_front_z,base_y,variation,callback)
	if stopped.value: return {"ready":false,"reason":"cancelled"}
	if not perimeter_ready: return {"ready":false,"reason":"perimeter_house_opening_layout_failed"}
	add_civic_service_yard(preview,Vector3(37.0,base_y,keep_front_z-8.5),variation)
	add_dressing_clusters(preview,front_z,keep_front_z,base_y,variation)
	if not add_bunting_lines(preview,front_z,keep_front_z,base_y,variation,layout):
		return {"ready":false,"reason":"citadel_bunting_declaration_failed"}
	return {"ready":true,"blueprint":preview}

static func _add_civic_house(blueprint, house: Dictionary, base_y: float, variation: float) -> bool:
	if blueprint.parts.is_empty(): reset_street_house_structural_manifest(blueprint)
	return add_street_house(blueprint,String(house.id),house.center,float(house.width),float(house.depth),float(house.height),-1.0,base_y,String(house.material),variation+float(String(house.id).hash()%17)*0.003,float(house.get("roofRise",-1.0)))

static func civic_house_specs(keep_front_z: float) -> Array:
	var houses := [
		{"id": "urban_civic_house_east", "center": Vector3(43.0, 0.0, keep_front_z - 2.5), "width": 10.2, "depth": 12.0, "height": 9.3, "material": "painted_brick_ochre"},
		{"id": "urban_civic_house_wall", "center": Vector3(56.0, 0.0, keep_front_z - 14.0), "width": 8.8, "depth": 10.4, "height": 7.2, "material": "painted_brick_sage"}
	]
	for house: Dictionary in houses: house["roofRise"]=street_house_roof_rise(house.center)
	return houses

static func add_civic_quarter(blueprint, front_z: float, keep_front_z: float, base_y: float, variation: float, urban_layout: Dictionary, infill_environment = null, continuation: Callable = Callable()) -> Dictionary:
	if not is_finite(variation):
		return {"ready": false, "reason": "invalid_civic_quarter_variation"}
	var commons_layout := civic_commons_layout(front_z, keep_front_z, base_y, urban_layout)
	if not bool(commons_layout.get("ready", false)):
		return commons_layout
	var commons_footprint: AABB = commons_layout.footprint
	var paving_north_z := keep_front_z + 8.0
	var old_paving_south_z := keep_front_z - 24.0
	var paving_margin := 0.25
	var required_paving_south_z := commons_footprint.position.z - paving_margin
	var paving_south_z := minf(old_paving_south_z, required_paving_south_z)
	var paving_depth := paving_north_z - paving_south_z
	var paving_center_z := (paving_north_z + paving_south_z) * 0.5
	if not is_finite(paving_depth) or not is_finite(paving_center_z) or paving_depth <= 0.0:
		return {"ready": false, "reason": "invalid_civic_quarter_paving_geometry"}
	var houses := civic_house_specs(keep_front_z)
	for house: Dictionary in houses:
		if not StreetOpeningLayout.prepare(float(house.depth),float(house.height)).ready:
			return {"ready": false, "reason": "civic_house_opening_layout_failed"}
	var infill: Dictionary={"ready":true,"scope":"standalone civic producer; no enclosure supplied"}
	# Sample the design once at its seeded recipe position. Placement must not
	# reshape the roof/chimney by feeding a relocated world pose back into it.
	if infill_environment!=null:
		var source_before := var_to_bytes(blueprint.snapshot())
		var paving_size := Vector3(48.0,0.08,paving_depth)
		var paving_preview = CivicInfill.Part.new({"position":Vector3(43.0,base_y+0.18,paving_center_z),"size":paving_size})
		var paving_bounds: AABB=blueprint.transformed_part_bounds(paving_preview)
		var producer := func(target, spec: Dictionary): return _add_civic_house(target,spec,base_y,variation)
		infill=CivicInfill.prepare_with_terrace_reconciliation(infill_environment,houses,producer,Rect2(Vector2(paving_bounds.position.x,paving_bounds.position.z),Vector2(paving_bounds.size.x,paving_bounds.size.z)),base_y,continuation)
		if not infill.ready: return infill
		if source_before!=var_to_bytes(blueprint.snapshot()): return {"ready":false,"reason":"civic_source_changed_during_terrace_preparation"}
		var terrace_commit := CivicInfill.Terraces.commit(blueprint,infill.terraceOriginals,infill.terraceReplacements)
		if not terrace_commit.ready: return terrace_commit
		houses=infill.specs
	add_part(blueprint, "urban_civic_quarter_paving", "foundation", "cobblestone", Vector3(43.0, base_y + 0.18, paving_center_z), Vector3(48.0, 0.08, paving_depth), {"collision": false, "variation": variation - 0.025, "semantic": "citadel_civic_quarter_paving", "pavingFamily": "civic_setts", "pavingRegion": "citadel_courtyard", "pavingHeading": "x"})
	for house_value in houses:
		var house: Dictionary = house_value as Dictionary
		if not _add_civic_house(blueprint,house,base_y,variation):
			return {"ready": false, "reason": "civic_house_opening_layout_failed"}
	for route_index in range(3):
		var route_z := keep_front_z - 13.5 + float(route_index) * 5.2
		add_traffic_wear(blueprint, "urban_civic_quarter_route_%02d" % route_index, Vector3(37.8, base_y + 0.232, route_z), Vector2(27.0, 1.84), 0.0, variation - 0.04 + float(route_index) * 0.011, "citadel_civic_route_wear")
	return {"ready": true, "commonsLayout": commons_layout, "pavingNorthZ": paving_north_z, "pavingSouthZ": paving_south_z, "pavingDepth": paving_depth, "pavingCenterZ": paving_center_z, "pavingMargin": paving_margin,"infill":infill}


static func add_civic_commons(blueprint, front_z: float, keep_front_z: float, base_y: float, variation: float, urban_layout: Dictionary) -> Dictionary:
	if not is_finite(variation):
		return {"ready": false, "reason": "invalid_civic_commons_variation"}
	var commons_layout := civic_commons_layout(front_z, keep_front_z, base_y, urban_layout)
	if not bool(commons_layout.get("ready", false)):
		return commons_layout
	var members: Array = commons_layout.members as Array
	for member_value in members:
		var member: Dictionary = member_value as Dictionary
		var options := {"rotation": member.rotation, "collision": false, "variation": variation + float(member.variationOffset), "semantic": member.semantic, "commonsRole": member.commonsRole}
		if member.has("clearApproachAxis"):
			options["clearApproachAxis"] = member.clearApproachAxis
		if member.has("physicalIntent"):
			options["physicalIntent"] = member.physicalIntent
		add_part(blueprint, String(member.id), String(member.kind), String(member.material), member.position as Vector3, member.size as Vector3, options)
	return {"ready": true, "layout": commons_layout, "rowTwoFoundationSouthZ": commons_layout.rowTwoFoundationSouthZ, "benchCenterZ": (commons_layout.benchCenter as Vector3).z, "backNorthExtent": commons_layout.backNorthExtent, "clearance": commons_layout.clearance}


static func add_market_stall_household(blueprint, stall_center: Vector3, side: float, depth_slot: float, variation: float) -> void:
	var stall_key := "%d_%d" % [int(side), int(depth_slot)]
	var canopy_material := "wool_rust" if side * depth_slot < 0.0 else "wool_moss"
	add_traffic_wear(blueprint, "urban_market_compaction_%s" % stall_key, stall_center + Vector3(-side * 2.10, 0.035, -depth_slot * 0.08), Vector2(4.85, 1.46 + (0.18 if depth_slot > 0.0 else 0.0)), 0.0, variation - 0.04, "citadel_market_compaction")
	for post_side in [-1.0, 1.0]:
		for post_depth in [-1.0, 1.0]:
			add_part(blueprint, "urban_market_knee_%s_%d_%d" % [stall_key, int(post_side), int(post_depth)], "beam", "timber_beam", stall_center + Vector3(post_side * 1.04, 2.14, post_depth * 0.72), Vector3(0.14, 0.92, 0.14), {"rotation": Vector3(0.0, 0.0, post_side * deg_to_rad(43.0)), "collision": false, "variation": variation + post_depth * 0.01, "semantic": "citadel_market_joinery"})
	for canopy_face in [-1.0, 1.0]:
		for strip_index in range(6):
			var strip_x := stall_center.x - 1.45 + float(strip_index) * 0.58
			var sag := 0.035 * absf(float(strip_index) - 2.5)
			var strip_material := "linen" if strip_index == (2 if side > 0.0 else 4) and canopy_face > 0.0 else canopy_material
			add_part(blueprint, "urban_market_canopy_%s_%d_%02d" % [stall_key, int(canopy_face), strip_index], "decor", strip_material, Vector3(strip_x, stall_center.y + 2.54 + sag, stall_center.z + canopy_face * 0.57), Vector3(0.56, 0.075, 1.30), {"rotation": Vector3(canopy_face * deg_to_rad(11.0 + float(strip_index % 3) * 0.8), 0.0, side * deg_to_rad(2.0 + float(strip_index % 2))), "collision": false, "variation": variation + canopy_face * 0.01 + float(strip_index) * 0.006, "semantic": "citadel_market_canopy"})
	add_part(blueprint, "urban_market_canopy_ridge_%s" % stall_key, "beam", "timber_beam", stall_center + Vector3(0.0, 2.68, 0.0), Vector3(3.55, 0.14, 0.14), {"collision": false, "variation": variation, "semantic": "citadel_market_canopy_ridge"})
	add_part(blueprint, "urban_market_lantern_frame_%s" % stall_key, "decor", "ironwork", stall_center + Vector3(0.0, 2.18, 0.0), Vector3(0.22, 0.42, 0.22), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_frame"})
	add_part(blueprint, "urban_market_lantern_flame_%s" % stall_key, "decor", "candle_flame", stall_center + Vector3(0.0, 2.16, 0.0), Vector3(0.11, 0.20, 0.11), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_flame"})
	for counter_board in range(5):
		add_part(blueprint, "urban_market_counter_%s_%02d" % [stall_key, counter_board], "decor", "timber_board", stall_center + Vector3(-1.14 + float(counter_board) * 0.57, 0.78 + float((counter_board + int(side)) % 3) * 0.012, -depth_slot * 0.10), Vector3(0.55, 0.15, 0.78), {"rotation": Vector3(0.0, deg_to_rad(float(counter_board - 2) * 0.7), 0.0), "collision": false, "variation": variation + float(counter_board) * 0.009, "semantic": "citadel_market_counter"})
	for leg_side in [-1.0, 1.0]:
		add_part(blueprint, "urban_market_counter_leg_%s_%d" % [stall_key, int(leg_side)], "beam", "timber_beam", stall_center + Vector3(leg_side * 1.18, 0.39, 0.0), Vector3(0.18, 0.78, 0.52), {"collision": false, "variation": variation, "semantic": "citadel_market_counter_leg"})
	add_part(blueprint, "urban_market_counter_shelf_%s" % stall_key, "decor", "timber_board", stall_center + Vector3(0.0, 0.31, 0.0), Vector3(2.65, 0.12, 0.66), {"collision": false, "variation": variation, "semantic": "citadel_market_counter_shelf"})
	var goods := [
		{"kind": "pottery", "material": "ceramic_glaze", "size": Vector3(0.34, 0.42, 0.34)},
		{"kind": "sack", "material": "linen", "size": Vector3(0.38, 0.46, 0.34)},
		{"kind": "basket", "material": "timber_board", "size": Vector3(0.42, 0.34, 0.42)},
		{"kind": "sack", "material": "wool_rust", "size": Vector3(0.34, 0.38, 0.32)},
		{"kind": "pottery", "material": "painted_decor", "size": Vector3(0.31, 0.36, 0.31)}
	]
	for goods_index in range(goods.size()):
		var good: Dictionary = goods[goods_index] as Dictionary
		var goods_phase := fposmod(sin(float(goods_index + 1) * 15.71 + side * 7.3 + depth_slot * 11.9) * 31757.13, 1.0)
		if goods_phase < 0.16:
			continue
		var goods_x := stall_center.x - 1.05 + float(goods_index) * 0.52 + (goods_phase - 0.5) * 0.20
		var goods_size: Vector3 = good.get("size", Vector3(0.30, 0.30, 0.30)) as Vector3
		add_part(blueprint, "urban_market_goods_%s_%02d" % [stall_key, goods_index], String(good.get("kind", "pottery")), String(good.get("material", "ceramic_glaze")), Vector3(goods_x, stall_center.y + 0.88 + goods_size.y * 0.5, stall_center.z - depth_slot * 0.10 + (goods_phase - 0.5) * 0.34), goods_size, {"rotation": Vector3(0.0, goods_phase * TAU, 0.0), "collision": false, "variation": variation + float(goods_index) * 0.012, "semantic": "citadel_market_goods"})
	for storage_index in range(2):
		var storage_phase := fposmod(sin(float(storage_index + 1) * 21.17 + side * 5.1 + depth_slot * 9.7) * 11369.37, 1.0)
		var storage_z := stall_center.z + depth_slot * (1.18 + float(storage_index) * 0.76) + (storage_phase - 0.5) * 0.42
		add_part(blueprint, "urban_market_barrel_%s_%02d" % [stall_key, storage_index], "barrel", "timber_board", Vector3(stall_center.x + side * (1.42 + storage_phase * 0.32), stall_center.y + 0.50, storage_z), Vector3(0.72, 1.0, 0.72), {"rotation": Vector3(0.0, storage_phase * TAU, 0.0), "collision": false, "variation": variation + float(storage_index) * 0.025, "semantic": "citadel_market_storage"})
		if storage_index == 0 or storage_phase > 0.42:
			add_part(blueprint, "urban_market_crate_%s_%02d" % [stall_key, storage_index], "crate", "timber_board", Vector3(stall_center.x - side * (1.05 - float(storage_index) * 0.18), stall_center.y + 0.33 + float(storage_index) * 0.13, storage_z + (storage_phase - 0.5) * 0.28), Vector3(0.62, 0.66 + float(storage_index) * 0.24, 0.62), {"rotation": Vector3(0.0, (storage_phase - 0.5) * 0.42, 0.0), "collision": false, "variation": variation + float(storage_index) * 0.018, "semantic": "citadel_market_storage"})
	var seating_phase := fposmod(sin(side * 17.0 + depth_slot * 31.0 + variation * 43.0) * 17357.19, 1.0)
	if seating_phase > 0.28:
		var bench_center := stall_center + Vector3((seating_phase - 0.5) * 0.72, 0.36, -depth_slot * (1.48 + seating_phase * 0.34))
		var bench_rotation := (seating_phase - 0.5) * deg_to_rad(12.0)
		add_part(blueprint, "urban_market_bench_%s" % stall_key, "decor", "timber_board", bench_center, Vector3(1.85 + seating_phase * 0.74, 0.16, 0.46), {"rotation": Vector3(0.0, bench_rotation, 0.0), "collision": false, "variation": variation, "semantic": "citadel_market_seating"})
		for bench_leg in [-1.0, 1.0]:
			add_part(blueprint, "urban_market_bench_leg_%s_%d" % [stall_key, int(bench_leg)], "beam", "timber_beam", bench_center + Vector3(bench_leg * (0.68 + seating_phase * 0.18), -0.18, 0.0), Vector3(0.14, 0.36, 0.34), {"rotation": Vector3(0.0, bench_rotation, 0.0), "collision": false, "variation": variation, "semantic": "citadel_market_seating"})


static func add_overhead_bridge(blueprint, center: Vector3, span: float, base_y: float, variation: float) -> void:
	for side in [-1.0, 1.0]:
		add_part(blueprint, "urban_bridge_abutment_%d" % int(side), "wall", "stone_foundation", Vector3(center.x + side * (span * 0.5 - 0.42), (base_y + 6.9) * 0.5, center.z), Vector3(0.84, base_y + 6.9, 2.6), {"variation": variation - 0.03, "semantic": "citadel_overhead_bridge_abutment", "physicalIntent": "structural_mass"})
	add_part(blueprint, "urban_bridge_deck", "floor", "timber_beam", Vector3(center.x, base_y + 6.9, center.z), Vector3(span, 0.34, 2.4), {"variation": variation, "semantic": "citadel_overhead_bridge", "physicalIntent": "walkable_surface", "playerSurfaceAudit": true})
	for side in [-1.0, 1.0]:
		add_part(blueprint, "urban_bridge_rail_%d" % int(side), "beam", "timber_beam", Vector3(center.x, base_y + 7.55, center.z + side * 1.05), Vector3(span, 1.0, 0.18), {"collision": false, "variation": variation, "semantic": "citadel_overhead_bridge_rail"})


static func add_civic_landmark(blueprint, center: Vector3, base_y: float, variation: float) -> void:
	var width := 8.4
	var depth := 9.0
	var height := 17.0
	add_grounded_foundation(blueprint, "urban_civic_tower_foundation", center, width + 0.36, depth + 0.36, base_y, variation - 0.025, "citadel_civic_landmark_foundation")
	add_part(blueprint, "urban_civic_tower", "wall", "painted_brick_cream", Vector3(center.x, base_y + height * 0.5, center.z), Vector3(width, height, depth), {"variation": variation, "semantic": "citadel_civic_landmark"})
	ExteriorBunting.declare(blueprint.parts.back(), "landmark", 0)
	for level in [4.2, 8.0, 11.8]:
		add_part(blueprint, "urban_civic_recess_%d" % int(level * 10.0), "decor", "window_recess", Vector3(center.x + width * 0.5 + 0.04, base_y + level, center.z), Vector3(0.10, 1.45, 1.05), {"collision": false, "variation": variation, "semantic": "citadel_civic_blind_recess"})
	add_civic_roof_section(blueprint, center, width, depth, base_y + height, variation)
	add_part(blueprint, "urban_civic_banner", "sign", "painted_decor", Vector3(center.x + width * 0.5 + 0.08, base_y + 10.0, center.z), Vector3(0.10, 3.2, 1.45), {"collision": false, "variation": variation, "semantic": "citadel_civic_banner"})


static func add_civic_roof_section(blueprint, center: Vector3, tower_width: float, tower_depth: float, tower_top_y: float, variation: float) -> void:
	var overhang := clampf(tower_width * 0.07, 0.48, 0.72)
	var half_run := tower_width * 0.5 + overhang
	var rise := clampf(tower_width * 0.42, 2.8, 3.8)
	var thickness := 0.32
	var slope_length := sqrt(half_run * half_run + rise * rise)
	var angle := atan2(rise, half_run)
	var center_y := tower_top_y + rise * 0.5 + cos(angle) * thickness * 0.5
	for side in [-1.0, 1.0]:
		var role := "left" if side < 0.0 else "right"
		var bearing_id := "urban_civic_roof_bearing_%d" % int(side)
		add_part(blueprint, "urban_civic_roof_%s" % role, "roof", "roof_shingle", Vector3(center.x + side * half_run * 0.5, center_y, center.z), Vector3(slope_length, thickness, tower_depth + overhang * 2.0), {"rotation": Vector3(0.0, 0.0, -side * angle), "variation": variation - 0.03, "semantic": "citadel_civic_roof", "physicalIntent": "structural_mass", "physicalRequiredSupportPartIds": [bearing_id], "roofRole": role, "roofHalfRun": half_run, "roofRise": rise, "roofTopY": tower_top_y, "roofOverhang": overhang})
	# Each face's inboard quarter sample now lands on a generated wall plate. The
	# plate spans from the rooted tower top to the exact sloped underside without
	# moving or thickening either visible roof face.
	for side in [-1.0, 1.0]:
		add_part(blueprint, "urban_civic_roof_bearing_%d" % int(side), "beam", "timber_beam", Vector3(center.x + side * half_run * 0.75, tower_top_y + rise * 0.125, center.z), Vector3(0.30, rise * 0.25, tower_depth), {"variation": variation - 0.026, "semantic": "citadel_civic_roof_bearing", "physicalIntent": "structural_mass", "physicalRequiredSupportPartIds": ["urban_civic_tower"], "roofRole": "wall_plate"})
	add_part(blueprint, "urban_civic_roof_ridge", "beam", "timber_beam", Vector3(center.x, tower_top_y + rise + 0.06, center.z), Vector3(0.28, 0.30, tower_depth + overhang * 2.0), {"collision": false, "variation": variation - 0.025, "semantic": "citadel_civic_roof_framing", "physicalIntent": "visual_detail", "roofRole": "ridge"})
	for side in [-1.0, 1.0]:
		add_part(blueprint, "urban_civic_roof_eave_%d" % int(side), "beam", "timber_beam", Vector3(center.x + side * half_run, tower_top_y + 0.10, center.z), Vector3(0.24, 0.30, tower_depth + overhang * 2.0), {"collision": false, "variation": variation - 0.02, "semantic": "citadel_civic_roof_framing", "physicalIntent": "visual_detail", "roofRole": "eave"})
	for gable_side in [-1.0, 1.0]:
		for level in range(4):
			var level_fraction := (float(level) + 0.5) / 4.0
			var upper_fraction := float(level + 1) / 4.0
			var level_width := maxf(0.20, half_run * 2.0 * (1.0 - upper_fraction))
			var support_id := "urban_civic_tower" if level == 0 else "urban_civic_roof_gable_%d_%02d" % [int(gable_side), level - 1]
			add_part(blueprint, "urban_civic_roof_gable_%d_%02d" % [int(gable_side), level], "wall", "painted_brick_cream", Vector3(center.x, tower_top_y + rise * level_fraction, center.z + gable_side * tower_depth * 0.5), Vector3(level_width, rise / 4.0 + 0.04, 0.22), {"variation": variation - 0.018 + float(level) * 0.004, "semantic": "citadel_civic_gable_closure", "physicalIntent": "structural_mass", "physicalRequiredSupportPartIds": [support_id], "roofRole": "gable_closure", "roofUpperFraction": upper_fraction})


static func add_terraced_edge(blueprint, center: Vector3, base_y: float, variation: float) -> void:
	for level in range(3):
		var terrace_top_y := base_y + float(level + 1) * 0.72
		var terrace_z := center.z + float(level) * 2.4
		add_grounded_foundation(blueprint, "urban_terrace_%02d" % level, Vector3(center.x, 0.0, terrace_z), 12.0 - float(level) * 1.4, 4.8, terrace_top_y, variation, "citadel_urban_terrace")
		for step in range(4):
			var step_top_y := base_y + float(level) * 0.72 + float(step + 1) * 0.18
			add_part(blueprint, "urban_terrace_step_%02d_%02d" % [level, step], "stair_tread", "stone_foundation", Vector3(center.x - 6.6 + float(step) * 0.42, step_top_y * 0.5, terrace_z - 2.0 + float(step) * 0.42), Vector3(1.5, step_top_y, 0.46), {"variation": variation, "semantic": "citadel_urban_stair"})


static func add_dressing_clusters(blueprint, front_z: float, keep_front_z: float, base_y: float, variation: float) -> void:
	var clusters: Array[Vector3] = [Vector3(-6.8, 0.0, front_z + 18.0), Vector3(11.0, 0.0, keep_front_z - 10.0)]
	for index in range(clusters.size()):
		var center: Vector3 = clusters[index]
		var awning_material := "wool_rust" if index % 2 == 0 else "wool_moss"
		for strip_index in range(6):
			add_part(blueprint, "urban_awning_%02d_%02d" % [index, strip_index], "decor", awning_material, Vector3(center.x - 1.45 + float(strip_index) * 0.58, base_y + 2.35 + absf(float(strip_index) - 2.5) * 0.025, center.z), Vector3(0.56, 0.075, 1.76), {"rotation": Vector3(deg_to_rad(-9.0), 0.0, 0.0), "collision": false, "variation": variation + float(index) * 0.02 + float(strip_index) * 0.005, "semantic": "citadel_market_awning"})
		for support_side in [-1.0, 1.0]:
			add_part(blueprint, "urban_awning_support_%02d_%d" % [index, int(support_side)], "beam", "timber_beam", Vector3(center.x + support_side * 1.52, base_y + 1.18, center.z + 0.52), Vector3(0.16, 2.36, 0.16), {"collision": false, "variation": variation, "semantic": "citadel_market_awning_support"})
		for crate_index in range(3):
			add_part(blueprint, "urban_crate_%02d_%02d" % [index, crate_index], "crate", "timber_board", Vector3(center.x - 1.1 + float(crate_index) * 0.82, base_y + 0.34, center.z + 0.8), Vector3(0.68, 0.68 + float(crate_index % 2) * 0.25, 0.68), {"collision": false, "variation": variation, "semantic": "citadel_market_crate"})
	for banner_index in range(5):
		var banner_z := front_z + 12.0 + float(banner_index) * 8.0
		var banner_x := -4.1 if banner_index % 2 == 0 else 7.2
		add_part(blueprint, "urban_street_banner_%02d" % banner_index, "sign", "painted_decor", Vector3(banner_x, base_y + 5.4, banner_z), Vector3(0.12, 2.3, 1.0), {"collision": false, "variation": variation + float(banner_index) * 0.01, "semantic": "citadel_street_banner"})


static func add_bunting_lines(blueprint, front_z: float, keep_front_z: float, base_y: float, variation: float, urban_layout: Dictionary) -> bool:
	var exterior := ExteriorBunting.association(blueprint)
	if not exterior.ready: return false
	var market_lane_x := float(urban_layout.get("marketLaneX", MARKET_LANE_X))
	var market_terrace_rise := float(urban_layout.get("marketTerraceRise", MARKET_TERRACE_RISE))
	var lines := [
		{"start": -4.2, "end": 5.8, "z": front_z + 20.0, "y": base_y + 5.8},
		{"start": market_lane_x - 8.0, "end": market_lane_x + 8.0, "z": front_z + 33.5, "y": base_y + market_terrace_rise + 6.0},
		{"start": 3.0, "end": 20.0, "z": keep_front_z - 9.0, "y": base_y + market_terrace_rise * 2.0 + 5.4}
	]
	# The third line is optional exterior dressing.  Its old fixed coordinates
	# can describe a different forecourt after deterministic layout variation;
	# do not publish an unowned, unmountable string and make it a structural
	# loading requirement.  Final socket and clearance proof still occurs after
	# all source geometry is assembled.
	var exterior_line: Dictionary = lines[2]
	var exterior_center := Vector3((float(exterior_line.start)+float(exterior_line.end))*0.5,
		float(exterior_line.y)+0.33,float(exterior_line.z))
	var exterior_emittable := ExteriorBunting.accepts_authored_center(blueprint,exterior.owners,exterior_center)
	var cloth_materials: Array[String] = ["wool_rust", "linen", "wool_moss"]
	var assemblies: Array = []
	for line_index in range(lines.size()):
		if line_index == 2 and not exterior_emittable:
			continue
		var line: Dictionary = lines[line_index] as Dictionary
		var start_x := float(line.get("start", 0.0))
		var end_x := float(line.get("end", 0.0))
		var line_y := float(line.get("y", base_y + 5.5))
		var line_z := float(line.get("z", front_z))
		var rope_id := "urban_bunting_rope_%02d" % line_index
		add_part(blueprint, rope_id, "beam", "ironwork", Vector3((start_x + end_x) * 0.5, line_y + 0.33, line_z), Vector3(end_x - start_x, 0.035, 0.035), {"collision": false, "variation": variation, "semantic": "citadel_bunting_rope"})
		if line_index == 1:
			blueprint.parts.back().recipe["buntingMarketOwners"] = blueprint.recipe.get("citadelMarketHousePair",{}).duplicate(true)
		if line_index == 2:
			blueprint.parts.back().recipe[ExteriorBunting.OWNERS] = exterior.owners.duplicate(true)
		var members: Array = []
		var pennant_count := 9 if line_index == 0 else 13
		for pennant_index in range(pennant_count):
			var ratio := (float(pennant_index) + 0.5) / float(pennant_count)
			var pennant_x := lerpf(start_x, end_x, ratio)
			var sag := sin(ratio * PI) * 0.28
			var material := cloth_materials[(line_index + pennant_index) % cloth_materials.size()]
			add_part(blueprint, "urban_bunting_%02d_%02d" % [line_index, pennant_index], "pennant", material, Vector3(pennant_x, line_y - sag, line_z), Vector3(maxf(0.38, (end_x - start_x) / float(pennant_count) * 0.56), 0.68, 0.055), {"rotation": Vector3(0.0, 0.0, deg_to_rad(-8.0 if pennant_index % 2 == 0 else 8.0)), "collision": false, "variation": variation + float(pennant_index) * 0.006, "semantic": "citadel_bunting"})
			members.append(blueprint.parts.back().id)
		var assembly := {"ropeId":rope_id,"pennantIds":members}
		if line_index == 2: assembly["mounting"] = "exterior"
		assemblies.append(assembly)
	return BuntingManifest.declare(blueprint,assemblies).ready


static func add_traffic_wear(blueprint, prefix: String, center: Vector3, span: Vector2, heading: float, variation: float, semantic: String) -> void:
	return


static func settle_household_ground_dressing(blueprint) -> void:
	var floors := []
	var house_ground := {}
	for part in blueprint.parts:
		if part.semantic == "citadel_urban_door": house_ground[part.id.trim_suffix("_door")] = part.position.y - part.size.y * 0.5
		if part.collision_enabled and part.kind in ["foundation", "floor"] and part.rotation == Vector3.ZERO:
			floors.append(blueprint.transformed_part_bounds(part))
	for index in range(blueprint.parts.size() - 1, -1, -1):
		var part = blueprint.parts[index]
		if not part.semantic in ["citadel_household_storage", "citadel_household_firewood"]: continue
		var prefix: String = part.id.get_slice("_household_",0) if "_household_" in part.id else part.id.get_slice("_firewood_",0)
		if not house_ground.has(prefix): continue
		var ground: float = house_ground[prefix]
		var bounds: AABB = blueprint.transformed_part_bounds(part)
		var supported_y := -INF
		for floor_bounds: AABB in floors:
			if floor_bounds.end.y < ground - 0.06 or floor_bounds.end.y > ground + 0.40: continue
			if bounds.position.x >= floor_bounds.position.x and bounds.end.x <= floor_bounds.end.x and bounds.position.z >= floor_bounds.position.z and bounds.end.z <= floor_bounds.end.z:
				supported_y = maxf(supported_y, floor_bounds.end.y)
		if not is_finite(supported_y): blueprint.parts.remove_at(index)
		else: part.position.y += supported_y - ground


static func add_grounded_foundation(blueprint, part_id: String, center: Vector3, width: float, depth: float, top_y: float, variation: float, semantic: String) -> void:
	if top_y <= 0.02:
		return
	add_part(blueprint, part_id, "foundation", "stone_foundation", Vector3(center.x, top_y * 0.5, center.z), Vector3(width, top_y, depth), {"variation": variation, "semantic": semantic, "physicalIntent": "structural_mass"})


static func paving_treatments(urban_layout: Dictionary, front_z: float, keep_front_z: float) -> Array:
	var lanes: Array = urban_layout.get("laneCenters", []) as Array
	var result: Array = []
	for lane_value in lanes:
		result.append({"center": Vector3(float(lane_value), 0.0, (front_z + keep_front_z) * 0.5), "span": Vector2(maxf(12.0, keep_front_z - front_z - 4.0), 2.1), "heading": PI * 0.5})
	return result


static func add_part(blueprint, part_id: String, kind: String, material: String, position: Vector3, size: Vector3, options: Dictionary = {}) -> void:
	blueprint.add_part({
		"id": part_id,
		"kind": kind,
		"material": material,
		"position": position,
		"rotation": options.get("rotation", Vector3.ZERO),
		"size": size,
		"collision": bool(options.get("collision", true)),
		"semantic": String(options.get("semantic", kind)),
		"recipe": options.duplicate(true)
	})


static func stable_unit(seed: int, channel: String) -> float:
	return float(stable_hash("%d:%s" % [seed, channel]) & 0x7fffffff) / float(0x7fffffff)


static func stable_hash(text: String) -> int:
	var hash_value := 2166136261
	for index in range(text.length()):
		hash_value = int((hash_value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return hash_value
