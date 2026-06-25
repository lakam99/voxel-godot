extends RefCounted
class_name NpcStats

static func build(system) -> Dictionary:
    var homed := 0
    var sheltered := 0
    var fighters := 0
    var armed := 0
    var visible_weapons := 0
    var job_workers := 0
    var outside_workers := 0
    var hungry := 0
    var foragers_with_food := 0
    var routed := 0
    var waiting_routes := 0
    var blocked_routes := 0
    var partial_routes := 0
    for entry in system.npcs:
        var body := entry.get("body") as Node
        if body == null or not is_instance_valid(body):
            continue
        if bool(body.get_meta("npc_has_home", false)):
            homed += 1
        if bool(body.get_meta("npc_inside_home", false)):
            sheltered += 1
        if bool(entry.get("canFight", false)):
            fighters += 1
        if String(entry.get("weaponId", "")) != "":
            armed += 1
        if body.has_meta("npc_weapon_visible") and bool(body.get_meta("npc_weapon_visible", false)):
            visible_weapons += 1
        if String(entry.get("job", "")) in ["forage", "wood", "stone"]:
            job_workers += 1
            if body is Node3D and not system.point_inside_town(entry, (body as Node3D).global_position):
                outside_workers += 1
        if float(entry.get("hunger", 100.0)) < 60.0:
            hungry += 1
        var personal_inventory: Dictionary = entry.get("personalInventory", {})
        if String(entry.get("job", "")) == "forage" and int(personal_inventory.get("berries", 0)) > 0:
            foragers_with_food += 1
        var route_status := String(entry.get("routeStatus", "idle"))
        if route_status == "moving" or route_status == "routed" or route_status == "arrived":
            routed += 1
        elif route_status == "waiting":
            waiting_routes += 1
        elif route_status == "blocked":
            blocked_routes += 1
        elif route_status == "partial":
            partial_routes += 1
    return {
        "npcs": system.npcs.size(),
        "homed": homed,
        "sheltered": sheltered,
        "fighters": fighters,
        "armed": armed,
        "visibleWeapons": visible_weapons,
        "jobWorkers": job_workers,
        "outsideWorkers": outside_workers,
        "jobRuns": system.job_runs_completed,
        "forageRuns": system.npc_forage_runs,
        "foragersWithFood": foragers_with_food,
        "hungry": hungry,
        "foodEaten": system.npc_food_eaten,
        "doorOpens": system.door_opens,
        "doorCloses": system.door_closes,
        "towns": system.spawned_town_keys.size(),
        "guardShots": system.guard_shots,
        "guardMeleeStrikes": system.guard_melee_strikes,
        "useAnimations": system.npc_use_animations,
        "pathDetours": system.npc_path_detours,
        "blockedMoves": system.npc_blocked_moves,
        "routeStatus": {
            "routed": routed,
            "waiting": waiting_routes,
            "blocked": blocked_routes,
            "partial": partial_routes
        },
        "routeReplans": system.npc_route_replans,
        "stuckRecoveries": system.npc_stuck_recoveries,
        "reservationWaits": system.npc_reservation_waits,
        "unreachableGoals": system.npc_unreachable_goals,
        "validatedMoves": system.npc_validated_moves,
        "tracers": system.combat.tracers.size() if system.combat else 0,
        "lastMessage": system.last_message
    }
