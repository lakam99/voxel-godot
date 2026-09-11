extends RefCounted
class_name BuildingSpatialDependencies

## Worker-compiled source dependencies. These are obligations, never an
## acknowledgement that geometry, collision or navigation has been published.
const Navigation = preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const FurnitureNavigation = preload("res://scripts/buildings/FurnishingNavigationManifestBuilder.gd")
const NavigationTiles = preload("res://scripts/buildings/BuildingNavigationTilePreparation.gd")
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
var preparation_usec := 0

static func compile(blueprint, plan, source_binding: Dictionary, world_origin: Vector3, continuation: Callable):
	var started := Time.get_ticks_usec()
	if not world_origin.is_finite(): return null
	var packet = load("res://scripts/buildings/BuildingSpatialDependencies.gd").new()
	packet.binding = source_binding.duplicate()
	packet.origin = world_origin
	var solids: Array[Dictionary] = []
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
			solids.append(Navigation._static_collision_fact(blueprint.id,part,transform,bounds))
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
	packet.navigation_tiles = NavigationTiles.compile(packet.navigation,packet.furnishing_navigation,continuation,solids)
	if not packet.navigation_tiles.get("ready",false): return null
	for key in packet.parts:
		packet.parts[key].dependencies.sort()
	for key in packet.cells:
		packet.cells[key].sort()
	for value in [packet.binding, packet.parts, packet.cells, packet.navigation, packet.furnishing_navigation,packet.navigation_tiles]:
		if not _freeze(value, continuation): return null
	packet.preparation_usec = Time.get_ticks_usec() - started
	return packet if _continue(continuation, "publication_spatial_ready") else null

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

func requirements(bounds: Rect2i) -> Dictionary:
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return {"status":"failed", "reason":"invalid_dependency_bounds"}
	var required := {}
	var queue: Array[String] = []
	var roots: Array[AABB] = []
	var missing: Array[String] = []
	var owners := {}
	var required_crossings: Array[String] = []
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
	var support_parts := {}
	for support in navigation.supports:
		support_parts[String(support.id)] = "building:" + String(support.sourcePartId)
	for family: String in ["doors", "verticalLinks", "supportSeamLinks", "interiorPassageLinks"]:
		for crossing in navigation.get(family,[]):
			if not _intersects(crossing.get("bounds",AABB()),query): continue
			required_crossings.append(String(crossing.id))
			if family == "doors" and not bool(crossing.get("sourcePortalReady",false)) \
					or family == "verticalLinks" and not bool(crossing.get("endpointCertification",{}).get("resolved",false)):
				unresolved_crossings.append(String(crossing.id))
			var crossing_parts: Array = []
			for field: String in ["sourcePartId", "sourceCollisionPartId"]:
				if not String(crossing.get(field,"")).is_empty(): crossing_parts.append("building:"+String(crossing[field]))
			for field: String in ["supportId", "startSupportId", "endSupportId", "interiorSupportId", "exteriorSupportId"]:
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
		owners[record.ownerCell] = true
		if record.terrainRoot: roots.append(record.bounds)
		for dependency: String in record.dependencies:
			if not required.has(dependency):
				required[dependency] = true
				queue.append(dependency)
	queue.sort()
	required_crossings.sort()
	missing.sort()
	return {"status":"described", "binding":binding, "origin":origin, "partIds":queue,
		"ownerCells":owners.keys(), "terrainRootBounds":roots, "crossingIds":required_crossings,
		"missingSourceIds":missing, "unresolvedCrossingIds":unresolved_crossings,
		"publicationAcknowledged":false}

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
