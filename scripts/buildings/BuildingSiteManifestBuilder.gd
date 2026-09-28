extends RefCounted
class_name BuildingSiteManifestBuilder

## Geometry SOURCE contract only. No terrain, placement, support resolution,
## publication or physics validation. Call off the gameplay frame: bounded work
## is not a frame-time guarantee. Sources must not be mutated concurrently.
## Returned dictionaries/arrays are recursively read-only, with no source aliases.
## sourceSignature hashes original snapshot fields (including recipe, typed
## arrays and access reservations), not derived corners, cells or world pose.
## It is NOT alone a terrain-profile cache key: include cellSize/profile policy.
const Blueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan := preload("res://scripts/buildings/FurnishingPlan.gd")
const Part := preload("res://scripts/buildings/BuildingPart.gd")
const Furniture := preload("res://scripts/buildings/FurnishingPart.gd")
const SCHEMA := "building-site-manifest/v1"
const MAX_PARTS := 20000 # Combined building + furnishing records.
const MAX_TREE_RECORDS := 20000 # Trees + buttress records, separately bounded.
const MAX_VALUES := 2000000
const MAX_CONTAINER := 100000
const MAX_DEPTH := 64
const MAX_HASH_BYTES := 67108864
const LOCAL_GROUND_Y := 0.0 # Inherited BuildingBlueprint physical contract.
const GROUND_TOLERANCE := 0.06

## Canonical bounded typed-value digest used by immutable building-source
## boundaries. Dictionary ordering is normalized by _hash_value; JSON is never
## involved in source identity.
static func canonical_value_digest(value: Variant) -> String:
	var digest := HashingContext.new()
	if digest.start(HashingContext.HASH_SHA256) != OK: return ""
	var budget := {"values": 0, "bytes": 0, "reason": ""}
	if not _hash_value(value,digest,budget,0): return ""
	return digest.finish().hex_encode()


