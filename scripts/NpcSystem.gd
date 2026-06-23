extends Node3D
class_name NpcSystem

const NpcVisualFactoryScript := preload("res://scripts/NpcVisualFactory.gd")
const NpcPathingScript := preload("res://scripts/NpcPathing.gd")
const NpcCombatScript := preload("res://scripts/NpcCombat.gd")
const NpcProfileRulesScript := preload("res://scripts/NpcProfileRules.gd")
const NpcStatsScript := preload("res://scripts/NpcStats.gd")

const CELL := 1.35
const NO_DETOUR := Vector3(9999999.0, 9999999.0, 9999999.0)

var main
var hostile_system
var npc_root: Node3D
var npcs: Array = []
var npc_by_id := {}
var spawned_town_keys := {}
var guard_shots := 0
var guard_melee_strikes := 0
var door_opens := 0
var door_closes := 0
var job_runs_completed := 0
var last_message := ""
var focused_dialogue_body: Node = null
var npc_use_animations := 0
var npc_path_detours := 0
var npc_blocked_moves := 0
var npc_forage_runs := 0
var npc_food_eaten := 0
var pending_door_closes: Array = []
var visual_factory
var pathing
var combat
var components_initialized := false
var component_init_attempted := false

func setup(main_node, hostile_system_node) -> void:
    main = main_node
    hostile_system = hostile_system_node
    npc_root = Node3D.new()
    npc_root.name = "TownNPCs"
    add_child(npc_root)
    ensure_components()

func ensure_components() -> void:
    if components_initialized or component_init_attempted:
        return
    component_init_attempted = true
    if visual_factory == null:
        visual_factory = NpcVisualFactoryScript.new()
        visual_factory.setup(main)
    if pathing == null:
        pathing = NpcPathingScript.new()
        pathing.setup(self, main)
    if combat == null:
        combat = NpcCombatScript.new()
        combat.setup(self, hostile_system, visual_factory.arrow_material)
    components_initialized = visual_factory != null and pathing != null and combat != null

func clear() -> void:
    for entry in npcs:
        var body := entry.get("body") as Node
        if body and is_instance_valid(body) and bool(body.get_meta("npc_owned_by_system", false)):
            body.queue_free()
    npcs.clear()
    npc_by_id.clear()
    spawned_town_keys.clear()
    focused_dialogue_body = null
    pending_door_closes.clear()
    if combat:
        combat.clear()

func unregister_npc(body: Node) -> void:
    if body == null:
        return
    npc_by_id.erase(body.get_instance_id())
    if focused_dialogue_body == body:
        focused_dialogue_body = null
    for entry in npcs.duplicate():
        if entry.get("body") == body:
            npcs.erase(entry)

func focus_dialogue_npc(body: Node, player_position: Vector3) -> void:
    clear_dialogue_focus()
    if body == null or not is_instance_valid(body):
        return
    focused_dialogue_body = body
    body.set_meta("npc_dialogue_focused", true)
    body.set_meta("npc_dialogue_face_position", player_position)

func clear_dialogue_focus() -> void:
    if focused_dialogue_body != null and is_instance_valid(focused_dialogue_body):
        focused_dialogue_body.set_meta("npc_dialogue_focused", false)
    focused_dialogue_body = null

func set_scripted_target(body: Node, target: Vector3, allow_outside := true, hold_on_arrival := true) -> void:
    if body == null or not is_instance_valid(body):
        return
    body.set_meta("npc_scripted_target", target)
    body.set_meta("npc_scripted_allow_outside", allow_outside)
    body.set_meta("npc_scripted_hold_on_arrival", hold_on_arrival)
    body.set_meta("npc_scripted_arrived", false)

func clear_scripted_target(body: Node) -> void:
    if body == null or not is_instance_valid(body):
        return
    body.remove_meta("npc_scripted_target")
    body.set_meta("npc_scripted_arrived", false)

