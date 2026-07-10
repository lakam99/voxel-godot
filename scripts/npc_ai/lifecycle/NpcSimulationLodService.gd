extends RefCounted
class_name NpcSimulationLodService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const AbstractNpcTransitScript := preload("res://scripts/npc_ai/lifecycle/AbstractNpcTransit.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")

const STATE_ACTIVE := "active"
const STATE_NEARBY := "nearby"
const STATE_ABSTRACT := "abstract"

const TRANSIENT_SAVE_KEYS := [
	"routeCells",
	"routeActions",
	"routeSnapshotRevision",
	"pathWaypoints",
	"pathRefreshTimer",
	"routeGoalCell",
	"routeForceReplan",
	"routeWaitTicks",
	"routeYieldTicks",
	"routePriority",
	"reservationWaits",
	"activeTrafficStepGroup",
	"activeDoorPortalId",
	"activeDoorActorId",
	"activeDoorDirection",
	"activeDoorTrafficGroupId",
	"jobReservationId",
	"jobApproachSlotId",
	"trafficWaitReason",
	"npc_requested_velocity",
	"npc_applied_velocity",
	"avoidanceRid",
	"debugTrace",
	"plannerOpenSet",
	"plannerClosedSet",
	"waitForGraph"
]

var autonomy_system = null
var npc_system = null
var main = null
var records_by_id := {}
var leak_counters := {
	"trafficReservations": 0,
	"doorHolds": 0,
	"smartObjectSlots": 0,
	"routeRequests": 0,
	"avoidanceRegistrations": 0,
	"contexts": 0
}
var counters := {
	"registered": 0,
	"unregistered": 0,
	"promotions": 0,
	"demotions": 0,
	"promotionRejected": 0,
	"demotionRejected": 0,
	"prefetchRequests": 0,
	"tileUnloadHolds": 0,
	"tileUnloadReleases": 0,
	"saveMigrations": 0,
	"cleanupCalls": 0
}

func setup(autonomy, npc_owner = null, main_node = null) -> void:
	autonomy_system = autonomy
	npc_system = npc_owner
	main = main_node

func clear() -> void:
	records_by_id.clear()
	for key in leak_counters.keys():
		leak_counters[key] = 0
	for key in counters.keys():
		counters[key] = 0

func register_actor(entry: Dictionary) -> Dictionary:
	var actor_id := actor_id_for(entry)
	if actor_id == "":
		return {}
	if not records_by_id.has(actor_id):
		records_by_id[actor_id] = {
			"id": actor_id,
			"state": String(entry.get("simulationLod", STATE_ACTIVE)),
			"brainAccumulator": 0.0,
			"abstractAccumulator": 0.0,
			"lastDistance": 0.0,
			"lastTransitionReason": "registered"
		}
		counters["registered"] = int(counters.get("registered", 0)) + 1
	var record: Dictionary = records_by_id[actor_id]
	entry["simulationLod"] = String(record.get("state", STATE_ACTIVE))
	entry["abstractSimulated"] = entry["simulationLod"] == STATE_ABSTRACT
	return record

func unregister_actor(entry_or_id, reason := "actor_removed") -> Dictionary:
	var actor_id := actor_id_for(entry_or_id)
	var cleanup := cleanup_actor_ownership(entry_or_id, reason)
	if actor_id != "":
		records_by_id.erase(actor_id)
		counters["unregistered"] = int(counters.get("unregistered", 0)) + 1
	return cleanup

