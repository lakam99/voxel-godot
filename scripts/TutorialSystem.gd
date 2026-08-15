extends Node
class_name TutorialSystem

const TutorialSceneBuilderScript := preload("res://scripts/TutorialSceneBuilder.gd")
const TutorialRepairQuestScript := preload("res://scripts/TutorialRepairQuest.gd")
const TutorialRescueSystemScript := preload("res://scripts/TutorialRescueSystem.gd")
const TutorialDialogueSystemScript := preload("res://scripts/TutorialDialogueSystem.gd")
const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")
const StartupReadinessResultScript := preload("res://scripts/world/StartupReadinessResult.gd")
const TutorialTownSaveContractScript := preload("res://scripts/tutorial/TutorialTownSaveContract.gd")

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
const INTRO_KNOCK_ACTOR_ID := "mira"
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
var intro_knock_initial_order_result := {}
var intro_knock_home_order_result := {}
var restored_tutorial_save_contract := {}
var tutorial_save_restore_result := {}

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
    var village_light_metrics: Dictionary = await ensure_village_lights_staged()
    await loading_yield("Village lights ready", "tutorial_scene", "pending", village_light_metrics)
    await loading_yield("Preparing starter shelter", "tutorial_scene", "pending")
    var starter_shelter_metrics := ensure_starter_shelter()
    await loading_yield("Starter shelter terrain ready", "tutorial_scene", "pending", starter_shelter_metrics)
    var starter_bed_started_usec := Time.get_ticks_usec()
    ensure_starter_bed()
    starter_shelter_metrics["starterBedMs"] = float(Time.get_ticks_usec() - starter_bed_started_usec) / 1000.0
    await loading_yield("Tutorial scene ready", "tutorial_scene", "ready", starter_shelter_metrics)
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
    var population_claim: Dictionary = main.npc_system.claim_town_population(
        String(startup_town_manifest.get("townKey", "")),
        "tutorial_scenario"
    ) if main.npc_system.has_method("claim_town_population") else {"ok": false, "reason": "missing_town_population_claim_api"}
    if not bool(population_claim.get("ok", false)):
        return await fail_tutorial_startup(
            String(population_claim.get("reason", "tutorial_population_claim_failed")),
            startup_town_manifest,
            population_claim
        )
    var initial_orders := submit_initial_actor_orders(startup_actor_specs, restoring)
    if not bool(initial_orders.get("ok", false)):
        return await fail_tutorial_startup(
            "tutorial_initial_order_failed",
            startup_town_manifest,
            initial_orders
        )
    var save_restore := {}
    var rescue_restore := {}
    if restoring:
        save_restore = reconcile_restored_tutorial_save_contract()
        if not bool(save_restore.get("ok", false)):
            return await fail_tutorial_startup(
                "tutorial_save_order_restore_failed",
                startup_town_manifest,
                save_restore
            )
        await loading_yield("Tutorial save state restored", "tutorial_save", "ready", save_restore)
        if ensure_rescue_system():
            rescue_restore = await rescue_system.reconcile_after_world_ready()
            if not bool(rescue_restore.get("ok", false)):
                return await fail_tutorial_startup(
                    "tutorial_rescue_mission_restore_failed",
                    startup_town_manifest,
                    rescue_restore
                )
            await loading_yield("Rescue mission state restored", "tutorial_mission", "ready", rescue_restore)
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
        "actorSpawn": spawn_result.get("metrics", {}),
        "villageLights": village_light_metrics,
        "initialOrders": initial_orders,
        "saveRestore": save_restore,
        "rescueRestore": rescue_restore
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
                "job": ""
            },
            "spawn": {"kind": "offset", "offset": Vector2i(-13, -15)},
            "initialOrder": {
                "kind": "wait",
                "reason": "tutorial_knock_pending",
                "activeWhen": "intro_knock_unacknowledged"
            }
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
    intro_knock_initial_order_result.clear()
    intro_knock_home_order_result.clear()
    restored_tutorial_save_contract.clear()
    tutorial_save_restore_result.clear()

