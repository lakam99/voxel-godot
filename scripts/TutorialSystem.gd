extends Node
class_name TutorialSystem

const TutorialSceneBuilderScript := preload("res://scripts/TutorialSceneBuilder.gd")
const TutorialRepairQuestScript := preload("res://scripts/TutorialRepairQuest.gd")
const TutorialRescueSystemScript := preload("res://scripts/TutorialRescueSystem.gd")
const TutorialDialogueSystemScript := preload("res://scripts/TutorialDialogueSystem.gd")
const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")
const StartupReadinessResultScript := preload("res://scripts/world/StartupReadinessResult.gd")

const CELL := 1.35
const TUTORIAL_TOWN_REGION := Vector2i(1, 0)
const SAFE_RADIUS_CELLS := 24
const FENCE_RADIUS_CELLS := 25
const INTRO_REQUIRED_FENCE := 8
const INTRO_REQUIRED_LAMPS := 4
const REPAIR_FENCE_TOLERANCE_CELLS := 1
const REPAIR_LAMP_TOLERANCE_CELLS := 3
const RESCUE_MONSTER_COUNT := 6
const RESCUE_GUARD_ID := "sera"
const RESCUE_FORAGER_ID := "niko"
const INVALID_REPAIR_CELL := Vector2i(2147483647, 2147483647)
const TOWN_MANIFEST_LOADING_TIMEOUT_SECONDS := 120.0
const TOWN_MANIFEST_OPS_PER_FRAME := 24
const TOWN_MANIFEST_FRAME_BUDGET_MS := 6.0

var main
var npc_root: Node3D
var light_root: Node3D
var repair_marker_root: Node3D
var started := false
var interacted := {}
var completed_steps := {}
var last_message := ""
var last_dialogue := {}
var last_dialogue_node: Node = null
var town := {}
var start_cell := Vector2i.ZERO
var intro_repair_active := false
var intro_repair_complete := false
var intro_bed_used := false
var intro_door_opened := false
var intro_elder_dialogue_acknowledged := false
var intro_repair_chest_opened := false
var final_night_active := false
var final_night_complete := false
var final_night_defeats_start := 0
var rescue_escort_started := false
var rescue_returning := false
var rescue_site := Vector3.ZERO
var rescue_hostiles: Array = []
var rescue_return_elapsed := 0.0
var rescue_torch: Node3D = null
var speech_bubbles: Array = []
var repair_fence_cells: Array[Vector2i] = []
var repair_lamp_cells: Array[Vector2i] = []
var repaired_fence := {}
var repaired_lamps := {}
var repair_chest_cell := Vector2i.ZERO
var repair_marker_wood_material: StandardMaterial3D
var repair_marker_lamp_material: StandardMaterial3D
var repair_marker_flame_material: StandardMaterial3D
var scene_builder
var repair_quest
var rescue_system
var dialogue_system
var startup_town_manifest := {}
var startup_scenario_requirements := {}
var startup_actor_specs: Array = []
var startup_readiness_result := {}
var restore_world_setup_pending := false

func setup(main_node) -> void:
    main = main_node
    scene_builder = TutorialSceneBuilderScript.new()
    scene_builder.setup(self)
    repair_quest = TutorialRepairQuestScript.new()
    repair_quest.setup(self)
    rescue_system = TutorialRescueSystemScript.new()
    rescue_system.setup(self)
    dialogue_system = TutorialDialogueSystemScript.new()
    dialogue_system.setup(self)

func ensure_rescue_system() -> bool:
    if rescue_system != null:
        return true
    rescue_system = TutorialRescueSystemScript.new()
    if rescue_system == null:
        return false
    rescue_system.setup(self)
    return true

func ensure_dialogue_system() -> bool:
    if dialogue_system != null:
        return true
    dialogue_system = TutorialDialogueSystemScript.new()
    if dialogue_system == null:
        return false
    dialogue_system.setup(self)
    return true

func _process(delta: float) -> void:
    update_speech_bubbles(delta)
    if final_night_active:
        refresh_rescue_progress(delta)

func start_new_world() -> bool:
    if main == null:
        return false
    clear_scene()
    town = main.town_region(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)
    if town.is_empty():
        return false
    reserve_tutorial_town_layout()
    started = true
    interacted.clear()
    completed_steps.clear()
    configure_starting_inventory()
    ensure_town_generated()
    var manifest_result: Dictionary = current_tutorial_manifest_result()
    if String(manifest_result.get("status", "")) != StartupReadinessResultScript.STATUS_READY:
        return false
    startup_town_manifest = (manifest_result.get("manifest", {}) as Dictionary).duplicate(true)
    ensure_village_perimeter()
    ensure_village_lights()
    ensure_starter_shelter()
    ensure_starter_bed()
    setup_intro_repair_quest()
    place_player_in_starter_house()
    var spawn_result: Dictionary = spawn_tutorial_npcs()
    if not bool(spawn_result.get("ok", false)):
        return false
    force_stormy_night()
    last_message = "Knock, knock. Someone is at the door."
    last_dialogue.clear()
    last_dialogue_node = null
    return true

func start_new_world_staged() -> Dictionary:
    reset_startup_readiness_state()
    if main == null:
        return remember_startup_readiness(StartupReadinessResultScript.failed("missing_tutorial_main"))
    clear_scene()
    town = main.town_region(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)
    if town.is_empty():
        return remember_startup_readiness(StartupReadinessResultScript.failed("missing_tutorial_town"))
    reserve_tutorial_town_layout()
    started = true
    interacted.clear()
    completed_steps.clear()
    configure_starting_inventory()
    return await prepare_tutorial_world_staged(false)

func complete_restore_world_staged() -> Dictionary:
    if not started:
        return remember_startup_readiness(StartupReadinessResultScript.ready({}, {
            "mode": "continue",
            "tutorialActive": false
        }))
    if main == null:
        return remember_startup_readiness(StartupReadinessResultScript.failed("missing_tutorial_main"))
    if town.is_empty():
        town = main.town_region(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)
        if town.is_empty():
            return remember_startup_readiness(StartupReadinessResultScript.failed("missing_tutorial_town"))
        reserve_tutorial_town_layout()
    return await prepare_tutorial_world_staged(true)

