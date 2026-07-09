extends RefCounted
class_name NavmeshWorldService

const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const NAV_TILE_CELL_SIZE := NpcConstantsScript.NAV_TILE_CELL_SIZE
const MAX_TIMING_SAMPLES := 512
const ENDPOINT_QUERY_CACHE_LIMIT := 256
const SERVER_CLOSEST_RETRIES := 8
const SERVER_PATH_QUERY_ATTEMPTS := 1
const PATH_ENDPOINT_EPSILON := CELL * 0.12
const EDGE_CONNECTION_MARGIN := CELL * 0.18
const LINK_CONNECTION_RADIUS := CELL * 0.75

var backend_config = NavigationBackendConfigScript.default_config()
var navigation_map := RID()
var owns_navigation_map := false
var descriptors_by_region := {}
var region_states := {}
var region_rids_by_region := {}
var region_ids_by_rid := {}
var region_metrics_by_region := {}
var topology_revision := 0
var dynamic_revision := 0
var registered_region_count := 0
var unregistered_region_count := 0
var installed_region_count := 0
var installed_surface_count := 0
var last_install_usec := 0
var path_query_count := 0
var path_query_failure_count := 0
var last_path_query_usec := 0
var total_path_query_usec := 0
var max_path_query_usec := 0
var slowest_path_query := {}
var install_duration_samples_usec: Array[int] = []
var path_query_duration_samples_usec: Array[int] = []
var dirty_regions_by_region := {}
var dirty_region_queue: Array[String] = []
var rebuild_count := 0
var last_rebuild_usec := 0
var door_link_records_by_region := {}
var door_link_records_by_portal := {}
var door_portal_states := {}
var installed_door_link_count := 0
var door_link_state_revision := 0
var door_link_install_failure_count := 0
var actor_path_records := {}
var navigation_map_dirty_serial := 0
var navigation_map_synced_serial := 0
var navigation_map_last_iteration_id := -1
var reusable_path_query_parameters := NavigationPathQueryParameters3D.new()
var endpoint_query_cache := {}
var endpoint_query_cache_order: Array[String] = []

func setup(config = null) -> void:
	backend_config = config if config != null else NavigationBackendConfigScript.from_environment()
	if backend_config.use_navmesh():
		_ensure_navigation_map()

func clear() -> void:
	for region_id in region_rids_by_region.keys():
		_release_region(String(region_id))
	descriptors_by_region.clear()
	region_states.clear()
	region_metrics_by_region.clear()
	dirty_regions_by_region.clear()
	dirty_region_queue.clear()
	door_link_records_by_region.clear()
	door_link_records_by_portal.clear()
	door_portal_states.clear()
	actor_path_records.clear()
	endpoint_query_cache.clear()
	endpoint_query_cache_order.clear()
	topology_revision = 0
	dynamic_revision = 0
	registered_region_count = 0
	unregistered_region_count = 0
	installed_region_count = 0
	installed_surface_count = 0
	last_install_usec = 0
	rebuild_count = 0
	last_rebuild_usec = 0
	path_query_count = 0
	path_query_failure_count = 0
	last_path_query_usec = 0
	total_path_query_usec = 0
	max_path_query_usec = 0
	slowest_path_query.clear()
	navigation_map_dirty_serial = 0
	navigation_map_synced_serial = 0
	navigation_map_last_iteration_id = -1
	install_duration_samples_usec.clear()
	path_query_duration_samples_usec.clear()
	installed_door_link_count = 0
	door_link_state_revision = 0
	door_link_install_failure_count = 0
	if owns_navigation_map and navigation_map.is_valid():
		NavigationServer3D.free_rid(navigation_map)
	navigation_map = RID()
	owns_navigation_map = false

func register_chunk_descriptor(descriptor) -> Dictionary:
	if descriptor == null:
		return { "status": "rejected", "reason": "missing_descriptor" }
	var region_id := String(descriptor.get("region_id"))
	if region_id == "":
		return { "status": "rejected", "reason": "missing_region_id" }
	var signature: String = String(descriptor.stable_signature()) if descriptor.has_method("stable_signature") else ""
	var existing_metrics: Dictionary = region_metrics_by_region.get(region_id, {})
	if signature != "" \
		and descriptors_by_region.has(region_id) \
		and region_rids_by_region.has(region_id) \
		and not dirty_regions_by_region.has(region_id) \
		and String(existing_metrics.get("signature", "")) == signature:
		return {
			"status": String(region_states.get(region_id, "installed")),
			"regionId": region_id,
			"tileKey": String(descriptor.get("tile_key")),
			"topologyRevision": topology_revision,
			"installed": true,
			"cached": true,
			"install": existing_metrics.duplicate(true),
			"signature": signature
		}
	_ensure_navigation_map()
	if region_rids_by_region.has(region_id):
		_release_region(region_id)
	descriptors_by_region[region_id] = descriptor
	_clear_dirty_region(region_id)
	var loaded := bool(descriptor.get("loaded"))
	var install_result := _install_region(region_id, descriptor) if loaded else { "status": "unloaded", "regionId": region_id }
	if signature != "":
		install_result["signature"] = signature
		var metrics: Dictionary = region_metrics_by_region.get(region_id, {})
		metrics["signature"] = signature
		region_metrics_by_region[region_id] = metrics
	region_states[region_id] = "installed" if String(install_result.get("status", "")) == "installed" else String(install_result.get("status", "unloaded"))
	topology_revision += 1
	registered_region_count += 1
	return {
		"status": region_states[region_id],
		"regionId": region_id,
		"tileKey": String(descriptor.get("tile_key")),
		"topologyRevision": topology_revision,
		"installed": String(install_result.get("status", "")) == "installed",
		"install": install_result,
		"signature": signature
	}

func unregister_chunk(region_id: String) -> Dictionary:
	if not descriptors_by_region.has(region_id):
		_release_region(region_id)
		_clear_dirty_region(region_id)
		return { "status": "missing", "regionId": region_id, "topologyRevision": topology_revision }
	_release_region(region_id)
	descriptors_by_region.erase(region_id)
	region_states[region_id] = "unregistered"
	region_metrics_by_region.erase(region_id)
	_clear_dirty_region(region_id)
	topology_revision += 1
	unregistered_region_count += 1
	return { "status": "unregistered", "regionId": region_id, "topologyRevision": topology_revision }

func register_tile_snapshot(snapshot: Dictionary) -> Dictionary:
	var descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(snapshot)
	return register_chunk_descriptor(descriptor)

func register_semantic_descriptor(kind: String, region_id: String, bounds: AABB, metadata := {}) -> Dictionary:
	if region_id == "":
		return { "status": "rejected", "reason": "missing_region_id" }
	var descriptor = NavigationBakeDescriptorScript.from_semantic_region(kind, region_id, bounds, metadata)
	return register_chunk_descriptor(descriptor)

func apply_navigation_events(events: Array) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for event_value in events:
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value
		var tile_key := String(event.get("tileKey", ""))
		var kinds: Array = event.get("changeKinds", [])
		if tile_key == "":
			continue
		var region_id := NavigationBakeDescriptorScript.chunk_region_id(tile_key)
		if _has_kind(kinds, NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED):
			results.append(unregister_chunk(region_id))
		elif _has_kind(kinds, NpcEnumsScript.CHANGE_KIND_DOOR_STATE):
			dynamic_revision += 1
			results.append({ "status": "dynamic", "regionId": region_id, "dynamicRevision": dynamic_revision })
		elif _event_needs_rebuild(kinds):
			topology_revision += 1
			results.append(_mark_dirty_region(region_id, event, "navigation_event"))
	return results

func process_dirty_regions(max_jobs := 1, max_usec := 4000) -> Array[Dictionary]:
	var started := Time.get_ticks_usec()
	var results: Array[Dictionary] = []
	var jobs := maxi(0, max_jobs)
	for region_id_value in dirty_region_queue.duplicate():
		if jobs > 0 and results.size() >= jobs:
			break
		if max_usec > 0 and Time.get_ticks_usec() - started >= max_usec:
			break
		var region_id := String(region_id_value)
		dirty_region_queue.erase(region_id)
		var dirty_record: Dictionary = dirty_regions_by_region.get(region_id, {})
		if not descriptors_by_region.has(region_id):
			dirty_regions_by_region.erase(region_id)
			region_states[region_id] = "missing"
			results.append({ "status": "missing", "regionId": region_id, "dirty": dirty_record })
			continue
		var descriptor = descriptors_by_region[region_id]
		if descriptor == null:
			dirty_regions_by_region.erase(region_id)
			region_states[region_id] = "missing"
			results.append({ "status": "missing_descriptor", "regionId": region_id, "dirty": dirty_record })
			continue
		_release_region(region_id)
		var install_result := _install_region(region_id, descriptor) if bool(descriptor.get("loaded")) else { "status": "unloaded", "regionId": region_id }
		region_states[region_id] = "installed" if String(install_result.get("status", "")) == "installed" else String(install_result.get("status", "unloaded"))
		dirty_regions_by_region.erase(region_id)
		rebuild_count += 1
		last_rebuild_usec = Time.get_ticks_usec() - started
		results.append({
			"status": "rebuilt" if String(install_result.get("status", "")) == "installed" else String(install_result.get("status", "unloaded")),
			"regionId": region_id,
			"install": install_result,
			"dirty": dirty_record,
			"topologyRevision": topology_revision,
			"rebuildCount": rebuild_count
		})
	return results

func set_door_portal_state(portal_or_id, state_value := "", metadata := {}) -> Dictionary:
	var portal_state := {}
	if portal_or_id is Dictionary:
		portal_state = (portal_or_id as Dictionary).duplicate(true)
	else:
		portal_state = metadata.duplicate(true) if metadata is Dictionary else {}
		portal_state["portalId"] = String(portal_or_id)
	if String(state_value) != "":
		portal_state["state"] = String(state_value)
	elif portal_state.has("open"):
		portal_state["state"] = String(NpcEnumsScript.DOOR_STATE_OPEN if bool(portal_state.get("open", false)) else NpcEnumsScript.DOOR_STATE_CLOSED)
	var portal_id := String(portal_state.get("portalId", portal_state.get("id", "")))
	if portal_id == "":
		return { "status": "rejected", "reason": "missing_portal_id" }
	portal_state["portalId"] = portal_id
	door_portal_states[portal_id] = portal_state
	var updated := 0
	for record in door_link_records_by_portal.get(portal_id, []):
		if not (record is Dictionary):
			continue
		_apply_portal_state_to_link_record(record, portal_state)
		updated += 1
	door_link_state_revision += 1
	dynamic_revision += 1
	return {
		"status": "updated" if updated > 0 else "recorded",
		"portalId": portal_id,
		"updatedLinks": updated,
		"doorLinkStateRevision": door_link_state_revision,
		"dynamicRevision": dynamic_revision
	}

