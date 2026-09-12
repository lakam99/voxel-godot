extends SceneTree

## Synthetic source/dependency contract. Uses real grouping and requirement
## owners; hand-authored crossing facts isolate closure, not route correctness.
## No generation, live geometry, publication receipts or gameplay acceptance.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Groups = preload("res://scripts/buildings/BuildingPublicationGroups.gd")
const Spatial = preload("res://scripts/buildings/BuildingSpatialDependencies.gd")
const BINDING := {"siteId":"synthetic-group-site","sourceKey":"synthetic-group-source","generation":7}

var checks: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func check(label: String, passed: bool) -> void:
	checks[label] = passed
	if not passed: print("PUBLICATION GROUP FAILURE ",label)

func _part(blueprint, id: String, x: float, dependencies: Array = [], recipe: Dictionary = {}, kind: String = "wall", collision: bool = true):
	var details: Dictionary = recipe.duplicate(true)
	if not dependencies.is_empty(): details["physicalSupportPartIds"] = dependencies.duplicate()
	return blueprint.add_part({"id":id,"kind":kind,"position":Vector3(x,1,0),"size":Vector3(2,2,2),
		"collision":collision,"recipe":details})

func _packet(blueprint, plan, origin: Vector3 = Vector3.ZERO):
	# Direct source setup deliberately bypasses navigation discovery. Tests below
	# separately use compile_description to verify the real immutable handoff.
	var packet = Spatial.new()
	packet.binding = BINDING.duplicate()
	packet.origin = origin
	packet.navigation = {"supports":[],"doors":[],"verticalLinks":[],"supportSeamLinks":[],"interiorPassageLinks":[]}
	for part in blueprint.parts:
		var dependencies: Array[String] = []
		for field: String in Spatial.SUPPORT_FIELDS:
			for id in part.recipe.get(field,[]):
				var key: String = "building:"+String(id)
				if not dependencies.has(key): dependencies.append(key)
		var pose: Transform3D = Transform3D(Basis.from_euler(part.rotation),origin+part.position)
		check("setup_part_"+blueprint.id+"_"+part.id,packet._add_part("building:"+part.id,part.id,"building",
			pose*AABB(-part.size*0.5,part.size),pose.origin,dependencies,bool(part.recipe.get("physicalRoot",false))))
	for part in plan.parts:
		var pose: Transform3D = Transform3D(Basis.from_euler(part.rotation),origin+part.position)
		var size: Vector3 = part.occupied_size
		check("setup_furniture_"+blueprint.id+"_"+part.id,packet._add_part("furnishing:"+part.id,part.id,"furnishing",
			pose*AABB(Vector3(-size.x*0.5,0,-size.z*0.5),size),pose.origin,[],false))
	packet.publication_groups = Groups.compile(blueprint,plan,packet.parts,origin,Callable())
	return packet

func _query(x: float, z: float = 0.0) -> Rect2i:
	return Rect2i(Vector2i(roundi(x/Spatial.CELL),roundi(z/Spatial.CELL)),Vector2i.ONE)

