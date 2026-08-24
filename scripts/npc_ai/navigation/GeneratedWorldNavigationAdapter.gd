extends RefCounted
class_name GeneratedWorldNavigationAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")
const BuildingNavigationTransitionCertifierScript := preload("res://scripts/buildings/BuildingNavigationTransitionCertifier.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const NAV_TILE_CELL_SIZE := NpcConstantsScript.NAV_TILE_CELL_SIZE
const INVALID_CELL := Vector2i(999999, 999999)
const PROP_COLLISION_RADIUS := CELL * 0.82
const PROP_NAV_CLEARANCE_RADIUS := PROP_COLLISION_RADIUS + NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
const DOOR_LINK_ENTER_COST := CELL * 18.0
const ROUTE_NAVMESH_MARGIN_CELLS := 4
const ROUTE_NAVMESH_MAX_TILES := 32
const NAV_TERRAIN_PROJECTION_UP_CELLS := 8
const NAV_TERRAIN_PROJECTION_DOWN_CELLS := 24
const NAV_TERRAIN_PROJECTION_MAX_SURFACE_DEVIATION := CELL * 1.10
const TRANSITION_COLLISION_INFLATION := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
const TRANSITION_RECORD_INDEX_MARGIN_CELLS := 2
const TRANSITION_RECORD_INDEX_MAX_CELLS := 96
const NAVMESH_TILE_SNAPSHOT_CACHE_LIMIT := 96
const BUILDING_SUPPORT_NAV_SAMPLE_STEP := 0.32
const BUILDING_SUPPORT_NAV_CLEARANCE := TRANSITION_COLLISION_INFLATION
const DOOR_PORTAL_PHYSICAL_COLLISION_INFLATION := NpcConstantsScript.DEFAULT_NPC_RADIUS
const DOOR_PORTAL_VALIDATION_POINT_EPSILON := CELL * 0.08
const BUILDING_SUPPORT_SEAM_MAX_ENDPOINT_DISTANCE := CELL * 0.22
const BUILDING_NAVIGATION_LINK_MAX_ENDPOINT_DRIFT := CELL * 0.34
const BUILDING_STAIR_LINK_MAX_ENDPOINT_DRIFT := CELL * 0.78
const BUILDING_SUPPORT_STACK_MAX_SEPARATION := CELL * 0.50
const BUILDING_SUPPORT_STACK_EPSILON := 0.01
const BUILDING_SUPPORT_TRANSITION_MAX_GAP := 0.04
const BUILDING_SUPPORT_TRANSITION_MAX_OVERLAP := CELL * 0.05
const CONTINUOUS_SUPPORT_SEAM_MAX_GAP := 0.01
const CONTINUOUS_SUPPORT_SEAM_MAX_HEIGHT_DELTA := 0.01

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
var cached_static_collision_broad: Array[Dictionary] = []
var cached_door_collision_records: Array[Dictionary] = []
var cached_door_collision_by_cell := {}
var surface_transition_publication_failures: Array[Dictionary] = []
var continuous_surface_transition_certificates: Array[Dictionary] = []
var cached_building_supports: Array[Dictionary] = []
var cached_building_supports_by_tile := {}
var cached_building_support_by_id := {}
var cached_building_support_ids_valid := true
var cached_building_vertical_links: Array[Dictionary] = []
var cached_building_support_seam_links: Array[Dictionary] = []
var cached_building_interior_passage_links: Array[Dictionary] = []
var cached_building_doors: Array[Dictionary] = []
var cached_private_interior_records_revision := ""
var cached_private_interior_records: Array = []
var height_cache := {}
var terrain_projection_cache := {}
var navmesh_tile_snapshot_cache := {}
var navmesh_tile_snapshot_cache_order: Array[String] = []
var navmesh_tile_snapshot_build_jobs := {}
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
    cached_private_interior_records_revision = ""
    dynamic_occupant_cache_frame_key = ""
    dynamic_occupant_cache = {}
    cached_private_interior_records = []

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
        if static_changed_tiles.is_empty():
            navmesh_tile_revision_by_key.clear()
        else:
            for tile_key in static_changed_tiles:
                _mark_navmesh_tile_and_seam_neighbors_changed(tile_key)
    if dynamic_changed:
        dynamic_revision = maxi(dynamic_revision + 1, last_event_revision)
    if semantic_changed:
        semantic_revision = maxi(semantic_revision + 1, last_event_revision)
        if semantic_global_changed or semantic_changed_tiles.is_empty():
            navmesh_tile_semantic_revision_by_key.clear()
        else:
            for changed_tile_key in semantic_changed_tiles:
                navmesh_tile_semantic_revision_by_key[changed_tile_key] = semantic_revision
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
        "staticCollisionBroad": cached_static_collision_broad,
        "doorCollision": cached_door_collision_records,
        "doorCollisionByCell": cached_door_collision_by_cell,
        "buildingSupports": cached_building_supports,
        "buildingVerticalLinks": cached_building_vertical_links,
        "buildingSupportSeamLinks": cached_building_support_seam_links,
        "buildingInteriorPassageLinks": cached_building_interior_passage_links,
        "dynamic": dynamic_cells,
        "allowOutside": allow_outside,
        "movingHome": moving_home
    }

func revision() -> String:
    return "%d:%d:%d:%d" % [static_snapshot_revision, dynamic_revision, semantic_revision, door_state_revision]

func navmesh_tile_source_key() -> String:
    return "%d:%d:%d" % [static_snapshot_revision, 0, door_state_revision]

func navmesh_tile_source_key_for_tile(tile_key: String) -> String:
    if tile_key == "":
        return navmesh_tile_source_key()
    if not navmesh_tile_revision_by_key.has(tile_key):
        navmesh_tile_revision_by_key[tile_key] = static_snapshot_revision
    var tile_revision := int(navmesh_tile_revision_by_key.get(tile_key, static_snapshot_revision))
    if not navmesh_tile_semantic_revision_by_key.has(tile_key):
        navmesh_tile_semantic_revision_by_key[tile_key] = semantic_revision
    if not navmesh_tile_door_revision_by_key.has(tile_key):
        navmesh_tile_door_revision_by_key[tile_key] = door_state_revision
    var tile_door_revision := int(navmesh_tile_door_revision_by_key.get(tile_key, door_state_revision))
    return "%d:%d:%d" % [tile_revision, 0, tile_door_revision]

func _mark_navmesh_tile_and_seam_neighbors_changed(tile_key: String) -> void:
    for affected_key in navmesh_affected_tile_keys_for_change(tile_key):
        navmesh_tile_revision_by_key[affected_key] = static_snapshot_revision
        _clear_navmesh_tile_snapshot_cache_for_tile(affected_key)

func navmesh_affected_tile_keys_for_change(tile_key: String) -> Array[String]:
    var result: Array[String] = []
    if tile_key.is_empty():
        return result
    var tile := _parse_tile_key(tile_key)
    for offset in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
        var affected: Vector2i = tile + (offset as Vector2i)
        result.append("%d,%d" % [affected.x, affected.y])
    result.sort()
    return result

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


func building_navigation_topology_tile_keys() -> Array[String]:
    cached_static_tile_snapshot(true, true)
    var tile_keys := {}
    for support_value in cached_building_supports:
        if support_value is Dictionary:
            _append_navigation_topology_tile_keys(tile_keys, (support_value as Dictionary).get("tileKeys", []))
    for door_value in cached_building_doors:
        if door_value is Dictionary:
            _append_navigation_topology_tile_keys(tile_keys, (door_value as Dictionary).get("tileKeys", []))
    for links_value in [cached_building_vertical_links, cached_building_support_seam_links, cached_building_interior_passage_links]:
        if not (links_value is Array):
            continue
        for link_value in links_value:
            if not (link_value is Dictionary):
                continue
            var link: Dictionary = link_value
            _append_navigation_topology_tile_keys(tile_keys, link.get("tileKeys", []))
            _append_navigation_topology_tile_keys(tile_keys, [
                _building_navigation_link_owner_tile_key(link),
                String(link.get("startTileKey", "")),
                String(link.get("endTileKey", ""))
            ])
    var result: Array[String] = []
    for tile_key_value in tile_keys.keys():
        result.append(String(tile_key_value))
    result.sort()
    return result


func _append_navigation_topology_tile_keys(result: Dictionary, values) -> void:
    if not (values is Array):
        return
    for value in values:
        var tile_key := String(value).strip_edges()
        if not tile_key.is_empty():
            result[tile_key] = true

# IMPORTANT: navmesh tile snapshots must be built from the same live collision
# snapshot used by collision probing. Do not switch this back to the lighter
# helper that only updates blocked/doors/paths; that reintroduces planner/probe
# disagreement and makes NPCs accept routes into walls or reject valid routes.
func build_navmesh_tile_snapshot(tile_key: String) -> Dictionary:
    var source_key := navmesh_tile_source_key_for_tile(tile_key)
    var cache_key := "%s|%s" % [tile_key, source_key]
    if navmesh_tile_snapshot_cache.has(cache_key):
        return navmesh_tile_snapshot_cache.get(cache_key, {}) as Dictionary
    var job := _new_navmesh_tile_snapshot_build_job(tile_key, source_key)
    while String(job.get("status", "pending_budget")) == "pending_budget":
        _advance_navmesh_tile_snapshot_build_job(job, 0)
    return job.get("snapshot", {}) as Dictionary


func advance_navmesh_tile_snapshot_build(tile_key: String, budget_usec := 2500) -> Dictionary:
    var source_key := navmesh_tile_source_key_for_tile(tile_key)
    var cache_key := "%s|%s" % [tile_key, source_key]
    if navmesh_tile_snapshot_cache.has(cache_key):
        return {"status": "ready", "snapshot": navmesh_tile_snapshot_cache.get(cache_key, {}), "tileKey": tile_key, "sourceKey": source_key, "cached": true}
    var job: Dictionary = navmesh_tile_snapshot_build_jobs.get(tile_key, {}) if navmesh_tile_snapshot_build_jobs.get(tile_key, {}) is Dictionary else {}
    if not job.is_empty() and String(job.get("sourceKey", "")) != source_key:
        navmesh_tile_snapshot_build_jobs.erase(tile_key)
        var monitor = performance_monitor()
        if monitor != null:
            monitor.increment_counter("navmesh_tile_snapshot_build_cancellations")
        job = {}
    if job.is_empty():
        job = _new_navmesh_tile_snapshot_build_job(tile_key, source_key)
        navmesh_tile_snapshot_build_jobs[tile_key] = job
    _advance_navmesh_tile_snapshot_build_job(job, maxi(1, budget_usec))
    if String(job.get("status", "pending_budget")) == "ready":
        navmesh_tile_snapshot_build_jobs.erase(tile_key)
        return {"status": "ready", "snapshot": job.get("snapshot", {}), "tileKey": tile_key, "sourceKey": source_key, "cached": false, "buildMetrics": job.get("metrics", {}).duplicate(true)}
    if String(job.get("status", "pending_budget")) in ["failed", "cancelled"]:
        navmesh_tile_snapshot_build_jobs.erase(tile_key)
        return {"status": String(job.get("status", "failed")), "reason": String(job.get("reason", "snapshot_build_failed")), "snapshot": {}, "tileKey": tile_key, "sourceKey": source_key, "buildMetrics": job.get("metrics", {}).duplicate(true)}
    return {"status": "pending_budget", "tileKey": tile_key, "sourceKey": source_key, "stage": String(job.get("stage", "")), "buildMetrics": job.get("metrics", {}).duplicate(true)}


func _new_navmesh_tile_snapshot_build_job(tile_key: String, source_key: String) -> Dictionary:
    return {
        "status": "pending_budget",
        "stage": "base",
        "tileKey": tile_key,
        "sourceKey": source_key,
        "tileRevision": int(navmesh_tile_revision_by_key.get(tile_key, static_snapshot_revision)),
        "metrics": {"sliceCount": 0, "maxSliceUsec": 0, "maxAtomicUsec": 0, "overBudgetSlices": 0, "atomicOverruns": 0}
    }


func _advance_navmesh_tile_snapshot_build_job(job: Dictionary, budget_usec: int) -> void:
    var started_usec := Time.get_ticks_usec()
    var processed_units := 0
    while String(job.get("status", "pending_budget")) == "pending_budget":
        if processed_units > 0 and budget_usec > 0 and Time.get_ticks_usec() - started_usec >= budget_usec:
            break
        var atomic_started_usec := Time.get_ticks_usec()
        var stage := String(job.get("stage", "base"))
        match stage:
            "base":
                _advance_navmesh_snapshot_base(job)
            "terrain":
                _advance_navmesh_snapshot_terrain_cell(job)
            "support_samples":
                _advance_navmesh_snapshot_support_sample(job)
            "support_surfaces":
                _advance_navmesh_snapshot_support_surfaces(job)
            "declared_links":
                _advance_navmesh_snapshot_declared_links(job)
            "transition_samples":
                _advance_navmesh_snapshot_transition_sample(job)
            "derived_links":
                _advance_navmesh_snapshot_derived_links(job)
            "finalize":
                _finalize_navmesh_tile_snapshot_build(job)
            _:
                job["status"] = "failed"
                job["reason"] = "invalid_snapshot_build_stage"
        processed_units += 1
        var atomic_usec := Time.get_ticks_usec() - atomic_started_usec
        var metrics: Dictionary = job.get("metrics", {}) as Dictionary
        metrics["maxAtomicUsec"] = maxi(int(metrics.get("maxAtomicUsec", 0)), atomic_usec)
        if budget_usec > 0 and atomic_usec > budget_usec * 2:
            metrics["atomicOverruns"] = int(metrics.get("atomicOverruns", 0)) + 1
        var monitor = performance_monitor()
        if monitor != null:
            monitor.observe_duration("navmesh_tile_snapshot_build_atomic", float(atomic_usec) / 1000.0)
            if budget_usec > 0 and atomic_usec > budget_usec * 2:
                monitor.increment_counter("navmesh_tile_snapshot_atomic_overruns")
    var slice_usec := Time.get_ticks_usec() - started_usec
    var metrics: Dictionary = job.get("metrics", {}) as Dictionary
    metrics["sliceCount"] = int(metrics.get("sliceCount", 0)) + 1
    metrics["maxSliceUsec"] = maxi(int(metrics.get("maxSliceUsec", 0)), slice_usec)
    if budget_usec > 0 and slice_usec > budget_usec * 2:
        metrics["overBudgetSlices"] = int(metrics.get("overBudgetSlices", 0)) + 1
    var monitor = performance_monitor()
    if monitor != null:
        monitor.observe_duration("navmesh_tile_snapshot_build_slice", float(slice_usec) / 1000.0)
        if budget_usec > 0 and slice_usec > budget_usec * 2:
            monitor.increment_counter("navmesh_tile_snapshot_over_budget_slices")


func _advance_navmesh_snapshot_base(job: Dictionary) -> void:
    if not cached_building_support_ids_valid:
        job["status"] = "failed"
        job["reason"] = "duplicate_building_support_ids"
        job["snapshot"] = {}
        return
    var monitor = performance_monitor()
    var tile_key := String(job.get("tileKey", ""))
    var base_start: int = monitor.begin_section("navmesh_tile_snapshot_base") if monitor != null else Time.get_ticks_usec()
    var snapshot: Dictionary = _navmesh_snapshot_with_live_tile_blocks(cached_static_tile_snapshot(true, true), tile_key)
    if monitor != null:
        monitor.end_section("navmesh_tile_snapshot_base", base_start)
    var tile := _parse_tile_key(tile_key)
    job["snapshotBase"] = snapshot
    job["minX"] = tile.x * NAV_TILE_CELL_SIZE
    job["minZ"] = tile.y * NAV_TILE_CELL_SIZE
    job["terrainCursor"] = 0
    job["surfaces"] = []
    job["semanticRegions"] = []
    job["stage"] = "terrain"


func _advance_navmesh_snapshot_terrain_cell(job: Dictionary) -> void:
    var monitor = performance_monitor()
    var terrain_start: int = monitor.begin_section("navmesh_tile_snapshot_terrain") if monitor != null else Time.get_ticks_usec()
    var cursor := int(job.get("terrainCursor", 0))
    var x := int(job.get("minX", 0)) + cursor % NAV_TILE_CELL_SIZE
    var z := int(job.get("minZ", 0)) + cursor / NAV_TILE_CELL_SIZE
    var surface := _navmesh_surface_for_cell(job.get("snapshotBase", {}) as Dictionary, Vector2i(x, z))
    if not surface.is_empty():
        (job.get("surfaces", []) as Array).append(surface)
    cursor += 1
    job["terrainCursor"] = cursor
    if monitor != null:
        monitor.end_section("navmesh_tile_snapshot_terrain", terrain_start)
    if cursor >= NAV_TILE_CELL_SIZE * NAV_TILE_CELL_SIZE:
        job["terrainSurfaces"] = (job.get("surfaces", []) as Array).duplicate()
        job["supports"] = building_supports_for_tile(String(job.get("tileKey", "")))
        job["supportIndex"] = 0
        job["buildingSampleData"] = {}
        job["supportSampleJob"] = {}
        job["stage"] = "support_samples"


func _advance_navmesh_snapshot_support_sample(job: Dictionary) -> void:
    var monitor = performance_monitor()
    var sample_start: int = monitor.begin_section("navmesh_tile_snapshot_support_samples") if monitor != null else Time.get_ticks_usec()
    var supports: Array = job.get("supports", []) as Array
    var support_index := int(job.get("supportIndex", 0))
    if support_index >= supports.size():
        job["stage"] = "support_surfaces"
        if monitor != null:
            monitor.end_section("navmesh_tile_snapshot_support_samples", sample_start)
        return
    var sample_job: Dictionary = job.get("supportSampleJob", {}) if job.get("supportSampleJob", {}) is Dictionary else {}
    if sample_job.is_empty():
        sample_job = _new_building_support_navigation_sample_job(supports[support_index] as Dictionary, job.get("snapshotBase", {}) as Dictionary, String(job.get("tileKey", "")))
        job["supportSampleJob"] = sample_job
    _advance_building_support_navigation_sample_job(sample_job)
    if bool(sample_job.get("done", false)):
        var support: Dictionary = supports[support_index] as Dictionary
        (job.get("buildingSampleData", {}) as Dictionary)[String(support.get("id", ""))] = sample_job.get("result", {})
        job["supportIndex"] = support_index + 1
        job["supportSampleJob"] = {}
    if monitor != null:
        monitor.end_section("navmesh_tile_snapshot_support_samples", sample_start)


func _advance_navmesh_snapshot_support_surfaces(job: Dictionary) -> void:
    var monitor = performance_monitor()
    var started: int = monitor.begin_section("navmesh_tile_snapshot_support_surfaces") if monitor != null else Time.get_ticks_usec()
    (job.get("surfaces", []) as Array).append_array(_navmesh_surfaces_from_building_tile(job.get("snapshotBase", {}) as Dictionary, String(job.get("tileKey", "")), 1, job.get("buildingSampleData", {}) as Dictionary))
    job["doorSummary"] = _navmesh_door_summary_for_tile(job.get("snapshotBase", {}) as Dictionary, String(job.get("tileKey", "")))
    job["stage"] = "declared_links"
    if monitor != null:
        monitor.end_section("navmesh_tile_snapshot_support_surfaces", started)


func _advance_navmesh_snapshot_declared_links(job: Dictionary) -> void:
    var monitor = performance_monitor()
    var started: int = monitor.begin_section("navmesh_tile_snapshot_declared_links") if monitor != null else Time.get_ticks_usec()
    var tile_key := String(job.get("tileKey", ""))
    var navigation_links := building_vertical_links_for_tile(tile_key)
    navigation_links.append_array(building_support_seam_links_for_tile(tile_key))
    navigation_links.append_array(building_interior_passage_links_for_tile(tile_key))
    job["navigationLinks"] = _resolve_building_navigation_link_endpoints(job.get("snapshotBase", {}) as Dictionary, navigation_links)
    job["transitionTileOffsets"] = [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
    job["transitionTileIndex"] = 0
    job["transitionSupportIndex"] = 0
    job["transitionTileSnapshot"] = {}
    job["transitionSampleJob"] = {}
    job["transitionSamples"] = []
    job["stage"] = "transition_samples"
    if monitor != null:
        monitor.end_section("navmesh_tile_snapshot_declared_links", started)


func _advance_navmesh_snapshot_transition_sample(job: Dictionary) -> void:
    var offsets: Array = job.get("transitionTileOffsets", []) as Array
    var tile_index := int(job.get("transitionTileIndex", 0))
    if tile_index >= offsets.size():
        (job.get("transitionSamples", []) as Array).sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
            return "%s|%s" % [String(left.get("tileKey", "")), String(left.get("supportId", ""))] < "%s|%s" % [String(right.get("tileKey", "")), String(right.get("supportId", ""))]
        )
        job["stage"] = "derived_links"
        return
    var origin_tile := _parse_tile_key(String(job.get("tileKey", "")))
    var sample_tile: Vector2i = origin_tile + (offsets[tile_index] as Vector2i)
    var sample_tile_key := "%d,%d" % [sample_tile.x, sample_tile.y]
    var supports: Array = building_supports_for_tile(sample_tile_key)
    var support_index := int(job.get("transitionSupportIndex", 0))
    if support_index >= supports.size():
        job["transitionTileIndex"] = tile_index + 1
        job["transitionSupportIndex"] = 0
        job["transitionTileSnapshot"] = {}
        job["transitionSampleJob"] = {}
        return
    var sample_snapshot: Dictionary = job.get("transitionTileSnapshot", {}) if job.get("transitionTileSnapshot", {}) is Dictionary else {}
    if sample_snapshot.is_empty():
        sample_snapshot = job.get("snapshotBase", {}) as Dictionary if tile_index == 0 else _navmesh_snapshot_with_live_tile_blocks(job.get("snapshotBase", {}) as Dictionary, sample_tile_key)
        job["transitionTileSnapshot"] = sample_snapshot
    var support: Dictionary = supports[support_index] as Dictionary
    var support_id := String(support.get("id", ""))
    if tile_index == 0 and (job.get("buildingSampleData", {}) as Dictionary).has(support_id):
        (job.get("transitionSamples", []) as Array).append({"supportId": support_id, "tileKey": sample_tile_key, "sampleData": (job.get("buildingSampleData", {}) as Dictionary).get(support_id, {})})
        job["transitionSupportIndex"] = support_index + 1
        return
    var sample_job: Dictionary = job.get("transitionSampleJob", {}) if job.get("transitionSampleJob", {}) is Dictionary else {}
    if sample_job.is_empty():
        sample_job = _new_building_support_navigation_sample_job(support, sample_snapshot, sample_tile_key)
        job["transitionSampleJob"] = sample_job
    _advance_building_support_navigation_sample_job(sample_job)
    if bool(sample_job.get("done", false)):
        (job.get("transitionSamples", []) as Array).append({"supportId": support_id, "tileKey": sample_tile_key, "sampleData": sample_job.get("result", {})})
        job["transitionSupportIndex"] = support_index + 1
        job["transitionSampleJob"] = {}


func _advance_navmesh_snapshot_derived_links(job: Dictionary) -> void:
    var monitor = performance_monitor()
    var started: int = monitor.begin_section("navmesh_tile_snapshot_derived_links") if monitor != null else Time.get_ticks_usec()
    (job.get("navigationLinks", []) as Array).append_array(_derived_surface_transition_links(job.get("snapshotBase", {}) as Dictionary, String(job.get("tileKey", "")), job.get("buildingSampleData", {}) as Dictionary, job.get("terrainSurfaces", []) as Array, job.get("transitionSamples", []) as Array))
    job["stage"] = "finalize"
    if monitor != null:
        monitor.end_section("navmesh_tile_snapshot_derived_links", started)


