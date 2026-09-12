extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35

var main: Node = null

func _ready() -> void:
    call_deferred("run")

func run() -> void:
    var report_path := OS.get_environment("VOXEL_TUTORIAL_TERRAIN_PROBE_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/npc/reports/tutorial-starter-terrain-probe.json")
    main = MAIN_SCENE.instantiate()
    add_child(main)
    if not await main.wait_for_startup_loading_complete():
        write_json(report_path, {
            "schemaVersion": 1,
            "diagnosticOnly": true,
            "passed": false,
            "reason": "startup_loading_not_ready",
            "startup_loading_failure_result": main.get("startup_loading_failure_result")
        })
        main.call("request_graceful_quit", 1)
        return
    await wait_physics_frames(30)
    var tutorial = main.get("tutorial_system") if main != null else null
    var started := false
    if tutorial != null and tutorial.has_method("start_new_world"):
        started = bool(tutorial.call("start_new_world"))
    if main != null and main.has_method("update_chunks"):
        main.call("update_chunks", true)
    if main != null and main.has_method("refresh_intro_knock_audio"):
        main.call("refresh_intro_knock_audio")
    await wait_physics_frames(140)
    if main != null and main.has_method("update_chunks"):
        main.call("update_chunks", true)
    await wait_physics_frames(20)

    var state: Dictionary = tutorial.call("state") if tutorial != null and tutorial.has_method("state") else {}
    var town_center: Vector2i = vector2i_from_value(state.get("townCenter", Vector2i.ZERO), Vector2i.ZERO)
    var start_cell: Vector2i = vector2i_from_value(state.get("startCell", Vector2i.ZERO), Vector2i.ZERO)
    var level := float(main.get("town").get("level", 16.0)) if main != null and main.get("town") is Dictionary else 16.0
    var floor_y := floori(level / CELL)
    var bed_node := nearest_block("bed", Vector3(float(town_center.x - 14) * CELL, level + CELL * 0.48, float(town_center.y - 8) * CELL))
    var door_node := nearest_block("door", Vector3(float(start_cell.x) * CELL, level + CELL * 0.48, float(start_cell.y - 3) * CELL))
    var bed_meta_cell: Vector3i = bed_node.get_meta("cell", Vector3i(town_center.x - 14, floor_y + 1, town_center.y - 8)) if bed_node != null else Vector3i(town_center.x - 14, floor_y + 1, town_center.y - 8)
    var hit_cell := Vector3i(floori(358.862 / CELL), floori(21.867 / CELL), floori(-11.208 / CELL))
    var probe_cells: Array[Vector3i] = [
        bed_meta_cell,
        hit_cell,
        Vector3i(town_center.x - 14, floor_y, town_center.y - 8),
        Vector3i(town_center.x - 14, floor_y + 1, town_center.y - 8),
        Vector3i(town_center.x - 15, floor_y + 1, town_center.y - 9),
        Vector3i(start_cell.x, floor_y + 1, start_cell.y - 3)
    ]
    for z in range(town_center.y - 11, town_center.y - 7):
        for x in range(town_center.x - 15, town_center.x - 12):
            probe_cells.append(Vector3i(x, floor_y + 1, z))

    var chunk_key := Vector2i(floori(float(bed_meta_cell.x) / 28.0), floori(float(bed_meta_cell.z) / 28.0))
    var report := {
        "schemaVersion": 1,
        "diagnosticOnly": true,
        "startedTutorial": started,
        "townCenter": vector2i_to_array(town_center),
        "startCell": vector2i_to_array(start_cell),
        "level": level,
        "floorY": floor_y,
        "bed": block_summary(bed_node),
        "door": block_summary(door_node),
        "chunkKey": vector2i_to_array(chunk_key),
        "chunkHasVolumeEdits": chunk_has_volume_edits(chunk_key),
        "chunkSignature": chunk_signature(chunk_key),
        "mesh": terrain_mesh_summary(chunk_key),
        "probes": probe_states(probe_cells)
    }
    write_json(report_path, report)
    main.request_graceful_quit(0)

func wait_physics_frames(count: int) -> void:
    for _i in range(maxi(0, count)):
        await get_tree().physics_frame

func nearest_block(block_type: String, near_position: Vector3) -> Node3D:
    if main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var best: Node3D = null
    var best_distance := INF
    for value in (blocks_value as Dictionary).values():
        var block := value as Node3D
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("block_type", "")) != block_type:
            continue
        var distance := block.global_position.distance_to(near_position)
        if distance < best_distance:
            best_distance = distance
            best = block
    return best

