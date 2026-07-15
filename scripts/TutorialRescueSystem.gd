extends RefCounted
class_name TutorialRescueSystem

const CELL := 1.35
const LocalLightRigScript := preload("res://scripts/LocalLightRig.gd")
const MissionActorRunnerScript := preload("res://scripts/missions/MissionActorRunner.gd")
const MissionEncounterRunnerScript := preload("res://scripts/missions/MissionEncounterRunner.gd")
const MissionSceneReadinessRunnerScript := preload("res://scripts/missions/MissionSceneReadinessRunner.gd")
const MissionTransitionRunnerScript := preload("res://scripts/missions/MissionTransitionRunner.gd")
const FENCE_RADIUS_CELLS := 25
const RESCUE_MONSTER_COUNT := 6
const RESCUE_BATTLE_ACTIVATION_RADIUS := CELL * 10.0
const RESCUE_ENCOUNTER_LEASH_RADIUS := CELL * 12.0
const RESCUE_ELDER_ID := "mira"
const RESCUE_GUARD_ID := "sera"
const RESCUE_FORAGER_ID := "niko"
const ENCOUNTER_ID := "tutorial_final_rescue"
const PHASE_DORMANT := "dormant"
const PHASE_BRIEFING := "briefing"
const PHASE_PREPARING := "preparing"
const PHASE_READY := "ready_at_gate"
const PHASE_ESCORTING := "escorting"
const PHASE_BATTLE := "battle"
const PHASE_RETURNING := "returning"
const PHASE_COMPLETE := "complete"
const CLOSE_ACTION_PREPARE := "prepare_final_rescue"
const CLOSE_ACTION_ESCORT := "start_final_rescue_escort"
const PREPARATION_TIMEOUT_SECONDS := 12.0

var system
var main
var transition_runner
var phase := PHASE_DORMANT
var gate_portal_id := ""
var guard_target := Vector3.ZERO
var remaining_slot_ids: Array[String] = []
var last_preparation_result := {}
var last_return_orders := {}
var last_failure := ""
var preparing := false

func setup(tutorial_system) -> void:
    system = tutorial_system
    main = system.main
    transition_runner = MissionTransitionRunnerScript.new()
    transition_runner.setup(main)

func surface_y_at_position(position: Vector3) -> float:
    if main != null and main.has_method("surface_y_at_position"):
        return float(main.call("surface_y_at_position", position))
    return position.y

func begin_final_night_briefing() -> bool:
    if system.final_night_active or system.final_night_complete or preparing:
        return false
    if phase == PHASE_DORMANT:
        phase = PHASE_BRIEFING
    return phase == PHASE_BRIEFING

func dialogue_close_action_for(npc_id: String) -> String:
    if npc_id == RESCUE_ELDER_ID and phase == PHASE_BRIEFING and not system.final_night_active:
        return CLOSE_ACTION_PREPARE
    if npc_id == RESCUE_GUARD_ID and phase == PHASE_READY and system.final_night_active and not system.rescue_escort_started:
        return CLOSE_ACTION_ESCORT
    return ""

func handle_dialogue_close_action(action: String) -> Dictionary:
    if action == CLOSE_ACTION_PREPARE:
        return await prepare_final_rescue(true)
    if action == CLOSE_ACTION_ESCORT:
        return start_rescue_escort_result()
    return {"ok": true, "action": "none", "phase": phase}

func start_final_night() -> bool:
    if not begin_final_night_briefing():
        return false
    var result: Dictionary = await prepare_final_rescue(true)
    return bool(result.get("ok", false))

