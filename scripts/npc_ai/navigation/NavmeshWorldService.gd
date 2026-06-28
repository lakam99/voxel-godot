extends RefCounted
class_name NavmeshWorldService

const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

const CELL := NpcConstantsScript.CELL_SIZE

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
	_ensure_navigation_map()
	if region_rids_by_region.has(region_id):
		_release_region(region_id)
	descriptors_by_region[region_id] = descriptor
	_clear_dirty_region(region_id)
	var loaded := bool(descriptor.get("loaded"))
	var install_result := _install_region(region_id, descriptor) if loaded else { "status": "unloaded", "regionId": region_id }
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
		"signature": descriptor.stable_signature() if descriptor.has_method("stable_signature") else ""
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
	if not server_result.is_empty():
		return server_result
	return _closest_walkable_from_descriptors(position, max_distance)

func query_route(start: Vector3, target: Vector3, options := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	path_query_count += 1
	if not backend_config.use_navmesh():
		return _finish_route_query(started, _route_query_failure("disabled", "navmesh_backend_disabled", start, target, options))
	if not navigation_map.is_valid() or region_rids_by_region.is_empty():
		return _finish_route_query(started, _route_query_failure("blocked", "missing_navmesh_regions", start, target, options))
	var max_snap := float(options.get("maxSnapDistance", INF))
	var start_walkable := closest_walkable(start, max_snap)
	if not bool(start_walkable.get("found", false)):
		return _finish_route_query(started, _route_query_failure("blocked", "no_start_walkable", start, target, options, start_walkable))
	var target_walkable := closest_walkable(target, max_snap)
	if not bool(target_walkable.get("found", false)):
		return _finish_route_query(started, _route_query_failure("blocked", "no_target_walkable", start, target, options, target_walkable))
	var query_start: Vector3 = start_walkable.get("position", start)
	var query_target: Vector3 = target_walkable.get("position", target)
	var path: Array[Vector3] = _query_path_points(query_start, query_target, options)
	if path.is_empty():
		return _finish_route_query(started, _route_query_failure("blocked", "no_route", start, target, options, {
			"startWalkable": start_walkable,
			"targetWalkable": target_walkable
		}))
	var door_actions := _door_actions_for_path(path)
	return _finish_route_query(started, {
		"ok": true,
		"status": "complete",
		"reason": "",
		"source": "navmesh",
		"queryApi": "query_path" if NavigationServer3D.has_method("query_path") else "map_get_path",
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
		"options": options.duplicate(true),
		"startWalkable": start_walkable,
		"targetWalkable": target_walkable
	})

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
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"regions": regions,
		"regionStates": region_states.duplicate(true),
		"dirtyRegions": _dirty_regions_summary(),
		"doorLinks": _door_links_debug_summary(),
		"doorPortalStates": _door_portal_states_summary(),
		"installedRegionCount": region_rids_by_region.size(),
		"installedSurfaceCount": installed_surface_count,
		"installedDoorLinkCount": installed_door_link_count
	}

func stats() -> Dictionary:
	return {
		"backend": backend_config.backend,
		"navmeshEnabled": backend_config.use_navmesh(),
		"hasNavigationMap": navigation_map.is_valid(),
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
		"dirtyRegionCount": dirty_regions_by_region.size(),
		"dirtyRegionQueueCount": dirty_region_queue.size(),
		"rebuildCount": rebuild_count,
		"lastRebuildUsec": last_rebuild_usec,
		"doorLinkInstallFailureCount": door_link_install_failure_count,
		"linkApiSupported": _link_api_supported(),
		"pathQueryCount": path_query_count,
		"pathQueryFailureCount": path_query_failure_count,
		"lastPathQueryUsec": last_path_query_usec,
		"avgPathQueryUsec": float(total_path_query_usec) / float(maxi(1, path_query_count)),
		"maxPathQueryUsec": max_path_query_usec
	}

func revision() -> String:
	return "%d:%d" % [topology_revision, dynamic_revision]

func _closest_walkable_from_descriptors(position: Vector3, max_distance := INF) -> Dictionary:
	var best := {}
	var best_distance := INF
	var keys := descriptors_by_region.keys()
	keys.sort()
	for region_id in keys:
		var descriptor = descriptors_by_region[region_id]
		if descriptor == null or not bool(descriptor.get("loaded")):
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
	if NavigationServer3D.has_method("region_set_enabled"):
		NavigationServer3D.call("region_set_enabled", region_rid, true)
	if NavigationServer3D.has_method("map_force_update"):
		NavigationServer3D.call("map_force_update", navigation_map)
	region_rids_by_region[region_id] = region_rid
	region_ids_by_rid[region_rid] = region_id
	var link_metrics := _install_door_links_for_region(region_id, descriptor)
	last_install_usec = Time.get_ticks_usec() - started
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
	var polygons: Array[PackedInt32Array] = []
	var surfaces: Array = descriptor.get("walkable_surfaces")
	var sorted_surfaces: Array = surfaces.duplicate()
	sorted_surfaces.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	for surface_value in sorted_surfaces:
		if not (surface_value is Dictionary):
			continue
		var surface: Dictionary = surface_value
		if not bool(surface.get("walkable", true)):
			continue
		var polygon_points := _surface_polygon(surface)
		if polygon_points.size() < 3:
			continue
		var indices := PackedInt32Array()
		for point in polygon_points:
			indices.append(vertices.size())
			vertices.append(point)
		polygons.append(indices)
	navigation_mesh.set_vertices(vertices)
	for polygon in polygons:
		navigation_mesh.add_polygon(polygon)
	return navigation_mesh

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
	region_rids_by_region.erase(region_id)
	region_ids_by_rid.erase(region_rid)
	var metrics: Dictionary = region_metrics_by_region.get(region_id, {})
	installed_surface_count = maxi(0, installed_surface_count - int(metrics.get("polygonCount", 0)))

