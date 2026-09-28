extends RefCounted
class_name GeneratedWorldNavigationAdapter

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")
const NavigationPublicationSourceScript := preload("res://scripts/npc_ai/navigation/NavigationPublicationSource.gd")
const NavigationTileCaptureScript := preload("res://scripts/npc_ai/navigation/NavigationTileCapture.gd")
const GAMEPLAY_NAVIGATION_CAPTURE_BUDGET_USEC := 750
const LOADING_NAVIGATION_CAPTURE_BUDGET_USEC := 8000

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
const NAVIGATION_CAPTURE_ORDER_KEY := &"_navigationCaptureOrder"
const NAVMESH_TILE_SNAPSHOT_CACHE_LIMIT := 96
const APPROACH_CERTIFICATION_VALIDATIONS_PER_CALL := 4

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
var cached_block_keys_by_nav_tile := {}
# Failed sources have unknown extent: block publication, never invent geometry.
var collision_source_errors := {}
var cached_static_collision_records: Array[Dictionary] = []
var cached_static_collision_by_cell := {}
var cached_static_collision_capture_sequence := 0
var cached_door_collision_records: Array[Dictionary] = []
var cached_door_collision_by_cell := {}
var cached_private_interior_records_revision := ""
var cached_private_interior_records: Array = []
var height_cache := {}
var terrain_projection_cache := {}
var navmesh_tile_snapshot_cache := {}
var navmesh_tile_snapshot_cache_order: Array[String] = []
var navmesh_tile_revision_by_key := {}
var navmesh_tile_semantic_revision_by_key := {}
var navmesh_tile_door_revision_by_key := {}
var navmesh_tile_load_revision_by_key := {}
## Terrain edits change a tile's authoritative surface facts, but do not alter
## the global live block/prop/collision inventory. Keep that identity separate
## so a local dig never triggers a full world collision-registry rebuild.
var navmesh_tile_terrain_revision_by_key := {}
# Monotonic source-identity clock. A scoped edit advances only the affected
# tile's fact revision; an unscoped terrain event advances the common baseline.
var terrain_revision_clock := 0
var terrain_global_revision := 0
var static_snapshot_revision := 1
var route_global_source_revision := 1
var topology_revision := 1
var dynamic_revision := 0
var semantic_revision := 0
var door_state_revision := 0
var last_event_revision := 0
var nav_static_rebuild_count := 0
var nav_dynamic_update_count := 0
var dynamic_occupant_cache_frame_key := ""
var dynamic_occupant_cache := {}
var approach_certification_jobs := {}
var active_approach_certification_by_actor := {}
var _publication_service_ref: WeakRef
var _capture_retirement: Dictionary = {}
var _navigation_capture
var _last_capture_diagnostic_frame := -1000
# Opt-in evidence only. Retention is bounded by the existing tile snapshot cache.
var navigation_rejection_diagnostics_enabled := OS.get_environment("VOXEL_NAVIGATION_REJECTION_DIAGNOSTICS") == "1"

func setup(system_node, main_node) -> void:
    system = system_node
    main = main_node

func _notification(what: int) -> void:
    if what != NOTIFICATION_PREDELETE: return
    # Do not discover owners while tearing down. A service that admitted this
    # producer must outlive its capture cache through the existing exit protocol.
    var service = _publication_service_ref.get_ref() if _publication_service_ref != null else null
    if _navigation_capture != null:
        _navigation_capture.detach_live_records()
        if is_instance_valid(service): service.retire_navigation_payload({"capture":_navigation_capture})
        _navigation_capture = null
    if is_instance_valid(service):
        service.retire_navigation_payload(navmesh_tile_snapshot_cache)
        service.retire_navigation_payload(_capture_retirement)
        navmesh_tile_snapshot_cache = {}
        _capture_retirement = {}

func performance_monitor():
    return main.get("runtime_perf_monitor") if main != null else null

func invalidate() -> void:
    static_snapshot_revision += 1
    route_global_source_revision += 1
    topology_revision = static_snapshot_revision
    cached_revision = ""
    height_cache = {}
    terrain_projection_cache = {}
    _clear_navmesh_tile_snapshot_cache()
    navmesh_tile_revision_by_key.clear()
    navmesh_tile_semantic_revision_by_key.clear()
    navmesh_tile_door_revision_by_key.clear()
    navmesh_tile_load_revision_by_key.clear()
    navmesh_tile_terrain_revision_by_key.clear()
    terrain_revision_clock = 0
    terrain_global_revision = 0
    cached_prop_cell_by_object_id = {}
    cached_prop_collision_records_by_object_id = {}
    cached_private_interior_records_revision = ""
    dynamic_occupant_cache_frame_key = ""
    dynamic_occupant_cache = {}
    cached_private_interior_records = []
    approach_certification_jobs.clear()
    active_approach_certification_by_actor.clear()

func apply_navigation_events(events: Array) -> void:
    var monitor = performance_monitor()
    var apply_start: int = monitor.begin_section("generated_nav_event_apply") if monitor != null else Time.get_ticks_usec()
    var static_changed := false
    var static_global_changed := false
    var terrain_changed := false
    var terrain_global_changed := false
    var dynamic_changed := false
    var semantic_changed := false
    var semantic_global_changed := false
    var door_state_changed := false
    var static_changed_tiles: Array[String] = []
    var terrain_changed_tiles := {}
    var semantic_changed_tiles: Array[String] = []
    var door_state_changed_tiles: Array[String] = []
    for event_value in events:
        if not (event_value is Dictionary):
            continue
        var event: Dictionary = event_value
        last_event_revision = maxi(last_event_revision, int(event.get("revision", 0)))
        var kinds: Array = event.get("changeKinds", [])
        var tile_key := String(event.get("tileKey", ""))
        if _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED):
            _mark_chunk_load_publication_change(tile_key)
        if _event_has_kind(kinds, NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT):
            terrain_changed = true
            var affected_terrain_tiles := _terrain_capture_tile_keys_for_event(event)
            if affected_terrain_tiles.is_empty():
                terrain_global_changed = true
            for affected_tile_key in affected_terrain_tiles:
                terrain_changed_tiles[affected_tile_key] = true
        if _event_changes_static_snapshot(kinds):
            var prop_start: int = monitor.begin_section("generated_nav_prop_event_apply") if monitor != null else Time.get_ticks_usec()
            if _event_is_prop_only_static_change(kinds) and _apply_prop_event_to_static_cache(event):
                _mark_incremental_static_change(tile_key)
            else:
                static_changed = true
                if tile_key == "":
                    static_global_changed = true
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
        if static_global_changed or static_changed_tiles.is_empty():
            route_global_source_revision += 1
        static_snapshot_revision = maxi(static_snapshot_revision + 1, last_event_revision)
        topology_revision = static_snapshot_revision
        cached_revision = ""
        height_cache = {}
        terrain_projection_cache = {}
        _clear_navmesh_tile_snapshot_cache()
        for tile_key in static_changed_tiles:
            navmesh_tile_revision_by_key[tile_key] = static_snapshot_revision
    if terrain_changed:
        # Terrain projection/height facts are derived from terrain authority and
        # must be queried fresh. The completed collision inventory remains valid:
        # a terrain edit cannot create, remove or transform a registered block,
        # prop or door body.
        height_cache = {}
        terrain_projection_cache = {}
        if terrain_global_changed or terrain_changed_tiles.is_empty():
            route_global_source_revision += 1
            terrain_revision_clock = maxi(terrain_revision_clock + 1, last_event_revision)
            terrain_global_revision = terrain_revision_clock
            navmesh_tile_terrain_revision_by_key.clear()
            _clear_navmesh_tile_snapshot_cache()
        else:
            # Every tile capture includes a one-cell seam halo. Advance one
            # shared edit revision for all captures intersecting the changed
            # cells so cached, active and accepted source identities cannot
            # retain a stale seam independently of the edit's owning tile.
            terrain_revision_clock = maxi(terrain_revision_clock + 1, last_event_revision)
            var affected_tile_keys: Array = terrain_changed_tiles.keys()
            affected_tile_keys.sort()
            for tile_key_value in affected_tile_keys:
                var tile_key := String(tile_key_value)
                navmesh_tile_terrain_revision_by_key[tile_key] = terrain_revision_clock
                _clear_navmesh_tile_snapshot_cache_for_tile(tile_key)
    if dynamic_changed:
        dynamic_revision = maxi(dynamic_revision + 1, last_event_revision)
    if semantic_changed:
        semantic_revision = maxi(semantic_revision + 1, last_event_revision)
        if semantic_global_changed or semantic_changed_tiles.is_empty():
            route_global_source_revision += 1
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
		"terrainRevision": terrain_revision_clock,
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
    return "%d:%d:%d:%d:%d" % [static_snapshot_revision, dynamic_revision, semantic_revision, door_state_revision, terrain_revision_clock]

