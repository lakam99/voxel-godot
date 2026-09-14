extends RefCounted
class_name BuildingSpatialDependencies

## Worker-compiled source dependencies. These are obligations, never an
## acknowledgement that geometry, collision or navigation has been published.
const Navigation = preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const FurnitureNavigation = preload("res://scripts/buildings/FurnishingNavigationManifestBuilder.gd")
const NavigationTiles = preload("res://scripts/buildings/BuildingNavigationTilePreparation.gd")
const PublicationGroups = preload("res://scripts/buildings/BuildingPublicationGroups.gd")
const SiteManifest = preload("res://scripts/buildings/BuildingSiteManifestBuilder.gd")
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
## Immutable source-membership records keyed by the navigation tile that owns
## the request. These are scheduling facts only; scene publication still
## validates every live collision/member receipt at its acceptance boundary.
var regional_tile_requirements: Dictionary = {}
var regional_tile_index_ready := false
## Prepared whole-source membership for the common case where a retained
## player region encloses the source. Query-specific outer tiles are added at
## runtime; collision acknowledgement is deliberately absent.
var regional_full_requirements: Dictionary = {}
var solid_records: Array[Dictionary] = []
var publication_groups: Dictionary = {}
var source_identity_digest := ""
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
	if not packet._compile_regional_tile_requirements(continuation): return null
	for key in packet.parts:
		packet.parts[key].dependencies.sort()
	for key in packet.cells:
		packet.cells[key].sort()
	for value in [packet.binding, packet.parts, packet.cells, packet.navigation, packet.furnishing_navigation,
			packet.navigation_tiles,packet.regional_tile_requirements,packet.regional_full_requirements,
			packet.solid_records,packet.publication_groups]:
		if not _freeze(value, continuation): return null
	packet.source_identity_digest = SiteManifest.canonical_value_digest([packet.parts,packet.cells,packet.navigation,
		packet.furnishing_navigation,packet.regional_tile_requirements,packet.regional_full_requirements,
		packet.regional_tile_index_ready,
		packet.solid_records,packet.publication_groups])
	if packet.source_identity_digest.length()!=64: return null
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
	packet.source_identity_digest = source_identity_digest
	packet.navigation_tiles = navigation_result
	packet.regional_tile_requirements = regional_tile_requirements
	packet.regional_full_requirements = regional_full_requirements
	packet.regional_tile_index_ready = regional_tile_index_ready
	packet.preparation_usec = preparation_usec + int(navigation_result.preparationUsec)
	return packet if _continue(continuation,"publication_spatial_ready") else null


