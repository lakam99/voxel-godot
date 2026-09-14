class_name NavigationMarkerIndex
extends RefCounted

var _entries_by_cell: Dictionary = {}
var _ordered_entries: Array = []
var _order_dirty := false
var _next_sequence := 1
var _revision := 0

func revision() -> int:
    return _revision

func register(cell: Vector3i, body: Node3D, marker: Dictionary) -> void:
    if body == null or marker.is_empty():
        unregister(cell)
        return
    var existing: Dictionary = _entries_by_cell.get(cell, {})
    var sequence := int(existing.get("sequence", 0))
    if sequence <= 0:
        sequence = _next_sequence
        _next_sequence += 1
    _entries_by_cell[cell] = {
        "body": body,
        "cell": cell,
        "instanceId": body.get_instance_id(),
        "marker": marker.duplicate(true),
        "sequence": sequence
    }
    _revision += 1
    _order_dirty = true

func unregister(cell: Vector3i, expected_body: Node = null) -> void:
    if not _entries_by_cell.has(cell):
        return
    var existing: Dictionary = _entries_by_cell[cell]
    if expected_body != null and int(existing.get("instanceId", 0)) != expected_body.get_instance_id():
        return
    _entries_by_cell.erase(cell)
    _revision += 1
    _order_dirty = true

func clear() -> void:
    if _entries_by_cell.is_empty():
        return
    _entries_by_cell.clear()
    _ordered_entries.clear()
    _revision += 1
    _order_dirty = false

func live_entries(blocks: Dictionary) -> Array:
    _prune_stale(blocks)
    if _order_dirty:
        _ordered_entries = _entries_by_cell.values()
        _ordered_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
            return int(a.get("sequence", 0)) < int(b.get("sequence", 0))
        )
        _order_dirty = false
    return _ordered_entries

func _prune_stale(blocks: Dictionary) -> void:
    var stale_cells: Array = []
    for cell_value in _entries_by_cell:
        var cell: Vector3i = cell_value
        var entry: Dictionary = _entries_by_cell[cell]
        # A queued-free Object remains in the Variant slot as a freed instance.
        # Validate that raw value before a typed cast; casting the freed value
        # itself raises an engine script error and prevents the stale entry from
        # ever being pruned.
        var body_value = entry.get("body")
        if not is_instance_valid(body_value):
            stale_cells.append(cell)
            continue
        var body := body_value as Node3D
        if body == null or blocks.get(cell) != body:
            stale_cells.append(cell)
    if stale_cells.is_empty():
        return
    for cell in stale_cells:
        _entries_by_cell.erase(cell)
    _revision += 1
    _order_dirty = true