func navmesh_tile_source_key() -> String:
    var key := "%d:%d:%d" % [static_snapshot_revision, semantic_revision, door_state_revision]
    if terrain_global_revision > 0:
        key += "|terrain:%d" % terrain_global_revision
    return key

func navmesh_tile_source_key_for_tile(tile_key: String) -> String:
    if tile_key == "":
        return navmesh_tile_source_key()
    var structures = main.get("structure_system") if is_instance_valid(main) else null
    if is_instance_valid(structures) and structures.has_method("navigation_tile_source_identity"):
        return _navmesh_tile_source_key_from_building_sources(
            tile_key,structures.navigation_tile_source_identity(_parse_tile_key(tile_key)))
    return _navmesh_tile_source_key_from_building_sources(tile_key,building_navigation_sources(tile_key))

# Compose identity from source facts already obtained in this synchronous call.
# This helper performs no live proof and must never replace public validation.
func _navmesh_tile_source_key_from_building_sources(tile_key: String, structures: Dictionary) -> String:
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
    var key := "%d:%d:%d" % [tile_revision, tile_semantic_revision, tile_door_revision]
    if navmesh_tile_load_revision_by_key.has(tile_key):
        key += "|chunk-load:%d" % int(navmesh_tile_load_revision_by_key[tile_key])
    var terrain_revision := int(navmesh_tile_terrain_revision_by_key.get(tile_key, terrain_global_revision))
    if terrain_revision > 0:
        key += "|terrain:%d" % terrain_revision
    if structures.get("status")!="ready": return key+"|structure:"+String(structures.get("reason","pending"))
    for source: Dictionary in structures.get("sources",[]):
        key += "|%s:%d" % [source.binding.sourceKey,int(source.binding.generation)]
    return key

func building_navigation_sources(tile_key: String) -> Dictionary:
    var structures = main.get("structure_system") if is_instance_valid(main) else null
    if not is_instance_valid(structures) or not structures.has_method("navigation_tile_sources"):
        return {"status":"ready","sources":[]}
    var result: Dictionary = structures.navigation_tile_sources(_parse_tile_key(tile_key))
    if result.get("status")!="ready": return result
    for source: Dictionary in result.get("sources",[]):
        var missing: Array = source.get("tile",{}).get("unresolvedCrossings",[])
        if not missing.is_empty():
            return {"status":"failed","reason":"source_crossings_unresolved","missingCrossings":missing,"binding":source.binding}
    return result

