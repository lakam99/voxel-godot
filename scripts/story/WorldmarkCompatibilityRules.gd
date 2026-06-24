extends RefCounted
class_name WorldmarkCompatibilityRules

const TraitCatalog := preload("res://scripts/story/data/WorldmarkTraitCatalog.gd")

static func validate_definition(definition: Dictionary) -> Dictionary:
    var problems: Array[String] = []
    var definition_id := String(definition.get("id", ""))
    for field in ["id", "archetype", "conceptCore", "domain", "condition", "desire", "publicBeliefId", "hiddenTruthId"]:
        if not definition.has(field) or String(definition.get(field, "")).strip_edges() == "":
            problems.append("%s missing %s" % [definition_id, field])
    for field in ["regionalConsequence", "humanHistory"]:
        var value = definition.get(field, {})
        if not (value is Dictionary) or value.is_empty():
            problems.append("%s missing %s" % [definition_id, field])
    validate_trait_array(definition, "movementTraits", "movement", problems)
    validate_trait_array(definition, "attackTraits", "attack", problems)
    validate_trait_array(definition, "defenseTraits", "defense", problems)
    validate_resolution_array(definition, problems)
    validate_concept_compatibility(definition, problems)
    return {
        "ok": problems.is_empty(),
        "problems": problems
    }

static func validate_trait_array(definition: Dictionary, field: String, category: String, problems: Array[String]) -> void:
    var definition_id := String(definition.get("id", ""))
    var values = definition.get(field, [])
    if not (values is Array) or values.is_empty():
        problems.append("%s has no %s" % [definition_id, field])
        return
    for value in values:
        var trait_id := String(value)
        if not TraitCatalog.has_trait(category, trait_id):
            problems.append("%s unknown %s trait %s" % [definition_id, category, trait_id])

static func validate_resolution_array(definition: Dictionary, problems: Array[String]) -> void:
    var definition_id := String(definition.get("id", ""))
    var values = definition.get("resolutionFamilies", [])
    if not (values is Array) or values.size() < 2:
        problems.append("%s needs at least two resolution families" % definition_id)
        return
    for value in values:
        var resolution_id := String(value)
        if not TraitCatalog.has_trait("resolution", resolution_id):
            problems.append("%s unknown resolution family %s" % [definition_id, resolution_id])

static func validate_concept_compatibility(definition: Dictionary, problems: Array[String]) -> void:
    var definition_id := String(definition.get("id", ""))
    var domain := String(definition.get("domain", ""))
    var condition := String(definition.get("condition", ""))
    var movement: Array = definition.get("movementTraits", [])
    var attack: Array = definition.get("attackTraits", [])
    var defense: Array = definition.get("defenseTraits", [])
    var resolutions: Array = definition.get("resolutionFamilies", [])
    if not TraitCatalog.has_trait("condition", condition):
        problems.append("%s unknown condition %s" % [definition_id, condition])
    if domain == "spores_and_stillwater":
        if movement.has("flight") or movement.has("hover"):
            problems.append("%s fungal concept cannot use flight/hover" % definition_id)
        if not attack.has("terrain_burst") or not defense.has("regeneration"):
            problems.append("%s fungal concept must express root terrain and regrowth" % definition_id)
        if not resolutions.has("heal") and not resolutions.has("relocate"):
            problems.append("%s fungal concept needs repair or relocation resolution" % definition_id)
    elif domain == "ember_and_high_wind":
        if not movement.has("flight") or not movement.has("hover"):
            problems.append("%s ember concept must fly and hover" % definition_id)
        if not attack.has("projectile") or not attack.has("terrain_burst"):
            problems.append("%s ember concept needs airborne projectile and ground-fire pressure" % definition_id)
        if not resolutions.has("bargain") and not resolutions.has("bind"):
            problems.append("%s ember concept needs compact-style resolution" % definition_id)
    elif domain == "storm_and_light":
        if not movement.has("charge") or not attack.has("sweep") or not attack.has("pulse"):
            problems.append("%s storm guardian must preserve charge/sweep/pulse behavior" % definition_id)
        if not resolutions.has("slay") or not resolutions.has("release"):
            problems.append("%s storm guardian must preserve slay/release resolutions" % definition_id)

static func compatible_summary(definition: Dictionary) -> Dictionary:
    return {
        "definitionId": String(definition.get("id", "")),
        "conceptCore": String(definition.get("conceptCore", "")),
        "domain": String(definition.get("domain", "")),
        "condition": String(definition.get("condition", "")),
        "desire": String(definition.get("desire", "")),
        "movement": array_value(definition.get("movementTraits", [])),
        "attack": array_value(definition.get("attackTraits", [])),
        "defense": array_value(definition.get("defenseTraits", [])),
        "resolution": array_value(definition.get("resolutionFamilies", []))
    }

static func array_value(value) -> Array:
    if value is Array:
        return value.duplicate(true)
    return []
