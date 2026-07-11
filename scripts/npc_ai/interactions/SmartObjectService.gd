extends RefCounted
class_name SmartObjectService

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const InteractionRequestScript := preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")
const InteractionResultScript := preload("res://scripts/npc_ai/contracts/InteractionResult.gd")
const SmartObjectRegistrationScript := preload("res://scripts/npc_ai/interactions/SmartObjectRegistration.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := 1.35
const WORLD_CHUNK_CELL_SIZE := 28
const RESOURCE_QUERY_DEFAULT_CHUNK_RADIUS := 3
const COMMAND_RESERVE := &"reserve"
const COMMAND_RELEASE := &"release"
const COMMAND_CANCEL := &"cancel"
const COMMAND_COMPLETE := &"complete"
const COMMAND_HARVEST := &"harvest"
const COMMAND_DEPOSIT := &"deposit"
const COMMAND_USE := &"use"
const COMMAND_REST := &"rest"
const COMMAND_GUARD := &"guard"

var owner: Node = null
var door_portals = null
var registrations := {}
var completed_effects := {}
var counters := {}
var revision_counter := 0
var index_by_kind := {}
var available_index_by_kind := {}
var depleted_index_by_kind := {}
var index_by_tile := {}
var index_by_chunk := {}
var index_by_region := {}
var index_by_town := {}
var index_by_layer := {}
var query_cache := {}
var last_release_by_object := {}

func setup(owner_node: Node, door_portal_service) -> void:
	owner = owner_node
	door_portals = door_portal_service

func clear() -> void:
	registrations.clear()
	completed_effects.clear()
	counters.clear()
	index_by_kind.clear()
	available_index_by_kind.clear()
	depleted_index_by_kind.clear()
	index_by_tile.clear()
	index_by_chunk.clear()
	index_by_region.clear()
	index_by_town.clear()
	index_by_layer.clear()
	query_cache.clear()
	last_release_by_object.clear()
	revision_counter = 0
	if door_portals != null:
		door_portals.clear()

func has_live_registration(object_id: String) -> bool:
	if object_id == "" or not registrations.has(object_id):
		return false
	return registration_is_live(registrations[object_id])

func register_door(door: Node, metadata := {}) -> String:
	if door_portals == null:
		return ""
	var portal_id: String = door_portals.register_door(door, metadata)
	if portal_id != "":
		registrations[portal_id] = SmartObjectRegistrationScript.make(portal_id, "door", door, metadata)
		_connect_registration_lifecycle(registrations[portal_id])
	return portal_id

func register_object(object_id: String, kind: String, node: Node = null, metadata := {}) -> String:
	if object_id == "":
		object_id = object_id_for_node(node)
	if object_id == "":
		return ""
	var merged := metadata.duplicate(true) if metadata is Dictionary else {}
	merged["kind"] = kind
	merged["objectId"] = object_id
	merged["nodeBacked"] = node != null
	if not merged.has("slots"):
		merged["slots"] = make_default_slots(node, kind, merged)
	if not merged.has("capacity"):
		merged["capacity"] = 1
	var existing = registrations.get(object_id)
	if existing != null:
		_unindex_registration(existing)
		existing.kind = kind
		existing.node = node
		existing.metadata = merged
		var incoming_slots: Dictionary = merged.get("slots", {}).duplicate(true) if merged.get("slots", {}) is Dictionary else {}
		existing.slots = reconcile_registered_slots(existing, incoming_slots)
		existing.metadata["slots"] = existing.slots.duplicate(true)
		existing.depleted = bool(merged.get("depleted", existing.depleted))
		existing.revision += 1
	else:
		registrations[object_id] = SmartObjectRegistrationScript.make(object_id, kind, node, merged)
	var registration = registrations[object_id]
	registration.revision = _next_revision()
	_connect_registration_lifecycle(registration)
	_index_registration(registration)
	_record("registered", object_id, kind, { "slots": registration.slots.size() })
	return object_id

func register_resource(prop: Node, metadata := {}) -> String:
	if prop == null or not is_instance_valid(prop):
		return ""
	var material := String(prop.get_meta("material", ""))
	var drop := String(prop.get_meta("drop", ""))
	var kind := ""
	if drop == "logs" or material == "tree":
		kind = "tree_source"
	elif drop in ["stones", "copperOre", "ironOre"] or material in ["rock", "copperOre", "ironOre"]:
		kind = "stone_source"
	elif drop in ["berries", "aloe", "mirecap", "frostHerb"] or material in ["berryBush", "aloePatch", "mushroomCluster", "frostHerbPatch"]:
		kind = "forage_source"
	else:
		return ""
	var object_id := object_id_for_node(prop)
	var merged := metadata.duplicate(true) if metadata is Dictionary else {}
	merged["drop"] = drop
	merged["material"] = material
	merged["dropCount"] = max(1, int(prop.get_meta("drop_count", 1)))
	merged["action"] = "harvest_resource"
	merged["singleUse"] = true
	merged["requiresApproach"] = true
	var default_action_reach := CELL * 2.50 if kind == "forage_source" else CELL * 1.65
	merged["actionReach"] = float(merged.get("actionReach", default_action_reach))
	var default_vertical_tolerance := CELL * 2.0 if kind == "forage_source" else CELL * 0.72
	merged["verticalTolerance"] = float(merged.get("verticalTolerance", default_vertical_tolerance))
	return register_object(object_id, kind, prop, merged)

func register_workstation(block: Node, metadata := {}) -> String:
	var object_id := object_id_for_node(block)
	var block_type := String(block.get_meta("block_type", "")) if block != null and block.has_meta("block_type") else String(metadata.get("blockType", "workstation"))
	var kind := "workstation"
	if block_type == "chest":
		kind = "storage"
	elif block_type == "traderStall":
		kind = "trader_stall"
	elif block_type == "bed":
		kind = "bed"
	var merged := metadata.duplicate(true) if metadata is Dictionary else {}
	merged["blockType"] = block_type
	merged["requiresApproach"] = true
	merged["actionReach"] = float(merged.get("actionReach", CELL * 1.55))
	merged["verticalTolerance"] = float(merged.get("verticalTolerance", CELL * 0.72))
	return register_object(object_id, kind, block, merged)

func register_anchor(object_id: String, kind: String, position: Vector3, metadata := {}) -> String:
	var merged := metadata.duplicate(true) if metadata is Dictionary else {}
	merged["position"] = position
	merged["slots"] = {
		"slot:0": {
			"slotId": "slot:0",
			"position": position,
			"facing": Vector3.FORWARD,
			"capacity": int(merged.get("capacity", 1)),
			"occupants": []
		}
	}
	merged["requiresApproach"] = bool(merged.get("requiresApproach", true))
	merged["actionReach"] = float(merged.get("actionReach", CELL * 1.30))
	merged["verticalTolerance"] = float(merged.get("verticalTolerance", CELL * 0.72))
	return register_object(object_id, kind, null, merged)

func request_interaction(request, actors: Array = []):
	if request == null:
		return InteractionResultScript.make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing_request")
	var command: StringName = request_value(request, "command", &"none")
	if command in [
		NpcEnumsScript.DOOR_COMMAND_OPEN,
		NpcEnumsScript.DOOR_COMMAND_CLOSE,
		NpcEnumsScript.DOOR_COMMAND_HOLD,
		NpcEnumsScript.DOOR_COMMAND_RELEASE,
		NpcEnumsScript.DOOR_COMMAND_CANCEL,
		NpcEnumsScript.DOOR_COMMAND_LOCK,
		NpcEnumsScript.DOOR_COMMAND_UNLOCK,
		NpcEnumsScript.DOOR_COMMAND_DESTROY,
		NpcEnumsScript.DOOR_COMMAND_MARK_JAMMED,
		NpcEnumsScript.DOOR_COMMAND_REPAIR
	] and door_portals != null:
		return door_portals.request_interaction(request, actors)
	match command:
		COMMAND_RESERVE:
			return reserve_interaction(request)
		COMMAND_RELEASE, COMMAND_CANCEL:
			return release_interaction(request)
		COMMAND_COMPLETE:
			return complete_interaction(request)
		COMMAND_HARVEST:
			return immediate_harvest(request)
		COMMAND_DEPOSIT, COMMAND_USE, COMMAND_REST, COMMAND_GUARD:
			return complete_interaction(request)
	return InteractionResultScript.make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"unsupported")

