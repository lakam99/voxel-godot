extends RefCounted

## Source-only infill planning. Uses actual house producers and curtain records;
## no publication, route, seed exception, geometry scaling or source mutation.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Placement = preload("res://scripts/buildings/BoundaryInfillPlacement.gd")
const Interior = preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const Membership = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Frame = preload("res://scripts/buildings/FacadeBearingFrameBuilder.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Furnishing = preload("res://scripts/buildings/FurnishingPart.gd")
const FurnishingPlan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Terraces = preload("res://scripts/buildings/ResidentialTerraceCarvingRecipe.gd")
const Support = preload("res://scripts/buildings/CivicCourtyardSupport.gd")
const Navigation = preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const CLEARANCE := 0.25
const MAX_PARTS := 10000

static func prepare_with_terrace_reconciliation(environment, specs: Array, producer: Callable, paving: Rect2, ground_y: float, continuation: Callable = Callable()) -> Dictionary:
	if not _valid_source(environment): return _fail("invalid_civic_infill_input")
	var source_before := var_to_bytes(environment.snapshot())
	var provisional_source := Terraces.planning_source(environment,continuation)
	if not provisional_source.ready: return provisional_source
	var proposed := prepare(provisional_source.blueprint,specs,producer,paving,ground_y,continuation)
	if not proposed.ready: return proposed
	var footprints: Array=[]
	for receipt: Dictionary in proposed.receipts:
		var bounds: AABB=receipt.actualBounds
		footprints.append(Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)).grow(CLEARANCE))
	var carved := Terraces.prepare(environment,footprints,continuation)
	if not carved.ready: return carved
	# Provisional omission of replaceable masses is never an acceptance result.
	# The ordinary strict planner must accept the real rebuilt geometry and the
	# exact same stored residence poses before replacements can be committed.
	var verified := prepare(carved.blueprint,proposed.specs,producer,paving,ground_y,continuation)
	if not verified.ready: return verified
	if var_to_bytes(verified.specs)!=var_to_bytes(proposed.specs): return _fail("carved_terrace_requires_unplanned_house_move")
	for i in range(verified.receipts.size()):
		if verified.receipts[i].actualBounds!=proposed.receipts[i].actualBounds: return _fail("carved_terrace_house_shape_changed")
	if source_before!=var_to_bytes(environment.snapshot()): return _fail("civic_environment_changed_during_preparation")
	verified["receipts"]=proposed.receipts
	verified["terraceReplacements"]=carved.replacements
	verified["terraceOriginals"]=carved.originals
	verified["terraceReconciliation"]={"changed":carved.changed,"footprints":carved.footprints,"dependencies":carved.dependencies,"sourceUnchanged":carved.sourceUnchanged,"actualCarvedSourceValidated":true}
	return verified