func _finalize_navmesh_tile_snapshot_build(job: Dictionary) -> void:
    var tile_key := String(job.get("tileKey", ""))
    var tile_source_key := String(job.get("sourceKey", ""))
    if navmesh_tile_source_key_for_tile(tile_key) != tile_source_key:
        job["status"] = "cancelled"
        job["reason"] = "source_revision_changed"
        return
    var tile_revision := int(job.get("tileRevision", static_snapshot_revision))
    var snapshot: Dictionary = job.get("snapshotBase", {}) as Dictionary
    var surfaces: Array = job.get("surfaces", []) as Array
    var semantic_regions: Array = job.get("semanticRegions", []) as Array
    var door_summary: Dictionary = job.get("doorSummary", {}) as Dictionary
    var navigation_links: Array = job.get("navigationLinks", []) as Array
    var result: Dictionary = {
        "tileKey": tile_key,
        "regionId": "region:chunk:%s" % tile_key,
        "sourceKey": tile_source_key,
        "sourceRevision": tile_revision,
        "topologyRevision": tile_revision,
        "dynamicRevision": dynamic_revision,
        "semanticRevision": semantic_revision,
        "blocked": snapshot.get("blocked", {}),
        "doors": snapshot.get("doors", {}),
        "paths": snapshot.get("paths", {}),
        "staticCollision": snapshot.get("staticCollision", []),
        "staticCollisionByCell": snapshot.get("staticCollisionByCell", {}),
        "staticCollisionBroad": snapshot.get("staticCollisionBroad", []),
        "doorCollision": snapshot.get("doorCollision", []),
        "doorCollisionByCell": snapshot.get("doorCollisionByCell", {}),
        "buildingSupports": snapshot.get("buildingSupports", []),
        "buildingVerticalLinks": snapshot.get("buildingVerticalLinks", []),
        "buildingSupportSeamLinks": snapshot.get("buildingSupportSeamLinks", []),
        "buildingInteriorPassageLinks": snapshot.get("buildingInteriorPassageLinks", []),
        "surfaces": surfaces,
        "semanticRegions": semantic_regions,
        "doorPortals": door_summary.get("doorPortals", []),
        "doorLinks": door_summary.get("doorLinks", []),
        "navigationLinks": navigation_links
    }
    result["authoritativeSourceReady"] = not surfaces.is_empty()
    result["authoritativeSurfaceCount"] = surfaces.size()
    _store_navmesh_tile_snapshot_cache("%s|%s" % [tile_key, tile_source_key], result)
    job["snapshot"] = result
    job["status"] = "ready"


func building_navigation_link_resolution_diagnostics(tile_key: String, link_ids: Array = []) -> Array[Dictionary]:
    var snapshot: Dictionary = _navmesh_snapshot_with_live_tile_blocks(cached_static_tile_snapshot(true, true), tile_key)
    var requested_ids := {}
    for link_id in link_ids:
        if not link_id.is_empty():
            requested_ids[link_id] = true
    var result: Array[Dictionary] = []
    for link_value in building_vertical_links_for_tile(tile_key):
        if not (link_value is Dictionary):
            continue
        var link: Dictionary = link_value
        var link_id := String(link.get("id", ""))
        if not requested_ids.is_empty() and not requested_ids.has(link_id):
            continue
        var start_support_id := String(link.get("startSupportId", ""))
        var end_support_id := String(link.get("endSupportId", ""))
        var authored_start: Vector3 = link.get("start", Vector3.INF) as Vector3
        var authored_end: Vector3 = link.get("end", Vector3.INF) as Vector3
        var owner_resolution := _building_navigation_link_owner_resolution(link, start_support_id, end_support_id)
        if not bool(owner_resolution.get("resolved", false)):
            result.append({"id": link_id, "ownerTileKey": tile_key, "accepted": false, "reason": String(owner_resolution.get("reason", "egress_support_owner_mismatch")), "ownerResolution": owner_resolution})
            continue
        var start_tile_key := _building_navigation_link_endpoint_tile_key(link, "start", authored_start)
        var end_tile_key := _building_navigation_link_endpoint_tile_key(link, "end", authored_end)
        var transition_axis := authored_end - authored_start
        var start_resolution := _resolve_building_navigation_link_endpoint(snapshot, start_support_id, authored_start, start_tile_key, transition_axis)
        var end_resolution := _resolve_building_navigation_link_endpoint(snapshot, end_support_id, authored_end, end_tile_key, transition_axis)
        var start_position: Vector3 = start_resolution.get("position", Vector3.INF) as Vector3
        var end_position: Vector3 = end_resolution.get("position", Vector3.INF) as Vector3
        var maximum_drift := BUILDING_STAIR_LINK_MAX_ENDPOINT_DRIFT
        var start_drift := start_position.distance_to(authored_start) if start_position.is_finite() and authored_start.is_finite() else INF
        var end_drift := end_position.distance_to(authored_end) if end_position.is_finite() and authored_end.is_finite() else INF
        var reason := ""
        if not bool(start_resolution.get("resolved", false)):
            reason = "start_%s" % String(start_resolution.get("reason", "unresolved"))
        elif not bool(end_resolution.get("resolved", false)):
            reason = "end_%s" % String(end_resolution.get("reason", "unresolved"))
        result.append({
            "id": link_id,
            "ownerTileKey": tile_key,
            "accepted": reason.is_empty(),
            "reason": reason,
            "maximumEndpointDrift": maximum_drift,
            "driftIsDiagnosticOnly": true,
            "startDrift": start_drift,
            "endDrift": end_drift,
            "startResolution": start_resolution,
            "endResolution": end_resolution,
            "startSupportSamples": building_support_navigation_sample_diagnostics(start_support_id, start_tile_key, [{"id": "authored_start", "position": authored_start}]),
            "endSupportSamples": building_support_navigation_sample_diagnostics(end_support_id, end_tile_key, [{"id": "authored_end", "position": authored_end}])
        })
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
    navmesh_tile_snapshot_build_jobs.clear()

func _clear_navmesh_tile_snapshot_cache_for_tile(tile_key: String) -> void:
    if tile_key == "":
        return
    navmesh_tile_snapshot_build_jobs.erase(tile_key)
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
    var static_broad: Array[Dictionary] = []
    var door_broad: Array[Dictionary] = []
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
    snapshot["staticCollisionByCell"] = _collision_index_for_records(static_records, static_broad, -1)
    snapshot["staticCollisionBroad"] = static_broad
    snapshot["doorCollision"] = door_records
    snapshot["doorCollisionByCell"] = _collision_index_for_records(door_records, door_broad, -1)
    snapshot["doorCollisionBroad"] = door_broad
    return snapshot


func _navmesh_snapshot_with_live_tile_blocks(base_snapshot: Dictionary, tile_key: String) -> Dictionary:
    if main == null:
        return base_snapshot
    var blocks: Dictionary = main.get("blocks")
    if blocks.is_empty():
        return base_snapshot
    var snapshot := base_snapshot.duplicate(false)
    var blocked := _tile_cells_dictionary(base_snapshot.get("blocked", {}), tile_key)
    var doors := _tile_cells_dictionary(base_snapshot.get("doors", {}), tile_key)
    var paths := _tile_cells_dictionary(base_snapshot.get("paths", {}), tile_key)
    var static_records := _collision_records_for_navmesh_tile(base_snapshot.get("staticCollision", []), tile_key)
    var door_records := _collision_records_for_navmesh_tile(base_snapshot.get("doorCollision", []), tile_key)
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
    snapshot["staticCollisionByCell"] = _collision_index_for_records(static_records, [], -1)
    snapshot["staticCollisionBroad"] = []
    snapshot["doorCollision"] = door_records
    snapshot["doorCollisionByCell"] = _collision_index_for_records(door_records, [], -1)
    snapshot["doorCollisionBroad"] = []
    return snapshot


func _collision_records_for_navmesh_tile(records_value, tile_key: String) -> Array:
    var result := []
    if not (records_value is Array):
        return result
    for record_value in records_value:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        if bool(record.get("sourceManifest", false)):
            if _collision_record_overlaps_tile(record, tile_key):
                result.append(record)
            continue
        var cell: Vector2i = record.get("cell", INVALID_CELL)
        if cell != INVALID_CELL and tile_key_for_cell(cell) == tile_key:
            continue
        if _collision_record_overlaps_tile(record, tile_key):
            result.append(record)
    return result

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
        if bool(record.get("sourceManifest", false)):
            if _collision_record_overlaps_tile(record, tile_key):
                result.append(record)
            continue
        var cell: Vector2i = record.get("cell", INVALID_CELL)
        if cell != INVALID_CELL and tile_key_for_cell(cell) == tile_key:
            continue
        result.append(record)
    return result


