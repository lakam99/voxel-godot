extends RefCounted
class_name NpcStats

static func build(system) -> Dictionary:
    var npcs: Array = system.get("npcs")
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
    for entry in npcs:
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
    var autonomy_system = system.get("autonomy_system")
    var traffic_reservations = autonomy_system.get("traffic_reservations") if autonomy_system else null
    var traffic_stats: Dictionary = traffic_reservations.stats() if traffic_reservations else {}
    var pathing = system.get("pathing")
    var combat = system.get("combat")
    var coordinator = pathing.get("coordinator") if pathing else null
    var locomotion = coordinator.get("locomotion") if coordinator else null
    var spawned_town_keys: Dictionary = system.get("spawned_town_keys")
    var reservation_waits := int(system.get("npc_reservation_waits")) + int(traffic_stats.get("waiting", 0))
    return {
        "npcs": npcs.size(),
        "homed": homed,
        "sheltered": sheltered,
        "fighters": fighters,
        "armed": armed,
        "visibleWeapons": visible_weapons,
        "jobWorkers": job_workers,
        "outsideWorkers": outside_workers,
        "jobRuns": int(system.get("job_runs_completed")),
        "forageRuns": int(system.get("npc_forage_runs")),
        "foragersWithFood": foragers_with_food,
        "hungry": hungry,
        "foodEaten": int(system.get("npc_food_eaten")),
        "doorOpens": int(system.get("door_opens")),
        "doorCloses": int(system.get("door_closes")),
        "towns": spawned_town_keys.size(),
        "guardShots": int(system.get("guard_shots")),
        "guardMeleeStrikes": int(system.get("guard_melee_strikes")),
        "useAnimations": int(system.get("npc_use_animations")),
        "pathDetours": int(system.get("npc_path_detours")),
        "blockedMoves": int(system.get("npc_blocked_moves")),
        "routeStatus": {
            "routed": routed,
            "waiting": waiting_routes,
            "blocked": blocked_routes,
            "partial": partial_routes
        },
        "routeReplans": int(system.get("npc_route_replans")),
        "stuckRecoveries": int(system.get("npc_stuck_recoveries")),
        "reservationWaits": reservation_waits,
        "unreachableGoals": int(system.get("npc_unreachable_goals")),
        "validatedMoves": int(system.get("npc_validated_moves")),
        "avoidance": {
            "activeFrames": int(system.get("npc_avoidance_active_frames")),
            "callbackFrames": int(system.get("npc_avoidance_callback_frames")),
            "fallbackFrames": int(system.get("npc_avoidance_fallback_frames")),
            "peakActiveRegistrations": int(system.get("npc_avoidance_active_registrations")),
            "adapter": locomotion.avoidance_stats() if locomotion else {},
            "corridor": locomotion.corridor_stats() if locomotion else {}
        },
        "traffic": traffic_stats,
        "tracers": (combat.get("tracers") as Array).size() if combat else 0,
        "lastMessage": String(system.get("last_message"))
    }