func prepare_final_rescue(show_transition := true, restored_slots: Array[String] = []) -> Dictionary:
    if preparing:
        return {"ok": false, "reason": "preparation_already_active", "phase": phase}
    if main == null or main.npc_system == null or main.hostile_system == null or system.town.is_empty():
        return await fail_preparation("missing_mission_authority", show_transition)
    preparing = true
    phase = PHASE_PREPARING
    if show_transition:
        await transition_runner.begin("Preparing the rescue")
    var started_usec := Time.get_ticks_usec()
    var scene_result := {}
    while true:
        scene_result = rescue_scene_readiness()
        if bool(scene_result.get("ok", false)):
            break
        if float(Time.get_ticks_usec() - started_usec) / 1000000.0 >= PREPARATION_TIMEOUT_SECONDS:
            return await fail_preparation(String(scene_result.get("reason", "rescue_scene_readiness_timeout")), show_transition, scene_result)
        if show_transition:
            await transition_runner.pulse("Publishing rescue terrain")
        elif system.get_tree() != null:
            await system.get_tree().process_frame
    gate_portal_id = String(scene_result.get("portalId", ""))
    system.rescue_site = scene_result.get("site", Vector3.ZERO)
    guard_target = scene_result.get("guardTarget", Vector3.ZERO)
    if show_transition:
        await transition_runner.pulse("Staging the rescue party")
    var forager_result := MissionActorRunnerScript.stage_and_wait(main.npc_system, RESCUE_FORAGER_ID, system.rescue_site, "final_rescue_staged_wait")
    var guard_result := MissionActorRunnerScript.stage_and_wait(main.npc_system, RESCUE_GUARD_ID, rescue_guard_return_position(), "final_rescue_gate_wait")
    if not bool(forager_result.get("ok", false)) or not bool(guard_result.get("ok", false)):
        return await fail_preparation("mission_actor_staging_failed", show_transition, {
            "forager": forager_result,
            "guard": guard_result
        })
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    if forager != null:
        forager.set_meta("npc_hostile_target_immune", true)
        forager.set_meta("hostile_target_immune", true)
    clear_rescue_torch()
    spawn_rescue_torch(system.rescue_site)
    if system.rescue_torch == null or not is_instance_valid(system.rescue_torch):
        return await fail_preparation("rescue_torch_staging_failed", show_transition)
    if show_transition:
        await transition_runner.pulse("Gathering the shadows")
    MissionEncounterRunnerScript.clear(main.hostile_system, ENCOUNTER_ID, false)
    var slots := restored_slots.duplicate() if not restored_slots.is_empty() else all_slot_ids()
    var encounter_result := spawn_rescue_hostiles_for_slots(slots)
    if not bool(encounter_result.get("ok", false)):
        return await fail_preparation(String(encounter_result.get("reason", "rescue_encounter_staging_failed")), show_transition, encounter_result)
    system.rescue_hostiles = MissionEncounterRunnerScript.bodies(main.hostile_system, ENCOUNTER_ID)
    remaining_slot_ids = MissionEncounterRunnerScript.slot_ids(main.hostile_system, ENCOUNTER_ID)
    var validation := validate_prepared_scene(slots)
    if not bool(validation.get("ok", false)):
        return await fail_preparation(String(validation.get("reason", "prepared_scene_validation_failed")), show_transition, validation)
    commit_prepared_scene()
    last_preparation_result = {
        "ok": true,
        "phase": phase,
        "portalId": gate_portal_id,
        "site": system.rescue_site,
        "guardTarget": guard_target,
        "slots": remaining_slot_ids.duplicate(),
        "readiness": scene_result,
        "validation": validation,
        "elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0
    }
    preparing = false
    if show_transition:
        await transition_runner.finish()
    show_speech_bubble(RESCUE_FORAGER_ID, "Help!", 3.8)
    return last_preparation_result.duplicate(true)

func fail_preparation(reason: String, show_transition: bool, details := {}) -> Dictionary:
    last_failure = reason
    rollback_prepared_scene()
    phase = PHASE_BRIEFING
    preparing = false
    last_preparation_result = {
        "ok": false,
        "reason": reason,
        "phase": phase,
        "details": details.duplicate(true) if details is Dictionary else {}
    }
    system.last_message = "The rescue scene could not be prepared: %s" % reason
    if show_transition and transition_runner != null and transition_runner.active:
        await transition_runner.finish()
    return last_preparation_result.duplicate(true)

func rollback_prepared_scene() -> void:
    if main != null and main.hostile_system != null:
        MissionEncounterRunnerScript.clear(main.hostile_system, ENCOUNTER_ID, false)
    system.rescue_hostiles.clear()
    remaining_slot_ids.clear()
    clear_rescue_torch()
    if main != null and main.npc_system != null:
        MissionActorRunnerScript.resume(main.npc_system, RESCUE_FORAGER_ID)
        MissionActorRunnerScript.resume(main.npc_system, RESCUE_GUARD_ID)
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    if forager != null:
        forager.set_meta("npc_hostile_target_immune", false)
        forager.set_meta("hostile_target_immune", false)

func commit_prepared_scene() -> void:
    system.final_night_active = true
    system.final_night_complete = false
    system.final_night_defeats_start = current_hostile_defeats()
    system.rescue_escort_started = false
    system.rescue_returning = false
    system.rescue_return_elapsed = 0.0
    phase = PHASE_READY
    system.complete_step("finalNightStarted")
    main.time_of_day = 0.86
    if main.weather_system != null and main.player != null:
        main.weather_system.force_weather("rain", 0.58, 0.76, main.player.global_position)
    main.hostile_system.spawn_cooldown = maxf(float(main.hostile_system.get("spawn_cooldown")), 8.0)
    send_elder_home_after_rescue_briefing()
    if main.has_method("update_sky"):
        main.update_sky(0.0)