func prepare_tutorial_world_staged(restoring: bool) -> Dictionary:
    startup_scenario_requirements = tutorial_scenario_requirements()
    if not bool(startup_scenario_requirements.get("ok", false)):
        return await fail_tutorial_startup("invalid_tutorial_scenario_requirements", {}, {
            "failureReasons": startup_scenario_requirements.get("problems", [])
        })
    await loading_yield("Tutorial requirements ready", "tutorial_scenario", "ready", {
        "requiredHomeKeys": startup_scenario_requirements.get("requiredHomeKeys", []),
        "actorAssignmentCount": (startup_scenario_requirements.get("actorHomeAssignments", {}) as Dictionary).size()
    })
    var manifest_result: Dictionary = await ensure_town_manifest_ready_staged(startup_scenario_requirements)
    if String(manifest_result.get("status", "")) != StartupReadinessResultScript.STATUS_READY:
        return remember_startup_readiness(manifest_result)
    startup_town_manifest = (manifest_result.get("manifest", {}) as Dictionary).duplicate(true)
    var actor_resolution: Dictionary = resolve_tutorial_actor_specs(startup_town_manifest)
    if not bool(actor_resolution.get("ok", false)):
        return await fail_tutorial_startup(
            "tutorial_actor_manifest_resolution_failed",
            startup_town_manifest,
            actor_resolution
        )
    startup_actor_specs = (actor_resolution.get("specs", []) as Array).duplicate(true)
    var door_result := tutorial_manifest_door_readiness(startup_town_manifest)
    if String(door_result.get("status", "")) != StartupReadinessResultScript.STATUS_READY:
        return await fail_tutorial_startup(
            String(door_result.get("reason", "required_town_doors_not_registered")),
            startup_town_manifest,
            door_result.get("metrics", {})
        )
    await loading_yield("Tutorial town doors ready", "town_doors", "ready", door_result.get("metrics", {}))
    await loading_yield("Preparing village perimeter", "tutorial_scene", "pending")
    ensure_village_perimeter()
    await loading_yield("Preparing village lights", "tutorial_scene", "pending")
    ensure_village_lights()
    await loading_yield("Preparing starter shelter", "tutorial_scene", "pending")
    ensure_starter_shelter()
    ensure_starter_bed()
    await loading_yield("Tutorial scene ready", "tutorial_scene", "ready")
    setup_intro_repair_quest(not restoring)
    if not restoring:
        place_player_in_starter_house()
    await loading_yield("Preparing villagers", "npc_registration", "pending")
    var spawn_result: Dictionary = scene_builder.spawn_tutorial_npcs(startup_actor_specs)
    if not bool(spawn_result.get("ok", false)):
        return await fail_tutorial_startup(
            "tutorial_actor_spawn_failed",
            startup_town_manifest,
            spawn_result
        )
    set_registered_npc_physics_enabled(false)
    var registration_result := tutorial_npc_registration_readiness(startup_town_manifest)
    if String(registration_result.get("status", "")) != StartupReadinessResultScript.STATUS_READY:
        return await fail_tutorial_startup(
            String(registration_result.get("reason", "required_tutorial_npcs_not_registered")),
            startup_town_manifest,
            registration_result.get("metrics", {})
        )
    await loading_yield("Villagers registered", "npc_registration", "ready", registration_result.get("metrics", {}))
    if not restoring:
        force_stormy_night()
        last_message = "Knock, knock. Someone is at the door."
        last_dialogue.clear()
        last_dialogue_node = null
    restore_world_setup_pending = false
    var metrics := {
        "mode": "continue" if restoring else "new_game",
        "tutorialActive": true,
        "manifest": manifest_result.get("metrics", {}),
        "doors": door_result.get("metrics", {}),
        "npcRegistration": registration_result.get("metrics", {}),
        "actorResolution": actor_resolution.get("metrics", {}),
        "actorSpawn": spawn_result.get("metrics", {})
    }
    await loading_yield("Tutorial world ready", "tutorial_world", "ready", metrics)
    return remember_startup_readiness(StartupReadinessResultScript.ready(startup_town_manifest, metrics))

func ensure_town_manifest_ready_staged(requirements: Dictionary) -> Dictionary:
    if main == null or town.is_empty() or main.structure_system == null:
        return await fail_tutorial_startup("missing_structure_manifest_authority")
    if not main.structure_system.has_method("request_town_manifest_publication"):
        return await fail_tutorial_startup("missing_structure_manifest_publication_api")
    var started_usec := Time.get_ticks_usec()
    var last_result: Dictionary = {}
    while true:
        var result_value = main.structure_system.call(
            "request_town_manifest_publication",
            town,
            requirements,
            TOWN_MANIFEST_OPS_PER_FRAME,
            TOWN_MANIFEST_FRAME_BUDGET_MS
        )
        if not (result_value is Dictionary):
            return await fail_tutorial_startup("invalid_structure_manifest_result")
        last_result = result_value
        var status := String(last_result.get("status", ""))
        var metrics: Dictionary = last_result.get("metrics", {}) if last_result.get("metrics", {}) is Dictionary else {}
        if status == StartupReadinessResultScript.STATUS_READY:
            await loading_yield("Tutorial town manifest ready", "town_manifest", "ready", metrics)
            return last_result
        if status == StartupReadinessResultScript.STATUS_FAILED:
            return await fail_tutorial_startup(
                String(last_result.get("reason", "tutorial_town_manifest_failed")),
                last_result.get("manifest", {}),
                metrics
            )
        var elapsed_seconds := float(Time.get_ticks_usec() - started_usec) / 1000000.0
        if elapsed_seconds >= TOWN_MANIFEST_LOADING_TIMEOUT_SECONDS:
            var timeout_metrics := metrics.duplicate(true)
            timeout_metrics["timeoutSeconds"] = TOWN_MANIFEST_LOADING_TIMEOUT_SECONDS
            timeout_metrics["elapsedSeconds"] = snappedf(elapsed_seconds, 0.001)
            return await fail_tutorial_startup(
                "tutorial_town_manifest_timeout",
                last_result.get("manifest", {}),
                timeout_metrics
            )
        var published_keys: Array = metrics.get("publishedKeys", []) if metrics.get("publishedKeys", []) is Array else []
        var required_keys: Array = metrics.get("requiredKeys", []) if metrics.get("requiredKeys", []) is Array else []
        await loading_yield(
            "Building tutorial town %d/%d homes, %d operations" % [
                published_keys.size(),
                required_keys.size(),
                int(metrics.get("pendingOpCount", 0))
            ],
            "town_manifest",
            "pending",
            metrics
        )
    return await fail_tutorial_startup("tutorial_town_manifest_loop_ended")

