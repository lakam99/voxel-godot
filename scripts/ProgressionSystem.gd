extends RefCounted
class_name ProgressionSystem

signal changed(state, leveled)

var level := 1
var xp := 0
var total_xp := 0
var recent := "No XP earned yet"

func reset() -> void:
    level = 1
    xp = 0
    total_xp = 0
    recent = "No XP earned yet"
    changed.emit(state(), false)

func xp_for_level(level_value := -1) -> int:
    var effective_level: int = level if int(level_value) <= 0 else int(level_value)
    return 80 + maxi(0, effective_level - 1) * 45

func bonuses(level_value := -1) -> Dictionary:
    var effective_level: int = level if int(level_value) <= 0 else int(level_value)
    var ranks: int = maxi(0, effective_level - 1)
    return {
        "health": mini(35, ranks * 5),
        "stamina": mini(35, ranks * 4),
        "hunger": mini(25, ranks * 3)
    }

func state() -> Dictionary:
    var needed := xp_for_level()
    return {
        "level": level,
        "xp": xp,
        "totalXp": total_xp,
        "needed": needed,
        "progress": clampf(float(xp) / float(maxi(1, needed)), 0.0, 1.0),
        "bonuses": bonuses(),
        "recent": recent
    }

func snapshot() -> Dictionary:
    return {
        "level": level,
        "xp": xp,
        "totalXp": total_xp
    }

func restore(snapshot_value = {}) -> void:
    var saved: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    level = maxi(1, floori(float(saved.get("level", 1))))
    xp = clampi(floori(float(saved.get("xp", 0))), 0, maxi(0, xp_for_level(level) - 1))
    total_xp = maxi(0, floori(float(saved.get("totalXp", xp))))
    recent = "Progress restored"
    changed.emit(state(), false)

func award(reason: String, amount := 1) -> bool:
    var gained: int = maxi(0, floori(float(amount)))
    if gained <= 0:
        return false

    xp += gained
    total_xp += gained
    var leveled := false
    while xp >= xp_for_level():
        xp -= xp_for_level()
        level += 1
        leveled = true

    recent = "Level %d: %s" % [level, reason] if leveled else "+%d XP %s" % [gained, reason]
    changed.emit(state(), leveled)
    return true
