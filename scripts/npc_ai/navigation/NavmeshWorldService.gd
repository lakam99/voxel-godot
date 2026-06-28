extends RefCounted
class_name NavmeshWorldService

const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")

var backend_config = NavigationBackendConfigScript.default_config()
var navigation_map := RID()
var owns_navigation_map := false
var descriptors_by_region := {}
var region_states := {}
var topology_revision := 0
var dynamic_revision := 0
var registered_region_count := 0
var unregistered_region_count := 0

func setup(config = null) -> void:
	backend_config = config if config != null else NavigationBackendConfigScript.from_environment()
	_ensure_navigation_map()

func clear() -> void:
	descriptors_by_region.clear()
	region_states.clear()
	topology_revision = 0
	dynamic_revision = 0
	registered_region_count = 0
	unregistered_region_count = 0
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
	descriptors_by_region[region_id] = descriptor
	region_states[region_id] = "registered" if bool(descriptor.get("loaded")) else "unloaded"
	topology_revision += 1
	registered_region_count += 1
	return {
		"status": "registered",
		"regionId": region_id,
		"tileKey": String(descriptor.get("tile_key")),
		"topologyRevision": topology_revision,
		"signature": descriptor.stable_signature() if descriptor.has_method("stable_signature") else ""
	}

func unregister_chunk(region_id: String) -> Dictionary:
	if not descriptors_by_region.has(region_id):
		return { "status": "missing", "regionId": region_id, "topologyRevision": topology_revision }
	descriptors_by_region.erase(region_id)
	region_states[region_id] = "unregistered"
	topology_revision += 1
	unregistered_region_count += 1
	return { "status": "unregistered", "regionId": region_id, "topologyRevision": topology_revision }

func closest_walkable(position: Vector3, max_distance := INF) -> Dictionary:
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
			var center: Vector3 = surface.get("center", Vector3.ZERO)
			var distance := position.distance_to(center)
			if distance <= max_distance and distance < best_distance:
				best_distance = distance
				best = {
					"found": true,
					"regionId": String(region_id),
					"surfaceId": String(surface.get("id", "")),
					"position": center,
					"distance": distance
				}
	if best.is_empty():
		return { "found": false, "reason": "no_walkable_surface", "position": position, "maxDistance": max_distance }
	return best

func query_route(start: Vector3, target: Vector3, options := {}) -> Dictionary:
	return {
		"status": "pending",
		"reason": "navmesh_query_not_live",
		"backend": backend_config.backend,
		"start": start,
		"target": target,
		"options": options,
		"topologyRevision": topology_revision
	}

func debug_snapshot() -> Dictionary:
	var regions := {}
	var keys := descriptors_by_region.keys()
	keys.sort()
	for region_id in keys:
		var descriptor = descriptors_by_region[region_id]
		regions[String(region_id)] = descriptor.to_summary() if descriptor != null and descriptor.has_method("to_summary") else {}
	return {
		"backend": backend_config.to_summary(),
		"hasNavigationMap": navigation_map.is_valid(),
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"regions": regions,
		"regionStates": region_states.duplicate(true)
	}

func stats() -> Dictionary:
	return {
		"backend": backend_config.backend,
		"navmeshEnabled": backend_config.use_navmesh(),
		"hasNavigationMap": navigation_map.is_valid(),
		"regionCount": descriptors_by_region.size(),
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"registeredRegionCount": registered_region_count,
		"unregisteredRegionCount": unregistered_region_count
	}

func _ensure_navigation_map() -> void:
	if navigation_map.is_valid():
		return
	navigation_map = NavigationServer3D.map_create()
	owns_navigation_map = true