func submit_initial_actor_orders(specs: Array, restoring: bool) -> Dictionary:
    if main == null or main.npc_system == null:
        return {"ok": false, "reason": "missing_npc_order_authority", "submissions": []}
    var submissions: Array[Dictionary] = []
    var problems: Array[String] = []
    for spec_value in specs:
        if not (spec_value is Dictionary):
            continue
        var spec: Dictionary = spec_value
        var order_value = spec.get("initialOrder", {})
        if not (order_value is Dictionary) or (order_value as Dictionary).is_empty():
            continue
        var order: Dictionary = order_value
        var active_when := String(order.get("activeWhen", "always"))
        if active_when == "intro_knock_unacknowledged" and (not intro_repair_active or intro_elder_dialogue_acknowledged):
            continue
        if restoring and active_when == "new_game_only":
            continue
        var actor_id := String(spec.get("id", ""))
        var kind := String(order.get("kind", ""))
        var reason := String(order.get("reason", "tutorial_initial_order"))
        var result: Dictionary = {}
        match kind:
            "wait":
                result = main.npc_system.order_wait(actor_id, reason)
            "go_home":
                result = main.npc_system.order_go_home(actor_id, reason)
            _:
                problems.append("actor %s has unsupported initial order %s" % [actor_id, kind])
                continue
        var summary := npc_order_state_summary(result)
        summary["actorId"] = actor_id
        submissions.append(summary)
        if actor_id == INTRO_KNOCK_ACTOR_ID and kind == "wait":
            intro_knock_initial_order_result = result.duplicate(true)
        if String(result.get("state", "")).begins_with("FAILED"):
            problems.append("actor %s initial order failed: %s" % [actor_id, String(result.get("failureReason", result.get("reason", "unknown")))])
    return {
        "ok": problems.is_empty(),
        "reason": "" if problems.is_empty() else "initial_order_submission_failed",
        "submissions": submissions,
        "problems": problems
    }

func npc_order_state_summary(order_value) -> Dictionary:
    if not (order_value is Dictionary):
        return {}
    var order: Dictionary = order_value
    return {
        "id": String(order.get("id", "")),
        "kind": String(order.get("kind", "")),
        "state": String(order.get("state", "")),
        "reason": String(order.get("reason", "")),
        "failureReason": String(order.get("failureReason", "")),
        "speedMode": String(order.get("speedMode", "")),
        "usesRouteStack": bool(order.get("usesRouteStack", false))
    }

func fallback_intro_knock_intent() -> Dictionary:
    if not started or not intro_repair_active or intro_bed_used:
        return {
            "kind": TutorialTownSaveContractScript.INTENT_RESUME_SCHEDULE,
            "reason": "resume_schedule"
        }
    if not intro_elder_dialogue_acknowledged:
        return {
            "kind": TutorialTownSaveContractScript.INTENT_WAIT,
            "reason": "tutorial_knock_pending"
        }
    return {
        "kind": TutorialTownSaveContractScript.INTENT_GO_HOME,
        "reason": "tutorial_knock_complete"
    }

func intro_knock_intent_for_snapshot() -> Dictionary:
    var fallback := fallback_intro_knock_intent()
    if String(fallback.get("kind", "")) != TutorialTownSaveContractScript.INTENT_GO_HOME:
        return fallback
    if main == null or main.npc_system == null:
        return fallback
    var entry: Dictionary = main.npc_system.npc_entry_for_actor(INTRO_KNOCK_ACTOR_ID)
    if entry.is_empty():
        return fallback
    if main.npc_system.has_method("settle_home_if_reached"):
        main.npc_system.settle_home_if_reached(entry)
    if bool(entry.get("insideHome", false)):
        return {
            "kind": TutorialTownSaveContractScript.INTENT_RESUME_SCHEDULE,
            "reason": "resume_schedule"
        }
    return fallback

func tutorial_save_contract_snapshot() -> Dictionary:
    var manifest: Dictionary = startup_town_manifest.duplicate(true)
    return TutorialTownSaveContractScript.build(
        manifest,
        startup_actor_specs,
        intro_knock_intent_for_snapshot()
    )