func request_door_state(door: Node, desired_open: bool, actor: Node = null, actor_kind := "system", metadata := {}):
	if door_portals == null:
		return InteractionResultScript.make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing_door_service")
	return door_portals.request_door_state(door, desired_open, actor, actor_kind, metadata)

func request_player_door_use(door: Node, actor: Node = null, actor_kind := "player", metadata := {}):
	if door_portals == null:
		return InteractionResultScript.make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing_door_service")
	return door_portals.request_player_door_use(door, actor, actor_kind, metadata)

func reserve_interaction(request):
	var registration = registration_for_request(request)
	if registration == null:
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"target_gone", { "objectId": String(request_value(request, "object_id", "")) })
	if registration.depleted:
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"resource_depleted", { "objectId": registration.object_id })
	var access := validate_access_policy(registration, request)
	if not bool(access.get("ok", false)):
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, StringName(String(access.get("reason", "access_denied"))), access)
	var owner_id := _actor_id(request)
	expire_deadline_reservations(registration)
	var existing := reservation_for_owner(registration, owner_id)
	if not existing.is_empty():
		return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"already_reserved", reservation_metrics(registration, existing, false))
	var metadata := request_metadata(request)
	var action_kind := String(metadata.get("action", registration.metadata.get("action", String(request_value(request, "command", "")))))
	var preferred_slot_id := String(metadata.get("preferredSlotId", ""))
	var slot := first_available_slot(registration, owner_id, action_kind, preferred_slot_id)
	if slot.is_empty():
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"capacity_busy", {
			"objectId": registration.object_id,
			"kind": registration.kind,
			"capacity": int(registration.metadata.get("capacity", 1)),
			"owners": reservation_owners(registration),
			"ownerReservations": reservation_debug_rows(registration),
			"preferredSlotId": preferred_slot_id
		})
	var slot_id := String(slot.get("slotId", "slot:0"))
	var reservation_id := "%s:%s:%s:%d" % [registration.object_id, slot_id, owner_id, registration.revision]
	var current_frame := Engine.get_physics_frames()
	var max_age_seconds := maxf(0.0, float(metadata.get("maxReservationAgeSeconds", 0.0)))
	var max_age_frames := ceili(max_age_seconds * maxf(float(Engine.physics_ticks_per_second), 1.0))
	var slot_position: Vector3 = slot.get("position", object_position(registration))
	var reservation := {
		"reservationId": reservation_id,
		"slotId": slot_id,
		"ownerId": owner_id,
		"actorKind": String(request_value(request, "actor_kind", metadata.get("actorKind", ""))),
		"action": action_kind,
		"requestId": String(request_value(request, "request_id", "")),
		"generation": int(request_value(request, "generation", 0)),
		"routeRequestId": String(metadata.get("routeRequestId", "")),
		"routeGeneration": int(metadata.get("routeGeneration", 0)),
		"goalKey": String(metadata.get("goalKey", "")),
		"createdPhysicsFrame": current_frame,
		"updatedPhysicsFrame": current_frame,
		"lastHeartbeatPhysicsFrame": current_frame,
		"maxAgeFrames": max_age_frames,
		"deadlinePhysicsFrame": current_frame + max_age_frames if max_age_frames > 0 else -1,
		"reservedSlotPosition": slot_position,
		"state": "reserved"
	}
	registration.reservations[reservation_id] = reservation
	var updated_slot: Dictionary = registration.slots.get(slot_id, {}).duplicate(true)
	var occupants: Array = updated_slot.get("occupants", [])
	if not occupants.has(owner_id):
		occupants.append(owner_id)
	updated_slot["occupants"] = occupants
	registration.slots[slot_id] = updated_slot
	_count("reservations_granted")
	_record("reserved", registration.object_id, registration.kind, reservation_metrics(registration, reservation, false))
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"reserved", reservation_metrics(registration, reservation, false))

func release_interaction(request):
	var registration = registration_for_request(request)
	if registration == null:
		return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"release_target_gone")
	var reservation_id := String(request_metadata(request).get("reservationId", ""))
	var owner_id := _actor_id(request)
	var release_reason := String(request_metadata(request).get("reason", request_value(request, "command", "released")))
	var released := release_reservation(registration, reservation_id, owner_id, release_reason)
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"released" if released > 0 else &"nothing_to_release", {
		"objectId": registration.object_id,
		"released": released
	})

func heartbeat_reservation(object_id: String, reservation_id: String, owner_id: String, route_metadata := {}) -> Dictionary:
	if object_id == "" or not registrations.has(object_id):
		return { "ok": false, "status": "failed", "reason": "missing_registration", "objectId": object_id }
	var registration = registrations[object_id]
	if reservation_id == "" or not registration.reservations.has(reservation_id):
		return { "ok": false, "status": "failed", "reason": "missing_reservation", "objectId": object_id, "reservationId": reservation_id }
	var reservation: Dictionary = registration.reservations[reservation_id]
	var current_frame := Engine.get_physics_frames()
	if reservation_deadline_expired(reservation, current_frame):
		var expired_metrics := reservation_metrics(registration, reservation, false)
		release_reservation(registration, reservation_id, owner_id, "reservation_deadline")
		_count("reservation_deadlines_expired")
		return {
			"ok": false,
			"status": "failed",
			"reason": "reservation_deadline",
			"objectId": object_id,
			"reservationId": reservation_id,
			"metrics": expired_metrics
		}
	if owner_id == "" or String(reservation.get("ownerId", "")) != owner_id:
		return { "ok": false, "status": "failed", "reason": "reservation_owner_mismatch", "objectId": object_id, "reservationId": reservation_id }
	var expected_slot_id := String(route_metadata.get("slotId", ""))
	if expected_slot_id != "" and String(reservation.get("slotId", "")) != expected_slot_id:
		return { "ok": false, "status": "failed", "reason": "reservation_slot_mismatch", "objectId": object_id, "reservationId": reservation_id }
	var incoming_generation := int(route_metadata.get("routeGeneration", 0))
	var current_generation := int(reservation.get("routeGeneration", 0))
	var incoming_request_id := String(route_metadata.get("routeRequestId", ""))
	var current_request_id := String(reservation.get("routeRequestId", ""))
	if incoming_generation <= 0 or incoming_request_id == "":
		return { "ok": false, "status": "failed", "reason": "missing_route_identity", "objectId": object_id, "reservationId": reservation_id }
	if current_generation > 0 and incoming_generation < current_generation:
		return { "ok": false, "status": "failed", "reason": "stale_route_generation", "objectId": object_id, "reservationId": reservation_id, "routeGeneration": current_generation }
	if current_generation == incoming_generation and current_request_id != "" and current_request_id != incoming_request_id:
		return { "ok": false, "status": "failed", "reason": "route_request_generation_conflict", "objectId": object_id, "reservationId": reservation_id, "routeRequestId": current_request_id, "routeGeneration": current_generation }
	reservation["routeRequestId"] = incoming_request_id
	reservation["routeGeneration"] = incoming_generation
	reservation["goalKey"] = String(route_metadata.get("goalKey", reservation.get("goalKey", "")))
	reservation["updatedPhysicsFrame"] = current_frame
	reservation["lastHeartbeatPhysicsFrame"] = current_frame
	reservation["state"] = "route_bound"
	registration.reservations[reservation_id] = reservation
	_count("reservation_heartbeats")
	return {
		"ok": true,
		"status": "succeeded",
		"reason": "heartbeat",
		"metrics": reservation_metrics(registration, reservation, false)
	}