## Compile the immutable per-tile source closure once on the preparation
## worker. Runtime queries combine these small records and never rescan every
## Citadel crossing or publication group as the player's bounds move.
func _compile_regional_tile_requirements(continuation: Callable) -> bool:
	# Preserve the existing diagnostic description for malformed/synthetic
	# sources. Only a semantically complete publication graph is indexable.
	if not publication_groups.get("ready",false): return true
	var seeds: Dictionary = {}
	var part_seeds: Dictionary = {}
	var crossings_by_tile: Dictionary = {}
	var missing_by_tile: Dictionary = {}
	var unresolved_by_tile: Dictionary = {}
	var groups: Dictionary = publication_groups.groups
	var by_part: Dictionary = publication_groups.groupByPart
	for key: String in parts:
		if not _continue(continuation,"publication_regional_membership_index"): return false
		if not by_part.has(key): return false
		for tile_key: String in _navigation_tile_keys_for_world_bounds(parts[key].bounds):
			_tile_set(seeds,tile_key)[String(by_part[key])] = true
			_tile_set(part_seeds,tile_key)[key] = true
	for key: String in publication_groups.get("treeMembers",{}):
		if not _continue(continuation,"publication_regional_membership_index"): return false
		if not by_part.has(key): return false
		var tree: Dictionary = publication_groups.treeMembers[key]
		for tile_key: String in _navigation_tile_keys_for_world_bounds(tree.bounds):
			_tile_set(seeds,tile_key)[String(by_part[key])] = true
	var support_parts: Dictionary = {}
	for support in navigation.get("supports",[]):
		support_parts[String(support.id)] = "building:"+String(support.sourcePartId)
	for family: String in ["doors","verticalLinks","supportSeamLinks","interiorPassageLinks"]:
		for crossing in navigation.get(family,[]):
			if not _continue(continuation,"publication_regional_crossing_index"): return false
			var owner_tile := String(crossing.get("ownerTileKey",""))
			# Regional publication already rejects ownerless crossings from local
			# tile demand. Preserve that rule in the prepared index.
			if owner_tile.is_empty(): continue
			var coordinates := owner_tile.split(",")
			if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): continue
			var tile_keys: Array = crossing.get("tileKeys",[]).duplicate()
			if not tile_keys.has(owner_tile): tile_keys.append(owner_tile)
			tile_keys.sort()
			var id := String(crossing.id)
			_tile_set(crossings_by_tile,owner_tile)[id] = {
				"sourceId":id,"kind":family,"sourcePartId":String(crossing.get("sourcePartId","")),
				"ownerTileKey":owner_tile,"tileKeys":tile_keys,
				"requiredLinkIds":[] if family=="doors" else [id],"binding":binding,
				"mappingStatus":"pending" if family=="doors" else "described"}
			if family=="doors" and not bool(crossing.get("sourcePortalReady",false)) \
					or family=="verticalLinks" and not bool(crossing.get("endpointCertification",{}).get("resolved",false)):
				_tile_set(unresolved_by_tile,owner_tile)[id] = true
			var crossing_parts: Array[String] = []
			for field: String in ["sourcePartId","sourceCollisionPartId","startSupportPartId","endSupportPartId","firstSupportPartId","secondSupportPartId"]:
				var part_id := String(crossing.get(field,""))
				if not part_id.is_empty(): crossing_parts.append("building:"+part_id)
			for field: String in ["supportId","startSupportId","endSupportId","firstSupportId","secondSupportId","interiorSupportId","exteriorSupportId"]:
				var support_id := String(crossing.get(field,""))
				if support_id.is_empty(): continue
				if support_parts.has(support_id): crossing_parts.append(String(support_parts[support_id]))
				else: _tile_set(missing_by_tile,owner_tile)[support_id] = true
			for part_key: String in crossing_parts:
				if not by_part.has(part_key): _tile_set(missing_by_tile,owner_tile)[part_key] = true
	var tile_keys: Dictionary = {}
	for source: Dictionary in [seeds,part_seeds,crossings_by_tile,missing_by_tile,unresolved_by_tile]:
		for tile_key: String in source: tile_keys[tile_key] = true
	var ordered_tiles: Array = tile_keys.keys()
	ordered_tiles.sort()
	for tile_key: String in ordered_tiles:
		if not _continue(continuation,"publication_regional_closure_index"): return false
		# Store only direct membership seeds. A moving regional query can cover
		# many tiles whose group closures largely overlap; retaining every
		# expanded closure made it merge the same thousands of IDs once per
		# tile. The immutable shared publication graph is closed once after all
		# queried tile seeds have been combined.
		var group_seeds: Array = seeds.get(tile_key,{}).keys()
		group_seeds.sort()
		for group_id: String in group_seeds:
			if not groups.has(group_id): return false
		var coordinates := tile_key.split(",")
		var dependency_bounds: Dictionary = {Rect2i(Vector2i(int(coordinates[0]),int(coordinates[1]))*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS):true}
		var required_parts: Dictionary = part_seeds.get(tile_key,{}).duplicate()
		var part_queue: Array = required_parts.keys()
		var part_cursor := 0
		while part_cursor < part_queue.size():
			var part_key := String(part_queue[part_cursor])
			part_cursor += 1
			if not parts.has(part_key):
				_tile_set(missing_by_tile,tile_key)[part_key]=true
				continue
			var part: Dictionary = parts[part_key]
			dependency_bounds[terrain_cells_for_bounds(part.bounds)] = true
			for dependency: String in part.dependencies:
				if not required_parts.has(dependency): required_parts[dependency]=true; part_queue.append(dependency)
		var crossing_ids: Array = crossings_by_tile.get(tile_key,{}).keys()
		crossing_ids.sort()
		var missing_ids: Array = missing_by_tile.get(tile_key,{}).keys()
		missing_ids.sort()
		var unresolved_ids: Array = unresolved_by_tile.get(tile_key,{}).keys()
		unresolved_ids.sort()
		regional_tile_requirements[tile_key] = {"groupSeedIds":group_seeds,
			"dependencyBounds":dependency_bounds.keys(),"requiredCrossings":crossings_by_tile.get(tile_key,{}),
			"crossingIds":crossing_ids,"missingSourceIds":missing_ids,"unresolvedCrossingIds":unresolved_ids}
	regional_tile_index_ready = true
	# A normal player retention ring generally encloses the complete Citadel.
	# Prepare that closure off the gameplay thread instead of rebuilding a
	# 3,000+ group union when the player crosses a coarse streaming cell.
	if not ordered_tiles.is_empty():
		var first_coordinates: PackedStringArray = String(ordered_tiles[0]).split(",")
		var minimum_tile := Vector2i(int(first_coordinates[0]),int(first_coordinates[1]))
		var maximum_tile := minimum_tile
		for tile_key: String in ordered_tiles:
			var tile_coordinates: PackedStringArray = tile_key.split(",")
			var tile := Vector2i(int(tile_coordinates[0]),int(tile_coordinates[1]))
			minimum_tile=minimum_tile.min(tile)
			maximum_tile=maximum_tile.max(tile)
		var source_bounds := Rect2i(minimum_tile*NAV_TILE_CELLS,(maximum_tile-minimum_tile+Vector2i.ONE)*NAV_TILE_CELLS)
		var full: Dictionary = _legacy_regional_group_requirements(source_bounds)
		if full.get("status")!="described": return false
		var query_regions: Dictionary = {source_bounds:true}
		for tile_key: String in _navigation_tile_keys_for_cells(source_bounds):
			var tile_coordinates: PackedStringArray = tile_key.split(",")
			query_regions[Rect2i(Vector2i(int(tile_coordinates[0]),int(tile_coordinates[1]))*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS)]=true
		var source_regions: Array = []
		for rectangle: Rect2i in full.get("dependencyBounds",[]):
			if not query_regions.has(rectangle): source_regions.append(rectangle)
		full["dependencyBounds"]=source_regions
		full["sourceBounds"]=source_bounds
		full.erase("domainBounds")
		full.erase("navigationTileKeys")
		regional_full_requirements=full
	return true