func register_npc(body: StaticBody3D, profile: Dictionary) -> Dictionary:
    if body == null:
        return {}
    ensure_components()
    unregister_npc(body)
    var home_cell: Vector2i = profile.get("homeCell", profile.get("cell", Vector2i.ZERO))
    var porch_cell: Vector2i = profile.get("porchCell", home_cell)
    var guard_cell: Vector2i = profile.get("guardCell", porch_cell)
    var level := float(profile.get("level", body.global_position.y))
    var role := String(profile.get("role", "Villager"))
    var can_fight := bool(profile.get("canFight", false))
    var job := String(profile.get("job", ""))
    if job == "":
        job = job_for_role(role, can_fight)
    var entry := {
        "body": body,
        "id": String(profile.get("id", body.name)),
        "name": String(profile.get("name", body.name)),
        "role": role,
        "townKey": String(profile.get("townKey", "")),
        "townCenter": profile.get("townCenter", Vector2i(roundi(body.global_position.x / CELL), roundi(body.global_position.z / CELL))),
        "townRadius": int(profile.get("townRadius", 18)),
        "level": level,
        "homeCell": home_cell,
        "porchCell": porch_cell,
        "guardCell": guard_cell,
        "homePosition": cell_to_position(home_cell, level),
        "porchPosition": cell_to_position(porch_cell, level),
        "guardPosition": cell_to_position(guard_cell, level),
        "homeRoutePositions": route_positions_from_profile(profile.get("homeRouteCells", []), level),
        "homeRouteIndex": 0,
        "canFight": can_fight,
        "nightGuard": bool(profile.get("nightGuard", false)),
        "weaponId": weapon_for_profile(profile, role, can_fight),
        "heldAnchor": null,
        "heldVisual": null,
        "useAnim": 0.0,
        "useAction": "",
        "useDuration": 0.0,
        "job": job,
        "jobResource": resource_for_job(job),
        "jobPhase": "idle",
        "jobTimer": randf_range(2.0, 6.0),
        "jobTarget": body.global_position,
        "jobTargetNode": null,
        "goal": "idle",
        "personalInventory": {},
        "hunger": randf_range(72.0, 96.0),
        "maxHunger": 100.0,
        "jobRuns": 0,
        "holdIntroDoor": bool(profile.get("holdIntroDoor", false)),
        "tutorial": bool(profile.get("tutorial", false)),
        "cooldown": randf_range(0.2, 1.2),
        "wanderTimer": randf_range(0.4, 1.6),
        "homeReturnTime": 0.0,
        "dayTarget": body.global_position,
        "insideHome": false,
        "lastMoveDistance": 0.0,
        "detourTarget": NO_DETOUR,
        "detourTimer": 0.0,
        "blockedMoveTime": 0.0,
        "pathWaypoints": [],
        "pathRefreshTimer": 0.0,
        "routeGoalCell": Vector2i(999999, 999999),
        "routeAllowOutside": false,
        "routeMovingHome": false,
        "jumpIntentTime": 0.0
    }
    apply_npc_metadata(body, entry, home_cell, porch_cell, guard_cell, job)
    ensure_npc_held_item(entry)
    npcs.append(entry)
    npc_by_id[body.get_instance_id()] = entry
    return entry

func apply_npc_metadata(body: Node, entry: Dictionary, home_cell: Vector2i, porch_cell: Vector2i, guard_cell: Vector2i, job: String) -> void:
    body.set_meta("npc_home_cell", home_cell)
    body.set_meta("npc_porch_cell", porch_cell)
    body.set_meta("npc_guard_cell", guard_cell)
    body.set_meta("npc_town_key", String(entry["townKey"]))
    body.set_meta("npc_can_fight", bool(entry["canFight"]))
    body.set_meta("npc_job", job)
    body.set_meta("npc_job_phase", "idle")
    body.set_meta("npc_goal", String(entry.get("goal", "idle")))
    body.set_meta("npc_hunger", float(entry.get("hunger", 100.0)))
    body.set_meta("npc_inventory", entry.get("personalInventory", {}))
    body.set_meta("npc_job_runs", 0)
    body.set_meta("npc_has_home", true)
    body.set_meta("npc_inside_home", false)
    body.set_meta("npc_weapon", String(entry["weaponId"]))

func route_positions_from_profile(route_cells_value, level: float) -> Array[Vector3]:
    var result: Array[Vector3] = []
    var route_cells: Array = route_cells_value if route_cells_value is Array else []
    for cell_value in route_cells:
        if cell_value is Vector2i:
            result.append(cell_to_position(cell_value, level))
        elif cell_value is Vector3:
            result.append(cell_value)
    return result

func weapon_for_profile(profile: Dictionary, role: String, can_fight: bool) -> String:
    return NpcProfileRulesScript.weapon_for_profile(profile, role, can_fight)

func job_for_role(role: String, can_fight: bool) -> String:
    return NpcProfileRulesScript.job_for_role(role, can_fight)

func resource_for_job(job: String) -> String:
    return NpcProfileRulesScript.resource_for_job(job)

func spawn_generic_town_npcs() -> void:
    if main == null or main.structure_system == null or not main.structure_system.has_method("town_home_records_snapshot"):
        return
    var records_by_town: Dictionary = main.structure_system.town_home_records_snapshot()
    var tutorial_key := tutorial_town_key()
    for town_key_variant in records_by_town.keys():
        var town_key := String(town_key_variant)
        if town_key == "" or spawned_town_keys.has(town_key):
            continue
        if tutorial_key != "" and town_key == tutorial_key:
            spawned_town_keys[town_key] = true
            continue
        var records: Array = records_by_town[town_key]
        for i in range(records.size()):
            spawn_town_npc(records[i], i)
        spawned_town_keys[town_key] = true

func tutorial_town_key() -> String:
    if main == null or main.tutorial_system == null or not main.tutorial_system.has_method("tutorial_town_key"):
        return ""
    return String(main.tutorial_system.tutorial_town_key())

