extends RefCounted
class_name StructureSystem

const StructureDoorRulesScript := preload("res://scripts/StructureDoorRules.gd")
const StructureLootScript := preload("res://scripts/StructureLoot.gd")
const CAVE_SPAWN_CHANCE := 0.18
const CAVE_SEARCH_ATTEMPTS := 72
const CAVE_CLIFF_VARIATION_MIN := 1.15
const CAVE_UNDERGROUND_VARIATION_MAX := 1.95

var main
var loot
var generated_towns := {}
var generated_structures := {}
var generated_caves := {}
var generated_building_count := 0
var generated_town_count := 0
var generated_mine_count := 0
var generated_ruin_count := 0
var generated_shrine_count := 0
var generated_camp_count := 0
var generated_cave_count := 0
var generated_path_count := 0
var generated_door_count := 0
var generated_utility_count := 0
var town_home_records := {}
var cave_records := {}

func setup(main_node) -> void:
    main = main_node
    loot = StructureLootScript.new()

func reset() -> void:
    generated_towns.clear()
    generated_structures.clear()
    generated_caves.clear()
    generated_building_count = 0
    generated_town_count = 0
    generated_mine_count = 0
    generated_ruin_count = 0
    generated_shrine_count = 0
    generated_camp_count = 0
    generated_cave_count = 0
    generated_path_count = 0
    generated_door_count = 0
    generated_utility_count = 0
    town_home_records.clear()
    cave_records.clear()

func update_around(center_cell: Vector2i) -> void:
    if main == null:
        return
    update_towns(center_cell)
    update_standalone_structures(center_cell)
    update_caves(center_cell)

func update_towns(center_cell: Vector2i) -> void:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.TOWN_REGION_CELLS)), floori(float(center_cell.y) / float(main.TOWN_REGION_CELLS)))
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_towns.has(key):
                continue
            var town: Dictionary = main.town_region(rx, rz)
            if town.is_empty():
                continue
            var distance := Vector2(float(center_cell.x - int(town["centerX"])), float(center_cell.y - int(town["centerZ"]))).length()
            var active_render_distance: int = int(main.get("render_distance"))
            if active_render_distance <= 0:
                active_render_distance = main.RENDER_DISTANCE
            var activation_range: float = float(main.TOWN_RADIUS_CELLS + main.CHUNK_SIZE * active_render_distance + 20)
            if distance > activation_range:
                continue
            generated_towns[key] = true
            build_town(town)

func update_standalone_structures(center_cell: Vector2i) -> void:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.STRUCTURE_REGION_CELLS)), floori(float(center_cell.y) / float(main.STRUCTURE_REGION_CELLS)))
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_structures.has(key):
                continue
            var roll: float = main.hash01("structure:%d,%d" % [rx, rz])
            if roll > main.STRUCTURE_SPAWN_CHANCE:
                continue
            var rng := RandomNumberGenerator.new()
            rng.seed = main.hash_string("%s:structure:%d,%d" % [main.seed_text, rx, rz])
            var base_x: int = rx * main.STRUCTURE_REGION_CELLS + rng.randi_range(16, main.STRUCTURE_REGION_CELLS - 18)
            var base_z: int = rz * main.STRUCTURE_REGION_CELLS + rng.randi_range(16, main.STRUCTURE_REGION_CELLS - 18)
            var structure_type := standalone_structure_type(rng)
            var dimensions := structure_dimensions_for_type(structure_type, rng)
            var level := flat_level_for_footprint(base_x, base_z, dimensions.x, dimensions.y)
            if is_nan(level):
                generated_structures[key] = false
                continue
            generated_structures[key] = true
            if structure_type == "mine":
                build_mine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "ruin":
                build_ruin(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "shrine":
                build_shrine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "camp":
                build_camp(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            else:
                var wall_type := "woodBlock" if rng.randf() < 0.5 else "stoneBlock"
                var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
                build_building(base_x, base_z, level, dimensions.x, dimensions.y, rng.randi_range(4, 5), wall_type, roof_type, rng.randi_range(0, 3), rng, false)

func update_caves(center_cell: Vector2i) -> void:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.STRUCTURE_REGION_CELLS)), floori(float(center_cell.y) / float(main.STRUCTURE_REGION_CELLS)))
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_caves.has(key):
                continue
            var plan := cave_plan_for_region(rx, rz, "", true)
            if plan.is_empty():
                generated_caves[key] = false
                continue
            generated_caves[key] = true
            var rng := RandomNumberGenerator.new()
            rng.seed = main.hash_string("%s:cave-build:%d,%d" % [main.seed_text, rx, rz])
            build_cave(plan, rng)

func cave_plan_for_region(region_x: int, region_z: int, preferred_kind := "", require_spawn_roll := true) -> Dictionary:
    if main == null:
        return {}
    if require_spawn_roll:
        var roll: float = main.hash01("cave:%d,%d" % [region_x, region_z])
        if roll > CAVE_SPAWN_CHANCE:
            return {}
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:cave:%d,%d" % [main.seed_text, region_x, region_z])
    var kind := preferred_kind.strip_edges().to_lower()
    if kind == "":
        kind = "cliff" if rng.randf() < 0.76 else "underground"
    var plan := best_cave_plan_candidate(region_x, region_z, kind, rng)
    if plan.is_empty() and kind == "cliff":
        rng.seed = main.hash_string("%s:cave-underground-fallback:%d,%d" % [main.seed_text, region_x, region_z])
        plan = best_cave_plan_candidate(region_x, region_z, "underground", rng)
    return plan

func find_cave_plan_sample(preferred_kind := "", search_radius_regions := 8, require_spawn_roll := false) -> Dictionary:
    var best_plan := {}
    var best_score := INF
    for rz in range(-search_radius_regions, search_radius_regions + 1):
        for rx in range(-search_radius_regions, search_radius_regions + 1):
            var plan := cave_plan_for_region(rx, rz, preferred_kind, require_spawn_roll)
            if plan.is_empty():
                continue
            var distance_score := Vector2(float(rx), float(rz)).length()
            var plan_score: float = distance_score + main.hash01("cave-sample:%d,%d:%s" % [rx, rz, String(plan.get("kind", ""))])
            if plan_score < best_score:
                best_score = plan_score
                best_plan = plan
    return best_plan

