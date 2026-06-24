extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const RegionStoryGeneratorScript := preload("res://scripts/story/RegionStoryGenerator.gd")
const StoryEventBusScript := preload("res://scripts/story/StoryEventBus.gd")
const StoryDirectorScript := preload("res://scripts/story/StoryDirector.gd")
const StoryQuestSystemScript := preload("res://scripts/story/StoryQuestSystem.gd")
const FrontierCampaignSpineScript := preload("res://scripts/story/campaign/FrontierCampaignSpine.gd")
const TemplateNarrativeTextProviderScript := preload("res://scripts/story/text/TemplateNarrativeTextProvider.gd")
const LocalLlmNarrativeTextProviderScript := preload("res://scripts/story/text/LocalLlmNarrativeTextProvider.gd")
const Phase13NarrativeTextProviderTestsScript := preload("res://scripts/story/testing/Phase13NarrativeTextProviderTests.gd")
const Phase14StoryPolishTestsScript := preload("res://scripts/story/testing/Phase14StoryPolishTests.gd")
const GloamHartArcScript := preload("res://scripts/story/arcs/GloamHartArc.gd")
const StorySitePlacementScript := preload("res://scripts/story/data/StorySitePlacement.gd")
const RegionStoryRecordScript := preload("res://scripts/story/data/RegionStoryRecord.gd")
const WorldmarkStateScript := preload("res://scripts/story/data/WorldmarkState.gd")
const StoryQuestStateScript := preload("res://scripts/story/data/StoryQuestState.gd")
const WorldmarkDefinitionScript := preload("res://scripts/story/data/WorldmarkDefinition.gd")
const WorldmarkTraitCatalogScript := preload("res://scripts/story/data/WorldmarkTraitCatalog.gd")
const WorldmarkGeneratorScript := preload("res://scripts/story/WorldmarkGenerator.gd")
const WorldmarkCompatibilityRulesScript := preload("res://scripts/story/WorldmarkCompatibilityRules.gd")
const StoryWorldOverlaySystemScript := preload("res://scripts/story/StoryWorldOverlaySystem.gd")
const WorldmarkInfluenceSystemScript := preload("res://scripts/story/WorldmarkInfluenceSystem.gd")
const StoryJournalModelScript := preload("res://scripts/story/StoryJournalModel.gd")
const StoryDialogueRouterScript := preload("res://scripts/story/StoryDialogueRouter.gd")
const NpcKnowledgeScopeScript := preload("res://scripts/story/data/NpcKnowledgeScope.gd")
const WorldmarkEncounterControllerScript := preload("res://scripts/story/encounters/WorldmarkEncounterController.gd")
const GloamHartEncounterScript := preload("res://scripts/story/encounters/GloamHartEncounter.gd")
const SettlementStateSystemScript := preload("res://scripts/story/SettlementStateSystem.gd")
const RegionAftermathSystemScript := preload("res://scripts/story/RegionAftermathSystem.gd")
const StoryAccessibilitySettingsScript := preload("res://scripts/story/StoryAccessibilitySettings.gd")
const StoryDebugToolsScript := preload("res://scripts/story/tools/StoryDebugTools.gd")
const StoryAuthoringValidatorScript := preload("res://scripts/story/tools/StoryAuthoringValidator.gd")

const FIRST_QUEST_ID := "story.gloam_hart.storm"

const SCRIPT_PATHS := [
    "res://scripts/Main.gd",
    "res://scripts/MainCore.gd",
    "res://scripts/MainSaveState.gd",
    "res://scripts/SaveSystem.gd",
    "res://scripts/TutorialSystem.gd",
    "res://scripts/TutorialDialogueSystem.gd",
    "res://scripts/TutorialRepairQuest.gd",
    "res://scripts/TutorialRescueSystem.gd",
    "res://scripts/MainWorldEntities.gd",
    "res://scripts/ObjectiveSystem.gd",
    "res://scripts/ContractSystem.gd",
    "res://scripts/NpcSystem.gd",
    "res://scripts/HostileSystem.gd",
    "res://scripts/WeatherSystem.gd",
    "res://scripts/GameHud.gd",
    "res://scripts/story/StoryEventBus.gd",
    "res://scripts/story/StoryDirector.gd",
    "res://scripts/story/StoryQuestSystem.gd",
    "res://scripts/story/campaign/FrontierCampaignSpine.gd",
    "res://scripts/story/text/NarrativeTextProvider.gd",
    "res://scripts/story/text/TemplateNarrativeTextProvider.gd",
    "res://scripts/story/text/LocalLlmNarrativeTextProvider.gd",
    "res://scripts/story/testing/Phase13NarrativeTextProviderTests.gd",
    "res://scripts/story/testing/Phase14StoryPolishTests.gd",
    "res://scripts/story/arcs/GloamHartArc.gd",
    "res://scripts/story/RegionStoryGenerator.gd",
    "res://scripts/story/data/StorySitePlacement.gd",
    "res://scripts/story/data/RegionStoryRecord.gd",
    "res://scripts/story/data/WorldmarkState.gd",
    "res://scripts/story/data/StoryQuestState.gd",
    "res://scripts/story/data/WorldmarkDefinition.gd",
    "res://scripts/story/data/WorldmarkTraitCatalog.gd",
    "res://scripts/story/WorldmarkGenerator.gd",
    "res://scripts/story/WorldmarkCompatibilityRules.gd",
    "res://scripts/story/StoryInteractable.gd",
    "res://scripts/story/StoryWorldOverlaySystem.gd",
    "res://scripts/story/WorldmarkInfluenceSystem.gd",
    "res://scripts/story/StoryJournalModel.gd",
    "res://scripts/story/StoryDialogueRouter.gd",
    "res://scripts/story/StoryAccessibilitySettings.gd",
    "res://scripts/story/data/NpcKnowledgeScope.gd",
    "res://scripts/story/SettlementStateSystem.gd",
    "res://scripts/story/RegionAftermathSystem.gd",
    "res://scripts/story/encounters/WorldmarkEncounterController.gd",
    "res://scripts/story/encounters/GloamHartEncounter.gd",
    "res://scripts/story/tools/StoryDebugTools.gd",
    "res://scripts/story/tools/StoryAuthoringValidator.gd",
    "res://scripts/visual/VisualAssetRegistry.gd",
    "res://scripts/visual/CharacterAssetRegistry.gd",
    "res://scripts/visual/StaticItemAssetRegistry.gd",
    "res://scripts/visual/AnimatedAssetRegistry.gd"
]

const SCENE_PATHS := [
    "res://scenes/story/StoryInteractable.tscn",
    "res://scenes/story/GloamHartEncounter.tscn"
]

var main: Node3D
var results: Array[Dictionary] = []
var failed := false
var finished := false
var elapsed := 0.0

func _ready() -> void:
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += delta
    if elapsed > 16.0:
        add_result("story_runner_watchdog", false, "runner timed out before completion")
        finish()

func run() -> void:
    mark_progress("start")
    add_result("story_runner_bootstraps", true, "StoryPlaytestRunner ready")
    test_project_scripts_load()
    test_region_id_floor_division()
    test_region_records_deterministic()
    test_phase3_region_record_validation_and_reset_restore_suppression()
    test_worldmark_trait_catalog_and_compatibility()
    test_concept_first_worldmark_generation_prototypes()
    test_gloam_hart_definition_preserves_first_arc_contract()
    test_duplicate_events_do_not_duplicate_story_effects()
    await test_main_scene_instantiates()
    test_phase12_campaign_spine_progression_and_endless_play()
    test_phase13_narrative_text_provider_contracts()
    test_phase14_story_polish_accessibility_debug_authoring()
    test_phase4_source_events_and_quest_state_round_trip()
    test_first_arc_waits_for_tutorial_completion()
    test_tutorial_completion_starts_first_quest_once()
    test_phase5_gloam_hart_handoff_opening_contract()
    test_mira_event_advances_only_mira_stage()
    test_sera_event_requires_mira_stage()
    test_affected_region_entry_advances_travel_stage()
    test_story_sites_are_valid_deterministic_and_saved()
    test_story_region_overlay_and_influence_clear_on_exit()
    test_story_interactable_boundary_and_encounter_events()
    test_boundary_retune_costs_and_failed_attempts()
    test_boundary_retune_duplicate_persistence_and_storm_weakening()
    test_history_clue_gates_release_route_after_boundary_retune()
    test_gloam_hart_encounter_phase_progression_countermeasure_and_animation_fallback()
    test_gloam_hart_slay_resolution_idempotent_rewards_and_cleanup()
    test_gloam_hart_release_gating_and_resolution()
    test_gloam_hart_release_normal_input_affordance()
    test_gloam_hart_save_load_recovery_policy()
    test_worldmark_aftermath_slay_delayed_settlement_and_dialogue()
    test_worldmark_aftermath_release_wildlife_trade_and_save_load()
    test_ordinary_clues_count_idempotently()
    test_story_interactable_clues_dedupe_and_progress()
    test_historical_clue_unlock_persists_and_quest_round_trips()
    test_optional_history_interactable_state_persists_and_sites_round_trips()
    test_story_journal_hides_hidden_truth_until_history()
    test_phase_b_navigation_and_journal_clarity()
    test_story_dialogue_router_filters_npc_knowledge()
    test_story_dialogue_router_generic_fallback()
    test_story_journal_save_load_round_trips()
    await test_story_journal_ui_viewports()
    test_story_snapshot_save_load_preserves_records_exactly()
    test_old_save_without_story_field_loads()
    test_story_artifacts_directory_writable()
    add_result("story_runner_exit_code_policy", true, "runner exits 0 on success and 1 on failure")
    finish()

func test_project_scripts_load() -> void:
    var failures: Array[String] = []
    for path in SCRIPT_PATHS:
        if not ResourceLoader.exists(path):
            failures.append("%s missing" % path)
            continue
        var script_resource := load(path)
        if script_resource == null:
            failures.append("%s failed to load" % path)
    for path in SCENE_PATHS:
        if not ResourceLoader.exists(path):
            failures.append("%s missing" % path)
            continue
        var scene_resource := load(path)
        if scene_resource == null:
            failures.append("%s failed to load" % path)
    add_result(
        "project_scripts_load",
        failures.is_empty(),
        "%d scripts and %d scenes checked%s" % [SCRIPT_PATHS.size(), SCENE_PATHS.size(), "" if failures.is_empty() else ": " + "; ".join(failures)]
    )

func test_region_id_floor_division() -> void:
    var generator := RegionStoryGeneratorScript.new()
    generator.setup("atlas-story-test", 101, 280)
    var positive_id := generator.region_id_for_cell(Vector2i(280, 559))
    var negative_id := generator.region_id_for_cell(Vector2i(-1, -281))
    add_result(
        "story_region_id_uses_floor_division",
        positive_id == "r:1,1" and negative_id == "r:-1,-2",
        "positive %s, negative %s" % [positive_id, negative_id]
    )
    generator.queue_free()

func test_region_records_deterministic() -> void:
    var generator := RegionStoryGeneratorScript.new()
    generator.setup("atlas-story-test", 101, 280)
    var same_a: Dictionary = generator.generate_region_record("atlas-story-test", 101, "r:0,0", "forest")
    var same_b: Dictionary = generator.generate_region_record("atlas-story-test", 101, "r:0,0", "forest")
    var different_region: Dictionary = generator.generate_region_record("atlas-story-test", 101, "r:1,0", "forest")
    var different_seed: Dictionary = generator.generate_region_record("atlas-other-test", 202, "r:0,0", "forest")
    var same_json := stable_json(same_a)
    add_result(
        "region_record_same_seed_same_region_identical",
        same_json == stable_json(same_b),
        String(same_a.get("id", ""))
    )
    add_result(
        "region_record_same_seed_different_region_differs",
        same_json != stable_json(different_region),
        "%s vs %s" % [same_a.get("id", ""), different_region.get("id", "")]
    )
    add_result(
        "region_record_different_seed_same_region_differs",
        same_json != stable_json(different_seed),
        "%s vs %s" % [same_a.get("seed", ""), different_seed.get("seed", "")]
    )
    generator.queue_free()

func test_phase3_region_record_validation_and_reset_restore_suppression() -> void:
    var bus := StoryEventBusScript.new()
    var generator := RegionStoryGeneratorScript.new()
    var quests := StoryQuestSystemScript.new()
    var director := StoryDirectorScript.new()
    add_child(bus)
    add_child(generator)
    add_child(quests)
    add_child(director)
    generator.setup("atlas-story-test", 101, 280)
    bus.setup(null)
    quests.setup(null)
    director.setup(null, bus, generator, quests)
    var record: Dictionary = generator.generate_region_record("atlas-story-test", 101, "r:3,-2", "taiga")
    var record_validation: Dictionary = RegionStoryRecordScript.validate(record)
    var worldmark_validation: Dictionary = WorldmarkStateScript.validate("r:3,-2", record.get("worldmark", {}))
    director.ensure_region_record_for_id("r:3,-2", "taiga")
    director.ingest_event(story_event("landmark_discovered", "mine:phase3", "r:3,-2", "discover:mine:phase3", {
        "landmarkType": "mine"
    }))
    var before_snapshot: Dictionary = director.snapshot()
    var before_json := stable_json(before_snapshot)
    director.restore(before_snapshot)
    var after_snapshot: Dictionary = director.snapshot()
    var after_json := stable_json(after_snapshot)
    var event_counts: Dictionary = after_snapshot.get("eventCounts", {})
    var dedupe_keys: Array = after_snapshot.get("processedDedupeKeys", [])
    director.reset()
    var reset_snapshot: Dictionary = director.snapshot()
    var reset_records: Dictionary = reset_snapshot.get("regionRecords", {})
    var reset_events: Dictionary = reset_snapshot.get("eventCounts", {})
    add_result(
        "phase3_region_record_validation_and_reset_restore_suppression",
        bool(record_validation.get("ok", false))
            and bool(worldmark_validation.get("ok", false))
            and before_json == after_json
            and int(event_counts.get("landmark_discovered", 0)) == 1
            and dedupe_keys.size() == 1
            and reset_records.is_empty()
            and reset_events.is_empty(),
        "record %s worldmark %s restoreSame %s events %s dedupe %d resetRecords %d" % [
            str(record_validation),
            str(worldmark_validation),
            str(before_json == after_json),
            str(event_counts),
            dedupe_keys.size(),
            reset_records.size()
        ]
    )
    director.queue_free()
    quests.queue_free()
    generator.queue_free()
    bus.queue_free()