func probe_states(cells: Array[Vector3i]) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var world_generation = main.get("world_generation_system") if main != null else null
    var seen := {}
    for cell in cells:
        var key := "%d,%d,%d" % [cell.x, cell.y, cell.z]
        if seen.has(key):
            continue
        seen[key] = true
        var state := {}
        var sample := {}
        if world_generation != null and world_generation.has_method("get_cell_state"):
            state = world_generation.call("get_cell_state", cell)
        if world_generation != null and world_generation.has_method("sample_world"):
            sample = world_generation.call("sample_world", Vector3(float(cell.x) * CELL, float(cell.y) * CELL, float(cell.z) * CELL))
        result.append({
            "cell": vector3i_to_array(cell),
            "worldPosition": vector3_to_array(Vector3(float(cell.x) * CELL, float(cell.y) * CELL, float(cell.z) * CELL)),
            "state": encode_json_value(state),
            "sample": encode_json_value(sample)
        })
    return result

func chunk_has_volume_edits(chunk_key: Vector2i) -> bool:
    var world_generation = main.get("world_generation_system") if main != null else null
    if world_generation != null and world_generation.has_method("terrain_volume_chunk_has_edits"):
        return bool(world_generation.call("terrain_volume_chunk_has_edits", chunk_key, 28))
    return false

func chunk_signature(chunk_key: Vector2i) -> String:
    if main != null and main.has_method("chunk_asset_signature"):
        return String(main.call("chunk_asset_signature", chunk_key))
    return ""

func terrain_mesh_summary(chunk_key: Vector2i) -> Dictionary:
    if main == null:
        return {}
    var chunks_value = main.get("chunks")
    if not (chunks_value is Dictionary) or not (chunks_value as Dictionary).has(chunk_key):
        return { "found": false }
    var chunk := (chunks_value as Dictionary)[chunk_key] as Node3D
    if chunk == null:
        return { "found": false }
    var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
    var mesh := mesh_instance.mesh if mesh_instance != null else null
    return {
        "found": true,
        "node": chunk.get_path(),
        "surfaceCount": mesh.get_surface_count() if mesh != null else 0,
        "backend": String(mesh.get_meta("terrainMeshingBackend", "")) if mesh != null else "",
        "native": bool(mesh.get_meta("terrainMeshingNative", false)) if mesh != null else false,
        "sectionPayload": bool(mesh.get_meta("terrainMeshingSectionPayload", false)) if mesh != null else false,
        "provisional": bool(mesh.get_meta("terrainMeshingProvisional", false)) if mesh != null else false
    }

func block_summary(block: Node3D) -> Dictionary:
    if block == null or not is_instance_valid(block):
        return { "found": false }
    return {
        "found": true,
        "name": block.name,
        "path": block.get_path(),
        "type": String(block.get_meta("block_type", "")),
        "cell": vector3i_to_array(block.get_meta("cell", Vector3i.ZERO)),
        "position": vector3_to_array(block.global_position)
    }

func vector2i_from_value(value, fallback: Vector2i) -> Vector2i:
    if value is Vector2i:
        return value
    if value is Array and value.size() >= 2:
        return Vector2i(int(value[0]), int(value[1]))
    return fallback

func vector2i_to_array(value: Vector2i) -> Array:
    return [value.x, value.y]

func vector3i_to_array(value: Vector3i) -> Array:
    return [value.x, value.y, value.z]

func vector3_to_array(value: Vector3) -> Array:
    return [snappedf(value.x, 0.001), snappedf(value.y, 0.001), snappedf(value.z, 0.001)]

func encode_json_value(value):
    if value is Vector3i:
        return vector3i_to_array(value)
    if value is Vector2i:
        return vector2i_to_array(value)
    if value is Vector3:
        return vector3_to_array(value)
    if value is Dictionary:
        var result := {}
        for key in value.keys():
            result[String(key)] = encode_json_value(value[key])
        return result
    if value is Array:
        var result_array := []
        for item in value:
            result_array.append(encode_json_value(item))
        return result_array
    return value

func write_json(path: String, data: Dictionary) -> void:
    var dir := path.get_base_dir()
    if dir != "":
        DirAccess.make_dir_recursive_absolute(dir)
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(data, "  "))