func best_cave_plan_candidate(region_x: int, region_z: int, kind: String, rng: RandomNumberGenerator) -> Dictionary:
    var best := {}
    var best_score := -INF
    var region_size := int(main.STRUCTURE_REGION_CELLS)
    var margin := 18
    for attempt in range(CAVE_SEARCH_ATTEMPTS):
        var entrance_x := region_x * region_size + rng.randi_range(margin, region_size - margin)
        var entrance_z := region_z * region_size + rng.randi_range(margin, region_size - margin)
        var entrance := Vector2i(entrance_x, entrance_z)
        var height := float(main.terrain_height_cell(entrance.x, entrance.y))
        if height <= float(main.WATER_LEVEL) + 2.4:
            continue
        var variation := float(main.height_variation_cell(entrance.x, entrance.y, 3)) / float(main.CELL)
        if kind == "cliff" and variation < CAVE_CLIFF_VARIATION_MIN:
            continue
        if kind == "underground" and variation > CAVE_UNDERGROUND_VARIATION_MAX:
            continue
        var side := rng.randi_range(0, 3)
        var path_length := rng.randi_range(14, 20)
        var chamber_radius := rng.randi_range(3, 4)
        var score := height * 0.12 + variation * (4.0 if kind == "cliff" else -2.0) - float(attempt) * 0.01
        if kind == "underground":
            score += maxf(0.0, 2.0 - variation) * 2.0
        if score <= best_score:
            continue
        best_score = score
        best = make_cave_plan(region_x, region_z, entrance, side, path_length, chamber_radius, kind, height, variation)
    return best

func make_cave_plan(region_x: int, region_z: int, entrance: Vector2i, side: int, path_length: int, chamber_radius: int, kind: String, level: float, entrance_variation: float) -> Dictionary:
    var inward := inward_for_side(side)
    var right := Vector2i(-inward.y, inward.x)
    var approach_cells: Array[Vector2i] = []
    var tunnel_cells: Array[Vector2i] = []
    var chamber_cells: Array[Vector2i] = []
    for z in range(-5, 0):
        for x in range(-1, 2):
            approach_cells.append(entrance + right * x + inward * z)
    for z in range(0, path_length + 1):
        for x in range(-1, 2):
            tunnel_cells.append(entrance + right * x + inward * z)
    var chamber_center := entrance + inward * (path_length + chamber_radius)
    for dz in range(-chamber_radius, chamber_radius + 1):
        for dx in range(-chamber_radius, chamber_radius + 1):
            if Vector2(float(dx), float(dz)).length() <= float(chamber_radius) + 0.25:
                chamber_cells.append(chamber_center + right * dx + inward * dz)
    var chest_cell := chamber_center + inward * maxi(1, chamber_radius - 1)
    var id := "cave:%d,%d:%d,%d" % [region_x, region_z, entrance.x, entrance.y]
    return {
        "id": id,
        "region": Vector2i(region_x, region_z),
        "kind": kind,
        "entranceSide": side,
        "entranceCell": entrance,
        "inward": inward,
        "right": right,
        "level": level,
        "entranceVariation": entrance_variation,
        "pathLength": path_length,
        "chamberRadius": chamber_radius,
        "approachCells": approach_cells,
        "pathCells": tunnel_cells,
        "chamberCells": chamber_cells,
        "finalChamberCell": chamber_center,
        "finalChestCell": chest_cell
    }

func inward_for_side(side: int) -> Vector2i:
    if side == 0:
        return Vector2i(0, -1)
    if side == 1:
        return Vector2i(-1, 0)
    if side == 2:
        return Vector2i(0, 1)
    return Vector2i(1, 0)

func standalone_structure_type(rng: RandomNumberGenerator) -> String:
    var roll := rng.randf()
    if roll < 0.12:
        return "shrine"
    if roll < 0.32:
        return "mine"
    if roll < 0.58:
        return "ruin"
    if roll < 0.74:
        return "camp"
    return "cabin"

func structure_dimensions_for_type(structure_type: String, rng: RandomNumberGenerator) -> Vector2i:
    if structure_type == "shrine":
        return Vector2i(9, 9)
    if structure_type == "mine":
        return Vector2i(rng.randi_range(10, 12), rng.randi_range(12, 14))
    if structure_type == "camp":
        return Vector2i(rng.randi_range(11, 13), rng.randi_range(10, 12))
    return Vector2i(rng.randi_range(7, 10), rng.randi_range(7, 10))

func build_town(town: Dictionary) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:town-build:%d,%d" % [main.seed_text, int(town["regionX"]), int(town["regionZ"])])
    var center_x := int(town["centerX"])
    var center_z := int(town["centerZ"])
    var level := float(town["level"])
    var town_key := town_key_for(town)
    town_home_records[town_key] = []
    generated_town_count += 1
    build_town_paths(center_x, center_z, int(town["radius"]), level)
    build_town_perimeter(center_x, center_z, int(town["radius"]), level, town_key)
    var desired_home_count := town_home_count(town)
    var sites := town_home_sites(town, rng)
    var built_home_count := 0
    for i in range(sites.size()):
        if built_home_count >= desired_home_count:
            break
        var site: Dictionary = sites[i]
        var base_x := center_x + int(site["dx"])
        var base_z := center_z + int(site["dz"])
        var side := int(site["side"])
        if town_home_site_excluded(town, base_x, base_z, 10, 10, side):
            continue
        var width := rng.randi_range(7, 9)
        var depth := rng.randi_range(7, 9)
        var wall_height := rng.randi_range(4, 5)
        var wall_type := "woodBlock" if i % 2 == 0 else "stoneBlock"
        if rng.randf() < 0.35:
            wall_type = "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        if town_home_site_excluded(town, base_x, base_z, width, depth, side):
            continue
        build_building(base_x, base_z, level, width, depth, wall_height, wall_type, roof_type, side, rng, true)
        record_town_home(town_key, town, base_x, base_z, width, depth, side, built_home_count)
        built_home_count += 1
    build_town_market(center_x, center_z, level, rng)
    place_utility(center_x - 2, center_z + 1, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "town"),
        "generatedTier": "town",
        "cacheKey": "%s:town-cache:%d,%d" % [main.seed_text, center_x, center_z]
    })
    place_utility(center_x + 2, center_z + 1, level, "furnace")
    place_utility(center_x, center_z - 3, level, "workbench")

