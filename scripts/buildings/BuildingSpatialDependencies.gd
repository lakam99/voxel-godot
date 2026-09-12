extends RefCounted
class_name BuildingSpatialDependencies

## Worker-compiled source dependencies. These are obligations, never an
## acknowledgement that geometry, collision or navigation has been published.
const Navigation = preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const FurnitureNavigation = preload("res://scripts/buildings/FurnishingNavigationManifestBuilder.gd")
const NavigationTiles = preload("res://scripts/buildings/BuildingNavigationTilePreparation.gd")
const PublicationGroups = preload("res://scripts/buildings/BuildingPublicationGroups.gd")
const NAV_TILE_CELLS := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd").NAV_TILE_CELL_SIZE
const CELL := 1.35
const OWNER_SIZE := CELL * 32.0
const MAX_PART_CELLS := 256
const SUPPORT_FIELDS := ["physicalSupportPartIds", "physicalRequiredSupportPartIds",
	"physicalRequiredSeatPartIds", "physicalRequiredRoofFramePartIds",
	"physicalAnchorPartIds", "physicalRequiredAnchorPartIds"]

var binding: Dictionary = {}
var origin := Vector3.ZERO
var parts: Dictionary = {}
var cells: Dictionary = {}
var navigation: Dictionary = {}
var furnishing_navigation: Dictionary = {}
var navigation_tiles: Dictionary = {}
var solid_records: Array[Dictionary] = []
var publication_groups: Dictionary = {}
var preparation_usec := 0

static func compile(blueprint, plan, source_binding: Dictionary, world_origin: Vector3, continuation: Callable):
	var started := Time.get_ticks_usec()
	var description = compile_description(blueprint,plan,source_binding,world_origin,continuation)
	if description == null: return null
	var packet = description.compile_navigation(continuation)
	if packet != null: packet.preparation_usec = Time.get_ticks_usec() - started
	return packet

## Complete source obligations without dense sampling or scene acknowledgement.
## The holder remains immutable when its dense sibling is compiled later.
static func compile_description(blueprint, plan, source_binding: Dictionary, world_origin: Vector3, continuation: Callable):
	var started := Time.get_ticks_usec()
	if not world_origin.is_finite(): return null
	var packet = load("res://scripts/buildings/BuildingSpatialDependencies.gd").new()
	packet.binding = source_binding.duplicate()
	packet.origin = world_origin
	for part in blueprint.parts:
		if not _continue(continuation, "publication_spatial_part"): return null
		var dependencies: Array[String] = []
		for field: String in SUPPORT_FIELDS:
			for id in part.recipe.get(field, []):
				var key := "building:" + String(id)
				if not dependencies.has(key): dependencies.append(key)
		var transform := Transform3D(Basis.from_euler(part.rotation), world_origin + part.position)
		var bounds := transform * AABB(-part.size * 0.5, part.size)
		if part.collision_enabled and part.kind!="door":
			packet.solid_records.append(Navigation._static_collision_fact(blueprint.id,part,transform,bounds))
		if not packet._add_part("building:" + part.id, part.id, "building", bounds, transform.origin, dependencies, bool(part.recipe.get("physicalRoot", false))): return null
	for part in plan.parts:
		if not _continue(continuation, "publication_spatial_furniture"): return null
		var transform := Transform3D(Basis.from_euler(part.rotation), world_origin + part.position)
		var size: Vector3 = part.occupied_size
		var bounds := transform * AABB(Vector3(-size.x * 0.5, 0, -size.z * 0.5), size)
		if not packet._add_part("furnishing:" + part.id, part.id, "furnishing", bounds, transform.origin, [], false): return null
	if not _continue(continuation, "publication_navigation_manifest"): return null
	packet.navigation = Navigation.build(blueprint, Transform3D(Basis.IDENTITY, world_origin))
	if not _continue(continuation, "publication_navigation_furnishing"): return null
	packet.furnishing_navigation = FurnitureNavigation.build(plan, Transform3D(Basis.IDENTITY, world_origin))
	packet.publication_groups = PublicationGroups.compile(blueprint,plan,packet.parts,world_origin,continuation)
	if packet.publication_groups.get("reason") == "cancelled": return null
	for key in packet.parts:
		packet.parts[key].dependencies.sort()
	for key in packet.cells:
		packet.cells[key].sort()
	for value in [packet.binding, packet.parts, packet.cells, packet.navigation, packet.furnishing_navigation,packet.navigation_tiles,packet.solid_records,packet.publication_groups]:
		if not _freeze(value, continuation): return null
	packet.preparation_usec = Time.get_ticks_usec() - started
	return packet