func tutorial_scenario_requirements() -> Dictionary:
    var assignments: Array = [{"id": "player_starter_home", "homeKey": 0}]
    for scenario_value in tutorial_actor_scenarios():
        if scenario_value is Dictionary:
            var scenario: Dictionary = scenario_value
            assignments.append({
                "id": String(scenario.get("id", "")),
                "homeKey": int(scenario.get("homeKey", -1))
            })
    return TownRuntimeManifestScript.requirements_from_actor_specs(assignments)

func tutorial_actor_scenarios() -> Array:
    return [
        {
            "id": "mira",
            "homeKey": 3,
            "presentation": {
                "name": "Mira",
                "role": "Elder",
                "color": Color(0.70, 0.46, 0.34),
                "accent": Color(0.92, 0.76, 0.42),
                "dialogue": [
                    "Storms bring the dark close. Start by meeting Rowan near the workbench.",
                    "The lights mark the safe ground. Beyond them, shadows notice you."
                ]
            },
            "simulation": {
                "role": "Civilian",
                "job": "",
                "holdIntroDoor": true
            },
            "spawn": {"kind": "offset", "offset": Vector2i(-13, -15)},
            "initialOrder": {"kind": "wait", "reason": "tutorial_knock_pending"}
        },
        {
            "id": "rowan",
            "homeKey": 1,
            "presentation": {
                "name": "Rowan",
                "role": "Carpenter",
                "color": Color(0.48, 0.32, 0.18),
                "accent": Color(0.73, 0.52, 0.28),
                "dialogue": [
                    "Workbench first. Logs become blocks, blocks become shelter.",
                    "Bring me wood when you're ready and we'll turn it into something sturdy."
                ]
            },
            "simulation": {"role": "Carpenter", "job": "wood", "startInsideHome": true},
            "spawn": {"kind": "home"}
        },
        {
            "id": "niko",
            "homeKey": 2,
            "presentation": {
                "name": "Niko",
                "role": "Forager",
                "color": Color(0.31, 0.50, 0.28),
                "accent": Color(0.82, 0.42, 0.35),
                "dialogue": [
                    "Food keeps your hands steady. Berries, fish, and cooked meat all matter.",
                    "Stay near the path while the rain is heavy."
                ]
            },
            "simulation": {"role": "Forager", "job": "forage", "startInsideHome": true},
            "spawn": {"kind": "home"}
        },
        {
            "id": "sera",
            "homeKey": 1,
            "presentation": {
                "name": "Sera",
                "role": "Watch",
                "color": Color(0.30, 0.34, 0.42),
                "accent": Color(0.66, 0.72, 0.86),
                "dialogue": [
                    "Do not cross the last lantern unarmed. Hostiles gather outside the village lights.",
                    "Craft a blade or bow before you brave the wilds."
                ]
            },
            "simulation": {
                "role": "Guard",
                "job": "guard",
                "guardOffset": Vector2i(FENCE_RADIUS_CELLS - 3, 0),
                "canFight": true,
                "nightGuard": true,
                "weapon": "hunterBow"
            },
            "spawn": {"kind": "offset", "offset": Vector2i(7, 0)}
        },
        {
            "id": "toma",
            "homeKey": 1,
            "presentation": {
                "name": "Toma",
                "role": "Gate Watch",
                "color": Color(0.34, 0.34, 0.30),
                "accent": Color(0.78, 0.66, 0.38),
                "dialogue": [
                    "The fence slows them. Arrows finish the rest.",
                    "Stay behind the lantern line when the gate splinters."
                ]
            },
            "simulation": {
                "role": "Guard",
                "job": "guard",
                "guardOffset": Vector2i(0, -FENCE_RADIUS_CELLS + 2),
                "canFight": true,
                "nightGuard": true,
                "weapon": "hunterBow"
            },
            "spawn": {"kind": "offset", "offset": Vector2i(0, -FENCE_RADIUS_CELLS + 4)}
        },
        {
            "id": "lyra",
            "homeKey": 2,
            "presentation": {
                "name": "Lyra",
                "role": "Lantern Archer",
                "color": Color(0.28, 0.38, 0.44),
                "accent": Color(0.68, 0.78, 0.88),
                "dialogue": [
                    "If a rail breaks, we hold the gap.",
                    "Watch their movement. They hate the light."
                ]
            },
            "simulation": {
                "role": "Guard",
                "job": "guard",
                "guardOffset": Vector2i(-FENCE_RADIUS_CELLS + 2, 0),
                "canFight": true,
                "nightGuard": true,
                "weapon": "hunterBow"
            },
            "spawn": {"kind": "offset", "offset": Vector2i(-FENCE_RADIUS_CELLS + 4, 0)}
        }
    ]

func current_tutorial_manifest_result() -> Dictionary:
    startup_scenario_requirements = tutorial_scenario_requirements()
    if not bool(startup_scenario_requirements.get("ok", false)):
        return StartupReadinessResultScript.failed("invalid_tutorial_scenario_requirements")
    if main == null or main.structure_system == null or not main.structure_system.has_method("town_manifest_status"):
        return StartupReadinessResultScript.failed("missing_structure_manifest_authority")
    var result_value = main.structure_system.call("town_manifest_status", town, startup_scenario_requirements)
    if not (result_value is Dictionary):
        return StartupReadinessResultScript.failed("invalid_structure_manifest_result")
    return result_value

func resolve_tutorial_actor_specs(manifest: Dictionary) -> Dictionary:
    if scene_builder == null:
        return {"ok": false, "reason": "missing_tutorial_scene_builder", "problems": ["missing tutorial scene builder"]}
    return scene_builder.resolve_tutorial_actor_specs(manifest, tutorial_actor_scenarios(), town)

func tutorial_expected_npc_ids() -> Array[String]:
    return ["mira", "rowan", "niko", "sera", "toma", "lyra"]

