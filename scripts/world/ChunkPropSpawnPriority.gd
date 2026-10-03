extends RefCounted

## Schedules the existing chunk-local publisher without touching its RNG or
## attempts. Surface completion is the producer's marker, not an estimate from
## the current phase or a viewer's visual receipt.
static func ordered_keys(pending: Dictionary, priority_keys: Array[Vector2i],
        near_bounds: Rect2i, chunk_size: int, near_full_turn: bool) -> Array[Vector2i]:
    var visible_surface: Array[Vector2i] = []
    var other_surface: Array[Vector2i] = []
    var near_full: Array[Vector2i] = []
    var visible_underground: Array[Vector2i] = []
    var other_underground: Array[Vector2i] = []
    var seen: Dictionary = {}
    for key in priority_keys:
        if not pending.has(key) or seen.has(key):
            continue
        seen[key] = true
        if _surface_complete(pending[key]):
            if chunk_size > 0 and Rect2i(key * chunk_size,
                    Vector2i.ONE * chunk_size).intersects(near_bounds):
                near_full.append(key)
            else:
                visible_underground.append(key)
        else:
            visible_surface.append(key)
    for key_value in pending.keys():
        if not (key_value is Vector2i):
            continue
        var key: Vector2i = key_value
        if seen.has(key):
            continue
        if _surface_complete(pending[key]):
            other_underground.append(key)
        else:
            other_surface.append(key)
    var result: Array[Vector2i] = []
    if near_full_turn:
        result.append_array(near_full)
    result.append_array(visible_surface)
    if not near_full_turn:
        result.append_array(near_full)
    result.append_array(visible_underground)
    result.append_array(other_surface)
    result.append_array(other_underground)
    return result

static func _surface_complete(state_value) -> bool:
    if not (state_value is Dictionary):
        return false
    var chunk = state_value.get("chunk")
    return chunk is Node3D and is_instance_valid(chunk) \
        and bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false))


## Select only a near physical producer whose incomplete full scan is already
## the visual region's declared missing source. Its existing state/RNG is used.
static func required_near_full_scan_key(pending: Dictionary, pending_reasons: Dictionary,
        physical_chunks: Dictionary, priority_keys: Array[Vector2i], near_bounds: Rect2i,
        chunk_size: int) -> Variant:
    if not near_bounds.has_area() or chunk_size <= 0:
        return null
    for key: Vector2i in priority_keys:
        if not pending.has(key) or not pending_reasons.has(key) \
                or not physical_chunks.has(key):
            continue
        var reason_value = pending_reasons[key]
        if not (reason_value is Dictionary) or String(reason_value.get("reason", "")) \
                != "chunk_prop_candidate_scan_incomplete":
            continue
        if not Rect2i(key * chunk_size, Vector2i.ONE * chunk_size).intersects(near_bounds):
            continue
        var state_value = pending[key]
        if not (state_value is Dictionary):
            continue
        var chunk_value = state_value.get("chunk")
        if not (chunk_value is Node3D) or not is_instance_valid(chunk_value) \
                or not is_same(physical_chunks[key], chunk_value) \
                or bool(chunk_value.get_meta("horizon_visual_only", false)) \
                or not bool(chunk_value.get_meta("chunk_surface_candidate_scan_complete", false)) \
                or bool(chunk_value.get_meta("chunk_prop_candidate_scan_complete", false)):
            continue
        return key
    return null


static func startup_spare_slice_admitted(elapsed_ms: float, required_full_scan: bool,
        ordinary_budget_ms: float, required_budget_ms: float, slice_headroom_ms: float) -> bool:
    if required_full_scan:
        return elapsed_ms + slice_headroom_ms <= required_budget_ms
    return elapsed_ms < ordinary_budget_ms
