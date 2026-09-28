extends RefCounted

## Reconcile retained residential terrace masses with replacement residence
## footprints. Source-only staging: never returns a partially carved source.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Occupancy = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const Arithmetic = preload("res://scripts/buildings/ConstructionSeamMath.gd")
const MAX_PARTS := 10000
const MAX_CUTS := 8
const MAX_SEGMENTS := 128

static func replaceable(part, recipe: Dictionary) -> bool:
	if not part is Part or part.kind!="foundation" or part.material_id!="stone_foundation" or part.rotation!=Vector3.ZERO or not part.collision_enabled:
		return false
	if part.semantic!="castle_inhabited_terrace_block": return false
	var carved: Variant=part.recipe.get("residenceCarved")
	var role: Variant=part.recipe.get("navigationRole")
	if not carved is bool or not carved or not role is String or role!="structural_mass": return false
	var tokens := String(part.id).split("_")
	if tokens.size()!=6 or tokens[0]!="castle" or tokens[1]!="terrace" or tokens[2]!="block" or tokens[4] not in ["left","right"]: return false
	if not tokens[3].is_valid_int() or not tokens[5].is_valid_int(): return false
	var row := int(tokens[3])
	var segment := int(tokens[5])
	if row<0 or segment<0 or segment>=MAX_PARTS or part.id!="castle_terrace_block_%02d_%s_%02d" % [row,tokens[4],segment]: return false
	if not recipe.get("castleGrammar",{}) is Dictionary: return false
	var grammar: Dictionary=recipe.get("castleGrammar",{})
	if not grammar.get("courtyardGrid",{}) is Dictionary: return false
	var grid: Dictionary=grammar.get("courtyardGrid",{})
	if not grid.get("rowCenters",[]) is Array or not grid.get("mode","") is String: return false
	var rows: Array=grid.get("rowCenters",[])
	if grid.get("mode")!="district_grid" or row>=rows.size(): return false
	var base := float(recipe.get("foundationHeight",0.62))
	var elevation := Castle.citadel_terrace_elevation_at_z(grid,float(rows[row]))
	return part.position.is_finite() and part.size.is_finite() and part.size.x>0 and part.size.z>0 and part.position.y==Vector3(0,base+elevation*0.5,0).y and part.size.y==Vector3(0,maxf(0.12,elevation),0).y

static func planning_source(source, continuation: Callable = Callable()) -> Dictionary:
	if not _valid_source(source): return _fail("invalid_terrace_source")
	var staged = Copy.copy_blueprint(source.snapshot())
	var immutable: Array=[]
	var replaceable_ids: Array=[]
	for part in staged.parts:
		if not _continue(continuation): return _fail("cancelled")
		if replaceable(part,staged.recipe): replaceable_ids.append(part.id)
		else: immutable.append(part)
	staged.parts=immutable
	_reindex(staged)
	return {"ready":true,"blueprint":staged,"replaceableIds":replaceable_ids,
		"scope":"provisional placement constraints only; actual carve and strict replay required before acceptance"}