func build_town_paths(center_x: int, center_z: int, radius: int, level: float) -> void:
    var path_span: int = max(10, radius - 2)
    for offset in range(-path_span, path_span + 1):
        place_path(center_x + offset, center_z, level)
        place_path(center_x, center_z + offset, level)
        if offset % 4 == 0:
            place_path(center_x + offset, center_z + 1, level)
            place_path(center_x + 1, center_z + offset, level)

func town_home_count(town: Dictionary) -> int:
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var extra_from_radius: int = clampi(floori(float(radius - main.TOWN_RADIUS_CELLS) * 0.75), 0, 7)
    var bonus := int(main.hash01("town-home-count:%d,%d" % [int(town.get("regionX", 0)), int(town.get("regionZ", 0))]) * 3.0)
    return clampi(4 + extra_from_radius + bonus, 4, 12)

func town_home_sites(town: Dictionary, _rng: RandomNumberGenerator) -> Array:
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var candidates := [
        { "dx": -16, "dz": -13, "side": 2 },
        { "dx": 8, "dz": -14, "side": 2 },
        { "dx": -17, "dz": 8, "side": 0 },
        { "dx": 9, "dz": 9, "side": 0 },
        { "dx": -5, "dz": -25, "side": 2 },
        { "dx": 22, "dz": -4, "side": 1 },
        { "dx": -29, "dz": -4, "side": 3 },
        { "dx": -5, "dz": 20, "side": 0 },
        { "dx": 18, "dz": 18, "side": 0 },
        { "dx": -24, "dz": 18, "side": 0 },
        { "dx": 18, "dz": -24, "side": 2 },
        { "dx": -24, "dz": -24, "side": 2 }
    ]
    var sites := []
    for candidate_value in candidates:
        var candidate: Dictionary = candidate_value
        var dx := int(candidate.get("dx", 0))
        var dz := int(candidate.get("dz", 0))
        if maxi(absi(dx), absi(dz)) > radius - 4:
            continue
        sites.append(candidate)
    return sites

func town_home_site_excluded(town: Dictionary, base_x: int, base_z: int, width: int, depth: int, door_side: int) -> bool:
    var rings_value = town.get("homeExclusionRings", [])
    if not (rings_value is Array):
        return false
    var min_x := base_x - 1
    var max_x := base_x + width
    var min_z := base_z - 1
    var max_z := base_z + depth
    var door_entries := StructureDoorRulesScript.door_cells(width, depth, door_side)
    for entry_value in door_entries:
        var entry: Dictionary = entry_value
        var door_x := base_x + int(entry.get("x", 0))
        var door_z := base_z + int(entry.get("z", 0))
        if door_side == 0:
            max_z = maxi(max_z, door_z + 1)
        elif door_side == 2:
            min_z = mini(min_z, door_z - 1)
        elif door_side == 1:
            max_x = maxi(max_x, door_x + 1)
        elif door_side == 3:
            min_x = mini(min_x, door_x - 1)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    for ring_value in rings_value:
        if not (ring_value is Dictionary):
            continue
        var ring: Dictionary = ring_value
        var radius := int(ring.get("radius", 0))
        if radius <= 0:
            continue
        var margin := maxi(0, int(ring.get("margin", 0)))
        if rect_intersects_town_ring(min_x, max_x, min_z, max_z, center_x, center_z, radius, margin):
            return true
    return false

func rect_intersects_town_ring(min_x: int, max_x: int, min_z: int, max_z: int, center_x: int, center_z: int, radius: int, margin: int) -> bool:
    var west := center_x - radius
    var east := center_x + radius
    var north := center_z - radius
    var south := center_z + radius
    var min_ring_x := west - margin
    var max_ring_x := east + margin
    var min_ring_z := north - margin
    var max_ring_z := south + margin
    if ranges_intersect(min_z, max_z, north - margin, north + margin) and ranges_intersect(min_x, max_x, min_ring_x, max_ring_x):
        return true
    if ranges_intersect(min_z, max_z, south - margin, south + margin) and ranges_intersect(min_x, max_x, min_ring_x, max_ring_x):
        return true
    if ranges_intersect(min_x, max_x, west - margin, west + margin) and ranges_intersect(min_z, max_z, min_ring_z, max_ring_z):
        return true
    if ranges_intersect(min_x, max_x, east - margin, east + margin) and ranges_intersect(min_z, max_z, min_ring_z, max_ring_z):
        return true
    return false

func ranges_intersect(a_min: int, a_max: int, b_min: int, b_max: int) -> bool:
    return a_min <= b_max and b_min <= a_max

func build_town_perimeter(center_x: int, center_z: int, radius: int, level: float, town_key: String) -> void:
    var gate_cells := {}
    for offset in [0, 1]:
        gate_cells[Vector2i(center_x + offset, center_z - radius)] = { "side": 2, "secondary": offset == 1, "axis": "x" }
        gate_cells[Vector2i(center_x + offset, center_z + radius)] = { "side": 0, "secondary": offset == 1, "axis": "x" }
        gate_cells[Vector2i(center_x - radius, center_z + offset)] = { "side": 3, "secondary": offset == 1, "axis": "z" }
        gate_cells[Vector2i(center_x + radius, center_z + offset)] = { "side": 1, "secondary": offset == 1, "axis": "z" }
    for offset in range(-radius, radius + 1):
        place_town_perimeter_cell(center_x + offset, center_z - radius, level, gate_cells, "x", town_key)
        place_town_perimeter_cell(center_x + offset, center_z + radius, level, gate_cells, "x", town_key)
        place_town_perimeter_cell(center_x - radius, center_z + offset, level, gate_cells, "z", town_key)
        place_town_perimeter_cell(center_x + radius, center_z + offset, level, gate_cells, "z", town_key)

func place_town_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary, axis: String, town_key: String) -> void:
    var cell := Vector2i(cell_x, cell_z)
    if gate_cells.has(cell):
        var gate: Dictionary = gate_cells[cell]
        place_path(cell_x, cell_z, level, { "generatedTier": "town", "cacheKey": "%s:town-gate-path:%s:%d,%d" % [main.seed_text, town_key, cell_x, cell_z] })
        place_door(cell_x, cell_z, level, int(gate.get("side", 0)), bool(gate.get("secondary", false)), "public_gate")
        return
    place_structure_block(cell_x, cell_z, level, 0, "woodBlock", {
        "generatedTier": "town",
        "accentRole": "fencePost",
        "fenceAxis": axis,
        "cacheKey": "%s:town-fence:%s:%d,%d" % [main.seed_text, town_key, cell_x, cell_z]
    })