func closest_walkable(position: Vector3, max_distance := INF) -> Dictionary:
	var server_result := _closest_walkable_from_server(position, max_distance)
	if bool(server_result.get("found", false)):
		return server_result
	var descriptor_result := _closest_walkable_from_descriptors(position, max_distance)
	if bool(descriptor_result.get("found", false)):
		if not server_result.is_empty():
			descriptor_result["serverFallbackReason"] = String(server_result.get("reason", "navigation_server_not_found"))
		return descriptor_result
	return server_result if not server_result.is_empty() else descriptor_result

func query_route(start: Vector3, target: Vector3, options := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	path_query_count += 1
	if not backend_config.use_navmesh():
		return _finish_route_query(started, _route_query_failure("disabled", "navmesh_backend_disabled", start, target, options), options)
	if not navigation_map.is_valid() or region_rids_by_region.is_empty():
		return _finish_route_query(started, _route_query_failure("blocked", "missing_navmesh_regions", start, target, options), options)
	var max_snap := float(options.get("maxSnapDistance", INF))
	var start_max_snap := float(options.get("startMaxSnapDistance", max_snap))
	var target_max_snap := float(options.get("targetMaxSnapDistance", max_snap))
	var query_api_used := _route_query_api(options)
	var prefer_descriptor_endpoint := bool(options.get("preferDescriptorEndpoint", false))
	var start_walkable := _closest_walkable_for_query_endpoint(start, start_max_snap, query_api_used, prefer_descriptor_endpoint)
	if not bool(start_walkable.get("found", false)):
		return _finish_route_query(started, _route_query_failure("blocked", "no_start_server_walkable", start, target, options, {
			"startWalkable": start_walkable,
			"descriptorStartWalkable": _closest_walkable_from_descriptors(start, start_max_snap)
		}), options)
	var target_walkable := _closest_walkable_for_query_endpoint(target, target_max_snap, query_api_used, prefer_descriptor_endpoint)
	if not bool(target_walkable.get("found", false)):
		return _finish_route_query(started, _route_query_failure("blocked", "no_target_server_walkable", start, target, options, {
			"startWalkable": start_walkable,
			"targetWalkable": target_walkable,
			"descriptorTargetWalkable": _closest_walkable_from_descriptors(target, target_max_snap)
		}), options)
	var query_start: Vector3 = start_walkable.get("position", start)
	var query_target: Vector3 = target_walkable.get("position", target)
	var preflight_door_route := _direct_door_route_for_points(query_start, query_target, [], options)
	if not preflight_door_route.is_empty():
		var preflight_path: Array[Vector3] = []
		for point in preflight_door_route.get("path", []):
			if point is Vector3:
				preflight_path.append(point)
		var preflight_actions: Dictionary = preflight_door_route.get("actions", {}) if preflight_door_route.get("actions", {}) is Dictionary else {}
		if not preflight_path.is_empty():
			return _finish_route_query(started, {
				"ok": true,
				"status": "complete",
				"reason": "",
				"source": "navmesh",
				"queryApi": "direct_door_route",
				"start": start,
				"target": target,
				"startPosition": query_start,
				"targetPosition": query_target,
				"path": preflight_path,
				"pointCount": preflight_path.size(),
				"distance": float(preflight_door_route.get("distance", _path_distance(preflight_path))),
				"actions": preflight_actions,
				"doorLinks": _door_links_for_actions(preflight_actions),
				"snapshotRevision": revision(),
				"options": _route_options_summary(options),
				"startWalkable": start_walkable,
				"targetWalkable": target_walkable
			}, options)
	if _descriptor_direct_endpoint_route_allowed(start_walkable, target_walkable, query_start, query_target, options):
		var preflight_descriptor_path: Array[Vector3] = []
		preflight_descriptor_path.append(query_start)
		preflight_descriptor_path.append(query_target)
		return _finish_route_query(started, {
			"ok": true,
			"status": "complete",
			"reason": "",
			"source": "navmesh",
			"queryApi": "descriptor_direct_endpoint",
			"start": start,
			"target": target,
			"startPosition": query_start,
			"targetPosition": query_target,
			"path": preflight_descriptor_path,
			"pointCount": preflight_descriptor_path.size(),
			"distance": _path_distance(preflight_descriptor_path),
			"actions": {},
			"doorLinks": [],
			"snapshotRevision": revision(),
			"options": _route_options_summary(options),
			"startWalkable": start_walkable,
			"targetWalkable": target_walkable
		}, options)
	if not _route_endpoint_owned_by_server(start_walkable) or not _route_endpoint_owned_by_server(target_walkable):
		var direct_door_route := _direct_door_route_for_points(query_start, query_target, [], options)
		if not direct_door_route.is_empty():
			var direct_path: Array[Vector3] = []
			for point in direct_door_route.get("path", []):
				if point is Vector3:
					direct_path.append(point)
			var direct_actions: Dictionary = direct_door_route.get("actions", {}) if direct_door_route.get("actions", {}) is Dictionary else {}
			if not direct_path.is_empty():
				return _finish_route_query(started, {
					"ok": true,
					"status": "complete",
					"reason": "",
					"source": "navmesh",
					"queryApi": "direct_door_route",
					"start": start,
					"target": target,
					"startPosition": query_start,
					"targetPosition": query_target,
					"path": direct_path,
					"pointCount": direct_path.size(),
					"distance": float(direct_door_route.get("distance", _path_distance(direct_path))),
					"actions": direct_actions,
					"doorLinks": _door_links_for_actions(direct_actions),
					"snapshotRevision": revision(),
					"options": _route_options_summary(options),
					"startWalkable": start_walkable,
					"targetWalkable": target_walkable
				}, options)
		if _descriptor_direct_endpoint_route_allowed(start_walkable, target_walkable, query_start, query_target, options):
			var descriptor_path: Array[Vector3] = []
			descriptor_path.append(query_start)
			descriptor_path.append(query_target)
			return _finish_route_query(started, {
				"ok": true,
				"status": "complete",
				"reason": "",
				"source": "navmesh",
				"queryApi": "descriptor_direct_endpoint",
				"start": start,
				"target": target,
				"startPosition": query_start,
				"targetPosition": query_target,
				"path": descriptor_path,
				"pointCount": descriptor_path.size(),
				"distance": _path_distance(descriptor_path),
				"actions": {},
				"doorLinks": [],
				"snapshotRevision": revision(),
				"options": _route_options_summary(options),
				"startWalkable": start_walkable,
				"targetWalkable": target_walkable
			}, options)
		if query_api_used == "query_path" and _descriptor_endpoint_query_attempt_allowed(start_walkable, target_walkable):
			pass
		else:
			return _finish_route_query(started, _route_query_failure("blocked", "endpoint_not_server_walkable", start, target, options, {
				"startWalkable": start_walkable,
				"targetWalkable": target_walkable
			}), options)
	var path: Array[Vector3] = _query_path_points(query_start, query_target, options)
	if path.is_empty():
		var map_readiness := _navigation_map_readiness(false)
		if not bool(map_readiness.get("ready", false)):
			return _finish_route_query(started, _route_query_failure("pending", String(map_readiness.get("reason", "navigation_map_sync_pending")), start, target, options, {
				"startWalkable": start_walkable,
				"targetWalkable": target_walkable,
				"navigationMapReadiness": map_readiness
			}), options)
		if _server_same_surface_direct_route_allowed(start_walkable, target_walkable, query_start, query_target):
			path = [query_start, query_target]
		else:
			return _finish_route_query(started, _route_query_failure("blocked", "no_route", start, target, options, {
				"startWalkable": start_walkable,
				"targetWalkable": target_walkable
			}), options)
	var endpoint_check := _path_endpoint_check(path, query_target, options)
	if not bool(endpoint_check.get("ok", false)):
		var fallback_endpoint_check := {}
		if query_api_used == "query_path" and NavigationServer3D.has_method("map_get_path"):
			var fallback_options := options.duplicate(true)
			fallback_options["queryApi"] = "map_get_path"
			var fallback_path: Array[Vector3] = _query_path_points(query_start, query_target, fallback_options)
			fallback_endpoint_check = _path_endpoint_check(fallback_path, query_target, options)
			if bool(fallback_endpoint_check.get("ok", false)):
				path = fallback_path
				endpoint_check = fallback_endpoint_check
				query_api_used = "map_get_path_endpoint_retry"
		if bool(endpoint_check.get("ok", false)):
			pass
		elif _endpoint_completion_allowed(path, endpoint_check, start_walkable, target_walkable, query_target, options):
			var original_endpoint_check := endpoint_check.duplicate(true)
			path.append(query_target)
			endpoint_check = _path_endpoint_check(path, query_target, options)
			endpoint_check["completedByAppendingTarget"] = true
			endpoint_check["originalEndpoint"] = original_endpoint_check.get("endpoint", Vector3.ZERO)
			endpoint_check["originalFlatDistance"] = original_endpoint_check.get("flatDistance", INF)
			query_api_used = "%s_endpoint_completed" % query_api_used
		else:
			var partial_endpoint: Vector3 = endpoint_check.get("endpoint", path[path.size() - 1] if not path.is_empty() else query_start)
			var start_flat_distance := Vector2(query_start.x - query_target.x, query_start.z - query_target.z).length()
			var endpoint_flat_distance := float(endpoint_check.get("flatDistance", INF))
			var route_kind := String(options.get("kind", ""))
			var home_or_scripted := route_kind == "scripted" or route_kind == "home" or bool(options.get("movingHome", false))
			if home_or_scripted and path.size() >= 2 and endpoint_flat_distance + CELL * 0.5 < start_flat_distance:
				return _finish_route_query(started, {
					"ok": true,
					"status": "partial",
					"reason": "path_endpoint_partial",
					"source": "navmesh",
					"queryApi": query_api_used,
					"start": start,
					"target": target,
					"startPosition": query_start,
					"targetPosition": partial_endpoint,
					"fallbackCell": _cell_for_position(partial_endpoint),
					"path": path,
					"actions": {},
					"doorLinks": [],
					"distance": _path_distance(path),
					"pointCount": path.size(),
					"snapshotRevision": revision(),
					"options": _route_options_summary(options),
					"startWalkable": start_walkable,
					"targetWalkable": target_walkable,
					"endpoint": endpoint_check,
					"endpointRetry": fallback_endpoint_check
				}, options)
			return _finish_route_query(started, _route_query_failure("blocked", "path_endpoint_mismatch", start, target, options, {
				"startWalkable": start_walkable,
				"targetWalkable": target_walkable,
				"endpoint": endpoint_check,
				"endpointRetry": fallback_endpoint_check,
				"pathPointCount": path.size()
			}), options)
	var forbidden_door_links := _forbidden_door_links_for_path(path, options)
	if not forbidden_door_links.is_empty():
		return _finish_route_query(started, _route_query_failure("blocked", "forbidden_private_door_link", start, target, options, {
			"startWalkable": start_walkable,
			"targetWalkable": target_walkable,
			"forbiddenDoorLinks": forbidden_door_links,
			"pathPointCount": path.size()
		}), options)
	var door_actions := _door_actions_for_path(path, options)
	if door_actions.is_empty():
		var direct_door_route := _direct_door_route_for_points(query_start, query_target, path, options)
		if not direct_door_route.is_empty():
			var direct_path: Array[Vector3] = []
			for point in direct_door_route.get("path", []):
				if point is Vector3:
					direct_path.append(point)
			if not direct_path.is_empty():
				path = direct_path
			door_actions = direct_door_route.get("actions", {})
	return _finish_route_query(started, {
		"ok": true,
		"status": "complete",
		"reason": "",
		"source": "navmesh",
		"queryApi": query_api_used,
		"start": start,
		"target": target,
		"startPosition": query_start,
		"targetPosition": query_target,
		"path": path,
		"actions": door_actions,
		"doorLinks": _door_links_for_actions(door_actions),
		"distance": _path_distance(path),
		"pointCount": path.size(),
		"snapshotRevision": revision(),
		"options": _route_options_summary(options),
		"startWalkable": start_walkable,
		"targetWalkable": target_walkable
	}, options)

func _route_endpoint_owned_by_server(walkable: Dictionary) -> bool:
	var source := String(walkable.get("source", ""))
	return source.begins_with("navigation_server") and String(walkable.get("regionId", "")) != ""

func _route_regions_connected(start_walkable: Dictionary, target_walkable: Dictionary) -> bool:
	var start_region_id := String(start_walkable.get("regionId", ""))
	var target_region_id := String(target_walkable.get("regionId", ""))
	if start_region_id == "" or target_region_id == "" or start_region_id == target_region_id:
		return true
	if not region_rids_by_region.has(start_region_id) or not region_rids_by_region.has(target_region_id):
		return false
	return false

func actor_path_status(actor_id := "") -> Dictionary:
	if String(actor_id) == "":
		var actors := {}
		var keys := actor_path_records.keys()
		keys.sort()
		for key_value in keys:
			var key := String(key_value)
			actors[key] = _actor_path_record_with_age(actor_path_records[key])
		return {
			"status": "ok",
			"count": actors.size(),
			"revision": revision(),
			"actors": actors
		}
	var id := String(actor_id)
	if not actor_path_records.has(id):
		return {
			"actorId": id,
			"status": "unknown",
			"reason": "no_query_record",
			"revision": revision()
		}
	return _actor_path_record_with_age(actor_path_records[id])

func debug_snapshot() -> Dictionary:
	var regions := {}
	var keys := descriptors_by_region.keys()
	keys.sort()
	for region_id in keys:
		var descriptor = descriptors_by_region[region_id]
		regions[String(region_id)] = descriptor.to_summary() if descriptor != null and descriptor.has_method("to_summary") else {}
		if region_metrics_by_region.has(region_id):
			regions[String(region_id)]["installMetrics"] = region_metrics_by_region[region_id].duplicate(true)
	return {
		"backend": backend_config.to_summary(),
		"hasNavigationMap": navigation_map.is_valid(),
		"navigationMapReadiness": _navigation_map_readiness(false),
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"regions": regions,
		"regionStates": region_states.duplicate(true),
		"dirtyRegions": _dirty_regions_summary(),
		"doorLinks": _door_links_debug_summary(),
		"doorPortalStates": _door_portal_states_summary(),
		"actorPathStatus": actor_path_status(),
		"installedRegionCount": region_rids_by_region.size(),
		"installedSurfaceCount": installed_surface_count,
		"installedDoorLinkCount": installed_door_link_count
	}

func tile_region_status(tile_key: String) -> Dictionary:
	var region_id := NavigationBakeDescriptorScript.chunk_region_id(tile_key)
	var descriptor = descriptors_by_region.get(region_id)
	var surface_count := 0
	if descriptor != null:
		var surfaces = descriptor.get("walkable_surfaces")
		if surfaces is Array:
			surface_count = surfaces.size()
	var metrics: Dictionary = region_metrics_by_region.get(region_id, {})
	return {
		"tileKey": tile_key,
		"regionId": region_id,
		"registered": descriptor != null,
		"state": String(region_states.get(region_id, "")),
		"surfaceCount": surface_count,
		"installed": region_rids_by_region.has(region_id),
		"dirty": dirty_regions_by_region.has(region_id),
		"installStatus": String(metrics.get("status", ""))
	}

func sync_navigation_map_if_dirty() -> bool:
	return _sync_navigation_map_if_dirty()

func navigation_map_readiness() -> Dictionary:
	return _navigation_map_readiness(false)

func reset_timing_stats() -> void:
	last_install_usec = 0
	install_duration_samples_usec.clear()
	last_path_query_usec = 0
	total_path_query_usec = 0
	max_path_query_usec = 0
	path_query_count = 0
	path_query_failure_count = 0
	path_query_duration_samples_usec.clear()
	slowest_path_query.clear()

func stats() -> Dictionary:
	return {
		"backend": backend_config.backend,
		"navmeshEnabled": backend_config.use_navmesh(),
		"hasNavigationMap": navigation_map.is_valid(),
		"navigationMapReadiness": _navigation_map_readiness(false),
		"regionCount": descriptors_by_region.size(),
		"installedRegionCount": region_rids_by_region.size(),
		"installedSurfaceCount": installed_surface_count,
		"installedDoorLinkCount": installed_door_link_count,
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"doorLinkStateRevision": door_link_state_revision,
		"registeredRegionCount": registered_region_count,
		"unregisteredRegionCount": unregistered_region_count,
		"lastInstallUsec": last_install_usec,
		"installP95Usec": _percentile_usec(install_duration_samples_usec, 0.95),
		"dirtyRegionCount": dirty_regions_by_region.size(),
		"dirtyRegionQueueCount": dirty_region_queue.size(),
		"rebuildCount": rebuild_count,
		"lastRebuildUsec": last_rebuild_usec,
		"actorPathStatusCount": actor_path_records.size(),
		"doorLinkInstallFailureCount": door_link_install_failure_count,
		"linkApiSupported": _link_api_supported(),
		"pathQueryCount": path_query_count,
		"pathQueryFailureCount": path_query_failure_count,
		"lastPathQueryUsec": last_path_query_usec,
		"avgPathQueryUsec": float(total_path_query_usec) / float(maxi(1, path_query_count)),
		"maxPathQueryUsec": max_path_query_usec,
		"pathQueryP95Usec": _percentile_usec(path_query_duration_samples_usec, 0.95),
		"slowestPathQuery": slowest_path_query.duplicate(true)
	}

func revision() -> String:
	return "%d:%d" % [topology_revision, dynamic_revision]

func topology_revision_key() -> String:
	return str(topology_revision)

func _closest_walkable_from_descriptors(position: Vector3, max_distance := INF) -> Dictionary:
	var nearby_keys := _descriptor_region_ids_near_position(position, max_distance)
	if not nearby_keys.is_empty() and nearby_keys.size() < descriptors_by_region.size():
		var nearby_result := _closest_walkable_from_descriptor_keys(position, max_distance, nearby_keys)
		if bool(nearby_result.get("found", false)):
			return nearby_result
		if max_distance < INF:
			return nearby_result
	return _closest_walkable_from_descriptor_keys(position, max_distance, _sorted_descriptor_region_ids())

func _closest_walkable_from_descriptor_keys(position: Vector3, max_distance: float, keys: Array) -> Dictionary:
	var best := {}
	var best_distance := INF
	for region_id in keys:
		var descriptor = descriptors_by_region[region_id]
		if descriptor == null or not bool(descriptor.get("loaded")):
			continue
		var descriptor_bounds: AABB = descriptor.get("bounds")
		if descriptor_bounds.size != Vector3.ZERO and _aabb_distance_to_position(descriptor_bounds, position) > max_distance:
			continue
		var surfaces: Array = descriptor.get("walkable_surfaces")
		for surface in surfaces:
			var closest: Vector3 = _closest_point_on_surface(surface, position)
			var distance := position.distance_to(closest)
			if distance <= max_distance and distance < best_distance:
				best_distance = distance
				best = {
					"found": true,
					"regionId": String(region_id),
					"surfaceId": String(surface.get("id", "")),
					"position": closest,
					"distance": distance
				}
	if best.is_empty():
		return { "found": false, "reason": "no_walkable_surface", "position": position, "maxDistance": max_distance }
	return best

func _aabb_distance_to_position(bounds: AABB, position: Vector3) -> float:
	var min_corner := bounds.position
	var max_corner := bounds.position + bounds.size
	var dx := maxf(maxf(min_corner.x - position.x, 0.0), position.x - max_corner.x)
	var dy := maxf(maxf(min_corner.y - position.y, 0.0), position.y - max_corner.y)
	var dz := maxf(maxf(min_corner.z - position.z, 0.0), position.z - max_corner.z)
	return sqrt(dx * dx + dy * dy + dz * dz)

func _closest_point_on_surface(surface: Dictionary, position: Vector3) -> Vector3:
	var center: Vector3 = surface.get("center", Vector3.ZERO)
	var size: Vector3 = surface.get("size", Vector3.ONE)
	var half_x := maxf(size.x, 0.01) * 0.5
	var half_z := maxf(size.z, 0.01) * 0.5
	return Vector3(
		clampf(position.x, center.x - half_x, center.x + half_x),
		center.y,
		clampf(position.z, center.z - half_z, center.z + half_z)
	)

func _ensure_navigation_map() -> void:
	if navigation_map.is_valid():
		return
	navigation_map = NavigationServer3D.map_create()
	if NavigationServer3D.has_method("map_set_active"):
		NavigationServer3D.call("map_set_active", navigation_map, true)
	if NavigationServer3D.has_method("map_set_edge_connection_margin"):
		NavigationServer3D.call("map_set_edge_connection_margin", navigation_map, EDGE_CONNECTION_MARGIN)
	if NavigationServer3D.has_method("map_set_use_edge_connections"):
		NavigationServer3D.call("map_set_use_edge_connections", navigation_map, true)
	if NavigationServer3D.has_method("map_set_link_connection_radius"):
		NavigationServer3D.call("map_set_link_connection_radius", navigation_map, LINK_CONNECTION_RADIUS)
	owns_navigation_map = true

func _install_region(region_id: String, descriptor) -> Dictionary:
	var started := Time.get_ticks_usec()
	var navigation_mesh = _build_navigation_mesh(descriptor)
	var polygon_count := int(navigation_mesh.get_polygon_count()) if navigation_mesh != null and navigation_mesh.has_method("get_polygon_count") else 0
	var vertex_count := int(navigation_mesh.get_vertices().size()) if navigation_mesh != null and navigation_mesh.has_method("get_vertices") else 0
	if polygon_count <= 0:
		region_metrics_by_region[region_id] = { "status": "empty", "polygonCount": 0, "vertexCount": vertex_count }
		return { "status": "empty", "regionId": region_id, "polygonCount": 0, "vertexCount": vertex_count }
	var region_rid := NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region_rid, navigation_map)
	NavigationServer3D.region_set_navigation_mesh(region_rid, navigation_mesh)
	if NavigationServer3D.has_method("region_set_use_edge_connections"):
		NavigationServer3D.call("region_set_use_edge_connections", region_rid, true)
	if NavigationServer3D.has_method("region_set_enabled"):
		NavigationServer3D.call("region_set_enabled", region_rid, true)
	_mark_navigation_map_dirty()
	region_rids_by_region[region_id] = region_rid
	region_ids_by_rid[region_rid] = region_id
	var link_metrics := _install_door_links_for_region(region_id, descriptor)
	last_install_usec = Time.get_ticks_usec() - started
	_record_timing_sample(install_duration_samples_usec, last_install_usec)
	installed_region_count += 1
	installed_surface_count += polygon_count
	var metrics := {
		"status": "installed",
		"polygonCount": polygon_count,
		"vertexCount": vertex_count,
		"durationUsec": last_install_usec,
		"doorLinks": link_metrics
	}
	region_metrics_by_region[region_id] = metrics
	return metrics.duplicate(true)

