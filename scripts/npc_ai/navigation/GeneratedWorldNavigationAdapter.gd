extends RefCounted
class_name GeneratedWorldNavigationAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const NAV_TILE_CELL_SIZE := NpcConstantsScript.NAV_TILE_CELL_SIZE
const INVALID_CELL := Vector2i(999999, 999999)
const PROP_CLEARANCE_RADIUS := CELL * 0.82
const DOOR_LINK_ENTER_COST := CELL * 18.0
const ROUTE_NAVMESH_MARGIN_CELLS := 10
const ROUTE_NAVMESH_MAX_TILES := 64

var system
var main
var cached_revision := ""
var cached_blocked := {}
var cached_doors := {}
var cached_paths := {}
var cached_props := {}
var height_cache := {}
var static_snapshot_revision := 1
var topology_revision := 1
var dynamic_revision := 0
var semantic_revision := 0
var door_state_revision := 0
var last_event_revision := 0
var nav_static_rebuild_count := 0
var nav_dynamic_update_count := 0

func setup(system_node, main_node) -> void:
    system = system_node
    main = main_node

func performance_monitor():
    return main.get("runtime_perf_monitor") if main != null else null

func invalidate() -> void:
    static_snapshot_revision += 1
    topology_revision = static_snapshot_revision
    cached_revision = ""
    height_cache = {}

func apply_navigation_events(events: Array) -> void:
    var static_changed := false
    var dynamic_changed := false
    var semantic_changed := false
    var door_state_changed := false
    for event_value in events:
        if not (event_value is Dictionary):
            continue
        var event: Dictionary = event_value
        last_event_revision = maxi(last_event_revision, int(event.get("revision", 0)))
        var kinds: Array = event.get("changeKinds", [])
        if _event_changes_static_snapshot(kinds):
            static_changed = true
        elif _event_changes_door_state(kinds):
            door_state_changed = true
        elif _event_changes_semantic_state(kinds):
            semantic_changed = true
        else:
            dynamic_changed = true
    if static_changed:
        static_snapshot_revision = maxi(static_snapshot_revision + 1, last_event_revision)
        topology_revision = static_snapshot_revision
        cached_revision = ""
        height_cache = {}
    if dynamic_changed:
        dynamic_revision = maxi(dynamic_revision + 1, last_event_revision)
    if semantic_changed:
        semantic_revision = maxi(semantic_revision + 1, last_event_revision)
    if door_state_changed:
        door_state_revision = maxi(door_state_revision + 1, last_event_revision)