func update_actor(entry: Dictionary, delta: float, observer_position := Vector3.INF, context := {}) -> Dictionary:
	var record := register_actor(entry)
	if record.is_empty():
		return { "state": STATE_ACTIVE, "brainDue": true, "reason": "missing_actor_id" }
	var current_state := String(record.get("state", STATE_ACTIVE))
	var distance := distance_to_observer(entry, observer_position)
	var next_state := classify_distance(distance, current_state)
	record["lastDistance"] = distance
	if current_state == STATE_ABSTRACT:
		advance_abstract(entry, delta)
		if next_state != STATE_ABSTRACT:
			var promoted := promote_actor(entry, promotion_position(entry, context), "distance_hysteresis", context)
			if not bool(promoted.get("ok", false)):
				record["state"] = STATE_ABSTRACT
				entry["simulationLod"] = STATE_ABSTRACT
				entry["abstractSimulated"] = true
				return { "state": STATE_ABSTRACT, "brainDue": false, "reason": String(promoted.get("reason", "promotion_rejected")), "distance": distance }
			current_state = STATE_ACTIVE
			next_state = classify_distance(distance, STATE_ACTIVE)
	if next_state == STATE_ABSTRACT and current_state != STATE_ABSTRACT:
		var demoted := demote_actor(entry, "distance_hysteresis", context)
		if not bool(demoted.get("ok", false)):
			record["state"] = current_state
			entry["simulationLod"] = current_state
			return { "state": current_state, "brainDue": true, "reason": String(demoted.get("reason", "demotion_rejected")), "distance": distance }
		return { "state": STATE_ABSTRACT, "brainDue": false, "reason": "demoted", "distance": distance }
	if next_state == STATE_ABSTRACT:
		record["state"] = STATE_ABSTRACT
		entry["simulationLod"] = STATE_ABSTRACT
		entry["abstractSimulated"] = true
		return { "state": STATE_ABSTRACT, "brainDue": false, "reason": "abstract", "distance": distance }
	record["state"] = next_state
	entry["simulationLod"] = next_state
	entry["abstractSimulated"] = next_state == STATE_ABSTRACT
	if next_state == STATE_NEARBY:
		record["brainAccumulator"] = float(record.get("brainAccumulator", 0.0)) + maxf(0.0, delta)
		var due := float(record.get("brainAccumulator", 0.0)) >= NpcConstantsScript.LOD_NEARBY_BRAIN_INTERVAL_SECONDS
		if due:
			record["brainAccumulator"] = 0.0
		return { "state": STATE_NEARBY, "brainDue": due, "reason": "nearby_cadence", "distance": distance }
	return { "state": STATE_ACTIVE, "brainDue": true, "reason": "active", "distance": distance }

func classify_distance(distance: float, previous_state := STATE_ACTIVE) -> String:
	if previous_state == STATE_ACTIVE:
		if distance > NpcConstantsScript.LOD_NEARBY_EXIT_DISTANCE:
			return STATE_ABSTRACT
		if distance > NpcConstantsScript.LOD_ACTIVE_EXIT_DISTANCE:
			return STATE_NEARBY
		return STATE_ACTIVE
	if previous_state == STATE_NEARBY:
		if distance <= NpcConstantsScript.LOD_ACTIVE_ENTER_DISTANCE:
			return STATE_ACTIVE
		if distance >= NpcConstantsScript.LOD_NEARBY_EXIT_DISTANCE:
			return STATE_ABSTRACT
		return STATE_NEARBY
	if distance <= NpcConstantsScript.LOD_ACTIVE_ENTER_DISTANCE:
		return STATE_ACTIVE
	if distance <= NpcConstantsScript.LOD_NEARBY_ENTER_DISTANCE:
		return STATE_NEARBY
	return STATE_ABSTRACT

func demote_actor(entry: Dictionary, reason := "demote", context := {}) -> Dictionary:
	var safe := can_demote(entry, context)
	if not bool(safe.get("ok", false)):
		counters["demotionRejected"] = int(counters.get("demotionRejected", 0)) + 1
		return safe
	var actor_id := actor_id_for(entry)
	var record := register_actor(entry)
	cleanup_actor_ownership(entry, "demote:%s" % reason)
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		if body is CollisionObject3D:
			entry["_lodCollisionLayer"] = int((body as CollisionObject3D).collision_layer)
			entry["_lodCollisionMask"] = int((body as CollisionObject3D).collision_mask)
			(body as CollisionObject3D).collision_layer = 0
			(body as CollisionObject3D).collision_mask = 0
		if body is Node3D:
			(body as Node3D).visible = false
		body.set_meta("npc_simulation_lod", STATE_ABSTRACT)
	entry["simulationLod"] = STATE_ABSTRACT
	entry["abstractSimulated"] = true
	entry["abstractRegionId"] = String(entry.get("abstractRegionId", semantic_region_for_entry(entry)))
	if context.has("transitEdge"):
		start_abstract_transit(entry, context.get("transitEdge", {}))
	record["state"] = STATE_ABSTRACT
	record["lastTransitionReason"] = reason
	counters["demotions"] = int(counters.get("demotions", 0)) + 1
	return { "ok": true, "state": STATE_ABSTRACT, "actorId": actor_id, "reason": reason }

