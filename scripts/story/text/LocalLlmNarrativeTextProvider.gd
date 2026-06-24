extends "res://scripts/story/text/NarrativeTextProvider.gd"
class_name LocalLlmNarrativeTextProvider

var service_enabled := false
var timeout_ms := 120
var mock_response_text := ""
var mock_timeout := false

func set_service_enabled(enabled: bool) -> void:
    service_enabled = enabled

func set_timeout_ms(value: int) -> void:
    timeout_ms = clampi(value, 1, 1000)

func set_mock_response(response_text: String) -> void:
    mock_response_text = response_text
    mock_timeout = false

func set_mock_timeout(enabled: bool) -> void:
    mock_timeout = enabled

func generate(request_value, cache := {}) -> Dictionary:
    var request := normalize_request(request_value)
    var key := stable_request_key(request)
    if cache is Dictionary and cache.has(key):
        return {
            "ok": true,
            "accepted": true,
            "cached": true,
            "source": "cache",
            "fallbackReason": "",
            "requestKey": key,
            "text": String(cache[key])
        }
    if not service_enabled:
        return template_result(request, "service_disabled")
    if mock_timeout:
        return template_result(request, "timeout")
    if mock_response_text == "":
        return template_result(request, "service_absent")
    var validation := validate_response_json(mock_response_text, request)
    if not bool(validation.get("ok", false)):
        return template_result(request, ";".join(validation.get("problems", [])))
    var text := String(validation.get("text", ""))
    if cache is Dictionary:
        cache[key] = text
    return {
        "ok": true,
        "accepted": true,
        "cached": false,
        "source": "local_llm",
        "fallbackReason": "",
        "requestKey": key,
        "text": text
    }
