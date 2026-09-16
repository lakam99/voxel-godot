extends RefCounted

## Durable producer declarations and private, owner-scoped planning receipts.
## This authorizes clearance underlay only, never replaces physical validation.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Membership = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const KEY := "courtyardSupport"
const DECLARATION := {"version":1,"producer":"castle_courtyard_foundation_and_paving","role":"shared_foundation"}
const MAX_PARTS := 10000

static func declared(part, ground_y: float) -> bool:
	if not part is Part or not is_finite(ground_y) or ground_y<=0.0: return false
	var declaration: Variant=part.recipe.get(KEY)
	if not declaration is Dictionary or declaration.size()!=DECLARATION.size(): return false
	for key: String in DECLARATION:
		if typeof(declaration.get(key))!=typeof(DECLARATION[key]) or declaration.get(key)!=DECLARATION[key]: return false
	if part.id!="castle_compound_foundation_segment_00" or part.recipe.get("continuousGroundCourse")!=true \
			or part.recipe.get("navigationRole")!="structural_mass": return false
	return part.kind=="foundation" and part.semantic=="castle_courtyard_foundation" and part.material_id=="stone_foundation" and part.collision_enabled and part.rotation==Vector3.ZERO and part.position.is_finite() and part.size.is_finite() and part.size.x>0.0 and part.size.z>0.0 and is_equal_approx(part.position.y,0.02) and is_equal_approx(part.size.y,0.04) and is_equal_approx(float(part.recipe.get("gradeSurfaceY",NAN)),0.08)

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
	# These slabs overlap the house's own ground-reaching foundation; they are
	# not bearings below an elevated house. Courtyard egress cuts need not be
	# filled by a second slab where the house already supplies its own base.
	if foundation.kind!="foundation" or not foundation.collision_enabled or foundation.rotation!=Vector3.ZERO or foundation.position.y!=Vector3(0,ground_y*0.5,0).y or foundation.size.y!=Vector3(0,ground_y,0).y or not source.is_grounded_structural_root(foundation):
		return _fail("civic_shared_base_requires_grounded_house")
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
	var previous := ""
	for record: Variant in receipt.supports:
		if not _continue(continuation): return _fail("cancelled")
		if not record is Dictionary or not record.get("id") is String or record.id<=previous or not by_id.has(record.id): return _fail("invalid_courtyard_support_member")
		previous=record.id
		var part=by_id[record.id]
		if not declared(part,ground_y) or geometry(part)!=record: return _fail("changed_courtyard_support_member")
		if house.memberIds.has(part.id) or house_members.has(part.id): return _fail("mixed_courtyard_support_ownership")
		authorized[part.id]=true
	return {"ready":true,"authorized":authorized}

static func geometry(part) -> Dictionary:
	return {"id":part.id,"kind":part.kind,"semantic":part.semantic,"material":part.material_id,"collision":part.collision_enabled,"position":part.position,"rotation":part.rotation,"size":part.size}

static func _xz(bounds: AABB) -> Rect2:
	return Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z))

static func _continue(callback: Callable) -> bool:
	return not callback.is_valid() or bool(callback.call("civic_courtyard_support"))

static func _fail(reason: String) -> Dictionary:
	return {"ready":false,"reason":reason}
