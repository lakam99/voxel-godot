extends RefCounted

## Durable producer declarations and private, owner-scoped planning receipts.
## This authorizes clearance underlay only, never replaces physical validation.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Membership = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const KEY := "courtyardSupport"
const DECLARATION := {"version":1,"producer":"castle_courtyard_foundation_and_paving","role":"shared_foundation"}
const MAX_PARTS := 10000
const MAX_FRAGMENTS := 4096

static func declared(part, ground_y: float) -> bool:
	if not part is Part or not is_finite(ground_y) or ground_y<=0.0: return false
	var declaration: Variant=part.recipe.get(KEY)
	if not declaration is Dictionary or declaration.size()!=DECLARATION.size(): return false
	for key: String in DECLARATION:
		if typeof(declaration.get(key))!=typeof(DECLARATION[key]) or declaration.get(key)!=DECLARATION[key]: return false
	var prefix := "castle_compound_foundation_segment_"
	var suffix: String=part.id.trim_prefix(prefix)
	if not part.id.begins_with(prefix) or not suffix.is_valid_int(): return false
	var index := suffix.to_int()
	if index<0 or index>=MAX_PARTS or part.id!="%s%02d"%[prefix,index]: return false
	if part.recipe.get("egressCarved")!=true or part.recipe.get("navigationRole")!="structural_mass": return false
	return part.kind=="foundation" and part.semantic=="castle_courtyard_foundation" and part.material_id=="stone_foundation" and part.collision_enabled and part.rotation==Vector3.ZERO and part.position.is_finite() and part.size.is_finite() and part.size.x>0.0 and part.size.z>0.0 and part.position.y==Vector3(0,ground_y*0.5,0).y and part.size.y==Vector3(0,ground_y,0).y

static func bind(environment, rebuilt, owner: String, envelope: AABB, ground_y: float, continuation: Callable) -> Dictionary:
	var membership := Membership.street_house_memberships(rebuilt)
	if not membership.ready: return membership
	if membership.houses.size()!=1 or membership.houses[0].prefix!=owner: return _fail("invalid_courtyard_support_owner")
	var house: Dictionary=membership.houses[0]
	var foundation = rebuilt.parts.filter(func(part):return part.id==house.foundationId)[0]
	var receipt := {"prefix":house.prefix,"roomId":house.roomId,"doorId":house.doorId,"foundationId":house.foundationId,"foundation":geometry(foundation),"supports":[]}
	for part in environment.parts:
		if not _continue(continuation): return _fail("cancelled")
		if declared(part,ground_y) and _xz(environment.transformed_part_bounds(part)).intersects(_xz(envelope).grow(0.25)):
			receipt.supports.append(geometry(part))
	receipt.supports.sort_custom(func(a,b):return a.id<b.id)
	var proof := resolve(environment,house,foundation,receipt,ground_y,continuation)
	if not proof.ready: return proof
	return {"ready":true,"receipt":receipt}

static func resolve(source, house: Dictionary, foundation, receipt: Variant, ground_y: float, continuation: Callable) -> Dictionary:
	if not receipt is Dictionary or receipt.size()!=6 or not receipt.get("supports") is Array or receipt.supports.size()>MAX_PARTS: return _fail("invalid_courtyard_support_receipt")
	for key: String in ["prefix","roomId","doorId","foundationId"]:
		if receipt.get(key)!=house.get(key): return _fail("foreign_courtyard_support_owner")
	if receipt.get("foundation")!=geometry(foundation): return _fail("changed_courtyard_supported_foundation")
	var membership := Membership.street_house_memberships(source)
	if not membership.ready: return membership
	var house_members: Dictionary={}
	for current: Dictionary in membership.houses:
		for id: String in current.memberIds: house_members[id]=true
	var by_id: Dictionary={}
	for part in source.parts:
		if not _continue(continuation): return _fail("cancelled")
		if by_id.has(part.id): return _fail("duplicate_courtyard_support_source")
		by_id[part.id]=part
	var authorized: Dictionary={}
	var rectangles: Array[Rect2]=[]
	var previous := ""
	for record: Variant in receipt.supports:
		if not _continue(continuation): return _fail("cancelled")
		if not record is Dictionary or not record.get("id") is String or record.id<=previous or not by_id.has(record.id): return _fail("invalid_courtyard_support_member")
		previous=record.id
		var part=by_id[record.id]
		if not declared(part,ground_y) or geometry(part)!=record: return _fail("changed_courtyard_support_member")
		if house.memberIds.has(part.id) or house_members.has(part.id): return _fail("mixed_courtyard_support_ownership")
		authorized[part.id]=true
		rectangles.append(_xz(source.transformed_part_bounds(part)))
	if not rectangles.is_empty():
		var coverage := covers(_xz(source.transformed_part_bounds(foundation)),rectangles,continuation)
		if not coverage.ready: return coverage
	return {"ready":true,"authorized":authorized}

static func covers(footprint: Rect2, rectangles: Array[Rect2], continuation: Callable) -> Dictionary:
	# Subtract each actual support rectangle. A bounding box or area sum would
	# accept holes and double-count overlapping slabs.
	var remaining: Array[Rect2]=[footprint]
	for support: Rect2 in rectangles:
		var next: Array[Rect2]=[]
		for region: Rect2 in remaining:
			if not _continue(continuation): return _fail("cancelled")
			var cut := region.intersection(support)
			if not cut.has_area():
				next.append(region)
			else:
				for fragment: Rect2 in [Rect2(region.position,Vector2(cut.position.x-region.position.x,region.size.y)),Rect2(Vector2(cut.end.x,region.position.y),Vector2(region.end.x-cut.end.x,region.size.y)),Rect2(Vector2(cut.position.x,region.position.y),Vector2(cut.size.x,cut.position.y-region.position.y)),Rect2(Vector2(cut.position.x,cut.end.y),Vector2(cut.size.x,region.end.y-cut.end.y))]:
					if fragment.has_area(): next.append(fragment)
			if next.size()>MAX_FRAGMENTS: return _fail("courtyard_support_coverage_limit")
		remaining=next
		if remaining.is_empty(): return {"ready":true}
	return _fail("courtyard_support_coverage_gap")

static func geometry(part) -> Dictionary:
	return {"id":part.id,"kind":part.kind,"semantic":part.semantic,"material":part.material_id,"collision":part.collision_enabled,"position":part.position,"rotation":part.rotation,"size":part.size}

static func _xz(bounds: AABB) -> Rect2:
	return Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z))

static func _continue(callback: Callable) -> bool:
	return not callback.is_valid() or bool(callback.call("civic_courtyard_support"))

static func _fail(reason: String) -> Dictionary:
	return {"ready":false,"reason":reason}
