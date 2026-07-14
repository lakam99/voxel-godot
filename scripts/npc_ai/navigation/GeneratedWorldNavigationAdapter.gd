extends RefCounted
class_name GeneratedWorldNavigationAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const NAV_TILE_CELL_SIZE := NpcConstantsScript.NAV_TILE_CELL_SIZE
const INVALID_CELL := Vector2i(999999, 999999)
const PROP_CLEARANCE_RADIUS := CELL * 0.82
const DOOR_LINK_ENTER_COST := CELL * 18.0
const ROUTE_NAVMESH_MARGIN_CELLS := 4
const ROUTE_NAVMESH_MAX_TILES := 32
const NAV_TERRAIN_PROJECTION_UP_CELLS := 8
const NAV_TERRAIN_PROJECTION_DOWN_CELLS := 24
const NAV_TERRAIN_PROJECTION_MAX_SURFACE_DEVIATION := CELL * 1.10
const TRANSITION_COLLISION_INFLATION := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
const TRANSITION_RECORD_INDEX_MARGIN_CELLS := 2
const NAVMESH_TILE_SNAPSHOT_CACHE_LIMIT := 96

var system
var main
var cached_revision := ""
var cached_blocked := {}
var cached_doors := {}
var cached_paths := {}
var cached_props := {}
var cached_prop_clearance := {}
var cached_prop_cell_by_object_id := {}
var cached_prop_collision_records_by_object_id := {}
var cached_static_collision_records: Array[Dictionary] = []
var cached_static_collision_by_cell := {}
var cached_door_collision_records: Array[Dictionary] = []
var cached_door_collision_by_cell := {}
var cached_private_interior_records_revision := -1
var cached_private_interior_records: Array = []
var cached_tutorial_starter_bounds_key := ""
var cached_tutorial_starter_bounds := {}
var height_cache := {}
var terrain_projection_cache := {}
var navmesh_tile_snapshot_cache := {}
var navmesh_tile_snapshot_cache_order: Array[String] = []
var navmesh_tile_revision_by_key := {}
var navmesh_tile_semantic_revision_by_key := {}
var navmesh_tile_door_revision_by_key := {}
var static_snapshot_revision := 1
var topology_revision := 1
var dynamic_revision := 0
var semantic_revision := 0
var door_state_revision := 0
var last_event_revision := 0
var nav_static_rebuild_count := 0
var nav_dynamic_update_count := 0
var dynamic_occupant_cache_frame_key := ""
var dynamic_occupant_cache := {}

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
    terrain_projection_cache = {}
    _clear_navmesh_tile_snapshot_cache()
    navmesh_tile_revision_by_key.clear()
    navmesh_tile_semantic_revision_by_key.clear()
    navmesh_tile_door_revision_by_key.clear()
    cached_prop_cell_by_object_id = {}
    cached_prop_collision_records_by_object_id = {}
    cached_private_interior_records_revision = -1
    dynamic_occupant_cache_frame_key = ""
    dynamic_occupant_cache = {}
    cached_private_interior_records = []
    cached_tutorial_starter_bounds_key = ""
    cached_tutorial_starter_bounds = {}

func apply_navigation_events(events: Array) -> void:
    var monitor = performance_monitor()
    var apply_start: int = monitor.begin_section("generated_nav_event_apply") if monitor != null else Time.get_ticks_usec()
    var static_changed := false
    var dynamic_changed := false
    var semantic_changed := false
    var semantic_global_changed := false
    var door_state_changed := false
    var static_changed_tiles: Array[String] = []
    var semantic_changed_tiles: Array[String] = []
    var door_state_changed_tiles: Array[String] = []
    for event_value in events:
        if not (event_value is Dictionary):
            continue
        var event: Dictionary = event_value
        last_event_revision = maxi(last_event_revision, int(event.get("revision", 0)))
        var kinds: Array = event.get("changeKinds", [])
        var tile_key := String(event.get("tileKey", ""))
        if _event_changes_static_snapshot(kinds):
            var prop_start: int = monitor.begin_section("generated_nav_prop_event_apply") if monitor != null else Time.get_ticks_usec()
            if _event_is_prop_only_static_change(kinds) and _apply_prop_event_to_static_cache(event):
                _mark_incremental_static_change(tile_key)
            else:
                static_changed = true
                if tile_key != "" and not static_changed_tiles.has(tile_key):
                    static_changed_tiles.append(tile_key)
            if monitor != null:
                monitor.end_section("generated_nav_prop_event_apply", prop_start)
        elif _event_changes_door_state(kinds):
            door_state_changed = true
            if tile_key != "" and not door_state_changed_tiles.has(tile_key):
                door_state_changed_tiles.append(tile_key)
        elif _event_changes_semantic_state(kinds):
            semantic_changed = true
            if tile_key != "":
                if not semantic_changed_tiles.has(tile_key):
                    semantic_changed_tiles.append(tile_key)
            else:
                semantic_global_changed = true
        else:
            dynamic_changed = true
    if static_changed:
        static_snapshot_revision = maxi(static_snapshot_revision + 1, last_event_revision)
        topology_revision = static_snapshot_revision
        cached_revision = ""
        height_cache = {}
        terrain_projection_cache = {}
        _clear_navmesh_tile_snapshot_cache()
        for tile_key in static_changed_tiles:
            navmesh_tile_revision_by_key[tile_key] = static_snapshot_revision
    if dynamic_changed:
        dynamic_revision = maxi(dynamic_revision + 1, last_event_revision)
    if semantic_changed:
        semantic_revision = maxi(semantic_revision + 1, last_event_revision)
        if semantic_global_changed or semantic_changed_tiles.is_empty():
            navmesh_tile_semantic_revision_by_key.clear()
            _clear_navmesh_tile_snapshot_cache()
        else:
            for changed_tile_key in semantic_changed_tiles:
                navmesh_tile_semantic_revision_by_key[changed_tile_key] = semantic_revision
                _clear_navmesh_tile_snapshot_cache_for_tile(changed_tile_key)
    if door_state_changed:
        door_state_revision = maxi(door_state_revision + 1, last_event_revision)
        if door_state_changed_tiles.is_empty():
            navmesh_tile_door_revision_by_key.clear()
            _clear_navmesh_tile_snapshot_cache()
        else:
            for changed_tile_key in door_state_changed_tiles:
                navmesh_tile_door_revision_by_key[changed_tile_key] = door_state_revision
                _clear_navmesh_tile_snapshot_cache_for_tile(changed_tile_key)
    if monitor != null:
        monitor.end_section("generated_nav_event_apply", apply_start)

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
        "propClearance": cached_prop_clearance,
        "staticCollision": cached_static_collision_records,
        "staticCollisionByCell": cached_static_collision_by_cell,
        "doorCollision": cached_door_collision_records,
        "doorCollisionByCell": cached_door_collision_by_cell,
        "dynamic": dynamic_cells,
        "allowOutside": allow_outside,
        "movingHome": moving_home
    }

func revision() -> String:
    return "%d:%d:%d:%d" % [static_snapshot_revision, dynamic_revision, semantic_revision, door_state_revision]

func navmesh_tile_source_key() -> String:
    return "%d:%d:%d" % [static_snapshot_revision, semantic_revision, door_state_revision]

func navmesh_tile_source_key_for_tile(tile_key: String) -> String:
    if tile_key == "":
        return navmesh_tile_source_key()
    if not navmesh_tile_revision_by_key.has(tile_key):
        navmesh_tile_revision_by_key[tile_key] = static_snapshot_revision
    var tile_revision := int(navmesh_tile_revision_by_key.get(tile_key, static_snapshot_revision))
    if not navmesh_tile_semantic_revision_by_key.has(tile_key):
        navmesh_tile_semantic_revision_by_key[tile_key] = semantic_revision
    var tile_semantic_revision := int(navmesh_tile_semantic_revision_by_key.get(tile_key, semantic_revision))
    if not navmesh_tile_door_revision_by_key.has(tile_key):
        navmesh_tile_door_revision_by_key[tile_key] = door_state_revision
    var tile_door_revision := int(navmesh_tile_door_revision_by_key.get(tile_key, door_state_revision))
    return "%d:%d:%d" % [tile_revision, tile_semantic_revision, tile_door_revision]