func test_worldmark_trait_catalog_and_compatibility() -> void:
    var movement_ids := WorldmarkTraitCatalogScript.ids("movement")
    var attack_ids := WorldmarkTraitCatalogScript.ids("attack")
    var defense_ids := WorldmarkTraitCatalogScript.ids("defense")
    var resolution_ids := WorldmarkTraitCatalogScript.ids("resolution")
    var generator := WorldmarkGeneratorScript.new()
    generator.setup("atlas-story-test", 101)
    var validation: Dictionary = generator.validate_all_definitions()
    var definitions: Dictionary = WorldmarkDefinitionScript.definitions()
    var hart: Dictionary = definitions.get("gloam_hart", {})
    var fungal: Dictionary = definitions.get("mire_bloom_colossus", {})
    var ember: Dictionary = definitions.get("cinderwing_ember", {})
    add_result(
        "worldmark_trait_catalog_and_compatibility",
        movement_ids == ["burrow", "charge", "flight", "hover", "stalk"]
            and attack_ids == ["projectile", "pulse", "summon", "sweep", "terrain_burst"]
            and defense_ids == ["armor", "burrow_escape", "mist", "regeneration", "shield"]
            and resolution_ids == ["bargain", "bind", "heal", "release", "relocate", "slay"]
            and bool(validation.get("ok", false))
            and not hart.is_empty()
            and not fungal.is_empty()
            and not ember.is_empty(),
        "defs %s, validation %s" % [str(definitions.keys()), str(validation)]
    )

func test_concept_first_worldmark_generation_prototypes() -> void:
    var generator := RegionStoryGeneratorScript.new()
    generator.setup("atlas-story-test", 101, 280)
    var swamp_a: Dictionary = generator.generate_region_record("atlas-story-test", 101, "r:7,0", "swamp")
    var swamp_b: Dictionary = generator.generate_region_record("atlas-story-test", 101, "r:7,0", "swamp")
    var ember_record: Dictionary = generator.generate_region_record("atlas-story-test", 101, "r:8,0", "savanna")
    var swamp_worldmark: Dictionary = swamp_a.get("worldmark", {})
    var ember_worldmark: Dictionary = ember_record.get("worldmark", {})
    var swamp_resolutions: Array = swamp_worldmark.get("resolutionFamilies", [])
    var ember_resolutions: Array = ember_worldmark.get("resolutionFamilies", [])
    var swamp_movement: Array = swamp_worldmark.get("movementTraits", [])
    var ember_movement: Array = ember_worldmark.get("movementTraits", [])
    add_result(
        "concept_first_worldmark_generation_prototypes",
        stable_json(swamp_a) == stable_json(swamp_b)
            and String(swamp_worldmark.get("definitionId", "")) == "mire_bloom_colossus"
            and String(swamp_worldmark.get("domain", "")) == "spores_and_stillwater"
            and String(swamp_worldmark.get("condition", "")) == "starving"
            and swamp_movement.has("burrow")
            and not swamp_movement.has("flight")
            and swamp_resolutions.has("heal")
            and String(ember_worldmark.get("definitionId", "")) == "cinderwing_ember"
            and String(ember_worldmark.get("domain", "")) == "ember_and_high_wind"
            and String(ember_worldmark.get("condition", "")) == "enraged"
            and ember_movement.has("flight")
            and ember_movement.has("hover")
            and ember_resolutions.has("bargain")
            and stable_json(swamp_resolutions) != stable_json(ember_resolutions),
        "swamp %s/%s, ember %s/%s" % [
            swamp_worldmark.get("definitionId", ""),
            str(swamp_resolutions),
            ember_worldmark.get("definitionId", ""),
            str(ember_resolutions)
        ]
    )
    generator.queue_free()

func test_gloam_hart_definition_preserves_first_arc_contract() -> void:
    var generator := RegionStoryGeneratorScript.new()
    var quests := StoryQuestSystemScript.new()
    var director := StoryDirectorScript.new()
    add_child(generator)
    add_child(quests)
    add_child(director)
    generator.setup("atlas-story-test", 101, 280)
    quests.setup(null)
    director.setup(null, null, generator, quests)
    var record: Dictionary = director.mark_gloam_hart_region("r:2,0", "forest")
    var worldmark: Dictionary = record.get("worldmark", {})
    var validation: Dictionary = WorldmarkCompatibilityRulesScript.validate_definition(WorldmarkDefinitionScript.definition_for_id("gloam_hart"))
    var movement: Array = worldmark.get("movementTraits", [])
    var attacks: Array = worldmark.get("attackTraits", [])
    var resolutions: Array = worldmark.get("resolutionFamilies", [])
    add_result(
        "gloam_hart_definition_preserves_first_arc_contract",
        String(worldmark.get("definitionId", "")) == "gloam_hart"
            and String(worldmark.get("arcId", "")) == "storm_that_stays"
            and String(worldmark.get("titleId", "")) == "story.gloam_hart.title"
            and String(worldmark.get("displayNameId", "")) == "story.gloam_hart.name"
            and String(worldmark.get("domain", "")) == "storm_and_light"
            and String(worldmark.get("condition", "")) == "bound"
            and String(worldmark.get("desire", "")) == "silence_the_old_lanterns"
            and String(worldmark.get("publicBeliefId", "")) == "gloam_hart_public"
            and String(worldmark.get("hiddenTruthId", "")) == "gloam_hart_truth"
            and movement.has("charge")
            and attacks.has("sweep")
            and attacks.has("pulse")
            and attacks.has("summon")
            and resolutions == ["slay", "release"]
            and bool(validation.get("ok", false)),
        "worldmark %s, validation %s" % [str(worldmark), str(validation)]
    )
    director.queue_free()
    quests.queue_free()
    generator.queue_free()

func test_duplicate_events_do_not_duplicate_story_effects() -> void:
    var bus := StoryEventBusScript.new()
    var generator := RegionStoryGeneratorScript.new()
    var quests := StoryQuestSystemScript.new()
    var director := StoryDirectorScript.new()
    add_child(bus)
    add_child(generator)
    add_child(quests)
    add_child(director)
    generator.setup("atlas-story-test", 101, 280)
    bus.setup(null)
    quests.setup(null)
    director.setup(null, bus, generator, quests)
    bus.emit_event("landmark_discovered", "ruin:test", "r:0,0", "discover:ruin:test", Vector3.ZERO, {
        "landmarkType": "ruin"
    })
    bus.emit_event("landmark_discovered", "ruin:test", "r:0,0", "discover:ruin:test", Vector3.ZERO, {
        "landmarkType": "ruin"
    })
    var snapshot: Dictionary = director.snapshot()
    var event_counts: Dictionary = snapshot.get("eventCounts", {})
    var dedupe_keys: Array = snapshot.get("processedDedupeKeys", [])
    var records: Dictionary = snapshot.get("regionRecords", {})
    add_result(
        "duplicate_events_do_not_duplicate_story_effects",
        int(event_counts.get("landmark_discovered", 0)) == 1 and dedupe_keys.size() == 1 and records.has("r:0,0"),
        "events %s, dedupe %d, records %d" % [str(event_counts), dedupe_keys.size(), records.size()]
    )
    director.queue_free()
    quests.queue_free()
    generator.queue_free()
    bus.queue_free()

func test_main_scene_instantiates() -> void:
    var story_test_mode := OS.get_environment("VOXEL_STORY_PLAYTEST") == "1"
    main = MAIN_SCENE.instantiate()
    add_child(main)
    await wait_physics_frames(24)
    var player = main.get("player") as CharacterBody3D
    if player:
        player.set("automated_input", true)
    var required_systems := [
        "save_system",
        "inventory_system",
        "crafting_system",
        "objective_system",
        "contract_system",
        "tutorial_system",
        "npc_system",
        "hostile_system",
        "weather_system",
        "story_event_bus",
        "story_director",
        "story_quest_system",
        "region_story_generator",
        "story_site_placement",
            "story_world_overlay_system",
            "worldmark_influence_system",
            "story_journal_model",
            "story_dialogue_router",
            "story_accessibility_settings",
            "story_debug_tools",
            "worldmark_encounter_controller",
        "settlement_state_system",
        "region_aftermath_system",
        "hud",
        "visual_asset_registry",
        "static_item_asset_registry",
        "animated_asset_registry"
    ]
    var missing: Array[String] = []
    for key in required_systems:
        if main.get(key) == null:
            missing.append(key)
    add_result(
        "main_scene_story_test_mode_instantiates",
        story_test_mode and main != null and player != null and missing.is_empty(),
        "story mode %s, player %s, missing %s" % [str(story_test_mode), str(player != null), str(missing)]
    )

func test_phase14_story_polish_accessibility_debug_authoring() -> void:
    var test := Phase14StoryPolishTestsScript.new()
    var outcome: Dictionary = test.run(main)
    add_result(
        "phase14_story_polish_accessibility_debug_authoring",
        bool(outcome.get("ok", false)),
        String(outcome.get("details", ""))
    )

func test_phase12_campaign_spine_progression_and_endless_play() -> void:
    if main == null or main.get("story_director") == null:
        add_result("phase12_campaign_spine_progression_and_endless_play", false, "main story_director missing")
        return
    var baseline_snapshot: Dictionary = main.create_save_snapshot()
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := start_first_arc_for_test(director)
    var spine = director.get("campaign_spine")
    var initial_state: Dictionary = spine.snapshot() if spine != null else {}
    var anchors: Dictionary = initial_state.get("anchors", {})
    var anchors_json := stable_json(anchors)
    reset_story_runtime(director)
    start_first_arc_for_test(director)
    var repeat_anchors_json := stable_json(spine.snapshot().get("anchors", {}))
    reset_story_runtime(director)
    quest = start_first_arc_for_test(director)
    var affected := String(quest.get("affectedRegionId", ""))
    director.ingest_event(story_event("story_worldmark_resolved", "worldmark:gloam_hart", affected, "phase12:first-worldmark", {
        "resolution": "release",
        "definitionId": "gloam_hart",
        "rewardsGranted": true
    }))
    var act_two_state: Dictionary = spine.snapshot()
    director.ingest_event(story_event("recurring_character_met", "character:mara_trader", starter_region_id(), "phase12:mara-met", {
        "characterId": "mara_trader",
        "relationshipDelta": 3,
        "memoryFlag": "met_on_far_road"
    }))
    director.ingest_event(story_event("recurring_character_memory", "character:mara_trader", starter_region_id(), "phase12:mara-route", {
        "characterId": "mara_trader",
        "relationshipDelta": 3,
        "memoryFlag": "shared_route_news"
    }))
    var anchor_ids := [
        "far_roads_network_junction",
        "far_roads_living_boundary",
        "old_compact_archive",
        "compact_failure_site"
    ]
    for anchor_id in anchor_ids:
        var anchor: Dictionary = spine.snapshot().get("anchors", {}).get(anchor_id, {})
        var region_id := String(anchor.get("regionId", starter_region_id()))
        director.ingest_event(story_event("campaign_anchor_reached", "campaign_anchor:%s" % anchor_id, region_id, "phase12:anchor:%s" % anchor_id, {
            "anchorId": anchor_id
        }))
    var before_principles_state: Dictionary = spine.snapshot()
    director.ingest_event(story_event("campaign_principles_chosen", "campaign:frontier_principles", starter_region_id(), "phase12:principles", {
        "principles": ["repair before expansion", "restraint around Worldmarks", "settlements answer to their regions", "chosen by prophecy"]
    }))
    var complete_state: Dictionary = spine.snapshot()
    var characters: Dictionary = complete_state.get("recurringCharacters", {})
    var mara: Dictionary = characters.get("mara_trader", {})
    var mara_flags: Dictionary = mara.get("memoryFlags", {})
    var save_snapshot: Dictionary = main.create_save_snapshot()
    var before_spine_json := stable_json(save_snapshot.get("story", {}).get("campaignSpine", {}))
    var loaded := bool(main.apply_save_snapshot(save_snapshot))
    director = main.get("story_director")
    spine = director.get("campaign_spine")
    var after_spine_json := stable_json(spine.snapshot() if spine != null else {})
    var post_campaign_record: Dictionary = director.ensure_region_record_for_id("r:44,-44", "forest")
    var post_campaign_event_before := int(director.snapshot().get("eventCounts", {}).get("story_region_entered", 0))
    director.ingest_event(story_event("story_region_entered", "region:r:44,-44", "r:44,-44", "phase12:post-region", {
        "biome": "forest"
    }))
    var post_campaign_event_after := int(director.snapshot().get("eventCounts", {}).get("story_region_entered", 0))
    var final_text := stable_json(spine.snapshot()).to_lower()
    var anchor_regions := {}
    for anchor_key in anchors.keys():
        var anchor_record: Dictionary = anchors[anchor_key]
        anchor_regions[String(anchor_record.get("regionId", ""))] = true
    var baseline_loaded := bool(main.apply_save_snapshot(baseline_snapshot))
    director = main.get("story_director")
    reset_story_runtime(director)
    add_result(
        "phase12_campaign_spine_progression_and_endless_play",
        spine != null
            and not anchors.is_empty()
            and anchor_regions.size() == anchors.size()
            and anchors_json == repeat_anchors_json
            and String(initial_state.get("act", "")) == FrontierCampaignSpineScript.ACT_I
            and String(act_two_state.get("act", "")) == FrontierCampaignSpineScript.ACT_II
            and String(before_principles_state.get("act", "")) == FrontierCampaignSpineScript.ACT_III
            and bool(complete_state.get("completed", false))
            and String(complete_state.get("act", "")) == FrontierCampaignSpineScript.POST_CAMPAIGN
            and bool(complete_state.get("endlessWorldContinues", false))
            and bool(complete_state.get("regionalStoriesEnabled", false))
            and bool(mara_flags.get("met_on_far_road", false))
            and bool(mara_flags.get("shared_route_news", false))
            and String(mara.get("relationship", "")) == "trusted"
            and loaded
            and before_spine_json == after_spine_json
            and not post_campaign_record.is_empty()
            and post_campaign_event_after == post_campaign_event_before + 1
            and final_text.find("prophecy") < 0
            and final_text.find("bloodline") < 0
            and baseline_loaded,
        "anchors %d stable %s, acts %s/%s/%s/%s, complete %s, mara %s, save %s, postEvent %d->%d" % [
            anchors.size(),
            str(anchors_json == repeat_anchors_json),
            initial_state.get("act", ""),
            act_two_state.get("act", ""),
            before_principles_state.get("act", ""),
            complete_state.get("act", ""),
            str(complete_state.get("completed", false)),
            str(mara),
            str(before_spine_json == after_spine_json),
            post_campaign_event_before,
            post_campaign_event_after
        ]
    )