static func prepare(environment, specs: Array, producer: Callable, paving: Rect2, ground_y: float, continuation: Callable = Callable()) -> Dictionary:
	if not _valid_source(environment) or not _valid_specs(specs) or not producer.is_valid() or not is_finite(ground_y) or ground_y<=0.0:
		return _fail("invalid_civic_infill_input")
	var domain := _domain(environment,paving)
	if not domain.ready: return domain
	var collected := _obstacles(environment,ground_y)
	if not collected.ready: return collected
	var obstacles: Array=collected.boxes
	var resolved: Array=[]
	var receipts: Array=[]
	var support_receipts: Dictionary={}
	for spec: Dictionary in specs:
		if not _continue(continuation): return _fail("cancelled")
		var original = Blueprint.new("civic-infill-preview",environment.seed,"masonry")
		var produced: Variant = producer.call(original,spec)
		if produced is bool and not produced: return {"ready":false,"reason":"civic_house_producer_failed","house":spec.id,"phase":"preview"}
		var geometry := _house_geometry(original)
		if not geometry.ready: return geometry
		var fitted := Placement.fit_columns(geometry.bounds,domain.bounds,obstacles,CLEARANCE,func(): return _continue(continuation))
		if not fitted.ready: return {"ready":false,"reason":"civic_infill_search_failed","house":spec.id,"detail":fitted}
		var moved: Dictionary=spec.duplicate(true)
		moved.center=spec.center+fitted.translation
		var rebuilt = Blueprint.new("civic-infill-rebuilt",environment.seed,"masonry")
		produced = producer.call(rebuilt,moved)
		if produced is bool and not produced: return {"ready":false,"reason":"civic_house_producer_failed","house":spec.id,"phase":"rebuild"}
		var actual := _house_geometry(rebuilt)
		if not actual.ready: return actual
		# Rebuilding changes stored rounding and coordinate-derived IDs. Validate
		# the actual result; translated preview bounds cannot authorize it.
		var proof := Placement.fit(actual.bounds,domain.bounds,obstacles,CLEARANCE,func(): return _continue(continuation))
		if not proof.ready or proof.translation!=Vector3.ZERO:
			return {"ready":false,"reason":"civic_infill_rebuilt_bounds_rejected","house":spec.id,"detail":proof,
				"plannedBounds":fitted.placedBounds,"actualBounds":actual.bounds,"rebuiltCenter":moved.center}
		resolved.append(moved)
		var support := Support.bind(environment,rebuilt,spec.id,actual.bounds,ground_y,continuation)
		if not support.ready: return support
		support_receipts[spec.id]=support.receipt
		receipts.append({"id":spec.id,"originalCenter":spec.center,"center":moved.center,"translation":moved.center-spec.center,
			"originalBounds":geometry.bounds,"actualBounds":actual.bounds,"partCount":rebuilt.parts.size(),"testedCandidates":fitted.get("testedCandidates",0)})
		obstacles.append(actual.bounds)
	return {"ready":true,"specs":resolved,"receipts":receipts,"supportReceipts":support_receipts,"domain":domain.bounds,"paving":paving,"clearance":CLEARANCE,"obstacleCount":collected.boxes.size()}