func build_snapshot(entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
    var monitor = performance_monitor()
    var static_revision_id := str(static_snapshot_revision)
    var revision_id := revision()
    if static_revision_id != cached_revision:
        var rebuild_start: int = monitor.begin_section("navigation_snapshot_rebuild") if monitor != null else Time.get_ticks_usec()
        var scanned := rebuild_static_cells()
        nav_static_rebuild_count += 1
        if monitor != null:
            monitor.increment_counter("nav_static_rebuild_count")
            monitor.increment_counter("prop_block_scan_count", scanned)
            monitor.end_section("navigation_snapshot_rebuild", rebuild_start)
        cached_revision = static_revision_id
    var dynamic_start: int = monitor.begin_section("navigation_dynamic_update") if monitor != null else Time.get_ticks_usec()
    var dynamic_cells := live_occupant_cells(entry)
    nav_dynamic_update_count += 1
    if monitor != null:
        monitor.increment_counter("nav_dynamic_update_count")
        monitor.end_section("navigation_dynamic_update", dynamic_start)
    return {
        "revision": revision_id,
        "staticSnapshotRevision": static_snapshot_revision,
        "dynamicRevision": dynamic_revision,
        "semanticRevision": semantic_revision,
        "doorStateRevision": door_state_revision,
        "navStaticRebuildCount": nav_static_rebuild_count,
        "navDynamicUpdateCount": nav_dynamic_update_count,
        "blocked": cached_blocked,
        "doors": cached_doors,
        "paths": cached_paths,
        "props": cached_props,
        "dynamic": dynamic_cells,
        "allowOutside": allow_outside,
        "movingHome": moving_home
    }

func revision() -> String:
    return "%d:%d:%d:%d" % [static_snapshot_revision, dynamic_revision, semantic_revision, door_state_revision]

func navmesh_tile_source_key() -> String:
    return "%d:%d" % [static_snapshot_revision, semantic_revision]

func route_navmesh_tile_keys(entry: Dictionary, start: Vector3, target: Vector3, allow_outside := false, moving_home := false, margin_cells := ROUTE_NAVMESH_MARGIN_CELLS) -> Array[String]:
    var start_cell := world_cell(start)
    var target_cell := world_cell(target)
    var min_x := mini(start_cell.x, target_cell.x) - margin_cells
    var max_x := maxi(start_cell.x, target_cell.x) + margin_cells
    var min_z := mini(start_cell.y, target_cell.y) - margin_cells
    var max_z := maxi(start_cell.y, target_cell.y) + margin_cells
    if entry != null and not entry.is_empty():
        var center: Vector2i = entry.get("townCenter", start_cell)
        var radius := int(entry.get("townRadius", 18))
        if allow_outside or moving_home:
            radius += 24
        var clamp_margin := maxi(margin_cells, 4)
        min_x = maxi(min_x, center.x - radius - clamp_margin)
        max_x = mini(max_x, center.x + radius + clamp_margin)
        min_z = maxi(min_z, center.y - radius - clamp_margin)
        max_z = mini(max_z, center.y + radius + clamp_margin)
    var min_tile_x := floori(float(min_x) / float(NAV_TILE_CELL_SIZE))
    var max_tile_x := floori(float(max_x) / float(NAV_TILE_CELL_SIZE))
    var min_tile_z := floori(float(min_z) / float(NAV_TILE_CELL_SIZE))
    var max_tile_z := floori(float(max_z) / float(NAV_TILE_CELL_SIZE))
    var keys: Array[String] = []
    for tile_z in range(min_tile_z, max_tile_z + 1):
        for tile_x in range(min_tile_x, max_tile_x + 1):
            keys.append("%d,%d" % [tile_x, tile_z])
    keys.sort()
    if keys.size() <= ROUTE_NAVMESH_MAX_TILES:
        return keys
    return _nearest_route_tiles(keys, start_cell, target_cell)

func build_navmesh_tile_snapshot(tile_key: String) -> Dictionary:
    var snapshot: Dictionary = build_snapshot({}, true, true)
    var tile := _parse_tile_key(tile_key)
    var min_x := tile.x * NAV_TILE_CELL_SIZE
    var min_z := tile.y * NAV_TILE_CELL_SIZE
    var surfaces: Array[Dictionary] = []
    var semantic_regions: Array[Dictionary] = []
    for z in range(min_z, min_z + NAV_TILE_CELL_SIZE):
        for x in range(min_x, min_x + NAV_TILE_CELL_SIZE):
            var cell := Vector2i(x, z)
            var surface := _navmesh_surface_for_cell(snapshot, cell)
            if not surface.is_empty():
                surfaces.append(surface)
    var door_summary := _navmesh_door_summary_for_tile(snapshot, tile_key)
    return {
        "tileKey": tile_key,
        "regionId": "region:chunk:%s" % tile_key,
        "sourceRevision": static_snapshot_revision,
        "topologyRevision": static_snapshot_revision,
        "dynamicRevision": dynamic_revision,
        "semanticRevision": semantic_revision,
        "surfaces": surfaces,
        "semanticRegions": semantic_regions,
        "doorPortals": door_summary.get("doorPortals", []),
        "doorLinks": door_summary.get("doorLinks", [])
    }

func _event_changes_static_snapshot(kinds: Array) -> bool:
    for kind_value in kinds:
        var kind := StringName(kind_value)
        if kind in [
            NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED,
            NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED,
            NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT,
            NpcEnumsScript.CHANGE_KIND_PROP_CREATED,
            NpcEnumsScript.CHANGE_KIND_PROP_REMOVED,
            NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED,
            NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED,
            NpcEnumsScript.CHANGE_KIND_DOOR_REGISTERED,
            NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA
        ]:
            return true
    return false

func _event_changes_door_state(kinds: Array) -> bool:
    for kind_value in kinds:
        if StringName(kind_value) == NpcEnumsScript.CHANGE_KIND_DOOR_STATE:
            return true
    return false

func _event_changes_semantic_state(kinds: Array) -> bool:
    for kind_value in kinds:
        if StringName(kind_value) == NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED:
            return true
    return false

func rebuild_static_cells() -> int:
    cached_blocked = {}
    cached_doors = {}
    cached_paths = {}
    cached_props = {}
    height_cache = {}
    if main == null:
        return 0
    var scanned := 0
    var blocks: Dictionary = main.get("blocks")
    for block in blocks.values():
        scanned += 1
        var body := block as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_type := String(body.get_meta("block_type", ""))
        var block_cell := block_world_cell(body)
        if block_cell == INVALID_CELL:
            continue
        if block_type == "door":
            cached_doors[block_cell] = body
            continue
        if block_type == "cobblestonePath":
            cached_paths[block_cell] = true
            continue
        if block_type == "torch":
            continue
        if not block_xz_blocks_npc(block_cell, body):
            continue
        cached_blocked[block_cell] = body
    scanned += add_prop_obstacle_cells()
    return scanned

func block_world_cell(body: Node) -> Vector2i:
    if body.has_meta("cell"):
        var cell_value = body.get_meta("cell")
        if cell_value is Vector3i:
            return Vector2i(cell_value.x, cell_value.z)
        if cell_value is Vector2i:
            return cell_value
    if body is Node3D:
        return world_cell((body as Node3D).global_position)
    return INVALID_CELL

func add_prop_obstacle_cells() -> int:
    var scanned := 0
    for root_value in [main.get("chunk_root"), main.get("prop_root")]:
        var root := root_value as Node
        if root == null:
            continue
        var stack: Array[Node] = [root]
        while not stack.is_empty():
            var node := stack.pop_back() as Node
            scanned += 1
            if node == null:
                continue
            if node is Node3D and String(node.get_meta("kind", "")) == "prop":
                var prop := node as Node3D
                if prop_blocks_npc(prop):
                    var cell := world_cell(prop.global_position)
                    cached_blocked[cell] = prop
                    cached_props[cell] = prop
            for child in node.get_children():
                stack.append(child)
    return scanned

func prop_blocks_npc(prop: Node3D) -> bool:
    var material := String(prop.get_meta("material", ""))
    var drop := String(prop.get_meta("drop", ""))
    if material in ["tree", "rock", "copperOre", "ironOre", "wildlife", "berryBush"]:
        return true
    return drop in ["logs", "stones", "berries"]

func block_xz_blocks_npc(cell: Vector2i, body: Node) -> bool:
    if main == null or not (body is Node3D):
        return true
    var block_center_y := (body as Node3D).global_position.y
    var floor_y := height_for_cell(cell)
    var clearance_center_y := floor_y + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT + NpcConstantsScript.DEFAULT_HEADROOM_MARGIN + CELL * 0.45
    return block_center_y <= clearance_center_y

func live_occupant_cells(entry: Dictionary) -> Dictionary:
    var dynamic := {}
    var self_body := entry.get("body") as Node3D
    if system != null:
        for other_entry in system.npcs:
            var other_body := other_entry.get("body") as Node3D
            if other_body == null or not is_instance_valid(other_body) or other_body == self_body:
                continue
            dynamic[world_cell(other_body.global_position)] = other_body
    if system != null and system.get("hostile_system") != null:
        var hostile_system = system.get("hostile_system")
        var enemies_value = hostile_system.get("enemies") if hostile_system != null else null
        if enemies_value is Array:
            for enemy in enemies_value:
                var enemy_body: Node3D = null
                if enemy is Node3D:
                    enemy_body = enemy
                elif enemy is Dictionary:
                    enemy_body = (enemy as Dictionary).get("body") as Node3D
                if enemy_body == null or not is_instance_valid(enemy_body):
                    continue
                dynamic[world_cell(enemy_body.global_position)] = enemy_body
    if main != null and main.get("player") is Node3D:
        var player := main.get("player") as Node3D
        dynamic[world_cell(player.global_position)] = player
    return dynamic

func world_cell(position: Vector3) -> Vector2i:
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func cell_position(cell: Vector2i) -> Vector3:
    if main == null:
        return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
    var y: float = height_for_cell(cell)
    return Vector3(float(cell.x) * CELL, y + 0.04, float(cell.y) * CELL)

func height_for_cell(cell: Vector2i) -> float:
    if main == null:
        return 0.0
    if height_cache.has(cell):
        return float(height_cache[cell])
    var y: float = float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y))) if main.has_method("surface_y_at_cell") else 0.0
    height_cache[cell] = y
    return y

