extends RefCounted
class_name NarrativeTextProvider

const DEFAULT_MAX_LENGTH := 220

const SUPPORTED_PURPOSES := [
    "rumor",
    "dialogue_variant",
    "worldmark_title",
    "journal_prose",
    "letter",
    "aftermath_reflection",
    "settlement_flavor",
    "site_discovery"
]

const FORBIDDEN_TERMS := [
    "quest requirement",
    "item cost",
    "boss stat",
    "weakness:",
    "reward:",
    "new location",
    "kill mira",
    "niko is dead",
    "sera is dead"
]

func generate(request_value, cache := {}) -> Dictionary:
    var request := normalize_request(request_value)
    return template_result(request, "base_provider")

func supported_purposes() -> Array:
    return SUPPORTED_PURPOSES.duplicate()

func normalize_request(request_value) -> Dictionary:
    var request: Dictionary = request_value.duplicate(true) if request_value is Dictionary else {}
    request["purpose"] = String(request.get("purpose", "rumor"))
    if not SUPPORTED_PURPOSES.has(String(request["purpose"])):
        request["purpose"] = "rumor"
    request["regionId"] = String(request.get("regionId", ""))
    request["questStage"] = String(request.get("questStage", ""))
    request["resolution"] = String(request.get("resolution", ""))
    request["maxLength"] = clampi(int(request.get("maxLength", DEFAULT_MAX_LENGTH)), 32, 600)
    request["hiddenFactsAllowed"] = bool(request.get("hiddenFactsAllowed", false))
    for array_key in ["publicFacts", "hiddenFacts", "requiredTerms", "toneTags", "playerActions", "unsupportedTerms", "allowedProperNouns"]:
        request[array_key] = string_array(request.get(array_key, []))
    request["worldmark"] = dictionary_value(request.get("worldmark", {}))
    request["npc"] = dictionary_value(request.get("npc", {}))
    return request

func stable_request_key(request_value) -> String:
    var request := normalize_request(request_value)
    var key_data := {
        "purpose": request.get("purpose", ""),
        "regionId": request.get("regionId", ""),
        "worldmark": request.get("worldmark", {}),
        "publicFacts": request.get("publicFacts", []),
        "hiddenFacts": request.get("hiddenFacts", []) if bool(request.get("hiddenFactsAllowed", false)) else [],
        "hiddenFactsAllowed": bool(request.get("hiddenFactsAllowed", false)),
        "npc": request.get("npc", {}),
        "questStage": request.get("questStage", ""),
        "playerActions": request.get("playerActions", []),
        "resolution": request.get("resolution", ""),
        "requiredTerms": request.get("requiredTerms", []),
        "maxLength": int(request.get("maxLength", DEFAULT_MAX_LENGTH)),
        "toneTags": request.get("toneTags", [])
    }
    return "narrative:%d" % stable_hash(stable_json(key_data))

func validate_response_json(response_text: String, request_value) -> Dictionary:
    var request := normalize_request(request_value)
    var parser := JSON.new()
    if parser.parse(response_text) != OK:
        return validation_failure("malformed_json")
    var parsed = parser.data
    if not (parsed is Dictionary):
        return validation_failure("malformed_json")
    var text := String(parsed.get("text", "")).strip_edges()
    if text == "":
        return validation_failure("missing_text")
    if text.length() > int(request.get("maxLength", DEFAULT_MAX_LENGTH)):
        return validation_failure("length_exceeded")
    for required in request.get("requiredTerms", []):
        var required_text := String(required)
        if required_text != "" and text.findn(required_text) < 0:
            return validation_failure("missing_required_term:%s" % required_text)
    var lower := text.to_lower()
    for forbidden in FORBIDDEN_TERMS:
        if lower.find(String(forbidden).to_lower()) >= 0:
            return validation_failure("unsupported_claim:%s" % forbidden)
    for unsupported in request.get("unsupportedTerms", []):
        var unsupported_text := String(unsupported)
        if unsupported_text != "" and lower.find(unsupported_text.to_lower()) >= 0:
            return validation_failure("unsupported_claim:%s" % unsupported_text)
    if not bool(request.get("hiddenFactsAllowed", false)):
        for hidden_fact in request.get("hiddenFacts", []):
            var hidden_text := String(hidden_fact)
            if hidden_text != "" and lower.find(hidden_text.to_lower()) >= 0:
                return validation_failure("hidden_fact_leak:%s" % hidden_text)
    return {
        "ok": true,
        "text": text,
        "problems": []
    }

