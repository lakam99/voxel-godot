extends RefCounted
class_name LandmarkBuildingRecipeSampler

## Pure deterministic recipe sampler for all landmark-scale construction.
## Context is normalized in a fixed key order before seeding, so generated
## results cannot depend on dictionary insertion order or publication order.

const BuildingFamilyCatalogScript := preload("res://scripts/buildings/BuildingFamilyCatalog.gd")

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
	var keep_height_scale := lerpf(1.0, 2.55, pow(citadel_progress, 0.70))
	var base_keep_storeys := keep_storeys
	keep_storeys = maxi(keep_storeys, roundi(float(base_keep_storeys) * keep_height_scale))
	var keep_width := snappedf(courtyard_width * rng.randf_range(0.32, 0.48) * keep_footprint_scale, 0.20)
	var keep_depth := snappedf(courtyard_depth * rng.randf_range(0.28, 0.46) * keep_footprint_scale, 0.20)
	var gate_width := snappedf(rng.randf_range(10.0, minf(20.0, courtyard_width * 0.28)), 0.20)
	var keep_offset_z := snappedf(rng.randf_range(0.08, 0.25), 0.02)
	var uses_district_grid := profile == "grand_citadel" and (courtyard_width > 128.0 or courtyard_depth > 112.0)
	var courtyard_grid := castle_courtyard_occupancy_lattice(courtyard_width, courtyard_depth, keep_width, keep_depth, keep_offset_z, gate_width, tower_span, uses_district_grid)
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
	return {
		"profile": profile,
		"grandScale": grand_scale,
		"citadelMasonry": sample_citadel_masonry_palette(seed, context),
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
		"courtyardGrid": courtyard_grid,
		"courtyardProgram": courtyard_program
	}


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
		var center_x := float(lot_pair.get("centerX", 0.0))
		var center_z := float(lot_pair.get("centerZ", 0.0))
		var band_index := int(lot_pair.get("bandIndex", 0))
		var row_index := int(lot_pair.get("rowIndex", 0))
		var neighbourhood := int(lot_pair.get("neighbourhood", 0))
		var district_class := String(lot_pair.get("districtClass", "golden_lane"))
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
					"districtClass": district_class,
					"frontDirection": front_direction_left if mirror_side == "left" else front_direction_right,
					"gridCenterX": center_x,
					"gridCenterZ": center_z,
					"lotPitchX": float(lot_pair.get("lotPitchX", grid.get("cellSpacing", 28.0))),
					"lotPitchZ": float(grid.get("cellSpacing", 28.0)),
					"width": float(lot_pair.get("lotPitchX", grid.get("cellSpacing", 28.0))) - 1.2,
					"depth": float(grid.get("cellSpacing", 28.0)) - 4.0,
					"height": 4.0,
					"roofRise": snappedf(rng.randf_range(1.25, 2.70), 0.10),
					"variation": snappedf(rng.randf_range(-0.025, 0.025), 0.005)
				})
	return program


