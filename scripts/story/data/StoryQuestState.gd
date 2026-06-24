extends RefCounted
class_name StoryQuestState

const SCHEMA_VERSION := 1

static func normalize(value) -> Dictionary:
    if not (value is Dictionary):
        return {}
    var quest: Dictionary = value.duplicate(true)
    quest["schemaVersion"] = int(quest.get("schemaVersion", SCHEMA_VERSION))
    quest["id"] = String(quest.get("id", ""))
    quest["arcId"] = String(quest.get("arcId", ""))
    quest["status"] = String(quest.get("status", "inactive"))
    quest["stage"] = String(quest.get("stage", ""))
    quest["stageIndex"] = int(quest.get("stageIndex", -1))
    quest["tracked"] = bool(quest.get("tracked", false))
    if not quest.has("facts") or not (quest["facts"] is Dictionary):
        quest["facts"] = {}
    if not quest.has("optionalObjectives") or not (quest["optionalObjectives"] is Dictionary):
        quest["optionalObjectives"] = {}
    return quest

static func validate(value) -> Dictionary:
    var problems: Array[String] = []
    if not (value is Dictionary):
        problems.append("quest is not a dictionary")
        return { "ok": false, "problems": problems }
    var quest: Dictionary = value
    for key in ["id", "status", "stage", "stageIndex", "tracked", "facts", "optionalObjectives"]:
        if not quest.has(key):
            problems.append("missing %s" % key)
    if String(quest.get("id", "")) == "":
        problems.append("id cannot be empty")
    if not (String(quest.get("status", "")) in ["inactive", "active", "completed", "failed"]):
        problems.append("invalid status %s" % String(quest.get("status", "")))
    if String(quest.get("stage", "")) == "":
        problems.append("stage cannot be empty")
    if int(quest.get("stageIndex", -1)) < 0:
        problems.append("stageIndex must be non-negative")
    if not (quest.get("facts", null) is Dictionary):
        problems.append("facts must be a dictionary")
    if not (quest.get("optionalObjectives", null) is Dictionary):
        problems.append("optionalObjectives must be a dictionary")
    return { "ok": problems.is_empty(), "problems": problems }