func complete_final_night() -> bool:
    if system.final_night_complete:
        return false
    system.final_night_active = false
    system.final_night_complete = true
    system.rescue_returning = false
    system.rescue_escort_started = true
    phase = PHASE_COMPLETE
    system.complete_step("finalNightComplete")
    system.complete_step("miraBlessing")
    system.last_message = "Niko is safe inside the lanterns. Dawn can come now."
    system.last_dialogue.clear()
    if main:
        var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
        var guard := find_tutorial_npc(RESCUE_GUARD_ID)
        if forager:
            forager.set_meta("npc_hostile_target_immune", false)
            forager.set_meta("hostile_target_immune", false)
        if main.npc_system:
            MissionActorRunnerScript.cancel(main.npc_system, RESCUE_FORAGER_ID, "rescue_complete")
            MissionActorRunnerScript.cancel(main.npc_system, RESCUE_GUARD_ID, "rescue_complete")
        if main.hostile_system:
            MissionEncounterRunnerScript.clear(main.hostile_system, ENCOUNTER_ID, false)
        if main.has_method("emit_story_event"):
            var event_position: Vector3 = main.player.global_position if main.player else rescue_return_position()
            var cell := Vector2i(main.world_to_cell(event_position.x), main.world_to_cell(event_position.z))
            main.emit_story_event("tutorial_final_rescue_complete", "tutorial:final_rescue", main.story_region_id_for_cell(cell), "tutorial:final_rescue_complete", event_position, {
                "rescuedNpcId": RESCUE_FORAGER_ID,
                "guardNpcId": RESCUE_GUARD_ID,
                "tutorialStep": "finalNightComplete"
            })
    clear_rescue_torch()
    remaining_slot_ids.clear()
    return true

func final_night_defeats() -> int:
    if not system.final_night_active and not system.final_night_complete:
        return 0
    if system.final_night_complete:
        return RESCUE_MONSTER_COUNT
    return max(0, RESCUE_MONSTER_COUNT - rescue_remaining_hostiles())

func current_hostile_defeats() -> int:
    if main == null or main.hostile_system == null:
        return 0
    return int(main.hostile_system.stats().get("defeated", 0))

func all_slot_ids() -> Array[String]:
    var result: Array[String] = []
    for index in range(RESCUE_MONSTER_COUNT):
        result.append("ring_%02d" % index)
    return result

func rescue_scene_readiness() -> Dictionary:
    var site := choose_rescue_site()
    if not site.is_finite() or site == Vector3.ZERO:
        return {"ok": false, "reason": "no_rescue_site_candidate"}
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var expected_gate := Vector3(float(center_x + FENCE_RADIUS_CELLS) * CELL, site.y, float(center_z) * CELL)
    var gate_result := MissionSceneReadinessRunnerScript.public_gate_near(main, expected_gate, CELL * 4.0)
    if not bool(gate_result.get("ok", false)):
        return gate_result
    var outward := Vector3(site.x - float(center_x) * CELL, 0.0, site.z - float(center_z) * CELL).normalized()
    if outward.length_squared() < 0.5:
        outward = Vector3.RIGHT
    var escort_target := site - outward * CELL * 6.0
    escort_target.y = surface_y_at_position(escort_target) + 0.04
    var probes: Array = [site, escort_target, gate_result.get("position", expected_gate)]
    for index in range(RESCUE_MONSTER_COUNT):
        var angle := TAU * float(index) / float(RESCUE_MONSTER_COUNT)
        var radius := CELL * (3.7 + 0.35 * float(index % 2))
        var ring_position := site + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
        ring_position.y = surface_y_at_position(ring_position) + 0.04
        probes.append(ring_position)
    var terrain_result := MissionSceneReadinessRunnerScript.terrain_collision_proof(main, probes, 0.38)
    if not bool(terrain_result.get("ok", false)):
        return terrain_result
    return {
        "ok": true,
        "reason": "",
        "site": site,
        "guardTarget": escort_target,
        "portalId": String(gate_result.get("portalId", "")),
        "gate": gate_result,
        "terrain": terrain_result
    }

func validate_prepared_scene(expected_slots: Array[String]) -> Dictionary:
    var bodies := MissionEncounterRunnerScript.bodies(main.hostile_system, ENCOUNTER_ID)
    var actual_slots := MissionEncounterRunnerScript.slot_ids(main.hostile_system, ENCOUNTER_ID)
    var sorted_expected := expected_slots.duplicate()
    sorted_expected.sort()
    if bodies.size() != sorted_expected.size() or actual_slots != sorted_expected:
        return {
            "ok": false,
            "reason": "encounter_slot_manifest_incomplete",
            "expectedSlots": sorted_expected,
            "actualSlots": actual_slots,
            "bodyCount": bodies.size()
        }
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    if forager == null or Vector2(forager.global_position.x - system.rescue_site.x, forager.global_position.z - system.rescue_site.z).length() > CELL * 0.9:
        return {"ok": false, "reason": "forager_not_staged_at_rescue_site"}
    for body_value in bodies:
        var body := body_value as Node
        var enemy: Dictionary = main.hostile_system.enemy_for_body(body) if body != null else {}
        if String(enemy.get("scriptedPhase", "")) != "circle_niko" or bool(enemy.get("damageable", true)) or bool(enemy.get("canAttack", true)):
            return {"ok": false, "reason": "encounter_not_passive", "slotId": String(enemy.get("scriptedSlotId", ""))}
    var guard_order := MissionActorRunnerScript.status(main.npc_system, RESCUE_GUARD_ID)
    var forager_order := MissionActorRunnerScript.status(main.npc_system, RESCUE_FORAGER_ID)
    if String(guard_order.get("kind", "")) != "wait" or String(forager_order.get("kind", "")) != "wait":
        return {"ok": false, "reason": "staged_wait_order_not_retained", "guardOrder": guard_order, "foragerOrder": forager_order}
    return {"ok": true, "slots": actual_slots, "guardOrder": guard_order, "foragerOrder": forager_order}