static func validate_composed(source, plan: Dictionary, furniture, ground_y: float, continuation: Callable = Callable()) -> Dictionary:
	# Sufficient external-clearance proof of the actual terminal composition.
	# The complete envelope is deliberately conservative. This does not replace
	# rooted structural proof or validate arrangements inside the same house.
	var started := Time.get_ticks_usec()
	if not _valid_source(source) or not furniture is FurnishingPlan or not plan.get("ready",false) or not plan.get("paving") is Rect2 or not plan.get("specs") is Array or not _valid_specs(plan.specs) or not is_finite(ground_y) or ground_y<=0.0:
		return _fail("invalid_composed_civic_input")
	var pavings: Array=source.parts.filter(func(part): return part.id=="urban_civic_quarter_paving")
	if pavings.size()!=1 or pavings[0].semantic!="citadel_civic_quarter_paving" or pavings[0].recipe.get("pavingFamily")!="civic_setts" or not compatible_underlay(pavings[0],ground_y):
		return _fail("invalid_composed_civic_paving")
	var paving_box: AABB=source.transformed_part_bounds(pavings[0])
	var actual_paving := Rect2(Vector2(paving_box.position.x,paving_box.position.z),Vector2(paving_box.size.x,paving_box.size.z))
	if actual_paving!=plan.paving: return _fail("civic_paving_changed")
	var domain := _domain(source,actual_paving)
	if not domain.ready: return domain
	if domain.bounds!=plan.get("domain"): return _fail("civic_enclosure_changed")
	var membership := Membership.street_house_memberships(source)
	if not membership.ready: return membership
	if not plan.get("supportReceipts") is Dictionary or plan.supportReceipts.size()!=plan.specs.size(): return _fail("invalid_courtyard_support_receipts")
	if furniture.parts.size()>MAX_PARTS or furniture.protected_access_reservations.size()>MAX_PARTS: return _fail("civic_furnishing_limit")
	var checked: Array=[]
	for spec: Dictionary in plan.specs:
		if not _continue(continuation): return _fail("cancelled")
		var matches: Array=membership.houses.filter(func(house): return house.prefix==spec.id)
		if matches.size()!=1: return _fail("missing_composed_civic_owner")
		var house: Dictionary=matches[0]
		var owned: Dictionary={}
		for id: String in house.memberIds: owned[id]=true
		var own = Blueprint.new("civic-terminal-owner",source.seed,"masonry")
		var other = Blueprint.new("civic-terminal-environment",source.seed,"masonry")
		for part in source.parts:
			if not _continue(continuation): return _fail("cancelled")
			if owned.has(part.id): own.parts.append(part)
			else: other.parts.append(part)
		for room: Dictionary in source.rooms:
			if room.id==house.roomId: own.rooms.append(room)
			else: other.rooms.append(room)
		if own.rooms.size()!=1: return _fail("missing_composed_civic_room")
		var geometry := _house_geometry(own)
		if not geometry.ready: return geometry
		var envelope: AABB=geometry.bounds
		var foundation = own.parts.filter(func(part):return part.id==house.foundationId)[0]
		var support := Support.resolve(source,house,foundation,plan.supportReceipts.get(spec.id),ground_y,continuation)
		if not support.ready: return support
		var collected := _obstacles(other,ground_y,support.authorized)
		if not collected.ready: return collected
		var obstacles: Array=collected.boxes
		for room: Dictionary in other.rooms:
			obstacles.append_array(Interior.circulation_reservations([room]))
		for reservation: AABB in furniture.protected_access_reservations:
			# This collection has no owner identity. Even a byte-identical own-room
			# volume cannot establish provenance or multiplicity; none are exempt.
			if not Placement._valid_box(reservation): return _fail("invalid_civic_furnishing_reservation")
			obstacles.append(reservation)
		for furnishing in furniture.parts:
			if not _continue(continuation): return _fail("cancelled")
			if not furnishing is Furnishing: return _fail("invalid_civic_furnishing")
			var occupied := Frame.furnishing_bounds(furnishing.snapshot())
			if not occupied.ready: return occupied
			if furnishing.room_id==house.roomId: envelope=envelope.merge(occupied.bounds)
			else: obstacles.append(occupied.bounds)
		var proof := Placement.fit(envelope,domain.bounds,obstacles,CLEARANCE,func(): return _continue(continuation))
		if proof.get("reason","")=="cancelled":return _fail("cancelled")
		if not proof.ready or proof.translation!=Vector3.ZERO:
			var evidence := _clearance_failure_evidence(source,house,furniture,envelope,ground_y,continuation,support.authorized)
			if evidence.get("cancelled",false):return _fail("cancelled")
			return {"ready":false,"reason":"composed_civic_clearance_failed","house":spec.id,"bounds":envelope,"detail":proof,"blockingEvidence":evidence}
		var trees := _tree_clearance(source,envelope,continuation)
		if not trees.ready: return trees
		checked.append({"house":spec.id,"partCount":own.parts.size(),"bounds":envelope,"obstacleCount":obstacles.size(),"treeCount":trees.count})
	return {"ready":true,"houses":checked,"elapsedUsec":Time.get_ticks_usec()-started,
		"scope":"terminal civic external envelopes, furniture, access and tree footprints; not same-house interior or global structure validation"}

