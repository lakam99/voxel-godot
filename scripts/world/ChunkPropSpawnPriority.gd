extends RefCounted

## Schedules the existing chunk-local publisher without touching its RNG or
## attempts. Surface completion is the producer's marker, not an estimate from
## the current phase or a viewer's visual receipt.
static func ordered_keys(pending: Dictionary, priority_keys: Array[Vector2i],
        underground_turn: bool) -> Array[Vector2i]:
    var visible_surface: Array[Vector2i] = []
    var other_surface: Array[Vector2i] = []
    var visible_underground: Array[Vector2i] = []
    var other_underground: Array[Vector2i] = []
    var seen: Dictionary = {}
    for key in priority_keys:
        if not pending.has(key) or seen.has(key):
            continue
        seen[key] = true
        if _surface_complete(pending[key]):
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
    if underground_turn:
        result.append_array(visible_underground)
        result.append_array(other_underground)
    result.append_array(visible_surface)
    result.append_array(other_surface)
    if not underground_turn:
        result.append_array(visible_underground)
        result.append_array(other_underground)
    return result

static func _surface_complete(state_value) -> bool:
    if not (state_value is Dictionary):
        return false
    var chunk = state_value.get("chunk")
    return chunk is Node3D and is_instance_valid(chunk) \
        and bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false))