func spawn_town_npc(record: Dictionary, index: int) -> StaticBody3D:
    ensure_components()
    var can_fight: bool = index == 0 or index % 4 == 3
    var roles := ["Farmer", "Carpenter", "Forager", "Mason", "Trader"]
    var names := ["Iven", "Mara", "Pell", "Ona", "Brin", "Tess", "Cal"]
    var role: String = "Guard" if can_fight else String(roles[index % roles.size()])
    var name: String = String(names[index % names.size()])
    var body := StaticBody3D.new()
    body.name = "TownNPC_%s_%d" % [String(record.get("townKey", "town")).replace(",", "_"), index]
    body.collision_layer = 4
    body.collision_mask = 0
    body.set_meta("kind", "npc")
    body.set_meta("npc_owned_by_system", true)
    body.set_meta("npc_name", name)
    body.set_meta("npc_role", role)
    var level := float(record.get("level", 16.0))
    var porch_cell: Vector2i = record.get("porchCell", record.get("homeCell", Vector2i.ZERO))
    body.position = cell_to_position(porch_cell, level)
    add_npc_visual(body, visual_factory.body_material(index), visual_factory.accent_material(index), name, role, can_fight)
    add_npc_collider(body)
    npc_root.add_child(body)
    register_npc(body, {
        "id": String(record.get("id", body.name)),
        "name": name,
        "role": role,
        "townKey": String(record.get("townKey", "")),
        "townCenter": record.get("townCenter", Vector2i.ZERO),
        "townRadius": int(record.get("townRadius", 18)),
        "level": level,
        "homeCell": record.get("homeCell", Vector2i.ZERO),
        "porchCell": porch_cell,
        "guardCell": record.get("guardCell", porch_cell),
        "canFight": can_fight,
        "nightGuard": can_fight
    })
    return body

func update_npcs(delta: float, day_factor: float) -> void:
    if main == null:
        return
    ensure_components()
    spawn_generic_town_npcs()
    if combat != null:
        combat.update_tracers(delta)
    update_pending_door_closes(delta)
    var night_factor := clampf((1.0 - day_factor - 0.30) / 0.55, 0.0, 1.0)
    for entry in npcs.duplicate():
        var body := entry.get("body") as StaticBody3D
        if body == null or not is_instance_valid(body):
            npcs.erase(entry)
            continue
        update_npc_visual_state(entry, delta)
        update_npc(entry, delta, night_factor)

func update_npc(entry: Dictionary, delta: float, night_factor: float) -> void:
    var body := entry.get("body") as StaticBody3D
    update_npc_needs(entry, delta, night_factor)
    if npc_is_held_by_intro_or_dialogue(entry, body):
        return
    if body.has_meta("npc_scripted_target"):
        update_scripted_npc(entry, body, delta)
        return
    var can_fight := bool(entry.get("canFight", false))
    var night_guard := bool(entry.get("nightGuard", false))
    var weapon_id := String(entry.get("weaponId", ""))
    var target_hostile := nearest_hostile(body.global_position, 42.0) if can_fight and night_factor > 0.22 else null
    entry["cooldown"] = maxf(0.0, float(entry.get("cooldown", 0.0)) - delta)

    var target: Vector3
    var moving_home := false
    var moving_job := false
    if night_factor > 0.45:
        if can_fight and (target_hostile != null or night_guard):
            target = update_fighter_target(entry, body, target_hostile, weapon_id)
        else:
            moving_home = true
            entry["homeReturnTime"] = float(entry.get("homeReturnTime", 0.0)) + delta
            target = home_route_target(entry)
    else:
        entry["homeReturnTime"] = 0.0
        entry["homeRouteIndex"] = 0
        entry["insideHome"] = false
        body.set_meta("npc_inside_home", false)
        if update_day_job(entry, delta):
            target = entry.get("jobTarget", body.global_position)
            moving_job = true
        else:
            target = update_wander_target(entry, body, delta)

    var speed := 2.3 if night_factor <= 0.45 else (6.4 if moving_home else 2.45)
    if moving_home and bool(entry.get("holdIntroDoor", false)):
        speed = 10.0
    var moved := move_npc(entry, target, speed * delta, moving_home, moving_job)
    entry["lastMoveDistance"] = moved
    if moved <= 0.001 and not moving_home:
        entry["wanderTimer"] = 0.0
        if moving_job and String(entry.get("job", "")) != "forage":
            entry["jobTarget"] = choose_job_target(entry)
    if moving_home:
        settle_home_if_reached(entry)
    face_hostile_if_needed(body, target_hostile)

func npc_is_held_by_intro_or_dialogue(entry: Dictionary, body: StaticBody3D) -> bool:
    if bool(entry.get("holdIntroDoor", false)) and main and main.tutorial_system:
        var waiting_for_door := not bool(main.tutorial_system.get("intro_door_opened"))
        var waiting_for_ack: bool = main.tutorial_system.has_method("is_intro_elder_waiting_for_ack") and bool(main.tutorial_system.is_intro_elder_waiting_for_ack())
        if waiting_for_door or waiting_for_ack:
            entry["insideHome"] = false
            body.set_meta("npc_inside_home", false)
            if main.player:
                face_position(body, main.player.global_position)
            return true
    if bool(body.get_meta("npc_dialogue_focused", false)):
        face_position(body, body.get_meta("npc_dialogue_face_position", body.global_position))
        entry["lastMoveDistance"] = 0.0
        return true
    if bool(body.get_meta("npc_force_hold", false)):
        if main.player:
            face_position(body, main.player.global_position)
        entry["lastMoveDistance"] = 0.0
        return true
    return false

func update_scripted_npc(entry: Dictionary, body: StaticBody3D, delta: float) -> void:
    var scripted_target: Vector3 = body.get_meta("npc_scripted_target", body.global_position)
    var allow_outside := bool(body.get_meta("npc_scripted_allow_outside", true))
    entry["lastMoveDistance"] = move_npc(entry, scripted_target, 3.05 * delta, false, allow_outside)
    if body.global_position.distance_to(scripted_target) <= CELL * 0.95:
        body.set_meta("npc_scripted_arrived", true)
        if not bool(body.get_meta("npc_scripted_hold_on_arrival", true)):
            clear_scripted_target(body)

