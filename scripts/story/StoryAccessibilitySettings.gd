extends Node
class_name StoryAccessibilitySettings

const DEFAULTS := {
    "storyTextSpeed": 2.0,
    "storySubtitles": true,
    "storyJournalFontScale": 1.0,
    "storyColorIndependentClues": true,
    "storyReplayDiscoveredText": true,
    "storyControllerNavigation": true
}

var main
var settings := DEFAULTS.duplicate(true)

func setup(main_node) -> void:
    main = main_node

func apply_runtime_settings(values: Dictionary) -> Dictionary:
    for key in DEFAULTS.keys():
        if values.has(key):
            apply_setting(String(key), values[key])
    return state()

func apply_setting(setting: String, value) -> bool:
    match setting:
        "storyTextSpeed":
            settings[setting] = clampf(float(value), 0.5, 2.0)
        "storyJournalFontScale":
            settings[setting] = clampf(float(value), 0.85, 1.35)
        "storySubtitles", "storyColorIndependentClues", "storyReplayDiscoveredText", "storyControllerNavigation":
            settings[setting] = bool(value)
        _:
            return false
    return true

func state() -> Dictionary:
    return settings.duplicate(true)

func dialogue_characters_per_second() -> float:
    var speed := float(settings.get("storyTextSpeed", DEFAULTS["storyTextSpeed"]))
    if speed >= 1.95:
        return -1.0
    return lerpf(24.0, 90.0, inverse_lerp(0.5, 1.95, speed))

func journal_font_size(base_size: int) -> int:
    return maxi(10, roundi(float(base_size) * float(settings.get("storyJournalFontScale", 1.0))))

func bool_value(setting: String, fallback := true) -> bool:
    return bool(settings.get(setting, fallback))