func route_navmesh_tile_keys(entry: Dictionary, start: Vector3, target: Vector3, allow_outside := false, moving_home := false, margin_cells := ROUTE_NAVMESH_MARGIN_CELLS) -> Array[String]:
    var start_cell := world_cell(start)
    var target_cell := world_cell(target)
    var min_x := mini(start_cell.x, target_cell.x) - margin_cells
    var max_x := maxi(start_cell.x, target_cell.x) + margin_cells
    var min_z := mini(start_cell.y, target_cell.y) - margin_cells
    var max_z := maxi(start_cell.y, target_cell.y) + margin_cells
    if entry != null and not entry.is_empty():
        var center: Vector2i = entry.get("townCenter", start_cell)
        var radius := int(ceili(role_leash_radius_cells(entry, allow_outside, moving_home)))
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

# IMPORTANT: navmesh tile snapshots must be built from the same live collision
# snapshot used by collision probing. Do not switch this back to the lighter
# helper that only updates blocked/doors/paths; that reintroduces planner/probe
# disagreement and makes NPCs accept routes into walls or reject valid routes.
func build_navmesh_tile_snapshot(tile_key: String) -> Dictionary:
    var cache_key := "%s|%s" % [tile_key, navmesh_tile_source_key_for_tile(tile_key)]
    if navmesh_tile_snapshot_cache.has(cache_key):
        var cached_snapshot: Dictionary = navmesh_tile_snapshot_cache[cache_key]
        return cached_snapshot
    var snapshot: Dictionary = _snapshot_with_live_tile_blocks(cached_static_tile_snapshot(true, true), tile_key)
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
    var result: Dictionary = {
        "tileKey": tile_key,
        "regionId": "region:chunk:%s" % tile_key,
        "sourceRevision": static_snapshot_revision,
        "topologyRevision": static_snapshot_revision,
        "dynamicRevision": dynamic_revision,
        "semanticRevision": semantic_revision,
        "blocked": snapshot.get("blocked", {}),
        "doors": snapshot.get("doors", {}),
        "paths": snapshot.get("paths", {}),
        "staticCollision": snapshot.get("staticCollision", []),
        "staticCollisionByCell": snapshot.get("staticCollisionByCell", {}),
        "doorCollision": snapshot.get("doorCollision", []),
        "doorCollisionByCell": snapshot.get("doorCollisionByCell", {}),
        "surfaces": surfaces,
        "semanticRegions": semantic_regions,
        "doorPortals": door_summary.get("doorPortals", []),
        "doorLinks": door_summary.get("doorLinks", [])
    }
    _store_navmesh_tile_snapshot_cache(cache_key, result)
    return result