func tutorial_manifest_door_readiness(manifest: Dictionary) -> Dictionary:
    var required_ids: Array = manifest.get("doorPortalIds", []) if manifest.get("doorPortalIds", []) is Array else []
    var live_block_ids := {}
    if main != null and main.get("blocks") is Dictionary:
        for block_value in (main.get("blocks") as Dictionary).values():
            var block := block_value as Node
            if block == null or not is_instance_valid(block):
                continue
            var portal_id := String(block.get_meta("door_portal_id", ""))
            if portal_id != "":
                live_block_ids[portal_id] = true
    var service_ids := {}
    if main != null and main.npc_system != null:
        var autonomy = main.npc_system.get("autonomy_system")
        var door_portals = autonomy.get("door_portals") if autonomy != null else null
        if door_portals != null and door_portals.get("portals") is Dictionary:
            for portal_id_value in (door_portals.get("portals") as Dictionary).keys():
                service_ids[String(portal_id_value)] = true
    var missing_blocks: Array[String] = []
    var missing_services: Array[String] = []
    for portal_id_value in required_ids:
        var portal_id := String(portal_id_value)
        if not live_block_ids.has(portal_id):
            missing_blocks.append(portal_id)
        if not service_ids.has(portal_id):
            missing_services.append(portal_id)
    var metrics := {
        "requiredDoorCount": required_ids.size(),
        "liveDoorBlockCount": required_ids.size() - missing_blocks.size(),
        "registeredDoorPortalCount": required_ids.size() - missing_services.size(),
        "missingDoorBlocks": missing_blocks,
        "missingDoorPortals": missing_services
    }
    if not missing_blocks.is_empty() or not missing_services.is_empty():
        return StartupReadinessResultScript.failed("required_town_doors_not_registered", manifest, [], metrics)
    return StartupReadinessResultScript.ready(manifest, metrics)

func tutorial_npc_registration_readiness(manifest: Dictionary) -> Dictionary:
    var expected_ids := tutorial_expected_npc_ids()
    var registered := {}
    if main != null and main.npc_system != null and main.npc_system.get("npcs") is Array:
        for entry_value in (main.npc_system.get("npcs") as Array):
            if not (entry_value is Dictionary):
                continue
            var entry: Dictionary = entry_value
            var npc_id := String(entry.get("id", ""))
            var body := entry.get("body") as Node
            if npc_id != "" and body != null and is_instance_valid(body):
                registered[npc_id] = entry
    var missing: Array[String] = []
    var profile_mismatches: Array[Dictionary] = []
    var assignments: Dictionary = startup_scenario_requirements.get("actorHomeAssignments", {}) if startup_scenario_requirements.get("actorHomeAssignments", {}) is Dictionary else {}
    var homes: Dictionary = manifest.get("homesByKey", {}) if manifest.get("homesByKey", {}) is Dictionary else {}
    for npc_id in expected_ids:
        if not registered.has(npc_id):
            missing.append(npc_id)
            continue
        var home_key := int(assignments.get(npc_id, -1))
        var home_value = homes.get(str(home_key))
        if not (home_value is Dictionary):
            profile_mismatches.append({"id": npc_id, "problems": ["manifest homeKey %d missing" % home_key]})
            continue
        var problems := tutorial_registration_profile_problems(registered[npc_id], home_key, home_value, manifest)
        if not problems.is_empty():
            profile_mismatches.append({"id": npc_id, "problems": problems})
    var metrics := {
        "expectedNpcIds": expected_ids,
        "expectedNpcCount": expected_ids.size(),
        "registeredNpcCount": expected_ids.size() - missing.size(),
        "missingNpcIds": missing,
        "profileMismatchCount": profile_mismatches.size(),
        "profileMismatches": profile_mismatches
    }
    if not missing.is_empty():
        return StartupReadinessResultScript.failed("required_tutorial_npcs_not_registered", manifest, [], metrics)
    if not profile_mismatches.is_empty():
        return StartupReadinessResultScript.failed("tutorial_npc_manifest_profile_mismatch", manifest, [], metrics)
    return StartupReadinessResultScript.ready(manifest, metrics)

func tutorial_registration_profile_problems(entry: Dictionary, home_key: int, home_value, manifest: Dictionary) -> Array[String]:
    var problems: Array[String] = []
    if not (home_value is Dictionary):
        problems.append("home record is not a dictionary")
        return problems
    var home: Dictionary = home_value
    var expected := {
        "homeKey": home_key,
        "homeStableId": String(home.get("stableId", "")),
        "doorPortalId": String(home.get("doorPortalId", "")),
        "townKey": String(manifest.get("townKey", "")),
        "homeCell": home.get("homeCell"),
        "porchCell": home.get("porchCell"),
        "doorCell": home.get("doorCell"),
        "interiorLandingCell": home.get("interiorLandingCell"),
        "interiorMinCell": home.get("interiorMinCell"),
        "interiorMaxCell": home.get("interiorMaxCell")
    }
    for field in expected.keys():
        if entry.get(field) != expected[field]:
            problems.append("%s does not match manifest" % field)
    var expected_route: Array = home.get("homeRouteCells", []) if home.get("homeRouteCells", []) is Array else []
    var actual_route: Array = entry.get("homeRouteCells", []) if entry.get("homeRouteCells", []) is Array else []
    if actual_route != expected_route:
        problems.append("homeRouteCells do not match manifest")
    return problems

func set_registered_npc_physics_enabled(enabled: bool) -> void:
    if main != null and main.has_method("set_registered_npc_physics_enabled"):
        main.call("set_registered_npc_physics_enabled", enabled)
        return
    if npc_root == null:
        return
    for child in npc_root.get_children():
        if child is Node:
            (child as Node).set_physics_process(enabled)

func fail_tutorial_startup(reason: String, manifest := {}, metrics := {}) -> Dictionary:
    var normalized_manifest: Dictionary = manifest if manifest is Dictionary else {}
    var normalized_metrics: Dictionary = metrics if metrics is Dictionary else {}
    await loading_yield("Tutorial loading failed: %s" % reason, "tutorial_world", "failed", normalized_metrics)
    return remember_startup_readiness(StartupReadinessResultScript.failed(reason, normalized_manifest, [], normalized_metrics))

func remember_startup_readiness(result: Dictionary) -> Dictionary:
    startup_readiness_result = result.duplicate(true)
    return startup_readiness_result.duplicate(true)

