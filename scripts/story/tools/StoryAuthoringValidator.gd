extends RefCounted
class_name StoryAuthoringValidator

const WorldmarkDefinitionScript := preload("res://scripts/story/data/WorldmarkDefinition.gd")
const WorldmarkCompatibilityRulesScript := preload("res://scripts/story/WorldmarkCompatibilityRules.gd")
const StorySitePlacementScript := preload("res://scripts/story/data/StorySitePlacement.gd")
const StoryQuestSystemScript := preload("res://scripts/story/StoryQuestSystem.gd")
const StoryWorldOverlaySystemScript := preload("res://scripts/story/StoryWorldOverlaySystem.gd")
const GloamHartEncounterScript := preload("res://scripts/story/encounters/GloamHartEncounter.gd")
const NarrativeTextProviderScript := preload("res://scripts/story/text/NarrativeTextProvider.gd")
const TemplateNarrativeTextProviderScript := preload("res://scripts/story/text/TemplateNarrativeTextProvider.gd")

const REQUIRED_GLOAM_HART_ANIMATIONS := [
    "idle_breathe",
    "walk_stalk",
    "charge_windup",
    "charge_recovery",
    "antler_sweep",
    "storm_pulse",
    "stagger_vulnerable",
    "death",
    "release_calm"
]

func validate_all() -> Dictionary:
    var categories := {
        "missingDefinitions": [],
        "textKeys": [],
        "animationStates": [],
        "clueSites": [],
        "incompatibleTraits": [],
        "fallbackGaps": [],
        "pacing": []
    }
    validate_definitions(categories)
    validate_text_keys(categories)
    validate_animation_states(categories)
    validate_clue_sites(categories)
    validate_fallbacks(categories)
    validate_pacing(categories)
    var problems: Array[String] = []
    for category in categories.keys():
        for problem in categories[category]:
            problems.append("%s: %s" % [String(category), String(problem)])
    return {
        "ok": problems.is_empty(),
        "problems": problems,
        "categories": categories,
        "counts": {
            "definitions": WorldmarkDefinitionScript.definitions().size(),
            "siteDefinitions": StorySitePlacementScript.SITE_DEFINITIONS.size(),
            "animationStates": GloamHartEncounterScript.ANIMATION_DURATIONS.size(),
            "templatePurposes": NarrativeTextProviderScript.SUPPORTED_PURPOSES.size()
        }
    }

func validate_definitions(categories: Dictionary) -> void:
    var definitions := WorldmarkDefinitionScript.definitions()
    for definition_id in WorldmarkDefinitionScript.definition_ids():
        if not definitions.has(definition_id):
            categories["missingDefinitions"].append("%s has no definition" % definition_id)
    for definition_id in definitions.keys():
        var definition: Dictionary = definitions[definition_id]
        var compatibility: Dictionary = WorldmarkCompatibilityRulesScript.validate_definition(definition)
        for problem in compatibility.get("problems", []):
            categories["incompatibleTraits"].append(String(problem))

func validate_text_keys(categories: Dictionary) -> void:
    for definition in WorldmarkDefinitionScript.definitions().values():
        for field in ["titleId", "displayNameId", "publicBeliefId", "hiddenTruthId"]:
            var key := String(definition.get(field, ""))
            if key == "" or (field.ends_with("Id") and field != "publicBeliefId" and field != "hiddenTruthId" and not key.begins_with("story.")):
                categories["textKeys"].append("%s missing valid %s" % [String(definition.get("id", "")), field])
    for site in StorySitePlacementScript.SITE_DEFINITIONS:
        var text_id := String(site.get("textId", ""))
        if text_id == "" or not text_id.begins_with("story."):
            categories["textKeys"].append("%s missing story textId" % String(site.get("id", "")))
    var stage_text_ids := {
        "speak_with_mira": "story.gloam_hart.stage.speak_with_mira",
        "speak_with_sera": "story.gloam_hart.stage.speak_with_sera",
        "travel_to_affected_region": "story.gloam_hart.stage.travel_to_affected_region",
        "find_ordinary_clues": "story.gloam_hart.stage.find_ordinary_clues",
        "optional_find_historical_clue": "story.gloam_hart.stage.optional_find_historical_clue",
        "prepare_countermeasure_placeholder": "story.gloam_hart.stage.prepare_countermeasure_placeholder",
        "retune_boundary_stones_placeholder": "story.gloam_hart.stage.retune_boundary_stones_placeholder",
        "encounter_locked_placeholder": "story.gloam_hart.stage.encounter_locked_placeholder",
        "worldmark_resolved": "story.gloam_hart.stage.worldmark_resolved"
    }
    for stage in StoryQuestSystemScript.STAGE_ORDER:
        if not stage_text_ids.has(stage):
            categories["textKeys"].append("stage %s missing text key" % stage)