func collision_snapshot_for_bounds(entry: Dictionary, bounds: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
    var snapshot := cached_validation_snapshot(entry, allow_outside, moving_home)
    if bounds.is_empty():
        return snapshot
    var min_x := int(bounds.get("minX", 0))
    var max_x := int(bounds.get("maxX", min_x))
    var min_z := int(bounds.get("minZ", 0))
    var max_z := int(bounds.get("maxZ", min_z))
    var min_tile_x := floori(float(mini(min_x, max_x)) / float(NAV_TILE_CELL_SIZE))
    var max_tile_x := floori(float(maxi(min_x, max_x)) / float(NAV_TILE_CELL_SIZE))
    var min_tile_z := floori(float(mini(min_z, max_z)) / float(NAV_TILE_CELL_SIZE))
    var max_tile_z := floori(float(maxi(min_z, max_z)) / float(NAV_TILE_CELL_SIZE))
    for tile_z in range(min_tile_z, max_tile_z + 1):
        for tile_x in range(min_tile_x, max_tile_x + 1):
            snapshot = _snapshot_with_live_tile_blocks(snapshot, "%d,%d" % [tile_x, tile_z])
    return snapshot

func _store_navmesh_tile_snapshot_cache(cache_key: String, snapshot: Dictionary) -> void:
    if cache_key == "" or snapshot.is_empty():
        return
    navmesh_tile_snapshot_cache[cache_key] = snapshot
    navmesh_tile_snapshot_cache_order.erase(cache_key)
    navmesh_tile_snapshot_cache_order.append(cache_key)
    while navmesh_tile_snapshot_cache_order.size() > NAVMESH_TILE_SNAPSHOT_CACHE_LIMIT:
        var evicted := String(navmesh_tile_snapshot_cache_order.pop_front())
        navmesh_tile_snapshot_cache.erase(evicted)

func _clear_navmesh_tile_snapshot_cache() -> void:
    navmesh_tile_snapshot_cache.clear()
    navmesh_tile_snapshot_cache_order.clear()

func _clear_navmesh_tile_snapshot_cache_for_tile(tile_key: String) -> void:
    if tile_key == "":
        return
    var prefix := "%s|" % tile_key
    var evicted_keys: Array[String] = []
    for cache_key_value in navmesh_tile_snapshot_cache.keys():
        var cache_key := String(cache_key_value)
        if cache_key.begins_with(prefix):
            evicted_keys.append(cache_key)
    for cache_key in evicted_keys:
        navmesh_tile_snapshot_cache.erase(cache_key)
        navmesh_tile_snapshot_cache_order.erase(cache_key)

func _snapshot_with_live_tile_blocks_for_navmesh_tile(base_snapshot: Dictionary, tile_key: String) -> Dictionary:
    if main == null:
        return base_snapshot
    var blocks: Dictionary = main.get("blocks")
    if blocks.is_empty():
        return base_snapshot
    var snapshot: Dictionary = base_snapshot.duplicate(false)
    var blocked := _tile_cells_dictionary(base_snapshot.get("blocked", {}), tile_key)
    var doors := _tile_cells_dictionary(base_snapshot.get("doors", {}), tile_key)
    var paths := _tile_cells_dictionary(base_snapshot.get("paths", {}), tile_key)
    for block_value in blocks.values():
        var body := block_value as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_cell := block_world_cell(body)
        if block_cell == INVALID_CELL or tile_key_for_cell(block_cell) != tile_key:
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if block_type == "door":
            doors[block_cell] = body
            blocked.erase(block_cell)
            continue
        if block_type == "cobblestonePath":
            paths[block_cell] = true
            blocked.erase(block_cell)
            continue
        if block_type == "torch":
            blocked.erase(block_cell)
            continue
        if not block_xz_blocks_npc(block_cell, body):
            blocked.erase(block_cell)
            continue
        blocked[block_cell] = body
    snapshot["blocked"] = blocked
    snapshot["doors"] = doors
    snapshot["paths"] = paths
    return snapshot

func _tile_cells_dictionary(cells_value, tile_key: String) -> Dictionary:
    var result: Dictionary = {}
    if not (cells_value is Dictionary):
        return result
    var cells: Dictionary = cells_value
    for cell_value in cells.keys():
        if cell_value is Vector2i and tile_key_for_cell(cell_value) == tile_key:
            result[cell_value] = cells[cell_value]
    return result

func _snapshot_with_live_tile_blocks(base_snapshot: Dictionary, tile_key: String) -> Dictionary:
    if main == null:
        return base_snapshot
    var blocks: Dictionary = main.get("blocks")
    if blocks.is_empty():
        return base_snapshot
    var snapshot := base_snapshot.duplicate(false)
    var blocked: Dictionary = (base_snapshot.get("blocked", {}) as Dictionary).duplicate(false)
    var doors: Dictionary = (base_snapshot.get("doors", {}) as Dictionary).duplicate(false)
    var paths: Dictionary = (base_snapshot.get("paths", {}) as Dictionary).duplicate(false)
    _erase_tile_cells(blocked, tile_key)
    _erase_tile_cells(doors, tile_key)
    _erase_tile_cells(paths, tile_key)
    var static_records: Array = _collision_records_outside_tile(base_snapshot.get("staticCollision", []), tile_key)
    var door_records: Array = _collision_records_outside_tile(base_snapshot.get("doorCollision", []), tile_key)
    for block_value in blocks.values():
        var body := block_value as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_cell := block_world_cell(body)
        if block_cell == INVALID_CELL or tile_key_for_cell(block_cell) != tile_key:
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if block_type == "door":
            doors[block_cell] = body
            blocked.erase(block_cell)
            _append_collision_records(door_records, body, block_cell, block_type, true)
            continue
        if block_type == "cobblestonePath":
            paths[block_cell] = true
            blocked.erase(block_cell)
            continue
        if block_type == "torch":
            blocked.erase(block_cell)
            continue
        if not block_xz_blocks_npc(block_cell, body):
            blocked.erase(block_cell)
            continue
        blocked[block_cell] = body
        _append_collision_records(static_records, body, block_cell, block_type, false)
    snapshot["blocked"] = blocked
    snapshot["doors"] = doors
    snapshot["paths"] = paths
    snapshot["staticCollision"] = static_records
    snapshot["staticCollisionByCell"] = _collision_index_for_records(static_records)
    snapshot["doorCollision"] = door_records
    snapshot["doorCollisionByCell"] = _collision_index_for_records(door_records)
    return snapshot

func _erase_tile_cells(cells: Dictionary, tile_key: String) -> void:
    for cell_value in cells.keys():
        if cell_value is Vector2i and tile_key_for_cell(cell_value) == tile_key:
            cells.erase(cell_value)

func _collision_records_outside_tile(records_value, tile_key: String) -> Array:
    var result := []
    if not (records_value is Array):
        return result
    for record_value in records_value:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var cell: Vector2i = record.get("cell", INVALID_CELL)
        if cell != INVALID_CELL and tile_key_for_cell(cell) == tile_key:
            continue
        result.append(record)
    return result

func _append_collision_records(records: Array, body: Node, cell: Vector2i, block_type: String, is_door: bool) -> void:
    var body_records := _collision_records_for_body(body, cell, block_type, is_door)
    if body_records.is_empty() and body is Node3D:
        body_records.append(_fallback_collision_record(body as Node3D, cell, block_type, is_door))
    for record in body_records:
        records.append(record)

func _collision_index_for_records(records: Array) -> Dictionary:
    var index := {}
    for record_value in records:
        if record_value is Dictionary:
            _index_collision_record(index, record_value)
    return index

func cached_static_tile_snapshot(allow_outside := false, moving_home := false) -> Dictionary:
    if cached_revision == "" and cached_blocked.is_empty() and cached_doors.is_empty() and cached_paths.is_empty() and cached_props.is_empty():
        return build_snapshot({}, allow_outside, moving_home)
    return {
        "revision": revision(),
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
        "propClearance": cached_prop_clearance,
        "staticCollision": cached_static_collision_records,
        "staticCollisionByCell": cached_static_collision_by_cell,
        "doorCollision": cached_door_collision_records,
        "doorCollisionByCell": cached_door_collision_by_cell,
        "dynamic": {},
        "allowOutside": allow_outside,
        "movingHome": moving_home
    }

func cached_validation_snapshot(entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
    if cached_revision == "" and cached_blocked.is_empty() and cached_doors.is_empty() and cached_paths.is_empty() and cached_props.is_empty():
        return build_snapshot(entry, allow_outside, moving_home)
    var monitor = performance_monitor()
    var dynamic_start: int = monitor.begin_section("navigation_dynamic_update") if monitor != null else Time.get_ticks_usec()
    var dynamic_cells := live_occupant_cells(entry)
    nav_dynamic_update_count += 1
    if monitor != null:
        monitor.increment_counter("nav_dynamic_update_count")
        monitor.end_section("navigation_dynamic_update", dynamic_start)
    return {
        "revision": revision(),
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
        "propClearance": cached_prop_clearance,
        "staticCollision": cached_static_collision_records,
        "staticCollisionByCell": cached_static_collision_by_cell,
        "doorCollision": cached_door_collision_records,
        "doorCollisionByCell": cached_door_collision_by_cell,
        "dynamic": dynamic_cells,
        "allowOutside": allow_outside,
        "movingHome": moving_home
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
            NpcEnumsScript.CHANGE_KIND_DOOR_REGISTERED,
            NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA
        ]:
            return true
    return false

func _event_is_prop_only_static_change(kinds: Array) -> bool:
    var saw_prop_change := false
    for kind_value in kinds:
        var kind := StringName(kind_value)
        if kind == NpcEnumsScript.CHANGE_KIND_PROP_CREATED or kind == NpcEnumsScript.CHANGE_KIND_PROP_REMOVED:
            saw_prop_change = true
            continue
        if kind in [
            NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED,
            NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED,
            NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT,
            NpcEnumsScript.CHANGE_KIND_DOOR_REGISTERED,
            NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA
        ]:
            return false
    return saw_prop_change

func _event_has_kind(kinds: Array, expected: StringName) -> bool:
    for kind_value in kinds:
        if StringName(kind_value) == expected:
            return true
    return false

func _mark_incremental_static_change(tile_key := "") -> void:
    static_snapshot_revision = maxi(static_snapshot_revision + 1, last_event_revision)
    topology_revision = static_snapshot_revision
    if cached_revision != "":
        cached_revision = str(static_snapshot_revision)
    if String(tile_key) != "":
        navmesh_tile_revision_by_key[String(tile_key)] = static_snapshot_revision
    _clear_navmesh_tile_snapshot_cache()

func _apply_prop_event_to_static_cache(event: Dictionary) -> bool:
    if cached_revision == "":
        return false
    var object_ids: Array = event.get("objectIds", []) if event.get("objectIds", []) is Array else []
    if object_ids.is_empty():
        return false
    var kinds: Array = event.get("changeKinds", []) if event.get("changeKinds", []) is Array else []
    var remove_props := _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_PROP_REMOVED)
    var create_props := _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_PROP_CREATED)
    for object_id_value in object_ids:
        var object_id := String(object_id_value)
        if not object_id.begins_with("prop:"):
            continue
        if remove_props:
            _remove_cached_prop_object(object_id)
        if create_props:
            _add_cached_prop_object(object_id)
    return true

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
    cached_prop_clearance = {}
    cached_prop_cell_by_object_id = {}
    cached_prop_collision_records_by_object_id = {}
    cached_static_collision_records = []
    cached_static_collision_by_cell = {}
    cached_door_collision_records = []
    cached_door_collision_by_cell = {}
    height_cache = {}
    terrain_projection_cache = {}
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
            _add_collision_records(body, block_cell, block_type, true)
            continue
        if block_type == "cobblestonePath":
            cached_paths[block_cell] = true
            continue
        if block_type == "torch":
            continue
        if not block_xz_blocks_npc(block_cell, body):
            continue
        cached_blocked[block_cell] = body
        _add_collision_records(body, block_cell, block_type, false)
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

func _add_collision_records(body: Node, cell: Vector2i, block_type: String, is_door: bool) -> void:
    var records := []
    var prop_object_id := _prop_object_id(body) if block_type == "prop" else ""
    if block_type == "prop" and body is Node3D:
        records.append(_fallback_collision_record(body as Node3D, cell, block_type, is_door))
    else:
        records = _collision_records_for_body(body, cell, block_type, is_door)
        if records.is_empty() and body is Node3D:
            records.append(_fallback_collision_record(body as Node3D, cell, block_type, is_door))
    var prop_records: Array[Dictionary] = []
    for record in records:
        if is_door:
            cached_door_collision_records.append(record)
            _index_collision_record(cached_door_collision_by_cell, record)
        else:
            cached_static_collision_records.append(record)
            _index_collision_record(cached_static_collision_by_cell, record)
            if prop_object_id != "":
                prop_records.append(record)
    if prop_object_id != "" and not prop_records.is_empty():
        cached_prop_collision_records_by_object_id[prop_object_id] = prop_records

func _collision_records_for_body(body: Node, cell: Vector2i, block_type: String, is_door: bool) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var body3d := body as Node3D
    if body3d == null:
        return result
    var stack: Array[Node] = [body]
    var collider_index := 0
    while not stack.is_empty():
        var node := stack.pop_back() as Node
        if node == null:
            continue
        var collider := node as CollisionShape3D
        if collider != null and not collider.disabled and collider.shape is BoxShape3D:
            var box := collider.shape as BoxShape3D
            var record := _box_collision_record(body3d, collider, box, cell, block_type, is_door, collider_index)
            if not record.is_empty():
                result.append(record)
                collider_index += 1
        for child in node.get_children():
            stack.append(child)
    return result