func promote_actor(entry: Dictionary, target_position: Vector3, reason := "promote", context := {}) -> Dictionary:
	var safe := can_promote(entry, target_position, context)
	if not bool(safe.get("ok", false)):
		counters["promotionRejected"] = int(counters.get("promotionRejected", 0)) + 1
		return safe
	var body := entry.get("body") as CharacterBody3D
	var placement := {}
	if npc_system != null and npc_system.has_method("safe_place_npc"):
		placement = npc_system.safe_place_npc(body, target_position, entry.get("motorProfile"), "promotion")
	else:
		return { "ok": false, "reason": "missing_safe_placement_api" }
	if not bool(placement.get("ok", false)):
		counters["promotionRejected"] = int(counters.get("promotionRejected", 0)) + 1
		return { "ok": false, "reason": String(placement.get("reason", "safe_placement_rejected")), "placement": placement }
	var record := register_actor(entry)
	if body != null and is_instance_valid(body):
		if entry.has("_lodCollisionLayer") and body is CollisionObject3D:
			(body as CollisionObject3D).collision_layer = int(entry.get("_lodCollisionLayer", NpcConstantsScript.COLLISION_NPC_BODY))
			(body as CollisionObject3D).collision_mask = int(entry.get("_lodCollisionMask", NpcConstantsScript.COLLISION_NPC_BODY_MASK))
		if body is Node3D:
			(body as Node3D).visible = true
		body.set_meta("npc_simulation_lod", STATE_ACTIVE)
	entry["simulationLod"] = STATE_ACTIVE
	entry["abstractSimulated"] = false
	entry.erase("movementHeldForTopology")
	entry.erase("requestedTopologyTile")
	record["state"] = STATE_ACTIVE
	record["lastTransitionReason"] = reason
	counters["promotions"] = int(counters.get("promotions", 0)) + 1
	return { "ok": true, "state": STATE_ACTIVE, "position": target_position, "placement": placement }

func can_demote(entry: Dictionary, context := {}) -> Dictionary:
	var checks := {
		"in_door_threshold": bool(entry.get("inDoorThreshold", context.get("inDoorThreshold", false))) or String(entry.get("activeDoorPortalId", "")) != "",
		"in_door_sweep": bool(entry.get("inDoorSweep", context.get("inDoorSweep", false))),
		"active_bottleneck_reservation": String(entry.get("activeTrafficStepGroup", "")) != "" or String(entry.get("activeDoorTrafficGroupId", "")) != "",
		"immediate_combat": bool(entry.get("immediateCombat", context.get("immediateCombat", false))) or bool(entry.get("inCombat", false)),
		"physically_blocked": bool(entry.get("physicallyBlocked", context.get("physicallyBlocked", false))) or bool(entry.get("penetrating", context.get("penetrating", false))),
		"noninterruptible_interaction": bool(entry.get("nonInterruptibleInteraction", context.get("nonInterruptibleInteraction", false))),
		"visible_scripted_sequence": bool(entry.get("visibleScriptedSequence", context.get("visibleScriptedSequence", false))) or bool(entry.get("requiredVisibleScripted", false))
	}
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		checks["visible_scripted_sequence"] = bool(checks.get("visible_scripted_sequence", false)) or bool(body.get_meta("npc_required_visible_sequence", false))
	for key in checks.keys():
		if bool(checks[key]):
			return { "ok": false, "reason": key }
	var abstract_plan := validate_abstract_demotion_plan(entry, context)
	if not bool(abstract_plan.get("ok", false)):
		return abstract_plan
	return { "ok": true, "reason": "" }

func validate_abstract_demotion_plan(entry: Dictionary, context: Dictionary) -> Dictionary:
	if context.has("transitEdge") and context["transitEdge"] is Dictionary:
		var edge_result := AbstractNpcTransitScript.edge_is_traversable(context["transitEdge"])
		if not bool(edge_result.get("ok", false)):
			return edge_result
		return { "ok": true, "reason": "valid_transit_edge" }
	var transit = entry.get("abstractTransit")
	if transit != null and transit.has_method("to_summary"):
		var summary: Dictionary = transit.to_summary()
		if String(summary.get("state", "")) != AbstractNpcTransitScript.STATE_BLOCKED:
			return { "ok": true, "reason": "existing_transit" }
	if bool(context.get("allowStationaryAbstract", false)) and semantic_region_for_entry(entry) != "":
		return { "ok": true, "reason": "stationary_semantic_region" }
	return { "ok": false, "reason": "missing_abstract_transit" }

