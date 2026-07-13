extends RefCounted
class_name TutorialTownSaveContract

const SCHEMA_VERSION := 1
const INTENT_WAIT := "wait"
const INTENT_GO_HOME := "go_home"
const INTENT_RESUME_SCHEDULE := "resume_schedule"

static func build(manifest_value, actor_specs: Array, intro_intent_value) -> Dictionary:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "manifestReference": manifest_reference(manifest_value, actor_specs),
        "introKnockIntent": normalize_intro_intent(intro_intent_value, {})
    }

static func normalize(value, fallback_intent_value) -> Dictionary:
    var source: Dictionary = value if value is Dictionary else {}
    var legacy_missing := source.is_empty() or not source.has("schemaVersion")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "manifestReference": normalize_manifest_reference(source.get("manifestReference", {})),
        "introKnockIntent": normalize_intro_intent(source.get("introKnockIntent", {}), fallback_intent_value),
        "migration": "tutorial_save_contract_missing" if legacy_missing else ""
    }

static func manifest_reference(manifest_value, actor_specs: Array) -> Dictionary:
    var manifest: Dictionary = manifest_value if manifest_value is Dictionary else {}
    var actor_homes := {}
    for spec_value in actor_specs:
        if not (spec_value is Dictionary):
            continue
        var spec: Dictionary = spec_value
        var actor_id := String(spec.get("id", "")).strip_edges()
        if actor_id == "":
            continue
        var profile: Dictionary = spec.get("profile", {}) if spec.get("profile", {}) is Dictionary else {}
        actor_homes[actor_id] = assignment_identity(profile)
    return {
        "manifestSchemaVersion": int(manifest.get("schemaVersion", 0)),
        "townKey": String(manifest.get("townKey", "")).strip_edges(),
        "seed": String(manifest.get("seed", "")).strip_edges(),
        "generationRevision": int(manifest.get("generationRevision", -1)),
        "actorHomes": actor_homes
    }

static func normalize_manifest_reference(value) -> Dictionary:
    if not (value is Dictionary):
        return {}
    var source: Dictionary = value
    var actor_homes := {}
    var source_homes: Dictionary = source.get("actorHomes", {}) if source.get("actorHomes", {}) is Dictionary else {}
    for actor_id_value in source_homes.keys():
        var actor_id := String(actor_id_value).strip_edges()
        var assignment_value = source_homes.get(actor_id_value)
        if actor_id == "" or not (assignment_value is Dictionary):
            continue
        actor_homes[actor_id] = assignment_identity(assignment_value as Dictionary)
    return {
        "manifestSchemaVersion": int(source.get("manifestSchemaVersion", 0)),
        "townKey": String(source.get("townKey", "")).strip_edges(),
        "seed": String(source.get("seed", "")).strip_edges(),
        "generationRevision": int(source.get("generationRevision", -1)),
        "actorHomes": actor_homes
    }

static func normalize_intro_intent(value, fallback_value) -> Dictionary:
    var fallback: Dictionary = fallback_value if fallback_value is Dictionary else {}
    var source: Dictionary = value if value is Dictionary else {}
    var kind := String(source.get("kind", fallback.get("kind", INTENT_WAIT))).strip_edges()
    if not kind in [INTENT_WAIT, INTENT_GO_HOME, INTENT_RESUME_SCHEDULE]:
        kind = String(fallback.get("kind", INTENT_WAIT)).strip_edges()
    if not kind in [INTENT_WAIT, INTENT_GO_HOME, INTENT_RESUME_SCHEDULE]:
        kind = INTENT_WAIT
    var reason := String(source.get("reason", fallback.get("reason", ""))).strip_edges()
    if reason == "":
        reason = default_reason_for_intent(kind)
    return {"kind": kind, "reason": reason}

static func default_reason_for_intent(kind: String) -> String:
    match kind:
        INTENT_WAIT:
            return "tutorial_knock_pending"
        INTENT_GO_HOME:
            return "tutorial_knock_complete"
        _:
            return "resume_schedule"

static func assignment_identity(value: Dictionary) -> Dictionary:
    return {
        "homeKey": int(value.get("homeKey", -1)),
        "homeStableId": String(value.get("homeStableId", value.get("stableId", ""))).strip_edges(),
        "doorPortalId": String(value.get("doorPortalId", "")).strip_edges()
    }

static func validate_manifest_reference(reference_value, manifest_value, actor_specs: Array) -> Dictionary:
    var reference := normalize_manifest_reference(reference_value)
    var actor_homes: Dictionary = reference.get("actorHomes", {}) if reference.get("actorHomes", {}) is Dictionary else {}
    var missing_identity := int(reference.get("manifestSchemaVersion", 0)) <= 0 \
        and String(reference.get("townKey", "")).strip_edges() == "" \
        and String(reference.get("seed", "")).strip_edges() == "" \
        and actor_homes.is_empty()
    if reference.is_empty() or missing_identity:
        return {
            "ok": true,
            "status": "legacy_missing",
            "compared": false,
            "mismatches": []
        }
    var expected := manifest_reference(manifest_value, actor_specs)
    var mismatches: Array[String] = []
    for key in ["manifestSchemaVersion", "townKey", "seed", "generationRevision"]:
        if reference.get(key) != expected.get(key):
            mismatches.append("%s_mismatch" % key)
    var saved_homes: Dictionary = reference.get("actorHomes", {}) if reference.get("actorHomes", {}) is Dictionary else {}
    var expected_homes: Dictionary = expected.get("actorHomes", {}) if expected.get("actorHomes", {}) is Dictionary else {}
    for actor_id_value in expected_homes.keys():
        var actor_id := String(actor_id_value)
        if not saved_homes.has(actor_id):
            mismatches.append("missing_actor_home:%s" % actor_id)
            continue
        if assignment_identity(saved_homes.get(actor_id, {})) != assignment_identity(expected_homes.get(actor_id, {})):
            mismatches.append("actor_home_mismatch:%s" % actor_id)
    for actor_id_value in saved_homes.keys():
        var actor_id := String(actor_id_value)
        if not expected_homes.has(actor_id):
            mismatches.append("unexpected_actor_home:%s" % actor_id)
    return {
        "ok": mismatches.is_empty(),
        "status": "valid" if mismatches.is_empty() else "mismatch",
        "compared": true,
        "mismatches": mismatches,
        "saved": reference,
        "regenerated": expected
    }

static func validate_saved_assignment(saved_fact_value, regenerated_profile_value) -> Dictionary:
    if not (saved_fact_value is Dictionary):
        return {"ok": true, "status": "missing", "compared": false, "mismatches": []}
    var saved_fact: Dictionary = saved_fact_value
    var has_identity := saved_fact.has("homeKey") or saved_fact.has("homeStableId") or saved_fact.has("doorPortalId")
    if not has_identity:
        return {"ok": true, "status": "legacy_missing", "compared": false, "mismatches": []}
    var saved := assignment_identity(saved_fact)
    var regenerated: Dictionary = regenerated_profile_value if regenerated_profile_value is Dictionary else {}
    var expected := assignment_identity(regenerated)
    var mismatches: Array[String] = []
    for key in ["homeKey", "homeStableId", "doorPortalId"]:
        if saved.get(key) != expected.get(key):
            mismatches.append("%s_mismatch" % key)
    return {
        "ok": mismatches.is_empty(),
        "status": "valid" if mismatches.is_empty() else "mismatch",
        "compared": true,
        "mismatches": mismatches,
        "saved": saved,
        "regenerated": expected
    }
