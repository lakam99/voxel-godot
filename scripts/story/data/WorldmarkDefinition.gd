extends RefCounted
class_name WorldmarkDefinition

static func definition_ids() -> Array[String]:
    return ["gloam_hart", "mire_bloom_colossus", "cinderwing_ember"]

static func definitions() -> Dictionary:
    var result := {}
    for definition in [gloam_hart(), mire_bloom_colossus(), cinderwing_ember()]:
        result[String(definition.get("id", ""))] = definition
    return result

static func definition_for_id(definition_id: String) -> Dictionary:
    return definitions().get(definition_id, {}).duplicate(true)

static func gloam_hart() -> Dictionary:
    return {
        "id": "gloam_hart",
        "arcId": "storm_that_stays",
        "titleId": "story.gloam_hart.title",
        "displayNameId": "story.gloam_hart.name",
        "archetype": "wounded guardian",
        "conceptCore": "A storm-bound hart caught inside an old lantern compact.",
        "domain": "storm_and_light",
        "condition": "bound",
        "desire": "silence_the_old_lanterns",
        "regionalConsequence": {
            "weather": "storm_that_stays",
            "hostilePressure": "night_shards_gather",
            "settlementThreat": "outer_lantern_line_breaks"
        },
        "humanHistory": {
            "compact": "old_lantern_compact",
            "wound": "lanterns meant as mercy became a cage"
        },
        "publicBeliefId": "gloam_hart_public",
        "hiddenTruthId": "gloam_hart_truth",
        "publicBelief": "People blame a monster for breaking lamps and calling storms.",
        "hiddenTruth": "The old compact was meant to spare the Hart, not bind it.",
        "movementTraits": ["charge", "stalk"],
        "attackTraits": ["sweep", "pulse", "summon"],
        "defenseTraits": ["shield"],
        "minionTraits": ["storm_shards"],
        "preparationFamilies": ["survey_lens", "ward_lantern", "boundary_retune"],
        "resolutionFamilies": ["slay", "release"],
        "aftermathPossibilities": {
            "slay": ["guard_confidence", "slow_wildlife_recovery", "hart_trophy_memorial"],
            "release": ["fast_wildlife_recovery", "nature_route", "living_compact_marker"]
        },
        "signs": [
            { "id": "ordinary_antler_scars", "kind": "ordinary", "cause": "bound movement tears bark away from the lantern line" },
            { "id": "ordinary_ringing_stone", "kind": "ordinary", "cause": "boundary stones still answer the old compact" },
            { "id": "ordinary_broken_lantern", "kind": "ordinary", "cause": "the Hart pushes against lantern light rather than the settlement" },
            { "id": "historical_old_compact", "kind": "historical", "cause": "town records preserve the intended release route" }
        ]
    }

static func mire_bloom_colossus() -> Dictionary:
    return {
        "id": "mire_bloom_colossus",
        "arcId": "regional_worldmark",
        "titleId": "story.worldmark.mire_bloom.title",
        "displayNameId": "story.worldmark.mire_bloom.name",
        "archetype": "fungal keeper",
        "conceptCore": "A starving mycelial guardian spreads through stagnant water after its nursery was drained.",
        "domain": "spores_and_stillwater",
        "condition": "starving",
        "desire": "feed_the_buried_network",
        "regionalConsequence": {
            "weather": "heavy_mist",
            "hostilePressure": "sporelings_follow_warmth",
            "settlementThreat": "wells_sour_and_paths_sink"
        },
        "humanHistory": {
            "compact": "peat_cutters_drainage_map",
            "wound": "the old fungal nursery was cut away to dry a trade road"
        },
        "publicBeliefId": "mire_bloom_public",
        "hiddenTruthId": "mire_bloom_truth",
        "publicBelief": "The swamp is said to be rotting villages from below.",
        "hiddenTruth": "The Worldmark is starving because the settlement diverted its water and root bed.",
        "movementTraits": ["burrow", "stalk"],
        "attackTraits": ["summon", "terrain_burst", "pulse"],
        "defenseTraits": ["regeneration", "mist", "burrow_escape"],
        "minionTraits": ["sporelings"],
        "preparationFamilies": ["clean_water", "sun_salt", "root_map"],
        "resolutionFamilies": ["slay", "heal", "relocate"],
        "aftermathPossibilities": {
            "slay": ["dry_trade_road", "lingering_spores", "mire_watch_post"],
            "heal": ["clean_wells", "mushroom_harvest", "root_pact"],
            "relocate": ["safe_causeway", "new_nursery", "swamp_guides"]
        },
        "signs": [
            { "id": "spore_ring_well", "kind": "ordinary", "cause": "the hungry network reaches toward stored water" },
            { "id": "sunken_cart_path", "kind": "ordinary", "cause": "roots pull down the trade road that cut the nursery" },
            { "id": "glowing_mire_cap", "kind": "ordinary", "cause": "fruiting bodies mark the buried guardian's path" },
            { "id": "peat_cutters_map", "kind": "historical", "cause": "old drainage records reveal the injury" }
        ]
    }