func can_promote(entry: Dictionary, target_position: Vector3, context := {}) -> Dictionary:
	if bool(entry.get("inDoorThreshold", false)) or bool(context.get("inDoorThreshold", false)):
		return { "ok": false, "reason": "door_threshold" }
	if not bool(context.get("topologyLoaded", true)):
		return { "ok": false, "reason": "topology_unloaded" }
	var transit_value = entry.get("abstractTransit")
	if transit_value != null:
		var transit = transit_value
		if transit.has_method("to_summary") and String(transit.get("state")) == AbstractNpcTransitScript.STATE_BLOCKED:
			return { "ok": false, "reason": "blocked_transit" }
	var body := entry.get("body") as CharacterBody3D
	if body == null or not is_instance_valid(body):
		return { "ok": false, "reason": "missing_body" }
	if target_position == Vector3.INF:
		return { "ok": false, "reason": "missing_position" }
	return { "ok": true, "reason": "" }

func start_abstract_transit(entry: Dictionary, edge: Dictionary) -> Dictionary:
	var allowed := AbstractNpcTransitScript.edge_is_traversable(edge)
	if not bool(allowed.get("ok", false)):
		entry["abstractTransitBlockedReason"] = String(allowed.get("reason", "blocked"))
		return allowed
	var transit = AbstractNpcTransitScript.from_edge(actor_id_for(entry), edge)
	entry["abstractTransit"] = transit
	entry["abstractRegionId"] = String(edge.get("fromRegionId", edge.get("from", entry.get("abstractRegionId", ""))))
	return { "ok": true, "transit": transit.to_summary() }

func advance_abstract(entry: Dictionary, delta: float) -> Dictionary:
	var transit = entry.get("abstractTransit")
	if transit != null and transit.has_method("advance"):
		var summary: Dictionary = transit.advance(delta)
		if String(summary.get("state", "")) == AbstractNpcTransitScript.STATE_ARRIVED:
			entry["abstractRegionId"] = String(summary.get("toRegionId", entry.get("abstractRegionId", "")))
		return summary
	return { "state": "idle", "actorId": actor_id_for(entry), "regionId": String(entry.get("abstractRegionId", "")) }

func cleanup_actor_ownership(entry_or_id, reason := "cleanup") -> Dictionary:
	var actor_id := actor_id_for(entry_or_id)
	var entry: Dictionary = entry_or_id if entry_or_id is Dictionary else {}
	if actor_id == "":
		return { "actorId": "", "released": {}, "leaks": leak_counters.duplicate(true) }
	counters["cleanupCalls"] = int(counters.get("cleanupCalls", 0)) + 1
	var released := {
		"traffic": 0,
		"smartObjects": 0,
		"doorHolds": 0,
		"routeState": 0,
		"avoidance": 0
	}
	if autonomy_system != null:
		if autonomy_system.has_method("release_npc_traffic_reservations"):
			released["traffic"] = int(autonomy_system.release_npc_traffic_reservations(actor_id, reason))
		if autonomy_system.has_method("release_npc_door_hold"):
			autonomy_system.release_npc_door_hold(actor_id, true)
			released["doorHolds"] = 1
		var smart_objects = autonomy_system.get("smart_objects")
		if smart_objects != null and smart_objects.has_method("release_owner"):
			released["smartObjects"] = int(smart_objects.release_owner(actor_id, reason))
	if npc_system != null and npc_system.has_method("cleanup_npc_route_state"):
		var route_cleanup: Dictionary = npc_system.cleanup_npc_route_state(actor_id, entry, reason)
		released["routeState"] = int(route_cleanup.get("routeState", 0))
		released["avoidance"] = int(route_cleanup.get("avoidance", 0))
	clear_transient_entry_state(entry)
	var leaks := scan_leaks(actor_id)
	for key in leaks.keys():
		leak_counters[key] = int(leaks.get(key, 0))
	return { "actorId": actor_id, "released": released, "leaks": leaks }