func reset_startup_readiness_state() -> void:
    startup_town_manifest.clear()
    startup_scenario_requirements.clear()
    startup_actor_specs.clear()
    startup_readiness_result.clear()
    restore_world_setup_pending = false

func loading_yield(message: String, domain := "tutorial", status := "pending", metrics := {}) -> void:
    if main != null and main.has_method("startup_loading_yield"):
        await main.call("startup_loading_yield", message, domain, status, metrics)
    elif get_tree() != null:
        await get_tree().process_frame

func restore(snapshot_value = {}) -> void:
    reset_startup_readiness_state()
    clear_scene()
    var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    started = bool(state.get("started", false))
    interacted.clear()
    var interacted_ids = state.get("interacted", [])
    if interacted_ids is Array:
        for npc_id in interacted_ids:
            interacted[String(npc_id)] = true
    completed_steps.clear()
    var step_ids = state.get("completedSteps", [])
    if step_ids is Array:
        for step_id in step_ids:
            completed_steps[String(step_id)] = true
    var start_cell_value = state.get("startCell", [])
    if start_cell_value is Array and start_cell_value.size() >= 2:
        start_cell = Vector2i(int(start_cell_value[0]), int(start_cell_value[1]))
    restore_intro_state(state.get("introRepair", {}))
    last_message = String(state.get("lastMessage", ""))
    if not started or main == null:
        town = {}
        return
    town = main.town_region(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)
    reserve_tutorial_town_layout()
    sync_crafting_unlocks_from_tutorial()
    if should_defer_restore_world_setup():
        restore_world_setup_pending = true
        return
    complete_restore_world_now()

func should_defer_restore_world_setup() -> bool:
    if main == null:
        return false
    return bool(main.get("startup_loading_active")) or bool(main.get("runtime_loading_active"))

func complete_restore_world_now() -> void:
    ensure_town_generated()
    var manifest_result: Dictionary = current_tutorial_manifest_result()
    if String(manifest_result.get("status", "")) != StartupReadinessResultScript.STATUS_READY:
        last_message = "Tutorial town records are not ready."
        return
    startup_town_manifest = (manifest_result.get("manifest", {}) as Dictionary).duplicate(true)
    ensure_village_perimeter()
    ensure_village_lights()
    ensure_starter_shelter()
    ensure_starter_bed()
    setup_intro_repair_quest(false)
    var spawn_result: Dictionary = spawn_tutorial_npcs()
    if not bool(spawn_result.get("ok", false)):
        last_message = "Tutorial villagers could not be registered."
        return
    restore_world_setup_pending = false

func reserve_tutorial_town_layout() -> void:
    if main == null or town.is_empty():
        return
    town["radius"] = FENCE_RADIUS_CELLS
    town["homeExclusionRings"] = [
        {
            "radius": FENCE_RADIUS_CELLS,
            "margin": 3,
            "reason": "tutorial_repair_perimeter"
        }
    ]
    if main.get("town_region_cache") is Dictionary:
        var cache: Dictionary = main.get("town_region_cache")
        cache[Vector2i(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)] = town

func snapshot() -> Dictionary:
    return {
        "started": started,
        "interacted": interacted.keys(),
        "completedSteps": completed_steps.keys(),
        "lastMessage": last_message,
        "townRegion": [TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y],
        "startCell": [start_cell.x, start_cell.y],
        "introRepair": intro_snapshot(),
        "npcCount": npc_count()
    }

func state() -> Dictionary:
    return {
        "started": started,
        "interacted": interacted.duplicate(),
        "completedSteps": completed_steps.duplicate(),
        "readyForWilds": is_ready_for_wilds(),
        "npcCount": npc_count(),
        "lastMessage": last_message,
        "townCenter": Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))) if not town.is_empty() else Vector2i.ZERO,
        "startCell": start_cell,
        "introDoorOpened": intro_door_opened,
        "introElderDialogueAcknowledged": intro_elder_dialogue_acknowledged,
        "introRepairChestOpened": intro_repair_chest_opened,
        "introRepairActive": intro_repair_active,
        "introRepairComplete": intro_repair_complete,
        "introBedUsed": intro_bed_used,
        "introFencePlaced": repaired_fence.size(),
        "introFenceRequired": INTRO_REQUIRED_FENCE,
        "introLampsPlaced": repaired_lamps.size(),
        "introLampsRequired": INTRO_REQUIRED_LAMPS,
        "introRepairChestCell": repair_chest_cell,
        "postIntroMiraBriefed": mira_morning_briefed(),
        "tutorialStage": current_tutorial_stage(),
        "finalNightActive": final_night_active,
        "finalNightComplete": final_night_complete,
        "finalNightDefeats": final_night_defeats(),
        "finalNightRequired": RESCUE_MONSTER_COUNT,
        "rescueEscortStarted": rescue_escort_started,
        "rescueReturning": rescue_returning,
        "rescueRemaining": rescue_remaining_hostiles(),
        "rescueRequired": RESCUE_MONSTER_COUNT,
        "rescueSite": rescue_site,
        "introRepairTargets": {
            "fence": repair_fence_cells.duplicate(),
            "lamps": repair_lamp_cells.duplicate()
        }
    }

func tutorial_town_key() -> String:
    if town.is_empty():
        return ""
    return "%d,%d" % [int(town.get("centerX", 0)), int(town.get("centerZ", 0))]

func configure_starting_inventory() -> void:
    if main == null or main.inventory_system == null:
        return
    main.inventory_system.clear()
    if main.has_method("reset_crafting_unlocks"):
        main.reset_crafting_unlocks(["tutorial_repair"])
    main._sync_inventory_totals()

func unlock_crafting_group(group_id: String, reason := "") -> bool:
    if main == null or not main.has_method("unlock_crafting_group"):
        return false
    return bool(main.unlock_crafting_group(group_id, reason))

func sync_crafting_unlocks_from_tutorial() -> void:
    if main == null:
        return
    unlock_crafting_group("tutorial_repair", "tutorial repair crafting")
    if bool(interacted.get("rowan", false)) or bool(completed_steps.get("rowanAxe", false)) or bool(completed_steps.get("rowanPickaxe", false)) or bool(completed_steps.get("rowanBlocks", false)):
        unlock_crafting_group("rowan_basic_tools", "Rowan's basic tools")
    if bool(interacted.get("sera", false)) or bool(completed_steps.get("seraWeapon", false)) or bool(completed_steps.get("readyForWilds", false)) or final_night_active or final_night_complete:
        unlock_crafting_group("rescue_weapon", "rescue weapon training")