func setup_rescue_scene() -> void:
    if phase == PHASE_BRIEFING and not preparing:
        prepare_final_rescue(false)

func choose_rescue_site() -> Vector3:
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var preferred_offsets: Array[Vector2i] = [
        Vector2i(FENCE_RADIUS_CELLS + 13, 0),
        Vector2i(FENCE_RADIUS_CELLS + 14, 3),
        Vector2i(FENCE_RADIUS_CELLS + 14, -3),
        Vector2i(FENCE_RADIUS_CELLS + 12, 6),
        Vector2i(FENCE_RADIUS_CELLS + 12, -6),
        Vector2i(FENCE_RADIUS_CELLS + 16, 0)
    ]
    for offset in preferred_offsets:
        var preferred := Vector3(float(center_x + offset.x) * CELL, 0.0, float(center_z + offset.y) * CELL)
        preferred.y = surface_y_at_position(preferred) + 0.06
        if rescue_encounter_site_clear(preferred):
            return preferred
    var base_angle := -0.55
    var radius := float(FENCE_RADIUS_CELLS + 13) * CELL
    for attempt in range(12):
        var angle := base_angle + float(attempt) * 0.28
        var position := Vector3(float(center_x) * CELL + cos(angle) * radius, 0.0, float(center_z) * CELL + sin(angle) * radius)
        position.y = surface_y_at_position(position) + 0.06
        if rescue_encounter_site_clear(position):
            return position
    var fallback := Vector3(float(center_x + FENCE_RADIUS_CELLS + 10) * CELL, 0.0, float(center_z + 4) * CELL)
    fallback.y = surface_y_at_position(fallback) + 0.06
    return fallback if rescue_encounter_site_clear(fallback) else Vector3.INF

func rescue_encounter_site_clear(position: Vector3) -> bool:
    if main == null:
        return true
    var town_center_position := Vector3(float(int(system.town.get("centerX", 0))) * CELL, 0.0, float(int(system.town.get("centerZ", 0))) * CELL)
    var town_level := float(system.town.get("level", surface_y_at_position(town_center_position)))
    var ground_y: float = surface_y_at_position(position)
    if ground_y < main.WATER_LEVEL + 0.8:
        return false
    if absf(ground_y - town_level) > CELL * 2.0:
        return false
    if rescue_root_has_near_prop(main.get("prop_root") as Node, position, CELL * CELL * 14.0):
        return false
    for i in range(RESCUE_MONSTER_COUNT):
        var angle := TAU * float(i) / float(RESCUE_MONSTER_COUNT)
        var ring_radius := CELL * (3.7 + 0.35 * float(i % 2))
        var ring_position := position + Vector3(cos(angle) * ring_radius, 0.0, sin(angle) * ring_radius)
        var ring_ground_y: float = surface_y_at_position(ring_position)
        if ring_ground_y < main.WATER_LEVEL + 0.8:
            return false
        if absf(ring_ground_y - town_level) > CELL * 2.4:
            return false
        if rescue_root_has_near_prop(main.get("prop_root") as Node, ring_position, CELL * CELL * 3.0):
            return false
    return true

func spawn_rescue_torch(position: Vector3) -> void:
    if system.light_root == null:
        return
    var root := Node3D.new()
    root.name = "RescueTorch"
    root.position = position + Vector3(0.0, 0.04, 0.0)
    var pole_mesh := CylinderMesh.new()
    pole_mesh.top_radius = 0.045
    pole_mesh.bottom_radius = 0.06
    pole_mesh.height = 0.92
    pole_mesh.radial_segments = 6
    var pole := MeshInstance3D.new()
    pole.mesh = pole_mesh
    pole.material_override = system.make_material(Color(0.30, 0.16, 0.08), 0.72)
    pole.position.y = 0.46
    root.add_child(pole)
    var flame_mesh := SphereMesh.new()
    flame_mesh.radius = 0.18
    flame_mesh.height = 0.26
    flame_mesh.radial_segments = 8
    flame_mesh.rings = 4
    var flame := MeshInstance3D.new()
    flame.mesh = flame_mesh
    flame.material_override = system.make_emissive_material(Color(1.0, 0.73, 0.42), 1.35)
    flame.position.y = 1.02
    root.add_child(flame)
    var cast_shadows := main != null and bool(main.get("shadows_enabled"))
    LocalLightRigScript.add_rig(root, "rescue_torch", {
        "context": "placed",
        "scale": CELL,
        "source_position": Vector3(0.0, 1.02, 0.0),
        "terrain_position": Vector3(0.0, CELL * 0.36, 0.0),
        "bounce_position": Vector3(0.0, CELL * 0.96, 0.0),
        "source_energy": 1.85,
        "source_range": CELL * 9.0,
        "terrain_energy": 1.35,
        "terrain_range": CELL * 8.6,
        "bounce_energy": 0.65,
        "bounce_range": CELL * 10.0,
        "shadows": cast_shadows,
        "day_suppressed": true
    })
    system.light_root.add_child(root)
    system.rescue_torch = root