func complete_interaction(request):
	var registration = registration_for_request(request)
	var request_id := stable_request_id(request)
	if completed_effects.has(request_id):
		var replay: Dictionary = completed_effects[request_id].duplicate(true)
		replay["effectApplied"] = false
		return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"idempotent_replay", replay)
	if registration == null:
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"target_gone", { "requestId": request_id })
	if registration.depleted and _is_single_use(registration):
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"resource_depleted", { "objectId": registration.object_id })
	if registration_node_is_stale(registration):
		mark_registration_stale(registration, "freed_node")
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"target_gone", { "objectId": registration.object_id })
	var access := validate_access_policy(registration, request)
	if not bool(access.get("ok", false)):
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, StringName(String(access.get("reason", "access_denied"))), access)
	var owner_id := _actor_id(request)
	var reservation := reservation_for_request(registration, request)
	var metadata := request_metadata(request)
	var action_kind := String(metadata.get("action", registration.metadata.get("action", String(request_value(request, "command", "")))))
	var require_reservation := bool(metadata.get("requireReservation", owner_id != "" and String(request_value(request, "actor_kind", "")) != "player"))
	if require_reservation and reservation.is_empty():
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing_reservation", { "objectId": registration.object_id, "ownerId": owner_id })
	var approach := validate_approach(registration, request, reservation)
	if not bool(approach.get("ok", false)):
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, StringName(String(approach.get("reason", "invalid_approach"))), approach)
	var metrics := effect_metrics(registration, request, reservation, action_kind)
	metrics["effectApplied"] = true
	metrics["requestId"] = request_id
	if _is_single_use(registration) or action_kind == "harvest_resource" or String(request_value(request, "command", "")) == String(COMMAND_HARVEST):
		registration.depleted = true
		registration.metadata["depleted"] = true
		var live_node := live_registration_node_3d(registration)
		if live_node != null:
			live_node.set_meta("npc_harvested", true)
			live_node.set_meta("smart_object_depleted", true)
		release_object_reservations(registration, "completed")
		_index_registration(registration)
	elif not bool(metadata.get("holdReservation", false)):
		release_reservation(registration, String(reservation.get("reservationId", "")), owner_id, "completed")
	completed_effects[request_id] = metrics.duplicate(true)
	_count("effects_completed")
	_record("completed", registration.object_id, registration.kind, metrics)
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"effect_applied", metrics)

func immediate_harvest(request):
	var registration = registration_for_request(request)
	if registration == null:
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"target_gone")
	var owner_id := _actor_id(request)
	if reservation_for_owner(registration, owner_id).is_empty():
		var reserve_request = InteractionRequestScript.make(COMMAND_RESERVE, registration.object_id, owner_id, {
			"action": "harvest_resource",
			"actorKind": String(request_value(request, "actor_kind", "player"))
		})
		reserve_request.object_node = registration.node
		reserve_request.actor_node = request_value(request, "actor_node", null)
		reserve_request.actor_kind = request_value(request, "actor_kind", "")
		var reserve_result = reserve_interaction(reserve_request)
		if String(reserve_result.status) != String(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED):
			return reserve_result
	var complete_request = InteractionRequestScript.make(COMMAND_COMPLETE, registration.object_id, owner_id, request_metadata(request))
	complete_request.object_node = registration.node
	complete_request.actor_node = request_value(request, "actor_node", null)
	complete_request.actor_kind = request_value(request, "actor_kind", "")
	complete_request.request_id = stable_request_id(request)
	return complete_interaction(complete_request)

func notify_object_removed(object_id: String, node_or_reason = null, reason := "node_removed") -> void:
	var removal_reason := reason
	var node: Node = null
	if node_or_reason is String or node_or_reason is StringName:
		removal_reason = String(node_or_reason)
	elif node_or_reason != null and is_instance_valid(node_or_reason) and node_or_reason is Node:
		node = node_or_reason as Node
	if object_id == "" and node != null:
		object_id = object_id_for_node(node)
	if object_id == "":
		return
	var registration = registrations.get(object_id)
	if registration == null:
		return
	mark_registration_stale(registration, removal_reason)

func object_available(object_id: String, actor_id := "") -> Dictionary:
	var registration = registrations.get(object_id)
	if registration == null:
		return { "ok": false, "reason": "target_gone" }
	if registration_node_is_stale(registration):
		mark_registration_stale(registration, "freed_node")
		return { "ok": false, "reason": "target_gone" }
	if registration.depleted:
		return { "ok": false, "reason": "resource_depleted" }
	expire_deadline_reservations(registration)
	if not first_available_slot(registration, actor_id, "").is_empty():
		return { "ok": true, "reason": "available" }
	return {
		"ok": false,
		"reason": "capacity_busy",
		"owners": reservation_owners(registration),
		"ownerReservations": reservation_debug_rows(registration)
	}

func query_resource_nodes(entry: Dictionary, kinds: Array, options := {}) -> Array[Node3D]:
	var option_map: Dictionary = options if options is Dictionary else {}
	var cache_key: String = query_cache_key(entry, kinds, option_map)
	var cached: Dictionary = query_cache.get(cache_key, {})
	if not cached.is_empty() and int(cached.get("revision", -1)) == revision_counter and int(cached.get("frame", -1000)) + int(option_map.get("cacheFrames", 8)) >= Engine.get_process_frames():
		var cached_nodes: Array[Node3D] = []
		for object_id_value in cached.get("objectIds", []):
			var registration = registrations.get(String(object_id_value))
			var node := cached_resource_node_for_query(registration, entry, option_map)
			if node != null:
				cached_nodes.append(node)
		_count("indexed_query_cache_hits")
		return cached_nodes
	var body: Node3D = null
	var body_value = entry.get("body")
	if body_value != null and is_instance_valid(body_value) and body_value is Node3D:
		body = body_value as Node3D
	var origin: Vector3 = node_position(body) if body != null else entry.get("porchPosition", Vector3.ZERO)
	var object_ids := candidate_object_ids_for_query(entry, kinds, option_map, origin)
	var scored: Array[Dictionary] = []
	for object_id in object_ids.keys():
		var registration = registrations.get(String(object_id))
		if registration == null or not registration_matches_query(registration, entry, option_map):
			continue
		var position: Vector3 = object_position(registration)
		scored.append({
			"objectId": String(object_id),
			"position": position,
			"distance": Vector2(position.x - origin.x, position.z - origin.z).length()
		})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a.get("distance", 0.0)), float(b.get("distance", 0.0))):
			return String(a.get("objectId", "")) < String(b.get("objectId", ""))
		return float(a.get("distance", 0.0)) < float(b.get("distance", 0.0))
	)
	var limit: int = maxi(1, int(option_map.get("limit", 48)))
	var result: Array[Node3D] = []
	var result_ids: Array[String] = []
	for score in scored:
		if result.size() >= limit:
			break
		var object_id := String(score.get("objectId", ""))
		var registration = registrations.get(object_id)
		if registration == null:
			continue
		var node := live_registration_node_3d(registration)
		if node == null:
			continue
		result.append(node)
		result_ids.append(object_id)
	query_cache[cache_key] = {
		"revision": revision_counter,
		"frame": Engine.get_process_frames(),
		"objectIds": result_ids
	}
	_count("indexed_resource_queries")
	return result

