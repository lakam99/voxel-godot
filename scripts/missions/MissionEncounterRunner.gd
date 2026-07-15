extends RefCounted
class_name MissionEncounterRunner

## Generic scripted-encounter adapter. Encounter identity, actors, positions, and
## phase policy are supplied entirely by the owning mission.

static func clear(hostile_system, encounter_id: String, drop := false) -> int:
    if hostile_system == null:
        return 0
    if hostile_system.has_method("clear_scripted_encounter"):
        return int(hostile_system.call("clear_scripted_encounter", encounter_id, drop))
    return 0

static func spawn(hostile_system, encounter_id: String, specs: Array) -> Dictionary:
    if hostile_system == null or not hostile_system.has_method("spawn_enemy") or not hostile_system.has_method("configure_scripted_encounter"):
        return {"ok": false, "reason": "missing_scripted_encounter_contract", "bodies": []}
    var bodies: Array = []
    var slots: Array[String] = []
    for value in specs:
        var spec: Dictionary = value if value is Dictionary else {}
        var position: Vector3 = spec.get("position", Vector3.INF)
        var slot_id := String(spec.get("slotId", ""))
        if not position.is_finite() or slot_id == "":
            clear(hostile_system, encounter_id, false)
            return {"ok": false, "reason": "invalid_encounter_spec", "slotId": slot_id, "bodies": []}
        var body = hostile_system.call("spawn_enemy", position, String(spec.get("variant", "shadow")))
        if body == null or not is_instance_valid(body):
            clear(hostile_system, encounter_id, false)
            return {"ok": false, "reason": "encounter_spawn_failed", "slotId": slot_id, "bodies": []}
        var options: Dictionary = spec.get("options", {}).duplicate(true) if spec.get("options", {}) is Dictionary else {}
        options["slotId"] = slot_id
        hostile_system.call("configure_scripted_encounter", body, encounter_id, String(spec.get("phase", "staged")), options)
        bodies.append(body)
        slots.append(slot_id)
    return {"ok": bodies.size() == specs.size(), "reason": "", "bodies": bodies, "slots": slots}

static func begin_battle(hostile_system, encounter_id: String, source: Node, source_kind: String) -> bool:
    if hostile_system == null or not hostile_system.has_method("begin_scripted_battle"):
        return false
    return bool(hostile_system.call("begin_scripted_battle", encounter_id, source, source_kind))

static func bodies(hostile_system, encounter_id: String) -> Array:
    var result: Array = []
    if hostile_system == null or not (hostile_system.get("enemies") is Array):
        return result
    for value in hostile_system.get("enemies"):
        var enemy: Dictionary = value if value is Dictionary else {}
        if String(enemy.get("scriptedEncounter", "")) != encounter_id:
            continue
        var body := enemy.get("body") as Node
        if body != null and is_instance_valid(body):
            result.append(body)
    return result

static func slot_ids(hostile_system, encounter_id: String) -> Array[String]:
    var result: Array[String] = []
    if hostile_system == null or not (hostile_system.get("enemies") is Array):
        return result
    for value in hostile_system.get("enemies"):
        var enemy: Dictionary = value if value is Dictionary else {}
        if String(enemy.get("scriptedEncounter", "")) == encounter_id:
            var slot_id := String(enemy.get("scriptedSlotId", ""))
            if slot_id != "":
                result.append(slot_id)
    result.sort()
    return result