func build_town_market(center_x: int, center_z: int, level: float, rng: RandomNumberGenerator) -> void:
    var stalls := [
        { "dx": -5, "dz": -5, "facing": PI * 0.5 },
        { "dx": 5, "dz": -5, "facing": -PI * 0.5 },
        { "dx": -5, "dz": 5, "facing": PI * 0.5 },
        { "dx": 5, "dz": 5, "facing": -PI * 0.5 }
    ]
    var count := 2 + rng.randi_range(0, 1)
    for i in range(count):
        var stall: Dictionary = stalls[i]
        place_utility(center_x + int(stall["dx"]), center_z + int(stall["dz"]), level, "traderStall", {
            "facing": float(stall["facing"]),
            "generatedTier": "town"
        })

func town_key_for(town: Dictionary) -> String:
    return "%d,%d" % [int(town.get("centerX", 0)), int(town.get("centerZ", 0))]

func record_town_home(town_key: String, town: Dictionary, base_x: int, base_z: int, width: int, depth: int, door_side: int, index: int) -> void:
    if town_key == "":
        return
    if not town_home_records.has(town_key):
        town_home_records[town_key] = []
    var center_cell := Vector2i(base_x + int(width / 2), base_z + int(depth / 2))
    var home_cell := center_cell
    var porch_cell := home_cell
    var guard_cell := home_cell
    var home_route_cells: Array[Vector2i] = []
    var interior_min_cell := Vector2i(base_x + 1, base_z + 1)
    var interior_max_cell := Vector2i(base_x + width - 2, base_z + depth - 2)
    var door_entries := StructureDoorRulesScript.door_cells(width, depth, door_side)
    if not door_entries.is_empty():
        var entry: Dictionary = door_entries[0]
        var door_cell := Vector2i(base_x + int(entry.get("x", 0)), base_z + int(entry.get("z", 0)))
        var interior_landing := door_cell
        var inward := Vector2i.ZERO
        porch_cell = door_cell
        if door_side == 0:
            porch_cell.y += 1
            guard_cell = Vector2i(porch_cell.x, porch_cell.y + 4)
            inward = Vector2i(0, -1)
        elif door_side == 2:
            porch_cell.y -= 1
            guard_cell = Vector2i(porch_cell.x, porch_cell.y - 4)
            inward = Vector2i(0, 1)
        elif door_side == 1:
            porch_cell.x += 1
            guard_cell = Vector2i(porch_cell.x + 4, porch_cell.y)
            inward = Vector2i(-1, 0)
        else:
            porch_cell.x -= 1
            guard_cell = Vector2i(porch_cell.x - 4, porch_cell.y)
            inward = Vector2i(1, 0)
        interior_landing = door_cell + inward
        home_cell = door_cell + inward * 3
        var lateral := Vector2i(-inward.y, inward.x)
        if lateral != Vector2i.ZERO:
            var center_delta := (center_cell.x - door_cell.x) * lateral.x + (center_cell.y - door_cell.y) * lateral.y
            var lateral_sign := 1 if center_delta >= 0 else -1
            home_cell += lateral * lateral_sign * 2
        interior_landing.x = clampi(interior_landing.x, interior_min_cell.x, interior_max_cell.x)
        interior_landing.y = clampi(interior_landing.y, interior_min_cell.y, interior_max_cell.y)
        home_cell.x = clampi(home_cell.x, interior_min_cell.x, interior_max_cell.x)
        home_cell.y = clampi(home_cell.y, interior_min_cell.y, interior_max_cell.y)
        var exterior_approach := porch_cell - inward
        if exterior_approach != porch_cell:
            home_route_cells.append(exterior_approach)
        home_route_cells.append(porch_cell)
        if interior_landing != porch_cell:
            home_route_cells.append(interior_landing)
        if home_cell != interior_landing:
            home_route_cells.append(home_cell)
    var record := {
        "id": "%s:home:%d" % [town_key, index],
        "townKey": town_key,
        "townCenter": Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))),
        "townRadius": int(town.get("radius", main.TOWN_RADIUS_CELLS)),
        "level": float(town.get("level", 16.0)),
        "homeCell": home_cell,
        "porchCell": porch_cell,
        "guardCell": guard_cell,
        "interiorMinCell": interior_min_cell,
        "interiorMaxCell": interior_max_cell,
        "homeRouteCells": home_route_cells,
        "buildingIndex": index
    }
    town_home_records[town_key].append(record)

func town_home_records_snapshot() -> Dictionary:
    return town_home_records.duplicate(true)

func build_building(base_x: int, base_z: int, level: float, width: int, depth: int, wall_height: int, wall_type: String, roof_type: String, door_side: int, rng: RandomNumberGenerator, town_building: bool) -> void:
    generated_building_count += 1
    var doors := StructureDoorRulesScript.door_cells(width, depth, door_side)
    for dy in range(wall_height):
        for x in range(width):
            for z in range(depth):
                var perimeter := x == 0 or z == 0 or x == width - 1 or z == depth - 1
                if not perimeter:
                    continue
                var door_entry: Dictionary = StructureDoorRulesScript.door_entry_at(doors, x, z)
                if not door_entry.is_empty():
                    if dy == 0:
                        place_door(base_x + x, base_z + z, level, door_side, bool(door_entry.get("secondary", false)))
                    if dy <= 1:
                        continue
                var block_type := wall_type
                var window_line := dy == 2 and door_entry.is_empty() and wall_height >= 4
                var window_axis_match := z % 3 == 1 if (x == 0 or x == width - 1) else x % 3 == 1
                if window_line and window_axis_match:
                    block_type = "glass"
                place_structure_block(base_x + x, base_z + z, level, dy, block_type, wall_visual_options(x, z, width, depth, dy, block_type, wall_type))
    for x in range(-1, width + 1):
        for z in range(-1, depth + 1):
            place_structure_block(base_x + x, base_z + z, level, wall_height, roof_type, roof_visual_options(x, z, width, depth, roof_type))
    place_porch(base_x, base_z, level, width, depth, door_side)
    if town_building and rng.randf() > 0.35:
        place_loot_chest(base_x, base_z, level, width, depth, door_side, rng, "town")
    elif not town_building and rng.randf() > 0.25:
        place_loot_chest(base_x, base_z, level, width, depth, door_side, rng, "cabin")
    if town_building and rng.randf() > 0.55:
        place_utility(base_x + 1, base_z + depth - 2, level, "bed")