## Failure-only observations at the tested stored pose. This never alters
## obstacle membership, placement, clearance or an acceptance decision.
static func _clearance_failure_evidence(source, house: Dictionary, furniture, envelope: AABB, ground_y: float, continuation: Callable, authorized: Variant = null) -> Dictionary:
	var result := {"rows":[],"count":0,"counts":{},"truncated":false,"limit":32,
		"scope":"Stored-pose positive overlaps under the existing XZ clearance rule; not a proof that no alternative placement exists."}
	for part in source.parts:
		if not _continue(continuation):return {"cancelled":true}
		if house.memberIds.has(part.id) or _accepted_underlay(part,ground_y,authorized):continue
		var bounds: AABB=source.transformed_part_bounds(part)
		if _clearance_overlap(envelope,bounds):_append_clearance_evidence(result,{"kind":"part","id":part.id,"bounds":bounds},part)
	for room: Dictionary in source.rooms:
		if not _continue(continuation):return {"cancelled":true}
		if room.id==house.roomId:continue
		if room.get("role","")!="courtyard" and room.get("bounds") is AABB and _clearance_overlap(envelope,room.bounds):
			_append_clearance_evidence(result,{"kind":"room","id":room.id,"bounds":room.bounds})
		for access: Dictionary in room.get("accesses",[]):
			var bounds := Interior.access_reservation(access)
			if _clearance_overlap(envelope,bounds):_append_clearance_evidence(result,{"kind":"access","id":access.get("id",""),"roomId":room.id,"bounds":bounds})
		for bounds: AABB in Interior.circulation_reservations([room]):
			if _clearance_overlap(envelope,bounds):_append_clearance_evidence(result,{"kind":"circulation","id":room.id,"bounds":bounds})
	for index in range(furniture.protected_access_reservations.size()):
		if not _continue(continuation):return {"cancelled":true}
		var bounds: AABB=furniture.protected_access_reservations[index]
		if _clearance_overlap(envelope,bounds):_append_clearance_evidence(result,{"kind":"plan_access","id":str(index),"bounds":bounds})
	for part in furniture.parts:
		if not _continue(continuation):return {"cancelled":true}
		if part.room_id==house.roomId:continue
		var bounds: AABB=Frame.furnishing_bounds(part.snapshot()).bounds
		if _clearance_overlap(envelope,bounds):_append_clearance_evidence(result,{"kind":"furnishing","id":part.id,"roomId":part.room_id,"bounds":bounds})
	return result

static func _clearance_overlap(a: AABB,b: AABB) -> bool:
	return Placement._axis_overlap(a,b,0,CLEARANCE) and Placement._axis_overlap(a,b,1,0.0) and Placement._axis_overlap(a,b,2,CLEARANCE)

static func _append_clearance_evidence(result: Dictionary,row: Dictionary, part = null) -> void:
	result.count+=1
	result.counts[row.kind]=int(result.counts.get(row.kind,0))+1
	if result.rows.size()<result.limit:
		if part!=null:row["part"]=part.snapshot()
		result.rows.append(row)
	else:result.truncated=true

static func _tree_clearance(source, envelope: AABB, continuation: Callable) -> Dictionary:
	var urban: Variant=source.recipe.get("urbanPoc",{})
	if not urban is Dictionary: return _fail("invalid_civic_tree_collection")
	var trees: Variant=urban.get("treePlacements",[])
	if not trees is Array or trees.size()>256: return _fail("invalid_civic_tree_collection")
	var house := Rect2(Vector2(envelope.position.x,envelope.position.z),Vector2(envelope.size.x,envelope.size.z)).grow(CLEARANCE)
	var roots := 0
	for tree: Variant in trees:
		if not _continue(continuation): return _fail("cancelled")
		if not tree is Dictionary or not tree.get("position") is Vector3 or not tree.position.is_finite() or not tree.get("rootButtressFootprints",[]) is Array:
			return _fail("invalid_civic_tree")
		var radius: Variant=tree.get("canopyRadius")
		if not (radius is float or radius is int) or not is_finite(radius) or radius<=0.0 or radius>100.0: return _fail("invalid_civic_tree_radius")
		var footprint := Rect2(Vector2(tree.position.x,tree.position.z)-Vector2.ONE*radius,Vector2.ONE*radius*2.0)
		for root: Variant in tree.get("rootButtressFootprints",[]):
			roots+=1
			if roots>10000 or not root is Dictionary or not root.get("start") is Vector3 or not root.get("end") is Vector3 or not root.start.is_finite() or not root.end.is_finite(): return _fail("invalid_civic_root")
			for key: String in ["radiusStart","radiusEnd"]:
				var value: Variant=root.get(key)
				if not (value is float or value is int) or not is_finite(value) or value<=0.0 or value>100.0: return _fail("invalid_civic_root_radius")
			var root_radius := maxf(root.radiusStart,root.radiusEnd)
			footprint=footprint.merge(Rect2(Vector2(root.start.x,root.start.z),Vector2.ZERO).expand(Vector2(root.end.x,root.end.z)).grow(root_radius))
		if house.intersects(footprint): return {"ready":false,"reason":"composed_civic_tree_overlap","tree":tree.get("id","")}
	return {"ready":true,"count":trees.size()}

