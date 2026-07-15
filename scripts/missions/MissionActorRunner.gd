extends RefCounted
class_name MissionActorRunner

## Generic adapter for story-owned actor choreography. Mission scripts select actors;
## this runner only calls the ordinary production NPC order and placement contracts.

static func actor_entry(npc_system, actor_id) -> Dictionary:
    if npc_system == null or not npc_system.has_method("npc_entry_for_actor"):
        return {}
    var value = npc_system.call("npc_entry_for_actor", actor_id)
    return value if value is Dictionary else {}

static func actor_body(npc_system, actor_id) -> Node3D:
    var entry := actor_entry(npc_system, actor_id)
    var body := entry.get("body") as Node3D
    return body if body != null and is_instance_valid(body) else null

static func stage_and_wait(npc_system, actor_id, position: Vector3, reason: String) -> Dictionary:
    var entry := actor_entry(npc_system, actor_id)
    var body := entry.get("body") as CharacterBody3D
    if body == null or not is_instance_valid(body):
        return failed("missing_actor", actor_id, reason)
    if not npc_system.has_method("safe_place_npc") or not npc_system.has_method("order_wait"):
        return failed("missing_actor_runner_contract", actor_id, reason)
    var placement_value = npc_system.call("safe_place_npc", body, position, null, reason)
    var placement: Dictionary = placement_value if placement_value is Dictionary else {}
    if not bool(placement.get("ok", false)):
        return {
            "ok": false,
            "actorId": String(actor_id),
            "reason": String(placement.get("reason", "safe_placement_failed")),
            "placement": placement
        }
    var order_value = npc_system.call("order_wait", actor_id, reason)
    var order: Dictionary = order_value if order_value is Dictionary else {}
    return order_result(actor_id, reason, order, {"placement": placement})

static func wait(npc_system, actor_id, reason: String) -> Dictionary:
    if npc_system == null or not npc_system.has_method("order_wait"):
        return failed("missing_wait_contract", actor_id, reason)
    var value = npc_system.call("order_wait", actor_id, reason)
    return order_result(actor_id, reason, value if value is Dictionary else {})

static func go_to(npc_system, actor_id, target: Vector3, reason: String, arrival_radius: float, speed_mode := "walking", combat_overlay := false) -> Dictionary:
    if npc_system == null or not npc_system.has_method("order_go_to"):
        return failed("missing_go_to_contract", actor_id, reason)
    var value = npc_system.call("order_go_to", actor_id, target, reason, arrival_radius, speed_mode, combat_overlay)
    return order_result(actor_id, reason, value if value is Dictionary else {}, {"target": target})

static func go_home(npc_system, actor_id, reason: String, speed_mode := "walking") -> Dictionary:
    if npc_system == null or not npc_system.has_method("order_go_home"):
        return failed("missing_go_home_contract", actor_id, reason)
    var value = npc_system.call("order_go_home", actor_id, reason, speed_mode)
    return order_result(actor_id, reason, value if value is Dictionary else {})

static func resume(npc_system, actor_id) -> Dictionary:
    if npc_system == null or not npc_system.has_method("order_resume_schedule"):
        return failed("missing_resume_contract", actor_id, "resume_schedule")
    var value = npc_system.call("order_resume_schedule", actor_id)
    return order_result(actor_id, "resume_schedule", value if value is Dictionary else {}, {}, true)

static func cancel(npc_system, actor_id, reason: String) -> Dictionary:
    if npc_system == null or not npc_system.has_method("cancel_order"):
        return failed("missing_cancel_contract", actor_id, reason)
    var value = npc_system.call("cancel_order", actor_id, reason)
    var result: Dictionary = value if value is Dictionary else {}
    if result.is_empty():
        result = {"state": "CANCELLED", "reason": reason}
    return order_result(actor_id, reason, result, {}, true)

static func status(npc_system, actor_id) -> Dictionary:
    if npc_system == null or not npc_system.has_method("scripted_order_status"):
        return {}
    var value = npc_system.call("scripted_order_status", actor_id)
    return value if value is Dictionary else {}

static func home_status(npc_system, actor_id) -> Dictionary:
    var entry := actor_entry(npc_system, actor_id)
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return {"strictInside": false, "reason": "missing_actor"}
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    if autonomy == null or not autonomy.has_method("home_interior_status"):
        return {"strictInside": false, "reason": "missing_home_interior_authority"}
    var value = autonomy.call("home_interior_status", entry, body.global_position)
    return value if value is Dictionary else {"strictInside": false, "reason": "invalid_home_interior_status"}

static func result_summary(result: Dictionary) -> Dictionary:
    var order: Dictionary = result.get("order", {}) if result.get("order", {}) is Dictionary else {}
    return {
        "ok": bool(result.get("ok", false)),
        "actorId": String(result.get("actorId", "")),
        "reason": String(result.get("reason", "")),
        "state": String(result.get("state", order.get("state", ""))),
        "order": order_summary(order)
    }

static func order_summary(order: Dictionary) -> Dictionary:
    var target = order.get("target", Vector3.INF)
    return {
        "id": String(order.get("id", "")),
        "kind": String(order.get("kind", "")),
        "state": String(order.get("state", "")),
        "reason": String(order.get("statusReason", order.get("reason", ""))),
        "failureReason": String(order.get("failureReason", "")),
        "target": target if target is Vector3 and (target as Vector3).is_finite() else Vector3.ZERO,
        "arrivalRadius": float(order.get("arrivalRadius", 0.0)),
        "speedMode": String(order.get("speedMode", "")),
        "usesRouteStack": bool(order.get("usesRouteStack", false))
    }

static func order_result(actor_id, reason: String, order: Dictionary, extra := {}, allow_cancelled := false) -> Dictionary:
    var state := String(order.get("state", ""))
    var accepted := state != "" and not state.begins_with("FAILED") and (allow_cancelled or state != "CANCELLED")
    var result := {
        "ok": accepted,
        "actorId": String(actor_id),
        "reason": reason,
        "state": state,
        "order": order.duplicate(true)
    }
    if extra is Dictionary:
        result.merge(extra, true)
    return result

static func failed(failure_reason: String, actor_id, reason: String) -> Dictionary:
    return {
        "ok": false,
        "actorId": String(actor_id),
        "reason": failure_reason,
        "submissionReason": reason,
        "state": "FAILED"
    }