func navigation_tile_terrain_readiness(tile_key: String) -> Dictionary:
    if not is_instance_valid(main) or not main.has_method("navigation_terrain_publication_readiness"):
        # Focused adapters without a production terrain runtime continue to
        # exercise their declared synthetic authority.
        return {"status":"ready","reason":"external_terrain_authority"}
    var tile := _parse_tile_key(tile_key)
    return main.navigation_terrain_publication_readiness(
        Rect2i(tile*NAV_TILE_CELL_SIZE,Vector2i.ONE*NAV_TILE_CELL_SIZE).grow(1))

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
    var started := Time.get_ticks_usec()
    # Another tile's slot has its own source proof. Retire an already-owned
    # predecessor even when a direct caller has no queued publisher visit; an
    # unaccepted capture keeps its slot. Resolve this before requested facts.
    if _navigation_capture != null and _navigation_capture.tile_key != tile_key:
        active_navigation_capture_tile()
    var world_seed = main.get("seed_text") if is_instance_valid(main) else null
    if not world_seed is String or world_seed.strip_edges().is_empty():
        _discard_navigation_capture()
        return {"tileKey":tile_key,"publicationStatus":"failed","reason":"invalid_worldSeed"}
    var terrain_readiness := navigation_tile_terrain_readiness(tile_key)
    if terrain_readiness.get("status") != "ready":
        if _navigation_capture != null and _navigation_capture.tile_key == tile_key:
            _discard_navigation_capture()
        return {"tileKey":tile_key,"publicationStatus":terrain_readiness.get("status","pending"),
            "reason":terrain_readiness.get("reason","navigation_terrain_publication_pending")}
    # Resolving the service may bind or retire payloads. Do it before acquiring
    # source facts, while preserving the early pending-source maintenance gate.
    var service = _publication_service()
    if not is_instance_valid(main) or (main is Node and main.is_queued_for_deletion()) or main.get("seed_text") != world_seed:
        _discard_navigation_capture()
        return {"tileKey":tile_key,"publicationStatus":"pending","reason":"navigation_source_changed_during_capture"}
    # Streaming and NPC publication can visit the same pending capture inside one
    # Main callback. Its cooperative slice has already consumed this frame; avoid
    # paying physical preflight again merely to hit the capture's frame guard.
    # This shortcut can only report pending. It never accepts or publishes facts.
    if _navigation_capture != null and _navigation_capture.tile_key == tile_key \
            and _navigation_capture.has_method("advanced_this_process_frame") \
            and _navigation_capture.advanced_this_process_frame():
        var monitor = performance_monitor()
        if monitor != null: monitor.increment_counter("navmesh_capture_same_frame_visits_deferred")
        return {"tileKey":tile_key,"publicationStatus":"pending","reason":"navigation_capture_frame_budget_used"}
    if cached_revision != str(static_snapshot_revision):
        build_snapshot({}, true, true)
    _retry_collision_sources()
    var failure := _collision_publication_failure(tile_key)
    if not failure.is_empty(): return failure
    if not is_instance_valid(main) or (main is Node and main.is_queued_for_deletion()) or main.get("seed_text") != world_seed:
        _discard_navigation_capture()
        return {"tileKey":tile_key,"publicationStatus":"pending","reason":"navigation_source_changed_during_capture"}
    # A capture retains the already validated immutable building artifacts for
    # its whole cursor lifetime. Repeating navigation_tile_sources here used to
    # rescan thousands of physical groups on every 4 ms slice. Use only cheap
    # revision identity while that owner is current; the service revalidates the
    # physical source at the actual installation boundary below this capture.
    var retained_capture := active_navigation_capture_source(tile_key)
    var building_sources: Dictionary = {}
    var source_key := ""
    if not retained_capture.is_empty():
        building_sources = {"status":"ready","sources":retained_capture.sources}
        source_key = String(retained_capture.sourceKey)
    else:
        var preflight_started := Time.get_ticks_usec()
        building_sources = building_navigation_sources(tile_key)
        _record_navmesh_capture_cost("navmesh_filter_source_preflight",Time.get_ticks_usec()-preflight_started)
        if building_sources.get("status") != "ready":
            if _navigation_capture != null and _navigation_capture.tile_key == tile_key:
                _discard_navigation_capture()
            return {"tileKey":tile_key,"publicationStatus":String(building_sources.get("status","pending")),
                "reason":String(building_sources.get("reason","structure_source_pending"))}
        source_key = _navmesh_tile_source_key_from_building_sources(tile_key,building_sources)
    if service != null and service.has_method("accepted_tile_state"):
        # A cheap scheduling lookup decides whether an installed result exists.
        # Only a matching result pays accepted_tile_state's authoritative physical
        # validation. An absent result proceeds directly to capture.
        var retained: Dictionary = service.accepted_tile_progress_source(tile_key,source_key,world_seed,self) \
            if service.has_method("accepted_tile_progress_source") else {}
        var state: Dictionary = service.accepted_tile_state(tile_key,source_key,world_seed,self) \
            if not retained.is_empty() else {}
        if state.get("status") == "invalid":
            if _navigation_capture != null and _navigation_capture.tile_key == tile_key:
                _discard_navigation_capture()
            return {"tileKey":tile_key,"sourceKey":source_key,"publicationStatus":"failed",
                "reason":state.get("reason","navigation_accepted_source_invalid")}
        if bool(state.get("sourceOwned",false)):
            if _navigation_capture != null and _navigation_capture.tile_key == tile_key:
                _discard_navigation_capture()
            return _accepted_navmesh_request(state.accepted)
    if _navigation_capture != null and _navigation_capture.tile_key == tile_key \
            and not _navigation_capture.current_from_entry_source(self,source_key):
        _discard_navigation_capture()
        # Retirement is another owner call. Retry with fresh facts rather than
        # carrying this entry proof through it into a replacement capture.
        return {"tileKey":tile_key,"publicationStatus":"pending","reason":"navigation_source_changed_during_capture"}
    var cache_key := "%s|%s" % [tile_key, JSON.stringify([world_seed, source_key])]
    if navmesh_tile_snapshot_cache.has(cache_key):
        # Callers receive a header copy. Service acceptance must not put result
        # aliases into the input cache, or eviction could destroy worker output.
        return navmesh_tile_snapshot_cache[cache_key].duplicate(false)
    if _navigation_capture != null and _navigation_capture.tile_key == tile_key and _navigation_capture.status == "ready":
        # A sealed cursor has detached its live aliases and cannot be resealed.
        # If its cached input was retired, restart through ordinary capture.
        _discard_navigation_capture()
        return {"tileKey":tile_key,"publicationStatus":"pending","reason":"navigation_capture_input_retired"}
    if _navigation_capture == null:
        _navigation_capture = NavigationTileCaptureScript.new()
        _navigation_capture.begin(self,tile_key,source_key,world_seed,building_sources.get("sources",[]))
    if _navigation_capture.tile_key != tile_key:
        return {"tileKey":tile_key,"publicationStatus":"pending","reason":"navigation_capture_slot_busy"}
    var active_capture = _navigation_capture
    var progress: Dictionary = active_capture.advance(self,_navigation_capture_budget_usec(),source_key)
    _record_navmesh_capture_cost("navmesh_filter_capture_step",Time.get_ticks_usec()-started)
    if progress.status == "stale" or _navigation_capture != active_capture:
        _discard_navigation_capture()
        return {"tileKey":tile_key,"publicationStatus":"pending","reason":"navigation_source_changed_during_capture"}
    if progress.status != "ready":
        return {"tileKey":tile_key,"publicationStatus":progress.status,"reason":progress.reason}
    var snapshot: Dictionary = _navigation_capture.snapshot
    failure = _collision_publication_failure(tile_key)
    if not failure.is_empty():
        _discard_navigation_capture()
        return failure
    var live_usec: int = _navigation_capture.profile.liveUsec
    var terrain: Array[Dictionary] = _navigation_capture.terrain
    var terrain_usec: int = _navigation_capture.profile.terrainUsec
    var doors := _navmesh_door_summary_for_tile(snapshot,tile_key,_navigation_capture.source_sites,
        _navigation_capture.heights,_navigation_capture.projections)
    var factory := NavigationPublicationSourceScript.new()
    var tiles: Array[Dictionary] = []
    for source: Dictionary in building_sources.get("sources",[]):
        if not _apply_building_door_geometry(doors,source,tile_key):
            return {"tileKey":tile_key,"publicationStatus":"pending","reason":"structure_door_owner_pending"}
        tiles.append(factory.retain_filter_building_tile(source))
    var diagnostics := {}
    if navigation_rejection_diagnostics_enabled:
        diagnostics = {"schema":"navigation-live-rejections/v1","tileKey":tile_key,"sourceKey":source_key,
            "worldSeed":world_seed,"sourceRevision":static_snapshot_revision,"semanticRevision":semantic_revision,
            "physicsFrame":Engine.get_physics_frames(),"processFrame":Engine.get_process_frames(),
            "rawBuildingSurfaceCount":0,"acceptedBuildingSurfaceCount":0,"rejectedBuildingSurfaceCount":0,
            "rawTerrainCellCount":NAV_TILE_CELL_SIZE*NAV_TILE_CELL_SIZE,"acceptedTerrainSurfaceCount":0,
            "rejectedTerrainCellCount":0,"terrainRejectionReasons":{},"sourceBindings":[],"blockers":{},"recordUsec":0}
    var input := {"waterLevel":float(main.WATER_LEVEL),"terrainCells":terrain,
        "staticCollision":snapshot.staticCollision,"buildingTiles":tiles,
        "doorPortals":doors.doorPortals,"doorLinks":doors.doorLinks,"diagnostics":diagnostics}
    var result := {"publicationStatus":"ready","worldSeed":world_seed,"tileKey":tile_key,
        "sourceKey":source_key,"regionId":"region:chunk:"+tile_key,"sourceRevision":static_snapshot_revision,
        "topologyRevision":static_snapshot_revision,"dynamicRevision":dynamic_revision,"semanticRevision":semantic_revision}
    var seal_started := Time.get_ticks_usec()
    var captured: Dictionary = factory.capture_filter_input(result,input)
    _record_navmesh_capture_cost("navmesh_filter_live_capture",live_usec)
    _record_navmesh_capture_cost("navmesh_filter_terrain_capture",terrain_usec)
    _record_navmesh_capture_cost("navmesh_filter_input_seal",Time.get_ticks_usec()-seal_started)
    _record_navmesh_capture_cost("navmesh_filter_capture_total",Time.get_ticks_usec()-started)
    if captured.status != "prepared":
        _discard_navigation_capture()
        return {"tileKey":tile_key,"publicationStatus":"failed","reason":captured.reason}
    # Sealing retains only value facts. Keep the cheap revision identity here;
    # NavmeshWorldService performs the authoritative live physical proof at the
    # actual acceptance/installation boundary.
    if _navigation_capture != active_capture or not active_capture.current_from_entry_source(self,source_key):
        _retire_navmesh_capture({"input":captured})
        _discard_navigation_capture()
        return {"tileKey":tile_key,"publicationStatus":"pending","reason":"navigation_source_changed_during_capture"}
    result["publicationInput"] = captured
    result["publicationOwner"] = weakref(self)
    var door_owners := {}
    for cell in snapshot.doors:
        var body = snapshot.doors[cell]
        if is_instance_valid(body) and body is Node: door_owners[cell] = weakref(body)
    door_owners.make_read_only()
    result["publicationDoorOwners"] = door_owners
    _store_navmesh_tile_snapshot_cache(cache_key,result)
    # The same slot owns capture through publication acknowledgement. Retiring
    # here queues work on the compiler before it can accept this input, while
    # dropping the slot lets uncaptured tiles displace the deferred ready input.
    # Only value facts remain retained; no live registry aliases cross the seal.
    active_capture.detach_live_records()
    return result.duplicate(false)

func _navigation_capture_budget_usec() -> int:
    if is_instance_valid(main) and (main.get("startup_loading_active") == true \
            or main.get("runtime_loading_active") == true):
        return LOADING_NAVIGATION_CAPTURE_BUDGET_USEC
    return GAMEPLAY_NAVIGATION_CAPTURE_BUDGET_USEC

func active_navigation_capture_tile() -> String:
    if _navigation_capture == null: return ""
    # Queue scheduling needs only the retained owner's cheap lifecycle/source
    # identity. Physical source validation remains at accepted_tile_state and
    # register/install boundaries, where it can actually transfer ownership.
    if not _navigation_capture.current_from_entry_source(self,_navigation_capture.source_key):
        _discard_navigation_capture()
        return ""
    if OS.get_environment("VOXEL_NAVIGATION_CAPTURE_DIAGNOSTICS") == "1":
        var process_frame := Engine.get_process_frames()
        if process_frame-_last_capture_diagnostic_frame >= 60:
            _last_capture_diagnostic_frame = process_frame
            print("NAVIGATION_CAPTURE_DIAGNOSTIC ",JSON.stringify(_navigation_capture.diagnostic_snapshot()))
    if _navigation_capture.status == "ready":
        var service = _publication_service()
        if service != null and service.has_method("accepted_tile_state"):
            var state: Dictionary = service.accepted_tile_state(_navigation_capture.tile_key,
                _navigation_capture.source_key,_navigation_capture.seed_text,self)
            var active: Dictionary = service.active_publication_request()
            # Source transfer releases the slot independently of server sync.
            if bool(state.get("sourceOwned",false)) or state.get("status") == "invalid" \
                    or (active.tileKey == _navigation_capture.tile_key and active.status == "failed"):
                _discard_navigation_capture()
                return ""
    return _navigation_capture.tile_key


func active_navigation_capture_source(tile_key: String) -> Dictionary:
    if _navigation_capture == null: return {}
    var retained: Dictionary = _navigation_capture.retained_source(self,tile_key)
    if retained.is_empty() and _navigation_capture.tile_key == tile_key:
        _discard_navigation_capture()
    return retained