func test_phase13_narrative_text_provider_contracts() -> void:
    var tester := Phase13NarrativeTextProviderTestsScript.new()
    var result: Dictionary = tester.run(main, main.get("story_director") if main != null else null)
    add_result(
        "phase13_narrative_text_provider_contracts",
        bool(result.get("ok", false)),
        String(result.get("details", ""))
    )

func test_story_snapshot_save_load_preserves_records_exactly() -> void:
    if main == null or main.get("story_director") == null:
        add_result("story_snapshot_save_load_preserves_records_exactly", false, "main story_director missing")
        return
    var director = main.get("story_director")
    director.reset()
    director.ensure_region_record_for_id("r:1,0", "taiga")
    director.ingest_event({
        "schemaVersion": 1,
        "type": "landmark_discovered",
        "subjectId": "mine:story-roundtrip",
        "regionId": "r:1,0",
        "dedupeKey": "discover:mine:story-roundtrip",
        "worldTime": 12.0,
        "position": [1.0, 2.0, 3.0],
        "payload": {
            "landmarkType": "mine"
        }
    })
    var snapshot: Dictionary = main.create_save_snapshot()
    var story_snapshot: Dictionary = snapshot.get("story", {})
    var before_json := stable_json(story_snapshot)
    director.reset()
    director.restore(story_snapshot)
    var after_json := stable_json(director.snapshot())
    add_result(
        "story_snapshot_save_load_preserves_records_exactly",
        before_json == after_json,
        "before %d chars, after %d chars" % [before_json.length(), after_json.length()]
    )

func test_phase4_source_events_and_quest_state_round_trip() -> void:
    if main == null or main.get("story_director") == null:
        add_result("phase4_source_events_and_quest_state_round_trip", false, "main story_director missing")
        return
    var director = main.get("story_director")
    reset_story_runtime(director)
    var saved_exploration := {
        "biomes": main.get("discovered_biomes").duplicate(true),
        "towns": main.get("discovered_town_keys").duplicate(true),
        "mines": main.get("discovered_mine_keys").duplicate(true),
        "ruins": main.get("discovered_ruin_keys").duplicate(true),
        "camps": main.get("discovered_camp_keys").duplicate(true),
        "shrines": main.get("discovered_shrine_keys").duplicate(true)
    }
    main.get("discovered_biomes").erase("taiga")
    var tutorial = main.get("tutorial_system")
    var town: Dictionary = tutorial.get("town") if tutorial != null and tutorial.get("town") is Dictionary else {}
    var town_cell := Vector2i(int(town.get("centerX", 280)), int(town.get("centerZ", 0)))
    var town_key := "%d,%d" % [town_cell.x, town_cell.y]
    main.get("discovered_town_keys").erase(town_key)
    main.update_exploration_state(town_cell, "taiga")
    main.discover_landmark("mine", "phase4-mine", Vector3(float(town_cell.x + 400) * main.CELL, 20.0, float(town_cell.y) * main.CELL))
    main.discover_landmark("ruin", "phase4-ruin", Vector3(float(town_cell.x + 430) * main.CELL, 20.0, float(town_cell.y) * main.CELL))
    main.discover_landmark("camp", "phase4-camp", Vector3(float(town_cell.x + 460) * main.CELL, 20.0, float(town_cell.y) * main.CELL))
    var shrine := StaticBody3D.new()
    shrine.name = "Phase4Shrine"
    shrine.set_meta("generatedTier", "shrine")
    shrine.set_meta("cacheKey", "phase4-shrine")
    shrine.position = Vector3(float(town_cell.x + 490) * main.CELL, 20.0, float(town_cell.y) * main.CELL)
    add_child(shrine)
    var old_sanctuary := bool(main.get("sanctuary_established"))
    main.set("sanctuary_established", true)
    var shrine_ok: bool = bool(main.discover_shrine_cache(shrine))
    main.set("sanctuary_established", old_sanctuary)
    shrine.queue_free()
    director.ingest_event(story_event("tutorial_final_rescue_complete", "tutorial:final_rescue", starter_region_id(), "phase4:tutorial", {
        "rescuedNpcId": "niko"
    }))
    director.ingest_event(story_event("npc_spoken_to", "npc:mira", starter_region_id(), "phase4:npc:mira", {
        "npcId": "mira"
    }))
    var quest := first_quest_state(director)
    var quest_validation: Dictionary = StoryQuestStateScript.validate(quest)
    var quest_json := stable_json(quest)
    var quest_system = director.get("quest_system")
    if quest_system != null and quest_system.has_method("restore"):
        var quest_snapshot := {}
        quest_snapshot[FIRST_QUEST_ID] = quest
        quest_system.restore(quest_snapshot)
    var restored_quest := first_quest_state(director)
    var counts_before_hud_refresh: Dictionary = director.snapshot().get("eventCounts", {})
    main.update_hud("phase4 hud refresh should not emit story")
    var counts: Dictionary = director.snapshot().get("eventCounts", {})
    main.set("discovered_biomes", saved_exploration["biomes"])
    main.set("discovered_town_keys", saved_exploration["towns"])
    main.set("discovered_mine_keys", saved_exploration["mines"])
    main.set("discovered_ruin_keys", saved_exploration["ruins"])
    main.set("discovered_camp_keys", saved_exploration["camps"])
    main.set("discovered_shrine_keys", saved_exploration["shrines"])
    var hostile_system = main.get("hostile_system")
    if hostile_system != null and hostile_system.has_method("clear"):
        hostile_system.clear()
    add_result(
        "phase4_source_events_and_quest_state_round_trip",
        stable_json(counts_before_hud_refresh) == stable_json(counts)
            and int(counts.get("biome_discovered", 0)) == 1
            and int(counts.get("town_discovered", 0)) == 1
            and int(counts.get("mine_discovered", 0)) == 1
            and int(counts.get("ruin_discovered", 0)) == 1
            and int(counts.get("camp_discovered", 0)) == 1
            and int(counts.get("shrine_discovered", 0)) == 1
            and int(counts.get("tutorial_final_rescue_complete", 0)) == 1
            and int(counts.get("npc_spoken_to", 0)) == 1
            and shrine_ok
            and bool(quest_validation.get("ok", false))
            and quest_json == stable_json(restored_quest),
        "beforeHud %s afterHud %s, shrine %s, quest %s, restoreSame %s" % [
            str(counts_before_hud_refresh),
            str(counts),
            str(shrine_ok),
            str(quest_validation),
            str(quest_json == stable_json(restored_quest))
        ]
    )

func test_first_arc_waits_for_tutorial_completion() -> void:
    var director = main.get("story_director")
    director.reset()
    director.ingest_event(story_event("npc_spoken_to", "npc:mira", starter_region_id(), "", {
        "npcId": "mira"
    }))
    var quests: Dictionary = director.snapshot().get("quests", {})
    add_result(
        "first_arc_waits_for_tutorial_completion",
        not quests.has(FIRST_QUEST_ID),
        "quests %d" % quests.size()
    )

func test_tutorial_completion_starts_first_quest_once() -> void:
    var director = main.get("story_director")
    director.reset()
    director.ingest_event(story_event("tutorial_final_rescue_complete", "tutorial:final_rescue", starter_region_id(), "", {
        "rescuedNpcId": "niko"
    }))
    director.ingest_event(story_event("tutorial_final_rescue_complete", "tutorial:final_rescue", starter_region_id(), "", {
        "rescuedNpcId": "niko"
    }))
    var quest := first_quest_state(director)
    var affected := String(quest.get("affectedRegionId", ""))
    var starter := String(quest.get("starterRegionId", ""))
    var snapshot: Dictionary = director.snapshot()
    var records: Dictionary = snapshot.get("regionRecords", {})
    var record: Dictionary = records.get(affected, {})
    var worldmark: Dictionary = record.get("worldmark", {})
    var campaign: Dictionary = snapshot.get("campaign", {})
    var coords_distance := affected_region_distance(starter, affected)
    director.reset()
    director.ingest_event(story_event("tutorial_final_rescue_complete", "tutorial:final_rescue", starter_region_id(), "", {
        "rescuedNpcId": "niko"
    }))
    var repeat_quest := first_quest_state(director)
    var repeat_affected := String(repeat_quest.get("affectedRegionId", ""))
    add_result(
        "tutorial_completion_starts_first_quest_once",
        quest_count(director) == 1
            and String(quest.get("stage", "")) == "speak_with_mira"
            and affected != ""
            and affected != starter
            and repeat_affected == affected
            and coords_distance > 0
            and coords_distance <= 8
            and String(worldmark.get("definitionId", "")) == "gloam_hart"
            and String(campaign.get("firstAffectedRegionId", "")) == affected,
        "stage %s, starter %s, affected %s, repeat %s, distance %d, worldmark %s" % [
            quest.get("stage", ""),
            starter,
            affected,
            repeat_affected,
            coords_distance,
            worldmark.get("definitionId", "")
        ]
    )

func test_phase5_gloam_hart_handoff_opening_contract() -> void:
    if main == null or main.get("story_director") == null:
        add_result("phase5_gloam_hart_handoff_opening_contract", false, "main story_director missing")
        return
    var baseline_snapshot: Dictionary = main.create_save_snapshot()
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := start_first_arc_for_test(director)
    var validation: Dictionary = GloamHartArcScript.validate_opening_quest(quest)
    var affected := String(quest.get("affectedRegionId", ""))
    var starter := String(quest.get("starterRegionId", ""))
    var biome := String(quest.get("affectedRegionBiome", ""))
    var campaign: Dictionary = director.snapshot().get("campaign", {})
    var start_load_ok := save_load_preserves_story_stage("speak_with_mira")
    director = main.get("story_director")
    director.ingest_event(story_event("npc_spoken_to", "npc:mira", starter_region_id(), "", {
        "npcId": "mira"
    }))
    var after_mira := first_quest_state(director)
    var mira_load_ok := save_load_preserves_story_stage("speak_with_sera")
    director = main.get("story_director")
    director.ingest_event(story_event("npc_spoken_to", "npc:sera", starter_region_id(), "", {
        "npcId": "sera"
    }))
    var after_sera := first_quest_state(director)
    var sera_load_ok := save_load_preserves_story_stage("travel_to_affected_region")
    director = main.get("story_director")
    director.ingest_event(story_event("story_region_entered", "region:r:99,99", "r:99,99", "", {
        "biome": "forest"
    }))
    var after_wrong_region := first_quest_state(director)
    var wrong_region_ok := String(after_wrong_region.get("stage", "")) == "travel_to_affected_region"
    var travel_load_ok := save_load_preserves_story_stage("travel_to_affected_region")
    director = main.get("story_director")
    director.ingest_event(story_event("story_region_entered", "region:%s" % affected, affected, "", {
        "biome": biome
    }))
    var after_enter := first_quest_state(director)
    var enter_facts: Dictionary = after_enter.get("facts", {})
    var enter_load_ok := save_load_preserves_story_stage(String(after_enter.get("stage", "")))
    director = main.get("story_director")
    reset_story_runtime(director)
    var repeat_quest := start_first_arc_for_test(director)
    var repeat_affected := String(repeat_quest.get("affectedRegionId", ""))
    var old_save_handoff: Dictionary = phase5_old_completed_tutorial_save_handoff_once()
    var baseline_loaded := bool(main.apply_save_snapshot(baseline_snapshot))
    director = main.get("story_director")
    reset_story_runtime(director)
    var opening_stages: Array = GloamHartArcScript.opening_stage_order()
    var ok := (
        bool(validation.get("ok", false))
        and opening_stages == ["speak_with_mira", "speak_with_sera", "travel_to_affected_region"]
        and String(campaign.get("firstAffectedRegionId", "")) == affected
        and affected != ""
        and affected != starter
        and affected_region_distance(starter, affected) > 0
        and affected_region_distance(starter, affected) <= 8
        and biome in ["forest", "taiga"]
        and start_load_ok
        and String(after_mira.get("stage", "")) == "speak_with_sera"
        and mira_load_ok
        and String(after_sera.get("stage", "")) == "travel_to_affected_region"
        and sera_load_ok
        and wrong_region_ok
        and travel_load_ok
        and String(after_enter.get("stage", "")) != "travel_to_affected_region"
        and bool(enter_facts.get("enteredAffectedRegion", false))
        and enter_load_ok
        and repeat_affected == affected
        and bool(old_save_handoff.get("ok", false))
        and baseline_loaded
    )
    add_result(
        "phase5_gloam_hart_handoff_opening_contract",
        ok,
        "validation %s, starter %s, affected %s, biome %s, stages %s/%s/%s, wrongOk %s, enter %s, repeat %s, oldSave %s" % [
            str(validation),
            starter,
            affected,
            biome,
            quest.get("stage", ""),
            after_mira.get("stage", ""),
            after_sera.get("stage", ""),
            str(wrong_region_ok),
            after_enter.get("stage", ""),
            repeat_affected,
            str(old_save_handoff)
        ]
    )

func test_mira_event_advances_only_mira_stage() -> void:
    var director = main.get("story_director")
    director.reset()
    start_first_arc_for_test(director)
    director.ingest_event(story_event("npc_spoken_to", "npc:mira", starter_region_id(), "", {
        "npcId": "mira"
    }))
    director.ingest_event(story_event("npc_spoken_to", "npc:mira", starter_region_id(), "", {
        "npcId": "mira"
    }))
    var quest := first_quest_state(director)
    var facts: Dictionary = quest.get("facts", {})
    add_result(
        "mira_event_advances_only_mira_stage",
        String(quest.get("stage", "")) == "speak_with_sera"
            and bool(facts.get("miraSpoken", false))
            and not bool(facts.get("seraSpoken", false)),
        "stage %s, facts %s" % [quest.get("stage", ""), str(facts)]
    )

func test_sera_event_requires_mira_stage() -> void:
    var director = main.get("story_director")
    director.reset()
    start_first_arc_for_test(director)
    director.ingest_event(story_event("npc_spoken_to", "npc:sera", starter_region_id(), "", {
        "npcId": "sera"
    }))
    var before_mira := first_quest_state(director)
    director.ingest_event(story_event("npc_spoken_to", "npc:mira", starter_region_id(), "", {
        "npcId": "mira"
    }))
    director.ingest_event(story_event("npc_spoken_to", "npc:sera", starter_region_id(), "", {
        "npcId": "sera"
    }))
    var after_sera := first_quest_state(director)
    add_result(
        "sera_event_advances_only_after_mira",
        String(before_mira.get("stage", "")) == "speak_with_mira"
            and String(after_sera.get("stage", "")) == "travel_to_affected_region",
        "before %s, after %s" % [before_mira.get("stage", ""), after_sera.get("stage", "")]
    )