func _build_navigation_mesh(descriptor):
	var navigation_mesh := NavigationMesh.new()
	var vertices := PackedVector3Array()
	var vertex_indices := {}
	var polygons: Array[PackedInt32Array] = []
	var surfaces: Array = descriptor.get("walkable_surfaces")
	var sorted_surfaces: Array = surfaces.duplicate()
	sorted_surfaces.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	for polygon_points in _navigation_mesh_polygons_for_surfaces(sorted_surfaces):
		if polygon_points.size() < 3:
			continue
		var indices := PackedInt32Array()
		for point in polygon_points:
			var vertex_key := _navigation_mesh_vertex_key(point)
			if vertex_indices.has(vertex_key):
				indices.append(int(vertex_indices[vertex_key]))
			else:
				vertex_indices[vertex_key] = vertices.size()
				indices.append(vertices.size())
				vertices.append(point)
		polygons.append(indices)
	navigation_mesh.set_vertices(vertices)
	for polygon in polygons:
		navigation_mesh.add_polygon(polygon)
	return navigation_mesh

func _navigation_mesh_vertex_key(point: Vector3) -> String:
	return "%d:%d:%d" % [
		roundi(point.x * 1000.0),
		roundi(point.y * 1000.0),
		roundi(point.z * 1000.0)
	]