static func cinderwing_ember() -> Dictionary:
    return {
        "id": "cinderwing_ember",
        "arcId": "regional_worldmark",
        "titleId": "story.worldmark.cinderwing.title",
        "displayNameId": "story.worldmark.cinderwing.name",
        "archetype": "flying ember",
        "conceptCore": "A high-wind ember creature circles above kiln towns after its coal-egg was taken.",
        "domain": "ember_and_high_wind",
        "condition": "enraged",
        "desire": "recover_the_stolen_coal_egg",
        "regionalConsequence": {
            "weather": "ash_wind",
            "hostilePressure": "cinder_sparks_nest_in_ruins",
            "settlementThreat": "roof_fires_and_closed_passes"
        },
        "humanHistory": {
            "compact": "kiln_makers_ledger",
            "wound": "a coal-egg was mistaken for rare fuel and built into a forge"
        },
        "publicBeliefId": "cinderwing_public",
        "hiddenTruthId": "cinderwing_truth",
        "publicBelief": "Travelers say a firebird hunts caravans for sport.",
        "hiddenTruth": "The ember is searching for its stolen coal-egg and follows the forge smoke.",
        "movementTraits": ["flight", "hover", "charge"],
        "attackTraits": ["projectile", "terrain_burst", "pulse"],
        "defenseTraits": ["mist", "shield"],
        "minionTraits": ["cinder_sparks"],
        "preparationFamilies": ["cooling_charm", "high_perch_lure", "coal_egg_record"],
        "resolutionFamilies": ["slay", "bind", "bargain"],
        "aftermathPossibilities": {
            "slay": ["ember_blade_recipe", "fire_watch_confidence", "scarred_roost"],
            "bind": ["forge_heat_stabilized", "guarded_roost", "ashfall_reduced"],
            "bargain": ["safe_sky_route", "forge_compact", "occasional_ember_aid"]
        },
        "signs": [
            { "id": "glass_scorched_grass", "kind": "ordinary", "cause": "hovering heat fuses sand and grass" },
            { "id": "roof_ash_spiral", "kind": "ordinary", "cause": "the ember circles above smoke trails" },
            { "id": "molten_perch_mark", "kind": "ordinary", "cause": "claws hold stone until it softens" },
            { "id": "kiln_ledger_coal_egg", "kind": "historical", "cause": "forge records identify the stolen coal-egg" }
        ]
    }

static func worldmark_state(region_id: String, definition: Dictionary) -> Dictionary:
    if definition.is_empty():
        return {}
    return {
        "id": "worldmark:%s" % region_id,
        "definitionId": String(definition.get("id", "")),
        "arcId": String(definition.get("arcId", "")),
        "titleId": String(definition.get("titleId", "")),
        "displayNameId": String(definition.get("displayNameId", "")),
        "archetype": String(definition.get("archetype", "")),
        "conceptCore": String(definition.get("conceptCore", "")),
        "domain": String(definition.get("domain", "")),
        "condition": String(definition.get("condition", "")),
        "desire": String(definition.get("desire", "")),
        "regionalConsequence": dictionary_value(definition.get("regionalConsequence", {})),
        "humanHistory": dictionary_value(definition.get("humanHistory", {})),
        "publicBeliefId": String(definition.get("publicBeliefId", "")),
        "hiddenTruthId": String(definition.get("hiddenTruthId", "")),
        "publicBelief": String(definition.get("publicBelief", "")),
        "hiddenTruth": String(definition.get("hiddenTruth", "")),
        "movementTraits": array_value(definition.get("movementTraits", [])),
        "attackTraits": array_value(definition.get("attackTraits", [])),
        "defenseTraits": array_value(definition.get("defenseTraits", [])),
        "minionTraits": array_value(definition.get("minionTraits", [])),
        "preparationFamilies": array_value(definition.get("preparationFamilies", [])),
        "resolutionFamilies": array_value(definition.get("resolutionFamilies", [])),
        "aftermathPossibilities": dictionary_value(definition.get("aftermathPossibilities", {})),
        "signs": array_value(definition.get("signs", [])),
        "foundClueIds": [],
        "preparationFlags": {},
        "encounterState": {},
        "resolution": ""
    }

static func apply_to_existing(region_id: String, definition: Dictionary, existing_value) -> Dictionary:
    var existing: Dictionary = dictionary_value(existing_value)
    var state := worldmark_state(region_id, definition)
    for key in ["foundClueIds", "preparationFlags", "encounterState", "resolution", "aftermathState"]:
        if existing.has(key):
            var value = existing[key]
            if value is Dictionary or value is Array:
                state[key] = value.duplicate(true)
            else:
                state[key] = value
    return state

static func dictionary_value(value) -> Dictionary:
    if value is Dictionary:
        return value.duplicate(true)
    return {}

static func array_value(value) -> Array:
    if value is Array:
        return value.duplicate(true)
    return []