func test_affected_region_entry_advances_travel_stage() -> void:
    var director = main.get("story_director")
    director.reset()
    var quest := advance_to_travel_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    director.ingest_event(story_event("story_region_entered", "region:r:99,99", "r:99,99", "", {
        "biome": "forest"
    }))
    var wrong_region := first_quest_state(director)
    var center: Vector2i = main.get("region_story_generator").region_center_cell(affected)
    main.set("last_story_region_id", "")
    main.update_story_region_entry(center, Vector3(float(center.x) * 1.35, 0.0, float(center.y) * 1.35), String(quest.get("affectedRegionBiome", "")))
    var entered := first_quest_state(director)
    add_result(
        "affected_region_entry_advances_travel_stage",
        String(wrong_region.get("stage", "")) == "travel_to_affected_region"
            and String(entered.get("stage", "")) == "find_ordinary_clues",
        "wrong %s, entered %s, affected %s" % [wrong_region.get("stage", ""), entered.get("stage", ""), affected]
    )

func test_story_sites_are_valid_deterministic_and_saved() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := start_first_arc_for_test(director)
    var affected := String(quest.get("affectedRegionId", ""))
    var sites := ensure_story_sites_for_region(affected)
    var first_sites_json := stable_json(sites)
    var first_snapshot: Dictionary = director.snapshot()
    var first_records: Dictionary = first_snapshot.get("regionRecords", {})
    var first_record: Dictionary = first_records.get(affected, {})
    var saved_sites: Array = first_record.get("storySites", [])
    var validation := story_site_validation(sites)
    reset_story_runtime(director)
    var repeat_quest := start_first_arc_for_test(director)
    var repeat_affected := String(repeat_quest.get("affectedRegionId", ""))
    var repeat_sites := ensure_story_sites_for_region(repeat_affected)
    add_result(
        "story_sites_are_valid_deterministic_and_saved",
        affected != ""
            and affected == repeat_affected
            and first_sites_json == stable_json(repeat_sites)
            and first_sites_json == stable_json(saved_sites)
            and bool(validation.get("ok", false)),
        "affected %s, repeat %s, sites %d, saved %d, %s" % [
            affected,
            repeat_affected,
            sites.size(),
            saved_sites.size(),
            String(validation.get("details", ""))
        ]
    )

func test_story_region_overlay_and_influence_clear_on_exit() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    enter_story_region(affected, String(quest.get("affectedRegionBiome", "")))
    var active_dump: Dictionary = main.debug_story_dump()
    var active_overlay: Dictionary = active_dump.get("overlay", {})
    var active_influence: Dictionary = active_dump.get("influence", {})
    enter_story_region(starter_region_id(), "forest")
    var exit_dump: Dictionary = main.debug_story_dump()
    var exit_overlay: Dictionary = exit_dump.get("overlay", {})
    var exit_influence: Dictionary = exit_dump.get("influence", {})
    add_result(
        "story_region_overlay_and_influence_clear_on_exit",
        int(active_overlay.get("spawnedCount", 0)) == 7
            and bool(active_influence.get("active", false))
            and int(exit_overlay.get("spawnedCount", 0)) == 0
            and not bool(exit_influence.get("active", false)),
        "active overlay %d influence %s, exit overlay %d influence %s" % [
            int(active_overlay.get("spawnedCount", 0)),
            str(active_influence.get("active", false)),
            int(exit_overlay.get("spawnedCount", 0)),
            str(exit_influence.get("active", false))
        ]
    )

func test_story_interactable_boundary_and_encounter_events() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    enter_story_region(affected, String(quest.get("affectedRegionBiome", "")))
    var north_node := story_site_node("boundary_stone_north")
    var south_node := story_site_node("boundary_stone_south")
    var marker_node := story_site_node("encounter_marker")
    var north_ok: bool = bool(main.interact_story_node(north_node))
    var south_ok: bool = bool(main.interact_story_node(south_node))
    var marker_ok: bool = bool(main.interact_story_node(marker_node))
    var snapshot: Dictionary = director.snapshot()
    var event_counts: Dictionary = snapshot.get("eventCounts", {})
    var after_quest := first_quest_state(director)
    add_result(
        "story_interactable_boundary_and_encounter_events",
        north_ok
            and south_ok
            and marker_ok
            and int(event_counts.get("story_boundary_stone_discovered", 0)) == 2
            and int(event_counts.get("story_encounter_marker_found", 0)) == 1
            and String(after_quest.get("stage", "")) == "find_ordinary_clues",
        "boundary %s/%s=%d encounter %s=%d stage %s" % [
            str(north_ok),
            str(south_ok),
            int(event_counts.get("story_boundary_stone_discovered", 0)),
            str(marker_ok),
            int(event_counts.get("story_encounter_marker_found", 0)),
            after_quest.get("stage", "")
        ]
    )

func test_boundary_retune_costs_and_failed_attempts() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var isolated_state := begin_isolated_countermeasure_test_state()
    var quest := advance_to_optional_history_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    enter_story_region(affected, String(quest.get("affectedRegionBiome", "")))
    var north_node := story_site_node("boundary_stone_north")
    var no_item_ok: bool = bool(main.interact_story_node(north_node))
    var after_no_items := first_quest_state(director)
    var after_no_items_facts: Dictionary = after_no_items.get("facts", {})
    grant_story_countermeasure_items(0)
    var no_shard_ok: bool = bool(main.interact_story_node(north_node))
    var after_no_shard := first_quest_state(director)
    var after_no_shard_facts: Dictionary = after_no_shard.get("facts", {})
    var inventory = main.get("inventory_system")
    inventory.add_item("nightShard", 1)
    var retune_ok: bool = bool(main.interact_story_node(north_node))
    var after_retune := first_quest_state(director)
    var retune_facts: Dictionary = after_retune.get("facts", {})
    var event_counts: Dictionary = director.snapshot().get("eventCounts", {})
    var shards_after_retune: int = inventory.count("nightShard")
    var retune_source := String(retune_facts.get("countermeasureSource", ""))
    var ok: bool = (
        no_item_ok
        and no_shard_ok
        and retune_ok
        and not bool(after_no_items_facts.get("countermeasurePrepared", false))
        and int(after_no_items_facts.get("boundaryStonesRetuned", 0)) == 0
        and not bool(after_no_shard_facts.get("countermeasurePrepared", false))
        and int(after_no_shard_facts.get("boundaryStonesRetuned", 0)) == 0
        and bool(retune_facts.get("countermeasurePrepared", false))
        and retune_source == "boundary_stone"
        and int(retune_facts.get("boundaryStonesRetuned", 0)) == 1
        and shards_after_retune == 0
        and int(event_counts.get("story_boundary_stone_retuned", 0)) == 1
    )
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "boundary_retune_costs_and_failed_attempts",
        ok,
        "noItem %s noShard %s retune %s prepared %s/%s/%s count %d shards %d events %d source %s" % [
            str(no_item_ok),
            str(no_shard_ok),
            str(retune_ok),
            str(after_no_items_facts.get("countermeasurePrepared", false)),
            str(after_no_shard_facts.get("countermeasurePrepared", false)),
            str(retune_facts.get("countermeasurePrepared", false)),
            int(retune_facts.get("boundaryStonesRetuned", 0)),
            shards_after_retune,
            int(event_counts.get("story_boundary_stone_retuned", 0)),
            retune_source
        ]
    )

func test_boundary_retune_duplicate_persistence_and_storm_weakening() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var isolated_state := begin_isolated_countermeasure_test_state()
    var quest := advance_to_optional_history_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    var biome := String(quest.get("affectedRegionBiome", ""))
    enter_story_region(affected, biome)
    grant_story_countermeasure_items(3)
    var north_node := story_site_node("boundary_stone_north")
    var south_node := story_site_node("boundary_stone_south")
    var north_first_ok: bool = bool(main.interact_story_node(north_node))
    var north_duplicate_ok: bool = bool(main.interact_story_node(north_node))
    var south_ok: bool = bool(main.interact_story_node(south_node))
    var inventory = main.get("inventory_system")
    var after_retune := first_quest_state(director)
    var retune_facts: Dictionary = after_retune.get("facts", {})
    var event_counts: Dictionary = director.snapshot().get("eventCounts", {})
    var save_snapshot: Dictionary = main.create_save_snapshot()
    var loaded := bool(main.apply_save_snapshot(save_snapshot))
    director = main.get("story_director")
    enter_story_region(affected, biome)
    var restored := first_quest_state(director)
    var restored_facts: Dictionary = restored.get("facts", {})
    var influence: Dictionary = main.debug_story_dump().get("influence", {})
    var weather: Dictionary = influence.get("weatherBias", {})
    var inventory_after_load = main.get("inventory_system")
    var ids: Array = restored_facts.get("boundaryStoneIds", [])
    var ok: bool = (
        north_first_ok
        and north_duplicate_ok
        and south_ok
        and loaded
        and int(retune_facts.get("boundaryStonesRetuned", 0)) == 2
        and int(restored_facts.get("boundaryStonesRetuned", 0)) == 2
        and ids.has("boundary_stone_north")
        and ids.has("boundary_stone_south")
        and String(restored.get("stage", "")) == "encounter_locked_placeholder"
        and bool(restored_facts.get("stormWeakened", false))
        and bool(restored_facts.get("encounterUnlocked", false))
        and bool(restored_facts.get("combatRouteUnlocked", false))
        and not bool(restored_facts.get("encounterLocked", true))
        and inventory_after_load.count("nightShard") == 1
        and int(event_counts.get("story_boundary_stone_retuned", 0)) == 2
        and bool(weather.get("stormWeakened", false))
        and float(weather.get("intensity", 1.0)) < 0.22
    )
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "boundary_retune_duplicate_persistence_and_storm_weakening",
        ok,
        "interacts %s/%s/%s loaded %s stage %s stones %d ids %s shards %d events %d weather %s" % [
            str(north_first_ok),
            str(north_duplicate_ok),
            str(south_ok),
            str(loaded),
            restored.get("stage", ""),
            int(restored_facts.get("boundaryStonesRetuned", 0)),
            str(ids),
            inventory_after_load.count("nightShard"),
            int(event_counts.get("story_boundary_stone_retuned", 0)),
            str(weather)
        ]
    )

func test_history_clue_gates_release_route_after_boundary_retune() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var isolated_state := begin_isolated_countermeasure_test_state()
    var combat_quest := advance_to_optional_history_stage(director)
    var combat_affected := String(combat_quest.get("affectedRegionId", ""))
    enter_story_region(combat_affected, String(combat_quest.get("affectedRegionBiome", "")))
    grant_story_countermeasure_items(2)
    var combat_north_node := story_site_node("boundary_stone_north")
    var combat_south_node := story_site_node("boundary_stone_south")
    var combat_north_ok: bool = bool(main.interact_story_node(combat_north_node))
    var combat_south_ok: bool = bool(main.interact_story_node(combat_south_node))
    var combat_after := first_quest_state(director)
    var combat_facts: Dictionary = combat_after.get("facts", {})
    reset_story_runtime(director)
    clear_story_countermeasure_test_inventory()
    var release_quest := advance_to_optional_history_stage(director)
    var release_affected := String(release_quest.get("affectedRegionId", ""))
    director.ingest_event(story_event("story_clue_found", "clue:old_compact_record", release_affected, "", {
        "clueKind": "historical",
        "clueId": "historical:old_compact_record"
    }))
    enter_story_region(release_affected, String(release_quest.get("affectedRegionBiome", "")))
    grant_story_countermeasure_items(2)
    var release_north_node := story_site_node("boundary_stone_north")
    var release_south_node := story_site_node("boundary_stone_south")
    var release_north_ok: bool = bool(main.interact_story_node(release_north_node))
    var release_south_ok: bool = bool(main.interact_story_node(release_south_node))
    var release_after := first_quest_state(director)
    var release_facts: Dictionary = release_after.get("facts", {})
    var ok: bool = (
        combat_north_ok
        and combat_south_ok
        and release_north_ok
        and release_south_ok
        and bool(combat_facts.get("combatRouteUnlocked", false))
        and not bool(combat_facts.get("historyClueFound", false))
        and not bool(combat_facts.get("releaseRouteUnlocked", false))
        and not bool(combat_facts.get("releaseRouteAvailable", false))
        and bool(release_facts.get("combatRouteUnlocked", false))
        and bool(release_facts.get("historyClueFound", false))
        and bool(release_facts.get("releaseRouteUnlocked", false))
        and bool(release_facts.get("releaseRouteAvailable", false))
    )
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "history_clue_gates_release_route_after_boundary_retune",
        ok,
        "combat ok %s/%s count %d hist/release %s/%s available %s combatRoute %s, release ok %s/%s count %d hist/release %s/%s available %s combatRoute %s" % [
            str(combat_north_ok),
            str(combat_south_ok),
            int(combat_facts.get("boundaryStonesRetuned", 0)),
            str(combat_facts.get("historyClueFound", false)),
            str(combat_facts.get("releaseRouteUnlocked", false)),
            str(combat_facts.get("releaseRouteAvailable", false)),
            str(combat_facts.get("combatRouteUnlocked", false)),
            str(release_north_ok),
            str(release_south_ok),
            int(release_facts.get("boundaryStonesRetuned", 0)),
            str(release_facts.get("historyClueFound", false)),
            str(release_facts.get("releaseRouteUnlocked", false)),
            str(release_facts.get("releaseRouteAvailable", false)),
            str(release_facts.get("combatRouteUnlocked", false))
        ]
    )

func test_gloam_hart_encounter_phase_progression_countermeasure_and_animation_fallback() -> void:
    var director = main.get("story_director")
    var isolated_state := begin_isolated_countermeasure_test_state()
    var setup := prepare_gloam_hart_encounter(director, false)
    var controller = main.get("worldmark_encounter_controller")
    var encounter = controller.get("active_encounter") if controller != null else null
    var start_ok := bool(setup.get("startOk", false))
    var fallback_ok := false
    var phase_two_ok := false
    var phase_three_ok := false
    var pulse_damage := -1.0
    var states: Array = []
    if encounter != null:
        encounter.force_animation_state("missing_state_for_test")
        fallback_ok = bool(encounter.get("animation_fallback_used"))
        pulse_damage = float(encounter.storm_pulse_damage())
        encounter.apply_player_damage(70.0, "test")
        phase_two_ok = int(encounter.get("phase")) == 2
        encounter.apply_player_damage(70.0, "test")
        phase_three_ok = int(encounter.get("phase")) == 3
        states = encounter.debug_state().get("animationStatesUsed", [])
    var debug: Dictionary = main.debug_story_dump()
    var encounter_dump: Dictionary = debug.get("encounter", {})
    var ok: bool = (
        start_ok
        and bool(encounter_dump.get("active", false))
        and fallback_ok
        and phase_two_ok
        and phase_three_ok
        and is_equal_approx(pulse_damage, 5.0)
        and states.has("idle_breathe")
        and states.has("storm_pulse")
        and states.has("stagger_vulnerable")
    )
    if controller != null and controller.has_method("reset"):
        controller.reset()
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "gloam_hart_encounter_phase_progression_countermeasure_and_animation_fallback",
        ok,
        "start %s active %s fallback %s phases %s/%s pulse %.1f states %s" % [
            str(start_ok),
            str(encounter_dump.get("active", false)),
            str(fallback_ok),
            str(phase_two_ok),
            str(phase_three_ok),
            pulse_damage,
            str(states)
        ]
    )

