extends RefCounted
class_name WorldmarkTraitCatalog

const MOVEMENT := {
    "charge": { "id": "charge", "family": "movement", "label": "Charge" },
    "flight": { "id": "flight", "family": "movement", "label": "Flight" },
    "burrow": { "id": "burrow", "family": "movement", "label": "Burrow" },
    "stalk": { "id": "stalk", "family": "movement", "label": "Stalk" },
    "hover": { "id": "hover", "family": "movement", "label": "Hover" }
}

const ATTACK := {
    "sweep": { "id": "sweep", "family": "attack", "label": "Sweep" },
    "projectile": { "id": "projectile", "family": "attack", "label": "Projectile" },
    "pulse": { "id": "pulse", "family": "attack", "label": "Pulse" },
    "summon": { "id": "summon", "family": "attack", "label": "Summon" },
    "terrain_burst": { "id": "terrain_burst", "family": "attack", "label": "Terrain Burst" }
}

const DEFENSE := {
    "armor": { "id": "armor", "family": "defense", "label": "Armor" },
    "regeneration": { "id": "regeneration", "family": "defense", "label": "Regeneration" },
    "mist": { "id": "mist", "family": "defense", "label": "Mist" },
    "shield": { "id": "shield", "family": "defense", "label": "Shield" },
    "burrow_escape": { "id": "burrow_escape", "family": "defense", "label": "Burrow Escape" }
}

const CONDITION := {
    "wounded": { "id": "wounded", "family": "condition", "label": "Wounded" },
    "corrupted": { "id": "corrupted", "family": "condition", "label": "Corrupted" },
    "trapped": { "id": "trapped", "family": "condition", "label": "Trapped" },
    "starving": { "id": "starving", "family": "condition", "label": "Starving" },
    "enraged": { "id": "enraged", "family": "condition", "label": "Enraged" },
    "protecting": { "id": "protecting", "family": "condition", "label": "Protecting" },
    "bound": { "id": "bound", "family": "condition", "label": "Bound" }
}

const RESOLUTION := {
    "slay": { "id": "slay", "family": "resolution", "label": "Slay" },
    "heal": { "id": "heal", "family": "resolution", "label": "Heal" },
    "release": { "id": "release", "family": "resolution", "label": "Release" },
    "relocate": { "id": "relocate", "family": "resolution", "label": "Relocate" },
    "bind": { "id": "bind", "family": "resolution", "label": "Bind" },
    "bargain": { "id": "bargain", "family": "resolution", "label": "Bargain" }
}

static func category_map(category: String) -> Dictionary:
    match category:
        "movement":
            return MOVEMENT.duplicate(true)
        "attack":
            return ATTACK.duplicate(true)
        "defense":
            return DEFENSE.duplicate(true)
        "condition":
            return CONDITION.duplicate(true)
        "resolution":
            return RESOLUTION.duplicate(true)
    return {}

static func has_trait(category: String, trait_id: String) -> bool:
    return category_map(category).has(trait_id)

static func ids(category: String) -> Array[String]:
    var result: Array[String] = []
    for key in category_map(category).keys():
        result.append(String(key))
    result.sort()
    return result

static func all_traits() -> Dictionary:
    return {
        "movement": MOVEMENT.duplicate(true),
        "attack": ATTACK.duplicate(true),
        "defense": DEFENSE.duplicate(true),
        "condition": CONDITION.duplicate(true),
        "resolution": RESOLUTION.duplicate(true)
    }