func _box_collision_record(body: Node3D, collider: CollisionShape3D, box: BoxShape3D, cell: Vector2i, block_type: String, is_door: bool, collider_index: int) -> Dictionary:
    var body_transform := body.global_transform if body.is_inside_tree() else body.transform
    var transform: Transform3D = collider.global_transform if collider.is_inside_tree() else body_transform * collider.transform
    if collider.get_parent() == body:
        transform = body_transform * collider.transform
    var half := box.size * 0.5
    var corners := [
        Vector3(-half.x, 0.0, -half.z),
        Vector3(half.x, 0.0, -half.z),
        Vector3(half.x, 0.0, half.z),
        Vector3(-half.x, 0.0, half.z)
    ]
    var min_x := INF
    var max_x := -INF
    var min_z := INF
    var max_z := -INF
    for corner in corners:
        var world_corner: Vector3 = transform * corner
        min_x = minf(min_x, world_corner.x)
        max_x = maxf(max_x, world_corner.x)
        min_z = minf(min_z, world_corner.z)
        max_z = maxf(max_z, world_corner.z)
    if min_x == INF or min_z == INF:
        return {}
    return {
        "id": "%s:%s:%s:%d" % ["door" if is_door else "static", cell_key(cell), String(body.name), collider_index],
        "cell": cell,
        "blockType": block_type,
        "node": body,
        "isDoor": is_door,
        "minX": min_x,
        "maxX": max_x,
        "minZ": min_z,
        "maxZ": max_z,
        "inflation": TRANSITION_COLLISION_INFLATION
    }

func _fallback_collision_record(body: Node3D, cell: Vector2i, block_type: String, is_door: bool) -> Dictionary:
    var radius := PROP_CLEARANCE_RADIUS if block_type == "prop" else CELL * 0.48
    var center := body.global_position
    return {
        "id": "%s:%s:%s:fallback" % ["door" if is_door else "static", cell_key(cell), String(body.name)],
        "cell": cell,
        "blockType": block_type,
        "node": body,
        "isDoor": is_door,
        "minX": center.x - radius,
        "maxX": center.x + radius,
        "minZ": center.z - radius,
        "maxZ": center.z + radius,
        "inflation": TRANSITION_COLLISION_INFLATION
    }

func _index_collision_record(index: Dictionary, record: Dictionary) -> void:
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    var min_x := floori((float(record.get("minX", 0.0)) - inflation) / CELL) - TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var max_x := floori((float(record.get("maxX", 0.0)) + inflation) / CELL) + TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var min_z := floori((float(record.get("minZ", 0.0)) - inflation) / CELL) - TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var max_z := floori((float(record.get("maxZ", 0.0)) + inflation) / CELL) + TRANSITION_RECORD_INDEX_MARGIN_CELLS
    for z in range(min_z, max_z + 1):
        for x in range(min_x, max_x + 1):
            var key := Vector2i(x, z)
            if not index.has(key):
                index[key] = []
            (index[key] as Array).append(record)

func _unindex_collision_record(index: Dictionary, record: Dictionary) -> void:
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    var min_x := floori((float(record.get("minX", 0.0)) - inflation) / CELL) - TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var max_x := floori((float(record.get("maxX", 0.0)) + inflation) / CELL) + TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var min_z := floori((float(record.get("minZ", 0.0)) - inflation) / CELL) - TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var max_z := floori((float(record.get("maxZ", 0.0)) + inflation) / CELL) + TRANSITION_RECORD_INDEX_MARGIN_CELLS
    for z in range(min_z, max_z + 1):
        for x in range(min_x, max_x + 1):
            var key := Vector2i(x, z)
            if not index.has(key):
                continue
            var records: Array = index.get(key, [])
            records.erase(record)
            if records.is_empty():
                index.erase(key)
            else:
                index[key] = records

func _add_cached_prop_object(object_id: String) -> bool:
    var prop := _registered_prop_node(object_id)
    if prop == null:
        return false
    if cached_prop_cell_by_object_id.has(object_id):
        _remove_cached_prop_object(object_id)
    if not prop_blocks_npc(prop):
        return true
    var cell := world_cell(prop.global_position)
    cached_blocked[cell] = prop
    cached_props[cell] = prop
    cached_prop_cell_by_object_id[object_id] = cell
    _index_prop_clearance(prop, cell)
    _add_collision_records(prop, cell, "prop", false)
    return true

func _remove_cached_prop_object(object_id: String) -> bool:
    var removed := false
    if cached_prop_cell_by_object_id.has(object_id):
        var prop_cell: Vector2i = cached_prop_cell_by_object_id.get(object_id, INVALID_CELL)
        var prop = cached_props.get(prop_cell)
        cached_props.erase(prop_cell)
        if cached_blocked.get(prop_cell, null) == prop:
            cached_blocked.erase(prop_cell)
        cached_prop_cell_by_object_id.erase(object_id)
        for dz in range(-1, 2):
            for dx in range(-1, 2):
                var clearance_cell := prop_cell + Vector2i(dx, dz)
                if _prop_object_id(cached_prop_clearance.get(clearance_cell)) == object_id:
                    cached_prop_clearance.erase(clearance_cell)
        removed = true
    else:
        for cell_value in cached_props.keys().duplicate():
            var cell: Vector2i = cell_value
            var prop = cached_props.get(cell)
            if _prop_object_id(prop) != object_id:
                continue
            cached_props.erase(cell)
            if cached_blocked.get(cell, null) == prop:
                cached_blocked.erase(cell)
            removed = true
        for cell_value in cached_prop_clearance.keys().duplicate():
            var cell: Vector2i = cell_value
            if _prop_object_id(cached_prop_clearance.get(cell)) == object_id:
                cached_prop_clearance.erase(cell)
                removed = true
    if _remove_collision_records_for_prop(object_id):
        removed = true
    return removed

func _remove_collision_records_for_prop(object_id: String) -> bool:
    if cached_prop_collision_records_by_object_id.has(object_id):
        var indexed_records: Array = cached_prop_collision_records_by_object_id.get(object_id, [])
        for record_value in indexed_records:
            if not (record_value is Dictionary):
                continue
            var record: Dictionary = record_value
            cached_static_collision_records.erase(record)
            _unindex_collision_record(cached_static_collision_by_cell, record)
        cached_prop_collision_records_by_object_id.erase(object_id)
        return not indexed_records.is_empty()
    var filtered: Array[Dictionary] = []
    var removed := false
    for record in cached_static_collision_records:
        if _prop_object_id(record.get("node", null)) == object_id:
            removed = true
            continue
        filtered.append(record)
    if removed:
        cached_static_collision_records = filtered
        cached_static_collision_by_cell = _collision_index_for_records(cached_static_collision_records)
    return removed

func _registered_prop_node(object_id: String) -> Node3D:
    if system == null or object_id == "":
        return null
    var autonomy = system.get("autonomy_system")
    if autonomy == null or autonomy.get("smart_objects") == null:
        return null
    var service = autonomy.get("smart_objects")
    var registrations = service.get("registrations")
    if not (registrations is Dictionary) or not (registrations as Dictionary).has(object_id):
        return null
    var registration = (registrations as Dictionary)[object_id]
    var node = registration.node
    if node == null or not is_instance_valid(node) or not (node is Node3D):
        return null
    return node as Node3D

func _prop_object_id(value) -> String:
    if value == null or not is_instance_valid(value):
        return ""
    if not (value is Node):
        return ""
    var node: Node = value
    if not node.has_meta("prop_id"):
        return ""
    return "prop:%s" % String(node.get_meta("prop_id"))

func add_prop_obstacle_cells() -> int:
    var scanned := 0
    var prop_root := main.get("prop_root") as Node
    if prop_root != null:
        scanned += _scan_prop_obstacle_root(prop_root)
        return scanned
    var chunk_root := main.get("chunk_root") as Node
    if chunk_root != null:
        scanned += _scan_prop_obstacle_root(chunk_root)
    return scanned

