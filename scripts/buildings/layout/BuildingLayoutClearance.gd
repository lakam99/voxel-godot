extends RefCounted
class_name BuildingLayoutClearance

## Immutable building/furniture layout analysis, extracted from the current
## visual donor. Not a runtime NPC/navigation publisher or route authority.
## Donor GeneratedWorldNavigationAdapter.gd SHA256: E501BA4D2CE745014A904CD6B675A7E2E68834A88A676513C9D7F3C8BCCBCC60
## Geometry/index/sampling/adjacency functions retain donor bodies. The only
## specialized execution boundary is synchronous source endpoint resolution:
## the already-loaded manifest supplies the target base and tile-wide sampler.
## No scene acquisition, producers, scheduler, NavigationServer, or live agents.
## Sampler layer bookkeeping remains because it is part of those exact bodies;
## nothing publishes it to runtime navigation. Source reload clears sample caches.

const NpcConstantsScript := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd")
const BuildingNavigationTransitionCertifierScript := preload("res://scripts/buildings/BuildingNavigationTransitionCertifier.gd")
const CELL := NpcConstantsScript.CELL_SIZE
const NAV_TILE_CELL_SIZE := NpcConstantsScript.NAV_TILE_CELL_SIZE
const INVALID_CELL := Vector2i(999999, 999999)
const TRANSITION_COLLISION_INFLATION := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
const TRANSITION_RECORD_INDEX_MARGIN_CELLS := 2
const TRANSITION_RECORD_INDEX_MAX_CELLS := 96
const NAVMESH_SUPPORT_SAMPLE_CACHE_LIMIT := 8192
const BUILDING_SUPPORT_NAV_SAMPLE_STEP := 0.32
const BUILDING_SUPPORT_NAV_CLEARANCE := TRANSITION_COLLISION_INFLATION
const BUILDING_NAVIGATION_LINK_MAX_ENDPOINT_DRIFT := CELL * 0.34
const BUILDING_STAIR_LINK_MAX_ENDPOINT_DRIFT := CELL * 0.78
const BUILDING_SUPPORT_STACK_MAX_SEPARATION := CELL * 0.50
const BUILDING_SUPPORT_STACK_EPSILON := 0.01
const NAVMESH_SORT_ITEMS_PER_ATOMIC_UNIT := 1024
const NAVMESH_SORT_ATOMIC_TARGET_USEC := 900
const NAVMESH_SUPPORT_SAMPLE_STEPS_PER_ATOMIC_UNIT := 32
const NAVMESH_SUPPORT_SAMPLE_ATOMIC_TARGET_USEC := 800
const NAVMESH_SUPPORT_SAMPLE_UNIFORM_RUN_CELLS_PER_STEP := 64
const NAVMESH_SUPPORT_SAMPLE_UNIFORM_RUN_TARGET_USEC := 400
const NAVMESH_TILE_SUPPORT_FAST_CELL_MAX_ROW_SPANS := 32
const MAX_UNINDEXED_SUPPORT_SAMPLE_CELLS := 256
const MAX_SUPPORT_POLYGON_POINTS := 64
const MAX_SURFACE_TRANSITION_COLLISION_CANDIDATES := 256
var _navmesh_nested_work_deadline_usec := 0
var cached_revision := ""
var source_manifest_revision := ""
var cached_static_collision_records: Array[Dictionary] = []
var cached_static_collision_by_cell := {}
var cached_static_collision_broad: Array[Dictionary] = []
var cached_static_collision_broad_by_tile := {}
var cached_static_collision_by_tile := {}
var cached_door_collision_records: Array[Dictionary] = []
var cached_door_collision_by_cell := {}
var cached_door_collision_broad: Array[Dictionary] = []
var cached_door_collision_broad_by_tile := {}
var cached_door_collision_by_tile := {}
var cached_collision_query_by_tile := {}
var cached_collision_query_revision := ""
var cached_building_supports: Array[Dictionary] = []
var cached_building_supports_by_tile := {}
var cached_building_support_by_id := {}
var cached_building_support_ids_valid := true
var cached_building_vertical_links: Array[Dictionary] = []
var cached_building_vertical_links_by_tile := {}
var cached_building_support_seam_links: Array[Dictionary] = []
var cached_building_support_seam_links_by_tile := {}
var cached_building_interior_passage_links: Array[Dictionary] = []
var cached_building_interior_passage_links_by_tile := {}
var cached_building_doors: Array[Dictionary] = []
var cached_building_doors_by_tile := {}
var navmesh_support_sample_cache := {}
var navmesh_support_sample_empty_cache := {}
var navmesh_support_sample_ordered_keys_cache := {}
var navmesh_support_sample_cache_order: Array[String] = []
var navmesh_support_sample_cache_hit_count := 0


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


func _building_navigation_link_blocker(snapshot: Dictionary, support: Dictionary, start: Vector3, end: Vector3, clearance := BUILDING_SUPPORT_NAV_CLEARANCE, additional_allowed_source_parts := []) -> Dictionary:
    if support.is_empty():
        return {"reason": "missing_support"}
    var minimum := Vector2(minf(start.x, end.x), minf(start.z, end.z))
    var maximum := Vector2(maxf(start.x, end.x), maxf(start.z, end.z))
    return _building_support_navigation_blocker_for_footprint(snapshot, support, minf(start.y, end.y), minimum, maximum, clearance, additional_allowed_source_parts)


func _building_support_navigation_blocker_for_footprint(snapshot: Dictionary, support: Dictionary, sample_y: float, minimum_corner: Vector2, maximum_corner: Vector2, clearance := BUILDING_SUPPORT_NAV_CLEARANCE, additional_allowed_source_parts := []) -> Dictionary:
    var minimum_cell := world_cell(Vector3(minimum_corner.x, sample_y, minimum_corner.y))
    var maximum_cell := world_cell(Vector3(maximum_corner.x, sample_y, maximum_corner.y))
    var records := _transition_collision_records(snapshot, "staticCollisionByCell", minimum_cell, maximum_cell)
    return _building_support_navigation_blocker_from_records(records, support, sample_y, minimum_corner, maximum_corner, clearance, additional_allowed_source_parts)


func _building_support_navigation_blocker_from_records(records: Array, support: Dictionary, sample_y: float, minimum_corner: Vector2, maximum_corner: Vector2, clearance := BUILDING_SUPPORT_NAV_CLEARANCE, additional_allowed_source_parts := []) -> Dictionary:
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


func _point_to_segment_distance_squared(point: Vector2, segment_start: Vector2, segment_end: Vector2) -> float:
    var segment := segment_end - segment_start
    var length_squared := segment.length_squared()
    if length_squared <= 0.000001:
        return point.distance_squared_to(segment_start)
    var projection := clampf((point - segment_start).dot(segment) / length_squared, 0.0, 1.0)
    return point.distance_squared_to(segment_start + segment * projection)


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


func _transition_collision_records(snapshot: Dictionary, index_key: String, from_cell: Vector2i, to_cell: Vector2i) -> Array:
    var index: Dictionary = snapshot.get(index_key, {})
    var broad_key := "staticCollisionBroad" if index_key == "staticCollisionByCell" else "doorCollisionBroad" if index_key == "doorCollisionByCell" else ""
    var broad_records: Array = snapshot.get(broad_key, []) if broad_key != "" and snapshot.get(broad_key, []) is Array else []
    if index.is_empty() and broad_records.is_empty():
        return []
    # Transition certification is a publication-time safety gate. Keep every
    # collision lookup strictly bounded and reject oversized input instead of
    # allowing one malformed source revision to become an unbounded atomic unit.
    if broad_records.size() > MAX_SURFACE_TRANSITION_COLLISION_CANDIDATES:
        return [_surface_transition_collision_limit_blocker(index_key, "broad", broad_records.size())]
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
                if result.size() > MAX_SURFACE_TRANSITION_COLLISION_CANDIDATES:
                    return [_surface_transition_collision_limit_blocker(index_key, "indexed", result.size())]
    for record_value in broad_records:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var id := String(record.get("id", ""))
        if id == "" or seen.has(id) or not _collision_record_overlaps_cells(record, min_x, max_x, min_z, max_z):
            continue
        seen[id] = true
        result.append(record)
        if result.size() > MAX_SURFACE_TRANSITION_COLLISION_CANDIDATES:
            return [_surface_transition_collision_limit_blocker(index_key, "combined", result.size())]
    return result


func _surface_transition_collision_limit_blocker(index_key: String, source: String, count: int) -> Dictionary:
    return {
        "id": "navigation:transition_collision_limit",
        "blockType": "validation_limit",
        "reason": "surface_transition_collision_candidate_limit_exceeded",
        "indexKey": index_key,
        "source": source,
        "candidateCount": count,
        "candidateLimit": MAX_SURFACE_TRANSITION_COLLISION_CANDIDATES,
        "minX": -INF,
        "maxX": INF,
        "minY": -INF,
        "maxY": INF,
        "minZ": -INF,
        "maxZ": INF,
        "inflation": 0.0
    }


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


func world_cell(position: Vector3) -> Vector2i:
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))


func _building_support_by_id(support_id: String) -> Dictionary:
    return cached_building_support_by_id.get(support_id, {}) as Dictionary


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


func _building_support_navigation_sample_data(support: Dictionary, snapshot: Dictionary, tile_key: String) -> Dictionary:
    var job := _new_building_support_navigation_sample_job(support, snapshot, tile_key)
    while not bool(job.get("done", false)):
        _advance_building_support_navigation_sample_job(job)
    return job.get("result", {}) as Dictionary