func clear_transient_entry_state(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	for key in TRANSIENT_SAVE_KEYS:
		entry.erase(key)
	NpcRouteStateStoreScript.write_status(entry, String(entry.get("routeStatus", "idle")), String(entry.get("routeReason", "")), "NpcSimulationLodService.clear_transient")

func prefetch_for_entry(entry: Dictionary, margin_cells := NpcConstantsScript.LOD_PREFETCH_BOUNDARY_MARGIN_CELLS) -> Dictionary:
	if autonomy_system == null or not autonomy_system.has_method("request_navigation_tile"):
		return { "requested": [], "reason": "missing_navigation_world" }
	var cells := route_cells_for_entry(entry)
	if cells.is_empty():
		return { "requested": [], "reason": "no_route" }
	var requested := []
	for cell in cells:
		if not (cell is Vector2i):
			continue
		var tile_key := tile_key_for_cell(cell)
		var local_x := posmod(cell.x, NpcConstantsScript.NAV_TILE_CELL_SIZE)
		var local_y := posmod(cell.y, NpcConstantsScript.NAV_TILE_CELL_SIZE)
		var near_boundary := local_x <= margin_cells or local_y <= margin_cells or local_x >= NpcConstantsScript.NAV_TILE_CELL_SIZE - 1 - margin_cells or local_y >= NpcConstantsScript.NAV_TILE_CELL_SIZE - 1 - margin_cells
		if not near_boundary:
			continue
		var result: Dictionary = autonomy_system.request_navigation_tile({ "tileKey": tile_key, "centerCell": cell }, 10, entry.get("motorProfile"))
		requested.append({ "tileKey": tile_key, "result": result })
	counters["prefetchRequests"] = int(counters.get("prefetchRequests", 0)) + requested.size()
	return { "requested": requested, "reason": "boundary_prefetch" if not requested.is_empty() else "not_near_boundary" }

func handle_tile_unloaded(tile_key: String, entries: Array) -> Dictionary:
	var affected := []
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		if not entry_uses_tile(entry, tile_key):
			continue
		entry["movementHeldForTopology"] = true
		entry["requestedTopologyTile"] = tile_key
		NpcRouteStateStoreScript.write_status(entry, "PENDING", "waiting_for_topology", "NpcSimulationLodService.tile_unloaded")
		affected.append(actor_id_for(entry))
		if autonomy_system != null and autonomy_system.has_method("request_navigation_tile"):
			autonomy_system.request_navigation_tile({ "tileKey": tile_key }, 100, entry.get("motorProfile"))
	counters["tileUnloadHolds"] = int(counters.get("tileUnloadHolds", 0)) + affected.size()
	return { "tileKey": tile_key, "affectedActors": affected, "action": "hold_and_request_topology" }

func should_hold_active_movement(entry: Dictionary) -> bool:
	if not bool(entry.get("movementHeldForTopology", false)):
		return false
	if String(entry.get("simulationLod", STATE_ACTIVE)) == STATE_ABSTRACT:
		return false
	if _release_topology_hold_if_ready(entry):
		return false
	return true

func _release_topology_hold_if_ready(entry: Dictionary) -> bool:
	var tile_key := String(entry.get("requestedTopologyTile", ""))
	if tile_key == "":
		_clear_topology_hold(entry, "missing_topology_tile")
		return true
	if not entry_uses_tile(entry, tile_key):
		_clear_topology_hold(entry, "route_changed_off_unloaded_tile")
		return true
	var navigation_world = autonomy_system.get("navigation_world") if autonomy_system != null else null
	if navigation_world != null and navigation_world.has_method("is_tile_traversable") and bool(navigation_world.is_tile_traversable(tile_key)):
		_clear_topology_hold(entry, "topology_ready")
		return true
	return false

func _clear_topology_hold(entry: Dictionary, reason: String) -> void:
	entry.erase("movementHeldForTopology")
	entry.erase("requestedTopologyTile")
	entry["routeForceReplan"] = true
	if String(entry.get("routeStatus", "")) == "PENDING" and String(entry.get("routeReason", "")) == "waiting_for_topology":
		NpcRouteStateStoreScript.write_status(entry, "waiting", reason, "NpcSimulationLodService.clear_topology_hold")
	counters["tileUnloadReleases"] = int(counters.get("tileUnloadReleases", 0)) + 1

func durable_snapshot(entry: Dictionary) -> Dictionary:
	var body := entry.get("body") as Node3D
	var position: Vector3 = body_position(body, entry.get("lastKnownPosition", Vector3.ZERO))
	var transit_save := {}
	var transit = entry.get("abstractTransit")
	if transit != null and transit.has_method("to_save"):
		transit_save = transit.to_save()
	var fact := {
		"schemaVersion": NpcConstantsScript.LOD_SCHEMA_VERSION,
		"id": String(entry.get("id", "")),
		"name": String(entry.get("name", "")),
		"role": String(entry.get("role", "")),
		"townKey": String(entry.get("townKey", "")),
		"homeCell": vector2i_to_array(entry.get("homeCell", Vector2i.ZERO)),
		"porchCell": vector2i_to_array(entry.get("porchCell", Vector2i.ZERO)),
		"guardCell": vector2i_to_array(entry.get("guardCell", Vector2i.ZERO)),
		"interiorMinCell": vector2i_to_array(entry.get("interiorMinCell", entry.get("homeCell", Vector2i.ZERO))),
		"interiorMaxCell": vector2i_to_array(entry.get("interiorMaxCell", entry.get("homeCell", Vector2i.ZERO))),
		"interiorRegionId": String(entry.get("interiorRegionId", deterministic_interior_region_id(entry))),
		"level": float(entry.get("level", position.y)),
		"position": vector3_to_array(position),
		"job": String(entry.get("job", "")),
		"jobResource": String(entry.get("jobResource", "")),
		"personalInventory": entry.get("personalInventory", {}).duplicate(true) if entry.get("personalInventory", {}) is Dictionary else {},
		"hunger": float(entry.get("hunger", 100.0)),
		"maxHunger": float(entry.get("maxHunger", 100.0)),
		"equipment": {
			"weaponId": String(entry.get("weaponId", "")),
			"carriedResource": String(entry.get("carriedResource", ""))
		},
		"nightGuard": bool(entry.get("nightGuard", false)),
		"guardDuty": guard_duty_for_entry(entry),
		"jobRuns": int(entry.get("jobRuns", 0)),
		"durableGoal": String(entry.get("goal", "idle")),
		"simulationLod": String(entry.get("simulationLod", STATE_ACTIVE)),
		"abstractRegionId": String(entry.get("abstractRegionId", semantic_region_for_entry(entry))),
		"abstractTransit": transit_save,
		"doorDurableState": entry.get("doorDurableState", {}).duplicate(true) if entry.get("doorDurableState", {}) is Dictionary else {}
	}
	return fact

func apply_durable_snapshot(entry: Dictionary, fact_value, options := {}) -> Dictionary:
	if not (fact_value is Dictionary):
		return { "ok": false, "reason": "invalid_fact" }
	var fact: Dictionary = fact_value
	var migrated := int(fact.get("schemaVersion", 0)) < NpcConstantsScript.LOD_SCHEMA_VERSION
	entry["job"] = String(fact.get("job", entry.get("job", "")))
	entry["jobResource"] = String(fact.get("jobResource", entry.get("jobResource", "")))
	entry["personalInventory"] = fact.get("personalInventory", {}).duplicate(true) if fact.get("personalInventory", {}) is Dictionary else {}
	entry["maxHunger"] = maxf(1.0, float(fact.get("maxHunger", entry.get("maxHunger", 100.0))))
	entry["hunger"] = clampf(float(fact.get("hunger", entry.get("hunger", 100.0))), 0.0, float(entry.get("maxHunger", 100.0)))
	entry["jobRuns"] = max(0, int(fact.get("jobRuns", entry.get("jobRuns", 0))))
	entry["interiorRegionId"] = String(fact.get("interiorRegionId", deterministic_interior_region_id(entry)))
	entry["abstractRegionId"] = String(fact.get("abstractRegionId", semantic_region_for_entry(entry)))
	entry["simulationLod"] = String(fact.get("simulationLod", entry.get("simulationLod", STATE_ACTIVE)))
	entry["abstractSimulated"] = entry["simulationLod"] == STATE_ABSTRACT
	entry["doorDurableState"] = fact.get("doorDurableState", {}).duplicate(true) if fact.get("doorDurableState", {}) is Dictionary else {}
	var equipment: Dictionary = fact.get("equipment", {}) if fact.get("equipment", {}) is Dictionary else {}
	entry["weaponId"] = String(equipment.get("weaponId", fact.get("weaponId", entry.get("weaponId", ""))))
	entry["carriedResource"] = String(equipment.get("carriedResource", fact.get("carriedResource", entry.get("carriedResource", ""))))
	entry["nightGuard"] = migrated_night_guard_default(entry, fact)
	if fact.get("abstractTransit", {}) is Dictionary and not (fact.get("abstractTransit", {}) as Dictionary).is_empty():
		entry["abstractTransit"] = AbstractNpcTransitScript.from_save(fact.get("abstractTransit", {}))
	reconstruct_schedule_intent(entry, fact, options)
	var placement := restore_saved_position(entry, fact, options)
	if migrated:
		record_migration(entry, "npc_save_schema_%d_to_%d" % [int(fact.get("schemaVersion", 0)), NpcConstantsScript.LOD_SCHEMA_VERSION])
		counters["saveMigrations"] = int(counters.get("saveMigrations", 0)) + 1
	return { "ok": true, "migrated": migrated, "placement": placement, "scheduleIntent": String(entry.get("restoredScheduleIntent", "")) }

func snapshot_has_transient_state(snapshot: Dictionary) -> bool:
	for key in TRANSIENT_SAVE_KEYS:
		if snapshot.has(key):
			return true
	var transit: Dictionary = snapshot.get("abstractTransit", {}) if snapshot.get("abstractTransit", {}) is Dictionary else {}
	for key in ["routeCells", "reservationIds", "avoidanceRid", "plannerOpenSet", "plannerClosedSet", "debugTrace"]:
		if transit.has(key):
			return true
	return false

func actor_id_for(entry_or_id) -> String:
	if entry_or_id is Dictionary:
		return String((entry_or_id as Dictionary).get("id", ""))
	if entry_or_id is Node:
		var node := entry_or_id as Node
		if node.has_meta("npc_stable_id"):
			return String(node.get_meta("npc_stable_id"))
		if node.has_meta("npc_id"):
			return String(node.get_meta("npc_id"))
		return String(node.name)
	return String(entry_or_id)

func distance_to_observer(entry: Dictionary, observer_position: Vector3) -> float:
	if observer_position == Vector3.INF:
		if main != null:
			var player = main.get("player")
			if player is Node3D:
				observer_position = (player as Node3D).global_position
	if observer_position == Vector3.INF:
		return 0.0
	var body := entry.get("body") as Node3D
	var position: Vector3 = body_position(body, entry.get("lastKnownPosition", Vector3.ZERO))
	position.y = 0.0
	observer_position.y = 0.0
	return position.distance_to(observer_position)

func promotion_position(entry: Dictionary, context: Dictionary) -> Vector3:
	if context.has("promotionPosition") and context["promotionPosition"] is Vector3:
		return context["promotionPosition"]
	if entry.has("abstractPosition") and entry["abstractPosition"] is Vector3:
		return entry["abstractPosition"]
	if entry.has("homePosition") and entry["homePosition"] is Vector3:
		return entry["homePosition"]
	var body := entry.get("body") as Node3D
	return body_position(body, Vector3.INF)

func route_cells_for_entry(entry: Dictionary) -> Array:
	var cells := []
	if entry.get("routeCells", []) is Array:
		cells.append_array(entry.get("routeCells", []))
	var goal = entry.get("routeGoalCell")
	if goal is Vector2i:
		cells.append(goal)
	return cells

func entry_uses_tile(entry: Dictionary, tile_key: String) -> bool:
	for cell in route_cells_for_entry(entry):
		if cell is Vector2i and tile_key_for_cell(cell) == tile_key:
			return true
	var body := entry.get("body") as Node3D
	if body != null and is_instance_valid(body):
		var cell := Vector2i(roundi(body.global_position.x / NpcConstantsScript.CELL_SIZE), roundi(body.global_position.z / NpcConstantsScript.CELL_SIZE))
		return tile_key_for_cell(cell) == tile_key
	return false

func tile_key_for_cell(cell: Vector2i) -> String:
	return "%d,%d" % [floori(float(cell.x) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE)), floori(float(cell.y) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE))]

