extends RefCounted
class_name CastleCompoundBlueprintBuilder

## Turns the deterministic castle member list into one ordinary construction
## blueprint.  The visual PoC and later settlement publication therefore share
## recipe sampling, part records, materials and collision publication.

const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const LandmarkBuildingRecipeSamplerScript := preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")
const CastleResidencePlacementGeometryScript := preload("res://scripts/buildings/CastleResidencePlacementGeometry.gd")
const CastleCourtyardDistrictPlacementPlannerScript := preload("res://scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd")
const GabledRoofFrameBuilderScript := preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const MAX_RAISED_ROUTE_SURFACE_SEAM := 0.42
const MAX_RAISED_ROUTE_HANDOFF_HEIGHT_DELTA := 0.08
const MAX_RAISED_ROUTE_HANDOFF_GAP := 0.01
const MIN_RAISED_ROUTE_HANDOFF_WIDTH := 1.24
const STAIR_LANDING_DEPTH := 1.04
const RAISED_ROUTE_HANDOFF_AGENT_MARGIN := 0.30


static func build(seed: int, raw_context: Dictionary = {}):
	return build_with_diagnostics(seed, raw_context).get("blueprint")


static func build_with_diagnostics(seed: int, raw_context: Dictionary = {}, continuation: Callable = Callable()) -> Dictionary:
	var context := raw_context.duplicate(true)
	context["settlementTier"] = "city"
	context["style"] = "masonry"
	var diagnostics := {}
	if not _continue_compound(continuation, diagnostics, "compound_sampler_started"):
		return {"blueprint": null, "diagnostics": diagnostics}
	var compound := LandmarkBuildingRecipeSamplerScript.sample_compound(seed, "castle", context)
	if not _continue_compound(continuation, diagnostics, "compound_sampler_completed"):
		return {"blueprint": null, "diagnostics": diagnostics}
	var blueprint = build_from_compound(compound, diagnostics, continuation)
	return {"blueprint": blueprint, "diagnostics": diagnostics.duplicate(true)}


static func _continue_compound(continuation: Callable, diagnostics: Dictionary, stage: String) -> bool:
	if not continuation.is_valid() or continuation.call(stage) == true: return true
	# Diagnostics are the caller-owned output channel, not generation input.
	# Do not retain a partly successful placement handoff after cancellation.
	diagnostics.clear()
	diagnostics["failureReason"] = "cancelled"
	return false


static func build_keep_poc(seed: int, raw_context: Dictionary = {}):
	var context := raw_context.duplicate(true)
	context["settlementTier"] = "city"
	context["style"] = "masonry"
	var compound: Dictionary = LandmarkBuildingRecipeSamplerScript.sample_compound(seed, "castle", context)
	var grammar: Dictionary = compound.get("castleGrammar", {}) as Dictionary
	var members: Array = compound.get("members", []) as Array
	var keep_recipe := member_recipe(members, "keep")
	var keep_width := float(grammar.get("keepWidth", keep_recipe.get("width", 26.0)))
	var keep_depth := float(grammar.get("keepDepth", keep_recipe.get("depth", 24.0)))
	var keep_height := float(grammar.get("keepHeight", float(keep_recipe.get("floorHeight", 3.7)) * 4.0))
	var reference_floor_height := clampf(float(keep_recipe.get("floorHeight", 3.70)), 3.20, 4.20)
	var storey_count := clampi(roundi(keep_height / reference_floor_height), 3, 24)
	var floor_height := keep_height / float(storey_count)
	var foundation_height := 0.62
	var palace_grammar: Dictionary = grammar.get("palaceGrammar", {}) as Dictionary
	var enclosed_storey_count := clampi(int(palace_grammar.get("hallStoreys", 4)), 1, storey_count)
	var masonry_palette: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var fortification_material := String(masonry_palette.get("fortification", "fired_brick"))
	var variation := float(seed % 19) / 100.0 - 0.09
	var blueprint = BuildingBlueprintScript.new("poc.keep.%d.%s" % [seed, String(context.get("siteKey", "keep-poc"))], seed, "masonry")
	blueprint.set_recipe({
		"schemaVersion": int(compound.get("schemaVersion", 1)),
		"family": "keep",
		"seed": seed,
		"context": context.duplicate(true),
		"castleGrammar": grammar.duplicate(true),
		"palaceGrammar": palace_grammar.duplicate(true),
		"width": keep_width,
		"depth": keep_depth,
		"wallHeight": keep_height,
		"floorCount": storey_count,
		"floorHeight": floor_height,
		"foundationHeight": foundation_height,
		"landmarkRole": "citadel_palace"
	})
	var room_records: Array = [
		{"id": "castle_keep", "role": "great_hall", "bounds": AABB(Vector3(-keep_width * 0.5, foundation_height, -keep_depth * 0.5), Vector3(keep_width, keep_height, keep_depth)), "wallMountInset": 0.22, "accesses": []}
	]
	if not add_keep(blueprint, Vector3.ZERO, keep_width, keep_depth, keep_height, storey_count, floor_height, foundation_height, variation, fortification_material, palace_grammar): return null
	append_keep_storey_room_records(room_records, Vector3.ZERO, keep_width, keep_depth, foundation_height, floor_height, enclosed_storey_count, blueprint.parts)
	blueprint.set_room_records(room_records)
	return blueprint


static func build_from_compound(compound: Dictionary, diagnostics: Dictionary = {}, continuation: Callable = Callable()):
	if not _continue_compound(continuation, diagnostics, "compound_geometry_started"): return null
	var members: Array = compound.get("members", []) as Array
	var keep_recipe := member_recipe(members, "keep")
	var gatehouse_recipe := member_recipe(members, "gatehouse")
	var courtyard_recipe := member_recipe(members, "courtyard")
	var tower_recipes := member_recipes(members, "tower")
	var seed := int(compound.get("seed", 0))
	var context: Dictionary = compound.get("context", {}) as Dictionary
	var grammar: Dictionary = compound.get("castleGrammar", {}) as Dictionary
	var variation := float(seed % 19) / 100.0 - 0.09
	var masonry_palette: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var palace_grammar: Dictionary = grammar.get("palaceGrammar", {}) as Dictionary
	var fortification_material := String(masonry_palette.get("fortification", "fired_brick"))
	var courtyard_width := float(grammar.get("courtyardWidth", courtyard_recipe.get("width", 46.0)))
	var courtyard_depth := float(grammar.get("courtyardDepth", courtyard_recipe.get("depth", 42.0)))
	var tower_span := float(grammar.get("towerSpan", (tower_recipes[0] as Dictionary).get("width", 6.4) if not tower_recipes.is_empty() else 6.4))
	var tower_count := clampi(int(grammar.get("towerCount", 4)), 4, 8)
	var wall_height := float(grammar.get("wallHeight", float(gatehouse_recipe.get("floorHeight", 3.6)) * 1.70))
	var tower_height_base := float(grammar.get("towerHeightBase", float((tower_recipes[0] as Dictionary).get("floorHeight", 3.6)) * 3.4 if not tower_recipes.is_empty() else 12.4))
	var tower_height_variation := float(grammar.get("towerHeightVariation", 0.16))
	var keep_width := minf(float(grammar.get("keepWidth", float(keep_recipe.get("width", 26.0)) * 0.52)), courtyard_width - tower_span * 2.50)
	var keep_depth := minf(float(grammar.get("keepDepth", float(keep_recipe.get("depth", 24.0)) * 0.48)), courtyard_depth - tower_span * 2.50)
	var keep_height := float(grammar.get("keepHeight", float(keep_recipe.get("floorHeight", 3.7)) * float(maxi(3, int(keep_recipe.get("floorCount", 4))))))
	# Castle grammar predates an explicit storey count, but its sampled height is
	# already derived from an ordinary floor height.  Reconstruct the occupied
	# levels here so the physical keep never advertises a multi-storey silhouette
	# while containing one uninterrupted empty volume.
	var keep_reference_floor_height := clampf(float(keep_recipe.get("floorHeight", 3.70)), 3.20, 4.20)
	var keep_storey_count := clampi(roundi(keep_height / keep_reference_floor_height), 3, 24)
	var keep_floor_height := keep_height / float(keep_storey_count)
	var gate_width := minf(float(grammar.get("gateWidth", gatehouse_recipe.get("width", 11.0))), courtyard_width * 0.42)
	var gate_depth := float(grammar.get("gateDepth", gatehouse_recipe.get("depth", 9.0)))
	var gate_height := maxf(wall_height + 1.80, float(grammar.get("gateHeight", float(gatehouse_recipe.get("floorHeight", 3.6)) * 2.30)))
	var foundation_height := 0.62
	var keep_foundation_height := foundation_height + citadel_keep_terrace_elevation(grammar)
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	# The gate is centred at x = 0, and the keep must stay on that same axis.
	# Do not reintroduce side offsets here: the main axis is a castle invariant.
	var keep_center := Vector3(0.0, 0.0, courtyard_depth * float(keep_offset.get("z", 0.14)))
	var tower_specs := tower_specs_for_grammar(seed, courtyard_width, courtyard_depth, tower_count, tower_span, tower_height_base, tower_height_variation, int(grammar.get("towerPhase", 0)))
	var courtyard_program: Array = grammar.get("courtyardProgram", []) as Array
	var forecourt_layout_valid := sampler_forecourt_layout_valid(palace_grammar)
	var entry_approach_valid := sampler_entry_approach_valid(palace_grammar)
	if not forecourt_layout_valid or not entry_approach_valid:
		diagnostics["failureReason"] = "invalid_sampler_entry_approach" if not entry_approach_valid else "invalid_sampler_forecourt_layout"
		push_error("Castle seed %d has missing or divergent sampler-owned palace approach authority" % seed)
		return null
	var enclosed_keep_storey_count := clampi(int(palace_grammar.get("hallStoreys", 4)), 1, keep_storey_count)
	var blueprint = BuildingBlueprintScript.new("compound.castle.%d.%s" % [seed, String(context.get("siteKey", "citadel"))], seed, "masonry")
	# Lot planning consumes the exact collision-enabled keep parts produced by
	# the shared recipe builder. This prevents wings, courts, galleries or
	# pavilions from becoming invisible-to-planning geometry as their seeded
	# proportions change.
	if not _continue_compound(continuation, diagnostics, "compound_keep_started"): return null
	if not add_keep(blueprint, keep_center, keep_width, keep_depth, keep_height, keep_storey_count, keep_floor_height, keep_foundation_height, variation, fortification_material, palace_grammar):
		diagnostics["failureReason"] = "keep_stair_circulation_unavailable"
		return null
	if not _continue_compound(continuation, diagnostics, "compound_towers_started"): return null
	for index in range(tower_specs.size()):
		if not _continue_compound(continuation, diagnostics, "compound_tower"): return null
		var tower_spec: Dictionary = tower_specs[index] as Dictionary
		add_tower(blueprint, "castle_tower_%02d" % (index + 1), tower_spec.get("position", Vector3.ZERO) as Vector3, float(tower_spec.get("span", tower_span)), float(tower_spec.get("height", tower_height_base)), foundation_height, variation + float(index) * 0.006, fortification_material)
	if not _continue_compound(continuation, diagnostics, "compound_courtyard_placement_started"): return null
	var keep_structure_footprints := keep_collision_footprints(blueprint.parts)
	# Diagnostics may be reused by a caller. Only this invocation's callback
	# can cancel its construction; an old output marker is not a control input.
	var placement_cancel := {"stopped": false}
	var placement_continuation := Callable()
	if continuation.is_valid():
		placement_continuation = func(stage: String) -> bool:
			if placement_cancel.stopped: return false
			var permitted: bool = continuation.call(stage) == true
			placement_cancel.stopped = not permitted
			return permitted
	var courtyard_buildings := courtyard_building_specs(courtyard_program, courtyard_width, courtyard_depth, keep_center, keep_width, keep_depth, keep_structure_footprints, gate_width, tower_specs, seed, context, masonry_palette, grammar, diagnostics, placement_continuation)
	if placement_cancel.stopped: return null
	if not _continue_compound(continuation, diagnostics, "compound_courtyard_placement_completed"): return null
	if courtyard_buildings.size() != courtyard_program.size():
		push_error("Castle seed %d could not publish its complete sampled courtyard program" % seed)
		return null
	blueprint.set_recipe({
		"schemaVersion": int(compound.get("schemaVersion", 1)),
		"family": "castle",
		"compound": compound.duplicate(true),
		"seed": seed,
		"context": context.duplicate(true),
		"castleGrammar": grammar.duplicate(true),
		"style": "masonry",
		"width": courtyard_width + tower_span * 1.10,
		"depth": courtyard_depth + tower_span * 1.10 + gate_depth * 0.58,
		"floorCount": keep_storey_count,
		"keepStoreyCount": keep_storey_count,
		"keepFloorHeight": keep_floor_height,
		"citadelMasonry": masonry_palette.duplicate(true),
		"wallHeight": keep_height,
		"towerCount": tower_specs.size(),
		"courtyardBuildingCount": courtyard_buildings.size(),
		# These are resolved source recipes and transforms, not a second castle
		# house authority.  CastleFurnishingPlanner rebuilds these exact shared
		# source blueprints before transforming their seeded furnishing plans.
		"courtyardResidences": courtyard_buildings.duplicate(true),
		"foundationHeight": foundation_height,
		"landmarkRole": "fortified_compound"
	})
	if not _continue_compound(continuation, diagnostics, "compound_rooms_started"): return null
	var room_records: Array = [
		{"id": "castle_courtyard", "role": "courtyard", "bounds": AABB(Vector3(-courtyard_width * 0.5, foundation_height, -courtyard_depth * 0.5), Vector3(courtyard_width, wall_height, courtyard_depth)), "wallMountInset": 0.22, "accesses": []},
		{"id": "castle_keep", "role": "great_hall", "bounds": AABB(Vector3(keep_center.x - keep_width * 0.5, keep_foundation_height, keep_center.z - keep_depth * 0.5), Vector3(keep_width, keep_height, keep_depth)), "wallMountInset": 0.22, "accesses": []}
	]
	append_keep_storey_room_records(room_records, keep_center, keep_width, keep_depth, keep_foundation_height, keep_floor_height, enclosed_keep_storey_count, blueprint.parts)
	append_declared_interior_program_rooms(room_records, blueprint.parts)
	for building_value in courtyard_buildings:
		if not _continue_compound(continuation, diagnostics, "compound_residence_room"): return null
		var building: Dictionary = building_value as Dictionary
		var building_center: Vector3 = building.get("center", Vector3.ZERO) as Vector3
		var building_width := float(building.get("width", 6.0))
		var building_depth := float(building.get("depth", 6.0))
		var building_height := float((building.get("residenceRecipe", {}) as Dictionary).get("wallHeight", building.get("height", 4.0)))
		# A residence record is the one graph node occupying a wall lane. Its
		# inherited rooms follow below and must not be mistaken for neighbour
		# buildings by compound-level clearance validation.
		room_records.append({"id": String(building.get("id", "courtyard_building")), "role": String(building.get("kind", "residence")), "bounds": AABB(Vector3(building_center.x - building_width * 0.5, foundation_height, building_center.z - building_depth * 0.5), Vector3(building_width, building_height, building_depth)), "wallMountInset": 0.20, "accesses": [], "castleCourtyardResidence": true, "castleResidenceFamily": String(building.get("residenceFamily", "cottage"))})
		append_courtyard_residence_rooms(room_records, building, foundation_height)
	blueprint.set_room_records(room_records)

	# The courtyard is a physical, paved interior of the perimeter—not an empty
	# ground plane placed underneath a decorative wall ring.  Residence ramps
	# are real egress corridors, so carve the compound slab and paving around
	# them rather than burying their walk planes inside a monolithic foundation.
	# Each corridor receives a structural underfill below its ramp in
	# add_courtyard_outbuilding(), keeping the visual and collision load path
	# continuous without turning the ramp into an embedded navigation endpoint.
	var half_width := courtyard_width * 0.5
	var half_depth := courtyard_depth * 0.5
	# Four curtain runs terminate against the corner towers. The front run is
	# deliberately split around the real gatehouse instead of covering a gate
	# visual with a continuous collision wall.
	var front_z := -half_depth
	var back_z := half_depth
	var left_x := -half_width
	var right_x := half_width
	var northwest_span := tower_span_for_role(tower_specs, "northwest", tower_span)
	var northeast_span := tower_span_for_role(tower_specs, "northeast", tower_span)
	var southeast_span := tower_span_for_role(tower_specs, "southeast", tower_span)
	var southwest_span := tower_span_for_role(tower_specs, "southwest", tower_span)
	add_curtain_x_segment(blueprint, "castle_front_wall_left", front_z, -half_width + northwest_span * 0.5, -gate_width * 0.5, wall_height, foundation_height, variation, fortification_material)
	add_curtain_x_segment(blueprint, "castle_front_wall_right", front_z, gate_width * 0.5, half_width - northeast_span * 0.5, wall_height, foundation_height, variation, fortification_material)
	add_curtain_x_segment(blueprint, "castle_back_wall", back_z, -half_width + southwest_span * 0.5, half_width - southeast_span * 0.5, wall_height, foundation_height, variation, fortification_material)
	add_curtain_z_segment(blueprint, "castle_left_wall", left_x, -half_depth + northwest_span * 0.5, half_depth - southwest_span * 0.5, wall_height, foundation_height, variation, fortification_material)
	add_curtain_z_segment(blueprint, "castle_right_wall", right_x, -half_depth + northeast_span * 0.5, half_depth - southwest_span * 0.5, wall_height, foundation_height, variation, fortification_material)

	if not _continue_compound(continuation, diagnostics, "compound_gatehouse_started"): return null
	add_gatehouse(blueprint, gate_width, gate_depth, gate_height, foundation_height, front_z, variation, fortification_material)
	if not _continue_compound(continuation, diagnostics, "compound_paving_started"): return null
	var keep_entry_reserved_walkways := keep_entry_transition_exclusions(blueprint)
	add_courtyard_foundation_and_paving(blueprint, courtyard_buildings, courtyard_width, courtyard_depth, foundation_height, variation, keep_entry_reserved_walkways)
	if not _continue_compound(continuation, diagnostics, "compound_terraces_started"): return null
	add_citadel_terraces(blueprint, grammar, courtyard_width, courtyard_depth, foundation_height, variation, courtyard_buildings, keep_entry_reserved_walkways)
	if not _continue_compound(continuation, diagnostics, "compound_streets_started"): return null
	add_district_streets(blueprint, grammar, foundation_height, variation)
	if not _continue_compound(continuation, diagnostics, "compound_dressing_started"): return null
	add_citadel_urban_room_dressing(blueprint, grammar, foundation_height, variation)
	for building_value in courtyard_buildings:
		if not _continue_compound(continuation, diagnostics, "compound_residence_started"): return null
		add_courtyard_outbuilding(blueprint, building_value as Dictionary, foundation_height)
	if not _continue_compound(continuation, diagnostics, "compound_facade_details_started"): return null
	add_citadel_residence_facade_details(blueprint, courtyard_buildings, grammar, foundation_height, variation)
	add_part(blueprint, "castle_banner_gate", "sign", "painted_decor", Vector3(0.0, foundation_height + gate_height * 0.72, front_z - gate_depth * 0.54), Vector3(1.32, 2.30, 0.10), {"variation": variation, "collision": false, "semantic": "castle_banner"})
	if not _continue_compound(continuation, diagnostics, "compound_geometry_completed"): return null
	return blueprint


static func append_keep_storey_room_records(records: Array, center: Vector3, width: float, depth: float, foundation_height: float, floor_height: float, storey_count: int, parts: Array) -> void:
	# These are ordinary room records for the occupied keep levels.  The shared
	# furnishing/layout authority can now see the same vertical circulation that
	# the construction builder publishes below instead of treating the keep as a
	# single impossible room spanning every floor.
	var roles: Array[String] = ["great_hall", "guard_chamber", "armory", "archive", "private_chamber", "watch_chamber", "roof_watch", "roof_watch"]
	var stairwell := keep_stairwell_layout(center, width, depth, parts)
	var stair_center: Vector3 = stairwell.get("center", center) as Vector3
	var stair_width := float(stairwell.get("width", 3.20))
	var stair_depth := float(stairwell.get("depth", 5.00))
	for level in range(storey_count):
		var level_y := foundation_height + floor_height * float(level)
		var access_kind := "stair_up" if level < storey_count - 1 else "stair_down"
		records.append({
			"id": "castle_keep_storey_%02d" % level,
			"role": roles[mini(level, roles.size() - 1)],
			"bounds": AABB(Vector3(center.x - width * 0.5 + 0.74, level_y, center.z - depth * 0.5 + 0.74), Vector3(width - 1.48, floor_height, depth - 1.48)),
			"wallMountInset": 0.22,
			"accesses": [{"id": "keep_stair_%02d" % level, "kind": access_kind, "position": Vector3(stair_center.x, level_y + 0.86, stair_center.z), "size": Vector3(stair_width, 2.20, stair_depth)}],
			"castleKeepStorey": level
		})


static func append_declared_interior_program_rooms(records: Array, parts: Array) -> void:
	var known_ids: Dictionary = {}
	for room_value in records:
		if room_value is Dictionary:
			known_ids[String((room_value as Dictionary).get("id", ""))] = true
	for part in parts:
		if part == null:
			continue
		var room_value: Variant = part.recipe.get("interiorProgramRoom")
		if not room_value is Dictionary:
			continue
		var room: Dictionary = room_value as Dictionary
		var room_id := String(room.get("id", "")).strip_edges()
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		if room_id.is_empty() or known_ids.has(room_id) or not bounds.position.is_finite() or not bounds.size.is_finite() \
				or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
			continue
		known_ids[room_id] = true
		records.append(room.duplicate(true))


static func keep_stairwell_layout(center: Vector3, width: float, depth: float, parts: Array) -> Dictionary:
	# The stairwell sits in the rear-right quarter of the keep.  It is wide enough
	# for a true two-flight stair, remains inside the structural walls, and leaves
	# the entry axis and great hall clear for normal play.
	var stair_width := clampf(width * 0.22, 3.10, 4.30)
	var stair_depth := clampf(depth * 0.38, 4.80, 6.40)
	var interior_right := center.x + width * 0.5 - 0.76
	var interior_back := center.z + depth * 0.5 - 0.76
	var interior_front := center.z - depth * 0.5 + 0.76
	var stair_x := interior_right - stair_width * 0.5
	# The existing palace and rear wings own their geometry. Fit circulation
	# between their actual collision envelopes, including roof overhangs, before
	# producing the shared floor openings and room access reservations.
	for part in parts:
		if not part.collision_enabled: continue
		var front_wing: bool = part.id.begins_with("castle_keep_palace_wing")
		var rear_wing: bool = part.id.begins_with("castle_keep_rear_cross_wing") or part.id.begins_with("castle_keep_rear_service")
		if not front_wing and not rear_wing: continue
		var bounds: AABB = Transform3D(Basis.from_euler(part.rotation),part.position) * AABB(-part.size*0.5,part.size)
		if bounds.end.x < stair_x-stair_width*0.5 or bounds.position.x > stair_x+stair_width*0.5: continue
		if front_wing: interior_front=maxf(interior_front,bounds.end.z+0.60)
		if rear_wing: interior_back=minf(interior_back,bounds.position.z-0.60)
	stair_depth=minf(stair_depth,interior_back-interior_front)
	return {
		"ready": stair_depth >= 2.14,
		"center": Vector3(stair_x, 0.0, interior_back - stair_depth * 0.5),
		"width": stair_width,
		"depth": stair_depth
	}


static func member_recipe(members: Array, family: String) -> Dictionary:
	for value in members:
		if value is Dictionary and String((value as Dictionary).get("family", "")) == family:
			return ((value as Dictionary).get("recipe", {}) as Dictionary).duplicate(true)
	return {}


static func member_recipes(members: Array, family: String) -> Array:
	var result: Array = []
	for value in members:
		if value is Dictionary and String((value as Dictionary).get("family", "")) == family:
			result.append(((value as Dictionary).get("recipe", {}) as Dictionary).duplicate(true))
	return result


static func tower_specs_for_grammar(seed: int, courtyard_width: float, courtyard_depth: float, tower_count: int, base_span: float, base_height: float, height_variation: float, phase: int) -> Array[Dictionary]:
	# Corners carry the perimeter structurally. Extra towers come in mirrored
	# pairs around the gate-to-keep axis. A centre-front tower would occupy the
	# real gatehouse passage, so the gate is flanked rather than blocked.
	var resolved_count := 4 if tower_count <= 4 else (6 if tower_count <= 6 else 8)
	var normalized_positions: Array[Dictionary] = [
		{"role": "northwest", "x": -0.5, "z": -0.5},
		{"role": "northeast", "x": 0.5, "z": -0.5},
		{"role": "southeast", "x": 0.5, "z": 0.5},
		{"role": "southwest", "x": -0.5, "z": 0.5}
	]
	if resolved_count >= 6:
		normalized_positions.append({"role": "north_gate_flank_left", "x": -0.28, "z": -0.5})
		normalized_positions.append({"role": "north_gate_flank_right", "x": 0.28, "z": -0.5})
	if resolved_count >= 8:
		normalized_positions.append({"role": "south_wall_flank_left", "x": -0.28, "z": 0.5})
		normalized_positions.append({"role": "south_wall_flank_right", "x": 0.28, "z": 0.5})
	var rng := RandomNumberGenerator.new()
	rng.seed = int(("%d|castle.tower.specs" % seed).hash())
	var specs: Array[Dictionary] = []
	for source_value in normalized_positions:
		var source: Dictionary = source_value as Dictionary
		var span := snappedf(base_span * rng.randf_range(0.88, 1.18), 0.20)
		var height := snappedf(base_height * rng.randf_range(1.0 - height_variation, 1.0 + height_variation), 0.20)
		specs.append({
			"role": String(source.get("role", "tower")),
			"position": Vector3(courtyard_width * float(source.get("x", 0.0)), 0.0, courtyard_depth * float(source.get("z", 0.0))),
			"span": span,
			"height": height
		})
	return specs


static func tower_span_for_role(specs: Array[Dictionary], role: String, fallback: float) -> float:
	for spec in specs:
		if String(spec.get("role", "")) == role:
			return float(spec.get("span", fallback))
	return fallback


static func courtyard_building_specs(program: Array, courtyard_width: float, courtyard_depth: float, keep_center: Vector3, keep_width: float, keep_depth: float, keep_structure_footprints: Array[Dictionary], gate_width: float, tower_specs: Array[Dictionary], seed: int, context: Dictionary, masonry_palette: Dictionary, grammar: Dictionary, diagnostics: Dictionary = {}, continuation: Callable = Callable()) -> Array[Dictionary]:
	var courtyard_grid_value = grammar.get("courtyardGrid", null)
	var district_grid := courtyard_grid_value as Dictionary if courtyard_grid_value is Dictionary else {}
	if String(district_grid.get("mode", "")) == "district_grid":
		var lot_pairs_value = district_grid.get("lotPairs", null)
		var declared_pair_count = district_grid.get("lotPairCount", null)
		var coverage_valid := lot_pairs_value is Array \
			and declared_pair_count is int \
			and int(declared_pair_count) > 0 \
			and int(declared_pair_count) == (lot_pairs_value as Array).size() \
			and program.size() == (lot_pairs_value as Array).size() * 2
		if not coverage_valid:
			diagnostics["failureReason"] = "invalid_post_geometry_district_program"
			diagnostics["pairDiagnostics"] = {"mode": "post_geometry_exact", "attemptCount": 0, "fallback": false, "terminalReason": "incomplete_district_program", "pairIndex": -1, "programCount": program.size(), "lotPairCount": (lot_pairs_value as Array).size() if lot_pairs_value is Array else -1}
			push_error("Castle seed %d district program does not cover every sampler-owned lot pair" % seed)
			return []
		return planned_district_courtyard_building_specs(program, lot_pairs_value as Array, district_grid, courtyard_width, courtyard_depth, keep_structure_footprints, seed, masonry_palette, diagnostics, continuation)
	return compact_courtyard_building_specs(program, courtyard_width, courtyard_depth, keep_center, keep_width, keep_depth, keep_structure_footprints, gate_width, tower_specs, seed, context, masonry_palette, grammar, diagnostics)


static func planned_district_courtyard_building_specs(program: Array, lot_pairs: Array, grid: Dictionary, courtyard_width: float, courtyard_depth: float, keep_structure_footprints: Array[Dictionary], seed: int, masonry_palette: Dictionary, diagnostics: Dictionary, continuation: Callable = Callable()) -> Array[Dictionary]:
	if String(grid.get("mode", "")) != "district_grid":
		return reject_post_geometry_district(diagnostics, seed, -1, "invalid_district_grid_mode")
	var street_records_value = grid.get("streetRecords", null)
	if not street_records_value is Array or (street_records_value as Array).is_empty():
		return reject_post_geometry_district(diagnostics, seed, -1, "invalid_street_records")
	var intents: Array = []
	var seen_ids := {}
	var seen_pairs := {}
	for index in range(0, program.size(), 2):
		var pair_index := index / 2
		if index + 1 >= program.size() or not program[index] is Dictionary or not program[index + 1] is Dictionary or pair_index >= lot_pairs.size() or not lot_pairs[pair_index] is Dictionary:
			return reject_post_geometry_district(diagnostics, seed, pair_index, "incomplete_district_program")
		var left_source: Dictionary = program[index] as Dictionary
		var right_source: Dictionary = program[index + 1] as Dictionary
		var lot_pair: Dictionary = lot_pairs[pair_index] as Dictionary
		var pair_id := String(left_source.get("symmetryGroup", ""))
		var pair_identity_valid := not pair_id.is_empty() \
			and pair_id == String(right_source.get("symmetryGroup", "")) \
			and String(left_source.get("mirrorSide", "")) == "left" \
			and String(right_source.get("mirrorSide", "")) == "right" \
			and not seen_pairs.has(pair_id)
		if not pair_identity_valid:
			return reject_post_geometry_district(diagnostics, seed, pair_index, "invalid_pair_identity", pair_id)
		seen_pairs[pair_id] = true
		var sources: Array[Dictionary] = [left_source, right_source]
		for side_index in range(2):
			if not _continue_compound(continuation, diagnostics, "compound_placement_source"): return []
			var source: Dictionary = sources[side_index]
			var side := "left" if side_index == 0 else "right"
			var identity := String(source.get("id", ""))
			var source_pair_index = source.get("cityGridPairIndex", null)
			var source_mode = source.get("cityGridMode", null)
			var source_valid := not identity.is_empty() \
				and not seen_ids.has(identity) \
				and source_pair_index is int \
				and int(source_pair_index) == pair_index \
				and int(source.get("placementOrdinal", -1)) == index + side_index \
				and source_mode is String \
				and String(source_mode) == "district" \
				and String(source.get("mirrorSide", "")) == side
			for numeric_key in ["gridCenterX", "gridCenterZ", "terraceElevation"]:
				var numeric_value = source.get(numeric_key, null)
				source_valid = source_valid and (numeric_value is int or numeric_value is float) and is_finite(float(numeric_value))
			var front_direction := String(source.get("frontDirection", ""))
			source_valid = source_valid and front_direction in ["north", "south", "east", "west"]
			if not source_valid:
				return reject_post_geometry_district(diagnostics, seed, pair_index, "invalid_source_intent", pair_id)
			if not sampled_district_lot_binding_valid(source, lot_pair, side):
				return reject_post_geometry_district(diagnostics, seed, pair_index, "program_lot_pair_mismatch", pair_id)
			if not sampled_residence_authority_valid(source, lot_pair, side):
				return reject_post_geometry_district(diagnostics, seed, pair_index, "invalid_residence_authority", pair_id)
			seen_ids[identity] = true
			var family := String(source.get("residenceFamily", ""))
			var recipe: Dictionary = (source.get("residenceRecipe", {}) as Dictionary).duplicate(true)
			var source_blueprint = courtyard_residence_blueprint_from_recipe(family, recipe)
			if source_blueprint == null:
				return reject_post_geometry_district(diagnostics, seed, pair_index, "invalid_source_blueprint", pair_id)
			var source_spec := source.duplicate(true)
			source_spec["residenceFacadeMaterial"] = residence_facade_material(seed, identity, masonry_palette)
			intents.append({
				"id": identity,
				"pairIndex": pair_index,
				"side": side,
				"family": family,
				"recipe": recipe,
				"recipeHash": String(source.get("residenceRecipeHash", "")),
				"sourceBlueprint": source_blueprint,
				"sourceBlueprintSignature": source_blueprint.deterministic_signature(),
				"sourceSpec": source_spec,
				"nominalCenter": Vector3(float(source.get("gridCenterX")), 0.0, float(source.get("gridCenterZ"))),
				"frontDirection": front_direction,
				"elevation": float(source.get("terraceElevation")),
				"foundationElevation": 0.62
			})
	if intents.size() != program.size():
		return reject_post_geometry_district(diagnostics, seed, -1, "incomplete_district_intents")
	var courtyard_bounds := {
		"minX": -courtyard_width * 0.5,
		"maxX": courtyard_width * 0.5,
		"minZ": -courtyard_depth * 0.5,
		"maxZ": courtyard_depth * 0.5
	}
	var options := {"fixedClearance": 0.04, "residenceClearance": 0.08, "pairClearance": 2.60, "boundaryClearance": 0.90}
	var plan: Dictionary = CastleCourtyardDistrictPlacementPlannerScript.plan(intents, street_records_value as Array, keep_structure_footprints, courtyard_bounds, options, continuation)
	if plan.get("status", "") == "cancelled":
		diagnostics.clear()
		diagnostics["failureReason"] = "cancelled"
		return []
	var plan_summary := plan.duplicate(true)
	plan_summary.erase("placements")
	diagnostics["districtPlacementPlan"] = plan_summary
	if String(plan.get("status", "")) != "ready" or not bool((plan.get("validation", {}) as Dictionary).get("passed", false)):
		diagnostics["failureReason"] = "district_placement_infeasible"
		diagnostics["pairDiagnostics"] = {"mode": "post_geometry_exact", "attemptCount": 0, "fallback": false, "terminalReason": String(plan.get("phase", "infeasible")), "pairIndex": -1, "rejections": (plan.get("rejections", []) as Array).duplicate(true)}
		push_error("Castle seed %d post-geometry district placement is infeasible" % seed)
		return []
	var placements_value = plan.get("placements", null)
	if not placements_value is Array or (placements_value as Array).size() != program.size():
		return reject_post_geometry_district(diagnostics, seed, -1, "incomplete_placement_plan")
	var placements_by_id := {}
	for placement_value in placements_value as Array:
		if not placement_value is Dictionary:
			return reject_post_geometry_district(diagnostics, seed, -1, "malformed_placement_record")
		var placement: Dictionary = placement_value as Dictionary
		var placement_id := String(placement.get("id", ""))
		if placement_id.is_empty() or placements_by_id.has(placement_id):
			return reject_post_geometry_district(diagnostics, seed, int(placement.get("pairIndex", -1)), "duplicate_placement_record")
		placements_by_id[placement_id] = placement
	var result: Array[Dictionary] = []
	var pair_diagnostics: Array = []
	for index in range(program.size()):
		if not _continue_compound(continuation, diagnostics, "compound_placement_record"): return []
		var source: Dictionary = program[index] as Dictionary
		var identity := String(source.get("id", ""))
		if not placements_by_id.has(identity):
			return reject_post_geometry_district(diagnostics, seed, int(source.get("cityGridPairIndex", -1)), "missing_placement_record", String(source.get("symmetryGroup", "")))
		var placement: Dictionary = placements_by_id[identity] as Dictionary
		var composition: Dictionary = (placement.get("composition", {}) as Dictionary).duplicate(true)
		var aggregate: Dictionary = (composition.get("aggregateFootprint", {}) as Dictionary).duplicate(true)
		if composition.is_empty() or aggregate.is_empty():
			return reject_post_geometry_district(diagnostics, seed, int(source.get("cityGridPairIndex", -1)), "missing_exact_composition", String(source.get("symmetryGroup", "")))
		var recipe: Dictionary = (source.get("residenceRecipe", {}) as Dictionary).duplicate(true)
		var front_direction := String(source.get("frontDirection", ""))
		var swaps_axes := front_direction in ["east", "west"]
		var spec := source.duplicate(true)
		spec["center"] = placement.get("center", Vector3.ZERO)
		spec["origin"] = placement.get("origin", Vector3.ZERO)
		spec["yaw"] = float(placement.get("yaw", 0.0))
		spec["resolvedNode"] = "district_block_row_%d_band_%d_%s" % [int(source.get("cityGridRow", -1)), int(source.get("cityGridColumn", -1)), String(source.get("mirrorSide", ""))]
		spec["resolvedPairSlot"] = {
			"mode": "post_geometry_exact",
			"attemptCount": 1,
			"fallback": false,
			"terminalReason": "accepted",
			"pairIndex": int(source.get("cityGridPairIndex", -1)),
			"placementSignature": String(placement.get("placementSignature", "")),
			"compositionSignature": String(placement.get("compositionSignature", "")),
			"sourceBlueprintSignature": String(placement.get("sourceBlueprintSignature", "")),
			"nominalCenter": placement.get("nominalCenter", Vector3.ZERO),
			"compositionPartCount": int(placement.get("compositionPartCount", 0)),
			"collisionPartCount": int(placement.get("collisionPartCount", 0)),
			"aggregateCount": int(placement.get("aggregateCount", 0))
		}
		spec["collisionFootprint"] = aggregate
		spec["compositionDescriptor"] = composition
		spec["frontDirection"] = front_direction
		spec["width"] = float(recipe.get("depth", 0.0)) if swaps_axes else float(recipe.get("width", 0.0))
		spec["depth"] = float(recipe.get("width", 0.0)) if swaps_axes else float(recipe.get("depth", 0.0))
		spec["residenceFamily"] = String(source.get("residenceFamily", ""))
		spec["residenceRecipe"] = recipe
		spec["residenceRecipeHash"] = String(source.get("residenceRecipeHash", ""))
		spec["residenceFacadeMaterial"] = residence_facade_material(seed, identity, masonry_palette)
		spec["terraceElevation"] = float(source.get("terraceElevation", 0.0))
		result.append(spec)
		if index % 2 == 1:
			var left_placement: Dictionary = placements_by_id[String((program[index - 1] as Dictionary).get("id", ""))] as Dictionary
			pair_diagnostics.append({
				"mode": "post_geometry_exact",
				"attemptCount": 1,
				"fallback": false,
				"terminalReason": "accepted",
				"pairIndex": int(source.get("cityGridPairIndex", -1)),
				"leftPlacementSignature": String(left_placement.get("placementSignature", "")),
				"rightPlacementSignature": String(placement.get("placementSignature", ""))
			})
	diagnostics["postGeometryPairs"] = pair_diagnostics
	return result


static func reject_post_geometry_district(diagnostics: Dictionary, seed: int, pair_index: int, terminal_reason: String, pair_id := "") -> Array[Dictionary]:
	diagnostics["failureReason"] = "invalid_post_geometry_district_program"
	diagnostics["pairId"] = pair_id
	diagnostics["pairDiagnostics"] = {"mode": "post_geometry_exact", "attemptCount": 0, "fallback": false, "terminalReason": terminal_reason, "pairIndex": pair_index}
	push_error("Castle seed %d post-geometry district source rejected at pair %d: %s" % [seed, pair_index, terminal_reason])
	return []


static func sampled_district_lot_binding_valid(source: Dictionary, lot_pair: Dictionary, side: String) -> bool:
	var center_x_key := "leftCenterX" if side == "left" else "rightCenterX"
	var center_z_key := "leftCenterZ" if side == "left" else "rightCenterZ"
	var front_key := "frontDirectionLeft" if side == "left" else "frontDirectionRight"
	var column_key := "leftColumn" if side == "left" else "rightColumn"
	for pair_key in [center_x_key, center_z_key, "terraceElevation"]:
		var pair_value = lot_pair.get(pair_key, null)
		if not (pair_value is int or pair_value is float) or not is_finite(float(pair_value)):
			return false
	var front_value = lot_pair.get(front_key, null)
	if not front_value is String or String(front_value) not in ["north", "south", "east", "west"]:
		return false
	return float(source.get("gridCenterX", INF)) == float(lot_pair.get(center_x_key)) \
		and float(source.get("gridCenterZ", INF)) == float(lot_pair.get(center_z_key)) \
		and float(source.get("terraceElevation", INF)) == float(lot_pair.get("terraceElevation")) \
		and String(source.get("frontDirection", "")) == String(front_value) \
		and int(source.get("cityGridRow", -1)) == int(lot_pair.get("rowIndex", -2)) \
		and int(source.get("cityGridColumn", -1)) == int(lot_pair.get(column_key, -2))


static func compact_courtyard_building_specs(program: Array, courtyard_width: float, courtyard_depth: float, keep_center: Vector3, keep_width: float, keep_depth: float, keep_structure_footprints: Array[Dictionary], gate_width: float, tower_specs: Array[Dictionary], seed: int, context: Dictionary, masonry_palette: Dictionary, grammar: Dictionary, diagnostics: Dictionary) -> Array[Dictionary]:
	var graph_nodes := courtyard_city_grid_nodes()
	var result: Array[Dictionary] = []
	var front_city_cursor := courtyard_inner_front_cursor(courtyard_depth, tower_specs)
	var outer_front_cursor := front_city_cursor
	var inner_front_cursor := front_city_cursor
	for index in range(0, program.size(), 2):
		if index + 1 >= program.size() or not program[index] is Dictionary or not program[index + 1] is Dictionary:
			push_error("Castle courtyard program has an incomplete symmetry pair")
			continue
		var left_source: Dictionary = program[index] as Dictionary
		var right_source: Dictionary = program[index + 1] as Dictionary
		if String(left_source.get("mirrorSide", "")) != "left" or String(right_source.get("mirrorSide", "")) != "right" or String(left_source.get("symmetryGroup", "")) != String(right_source.get("symmetryGroup", "")):
			push_error("Castle courtyard program lost its left/right symmetry pairing")
			continue
		if left_source.has("cityGridMode") or right_source.has("cityGridMode"):
			diagnostics["failureReason"] = "district_source_in_compact_path"
			push_error("Castle seed %d district source reached compact placement" % seed)
			return []
		var requested_node := String(left_source.get("graphNode", "gate_outer"))
		var node: Dictionary = graph_nodes.get(requested_node, graph_nodes["gate_outer"]) as Dictionary
		var grid_row := int(node.get("row", -1))
		var grid_band := String(node.get("band", "outer"))
		var left_residence := LandmarkBuildingRecipeSamplerScript.sample_courtyard_residence(seed, left_source, courtyard_width, courtyard_depth, context)
		var right_residence := left_residence
		var left_recipe: Dictionary = (left_residence.get("recipe", {}) as Dictionary).duplicate(true)
		var right_recipe: Dictionary = (right_residence.get("recipe", {}) as Dictionary).duplicate(true)
		var left_blueprint = courtyard_residence_blueprint_from_recipe(String(left_residence.get("family", "cottage")), left_recipe)
		var right_blueprint = courtyard_residence_blueprint_from_recipe(String(right_residence.get("family", "cottage")), right_recipe)
		if left_blueprint == null or right_blueprint == null:
			push_error("Castle seed %d could not build shared residence blueprints for %s" % [seed, String(left_source.get("symmetryGroup", "pair"))])
			return []
		var left_template := left_source.duplicate(true)
		left_template["residenceFamily"] = String(left_residence.get("family", "cottage"))
		left_template["residenceRecipe"] = left_recipe.duplicate(true)
		var right_template := right_source.duplicate(true)
		right_template["residenceFamily"] = String(right_residence.get("family", "cottage"))
		right_template["residenceRecipe"] = right_recipe.duplicate(true)
		var left_swaps_axes := String(left_source.get("frontDirection", "")) in ["east", "west"]
		var right_swaps_axes := String(right_source.get("frontDirection", "")) in ["east", "west"]
		var left_width := float(left_recipe.get("depth", 6.0)) if left_swaps_axes else float(left_recipe.get("width", 8.0))
		var left_depth := float(left_recipe.get("width", 8.0)) if left_swaps_axes else float(left_recipe.get("depth", 6.0))
		var right_width := float(right_recipe.get("depth", 6.0)) if right_swaps_axes else float(right_recipe.get("width", 8.0))
		var right_depth := float(right_recipe.get("width", 8.0)) if right_swaps_axes else float(right_recipe.get("depth", 6.0))
		var selected_left := courtyard_city_block_center(-1.0, node, left_width, left_depth, courtyard_width, courtyard_depth, gate_width, tower_specs)
		var selected_right := courtyard_city_block_center(1.0, node, right_width, right_depth, courtyard_width, courtyard_depth, gate_width, tower_specs)
		if grid_band == "inner":
			var inner_row_z := courtyard_front_city_block_z(inner_front_cursor, maxf(left_depth, right_depth))
			selected_left.z = inner_row_z
			selected_right.z = inner_row_z
			inner_front_cursor = inner_row_z + maxf(left_depth, right_depth) * 0.5 + 1.50
		else:
			var outer_depth := maxf(left_depth, right_depth)
			var outer_row_min_z := courtyard_front_city_block_z(outer_front_cursor, outer_depth)
			var outer_row_max_z := courtyard_depth * 0.5 - 2.60 - outer_depth * 0.5
			var outer_row_z := minf(outer_row_max_z, maxf(selected_left.z, outer_row_min_z))
			selected_left.z = outer_row_z
			selected_right.z = outer_row_z
			outer_front_cursor = outer_row_z + outer_depth * 0.5 + 1.50
		var shared_abs_x := minf(absf(selected_left.x), absf(selected_right.x))
		selected_left.x = -shared_abs_x
		selected_right.x = shared_abs_x
		var left_front_direction := String(left_source.get("frontDirection", ""))
		var right_front_direction := String(right_source.get("frontDirection", ""))
		var pair_diagnostics := {}
		var pair_resolution := resolve_courtyard_building_pair(selected_left, selected_right, left_width, left_depth, right_width, right_depth, left_front_direction, right_front_direction, left_blueprint, right_blueprint, left_template, right_template, courtyard_width, courtyard_depth, keep_center, keep_width, keep_depth, keep_structure_footprints, tower_specs, result, 1.30, grammar, pair_diagnostics)
		if pair_resolution.is_empty():
			diagnostics["failureReason"] = "courtyard_pair_unplaceable"
			diagnostics["pairId"] = String(left_source.get("symmetryGroup", "pair"))
			diagnostics["pairDiagnostics"] = pair_diagnostics.duplicate(true)
			push_error("Castle seed %d planned city block %s has no legal mirrored fallback slot" % [seed, String(left_source.get("symmetryGroup", "pair"))])
			return []
		selected_left = pair_resolution.get("leftCenter", selected_left) as Vector3
		selected_right = pair_resolution.get("rightCenter", selected_right) as Vector3
		left_front_direction = String(pair_resolution.get("leftFrontDirection", left_front_direction))
		right_front_direction = String(pair_resolution.get("rightFrontDirection", right_front_direction))
		var sources: Array[Dictionary] = [left_source, right_source]
		var centers: Array[Vector3] = [selected_left, selected_right]
		var front_directions: Array[String] = [left_front_direction, right_front_direction]
		var widths: Array[float] = [left_width, right_width]
		var depths: Array[float] = [left_depth, right_depth]
		var residences: Array[Dictionary] = [left_residence, right_residence]
		var recipes: Array[Dictionary] = [left_recipe, right_recipe]
		for side_index in range(2):
			var source: Dictionary = sources[side_index]
			var spec := source.duplicate(true)
			var side_name := "left" if side_index == 0 else "right"
			spec["center"] = centers[side_index]
			spec["resolvedNode"] = "city_block_row_%d_%s_%s" % [grid_row, grid_band, side_name]
			spec["cityGridRow"] = grid_row
			spec["cityGridBand"] = grid_band
			spec["cityGridColumn"] = (0 if grid_band == "outer" else 1) if side_index == 0 else (4 if grid_band == "outer" else 3)
			spec["cityGridMode"] = "compact"
			spec["resolvedPairSlot"] = (pair_resolution.get("slot", {}) as Dictionary).duplicate(true)
			spec["collisionFootprint"] = (pair_resolution.get("leftCollisionFootprint" if side_index == 0 else "rightCollisionFootprint", {}) as Dictionary).duplicate(true)
			spec["compositionDescriptor"] = (pair_resolution.get("leftCompositionDescriptor" if side_index == 0 else "rightCompositionDescriptor", {}) as Dictionary).duplicate(true)
			spec["frontDirection"] = front_directions[side_index]
			spec["width"] = widths[side_index]
			spec["depth"] = depths[side_index]
			spec["residenceFamily"] = String(residences[side_index].get("family", "cottage"))
			spec["residenceRecipe"] = recipes[side_index].duplicate(true)
			spec["residenceFacadeMaterial"] = residence_facade_material(seed, String(spec.get("id", side_name)), masonry_palette)
			spec["terraceElevation"] = citadel_terrace_elevation_at_z(grammar, centers[side_index].z)
			append_residence_transform(spec, castle_foundation_height_for_residence(recipes[side_index]))
			result.append(spec)
	return result

static func residence_facade_material(castle_seed: int, residence_id: String, masonry_palette: Dictionary) -> String:
	# Most inner-city homes take a painted façade, with a minority retaining the
	# civic masonry colour. Stable lot ids make visual personality deterministic
	# without breaking the mirrored street graph or replaying spatial RNG.
	var rng := RandomNumberGenerator.new()
	rng.seed = int(("%d|castle.residence.facade|%s" % [castle_seed, residence_id]).hash())
	var civic_material := String(masonry_palette.get("fortification", "fired_brick"))
	var residences: Array = masonry_palette.get("residences", [civic_material]) as Array
	if residences.is_empty() or rng.randf() < 0.16:
		return civic_material
	return String(residences[rng.randi_range(0, residences.size() - 1)])


static func courtyard_city_grid_nodes() -> Dictionary:
	# Grid rows run gate (4) to rear wall (0).  The outer band begins at the
	# curtain walls with a service setback. The only inner lots are in front of
	# the keep, where their door streets lead to the public axis rather than
	# dead-ending against its masonry.
	return {
		"gate_outer": {"z": -0.34, "row": 4, "band": "outer"},
		"lower_outer": {"z": -0.10, "row": 3, "band": "outer"},
		"middle_outer": {"z": 0.10, "row": 2, "band": "outer"},
		"rear_outer": {"z": 0.30, "row": 0, "band": "outer"},
		"gate_inner": {"z": -0.44, "row": 4, "band": "inner"},
		"lower_inner": {"z": -0.30, "row": 3, "band": "inner"}
	}


static func courtyard_city_block_center(side: float, node: Dictionary, width: float, depth: float, courtyard_width: float, courtyard_depth: float, gate_width: float, tower_specs: Array[Dictionary]) -> Vector3:
	var wall_setback := 2.60
	var street_width := 3.20
	var half_width := courtyard_width * 0.5
	var side_tower_setback := courtyard_side_tower_setback(side, half_width, tower_specs)
	var max_x := maxf(0.0, half_width - maxf(wall_setback, side_tower_setback) - width * 0.5)
	var max_z := maxf(0.0, courtyard_depth * 0.5 - wall_setback - depth * 0.5)
	var route_half_width := maxf(2.40, gate_width * 0.5 + 1.00)
	var band := String(node.get("band", "outer"))
	var x := half_width - maxf(wall_setback, side_tower_setback) - width * 0.5
	if band == "inner":
		x = route_half_width + width * 0.5 + street_width
	return Vector3(side * minf(max_x, x), 0.0, clampf(courtyard_depth * float(node.get("z", 0.0)), -max_z, max_z))


static func courtyard_front_city_block_z(front_cursor: float, depth: float) -> float:
	return front_cursor + depth * 0.5


static func courtyard_side_tower_setback(side: float, half_width: float, tower_specs: Array[Dictionary]) -> float:
	var result := 0.0
	for tower_spec in tower_specs:
		var tower_position: Vector3 = tower_spec.get("position", Vector3.ZERO) as Vector3
		# Only the towers seated on this curtain wall reserve its service lane;
		# the two gate flanks are handled by the front-row cursor instead.
		if signf(tower_position.x) != signf(side) or absf(tower_position.x) < half_width * 0.70:
			continue
		result = maxf(result, float(tower_spec.get("span", 0.0)) * 0.5 + 0.34)
	return result


static func courtyard_inner_front_cursor(courtyard_depth: float, tower_specs: Array[Dictionary]) -> float:
	# Gatehouse flank towers are part of the deterministic compound grammar, not
	# optional scenery. Start the first inner block after their physical depth so
	# every grid row has a real cross-street from the gate instead of clipping a
	# tower's foundation on six/eight-tower variants.
	var front_setback := 2.70
	for tower_spec in tower_specs:
		if String(tower_spec.get("role", "")).begins_with("north_gate_flank"):
			front_setback = maxf(front_setback, float(tower_spec.get("span", 0.0)) * 0.5 + 0.34)
	return -courtyard_depth * 0.5 + front_setback


static func castle_foundation_height_for_residence(_residence_recipe: Dictionary) -> float:
	# This remains one compound foundation datum.  Keeping it in this helper
	# prevents the construction and furnishing transforms from quietly diverging.
	return 0.62


static func citadel_keep_terrace_elevation(grammar: Dictionary) -> float:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	if String(grid.get("mode", "")) != "district_grid":
		return 0.0
	var courtyard_depth := float(grammar.get("courtyardDepth", 0.0))
	var keep_depth := float(grammar.get("keepDepth", 0.0))
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	var keep_front_z := courtyard_depth * float(keep_offset.get("z", 0.14)) - keep_depth * 0.5
	return citadel_terrace_elevation_at_z(grid, keep_front_z)


static func append_residence_transform(spec: Dictionary, castle_foundation_height: float) -> void:
	var center: Vector3 = spec.get("center", Vector3.ZERO) as Vector3
	var recipe: Dictionary = spec.get("residenceRecipe", {}) as Dictionary
	var source_foundation_height := float(recipe.get("foundationHeight", 0.48))
	# Cottage/manor source doors point down local -Z. District homes choose the
	# nearest boulevard or cross-street as their frontage, so a city block reads
	# as connected streets instead of every door staring at the keep wall.
	var front_direction := String(spec.get("frontDirection", ""))
	var yaw := residence_yaw_for_front_direction(front_direction)
	spec["yaw"] = yaw
	spec["origin"] = Vector3(center.x, castle_foundation_height - source_foundation_height + float(spec.get("terraceElevation", 0.0)), center.z)


static func residence_yaw_for_front_direction(front_direction: String) -> float:
	return CastleResidencePlacementGeometryScript.yaw_for_front_direction(front_direction)


static func keep_collision_footprints(parts: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for part in parts:
		if part == null or not bool(part.collision_enabled) or (not String(part.id).begins_with("castle_keep_") and not String(part.id).begins_with("castle_tower_")):
			continue
		var yaw := float(part.rotation.y)
		var footprint_width: float = absf(cos(yaw)) * float(part.size.x) + absf(sin(yaw)) * float(part.size.z)
		var footprint_depth: float = absf(sin(yaw)) * float(part.size.x) + absf(cos(yaw)) * float(part.size.z)
		result.append({"partId": String(part.id), "center": part.position, "size": part.size, "basis": Basis.from_euler(part.rotation), "width": footprint_width, "depth": footprint_depth})
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left.get("partId", "")) < String(right.get("partId", ""))
	)
	return result


static func resolve_courtyard_building_pair(requested_left: Vector3, requested_right: Vector3, left_width: float, left_depth: float, right_width: float, right_depth: float, left_front_direction: String, right_front_direction: String, left_source_blueprint, right_source_blueprint, left_template: Dictionary, right_template: Dictionary, courtyard_width: float, courtyard_depth: float, keep_center: Vector3, keep_width: float, keep_depth: float, keep_structure_footprints: Array[Dictionary], tower_specs: Array[Dictionary], placed: Array[Dictionary], neighbour_clearance: float, grammar: Dictionary, diagnostics: Dictionary = {}) -> Dictionary:
	var base_abs_x := maxf(absf(requested_left.x), absf(requested_right.x))
	var base_z := (requested_left.z + requested_right.z) * 0.5
	var step := 2.40
	var offsets: Array[Vector2] = [Vector2.ZERO]
	for ring in range(1, 9):
		for z_index in range(-ring, ring + 1):
			var x_index := ring - absi(z_index)
			offsets.append(Vector2(float(x_index), float(z_index)))
			if x_index > 0:
				offsets.append(Vector2(float(-x_index), float(z_index)))
	var direction_pairs := [
		[left_front_direction, right_front_direction],
		[opposite_front_direction(left_front_direction), opposite_front_direction(right_front_direction)]
	]
	var rejection_counts := {"invalidComposition": 0, "pairCollision": 0, "outsideBounds": 0, "environmentCollision": 0}
	var last_invalid_composition: Dictionary = {}
	for offset_index in range(offsets.size()):
		var offset: Vector2 = offsets[offset_index]
		var candidate_abs_x := maxf(maxf(left_width, right_width) * 0.5 + 0.70, base_abs_x + offset.x * step)
		var candidate_z := base_z + offset.y * step
		var left_center := Vector3(-candidate_abs_x, 0.0, candidate_z)
		var right_center := Vector3(candidate_abs_x, 0.0, candidate_z)
		for direction_pair_value in direction_pairs:
			var direction_pair: Array = direction_pair_value
			var candidate_left_front := String(direction_pair[0])
			var candidate_right_front := String(direction_pair[1])
			var left_candidate := resolved_residence_candidate(left_template, left_center, candidate_left_front, left_width, left_depth, grammar)
			var right_candidate := resolved_residence_candidate(right_template, right_center, candidate_right_front, right_width, right_depth, grammar)
			var left_composition := residence_composition_descriptor(left_candidate, left_source_blueprint, 0.62)
			var right_composition := residence_composition_descriptor(right_candidate, right_source_blueprint, 0.62)
			var left_blocker := residence_composition_blocker(left_composition)
			var right_blocker := residence_composition_blocker(right_composition)
			if not left_blocker.is_empty() or not right_blocker.is_empty():
				rejection_counts["invalidComposition"] = int(rejection_counts["invalidComposition"]) + 1
				last_invalid_composition = left_blocker if not left_blocker.is_empty() else right_blocker
				continue
			if residence_compositions_overlap(left_composition, right_composition, 2.60):
				rejection_counts["pairCollision"] = int(rejection_counts["pairCollision"]) + 1
				continue
			var left_collision_footprint: Dictionary = left_composition.get("aggregateFootprint", {}) as Dictionary
			var right_collision_footprint: Dictionary = right_composition.get("aggregateFootprint", {}) as Dictionary
			if left_collision_footprint.is_empty() or right_collision_footprint.is_empty():
				continue
			if not courtyard_pair_inside_bounds(left_collision_footprint, right_collision_footprint, courtyard_width, courtyard_depth):
				rejection_counts["outsideBounds"] = int(rejection_counts["outsideBounds"]) + 1
				continue
			if not courtyard_building_footprint_is_clear(left_center, left_width, left_depth, candidate_left_front, left_collision_footprint, left_composition, keep_center, keep_width, keep_depth, keep_structure_footprints, tower_specs, placed, neighbour_clearance):
				rejection_counts["environmentCollision"] = int(rejection_counts["environmentCollision"]) + 1
				continue
			if not courtyard_building_footprint_is_clear(right_center, right_width, right_depth, candidate_right_front, right_collision_footprint, right_composition, keep_center, keep_width, keep_depth, keep_structure_footprints, tower_specs, placed, neighbour_clearance):
				rejection_counts["environmentCollision"] = int(rejection_counts["environmentCollision"]) + 1
				continue
			return {
				"leftCenter": left_center,
				"rightCenter": right_center,
				"leftFrontDirection": candidate_left_front,
				"rightFrontDirection": candidate_right_front,
				"leftCollisionFootprint": left_collision_footprint,
				"rightCollisionFootprint": right_collision_footprint,
				"leftCompositionDescriptor": left_composition,
				"rightCompositionDescriptor": right_composition,
				"slot": {"index": offset_index, "offset": offset, "fallback": offset_index > 0 or direction_pair != direction_pairs[0]}
			}
	push_error("Castle residence pair composition rejection: %s" % JSON.stringify({"leftId": String(left_template.get("id", "")), "rightId": String(right_template.get("id", "")), "counts": rejection_counts, "lastInvalidComposition": last_invalid_composition}))
	diagnostics["leftId"] = String(left_template.get("id", ""))
	diagnostics["rightId"] = String(right_template.get("id", ""))
	diagnostics["rejectionCounts"] = rejection_counts.duplicate(true)
	diagnostics["lastInvalidComposition"] = last_invalid_composition.duplicate(true)
	return {}


static func courtyard_pair_inside_bounds(left_footprint: Dictionary, right_footprint: Dictionary, courtyard_width: float, courtyard_depth: float) -> bool:
	var inset := 0.90
	var left_center: Vector3 = left_footprint.get("center", Vector3.ZERO) as Vector3
	var right_center: Vector3 = right_footprint.get("center", Vector3.ZERO) as Vector3
	return absf(left_center.x) + float(left_footprint.get("width", 0.0)) * 0.5 <= courtyard_width * 0.5 - inset \
		and absf(right_center.x) + float(right_footprint.get("width", 0.0)) * 0.5 <= courtyard_width * 0.5 - inset \
		and absf(left_center.z) + float(left_footprint.get("depth", 0.0)) * 0.5 <= courtyard_depth * 0.5 - inset \
		and absf(right_center.z) + float(right_footprint.get("depth", 0.0)) * 0.5 <= courtyard_depth * 0.5 - inset


static func courtyard_building_footprint_is_clear(center: Vector3, width: float, depth: float, front_direction: String, collision_footprint: Dictionary, composition: Dictionary, keep_center: Vector3, keep_width: float, keep_depth: float, keep_structure_footprints: Array[Dictionary], tower_specs: Array[Dictionary], placed: Array[Dictionary], neighbour_clearance := 1.30) -> bool:
	var collision_center: Vector3 = collision_footprint.get("center", center) as Vector3
	var collision_width := float(collision_footprint.get("width", width))
	var collision_depth := float(collision_footprint.get("depth", depth))
	if residence_composition_overlaps_obstacles(composition, keep_structure_footprints, 0.04):
		return false
	for placed_spec in placed:
		var placed_composition: Dictionary = placed_spec.get("compositionDescriptor", {}) as Dictionary
		if not placed_composition.is_empty() and residence_compositions_overlap(composition, placed_composition, neighbour_clearance):
			return false
		var placed_footprint: Dictionary = placed_spec.get("collisionFootprint", {}) as Dictionary
		var placed_center: Vector3 = placed_footprint.get("center", placed_spec.get("center", Vector3.ZERO)) as Vector3
		var placed_width := float(placed_footprint.get("width", placed_spec.get("width", 7.0)))
		var placed_depth := float(placed_footprint.get("depth", placed_spec.get("depth", 6.0)))
		if footprint_overlaps(collision_center, collision_width, collision_depth, placed_center, placed_width, placed_depth, neighbour_clearance):
			return false
	return true


static func courtyard_building_collision_provenance(candidate_id: String, candidate_side: String, _collision_footprint: Dictionary, composition: Dictionary, keep_structure_footprints: Array[Dictionary], placed: Array[Dictionary], neighbour_clearance: float) -> Dictionary:
	return CastleResidencePlacementGeometryScript.first_overlap_provenance(candidate_id, candidate_side, composition, keep_structure_footprints, placed, neighbour_clearance)


static func residence_composition_overlaps_obstacles(composition: Dictionary, obstacles: Array[Dictionary], clearance: float) -> bool:
	return CastleResidencePlacementGeometryScript.composition_overlaps_obstacles(composition, obstacles, clearance)


static func resolved_residence_candidate(template: Dictionary, center: Vector3, front_direction: String, width: float, depth: float, grammar: Dictionary) -> Dictionary:
	var candidate := template.duplicate(true)
	var recipe: Dictionary = candidate.get("residenceRecipe", {}) as Dictionary
	var terrace_elevation := citadel_terrace_elevation_at_z(grammar, center.z)
	candidate["center"] = center
	candidate["frontDirection"] = front_direction
	candidate["width"] = width
	candidate["depth"] = depth
	candidate["terraceElevation"] = terrace_elevation
	candidate["yaw"] = residence_yaw_for_front_direction(front_direction)
	candidate["origin"] = Vector3(center.x, 0.62 - float(recipe.get("foundationHeight", 0.48)) + terrace_elevation, center.z)
	return candidate


static func residence_composition_descriptor(spec: Dictionary, source_blueprint, compound_foundation_height: float) -> Dictionary:
	return CastleResidencePlacementGeometryScript.describe_residence(spec, source_blueprint, compound_foundation_height)


static func residence_composition_part(spec: Dictionary, part_id: String) -> Dictionary:
	for part_value in (spec.get("compositionDescriptor", {}) as Dictionary).get("collisionParts", []) as Array:
		var part: Dictionary = part_value as Dictionary
		if String(part.get("id", "")) == part_id:
			return part
	return {}


static func residence_composition_part_by_role(spec: Dictionary, role: String) -> Dictionary:
	for part_value in (spec.get("compositionDescriptor", {}) as Dictionary).get("collisionParts", []) as Array:
		var part: Dictionary = part_value as Dictionary
		if String(part.get("role", "")) == role:
			return part
	return {}


static func residence_composition_source_part(spec: Dictionary, source_part_id: String) -> Dictionary:
	for part_value in (spec.get("compositionDescriptor", {}) as Dictionary).get("collisionParts", []) as Array:
		var part: Dictionary = part_value as Dictionary
		if String(part.get("role", "")) == "source" and String(part.get("sourcePartId", "")) == source_part_id:
			return part
	return {}


static func sampler_forecourt_layout_valid(palace_grammar: Dictionary) -> bool:
	var layout_value = palace_grammar.get("forecourtLayout", null)
	var hash_value = palace_grammar.get("forecourtLayoutHash", null)
	if not layout_value is Array or typeof(hash_value) != TYPE_STRING or String(hash_value).is_empty():
		return false
	var layout: Array = layout_value as Array
	if layout.size() != 2 or JSON.stringify(layout).sha256_text() != String(hash_value):
		return false
	var seen_sides := {}
	for layout_record_value in layout:
		if not layout_record_value is Dictionary:
			return false
		var layout_record: Dictionary = layout_record_value as Dictionary
		var side_value = layout_record.get("side", null)
		if typeof(side_value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(side_value)) or float(side_value) not in [-1.0, 1.0] or seen_sides.has(str(float(side_value))):
			return false
		seen_sides[str(float(side_value))] = true
		for vector_key in ["galleryCenter", "pavilionCenter"]:
			var vector_value = layout_record.get(vector_key, null)
			if typeof(vector_value) != TYPE_VECTOR3 or not (vector_value as Vector3).is_finite():
				return false
		for numeric_key in ["galleryWidth", "galleryHeight", "arcadeDepth", "galleryBayCount", "pavilionDepth", "pavilionHeight", "pavilionWidth"]:
			var numeric_value = layout_record.get(numeric_key, null)
			if typeof(numeric_value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(numeric_value)) or float(numeric_value) <= 0.0:
				return false
		for footprint_key in ["galleryFootprint", "pavilionFootprint"]:
			var footprint_value = layout_record.get(footprint_key, null)
			if not footprint_value is Dictionary:
				return false
			var footprint: Dictionary = footprint_value as Dictionary
			if typeof(footprint.get("center", null)) != TYPE_VECTOR3 or not (footprint.get("center") as Vector3).is_finite():
				return false
			for extent_key in ["width", "depth"]:
				var extent_value = footprint.get(extent_key, null)
				if typeof(extent_value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(extent_value)) or float(extent_value) <= 0.0:
					return false
	return seen_sides.size() == 2


static func sampler_entry_approach_valid(palace_grammar: Dictionary) -> bool:
	var approach_value = palace_grammar.get("entryApproach", null)
	var hash_value = palace_grammar.get("entryApproachHash", null)
	if not approach_value is Dictionary or typeof(hash_value) != TYPE_STRING or String(hash_value).is_empty():
		return false
	var approach: Dictionary = approach_value as Dictionary
	if JSON.stringify(approach).sha256_text() != String(hash_value):
		return false
	for key in ["portalFrontZ", "routeTerminalZ", "terminalInset", "rampApproachLength", "rampStartZ", "civicCoreDepth", "entranceTowerDepth"]:
		var value = approach.get(key, null)
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
			return false
	var portal_front_z := float(approach.get("portalFrontZ"))
	var route_terminal_z := float(approach.get("routeTerminalZ"))
	var terminal_inset := float(approach.get("terminalInset"))
	var ramp_length := float(approach.get("rampApproachLength"))
	var ramp_start_z := float(approach.get("rampStartZ"))
	return terminal_inset > 0.0 and ramp_length > 0.0 and float(approach.get("civicCoreDepth")) > 0.0 and float(approach.get("entranceTowerDepth")) > 0.0 \
		and is_equal_approx(portal_front_z - route_terminal_z, terminal_inset) \
		and is_equal_approx(portal_front_z - ramp_start_z, ramp_length) \
		and ramp_start_z < route_terminal_z


static func sampled_residence_authority_valid(source: Dictionary, lot_pair: Dictionary, side: String) -> bool:
	var family_value = source.get("residenceFamily", null)
	var recipe_value = source.get("residenceRecipe", null)
	var recipe_hash_value = source.get("residenceRecipeHash", null)
	var intent_id_value = source.get("placementIntentId", null)
	var ordinal_value = source.get("placementOrdinal", null)
	if typeof(family_value) != TYPE_STRING or String(family_value) not in ["cottage", "manor"] or not recipe_value is Dictionary or (recipe_value as Dictionary).is_empty() or typeof(recipe_hash_value) != TYPE_STRING or String(recipe_hash_value).is_empty() or typeof(intent_id_value) != TYPE_STRING or String(intent_id_value).is_empty() or String(intent_id_value) != String(source.get("id", "")) or typeof(ordinal_value) != TYPE_INT or int(ordinal_value) < 0 or String(source.get("placementMode", "")) != "post_geometry_exact":
		return false
	var family := String(family_value)
	var recipe: Dictionary = recipe_value as Dictionary
	var expected_hash := LandmarkBuildingRecipeSamplerScript.courtyard_residence_recipe_hash(family, recipe)
	if String(recipe_hash_value) != expected_hash:
		return false
	var pair_prefix := "left" if side == "left" else "right"
	return String(lot_pair.get("%sResidenceFamily" % pair_prefix, "")) == family \
		and String(lot_pair.get("%sResidenceRecipeHash" % pair_prefix, "")) == expected_hash \
		and JSON.stringify(lot_pair.get("%sResidenceRecipe" % pair_prefix, {})) == JSON.stringify(recipe) \
		and String(lot_pair.get("%sPlacementIntentId" % pair_prefix, "")) == String(intent_id_value)


static func residence_composition_is_valid(composition: Dictionary) -> bool:
	return CastleResidencePlacementGeometryScript.composition_blocker(composition).is_empty()


static func residence_composition_blocker(composition: Dictionary) -> Dictionary:
	return CastleResidencePlacementGeometryScript.composition_blocker(composition)


static func residence_compositions_overlap(first: Dictionary, second: Dictionary, clearance: float) -> bool:
	return CastleResidencePlacementGeometryScript.compositions_overlap(first, second, clearance)


static func residence_egress_footprint_overlaps(center: Vector3, width: float, depth: float, front_direction: String, obstacle_center: Vector3, obstacle_width: float, obstacle_depth: float) -> bool:
	# The main shell can be clear while a manor portico and its declared public
	# transition run directly into the keep. Reserve the full shared egress lane
	# during lot validation, before either collider is published.
	const EGRESS_RUN := 3.75
	const EGRESS_WIDTH_MARGIN := 0.72
	var egress_center := center
	var egress_width := width + EGRESS_WIDTH_MARGIN * 2.0
	var egress_depth := depth + EGRESS_WIDTH_MARGIN * 2.0
	match front_direction:
		"north":
			egress_center.z -= depth * 0.5 + EGRESS_RUN * 0.5
			egress_depth = EGRESS_RUN
		"south":
			egress_center.z += depth * 0.5 + EGRESS_RUN * 0.5
			egress_depth = EGRESS_RUN
		"east":
			egress_center.x += width * 0.5 + EGRESS_RUN * 0.5
			egress_width = EGRESS_RUN
			egress_depth = depth + EGRESS_WIDTH_MARGIN * 2.0
		"west":
			egress_center.x -= width * 0.5 + EGRESS_RUN * 0.5
			egress_width = EGRESS_RUN
			egress_depth = depth + EGRESS_WIDTH_MARGIN * 2.0
		_:
			return false
	return footprint_overlaps(egress_center, egress_width, egress_depth, obstacle_center, obstacle_width, obstacle_depth, 0.18)


static func opposite_front_direction(front_direction: String) -> String:
	match front_direction:
		"north":
			return "south"
		"south":
			return "north"
		"east":
			return "west"
		"west":
			return "east"
		_:
			return front_direction


static func footprint_overlaps(first_center: Vector3, first_width: float, first_depth: float, second_center: Vector3, second_width: float, second_depth: float, clearance := 0.0) -> bool:
	return CastleResidencePlacementGeometryScript.footprint_overlaps(first_center, first_width, first_depth, second_center, second_width, second_depth, clearance)


static func add_district_streets(blueprint, grammar: Dictionary, foundation_height: float, variation: float) -> void:
	# Streets are part of the compound grammar, not omitted ground between a
	# collection of homes. Every route receives one continuous collision-bearing
	# roadbed whose top is aligned with the decorative paving layered over it.
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	if String(grid.get("mode", "")) != "district_grid":
		return
	var street_records: Array = grid.get("streetRecords", []) as Array
	add_raised_route_junctions(blueprint, street_records, foundation_height, variation)
	var protected_route_supports := raised_route_existing_support_bounds(blueprint)
	var route_coverage_records: Array = []
	for record_value in street_records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value as Dictionary
		var width := float(record.get("width", 0.0))
		var depth := float(record.get("depth", 0.0))
		if width <= 0.20 or depth <= 0.20:
			continue
		var street_elevation := float(record.get("elevation", citadel_terrace_elevation_at_z(grid, float(record.get("z", 0.0)))))
		var street_id := String(record.get("id", "street"))
		var street_center := Vector3(float(record.get("x", 0.0)), 0.0, float(record.get("z", 0.0)))
		if not bool(record.get("transitionOwned", false)):
			add_elevated_street_roadbed(blueprint, street_id, street_center, width, depth, foundation_height, street_elevation, variation)
		var route_coverage := raised_route_record_coverage(blueprint, street_id, street_center, width, depth, foundation_height, street_elevation, false, record.get("allowedTransitionOwnerIds", []) as Array, float(record.get("handoffSeamZ", INF)), String(record.get("handoffTransitionOwnerId", "")), String(record.get("handoffTransitionSemantic", "")), String(record.get("handoffSourceOwnerId", "")), String(record.get("handoffSourceSemantic", "castle_route_terrace_walkway")), bool(record.get("transitionOwned", false)))
		route_coverage_records.append(route_coverage)
		if not bool(route_coverage.get("passed", false)):
			continue
		var center := Vector3(float(record.get("x", 0.0)), foundation_height + street_elevation + 0.155, float(record.get("z", 0.0)))
		var runs_along_z := depth >= width
		var longitudinal_span := depth if runs_along_z else width
		var available_cross_span := width if runs_along_z else depth
		var base_channel_span := minf(3.45, available_cross_span * 0.60)
		var module_count := clampi(int(ceil(longitudinal_span / 1.9)), 2, 72)
		var module_run := longitudinal_span / float(module_count)
		for module_index in range(module_count):
			var stable_phase := float((street_id.hash() + module_index * 17) % 9)
			var width_bias := (stable_phase - 4.0) * 0.045
			var module_cross_span := clampf(base_channel_span + width_bias, base_channel_span * 0.86, available_cross_span * 0.68)
			var lateral_offset := sin(float(module_index) * 1.73 + float(street_id.hash() % 11)) * 0.12
			var longitudinal_offset := -longitudinal_span * 0.5 + module_run * (float(module_index) + 0.5)
			var module_center := center + (Vector3(lateral_offset, 0.008 + absf(lateral_offset) * 0.02, longitudinal_offset) if runs_along_z else Vector3(longitudinal_offset, 0.008 + absf(lateral_offset) * 0.02, lateral_offset))
			var module_size := Vector3(module_cross_span, 0.07, module_run + 0.035) if runs_along_z else Vector3(module_run + 0.035, 0.07, module_cross_span)
			if not route_visual_overlaps_protected_support(module_center, module_size, protected_route_supports):
				add_part(blueprint, "castle_district_%s_cobble_%03d" % [street_id, module_index], "foundation", "cobblestone", module_center, module_size, {"variation": variation - 0.035 + width_bias * 0.4, "collision": false, "semantic": "castle_route_cobbled_module", "pavingFamily": "lane_cobbles", "pavingRegion": "castle_route_%s" % street_id, "pavingHeading": "z" if runs_along_z else "x"})
		var cross_span := width if runs_along_z else depth
		var margin_span := maxf(0.34, (cross_span - base_channel_span) * 0.5)
		for side in [-1.0, 1.0]:
			var margin_offset: float = side * (base_channel_span * 0.5 + margin_span * 0.5)
			var margin_center := center + (Vector3(margin_offset, 0.012, 0.0) if runs_along_z else Vector3(0.0, 0.012, margin_offset))
			var margin_size := Vector3(margin_span, 0.045, depth) if runs_along_z else Vector3(width, 0.045, margin_span)
			if not route_visual_overlaps_protected_support(margin_center, margin_size, protected_route_supports):
				add_part(blueprint, "castle_district_%s_margin_%d" % [street_id, int(side)], "foundation", "stone_foundation", margin_center, margin_size, {"variation": variation + 0.035 + side * 0.006, "collision": false, "semantic": "castle_route_pedestrian_margin"})
		var drain_offset := base_channel_span * 0.5 + 0.16
		var drain_center := center + (Vector3(drain_offset, 0.022, 0.0) if runs_along_z else Vector3(0.0, 0.022, drain_offset))
		var drain_size := Vector3(0.28, 0.055, depth) if runs_along_z else Vector3(width, 0.055, 0.28)
		if not route_visual_overlaps_protected_support(drain_center, drain_size, protected_route_supports):
			add_part(blueprint, "castle_district_%s_drain" % street_id, "foundation", "stone_foundation", drain_center, drain_size, {"collision": false, "variation": variation - 0.08, "semantic": "castle_route_constructed_gutter"})


static func add_elevated_street_roadbed(blueprint, street_id: String, center: Vector3, width: float, depth: float, foundation_height: float, street_elevation: float, variation: float) -> void:
	# The roadbed starts at the already-grounded courtyard foundation and reaches
	# the decorative paving's visible top surface. It is both the retaining mass
	# and the single physical/nav surface for this route. Existing stairs
	# and the keep-entry ramp already own their own support volumes, so carve their
	# footprint out of the street support instead of publishing overlapping floors.
	var roadbed_height := street_elevation + 0.20
	var segments: Array[AABB] = [AABB(Vector3(center.x - width * 0.5, 0.0, center.z - depth * 0.5), Vector3(width, 0.01, depth))]
	for protected_bounds in raised_route_existing_support_bounds(blueprint):
		segments = subtract_roadbed_footprint(segments, protected_bounds)
	var segment_index := 0
	for segment in segments:
		if segment.size.x <= 0.20 or segment.size.z <= 0.20:
			continue
		segment_index += 1
		var segment_center := segment.position + segment.size * 0.5
		var support_ids: Array[String] = []
		for foundation in blueprint.parts:
			if foundation == null or String(foundation.semantic) != "castle_courtyard_foundation" or not bool(foundation.collision_enabled) or not bool(foundation.recipe.get("physicalRoot", false)):
				continue
			if absf(foundation.position.y + foundation.size.y * 0.5 - foundation_height) > 0.04:
				continue
			var foundation_bounds := AABB(Vector3(foundation.position.x - foundation.size.x * 0.5, 0.0, foundation.position.z - foundation.size.z * 0.5), Vector3(foundation.size.x, 0.01, foundation.size.z))
			if segment.intersects(foundation_bounds):
				support_ids.append(String(foundation.id))
		if not roadbed_has_courtyard_foundation_support(blueprint, segment_center, segment.size, foundation_height):
			var uncovered: Array[AABB] = [segment]
			for foundation in blueprint.parts:
				if foundation == null or String(foundation.semantic) != "castle_courtyard_foundation" or not bool(foundation.collision_enabled) or not bool(foundation.recipe.get("physicalRoot", false)) or absf(foundation.position.y + foundation.size.y * 0.5 - foundation_height) > 0.04:
					continue
				uncovered = subtract_roadbed_footprint(uncovered, AABB(Vector3(foundation.position.x - foundation.size.x * 0.5, 0.0, foundation.position.z - foundation.size.z * 0.5), Vector3(foundation.size.x, 0.01, foundation.size.z)))
			var retaining_index := 0
			for retaining in uncovered:
				retaining_index += 1
				var retaining_id := "castle_district_%s_retaining_foundation_%02d_%02d" % [street_id, segment_index, retaining_index]
				var retaining_center := retaining.position + retaining.size * 0.5
				add_part(blueprint, retaining_id, "foundation", "stone_foundation", Vector3(retaining_center.x, foundation_height * 0.5, retaining_center.z), Vector3(retaining.size.x, foundation_height, retaining.size.z), {"variation": variation - 0.04, "semantic": "castle_courtyard_foundation", "navigationRole": "structural_mass", "physicalIntent": "structural_root", "physicalRoot": true})
				support_ids.append(retaining_id)
		if support_ids.is_empty():
			push_error("Raised route %s segment %d has no declared rooted support: segment=%s" % [street_id, segment_index, segment])
			continue
		var roadbed = add_part(blueprint, "castle_district_%s_roadbed_%02d" % [street_id, segment_index], "foundation", "stone_foundation", Vector3(segment_center.x, foundation_height + roadbed_height * 0.5, segment_center.z), Vector3(segment.size.x, roadbed_height, segment.size.z), {"variation": variation - 0.03, "semantic": "castle_route_terrace_walkway", "navigationRole": "walkable_support", "routeStreetId": street_id})
		roadbed.recipe["physicalRequiredSupportPartIds"] = support_ids
		# Every contacting foundation is a required bearing, including narrow strips
		# between sample columns. Preserve the route owner's support list verbatim;
		# prove named contacts as seats and independently require full rooted coverage.
		roadbed.recipe["physicalRequiredSeatPartIds"] = support_ids.duplicate()
		roadbed.recipe["physicalAssemblyRole"] = "walkable_subfloor"


static func add_raised_route_junctions(blueprint, street_records: Array, foundation_height: float, variation: float) -> void:
	var junction_index := 0
	for first_index in range(street_records.size()):
		if not street_records[first_index] is Dictionary:
			continue
		var first: Dictionary = street_records[first_index] as Dictionary
		if bool(first.get("transitionOwned", false)):
			continue
		var first_width := float(first.get("width", 0.0))
		var first_depth := float(first.get("depth", 0.0))
		if first_width <= 0.20 or first_depth <= 0.20:
			continue
		var first_elevation := float(first.get("elevation", 0.0))
		var first_bounds := AABB(Vector3(float(first.get("x", 0.0)) - first_width * 0.5, 0.0, float(first.get("z", 0.0)) - first_depth * 0.5), Vector3(first_width, 0.01, first_depth))
		for second_index in range(first_index + 1, street_records.size()):
			if not street_records[second_index] is Dictionary:
				continue
			var second: Dictionary = street_records[second_index] as Dictionary
			if bool(second.get("transitionOwned", false)):
				continue
			if absf(float(second.get("elevation", 0.0)) - first_elevation) > 0.04:
				continue
			var second_width := float(second.get("width", 0.0))
			var second_depth := float(second.get("depth", 0.0))
			if second_width <= 0.20 or second_depth <= 0.20:
				continue
			var second_bounds := AABB(Vector3(float(second.get("x", 0.0)) - second_width * 0.5, 0.0, float(second.get("z", 0.0)) - second_depth * 0.5), Vector3(second_width, 0.01, second_depth))
			if not first_bounds.intersects(second_bounds):
				continue
			var junction_bounds := first_bounds.intersection(second_bounds)
			if junction_bounds.size.x <= 0.20 or junction_bounds.size.z <= 0.20:
				continue
			junction_index += 1
			var junction_id := "castle_district_route_junction_%02d" % junction_index
			var support_ids: Array[String] = []
			for foundation in blueprint.parts:
				if foundation == null or String(foundation.semantic) != "castle_courtyard_foundation" or not bool(foundation.collision_enabled) or not bool(foundation.recipe.get("physicalRoot", false)):
					continue
				if absf(foundation.position.y + foundation.size.y * 0.5 - foundation_height) > 0.04:
					continue
				var foundation_bounds := AABB(Vector3(foundation.position.x - foundation.size.x * 0.5, 0.0, foundation.position.z - foundation.size.z * 0.5), Vector3(foundation.size.x, 0.01, foundation.size.z))
				if junction_bounds.intersects(foundation_bounds):
					support_ids.append(String(foundation.id))
			if not roadbed_has_courtyard_foundation_support(blueprint, junction_bounds.position + junction_bounds.size * 0.5, junction_bounds.size, foundation_height):
				var uncovered: Array[AABB] = [junction_bounds]
				for foundation in blueprint.parts:
					if foundation == null or String(foundation.semantic) != "castle_courtyard_foundation" or not bool(foundation.collision_enabled) or not bool(foundation.recipe.get("physicalRoot", false)) or absf(foundation.position.y + foundation.size.y * 0.5 - foundation_height) > 0.04:
						continue
					uncovered = subtract_roadbed_footprint(uncovered, AABB(Vector3(foundation.position.x - foundation.size.x * 0.5, 0.0, foundation.position.z - foundation.size.z * 0.5), Vector3(foundation.size.x, 0.01, foundation.size.z)))
				var retaining_index := 0
				for retaining in uncovered:
					retaining_index += 1
					var retaining_id := "%s_retaining_foundation_%02d" % [junction_id, retaining_index]
					var retaining_center := retaining.position + retaining.size * 0.5
					add_part(blueprint, retaining_id, "foundation", "stone_foundation", Vector3(retaining_center.x, foundation_height * 0.5, retaining_center.z), Vector3(retaining.size.x, foundation_height, retaining.size.z), {"variation": variation - 0.04, "semantic": "castle_courtyard_foundation", "navigationRole": "structural_mass", "physicalIntent": "structural_root", "physicalRoot": true})
					support_ids.append(retaining_id)
			if support_ids.is_empty():
				push_error("Raised route junction %s has no declared rooted support" % junction_id)
				continue
			var junction_center := junction_bounds.position + junction_bounds.size * 0.5
			var junction_height := first_elevation + 0.20
			var junction = add_part(blueprint, junction_id, "foundation", "stone_foundation", Vector3(junction_center.x, foundation_height + junction_height * 0.5, junction_center.z), Vector3(junction_bounds.size.x, junction_height, junction_bounds.size.z), {"variation": variation - 0.026, "semantic": "castle_route_junction", "navigationRole": "walkable_support", "routeIncidentStreetIds": [String(first.get("id", "")), String(second.get("id", ""))], "physicalIntent": "walkable_surface"})
			junction.recipe["physicalRequiredSupportPartIds"] = support_ids


static func raised_route_record_coverage(blueprint, street_id: String, center: Vector3, width: float, depth: float, foundation_height: float, street_elevation: float, verify_root_chain := false, allowed_transition_owner_ids: Array = [], handoff_seam_z := INF, handoff_transition_owner_id := "", handoff_transition_semantic := "", handoff_source_owner_id := "", handoff_source_semantic := "castle_route_terrace_walkway", transition_owned := false, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	if transition_owned:
		return raised_route_transition_owned_record_coverage(blueprint, street_id, center, width, depth, foundation_height, verify_root_chain, allowed_transition_owner_ids, handoff_seam_z, handoff_source_owner_id, handoff_source_semantic, handoff_transition_owner_id, handoff_transition_semantic, _route_control)
	var samples: Array[Dictionary] = []
	var violations: Array[String] = []
	var expected_top_y := foundation_height + street_elevation + 0.20
	for x_index in range(3):
		if _route_control != null and not _route_control.poll("route_sample_row"): return _cancelled_route_diagnostic()
		for z_index in range(3):
			if _route_control != null and not _route_control.poll("route_sample"): return _cancelled_route_diagnostic()
			var x_fraction := -0.42 + float(x_index) * 0.42
			var z_fraction := -0.42 + float(z_index) * 0.42
			var surface_point := Vector3(center.x + width * x_fraction, expected_top_y, center.z + depth * z_fraction)
			var owner := raised_route_surface_owner_at(blueprint, street_id, surface_point, allowed_transition_owner_ids, _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var owner_id := String(owner.get("partId", ""))
			var owner_semantic := String(owner.get("semantic", ""))
			var is_roadbed := owner_semantic == "castle_route_terrace_walkway" or owner_semantic == "castle_route_junction"
			var owner_part = blueprint.find_part(owner_id)
			var declared_support_ids: Array = owner_part.recipe.get("physicalRequiredSupportPartIds", []) as Array if owner_part != null else []
			var foundation_support := courtyard_foundation_owner_at(blueprint, Vector3(surface_point.x, foundation_height, surface_point.z), declared_support_ids, _route_control) if is_roadbed else {}
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var root_support := foundation_support if is_roadbed else transition_root_support_owner_at(blueprint, owner, surface_point, _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var sample_id := "%s_%d_%d" % [street_id, x_index, z_index]
			var boundary_owner_ids := route_surface_boundary_owner_ids(blueprint, street_id, surface_point, _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var sample := {
				"id": sample_id,
				"position": surface_point,
				"ownerId": owner_id,
				"ownerSemantic": owner_semantic,
				"ownerCollisionEnabled": bool(owner.get("collisionEnabled", false)),
				"ownerTopY": float(owner.get("topY", INF)),
				"seamHeight": float(owner.get("topY", INF)) - expected_top_y,
				"foundationSupportId": String(foundation_support.get("partId", "")),
				"foundationSupportCollisionEnabled": bool(foundation_support.get("collisionEnabled", false)),
				"rootSupportId": String(root_support.get("partId", "")),
				"rootSupportCollisionEnabled": bool(root_support.get("collisionEnabled", false)),
				"rootSupportRooted": bool(root_support.get("rooted", false)) if verify_root_chain else not String(root_support.get("partId", "")).is_empty(),
				"transitionSurface": bool(owner.get("transitionSurface", false)),
				"boundaryContact": boundary_owner_ids.size() > 1,
				"boundaryOwnerIds": boundary_owner_ids
			}
			var seam_valid := absf(float(sample.get("seamHeight", INF))) <= MAX_RAISED_ROUTE_SURFACE_SEAM
			sample["seamLimit"] = MAX_RAISED_ROUTE_SURFACE_SEAM
			sample["seamValid"] = seam_valid
			var passed := not owner_id.is_empty() and bool(sample.get("ownerCollisionEnabled", false)) and not String(sample.get("rootSupportId", "")).is_empty() and bool(sample.get("rootSupportCollisionEnabled", false)) and bool(sample.get("rootSupportRooted", false)) and seam_valid
			sample["passed"] = passed
			if not passed:
				violations.append("%s lacks a collision-backed route owner with a rooted support and traversable seam" % sample_id)
			samples.append(sample)
	var junction_seams := raised_route_junction_seam_pairs(blueprint, street_id, foundation_height, expected_top_y, verify_root_chain, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	if not bool(junction_seams.get("passed", true)):
		violations.append_array(junction_seams.get("violations", []) as Array)
	var handoff_seam := raised_route_handoff_seam_coverage(blueprint, street_id, center.x, foundation_height, expected_top_y, handoff_seam_z, verify_root_chain, allowed_transition_owner_ids, handoff_source_owner_id, handoff_source_semantic, handoff_transition_owner_id, handoff_transition_semantic, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	if not bool(handoff_seam.get("passed", true)):
		violations.append("%s lacks a collision-continuous declared roadbed-to-transition seam" % street_id)
	return {
		"streetId": street_id,
		"handoffSeam": handoff_seam,
		"center": center,
		"size": Vector3(width, 0.0, depth),
		"expectedTopY": expected_top_y,
		"samples": samples,
		"junctionSeams": junction_seams,
		"passed": violations.is_empty(),
		"violations": violations
	}


static func raised_route_transition_owned_record_coverage(blueprint, street_id: String, center: Vector3, width: float, depth: float, foundation_height: float, verify_root_chain: bool, allowed_transition_owner_ids: Array, handoff_seam_z: float, handoff_source_owner_id: String, handoff_source_semantic: String, handoff_transition_owner_id: String, handoff_transition_semantic: String, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	var samples: Array[Dictionary] = []
	var violations: Array[String] = []
	var exclusivity := transition_route_collision_exclusivity(blueprint, street_id, allowed_transition_owner_ids, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	violations.append_array(exclusivity.get("violations", []) as Array)
	var transition_bounds := declared_transition_bounds(blueprint, allowed_transition_owner_ids, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	if transition_bounds.is_empty():
		return {"streetId": street_id, "coverageMode": "transition_owned", "handoffSeam": {"declared": false, "passed": true}, "center": center, "size": Vector3(width, 0.0, depth), "samples": samples, "passed": false, "violations": ["%s declares no collision-backed transition geometry" % street_id]}
	var minimum_x := float(transition_bounds.get("minX", center.x - width * 0.5))
	var maximum_x := float(transition_bounds.get("maxX", center.x + width * 0.5))
	var minimum_z := float(transition_bounds.get("minZ", center.z - depth * 0.5))
	var maximum_z := float(transition_bounds.get("maxZ", center.z + depth * 0.5))
	for x_index in range(3):
		if _route_control != null and not _route_control.poll("route_transition_sample_row"): return _cancelled_route_diagnostic()
		for z_index in range(3):
			if _route_control != null and not _route_control.poll("route_transition_sample"): return _cancelled_route_diagnostic()
			var x_fraction := -0.42 + float(x_index) * 0.42
			var z_fraction := -0.42 + float(z_index) * 0.42
			var surface_point := Vector3(lerpf(minimum_x, maximum_x, 0.5 + x_fraction * 0.5), foundation_height, lerpf(minimum_z, maximum_z, 0.5 + z_fraction * 0.5))
			var owner := raised_route_surface_owner_at(blueprint, street_id, surface_point, allowed_transition_owner_ids, _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var owner_id := String(owner.get("partId", ""))
			var owner_part = blueprint.find_part(owner_id)
			var root_support := transition_root_support_owner_at(blueprint, owner, surface_point, _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var root_id := String(root_support.get("partId", ""))
			var root_rooted := bool(root_support.get("rooted", false)) if verify_root_chain else not root_id.is_empty()
			var sample_id := "%s_%d_%d" % [street_id, x_index, z_index]
			var sample := {
				"id": sample_id,
				"position": surface_point,
				"ownerId": owner_id,
				"ownerSemantic": String(owner.get("semantic", "")),
				"ownerCollisionEnabled": bool(owner.get("collisionEnabled", false)),
				"ownerTopY": float(owner.get("topY", INF)),
				"rootSupportId": root_id,
				"rootSupportCollisionEnabled": bool(root_support.get("collisionEnabled", false)),
				"rootSupportRooted": root_rooted,
				"declaredTransitionOwner": owner_part != null and allowed_transition_owner_ids.has(owner_id)
			}
			var passed := bool(sample.get("declaredTransitionOwner", false)) and bool(sample.get("ownerCollisionEnabled", false)) and not root_id.is_empty() and bool(sample.get("rootSupportCollisionEnabled", false)) and root_rooted
			sample["passed"] = passed
			if not passed:
				violations.append("%s lacks a declared collision-backed transition surface with a rooted support" % sample_id)
			samples.append(sample)
	var handoff_seam := raised_route_handoff_seam_coverage(blueprint, street_id, center.x, foundation_height, foundation_height, handoff_seam_z, verify_root_chain, allowed_transition_owner_ids, handoff_source_owner_id, handoff_source_semantic, handoff_transition_owner_id, handoff_transition_semantic, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	if not bool(handoff_seam.get("passed", true)):
		violations.append("%s lacks a collision-continuous declared transition-to-forecourt seam" % street_id)
	return {
		"streetId": street_id,
		"coverageMode": "transition_owned",
		"collisionExclusivity": exclusivity,
		"handoffSeam": handoff_seam,
		"center": center,
		"size": Vector3(width, 0.0, depth),
		"samples": samples,
		"passed": violations.is_empty(),
		"violations": violations
	}


static func transition_route_collision_exclusivity(blueprint, street_id: String, allowed_transition_owner_ids: Array, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	var transition_owners: Array = []
	for owner_id_value in allowed_transition_owner_ids:
		if _route_control != null and not _route_control.poll("route_transition_owner"): return _cancelled_route_diagnostic()
		var owner = blueprint.find_part(String(owner_id_value))
		if owner != null and bool(owner.collision_enabled):
			transition_owners.append(owner)
	var violations: Array[String] = []
	var overlaps: Array[Dictionary] = []
	for part in blueprint.parts:
		if _route_control != null and not _route_control.poll("route_exclusivity_part"): return _cancelled_route_diagnostic()
		if part == null or not bool(part.collision_enabled):
			continue
		var route_street_id := String(part.recipe.get("routeStreetId", ""))
		if route_street_id.is_empty():
			continue
		if route_street_id == street_id:
			violations.append("%s publishes a forbidden collision roadbed %s" % [street_id, String(part.id)])
		for transition_owner in transition_owners:
			if _route_control != null and not _route_control.poll("route_exclusivity_pair"): return _cancelled_route_diagnostic()
			if positive_collision_volume_overlap(part, transition_owner):
				overlaps.append({"roadbedId": String(part.id), "transitionOwnerId": String(transition_owner.id), "routeStreetId": route_street_id})
	if not overlaps.is_empty():
		violations.append("%s has collision roadbed overlap with its declared transition geometry" % street_id)
	return {"passed": violations.is_empty(), "overlaps": overlaps, "violations": violations}


static func raised_route_collision_partition(blueprint, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	var route_parts: Array = []
	for part in blueprint.parts:
		if _route_control != null and not _route_control.poll("route_partition_part"): return _cancelled_route_diagnostic()
		if part == null or not bool(part.collision_enabled):
			continue
		var semantic := String(part.semantic)
		if semantic != "castle_route_terrace_walkway" and semantic != "castle_route_junction":
			continue
		route_parts.append(part)
	var overlaps: Array[Dictionary] = []
	for first_index in range(route_parts.size()):
		if _route_control != null and not _route_control.poll("route_partition_owner"): return _cancelled_route_diagnostic()
		var first = route_parts[first_index]
		for second_index in range(first_index + 1, route_parts.size()):
			if _route_control != null and not _route_control.poll("route_partition_pair"): return _cancelled_route_diagnostic()
			var second = route_parts[second_index]
			if positive_collision_volume_overlap(first, second):
				overlaps.append({"firstPartId": String(first.id), "firstSemantic": String(first.semantic), "secondPartId": String(second.id), "secondSemantic": String(second.semantic)})
	var violations: Array[String] = []
	for overlap in overlaps:
		if _route_control != null and not _route_control.poll("route_partition_violation"): return _cancelled_route_diagnostic()
		violations.append("Raised route collision partition overlaps %s and %s" % [String(overlap.get("firstPartId", "")), String(overlap.get("secondPartId", ""))])
	return {"passed": overlaps.is_empty(), "overlaps": overlaps, "violations": violations}


static func positive_collision_volume_overlap(first, second) -> bool:
	var first_bounds := horizontal_part_bounds(first)
	var second_bounds := horizontal_part_bounds(second)
	if first_bounds.is_empty() or second_bounds.is_empty():
		return false
	var overlap_x := minf(float(first_bounds.get("maxX", -INF)), float(second_bounds.get("maxX", -INF))) - maxf(float(first_bounds.get("minX", INF)), float(second_bounds.get("minX", INF)))
	var overlap_z := minf(float(first_bounds.get("maxZ", -INF)), float(second_bounds.get("maxZ", -INF))) - maxf(float(first_bounds.get("minZ", INF)), float(second_bounds.get("minZ", INF)))
	var first_bottom := part_bottom_y_at(first, first.position.x, first.position.z)
	var first_top := part_top_y_at(first, first.position.x, first.position.z)
	var second_bottom := part_bottom_y_at(second, second.position.x, second.position.z)
	var second_top := part_top_y_at(second, second.position.x, second.position.z)
	var overlap_y := minf(first_top, second_top) - maxf(first_bottom, second_bottom)
	return overlap_x > 0.015 and overlap_y > 0.015 and overlap_z > 0.015


static func declared_transition_bounds(blueprint, allowed_transition_owner_ids: Array, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	var minimum_x := INF
	var maximum_x := -INF
	var minimum_z := INF
	var maximum_z := -INF
	for owner_id_value in allowed_transition_owner_ids:
		if _route_control != null and not _route_control.poll("route_transition_bounds"): return _cancelled_route_diagnostic()
		var part = blueprint.find_part(String(owner_id_value))
		if part == null or not bool(part.collision_enabled):
			continue
		var bounds := horizontal_part_bounds(part)
		if bounds.is_empty():
			continue
		minimum_x = minf(minimum_x, float(bounds.get("minX", INF)))
		maximum_x = maxf(maximum_x, float(bounds.get("maxX", -INF)))
		minimum_z = minf(minimum_z, float(bounds.get("minZ", INF)))
		maximum_z = maxf(maximum_z, float(bounds.get("maxZ", -INF)))
	return {} if is_inf(minimum_x) else {"minX": minimum_x, "maxX": maximum_x, "minZ": minimum_z, "maxZ": maximum_z}


static func raised_route_handoff_seam_coverage(blueprint, street_id: String, center_x: float, foundation_height: float, expected_top_y: float, seam_z: float, verify_root_chain: bool, allowed_transition_owner_ids: Array, source_owner_id: String, source_semantic: String, transition_owner_id: String, transition_semantic: String, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	if is_inf(seam_z):
		return {"declared": false, "passed": true}
	var expected_transition_semantic := transition_semantic if not transition_semantic.is_empty() else "castle_keep_palace_entry_forecourt"
	var handoff_owner_ids: Array = allowed_transition_owner_ids.duplicate()
	if not transition_owner_id.is_empty() and not handoff_owner_ids.has(transition_owner_id):
		handoff_owner_ids.append(transition_owner_id)
	var center_roadbed := raised_route_handoff_side_coverage(blueprint, street_id, Vector3(center_x, expected_top_y, seam_z - 0.020), foundation_height, verify_root_chain, handoff_owner_ids, source_semantic, source_owner_id, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	var center_transition := raised_route_handoff_side_coverage(blueprint, street_id, Vector3(center_x, expected_top_y, seam_z + 0.020), foundation_height, verify_root_chain, handoff_owner_ids, expected_transition_semantic, transition_owner_id, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	var roadbed_part = blueprint.find_part(String(center_roadbed.get("ownerId", "")))
	var transition_part = blueprint.find_part(String(center_transition.get("ownerId", "")))
	var roadbed_bounds := horizontal_part_bounds(roadbed_part)
	var transition_bounds := horizontal_part_bounds(transition_part)
	var contact_gap := maxf(0.0, float(transition_bounds.get("minZ", INF)) - float(roadbed_bounds.get("maxZ", -INF)))
	var shared_min_x := maxf(float(roadbed_bounds.get("minX", INF)), float(transition_bounds.get("minX", INF)))
	var shared_max_x := minf(float(roadbed_bounds.get("maxX", -INF)), float(transition_bounds.get("maxX", -INF)))
	var shared_width := maxf(0.0, shared_max_x - shared_min_x)
	var lane_offset := maxf(0.0, shared_width * 0.5 - RAISED_ROUTE_HANDOFF_AGENT_MARGIN)
	var lanes: Array[Dictionary] = []
	for lane_offset_multiplier in [-1.0, 0.0, 1.0]:
		if _route_control != null and not _route_control.poll("route_handoff_lane"): return _cancelled_route_diagnostic()
		var lane_x: float = center_x + lane_offset * lane_offset_multiplier
		var roadbed := raised_route_handoff_side_coverage(blueprint, street_id, Vector3(lane_x, expected_top_y, seam_z - 0.020), foundation_height, verify_root_chain, handoff_owner_ids, source_semantic, source_owner_id, _route_control)
		if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
		var transition := raised_route_handoff_side_coverage(blueprint, street_id, Vector3(lane_x, expected_top_y, seam_z + 0.020), foundation_height, verify_root_chain, handoff_owner_ids, expected_transition_semantic, transition_owner_id, _route_control)
		if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
		var lane_height_delta := absf(float(roadbed.get("topY", INF)) - float(transition.get("topY", INF)))
		lanes.append({"offset": lane_offset * lane_offset_multiplier, "roadbed": roadbed, "transition": transition, "heightDelta": lane_height_delta, "passed": bool(roadbed.get("passed", false)) and bool(transition.get("passed", false)) and lane_height_delta <= MAX_RAISED_ROUTE_HANDOFF_HEIGHT_DELTA})
	var contact_passed := contact_gap <= MAX_RAISED_ROUTE_HANDOFF_GAP
	var width_passed := shared_width >= MIN_RAISED_ROUTE_HANDOFF_WIDTH
	var lanes_passed := lanes.size() == 3 and lanes.all(func(lane: Dictionary) -> bool: return bool(lane.get("passed", false)))
	var passed := contact_passed and width_passed and lanes_passed
	return {"declared": true, "passed": passed, "seamZ": seam_z, "contactGap": contact_gap, "contactGapLimit": MAX_RAISED_ROUTE_HANDOFF_GAP, "sharedWidth": shared_width, "requiredWidth": MIN_RAISED_ROUTE_HANDOFF_WIDTH, "laneOffset": lane_offset, "heightLimit": MAX_RAISED_ROUTE_HANDOFF_HEIGHT_DELTA, "roadbed": center_roadbed, "transition": center_transition, "lanes": lanes}


static func horizontal_part_bounds(part) -> Dictionary:
	if part == null:
		return {}
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for local_x in [-part.size.x * 0.5, part.size.x * 0.5]:
		for local_z in [-part.size.z * 0.5, part.size.z * 0.5]:
			var corner := transform * Vector3(local_x, 0.0, local_z)
			min_x = minf(min_x, corner.x)
			max_x = maxf(max_x, corner.x)
			min_z = minf(min_z, corner.z)
			max_z = maxf(max_z, corner.z)
	return {"minX": min_x, "maxX": max_x, "minZ": min_z, "maxZ": max_z}


static func raised_route_handoff_side_coverage(blueprint, street_id: String, surface_point: Vector3, foundation_height: float, verify_root_chain: bool, allowed_transition_owner_ids: Array, expected_semantic: String, expected_owner_id: String, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	var owner := raised_route_surface_owner_at(blueprint, street_id, surface_point, allowed_transition_owner_ids, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	var owner_id := String(owner.get("partId", ""))
	var owner_semantic := String(owner.get("semantic", ""))
	var is_roadbed := owner_semantic == "castle_route_terrace_walkway" or owner_semantic == "castle_route_junction"
	var owner_part = blueprint.find_part(owner_id)
	var declared_support_ids: Array = owner_part.recipe.get("physicalRequiredSupportPartIds", []) as Array if owner_part != null else []
	var foundation_support := courtyard_foundation_owner_at(blueprint, Vector3(surface_point.x, foundation_height, surface_point.z), declared_support_ids, _route_control) if is_roadbed else {}
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	var root_support := foundation_support if is_roadbed else transition_root_support_owner_at(blueprint, owner, surface_point, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	var root_id := String(root_support.get("partId", ""))
	var root_rooted := bool(root_support.get("rooted", false)) if verify_root_chain else not root_id.is_empty()
	var expected_owner_matches := expected_owner_id.is_empty() or owner_id == expected_owner_id
	var expected_surface_matches := owner_semantic == expected_semantic or (owner_semantic == "castle_route_junction" and expected_semantic == "castle_route_terrace_walkway")
	var passed := expected_surface_matches and expected_owner_matches and bool(owner.get("collisionEnabled", false)) and not root_id.is_empty() and bool(root_support.get("collisionEnabled", false)) and root_rooted
	return {"position": surface_point, "ownerId": owner_id, "ownerSemantic": owner_semantic, "topY": float(owner.get("topY", INF)), "rootSupportId": root_id, "ownerCollisionEnabled": bool(owner.get("collisionEnabled", false)), "rootSupportCollisionEnabled": bool(root_support.get("collisionEnabled", false)), "rootSupportRooted": root_rooted, "expectedSemantic": expected_semantic, "expectedOwnerId": expected_owner_id, "passed": passed}


static func raised_route_surface_owner_at(blueprint, street_id: String, surface_point: Vector3, allowed_transition_owner_ids: Array = [], _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	var transition_semantics := {
		"castle_processional_step": true,
		"castle_keep_palace_entry_forecourt": true
	}
	var best_owner := {}
	var best_top_y := -INF
	for part in blueprint.parts:
		if _route_control != null and not _route_control.poll("route_surface_part"): return _cancelled_route_diagnostic()
		if part == null or not bool(part.collision_enabled):
			continue
		var semantic := String(part.semantic)
		var incident_street_ids: Array = part.recipe.get("routeIncidentStreetIds", []) as Array
		var is_roadbed := semantic == "castle_route_terrace_walkway" and String(part.recipe.get("routeStreetId", "")) == street_id
		var is_junction := semantic == "castle_route_junction" and incident_street_ids.has(street_id)
		var is_transition := transition_semantics.has(semantic) and allowed_transition_owner_ids.has(String(part.id))
		if not is_roadbed and not is_junction and not is_transition:
			continue
		var top_y := route_surface_top_y_at(part, surface_point.x, surface_point.z) if is_roadbed or is_junction else part_top_y_at(part, surface_point.x, surface_point.z)
		if is_inf(top_y):
			continue
		if top_y >= best_top_y:
			best_top_y = top_y
			best_owner = {"partId": String(part.id), "semantic": semantic, "collisionEnabled": true, "topY": top_y, "transitionSurface": is_transition, "junctionSurface": is_junction}
	return best_owner


static func route_surface_boundary_owner_ids(blueprint, street_id: String, surface_point: Vector3, _route_control: _RouteDiagnosticContinuation = null) -> Array[String]:
	var owner_ids: Array[String] = []
	for part in blueprint.parts:
		if _route_control != null and not _route_control.poll("route_boundary_part"): return []
		if part == null or not bool(part.collision_enabled):
			continue
		var semantic := String(part.semantic)
		var is_roadbed := semantic == "castle_route_terrace_walkway" and String(part.recipe.get("routeStreetId", "")) == street_id
		var is_junction := semantic == "castle_route_junction" and (part.recipe.get("routeIncidentStreetIds", []) as Array).has(street_id)
		if not is_roadbed and not is_junction:
			continue
		var top_y := route_surface_top_y_at(part, surface_point.x, surface_point.z)
		if is_inf(top_y) or absf(top_y - surface_point.y) > 0.01:
			continue
		var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
		var local := transform.affine_inverse() * Vector3(surface_point.x, top_y, surface_point.z)
		if absf(absf(local.x) - part.size.x * 0.5) <= 0.002 or absf(absf(local.z) - part.size.z * 0.5) <= 0.002:
			owner_ids.append(String(part.id))
	return owner_ids


static func raised_route_junction_seam_pairs(blueprint, street_id: String, foundation_height: float, expected_top_y: float, verify_root_chain: bool, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	var pairs: Array[Dictionary] = []
	var violations: Array[String] = []
	for junction in blueprint.parts:
		if _route_control != null and not _route_control.poll("route_junction_part"): return _cancelled_route_diagnostic()
		if junction == null or String(junction.semantic) != "castle_route_junction" or not (junction.recipe.get("routeIncidentStreetIds", []) as Array).has(street_id):
			continue
		var junction_bounds := horizontal_part_bounds(junction)
		for roadbed in blueprint.parts:
			if _route_control != null and not _route_control.poll("route_junction_pair"): return _cancelled_route_diagnostic()
			if roadbed == null or String(roadbed.semantic) != "castle_route_terrace_walkway" or String(roadbed.recipe.get("routeStreetId", "")) != street_id:
				continue
			var roadbed_bounds := horizontal_part_bounds(roadbed)
			var seam := route_junction_shared_boundary(junction_bounds, roadbed_bounds)
			if seam.is_empty():
				continue
			var direction: Vector3 = seam.get("direction", Vector3.ZERO) as Vector3
			var contact: Vector3 = seam.get("contact", Vector3.ZERO) as Vector3
			var inset := 0.055
			var roadbed_position := contact - direction * inset
			var junction_position := contact + direction * inset
			var roadbed_owner := raised_route_surface_owner_at(blueprint, street_id, roadbed_position, [], _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var junction_owner := raised_route_surface_owner_at(blueprint, street_id, junction_position, [], _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var roadbed_is_surface := String(roadbed_owner.get("semantic", "")) == "castle_route_terrace_walkway"
			var junction_is_surface := String(junction_owner.get("semantic", "")) == "castle_route_junction"
			var roadbed_support := courtyard_foundation_owner_at(blueprint, Vector3(roadbed_position.x, foundation_height, roadbed_position.z), roadbed.recipe.get("physicalRequiredSupportPartIds", []) as Array, _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var junction_support := courtyard_foundation_owner_at(blueprint, Vector3(junction_position.x, foundation_height, junction_position.z), junction.recipe.get("physicalRequiredSupportPartIds", []) as Array, _route_control)
			if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
			var gap := float(seam.get("gap", INF))
			var roadbed_top_y := float(roadbed_owner.get("topY", expected_top_y))
			var junction_top_y := float(junction_owner.get("topY", expected_top_y))
			var height_delta := absf(roadbed_top_y - junction_top_y)
			var roadbed_rooted := bool(roadbed_support.get("rooted", false)) if verify_root_chain else not roadbed_support.is_empty()
			var junction_rooted := bool(junction_support.get("rooted", false)) if verify_root_chain else not junction_support.is_empty()
			var roadbed_passed := roadbed_is_surface and String(roadbed_owner.get("partId", "")) == String(roadbed.id) and bool(roadbed_owner.get("collisionEnabled", false)) and bool(roadbed_support.get("collisionEnabled", false)) and roadbed_rooted
			var junction_passed := junction_is_surface and String(junction_owner.get("partId", "")) == String(junction.id) and bool(junction_owner.get("collisionEnabled", false)) and bool(junction_support.get("collisionEnabled", false)) and junction_rooted
			var passed := gap <= 0.01 and height_delta <= 0.01 and roadbed_passed and junction_passed
			var pair := {"id": "%s__%s" % [String(roadbed.id), String(junction.id)], "junctionId": String(junction.id), "streetId": street_id, "direction": direction, "contact": contact, "inset": inset, "roadbed": {"ownerId": String(roadbed.id), "position": roadbed_position, "topY": roadbed_top_y, "rootSupportId": String(roadbed_support.get("partId", "")), "ownerCollisionEnabled": bool(roadbed_owner.get("collisionEnabled", false)), "rootSupportCollisionEnabled": bool(roadbed_support.get("collisionEnabled", false)), "rootSupportRooted": roadbed_rooted, "passed": roadbed_passed}, "junction": {"ownerId": String(junction.id), "position": junction_position, "topY": junction_top_y, "rootSupportId": String(junction_support.get("partId", "")), "ownerCollisionEnabled": bool(junction_owner.get("collisionEnabled", false)), "rootSupportCollisionEnabled": bool(junction_support.get("collisionEnabled", false)), "rootSupportRooted": junction_rooted, "passed": junction_passed}, "gap": gap, "gapLimit": 0.01, "heightDelta": height_delta, "heightLimit": 0.01, "passed": passed}
			pairs.append(pair)
			if not passed:
				violations.append("%s does not declare an exact rooted roadbed-to-junction seam pair" % String(pair.get("id", "")))
	return {"passed": violations.is_empty(), "pairs": pairs, "violations": violations}


static func route_junction_shared_boundary(junction_bounds: Dictionary, roadbed_bounds: Dictionary) -> Dictionary:
	var min_x := maxf(float(junction_bounds.get("minX", INF)), float(roadbed_bounds.get("minX", INF)))
	var max_x := minf(float(junction_bounds.get("maxX", -INF)), float(roadbed_bounds.get("maxX", -INF)))
	var min_z := maxf(float(junction_bounds.get("minZ", INF)), float(roadbed_bounds.get("minZ", INF)))
	var max_z := minf(float(junction_bounds.get("maxZ", -INF)), float(roadbed_bounds.get("maxZ", -INF)))
	if max_x - min_x > 0.25:
		if absf(float(roadbed_bounds.get("maxZ", 0.0)) - float(junction_bounds.get("minZ", 0.0))) <= 0.01:
			return {"contact": Vector3((min_x + max_x) * 0.5, 0.0, float(junction_bounds.get("minZ", 0.0))), "direction": Vector3.BACK, "gap": maxf(0.0, float(junction_bounds.get("minZ", 0.0)) - float(roadbed_bounds.get("maxZ", 0.0)))}
		if absf(float(roadbed_bounds.get("minZ", 0.0)) - float(junction_bounds.get("maxZ", 0.0))) <= 0.01:
			return {"contact": Vector3((min_x + max_x) * 0.5, 0.0, float(junction_bounds.get("maxZ", 0.0))), "direction": Vector3.FORWARD, "gap": maxf(0.0, float(roadbed_bounds.get("minZ", 0.0)) - float(junction_bounds.get("maxZ", 0.0)))}
	if max_z - min_z > 0.25:
		if absf(float(roadbed_bounds.get("maxX", 0.0)) - float(junction_bounds.get("minX", 0.0))) <= 0.01:
			return {"contact": Vector3(float(junction_bounds.get("minX", 0.0)), 0.0, (min_z + max_z) * 0.5), "direction": Vector3.RIGHT, "gap": maxf(0.0, float(junction_bounds.get("minX", 0.0)) - float(roadbed_bounds.get("maxX", 0.0)))}
		if absf(float(roadbed_bounds.get("minX", 0.0)) - float(junction_bounds.get("maxX", 0.0))) <= 0.01:
			return {"contact": Vector3(float(junction_bounds.get("maxX", 0.0)), 0.0, (min_z + max_z) * 0.5), "direction": Vector3.LEFT, "gap": maxf(0.0, float(roadbed_bounds.get("minX", 0.0)) - float(junction_bounds.get("maxX", 0.0)))}
	return {}


static func courtyard_foundation_owner_at(blueprint, surface_point: Vector3, declared_support_ids: Array = [], _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	for part in blueprint.parts:
		if _route_control != null and not _route_control.poll("route_foundation_part"): return _cancelled_route_diagnostic()
		if part == null or String(part.semantic) != "castle_courtyard_foundation" or not bool(part.collision_enabled):
			continue
		if not declared_support_ids.is_empty() and not declared_support_ids.has(String(part.id)):
			continue
		var top_y := part_top_y_at(part, surface_point.x, surface_point.z)
		if is_inf(top_y) or absf(top_y - surface_point.y) > 0.04:
			continue
		return {"partId": String(part.id), "collisionEnabled": true, "topY": top_y, "rooted": bool(part.recipe.get("physicalRoot", false))}
	return {}


static func transition_root_support_owner_at(blueprint, owner: Dictionary, surface_point: Vector3, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	var owner_id := String(owner.get("partId", ""))
	var owner_top_y := float(owner.get("topY", -INF))
	var owner_part = blueprint.find_part(owner_id)
	if owner_part == null:
		return {}
	var owner_bottom_y := part_bottom_y_at(owner_part, surface_point.x, surface_point.z)
	var declared_root_ids: Array = owner_part.recipe.get("routeTransitionRootPartIds", []) as Array
	if declared_root_ids.is_empty():
		return {}
	var best_support := {}
	var best_top_y := -INF
	for root_id_value in declared_root_ids:
		if _route_control != null and not _route_control.poll("route_root_support"): return _cancelled_route_diagnostic()
		var part = blueprint.find_part(String(root_id_value))
		if part == null or not bool(part.collision_enabled):
			continue
		if String(part.id) == owner_id and bool(part.recipe.get("physicalRoot", false)):
			return {"partId": owner_id, "collisionEnabled": true, "topY": owner_top_y, "rooted": true}
		var top_y := part_top_y_at(part, surface_point.x, surface_point.z)
		if is_inf(top_y) or is_inf(owner_bottom_y) or absf(top_y - owner_bottom_y) > 0.05 or top_y > owner_top_y + 0.05 or top_y < best_top_y:
			continue
		best_top_y = top_y
		best_support = {"partId": String(part.id), "collisionEnabled": true, "topY": top_y, "rooted": bool(part.recipe.get("physicalRoot", false))}
	return best_support


## Per-invocation worker cancellation; never shared with another diagnostic or
## stored on the blueprint. A rejected caller is never invoked again.
class _RouteDiagnosticContinuation extends RefCounted:
	var callback: Callable
	var cancelled := false

	func _init(continuation: Callable) -> void:
		callback = continuation

	func poll(stage: String) -> bool:
		if cancelled: return false
		if callback.call(stage) != true:
			cancelled = true
			return false
		return true


static func _cancelled_route_diagnostic() -> Dictionary:
	return {"passed": false, "cancelled": true}


## Geometry diagnostics only. Cancellation leaves derived physical facts on the
## exclusively owned blueprint; discard it rather than publishing partial proof.
static func validate_raised_route_coverage(blueprint, continuation: Callable = Callable()) -> Dictionary:
	var control: _RouteDiagnosticContinuation = _RouteDiagnosticContinuation.new(continuation) if continuation.is_valid() else null
	if control != null and not control.poll("route_validation_started"): return _cancelled_route_diagnostic()
	var result := _validate_raised_route_coverage(blueprint, control)
	if control != null:
		if control.cancelled or bool(result.get("cancelled", false)): return _cancelled_route_diagnostic()
		if not control.poll("route_validation_completed"): return _cancelled_route_diagnostic()
	return result


static func _validate_raised_route_coverage(blueprint, _route_control: _RouteDiagnosticContinuation = null) -> Dictionary:
	if blueprint == null or not blueprint.recipe is Dictionary:
		return {"passed": true, "records": [], "violations": []}
	if String((blueprint.recipe as Dictionary).get("publicationScope", "")) == "residence_district":
		var scope_violations: Array[String] = []
		for part in blueprint.parts:
			if _route_control != null and not _route_control.poll("route_residence_part"): return _cancelled_route_diagnostic()
			if part != null and String(part.semantic) in ["castle_route_terrace_walkway", "castle_route_junction"]:
				scope_violations.append("Residence district slice contains core-owned route part %s" % String(part.id))
		return {"passed": scope_violations.is_empty(), "applicability": "not_applicable", "records": [], "violations": scope_violations}
	var grammar: Dictionary = (blueprint.recipe as Dictionary).get("castleGrammar", {}) as Dictionary
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	if String(grid.get("mode", "")) != "district_grid":
		return {"passed": true, "records": [], "violations": []}
	if _route_control == null:
		# Preserve legacy virtual dispatch and the exact applicability branches.
		blueprint.resolve_physical_contracts()
	else:
		if not blueprint.resolve_physical_contracts_cancellable(_route_control.poll):
			return _cancelled_route_diagnostic()
	var foundation_height := float((blueprint.recipe as Dictionary).get("foundationHeight", 0.62))
	var records: Array[Dictionary] = []
	var violations: Array[String] = []
	var collision_partition := raised_route_collision_partition(blueprint, _route_control)
	if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
	violations.append_array(collision_partition.get("violations", []) as Array)
	for record_value in grid.get("streetRecords", []) as Array:
		if _route_control != null and not _route_control.poll("route_street"): return _cancelled_route_diagnostic()
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value as Dictionary
		var width := float(record.get("width", 0.0))
		var depth := float(record.get("depth", 0.0))
		if width <= 0.20 or depth <= 0.20:
			continue
		var elevation := float(record.get("elevation", citadel_terrace_elevation_at_z(grid, float(record.get("z", 0.0)))))
		var coverage := raised_route_record_coverage(blueprint, String(record.get("id", "street")), Vector3(float(record.get("x", 0.0)), 0.0, float(record.get("z", 0.0))), width, depth, foundation_height, elevation, true, record.get("allowedTransitionOwnerIds", []) as Array, float(record.get("handoffSeamZ", INF)), String(record.get("handoffTransitionOwnerId", "")), String(record.get("handoffTransitionSemantic", "")), String(record.get("handoffSourceOwnerId", "")), String(record.get("handoffSourceSemantic", "castle_route_terrace_walkway")), bool(record.get("transitionOwned", false)), _route_control)
		if _route_control != null and _route_control.cancelled: return _cancelled_route_diagnostic()
		records.append(coverage)
		if not bool(coverage.get("passed", false)):
			violations.append_array(coverage.get("violations", []) as Array)
	return {"passed": not records.is_empty() and violations.is_empty(), "records": records, "collisionPartition": collision_partition, "violations": violations}


static func part_top_y_at(part, world_x: float, world_z: float) -> float:
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	var normal := transform.basis * Vector3.UP
	if absf(normal.y) <= 0.0001:
		return INF
	var top_origin := transform * Vector3(0.0, part.size.y * 0.5, 0.0)
	var world_y := top_origin.y - (normal.x * (world_x - top_origin.x) + normal.z * (world_z - top_origin.z)) / normal.y
	var local := transform.affine_inverse() * Vector3(world_x, world_y, world_z)
	if absf(local.x) > part.size.x * 0.5 - 0.015 or absf(local.z) > part.size.z * 0.5 - 0.015:
		return INF
	return world_y


static func route_surface_top_y_at(part, world_x: float, world_z: float) -> float:
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	var normal := transform.basis * Vector3.UP
	if absf(normal.y) <= 0.0001:
		return INF
	var top_origin := transform * Vector3(0.0, part.size.y * 0.5, 0.0)
	var world_y := top_origin.y - (normal.x * (world_x - top_origin.x) + normal.z * (world_z - top_origin.z)) / normal.y
	var local := transform.affine_inverse() * Vector3(world_x, world_y, world_z)
	if absf(local.x) > part.size.x * 0.5 + 0.001 or absf(local.z) > part.size.z * 0.5 + 0.001:
		return INF
	return world_y




static func part_bottom_y_at(part, world_x: float, world_z: float) -> float:
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	var normal := transform.basis * Vector3.UP
	if absf(normal.y) <= 0.0001:
		return INF
	var bottom_origin := transform * Vector3(0.0, -part.size.y * 0.5, 0.0)
	var world_y := bottom_origin.y - (normal.x * (world_x - bottom_origin.x) + normal.z * (world_z - bottom_origin.z)) / normal.y
	var local := transform.affine_inverse() * Vector3(world_x, world_y, world_z)
	if absf(local.x) > part.size.x * 0.5 - 0.015 or absf(local.z) > part.size.z * 0.5 - 0.015:
		return INF
	return world_y


static func roadbed_has_courtyard_foundation_support(blueprint, center: Vector3, size: Vector3, foundation_height: float) -> bool:
	for x_fraction in [-0.5, 0.0, 0.5]:
		for z_fraction in [-0.5, 0.0, 0.5]:
			var sample_x: float = center.x + size.x * float(x_fraction)
			var sample_z: float = center.z + size.z * float(z_fraction)
			var covered := false
			for part in blueprint.parts:
				if part == null or String(part.semantic) != "castle_courtyard_foundation" or not bool(part.collision_enabled) or not bool(part.recipe.get("physicalRoot", false)):
					continue
				if absf(part.position.y + part.size.y * 0.5 - foundation_height) > 0.04:
					continue
				if absf(sample_x - part.position.x) <= part.size.x * 0.5 - 0.015 and absf(sample_z - part.position.z) <= part.size.z * 0.5 - 0.015:
					covered = true
					break
			if not covered:
				return false
	return true


static func raised_route_existing_support_bounds(blueprint) -> Array[AABB]:
	var bounds: Array[AABB] = []
	var protected_semantics := {
		"castle_processional_step": true,
		"castle_keep_palace_entry_forecourt": true,
		"castle_route_junction": true
	}
	for part in blueprint.parts:
		if part == null or not bool(part.collision_enabled) or not protected_semantics.has(String(part.semantic)):
			continue
		var part_bounds := AABB(Vector3(part.position.x - part.size.x * 0.5, 0.0, part.position.z - part.size.z * 0.5), Vector3(part.size.x, 0.01, part.size.z))
		bounds.append(part_bounds)
	return bounds


static func route_visual_overlaps_protected_support(center: Vector3, size: Vector3, protected_bounds: Array[AABB]) -> bool:
	var bounds := AABB(Vector3(center.x - size.x * 0.5, 0.0, center.z - size.z * 0.5), Vector3(size.x, 0.01, size.z))
	for protected in protected_bounds:
		if bounds.intersects(protected):
			return true
	return false


static func subtract_roadbed_footprint(segments: Array[AABB], protected_bounds: AABB) -> Array[AABB]:
	var remaining: Array[AABB] = []
	for segment in segments:
		if not segment.intersects(protected_bounds):
			remaining.append(segment)
			continue
		var overlap := segment.intersection(protected_bounds)
		var segment_min_x := segment.position.x
		var segment_max_x := segment.end.x
		var segment_min_z := segment.position.z
		var segment_max_z := segment.end.z
		var overlap_min_x := overlap.position.x
		var overlap_max_x := overlap.end.x
		var overlap_min_z := overlap.position.z
		var overlap_max_z := overlap.end.z
		append_roadbed_segment(remaining, segment_min_x, overlap_min_x, segment_min_z, segment_max_z)
		append_roadbed_segment(remaining, overlap_max_x, segment_max_x, segment_min_z, segment_max_z)
		append_roadbed_segment(remaining, overlap_min_x, overlap_max_x, segment_min_z, overlap_min_z)
		append_roadbed_segment(remaining, overlap_min_x, overlap_max_x, overlap_max_z, segment_max_z)
	return remaining


static func append_roadbed_segment(segments: Array[AABB], minimum_x: float, maximum_x: float, minimum_z: float, maximum_z: float) -> void:
	var width := maximum_x - minimum_x
	var depth := maximum_z - minimum_z
	if width <= 0.20 or depth <= 0.20:
		return
	segments.append(AABB(Vector3(minimum_x, 0.0, minimum_z), Vector3(width, 0.01, depth)))


static func add_citadel_terraces(blueprint, grammar: Dictionary, courtyard_width: float, courtyard_depth: float, foundation_height: float, variation: float, residences: Array[Dictionary] = [], reserved_walkways: Array[Dictionary] = []) -> void:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	if String(grid.get("mode", "")) != "district_grid":
		return
	var row_centers: Array = grid.get("rowCenters", []) as Array
	if row_centers.is_empty():
		return
	var boulevard_half_width := float(grid.get("boulevardHalfWidth", 7.0))
	var route_centers: Array = grid.get("routeCenters", []) as Array
	var street_records: Array = grid.get("streetRecords", []) as Array
	var processional_transitions: Array = grid.get("processionalTransitions", []) as Array
	var terrace_exclusions := courtyard_residence_egress_corridors(residences, foundation_height)
	terrace_exclusions.append_array(courtyard_residence_structural_exclusions(residences))
	terrace_exclusions.append_array(reserved_walkways)
	var front_z := -courtyard_depth * 0.5 + 1.2
	for row_index in range(row_centers.size()):
		var row_z := float(row_centers[row_index])
		var next_z := float(row_centers[row_index + 1]) if row_index + 1 < row_centers.size() else courtyard_depth * 0.5 - 1.2
		var elevation := citadel_terrace_elevation_at_z(grid, row_z)
		var depth := maxf(1.0, next_z - front_z)
		var route_x := float(route_centers[mini(row_index, route_centers.size() - 1)]) if not route_centers.is_empty() else 0.0
		var route_clear_half_width := boulevard_half_width * 1.12
		var terrace_min_x := -courtyard_width * 0.5 + 1.2
		var terrace_max_x := courtyard_width * 0.5 - 1.2
		var access_interval := terrace_access_interval_for_band(street_records, front_z, next_z, route_x, route_clear_half_width)
		var left_edge := maxf(terrace_min_x, float(access_interval.get("minX", route_x - route_clear_half_width)))
		var right_edge := minf(terrace_max_x, float(access_interval.get("maxX", route_x + route_clear_half_width)))
		var terrace_center_z := front_z + depth * 0.5
		var left_width := maxf(0.0, left_edge - terrace_min_x)
		var right_width := maxf(0.0, terrace_max_x - right_edge)
		if left_width > 0.2:
			var left_segments := subtract_courtyard_egress_corridors(Rect2(terrace_min_x, front_z, left_width, depth), terrace_exclusions)
			for segment_index in range(left_segments.size()):
				var segment: Rect2 = left_segments[segment_index] as Rect2
				add_part(blueprint, "castle_terrace_block_%02d_left_%02d" % [row_index, segment_index], "foundation", "stone_foundation", Vector3(segment.get_center().x, foundation_height + elevation * 0.5, segment.get_center().y), Vector3(segment.size.x, maxf(0.12, elevation), segment.size.y), {"variation": variation - 0.025, "semantic": "castle_inhabited_terrace_block", "navigationRole": "structural_mass", "residenceCarved": true})
		if right_width > 0.2:
			var right_segments := subtract_courtyard_egress_corridors(Rect2(right_edge, front_z, right_width, depth), terrace_exclusions)
			for segment_index in range(right_segments.size()):
				var segment: Rect2 = right_segments[segment_index] as Rect2
				add_part(blueprint, "castle_terrace_block_%02d_right_%02d" % [row_index, segment_index], "foundation", "stone_foundation", Vector3(segment.get_center().x, foundation_height + elevation * 0.5, segment.get_center().y), Vector3(segment.size.x, maxf(0.12, elevation), segment.size.y), {"variation": variation - 0.025, "semantic": "castle_inhabited_terrace_block", "navigationRole": "structural_mass", "residenceCarved": true})
		if elevation > 0.1:
			for retaining_side in [-1.0, 1.0]:
				add_citadel_terrace_retaining_wall_segments(blueprint, row_index, retaining_side, route_x + retaining_side * route_clear_half_width, front_z, next_z, foundation_height, elevation, variation, terrace_exclusions)
		front_z = next_z
	# Stair publication follows the route recipe rather than the coarse terrace
	# row lattice. Two elevation changes can legitimately share one row interval;
	# explicit ordered descriptors keep both transitions and their elevations.
	var expected_from_elevation := 0.0
	for transition_index in range(processional_transitions.size()):
		var value: Variant = processional_transitions[transition_index]
		if not value is Dictionary:
			push_error("Citadel processional transition %d is not a descriptor" % transition_index)
			continue
		var transition: Dictionary = value as Dictionary
		var ordinal := int(transition.get("ordinal", -1))
		var prefix := String(transition.get("idPrefix", ""))
		var center_x := float(transition.get("centerX", NAN))
		var center_z := float(transition.get("centerZ", NAN))
		var width := float(transition.get("width", 0.0))
		var from_elevation := float(transition.get("fromElevation", NAN))
		var to_elevation := float(transition.get("toElevation", NAN))
		var start_z := float(transition.get("startZ", NAN))
		var end_z := float(transition.get("endZ", NAN))
		var valid := ordinal == transition_index and not prefix.is_empty() and is_finite(center_x) and is_finite(center_z) and width > 0.20 and is_finite(from_elevation) and is_finite(to_elevation) and to_elevation > from_elevation and is_equal_approx(from_elevation, expected_from_elevation) and is_finite(start_z) and is_finite(end_z) and end_z > start_z
		if not valid:
			push_error("Citadel processional transition %d is malformed or discontinuous: %s" % [transition_index, transition])
			continue
		add_citadel_processional_steps(blueprint, prefix, center_x, center_z, width, from_elevation, to_elevation, foundation_height, variation)
		expected_from_elevation = to_elevation


static func add_citadel_terrace_retaining_wall_segments(blueprint, row_index: int, retaining_side: float, wall_x: float, minimum_z: float, maximum_z: float, foundation_height: float, elevation: float, variation: float, exclusions: Array[Dictionary]) -> void:
	var intervals: Array[Vector2] = [Vector2(minimum_z, maximum_z)]
	for exclusion_value in exclusions:
		if not (exclusion_value is Dictionary):
			continue
		var exclusion: Dictionary = exclusion_value as Dictionary
		var rect: Rect2 = exclusion.get("rect", Rect2()) as Rect2
		if rect.size.x <= 0.0 or rect.size.y <= 0.0 or rect.position.x >= wall_x + 0.18 or rect.end.x <= wall_x - 0.18:
			continue
		var remaining: Array[Vector2] = []
		for interval in intervals:
			var start := interval.x
			var finish := interval.y
			var blocked_start := maxf(start, rect.position.y)
			var blocked_finish := minf(finish, rect.end.y)
			if blocked_finish <= blocked_start:
				remaining.append(interval)
				continue
			if blocked_start - start > 0.12:
				remaining.append(Vector2(start, blocked_start))
			if finish - blocked_finish > 0.12:
				remaining.append(Vector2(blocked_finish, finish))
		intervals = remaining
	for segment_index in range(intervals.size()):
		var interval: Vector2 = intervals[segment_index]
		var segment_depth := interval.y - interval.x
		if segment_depth <= 0.12:
			continue
		add_part(blueprint, "castle_terrace_route_wall_%02d_%d_%02d" % [row_index, int(retaining_side), segment_index], "wall", "stone_foundation", Vector3(wall_x, foundation_height + elevation * 0.5, (interval.x + interval.y) * 0.5), Vector3(0.28, elevation, segment_depth), {"variation": variation - 0.035, "semantic": "castle_terrace_route_retaining_wall", "residenceEgressCarved": true})


static func terrace_access_interval_for_band(street_records: Array, band_start_z: float, band_end_z: float, fallback_center_x: float, fallback_half_width: float) -> Dictionary:
	# Terrace volumes are allowed beside a route, never through it.  The sampled
	# row centre only identifies the dominant bent lane; street records preserve
	# the complete generated graph where a palace approach and a turn share a row.
	var min_x := fallback_center_x - fallback_half_width
	var max_x := fallback_center_x + fallback_half_width
	for street_record_value in street_records:
		if not street_record_value is Dictionary:
			continue
		var street_record: Dictionary = street_record_value as Dictionary
		var street_depth := float(street_record.get("depth", 0.0))
		var street_center_z := float(street_record.get("z", 0.0))
		var street_min_z := street_center_z - street_depth * 0.5
		var street_max_z := street_center_z + street_depth * 0.5
		if street_max_z < band_start_z or street_min_z > band_end_z:
			continue
		var street_center_x := float(street_record.get("x", 0.0))
		var street_half_width := float(street_record.get("width", 0.0)) * 0.5
		min_x = minf(min_x, street_center_x - street_half_width)
		max_x = maxf(max_x, street_center_x + street_half_width)
	return {"minX": min_x, "maxX": max_x}


static func add_citadel_urban_room_dressing(blueprint, grammar: Dictionary, foundation_height: float, variation: float) -> void:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var rooms: Dictionary = grid.get("urbanRooms", {}) as Dictionary
	if rooms.is_empty():
		return
	var gate: Dictionary = rooms.get("gate", {}) as Dictionary
	var gate_center: Vector3 = gate.get("center", Vector3.ZERO) as Vector3
	var gate_width := float(gate.get("width", 16.0))
	var gate_depth := float(gate.get("depth", 8.0))
	for side in [-1.0, 1.0]:
		var edge_x: float = gate_center.x + side * gate_width * 0.42
		for use_index in range(3):
			var use_z := gate_center.z + lerpf(-gate_depth * 0.26, gate_depth * 0.26, float(use_index) / 2.0)
			add_part(blueprint, "castle_gate_frontage_counter_%d_%02d" % [int(side), use_index], "decor", "timber_board", Vector3(edge_x, foundation_height + 0.72, use_z), Vector3(0.58, 0.18, 1.05), {"collision": false, "variation": variation + float(use_index) * 0.01, "semantic": "castle_gate_frontage_use"})
			add_part(blueprint, "castle_gate_frontage_goods_%d_%02d" % [int(side), use_index], "decor", "painted_decor", Vector3(edge_x, foundation_height + 0.98, use_z), Vector3(0.34, 0.34, 0.48), {"collision": false, "variation": variation + float(use_index) * 0.02, "semantic": "castle_gate_frontage_goods"})
	var palace: Dictionary = rooms.get("palace", {}) as Dictionary
	var palace_center: Vector3 = palace.get("center", Vector3.ZERO) as Vector3
	var palace_width := float(palace.get("width", 24.0))
	var palace_depth := float(palace.get("depth", 10.0))
	for side in [-1.0, 1.0]:
		var pocket_x: float = palace_center.x + side * palace_width * 0.38
		var pocket_z: float = palace_center.z - palace_depth * 0.28
		add_part(blueprint, "castle_palace_planting_bed_%d" % int(side), "foundation", "mortar", Vector3(pocket_x, foundation_height + palace_center.y + 0.10, pocket_z), Vector3(palace_width * 0.18, 0.08, palace_depth * 0.34), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_palace_planting_bed", "physicalIntent": "visual_detail"})
		for planting_index in range(4):
			var planting_z := pocket_z + lerpf(-palace_depth * 0.12, palace_depth * 0.12, float(planting_index) / 3.0)
			add_part(blueprint, "castle_palace_planting_%d_%02d" % [int(side), planting_index], "decor", "wool_moss", Vector3(pocket_x, foundation_height + palace_center.y + 0.42, planting_z), Vector3(palace_width * 0.12, 0.50, palace_depth * 0.07), {"collision": false, "variation": variation + side * 0.01 + float(planting_index) * 0.005, "semantic": "castle_palace_planting"})
		add_part(blueprint, "castle_palace_room_banner_%d" % int(side), "sign", "painted_decor", Vector3(pocket_x, foundation_height + palace_center.y + 3.2, palace_center.z + palace_depth * 0.28), Vector3(0.72, 1.8, 0.10), {"collision": false, "variation": variation + side * 0.02, "semantic": "castle_palace_room_banner"})


static func add_citadel_route_necks(blueprint, grammar: Dictionary, residences: Array[Dictionary], foundation_height: float, variation: float) -> void:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var necks: Array = grid.get("routeNecks", []) as Array
	var masonry: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var material := String(masonry.get("fortification", "fired_brick"))
	for neck_value in necks:
		if not neck_value is Dictionary:
			continue
		var neck: Dictionary = neck_value as Dictionary
		var neck_id := String(neck.get("id", "route_neck"))
		var center: Vector3 = neck.get("center", Vector3.ZERO) as Vector3
		var clear_width := float(neck.get("clearWidth", 5.6))
		var clear_height := float(neck.get("clearHeight", 4.2))
		var projection_depth := float(neck.get("projectionDepth", 2.8))
		var runs_along_z := String(neck.get("direction", "z")) == "z"
		var hosts := citadel_route_neck_hosts(residences, center, runs_along_z)
		if hosts.size() != 2:
			continue
		var negative_host: Dictionary = hosts[0] as Dictionary
		var positive_host: Dictionary = hosts[1] as Dictionary
		var negative_center: Vector3 = negative_host.get("center", Vector3.ZERO) as Vector3
		var positive_center: Vector3 = positive_host.get("center", Vector3.ZERO) as Vector3
		var negative_cross_span := float(negative_host.get("width", 0.0)) if runs_along_z else float(negative_host.get("depth", 0.0))
		var positive_cross_span := float(positive_host.get("width", 0.0)) if runs_along_z else float(positive_host.get("depth", 0.0))
		var negative_inner_facade := negative_center.x + negative_cross_span * 0.5 if runs_along_z else negative_center.z + negative_cross_span * 0.5
		var positive_inner_facade := positive_center.x - positive_cross_span * 0.5 if runs_along_z else positive_center.z - positive_cross_span * 0.5
		var route_cross_center := center.x if runs_along_z else center.z
		var negative_inner_local := negative_inner_facade - route_cross_center
		var positive_inner_local := positive_inner_facade - route_cross_center
		var negative_structural_depth := float(negative_host.get("depth", 0.0)) if runs_along_z else float(negative_host.get("width", 0.0))
		var positive_structural_depth := float(positive_host.get("depth", 0.0)) if runs_along_z else float(positive_host.get("width", 0.0))
		var facade_gap := positive_inner_facade - negative_inner_facade
		var maximum_gap := clear_width + minf(negative_structural_depth, positive_structural_depth) * 0.72
		if facade_gap <= clear_width or facade_gap > maximum_gap:
			continue
		var room_height := 1.85
		var connector_floor_y := foundation_height + center.y + clear_height
		var bridge_center := Vector3(center.x, connector_floor_y + room_height * 0.5, center.z)
		var dominant_inner_edge := clear_width * 0.08
		var secondary_inner_edge := clear_width * 0.34
		var connector_center_axis := (dominant_inner_edge + secondary_inner_edge) * 0.5
		var connector_span := secondary_inner_edge - dominant_inner_edge + 0.18
		var negative_projection_span := absf(dominant_inner_edge - (negative_inner_local - 0.42))
		var positive_projection_span := absf(secondary_inner_edge - (positive_inner_local + 0.42))
		if negative_projection_span > negative_structural_depth * 0.82 or positive_projection_span > positive_structural_depth * 0.82:
			continue
		for side in [-1.0, 1.0]:
			var host: Dictionary = negative_host if side < 0.0 else positive_host
			var host_center: Vector3 = host.get("center", Vector3.ZERO) as Vector3
			var host_cross_span := float(host.get("width", 0.0)) if runs_along_z else float(host.get("depth", 0.0))
			var host_inner_world := host_center.x + host_cross_span * 0.5 if runs_along_z and side < 0.0 else host_center.x - host_cross_span * 0.5 if runs_along_z else host_center.z + host_cross_span * 0.5 if side < 0.0 else host_center.z - host_cross_span * 0.5
			var host_inner_edge := host_inner_world - route_cross_center
			var inner_edge: float = dominant_inner_edge if side < 0.0 else secondary_inner_edge
			var outer_edge := host_inner_edge - 0.42 if side < 0.0 else host_inner_edge + 0.42
			var projection_span := absf(inner_edge - outer_edge)
			var projection_offset := (inner_edge + outer_edge) * 0.5
			var wing_height := room_height if side < 0.0 else room_height * 0.78
			var wing_depth := projection_depth * 1.18 if side < 0.0 else projection_depth * 0.76
			var wing_lift := 0.0 if side < 0.0 else 0.42
			var host_material := String(host.get("residenceFacadeMaterial", material))
			var projection_center := bridge_center + Vector3(0.0, wing_lift, 0.0) + (Vector3(projection_offset, 0.0, -projection_depth * 0.10) if runs_along_z else Vector3(-projection_depth * 0.10, 0.0, projection_offset))
			var projection_size := Vector3(projection_span, wing_height, wing_depth) if runs_along_z else Vector3(wing_depth, wing_height, projection_span)
			add_part(blueprint, "castle_route_neck_%s_host_projection_%d" % [neck_id, int(side)], "wall", host_material, projection_center, projection_size, {"variation": variation - 0.015 + side * 0.008, "semantic": "castle_route_neck_host_projection", "hostResidenceId": String(host.get("id", ""))})
			var wing_roof_size := Vector3(projection_span + 0.34, 0.42, wing_depth + 0.38) if runs_along_z else Vector3(wing_depth + 0.38, 0.42, projection_span + 0.34)
			add_part(blueprint, "castle_route_neck_%s_host_roof_%d" % [neck_id, int(side)], "roof", "roof_shingle", projection_center + Vector3(0.0, wing_height * 0.5 + 0.22, 0.0), wing_roof_size, {"collision": false, "variation": variation + side * 0.008, "semantic": "castle_route_neck_host_roof"})
			var facade_window_count := 2 if projection_span >= 2.8 else 1
			for bay_index in range(facade_window_count):
				var bay_progress := (float(bay_index) + 1.0) / (float(facade_window_count) + 1.0)
				var bay_axis := lerpf(minf(inner_edge, outer_edge), maxf(inner_edge, outer_edge), bay_progress)
				var bay_center := projection_center
				if runs_along_z:
					bay_center.x = center.x + bay_axis
					bay_center.z += wing_depth * 0.5 + 0.025
				else:
					bay_center.z = center.z + bay_axis
					bay_center.x += wing_depth * 0.5 + 0.025
				var bay_size := Vector3(0.68, minf(1.10, wing_height * 0.62), 0.08) if runs_along_z else Vector3(0.08, minf(1.10, wing_height * 0.62), 0.68)
				add_part(blueprint, "castle_route_neck_%s_host_window_%d_%02d" % [neck_id, int(side), bay_index], "window", "window_glass", bay_center, bay_size, {"collision": false, "variation": variation + side * 0.01 + float(bay_index) * 0.004, "semantic": "castle_route_neck_occupied_bay"})
				var lintel_center := bay_center + Vector3(0.0, bay_size.y * 0.5 + 0.08, 0.0)
				var lintel_size := Vector3(bay_size.x + 0.24, 0.12, 0.12) if runs_along_z else Vector3(0.12, 0.12, bay_size.z + 0.24)
				add_part(blueprint, "castle_route_neck_%s_host_lintel_%d_%02d" % [neck_id, int(side), bay_index], "beam", "timber_beam", lintel_center, lintel_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_window_frame"})
			for frame_side in [-1.0, 1.0]:
				var frame_axis: float = projection_offset + frame_side * projection_span * 0.46
				var frame_center := projection_center
				if runs_along_z:
					frame_center.x = center.x + frame_axis
					frame_center.z += wing_depth * 0.5 + 0.035
				else:
					frame_center.z = center.z + frame_axis
					frame_center.x += wing_depth * 0.5 + 0.035
				var frame_size := Vector3(0.12, wing_height * 0.88, 0.10) if runs_along_z else Vector3(0.10, wing_height * 0.88, 0.12)
				add_part(blueprint, "castle_route_neck_%s_host_frame_%d_%d" % [neck_id, int(side), int(frame_side)], "beam", "timber_beam", frame_center, frame_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_host_frame"})
			var bond_axis: float = outer_edge + side * 0.06
			var bond_center := bridge_center + Vector3(0.0, wing_lift, 0.0) + (Vector3(bond_axis, 0.0, -projection_depth * 0.10) if runs_along_z else Vector3(-projection_depth * 0.10, 0.0, bond_axis))
			var bond_size := Vector3(0.22, wing_height + 0.34, wing_depth + 0.16) if runs_along_z else Vector3(wing_depth + 0.16, wing_height + 0.34, 0.22)
			add_part(blueprint, "castle_route_neck_%s_host_bond_%d" % [neck_id, int(side)], "beam", "timber_beam", bond_center, bond_size, {"collision": false, "variation": variation + side * 0.006, "semantic": "castle_route_neck_host_bond"})
		var connector_center := bridge_center + (Vector3(connector_center_axis, -0.18, projection_depth * 0.18) if runs_along_z else Vector3(projection_depth * 0.18, -0.18, connector_center_axis))
		var connector_size := Vector3(connector_span, room_height * 0.66, projection_depth * 0.54) if runs_along_z else Vector3(projection_depth * 0.54, room_height * 0.66, connector_span)
		add_part(blueprint, "castle_route_neck_%s_connector" % neck_id, "wall", material, connector_center, connector_size, {"variation": variation - 0.01, "semantic": "castle_route_neck_connector"})
		var connector_roof_size := Vector3(connector_span + 0.30, 0.22, projection_depth * 0.72 + 0.30) if runs_along_z else Vector3(projection_depth * 0.72 + 0.30, 0.22, connector_span + 0.30)
		add_part(blueprint, "castle_route_neck_%s_connector_roof" % neck_id, "roof", "roof_shingle", connector_center + Vector3(0.0, connector_size.y * 0.5 + 0.15, 0.0), connector_roof_size, {"collision": false, "variation": variation - 0.006, "semantic": "castle_route_neck_connector_roof"})
		for side in [-1.0, 1.0]:
			var corbel_axis := -clear_width * 0.22 if side < 0.0 else clear_width * 0.27
			var corbel_offset := Vector3(corbel_axis, -room_height * 0.58, 0.0) if runs_along_z else Vector3(0.0, -room_height * 0.58, corbel_axis)
			var corbel_size := Vector3(0.42, 0.34, projection_depth + 0.24) if runs_along_z else Vector3(projection_depth + 0.24, 0.34, 0.42)
			add_part(blueprint, "castle_route_neck_%s_corbel_%d" % [neck_id, int(side)], "beam", "timber_beam", bridge_center + corbel_offset, corbel_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_corbel"})
			var window_axis := -clear_width * 0.18 if side < 0.0 else clear_width * 0.43
			var window_depth := projection_depth * 0.59 if side < 0.0 else projection_depth * 0.39
			var window_offset := Vector3(window_axis, 0.04 + (0.42 if side > 0.0 else 0.0), window_depth) if runs_along_z else Vector3(window_depth, 0.04 + (0.42 if side > 0.0 else 0.0), window_axis)
			var window_size := Vector3(0.78, 1.12, 0.10) if runs_along_z else Vector3(0.10, 1.12, 0.78)
			var window_center := bridge_center + window_offset
			add_part(blueprint, "castle_route_neck_%s_window_%d" % [neck_id, int(side)], "window", "window_glass", window_center, window_size, {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_route_neck_window"})
			if side < 0.0:
				var oriel_size := Vector3(1.24, 0.22, 0.34) if runs_along_z else Vector3(0.34, 0.22, 1.24)
				var oriel_offset := Vector3(0.0, -0.68, 0.15) if runs_along_z else Vector3(0.15, -0.68, 0.0)
				add_part(blueprint, "castle_route_neck_%s_oriel_sill" % neck_id, "beam", "timber_beam", window_center + oriel_offset, oriel_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_oriel"})
		var connector_frame_size := Vector3(connector_span + 0.08, 0.14, projection_depth * 0.76) if runs_along_z else Vector3(projection_depth * 0.76, 0.14, connector_span + 0.08)
		add_part(blueprint, "castle_route_neck_%s_timber_frame" % neck_id, "beam", "timber_beam", connector_center + Vector3(0.0, -connector_size.y * 0.36, 0.0), connector_frame_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_frame"})


static func citadel_route_neck_hosts(residences: Array[Dictionary], center: Vector3, runs_along_z: bool) -> Array[Dictionary]:
	var negative_host: Dictionary = {}
	var positive_host: Dictionary = {}
	var negative_distance := INF
	var positive_distance := INF
	for residence_value in residences:
		var residence: Dictionary = residence_value as Dictionary
		var residence_center: Vector3 = residence.get("center", Vector3.ZERO) as Vector3
		var route_axis_distance := absf(residence_center.z - center.z) if runs_along_z else absf(residence_center.x - center.x)
		var route_axis_span := float(residence.get("depth", 0.0)) if runs_along_z else float(residence.get("width", 0.0))
		var cross_delta := residence_center.x - center.x if runs_along_z else residence_center.z - center.z
		var cross_span := float(residence.get("width", 0.0)) if runs_along_z else float(residence.get("depth", 0.0))
		var facade_distance := absf(cross_delta) - cross_span * 0.5
		var route_gap := maxf(0.0, route_axis_distance - route_axis_span * 0.5)
		var score := maxf(0.0, facade_distance) + route_gap * 1.4 + route_axis_distance * 0.12
		if cross_delta < 0.0 and score < negative_distance:
			negative_host = residence
			negative_distance = score
		elif cross_delta > 0.0 and score < positive_distance:
			positive_host = residence
			positive_distance = score
	if negative_host.is_empty() or positive_host.is_empty():
		return []
	return [negative_host, positive_host]


static func add_citadel_processional_steps(blueprint, prefix: String, center_x: float, center_z: float, width: float, from_elevation: float, to_elevation: float, foundation_height: float, variation: float) -> void:
	var step_count := 7
	var tread_depth := 0.48
	for step_index in range(step_count):
		var progress := float(step_index + 1) / float(step_count)
		var elevation := lerpf(from_elevation, to_elevation, progress)
		# Ramp the palace forecourt's 0.14 m surface cap through the seven treads.
		# The first 0.02 m increment keeps the roadbed handoff within the ordinary
		# step-height contract; the final increment makes the last tread exactly
		# coplanar with the forecourt.
		var surface_offset := 0.14 * progress
		var step_height := elevation + surface_offset
		var step_z := center_z - tread_depth * float(step_count - step_index)
		var step_id := "%s_%02d" % [prefix, step_index + 1]
		var step = add_part(blueprint, step_id, "foundation", "stone_foundation", Vector3(center_x, foundation_height + step_height * 0.5, step_z), Vector3(width, maxf(0.12, step_height), tread_depth + 0.04), {"variation": variation - 0.04, "semantic": "castle_processional_step", "navigationRole": "walkable_support", "physicalIntent": "structural_mass", "physicalAssemblyRole": "walkable_subfloor"})
		# Raised masonry is carried by the generated foundations below it; its
		# name/kind does not make it a ground root. Preserve every tread vertex.
		var roots: Array[String] = []
		if blueprint.is_grounded_structural_root(step):
			roots.append(step_id)
		else:
			var step_bounds: AABB = blueprint.transformed_part_bounds(step)
			for support in blueprint.parts:
				if support == step or not blueprint.is_grounded_structural_root(support) or support.rotation != Vector3.ZERO:
					continue
				var support_bounds: AABB = blueprint.transformed_part_bounds(support)
				if absf(support_bounds.end.y - step_bounds.position.y) > 0.04:
					continue
				if minf(step_bounds.end.x, support_bounds.end.x) <= maxf(step_bounds.position.x, support_bounds.position.x) or minf(step_bounds.end.z, support_bounds.end.z) <= maxf(step_bounds.position.z, support_bounds.position.z):
					continue
				roots.append(support.id)
			roots.sort()
			step.recipe["physicalRequiredSeatPartIds"] = roots.duplicate()
		step.recipe["routeTransitionRootPartIds"] = roots


static func add_citadel_residence_facade_details(blueprint, residences: Array[Dictionary], grammar: Dictionary, foundation_height: float, variation: float) -> void:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var route_centers: Array = grid.get("routeCenters", []) as Array
	for residence_value in residences:
		var residence: Dictionary = residence_value as Dictionary
		var center: Vector3 = residence.get("center", Vector3.ZERO) as Vector3
		var terrace_elevation := float(residence.get("terraceElevation", 0.0))
		var wall_height := float((residence.get("residenceRecipe", {}) as Dictionary).get("wallHeight", 7.0))
		var width := float(residence.get("width", 8.0))
		var depth := float(residence.get("depth", 8.0))
		var front_direction := String(residence.get("frontDirection", "east"))
		var doorway_geometry: Dictionary = (residence.get("compositionDescriptor", {}) as Dictionary).get("door", {}) as Dictionary
		if doorway_geometry.is_empty():
			push_error("Castle residence %s cannot publish facade details without its generated doorway" % String(residence.get("id", "home")))
			continue
		var outward: Vector3 = doorway_geometry.get("exteriorNormal", Vector3.FORWARD) as Vector3
		var doorway_center: Vector3 = doorway_geometry.get("center", center) as Vector3
		var facade_center := Vector3(doorway_center.x, center.y, doorway_center.z) + outward * 0.42
		var detail_y := foundation_height + terrace_elevation + minf(wall_height * 0.58, 6.2)
		var residence_recipe: Dictionary = residence.get("residenceRecipe", {}) as Dictionary
		var opening_policy: Dictionary = residence_recipe.get("openingPolicy", {}) as Dictionary
		var entry_width := float(doorway_geometry.get("openingWidth", opening_policy.get("entryWidth", 1.8)))
		var pilaster_lateral_offset := entry_width * 0.5 + 0.72
		var detail_span := maxf(clampf((depth if absf(outward.x) > 0.5 else width) * 0.24, 1.8, 3.0), pilaster_lateral_offset * 2.0 + 0.40)
		var awning_size := Vector3(0.92, 0.14, detail_span) if absf(outward.x) > 0.5 else Vector3(detail_span, 0.14, 0.92)
		var facade_residence_id := String(residence.get("id", "home"))
		var awning_anchor_ids: Array[String] = []
		for bracket_side in [-1.0, 1.0]:
			var bracket_offset := Vector3(0.0, -0.30, bracket_side * pilaster_lateral_offset) if absf(outward.x) > 0.5 else Vector3(bracket_side * pilaster_lateral_offset, -0.30, 0.0)
			var bracket_size := Vector3(0.56, 0.10, 0.10) if absf(outward.x) > 0.5 else Vector3(0.10, 0.10, 0.56)
			var anchor_id := "castle_residence_awning_pilaster_%s_%d" % [facade_residence_id, int(bracket_side)]
			awning_anchor_ids.append(anchor_id)
			var anchor_descriptor := residence_composition_part(residence, anchor_id)
			if anchor_descriptor.is_empty():
				push_error("Castle residence %s is missing planned facade collider %s" % [facade_residence_id, anchor_id])
				continue
			add_part(blueprint, anchor_id, "foundation", String(residence.get("residenceFacadeMaterial", "stone_foundation")), anchor_descriptor.get("center", Vector3.ZERO) as Vector3, anchor_descriptor.get("size", Vector3.ZERO) as Vector3, {"variation": variation - 0.018, "semantic": "castle_residence_awning_pilaster", "physicalIntent": "structural_root", "castleResidenceId": facade_residence_id})
			add_part(blueprint, "castle_residence_awning_bracket_%s_%d" % [facade_residence_id, int(bracket_side)], "beam", "timber_beam", Vector3(facade_center.x, detail_y, facade_center.z) + bracket_offset - outward * 0.18, bracket_size, {"collision": false, "variation": variation, "semantic": "castle_residence_awning_bracket", "physicalIntent": "facade_attachment", "physicalRequiredAnchorPartIds": [anchor_id], "physicalRequiredAnchorFacts": [{"anchorId": anchor_id, "contactMode": "attachment_socket", "localMountCenter": Vector3.ZERO, "localMountHalfExtents": Vector3(0.04, 0.02, 0.02)}]})
		add_part(blueprint, "castle_residence_awning_%s" % facade_residence_id, "roof", "painted_decor", Vector3(facade_center.x, detail_y, facade_center.z), awning_size, {"collision": false, "variation": variation + float(facade_residence_id.hash() % 11) * 0.004, "semantic": "castle_residence_awning", "physicalIntent": "facade_attachment", "physicalRequiredAnchorPartIds": awning_anchor_ids})
		if String(residence.get("districtClass", "")) == "civic_anchor":
			var market_center := facade_center + outward * 0.18
			var counter_size := Vector3(0.46, 0.22, detail_span * 0.82) if absf(outward.x) > 0.5 else Vector3(detail_span * 0.82, 0.22, 0.46)
			add_part(blueprint, "castle_gate_market_counter_%s" % String(residence.get("id", "anchor")), "decor", "timber_board", Vector3(market_center.x, foundation_height + terrace_elevation + 1.02, market_center.z), counter_size, {"collision": false, "variation": variation, "semantic": "castle_gate_market_counter"})
			for goods_index in range(3):
				var lateral := (float(goods_index) - 1.0) * detail_span * 0.28
				var goods_offset := Vector3(0.0, 0.0, lateral) if absf(outward.x) > 0.5 else Vector3(lateral, 0.0, 0.0)
				add_part(blueprint, "castle_gate_market_goods_%s_%02d" % [String(residence.get("id", "anchor")), goods_index], "decor", "painted_decor", Vector3(market_center.x, foundation_height + terrace_elevation + 1.30 + float(goods_index % 2) * 0.10, market_center.z) + goods_offset, Vector3(0.30, 0.34 + float(goods_index % 2) * 0.12, 0.30), {"collision": false, "variation": variation + float(goods_index) * 0.03, "semantic": "castle_gate_market_goods"})
		var residence_id := String(residence.get("id", "home"))
		var balcony_id := "castle_residence_balcony_%s" % residence_id
		var balcony_descriptor := residence_composition_part(residence, balcony_id)
		var publishes_balcony := not balcony_descriptor.is_empty()
		if publishes_balcony:
			var balcony_size := Vector3(1.05, 0.18, detail_span * 0.88) if absf(outward.x) > 0.5 else Vector3(detail_span * 0.88, 0.18, 1.05)
			var underframe_id := "%s_underframe" % balcony_id
			var balcony_center := Vector3(facade_center.x, detail_y - 0.36, facade_center.z)
			var underframe_size := Vector3(balcony_size.x, 0.12, balcony_size.z)
			var underframe_center := balcony_center - Vector3.UP * (balcony_size.y * 0.5 + underframe_size.y * 0.5)
			var radial_half_span := balcony_size.x * 0.5 if absf(outward.x) > 0.5 else balcony_size.z * 0.5
			var support_wall_height := maxf(0.24, underframe_center.y + underframe_size.y * 0.5 - (foundation_height + terrace_elevation + 0.14))
			var support_pier_center := balcony_center - outward * (radial_half_span - 0.09)
			support_pier_center.y = foundation_height + terrace_elevation + 0.14 + support_wall_height * 0.5
			var support_pier_ids: Array[String] = []
			for pier_side in [-1.0, 1.0]:
				var support_pier_id := "%s_support_pier_%d" % [balcony_id, int(pier_side)]
				var lateral_offset := Vector3(0.0, 0.0, pier_side * pilaster_lateral_offset) if absf(outward.x) > 0.5 else Vector3(pier_side * pilaster_lateral_offset, 0.0, 0.0)
				support_pier_ids.append(support_pier_id)
				var support_descriptor := residence_composition_part(residence, support_pier_id)
				if support_descriptor.is_empty():
					push_error("Castle residence %s is missing planned facade collider %s" % [residence_id, support_pier_id])
					continue
				add_part(blueprint, support_pier_id, "foundation", String(residence.get("residenceFacadeMaterial", "stone_foundation")), support_descriptor.get("center", support_pier_center + lateral_offset) as Vector3, support_descriptor.get("size", Vector3(0.20, support_wall_height, 0.20)) as Vector3, {"collision": true, "variation": variation - 0.015, "semantic": "castle_residence_balcony_support_pier", "physicalIntent": "structural_root", "physicalRoot": true, "castleResidenceId": residence_id})
			var underframe_descriptor := residence_composition_part(residence, underframe_id)
			add_part(blueprint, underframe_id, "floor", "timber_beam", underframe_descriptor.get("center", underframe_center) as Vector3, underframe_descriptor.get("size", underframe_size) as Vector3, {"collision": true, "variation": variation - 0.008, "semantic": "castle_residence_balcony_underframe", "physicalIntent": "structural_mass", "physicalRequiredSupportPartIds": support_pier_ids, "castleResidenceId": residence_id})
			add_part(blueprint, balcony_id, "floor", "timber_board", balcony_descriptor.get("center", balcony_center) as Vector3, balcony_descriptor.get("size", balcony_size) as Vector3, {"collision": true, "variation": variation, "semantic": "castle_residence_balcony", "physicalIntent": "walkable_surface", "physicalRequiredSupportPartIds": [underframe_id], "playerSurfaceAudit": true, "castleResidenceId": residence_id})
			for rail_side in [-1.0, 1.0]:
				var rail_offset := Vector3(0.0, 0.34, rail_side * detail_span * 0.40) if absf(outward.x) > 0.5 else Vector3(rail_side * detail_span * 0.40, 0.34, 0.0)
				add_part(blueprint, "castle_residence_balcony_rail_%s_%d" % [String(residence.get("id", "home")), int(rail_side)], "beam", "timber_beam", Vector3(facade_center.x, detail_y - 0.36, facade_center.z) + rail_offset, Vector3(0.12, 0.68, 0.12), {"collision": false, "variation": variation, "semantic": "castle_residence_balcony"})
		var district_class := String(residence.get("districtClass", ""))
		var supports_facade_projections := bool(residence.get("supportsFacadeProjections", false))
		if supports_facade_projections and district_class == "sightline_screen":
			var screen_material := String(residence.get("residenceFacadeMaterial", "painted_brick_cream"))
			var side_axis := Vector3.RIGHT if absf(outward.z) > 0.5 else Vector3.FORWARD
			var screen_side := -1.0 if center.x > 0.0 else 1.0
			var visibility_projection := 0.45
			var corner_face_center := center + outward * ((depth if absf(outward.z) > 0.5 else width) * 0.5 + 0.18) + side_axis * screen_side * ((width if absf(outward.z) > 0.5 else depth) * 0.34 + visibility_projection)
			for step_index in range(2):
				var step_width := (width if absf(outward.z) > 0.5 else depth) * (0.25 - float(step_index) * 0.055)
				var step_depth := 0.86 + float(step_index) * 0.24
				var step_height := wall_height * (0.54 - float(step_index) * 0.12)
				var step_center := corner_face_center - side_axis * screen_side * float(step_index) * step_width * 0.92 - outward * float(step_index) * 0.34 + outward * step_depth * 0.5
				step_center.y = foundation_height + terrace_elevation + step_height * 0.5
				var step_size := Vector3(step_width, step_height, step_depth) if absf(outward.z) > 0.5 else Vector3(step_depth, step_height, step_width)
				add_part(blueprint, "castle_sightline_screen_corner_%02d" % step_index, "wall", screen_material, step_center, step_size, {"collision": false, "variation": variation + float(step_index) * 0.008, "semantic": "castle_sightline_screen_corner_step", "physicalIntent": "facade_attachment"})
				var step_window_center := step_center + outward * (step_depth * 0.5 + 0.045)
				step_window_center.y = foundation_height + terrace_elevation + minf(step_height * 0.62, 6.8)
				var step_window_size := Vector3(step_width * 0.48, 1.28, 0.10) if absf(outward.z) > 0.5 else Vector3(0.10, 1.28, step_width * 0.48)
				add_part(blueprint, "castle_sightline_screen_corner_window_%02d" % step_index, "window", "window_glass", step_window_center, step_window_size, {"collision": false, "variation": variation, "semantic": "castle_sightline_screen_corner_window"})
				var roof_center := step_center + Vector3(0.0, step_height * 0.5 + 0.22, 0.0) - outward * 0.10
				var roof_size := Vector3(step_width + 0.42, 0.24, step_depth + 0.50) if absf(outward.z) > 0.5 else Vector3(step_depth + 0.50, 0.24, step_width + 0.42)
				add_part(blueprint, "castle_sightline_screen_corner_roof_%02d" % step_index, "roof", "roof_shingle", roof_center, roof_size, {"collision": false, "variation": variation - 0.01 + float(step_index) * 0.006, "semantic": "castle_sightline_screen_corner_gable"})
		if supports_facade_projections and district_class in ["civic", "civic_anchor", "sightline_screen"]:
			var stable_selector := absi(String(residence.get("id", "home")).hash()) % 5
			var publishes_oriel := district_class == "sightline_screen" or stable_selector in [1, 3, 4]
			if publishes_oriel:
				var projection_depth := 0.72 + float(stable_selector % 3) * 0.18
				var projection_span := clampf((depth if absf(outward.x) > 0.5 else width) * (0.30 + float(stable_selector % 2) * 0.05), 2.5, 4.2)
				var projection_height := clampf(wall_height * 0.30, 1.75, 2.35)
				var lateral_bias := (float(stable_selector) - 2.0) * 0.24
				var lateral_axis := Vector3.FORWARD if absf(outward.x) > 0.5 else Vector3.RIGHT
				var projection_center := facade_center + outward * (projection_depth * 0.5 - 0.36) + lateral_axis * lateral_bias
				projection_center.y = foundation_height + terrace_elevation + wall_height - projection_height * 0.56
				var projection_size := Vector3(projection_depth, projection_height, projection_span) if absf(outward.x) > 0.5 else Vector3(projection_span, projection_height, projection_depth)
				var facade_material := String(residence.get("residenceFacadeMaterial", "painted_brick_cream"))
				var backing_size := Vector3(projection_depth + 0.34, projection_height * 0.90, projection_span * 0.78) if absf(outward.x) > 0.5 else Vector3(projection_span * 0.78, projection_height * 0.90, projection_depth + 0.34)
				var backing_center := projection_center - outward * (projection_depth * 0.50 + 0.12)
				var backing_id := "castle_route_frontage_oriel_backing_%s" % String(residence.get("id", "home"))
				var backing_descriptor := residence_composition_part(residence, backing_id)
				add_part(blueprint, backing_id, "wall", facade_material, backing_descriptor.get("center", backing_center) as Vector3, backing_descriptor.get("size", backing_size) as Vector3, {"variation": variation - 0.012, "semantic": "castle_route_frontage_oriel_backing", "physicalIntent": "structural_mass", "requiresStructuralSupport": true, "castleResidenceId": String(residence.get("id", "home"))})
				add_part(blueprint, "castle_route_frontage_oriel_%s" % String(residence.get("id", "home")), "wall", facade_material, projection_center, projection_size, {"collision": false, "variation": variation + float(stable_selector) * 0.006, "semantic": "castle_route_frontage_oriel", "physicalIntent": "facade_attachment"})
				var roof_center := projection_center + Vector3(0.0, projection_height * 0.5 + 0.16, 0.0) + outward * 0.08
				var roof_size := Vector3(projection_depth + 0.34, 0.22, projection_span + 0.32) if absf(outward.x) > 0.5 else Vector3(projection_span + 0.32, 0.22, projection_depth + 0.34)
				add_part(blueprint, "castle_route_frontage_oriel_roof_%s" % String(residence.get("id", "home")), "roof", "roof_shingle", roof_center, roof_size, {"collision": false, "variation": variation - 0.01, "semantic": "castle_route_frontage_oriel_roof"})
				var window_center := projection_center + outward * (projection_depth * 0.5 + 0.045)
				var window_size := Vector3(0.10, minf(1.24, projection_height * 0.64), projection_span * 0.56) if absf(outward.x) > 0.5 else Vector3(projection_span * 0.56, minf(1.24, projection_height * 0.64), 0.10)
				add_part(blueprint, "castle_route_frontage_oriel_recess_%s" % String(residence.get("id", "home")), "decor", "window_recess", window_center, window_size, {"collision": false, "variation": variation, "semantic": "castle_route_frontage_oriel_blind_recess"})
				for bracket_side in [-1.0, 1.0]:
					var bracket_lateral: Vector3 = lateral_axis * bracket_side * projection_span * 0.34
					var bracket_center: Vector3 = projection_center - outward * projection_depth * 0.22 - Vector3(0.0, projection_height * 0.58, 0.0) + bracket_lateral
					var bracket_size := Vector3(projection_depth * 0.72, 0.18, 0.16) if absf(outward.x) > 0.5 else Vector3(0.16, 0.18, projection_depth * 0.72)
					add_part(blueprint, "castle_route_frontage_oriel_bracket_%s_%d" % [String(residence.get("id", "home")), int(bracket_side)], "beam", "timber_beam", bracket_center, bracket_size, {"collision": false, "variation": variation, "semantic": "castle_route_frontage_oriel_bracket"})


static func citadel_terrace_elevation_at_z(grid: Dictionary, z: float) -> float:
	# Callers that place residences own the complete castle grammar, while the
	# terrace and street publishers already own its courtyard-grid record. Both
	# must resolve through the same sampled grid or buildings can remain at the
	# base slab while the authoritative terrace rises through them.
	var resolved_grid: Dictionary = grid.get("courtyardGrid", grid) as Dictionary
	var step_height := float(resolved_grid.get("terraceStepHeight", 1.75))
	if String(resolved_grid.get("layoutFamily", "")) == "bent_processional":
		if z < float(resolved_grid.get("firstTurnZ", 0.0)):
			return 0.0
		if z < float(resolved_grid.get("finalTurnZ", 0.0)):
			return step_height
		return step_height * 2.0
	var rows: Array = resolved_grid.get("rowCenters", []) as Array
	var row_index := 0
	for candidate_index in range(rows.size()):
		if z >= float(rows[candidate_index]):
			row_index = candidate_index
	return minf(7.0, float(row_index) * step_height)


static func add_curtain_x_segment(blueprint, prefix: String, z: float, from_x: float, to_x: float, height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	var length := to_x - from_x
	if length <= 0.20:
		return
	add_curtain_run(blueprint, prefix, Vector3((from_x + to_x) * 0.5, 0.0, z), Vector3(length, height, 0.72), foundation_height, variation, masonry_material)


static func add_curtain_z_segment(blueprint, prefix: String, x: float, from_z: float, to_z: float, height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	var length := to_z - from_z
	if length <= 0.20:
		return
	add_curtain_run(blueprint, prefix, Vector3(x, 0.0, (from_z + to_z) * 0.5), Vector3(0.72, height, length), foundation_height, variation, masonry_material)


static func add_courtyard_outbuilding(blueprint, spec: Dictionary, castle_foundation_height: float) -> void:
	# This is intentionally a composition seam, not a third house grammar. The
	# castle reserves a valid wall lane; the existing cottage/manor builders own
	# every roof, room, window, door, stair and material decision within it.
	var source_blueprint = courtyard_residence_blueprint(spec)
	if source_blueprint == null:
		push_error("Castle courtyard residence has no shared source blueprint")
		return
	var prefix := "castle_%s" % String(spec.get("id", "courtyard_building"))
	var center: Vector3 = spec.get("center", Vector3.ZERO) as Vector3
	var local_foundation_height := float(source_blueprint.recipe.get("foundationHeight", 0.48))
	var yaw := float(spec.get("yaw", PI * 0.5 if center.x > 0.0 else -PI * 0.5))
	var origin: Vector3 = spec.get("origin", Vector3(center.x, castle_foundation_height - local_foundation_height, center.z)) as Vector3
	add_courtyard_residence_plinth(blueprint, source_blueprint, prefix, origin, yaw, castle_foundation_height, String(spec.get("residenceFacadeMaterial", "stone_foundation")))
	add_courtyard_residence_egress_underfill(blueprint, source_blueprint, prefix, origin, yaw, castle_foundation_height, String(spec.get("residenceFacadeMaterial", "stone_foundation")))
	append_transformed_residence_parts(blueprint, source_blueprint, prefix, origin, yaw, castle_foundation_height, String(spec.get("residenceFamily", "cottage")), String(spec.get("residenceFacadeMaterial", "fired_brick")))


static func courtyard_residence_blueprint(spec: Dictionary):
	var residence_recipe: Dictionary = spec.get("residenceRecipe", {}) as Dictionary
	return courtyard_residence_blueprint_from_recipe(String(spec.get("residenceFamily", "cottage")), residence_recipe)


static func courtyard_residence_blueprint_from_recipe(family: String, residence_recipe: Dictionary):
	match family:
		"manor":
			return LandmarkBuildingBlueprintBuilderScript.build_from_recipe(residence_recipe)
		_:
			return CottageBlueprintBuilderScript.build_from_recipe(residence_recipe)


static func transformed_residence_doorway_geometry(spec: Dictionary) -> Dictionary:
	var source_blueprint = courtyard_residence_blueprint(spec)
	if source_blueprint == null:
		return {}
	var origin: Vector3 = spec.get("origin", spec.get("center", Vector3.ZERO)) as Vector3
	var yaw_basis := Basis(Vector3.UP, float(spec.get("yaw", residence_yaw_for_front_direction(String(spec.get("frontDirection", "north"))))))
	for source_part in source_blueprint.parts:
		if source_part == null or String(source_part.kind) != "door":
			continue
		var transformed_basis := yaw_basis * Basis.from_euler(source_part.rotation)
		var world_width: float = absf(transformed_basis.x.x) * source_part.size.x + absf(transformed_basis.y.x) * source_part.size.y + absf(transformed_basis.z.x) * source_part.size.z
		var world_depth: float = absf(transformed_basis.x.z) * source_part.size.x + absf(transformed_basis.y.z) * source_part.size.y + absf(transformed_basis.z.z) * source_part.size.z
		var outward_along_x := String(spec.get("frontDirection", "north")) in ["east", "west"]
		return {
			"sourcePartId": String(source_part.id),
			"center": origin + yaw_basis * source_part.position,
			"openingWidth": world_depth if outward_along_x else world_width
		}
	return {}


static func add_courtyard_foundation_and_paving(blueprint, residences: Array[Dictionary], courtyard_width: float, courtyard_depth: float, foundation_height: float, variation: float, reserved_walkways: Array[Dictionary] = []) -> void:
	var foundation_exclusions := courtyard_residence_egress_corridors(residences, foundation_height)
	foundation_exclusions.append_array(reserved_walkways)
	var foundation_bounds := Rect2(-courtyard_width * 0.5, -courtyard_depth * 0.5, courtyard_width, courtyard_depth)
	var foundation_rects := subtract_courtyard_egress_corridors(foundation_bounds, foundation_exclusions)
	for index in range(foundation_rects.size()):
		var rect: Rect2 = foundation_rects[index] as Rect2
		if rect.size.x <= 0.04 or rect.size.y <= 0.04:
			continue
		add_part(blueprint, "castle_compound_foundation_segment_%02d" % index, "foundation", "stone_foundation", Vector3(rect.get_center().x, foundation_height * 0.5, rect.get_center().y), Vector3(rect.size.x, foundation_height, rect.size.y), {"variation": variation, "semantic": "castle_courtyard_foundation", "navigationRole": "structural_mass", "egressCarved": true, "physicalRoot": true, "courtyardSupport": {"version":1,"producer":"castle_courtyard_foundation_and_paving","role":"shared_foundation"}})
	var paving_exclusions := courtyard_residence_egress_corridors(residences, foundation_height, 0.0)
	paving_exclusions.append_array(reserved_walkways)
	var paving_bounds := Rect2(-courtyard_width * 0.5 + 0.41, -courtyard_depth * 0.5 + 0.41, courtyard_width - 0.82, courtyard_depth - 0.82)
	var paving_rects := subtract_courtyard_egress_corridors(paving_bounds, paving_exclusions)
	for index in range(paving_rects.size()):
		var rect: Rect2 = paving_rects[index] as Rect2
		if rect.size.x <= 0.04 or rect.size.y <= 0.04:
			continue
		add_part(blueprint, "castle_compound_paving_segment_%02d" % index, "foundation", "cobblestone", Vector3(rect.get_center().x, foundation_height + 0.07, rect.get_center().y), Vector3(rect.size.x, 0.14, rect.size.y), {"variation": variation + 0.03, "semantic": "castle_courtyard_paving", "pavingFamily": "courtyard_setts", "pavingRegion": "citadel_courtyard", "pavingHeading": "x", "navigationRole": "walkable_support", "egressCarved": true})


static func keep_entry_transition_exclusions(blueprint) -> Array[Dictionary]:
	var exclusions: Array[Dictionary] = []
	for part in blueprint.parts:
		if part == null or String(part.semantic) != "castle_keep_palace_entry_forecourt":
			continue
		exclusions.append({"kind": "keep_entry_transition", "partId": String(part.id), "rect": Rect2(part.position.x - part.size.x * 0.5, part.position.z - part.size.z * 0.5, part.size.x, part.size.z)})
	return exclusions


static func courtyard_residence_egress_corridors(residences: Array[Dictionary], compound_foundation_height: float, exclusion_margin: float = 0.64) -> Array[Dictionary]:
	var corridors: Array[Dictionary] = []
	for residence_value in residences:
		var residence: Dictionary = residence_value as Dictionary
		var source_blueprint = courtyard_residence_blueprint(residence)
		if source_blueprint == null:
			continue
		var yaw := float(residence.get("yaw", 0.0))
		var origin: Vector3 = residence.get("origin", Vector3.ZERO) as Vector3
		var yaw_basis := Basis(Vector3.UP, yaw)
		for source_part in source_blueprint.parts:
			if source_part == null:
				continue
			var egress_for := String(source_part.recipe.get("doorEgressFor", ""))
			if egress_for.is_empty():
				continue
			var resolved_part := courtyard_residence_contextual_egress_part(source_part, origin.y, compound_foundation_height, float(residence.get("terraceElevation", 0.0)))
			var resolved_position: Vector3 = resolved_part.get("position", source_part.position) as Vector3
			var resolved_rotation: Vector3 = resolved_part.get("rotation", source_part.rotation) as Vector3
			var resolved_size: Vector3 = resolved_part.get("size", source_part.size) as Vector3
			var transform := Transform3D(yaw_basis * Basis.from_euler(resolved_rotation), origin + yaw_basis * resolved_position)
			corridors.append({
				"residenceId": String(residence.get("id", "")),
				"doorPartId": egress_for,
				"rect": transformed_horizontal_bounds(transform, resolved_size).grow(maxf(0.0, exclusion_margin)),
				"approachTransform": transform,
				"approachSize": resolved_size,
				"approachKind": String(source_part.kind),
				"approachSemantic": String(source_part.semantic)
			})
	return corridors


static func courtyard_residence_structural_exclusions(residences: Array[Dictionary]) -> Array[Dictionary]:
	var exclusions: Array[Dictionary] = []
	for residence_value in residences:
		var residence: Dictionary = residence_value as Dictionary
		var source_blueprint = courtyard_residence_blueprint(residence)
		if source_blueprint == null:
			continue
		var yaw := float(residence.get("yaw", 0.0))
		var origin: Vector3 = residence.get("origin", Vector3.ZERO) as Vector3
		var yaw_basis := Basis(Vector3.UP, yaw)
		for source_part in source_blueprint.parts:
			if source_part == null or String(source_part.kind) != "foundation" or not bool(source_part.collision_enabled):
				continue
			var transform := Transform3D(yaw_basis * Basis.from_euler(source_part.rotation), origin + yaw_basis * source_part.position)
			exclusions.append({
				"residenceId": String(residence.get("id", "")),
				"rect": transformed_horizontal_bounds(transform, source_part.size).grow(0.08),
				"kind": "residence_foundation"
			})
	return exclusions


static func subtract_courtyard_egress_corridors(initial: Rect2, corridors: Array[Dictionary], preserve_construction_planes := false) -> Array[Rect2]:
	var result: Array[Rect2] = [initial]
	for corridor_value in corridors:
		var corridor: Dictionary = corridor_value as Dictionary
		var hole: Rect2 = corridor.get("rect", Rect2()) as Rect2
		if hole.size.x <= 0.0 or hole.size.y <= 0.0:
			continue
		var remaining: Array[Rect2] = []
		for rect_value in result:
			var rect: Rect2 = rect_value as Rect2
			var overlap := rect.intersection(hole)
			# Existing callers retain their historical Rect2 intersection result.
			# Replacement-solid carving must keep the supplied cut planes exactly:
			# rebuilding an intersection width can round its far edge a second time.
			var overlap_min_x := maxf(rect.position.x,hole.position.x) if preserve_construction_planes else float(overlap.position.x)
			var overlap_max_x := minf(rect.end.x,hole.end.x) if preserve_construction_planes else float(overlap.end.x)
			var overlap_min_z := maxf(rect.position.y,hole.position.y) if preserve_construction_planes else float(overlap.position.y)
			var overlap_max_z := minf(rect.end.y,hole.end.y) if preserve_construction_planes else float(overlap.end.y)
			var minimum_overlap := 0.0 if preserve_construction_planes else 0.0001
			var empty_overlap: bool = overlap_max_x-overlap_min_x <= minimum_overlap or overlap_max_z-overlap_min_z <= minimum_overlap
			if not preserve_construction_planes: empty_overlap=overlap.size.x<=0.0001 or overlap.size.y<=0.0001
			if empty_overlap:
				remaining.append(rect)
				continue
			append_positive_rect(remaining, Rect2(rect.position.x, rect.position.y, overlap_min_x - rect.position.x, rect.size.y))
			append_positive_rect(remaining, Rect2(overlap_max_x, rect.position.y, rect.end.x - overlap_max_x, rect.size.y))
			var overlap_width := overlap_max_x-overlap_min_x if preserve_construction_planes else float(overlap.size.x)
			append_positive_rect(remaining, Rect2(overlap_min_x, rect.position.y, overlap_width, overlap_min_z - rect.position.y))
			append_positive_rect(remaining, Rect2(overlap_min_x, overlap_max_z, overlap_width, rect.end.y - overlap_max_z))
		result = remaining
	return result


static func append_positive_rect(rectangles: Array[Rect2], rect: Rect2) -> void:
	if rect.size.x > 0.04 and rect.size.y > 0.04:
		rectangles.append(rect)


static func transformed_horizontal_bounds(transform: Transform3D, size: Vector3) -> Rect2:
	var axis_x := transform.basis * Vector3.RIGHT
	var axis_z := transform.basis * Vector3.FORWARD
	var half_x := absf(axis_x.x) * size.x * 0.5 + absf(axis_z.x) * size.z * 0.5
	var half_z := absf(axis_x.z) * size.x * 0.5 + absf(axis_z.z) * size.z * 0.5
	return Rect2(transform.origin.x - half_x, transform.origin.z - half_z, half_x * 2.0, half_z * 2.0)


static func courtyard_residence_contextual_egress_part(source_part, residence_origin_y: float, compound_foundation_height: float, terrace_elevation := 0.0) -> Dictionary:
	return CastleResidencePlacementGeometryScript.contextual_egress_part(source_part, residence_origin_y, compound_foundation_height, terrace_elevation)


static func add_courtyard_residence_egress_underfill(blueprint, source_blueprint, prefix: String, origin: Vector3, yaw: float, compound_foundation_height: float, facade_material: String) -> void:
	var residence_id := prefix.trim_prefix("castle_")
	var residence_spec: Dictionary = {}
	for residence_value in blueprint.recipe.get("courtyardResidences", []) as Array:
		if residence_value is Dictionary and String((residence_value as Dictionary).get("id", "")) == residence_id:
			residence_spec = residence_value as Dictionary
			break
	for descriptor_value in (residence_spec.get("compositionDescriptor", {}) as Dictionary).get("collisionParts", []) as Array:
		var descriptor: Dictionary = descriptor_value as Dictionary
		if String(descriptor.get("role", "")) != "egress_underfill":
			continue
		add_part(blueprint, "%s_%s" % [prefix, String(descriptor.get("id", "egress_underfill"))], "foundation", facade_material, descriptor.get("center", Vector3.ZERO) as Vector3, descriptor.get("size", Vector3.ZERO) as Vector3, {"rotation": descriptor.get("rotation", Vector3.ZERO) as Vector3, "variation": -0.04, "semantic": "castle_residence_egress_underfill", "castleResidenceId": residence_id, "navigationRole": "structural_mass"})


static func add_courtyard_residence_plinth(blueprint, source_blueprint, prefix: String, origin: Vector3, yaw: float, compound_foundation_height: float, facade_material: String) -> void:
	var residence_id := prefix.trim_prefix("castle_")
	var residence_spec: Dictionary = {}
	for residence_value in blueprint.recipe.get("courtyardResidences", []) as Array:
		if residence_value is Dictionary and String((residence_value as Dictionary).get("id", "")) == residence_id:
			residence_spec = residence_value as Dictionary
			break
	var descriptor := residence_composition_part_by_role(residence_spec, "plinth")
	if descriptor.is_empty():
		return
	add_part(blueprint, "%s_structural_plinth" % prefix, "foundation", facade_material, descriptor.get("center", Vector3.ZERO) as Vector3, descriptor.get("size", Vector3.ZERO) as Vector3, {"variation": -0.03, "semantic": "castle_residence_structural_plinth", "castleResidenceId": residence_id, "navigationRole": "structural_mass"})


static func append_transformed_residence_parts(target_blueprint, source_blueprint, prefix: String, origin: Vector3, yaw: float, compound_foundation_height: float, family: String, facade_material: String) -> void:
	var yaw_basis := Basis(Vector3.UP, yaw)
	var transformed_part_ids: Dictionary = {}
	var residence_spec: Dictionary = {}
	var residence_id := prefix.trim_prefix("castle_")
	for residence_value in target_blueprint.recipe.get("courtyardResidences", []) as Array:
		if residence_value is Dictionary and String((residence_value as Dictionary).get("id", "")) == residence_id:
			residence_spec = residence_value as Dictionary
			break
	for source_part in source_blueprint.parts:
		if source_part == null:
			continue
		var source_recipe: Dictionary = source_part.recipe.duplicate(true)
		var door_egress_for := String(source_recipe.get("doorEgressFor", ""))
		if not door_egress_for.is_empty():
			source_recipe["doorEgressFor"] = "%s__%s" % [prefix, door_egress_for]
		var door_egress: Dictionary = source_recipe.get("doorEgress", {}) as Dictionary
		if not door_egress.is_empty():
			var resolved_door_egress := door_egress.duplicate(true)
			var resolved_approach_part_ids: Array[String] = []
			for approach_part_id_value in door_egress.get("approachPartIds", []) as Array:
				var approach_part_id := String(approach_part_id_value)
				if not approach_part_id.is_empty():
					resolved_approach_part_ids.append("%s__%s" % [prefix, approach_part_id])
			resolved_door_egress["approachPartIds"] = resolved_approach_part_ids
			var outward_endpoint_part_id := String(door_egress.get("outwardEndpointPartId", ""))
			if not outward_endpoint_part_id.is_empty():
				resolved_door_egress["outwardEndpointPartId"] = "%s__%s" % [prefix, outward_endpoint_part_id]
			source_recipe["doorEgress"] = resolved_door_egress
		for navigation_support_key in ["navigationStartSupportPartId", "navigationEndSupportPartId"]:
			var navigation_support_id := String(source_recipe.get(navigation_support_key, ""))
			if not navigation_support_id.is_empty():
				source_recipe[navigation_support_key] = "%s__%s" % [prefix, navigation_support_id]
		for relationship_key in ["physicalRequiredSupportPartIds", "physicalRequiredAnchorPartIds", "physicalRequiredSeatPartIds", "physicalRequiredCoverageByZIndex", "physicalRequiredAssemblyBearingBlockIds", "physicalRequiredRoofFramePartIds", "physicalRequiredRoofFramePostIds"]:
			if not source_recipe.has(relationship_key):
				continue
			var resolved_relationship_ids: Array[String] = []
			for source_id_value in source_recipe.get(relationship_key, []) as Array:
				var source_id := String(source_id_value)
				if not source_id.is_empty():
					resolved_relationship_ids.append("%s__%s" % [prefix, source_id])
			source_recipe[relationship_key] = resolved_relationship_ids
			for source_id_value in source_part.recipe.get(relationship_key, []) as Array:
				if source_blueprint.parts.all(func(candidate) -> bool: return candidate == null or String(candidate.id) != String(source_id_value)):
					source_recipe["physicalTransformDependencyMissing"] = true
		var source_seat_facts: Array = source_recipe.get("physicalRequiredSeatFacts", []) as Array
		if not source_seat_facts.is_empty():
			var resolved_seat_facts: Array[Dictionary] = []
			for source_seat_fact_value in source_seat_facts:
				var source_seat_fact: Dictionary = source_seat_fact_value as Dictionary
				var resolved_seat_fact := source_seat_fact.duplicate(true)
				resolved_seat_fact["seatId"] = "%s__%s" % [prefix, String(source_seat_fact.get("seatId", ""))]
				resolved_seat_facts.append(resolved_seat_fact)
			source_recipe["physicalRequiredSeatFacts"] = resolved_seat_facts
		var source_anchor_facts: Array = source_recipe.get("physicalRequiredAnchorFacts", []) as Array
		if not source_anchor_facts.is_empty():
			var resolved_anchor_facts: Array[Dictionary] = []
			for source_anchor_fact_value in source_anchor_facts:
				var source_anchor_fact: Dictionary = source_anchor_fact_value as Dictionary
				var resolved_anchor_fact := source_anchor_fact.duplicate(true)
				resolved_anchor_fact["anchorId"] = "%s__%s" % [prefix, String(source_anchor_fact.get("anchorId", ""))]
				resolved_anchor_facts.append(resolved_anchor_fact)
			source_recipe["physicalRequiredAnchorFacts"] = resolved_anchor_facts
		var supported_part_id := String(source_recipe.get("physicalSupportsPartId", ""))
		if not supported_part_id.is_empty():
			source_recipe["physicalSupportsPartId"] = "%s__%s" % [prefix, supported_part_id]
		var roof_frame_id := String(source_recipe.get("physicalRoofFrameId", ""))
		if not roof_frame_id.is_empty():
			source_recipe["physicalRoofFrameId"] = "%s__%s" % [prefix, roof_frame_id]
		source_recipe["castleResidenceId"] = prefix.trim_prefix("castle_")
		source_recipe["castleResidenceFamily"] = family
		source_recipe["castleResidenceSourcePart"] = String(source_part.id)
		source_recipe["castleResidenceFacing"] = "courtyard_core"
		source_recipe["castleResidenceFacadeMaterial"] = facade_material
		var local_basis := Basis.from_euler(source_part.rotation)
		var resolved_part := courtyard_residence_contextual_egress_part(source_part, origin.y, compound_foundation_height, float(residence_spec.get("terraceElevation", 0.0)))
		var resolved_position: Vector3 = resolved_part.get("position", source_part.position) as Vector3
		var resolved_rotation: Vector3 = resolved_part.get("rotation", source_part.rotation) as Vector3
		var resolved_size: Vector3 = resolved_part.get("size", source_part.size) as Vector3
		local_basis = Basis.from_euler(resolved_rotation)
		var transformed_basis := yaw_basis * local_basis
		var planned_source := residence_composition_source_part(residence_spec, String(source_part.id))
		var published_position: Vector3 = origin + yaw_basis * resolved_position
		if bool(source_part.collision_enabled):
			if planned_source.is_empty():
				push_error("Castle residence %s is missing planned source collider %s" % [residence_id, String(source_part.id)])
				continue
			published_position = planned_source.get("center", published_position) as Vector3
			resolved_size = planned_source.get("size", resolved_size) as Vector3
			transformed_basis = planned_source.get("basis", transformed_basis) as Basis
		var semantic := "castle_courtyard_building_door" if String(source_part.kind) == "door" else "castle_courtyard_residence_%s" % String(source_part.semantic)
		source_recipe["rotation"] = transformed_basis.get_euler()
		source_recipe["collision"] = bool(source_part.collision_enabled)
		source_recipe["semantic"] = semantic
		var material_id := facade_material if String(source_part.material_id) == "fired_brick" else String(source_part.material_id)
		var transformed_part_id := "%s__%s" % [prefix, String(source_part.id)]
		add_part(target_blueprint, transformed_part_id, String(source_part.kind), material_id, published_position, resolved_size, source_recipe)
		transformed_part_ids[transformed_part_id] = true
	for target_part in target_blueprint.parts:
		if target_part == null or not transformed_part_ids.has(String(target_part.id)):
			continue
		for relationship_key in ["physicalRequiredSupportPartIds", "physicalRequiredAnchorPartIds", "physicalRequiredSeatPartIds", "physicalRequiredCoverageByZIndex", "physicalRequiredAssemblyBearingBlockIds", "physicalRequiredRoofFramePartIds", "physicalRequiredRoofFramePostIds"]:
			for dependency_value in target_part.recipe.get(relationship_key, []) as Array:
				var dependency_id := String(dependency_value)
				if not dependency_id.begins_with("%s__" % prefix) or not transformed_part_ids.has(dependency_id):
					target_part.recipe["physicalTransformDependencyMissing"] = true
		for seat_fact_value in target_part.recipe.get("physicalRequiredSeatFacts", []) as Array:
			var seat_fact: Dictionary = seat_fact_value as Dictionary
			var seat_id := String(seat_fact.get("seatId", ""))
			if not seat_id.begins_with("%s__" % prefix) or not transformed_part_ids.has(seat_id):
				target_part.recipe["physicalTransformDependencyMissing"] = true
		for anchor_fact_value in target_part.recipe.get("physicalRequiredAnchorFacts", []) as Array:
			var anchor_fact: Dictionary = anchor_fact_value as Dictionary
			var anchor_id := String(anchor_fact.get("anchorId", ""))
			if not anchor_id.begins_with("%s__" % prefix) or not transformed_part_ids.has(anchor_id):
				target_part.recipe["physicalTransformDependencyMissing"] = true


static func append_courtyard_residence_rooms(records: Array, spec: Dictionary, castle_foundation_height: float) -> void:
	var source_blueprint = courtyard_residence_blueprint(spec)
	if source_blueprint == null:
		return
	var center: Vector3 = spec.get("center", Vector3.ZERO) as Vector3
	var local_foundation_height := float(source_blueprint.recipe.get("foundationHeight", 0.48))
	var yaw := float(spec.get("yaw", PI * 0.5 if center.x > 0.0 else -PI * 0.5))
	var yaw_basis := Basis(Vector3.UP, yaw)
	var origin: Vector3 = spec.get("origin", Vector3(center.x, castle_foundation_height - local_foundation_height, center.z)) as Vector3
	var prefix := String(spec.get("id", "courtyard_building"))
	var part_prefix := "castle_%s" % prefix
	for room_value in source_blueprint.rooms:
		if not room_value is Dictionary:
			continue
		var source_room: Dictionary = room_value as Dictionary
		var local_bounds: AABB = source_room.get("bounds", AABB()) as AABB
		var transformed_size := transformed_horizontal_size(local_bounds.size, yaw_basis)
		var room := source_room.duplicate(true)
		room["id"] = "%s_%s" % [prefix, String(source_room.get("id", "room"))]
		room["bounds"] = AABB(origin + yaw_basis * local_bounds.get_center() - transformed_size * 0.5, transformed_size)
		room["castleResidenceFamily"] = String(spec.get("residenceFamily", "cottage"))
		room["castleResidenceRoom"] = true
		var transformed_accesses: Array = []
		var source_accesses: Array = source_room.get("accesses", []) as Array
		for access_value in source_accesses:
			if not access_value is Dictionary:
				continue
			var access: Dictionary = (access_value as Dictionary).duplicate(true)
			var local_position: Vector3 = access.get("position", Vector3.ZERO) as Vector3
			var local_size: Vector3 = access.get("size", Vector3.ZERO) as Vector3
			var local_furnishing_size: Vector3 = access.get("furnishingSize", local_size) as Vector3
			var source_orientation: Vector3 = access.get("orientation", Vector3.ZERO) as Vector3
			var access_basis := yaw_basis * Basis.from_euler(source_orientation)
			access["position"] = origin + yaw_basis * local_position
			access["navigationSize"] = local_size
			access["size"] = transformed_horizontal_size(local_size, access_basis)
			access["furnishingSize"] = transformed_horizontal_size(local_furnishing_size, access_basis)
			access["orientation"] = access_basis.get_euler()
			var support_part_id := String(access.get("supportPartId", ""))
			if not support_part_id.is_empty():
				access["supportPartId"] = "%s__%s" % [part_prefix, support_part_id]
			transformed_accesses.append(access)
		room["accesses"] = transformed_accesses
		records.append(room)


static func transformed_horizontal_size(size: Vector3, basis: Basis) -> Vector3:
	var axis_x := basis * Vector3.RIGHT
	var axis_z := basis * Vector3.FORWARD
	return Vector3(
		absf(axis_x.x) * size.x + absf(axis_z.x) * size.z,
		size.y,
		absf(axis_x.z) * size.x + absf(axis_z.z) * size.z
	)


static func add_tower(blueprint, prefix: String, center: Vector3, span: float, height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	add_part(blueprint, "%s_foundation" % prefix, "foundation", "stone_foundation", Vector3(center.x, foundation_height * 0.5, center.z), Vector3(span + 0.54, foundation_height, span + 0.54), {"variation": variation, "semantic": "castle_tower_foundation"})
	add_part(blueprint, "%s_floor" % prefix, "foundation", "stone_foundation", Vector3(center.x, foundation_height + 0.09, center.z), Vector3(span - 0.38, 0.18, span - 0.38), {"variation": variation, "semantic": "castle_tower_floor"})
	var wall_y := foundation_height + height * 0.5
	for spec in [
		{"id": "front", "position": Vector3(center.x, wall_y, center.z - span * 0.5), "size": Vector3(span, height, 0.62)},
		{"id": "back", "position": Vector3(center.x, wall_y, center.z + span * 0.5), "size": Vector3(span, height, 0.62)},
		{"id": "left", "position": Vector3(center.x - span * 0.5, wall_y, center.z), "size": Vector3(0.62, height, span)},
		{"id": "right", "position": Vector3(center.x + span * 0.5, wall_y, center.z), "size": Vector3(0.62, height, span)}
	]:
		add_part(blueprint, "%s_%s" % [prefix, String(spec.get("id", "wall"))], "wall", masonry_material, spec.get("position", Vector3.ZERO) as Vector3, spec.get("size", Vector3.ONE) as Vector3, {"variation": variation, "semantic": "castle_tower_wall"})
	add_part(blueprint, "%s_roof_deck" % prefix, "foundation", "stone_foundation", Vector3(center.x, foundation_height + height + 0.12, center.z), Vector3(span - 0.28, 0.24, span - 0.28), {"variation": variation, "semantic": "castle_tower_roof"})
	add_crenellations(blueprint, "%s_battlement" % prefix, center, span, span, foundation_height + height + 0.50, variation)


static func add_curtain_run(blueprint, prefix: String, center: Vector3, size: Vector3, foundation_height: float, variation: float, masonry_material: String) -> void:
	if size.x <= 0.20 or size.z <= 0.20:
		return
	add_part(blueprint, "%s_foundation" % prefix, "foundation", "stone_foundation", Vector3(center.x, foundation_height * 0.5, center.z), Vector3(size.x + 0.20, foundation_height, size.z + 0.20), {"variation": variation, "semantic": "castle_curtain_foundation"})
	add_part(blueprint, "%s_wall" % prefix, "wall", masonry_material, Vector3(center.x, foundation_height + size.y * 0.5, center.z), size, {"variation": variation, "semantic": "castle_curtain_wall"})
	add_crenellations(blueprint, "%s_battlement" % prefix, center, size.x, size.z, foundation_height + size.y + 0.36, variation)


static func add_gatehouse(blueprint, width: float, depth: float, height: float, foundation_height: float, front_z: float, variation: float, masonry_material: String) -> void:
	var center_z := front_z - depth * 0.42
	var exterior_gate_z := center_z - depth * 0.5
	# The gatehouse must preserve the broad axial opening claimed by the curtain
	# wall.  A narrow 3m chute makes the inner piers read as a solid rear wall;
	# this proportional arch keeps a clear, legible route into the courtyard at
	# every seeded compound scale.
	var opening_width := clampf(width * 0.48, 4.00, 6.00)
	var pier_width := (width - opening_width) * 0.5
	var wall_y := foundation_height + height * 0.5
	var passage_floor_top := foundation_height + 0.14
	# The gatehouse is a raised, load-bearing part of the compound.  Its full
	# footprint supplies the continuous passage floor and physically supports
	# both piers; entry steps meet this exterior edge from normal terrain.
	add_part(blueprint, "castle_gatehouse_foundation", "foundation", "stone_foundation", Vector3(0.0, foundation_height * 0.5, center_z), Vector3(width + 0.22, foundation_height, depth + 0.22), {"variation": variation, "semantic": "castle_gatehouse_foundation"})
	# Match the courtyard paving elevation throughout the passage.  Without this
	# cap the inner threshold leaves a small but real collision ledge after the
	# gate has opened.
	add_part(blueprint, "castle_gatehouse_paving", "foundation", "stone_foundation", Vector3(0.0, foundation_height + 0.07, center_z), Vector3(width - 0.34, 0.14, depth - 0.18), {"variation": variation + 0.02, "semantic": "castle_gatehouse_paving"})
	for side in [-1.0, 1.0]:
		var pier_center_x: float = side * (opening_width * 0.5 + pier_width * 0.5)
		if side < 0.0:
			# The left pier is a real enclosed stair bay rather than a decorative
			# solid.  Its rear door opens from the courtyard; all of its masonry
			# remains outside the central arch, so the gate passage stays clear.
			add_gatehouse_stair_bay(blueprint, pier_center_x, pier_width, center_z, depth, height, foundation_height, variation, masonry_material)
		else:
			add_part(blueprint, "castle_gatehouse_pier_%d" % int(side), "wall", masonry_material, Vector3(pier_center_x, wall_y, center_z), Vector3(pier_width, height, depth), {"variation": variation, "semantic": "castle_gatehouse_pier"})
	var passage_height := 2.88
	var lintel_height := height - passage_height
	add_part(blueprint, "castle_gatehouse_lintel", "wall", masonry_material, Vector3(0.0, foundation_height + passage_height + lintel_height * 0.5, center_z), Vector3(opening_width, lintel_height, depth), {"variation": variation, "semantic": "castle_gatehouse_lintel"})
	add_gatehouse_threshold_composition(blueprint, opening_width, depth, height, foundation_height, center_z, exterior_gate_z, variation)
	# Face the player with the actual operable gate.  Once raised, the player
	# traverses one continuous founded gatehouse passage into the courtyard.
	add_part(blueprint, "castle_gatehouse_portcullis", "door", "ironwork", Vector3(0.0, passage_floor_top + passage_height * 0.5, exterior_gate_z - 0.10), Vector3(opening_width - 0.16, passage_height, 0.18), {"variation": variation - 0.05, "semantic": "castle_portcullis", "doorPresentation": "portcullis", "doorMotion": "raise"})
	add_gatehouse_entry_steps(blueprint, opening_width, passage_floor_top, exterior_gate_z, variation)
	add_gatehouse_roof_deck_with_stair_hatch(blueprint, width, depth, height, foundation_height, center_z, -1.0 * (opening_width * 0.5 + pier_width * 0.5), pier_width, variation)
	add_crenellations(blueprint, "castle_gatehouse_battlement", Vector3(0.0, 0.0, center_z), width, depth, foundation_height + height + 0.50, variation)


static func add_gatehouse_threshold_composition(blueprint, opening_width: float, depth: float, height: float, foundation_height: float, center_z: float, exterior_gate_z: float, variation: float) -> void:
	var passage_height := 2.88
	var trim_depth := 0.18
	var trim_width := clampf(opening_width * 0.075, 0.30, 0.44)
	var exterior_trim_z := exterior_gate_z - 0.23
	var inner_gate_z := center_z + depth * 0.5 - 0.12
	for threshold_index in range(2):
		var threshold_z := exterior_trim_z if threshold_index == 0 else inner_gate_z
		var threshold_prefix := "outer" if threshold_index == 0 else "inner"
		for side in [-1.0, 1.0]:
			add_part(blueprint, "castle_gatehouse_%s_arch_jamb_%d" % [threshold_prefix, int(side)], "beam", "stone_foundation", Vector3(side * (opening_width * 0.5 + trim_width * 0.5), foundation_height + passage_height * 0.5, threshold_z), Vector3(trim_width, passage_height + 0.22, trim_depth), {"collision": false, "variation": variation + side * 0.006, "semantic": "castle_gatehouse_arch_trim"})
		add_part(blueprint, "castle_gatehouse_%s_arch_header" % threshold_prefix, "beam", "stone_foundation", Vector3(0.0, foundation_height + passage_height + trim_width * 0.5, threshold_z), Vector3(opening_width + trim_width * 2.0, trim_width, trim_depth), {"collision": false, "variation": variation + 0.01, "semantic": "castle_gatehouse_arch_trim"})

	# Repeated pale ribs break the deep passage into readable spatial bays. They
	# are presentation only and stay flush with the structural shell, preserving
	# the full collision-backed opening for players, NPCs, and the raised gate.
	var bay_count := clampi(roundi(depth / 2.25), 3, 5)
	for bay_index in range(1, bay_count):
		var bay_t := float(bay_index) / float(bay_count)
		var bay_z := lerpf(exterior_gate_z, center_z + depth * 0.5, bay_t)
		for side in [-1.0, 1.0]:
			add_part(blueprint, "castle_gatehouse_passage_rib_%02d_%d" % [bay_index, int(side)], "beam", "stone_foundation", Vector3(side * (opening_width * 0.5 - 0.055), foundation_height + passage_height * 0.52, bay_z), Vector3(0.11, passage_height * 0.92, 0.16), {"collision": false, "variation": variation + bay_t * 0.02, "semantic": "castle_gatehouse_passage_rib"})
		add_part(blueprint, "castle_gatehouse_passage_header_%02d" % bay_index, "beam", "timber_beam", Vector3(0.0, foundation_height + passage_height - 0.10, bay_z), Vector3(opening_width - 0.12, 0.16, 0.20), {"collision": false, "variation": variation - bay_t * 0.02, "semantic": "castle_gatehouse_passage_header"})

	# The upper gatehouse reads as occupied civic architecture rather than a
	# blank defensive slab. Window orders and a central heraldic recess derive
	# entirely from the gate span, so every generated compound receives the same
	# scalable threshold grammar.
	var upper_base_y := foundation_height + passage_height + 0.74
	var upper_height := maxf(1.2, height - passage_height - 1.10)
	var window_height := minf(1.34, upper_height * 0.52)
	var window_width := clampf(opening_width * 0.15, 0.62, 0.90)
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_gatehouse_upper_recess_%d" % int(side), "decor", "window_recess", Vector3(side * opening_width * 0.27, upper_base_y + window_height * 0.5, exterior_trim_z - 0.015), Vector3(window_width, window_height, 0.12), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_gatehouse_upper_blind_recess"})
	var panel_height := minf(1.0, upper_height * 0.40)
	# Recess the heraldic panel into the actual front lintel rather than leaving
	# a detached decal just beyond the gatehouse face.
	add_part(blueprint, "castle_gatehouse_heraldic_recess", "beam", "painted_brick_cream", Vector3(0.0, upper_base_y + panel_height * 0.5, exterior_trim_z + 0.220), Vector3(window_width * 0.72, panel_height, 0.10), {"collision": false, "variation": variation - 0.02, "semantic": "castle_gatehouse_heraldic_recess", "physicalIntent": "facade_attachment", "physicalRequiredAnchorPartIds": ["castle_gatehouse_lintel"], "physicalRequiredAnchorFacts": [{"anchorId": "castle_gatehouse_lintel", "contactMode": "attachment_socket", "localMountCenter": Vector3(0.0, 0.0, 0.045), "localMountHalfExtents": Vector3(0.025, 0.025, 0.018)}]})


static func add_gatehouse_stair_bay(blueprint, center_x: float, span: float, center_z: float, depth: float, height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	# Retain the pier's structural envelope, but hollow its centre into an
	# enclosed, courtyard-entered vertical route.  The inner wall finishes at
	# the arch edge; no stair part may cross that boundary into the main passage.
	var shell_thickness := minf(0.62, span * 0.22)
	var rear_z := center_z + depth * 0.5
	var front_z := center_z - depth * 0.5
	var wall_y := foundation_height + height * 0.5
	var door_width := clampf(span * 0.48, 1.02, 1.30)
	var door_height := minf(2.44, height - 0.40)
	var rear_side_width := (span - door_width) * 0.5
	# Preserve the historical pier id on the exterior load-bearing front face;
	# downstream shell/foundation checks still see a pier seated on the same
	# foundation while the new bay owns its usable interior.
	add_part(blueprint, "castle_gatehouse_pier_-1", "wall", masonry_material, Vector3(center_x, wall_y, front_z), Vector3(span, height, shell_thickness), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_front"})
	add_part(blueprint, "castle_gatehouse_stair_bay_outer_wall", "wall", masonry_material, Vector3(center_x - span * 0.5, wall_y, center_z), Vector3(shell_thickness, height, depth), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_wall"})
	# The inside face is exactly flush with the left edge of the central arch.
	# It therefore encloses the stair without stealing even a fraction of the
	# player-width gate route.
	add_part(blueprint, "castle_gatehouse_stair_bay_inner_wall", "wall", masonry_material, Vector3(center_x + span * 0.5 - shell_thickness * 0.5, wall_y, center_z), Vector3(shell_thickness, height, depth), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_wall"})
	for side in [-1.0, 1.0]:
		if rear_side_width > 0.08:
			add_part(blueprint, "castle_gatehouse_stair_bay_rear_%d" % int(side), "wall", masonry_material, Vector3(center_x + side * (door_width * 0.5 + rear_side_width * 0.5), foundation_height + door_height * 0.5, rear_z), Vector3(rear_side_width, door_height, shell_thickness), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_rear"})
	var rear_header_height := height - door_height
	add_part(blueprint, "castle_gatehouse_stair_bay_rear_header", "wall", masonry_material, Vector3(center_x, foundation_height + door_height + rear_header_height * 0.5, rear_z), Vector3(door_width, rear_header_height, shell_thickness), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_rear_header"})
	add_part(blueprint, "castle_gatehouse_wall_stair_door", "door", "painted_door", Vector3(center_x, foundation_height + door_height * 0.5, rear_z + shell_thickness * 0.68), Vector3(door_width - 0.14, door_height, 0.16), {"rotation": Vector3(0.0, PI, 0.0), "variation": variation - 0.03, "semantic": "castle_gatehouse_wall_stair_entry"})
	var climb_segments := clampi(ceili(height / 3.55), 2, 5)
	var stair_start: int = blueprint.parts.size()
	add_switchback_stair_flights(blueprint, "castle_gatehouse_wall_stair", Vector3(center_x, 0.0, center_z), span - shell_thickness * 2.0 - 0.08, depth - shell_thickness * 2.0 - 0.12, foundation_height + 0.20, height / float(climb_segments), climb_segments, "stone_foundation", variation, "castle_gatehouse_wall_stair")
	# The courtyard door is at +Z. Face the first full-height landing toward
	# that entrance; the half-level turn cannot provide standing headroom.
	# Rotate the complete assembly, including its seats and bearing piers.
	var stair_origin := Vector3(center_x, 0.0, center_z)
	var stair_basis := Basis(Vector3.UP, PI)
	for part_index in range(stair_start, blueprint.parts.size()):
		var part = blueprint.parts[part_index]
		part.position = stair_origin + stair_basis * (part.position - stair_origin)
		part.rotation = (stair_basis * Basis.from_euler(part.rotation)).get_euler()


static func add_gatehouse_roof_deck_with_stair_hatch(blueprint, width: float, depth: float, height: float, foundation_height: float, center_z: float, stair_center_x: float, stair_span: float, variation: float) -> void:
	# The roof is a ring around the stair bay, not a decorative solid deck that
	# would cap the last tread.  The hatch is the actual route onto the gatehouse
	# roof/wall walk and is sized from the same pier envelope as the stairs.
	var deck_y := foundation_height + height + 0.12
	var deck_width := width + 0.22
	var deck_depth := depth + 0.22
	var min_x := -deck_width * 0.5
	var max_x := deck_width * 0.5
	var min_z := center_z - deck_depth * 0.5
	var max_z := center_z + deck_depth * 0.5
	var hatch_min_x := stair_center_x - stair_span * 0.5 + 0.26
	var hatch_max_x := stair_center_x + stair_span * 0.5 - 0.26
	var hatch_min_z := center_z - depth * 0.5 + 0.48
	var hatch_max_z := center_z + depth * 0.5 - 0.48
	add_gatehouse_roof_panel(blueprint, "castle_gatehouse_roof_deck_front", min_x, max_x, min_z, hatch_min_z, deck_y, variation)
	add_gatehouse_roof_panel(blueprint, "castle_gatehouse_roof_deck_back", min_x, max_x, hatch_max_z, max_z, deck_y, variation)
	add_gatehouse_roof_panel(blueprint, "castle_gatehouse_roof_deck_hatch_outer", min_x, hatch_min_x, hatch_min_z, hatch_max_z, deck_y, variation)
	add_gatehouse_roof_panel(blueprint, "castle_gatehouse_roof_deck_hatch_inner", hatch_max_x, max_x, hatch_min_z, hatch_max_z, deck_y, variation)


static func add_gatehouse_roof_panel(blueprint, part_id: String, min_x: float, max_x: float, min_z: float, max_z: float, y: float, variation: float) -> void:
	if max_x - min_x <= 0.08 or max_z - min_z <= 0.08:
		return
	add_part(blueprint, part_id, "foundation", "stone_foundation", Vector3((min_x + max_x) * 0.5, y, (min_z + max_z) * 0.5), Vector3(max_x - min_x, 0.24, max_z - min_z), {"variation": variation, "semantic": "castle_gatehouse_roof", "navigationRole": "walkable_support"})


static func add_gatehouse_entry_steps(blueprint, opening_width: float, passage_floor_top: float, exterior_gate_z: float, variation: float) -> void:
	# The gate is a real player/NPC entry, not a decorative opening raised above
	# terrain. These shared construction parts make the exterior ground meet the
	# published courtyard floor through climbable, collision-backed stone steps.
	var step_count := 3
	var tread_depth := 0.54
	for step_index in range(step_count):
		var progress := float(step_index + 1) / float(step_count)
		var step_height := passage_floor_top * progress
		var step_z := exterior_gate_z - tread_depth * (float(step_count - step_index) - 0.5)
		add_part(blueprint, "castle_gatehouse_entry_step_%02d" % (step_index + 1), "foundation", "stone_foundation", Vector3(0.0, step_height * 0.5, step_z), Vector3(opening_width + 0.72, step_height, tread_depth + 0.03), {"variation": variation, "semantic": "castle_gatehouse_entry_step", "navigationRole": "walkable_support"})


static func add_keep(blueprint, center: Vector3, width: float, depth: float, height: float, storey_count: int, floor_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary = {}) -> bool:
	var palace_material := String(palace_grammar.get("palaceMaterial", "painted_brick_cream"))
	var enclosed_storey_count := clampi(int(palace_grammar.get("hallStoreys", 4)), 1, storey_count)
	var hall_height := minf(height, floor_height * float(enclosed_storey_count))
	add_part(blueprint, "castle_keep_foundation", "foundation", "stone_foundation", Vector3(center.x, foundation_height * 0.5, center.z), Vector3(width + 0.70, foundation_height, depth + 0.70), {"variation": variation, "semantic": "castle_keep_foundation"})
	add_part(blueprint, "castle_keep_floor", "foundation", "stone_foundation", Vector3(center.x, foundation_height + 0.10, center.z), Vector3(width - 0.40, 0.20, depth - 0.40), {"variation": variation, "semantic": "castle_keep_floor"})
	var wall_y := foundation_height + hall_height * 0.5
	var front_z := center.z - depth * 0.5
	var door_width := minf(2.30, width * 0.18)
	var civic_front_opening_width := clampf(width * float(palace_grammar.get("hallRoofCoreWidthRatio", 0.40)), 11.0, width * 0.56)
	var civic_front_opening_center_x := center.x + width * float(palace_grammar.get("hallRoofCoreOffsetXRatio", 0.0))
	var facade_left := center.x - width * 0.5
	var facade_right := center.x + width * 0.5
	var civic_left := civic_front_opening_center_x - civic_front_opening_width * 0.5
	var civic_right := civic_front_opening_center_x + civic_front_opening_width * 0.5
	var left_flank_width := civic_left - facade_left
	var right_flank_width := facade_right - civic_right
	if left_flank_width > 0.08:
		add_part(blueprint, "castle_keep_front_-1", "wall", palace_material, Vector3(facade_left + left_flank_width * 0.5, wall_y, front_z), Vector3(left_flank_width, hall_height, 0.72), {"variation": variation, "semantic": "castle_keep_wall"})
	if right_flank_width > 0.08:
		add_part(blueprint, "castle_keep_front_1", "wall", palace_material, Vector3(civic_right + right_flank_width * 0.5, wall_y, front_z), Vector3(right_flank_width, hall_height, 0.72), {"variation": variation, "semantic": "castle_keep_wall"})
	var entry_height := 2.80
	var entry_header_height := hall_height - entry_height
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_entry_jamb_%d" % int(side), "wall", masonry_material, Vector3(center.x + side * (door_width * 0.5 + 0.18), foundation_height + entry_height * 0.5, front_z), Vector3(0.36, entry_height, 0.72), {"variation": variation + side * 0.004, "semantic": "castle_keep_entry_jamb"})
	add_part(blueprint, "castle_keep_entry_header", "wall", masonry_material, Vector3(center.x, foundation_height + entry_height + entry_header_height * 0.5, front_z), Vector3(door_width, entry_header_height, 0.72), {"variation": variation, "semantic": "castle_keep_entry_header"})
	add_part(blueprint, "castle_keep_entry_door", "door", "painted_door", Vector3(center.x, foundation_height + entry_height * 0.5, front_z - 0.10), Vector3(door_width - 0.16, entry_height, 0.18), {"variation": variation - 0.03, "semantic": "castle_keep_entry"})
	for spec in [
		{"id": "back", "position": Vector3(center.x, wall_y, center.z + depth * 0.5), "size": Vector3(width, hall_height, 0.72)},
		{"id": "left", "position": Vector3(center.x - width * 0.5, wall_y, center.z), "size": Vector3(0.72, hall_height, depth)},
		{"id": "right", "position": Vector3(center.x + width * 0.5, wall_y, center.z), "size": Vector3(0.72, hall_height, depth)}
	]:
		add_part(blueprint, "castle_keep_%s" % String(spec.get("id", "wall")), "wall", palace_material, spec.get("position", Vector3.ZERO) as Vector3, spec.get("size", Vector3.ONE) as Vector3, {"variation": variation, "semantic": "castle_keep_wall"})
	var lower_roof_y := foundation_height + hall_height
	var hall_roof_rise := maxf(3.8, width * float(palace_grammar.get("hallRoofRiseRatio", 0.20)))
	# The civic core is an actual continuous structural volume around the entry,
	# not a decorative roof object. Its seeded proportions establish the keep's
	# vertical hierarchy and give every roof a visible load-bearing termination.
	var civic_core := add_keep_civic_core(blueprint, center, width, depth, hall_height, foundation_height, door_width, variation, masonry_material, palace_grammar)
	var civic_core_center: Vector3 = civic_core.get("center", center) as Vector3
	var civic_core_width := float(civic_core.get("width", width * 0.40))
	var civic_core_depth := float(civic_core.get("depth", depth * 0.46))
	var civic_core_eave_y := float(civic_core.get("eaveY", lower_roof_y + 5.6))
	var hall_roof_top := add_keep_hall_roof_grammar(blueprint, center, width, depth, lower_roof_y, hall_roof_rise, variation, civic_core_center, civic_core_width, civic_core_depth, civic_core_eave_y, palace_grammar)
	var civic_entrance := add_keep_civic_entrance_tower(blueprint, civic_core_center, civic_core_width, civic_core_depth, civic_core_eave_y, foundation_height, door_width, variation, masonry_material, palace_grammar)
	var entry_approach: Dictionary = palace_grammar.get("entryApproach", {}) as Dictionary
	add_keep_civic_front_bay_walls(blueprint, civic_core_center, civic_core_width, civic_core_depth, civic_core_eave_y, foundation_height, float(civic_entrance.get("towerWidth", civic_core_width * 0.44)), variation, masonry_material, palace_grammar)
	add_keep_civic_facade_bays(blueprint, civic_core_center, civic_core_width, civic_core_depth, civic_core_eave_y, foundation_height, float(civic_entrance.get("towerWidth", civic_core_width * 0.44)), float(civic_entrance.get("towerHeight", civic_core_eave_y - foundation_height)), float(civic_entrance.get("portalWidth", door_width + 3.0)), float(civic_entrance.get("frontZ", center.z - depth * 0.5)), variation, palace_grammar)
	add_keep_facade_articulation(blueprint, center, width, depth, hall_height, foundation_height, variation, palace_material, palace_grammar)
	add_keep_palace_wings(blueprint, center, width, depth, hall_height, foundation_height, variation, palace_material, civic_core_center, civic_core_width, civic_core_depth, civic_core_eave_y, palace_grammar)
	add_keep_palace_entry_court(blueprint, center, width, depth, foundation_height, variation, float(civic_entrance.get("portalWidth", door_width + 2.4)), door_width, float(entry_approach["portalFrontZ"]), palace_grammar)
	add_keep_palace_forecourt_galleries(blueprint, center, width, depth, foundation_height, variation, palace_material, palace_grammar)
	add_keep_palace_rear_court(blueprint, center, width, depth, hall_height, foundation_height, variation, palace_material, palace_grammar)
	var stairwell := keep_stairwell_layout(center, width, depth, blueprint.parts)
	if not stairwell.ready:
		return false
	var stair_center: Vector3 = stairwell.center
	for storey_index in range(1, enclosed_storey_count):
		add_keep_storey_floor_with_stairwell(blueprint, storey_index, center, width, depth, stair_center, stairwell.width, stairwell.depth, foundation_height, floor_height, variation)
	add_switchback_stair_flights(blueprint, "castle_keep_stair", stair_center, stairwell.width, stairwell.depth, foundation_height + 0.20, floor_height, maxi(1, enclosed_storey_count - 1), "stone_foundation", variation, "castle_keep_stair")
	add_part(blueprint, "castle_keep_banner", "sign", "painted_decor", Vector3(center.x, foundation_height + height * 0.64, front_z - 0.42), Vector3(1.46, 2.60, 0.10), {"variation": variation, "collision": false, "semantic": "castle_banner"})
	return true


static func add_keep_civic_core(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, door_width: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> Dictionary:
	var core_width := clampf(width * float(palace_grammar.get("hallRoofCoreWidthRatio", 0.40)), 11.0, width * 0.56)
	var core_depth := clampf(depth * float(palace_grammar.get("hallRoofCoreDepthRatio", 0.46)), 9.0, depth * 0.62)
	var front_z := center.z - depth * 0.5 - 0.04
	var core_center := Vector3(center.x + width * float(palace_grammar.get("hallRoofCoreOffsetXRatio", 0.0)), 0.0, front_z + core_depth * 0.5)
	var core_height := hall_height + clampf(float(palace_grammar.get("hallRoofCoreHeightAdd", 6.0)), 3.8, 8.8)
	var core_side_width := maxf(1.40, (core_width - door_width - 0.46) * 0.5)
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_civic_core_side_%d" % int(side), "wall", masonry_material, Vector3(core_center.x + side * core_width * 0.5, foundation_height + core_height * 0.5, core_center.z), Vector3(0.82, core_height, core_depth), {"variation": variation + side * 0.008, "semantic": "castle_keep_civic_core"})
	add_part(blueprint, "castle_keep_civic_core_back", "wall", masonry_material, Vector3(core_center.x, foundation_height + core_height * 0.5, front_z + core_depth), Vector3(core_width, core_height, 0.82), {"variation": variation + 0.01, "semantic": "castle_keep_civic_core"})
	var core_header_height := core_height - 2.80
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_civic_core_entry_jamb_%d" % int(side), "wall", masonry_material, Vector3(core_center.x + side * (door_width * 0.5 + 0.28), foundation_height + 1.40, front_z), Vector3(0.56, 2.80, 0.82), {"variation": variation + side * 0.006, "semantic": "castle_keep_civic_core_entry_jamb"})
	add_part(blueprint, "castle_keep_civic_core_entry_header", "wall", masonry_material, Vector3(core_center.x, foundation_height + 2.80 + core_header_height * 0.5, front_z), Vector3(door_width + 0.46, core_header_height, 0.82), {"variation": variation - 0.01, "semantic": "castle_keep_civic_core_entry"})
	return {"center": core_center, "width": core_width, "depth": core_depth, "eaveY": foundation_height + core_height}


static func add_keep_civic_entrance_tower(blueprint, core_center: Vector3, core_width: float, core_depth: float, core_eave_y: float, foundation_height: float, door_width: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> Dictionary:
	var tower_width := clampf(core_width * float(palace_grammar.get("entranceTowerWidthRatio", 0.44)), door_width + 5.0, core_width * 0.62)
	var tower_depth := clampf(core_depth * float(palace_grammar.get("entranceTowerDepthRatio", 0.11)), 4.6, 8.8)
	var core_front_z := core_center.z - core_depth * 0.5
	var tower_front_z := core_front_z - tower_depth
	var tower_center_z := core_front_z - tower_depth * 0.5
	var tower_height := core_eave_y - foundation_height + clampf(float(palace_grammar.get("entranceTowerHeightAdd", 2.4)), 1.0, 4.0)
	var portal_width := clampf(tower_width * float(palace_grammar.get("entrancePortalWidthRatio", 0.54)), door_width + 3.0, tower_width - 2.40)
	var portal_height := clampf(tower_height * float(palace_grammar.get("entrancePortalHeightRatio", 0.56)), 6.0, tower_height - 2.20)
	var side_width := maxf(1.65, (tower_width - portal_width) * 0.5)
	var vestibule_width := maxf(1.20, portal_width - 0.20)
	var vestibule_min_z := tower_front_z - 0.02
	var vestibule_max_z := core_front_z + 0.08
	var vestibule_depth := vestibule_max_z - vestibule_min_z
	var vestibule_root_height := maxf(0.12, foundation_height - 0.20)
	var vestibule_root_id := "castle_keep_palace_entry_vestibule_root"
	add_part(blueprint, vestibule_root_id, "foundation", "stone_foundation", Vector3(core_center.x, vestibule_root_height * 0.5, (vestibule_min_z + vestibule_max_z) * 0.5), Vector3(vestibule_width, vestibule_root_height, vestibule_depth), {"variation": variation - 0.038, "semantic": "castle_keep_palace_entry_vestibule_root", "physicalIntent": "structural_root", "physicalRoot": true})
	var vestibule := add_part(blueprint, "castle_keep_palace_entry_vestibule", "foundation", "stone_foundation", Vector3(core_center.x, vestibule_root_height + 0.10, (vestibule_min_z + vestibule_max_z) * 0.5), Vector3(vestibule_width, 0.20, vestibule_depth), {"variation": variation - 0.039, "semantic": "castle_keep_palace_entry_vestibule", "navigationRole": "transition", "physicalIntent": "walkable_surface"})
	vestibule.recipe["physicalRequiredSupportPartIds"] = [vestibule_root_id]
	var threshold_depth := 0.72
	var threshold := add_part(blueprint, "castle_keep_palace_entry_threshold", "foundation", "stone_foundation", Vector3(core_center.x, foundation_height + 0.10, core_front_z + threshold_depth * 0.5 - 0.02), Vector3(vestibule_width, 0.20, threshold_depth), {"variation": variation - 0.040, "semantic": "castle_keep_palace_entry_threshold", "navigationRole": "transition", "physicalIntent": "walkable_surface"})
	threshold.recipe["physicalRequiredSupportPartIds"] = ["castle_keep_palace_entry_vestibule"]
	for side in [-1.0, 1.0]:
		var side_x: float = core_center.x + side * (portal_width * 0.5 + side_width * 0.5)
		add_part(blueprint, "castle_keep_civic_entrance_tower_side_%d" % int(side), "wall", masonry_material, Vector3(side_x, foundation_height + tower_height * 0.5, tower_center_z), Vector3(side_width, tower_height, tower_depth), {"variation": variation + side * 0.008, "semantic": "castle_keep_civic_entrance_tower"})
	var header_height := tower_height - portal_height
	add_part(blueprint, "castle_keep_civic_entrance_tower_header", "wall", masonry_material, Vector3(core_center.x, foundation_height + portal_height + header_height * 0.5, tower_front_z), Vector3(portal_width, header_height, 0.82), {"variation": variation - 0.01, "semantic": "castle_keep_civic_entrance_tower"})
	var pier_height := portal_height - 0.04
	var pier_ids: Array[String] = []
	for side in [-1.0, 1.0]:
		var pier_id := "castle_keep_civic_entrance_tower_pier_%d" % int(side)
		var footing_id := "%s_footing" % pier_id
		pier_ids.append(pier_id)
		var pier_center := Vector3(core_center.x + side * (portal_width * 0.5 + 0.16), foundation_height + pier_height * 0.5, tower_front_z - 0.10)
		add_part(blueprint, footing_id, "foundation", "stone_foundation", Vector3(pier_center.x, foundation_height * 0.5, pier_center.z), Vector3(0.56, foundation_height, 0.62), {"variation": variation - 0.034, "semantic": "castle_keep_civic_entrance_portal_footing", "physicalIntent": "structural_root"})
		add_part(blueprint, pier_id, "beam", "stone_foundation", pier_center, Vector3(0.32, pier_height, 0.36), {"variation": variation - 0.03, "semantic": "castle_keep_civic_entrance_portal", "physicalRequiredSeatPartIds": [footing_id], "physicalRequiredSeatFacts": [{"seatId": footing_id, "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -pier_height * 0.5, 0.0), "localPatchHalfExtents": Vector2(0.10, 0.10), "seatFace": "max_y"}]})
	var lintel := add_part(blueprint, "castle_keep_civic_entrance_tower_lintel", "beam", "stone_foundation", Vector3(core_center.x, foundation_height + portal_height + 0.16, tower_front_z - 0.10), Vector3(portal_width + 0.72, 0.40, 0.38), {"variation": variation - 0.03, "semantic": "castle_keep_civic_entrance_portal"})
	lintel.recipe["physicalRequiredSeatPartIds"] = pier_ids
	lintel.recipe["physicalRequiredSeatFacts"] = [
		{"seatId": pier_ids[0], "loadDirection": "world_down", "localPatchCenter": Vector3(-(portal_width * 0.5 + 0.16), -0.20, 0.0), "localPatchHalfExtents": Vector2(0.10, 0.10), "seatFace": "max_y"},
		{"seatId": pier_ids[1], "loadDirection": "world_down", "localPatchCenter": Vector3(portal_width * 0.5 + 0.16, -0.20, 0.0), "localPatchHalfExtents": Vector2(0.10, 0.10), "seatFace": "max_y"}
	]
	for arch_course in range(3):
		var arch_progress := float(arch_course + 1) / 3.0
		var arch_width := portal_width + 0.62 - arch_progress * 0.88
		var arch_y := foundation_height + portal_height + 0.46 + float(arch_course) * 0.38
		add_part(blueprint, "castle_keep_civic_entrance_tower_arch_%02d" % arch_course, "beam", "stone_foundation", Vector3(core_center.x, arch_y, tower_front_z - 0.13), Vector3(arch_width, 0.26, 0.34), {"variation": variation - 0.026 + float(arch_course) * 0.003, "semantic": "castle_keep_civic_entrance_arch"})
	for level in range(2):
		var window_y := foundation_height + portal_height + 1.56 + float(level) * 2.72
		if window_y < foundation_height + tower_height - 1.20:
			add_part(blueprint, "castle_keep_civic_entrance_tower_recess_%02d" % level, "decor", "window_recess", Vector3(core_center.x, window_y, tower_front_z - 0.08), Vector3(1.12, 1.34, 0.12), {"collision": false, "variation": variation + float(level) * 0.006, "semantic": "castle_keep_civic_entrance_blind_recess"})
	# The entrance roof terminates on visible eave caps, not directly on the
	# broad portal sidewalls. This keeps the roof plates fully seated at every
	# procedural scale while reading as a deliberate stone course.
	var eave_cap_height := 0.20
	var eave_cap_ids: Array[String] = []
	for side in [-1.0, 1.0]:
		var cap_id := "castle_keep_civic_entrance_tower_eave_cap_%d" % int(side)
		eave_cap_ids.append(cap_id)
		add_part(blueprint, cap_id, "beam", "stone_foundation", Vector3(core_center.x + side * (tower_width * 0.5 - 0.15), foundation_height + tower_height + eave_cap_height * 0.5, tower_center_z), Vector3(0.52, eave_cap_height, tower_depth), {"variation": variation - 0.018 + side * 0.004, "semantic": "castle_keep_civic_entrance_eave_cap", "physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": ["castle_keep_civic_entrance_tower_side_%d" % int(side)], "physicalRequiredSeatFacts": [{"seatId": "castle_keep_civic_entrance_tower_side_%d" % int(side), "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -eave_cap_height * 0.5, 0.0), "localPatchHalfExtents": Vector2(0.08, minf(tower_depth * 0.34, 1.30)), "seatFace": "max_y"}]})
	var roof_rise := clampf(float(palace_grammar.get("entranceTowerRoofRise", 4.4)), 3.0, 6.2)
	add_keep_gabled_roof(blueprint, "castle_keep_civic_entrance_tower_roof", Vector3(core_center.x, 0.0, tower_center_z), tower_width + 0.22, tower_depth + 0.22, foundation_height + tower_height + eave_cap_height, roof_rise, variation - 0.008, eave_cap_ids)
	return {"portalWidth": portal_width, "frontZ": tower_front_z, "towerWidth": tower_width, "towerHeight": tower_height}


static func add_keep_civic_front_bay_walls(blueprint, core_center: Vector3, core_width: float, core_depth: float, core_eave_y: float, foundation_height: float, tower_width: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var facade_bay_count := clampi(int(palace_grammar.get("facadeBayCount", 3)), 2, 4)
	var window_level_count := clampi(int(palace_grammar.get("facadeWindowLevelCount", 2)), 2, 3)
	var core_front_z := core_center.z - core_depth * 0.5
	var core_height := core_eave_y - foundation_height
	var core_room_id := "castle_keep_civic_core_interior"
	var core_room_inset := 0.42
	var core_room := {"id": core_room_id, "role": "civic_hall", "interiorProgramOnly": true,
		"bounds": AABB(Vector3(core_center.x - core_width * 0.5 + core_room_inset, foundation_height + 0.10, core_center.z - core_depth * 0.5 + core_room_inset),
			Vector3(core_width - core_room_inset * 2.0, core_height - 0.20, core_depth - core_room_inset * 2.0)),
		"wallMountInset": 0.22, "accesses": []}
	var core_window_wall_offset := core_room_inset + 0.03
	var flank_span := maxf(3.2, (core_width - tower_width) * 0.5)
	for side in [-1.0, 1.0]:
		var flank_min_x: float = core_center.x - core_width * 0.5 if side < 0.0 else core_center.x + tower_width * 0.5
		var bay_width := flank_span / float(facade_bay_count)
		for bay_index in range(facade_bay_count):
			var bay_min_x := flank_min_x + float(bay_index) * bay_width
			var bay_center_x := bay_min_x + bay_width * 0.5
			var window_width := minf(1.34, bay_width * 0.42)
			var cursor_y := foundation_height
			for level in range(window_level_count):
				var window_y := foundation_height + 2.25 + float(level) * 3.10
				var opening_bottom := window_y - 0.71
				var opening_top := window_y + 0.71
				if opening_top >= core_eave_y - 1.30:
					continue
				if opening_bottom > cursor_y + 0.04:
					add_part(blueprint, "castle_keep_civic_core_front_%d_%02d_band_%02d" % [int(side), bay_index, level], "wall", masonry_material, Vector3(bay_center_x, (cursor_y + opening_bottom) * 0.5, core_front_z), Vector3(bay_width, opening_bottom - cursor_y, 0.82), {"variation": variation + side * 0.006, "semantic": "castle_keep_civic_core_front", "supportingWall": "castle_keep_civic_core_front_%d" % int(side)})
				var jamb_width := maxf(0.18, (bay_width - window_width) * 0.5)
				add_part(blueprint, "castle_keep_civic_core_front_%d_%02d_jamb_left_%02d" % [int(side), bay_index, level], "wall", masonry_material, Vector3(bay_min_x + jamb_width * 0.5, window_y, core_front_z), Vector3(jamb_width, 1.42, 0.82), {"variation": variation + side * 0.006, "semantic": "castle_keep_civic_window_jamb", "supportingWall": "castle_keep_civic_core_front_%d" % int(side)})
				add_part(blueprint, "castle_keep_civic_core_front_%d_%02d_jamb_right_%02d" % [int(side), bay_index, level], "wall", masonry_material, Vector3(bay_min_x + bay_width - jamb_width * 0.5, window_y, core_front_z), Vector3(jamb_width, 1.42, 0.82), {"variation": variation + side * 0.006, "semantic": "castle_keep_civic_window_jamb", "supportingWall": "castle_keep_civic_core_front_%d" % int(side)})
				add_part(blueprint, "castle_keep_civic_facade_window_%d_%02d_%02d" % [int(side), level, bay_index], "window", "window_glass", Vector3(bay_center_x, window_y, core_front_z - 0.03), Vector3(window_width, 1.42, 0.12), {"collision": false, "variation": variation + float(level) * 0.006 + side * 0.004, "semantic": "castle_keep_civic_facade_window", "supportingWall": "castle_keep_civic_core_front_%d" % int(side), "openingBacked": true, "roomId": core_room_id, "interiorProgramRoom": core_room, "interiorInwardDirection": Vector3.BACK, "interiorWallOffset": core_window_wall_offset})
				cursor_y = opening_top
			if core_eave_y > cursor_y + 0.04:
				add_part(blueprint, "castle_keep_civic_core_front_%d_%02d_top" % [int(side), bay_index], "wall", masonry_material, Vector3(bay_center_x, (cursor_y + core_eave_y) * 0.5, core_front_z), Vector3(bay_width, core_eave_y - cursor_y, 0.82), {"variation": variation + side * 0.006, "semantic": "castle_keep_civic_core_front", "supportingWall": "castle_keep_civic_core_front_%d" % int(side)})


static func add_keep_civic_facade_bays(blueprint, core_center: Vector3, core_width: float, core_depth: float, core_eave_y: float, foundation_height: float, tower_width: float, tower_height: float, portal_width: float, tower_front_z: float, variation: float, palace_grammar: Dictionary) -> void:
	var core_front_z := core_center.z - core_depth * 0.5 - 0.46
	var facade_bay_count := clampi(int(palace_grammar.get("facadeBayCount", 3)), 2, 4)
	var window_level_count := clampi(int(palace_grammar.get("facadeWindowLevelCount", 2)), 2, 3)
	var course_count := clampi(int(palace_grammar.get("facadeStringCourseCount", 2)), 2, 3)
	var flank_span := maxf(3.2, (core_width - tower_width) * 0.5)
	for side in [-1.0, 1.0]:
		var flank_center_x: float = core_center.x + side * (tower_width * 0.5 + flank_span * 0.5)
		for bay_index in range(facade_bay_count + 1):
			var bay_t := float(bay_index) / float(facade_bay_count)
			var pier_x: float = flank_center_x + side * (bay_t - 0.5) * flank_span
			add_part(blueprint, "castle_keep_civic_facade_pilaster_%d_%02d" % [int(side), bay_index], "beam", "stone_foundation", Vector3(pier_x, foundation_height + (core_eave_y - foundation_height) * 0.42, core_front_z), Vector3(0.46, (core_eave_y - foundation_height) * 0.84, 0.34), {"variation": variation - 0.022 + side * 0.004, "semantic": "castle_keep_civic_facade_pilaster", "supportingWall": "castle_keep_civic_core_front_%d" % int(side)})
		for course_index in range(course_count):
			var course_t := float(course_index + 1) / float(course_count + 1)
			var course_y := foundation_height + (core_eave_y - foundation_height) * course_t
			var anchor_ids := [
				"castle_keep_civic_facade_pilaster_%d_%02d" % [int(side), 0],
				"castle_keep_civic_facade_pilaster_%d_%02d" % [int(side), facade_bay_count]
			]
			add_part(blueprint, "castle_keep_civic_facade_course_%d_%02d" % [int(side), course_index], "beam", "stone_foundation", Vector3(flank_center_x, course_y, core_front_z - 0.05), Vector3(flank_span + 0.24, 0.28, 0.30), {"collision": false, "variation": variation - 0.028 + float(course_index) * 0.004, "semantic": "castle_keep_civic_facade_course", "physicalIntent": "facade_attachment", "physicalRequiredAnchorPartIds": anchor_ids, "supportingWall": anchor_ids[0]})
	var portal_top := foundation_height + tower_height * float(palace_grammar.get("entrancePortalHeightRatio", 0.56))
	for course_index in range(course_count):
		var course_y := portal_top + 0.72 + float(course_index) * 0.58
		if course_y < foundation_height + tower_height - 0.74:
			add_part(blueprint, "castle_keep_civic_entrance_course_%02d" % course_index, "beam", "stone_foundation", Vector3(core_center.x, course_y, tower_front_z - 0.16), Vector3(portal_width + 0.84 - float(course_index) * 0.18, 0.24, 0.30), {"variation": variation - 0.026 + float(course_index) * 0.003, "semantic": "castle_keep_civic_entrance_course", "supportingWall": "castle_keep_civic_entrance_tower_header"})


static func add_keep_hall_roof_grammar(blueprint, center: Vector3, width: float, depth: float, hall_eave_y: float, rise: float, variation: float, core_center: Vector3, core_width: float, core_depth: float, core_eave_y: float, palace_grammar: Dictionary) -> float:
	var roof_family := String(palace_grammar.get("hallRoofFamily", "terraced_crown"))
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	var core_rise := maxf(2.8, rise * 0.64)
	add_keep_gabled_roof(blueprint, "castle_keep_civic_core_roof", core_center, core_width + 0.26, core_depth + 0.26, core_eave_y, core_rise, variation + 0.006, ["castle_keep_civic_core_side_-1", "castle_keep_civic_core_side_1"])
	var highest_top := core_eave_y + core_rise
	var pavilion_width := clampf(width * float(palace_grammar.get("hallRoofPavilionWidthRatio", 0.22)), 5.4, width * 0.31)
	var pavilion_depth := clampf(depth * float(palace_grammar.get("hallRoofPavilionDepthRatio", 0.34)), 5.0, depth * 0.46)
	var pavilion_z := center.z - depth * (0.20 if roof_family == "court_pavilions" else 0.13)
	for side in [-1.0, 1.0]:
		var is_dominant: bool = side == dominant_side
		var pavilion_height := float(palace_grammar.get("hallRoofDominantPavilionHeight", 3.4)) if is_dominant else float(palace_grammar.get("hallRoofSecondaryPavilionHeight", 1.8))
		if roof_family == "terraced_crown":
			pavilion_height = lerpf(pavilion_height, core_rise * 0.42, 0.55)
		var pavilion_x: float = center.x + side * (width * 0.5 - pavilion_width * 0.64)
		var resolved_pavilion_z: float = pavilion_z + (depth * 0.11 * side if roof_family == "court_pavilions" else 0.0)
		var pavilion_center := Vector3(pavilion_x, 0.0, resolved_pavilion_z)
		var pavilion_id := "castle_keep_hall_roof_pavilion_%d" % int(side)
		var pavilion_drum_id := "%s_masonry_drum" % pavilion_id
		add_part(blueprint, pavilion_drum_id, "foundation", "stone_foundation", Vector3(pavilion_center.x, hall_eave_y * 0.5, pavilion_center.z), Vector3(pavilion_width * 0.62, hall_eave_y, pavilion_depth * 0.62), {"variation": variation + side * 0.006, "semantic": "castle_keep_pavilion_masonry_drum", "physicalIntent": "structural_root"})
		add_part(blueprint, pavilion_id, "wall", "stone_foundation", Vector3(pavilion_center.x, hall_eave_y + pavilion_height * 0.5, pavilion_center.z), Vector3(pavilion_width, pavilion_height, pavilion_depth), {"variation": variation + side * 0.012, "semantic": "castle_keep_roof_pavilion", "physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": [pavilion_drum_id], "physicalRequiredSeatFacts": [{"seatId": pavilion_drum_id, "loadDirection": "world_down", "seatFace": "max_y", "localPatchCenter": Vector3(0.0, -pavilion_height * 0.5, 0.0), "localPatchHalfExtents": Vector2(pavilion_width * 0.20, pavilion_depth * 0.20)}]})
		var pavilion_rise := maxf(1.9, pavilion_width * (0.32 if is_dominant else 0.26))
		add_keep_gabled_roof(blueprint, pavilion_id, pavilion_center, pavilion_width + 0.20, pavilion_depth + 0.20, hall_eave_y + pavilion_height, pavilion_rise, variation + side * 0.012, [pavilion_id, pavilion_id])
		highest_top = maxf(highest_top, hall_eave_y + pavilion_height + pavilion_rise)
	return highest_top


static func add_keep_palace_central_hierarchy(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var front_z := center.z - depth * 0.5
	var bay_width := width * float(palace_grammar.get("entranceBayWidthRatio", 0.25))
	var bay_depth := depth * float(palace_grammar.get("entranceBayDepthRatio", 0.09))
	var bay_height := hall_height * float(palace_grammar.get("entranceBayHeightRatio", 0.82))
	var bay_center := Vector3(center.x, 0.0, front_z - bay_depth * 0.5)
	var portal_width := minf(2.30, width * 0.18) + 0.34
	var portal_height := 3.18
	var bay_side_width := maxf(0.80, (bay_width - portal_width) * 0.5)
	for side in [-1.0, 1.0]:
		var bay_side_x: float = center.x + side * (portal_width * 0.5 + bay_side_width * 0.5)
		add_part(blueprint, "castle_keep_palace_entrance_bay_side_%d" % int(side), "wall", masonry_material, Vector3(bay_side_x, foundation_height + bay_height * 0.5, bay_center.z), Vector3(bay_side_width, bay_height, bay_depth), {"variation": variation - 0.006 + side * 0.004, "semantic": "castle_keep_palace_entrance_bay"})
	var bay_header_height := bay_height - portal_height
	add_part(blueprint, "castle_keep_palace_entrance_bay_header", "wall", masonry_material, Vector3(center.x, foundation_height + portal_height + bay_header_height * 0.5, bay_center.z), Vector3(portal_width, bay_header_height, bay_depth), {"variation": variation - 0.006, "semantic": "castle_keep_palace_entrance_bay_header"})
	var portal_face_z := front_z - bay_depth - 0.08
	add_part(blueprint, "castle_keep_palace_entrance_recess_header", "beam", "stone_foundation", Vector3(center.x, foundation_height + portal_height + 0.18, portal_face_z), Vector3(portal_width + 0.72, 0.42, 0.32), {"variation": variation - 0.03, "semantic": "castle_keep_palace_entrance_recess"})
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_palace_entrance_recess_pier_%d" % int(side), "beam", "stone_foundation", Vector3(center.x + side * (portal_width * 0.5 + 0.18), foundation_height + portal_height * 0.48, portal_face_z), Vector3(0.36, portal_height * 0.96, 0.32), {"variation": variation - 0.03, "semantic": "castle_keep_palace_entrance_recess"})
	var flank_step := width * float(palace_grammar.get("entranceFlankStepRatio", 0.12))
	for side in [-1.0, 1.0]:
		var flank_width := maxf(2.8, flank_step)
		var flank_height := bay_height * (0.82 if side < 0.0 else 0.74)
		var flank_depth := bay_depth * (0.72 if side < 0.0 else 0.56)
		var flank_center := Vector3(center.x + side * (bay_width * 0.5 + flank_width * 0.5 - 0.18), 0.0, front_z - flank_depth * 0.5)
		add_part(blueprint, "castle_keep_palace_entrance_flank_%d" % int(side), "wall", masonry_material, Vector3(flank_center.x, foundation_height + flank_height * 0.5, flank_center.z), Vector3(flank_width, flank_height, flank_depth), {"variation": variation + side * 0.008, "semantic": "castle_keep_palace_entrance_flank"})
		add_part(blueprint, "castle_keep_palace_entrance_flank_cornice_%d" % int(side), "beam", "stone_foundation", Vector3(flank_center.x, foundation_height + flank_height * 0.82, flank_center.z - flank_depth * 0.5 - 0.06), Vector3(flank_width * 0.82, 0.30, 0.26), {"variation": variation - 0.02, "semantic": "castle_keep_palace_entrance_order"})
	var root_width := width * float(palace_grammar.get("rotundaRootWidthRatio", 0.28))
	var root_depth := depth * float(palace_grammar.get("rotundaRootProjectionRatio", 0.06))
	var root_height := hall_height * 0.54
	var root_center := Vector3(center.x, foundation_height + hall_height - root_height * 0.5, front_z - root_depth * 0.5 - bay_depth * 0.18)
	add_part(blueprint, "castle_keep_palace_rotunda_root", "wall", masonry_material, root_center, Vector3(root_width, root_height, root_depth), {"variation": variation + 0.005, "semantic": "castle_keep_palace_rotunda_root"})
	var order_levels := 3
	for level in range(order_levels):
		var order_y := foundation_height + portal_height + 1.10 + float(level) * minf(2.55, hall_height * 0.19)
		for bay in [-1.0, 0.0, 1.0]:
			var order_x: float = center.x + bay * bay_width * 0.25
			add_part(blueprint, "castle_keep_palace_entrance_window_%02d_%d" % [level, int(bay)], "window", "window_glass", Vector3(order_x, order_y, front_z - bay_depth - 0.055), Vector3(bay_width * 0.15, 1.34 + float(level) * 0.08, 0.12), {"collision": false, "variation": variation + float(level) * 0.004, "semantic": "castle_keep_palace_entrance_window"})
		add_part(blueprint, "castle_keep_palace_entrance_order_%02d" % level, "beam", "stone_foundation", Vector3(center.x, order_y + 0.88, front_z - bay_depth - 0.04), Vector3(bay_width * 0.88, 0.26, 0.24), {"variation": variation - 0.02, "semantic": "castle_keep_palace_entrance_order"})
	add_part(blueprint, "castle_keep_palace_entrance_cornice", "beam", "stone_foundation", Vector3(center.x, foundation_height + bay_height - 0.28, front_z - bay_depth - 0.05), Vector3(bay_width + 0.72, 0.56, 0.34), {"variation": variation - 0.03, "semantic": "castle_keep_palace_entrance_cornice"})


static func add_keep_gabled_roof(blueprint, prefix: String, center: Vector3, width: float, depth: float, eave_y: float, rise: float, variation: float, eave_bearing_part_ids: Array, align_eave_plates_to_bearers := false) -> void:
	GabledRoofFrameBuilderScript.add_gabled_roof_frame(blueprint, {
		"prefix": prefix,
		"center": center,
		"width": width,
		"depth": depth,
		"eaveY": eave_y,
		"rise": rise,
		"overhang": 0.72,
		"variation": variation,
		"wallMaterial": "stone_foundation",
		"beamMaterial": "timber_beam",
		"roofSemantic": "castle_keep_roof",
		"gableSemantic": "castle_keep_roof_gable",
		"eaveBearingPartIds": eave_bearing_part_ids,
		"alignEavePlatesToBearers": align_eave_plates_to_bearers,
		"gableIdStyle": "castle",
		"gableStripCount": 7
	})


static func add_keep_facade_articulation(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var front_z := center.z - depth * 0.5 - 0.58
	var tower_span := clampf(width * float(palace_grammar.get("frontTowerSpanRatio", 0.18)), 4.6, 6.4)
	var tower_height := hall_height + clampf(hall_height * 0.16, 2.4, 4.2)
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	for side in [-1.0, 1.0]:
		var resolved_tower_height := tower_height + (float(palace_grammar.get("frontTowerDominantHeight", 3.4)) if side == dominant_side else float(palace_grammar.get("frontTowerSecondaryHeight", -1.8)))
		var tower_center := Vector3(center.x + side * (width * 0.5 - tower_span * 0.42), 0.0, front_z + tower_span * 0.34)
		add_part(blueprint, "castle_keep_front_tower_%d" % int(side), "wall", masonry_material, Vector3(tower_center.x, foundation_height + resolved_tower_height * 0.5, tower_center.z), Vector3(tower_span, resolved_tower_height, tower_span), {"variation": variation + side * 0.01, "semantic": "castle_keep_tower"})
		var tower_id := "castle_keep_front_tower_%d" % int(side)
		add_keep_gabled_roof(blueprint, "castle_keep_front_tower_roof_%d" % int(side), tower_center, tower_span, tower_span, foundation_height + resolved_tower_height, tower_span * 0.62, variation + side * 0.01, [tower_id, tower_id])
	var bay_count := maxi(2, floori(width / 9.0))
	for bay in range(1, bay_count):
		var x := lerpf(center.x - width * 0.5, center.x + width * 0.5, float(bay) / float(bay_count))
		if absf(x - center.x) < maxf(2.4, width * 0.08):
			continue
		add_part(blueprint, "castle_keep_front_buttress_%02d" % bay, "wall", "stone_foundation", Vector3(x, foundation_height + hall_height * 0.30, front_z - 0.12), Vector3(0.72, hall_height * 0.60, 1.14), {"variation": variation - 0.03, "semantic": "castle_keep_buttress"})
	for wear_side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_entry_damp_%d" % int(wear_side), "ground_patch", "drainage_stain", Vector3(center.x + wear_side * 2.05, foundation_height + 1.02, front_z - 0.74), Vector3(1.10, 0.02, 1.72), {"rotation": Vector3(PI * 0.5, 0.0, 0.0), "collision": false, "variation": variation - 0.05 + wear_side * 0.008, "semantic": "castle_keep_entry_weathering"})
		add_part(blueprint, "castle_keep_entry_growth_%d" % int(wear_side), "ground_patch", "wall_growth", Vector3(center.x + wear_side * 2.62, foundation_height + 0.42, front_z - 0.76), Vector3(0.72, 0.02, 0.58), {"rotation": Vector3(PI * 0.5, 0.0, 0.0), "collision": false, "variation": variation - 0.04, "semantic": "castle_keep_entry_weathering"})


static func add_keep_palace_wings(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, masonry_material: String, core_center: Vector3, core_width: float, core_depth: float, core_eave_y: float, palace_grammar: Dictionary) -> void:
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	var core_front_z := core_center.z - core_depth * 0.5
	var core_back_z := core_center.z + core_depth * 0.5
	var wing_front_z := core_front_z + core_depth * 0.46
	var rear_limit_z := center.z + depth * 0.5 - 3.8
	var available_depth := maxf(12.0, rear_limit_z - wing_front_z)
	var requested_depth := depth * clampf(float(palace_grammar.get("wingDepthRatio", 0.68)) * 0.56, 0.28, 0.42)
	var base_wing_depth := minf(requested_depth, available_depth)
	var side_clearance := maxf(5.8, width * 0.5 - core_width * 0.5)
	var base_wing_width := minf(width * clampf(float(palace_grammar.get("wingWidthRatio", 0.68)) * 0.38, 0.20, 0.28), side_clearance - 0.60)
	for side in [-1.0, 1.0]:
		var is_dominant: bool = side == dominant_side
		var depth_bias := float(palace_grammar.get("dominantWingDepthBias", 0.0)) if is_dominant else float(palace_grammar.get("secondaryWingDepthBias", 0.0))
		var wing_depth := clampf(base_wing_depth * (1.0 + depth_bias), 10.0, available_depth)
		var wing_width := clampf(base_wing_width * (1.04 if is_dominant else 0.88), 5.4, side_clearance - 0.30)
		var wing_height := minf(hall_height * clampf(float(palace_grammar.get("wingHeightRatio", 0.74)) * 0.72, 0.42, 0.60), core_eave_y - foundation_height - 3.20)
		var wing_x: float = core_center.x + side * (core_width * 0.5 + wing_width * 0.5 + 0.06)
		var wing_center := Vector3(wing_x, 0.0, wing_front_z + wing_depth * 0.5)
		var wing_room_id := "castle_keep_palace_wing_interior_%d" % int(side)
		var wing_room_inset := 0.42
		var wing_room := {"id": wing_room_id, "role": "palace_wing", "interiorProgramOnly": true,
			"bounds": AABB(Vector3(wing_center.x - wing_width * 0.5 + wing_room_inset, foundation_height + 0.10, wing_center.z - wing_depth * 0.5 + wing_room_inset),
				Vector3(wing_width - wing_room_inset * 2.0, wing_height - 0.20, wing_depth - wing_room_inset * 2.0)),
			"wallMountInset": 0.22, "accesses": []}
		add_part(blueprint, "castle_keep_palace_wing_%d" % int(side), "wall", masonry_material, Vector3(wing_center.x, foundation_height + wing_height * 0.5, wing_center.z), Vector3(wing_width, wing_height, wing_depth), {"variation": variation + side * 0.012, "semantic": "castle_keep_palace_wing"})
		var wing_rise := minf(maxf(2.0, wing_width * 0.26), core_eave_y - (foundation_height + wing_height) - 0.80)
		var wing_id := "castle_keep_palace_wing_%d" % int(side)
		add_keep_gabled_roof(blueprint, "castle_keep_palace_wing_roof_%d" % int(side), wing_center, wing_width + 0.18, wing_depth + 0.18, foundation_height + wing_height, wing_rise, variation + side * 0.012, [wing_id, wing_id])
		var outer_face_x: float = wing_center.x + side * (wing_width * 0.5 + 0.12)
		var bay_count := maxi(2, roundi(wing_depth / 8.0))
		for bay in range(bay_count):
			var bay_z := wing_center.z + lerpf(-wing_depth * 0.30, wing_depth * 0.30, float(bay) / float(maxi(1, bay_count - 1)))
			add_part(blueprint, "castle_keep_palace_wing_outer_pier_%d_%02d" % [int(side), bay], "wall", "stone_foundation", Vector3(outer_face_x, foundation_height + wing_height * 0.34, bay_z), Vector3(0.38, wing_height * 0.68, 0.56), {"variation": variation - 0.02, "semantic": "castle_keep_palace_wing_outer_bay"})
			for level in range(2):
				var window_y := foundation_height + 2.0 + float(level) * minf(2.8, wing_height * 0.36)
				if window_y < foundation_height + wing_height - 0.70:
					add_part(blueprint, "castle_keep_palace_wing_outer_window_%d_%02d_%02d" % [int(side), level, bay], "window", "window_glass", Vector3(outer_face_x + side * 0.14, window_y, bay_z), Vector3(0.12, 1.24, 0.82), {"collision": false, "variation": variation, "semantic": "castle_keep_palace_window", "roomId": wing_room_id, "interiorProgramRoom": wing_room, "interiorInwardDirection": Vector3(-side, 0.0, 0.0), "interiorWallOffset": wing_room_inset + 0.26})
		add_part(blueprint, "castle_keep_palace_wing_outer_cornice_%d" % int(side), "beam", "stone_foundation", Vector3(outer_face_x, foundation_height + wing_height - 0.38, wing_center.z), Vector3(0.34, 0.38, wing_depth * 0.82), {"variation": variation - 0.02, "semantic": "castle_keep_palace_wing_outer_bay"})


static func add_keep_palace_dome(blueprint, center: Vector3, span: float, base_y: float, register_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var drum_span := maxf(12.4, span * float(palace_grammar.get("drumSpanRatio", 1.36)))
	var drum_height := maxf(4.0, register_height * float(palace_grammar.get("drumHeightRatio", 0.60)))
	var drum_base_y := base_y + register_height - float(palace_grammar.get("drumSeatOverlap", 0.24))
	var drum_y := drum_base_y + drum_height * 0.5
	var drum_radius := drum_span * 0.46
	var drum_panel_width := drum_span * 0.38
	for panel_index in range(8):
		var panel_angle := float(panel_index) * TAU / 8.0
		var panel_center := Vector3(center.x + sin(panel_angle) * drum_radius, drum_y, center.z + cos(panel_angle) * drum_radius)
		add_part(blueprint, "castle_keep_palace_drum_%02d" % panel_index, "wall", masonry_material, panel_center, Vector3(drum_panel_width, drum_height, 0.72), {"rotation": Vector3(0.0, panel_angle, 0.0), "variation": variation + float(panel_index) * 0.003, "semantic": "castle_keep_palace_drum"})
		if panel_index % 2 == 0:
			var window_center := panel_center + Vector3(sin(panel_angle) * 0.38, 0.0, cos(panel_angle) * 0.38)
			add_part(blueprint, "castle_keep_palace_drum_window_%02d" % panel_index, "window", "window_glass", window_center, Vector3(1.16, minf(2.2, drum_height * 0.46), 0.14), {"rotation": Vector3(0.0, panel_angle, 0.0), "collision": false, "variation": variation, "semantic": "castle_keep_palace_window"})
	var tier_count := int(palace_grammar.get("domeTierCount", 7))
	var tier_step := float(palace_grammar.get("domeTierStep", 0.78))
	var dome_twist := bool(palace_grammar.get("domeTwist", false))
	var dome_base_y := drum_base_y + drum_height
	# A nested octagonal shell is stable under every scale and has no transformed
	# panel seams. Each course overlaps the one below and narrows toward the
	# lantern, preserving the compact stepped crown already proven in the keep PoC.
	for tier_index in range(tier_count):
		var progress := float(tier_index) / float(maxi(1, tier_count - 1))
		var tier_span := lerpf(drum_span * 1.04, maxf(2.4, drum_span * 0.18), progress)
		var tier_y := dome_base_y + float(tier_index) * tier_step + tier_step * 0.50
		var tier_radius := tier_span * 0.44
		var panel_width := tier_span * 0.40
		for panel_index in range(8):
			var panel_angle := float(panel_index) * TAU / 8.0 + (PI * 0.125 if dome_twist and tier_index % 2 == 1 else 0.0)
			var panel_center := Vector3(center.x + sin(panel_angle) * tier_radius, tier_y, center.z + cos(panel_angle) * tier_radius)
			add_part(blueprint, "castle_keep_palace_dome_%02d_%02d" % [tier_index, panel_index], "roof", "roof_shingle", panel_center, Vector3(panel_width, tier_step + 0.08, 0.54), {"rotation": Vector3(0.0, panel_angle, 0.0), "variation": variation + float(panel_index) * 0.002, "semantic": "castle_keep_palace_dome"})
	var lantern_base_y := dome_base_y + float(tier_count) * tier_step
	add_part(blueprint, "castle_keep_palace_lantern", "beam", "stone_foundation", Vector3(center.x, lantern_base_y + 1.4, center.z), Vector3(1.35, 2.8, 1.35), {"variation": variation - 0.02, "semantic": "castle_keep_palace_lantern"})
	add_keep_gabled_roof(blueprint, "castle_keep_palace_lantern_roof", Vector3(center.x, 0.0, center.z), 2.05, 2.05, lantern_base_y + 2.8, 1.48, variation - 0.02, ["castle_keep_palace_lantern", "castle_keep_palace_lantern"])


static func add_keep_palace_entry_court(blueprint, center: Vector3, width: float, depth: float, foundation_height: float, variation: float, portal_width: float, door_width: float, portal_front_z: float, palace_grammar: Dictionary) -> void:
	var court_width := width * float(palace_grammar.get("courtWidthRatio", 0.56))
	var entry_approach: Dictionary = palace_grammar.get("entryApproach", {}) as Dictionary
	var requested_approach_length := float(entry_approach["rampApproachLength"])
	var approach_length := clampf(requested_approach_length, 0.80, 30.0)
	var path_width := portal_width + clampf(float(palace_grammar.get("entranceApproachWidthAdd", 2.2)), 1.2, 3.4)
	var path_start_z := portal_front_z - approach_length
	var entry_surface_thickness := 0.14
	var forecourt_root_height := foundation_height
	var forecourt_root_id := "castle_keep_palace_entry_forecourt_root"
	add_part(blueprint, forecourt_root_id, "foundation", "stone_foundation", Vector3(center.x, forecourt_root_height * 0.5, path_start_z + approach_length * 0.5), Vector3(path_width, forecourt_root_height, approach_length), {"variation": variation - 0.044, "semantic": "castle_keep_palace_entry_forecourt_root", "physicalIntent": "structural_root", "physicalRoot": true})
	var forecourt := add_part(blueprint, "castle_keep_palace_entry_forecourt", "foundation", "stone_foundation", Vector3(center.x, forecourt_root_height + entry_surface_thickness * 0.5, path_start_z + approach_length * 0.5), Vector3(path_width, entry_surface_thickness, approach_length), {"variation": variation - 0.045, "semantic": "castle_keep_palace_entry_forecourt", "navigationRole": "transition", "physicalIntent": "walkable_surface"})
	forecourt.recipe["physicalRequiredSupportPartIds"] = [forecourt_root_id]
	forecourt.recipe["routeTransitionRootPartIds"] = [forecourt_root_id]
	forecourt.recipe["minimumNavigationLaneCount"] = 2
	# The ceremonial portal can be wider than the actual operable keep door.
	# Player/NPC entry lanes must fit the published door leaf, rather than treating
	# the broader forecourt as an imaginary opening through its collision.
	forecourt.recipe["playerTraversalHalfWidth"] = maxf(0.34, minf(portal_width * 0.5 - 0.42, door_width * 0.5 - 0.42))
	forecourt.recipe["interiorDoorPartId"] = "castle_keep_entry_door"
	forecourt.recipe["interiorTransitionPartId"] = "castle_keep_palace_entry_threshold"
	var apron_width := maxf(2.8, (court_width - path_width) * 0.5)
	var apron_center_z := path_start_z + approach_length * 0.5
	var apron_overlap := 0.04
	for side in [-1.0, 1.0]:
		var apron_x: float = center.x + side * (path_width * 0.5 + apron_width * 0.5 - apron_overlap)
		add_part(blueprint, "castle_keep_palace_entry_apron_%d" % int(side), "foundation", "stone_foundation", Vector3(apron_x, foundation_height - 0.035, apron_center_z), Vector3(apron_width, 0.07, approach_length), {"variation": variation - 0.05 + side * 0.006, "collision": false, "semantic": "castle_keep_palace_entry_apron_visual_detail"})


static func ramp_underside_height_at(origin: Vector3, normal: Vector3, world_x: float, world_z: float) -> float:
	return origin.y - (normal.x * (world_x - origin.x) + normal.z * (world_z - origin.z)) / normal.y


static func add_keep_palace_forecourt_galleries(blueprint, center: Vector3, width: float, depth: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	for layout_value in palace_grammar.get("forecourtLayout", []) as Array:
		var layout: Dictionary = layout_value
		var side := float(layout.get("side", -1.0))
		var gallery_center: Vector3 = layout.get("galleryCenter", Vector3.ZERO) as Vector3
		var gallery_width := float(layout.get("galleryWidth", 4.8))
		var gallery_height := float(layout.get("galleryHeight", 5.8))
		var arcade_depth := float(layout.get("arcadeDepth", 3.5))
		var gallery_bay_count := int(layout.get("galleryBayCount", 2))
		var pavilion_center: Vector3 = layout.get("pavilionCenter", Vector3.ZERO) as Vector3
		var pavilion_depth := float(layout.get("pavilionDepth", 2.8))
		var pavilion_height := float(layout.get("pavilionHeight", 7.0))
		var pavilion_width := float(layout.get("pavilionWidth", 5.0))
		add_part(blueprint, "castle_keep_forecourt_gallery_floor_%d" % int(side), "foundation", "stone_foundation", Vector3(gallery_center.x, foundation_height + 0.10, gallery_center.z), Vector3(gallery_width, 0.20, arcade_depth), {"variation": variation, "semantic": "castle_keep_forecourt_gallery"})
		var arcade_clear_height := clampf(gallery_height * 0.48, 2.8, 3.2)
		var upper_storey_height := gallery_height - arcade_clear_height
		var outer_wall_x: float = gallery_center.x + side * (gallery_width * 0.5 - 0.25)
		add_part(blueprint, "castle_keep_forecourt_gallery_outer_wall_%d" % int(side), "wall", masonry_material, Vector3(outer_wall_x, foundation_height + gallery_height * 0.5, gallery_center.z), Vector3(0.50, gallery_height, arcade_depth), {"variation": variation + side * 0.008, "semantic": "castle_keep_forecourt_gallery_occupied_wall"})
		var inner_wall_x: float = gallery_center.x - side * (gallery_width * 0.5 - 0.25)
		add_part(blueprint, "castle_keep_forecourt_gallery_upper_storey_%d" % int(side), "wall", masonry_material, Vector3(inner_wall_x, foundation_height + arcade_clear_height + upper_storey_height * 0.5, gallery_center.z), Vector3(0.50, upper_storey_height, arcade_depth), {"variation": variation + side * 0.008, "semantic": "castle_keep_forecourt_gallery_upper_storey"})
		var bay_depth := arcade_depth / float(gallery_bay_count)
		for bay in range(gallery_bay_count):
			var occupied_z := gallery_center.z - arcade_depth * 0.5 + bay_depth * (float(bay) + 0.5)
			var window_x: float = inner_wall_x - side * 0.30
			add_part(blueprint, "castle_keep_forecourt_gallery_recess_%d_%02d" % [int(side), bay], "decor", "window_recess", Vector3(window_x, foundation_height + arcade_clear_height + upper_storey_height * 0.52, occupied_z), Vector3(0.12, minf(1.38, upper_storey_height * 0.58), maxf(0.58, bay_depth * 0.42)), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_forecourt_gallery_blind_recess"})
		for bay in range(gallery_bay_count + 1):
			var bay_z := gallery_center.z - arcade_depth * 0.5 + float(bay) * arcade_depth / float(gallery_bay_count)
			add_part(blueprint, "castle_keep_forecourt_gallery_column_%d_%02d" % [int(side), bay], "beam", "stone_foundation", Vector3(inner_wall_x, foundation_height + arcade_clear_height * 0.5, bay_z), Vector3(0.48, arcade_clear_height, 0.48), {"variation": variation + side * 0.008, "semantic": "castle_keep_forecourt_arcade"})
		add_part(blueprint, "castle_keep_forecourt_gallery_arcade_header_%d" % int(side), "beam", masonry_material, Vector3(inner_wall_x, foundation_height + arcade_clear_height - 0.18, gallery_center.z), Vector3(0.58, 0.36, arcade_depth + 0.18), {"variation": variation + side * 0.008, "semantic": "castle_keep_forecourt_arcade_header"})
		var gallery_bearers := ["castle_keep_forecourt_gallery_outer_wall_%d" % int(side), "castle_keep_forecourt_gallery_upper_storey_%d" % int(side)] if side < 0.0 else ["castle_keep_forecourt_gallery_upper_storey_%d" % int(side), "castle_keep_forecourt_gallery_outer_wall_%d" % int(side)]
		add_keep_gabled_roof(blueprint, "castle_keep_forecourt_gallery_roof_%d" % int(side), gallery_center, gallery_width, arcade_depth, foundation_height + gallery_height, 2.2, variation + side * 0.008, gallery_bearers)
		add_part(blueprint, "castle_keep_forecourt_pavilion_foundation_%d" % int(side), "foundation", "stone_foundation", Vector3(pavilion_center.x, foundation_height * 0.5, pavilion_center.z), Vector3(pavilion_width + 0.36, foundation_height, pavilion_depth + 0.36), {"variation": variation + side * 0.010, "semantic": "castle_keep_forecourt_pavilion_plinth", "physicalIntent": "structural_root"})
		add_part(blueprint, "castle_keep_forecourt_pavilion_%d" % int(side), "wall", masonry_material, Vector3(pavilion_center.x, foundation_height + pavilion_height * 0.5, pavilion_center.z), Vector3(pavilion_width, pavilion_height, pavilion_depth), {"variation": variation + side * 0.012, "semantic": "castle_keep_forecourt_pavilion", "physicalPartyWallBearingModes": ["terminal_joint", "embedded_panel"]})
		preload("res://scripts/buildings/CitadelExteriorBuntingDomain.gd").declare(blueprint.parts.back(), "forecourt_pavilion", int(side))
		var pavilion_id := "castle_keep_forecourt_pavilion_%d" % int(side)
		add_keep_gabled_roof(blueprint, "castle_keep_forecourt_pavilion_roof_%d" % int(side), pavilion_center, pavilion_width, pavilion_depth, foundation_height + pavilion_height, maxf(2.2, pavilion_width * 0.46), variation + side * 0.012, [pavilion_id, pavilion_id])
		for level in range(2):
			var window_center := Vector3(pavilion_center.x - side * (pavilion_width * 0.5 + 0.04), foundation_height + 1.78 + float(level) * 2.45, pavilion_center.z)
			add_part(blueprint, "castle_keep_forecourt_pavilion_recess_%d_%02d" % [int(side), level], "decor", "window_recess", window_center, Vector3(0.10, 1.30, minf(1.04, pavilion_depth * 0.34)), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_forecourt_pavilion_blind_recess"})


static func add_keep_palace_rear_court(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var rear_z := center.z + depth * 0.5
	var court_depth := clampf(depth * float(palace_grammar.get("rearCourtDepthRatio", 0.22)), 4.2, 8.4)
	var portico_width := width * float(palace_grammar.get("rearPorticoWidthRatio", 0.36))
	var portico_height := clampf(hall_height * 0.28, 3.8, 5.4)
	var portico_center := Vector3(center.x, 0.0, rear_z + court_depth * 0.46)
	add_part(blueprint, "castle_keep_rear_court", "foundation", "stone_foundation", Vector3(center.x, foundation_height + 0.10, rear_z + court_depth * 0.5), Vector3(width * 0.72, 0.20, court_depth), {"variation": variation, "semantic": "castle_keep_rear_court"})
	for column_index in range(5):
		var column_x := center.x + lerpf(-portico_width * 0.5, portico_width * 0.5, float(column_index) / 4.0)
		add_part(blueprint, "castle_keep_rear_portico_column_%02d" % column_index, "beam", "stone_foundation", Vector3(column_x, foundation_height + portico_height * 0.5, portico_center.z), Vector3(0.58, portico_height, 0.58), {"variation": variation, "semantic": "castle_keep_rear_portico"})
	add_part(blueprint, "castle_keep_rear_portico_entablature", "beam", masonry_material, Vector3(portico_center.x, foundation_height + portico_height - 0.26, portico_center.z), Vector3(portico_width + 0.60, 0.52, 0.82), {"variation": variation, "semantic": "castle_keep_rear_portico"})
	add_keep_gabled_roof(blueprint, "castle_keep_rear_portico_roof", portico_center, portico_width, 0.82, foundation_height + portico_height, 2.0, variation, ["castle_keep_rear_portico_entablature", "castle_keep_rear_portico_entablature"])
	var service_bias := width * float(palace_grammar.get("rearServiceWingBias", 0.08))
	for side in [-1.0, 1.0]:
		var service_width := width * (0.22 if side < 0.0 else 0.18)
		var service_depth := court_depth * (0.72 if side < 0.0 else 0.58)
		var service_height := portico_height * (1.18 if side < 0.0 else 0.96)
		var service_center := Vector3(center.x + side * (width * 0.34 + service_bias * side), 0.0, rear_z + service_depth * 0.42)
		add_part(blueprint, "castle_keep_rear_service_%d" % int(side), "wall", masonry_material, Vector3(service_center.x, foundation_height + service_height * 0.5, service_center.z), Vector3(service_width, service_height, service_depth), {"variation": variation + side * 0.01, "semantic": "castle_keep_rear_service"})
		var service_id := "castle_keep_rear_service_%d" % int(side)
		add_keep_gabled_roof(blueprint, "castle_keep_rear_service_roof_%d" % int(side), service_center, service_width, service_depth, foundation_height + service_height, maxf(1.8, service_width * 0.28), variation + side * 0.01, [service_id, service_id])
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	var cross_width := width * float(palace_grammar.get("rearCrossWingWidthRatio", 0.30))
	var cross_depth := depth * float(palace_grammar.get("rearCrossWingDepthRatio", 0.50))
	for side in [-1.0, 1.0]:
		var cross_height := hall_height * float(palace_grammar.get("rearCrossWingHeightRatio", 0.54)) * (1.10 if side == dominant_side else 0.90)
		var cross_center := Vector3(center.x + side * width * 0.30, 0.0, rear_z + cross_depth * 0.30)
		add_part(blueprint, "castle_keep_rear_cross_wing_%d" % int(side), "wall", masonry_material, Vector3(cross_center.x, foundation_height + cross_height * 0.5, cross_center.z), Vector3(cross_width, cross_height, cross_depth), {"variation": variation + side * 0.012, "semantic": "castle_keep_rear_cross_wing"})
		var cross_wing_id := "castle_keep_rear_cross_wing_%d" % int(side)
		add_keep_gabled_roof(blueprint, "castle_keep_rear_cross_wing_roof_%d" % int(side), cross_center, cross_width, cross_depth, foundation_height + cross_height, maxf(2.4, cross_width * 0.34), variation + side * 0.012, [cross_wing_id, cross_wing_id])
		var rear_face_z := cross_center.z + cross_depth * 0.5 + 0.39
		for level in range(2):
			for bay in range(3):
				var window_x := cross_center.x + (float(bay) - 1.0) * cross_width * 0.24
				if side == dominant_side and level == 0 and bay == 1:
					continue
				add_part(blueprint, "castle_keep_rear_cross_recess_%d_%d_%d" % [int(side), level, bay], "decor", "window_recess", Vector3(window_x, foundation_height + 2.15 + float(level) * 3.15, rear_face_z), Vector3(1.06, 1.58, 0.14), {"collision": false, "variation": variation, "semantic": "castle_keep_rear_cross_blind_recess"})
		if side == dominant_side:
			add_part(blueprint, "castle_keep_rear_secondary_door", "door", "painted_door", Vector3(cross_center.x, foundation_height + 1.36, rear_face_z + 0.04), Vector3(1.42, 2.72, 0.18), {"variation": variation - 0.02, "semantic": "castle_keep_secondary_entry"})
			for jamb_side in [-1.0, 1.0]:
				add_part(blueprint, "castle_keep_rear_secondary_jamb_%d" % int(jamb_side), "wall", masonry_material, Vector3(cross_center.x + jamb_side * 0.94, foundation_height + 1.36, rear_face_z - 0.28), Vector3(0.36, 2.72, 0.42), {"collision": false, "variation": variation - 0.018 + jamb_side * 0.004, "semantic": "castle_keep_secondary_entry_jamb", "physicalIntent": "facade_attachment", "physicalRequiredAnchorPartIds": [cross_wing_id], "physicalRequiredAnchorFacts": [{"anchorId": cross_wing_id, "contactMode": "attachment_socket", "localMountCenter": Vector3(0.0, 0.0, -0.17), "localMountHalfExtents": Vector3(0.025, 0.025, 0.018)}]})
			add_part(blueprint, "castle_keep_rear_secondary_lintel", "beam", "stone_foundation", Vector3(cross_center.x, foundation_height + 3.02, rear_face_z - 0.26), Vector3(2.38, 0.44, 0.42), {"collision": false, "variation": variation - 0.02, "semantic": "castle_keep_secondary_entry", "physicalIntent": "facade_attachment", "physicalRequiredAnchorPartIds": [cross_wing_id], "physicalRequiredAnchorFacts": [{"anchorId": cross_wing_id, "contactMode": "attachment_socket", "localMountCenter": Vector3(0.0, 0.0, -0.17), "localMountHalfExtents": Vector3(0.025, 0.025, 0.018)}]})


static func add_keep_palace_window_rhythm(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, palace_grammar: Dictionary) -> void:
	var front_z := center.z - depth * 0.5 - 0.39
	var levels := clampi(floori(hall_height / 3.7), 3, 5)
	var central_columns := int(palace_grammar.get("centralWindowColumns", 5))
	for level in range(levels):
		var y := foundation_height + 2.15 + float(level) * 3.35
		for column in range(central_columns):
			if level == 0 and column == central_columns / 2:
				continue
			var x := center.x + (float(column) - float(central_columns - 1) * 0.5) * width * 0.145
			add_part(blueprint, "castle_keep_palace_window_c_%02d_%02d" % [level, column], "window", "window_glass", Vector3(x, y, front_z), Vector3(1.18, 1.72, 0.14), {"collision": false, "variation": variation + float(column) * 0.004, "semantic": "castle_keep_palace_window"})
	var wing_width := width * float(palace_grammar.get("wingWidthRatio", 0.68))
	var wing_depth := depth * float(palace_grammar.get("wingDepthRatio", 0.68))
	var wing_front_z := center.z + depth * float(palace_grammar.get("wingZRatio", -0.16)) - wing_depth * 0.5 - 0.39
	for side in [-1.0, 1.0]:
		var offset_ratio := float(palace_grammar.get("wingOffsetLeftRatio", 0.58)) if side < 0.0 else float(palace_grammar.get("wingOffsetRightRatio", 0.54))
		var wing_center_x: float = center.x + side * width * offset_ratio
		for level in range(maxi(2, levels - 1)):
			var y := foundation_height + 2.15 + float(level) * 3.35
			var wing_columns := int(palace_grammar.get("wingWindowColumns", 4))
			for column in range(wing_columns):
				var x: float = wing_center_x + (float(column) - float(wing_columns - 1) * 0.5) * wing_width * 0.21
				add_part(blueprint, "castle_keep_palace_window_w%d_%02d_%02d" % [int(side), level, column], "window", "window_glass", Vector3(x, y, wing_front_z), Vector3(1.08, 1.62, 0.14), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_palace_window"})
	var rear_z := center.z + depth * 0.5 + 0.39
	var rear_columns := int(palace_grammar.get("rearWindowColumns", 5))
	for level in range(levels):
		var rear_y := foundation_height + 2.15 + float(level) * 3.35
		for column in range(rear_columns):
			var rear_x := center.x + (float(column) - float(rear_columns - 1) * 0.5) * width * 0.14
			add_part(blueprint, "castle_keep_palace_window_rear_%02d_%02d" % [level, column], "window", "window_glass", Vector3(rear_x, rear_y, rear_z), Vector3(1.08, 1.62, 0.14), {"rotation": Vector3(0.0, PI, 0.0), "collision": false, "variation": variation, "semantic": "castle_keep_palace_window"})
	var wing_end_columns := int(palace_grammar.get("wingEndWindowColumns", 2))
	var wing_z_center := center.z + depth * float(palace_grammar.get("wingZRatio", -0.16))
	for side in [-1.0, 1.0]:
		var offset_ratio := float(palace_grammar.get("wingOffsetLeftRatio", 0.58)) if side < 0.0 else float(palace_grammar.get("wingOffsetRightRatio", 0.54))
		var outer_x: float = center.x + side * (width * offset_ratio + wing_width * 0.5 + 0.39)
		for level in range(maxi(2, levels - 1)):
			var end_y := foundation_height + 2.15 + float(level) * 3.35
			for column in range(wing_end_columns):
				var end_z := wing_z_center + (float(column) - float(wing_end_columns - 1) * 0.5) * wing_depth * 0.28
				add_part(blueprint, "castle_keep_palace_window_end%d_%02d_%02d" % [int(side), level, column], "window", "window_glass", Vector3(outer_x, end_y, end_z), Vector3(0.14, 1.62, 1.08), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_palace_window"})
	var hall_side_columns := int(palace_grammar.get("hallSideWindowColumns", 4))
	for side in [-1.0, 1.0]:
		var side_x: float = center.x + side * (width * 0.5 + 0.39)
		for level in range(levels):
			var side_y := foundation_height + 2.15 + float(level) * 3.35
			for column in range(hall_side_columns):
				var side_z := center.z + (float(column) - float(hall_side_columns - 1) * 0.5) * depth * 0.21
				add_part(blueprint, "castle_keep_palace_window_side%d_%02d_%02d" % [int(side), level, column], "window", "window_glass", Vector3(side_x, side_y, side_z), Vector3(0.14, 1.62, 1.08), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_palace_window"})
		for pier_index in range(1, hall_side_columns):
			var pier_z := center.z + lerpf(-depth * 0.42, depth * 0.42, float(pier_index) / float(hall_side_columns))
			add_part(blueprint, "castle_keep_palace_side_pier%d_%02d" % [int(side), pier_index], "wall", "stone_foundation", Vector3(side_x + side * 0.10, foundation_height + hall_height * 0.30, pier_z), Vector3(0.68, hall_height * 0.60, 0.78), {"variation": variation - 0.03, "semantic": "castle_keep_buttress"})
		var side_bay_count := int(palace_grammar.get("sideBayCount", 3))
		for bay_index in range(side_bay_count):
			var bay_z := center.z + lerpf(-depth * 0.34, depth * 0.34, float(bay_index) / float(maxi(1, side_bay_count - 1)))
			var bay_height := hall_height * (0.42 + 0.06 * float((bay_index + 1) % 2))
			add_part(blueprint, "castle_keep_palace_side_bay%d_%02d" % [int(side), bay_index], "wall", "stone_foundation", Vector3(side_x + side * 0.56, foundation_height + bay_height * 0.5, bay_z), Vector3(1.12, bay_height, maxf(2.2, depth * 0.14)), {"variation": variation - 0.02, "semantic": "castle_keep_palace_side_bay"})


static func add_keep_storey_floor_with_stairwell(blueprint, storey_index: int, center: Vector3, width: float, depth: float, stair_center: Vector3, stair_width: float, stair_depth: float, foundation_height: float, floor_height: float, variation: float) -> void:
	var inset := 0.74
	var min_x := center.x - width * 0.5 + inset
	var max_x := center.x + width * 0.5 - inset
	var min_z := center.z - depth * 0.5 + inset
	var max_z := center.z + depth * 0.5 - inset
	# The stairwell and its trim need an actual framing margin on every side;
	# without it a rear-edge well emits visible supports beyond the keep shell.
	var hole_min_x := clampf(stair_center.x - stair_width * 0.5 - 0.12, min_x + 0.28, max_x - 1.10)
	var hole_max_x := clampf(stair_center.x + stair_width * 0.5 + 0.12, hole_min_x + 0.82, max_x - 0.28)
	var hole_min_z := clampf(stair_center.z - stair_depth * 0.5 - 0.12, min_z + 0.28, max_z - 1.10)
	var hole_max_z := clampf(stair_center.z + stair_depth * 0.5 + 0.12, hole_min_z + 0.82, max_z - 0.28)
	var floor_y := foundation_height + floor_height * float(storey_index) + 0.10
	var prefix := "castle_keep_storey_%02d" % storey_index
	var left_ledger_id := "%s_left_shell_ledger" % prefix
	var right_ledger_id := "%s_right_shell_ledger" % prefix
	var ledger_y := floor_y - 0.16
	var ledger_bottom_y := ledger_y - 0.15
	var prior_ledger_bottom_y := foundation_height + floor_height * float(storey_index - 1) - 0.21
	var ledger_supports: Dictionary = {"left": [], "right": []}
	for side_name in ["left", "right"]:
		var side_x := min_x + 0.18 if side_name == "left" else max_x - 0.18
		for support_index in range(3):
			var support_z := lerpf(min_z + 0.28, max_z - 0.28, float(support_index) * 0.5)
			var support_id := "%s_%s_ledger_pilaster_%d" % [prefix, side_name, support_index]
			(ledger_supports[side_name] as Array).append(support_id)
			if storey_index == 1:
				add_part(blueprint, support_id, "foundation", "stone_foundation", Vector3(side_x, ledger_bottom_y * 0.5, support_z), Vector3(0.36, ledger_bottom_y, 0.36), {"variation": variation - 0.026, "semantic": "castle_keep_interior_ledger_pilaster", "physicalIntent": "structural_root"})
			else:
				var lower_id := "castle_keep_storey_%02d_%s_ledger_pilaster_%d" % [storey_index - 1, side_name, support_index]
				var segment_height := ledger_bottom_y - prior_ledger_bottom_y
				add_part(blueprint, support_id, "beam", "stone_foundation", Vector3(side_x, prior_ledger_bottom_y + segment_height * 0.5, support_z), Vector3(0.36, segment_height, 0.36), {"variation": variation - 0.026, "semantic": "castle_keep_interior_ledger_pilaster", "physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": [lower_id], "physicalRequiredSeatFacts": [{"seatId": lower_id, "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -segment_height * 0.5, 0.0), "localPatchHalfExtents": Vector2(0.08, 0.08), "seatFace": "max_y"}]})
	var left_ledger_facts: Array[Dictionary] = []
	var right_ledger_facts: Array[Dictionary] = []
	for support_index in range(3):
		var support_z := lerpf(min_z + 0.28, max_z - 0.28, float(support_index) * 0.5)
		left_ledger_facts.append({"seatId": String((ledger_supports["left"] as Array)[support_index]), "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -0.15, support_z - center.z), "localPatchHalfExtents": Vector2(0.08, 0.08), "seatFace": "max_y"})
		right_ledger_facts.append({"seatId": String((ledger_supports["right"] as Array)[support_index]), "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -0.15, support_z - center.z), "localPatchHalfExtents": Vector2(0.08, 0.08), "seatFace": "max_y"})
	# All upper-storey framing stays behind the outer shell line.  These are
	# visible interior ledgers, never exterior platforms or hidden overhangs.
	add_part(blueprint, left_ledger_id, "beam", "stone_foundation", Vector3(min_x + 0.18, ledger_y, center.z), Vector3(0.36, 0.30, max_z - min_z), {"variation": variation - 0.02, "semantic": "castle_keep_floor_shell_ledger", "physicalAssemblyRole": "floor_ledger", "physicalRequiredSeatPartIds": ledger_supports["left"], "physicalRequiredSeatFacts": left_ledger_facts})
	add_part(blueprint, right_ledger_id, "beam", "stone_foundation", Vector3(max_x - 0.18, ledger_y, center.z), Vector3(0.36, 0.30, max_z - min_z), {"variation": variation - 0.02, "semantic": "castle_keep_floor_shell_ledger", "physicalAssemblyRole": "floor_ledger", "physicalRequiredSeatPartIds": ledger_supports["right"], "physicalRequiredSeatFacts": right_ledger_facts})
	var trim_front_id := "%s_stair_trim_front" % prefix
	var trim_back_id := "%s_stair_trim_back" % prefix
	var trim_supports: Dictionary = {"front": [], "back": []}
	for trim_name in ["front", "back"]:
		var trim_z := hole_min_z - 0.18 if trim_name == "front" else hole_max_z + 0.18
		for support_index in range(3):
			var support_x := lerpf(min_x + 0.28, max_x - 0.28, float(support_index) * 0.5)
			var support_id := "%s_stair_trim_%s_pilaster_%d" % [prefix, trim_name, support_index]
			(trim_supports[trim_name] as Array).append(support_id)
			if storey_index == 1:
				add_part(blueprint, support_id, "foundation", "stone_foundation", Vector3(support_x, ledger_bottom_y * 0.5, trim_z), Vector3(0.36, ledger_bottom_y, 0.36), {"variation": variation - 0.028, "semantic": "castle_keep_stairwell_trim_pilaster", "physicalIntent": "structural_root"})
			else:
				var lower_id := "castle_keep_storey_%02d_stair_trim_%s_pilaster_%d" % [storey_index - 1, trim_name, support_index]
				var segment_height := ledger_bottom_y - prior_ledger_bottom_y
				add_part(blueprint, support_id, "beam", "stone_foundation", Vector3(support_x, prior_ledger_bottom_y + segment_height * 0.5, trim_z), Vector3(0.36, segment_height, 0.36), {"variation": variation - 0.028, "semantic": "castle_keep_stairwell_trim_pilaster", "physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": [lower_id], "physicalRequiredSeatFacts": [{"seatId": lower_id, "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -segment_height * 0.5, 0.0), "localPatchHalfExtents": Vector2(0.08, 0.08), "seatFace": "max_y"}]})
	var trim_front_facts: Array[Dictionary] = []
	var trim_back_facts: Array[Dictionary] = []
	for support_index in range(3):
		var support_x := lerpf(min_x + 0.28, max_x - 0.28, float(support_index) * 0.5)
		trim_front_facts.append({"seatId": String((trim_supports["front"] as Array)[support_index]), "loadDirection": "world_down", "localPatchCenter": Vector3(support_x - center.x, -0.15, 0.0), "localPatchHalfExtents": Vector2(0.08, 0.08), "seatFace": "max_y"})
		trim_back_facts.append({"seatId": String((trim_supports["back"] as Array)[support_index]), "loadDirection": "world_down", "localPatchCenter": Vector3(support_x - center.x, -0.15, 0.0), "localPatchHalfExtents": Vector2(0.08, 0.08), "seatFace": "max_y"})
	add_part(blueprint, trim_front_id, "beam", "stone_foundation", Vector3(center.x, ledger_y, hole_min_z - 0.18), Vector3(max_x - min_x, 0.30, 0.36), {"variation": variation - 0.018, "semantic": "castle_keep_stairwell_trim_girder", "physicalAssemblyRole": "stairwell_trim_girder", "physicalRequiredSeatPartIds": trim_supports["front"], "physicalRequiredSeatFacts": trim_front_facts})
	add_part(blueprint, trim_back_id, "beam", "stone_foundation", Vector3(center.x, ledger_y, hole_max_z + 0.18), Vector3(max_x - min_x, 0.30, 0.36), {"variation": variation - 0.018, "semantic": "castle_keep_stairwell_trim_girder", "physicalAssemblyRole": "stairwell_trim_girder", "physicalRequiredSeatPartIds": trim_supports["back"], "physicalRequiredSeatFacts": trim_back_facts})
	# Four panels surround the stairwell on the exact same elevation.  The rear
	# right well is intentionally open, while all other floor area stays real
	# collision-backed stone.
	add_keep_floor_panel(blueprint, "%s_floor_front" % prefix, min_x, max_x, min_z, hole_min_z, floor_y, variation, "x", left_ledger_id, right_ledger_id)
	add_keep_floor_panel(blueprint, "%s_floor_back" % prefix, min_x, max_x, hole_max_z, max_z, floor_y, variation, "x", left_ledger_id, right_ledger_id)
	add_keep_floor_panel(blueprint, "%s_floor_left" % prefix, min_x, hole_min_x, hole_min_z, hole_max_z, floor_y, variation, "z", trim_front_id, trim_back_id)
	add_keep_floor_panel(blueprint, "%s_floor_right" % prefix, hole_max_x, max_x, hole_min_z, hole_max_z, floor_y, variation, "z", trim_front_id, trim_back_id)


static func add_keep_floor_panel(blueprint, part_id: String, min_x: float, max_x: float, min_z: float, max_z: float, y: float, variation: float, bearer_axis: String, first_seat_id: String, second_seat_id: String) -> void:
	if max_x - min_x <= 0.08 or max_z - min_z <= 0.08:
		return
	var floor := add_part(blueprint, part_id, "floor", "stone_foundation", Vector3((min_x + max_x) * 0.5, y, (min_z + max_z) * 0.5), Vector3(max_x - min_x, 0.20, max_z - min_z), {"variation": variation, "semantic": "castle_keep_storey_floor", "physicalAssemblyRole": "floor_diaphragm"})
	var bearer_ids: Array[String] = []
	for bearer_index in range(3):
		var bearer_id := "%s_bearer_%d" % [part_id, bearer_index]
		bearer_ids.append(bearer_id)
		var position := Vector3((min_x + max_x) * 0.5, y - 0.16, (min_z + max_z) * 0.5)
		var size := Vector3(max_x - min_x - 0.72, 0.30, 0.36)
		var facts: Array[Dictionary] = [{"seatId": first_seat_id, "bearerFace": "min_x", "seatFace": "max_x"}, {"seatId": second_seat_id, "bearerFace": "max_x", "seatFace": "min_x"}]
		if bearer_axis == "x":
			position.z = lerpf(min_z + 0.18, max_z - 0.18, float(bearer_index) * 0.5)
		else:
			position.x = lerpf(min_x + 0.18, max_x - 0.18, float(bearer_index) * 0.5)
			size = Vector3(0.36, 0.30, max_z - min_z)
			facts = [{"seatId": first_seat_id, "bearerFace": "min_z", "seatFace": "max_z"}, {"seatId": second_seat_id, "bearerFace": "max_z", "seatFace": "min_z"}]
		add_part(blueprint, bearer_id, "beam", "stone_foundation", position, size, {"variation": variation - 0.02, "semantic": "castle_keep_floor_bearer", "physicalAssemblyRole": "floor_bearer", "physicalRequiredSeatPartIds": [first_seat_id, second_seat_id], "physicalRequiredSeatFacts": facts})
	# A clipped panel may only intersect one of its three joists, while its
	# perimeter ledgers/trimmers are also valid collision-bearing support. Keep
	# a named mandatory joist and list the complete legal frame separately.
	var storey_prefix := part_id.get_slice("_floor_", 0)
	var local_frame_ids: Array[String] = [
		"%s_left_shell_ledger" % storey_prefix,
		"%s_right_shell_ledger" % storey_prefix,
		"%s_stair_trim_front" % storey_prefix,
		"%s_stair_trim_back" % storey_prefix,
		# The front corners terminate at the visible, rooted entrance towers.
		# They are part of the shell framing rather than a separate collider.
		"castle_keep_front_tower_-1",
		"castle_keep_front_tower_1",
		"castle_keep_palace_wing_-1",
		"castle_keep_palace_wing_1",
		"castle_keep_palace_wing_roof_-1_left",
		"castle_keep_palace_wing_roof_-1_right",
		"castle_keep_palace_wing_roof_1_left",
		"castle_keep_palace_wing_roof_1_right",
		# Rear wing walls carry the clipped inside corners where the procedural
		# cross-wing joins the stairwell floor.
		"castle_keep_rear_cross_wing_-1",
		"castle_keep_rear_cross_wing_1"
	]
	floor.recipe["physicalRequiredSupportPartIds"] = [bearer_ids.front()]
	floor.recipe["physicalAllowedSupportPartIds"] = bearer_ids + local_frame_ids
	if bearer_axis == "x":
		# The perimeter ledger bears the outer sample columns while the three
		# interior joists carry the span. Exact row ownership would incorrectly
		# reject that real composite floor frame.
		pass
	else:
		# Stairwell trimmers likewise carry the perimeter samples of the side
		# panels; acceptance requires rooted coverage, not a single-owner sample.
		pass


static func add_switchback_stair_flights(blueprint, prefix: String, center: Vector3, span_width: float, span_depth: float, base_y: float, rise_per_level: float, level_count: int, material: String, variation: float, semantic: String) -> void:
	# This is the same construction logic proven by the manor: visible treads
	# express the staircase, while continuous hidden stringers provide smooth
	# collision all the way between landings.  It is shared here so the keep and
	# gatehouse do not grow competing vertical-movement implementations.
	# Leave head/shoulder clearance at the turn beneath the enclosing floor
	# trim and roof hatch. The full landing still carries each housed ramp end.
	var run := maxf(1.42, span_depth - 1.08)
	var half_rise := rise_per_level * 0.5
	var angle := atan2(half_rise, run)
	# The return flight's lower end projects farther into the half-level turn
	# than its upper end projects onto the exit: its top plane is 0.14m above
	# the housed contact plane. Centre that asymmetric envelope in the opening
	# instead of steepening both flights to make room beneath the rear trim.
	center.z -= 0.14 * sin(angle)
	var ramp_width := clampf(span_width * 0.30, 0.70, 1.10)
	var lateral_offset := minf(span_width * 0.20, maxf(0.34, span_width * 0.5 - ramp_width * 0.60))
	var left_x := center.x - lateral_offset
	var right_x := center.x + lateral_offset
	var tread_count := maxi(7, ceili(half_rise / 0.24))
	var tread_run := run / float(tread_count)
	var tread_rise := half_rise / float(tread_count)
	for level in range(maxi(1, level_count)):
		var level_base_y := base_y + rise_per_level * float(level)
		var base_pier_id := "%s_base_pier_%02d" % [prefix, level]
		var landing_pier_id := "%s_landing_pier_%02d" % [prefix, level]
		var exit_pier_id := "%s_exit_pier_%02d" % [prefix, level]
		var base_underframe_id := "%s_base_underframe_%02d" % [prefix, level]
		var landing_underframe_id := "%s_landing_underframe_%02d" % [prefix, level]
		var exit_underframe_id := "%s_exit_underframe_%02d" % [prefix, level]
		var shoe_thickness := 0.14
		var up_lower_shoe_id := "%s_up_lower_shoe_%02d" % [prefix, level]
		var up_upper_shoe_id := "%s_up_upper_shoe_%02d" % [prefix, level]
		var return_lower_shoe_id := "%s_return_lower_shoe_%02d" % [prefix, level]
		var return_upper_shoe_id := "%s_return_upper_shoe_%02d" % [prefix, level]
		var base_pier_center := Vector3(center.x, 0.0, center.z - run * 0.5)
		var landing_pier_center := Vector3(center.x, 0.0, center.z + run * 0.5)
		var exit_pier_center := Vector3(center.x, 0.0, center.z - run * 0.5)
		add_stair_landing_frame(blueprint, base_underframe_id, base_pier_id, base_pier_center, level_base_y, span_width - 0.18, material, variation, semantic)
		add_stair_landing_frame(blueprint, landing_underframe_id, landing_pier_id, landing_pier_center, level_base_y + half_rise, span_width - 0.18, material, variation, semantic)
		add_stair_landing_frame(blueprint, exit_underframe_id, exit_pier_id, exit_pier_center, level_base_y + rise_per_level, span_width - 0.18, material, variation, semantic)
		if level == 0:
			# The first flight needs the same finished walking surface as later
			# exits; otherwise its bearing shoe protrudes above the surrounding floor.
			add_part(blueprint, "%s_base_landing" % prefix, "floor", material, Vector3(center.x, level_base_y, center.z - run * 0.5), Vector3(span_width - 0.18, 0.20, STAIR_LANDING_DEPTH), {"variation": variation, "semantic": "%s_landing" % semantic})
		var up_assembly_id := "%s_up_%02d" % [prefix, level]
		var up_lower_shoe_center := Vector3(left_x, level_base_y - 0.10 + shoe_thickness * 0.5, center.z - run * 0.5)
		var up_upper_shoe_center := Vector3(left_x, level_base_y + half_rise - 0.10 + shoe_thickness * 0.5, center.z + run * 0.5)
		var up_geometry := stair_housed_geometry(up_lower_shoe_center, up_upper_shoe_center, 0.18)
		add_part(blueprint, "%s_up_carriage_%02d" % [prefix, level], "ramp", material, up_geometry.get("center", Vector3.ZERO) as Vector3, Vector3(ramp_width, 0.18, float(up_geometry.get("length", run))), {"rotation": up_geometry.get("rotation", Vector3.ZERO) as Vector3, "variation": variation - 0.025, "semantic": "%s_visible_stair_carriage" % semantic, "physicalIntent": "structural_mass", "physicalAssemblyRole": "stair_sloped_span", "physicalStairAssemblyId": up_assembly_id, "physicalRequiredAssemblyBearingBlockIds": [up_lower_shoe_id, up_upper_shoe_id], "physicalRequiredSeatPartIds": [up_lower_shoe_id, up_upper_shoe_id], "physicalRequiredSeatFacts": [stair_housed_joint_fact(up_lower_shoe_id, -1.0, up_geometry), stair_housed_joint_fact(up_upper_shoe_id, 1.0, up_geometry)]})
		var up_carriage = blueprint.parts.back()
		up_carriage.recipe.navigationStartSupportPartId = "%s_base_landing" % prefix if level == 0 else "%s_exit_%02d" % [prefix, level - 1]
		up_carriage.recipe.navigationEndSupportPartId = "%s_landing_%02d" % [prefix, level]
		for tread_index in range(tread_count):
			var up_z := center.z - run * 0.5 + tread_run * (float(tread_index) + 0.5)
			var up_y := level_base_y + tread_rise * float(tread_index + 1) - 0.055
			add_part(blueprint, "%s_up_tread_%02d_%02d" % [prefix, level, tread_index], "stair_tread", material, Vector3(left_x, up_y, up_z), Vector3(ramp_width, 0.11, tread_run + 0.025), {"collision": false, "variation": variation, "semantic": "%s_tread" % semantic, "physicalIntent": "visual_detail"})
		var landing_y := level_base_y + half_rise
		var landing_center := Vector3(center.x, landing_y, center.z + run * 0.5)
		add_part(blueprint, "%s_landing_%02d" % [prefix, level], "floor", material, landing_center, Vector3(span_width - 0.18, 0.20, STAIR_LANDING_DEPTH), {"variation": variation, "semantic": "%s_landing" % semantic})
		var return_assembly_id := "%s_return_%02d" % [prefix, level]
		var return_lower_shoe_center := Vector3(right_x, level_base_y + half_rise - 0.10 + shoe_thickness * 0.5, center.z + run * 0.5)
		var return_upper_shoe_center := Vector3(right_x, level_base_y + rise_per_level - 0.10 + shoe_thickness * 0.5, center.z - run * 0.5)
		var return_geometry := stair_housed_geometry(return_lower_shoe_center, return_upper_shoe_center, 0.18)
		add_part(blueprint, "%s_return_carriage_%02d" % [prefix, level], "ramp", material, return_geometry.get("center", Vector3.ZERO) as Vector3, Vector3(ramp_width, 0.18, float(return_geometry.get("length", run))), {"rotation": return_geometry.get("rotation", Vector3.ZERO) as Vector3, "variation": variation - 0.025, "semantic": "%s_visible_stair_carriage" % semantic, "physicalIntent": "structural_mass", "physicalAssemblyRole": "stair_sloped_span", "physicalStairAssemblyId": return_assembly_id, "physicalRequiredAssemblyBearingBlockIds": [return_lower_shoe_id, return_upper_shoe_id], "physicalRequiredSeatPartIds": [return_lower_shoe_id, return_upper_shoe_id], "physicalRequiredSeatFacts": [stair_housed_joint_fact(return_lower_shoe_id, -1.0, return_geometry), stair_housed_joint_fact(return_upper_shoe_id, 1.0, return_geometry)]})
		var return_carriage = blueprint.parts.back()
		return_carriage.recipe.navigationStartSupportPartId = "%s_landing_%02d" % [prefix, level]
		return_carriage.recipe.navigationEndSupportPartId = "%s_exit_%02d" % [prefix, level]
		for tread_index in range(tread_count):
			var return_z := center.z + run * 0.5 - tread_run * (float(tread_index) + 0.5)
			var return_y := level_base_y + half_rise + tread_rise * float(tread_index + 1) - 0.055
			add_part(blueprint, "%s_return_tread_%02d_%02d" % [prefix, level, tread_index], "stair_tread", material, Vector3(right_x, return_y, return_z), Vector3(ramp_width, 0.11, tread_run + 0.025), {"collision": false, "variation": variation, "semantic": "%s_tread" % semantic, "physicalIntent": "visual_detail"})
		var exit_y := level_base_y + rise_per_level
		var exit_center := Vector3(center.x, exit_y, center.z - run * 0.5)
		add_part(blueprint, "%s_exit_%02d" % [prefix, level], "floor", material, exit_center, Vector3(span_width - 0.18, 0.20, STAIR_LANDING_DEPTH), {"variation": variation, "semantic": "%s_exit" % semantic})
		add_stair_carriage_shoe(blueprint, up_lower_shoe_id, up_lower_shoe_center, ramp_width, shoe_thickness, base_underframe_id, up_assembly_id, material, variation, semantic)
		add_stair_carriage_shoe(blueprint, up_upper_shoe_id, up_upper_shoe_center, ramp_width, shoe_thickness, landing_underframe_id, up_assembly_id, material, variation, semantic)
		add_stair_carriage_shoe(blueprint, return_lower_shoe_id, return_lower_shoe_center, ramp_width, shoe_thickness, landing_underframe_id, return_assembly_id, material, variation, semantic)
		add_stair_carriage_shoe(blueprint, return_upper_shoe_id, return_upper_shoe_center, ramp_width, shoe_thickness, exit_underframe_id, return_assembly_id, material, variation, semantic)


static func add_stair_landing_frame(blueprint, frame_id: String, pier_prefix: String, center: Vector3, deck_y: float, width: float, material: String, variation: float, semantic: String) -> void:
	# Edge posts carry the transverse frame without filling the lower-level
	# landing with a full-width pier. Both real seats are declared explicitly.
	var height := maxf(0.20, deck_y - 0.28)
	var seats: Array[String] = []
	var facts: Array[Dictionary] = []
	for side in [-1.0, 1.0]:
		var offset: float = side * (width * 0.5 + 0.06)
		var seat_id := "%s_%d" % [pier_prefix, int(side)]
		seats.append(seat_id)
		add_part(blueprint, seat_id, "foundation", "stone_foundation", Vector3(center.x + offset, height * 0.5, center.z), Vector3(0.24, height, 0.30), {"variation": variation - 0.028, "semantic": "%s_stair_bearing_pier" % semantic, "physicalAssemblyRole": "stair_bearing_pier"})
		facts.append({"seatId": seat_id, "loadDirection": "world_down", "localPatchCenter": Vector3(offset, -0.09, 0.0), "localPatchHalfExtents": Vector2(0.06, 0.08), "seatFace": "max_y"})
	add_part(blueprint, frame_id, "beam", material, Vector3(center.x, deck_y - 0.19, center.z), Vector3(width + 0.36, 0.18, STAIR_LANDING_DEPTH), {"variation": variation - 0.022, "semantic": "%s_underframe" % semantic, "physicalAssemblyRole": "two_post_landing_underframe", "physicalRequiredSeatPartIds": seats, "physicalRequiredSeatFacts": facts})


static func add_stair_carriage_shoe(blueprint, part_id: String, center: Vector3, width: float, thickness: float, underframe_id: String, assembly_id: String, material: String, variation: float, semantic: String) -> void:
	add_part(blueprint, part_id, "beam", material, center, Vector3(width + 0.08, thickness, 0.56), {"variation": variation - 0.018, "semantic": "%s_stair_carriage_shoe" % semantic, "physicalAssemblyRole": "stair_carriage_bearing_block", "physicalStairAssemblyId": assembly_id, "physicalRequiredSeatPartIds": [underframe_id], "physicalRequiredSeatFacts": [{"seatId": underframe_id, "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -thickness * 0.5, 0.0), "localPatchHalfExtents": Vector2(width * 0.35, 0.10), "seatFace": "max_y"}]})


static func stair_housed_geometry(lower_shoe_center: Vector3, upper_shoe_center: Vector3, thickness: float) -> Dictionary:
	const HOUSED_EMBED_CENTER := 0.14
	const HOUSED_VERTICAL_CENTER := 0.04
	var tangent := (upper_shoe_center - lower_shoe_center).normalized()
	var normal := Vector3(0.0, tangent.z, -tangent.y).normalized()
	if normal.y < 0.0:
		normal = -normal
	var lateral := normal.cross(tangent).normalized()
	var lower_endpoint := lower_shoe_center - tangent * HOUSED_EMBED_CENTER - normal * HOUSED_VERTICAL_CENTER
	var upper_endpoint := upper_shoe_center + tangent * HOUSED_EMBED_CENTER - normal * HOUSED_VERTICAL_CENTER
	return {"center": (lower_endpoint + upper_endpoint) * 0.5 + normal * (thickness * 0.5), "length": lower_endpoint.distance_to(upper_endpoint), "rotation": Basis(lateral, normal, tangent).get_euler(), "housedEmbedCenter": HOUSED_EMBED_CENTER, "housedOverlapHalfExtents": Vector3(0.20, 0.021, 0.061)}


static func stair_housed_joint_fact(shoe_id: String, end_sign: float, geometry: Dictionary) -> Dictionary:
	var length := float(geometry.get("length", 0.0))
	var embed_center := float(geometry.get("housedEmbedCenter", 0.14))
	return {"seatId": shoe_id, "contactMode": "housed_overlap", "localOverlapCenter": Vector3(0.0, -0.05, end_sign * (length * 0.5 - embed_center)), "localOverlapHalfExtents": geometry.get("housedOverlapHalfExtents", Vector3(0.20, 0.021, 0.061)), "minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04}


static func add_crenellations(blueprint, prefix: String, center: Vector3, width: float, depth: float, y: float, variation: float) -> void:
	var unit := 1.18
	var x_count := maxi(2, ceili(width / unit))
	var z_count := maxi(2, ceili(depth / unit))
	for index in range(x_count):
		var x := center.x - width * 0.5 + width * (float(index) + 0.5) / float(x_count)
		add_part(blueprint, "%s_front_%d" % [prefix, index], "beam", "stone_foundation", Vector3(x, y, center.z - depth * 0.5), Vector3(width / float(x_count) * 0.54, 0.58, 0.54), {"variation": variation, "semantic": "castle_battlement"})
		add_part(blueprint, "%s_back_%d" % [prefix, index], "beam", "stone_foundation", Vector3(x, y, center.z + depth * 0.5), Vector3(width / float(x_count) * 0.54, 0.58, 0.54), {"variation": variation, "semantic": "castle_battlement"})
	for index in range(z_count):
		var z := center.z - depth * 0.5 + depth * (float(index) + 0.5) / float(z_count)
		add_part(blueprint, "%s_left_%d" % [prefix, index], "beam", "stone_foundation", Vector3(center.x - width * 0.5, y, z), Vector3(0.54, 0.58, depth / float(z_count) * 0.54), {"variation": variation, "semantic": "castle_battlement"})
		add_part(blueprint, "%s_right_%d" % [prefix, index], "beam", "stone_foundation", Vector3(center.x + width * 0.5, y, z), Vector3(0.54, 0.58, depth / float(z_count) * 0.54), {"variation": variation, "semantic": "castle_battlement"})


static func add_part(blueprint, part_id: String, kind: String, material: String, position: Vector3, size: Vector3, options: Dictionary = {}) -> BuildingPart:
	var resolved_material := material
	var semantic := String(options.get("semantic", kind))
	if kind == "window" and material == "window_glass" and (semantic.contains("palace") or semantic.contains("occupied") or semantic.contains("gallery")):
		var window_phase := posmod(part_id.hash(), 7)
		if window_phase in [0, 2, 3]:
			resolved_material = "window_warm_glass"
	return LandmarkBuildingBlueprintBuilderScript.add_part(blueprint, part_id, kind, resolved_material, position, size, options)
