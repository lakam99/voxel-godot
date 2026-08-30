extends RefCounted
class_name LandmarkBuildingRecipeSampler

## Pure deterministic recipe sampler for all landmark-scale construction.
## Context is normalized in a fixed key order before seeding, so generated
## results cannot depend on dictionary insertion order or publication order.

const BuildingFamilyCatalogScript := preload("res://scripts/buildings/BuildingFamilyCatalog.gd")
const CottageRecipeSamplerScript := preload("res://scripts/buildings/CottageRecipeSampler.gd")
const NpcConstantsScript := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd")

const SCHEMA_VERSION := 1
const CONTEXT_KEYS: Array[String] = ["settlementTier", "biome", "siteKey", "style"]


static func sample(seed: int, requested_family: String, raw_context: Dictionary = {}) -> Dictionary:
	var family := BuildingFamilyCatalogScript.normalize_family(requested_family)
	var context := normalized_context(raw_context, family)
	var definition := BuildingFamilyCatalogScript.definition_for(family)
	var recipe_seed := stable_recipe_seed(seed, family, context)
	var rng := RandomNumberGenerator.new()
	rng.seed = recipe_seed
	var width_range: Vector2 = definition.get("widthRange", Vector2(8.0, 10.0)) as Vector2
	var depth_range: Vector2 = definition.get("depthRange", Vector2(6.0, 8.0)) as Vector2
	var storey_range: Vector2i = definition.get("storeyRange", Vector2i(1, 1)) as Vector2i
	var floor_count := rng.randi_range(storey_range.x, storey_range.y)
	var floor_height := snappedf(rng.randf_range(4.15, 4.70), 0.05) if family == "town_hall" else snappedf(rng.randf_range(3.35, 3.85), 0.05) if floor_count > 0 else 0.0
	var width := snappedf(rng.randf_range(width_range.x, width_range.y), 0.20)
	var depth := snappedf(rng.randf_range(depth_range.x, depth_range.y), 0.20)
	var wall_height := snappedf(floor_height * maxf(1.0, float(floor_count)), 0.05)
	var room_program: Array[Dictionary] = []
	# Civic room count derives from usable footprint, not from one authored
	# Town-Hall scene. A compact hall has one rear service room, a standard hall
	# separates records from the steward, and a deep/wide hall earns a dedicated
	# civic store. All choices replay from the same recipe seed and dimensions.
	var town_hall_layout := town_hall_layout_for_footprint(width, depth) if family == "town_hall" else ""
	var roles: Array = town_hall_room_roles(town_hall_layout) if family == "town_hall" else definition.get("roomProgram", []) as Array
	for index in range(roles.size()):
		var role := String(roles[index])
		room_program.append({
			"id": "%s_%02d" % [role, index + 1],
			"role": role,
			"floor": room_floor_for_role(role, index, floor_count),
			"public": role in ["public_hall", "hearth", "notice_archive", "gate_passage", "courtyard", "great_hall"]
		})
	# The first civic form reserves its front facade for the public square. The
	# family still varies in footprint, openings, rooms and materials; this is a
	# settlement-facing rule, not an authored landmark placement.
	var entry_side: String = "front" if family == "town_hall" else ["front", "right", "back", "left"][rng.randi_range(0, 3)]
	var window_count := maxi(0, int(round((width + depth) * rng.randf_range(0.14, 0.22))))
	var style := String(context.get("style", definition.get("defaultStyle", "timber"))).to_lower()
	return {
		"schemaVersion": SCHEMA_VERSION,
		"family": family,
		"seed": seed,
		"recipeSeed": recipe_seed,
		"context": context,
		"style": style,
		"landmarkRole": String(definition.get("landmarkRole", "home")),
		"minimumTier": String(definition.get("minimumTier", "hamlet")),
		"width": width,
		"depth": depth,
		"floorCount": floor_count,
		"floorHeight": floor_height,
		"wallHeight": wall_height,
		"wallThickness": 0.34 if style == "masonry" else 0.28,
		"foundationHeight": 0.56 if family in ["keep", "gatehouse", "tower"] else 0.48,
		"roofRise": snappedf(rng.randf_range(3.10, 4.30), 0.05) if family == "town_hall" else snappedf(rng.randf_range(2.0, 3.4), 0.05) if floor_count > 0 else 0.0,
		"roofOverhang": snappedf(rng.randf_range(0.44, 0.72), 0.02) if floor_count > 0 else 0.0,
		"openingPolicy": {
			"entrySide": entry_side,
			"entryWidth": snappedf(rng.randf_range(1.48, 2.22), 0.02),
			"entryHeight": minf(wall_height - 0.52, snappedf(rng.randf_range(2.38, 2.86), 0.02)),
			"windowCount": window_count,
			"windowHeight": snappedf(rng.randf_range(1.10, 1.48), 0.02)
		},
		"roomProgram": room_program,
		"townHallLayout": town_hall_layout,
		"materialVariation": float(abs(seed) % 17) / 100.0 - 0.08
	}


static func sample_compound(seed: int, requested_compound: String, raw_context: Dictionary = {}) -> Dictionary:
	var compound := requested_compound.strip_edges().to_lower()
	var context := normalized_context(raw_context, "keep")
	var member_families := BuildingFamilyCatalogScript.compound_member_families(compound)
	var members: Array[Dictionary] = []
	for index in range(member_families.size()):
		var family := member_families[index]
		var member_seed := stable_recipe_seed(seed + index * 92821, "%s.%s.%d" % [compound, family, index], context)
		var recipe := sample(member_seed, family, context)
		members.append({
			"id": "%s_%02d" % [family, index + 1],
			"family": family,
			"seed": member_seed,
			"recipe": recipe,
			"placementRole": compound_member_role(family, index),
			"ordinal": index
		})
	var compound_recipe := {
		"schemaVersion": SCHEMA_VERSION,
		"compound": compound,
		"seed": seed,
		"context": context,
		"id": "compound.%s.%d.%s" % [compound, seed, String(context.get("siteKey", "site"))],
		"members": members
	}
	if compound == "castle":
		compound_recipe["castleGrammar"] = sample_castle_grammar(seed, context)
	return compound_recipe