func _directed_and_cycles() -> void:
	var blueprint = Blueprint.new("directed",1,"stone")
	_part(blueprint,"roof",0,["wall"])
	_part(blueprint,"wall",40,["foundation"])
	_part(blueprint,"foundation",80,[],{"physicalRoot":true})
	var plan = Plan.new("furniture",1,blueprint.id)
	plan.add_part({"id":"wall","archetype":"table","position":Vector3(120,0,0),"collision":false})
	var before: PackedByteArray = var_to_bytes([blueprint.snapshot(),plan.snapshot()])
	var packet = _packet(blueprint,plan)
	var description: Dictionary = packet.publication_groups
	check("directed_groups_ready",description.get("ready",false))
	if not description.get("ready",false): return
	check("directed_supports_not_atomic",description.order==["building:foundation","building:roof","building:wall","furnishing:wall"])
	check("directed_edge_orientation",description.groups["building:roof"].dependencies==["building:wall"]
		and description.groups["building:wall"].dependencies==["building:foundation"] and description.groups["building:foundation"].dependencies.is_empty())
	var roof: Dictionary = packet.group_requirements(_query(0))
	var foundation: Dictionary = packet.group_requirements(_query(80))
	check("roof_requires_entire_directed_support_chain",roof.get("groupIds")==["building:foundation","building:roof","building:wall"])
	check("foundation_does_not_require_supported_roofs",foundation.get("groupIds")==["building:foundation"])
	var exact_regions: Array = [_query(0)]
	for id: String in ["roof","wall","foundation"]:
		exact_regions.append(Spatial.terrain_cells_for_bounds(packet.parts["building:"+id].bounds))
	var separate_regions: bool = roof.dependencyBounds.size()==exact_regions.size()
	for rectangle: Rect2i in roof.dependencyBounds:
		separate_regions = separate_regions and exact_regions.has(rectangle) and rectangle.size.x<=3
	check("directed_support_demand_keeps_exact_disjoint_regions",separate_regions)
	check("existing_ungrouped_query_keeps_legacy_enclosing_bounds",packet.requirements(_query(0)).dependencyBounds.size()==1
		and packet.requirements(_query(0)).dependencyBounds[0].size.x>50)
	check("furniture_namespace_and_collision_intent",description.groups["furnishing:wall"].furnitureIndices==[0]
		and description.groups["furnishing:wall"].buildingIndices.is_empty() and not description.groups["furnishing:wall"].hasCollision)
	check("group_obligations_never_acknowledge_publication",roof.status=="described" and roof.groupDescriptionComplete and not roof.publicationAcknowledged)
	check("directed_input_unchanged",before==var_to_bytes([blueprint.snapshot(),plan.snapshot()]))
	var cycle = Blueprint.new("cycle",2,"stone")
	_part(cycle,"a",0,["b"])
	_part(cycle,"b",40,["a","foundation"])
	_part(cycle,"c",80,["a"])
	_part(cycle,"foundation",120)
	var cycle_packet = _packet(cycle,Plan.new())
	var graph: Dictionary = cycle_packet.publication_groups
	check("cycle_ready",graph.get("ready",false))
	if not graph.get("ready",false): return
	check("scc_only_true_cycle_atomic",graph.groups["building:a"].members==["building:a","building:b"] and graph.order==["building:a","building:c","building:foundation"])
	check("scc_retains_directed_external_dependency",graph.groups["building:a"].dependencies==["building:foundation"] and graph.groups["building:c"].dependencies==["building:a"])
	check("group_compilation_order_and_values_repeat_exactly",var_to_bytes(graph)==var_to_bytes(Groups.compile(cycle,Plan.new(),cycle_packet.parts,Vector3.ZERO,Callable())))
	check("cycle_demand_terminates_without_reverse_expansion",cycle_packet.group_requirements(_query(0)).get("groupIds")==["building:a","building:foundation"])
	check("invalid_bounds_fail",packet.group_requirements(Rect2i()).get("status")=="failed")
	metrics.directedGroups = description.order
	metrics.cycleGroups = graph.order