func _scan_prop_obstacle_root(root: Node) -> int:
    var scanned := 0
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
                var object_id := _prop_object_id(prop)
                cached_blocked[cell] = prop
                cached_props[cell] = prop
                if object_id != "":
                    cached_prop_cell_by_object_id[object_id] = cell
                _index_prop_clearance(prop, cell)
                _add_collision_records(prop, cell, "prop", false)
            continue
        for child in node.get_children():
            stack.append(child)
    return scanned

func _scan_direct_chunk_prop_children(chunk_root: Node) -> int:
    var scanned := 0
    for child in chunk_root.get_children():
        var node := child as Node
        scanned += 1
        if node == null:
            continue
        if node is Node3D and String(node.get_meta("kind", "")) == "prop":
            scanned += _scan_prop_obstacle_root(node)
    return scanned

func prop_blocks_npc(prop: Node3D) -> bool:
    var material := String(prop.get_meta("material", ""))
    var drop := String(prop.get_meta("drop", ""))
    if material in ["tree", "rock", "copperOre", "ironOre", "wildlife", "berryBush"]:
        return true
    return drop in ["logs", "stones", "berries"]

func _index_prop_clearance(prop: Node3D, prop_cell: Vector2i) -> void:
    if prop == null:
        return
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            if dx == 0 and dz == 0:
                continue
            var cell := prop_cell + Vector2i(dx, dz)
            var flat_distance := Vector2(float(cell.x) * CELL - prop.global_position.x, float(cell.y) * CELL - prop.global_position.z).length()
            if flat_distance <= PROP_CLEARANCE_RADIUS:
                cached_prop_clearance[cell] = prop

func block_xz_blocks_npc(cell: Vector2i, body: Node) -> bool:
    if main == null or not (body is Node3D):
        return true
    var block_center_y := (body as Node3D).global_position.y
    var floor_y := height_for_cell(cell)
    var clearance_center_y := floor_y + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT + NpcConstantsScript.DEFAULT_HEADROOM_MARGIN + CELL * 0.45
    return block_center_y <= clearance_center_y

func live_occupant_cells(entry: Dictionary) -> Dictionary:
    var dynamic := _live_occupant_cells_for_frame().duplicate()
    var self_body := entry.get("body") as Node3D
    if self_body != null and is_instance_valid(self_body):
        var self_cell := world_cell(self_body.global_position)
        if dynamic.get(self_cell) == self_body:
            dynamic.erase(self_cell)
    return dynamic

func _live_occupant_cells_for_frame() -> Dictionary:
    var frame_key := "%d:%d" % [Engine.get_process_frames(), Engine.get_physics_frames()]
    if dynamic_occupant_cache_frame_key == frame_key:
        return dynamic_occupant_cache
    var dynamic := {}
    if system != null:
        for other_entry in system.npcs:
            var other_body := other_entry.get("body") as Node3D
            if other_body == null or not is_instance_valid(other_body):
                continue
            if not dynamic_actor_blocks_navigation(other_body):
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
                if not dynamic_actor_blocks_navigation(enemy_body):
                    continue
                dynamic[world_cell(enemy_body.global_position)] = enemy_body
    if main != null and main.get("player") is Node3D:
        var player := main.get("player") as Node3D
        if dynamic_actor_blocks_navigation(player):
            dynamic[world_cell(player.global_position)] = player
    dynamic_occupant_cache_frame_key = frame_key
    dynamic_occupant_cache = dynamic
    return dynamic

func dynamic_actor_blocks_navigation(actor: Node3D) -> bool:
    if actor == null or not is_instance_valid(actor):
        return false
    if actor is CollisionObject3D:
        var collider := actor as CollisionObject3D
        if int(collider.collision_layer) == 0 and int(collider.collision_mask) == 0:
            return false
    return true

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
    var projection := terrain_projection_for_cell(cell)
    var y := 0.0
    if bool(projection.get("found", false)):
        var position: Vector3 = projection.get("position", Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL))
        y = position.y
    else:
        y = float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y))) if main.has_method("surface_y_at_cell") else 0.0
    height_cache[cell] = y
    return y

func terrain_projection_for_cell(cell: Vector2i) -> Dictionary:
    if terrain_projection_cache.has(cell):
        return terrain_projection_cache[cell]
    var projection := {}
    var world_generation = main.get("world_generation_system") if main != null else null
    var probe_y := 0
    var surface_y := 0.0
    if main != null and main.has_method("surface_y_at_cell"):
        surface_y = float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
        probe_y = floori(surface_y / CELL)
    var probe_cell := Vector3i(cell.x, probe_y, cell.y)
    var fallback_projection := surface_height_projection(cell, probe_y, surface_y)
    if world_generation != null and world_generation.has_method("terrain_volume_column_has_surface_projection_affecting_edits"):
        var has_surface_edits := bool(world_generation.call("terrain_volume_column_has_surface_projection_affecting_edits", probe_cell))
        if not has_surface_edits:
            terrain_projection_cache[cell] = fallback_projection
            return fallback_projection
    if world_generation != null and world_generation.has_method("walkable_surface_cell_near"):
        projection = world_generation.call("walkable_surface_cell_near", probe_cell, NAV_TERRAIN_PROJECTION_UP_CELLS, NAV_TERRAIN_PROJECTION_DOWN_CELLS)
    elif world_generation != null and world_generation.has_method("surface_projection_for_cell"):
        projection = world_generation.call("surface_projection_for_cell", probe_cell, NAV_TERRAIN_PROJECTION_UP_CELLS, NAV_TERRAIN_PROJECTION_DOWN_CELLS)
    if bool(projection.get("found", false)) and main != null and main.has_method("surface_y_at_cell"):
        var projected_position: Vector3 = projection.get("position", fallback_projection.get("position", Vector3.ZERO))
        if projected_position.y > surface_y + NAV_TERRAIN_PROJECTION_MAX_SURFACE_DEVIATION:
            projection = fallback_projection
    if (projection.is_empty() or not bool(projection.get("found", false))) and main != null and main.has_method("surface_y_at_cell"):
        projection = fallback_projection
    terrain_projection_cache[cell] = projection
    return projection

func surface_height_projection(cell: Vector2i, probe_y: int, surface_y: float) -> Dictionary:
    var solid_cell := Vector3i(cell.x, probe_y, cell.y)
    return {
        "found": true,
        "solidCell": solid_cell,
        "airCell": solid_cell + Vector3i(0, 1, 0),
        "position": Vector3(float(cell.x) * CELL, surface_y, float(cell.y) * CELL),
        "walkable": true,
        "occupancy": {}
    }

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
    var to_projection := terrain_projection_for_cell(to_cell)
    if not bool(to_projection.get("found", false)):
        return { "ok": false, "reason": "no_walkable_surface" }
    var occupancy: Dictionary = to_projection.get("occupancy", {}) if to_projection.get("occupancy", {}) is Dictionary else {}
    if not occupancy.is_empty() and not bool(occupancy.get("walkableAir", true)):
        return { "ok": false, "reason": "blocked_terrain_occupancy" }
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

func live_static_blocker_for_cell(cell: Vector2i):
    if main == null:
        return null
    var blocks: Dictionary = main.get("blocks")
    if blocks.is_empty():
        return null
    for key in blocks.keys():
        var key_cell := INVALID_CELL
        if key is Vector3i:
            key_cell = Vector2i(key.x, key.z)
        elif key is Vector2i:
            key_cell = key
        if key_cell != cell:
            continue
        var body := blocks.get(key) as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if block_type in ["door", "cobblestonePath", "torch"]:
            continue
        if not block_xz_blocks_npc(cell, body):
            continue
        return body
    return null

