extends RefCounted

## Test-only policy for headed playtests that can observe the world at night.
## It protects only the production player SurvivalSystem. NPC health, hostile AI,
## schedules, navigation, weather, lighting, and world time remain untouched.

static func enable_player_god_mode(main: Node, reason: String) -> Dictionary:
    var result := {
        "required": true,
        "enabled": false,
        "reason": reason,
        "scope": "player_survival_damage_only",
        "preserves": [
            "world_time",
            "night_lighting",
            "weather",
            "hostile_behavior",
            "npc_health",
            "npc_schedules",
            "npc_navigation"
        ],
        "failure": ""
    }
    if main == null or not is_instance_valid(main):
        result["failure"] = "main_missing"
        return result
    var survival = main.get("survival_system")
    if survival == null:
        result["failure"] = "survival_system_missing"
        return result
    if not survival.has_method("set_test_god_mode"):
        result["failure"] = "set_test_god_mode_missing"
        return result
    survival.call("set_test_god_mode", true, reason)
    var state: Dictionary = survival.call("test_god_mode_state") \
        if survival.has_method("test_god_mode_state") \
        else {"enabled": false, "reason": "state_unavailable"}
    result["enabled"] = bool(state.get("enabled", false))
    result["reason"] = String(state.get("reason", reason))
    if not bool(result["enabled"]):
        result["failure"] = "god_mode_not_enabled"
    return result
