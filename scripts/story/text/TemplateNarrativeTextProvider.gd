extends "res://scripts/story/text/NarrativeTextProvider.gd"
class_name TemplateNarrativeTextProvider

func generate(request_value, cache := {}) -> Dictionary:
    var request := normalize_request(request_value)
    var key := stable_request_key(request)
    return {
        "ok": true,
        "accepted": true,
        "cached": false,
        "source": "template",
        "fallbackReason": "",
        "requestKey": key,
        "text": template_text(request)
    }