func prop_clearance_blocker(snapshot: Dictionary, cell: Vector2i):
    var clearance: Dictionary = snapshot.get("propClearance", {})
    var prop = clearance.get(cell, null)
    if prop == null:
        return null
    if prop is Object and not is_instance_valid(prop):
        clearance.erase(cell)
        return null
    return prop

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
    var relax_target_blockers := target_cells.has(to_cell) and not bool(target_cells.get("_strictTargetCollision", false))
    if not cell_allowed_area(entry, to_cell, allow_outside, moving_home):
        return { "ok": false, "reason": "outside_area" }
    if private_interior_blocks_entry(entry, to_cell):
        return { "ok": false, "reason": "private_interior_not_routeable" }
    var terrain := terrain_allows_step(from_cell, to_cell, moving_home)
    if not bool(terrain.get("ok", false)):
        return terrain
    var door := door_at(snapshot, to_cell)
    if door != null and not door_allows_route_for_entry(entry, door, from_cell, moving_home):
        return { "ok": false, "reason": "private_door_not_routeable" }
    if static_blocker(snapshot, to_cell) != null and not relax_target_blockers:
        return { "ok": false, "reason": "blocked_static" }
    if door == null:
        var collision_blocker := static_collision_blocker(snapshot, to_cell)
        if not collision_blocker.is_empty():
            return {
                "ok": false,
                "reason": "blocked_static_collision",
                "transitionReason": "blocked_static_collision",
                "blockerCell": collision_blocker.get("cell", INVALID_CELL),
                "blockType": collision_blocker.get("blockType", "")
            }
    if to_cell != from_cell and prop_clearance_blocker(snapshot, to_cell) != null and not relax_target_blockers:
        return { "ok": false, "reason": "blocked_prop_clearance" }
    if not ignore_dynamic and dynamic_blocker(snapshot, to_cell) != null and not relax_target_blockers:
        return { "ok": false, "reason": "blocked_dynamic" }
    return { "ok": true, "reason": "" }

func cell_bridge_search_pathable(entry: Dictionary, snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i, target_cells: Dictionary, ignore_dynamic := false) -> Dictionary:
    var allow_outside := bool(snapshot.get("allowOutside", false))
    var moving_home := bool(snapshot.get("movingHome", false))
    var relax_target_blockers := target_cells.has(to_cell) and not bool(target_cells.get("_strictTargetCollision", false))
    if not cell_allowed_area(entry, to_cell, allow_outside, moving_home):
        return { "ok": false, "reason": "outside_area" }
    if private_interior_blocks_entry(entry, to_cell):
        return { "ok": false, "reason": "private_interior_not_routeable" }
    var terrain := terrain_allows_step(from_cell, to_cell, moving_home)
    if not bool(terrain.get("ok", false)):
        return terrain
    var door := door_at(snapshot, to_cell)
    if door != null and not door_allows_route_for_entry(entry, door, from_cell, moving_home):
        return { "ok": false, "reason": "private_door_not_routeable" }
    if static_blocker(snapshot, to_cell) != null and not relax_target_blockers:
        return { "ok": false, "reason": "blocked_static" }
    if door == null:
        var collision_blocker := static_collision_blocker(snapshot, to_cell)
        if not collision_blocker.is_empty():
            return {
                "ok": false,
                "reason": "blocked_static_collision",
                "transitionReason": "blocked_static_collision",
                "blockerCell": collision_blocker.get("cell", INVALID_CELL),
                "blockType": collision_blocker.get("blockType", "")
            }
    if to_cell != from_cell and prop_clearance_blocker(snapshot, to_cell) != null and not relax_target_blockers:
        return { "ok": false, "reason": "blocked_prop_clearance" }
    if not ignore_dynamic and dynamic_blocker(snapshot, to_cell) != null and not relax_target_blockers:
        return { "ok": false, "reason": "blocked_dynamic" }
    return { "ok": true, "reason": "" }

func cell_transition_pathable(entry: Dictionary, snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i, target_cells: Dictionary, ignore_dynamic := false) -> Dictionary:
    var base := cell_pathable(entry, snapshot, from_cell, to_cell, target_cells, ignore_dynamic)
    if not bool(base.get("ok", false)):
        return base
    var moving_home := bool(snapshot.get("movingHome", false))
    var door_check := _transition_door_collision_pathable(entry, snapshot, from_cell, to_cell, moving_home)
    if not bool(door_check.get("ok", false)):
        return door_check
    var static_check := _transition_static_collision_pathable(snapshot, from_cell, to_cell)
    if not bool(static_check.get("ok", false)):
        return static_check
    return { "ok": true, "reason": "" }

func validate_waypoint_route(entry: Dictionary, snapshot: Dictionary, points: Array, target_cells: Dictionary, ignore_dynamic := true) -> Dictionary:
    if points.size() < 2:
        return { "ok": true, "reason": "" }
    var avoid_lookup := {}
    for cell_value in entry.get("routeDynamicAvoidCells", []):
        if cell_value is Vector2i:
            avoid_lookup[cell_value] = true
    var previous_point: Vector3 = points[0]
    var previous_cell := world_cell(previous_point)
    var checked_transitions := {}
    for index in range(1, points.size()):
        if not (points[index] is Vector3):
            continue
        var next_point: Vector3 = points[index]
        var sample_cell := world_cell(next_point)
        if sample_cell == previous_cell:
            previous_point = next_point
            continue
        var cursor := previous_cell
        while cursor != sample_cell:
            var delta := sample_cell - cursor
            var step := Vector2i(clampi(delta.x, -1, 1), clampi(delta.y, -1, 1))
            var next_cursor := cursor + step
            var transition_key := "%d,%d>%d,%d" % [cursor.x, cursor.y, next_cursor.x, next_cursor.y]
            if checked_transitions.has(transition_key):
                cursor = next_cursor
                continue
            if avoid_lookup.has(next_cursor) and not target_cells.has(next_cursor):
                return {
                    "ok": false,
                    "reason": "path_crosses_static_collision",
                    "transitionReason": "route_avoid_cell",
                    "fromCell": cursor,
                    "toCell": next_cursor,
                    "blockerCell": next_cursor,
                    "segmentIndex": index - 1
                }
            var transition := cell_transition_pathable(entry, snapshot, cursor, next_cursor, target_cells, ignore_dynamic)
            if not bool(transition.get("ok", false)):
                var transition_reason := String(transition.get("transitionReason", transition.get("reason", "transition_blocked")))
                transition["ok"] = false
                transition["reason"] = "path_crosses_static_collision"
                transition["transitionReason"] = transition_reason
                transition["fromCell"] = cursor
                transition["toCell"] = next_cursor
                transition["segmentIndex"] = index - 1
                return transition
            checked_transitions[transition_key] = true
            cursor = next_cursor
        previous_cell = sample_cell
        previous_point = next_point
    return { "ok": true, "reason": "" }
func _transition_door_collision_pathable(entry: Dictionary, snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i, moving_home := false) -> Dictionary:
    var from_position := cell_position(from_cell)
    var to_position := cell_position(to_cell)
    var records := _transition_collision_records(snapshot, "doorCollisionByCell", from_cell, to_cell)
    for record in records:
        if not _segment_intersects_collision_record(from_position, to_position, record):
            continue
        var door_value = record.get("node", null)
        if door_value == null or not is_instance_valid(door_value) or not (door_value is Node):
            continue
        var door: Node = door_value
        if not _door_transition_allows(entry, door, from_cell, to_cell, moving_home):
            return {
                "ok": false,
                "reason": "door_transition_blocked",
                "transitionReason": "door_transition_blocked",
                "blockerCell": record.get("cell", INVALID_CELL),
                "blockType": record.get("blockType", ""),
                "portalId": _door_portal_id(door, door_flat_cell(door))
            }
    return { "ok": true, "reason": "" }

func _transition_static_collision_pathable(snapshot: Dictionary, from_cell: Vector2i, to_cell: Vector2i) -> Dictionary:
    var from_position := cell_position(from_cell)
    var to_position := cell_position(to_cell)
    var records := _transition_collision_records(snapshot, "staticCollisionByCell", from_cell, to_cell)
    for record in records:
        if not _segment_intersects_collision_record(from_position, to_position, record):
            continue
        var blocker_cell: Vector2i = record.get("cell", INVALID_CELL)
        if String(record.get("blockType", "")) == "prop" and blocker_cell != from_cell and blocker_cell != to_cell:
            continue
        var node_value = record.get("node", null)
        if node_value != null and not is_instance_valid(node_value):
            continue
        return {
            "ok": false,
            "reason": "blocked_static_transition",
            "transitionReason": "blocked_static_transition",
            "blockerCell": blocker_cell,
            "blockType": record.get("blockType", "")
        }
    return { "ok": true, "reason": "" }