func release_navigation_capture_slot(expected_tile := "", expected_source := "") -> void:
    if _navigation_capture == null: return
    if not expected_tile.is_empty() and _navigation_capture.tile_key != expected_tile: return
    if not expected_source.is_empty() and _navigation_capture.source_key != expected_source: return
    _discard_navigation_capture()

func _discard_navigation_capture() -> void:
    if _navigation_capture == null: return
    # Live registry aliases are detached here; value facts and large immutable
    # source references retire through the established owned worker protocol.
    _navigation_capture.detach_live_records()
    _retire_navmesh_capture({"capture":_navigation_capture})
    _navigation_capture = null

func _navmesh_filter_live_snapshot(tile_key: String) -> Dictionary:
    var base := cached_static_tile_snapshot(true,true)
    var tile := _parse_tile_key(tile_key)
    var snapshot := {}
    # Only tile cells and the door-axis neighbor halo need live registry values.
    for field: String in ["blocked","doors","paths","propClearance"]:
        var local := {}
        var cells: Dictionary = base.get(field,{})
        for z in range(tile.y*NAV_TILE_CELL_SIZE-1,(tile.y+1)*NAV_TILE_CELL_SIZE+1):
            for x in range(tile.x*NAV_TILE_CELL_SIZE-1,(tile.x+1)*NAV_TILE_CELL_SIZE+1):
                var cell := Vector2i(x,z)
                if cells.has(cell): local[cell] = cells[cell]
        snapshot[field] = local
    var blocks: Dictionary = main.get("blocks")
    var records: Array = base.get("staticCollision",[])
    if not blocks.is_empty():
        for field: String in ["blocked","doors","paths"]: _erase_tile_cells(snapshot[field],tile_key)
        records = _collision_records_outside_tile(records,tile_key)
        for block_value in blocks.values():
            var body := block_value as Node
            if body == null or not is_instance_valid(body): continue
            var cell := block_world_cell(body)
            if cell == INVALID_CELL or tile_key_for_cell(cell) != tile_key: continue
            var kind := String(body.get_meta("block_type",""))
            if kind == "door":
                snapshot.doors[cell] = body
                snapshot.blocked.erase(cell)
                # Preserve live finite-shape validation/retry even though static
                # surface filtering does not consume door collision indexes.
                _collision_records_for_body(body,cell,kind,true)
            elif kind == "cobblestonePath":
                snapshot.paths[cell] = true
                snapshot.blocked.erase(cell)
            elif kind == "torch" or not block_xz_blocks_npc(cell,body):
                snapshot.blocked.erase(cell)
            else:
                snapshot.blocked[cell] = body
                _append_collision_records(records,body,cell,kind,false)
    var facts: Array[Dictionary] = []
    # Keep the full ordered collision inventory; only indexing/filtering moves.
    # No global by-cell index clone or construction occurs on this capture path.
    for record: Dictionary in records:
        var fact := _navigation_rejection_record_values(record) if navigation_rejection_diagnostics_enabled else record.duplicate(false)
        var node = record.get("node")
        fact.erase("node")
        fact["terrainNodeValid"] = node == null or is_instance_valid(node)
        if fact.get("footprint") is Array: fact["footprint"] = fact.footprint.duplicate()
        facts.append(fact)
    snapshot["staticCollision"] = facts
    return snapshot

func _navmesh_node_evidence(node) -> Dictionary:
    return _navigation_rejection_record_values({"node":node}) if navigation_rejection_diagnostics_enabled and node != null else {}

func _record_navmesh_capture_cost(section: String, elapsed: int) -> void:
    var monitor = performance_monitor()
    if monitor != null: monitor.observe_duration(section,float(elapsed)/1000.0)

func _accepted_navmesh_request(accepted: Dictionary) -> Dictionary:
    var result: Dictionary = accepted.source.snapshot.duplicate(false)
    result["publicationStatus"] = "ready"
    result["publicationSource"] = accepted.source
    result["publicationOwner"] = weakref(self)
    result["publicationAcceptedSerial"] = accepted.serial
    result["publicationDoorOwners"] = accepted.doorOwners
    result["publicationCaptureProfile"] = accepted.captureProfile
    if not accepted.get("diagnostics",{}).is_empty(): result["publicationDiagnostics"] = accepted.diagnostics
    return result

func bind_navigation_publication_service(service) -> void:
    _publication_service_ref = weakref(service)
    service.retain_navigation_capture_owner(self)
    if not _capture_retirement.is_empty():
        service.retire_navigation_payload(_capture_retirement)
        _capture_retirement = {}

func _publication_service():
    var service = _publication_service_ref.get_ref() if _publication_service_ref != null else null
    if service != null: return service
    var npc = main.get("npc_system") if is_instance_valid(main) else null
    var autonomy = npc.get("autonomy_system") if is_instance_valid(npc) else null
    service = autonomy.get("navmesh_world") if is_instance_valid(autonomy) else null
    if is_instance_valid(service) and service.has_method("retire_navigation_payload"):
        bind_navigation_publication_service(service)
        return service
    return null

func release_navigation_capture_cache() -> void:
    _discard_navigation_capture()
    _clear_navmesh_tile_snapshot_cache()

func _retire_navmesh_capture(payload: Dictionary) -> void:
    if payload.is_empty(): return
    var service = _publication_service()
    if service != null: service.retire_navigation_payload(payload)
    else: _capture_retirement[_capture_retirement.size()] = payload





func _navigation_rejection_record_values(record: Dictionary) -> Dictionary:
    var result := {}
    # Scalar/vector metadata includes the actual ID, cell, sourcePartId, source
    # kind, bounds, inflation and door flag. Never copy live object references.
    for key in record:
        if key is String and typeof(record[key]) <= TYPE_NODE_PATH: result[key] = record[key]
    if record.get("footprint") is Array:
        var footprint: Array[Vector3] = []
        for point in record.footprint:
            if point is Vector3: footprint.append(point)
        result["footprint"] = footprint
    var node = record.get("node")
    if is_instance_valid(node) and node is Node:
        var owner := {"instanceId":node.get_instance_id(),"name":String(node.name),"class":node.get_class(),
            "insideTree":node.is_inside_tree(),"queuedForDeletion":node.is_queued_for_deletion(),"metadata":{}}
        if node.is_inside_tree(): owner["path"] = String(node.get_path())
        if node is Node3D: owner["position"] = node.global_position if node.is_inside_tree() else node.position
        for key: String in ["kind","block_type","cell","building_id","building_part_id","building_source_blueprint_id",
                "furnishing_part_id","furnishing_plan_id","door_building_id","prop_id","prop_kind","prop","source_part_id","sourcePartId",
                "tree_recipe_signature","tree_visual_state","tree_render_lod_tier","tree_publication_cancelled","tree_collision_ready_usec"]:
            if node.has_meta(key) and typeof(node.get_meta(key)) <= TYPE_NODE_PATH: owner.metadata[key] = node.get_meta(key)
        if node is CollisionObject3D:
            owner["collisionLayer"] = node.collision_layer
            owner["collisionMask"] = node.collision_mask
            owner["enabledShapes"] = []
            # Only direct CollisionShape3D children belong to this body. Read
            # once per rejecting record, without a physics query or mutation.
            for child in node.get_children():
                if not child is CollisionShape3D or child.disabled or child.shape == null: continue
                var shape: Shape3D = child.shape
                var shape_evidence := {"name":String(child.name),"type":shape.get_class(),
                    "localTransform":child.transform,"insideTree":child.is_inside_tree()}
                if child.is_inside_tree(): shape_evidence["globalTransform"] = child.global_transform
                if shape is WorldBoundaryShape3D:
                    shape_evidence["plane"] = shape.plane
                    shape_evidence["boundsStatus"] = "unbounded_plane"
                else:
                    var debug_mesh: ArrayMesh = shape.get_debug_mesh()
                    if debug_mesh != null:
                        shape_evidence["localShapeBounds"] = debug_mesh.get_aabb()
                        shape_evidence["boundsSource"] = "shape_debug_mesh"
                    else: shape_evidence["boundsStatus"] = "unavailable"
                owner.enabledShapes.append(shape_evidence)
        result["nodeEvidence"] = owner
    return result