func cell_distance(a: Vector2i, b: Vector2i) -> float:
    return Vector2(float(a.x - b.x), float(a.y - b.y)).length()

func cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

func tile_key_for_cell(cell: Vector2i) -> String:
    return "%d,%d" % [floori(float(cell.x) / float(NAV_TILE_CELL_SIZE)), floori(float(cell.y) / float(NAV_TILE_CELL_SIZE))]

func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var radius := float(entry.get("townRadius", 18)) * CELL
    var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
    return flat.length() <= radius

func point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var radius := role_leash_radius_cells(entry, true, false) * CELL
    var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
    return flat.length() <= radius

func point_allowed(entry: Dictionary, position: Vector3, allow_outside := false, moving_home := false) -> bool:
    if allow_outside or moving_home:
        return point_inside_role_leash(entry, position, allow_outside, moving_home)
    return point_inside_town(entry, position)

func cell_allowed_area(entry: Dictionary, cell: Vector2i, allow_outside := false, moving_home := false) -> bool:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var radius_cells := float(entry.get("townRadius", 18))
    if allow_outside or moving_home:
        radius_cells = role_leash_radius_cells(entry, allow_outside, moving_home)
    var flat := Vector2(float(cell.x - center.x), float(cell.y - center.y)) * CELL
    return flat.length() <= radius_cells * CELL

