extends RefCounted
class_name WorldmarkState

const SCHEMA_VERSION := 1

static func default_state(region_id: String, definition_id := "pending_worldmark") -> Dictionary:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "id": "worldmark:%s" % region_id,
        "definitionId": definition_id,
        "domain": "",
        "condition": "",
        "desire": "",
        "publicBeliefId": "",
        "hiddenTruthId": "",
        "foundClueIds": [],
        "preparationFlags": {},
        "encounterState": {},
        "resolution": ""
    }

static func normalize(region_id: String, value) -> Dictionary:
    var state: Dictionary = value.duplicate(true) if value is Dictionary else default_state(region_id)
    state["schemaVersion"] = int(state.get("schemaVersion", SCHEMA_VERSION))
    state["id"] = String(state.get("id", "worldmark:%s" % region_id))
    state["definitionId"] = String(state.get("definitionId", "pending_worldmark"))
    state["domain"] = String(state.get("domain", ""))
    state["condition"] = String(state.get("condition", ""))
    state["desire"] = String(state.get("desire", ""))
    state["publicBeliefId"] = String(state.get("publicBeliefId", ""))
    state["hiddenTruthId"] = String(state.get("hiddenTruthId", ""))
    if not state.has("foundClueIds") or not (state["foundClueIds"] is Array):
        state["foundClueIds"] = []
    if not state.has("preparationFlags") or not (state["preparationFlags"] is Dictionary):
        state["preparationFlags"] = {}
    if not state.has("encounterState") or not (state["encounterState"] is Dictionary):
        state["encounterState"] = {}
    state["resolution"] = String(state.get("resolution", ""))
    return state

static func validate(region_id: String, value) -> Dictionary:
    var problems: Array[String] = []
    if not (value is Dictionary):
        problems.append("worldmark is not a dictionary")
        return { "ok": false, "problems": problems }
    var state: Dictionary = value
    var expected_id := "worldmark:%s" % region_id
    if String(state.get("id", "")) != expected_id:
        problems.append("id must be %s" % expected_id)
    for key in ["definitionId", "domain", "condition", "desire", "publicBeliefId", "hiddenTruthId"]:
        if not state.has(key):
            problems.append("missing %s" % key)
    if not (state.get("foundClueIds", null) is Array):
        problems.append("foundClueIds must be an array")
    if not (state.get("preparationFlags", null) is Dictionary):
        problems.append("preparationFlags must be a dictionary")
    if not (state.get("encounterState", null) is Dictionary):
        problems.append("encounterState must be a dictionary")
    return { "ok": problems.is_empty(), "problems": problems }
