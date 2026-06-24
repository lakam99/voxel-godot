extends RefCounted
class_name Phase13NarrativeTextProviderTests

const TemplateNarrativeTextProviderScript := preload("res://scripts/story/text/TemplateNarrativeTextProvider.gd")
const LocalLlmNarrativeTextProviderScript := preload("res://scripts/story/text/LocalLlmNarrativeTextProvider.gd")

func run(main, director) -> Dictionary:
    if main == null or director == null:
        return { "ok": false, "details": "main or director missing" }
    var request := text_request()
    var template_check := check_template_coverage(request)
    var provider_check := check_provider_failures(request)
    var cache_check := check_cache_and_save(main, director, request)
    director.set_narrative_text_provider(LocalLlmNarrativeTextProviderScript.new())
    var ok := bool(template_check.get("ok", false))
    ok = ok and bool(provider_check.get("ok", false))
    ok = ok and bool(cache_check.get("ok", false))
    return {
        "ok": ok,
        "details": "templates %s; failures %s; cache %s" % [
            String(template_check.get("details", "")),
            String(provider_check.get("details", "")),
            String(cache_check.get("details", ""))
        ]
    }

func check_template_coverage(request: Dictionary) -> Dictionary:
    var provider := TemplateNarrativeTextProviderScript.new()
    var ok := true
    var details: Array[String] = []
    for purpose in provider.supported_purposes():
        var purpose_request: Dictionary = request.duplicate(true)
        purpose_request["purpose"] = purpose
        var result: Dictionary = provider.generate(purpose_request, {})
        var text := String(result.get("text", ""))
        var purpose_ok := bool(result.get("ok", false))
        purpose_ok = purpose_ok and text != ""
        purpose_ok = purpose_ok and text.length() <= int(purpose_request.get("maxLength", 0))
        ok = ok and purpose_ok
        details.append("%s:%s" % [purpose, str(purpose_ok)])
    return {
        "ok": ok,
        "details": ", ".join(details)
    }

func check_provider_failures(request: Dictionary) -> Dictionary:
    var provider := LocalLlmNarrativeTextProviderScript.new()
    provider.set_service_enabled(false)
    var disabled := provider.generate(request, {})
    provider.set_service_enabled(true)
    provider.set_mock_timeout(true)
    var timeout := provider.generate(request, {})
    provider.set_mock_response("{not json")
    var malformed := provider.generate(request, {})
    provider.set_mock_response(JSON.stringify({ "line": "No text field" }))
    var schema_failure := provider.generate(request, {})
    provider.set_mock_response(JSON.stringify({ "text": "Mara says the old compact cage proves the Gloam Hart is trapped." }))
    var hidden_leak := provider.generate(request, {})
    provider.set_mock_response(JSON.stringify({ "text": "Mara promises a Rift Core reward if you exploit the Gloam Hart." }))
    var unsupported_claim := provider.generate(request, {})
    var ok := String(disabled.get("fallbackReason", "")) == "service_disabled"
    ok = ok and String(timeout.get("fallbackReason", "")) == "timeout"
    ok = ok and String(malformed.get("fallbackReason", "")).find("malformed_json") >= 0
    ok = ok and String(schema_failure.get("fallbackReason", "")).find("missing_text") >= 0
    ok = ok and String(hidden_leak.get("fallbackReason", "")).find("hidden_fact_leak") >= 0
    ok = ok and String(unsupported_claim.get("fallbackReason", "")).find("unsupported_claim") >= 0
    return {
        "ok": ok,
        "details": "%s/%s/%s/%s/%s/%s" % [
            disabled.get("fallbackReason", ""),
            timeout.get("fallbackReason", ""),
            malformed.get("fallbackReason", ""),
            schema_failure.get("fallbackReason", ""),
            hidden_leak.get("fallbackReason", ""),
            unsupported_claim.get("fallbackReason", "")
        ]
    }

func check_cache_and_save(main, director, request: Dictionary) -> Dictionary:
    var provider := LocalLlmNarrativeTextProviderScript.new()
    provider.set_service_enabled(true)
    provider.set_mock_response(JSON.stringify({ "text": "Mara says the Gloam Hart marks the fixed storm without naming a cause." }))
    director.set_narrative_text_provider(provider)
    var accepted: Dictionary = director.narrative_text(request)
    provider.set_mock_response("{bad cache bypass would fail")
    var cached: Dictionary = director.narrative_text(request)
    var save_snapshot: Dictionary = main.create_save_snapshot()
    var story_snapshot: Dictionary = dict_value(save_snapshot.get("story", {}))
    var generated_snapshot: Dictionary = dict_value(story_snapshot.get("generatedText", {}))
    var before_cache: Dictionary = dict_value(generated_snapshot.get("narrativeText", {}))
    var loaded := bool(main.apply_save_snapshot(save_snapshot))
    director = main.get("story_director")
    var after_story_snapshot: Dictionary = director.snapshot()
    var after_generated: Dictionary = dict_value(after_story_snapshot.get("generatedText", {}))
    var after_cache: Dictionary = dict_value(after_generated.get("narrativeText", {}))
    var accepted_key := String(accepted.get("requestKey", ""))
    var ok := String(accepted.get("source", "")) == "local_llm"
    ok = ok and accepted_key != ""
    ok = ok and before_cache.has(accepted_key)
    ok = ok and bool(cached.get("cached", false))
    ok = ok and String(cached.get("text", "")) == String(accepted.get("text", ""))
    ok = ok and loaded
    ok = ok and stable_json(before_cache) == stable_json(after_cache)
    return {
        "ok": ok,
        "details": "accepted %s cached %s save %s" % [
            accepted.get("source", ""),
            str(cached.get("cached", false)),
            str(stable_json(before_cache) == stable_json(after_cache))
        ]
    }

func text_request() -> Dictionary:
    return {
        "purpose": "rumor",
        "regionId": "r:2,-1",
        "worldmark": {
            "definitionId": "gloam_hart",
            "displayName": "Gloam Hart",
            "condition": "bound"
        },
        "publicFacts": [
            "the storm remains fixed over the tree line",
            "lantern attacks started after the boundary stones rang"
        ],
        "hiddenFacts": [
            "old compact cage",
            "lantern material came from the Hart"
        ],
        "hiddenFactsAllowed": false,
        "npc": {
            "id": "mara_trader",
            "name": "Mara",
            "knowledgeScope": ["public_town_rumor"]
        },
        "questStage": "travel_to_affected_region",
        "playerActions": ["rescued Niko", "spoke with Mira"],
        "resolution": "",
        "requiredTerms": ["Gloam Hart"],
        "unsupportedTerms": ["Rift Core", "reward", "new location", "kill Mira"],
        "allowedProperNouns": ["Mara", "Gloam Hart", "Niko", "Mira"],
        "maxLength": 150,
        "toneTags": ["frontier", "plainspoken"]
    }

func dict_value(value) -> Dictionary:
    if value is Dictionary:
        return value.duplicate(true)
    return {}

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