func candidate_object_ids_for_query(entry: Dictionary, kinds: Array, options: Dictionary, origin: Vector3) -> Dictionary:
	var kind_lookup := {}
	for kind_value in kinds:
		var kind := String(kind_value)
		if kind != "":
			kind_lookup[kind] = true
	if kind_lookup.is_empty():
		return {}
	var result := {}
	var origin_cell := Vector2i(roundi(origin.x / CELL), roundi(origin.z / CELL))
	var chunk_size: int = maxi(1, WORLD_CHUNK_CELL_SIZE)
	var search_radius: int = resource_query_chunk_radius(entry, options)
	var collection_limit := resource_query_collection_limit(options)
	var found_enough := false
	for radius in range(search_radius + 1):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var chunk_cell := origin_cell + Vector2i(dx * chunk_size, dz * chunk_size)
				var bucket: Dictionary = index_by_chunk.get(chunk_key_for_cell(chunk_cell), {})
				collect_candidate_object_ids(result, bucket, kind_lookup, entry, options, collection_limit)
				if result.size() >= collection_limit:
					found_enough = true
					break
			if found_enough:
				break
		if found_enough:
			break
	if result.is_empty() and not bool(options.get("workAreaOnly", true)):
		_count("indexed_resource_global_fallbacks")
		for kind in kind_lookup.keys():
			var bucket: Dictionary = available_index_by_kind.get(String(kind), {})
			collect_candidate_object_ids(result, bucket, kind_lookup, entry, options, collection_limit)
			if result.size() >= collection_limit:
				break
	elif result.is_empty():
		_count("indexed_resource_empty_spatial_queries")
	else:
		_count("indexed_resource_spatial_queries")
	return result

func resource_query_chunk_radius(entry: Dictionary, options: Dictionary) -> int:
	if options.has("chunkRadius"):
		return maxi(1, int(options.get("chunkRadius", RESOURCE_QUERY_DEFAULT_CHUNK_RADIUS)))
	if bool(options.get("workAreaOnly", true)):
		var town_radius := float(entry.get("townRadius", 18))
		var farthest_work_cell_radius := town_radius + town_radius + 24.0
		return maxi(1, ceili(farthest_work_cell_radius / float(maxi(1, WORLD_CHUNK_CELL_SIZE))))
	return maxi(1, int(options.get("chunkRadius", RESOURCE_QUERY_DEFAULT_CHUNK_RADIUS)))

func resource_query_collection_limit(options: Dictionary) -> int:
	var limit := maxi(1, int(options.get("limit", 48)))
	return maxi(6, limit)

func collect_candidate_object_ids(result: Dictionary, bucket: Dictionary, kind_lookup: Dictionary, entry: Dictionary, options: Dictionary, collection_limit := 0) -> void:
	for object_id_value in bucket.keys():
		if collection_limit > 0 and result.size() >= collection_limit:
			return
		var object_id := String(object_id_value)
		if result.has(object_id):
			continue
		var registration = registrations.get(object_id)
		if registration == null or not registration_matches_candidate_filters(registration, entry, options, kind_lookup):
			continue
		result[object_id] = true

func registration_matches_candidate_filters(registration, entry: Dictionary, options: Dictionary, kind_lookup: Dictionary) -> bool:
	if registration == null or registration.depleted:
		return false
	if registration_node_is_stale(registration):
		mark_registration_stale(registration)
		return false
	if not kind_lookup.has(String(registration.kind)):
		return false
	var allowed_drops: Array = options.get("drops", [])
	if not allowed_drops.is_empty() and not allowed_drops.has(registration_drop_value(registration)):
		return false
	var allowed_materials: Array = options.get("materials", [])
	if not allowed_materials.is_empty() and not allowed_materials.has(registration_material_value(registration)):
		return false
	var position: Vector3 = object_position(registration)
	if bool(options.get("workAreaOnly", true)) and not indexed_point_inside_work_area(entry, position):
		return false
	if bool(options.get("outsideTown", true)) and indexed_point_inside_town(entry, position):
		return false
	var required_layer := int(options.get("verticalLayer", -999999))
	if required_layer != -999999 and vertical_layer_for_position(position) != required_layer:
		return false
	return true

func registration_drop_value(registration) -> String:
	if registration == null:
		return ""
	var node := live_registration_node_3d(registration)
	if node != null:
		return String(node.get_meta("drop", registration.metadata.get("drop", "")))
	return String(registration.metadata.get("drop", ""))

func registration_material_value(registration) -> String:
	if registration == null:
		return ""
	var node := live_registration_node_3d(registration)
	if node != null:
		return String(node.get_meta("material", registration.metadata.get("material", "")))
	return String(registration.metadata.get("material", ""))

func registration_matches_query(registration, entry: Dictionary, options: Dictionary) -> bool:
	if registration == null or registration.depleted:
		return false
	var node := live_registration_node_3d(registration)
	if node == null:
		return false
	if bool(node.get_meta("npc_harvested", false)) or bool(node.get_meta("smart_object_depleted", false)):
		return false
	var allowed_drops: Array = options.get("drops", [])
	if not allowed_drops.is_empty() and not allowed_drops.has(String(node.get_meta("drop", ""))):
		return false
	var allowed_materials: Array = options.get("materials", [])
	if not allowed_materials.is_empty() and not allowed_materials.has(String(node.get_meta("material", ""))):
		return false
	var unreachable_key := String(options.get("unreachableMetaKey", ""))
	if unreachable_key != "" and bool(node.get_meta(unreachable_key, false)):
		return false
	var position: Vector3 = object_position(registration)
	if bool(options.get("workAreaOnly", true)) and not indexed_point_inside_work_area(entry, position):
		return false
	if bool(options.get("outsideTown", true)) and indexed_point_inside_town(entry, position):
		return false
	var required_layer := int(options.get("verticalLayer", -999999))
	if required_layer != -999999 and vertical_layer_for_position(position) != required_layer:
		return false
	var actor_id := String(entry.get("id", ""))
	var availability: Dictionary = object_available(registration.object_id, actor_id)
	return bool(availability.get("ok", false))

func cached_resource_node_for_query(registration, entry: Dictionary, options: Dictionary) -> Node3D:
	if registration == null:
		return null
	if registration_node_is_stale(registration):
		mark_registration_stale(registration)
		return null
	if registration.depleted:
		return null
	var node := live_registration_node_3d(registration)
	if node == null:
		return null
	if bool(node.get_meta("npc_harvested", false)) or bool(node.get_meta("smart_object_depleted", false)):
		return null
	var unreachable_key := String(options.get("unreachableMetaKey", ""))
	if unreachable_key != "" and bool(node.get_meta(unreachable_key, false)):
		return null
	var required_layer := int(options.get("verticalLayer", -999999))
	if required_layer != -999999 and vertical_layer_for_position(node.global_position) != required_layer:
		return null
	return node

func score_candidates(entry: Dictionary, action_kind: String, candidates: Array) -> Array[Dictionary]:
	var scored: Array[Dictionary] = []
	var body: Node3D = null
	var body_value = entry.get("body")
	if body_value != null and is_instance_valid(body_value) and body_value is Node3D:
		body = body_value as Node3D
	var origin: Vector3 = node_position(body) if body != null else entry.get("porchPosition", Vector3.ZERO)
	var role := String(entry.get("job", entry.get("role", ""))).to_lower()
	for candidate in candidates:
		var object_id := ""
		var position := origin
		var metadata := {}
		if candidate is Dictionary:
			object_id = String(candidate.get("objectId", ""))
			position = candidate.get("position", origin)
			metadata = candidate.get("metadata", {})
		elif candidate != null and is_instance_valid(candidate) and candidate is Node3D:
			var node := candidate as Node3D
			object_id = object_id_for_node(node)
			position = node_position(node)
			metadata = { "material": String(node.get_meta("material", "")), "drop": String(node.get_meta("drop", "")) }
		var distance := Vector2(position.x - origin.x, position.z - origin.z).length()
		var congestion := 0
		if registrations.has(object_id):
			var registered_object = registrations[object_id]
			congestion = registered_object.reservations.size()
		var role_bonus := 0.0
		var drop := String(metadata.get("drop", ""))
		var material := String(metadata.get("material", ""))
		if role == "forage" and (drop == "berries" or material == "berryBush"):
			role_bonus = 18.0
		elif role == "wood" and (drop == "logs" or material == "tree"):
			role_bonus = 18.0
		elif role == "stone" and (drop in ["stones", "copperOre", "ironOre"] or material in ["rock", "copperOre", "ironOre"]):
			role_bonus = 18.0
		var danger := float(metadata.get("danger", 0.0))
		var score := distance + float(congestion) * CELL * 8.0 + danger * CELL * 10.0 - role_bonus
		scored.append({
			"objectId": object_id,
			"position": position,
			"score": score,
			"distance": distance,
			"congestion": congestion,
			"danger": danger,
			"roleBonus": role_bonus,
			"action": action_kind
		})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a.get("score", 0.0)), float(b.get("score", 0.0))):
			return String(a.get("objectId", "")) < String(b.get("objectId", ""))
		return float(a.get("score", 0.0)) < float(b.get("score", 0.0))
	)
	return scored