func _atomic_peers() -> void:
	var blueprint = Blueprint.new("atomic",3,"stone")
	_part(blueprint,"paver",0,[],{"pavingFootingJoints":{"footPartIds":["foot"]}})
	_part(blueprint,"foot",40)
	_part(blueprint,"frame",80,[],{"masonryApertureSource":"opening"})
	_part(blueprint,"door",120,[],{},"door")
	_part(blueprint,"decoration",160,[],{},"wall",false)
	blueprint.recipe = {"facadeApertures":{"opening":{"producerPrefix":"opening","partIds":["frame","door","decoration"]}}}
	var packet = _packet(blueprint,Plan.new())
	var description: Dictionary = packet.publication_groups
	check("atomic_groups_ready",description.get("ready",false))
	if not description.get("ready",false): return
	var paving: Dictionary = description.groups[description.groupByPart["building:paver"]]
	var aperture: Dictionary = description.groups[description.groupByPart["building:frame"]]
	check("paving_declared_peers_atomic",paving.members==["building:foot","building:paver"] and paving.buildingIndices==[0,1])
	check("aperture_declared_peers_atomic",aperture.members==["building:decoration","building:door","building:frame"] and aperture.buildingIndices==[2,3,4])
	check("atomic_door_and_disjoint_collision_members",aperture.doorPartIds==["door"] and aperture.collisionMemberBounds.size()==2
		and aperture.collisionMemberBounds==[packet.parts["building:frame"].bounds,packet.parts["building:door"].bounds])
	check("atomic_visual_bounds_include_noncolliding_member",aperture.bounds.encloses(packet.parts["building:decoration"].bounds)
		and not aperture.collisionBounds.encloses(packet.parts["building:decoration"].bounds))
	check("atomic_query_includes_far_members",packet.group_requirements(_query(0)).get("groupMemberIds")==["building:foot","building:paver"])

func _crossing(id: String, x: float, tile: String) -> Dictionary:
	return {"id":id,"bounds":AABB(Vector3(x-1,0,-1),Vector3(2,2,2)),"ownerTileKey":tile,"tileKeys":[tile],
		"sourcePortalReady":true,"endpointCertification":{"resolved":true}}

func _bounded_crossing_ownership() -> void:
	var blueprint = Blueprint.new("crossing",4,"stone")
	_part(blueprint,"near",0,["foundation"],{"masonryApertureSource":"route_group"})
	_part(blueprint,"stair",80)
	_part(blueprint,"door",120,[],{},"door")
	_part(blueprint,"foundation",160)
	_part(blueprint,"endpoint",200)
	_part(blueprint,"remote",240)
	blueprint.recipe = {"facadeApertures":{"route_group":{"producerPrefix":"route_group","partIds":["near","stair","door"]}}}
	var packet = _packet(blueprint,Plan.new())
	check("crossing_groups_ready",packet.publication_groups.get("ready",false))
	if not packet.publication_groups.get("ready",false): return
	var stair: Dictionary = _crossing("owned_stair",80,"3,0")
	stair["sourceCollisionPartId"] = "stair"
	stair["endSupportId"] = "endpoint_support"
	var door: Dictionary = _crossing("owned_door",120,"5,0")
	door["sourcePartId"] = "door"
	door["exteriorSupportId"] = "endpoint_support"
	var seam: Dictionary = _crossing("unrelated_seam",240,"11,0")
	seam["firstSupportPartId"] = "stair" # Atomic peer endpoint is not an owner.
	seam["secondSupportPartId"] = "remote"
	var foundation_route: Dictionary = _crossing("unrelated_foundation_route",240,"11,0")
	foundation_route["sourcePartId"] = "foundation" # Directed dependency is not a query seed.
	foundation_route["endSupportPartId"] = "remote"
	var endpoint_route: Dictionary = _crossing("unrelated_endpoint_route",240,"11,0")
	endpoint_route["sourcePartId"] = "endpoint" # Newly included endpoint does not recursively expand.
	endpoint_route["endSupportPartId"] = "remote"
	packet.navigation.supports = [{"id":"endpoint_support","sourcePartId":"endpoint"}]
	packet.navigation.doors = [door]
	packet.navigation.verticalLinks = [stair,foundation_route,endpoint_route]
	packet.navigation.supportSeamLinks = [seam]
	var before: PackedByteArray = var_to_bytes([packet.parts,packet.navigation,packet.publication_groups])
	var demand: Dictionary = packet.group_requirements(_query(0))
	check("far_atomic_owned_door_and_stair_required",demand.get("crossingIds")==["owned_door","owned_stair"])
	check("owned_crossing_endpoint_and_support_closure",demand.get("groupMemberIds")==["building:door","building:endpoint","building:foundation","building:near","building:stair"])
	check("unrelated_seam_foundation_endpoint_routes_excluded",not demand.requiredCrossings.has("unrelated_seam")
		and not demand.requiredCrossings.has("unrelated_foundation_route") and not demand.requiredCrossings.has("unrelated_endpoint_route") and not demand.groupMemberIds.has("building:remote"))
	check("crossing_endpoint_mapping_complete",demand.missingSourceIds.is_empty() and demand.unresolvedCrossingIds.is_empty()
		and demand.requiredCrossings.owned_door.mappingStatus=="pending" and demand.requiredCrossings.owned_stair.requiredLinkIds==["owned_stair"])
	check("spatial_seed_excludes_dependency_closure",demand.spatialPartIds==["building:near"])
	check("crossing_query_pure_and_repeatable",before==var_to_bytes([packet.parts,packet.navigation,packet.publication_groups])
		and var_to_bytes(demand)==var_to_bytes(packet.group_requirements(_query(0))))
	metrics.crossingIds = demand.crossingIds
	metrics.crossingMemberIds = demand.groupMemberIds

