extends RefCounted
## Pure source preparation, not a gameplay-frame publication API.
## Composer integration is separate; this helper has no runtime caller.
## Preserve a subset of retired real solids, never fabricate a footprint footing.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_PARTS = 16384
const MAX_FRAGMENTS = 256
const EPS = 0.00001

static func fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}

static func valid_box(box: AABB) -> bool:
	return box.position.is_finite() and box.end.is_finite() and box.size.is_finite() and box.size.x > 0 and box.size.y > 0 and box.size.z > 0

static func axis_box(b, p) -> bool:
	if not b.has_finite_positive_bounds(p): return false
	var basis = Basis.from_euler(p.rotation)
	for v in [basis.x,basis.y,basis.z]:
		var count = 0
		for axis in range(3):
			if absf(absf(v[axis])-1.0) <= 0.000001: count += 1
			elif absf(v[axis]) > 0.000001: return false
		if count != 1: return false
	# This only admits candidates. Actual oriented-solid containment is proved
	# independently before any new support can be returned.
	return true

static func rect(box: AABB) -> Rect2:
	return Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z))

static func solid_containment(inner, old, target) -> bool:
	# Unrotated record coordinates are float32; scalar float64 arithmetic avoids
	# an AABB min/extent roundtrip expanding the actual solid being certified.
	for axis in range(3):
		var low = float(inner.position[axis])-float(inner.size[axis])*0.5
		var high = float(inner.position[axis])+float(inner.size[axis])*0.5
		if axis == 1:
			if high > float(target.position.y)-float(target.size.y)*0.5: return false
		elif low < float(target.position[axis])-float(target.size[axis])*0.5 or high > float(target.position[axis])+float(target.size[axis])*0.5: return false
	return oriented_contains(old,inner)

static func oriented_contains(outer,inner) -> bool:
	var transform = Transform3D(Basis.from_euler(outer.rotation),outer.position).affine_inverse() * Transform3D(Basis.from_euler(inner.rotation),inner.position)
	# Both shapes are convex boxes: containment of every vertex proves that
	# the whole new solid is a subset of the actual retired oriented solid.
	for x in [-1.0,1.0]:
		for y in [-1.0,1.0]:
			for z in [-1.0,1.0]:
				var corner = transform * (inner.size*Vector3(x,y,z)*0.5)
				for axis in range(3):
					if not is_finite(corner[axis]) or absf(corner[axis]) > outer.size[axis]*0.5: return false
	return true

static func rect_less(a: Rect2, b: Rect2) -> bool:
	for pair in [[a.position.x,b.position.x], [a.position.y,b.position.y], [a.size.x,b.size.x], [a.size.y,b.size.y]]:
		if pair[0] != pair[1]: return pair[0] < pair[1]
	return false

static func box_less(a: AABB, b: AABB) -> bool:
	for pair in [[a.position.x,b.position.x], [a.position.y,b.position.y], [a.position.z,b.position.z], [a.size.x,b.size.x], [a.size.y,b.size.y], [a.size.z,b.size.z]]:
		if pair[0] != pair[1]: return pair[0] < pair[1]
	return false

static func subtract(rows: Array, cut: Rect2) -> Dictionary:
	var out: Array = []
	for r: Rect2 in rows:
		if not r.intersects(cut):
			out.append(r)
		else:
			var i = r.intersection(cut)
			for piece in [Rect2(r.position, Vector2(i.position.x-r.position.x,r.size.y)),
				Rect2(Vector2(i.end.x,r.position.y),Vector2(r.end.x-i.end.x,r.size.y)),
				Rect2(Vector2(i.position.x,r.position.y),Vector2(i.size.x,i.position.y-r.position.y)),
				Rect2(Vector2(i.position.x,i.end.y),Vector2(i.size.x,r.end.y-i.end.y))]:
				if piece.size.x > 0.000001 and piece.size.y > 0.000001: out.append(piece)
		if out.size() > MAX_FRAGMENTS: return fail("fragment_limit")
	return {"ready": true, "pieces": out}