func registration_for_request(request):
	var object_id := String(request_value(request, "object_id", ""))
	var node_value = request_value(request, "object_node", null)
	if object_id == "" and node_value != null and is_instance_valid(node_value) and node_value is Node:
		object_id = object_id_for_node(node_value)
	if object_id != "" and registrations.has(object_id):
		return registrations[object_id]
	var node: Node = null
	if node_value != null and is_instance_valid(node_value) and node_value is Node:
		node = node_value as Node
	if node != null:
		if String(node.get_meta("kind", "")) == "prop":
			object_id = register_resource(node, request_metadata(request))
		elif node.has_meta("block_type"):
			object_id = register_workstation(node, request_metadata(request))
		if object_id != "" and registrations.has(object_id):
			return registrations[object_id]
	return null

func first_available_slot(registration, owner_id: String, _action_kind: String, preferred_slot_id := "") -> Dictionary:
	var slots: Dictionary = registration.slots
	var keys: Array = slots.keys()
	keys.sort()
	for key in keys:
		var slot: Dictionary = slots[key]
		var occupants: Array = slot.get("occupants", [])
		if occupants.has(owner_id):
			return slot
	var object_capacity := int(registration.metadata.get("capacity", 1))
	if registration.reservations.size() >= object_capacity:
		return {}
	if preferred_slot_id != "":
		if not slots.has(preferred_slot_id):
			return {}
		var preferred: Dictionary = slots[preferred_slot_id]
		var preferred_capacity := int(preferred.get("capacity", registration.metadata.get("capacity", 1)))
		var preferred_occupants: Array = preferred.get("occupants", [])
		return preferred if preferred_occupants.size() < preferred_capacity else {}
	for key in keys:
		var slot: Dictionary = slots[key]
		var capacity := int(slot.get("capacity", registration.metadata.get("capacity", 1)))
		var occupants: Array = slot.get("occupants", [])
		if occupants.size() < capacity:
			return slot
	return {}

func reconcile_registered_slots(registration, incoming_slots: Dictionary) -> Dictionary:
	var reconciled := incoming_slots.duplicate(true)
	for reservation_value in registration.reservations.values():
		var reservation: Dictionary = reservation_value
		var slot_id := String(reservation.get("slotId", ""))
		if slot_id == "":
			continue
		var previous_slot: Dictionary = registration.slots.get(slot_id, {}).duplicate(true)
		var live_slot: Dictionary = reconciled.get(slot_id, previous_slot).duplicate(true)
		var reserved_position = reservation.get("reservedSlotPosition", previous_slot.get("position", live_slot.get("position", Vector3.ZERO)))
		if reserved_position is Vector3:
			live_slot["position"] = reserved_position
		if previous_slot.has("facing"):
			live_slot["facing"] = previous_slot.get("facing")
		live_slot["slotId"] = slot_id
		live_slot["capacity"] = maxi(1, int(live_slot.get("capacity", previous_slot.get("capacity", 1))))
		var occupants: Array = live_slot.get("occupants", []).duplicate()
		var owner_id := String(reservation.get("ownerId", ""))
		if owner_id != "" and not occupants.has(owner_id):
			occupants.append(owner_id)
		live_slot["occupants"] = occupants
		reconciled[slot_id] = live_slot
	return reconciled

func reservation_for_owner(registration, owner_id: String) -> Dictionary:
	if owner_id == "":
		return {}
	for reservation_value in registration.reservations.values():
		var reservation: Dictionary = reservation_value
		if String(reservation.get("ownerId", "")) == owner_id:
			return reservation
	return {}

func reservation_deadline_expired(reservation: Dictionary, current_frame: int) -> bool:
	var deadline_frame := int(reservation.get("deadlinePhysicsFrame", -1))
	return deadline_frame > 0 and current_frame >= deadline_frame

func expire_deadline_reservations(registration, current_frame := -1) -> int:
	var frame := current_frame if current_frame >= 0 else Engine.get_physics_frames()
	var released := 0
	for reservation_id_value in registration.reservations.keys().duplicate():
		var reservation: Dictionary = registration.reservations.get(reservation_id_value, {})
		if not reservation_deadline_expired(reservation, frame):
			continue
		released += release_reservation(registration, String(reservation_id_value), String(reservation.get("ownerId", "")), "reservation_deadline")
	if released > 0:
		counters["reservation_deadlines_expired"] = int(counters.get("reservation_deadlines_expired", 0)) + released
	return released

func reservation_for_request(registration, request) -> Dictionary:
	var reservation_id := String(request_metadata(request).get("reservationId", ""))
	if reservation_id != "" and registration.reservations.has(reservation_id):
		return registration.reservations[reservation_id]
	return reservation_for_owner(registration, _actor_id(request))

func release_reservation(registration, reservation_id: String, owner_id: String, reason: String) -> int:
	var released := 0
	var keys: Array = registration.reservations.keys().duplicate()
	for key in keys:
		var reservation: Dictionary = registration.reservations[key]
		if reservation_id != "" and String(key) != reservation_id:
			continue
		if reservation_id == "" and owner_id != "" and String(reservation.get("ownerId", "")) != owner_id:
			continue
		var slot_id := String(reservation.get("slotId", ""))
		var release_frame := Engine.get_physics_frames()
		var release_debug := reservation_debug_row(registration, reservation, release_frame)
		release_debug["releaseReason"] = reason
		release_debug["releasedPhysicsFrame"] = release_frame
		last_release_by_object[registration.object_id] = release_debug
		registration.reservations.erase(key)
		var slot: Dictionary = registration.slots.get(slot_id, {}).duplicate(true)
		var occupants: Array = slot.get("occupants", [])
		occupants.erase(String(reservation.get("ownerId", "")))
		slot["occupants"] = occupants
		registration.slots[slot_id] = slot
		released += 1
		_record("released", registration.object_id, registration.kind, { "reservationId": String(key), "reason": reason })
	return released

func release_object_reservations(registration, reason: String) -> int:
	var released := 0
	for key in registration.reservations.keys().duplicate():
		var reservation: Dictionary = registration.reservations[key]
		released += release_reservation(registration, String(key), String(reservation.get("ownerId", "")), reason)
	return released

func release_owner(owner_id: String, reason := "owner_released") -> int:
	if owner_id == "":
		return 0
	var released := 0
	for registration in registrations.values():
		released += release_reservation(registration, "", owner_id, reason)
	return released

func owner_reservation_count(owner_id: String) -> int:
	if owner_id == "":
		return 0
	var count := 0
	for registration in registrations.values():
		for reservation_value in registration.reservations.values():
			var reservation: Dictionary = reservation_value
			if String(reservation.get("ownerId", "")) == owner_id:
				count += 1
	return count