func wall_visual_options(x: int, z: int, width: int, depth: int, dy: int, block_type: String, wall_type: String) -> Dictionary:
    var trim_key := "trimStone" if wall_type == "stoneBlock" else "trimWood"
    if block_type == "glass":
        var axis := "x" if (x == 0 or x == width - 1) else "z"
        var side := -1 if (x == 0 or z == 0) else 1
        if axis == "z":
            side = -1 if z == 0 else 1
        return {
            "accentRole": "windowFrame",
            "windowAxis": axis,
            "windowSide": side,
            "windowTrimMaterial": trim_key
        }
    var corner := (x == 0 or x == width - 1) and (z == 0 or z == depth - 1)
    if corner and dy <= 2:
        return {
            "accentRole": "cornerTimber",
            "cornerX": -1 if x == 0 else 1,
            "cornerZ": -1 if z == 0 else 1,
            "cornerTrimMaterial": trim_key
        }
    return {}

func roof_visual_options(x: int, z: int, width: int, depth: int, roof_type: String) -> Dictionary:
    var axis := "x" if width >= depth else "z"
    var cross_value := z if axis == "x" else x
    var cross_min := -1
    var cross_max := depth if axis == "x" else width
    var center := float(cross_min + cross_max) * 0.5
    var distance_to_center := absf(float(cross_value) - center)
    var role := "ridge" if distance_to_center <= 0.52 else "slope"
    var side := -1 if float(cross_value) < center else 1
    var edge_x := 0
    var edge_z := 0
    if x == -1:
        edge_x = -1
    elif x == width:
        edge_x = 1
    if z == -1:
        edge_z = -1
    elif z == depth:
        edge_z = 1
    if edge_x != 0 or edge_z != 0:
        role = "eave" if role != "ridge" else role
    var options := {
        "roofRole": role,
        "roofAxis": axis,
        "roofSide": side,
        "roofMaterial": "roofStone" if roof_type == "stoneBlock" else "roofWood",
        "roofTrimMaterial": "trimStone" if roof_type == "stoneBlock" else "trimWood",
        "roofEdgeX": edge_x,
        "roofEdgeZ": edge_z
    }
    var chimney_x: int = clampi(width - 2, 1, width - 2)
    var chimney_z: int = clampi(2, 1, depth - 2)
    if x == chimney_x and z == chimney_z:
        options["roofAccent"] = "chimney"
    return options

func camp_fence_options(base_options: Dictionary, axis: String) -> Dictionary:
    var options := base_options.duplicate()
    options["accentRole"] = "fencePost"
    options["fenceAxis"] = axis
    options["fenceTrimMaterial"] = "trimWood"
    return options

func build_ruin(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_ruin_count += 1
    var cache_key := "%s:ruin:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "ruin", "cacheKey": cache_key }
    var wall_height := rng.randi_range(2, 5)
    for x in range(width):
        for z in range(depth):
            var edge := x == 0 or z == 0 or x == width - 1 or z == depth - 1
            if not edge:
                continue
            var corner := (x == 0 or x == width - 1) and (z == 0 or z == depth - 1)
            if rng.randf() < (0.14 if corner else 0.42):
                continue
            var height := clampi(1 + rng.randi_range(0, wall_height), 1, wall_height)
            for dy in range(height):
                place_structure_block(base_x + x, base_z + z, level, dy, "stoneBlock", tier_options)
    place_loot_chest(base_x, base_z, level, width, depth, -1, rng, "ruin", cache_key)
    for i in range(rng.randi_range(3, 6)):
        var rubble_x := base_x + rng.randi_range(1, width - 2)
        var rubble_z := base_z + rng.randi_range(1, depth - 2)
        place_structure_block(rubble_x, rubble_z, level, 0, "stoneBlock", tier_options)

func build_camp(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_camp_count += 1
    var cache_key := "%s:camp:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "camp", "cacheKey": cache_key }
    var center_x := int(width / 2)
    var center_z := int(depth / 2)
    for x in range(width):
        for z in range(depth):
            var offset := Vector2(float(x - center_x), float(z - center_z))
            if offset.length() <= 4.2 or x == center_x or z == center_z or rng.randf() > 0.72:
                place_path(base_x + x, base_z + z, level, tier_options)
    for z in range(-5, 0):
        for lane in range(-1, 2):
            place_path(base_x + center_x + lane, base_z + z, level, tier_options)
    place_utility(base_x + center_x, base_z + center_z, level, "campfire", tier_options)
    place_utility(base_x + max(1, center_x - 3), base_z + max(1, center_z - 2), level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "camp"),
        "generatedTier": "camp",
        "cacheKey": cache_key
    })
    var torch_cells := [
        Vector2i(1, 1),
        Vector2i(width - 2, 1),
        Vector2i(1, depth - 2),
        Vector2i(width - 2, depth - 2)
    ]
    for cell in torch_cells:
        place_utility(base_x + cell.x, base_z + cell.y, level, "torch", tier_options)
    for x in range(1, width - 1):
        if x % 3 == 0:
            place_structure_block(base_x + x, base_z, level, 0, "woodBlock", camp_fence_options(tier_options, "x"))
            place_structure_block(base_x + x, base_z + depth - 1, level, 0, "woodBlock", camp_fence_options(tier_options, "x"))
    for z in range(1, depth - 1):
        if z % 3 == 1:
            place_structure_block(base_x, base_z + z, level, 0, "woodBlock", camp_fence_options(tier_options, "z"))
            place_structure_block(base_x + width - 1, base_z + z, level, 0, "woodBlock", camp_fence_options(tier_options, "z"))
    var trap_cells := [
        Vector2i(center_x - 1, -2),
        Vector2i(center_x + 1, -2),
        Vector2i(1, center_z),
        Vector2i(width - 2, center_z)
    ]
    for cell in trap_cells:
        place_utility(base_x + cell.x, base_z + cell.y, level, "spikeTrap", tier_options)