static func prepare(source, retired_records: Array, target_ids: Array, voids: Array) -> Dictionary:
	if source == null or source.parts.size() > MAX_PARTS or retired_records.size() > 1024 or target_ids.size() > 512 or voids.size() > 4096: return fail("input_limit")
	var seen = {}
	for p in source.parts:
		if p == null or p.id.is_empty() or seen.has(p.id) or not source.has_finite_positive_bounds(p): return fail("invalid_source_part")
		seen[p.id] = true
	var target_seen = {}
	for id in target_ids:
		if not id is String or id.is_empty() or target_seen.has(id) or not seen.has(id): return fail("invalid_target_id")
		target_seen[id] = true
	var protected_boxes: Array = []
	for box in voids:
		if not box is AABB or not valid_box(box): return fail("invalid_protected_volume")
		protected_boxes.append(box)
	protected_boxes.sort_custom(box_less)
	var retired: Array = []
	var retired_seen = {}
	for record in retired_records:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or seen.has(record.id) or retired_seen.has(record.id): return fail("invalid_retired_id")
		if not record.get("position") is Vector3 or not record.get("rotation") is Vector3 or not record.get("size") is Vector3 or not record.get("recipe", {}) is Dictionary: return fail("invalid_retired_geometry")
		var p = Part.new(record)
		# Constructor normalization is not permission to enlarge an old solid.
		if p.id != record.id or p.size != record.size or not axis_box(source,p) or not source.is_grounded_structural_root(p): return fail("unsupported_retired_root")
		retired_seen[p.id] = true
		retired.append(p)
	retired.sort_custom(func(a,b): return a.id < b.id)
	var original: Dictionary = source.snapshot()
	var b = Copy.copy_blueprint(original)
	Copy.clear_caches(b)
	var initial_work = Copy.validation_grid_work(b)
	if not initial_work.ready: return fail("initial_validation_work_limit")
	var before: Dictionary = b.validate_physical_integrity()
	var checks = {}
	for c in before.checks: checks[c.partId] = c
	var ids = target_ids.duplicate()
	ids.sort()
	var emitted: Array = []
	var allocations: Array = []
	var selected: Array = []
	for id in ids:
		var target = b.find_part(id)
		if target == null or not axis_box(b,target) or target.rotation != Vector3.ZERO or not target.collision_enabled or target.kind != "foundation": return fail("unsupported_retained_surface")
		if checks.get(id,{}).get("passed",false): continue
		var box: AABB = b.transformed_part_bounds(target)
		var top = box.position.y
		var occupied: Array = []
		for current in b.parts:
			if not b.is_grounded_structural_root(current) or not axis_box(b,current): continue
			var bounds: AABB = b.transformed_part_bounds(current)
			if bounds.position.y <= top and bounds.end.y >= top: occupied.append(rect(bounds))
		occupied.sort_custom(rect_less)
		var part_index = 0
		for old in retired:
			var old_box: AABB = b.transformed_part_bounds(old)
			if old_box.position.y >= top or old_box.end.y < top: continue
			var intersection = rect(box).intersection(rect(old_box))
			if intersection.size.x <= 0.000001 or intersection.size.y <= 0.000001: continue
			var pieces: Array = [intersection]
			var cuts = occupied.duplicate()
			for allocated in allocations:
				if allocated.bottom == old_box.position.y and allocated.top == top: cuts.append(allocated.footprint)
			for protected: AABB in protected_boxes:
				# Conservative empty clearance compensates center/size float roundtrip;
				# the constructed solid must still strictly avoid the original volume.
				if protected.position.y < top and protected.end.y > old_box.position.y: cuts.append(rect(protected).grow(EPS))
			cuts.sort_custom(rect_less)
			for cut: Rect2 in cuts:
				var difference = subtract(pieces,cut)
				if not difference.ready: return difference
				pieces = difference.pieces
			if pieces.size()+emitted.size() > MAX_FRAGMENTS: return fail("fragment_limit")
			pieces.sort_custom(rect_less)
			for footprint: Rect2 in pieces:
				var proposed = AABB(Vector3(footprint.position.x,old_box.position.y,footprint.position.y),Vector3(footprint.size.x,top-old_box.position.y,footprint.size.y))
				# Reserve a tiny empty horizontal margin INSIDE the candidate fragment.
				# This is less retained stone, never permission to expand an old solid.
				var represented_size = proposed.size - Vector3(EPS*2.0,0,EPS*2.0)
				var bearing_id = String(id) + "_retained_bearing_%03d" % part_index
				if seen.has(bearing_id): return fail("bearing_id_collision")
				var p = Part.new({"id":bearing_id,"kind":"foundation","material":old.material_id,
					"position":proposed.get_center(),"size":represented_size,"collision":true,"semantic":"retained_surface_bearing",
					"recipe":{"retiredSourceId":old.id,"retainedSurfaceId":id}})
				# Tiny fragments fail closed rather than growing to BuildingPart's minimum.
				if p.size != represented_size: return fail("unrepresentable_retired_fragment")
				var actual: AABB = b.transformed_part_bounds(p)
				# Center/size float encoding can round a boundary outward. Reduce only
				# the affected new solid's axis, never relax the containment proof.
				var adjusted = false
				for axis in range(3):
					var low = float(old_box.position[axis])
					var high = float(old_box.end[axis])
					if axis != 1:
						low = maxf(low,float(target.position[axis])-float(target.size[axis])*0.5)
						high = minf(high,float(target.position[axis])+float(target.size[axis])*0.5)
					else: high = minf(high,float(target.position.y)-float(target.size.y)*0.5)
					if actual.position[axis] < low or actual.end[axis] > high or float(p.position[axis])-float(p.size[axis])*0.5 < low or float(p.position[axis])+float(p.size[axis])*0.5 > high:
						p.size[axis] -= EPS*2.0
						adjusted = true
				if adjusted:
					var normalized = Part.new(p.snapshot())
					if normalized.size != p.size: return fail("unrepresentable_retired_fragment")
					p = normalized
					actual = b.transformed_part_bounds(p)
				if not solid_containment(p,old,target) or not old_box.encloses(actual) or not rect(box).encloses(rect(actual)) or actual.end.y > top: return fail("retired_volume_containment_failed")
				for protected: AABB in protected_boxes:
					if actual.intersects(protected): return fail("constructed_volume_enters_reservation")
				b.add_part(p.snapshot())
				seen[bearing_id] = true
				emitted.append({"part":p.snapshot(),"sourceId":old.id,"sourceBox":old_box,"surfaceId":id,"surfaceBox":box})
				# Keep the complete allocated cut occupied: do not fill rounding margins
				# again from another overlapping retired root as unrepresentable slivers.
				occupied.append(footprint)
				allocations.append({"footprint":footprint,"bottom":old_box.position.y,"top":top})
				part_index += 1
		# An earlier target may already have emitted the same required bearing.
		# Only the final ordinary proof may decide whether this target is repaired.
		selected.append(id)
	if emitted.is_empty():
		if not selected.is_empty(): return fail("no_retired_bearing_volume")
		return {"ready":true,"unchanged":true,"afterSnapshot":original,"emitted":[]}
	Copy.clear_caches(b)
	var final_work = Copy.validation_grid_work(b)
	if not final_work.ready: return fail("final_validation_work_limit")
	var after: Dictionary = b.validate_physical_integrity()
	for c in after.checks:
		if (selected.has(c.partId) or checks.get(c.partId,{}).get("passed",false) or not checks.has(c.partId)) and not c.passed: return fail("retirement_support_or_preservation_failed:"+String(c.partId))
	var output = original.duplicate(true)
	for record in emitted: output.parts.append(record.part)
	return {"ready":true,"unchanged":false,"afterSnapshot":output,"emitted":emitted,"selectedIds":selected,"beforeChecks":before.checks.filter(func(c):return selected.has(c.partId)),"afterChecks":after.checks.filter(func(c):return selected.has(c.partId))}