func validate_approach(registration, request, reservation: Dictionary) -> Dictionary:
	var metadata := request_metadata(request)
	if not bool(metadata.get("requiresApproach", registration.metadata.get("requiresApproach", true))):
		return { "ok": true, "reason": "approach_not_required" }
	var actor_position := actor_position_for_request(request)
	if actor_position == Vector3.INF:
		return { "ok": false, "reason": "missing_actor_position", "objectId": registration.object_id }
	var slot := slot_for_reservation(registration, reservation)
	if slot.is_empty():
		return { "ok": false, "reason": "missing_approach_slot", "objectId": registration.object_id }
	var slot_position: Vector3 = slot.get("position", object_position(registration))
	var reach := float(metadata.get("actionReach", registration.metadata.get("actionReach", CELL * 1.55)))
	var vertical_tolerance := float(metadata.get("verticalTolerance", registration.metadata.get("verticalTolerance", CELL * 0.72)))
	var flat_distance := Vector2(actor_position.x - slot_position.x, actor_position.z - slot_position.z).length()
	var vertical_delta := absf(actor_position.y - slot_position.y)
	if vertical_delta > vertical_tolerance:
		return { "ok": false, "reason": "wrong_vertical_layer", "verticalDelta": vertical_delta, "tolerance": vertical_tolerance, "slot": _vector_summary(slot_position), "actor": _vector_summary(actor_position) }
	if flat_distance > reach:
		return { "ok": false, "reason": "outside_action_reach", "distance": flat_distance, "reach": reach, "slot": _vector_summary(slot_position), "actor": _vector_summary(actor_position) }
	var action_kind := String(metadata.get("action", registration.metadata.get("action", String(request_value(request, "command", "")))))
	if approach_line_of_sight_required(registration, metadata, reservation, action_kind):
		var line_reason := line_of_sight_block_reason(actor_position, object_position(registration), registration)
		if line_reason != "":
			return { "ok": false, "reason": line_reason, "slot": _vector_summary(slot_position), "actor": _vector_summary(actor_position) }
	return { "ok": true, "reason": "valid_approach", "distance": flat_distance, "slotId": String(slot.get("slotId", "")), "slot": _vector_summary(slot_position) }

func approach_line_of_sight_required(registration, metadata: Dictionary, reservation: Dictionary, action_kind: String) -> bool:
	if metadata.has("requiresLineOfSight"):
		return bool(metadata.get("requiresLineOfSight", true))
	if registration.metadata.has("requiresLineOfSight"):
		return bool(registration.metadata.get("requiresLineOfSight", true))
	return true

func validate_access_policy(registration, request) -> Dictionary:
	var metadata := request_metadata(request)
	var actor_kind := String(request_value(request, "actor_kind", metadata.get("actorKind", "")))
	var allowed_actor_kinds: Array = registration.metadata.get("allowedActorKinds", [])
	if not allowed_actor_kinds.is_empty() and not allowed_actor_kinds.has(actor_kind):
		return {
			"ok": false,
			"reason": "access_denied",
			"actorKind": actor_kind,
			"allowedActorKinds": allowed_actor_kinds.duplicate()
		}
	var schedule_state := String(metadata.get("scheduleState", ""))
	var allowed_schedule: Array = registration.metadata.get("allowedScheduleStates", [])
	if schedule_state != "" and not allowed_schedule.is_empty() and not allowed_schedule.has(schedule_state):
		return {
			"ok": false,
			"reason": "schedule_policy_closed",
			"scheduleState": schedule_state,
			"allowedScheduleStates": allowed_schedule.duplicate()
		}
	return { "ok": true, "reason": "access_granted" }

func slot_for_reservation(registration, reservation: Dictionary) -> Dictionary:
	if not reservation.is_empty():
		var slot_id := String(reservation.get("slotId", ""))
		if slot_id != "" and registration.slots.has(slot_id):
			return registration.slots[slot_id]
	var slots: Dictionary = registration.slots
	var keys: Array = slots.keys()
	keys.sort()
	if keys.is_empty():
		return {}
	return slots[keys[0]]

func effect_metrics(registration, request, reservation: Dictionary, action_kind: String) -> Dictionary:
	var drop := String(registration.metadata.get("drop", ""))
	var amount: int = max(1, int(registration.metadata.get("dropCount", registration.metadata.get("amount", 1))))
	var live_node := live_registration_node_3d(registration)
	if live_node != null:
		drop = String(live_node.get_meta("drop", drop))
		amount = max(1, int(live_node.get_meta("drop_count", amount)))
	var metrics := reservation_metrics(registration, reservation, true)
	metrics["action"] = action_kind
	metrics["drop"] = drop
	metrics["amount"] = amount
	metrics["material"] = String(registration.metadata.get("material", ""))
	metrics["propId"] = String(registration.metadata.get("propId", ""))
	if live_node != null:
		metrics["propId"] = String(live_node.get_meta("prop_id", metrics["propId"]))
		if live_node.has_meta("extra_drop"):
			metrics["extraDrop"] = String(live_node.get_meta("extra_drop", ""))
			metrics["extraAmount"] = int(live_node.get_meta("extra_drop_count", 0))
	metrics["command"] = String(request_value(request, "command", ""))
	return metrics

func reservation_metrics(registration, reservation: Dictionary, effect_applied: bool) -> Dictionary:
	var slot := slot_for_reservation(registration, reservation)
	var position: Vector3 = slot.get("position", object_position(registration)) if not slot.is_empty() else object_position(registration)
	var current_frame := Engine.get_physics_frames()
	var created_frame := int(reservation.get("createdPhysicsFrame", current_frame))
	var heartbeat_frame := int(reservation.get("lastHeartbeatPhysicsFrame", created_frame))
	var reserved_position: Vector3 = reservation.get("reservedSlotPosition", position) if reservation.get("reservedSlotPosition", position) is Vector3 else position
	return {
		"objectId": registration.object_id,
		"kind": registration.kind,
		"reservationId": String(reservation.get("reservationId", "")),
		"slotId": String(slot.get("slotId", reservation.get("slotId", ""))),
		"ownerId": String(reservation.get("ownerId", "")),
		"approachPosition": _vector_summary(position),
		"reservedApproachPosition": _vector_summary(reserved_position),
		"slotGeometryChanged": not reserved_position.is_equal_approx(position),
		"createdPhysicsFrame": created_frame,
		"updatedPhysicsFrame": int(reservation.get("updatedPhysicsFrame", created_frame)),
		"lastHeartbeatPhysicsFrame": heartbeat_frame,
		"ageFrames": maxi(0, current_frame - created_frame),
		"heartbeatAgeFrames": maxi(0, current_frame - heartbeat_frame),
		"maxAgeFrames": int(reservation.get("maxAgeFrames", 0)),
		"deadlinePhysicsFrame": int(reservation.get("deadlinePhysicsFrame", -1)),
		"routeRequestId": String(reservation.get("routeRequestId", "")),
		"routeGeneration": int(reservation.get("routeGeneration", 0)),
		"goalKey": String(reservation.get("goalKey", "")),
		"effectApplied": effect_applied,
		"depleted": registration.depleted
	}

func reservation_debug(object_id: String, owner_id := "") -> Dictionary:
	if object_id == "" or not registrations.has(object_id):
		return {
			"ok": false,
			"reason": "missing_registration",
			"objectId": object_id,
			"lastRelease": last_release_by_object.get(object_id, {}).duplicate(true)
		}
	var registration = registrations[object_id]
	var rows := reservation_debug_rows(registration, owner_id)
	return {
		"ok": true,
		"objectId": object_id,
		"kind": String(registration.kind),
		"depleted": bool(registration.depleted),
		"registrationRevision": int(registration.revision),
		"capacity": int(registration.metadata.get("capacity", 1)),
		"reservations": rows,
		"lastRelease": last_release_by_object.get(object_id, {}).duplicate(true)
	}