func scan_leaks(_actor_id: String) -> Dictionary:
	var leaks := {
		"trafficReservations": 0,
		"doorHolds": 0,
		"smartObjectSlots": 0,
		"routeRequests": 0,
		"avoidanceRegistrations": 0,
		"contexts": 0
	}
	if autonomy_system != null:
		var traffic = autonomy_system.get("traffic_reservations")
		if traffic != null and traffic.has_method("active_reservation_count"):
			leaks["trafficReservations"] = int(traffic.active_reservation_count())
		var door = autonomy_system.get("door_traversal")
		if door != null and door.has_method("stats"):
			leaks["doorHolds"] = int(door.stats().get("activeCrossings", 0))
		var smart = autonomy_system.get("smart_objects")
		if smart != null and smart.has_method("owner_reservation_count"):
			leaks["smartObjectSlots"] = int(smart.owner_reservation_count(_actor_id))
		var contexts = autonomy_system.get("contexts_by_stable_id")
		if contexts is Dictionary:
			leaks["contexts"] = 1 if (contexts as Dictionary).has(_actor_id) and not records_by_id.has(_actor_id) else 0
	if npc_system != null and npc_system.has_method("npc_avoidance_registration_count"):
		leaks["avoidanceRegistrations"] = int(npc_system.npc_avoidance_registration_count())
	return leaks