static func _tile_set(index: Dictionary, tile_key: String) -> Dictionary:
	if not index.has(tile_key): index[tile_key] = {}
	return index[tile_key]


static func _navigation_tile_keys_for_cells(bounds: Rect2i) -> Array[String]:
	var result: Array[String] = []
	if bounds.size.x<=0 or bounds.size.y<=0: return result
	var low := Vector2i(floori(float(bounds.position.x)/NAV_TILE_CELLS),floori(float(bounds.position.y)/NAV_TILE_CELLS))
	var high := Vector2i(floori(float(bounds.end.x-1)/NAV_TILE_CELLS),floori(float(bounds.end.y-1)/NAV_TILE_CELLS))
	for z: int in range(low.y,high.y+1):
		for x: int in range(low.x,high.x+1): result.append("%d,%d" % [x,z])
	return result


## requirements() expands the queried cell rectangle by half a cell at each
## edge. Inverting that test adds one candidate cell before the ordinary
## terrain-cell range while retaining its inclusive upper edge.
static func _navigation_tile_keys_for_world_bounds(bounds: AABB) -> Array[String]:
	var cells := terrain_cells_for_bounds(bounds)
	return _navigation_tile_keys_for_cells(Rect2i(cells.position-Vector2i.ONE,cells.size+Vector2i.ONE))

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

func requirements(bounds: Rect2i, atomic_crossing_owners: Dictionary = {}, separate_dependency_bounds := false, discover_crossings := true) -> Dictionary:
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
	if discover_crossings:
		for support in navigation.supports:
			support_parts[String(support.id)] = "building:" + String(support.sourcePartId)
	var crossing_families: Array = ["doors", "verticalLinks", "supportSeamLinks", "interiorPassageLinks"] if discover_crossings else []
	for family: String in crossing_families:
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
func group_requirements(bounds: Rect2i, discover_crossings := true) -> Dictionary:
	if not publication_groups.get("ready",false):
		return {"status":"pending","reason":publication_groups.get("reason","publication_groups_pending")}
	var result: Dictionary = requirements(bounds,{},true,discover_crossings)
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
	if discover_crossings and not atomic_owners.is_empty():
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

