extends SceneTree

## Unheaded producer contract for the procedural short-house course rule.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")

func _initialize() -> void:
	var path := OS.get_environment("VOXEL_COURSE_BREAK_REPORT").simplify_path()
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2); return
	var seed := int(OS.get_environment("VOXEL_COURSE_BREAK_SEED"))
	if seed == 0: seed = 208159
	var source = Castle.build(seed, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	var report := {"passed": false, "reason": "castle_build_failed"}
	if source != null:
		var grammar: Dictionary = source.recipe.get("castleGrammar", {})
		var foundation_height := float(source.recipe.get("foundationHeight", 0.62))
		var courtyard_depth := float(grammar.get("courtyardDepth", 84.0))
		var keep_depth := float(grammar.get("keepDepth", 28.0))
		var keep_center_z := courtyard_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14))
		var keep_front_z := keep_center_z - keep_depth * 0.5
		var front_z := -courtyard_depth * 0.5
		var layout := Urban.sample_urban_layout(seed, grammar, front_z, keep_front_z, foundation_height)
		source.recipe[Manifest.KEY] = {}
		Urban.add_street_sequence(source, front_z, keep_front_z, foundation_height, 0.0, layout)
		Urban.add_civic_quarter(source, front_z, keep_front_z, foundation_height, 0.0, layout)
		var declarations: Dictionary = source.recipe.get("facadeApertures", {})
		var terrace: Dictionary = declarations.get("urban_row_03_right_upper_facade", {})
		var civic: Dictionary = declarations.get("urban_civic_house_east_upper_facade", {})
		var terrace_bottom := float((terrace.get("wallDomain", AABB()) as AABB).position.y)
		var civic_bottom := float((civic.get("wallDomain", AABB()) as AABB).position.y)
		var terrace_ground := _foundation_top(source, "urban_row_03_right_foundation")
		var civic_ground := _foundation_top(source, "urban_civic_house_east_foundation")
		var sill_height := 2.75 - 1.46 * 0.5
		var terrace_local_height := terrace_bottom - terrace_ground
		var civic_local_height := civic_bottom - civic_ground
		var checks := {
			"terrace_party_wall_course_retained": not terrace.is_empty() and terrace_local_height < sill_height - 0.01,
			"standalone_civic_home_keeps_regular_base_course": not civic.is_empty() and civic_local_height > sill_height + 0.01,
			"producer_manifest_remains_valid": Manifest.read(source).get("ready", false),
			"malformed_late_commit_record_rejected_atomically": _late_record_rejected_atomically()}
		report = {"passed": checks.values().all(func(value): return value == true), "checks": checks,
			"terraceLocalHeight": terrace_local_height, "civicLocalHeight": civic_local_height, "sillHeight": sill_height, "seed": seed,
			"scope": "Procedural source proportions only; no structural completion, publication, rendering, gameplay or headed claim."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "\t")); file.close()
	quit(0 if report.passed else 1)

func _foundation_top(source, id: String) -> float:
	for part in source.parts:
		if part.id == id:
			return source.transformed_part_bounds(part).end.y
	return INF

func _late_record_rejected_atomically() -> bool:
	var fixture = Blueprint.new("late-record-atomic", 7, "citadel")
	fixture.rooms = [{"id": "room"}]
	fixture.recipe = {"kind": "atomic_control"}
	fixture.add_part({"id": "first", "kind": "wall", "material": "stone_foundation", "position": Vector3.ZERO,
		"size": Vector3.ONE, "collision": true, "semantic": "control", "physicalIntent": "structural_root"})
	fixture.add_part({"id": "last", "kind": "wall", "material": "stone_foundation", "position": Vector3.ONE,
		"size": Vector3.ONE, "collision": true, "semantic": "control", "physicalIntent": "structural_root"})
	var frozen := var_to_bytes(fixture.snapshot())
	var malformed: Dictionary = fixture.snapshot()
	malformed.parts[1]["size"] = "malformed_late_size"
	var result := Urban._commit_structural_completion(fixture, malformed)
	return not result.get("ready", false) and result.get("reason") == "invalid_structural_completion_part_inventory" \
		and frozen == var_to_bytes(fixture.snapshot())