func restore_saved_position(entry: Dictionary, fact: Dictionary, _options: Dictionary) -> Dictionary:
	var body := entry.get("body") as CharacterBody3D
	if body == null or not is_instance_valid(body):
		return { "ok": false, "reason": "missing_body" }
	var position := array_to_vector3(fact.get("position", []), body_position(body, Vector3.ZERO))
	var valid_position := bool(fact.get("positionValid", true))
	if not valid_position:
		position = entry.get("homePosition", body.global_position)
		record_migration(entry, "invalid_position_safe_migration")
	if npc_system != null and npc_system.has_method("safe_place_npc"):
		return npc_system.safe_place_npc(body, position, entry.get("motorProfile"), "load_restore")
	return { "ok": false, "reason": "missing_safe_placement_api" }

func reconstruct_schedule_intent(entry: Dictionary, _fact: Dictionary, options: Dictionary) -> void:
	var time_of_day := float(options.get("timeOfDay", -1.0))
	var is_night := bool(options.get("isNight", time_of_day >= 0.68 or time_of_day <= 0.10))
	if is_night:
		if bool(entry.get("nightGuard", false)) or String(entry.get("guardDuty", "")) != "":
			entry["restoredScheduleIntent"] = "guard_duty"
		else:
			entry["restoredScheduleIntent"] = "return_home"
	else:
		entry["restoredScheduleIntent"] = "work_or_idle"