func physical_group_requirements(bounds: Rect2i) -> Dictionary:
	return group_requirements(bounds,false)

## A retained consumer may touch the source reservation before any of its
## current navigation tiles intersects a physical member.  Select one real,
## collision-bearing structural group at that boundary so packet publication
## can begin before the player reaches invisible source geometry.  This remains
## source membership only: the caller must still obtain the live packet receipt
## and revalidate collision at its acceptance boundary.
##
## `eligible_group_ids` is an optional worker capability filter.  It never
## declares a group ready; it merely avoids choosing a closure that the current
## immutable publication base cannot compile.
func exterior_structural_group_requirements(bounds: Rect2i, eligible_group_ids: Dictionary = {}) -> Dictionary:
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return {"status":"failed","reason":"invalid_dependency_bounds"}
	if not publication_groups.get("ready",false):
		return {"status":"pending","reason":publication_groups.get("reason","publication_groups_pending")}
	var groups: Dictionary = publication_groups.groups
	var candidates: Array[Dictionary] = []
	var query: Rect2 = _world_rect_for_cells(bounds)
	for id: String in groups:
		var group: Dictionary = groups[id]
		# Foliage and furnishing-only groups cannot make a structure boundary
		# physically legible.  Select declared building collision ownership.
		if group.get("buildingIndices",[]).is_empty() or not bool(group.get("hasCollision",false)):
			continue
		var closure: Dictionary = _publication_group_closure(id)
		if closure.get("status")!="described": return closure
		if not eligible_group_ids.is_empty():
			var eligible := true
			for required_id: String in closure.groupIds:
				if not eligible_group_ids.has(required_id):
					eligible = false
					break
			if not eligible: continue
		var collision_bounds: AABB = group.get("collisionBounds",group.bounds)
		candidates.append({"id":id,"distanceSquared":_rect_aabb_distance_squared(query,collision_bounds),"closure":closure})
	if candidates.is_empty():
		return {"status":"pending","reason":"exterior_structural_group_unavailable"}
	candidates.sort_custom(func(a: Dictionary,b: Dictionary):
		return String(a.id)<String(b.id) if is_equal_approx(float(a.distanceSquared),float(b.distanceSquared)) else float(a.distanceSquared)<float(b.distanceSquared))
	var selected: Dictionary = candidates[0]
	var result: Dictionary = selected.closure.duplicate(true)
	result["boundaryGroupId"] = selected.id
	result["boundaryDistanceSquared"] = selected.distanceSquared
	result["boundarySelection"] = "nearest_collision_bearing_structural_group"
	return result

func _publication_group_closure(first_id: String) -> Dictionary:
	if not publication_groups.get("groups",{}).has(first_id):
		return {"status":"failed","reason":"publication_group_missing","groupId":first_id}
	var groups: Dictionary = publication_groups.groups
	var selected: Dictionary = {first_id:true}
	var queue: Array[String] = [first_id]
	var cursor := 0
	while cursor < queue.size():
		var id: String = queue[cursor]
		cursor += 1
		var group: Dictionary = groups.get(id,{})
		if group.is_empty(): return {"status":"failed","reason":"publication_group_dependency_missing","groupId":id}
		for dependency: String in group.get("dependencies",[]):
			if not groups.has(dependency): return {"status":"failed","reason":"publication_group_dependency_missing","groupId":dependency}
			if not selected.has(dependency):
				selected[dependency] = true
				queue.append(dependency)
	queue.sort()
	var members: Dictionary = {}
	var dependency_bounds: Dictionary = {}
	for id: String in queue:
		var group: Dictionary = groups[id]
		for member: String in group.members: members[member] = true
		var group_cells: Rect2i = terrain_cells_for_bounds(group.bounds)
		dependency_bounds[group_cells] = true
	var member_ids: Array = members.keys()
	member_ids.sort()
	return {"status":"described","binding":binding,"origin":origin,"groupIds":queue,
		"groupMemberIds":member_ids,"dependencyBounds":dependency_bounds.keys(),
		"groupDescriptionComplete":true,"publicationAcknowledged":false}