func clear_rescue_torch() -> void:
    if system.rescue_torch != null and is_instance_valid(system.rescue_torch):
        system.rescue_torch.queue_free()
    system.rescue_torch = null

func spawn_rescue_hostiles() -> void:
    if main == null or main.hostile_system == null:
        return
    MissionEncounterRunnerScript.clear(main.hostile_system, ENCOUNTER_ID, false)
    spawn_rescue_hostiles_for_slots(all_slot_ids())
    system.rescue_hostiles = MissionEncounterRunnerScript.bodies(main.hostile_system, ENCOUNTER_ID)
    remaining_slot_ids = MissionEncounterRunnerScript.slot_ids(main.hostile_system, ENCOUNTER_ID)

func spawn_rescue_hostiles_for_slots(slots: Array[String]) -> Dictionary:
    if main == null or main.hostile_system == null:
        return {"ok": false, "reason": "missing_hostile_authority"}
    var specs: Array = []
    for slot_id in slots:
        var index := slot_index(String(slot_id))
        if index < 0 or index >= RESCUE_MONSTER_COUNT:
            return {"ok": false, "reason": "invalid_rescue_slot", "slotId": String(slot_id)}
        var angle := TAU * float(index) / float(RESCUE_MONSTER_COUNT)
        var radius := CELL * (3.7 + 0.35 * float(index % 2))
        var position: Vector3 = system.rescue_site + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
        position.y = surface_y_at_position(position) + 0.72
        specs.append({
            "slotId": String(slot_id),
            "position": position,
            "variant": "seer" if index == RESCUE_MONSTER_COUNT - 1 else "shadow",
            "phase": "circle_niko",
            "options": {
                "targetName": "Niko",
                "targetNpcId": RESCUE_FORAGER_ID,
                "targetNpcIds": [RESCUE_GUARD_ID],
                "targetPlayer": true,
                "battleSourceNpcId": RESCUE_GUARD_ID,
                "battleSourceRequiresAnchor": true,
                "battleSourceRadius": RESCUE_BATTLE_ACTIVATION_RADIUS,
                "leashAnchor": system.rescue_site,
                "leashRadius": RESCUE_ENCOUNTER_LEASH_RADIUS,
                "leashReleaseRadius": CELL * 8.0,
                "playerCanStartBattle": false,
                "exclusiveWorldSpawns": true,
                "damageable": false,
                "canAttack": false,
                "frenzy": true,
                "circleAnchor": system.rescue_site,
                "circleRadius": radius,
                "circleIndex": index,
                "circleCount": RESCUE_MONSTER_COUNT,
                "circleAngularSpeed": 0.17,
                "circlePhase": 0.0
            }
        })
    var result := MissionEncounterRunnerScript.spawn(main.hostile_system, ENCOUNTER_ID, specs)
    return result

func slot_index(slot_id: String) -> int:
    if not slot_id.begins_with("ring_"):
        return -1
    return int(slot_id.trim_prefix("ring_"))

func start_rescue_escort() -> void:
    start_rescue_escort_result()

func start_rescue_escort_result() -> Dictionary:
    if system.rescue_escort_started:
        return {"ok": true, "retained": true, "phase": phase}
    if phase != PHASE_READY or guard_target == Vector3.ZERO:
        return {"ok": false, "reason": "rescue_scene_not_ready", "phase": phase}
    var result := MissionActorRunnerScript.go_to(main.npc_system, RESCUE_GUARD_ID, guard_target, "rescue_escort_to_niko", CELL * 1.2, "sprinting", true)
    if not bool(result.get("ok", false)):
        last_failure = String(result.get("reason", "rescue_escort_order_failed"))
        return result
    system.rescue_escort_started = true
    phase = PHASE_ESCORTING
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if guard != null:
        guard.set_meta("npc_dialogue_focused", false)
    show_speech_bubble(RESCUE_GUARD_ID, "With me!", 2.5)
    show_speech_bubble(RESCUE_FORAGER_ID, "Over here!", 3.2)
    result["phase"] = phase
    return result

func rescue_guard_target(guard: Node3D) -> Vector3:
    if guard_target.is_finite() and guard_target != Vector3.ZERO:
        return guard_target
    var fallback: Vector3 = system.rescue_site + Vector3(-CELL * 6.0, 0.0, 0.0)
    fallback.y = surface_y_at_position(fallback) + 0.04
    return fallback

func rescue_root_has_near_prop(root: Node, position: Vector3, radius_sq: float) -> bool:
    if root == null:
        return false
    var stack: Array[Node] = [root]
    var scanned := 0
    while not stack.is_empty() and scanned < 400:
        scanned += 1
        var node := stack.pop_back() as Node
        if node == null:
            continue
        if node is Node3D and String(node.get_meta("kind", "")) == "prop":
            var prop := node as Node3D
            if Vector2(prop.global_position.x - position.x, prop.global_position.z - position.z).length_squared() <= radius_sq:
                return true
        for child in node.get_children():
            stack.append(child)
    return false