func _apply_building_door_geometry(summary: Dictionary, source: Dictionary, tile_key: String) -> bool:
    # The publication owner supplies the exact registered leaf, even when its
    # body and certified interior support occupy different navigation tiles.
    for fact: Dictionary in source.get("tile",{}).get("doors",[]):
        var reference: WeakRef = source.get("doorBodies",{}).get(String(fact.sourcePartId))
        var body = reference.get_ref() if reference != null else null
        if not is_instance_valid(body) or body.is_queued_for_deletion() or not body.is_inside_tree(): return false
        if String(body.get_meta("door_building_id",""))!=String(source.binding.siteId): return false
        var cell := world_cell(body.global_position)
        var axis := "x" if absf(fact.outward.x)>absf(fact.outward.z) else "z"
        _append_navmesh_door(summary,body,cell,tile_key,axis,fact.exterior,fact.interior)
    return true

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
    if navmesh_tile_snapshot_cache.has(cache_key):
        _retire_navmesh_capture(navmesh_tile_snapshot_cache[cache_key])
    navmesh_tile_snapshot_cache[cache_key] = snapshot
    navmesh_tile_snapshot_cache_order.erase(cache_key)
    navmesh_tile_snapshot_cache_order.append(cache_key)
    while navmesh_tile_snapshot_cache_order.size() > NAVMESH_TILE_SNAPSHOT_CACHE_LIMIT:
        var evicted := String(navmesh_tile_snapshot_cache_order.pop_front())
        _retire_navmesh_capture(navmesh_tile_snapshot_cache.get(evicted,{}))
        navmesh_tile_snapshot_cache.erase(evicted)

func _clear_navmesh_tile_snapshot_cache() -> void:
    _discard_navigation_capture()
    var retired := navmesh_tile_snapshot_cache
    navmesh_tile_snapshot_cache = {}
    _retire_navmesh_capture(retired)
    navmesh_tile_snapshot_cache_order.clear()

func _clear_navmesh_tile_snapshot_cache_for_tile(tile_key: String) -> void:
    if tile_key == "":
        return
    if _navigation_capture != null and _navigation_capture.tile_key == tile_key:
        _discard_navigation_capture()
    var prefix := "%s|" % tile_key
    var evicted_keys: Array[String] = []
    for cache_key_value in navmesh_tile_snapshot_cache.keys():
        var cache_key := String(cache_key_value)
        if cache_key.begins_with(prefix):
            evicted_keys.append(cache_key)
    for cache_key in evicted_keys:
        _retire_navmesh_capture(navmesh_tile_snapshot_cache.get(cache_key,{}))
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
    for record in body_records:
        records.append(record)

func _collision_index_for_records(records: Array) -> Dictionary:
    var index := {}
    for record_value in records:
        if record_value is Dictionary:
            _index_collision_record(index, record_value)
    return index

func _rebuild_navigation_capture_static_collision_order() -> void:
    cached_static_collision_capture_sequence = 0
    for record_value in cached_static_collision_records:
        if not record_value is Dictionary:
            continue
        var record := record_value as Dictionary
        record[NAVIGATION_CAPTURE_ORDER_KEY] = cached_static_collision_capture_sequence
        cached_static_collision_capture_sequence += 1

func navigation_capture_static_collision_candidates(extent: Rect2i) -> Dictionary:
    # The cell index repeats a spanning record in every covered bucket. Its
    # capture ordinal identifies that one authoritative inventory occurrence,
    # so the result can be de-duplicated without scanning the global array and
    # then restored to the exact original record order.
    var candidates_by_order := {}
    var indexed_occurrence_visits := 0
    var index_cells_visited := 0
    for z in range(extent.position.y, extent.end.y):
        for x in range(extent.position.x, extent.end.x):
            index_cells_visited += 1
            var records_value = cached_static_collision_by_cell.get(Vector2i(x, z), [])
            if not records_value is Array:
                continue
            for record_value in records_value as Array:
                if not record_value is Dictionary:
                    continue
                indexed_occurrence_visits += 1
                var record := record_value as Dictionary
                var order_value = record.get(NAVIGATION_CAPTURE_ORDER_KEY, null)
                if not order_value is int:
                    return {"status":"failed", "reason":"navigation_collision_capture_order_missing"}
                var order := int(order_value)
                if candidates_by_order.has(order) and not is_same(candidates_by_order[order], record):
                    return {"status":"failed", "reason":"navigation_collision_capture_order_conflict"}
                candidates_by_order[order] = record
    var ordered_keys: Array = candidates_by_order.keys()
    ordered_keys.sort()
    var records: Array[Dictionary] = []
    for order_value in ordered_keys:
        records.append(candidates_by_order[order_value] as Dictionary)
    return {
        "status":"ready", "reason":"", "records":records,
        "inventoryCount":cached_static_collision_records.size(),
        "candidateCount":records.size(), "indexCellsVisited":index_cells_visited,
        "indexedOccurrenceVisits":indexed_occurrence_visits
    }

func navigation_capture_block_keys(tile_key: String) -> Array:
    var keys_value = cached_block_keys_by_nav_tile.get(tile_key, [])
    return (keys_value as Array).duplicate() if keys_value is Array else []

func cached_static_tile_snapshot(allow_outside := false, moving_home := false) -> Dictionary:
    if cached_revision == "" and cached_blocked.is_empty() and cached_doors.is_empty() and cached_paths.is_empty() and cached_props.is_empty():
        return build_snapshot({}, allow_outside, moving_home)
    return {
        "revision": revision(),
        "staticSnapshotRevision": static_snapshot_revision,
		"terrainRevision": terrain_revision_clock,
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
		"terrainRevision": terrain_revision_clock,
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
        # Prop publication already supplies the exact affected navigation tile.
        # Keep unrelated sealed inputs and an unrelated in-progress capture: their
        # tile-local source identities and physical facts have not changed.
        _clear_navmesh_tile_snapshot_cache_for_tile(String(tile_key))
    else:
        route_global_source_revision += 1
        # An unscoped event cannot prove locality, so retain the conservative
        # full invalidation used by world resets and unknown source mutations.
        _clear_navmesh_tile_snapshot_cache()

func _mark_chunk_load_publication_change(tile_key: String) -> void:
    if tile_key.length() > 23:
        return
    var coordinates := tile_key.split(",", true)
    if coordinates.size() != 2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int():
        return
    var x := int(coordinates[0])
    var z := int(coordinates[1])
    if x < -2147483648 or x > 2147483647 or z < -2147483648 or z > 2147483647 \
            or tile_key != "%d,%d" % [x, z]:
        return
    # Loading acknowledges volume collision; it does not change the shared
    # blocks/props index. Match service dirtiness once per delivered entry,
    # including change-bus batches sharing the same event revision.
    navmesh_tile_load_revision_by_key[tile_key] = int(navmesh_tile_load_revision_by_key.get(tile_key, 0)) + 1
    _clear_navmesh_tile_snapshot_cache_for_tile(tile_key)

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

func _terrain_capture_tile_keys_for_event(event: Dictionary) -> Array[String]:
    var edit_cell_bounds := _terrain_event_cell_bounds(event)
    if edit_cell_bounds.size.x <= 0 or edit_cell_bounds.size.y <= 0:
        return []
    # Candidate cores can only be one tile beyond the edit's own cells because
    # the authoritative capture/readiness footprint grows each core by one cell.
    var candidate_cells := edit_cell_bounds.grow(1)
    var last_candidate := candidate_cells.end - Vector2i.ONE
    var min_tile := Vector2i(
        floori(float(candidate_cells.position.x) / float(NAV_TILE_CELL_SIZE)),
        floori(float(candidate_cells.position.y) / float(NAV_TILE_CELL_SIZE)))
    var max_tile := Vector2i(
        floori(float(last_candidate.x) / float(NAV_TILE_CELL_SIZE)),
        floori(float(last_candidate.y) / float(NAV_TILE_CELL_SIZE)))
    var result: Array[String] = []
    for tile_z in range(min_tile.y, max_tile.y + 1):
        for tile_x in range(min_tile.x, max_tile.x + 1):
            var tile := Vector2i(tile_x, tile_z)
            var capture_bounds := Rect2i(
                tile * NAV_TILE_CELL_SIZE,
                Vector2i.ONE * NAV_TILE_CELL_SIZE).grow(1)
            if capture_bounds.intersects(edit_cell_bounds):
                result.append("%d,%d" % [tile_x, tile_z])
    result.sort()
    return result

func _terrain_event_cell_bounds(event: Dictionary) -> Rect2i:
    var bounds_value = event.get("bounds")
    if bounds_value is AABB:
        var bounds: AABB = bounds_value
        if bounds.size.x > 0.0 and bounds.size.z > 0.0:
            var bounds_end := bounds.position + bounds.size
            # Terrain edit events describe cell volumes centered on integer
            # cells. Convert the half-cell world extents back to an inclusive
            # cell range without treating merely touching neighbor faces as edits.
            var epsilon := 0.0001
            var min_cell := Vector2i(
                floori(bounds.position.x / NpcConstantsScript.CELL_SIZE - 0.5 + epsilon) + 1,
                floori(bounds.position.z / NpcConstantsScript.CELL_SIZE - 0.5 + epsilon) + 1)
            var max_cell := Vector2i(
                ceili(bounds_end.x / NpcConstantsScript.CELL_SIZE + 0.5 - epsilon) - 1,
                ceili(bounds_end.z / NpcConstantsScript.CELL_SIZE + 0.5 - epsilon) - 1)
            if max_cell.x >= min_cell.x and max_cell.y >= min_cell.y:
                return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)
    # Legacy/synthetic callers without bounds cannot prove where inside their
    # tile the edit landed. Treat the whole core as edited, conservatively
    # invalidating all captures whose halo overlaps it.
    var tile_key := String(event.get("tileKey", ""))
    if tile_key == "":
        return Rect2i()
    var tile := _parse_tile_key(tile_key)
    if tile_key != "%d,%d" % [tile.x, tile.y]:
        return Rect2i()
    return Rect2i(tile * NAV_TILE_CELL_SIZE, Vector2i.ONE * NAV_TILE_CELL_SIZE)