func point_inside_dynamic_work_area(entry: Dictionary, position: Vector3, moving_home := false) -> bool:
    return point_inside_role_leash(entry, position, true, moving_home)

func point_inside_role_leash(entry: Dictionary, position: Vector3, allow_outside := false, moving_home := false) -> bool:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var radius := role_leash_radius_cells(entry, allow_outside, moving_home) * CELL
    var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
    return flat.length() <= radius

func role_leash_radius_cells(entry: Dictionary, allow_outside := false, moving_home := false) -> float:
    var base_radius := float(entry.get("townRadius", 18))
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var job := String(entry.get("job", ""))
    var role := String(entry.get("role", "")).to_lower()
    var leash_radius := base_radius
    if job == "forage":
        leash_radius = base_radius + 24.0
    elif job == "guard" or role.find("guard") >= 0:
        leash_radius = base_radius + 8.0
    elif allow_outside:
        leash_radius = base_radius + 2.0
    if allow_outside:
        leash_radius = scripted_target_leash_radius_cells(entry, center, leash_radius)
    if not moving_home:
        return leash_radius
    var body := entry.get("body") as Node3D
    if body != null and is_instance_valid(body):
        var body_cell := world_cell(body.global_position)
        var current_radius := Vector2(float(body_cell.x - center.x), float(body_cell.y - center.y)).length()
        leash_radius = maxf(leash_radius, minf(current_radius + 8.0, 640.0))
    return leash_radius