func _navigation_mesh_polygons_for_surfaces(sorted_surfaces: Array) -> Array:
	var result := []
	var layers := {}
	for surface_value in sorted_surfaces:
		if not (surface_value is Dictionary):
			continue
		var surface: Dictionary = surface_value
		if not bool(surface.get("walkable", true)):
			continue
		if not _surface_mergeable_for_mesh(surface):
			var polygon := _surface_polygon(surface)
			if polygon.size() >= 3:
				result.append(polygon)
			continue
		var cell: Vector3i = surface.get("cell")
		var center: Vector3 = surface.get("center", Vector3(float(cell.x) * CELL, float(cell.y) * CELL, float(cell.z) * CELL))
		var layer_key := "%d:%d" % [cell.y, roundi(center.y * 100.0)]
		if not layers.has(layer_key):
			layers[layer_key] = {
				"cells": {},
				"y": center.y
			}
		var layer: Dictionary = layers[layer_key]
		var grid: Dictionary = layer.get("cells", {})
		grid[Vector2i(cell.x, cell.z)] = true
	for layer_key in layers.keys():
		var layer: Dictionary = layers[layer_key]
		var grid: Dictionary = layer.get("cells", {})
		result.append_array(_merged_grid_polygons(grid, float(layer.get("y", 0.0))))
	return result

func _surface_mergeable_for_mesh(surface: Dictionary) -> bool:
	if surface.has("polygon"):
		var polygon_value = surface.get("polygon", [])
		if polygon_value is Array and polygon_value.size() >= 3:
			return false
	var cell_value = surface.get("cell")
	if not (cell_value is Vector3i):
		return false
	var size: Vector3 = surface.get("size", Vector3(CELL, 0.05, CELL))
	return absf(size.x - CELL) <= CELL * 0.05 and absf(size.z - CELL) <= CELL * 0.05

func _merged_grid_polygons(grid: Dictionary, y: float) -> Array:
	var result := []
	var keys: Array = grid.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y == b.y:
			return a.x < b.x
		return a.y < b.y
	)
	var visited := {}
	for key_value in keys:
		if not (key_value is Vector2i):
			continue
		var start: Vector2i = key_value
		if visited.has(start):
			continue
		var end_x := start.x
		while grid.has(Vector2i(end_x + 1, start.y)) and not visited.has(Vector2i(end_x + 1, start.y)):
			end_x += 1
		var end_z := start.y
		var can_extend := true
		while can_extend:
			var next_z := end_z + 1
			for x in range(start.x, end_x + 1):
				if not grid.has(Vector2i(x, next_z)) or visited.has(Vector2i(x, next_z)):
					can_extend = false
					break
			if can_extend:
				end_z = next_z
		for z in range(start.y, end_z + 1):
			for x in range(start.x, end_x + 1):
				visited[Vector2i(x, z)] = true
		var min_x := float(start.x) * CELL - CELL * 0.5
		var max_x := float(end_x) * CELL + CELL * 0.5
		var min_z := float(start.y) * CELL - CELL * 0.5
		var max_z := float(end_z) * CELL + CELL * 0.5
		result.append([
			Vector3(min_x, y, min_z),
			Vector3(min_x, y, max_z),
			Vector3(max_x, y, max_z),
			Vector3(max_x, y, min_z)
		])
	return result

func _surface_polygon(surface: Dictionary) -> Array[Vector3]:
	var polygon_value = surface.get("polygon", [])
	if polygon_value is Array and polygon_value.size() >= 3:
		var polygon: Array[Vector3] = []
		for point in polygon_value:
			if point is Vector3:
				polygon.append(point)
		if polygon.size() >= 3:
			return polygon
	var center: Vector3 = surface.get("center", Vector3.ZERO)
	var size: Vector3 = surface.get("size", Vector3.ONE)
	var half_x := maxf(size.x, 0.01) * 0.5
	var half_z := maxf(size.z, 0.01) * 0.5
	return [
		Vector3(center.x - half_x, center.y, center.z - half_z),
		Vector3(center.x - half_x, center.y, center.z + half_z),
		Vector3(center.x + half_x, center.y, center.z + half_z),
		Vector3(center.x + half_x, center.y, center.z - half_z)
	]

func _release_region(region_id: String) -> void:
	_release_door_links_for_region(region_id)
	if not region_rids_by_region.has(region_id):
		return
	var region_rid: RID = region_rids_by_region[region_id]
	if region_rid.is_valid():
		NavigationServer3D.free_rid(region_rid)
		_mark_navigation_map_dirty()
	region_rids_by_region.erase(region_id)
	region_ids_by_rid.erase(region_rid)
	var metrics: Dictionary = region_metrics_by_region.get(region_id, {})
	installed_surface_count = maxi(0, installed_surface_count - int(metrics.get("polygonCount", 0)))

func _closest_walkable_from_server(position: Vector3, max_distance := INF) -> Dictionary:
	if not navigation_map.is_valid() or region_rids_by_region.is_empty():
		return {}
	if not NavigationServer3D.has_method("map_get_closest_point") or not NavigationServer3D.has_method("map_get_closest_point_owner"):
		return {}
	var direct_result := _server_closest_for_sample(position, position, max_distance, "navigation_server")
	if bool(direct_result.get("found", false)):
		return direct_result
	var probe_result := _descriptor_guided_server_probe(position, max_distance)
	if bool(probe_result.get("found", false)):
		return probe_result
	return direct_result

func _closest_walkable_for_query_endpoint(position: Vector3, max_distance: float, query_api_used: String, prefer_descriptor_endpoint: bool) -> Dictionary:
	var cache_key := _endpoint_query_cache_key(position, max_distance, query_api_used, prefer_descriptor_endpoint)
	if endpoint_query_cache.has(cache_key):
		return (endpoint_query_cache[cache_key] as Dictionary).duplicate(true)
	var result := {}
	if query_api_used == "map_get_path":
		result = _closest_walkable_from_server(position, max_distance)
		if not bool(result.get("found", false)):
			result = _closest_walkable_for_direct_route_endpoint(position, max_distance)
	elif prefer_descriptor_endpoint:
		var server_endpoint := _closest_walkable_from_server(position, max_distance)
		var descriptor_endpoint := _closest_installed_descriptor_route_endpoint(position, max_distance)
		if bool(server_endpoint.get("found", false)) and _route_endpoint_owned_by_server(server_endpoint):
			result = server_endpoint
		elif bool(descriptor_endpoint.get("found", false)):
			if bool(server_endpoint.get("found", false)):
				descriptor_endpoint["serverFallbackReason"] = "server_endpoint_missing_region"
			result = descriptor_endpoint
		else:
			result = server_endpoint if not server_endpoint.is_empty() else descriptor_endpoint
	else:
		result = _closest_walkable_for_route_endpoint(position, max_distance)
	_store_endpoint_query_cache(cache_key, result)
	return result.duplicate(true)

func _endpoint_query_cache_key(position: Vector3, max_distance: float, query_api_used: String, prefer_descriptor_endpoint: bool) -> String:
	var quantized := Vector3i(roundi(position.x * 10.0), roundi(position.y * 10.0), roundi(position.z * 10.0))
	var max_key := "inf" if max_distance >= INF * 0.5 else str(roundi(max_distance * 100.0))
	return "%d|%s|%s|%s|%d,%d,%d" % [
		topology_revision,
		query_api_used,
		str(prefer_descriptor_endpoint),
		max_key,
		quantized.x,
		quantized.y,
		quantized.z
	]

func _store_endpoint_query_cache(cache_key: String, result: Dictionary) -> void:
	if cache_key == "" or result.is_empty():
		return
	if not endpoint_query_cache.has(cache_key):
		endpoint_query_cache_order.append(cache_key)
	endpoint_query_cache[cache_key] = result.duplicate(true)
	while endpoint_query_cache_order.size() > ENDPOINT_QUERY_CACHE_LIMIT:
		var evicted: String = endpoint_query_cache_order.pop_front()
		endpoint_query_cache.erase(evicted)

func _closest_installed_descriptor_route_endpoint(position: Vector3, max_distance := INF) -> Dictionary:
	var descriptor_result := _closest_walkable_from_descriptors(position, max_distance)
	if not bool(descriptor_result.get("found", false)):
		return descriptor_result
	var region_id := String(descriptor_result.get("regionId", ""))
	if region_id == "" or not region_rids_by_region.has(region_id):
		var missing_region := descriptor_result.duplicate(true)
		missing_region["found"] = false
		missing_region["reason"] = "descriptor_region_not_installed"
		missing_region["serverFallbackReason"] = "descriptor_preferred"
		return missing_region
	var endpoint := descriptor_result.duplicate(true)
	endpoint["source"] = "installed_descriptor_endpoint"
	endpoint["serverFallbackReason"] = "descriptor_preferred"
	return endpoint