static func _world_rect_for_cells(bounds: Rect2i) -> Rect2:
	var minimum := Vector2(bounds.position)*CELL-Vector2.ONE*CELL*0.5
	var maximum := Vector2(bounds.end)*CELL+Vector2.ONE*CELL*0.5
	return Rect2(minimum,maximum-minimum)

static func _rect_aabb_distance_squared(query: Rect2, bounds: AABB) -> float:
	var other := Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z))
	var dx := maxf(maxf(query.position.x-other.end.x,other.position.x-query.end.x),0.0)
	var dz := maxf(maxf(query.position.y-other.end.y,other.position.y-query.end.y),0.0)
	return dx*dx+dz*dz

## One source closes the consumer's actual navigation grid before retention.
## Added tile-edge geometry contributes physical supports, never new outgoing
## crossings. Thus a tile cannot recursively turn into adjacent site demand.
func regional_group_requirements(bounds: Rect2i) -> Dictionary:
	if regional_tile_index_ready:
		if not regional_full_requirements.is_empty() and bounds.encloses(regional_full_requirements.get("sourceBounds",Rect2i())):
			return _full_regional_group_requirements(bounds)
		return _indexed_regional_group_requirements(bounds)
	return _legacy_regional_group_requirements(bounds)


## Compact scheduling contract. Retention needs immutable group identity,
## source-owned domain bounds and crossing obligations. It does not consume
## thousands of part/member records, so do not reconstruct them on a gameplay
## frame. Fresh physical acceptance continues through the scene job.
func regional_scheduling_requirements(bounds: Rect2i) -> Dictionary:
	if not regional_tile_index_ready: return regional_group_requirements(bounds)
	if bounds.size.x<=0 or bounds.size.y<=0:
		return {"status":"failed","reason":"invalid_dependency_bounds"}
	var low := Vector2i(floori(float(bounds.position.x)/NAV_TILE_CELLS),floori(float(bounds.position.y)/NAV_TILE_CELLS))
	var high := Vector2i(floori(float(bounds.end.x-1)/NAV_TILE_CELLS),floori(float(bounds.end.y-1)/NAV_TILE_CELLS))
	var tiles: Dictionary={}
	var selected: Dictionary={}
	var regions: Dictionary={bounds:true}
	var crossings: Dictionary={}
	var missing: Dictionary={}
	var unresolved: Dictionary={}
	for z: int in range(low.y,high.y+1):
		for x: int in range(low.x,high.x+1):
			var tile:=Vector2i(x,z)
			var key:="%d,%d" % [x,z]
			tiles[key]=tile
			regions[Rect2i(tile*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS)]=true
			var indexed: Dictionary=regional_tile_requirements.get(key,{})
			for id: String in indexed.get("groupSeedIds",[]): selected[id]=true
			for rectangle: Rect2i in indexed.get("dependencyBounds",[]): regions[rectangle]=true
			for id: String in indexed.get("requiredCrossings",{}): crossings[id]=indexed.requiredCrossings[id]
			for id: String in indexed.get("missingSourceIds",[]): missing[id]=true
			for id: String in indexed.get("unresolvedCrossingIds",[]): unresolved[id]=true
			if tiles.size()>512: return {"status":"pending","reason":"source_navigation_dependency_capacity"}
	var publication: Dictionary=publication_groups.get("groups",{})
	var group_ids: Array=selected.keys()
	var cursor:=0
	while cursor<group_ids.size():
		var group_id:=String(group_ids[cursor])
		cursor+=1
		if not publication.has(group_id):
			return {"status":"failed","reason":"publication_group_dependency_missing","groupId":group_id}
		for dependency: String in publication[group_id].get("dependencies",[]):
			if not publication.has(dependency):
				return {"status":"failed","reason":"publication_group_dependency_missing","groupId":dependency}
			if not selected.has(dependency): selected[dependency]=true; group_ids.append(dependency)
	group_ids.sort()
	for group_id: String in group_ids: regions[terrain_cells_for_bounds(publication[group_id].bounds)]=true
	var keys: Array=tiles.keys(); keys.sort()
	var navigation_regions: Array=[]
	for key: String in keys: navigation_regions.append(Rect2i(tiles[key]*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS))
	var crossing_ids: Array=crossings.keys(); crossing_ids.sort()
	var missing_ids: Array=missing.keys(); missing_ids.sort()
	var unresolved_ids: Array=unresolved.keys(); unresolved_ids.sort()
	var dependency_bounds: Array=regions.keys()
	return {"status":"described","reason":"","binding":binding,"origin":origin,
		"groupIds":group_ids,"dependencyBounds":dependency_bounds,"requiredCrossings":crossings,
		"crossingIds":crossing_ids,"missingSourceIds":missing_ids,"unresolvedCrossingIds":unresolved_ids,
		"groupDescriptionComplete":true,"navigationTileKeys":keys,"publicationAcknowledged":false,
		"domainBounds":{"terrain":dependency_bounds.duplicate(),"render":dependency_bounds.duplicate(),"navigation":navigation_regions}}