static func build(blueprint: Variant, furnishing_plan: Variant, cell_size: float = 1.35) -> Dictionary:
	if not blueprint is Blueprint or not furnishing_plan is Plan:
		return _reject("invalid_source_type")
	if not is_finite(cell_size) or cell_size <= 0.0:
		return _reject("invalid_cell_size")
	if blueprint.id.is_empty() or furnishing_plan.id.is_empty() or furnishing_plan.source_blueprint_id != blueprint.id:
		return _reject("invalid_source_identity")
	if blueprint.parts.size() + furnishing_plan.parts.size() > MAX_PARTS:
		return _reject("part_limit_exceeded")
	var records: Array = []
	var roots: Array = []
	var root_ids: Array = []
	var snapshots: Array = [[], []]
	var full_bounds := AABB()
	var have_bounds := false
	for namespace_index in range(2):
		var namespace_name := "building" if namespace_index == 0 else "furniture"
		var source_parts: Array = blueprint.parts if namespace_index == 0 else furnishing_plan.parts
		var ids := {}
		for part in source_parts:
			if (namespace_index == 0 and not part is Part) or (namespace_index == 1 and not part is Furniture):
				return _reject("invalid_part_type", namespace_name)
			if part.id.strip_edges().is_empty() or ids.has(part.id):
				return _reject("invalid_or_duplicate_part_id", namespace_name)
			ids[part.id] = true
			var size: Vector3 = part.size if namespace_index == 0 else part.occupied_size
			if not _positive_size(size) or not part.position.is_finite() or not part.rotation.is_finite():
				return _reject("invalid_part_geometry", namespace_name + ":" + part.id)
			var pose := Transform3D(Basis.from_euler(part.rotation), part.position)
			var corners := _corners(pose, size)
			if not _finite_corners(corners):
				return _reject("nonfinite_transformed_geometry", namespace_name + ":" + part.id)
			var bounds := _bounds(corners)
			full_bounds = full_bounds.merge(bounds) if have_bounds else bounds
			have_bounds = true
			records.append({"namespace": namespace_name, "id": part.id,
				"collision": part.collision_enabled, "corners": corners, "bounds": bounds})
			# Shallow snapshot shell matches the normal snapshot API, without its
			# unbounded recursive duplication before the typed hash walk's limits.
			var snapshot := {"id": part.id, "material": part.material_id,
				"position": part.position, "rotation": part.rotation,
				"collision": part.collision_enabled, "semantic": part.semantic, "recipe": part.recipe}
			if namespace_index == 0:
				snapshot.merge({"kind": part.kind, "size": size, "physicalIntent": part.physical_intent})
				var grounded: bool = blueprint.is_grounded_structural_root(part)
				if part.physical_intent == "structural_root" and not grounded:
					return _reject("ungrounded_declared_root", part.id)
				if grounded:
					# Winding around the actual transformed bottom face, not an AABB.
					var bottom: Array[Vector3] = [corners[0], corners[4], corners[5], corners[1]]
					roots.append({"partId": part.id, "corners": bottom})
					root_ids.append(part.id)
			else:
				snapshot.merge({"roomId": part.room_id, "archetype": part.archetype, "occupiedSize": size})
			snapshots[namespace_index].append(snapshot)
	if roots.is_empty():
		return _reject("missing_grounded_roots")
	var tree_result := _trees(blueprint.recipe)
	if not tree_result.ready:
		return tree_result
	for tree: Dictionary in tree_result.trees:
		full_bounds = full_bounds.merge(tree.bounds)
	var reservations: Array = []
	if furnishing_plan.protected_access_reservations.size() > MAX_CONTAINER:
		return _reject("reservation_limit_exceeded")
	for reservation: AABB in furnishing_plan.protected_access_reservations:
		if not reservation.position.is_finite() or not reservation.size.is_finite() or reservation.size.x <= 0.0 or reservation.size.z <= 0.0 or reservation.size.y < 0.0 or not reservation.end.is_finite():
			return _reject("invalid_access_reservation")
		reservations.append(reservation)
	if not full_bounds.position.is_finite() or not full_bounds.end.is_finite() or not _positive_size(full_bounds.size):
		return _reject("invalid_full_bounds")
	# A half-open rectangle of terrain SAMPLE NODES, not occupied cell boxes.
	# Include ceil(max/cellSize) itself: interpolation at a geometric boundary
	# must not fetch its adjacent sample from the later caller-owned slope apron.
	var edges := [floor(full_bounds.position.x / cell_size), floor(full_bounds.position.z / cell_size),
		ceil(full_bounds.end.x / cell_size) + 1.0, ceil(full_bounds.end.z / cell_size) + 1.0]
	# Conservative int32 headroom for Rect2i position, size AND end arithmetic.
	for edge: float in edges:
		if not is_finite(edge) or absf(edge) > 1000000000.0:
			return _reject("footprint_out_of_range")
	var minimum := Vector2i(int(edges[0]), int(edges[1]))
	var maximum := Vector2i(int(edges[2]), int(edges[3]))
	var source := {
		"blueprint": {"id": blueprint.id, "seed": blueprint.seed, "style": blueprint.style,
			"recipe": blueprint.recipe, "rooms": blueprint.rooms, "parts": snapshots[0]},
		"furnishingPlan": {"id": furnishing_plan.id, "seed": furnishing_plan.seed,
			"sourceBlueprintId": furnishing_plan.source_blueprint_id, "parts": snapshots[1],
			"egressDiagnostics": furnishing_plan.egress_diagnostics,
			"accessReservations": furnishing_plan.protected_access_reservations}}
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	var budget := {"values": 0, "bytes": 0, "reason": ""}
	if not _hash_value(source, digest, budget, 0):
		return _reject(budget.reason)
	return _freeze({"ready": true, "reason": "", "schema": SCHEMA, "publicationReady": false,
		"sourceSignature": digest.finish().hex_encode(), "blueprintId": blueprint.id,
		"furnishingPlanId": furnishing_plan.id, "coordinateSpace": "building_local",
		"cellSize": cell_size, "groundY": LOCAL_GROUND_Y, "localGroundY": LOCAL_GROUND_Y, "groundTolerance": GROUND_TOLERANCE,
		"parts": records, "supportRootIds": root_ids, "groundRoots": roots,
		"trees": tree_result.trees, "unknownHeightTreeIds": tree_result.unknownHeightTreeIds,
		"verticalBoundsComplete": tree_result.unknownHeightTreeIds.is_empty(),
		"localBounds": full_bounds, "footprintCells": Rect2i(minimum, maximum - minimum),
		"footprintSemantics": "half-open XZ sample-node rectangle; floor(min/cellSize) through ceil(max/cellSize) inclusive",
		"accessReservations": reservations,
		"boundsProvenance": "all declared transformed part boxes, tree canopy extents and buttress envelopes",
		"supportProvenance": "BuildingBlueprint.is_grounded_structural_root; actual bottom faces, not enclosing bounds"})