func reconcile_restored_tutorial_save_contract() -> Dictionary:
    if main == null or main.npc_system == null:
        tutorial_save_restore_result = {
            "ok": false,
            "reason": "missing_npc_order_authority"
        }
        return tutorial_save_restore_result.duplicate(true)
    var contract: Dictionary = restored_tutorial_save_contract if not restored_tutorial_save_contract.is_empty() else TutorialTownSaveContractScript.normalize({}, fallback_intro_knock_intent())
    var manifest_validation := TutorialTownSaveContractScript.validate_manifest_reference(
        contract.get("manifestReference", {}),
        startup_town_manifest,
        startup_actor_specs
    )
    var entry: Dictionary = main.npc_system.npc_entry_for_actor(INTRO_KNOCK_ACTOR_ID)
    if entry.is_empty():
        tutorial_save_restore_result = {
            "ok": false,
            "reason": "missing_intro_knock_actor",
            "manifestValidation": manifest_validation
        }
        return tutorial_save_restore_result.duplicate(true)
    if main.npc_system.has_method("settle_home_if_reached"):
        main.npc_system.settle_home_if_reached(entry)
    var saved_fact := {}
    if main.npc_system.has_method("saved_npc_fact"):
        saved_fact = main.npc_system.saved_npc_fact(INTRO_KNOCK_ACTOR_ID)
    var assignment_validation := TutorialTownSaveContractScript.validate_saved_assignment(saved_fact, entry)
    var desired: Dictionary = TutorialTownSaveContractScript.normalize_intro_intent(
        contract.get("introKnockIntent", {}),
        fallback_intro_knock_intent()
    )
    if String(desired.get("kind", "")) == TutorialTownSaveContractScript.INTENT_GO_HOME and bool(entry.get("insideHome", false)):
        desired = {
            "kind": TutorialTownSaveContractScript.INTENT_RESUME_SCHEDULE,
            "reason": "resume_schedule"
        }
    var active: Dictionary = main.npc_system.scripted_order_status(INTRO_KNOCK_ACTOR_ID)
    var action := "retained"
    var order_result: Dictionary = active.duplicate(true)
    var kind := String(desired.get("kind", ""))
    var reason := String(desired.get("reason", ""))
    if kind == TutorialTownSaveContractScript.INTENT_WAIT:
        if not intro_knock_order_matches(active, kind, reason):
            action = "submitted"
            order_result = main.npc_system.order_wait(INTRO_KNOCK_ACTOR_ID, reason)
        intro_knock_initial_order_result = order_result.duplicate(true)
    elif kind == TutorialTownSaveContractScript.INTENT_GO_HOME:
        if not intro_knock_order_matches(active, kind, reason):
            action = "submitted"
            order_result = main.npc_system.order_go_home(INTRO_KNOCK_ACTOR_ID, reason)
        intro_knock_home_order_result = order_result.duplicate(true)
    else:
        if intro_knock_order_is_active(active):
            action = "resumed_schedule"
            order_result = main.npc_system.order_resume_schedule(INTRO_KNOCK_ACTOR_ID)
        else:
            order_result = {
                "kind": TutorialTownSaveContractScript.INTENT_RESUME_SCHEDULE,
                "state": "RETAINED",
                "reason": "resume_schedule"
            }
        intro_knock_home_order_result = order_result.duplicate(true)
    var order_failed := String(order_result.get("state", "")).begins_with("FAILED")
    tutorial_save_restore_result = {
        "ok": not order_failed,
        "reason": "" if not order_failed else String(order_result.get("failureReason", order_result.get("reason", "order_restore_failed"))),
        "contractMigration": String(contract.get("migration", "")),
        "manifestValidation": manifest_validation,
        "assignmentValidation": assignment_validation,
        "desiredIntent": desired,
        "action": action,
        "order": npc_order_state_summary(order_result)
    }
    return tutorial_save_restore_result.duplicate(true)

func intro_knock_order_matches(order_value, kind: String, reason: String) -> bool:
    if not (order_value is Dictionary):
        return false
    var order: Dictionary = order_value
    var state := String(order.get("state", ""))
    if not state in ["PENDING", "ACTIVE"]:
        return false
    if String(order.get("kind", "")) != kind:
        return false
    var submission_reason := String(order.get("submissionReason", order.get("reason", "")))
    return submission_reason == reason

func intro_knock_order_is_active(order_value) -> bool:
    if not (order_value is Dictionary):
        return false
    var order: Dictionary = order_value
    var state := String(order.get("state", ""))
    if not state in ["PENDING", "ACTIVE"]:
        return false
    var reason := String(order.get("submissionReason", order.get("reason", "")))
    return reason in ["tutorial_knock_pending", "tutorial_knock_complete"]

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
    if ensure_rescue_system():
        rescue_system.restore(state.get("finalRescueMission", {}))
    restored_tutorial_save_contract = TutorialTownSaveContractScript.normalize(
        state.get("saveContract", {}),
        fallback_intro_knock_intent()
    )
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
    var spawn_result: Dictionary = spawn_tutorial_npcs(true)
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
        "finalRescueMission": rescue_system.snapshot() if ensure_rescue_system() else {},
        "saveContract": tutorial_save_contract_snapshot(),
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
        "introKnockOrders": {
            "initial": npc_order_state_summary(intro_knock_initial_order_result),
            "home": npc_order_state_summary(intro_knock_home_order_result)
        },
        "tutorialSaveRestore": tutorial_save_restore_result.duplicate(true),
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
        "finalRescueMission": rescue_system.mission_state() if ensure_rescue_system() else {},
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
    resume_knock_actor_schedule()
    complete_step("introFirstSleep")
    last_message = "You slept through the storm. Dawn breaks over the repaired village."
    last_dialogue.clear()
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()