func _tree(id: String, position: Vector3 = Vector3.ZERO) -> Dictionary:
	return {"id":id,"position":position,"rotationY":0.25,"canopyRadius":2.0,
		"rootButtressFootprints":[{"start":position+Vector3(9,0,0),"end":position+Vector3(10,0,0),"radiusStart":0.5,"radiusEnd":0.25}],
		"treeRequest":{"architecture":"broadleaf","speciesGrammar":"synthetic_contract","visualHeight":6.0,
			"collisionHeight":3.0,"trunkRadius":0.3,"canopyRadius":4.0}}

func _trees_and_immutability() -> void:
	var blueprint = Blueprint.new("trees",5,"stone")
	blueprint.recipe = {"landscapeTrees":[_tree("chosen")],"urbanPoc":{"treePlacements":[_tree("ignored",Vector3(100,0,0))]}}
	var before: PackedByteArray = var_to_bytes(blueprint.snapshot())
	var packet = _packet(blueprint,Plan.new(),Vector3(20,2,-10))
	var description: Dictionary = packet.publication_groups
	check("tree_groups_ready",description.get("ready",false))
	if not description.get("ready",false): return
	var tree: Dictionary = description.treeMembers["tree:chosen"]
	check("landscape_tree_source_precedence",description.order==["tree:chosen"] and description.treeRecords.size()==1)
	check("tree_collider_exact_origin_and_dimensions",tree.position==Vector3(20,2,-10)
		and tree.collisionBounds==AABB(Vector3(19.7,2,-10.3),Vector3(0.6,3,0.6)))
	check("tree_request_canopy_and_declared_buttress_retained",tree.bounds.has_point(Vector3(16.1,3,-10)) and tree.bounds.has_point(Vector3(30.4,2,-10)))
	check("tree_query_at_offset_buttress_requires_whole_tree",packet.group_requirements(_query(30,-10)).get("groupIds")==["tree:chosen"])
	check("tree_query_does_not_pull_remote_tree",packet.group_requirements(_query(120,-10)).get("groupIds")==[])
	description.treeRecords[0].treeRequest.visualHeight = 99.0
	check("tree_records_owned_copy_and_input_unchanged",before==var_to_bytes(blueprint.snapshot()) and blueprint.recipe.landscapeTrees[0].treeRequest.visualHeight==6.0)
	blueprint.recipe.landscapeTrees = []
	check("explicit_empty_landscape_overrides_urban",_packet(blueprint,Plan.new()).publication_groups.get("order")==[])
	blueprint.recipe.erase("landscapeTrees")
	check("urban_tree_fallback_selected",_packet(blueprint,Plan.new()).publication_groups.get("order")==["tree:ignored"])
	var immutable = Blueprint.new("immutable",6,"stone")
	_part(immutable,"part",0,[],{},"wall",false)
	immutable.recipe = {"landscapeTrees":[_tree("frozen")]}
	var immutable_plan = Plan.new()
	var source_before: PackedByteArray = var_to_bytes([immutable.snapshot(),immutable_plan.snapshot()])
	var compact = Spatial.compile_description(immutable,immutable_plan,BINDING,Vector3.ZERO,Callable())
	check("real_compact_group_description_compiles",compact!=null)
	if compact!=null:
		check("all_compact_source_containers_deeply_read_only",_deep_read_only([compact.binding,compact.parts,compact.cells,
			compact.navigation,compact.publication_groups],false))
		check("compact_does_not_generate_dense_samples",compact.navigation_tiles.is_empty() and compact.navigation_tiles.is_read_only())
		check("compact_preserves_caller_values_and_mutability",source_before==var_to_bytes([immutable.snapshot(),immutable_plan.snapshot()])
			and not immutable.recipe.is_read_only() and not immutable.recipe.landscapeTrees.is_read_only() and not immutable.recipe.landscapeTrees[0].treeRequest.is_read_only())