func _full_regional_group_requirements(bounds: Rect2i) -> Dictionary:
	if bounds.size.x<=0 or bounds.size.y<=0:
		return {"status":"failed","reason":"invalid_dependency_bounds"}
	var result: Dictionary=regional_full_requirements.duplicate(false)
	var regions: Dictionary={bounds:true}
	for rectangle: Rect2i in regional_full_requirements.get("dependencyBounds",[]): regions[rectangle]=true
	var tiles: Dictionary={}
	var low := Vector2i(floori(float(bounds.position.x)/NAV_TILE_CELLS),floori(float(bounds.position.y)/NAV_TILE_CELLS))
	var high := Vector2i(floori(float(bounds.end.x-1)/NAV_TILE_CELLS),floori(float(bounds.end.y-1)/NAV_TILE_CELLS))
	for z: int in range(low.y,high.y+1):
		for x: int in range(low.x,high.x+1):
			var tile:=Vector2i(x,z)
			tiles["%d,%d" % [x,z]]=tile
			regions[Rect2i(tile*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS)]=true
			if tiles.size()>512: return {"status":"pending","reason":"source_navigation_dependency_capacity"}
	var keys: Array=tiles.keys()
	keys.sort()
	var navigation_regions: Array=[]
	for key: String in keys: navigation_regions.append(Rect2i(tiles[key]*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS))
	result["dependencyBounds"]=regions.keys()
	result["navigationTileKeys"]=keys
	result["domainBounds"]={"terrain":result.dependencyBounds.duplicate(),"render":result.dependencyBounds.duplicate(),"navigation":navigation_regions}
	return result