func test_gloam_hart_slay_resolution_idempotent_rewards_and_cleanup() -> void:
    var director = main.get("story_director")
    var isolated_state := begin_isolated_countermeasure_test_state()
    var setup := prepare_gloam_hart_encounter(director, false)
    var affected := String(setup.get("affected", ""))
    var controller = main.get("worldmark_encounter_controller")
    var encounter = controller.get("active_encounter") if controller != null else null
    var inventory = main.get("inventory_system")
    var night_before: int = inventory.count("nightShard") if inventory != null else -1
    var core_before: int = inventory.count("riftCore") if inventory != null else -1
    var relic_before: int = inventory.count("relicFragment") if inventory != null else -1
    var minions_before := 0
    var slay_ok := false
    if encounter != null:
        encounter.apply_player_damage(70.0, "test")
        minions_before = story_minion_count()
        slay_ok = bool(controller.damage_active_encounter(999.0, "test"))
    var night_after: int = inventory.count("nightShard") if inventory != null else -1
    var core_after: int = inventory.count("riftCore") if inventory != null else -1
    var relic_after: int = inventory.count("relicFragment") if inventory != null else -1
    var duplicate_result := false
    if controller != null and controller.has_method("resolve_region"):
        duplicate_result = bool(controller.resolve_region(affected, "slay"))
    var night_final: int = inventory.count("nightShard") if inventory != null else -1
    var core_final: int = inventory.count("riftCore") if inventory != null else -1
    var relic_final: int = inventory.count("relicFragment") if inventory != null else -1
    var quest := first_quest_state(director)
    var facts: Dictionary = quest.get("facts", {})
    var record: Dictionary = director.snapshot().get("regionRecords", {}).get(affected, {})
    var worldmark: Dictionary = record.get("worldmark", {})
    var state: Dictionary = worldmark.get("encounterState", {})
    var ok: bool = (
        bool(setup.get("startOk", false))
        and slay_ok
        and minions_before >= 2
        and story_minion_count() == 0
        and night_after == night_before + 6
        and core_after == core_before + 1
        and relic_after == relic_before + 2
        and not duplicate_result
        and night_final == night_after
        and core_final == core_after
        and relic_final == relic_after
        and String(worldmark.get("resolution", "")) == "slay"
        and String(quest.get("status", "")) == "completed"
        and bool(facts.get("worldmarkResolved", false))
        and String(facts.get("resolution", "")) == "slay"
        and bool(state.get("rewardsGranted", false))
    )
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "gloam_hart_slay_resolution_idempotent_rewards_and_cleanup",
        ok,
        "start %s slay %s minions %d->%d rewards night %d/%d/%d core %d/%d/%d relic %d/%d/%d duplicate %s resolution %s quest %s" % [
            str(setup.get("startOk", false)),
            str(slay_ok),
            minions_before,
            story_minion_count(),
            night_before,
            night_after,
            night_final,
            core_before,
            core_after,
            core_final,
            relic_before,
            relic_after,
            relic_final,
            str(duplicate_result),
            worldmark.get("resolution", ""),
            quest.get("status", "")
        ]
    )

func test_gloam_hart_release_gating_and_resolution() -> void:
    var director = main.get("story_director")
    var isolated_state := begin_isolated_countermeasure_test_state()
    var combat_setup := prepare_gloam_hart_encounter(director, false)
    var combat_controller = main.get("worldmark_encounter_controller")
    var combat_encounter = combat_controller.get("active_encounter") if combat_controller != null else null
    var unavailable_release := false
    if combat_encounter != null:
        combat_encounter.apply_player_damage(140.0, "test")
        unavailable_release = not bool(main.try_release_story_worldmark())
    reset_story_runtime(director)
    clear_story_countermeasure_test_inventory()
    var release_setup := prepare_gloam_hart_encounter(director, true)
    var affected := String(release_setup.get("affected", ""))
    var release_controller = main.get("worldmark_encounter_controller")
    var release_encounter = release_controller.get("active_encounter") if release_controller != null else null
    var inventory = main.get("inventory_system")
    var tonic_before: int = inventory.count("wardTonic") if inventory != null else -1
    var relic_before: int = inventory.count("relicFragment") if inventory != null else -1
    var release_ok := false
    if release_encounter != null:
        release_encounter.apply_player_damage(140.0, "test")
        release_ok = bool(main.try_release_story_worldmark())
    var tonic_after: int = inventory.count("wardTonic") if inventory != null else -1
    var relic_after: int = inventory.count("relicFragment") if inventory != null else -1
    var duplicate_result := false
    if release_controller != null and release_controller.has_method("resolve_region"):
        duplicate_result = bool(release_controller.resolve_region(affected, "release"))
    var tonic_final: int = inventory.count("wardTonic") if inventory != null else -1
    var relic_final: int = inventory.count("relicFragment") if inventory != null else -1
    var quest := first_quest_state(director)
    var facts: Dictionary = quest.get("facts", {})
    var record: Dictionary = director.snapshot().get("regionRecords", {}).get(affected, {})
    var worldmark: Dictionary = record.get("worldmark", {})
    var ok: bool = (
        bool(combat_setup.get("startOk", false))
        and unavailable_release
        and bool(release_setup.get("startOk", false))
        and release_ok
        and tonic_after == tonic_before + 2
        and relic_after == relic_before + 3
        and tonic_final == tonic_after
        and relic_final == relic_after
        and not duplicate_result
        and String(worldmark.get("resolution", "")) == "release"
        and bool(facts.get("worldmarkResolved", false))
        and String(facts.get("resolution", "")) == "release"
    )
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "gloam_hart_release_gating_and_resolution",
        ok,
        "combat start %s unavailable %s release start %s release %s tonic %d/%d/%d relic %d/%d/%d duplicate %s resolution %s" % [
            str(combat_setup.get("startOk", false)),
            str(unavailable_release),
            str(release_setup.get("startOk", false)),
            str(release_ok),
            tonic_before,
            tonic_after,
            tonic_final,
            relic_before,
            relic_after,
            relic_final,
            str(duplicate_result),
            worldmark.get("resolution", "")
        ]
    )

func test_gloam_hart_release_normal_input_affordance() -> void:
    var director = main.get("story_director")
    var isolated_state := begin_isolated_countermeasure_test_state()

    var early_setup := prepare_gloam_hart_encounter(director, true)
    var early_affected := String(early_setup.get("affected", ""))
    var early_controller = main.get("worldmark_encounter_controller")
    var early_inventory = main.get("inventory_system")
    var early_tonic_before: int = early_inventory.count("wardTonic") if early_inventory != null else -1
    var early_relic_before: int = early_inventory.count("relicFragment") if early_inventory != null else -1
    var prompt_hidden_before_phase := String(main.story_release_input_prompt()) == ""
    press_story_release_input()
    var early_tonic_after: int = early_inventory.count("wardTonic") if early_inventory != null else -1
    var early_relic_after: int = early_inventory.count("relicFragment") if early_inventory != null else -1
    var early_resolution := ""
    if early_controller != null and early_controller.has_method("worldmark_resolution"):
        early_resolution = String(early_controller.worldmark_resolution(early_affected))
    var early_message := String(main.get("last_hud_refresh_message"))
    var blocked_before_phase := early_resolution == "" and early_tonic_after == early_tonic_before and early_relic_after == early_relic_before

    reset_story_runtime(director)
    clear_story_countermeasure_test_inventory()
    var no_history_setup := prepare_gloam_hart_encounter(director, false)
    var no_history_affected := String(no_history_setup.get("affected", ""))
    var no_history_controller = main.get("worldmark_encounter_controller")
    var no_history_encounter = no_history_controller.get("active_encounter") if no_history_controller != null else null
    if no_history_encounter != null:
        no_history_encounter.apply_player_damage(140.0, "test")
    var prompt_hidden_without_history := String(main.story_release_input_prompt()) == ""
    press_story_release_input()
    var no_history_resolution := ""
    if no_history_controller != null and no_history_controller.has_method("worldmark_resolution"):
        no_history_resolution = String(no_history_controller.worldmark_resolution(no_history_affected))
    var no_history_message := String(main.get("last_hud_refresh_message"))
    var unavailable_without_history := no_history_resolution == "" and no_history_message == "You do not know the old rite."

    reset_story_runtime(director)
    clear_story_countermeasure_test_inventory()
    var release_setup := prepare_gloam_hart_encounter(director, true)
    var release_affected := String(release_setup.get("affected", ""))
    var release_controller = main.get("worldmark_encounter_controller")
    var release_encounter = release_controller.get("active_encounter") if release_controller != null else null
    var inventory = main.get("inventory_system")
    if release_encounter != null:
        release_encounter.apply_player_damage(140.0, "test")
    var prompt_ready := String(main.story_release_input_prompt()) == "[R] Release rite ready"
    var tonic_before: int = inventory.count("wardTonic") if inventory != null else -1
    var relic_before: int = inventory.count("relicFragment") if inventory != null else -1
    press_story_release_input()
    var tonic_after: int = inventory.count("wardTonic") if inventory != null else -1
    var relic_after: int = inventory.count("relicFragment") if inventory != null else -1
    var release_resolution := ""
    if release_controller != null and release_controller.has_method("worldmark_resolution"):
        release_resolution = String(release_controller.worldmark_resolution(release_affected))
    var release_event_counts: Dictionary = director.snapshot().get("eventCounts", {}).duplicate(true)
    var save_snapshot: Dictionary = main.create_save_snapshot()
    press_story_release_input()
    var tonic_duplicate: int = inventory.count("wardTonic") if inventory != null else -1
    var relic_duplicate: int = inventory.count("relicFragment") if inventory != null else -1
    var duplicate_event_counts: Dictionary = director.snapshot().get("eventCounts", {}).duplicate(true)
    var loaded := bool(main.apply_save_snapshot(save_snapshot))
    director = main.get("story_director")
    inventory = main.get("inventory_system")
    var loaded_record: Dictionary = director.snapshot().get("regionRecords", {}).get(release_affected, {})
    var loaded_worldmark: Dictionary = loaded_record.get("worldmark", {})
    var loaded_state: Dictionary = loaded_worldmark.get("encounterState", {})
    var release_save_load_stable: bool = (
        loaded
        and String(loaded_worldmark.get("resolution", "")) == "release"
        and bool(loaded_state.get("rewardsGranted", false))
        and inventory != null
        and inventory.count("wardTonic") == tonic_after
        and inventory.count("relicFragment") == relic_after
    )

    reset_story_runtime(director)
    clear_story_countermeasure_test_inventory()
    var slay_setup := prepare_gloam_hart_encounter(director, true)
    var slay_affected := String(slay_setup.get("affected", ""))
    var slay_controller = main.get("worldmark_encounter_controller")
    var slay_ok := false
    if slay_controller != null:
        slay_ok = bool(slay_controller.damage_active_encounter(999.0, "test"))
    var slay_resolution := ""
    if slay_controller != null and slay_controller.has_method("worldmark_resolution"):
        slay_resolution = String(slay_controller.worldmark_resolution(slay_affected))

    var release_via_input := (
        release_resolution == "release"
        and tonic_after == tonic_before + 2
        and relic_after == relic_before + 3
    )
    var duplicate_input_idempotent := (
        tonic_duplicate == tonic_after
        and relic_duplicate == relic_after
        and int(duplicate_event_counts.get("story_worldmark_resolved", 0)) == int(release_event_counts.get("story_worldmark_resolved", 0))
    )
    var slay_still_works := slay_ok and slay_resolution == "slay"
    var ok: bool = (
        bool(early_setup.get("startOk", false))
        and prompt_hidden_before_phase
        and blocked_before_phase
        and bool(no_history_setup.get("startOk", false))
        and prompt_hidden_without_history
        and unavailable_without_history
        and bool(release_setup.get("startOk", false))
        and prompt_ready
        and release_via_input
        and duplicate_input_idempotent
        and release_save_load_stable
        and bool(slay_setup.get("startOk", false))
        and slay_still_works
    )
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "gloam_hart_release_normal_input_affordance",
        ok,
        "early start %s promptHidden %s blocked %s msg '%s', noHistory start %s promptHidden %s unavailable %s msg '%s', release start %s promptReady %s input %s rewards tonic %d/%d/%d relic %d/%d/%d duplicate %s saveLoad %s, slay start %s slay %s" % [
            str(early_setup.get("startOk", false)),
            str(prompt_hidden_before_phase),
            str(blocked_before_phase),
            early_message,
            str(no_history_setup.get("startOk", false)),
            str(prompt_hidden_without_history),
            str(unavailable_without_history),
            no_history_message,
            str(release_setup.get("startOk", false)),
            str(prompt_ready),
            str(release_via_input),
            tonic_before,
            tonic_after,
            tonic_duplicate,
            relic_before,
            relic_after,
            relic_duplicate,
            str(duplicate_input_idempotent),
            str(release_save_load_stable),
            str(slay_setup.get("startOk", false)),
            str(slay_still_works)
        ]
    )