func scripted_target_leash_radius_cells(entry: Dictionary, center: Vector2i, fallback_radius: float) -> float:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return fallback_radius
    if not body.has_meta("npc_scripted_target") or not bool(body.get_meta("npc_scripted_allow_outside", false)):
        return fallback_radius
    var target_value = body.get_meta("npc_scripted_target")
    if not (target_value is Vector3):
        return fallback_radius
    var target: Vector3 = target_value
    var target_radius := Vector2(target.x - float(center.x) * CELL, target.z - float(center.y) * CELL).length() / CELL
    var current_radius := Vector2(body.global_position.x - float(center.x) * CELL, body.global_position.z - float(center.y) * CELL).length() / CELL
    return minf(maxf(maxf(fallback_radius, target_radius + 4.0), current_radius + 4.0), 640.0)

func dynamic_work_radius_cells(entry: Dictionary, moving_home := false) -> float:
    return role_leash_radius_cells(entry, true, moving_home)

func terrain_allows_step(from_cell: Vector2i, to_cell: Vector2i, moving_home := false) -> Dictionary:
    if main == null:
        return { "ok": false, "reason": "no_world" }
    var from_height: float = height_for_cell(from_cell)
    var to_height: float = height_for_cell(to_cell)
    if to_height < main.WATER_LEVEL + 0.45:
        return { "ok": false, "reason": "water" }
    if absf(to_height - from_height) > CELL * 0.90 and not moving_home:
        return { "ok": false, "reason": "slope" }
    return { "ok": true, "height": to_height }

func static_blocker(snapshot: Dictionary, cell: Vector2i):
    if door_at(snapshot, cell) != null:
        return null
    var blocked: Dictionary = snapshot.get("blocked", {})
    var blocker = blocked.get(cell, null)
    if blocker != null and blocker is Object and not is_instance_valid(blocker):
        blocked.erase(cell)
        return null
    return blocker

func prop_clearance_blocker(snapshot: Dictionary, cell: Vector2i):
    var props: Dictionary = snapshot.get("props", {})
    if props.is_empty():
        return null
    var cell_position_value := cell_position(cell)
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            if dx == 0 and dz == 0:
                continue
            var neighbor := cell + Vector2i(dx, dz)
            var prop = props.get(neighbor, null)
            if prop == null:
                continue
            if prop is Object and not is_instance_valid(prop):
                props.erase(neighbor)
                continue
            var prop_body := prop as Node3D
            if prop_body == null:
                continue
            var flat_distance := Vector2(cell_position_value.x - prop_body.global_position.x, cell_position_value.z - prop_body.global_position.z).length()
            if flat_distance <= PROP_CLEARANCE_RADIUS:
                return prop
    return null

func door_at(snapshot: Dictionary, cell: Vector2i) -> Node:
    var doors: Dictionary = snapshot.get("doors", {})
    var door_value = doors.get(cell, null)
    if door_value == null:
        return null
    if not is_instance_valid(door_value):
        doors.erase(cell)
        return null
    if door_value is Node:
        return door_value
    return null

func dynamic_blocker(snapshot: Dictionary, cell: Vector2i):
    var dynamic: Dictionary = snapshot.get("dynamic", {})
    var blocker = dynamic.get(cell, null)
    if blocker != null and blocker is Object and not is_instance_valid(blocker):
        dynamic.erase(cell)
        return null
    return blocker

func is_path_cell(snapshot: Dictionary, cell: Vector2i) -> bool:
    var paths: Dictionary = snapshot.get("paths", {})
    return paths.has(cell)

