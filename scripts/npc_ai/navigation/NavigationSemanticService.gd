extends RefCounted
class_name NavigationSemanticService

var semantic_revision := 0
var regions_by_id := {}
var regions_by_kind := {}

func clear() -> void:
	semantic_revision = 0
	regions_by_id.clear()
	regions_by_kind.clear()

func register_region(kind: StringName, region_id: String, bounds: AABB, metadata := {}) -> int:
	semantic_revision += 1
	var entry := {
		"id": region_id,
		"kind": String(kind),
		"bounds": bounds,
		"metadata": metadata.duplicate(),
		"revision": semantic_revision
	}
	regions_by_id[region_id] = entry
	if not regions_by_kind.has(String(kind)):
		regions_by_kind[String(kind)] = []
	var ids: Array = regions_by_kind[String(kind)]
	if not ids.has(region_id):
		ids.append(region_id)
	return semantic_revision

func register_home(building_id: String, interior_bounds: AABB, anchors := {}, entrance_metadata := {}) -> int:
	var metadata := {
		"buildingId": building_id,
		"anchors": anchors.duplicate(),
		"entrance": entrance_metadata.duplicate(),
		"inside": true
	}
	return register_region(&"home_interior", "home:%s" % building_id, interior_bounds, metadata)

func register_guard_post(post_id: String, bounds: AABB, metadata := {}) -> int:
	return register_region(&"guard_post", "guard:%s" % post_id, bounds, metadata)

func register_road(anchor_id: String, bounds: AABB, metadata := {}) -> int:
	return register_region(&"road", "road:%s" % anchor_id, bounds, metadata)

func register_work_anchor(anchor_id: String, bounds: AABB, metadata := {}) -> int:
	return register_region(&"work_anchor", "work:%s" % anchor_id, bounds, metadata)

func region(region_id: String) -> Dictionary:
	return regions_by_id.get(region_id, {})

func regions_for_kind(kind: StringName) -> Array:
	var result: Array = []
	for region_id in regions_by_kind.get(String(kind), []):
		result.append(regions_by_id.get(region_id, {}))
	return result

func regions_at_position(position: Vector3, kind_filter := &"") -> Array:
	var result: Array = []
	for entry in regions_by_id.values():
		if kind_filter != &"" and String(entry.get("kind", "")) != String(kind_filter):
			continue
		var bounds: AABB = entry.get("bounds", AABB())
		if bounds.has_point(position):
			result.append(entry)
	return result

func stats() -> Dictionary:
	return {
		"semanticRevision": semantic_revision,
		"regionCount": regions_by_id.size(),
		"kinds": regions_by_kind.keys()
	}

func to_summary() -> Dictionary:
	var ids := regions_by_id.keys()
	ids.sort()
	return {
		"semanticRevision": semantic_revision,
		"regionIds": ids,
		"regionCount": ids.size()
	}