func build_mine(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_mine_count += 1
    var cache_key := "%s:mine:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "mine", "cacheKey": cache_key }
    var center_x := int(width / 2)
    for z in range(depth):
        for x in range(1, width - 1):
            if x == 1 or x == width - 2 or z % 2 == 0:
                place_path(base_x + x, base_z + z, level, tier_options)
    for z in range(-5, 0):
        for lane in range(-1, 2):
            place_path(base_x + center_x + lane, base_z + z, level, tier_options)
    for torch_offset in [Vector2i(center_x - 2, -1), Vector2i(center_x + 2, -1), Vector2i(1, 2), Vector2i(width - 2, 2)]:
        place_structure_block(base_x + torch_offset.x, base_z + torch_offset.y, level, 0, "torch", tier_options)
    for z in range(2, depth):
        for x in [0, width - 1]:
            place_structure_block(base_x + x, base_z + z, level, 0, "stoneBlock", tier_options)
            if z > 4 and z < depth - 1 and rng.randf() > 0.42:
                place_structure_block(base_x + x, base_z + z, level, 1, mine_vein_type(rng), tier_options)
            elif z % 3 == 0:
                place_structure_block(base_x + x, base_z + z, level, 1, "stoneBlock", tier_options)
    for x in range(width):
        place_structure_block(base_x + x, base_z + depth - 1, level, 0, "stoneBlock", tier_options)
        if x > 1 and x < width - 2:
            place_structure_block(base_x + x, base_z + depth - 1, level, 1, mine_vein_type(rng), tier_options)
            if rng.randf() > 0.62:
                place_structure_block(base_x + x, base_z + depth - 1, level, 2, mine_vein_type(rng), tier_options)
        else:
            place_structure_block(base_x + x, base_z + depth - 1, level, 1, "stoneBlock", tier_options)
    for z in [2, 6, depth - 3]:
        for x in [2, width - 3]:
            for dy in range(3):
                place_structure_block(base_x + x, base_z + z, level, dy, "woodBlock", tier_options)
            place_structure_block(base_x + x, base_z + z + 1, level, 0, "torch", tier_options)
        for x in range(2, width - 2):
            place_structure_block(base_x + x, base_z + z, level, 3, "woodBlock", tier_options)
    place_utility(base_x + center_x, base_z + 3, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "mine"),
        "generatedTier": "mine",
        "cacheKey": cache_key
    })

func build_shrine(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_shrine_count += 1
    var cache_key := "%s:shrine:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "shrine", "cacheKey": cache_key }
    var center_x := int(width / 2)
    var center_z := int(depth / 2)
    for x in range(width):
        for z in range(depth):
            place_path(base_x + x, base_z + z, level, tier_options)
    for xz in [
        Vector2i(1, 1),
        Vector2i(width - 2, 1),
        Vector2i(1, depth - 2),
        Vector2i(width - 2, depth - 2)
    ]:
        for dy in range(5):
            place_structure_block(base_x + xz.x, base_z + xz.y, level, dy, "stoneBlock", tier_options)
    for x in range(1, width - 1):
        place_structure_block(base_x + x, base_z + 1, level, 5, "stoneBlock", tier_options)
        place_structure_block(base_x + x, base_z + depth - 2, level, 5, "stoneBlock", tier_options)
    for z in range(1, depth - 1):
        place_structure_block(base_x + 1, base_z + z, level, 5, "stoneBlock", tier_options)
        place_structure_block(base_x + width - 2, base_z + z, level, 5, "stoneBlock", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 0, "stoneBlock", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 2, "glass", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 3, "glass", tier_options)
    for offset in [Vector2i(0, -3), Vector2i(3, 0), Vector2i(0, 3), Vector2i(-3, 0)]:
        place_structure_block(base_x + center_x + offset.x, base_z + center_z + offset.y, level, 1, "torch", tier_options)
    place_utility(base_x + center_x, base_z + center_z + 2, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "shrine"),
        "generatedTier": "shrine",
        "cacheKey": cache_key
    })

func build_cave(plan: Dictionary, rng: RandomNumberGenerator = null) -> void:
    if plan.is_empty():
        return
    var cave_rng := rng
    if cave_rng == null:
        cave_rng = RandomNumberGenerator.new()
        cave_rng.seed = main.hash_string("%s:%s" % [main.seed_text, String(plan.get("id", "cave"))])
    generated_cave_count += 1
    var cave_id := String(plan.get("id", "cave:%d" % generated_cave_count))
    var level := float(plan.get("level", 0.0))
    var kind := String(plan.get("kind", "underground"))
    var cache_key := "%s:%s" % [main.seed_text, cave_id]
    var base_options := {
        "generatedTier": "cave",
        "cacheKey": cache_key,
        "caveId": cave_id,
        "caveKind": kind
    }
    apply_cave_terrain_edits(plan)
    var floor_lookup := cave_floor_lookup(plan)
    var approach_cells: Array = plan.get("approachCells", [])
    var path_cells: Array = plan.get("pathCells", [])
    var chamber_cells: Array = plan.get("chamberCells", [])
    for i in range(approach_cells.size()):
        var cell: Vector2i = approach_cells[i]
        place_path(cell.x, cell.y, level, cave_options(base_options, "approach", i))
    for i in range(path_cells.size()):
        var cell: Vector2i = path_cells[i]
        place_path(cell.x, cell.y, level, cave_options(base_options, "tunnel_floor", i))
    for i in range(chamber_cells.size()):
        var cell: Vector2i = chamber_cells[i]
        place_path(cell.x, cell.y, level, cave_options(base_options, "final_chamber_floor", i))
    build_cave_boundary_walls(floor_lookup, level, base_options, cave_rng)
    build_cave_entrance_arch(plan, level, base_options)
    build_cave_supports(plan, level, base_options)
    var chest_cell: Vector2i = plan.get("finalChestCell", plan.get("finalChamberCell", Vector2i.ZERO))
    place_utility(chest_cell.x, chest_cell.y, level, "chest", cave_options(base_options, "final_chest", int(plan.get("pathLength", 0)), {
        "storageSlots": loot.make_cave_final_loot_slots(cave_rng),
        "caveFinalLoot": true
    }))
    cave_records[cave_id] = cave_record_from_plan(plan, cache_key)