func cell_pathable(entry: Dictionary, snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i, target_cells: Dictionary, ignore_dynamic := false) -> Dictionary:
    var allow_outside := bool(snapshot.get("allowOutside", false))
    var moving_home := bool(snapshot.get("movingHome", false))
    if not cell_allowed_area(entry, to_cell, allow_outside, moving_home):
        return { "ok": false, "reason": "outside_area" }
    var terrain := terrain_allows_step(from_cell, to_cell, moving_home)
    if not bool(terrain.get("ok", false)):
        return terrain
    var door := door_at(snapshot, to_cell)
    if door != null and not door_allows_route_for_entry(entry, door, from_cell, moving_home):
        return { "ok": false, "reason": "private_door_not_routeable" }
    if static_blocker(snapshot, to_cell) != null and not target_cells.has(to_cell):
        return { "ok": false, "reason": "blocked_static" }
    if to_cell != from_cell and prop_clearance_blocker(snapshot, to_cell) != null and not target_cells.has(to_cell):
        return { "ok": false, "reason": "blocked_prop_clearance" }
    if not ignore_dynamic and dynamic_blocker(snapshot, to_cell) != null and not target_cells.has(to_cell):
        return { "ok": false, "reason": "blocked_dynamic" }
    return { "ok": true, "reason": "" }

func door_allows_route_for_entry(entry: Dictionary, door: Node, from_cell: Vector2i, moving_home := false) -> bool:
    if door == null:
        return true
    var policy := String(door.get_meta("door_policy", "private_home"))
    if policy != "private_home":
        return true
    if not private_home_door_matches_entry(entry, door):
        return false
    if moving_home:
        return true
    if entry_body_inside_home(entry):
        return true
    return cell_inside_entry_home(entry, from_cell)

func private_home_door_matches_entry(entry: Dictionary, door: Node) -> bool:
    var door_cell := door_flat_cell(door)
    if door_cell == Vector2i(999999, 999999):
        return false
    var porch_cell: Vector2i = entry.get("porchCell", entry.get("homeCell", Vector2i.ZERO))
    if maxi(absi(door_cell.x - porch_cell.x), absi(door_cell.y - porch_cell.y)) <= 1:
        return true
    var interior_min: Vector2i = entry.get("interiorMinCell", entry.get("homeCell", Vector2i.ZERO))
    var interior_max: Vector2i = entry.get("interiorMaxCell", entry.get("homeCell", Vector2i.ZERO))
    if door_cell.x < mini(interior_min.x, interior_max.x) \
        or door_cell.x > maxi(interior_min.x, interior_max.x) \
        or door_cell.y < mini(interior_min.y, interior_max.y) \
        or door_cell.y > maxi(interior_min.y, interior_max.y):
        return false
    return maxi(absi(door_cell.x - porch_cell.x), absi(door_cell.y - porch_cell.y)) <= 1

func door_flat_cell(door: Node) -> Vector2i:
    if door == null:
        return Vector2i(999999, 999999)
    var cell_value = door.get_meta("cell", Vector3i(999999, 0, 999999))
    if cell_value is Vector3i:
        var cell: Vector3i = cell_value
        return Vector2i(cell.x, cell.z)
    var body := door as Node3D
    if body != null:
        return world_cell(body.global_position)
    return Vector2i(999999, 999999)

func entry_body_inside_home(entry: Dictionary) -> bool:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    return cell_inside_entry_home(entry, world_cell(body.global_position))

func cell_inside_entry_home(entry: Dictionary, cell: Vector2i) -> bool:
    var interior_min: Vector2i = entry.get("interiorMinCell", entry.get("homeCell", Vector2i.ZERO))
    var interior_max: Vector2i = entry.get("interiorMaxCell", entry.get("homeCell", Vector2i.ZERO))
    return cell.x >= mini(interior_min.x, interior_max.x) \
        and cell.x <= maxi(interior_min.x, interior_max.x) \
        and cell.y >= mini(interior_min.y, interior_max.y) \
        and cell.y <= maxi(interior_min.y, interior_max.y)

func candidate_cells_near(entry: Dictionary, target_cell: Vector2i, allow_outside := false, moving_home := false, radius := 2) -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    for r in range(0, radius + 1):
        for dx in range(-r, r + 1):
            for dz in range(-r, r + 1):
                if max(abs(dx), abs(dz)) != r:
                    continue
                var cell := target_cell + Vector2i(dx, dz)
                if cell_allowed_area(entry, cell, allow_outside, moving_home):
                    result.append(cell)
    result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return cell_distance(a, target_cell) < cell_distance(b, target_cell)
    )
    return result