func _indexed_regional_group_requirements(bounds: Rect2i) -> Dictionary:
	if bounds.size.x<=0 or bounds.size.y<=0:
		return {"status":"failed","reason":"invalid_dependency_bounds"}
	# Preserve exact local part/root and crossing discovery through the spatial
	# query. Crossing ownership depends on both a local source witness and its
	# declared owner tile, so a tile-only index would over-select remote seams.
	# The expensive publication-group closure still comes from the worker index.
	var result: Dictionary = requirements(bounds,{},true,true)
	if result.get("status")!="described": return result
	var tiles: Dictionary = {}
	var low := Vector2i(floori(float(bounds.position.x)/NAV_TILE_CELLS),floori(float(bounds.position.y)/NAV_TILE_CELLS))
	var high := Vector2i(floori(float(bounds.end.x-1)/NAV_TILE_CELLS),floori(float(bounds.end.y-1)/NAV_TILE_CELLS))
	for z: int in range(low.y,high.y+1):
		for x: int in range(low.x,high.x+1):
			tiles["%d,%d" % [x,z]] = Vector2i(x,z)
			if tiles.size()>512: return {"status":"pending","reason":"source_navigation_dependency_capacity"}
	var group_seeds: Dictionary = {}
	var regions: Dictionary = {bounds:true}
	var crossings: Dictionary = {}
	var missing: Dictionary = {}
	var unresolved: Dictionary = {}
	for id: String in result.get("missingSourceIds",[]): missing[id]=true
	for id: String in result.get("requiredCrossings",{}):
		var crossing: Dictionary = result.requiredCrossings[id]
		if not tiles.has(String(crossing.get("ownerTileKey",""))): continue
		crossings[id]=crossing
		if result.get("unresolvedCrossingIds",[]).has(id): unresolved[id]=true
	var keys: Array = tiles.keys()
	keys.sort()
	for key: String in keys:
		var indexed: Dictionary = regional_tile_requirements.get(key,{})
		# Each queried navigation tile is itself an authoritative dependency
		# region, including empty source tiles. The legacy closure obtained this
		# from physical_group_requirements() once per tile.
		regions[Rect2i(tiles[key]*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS)]=true
		for id: String in indexed.get("groupSeedIds",[]): group_seeds[id]=true
		for rectangle: Rect2i in indexed.get("dependencyBounds",[]): regions[rectangle]=true
		for id: String in indexed.get("missingSourceIds",[]): missing[id]=true
	# Close the union once against the immutable publication graph. This keeps
	# exact group/member/bounds parity with the legacy query while avoiding
	# repeated expansion for overlapping tile closures.
	var publication: Dictionary = publication_groups.get("groups",{})
	var selected: Dictionary = group_seeds.duplicate()
	var group_ids: Array = selected.keys()
	var cursor := 0
	while cursor<group_ids.size():
		var group_id := String(group_ids[cursor])
		cursor += 1
		if not publication.has(group_id):
			return {"status":"failed","reason":"publication_group_dependency_missing","groupId":group_id}
		for dependency: String in publication[group_id].get("dependencies",[]):
			if not publication.has(dependency):
				return {"status":"failed","reason":"publication_group_dependency_missing","groupId":dependency}
			if not selected.has(dependency): selected[dependency]=true; group_ids.append(dependency)
	group_ids.sort()
	var members: Dictionary = {}
	for group_id: String in group_ids:
		var group: Dictionary = publication[group_id]
		for member: String in group.get("members",[]): members[member]=true
		regions[terrain_cells_for_bounds(group.bounds)]=true
	result.groupIds = group_ids
	result.groupMemberIds = members.keys(); result.groupMemberIds.sort()
	result.dependencyBounds = regions.keys()
	result.requiredCrossings = crossings
	result.crossingIds = crossings.keys(); result.crossingIds.sort()
	result.missingSourceIds = missing.keys(); result.missingSourceIds.sort()
	result.unresolvedCrossingIds = unresolved.keys(); result.unresolvedCrossingIds.sort()
	result["groupDescriptionComplete"] = true
	result["navigationTileKeys"] = keys
	var navigation_regions: Array = []
	for key: String in keys: navigation_regions.append(Rect2i(tiles[key]*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS))
	result["domainBounds"] = {"terrain":result.dependencyBounds.duplicate(),"render":result.dependencyBounds.duplicate(),"navigation":navigation_regions}
	return result


