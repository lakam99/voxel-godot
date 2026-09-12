extends RefCounted

## Pure source grouping. A group is an obligation, never a publication receipt.
## Atomic recipe peers and support cycles share one owner; acyclic supports stay
## directed so requiring a foundation does not require every roof it supports.
const SiteManifest = preload("res://scripts/buildings/BuildingSiteManifestBuilder.gd")
const TreeRequests = preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")

static func compile(blueprint, plan, parts: Dictionary, origin: Vector3, continuation: Callable) -> Dictionary:
	var members: Dictionary = {}
	var parent: Dictionary = {}
	var ordinal: int = 0
	for collection: Array in [blueprint.parts,plan.parts]:
		var building: bool = ordinal == 0
		for index: int in range(collection.size()):
			if not _continue(continuation): return _failure("cancelled")
			var part = collection[index]
			var key: String = ("building:" if building else "furnishing:")+String(part.id)
			if members.has(key): return _failure("duplicate_group_part")
			if not parts.has(key): return _failure("missing_group_part")
			members[key] = {"index":index,"kind":"building" if building else "furnishing",
				"bounds":parts[key].bounds,"dependencies":parts[key].dependencies,
				"door":building and part.kind == "door","hasCollision":bool(part.collision_enabled),
				"collisionBounds":parts[key].bounds if part.collision_enabled else AABB()}
			parent[key] = key
		ordinal += 1
	# These recipes bind peers at emission, not merely through physical support.
	for part in blueprint.parts:
		if not _continue(continuation): return _failure("cancelled")
		var key: String = "building:"+String(part.id)
		if part.recipe.has("pavingFootingJoints"):
			var joint: Variant = part.recipe.pavingFootingJoints
			if not joint is Dictionary or not joint.get("footPartIds") is Array:
				return _failure("unknown_paving_group")
			for id in joint.footPartIds:
				if not id is String or not _union(parent,key,"building:"+id):
					return _failure("missing_paving_group_peer")
		if part.recipe.has("masonryApertureSource"):
			var apertures: Variant = blueprint.recipe.get("facadeApertures",{})
			if not apertures is Dictionary: return _failure("unknown_aperture_group")
			var aperture: Variant = apertures.get(part.recipe.masonryApertureSource)
			if not aperture is Dictionary or not aperture.get("partIds") is Array:
				return _failure("unknown_aperture_group")
			if not aperture.partIds.has(part.id) or aperture.get("producerPrefix") != part.recipe.masonryApertureSource:
				return _failure("unbound_aperture_group")
			for id in aperture.partIds:
				if not id is String or not _union(parent,key,"building:"+id):
					return _failure("missing_aperture_group_peer")
	var tree_result: Dictionary = _trees(blueprint.recipe,origin)
	if not tree_result.ready: return tree_result
	for key: String in tree_result.members:
		if members.has(key): return _failure("duplicate_tree_group")
		members[key] = tree_result.members[key]
		parent[key] = key
	var graph: Dictionary = {}
	for key: String in members:
		var owner: String = _root(parent,key)
		if not graph.has(owner): graph[owner] = {}
		for dependency: String in members[key].dependencies:
			if not parent.has(dependency): return _failure("missing_group_dependency")
			var required: String = _root(parent,dependency)
			if required != owner: graph[owner][required] = true
	# Collapse only genuine directed cycles. Iterative traversal avoids a script
	# recursion limit for long procedural support chains.
	var components: Array = _components(graph,continuation)
	if not graph.is_empty() and components.is_empty(): return _failure("cancelled")
	for component: Array in components:
		for key: String in component: _union(parent,String(component[0]),key)
	var groups: Dictionary = {}
	var by_part: Dictionary = {}
	for key: String in members:
		if not _continue(continuation): return _failure("cancelled")
		var owner: String = _root(parent,key)
		var member: Dictionary = members[key]
		if not groups.has(owner):
			groups[owner] = {"id":owner,"members":[],"dependencies":[],"bounds":member.bounds,
				"buildingIndices":[],"furnitureIndices":[],"treeIndices":[],"doorPartIds":[],
				"hasCollision":false,"collisionBounds":AABB(),"collisionMemberBounds":[]}
		var group: Dictionary = groups[owner]
		group.members.append(key)
		group.bounds = group.bounds.merge(member.bounds)
		if member.hasCollision:
			group.collisionBounds = group.collisionBounds.merge(member.collisionBounds) if group.hasCollision else member.collisionBounds
			group.hasCollision = true
			group.collisionMemberBounds.append(member.collisionBounds)
		var field: String = {"building":"buildingIndices","furnishing":"furnitureIndices","tree":"treeIndices"}[member.kind]
		group[field].append(member.index)
		if member.door: group.doorPartIds.append(key.trim_prefix("building:"))
		by_part[key] = owner
	for key: String in members:
		var group: Dictionary = groups[by_part[key]]
		for dependency: String in members[key].dependencies:
			var required: String = by_part[dependency]
			if required != group.id and not group.dependencies.has(required): group.dependencies.append(required)
	var order: Array = groups.keys()
	order.sort()
	for key: String in order:
		for field: String in ["members","dependencies","buildingIndices","furnitureIndices","treeIndices","doorPartIds"]:
			groups[key][field].sort()
	return {"ready":true,"groups":groups,"groupByPart":by_part,"order":order,
		"treeRecords":tree_result.records,"treeMembers":tree_result.members}