func test_gloam_hart_save_load_recovery_policy() -> void:
    var director = main.get("story_director")
    var isolated_state := begin_isolated_countermeasure_test_state()
    var setup := prepare_gloam_hart_encounter(director, false)
    var controller = main.get("worldmark_encounter_controller")
    var encounter = controller.get("active_encounter") if controller != null else null
    if encounter != null:
        encounter.apply_player_damage(70.0, "test")
        encounter.force_animation_state("storm_pulse")
    var snapshot: Dictionary = main.create_save_snapshot()
    var loaded := bool(main.apply_save_snapshot(snapshot))
    director = main.get("story_director")
    controller = main.get("worldmark_encounter_controller")
    var recovered_dump: Dictionary = controller.debug_state() if controller != null and controller.has_method("debug_state") else {}
    var recovered_encounter: Dictionary = recovered_dump.get("encounter", {})
    var active := bool(recovered_dump.get("active", false))
    var recovered := bool(recovered_dump.get("recoveredFromSave", false))
    var phase := int(recovered_encounter.get("phase", 0))
    var health := float(recovered_encounter.get("health", 0.0))
    var record: Dictionary = director.snapshot().get("regionRecords", {}).get(String(setup.get("affected", "")), {})
    var worldmark: Dictionary = record.get("worldmark", {})
    var state: Dictionary = worldmark.get("encounterState", {})
    var state_json := stable_json(state)
    var transient_absent := state_json.find("stateElapsed") < 0 and state_json.find("animationState") < 0 and state_json.find("projectile") < 0
    var ok: bool = (
        bool(setup.get("startOk", false))
        and loaded
        and active
        and recovered
        and phase == 2
        and is_equal_approx(health, 120.0)
        and String(state.get("status", "")) == "active"
        and int(state.get("phase", 0)) == 2
        and String(worldmark.get("resolution", "")) == ""
        and transient_absent
    )
    if controller != null and controller.has_method("reset"):
        controller.reset()
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "gloam_hart_save_load_recovery_policy",
        ok,
        "start %s loaded %s active %s recovered %s phase %d health %.1f state %s transientAbsent %s" % [
            str(setup.get("startOk", false)),
            str(loaded),
            str(active),
            str(recovered),
            phase,
            health,
            str(state),
            str(transient_absent)
        ]
    )

func test_worldmark_aftermath_slay_delayed_settlement_and_dialogue() -> void:
    var director = main.get("story_director")
    var isolated_state := begin_isolated_countermeasure_test_state()
    var setup := finish_gloam_hart_resolution(director, "slay")
    var aftermath = main.get("region_aftermath_system")
    var settlement = main.get("settlement_state_system")
    var started: bool = bool(aftermath.sync_from_resolution()) if aftermath != null else false
    var initial: Dictionary = aftermath.debug_state() if aftermath != null else {}
    var initial_settlement: Dictionary = settlement.debug_state() if settlement != null else {}
    var advanced: Dictionary = aftermath.advance_days_for_test(1.0) if aftermath != null else {}
    var advanced_settlement: Dictionary = settlement.debug_state() if settlement != null else {}
    var router = main.get("story_dialogue_router")
    var dialogue: Dictionary = router.response_for_npc("sera", "Sera", "Guard", "") if router != null else {}
    var dialogue_text := String(dialogue.get("text", "")).to_lower()
    var npc_activity_count := story_aftermath_npc_activity_count("repair_public_space")
    var ok: bool = (
        bool(setup.get("resolved", false))
        and started
        and String(initial.get("resolution", "")) == "slay"
        and not bool(initial.get("settlementTierUnlocked", false))
        and int(initial_settlement.get("tier", -1)) == 0
        and bool(advanced.get("settlementTierUnlocked", false))
        and bool(advanced.get("tradeLinkUnlocked", false))
        and bool(advanced.get("serviceUnlocked", false))
        and bool(advanced.get("cozySceneUnlocked", false))
        and bool(advanced.get("slayCombatRecipe", false))
        and String(advanced.get("wildlifeRecovery", "")) == "slow"
        and String(advanced.get("guardMood", "")) == "confident"
        and int(advanced_settlement.get("tier", 0)) == 1
        and String(advanced_settlement.get("status", "")) == "secure"
        and npc_activity_count >= 1
        and bool(dialogue.get("handled", false))
        and dialogue_text.find("guards") >= 0
    )
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "worldmark_aftermath_slay_delayed_settlement_and_dialogue",
        ok,
        "resolved %s started %s initial tier %s advanced %s settlement %s npcActivity %d dialogue '%s'" % [
            str(setup.get("resolved", false)),
            str(started),
            str(initial_settlement.get("tier", "")),
            str(advanced),
            str(advanced_settlement),
            npc_activity_count,
            dialogue.get("text", "")
        ]
    )

func test_worldmark_aftermath_release_wildlife_trade_and_save_load() -> void:
    var director = main.get("story_director")
    var isolated_state := begin_isolated_countermeasure_test_state()
    var setup := finish_gloam_hart_resolution(director, "release")
    var aftermath = main.get("region_aftermath_system")
    var settlement = main.get("settlement_state_system")
    if aftermath != null:
        aftermath.sync_from_resolution()
        aftermath.advance_days_for_test(2.0)
    var before: Dictionary = aftermath.debug_state() if aftermath != null else {}
    var before_settlement: Dictionary = settlement.debug_state() if settlement != null else {}
    var npc_activity_before := story_aftermath_npc_activity_count("reopen_forage_paths")
    var save_snapshot: Dictionary = main.create_save_snapshot()
    var loaded := bool(main.apply_save_snapshot(save_snapshot))
    director = main.get("story_director")
    aftermath = main.get("region_aftermath_system")
    settlement = main.get("settlement_state_system")
    var after: Dictionary = aftermath.debug_state() if aftermath != null else {}
    var after_settlement: Dictionary = settlement.debug_state() if settlement != null else {}
    var router = main.get("story_dialogue_router")
    var dialogue: Dictionary = router.response_for_npc("niko", "Niko", "Forager", "") if router != null else {}
    var dialogue_text := String(dialogue.get("text", "")).to_lower()
    var npc_activity_count := story_aftermath_npc_activity_count("reopen_forage_paths")
    var activity_reconstructed: bool = npc_activity_count >= 1 or String(after_settlement.get("residentActivity", "")) == "reopen_forage_paths"
    var story_snapshot: Dictionary = director.snapshot() if director != null else {}
    var beacon_preserved: bool = main.get("sanctuary_established") == false and float(main.get("beacon_charge")) >= 0.0
    var settlements_saved: bool = story_snapshot.get("settlements", {}) is Dictionary
    var ok: bool = (
        bool(setup.get("resolved", false))
        and loaded
        and String(before.get("resolution", "")) == "release"
        and bool(before.get("complete", false))
        and bool(before.get("releaseNatureRoute", false))
        and bool(before.get("distantHartMayAppear", false))
        and String(before.get("wildlifeRecovery", "")) == "quick"
        and bool(before.get("tradeLinkUnlocked", false))
        and bool(before.get("serviceUnlocked", false))
        and bool(before_settlement.get("tradeLinkUnlocked", false))
        and String(after.get("resolution", "")) == "release"
        and bool(after.get("complete", false))
        and String(after_settlement.get("status", "")) == "secure"
        and npc_activity_before >= 1
        and activity_reconstructed
        and bool(dialogue.get("handled", false))
        and dialogue_text.find("forage") >= 0
        and settlements_saved
        and beacon_preserved
    )
    restore_isolated_countermeasure_test_state(isolated_state)
    add_result(
        "worldmark_aftermath_release_wildlife_trade_and_save_load",
        ok,
        "resolved %s loaded %s before %s settlement %s after %s afterSettlement %s npcActivity %d/%d dialogue '%s' beacon %s" % [
            str(setup.get("resolved", false)),
            str(loaded),
            str(before),
            str(before_settlement),
            str(after),
            str(after_settlement),
            npc_activity_before,
            npc_activity_count,
            dialogue.get("text", ""),
            str(beacon_preserved)
        ]
    )

func test_ordinary_clues_count_idempotently() -> void:
    var director = main.get("story_director")
    director.reset()
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    director.ingest_event(story_event("story_clue_found", "clue:scarred_tree", affected, "", {
        "clueKind": "ordinary",
        "clueId": "ordinary:scarred_tree"
    }))
    director.ingest_event(story_event("story_clue_found", "clue:scarred_tree", affected, "", {
        "clueKind": "ordinary",
        "clueId": "ordinary:scarred_tree"
    }))
    director.ingest_event(story_event("story_clue_found", "clue:ringing_stone", affected, "", {
        "clueKind": "ordinary",
        "clueId": "ordinary:ringing_stone"
    }))
    var after_clues := first_quest_state(director)
    var facts: Dictionary = after_clues.get("facts", {})
    add_result(
        "ordinary_clues_count_idempotently",
        int(facts.get("ordinaryCluesFound", 0)) == 2
            and String(after_clues.get("stage", "")) == "prepare_countermeasure_placeholder",
        "count %d, ids %s, stage %s" % [int(facts.get("ordinaryCluesFound", 0)), str(facts.get("ordinaryClueIds", [])), after_clues.get("stage", "")]
    )

func test_story_interactable_clues_dedupe_and_progress() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    enter_story_region(affected, String(quest.get("affectedRegionBiome", "")))
    var antler_node := story_site_node("ordinary_antler_scars")
    var stone_node := story_site_node("ordinary_ringing_stone")
    var first_ok: bool = bool(main.interact_story_node(antler_node))
    var duplicate_ok: bool = bool(main.interact_story_node(antler_node))
    var after_first := first_quest_state(director)
    var first_facts: Dictionary = after_first.get("facts", {})
    var second_ok: bool = bool(main.interact_story_node(stone_node))
    var after_second := first_quest_state(director)
    var second_facts: Dictionary = after_second.get("facts", {})
    add_result(
        "story_interactable_clues_dedupe_and_progress",
        first_ok
            and duplicate_ok
            and second_ok
            and int(first_facts.get("ordinaryCluesFound", 0)) == 1
            and int(second_facts.get("ordinaryCluesFound", 0)) == 2
            and String(after_second.get("stage", "")) == "prepare_countermeasure_placeholder",
        "first %s duplicate %s second %s, counts %d/%d, stage %s" % [
            str(first_ok),
            str(duplicate_ok),
            str(second_ok),
            int(first_facts.get("ordinaryCluesFound", 0)),
            int(second_facts.get("ordinaryCluesFound", 0)),
            after_second.get("stage", "")
        ]
    )

func test_historical_clue_unlock_persists_and_quest_round_trips() -> void:
    var director = main.get("story_director")
    director.reset()
    var quest := advance_to_optional_history_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    director.ingest_event(story_event("story_clue_found", "clue:old_compact_record", affected, "", {
        "clueKind": "historical",
        "clueId": "historical:old_compact_record"
    }))
    var before: Dictionary = director.snapshot()
    var before_json := stable_json(before)
    director.reset()
    director.restore(before)
    var after: Dictionary = director.snapshot()
    var after_json := stable_json(after)
    var restored := first_quest_state(director)
    var facts: Dictionary = restored.get("facts", {})
    var debug_dump: Dictionary = main.debug_story_dump()
    var debug_quest: Dictionary = debug_dump.get("quest", {})
    add_result(
        "historical_clue_unlock_persists_and_quest_round_trips",
        before_json == after_json
            and bool(facts.get("historyClueFound", false))
            and bool(facts.get("releaseRouteUnlocked", false))
            and String(restored.get("stage", "")) == "prepare_countermeasure_placeholder"
            and String(debug_quest.get("stage", "")) == "prepare_countermeasure_placeholder"
            and String(debug_quest.get("affectedRegionId", "")) == affected
            and int(debug_quest.get("ordinaryCluesFound", 0)) == 2
            and bool(debug_quest.get("historyClueFound", false))
            and bool(debug_quest.get("releaseRouteUnlocked", false)),
        "stage %s, history %s, release %s, debug %s/%s/%d/%s/%s" % [
            restored.get("stage", ""),
            str(facts.get("historyClueFound", false)),
            str(facts.get("releaseRouteUnlocked", false)),
            debug_quest.get("stage", ""),
            debug_quest.get("affectedRegionId", ""),
            int(debug_quest.get("ordinaryCluesFound", 0)),
            str(debug_quest.get("historyClueFound", false)),
            str(debug_quest.get("releaseRouteUnlocked", false))
        ]
    )

func test_optional_history_interactable_state_persists_and_sites_round_trips() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    enter_story_region(affected, String(quest.get("affectedRegionBiome", "")))
    var antler_node := story_site_node("ordinary_antler_scars")
    var stone_node := story_site_node("ordinary_ringing_stone")
    var history_node := story_site_node("historical_old_compact")
    var first_ok: bool = bool(main.interact_story_node(antler_node))
    var second_ok: bool = bool(main.interact_story_node(stone_node))
    var history_ok: bool = bool(main.interact_story_node(history_node))
    var save_snapshot: Dictionary = main.create_save_snapshot()
    var story_before: Dictionary = save_snapshot.get("story", {})
    var before_records: Dictionary = story_before.get("regionRecords", {})
    var before_record: Dictionary = before_records.get(affected, {})
    var before_sites_json := stable_json(before_record.get("storySites", []))
    var loaded := bool(main.apply_save_snapshot(save_snapshot))
    director = main.get("story_director")
    var restored := first_quest_state(director)
    var facts: Dictionary = restored.get("facts", {})
    var after_snapshot: Dictionary = director.snapshot()
    var after_records: Dictionary = after_snapshot.get("regionRecords", {})
    var after_record: Dictionary = after_records.get(affected, {})
    var after_sites: Array = after_record.get("storySites", [])
    add_result(
        "optional_history_interactable_state_persists_and_sites_round_trips",
        first_ok
            and second_ok
            and history_ok
            and loaded
            and bool(facts.get("historyClueFound", false))
            and bool(facts.get("releaseRouteUnlocked", false))
            and String(restored.get("stage", "")) == "prepare_countermeasure_placeholder"
            and before_sites_json == stable_json(after_record.get("storySites", [])),
        "interacts %s/%s/%s, loaded %s, stage %s, history %s, release %s, sites %d" % [
            str(first_ok),
            str(second_ok),
            str(history_ok),
            str(loaded),
            restored.get("stage", ""),
            str(facts.get("historyClueFound", false)),
            str(facts.get("releaseRouteUnlocked", false)),
            after_sites.size()
        ]
    )

func test_story_journal_hides_hidden_truth_until_history() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    var journal = main.get("story_journal_model")
    var before: Dictionary = journal.state()
    var before_hidden := dossier_value(before, "Hidden truth")
    director.ingest_event(story_event("story_clue_found", "clue:old_compact_record", affected, "", {
        "clueKind": "historical",
        "clueId": "historical:old_compact_record"
    }))
    var after: Dictionary = journal.state()
    var after_hidden := dossier_value(after, "Hidden truth")
    add_result(
        "story_journal_hides_hidden_truth_until_history",
        bool(before.get("active", false))
            and before_hidden == "???"
            and after_hidden.find("compact") >= 0
            and after_hidden.find("spare") >= 0,
        "before '%s', after '%s', affected %s" % [before_hidden, after_hidden, affected]
    )