func _closest_walkable_for_route_endpoint(position: Vector3, max_distance := INF) -> Dictionary:
	var server_result := _closest_walkable_from_server(position, max_distance)
	if bool(server_result.get("found", false)):
		return server_result
	var descriptor_result := _closest_walkable_from_descriptors(position, max_distance)
	if not bool(descriptor_result.get("found", false)):
		return server_result if not server_result.is_empty() else descriptor_result
	var region_id := String(descriptor_result.get("regionId", ""))
	if region_id == "" or not region_rids_by_region.has(region_id):
		var missing_region := descriptor_result.duplicate(true)
		missing_region["found"] = false
		missing_region["reason"] = "descriptor_region_not_installed"
		if not server_result.is_empty():
			missing_region["serverFallbackReason"] = String(server_result.get("reason", "navigation_server_owner_missing"))
		return missing_region
	var endpoint := descriptor_result.duplicate(true)
	endpoint["source"] = "installed_descriptor_endpoint"
	endpoint["serverFallbackReason"] = String(server_result.get("reason", "navigation_server_owner_missing")) if not server_result.is_empty() else "navigation_server_owner_missing"
	return endpoint

func _closest_walkable_for_direct_route_endpoint(position: Vector3, max_distance := INF) -> Dictionary:
	var descriptor_result := _closest_walkable_from_descriptors(position, max_distance)
	if bool(descriptor_result.get("found", false)):
		descriptor_result["source"] = "descriptor_direct_endpoint"
		return descriptor_result
	return _closest_walkable_for_route_endpoint(position, max_distance)

func _server_closest_for_sample(sample_position: Vector3, original_position: Vector3, max_distance := INF, source_label := "navigation_server") -> Dictionary:
	var map_readiness := _navigation_map_readiness(true)
	if not bool(map_readiness.get("ready", false)):
		return {
			"found": false,
			"reason": String(map_readiness.get("reason", "navigation_map_sync_pending")),
			"position": original_position,
			"source": source_label,
			"navigationMapReadiness": map_readiness
		}
	var closest_value = Vector3.ZERO
	var owner := RID()
	for _attempt in range(SERVER_CLOSEST_RETRIES):
		_sync_navigation_map_if_dirty()
		var candidate_closest = NavigationServer3D.call("map_get_closest_point", navigation_map, sample_position)
		var owner_value = NavigationServer3D.call("map_get_closest_point_owner", navigation_map, sample_position)
		if candidate_closest is Vector3:
			closest_value = candidate_closest
		if owner_value is RID:
			owner = owner_value
		if owner.is_valid():
			break
	if not owner.is_valid():
		return {}
	var distance := original_position.distance_to(closest_value)
	if distance > max_distance:
		return {
			"found": false,
			"reason": "no_walkable_surface",
			"position": original_position,
			"closestPosition": closest_value,
			"closestDistance": distance,
			"maxDistance": max_distance,
			"source": source_label
		}
	var region_id := String(region_ids_by_rid.get(owner, ""))
	var surface_id := _closest_surface_id(region_id, closest_value)
	return {
		"found": true,
		"regionId": region_id,
		"surfaceId": surface_id,
		"position": closest_value,
		"distance": distance,
		"source": source_label
	}

func _descriptor_guided_server_probe(position: Vector3, max_distance := INF) -> Dictionary:
	var descriptor_result := _closest_walkable_from_descriptors(position, max_distance)
	if not bool(descriptor_result.get("found", false)):
		return {}
	var region_id := String(descriptor_result.get("regionId", ""))
	var surface_id := String(descriptor_result.get("surfaceId", ""))
	var surface := _descriptor_surface(region_id, surface_id)
	if surface.is_empty():
		return {}
	var center: Vector3 = surface.get("center", descriptor_result.get("position", position))
	var descriptor_position: Vector3 = descriptor_result.get("position", position)
	var size: Vector3 = surface.get("size", Vector3(CELL, 0.05, CELL))
	var inset := minf(CELL * 0.18, maxf(0.05, minf(maxf(size.x, 0.01), maxf(size.z, 0.01)) * 0.25))
	var samples: Array[Vector3] = [
		descriptor_position,
		descriptor_position.lerp(center, 0.35),
		center,
		_closest_point_on_surface(surface, descriptor_position + Vector3(inset, 0.0, 0.0)),
		_closest_point_on_surface(surface, descriptor_position + Vector3(-inset, 0.0, 0.0)),
		_closest_point_on_surface(surface, descriptor_position + Vector3(0.0, 0.0, inset)),
		_closest_point_on_surface(surface, descriptor_position + Vector3(0.0, 0.0, -inset))
	]
	for sample in samples:
		var result := _server_closest_for_sample(sample, position, max_distance, "navigation_server_descriptor_probe")
		if bool(result.get("found", false)):
			result["probePosition"] = sample
			result["descriptorPosition"] = descriptor_position
			return result
	return {}

func _descriptor_surface(region_id: String, surface_id: String) -> Dictionary:
	var descriptor = descriptors_by_region.get(region_id)
	if descriptor == null:
		return {}
	var surfaces: Array = descriptor.get("walkable_surfaces")
	for surface_value in surfaces:
		if not (surface_value is Dictionary):
			continue
		var surface: Dictionary = surface_value
		if String(surface.get("id", "")) == surface_id:
			return surface
	return {}

func _closest_surface_id(region_id: String, position: Vector3) -> String:
	var descriptor = descriptors_by_region.get(region_id)
	if descriptor == null:
		return ""
	var best_id := ""
	var best_distance := INF
	for surface in descriptor.get("walkable_surfaces"):
		if not (surface is Dictionary):
			continue
		var center: Vector3 = surface.get("center", Vector3.ZERO)
		var distance := position.distance_to(center)
		if distance < best_distance:
			best_distance = distance
			best_id = String(surface.get("id", ""))
	return best_id

func _query_path_points(start: Vector3, target: Vector3, options := {}) -> Array[Vector3]:
	var points: Array[Vector3] = []
	var map_readiness := _navigation_map_readiness(true)
	if not bool(map_readiness.get("ready", false)):
		return points
	var use_map_get_path := _route_query_api(options) == "map_get_path"
	if not use_map_get_path and NavigationServer3D.has_method("query_path"):
		for attempt in range(SERVER_PATH_QUERY_ATTEMPTS):
			_sync_navigation_map_if_dirty()
			var parameters := reusable_path_query_parameters
			parameters.map = navigation_map
			parameters.start_position = start
			parameters.target_position = target
			parameters.navigation_layers = int(options.get("navigationLayers", 1))
			parameters.path_postprocessing = int(options.get("pathPostprocessing", NavigationPathQueryParameters3D.PATH_POSTPROCESSING_EDGECENTERED))
			parameters.simplify_path = bool(options.get("simplifyPath", false))
			parameters.simplify_epsilon = float(options.get("simplifyEpsilon", 0.0))
			var result := NavigationPathQueryResult3D.new()
			var returned_path = NavigationServer3D.call("query_path", parameters, result)
			var raw_path = result.call("get_path") if result.has_method("get_path") else result.get("path")
			points = _vector_path_to_array(raw_path)
			if points.is_empty():
				points = _vector_path_to_array(returned_path)
			if not points.is_empty():
				break
	if points.is_empty() and NavigationServer3D.has_method("map_get_path"):
		_sync_navigation_map_if_dirty()
		var map_path = NavigationServer3D.call("map_get_path", navigation_map, start, target, bool(options.get("optimizePath", true)))
		points = _vector_path_to_array(map_path)
	return points

func _route_query_api(options := {}) -> String:
	var requested := String(options.get("queryApi", "query_path"))
	if requested == "map_get_path" and NavigationServer3D.has_method("map_get_path"):
		return "map_get_path"
	if requested == "query_path" and NavigationServer3D.has_method("query_path"):
		return "query_path"
	return "map_get_path"

func _descriptor_direct_endpoint_route_allowed(start_walkable: Dictionary, target_walkable: Dictionary, start: Vector3, target: Vector3, options := {}) -> bool:
	var moving_home := bool(options.get("movingHome", false))
	var kind := String(options.get("kind", ""))
	if _route_endpoint_owned_by_server(start_walkable) and _route_endpoint_owned_by_server(target_walkable):
		return false
	var start_region := String(start_walkable.get("regionId", ""))
	var target_region := String(target_walkable.get("regionId", ""))
	if start_region == "" or start_region != target_region:
		return false
	var start_surface := String(start_walkable.get("surfaceId", ""))
	var target_surface := String(target_walkable.get("surfaceId", ""))
	if start_surface != "" and start_surface == target_surface:
		return true
	if moving_home or kind == "scripted":
		return false
	if kind in ["forage", "work", "job", "guard", "idle", "move"]:
		return start.distance_to(target) <= CELL * 4.0
	if not moving_home and kind != "scripted":
		return false
	return start.distance_to(target) <= CELL * 6.0

func _server_same_surface_direct_route_allowed(start_walkable: Dictionary, target_walkable: Dictionary, _start: Vector3, _target: Vector3) -> bool:
	if not _route_endpoint_owned_by_server(start_walkable) or not _route_endpoint_owned_by_server(target_walkable):
		return false
	var start_region := String(start_walkable.get("regionId", ""))
	var target_region := String(target_walkable.get("regionId", ""))
	if start_region == "" or start_region != target_region:
		return false
	var start_surface := String(start_walkable.get("surfaceId", ""))
	var target_surface := String(target_walkable.get("surfaceId", ""))
	return start_surface != "" and start_surface == target_surface

func _endpoint_completion_allowed(path: Array[Vector3], endpoint_check: Dictionary, start_walkable: Dictionary, target_walkable: Dictionary, target: Vector3, _options := {}) -> bool:
	if path.is_empty():
		return false
	if not _route_endpoint_queryable(start_walkable) or not _route_endpoint_queryable(target_walkable):
		return false
	var endpoint_value = endpoint_check.get("endpoint", path[path.size() - 1])
	if not (endpoint_value is Vector3):
		return false
	var endpoint: Vector3 = endpoint_value
	if endpoint.distance_to(target) <= CELL * 0.08:
		return false
	var target_region := String(target_walkable.get("regionId", ""))
	if target_region == "":
		return false
	return true

func _descriptor_endpoint_query_attempt_allowed(start_walkable: Dictionary, target_walkable: Dictionary) -> bool:
	return _route_endpoint_queryable(start_walkable) and _route_endpoint_queryable(target_walkable)

func _route_endpoint_queryable(walkable: Dictionary) -> bool:
	if not bool(walkable.get("found", false)):
		return false
	var region_id := String(walkable.get("regionId", ""))
	if region_id == "" or not region_rids_by_region.has(region_id):
		return false
	var source := String(walkable.get("source", ""))
	return source.begins_with("navigation_server") or source in ["installed_descriptor_endpoint", "descriptor_direct_endpoint"]

func _vector_path_to_array(path_value) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if path_value is PackedVector3Array:
		for point in path_value:
			points.append(point)
	elif path_value is Array:
		for point in path_value:
			if point is Vector3:
				points.append(point)
	return points

func _path_distance(points: Array[Vector3]) -> float:
	if points.size() < 2:
		return 0.0
	var distance := 0.0
	for index in range(1, points.size()):
		distance += points[index - 1].distance_to(points[index])
	return distance