func compile_navigation(continuation: Callable):
	if not _continue(continuation,"publication_navigation_dense_started"): return null
	var navigation_result := NavigationTiles.compile(navigation,furnishing_navigation,continuation,solid_records)
	if not navigation_result.get("ready",false): return null
	if not _freeze(navigation_result,continuation): return null
	# Share only frozen source containers. Dense completion cannot modify the
	# compact holder already transferred through the worker phase boundary.
	var packet = get_script().new()
	packet.binding = binding
	packet.origin = origin
	packet.parts = parts
	packet.cells = cells
	packet.navigation = navigation
	packet.furnishing_navigation = furnishing_navigation
	packet.solid_records = solid_records
	packet.publication_groups = publication_groups
	packet.navigation_tiles = navigation_result
	packet.preparation_usec = preparation_usec + int(navigation_result.preparationUsec)
	return packet if _continue(continuation,"publication_spatial_ready") else null

func _add_part(key: String, source_id: String, kind: String, bounds: AABB, anchor: Vector3, dependencies: Array, terrain_root: bool) -> bool:
	if source_id.is_empty() or parts.has(key) or not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x <= 0 or bounds.size.y <= 0 or bounds.size.z <= 0:
		return false
	var owner := Vector2i(floori(anchor.x / OWNER_SIZE), floori(anchor.z / OWNER_SIZE))
	var low := Vector2i(floori(bounds.position.x / OWNER_SIZE), floori(bounds.position.z / OWNER_SIZE))
	var high := Vector2i(ceili(bounds.end.x / OWNER_SIZE)-1, ceili(bounds.end.z / OWNER_SIZE)-1)
	if (high.x-low.x+1)*(high.y-low.y+1) > MAX_PART_CELLS: return false
	parts[key] = {"sourcePartId":source_id, "kind":kind, "ownerCell":owner, "bounds":bounds,
		"dependencies":dependencies, "terrainRoot":terrain_root}
	for z in range(low.y, high.y+1):
		for x in range(low.x, high.x+1):
			var cell := Vector2i(x,z)
			if not cells.has(cell): cells[cell] = []
			cells[cell].append(key) # A reference to one owner; never a duplicate part.
	return true