func test_phase_b_navigation_and_journal_clarity() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var journal = main.get("story_journal_model")
    var problems: Array[String] = []

    var quest_start := start_first_arc_for_test(director)
    var start_state: Dictionary = journal.state()
    var start_optional := journal_row_value(start_state, "optionalObjectives", "Old compact record")
    if String(start_state.get("status", "")) != "Speak with Mira":
        problems.append("quest start status")
    if start_optional.find("may reveal another way to resolve the Hart") < 0:
        problems.append("quest start optional history line")
    if dossier_value(start_state, "Hidden truth") != "???":
        problems.append("quest start hidden truth")

    director.ingest_event(story_event("npc_spoken_to", "npc:mira", starter_region_id(), "", {
        "npcId": "mira"
    }))
    var mira_state: Dictionary = journal.state()
    if String(mira_state.get("status", "")) != "Speak with Sera":
        problems.append("Mira handoff status")

    director.ingest_event(story_event("npc_spoken_to", "npc:sera", starter_region_id(), "", {
        "npcId": "sera"
    }))
    var travel_quest := first_quest_state(director)
    var affected := String(travel_quest.get("affectedRegionId", quest_start.get("affectedRegionId", "")))
    var travel_state: Dictionary = journal.state()
    var waypoint := journal_row_value(travel_state, "navigation", "Storm waypoint")
    var travel_navigation_text := stable_json(travel_state.get("navigation", []))
    var direction_ok := waypoint.find("north") >= 0 or waypoint.find("south") >= 0 or waypoint.find("east") >= 0 or waypoint.find("west") >= 0
    if String(travel_state.get("status", "")) != "Travel to the storm waypoint":
        problems.append("Sera handoff travel status")
    if waypoint == "" or not direction_ok or travel_navigation_text.find("r:") >= 0:
        problems.append("affected region waypoint")

    var prep_names_ok := (
        journal_row_value(travel_state, "preparationRequirements", "Survey Lens") != ""
        and journal_row_value(travel_state, "preparationRequirements", "Ward Lantern") != ""
        and journal_row_value(travel_state, "preparationRequirements", "Night Shard charge") != ""
    )
    if not prep_names_ok:
        problems.append("countermeasure requirement rows")

    director.ingest_event(story_event("story_region_entered", "region:%s" % affected, affected, "", {
        "biome": travel_quest.get("affectedRegionBiome", "")
    }))
    var entered_state: Dictionary = journal.state()
    if journal_row_value(entered_state, "progress", "Ordinary clues").find("0 found, 2 remaining") < 0:
        problems.append("entered ordinary count")

    director.ingest_event(story_event("story_clue_found", "clue:scarred_tree", affected, "", {
        "clueKind": "ordinary",
        "clueId": "ordinary:scarred_tree"
    }))
    var one_clue_state: Dictionary = journal.state()
    if journal_row_value(one_clue_state, "progress", "Ordinary clues").find("1 found, 1 remaining") < 0:
        problems.append("one ordinary clue count")

    director.ingest_event(story_event("story_clue_found", "clue:ringing_stone", affected, "", {
        "clueKind": "ordinary",
        "clueId": "ordinary:ringing_stone"
    }))
    var two_clue_state: Dictionary = journal.state()
    if journal_row_value(two_clue_state, "progress", "Ordinary clues").find("2 found, 0 remaining") < 0:
        problems.append("two ordinary clue count")
    if dossier_value(two_clue_state, "Hidden truth") != "???":
        problems.append("historical clue not found hidden truth")
    if journal_row_value(two_clue_state, "optionalObjectives", "Old compact record").find("may reveal another way") < 0:
        problems.append("historical clue not found optional line")

    director.ingest_event(story_event("story_clue_found", "clue:old_compact_record", affected, "", {
        "clueKind": "historical",
        "clueId": "historical:old_compact_record"
    }))
    var history_state: Dictionary = journal.state()
    if dossier_value(history_state, "Hidden truth").find("spare the Hart") < 0:
        problems.append("historical clue found hidden truth")
    if journal_row_value(history_state, "optionalObjectives", "Old compact record").find("release rite understood") < 0:
        problems.append("historical clue found optional line")

    director.ingest_event(story_event("story_countermeasure_prepared", "countermeasure:gloam_hart", affected, "", {
        "source": "test",
        "items": ["surveyLens", "wardLantern"]
    }))
    director.ingest_event(story_event("story_boundary_stone_retuned", "boundary_stone_north", affected, "", {
        "stoneId": "boundary_stone_north"
    }))
    var one_stone_state: Dictionary = journal.state()
    if journal_row_value(one_stone_state, "progress", "Boundary stones").find("1 retuned, 1 remaining") < 0:
        problems.append("one boundary stone count")

    director.ingest_event(story_event("story_boundary_stone_retuned", "boundary_stone_south", affected, "", {
        "stoneId": "boundary_stone_south"
    }))
    var two_stone_state: Dictionary = journal.state()
    if journal_row_value(two_stone_state, "progress", "Boundary stones").find("2 retuned, 0 remaining") < 0:
        problems.append("two boundary stone count")

    add_result(
        "phase_b_navigation_and_journal_clarity",
        problems.is_empty(),
        "problems %s; waypoint '%s'; ordinary '%s'/'%s'; boundary '%s'/'%s'; hidden before '%s' after '%s'" % [
            str(problems),
            waypoint,
            journal_row_value(one_clue_state, "progress", "Ordinary clues"),
            journal_row_value(two_clue_state, "progress", "Ordinary clues"),
            journal_row_value(one_stone_state, "progress", "Boundary stones"),
            journal_row_value(two_stone_state, "progress", "Boundary stones"),
            dossier_value(two_clue_state, "Hidden truth"),
            dossier_value(history_state, "Hidden truth")
        ]
    )

func test_story_dialogue_router_filters_npc_knowledge() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    var router = main.get("story_dialogue_router")
    var before: Dictionary = router.response_for_npc("niko", "Niko", "Forager", "")
    var before_text := String(before.get("text", "")).to_lower()
    director.ingest_event(story_event("story_clue_found", "clue:old_compact_record", affected, "", {
        "clueKind": "historical",
        "clueId": "historical:old_compact_record"
    }))
    var after: Dictionary = router.response_for_npc("niko", "Niko", "Forager", "")
    var after_text := String(after.get("text", "")).to_lower()
    var scopes: Array = before.get("knowledgeScopes", [])
    add_result(
        "story_dialogue_router_filters_npc_knowledge",
        bool(before.get("handled", false))
            and scopes.has("public_town_rumor")
            and scopes.has("role_specific_knowledge")
            and not bool(before.get("hiddenTruthKnown", false))
            and before_text.find("compact") < 0
            and bool(after.get("hiddenTruthKnown", false))
            and after_text.find("compact") >= 0,
        "before scopes %s hidden %s text '%s', after hidden %s text '%s'" % [
            str(scopes),
            str(before.get("hiddenTruthKnown", false)),
            before.get("text", ""),
            str(after.get("hiddenTruthKnown", false)),
            after.get("text", "")
        ]
    )

func test_story_dialogue_router_generic_fallback() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    advance_to_clue_stage(director)
    var router = main.get("story_dialogue_router")
    var body := StaticBody3D.new()
    body.name = "GeneratedStoryResident"
    body.set_meta("kind", "npc")
    body.set_meta("npc_name", "Iven")
    body.set_meta("npc_role", "Guard")
    add_child(body)
    var response: Dictionary = router.interact_with_node(body)
    var snapshot: Dictionary = director.snapshot()
    var event_counts: Dictionary = snapshot.get("eventCounts", {})
    var scopes_value = response.get("knowledgeScopes", [])
    var scopes: Array = scopes_value if scopes_value is Array else []
    body.queue_free()
    add_result(
        "story_dialogue_router_generic_fallback",
        bool(response.get("handled", false))
            and String(response.get("text", "")).to_lower().find("compact") < 0
            and String(response.get("text", "")).to_lower().find("spare") < 0
            and String(response.get("text", "")).to_lower().find("cage") < 0
            and scopes.has("role_specific_knowledge")
            and int(event_counts.get("npc_spoken_to", 0)) >= 1,
        "handled %s scopes %s events %d text '%s'" % [
            str(response.get("handled", false)),
            str(response.get("knowledgeScopes", [])),
            int(event_counts.get("npc_spoken_to", 0)),
            response.get("text", "")
        ]
    )

func test_story_journal_save_load_round_trips() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    director.ingest_event(story_event("story_clue_found", "clue:scarred_tree", affected, "", {
        "clueKind": "ordinary",
        "clueId": "ordinary:scarred_tree"
    }))
    var journal = main.get("story_journal_model")
    var before_json := stable_json(journal.state())
    var save_snapshot: Dictionary = main.create_save_snapshot()
    var loaded := bool(main.apply_save_snapshot(save_snapshot))
    journal = main.get("story_journal_model")
    var after_json := stable_json(journal.state())
    add_result(
        "story_journal_save_load_round_trips",
        loaded and before_json == after_json,
        "loaded %s, before %d chars, after %d chars" % [str(loaded), before_json.length(), after_json.length()]
    )

func test_story_journal_ui_viewports() -> void:
    var director = main.get("story_director")
    reset_story_runtime(director)
    advance_to_clue_stage(director)
    var hud_node = main.get("hud")
    var old_size := get_window().size
    var ok := true
    var details: Array[String] = []
    for size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
        get_window().size = size
        await get_tree().process_frame
        hud_node.set_story_journal_open(true)
        await get_tree().process_frame
        var rect: Rect2 = hud_node.story_panel.get_global_rect()
        var fits := rect.position.x >= 0.0 and rect.position.y >= 0.0 and rect.end.x <= float(size.x) and rect.end.y <= float(size.y)
        ok = ok and hud_node.story_panel.visible and fits and rect.size.x >= 360.0 and rect.size.y >= 300.0
        details.append("%s rect %s fits %s" % [str(size), str(rect), str(fits)])
        hud_node.set_story_journal_open(false)
    get_window().size = old_size
    add_result(
        "story_journal_ui_viewports",
        ok,
        "; ".join(details)
    )

func test_old_save_without_story_field_loads() -> void:
    if main == null:
        add_result("old_save_without_story_field_loads", false, "main missing")
        return
    var snapshot: Dictionary = main.create_save_snapshot()
    snapshot.erase("story")
    var loaded := bool(main.apply_save_snapshot(snapshot))
    var director = main.get("story_director")
    var story_snapshot: Dictionary = director.snapshot() if director != null else {}
    var records: Dictionary = story_snapshot.get("regionRecords", {})
    var dedupe_keys: Array = story_snapshot.get("processedDedupeKeys", [])
    add_result(
        "old_save_without_story_field_loads",
        loaded and int(story_snapshot.get("schemaVersion", 0)) == 1 and records.is_empty() and dedupe_keys.is_empty(),
        "loaded %s, records %d, dedupe %d" % [str(loaded), records.size(), dedupe_keys.size()]
    )

func test_story_artifacts_directory_writable() -> void:
    var artifact_path := ProjectSettings.globalize_path("res://artifacts/story/latest/story-playtest-artifact.json")
    ensure_dir_for_file(artifact_path)
    var payload := {
        "schemaVersion": 1,
        "runner": "StoryPlaytestRunner",
        "resultsBeforeWrite": results.size()
    }
    var file := FileAccess.open(artifact_path, FileAccess.WRITE)
    var write_ok := file != null
    if file != null:
        file.store_string(JSON.stringify(payload, "  "))
        file.close()
    var read_back := ""
    if FileAccess.file_exists(artifact_path):
        var read_file := FileAccess.open(artifact_path, FileAccess.READ)
        if read_file != null:
            read_back = read_file.get_as_text()
            read_file.close()
    add_result(
        "story_artifacts_directory_writable",
        write_ok and read_back.find("StoryPlaytestRunner") >= 0,
        artifact_path
    )

func reset_story_runtime(director) -> void:
    if director != null:
        director.reset()
    if main != null:
        main.set("last_story_region_id", "")
        var encounter_controller = main.get("worldmark_encounter_controller")
        if encounter_controller != null and encounter_controller.has_method("reset"):
            encounter_controller.reset()
        var settlement = main.get("settlement_state_system")
        if settlement != null and settlement.has_method("reset"):
            settlement.reset()
        var aftermath = main.get("region_aftermath_system")
        if aftermath != null and aftermath.has_method("reset"):
            aftermath.reset()
        var overlay = main.get("story_world_overlay_system")
        if overlay != null and overlay.has_method("reset"):
            overlay.reset()
        var influence = main.get("worldmark_influence_system")
        if influence != null and influence.has_method("reset"):
            influence.reset()

func prepare_gloam_hart_encounter(director, include_history: bool) -> Dictionary:
    reset_story_runtime(director)
    var quest := advance_to_optional_history_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    var biome := String(quest.get("affectedRegionBiome", ""))
    if include_history:
        director.ingest_event(story_event("story_clue_found", "clue:old_compact_record", affected, "", {
            "clueKind": "historical",
            "clueId": "historical:old_compact_record"
        }))
    enter_story_region(affected, biome)
    grant_story_countermeasure_items(2)
    var north_node := story_site_node("boundary_stone_north")
    var south_node := story_site_node("boundary_stone_south")
    var marker_node := story_site_node("encounter_marker")
    var north_ok: bool = bool(main.interact_story_node(north_node))
    var south_ok: bool = bool(main.interact_story_node(south_node))
    var start_ok: bool = bool(main.interact_story_node(marker_node))
    return {
        "affected": affected,
        "biome": biome,
        "northOk": north_ok,
        "southOk": south_ok,
        "startOk": start_ok,
        "history": include_history
    }

func finish_gloam_hart_resolution(director, resolution: String) -> Dictionary:
    var setup := prepare_gloam_hart_encounter(director, resolution == "release")
    var controller = main.get("worldmark_encounter_controller")
    var encounter = controller.get("active_encounter") if controller != null else null
    var resolved := false
    if encounter != null:
        if resolution == "release":
            encounter.apply_player_damage(140.0, "test")
            resolved = bool(main.try_release_story_worldmark())
        else:
            resolved = bool(controller.damage_active_encounter(999.0, "test"))
    setup["resolved"] = resolved
    return setup

func story_minion_count() -> int:
    var hostile_system = main.get("hostile_system") if main != null else null
    if hostile_system == null:
        return 0
    var enemies_value = hostile_system.get("enemies")
    if not (enemies_value is Array):
        return 0
    var count := 0
    for enemy_value in enemies_value:
        if not (enemy_value is Dictionary):
            continue
        var enemy: Dictionary = enemy_value
        var body := enemy.get("body") as Node
        if body != null and is_instance_valid(body) and String(body.get_meta("story_minion", "")) == "gloam_hart":
            count += 1
    return count