func rebuild_static_cells() -> int:
    collision_source_errors.clear()
    cached_blocked = {}
    cached_doors = {}
    cached_paths = {}
    cached_props = {}
    cached_prop_clearance = {}
    cached_prop_cell_by_object_id = {}
    cached_prop_collision_records_by_object_id = {}
    cached_block_keys_by_nav_tile = {}
    cached_static_collision_records = []
    cached_static_collision_by_cell = {}
    cached_static_collision_capture_sequence = 0
    cached_door_collision_records = []
    cached_door_collision_by_cell = {}
    height_cache = {}
    terrain_projection_cache = {}
    if main == null:
        return 0
    var scanned := 0
    var blocks: Dictionary = main.get("blocks")
    # Keep the authoritative Dictionary traversal order while partitioning the
    # live registry once per static revision. A capture can then refresh body,
    # metadata and collider facts for its tile without walking the loaded world.
    for block_key in blocks.keys():
        scanned += 1
        var block = blocks.get(block_key)
        var body := block as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_cell := block_world_cell(body)
        if block_cell == INVALID_CELL:
            continue
        var block_tile_key := tile_key_for_cell(block_cell)
        if not cached_block_keys_by_nav_tile.has(block_tile_key):
            cached_block_keys_by_nav_tile[block_tile_key] = []
        cached_block_keys_by_nav_tile[block_tile_key].append(block_key)
        var block_type := String(body.get_meta("block_type", ""))
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
    var records := _collision_records_for_body(body, cell, block_type, is_door)
    var prop_object_id := _prop_object_id(body) if block_type == "prop" else ""
    var prop_records: Array[Dictionary] = []
    for record in records:
        if is_door:
            cached_door_collision_records.append(record)
            _index_collision_record(cached_door_collision_by_cell, record)
        else:
            record[NAVIGATION_CAPTURE_ORDER_KEY] = cached_static_collision_capture_sequence
            cached_static_collision_capture_sequence += 1
            cached_static_collision_records.append(record)
            _index_collision_record(cached_static_collision_by_cell, record)
            if prop_object_id != "":
                prop_records.append(record)
    if prop_object_id != "" and not prop_records.is_empty():
        cached_prop_collision_records_by_object_id[prop_object_id] = prop_records

func _collision_records_for_body(body: Node, cell: Vector2i, block_type: String, is_door: bool) -> Array[Dictionary]:
    var publication := _collect_collision_records(body, cell, block_type, is_door)
    var key := str(body.get_instance_id())
    if publication.status != "ready":
        collision_source_errors[key] = {"owner":weakref(body), "cell":cell,
            "blockType":block_type, "isDoor":is_door, "objectId":_prop_object_id(body),
            "error":publication.error}
        _clear_navmesh_tile_snapshot_cache()
        return []
    collision_source_errors.erase(key)
    return publication.records

func _collect_collision_records(body: Node, cell: Vector2i, block_type: String, is_door: bool) -> Dictionary:
    var records: Array[Dictionary] = []
    if not body is Node3D or not body.is_inside_tree():
        return {"status":"failed", "error":{"reason":"navigation_collision_owner_not_live"}}
    var stack: Array[Node] = [body]
    var box_index := 0
    while not stack.is_empty():
        var node := stack.pop_back() as Node
        var collider := node as CollisionShape3D
        if collider != null and not collider.disabled:
            var compiled := _finite_collision_bounds(collider)
            if compiled.status != "ready":
                return {"status":"failed", "error":{"reason":compiled.reason,
                    "body":String(body.name), "objectId":_prop_object_id(body),
                    "colliderPath":String(body.get_path_to(collider)),
                    "shapeClass":collider.shape.get_class() if collider.shape != null else "null"}}
            # Existing box ordinals stay unchanged if another shape is present.
            var suffix := str(box_index) if collider.shape is BoxShape3D else "shape:"+String(body.get_path_to(collider))
            if collider.shape is BoxShape3D: box_index += 1
            records.append(_finite_collision_record(body, cell, block_type, is_door, suffix, compiled.bounds))
        for child in node.get_children(): stack.append(child)
    if block_type == "prop" and not records.is_empty():
        var bounds := _collision_record_bounds(records[0])
        for index in range(1, records.size()): bounds = bounds.merge(_collision_record_bounds(records[index]))
        # Preserve the existing opaque prop ID and one aggregate record.
        records.assign([_finite_collision_record(body, cell, block_type, is_door, "fallback", bounds)])
    return {"status":"ready", "records":records}

func _finite_collision_bounds(collider: CollisionShape3D) -> Dictionary:
    var shape := collider.shape
    if shape == null: return {"status":"failed", "reason":"missing_navigation_collision_shape"}
    if not (shape is BoxShape3D or shape is SphereShape3D or shape is CylinderShape3D or shape is CapsuleShape3D):
        return {"status":"failed", "reason":"unsupported_navigation_collision_shape"}
    var transform := collider.global_transform
    if not transform.is_finite() or is_zero_approx(transform.basis.determinant()):
        return {"status":"failed", "reason":"invalid_navigation_collision_transform"}
    var half := Vector3.ZERO
    var radius := 0.0
    var half_height := 0.0
    if shape is BoxShape3D:
        half = shape.size * 0.5
        if not half.is_finite() or half.x <= 0.0 or half.y <= 0.0 or half.z <= 0.0:
            return {"status":"failed", "reason":"invalid_navigation_collision_dimensions"}
    else:
        radius = shape.radius
        if shape is CylinderShape3D or shape is CapsuleShape3D: half_height = shape.height * 0.5
        if not is_finite(radius) or radius <= 0.0 or not is_finite(half_height) \
            or ((shape is CylinderShape3D or shape is CapsuleShape3D) and half_height <= 0.0) \
            or (shape is CapsuleShape3D and half_height < radius):
            return {"status":"failed", "reason":"invalid_navigation_collision_dimensions"}
    var extent := Vector3.ZERO
    for axis in range(3):
        var row := Vector3(transform.basis.x[axis], transform.basis.y[axis], transform.basis.z[axis])
        if shape is BoxShape3D: extent[axis] = row.abs().dot(half)
        elif shape is SphereShape3D: extent[axis] = radius * row.length()
        elif shape is CylinderShape3D: extent[axis] = radius * Vector2(row.x,row.z).length() + half_height * absf(row.y)
        else: extent[axis] = radius * row.length() + (half_height-radius) * absf(row.y)
    var bounds := AABB(transform.origin-extent, extent*2.0)
    if not bounds.position.is_finite() or not bounds.end.is_finite():
        return {"status":"failed", "reason":"invalid_navigation_collision_bounds"}
    return {"status":"ready", "bounds":bounds}

func _finite_collision_record(body: Node3D, cell: Vector2i, block_type: String, is_door: bool, suffix: String, bounds: AABB) -> Dictionary:
    return {"id":"%s:%s:%s:%s" % ["door" if is_door else "static",cell_key(cell),String(body.name),suffix],
        "cell":cell, "blockType":block_type, "node":body, "isDoor":is_door,
        "minX":bounds.position.x, "maxX":bounds.end.x,
        "minY":bounds.position.y, "maxY":bounds.end.y,
        "minZ":bounds.position.z, "maxZ":bounds.end.z,
        "inflation":TRANSITION_COLLISION_INFLATION}