func update_fighter_target(entry: Dictionary, body: StaticBody3D, target_hostile: Node3D, weapon_id: String) -> Vector3:
    entry["insideHome"] = false
    body.set_meta("npc_inside_home", false)
    var target: Vector3 = entry.get("guardPosition", body.global_position)
    if target_hostile == null:
        return target
    if npc_weapon_is_melee(weapon_id):
        var flat_distance := Vector2(target_hostile.global_position.x - body.global_position.x, target_hostile.global_position.z - body.global_position.z).length()
        if flat_distance <= CELL * 1.72:
            strike_hostile(entry, target_hostile)
        else:
            target = target_hostile.global_position
    else:
        fire_at_hostile(entry, target_hostile)
    return target

func update_wander_target(entry: Dictionary, body: StaticBody3D, delta: float) -> Vector3:
    var wander_timer := float(entry.get("wanderTimer", 0.0)) - delta
    var day_target: Vector3 = entry.get("dayTarget", body.global_position)
    if wander_timer <= 0.0 or body.global_position.distance_to(day_target) < CELL * 0.65 or not point_inside_town(entry, day_target):
        day_target = choose_day_target(entry)
        wander_timer = randf_range(3.0, 7.0)
    entry["wanderTimer"] = wander_timer
    entry["dayTarget"] = day_target
    return day_target

func face_hostile_if_needed(body: StaticBody3D, target_hostile: Node3D) -> void:
    if target_hostile == null or body.global_position.distance_to(target_hostile.global_position) <= 0.1:
        return
    var to_target := target_hostile.global_position - body.global_position
    to_target.y = 0.0
    if to_target.length_squared() > 0.001:
        body.rotation.y = atan2(to_target.x, to_target.z)

func update_npc_visual_state(entry: Dictionary, delta: float) -> void:
    entry["detourTimer"] = maxf(0.0, float(entry.get("detourTimer", 0.0)) - delta)
    if float(entry.get("detourTimer", 0.0)) <= 0.0:
        entry["detourTarget"] = NO_DETOUR
    entry["pathRefreshTimer"] = maxf(0.0, float(entry.get("pathRefreshTimer", 0.0)) - delta)
    entry["jumpIntentTime"] = maxf(0.0, float(entry.get("jumpIntentTime", 0.0)) - delta)
    var body := entry.get("body") as Node
    if body and float(entry.get("jumpIntentTime", 0.0)) <= 0.0:
        body.set_meta("npc_jump_intent", false)
    update_name_label_visibility(entry)
    visual_factory.update_held_animation(entry, delta)

func update_npc_needs(entry: Dictionary, delta: float, night_factor: float) -> void:
    var max_hunger := float(entry.get("maxHunger", 100.0))
    var drain := 0.020 if night_factor <= 0.45 else 0.010
    if String(entry.get("job", "")) == "forage":
        drain *= 1.35
    var hunger := clampf(float(entry.get("hunger", max_hunger)) - delta * drain, 0.0, max_hunger)
    entry["hunger"] = hunger
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_hunger", hunger)
    if hunger < max_hunger * 0.55 and npc_inventory_count(entry, "berries") > 0:
        npc_inventory_add(entry, "berries", -1)
        hunger = minf(max_hunger, hunger + 24.0)
        entry["hunger"] = hunger
        npc_food_eaten += 1
        if body:
            body.set_meta("npc_hunger", hunger)
        last_message = "%s ate berries" % String(entry.get("name", "NPC"))

func update_name_label_visibility(entry: Dictionary) -> void:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return
    var label := body.get_node_or_null("NpcNameLabel") as Label3D
    if label == null:
        return
    var show := bool(body.get_meta("npc_dialogue_focused", false))
    var player_body := main.get("player") as Node3D if main != null else null
    if player_body != null:
        var distance := body.global_position.distance_to(player_body.global_position)
        if distance <= CELL * 5.25:
            show = true
        elif npc_is_targeted_by_camera(body, player_body, distance):
            show = true
    label.visible = show
    label.no_depth_test = false

func npc_is_targeted_by_camera(body: Node3D, player_body: Node, distance: float) -> bool:
    if distance > CELL * 10.0 or player_body == null:
        return false
    var camera := player_body.get("camera") as Camera3D
    if camera == null:
        return false
    var to_label := (body.global_position + Vector3(0.0, 1.20, 0.0)) - camera.global_position
    if to_label.length_squared() <= 0.001:
        return true
    var forward := -camera.global_transform.basis.z.normalized()
    return forward.dot(to_label.normalized()) > 0.982

func play_npc_use(entry: Dictionary, action: String) -> void:
    entry["useAction"] = action
    entry["useDuration"] = 0.34 if action == "shoot" else 0.28
    entry["useAnim"] = float(entry["useDuration"])
    npc_use_animations += 1

func face_position(body: Node3D, target: Vector3) -> void:
    if body == null:
        return
    var to_target := target - body.global_position
    to_target.y = 0.0
    if to_target.length_squared() > 0.001:
        body.rotation.y = atan2(to_target.x, to_target.z)