func intro_snapshot() -> Dictionary:
    return {
        "active": intro_repair_active,
        "complete": intro_repair_complete,
        "bedUsed": intro_bed_used,
        "doorOpened": intro_door_opened,
        "elderAcknowledged": intro_elder_dialogue_acknowledged,
        "chestOpened": intro_repair_chest_opened,
        "finalNightActive": final_night_active,
        "finalNightComplete": final_night_complete,
        "finalNightDefeatsStart": final_night_defeats_start,
        "rescueEscortStarted": rescue_escort_started,
        "rescueReturning": rescue_returning,
        "rescueSite": [rescue_site.x, rescue_site.y, rescue_site.z],
        "fence": repaired_fence.keys(),
        "lamps": repaired_lamps.keys()
    }

func restore_intro_state(state_value = {}) -> void:
    var state: Dictionary = state_value if state_value is Dictionary else {}
    intro_repair_active = bool(state.get("active", true))
    intro_repair_complete = bool(state.get("complete", false))
    intro_bed_used = bool(state.get("bedUsed", false))
    intro_door_opened = bool(state.get("doorOpened", false))
    intro_elder_dialogue_acknowledged = bool(state.get("elderAcknowledged", intro_door_opened))
    intro_repair_chest_opened = bool(state.get("chestOpened", false))
    final_night_active = bool(state.get("finalNightActive", false))
    final_night_complete = bool(state.get("finalNightComplete", false))
    final_night_defeats_start = int(state.get("finalNightDefeatsStart", 0))
    rescue_escort_started = bool(state.get("rescueEscortStarted", false))
    rescue_returning = bool(state.get("rescueReturning", false))
    var rescue_site_value = state.get("rescueSite", [])
    if rescue_site_value is Array and rescue_site_value.size() >= 3:
        rescue_site = Vector3(float(rescue_site_value[0]), float(rescue_site_value[1]), float(rescue_site_value[2]))
    else:
        rescue_site = Vector3.ZERO
    repaired_fence.clear()
    for key_variant in state.get("fence", []):
        repaired_fence[String(key_variant)] = true
    repaired_lamps.clear()
    for key_variant in state.get("lamps", []):
        repaired_lamps[String(key_variant)] = true

func setup_intro_repair_quest(reset_state := true) -> void:
    repair_quest.setup_intro_repair_quest(reset_state)

func damage_intro_perimeter() -> void:
    repair_quest.damage_intro_perimeter()

func remove_repair_block(cell: Vector2i, block_type: String) -> void:
    repair_quest.remove_repair_block(cell, block_type)

func place_intro_repair_chest() -> void:
    repair_quest.place_intro_repair_chest()

func repair_chest_slots() -> Array:
    return repair_quest.repair_chest_slots()

func repair_cell_key(cell: Vector2i) -> String:
    return repair_quest.repair_cell_key(cell)

func repair_supplies_ready(state: Dictionary) -> bool:
    return repair_quest.repair_supplies_ready(state)

func nearest_unrepaired_cell(flat: Vector2i, targets: Array[Vector2i], repaired: Dictionary, tolerance: int) -> Vector2i:
    return repair_quest.nearest_unrepaired_cell(flat, targets, repaired, tolerance)

func valid_repair_cell(cell: Vector2i) -> bool:
    return repair_quest.valid_repair_cell(cell)

func repair_lamp_type(block_type: String) -> bool:
    return repair_quest.repair_lamp_type(block_type)

func intro_repair_progress_message() -> String:
    return repair_quest.intro_repair_progress_message()

func setup_repair_marker_materials() -> void:
    repair_quest.setup_marker_materials()

func make_repair_marker_material(albedo: Color, emission: Color, energy: float) -> StandardMaterial3D:
    return repair_quest.make_marker_material(albedo, emission, energy)

func refresh_repair_markers() -> void:
    repair_quest.refresh_repair_markers()

func clear_repair_markers() -> void:
    repair_quest.clear_repair_markers()

func add_repair_marker(cell: Vector2i, block_type: String) -> void:
    repair_quest.add_repair_marker(cell, block_type)

func add_repair_marker_box(parent: Node3D, size: Vector3, offset: Vector3, material: Material, rotation := Vector3.ZERO) -> void:
    repair_quest.add_marker_box(parent, size, offset, material, rotation)

func on_door_opened(door: Node) -> bool:
    if not started:
        return false
    if intro_door_opened:
        return intro_repair_active and not intro_elder_dialogue_acknowledged
    intro_door_opened = true
    intro_elder_dialogue_acknowledged = false
    interacted["mira"] = true
    var line := "I'm sorry to wake you. Monsters broke the outer lamps and fence. Take wood and stone from the town chest and patch the gaps before anyone sleeps."
    last_message = "Mira: %s" % line
    last_dialogue = dialogue_system.make_dialogue_payload("Mira", "Elder", line, "mira", true)
    complete_step("introDoorOpened")
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()
    return true

func on_utility_opened(block: Node) -> bool:
    if block == null or not bool(block.get_meta("intro_repair_chest", false)):
        return false
    intro_repair_chest_opened = true
    complete_step("introRepairChest")
    last_message = "Repair chest opened: craft wood blocks for the fence and torches for the broken lamps."
    last_dialogue.clear()
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()
    return true

func on_block_placed(block: Node) -> bool:
    return repair_quest.on_block_placed(block)

func refresh_intro_repair_complete() -> bool:
    return repair_quest.refresh_intro_repair_complete()

func is_bed_locked() -> bool:
    return (started and intro_repair_active and not intro_repair_complete) or final_night_active

func on_bed_blocked() -> void:
    if final_night_active:
        last_message = "Mira: Not yet. Bring Niko back before anyone sleeps."
    else:
        last_message = "Mira: Not yet. The lamps and fence have to be repaired before anyone can sleep."
    last_dialogue.clear()

func on_bed_used() -> void:
    if not started or intro_bed_used:
        return
    intro_bed_used = true
    intro_repair_active = false
    resume_intro_elder_schedule()
    complete_step("introFirstSleep")
    last_message = "You slept through the storm. Dawn breaks over the repaired village."
    last_dialogue.clear()
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()