func _collision_record_bounds(record: Dictionary) -> AABB:
    var minimum := Vector3(record.minX,record.minY,record.minZ)
    return AABB(minimum,Vector3(record.maxX,record.maxY,record.maxZ)-minimum)

func _collision_publication_failure(tile_key: String) -> Dictionary:
    if collision_source_errors.is_empty(): return {}
    # No finite bound exists for an unsupported source. Do not guess tile extent.
    return {"tileKey":tile_key, "publicationStatus":"failed",
        "reason":"navigation_collision_source_invalid", "sourceRevision":static_snapshot_revision,
        "sourceErrorCount":collision_source_errors.size(),
        "collisionError":collision_source_errors.values()[0].error.duplicate(true)}

func _retry_collision_sources() -> void:
    var recovered := false
    for entry: Dictionary in collision_source_errors.values():
        var body = entry.owner.get_ref()
        if body == null or not body.is_inside_tree():
            recovered = true
            continue
        var publication := _collect_collision_records(body,entry.cell,entry.blockType,entry.isDoor)
        if publication.status == "ready": recovered = true
    if recovered:
        # Recovery must rebuild the same source, not merely clear the error/cache.
        invalidate()
        build_snapshot({},true,true)

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
    for key in collision_source_errors.keys():
        if collision_source_errors[key].objectId == object_id: collision_source_errors.erase(key)
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
        if cached_static_collision_records.is_empty():
            cached_static_collision_capture_sequence = 0
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
        _rebuild_navigation_capture_static_collision_order()
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
    return _block_xz_blocks_npc_with_caches(cell,body,height_cache,terrain_projection_cache)

func _block_xz_blocks_npc_with_caches(cell: Vector2i, body: Node, heights: Dictionary, projections: Dictionary) -> bool:
    if main == null or not (body is Node3D):
        return true
    var block_center_y := (body as Node3D).global_position.y
    var floor_y := _height_for_cell_with_caches(cell,heights,projections)
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
    return _height_for_cell_with_caches(cell,height_cache,terrain_projection_cache)

func _height_for_cell_with_caches(cell: Vector2i, heights: Dictionary, projections: Dictionary) -> float:
    if main == null:
        return 0.0
    if heights.has(cell):
        return float(heights[cell])
    var projection := _terrain_projection_for_cell_with_cache(cell,projections)
    var y := 0.0
    if bool(projection.get("found", false)):
        var position: Vector3 = projection.get("position", Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL))
        y = position.y
    else:
        y = float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y))) if main.has_method("surface_y_at_cell") else 0.0
    heights[cell] = y
    return y

func terrain_projection_for_cell(cell: Vector2i) -> Dictionary:
    return _terrain_projection_for_cell_with_cache(cell,terrain_projection_cache)

func _terrain_projection_for_cell_with_cache(cell: Vector2i, projections: Dictionary) -> Dictionary:
    if projections.has(cell):
        return projections[cell]
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
            projections[cell] = fallback_projection
            return fallback_projection
        if world_generation.has_method("navigation_surface_projection_at_known_height"):
            var known_boundary: Dictionary = world_generation.call(
                "navigation_surface_projection_at_known_height", probe_cell, surface_y)
            if known_boundary.get("status") == "ready" and bool(known_boundary.get("found", false)):
                projections[cell] = known_boundary
                return known_boundary
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
    projections[cell] = projection
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

func route_source_revision_for_cells(cells: Array) -> String:
    # A route validates cells and their immediate collision/terrain halo. Prop
    # publication outside those tiles must not discard its bounded search.
    var tiles := {}
    for value in cells:
        if not value is Vector2i:
            continue
        var cell: Vector2i = value
        for x_offset in range(-1, 2):
            for z_offset in range(-1, 2):
                tiles[tile_key_for_cell(cell + Vector2i(x_offset, z_offset))] = true
    return route_source_revision_for_tiles(tiles.keys())

func route_source_revision_for_tiles(source_tile_keys: Array) -> String:
    var tile_keys: Array = source_tile_keys.duplicate()
    tile_keys.sort()
    var parts: Array[String] = ["global:%d" % route_global_source_revision]
    for key_value in tile_keys:
        var tile_key := String(key_value)
        if not navmesh_tile_revision_by_key.has(tile_key):
            navmesh_tile_revision_by_key[tile_key] = static_snapshot_revision
        if not navmesh_tile_semantic_revision_by_key.has(tile_key):
            navmesh_tile_semantic_revision_by_key[tile_key] = semantic_revision
        parts.append("%s:%d:%d:%d" % [
            tile_key,
            int(navmesh_tile_revision_by_key[tile_key]),
            int(navmesh_tile_semantic_revision_by_key[tile_key]),
            int(navmesh_tile_terrain_revision_by_key.get(tile_key, terrain_global_revision))
        ])
    return "|".join(parts)

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



func _navmesh_door_summary_for_tile(snapshot: Dictionary, tile_key: String, source_sites: Array[String] = [], capture_heights: Dictionary = {}, capture_projections: Dictionary = {}) -> Dictionary:
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
        if source_sites.has(String(door.get_meta("door_building_id",""))): continue
        var portal_id := _door_portal_id(door, cell)
        if portal_id == "":
            continue
        var axis := _door_crossing_axis(door, snapshot, cell)
        var step := Vector2i(1, 0) if axis == "x" else Vector2i(0, 1)
        var entrance_cell := cell - step
        var exit_cell := cell + step
        var entrance: Vector3
        var exit: Vector3
        if capture_heights.is_empty():
            entrance = cell_position(entrance_cell)
            exit = cell_position(exit_cell)
        else:
            entrance = Vector3(float(entrance_cell.x)*CELL,_height_for_cell_with_caches(entrance_cell,capture_heights,capture_projections)+0.04,float(entrance_cell.y)*CELL)
            exit = Vector3(float(exit_cell.x)*CELL,_height_for_cell_with_caches(exit_cell,capture_heights,capture_projections)+0.04,float(exit_cell.y)*CELL)
        _append_navmesh_door({"doorPortals":portals,"doorLinks":links},door,cell,tile_key,axis,entrance,exit)
    return { "doorPortals": portals, "doorLinks": links }