func update_day_job(entry: Dictionary, delta: float) -> bool:
    var body := entry.get("body") as StaticBody3D
    if body == null:
        return false
    var job := String(entry.get("job", ""))
    if not (job in ["forage", "wood", "stone"]):
        return false
    if job == "forage":
        return update_forager_goal(entry, body, delta)
    var phase := String(entry.get("jobPhase", "idle"))
    var timer := float(entry.get("jobTimer", 0.0)) - delta
    if phase == "idle":
        if timer > 0.0:
            entry["jobTimer"] = timer
            body.set_meta("npc_job_phase", "idle")
            return false
        entry["jobPhase"] = "outbound"
        entry["jobTarget"] = choose_job_target(entry)
        set_npc_goal(entry, "gather %s" % String(entry.get("jobResource", "resource")))
        entry["jobTimer"] = randf_range(6.0, 12.0)
        body.set_meta("npc_job_phase", "outbound")
        return true
    if phase == "outbound":
        return update_outbound_job(entry, body, timer)
    if phase == "gathering":
        return update_gathering_job(entry, body, timer)
    if phase == "returning":
        return update_returning_job(entry, body, timer)
    entry["jobPhase"] = "idle"
    entry["jobTimer"] = randf_range(4.0, 9.0)
    body.set_meta("npc_job_phase", "idle")
    return false

func update_outbound_job(entry: Dictionary, body: StaticBody3D, timer: float) -> bool:
    var target: Vector3 = entry.get("jobTarget", body.global_position)
    var outside_town := not point_inside_town(entry, body.global_position)
    if body.global_position.distance_to(target) <= CELL * 1.1 or (timer <= 0.0 and outside_town):
        entry["jobPhase"] = "gathering"
        entry["jobTimer"] = randf_range(1.8, 3.5)
        body.set_meta("npc_job_phase", "gathering")
    elif timer <= 0.0:
        entry["jobTarget"] = choose_job_target(entry)
        entry["jobTimer"] = randf_range(4.0, 8.0)
    else:
        entry["jobTimer"] = timer
    return true

func update_gathering_job(entry: Dictionary, body: StaticBody3D, timer: float) -> bool:
    if timer > 0.0:
        entry["jobTimer"] = timer
        body.set_meta("npc_job_phase", "gathering")
        return true
    var runs := int(entry.get("jobRuns", 0)) + 1
    entry["jobRuns"] = runs
    job_runs_completed += 1
    entry["jobPhase"] = "returning"
    entry["jobTarget"] = entry.get("porchPosition", body.global_position)
    set_npc_goal(entry, "return home")
    entry["jobTimer"] = randf_range(8.0, 14.0)
    body.set_meta("npc_job_phase", "returning")
    body.set_meta("npc_job_runs", runs)
    body.set_meta("npc_carried_resource", String(entry.get("jobResource", "")))
    return true

func update_returning_job(entry: Dictionary, body: StaticBody3D, timer: float) -> bool:
    var porch: Vector3 = entry.get("porchPosition", body.global_position)
    if body.global_position.distance_to(porch) <= CELL * 1.0 or timer <= 0.0:
        entry["jobPhase"] = "idle"
        set_npc_goal(entry, "idle")
        entry["jobTimer"] = randf_range(8.0, 18.0)
        body.set_meta("npc_job_phase", "idle")
        body.set_meta("npc_carried_resource", "")
        return false
    entry["jobTarget"] = porch
    entry["jobTimer"] = timer
    body.set_meta("npc_job_phase", "returning")
    return true