func reservation_debug_rows(registration, owner_id := "") -> Array:
	var rows: Array = []
	var current_frame := Engine.get_physics_frames()
	for reservation_value in registration.reservations.values():
		var reservation: Dictionary = reservation_value
		if owner_id != "" and String(reservation.get("ownerId", "")) != owner_id:
			continue
		rows.append(reservation_debug_row(registration, reservation, current_frame))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("reservationId", "")) < String(b.get("reservationId", ""))
	)
	return rows

func reservation_debug_row(registration, reservation: Dictionary, current_frame: int) -> Dictionary:
	var metrics := reservation_metrics(registration, reservation, false)
	metrics["state"] = String(reservation.get("state", ""))
	metrics["action"] = String(reservation.get("action", ""))
	metrics["requestId"] = String(reservation.get("requestId", ""))
	metrics["actorKind"] = String(reservation.get("actorKind", ""))
	metrics["debugPhysicsFrame"] = current_frame
	return metrics

func make_default_slots(node: Node, kind: String, metadata: Dictionary) -> Dictionary:
	var base := object_position_from_node_or_metadata(node, metadata)
	var reach := float(metadata.get("slotOffset", CELL * 1.05))
	var positions := [
		base + Vector3(reach, 0.0, 0.0),
		base + Vector3(-reach, 0.0, 0.0),
		base + Vector3(0.0, 0.0, reach),
		base + Vector3(0.0, 0.0, -reach)
	]
	if kind in ["bed", "storage", "trader_stall", "workstation"]:
		positions = [base + Vector3(0.0, 0.0, reach)]
	var slots := {}
	for i in range(positions.size()):
		var slot_id := "slot:%d" % i
		slots[slot_id] = {
			"slotId": slot_id,
			"position": positions[i],
			"facing": base - positions[i],
			"capacity": int(metadata.get("capacity", 1)),
			"occupants": []
		}
	return slots

