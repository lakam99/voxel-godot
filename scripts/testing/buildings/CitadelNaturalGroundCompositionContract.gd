extends SceneTree

const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Infill = preload("res://scripts/buildings/CivicHouseInfillRecipe.gd")
const Support = preload("res://scripts/buildings/CivicCourtyardSupport.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_CITADEL_NATURAL_GROUND_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var seed := 237207443
	var source = Castle.build(seed, {"biome": "forest", "citadelScale": 1.25, "siteKey": "river-citadel"})
	var result: Dictionary = Urban.compose_prepared(source, seed)
	var blueprint = result.get("blueprint")
	var forbidden: Array = []
	var courtyard_foundations: Array = []
	var courtyard_paving: Array = []
	var building_foundations: Array = []
	var entry_foundations: Array = []
	var interior_floors: Array = []
	var inspected = blueprint if blueprint != null else source
	if inspected != null:
		forbidden = inspected.parts.filter(func(part):
			var id := String(part.id)
			return id.begins_with("castle_terrace_block_") or id.begins_with("castle_terrace_stair_") \
				or id.begins_with("castle_district_") \
				or id.begins_with("urban_street_climb_") or id.begins_with("urban_market_plaza_retaining") \
				or String(part.semantic) in ["castle_inhabited_terrace_block", "castle_terrace_route_wall", "castle_processional_step", "castle_route_terrace_walkway", "castle_route_junction", "citadel_urban_terrace", "citadel_urban_stair"])
		courtyard_foundations = inspected.parts.filter(func(part): return String(part.id).begins_with("castle_compound_foundation_segment_"))
		courtyard_paving = inspected.parts.filter(func(part): return String(part.id).begins_with("castle_compound_paving_segment_"))
		building_foundations = inspected.parts.filter(func(part):
			return String(part.kind) == "foundation" and bool(part.collision_enabled) \
				and String(part.semantic) not in ["castle_courtyard_foundation", "castle_courtyard_paving"] \
				and part.size.y >= 0.40)
		entry_foundations = inspected.parts.filter(func(part): return String(part.id).contains("_entry_foundation"))
		interior_floors = inspected.parts.filter(func(part): return String(part.id).ends_with("_interior_floor"))
	var continuous_grade_platform := courtyard_foundations.size() == 1 and not courtyard_paving.is_empty()
	if continuous_grade_platform:
		var bed = courtyard_foundations[0]
		var paving_area := 0.0
		var paving_geometry_valid := true
		for paving_index in range(courtyard_paving.size()):
			var paving = courtyard_paving[paving_index]
			paving_area += paving.size.x*paving.size.z
			paving_geometry_valid = paving_geometry_valid \
				and paving.recipe.get("continuousGroundCourse") == true \
				and is_equal_approx(paving.position.y + paving.size.y * 0.5, Castle.COURTYARD_GRADE_SURFACE_Y) \
				and paving.position.x-paving.size.x*0.5 >= bed.position.x-bed.size.x*0.5-0.001 \
				and paving.position.x+paving.size.x*0.5 <= bed.position.x+bed.size.x*0.5+0.001 \
				and paving.position.z-paving.size.z*0.5 >= bed.position.z-bed.size.z*0.5-0.001 \
				and paving.position.z+paving.size.z*0.5 <= bed.position.z+bed.size.z*0.5+0.001
			var paving_bounds := Rect2(Vector2(paving.position.x - paving.size.x * 0.5, paving.position.z - paving.size.z * 0.5), Vector2(paving.size.x, paving.size.z))
			for other_index in range(paving_index):
				var other = courtyard_paving[other_index]
				var other_bounds := Rect2(Vector2(other.position.x - other.size.x * 0.5, other.position.z - other.size.z * 0.5), Vector2(other.size.x, other.size.z))
				var overlap := paving_bounds.intersection(other_bounds)
				paving_geometry_valid = paving_geometry_valid and (overlap.size.x <= 0.001 or overlap.size.y <= 0.001)
		continuous_grade_platform = bed.id == "castle_compound_foundation_segment_00" \
			and bed.recipe.get("continuousGroundCourse") == true \
			and is_equal_approx(bed.position.y - bed.size.y * 0.5, 0.0) \
			and paving_geometry_valid and is_equal_approx(paving_area,bed.size.x*bed.size.z)
	var passed := bool(result.get("ready", false)) and blueprint != null and forbidden.is_empty() \
		and continuous_grade_platform and not building_foundations.is_empty()
	var report := {
		"passed": passed,
		"seed": seed,
		"ready": result.get("ready", false),
		"reason": result.get("reason", ""),
		"failure": result.get("structuralCompletionFailure", result.get("civicQuarterFailure", result.get("civicClearanceFailure", result.get("shopFailure", result.get("terminalFoundationFailure", {}))))),
		"forbiddenPartIds": forbidden.map(func(part): return String(part.id)),
		"continuousGradePlatform": continuous_grade_platform,
		"courtyardFoundationRecords": courtyard_foundations.map(func(part): return part.snapshot()),
		"courtyardPavingRecords": courtyard_paving.map(func(part): return part.snapshot()),
		"courtyardFoundationDeclared": courtyard_foundations.map(func(part): return Support.declared(part, 0.62)),
		"courtyardUnderlayCompatible": (courtyard_foundations + courtyard_paving).map(func(part): return Infill.compatible_underlay(part, 0.62)),
		"buildingFoundationCount": building_foundations.size(),
		"entryFoundationRecords": entry_foundations.map(func(part): return part.snapshot()),
		"interiorFloorRecords": interior_floors.map(func(part): return part.snapshot()),
		"partCount": blueprint.parts.size() if blueprint != null else 0,
		"evidenceLevel": "full_source_composition_contract",
		"doesNotProve": "No publication, rendered appearance, world-space terrain contact, routing, navigation or gameplay acceptance."
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.close()
	quit(0 if passed else 1)


static func _json(value: Variant) -> Variant:
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return [value.x, value.y]
	if value is AABB or value is Rect2:
		return {"position": _json(value.position), "size": _json(value.size)}
	if value is float and not is_finite(value):
		return str(value)
	if value is Object:
		return str(value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _json(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json(item))
	return value
