extends RefCounted
class_name StructureDoorRules

static func door_cells(width: int, depth: int, side: int) -> Array:
    var result := []
    if side == 0:
        var start_x := width / 2 - 1
        result.append({ "x": start_x, "z": depth - 1, "secondary": false })
        result.append({ "x": start_x + 1, "z": depth - 1, "secondary": true })
    elif side == 2:
        var start_x := width / 2 - 1
        result.append({ "x": start_x, "z": 0, "secondary": false })
        result.append({ "x": start_x + 1, "z": 0, "secondary": true })
    elif side == 1:
        var start_z := depth / 2 - 1
        result.append({ "x": width - 1, "z": start_z, "secondary": false })
        result.append({ "x": width - 1, "z": start_z + 1, "secondary": true })
    else:
        var start_z := depth / 2 - 1
        result.append({ "x": 0, "z": start_z, "secondary": false })
        result.append({ "x": 0, "z": start_z + 1, "secondary": true })
    return result

static func door_entry_at(entries: Array, x: int, z: int) -> Dictionary:
    for entry in entries:
        if int(entry["x"]) == x and int(entry["z"]) == z:
            return entry
    return {}

static func door_facing(side: int) -> float:
    if side == 0:
        return 0.0
    if side == 2:
        return PI
    if side == 1:
        return PI * 0.5
    return -PI * 0.5