func _advance_building_support_navigation_sample_job(job: Dictionary) -> void:
    var started_usec := Time.get_ticks_usec()
    var processed_steps := 0
    while not bool(job.get("done", false)) and processed_steps < NAVMESH_SUPPORT_SAMPLE_STEPS_PER_ATOMIC_UNIT:
        _advance_building_support_navigation_sample_step(job)
        processed_steps += 1
        if Time.get_ticks_usec() - started_usec >= NAVMESH_SUPPORT_SAMPLE_ATOMIC_TARGET_USEC:
            break


func _advance_building_support_navigation_sample_step(job: Dictionary) -> void:
    if bool(job.get("done", false)):
        return
    var x := int(job.get("x", 0))
    var z := int(job.get("z", 0))
    var support: Dictionary = job.get("support", {}) as Dictionary
    var phase := String(job.get("samplePhase", "prepare"))
    if phase == "candidate_filter":
        var owner_bounds: Array = job.get("ownerBounds", []) as Array
        var bounds_index := int(job.get("ownerBoundsIndex", 0))
        if bounds_index >= owner_bounds.size():
            job.erase("ownerBounds")
            job["samplePhase"] = "prepare"
            return
        job["ownerBoundsIndex"] = bounds_index + 1
        var bound_value = owner_bounds[bounds_index]
        if not (bound_value is Dictionary):
            return
        var bound: Dictionary = bound_value
        var support_minimum: Vector2 = job.get("supportMinimum", Vector2(INF, INF))
        var support_maximum: Vector2 = job.get("supportMaximum", Vector2(-INF, -INF))
        var support_min_y := float(job.get("supportMinY", INF))
        var support_max_y := float(job.get("supportMaxY", -INF))
        if float(bound.get("maxX", -INF)) < support_minimum.x \
                or float(bound.get("minX", INF)) > support_maximum.x \
                or float(bound.get("maxY", -INF)) < support_min_y - BUILDING_SUPPORT_STACK_EPSILON \
                or float(bound.get("minY", INF)) > support_max_y + BUILDING_SUPPORT_STACK_MAX_SEPARATION \
                or float(bound.get("maxZ", -INF)) < support_minimum.y \
                or float(bound.get("minZ", INF)) > support_maximum.y:
            return
        var candidate = bound.get("support")
        if candidate is Dictionary:
            (job.get("ownerCandidates", []) as Array).append(candidate)
        return
    if phase == "prepare":
        var position := Vector3((float(x) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, 0.0, (float(z) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
        if not _point_within_support_xz(position, support):
            _advance_building_support_sample_cursor(job)
            return
        position.y = _support_surface_y(support, position) + 0.04
        job["samplePosition"] = position
        job["sampleCell"] = Vector2i(x, z)
        job["sampleMinimumCorner"] = Vector2(float(x) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, float(z) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
        job["sampleOwnerId"] = String(support.get("id", ""))
        job["sampleSupportY"] = _support_surface_y(support, position)
        job["sampleOwnerY"] = float(job.get("sampleSupportY", position.y))
        job["ownerIndex"] = 0
        var owner_candidates: Array = job.get("ownerCandidates", []) as Array
        var sole_candidate_id := String((owner_candidates[0] as Dictionary).get("id", "")) if owner_candidates.size() == 1 and owner_candidates[0] is Dictionary else ""
        job["samplePhase"] = "blocker" if owner_candidates.is_empty() or sole_candidate_id == String(support.get("id", "")) else "ownership"
        return
    if phase == "ownership":
        var candidates: Array = job.get("ownerCandidates", []) as Array
        var owner_index := int(job.get("ownerIndex", 0))
        if owner_index < candidates.size():
            job["ownerIndex"] = owner_index + 1
            var candidate_value = candidates[owner_index]
            if candidate_value is Dictionary:
                var candidate: Dictionary = candidate_value
                var position: Vector3 = job.get("samplePosition", Vector3.INF)
                if _point_within_support_xz(position, candidate):
                    var support_y := float(job.get("sampleSupportY", _support_surface_y(support, position)))
                    var candidate_y := _support_surface_y(candidate, position)
                    if candidate_y >= support_y - BUILDING_SUPPORT_STACK_EPSILON and candidate_y <= support_y + BUILDING_SUPPORT_STACK_MAX_SEPARATION:
                        var candidate_id := String(candidate.get("id", ""))
                        var owner_y := float(job.get("sampleOwnerY", support_y))
                        if candidate_y > owner_y + BUILDING_SUPPORT_STACK_EPSILON or (absf(candidate_y - owner_y) <= BUILDING_SUPPORT_STACK_EPSILON and candidate_id < String(job.get("sampleOwnerId", ""))):
                            job["sampleOwnerId"] = candidate_id
                            job["sampleOwnerY"] = candidate_y
            return
        job["samplePhase"] = "blocker"
        return
    if phase == "blocker":
        var position: Vector3 = job.get("samplePosition", Vector3.INF)
        var sample_cell: Vector2i = job.get("sampleCell", INVALID_CELL)
        if String(job.get("sampleOwnerId", "")) == String(support.get("id", "")):
            var minimum_corner: Vector2 = job.get("sampleMinimumCorner", Vector2.ZERO)
            var maximum_corner := minimum_corner + Vector2(BUILDING_SUPPORT_NAV_SAMPLE_STEP, BUILDING_SUPPORT_NAV_SAMPLE_STEP)
            var minimum_cell := world_cell(Vector3(minimum_corner.x, position.y, minimum_corner.y))
            var maximum_cell := world_cell(Vector3(maximum_corner.x, position.y, maximum_corner.y))
            var records_key := "%d,%d:%d,%d" % [minimum_cell.x, minimum_cell.y, maximum_cell.x, maximum_cell.y]
            var records_by_range: Dictionary = job.get("collisionRecordsByCellRange", {}) as Dictionary
            var records: Array
            if records_by_range.has(records_key):
                records = records_by_range.get(records_key, []) as Array
            else:
                records = _transition_collision_records(job.get("snapshot", {}) as Dictionary, "staticCollisionByCell", minimum_cell, maximum_cell)
                records_by_range[records_key] = records
            var blocker := _building_support_navigation_blocker_from_records(records, support, position.y, minimum_corner, maximum_corner)
            if blocker.is_empty():
                var sample_result := {
                    "navigableCells": job.get("navigableCells", {}),
                    "_navigableCellKeys": job.get("navigableCellKeys", [])
                }
                _record_navigable_support_sample(sample_result, sample_cell, position)
            else:
                (job.get("blockedByCell", {}) as Dictionary)[sample_cell] = blocker
        _advance_building_support_sample_cursor(job)


func _advance_building_support_sample_cursor(job: Dictionary) -> void:
    var x := int(job.get("x", 0)) + 1
    var z := int(job.get("z", 0))
    if x > int(job.get("lastX", x)):
        x = int(job.get("firstX", x))
        z += 1
    job["x"] = x
    job["z"] = z
    job["samplePhase"] = "prepare"
    if z > int(job.get("lastZ", z)):
        job["done"] = true
        job["result"] = {"navigableCells": job.get("navigableCells", {}), "blockedByCell": job.get("blockedByCell", {}), "_navigableCellKeys": job.get("navigableCellKeys", [])}


func _record_navigable_support_sample(sample: Dictionary, sample_cell: Vector2i, position: Vector3) -> void:
    var cells: Dictionary = sample.get("navigableCells", {}) as Dictionary
    if cells.has(sample_cell):
        return
    cells[sample_cell] = position
    var keys: Array = sample.get("_navigableCellKeys", []) as Array
    keys.append(sample_cell)


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


func _new_building_support_navigation_sample_job(support: Dictionary, snapshot: Dictionary, tile_key: String, owner_bounds: Array = []) -> Dictionary:
    var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
    if polygon.size() < 3 or polygon.size() > MAX_SUPPORT_POLYGON_POINTS:
        return {"done": true, "result": {"navigableCells": {}, "blockedByCell": {}, "_navigableCellKeys": []}}
    var tile := _parse_tile_key(tile_key)
    var tile_min_x := (float(tile.x * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_max_x := (float((tile.x + 1) * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_min_z := (float(tile.y * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var tile_max_z := (float((tile.y + 1) * NAV_TILE_CELL_SIZE) - 0.5) * CELL
    var minimum := Vector2(INF, INF)
    var maximum := Vector2(-INF, -INF)
    var support_min_y := INF
    var support_max_y := -INF
    for point_value in polygon:
        if point_value is Vector3:
            var point: Vector3 = point_value
            minimum.x = minf(minimum.x, point.x)
            minimum.y = minf(minimum.y, point.z)
            maximum.x = maxf(maximum.x, point.x)
            maximum.y = maxf(maximum.y, point.z)
            support_min_y = minf(support_min_y, point.y)
            support_max_y = maxf(support_max_y, point.y)
    minimum.x = maxf(minimum.x, tile_min_x)
    minimum.y = maxf(minimum.y, tile_min_z)
    maximum.x = minf(maximum.x, tile_max_x)
    maximum.y = minf(maximum.y, tile_max_z)
    if minimum.x >= maximum.x or minimum.y >= maximum.y:
        return {"done": true, "result": {"navigableCells": {}, "blockedByCell": {}, "_navigableCellKeys": []}}
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
        "samplePhase": "candidate_filter" if not owner_bounds.is_empty() else "prepare",
        "ownerCandidates": [] if not owner_bounds.is_empty() else building_supports_for_tile(tile_key),
        "ownerBounds": owner_bounds,
        "ownerBoundsIndex": 0,
        "supportMinimum": minimum,
        "supportMaximum": maximum,
        "supportMinY": support_min_y,
        "supportMaxY": support_max_y,
        "collisionRecordsByCellRange": {},
        "ownerIndex": 0,
        "navigableCells": {},
        "blockedByCell": {},
        "navigableCellKeys": []
    }


func building_supports_for_tile(tile_key: String) -> Array[Dictionary]:
    var required_support_ids := _building_link_support_ids_for_tile(tile_key)
    var indexed_support_ids := {}
    for support_value in cached_building_supports_by_tile.get(tile_key, []) as Array:
        if support_value is Dictionary:
            indexed_support_ids[String((support_value as Dictionary).get("id", ""))] = true
    var result: Array[Dictionary] = []
    # Preserve the global deterministic support order. A link-owning tile must
    # publish the support polygons named by that link even when an AABB/tile
    # boundary rounds the support's broad tileKeys away from the resolved
    # endpoint tile. Sampling clips those polygons back to this tile, so this
    # repairs ownership without creating a second geometry authority.
    for support_value in cached_building_supports:
        if not (support_value is Dictionary):
            continue
        var support: Dictionary = support_value
        var support_id := String(support.get("id", ""))
        if indexed_support_ids.has(support_id) or required_support_ids.has(support_id):
            result.append(support)
    return result


func _building_link_support_ids_for_tile(tile_key: String) -> Dictionary:
    var result := {}
    for source_value in [
        cached_building_vertical_links_by_tile.get(tile_key, []),
        cached_building_support_seam_links_by_tile.get(tile_key, []),
        cached_building_interior_passage_links_by_tile.get(tile_key, []),
        cached_building_doors_by_tile.get(tile_key, [])
    ]:
        for link_value in source_value as Array:
            if not (link_value is Dictionary):
                continue
            var link: Dictionary = link_value
            for support_key in ["startSupportId", "endSupportId", "interiorSupportId", "exteriorSupportId"]:
                var support_id := String(link.get(support_key, ""))
                if not support_id.is_empty():
                    result[support_id] = true
    # Door links are owned and installed by one tile, while each endpoint must
    # resolve against the navigation region for its own declared tile. Index
    # both endpoint supports by those endpoint tiles without duplicating door
    # link ownership or changing the source manifest.
    for door_value in cached_building_doors:
        if not (door_value is Dictionary):
            continue
        var door: Dictionary = door_value
        if not bool(door.get("sourcePortalReady", false)):
            continue
        if String(door.get("interiorTileKey", "")) == tile_key:
            var interior_support_id := String(door.get("interiorSupportId", ""))
            if not interior_support_id.is_empty():
                result[interior_support_id] = true
        if String(door.get("exteriorTileKey", "")) == tile_key:
            var exterior_support_id := String(door.get("exteriorSupportId", ""))
            if not exterior_support_id.is_empty():
                result[exterior_support_id] = true
    return result


func _parse_tile_key(tile_key: String) -> Vector2i:
    var parts := tile_key.split(",")
    if parts.size() < 2:
        return Vector2i.ZERO
    return Vector2i(int(parts[0]), int(parts[1]))


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


func _append_source_support_edge(adjacency: Dictionary, first: String, second: String) -> void:
    if first.is_empty() or second.is_empty() or first == second or not adjacency.has(first) or not adjacency.has(second):
        return
    if not (adjacency[first] as Array).has(second):
        (adjacency[first] as Array).append(second)
    if not (adjacency[second] as Array).has(first):
        (adjacency[second] as Array).append(first)


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
    var adjacency_result := _source_sample_adjacency(samples_by_support, snapshot)
    if not bool(adjacency_result.get("complete", false)):
        return {"resolutions": [], "incomplete": true, "status": adjacency_result.get("status", "failed"), "reason": adjacency_result.get("reason", "source_sample_adjacency_incomplete"), "sourceCollisionRevision": cached_revision}
    var adjacency: Dictionary = adjacency_result.get("adjacency", {}) as Dictionary
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


func _source_sample_node_key(support_id: String, cell: Vector2i) -> String:
    return "%s|%d,%d" % [support_id, cell.x, cell.y]


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
        var resolution := _append_declared_source_sample_link(adjacency, samples_by_support, snapshot, link, "startSupportId", "endSupportId")
        if bool(resolution.get("incomplete", false)):
            return {"complete": false, "status": resolution.get("status", "failed"), "reason": resolution.get("reason", "declared_link_incomplete")}
    for link in cached_building_interior_passage_links:
        var resolution := _append_declared_source_sample_link(adjacency, samples_by_support, snapshot, link, "firstSupportId", "secondSupportId")
        if bool(resolution.get("incomplete", false)):
            return {"complete": false, "status": resolution.get("status", "failed"), "reason": resolution.get("reason", "declared_link_incomplete")}
    return {"complete": true, "status": "ready", "adjacency": adjacency}


func _append_declared_source_sample_link(adjacency: Dictionary, samples_by_support: Dictionary, snapshot: Dictionary, link: Dictionary, first_key: String, second_key: String) -> Dictionary:
    var resolution := _resolve_declared_source_sample_link(samples_by_support, snapshot, link, first_key, second_key)
    if not bool(resolution.get("resolved", false)):
        return resolution
    _append_source_support_edge(adjacency, String(resolution.get("firstNode", "")), String(resolution.get("secondNode", "")))
    return resolution


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
    if bool(first_resolution.get("incomplete", false)):
        return first_resolution
    var second_resolution := _resolve_building_navigation_link_endpoint(snapshot, second_id, second_position, second_tile_key, transition_axis if kind == "stair_ramp" else Vector3.ZERO)
    if bool(second_resolution.get("incomplete", false)):
        return second_resolution
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


func _resolve_building_navigation_link_endpoint(_snapshot: Dictionary, support_id: String, authored_position: Vector3, tile_key: String, transition_axis := Vector3.ZERO) -> Dictionary:
    # Source-only endpoint drain: same donor target-base payload, tile sampler,
    # certifier and sorted nearest-cell selection, with no runtime producer.
    if tile_key.is_empty() and authored_position.is_finite():
        tile_key = tile_key_for_cell(world_cell(authored_position))
    if support_id.is_empty() or not authored_position.is_finite():
        return {"resolved": false, "reason": "missing_support_or_position"}
    if source_manifest_revision.is_empty() or cached_revision != source_manifest_revision:
        return {"resolved": false, "incomplete": true, "status": "failed", "reason": "source_manifest_revision_changed"}
    if not cached_building_support_ids_valid:
        return {"resolved": false, "incomplete": true, "status": "failed", "reason": "duplicate_building_support_ids"}
    var support: Dictionary = _building_support_by_id(support_id)
    var source_snapshot := _layout_source_tile_snapshot(tile_key)
    var source_supports := building_supports_for_tile(tile_key)
    if transition_axis.length_squared() > 0.0001:
        var acquired_support := {}
        for source_support in source_supports:
            if String(source_support.get("id", "")) == support_id:
                acquired_support = source_support
                break
        if acquired_support.is_empty():
            return {"resolved": false, "reason": "support_not_in_acquired_source", "supportId": support_id}
        support = acquired_support
        var resolution := BuildingNavigationTransitionCertifierScript.certify_endpoint(support, authored_position, transition_axis, BUILDING_SUPPORT_NAV_CLEARANCE, func(position: Vector3) -> Dictionary: return _building_navigation_link_blocker(source_snapshot, support, authored_position, position, BUILDING_SUPPORT_NAV_CLEARANCE))
        resolution["tileKey"] = tile_key
        if bool(resolution.get("resolved", false)):
            resolution["cell"] = world_cell(resolution.get("position", authored_position) as Vector3)
        return resolution
    var source_key := navmesh_tile_source_key_for_tile(tile_key)
    var sample: Dictionary
    if _has_cached_navmesh_support_sample(tile_key, support_id, source_key):
        sample = _cached_navmesh_support_sample(tile_key, support_id, source_key)
    else:
        var sample_job := _new_tile_support_navigation_sample_job(source_supports, source_snapshot, tile_key)
        while not bool(sample_job.get("done", false)):
            _advance_tile_support_navigation_sample_job(sample_job)
        var results: Dictionary = sample_job.get("resultsBySupport", {}) as Dictionary
        # Preserve donor support order and its bounded sample-cache eviction.
        for source_support in source_supports:
            var id := String(source_support.get("id", ""))
            _store_navmesh_support_sample(tile_key, id, results.get(id, {}) as Dictionary, source_key)
        sample = results.get(support_id, {}) as Dictionary
    var sort_job := _new_incremental_sort_job(_navigable_support_sample_keys(sample), "vector2i")
    while not bool(sort_job.get("done", false)):
        _advance_incremental_sort_job(sort_job)
    var keys: Array = sort_job.get("result", []) as Array
    var cells: Dictionary = sample.get("navigableCells", {}) as Dictionary
    var best_position := Vector3.INF
    var best_distance := INF
    var best_cell := Vector2i.ZERO
    for cell_value in keys:
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var candidate: Vector3 = cells.get(cell, Vector3.INF) as Vector3
        if not candidate.is_finite():
            continue
        var distance := candidate.distance_to(authored_position)
        if distance < best_distance - 0.0001 or (is_equal_approx(distance, best_distance) and (cell.x < best_cell.x or (cell.x == best_cell.x and cell.y < best_cell.y))):
            best_position = candidate
            best_distance = distance
            best_cell = cell
    return {"resolved": true, "supportId": support_id, "tileKey": tile_key, "cell": best_cell, "position": best_position, "distance": best_distance} if best_position.is_finite() else {"resolved": false, "reason": "no_collision_screened_support_sample", "supportId": support_id, "tileKey": tile_key}


func _advance_incremental_sort_job(job: Dictionary, deadline_usec := 0) -> void:
    var parent_deadline_usec := _navmesh_nested_work_deadline_usec
    _navmesh_nested_work_deadline_usec = _navmesh_nested_work_deadline(NAVMESH_SORT_ATOMIC_TARGET_USEC, deadline_usec)
    for _item_index in range(NAVMESH_SORT_ITEMS_PER_ATOMIC_UNIT):
        if bool(job.get("done", false)) or Time.get_ticks_usec() >= _navmesh_nested_work_deadline_usec:
            break
        _advance_incremental_sort_job_unit(job)
    _navmesh_nested_work_deadline_usec = parent_deadline_usec


func _advance_incremental_sort_job_unit(job: Dictionary) -> void:
    if bool(job.get("done", false)):
        return
    var source: Array = job.get("source", []) as Array
    var target: Array = job.get("target", []) as Array
    var width := int(job.get("width", 1))
    var run_start := int(job.get("runStart", 0))
    if run_start >= source.size():
        job["source"] = target
        var next_target: Array = []
        next_target.resize(source.size())
        job["target"] = next_target
        job["width"] = width * 2
        job["runStart"] = 0
        job["runReady"] = false
        if width * 2 >= source.size():
            job["done"] = true
            job["result"] = target
        return
    if not bool(job.get("runReady", false)):
        job["left"] = run_start
        job["leftEnd"] = mini(run_start + width, source.size())
        job["right"] = mini(run_start + width, source.size())
        job["rightEnd"] = mini(run_start + width * 2, source.size())
        job["output"] = run_start
        job["runReady"] = true
        return
    var left := int(job.get("left", run_start))
    var left_end := int(job.get("leftEnd", run_start))
    var right := int(job.get("right", run_start))
    var right_end := int(job.get("rightEnd", run_start))
    var output := int(job.get("output", run_start))
    if left >= left_end and right >= right_end:
        job["runStart"] = run_start + width * 2
        job["runReady"] = false
        return
    if right >= right_end or (left < left_end and _incremental_sort_less(source[left], source[right], String(job.get("mode", "variant_text")))):
        target[output] = source[left]
        job["left"] = left + 1
    else:
        target[output] = source[right]
        job["right"] = right + 1
    job["target"] = target
    job["output"] = output + 1


func _incremental_sort_less(left, right, mode: String) -> bool:
    match mode:
        "dictionary_id":
            return String((left as Dictionary).get("id", "")) <= String((right as Dictionary).get("id", ""))
        "dictionary_lane":
            return int((left as Dictionary).get("laneIndex", 0)) <= int((right as Dictionary).get("laneIndex", 0))
        "vector2i":
            var left_cell: Vector2i = left
            var right_cell: Vector2i = right
            return left_cell.x < right_cell.x or (left_cell.x == right_cell.x and left_cell.y <= right_cell.y)
        "vector3i":
            var left_cell: Vector3i = left
            var right_cell: Vector3i = right
            return left_cell.x < right_cell.x \
                or (left_cell.x == right_cell.x and left_cell.y < right_cell.y) \
                or (left_cell.x == right_cell.x and left_cell.y == right_cell.y and left_cell.z <= right_cell.z)
        "integer":
            return int(left) <= int(right)
        "transition_sample":
            return "%s|%s" % [String((left as Dictionary).get("tileKey", "")), String((left as Dictionary).get("supportId", ""))] <= "%s|%s" % [String((right as Dictionary).get("tileKey", "")), String((right as Dictionary).get("supportId", ""))]
        _:
            return str(left) <= str(right)


func _navmesh_nested_work_deadline(target_usec: int, requested_deadline_usec := 0) -> int:
    var deadline_usec := Time.get_ticks_usec() + target_usec
    if _navmesh_nested_work_deadline_usec > 0:
        deadline_usec = mini(deadline_usec, _navmesh_nested_work_deadline_usec)
    if requested_deadline_usec > 0:
        deadline_usec = mini(deadline_usec, requested_deadline_usec)
    return deadline_usec


func _navigable_support_sample_keys(sample: Dictionary) -> Array:
    var emitted_keys = sample.get("_navigableCellKeys", [])
    if emitted_keys is Array and not (emitted_keys as Array).is_empty():
        return emitted_keys as Array
    var ordered_keys = sample.get("_orderedNavigableCellKeys", [])
    if ordered_keys is Array and not (ordered_keys as Array).is_empty():
        return ordered_keys as Array
    var cells: Dictionary = sample.get("navigableCells", {}) as Dictionary
    # Legacy/synthetic small samples may predate the derived index. Keep their
    # compatibility path explicitly bounded; large production samples must
    # arrive with the cursor-produced index and otherwise fail at their owner.
    return cells.keys() if cells.size() <= MAX_UNINDEXED_SUPPORT_SAMPLE_CELLS else []


func _new_incremental_sort_job(values: Array, mode: String) -> Dictionary:
    if values.size() <= 1:
        return {"done": true, "result": values.duplicate(), "mode": mode}
    var source := values.duplicate()
    var target: Array = []
    target.resize(values.size())
    return {"done": false, "source": source, "target": target, "mode": mode, "width": 1, "runStart": 0, "left": 0, "leftEnd": 0, "right": 0, "rightEnd": 0, "output": 0, "runReady": false}


func _store_navmesh_support_sample(tile_key: String, support_id: String, sample: Dictionary, source_key := "", ordered_keys = null) -> void:
    if tile_key.is_empty() or support_id.is_empty():
        return
    var cache_key := _navmesh_support_sample_cache_key(tile_key, support_id, source_key)
    if sample.is_empty():
        navmesh_support_sample_cache.erase(cache_key)
        navmesh_support_sample_empty_cache[cache_key] = true
    else:
        navmesh_support_sample_empty_cache.erase(cache_key)
        navmesh_support_sample_cache[cache_key] = sample
    if ordered_keys is Array:
        navmesh_support_sample_ordered_keys_cache[cache_key] = (ordered_keys as Array).duplicate()
    else:
        navmesh_support_sample_ordered_keys_cache.erase(cache_key)
    navmesh_support_sample_cache_order.erase(cache_key)
    navmesh_support_sample_cache_order.append(cache_key)
    while navmesh_support_sample_cache_order.size() > NAVMESH_SUPPORT_SAMPLE_CACHE_LIMIT:
        var evicted := String(navmesh_support_sample_cache_order.pop_front())
        navmesh_support_sample_cache.erase(evicted)
        navmesh_support_sample_empty_cache.erase(evicted)
        navmesh_support_sample_ordered_keys_cache.erase(evicted)


func _navmesh_support_sample_cache_key(tile_key: String, support_id: String, source_key := "") -> String:
    var revision_key := source_key if not String(source_key).is_empty() else navmesh_tile_source_key_for_tile(tile_key)
    return "%s|%s|%s" % [tile_key, revision_key, support_id]


func navmesh_tile_source_key_for_tile(_tile_key: String) -> String:
    return "manifest:%s" % source_manifest_revision


func _advance_tile_support_navigation_sample_job(job: Dictionary, deadline_usec := 0) -> void:
    var started_usec := Time.get_ticks_usec()
    var processed_steps := 0
    while not bool(job.get("done", false)) and processed_steps < NAVMESH_SUPPORT_SAMPLE_STEPS_PER_ATOMIC_UNIT:
        if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
            break
        _advance_tile_support_navigation_sample_step(job)
        processed_steps += 1
        if Time.get_ticks_usec() - started_usec >= NAVMESH_SUPPORT_SAMPLE_ATOMIC_TARGET_USEC:
            break


func _advance_tile_support_navigation_sample_step(job: Dictionary) -> void:
    match String(job.get("phase", "initialize")):
        "initialize":
            _advance_tile_support_sample_initialize(job)
        "index_rows":
            _advance_tile_support_sample_index_row(job)
        "prepare_cell":
            if _tile_support_sample_fast_cell_eligible(job):
                _advance_tile_support_sample_cell(job)
                if not bool(job.get("done", false)):
                    job["phase"] = "prepare_cell"
            else:
                _advance_tile_support_sample_prepare_cell(job)
        "prepare_cell_prune":
            _advance_tile_support_sample_prepare_cell_prune(job)
        "prepare_cell_add":
            _advance_tile_support_sample_prepare_cell_add(job)
        "prepare_cell_merge":
            _advance_tile_support_sample_prepare_cell_merge(job)
        "collect_hits":
            _advance_tile_support_sample_collect_hit(job)
        "resolve_owners":
            _advance_tile_support_sample_resolve_owner(job)
        "emit_owners":
            _advance_tile_support_sample_emit_owner(job)
        "emit_uniform_run":
            _advance_tile_support_sample_uniform_run(job)
        "advance_cell":
            _advance_tile_support_sample_cursor(job)
        _:
            job["done"] = true
            job["reason"] = "invalid_tile_support_sample_phase"


func _advance_tile_support_sample_cursor(job: Dictionary) -> void:
    var x := int(job.get("x", 0)) + 1
    var z := int(job.get("z", 0))
    if x > int(job.get("lastX", x)):
        x = int(job.get("firstX", x))
        z += 1
        job["rowSpanCursor"] = 0
        job["activeSpans"] = []
    job["x"] = x
    job["z"] = z
    job["supportSpanIndex"] = 0
    job["cellHits"] = []
    job["cellOwners"] = []
    job["ownershipIndex"] = 0
    job["ownerCandidateIndex"] = 0
    job["emitIndex"] = 0
    job.erase("prepareRetainedSpans")
    job.erase("prepareAddedSpans")
    job.erase("prepareMergedSpans")
    job.erase("prepareActiveIndex")
    job.erase("prepareRetainedIndex")
    job.erase("prepareAddedIndex")
    if z > int(job.get("lastZ", z)):
        job["done"] = true
    else:
        job["phase"] = "prepare_cell"


func _advance_tile_support_sample_uniform_run(job: Dictionary) -> void:
    var spans: Array = job.get("activeSpans", []) as Array
    if spans.size() != 1 or not (spans[0] is Dictionary):
        job["phase"] = "prepare_cell"
        return
    var supports: Array = job.get("supports", []) as Array
    var support_index := int((spans[0] as Dictionary).get("supportIndex", -1))
    if support_index < 0 or support_index >= supports.size() or not (supports[support_index] is Dictionary):
        job["phase"] = "collect_hits"
        return
    var support: Dictionary = supports[support_index] as Dictionary
    var support_id := String(support.get("id", ""))
    var z := int(job.get("z", 0))
    var x := int(job.get("x", 0))
    var run_end := int(job.get("uniformRunEndX", x - 1))
    var started_usec := Time.get_ticks_usec()
    var processed := 0
    while x <= run_end and processed < NAVMESH_SUPPORT_SAMPLE_UNIFORM_RUN_CELLS_PER_STEP:
        var position := Vector3((float(x) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, 0.0, (float(z) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
        if _point_within_support_xz(position, support):
            _emit_tile_support_sample_owner(job, {
                "support": support,
                "supportId": support_id,
                "surfaceY": _support_surface_y(support, position)
            }, x, z)
        x += 1
        processed += 1
        if Time.get_ticks_usec() - started_usec >= NAVMESH_SUPPORT_SAMPLE_UNIFORM_RUN_TARGET_USEC:
            break
    job["uniformRunCellCount"] = int(job.get("uniformRunCellCount", 0)) + processed
    job["uniformRunStepCount"] = int(job.get("uniformRunStepCount", 0)) + 1
    if x <= run_end:
        job["x"] = x
        return
    # Re-enter the ordinary cursor path at the first ownership boundary. This
    # preserves row rotation and overlap ordering without replaying the cells
    # already certified by the uniform run.
    job["x"] = x - 1
    job.erase("uniformRunEndX")
    job["phase"] = "advance_cell"


func _emit_tile_support_sample_owner(job: Dictionary, owner: Dictionary, x: int, z: int) -> void:
    var support: Dictionary = owner.get("support", {}) as Dictionary
    var support_id := String(owner.get("supportId", ""))
    var sample_cell := Vector2i(x, z)
    var surface_position := Vector3((float(x) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, float(owner.get("surfaceY", 0.0)) + 0.04, (float(z) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var minimum_corner := Vector2(float(x) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, float(z) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var maximum_corner := minimum_corner + Vector2(BUILDING_SUPPORT_NAV_SAMPLE_STEP, BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var minimum_cell := world_cell(Vector3(minimum_corner.x, surface_position.y, minimum_corner.y))
    var maximum_cell := world_cell(Vector3(maximum_corner.x, surface_position.y, maximum_corner.y))
    var records_key := "%d,%d:%d,%d" % [minimum_cell.x, minimum_cell.y, maximum_cell.x, maximum_cell.y]
    var records_by_range: Dictionary = job.get("collisionRecordsByCellRange", {}) as Dictionary
    var records: Array
    if records_by_range.has(records_key):
        records = records_by_range.get(records_key, []) as Array
    else:
        records = _transition_collision_records(job.get("snapshot", {}) as Dictionary, "staticCollisionByCell", minimum_cell, maximum_cell)
        records_by_range[records_key] = records
    var blocker := _building_support_navigation_blocker_from_records(records, support, surface_position.y, minimum_corner, maximum_corner)
    var result: Dictionary = (job.get("resultsBySupport", {}) as Dictionary).get(support_id, {}) as Dictionary
    if blocker.is_empty():
        _record_navigable_tile_support_sample(job, support, result, sample_cell, surface_position)
        var support_columns: Dictionary = (job.get("navigableCellsBySupportX", {}) as Dictionary).get(support_id, {}) as Dictionary
        if not support_columns.has(x):
            support_columns[x] = []
        (support_columns.get(x, []) as Array).append(sample_cell)
    else:
        (result.get("blockedByCell", {}) as Dictionary)[sample_cell] = blocker


func _record_navigable_tile_support_sample(job: Dictionary, support: Dictionary, sample: Dictionary, sample_cell: Vector2i, position: Vector3) -> void:
    var cells: Dictionary = sample.get("navigableCells", {}) as Dictionary
    if cells.has(sample_cell):
        return
    _record_navigable_support_sample(sample, sample_cell, position)
    var normal: Vector3 = support.get("floorNormal", Vector3.UP) if support.get("floorNormal", Vector3.UP) is Vector3 else Vector3.UP
    if normal.normalized().y < 0.985:
        return
    var support_id := String(support.get("id", ""))
    var layer_key := str(roundi(position.y * 100.0))
    var layer_cells: Dictionary = job.get("supportSurfaceLayerCells", {}) as Dictionary
    var layer_columns_by_row: Dictionary = job.get("supportSurfaceLayerColumnsByRow", {}) as Dictionary
    var layer_height: Dictionary = job.get("supportSurfaceLayerHeight", {}) as Dictionary
    if not layer_cells.has(layer_key):
        layer_cells[layer_key] = {}
        layer_columns_by_row[layer_key] = {}
        layer_height[layer_key] = position.y - 0.04
    var cells_for_layer: Dictionary = layer_cells.get(layer_key, {}) as Dictionary
    if not cells_for_layer.has(sample_cell):
        cells_for_layer[sample_cell] = position
        var columns_by_row: Dictionary = layer_columns_by_row.get(layer_key, {}) as Dictionary
        if not columns_by_row.has(sample_cell.y):
            columns_by_row[sample_cell.y] = []
        (columns_by_row.get(sample_cell.y, []) as Array).append(sample_cell.x)
    var keys_by_support: Dictionary = job.get("supportSurfaceLayerKeysBySupport", {}) as Dictionary
    if not keys_by_support.has(support_id):
        keys_by_support[support_id] = {}
    (keys_by_support.get(support_id, {}) as Dictionary)[layer_key] = true


func _advance_tile_support_sample_emit_owner(job: Dictionary) -> void:
    var owners: Array = job.get("cellOwners", []) as Array
    var emit_index := int(job.get("emitIndex", 0))
    if emit_index >= owners.size():
        job["phase"] = "advance_cell"
        return
    job["emitIndex"] = emit_index + 1
    var owner: Dictionary = owners[emit_index] as Dictionary
    _emit_tile_support_sample_owner(job, owner, int(job.get("x", 0)), int(job.get("z", 0)))


func _advance_tile_support_sample_resolve_owner(job: Dictionary) -> void:
    var hits: Array = job.get("cellHits", []) as Array
    var ownership_index := int(job.get("ownershipIndex", 0))
    if ownership_index >= hits.size():
        job["emitIndex"] = 0
        job["phase"] = "emit_owners"
        return
    var hit: Dictionary = hits[ownership_index] as Dictionary
    var candidate_index := int(job.get("ownerCandidateIndex", 0))
    if candidate_index == 0:
        job["currentOwnerId"] = String(hit.get("supportId", ""))
        job["currentOwnerY"] = float(hit.get("surfaceY", 0.0))
    if candidate_index < hits.size():
        job["ownerCandidateIndex"] = candidate_index + 1
        var candidate: Dictionary = hits[candidate_index] as Dictionary
        var support_y := float(hit.get("surfaceY", 0.0))
        var candidate_y := float(candidate.get("surfaceY", 0.0))
        if candidate_y >= support_y - BUILDING_SUPPORT_STACK_EPSILON and candidate_y <= support_y + BUILDING_SUPPORT_STACK_MAX_SEPARATION:
            var candidate_id := String(candidate.get("supportId", ""))
            var owner_y := float(job.get("currentOwnerY", support_y))
            if candidate_y > owner_y + BUILDING_SUPPORT_STACK_EPSILON or (absf(candidate_y - owner_y) <= BUILDING_SUPPORT_STACK_EPSILON and candidate_id < String(job.get("currentOwnerId", ""))):
                job["currentOwnerId"] = candidate_id
                job["currentOwnerY"] = candidate_y
        return
    if String(job.get("currentOwnerId", "")) == String(hit.get("supportId", "")):
        (job.get("cellOwners", []) as Array).append(hit)
    job["ownershipIndex"] = ownership_index + 1
    job["ownerCandidateIndex"] = 0


func _advance_tile_support_sample_collect_hit(job: Dictionary) -> void:
    var supports: Array = job.get("supports", []) as Array
    var spans: Array = job.get("activeSpans", []) as Array
    var span_index := int(job.get("supportSpanIndex", 0))
    if span_index >= spans.size():
        job["ownershipIndex"] = 0
        job["ownerCandidateIndex"] = 0
        job["phase"] = "resolve_owners"
        return
    job["supportSpanIndex"] = span_index + 1
    var span: Dictionary = spans[span_index] as Dictionary
    var support_index := int(span.get("supportIndex", -1))
    if support_index < 0 or support_index >= supports.size():
        return
    var support_value = supports[support_index]
    if not (support_value is Dictionary):
        return
    var support: Dictionary = support_value
    var position := Vector3((float(job.get("x", 0)) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, 0.0, (float(job.get("z", 0)) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    if not _point_within_support_xz(position, support):
        return
    var surface_y := _support_surface_y(support, position)
    (job.get("cellHits", []) as Array).append({
        "support": support,
        "supportId": String(support.get("id", "")),
        "surfaceY": surface_y
    })


func _advance_tile_support_sample_prepare_cell_merge(job: Dictionary) -> void:
    var retained: Array = job.get("prepareRetainedSpans", []) as Array
    var added: Array = job.get("prepareAddedSpans", []) as Array
    var retained_index := int(job.get("prepareRetainedIndex", 0))
    var added_index := int(job.get("prepareAddedIndex", 0))
    if retained_index >= retained.size() and added_index >= added.size():
        job["activeSpans"] = job.get("prepareMergedSpans", [])
        job["supportSpanIndex"] = 0
        var uniform_run_end := _tile_support_sample_uniform_run_end(job)
        if uniform_run_end >= int(job.get("x", 0)):
            job["uniformRunEndX"] = uniform_run_end
            job["phase"] = "emit_uniform_run"
        else:
            job["phase"] = "collect_hits"
        return
    var take_retained := added_index >= added.size()
    if not take_retained and retained_index < retained.size():
        var retained_support_index := int((retained[retained_index] as Dictionary).get("supportIndex", 0))
        var added_support_index := int((added[added_index] as Dictionary).get("supportIndex", 0))
        take_retained = retained_support_index <= added_support_index
    if take_retained:
        (job.get("prepareMergedSpans", []) as Array).append(retained[retained_index])
        job["prepareRetainedIndex"] = retained_index + 1
    else:
        (job.get("prepareMergedSpans", []) as Array).append(added[added_index])
        job["prepareAddedIndex"] = added_index + 1


func _tile_support_sample_uniform_run_end(job: Dictionary) -> int:
    var x := int(job.get("x", 0))
    var spans: Array = job.get("activeSpans", []) as Array
    if spans.size() != 1 or not (spans[0] is Dictionary):
        return x - 1
    var run_end := int((spans[0] as Dictionary).get("lastX", x - 1))
    var z := int(job.get("z", 0))
    var row_spans: Array = (job.get("supportSpansByRow", {}) as Dictionary).get(z, []) as Array
    var row_cursor := int(job.get("rowSpanCursor", 0))
    if row_cursor < row_spans.size() and row_spans[row_cursor] is Dictionary:
        # Stop immediately before another support's conservative XZ bound
        # begins. Within this interval there is exactly one possible owner;
        # polygon containment and collision/blocker certification still run for
        # every emitted lattice cell below.
        run_end = mini(run_end, int((row_spans[row_cursor] as Dictionary).get("firstX", run_end + 1)) - 1)
    return run_end


func _advance_tile_support_sample_prepare_cell_add(job: Dictionary) -> void:
    var x := int(job.get("x", 0))
    var z := int(job.get("z", 0))
    var row_spans: Array = (job.get("supportSpansByRow", {}) as Dictionary).get(z, []) as Array
    var row_cursor := int(job.get("rowSpanCursor", 0))
    if row_cursor < row_spans.size():
        var span: Dictionary = row_spans[row_cursor] as Dictionary
        if int(span.get("firstX", x + 1)) <= x:
            job["rowSpanCursor"] = row_cursor + 1
            if int(span.get("lastX", x - 1)) >= x:
                (job.get("prepareAddedSpans", []) as Array).append(span)
            return
    job["phase"] = "prepare_cell_merge"


func _advance_tile_support_sample_prepare_cell_prune(job: Dictionary) -> void:
    var active: Array = job.get("activeSpans", []) as Array
    var active_index := int(job.get("prepareActiveIndex", 0))
    if active_index < active.size():
        job["prepareActiveIndex"] = active_index + 1
        var span_value = active[active_index]
        if span_value is Dictionary and int((span_value as Dictionary).get("lastX", int(job.get("x", 0)) - 1)) >= int(job.get("x", 0)):
            (job.get("prepareRetainedSpans", []) as Array).append(span_value)
        return
    var x := int(job.get("x", 0))
    var z := int(job.get("z", 0))
    var row_spans: Array = (job.get("supportSpansByRow", {}) as Dictionary).get(z, []) as Array
    var row_cursor := int(job.get("rowSpanCursor", 0))
    var retained: Array = job.get("prepareRetainedSpans", []) as Array
    # Preserve the monolithic sampler's deterministic empty-gap jump without
    # turning the skipped lattice cells into hidden atomic work.
    if retained.is_empty():
        if row_cursor >= row_spans.size():
            job["x"] = int(job.get("lastX", x))
            job["phase"] = "advance_cell"
            return
        var next_span: Dictionary = row_spans[row_cursor] as Dictionary
        var next_x := int(next_span.get("firstX", x))
        if next_x > x:
            job["x"] = next_x
    job["phase"] = "prepare_cell_add"


func _advance_tile_support_sample_prepare_cell(job: Dictionary) -> void:
    job["prepareRetainedSpans"] = []
    job["prepareAddedSpans"] = []
    job["prepareMergedSpans"] = []
    job["prepareActiveIndex"] = 0
    job["prepareRetainedIndex"] = 0
    job["prepareAddedIndex"] = 0
    job["phase"] = "prepare_cell_prune"


func _advance_tile_support_sample_cell(job: Dictionary) -> void:
    var x := int(job.get("x", 0))
    var z := int(job.get("z", 0))
    var row_spans: Array = (job.get("supportSpansByRow", {}) as Dictionary).get(z, []) as Array
    var active: Array = job.get("activeSpans", []) as Array
    var retained: Array = []
    for span_value in active:
        if span_value is Dictionary and int((span_value as Dictionary).get("lastX", x - 1)) >= x:
            retained.append(span_value)
    var row_cursor := int(job.get("rowSpanCursor", 0))
    # The union bounding rectangle can contain long gaps between disjoint
    # supports. Those cells cannot contribute a sample, owner, or blocker, so
    # jump to the next indexed span instead of paying one atomic unit per empty
    # lattice cell. The span itself still enters through the normal ordered
    # path below, preserving containment and ownership semantics.
    if retained.is_empty():
        if row_cursor >= row_spans.size():
            job["x"] = int(job.get("lastX", x))
            _advance_tile_support_sample_cursor(job)
            job["phase"] = "raster_cells" if not bool(job.get("done", false)) else String(job.get("phase", "raster_cells"))
            return
        var next_span: Dictionary = row_spans[row_cursor] as Dictionary
        var next_x := int(next_span.get("firstX", x))
        if next_x > x:
            x = next_x
            job["x"] = x
    while row_cursor < row_spans.size():
        var row_span: Dictionary = row_spans[row_cursor] as Dictionary
        if int(row_span.get("firstX", x + 1)) > x:
            break
        if int(row_span.get("lastX", x - 1)) >= x:
            var support_index := int(row_span.get("supportIndex", 0))
            var insert_index := retained.size()
            while insert_index > 0 and int((retained[insert_index - 1] as Dictionary).get("supportIndex", 0)) > support_index:
                insert_index -= 1
            retained.insert(insert_index, row_span)
        row_cursor += 1
    job["activeSpans"] = retained
    job["rowSpanCursor"] = row_cursor
    var supports: Array = job.get("supports", []) as Array
    var sample_xz := Vector3((float(x) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, 0.0, (float(z) + 0.5) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var hits: Array[Dictionary] = []
    for span_value in retained:
        var span: Dictionary = span_value as Dictionary
        var support_index := int(span.get("supportIndex", -1))
        if support_index < 0 or support_index >= supports.size() or not (supports[support_index] is Dictionary):
            continue
        var support: Dictionary = supports[support_index] as Dictionary
        if not _point_within_support_xz(sample_xz, support):
            continue
        hits.append({"support": support, "supportId": String(support.get("id", "")), "surfaceY": _support_surface_y(support, sample_xz)})
    var owners: Array[Dictionary] = []
    for hit in hits:
        var support_y := float(hit.get("surfaceY", 0.0))
        var owner_id := String(hit.get("supportId", ""))
        var owner_y := support_y
        for candidate in hits:
            var candidate_y := float(candidate.get("surfaceY", 0.0))
            if candidate_y < support_y - BUILDING_SUPPORT_STACK_EPSILON or candidate_y > support_y + BUILDING_SUPPORT_STACK_MAX_SEPARATION:
                continue
            var candidate_id := String(candidate.get("supportId", ""))
            if candidate_y > owner_y + BUILDING_SUPPORT_STACK_EPSILON or (absf(candidate_y - owner_y) <= BUILDING_SUPPORT_STACK_EPSILON and candidate_id < owner_id):
                owner_id = candidate_id
                owner_y = candidate_y
        if owner_id == String(hit.get("supportId", "")):
            owners.append(hit)
    var sample_cell := Vector2i(x, z)
    var minimum_corner := Vector2(float(x) * BUILDING_SUPPORT_NAV_SAMPLE_STEP, float(z) * BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var maximum_corner := minimum_corner + Vector2(BUILDING_SUPPORT_NAV_SAMPLE_STEP, BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var records_by_range: Dictionary = job.get("collisionRecordsByCellRange", {}) as Dictionary
    for owner in owners:
        var support: Dictionary = owner.get("support", {}) as Dictionary
        var support_id := String(owner.get("supportId", ""))
        var surface_position := Vector3(sample_xz.x, float(owner.get("surfaceY", 0.0)) + 0.04, sample_xz.z)
        var minimum_cell := world_cell(Vector3(minimum_corner.x, surface_position.y, minimum_corner.y))
        var maximum_cell := world_cell(Vector3(maximum_corner.x, surface_position.y, maximum_corner.y))
        var records_key := "%d,%d:%d,%d" % [minimum_cell.x, minimum_cell.y, maximum_cell.x, maximum_cell.y]
        var records: Array
        if records_by_range.has(records_key):
            records = records_by_range.get(records_key, []) as Array
        else:
            records = _transition_collision_records(job.get("snapshot", {}) as Dictionary, "staticCollisionByCell", minimum_cell, maximum_cell)
            records_by_range[records_key] = records
        var blocker := _building_support_navigation_blocker_from_records(records, support, surface_position.y, minimum_corner, maximum_corner)
        var result: Dictionary = (job.get("resultsBySupport", {}) as Dictionary).get(support_id, {}) as Dictionary
        if blocker.is_empty():
            _record_navigable_tile_support_sample(job, support, result, sample_cell, surface_position)
        else:
            (result.get("blockedByCell", {}) as Dictionary)[sample_cell] = blocker
    x += 1
    if x > int(job.get("lastX", x)):
        x = int(job.get("firstX", x))
        z += 1
        job["rowSpanCursor"] = 0
        job["activeSpans"] = []
    job["x"] = x
    job["z"] = z
    job["cellHits"] = []
    job["cellOwners"] = []
    if z > int(job.get("lastZ", z)):
        job["done"] = true


func _tile_support_sample_fast_cell_eligible(job: Dictionary) -> bool:
    var z := int(job.get("z", 0))
    var row_spans: Array = (job.get("supportSpansByRow", {}) as Dictionary).get(z, []) as Array
    # The monolithic path is the same deterministic sampler expressed without
    # per-field cursor dispatch. Keep its candidate set explicitly bounded so
    # unusually dense stacked geometry remains on the fully split state machine.
    return row_spans.size() <= NAVMESH_TILE_SUPPORT_FAST_CELL_MAX_ROW_SPANS


func _advance_tile_support_sample_index_row(job: Dictionary) -> void:
    var bounds: Array = job.get("supportBounds", []) as Array
    var support_index := int(job.get("rowSupportIndex", 0))
    if support_index >= bounds.size():
        job["rowSpanCursor"] = 0
        job["activeSpans"] = []
        job["phase"] = "prepare_cell"
        return
    var bound: Dictionary = bounds[support_index] as Dictionary if bounds[support_index] is Dictionary else {}
    if bound.is_empty() or int(bound.get("firstX", 1)) > int(bound.get("lastX", 0)) or int(bound.get("firstZ", 1)) > int(bound.get("lastZ", 0)):
        job["rowSupportIndex"] = support_index + 1
        job.erase("rowIndex")
        return
    var row := int(job.get("rowIndex", int(bound.get("firstZ", 0))))
    var spans_by_row: Dictionary = job.get("supportSpansByRow", {}) as Dictionary
    if not spans_by_row.has(row):
        spans_by_row[row] = []
    var row_spans: Array = spans_by_row[row] as Array
    var span := {"supportIndex": support_index, "firstX": int(bound.get("firstX", 0)), "lastX": int(bound.get("lastX", -1))}
    var insert_index := row_spans.size()
    while insert_index > 0:
        var previous: Dictionary = row_spans[insert_index - 1] as Dictionary
        if int(previous.get("firstX", 0)) < int(span.get("firstX", 0)) or (int(previous.get("firstX", 0)) == int(span.get("firstX", 0)) and int(previous.get("supportIndex", 0)) <= support_index):
            break
        insert_index -= 1
    row_spans.insert(insert_index, span)
    row += 1
    if row > int(bound.get("lastZ", row - 1)):
        job["rowSupportIndex"] = support_index + 1
        job.erase("rowIndex")
    else:
        job["rowIndex"] = row


func _advance_tile_support_sample_initialize(job: Dictionary) -> void:
    var supports: Array = job.get("supports", []) as Array
    var index := int(job.get("initializeIndex", 0))
    if index >= supports.size():
        var minimum: Vector2 = job.get("minimum", Vector2(INF, INF))
        var maximum: Vector2 = job.get("maximum", Vector2(-INF, -INF))
        if not minimum.is_finite() or not maximum.is_finite() or minimum.x >= maximum.x or minimum.y >= maximum.y:
            job["done"] = true
            return
        var first_x := ceili((minimum.x - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
        var last_x := floori((maximum.x - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
        var first_z := ceili((minimum.y - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
        var last_z := floori((maximum.y - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
        if first_x > last_x or first_z > last_z:
            job["done"] = true
            return
        job["firstX"] = first_x
        job["lastX"] = last_x
        job["lastZ"] = last_z
        job["x"] = first_x
        job["z"] = first_z
        job["rowSupportIndex"] = 0
        job["phase"] = "index_rows"
        return
    job["initializeIndex"] = index + 1
    var support_value = supports[index]
    if not (support_value is Dictionary):
        (job.get("supportBounds", []) as Array).append({})
        return
    var support: Dictionary = support_value
    var support_id := String(support.get("id", ""))
    (job.get("resultsBySupport", {}) as Dictionary)[support_id] = {
        "navigableCells": {}, "blockedByCell": {}, "_navigableCellKeys": []
    }
    (job.get("navigableCellsBySupportX", {}) as Dictionary)[support_id] = {}
    (job.get("supportSurfaceLayerKeysBySupport", {}) as Dictionary)[support_id] = {}
    var support_minimum := Vector2(INF, INF)
    var support_maximum := Vector2(-INF, -INF)
    for point_value in support.get("polygon", []) as Array:
        if point_value is Vector3:
            var point: Vector3 = point_value
            support_minimum.x = minf(support_minimum.x, point.x)
            support_minimum.y = minf(support_minimum.y, point.z)
            support_maximum.x = maxf(support_maximum.x, point.x)
            support_maximum.y = maxf(support_maximum.y, point.z)
    support_minimum.x = maxf(support_minimum.x, float(job.get("tileMinX", support_minimum.x)))
    support_minimum.y = maxf(support_minimum.y, float(job.get("tileMinZ", support_minimum.y)))
    support_maximum.x = minf(support_maximum.x, float(job.get("tileMaxX", support_maximum.x)))
    support_maximum.y = minf(support_maximum.y, float(job.get("tileMaxZ", support_maximum.y)))
    var support_first_x := ceili((support_minimum.x - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var support_last_x := floori((support_maximum.x - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var support_first_z := ceili((support_minimum.y - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    var support_last_z := floori((support_maximum.y - BUILDING_SUPPORT_NAV_SAMPLE_STEP * 0.5) / BUILDING_SUPPORT_NAV_SAMPLE_STEP)
    (job.get("supportBounds", []) as Array).append({"minimum": support_minimum, "maximum": support_maximum, "firstX": support_first_x, "lastX": support_last_x, "firstZ": support_first_z, "lastZ": support_last_z})
    var minimum: Vector2 = job.get("minimum", Vector2(INF, INF))
    var maximum: Vector2 = job.get("maximum", Vector2(-INF, -INF))
    minimum.x = minf(minimum.x, support_minimum.x)
    minimum.y = minf(minimum.y, support_minimum.y)
    maximum.x = maxf(maximum.x, support_maximum.x)
    maximum.y = maxf(maximum.y, support_maximum.y)
    job["minimum"] = minimum
    job["maximum"] = maximum


func _new_tile_support_navigation_sample_job(supports: Array, snapshot: Dictionary, tile_key: String) -> Dictionary:
    var tile := _parse_tile_key(tile_key)
    return {
        "done": false,
        "phase": "initialize",
        "supports": supports,
        "snapshot": snapshot,
        "tileKey": tile_key,
        "tileMinX": (float(tile.x * NAV_TILE_CELL_SIZE) - 0.5) * CELL,
        "tileMaxX": (float((tile.x + 1) * NAV_TILE_CELL_SIZE) - 0.5) * CELL,
        "tileMinZ": (float(tile.y * NAV_TILE_CELL_SIZE) - 0.5) * CELL,
        "tileMaxZ": (float((tile.y + 1) * NAV_TILE_CELL_SIZE) - 0.5) * CELL,
        "initializeIndex": 0,
        "minimum": Vector2(INF, INF),
        "maximum": Vector2(-INF, -INF),
        "supportBounds": [],
        "supportSpansByRow": {},
        "resultsBySupport": {},
        "navigableCellsBySupportX": {},
        "supportSurfaceLayerCells": {},
        "supportSurfaceLayerColumnsByRow": {},
        "supportSurfaceLayerHeight": {},
        "supportSurfaceLayerKeysBySupport": {},
        "collisionRecordsByCellRange": {},
        "cellHits": [],
        "cellOwners": []
    }


func _cached_navmesh_support_sample(tile_key: String, support_id: String, source_key := "") -> Dictionary:
    var cache_key := _navmesh_support_sample_cache_key(tile_key, support_id, source_key)
    if not navmesh_support_sample_cache.has(cache_key) and not navmesh_support_sample_empty_cache.has(cache_key):
        return {}
    navmesh_support_sample_cache_hit_count += 1
    navmesh_support_sample_cache_order.erase(cache_key)
    navmesh_support_sample_cache_order.append(cache_key)
    return navmesh_support_sample_cache.get(cache_key, {}) as Dictionary


func _has_cached_navmesh_support_sample(tile_key: String, support_id: String, source_key := "") -> bool:
    var cache_key := _navmesh_support_sample_cache_key(tile_key, support_id, source_key)
    return navmesh_support_sample_cache.has(cache_key) or navmesh_support_sample_empty_cache.has(cache_key)


func _layout_source_tile_snapshot(tile_key: String) -> Dictionary:
    # Exact fields consumed by donor clearance tests after an immutable source
    # base completes. Its payload uses global cell indexes and tile broad lists;
    # do NOT refilter nominal-tile bounds or substitute global broad records.
    var has_payload := cached_static_collision_by_tile.has(tile_key) or cached_door_collision_by_tile.has(tile_key)
    return {
        "staticCollision": cached_static_collision_by_tile.get(tile_key, []),
        "staticCollisionByCell": cached_static_collision_by_cell if has_payload else {},
        "staticCollisionBroad": cached_static_collision_broad_by_tile.get(tile_key, []),
        "doorCollision": cached_door_collision_by_tile.get(tile_key, []),
        "doorCollisionByCell": cached_door_collision_by_cell if has_payload else {},
        "doorCollisionBroad": cached_door_collision_broad_by_tile.get(tile_key, []),
        "navmeshBaseTileKey": tile_key,
        "navmeshBaseSourceKey": navmesh_tile_source_key_for_tile(tile_key)
    }


func tile_key_for_cell(cell: Vector2i) -> String:
    return "%d,%d" % [floori(float(cell.x) / float(NAV_TILE_CELL_SIZE)), floori(float(cell.y) / float(NAV_TILE_CELL_SIZE))]


func _building_navigation_link_endpoint_tile_key(link: Dictionary, endpoint: String, position: Vector3) -> String:
    var declared_tile_key := String(link.get("%sTileKey" % endpoint.capitalize(), ""))
    if not declared_tile_key.is_empty():
        return declared_tile_key
    if position.is_finite():
        return tile_key_for_cell(world_cell(position))
    return _building_navigation_link_owner_tile_key(link)


func _building_navigation_link_owner_tile_key(link: Dictionary) -> String:
    var owner_tile_key := String(link.get("ownerTileKey", ""))
    if not owner_tile_key.is_empty():
        return owner_tile_key
    var start: Vector3 = link.get("start", Vector3.INF) as Vector3
    if start.is_finite():
        return tile_key_for_cell(world_cell(start))
    var tile_keys: Array = link.get("tileKeys", []) if link.get("tileKeys", []) is Array else []
    return String(tile_keys[0]) if not tile_keys.is_empty() else ""


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


func _load_source_navigation_manifests(building_manifest: Dictionary, collision_manifests: Array) -> void:
    _clear_layout_sample_cache()
    cached_revision = str(JSON.stringify({"building": building_manifest, "collision": collision_manifests}).hash())
    # Explicit source-only adapters bind to the supplied immutable manifests.
    # Native acquisition never selects this mode as a fallback after failure.
    source_manifest_revision = cached_revision
    cached_static_collision_records = []
    cached_static_collision_by_cell = {}
    cached_static_collision_broad = []
    cached_static_collision_broad_by_tile = {}
    cached_static_collision_by_tile = {}
    cached_door_collision_records = []
    cached_door_collision_by_cell = {}
    cached_door_collision_broad = []
    cached_door_collision_broad_by_tile = {}
    cached_door_collision_by_tile = {}
    cached_collision_query_by_tile = {}
    cached_collision_query_revision = ""
    cached_building_supports = []
    cached_building_supports_by_tile = {}
    cached_building_vertical_links = []
    cached_building_vertical_links_by_tile = {}
    cached_building_support_seam_links = []
    cached_building_support_seam_links_by_tile = {}
    cached_building_interior_passage_links = []
    cached_building_interior_passage_links_by_tile = {}
    cached_building_doors = []
    cached_building_doors_by_tile = {}
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
    _rebuild_building_navigation_fact_indexes()


func _rebuild_building_navigation_fact_indexes() -> void:
    cached_building_vertical_links_by_tile = _building_facts_by_owner_tile(cached_building_vertical_links)
    cached_building_support_seam_links_by_tile = _building_facts_by_owner_tile(cached_building_support_seam_links)
    cached_building_interior_passage_links_by_tile = _building_facts_by_owner_tile(cached_building_interior_passage_links)
    cached_building_doors_by_tile = _building_facts_by_owner_tile(cached_building_doors)


func _building_facts_by_owner_tile(values: Array) -> Dictionary:
    var result := {}
    for value in values:
        if not (value is Dictionary):
            continue
        var tile_key := String((value as Dictionary).get("ownerTileKey", ""))
        if tile_key.is_empty():
            tile_key = _building_navigation_link_owner_tile_key(value as Dictionary)
        if tile_key.is_empty():
            continue
        if not result.has(tile_key):
            result[tile_key] = []
        (result[tile_key] as Array).append(value)
    return result


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
        _index_collision_record_by_tile(cached_static_collision_by_tile, record)


func _index_collision_record_by_tile(index: Dictionary, record: Dictionary) -> void:
    for tile_key in _collision_record_tile_keys(record):
        if not index.has(tile_key):
            index[tile_key] = []
        (index[tile_key] as Array).append(record)


func _collision_record_tile_keys(record: Dictionary) -> Array[String]:
    var explicit_keys: Array = record.get("tileKeys", []) if record.get("tileKeys", []) is Array else []
    var unique := {}
    for tile_key_value in explicit_keys:
        var explicit_key := String(tile_key_value).strip_edges()
        if not explicit_key.is_empty():
            unique[explicit_key] = true
    if unique.is_empty():
        var inflation := float(record.get("inflation", TRANSITION_COLLISION_INFLATION))
        var min_cell_x := floori((float(record.get("minX", 0.0)) - inflation) / CELL) - TRANSITION_RECORD_INDEX_MARGIN_CELLS
        var max_cell_x := floori((float(record.get("maxX", 0.0)) + inflation) / CELL) + TRANSITION_RECORD_INDEX_MARGIN_CELLS
        var min_cell_z := floori((float(record.get("minZ", 0.0)) - inflation) / CELL) - TRANSITION_RECORD_INDEX_MARGIN_CELLS
        var max_cell_z := floori((float(record.get("maxZ", 0.0)) + inflation) / CELL) + TRANSITION_RECORD_INDEX_MARGIN_CELLS
        var min_tile_x := floori(float(min_cell_x) / float(NAV_TILE_CELL_SIZE)) - 1
        var max_tile_x := floori(float(max_cell_x) / float(NAV_TILE_CELL_SIZE)) + 1
        var min_tile_z := floori(float(min_cell_z) / float(NAV_TILE_CELL_SIZE)) - 1
        var max_tile_z := floori(float(max_cell_z) / float(NAV_TILE_CELL_SIZE)) + 1
        for tile_z in range(min_tile_z, max_tile_z + 1):
            for tile_x in range(min_tile_x, max_tile_x + 1):
                var tile_key := "%d,%d" % [tile_x, tile_z]
                if _collision_record_overlaps_tile(record, tile_key):
                    unique[tile_key] = true
    var result: Array[String] = []
    for tile_key_value in unique.keys():
        result.append(String(tile_key_value))
    result.sort()
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
    var tile_keys: Array = part.get("tileKeys", []) if part.get("tileKeys", []) is Array else []
    if not tile_keys.is_empty():
        result["tileKeys"] = tile_keys.duplicate()
    return result


func _clear_layout_sample_cache() -> void:
    navmesh_support_sample_cache.clear()
    navmesh_support_sample_empty_cache.clear()
    navmesh_support_sample_ordered_keys_cache.clear()
    navmesh_support_sample_cache_order.clear()
    navmesh_support_sample_cache_hit_count = 0


static func source_support_connectivities(building_manifest: Dictionary, collision_manifests: Array, requests: Array) -> Dictionary:
    var adapter = BuildingLayoutClearance.new()
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
    var adjacency_result := _source_sample_adjacency(samples_by_support, snapshot)
    if not bool(adjacency_result.get("complete", false)):
        return {"reachable": false, "incomplete": true, "status": adjacency_result.get("status", "failed"), "reason": adjacency_result.get("reason", "source_sample_adjacency_incomplete"), "sourceCollisionRevision": cached_revision}
    var adjacency: Dictionary = adjacency_result.get("adjacency", {}) as Dictionary
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


static func source_support_connectivity(building_manifest: Dictionary, collision_manifests: Array, support_id: String, probes: Array, snap_distance: float) -> Dictionary:
    var adapter = BuildingLayoutClearance.new()
    adapter._load_source_navigation_manifests(building_manifest, collision_manifests)
    return adapter._source_support_connectivity(support_id, probes, snap_distance)