static func prepare(source, footprints: Array, continuation: Callable = Callable()) -> Dictionary:
	if not _valid_source(source) or footprints.is_empty() or footprints.size()>MAX_CUTS: return _fail("invalid_terrace_carving_input")
	var cuts: Array[Dictionary]=[]
	for footprint: Variant in footprints:
		if not footprint is Rect2 or not footprint.position.is_finite() or not footprint.size.is_finite() or footprint.size.x<=0 or footprint.size.y<=0: return _fail("invalid_residence_footprint")
		cuts.append({"rect":footprint})
	var before: Dictionary=source.snapshot()
	var result = Copy.copy_blueprint(before)
	var output: Array=[]
	var replacements: Dictionary={}
	var originals: Dictionary={}
	var changed: Array=[]
	for part in result.parts:
		if not _continue(continuation): return _fail("cancelled")
		var bounds: AABB=result.transformed_part_bounds(part)
		var rect := Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z))
		if not replaceable(part,result.recipe) or not footprints.any(func(cut): return rect.intersects(cut)):
			output.append(part)
			continue
		# Existing Castle subtraction preserves old voids: operate on each actual
		# retained segment, not an uncarved rectangle regenerated from old layout.
		var pieces := Castle.subtract_courtyard_egress_corridors(rect,cuts,true)
		if pieces.size()>MAX_SEGMENTS: return _fail("terrace_segment_limit")
		var emitted: Array=[]
		var volumes: Array=[]
		for i in range(pieces.size()):
			if not _continue(continuation): return _fail("cancelled")
			var piece: Rect2=pieces[i]
			var x_axis := _axis_segments(piece.position.x,piece.end.x)
			var z_axis := _axis_segments(piece.position.y,piece.end.y)
			if not x_axis.ready or not z_axis.ready: return {"ready":false,"reason":"unrepresentable_terrace_fragment","partId":part.id,"piece":i,"x":x_axis,"z":z_axis}
			for x: Dictionary in x_axis.segments:
				for z: Dictionary in z_axis.segments:
					var record: Dictionary=part.snapshot()
					record.id="%s_residential_cut_%02d" % [part.id,emitted.size()]
					record.position=Vector3(x.center,part.position.y,z.center)
					record.size=Vector3(x.size,part.size.y,z.size)
					record.recipe["residentialTerraceSourcePartId"]=part.id
					var rebuilt = Part.new(record)
					var actual: AABB=result.transformed_part_bounds(rebuilt)
					var actual_rect := Rect2(Vector2(actual.position.x,actual.position.z),Vector2(actual.size.x,actual.size.z))
					if not _contains(rect,actual_rect): return {"ready":false,"reason":"represented_terrace_expands_source","partId":part.id,"piece":i,"old":rect,"actual":actual_rect}
					if footprints.any(func(cut): return actual_rect.intersects(cut)): return {"ready":false,"reason":"represented_terrace_enters_cut","partId":part.id,"piece":i,"ideal":piece,"actual":actual_rect,"cuts":footprints}
					emitted.append(rebuilt)
					volumes.append(_box(actual))
					if emitted.size()>MAX_SEGMENTS: return _fail("terrace_segment_limit")
		# Removing a producer's sub-minimum fragment is not silently accepted.
		# All removed occupancy must be inside the explicitly requested cutouts.
		var retained_and_cuts: Array=volumes.duplicate()
		for cut: Rect2 in footprints:
			retained_and_cuts.append([float(cut.position.x),float(bounds.position.y),float(cut.position.y),float(cut.end.x),float(bounds.end.y),float(cut.end.y)])
		var preservation := Occupancy.cover(_box(bounds),retained_and_cuts)
		if not preservation.ready or not preservation.covered: return {"ready":false,"reason":"terrace_removal_outside_replacement_footprint","partId":part.id,"detail":preservation}
		output.append_array(emitted)
		if output.size()>MAX_PARTS: return _fail("terrace_part_limit")
		replacements[part.id]=emitted.map(func(value): return value.snapshot())
		originals[part.id]=part.snapshot()
		changed.append({"id":part.id,"originalBounds":bounds,"pieceCount":emitted.size()})
	result.parts=output
	_reindex(result)
	var references := _reference_guard(result.snapshot(),replacements,continuation)
	if not references.ready: return references
	var dependencies := _preserved_dependents(source,result,originals,replacements,continuation)
	if not dependencies.ready: return dependencies
	if var_to_bytes(before)!=var_to_bytes(source.snapshot()): return _fail("terrace_source_mutated")
	return {"ready":true,"blueprint":result,"replacements":replacements,"originals":originals,"changed":changed,"dependencies":dependencies,"footprints":footprints.duplicate(),"sourceUnchanged":true}

static func commit(source, originals: Dictionary, replacements: Dictionary) -> Dictionary:
	if not _valid_source(source) or originals.size()!=replacements.size(): return _fail("invalid_terrace_commit")
	var snapshot: Dictionary=source.snapshot()
	var found: Dictionary={}
	var ids: Dictionary={}
	var records: Array=[]
	for record: Dictionary in snapshot.parts:
		if ids.has(record.id): return _fail("duplicate_terrace_commit_source_id")
		ids[record.id]=true
		if not replacements.has(record.id): records.append(record); continue
		if not originals.has(record.id) or var_to_bytes(record)!=var_to_bytes(originals[record.id]): return _fail("stale_terrace_commit_source")
		found[record.id]=true
		if not replacements[record.id] is Array: return _fail("invalid_terrace_replacement_records")
		records.append_array(replacements[record.id])
	if found.size()!=replacements.size() or records.size()>MAX_PARTS: return _fail("missing_or_excess_terrace_commit_records")
	ids.clear()
	for record: Variant in records:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or ids.has(record.id): return _fail("duplicate_or_invalid_terrace_replacement_id")
		ids[record.id]=true
	snapshot.parts=records
	var references := _reference_guard(snapshot,replacements,Callable())
	if not references.ready: return references
	var staged = Copy.copy_blueprint(snapshot)
	if not _valid_source(staged): return _fail("invalid_terrace_commit_geometry")
	# Source was untouched during preflight; publish the complete part list once.
	source.parts=staged.parts
	_reindex(source)
	return {"ready":true,"changedCount":replacements.size()}