static func sample_castle_grammar(seed: int, context: Dictionary) -> Dictionary:
	# The compound has its own deterministic spatial grammar. Member recipes give
	# each family its material/room identity, while these values decide how the
	# families compose into a compact fortress, broad bailey or grand citadel.
	var rng := RandomNumberGenerator.new()
	rng.seed = stable_recipe_seed(seed, "castle.grammar", context)
	var profile_roll := rng.randf()
	var requested_citadel_scale := clampf(float(context.get("citadelScale", 0.0)), 0.0, 6.0)
	# A caller that explicitly requests a large citadel is asking for this
	# grammar, not merely for a larger compact keep. Seeded profile variation
	# remains unchanged when no scale is supplied.
	var profile := "grand_citadel" if requested_citadel_scale > 1.0 else ("compact_keep" if profile_roll < 0.28 else "walled_bailey" if profile_roll < 0.70 else "grand_citadel")
	var courtyard_width := 0.0
	var courtyard_depth := 0.0
	var tower_count := 4
	var tower_span := 0.0
	var wall_height := 0.0
	var keep_storeys := 0
	var grand_scale := 1.0
	match profile:
		"compact_keep":
			courtyard_width = snappedf(rng.randf_range(40.0, 54.0), 0.20)
			courtyard_depth = snappedf(rng.randf_range(34.0, 50.0), 0.20)
			tower_count = [4, 6][rng.randi_range(0, 1)]
			tower_span = snappedf(rng.randf_range(5.6, 7.6), 0.20)
			wall_height = snappedf(rng.randf_range(5.6, 7.4), 0.20)
			keep_storeys = rng.randi_range(3, 5)
		"grand_citadel":
			# A production seed may grow a citadel beyond the former maximum; a
			# supplied scale is useful for a deterministic review of the six-times
			# maximum form without adding a second builder or authored mega-map.
			grand_scale = requested_citadel_scale if requested_citadel_scale >= 1.0 else 1.0 + pow(rng.randf(), 8.0) * 5.0
			courtyard_width = snappedf(rng.randf_range(82.0, 112.0) * grand_scale, 0.20)
			courtyard_depth = snappedf(rng.randf_range(68.0, 96.0) * grand_scale, 0.20)
			tower_count = [6, 8][rng.randi_range(0, 1)]
			tower_span = snappedf(rng.randf_range(7.8, 10.6), 0.20)
			wall_height = snappedf(rng.randf_range(8.0, 11.2), 0.20)
			keep_storeys = rng.randi_range(5, 8)
		_:
			courtyard_width = snappedf(rng.randf_range(58.0, 84.0), 0.20)
			courtyard_depth = snappedf(rng.randf_range(48.0, 72.0), 0.20)
			tower_count = [4, 6, 8][rng.randi_range(0, 2)]
			tower_span = snappedf(rng.randf_range(6.6, 9.2), 0.20)
			wall_height = snappedf(rng.randf_range(6.8, 9.4), 0.20)
			keep_storeys = rng.randi_range(4, 7)
	var floor_height := snappedf(rng.randf_range(3.45, 4.10), 0.05)
	# A city-scale citadel must retain a keep that reads as its landmark rather
	# than a low roofed rectangle in a much larger court. The courtyard is already
	# the authoritative footprint scale, so keep width/depth grow exactly with it
	# without stealing planned street lots. The additional response grows occupied
	# storeys with city scale. It remains a recipe value, so floors, stairs, rooms
	# and collision all use the same fact.
	var citadel_progress := clampf((grand_scale - 1.0) / 5.0, 0.0, 1.0)
	var keep_footprint_scale := 1.0
	var keep_height_scale := lerpf(1.0, 1.42, pow(citadel_progress, 0.70))
	var base_keep_storeys := keep_storeys
	keep_storeys = clampi(maxi(keep_storeys, roundi(float(base_keep_storeys) * keep_height_scale)), 5, 7)
	var keep_width := snappedf(courtyard_width * rng.randf_range(0.25, 0.34) * keep_footprint_scale, 0.20)
	var keep_depth := snappedf(courtyard_depth * rng.randf_range(0.22, 0.32) * keep_footprint_scale, 0.20)
	var gate_width := snappedf(rng.randf_range(10.0, minf(20.0, courtyard_width * 0.28)), 0.20)
	var keep_offset_z := snappedf(rng.randf_range(0.08, 0.25), 0.02)
	var uses_district_grid := profile == "grand_citadel" and (courtyard_width > 88.0 or courtyard_depth > 80.0)
	var route_sign := -1.0 if rng.randi_range(0, 1) == 0 else 1.0
	var palace_grammar := sample_castle_palace_grammar(seed, context, keep_width, keep_depth, floor_height, keep_storeys, palace_material_for_seed(seed, context))
	var entry_approach := castle_entry_approach_descriptor(courtyard_depth * keep_offset_z, keep_depth, palace_grammar)
	palace_grammar["entryApproach"] = entry_approach.duplicate(true)
	palace_grammar["entryApproachHash"] = JSON.stringify(entry_approach).sha256_text()
	var keep_center := Vector3(0.0, 0.0, courtyard_depth * keep_offset_z)
	var forecourt_layout := keep_palace_forecourt_layout(keep_center, keep_width, keep_depth, palace_grammar)
	palace_grammar["forecourtLayout"] = forecourt_layout.duplicate(true)
	palace_grammar["forecourtLayoutHash"] = JSON.stringify(forecourt_layout).sha256_text()
	var courtyard_grid := castle_courtyard_occupancy_lattice(courtyard_width, courtyard_depth, keep_width, keep_depth, keep_offset_z, gate_width, tower_span, uses_district_grid, route_sign, palace_grammar)
	# The courtyard is a filled, mirrored settlement lattice. Only the keep
	# footprint and the continuous gate-to-keep route are reserved; the remaining
	# flank cells are eligible for real shared residence recipes.  The exact
	# footprint gate is still resolved by CastleCompoundBlueprintBuilder, but the
	# density decision belongs here with the deterministic compound grammar.
	# A lattice one means real lot capacity. Larger compounds first fill the
	# complete perimeter row, then add a second, front-only pair of inner blocks.
	# The rear of a deep keep stays clear instead of forcing one last residence
	# into a space that cannot give its door a usable street.
	# A compact bailey has space for a single mirrored gate block only. A second
	# pair would either face a keep wall or turn the central route into a maze;
	# medium and grand compounds scale through planned perimeter and inner rows.
	var courtyard_building_count := 2 if profile == "compact_keep" else 6 if profile == "walled_bailey" else 12
	var courtyard_program := sample_district_castle_courtyard_program(rng, courtyard_grid) if uses_district_grid else sample_castle_courtyard_program(rng, courtyard_building_count, courtyard_width, courtyard_depth)
	if uses_district_grid:
		bind_district_courtyard_residence_recipes(seed, context, courtyard_width, courtyard_depth, courtyard_grid, courtyard_program)
	var citadel_masonry := sample_citadel_masonry_palette(seed, context)
	return {
		"profile": profile,
		"grandScale": grand_scale,
		"citadelMasonry": citadel_masonry,
		"courtyardWidth": courtyard_width,
		"courtyardDepth": courtyard_depth,
		"towerCount": tower_count,
		"towerSpan": tower_span,
		"towerHeightBase": snappedf(floor_height * float(base_keep_storeys) * rng.randf_range(0.72, 0.94), 0.20),
		"towerHeightVariation": snappedf(rng.randf_range(0.10, 0.26), 0.02),
		"wallHeight": wall_height,
		"keepWidth": keep_width,
		"keepDepth": keep_depth,
		"keepHeight": snappedf(floor_height * float(keep_storeys), 0.20),
		"keepBaseStoreys": base_keep_storeys,
		"keepStoreys": keep_storeys,
		"keepFootprintScale": keep_footprint_scale,
		"keepHeightScale": keep_height_scale,
		# The keep is on the gate centreline; only its depth position may vary.
		"keepOffset": {"x": 0.0, "z": keep_offset_z},
		"gateWidth": gate_width,
		"gateDepth": snappedf(rng.randf_range(8.0, 15.0), 0.20),
		"gateHeight": snappedf(wall_height + rng.randf_range(2.0, 5.2), 0.20),
		"towerPhase": rng.randi_range(0, 3),
		"palaceGrammar": palace_grammar,
		"courtyardGrid": courtyard_grid,
		"courtyardProgram": courtyard_program
	}