func validate_animation_states(categories: Dictionary) -> void:
    for state in REQUIRED_GLOAM_HART_ANIMATIONS:
        if not GloamHartEncounterScript.ANIMATION_DURATIONS.has(state):
            categories["animationStates"].append("Gloam Hart missing %s" % state)
        elif float(GloamHartEncounterScript.ANIMATION_DURATIONS[state]) <= 0.0:
            categories["animationStates"].append("Gloam Hart %s has non-positive duration" % state)

func validate_clue_sites(categories: Dictionary) -> void:
    var ordinary := 0
    var historical := 0
    var boundary := 0
    var encounter := 0
    var site_ids := {}
    for site in StorySitePlacementScript.SITE_DEFINITIONS:
        var site_id := String(site.get("id", ""))
        site_ids[site_id] = true
        var kind := String(site.get("kind", ""))
        var clue_kind := String(site.get("clueKind", ""))
        if kind == "clue" and clue_kind == "ordinary":
            ordinary += 1
        elif kind == "clue" and clue_kind == "historical":
            historical += 1
        elif kind == "boundary_stone":
            boundary += 1
        elif kind == "encounter_marker":
            encounter += 1
    if ordinary < StoryQuestSystemScript.ORDINARY_CLUES_REQUIRED:
        categories["clueSites"].append("ordinary clues %d below required %d" % [ordinary, StoryQuestSystemScript.ORDINARY_CLUES_REQUIRED])
    if ordinary != 3 or historical != 1 or boundary != 2 or encounter != 1:
        categories["clueSites"].append("unexpected site counts ordinary=%d historical=%d boundary=%d encounter=%d" % [ordinary, historical, boundary, encounter])
    var gloam := WorldmarkDefinitionScript.definition_for_id("gloam_hart")
    for sign in gloam.get("signs", []):
        if sign is Dictionary and not site_ids.has(String(sign.get("id", ""))):
            categories["clueSites"].append("Gloam Hart sign %s has no site definition" % String(sign.get("id", "")))

func validate_fallbacks(categories: Dictionary) -> void:
    var overlay := StoryWorldOverlaySystemScript.new()
    for site in StorySitePlacementScript.SITE_DEFINITIONS:
        var generated_site: Dictionary = site.duplicate(true)
        generated_site["definitionId"] = String(site.get("id", ""))
        var text := overlay.authored_text_for_site(generated_site)
        if text == "" or text == String(site.get("label", "Story sign")):
            categories["fallbackGaps"].append("%s missing authored fallback" % String(site.get("id", "")))
    overlay.queue_free()
    var provider := TemplateNarrativeTextProviderScript.new()
    for purpose in NarrativeTextProviderScript.SUPPORTED_PURPOSES:
        var result: Dictionary = provider.generate({
            "purpose": String(purpose),
            "regionId": "r:0,0",
            "worldmark": { "definitionId": "gloam_hart", "displayName": "Gloam Hart" },
            "publicFacts": ["the storm stays near the old lantern line"],
            "npc": { "name": "Mira" },
            "resolution": "release"
        })
        if String(result.get("text", "")).strip_edges() == "":
            categories["fallbackGaps"].append("template purpose %s returned no text" % String(purpose))

func validate_pacing(categories: Dictionary) -> void:
    if StoryQuestSystemScript.STAGE_ORDER.size() < 8:
        categories["pacing"].append("first quest stage order is too short")
    if StoryQuestSystemScript.STAGE_ORDER.find("prepare_countermeasure_placeholder") > StoryQuestSystemScript.STAGE_ORDER.find("retune_boundary_stones_placeholder"):
        categories["pacing"].append("countermeasure stage must precede boundary retune")
    if StoryQuestSystemScript.STAGE_ORDER.find("retune_boundary_stones_placeholder") > StoryQuestSystemScript.STAGE_ORDER.find("encounter_locked_placeholder"):
        categories["pacing"].append("boundary retune must precede encounter unlock")
