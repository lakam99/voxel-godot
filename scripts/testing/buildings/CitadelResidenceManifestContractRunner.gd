extends SceneTree

## A focused data contract. It proves deterministic bed-to-citizen manifests
## from the shared castle and furnishing grammar; it does not prove physics,
## player traversal, door use, scheduling, or visual behaviour.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const CitadelResidenceManifestBuilderScript := preload("res://scripts/buildings/CitadelResidenceManifestBuilder.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")

const SEEDS: Array[int] = [208158, 208159, 306701]

var failures: Array[String] = []
var report_path := ""


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/citadel-residence-manifest-contract.json")
	var rows: Array[Dictionary] = []
	for seed in SEEDS:
		rows.append(verify_seed(seed))
	var report := {
		"runnerId": "citadel_residence_manifest_contract",
		"evidenceLevel": "contract",
		"scope": "Deterministic semantic residences, bed assignments and published-door identifiers. It does not prove NPC physics, live pathfinding, player movement or visual gameplay.",
		"seeds": SEEDS,
		"passed": failures.is_empty(),
		"rows": rows,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func verify_seed(seed: int) -> Dictionary:
	var castle = CastleCompoundBlueprintBuilderScript.build(seed, {
		"biome": "forest",
		"siteKey": "citadel-life-contract",
		"citadelScale": 1.25
	})
	var furnishing_seed := seed * 7919 + 37
	var furnishing = CastleFurnishingPlannerScript.build(castle, furnishing_seed)
	var replay_furnishing = CastleFurnishingPlannerScript.build(castle, furnishing_seed)
	var manifest := CitadelResidenceManifestBuilderScript.build(castle, furnishing)
	var replay := CitadelResidenceManifestBuilderScript.build(castle, replay_furnishing)
	check(
		CitadelResidenceManifestBuilderScript.deterministic_signature(manifest) == CitadelResidenceManifestBuilderScript.deterministic_signature(replay),
		"seed %d residence manifest did not replay deterministically" % seed
	)
	var source_bed_ids := {}
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
	var seen_citizens := {}
	var assigned_bed_ids := {}
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
		check(home_cell.x >= interior_min.x and home_cell.x <= interior_max.x and home_cell.y >= interior_min.y and home_cell.y <= interior_max.y, "seed %d citizen %s has home cell outside strict interior bounds" % [seed, id])
		check(home_cell != door_cell, "seed %d citizen %s stands on the home door cell" % [seed, id])
		check(String(citizen.get("doorPortalId", "")).begins_with("building:%s:castle_" % String(castle.id)), "seed %d citizen %s has a portal id that cannot be produced by BuildingPartPublisher" % [seed, id])
	check(assigned_bed_ids.size() == source_bed_ids.size(), "seed %d assigned %d citizens to %d semantic beds" % [seed, assigned_bed_ids.size(), source_bed_ids.size()])
	return {
		"seed": seed,
		"castleParts": castle.parts.size(),
		"furnishingParts": furnishing.parts.size(),
		"residenceCount": (manifest.get("residences", []) as Array).size(),
		"bedCount": source_bed_ids.size(),
		"citizenCount": (manifest.get("citizens", []) as Array).size()
	}


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