static func sample_castle_palace_grammar(seed: int, context: Dictionary, keep_width: float, keep_depth: float, floor_height: float, keep_storeys: int, palace_material: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	var palace_recipe_seed := stable_recipe_seed(seed, "castle.palace", context)
	rng.seed = palace_recipe_seed
	var plan_families: Array[String] = ["u_court", "offset_court", "e_court"]
	var plan_family := plan_families[rng.randi_range(0, plan_families.size() - 1)]
	var dominant_side := -1.0 if rng.randi_range(0, 1) == 0 else 1.0
	var plan_wing_depth_bias := 0.0 if plan_family == "u_court" else 0.10 if plan_family == "offset_court" else 0.16
	var plan_gallery_depth_bias := 0.0 if plan_family == "u_court" else -0.06 if plan_family == "offset_court" else 0.08
	var hall_roof_families: Array[String] = ["terraced_crown", "offset_crown", "court_pavilions"]
	var hall_roof_family := hall_roof_families[rng.randi_range(0, hall_roof_families.size() - 1)]
	if plan_family == "e_court":
		hall_roof_family = "court_pavilions"
	elif plan_family == "offset_court":
		hall_roof_family = "offset_crown"
	var dominant_gallery_depth_scale := snappedf(rng.randf_range(0.68, 0.84), 0.02)
	var secondary_gallery_depth_scale := snappedf(rng.randf_range(0.44, 0.64), 0.02)
	if plan_family == "e_court":
		dominant_gallery_depth_scale += 0.10
	if plan_family == "offset_court":
		secondary_gallery_depth_scale -= 0.08
	var hall_storeys := clampi(rng.randi_range(3, 4), 3, mini(4, keep_storeys))
	var wing_offset_left := snappedf(rng.randf_range(0.55, 0.62), 0.01)
	var wing_offset_right := snappedf(rng.randf_range(0.53, 0.60), 0.01)
	if dominant_side > 0.0:
		var swap_offset := wing_offset_left
		wing_offset_left = wing_offset_right
		wing_offset_right = swap_offset
	return {
		"schemaVersion": 2,
		"recipeSeed": palace_recipe_seed,
		"planFamily": plan_family,
		"palaceMaterial": palace_material,
		"dominantSide": dominant_side,
		"dominantWingDepthBias": plan_wing_depth_bias,
		"secondaryWingDepthBias": -0.04 if plan_family == "offset_court" else 0.0,
		"galleryDepthBias": plan_gallery_depth_bias,
		"dominantGalleryDepthScale": dominant_gallery_depth_scale,
		"secondaryGalleryDepthScale": maxf(0.34, secondary_gallery_depth_scale),
		"galleryArcadeShare": snappedf(rng.randf_range(0.42, 0.58), 0.02),
		"galleryFlareRatio": snappedf(rng.randf_range(0.05, 0.10), 0.01),
		"galleryPavilionDepthRatio": snappedf(rng.randf_range(0.28, 0.40), 0.02),
		"galleryPavilionHeightAdd": snappedf(rng.randf_range(1.4, 2.4), 0.20),
		"dominantWingForwardBias": snappedf(rng.randf_range(0.04, 0.10), 0.01) if plan_family != "u_court" else 0.0,
		"secondaryWingForwardBias": snappedf(rng.randf_range(-0.03, 0.03), 0.01),
		"hallStoreys": hall_storeys,
		"hallRoofRiseRatio": snappedf(rng.randf_range(0.17, 0.23), 0.01),
		"hallRoofFamily": hall_roof_family,
		"hallRoofCoreWidthRatio": snappedf(rng.randf_range(0.34, 0.46), 0.01),
		"hallRoofCoreDepthRatio": snappedf(rng.randf_range(0.38, 0.54), 0.01),
		"hallRoofCoreOffsetXRatio": snappedf(rng.randf_range(0.03, 0.10) * dominant_side, 0.01) if hall_roof_family == "offset_crown" else 0.0,
		"hallRoofCoreOffsetZRatio": snappedf(rng.randf_range(-0.10, 0.06), 0.01),
		"hallRoofCoreHeightAdd": snappedf(rng.randf_range(4.6, 7.8), 0.20),
		"hallRoofPavilionWidthRatio": snappedf(rng.randf_range(0.18, 0.26), 0.01),
		"hallRoofPavilionDepthRatio": snappedf(rng.randf_range(0.28, 0.40), 0.01),
		"hallRoofPavilionBaseHeight": snappedf(rng.randf_range(1.6, 2.6), 0.20),
		"hallRoofDominantPavilionHeight": snappedf(rng.randf_range(2.4, 4.2), 0.20),
		"hallRoofSecondaryPavilionHeight": snappedf(rng.randf_range(1.2, 2.4), 0.20),
		"hallRoofParapetHeight": snappedf(rng.randf_range(0.72, 1.18), 0.02),
		"upperWidthRatio": snappedf(rng.randf_range(0.31, 0.38), 0.01),
		"upperDepthRatio": snappedf(rng.randf_range(0.35, 0.43), 0.01),
		"upperOffsetXRatio": snappedf(rng.randf_range(0.05, 0.11) * dominant_side, 0.01),
		"upperOffsetZRatio": snappedf(rng.randf_range(0.01, 0.06), 0.01),
		"entranceBayWidthRatio": snappedf(rng.randf_range(0.22, 0.28), 0.01),
		"entranceBayDepthRatio": snappedf(rng.randf_range(0.07, 0.12), 0.01),
		"entranceBayHeightRatio": snappedf(rng.randf_range(0.76, 0.88), 0.02),
		"entranceTowerWidthRatio": snappedf(rng.randf_range(0.38, 0.50), 0.01),
		"entranceTowerDepthRatio": snappedf(rng.randf_range(0.08, 0.14), 0.01),
		"entranceTowerHeightAdd": snappedf(rng.randf_range(1.4, 3.4), 0.20),
		"entranceTowerRoofRise": snappedf(rng.randf_range(3.6, 5.4), 0.20),
		"entrancePortalHeightRatio": snappedf(rng.randf_range(0.48, 0.62), 0.01),
		"entrancePortalWidthRatio": snappedf(rng.randf_range(0.48, 0.60), 0.01),
		"entranceApproachWidthAdd": snappedf(rng.randf_range(1.6, 3.0), 0.20),
		"facadeBayCount": rng.randi_range(2, 4),
		"facadeWindowLevelCount": rng.randi_range(2, 3),
		"facadeStringCourseCount": rng.randi_range(2, 3),
		"entranceFlankStepRatio": snappedf(rng.randf_range(0.10, 0.15), 0.01),
		"rotundaRootWidthRatio": snappedf(rng.randf_range(0.24, 0.31), 0.01),
		"rotundaRootProjectionRatio": snappedf(rng.randf_range(0.04, 0.08), 0.01),
		"frontTowerSpanRatio": snappedf(rng.randf_range(0.17, 0.21), 0.01),
		"frontTowerDominantHeight": snappedf(rng.randf_range(4.2, 6.4), 0.20),
		"frontTowerSecondaryHeight": snappedf(rng.randf_range(-3.0, -1.4), 0.20),
		"wingWidthRatio": snappedf(rng.randf_range(0.62, 0.72), 0.01),
		"wingDepthRatio": snappedf(rng.randf_range(0.62, 0.73), 0.01),
		"wingHeightRatio": snappedf(rng.randf_range(0.68, 0.78), 0.01),
		"wingOffsetLeftRatio": wing_offset_left,
		"wingOffsetRightRatio": wing_offset_right,
		"wingZRatio": snappedf(rng.randf_range(-0.20, -0.11), 0.01),
		"wingZAsymmetry": snappedf(rng.randf_range(0.8, 1.8), 0.20),
		"pavilionSpanRatio": snappedf(rng.randf_range(0.36, 0.44), 0.01),
		"pavilionHeightAdd": snappedf(rng.randf_range(1.8, 2.8), 0.20),
		"domeOffsetZRatio": snappedf(rng.randf_range(-0.12, -0.06), 0.01),
		"drumSpanRatio": snappedf(rng.randf_range(1.28, 1.44), 0.02),
		"drumHeightRatio": snappedf(rng.randf_range(0.52, 0.68), 0.02),
		"drumSeatOverlap": snappedf(rng.randf_range(0.16, 0.34), 0.02),
		"domeTierCount": rng.randi_range(8, 10),
		"domeTierStep": snappedf(rng.randf_range(0.62, 0.76), 0.02),
		"domeTwist": rng.randi_range(0, 1) == 1,
		"courtWidthRatio": snappedf(rng.randf_range(0.52, 0.62), 0.02),
		"courtDepthRatio": snappedf(rng.randf_range(0.22, 0.30), 0.02),
		"galleryDepthRatio": snappedf(rng.randf_range(0.32, 0.41), 0.01),
		"galleryXRatio": snappedf(rng.randf_range(0.32, 0.38), 0.01),
		"galleryWidthRatio": snappedf(rng.randf_range(0.18, 0.23), 0.01),
		"galleryHeight": snappedf(rng.randf_range(4.4, 5.4), 0.20),
		"galleryBayCount": rng.randi_range(4, 6),
		"connectorHeightRatio": snappedf(rng.randf_range(0.48, 0.60), 0.02),
		"connectorDepthRatio": snappedf(rng.randf_range(0.42, 0.58), 0.02),
		"entryStepCount": rng.randi_range(3, 5),
		"rearCourtDepthRatio": snappedf(rng.randf_range(0.18, 0.28), 0.02),
		"rearPorticoWidthRatio": snappedf(rng.randf_range(0.30, 0.42), 0.02),
		"rearServiceWingBias": snappedf(rng.randf_range(0.04, 0.12), 0.02),
		"rearCrossWingWidthRatio": snappedf(rng.randf_range(0.25, 0.34), 0.02),
		"rearCrossWingDepthRatio": snappedf(rng.randf_range(0.42, 0.58), 0.02),
		"rearCrossWingHeightRatio": snappedf(rng.randf_range(0.46, 0.62), 0.02),
		"endPavilionDepthRatio": snappedf(rng.randf_range(0.38, 0.52), 0.02),
		"endPavilionInsetRatio": snappedf(rng.randf_range(0.06, 0.14), 0.02),
		"approachLengthRatio": snappedf(rng.randf_range(0.34, 0.48), 0.02),
		"courtWallHeight": snappedf(rng.randf_range(2.4, 3.2), 0.10),
		"sideBayCount": rng.randi_range(2, 4),
		"centralWindowColumns": [5, 7][rng.randi_range(0, 1)],
		"wingWindowColumns": rng.randi_range(3, 5),
		"rearWindowColumns": rng.randi_range(4, 6),
		"wingEndWindowColumns": rng.randi_range(2, 3),
		"hallSideWindowColumns": rng.randi_range(3, 5),
		"floorHeight": floor_height,
		"sourceKeepSize": Vector2(keep_width, keep_depth)
	}


static func masonry_palette_residence_material(palette: Dictionary) -> String:
	var residence_materials: Array = palette.get("residences", []) as Array
	for material_value in residence_materials:
		if String(material_value) == "painted_brick_cream":
			return "painted_brick_cream"
	return String(residence_materials[0]) if not residence_materials.is_empty() else "painted_brick_cream"


static func palace_material_for_seed(seed: int, context: Dictionary) -> String:
	return "aged_castle_stone"


static func sample_citadel_masonry_palette(seed: int, context: Dictionary) -> Dictionary:
	# This isolated seed stream avoids perturbing spatial grammar when a new
	# palette is added. A citadel owns a consistent civic masonry colour while
	# its homes may use the related facade colours with individual personality.
	var rng := RandomNumberGenerator.new()
	rng.seed = stable_recipe_seed(seed, "castle.masonry", context)
	var palettes: Array[Dictionary] = [
		{"fortification": "painted_brick_ochre", "residences": ["painted_brick_ochre", "painted_brick_cream", "painted_brick_rose", "painted_brick_sage"]},
		{"fortification": "painted_brick_sage", "residences": ["painted_brick_sage", "painted_brick_cream", "painted_brick_ochre", "painted_brick_azure"]},
		{"fortification": "painted_brick_azure", "residences": ["painted_brick_azure", "painted_brick_cream", "painted_brick_plum", "painted_brick_rose"]},
		{"fortification": "painted_brick_rose", "residences": ["painted_brick_rose", "painted_brick_cream", "painted_brick_ochre", "painted_brick_plum"]},
		{"fortification": "painted_brick_plum", "residences": ["painted_brick_plum", "painted_brick_cream", "painted_brick_azure", "painted_brick_sage"]}
	]
	return (palettes[rng.randi_range(0, palettes.size() - 1)] as Dictionary).duplicate(true)


static func sample_castle_courtyard_program(rng: RandomNumberGenerator, count: int, courtyard_width: float, courtyard_depth: float) -> Array[Dictionary]:
	# Each graph node is one mirrored pair of eligible cells in the occupancy
	# lattice.  The central x=0 column is intentionally absent: it is the real
	# axial walk from the operable gate to the keep entry.  Increasing scale adds
	# more paired flank cells instead of broadening a single authored building.
	# The city planner fills perimeter blocks before adding front inner blocks.
	# It never first-fits a house into an arbitrary gap or treats a deep keep's
	# rear clearance as a spare residential lot.
	var graph_nodes: Array[String] = []
	if count <= 4:
		# A compact bailey has only two legal perimeter blocks. Place one behind
		# the gate and one on the rear wall instead of squeezing both against the
		# keep's front corners.
		graph_nodes = ["gate_outer", "rear_outer"]
	elif count <= 6:
		graph_nodes = ["gate_outer", "middle_outer", "rear_outer"]
	else:
		graph_nodes = ["gate_outer", "lower_outer", "middle_outer", "rear_outer", "gate_inner", "lower_inner"]
	var kinds: Array[String] = ["barracks", "workshop", "granary", "stable", "storehouse", "chapel"]
	var pair_count := mini(count / 2, graph_nodes.size())
	var program: Array[Dictionary] = []
	for pair_index in range(pair_count):
		# All profiles fill their sampled capacity in a stable inner-to-outer order.
		# Seeded dimensions and use still vary; only the shared settlement topology
		# stays fixed enough to preserve the gate-to-keep public axis.
		var graph_node := graph_nodes[pair_index]
		var kind := kinds[(pair_index * 3 + rng.randi_range(0, kinds.size() - 1)) % kinds.size()]
		var width := snappedf(clampf(courtyard_width * rng.randf_range(0.11, 0.17), 7.0, 16.0), 0.20)
		var depth := snappedf(clampf(courtyard_depth * rng.randf_range(0.10, 0.17), 6.0, 13.0), 0.20)
		var height := snappedf(rng.randf_range(3.6, 5.4), 0.20)
		if kind == "granary":
			height += 1.40
		elif kind == "chapel":
			height += 3.00
		elif kind == "barracks":
			width = minf(16.0, width * 1.16)
		var group_id := "courtyard_pair_%02d" % (pair_index + 1)
		var roof_rise := snappedf(rng.randf_range(1.25, 2.70), 0.10)
		var variation := snappedf(rng.randf_range(-0.025, 0.025), 0.005)
		for mirror_side in ["left", "right"]:
			program.append({
				"id": "courtyard_%s_%02d_%s" % [kind, pair_index + 1, mirror_side],
				"kind": kind,
				"slot": "%s_%s" % [graph_node, mirror_side],
				"graphNode": graph_node,
				"symmetryGroup": group_id,
				"mirrorSide": mirror_side,
				"width": width,
				"depth": depth,
				"height": height,
				"roofRise": roof_rise,
				"variation": variation
			})
	return program


static func sample_district_castle_courtyard_program(rng: RandomNumberGenerator, grid: Dictionary) -> Array[Dictionary]:
	# A citadel district is built from explicit symmetric lots around a real
	# street graph. The keep only removes cells that physically overlap it; its
	# width is not projected as a dead strip all the way to the gate.
	var lot_pairs: Array = grid.get("lotPairs", []) as Array
	var kinds: Array[String] = ["barracks", "workshop", "granary", "stable", "storehouse", "chapel"]
	var program: Array[Dictionary] = []
	for pair_index in range(lot_pairs.size()):
		if not lot_pairs[pair_index] is Dictionary:
			continue
		var lot_pair: Dictionary = lot_pairs[pair_index] as Dictionary
		var kind := kinds[(pair_index * 5 + rng.randi_range(0, kinds.size() - 1)) % kinds.size()]
		var group_id := "courtyard_pair_%03d" % (pair_index + 1)
		var left_center_x := float(lot_pair.get("leftCenterX", lot_pair.get("centerX", 0.0)))
		var right_center_x := float(lot_pair.get("rightCenterX", -left_center_x))
		var left_center_z := float(lot_pair.get("leftCenterZ", lot_pair.get("centerZ", 0.0)))
		var right_center_z := float(lot_pair.get("rightCenterZ", lot_pair.get("centerZ", 0.0)))
		var band_index := int(lot_pair.get("bandIndex", 0))
		var row_index := int(lot_pair.get("rowIndex", 0))
		var neighbourhood := int(lot_pair.get("neighbourhood", 0))
		var district_class := String(lot_pair.get("districtClass", "golden_lane"))
		var left_district_class := String(lot_pair.get("leftDistrictClass", district_class))
		var right_district_class := String(lot_pair.get("rightDistrictClass", district_class))
		var terrace_elevation := float(lot_pair.get("terraceElevation", 0.0))
		var front_direction_left := String(lot_pair.get("frontDirectionLeft", "east"))
		var front_direction_right := String(lot_pair.get("frontDirectionRight", "west"))
		for mirror_side in ["left", "right"]:
			program.append({
					"id": "courtyard_%s_%03d_%s" % [kind, pair_index + 1, mirror_side],
					"kind": kind,
					"slot": "district_band_%02d_row_%02d_%s" % [band_index, row_index, mirror_side],
					"graphNode": "district_band_%02d_row_%02d" % [band_index, row_index],
					"symmetryGroup": group_id,
					"mirrorSide": mirror_side,
					"cityGridMode": "district",
					"cityGridBand": "district_%02d" % band_index,
					"cityGridPairIndex": pair_index,
					"cityGridRow": row_index,
					"cityGridColumn": int(lot_pair.get("leftColumn", band_index)) if mirror_side == "left" else int(lot_pair.get("rightColumn", band_index)),
					"neighbourhood": neighbourhood,
					"districtClass": left_district_class if mirror_side == "left" else right_district_class,
					"terraceElevation": terrace_elevation,
					"frontDirection": front_direction_left if mirror_side == "left" else front_direction_right,
					"gridCenterX": left_center_x if mirror_side == "left" else right_center_x,
					"gridCenterZ": left_center_z if mirror_side == "left" else right_center_z,
					"lotPitchX": float(lot_pair.get("lotPitchX", grid.get("cellSpacing", 28.0))),
					"lotPitchZ": float(grid.get("cellSpacing", 28.0)),
					"width": float(lot_pair.get("lotPitchX", grid.get("cellSpacing", 28.0))) - 1.2,
					"depth": float(grid.get("cellSpacing", 28.0)) - 4.0,
					"height": 4.0,
					"roofRise": snappedf(rng.randf_range(1.25, 2.70), 0.10),
					"variation": snappedf(rng.randf_range(-0.025, 0.025), 0.005)
				})
	return program


static func bind_district_courtyard_residence_recipes(castle_seed: int, context: Dictionary, courtyard_width: float, courtyard_depth: float, grid: Dictionary, program: Array[Dictionary]) -> void:
	# The sampler owns deterministic semantic identity and complete recipes, but
	# these centres remain nominal placement intents. Exact physical placement is
	# resolved later from the real source blueprints and constructed keep parts.
	var lot_pairs: Array = grid.get("lotPairs", []) as Array
	if program.size() != lot_pairs.size() * 2:
		return
	for pair_index in range(lot_pairs.size()):
		if not lot_pairs[pair_index] is Dictionary:
			continue
		var pair: Dictionary = lot_pairs[pair_index] as Dictionary
		for side_index in range(2):
			var side := "left" if side_index == 0 else "right"
			var source_index := pair_index * 2 + side_index
			if not program[source_index] is Dictionary:
				continue
			var source: Dictionary = program[source_index] as Dictionary
			var residence := sample_courtyard_residence(castle_seed, source, courtyard_width, courtyard_depth, context)
			var family := String(residence.get("family", ""))
			var recipe: Dictionary = residence.get("recipe", {}) as Dictionary
			var recipe_hash := courtyard_residence_recipe_hash(family, recipe)
			var intent_id := String(source.get("id", ""))
			source["placementIntentId"] = intent_id
			source["placementOrdinal"] = source_index
			source["placementMode"] = "post_geometry_exact"
			source["residenceFamily"] = family
			source["residenceRecipe"] = recipe.duplicate(true)
			source["residenceRecipeHash"] = recipe_hash
			pair["%sResidenceFamily" % side] = family
			pair["%sResidenceRecipe" % side] = recipe.duplicate(true)
			pair["%sResidenceRecipeHash" % side] = recipe_hash
			pair["%sPlacementIntentId" % side] = intent_id
	grid["lotPairs"] = lot_pairs
	grid["lotPairCount"] = lot_pairs.size()


static func courtyard_residence_recipe_hash(family: String, recipe: Dictionary) -> String:
	return (family + "\n" + JSON.stringify(recipe)).sha256_text()


static func sample_courtyard_residence(castle_seed: int, source: Dictionary, courtyard_width: float, courtyard_depth: float, context: Dictionary) -> Dictionary:
	# Stable, source-scoped RNG keeps residence work from perturbing the castle
	# grammar stream. The resulting recipe is part of placement authority.
	var node := String(source.get("graphNode", "gate_inner"))
	var residence_seed := int(("%d|castle.courtyard.residence|%s" % [castle_seed, String(source.get("symmetryGroup", "pair"))]).hash())
	var supports_manor := courtyard_width >= 76.0 and courtyard_depth >= 66.0 and node == "middle_outer"
	if supports_manor:
		var manor_context := context.duplicate(true)
		manor_context["settlementTier"] = "city"
		manor_context["siteKey"] = "castle-courtyard"
		manor_context["style"] = "masonry"
		return {"family": "manor", "recipe": courtyard_manor_recipe(sample(residence_seed, "manor", manor_context))}
	if String(source.get("cityGridMode", "")) == "district":
		var district_rng := RandomNumberGenerator.new()
		district_rng.seed = int(("%d|castle.district.wealthy.family" % residence_seed).hash())
		var district_class := String(source.get("districtClass", ""))
		var manor_chance := 1.0 if district_class == "sightline_screen" else 0.0 if district_class == "civic_anchor" else 0.20 if district_class == "golden_lane" else 0.82 if district_class == "civic" else 0.58 if district_class == "wealthy" else 0.0
		if district_rng.randf() < manor_chance:
			var manor_context := context.duplicate(true)
			manor_context["settlementTier"] = "city"
			manor_context["siteKey"] = "castle-%s-district" % district_class
			manor_context["style"] = "masonry"
			return {"family": "manor", "recipe": district_manor_recipe(sample(residence_seed, "manor", manor_context), source)}
	var cottage_recipe := CottageRecipeSamplerScript.sample(residence_seed, "masonry")
	if String(source.get("cityGridMode", "")) == "district":
		cottage_recipe = district_cottage_recipe(cottage_recipe, source, residence_seed)
	return {"family": "cottage", "recipe": cottage_recipe}


static func district_cottage_recipe(raw_recipe: Dictionary, source: Dictionary, residence_seed: int) -> Dictionary:
	var recipe := raw_recipe.duplicate(true)
	var lot_width := float(source.get("width", 24.0))
	var lot_depth := float(source.get("depth", 24.0))
	var district_class := String(source.get("districtClass", "district"))
	var east_west_frontage := String(source.get("frontDirection", "")) in ["east", "west"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(("%d|castle.district.cottage.lot" % residence_seed).hash())
	if district_class == "golden_lane":
		recipe["width"] = snappedf(clampf((lot_depth if east_west_frontage else lot_width) * rng.randf_range(0.95, 0.99), 11.8, 12.8), 0.20)
		recipe["depth"] = snappedf(clampf((lot_width if east_west_frontage else lot_depth) * rng.randf_range(0.78, 0.86), 8.8, 13.8), 0.20)
	else:
		recipe["width"] = snappedf(clampf((lot_depth if east_west_frontage else lot_width) * rng.randf_range(0.94, 0.98), 11.6, 12.8), 0.20)
		recipe["depth"] = snappedf(clampf((lot_width if east_west_frontage else lot_depth) * rng.randf_range(0.72, 0.82), 9.8, 14.8), 0.20)
	var floor_height := float(recipe.get("floorHeight", 3.45))
	if district_class == "civic_anchor":
		recipe["width"] = snappedf(clampf(float(recipe.get("width", 10.0)), 8.8, 10.6), 0.20)
		recipe["depth"] = snappedf(clampf(float(recipe.get("depth", 8.0)), 7.0, 8.8), 0.20)
	var floor_count := 2 if district_class == "civic_anchor" else 3 if district_class == "civic" or (district_class == "golden_lane" and rng.randf() < 0.34) else 2
	recipe["floorCount"] = floor_count
	recipe["wallHeight"] = snappedf(floor_height * float(floor_count), 0.05)
	recipe["districtLot"] = district_class
	return recipe


static func district_manor_recipe(raw_recipe: Dictionary, source: Dictionary) -> Dictionary:
	var recipe := raw_recipe.duplicate(true)
	var floor_height := float(recipe.get("floorHeight", 3.55))
	var lot_width := float(source.get("width", 28.0))
	var lot_depth := float(source.get("depth", 16.0))
	var district_class := String(source.get("districtClass", ""))
	var east_west_frontage := String(source.get("frontDirection", "")) in ["east", "west"]
	var is_golden_lane := district_class == "golden_lane"
	var frontage_ratio := 0.98 if is_golden_lane else 0.88 if district_class == "sightline_screen" else 0.72
	var depth_ratio := 0.82
	var source_width_limit := lot_width * 0.98 if district_class == "sightline_screen" else float(recipe.get("width", 16.0))
	recipe["width"] = snappedf(minf(source_width_limit, (lot_depth if east_west_frontage else lot_width) * (0.98 if east_west_frontage else frontage_ratio)), 0.20)
	recipe["depth"] = snappedf(minf(float(recipe.get("depth", 12.0)), (lot_width if east_west_frontage else lot_depth) * (0.92 if district_class == "sightline_screen" else depth_ratio)), 0.20)
	recipe["floorCount"] = 3 if district_class == "sightline_screen" or district_class == "civic_anchor" else mini(3, maxi(2, int(recipe.get("floorCount", 2))))
	recipe["wallHeight"] = snappedf(floor_height * float(recipe["floorCount"]), 0.05)
	recipe["districtLot"] = "golden_lane_manor" if is_golden_lane else "wealthy_manor"
	return recipe


static func courtyard_manor_recipe(raw_recipe: Dictionary) -> Dictionary:
	var recipe := raw_recipe.duplicate(true)
	var floor_height := float(recipe.get("floorHeight", 3.55))
	var floor_count := mini(2, maxi(2, int(recipe.get("floorCount", 2))))
	recipe["width"] = minf(float(recipe.get("width", 16.0)), 14.00)
	recipe["depth"] = minf(float(recipe.get("depth", 12.0)), 10.00)
	recipe["floorCount"] = floor_count
	recipe["wallHeight"] = snappedf(floor_height * float(floor_count), 0.05)
	recipe["castleCourtyardLot"] = "compact_manor"
	return recipe


static func keep_palace_forecourt_layout(center: Vector3, width: float, depth: float, palace_grammar: Dictionary) -> Array[Dictionary]:
	var front_z := center.z - depth * 0.5
	var base_gallery_depth := clampf(depth * (float(palace_grammar.get("galleryDepthRatio", 0.36)) + float(palace_grammar.get("galleryDepthBias", 0.0))), 7.0, 14.0)
	var gallery_x := width * float(palace_grammar.get("galleryXRatio", 0.34))
	var gallery_width := clampf(width * float(palace_grammar.get("galleryWidthRatio", 0.20)), 4.8, 6.4)
	var gallery_height := maxf(5.8, float(palace_grammar.get("galleryHeight", 4.8)))
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	var arcade_share := float(palace_grammar.get("galleryArcadeShare", 0.50))
	var flare_ratio := float(palace_grammar.get("galleryFlareRatio", 0.07))
	var result: Array[Dictionary] = []
	for side in [-1.0, 1.0]:
		var depth_scale := float(palace_grammar.get("dominantGalleryDepthScale", 0.78)) if side == dominant_side else float(palace_grammar.get("secondaryGalleryDepthScale", 0.54))
		var gallery_depth := base_gallery_depth * depth_scale
		var arcade_depth := gallery_depth * arcade_share
		var pavilion_depth := maxf(2.8, gallery_depth * float(palace_grammar.get("galleryPavilionDepthRatio", 0.34)))
		var gallery_center := Vector3(center.x + side * gallery_x, 0.0, front_z - arcade_depth * 0.5)
		var outer_flare: float = side * width * flare_ratio * (1.0 if side == dominant_side else 0.72)
		var pavilion_center := Vector3(gallery_center.x + outer_flare, 0.0, front_z - arcade_depth - pavilion_depth * 0.5 + 0.30)
		var gallery_bay_count := maxi(2, roundi(float(palace_grammar.get("galleryBayCount", 5)) * depth_scale * arcade_share + 0.5))
		var pavilion_height := gallery_height + float(palace_grammar.get("galleryPavilionHeightAdd", 1.8)) * (1.0 if side == dominant_side else 0.72)
		var pavilion_width := gallery_width * (1.12 if side == dominant_side else 0.94)
		result.append({
			"side": side,
			"galleryCenter": gallery_center,
			"galleryWidth": gallery_width,
			"galleryHeight": gallery_height,
			"arcadeDepth": arcade_depth,
			"galleryBayCount": gallery_bay_count,
			"pavilionCenter": pavilion_center,
			"pavilionDepth": pavilion_depth,
			"pavilionHeight": pavilion_height,
			"pavilionWidth": pavilion_width,
			"galleryFootprint": {"center": gallery_center, "width": gallery_width, "depth": arcade_depth},
			"pavilionFootprint": {"center": pavilion_center, "width": pavilion_width + 0.36, "depth": pavilion_depth + 0.36}
		})
	return result


static func castle_courtyard_occupancy_lattice(courtyard_width := 0.0, courtyard_depth := 0.0, keep_width := 0.0, keep_depth := 0.0, keep_offset_z := 0.0, gate_width := 0.0, tower_span := 0.0, district_grid := false, route_sign := 1.0, palace_grammar: Dictionary = {}) -> Dictionary:
	if district_grid:
		# Grand citadels use a processional graph rather than a centred boulevard.
		# The route makes two deterministic turns: the first terminates the gate view
		# on a civic facade, and the second returns to the palace axis only at the
		# forecourt. Lots derive from the route, so buildings, paving and terraces
		# share one authority across seeds and scales.
		var cell_spacing := 13.0
		var half_width := courtyard_width * 0.5
		var half_depth := courtyard_depth * 0.5
		var route_half_width := clampf(gate_width * 0.17, 2.65, 3.35)
		var boulevard_half_width := route_half_width
		var outer_center_limit := half_width - tower_span * 0.5 - 5.2
		var front_center := -half_depth + tower_span * 0.5 + 2.8 + cell_spacing * 0.5
		var rear_center_limit := half_depth - tower_span * 0.5 - 5.0 - cell_spacing * 0.5
		var row_centers: Array[float] = []
		var row_index := 0
		while true:
			var row_z := front_center + float(row_index) * cell_spacing
			if row_z > rear_center_limit + 0.01:
				break
			row_centers.append(row_z)
			row_index += 1
		var rows := row_centers.size()
		var terrace_step_height := 1.80
		var keep_center_z := courtyard_depth * keep_offset_z
		var keep_front_z := keep_center_z - keep_depth * 0.5
		var entry_approach: Dictionary = palace_grammar.get("entryApproach", {}) as Dictionary
		var palace_entry_route_terminal_z := float(entry_approach["routeTerminalZ"])
		var turn_offset := route_sign * clampf(courtyard_width * 0.15, 12.0, 17.0)
		var first_turn_z := float(row_centers[0]) + cell_spacing * 0.15 if not row_centers.is_empty() else -courtyard_depth * 0.30
		var final_turn_z := keep_front_z - clampf(keep_depth * 0.45, 10.0, 14.0)
		var stair_run := 7.0 * 0.48
		var processional_tread_half_depth := 0.26
		var entry_ramp_start_z := float(entry_approach["rampStartZ"])
		var second_stair_end_z := entry_ramp_start_z
		# add_citadel_processional_steps places its final tread one nominal tread
		# behind the supplied centre. Its physical front edge is therefore centre
		# minus 0.22m (0.48m tread with 0.04m overlap).
		var second_stair_center_z := second_stair_end_z + 0.22
		var second_stair_start_z := second_stair_center_z - stair_run - processional_tread_half_depth
		# The turn must clear the first physical tread. Otherwise the street
		# publisher correctly removes its overlapping roadbed and leaves a gap at
		# the turn's forward edge. This keeps the route ordered: turn -> roadbed
		# -> stairs -> forecourt.
		final_turn_z = minf(final_turn_z, second_stair_start_z - route_half_width)
		var route_centers: Array[float] = []
		for resolved_row_index in range(rows):
			var row_z := float(row_centers[resolved_row_index])
			route_centers.append(0.0 if row_z < first_turn_z else turn_offset if row_z < final_turn_z else 0.0)
		var bands_per_side := 1
		var columns := bands_per_side * 2 + 1
		var cells: Array = []
		var lot_pairs: Array[Dictionary] = []
		var street_records: Array[Dictionary] = []
		var keep_min_z := keep_center_z - keep_depth * 0.5 - cell_spacing * 0.42
		var keep_max_z := keep_center_z + keep_depth * 0.5 + cell_spacing * 0.42
		var palace_approach_min_z := keep_center_z - keep_depth * 0.5 - clampf(keep_depth * 0.72, 14.0, 22.0)
		for resolved_row_index in range(rows):
			var resolved_row_z := row_centers[resolved_row_index]
			var lane_x := route_centers[resolved_row_index]
			var row: Array[int] = []
			for column in range(columns):
				row.append(0)
			for band_index in range(bands_per_side):
				var at_first_node := resolved_row_z <= first_turn_z and first_turn_z - resolved_row_z < cell_spacing * 0.90
				var at_final_node := absf(resolved_row_z - final_turn_z) < cell_spacing * 0.55
				var at_route_node := at_first_node or at_final_node
				var district_class := "civic_anchor" if at_first_node else "civic" if at_final_node or resolved_row_z >= first_turn_z else "golden_lane"
				var lot_pitch := 17.5 if district_class == "civic_anchor" else 14.5 if district_class == "golden_lane" else 16.5
				# The route reservation includes the transformed source blueprint's
				# roof eaves, not just its wall footprint. This keeps the live player,
				# NPC motor and review camera out of apparently open but roof-covered
				# space after east/west rotation.
				var center_offset := route_half_width + (7.8 if at_first_node else 9.0) + float(band_index) * 14.2
				var left_center_x := lane_x - center_offset
				var right_center_x := lane_x + center_offset
				var left_center_z := resolved_row_z
				var right_center_z := resolved_row_z
				var left_district_class := district_class
				var right_district_class := district_class
				var front_direction_left := "east"
				var front_direction_right := "west"
				if at_first_node:
					# The first civic pair forms the inhabited gate court. Its public
					# fronts face arriving players so doors, awnings and trade counters
					# establish city life before the processional route turns inland.
					front_direction_left = "north"
					front_direction_right = "west" if route_sign > 0.0 else "east"
					var gate_room_depth := cell_spacing * 0.08
					left_center_z += gate_room_depth
					right_center_z += gate_room_depth
					left_center_x -= route_sign * 1.6
					# The route-facing shop sits beyond the *entire* horizontal turn,
					# not merely beyond the lane centre. Its reserved lot envelope must
					# leave enough room for its transformed floor/eaves and the shared
					# player/NPC motor corridor on either sign of the generated bend.
					var turn_outer_edge := turn_offset + route_sign * route_half_width
					var lot_clearance := lot_pitch * 0.5 + 1.50
					if route_sign > 0.0:
						right_center_x = maxf(right_center_x, turn_outer_edge + lot_clearance)
					else:
						left_center_x = minf(left_center_x, turn_outer_edge - lot_clearance)
				if band_index == 1:
					left_center_x = maxf(-outer_center_limit, left_center_x)
					right_center_x = minf(outer_center_limit, right_center_x)
				if resolved_row_z >= palace_approach_min_z and resolved_row_z <= keep_max_z and (absf(left_center_x) < keep_width * 0.5 + 12.0 or absf(right_center_x) < keep_width * 0.5 + 12.0):
					# The palace removes only its inner approach lots. Repack the remaining
					# court edge with shallow civic frontage instead of discarding the
					# entire row inherited from the coarse lattice.
					var court_edge_x := minf(outer_center_limit, keep_width * 0.5 + 15.0)
					left_center_x = -court_edge_x
					right_center_x = court_edge_x
					district_class = "civic_anchor" if at_first_node else "civic"
					left_district_class = district_class
					right_district_class = district_class
					lot_pitch = 17.5 if district_class == "civic_anchor" else 16.5
				if at_final_node:
					# The middle street terminates on one inhabited civic facade. Its
					# broad, tall ordinary manor occupies the diagonal sightline between
					# the incoming lane and palace axis. It stays north of the horizontal
					# turn, so the player clears its corner before the palace reopens.
					var screen_z := final_turn_z + cell_spacing * 0.48
					# Derive the diagonal screen from both the bent route and palace span.
					# Its inner edge should reveal a narrow slice of the central palace at
					# the final turn, then clear fully on the axial approach. A fixed route
					# fraction either hides the palace completely or exposes it too early as
					# generated keep widths vary.
					var screen_offset := maxf(0.0, minf(absf(turn_offset), keep_width * 0.52) - 1.30)
					var screen_x := route_sign * screen_offset
					if route_sign > 0.0:
						right_center_x = screen_x
						right_center_z = screen_z
						right_district_class = "sightline_screen"
						front_direction_right = "south"
					else:
						left_center_x = screen_x
						left_center_z = screen_z
						left_district_class = "sightline_screen"
						front_direction_left = "south"
				var left_column := band_index
				var right_column := columns - 1 - band_index
				row[left_column] = 1
				row[right_column] = 1
				lot_pairs.append({
					"bandIndex": band_index,
					"districtClass": district_class,
					"lotPitchX": lot_pitch,
					"rowIndex": resolved_row_index,
					"neighbourhood": resolved_row_index,
					"leftColumn": left_column,
					"rightColumn": right_column,
					"leftCenterX": left_center_x,
					"rightCenterX": right_center_x,
					"leftCenterZ": left_center_z,
					"rightCenterZ": right_center_z,
					"centerZ": resolved_row_z,
					"leftDistrictClass": left_district_class,
					"rightDistrictClass": right_district_class,
					"terraceElevation": 0.0 if resolved_row_z < first_turn_z else terrace_step_height if resolved_row_z < final_turn_z else terrace_step_height * 2.0,
					"frontDirectionLeft": front_direction_left,
					"frontDirectionRight": front_direction_right
				})
			cells.append(row)
		var boulevard_front_z := -half_depth + tower_span * 0.5 + 1.0
		var first_transition_index := 0
		var second_transition_index := maxi(0, row_centers.size() - 1)
		for transition_index in range(row_centers.size()):
			var transition_z := float(row_centers[transition_index])
			if transition_z >= first_turn_z and first_transition_index == 0:
				first_transition_index = transition_index
			if transition_z >= final_turn_z:
				second_transition_index = transition_index
				break
		var first_stair_center_z := float(row_centers[first_transition_index]) - 1.6
		var first_stair_start_z := first_stair_center_z - stair_run
		# The entry landing is the single owner of the final processional seam.
		# The compound builder consumes this same centre override when publishing
		# the real stair geometry.
		var processional_step_centers := {str(second_transition_index): second_stair_center_z}
		street_records.append({"id": "processional_00_gate_lane", "x": 0.0, "z": (boulevard_front_z + first_turn_z) * 0.5, "width": route_half_width * 2.0, "depth": first_turn_z - boulevard_front_z, "elevation": 0.0})
		street_records.append({"id": "processional_01_first_turn", "x": turn_offset * 0.5, "z": first_turn_z, "width": absf(turn_offset) + route_half_width * 2.0, "depth": route_half_width * 2.0, "elevation": 0.0})
		street_records.append({"id": "processional_02a_civic_approach", "x": turn_offset, "z": (first_turn_z + first_stair_start_z) * 0.5, "width": route_half_width * 2.0, "depth": maxf(0.2, first_stair_start_z - first_turn_z), "elevation": 0.0})
		street_records.append({"id": "processional_02b_civic_climb", "x": turn_offset, "z": (first_stair_center_z + final_turn_z) * 0.5, "width": route_half_width * 2.0, "depth": maxf(0.2, final_turn_z - first_stair_center_z), "elevation": terrace_step_height})
		street_records.append({"id": "processional_03_final_turn", "x": turn_offset * 0.5, "z": final_turn_z, "width": absf(turn_offset) + route_half_width * 2.0, "depth": route_half_width * 2.0, "elevation": terrace_step_height})
		var final_stair_owner_ids: Array[String] = []
		for final_stair_step_index in range(1, 8):
			final_stair_owner_ids.append("castle_terrace_stair_%02d_%02d" % [second_transition_index, final_stair_step_index])
		street_records.append({"id": "processional_04a_palace_approach", "x": 0.0, "z": (final_turn_z + second_stair_start_z) * 0.5, "width": route_half_width * 2.0, "depth": maxf(0.2, second_stair_start_z - final_turn_z), "elevation": terrace_step_height, "allowedTransitionOwnerIds": final_stair_owner_ids, "handoffSeamZ": second_stair_start_z, "handoffTransitionOwnerId": String(final_stair_owner_ids.front()), "handoffTransitionSemantic": "castle_processional_step"})
		street_records.append({"id": "processional_04b_palace_reveal", "x": 0.0, "z": (second_stair_start_z + second_stair_end_z) * 0.5, "width": route_half_width * 2.0, "depth": maxf(0.2, second_stair_end_z - second_stair_start_z), "elevation": terrace_step_height * 2.0, "routeDestination": "palace_entry_stairs", "transitionOwned": true, "allowedTransitionOwnerIds": final_stair_owner_ids, "handoffSeamZ": second_stair_end_z, "handoffSourceOwnerId": String(final_stair_owner_ids.back()), "handoffSourceSemantic": "castle_processional_step", "handoffTransitionOwnerId": "castle_keep_palace_entry_forecourt", "handoffTransitionSemantic": "castle_keep_palace_entry_forecourt"})
		var entry_transition_owner_ids: Array[String] = ["castle_keep_palace_entry_forecourt"]
		street_records.append({"id": "processional_04c_palace_entry_transition", "x": 0.0, "z": (entry_ramp_start_z + palace_entry_route_terminal_z) * 0.5, "width": route_half_width * 2.0, "depth": maxf(0.2, palace_entry_route_terminal_z - entry_ramp_start_z), "elevation": terrace_step_height * 2.0, "routeDestination": "palace_entry_forecourt", "transitionOwned": true, "allowedTransitionOwnerIds": entry_transition_owner_ids})
		var urban_rooms := {
			"gate": {"center": Vector3(0.0, 0.0, first_turn_z - cell_spacing * 0.28), "width": absf(turn_offset) + route_half_width * 2.0, "depth": cell_spacing * 0.72, "sightlineTarget": Vector3(turn_offset, terrace_step_height + 2.2, first_stair_center_z + 2.0)},
			"palace": {"center": Vector3(0.0, terrace_step_height * 2.0, (final_turn_z + keep_front_z) * 0.5), "width": keep_width * 1.55, "depth": keep_front_z - final_turn_z, "sightlineTarget": Vector3(0.0, terrace_step_height * 2.0 + clampf(keep_depth * 0.28, 7.0, 10.0), keep_center_z)}
		}
		var route_necks := [
			{"id": "civic_climb", "center": Vector3(turn_offset, terrace_step_height, first_stair_center_z + 3.2), "direction": "z", "clearWidth": route_half_width * 2.0, "clearHeight": 5.0, "projectionDepth": 1.45},
			{"id": "palace_turn", "center": Vector3(turn_offset * 0.5, terrace_step_height, final_turn_z), "direction": "x", "clearWidth": route_half_width * 2.0, "clearHeight": 5.2, "projectionDepth": 1.65}
		]
		return {
			"mode": "district_grid",
			"layoutFamily": "bent_processional",
			"columns": columns,
			"rows": rows,
			"bandsPerSide": bands_per_side,
			"cellSpacing": cell_spacing,
			"goldenLanePitch": 15.5,
			"wealthyPitch": 18.5,
			"boulevardHalfWidth": boulevard_half_width,
			"outerCenterX": outer_center_limit,
			"frontCenterZ": front_center,
			"rowCenters": row_centers,
			"routeCenters": route_centers,
			"routeTurnOffset": turn_offset,
			"firstTurnZ": first_turn_z,
			"finalTurnZ": final_turn_z,
			"terraceStepHeight": terrace_step_height,
			"processionalStepCenters": processional_step_centers,
			"cells": cells,
			"lotPairs": lot_pairs,
			"lotPairCount": lot_pairs.size(),
			"streetRecords": street_records,
			"urbanRooms": urban_rooms,
			"routeNecks": route_necks,
			"reserved": "keep_palace_court_and_bent_processional_route"
		}


	# 1 means a residence may claim the cell; 0 is permanently reserved for the
	# keep footprint or its public gate-to-door approach.  A later footprint
	# check may reject a cell for a tower or an unusually broad source recipe,
	# but no builder is permitted to occupy either reserved class.
	return {
		"mode": "compact_grid",
		"columns": 5,
		"rows": 5,
		"cells": [
			[1, 1, 1, 1, 1],
			[1, 0, 0, 0, 1],
			[1, 0, 0, 0, 1],
			[1, 1, 0, 1, 1],
			[1, 1, 0, 1, 1]
		],
		"reserved": "keep_and_gate_to_keep_route"
	}


static func castle_entry_approach_descriptor(keep_center_z: float, keep_depth: float, palace_grammar: Dictionary) -> Dictionary:
	var keep_front_z := keep_center_z - keep_depth * 0.5
	var civic_core_depth := clampf(keep_depth * float(palace_grammar.get("hallRoofCoreDepthRatio", 0.46)), 9.0, keep_depth * 0.62)
	var entrance_tower_depth := clampf(civic_core_depth * float(palace_grammar.get("entranceTowerDepthRatio", 0.11)), 4.6, 8.8)
	var portal_front_z := keep_front_z - 0.04 - entrance_tower_depth
	# This recipe is the authority for the complete public approach envelope.
	# Publication must consume this value verbatim: independently enlarging the
	# forecourt makes its collider overlap the final processional stair and breaks
	# direct support ownership at the declared handoff seam.
	var transition_queue_depth := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN \
		+ NpcConstantsScript.TRAFFIC_RETREAT_CLEARANCE + NpcConstantsScript.NAVIGATION_TRANSITION_PHASE_RADIUS \
		+ NpcConstantsScript.DEFAULT_NPC_RADIUS * 2.0 + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN \
		+ NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.CELL_SIZE * 0.12
	var ramp_approach_length := maxf(3.00, transition_queue_depth)
	return {"portalFrontZ": portal_front_z, "routeTerminalZ": portal_front_z - 0.50, "terminalInset": 0.50, "rampApproachLength": ramp_approach_length, "rampStartZ": portal_front_z - ramp_approach_length, "civicCoreDepth": civic_core_depth, "entranceTowerDepth": entrance_tower_depth}


static func normalized_context(raw_context: Dictionary, family: String) -> Dictionary:
	var definition := BuildingFamilyCatalogScript.definition_for(family)
	var requested_style := String(raw_context.get("style", definition.get("defaultStyle", "timber"))).strip_edges().to_lower()
	if requested_style not in ["timber", "masonry"]:
		requested_style = String(definition.get("defaultStyle", "timber"))
	return {
		"settlementTier": String(raw_context.get("settlementTier", definition.get("minimumTier", "hamlet"))).strip_edges().to_lower(),
		"biome": String(raw_context.get("biome", "temperate")).strip_edges().to_lower(),
		"siteKey": String(raw_context.get("siteKey", "origin")).strip_edges().to_lower(),
		"style": requested_style,
		"citadelScale": snappedf(clampf(float(raw_context.get("citadelScale", 0.0)), 0.0, 6.0), 0.01)
	}


static func stable_recipe_seed(seed: int, family: String, context: Dictionary) -> int:
	var source := "%d|%s" % [seed, family.strip_edges().to_lower()]
	for key in CONTEXT_KEYS:
		# Context values may originate from a catalog StringName.  `str` keeps the
		# normalized seed serializer scalar-only without rejecting an otherwise
		# valid deterministic building context.
		source += "|%s=%s" % [key, str(context.get(key, ""))]
	# A scale is opt-in: ordinary building recipes retain their historical seed
	# signatures when no citadel expansion was requested, while a scaled castle
	# (and its member recipes) gets a distinct deterministic identity.
	var citadel_scale := float(context.get("citadelScale", 0.0))
	if citadel_scale > 0.0:
		source += "|citadelScale=%s" % str(citadel_scale)
	return int(source.hash())


static func room_floor_for_role(role: String, index: int, floor_count: int) -> int:
	if floor_count <= 1:
		return 0
	if role in ["roof_watch"]:
		return floor_count - 1
	if role in ["private_chamber", "bedroom"]:
		return mini(floor_count - 1, 1 + index % maxi(1, floor_count - 1))
	return 0


static func town_hall_layout_for_footprint(width: float, depth: float) -> String:
	var footprint := width * depth
	if footprint < 400.0:
		return "compact"
	if footprint < 500.0:
		return "standard"
	return "expanded"


static func town_hall_room_roles(layout: String) -> Array[String]:
	match layout:
		"compact":
			return ["public_hall", "notice_archive"]
		"expanded":
			return ["public_hall", "notice_archive", "steward_office", "civic_store"]
		_:
			return ["public_hall", "notice_archive", "steward_office"]


static func compound_member_role(family: String, index: int) -> String:
	if family == "tower":
		return ["northwest", "northeast", "southeast", "southwest"][index % 4]
	if family == "curtain_wall":
		return "perimeter"
	return family