func requirements(bounds: Rect2i, atomic_crossing_owners: Dictionary = {}, separate_dependency_bounds := false) -> Dictionary:
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return {"status":"failed", "reason":"invalid_dependency_bounds"}
	var required := {}
	var queue: Array[String] = []
	var roots: Array[AABB] = []
	var missing: Array[String] = []
	var owners := {}
	var required_crossings: Array[String] = []
	var crossing_requirements := {}
	var dependency_bounds := bounds
	var dependency_regions: Array[Rect2i] = [bounds]
	var dependency_seen: Dictionary = {bounds:true}
	var unresolved_crossings: Array[String] = []
	# Include complete edge cells; navigation retains its own existing grid.
	var minimum := Vector2(bounds.position) * CELL - Vector2.ONE * CELL * 0.5
	var maximum := Vector2(bounds.end) * CELL + Vector2.ONE * CELL * 0.5
	var query := Rect2(minimum, maximum-minimum)
	var low := Vector2i(floori(minimum.x/OWNER_SIZE),floori(minimum.y/OWNER_SIZE))
	var high := Vector2i(floori(maximum.x/OWNER_SIZE),floori(maximum.y/OWNER_SIZE))
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			for key: String in cells.get(Vector2i(x,z),[]):
				if _intersects(parts[key].bounds,query) and not required.has(key):
					required[key] = true
					queue.append(key)
	var spatial_parts: Array[String] = queue.duplicate()
	var support_parts := {}
	for support in navigation.supports:
		support_parts[String(support.id)] = "building:" + String(support.sourcePartId)
	for family: String in ["doors", "verticalLinks", "supportSeamLinks", "interiorPassageLinks"]:
		for crossing in navigation.get(family,[]):
			# Only declared geometry owners extend a spatial crossing request.
			# Endpoint supports are dependencies, never owners of all adjacency.
			var owned: bool = atomic_crossing_owners.has("building:"+String(crossing.get("sourcePartId",""))) \
				or atomic_crossing_owners.has("building:"+String(crossing.get("sourceCollisionPartId","")))
			if not owned and not _intersects(crossing.get("bounds",AABB()),query): continue
			required_crossings.append(String(crossing.id))
			var owner_tile := String(crossing.get("ownerTileKey", ""))
			var tile_keys: Array = crossing.get("tileKeys", []).duplicate()
			if not owner_tile.is_empty() and not tile_keys.has(owner_tile): tile_keys.append(owner_tile)
			tile_keys.sort()
			crossing_requirements[String(crossing.id)] = {
				"sourceId":String(crossing.id), "kind":family,
				"sourcePartId":String(crossing.get("sourcePartId", "")),
				"ownerTileKey":owner_tile, "tileKeys":tile_keys,
				"requiredLinkIds":[] if family == "doors" else [String(crossing.id)],
				"binding":binding, "mappingStatus":"pending" if family == "doors" else "described"}
			if owner_tile.is_empty() and not missing.has(String(crossing.id)): missing.append(String(crossing.id))
			for tile_key: String in tile_keys:
				var coordinates := tile_key.split(",")
				if coordinates.size() != 2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int():
					if not missing.has(String(crossing.id)): missing.append(String(crossing.id))
					continue
				var tile_bounds: Rect2i = Rect2i(Vector2i(int(coordinates[0]),int(coordinates[1]))*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS)
				if separate_dependency_bounds:
					if not dependency_seen.has(tile_bounds): dependency_seen[tile_bounds] = true; dependency_regions.append(tile_bounds)
				else: dependency_bounds = dependency_bounds.merge(tile_bounds)
			if family == "doors" and not bool(crossing.get("sourcePortalReady",false)) \
					or family == "verticalLinks" and not bool(crossing.get("endpointCertification",{}).get("resolved",false)):
				unresolved_crossings.append(String(crossing.id))
			var crossing_parts: Array = []
			for field: String in ["sourcePartId", "sourceCollisionPartId", "startSupportPartId", "endSupportPartId", "firstSupportPartId", "secondSupportPartId"]:
				if not String(crossing.get(field,"")).is_empty(): crossing_parts.append("building:"+String(crossing[field]))
			for field: String in ["supportId", "startSupportId", "endSupportId", "firstSupportId", "secondSupportId", "interiorSupportId", "exteriorSupportId"]:
				var id := String(crossing.get(field,""))
				if id.is_empty(): continue
				if support_parts.has(id): crossing_parts.append(support_parts[id])
				elif not missing.has(id): missing.append(id)
			for key: String in crossing_parts:
				if not required.has(key):
					required[key] = true
					queue.append(key)
	var cursor := 0
	while cursor < queue.size():
		var key := queue[cursor]
		cursor += 1
		if not parts.has(key):
			missing.append(key)
			continue
		var record: Dictionary = parts[key]
		var part_bounds: Rect2i = terrain_cells_for_bounds(record.bounds)
		if separate_dependency_bounds:
			if not dependency_seen.has(part_bounds): dependency_seen[part_bounds] = true; dependency_regions.append(part_bounds)
		else: dependency_bounds = dependency_bounds.merge(part_bounds)
		owners[record.ownerCell] = true
		if record.terrainRoot: roots.append(record.bounds)
		for dependency: String in record.dependencies:
			if not required.has(dependency):
				required[dependency] = true
				queue.append(dependency)
	queue.sort()
	required_crossings.sort()
	missing.sort()
	unresolved_crossings.sort()
	return {"status":"described", "binding":binding, "origin":origin, "partIds":queue,"spatialPartIds":spatial_parts,
		"dependencyBounds":dependency_regions if separate_dependency_bounds else [dependency_bounds], "sourceRevisions":{String(binding.get("siteId", "")):binding},
		"requiredCrossings":crossing_requirements,
		"ownerCells":owners.keys(), "terrainRootBounds":roots, "crossingIds":required_crossings,
		"missingSourceIds":missing, "unresolvedCrossingIds":unresolved_crossings,
		"publicationAcknowledged":false}

static func terrain_cells_for_bounds(world_bounds: AABB) -> Rect2i:
	# Match the existing cell-centred navigation grid, including boundary cells.
	var low := Vector2i(floori(world_bounds.position.x/CELL+0.5),floori(world_bounds.position.z/CELL+0.5))
	var high := Vector2i(floori(world_bounds.end.x/CELL+0.5),floori(world_bounds.end.z/CELL+0.5))
	return Rect2i(low,high-low+Vector2i.ONE)