func refresh_rescue_progress(delta := -1.0) -> bool:
    if not system.final_night_active or system.final_night_complete:
        return false
    if phase == PHASE_ESCORTING:
        var guard := find_tutorial_npc(RESCUE_GUARD_ID)
        if guard != null:
            var flat_distance := Vector2(guard.global_position.x - system.rescue_site.x, guard.global_position.z - system.rescue_site.z).length()
            # The generic collision-backed route may normalize the semantic
            # approach goal to the nearest standable endpoint. Keep the mission
            # trigger aligned with the encounter's declared source radius so a
            # valid ARRIVED result cannot leave the passive swarm deadlocked.
            if flat_distance <= RESCUE_BATTLE_ACTIVATION_RADIUS:
                MissionEncounterRunnerScript.begin_battle(main.hostile_system, ENCOUNTER_ID, guard, "npc_mission_activation")
                phase = PHASE_BATTLE
    remaining_slot_ids = MissionEncounterRunnerScript.slot_ids(main.hostile_system, ENCOUNTER_ID)
    if phase == PHASE_BATTLE and not system.rescue_returning and rescue_remaining_hostiles() <= 0:
        start_rescue_return()
        return true
    if system.rescue_returning:
        system.rescue_return_elapsed += delta if delta >= 0.0 else system.get_process_delta_time()
        if rescue_party_home():
            return complete_final_night()
    return false

func rescue_remaining_hostiles() -> int:
    if main == null or main.hostile_system == null:
        return 0
    system.rescue_hostiles = MissionEncounterRunnerScript.bodies(main.hostile_system, ENCOUNTER_ID)
    return system.rescue_hostiles.size()

func start_rescue_return() -> void:
    system.rescue_returning = true
    system.rescue_return_elapsed = 0.0
    phase = PHASE_RETURNING
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    last_return_orders = {}
    if forager:
        if main and main.npc_system:
            last_return_orders["forager"] = MissionActorRunnerScript.result_summary(
                MissionActorRunnerScript.go_home(main.npc_system, RESCUE_FORAGER_ID, "rescue_return_home", "sprinting")
            )
    if guard and main and main.npc_system:
        last_return_orders["guard"] = MissionActorRunnerScript.result_summary(
            MissionActorRunnerScript.go_to(main.npc_system, RESCUE_GUARD_ID, rescue_guard_return_position(), "rescue_return_guard_post", CELL * 0.72, "walking")
        )
    show_speech_bubble(RESCUE_FORAGER_ID, "I can move!", 2.8)
    show_speech_bubble(RESCUE_GUARD_ID, "Back to town!", 2.8)

func rescue_return_position() -> Vector3:
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    return Vector3(float(center_x + FENCE_RADIUS_CELLS - 5) * CELL, level + 0.04, float(center_z) * CELL)

func rescue_guard_return_position() -> Vector3:
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if guard != null and main != null and main.npc_system != null and main.npc_system.has_method("npc_entry_for_actor"):
        var entry: Dictionary = main.npc_system.npc_entry_for_actor(guard)
        if not entry.is_empty():
            var guard_position: Vector3 = entry.get("guardPosition", Vector3.INF)
            if guard_position.is_finite():
                guard_position.y = surface_y_at_position(guard_position) + 0.04
                return guard_position
            var guard_cell: Vector2i = entry.get("guardCell", Vector2i.ZERO)
            var level := float(entry.get("level", 16.0))
            var cell_target := Vector3(float(guard_cell.x) * CELL, level + 0.04, float(guard_cell.y) * CELL)
            cell_target.y = surface_y_at_position(cell_target) + 0.04
            return cell_target
    var target := rescue_return_position() + Vector3(CELL * 0.65, 0.0, CELL * 0.65)
    if main != null:
        target.y = surface_y_at_position(target) + 0.04
    return target

func send_elder_home_after_rescue_briefing() -> void:
    if main == null or main.npc_system == null or not main.npc_system.has_method("order_go_home"):
        return
    var elder := find_tutorial_npc(RESCUE_ELDER_ID)
    if elder == null:
        return
    main.npc_system.order_go_home(elder, "final_rescue_briefing_return_home", "walking")

func rescue_party_home() -> bool:
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    var forager_home := true if forager == null else tutorial_npc_strictly_inside_home(forager)
    if not forager_home:
        return false
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if guard == null:
        return true
    return rescue_guard_returned(guard)

func rescue_guard_returned(guard: Node3D) -> bool:
    if guard == null:
        return true
    if rescue_guard_route_arrived(guard):
        return true
    var target := rescue_guard_return_position()
    var flat := Vector2(guard.global_position.x - target.x, guard.global_position.z - target.z)
    return flat.length() <= CELL * 1.45

