extends RefCounted
class_name CitadelPublicationPlan

## Immutable, worker-built scheduling plan for one complete generated Citadel
## source. It is not geometry, collision, navigation, or readiness authority.
## Those owners still validate every selected physical group at publication.
const ViewPriority = preload("res://scripts/world/GeneratedContentViewPriority.gd")
const CELL := 1.35
const BUCKET_WORLD_SIZE := 32.0
# Exact readiness closures are admitted before optional presentation. Sixteen
# additional ranked roots provide progressive visual breadth without spending
# the 2 ms gameplay query ceiling on details that a later rolling window owns.
const MAX_VIEW_CANDIDATES := 16
const MAX_BUCKET_QUERY_AXIS := 32
const FIRST_USEFUL_HOME_COUNT := 2
const FIRST_USEFUL_HOME_ARCHETYPES: Array[String] = ["bed","chair","hearth","table"]
const FIRST_USEFUL_STRUCTURAL_SEMANTICS: Array[String] = [
	"castle_gatehouse_wall_stair_exit",
	"castle_gatehouse_wall_stair_landing",
	"castle_keep_stair_exit",
	"castle_keep_stair_landing",
]
const COURTYARD_SEMANTICS: Array[String] = [
	"castle_courtyard_paving",
	"castle_courtyard_foundation",
]

var binding: Dictionary = {}
var groups: Dictionary = {}
var order: Array[String] = []
var dependency_closures: Dictionary = {}
var center_buckets: Dictionary = {}
var bounds_buckets: Dictionary = {}
var member_records: Array[Dictionary] = []
var member_buckets: Dictionary = {}
var door_group_ids: Array[String] = []
var structural_group_ids: Array[String] = []
var first_useful_homes: Dictionary = {}
var first_useful_home_ids: Array[String] = []
var first_useful_structural_group_ids: Array[String] = []
var courtyard_group_ids: Array[String] = []
var selected_first_useful_home_ids: Array[String] = []
var selected_first_useful_home_group_ids: Array[String] = []
var selected_first_useful_door_group_id := ""
var selected_first_useful_structural_group_ids: Array[String] = []
var selected_courtyard_group_ids: Array[String] = []
var eligible_group_ids: Dictionary = {}
var output_signature := ""
var preparation_usec := 0