func _path_endpoint_check(points: Array[Vector3], target: Vector3, options := {}) -> Dictionary:
	if points.is_empty():
		return { "ok": false, "reason": "empty_path" }
	var endpoint: Vector3 = points[points.size() - 1]
	var flat_distance := Vector2(endpoint.x - target.x, endpoint.z - target.z).length()
	var vertical_distance := absf(endpoint.y - target.y)
	var arrival_radius := maxf(float(options.get("arrivalRadius", CELL * 0.75)), CELL * 0.35)
	var flat_limit := arrival_radius + PATH_ENDPOINT_EPSILON
	var vertical_limit := NpcConstantsScript.DEFAULT_NPC_STEP_UP + PATH_ENDPOINT_EPSILON
	return {
		"ok": flat_distance <= flat_limit and vertical_distance <= vertical_limit,
		"flatDistance": flat_distance,
		"flatLimit": flat_limit,
		"verticalDistance": vertical_distance,
		"verticalLimit": vertical_limit,
		"endpoint": endpoint,
		"target": target
	}

func _finish_route_query(started_usec: int, result: Dictionary, options := {}) -> Dictionary:
	last_path_query_usec = Time.get_ticks_usec() - started_usec
	total_path_query_usec += last_path_query_usec
	var previous_max := max_path_query_usec
	max_path_query_usec = maxi(max_path_query_usec, last_path_query_usec)
	_record_timing_sample(path_query_duration_samples_usec, last_path_query_usec)
	if not bool(result.get("ok", false)):
		path_query_failure_count += 1
	result["durationUsec"] = last_path_query_usec
	if last_path_query_usec >= previous_max:
		slowest_path_query = {
			"durationUsec": last_path_query_usec,
			"ok": bool(result.get("ok", false)),
			"status": String(result.get("status", "")),
			"reason": String(result.get("reason", "")),
			"source": String(result.get("source", "")),
			"queryApi": String(result.get("queryApi", _route_query_api(options))),
			"actorId": String(options.get("actorId", "")) if options is Dictionary else "",
			"kind": String(options.get("kind", "")) if options is Dictionary else "",
			"startWalkableSource": String((result.get("startWalkable", {}) as Dictionary).get("source", "")) if result.get("startWalkable", {}) is Dictionary else "",
			"targetWalkableSource": String((result.get("targetWalkable", {}) as Dictionary).get("source", "")) if result.get("targetWalkable", {}) is Dictionary else ""
		}
	_record_actor_path_status(result, options)
	return result

func _record_actor_path_status(route: Dictionary, options := {}) -> void:
	if not (options is Dictionary):
		return
	var actor_id := String((options as Dictionary).get("actorId", ""))
	if actor_id == "":
		return
	var door_links: Array = route.get("doorLinks", []) if route.get("doorLinks", []) is Array else []
	var next_portal_id := ""
	for link_value in door_links:
		if link_value is Dictionary:
			next_portal_id = String((link_value as Dictionary).get("portalId", ""))
			if next_portal_id != "":
				break
	actor_path_records[actor_id] = {
		"actorId": actor_id,
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "navmesh")),
		"queryApi": String(route.get("queryApi", "")),
		"start": route.get("start", Vector3.ZERO),
		"target": route.get("target", Vector3.ZERO),
		"startPosition": route.get("startPosition", route.get("start", Vector3.ZERO)),
		"targetPosition": route.get("targetPosition", route.get("target", Vector3.ZERO)),
		"pathPointCount": int(route.get("pointCount", 0)),
		"distance": float(route.get("distance", -1.0)),
		"nextDoorPortalId": next_portal_id,
		"doorLinkCount": door_links.size(),
		"snapshotRevision": String(route.get("snapshotRevision", revision())),
		"durationUsec": int(route.get("durationUsec", 0)),
		"updatedMsec": Time.get_ticks_msec()
	}

func _actor_path_record_with_age(record_value) -> Dictionary:
	var record: Dictionary = record_value.duplicate(true) if record_value is Dictionary else {}
	var updated_msec := int(record.get("updatedMsec", Time.get_ticks_msec()))
	record["ageMsec"] = maxi(0, Time.get_ticks_msec() - updated_msec)
	return record

func _record_timing_sample(samples: Array[int], value: int) -> void:
	samples.append(maxi(0, value))
	while samples.size() > MAX_TIMING_SAMPLES:
		samples.pop_front()

func _route_options_summary(options := {}) -> Dictionary:
	if not (options is Dictionary):
		return {}
	return {
		"actorId": String(options.get("actorId", "")),
		"kind": String(options.get("kind", "")),
		"queryApi": _route_query_api(options),
		"allowOutside": bool(options.get("allowOutside", false)),
		"movingHome": bool(options.get("movingHome", false)),
		"preferDescriptorEndpoint": bool(options.get("preferDescriptorEndpoint", false)),
		"maxSnapDistance": float(options.get("maxSnapDistance", INF)),
		"startMaxSnapDistance": float(options.get("startMaxSnapDistance", options.get("maxSnapDistance", INF))),
		"targetMaxSnapDistance": float(options.get("targetMaxSnapDistance", options.get("maxSnapDistance", INF))),
		"targetCell": options.get("targetCell", Vector2i(999999, 999999))
	}

func _percentile_usec(samples: Array[int], ratio: float) -> int:
	if samples.is_empty():
		return 0
	var sorted := samples.duplicate()
	sorted.sort()
	var index := clampi(ceili(float(sorted.size()) * ratio) - 1, 0, sorted.size() - 1)
	return int(sorted[index])

func _route_query_failure(status: String, reason: String, start: Vector3, target: Vector3, options := {}, details := {}) -> Dictionary:
	var result := {
		"ok": false,
		"status": status,
		"reason": reason,
		"source": "navmesh",
		"queryApi": _route_query_api(options),
		"start": start,
		"target": target,
		"path": [],
		"distance": -1.0,
		"snapshotRevision": revision(),
		"options": options.duplicate(true),
		"details": details
	}
	if details is Dictionary:
		for key in (details as Dictionary).keys():
			result[key] = (details as Dictionary)[key]
	return result

func _install_door_links_for_region(region_id: String, descriptor) -> Dictionary:
	var door_portals: Array = _descriptor_array(descriptor, "door_portals")
	var door_links: Array = _descriptor_array(descriptor, "door_links")
	if not _link_api_supported():
		if not door_portals.is_empty() or not door_links.is_empty():
			door_link_install_failure_count += 1
		return { "status": "unsupported", "installed": 0 }
	var portal_by_id := {}
	for portal_value in door_portals:
		if not (portal_value is Dictionary):
			continue
		var portal: Dictionary = portal_value
		var portal_id := String(portal.get("id", portal.get("portalId", "")))
		if portal_id != "":
			portal_by_id[portal_id] = portal
	var link_specs: Array = []
	for link_value in door_links:
		if link_value is Dictionary:
			link_specs.append((link_value as Dictionary).duplicate(true))
	if link_specs.is_empty():
		var portal_ids := portal_by_id.keys()
		portal_ids.sort()
		for portal_id_value in portal_ids:
			var portal_id := String(portal_id_value)
			link_specs.append({
				"id": "door-link:%s" % portal_id,
				"portalId": portal_id,
				"actionId": "open",
				"bidirectional": true,
				"openable": true,
				"enabled": true
			})
	link_specs.sort_custom(func(a, b): return String(a.get("id", a.get("portalId", ""))) < String(b.get("id", b.get("portalId", ""))))
	var installed := 0
	var failures := 0
	for link_spec_value in link_specs:
		if not (link_spec_value is Dictionary):
			continue
		var link_spec: Dictionary = link_spec_value
		var portal_id := String(link_spec.get("portalId", link_spec.get("portal_id", "")))
		if portal_id == "":
			failures += 1
			continue
		var portal: Dictionary = portal_by_id.get(portal_id, {})
		var base_metadata := _merged_link_metadata(portal, link_spec, door_portal_states.get(portal_id, {}))
		var start_position := _door_link_position(link_spec, portal, ["start", "startPosition", "fromPosition", "entrance"], Vector3.ZERO)
		var end_position := _door_link_position(link_spec, portal, ["end", "endPosition", "toPosition", "exit"], Vector3.ZERO)
		if start_position == end_position:
			failures += 1
			continue
		var link_value = NavigationServer3D.call("link_create")
		if not (link_value is RID):
			failures += 1
			continue
		var link_rid: RID = link_value
		NavigationServer3D.call("link_set_map", link_rid, navigation_map)
		NavigationServer3D.call("link_set_start_position", link_rid, start_position)
		NavigationServer3D.call("link_set_end_position", link_rid, end_position)
		NavigationServer3D.call("link_set_bidirectional", link_rid, bool(base_metadata.get("bidirectional", true)))
		if NavigationServer3D.has_method("link_set_navigation_layers"):
			NavigationServer3D.call("link_set_navigation_layers", link_rid, int(base_metadata.get("navigationLayers", 1)))
		if NavigationServer3D.has_method("link_set_enter_cost"):
			NavigationServer3D.call("link_set_enter_cost", link_rid, float(base_metadata.get("enterCost", base_metadata.get("cost", 1.0))))
		if NavigationServer3D.has_method("link_set_travel_cost"):
			NavigationServer3D.call("link_set_travel_cost", link_rid, float(base_metadata.get("travelCost", base_metadata.get("cost", 1.0))))
		var enabled := _door_link_enabled(base_metadata)
		_set_link_enabled(link_rid, enabled)
		var record := {
			"rid": link_rid,
			"regionId": region_id,
			"portalId": portal_id,
			"linkId": String(base_metadata.get("id", "door-link:%s" % portal_id)),
			"start": start_position,
			"end": end_position,
			"enabled": enabled,
			"baseMetadata": base_metadata.duplicate(true),
			"metadata": base_metadata.duplicate(true)
		}
		if not door_link_records_by_region.has(region_id):
			door_link_records_by_region[region_id] = []
		door_link_records_by_region[region_id].append(record)
		if not door_link_records_by_portal.has(portal_id):
			door_link_records_by_portal[portal_id] = []
		door_link_records_by_portal[portal_id].append(record)
		installed += 1
	installed_door_link_count += installed
	door_link_install_failure_count += failures
	return { "status": "installed", "installed": installed, "failed": failures }

func _descriptor_array(descriptor, property_name: String) -> Array:
	if descriptor == null:
		return []
	var value = descriptor.get(property_name)
	if value is Array:
		return value
	return []

