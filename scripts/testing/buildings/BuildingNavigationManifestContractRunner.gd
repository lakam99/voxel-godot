extends SceneTree

## Focused VOX-223 source contract.  It proves that the construction blueprint
## produces deterministic, source-addressable walkable supports and physical
## stair links.  It deliberately does not claim live NPC movement or navmesh
## traversal; the Citadel Life fixture remains that evidence level.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")

const SEEDS: Array[int] = [208158, 208159, 306701]

var failures: Array[String] = []
var report_path := ""


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_BUILDING_NAVIGATION_MANIFEST_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/building-navigation-manifest-contract.json")
	var rows: Array[Dictionary] = []
	for seed in SEEDS:
		rows.append(verify_seed(seed))
	var report := {
		"runnerId": "building_navigation_manifest_contract",
		"evidenceLevel": "contract",
		"scope": "Deterministic BuildingPart-derived support and stair-link facts for layered buildings. It does not prove NavMesh installation, CharacterBody3D movement, doors, or live Citadel Life behavior.",
		"seeds": SEEDS,
		"passed": failures.is_empty(),
		"rows": rows,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func verify_seed(seed: int) -> Dictionary:
	var context := {
		"biome": "forest",
		"siteKey": "building-navigation-contract",
		"citadelScale": 1.25
	}
	var first_blueprint = CastleCompoundBlueprintBuilderScript.build(seed, context)
	var replay_blueprint = CastleCompoundBlueprintBuilderScript.build(seed, context)
	var parent_transform := Transform3D(Basis.from_euler(Vector3(0.0, 0.37, 0.0)), Vector3(13.0, 2.5, -7.0))
	var manifest := BuildingNavigationManifestBuilderScript.build(first_blueprint, parent_transform)
	var replay := BuildingNavigationManifestBuilderScript.build(replay_blueprint, parent_transform)
	check(JSON.stringify(manifest) == JSON.stringify(replay), "seed %d navigation manifest is not deterministic" % seed)
	var source_ids := {}
	for id_value in manifest.get("sourcePartIds", []):
		source_ids[String(id_value)] = true
	var supports: Array = manifest.get("supports", []) as Array
	var links: Array = manifest.get("verticalLinks", []) as Array
	check(not supports.is_empty(), "seed %d published no walkable building supports" % seed)
	check(not links.is_empty(), "seed %d published no physical stair/ramp links" % seed)
	check(int(manifest.get("supportCount", -1)) == supports.size(), "seed %d support count disagrees with support facts" % seed)
	check(int(manifest.get("verticalLinkCount", -1)) == links.size(), "seed %d link count disagrees with link facts" % seed)
	var support_ids := {}
	var elevations := {}
	for support_value in supports:
		if not (support_value is Dictionary):
			check(false, "seed %d has malformed support fact" % seed)
			continue
		var support: Dictionary = support_value
		var support_id := String(support.get("id", ""))
		var source_part_id := String(support.get("sourceCollisionPartId", ""))
		check(not support_id.is_empty() and not support_ids.has(support_id), "seed %d has missing/duplicate support id %s" % [seed, support_id])
		check(source_ids.has(source_part_id), "seed %d support %s does not cite a collision source part" % [seed, support_id])
		check((support.get("polygon", []) as Array).size() >= 3, "seed %d support %s lacks a physical top polygon" % [seed, support_id])
		var normal: Vector3 = support.get("floorNormal", Vector3.ZERO) as Vector3
		check(normal.y >= 0.68, "seed %d support %s is not physically walkable" % [seed, support_id])
		var position: Vector3 = support.get("worldPosition", Vector3.ZERO) as Vector3
		elevations[roundi(position.y * 10.0)] = true
		support_ids[support_id] = true
	check(elevations.size() >= 3, "seed %d did not expose multiple physical walkable elevations" % seed)
	for link_value in links:
		if not (link_value is Dictionary):
			check(false, "seed %d has malformed vertical link" % seed)
			continue
		var link: Dictionary = link_value
		var link_id := String(link.get("id", ""))
		var source_part_id := String(link.get("sourceCollisionPartId", ""))
		var start: Vector3 = link.get("start", Vector3.ZERO) as Vector3
		var end: Vector3 = link.get("end", Vector3.ZERO) as Vector3
		check(not link_id.is_empty(), "seed %d has an unnamed vertical link" % seed)
		check(source_ids.has(source_part_id), "seed %d vertical link %s does not cite a collision source part" % [seed, link_id])
		check(end.y > start.y + 0.10, "seed %d vertical link %s is not an ascending physical ramp" % [seed, link_id])
	return {
		"seed": seed,
		"blueprintParts": first_blueprint.parts.size() if first_blueprint != null else 0,
		"supportCount": supports.size(),
		"verticalLinkCount": links.size(),
		"supportElevationCount": elevations.size()
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