func object_id_for_node(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return ""
	if node.has_meta("prop_id"):
		return "prop:%s" % String(node.get_meta("prop_id"))
	if node.has_meta("cell"):
		var cell = node.get_meta("cell")
		var kind := String(node.get_meta("block_type", node.name))
		if cell is Vector3i:
			return "block:%d,%d,%d:%s" % [cell.x, cell.y, cell.z, kind]
	if node.has_meta("smart_object_id"):
		return String(node.get_meta("smart_object_id"))
	return "node:%s:%d" % [String(node.name), node.get_instance_id()]

func object_position(registration) -> Vector3:
	if registration == null:
		return Vector3.ZERO
	return object_position_from_node_or_metadata(registration.node, registration.metadata)

func object_position_from_node_or_metadata(node, metadata: Dictionary) -> Vector3:
	if metadata.has("position") and metadata["position"] is Vector3:
		return metadata["position"]
	if node == null:
		return Vector3.ZERO
	if not is_instance_valid(node):
		return Vector3.ZERO
	if not (node is Node3D):
		return Vector3.ZERO
	var node_3d := node as Node3D
	return node_3d.global_position if node_3d.is_inside_tree() else node_3d.position
	return Vector3.ZERO

func live_registration_node_3d(registration) -> Node3D:
	if registration == null:
		return null
	var node = registration.node
	if node == null:
		if bool(registration.metadata.get("nodeBacked", false)) and not bool(registration.metadata.get("stale", false)):
			mark_registration_stale(registration, "missing_node")
		return null
	if not is_instance_valid(node):
		mark_registration_stale(registration, "freed_node")
		return null
	if not (node is Node3D):
		mark_registration_stale(registration, "not_node_3d")
		return null
	return node as Node3D

func registration_node_is_stale(registration) -> bool:
	if registration == null:
		return false
	if bool(registration.metadata.get("stale", false)):
		return false
	var node = registration.node
	if node == null:
		return bool(registration.metadata.get("nodeBacked", false))
	return not is_instance_valid(node)

func registration_is_live(registration) -> bool:
	if registration == null or registration.depleted:
		return false
	if bool(registration.metadata.get("stale", false)):
		return false
	if registration.node == null:
		return registration.metadata.has("position")
	return live_registration_node_3d(registration) != null

func mark_registration_stale(registration, reason := "stale_node") -> void:
	if registration == null:
		return
	var object_id := String(registration.object_id)
	if object_id == "":
		return
	if not registration.depleted:
		release_object_reservations(registration, reason)
	registration.depleted = true
	registration.node = null
	registration.metadata["depleted"] = true
	registration.metadata["available"] = false
	registration.metadata["stale"] = true
	_unindex_registration(registration)
	registration.revision = _next_revision()
	query_cache.clear()
	_record("removed", object_id, registration.kind, { "reason": reason })

func _connect_registration_lifecycle(registration) -> void:
	if registration == null:
		return
	var node = registration.node
	if node == null or not is_instance_valid(node) or not (node is Node):
		return
	var live_node := node as Node
	var callback := Callable(self, "_on_registered_node_tree_exiting").bind(String(registration.object_id), int(live_node.get_instance_id()))
	if not live_node.tree_exiting.is_connected(callback):
		live_node.tree_exiting.connect(callback)

func _on_registered_node_tree_exiting(object_id: String, instance_id: int) -> void:
	if object_id == "":
		return
	var registration = registrations.get(object_id)
	if registration == null:
		return
	var node = registration.node
	if node != null and is_instance_valid(node) and int(node.get_instance_id()) != instance_id:
		return
	mark_registration_stale(registration, "node_removed")

func actor_position_for_request(request) -> Vector3:
	var metadata := request_metadata(request)
	if metadata.has("actorPosition") and metadata["actorPosition"] is Vector3:
		return metadata["actorPosition"]
	var actor_value = request_value(request, "actor_node", null)
	if actor_value != null and is_instance_valid(actor_value) and actor_value is Node3D:
		var actor := actor_value as Node3D
		return node_position(actor)
	return Vector3.INF

func node_position(node: Node3D) -> Vector3:
	if node == null or not is_instance_valid(node):
		return Vector3.ZERO
	return node.global_position if node.is_inside_tree() else node.position

func line_of_sight_block_reason(from_position: Vector3, to_position: Vector3, registration) -> String:
	var blockers: Array = registration.metadata.get("blockers", [])
	for blocker in blockers:
		if blocker is AABB and segment_samples_enter_aabb(from_position, to_position, blocker):
			return "line_of_sight_blocked"
	var main_node = owner.get("main") if owner != null else null
	if main_node == null:
		return ""
	var blocks: Dictionary = main_node.get("blocks")
	if blocks.is_empty():
		return ""
	var flat_distance := Vector2(to_position.x - from_position.x, to_position.z - from_position.z).length()
	var steps: int = maxi(2, ceili(flat_distance / (CELL * 0.45)))
	for i in range(1, steps):
		var t := float(i) / float(steps)
		var sample := from_position.lerp(to_position, t)
		var sample_cell := Vector3i(roundi(sample.x / CELL), roundi(sample.y / CELL), roundi(sample.z / CELL))
		for dy in range(-1, 2):
			var key := Vector3i(sample_cell.x, sample_cell.y + dy, sample_cell.z)
			if not blocks.has(key):
				continue
			var block := blocks[key] as Node
			if block == null or not is_instance_valid(block):
				continue
			var block_type := String(block.get_meta("block_type", ""))
			if block_type in ["cobblestonePath", "torch"]:
				continue
			if block_type == "door" and bool(block.get_meta("open", false)):
				continue
			return "line_of_sight_blocked"
	return ""

func segment_samples_enter_aabb(from_position: Vector3, to_position: Vector3, bounds: AABB) -> bool:
	for i in range(1, 16):
		var t := float(i) / 16.0
		if bounds.has_point(from_position.lerp(to_position, t)):
			return true
	return false

func _index_registration(registration) -> void:
	if registration == null:
		return
	_unindex_registration(registration)
	var object_id: String = registration.object_id
	if object_id == "":
		return
	if bool(registration.metadata.get("stale", false)):
		query_cache.clear()
		return
	var position: Vector3 = object_position(registration)
	var cell := Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
	var tile_key: String = tile_key_for_cell(cell)
	var chunk_key: String = chunk_key_for_cell(cell)
	var region_key: String = region_key_for_cell(cell)
	var layer_key: String = str(vertical_layer_for_position(position))
	var town_key: String = String(registration.metadata.get("townKey", ""))
	_index_add(index_by_kind, registration.kind, object_id)
	if registration.depleted:
		_index_add(depleted_index_by_kind, registration.kind, object_id)
	else:
		_index_add(available_index_by_kind, registration.kind, object_id)
	_index_add(index_by_tile, tile_key, object_id)
	_index_add(index_by_chunk, chunk_key, object_id)
	_index_add(index_by_region, region_key, object_id)
	_index_add(index_by_layer, layer_key, object_id)
	if town_key != "":
		_index_add(index_by_town, town_key, object_id)
	registration.metadata["tileKey"] = tile_key
	registration.metadata["chunkKey"] = chunk_key
	registration.metadata["regionKey"] = region_key
	registration.metadata["verticalLayer"] = int(layer_key)
	registration.metadata["available"] = not registration.depleted
	query_cache.clear()

func _unindex_registration(registration) -> void:
	if registration == null:
		return
	var object_id: String = registration.object_id
	if object_id == "":
		return
	for index in [
		index_by_kind,
		available_index_by_kind,
		depleted_index_by_kind,
		index_by_tile,
		index_by_chunk,
		index_by_region,
		index_by_town,
		index_by_layer
	]:
		_index_remove(index, object_id)

func _index_add(index: Dictionary, key: String, object_id: String) -> void:
	if key == "" or object_id == "":
		return
	var bucket: Dictionary = index.get(key, {})
	bucket[object_id] = true
	index[key] = bucket

func _index_remove(index: Dictionary, object_id: String) -> void:
	for key_value in index.keys().duplicate():
		var key := String(key_value)
		var bucket: Dictionary = index.get(key, {})
		if not bucket.has(object_id):
			continue
		bucket.erase(object_id)
		if bucket.is_empty():
			index.erase(key)
		else:
			index[key] = bucket

func tile_key_for_cell(cell: Vector2i) -> String:
	var tile_size: int = maxi(1, NpcConstantsScript.NAV_TILE_CELL_SIZE)
	return "%d,%d" % [floori(float(cell.x) / float(tile_size)), floori(float(cell.y) / float(tile_size))]

func chunk_key_for_cell(cell: Vector2i) -> String:
	var chunk_size: int = maxi(1, WORLD_CHUNK_CELL_SIZE)
	return "%d,%d" % [floori(float(cell.x) / float(chunk_size)), floori(float(cell.y) / float(chunk_size))]

func region_key_for_cell(cell: Vector2i) -> String:
	var region_size := 64
	return "%d,%d" % [floori(float(cell.x) / float(region_size)), floori(float(cell.y) / float(region_size))]

func vertical_layer_for_position(position: Vector3) -> int:
	return floori(position.y / CELL)

func indexed_point_inside_town(entry: Dictionary, position: Vector3) -> bool:
	var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
	var radius := float(entry.get("townRadius", 18)) * CELL
	var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
	return flat.length() <= radius

func indexed_point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
	var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
	var radius := (float(entry.get("townRadius", 18)) + 24.0) * CELL
	var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
	return flat.length() <= radius

func query_cache_key(entry: Dictionary, kinds: Array, options: Dictionary) -> String:
	var kind_values: Array[String] = []
	for kind_value in kinds:
		kind_values.append(String(kind_value))
	kind_values.sort()
	var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
	return "%s|%d,%d|%d|%s|%s|%s|%s" % [
		",".join(kind_values),
		center.x,
		center.y,
		int(entry.get("townRadius", 18)),
		str(bool(options.get("workAreaOnly", true))),
		str(bool(options.get("outsideTown", true))),
		String(options.get("unreachableMetaKey", "")),
		String(options.get("verticalLayer", "")) + "|" + str(int(options.get("limit", 48))) + "|" + JSON.stringify(options.get("drops", [])) + "|" + JSON.stringify(options.get("materials", []))
	]

func reservation_owners(registration) -> Array:
	var owners := []
	for reservation in registration.reservations.values():
		owners.append(String((reservation as Dictionary).get("ownerId", "")))
	return owners

func stable_request_id(request) -> String:
	var request_id := String(request_value(request, "request_id", ""))
	if request_id != "":
		return request_id
	return "%s:%s:%s:%d" % [String(request_value(request, "command", "")), String(request_value(request, "object_id", "")), _actor_id(request), int(request_value(request, "generation", 0))]

func _actor_id(request) -> String:
	var actor_id := String(request_value(request, "actor_id", ""))
	if actor_id != "":
		return actor_id
	var actor := request_value(request, "actor_node", null) as Node
	if actor != null:
		if actor.has_meta("npc_stable_id"):
			return String(actor.get_meta("npc_stable_id"))
		if actor.name != "":
			return String(actor.name)
	return String(request_metadata(request).get("actorId", ""))

func _is_single_use(registration) -> bool:
	return bool(registration.metadata.get("singleUse", registration.kind in ["forage_source", "tree_source", "stone_source"]))

func request_value(request, key: String, default_value = null):
	if request == null:
		return default_value
	if request is Dictionary:
		return request.get(key, default_value)
	var value = request.get(key)
	return default_value if value == null else value

func request_metadata(request) -> Dictionary:
	var metadata = request_value(request, "metadata", {})
	return metadata if metadata is Dictionary else {}

func _result(status: StringName, reason: StringName, metrics := {}):
	var result = InteractionResultScript.make(status, reason)
	result.metrics = metrics.duplicate(true) if metrics is Dictionary else {}
	result.interaction_id = String(result.metrics.get("reservationId", result.metrics.get("requestId", "")))
	result.owner_npc_id = String(result.metrics.get("ownerId", ""))
	return result

func _vector_summary(value: Vector3) -> Array:
	return [snappedf(value.x, 0.001), snappedf(value.y, 0.001), snappedf(value.z, 0.001)]

func _next_revision() -> int:
	revision_counter += 1
	return revision_counter

func _count(key: String) -> void:
	counters[key] = int(counters.get(key, 0)) + 1

func _record(action: String, object_id: String, kind: String, metadata := {}) -> void:
	_count(action)
	if owner != null and owner.get("telemetry") != null:
		var telemetry = owner.get("telemetry")
		if telemetry != null and telemetry.has_method("record_event"):
			telemetry.record_event("_system", &"smart_object", action, StringName(kind), {
				"objectId": object_id,
				"metadata": metadata.duplicate(true) if metadata is Dictionary else {}
			})

func stats() -> Dictionary:
	var reservation_count := 0
	var oldest_reservation_age_frames := 0
	var current_frame := Engine.get_physics_frames()
	for registration in registrations.values():
		reservation_count += registration.reservations.size()
		for reservation_value in registration.reservations.values():
			var reservation: Dictionary = reservation_value
			oldest_reservation_age_frames = maxi(oldest_reservation_age_frames, current_frame - int(reservation.get("createdPhysicsFrame", current_frame)))
	return {
		"registrations": registrations.size(),
		"reservations": reservation_count,
		"oldestReservationAgeFrames": oldest_reservation_age_frames,
		"trackedReleaseObjects": last_release_by_object.size(),
		"doorPortals": door_portals.stats() if door_portals != null else {},
		"completedEffects": completed_effects.size(),
		"counters": counters.duplicate(true)
	}