static func castle_courtyard_occupancy_lattice(courtyard_width := 0.0, courtyard_depth := 0.0, keep_width := 0.0, keep_depth := 0.0, keep_offset_z := 0.0, gate_width := 0.0, tower_span := 0.0, district_grid := false) -> Dictionary:
	if district_grid:
		# Lots, streets and the keep all live in one deterministic city graph. The
		# narrow boulevard is protected from the gate to the keep door; the keep's
		# wider footprint only removes the rows it physically occupies.
		# The exterior districts use a short, repeatable house pitch: this is what
		# makes a Golden-Lane row read as joined town houses rather than rural homes
		# scattered through a large court.  Inner lots deliberately claim every
		# other row below, leaving room for larger homes and their private approaches.
		var cell_spacing := 20.0
		var street_gap := 8.0
		var neighbourhood_rows := 5
		var half_width := courtyard_width * 0.5
		var half_depth := courtyard_depth * 0.5
		var boulevard_half_width := maxf(gate_width * 0.5 + 2.40, 6.0)
		var inner_lot_min_x := boulevard_half_width + 11.0
		var outer_center_limit := half_width - tower_span * 0.5 - 8.0
		var front_center := -half_depth + tower_span * 0.5 + 8.0 + cell_spacing * 0.5
		var rear_center_limit := half_depth - tower_span * 0.5 - 8.0 - cell_spacing * 0.5
		# A dense Golden-Lane belt fronts narrow shared streets near the curtain
		# wall. Past one intentional transition lane, inner lots widen into the
		# roomier manor-capable neighbourhoods around the keep.
		var golden_lane_pitch := 20.0
		var wealthy_pitch := 32.0
		var transition_lane_width := 12.0
		var dense_band_count := mini(6, maxi(2, floori((outer_center_limit - inner_lot_min_x) * 0.42 / golden_lane_pitch) + 1))
		var band_specs: Array[Dictionary] = []
		var current_band_x := outer_center_limit
		for dense_band_index in range(dense_band_count):
			if current_band_x < inner_lot_min_x:
				break
			band_specs.append({"centerX": current_band_x, "districtClass": "golden_lane", "lotPitchX": golden_lane_pitch})
			current_band_x -= golden_lane_pitch
		var golden_lane_inner_x := current_band_x + golden_lane_pitch
		current_band_x -= transition_lane_width
		var wealthy_outer_x := current_band_x
		while current_band_x >= inner_lot_min_x:
			band_specs.append({"centerX": current_band_x, "districtClass": "wealthy", "lotPitchX": wealthy_pitch})
			current_band_x -= wealthy_pitch
		var bands_per_side := band_specs.size()
		var row_centers: Array[float] = []
		var row_index := 0
		while true:
			var row_z := front_center + float(row_index) * cell_spacing + float(row_index / neighbourhood_rows) * street_gap
			if row_z > rear_center_limit + 0.01:
				break
			row_centers.append(row_z)
			row_index += 1
		var rows := row_centers.size()
		var columns := bands_per_side * 2 + 1
		var cells: Array = []
		var lot_pairs: Array[Dictionary] = []
		var street_records: Array[Dictionary] = []
		var keep_center_z := courtyard_depth * keep_offset_z
		var keep_min_z := keep_center_z - keep_depth * 0.5 - cell_spacing * 0.42
		var keep_max_z := keep_center_z + keep_depth * 0.5 + cell_spacing * 0.42
		var keep_side_clearance := keep_width * 0.5 + 12.0
		for resolved_row_index in range(rows):
			var resolved_row_z := row_centers[resolved_row_index]
			var row: Array[int] = []
			for column in range(columns):
				row.append(0)
			for band_index in range(bands_per_side):
				var band_spec: Dictionary = band_specs[band_index] as Dictionary
				var center_x := float(band_spec.get("centerX", 0.0))
				var district_class := String(band_spec.get("districtClass", "golden_lane"))
				# Wealthy homes have a larger two-row cadence; compact Golden-Lane
				# cottages claim every row. This is a simple density field, not a
				# hand-authored neighbourhood exception.
				if district_class == "wealthy" and resolved_row_index % 2 != 0:
					continue
				var intersects_keep := resolved_row_z >= keep_min_z and resolved_row_z <= keep_max_z and center_x <= keep_side_clearance
				if intersects_keep:
					continue
				var row_in_neighbourhood := resolved_row_index % neighbourhood_rows
				# Successive Golden-Lane rows face one another across their narrow
				# shared lane. They are a compact urban frontage, not independent
				# cottages each pointing at a different accidental gap.
				var golden_lane_front := "south" if resolved_row_index % 2 == 0 else "north"
				var left_front := golden_lane_front if district_class == "golden_lane" else ("east" if band_index == bands_per_side - 1 else ("north" if row_in_neighbourhood == 0 else "south" if row_in_neighbourhood == neighbourhood_rows - 1 else ("north" if (resolved_row_index + band_index) % 2 == 0 else "south")))
				var right_front := "west" if district_class == "wealthy" and band_index == bands_per_side - 1 else left_front
				var left_column := band_index
				var right_column := columns - 1 - band_index
				row[left_column] = 1
				row[right_column] = 1
				lot_pairs.append({
					"bandIndex": band_index,
					"districtClass": district_class,
					"lotPitchX": float(band_spec.get("lotPitchX", cell_spacing)),
					"rowIndex": resolved_row_index,
					"neighbourhood": resolved_row_index / neighbourhood_rows,
					"leftColumn": left_column,
					"rightColumn": right_column,
					"centerX": center_x,
					"centerZ": resolved_row_z,
					"frontDirectionLeft": left_front,
					"frontDirectionRight": right_front
				})
			cells.append(row)
			if (resolved_row_index + 1) % neighbourhood_rows == 0 and resolved_row_index + 1 < rows:
				var next_row_z := row_centers[resolved_row_index + 1]
				var street_z := (resolved_row_z + next_row_z) * 0.5
				if street_z < keep_min_z or street_z > keep_max_z:
					street_records.append({"id": "cross_street_%02d" % street_records.size(), "z": street_z, "width": courtyard_width - tower_span - 5.0, "depth": street_gap})
			elif resolved_row_index % 2 == 0 and resolved_row_index + 1 < rows:
				# Pave the short lane that the paired Golden-Lane facades actually
				# front. The wealthier inner neighbourhood intentionally remains more
				# open and is served by the larger cross streets instead.
				var paired_lane_z := (resolved_row_z + row_centers[resolved_row_index + 1]) * 0.5
				var golden_lane_width := outer_center_limit - golden_lane_inner_x + golden_lane_pitch
				var golden_lane_center_x := (outer_center_limit + golden_lane_inner_x) * 0.5
				if golden_lane_width > 0.20:
					street_records.append({"id": "golden_lane_left_%02d" % resolved_row_index, "x": -golden_lane_center_x, "z": paired_lane_z, "width": golden_lane_width, "depth": maxf(0.20, cell_spacing - 14.0)})
					street_records.append({"id": "golden_lane_right_%02d" % resolved_row_index, "x": golden_lane_center_x, "z": paired_lane_z, "width": golden_lane_width, "depth": maxf(0.20, cell_spacing - 14.0)})
		var keep_front_z := keep_center_z - keep_depth * 0.5
		if golden_lane_inner_x > inner_lot_min_x and wealthy_outer_x < golden_lane_inner_x - 2.0:
			var transition_center_x := (golden_lane_inner_x + wealthy_outer_x) * 0.5
			street_records.append({"id": "golden_lane_transition_left", "x": -transition_center_x, "z": 0.0, "width": transition_lane_width, "depth": courtyard_depth - tower_span - 5.0})
			street_records.append({"id": "golden_lane_transition_right", "x": transition_center_x, "z": 0.0, "width": transition_lane_width, "depth": courtyard_depth - tower_span - 5.0})
		var boulevard_front_z := -half_depth + tower_span * 0.5 + 1.0
		var boulevard_depth := maxf(0.20, keep_front_z - boulevard_front_z + 0.50)
		street_records.append({"id": "gate_to_keep_boulevard", "z": boulevard_front_z + boulevard_depth * 0.5, "width": boulevard_half_width * 2.0, "depth": boulevard_depth})
		return {
			"mode": "district_grid",
			"columns": columns,
			"rows": rows,
			"bandsPerSide": bands_per_side,
			"cellSpacing": cell_spacing,
			"goldenLanePitch": golden_lane_pitch,
			"wealthyPitch": wealthy_pitch,
			"streetGap": street_gap,
			"neighbourhoodRows": neighbourhood_rows,
			"boulevardHalfWidth": boulevard_half_width,
			"outerCenterX": outer_center_limit,
			"frontCenterZ": front_center,
			"cells": cells,
			"lotPairs": lot_pairs,
			"lotPairCount": lot_pairs.size(),
			"streetRecords": street_records,
			"reserved": "keep_footprint_and_gate_to_keep_boulevard"
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