static func _trees(recipe: Dictionary) -> Dictionary:
	var urban: Variant = recipe.get("urbanPoc", {})
	if not urban is Dictionary or not urban.get("treePlacements", []) is Array:
		return _reject("invalid_tree_collection")
	var placements: Array = urban.get("treePlacements", [])
	if placements.size() > MAX_TREE_RECORDS:
		return _reject("tree_record_limit_exceeded")
	var trees: Array = []
	var unknown: Array = []
	var ids := {}
	var record_count := placements.size()
	for tree in placements:
		if not tree is Dictionary or not tree.get("id") is String or tree.id.strip_edges().is_empty():
			return _reject("invalid_tree_record")
		if ids.has(tree.id):
			return _reject("duplicate_tree_id", tree.id)
		ids[tree.id] = true
		if not tree.get("position") is Vector3 or not tree.position.is_finite() or not _positive_number(tree.get("canopyRadius")) or not tree.get("rootButtressFootprints") is Array:
			return _reject("invalid_tree_geometry", tree.id)
		if tree.has("rotationY") and not _finite_number(tree.rotationY):
			return _reject("invalid_tree_rotation", tree.id)
		if tree.has("treeRequest") and not tree.treeRequest is Dictionary:
			return _reject("invalid_tree_request", tree.id)
		if tree.get("treeRequest", {}).has("visualHeight") and not _positive_number(tree.treeRequest.visualHeight):
			return _reject("invalid_tree_height", tree.id)
		# Height must be declared, never guessed from radius or generated afresh.
		# A request visualHeight is a source envelope, NOT a measured mesh bound.
		var height: Variant = tree.get("height", tree.get("treeRequest", {}).get("visualHeight"))
		if height != null and not _positive_number(height):
			return _reject("invalid_tree_height", tree.id)
		if tree.has("height") and height == null:
			return _reject("invalid_tree_height", tree.id)
		var position: Vector3 = tree.position
		var radius := float(tree.canopyRadius)
		var canopy := AABB(position - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, float(height) if height != null else 0.0, radius * 2.0))
		var bounds := canopy
		var buttresses: Array = []
		record_count += tree.rootButtressFootprints.size()
		if record_count > MAX_TREE_RECORDS:
			return _reject("tree_record_limit_exceeded")
		for root in tree.rootButtressFootprints:
			if not root is Dictionary or not root.get("start") is Vector3 or not root.get("end") is Vector3:
				return _reject("invalid_tree_buttress", tree.id)
			if not root.start.is_finite() or not root.end.is_finite() or not _positive_number(root.get("radiusStart")) or not _positive_number(root.get("radiusEnd")):
				return _reject("invalid_tree_buttress", tree.id)
			# These endpoints already include tree position/rotation in source space.
			var r := maxf(float(root.radiusStart), float(root.radiusEnd))
			var root_bounds := AABB(root.start, Vector3.ZERO).expand(root.end).grow(r)
			bounds = bounds.merge(root_bounds)
			buttresses.append({"start": root.start, "end": root.end,
				"radiusStart": root.radiusStart, "radiusEnd": root.radiusEnd, "bounds": root_bounds})
		if not bounds.position.is_finite() or not bounds.end.is_finite():
			return _reject("nonfinite_tree_bounds", tree.id)
		if height == null:
			unknown.append(tree.id)
		trees.append({"namespace": "tree", "id": tree.id, "position": position,
			"trunkRadius": float(tree.get("treeRequest", {}).get("trunkRadius", 0.0)),
			"canopyRadius": radius, "height": height, "canopyBounds": canopy,
			"heightSource": "height" if tree.has("height") else "treeRequest.visualHeight" if height != null else "unknown",
			"rootButtressFootprints": buttresses, "bounds": bounds})
	return {"ready": true, "trees": trees, "unknownHeightTreeIds": unknown}


static func _corners(pose: Transform3D, size: Vector3) -> Array:
	var result: Array = []
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				result.append(pose * (size * Vector3(x, y, z)))
	return result


static func _finite_corners(corners: Array) -> bool:
	for point: Vector3 in corners:
		if not point.is_finite():
			return false
	return true