func _append_navmesh_door(summary: Dictionary, door: Node, cell: Vector2i, tile_key: String, axis: String, entrance: Vector3, exit: Vector3) -> void:
        var portal_id := _door_portal_id(door,cell)
        var entrance_cell := world_cell(entrance)
        var exit_cell := world_cell(exit)
        summary.doorPortals.append({
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
        summary.doorLinks.append({
            "id": "door-link:%s:%s" % [portal_id, tile_key],
            "from": _nav_span_key(tile_key, entrance_cell, entrance),
            "to": _nav_span_key(tile_key, exit_cell, exit),
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

func _nav_span_key(tile_key: String, cell: Vector2i, position: Vector3) -> String:
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


# Resumable first-match form used by high-level selectors that need only the
# first cell from the exact ordered approach set. Partial work is invisible and
# one admission validates a fixed number of cells against one coherent captured
# snapshot. Static/semantic/door/terrain changes reject the retained job; live
# occupancy is rechecked immediately before a cell becomes visible.
func advance_first_approach_cell(entry: Dictionary, target_position: Vector3, allow_outside := true, request_identity := "", validations_per_call := APPROACH_CERTIFICATION_VALIDATIONS_PER_CALL) -> Dictionary:
    var actor_key := _approach_actor_key(entry)
    var target_cell := world_cell(target_position)
    var input_identity := _approach_input_identity(entry)
    var job_key := "%s|%s|%d,%d|%s" % [actor_key, request_identity, target_cell.x, target_cell.y, str(allow_outside)]
    var previous_key := String(active_approach_certification_by_actor.get(actor_key, ""))
    if previous_key != "" and previous_key != job_key:
        approach_certification_jobs.erase(previous_key)
    active_approach_certification_by_actor[actor_key] = job_key
    var job: Dictionary = approach_certification_jobs.get(job_key, {}) if approach_certification_jobs.get(job_key, {}) is Dictionary else {}
    var source_tiles: Array = job.get("sourceTiles", []) if job.get("sourceTiles", []) is Array else []
    var source_identity := _approach_source_identity_for_tiles(source_tiles) if not job.is_empty() else ""
    if not job.is_empty() and (String(job.get("sourceIdentity", "")) != source_identity or String(job.get("inputIdentity", "")) != input_identity):
        approach_certification_jobs.erase(job_key)
        active_approach_certification_by_actor.erase(actor_key)
        return {"status":"invalidated", "reason":"approach_source_changed", "cell":INVALID_CELL, "validatedThisCall":0}
    if job.is_empty():
        var candidate_cells := approach_candidate_cells_for_target(entry, target_position, allow_outside)
        source_tiles = _approach_source_tiles(candidate_cells)
        source_identity = _approach_source_identity_for_tiles(source_tiles)
        job = {
            "actorKey":actor_key,
            "requestIdentity":request_identity,
            "sourceIdentity":source_identity,
            "inputIdentity":input_identity,
            "targetCell":target_cell,
            "allowOutside":allow_outside,
            "cells":candidate_cells,
            "sourceTiles":source_tiles,
            "snapshot":cached_validation_snapshot(entry, allow_outside, false).duplicate(false),
            "cursor":0,
            "validated":0
        }
        approach_certification_jobs[job_key] = job
    var cells: Array = job.get("cells", []) if job.get("cells", []) is Array else []
    var cursor := clampi(int(job.get("cursor", 0)), 0, cells.size())
    var validated_this_call := 0
    var validation_limit := maxi(1, int(validations_per_call))
    var captured_snapshot: Dictionary = job.get("snapshot", {}) if job.get("snapshot", {}) is Dictionary else {}
    while cursor < cells.size() and validated_this_call < validation_limit:
        var cell_value = cells[cursor]
        cursor += 1
        validated_this_call += 1
        job["cursor"] = cursor
        job["validated"] = int(job.get("validated", 0)) + 1
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        if not cell_is_standable_goal_in_snapshot(entry, captured_snapshot, cell, allow_outside, false):
            continue
        if _approach_source_identity_for_tiles(source_tiles) != source_identity:
            approach_certification_jobs.erase(job_key)
            active_approach_certification_by_actor.erase(actor_key)
            return {"status":"invalidated", "reason":"approach_source_changed", "cell":INVALID_CELL, "validatedThisCall":validated_this_call}
        var live_snapshot := cached_validation_snapshot(entry, allow_outside, false)
        if not cell_is_standable_goal_in_snapshot(entry, live_snapshot, cell, allow_outside, false):
            continue
        approach_certification_jobs.erase(job_key)
        active_approach_certification_by_actor.erase(actor_key)
        return {
            "status":"ready", "reason":"first_standable_approach", "cell":cell,
            "validatedThisCall":validated_this_call, "validatedTotal":int(job.get("validated", 0))
        }
    approach_certification_jobs[job_key] = job
    if cursor < cells.size():
        return {
            "status":"pending", "reason":"approach_certification_pending", "cell":INVALID_CELL,
            "validatedThisCall":validated_this_call, "validatedTotal":int(job.get("validated", 0)), "total":cells.size()
        }
    approach_certification_jobs.erase(job_key)
    active_approach_certification_by_actor.erase(actor_key)
    return {
        "status":"exhausted", "reason":"no_standable_approach", "cell":INVALID_CELL,
        "validatedThisCall":validated_this_call, "validatedTotal":int(job.get("validated", 0)), "total":cells.size()
    }


func cancel_approach_cell_certification(entry_or_actor_key, request_identity := "") -> int:
    var actor_key := _approach_actor_key(entry_or_actor_key) if entry_or_actor_key is Dictionary else String(entry_or_actor_key)
    if actor_key == "":
        return 0
    var job_key := String(active_approach_certification_by_actor.get(actor_key, ""))
    if job_key == "":
        return 0
    var job: Dictionary = approach_certification_jobs.get(job_key, {}) if approach_certification_jobs.get(job_key, {}) is Dictionary else {}
    if request_identity != "" and String(job.get("requestIdentity", "")) != request_identity:
        return 0
    var removed := 0
    if approach_certification_jobs.has(job_key):
        approach_certification_jobs.erase(job_key)
        removed = 1
    active_approach_certification_by_actor.erase(actor_key)
    return removed


func approach_certification_census() -> Dictionary:
    return {"jobCount":approach_certification_jobs.size(), "actorCount":active_approach_certification_by_actor.size()}


func _approach_actor_key(entry: Dictionary) -> String:
    var actor_id := String(entry.get("id", entry.get("actorId", "")))
    if actor_id != "":
        return actor_id
    var body = entry.get("body")
    if body is Object and is_instance_valid(body):
        return "instance:%d" % (body as Object).get_instance_id()
    return "entry:%d" % entry.hash()


func _approach_source_tiles(cells: Array) -> Array[String]:
    var lookup := {}
    for cell_value in cells:
        if cell_value is Vector2i:
            lookup[tile_key_for_cell(cell_value)] = true
    var result: Array[String] = []
    for key_value in lookup.keys():
        result.append(String(key_value))
    result.sort()
    return result


func _approach_source_identity_for_tiles(tile_keys: Array) -> String:
    var private_interior_revision := 0
    var structure_system = main.get("structure_system") if main != null else null
    if structure_system != null and structure_system.has_method("private_interior_records_revision"):
        private_interior_revision = int(structure_system.private_interior_records_revision())
    var parts: Array[String] = ["private:%d" % private_interior_revision]
    for key_value in tile_keys:
        var tile_key := String(key_value)
        if not navmesh_tile_revision_by_key.has(tile_key):
            navmesh_tile_revision_by_key[tile_key] = static_snapshot_revision
        if not navmesh_tile_semantic_revision_by_key.has(tile_key):
            navmesh_tile_semantic_revision_by_key[tile_key] = semantic_revision
        if not navmesh_tile_door_revision_by_key.has(tile_key):
            navmesh_tile_door_revision_by_key[tile_key] = door_state_revision
        var terrain_revision := int(navmesh_tile_terrain_revision_by_key.get(tile_key, terrain_global_revision))
        parts.append("%s:%d:%d:%d:%d" % [
            tile_key,
            int(navmesh_tile_revision_by_key.get(tile_key, static_snapshot_revision)),
            int(navmesh_tile_semantic_revision_by_key.get(tile_key, semantic_revision)),
            int(navmesh_tile_door_revision_by_key.get(tile_key, door_state_revision)),
            terrain_revision
        ])
    return "|".join(parts)


func _approach_input_identity(entry: Dictionary) -> String:
    var body = entry.get("body")
    var body_id := (body as Object).get_instance_id() if body is Object and is_instance_valid(body) else 0
    return "%d|%s|%s|%s|%s|%s|%s|%s|%s|%s" % [
        body_id,
        str(entry.get("townCenter", Vector2i.ZERO)),
        str(entry.get("townRadius", 18)),
        String(entry.get("townKey", "")),
        String(entry.get("homeStableId", "")),
        str(entry.get("homeKey", "")),
        str(entry.get("homeCell", Vector2i.ZERO)),
        str(entry.get("porchCell", Vector2i.ZERO)),
        str(entry.get("interiorMinCell", entry.get("homeInteriorMinCell", Vector2i.ZERO))),
        str(entry.get("interiorMaxCell", entry.get("homeInteriorMaxCell", Vector2i.ZERO)))
    ]


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
    return cell_is_standable_goal_in_snapshot(
        entry,
        cached_validation_snapshot(entry, allow_outside, moving_home),
        cell,
        allow_outside,
        moving_home
    )


func cell_is_standable_goal_in_snapshot(entry: Dictionary, snapshot: Dictionary, cell: Vector2i, allow_outside := false, moving_home := false) -> bool:
    if not cell_allowed_area(entry, cell, allow_outside, moving_home):
        return false
    if private_interior_blocks_entry(entry, cell):
        return false
    var terrain := terrain_allows_step(cell, cell, moving_home)
    if not bool(terrain.get("ok", false)):
        return false
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
    return cell_is_static_standable_goal_in_snapshot(
        entry,
        static_validation_snapshot(entry, allow_outside, moving_home),
        cell,
        allow_outside,
        moving_home
    )


func cell_is_static_standable_goal_in_snapshot(entry: Dictionary, snapshot: Dictionary, cell: Vector2i, allow_outside := false, moving_home := false) -> bool:
    if not cell_allowed_area(entry, cell, allow_outside, moving_home):
        return false
    if private_interior_blocks_entry(entry, cell):
        return false
    var terrain := terrain_allows_step(cell, cell, moving_home)
    if not bool(terrain.get("ok", false)):
        return false
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
		"terrainRevision": terrain_revision_clock,
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