func _closest_walkable_from_server(position: Vector3, max_distance := INF) -> Dictionary:
	if not navigation_map.is_valid() or region_rids_by_region.is_empty():
		return {}
	if NavigationServer3D.has_method("map_force_update"):
		NavigationServer3D.call("map_force_update", navigation_map)
	if not NavigationServer3D.has_method("map_get_closest_point") or not NavigationServer3D.has_method("map_get_closest_point_owner"):
		return {}
	var closest_value = NavigationServer3D.call("map_get_closest_point", navigation_map, position)
	var owner_value = NavigationServer3D.call("map_get_closest_point_owner", navigation_map, position)
	if not (closest_value is Vector3) or not (owner_value is RID):
		return {}
	var owner: RID = owner_value
	if not owner.is_valid():
		return {}
	var distance := position.distance_to(closest_value)
	if distance > max_distance:
		return { "found": false, "reason": "no_walkable_surface", "position": position, "maxDistance": max_distance, "source": "navigation_server" }
	var region_id := String(region_ids_by_rid.get(owner, ""))
	var surface_id := _closest_surface_id(region_id, closest_value)
	return {
		"found": true,
		"regionId": region_id,
		"surfaceId": surface_id,
		"position": closest_value,
		"distance": distance,
		"source": "navigation_server"
	}

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
	if NavigationServer3D.has_method("query_path"):
		for attempt in range(2):
			if NavigationServer3D.has_method("map_force_update"):
				NavigationServer3D.call("map_force_update", navigation_map)
			var parameters := NavigationPathQueryParameters3D.new()
			parameters.map = navigation_map
			parameters.start_position = start
			parameters.target_position = target
			parameters.navigation_layers = int(options.get("navigationLayers", 1))
			var result := NavigationPathQueryResult3D.new()
			var returned_path = NavigationServer3D.call("query_path", parameters, result)
			var raw_path = result.call("get_path") if result.has_method("get_path") else result.get("path")
			points = _vector_path_to_array(raw_path)
			if points.is_empty():
				points = _vector_path_to_array(returned_path)
			if not points.is_empty():
				break
	if points.is_empty() and NavigationServer3D.has_method("map_get_path"):
		if NavigationServer3D.has_method("map_force_update"):
			NavigationServer3D.call("map_force_update", navigation_map)
		var raw_map_path = NavigationServer3D.call("map_get_path", navigation_map, start, target, true)
		points = _vector_path_to_array(raw_map_path)
	return points

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

func _finish_route_query(started_usec: int, result: Dictionary) -> Dictionary:
	last_path_query_usec = Time.get_ticks_usec() - started_usec
	total_path_query_usec += last_path_query_usec
	max_path_query_usec = maxi(max_path_query_usec, last_path_query_usec)
	if not bool(result.get("ok", false)):
		path_query_failure_count += 1
	result["durationUsec"] = last_path_query_usec
	return result

func _route_query_failure(status: String, reason: String, start: Vector3, target: Vector3, options := {}, details := {}) -> Dictionary:
	return {
		"ok": false,
		"status": status,
		"reason": reason,
		"source": "navmesh",
		"queryApi": "query_path" if NavigationServer3D.has_method("query_path") else ("map_get_path" if NavigationServer3D.has_method("map_get_path") else ""),
		"start": start,
		"target": target,
		"path": [],
		"distance": -1.0,
		"snapshotRevision": revision(),
		"options": options.duplicate(true),
		"details": details
	}

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
	if NavigationServer3D.has_method("map_force_update"):
		NavigationServer3D.call("map_force_update", navigation_map)
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

func _door_actions_for_path(path: Array[Vector3]) -> Dictionary:
	var actions := {}
	if path.size() < 2:
		return actions
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
			if not _path_uses_door_link(path, record):
				continue
			var metadata: Dictionary = record.get("metadata", {})
			var end_position: Vector3 = record.get("end", Vector3.ZERO)
			var action_cell := _cell_for_position(end_position)
			var action_key := _cell_key(action_cell)
			var action := {
				"kind": "door",
				"portalId": portal_id,
				"actionId": String(metadata.get("actionId", "open")),
				"cell": action_cell,
				"entryPosition": record.get("start", Vector3.ZERO),
				"exitPosition": end_position,
				"navLink": true,
				"requiresSmartObject": true,
				"enabled": bool(record.get("enabled", false))
			}
			var door_value = metadata.get("door", null)
			if door_value is Node and is_instance_valid(door_value):
				action["door"] = door_value
			actions[action_key] = action
	return actions

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
	var start: Vector3 = record.get("start", Vector3.ZERO)
	var end: Vector3 = record.get("end", Vector3.ZERO)
	var tolerance := CELL * 0.35
	for index in range(1, path.size()):
		var from_point := path[index - 1]
		var to_point := path[index]
		if from_point.distance_to(start) <= tolerance and to_point.distance_to(end) <= tolerance:
			return true
		if from_point.distance_to(end) <= tolerance and to_point.distance_to(start) <= tolerance:
			return true
		if _point_segment_distance(start, from_point, to_point) <= tolerance and _point_segment_distance(end, from_point, to_point) <= tolerance:
			return true
	return false

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