func static_collision_blocker(snapshot: Dictionary, cell: Vector2i) -> Dictionary:
    var position := cell_position(cell)
    var records := _transition_collision_records(snapshot, "staticCollisionByCell", cell, cell)
    for record in records:
        var node_value = record.get("node", null)
        if node_value != null and not is_instance_valid(node_value):
            continue
        var blocker_cell: Vector2i = record.get("cell", INVALID_CELL)
        if String(record.get("blockType", "")) == "prop" and blocker_cell != cell:
            continue
        if _point_inside_collision_record(position, record):
            return record
    return {}

func _transition_collision_records(snapshot: Dictionary, index_key: String, from_cell: Vector2i, to_cell: Vector2i) -> Array:
    var index: Dictionary = snapshot.get(index_key, {})
    if index.is_empty():
        return []
    var min_x := mini(from_cell.x, to_cell.x) - 1
    var max_x := maxi(from_cell.x, to_cell.x) + 1
    var min_z := mini(from_cell.y, to_cell.y) - 1
    var max_z := maxi(from_cell.y, to_cell.y) + 1
    var result := []
    var seen := {}
    for z in range(min_z, max_z + 1):
        for x in range(min_x, max_x + 1):
            var key := Vector2i(x, z)
            for record_value in index.get(key, []):
                if not (record_value is Dictionary):
                    continue
                var record: Dictionary = record_value
                var id := String(record.get("id", ""))
                if id == "" or seen.has(id):
                    continue
                seen[id] = true
                result.append(record)
    return result

func _segment_intersects_collision_record(from_position: Vector3, to_position: Vector3, record: Dictionary) -> bool:
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    var min_point := Vector2(float(record.get("minX", 0.0)) - inflation, float(record.get("minZ", 0.0)) - inflation)
    var max_point := Vector2(float(record.get("maxX", 0.0)) + inflation, float(record.get("maxZ", 0.0)) + inflation)
    return _segment_intersects_aabb_2d(Vector2(from_position.x, from_position.z), Vector2(to_position.x, to_position.z), min_point, max_point)

func _point_inside_collision_record(position: Vector3, record: Dictionary) -> bool:
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    var x := position.x
    var z := position.z
    return x >= float(record.get("minX", 0.0)) - inflation \
        and x <= float(record.get("maxX", 0.0)) + inflation \
        and z >= float(record.get("minZ", 0.0)) - inflation \
        and z <= float(record.get("maxZ", 0.0)) + inflation

func _segment_intersects_aabb_2d(from_point: Vector2, to_point: Vector2, min_point: Vector2, max_point: Vector2) -> bool:
    var delta := to_point - from_point
    var t_min := 0.0
    var t_max := 1.0
    if absf(delta.x) < 0.0001:
        if from_point.x < min_point.x or from_point.x > max_point.x:
            return false
    else:
        var tx1 := (min_point.x - from_point.x) / delta.x
        var tx2 := (max_point.x - from_point.x) / delta.x
        t_min = maxf(t_min, minf(tx1, tx2))
        t_max = minf(t_max, maxf(tx1, tx2))
    if absf(delta.y) < 0.0001:
        if from_point.y < min_point.y or from_point.y > max_point.y:
            return false
    else:
        var ty1 := (min_point.y - from_point.y) / delta.y
        var ty2 := (max_point.y - from_point.y) / delta.y
        t_min = maxf(t_min, minf(ty1, ty2))
        t_max = minf(t_max, maxf(ty1, ty2))
    return t_max >= t_min and t_max >= 0.0 and t_min <= 1.0

func _door_transition_allows(entry: Dictionary, door: Node, from_cell: Vector2i, to_cell: Vector2i, moving_home := false) -> bool:
    if door == null:
        return false
    if bool(door.get_meta("locked", false)) or bool(door.get_meta("jammed", false)) or bool(door.get_meta("destroyed", false)) or bool(door.get_meta("unloaded", false)):
        return false
    var door_state := String(door.get_meta("door_state", NpcEnumsScript.DOOR_STATE_CLOSED))
    if door_state in [String(NpcEnumsScript.DOOR_STATE_LOCKED), String(NpcEnumsScript.DOOR_STATE_JAMMED), String(NpcEnumsScript.DOOR_STATE_DESTROYED), String(NpcEnumsScript.DOOR_STATE_UNLOADED)]:
        return false
    var door_cell := door_flat_cell(door)
    if door_cell == INVALID_CELL:
        return false
    if from_cell != door_cell and to_cell != door_cell:
        return false
    var delta := to_cell - from_cell
    if maxi(absi(delta.x), absi(delta.y)) != 1:
        return false
    var axis := _door_crossing_axis(door)
    if axis == "x" and not (absi(delta.x) == 1 and delta.y == 0):
        return false
    if axis == "z" and not (delta.x == 0 and absi(delta.y) == 1):
        return false
    var reference_cell := from_cell if to_cell == door_cell else to_cell
    return door_allows_route_for_entry(entry, door, reference_cell, moving_home)

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

func forbidden_private_door_portal_ids_for_entry(entry: Dictionary) -> Array[String]:
    var result: Array[String] = []
    var snapshot := cached_static_tile_snapshot(true, true)
    var doors: Dictionary = snapshot.get("doors", {})
    for cell_value in doors.keys():
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var door := door_at(snapshot, cell)
        if door == null:
            continue
        if String(door.get_meta("door_policy", "private_home")) != "private_home":
            continue
        if private_home_door_matches_entry(entry, door):
            continue
        var portal_id := _door_portal_id(door, cell)
        if portal_id != "" and not result.has(portal_id):
            result.append(portal_id)
    result.sort()
    return result

func entry_body_inside_home(entry: Dictionary) -> bool:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    var portal = null
    if main != null and main.get("npc_system") != null:
        var npc_system = main.get("npc_system")
        var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
        if autonomy != null and autonomy.get("door_portals") != null:
            portal = HomeInteriorServiceScript.portal_for_entry(entry, autonomy.get("door_portals"))
    return bool(HomeInteriorServiceScript.status(entry, body.global_position, portal).get("strictInside", false))

func cell_inside_entry_home(entry: Dictionary, cell: Vector2i) -> bool:
    return HomeInteriorServiceScript.cell_inside_home_bounds(entry, cell, true)

func private_interior_blocks_entry(entry: Dictionary, cell: Vector2i) -> bool:
    if entry.is_empty() or main == null or main.get("structure_system") == null:
        return false
    if cell_inside_entry_home(entry, cell):
        return false
    var structure_system = main.get("structure_system")
    var records := private_interior_records_for_entry(entry, structure_system)
    for record_value in records:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        if record_interior_contains_cell(record, cell):
            return true
    return tutorial_starter_interior_blocks_cell(cell)

func private_interior_records_for_entry(_entry: Dictionary, structure_system) -> Array:
    if cached_private_interior_records_revision == static_snapshot_revision:
        return cached_private_interior_records
    var records: Array = []
    if structure_system == null or not structure_system.has_method("town_home_records_snapshot"):
        cached_private_interior_records_revision = static_snapshot_revision
        cached_private_interior_records = records
        return records
    var records_by_town: Dictionary = structure_system.town_home_records_snapshot()
    for key_value in records_by_town.keys():
        var town_records_value = records_by_town.get(key_value, [])
        if town_records_value is Array:
            records.append_array(town_records_value)
    cached_private_interior_records_revision = static_snapshot_revision
    cached_private_interior_records = records
    return records

func record_interior_contains_cell(record: Dictionary, cell: Vector2i) -> bool:
    var interior_min: Vector2i = record.get("interiorMinCell", record.get("homeCell", INVALID_CELL))
    var interior_max: Vector2i = record.get("interiorMaxCell", record.get("homeCell", INVALID_CELL))
    if interior_min == INVALID_CELL or interior_max == INVALID_CELL:
        return false
    return cell.x >= mini(interior_min.x, interior_max.x) \
        and cell.x <= maxi(interior_min.x, interior_max.x) \
        and cell.y >= mini(interior_min.y, interior_max.y) \
        and cell.y <= maxi(interior_min.y, interior_max.y)