func update_forager_goal(entry: Dictionary, body: StaticBody3D, delta: float) -> bool:
    var phase := String(entry.get("jobPhase", "idle"))
    var timer := float(entry.get("jobTimer", 0.0)) - delta
    if phase == "idle":
        var hungry := float(entry.get("hunger", 100.0)) < 82.0
        if timer > 0.0 and not hungry:
            entry["jobTimer"] = timer
            set_npc_goal(entry, "rest")
            body.set_meta("npc_job_phase", "idle")
            return false
        var forage := find_forage_target(entry)
        if forage == null:
            entry["jobPhase"] = "searching"
            entry["jobTimer"] = randf_range(3.0, 7.0)
            entry["jobTarget"] = choose_job_target(entry)
            set_npc_goal(entry, "search for berries")
            body.set_meta("npc_job_phase", "searching")
            return true
        entry["jobTargetNode"] = forage
        entry["jobTarget"] = forage.global_position
        entry["jobPhase"] = "outbound"
        entry["jobTimer"] = randf_range(12.0, 22.0)
        set_npc_goal(entry, "forage berries")
        body.set_meta("npc_job_phase", "outbound")
        return true
    if phase == "outbound" or phase == "searching":
        var target_value = entry.get("jobTargetNode")
        var target_node: Node3D = target_value if target_value is Node3D and is_instance_valid(target_value) else null
        if target_node != null:
            entry["jobTarget"] = target_node.global_position
        elif phase == "outbound":
            entry["jobTargetNode"] = null
            entry["jobPhase"] = "idle"
            entry["jobTimer"] = 0.0
            return true
        var target: Vector3 = entry.get("jobTarget", body.global_position)
        var outside_town := not point_inside_town(entry, body.global_position)
        var reached_target := body.global_position.distance_to(target) <= CELL * 1.15
        var timed_out_at_real_target := timer <= 0.0 and phase == "outbound" and target_node != null
        if reached_target or (phase == "searching" and outside_town) or timed_out_at_real_target:
            entry["jobPhase"] = "gathering"
            entry["jobTimer"] = randf_range(1.0, 1.8)
            set_npc_goal(entry, "pick berries")
            play_npc_use(entry, "gather")
            body.set_meta("npc_job_phase", "gathering")
        else:
            if timer <= 0.0:
                entry["jobTarget"] = choose_job_target(entry)
                timer = randf_range(3.0, 7.0)
            entry["jobTimer"] = timer
        return true
    if phase == "gathering":
        if timer > 0.0:
            entry["jobTimer"] = timer
            set_npc_goal(entry, "pick berries")
            body.set_meta("npc_job_phase", "gathering")
            return true
        harvest_forager_target(entry)
        var runs := int(entry.get("jobRuns", 0)) + 1
        entry["jobRuns"] = runs
        job_runs_completed += 1
        npc_forage_runs += 1
        entry["jobPhase"] = "returning"
        entry["jobTarget"] = entry.get("porchPosition", body.global_position)
        entry["jobTimer"] = randf_range(10.0, 18.0)
        set_npc_goal(entry, "bring berries home")
        body.set_meta("npc_job_phase", "returning")
        body.set_meta("npc_job_runs", runs)
        body.set_meta("npc_carried_resource", "berries")
        return true
    if phase == "returning":
        var porch: Vector3 = entry.get("porchPosition", body.global_position)
        if body.global_position.distance_to(porch) <= CELL * 1.0 or timer <= 0.0:
            entry["jobPhase"] = "idle"
            entry["jobTimer"] = randf_range(5.0, 12.0)
            set_npc_goal(entry, "rest")
            body.set_meta("npc_job_phase", "idle")
            body.set_meta("npc_carried_resource", "")
            return false
        entry["jobTarget"] = porch
        entry["jobTimer"] = timer
        set_npc_goal(entry, "bring berries home")
        body.set_meta("npc_job_phase", "returning")
        return true
    entry["jobPhase"] = "idle"
    entry["jobTimer"] = randf_range(3.0, 7.0)
    return false

func set_npc_goal(entry: Dictionary, goal: String) -> void:
    entry["goal"] = goal
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_goal", goal)

func npc_inventory_count(entry: Dictionary, item_id: String) -> int:
    var personal_inventory: Dictionary = entry.get("personalInventory", {})
    return int(personal_inventory.get(item_id, 0))

func npc_inventory_add(entry: Dictionary, item_id: String, amount: int) -> void:
    if item_id == "" or amount == 0:
        return
    var personal_inventory: Dictionary = entry.get("personalInventory", {})
    var new_count := maxi(0, int(personal_inventory.get(item_id, 0)) + amount)
    if new_count <= 0:
        personal_inventory.erase(item_id)
    else:
        personal_inventory[item_id] = new_count
    entry["personalInventory"] = personal_inventory
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_inventory", personal_inventory.duplicate())

func find_forage_target(entry: Dictionary) -> Node3D:
    var body := entry.get("body") as Node3D
    if body == null:
        return null
    var best: Node3D = null
    var best_distance := INF
    for root in [main.get("chunk_root"), main.get("prop_root")]:
        var found := find_forage_target_in_tree(root as Node, entry, body.global_position, best_distance)
        if found.get("node") is Node3D:
            best = found["node"]
            best_distance = float(found["distance"])
    return best

func find_forage_target_in_tree(root: Node, entry: Dictionary, origin: Vector3, best_distance: float) -> Dictionary:
    var best: Node3D = null
    var best_dist := best_distance
    if root == null:
        return { "node": best, "distance": best_dist }
    var stack: Array[Node] = [root]
    while not stack.is_empty():
        var node := stack.pop_back() as Node
        if node == null:
            continue
        if node is Node3D and is_valid_forage_node(node as Node3D, entry):
            var distance := (node as Node3D).global_position.distance_to(origin)
            if distance < best_dist:
                best = node as Node3D
                best_dist = distance
        for child in node.get_children():
            stack.append(child)
    return { "node": best, "distance": best_dist }

func is_valid_forage_node(node: Node3D, entry: Dictionary) -> bool:
    if not is_instance_valid(node) or bool(node.get_meta("npc_harvested", false)):
        return false
    if String(node.get_meta("kind", "")) != "prop":
        return false
    if String(node.get_meta("drop", "")) != "berries" and String(node.get_meta("material", "")) != "berryBush":
        return false
    if not point_inside_work_area(entry, node.global_position):
        return false
    var h: float = main.height_at_world(node.global_position.x, node.global_position.z)
    return h >= main.WATER_LEVEL + 0.45

func harvest_forager_target(entry: Dictionary) -> void:
    var target_value = entry.get("jobTargetNode")
    var target_node: Node3D = target_value if target_value is Node3D and is_instance_valid(target_value) else null
    var amount := 1
    if target_node != null:
        amount = max(1, int(target_node.get_meta("drop_count", 1)))
        target_node.set_meta("npc_harvested", true)
        var prop_id := String(target_node.get_meta("prop_id", ""))
        if prop_id != "" and main != null:
            var removed_props: Dictionary = main.get("removed_props")
            removed_props[prop_id] = true
        target_node.queue_free()
    npc_inventory_add(entry, "berries", amount)
    entry["jobTargetNode"] = null
    last_message = "%s gathered berries" % String(entry.get("name", "Forager"))