func should_freeze_intro_night() -> bool:
    return (started and intro_repair_active and not intro_bed_used) or (final_night_active and not final_night_complete)

func should_loop_intro_knock() -> bool:
    return started and intro_repair_active and not intro_door_opened

func is_intro_elder_waiting_for_ack() -> bool:
    return started and intro_repair_active and intro_door_opened and not intro_elder_dialogue_acknowledged

func acknowledge_dialogue(context := {}) -> void:
    var state: Dictionary = context if context is Dictionary else {}
    var state_npc_id := String(state.get("npcId", ""))
    var current_npc_id := String(last_dialogue.get("npcId", ""))
    var intro_ack := bool(state.get("introElder", false)) \
        or (
            state_npc_id != ""
            and current_npc_id != ""
            and state_npc_id == current_npc_id
            and bool(last_dialogue.get("introElder", false))
            and intro_door_opened
            and not intro_elder_dialogue_acknowledged
        )
    if intro_ack:
        intro_elder_dialogue_acknowledged = true
        release_intro_elder_home_order()
    clear_dialogue_focus()

func dialogue_payload() -> Dictionary:
    return last_dialogue.duplicate(true)

func release_intro_elder_home_order() -> void:
    if main == null or main.npc_system == null or not main.npc_system.has_method("order_go_home"):
        return
    var actor = intro_elder_dialogue_actor()
    if actor == null:
        last_message = "The elder is no longer in reach."
        return
    if main.npc_system.has_method("release_intro_hold_and_order_home"):
        var release_result: Dictionary = main.npc_system.release_intro_hold_and_order_home(actor, "intro_acknowledged_return_home")
        if String(release_result.get("state", "")) != "FAILED_TARGET_GONE":
            return
    var entry: Dictionary = main.npc_system.npc_entry_for_actor(actor) if main.npc_system.has_method("npc_entry_for_actor") else {}
    if not entry.is_empty():
        if main.npc_system.has_method("clear_intro_hold_for_entry"):
            main.npc_system.clear_intro_hold_for_entry(entry)
        else:
            entry["holdIntroDoor"] = false
        var body := entry.get("body") as Node
        if body != null and is_instance_valid(body):
            body.set_meta("npc_hold_intro_door", false)
    main.npc_system.order_go_home(actor, "intro_acknowledged_return_home")

func intro_elder_dialogue_actor():
    if last_dialogue_node != null and is_instance_valid(last_dialogue_node):
        return last_dialogue_node
    var npc_id := String(last_dialogue.get("npcId", ""))
    if npc_id != "":
        return npc_id
    return null

func resume_intro_elder_schedule() -> void:
    if main == null or main.npc_system == null or not main.npc_system.has_method("order_resume_schedule"):
        return
    main.npc_system.order_resume_schedule("mira")

func focus_dialogue_npc() -> void:
    if last_dialogue_node == null or main == null or main.npc_system == null or main.player == null:
        return
    if main.npc_system.has_method("focus_dialogue_npc"):
        main.npc_system.focus_dialogue_npc(last_dialogue_node, main.player.global_position)

func clear_dialogue_focus() -> void:
    last_dialogue_node = null
    if main and main.npc_system and main.npc_system.has_method("clear_dialogue_focus"):
        main.npc_system.clear_dialogue_focus()

func update_progress(state: Dictionary) -> bool:
    if not started:
        return false
    var changed := false
    changed = complete_step_if("introDoorOpened", intro_door_opened) or changed
    changed = complete_step_if("introRepairChest", intro_repair_chest_opened) or changed
    changed = complete_step_if("introFenceBuilt", repair_supplies_ready(state)) or changed
    changed = complete_step_if("introPerimeterRepaired", intro_repair_complete) or changed
    changed = complete_step_if("introFirstSleep", intro_bed_used) or changed
    changed = complete_step_if("finalNightStarted", final_night_active or final_night_complete) or changed
    changed = refresh_rescue_progress() or changed
    changed = complete_step_if("finalNightComplete", final_night_complete) or changed
    var totals: Dictionary = state.get("totals", {})
    if bool(interacted.get("rowan", false)):
        changed = complete_step_if("rowanAxe", has_axe(totals)) or changed
        changed = complete_step_if("rowanLogs", bool(completed_steps.get("rowanAxe", false)) and int(totals.get("logs", 0)) >= 4) or changed
        changed = complete_step_if("rowanPickaxe", has_pickaxe(totals)) or changed
        changed = complete_step_if("rowanStones", bool(completed_steps.get("rowanPickaxe", false)) and int(totals.get("stones", 0)) >= 4) or changed
        changed = complete_step_if("rowanBlocks", bool(completed_steps.get("rowanStones", false))) or changed
    if bool(interacted.get("niko", false)):
        changed = complete_step_if("nikoBerries", int(totals.get("berries", 0)) >= 2 or int(totals.get("fieldRation", 0)) > 0) or changed
    if bool(interacted.get("sera", false)):
        changed = complete_step_if("seraWeapon", has_weapon(totals)) or changed
    changed = complete_step_if("readyForWilds", is_ready_for_wilds()) or changed
    return changed

func is_tutorial_npc(node: Node) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.is_tutorial_npc(node)

func interact_with(node: Node) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.interact_with(node)

func handle_npc_quest(npc_id: String) -> String:
    if not ensure_dialogue_system():
        return ""
    return dialogue_system.handle_npc_quest(npc_id)

func award_once(step_id: String, reason: String, items: Dictionary, xp := 0) -> bool:
    if bool(completed_steps.get(step_id, false)):
        return false
    completed_steps[step_id] = true
    if main and main.inventory_system:
        for item_id_variant in items.keys():
            main.inventory_system.add_item(String(item_id_variant), int(items[item_id_variant]))
        main._sync_inventory_totals()
    if xp > 0 and main and main.has_method("award_progression"):
        main.award_progression(reason, xp)
    return true

func complete_step(step_id: String) -> bool:
    if bool(completed_steps.get(step_id, false)):
        return false
    completed_steps[step_id] = true
    return true

func complete_step_if(step_id: String, condition: bool) -> bool:
    if not condition:
        return false
    return complete_step(step_id)

func is_ready_for_wilds() -> bool:
    return bool(completed_steps.get("rowanBlocks", false)) and bool(completed_steps.get("nikoBerries", false)) and bool(completed_steps.get("seraWeapon", false))