static func _bounds(corners: Array) -> AABB:
	var result := AABB(corners[0], Vector3.ZERO)
	for point: Vector3 in corners:
		result = result.expand(point)
	return result


static func _positive_size(size: Vector3) -> bool:
	return size.is_finite() and size.x > 0.0 and size.y > 0.0 and size.z > 0.0


static func _finite_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func _positive_number(value: Variant) -> bool:
	return _finite_number(value) and float(value) > 0.0


static func _hash_value(value: Variant, digest: HashingContext, budget: Dictionary, depth: int) -> bool:
	# Ordered arrays and typed scalars; dictionary insertion order is immaterial.
	# No JSON rounding, object serialization, hidden RNG or locale formatting.
	budget.values += 1
	if depth > MAX_DEPTH or budget.values > MAX_VALUES:
		budget.reason = "source_value_limit_exceeded"
		return false
	if value is Dictionary:
		if value.size() > MAX_CONTAINER or value.get_typed_key_builtin() == TYPE_OBJECT or value.get_typed_value_builtin() == TYPE_OBJECT:
			budget.reason = "source_container_limit_exceeded"
			return false
		var keys: Array = value.keys()
		var sort_bytes := 0
		var ordered: Array = []
		for key in keys:
			if typeof(key) in [TYPE_OBJECT, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_ARRAY, TYPE_DICTIONARY] or typeof(key) >= TYPE_PACKED_BYTE_ARRAY:
				budget.reason = "unsupported_source_dictionary_key"
				return false
			if (key is String or key is StringName) and str(key).length() > 262144:
				budget.reason = "source_string_limit_exceeded"
				return false
			var encoded := var_to_bytes(key)
			sort_bytes += encoded.size() * 2
			if sort_bytes + budget.bytes > MAX_HASH_BYTES:
				budget.reason = "source_byte_limit_exceeded"
				return false
			ordered.append({"key": key, "token": encoded.hex_encode()})
		ordered.sort_custom(func(a, b): return a.token < b.token)
		if not _feed([TYPE_DICTIONARY, keys.size(), value.get_typed_key_builtin(), value.get_typed_value_builtin()], digest, budget):
			return false
		for entry: Dictionary in ordered:
			var key: Variant = entry.key
			if not _hash_value(key, digest, budget, depth + 1) or not _hash_value(value[key], digest, budget, depth + 1):
				return false
		return true
	if value is Array:
		if value.size() > MAX_CONTAINER or value.get_typed_builtin() == TYPE_OBJECT:
			budget.reason = "unsupported_source_array"
			return false
		if not _feed([TYPE_ARRAY, value.size(), value.get_typed_builtin()], digest, budget):
			return false
		for element in value:
			if not _hash_value(element, digest, budget, depth + 1):
				return false
		return true
	if typeof(value) in [TYPE_OBJECT, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL]:
		budget.reason = "unsupported_source_value"
		return false
	if (value is String or value is StringName) and str(value).length() > 262144:
		budget.reason = "source_string_limit_exceeded"
		return false
	if typeof(value) >= TYPE_PACKED_BYTE_ARRAY:
		if value.size() > MAX_CONTAINER:
			budget.reason = "source_container_limit_exceeded"
			return false
		# Packed arrays retain their type in the header and are scanned too.
		if not _feed([typeof(value), value.size()], digest, budget):
			return false
		for element in value:
			if not _hash_value(element, digest, budget, depth + 1):
				return false
		return true
	return _feed(value, digest, budget)


static func _feed(value: Variant, digest: HashingContext, budget: Dictionary) -> bool:
	var bytes := var_to_bytes(value)
	budget.bytes += bytes.size() + 8
	if budget.bytes > MAX_HASH_BYTES:
		budget.reason = "source_byte_limit_exceeded"
		return false
	# Frame every atom, so adjacent container headers/scalars cannot alias.
	digest.update(var_to_bytes(bytes.size()))
	digest.update(bytes)
	return true


static func _freeze(value: Variant) -> Variant:
	if value is Dictionary:
		for key in value:
			_freeze(value[key])
		value.make_read_only()
	elif value is Array:
		for element in value:
			_freeze(element)
		value.make_read_only()
	return value


static func _reject(reason: String, source_id: String = "") -> Dictionary:
	return _freeze({"ready": false, "publicationReady": false, "reason": reason, "sourceId": source_id})