func _navmesh_surface_for_cell(snapshot: Dictionary, cell: Vector2i) -> Dictionary:
    if main == null:
        return {}
    if height_for_cell(cell) < main.WATER_LEVEL + 0.45:
        return {}
    var door := door_at(snapshot, cell)
    if door != null:
        var door_state := String(door.get_meta("door_state", NpcEnumsScript.DOOR_STATE_CLOSED))
        if bool(door.get_meta("locked", false)) or bool(door.get_meta("jammed", false)) or bool(door.get_meta("destroyed", false)) or bool(door.get_meta("unloaded", false)):
            return {}
        if door_state in [String(NpcEnumsScript.DOOR_STATE_LOCKED), String(NpcEnumsScript.DOOR_STATE_JAMMED), String(NpcEnumsScript.DOOR_STATE_DESTROYED), String(NpcEnumsScript.DOOR_STATE_UNLOADED)]:
            return {}
    if static_blocker(snapshot, cell) != null:
        return {}
    if prop_clearance_blocker(snapshot, cell) != null:
        return {}
    var position := cell_position(cell)
    var span_y := floori(position.y / CELL)
    position.y = float(span_y) * CELL + 0.04
    var traversal_tags: Array[String] = ["terrain"]
    var semantic_region_ids: Array[String] = []
    var cave_id := cave_navigation_id_for_cell(cell)
    if cave_id != "":
        traversal_tags.append("cave")
        semantic_region_ids.append("cave:%s" % cave_id)
    if door != null:
        traversal_tags.append("door")
    if is_path_cell(snapshot, cell):
        traversal_tags.append("path")
    var surface := {
        "cell": Vector3i(cell.x, span_y, cell.y),
        "spanIndex": 0,
        "worldPosition": position,
        "floorNormal": Vector3.UP,
        "headroom": 3.0,
        "lateralClearance": 1.0,
        "blocked": false,
        "semanticRegionIds": semantic_region_ids,
        "traversalTags": traversal_tags
    }
    return surface

func cave_navigation_id_for_cell(cell: Vector2i) -> String:
    if main == null:
        return ""
    var structure_system = main.get("structure_system")
    if structure_system == null or not structure_system.has_method("cave_navigation_id_for_cell"):
        return ""
    return String(structure_system.call("cave_navigation_id_for_cell", cell.x, cell.y))

func _navmesh_door_summary_for_tile(snapshot: Dictionary, tile_key: String) -> Dictionary:
    var portals: Array[Dictionary] = []
    var links: Array[Dictionary] = []
    var doors: Dictionary = snapshot.get("doors", {})
    var cells: Array = doors.keys()
    cells.sort_custom(func(a, b): return cell_key(a) < cell_key(b))
    for cell_value in cells:
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        if tile_key_for_cell(cell) != tile_key:
            continue
        var door := door_at(snapshot, cell)
        if door == null:
            continue
        var portal_id := _door_portal_id(door, cell)
        if portal_id == "":
            continue
        var axis := _door_crossing_axis(door)
        var step := Vector2i(1, 0) if axis == "x" else Vector2i(0, 1)
        var entrance_cell := cell - step
        var exit_cell := cell + step
        var entrance := cell_position(entrance_cell)
        var exit := cell_position(exit_cell)
        portals.append({
            "id": portal_id,
            "entrance": entrance,
            "exit": exit,
            "state": String(door.get_meta("door_state", NpcEnumsScript.DOOR_STATE_CLOSED)),
            "openable": true,
            "enabled": not bool(door.get_meta("destroyed", false)) and not bool(door.get_meta("unloaded", false)),
            "locked": bool(door.get_meta("locked", false)),
            "jammed": bool(door.get_meta("jammed", false)),
            "destroyed": bool(door.get_meta("destroyed", false)),
            "unloaded": bool(door.get_meta("unloaded", false)),
            "crossingAxis": axis,
            "cell": cell
        })
        links.append({
            "id": "door-link:%s:%s" % [portal_id, tile_key],
            "from": _nav_span_key(tile_key, entrance_cell),
            "to": _nav_span_key(tile_key, exit_cell),
            "portalId": portal_id,
            "actionId": "open",
            "start": entrance,
            "end": exit,
            "bidirectional": true,
            "openable": true,
            "enabled": true,
            "cost": 1.0,
            "enterCost": DOOR_LINK_ENTER_COST,
            "travelCost": 1.0,
            "cell": cell
        })
    return { "doorPortals": portals, "doorLinks": links }