func _release_door_links_for_region(region_id: String) -> int:
	var records: Array = door_link_records_by_region.get(region_id, [])
	var released := 0
	for record_value in records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		var link_rid: RID = record.get("rid", RID())
		if link_rid.is_valid():
			NavigationServer3D.free_rid(link_rid)
			_mark_navigation_map_dirty()
			released += 1
		var portal_id := String(record.get("portalId", ""))
		if door_link_records_by_portal.has(portal_id):
			var kept: Array = []
			for portal_record in door_link_records_by_portal[portal_id]:
				if portal_record is Dictionary and String((portal_record as Dictionary).get("regionId", "")) != region_id:
					kept.append(portal_record)
			if kept.is_empty():
				door_link_records_by_portal.erase(portal_id)
			else:
				door_link_records_by_portal[portal_id] = kept
	door_link_records_by_region.erase(region_id)
	installed_door_link_count = maxi(0, installed_door_link_count - released)
	return released

func _apply_portal_state_to_link_record(record: Dictionary, portal_state: Dictionary) -> void:
	var base_metadata: Dictionary = record.get("baseMetadata", {})
	var metadata := _merged_link_metadata(base_metadata, {}, portal_state)
	record["metadata"] = metadata
	var enabled := _door_link_enabled(metadata)
	record["enabled"] = enabled
	var link_rid: RID = record.get("rid", RID())
	if link_rid.is_valid():
		_set_link_enabled(link_rid, enabled)

func _set_link_enabled(link_rid: RID, enabled: bool) -> void:
	if not link_rid.is_valid():
		return
	if NavigationServer3D.has_method("link_set_enabled"):
		NavigationServer3D.call("link_set_enabled", link_rid, enabled)
	elif NavigationServer3D.has_method("link_set_navigation_layers"):
		NavigationServer3D.call("link_set_navigation_layers", link_rid, 1 if enabled else 0)
	_mark_navigation_map_dirty()

func _mark_navigation_map_dirty() -> void:
	navigation_map_dirty_serial += 1

func _sync_navigation_map_if_dirty() -> bool:
	if navigation_map_synced_serial == navigation_map_dirty_serial:
		navigation_map_last_iteration_id = _navigation_map_iteration_id()
		return false
	if navigation_map.is_valid() and NavigationServer3D.has_method("map_force_update"):
		NavigationServer3D.call("map_force_update", navigation_map)
	navigation_map_last_iteration_id = _navigation_map_iteration_id()
	navigation_map_synced_serial = navigation_map_dirty_serial
	return true

func _navigation_map_readiness(sync_dirty := false) -> Dictionary:
	var sync_attempted := false
	if sync_dirty:
		sync_attempted = _sync_navigation_map_if_dirty()
	var has_iteration_api := NavigationServer3D.has_method("map_get_iteration_id")
	var iteration_id := _navigation_map_iteration_id()
	navigation_map_last_iteration_id = iteration_id
	var ready := true
	var reason := ""
	if not backend_config.use_navmesh():
		ready = false
		reason = "navmesh_backend_disabled"
	elif not navigation_map.is_valid():
		ready = false
		reason = "missing_navigation_map"
	elif region_rids_by_region.is_empty():
		ready = false
		reason = "missing_navmesh_regions"
	elif has_iteration_api and iteration_id <= 0:
		ready = false
		reason = "navigation_map_sync_pending"
	return {
		"ready": ready,
		"reason": reason,
		"state": String(NpcEnumsScript.ROUTE_AUTHORITY_READY if ready else NpcEnumsScript.ROUTE_AUTHORITY_PENDING_NAV_DATA),
		"hasIterationApi": has_iteration_api,
		"iterationId": iteration_id,
		"lastIterationId": navigation_map_last_iteration_id,
		"syncAttempted": sync_attempted,
		"dirtySerial": navigation_map_dirty_serial,
		"syncedSerial": navigation_map_synced_serial,
		"hasNavigationMap": navigation_map.is_valid(),
		"installedRegionCount": region_rids_by_region.size()
	}

func _navigation_map_iteration_id() -> int:
	if not navigation_map.is_valid() or not NavigationServer3D.has_method("map_get_iteration_id"):
		return -1
	var value = NavigationServer3D.call("map_get_iteration_id", navigation_map)
	if value is int:
		return int(value)
	if value is float:
		return int(value)
	return -1

func _door_link_enabled(metadata: Dictionary) -> bool:
	if not bool(metadata.get("enabled", true)):
		return false
	if bool(metadata.get("locked", false)) or bool(metadata.get("jammed", false)) or bool(metadata.get("destroyed", false)) or bool(metadata.get("unloaded", false)):
		return false
	var state := String(metadata.get("state", NpcEnumsScript.DOOR_STATE_CLOSED))
	if state in [String(NpcEnumsScript.DOOR_STATE_LOCKED), String(NpcEnumsScript.DOOR_STATE_JAMMED), String(NpcEnumsScript.DOOR_STATE_DESTROYED), String(NpcEnumsScript.DOOR_STATE_UNLOADED)]:
		return false
	if state == String(NpcEnumsScript.DOOR_STATE_CLOSED) and not bool(metadata.get("openable", true)):
		return false
	return true

func _merged_link_metadata(portal: Dictionary, link: Dictionary, live_state: Dictionary) -> Dictionary:
	var result := {}
	for source in [portal, link, live_state]:
		if not (source is Dictionary):
			continue
		for key in (source as Dictionary).keys():
			result[key] = (source as Dictionary)[key]
	if not result.has("state"):
		result["state"] = String(NpcEnumsScript.DOOR_STATE_CLOSED)
	if not result.has("openable"):
		result["openable"] = true
	if not result.has("enabled"):
		result["enabled"] = true
	return result

func _door_link_position(link: Dictionary, portal: Dictionary, keys: Array, fallback: Vector3) -> Vector3:
	for key_value in keys:
		var key := String(key_value)
		if link.has(key) and link[key] is Vector3:
			return link[key]
		if portal.has(key) and portal[key] is Vector3:
			return portal[key]
	return fallback

func _door_actions_for_path(path: Array[Vector3], options := {}) -> Dictionary:
	var actions := {}
	if path.size() < 2:
		return actions
	var path_bounds := _flat_bounds_for_points(path, CELL * 1.6)
	var portal_ids := door_link_records_by_portal.keys()
	portal_ids.sort()
	for portal_id_value in portal_ids:
		var portal_id := String(portal_id_value)
		for record_value in door_link_records_by_portal.get(portal_id, []):
			if not (record_value is Dictionary):
				continue
			var record: Dictionary = record_value
			if not bool(record.get("enabled", false)):
				continue
			if _door_record_forbidden(record, options):
				continue
			if not _door_record_overlaps_flat_bounds(record, path_bounds):
				continue
			var link_direction := _path_door_link_direction(path, record)
			if link_direction == "":
				continue
			var metadata: Dictionary = record.get("metadata", {})
			var start_position: Vector3 = record.get("start", Vector3.ZERO)
			var end_position: Vector3 = record.get("end", Vector3.ZERO)
			var action := _door_action_for_record(portal_id, record, link_direction)
			if not action.is_empty():
				actions[_cell_key(action.get("cell", Vector2i.ZERO))] = action
	return actions

func _direct_door_route_for_points(start: Vector3, target: Vector3, current_path: Array[Vector3], options := {}) -> Dictionary:
	var best := {}
	var best_distance := INF
	var current_distance := _path_distance(current_path)
	var query_bounds := _flat_bounds_for_points([start, target], CELL * 1.6)
	var portal_ids := door_link_records_by_portal.keys()
	portal_ids.sort()
	for portal_id_value in portal_ids:
		var portal_id := String(portal_id_value)
		for record_value in door_link_records_by_portal.get(portal_id, []):
			if not (record_value is Dictionary):
				continue
			var record: Dictionary = record_value
			if not bool(record.get("enabled", false)):
				continue
			if _door_record_forbidden(record, options):
				continue
			if not _door_record_overlaps_flat_bounds(record, query_bounds):
				continue
			var start_position: Vector3 = record.get("start", Vector3.ZERO)
			var end_position: Vector3 = record.get("end", Vector3.ZERO)
			var axis := end_position - start_position
			axis.y = 0.0
			if axis.length_squared() <= 0.0001:
				continue
			axis = axis.normalized()
			var center := (start_position + end_position) * 0.5
			var from_start := start - center
			var from_target := target - center
			from_start.y = 0.0
			from_target.y = 0.0
			var start_along := from_start.dot(axis)
			var target_along := from_target.dot(axis)
			if start_along == 0.0 or target_along == 0.0 or start_along * target_along > 0.0:
				continue
			var start_lateral := (from_start - axis * start_along).length()
			var target_lateral := (from_target - axis * target_along).length()
			if maxf(start_lateral, target_lateral) > CELL * 1.35:
				continue
			var direction := "forward" if start_along < target_along else "reverse"
			var action := _door_action_for_record(portal_id, record, direction)
			if action.is_empty():
				continue
			var entry_position: Vector3 = action.get("entryPosition", start_position)
			var exit_position: Vector3 = action.get("exitPosition", end_position)
			var metadata: Dictionary = record.get("metadata", {})
			var link_distance := entry_position.distance_to(exit_position)
			var geometric_distance := start.distance_to(entry_position) + link_distance + exit_position.distance_to(target)
			var weighted_distance := start.distance_to(entry_position) + _door_link_query_cost(metadata, link_distance) + exit_position.distance_to(target)
			var mandatory_local_crossing := maxf(absf(start_along), absf(target_along)) <= CELL * 2.35
			if not mandatory_local_crossing:
				continue
			if not mandatory_local_crossing and current_distance > 0.0 and weighted_distance > current_distance + CELL * 1.5:
				continue
			var distance := geometric_distance if mandatory_local_crossing else weighted_distance
			if distance < best_distance:
				best_distance = distance
				best = {
					"path": [start, entry_position, exit_position, target],
					"actions": { _cell_key(action.get("cell", Vector2i.ZERO)): action },
					"distance": distance
				}
	return best

func _forbidden_door_links_for_path(path: Array[Vector3], options := {}) -> Array[String]:
	var result: Array[String] = []
	if path.size() < 2:
		return result
	var portal_ids := door_link_records_by_portal.keys()
	portal_ids.sort()
	for portal_id_value in portal_ids:
		var portal_id := String(portal_id_value)
		for record_value in door_link_records_by_portal.get(portal_id, []):
			if not (record_value is Dictionary):
				continue
			var record: Dictionary = record_value
			if not bool(record.get("enabled", false)):
				continue
			if not _door_record_forbidden(record, options):
				continue
			if _path_uses_door_link(path, record) and not result.has(portal_id):
				result.append(portal_id)
	result.sort()
	return result

func _door_record_forbidden(record: Dictionary, options := {}) -> bool:
	var forbidden := _forbidden_door_portal_lookup(options)
	if forbidden.is_empty():
		return false
	return forbidden.has(String(record.get("portalId", "")))

func _forbidden_door_portal_lookup(options := {}) -> Dictionary:
	var result := {}
	if not (options is Dictionary):
		return result
	for value in (options as Dictionary).get("forbiddenDoorPortalIds", []):
		var portal_id := String(value)
		if portal_id != "":
			result[portal_id] = true
	return result

func _sorted_descriptor_region_ids() -> Array:
	var keys := descriptors_by_region.keys()
	keys.sort()
	return keys