func rescue_guard_route_arrived(guard: Node3D) -> bool:
    if guard == null or main == null or main.npc_system == null:
        return false
    if not main.npc_system.has_method("npc_entry_for_actor"):
        return false
    var entry: Dictionary = main.npc_system.npc_entry_for_actor(guard)
    if entry.is_empty():
        return false
    var scripted_order: Dictionary = entry.get("scriptedOrder", {}) if entry.get("scriptedOrder", {}) is Dictionary else {}
    if String(scripted_order.get("kind", "")) != "go_to":
        return false
    if String(scripted_order.get("state", "")) != "ARRIVED":
        return false
    var ordered_target: Vector3 = scripted_order.get("target", Vector3.INF)
    if not ordered_target.is_finite():
        return false
    var return_target := rescue_guard_return_position()
    var ordered_flat := Vector2(ordered_target.x - return_target.x, ordered_target.z - return_target.z)
    if ordered_flat.length() > CELL * 0.35:
        return false
    var authority: Dictionary = entry.get("routeAuthorityV2", {}) if entry.get("routeAuthorityV2", {}) is Dictionary else {}
    var proof: Dictionary = authority.get("proof", {}) if authority.get("proof", {}) is Dictionary else {}
    var authority_arrived := String(authority.get("state", "")) == "arrived" or String(entry.get("routeStatus", "")) == "arrived"
    return authority_arrived and bool(proof.get("ok", false)) and bool(proof.get("collisionBacked", false))

func snapshot() -> Dictionary:
    if main != null and main.hostile_system != null and system.final_night_active:
        remaining_slot_ids = MissionEncounterRunnerScript.slot_ids(main.hostile_system, ENCOUNTER_ID)
    return {
        "version": 1,
        "phase": phase,
        "gatePortalId": gate_portal_id,
        "site": vector_snapshot(system.rescue_site),
        "guardTarget": vector_snapshot(guard_target),
        "remainingSlots": remaining_slot_ids.duplicate(),
        "lastFailure": last_failure
    }

func restore(snapshot_value = {}) -> void:
    var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    phase = String(state.get("phase", ""))
    gate_portal_id = String(state.get("gatePortalId", ""))
    system.rescue_site = vector_from_snapshot(state.get("site", []), system.rescue_site)
    guard_target = vector_from_snapshot(state.get("guardTarget", []), Vector3.ZERO)
    remaining_slot_ids.clear()
    var slots_value = state.get("remainingSlots", [])
    if slots_value is Array:
        for slot_value in slots_value:
            var slot_id := String(slot_value)
            if slot_index(slot_id) >= 0 and not remaining_slot_ids.has(slot_id):
                remaining_slot_ids.append(slot_id)
    last_failure = String(state.get("lastFailure", ""))
    if phase == "":
        if system.final_night_complete:
            phase = PHASE_COMPLETE
        elif system.rescue_returning:
            phase = PHASE_RETURNING
        elif system.rescue_escort_started:
            phase = PHASE_ESCORTING
        elif system.final_night_active:
            phase = PHASE_READY
        else:
            phase = PHASE_DORMANT
    if system.final_night_active and phase in [PHASE_READY, PHASE_ESCORTING, PHASE_BATTLE] and not state.has("remainingSlots"):
        remaining_slot_ids = all_slot_ids()

func reconcile_after_world_ready() -> Dictionary:
    if system.final_night_complete or phase == PHASE_COMPLETE:
        phase = PHASE_COMPLETE
        rollback_completed_runtime_artifacts()
        return {"ok": true, "phase": phase, "action": "complete_retained"}
    if not system.final_night_active:
        if phase == PHASE_PREPARING:
            phase = PHASE_BRIEFING
        return {"ok": true, "phase": phase, "action": "inactive_retained"}
    if phase == PHASE_RETURNING or system.rescue_returning:
        phase = PHASE_RETURNING
        MissionEncounterRunnerScript.clear(main.hostile_system, ENCOUNTER_ID, false)
        clear_rescue_torch()
        start_rescue_return()
        return {"ok": true, "phase": phase, "action": "return_orders_restored"}
    var desired_phase := phase
    var slots := remaining_slot_ids.duplicate()
    if slots.is_empty() and desired_phase == PHASE_BATTLE:
        start_rescue_return()
        return {"ok": true, "phase": phase, "action": "empty_battle_advanced_to_return"}
    if slots.is_empty():
        slots = all_slot_ids()
    phase = PHASE_BRIEFING
    var preparation: Dictionary = await prepare_final_rescue(false, slots)
    if not bool(preparation.get("ok", false)):
        return preparation
    if desired_phase in [PHASE_ESCORTING, PHASE_BATTLE]:
        var escort_result := start_rescue_escort_result()
        if not bool(escort_result.get("ok", false)):
            return escort_result
    if desired_phase == PHASE_BATTLE:
        var guard := find_tutorial_npc(RESCUE_GUARD_ID)
        MissionEncounterRunnerScript.begin_battle(main.hostile_system, ENCOUNTER_ID, guard, "mission_restore")
        phase = PHASE_BATTLE
    return {"ok": true, "phase": phase, "action": "active_scene_reconciled", "preparation": preparation}