func apply_cave_terrain_edits(plan: Dictionary) -> void:
    if main == null:
        return
    var edits = main.get("height_edits")
    if not (edits is Dictionary):
        return
    var npc_system = main.get("npc_system")
    var level := float(plan.get("level", 0.0))
    var cells := cave_shaping_cells(plan)
    var edited := {}
    for cell_value in cells:
        var cell: Vector2i = cell_value
        if edited.has(cell):
            continue
        edited[cell] = true
        var old_height := float(main.terrain_height_cell(cell.x, cell.y))
        edits[cell] = level
        if npc_system != null and npc_system.has_method("notify_navigation_terrain_edited"):
            npc_system.notify_navigation_terrain_edited(cell, old_height, level)
    if main.has_method("rebuild_chunks_around_cell"):
        main.rebuild_chunks_around_cell(plan.get("entranceCell", Vector2i.ZERO))
        main.rebuild_chunks_around_cell(plan.get("finalChamberCell", Vector2i.ZERO))

func cave_walkable_cells(plan: Dictionary, include_approach := false) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    if include_approach:
        for cell in plan.get("approachCells", []):
            cells.append(cell)
    for cell in plan.get("pathCells", []):
        cells.append(cell)
    for cell in plan.get("chamberCells", []):
        cells.append(cell)
    return cells

func cave_floor_lookup(plan: Dictionary) -> Dictionary:
    var lookup := {}
    for cell in cave_walkable_cells(plan, false):
        lookup[cell] = true
    return lookup

func cave_shaping_cells(plan: Dictionary) -> Array[Vector2i]:
    var lookup := {}
    for cell_value in cave_walkable_cells(plan, true):
        var cell: Vector2i = cell_value
        for dz in range(-2, 3):
            for dx in range(-2, 3):
                if Vector2(float(dx), float(dz)).length() > 2.25:
                    continue
                lookup[cell + Vector2i(dx, dz)] = true
    var cells: Array[Vector2i] = []
    for key in lookup.keys():
        cells.append(key)
    return cells

func build_cave_boundary_walls(floor_lookup: Dictionary, level: float, base_options: Dictionary, rng: RandomNumberGenerator) -> void:
    var wall_cells := {}
    var directions := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
    for cell_value in floor_lookup.keys():
        var cell: Vector2i = cell_value
        for direction in directions:
            var neighbor: Vector2i = cell + direction
            if floor_lookup.has(neighbor) or wall_cells.has(neighbor):
                continue
            wall_cells[neighbor] = true
            place_structure_block(neighbor.x, neighbor.y, level, 0, "stoneBlock", cave_options(base_options, "wall", 0))
            if rng.randf() < 0.64:
                place_structure_block(neighbor.x, neighbor.y, level, 1, "stoneBlock", cave_options(base_options, "wall", 1))
            elif rng.randf() < 0.5:
                place_structure_block(neighbor.x, neighbor.y, level, 1, mine_vein_type(rng), cave_options(base_options, "ore_vein", 1))

func build_cave_entrance_arch(plan: Dictionary, level: float, base_options: Dictionary) -> void:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    for side_offset in [-2, 2]:
        var pillar_cell: Vector2i = entrance + right * side_offset
        for dy in range(3):
            place_structure_block(pillar_cell.x, pillar_cell.y, level, dy, "stoneBlock", cave_options(base_options, "entrance_arch", dy))
    for top_offset in range(-1, 2):
        var cap_cell: Vector2i = entrance + right * top_offset
        place_structure_block(cap_cell.x, cap_cell.y, level, 3, "stoneBlock", cave_options(base_options, "entrance_arch", 3))
    for torch_cell in [entrance + right * -2, entrance + right * 2]:
        place_structure_block(torch_cell.x, torch_cell.y, level, 1, "torch", cave_options(base_options, "entrance_torch", 1))

func build_cave_supports(plan: Dictionary, level: float, base_options: Dictionary) -> void:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var path_length := int(plan.get("pathLength", 12))
    var support_depths := [4, 9, maxi(12, path_length - 4)]
    for depth in support_depths:
        if depth >= path_length:
            continue
        for side_offset in [-2, 2]:
            var post: Vector2i = entrance + inward * depth + right * side_offset
            for dy in range(3):
                place_structure_block(post.x, post.y, level, dy, "woodBlock", cave_options(base_options, "support_post", depth))
        for cross_offset in range(-2, 3):
            var beam: Vector2i = entrance + inward * depth + right * cross_offset
            place_structure_block(beam.x, beam.y, level, 3, "woodBlock", cave_options(base_options, "support_beam", depth))
        if depth % 2 == 1:
            var torch: Vector2i = entrance + inward * (depth + 1) + right * -1
            place_structure_block(torch.x, torch.y, level, 1, "torch", cave_options(base_options, "tunnel_torch", depth))
    var chamber_center: Vector2i = plan.get("finalChamberCell", entrance + inward * path_length)
    for offset in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2)]:
        var torch_cell: Vector2i = chamber_center + right * offset.x + inward * offset.y
        place_structure_block(torch_cell.x, torch_cell.y, level, 1, "torch", cave_options(base_options, "chamber_torch", path_length))

func cave_options(base_options: Dictionary, role: String, depth_index := -1, extra_options: Dictionary = {}) -> Dictionary:
    var options := base_options.duplicate()
    options["caveRole"] = role
    if depth_index >= 0:
        options["caveDepthIndex"] = depth_index
    for key in extra_options.keys():
        options[key] = extra_options[key]
    return options

func cave_record_from_plan(plan: Dictionary, cache_key: String) -> Dictionary:
    return {
        "id": String(plan.get("id", "")),
        "cacheKey": cache_key,
        "kind": String(plan.get("kind", "")),
        "region": plan.get("region", Vector2i.ZERO),
        "entranceCell": plan.get("entranceCell", Vector2i.ZERO),
        "finalChamberCell": plan.get("finalChamberCell", Vector2i.ZERO),
        "finalChestCell": plan.get("finalChestCell", Vector2i.ZERO),
        "level": float(plan.get("level", 0.0)),
        "entranceVariation": float(plan.get("entranceVariation", 0.0)),
        "pathLength": int(plan.get("pathLength", 0)),
        "chamberRadius": int(plan.get("chamberRadius", 0)),
        "walkableCellCount": cave_walkable_cells(plan, false).size(),
        "approachCellCount": cave_array_size(plan, "approachCells")
    }

func cave_records_snapshot() -> Dictionary:
    return cave_records.duplicate(true)

