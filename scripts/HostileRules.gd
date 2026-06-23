extends RefCounted
class_name HostileRules

static func awareness_radius(enemy: Dictionary) -> float:
    var variant := String(enemy.get("variant", ""))
    if variant == "rift":
        return 36.0
    return 30.0 if variant == "seer" else 24.0

static func leash_radius(enemy: Dictionary) -> float:
    var variant := String(enemy.get("variant", ""))
    if variant == "rift":
        return awareness_radius(enemy) + 24.0
    return awareness_radius(enemy) + (18.0 if variant == "seer" else 15.0)

static func random_roam_direction() -> Vector3:
    var angle := randf() * TAU
    return Vector3(cos(angle), 0.0, sin(angle)).normalized()
