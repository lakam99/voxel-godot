extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const RegionStoryGeneratorScript := preload("res://scripts/story/RegionStoryGenerator.gd")
const StoryEventBusScript := preload("res://scripts/story/StoryEventBus.gd")
const StoryDirectorScript := preload("res://scripts/story/StoryDirector.gd")
const StoryQuestSystemScript := preload("res://scripts/story/StoryQuestSystem.gd")

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
    "res://scripts/story/RegionStoryGenerator.gd",
    "res://scripts/visual/VisualAssetRegistry.gd",
    "res://scripts/visual/CharacterAssetRegistry.gd",
    "res://scripts/visual/StaticItemAssetRegistry.gd",
    "res://scripts/visual/AnimatedAssetRegistry.gd"
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
    test_duplicate_events_do_not_duplicate_story_effects()
    await test_main_scene_instantiates()
    test_first_arc_waits_for_tutorial_completion()
    test_tutorial_completion_starts_first_quest_once()
    test_mira_event_advances_only_mira_stage()
    test_sera_event_requires_mira_stage()
    test_affected_region_entry_advances_travel_stage()
    test_ordinary_clues_count_idempotently()
    test_historical_clue_unlock_persists_and_quest_round_trips()
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
        var resource := load(path)
        if resource == null:
            failures.append("%s failed to load" % path)
    add_result(
        "project_scripts_load",
        failures.is_empty(),
        "%d scripts checked%s" % [SCRIPT_PATHS.size(), "" if failures.is_empty() else ": " + "; ".join(failures)]
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
            and String(after_clues.get("stage", "")) == "optional_find_historical_clue",
        "count %d, ids %s, stage %s" % [int(facts.get("ordinaryCluesFound", 0)), str(facts.get("ordinaryClueIds", [])), after_clues.get("stage", "")]
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