func cave_plan_is_contiguous(plan: Dictionary) -> bool:
    var cells := cave_walkable_cells(plan, false)
    if cells.is_empty():
        return false
    var lookup := {}
    for cell in cells:
        lookup[cell] = true
    var start: Vector2i = plan.get("entranceCell", cells[0])
    var goal: Vector2i = plan.get("finalChestCell", plan.get("finalChamberCell", cells.back()))
    if not lookup.has(start):
        start = cells[0]
    var open := [start]
    var visited := { start: true }
    var directions := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
    while not open.is_empty():
        var current: Vector2i = open.pop_front()
        if current == goal or Vector2(float(current.x - goal.x), float(current.y - goal.y)).length() <= 1.5:
            return true
        for direction in directions:
            var next: Vector2i = current + direction
            if not lookup.has(next) or visited.has(next):
                continue
            visited[next] = true
            open.append(next)
    return false

func cave_array_size(plan: Dictionary, key: String) -> int:
    var value = plan.get(key, [])
    return value.size() if value is Array else 0

func mine_vein_type(rng: RandomNumberGenerator) -> String:
    return "ironVein" if rng.randf() > 0.76 else "copperVein"

func place_loot_chest(base_x: int, base_z: int, level: float, width: int, depth: int, door_side: int, rng: RandomNumberGenerator, tier: String, cache_key: String = "") -> bool:
    if width < 4 or depth < 4:
        return false
    var cell := loot_chest_cell(width, depth, door_side, rng)
    var key := cache_key
    if key == "":
        key = "%s:%s-cache:%d,%d" % [main.seed_text, tier, base_x + int(cell.get("x", 0)), base_z + int(cell.get("z", 0))]
    return place_utility(base_x + int(cell.get("x", 0)), base_z + int(cell.get("z", 0)), level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, tier),
        "generatedTier": tier,
        "cacheKey": key
    }) != null

func loot_chest_cell(width: int, depth: int, door_side: int, rng: RandomNumberGenerator) -> Dictionary:
    var side_x := 1 if rng.randf() < 0.5 else width - 2
    var side_z := 1 if rng.randf() < 0.5 else depth - 2
    if door_side == 0:
        return { "x": side_x, "z": depth - 2 }
    if door_side == 1:
        return { "x": 1, "z": side_z }
    if door_side == 2:
        return { "x": side_x, "z": 1 }
    if door_side == 3:
        return { "x": width - 2, "z": side_z }
    return { "x": side_x, "z": side_z }

func flat_level_for_footprint(base_x: int, base_z: int, width: int, depth: int) -> float:
    var samples := []
    for x in range(base_x, base_x + width):
        samples.append(main.terrain_height_cell(x, base_z))
        samples.append(main.terrain_height_cell(x, base_z + depth - 1))
    for z in range(base_z, base_z + depth):
        samples.append(main.terrain_height_cell(base_x, z))
        samples.append(main.terrain_height_cell(base_x + width - 1, z))
    var min_h := 999999.0
    var max_h := -999999.0
    for h in samples:
        min_h = min(min_h, float(h))
        max_h = max(max_h, float(h))
    if max_h - min_h > main.CELL * 0.65 or max_h <= main.WATER_LEVEL + 1.2:
        return NAN
    return (min_h + max_h) * 0.5

func place_structure_block(cell_x: int, cell_z: int, level: float, dy: int, block_type: String, extra_options: Dictionary = {}) -> void:
    var world_y: float = level + main.CELL * 0.48 + float(dy) * main.CELL
    var cell_y: int = floori(world_y / main.CELL) + 1
    var options := {
        "generated": true,
        "world_y": world_y,
        "structureDy": dy,
        "structureLevel": level
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    main.create_block(Vector3i(cell_x, cell_y, cell_z), block_type, options)

func place_path(cell_x: int, cell_z: int, level: float, extra_options: Dictionary = {}) -> void:
    var cell_y: int = roundi(level / main.CELL)
    var options := {
        "generated": true,
        "world_y": level + main.CELL * 0.024
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), "cobblestonePath", options)
    if block:
        generated_path_count += 1

func place_utility(cell_x: int, cell_z: int, level: float, block_type: String, extra_options: Dictionary = {}) -> StaticBody3D:
    var world_y: float = level + main.CELL * 0.48
    var cell_y: int = floori(world_y / main.CELL) + 1
    var options := {
        "generated": true,
        "world_y": world_y
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), block_type, options)
    if block:
        generated_utility_count += 1
    return block

func place_door(cell_x: int, cell_z: int, level: float, side: int, secondary: bool, door_policy := "private_home") -> void:
    var world_y: float = level + main.CELL * 0.48
    var cell_y: int = floori(world_y / main.CELL) + 1
    var facing: float = StructureDoorRulesScript.door_facing(side)
    var group_x := cell_x
    var group_z := cell_z
    if secondary:
        if side == 0 or side == 2:
            group_x -= 1
        elif side == 1 or side == 3:
            group_z -= 1
    var group_id := "door-group:%d,%d,%d:%d" % [group_x, cell_y, group_z, side]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), "door", {
        "generated": true,
        "world_y": world_y,
        "facing": facing,
        "secondary": secondary,
        "doorSide": side,
        "doorLeafIndex": 1 if secondary else 0,
        "doorGroupId": group_id,
        "doorPortalId": "door:%s" % group_id,
        "doorPublicAccess": true,
        "doorPolicy": door_policy,
        "door": true,
        "accentRole": "doorFrame",
        "doorTrimMaterial": "trimWood"
    })
    if block:
        generated_door_count += 1

func place_porch(base_x: int, base_z: int, level: float, width: int, depth: int, side: int) -> void:
    var doors := StructureDoorRulesScript.door_cells(width, depth, side)
    for entry in doors:
        var x := base_x + int(entry["x"])
        var z := base_z + int(entry["z"])
        if side == 0:
            place_path(x, z + 1, level)
        elif side == 2:
            place_path(x, z - 1, level)
        elif side == 1:
            place_path(x + 1, z, level)
        else:
            place_path(x - 1, z, level)

func counts() -> Dictionary:
    return {
        "towns": generated_town_count,
        "buildings": generated_building_count,
        "mines": generated_mine_count,
        "ruins": generated_ruin_count,
        "shrines": generated_shrine_count,
        "camps": generated_camp_count,
        "caves": generated_cave_count,
        "paths": generated_path_count,
        "doors": generated_door_count,
        "utilities": generated_utility_count
    }