static func _reindex(source) -> void:
	source.physical_parts_by_id.clear()
	source.structural_support_grid.clear()
	for part in source.parts: source.physical_parts_by_id[part.id]=part

static func _reference_guard(snapshot: Dictionary, removed: Dictionary, continuation: Callable) -> Dictionary:
	var work := {"count":0}
	for record: Dictionary in snapshot.parts:
		var recipe: Dictionary=record.recipe.duplicate(true)
		# This one field identifies historic source ownership, not a support ID.
		recipe.erase("residentialTerraceSourcePartId")
		var checked := _references(recipe,removed,work,0,continuation)
		if not checked.ready: checked["ownerId"]=record.id; return checked
	for value: Variant in [snapshot.rooms,snapshot.recipe]:
		var checked := _references(value,removed,work,0,continuation)
		if not checked.ready: return checked
	return {"ready":true}

static func _references(value: Variant, removed: Dictionary, work: Dictionary, depth: int, continuation: Callable) -> Dictionary:
	work.count+=1
	if depth>64 or work.count>1000000: return _fail("terrace_reference_scan_limit")
	if not _continue(continuation): return _fail("cancelled")
	if value is String or value is StringName:
		if removed.has(String(value)): return {"ready":false,"reason":"referenced_terrace_requires_dependency_reconciliation","partId":String(value)}
	elif value is Dictionary:
		for key: Variant in value:
			if (key is String or key is StringName) and removed.has(String(key)): return {"ready":false,"reason":"referenced_terrace_requires_dependency_reconciliation","partId":String(key)}
			var checked := _references(value[key],removed,work,depth+1,continuation)
			if not checked.ready: return checked
	elif value is Array or value is PackedStringArray:
		for item: Variant in value:
			var checked := _references(item,removed,work,depth+1,continuation)
			if not checked.ready: return checked
	return {"ready":true}

static func _preserved_dependents(source, staged, originals: Dictionary, replacements: Dictionary, continuation: Callable) -> Dictionary:
	var affected: Dictionary={}
	var contacts := 0
	# Evaluate actual survivors, not a category such as "replaceable". Side and
	# embedded contacts are included. Lost proximity triggers the established
	# physical authority below; proximity alone is not a support dependency.
	for id: String in originals:
		var old = Part.new(originals[id])
		var bounds: AABB=source.transformed_part_bounds(old)
		var retained: Array=[]
		for record: Dictionary in replacements[id]: retained.append(_box(staged.transformed_part_bounds(Part.new(record))))
		for other in staged.parts:
			if not _continue(continuation): return _fail("cancelled")
			if other.recipe.get("residentialTerraceSourcePartId")==id: continue
			var other_bounds: AABB=staged.transformed_part_bounds(other)
			var query_bounds := other_bounds.grow(source.PHYSICAL_CONTACT_MARGIN*2.0)
			# Broad phase includes the complete existing support reach, not just
			# contact tolerance. Final dependency acceptance stays with that owner.
			# One contact-width pad includes exact closed support endpoints in this
			# positive-volume broad phase. It never admits a support on its own.
			var vertical_reach: float = Blueprint.STRUCTURAL_SUPPORT_MAX_GAP+Blueprint.PHYSICAL_CONTACT_MARGIN
			query_bounds.position.y=other_bounds.position.y-vertical_reach
			query_bounds.size.y=other_bounds.size.y+2.0*vertical_reach
			var contact := Occupancy.intersection(_box(bounds),_box(query_bounds))
			if contact.is_empty(): continue
			contacts+=1
			var proof := Occupancy.cover(contact,retained)
			if not proof.ready: return _fail("terrace_contact_accounting_failed")
			if not proof.covered: affected[other.id]=true
	if affected.is_empty(): return {"ready":true,"contactCount":contacts,"reprovedIds":[]}
	# Resolve on private copies only. This is the existing physical authority,
	# including embedded support and attachment anchors, not another rule set.
	var before = Copy.copy_blueprint(source.snapshot())
	var after = Copy.copy_blueprint(staged.snapshot())
	if not before.resolve_physical_contracts_cancellable(continuation) or not after.resolve_physical_contracts_cancellable(continuation): return _fail("cancelled")
	for id: String in affected:
		if not _continue(continuation): return _fail("cancelled")
		var survivor = after.find_part(id)
		var original = before.find_part(id)
		if original==null:
			original=before.find_part(String(survivor.recipe.get("residentialTerraceSourcePartId","")))
		if original==null: return _fail("missing_terrace_dependent_origin")
		if survivor.physical_intent=="facade_attachment":
			var old_anchors: Array=original.recipe.get("physicalAnchorPartIds",[])
			var new_anchors: Array=survivor.recipe.get("physicalAnchorPartIds",[])
			if not old_anchors.is_empty() and new_anchors.is_empty(): return {"ready":false,"reason":"terrace_dependent_anchor_lost","dependentId":id}
			var was_rooted := old_anchors.any(func(anchor): return before.has_rooted_support_chain(before.find_part(anchor),{}))
			var now_rooted := new_anchors.any(func(anchor): return after.has_rooted_support_chain(after.find_part(anchor),{}))
			if was_rooted and not now_rooted: return {"ready":false,"reason":"terrace_dependent_rooted_anchor_lost","dependentId":id}
		elif survivor.physical_intent in ["structural_mass","walkable_surface","structural_root"]:
			if before.has_rooted_support_chain(original,{}) and not after.has_rooted_support_chain(survivor,{}): return {"ready":false,"reason":"terrace_dependent_rooted_support_lost","dependentId":id}
			var old_coverage: Array=original.recipe.get("physicalSupportCoverage",[])
			var new_coverage: Array=survivor.recipe.get("physicalSupportCoverage",[])
			if old_coverage.size()==new_coverage.size():
				for i in range(old_coverage.size()):
					if old_coverage[i].get("supported",false) and not new_coverage[i].get("supported",false): return {"ready":false,"reason":"terrace_dependent_support_coverage_lost","dependentId":id,"sample":i}
	return {"ready":true,"contactCount":contacts,"reprovedIds":affected.keys()}