func home_route_target(entry: Dictionary) -> Vector3:
    var body := entry.get("body") as StaticBody3D
    var porch: Vector3 = entry.get("porchPosition", body.global_position)
    var home: Vector3 = entry.get("homePosition", body.global_position)
    if bool(entry.get("insideHome", false)):
        return home
    var route_positions: Array = entry.get("homeRoutePositions", [])
    var route_index := int(entry.get("homeRouteIndex", 0))
    while route_index < route_positions.size():
        var route_target: Vector3 = route_positions[route_index]
        if body.global_position.distance_to(route_target) > CELL * 0.82:
            entry["homeRouteIndex"] = route_index
            return route_target
        route_index += 1
    entry["homeRouteIndex"] = route_index
    return porch if body.global_position.distance_to(porch) > CELL * 0.82 else home

func settle_home_if_reached(entry: Dictionary) -> void:
    var body := entry.get("body") as StaticBody3D
    if body == null:
        return
    var porch: Vector3 = entry.get("porchPosition", body.global_position)
    var home: Vector3 = entry.get("homePosition", body.global_position)
    var near_home := body.global_position.distance_to(home) <= CELL * 4.8
    var timed_near := float(entry.get("homeReturnTime", 0.0)) > 5.6 and body.global_position.distance_to(home) <= CELL * 14.0
    var near_porch := body.global_position.distance_to(porch) <= CELL * 1.65 and body.global_position.distance_to(home) <= CELL * 5.2
    if near_home or timed_near or near_porch:
        body.global_position = home
        entry["insideHome"] = true
        entry["homeRouteIndex"] = int((entry.get("homeRoutePositions", []) as Array).size())
        body.set_meta("npc_inside_home", true)

func open_door_for_npc(collider: Node, npc_body: Node3D = null) -> void:
    if collider == null or main == null or not main.has_method("toggle_door"):
        return
    collider = main.interaction_block_from_collider(collider) if main.has_method("interaction_block_from_collider") else collider
    if bool(collider.get_meta("open", false)):
        schedule_door_close(collider, npc_body)
        return
    if bool(main.toggle_door(collider)):
        door_opens += 1
        schedule_door_close(collider, npc_body)
        last_message = "NPC opened a door"

func schedule_door_close(door: Node, npc_body: Node3D) -> void:
    if door == null or not is_instance_valid(door):
        return
    for pending in pending_door_closes:
        if pending.get("door") == door:
            pending["timer"] = 0.0
            pending["npc"] = npc_body
            return
    pending_door_closes.append({ "door": door, "npc": npc_body, "timer": 0.0 })

func update_pending_door_closes(delta: float) -> void:
    for pending in pending_door_closes.duplicate():
        var door := pending.get("door") as Node3D
        if door == null or not is_instance_valid(door):
            pending_door_closes.erase(pending)
            continue
        pending["timer"] = float(pending.get("timer", 0.0)) + delta
        var npc := pending.get("npc") as Node3D
        var npc_clear: bool = npc == null or not is_instance_valid(npc) or npc.global_position.distance_to(door.global_position) > CELL * 1.45
        var player_clear: bool = true
        if main != null and main.player != null:
            player_clear = main.player.global_position.distance_to(door.global_position) > CELL * 1.35
        var timed_out := float(pending.get("timer", 0.0)) > 4.5
        if bool(door.get_meta("open", false)) and npc_clear and (player_clear or timed_out):
            if bool(main.toggle_door(door)):
                door_closes += 1
                last_message = "NPC closed a door"
            pending_door_closes.erase(pending)
        elif not bool(door.get_meta("open", false)):
            pending_door_closes.erase(pending)

func move_npc(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false) -> float:
    var moved := 0.0
    if pathing == null:
        return fallback_move_npc(entry, target, max_distance, moving_home, allow_outside)
    moved = pathing.move_npc(entry, target, max_distance, moving_home, allow_outside)
    if moved <= 0.001 and max_distance > 0.0:
        moved = fallback_move_npc(entry, target, max_distance, moving_home, allow_outside)
    return moved

func fallback_move_npc(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false) -> float:
    var body := entry.get("body") as StaticBody3D
    if body == null or main == null or max_distance <= 0.0:
        return 0.0
    var previous := body.global_position
    var active_target := target
    var detour: Vector3 = entry.get("fallbackDetour", NO_DETOUR)
    if absf(detour.x) < 1000000.0:
        if previous.distance_to(detour) > CELL * 0.65:
            active_target = detour
        else:
            entry["fallbackDetour"] = NO_DETOUR
    elif fallback_route_blocked(previous, target):
        var chosen := choose_fallback_detour(entry, previous, target, moving_home, allow_outside)
        if absf(chosen.x) < 1000000.0:
            entry["fallbackDetour"] = chosen
            active_target = chosen
            npc_path_detours += 1
    var delta := active_target - previous
    delta.y = 0.0
    if delta.length_squared() < 0.001:
        return 0.0
    var step := delta.normalized() * minf(max_distance, delta.length())
    var candidate := previous + step
    if not fallback_candidate_allowed(entry, previous, candidate, moving_home, allow_outside):
        npc_blocked_moves += 1
        return 0.0
    var ground_y: float = main.height_at_world(candidate.x, candidate.z)
    candidate.y = ground_y + 0.04
    body.global_position = candidate
    body.rotation.y = atan2(step.x, step.z)
    return Vector2(candidate.x - previous.x, candidate.z - previous.z).length()