func migrated_night_guard_default(entry: Dictionary, fact: Dictionary) -> bool:
	if fact.has("nightGuard"):
		return bool(fact.get("nightGuard", false))
	var duty := String(fact.get("guardDuty", ""))
	if duty != "":
		return true
	var role := String(fact.get("role", entry.get("role", ""))).to_lower()
	return role.find("guard") >= 0

func guard_duty_for_entry(entry: Dictionary) -> String:
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body) and body.has_meta("npc_guard_duty"):
		return String(body.get_meta("npc_guard_duty"))
	return String(entry.get("guardDuty", ""))

func deterministic_interior_region_id(entry: Dictionary) -> String:
	var town_key := String(entry.get("townKey", "town"))
	var home: Vector2i = entry.get("homeCell", Vector2i.ZERO)
	return "home:%s:%d,%d" % [town_key, home.x, home.y]

func semantic_region_for_entry(entry: Dictionary) -> String:
	if String(entry.get("abstractRegionId", "")) != "":
		return String(entry.get("abstractRegionId", ""))
	if String(entry.get("interiorRegionId", "")) != "":
		return String(entry.get("interiorRegionId", ""))
	return deterministic_interior_region_id(entry)

func record_migration(entry: Dictionary, message: String) -> void:
	var log: Array = entry.get("saveMigrationLog", [])
	if not log.has(message):
		log.append(message)
	entry["saveMigrationLog"] = log

func vector2i_to_array(cell: Vector2i) -> Array:
	return [cell.x, cell.y]

func vector3_to_array(position: Vector3) -> Array:
	return [position.x, position.y, position.z]

func array_to_vector3(value, fallback: Vector3) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback

func body_position(body: Node3D, fallback: Vector3) -> Vector3:
	if body == null or not is_instance_valid(body):
		return fallback
	return body.global_position if body.is_inside_tree() else body.position

func stats() -> Dictionary:
	var state_counts := { STATE_ACTIVE: 0, STATE_NEARBY: 0, STATE_ABSTRACT: 0 }
	for record in records_by_id.values():
		var state := String((record as Dictionary).get("state", STATE_ACTIVE))
		state_counts[state] = int(state_counts.get(state, 0)) + 1
	return {
		"records": records_by_id.size(),
		"states": state_counts,
		"counters": counters.duplicate(true),
		"leakCounters": leak_counters.duplicate(true),
		"thresholds": {
			"activeEnter": NpcConstantsScript.LOD_ACTIVE_ENTER_DISTANCE,
			"activeExit": NpcConstantsScript.LOD_ACTIVE_EXIT_DISTANCE,
			"nearbyEnter": NpcConstantsScript.LOD_NEARBY_ENTER_DISTANCE,
			"nearbyExit": NpcConstantsScript.LOD_NEARBY_EXIT_DISTANCE
		}
	}