func _deep_read_only(value: Variant, inspect_container: bool = true) -> bool:
	if value is Dictionary:
		if inspect_container and not value.is_read_only(): return false
		for child in value.values():
			if not _deep_read_only(child): return false
	elif value is Array:
		if inspect_container and not value.is_read_only(): return false
		for child in value:
			if not _deep_read_only(child): return false
	return true

func _malformed_and_cancelled() -> void:
	var cases: Array = [
		{"label":"paving_shape","part":{"pavingFootingJoints":[]},"reason":"unknown_paving_group"},
		{"label":"paving_peer_type","part":{"pavingFootingJoints":{"footPartIds":[5]}},"reason":"missing_paving_group_peer"},
		{"label":"paving_peer_missing","part":{"pavingFootingJoints":{"footPartIds":["absent"]}},"reason":"missing_paving_group_peer"},
		{"label":"aperture_missing","part":{"masonryApertureSource":"opening"},"reason":"unknown_aperture_group"},
		{"label":"aperture_prefix","part":{"masonryApertureSource":"opening"},"recipe":{"facadeApertures":{"opening":{"producerPrefix":"other","partIds":["part"]}}},"reason":"unbound_aperture_group"},
		{"label":"aperture_membership","part":{"masonryApertureSource":"opening"},"recipe":{"facadeApertures":{"opening":{"producerPrefix":"opening","partIds":[]}}},"reason":"unbound_aperture_group"},
		{"label":"aperture_peer_missing","part":{"masonryApertureSource":"opening"},"recipe":{"facadeApertures":{"opening":{"producerPrefix":"opening","partIds":["part","absent"]}}},"reason":"missing_aperture_group_peer"},
		{"label":"support_missing","dependencies":["absent"],"reason":"missing_group_dependency"},
		{"label":"tree_collection","recipe":{"landscapeTrees":{}},"reason":"unknown_tree_collection"}]
	for value: Dictionary in cases:
		var blueprint = Blueprint.new(value.label,7,"stone")
		_part(blueprint,"part",0,value.get("dependencies",[]),value.get("part",{}))
		blueprint.recipe = value.get("recipe",{}).duplicate(true)
		var packet = _packet(blueprint,Plan.new())
		check("malformed_"+value.label,packet.publication_groups=={"ready":false,"reason":value.reason})
		check("malformed_pending_not_ready_"+value.label,packet.group_requirements(_query(0))=={"status":"pending","reason":value.reason})
	var invalid_trees: Array = []
	var no_rotation: Dictionary = _tree("no_rotation"); no_rotation.erase("rotationY")
	invalid_trees.append({"label":"rotation","records":[no_rotation],"reason":"unknown_tree_rotation"})
	var no_request: Dictionary = _tree("no_request"); no_request.treeRequest.erase("speciesGrammar")
	invalid_trees.append({"label":"request","records":[no_request],"reason":"unknown_tree_request"})
	var bad_dimensions: Dictionary = _tree("dimensions"); bad_dimensions.treeRequest.collisionHeight = 10.0
	invalid_trees.append({"label":"dimensions","records":[bad_dimensions],"reason":"unknown_tree_dimensions"})
	invalid_trees.append({"label":"duplicate","records":[_tree("duplicate"),_tree("duplicate")],"reason":"unknown_tree_envelope"})
	for value: Dictionary in invalid_trees:
		var blueprint = Blueprint.new("invalid_tree_"+value.label)
		blueprint.recipe = {"landscapeTrees":value.records}
		check("malformed_tree_"+value.label,_packet(blueprint,Plan.new()).publication_groups=={"ready":false,"reason":value.reason})
	var blueprint = Blueprint.new("cancel",8,"stone")
	_part(blueprint,"a",0,["b"]); _part(blueprint,"b",40,["a"]); _part(blueprint,"c",80,["b"])
	var plan = Plan.new()
	var packet = _packet(blueprint,plan)
	var original: PackedByteArray = var_to_bytes([blueprint.snapshot(),plan.snapshot(),packet.parts])
	for reject_at: int in [1,8]:
		var count: Array[int] = [0]
		var result: Dictionary = Groups.compile(blueprint,plan,packet.parts,Vector3.ZERO,func(_stage: String) -> bool:
			count[0] += 1
			return count[0]<reject_at)
		check("cancel_group_"+str(reject_at)+"_discards_partial_graph",result=={"ready":false,"reason":"cancelled"} and count[0]==reject_at)
	check("cancel_group_input_unchanged",original==var_to_bytes([blueprint.snapshot(),plan.snapshot(),packet.parts]))
	for stage: String in ["publication_group_index","publication_spatial_freeze"]:
		var stopped: Array[bool] = [false]
		var late: Array[int] = [0]
		var cancelled = Spatial.compile_description(blueprint,plan,BINDING,Vector3.ZERO,func(current: String) -> bool:
			if stopped[0]: late[0] += 1
			if current==stage: stopped[0] = true
			return not stopped[0])
		check("cancel_compact_"+stage,cancelled==null and stopped[0] and late[0]==0)
	check("cancel_compact_input_unchanged",original==var_to_bytes([blueprint.snapshot(),plan.snapshot(),packet.parts]))
	var missing_parts: Dictionary = packet.parts.duplicate(true); missing_parts.erase("building:a")
	check("missing_member_rejected",Groups.compile(blueprint,plan,missing_parts,Vector3.ZERO,Callable())=={"ready":false,"reason":"missing_group_part"})
	blueprint.parts.append(blueprint.parts[0])
	check("duplicate_member_rejected",Groups.compile(blueprint,plan,packet.parts,Vector3.ZERO,Callable())=={"ready":false,"reason":"duplicate_group_part"})

func _run() -> void:
	_directed_and_cycles()
	_atomic_peers()
	_bounded_crossing_ownership()
	_trees_and_immutability()
	_malformed_and_cancelled()
	var report: Dictionary = {"schema":"building-publication-groups-contract/v1","complete":true,"passed":not checks.values().has(false),
		"checks":checks,"metrics":metrics,"evidenceLevel":"synthetic_source_group_and_spatial_requirement_contract",
		"doesNotProve":"No actual citadel source, runtime group publication, collision/navigation receipts, live routes, worker throughput or gameplay acceptance."}
	var output: String = OS.get_environment("BUILDING_PUBLICATION_GROUPS_REPORT")
	var file: FileAccess = FileAccess.open(output,FileAccess.WRITE)
	if file==null:
		push_error("Cannot write publication groups contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("PUBLICATION GROUP CONTRACT COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