func _collision_record_overlaps_tile(record: Dictionary, tile_key: String) -> bool:
    var tile := _parse_tile_key(tile_key)
    var tile_min_x := (float(tile.x * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_max_x := (float((tile.x + 1) * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_min_z := (float(tile.y * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_max_z := (float((tile.y + 1) * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    return float(record.get("maxX", -INF)) + inflation >= tile_min_x \
        and float(record.get("minX", INF)) - inflation <= tile_max_x \
        and float(record.get("maxZ", -INF)) + inflation >= tile_min_z \
        and float(record.get("minZ", INF)) - inflation <= tile_max_z

func _append_collision_records(records: Array, body: Node, cell: Vector2i, block_type: String, is_door: bool) -> void:
    var body_records := _collision_records_for_body(body, cell, block_type, is_door)
    if body_records.is_empty() and body is Node3D:
        body_records.append(_fallback_collision_record(body as Node3D, cell, block_type, is_door))
    for record in body_records:
        records.append(record)

func _collision_index_for_records(records: Array, broad_records: Array = [], max_index_cells := TRANSITION_RECORD_INDEX_MAX_CELLS) -> Dictionary:
    var index := {}
    for record_value in records:
        if record_value is Dictionary:
            _index_collision_record(index, record_value, broad_records, max_index_cells)
    return index

func cached_static_tile_snapshot(allow_outside := false, moving_home := false) -> Dictionary:
    if cached_revision == "":
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
        "staticCollisionBroad": cached_static_collision_broad,
        "doorCollision": cached_door_collision_records,
        "doorCollisionByCell": cached_door_collision_by_cell,
        "buildingSupports": cached_building_supports,
        "buildingVerticalLinks": cached_building_vertical_links,
        "buildingSupportSeamLinks": cached_building_support_seam_links,
        "buildingInteriorPassageLinks": cached_building_interior_passage_links,
        "dynamic": {},
        "allowOutside": allow_outside,
        "movingHome": moving_home
    }

func cached_validation_snapshot(entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
    if cached_revision == "":
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
        "staticCollisionBroad": cached_static_collision_broad,
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
    var changed_tile_key := String(tile_key).strip_edges()
    if not changed_tile_key.is_empty():
        _mark_navmesh_tile_and_seam_neighbors_changed(changed_tile_key)
        return
    navmesh_tile_revision_by_key.clear()
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
    cached_static_collision_broad = []
    cached_door_collision_records = []
    cached_door_collision_by_cell = {}
    cached_building_supports = []
    cached_building_supports_by_tile = {}
    cached_building_support_by_id = {}
    cached_building_vertical_links = []
    cached_building_support_seam_links = []
    cached_building_interior_passage_links = []
    cached_building_doors = []
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
    _rebuild_building_navigation_facts()
    return scanned

func _rebuild_building_navigation_facts() -> void:
    if system == null or not system.has_method("building_navigation_manifest_snapshot"):
        return
    var manifests = system.call("building_navigation_manifest_snapshot")
    if not (manifests is Array):
        return
    for manifest_value in manifests:
        if not (manifest_value is Dictionary):
            continue
        var manifest: Dictionary = manifest_value
        for support_value in manifest.get("supports", []):
            if support_value is Dictionary:
                cached_building_supports.append((support_value as Dictionary).duplicate(true))
        for link_value in manifest.get("verticalLinks", []):
            if link_value is Dictionary:
                cached_building_vertical_links.append((link_value as Dictionary).duplicate(true))
        for link_value in manifest.get("supportSeamLinks", []):
            if link_value is Dictionary:
                cached_building_support_seam_links.append((link_value as Dictionary).duplicate(true))
        for link_value in manifest.get("interiorPassageLinks", []):
            if link_value is Dictionary:
                cached_building_interior_passage_links.append((link_value as Dictionary).duplicate(true))
        for door_value in manifest.get("doors", []):
            if door_value is Dictionary:
                cached_building_doors.append((door_value as Dictionary).duplicate(true))
        _append_manifest_static_collision_records(manifest)

    if system != null and system.has_method("navigation_collision_manifest_snapshot"):
        var collision_manifests = system.call("navigation_collision_manifest_snapshot")
        if collision_manifests is Array:
            for manifest_value in collision_manifests:
                if manifest_value is Dictionary:
                    _append_manifest_static_collision_records(manifest_value as Dictionary)
    cached_building_supports.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
    _index_building_supports_by_tile()
    cached_building_vertical_links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
    cached_building_support_seam_links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
    cached_building_interior_passage_links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
    cached_building_doors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))


func _index_building_supports_by_tile() -> void:
    cached_building_supports_by_tile = {}
    cached_building_support_by_id = {}
    cached_building_support_ids_valid = true
    for support in cached_building_supports:
        var support_id := String(support.get("id", ""))
        if not support_id.is_empty():
            if cached_building_support_by_id.has(support_id):
                cached_building_support_ids_valid = false
                push_error("Duplicate generated building navigation support id: %s" % support_id)
                continue
            cached_building_support_by_id[support_id] = support
        var tile_keys: Array = support.get("tileKeys", []) if support.get("tileKeys", []) is Array else []
        for tile_key_value in tile_keys:
            var tile_key := String(tile_key_value)
            if tile_key.is_empty():
                continue
            if not cached_building_supports_by_tile.has(tile_key):
                cached_building_supports_by_tile[tile_key] = []
            (cached_building_supports_by_tile[tile_key] as Array).append(support)


func _append_manifest_static_collision_records(manifest: Dictionary) -> void:
    for part_value in manifest.get("staticCollision", []):
        if not (part_value is Dictionary):
            continue
        var record := _manifest_static_collision_record(part_value as Dictionary, String(manifest.get("sourceKind", "building")))
        if record.is_empty():
            continue
        cached_static_collision_records.append(record)
        _index_collision_record(cached_static_collision_by_cell, record, cached_static_collision_broad)


func _manifest_static_collision_record(part: Dictionary, source_kind: String) -> Dictionary:
    var bounds: AABB = part.get("bounds", AABB()) if part.get("bounds", AABB()) is AABB else AABB()
    if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
        return {}
    var part_id := String(part.get("id", ""))
    if part_id == "":
        return {}
    var center := bounds.get_center()
    var result := {
        "id": part_id,
        "cell": world_cell(center),
        "blockType": source_kind,
        "isDoor": false,
        "minX": bounds.position.x,
        "maxX": bounds.end.x,
        "minY": bounds.position.y,
        "maxY": bounds.end.y,
        "minZ": bounds.position.z,
        "maxZ": bounds.end.z,
        "sourcePartId": String(part.get("sourceCollisionPartId", part.get("sourcePartId", ""))),
        "sourcePartKind": String(part.get("kind", "")),
        "sourceManifest": true,
        "inflation": TRANSITION_COLLISION_INFLATION
    }
    var footprint: Array = part.get("footprint", []) if part.get("footprint", []) is Array else []
    if footprint.size() >= 3:
        result["footprint"] = footprint.duplicate(true)
    return result

func building_supports_for_tile(tile_key: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for support_value in cached_building_supports_by_tile.get(tile_key, []) as Array:
        if support_value is Dictionary:
            result.append(support_value as Dictionary)
    return result

func building_vertical_links_for_tile(tile_key: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for link in cached_building_vertical_links:
        if _building_navigation_link_owner_tile_key(link) == tile_key:
            result.append(link)
    return result


func building_support_seam_links_for_tile(tile_key: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for link in cached_building_support_seam_links:
        if _building_navigation_link_owner_tile_key(link) == tile_key:
            result.append(link)
    return result


func building_interior_passage_links_for_tile(tile_key: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for link in cached_building_interior_passage_links:
        if _building_navigation_link_owner_tile_key(link) == tile_key:
            result.append(link)
    return result


func building_doors_for_tile(tile_key: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for door in cached_building_doors:
        if String(door.get("ownerTileKey", "")) == tile_key:
            result.append(door)
    return result

func _navmesh_surfaces_from_building_tile(snapshot: Dictionary, tile_key: String, span_index: int, sample_data_by_support := {}) -> Array[Dictionary]:
    var flat_layers := {}
    var ramps: Array[Dictionary] = []
    for support in building_supports_for_tile(tile_key):
        var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
        if polygon.size() < 3:
            continue
        var normal: Vector3 = support.get("floorNormal", Vector3.UP) if support.get("floorNormal", Vector3.UP) is Vector3 else Vector3.UP
        if normal.normalized().y < 0.985:
            ramps.append(support)
            continue
        var support_id := String(support.get("id", ""))
        var sample_data: Dictionary = sample_data_by_support.get(support_id, {}) as Dictionary
        if sample_data.is_empty():
            sample_data = _building_support_navigation_sample_data(support, snapshot, tile_key)
        var navigable_cells: Dictionary = sample_data.get("navigableCells", {}) if sample_data.get("navigableCells", {}) is Dictionary else {}
        for cell_value in navigable_cells.keys():
            if not (cell_value is Vector2i):
                continue
            var cell: Vector2i = cell_value
            var position: Vector3 = navigable_cells.get(cell, Vector3.INF) if navigable_cells.get(cell, Vector3.INF) is Vector3 else Vector3.INF
            if not position.is_finite():
                continue
            var layer_key := str(roundi(position.y * 100.0))
            if not flat_layers.has(layer_key):
                flat_layers[layer_key] = {
                    "cells": {},
                    "height": position.y - 0.04,
                    "sourcePartIds": {},
                    "sourceCollisionPartIds": {},
                    "lateralClearance": float(support.get("lateralClearance", 1.0)),
                    "traversalTags": support.get("traversalTags", ["building", "support"])
                }
            var layer: Dictionary = flat_layers.get(layer_key, {}) as Dictionary
            var layer_cells: Dictionary = layer.get("cells", {}) as Dictionary
            if not layer_cells.has(cell):
                layer_cells[cell] = position
            var source_part_ids: Dictionary = layer.get("sourcePartIds", {}) as Dictionary
            source_part_ids[String(support.get("sourcePartId", ""))] = true
            var source_collision_part_ids: Dictionary = layer.get("sourceCollisionPartIds", {}) as Dictionary
            source_collision_part_ids[String(support.get("sourceCollisionPartId", ""))] = true
            layer["lateralClearance"] = minf(float(layer.get("lateralClearance", 1.0)), float(support.get("lateralClearance", 1.0)))
            flat_layers[layer_key] = layer
    var result: Array[Dictionary] = []
    var next_span := span_index
    var layer_keys: Array = flat_layers.keys()
    layer_keys.sort_custom(func(left, right) -> bool: return int(left) < int(right))
    for layer_key_value in layer_keys:
        var layer_key := String(layer_key_value)
        var layer: Dictionary = flat_layers.get(layer_key, {}) as Dictionary
        var cells: Dictionary = layer.get("cells", {}) as Dictionary
        if cells.is_empty():
            continue
        var source_part_ids: Array = (layer.get("sourcePartIds", {}) as Dictionary).keys()
        source_part_ids.sort()
        var source_collision_part_ids: Array = (layer.get("sourceCollisionPartIds", {}) as Dictionary).keys()
        source_collision_part_ids.sort()
        var height := float(layer.get("height", 0.0))
        var unified_support := {
            "id": "building:tile:%s:flat:%s" % [tile_key, layer_key],
            "cell": Vector3i.ZERO,
            "worldPosition": Vector3(0.0, height, 0.0),
            "floorNormal": Vector3.UP,
            "headroom": 3.0,
            "lateralClearance": float(layer.get("lateralClearance", 1.0)),
            "traversalTags": layer.get("traversalTags", ["building", "support"]),
            "sourcePartId": String(source_part_ids[0]) if not source_part_ids.is_empty() else "",
            "sourceCollisionPartId": String(source_collision_part_ids[0]) if not source_collision_part_ids.is_empty() else ""
        }
        var layer_surfaces := _merged_building_support_navmesh_surfaces(unified_support, cells, next_span)
        result.append_array(layer_surfaces)
        next_span += layer_surfaces.size()
    for ramp_value in ramps:
        var ramp: Dictionary = ramp_value
        var ramp_polygon: Array = ramp.get("polygon", []) if ramp.get("polygon", []) is Array else []
        var ramp_surface := _navmesh_surface_from_building_support(ramp, next_span, ramp_polygon)
        if ramp_surface.is_empty():
            continue
        result.append(ramp_surface)
        next_span += 1
    return result


func _building_support_navigation_sample_data_by_id(snapshot: Dictionary, tile_key: String) -> Dictionary:
    var result := {}
    for support in building_supports_for_tile(tile_key):
        var support_id := String(support.get("id", ""))
        if support_id.is_empty():
            continue
        result[support_id] = _building_support_navigation_sample_data(support, snapshot, tile_key)
    return result


func _derived_surface_transition_links(snapshot: Dictionary, tile_key: String, sample_data_by_support: Dictionary, terrain_surfaces: Array, prepared_transition_samples: Array = []) -> Array[Dictionary]:
    var entries_by_cell := {}
    var validation_snapshot_by_tile_pair := {}
    var live_snapshot_by_tile := {}
    live_snapshot_by_tile[tile_key] = snapshot
    var transition_samples := prepared_transition_samples if not prepared_transition_samples.is_empty() else _surface_transition_support_samples(snapshot, tile_key, sample_data_by_support)
    for sample_value in transition_samples:
        if not (sample_value is Dictionary):
            continue
        var sample: Dictionary = sample_value
        var support_id := String(sample.get("supportId", ""))
        var sample_tile_key := String(sample.get("tileKey", ""))
        var sample_data: Dictionary = sample.get("sampleData", {}) as Dictionary
        var navigable_cells: Dictionary = sample_data.get("navigableCells", {}) as Dictionary
        for cell_value in navigable_cells.keys():
            if not (cell_value is Vector2i):
                continue
            var position: Vector3 = navigable_cells.get(cell_value, Vector3.INF) as Vector3
            if not position.is_finite():
                continue
            if not entries_by_cell.has(cell_value):
                entries_by_cell[cell_value] = []
            (entries_by_cell[cell_value] as Array).append({
                "supportId": support_id,
                "tileKey": sample_tile_key,
                "position": position
            })
    var terrain_by_cell := {}
    for surface_value in terrain_surfaces:
        if not (surface_value is Dictionary):
            continue
        var surface: Dictionary = surface_value
        var surface_cell: Vector3i = surface.get("cell", Vector3i.ZERO) as Vector3i
        terrain_by_cell[Vector2i(surface_cell.x, surface_cell.z)] = surface
    var candidate_groups := {}
    var cells: Array = entries_by_cell.keys()
    cells.sort_custom(func(left: Vector2i, right: Vector2i) -> bool:
        return left.x < right.x if left.y == right.y else left.y < right.y
    )
    for cell_value in cells:
        var cell: Vector2i = cell_value as Vector2i
        for base_neighbor_offset in [Vector2i.RIGHT, Vector2i.DOWN]:
            var neighbor_offset: Vector2i = base_neighbor_offset as Vector2i
            var neighbor_cell := cell + neighbor_offset
            if not entries_by_cell.has(neighbor_cell):
                neighbor_offset *= 2
                neighbor_cell = cell + neighbor_offset
            if not entries_by_cell.has(neighbor_cell):
                continue
            for first_value in entries_by_cell.get(cell, []) as Array:
                if not (first_value is Dictionary):
                    continue
                var first: Dictionary = first_value
                var first_support_id := String(first.get("supportId", ""))
                var first_tile_key := String(first.get("tileKey", tile_key))
                var first_position: Vector3 = first.get("position", Vector3.INF) as Vector3
                var first_support := _building_support_by_id(first_support_id)
                for second_value in entries_by_cell.get(neighbor_cell, []) as Array:
                    if not (second_value is Dictionary):
                        continue
                    var second: Dictionary = second_value
                    var second_support_id := String(second.get("supportId", ""))
                    var second_tile_key := String(second.get("tileKey", tile_key))
                    var second_position: Vector3 = second.get("position", Vector3.INF) as Vector3
                    if first_support_id.is_empty() or second_support_id.is_empty() or first_support_id == second_support_id:
                        continue
                    var height_delta := absf(first_position.y - second_position.y)
                    if height_delta > NpcConstantsScript.DEFAULT_NPC_STEP_UP:
                        _record_surface_transition_candidate_rejection(first_support_id, second_support_id, first_tile_key, second_tile_key, "support_seam_step_exceeds_policy", {"heightDelta": height_delta})
                        continue
                    var second_support := _building_support_by_id(second_support_id)
                    var validation_tile_keys: Array[String] = [first_tile_key, second_tile_key]
                    validation_tile_keys.sort()
                    var validation_key := "|".join(validation_tile_keys)
                    if not validation_snapshot_by_tile_pair.has(validation_key):
                        validation_snapshot_by_tile_pair[validation_key] = _surface_transition_validation_snapshot(snapshot, validation_tile_keys)
                    var validation_snapshot: Dictionary = validation_snapshot_by_tile_pair.get(validation_key, {}) as Dictionary
                    var second_support_part_id := String(second_support.get("sourceCollisionPartId", second_support.get("sourcePartId", "")))
                    var blocker := _building_navigation_link_blocker(validation_snapshot, first_support, first_position, second_position, NpcConstantsScript.DEFAULT_NPC_RADIUS, [second_support_part_id])
                    if not blocker.is_empty():
                        _record_surface_transition_candidate_rejection(first_support_id, second_support_id, first_tile_key, second_tile_key, "support_seam_blocked", {"collision": blocker})
                        continue
                    var door_blocker := _building_navigation_transition_door_blocker(validation_snapshot, first_position, second_position)
                    if not door_blocker.is_empty():
                        _record_surface_transition_candidate_rejection(first_support_id, second_support_id, first_tile_key, second_tile_key, "support_seam_door_blocked", {"collision": door_blocker})
                        continue
                    var seam_certificate := _building_support_transition_seam_certificate(first_support, second_support, first_position, second_position)
                    if not bool(seam_certificate.get("ok", false)):
                        _record_surface_transition_candidate_rejection(first_support_id, second_support_id, first_tile_key, second_tile_key, String(seam_certificate.get("reason", "support_seam_uncertified")), seam_certificate)
                        continue
                    var axis := "x" if neighbor_offset.x != 0 else "z"
                    var seam_index := cell.x if axis == "x" else cell.y
                    var lane_index := cell.y if axis == "x" else cell.x
                    var ordered_ids: Array[String] = [first_support_id, second_support_id]
                    ordered_ids.sort()
                    var group_key := "support|%s|%s|%s|%d" % [ordered_ids[0], ordered_ids[1], axis, seam_index]
                    var producer_tile_key := _canonical_navigation_tile_key(first_tile_key, second_tile_key)
                    _append_surface_transition_candidate(candidate_groups, group_key, {
                        "start": first_position,
                        "end": second_position,
                        "startSupportId": first_support_id,
                        "endSupportId": second_support_id,
                        "startTileKey": first_tile_key,
                        "endTileKey": second_tile_key,
                        "axis": axis,
                        "laneIndex": lane_index,
                        "heightDelta": height_delta,
						"producerTileKey": producer_tile_key,
                        "seamCertificate": seam_certificate,
                        "minimumLaneCount": maxi(int(first_support.get("minimumNavigationLaneCount", 0)), int(second_support.get("minimumNavigationLaneCount", 0))),
                        "sourceOwners": [first_support_id, second_support_id]
                    })
    for cell_value in cells:
        var cell: Vector2i = cell_value as Vector2i
        for entry_value in entries_by_cell.get(cell, []) as Array:
            if not (entry_value is Dictionary):
                continue
            var entry: Dictionary = entry_value
            if String(entry.get("tileKey", tile_key)) != tile_key:
                continue
            var support_id := String(entry.get("supportId", ""))
            var support_position: Vector3 = entry.get("position", Vector3.INF) as Vector3
            var support := _building_support_by_id(support_id)
            for neighbor_offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
                var neighbor_cell := cell + (neighbor_offset as Vector2i)
                if entries_by_cell.has(neighbor_cell):
                    continue
                var terrain_probe := Vector3(
                    (float(neighbor_cell.x) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP,
                    0.0,
                    (float(neighbor_cell.y) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP
                )
                var terrain_cell := world_cell(terrain_probe)
                if not terrain_by_cell.has(terrain_cell):
                    var neighbor_tile_key := tile_key_for_cell(terrain_cell)
                    if not live_snapshot_by_tile.has(neighbor_tile_key):
                        live_snapshot_by_tile[neighbor_tile_key] = _navmesh_snapshot_with_live_tile_blocks(snapshot, neighbor_tile_key)
                    var neighbor_snapshot: Dictionary = live_snapshot_by_tile.get(neighbor_tile_key, {}) as Dictionary
                    var neighbor_surface := _navmesh_surface_for_cell(neighbor_snapshot, terrain_cell)
                    if not neighbor_surface.is_empty():
                        terrain_by_cell[terrain_cell] = neighbor_surface
                if not terrain_by_cell.has(terrain_cell):
                    continue
                var terrain_surface: Dictionary = terrain_by_cell.get(terrain_cell, {}) as Dictionary
                terrain_probe.y = (terrain_surface.get("worldPosition", Vector3.INF) as Vector3).y
                var height_delta := absf(support_position.y - terrain_probe.y)
                if not terrain_probe.is_finite() or height_delta > NpcConstantsScript.DEFAULT_NPC_STEP_UP:
                    continue
                var blocker := _building_navigation_link_blocker(snapshot, support, support_position, terrain_probe, NpcConstantsScript.DEFAULT_NPC_RADIUS)
                if not blocker.is_empty() or not _building_navigation_transition_door_blocker(snapshot, support_position, terrain_probe).is_empty():
                    continue
                var axis := "x" if neighbor_offset.x != 0 else "z"
                var seam_index := mini(cell.x, neighbor_cell.x) if axis == "x" else mini(cell.y, neighbor_cell.y)
                var lane_index := cell.y if axis == "x" else cell.x
                var direction: int = neighbor_offset.x + neighbor_offset.y
                var group_key := "terrain|%s|%s|%d|%d" % [support_id, axis, seam_index, direction]
                var terrain_tile_key := tile_key_for_cell(terrain_cell)
                _append_surface_transition_candidate(candidate_groups, group_key, {
                    "start": support_position,
                    "end": terrain_probe,
                    "startSupportId": support_id,
                    "endSupportId": "terrain:%d,%d" % [terrain_cell.x, terrain_cell.y],
                    "startTileKey": tile_key,
                    "endTileKey": terrain_tile_key,
                    "axis": axis,
                    "laneIndex": lane_index,
                    "heightDelta": height_delta,
					"producerTileKey": tile_key,
                    "sourceOwners": [support_id, "terrain:%d,%d" % [terrain_cell.x, terrain_cell.y]]
                })
    return _surface_transition_links_from_candidate_groups(candidate_groups, tile_key, snapshot)


func _surface_transition_support_samples(snapshot: Dictionary, tile_key: String, local_sample_data: Dictionary) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var seen := {}
    for support_id_value in local_sample_data.keys():
        var support_id := String(support_id_value)
        var key := "%s|%s" % [tile_key, support_id]
        seen[key] = true
        result.append({
            "supportId": support_id,
            "tileKey": tile_key,
            "sampleData": local_sample_data.get(support_id_value, {})
        })
    var tile := _parse_tile_key(tile_key)
    for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
        var neighbor: Vector2i = tile + offset
        var neighbor_tile_key := "%d,%d" % [neighbor.x, neighbor.y]
        var neighbor_snapshot := _navmesh_snapshot_with_live_tile_blocks(snapshot, neighbor_tile_key)
        for support_value in cached_building_supports_by_tile.get(neighbor_tile_key, []) as Array:
            if not (support_value is Dictionary):
                continue
            var support: Dictionary = support_value
            var support_id := String(support.get("id", ""))
            var key := "%s|%s" % [neighbor_tile_key, support_id]
            if support_id.is_empty() or seen.has(key):
                continue
            seen[key] = true
            result.append({
                "supportId": support_id,
                "tileKey": neighbor_tile_key,
                "sampleData": _building_support_navigation_sample_data(support, neighbor_snapshot, neighbor_tile_key)
            })
    result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
        var left_key := "%s|%s" % [String(left.get("tileKey", "")), String(left.get("supportId", ""))]
        var right_key := "%s|%s" % [String(right.get("tileKey", "")), String(right.get("supportId", ""))]
        return left_key < right_key
    )
    return result


func _canonical_navigation_tile_key(first: String, second: String) -> String:
    var first_tile := _parse_tile_key(first)
    var second_tile := _parse_tile_key(second)
    if first_tile.x != second_tile.x:
        return first if first_tile.x < second_tile.x else second
    if first_tile.y != second_tile.y:
        return first if first_tile.y < second_tile.y else second
    return first if first <= second else second


func _surface_transition_validation_snapshot(base_snapshot: Dictionary, tile_keys_value: Array) -> Dictionary:
    var tile_keys: Array[String] = []
    for tile_key_value in tile_keys_value:
        var tile_key := String(tile_key_value)
        if not tile_key.is_empty() and not tile_keys.has(tile_key):
            tile_keys.append(tile_key)
    tile_keys.sort_custom(func(left: String, right: String) -> bool:
        return _canonical_navigation_tile_key(left, right) == left
    )
    if tile_keys.is_empty():
        return base_snapshot
    var source_snapshot := cached_static_tile_snapshot(true, true)
    var result := source_snapshot.duplicate(false)
    var blocked := {}
    var doors := {}
    var paths := {}
    var static_records: Array = []
    var door_records: Array = []
    var seen_static := {}
    var seen_doors := {}
    var participating_tiles: Array[Dictionary] = []
    for tile_key in tile_keys:
        var tile_snapshot := _navmesh_snapshot_with_live_tile_blocks(source_snapshot, tile_key)
        for key in ["blocked", "doors", "paths"]:
            var target: Dictionary = blocked if key == "blocked" else (doors if key == "doors" else paths)
            var values: Dictionary = tile_snapshot.get(key, {}) if tile_snapshot.get(key, {}) is Dictionary else {}
            for cell_value in values.keys():
                target[cell_value] = values[cell_value]
        _append_unique_transition_collision_records(static_records, seen_static, tile_snapshot.get("staticCollision", []))
        _append_unique_transition_collision_records(door_records, seen_doors, tile_snapshot.get("doorCollision", []))
        participating_tiles.append({
            "tileKey": tile_key,
            "sourceKey": navmesh_tile_source_key_for_tile(tile_key),
            "sourceRevision": int(navmesh_tile_revision_by_key.get(tile_key, static_snapshot_revision))
        })
    result["blocked"] = blocked
    result["doors"] = doors
    result["paths"] = paths
    result["staticCollision"] = static_records
    result["staticCollisionByCell"] = _collision_index_for_records(static_records, [], -1)
    result["staticCollisionBroad"] = []
    result["doorCollision"] = door_records
    result["doorCollisionByCell"] = _collision_index_for_records(door_records, [], -1)
    result["doorCollisionBroad"] = []
    result["participatingTiles"] = participating_tiles
    return result


func _append_unique_transition_collision_records(target: Array, seen: Dictionary, records_value) -> void:
    if not (records_value is Array):
        return
    for record_value in records_value:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var key := "%s|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f" % [
            String(record.get("id", record.get("sourcePartId", ""))),
            float(record.get("minX", 0.0)),
            float(record.get("maxX", 0.0)),
            float(record.get("minY", 0.0)),
            float(record.get("maxY", 0.0)),
            float(record.get("minZ", 0.0)),
            float(record.get("maxZ", 0.0))
        ]
        if seen.has(key):
            continue
        seen[key] = true
        target.append(record)


func _building_support_transition_seam_certificate(first_support: Dictionary, second_support: Dictionary, first_position: Vector3, second_position: Vector3) -> Dictionary:
    var crossing := second_position - first_position
    crossing.y = 0.0
    if crossing.length_squared() <= 0.000001:
        return {"ok": false, "reason": "degenerate_support_seam"}
    var direction := Vector2(crossing.x, crossing.z).normalized()
    var lateral := Vector2(-direction.y, direction.x)
    var first_polygon: Array = first_support.get("polygon", []) if first_support.get("polygon", []) is Array else []
    var second_polygon: Array = second_support.get("polygon", []) if second_support.get("polygon", []) is Array else []
    if first_polygon.size() < 3 or second_polygon.size() < 3:
        return {"ok": false, "reason": "missing_support_polygon"}
    var first_interval := _support_projection_interval(first_polygon, direction)
    var second_interval := _support_projection_interval(second_polygon, direction)
    var first_lateral := _support_projection_interval(first_polygon, lateral)
    var second_lateral := _support_projection_interval(second_polygon, lateral)
    var forward := Vector2(second_position.x - first_position.x, second_position.z - first_position.z).dot(direction) >= 0.0
    var first_edge := float(first_interval.get("maximum" if forward else "minimum", 0.0))
    var second_edge := float(second_interval.get("minimum" if forward else "maximum", 0.0))
    var gap := second_edge - first_edge if forward else first_edge - second_edge
    if gap > BUILDING_SUPPORT_TRANSITION_MAX_GAP + 0.0001:
        return {"ok": false, "reason": "support_seam_gap_exceeds_policy", "gap": gap}
    if gap < -BUILDING_SUPPORT_TRANSITION_MAX_OVERLAP - 0.0001:
        return {"ok": false, "reason": "support_seam_overlap_exceeds_policy", "gap": gap}
    var lateral_min := maxf(float(first_lateral.get("minimum", 0.0)), float(second_lateral.get("minimum", 0.0)))
    var lateral_max := minf(float(first_lateral.get("maximum", 0.0)), float(second_lateral.get("maximum", 0.0)))
    var lane_center := Vector2((first_position.x + second_position.x) * 0.5, (first_position.z + second_position.z) * 0.5).dot(lateral)
    var floor_check_half_width := minf(NpcConstantsScript.DEFAULT_NPC_RADIUS, BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.45)
    if lane_center - floor_check_half_width < lateral_min - 0.0001 or lane_center + floor_check_half_width > lateral_max + 0.0001:
        return {"ok": false, "reason": "support_seam_lane_lacks_width", "lateralMinimum": lateral_min, "lateralMaximum": lateral_max}
    var edge_epsilon := 0.005
    for lateral_offset in [-floor_check_half_width, 0.0, floor_check_half_width]:
        var lane_projection: float = lane_center + float(lateral_offset)
        var first_projection := first_edge - edge_epsilon if forward else first_edge + edge_epsilon
        var second_projection := second_edge + edge_epsilon if forward else second_edge - edge_epsilon
        var first_point_2d: Vector2 = direction * first_projection + lateral * lane_projection
        var second_point_2d: Vector2 = direction * second_projection + lateral * lane_projection
        var first_point := Vector3(first_point_2d.x, first_position.y, first_point_2d.y)
        var second_point := Vector3(second_point_2d.x, second_position.y, second_point_2d.y)
        if not _point_within_or_near_support_xz(first_point, first_support, edge_epsilon * 2.0) or not _point_within_or_near_support_xz(second_point, second_support, edge_epsilon * 2.0):
            return {"ok": false, "reason": "support_seam_lane_floor_missing", "lateralOffset": lateral_offset, "firstPoint": first_point, "secondPoint": second_point}
    return {"ok": true, "reason": "", "gap": gap, "seamProjection": (first_edge + second_edge) * 0.5, "laneCenter": lane_center, "floorCheckHalfWidth": floor_check_half_width, "floorCheckCount": 3}


func _support_projection_interval(polygon: Array, axis: Vector2) -> Dictionary:
    var minimum := INF
    var maximum := -INF
    for point_value in polygon:
        if not (point_value is Vector3):
            continue
        var point: Vector3 = point_value
        var projection := Vector2(point.x, point.z).dot(axis)
        minimum = minf(minimum, projection)
        maximum = maxf(maximum, projection)
    return {"minimum": minimum, "maximum": maximum}


func _append_surface_transition_candidate(groups: Dictionary, group_key: String, candidate: Dictionary) -> void:
    if not groups.has(group_key):
        groups[group_key] = []
    (groups[group_key] as Array).append(candidate)


func _record_surface_transition_candidate_rejection(first_support_id: String, second_support_id: String, first_tile_key: String, second_tile_key: String, reason: String, details := {}) -> void:
    if first_tile_key == second_tile_key:
        return
    surface_transition_publication_failures.append({
        "reason": reason,
        "startSupportId": first_support_id,
        "endSupportId": second_support_id,
        "startTileKey": first_tile_key,
        "endTileKey": second_tile_key,
        "certificate": details
    })
    if surface_transition_publication_failures.size() > 256:
        surface_transition_publication_failures.pop_front()


func _surface_transition_links_from_candidate_groups(candidate_groups: Dictionary, owner_tile_key: String, snapshot := {}) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var group_keys: Array = candidate_groups.keys()
    group_keys.sort()
    for group_key_value in group_keys:
        var group_key := String(group_key_value)
        var candidates: Array = []
        for candidate_value in candidate_groups.get(group_key_value, []) as Array:
            if candidate_value is Dictionary and String((candidate_value as Dictionary).get("producerTileKey", owner_tile_key)) == owner_tile_key:
                candidates.append(candidate_value)
        if candidates.is_empty():
            continue
        candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
            return int(left.get("laneIndex", 0)) < int(right.get("laneIndex", 0))
        )
        var run_start := 0
        while run_start < candidates.size():
            var run_end := run_start + 1
            while run_end < candidates.size() and int((candidates[run_end] as Dictionary).get("laneIndex", 0)) == int((candidates[run_end - 1] as Dictionary).get("laneIndex", 0)) + 1:
                run_end += 1
            var lane_width := float(run_end - run_start) * BUILDING_SUPPORT_NAV_SAMPLE_STEP
            var minimum_corridor_width := NpcConstantsScript.DEFAULT_NPC_RADIUS * 2.0 + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN * 2.0
            if lane_width + 0.001 < minimum_corridor_width:
                run_start = run_end
                continue
            var lane_pitch_samples := maxi(1, ceili(minimum_corridor_width / BUILDING_SUPPORT_NAV_SAMPLE_STEP))
            var lane_count := maxi(1, floori(float(run_end - run_start) / float(lane_pitch_samples)))
            var seam_corridor_id := "building:surface_transition_corridor:%s:%s:%d" % [owner_tile_key, group_key.sha256_text().left(16), run_start]
            var minimum_lane_count := 0
            var continuous_source_proof := true
            var maximum_height_delta := 0.0
            var maximum_contact_gap := 0.0
            var minimum_contact_gap := INF
            for candidate_index in range(run_start, run_end):
                var run_candidate: Dictionary = candidates[candidate_index] as Dictionary
                var run_certificate: Dictionary = run_candidate.get("seamCertificate", {}) if run_candidate.get("seamCertificate", {}) is Dictionary else {}
                var contact_gap := float(run_certificate.get("gap", INF))
                var height_delta := float(run_candidate.get("heightDelta", INF))
                minimum_lane_count = maxi(minimum_lane_count, int(run_candidate.get("minimumLaneCount", 0)))
                maximum_height_delta = maxf(maximum_height_delta, height_delta)
                maximum_contact_gap = maxf(maximum_contact_gap, absf(contact_gap))
                minimum_contact_gap = minf(minimum_contact_gap, contact_gap)
                continuous_source_proof = continuous_source_proof \
                    and bool(run_certificate.get("ok", false)) \
                    and height_delta <= CONTINUOUS_SUPPORT_SEAM_MAX_HEIGHT_DELTA \
                    and contact_gap >= 0.0 \
                    and contact_gap <= CONTINUOUS_SUPPORT_SEAM_MAX_GAP
            if continuous_source_proof:
                var lane_positions: Array[Vector3] = []
                for lane_number in range(lane_count):
                    var lane_candidate_index := _surface_transition_lane_candidate_indices(run_start, run_end, lane_number, lane_count)[0]
                    var lane_candidate: Dictionary = candidates[lane_candidate_index] as Dictionary
                    var lane_start: Vector3 = lane_candidate.get("start", Vector3.INF) as Vector3
                    var lane_end: Vector3 = lane_candidate.get("end", Vector3.INF) as Vector3
                    if lane_start.is_finite() and lane_end.is_finite():
                        lane_positions.append((lane_start + lane_end) * 0.5)
                var continuity_certificate := {
                    "sourceBacked": true,
                    "ownerTileKey": owner_tile_key,
                    "seamCorridorId": seam_corridor_id,
                    "sourceOwners": (candidates[run_start] as Dictionary).get("sourceOwners", []),
                    "laneCount": lane_count,
                    "minimumLaneCount": minimum_lane_count,
                    "laneWidth": lane_width,
                    "lanePositions": lane_positions,
                    "maximumHeightDelta": maximum_height_delta,
                    "maximumContactGap": maximum_contact_gap,
                    "minimumContactGap": minimum_contact_gap,
                    "positiveOverlap": minimum_contact_gap < 0.0,
                    "passed": lane_count >= maxi(1, minimum_lane_count)
                }
                continuous_surface_transition_certificates.append(continuity_certificate)
                if continuous_surface_transition_certificates.size() > 256:
                    continuous_surface_transition_certificates.pop_front()
                if bool(continuity_certificate.get("passed", false)):
                    run_start = run_end
                    continue
                _record_surface_transition_candidate_rejection(
                    String((candidates[run_start] as Dictionary).get("startSupportId", "")),
                    String((candidates[run_start] as Dictionary).get("endSupportId", "")),
                    String((candidates[run_start] as Dictionary).get("startTileKey", owner_tile_key)),
                    String((candidates[run_start] as Dictionary).get("endTileKey", owner_tile_key)),
                    "continuous_seam_insufficient_capacity",
                    continuity_certificate
                )
                run_start = run_end
                continue
            for lane_number in range(lane_count):
                var link_id := "building:surface_transition:%s:%s:%d:%d" % [owner_tile_key, group_key.sha256_text().left(16), run_start, lane_number]
                var candidate: Dictionary = {}
                var endpoints: Dictionary = {}
                for selected_index in _surface_transition_lane_candidate_indices(run_start, run_end, lane_number, lane_count):
                    var candidate_value: Dictionary = candidates[selected_index] as Dictionary
                    var candidate_endpoints := _certified_surface_transition_endpoints(snapshot, candidate_value, link_id)
                    if candidate_endpoints.is_empty():
                        continue
                    candidate = candidate_value
                    endpoints = candidate_endpoints
                    break
                if endpoints.is_empty():
                    continue
                var start: Vector3 = endpoints.get("start", Vector3.INF) as Vector3
                var end: Vector3 = endpoints.get("end", Vector3.INF) as Vector3
                var start_tile_key := String(candidate.get("startTileKey", owner_tile_key))
                var end_tile_key := String(candidate.get("endTileKey", owner_tile_key))
                var corridor_width := minf(lane_width / float(lane_count), minimum_corridor_width)
                var participating_tiles := _merged_surface_transition_participating_tiles(
                    (endpoints.get("forwardTraversal", {}) as Dictionary).get("participatingTiles", []),
                    (endpoints.get("reverseTraversal", {}) as Dictionary).get("participatingTiles", [])
                )
                result.append({
                    "id": link_id,
                    "kind": "surface_transition",
                    "start": start,
                    "end": end,
                    "startSupportId": String(candidate.get("startSupportId", "")),
                    "endSupportId": String(candidate.get("endSupportId", "")),
                    "startTileKey": start_tile_key,
                    "endTileKey": end_tile_key,
                    "startTileSourceKey": navmesh_tile_source_key_for_tile(start_tile_key),
                    "endTileSourceKey": navmesh_tile_source_key_for_tile(end_tile_key),
                    "ownerTileKey": owner_tile_key,
                    "bidirectional": true,
                    "cost": start.distance_to(end),
                    "heightDelta": float(candidate.get("heightDelta", 0.0)),
                    "laneWidth": lane_width,
                    "certifiedCorridorWidth": corridor_width,
                    "laneSampleCount": run_end - run_start,
                    "laneIndex": int(candidate.get("laneIndex", 0)),
                    "laneNumber": lane_number,
                    "laneCount": lane_count,
                    "seamCorridorId": seam_corridor_id,
                    "crossingAxis": String(candidate.get("axis", "")),
                    "capacity": 1,
                    "requiresScriptedTraversal": true,
                    "forwardTraversal": endpoints.get("forwardTraversal", {}),
                    "reverseTraversal": endpoints.get("reverseTraversal", {}),
                    "participatingTiles": participating_tiles,
                    "sourceOwners": candidate.get("sourceOwners", []),
                    "sourceRevision": int(navmesh_tile_revision_by_key.get(owner_tile_key, static_snapshot_revision)),
                    "topologyRevision": int(navmesh_tile_revision_by_key.get(owner_tile_key, static_snapshot_revision)),
                    "collisionBacked": true
                })
            run_start = run_end
    result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
        return String(left.get("id", "")) < String(right.get("id", ""))
    )
    return result


func _building_support_producer_tile_key(support: Dictionary) -> String:
    var declared := String(support.get("producerTileKey", ""))
    if not declared.is_empty():
        return declared
    var center: Vector3 = support.get("worldPosition", Vector3.INF) as Vector3
    if not center.is_finite():
        var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
        center = Vector3.ZERO
        var point_count := 0
        for point_value in polygon:
            if point_value is Vector3:
                center += point_value as Vector3
                point_count += 1
        if point_count == 0:
            return ""
        center /= float(point_count)
    return tile_key_for_cell(world_cell(center))


func _surface_transition_lane_candidate_indices(run_start: int, run_end: int, lane_number: int, lane_count: int) -> Array[int]:
    var run_size := run_end - run_start
    var slot_start := run_start + floori(float(lane_number * run_size) / float(lane_count))
    var slot_end := run_start + floori(float((lane_number + 1) * run_size) / float(lane_count))
    slot_end = maxi(slot_start + 1, slot_end)
    var preferred := clampi((slot_start + slot_end - 1) / 2, slot_start, slot_end - 1)
    var result: Array[int] = [preferred]
    for distance in range(1, slot_end - slot_start):
        var lower := preferred - distance
        var upper := preferred + distance
        if lower >= slot_start:
            result.append(lower)
        if upper < slot_end:
            result.append(upper)
    return result


func _certified_surface_transition_endpoints(snapshot: Dictionary, candidate: Dictionary, link_id := "") -> Dictionary:
    var original_start: Vector3 = candidate.get("start", Vector3.INF) as Vector3
    var original_end: Vector3 = candidate.get("end", Vector3.INF) as Vector3
    var crossing_vector := original_end - original_start
    crossing_vector.y = 0.0
    if not original_start.is_finite() or not original_end.is_finite() or crossing_vector.length_squared() <= 0.000001:
        return {}
    var crossing_direction := crossing_vector.normalized()
    var seam_center := (original_start + original_end) * 0.5
    var seam_certificate: Dictionary = candidate.get("seamCertificate", {}) if candidate.get("seamCertificate", {}) is Dictionary else {}
    var start_support_id := String(candidate.get("startSupportId", ""))
    var end_support_id := String(candidate.get("endSupportId", ""))
    var support_to_support := not start_support_id.begins_with("terrain:") and not end_support_id.begins_with("terrain:")
    if support_to_support and bool(seam_certificate.get("ok", false)) and seam_certificate.has("seamProjection") and seam_certificate.has("laneCenter"):
        var crossing_axis := Vector2(crossing_direction.x, crossing_direction.z)
        var lateral_axis := Vector2(-crossing_axis.y, crossing_axis.x)
        var seam_point_2d := crossing_axis * float(seam_certificate.get("seamProjection", 0.0)) + lateral_axis * float(seam_certificate.get("laneCenter", 0.0))
        seam_center.x = seam_point_2d.x
        seam_center.z = seam_point_2d.y
    var endpoint_inset := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
    var start := seam_center - crossing_direction * endpoint_inset
    var end := seam_center + crossing_direction * endpoint_inset
    start.y = original_start.y
    end.y = original_end.y
    if snapshot.is_empty():
        return {"start": start, "end": end}
    var forward_traversal := _surface_transition_phase_bundle(snapshot, link_id, "forward", start, end, start_support_id, end_support_id)
    if not bool(forward_traversal.get("ok", false)):
        _record_surface_transition_publication_failure(link_id, candidate, forward_traversal)
        return {}
    var reverse_traversal := _surface_transition_phase_bundle(snapshot, link_id, "reverse", end, start, end_support_id, start_support_id)
    if not bool(reverse_traversal.get("ok", false)):
        _record_surface_transition_publication_failure(link_id, candidate, reverse_traversal)
        return {}
    return {
        "start": start,
        "end": end,
        "forwardTraversal": forward_traversal,
        "reverseTraversal": reverse_traversal
    }


func _surface_transition_phase_bundle(snapshot: Dictionary, link_id: String, direction: String, entry_position: Vector3, exit_position: Vector3, entry_support_id: String, exit_support_id: String) -> Dictionary:
    var transition_axis := exit_position - entry_position
    transition_axis.y = 0.0
    if transition_axis.length_squared() <= 0.0001:
        return {"ok": false, "reason": "degenerate_transition_axis", "linkId": link_id, "direction": direction}
    transition_axis = transition_axis.normalized()
    var crossing_clearance := NpcConstantsScript.TRAFFIC_RETREAT_CLEARANCE + NpcConstantsScript.NAVIGATION_TRANSITION_PHASE_RADIUS
    var queue_clearance := crossing_clearance + NpcConstantsScript.DEFAULT_NPC_RADIUS * 2.0 + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
    var action := {
        "linkId": link_id,
        "direction": direction,
        "entryPosition": entry_position,
        "exitPosition": exit_position,
        "entrySupportId": entry_support_id,
        "exitSupportId": exit_support_id,
        "stagingPosition": entry_position - transition_axis * crossing_clearance,
        "queuePosition": entry_position - transition_axis * queue_clearance,
        "clearancePosition": exit_position + transition_axis * crossing_clearance
    }
    var touched_tile_keys: Array = []
    for position_key in ["entryPosition", "exitPosition", "stagingPosition", "queuePosition", "clearancePosition"]:
        var position: Vector3 = action.get(position_key, Vector3.INF) as Vector3
        if not position.is_finite():
            continue
        var touched_tile_key := tile_key_for_cell(world_cell(position))
        if not touched_tile_keys.has(touched_tile_key):
            touched_tile_keys.append(touched_tile_key)
    var validation_snapshot := _surface_transition_validation_snapshot(snapshot, touched_tile_keys)
    var certificate := validate_surface_transition_action(validation_snapshot, action)
    if not bool(certificate.get("ok", false)):
        return {"ok": false, "reason": String(certificate.get("reason", "surface_transition_uncertified")), "linkId": link_id, "direction": direction, "certificate": certificate}
    action["ok"] = true
    action["corridorCertificate"] = certificate
    action["participatingTiles"] = certificate.get("participatingTiles", [])
    action["staticSnapshotRevision"] = int(certificate.get("staticSnapshotRevision", static_snapshot_revision))
    action["doorStateRevision"] = int(certificate.get("doorStateRevision", door_state_revision))
    return action


func _merged_surface_transition_participating_tiles(first_value, second_value) -> Array[Dictionary]:
    var by_tile := {}
    for records_value in [first_value, second_value]:
        if not (records_value is Array):
            continue
        for record_value in records_value:
            if not (record_value is Dictionary):
                continue
            var record: Dictionary = record_value
            var tile_key := String(record.get("tileKey", ""))
            if not tile_key.is_empty():
                by_tile[tile_key] = record.duplicate(true)
    var tile_keys: Array = by_tile.keys()
    tile_keys.sort_custom(func(left, right) -> bool:
        return _canonical_navigation_tile_key(String(left), String(right)) == String(left)
    )
    var result: Array[Dictionary] = []
    for tile_key_value in tile_keys:
        result.append(by_tile[tile_key_value] as Dictionary)
    return result


func _record_surface_transition_publication_failure(link_id: String, candidate: Dictionary, failure: Dictionary) -> void:
    surface_transition_publication_failures.append({
        "linkId": link_id,
        "direction": String(failure.get("direction", "")),
        "reason": String(failure.get("reason", "surface_transition_uncertified")),
        "startSupportId": String(candidate.get("startSupportId", "")),
        "endSupportId": String(candidate.get("endSupportId", "")),
        "laneIndex": int(candidate.get("laneIndex", -1)),
        "certificate": failure.get("certificate", {})
    })
    if surface_transition_publication_failures.size() > 256:
        surface_transition_publication_failures.pop_front()


func _building_navigation_transition_door_blocker(snapshot: Dictionary, start: Vector3, end: Vector3) -> Dictionary:
    var start_cell := world_cell(start)
    var end_cell := world_cell(end)
    var minimum_y := minf(start.y, end.y) + 0.02
    var maximum_y := maxf(start.y, end.y) + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
    for record_value in _transition_collision_records(snapshot, "doorCollisionByCell", start_cell, end_cell):
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        if float(record.get("maxY", -INF)) < minimum_y or float(record.get("minY", INF)) > maximum_y:
            continue
        if _segment_intersects_collision_record(start, end, record):
            return record
    return {}


func _resolve_building_navigation_link_endpoints(snapshot: Dictionary, links: Array[Dictionary]) -> Array[Dictionary]:
    var resolved_links: Array[Dictionary] = []
    for link_value in links:
        var link: Dictionary = link_value.duplicate(true)
        var kind := String(link.get("kind", ""))
        if kind == "support_seam":
            resolved_links.append_array(_resolve_building_support_seam_links(snapshot, link))
            continue
        if kind not in ["interior_passage", "stair_ramp"]:
            resolved_links.append(link)
            continue
        var start_support_id := String(link.get("startSupportId", link.get("supportId", link.get("firstSupportId", ""))))
        var end_support_id := String(link.get("endSupportId", link.get("supportId", link.get("secondSupportId", ""))))
        var authored_start: Vector3 = link.get("start", Vector3.INF) as Vector3
        var authored_end: Vector3 = link.get("end", Vector3.INF) as Vector3
        if kind == "stair_ramp" and not bool(_building_navigation_link_owner_resolution(link, start_support_id, end_support_id).get("resolved", false)):
            continue
        var start_tile_key := _building_navigation_link_endpoint_tile_key(link, "start", authored_start)
        var end_tile_key := _building_navigation_link_endpoint_tile_key(link, "end", authored_end)
        var transition_axis := authored_end - authored_start if kind == "stair_ramp" else Vector3.ZERO
        var start_resolution := _resolve_building_navigation_link_endpoint(snapshot, start_support_id, authored_start, start_tile_key, transition_axis)
        var end_resolution := _resolve_building_navigation_link_endpoint(snapshot, end_support_id, authored_end, end_tile_key, transition_axis)
        if not bool(start_resolution.get("resolved", false)) or not bool(end_resolution.get("resolved", false)):
            continue
        var resolved_start: Vector3 = start_resolution.get("position", authored_start) as Vector3
        var resolved_end: Vector3 = end_resolution.get("position", authored_end) as Vector3
        if kind == "interior_passage":
            var start_support := _building_support_by_id(start_support_id)
            var link_blocker := _building_navigation_link_blocker(snapshot, start_support, resolved_start, resolved_end)
            if not link_blocker.is_empty():
                continue
        link["start"] = resolved_start
        link["end"] = resolved_end
        link["authoredStart"] = authored_start
        link["authoredEnd"] = authored_end
        link["endpointResolution"] = {
            "start": start_resolution,
            "end": end_resolution,
            "startDrift": resolved_start.distance_to(authored_start),
            "endDrift": resolved_end.distance_to(authored_end)
        }
        resolved_links.append(link)
    return resolved_links


func _resolve_building_support_seam_links(snapshot: Dictionary, link: Dictionary) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var support_id := String(link.get("supportId", ""))
    var support := _building_support_by_id(support_id)
    var axis := String(link.get("axis", ""))
    var authored_start: Vector3 = link.get("start", Vector3.INF) as Vector3
    var authored_end: Vector3 = link.get("end", Vector3.INF) as Vector3
    if support.is_empty() or axis not in ["x", "z"] or not authored_start.is_finite() or not authored_end.is_finite():
        return result
    var seam_coordinate := float(link.get("seamCoordinate", INF))
    if not is_finite(seam_coordinate):
        seam_coordinate = _building_navigation_link_axis_value(authored_start, axis) + (_building_navigation_link_axis_value(authored_end, axis) - _building_navigation_link_axis_value(authored_start, axis)) * 0.5
    var start_tile_key := _building_navigation_link_endpoint_tile_key(link, "start", authored_start)
    var end_tile_key := _building_navigation_link_endpoint_tile_key(link, "end", authored_end)
    var start_snapshot := _navmesh_snapshot_with_live_tile_blocks(snapshot, start_tile_key)
    var end_snapshot := _navmesh_snapshot_with_live_tile_blocks(snapshot, end_tile_key)
    var start_samples: Dictionary = _building_support_navigation_sample_data(support, start_snapshot, start_tile_key).get("navigableCells", {}) as Dictionary
    var end_samples: Dictionary = _building_support_navigation_sample_data(support, end_snapshot, end_tile_key).get("navigableCells", {}) as Dictionary
    var start_side := signf(_building_navigation_link_axis_value(authored_start, axis) - seam_coordinate)
    var end_side := signf(_building_navigation_link_axis_value(authored_end, axis) - seam_coordinate)
    if start_side == 0.0 or end_side == 0.0 or is_equal_approx(start_side, end_side):
        return result
    var start_lanes := _building_support_seam_lane_positions(start_samples, axis, seam_coordinate, start_side)
    var end_lanes := _building_support_seam_lane_positions(end_samples, axis, seam_coordinate, end_side)
    var lane_indices: Array = start_lanes.keys()
    lane_indices.sort()
    for lane_value in lane_indices:
        var lane_index := int(lane_value)
        if not end_lanes.has(lane_index):
            continue
        var start_resolution: Dictionary = start_lanes.get(lane_index, {}) as Dictionary
        var end_resolution: Dictionary = end_lanes.get(lane_index, {}) as Dictionary
        var resolved_start: Vector3 = start_resolution.get("position", Vector3.INF) as Vector3
        var resolved_end: Vector3 = end_resolution.get("position", Vector3.INF) as Vector3
        if not resolved_start.is_finite() or not resolved_end.is_finite():
            continue
        var link_blocker := _building_navigation_link_blocker(snapshot, support, resolved_start, resolved_end)
        if not link_blocker.is_empty():
            continue
        var resolved_link := link.duplicate(true)
        resolved_link["id"] = "%s:lane:%d" % [String(link.get("id", "")), lane_index]
        resolved_link["start"] = resolved_start
        resolved_link["end"] = resolved_end
        resolved_link["authoredStart"] = authored_start
        resolved_link["authoredEnd"] = authored_end
        resolved_link["cost"] = resolved_start.distance_to(resolved_end)
        resolved_link["bounds"] = AABB(resolved_start, Vector3.ZERO).expand(resolved_end).grow(CELL * 0.04)
        resolved_link["endpointResolution"] = {
            "start": start_resolution,
            "end": end_resolution
        }
        result.append(resolved_link)
    return result


func _building_support_seam_lane_positions(samples: Dictionary, axis: String, seam_coordinate: float, side: float) -> Dictionary:
    var lanes := {}
    for cell_value in samples.keys():
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var position: Vector3 = samples.get(cell, Vector3.INF) as Vector3
        if not position.is_finite():
            continue
        var axis_value := _building_navigation_link_axis_value(position, axis)
        var side_distance := (axis_value - seam_coordinate) * side
        if side_distance <= 0.0 or side_distance > BUILDING_SUPPORT_SEAM_MAX_ENDPOINT_DISTANCE:
            continue
        var lane_index := cell.x if axis == "z" else cell.y
        var existing: Dictionary = lanes.get(lane_index, {}) as Dictionary
        if existing.is_empty() or side_distance < float(existing.get("distanceToSeam", INF)):
            lanes[lane_index] = {
                "cell": cell,
                "position": position,
                "distanceToSeam": side_distance
            }
    return lanes


func _building_navigation_link_axis_value(position: Vector3, axis: String) -> float:
    return position.x if axis == "x" else position.z


func _building_navigation_link_blocker(snapshot: Dictionary, support: Dictionary, start: Vector3, end: Vector3, clearance := BUILDING_SUPPORT_NAV_CLEARANCE, additional_allowed_source_parts := []) -> Dictionary:
    if support.is_empty():
        return {"reason": "missing_support"}
    var minimum := Vector2(minf(start.x, end.x), minf(start.z, end.z))
    var maximum := Vector2(maxf(start.x, end.x), maxf(start.z, end.z))
    return _building_support_navigation_blocker_for_footprint(snapshot, support, minf(start.y, end.y), minimum, maximum, clearance, additional_allowed_source_parts)


func _building_navigation_link_owner_resolution(link: Dictionary, start_support_id: String, end_support_id: String) -> Dictionary:
    var egress_owner_door_part_id := String(link.get("egressOwnerDoorPartId", ""))
    if egress_owner_door_part_id.is_empty():
        return {"resolved": true}
    var start_support := _building_support_by_id(start_support_id)
    var end_support := _building_support_by_id(end_support_id)
    var start_owner := String(start_support.get("egressOwnerDoorPartId", ""))
    var end_owner := String(end_support.get("egressOwnerDoorPartId", ""))
    return {"resolved": start_owner == egress_owner_door_part_id and end_owner == egress_owner_door_part_id, "reason": "" if start_owner == egress_owner_door_part_id and end_owner == egress_owner_door_part_id else "egress_support_owner_mismatch", "egressOwnerDoorPartId": egress_owner_door_part_id, "startSupportOwner": start_owner, "endSupportOwner": end_owner}


func _resolve_building_navigation_link_endpoint(snapshot: Dictionary, support_id: String, authored_position: Vector3, tile_key: String, transition_axis := Vector3.ZERO) -> Dictionary:
    if support_id.is_empty() or not authored_position.is_finite():
        return {"resolved": false, "reason": "missing_support_or_position"}
    var support := _building_support_by_id(support_id)
    if support.is_empty():
        return {"resolved": false, "reason": "support_not_found", "supportId": support_id}
    if transition_axis is Vector3 and (transition_axis as Vector3).length_squared() > 0.0001:
        var exact_resolution := BuildingNavigationTransitionCertifierScript.certify_endpoint(support, authored_position, transition_axis as Vector3, BUILDING_SUPPORT_NAV_CLEARANCE, func(position: Vector3) -> Dictionary: return _building_navigation_link_blocker(snapshot, support, authored_position, position, BUILDING_SUPPORT_NAV_CLEARANCE))
        exact_resolution["tileKey"] = tile_key
        if bool(exact_resolution.get("resolved", false)):
            exact_resolution["cell"] = world_cell(exact_resolution.get("position", authored_position) as Vector3)
        return exact_resolution
    if tile_key.is_empty():
        tile_key = tile_key_for_cell(world_cell(authored_position))
    var tile_snapshot := _navmesh_snapshot_with_live_tile_blocks(snapshot, tile_key)
    var sample_data := _building_support_navigation_sample_data(support, tile_snapshot, tile_key)
    var navigable_cells: Dictionary = sample_data.get("navigableCells", {}) if sample_data.get("navigableCells", {}) is Dictionary else {}
    var best_position := Vector3.INF
    var best_distance := INF
    var best_cell := Vector2i.ZERO
    for cell_value in navigable_cells.keys():
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var candidate: Vector3 = navigable_cells.get(cell, Vector3.INF) as Vector3
        if not candidate.is_finite():
            continue
        var distance := candidate.distance_to(authored_position)
        if distance < best_distance - 0.0001 or (is_equal_approx(distance, best_distance) and (cell.x < best_cell.x or (cell.x == best_cell.x and cell.y < best_cell.y))):
            best_position = candidate
            best_distance = distance
            best_cell = cell
    if not best_position.is_finite():
        return {"resolved": false, "reason": "no_collision_screened_support_sample", "supportId": support_id, "tileKey": tile_key}
    return {
        "resolved": true,
        "supportId": support_id,
        "tileKey": tile_key,
        "cell": best_cell,
        "position": best_position,
        "distance": best_distance
    }


func _building_support_by_id(support_id: String) -> Dictionary:
    return cached_building_support_by_id.get(support_id, {}) as Dictionary


func _building_navigation_link_owner_tile_key(link: Dictionary) -> String:
    var owner_tile_key := String(link.get("ownerTileKey", ""))
    if not owner_tile_key.is_empty():
        return owner_tile_key
    var start: Vector3 = link.get("start", Vector3.INF) as Vector3
    if start.is_finite():
        return tile_key_for_cell(world_cell(start))
    var tile_keys: Array = link.get("tileKeys", []) if link.get("tileKeys", []) is Array else []
    return String(tile_keys[0]) if not tile_keys.is_empty() else ""


func _building_navigation_link_endpoint_tile_key(link: Dictionary, endpoint: String, position: Vector3) -> String:
    var declared_tile_key := String(link.get("%sTileKey" % endpoint.capitalize(), ""))
    if not declared_tile_key.is_empty():
        return declared_tile_key
    if position.is_finite():
        return tile_key_for_cell(world_cell(position))
    return _building_navigation_link_owner_tile_key(link)


func building_support_navigation_sample_diagnostics(support_id: String, tile_key: String, probes: Array = [], options := {}) -> Dictionary:
    var support := {}
    for support_value in cached_building_supports:
        if support_value is Dictionary and String((support_value as Dictionary).get("id", "")) == support_id:
            support = support_value as Dictionary
            break
    if support.is_empty():
        return {"diagnosticOnly": true, "reason": "support_not_found", "supportId": support_id, "tileKey": tile_key}
    var snapshot := _navmesh_snapshot_with_live_tile_blocks(cached_static_tile_snapshot(true, true), tile_key)
    if bool(options.get("excludeFurnishings", false)):
        snapshot = _diagnostic_snapshot_without_furnishings(snapshot)
    var sample_data := _building_support_navigation_sample_data(support, snapshot, tile_key)
    var navigable_cells: Dictionary = sample_data.get("navigableCells", {}) if sample_data.get("navigableCells", {}) is Dictionary else {}
    var blocked_by_cell: Dictionary = sample_data.get("blockedByCell", {}) if sample_data.get("blockedByCell", {}) is Dictionary else {}
    var component_by_cell := {}
    var components: Array[Dictionary] = []
    var sorted_cells: Array = navigable_cells.keys()
    sorted_cells.sort_custom(func(left: Vector2i, right: Vector2i) -> bool:
        return left.x < right.x if left.y == right.y else left.y < right.y
    )
    for cell_value in sorted_cells:
        if not (cell_value is Vector2i):
            continue
        var start: Vector2i = cell_value
        if component_by_cell.has(start):
            continue
        var component_id := components.size()
        var queue: Array[Vector2i] = [start]
        var cell_count := 0
        var minimum := Vector2i(2147483647, 2147483647)
        var maximum := Vector2i(-2147483647, -2147483647)
        while not queue.is_empty():
            var current: Vector2i = queue.pop_front()
            if component_by_cell.has(current) or not navigable_cells.has(current):
                continue
            component_by_cell[current] = component_id
            cell_count += 1
            minimum.x = mini(minimum.x, current.x)
            minimum.y = mini(minimum.y, current.y)
            maximum.x = maxi(maximum.x, current.x)
            maximum.y = maxi(maximum.y, current.y)
            for neighbor in [current + Vector2i.LEFT, current + Vector2i.RIGHT, current + Vector2i.UP, current + Vector2i.DOWN]:
                if navigable_cells.has(neighbor) and not component_by_cell.has(neighbor):
                    queue.append(neighbor)
        components.append({"id": component_id, "cellCount": cell_count, "minimumCell": minimum, "maximumCell": maximum})
    var blocker_counts := {}
    for blocker_value in blocked_by_cell.values():
        if not (blocker_value is Dictionary):
            continue
        var blocker: Dictionary = blocker_value
        var blocker_id := String(blocker.get("id", "unknown"))
        blocker_counts[blocker_id] = int(blocker_counts.get(blocker_id, 0)) + 1
    var blockers: Array[Dictionary] = []
    for blocker_id_value in blocker_counts.keys():
        var blocker_id := String(blocker_id_value)
        blockers.append({"id": blocker_id, "blockedSampleCount": int(blocker_counts[blocker_id]), "sourcePartId": blocker_id})
    blockers.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
        var left_count := int(left.get("blockedSampleCount", 0))
        var right_count := int(right.get("blockedSampleCount", 0))
        return String(left.get("id", "")) < String(right.get("id", "")) if left_count == right_count else left_count > right_count
    )
    var probe_results: Array[Dictionary] = []
    for probe_value in probes:
        if not (probe_value is Dictionary):
            continue
        var probe: Dictionary = probe_value
        var position: Vector3 = probe.get("position", Vector3.INF) if probe.get("position", Vector3.INF) is Vector3 else Vector3.INF
        if not position.is_finite():
            continue
        var nearest_cell := Vector2i.ZERO
        var nearest_position := Vector3.INF
        var nearest_distance := INF
        for cell_value in sorted_cells:
            if not (cell_value is Vector2i):
                continue
            var cell: Vector2i = cell_value
            var candidate: Vector3 = navigable_cells.get(cell, Vector3.INF) if navigable_cells.get(cell, Vector3.INF) is Vector3 else Vector3.INF
            var distance := candidate.distance_to(position)
            if distance < nearest_distance:
                nearest_cell = cell
                nearest_position = candidate
                nearest_distance = distance
        probe_results.append({
            "id": String(probe.get("id", "probe")),
            "position": position,
            "nearestCell": nearest_cell,
            "nearestPosition": nearest_position,
            "nearestDistance": nearest_distance,
            "componentId": int(component_by_cell.get(nearest_cell, -1))
        })
    return {
        "diagnosticOnly": true,
        "supportId": support_id,
        "tileKey": tile_key,
        "options": options.duplicate(true),
        "sampleStep": BUILDING_SUPPORT_NAV_SAMPLE_STEP,
        "navigableCellCount": navigable_cells.size(),
        "blockedCellCount": blocked_by_cell.size(),
        "componentCount": components.size(),
        "components": components,
        "topBlockedSources": blockers.slice(0, 8),
        "probes": probe_results
    }


static func source_support_connectivity(building_manifest: Dictionary, collision_manifests: Array, support_id: String, probes: Array, snap_distance: float) -> Dictionary:
    var adapter = GeneratedWorldNavigationAdapter.new()
    adapter._load_source_navigation_manifests(building_manifest, collision_manifests)
    return adapter._source_support_connectivity(support_id, probes, snap_distance)


static func source_support_connectivities(building_manifest: Dictionary, collision_manifests: Array, requests: Array) -> Dictionary:
    var adapter = GeneratedWorldNavigationAdapter.new()
    adapter._load_source_navigation_manifests(building_manifest, collision_manifests)
    var result := {}
    for request_value in requests:
        if not (request_value is Dictionary):
            continue
        var request: Dictionary = request_value
        var request_id := String(request.get("id", ""))
        if request_id.is_empty():
            continue
        result[request_id] = adapter._source_support_connectivity(
            String(request.get("supportId", "")),
            request.get("probes", []) as Array,
            float(request.get("snapDistance", 0.0))
        )
    return result


static func source_support_probe_resolutions(building_manifest: Dictionary, collision_manifests: Array, support_id: String, probes: Array, snap_distance: float, stop_after_first_resolved := false) -> Dictionary:
    var adapter = GeneratedWorldNavigationAdapter.new()
    adapter._load_source_navigation_manifests(building_manifest, collision_manifests)
    return adapter._source_support_probe_resolutions(support_id, probes, snap_distance, stop_after_first_resolved)


static func building_navigation_link_resolution_contract(building_manifest: Dictionary, collision_manifests: Array, link_ids: Array = []) -> Array[Dictionary]:
    var adapter = GeneratedWorldNavigationAdapter.new()
    adapter._load_source_navigation_manifests(building_manifest, collision_manifests)
    var requested_ids := {}
    for link_id_value in link_ids:
        requested_ids[String(link_id_value)] = true
    var result: Array[Dictionary] = []
    var visited_tiles := {}
    for link_value in building_manifest.get("verticalLinks", []) as Array:
        if not (link_value is Dictionary):
            continue
        var link: Dictionary = link_value
        var link_id := String(link.get("id", ""))
        if not requested_ids.is_empty() and not requested_ids.has(link_id):
            continue
        var tile_key := String(link.get("ownerTileKey", ""))
        if tile_key.is_empty() or visited_tiles.has(tile_key):
            continue
        visited_tiles[tile_key] = true
        result.append_array(adapter.building_navigation_link_resolution_diagnostics(tile_key, link_ids))
    return result


static func building_navigation_snapshot_link_contract(building_manifest: Dictionary, collision_manifests: Array, link_ids: Array = []) -> Array[Dictionary]:
    var adapter = GeneratedWorldNavigationAdapter.new()
    adapter._load_source_navigation_manifests(building_manifest, collision_manifests)
    var requested_ids := {}
    for link_id_value in link_ids:
        requested_ids[String(link_id_value)] = true
    var result: Array[Dictionary] = []
    var visited_tiles := {}
    for link_value in building_manifest.get("verticalLinks", []) as Array:
        if not (link_value is Dictionary):
            continue
        var link: Dictionary = link_value
        var link_id := String(link.get("id", ""))
        if not requested_ids.is_empty() and not requested_ids.has(link_id):
            continue
        var tile_key := String(link.get("ownerTileKey", ""))
        if tile_key.is_empty() or visited_tiles.has(tile_key):
            continue
        visited_tiles[tile_key] = true
        var tile_snapshot := adapter.build_navmesh_tile_snapshot(tile_key)
        for published_value in tile_snapshot.get("navigationLinks", []) as Array:
            if not (published_value is Dictionary):
                continue
            var published: Dictionary = published_value
            if requested_ids.is_empty() or requested_ids.has(String(published.get("id", ""))):
                result.append(published)
    return result


static func source_support_reachable_probe_resolutions(building_manifest: Dictionary, collision_manifests: Array, support_id: String, probes: Array, target_probe: Dictionary, snap_distance: float) -> Dictionary:
    var adapter = GeneratedWorldNavigationAdapter.new()
    adapter._load_source_navigation_manifests(building_manifest, collision_manifests)
    return adapter._source_support_reachable_probe_resolutions(support_id, probes, target_probe, snap_distance)


func _load_source_navigation_manifests(building_manifest: Dictionary, collision_manifests: Array) -> void:
    cached_revision = str(JSON.stringify({"building": building_manifest, "collision": collision_manifests}).hash())
    cached_static_collision_records = []
    cached_static_collision_by_cell = {}
    cached_static_collision_broad = []
    cached_building_supports = []
    cached_building_supports_by_tile = {}
    cached_building_vertical_links = []
    cached_building_support_seam_links = []
    cached_building_interior_passage_links = []
    for support_value in building_manifest.get("supports", []) as Array:
        if support_value is Dictionary:
            cached_building_supports.append((support_value as Dictionary).duplicate(true))
    for link_value in building_manifest.get("verticalLinks", []) as Array:
        if link_value is Dictionary:
            cached_building_vertical_links.append((link_value as Dictionary).duplicate(true))
    for link_value in building_manifest.get("supportSeamLinks", []) as Array:
        if link_value is Dictionary:
            cached_building_support_seam_links.append((link_value as Dictionary).duplicate(true))
    for link_value in building_manifest.get("interiorPassageLinks", []) as Array:
        if link_value is Dictionary:
            cached_building_interior_passage_links.append((link_value as Dictionary).duplicate(true))
    _append_manifest_static_collision_records(building_manifest)
    for manifest_value in collision_manifests:
        if manifest_value is Dictionary:
            _append_manifest_static_collision_records(manifest_value as Dictionary)
    cached_building_supports.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
        return String(left.get("id", "")) < String(right.get("id", ""))
    )
    _index_building_supports_by_tile()


func _source_support_connectivity(support_id: String, probes: Array, snap_distance: float) -> Dictionary:
    var support := _building_support_by_id(support_id)
    if support.is_empty():
        return {"reachable": false, "reason": "missing_door_interior_support", "supportId": support_id}
    var snapshot := {
        "staticCollision": cached_static_collision_records,
        "staticCollisionByCell": cached_static_collision_by_cell,
        "staticCollisionBroad": cached_static_collision_broad
    }
    var support_component := _source_support_component_ids(support_id)
    var unsampled_supports: Array[Dictionary] = []
    var samples_by_support := _source_support_samples_by_id(snapshot, support_component, unsampled_supports)
    if not samples_by_support.has(support_id) or (samples_by_support.get(support_id, {}) as Dictionary).is_empty():
        return {"reachable": false, "reason": "no_collision_screened_support_samples", "supportId": support_id}
    var resolved_probes: Array[Dictionary] = []
    for probe_value in probes:
        if not (probe_value is Dictionary):
            continue
        var probe: Dictionary = probe_value as Dictionary
        var position: Vector3 = probe.get("position", Vector3.INF) as Vector3
        var probe_snap_distance := float(probe.get("snapDistance", snap_distance))
        var probe_support_id := String(probe.get("supportId", ""))
        var probe_samples := samples_by_support
        if not probe_support_id.is_empty():
            probe_samples = {probe_support_id: samples_by_support.get(probe_support_id, {})}
        var resolution := _nearest_connector_clear_source_support_probe(probe_samples, position, probe_snap_distance, snapshot)
        resolution["id"] = String(probe.get("id", "probe"))
        resolution["declaredSupportId"] = probe_support_id
        resolution["requestedPosition"] = position
        resolution["snapDistance"] = probe_snap_distance
        resolved_probes.append(resolution)
    if resolved_probes.size() < 2:
        return {"reachable": false, "reason": "missing_egress_probes", "supportId": support_id, "probes": resolved_probes}
    var start_resolution: Dictionary = resolved_probes[0]
    var target_resolution: Dictionary = resolved_probes[1]
    if not bool(start_resolution.get("resolved", false)) or not bool(target_resolution.get("resolved", false)):
        return {
            "reachable": false,
            "reason": "egress_probe_has_no_collision_screened_sample",
            "supportId": support_id,
            "probes": resolved_probes,
            "componentSupportIds": support_component.keys(),
            "unsampledSupports": unsampled_supports,
            "verticalLinks": _source_component_link_diagnostics(support_component, cached_building_vertical_links, "startSupportId", "endSupportId"),
            "residenceVerticalLinks": _source_residence_vertical_link_diagnostics(support),
            "interiorPassageLinks": _source_component_link_diagnostics(support_component, cached_building_interior_passage_links, "firstSupportId", "secondSupportId")
        }
    var start_support_id := String(start_resolution.get("supportId", ""))
    var target_support_id := String(target_resolution.get("supportId", ""))
    var start_cell: Vector2i = start_resolution.get("cell", INVALID_CELL) as Vector2i
    var target_cell: Vector2i = target_resolution.get("cell", INVALID_CELL) as Vector2i
    var adjacency := _source_sample_adjacency(samples_by_support, snapshot)
    var start_node := _source_sample_node_key(start_support_id, start_cell)
    var target_node := _source_sample_node_key(target_support_id, target_cell)
    var frontier: Array[String] = [start_node]
    var visited := {start_node: true}
    var cursor := 0
    while cursor < frontier.size():
        var current := String(frontier[cursor])
        cursor += 1
        if current == target_node:
            return {
                "reachable": true,
                "sourceCollisionRevision": cached_revision,
                "supportId": support_id,
                "startSupportId": start_support_id,
                "targetSupportId": target_support_id,
                "probes": resolved_probes,
                "visitedCellCount": visited.size()
            }
        for neighbor_value in adjacency.get(current, []) as Array:
            var neighbor := String(neighbor_value)
            if not visited.has(neighbor):
                visited[neighbor] = true
                frontier.append(neighbor)
    return {
        "reachable": false,
        "reason": "collision_screened_support_disconnected",
        "sourceCollisionRevision": cached_revision,
        "supportId": support_id,
        "probes": resolved_probes,
        "visitedCellCount": visited.size(),
        "startSupportId": start_support_id,
        "targetSupportId": target_support_id,
        "sampledSupportIds": samples_by_support.keys(),
        "unsampledSupports": unsampled_supports,
        "startNode": start_node,
        "targetNode": target_node,
        "startNeighbors": (adjacency.get(start_node, []) as Array).duplicate(),
        "targetNeighbors": (adjacency.get(target_node, []) as Array).duplicate(),
        "verticalLinks": _source_component_link_diagnostics(support_component, cached_building_vertical_links, "startSupportId", "endSupportId"),
        "interiorPassageLinks": _source_component_link_diagnostics(support_component, cached_building_interior_passage_links, "firstSupportId", "secondSupportId"),
        "declaredLinkResolutions": _source_declared_sample_link_diagnostics(samples_by_support, snapshot, support_component)
    }


func _source_support_probe_resolutions(support_id: String, probes: Array, snap_distance: float, stop_after_first_resolved := false) -> Dictionary:
    if _building_support_by_id(support_id).is_empty():
        return {"resolutions": [], "reason": "missing_support", "supportId": support_id}
    var snapshot := {
        "staticCollision": cached_static_collision_records,
        "staticCollisionByCell": cached_static_collision_by_cell,
        "staticCollisionBroad": cached_static_collision_broad
    }
    var support_component := _source_support_component_ids(support_id)
    var samples_by_support := _source_support_samples_by_id(snapshot, support_component)
    var resolutions: Array[Dictionary] = []
    for probe_value in probes:
        if not (probe_value is Dictionary):
            continue
        var probe: Dictionary = probe_value
        var position: Vector3 = probe.get("position", Vector3.INF) as Vector3
        var probe_snap_distance := float(probe.get("snapDistance", snap_distance))
        var probe_support_id := String(probe.get("supportId", ""))
        var probe_samples := samples_by_support
        if not probe_support_id.is_empty():
            probe_samples = {probe_support_id: samples_by_support.get(probe_support_id, {})}
        var resolution := _nearest_connector_clear_source_support_probe(probe_samples, position, probe_snap_distance, snapshot)
        resolution["id"] = String(probe.get("id", "probe"))
        resolution["declaredSupportId"] = probe_support_id
        resolution["requestedPosition"] = position
        resolution["snapDistance"] = probe_snap_distance
        resolution["candidateIndex"] = int(probe.get("candidateIndex", -1))
        resolutions.append(resolution)
        if stop_after_first_resolved and bool(resolution.get("resolved", false)):
            break
    return {"resolutions": resolutions, "supportId": support_id}


func _source_support_reachable_probe_resolutions(support_id: String, probes: Array, target_probe: Dictionary, snap_distance: float) -> Dictionary:
    if _building_support_by_id(support_id).is_empty():
        return {"resolutions": [], "reason": "missing_support", "supportId": support_id}
    var snapshot := {
        "staticCollision": cached_static_collision_records,
        "staticCollisionByCell": cached_static_collision_by_cell,
        "staticCollisionBroad": cached_static_collision_broad
    }
    var support_component := _source_support_component_ids(support_id)
    var samples_by_support := _source_support_samples_by_id(snapshot, support_component)
    var target_position: Vector3 = target_probe.get("position", Vector3.INF) as Vector3
    var target_support_id := String(target_probe.get("supportId", support_id))
    var target_samples := {target_support_id: samples_by_support.get(target_support_id, {})}
    var target_resolution := _nearest_connector_clear_source_support_probe(target_samples, target_position, float(target_probe.get("snapDistance", snap_distance)), snapshot)
    if not bool(target_resolution.get("resolved", false)):
        return {"resolutions": [], "reason": "target_probe_unresolved", "supportId": support_id, "targetResolution": target_resolution}
    var adjacency := _source_sample_adjacency(samples_by_support, snapshot)
    var target_cell: Vector2i = target_resolution.get("cell", INVALID_CELL) as Vector2i
    var target_node := _source_sample_node_key(String(target_resolution.get("supportId", target_support_id)), target_cell)
    var reachable_nodes := {target_node: true}
    var frontier: Array[String] = [target_node]
    var cursor := 0
    while cursor < frontier.size():
        var current := String(frontier[cursor])
        cursor += 1
        for neighbor_value in adjacency.get(current, []) as Array:
            var neighbor := String(neighbor_value)
            if not reachable_nodes.has(neighbor):
                reachable_nodes[neighbor] = true
                frontier.append(neighbor)
    var resolutions: Array[Dictionary] = []
    for probe_value in probes:
        if not (probe_value is Dictionary):
            continue
        var probe: Dictionary = probe_value
        var probe_position: Vector3 = probe.get("position", Vector3.INF) as Vector3
        var probe_support_id := String(probe.get("supportId", ""))
        var probe_samples := samples_by_support if probe_support_id.is_empty() else {probe_support_id: samples_by_support.get(probe_support_id, {})}
        var resolution := _nearest_connector_clear_source_support_probe(probe_samples, probe_position, float(probe.get("snapDistance", snap_distance)), snapshot)
        resolution["id"] = String(probe.get("id", "probe"))
        resolution["candidateIndex"] = int(probe.get("candidateIndex", -1))
        resolution["declaredSupportId"] = probe_support_id
        resolution["requestedPosition"] = probe_position
        resolution["snapDistance"] = float(probe.get("snapDistance", snap_distance))
        if bool(resolution.get("resolved", false)):
            var probe_node := _source_sample_node_key(String(resolution.get("supportId", probe_support_id)), resolution.get("cell", INVALID_CELL) as Vector2i)
            resolution["reachableToTarget"] = reachable_nodes.has(probe_node)
            resolution["targetNode"] = target_node
        else:
            resolution["reachableToTarget"] = false
        resolutions.append(resolution)
    target_resolution["requestedPosition"] = target_position
    target_resolution["declaredSupportId"] = target_support_id
    return {
        "resolutions": resolutions,
        "supportId": support_id,
        "targetResolution": target_resolution,
        "sourceCollisionRevision": cached_revision,
        "reachableNodeCount": reachable_nodes.size()
    }


func _source_support_samples_by_id(snapshot: Dictionary, allowed_support_ids: Dictionary, unsampled_diagnostics: Array[Dictionary] = []) -> Dictionary:
    var result := {}
    for support in cached_building_supports:
        var support_id := String(support.get("id", ""))
        if support_id.is_empty() or not allowed_support_ids.has(support_id):
            continue
        var samples := {}
        var blocker_counts := {}
        var blocker_examples := {}
        for tile_key_value in support.get("tileKeys", []) as Array:
            var tile_key := String(tile_key_value)
            if tile_key.is_empty():
                continue
            var sample_data := _building_support_navigation_sample_data(support, snapshot, tile_key)
            var tile_cells: Dictionary = sample_data.get("navigableCells", {}) as Dictionary
            for blocker_value in (sample_data.get("blockedByCell", {}) as Dictionary).values():
                if blocker_value is Dictionary:
                    var blocker_id := String((blocker_value as Dictionary).get("sourcePartId", (blocker_value as Dictionary).get("id", "unknown")))
                    blocker_counts[blocker_id] = int(blocker_counts.get(blocker_id, 0)) + 1
                    if not blocker_examples.has(blocker_id):
                        blocker_examples[blocker_id] = blocker_value
            for cell_value in tile_cells.keys():
                if cell_value is Vector2i:
                    samples[cell_value] = tile_cells[cell_value]
        if not samples.is_empty():
            result[support_id] = samples
        elif unsampled_diagnostics.size() < 12:
            var blockers: Array[Dictionary] = []
            for blocker_id_value in blocker_counts.keys():
                var blocker_id := String(blocker_id_value)
                var blocker_example: Dictionary = blocker_examples.get(blocker_id, {}) as Dictionary
                blockers.append({"sourcePartId": blocker_id, "blockedSampleCount": int(blocker_counts.get(blocker_id, 0)), "bounds": blocker_example.get("bounds", AABB())})
            blockers.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
                return int(left.get("blockedSampleCount", 0)) > int(right.get("blockedSampleCount", 0))
            )
            unsampled_diagnostics.append({"supportId": support_id, "sourcePartId": String(support.get("sourcePartId", "")), "polygon": (support.get("polygon", []) as Array).duplicate(), "topBlockedSources": blockers.slice(0, 6)})
    return result


func _source_support_component_ids(origin_support_id: String) -> Dictionary:
    var adjacency := {}
    for support in cached_building_supports:
        var support_id := String(support.get("id", ""))
        if not support_id.is_empty():
            adjacency[support_id] = []
    for link in cached_building_vertical_links:
        _append_source_support_edge(adjacency, String(link.get("startSupportId", "")), String(link.get("endSupportId", "")))
    for link in cached_building_interior_passage_links:
        _append_source_support_edge(adjacency, String(link.get("firstSupportId", "")), String(link.get("secondSupportId", "")))
    var visited := {}
    if not adjacency.has(origin_support_id):
        return visited
    var frontier: Array[String] = [origin_support_id]
    var cursor := 0
    visited[origin_support_id] = true
    while cursor < frontier.size():
        var current := String(frontier[cursor])
        cursor += 1
        for neighbor_value in adjacency.get(current, []) as Array:
            var neighbor := String(neighbor_value)
            if not visited.has(neighbor):
                visited[neighbor] = true
                frontier.append(neighbor)
    var origin_support := _building_support_by_id(origin_support_id)
    var source_part_id := String(origin_support.get("sourcePartId", ""))
    var separator := source_part_id.find("__")
    var residence_prefix := source_part_id.left(separator + 2) if separator >= 0 else ""
    if not residence_prefix.is_empty():
        for support in cached_building_supports:
            if String(support.get("sourcePartId", "")).begins_with(residence_prefix):
                visited[String(support.get("id", ""))] = true
    return visited


func _nearest_source_support_probe(samples_by_support: Dictionary, position: Vector3, snap_distance: float) -> Dictionary:
    var best := {"resolved": false, "reason": "no_sample_within_snap_distance", "distance": INF}
    for support_id_value in samples_by_support.keys():
        var resolution := _nearest_source_support_sample(samples_by_support.get(support_id_value, {}) as Dictionary, position, snap_distance)
        if bool(resolution.get("resolved", false)) and float(resolution.get("distance", INF)) < float(best.get("distance", INF)):
            best = resolution
            best["supportId"] = String(support_id_value)
        elif not bool(best.get("resolved", false)) and float(resolution.get("distance", INF)) < float(best.get("distance", INF)):
            best["distance"] = float(resolution.get("distance", INF))
            best["nearestSupportId"] = String(support_id_value)
    return best


func _nearest_connector_clear_source_support_probe(samples_by_support: Dictionary, position: Vector3, snap_distance: float, snapshot: Dictionary) -> Dictionary:
    var best := {"resolved": false, "reason": "no_sample_within_snap_distance", "distance": INF}
    var nearest_blocked := {}
    for support_id_value in samples_by_support.keys():
        var support_id := String(support_id_value)
        var support := _building_support_by_id(support_id)
        for cell_value in (samples_by_support.get(support_id_value, {}) as Dictionary).keys():
            if not (cell_value is Vector2i):
                continue
            var cell: Vector2i = cell_value
            var candidate: Vector3 = (samples_by_support.get(support_id_value, {}) as Dictionary).get(cell, Vector3.INF) as Vector3
            if not candidate.is_finite():
                continue
            var distance := candidate.distance_to(position)
            if distance > snap_distance:
                if distance < float(best.get("distance", INF)):
                    best["distance"] = distance
                    best["nearestSupportId"] = support_id
                continue
            var blocker := _building_navigation_link_blocker(snapshot, support, position, candidate, NpcConstantsScript.DEFAULT_NPC_RADIUS)
            if blocker.is_empty():
                if not bool(best.get("resolved", false)) or distance < float(best.get("distance", INF)) - 0.0001 \
                    or (is_equal_approx(distance, float(best.get("distance", INF))) and support_id < String(best.get("supportId", ""))):
                    best = {"resolved": true, "supportId": support_id, "cell": cell, "position": candidate, "distance": distance, "connectorClear": true}
                continue
            if nearest_blocked.is_empty() or distance < float(nearest_blocked.get("distance", INF)):
                nearest_blocked = {
                    "distance": distance,
                    "supportId": support_id,
                    "cell": cell,
                    "position": candidate,
                    "sampleCollisionClear": true,
                    "connectorBlockerId": String(blocker.get("id", "")),
                    "connectorBlockerSourcePartId": String(blocker.get("sourcePartId", ""))
                }
    if bool(best.get("resolved", false)):
        return best
    if not nearest_blocked.is_empty():
        nearest_blocked["resolved"] = false
        nearest_blocked["reason"] = "probe_sample_connector_blocked"
        return nearest_blocked
    return best


func _source_support_adjacency(samples_by_support: Dictionary, snapshot: Dictionary) -> Dictionary:
    var adjacency := {}
    for support_id_value in samples_by_support.keys():
        adjacency[String(support_id_value)] = []
    for link in cached_building_vertical_links:
        _append_source_support_edge(adjacency, String(link.get("startSupportId", "")), String(link.get("endSupportId", "")))
    for link in cached_building_interior_passage_links:
        _append_source_support_edge(adjacency, String(link.get("firstSupportId", "")), String(link.get("secondSupportId", "")))
    _append_adjacent_source_support_edges(adjacency, samples_by_support, snapshot)
    return adjacency


func _source_sample_adjacency(samples_by_support: Dictionary, snapshot: Dictionary) -> Dictionary:
    var adjacency := {}
    for support_id_value in samples_by_support.keys():
        var support_id := String(support_id_value)
        var samples: Dictionary = samples_by_support.get(support_id_value, {}) as Dictionary
        for cell_value in samples.keys():
            if not (cell_value is Vector2i):
                continue
            var cell: Vector2i = cell_value
            var node := _source_sample_node_key(support_id, cell)
            adjacency[node] = []
            for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
                var neighbor_cell: Vector2i = cell + (offset as Vector2i)
                if samples.has(neighbor_cell):
                    _append_source_support_edge(adjacency, node, _source_sample_node_key(support_id, neighbor_cell))
    _append_adjacent_source_sample_edges(adjacency, samples_by_support, snapshot)
    for link in cached_building_vertical_links:
        _append_declared_source_sample_link(adjacency, samples_by_support, snapshot, link, "startSupportId", "endSupportId")
    for link in cached_building_interior_passage_links:
        _append_declared_source_sample_link(adjacency, samples_by_support, snapshot, link, "firstSupportId", "secondSupportId")
    return adjacency


func _append_adjacent_source_sample_edges(adjacency: Dictionary, samples_by_support: Dictionary, snapshot: Dictionary) -> void:
    var entries_by_cell := {}
    for support_id_value in samples_by_support.keys():
        var support_id := String(support_id_value)
        var samples: Dictionary = samples_by_support.get(support_id_value, {}) as Dictionary
        for cell_value in samples.keys():
            if not (cell_value is Vector2i):
                continue
            var cell: Vector2i = cell_value
            if not entries_by_cell.has(cell):
                entries_by_cell[cell] = []
            (entries_by_cell[cell] as Array).append({"supportId": support_id, "cell": cell, "position": samples[cell]})
    var cells: Array = entries_by_cell.keys()
    cells.sort_custom(func(left: Vector2i, right: Vector2i) -> bool:
        return left.x < right.x if left.y == right.y else left.y < right.y
    )
    for first_cell_value in cells:
        var first_cell: Vector2i = first_cell_value as Vector2i
        for first_entry_value in entries_by_cell.get(first_cell, []) as Array:
            var first_entry: Dictionary = first_entry_value as Dictionary
            var first_id := String(first_entry.get("supportId", ""))
            var first_position: Vector3 = first_entry.get("position", Vector3.INF) as Vector3
            var first_support := _building_support_by_id(first_id)
            for offset in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN]:
                var second_cell: Vector2i = first_cell + (offset as Vector2i)
                for second_entry_value in entries_by_cell.get(second_cell, []) as Array:
                    var second_entry: Dictionary = second_entry_value as Dictionary
                    var second_id := String(second_entry.get("supportId", ""))
                    if first_id == second_id:
                        continue
                    var first_node := _source_sample_node_key(first_id, first_cell)
                    var second_node := _source_sample_node_key(second_id, second_cell)
                    if first_node >= second_node and offset == Vector2i.ZERO:
                        continue
                    var second_position: Vector3 = second_entry.get("position", Vector3.INF) as Vector3
                    if absf(first_position.y - second_position.y) > NpcConstantsScript.DEFAULT_NPC_STEP_UP:
                        continue
                    if not _building_navigation_link_blocker(snapshot, first_support, first_position, second_position, NpcConstantsScript.DEFAULT_NPC_RADIUS).is_empty():
                        continue
                    _append_source_support_edge(adjacency, first_node, second_node)


func _append_declared_source_sample_link(adjacency: Dictionary, samples_by_support: Dictionary, snapshot: Dictionary, link: Dictionary, first_key: String, second_key: String) -> void:
    var resolution := _resolve_declared_source_sample_link(samples_by_support, snapshot, link, first_key, second_key)
    if not bool(resolution.get("resolved", false)):
        return
    _append_source_support_edge(adjacency, String(resolution.get("firstNode", "")), String(resolution.get("secondNode", "")))


func _resolve_declared_source_sample_link(samples_by_support: Dictionary, snapshot: Dictionary, link: Dictionary, first_key: String, second_key: String) -> Dictionary:
    var first_id := String(link.get(first_key, ""))
    var second_id := String(link.get(second_key, ""))
    if first_id.is_empty() or second_id.is_empty() or not samples_by_support.has(first_id) or not samples_by_support.has(second_id):
        return {"resolved": false, "reason": "declared_link_support_unsampled", "firstSupportId": first_id, "secondSupportId": second_id}
    var first_position: Vector3 = link.get("start", Vector3.INF) as Vector3
    var second_position: Vector3 = link.get("end", Vector3.INF) as Vector3
    if not first_position.is_finite() or not second_position.is_finite():
        return {"resolved": false, "reason": "declared_link_endpoint_missing", "firstSupportId": first_id, "secondSupportId": second_id}
    var kind := String(link.get("kind", ""))
    var maximum_drift := BUILDING_STAIR_LINK_MAX_ENDPOINT_DRIFT if kind == "stair_ramp" else BUILDING_NAVIGATION_LINK_MAX_ENDPOINT_DRIFT
    var first_tile_key := _building_navigation_link_endpoint_tile_key(link, "start", first_position)
    var second_tile_key := _building_navigation_link_endpoint_tile_key(link, "end", second_position)
    var transition_axis := second_position - first_position
    var first_resolution := _resolve_building_navigation_link_endpoint(snapshot, first_id, first_position, first_tile_key, transition_axis if kind == "stair_ramp" else Vector3.ZERO)
    var second_resolution := _resolve_building_navigation_link_endpoint(snapshot, second_id, second_position, second_tile_key, transition_axis if kind == "stair_ramp" else Vector3.ZERO)
    if not bool(first_resolution.get("resolved", false)) or not bool(second_resolution.get("resolved", false)):
        return {"resolved": false, "reason": "declared_link_endpoint_unresolved", "firstSupportId": first_id, "secondSupportId": second_id, "start": first_position, "end": second_position, "maximumDrift": maximum_drift, "firstResolution": first_resolution, "secondResolution": second_resolution}
    if kind == "interior_passage":
        var first_support := _building_support_by_id(first_id)
        var resolved_first: Vector3 = first_resolution.get("position", Vector3.INF) as Vector3
        var resolved_second: Vector3 = second_resolution.get("position", Vector3.INF) as Vector3
        var blocker := _building_navigation_link_blocker(snapshot, first_support, resolved_first, resolved_second)
        if not blocker.is_empty():
            return {"resolved": false, "reason": "declared_link_collision_blocked", "firstSupportId": first_id, "secondSupportId": second_id, "start": first_position, "end": second_position, "maximumDrift": maximum_drift, "firstResolution": first_resolution, "secondResolution": second_resolution, "blocker": blocker}
    var first_cell: Vector2i = first_resolution.get("cell", INVALID_CELL) as Vector2i
    var second_cell: Vector2i = second_resolution.get("cell", INVALID_CELL) as Vector2i
    return {"resolved": true, "firstSupportId": first_id, "secondSupportId": second_id, "firstNode": _source_sample_node_key(first_id, first_cell), "secondNode": _source_sample_node_key(second_id, second_cell), "authoredStart": first_position, "authoredEnd": second_position, "firstResolution": first_resolution, "secondResolution": second_resolution, "maximumDiagnosticDrift": maximum_drift, "firstDrift": float(first_resolution.get("distance", INF)), "secondDrift": float(second_resolution.get("distance", INF))}


func _source_declared_sample_link_diagnostics(samples_by_support: Dictionary, snapshot: Dictionary, component: Dictionary) -> Array[Dictionary]:
    var diagnostics: Array[Dictionary] = []
    for link_group in [
        {"links": cached_building_vertical_links, "firstKey": "startSupportId", "secondKey": "endSupportId"},
        {"links": cached_building_interior_passage_links, "firstKey": "firstSupportId", "secondKey": "secondSupportId"}
    ]:
        for link_value in link_group.get("links", []) as Array:
            if not (link_value is Dictionary):
                continue
            var link: Dictionary = link_value
            var first_key := String(link_group.get("firstKey", ""))
            var second_key := String(link_group.get("secondKey", ""))
            if not component.has(String(link.get(first_key, ""))) and not component.has(String(link.get(second_key, ""))):
                continue
            var resolution := _resolve_declared_source_sample_link(samples_by_support, snapshot, link, first_key, second_key)
            resolution["id"] = String(link.get("id", ""))
            resolution["kind"] = String(link.get("kind", ""))
            diagnostics.append(resolution)
    return diagnostics


func _source_sample_node_key(support_id: String, cell: Vector2i) -> String:
    return "%s|%d,%d" % [support_id, cell.x, cell.y]


func _append_adjacent_source_support_edges(adjacency: Dictionary, samples_by_support: Dictionary, snapshot: Dictionary) -> void:
    var support_ids: Array = samples_by_support.keys()
    support_ids.sort()
    for first_index in range(support_ids.size()):
        var first_id := String(support_ids[first_index])
        var first_samples: Dictionary = samples_by_support.get(first_id, {}) as Dictionary
        for second_index in range(first_index + 1, support_ids.size()):
            var second_id := String(support_ids[second_index])
            var second_samples: Dictionary = samples_by_support.get(second_id, {}) as Dictionary
            var first_support := _building_support_by_id(first_id)
            if _source_support_samples_connect(first_samples, second_samples, first_support, snapshot):
                _append_source_support_edge(adjacency, first_id, second_id)


func _source_support_samples_connect(first_samples: Dictionary, second_samples: Dictionary, first_support: Dictionary, snapshot: Dictionary) -> bool:
    for first_cell_value in first_samples.keys():
        if not (first_cell_value is Vector2i):
            continue
        var first_cell: Vector2i = first_cell_value
        var first_position: Vector3 = first_samples[first_cell] as Vector3
        for offset in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
            var second_cell: Vector2i = first_cell + (offset as Vector2i)
            if not second_samples.has(second_cell):
                continue
            var second_position: Vector3 = second_samples[second_cell] as Vector3
            if absf(first_position.y - second_position.y) <= NpcConstantsScript.DEFAULT_NPC_STEP_UP \
                and _building_navigation_link_blocker(snapshot, first_support, first_position, second_position, NpcConstantsScript.DEFAULT_NPC_RADIUS).is_empty():
                return true
    return false


func _append_source_support_edge(adjacency: Dictionary, first: String, second: String) -> void:
    if first.is_empty() or second.is_empty() or first == second or not adjacency.has(first) or not adjacency.has(second):
        return
    if not (adjacency[first] as Array).has(second):
        (adjacency[first] as Array).append(second)
    if not (adjacency[second] as Array).has(first):
        (adjacency[second] as Array).append(first)


func _source_component_link_diagnostics(component: Dictionary, links: Array[Dictionary], first_key: String, second_key: String) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for link in links:
        var first := String(link.get(first_key, ""))
        var second := String(link.get(second_key, ""))
        if component.has(first) or component.has(second):
            result.append({"id": String(link.get("id", "")), "firstSupportId": first, "secondSupportId": second})
            if result.size() >= 12:
                break
    return result


func _source_residence_vertical_link_diagnostics(support: Dictionary) -> Array[Dictionary]:
    var source_part_id := String(support.get("sourcePartId", ""))
    var separator := source_part_id.find("__")
    var prefix := source_part_id.left(separator + 2) if separator >= 0 else ""
    var result: Array[Dictionary] = []
    for link in cached_building_vertical_links:
        if not prefix.is_empty() and not String(link.get("sourcePartId", "")).begins_with(prefix):
            continue
        result.append({
            "id": String(link.get("id", "")),
            "sourcePartId": String(link.get("sourcePartId", "")),
            "start": link.get("start", Vector3.ZERO),
            "end": link.get("end", Vector3.ZERO),
            "startSupportId": String(link.get("startSupportId", "")),
            "endSupportId": String(link.get("endSupportId", ""))
        })
        if result.size() >= 12:
            break
    return result


func _nearest_source_support_sample(navigable_cells: Dictionary, position: Vector3, snap_distance: float) -> Dictionary:
    if not position.is_finite():
        return {"resolved": false, "reason": "invalid_probe_position"}
    var nearest_cell := INVALID_CELL
    var nearest_position := Vector3.INF
    var nearest_distance := INF
    for cell_value in navigable_cells.keys():
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var candidate: Vector3 = navigable_cells[cell] as Vector3
        var distance := candidate.distance_to(position)
        if distance < nearest_distance:
            nearest_cell = cell
            nearest_position = candidate
            nearest_distance = distance
    if nearest_cell == INVALID_CELL or nearest_distance > snap_distance:
        return {"resolved": false, "reason": "no_sample_within_snap_distance", "distance": nearest_distance}
    return {
        "resolved": true,
        "cell": nearest_cell,
        "position": nearest_position,
        "distance": nearest_distance
    }


func _diagnostic_snapshot_without_furnishings(snapshot: Dictionary) -> Dictionary:
    var records: Array = snapshot.get("staticCollision", []) if snapshot.get("staticCollision", []) is Array else []
    var filtered: Array = []
    for record_value in records:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        if String(record.get("id", "")).begins_with("furnishing:"):
            continue
        filtered.append(record)
    var broad_records: Array = []
    var result := snapshot.duplicate(false)
    result["staticCollision"] = filtered
    result["staticCollisionByCell"] = _collision_index_for_records(filtered, broad_records)
    result["staticCollisionBroad"] = broad_records
    return result


func _building_support_navigation_sample_data(support: Dictionary, snapshot: Dictionary, tile_key: String) -> Dictionary:
    var job := _new_building_support_navigation_sample_job(support, snapshot, tile_key)
    while not bool(job.get("done", false)):
        _advance_building_support_navigation_sample_job(job)
    return job.get("result", {}) as Dictionary


func _new_building_support_navigation_sample_job(support: Dictionary, snapshot: Dictionary, tile_key: String) -> Dictionary:
    var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
    if polygon.size() < 3:
        return {"done": true, "result": {"navigableCells": {}, "blockedByCell": {}}}
    var tile := _parse_tile_key(tile_key)
    var tile_min_x := (float(tile.x * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_max_x := (float((tile.x + 1) * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_min_z := (float(tile.y * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_max_z := (float((tile.y + 1) * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var minimum := Vector2(INF, INF)
    var maximum := Vector2(-INF, -INF)
    for point_value in polygon:
        if point_value is Vector3:
            var point: Vector3 = point_value
            minimum.x = minf(minimum.x, point.x)
            minimum.y = minf(minimum.y, point.z)
            maximum.x = maxf(maximum.x, point.x)
            maximum.y = maxf(maximum.y, point.z)
    minimum.x = maxf(minimum.x, tile_min_x)
    minimum.y = maxf(minimum.y, tile_min_z)
    maximum.x = minf(maximum.x, tile_max_x)
    maximum.y = minf(maximum.y, tile_max_z)
    if minimum.x >= maximum.x or minimum.y >= maximum.y:
        return {"done": true, "result": {"navigableCells": {}, "blockedByCell": {}}}
    var first_x := ceili((minimum.x - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var last_x := floori((maximum.x - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var first_z := ceili((minimum.y - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var last_z := floori((maximum.y - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    return {
        "done": false,
        "support": support,
        "snapshot": snapshot,
        "tileKey": tile_key,
        "firstX": first_x,
        "lastX": last_x,
        "lastZ": last_z,
        "x": first_x,
        "z": first_z,
        "navigableCells": {},
        "blockedByCell": {}
    }


func _advance_building_support_navigation_sample_job(job: Dictionary) -> void:
    if bool(job.get("done", false)):
        return
    var x := int(job.get("x", 0))
    var z := int(job.get("z", 0))
    var support: Dictionary = job.get("support", {}) as Dictionary
    var sample_cell := Vector2i(x, z)
    var minimum_corner := Vector2(float(x) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, float(z) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var maximum_corner := minimum_corner + Vector2(BUILDING_SUPPORT_NAV_SAMPLE_STEP, BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var position := Vector3((float(x) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, 0.0, (float(z) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    if _point_within_support_xz(position, support):
        position.y = _support_surface_y(support, position) + 0.04
        if _building_support_owns_navigation_sample(support, position, String(job.get("tileKey", ""))):
            var blocker := _building_support_navigation_cell_blocker(job.get("snapshot", {}) as Dictionary, support, position, minimum_corner, maximum_corner)
            if blocker.is_empty():
                (job.get("navigableCells", {}) as Dictionary)[sample_cell] = position
            else:
                (job.get("blockedByCell", {}) as Dictionary)[sample_cell] = blocker
    x += 1
    if x > int(job.get("lastX", x)):
        x = int(job.get("firstX", x))
        z += 1
    job["x"] = x
    job["z"] = z
    if z > int(job.get("lastZ", z)):
        job["done"] = true
        job["result"] = {"navigableCells": job.get("navigableCells", {}), "blockedByCell": job.get("blockedByCell", {})}


func _building_support_owns_navigation_sample(support: Dictionary, position: Vector3, tile_key: String) -> bool:
    var support_id := String(support.get("id", ""))
    if support_id.is_empty():
        return true
    var support_y := _support_surface_y(support, position)
    var owner_id := support_id
    var owner_y := support_y
    for candidate_value in building_supports_for_tile(tile_key):
        if not (candidate_value is Dictionary):
            continue
        var candidate: Dictionary = candidate_value
        if not _point_within_support_xz(position, candidate):
            continue
        var candidate_y := _support_surface_y(candidate, position)
        if candidate_y < support_y - BUILDING_SUPPORT_STACK_EPSILON:
            continue
        if candidate_y > support_y + BUILDING_SUPPORT_STACK_MAX_SEPARATION:
            continue
        var candidate_id := String(candidate.get("id", ""))
        if candidate_y > owner_y + BUILDING_SUPPORT_STACK_EPSILON or (absf(candidate_y - owner_y) <= BUILDING_SUPPORT_STACK_EPSILON and candidate_id < owner_id):
            owner_id = candidate_id
            owner_y = candidate_y
    return owner_id == support_id


func _navmesh_surface_from_building_support(support: Dictionary, span_index: int, polygon: Array = []) -> Dictionary:
    var cell: Vector3i = support.get("cell", Vector3i.ZERO) if support.get("cell", Vector3i.ZERO) is Vector3i else Vector3i.ZERO
    var position: Vector3 = support.get("worldPosition", Vector3.ZERO) if support.get("worldPosition", Vector3.ZERO) is Vector3 else Vector3.ZERO
    if polygon.is_empty():
        polygon = support.get("polygon", []) if support.get("polygon", []) is Array else []
    if polygon.size() < 3:
        return {}
    return {
        "id": String(support.get("id", "")),
        "cell": cell,
        "spanIndex": span_index,
        "worldPosition": position,
        "floorNormal": support.get("floorNormal", Vector3.UP),
        "headroom": float(support.get("headroom", 3.0)),
        "lateralClearance": float(support.get("lateralClearance", 1.0)),
        "blocked": false,
        "semanticRegionIds": [],
        "traversalTags": support.get("traversalTags", ["building", "support"]),
        "polygon": polygon,
        "sourcePartId": String(support.get("sourcePartId", "")),
        "sourceCollisionPartId": String(support.get("sourceCollisionPartId", "")),
        "support": true
    }


func _merged_building_support_navmesh_surfaces(support: Dictionary, cells: Dictionary, span_index: int) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var columns_by_row := {}
    for key_value in cells.keys():
        if not (key_value is Vector2i):
            continue
        var cell: Vector2i = key_value
        if not columns_by_row.has(cell.y):
            columns_by_row[cell.y] = []
        (columns_by_row[cell.y] as Array).append(cell.x)
    var row_runs := {}
    var rows: Array = columns_by_row.keys()
    rows.sort()
    for row_value in rows:
        var row := int(row_value)
        var columns: Array = columns_by_row.get(row, [])
        columns.sort()
        var runs: Array[Vector2i] = []
        var run_start := 0
        var previous_column := 0
        var has_run := false
        for column_value in columns:
            var column := int(column_value)
            if not has_run:
                run_start = column
                previous_column = column
                has_run = true
                continue
            if column == previous_column + 1:
                previous_column = column
                continue
            runs.append(Vector2i(run_start, previous_column + 1))
            run_start = column
            previous_column = column
        if has_run:
            runs.append(Vector2i(run_start, previous_column + 1))
        row_runs[row] = runs
    var row_breakpoints := {}
    for row_value in rows:
        var row := int(row_value)
        var breakpoints := {}
        for run_value in row_runs.get(row, []):
            if not (run_value is Vector2i):
                continue
            var run: Vector2i = run_value
            breakpoints[run.x] = true
            breakpoints[run.y] = true
        row_breakpoints[row] = breakpoints
    for _pass in range(maxi(1, rows.size())):
        var changed := false
        for row_value in rows:
            var row := int(row_value)
            var current_runs: Array = row_runs.get(row, [])
            var current_breakpoints: Dictionary = row_breakpoints.get(row, {}) as Dictionary
            for neighbor_row in [row - 1, row + 1]:
                var neighbor_breakpoints: Dictionary = row_breakpoints.get(neighbor_row, {}) as Dictionary
                for boundary_value in neighbor_breakpoints.keys():
                    var boundary := int(boundary_value)
                    if not _building_support_row_contains_boundary(current_runs, boundary) or current_breakpoints.has(boundary):
                        continue
                    current_breakpoints[boundary] = true
                    changed = true
            row_breakpoints[row] = current_breakpoints
        if not changed:
            break
    var next_span := span_index
    for row_value in rows:
        var row := int(row_value)
        var current_runs: Array = row_runs.get(row, [])
        var breakpoints: Dictionary = row_breakpoints.get(row, {}) as Dictionary
        var sorted_breakpoints: Array = breakpoints.keys()
        sorted_breakpoints.sort()
        for breakpoint_index in range(maxi(0, sorted_breakpoints.size() - 1)):
            var start_x := int(sorted_breakpoints[breakpoint_index])
            var end_x := int(sorted_breakpoints[breakpoint_index + 1])
            if end_x <= start_x or not cells.has(Vector2i(start_x, row)):
                continue
            var min_x := float(start_x) * BUILDING_SUPPORT_NAV_SAMPLE_STEP
            var max_x := float(end_x) * BUILDING_SUPPORT_NAV_SAMPLE_STEP
            var min_z := float(row) * BUILDING_SUPPORT_NAV_SAMPLE_STEP
            var max_z := float(row + 1) * BUILDING_SUPPORT_NAV_SAMPLE_STEP
            var polygon: Array[Vector3] = []
            for point in [Vector3(min_x, 0.0, min_z), Vector3(min_x, 0.0, max_z), Vector3(max_x, 0.0, max_z), Vector3(max_x, 0.0, min_z)]:
                point.y = _support_surface_y(support, point) + 0.04
                polygon.append(point)
            var center := Vector3((min_x + max_x) * 0.5, 0.0, (min_z + max_z) * 0.5)
            center.y = _support_surface_y(support, center) + 0.04
            var surface := _navmesh_surface_from_building_support(support, next_span, polygon)
            surface["cell"] = Vector3i(roundi(center.x / CELL), floori(center.y / CELL), roundi(center.z / CELL))
            surface["worldPosition"] = center
            surface["id"] = "%s:navmesh:%d" % [String(support.get("id", "")), next_span]
            result.append(surface)
            next_span += 1
    return result


func _building_support_row_contains_boundary(runs: Array, boundary: int) -> bool:
    for run_value in runs:
        if run_value is Vector2i:
            var run: Vector2i = run_value
            if boundary >= run.x and boundary <= run.y:
                return true
    return false


func _building_support_navigation_blocked(snapshot: Dictionary, support: Dictionary, position: Vector3) -> bool:
    return not _building_support_navigation_blocker(snapshot, support, position).is_empty()


func _building_support_navigation_blocker(snapshot: Dictionary, support: Dictionary, position: Vector3) -> Dictionary:
    var footprint := Vector2(position.x, position.z)
    return _building_support_navigation_blocker_for_footprint(snapshot, support, position.y, footprint, footprint)


func _building_support_navigation_cell_blocker(snapshot: Dictionary, support: Dictionary, position: Vector3, minimum_corner: Vector2, maximum_corner: Vector2) -> Dictionary:
    return _building_support_navigation_blocker_for_footprint(snapshot, support, position.y, minimum_corner, maximum_corner)


func _building_support_navigation_blocker_for_footprint(snapshot: Dictionary, support: Dictionary, sample_y: float, minimum_corner: Vector2, maximum_corner: Vector2, clearance := BUILDING_SUPPORT_NAV_CLEARANCE, additional_allowed_source_parts := []) -> Dictionary:
    var minimum_cell := world_cell(Vector3(minimum_corner.x, sample_y, minimum_corner.y))
    var maximum_cell := world_cell(Vector3(maximum_corner.x, sample_y, maximum_corner.y))
    var records := _transition_collision_records(snapshot, "staticCollisionByCell", minimum_cell, maximum_cell)
    var support_part_id := String(support.get("sourceCollisionPartId", support.get("sourcePartId", "")))
    var allowed_source_parts := {support_part_id: true}
    if additional_allowed_source_parts is Array:
        for source_part_value in additional_allowed_source_parts:
            var source_part_id := String(source_part_value)
            if not source_part_id.is_empty():
                allowed_source_parts[source_part_id] = true
    for record_value in records:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        if allowed_source_parts.has(String(record.get("sourcePartId", ""))):
            continue
        if float(record.get("maxY", -INF)) < sample_y + 0.02 or float(record.get("minY", INF)) > sample_y + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT:
            continue
        if maximum_corner.x <= float(record.get("minX", INF)) - clearance + 0.0001 \
            or minimum_corner.x >= float(record.get("maxX", -INF)) + clearance - 0.0001 \
            or maximum_corner.y <= float(record.get("minZ", INF)) - clearance + 0.0001 \
            or minimum_corner.y >= float(record.get("maxZ", -INF)) + clearance - 0.0001:
            continue
        var footprint: Array = record.get("footprint", []) if record.get("footprint", []) is Array else []
        if not footprint.is_empty() and not _footprint_intersects_segment(minimum_corner, maximum_corner, footprint, clearance):
            continue
        return record
    return {}


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
            _index_collision_record(cached_static_collision_by_cell, record, cached_static_collision_broad)
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
        Vector3(-half.x, -half.y, -half.z), Vector3(-half.x, -half.y, half.z),
        Vector3(-half.x, half.y, -half.z), Vector3(-half.x, half.y, half.z),
        Vector3(half.x, -half.y, -half.z), Vector3(half.x, -half.y, half.z),
        Vector3(half.x, half.y, -half.z), Vector3(half.x, half.y, half.z)
    ]
    var min_x := INF
    var max_x := -INF
    var min_y := INF
    var max_y := -INF
    var min_z := INF
    var max_z := -INF
    for corner in corners:
        var world_corner: Vector3 = transform * corner
        min_x = minf(min_x, world_corner.x)
        max_x = maxf(max_x, world_corner.x)
        min_y = minf(min_y, world_corner.y)
        max_y = maxf(max_y, world_corner.y)
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
        "minY": min_y,
        "maxY": max_y,
        "minZ": min_z,
        "maxZ": max_z,
        "sourcePartId": String(collider.get_meta("building_part_id", body.get_meta("building_part_id", ""))),
        "sourcePartKind": String(collider.get_meta("building_part_kind", body.get_meta("building_part_kind", ""))),
        "inflation": TRANSITION_COLLISION_INFLATION
    }

func _fallback_collision_record(body: Node3D, cell: Vector2i, block_type: String, is_door: bool) -> Dictionary:
    var radius := PROP_COLLISION_RADIUS if block_type == "prop" else CELL * 0.48
    var center := body.global_position
    var parent := body.get_parent()
    return {
        "id": "%s:%s:%s:fallback" % ["door" if is_door else "static", cell_key(cell), String(body.name)],
        "cell": cell,
        "blockType": block_type,
        "node": body,
        "nodeName": String(body.name),
        "parentName": String(parent.name) if parent != null else "",
        "propId": String(body.get_meta("prop_id", "")),
        "material": String(body.get_meta("material", "")),
        "drop": String(body.get_meta("drop", "")),
        "obstacleClass": String(body.get_meta("navigation_obstacle_class", "")),
        "isDoor": is_door,
        "minX": center.x - radius,
        "maxX": center.x + radius,
        "minY": center.y - radius,
        "maxY": center.y + radius,
        "minZ": center.z - radius,
        "maxZ": center.z + radius,
        "inflation": TRANSITION_COLLISION_INFLATION
    }

func _index_collision_record(index: Dictionary, record: Dictionary, broad_records: Array = [], max_index_cells := TRANSITION_RECORD_INDEX_MAX_CELLS) -> void:
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    var min_x := floori((float(record.get("minX", 0.0)) - inflation) / CELL) - TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var max_x := floori((float(record.get("maxX", 0.0)) + inflation) / CELL) + TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var min_z := floori((float(record.get("minZ", 0.0)) - inflation) / CELL) - TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var max_z := floori((float(record.get("maxZ", 0.0)) + inflation) / CELL) + TRANSITION_RECORD_INDEX_MARGIN_CELLS
    var cell_count := (max_x - min_x + 1) * (max_z - min_z + 1)
    if max_index_cells > 0 and cell_count > max_index_cells:
        broad_records.append(record)
        return
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
            cached_static_collision_broad.erase(record)
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
        cached_static_collision_broad = []
        cached_static_collision_by_cell = _collision_index_for_records(cached_static_collision_records, cached_static_collision_broad)
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
    if String(prop.get_meta("navigation_obstacle_class", "")) == "dynamic_actor":
        return false
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
            if flat_distance <= PROP_NAV_CLEARANCE_RADIUS:
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
    if main != null and main.get("wildlife_nodes") is Array:
        for wildlife_value in main.get("wildlife_nodes") as Array:
            if not (wildlife_value is Node3D):
                continue
            var wildlife := wildlife_value as Node3D
            if dynamic_actor_blocks_navigation(wildlife):
                dynamic[world_cell(wildlife.global_position)] = wildlife
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


func route_waypoint_for_cell(cell: Vector2i, reference_position: Vector3 = Vector3.INF) -> Vector3:
    var position := Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
    if reference_position.is_finite():
        var source_support := building_support_for_position(reference_position, CELL * 0.92)
        if not source_support.is_empty() and _point_within_support_xz(position, source_support):
            position.y = _support_surface_y(source_support, position) + 0.04
            return position
    return cell_position(cell)


func route_requires_layered_navigation(start: Vector3, target: Vector3) -> bool:
    return not building_support_for_position(start, CELL * 0.92).is_empty() \
        or not building_support_for_position(target, CELL * 0.92).is_empty()


func support_surface_y_for_position(support: Dictionary, position: Vector3) -> float:
    return _support_surface_y(support, position)


func navigation_query_position(position: Vector3) -> Vector3:
    # A point already placed on a published building support retains that layer.
    # Ground callers keep the old terrain projection, so this does not alter
    # ordinary terrain routing or silently promote a point to a nearby floor.
    var support := building_support_for_position(position, CELL * 0.82)
    if not support.is_empty():
        var supported := position
        supported.y = _support_surface_y(support, position) + 0.04
        return supported
    var cell := world_cell(position)
    var terrain_position := cell_position(cell)
    if absf(position.y - terrain_position.y) <= CELL * 0.72:
        return terrain_position
    return position


func position_is_static_standable_goal(entry: Dictionary, position: Vector3, allow_outside := false, moving_home := false) -> bool:
    var support := building_support_for_position(position, CELL * 0.82)
    if not support.is_empty():
        var foot := position
        foot.y = _support_surface_y(support, position) + 0.04
        return static_collision_blocker_at_position(cached_static_tile_snapshot(allow_outside, moving_home), foot).is_empty()
    return cell_is_static_standable_goal(entry, world_cell(position), allow_outside, moving_home)

func validate_surface_transition_action(snapshot: Dictionary, action: Dictionary) -> Dictionary:
    var positions := {
        "entry": {"position": action.get("entryPosition", Vector3.INF), "supportId": String(action.get("entrySupportId", ""))},
        "staging": {"position": action.get("stagingPosition", Vector3.INF), "supportId": String(action.get("entrySupportId", ""))},
        "queue": {"position": action.get("queuePosition", Vector3.INF), "supportId": String(action.get("entrySupportId", ""))},
        "exit": {"position": action.get("exitPosition", Vector3.INF), "supportId": String(action.get("exitSupportId", ""))},
        "clearance": {"position": action.get("clearancePosition", Vector3.INF), "supportId": String(action.get("exitSupportId", ""))}
    }
    var certificates := {}
    for phase_value in positions.keys():
        var phase := String(phase_value)
        var position_spec: Dictionary = positions.get(phase_value, {}) as Dictionary
        var position: Vector3 = position_spec.get("position", Vector3.INF) as Vector3
        var expected_support_id := String(position_spec.get("supportId", ""))
        var certificate := _surface_transition_position_certificate(snapshot, position, expected_support_id)
        if not bool(certificate.get("ok", false)):
            certificate["reason"] = "surface_transition_%s_%s" % [phase, String(certificate.get("reason", "uncertified"))]
            certificate["phase"] = phase
            certificate["linkId"] = String(action.get("linkId", ""))
            return certificate
        certificates[phase] = certificate
    var sweep_order := ["queue", "staging", "entry", "exit", "clearance"]
    var sweep_certificates: Array[Dictionary] = []
    for sweep_index in range(sweep_order.size() - 1):
        var from_phase := String(sweep_order[sweep_index])
        var to_phase := String(sweep_order[sweep_index + 1])
        var from_certificate: Dictionary = certificates.get(from_phase, {}) as Dictionary
        var to_certificate: Dictionary = certificates.get(to_phase, {}) as Dictionary
        var sweep_certificate := _surface_transition_capsule_sweep_certificate(snapshot, from_certificate, to_certificate)
        if not bool(sweep_certificate.get("ok", false)):
            sweep_certificate["reason"] = "surface_transition_%s_to_%s_%s" % [from_phase, to_phase, String(sweep_certificate.get("reason", "uncertified"))]
            sweep_certificate["fromPhase"] = from_phase
            sweep_certificate["toPhase"] = to_phase
            sweep_certificate["linkId"] = String(action.get("linkId", ""))
            return sweep_certificate
        sweep_certificate["fromPhase"] = from_phase
        sweep_certificate["toPhase"] = to_phase
        sweep_certificates.append(sweep_certificate)
    return {
        "ok": true,
        "reason": "",
        "collisionBacked": true,
        "standable": true,
        "linkId": String(action.get("linkId", "")),
        "direction": String(action.get("direction", "")),
        "positions": certificates,
        "sweeps": sweep_certificates,
        "participatingTiles": snapshot.get("participatingTiles", []),
        "staticSnapshotRevision": int(snapshot.get("staticSnapshotRevision", static_snapshot_revision)),
        "doorStateRevision": int(snapshot.get("doorStateRevision", door_state_revision))
    }

func surface_transition_certificate_matches_action(action: Dictionary, certificate: Dictionary) -> bool:
    if not bool(certificate.get("ok", false)) or String(certificate.get("linkId", "")) != String(action.get("linkId", "")) \
        or String(certificate.get("direction", "")) != String(action.get("direction", "")):
        return false
    var positions: Dictionary = certificate.get("positions", {}) if certificate.get("positions", {}) is Dictionary else {}
    var phase_contracts := {
        "queue": ["queuePosition", "entrySupportId"],
        "staging": ["stagingPosition", "entrySupportId"],
        "entry": ["entryPosition", "entrySupportId"],
        "exit": ["exitPosition", "exitSupportId"],
        "clearance": ["clearancePosition", "exitSupportId"]
    }
    for phase_value in phase_contracts.keys():
        var phase := String(phase_value)
        var contract: Array = phase_contracts[phase]
        var certified: Dictionary = positions.get(phase, {}) if positions.get(phase, {}) is Dictionary else {}
        if certified.get("position", Vector3.INF) != action.get(String(contract[0]), Vector3.INF) \
            or String(certified.get("expectedSupportId", "")) != String(action.get(String(contract[1]), "")):
            return false
    return true

func _surface_transition_capsule_sweep_certificate(snapshot: Dictionary, from_certificate: Dictionary, to_certificate: Dictionary) -> Dictionary:
    var from_position: Vector3 = from_certificate.get("position", Vector3.INF) as Vector3
    var to_position: Vector3 = to_certificate.get("position", Vector3.INF) as Vector3
    if not from_position.is_finite() or not to_position.is_finite():
        return {"ok": false, "reason": "missing_sweep_endpoint"}
    var allowed_support_parts := {}
    for certificate in [from_certificate, to_certificate]:
        var source_part_id := String((certificate as Dictionary).get("sourcePartId", ""))
        if not source_part_id.is_empty():
            allowed_support_parts[source_part_id] = true
    var from_cell := world_cell(from_position)
    var to_cell := world_cell(to_position)
    var minimum_y := minf(from_position.y, to_position.y) + 0.02
    var maximum_y := maxf(from_position.y, to_position.y) + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
    for index_key in ["staticCollisionByCell", "doorCollisionByCell"]:
        for record_value in _transition_collision_records(snapshot, index_key, from_cell, to_cell):
            if not (record_value is Dictionary):
                continue
            var record: Dictionary = record_value
            if allowed_support_parts.has(String(record.get("sourcePartId", ""))):
                continue
            if float(record.get("maxY", -INF)) < minimum_y or float(record.get("minY", INF)) > maximum_y:
                continue
            if _segment_intersects_collision_record_with_inflation(from_position, to_position, record, NpcConstantsScript.DEFAULT_NPC_RADIUS):
                return {"ok": false, "reason": "capsule_sweep_collision", "from": from_position, "to": to_position, "collision": record}
    return {"ok": true, "reason": "", "from": from_position, "to": to_position, "collisionBacked": true}

func _surface_transition_position_certificate(snapshot: Dictionary, position: Vector3, expected_support_id: String) -> Dictionary:
    if not position.is_finite():
        return {"ok": false, "reason": "missing_position", "position": position}
    if expected_support_id.is_empty():
        return {"ok": false, "reason": "missing_expected_support_owner", "position": position}
    var supported_position := position
    var support := building_support_for_position(position, CELL * 0.92)
    var source_part_id := ""
    var support_id := "terrain"
    var expects_terrain := expected_support_id.begins_with("terrain:")
    if expects_terrain and not support.is_empty():
        return {"ok": false, "reason": "wrong_overlapping_support_owner", "position": position, "expectedSupportId": expected_support_id, "actualSupportId": String(support.get("id", ""))}
    if not expects_terrain and (support.is_empty() or String(support.get("id", "")) != expected_support_id):
        return {"ok": false, "reason": "wrong_support_owner", "position": position, "expectedSupportId": expected_support_id, "actualSupportId": String(support.get("id", "")) if not support.is_empty() else ""}
    if not support.is_empty():
        support_id = String(support.get("id", ""))
        source_part_id = String(support.get("sourceCollisionPartId", support.get("sourcePartId", "")))
        supported_position.y = _support_surface_y(support, position) + 0.04
        var footprint_radius := NpcConstantsScript.DEFAULT_NPC_RADIUS
        for offset in [Vector2(footprint_radius, 0.0), Vector2(-footprint_radius, 0.0), Vector2(0.0, footprint_radius), Vector2(0.0, -footprint_radius)]:
            if not _point_within_support_xz(Vector3(position.x + offset.x, position.y, position.z + offset.y), support):
                return {"ok": false, "reason": "unsupported_capsule_footprint", "position": position, "supportId": support_id}
    else:
        var terrain_position := cell_position(world_cell(position))
        if absf(position.y - terrain_position.y) > NpcConstantsScript.DEFAULT_NPC_STEP_UP + 0.04:
            return {"ok": false, "reason": "missing_walkable_support", "position": position}
        supported_position.y = terrain_position.y
        var center_cell := world_cell(position)
        for offset in [Vector2.ZERO, Vector2(NpcConstantsScript.DEFAULT_NPC_RADIUS, 0.0), Vector2(-NpcConstantsScript.DEFAULT_NPC_RADIUS, 0.0), Vector2(0.0, NpcConstantsScript.DEFAULT_NPC_RADIUS), Vector2(0.0, -NpcConstantsScript.DEFAULT_NPC_RADIUS)]:
            var sample_cell := world_cell(Vector3(position.x + offset.x, position.y, position.z + offset.y))
            var terrain_step := terrain_allows_step(center_cell, sample_cell, false)
            if not bool(terrain_step.get("ok", false)) or absf(float(terrain_step.get("height", supported_position.y)) - supported_position.y) > NpcConstantsScript.DEFAULT_NPC_STEP_UP:
                return {"ok": false, "reason": "unsupported_terrain_footprint", "position": position, "sampleCell": sample_cell}
    var collision := _surface_transition_capsule_blocker(snapshot, supported_position, source_part_id)
    if not collision.is_empty():
        return {"ok": false, "reason": "capsule_collision", "position": supported_position, "supportId": support_id, "collision": collision}
    return {"ok": true, "reason": "", "position": supported_position, "supportId": support_id, "expectedSupportId": expected_support_id, "sourcePartId": source_part_id, "collisionBacked": true, "standable": true}

func _surface_transition_capsule_blocker(snapshot: Dictionary, position: Vector3, supporting_source_part_id: String) -> Dictionary:
    var cell := world_cell(position)
    for index_key in ["staticCollisionByCell", "doorCollisionByCell"]:
        for record_value in _transition_collision_records(snapshot, index_key, cell, cell):
            if not (record_value is Dictionary):
                continue
            var record: Dictionary = record_value
            if not supporting_source_part_id.is_empty() and String(record.get("sourcePartId", "")) == supporting_source_part_id:
                continue
            if float(record.get("maxY", -INF)) < position.y + 0.02 or float(record.get("minY", INF)) > position.y + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT:
                continue
            if _point_inside_collision_record_with_inflation(position, record, NpcConstantsScript.DEFAULT_NPC_RADIUS):
                return record
    return {}


func building_support_for_position(position: Vector3, vertical_tolerance := CELL * 0.48) -> Dictionary:
    var best: Dictionary = {}
    var best_distance := INF
    for support in cached_building_supports:
        if not _point_within_support_xz(position, support):
            continue
        var support_y := _support_surface_y(support, position)
        var distance := absf(position.y - support_y)
        if distance > vertical_tolerance or distance >= best_distance:
            continue
        best = support
        best_distance = distance
    return best


func collision_part_is_walkable_building_support(source_part_id: String, position: Vector3, vertical_tolerance := 0.08, horizontal_tolerance := 0.0) -> bool:
    if source_part_id.is_empty():
        return false
    for support_value in cached_building_supports:
        if not (support_value is Dictionary):
            continue
        var support: Dictionary = support_value
        if String(support.get("sourceCollisionPartId", support.get("sourcePartId", ""))) != source_part_id:
            continue
        if not _point_within_or_near_support_xz(position, support, horizontal_tolerance):
            continue
        if absf(position.y - _support_surface_y(support, position) - 0.04) <= vertical_tolerance:
            return true
    return false


func _point_within_support_xz(position: Vector3, support: Dictionary) -> bool:
    var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
    if polygon.size() < 3:
        return false
    var inside := false
    var previous: Vector3 = polygon[polygon.size() - 1] if polygon[polygon.size() - 1] is Vector3 else Vector3.ZERO
    for point_value in polygon:
        if not (point_value is Vector3):
            return false
        var point: Vector3 = point_value
        var crosses := (point.z > position.z) != (previous.z > position.z)
        if crosses:
            var denominator := previous.z - point.z
            if absf(denominator) <= 0.000001:
                previous = point
                continue
            var x_at_z := (previous.x - point.x) * (position.z - point.z) / denominator + point.x
            if position.x < x_at_z:
                inside = not inside
        previous = point
    return inside


func _point_within_or_near_support_xz(position: Vector3, support: Dictionary, horizontal_tolerance := 0.0) -> bool:
    if _point_within_support_xz(position, support):
        return true
    if horizontal_tolerance <= 0.0:
        return false
    var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
    if polygon.size() < 2:
        return false
    var point_2d := Vector2(position.x, position.z)
    var previous: Vector3 = polygon[polygon.size() - 1] if polygon[polygon.size() - 1] is Vector3 else Vector3.ZERO
    for point_value in polygon:
        if not (point_value is Vector3):
            return false
        var point: Vector3 = point_value
        var edge_start := Vector2(previous.x, previous.z)
        var edge_end := Vector2(point.x, point.z)
        var edge := edge_end - edge_start
        var edge_length_squared := edge.length_squared()
        var closest := edge_start
        if edge_length_squared > 0.000001:
            var projection := clampf((point_2d - edge_start).dot(edge) / edge_length_squared, 0.0, 1.0)
            closest = edge_start + edge * projection
        if point_2d.distance_to(closest) <= horizontal_tolerance:
            return true
        previous = point
    return false


func _support_surface_y(support: Dictionary, position: Vector3) -> float:
    var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
    if polygon.size() >= 3 and polygon[0] is Vector3 and polygon[1] is Vector3 and polygon[2] is Vector3:
        var a: Vector3 = polygon[0]
        var b: Vector3 = polygon[1]
        var c: Vector3 = polygon[2]
        var normal := (b - a).cross(c - a)
        if absf(normal.y) > 0.0001:
            return a.y - (normal.x * (position.x - a.x) + normal.z * (position.z - a.z)) / normal.y
    var center: Vector3 = support.get("worldPosition", position) if support.get("worldPosition", position) is Vector3 else position
    return center.y

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

func validate_waypoint_route(entry: Dictionary, snapshot: Dictionary, points: Array, target_cells: Dictionary, ignore_dynamic := true, route_actions := {}) -> Dictionary:
    if points.size() < 2:
        return { "ok": true, "reason": "" }
    if _route_uses_building_supports(points):
        return _validate_layered_building_route(snapshot, points, route_actions)
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


func _route_uses_building_supports(points: Array) -> bool:
    for point_value in points:
        if point_value is Vector3 and not building_support_for_position(point_value as Vector3, CELL * 0.92).is_empty():
            return true
    return false


func _validate_layered_building_route(snapshot: Dictionary, points: Array, route_actions := {}) -> Dictionary:
    # The navmesh may cross terrain, floor slabs and real stair stringers in one
    # route.  Validate that exact three-dimensional corridor instead of applying
    # the legacy one-height-per-XZ cell test, which cannot represent a floor over
    # ground.  Every permitted elevated point still has a published support and
    # every non-support construction collider remains a blocker.
    var previous: Vector3 = points[0] if points[0] is Vector3 else Vector3.ZERO
    for index in range(1, points.size()):
        if not (points[index] is Vector3):
            continue
        var next: Vector3 = points[index]
        var samples := clampi(ceili(previous.distance_to(next) / maxf(CELL * 0.28, 0.12)), 1, 96)
        for sample_index in range(samples + 1):
            var point := previous.lerp(next, float(sample_index) / float(samples))
            var support := building_support_for_position(point, CELL * 0.92)
            var source_part_id := ""
            if not support.is_empty():
                point.y = _support_surface_y(support, point) + 0.04
                source_part_id = String(support.get("sourceCollisionPartId", support.get("sourcePartId", "")))
            else:
                var terrain_point := cell_position(world_cell(point))
                if absf(point.y - terrain_point.y) > CELL * 0.88:
                    return {
                        "ok": false,
                        "reason": "missing_walkable_support_layer",
                        "segmentIndex": index - 1,
                        "point": point
                    }
                point.y = terrain_point.y
            var collision := static_collision_blocker_at_position(snapshot, point, source_part_id)
            if not collision.is_empty():
                var portal_action := _source_door_portal_action_for_segment(route_actions, previous, next)
                if not portal_action.is_empty() and _door_portal_segment_is_physically_clear(snapshot, previous, next, portal_action):
                    continue
                return {
                    "ok": false,
                    "reason": "layered_static_collision",
                    "segmentIndex": index - 1,
                    "point": point,
                    "collision": collision
                }
        previous = next
    return { "ok": true, "reason": "", "layeredSupportValidation": true }


func _source_door_portal_action_for_segment(route_actions, first: Vector3, second: Vector3) -> Dictionary:
    if not (route_actions is Dictionary):
        return {}
    for action_value in (route_actions as Dictionary).values():
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        if String(action.get("kind", "")) != "door" or not bool(action.get("navLink", false)):
            continue
        var portal_id := String(action.get("portalId", ""))
        var source_door := _source_building_door_for_portal(portal_id)
        if source_door.is_empty():
            continue
        var entry_position = action.get("entryPosition", null)
        var exit_position = action.get("exitPosition", null)
        if not (entry_position is Vector3) or not (exit_position is Vector3):
            continue
        if not _source_door_action_matches_portal(entry_position as Vector3, exit_position as Vector3, source_door):
            continue
        if _door_portal_segment_touches_endpoint(first, second, entry_position as Vector3, exit_position as Vector3):
            return action
    return {}


func _source_building_door_for_portal(portal_id: String) -> Dictionary:
    if portal_id.is_empty():
        return {}
    for door_value in cached_building_doors:
        if not (door_value is Dictionary):
            continue
        var source_door: Dictionary = door_value
        if String(source_door.get("id", "")) == portal_id and bool(source_door.get("sourcePortalReady", false)):
            return source_door
    return {}


func _source_door_action_matches_portal(entry: Vector3, exit: Vector3, source_door: Dictionary) -> bool:
    var interior = source_door.get("interior", null)
    var exterior = source_door.get("exterior", null)
    if not (interior is Vector3) or not (exterior is Vector3):
        return false
    return (entry.distance_to(interior as Vector3) <= DOOR_PORTAL_VALIDATION_POINT_EPSILON and exit.distance_to(exterior as Vector3) <= DOOR_PORTAL_VALIDATION_POINT_EPSILON) \
        or (entry.distance_to(exterior as Vector3) <= DOOR_PORTAL_VALIDATION_POINT_EPSILON and exit.distance_to(interior as Vector3) <= DOOR_PORTAL_VALIDATION_POINT_EPSILON)


func _door_portal_segment_touches_endpoint(first: Vector3, second: Vector3, entry: Vector3, exit: Vector3) -> bool:
    return first.distance_to(entry) <= DOOR_PORTAL_VALIDATION_POINT_EPSILON \
        or first.distance_to(exit) <= DOOR_PORTAL_VALIDATION_POINT_EPSILON \
        or second.distance_to(entry) <= DOOR_PORTAL_VALIDATION_POINT_EPSILON \
        or second.distance_to(exit) <= DOOR_PORTAL_VALIDATION_POINT_EPSILON


func _door_portal_segment_is_physically_clear(snapshot: Dictionary, first: Vector3, second: Vector3, _action: Dictionary) -> bool:
    var samples := clampi(ceili(first.distance_to(second) / maxf(CELL * 0.28, 0.12)), 1, 96)
    for sample_index in range(samples + 1):
        var point := first.lerp(second, float(sample_index) / float(samples))
        var support := building_support_for_position(point, CELL * 0.92)
        var source_part_id := ""
        if not support.is_empty():
            point.y = _support_surface_y(support, point) + 0.04
            source_part_id = String(support.get("sourceCollisionPartId", support.get("sourcePartId", "")))
        var collision := static_collision_blocker_at_position_with_inflation(snapshot, point, source_part_id, DOOR_PORTAL_PHYSICAL_COLLISION_INFLATION)
        if not collision.is_empty():
            return false
    return true
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


func static_collision_blocker_at_position(snapshot: Dictionary, position: Vector3, supporting_source_part_id := "") -> Dictionary:
    var cell := world_cell(position)
    var records := _transition_collision_records(snapshot, "staticCollisionByCell", cell, cell)
    for record in records:
        var node_value = record.get("node", null)
        if node_value != null and not is_instance_valid(node_value):
            continue
        var source_part_id := String(record.get("sourcePartId", ""))
        if supporting_source_part_id != "" and source_part_id == supporting_source_part_id:
            continue
        if _point_inside_collision_record_3d(position, record):
            return record
    return {}


func static_collision_blocker_at_position_with_inflation(snapshot: Dictionary, position: Vector3, supporting_source_part_id: String, inflation: float) -> Dictionary:
    var cell := world_cell(position)
    var records := _transition_collision_records(snapshot, "staticCollisionByCell", cell, cell)
    for record in records:
        var node_value = record.get("node", null)
        if node_value != null and not is_instance_valid(node_value):
            continue
        var source_part_id := String(record.get("sourcePartId", ""))
        if not supporting_source_part_id.is_empty() and source_part_id == supporting_source_part_id:
            continue
        if _point_inside_collision_record_3d_with_inflation(position, record, inflation):
            return record
    return {}

func _transition_collision_records(snapshot: Dictionary, index_key: String, from_cell: Vector2i, to_cell: Vector2i) -> Array:
    var index: Dictionary = snapshot.get(index_key, {})
    var broad_key := "staticCollisionBroad" if index_key == "staticCollisionByCell" else "doorCollisionBroad" if index_key == "doorCollisionByCell" else ""
    var broad_records: Array = snapshot.get(broad_key, []) if broad_key != "" and snapshot.get(broad_key, []) is Array else []
    if index.is_empty() and broad_records.is_empty():
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
    for record_value in broad_records:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var id := String(record.get("id", ""))
        if id == "" or seen.has(id) or not _collision_record_overlaps_cells(record, min_x, max_x, min_z, max_z):
            continue
        seen[id] = true
        result.append(record)
    return result

func _collision_record_overlaps_cells(record: Dictionary, min_x: int, max_x: int, min_z: int, max_z: int) -> bool:
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    var min_world_x := float(min_x) * CELL
    var max_world_x := float(max_x + 1) * CELL
    var min_world_z := float(min_z) * CELL
    var max_world_z := float(max_z + 1) * CELL
    return float(record.get("maxX", -INF)) + inflation >= min_world_x \
        and float(record.get("minX", INF)) - inflation <= max_world_x \
        and float(record.get("maxZ", -INF)) + inflation >= min_world_z \
        and float(record.get("minZ", INF)) - inflation <= max_world_z

func _segment_intersects_collision_record(from_position: Vector3, to_position: Vector3, record: Dictionary) -> bool:
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    return _segment_intersects_collision_record_with_inflation(from_position, to_position, record, inflation)

func _segment_intersects_collision_record_with_inflation(from_position: Vector3, to_position: Vector3, record: Dictionary, inflation: float) -> bool:
    var footprint: Array = record.get("footprint", []) if record.get("footprint", []) is Array else []
    if footprint.size() >= 3:
        return _footprint_intersects_segment(Vector2(from_position.x, from_position.z), Vector2(to_position.x, to_position.z), footprint, inflation)
    var min_point := Vector2(float(record.get("minX", 0.0)) - inflation, float(record.get("minZ", 0.0)) - inflation)
    var max_point := Vector2(float(record.get("maxX", 0.0)) + inflation, float(record.get("maxZ", 0.0)) + inflation)
    return _segment_intersects_aabb_2d(Vector2(from_position.x, from_position.z), Vector2(to_position.x, to_position.z), min_point, max_point)

func _point_inside_collision_record(position: Vector3, record: Dictionary) -> bool:
    var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
    return _point_inside_collision_record_with_inflation(position, record, inflation)


func _point_inside_collision_record_with_inflation(position: Vector3, record: Dictionary, inflation: float) -> bool:
    var footprint: Array = record.get("footprint", []) if record.get("footprint", []) is Array else []
    if footprint.size() >= 3:
        return _footprint_intersects_segment(Vector2(position.x, position.z), Vector2(position.x, position.z), footprint, inflation)
    var x := position.x
    var z := position.z
    return x >= float(record.get("minX", 0.0)) - inflation \
        and x <= float(record.get("maxX", 0.0)) + inflation \
        and z >= float(record.get("minZ", 0.0)) - inflation \
        and z <= float(record.get("maxZ", 0.0)) + inflation


func _point_inside_collision_record_3d(position: Vector3, record: Dictionary) -> bool:
    if not _point_inside_collision_record(position, record):
        return false
    return _point_inside_collision_record_vertical_range(position, record)


func _point_inside_collision_record_3d_with_inflation(position: Vector3, record: Dictionary, inflation: float) -> bool:
    if not _point_inside_collision_record_with_inflation(position, record, inflation):
        return false
    return _point_inside_collision_record_vertical_range(position, record)


func _point_inside_collision_record_vertical_range(position: Vector3, record: Dictionary) -> bool:
    var min_y := float(record.get("minY", -INF))
    var max_y := float(record.get("maxY", INF))
    return position.y >= min_y - 0.025 and position.y <= max_y + 0.025

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


func _footprint_intersects_segment(first: Vector2, second: Vector2, footprint: Array, clearance: float) -> bool:
    if footprint.size() < 3:
        return false
    if _point_within_footprint(first, footprint) or _point_within_footprint(second, footprint):
        return true
    var clearance_squared := clearance * clearance
    var previous: Vector3 = footprint[footprint.size() - 1] if footprint[footprint.size() - 1] is Vector3 else Vector3.ZERO
    for point_value in footprint:
        if not (point_value is Vector3):
            return false
        var point: Vector3 = point_value
        var edge_start := Vector2(previous.x, previous.z)
        var edge_end := Vector2(point.x, point.z)
        if _segments_intersect_2d(first, second, edge_start, edge_end):
            return true
        if _point_to_segment_distance_squared(first, edge_start, edge_end) <= clearance_squared \
                or _point_to_segment_distance_squared(second, edge_start, edge_end) <= clearance_squared \
                or _point_to_segment_distance_squared(edge_start, first, second) <= clearance_squared \
                or _point_to_segment_distance_squared(edge_end, first, second) <= clearance_squared:
            return true
        previous = point
    return false


func _point_within_footprint(position: Vector2, footprint: Array) -> bool:
    if footprint.size() < 3:
        return false
    var inside := false
    var previous: Vector3 = footprint[footprint.size() - 1] if footprint[footprint.size() - 1] is Vector3 else Vector3.ZERO
    for point_value in footprint:
        if not (point_value is Vector3):
            return false
        var point: Vector3 = point_value
        var crosses := (point.z > position.y) != (previous.z > position.y)
        if crosses:
            var denominator := previous.z - point.z
            if absf(denominator) > 0.000001:
                var x_at_z := (previous.x - point.x) * (position.y - point.z) / denominator + point.x
                if position.x < x_at_z:
                    inside = not inside
        previous = point
    return inside


func _segments_intersect_2d(first_start: Vector2, first_end: Vector2, second_start: Vector2, second_end: Vector2) -> bool:
    var first_direction := first_end - first_start
    var second_direction := second_end - second_start
    var denominator := first_direction.cross(second_direction)
    var delta := second_start - first_start
    if absf(denominator) <= 0.000001:
        if absf(delta.cross(first_direction)) > 0.000001:
            return false
        var first_length_squared := first_direction.length_squared()
        if first_length_squared <= 0.000001:
            return first_start.distance_squared_to(second_start) <= 0.000001
        var start_projection := delta.dot(first_direction) / first_length_squared
        var end_projection := (second_end - first_start).dot(first_direction) / first_length_squared
        return maxf(minf(start_projection, end_projection), 0.0) <= minf(maxf(start_projection, end_projection), 1.0)
    var first_t := delta.cross(second_direction) / denominator
    var second_t := delta.cross(first_direction) / denominator
    return first_t >= -0.000001 and first_t <= 1.000001 and second_t >= -0.000001 and second_t <= 1.000001


func _point_to_segment_distance_squared(point: Vector2, segment_start: Vector2, segment_end: Vector2) -> float:
    var segment := segment_end - segment_start
    var length_squared := segment.length_squared()
    if length_squared <= 0.000001:
        return point.distance_squared_to(segment_start)
    var projection := clampf((point - segment_start).dot(segment) / length_squared, 0.0, 1.0)
    return point.distance_squared_to(segment_start + segment * projection)

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
        if String(record.get("ownerActorId", "")) == String(entry.get("id", "")):
            continue
        if record_interior_contains_cell(record, cell):
            return true
    return false

func private_interior_records_for_entry(_entry: Dictionary, structure_system) -> Array:
    var structure_revision := 0
    if structure_system != null and structure_system.has_method("private_interior_records_revision"):
        structure_revision = int(structure_system.private_interior_records_revision())
    var revision_key := "%d:%d" % [static_snapshot_revision, structure_revision]
    if cached_private_interior_records_revision == revision_key:
        return cached_private_interior_records
    var records: Array = []
    if structure_system == null or not structure_system.has_method("town_home_records_snapshot"):
        cached_private_interior_records_revision = revision_key
        cached_private_interior_records = records
        return records
    var records_by_town: Dictionary = structure_system.town_home_records_snapshot()
    for key_value in records_by_town.keys():
        var town_records_value = records_by_town.get(key_value, [])
        if town_records_value is Array:
            records.append_array(town_records_value)
    if structure_system.has_method("private_interior_records_snapshot"):
        records.append_array(structure_system.private_interior_records_snapshot())
    cached_private_interior_records_revision = revision_key
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
    if _terrain_surface_is_covered_by_building_support(snapshot, position):
        return {}
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


func _terrain_surface_is_covered_by_building_support(snapshot: Dictionary, position: Vector3) -> bool:
    var cell := world_cell(position)
    var tile_key := tile_key_for_cell(cell)
    for support in building_supports_for_tile(tile_key):
        if not _point_within_support_xz(position, support):
            continue
        if _support_surface_y(support, position) >= position.y + CELL * 0.12:
            return true
    # A solid building mass can leave the terrain surface geometrically below its
    # collision volume even when the mass is not itself an exposed walkable floor.
    # Suppress that terrain layer whenever it lacks standing headroom; otherwise
    # NavMesh can route below a terrace and the collision substrate must reject it.
    for record_value in _transition_collision_records(snapshot, "staticCollisionByCell", cell, cell):
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        if not bool(record.get("sourceManifest", false)):
            continue
        if position.x < float(record.get("minX", INF)) or position.x > float(record.get("maxX", -INF)) \
            or position.z < float(record.get("minZ", INF)) or position.z > float(record.get("maxZ", -INF)):
            continue
        if float(record.get("maxY", -INF)) < position.y + 0.02:
            continue
        if float(record.get("minY", INF)) <= position.y + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT:
            return true
    return false

func _navmesh_door_summary_for_tile(snapshot: Dictionary, tile_key: String) -> Dictionary:
    var portals: Array[Dictionary] = []
    var links: Array[Dictionary] = []
    var source_portal_ids := {}
    var published_portal_ids := {}
    for source_door in cached_building_doors:
        var managed_portal_id := String(source_door.get("id", ""))
        if not managed_portal_id.is_empty():
            source_portal_ids[managed_portal_id] = true
    for source_door in building_doors_for_tile(tile_key):
        if not bool(source_door.get("sourcePortalReady", false)):
            continue
        var portal_id := String(source_door.get("id", ""))
        var endpoint_resolution := _resolve_building_door_navigation_endpoints(snapshot, source_door)
        if not bool(endpoint_resolution.get("resolved", false)):
            continue
        var interior: Vector3 = endpoint_resolution.get("interior", Vector3.ZERO) as Vector3
        var exterior: Vector3 = endpoint_resolution.get("exterior", Vector3.ZERO) as Vector3
        if portal_id.is_empty() or interior.distance_squared_to(exterior) <= 0.0001:
            continue
        var interior_support_id := String(source_door.get("interiorSupportId", ""))
        var exterior_support_id := String(source_door.get("exteriorSupportId", ""))
        var live_door := _live_door_for_portal(snapshot, portal_id)
        var door_cell := world_cell((interior + exterior) * 0.5)
        var state := String(live_door.get_meta("door_state", NpcEnumsScript.DOOR_STATE_CLOSED)) if live_door != null else String(NpcEnumsScript.DOOR_STATE_CLOSED)
        var locked := bool(live_door.get_meta("locked", false)) if live_door != null else false
        var jammed := bool(live_door.get_meta("jammed", false)) if live_door != null else false
        var destroyed := bool(live_door.get_meta("destroyed", false)) if live_door != null else false
        var unloaded := bool(live_door.get_meta("unloaded", false)) if live_door != null else false
        portals.append({
            "id": portal_id,
            "entrance": interior,
            "exit": exterior,
            "state": state,
            "openable": true,
            "enabled": not destroyed and not unloaded,
            "locked": locked,
            "jammed": jammed,
            "destroyed": destroyed,
            "unloaded": unloaded,
            "crossingAxis": "source",
            "cell": door_cell,
            "sourceDoor": true,
            "sourcePartId": String(source_door.get("sourcePartId", "")),
            "interiorSupportId": interior_support_id,
            "exteriorSupportId": exterior_support_id,
            "endpointResolution": endpoint_resolution.duplicate(true)
        })
        published_portal_ids[portal_id] = true
        links.append({
            "id": "door-link:%s:%s" % [portal_id, tile_key],
            "from": _nav_span_key(tile_key, world_cell(interior)),
            "to": _nav_span_key(tile_key, world_cell(exterior)),
            "portalId": portal_id,
            "actionId": "open",
            "start": interior,
            "end": exterior,
            "bidirectional": true,
            "openable": true,
            "enabled": true,
            "cost": 1.0,
            "enterCost": DOOR_LINK_ENTER_COST,
            "travelCost": 1.0,
            "cell": door_cell,
            "sourceDoor": true,
            "ownerTileKey": String(source_door.get("ownerTileKey", tile_key)),
            "startTileKey": String(source_door.get("interiorTileKey", "")),
            "endTileKey": String(source_door.get("exteriorTileKey", "")),
            "startSupportId": interior_support_id,
            "endSupportId": exterior_support_id,
            "endpointResolution": endpoint_resolution.duplicate(true)
        })
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
        if source_portal_ids.has(portal_id):
            continue
        var axis := _door_crossing_axis(door, snapshot, cell)
        var step := Vector2i(1, 0) if axis == "x" else Vector2i(0, 1)
        var entrance_cell := cell - step
        var exit_cell := cell + step
        var entrance := cell_position(entrance_cell)
        var exit := cell_position(exit_cell)
        if not published_portal_ids.has(portal_id):
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
            published_portal_ids[portal_id] = true
        links.append({
            "id": "door-link:%s:%s:%s" % [portal_id, tile_key, cell_key(cell)],
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


func _resolve_building_door_navigation_endpoints(snapshot: Dictionary, source_door: Dictionary) -> Dictionary:
    var interior_support_id := String(source_door.get("interiorSupportId", ""))
    var exterior_support_id := String(source_door.get("exteriorSupportId", ""))
    var authored_interior: Vector3 = source_door.get("interior", Vector3.INF) as Vector3
    var authored_exterior: Vector3 = source_door.get("exterior", Vector3.INF) as Vector3
    if interior_support_id.is_empty() or exterior_support_id.is_empty() or not authored_interior.is_finite() or not authored_exterior.is_finite():
        return {"resolved": false, "reason": "door_endpoint_provenance_missing"}
    var interior_resolution := _resolve_building_navigation_link_endpoint(snapshot, interior_support_id, authored_interior, String(source_door.get("interiorTileKey", "")))
    var exterior_resolution := _resolve_building_navigation_link_endpoint(snapshot, exterior_support_id, authored_exterior, String(source_door.get("exteriorTileKey", "")))
    if not bool(interior_resolution.get("resolved", false)) or not bool(exterior_resolution.get("resolved", false)):
        return {"resolved": false, "reason": "door_endpoint_support_unresolved", "interiorResolution": interior_resolution, "exteriorResolution": exterior_resolution}
    var interior: Vector3 = interior_resolution.get("position", Vector3.INF) as Vector3
    var exterior: Vector3 = exterior_resolution.get("position", Vector3.INF) as Vector3
    if interior.distance_to(authored_interior) > BUILDING_NAVIGATION_LINK_MAX_ENDPOINT_DRIFT or exterior.distance_to(authored_exterior) > BUILDING_NAVIGATION_LINK_MAX_ENDPOINT_DRIFT:
        return {"resolved": false, "reason": "door_endpoint_support_drift", "interiorResolution": interior_resolution, "exteriorResolution": exterior_resolution}
    return {
        "resolved": true,
        "interior": interior,
        "exterior": exterior,
        "interiorSupportId": interior_support_id,
        "exteriorSupportId": exterior_support_id,
        "interiorResolution": interior_resolution,
        "exteriorResolution": exterior_resolution
    }


func _live_door_for_portal(snapshot: Dictionary, portal_id: String) -> Node:
    var doors: Dictionary = snapshot.get("doors", {})
    var cells: Array = doors.keys()
    cells.sort_custom(func(a, b): return cell_key(a) < cell_key(b))
    for cell_value in cells:
        if not (cell_value is Vector2i):
            continue
        var door := door_at(snapshot, cell_value as Vector2i)
        if door != null and _door_portal_id(door, cell_value as Vector2i) == portal_id:
            return door
    return null

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
    if cached_revision == "":
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