## Resolve complete atomic groups and their directed support closure. This is
## source membership only: callers must obtain live receipts for every group.
## The existing crossing contract supplies endpoint/door dependencies first.
func group_requirements(bounds: Rect2i) -> Dictionary:
	if not publication_groups.get("ready",false):
		return {"status":"pending","reason":publication_groups.get("reason","publication_groups_pending")}
	var result: Dictionary = requirements(bounds,{},true)
	if result.get("status") != "described": return result
	var description: Dictionary = publication_groups
	var groups: Dictionary = description.groups
	var atomic_owners: Dictionary = {}
	for part_id: String in result.spatialPartIds:
		if not description.groupByPart.has(part_id):
			return {"status":"failed","reason":"publication_group_member_missing","sourcePartId":part_id}
		var group: Dictionary = groups[description.groupByPart[part_id]]
		for member: String in group.members:
			if member != part_id: atomic_owners[member] = true
	if not atomic_owners.is_empty():
		result = requirements(bounds,atomic_owners,true)
		if result.get("status") != "described": return result
	var required: Dictionary = {}
	var queue: Array[String] = []
	for part_id: String in result.partIds:
		if not description.groupByPart.has(part_id):
			return {"status":"failed","reason":"publication_group_member_missing","sourcePartId":part_id}
		var id: String = description.groupByPart[part_id]
		if not required.has(id): required[id] = true; queue.append(id)
	var minimum: Vector2 = Vector2(bounds.position)*CELL-Vector2.ONE*CELL*0.5
	var maximum: Vector2 = Vector2(bounds.end)*CELL+Vector2.ONE*CELL*0.5
	var query: Rect2 = Rect2(minimum,maximum-minimum)
	for tree_id: String in description.treeMembers:
		if not _intersects(description.treeMembers[tree_id].bounds,query): continue
		var id: String = description.groupByPart[tree_id]
		if not required.has(id): required[id] = true; queue.append(id)
	var cursor: int = 0
	while cursor < queue.size():
		var group: Dictionary = groups[queue[cursor]]
		cursor += 1
		for dependency: String in group.dependencies:
			if not groups.has(dependency):
				return {"status":"failed","reason":"publication_group_dependency_missing","groupId":dependency}
			if not required.has(dependency): required[dependency] = true; queue.append(dependency)
	queue.sort()
	var member_ids: Dictionary = {}
	var dependency_seen: Dictionary = {}
	for rectangle: Rect2i in result.dependencyBounds: dependency_seen[rectangle] = true
	for id: String in queue:
		var group: Dictionary = groups[id]
		for member: String in group.members: member_ids[member] = true
		# Keep disjoint source groups disjoint. Enclosing their union would turn
		# a long support chain into unrelated terrain/navigation demand.
		var rectangle: Rect2i = terrain_cells_for_bounds(group.bounds)
		if not dependency_seen.has(rectangle): dependency_seen[rectangle] = true; result.dependencyBounds.append(rectangle)
	var ordered_members: Array = member_ids.keys()
	ordered_members.sort()
	result["groupIds"] = queue
	result["groupMemberIds"] = ordered_members
	result["groupDescriptionComplete"] = true
	return result

func summary() -> Dictionary:
	return {"partCount":parts.size(),"consumerCellCount":cells.size(),"supportCount":navigation.get("supportCount",0),
		"doorCount":navigation.get("doorCount",0),"verticalLinkCount":navigation.get("verticalLinkCount",0),
		"supportSeamLinkCount":navigation.get("supportSeamLinkCount",0),"preparationUsec":preparation_usec,
		"navigationTiles":navigation_tiles.get("tiles",{}).size(),"navigationSamples":navigation_tiles.get("sampleCount",0),
		"navigationSurfaces":navigation_tiles.get("surfaceCount",0),"navigationPreparationUsec":navigation_tiles.get("preparationUsec",0),
		"unresolvedNavigationCrossings":navigation_tiles.get("unresolvedCrossingIds",[])}

static func _intersects(bounds: AABB, query: Rect2) -> bool:
	return query.intersects(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)),true)

static func _continue(callback: Callable, stage: String) -> bool:
	return not callback.is_valid() or callback.call(stage) == true

static func _freeze(value, callback: Callable) -> bool:
	if value is Dictionary:
		if not _continue(callback,"publication_spatial_freeze"): return false
		for item in value.values():
			if not _freeze(item,callback): return false
		value.make_read_only()
	elif value is Array:
		if not _continue(callback,"publication_spatial_freeze"): return false
		for item in value:
			if not _freeze(item,callback): return false
		value.make_read_only()
	return true