static func _trees(recipe: Dictionary, origin: Vector3) -> Dictionary:
	var selected: Variant = recipe.get("landscapeTrees")
	if selected == null:
		var urban: Variant = recipe.get("urbanPoc",{})
		if not urban is Dictionary: return _failure("unknown_tree_collection")
		selected = urban.get("treePlacements",[])
	if not selected is Array: return _failure("unknown_tree_collection")
	# Reuse declared canopy/buttress geometry without changing terrain generation
	# or inventing a second tree recipe. Selection matches the runtime owner.
	var declared: Dictionary = SiteManifest._trees({"urbanPoc":{"treePlacements":selected}})
	if not declared.get("ready",false) or not declared.unknownHeightTreeIds.is_empty():
		return _failure("unknown_tree_envelope")
	var members: Dictionary = {}
	for index: int in range(selected.size()):
		var record: Dictionary = selected[index]
		if not (record.get("rotationY") is float or record.get("rotationY") is int) or not is_finite(float(record.rotationY)):
			return _failure("unknown_tree_rotation")
		var request: Variant = record.get("treeRequest")
		if not request is Dictionary or not TreeRequests.is_procedural_request(request):
			return _failure("unknown_tree_request")
		for field: String in ["visualHeight","collisionHeight","trunkRadius","canopyRadius"]:
			if not (request.get(field) is float or request.get(field) is int) or not is_finite(float(request[field])):
				return _failure("unknown_tree_dimensions")
		var height: float = float(request.visualHeight)
		var collision_height: float = float(request.collisionHeight)
		var radius: float = float(request.trunkRadius)
		if height < 1.0 or radius < 0.12 or float(request.canopyRadius) < radius or collision_height < 1.0 or collision_height > height:
			return _failure("unknown_tree_dimensions")
		var position: Vector3 = origin+record.position
		var collider: AABB = AABB(position-Vector3(radius,0,radius),Vector3(radius*2,collision_height,radius*2))
		var visual: AABB = declared.trees[index].bounds
		visual.position += origin
		var canopy_radius: float = float(request.canopyRadius)
		visual = visual.merge(AABB(position-Vector3(canopy_radius,0,canopy_radius),Vector3(canopy_radius*2,height,canopy_radius*2)))
		members["tree:"+String(record.id)] = {"kind":"tree","index":index,"dependencies":[],"door":false,
			"bounds":visual.merge(collider),"collisionBounds":collider,"hasCollision":true,"position":position}
	return {"ready":true,"records":selected.duplicate(true),"members":members}

static func _root(parent: Dictionary, key: String) -> String:
	var result: String = key
	while parent[result] != result: result = parent[result]
	while parent[key] != key:
		var next: String = parent[key]
		parent[key] = result
		key = next
	return result

static func _union(parent: Dictionary, a: String, b: String) -> bool:
	if not parent.has(a) or not parent.has(b): return false
	var first: String = _root(parent,a)
	var second: String = _root(parent,b)
	if first < second: parent[second] = first
	elif second < first: parent[first] = second
	return true

static func _components(graph: Dictionary, continuation: Callable) -> Array:
	var visited: Dictionary = {}
	var finished: Array[String] = []
	var reverse: Dictionary = {}
	var keys: Array = graph.keys()
	keys.sort()
	for key: String in keys: reverse[key] = []
	for key: String in keys:
		for neighbor: String in graph[key]: reverse[neighbor].append(key)
	for key: String in keys:
		if visited.has(key): continue
		var stack: Array = [[key,false]]
		while not stack.is_empty():
			if not _continue(continuation): return []
			var frame: Array = stack.pop_back()
			var node: String = frame[0]
			if frame[1]: finished.append(node); continue
			if visited.has(node): continue
			visited[node] = true
			stack.append([node,true])
			var neighbors: Array = graph[node].keys()
			neighbors.sort()
			for neighbor: String in neighbors:
				if not visited.has(neighbor): stack.append([neighbor,false])
	visited = {}
	var result: Array = []
	while not finished.is_empty():
		var key: String = finished.pop_back()
		if visited.has(key): continue
		var component: Array[String] = []
		var stack: Array[String] = [key]
		while not stack.is_empty():
			if not _continue(continuation): return []
			var node: String = stack.pop_back()
			if visited.has(node): continue
			visited[node] = true
			component.append(node)
			for neighbor: String in reverse[node]:
				if not visited.has(neighbor): stack.append(neighbor)
		component.sort()
		result.append(component)
	return result

static func _continue(callback: Callable) -> bool:
	return not callback.is_valid() or callback.call("publication_group_index") == true

static func _failure(reason: String) -> Dictionary:
	return {"ready":false,"reason":reason}
