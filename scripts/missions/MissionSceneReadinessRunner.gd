extends RefCounted
class_name MissionSceneReadinessRunner

const DEFAULT_CELL_SIZE := 1.35

## Read-only readiness checks shared by scripted missions. This runner never plans
## routes or moves actors; it verifies published terrain and door authorities.

static func terrain_collision_proof(main, positions: Array, footprint_radius := 0.42) -> Dictionary:
    if main == null:
        return {"ok": false, "reason": "missing_main", "proofs": []}
    var runtime = main.get("voxel_terrain_runtime")
    if runtime == null or not is_instance_valid(runtime) or not runtime.has_method("collision_proof_for_world_position"):
        return {"ok": false, "reason": "missing_terrain_collision_authority", "proofs": []}
    request_terrain_publication(main, runtime, positions)
    var proofs: Array = []
    for value in positions:
        var position: Vector3 = value if value is Vector3 else Vector3.INF
        if not position.is_finite():
            return {"ok": false, "reason": "invalid_collision_probe_position", "proofs": proofs}
        var proof_value = runtime.call("collision_proof_for_world_position", position, footprint_radius)
        var proof: Dictionary = proof_value if proof_value is Dictionary else {}
        proofs.append(proof)
        if not bool(proof.get("passed", false)):
            return {"ok": false, "reason": String(proof.get("reason", "terrain_collision_pending")), "proofs": proofs}
    return {"ok": true, "reason": "", "proofs": proofs}

static func request_terrain_publication(main, runtime, positions: Array) -> void:
    if runtime == null or not runtime.has_method("request_gameplay_chunk_publication") or not runtime.has_method("game_chunk_for_cell"):
        return
    var cell_size := DEFAULT_CELL_SIZE
    for value in positions:
        var position: Vector3 = value if value is Vector3 else Vector3.INF
        if not position.is_finite():
            continue
        var cell := Vector3i(floori(position.x / cell_size), floori(position.y / cell_size), floori(position.z / cell_size))
        var chunk_value = runtime.call("game_chunk_for_cell", cell)
        if chunk_value is Vector2i:
            runtime.call("request_gameplay_chunk_publication", chunk_value)

static func public_gate_near(main, expected_position: Vector3, max_distance: float) -> Dictionary:
    if main == null or not (main.get("blocks") is Dictionary):
        return {"ok": false, "reason": "missing_live_door_blocks"}
    var best: Node3D = null
    var best_distance := max_distance
    for value in (main.get("blocks") as Dictionary).values():
        var door := value as Node3D
        if door == null or not is_instance_valid(door) or String(door.get_meta("door_policy", "")) != "public_gate":
            continue
        var distance := Vector2(door.global_position.x - expected_position.x, door.global_position.z - expected_position.z).length()
        if distance < best_distance:
            best_distance = distance
            best = door
    if best == null:
        return {"ok": false, "reason": "public_gate_not_published"}
    var portal_id := String(best.get_meta("door_portal_id", ""))
    var portal_summary := {}
    var npc_system = main.get("npc_system")
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var service = autonomy.get("door_portals") if autonomy != null else null
    if service != null and service.has_method("to_summary"):
        var service_summary: Dictionary = service.call("to_summary")
        var portals: Dictionary = service_summary.get("portals", {}) if service_summary.get("portals", {}) is Dictionary else {}
        portal_summary = portals.get(portal_id, {}) if portals.get(portal_id, {}) is Dictionary else {}
    if portal_id == "" or portal_summary.is_empty():
        return {"ok": false, "reason": "public_gate_portal_not_registered", "portalId": portal_id}
    if bool(portal_summary.get("destroyed", false)) or bool(portal_summary.get("unloaded", false)) or not bool(portal_summary.get("publicAccess", false)):
        return {"ok": false, "reason": "public_gate_not_traversable", "portal": portal_summary}
    return {
        "ok": true,
        "reason": "",
        "door": best,
        "portalId": portal_id,
        "position": best.global_position,
        "portal": portal_summary,
        "distance": best_distance
    }