func tutorial_starter_interior_blocks_cell(cell: Vector2i) -> bool:
    if main == null or main.get("tutorial_system") == null:
        return false
    var tutorial = main.get("tutorial_system")
    if not tutorial.has_method("state"):
        return false
    var state: Dictionary = tutorial.call("state")
    var start_value = state.get("startCell", INVALID_CELL)
    var start_cell: Vector2i = HomeInteriorServiceScript.cell_value(start_value, INVALID_CELL)
    if start_cell == INVALID_CELL:
        return false
    var bounds := tutorial_starter_structure_bounds(start_cell)
    var min_cell: Vector2i = bounds.get("min", start_cell)
    var max_cell: Vector2i = bounds.get("max", start_cell)
    var interior_min := Vector2i(min_cell.x + 1, min_cell.y + 2)
    var interior_max := Vector2i(max_cell.x - 1, max_cell.y - 1)
    return cell.x >= mini(interior_min.x, interior_max.x) \
        and cell.x <= maxi(interior_min.x, interior_max.x) \
        and cell.y >= mini(interior_min.y, interior_max.y) \
        and cell.y <= maxi(interior_min.y, interior_max.y)

func tutorial_starter_structure_bounds(start_cell: Vector2i) -> Dictionary:
    var cache_key := "%d:%d,%d" % [static_snapshot_revision, start_cell.x, start_cell.y]
    if cached_tutorial_starter_bounds_key == cache_key and not cached_tutorial_starter_bounds.is_empty():
        return cached_tutorial_starter_bounds
    var min_cell := Vector2i(start_cell.x - 4, start_cell.y - 5)
    var max_cell := Vector2i(start_cell.x + 4, start_cell.y + 4)
    if main == null:
        cached_tutorial_starter_bounds_key = cache_key
        cached_tutorial_starter_bounds = { "min": min_cell, "max": max_cell }
        return cached_tutorial_starter_bounds
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        cached_tutorial_starter_bounds_key = cache_key
        cached_tutorial_starter_bounds = { "min": min_cell, "max": max_cell }
        return cached_tutorial_starter_bounds
    var blocks: Dictionary = blocks_value
    var found := false
    for block_value in blocks.values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block) or not block.has_meta("cell"):
            continue
        var block_type := String(block.get_meta("block_type", ""))
        if block_type == "torch" or block_type == "cobblestonePath":
            continue
        var cell_value = block.get_meta("cell")
        if not (cell_value is Vector3i):
            continue
        var cell3: Vector3i = cell_value
        var flat := Vector2i(cell3.x, cell3.z)
        if abs(flat.x - start_cell.x) > 9 or abs(flat.y - start_cell.y) > 9:
            continue
        if not found:
            min_cell = flat
            max_cell = flat
            found = true
        else:
            min_cell.x = mini(min_cell.x, flat.x)
            min_cell.y = mini(min_cell.y, flat.y)
            max_cell.x = maxi(max_cell.x, flat.x)
            max_cell.y = maxi(max_cell.y, flat.y)
    cached_tutorial_starter_bounds_key = cache_key
    cached_tutorial_starter_bounds = { "min": min_cell, "max": max_cell }
    return cached_tutorial_starter_bounds

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
    if door == null and not static_collision_blocker(snapshot, cell).is_empty():
        return {}
    if prop_clearance_blocker(snapshot, cell) != null:
        return {}
    var position := cell_position(cell)
    var span_y := floori(position.y / CELL)
    position.y = float(span_y) * CELL + 0.04
    var traversal_tags: Array[String] = ["terrain"]
    var semantic_region_ids: Array[String] = []
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
        var axis := _door_crossing_axis(door, snapshot, cell)
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

func _door_crossing_axis(door: Node, snapshot := {}, cell := INVALID_CELL) -> String:
    if door == null:
        return "z"
    var side := int(door.get_meta("door_side", -1))
    if side == 1 or side == 3:
        return "x"
    if side == 0 or side == 2:
        return "z"
    if snapshot is Dictionary and cell is Vector2i:
        var door_cell: Vector2i = cell
        var x_blocked := static_blocker(snapshot, door_cell + Vector2i(-1, 0)) != null \
            or static_blocker(snapshot, door_cell + Vector2i(1, 0)) != null
        var z_blocked := static_blocker(snapshot, door_cell + Vector2i(0, -1)) != null \
            or static_blocker(snapshot, door_cell + Vector2i(0, 1)) != null
        if z_blocked and not x_blocked:
            return "x"
        if x_blocked and not z_blocked:
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
    for cell in approach_candidate_cells_for_target(entry, target_position, allow_outside):
        if cell_is_standable_goal(entry, cell, allow_outside, false):
            result.append(cell)
    result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return cell_distance(a, target_cell) < cell_distance(b, target_cell)
    )
    return result


# Raw geometry only. Collision-backed consumers validate these poses through their
# own snapshot so that validation can be scheduled under the route budget.
func approach_candidate_cells_for_target(_entry: Dictionary, target_position: Vector3, _allow_outside := true) -> Array[Vector2i]:
    var target_cell := world_cell(target_position)
    var result: Array[Vector2i] = []
    for radius in range(1, 4):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if max(abs(dx), abs(dz)) != radius:
                    continue
                result.append(target_cell + Vector2i(dx, dz))
    result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return cell_distance(a, target_cell) < cell_distance(b, target_cell)
    )
    return result

func cell_is_standable_goal(entry: Dictionary, cell: Vector2i, allow_outside := false, moving_home := false) -> bool:
    if not cell_allowed_area(entry, cell, allow_outside, moving_home):
        return false
    if private_interior_blocks_entry(entry, cell):
        return false
    var terrain := terrain_allows_step(cell, cell, moving_home)
    if not bool(terrain.get("ok", false)):
        return false
    var snapshot := cached_validation_snapshot(entry, allow_outside, moving_home)
    var door := door_at(snapshot, cell)
    if door != null and not door_allows_route_for_entry(entry, door, cell, moving_home):
        return false
    if door == null and not static_collision_blocker(snapshot, cell).is_empty():
        return false
    if static_blocker(snapshot, cell) != null:
        return false
    if prop_clearance_blocker(snapshot, cell) != null:
        return false
    if dynamic_blocker(snapshot, cell) != null:
        return false
    return true

func cell_is_static_standable_goal(entry: Dictionary, cell: Vector2i, allow_outside := false, moving_home := false) -> bool:
    if not cell_allowed_area(entry, cell, allow_outside, moving_home):
        return false
    if private_interior_blocks_entry(entry, cell):
        return false
    var terrain := terrain_allows_step(cell, cell, moving_home)
    if not bool(terrain.get("ok", false)):
        return false
    var snapshot := static_validation_snapshot(entry, allow_outside, moving_home)
    var door := door_at(snapshot, cell)
    if door != null and not door_allows_route_for_entry(entry, door, cell, moving_home):
        return false
    if door == null and not static_collision_blocker(snapshot, cell).is_empty():
        return false
    if static_blocker(snapshot, cell) != null:
        return false
    if prop_clearance_blocker(snapshot, cell) != null:
        return false
    return true


func static_validation_snapshot(entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
    if cached_revision == "" and cached_blocked.is_empty() and cached_doors.is_empty() and cached_paths.is_empty() and cached_props.is_empty():
        build_snapshot(entry, allow_outside, moving_home)
    return {
        "revision": revision(),
        "staticSnapshotRevision": static_snapshot_revision,
        "dynamicRevision": dynamic_revision,
        "semanticRevision": semantic_revision,
        "doorStateRevision": door_state_revision,
        "blocked": cached_blocked,
        "doors": cached_doors,
        "paths": cached_paths,
        "props": cached_props,
        "propClearance": cached_prop_clearance,
        "staticCollision": cached_static_collision_records,
        "staticCollisionByCell": cached_static_collision_by_cell,
        "doorCollision": cached_door_collision_records,
        "doorCollisionByCell": cached_door_collision_by_cell,
        "dynamic": {},
        "allowOutside": allow_outside,
        "movingHome": moving_home
    }