static func _domain(source, paving: Rect2) -> Dictionary:
	if not _valid_source(source): return _fail("invalid_civic_enclosure_source")
	if not paving.position.is_finite() or not paving.size.is_finite() or paving.size.x<=0 or paving.size.y<=0: return _fail("invalid_civic_paving_domain")
	var low := paving.position
	var high := paving.end
	var sides: Dictionary={}
	for part in source.parts:
		if part.semantic!="castle_curtain_wall": continue
		if part.rotation!=Vector3.ZERO or not part.collision_enabled: return _fail("unsupported_civic_enclosure")
		var box: AABB=source.transformed_part_bounds(part)
		if box.size.z>box.size.x and part.position.x>0.0:
			# The right civic district must fit within this actual wall's finite
			# run, not an infinite plane inferred from a nominal courtyard width.
			high.x=minf(high.x,box.position.x-CLEARANCE)
			low.y=maxf(low.y,box.position.z+CLEARANCE)
			high.y=minf(high.y,box.end.z-CLEARANCE)
			sides.right=true
		elif box.size.x>box.size.z:
			if part.position.z<0.0: low.y=maxf(low.y,box.end.z+CLEARANCE)
			else: high.y=minf(high.y,box.position.z-CLEARANCE)
	if not sides.has("right") or high.x<=low.x or high.y<=low.y: return _fail("missing_or_empty_civic_enclosure")
	return {"ready":true,"bounds":Rect2(low,high-low)}

static func _house_geometry(source) -> Dictionary:
	if not _valid_source(source) or source.parts.is_empty() or source.parts.size()>512: return _fail("invalid_civic_house_preview")
	var bounds := AABB()
	var first := true
	for part in source.parts:
		var box: AABB=source.transformed_part_bounds(part)
		if not Placement._valid_box(box): return _fail("invalid_civic_house_bounds")
		bounds=box if first else bounds.merge(box)
		first=false
		if part.kind == "door":
			bounds = bounds.merge(Navigation.door_staging_reservation(part, source.part_transform(part)))
	for room: Dictionary in source.rooms:
		for access: Dictionary in room.get("accesses",[]):
			var box := Interior.access_reservation(access)
			if not Placement._valid_box(box): return _fail("invalid_civic_house_access")
			bounds=bounds.merge(box)
	return {"ready":true,"bounds":bounds}

static func _obstacles(source, ground_y: float, authorized: Variant = null) -> Dictionary:
	if not _valid_source(source): return _fail("invalid_civic_obstacle_source")
	var boxes: Array=[]
	for part in source.parts:
		if _accepted_underlay(part,ground_y,authorized): continue
		var box: AABB=source.transformed_part_bounds(part)
		if not Placement._valid_box(box): return _fail("invalid_civic_obstacle")
		boxes.append(box)
	for room: Dictionary in source.rooms:
		if room.get("role","")!="courtyard" and room.get("bounds") is AABB: boxes.append(room.bounds)
		for access: Dictionary in room.get("accesses",[]): boxes.append(Interior.access_reservation(access))
	if boxes.size()>Placement.MAX_OBSTACLES: return _fail("civic_obstacle_limit")
	return {"ready":true,"boxes":boxes}

static func _accepted_underlay(part, ground_y: float, authorized: Variant) -> bool:
	if authorized is Dictionary and part.semantic=="castle_courtyard_foundation":
		return authorized.has(part.id)
	return compatible_underlay(part,ground_y)