func _door_portal_id(door: Node, cell: Vector2i) -> String:
    if door == null:
        return ""
    if door.has_meta("door_portal_id"):
        return String(door.get_meta("door_portal_id"))
    if door.has_meta("cell"):
        var door_cell = door.get_meta("cell")
        if door_cell is Vector3i:
            return "door:%d,%d,%d" % [door_cell.x, door_cell.y, door_cell.z]
    return "door:%d,0,%d" % [cell.x, cell.y]

func _door_crossing_axis(door: Node) -> String:
    if door == null:
        return "z"
    var side := int(door.get_meta("door_side", -1))
    if side == 1 or side == 3:
        return "x"
    if side == 0 or side == 2:
        return "z"
    var facing := float(door.get_meta("closed_rotation", (door as Node3D).rotation.y if door is Node3D else 0.0))
    return "x" if absf(sin(facing)) > absf(cos(facing)) else "z"

func _nav_span_key(tile_key: String, cell: Vector2i) -> String:
    var position := cell_position(cell)
    return "%s:%d,%d,%d:0" % [tile_key, cell.x, floori(position.y / CELL), cell.y]

func _parse_tile_key(tile_key: String) -> Vector2i:
    var parts := tile_key.split(",")
    if parts.size() < 2:
        return Vector2i.ZERO
    return Vector2i(int(parts[0]), int(parts[1]))

func _nearest_route_tiles(keys: Array[String], start_cell: Vector2i, target_cell: Vector2i) -> Array[String]:
    var midpoint := Vector2(float(start_cell.x + target_cell.x) * 0.5, float(start_cell.y + target_cell.y) * 0.5)
    var scored := []
    for key in keys:
        var tile := _parse_tile_key(String(key))
        var center := Vector2(float(tile.x * NAV_TILE_CELL_SIZE) + float(NAV_TILE_CELL_SIZE) * 0.5, float(tile.y * NAV_TILE_CELL_SIZE) + float(NAV_TILE_CELL_SIZE) * 0.5)
        scored.append({ "key": String(key), "score": center.distance_squared_to(midpoint) })
    scored.sort_custom(func(a, b):
        if is_equal_approx(float(a.get("score", 0.0)), float(b.get("score", 0.0))):
            return String(a.get("key", "")) < String(b.get("key", ""))
        return float(a.get("score", 0.0)) < float(b.get("score", 0.0))
    )
    var result: Array[String] = []
    for item in scored:
        if result.size() >= ROUTE_NAVMESH_MAX_TILES:
            break
        result.append(String((item as Dictionary).get("key", "")))
    result.sort()
    return result

func approach_cells_for_target(entry: Dictionary, target_position: Vector3, allow_outside := true) -> Array[Vector2i]:
    var target_cell := world_cell(target_position)
    var result: Array[Vector2i] = []
    for radius in range(1, 4):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if max(abs(dx), abs(dz)) != radius:
                    continue
                var cell := target_cell + Vector2i(dx, dz)
                if cell_allowed_area(entry, cell, allow_outside, false):
                    result.append(cell)
    result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return cell_distance(a, target_cell) < cell_distance(b, target_cell)
    )
    return result