func mira_morning_briefed() -> bool:
    return bool(completed_steps.get("miraMorningBriefing", false))

func start_final_night() -> bool:
    if not ensure_rescue_system():
        return false
    return rescue_system.start_final_night()

func complete_final_night() -> bool:
    if not ensure_rescue_system():
        return false
    return rescue_system.complete_final_night()

func final_night_defeats() -> int:
    if not ensure_rescue_system():
        return RESCUE_MONSTER_COUNT if final_night_complete else 0
    return rescue_system.final_night_defeats()

func current_hostile_defeats() -> int:
    if not ensure_rescue_system():
        return 0
    return rescue_system.current_hostile_defeats()

func setup_rescue_scene() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.setup_rescue_scene()

func choose_rescue_site() -> Vector3:
    if not ensure_rescue_system():
        return Vector3.ZERO
    return rescue_system.choose_rescue_site()

func spawn_rescue_torch(position: Vector3) -> void:
    if not ensure_rescue_system():
        return
    rescue_system.spawn_rescue_torch(position)

func clear_rescue_torch() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.clear_rescue_torch()

func spawn_rescue_hostiles() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.spawn_rescue_hostiles()

func start_rescue_escort() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.start_rescue_escort()

func refresh_rescue_progress(delta := -1.0) -> bool:
    if not ensure_rescue_system():
        return false
    return rescue_system.refresh_rescue_progress(delta)

func rescue_remaining_hostiles() -> int:
    if not ensure_rescue_system():
        return 0
    return rescue_system.rescue_remaining_hostiles()

func start_rescue_return() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.start_rescue_return()

func rescue_return_position() -> Vector3:
    if not ensure_rescue_system():
        return Vector3.ZERO
    return rescue_system.rescue_return_position()

func rescue_party_home() -> bool:
    if not ensure_rescue_system():
        return true
    return rescue_system.rescue_party_home()

func settle_rescue_party_home() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.settle_rescue_party_home()

func find_tutorial_npc(npc_id: String) -> Node3D:
    if not ensure_rescue_system():
        return null
    return rescue_system.find_tutorial_npc(npc_id)

func show_speech_bubble(npc_id: String, text: String, duration := 2.6) -> void:
    if not ensure_rescue_system():
        return
    rescue_system.show_speech_bubble(npc_id, text, duration)

func update_speech_bubbles(delta: float) -> void:
    if not ensure_rescue_system():
        return
    rescue_system.update_speech_bubbles(delta)

func clear_speech_bubbles() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.clear_speech_bubbles()

func current_tutorial_stage() -> String:
    if not ensure_dialogue_system():
        return "intro" if not intro_bed_used else "wilds"
    return dialogue_system.current_tutorial_stage()

func npc_allowed_for_current_stage(npc_id: String) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.npc_allowed_for_current_stage(npc_id)

func locked_line_for_stage(npc_id: String) -> String:
    if not ensure_dialogue_system():
        return ""
    return dialogue_system.locked_line_for_stage(npc_id)

func is_after_training_hours() -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.is_after_training_hours()

func inventory_count(item_id: String) -> int:
    if not ensure_dialogue_system():
        return 0
    return dialogue_system.inventory_count(item_id)

func structure_count(block_type: String) -> int:
    if not ensure_dialogue_system():
        return 0
    return dialogue_system.structure_count(block_type)

func has_weapon(totals: Dictionary) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.has_weapon(totals)

func has_axe(totals: Dictionary) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.has_axe(totals)

func has_pickaxe(totals: Dictionary) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.has_pickaxe(totals)

func danger_profile(position: Vector3) -> Dictionary:
    if not ensure_dialogue_system():
        return {}
    return dialogue_system.danger_profile(position)

func ensure_town_generated() -> void:
    scene_builder.ensure_town_generated()

func ensure_starter_bed() -> void:
    scene_builder.ensure_starter_bed()

func clear_overlapping_starter_beds(center_cell: Vector2i, level: float) -> void:
    scene_builder.clear_overlapping_starter_beds(center_cell, level)

func ensure_starter_shelter() -> void:
    scene_builder.ensure_starter_shelter()

func ensure_village_perimeter() -> void:
    scene_builder.ensure_village_perimeter()

func place_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary) -> void:
    scene_builder.place_perimeter_cell(cell_x, cell_z, level, gate_cells)

func ensure_village_lights() -> void:
    scene_builder.ensure_village_lights()

func place_player_in_starter_house() -> void:
    scene_builder.place_player_in_starter_house()

func force_stormy_night() -> void:
    scene_builder.force_stormy_night()

func spawn_tutorial_npcs() -> Dictionary:
    if startup_town_manifest.is_empty():
        var manifest_result: Dictionary = current_tutorial_manifest_result()
        if String(manifest_result.get("status", "")) != StartupReadinessResultScript.STATUS_READY:
            return {
                "ok": false,
                "reason": String(manifest_result.get("reason", "tutorial_town_manifest_not_ready")),
                "manifestResult": manifest_result
            }
        startup_town_manifest = (manifest_result.get("manifest", {}) as Dictionary).duplicate(true)
    var resolution: Dictionary = resolve_tutorial_actor_specs(startup_town_manifest)
    if not bool(resolution.get("ok", false)):
        return resolution
    startup_actor_specs = (resolution.get("specs", []) as Array).duplicate(true)
    return scene_builder.spawn_tutorial_npcs(startup_actor_specs)

func add_npc_visual(parent: Node3D, color: Color, accent: Color, npc_name: String, role: String) -> void:
    scene_builder.add_npc_visual(parent, color, accent, npc_name, role)

func add_warm_light(position: Vector3, radius: float, energy: float) -> void:
    scene_builder.add_warm_light(position, radius, energy)

func make_material(color: Color, roughness: float) -> StandardMaterial3D:
    return scene_builder.make_material(color, roughness)

func make_emissive_material(color: Color, energy: float) -> StandardMaterial3D:
    return scene_builder.make_emissive_material(color, energy)

func clear_scene() -> void:
    scene_builder.clear_scene()

func clear_npcs() -> void:
    scene_builder.clear_npcs()

func clear_lights() -> void:
    scene_builder.clear_lights()

func npc_count() -> int:
    return scene_builder.npc_count()
