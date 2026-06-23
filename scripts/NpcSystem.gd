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
var job_runs_completed := 0
var last_message := ""
var focused_dialogue_body: Node = null
var npc_use_animations := 0
var npc_path_detours := 0
var npc_blocked_moves := 0
var visual_factory
var pathing
var combat

func setup(main_node, hostile_system_node) -> void:
    main = main_node
    hostile_system = hostile_system_node
    npc_root = Node3D.new()
    npc_root.name = "TownNPCs"
    add_child(npc_root)
    visual_factory = NpcVisualFactoryScript.new()
    visual_factory.setup(main)
    pathing = NpcPathingScript.new()
    pathing.setup(self, main)
    combat = NpcCombatScript.new()
    combat.setup(self, hostile_system, visual_factory.arrow_material)

func clear() -> void:
    for entry in npcs:
        var body := entry.get("body") as Node
        if body and is_instance_valid(body) and bool(body.get_meta("npc_owned_by_system", false)):
            body.queue_free()
    npcs.clear()
    npc_by_id.clear()
    spawned_town_keys.clear()
    focused_dialogue_body = null
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
        "pathRefreshTimer": 0.0
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
    var can_fight: bool = index == 0 or index % 3 == 2
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
    spawn_generic_town_npcs()
    combat.update_tracers(delta)
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
        if moving_job:
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
    visual_factory.update_held_animation(entry, delta)

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
    var phase := String(entry.get("jobPhase", "idle"))
    var timer := float(entry.get("jobTimer", 0.0)) - delta
    if phase == "idle":
        if timer > 0.0:
            entry["jobTimer"] = timer
            body.set_meta("npc_job_phase", "idle")
            return false
        entry["jobPhase"] = "outbound"
        entry["jobTarget"] = choose_job_target(entry)
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
    entry["jobTimer"] = randf_range(8.0, 14.0)
    body.set_meta("npc_job_phase", "returning")
    body.set_meta("npc_job_runs", runs)
    body.set_meta("npc_carried_resource", String(entry.get("jobResource", "")))
    return true

func update_returning_job(entry: Dictionary, body: StaticBody3D, timer: float) -> bool:
    var porch: Vector3 = entry.get("porchPosition", body.global_position)
    if body.global_position.distance_to(porch) <= CELL * 1.0 or timer <= 0.0:
        entry["jobPhase"] = "idle"
        entry["jobTimer"] = randf_range(8.0, 18.0)
        body.set_meta("npc_job_phase", "idle")
        body.set_meta("npc_carried_resource", "")
        return false
    entry["jobTarget"] = porch
    entry["jobTimer"] = timer
    body.set_meta("npc_job_phase", "returning")
    return true

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

func open_door_for_npc(collider: Node) -> void:
    if collider == null or main == null or not main.has_method("toggle_door"):
        return
    if bool(collider.get_meta("open", false)):
        return
    if bool(main.toggle_door(collider)):
        door_opens += 1
        last_message = "NPC opened a door"

func move_npc(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false) -> float:
    return pathing.move_npc(entry, target, max_distance, moving_home, allow_outside)

func choose_day_target(entry: Dictionary) -> Vector3:
    return pathing.choose_day_target(entry)

func choose_job_target(entry: Dictionary) -> Vector3:
    return pathing.choose_job_target(entry)

func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
    return pathing.point_inside_town(entry, position)

func nearest_hostile(origin: Vector3, radius: float) -> Node3D:
    return combat.nearest_hostile(origin, radius)

func fire_at_hostile(entry: Dictionary, target: Node3D) -> void:
    combat.fire_at_hostile(entry, target)

func strike_hostile(entry: Dictionary, target: Node3D) -> void:
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