func _descriptor_region_ids_near_position(position: Vector3, max_distance: float) -> Array:
	if max_distance >= INF or descriptors_by_region.is_empty():
		return []
	var cell_x := floori(position.x / CELL)
	var cell_z := floori(position.z / CELL)
	var tile_x := floori(float(cell_x) / float(NAV_TILE_CELL_SIZE))
	var tile_z := floori(float(cell_z) / float(NAV_TILE_CELL_SIZE))
	var tile_radius := clampi(ceili(max_distance / (CELL * float(NAV_TILE_CELL_SIZE))) + 1, 1, 3)
	var keys: Array[String] = []
	for z in range(tile_z - tile_radius, tile_z + tile_radius + 1):
		for x in range(tile_x - tile_radius, tile_x + tile_radius + 1):
			var region_id := NavigationBakeDescriptorScript.chunk_region_id("%d,%d" % [x, z])
			if descriptors_by_region.has(region_id):
				keys.append(region_id)
	keys.sort()
	return keys

func _flat_bounds_for_points(points: Array, margin: float) -> Dictionary:
	if points.is_empty():
		return {}
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for point_value in points:
		if not (point_value is Vector3):
			continue
		var point: Vector3 = point_value
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_z = minf(min_z, point.z)
		max_z = maxf(max_z, point.z)
	if min_x == INF:
		return {}
	return {
		"minX": min_x - margin,
		"maxX": max_x + margin,
		"minZ": min_z - margin,
		"maxZ": max_z + margin
	}

func _door_record_overlaps_flat_bounds(record: Dictionary, bounds: Dictionary) -> bool:
	if bounds.is_empty():
		return true
	var start_position: Vector3 = record.get("start", Vector3.ZERO)
	var end_position: Vector3 = record.get("end", Vector3.ZERO)
	var record_min_x := minf(start_position.x, end_position.x)
	var record_max_x := maxf(start_position.x, end_position.x)
	var record_min_z := minf(start_position.z, end_position.z)
	var record_max_z := maxf(start_position.z, end_position.z)
	return record_max_x >= float(bounds.get("minX", -INF)) \
		and record_min_x <= float(bounds.get("maxX", INF)) \
		and record_max_z >= float(bounds.get("minZ", -INF)) \
		and record_min_z <= float(bounds.get("maxZ", INF))

func _door_link_query_cost(metadata: Dictionary, link_distance: float) -> float:
	var enter_cost := float(metadata.get("enterCost", metadata.get("cost", 1.0)))
	var travel_cost := float(metadata.get("travelCost", metadata.get("cost", 1.0)))
	return maxf(0.0, enter_cost) + maxf(0.0, travel_cost) * maxf(0.0, link_distance)

func _door_action_for_record(portal_id: String, record: Dictionary, direction: String) -> Dictionary:
	var metadata: Dictionary = record.get("metadata", {})
	var start_position: Vector3 = record.get("start", Vector3.ZERO)
	var end_position: Vector3 = record.get("end", Vector3.ZERO)
	var entry_position := start_position
	var exit_position := end_position
	if direction == "reverse":
		entry_position = end_position
		exit_position = start_position
	var entry_cell := _cell_for_position(entry_position)
	var action_cell := _cell_for_position(exit_position)
	var action := {
		"kind": "door",
		"portalId": portal_id,
		"actionId": String(metadata.get("actionId", "open")),
		"cell": action_cell,
		"entryCell": entry_cell,
		"entryPosition": entry_position,
		"exitPosition": exit_position,
		"direction": _door_action_direction(entry_position, exit_position),
		"navLink": true,
		"requiresSmartObject": true,
		"enabled": bool(record.get("enabled", false))
	}
	var door_value = metadata.get("door", null)
	if door_value is Node and is_instance_valid(door_value):
		action["door"] = door_value
	return action

func _door_action_direction(entry_position: Vector3, exit_position: Vector3) -> String:
	var delta := exit_position - entry_position
	delta.y = 0.0
	if delta.length_squared() <= 0.0001:
		return ""
	if absf(delta.x) >= absf(delta.z) and absf(delta.x) > 0.0001:
		return "x+" if delta.x > 0.0 else "x-"
	if absf(delta.z) > 0.0001:
		return "z+" if delta.z > 0.0 else "z-"
	return ""

func _door_links_for_actions(actions: Dictionary) -> Array:
	var result := []
	var keys := actions.keys()
	keys.sort()
	for key in keys:
		var action: Dictionary = actions[key]
		result.append({
			"cellKey": String(key),
			"portalId": String(action.get("portalId", "")),
			"actionId": String(action.get("actionId", "open")),
			"navLink": bool(action.get("navLink", false))
		})
	return result

func _path_uses_door_link(path: Array[Vector3], record: Dictionary) -> bool:
	return _path_door_link_direction(path, record) != ""

func _path_door_link_direction(path: Array[Vector3], record: Dictionary) -> String:
	var start: Vector3 = record.get("start", Vector3.ZERO)
	var end: Vector3 = record.get("end", Vector3.ZERO)
	var tolerance := CELL * 0.35
	for index in range(1, path.size()):
		var from_point := path[index - 1]
		var to_point := path[index]
		if from_point.distance_to(start) <= tolerance and to_point.distance_to(end) <= tolerance:
			return "forward"
		if from_point.distance_to(end) <= tolerance and to_point.distance_to(start) <= tolerance:
			return "reverse"
		if _point_segment_distance(start, from_point, to_point) <= tolerance and _point_segment_distance(end, from_point, to_point) <= tolerance:
			var link_axis := end - start
			link_axis.y = 0.0
			var path_axis := to_point - from_point
			path_axis.y = 0.0
			if link_axis.length_squared() <= 0.0001 or path_axis.length_squared() <= 0.0001:
				return "forward"
			return "forward" if link_axis.dot(path_axis) >= 0.0 else "reverse"
	var cell_value = (record.get("metadata", {}) as Dictionary).get("cell") if record.get("metadata", {}) is Dictionary else null
	if cell_value is Vector2i:
		var door_center := Vector3(float((cell_value as Vector2i).x) * CELL, (start.y + end.y) * 0.5, float((cell_value as Vector2i).y) * CELL)
		for index in range(1, path.size()):
			var from_point := path[index - 1]
			var to_point := path[index]
			if _point_segment_distance(door_center, from_point, to_point) > CELL * 0.48:
				continue
			var link_axis := end - start
			link_axis.y = 0.0
			var path_axis := to_point - from_point
			path_axis.y = 0.0
			if link_axis.length_squared() <= 0.0001 or path_axis.length_squared() <= 0.0001:
				return "forward"
			return "forward" if link_axis.dot(path_axis) >= 0.0 else "reverse"
	return ""

func _point_segment_distance(point: Vector3, segment_start: Vector3, segment_end: Vector3) -> float:
	var segment := segment_end - segment_start
	var length_sq := segment.length_squared()
	if length_sq <= 0.0001:
		return point.distance_to(segment_start)
	var t := clampf((point - segment_start).dot(segment) / length_sq, 0.0, 1.0)
	return point.distance_to(segment_start + segment * t)

func _cell_for_position(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]

func _mark_dirty_region(region_id: String, event: Dictionary, reason: String) -> Dictionary:
	if region_id == "":
		return { "status": "rejected", "reason": "missing_region_id" }
	var record := {
		"reason": reason,
		"tileKey": String(event.get("tileKey", "")),
		"changeKinds": (event.get("changeKinds", []) as Array).duplicate(),
		"sourceRevision": int(event.get("revision", 0))
	}
	dirty_regions_by_region[region_id] = record
	if not dirty_region_queue.has(region_id):
		dirty_region_queue.append(region_id)
	region_states[region_id] = "dirty"
	return {
		"status": "dirty",
		"regionId": region_id,
		"topologyRevision": topology_revision,
		"dirtyRegionCount": dirty_regions_by_region.size(),
		"queuedRebuild": true
	}

func _clear_dirty_region(region_id: String) -> void:
	dirty_regions_by_region.erase(region_id)
	dirty_region_queue.erase(region_id)

func _dirty_regions_summary() -> Dictionary:
	var result := {}
	var keys := dirty_regions_by_region.keys()
	keys.sort()
	for region_id in keys:
		result[String(region_id)] = dirty_regions_by_region[region_id].duplicate(true)
	return result

func _door_links_debug_summary() -> Dictionary:
	var result := {}
	var portal_ids := door_link_records_by_portal.keys()
	portal_ids.sort()
	for portal_id in portal_ids:
		var summaries := []
		for record_value in door_link_records_by_portal[portal_id]:
			if not (record_value is Dictionary):
				continue
			var record: Dictionary = record_value
			var metadata: Dictionary = record.get("metadata", {})
			summaries.append({
				"linkId": String(record.get("linkId", "")),
				"regionId": String(record.get("regionId", "")),
				"portalId": String(record.get("portalId", "")),
				"enabled": bool(record.get("enabled", false)),
				"state": String(metadata.get("state", "")),
				"locked": bool(metadata.get("locked", false)),
				"jammed": bool(metadata.get("jammed", false)),
				"destroyed": bool(metadata.get("destroyed", false)),
				"unloaded": bool(metadata.get("unloaded", false)),
				"openable": bool(metadata.get("openable", true)),
				"start": _vector3_summary(record.get("start", Vector3.ZERO)),
				"end": _vector3_summary(record.get("end", Vector3.ZERO))
			})
		result[String(portal_id)] = summaries
	return result

func _door_portal_states_summary() -> Dictionary:
	var result := {}
	var portal_ids := door_portal_states.keys()
	portal_ids.sort()
	for portal_id in portal_ids:
		var state: Dictionary = door_portal_states[portal_id]
		result[String(portal_id)] = {
			"portalId": String(state.get("portalId", portal_id)),
			"state": String(state.get("state", "")),
			"locked": bool(state.get("locked", false)),
			"jammed": bool(state.get("jammed", false)),
			"destroyed": bool(state.get("destroyed", false)),
			"unloaded": bool(state.get("unloaded", false)),
			"stateRevision": int(state.get("stateRevision", 0))
		}
	return result

func _link_api_supported() -> bool:
	return (
		NavigationServer3D.has_method("link_create")
		and NavigationServer3D.has_method("link_set_map")
		and NavigationServer3D.has_method("link_set_start_position")
		and NavigationServer3D.has_method("link_set_end_position")
		and NavigationServer3D.has_method("link_set_bidirectional")
	)

func _has_kind(kinds: Array, expected) -> bool:
	var expected_string := String(expected)
	for kind_value in kinds:
		if String(kind_value) == expected_string:
			return true
	return false

func _event_needs_rebuild(kinds: Array) -> bool:
	for kind_value in kinds:
		var kind := String(kind_value)
		if kind in ["block_created", "block_removed", "terrain_edit", "prop_created", "prop_removed", "chunk_loaded", "door_registered", "structure_metadata", "semantic_changed"]:
			return true
	return false

func _vector3_summary(value: Vector3) -> Array:
	return [snappedf(value.x, 0.001), snappedf(value.y, 0.001), snappedf(value.z, 0.001)]