func should_freeze_intro_night() -> bool:
    return (started and intro_repair_active and not intro_bed_used) or (final_night_active and not final_night_complete)

func should_loop_intro_knock() -> bool:
    return started and intro_repair_active and not intro_door_opened and intro_knock_scene_is_present()

func intro_knock_scene_is_present() -> bool:
    if main == null or not is_instance_valid(main) or not main.is_inside_tree():
        return false
    var tree: SceneTree = main.get_tree()
    if tree == null:
        return false
    if tree.current_scene == main:
        return true
    var parent: Node = main.get_parent()
    return parent != null and tree.current_scene == parent and parent.get("active_main") == main

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
        if main == null or main.npc_system == null:
            intro_knock_home_order_result = {
                "kind": "go_home",
                "state": "FAILED_TARGET_GONE",
                "reason": "tutorial_knock_complete",
                "failureReason": "missing_npc_order_authority"
            }
        else:
            var actor = dialogue_actor_reference()
            intro_knock_home_order_result = main.npc_system.order_go_home(actor, "tutorial_knock_complete")
            if String(intro_knock_home_order_result.get("state", "")).begins_with("FAILED"):
                last_message = "The speaker is no longer in reach."
    var close_action := String(state.get("closeAction", ""))
    if close_action == "" and state_npc_id != "" and state_npc_id == current_npc_id:
        close_action = String(last_dialogue.get("closeAction", ""))
    clear_dialogue_focus()
    if close_action != "" and ensure_rescue_system():
        var result: Dictionary = await rescue_system.handle_dialogue_close_action(close_action)
        if not bool(result.get("ok", false)):
            last_message = "The rescue could not begin: %s" % String(result.get("reason", "unknown_error"))

func dialogue_payload() -> Dictionary:
    return last_dialogue.duplicate(true)

func dialogue_actor_reference():
    if last_dialogue_node != null and is_instance_valid(last_dialogue_node):
        return last_dialogue_node
    var npc_id := String(last_dialogue.get("npcId", ""))
    if npc_id != "":
        return npc_id
    return null

func resume_knock_actor_schedule() -> void:
    if main == null or main.npc_system == null or not main.npc_system.has_method("order_resume_schedule"):
        return
    main.npc_system.order_resume_schedule(INTRO_KNOCK_ACTOR_ID)

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
    return await rescue_system.start_final_night()

func begin_final_night_briefing() -> bool:
    if not ensure_rescue_system():
        return false
    return rescue_system.begin_final_night_briefing()

func dialogue_close_action_for(npc_id: String) -> String:
    if not ensure_rescue_system():
        return ""
    return rescue_system.dialogue_close_action_for(npc_id)

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

func ensure_starter_shelter() -> Dictionary:
    return scene_builder.ensure_starter_shelter()

func ensure_village_perimeter() -> void:
    scene_builder.ensure_village_perimeter()

func place_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary) -> void:
    scene_builder.place_perimeter_cell(cell_x, cell_z, level, gate_cells)

func ensure_village_lights() -> Dictionary:
    return scene_builder.ensure_village_lights()

func ensure_village_lights_staged() -> Dictionary:
    return await scene_builder.ensure_village_lights_staged()

func place_player_in_starter_house() -> void:
    scene_builder.place_player_in_starter_house()

func force_stormy_night() -> void:
    scene_builder.force_stormy_night()

func spawn_tutorial_npcs(restoring := false) -> Dictionary:
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
    var spawn_result: Dictionary = scene_builder.spawn_tutorial_npcs(startup_actor_specs)
    if not bool(spawn_result.get("ok", false)):
        return spawn_result
    var initial_orders := submit_initial_actor_orders(startup_actor_specs, restoring)
    if not bool(initial_orders.get("ok", false)):
        return initial_orders
    spawn_result["initialOrders"] = initial_orders
    if restoring:
        var save_restore := reconcile_restored_tutorial_save_contract()
        if not bool(save_restore.get("ok", false)):
            return {
                "ok": false,
                "reason": "tutorial_save_order_restore_failed",
                "saveRestore": save_restore
            }
        spawn_result["saveRestore"] = save_restore
    return spawn_result

func add_npc_visual(parent: Node3D, color: Color, accent: Color, npc_name: String, role: String) -> void:
    scene_builder.add_npc_visual(parent, color, accent, npc_name, role)

func add_warm_light(position: Vector3, radius: float, energy: float, foundation_y := NAN) -> void:
    scene_builder.add_warm_light(position, radius, energy, foundation_y)

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