func story_aftermath_npc_activity_count(activity: String) -> int:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return 0
    var npcs_value = npc_system.get("npcs")
    if not (npcs_value is Array):
        return 0
    var count := 0
    for entry_value in npcs_value:
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        var body := entry.get("body") as Node
        if body != null and is_instance_valid(body) and String(body.get_meta("story_aftermath_activity", "")) == activity:
            count += 1
    return count

func ensure_story_sites_for_region(region_id: String) -> Array:
    if main == null or region_id == "":
        return []
    var overlay = main.get("story_world_overlay_system")
    if overlay != null and overlay.has_method("ensure_sites_for_region"):
        return overlay.ensure_sites_for_region(region_id)
    return []

func begin_isolated_countermeasure_test_state() -> Dictionary:
    var state := {}
    var inventory = main.get("inventory_system") if main != null else null
    if inventory != null:
        state["inventory"] = {
            "slots": inventory.snapshot(),
            "size": inventory.size,
            "selectedSlot": inventory.selected_slot
        }
        inventory.restore({
            "slots": [],
            "size": inventory.size,
            "selectedSlot": 0
        })
    var contracts = main.get("contract_system") if main != null else null
    if contracts != null:
        var contract_list = contracts.get("contracts")
        state["contractsSnapshot"] = contracts.snapshot()
        state["contractsList"] = contract_list.duplicate(true) if contract_list is Array else []
        contracts.set("contracts", [])
    return state

func restore_isolated_countermeasure_test_state(state: Dictionary) -> void:
    var contracts = main.get("contract_system") if main != null else null
    if contracts != null:
        contracts.set("contracts", state.get("contractsList", []))
        contracts.restore(state.get("contractsSnapshot", {}))
    var inventory = main.get("inventory_system") if main != null else null
    if inventory != null and state.has("inventory"):
        inventory.restore(state["inventory"])

func clear_story_countermeasure_test_inventory() -> void:
    var inventory = main.get("inventory_system") if main != null else null
    if inventory == null:
        return
    inventory.restore({
        "slots": [],
        "size": inventory.size,
        "selectedSlot": 0
    })

func grant_story_countermeasure_items(night_shards: int) -> void:
    if main == null:
        return
    var inventory = main.get("inventory_system")
    if inventory == null:
        return
    inventory.add_item("surveyLens", 1)
    inventory.add_item("wardLantern", 1)
    if night_shards > 0:
        inventory.add_item("nightShard", night_shards)

func story_site_validation(sites: Array) -> Dictionary:
    var seen_ids := {}
    var cells: Array[Vector2i] = []
    var ordinary_count := 0
    var historical_count := 0
    var boundary_count := 0
    var encounter_count := 0
    var problems: Array[String] = []
    for site_value in sites:
        if not (site_value is Dictionary):
            problems.append("non-dictionary site")
            continue
        var site: Dictionary = site_value
        var site_id := String(site.get("id", ""))
        var kind := String(site.get("kind", ""))
        var clue_kind := String(site.get("clueKind", ""))
        var cell := story_site_cell(site)
        if site_id == "" or seen_ids.has(site_id):
            problems.append("duplicate id %s" % site_id)
        seen_ids[site_id] = true
        if not story_site_cell_valid(cell):
            problems.append("%s invalid cell %s" % [site_id, str(cell)])
        for existing_cell in cells:
            var distance := Vector2(float(existing_cell.x), float(existing_cell.y)).distance_to(Vector2(float(cell.x), float(cell.y)))
            if distance < 8.0:
                problems.append("%s too close to %s" % [site_id, str(existing_cell)])
        cells.append(cell)
        if kind == "clue" and clue_kind == "ordinary":
            ordinary_count += 1
        elif kind == "clue" and clue_kind == "historical":
            historical_count += 1
        elif kind == "boundary_stone":
            boundary_count += 1
        elif kind == "encounter_marker":
            encounter_count += 1
    var ok := sites.size() == 7 and ordinary_count == 3 and historical_count == 1 and boundary_count == 2 and encounter_count == 1 and problems.is_empty()
    return {
        "ok": ok,
        "details": "counts ordinary=%d historical=%d boundary=%d encounter=%d problems=%s" % [
            ordinary_count,
            historical_count,
            boundary_count,
            encounter_count,
            str(problems)
        ]
    }

func story_site_cell_valid(cell: Vector2i) -> bool:
    if main == null:
        return false
    if main.terrain_height_cell(cell.x, cell.y) <= main.WATER_LEVEL + 1.2:
        return false
    if String(main.biome_at_cell(cell.x, cell.y)) in ["ocean", "beach", "town"]:
        return false
    var town: Dictionary = main.town_region_at_cell(cell.x, cell.y)
    if not town.is_empty():
        return false
    if main.height_variation_cell(cell.x, cell.y, 2) > 2.4:
        return false
    return true

func story_site_cell(site: Dictionary) -> Vector2i:
    var cell_value = site.get("cell", [])
    if cell_value is Array and cell_value.size() >= 2:
        return Vector2i(int(cell_value[0]), int(cell_value[1]))
    return Vector2i.ZERO

func enter_story_region(region_id: String, biome: String) -> void:
    if main == null or region_id == "":
        return
    var generator = main.get("region_story_generator")
    if generator == null:
        return
    var center: Vector2i = generator.region_center_cell(region_id)
    var resolved_biome := biome
    if resolved_biome == "":
        resolved_biome = String(main.biome_at_cell(center.x, center.y))
    main.set("last_story_region_id", "")
    main.update_story_region_entry(center, Vector3(float(center.x) * main.CELL, main.terrain_height_cell(center.x, center.y), float(center.y) * main.CELL), resolved_biome)

func story_site_node(definition_id: String) -> Node:
    if main == null:
        return null
    var overlay = main.get("story_world_overlay_system")
    if overlay == null:
        return null
    var spawned_value = overlay.get("spawned_sites")
    if not (spawned_value is Dictionary):
        return null
    var spawned: Dictionary = spawned_value
    for site_id in spawned.keys():
        var node = spawned[site_id]
        if node == null or not (node is Node):
            continue
        var story_node := node as Node
        var site: Dictionary = story_node.get_meta("storySite", {})
        if String(site.get("definitionId", "")) == definition_id:
            return story_node
    return null

func press_story_release_input() -> void:
    if main == null:
        return
    var event := InputEventKey.new()
    event.keycode = KEY_R
    event.pressed = true
    event.echo = false
    main.call("_unhandled_input", event)

func dossier_value(journal_state: Dictionary, label: String) -> String:
    var rows: Array = journal_state.get("dossier", [])
    for row_value in rows:
        if not (row_value is Dictionary):
            continue
        var row: Dictionary = row_value
        if String(row.get("label", "")) == label:
            return String(row.get("value", ""))
    return ""

func journal_row_value(journal_state: Dictionary, section: String, label: String) -> String:
    var rows: Array = journal_state.get(section, [])
    for row_value in rows:
        if row_value is Dictionary:
            var row: Dictionary = row_value
            if String(row.get("label", "")) == label:
                return String(row.get("value", ""))
    return ""

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func add_result(name: String, passed: bool, details: String = "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    if not passed:
        failed = true
    print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])
    save_report()

func mark_progress(label: String) -> void:
    var path := OS.get_environment("VOXEL_STORY_PLAYTEST_PROGRESS")
    if path == "":
        return
    ensure_dir_for_file(path)
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%s\n" % [label, elapsed, results.size(), str(failed)])
    file.close()

func finish() -> void:
    if finished:
        return
    finished = true
    mark_progress("finished")
    save_report()
    get_tree().quit(1 if failed else 0)

func save_report() -> void:
    var report_path := OS.get_environment("VOXEL_STORY_PLAYTEST_REPORT")
    if report_path == "":
        report_path = "user://story-playtest-report.json"
    ensure_dir_for_file(report_path)
    var report := {
        "passed": not failed,
        "results": results
    }
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write story playtest report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func ensure_dir_for_file(path: String) -> void:
    var directory := path.get_base_dir()
    if directory == "":
        return
    if path.begins_with("user://") or path.begins_with("res://"):
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
    else:
        DirAccess.make_dir_recursive_absolute(directory)

func stable_json(value) -> String:
    if value is Dictionary:
        var dict: Dictionary = value
        var keys := dict.keys()
        keys.sort()
        var parts: Array[String] = []
        for key in keys:
            parts.append("%s:%s" % [JSON.stringify(String(key)), stable_json(dict[key])])
        return "{%s}" % ",".join(parts)
    if value is Array:
        var parts: Array[String] = []
        for item in value:
            parts.append(stable_json(item))
        return "[%s]" % ",".join(parts)
    return JSON.stringify(value)

func story_event(event_type: String, subject_id: String, region_id: String, dedupe_key: String, payload := {}) -> Dictionary:
    return {
        "schemaVersion": 1,
        "type": event_type,
        "subjectId": subject_id,
        "regionId": region_id,
        "dedupeKey": dedupe_key,
        "worldTime": 0.0,
        "position": [],
        "payload": payload.duplicate(true) if payload is Dictionary else {}
    }

func starter_region_id() -> String:
    if main != null and main.has_method("story_region_id_for_cell"):
        return String(main.story_region_id_for_cell(Vector2i(280, 0)))
    return "r:1,0"

func start_first_arc_for_test(director) -> Dictionary:
    director.ingest_event(story_event("tutorial_final_rescue_complete", "tutorial:final_rescue", starter_region_id(), "", {
        "rescuedNpcId": "niko"
    }))
    return first_quest_state(director)

func advance_to_travel_stage(director) -> Dictionary:
    start_first_arc_for_test(director)
    director.ingest_event(story_event("npc_spoken_to", "npc:mira", starter_region_id(), "", {
        "npcId": "mira"
    }))
    director.ingest_event(story_event("npc_spoken_to", "npc:sera", starter_region_id(), "", {
        "npcId": "sera"
    }))
    return first_quest_state(director)

func advance_to_clue_stage(director) -> Dictionary:
    var quest := advance_to_travel_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    director.ingest_event(story_event("story_region_entered", "region:%s" % affected, affected, "", {
        "biome": quest.get("affectedRegionBiome", "")
    }))
    return first_quest_state(director)

func advance_to_optional_history_stage(director) -> Dictionary:
    var quest := advance_to_clue_stage(director)
    var affected := String(quest.get("affectedRegionId", ""))
    director.ingest_event(story_event("story_clue_found", "clue:scarred_tree", affected, "", {
        "clueKind": "ordinary",
        "clueId": "ordinary:scarred_tree"
    }))
    director.ingest_event(story_event("story_clue_found", "clue:ringing_stone", affected, "", {
        "clueKind": "ordinary",
        "clueId": "ordinary:ringing_stone"
    }))
    return first_quest_state(director)

func save_load_preserves_story_stage(expected_stage: String) -> bool:
    if main == null or main.get("story_director") == null:
        return false
    var snapshot: Dictionary = main.create_save_snapshot()
    var before_story_json := stable_json(snapshot.get("story", {}))
    var loaded := bool(main.apply_save_snapshot(snapshot))
    var director = main.get("story_director")
    if director == null:
        return false
    var quest := first_quest_state(director)
    return loaded and String(quest.get("stage", "")) == expected_stage and stable_json(director.snapshot()) == before_story_json

func phase5_old_completed_tutorial_save_handoff_once() -> Dictionary:
    if main == null:
        return { "ok": false, "reason": "main missing" }
    var old_save: Dictionary = main.create_save_snapshot()
    old_save.erase("story")
    var tutorial: Dictionary = old_save.get("tutorial", {}) if old_save.get("tutorial", {}) is Dictionary else {}
    tutorial["started"] = true
    var completed_steps: Array = tutorial.get("completedSteps", []) if tutorial.get("completedSteps", []) is Array else []
    for step_id in ["finalNightStarted", "finalNightComplete", "miraBlessing"]:
        if not completed_steps.has(step_id):
            completed_steps.append(step_id)
    tutorial["completedSteps"] = completed_steps
    var intro: Dictionary = tutorial.get("introRepair", {}) if tutorial.get("introRepair", {}) is Dictionary else {}
    intro["finalNightActive"] = false
    intro["finalNightComplete"] = true
    intro["finalNightDefeatsStart"] = 0
    tutorial["introRepair"] = intro
    old_save["tutorial"] = tutorial
    var loaded_old := bool(main.apply_save_snapshot(old_save))
    var director = main.get("story_director")
    var first := first_quest_state(director)
    var first_count := quest_count(director)
    var migrated_save: Dictionary = main.create_save_snapshot()
    var loaded_migrated := bool(main.apply_save_snapshot(migrated_save))
    director = main.get("story_director")
    var second := first_quest_state(director)
    var second_count := quest_count(director)
    var event_counts: Dictionary = director.snapshot().get("eventCounts", {}) if director != null else {}
    var ok := (
        loaded_old
        and loaded_migrated
        and first_count == 1
        and second_count == 1
        and String(first.get("id", "")) == FIRST_QUEST_ID
        and String(second.get("id", "")) == FIRST_QUEST_ID
        and String(first.get("affectedRegionId", "")) == String(second.get("affectedRegionId", ""))
        and int(event_counts.get("tutorial_final_rescue_complete", 0)) == 1
    )
    return {
        "ok": ok,
        "loadedOld": loaded_old,
        "loadedMigrated": loaded_migrated,
        "firstCount": first_count,
        "secondCount": second_count,
        "affected": String(first.get("affectedRegionId", "")),
        "events": event_counts
    }

func first_quest_state(director) -> Dictionary:
    var snapshot: Dictionary = director.snapshot()
    var quests: Dictionary = snapshot.get("quests", {})
    if not quests.has(FIRST_QUEST_ID) or not (quests[FIRST_QUEST_ID] is Dictionary):
        return {}
    return quests[FIRST_QUEST_ID].duplicate(true)

func quest_count(director) -> int:
    var snapshot: Dictionary = director.snapshot()
    var quests: Dictionary = snapshot.get("quests", {})
    return quests.size()

func affected_region_distance(starter_region_id: String, affected_region_id: String) -> int:
    var generator = main.get("region_story_generator")
    var starter: Vector2i = generator.region_coords(starter_region_id)
    var affected: Vector2i = generator.region_coords(affected_region_id)
    return maxi(absi(starter.x - affected.x), absi(starter.y - affected.y))