func _legacy_regional_group_requirements(bounds: Rect2i) -> Dictionary:
	# Navigation streaming selects crossing obligations from the queried surface
	# boundary itself. A physical publication group can intentionally contain
	# distant aperture peers, but that atomic collision ownership must not make
	# every peer-owned door, stair, or seam part of this local navigation
	# request. Per-tile physical requirements below still add every support that
	# the queried tiles actually need.
	var result: Dictionary = requirements(bounds,{},true,true)
	if result.get("status")!="described": return result
	result["groupIds"] = []
	result["groupMemberIds"] = []
	result["groupDescriptionComplete"] = true
	var tiles: Dictionary = {}
	var local_tiles: Dictionary = {}
	var low := Vector2i(floori(float(bounds.position.x)/NAV_TILE_CELLS),floori(float(bounds.position.y)/NAV_TILE_CELLS))
	var high := Vector2i(floori(float(bounds.end.x-1)/NAV_TILE_CELLS),floori(float(bounds.end.y-1)/NAV_TILE_CELLS))
	for z: int in range(low.y,high.y+1):
		for x: int in range(low.x,high.x+1):
			var key := "%d,%d" % [x,z]
			tiles[key] = Vector2i(x,z)
			local_tiles[key] = true
			if tiles.size()>512: return {"status":"pending","reason":"source_navigation_dependency_capacity"}
	# A crossing whose semantic tiles are elsewhere does not become local merely
	# because its long source mesh overlaps this tile. It is admitted when its
	# declared endpoint reaches a later local request.
	var local_crossings: Dictionary = {}
	var local_crossing_ids: Array[String] = []
	var local_unresolved: Array[String] = []
	for crossing_id: String in result.requiredCrossings:
		var crossing: Dictionary = result.requiredCrossings[crossing_id]
		var owner_tile := String(crossing.get("ownerTileKey",""))
		if owner_tile.is_empty() or not local_tiles.has(owner_tile): continue
		local_crossings[crossing_id] = crossing
		local_crossing_ids.append(crossing_id)
		if result.unresolvedCrossingIds.has(crossing_id): local_unresolved.append(crossing_id)
		# `tileKeys` records the full static topology spanned by this crossing.
		# Its endpoints can be many tiles apart; treating every one as immediate
		# demand turns a local player capsule into a whole-citadel loading gate.
		# The crossing is published by its declared owner tile, while later tiles
		# independently retain their own terrain and source-owned supports.
	local_crossing_ids.sort()
	local_unresolved.sort()
	result.requiredCrossings = local_crossings
	result.crossingIds = local_crossing_ids
	result.unresolvedCrossingIds = local_unresolved
	# Remote crossings were intentionally excluded above, so their broad source
	# geometry cannot inflate terrain retention either.
	result.dependencyBounds = [bounds]
	var groups: Dictionary = {}
	var members: Dictionary = {}
	var regions: Dictionary = {}
	var missing: Dictionary = {}
	for id: String in result.groupIds: groups[id] = true
	for id: String in result.groupMemberIds: members[id] = true
	for rectangle: Rect2i in result.dependencyBounds: regions[rectangle] = true
	for id: String in result.missingSourceIds: missing[id] = true
	var keys: Array = tiles.keys()
	keys.sort()
	for key: String in keys:
		var physical: Dictionary = physical_group_requirements(Rect2i(tiles[key]*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS))
		if physical.get("status")!="described": return physical
		for id: String in physical.groupIds: groups[id] = true
		for id: String in physical.groupMemberIds: members[id] = true
		for rectangle: Rect2i in physical.dependencyBounds: regions[rectangle] = true
		for id: String in physical.missingSourceIds: missing[id] = true
	result.groupIds = groups.keys()
	result.groupIds.sort()
	result.groupMemberIds = members.keys()
	result.groupMemberIds.sort()
	result.dependencyBounds = regions.keys()
	result.missingSourceIds = missing.keys()
	result.missingSourceIds.sort()
	result["navigationTileKeys"] = keys
	var navigation_regions: Array = []
	for key: String in keys:
		navigation_regions.append(Rect2i(tiles[key]*NAV_TILE_CELLS,Vector2i.ONE*NAV_TILE_CELLS))
	result["domainBounds"] = {"terrain":result.dependencyBounds.duplicate(),"render":result.dependencyBounds.duplicate(),"navigation":navigation_regions}
	return result

func summary() -> Dictionary:
	return {"partCount":parts.size(),"consumerCellCount":cells.size(),"supportCount":navigation.get("supportCount",0),
		"doorCount":navigation.get("doorCount",0),"verticalLinkCount":navigation.get("verticalLinkCount",0),
		"supportSeamLinkCount":navigation.get("supportSeamLinkCount",0),"preparationUsec":preparation_usec,
		"navigationTiles":navigation_tiles.get("tiles",{}).size(),"navigationSamples":navigation_tiles.get("sampleCount",0),
		"navigationSurfaces":navigation_tiles.get("surfaceCount",0),"navigationPreparationUsec":navigation_tiles.get("preparationUsec",0),
		"regionalTileRequirementCount":regional_tile_requirements.size(),"regionalTileIndexReady":regional_tile_index_ready,
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