static func _contains(outer: Rect2, inner: Rect2) -> bool:
	return inner.position.x>=outer.position.x and inner.position.y>=outer.position.y and inner.end.x<=outer.end.x and inner.end.y<=outer.end.y

static func _represented_axis(low: float, high: float) -> Dictionary:
	# Fit stored centre/size to EXACT existing producer endpoints. This bounded
	# construction search does not move the cut planes or waive clearance.
	var center := float(Vector3((low+high)*0.5,0,0).x)
	var size := float(Vector3(high-low,0,0).x)
	var centers := _neighbours(center)
	var sizes := _neighbours(size)
	for c: float in centers:
		for s: float in sizes:
			if s<0.02: continue
			var origin := Vector3(c,0,0)
			var half := Vector3(s,0,0)*0.5
			if float((origin-half).x)==low and float((origin+half).x)==high:
				return {"ready":true,"center":c,"size":s}
	return {"ready":false,"low":low,"high":high}

static func _axis_segments(low: float, high: float) -> Dictionary:
	var whole := _represented_axis(low,high)
	if whole.ready: return {"ready":true,"segments":[whole]}
	# Some endpoint parity pairs cannot be represented by ONE float32 centre
	# and size. Two same-material solids may overlap inside the retained volume;
	# their union still has exactly the requested endpoints and no missing cell.
	# Only four neighbouring midpoint planes are considered on either side.
	var midpoint := float(Vector3((low+high)*0.5,0,0).x)
	var planes := _neighbours(midpoint)
	for left_high: float in planes:
		if left_high<=low or left_high>=high: continue
		var left := _represented_axis(low,left_high)
		if not left.ready: continue
		for right_low: float in planes:
			if right_low<=low or right_low>left_high or right_low>=high: continue
			var right := _represented_axis(right_low,high)
			if right.ready: return {"ready":true,"segments":[left,right],"sharedInternalSpan":left_high-right_low}
	return whole

static func _neighbours(value: float) -> Array:
	var result: Array=[value]
	var low := value
	var high := value
	for i in range(4):
		low=-Arithmetic.next_float32_up(-low)
		high=Arithmetic.next_float32_up(high)
		result.append(low); result.append(high)
	return result

static func _box(bounds: AABB) -> Array:
	return [float(bounds.position.x),float(bounds.position.y),float(bounds.position.z),float(bounds.end.x),float(bounds.end.y),float(bounds.end.z)]

static func _valid_source(source) -> bool:
	if not source is Blueprint or source.parts.size()>MAX_PARTS: return false
	var ids: Dictionary={}
	for part: Variant in source.parts:
		if not part is Part or part.id.is_empty() or ids.has(part.id) or not source.has_finite_positive_bounds(part): return false
		ids[part.id]=true
		if not Occupancy.valid(_box(source.transformed_part_bounds(part))): return false
	return true

static func _continue(callback: Callable) -> bool:
	return not callback.is_valid() or callback.call("residential_terrace_carving")==true

static func _fail(reason: String) -> Dictionary:
	return {"ready":false,"reason":reason}