func rollback_completed_runtime_artifacts() -> void:
    if main != null and main.hostile_system != null:
        MissionEncounterRunnerScript.clear(main.hostile_system, ENCOUNTER_ID, false)
    clear_rescue_torch()
    system.rescue_hostiles.clear()
    remaining_slot_ids.clear()

func mission_state() -> Dictionary:
    return {
        "phase": phase,
        "preparing": preparing,
        "gatePortalId": gate_portal_id,
        "guardTarget": guard_target,
        "remainingSlots": remaining_slot_ids.duplicate(),
        "lastFailure": last_failure,
        "lastPreparation": preparation_state_summary(),
        "lastReturnOrders": last_return_orders.duplicate(true)
    }

func preparation_state_summary() -> Dictionary:
    if last_preparation_result.is_empty():
        return {}
    var readiness: Dictionary = last_preparation_result.get("readiness", {}) if last_preparation_result.get("readiness", {}) is Dictionary else {}
    var validation: Dictionary = last_preparation_result.get("validation", {}) if last_preparation_result.get("validation", {}) is Dictionary else {}
    var details: Dictionary = last_preparation_result.get("details", {}) if last_preparation_result.get("details", {}) is Dictionary else {}
    return {
        "ok": bool(last_preparation_result.get("ok", false)),
        "reason": String(last_preparation_result.get("reason", "")),
        "phase": String(last_preparation_result.get("phase", "")),
        "portalId": String(last_preparation_result.get("portalId", gate_portal_id)),
        "site": last_preparation_result.get("site", system.rescue_site),
        "guardTarget": last_preparation_result.get("guardTarget", guard_target),
        "slots": (last_preparation_result.get("slots", []) as Array).duplicate() if last_preparation_result.get("slots", []) is Array else [],
        "elapsedMs": float(last_preparation_result.get("elapsedMs", 0.0)),
        "readiness": {
            "ok": bool(readiness.get("ok", false)),
            "reason": String(readiness.get("reason", "")),
            "portalId": String(readiness.get("portalId", ""))
        } if not readiness.is_empty() else {},
        "validation": {
            "ok": bool(validation.get("ok", false)),
            "reason": String(validation.get("reason", "")),
            "slots": (validation.get("slots", []) as Array).duplicate() if validation.get("slots", []) is Array else []
        } if not validation.is_empty() else {},
        "failureDetails": {
            "reason": String(details.get("reason", "")),
            "state": String(details.get("state", details.get("status", "")))
        } if not details.is_empty() else {}
    }

func vector_snapshot(value: Vector3) -> Array:
    return [value.x, value.y, value.z]

func vector_from_snapshot(value, fallback: Vector3) -> Vector3:
    if value is Array and value.size() >= 3:
        return Vector3(float(value[0]), float(value[1]), float(value[2]))
    return fallback

func tutorial_npc_strictly_inside_home(body: Node3D) -> bool:
    if body == null or main == null or main.npc_system == null:
        return false
    return bool(MissionActorRunnerScript.home_status(main.npc_system, body).get("strictInside", false))

func find_tutorial_npc(npc_id: String) -> Node3D:
    if system.npc_root == null:
        return null
    for child in system.npc_root.get_children():
        var body := child as Node3D
        if body != null and String(body.get_meta("npc_id", "")) == npc_id:
            return body
    return null

func show_speech_bubble(npc_id: String, text: String, duration := 2.6) -> void:
    var npc := find_tutorial_npc(npc_id)
    if npc == null:
        return
    var existing := npc.get_node_or_null("SpeechBubble")
    if existing:
        existing.queue_free()
    var label := Label3D.new()
    label.name = "SpeechBubble"
    label.text = text
    label.font_size = 34
    label.position.y = 2.34
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    label.modulate = Color(1.0, 0.96, 0.78, 1.0)
    npc.add_child(label)
    system.speech_bubbles.append({ "node": label, "life": duration, "duration": duration })

func update_speech_bubbles(delta: float) -> void:
    for bubble in system.speech_bubbles.duplicate():
        var node_value = bubble.get("node")
        if not is_instance_valid(node_value):
            system.speech_bubbles.erase(bubble)
            continue
        var node := node_value as Label3D
        if node == null:
            system.speech_bubbles.erase(bubble)
            continue
        var life := float(bubble.get("life", 0.0)) - delta
        bubble["life"] = life
        var duration := maxf(0.1, float(bubble.get("duration", 1.0)))
        node.modulate.a = clampf(life / duration, 0.0, 1.0)
        if life <= 0.0:
            system.speech_bubbles.erase(bubble)
            node.queue_free()

func clear_speech_bubbles() -> void:
    for bubble in system.speech_bubbles:
        var node_value = bubble.get("node")
        if is_instance_valid(node_value):
            var node := node_value as Node
            if node != null:
                node.queue_free()
    system.speech_bubbles.clear()