static func compatible_underlay(part, ground_y: float) -> bool:
	if not part is Part or not is_finite(ground_y) or ground_y<=0.0: return false
	if part.kind!="foundation" or part.rotation!=Vector3.ZERO: return false
	# Exact producer-owned base layers only. Raised beds, unrelated foundations,
	# and noncolliding decorative structures remain obstacles.
	var carved_paving: bool = _indexed_id(part.id,"castle_compound_paving_segment_") and part.recipe.get("egressCarved",false)==true and part.recipe.get("navigationRole")=="walkable_support" and part.recipe.get("pavingRegion")=="citadel_courtyard" and part.recipe.get("pavingHeading")=="x"
	# The production castle carves its ground around egress/entry corridors and
	# emits indexed segments. Their identity and geometry come from the same
	# add_courtyard_foundation_and_paving producer, not a broad decor exemption.
	if Support.declared(part,ground_y):
		return true
	if (part.id=="castle_courtyard_paving" or carved_paving) and part.semantic=="castle_courtyard_paving" and part.recipe.get("pavingFamily","")=="courtyard_setts" and part.collision_enabled and part.material_id=="cobblestone":
		return part.position.y==Vector3(0,ground_y+0.07,0).y and part.size.y==Vector3(0,0.14,0).y
	if part.id=="urban_civic_quarter_paving" and part.semantic=="citadel_civic_quarter_paving" and part.recipe.get("pavingFamily","")=="civic_setts" and not part.collision_enabled:
		return part.position.y==Vector3(0,ground_y+0.18,0).y and part.size.y==Vector3(0,0.08,0).y
	return false

static func _indexed_id(id: String, prefix: String) -> bool:
	if not id.begins_with(prefix): return false
	var suffix := id.trim_prefix(prefix)
	if not suffix.is_valid_int(): return false
	var index := suffix.to_int()
	return index>=0 and index<MAX_PARTS and id=="%s%02d" % [prefix,index]

static func _valid_source(source) -> bool:
	if not source is Blueprint or source.parts.size()>MAX_PARTS or source.rooms.size()>MAX_PARTS: return false
	var ids: Dictionary={}
	for part: Variant in source.parts:
		if not part is Part or part.id.is_empty() or ids.has(part.id) or not part.position.is_finite() or not part.rotation.is_finite() or not Placement._valid_box(AABB(part.position-part.size*0.5,part.size)): return false
		ids[part.id]=true
	var rooms: Dictionary={}
	var access_count := 0
	for room: Variant in source.rooms:
		if not room is Dictionary or not room.get("id") is String or room.id.is_empty() or rooms.has(room.id) or not room.get("role","") is String or not room.get("accesses",[]) is Array: return false
		rooms[room.id]=true
		if room.get("role","")!="courtyard" and (not room.get("bounds") is AABB or not Placement._valid_box(room.bounds)): return false
		for access: Variant in room.get("accesses",[]):
			access_count+=1
			if access_count>MAX_PARTS or not access is Dictionary or not access.get("position") is Vector3 or not access.position.is_finite(): return false
			var size: Variant=access.get("furnishingSize",access.get("size"))
			if not size is Vector3 or not Placement._valid_box(AABB(Vector3.ZERO,size)): return false
	return true

static func _valid_specs(specs: Array) -> bool:
	if specs.is_empty() or specs.size()>8: return false
	var ids: Dictionary={}
	for spec: Variant in specs:
		if not spec is Dictionary or not spec.get("id") is String or spec.id.is_empty() or ids.has(spec.id) or not spec.get("center") is Vector3 or not spec.center.is_finite() or not spec.get("material") is String or spec.material.is_empty(): return false
		ids[spec.id]=true
		var rise: Variant=spec.get("roofRise")
		if not (rise is int or rise is float) or not is_finite(rise) or rise<3.2 or rise>=4.8: return false
		for key: String in ["width","depth","height"]:
			var value: Variant=spec.get(key)
			if not (value is int or value is float) or not is_finite(value) or value<=0.0 or value>100.0: return false
	return true

static func _continue(callback: Callable) -> bool:
	return not callback.is_valid() or callback.call("civic_house_infill") == true

static func _fail(reason: String) -> Dictionary:
	return {"ready":false,"reason":reason}
