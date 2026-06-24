extends Node
class_name StorySitePlacement

const SITE_VERSION := 1
const MIN_SITE_SEPARATION_CELLS := 8
const WATER_MARGIN := 1.2
const MAX_LOCAL_VARIATION := 2.4

const SITE_DEFINITIONS := [
    {
        "id": "ordinary_antler_scars",
        "kind": "clue",
        "clueKind": "ordinary",
        "label": "Pale antler scars",
        "prompt": "Inspect pale scars",
        "textId": "story.gloam_hart.clue.antler_scars"
    },
    {
        "id": "ordinary_ringing_stone",
        "kind": "clue",
        "clueKind": "ordinary",
        "label": "Ringing boundary stone",
        "prompt": "Listen to the stone",
        "textId": "story.gloam_hart.clue.ringing_stone"
    },
    {
        "id": "ordinary_broken_lantern",
        "kind": "clue",
        "clueKind": "ordinary",
        "label": "Broken lantern frame",
        "prompt": "Study the lantern",
        "textId": "story.gloam_hart.clue.broken_lantern"
    },
    {
        "id": "historical_old_compact",
        "kind": "clue",
        "clueKind": "historical",
        "label": "Old compact record",
        "prompt": "Read the old record",
        "textId": "story.gloam_hart.clue.old_compact"
    },
    {
        "id": "boundary_stone_north",
        "kind": "boundary_stone",
        "label": "North boundary stone",
        "prompt": "Examine boundary stone",
        "textId": "story.gloam_hart.boundary_stone.north"
    },
    {
        "id": "boundary_stone_south",
        "kind": "boundary_stone",
        "label": "South boundary stone",
        "prompt": "Examine boundary stone",
        "textId": "story.gloam_hart.boundary_stone.south"
    },
    {
        "id": "encounter_marker",
        "kind": "encounter_marker",
        "label": "Storm-lashed hollow",
        "prompt": "Survey storm hollow",
        "textId": "story.gloam_hart.encounter.locked"
    }
]

var main
var region_generator

func setup(main_node, generator_node) -> void:
    main = main_node
    region_generator = generator_node

func ensure_sites(region_record: Dictionary) -> Array:
    var existing = region_record.get("storySites", [])
    if existing is Array and existing.size() >= SITE_DEFINITIONS.size():
        return existing
    var region_id := String(region_record.get("id", ""))
    var sites := generate_sites(region_record, region_id)
    region_record["storySitesVersion"] = SITE_VERSION
    region_record["storySites"] = sites
    return sites

func generate_sites(region_record: Dictionary, region_id: String) -> Array:
    var result: Array = []
    if region_generator == null:
        return result
    var seed_value := int(region_record.get("seed", region_generator.stable_hash(region_id)))
    var center: Vector2i = region_generator.region_center_cell(region_id)
    for definition in SITE_DEFINITIONS:
        var site := choose_site(definition, region_id, seed_value, center, result)
        if not site.is_empty():
            result.append(site)
    return result

func choose_site(definition: Dictionary, region_id: String, seed_value: int, center: Vector2i, existing_sites: Array) -> Dictionary:
    var region_size := int(region_generator.get("region_cell_size")) if region_generator != null else 280
    var safe_radius := maxi(24, int(float(region_size) * 0.38))
    for attempt in range(160):
        var angle_seed: int = region_generator.stable_hash("%s|%s|%d|angle" % [region_id, definition.get("id", ""), attempt])
        var radius_seed: int = region_generator.stable_hash("%s|%s|%d|radius" % [region_id, definition.get("id", ""), attempt])
        var angle := TAU * float(angle_seed % 10000) / 10000.0
        var radius := float(18 + (radius_seed % safe_radius))
        var cell := center + Vector2i(roundi(cos(angle) * radius), roundi(sin(angle) * radius))
        if is_site_valid(cell, existing_sites):
            return make_site(definition, region_id, seed_value, cell)
    return make_site(definition, region_id, seed_value, center)

func make_site(definition: Dictionary, region_id: String, seed_value: int, cell: Vector2i) -> Dictionary:
    var site_id := String(definition.get("id", "site"))
    var y := terrain_height(cell)
    return {
        "schemaVersion": 1,
        "id": "%s:%s" % [region_id, site_id],
        "definitionId": site_id,
        "kind": String(definition.get("kind", "")),
        "clueKind": String(definition.get("clueKind", "")),
        "label": String(definition.get("label", "")),
        "prompt": String(definition.get("prompt", "Inspect")),
        "textId": String(definition.get("textId", "")),
        "regionId": region_id,
        "cell": [cell.x, cell.y],
        "worldY": y,
        "placementSeed": region_generator.stable_hash("%s|%s|%d" % [region_id, site_id, seed_value])
    }

func is_site_valid(cell: Vector2i, existing_sites: Array) -> bool:
    if main == null:
        return true
    if terrain_height(cell) <= water_level() + WATER_MARGIN:
        return false
    if String(main.biome_at_cell(cell.x, cell.y)) in ["ocean", "beach", "town"]:
        return false
    var town_region: Dictionary = main.town_region_at_cell(cell.x, cell.y)
    if not town_region.is_empty():
        return false
    if main.height_variation_cell(cell.x, cell.y, 2) > MAX_LOCAL_VARIATION:
        return false
    if not nearby_reachable(cell):
        return false
    for site_value in existing_sites:
        if not (site_value is Dictionary):
            continue
        var other_cell := site_cell(site_value)
        var other_2d := Vector2(float(other_cell.x), float(other_cell.y))
        var cell_2d := Vector2(float(cell.x), float(cell.y))
        if other_2d.distance_to(cell_2d) < float(MIN_SITE_SEPARATION_CELLS):
            return false
    return true

func nearby_reachable(cell: Vector2i) -> bool:
    if main == null:
        return true
    for dz in range(-2, 3):
        for dx in range(-2, 3):
            var sample := cell + Vector2i(dx, dz)
            if terrain_height(sample) <= water_level() + WATER_MARGIN:
                continue
            if String(main.biome_at_cell(sample.x, sample.y)) in ["ocean", "beach"]:
                continue
            return true
    return false

func site_cell(site: Dictionary) -> Vector2i:
    var cell_value = site.get("cell", [])
    if cell_value is Array and cell_value.size() >= 2:
        return Vector2i(int(cell_value[0]), int(cell_value[1]))
    return Vector2i.ZERO

func terrain_height(cell: Vector2i) -> float:
    if main == null:
        return 0.0
    return float(main.terrain_height_cell(cell.x, cell.y))

func water_level() -> float:
    if main == null:
        return 0.0
    return float(main.WATER_LEVEL)