static func build(description, building_source: Dictionary, furnishing_source: Dictionary,
		eligibility: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	var started := Time.get_ticks_usec()
	if description == null or not description.get("binding") is Dictionary \
			or not description.publication_groups.get("ready",false):
		return {"ready":false,"reason":"publication_plan_description_invalid"}
	var source_groups: Variant = description.publication_groups.get("groups")
	if not source_groups is Dictionary or source_groups.is_empty() or not source_groups.is_read_only():
		return {"ready":false,"reason":"publication_plan_groups_invalid"}
	if not eligibility.get("ready",false) or not eligibility.get("groups") is Dictionary:
		return {"ready":false,"reason":"publication_plan_eligibility_invalid"}
	var plan := new()
	plan.binding = description.binding
	plan.groups = source_groups
	var declared_order: Variant = description.publication_groups.get("order",[])
	if declared_order is Array:
		for raw_id in declared_order:
			if raw_id is String and source_groups.has(raw_id) and not plan.order.has(raw_id):
				plan.order.append(raw_id)
	if plan.order.size() != source_groups.size():
		plan.order.clear()
		for id: String in source_groups: plan.order.append(id)
		plan.order.sort()
	var signature := HashingContext.new()
	if signature.start(HashingContext.HASH_SHA256) != OK:
		return {"ready":false,"reason":"publication_plan_signature_start_failed"}
	# Generation is a runtime lifetime fence, not semantic source identity.
	signature.update(var_to_bytes(["citadel-publication-plan/v1",String(plan.binding.siteId),
		String(plan.binding.sourceKey),plan.order]))
	for index: int in plan.order.size():
		if index % 64 == 0 and continuation.is_valid() and continuation.call("publication_plan_group") != true:
			return {"ready":false,"reason":"cancelled"}
		var id := plan.order[index]
		var group: Dictionary = source_groups[id]
		var bounds: Variant = group.get("bounds")
		if not bounds is AABB or not bounds.position.is_finite() or not bounds.size.is_finite() \
				or bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
			return {"ready":false,"reason":"publication_plan_group_bounds_invalid","groupId":id}
		var closure: Dictionary = _dependency_window(source_groups,id)
		if closure.get("status") != "ready": return closure
		var frozen_closure: Array[String] = closure.groupIds
		frozen_closure.make_read_only()
		plan.dependency_closures[id] = frozen_closure
		var center: Vector3 = bounds.get_center()
		_add_bucket(plan.center_buckets,_bucket_for_point(center),id)
		var low := _bucket_for_point(bounds.position)
		var high := _bucket_for_point(bounds.end-Vector3(0.0001,0.0,0.0001))
		if high.x-low.x+1 > MAX_BUCKET_QUERY_AXIS or high.y-low.y+1 > MAX_BUCKET_QUERY_AXIS:
			return {"ready":false,"reason":"publication_plan_group_bucket_span_invalid","groupId":id}
		for z: int in range(low.y,high.y+1):
			for x: int in range(low.x,high.x+1): _add_bucket(plan.bounds_buckets,Vector2i(x,z),id)
		if not group.get("doorPartIds",[]).is_empty(): plan.door_group_ids.append(id)
		if not group.get("buildingIndices",[]).is_empty() and bool(group.get("hasCollision",false)):
			plan.structural_group_ids.append(id)
		if bool(eligibility.groups.get(id,{}).get("eligible",false)): plan.eligible_group_ids[id] = true
		var dependencies: Array = group.get("dependencies",[]).duplicate()
		dependencies.sort()
		signature.update(var_to_bytes([id,bounds,dependencies,group.get("members",[]),
			group.get("doorPartIds",[]),bool(group.get("hasCollision",false))]))
	var by_part: Dictionary = description.publication_groups.get("groupByPart",{})
	var building_visuals: Dictionary = {}
	for raw_part in building_source.get("parts",[]):
		if raw_part is Dictionary:
			var recipe: Variant = raw_part.get("recipe",{})
			building_visuals["building:"+String(raw_part.get("id",""))] = \
				bool(recipe.get("visual",true)) if recipe is Dictionary else true
	var part_member_ids: Array[String] = []
	for member_id: String in description.parts: part_member_ids.append(member_id)
	part_member_ids.sort()
	for member_id: String in part_member_ids:
		if not by_part.has(member_id): return {"ready":false,"reason":"publication_plan_member_group_missing","memberId":member_id}
		var member_bounds: Variant = description.parts[member_id].get("bounds")
		if not _member_bounds_valid(member_bounds): return {"ready":false,"reason":"publication_plan_member_bounds_invalid","memberId":member_id}
		_add_member_record(plan,member_id,String(by_part[member_id]),member_bounds,
			bool(building_visuals.get(member_id,true)))
	var tree_members: Dictionary = description.publication_groups.get("treeMembers",{})
	var tree_member_ids: Array[String] = []
	for member_id: String in tree_members: tree_member_ids.append(member_id)
	tree_member_ids.sort()
	for member_id: String in tree_member_ids:
		if not by_part.has(member_id): return {"ready":false,"reason":"publication_plan_member_group_missing","memberId":member_id}
		var tree_bounds: Variant = tree_members[member_id].get("bounds")
		if not _member_bounds_valid(tree_bounds): return {"ready":false,"reason":"publication_plan_member_bounds_invalid","memberId":member_id}
		_add_member_record(plan,member_id,String(by_part[member_id]),tree_bounds)
	_compile_first_useful(plan,description,building_source,furnishing_source)
	_freeze_bucket_index(plan.center_buckets)
	_freeze_bucket_index(plan.bounds_buckets)
	_freeze_member_bucket_index(plan.member_buckets)
	plan.door_group_ids.sort()
	plan.structural_group_ids.sort()
	plan.first_useful_structural_group_ids.sort()
	plan.courtyard_group_ids = _unique_sorted(plan.courtyard_group_ids)
	for home_id: String in plan.first_useful_homes:
		if FIRST_USEFUL_HOME_ARCHETYPES.all(func(archetype: String): return plan.first_useful_homes[home_id].has(archetype)):
			plan.first_useful_home_ids.append(home_id)
	plan.first_useful_home_ids.sort()
	for home_id: String in plan.first_useful_home_ids:
		var archetypes: Dictionary = plan.first_useful_homes[home_id]
		var eligible_home := true
		for archetype: String in FIRST_USEFUL_HOME_ARCHETYPES:
			if not _dependency_closure_eligible(plan,String(archetypes[archetype])): eligible_home=false
		if not eligible_home: continue
		plan.selected_first_useful_home_ids.append(home_id)
		for archetype: String in FIRST_USEFUL_HOME_ARCHETYPES:
			var group_id := String(archetypes[archetype])
			if not plan.selected_first_useful_home_group_ids.has(group_id):
				plan.selected_first_useful_home_group_ids.append(group_id)
		if plan.selected_first_useful_home_ids.size()>=FIRST_USEFUL_HOME_COUNT: break
	for group_id: String in plan.door_group_ids:
		if _dependency_closure_eligible(plan,group_id):
			plan.selected_first_useful_door_group_id=group_id
			break
	for group_id: String in plan.first_useful_structural_group_ids:
		if _dependency_closure_eligible(plan,group_id):
			plan.selected_first_useful_structural_group_ids.append(group_id)
			break
	for group_id: String in plan.courtyard_group_ids:
		if _dependency_closure_eligible(plan,group_id):
			plan.selected_courtyard_group_ids.append(group_id)
			break
	plan.selected_first_useful_home_group_ids.sort()
	var canonical_homes: Array = []
	for home_id: String in plan.first_useful_home_ids:
		var archetype_rows: Array = []
		for archetype: String in FIRST_USEFUL_HOME_ARCHETYPES:
			archetype_rows.append([archetype,String(plan.first_useful_homes[home_id][archetype])])
		canonical_homes.append([home_id,archetype_rows])
	var canonical_eligible: Array[String] = []
	for id: String in plan.eligible_group_ids: canonical_eligible.append(id)
	canonical_eligible.sort()
	# Sign every semantic input that changes a scheduling result. Timing and the
	# runtime generation fence remain intentionally absent.
	signature.update(var_to_bytes([plan.door_group_ids,plan.structural_group_ids,plan.courtyard_group_ids,
		canonical_homes,plan.first_useful_structural_group_ids,canonical_eligible,
		plan.selected_first_useful_home_ids,plan.selected_first_useful_home_group_ids,
		plan.selected_first_useful_door_group_id,plan.selected_first_useful_structural_group_ids,
		plan.selected_courtyard_group_ids]))
	var canonical_members: Array = []
	for record: Dictionary in plan.member_records:
		canonical_members.append([record.memberId,record.groupId,record.bounds,record.visual])
	signature.update(var_to_bytes(canonical_members))
	plan.order.make_read_only()
	plan.dependency_closures.make_read_only()
	plan.center_buckets.make_read_only()
	plan.bounds_buckets.make_read_only()
	plan.member_records.make_read_only()
	plan.member_buckets.make_read_only()
	plan.door_group_ids.make_read_only()
	plan.structural_group_ids.make_read_only()
	for home_id: String in plan.first_useful_homes:
		var archetypes: Dictionary = plan.first_useful_homes[home_id]
		archetypes.make_read_only()
	plan.first_useful_homes.make_read_only()
	plan.first_useful_home_ids.make_read_only()
	plan.first_useful_structural_group_ids.make_read_only()
	plan.courtyard_group_ids.make_read_only()
	plan.selected_first_useful_home_ids.make_read_only()
	plan.selected_first_useful_home_group_ids.make_read_only()
	plan.selected_first_useful_structural_group_ids.make_read_only()
	plan.selected_courtyard_group_ids.make_read_only()
	plan.eligible_group_ids.make_read_only()
	plan.output_signature = signature.finish().hex_encode()
	plan.preparation_usec = Time.get_ticks_usec()-started
	if not plan.matches(description.binding,source_groups):
		return {"ready":false,"reason":"publication_plan_invalid"}
	return {"ready":true,"reason":"","plan":plan,"preparationUsec":plan.preparation_usec,
		"outputSignature":plan.output_signature}


func matches(expected_binding: Dictionary, expected_groups: Dictionary) -> bool:
	return binding == expected_binding and binding.is_read_only() and is_same(groups,expected_groups) \
		and order.is_read_only() and dependency_closures.is_read_only() \
		and center_buckets.is_read_only() and bounds_buckets.is_read_only() \
		and member_records.is_read_only() and member_buckets.is_read_only() \
		and first_useful_home_ids.is_read_only() and eligible_group_ids.is_read_only() \
		and selected_first_useful_home_ids.is_read_only() and selected_first_useful_home_group_ids.is_read_only() \
		and selected_first_useful_structural_group_ids.is_read_only() and courtyard_group_ids.is_read_only() \
		and selected_courtyard_group_ids.is_read_only() \
		and output_signature.length() == 64


func dependency_window(group_id: String, completed: Dictionary = {}) -> Dictionary:
	if not dependency_closures.has(group_id):
		return {"status":"failed","reason":"publication_group_dependency_missing","groupId":group_id}
	var selected: Array[String] = []
	for id: String in dependency_closures[group_id]:
		if not completed.has(id): selected.append(id)
	return {"status":"ready","groupIds":selected}


func publication_closure_eligible(group_id: String, door_lifecycle_available: bool) -> bool:
	if not dependency_closures.has(group_id): return false
	for required_id: String in dependency_closures[group_id]:
		if not eligible_group_ids.has(required_id): return false
		if not door_lifecycle_available and door_group_ids.has(required_id): return false
	return true


## Exact immutable-member query followed by atomic-group dependency closure.
## A spatially disjoint member of the same atomic group is published with its
## intersecting sibling, but cannot make the group relevant by itself.
func physical_group_requirements(bounds: Rect2i) -> Dictionary:
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return {"status":"failed","reason":"invalid_dependency_bounds"}
	var world_query := _world_rect_for_cells(bounds)
	var candidates := _bucket_record_candidates(member_buckets,world_query,member_records.size())
	var direct_groups: Dictionary = {}
	for index: int in candidates:
		var record: Dictionary = member_records[index]
		if _rect_intersects_aabb(world_query,record.bounds): direct_groups[String(record.groupId)]=true
	var selected: Dictionary = {}
	for id: String in direct_groups:
		for required_id: String in dependency_closures[id]: selected[required_id] = true
	var result: Array[String] = []
	for id: String in selected: result.append(id)
	result.sort()
	return {"status":"described","binding":binding,"groupIds":result,
		"groupDescriptionComplete":true,"publicationAcknowledged":false,
		"queryCandidateCount":direct_groups.size(),"queryMemberCandidateCount":candidates.size(),
		"queryOwner":"citadel_publication_plan_exact_members"}


## Exact visual obligations from the same immutable members used to build the
## scene. A group may extend beyond this rectangle, so group completion alone
## cannot describe which visible members belong to a view chunk.
func visual_member_requirements(bounds: Rect2i) -> Dictionary:
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return {"status":"failed","reason":"invalid_visual_member_bounds"}
	var world_query := _world_rect_for_cells(bounds)
	var indices := _bucket_record_candidates(member_buckets,world_query,member_records.size())
	var members: Array[Dictionary] = []
	for index: int in indices:
		var record: Dictionary = member_records[index]
		if bool(record.visual) and _rect_intersects_aabb(world_query,record.bounds):
			members.append(record)
	return {"status":"described","binding":binding,"members":members,
		"descriptionComplete":true,"sourceSignature":output_signature,
		"queryMemberCandidateCount":indices.size()}


func exterior_structural_group_requirements(bounds: Rect2i, runtime_eligible: Dictionary = {}) -> Dictionary:
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return {"status":"failed","reason":"invalid_dependency_bounds"}
	var query := _world_rect_for_cells(bounds)
	var candidates := _bucket_candidates(bounds_buckets,query,MAX_VIEW_CANDIDATES)
	var best_id := ""
	var best_distance := INF
	for id: String in candidates:
		if not structural_group_ids.has(id): continue
		var allowed := true
		for required_id: String in dependency_closures[id]:
			if not eligible_group_ids.has(required_id) or not runtime_eligible.is_empty() and not runtime_eligible.has(required_id):
				allowed = false
				break
		if not allowed: continue
		var distance := _rect_aabb_distance_squared(query,groups[id].get("collisionBounds",groups[id].bounds))
		if distance < best_distance or is_equal_approx(distance,best_distance) and id < best_id:
			best_distance = distance
			best_id = id
	if best_id.is_empty(): return {"status":"pending","reason":"exterior_structural_group_unavailable"}
	var result := dependency_window(best_id)
	result["status"] = "described"
	result["binding"] = binding
	result["boundaryGroupId"] = best_id
	result["boundaryDistanceSquared"] = best_distance
	result["boundarySelection"] = "nearest_indexed_collision_bearing_structural_group"
	result["publicationAcknowledged"] = false
	result["queryCandidateCount"] = candidates.size()
	return result


## At most MAX_VIEW_CANDIDATES group rows cross into ranking. Completed groups
## disappear from the window and stable source order backfills hidden detail,
## so a continuously retained source drains without a whole-source rescan.
func ranked_groups(view_intent: Dictionary, completed: Dictionary = {}) -> Dictionary:
	var view := ViewPriority.normalize(view_intent)
	var candidates: Dictionary = {}
	if not view.is_empty():
		var radius := float(view.farDistance)+ViewPriority.PORTAL_LOOK_THROUGH_DISTANCE
		var query := Rect2(Vector2(view.origin.x-radius,view.origin.z-radius),Vector2.ONE*radius*2.0)
		for id: String in _bucket_candidates(center_buckets,query,MAX_VIEW_CANDIDATES):
			if not completed.has(id): candidates[id] = true
	for id: String in order:
		if candidates.size() >= MAX_VIEW_CANDIDATES: break
		if not completed.has(id): candidates[id] = true
	var ids: Array[String] = []
	var candidate_doors: Array[String] = []
	for id: String in candidates:
		ids.append(id)
		if not groups[id].get("doorPartIds",[]).is_empty(): candidate_doors.append(id)
	var rows := ViewPriority.ranked_group_subset(groups,ids,candidate_doors,view)
	return {"status":"ready","rows":rows,"candidateCount":ids.size(),"candidateLimit":MAX_VIEW_CANDIDATES}


static func _compile_first_useful(plan, description, building_source: Dictionary,
		furnishing_source: Dictionary) -> void:
	var by_part: Dictionary = description.publication_groups.get("groupByPart",{})
	for raw_part in furnishing_source.get("parts",[]):
		if not raw_part is Dictionary: continue
		var recipe: Variant = raw_part.get("recipe",{})
		if not recipe is Dictionary: continue
		var home_id := String(recipe.get("citadelUrbanHomeId",""))
		var archetype := String(raw_part.get("archetype",""))
		var member_id := "furnishing:"+String(raw_part.get("id",""))
		if home_id.is_empty() or archetype not in FIRST_USEFUL_HOME_ARCHETYPES or not by_part.has(member_id): continue
		if not plan.first_useful_homes.has(home_id): plan.first_useful_homes[home_id] = {}
		if not plan.first_useful_homes[home_id].has(archetype):
			plan.first_useful_homes[home_id][archetype] = String(by_part[member_id])
	for raw_part in building_source.get("parts",[]):
		if not raw_part is Dictionary: continue
		var semantic := String(raw_part.get("semantic",""))
		var member_id := "building:"+String(raw_part.get("id",""))
		if not by_part.has(member_id): continue
		var group_id := String(by_part[member_id])
		if semantic in FIRST_USEFUL_STRUCTURAL_SEMANTICS: plan.first_useful_structural_group_ids.append(group_id)
		if semantic in COURTYARD_SEMANTICS: plan.courtyard_group_ids.append(group_id)
	plan.first_useful_structural_group_ids = _unique_sorted(plan.first_useful_structural_group_ids)


static func _dependency_closure_eligible(plan, group_id: String) -> bool:
	if not plan.dependency_closures.has(group_id): return false
	for required_id: String in plan.dependency_closures[group_id]:
		if not plan.eligible_group_ids.has(required_id): return false
	return true


static func _dependency_window(source_groups: Dictionary, first_id: String) -> Dictionary:
	var visiting: Dictionary = {}
	var ordered: Array[String] = []
	var stack: Array = [[first_id,false]]
	while not stack.is_empty():
		var frame: Array = stack.pop_back()
		var id := String(frame[0])
		if not source_groups.has(id): return {"ready":false,"reason":"publication_group_dependency_missing","groupId":id}
		if bool(frame[1]):
			visiting[id] = 2
			if not ordered.has(id): ordered.append(id)
			continue
		if int(visiting.get(id,0)) == 2: continue
		if int(visiting.get(id,0)) == 1: return {"ready":false,"reason":"publication_group_dependency_cycle","groupId":id}
		visiting[id] = 1
		stack.append([id,true])
		var dependencies: Array = source_groups[id].get("dependencies",[]).duplicate()
		dependencies.sort()
		dependencies.reverse()
		for dependency in dependencies: stack.append([String(dependency),false])
	return {"status":"ready","groupIds":ordered}


static func _add_bucket(index: Dictionary, key: Vector2i, id: String) -> void:
	var encoded := "%d,%d" % [key.x,key.y]
	if not index.has(encoded): index[encoded] = []
	index[encoded].append(id)


static func _freeze_bucket_index(index: Dictionary) -> void:
	for key: String in index:
		var ids: Array = index[key]
		ids.sort()
		ids.make_read_only()


static func _add_member_record(plan, member_id: String, group_id: String, bounds: AABB,
		visual := true) -> void:
	var index: int = plan.member_records.size()
	var record := {"memberId":member_id,"groupId":group_id,"bounds":bounds,"visual":visual}
	record.make_read_only()
	plan.member_records.append(record)
	var low := _bucket_for_point(bounds.position)
	var high := _bucket_for_point(bounds.end-Vector3(0.0001,0.0,0.0001))
	for z: int in range(low.y,high.y+1):
		for x: int in range(low.x,high.x+1):
			var encoded := "%d,%d" % [x,z]
			if not plan.member_buckets.has(encoded): plan.member_buckets[encoded]=[]
			plan.member_buckets[encoded].append(index)


static func _member_bounds_valid(value: Variant) -> bool:
	if not value is AABB or not value.position.is_finite() or not value.size.is_finite() \
			or value.size.x <= 0.0 or value.size.z <= 0.0:
		return false
	var low := _bucket_for_point(value.position)
	var high := _bucket_for_point(value.end-Vector3(0.0001,0.0,0.0001))
	return high.x-low.x+1 <= MAX_BUCKET_QUERY_AXIS and high.y-low.y+1 <= MAX_BUCKET_QUERY_AXIS


static func _freeze_member_bucket_index(index: Dictionary) -> void:
	for key: String in index:
		var indices: Array = index[key]
		indices.sort()
		indices.make_read_only()


static func _bucket_candidates(index: Dictionary, query: Rect2, limit: int) -> Array[String]:
	var low := Vector2i(floori(query.position.x/BUCKET_WORLD_SIZE),floori(query.position.y/BUCKET_WORLD_SIZE))
	var high := Vector2i(floori((query.end.x-0.0001)/BUCKET_WORLD_SIZE),floori((query.end.y-0.0001)/BUCKET_WORLD_SIZE))
	if high.x-low.x+1 > MAX_BUCKET_QUERY_AXIS: high.x = low.x+MAX_BUCKET_QUERY_AXIS-1
	if high.y-low.y+1 > MAX_BUCKET_QUERY_AXIS: high.y = low.y+MAX_BUCKET_QUERY_AXIS-1
	var center := Vector2i(floori(query.get_center().x/BUCKET_WORLD_SIZE),floori(query.get_center().y/BUCKET_WORLD_SIZE))
	var radius := maxi(maxi(absi(center.x-low.x),absi(high.x-center.x)),maxi(absi(center.y-low.y),absi(high.y-center.y)))
	var seen: Dictionary = {}
	var result: Array[String] = []
	# Deterministic near-to-far square rings avoid sorting hundreds of empty
	# bucket coordinates on every quantized camera revision. Exact group distance
	# still owns final ordering in GeneratedContentViewPriority.
	for ring: int in range(radius+1):
		for z: int in range(center.y-ring,center.y+ring+1):
			for x: int in range(center.x-ring,center.x+ring+1):
				if ring>0 and absi(x-center.x)!=ring and absi(z-center.y)!=ring: continue
				if x<low.x or x>high.x or z<low.y or z>high.y: continue
				for id: String in index.get("%d,%d" % [x,z],[]):
					if seen.has(id): continue
					seen[id] = true
					result.append(id)
					if result.size() >= limit: return result
	return result


static func _bucket_record_candidates(index: Dictionary, query: Rect2, limit: int) -> Array[int]:
	var low := Vector2i(floori(query.position.x/BUCKET_WORLD_SIZE),floori(query.position.y/BUCKET_WORLD_SIZE))
	var high := Vector2i(floori((query.end.x-0.0001)/BUCKET_WORLD_SIZE),floori((query.end.y-0.0001)/BUCKET_WORLD_SIZE))
	if high.x-low.x+1 > MAX_BUCKET_QUERY_AXIS: high.x=low.x+MAX_BUCKET_QUERY_AXIS-1
	if high.y-low.y+1 > MAX_BUCKET_QUERY_AXIS: high.y=low.y+MAX_BUCKET_QUERY_AXIS-1
	var seen: Dictionary = {}
	var result: Array[int] = []
	for z: int in range(low.y,high.y+1):
		for x: int in range(low.x,high.x+1):
			for index_value in index.get("%d,%d" % [x,z],[]):
				var record_index := int(index_value)
				if seen.has(record_index): continue
				seen[record_index]=true
				result.append(record_index)
				if result.size()>=limit: return result
	return result


static func _bucket_for_point(value: Vector3) -> Vector2i:
	return Vector2i(floori(value.x/BUCKET_WORLD_SIZE),floori(value.z/BUCKET_WORLD_SIZE))


static func _world_rect_for_cells(bounds: Rect2i) -> Rect2:
	var minimum := Vector2(bounds.position)*CELL-Vector2.ONE*CELL*0.5
	var maximum := Vector2(bounds.end)*CELL+Vector2.ONE*CELL*0.5
	return Rect2(minimum,maximum-minimum)


static func _rect_intersects_aabb(query: Rect2, bounds: AABB) -> bool:
	return query.intersects(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)),true)


static func _rect_aabb_distance_squared(query: Rect2, bounds: AABB) -> float:
	var other := Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z))
	var dx := maxf(maxf(query.position.x-other.end.x,other.position.x-query.end.x),0.0)
	var dz := maxf(maxf(query.position.y-other.end.y,other.position.y-query.end.y),0.0)
	return dx*dx+dz*dz


static func _unique_sorted(values: Array[String]) -> Array[String]:
	var seen: Dictionary = {}
	for value: String in values: seen[value] = true
	var result: Array[String] = []
	for value: String in seen: result.append(value)
	result.sort()
	return result