func fallback_route_blocked(previous: Vector3, target: Vector3) -> bool:
    var delta := target - previous
    delta.y = 0.0
    var distance := delta.length()
    if distance <= CELL * 1.5 or main == null:
        return false
    var samples := clampi(ceili(distance / (CELL * 0.5)), 2, 80)
    for i in range(1, samples):
        var probe := previous.lerp(target, float(i) / float(samples))
        if fallback_cell_blocked(Vector2i(roundi(probe.x / CELL), roundi(probe.z / CELL))):
            return true
    return false

func choose_fallback_detour(entry: Dictionary, previous: Vector3, target: Vector3, moving_home: bool, allow_outside: bool) -> Vector3:
    var forward := target - previous
    forward.y = 0.0
    if forward.length_squared() < 0.001:
        return NO_DETOUR
    forward = forward.normalized()
    var side := Vector3(-forward.z, 0.0, forward.x)
    for distance_value in [CELL * 2.4, CELL * 4.0, CELL * 5.6]:
        var distance: float = float(distance_value)
        for direction_value in [1.0, -1.0]:
            var direction: float = float(direction_value)
            var detour: Vector3 = previous + side * direction * distance + forward * CELL * 3.2
            if fallback_candidate_allowed(entry, previous, detour, moving_home, allow_outside):
                detour.y = main.height_at_world(detour.x, detour.z) + 0.04
                return detour
    return NO_DETOUR

func fallback_candidate_allowed(entry: Dictionary, previous: Vector3, candidate: Vector3, moving_home: bool, allow_outside: bool) -> bool:
    if allow_outside:
        if not point_inside_work_area(entry, candidate):
            return false
    elif not point_inside_town(entry, candidate):
        return false
    var ground_y: float = main.height_at_world(candidate.x, candidate.z)
    if ground_y < main.WATER_LEVEL + 0.45:
        return false
    var previous_y: float = main.height_at_world(previous.x, previous.z)
    if absf(ground_y - previous_y) > CELL * 0.9 and not moving_home:
        return false
    var cell: Vector2i = Vector2i(roundi(candidate.x / CELL), roundi(candidate.z / CELL))
    return not fallback_cell_blocked(cell)

func fallback_cell_blocked(cell: Vector2i) -> bool:
    if main == null:
        return false
    var blocks: Dictionary = main.get("blocks")
    for block in blocks.values():
        var body := block as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if block_type in ["cobblestonePath", "torch"]:
            continue
        var block_cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        if block_cell.x == cell.x and block_cell.z == cell.y:
            if block_type == "door":
                open_door_for_npc(body, null)
                return false
            return true
    return false

func choose_day_target(entry: Dictionary) -> Vector3:
    if pathing == null:
        return entry.get("porchPosition", Vector3.ZERO)
    return pathing.choose_day_target(entry)

func choose_job_target(entry: Dictionary) -> Vector3:
    if pathing == null:
        return entry.get("porchPosition", Vector3.ZERO)
    return pathing.choose_job_target(entry)

func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
    if pathing == null:
        var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
        var radius := float(entry.get("townRadius", 18)) * CELL
        var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
        return flat.length() <= radius
    return pathing.point_inside_town(entry, position)

func point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
    if pathing == null:
        var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
        var radius := (float(entry.get("townRadius", 18)) + 24.0) * CELL
        var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
        return flat.length() <= radius
    return pathing.point_inside_work_area(entry, position)

func nearest_hostile(origin: Vector3, radius: float) -> Node3D:
    if combat == null:
        return null
    return combat.nearest_hostile(origin, radius)

func fire_at_hostile(entry: Dictionary, target: Node3D) -> void:
    if combat == null:
        return
    combat.fire_at_hostile(entry, target)

func strike_hostile(entry: Dictionary, target: Node3D) -> void:
    if combat == null:
        return
    combat.strike_hostile(entry, target)

func npc_weapon_is_ranged(weapon_id: String) -> bool:
    return visual_factory.npc_weapon_is_ranged(weapon_id)

func npc_weapon_is_melee(weapon_id: String) -> bool:
    return visual_factory.npc_weapon_is_melee(weapon_id)

func ensure_npc_held_item(entry: Dictionary) -> void:
    visual_factory.ensure_held_item(entry)

func add_npc_collider(parent: StaticBody3D) -> void:
    visual_factory.add_collider(parent)

func add_npc_visual(parent: Node3D, body_material: StandardMaterial3D, accent_material: StandardMaterial3D, npc_name: String, role: String, can_fight := false) -> void:
    visual_factory.add_visual(parent, body_material, accent_material, npc_name, role)

func cell_to_position(cell: Vector2i, level: float) -> Vector3:
    return Vector3(float(cell.x) * CELL, level + 0.04, float(cell.y) * CELL)

func stats() -> Dictionary:
    return NpcStatsScript.build(self)