func validation_failure(problem: String) -> Dictionary:
    return {
        "ok": false,
        "text": "",
        "problems": [problem]
    }

func template_result(request_value, reason := "") -> Dictionary:
    var request := normalize_request(request_value)
    return {
        "ok": true,
        "accepted": false,
        "cached": false,
        "source": "template",
        "fallbackReason": reason,
        "requestKey": stable_request_key(request),
        "text": template_text(request)
    }

func template_text(request: Dictionary) -> String:
    var purpose := String(request.get("purpose", "rumor"))
    var region_id := String(request.get("regionId", "the region"))
    var worldmark: Dictionary = request.get("worldmark", {})
    var worldmark_name := String(worldmark.get("displayName", worldmark.get("definitionId", "the Worldmark")))
    var public_facts: Array = request.get("publicFacts", [])
    var fact := String(public_facts[0]) if public_facts.size() > 0 else "the signs match known frontier records"
    var npc: Dictionary = request.get("npc", {})
    var npc_name := String(npc.get("name", npc.get("id", "the speaker")))
    var resolution := String(request.get("resolution", ""))
    var text := ""
    match purpose:
        "rumor":
            text = "Rumor in %s says %s: %s." % [region_id, worldmark_name, fact]
        "dialogue_variant":
            text = "%s keeps to what they know: %s." % [npc_name, fact]
        "worldmark_title":
            text = "%s of %s" % [worldmark_name, region_id]
        "journal_prose":
            text = "Journal record for %s in %s: %s." % [worldmark_name, region_id, fact]
        "letter":
            text = "Letter from %s: %s around %s needs attention." % [npc_name, fact, region_id]
        "aftermath_reflection":
            text = "After %s, %s remembers %s." % [resolution if resolution != "" else "the choice", region_id, fact]
        "settlement_flavor":
            text = "%s changes its routine around one fact: %s." % [region_id, fact]
        "site_discovery":
            text = "%s shows a clear sign: %s." % [region_id, fact]
        _:
            text = "%s: %s." % [region_id, fact]
    return limit_text(text, int(request.get("maxLength", DEFAULT_MAX_LENGTH)))

func limit_text(text: String, max_length: int) -> String:
    if text.length() <= max_length:
        return text
    return text.substr(0, maxi(0, max_length - 1)).strip_edges() + "."

func stable_hash(text: String) -> int:
    var value := 2166136261
    for index in range(text.length()):
        value = int((value ^ text.unicode_at(index)) & 0x7fffffff)
        value = int((value * 16777619) & 0x7fffffff)
    return absi(value)

func stable_json(value) -> String:
    if value is Dictionary:
        var dict: Dictionary = value
        var keys := dict.keys()
        keys.sort()
        var parts: Array[String] = []
        for key in keys:
            parts.append("%s:%s" % [JSON.stringify(String(key)), stable_json(dict[key])])
        return "{%s}" % ",".join(parts)
    if value is Array:
        var parts: Array[String] = []
        for item in value:
            parts.append(stable_json(item))
        return "[%s]" % ",".join(parts)
    return JSON.stringify(value)

func string_array(value) -> Array:
    var result: Array = []
    if value is Array:
        for item in value:
            result.append(String(item))
    return result

func dictionary_value(value) -> Dictionary:
    if value is Dictionary:
        return value.duplicate(true)
    return {}
