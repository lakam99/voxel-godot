extends RefCounted

## Pure source proposal: two real opposing building faces, never incidental
## middle contact or invented posts. No commit, publication or gameplay claim.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const SupportMemo = preload("res://scripts/buildings/BuildingSupportResolutionMemo.gd")
const MAX_PARTS := 10000
const MAX_ASSEMBLIES := 16
const MAX_PENNANTS := 128
const MAX_PROTECTED := 4096
const MAX_FACES := 128
const MAX_PAIRS := 4096
const MAX_COMPARISONS := 1000000
const SOCKET_INSET := Blueprint.STAIR_HOUSED_JOINT_INSET + 0.001

class Run:
	var continuation: Callable
	var _support_identities: Variant = null
	var _support_observations: Dictionary = {}
	var cancelled := false
	var comparisons := 0
	var pairs := 0
	func step(stage: String) -> bool:
		if cancelled: return false
		cancelled = continuation.is_valid() and continuation.call(stage) != true
		if cancelled and _support_identities != null: _support_identities.clear()
		return not cancelled

## assemblies: [{ropeId:String, pennantIds:Array[String]}], producer supplied.
## protected_volumes: AABB or {bounds:AABB}. No implicit widening/domain policy.
## ready result changes is an ordered Array of complete replacement snapshots;
## sourceBytes binds the unmodified caller snapshot, for the caller's commit.
static func prepare(source, assemblies: Array, protected_volumes: Array, continuation: Callable = Callable()) -> Dictionary:
	return _prepare_internal(source,assemblies,protected_volumes,continuation,null)

## Only the owning completion transaction supplies this store. Public proposals
## stay fresh, and no store or proof object escapes in the returned proposal.
static func _prepare_with_support_memo(source, assemblies: Array, protected_volumes: Array, continuation: Callable, identities: Dictionary) -> Dictionary:
	var result := _prepare_internal(source,assemblies,protected_volumes,continuation,identities)
	if not result.get("ready",false): identities.clear()
	return result

static func _prepare_internal(source, assemblies: Array, protected_volumes: Array, continuation: Callable, identities: Variant) -> Dictionary:
	if not _valid_source(source) or assemblies.size() > MAX_ASSEMBLIES or protected_volumes.size() > MAX_PROTECTED:
		return _fail("invalid_bunting_source")
	var snapshot: Dictionary = source.snapshot()
	var source_bytes: PackedByteArray = var_to_bytes(snapshot)
	var input_bytes: PackedByteArray = var_to_bytes([assemblies,protected_volumes])
	var private_assemblies: Array = assemblies.duplicate(true)
	var private_protected: Array = protected_volumes.duplicate(true)
	var run := Run.new()
	run.continuation = continuation
	run._support_identities = identities
	var result: Dictionary = _prepare(snapshot,private_assemblies,private_protected,run)
	if run.cancelled: return _fail("cancelled")
	if not _valid_source(source) or source_bytes != var_to_bytes(source.snapshot()) or input_bytes != var_to_bytes([assemblies,protected_volumes]):
		return _fail("bunting_source_changed")
	if result.get("ready",false): result["sourceBytes"] = source_bytes
	return result

## Read-only terminal check against an already physically validated source.
## It certifies the STORED placement; it never searches or relocates again.
static func verify_stored(source, assemblies: Array, protected: Array, continuation: Callable = Callable()) -> Dictionary:
	if not _valid_source(source) or assemblies.size()>MAX_ASSEMBLIES or protected.size()>MAX_PROTECTED: return _fail("invalid_bunting_source")
	var frozen := var_to_bytes(source.snapshot())
	var inputs := var_to_bytes([assemblies,protected])
	var original: Dictionary = {}
	for record: Dictionary in source.snapshot().parts: original[record.id]=record
	var normalized := _protected_volumes(protected)
	if not normalized.ready: return normalized
	var volumes: Array[AABB] = normalized.volumes
	var run := Run.new(); run.continuation=continuation
	for assembly: Dictionary in assemblies:
		if not run.step("bunting_verify_stored"): return _fail("cancelled")
		if not original.has(assembly.ropeId): return _fail("missing_stored_bunting_rope")
		var record: Dictionary = original[assembly.ropeId]
		var ids: Variant = record.recipe.get("physicalRequiredAnchorPartIds")
		if not ids is Array or ids.size()!=2 or ids[0]==ids[1]: return _fail("invalid_stored_bunting_anchors")
		var a=source.find_part(ids[0]); var b=source.find_part(ids[1])
		if a==null or b==null or not source.has_rooted_support_chain(a,{}) or not source.has_rooted_support_chain(b,{}): return _fail("unrooted_stored_bunting_anchor")
		if assembly.has("placementDomain"):
			if not _valid_domain(assembly.placementDomain,original) or ids[0] not in assembly.placementDomain.leftAnchorIds or ids[1] not in assembly.placementDomain.rightAnchorIds:
				return _fail("foreign_stored_bunting_anchor")
		var half := Vector3(minf(record.size.y,record.size.z),record.size.y,record.size.z)*0.25
		var candidate := {"a":{"part":a},"b":{"part":b},"existing":true}
		var checked: Dictionary = _candidate(source,original,assembly,candidate,half,volumes,run)
		if not checked.get("ready",false): return checked
		if not checked.changes.is_empty(): return _fail("stored_bunting_requires_change")
	if not run.step("bunting_verify_completed"): return _fail("cancelled")
	if frozen != var_to_bytes(source.snapshot()) or inputs != var_to_bytes([assemblies,protected]): return _fail("bunting_source_changed")
	return {"ready":true,"checkedAssemblies":assemblies.size(),"physicalValidations":0,"comparisons":run.comparisons}

static func _prepare(snapshot: Dictionary, assemblies: Array, protected: Array, run: Run) -> Dictionary:
	if not run.step("bunting_started"): return _fail("cancelled")
	var original: Dictionary = {}
	for record: Dictionary in snapshot.parts: original[record.id] = record
	var owned: Dictionary = {}
	for value: Variant in assemblies:
		if not value is Dictionary or not value.get("ropeId") is String or not value.get("pennantIds") is Array:
			return _fail("invalid_bunting_assembly")
		if value.has("placementBounds"): return _fail("unsupported_bunting_placement_domain")
		if value.has("placementDomain") and not _valid_domain(value.placementDomain,original):
			return _fail("invalid_bunting_placement_domain")
		if value.pennantIds.is_empty() or value.pennantIds.size() > MAX_PENNANTS: return _fail("invalid_bunting_pennants")
		var ids: Array = [value.ropeId]
		ids.append_array(value.pennantIds)
		for id: Variant in ids:
			if not id is String or id.is_empty() or owned.has(id) or not original.has(id): return _fail("invalid_bunting_membership")
			owned[id] = true
		var rope: Dictionary = original[value.ropeId]
		if rope.kind != "beam" or rope.semantic != "citadel_bunting_rope" or rope.collision or rope.rotation != Vector3.ZERO:
			return _fail("invalid_bunting_rope")
		for id: String in value.pennantIds:
			var pennant: Dictionary = original[id]
			if pennant.kind != "pennant" or pennant.semantic != "citadel_bunting" or pennant.collision:
				return _fail("invalid_bunting_pennant")
			var ratio: float = (pennant.position.x-rope.position.x)/rope.size.x+0.5
			if ratio <= 0.0 or ratio >= 1.0: return _fail("pennant_outside_original_span")
	var normalized := _protected_volumes(protected)
	if not normalized.ready: return normalized
	var volumes: Array[AABB] = normalized.volumes
	# All declared dressing is absent from the independent root proof. Its
	# metadata therefore cannot establish either mounting building's rootedness.
	var proof = Copy.copy_blueprint(snapshot)
	proof.parts = proof.parts.filter(func(part) -> bool: return not owned.has(part.id))
	if run._support_identities != null:
		var memo := SupportMemo.new(proof.id,proof.seed,proof.style)
		memo.recipe=proof.recipe; memo.rooms=proof.rooms; memo.parts=proof.parts
		memo.identities=run._support_identities
		proof=memo
	Copy.clear_caches(proof)
	var grid: Dictionary = Copy.validation_grid_work(proof)
	if not grid.get("ready",false): return _fail("bunting_proof_grid_limit",grid)
	if not run.step("bunting_proof_started"): return _fail("cancelled")
	var report: Dictionary = proof.validate_physical_integrity_cancellable(run.step)
	if run._support_identities != null:
		run._support_observations=proof.observations.duplicate(true)
		proof.identities={}
	if report.get("cancelled",false) or not run.step("bunting_proof_completed"): return _fail("cancelled")
	var passed: Dictionary = {}
	for check: Dictionary in report.get("checks",[]):
		if check.get("passed",false): passed[check.partId] = true
	var changes: Array[Dictionary] = []
	var facts: Array[Dictionary] = []
	for assembly: Dictionary in assemblies:
		if not run.step("bunting_assembly"): return _fail("cancelled")
		var planned: Dictionary = _line(proof,original,assembly,passed,volumes,run)
		if not planned.get("ready",false):
			if run.cancelled: return _fail("cancelled")
			return _fail(String(planned.reason),{"ropeId":assembly.ropeId,"detail":planned.get("detail",{}),"pairs":run.pairs,"comparisons":run.comparisons})
		changes.append_array(planned.changes)
		facts.append(planned.endpoints)
		# Later proposals must clear the complete earlier accepted assembly,
		# including members whose records did not need changing.
		var staged: Dictionary = {}
		for record: Dictionary in planned.changes: staged[record.id] = record
		var member_ids: Array = [assembly.ropeId]
		member_ids.append_array(assembly.pennantIds)
		for id: String in member_ids: proof.parts.append(_part(staged.get(id,original[id])))
	if not run.step("bunting_completed"): return _fail("cancelled")
	return {"ready":true,"changes":changes,"endpointFacts":facts,"unchanged":changes.is_empty(),
		"physicalValidations":1,"candidatePairs":run.pairs,"comparisons":run.comparisons,
		"scope":"Two independently rooted endpoint sockets and bounded source-box clearance; unrelated source failures are not waived or claimed resolved."}

static func _line(proof, original: Dictionary, assembly: Dictionary, passed: Dictionary, volumes: Array[AABB], run: Run) -> Dictionary:
	var rope: Dictionary = original[assembly.ropeId]
	var domain: Dictionary = assembly.get("placementDomain",{})
	var half := Vector3(minf(rope.size.y,rope.size.z),rope.size.y,rope.size.z)*0.25
	var embed: float = half.x*2.0+SOCKET_INSET
	var low: float = rope.position.x-rope.size.x*0.5
	var high: float = rope.position.x+rope.size.x*0.5
	var left: Array = []
	var right: Array = []
	for part in proof.parts:
		if not run.step("bunting_face"): return _fail("cancelled")
		if not passed.has(part.id) or not part.collision_enabled or part.kind not in ["wall","foundation"] or part.rotation != Vector3.ZERO:
			continue
		if part.physical_intent not in ["structural_mass","structural_root"] or not proof.has_rooted_support_chain(part,{}): continue
		var bounds: AABB = proof.transformed_part_bounds(part)
		if domain.is_empty():
			if rope.position.y-half.y <= bounds.position.y+SOCKET_INSET or rope.position.y+half.y >= bounds.end.y-SOCKET_INSET or rope.position.z-half.z <= bounds.position.z+SOCKET_INSET or rope.position.z+half.z >= bounds.end.z-SOCKET_INSET:
				continue
			if bounds.end.x < rope.position.x and bounds.end.x >= low: left.append({"part":part,"face":bounds.end.x,"bounds":bounds})
			if bounds.position.x > rope.position.x and bounds.position.x <= high: right.append({"part":part,"face":bounds.position.x,"bounds":bounds})
		else:
			if part.id in domain.leftAnchorIds: left.append({"part":part,"face":bounds.end.x,"bounds":bounds})
			if part.id in domain.rightAnchorIds: right.append({"part":part,"face":bounds.position.x,"bounds":bounds})
	if left.size() > MAX_FACES or right.size() > MAX_FACES or left.size()*right.size() > MAX_PAIRS:
		return _fail("bunting_candidate_limit")
	var candidates: Array[Dictionary] = []
	for a: Dictionary in left:
		for b: Dictionary in right:
			if not domain.is_empty():
				candidates.append({"a":a,"b":b,"low":low,"high":high,"cost":-1.0,"existing":true})
				candidates.append_array(_domain_candidates(a,b,rope,half,embed,domain.bounds))
				continue
			# Try the represented original span first when its sockets already
			# fit; this preserves an existing valid assembly without round trips.
			candidates.append({"a":a,"b":b,"low":low,"high":high,"cost":0.0,"existing":true})
			var start: float = float(a.face)-embed
			var finish: float = float(b.face)+embed
			if start < low or finish > high or start >= finish: continue
			candidates.append({"a":a,"b":b,"low":start,"high":finish,"cost":absf(start-low)+absf(finish-high),"existing":false})
	if candidates.size() > MAX_PAIRS: return _fail("bunting_candidate_limit")
	candidates.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:
		if a.cost != b.cost: return a.cost < b.cost
		if a.a.part.id != b.a.part.id: return a.a.part.id < b.a.part.id
		if a.b.part.id != b.b.part.id: return a.b.part.id < b.b.part.id
		if a.get("y",rope.position.y) != b.get("y",rope.position.y): return a.get("y",rope.position.y) < b.get("y",rope.position.y)
		if a.get("z",rope.position.z) != b.get("z",rope.position.z): return a.get("z",rope.position.z) < b.get("z",rope.position.z)
		return a.existing and not b.existing)
	var rejection_counts: Dictionary = {}
	for candidate: Dictionary in candidates:
		if not run.step("bunting_candidate"): return _fail("cancelled")
		run.pairs += 1
		if run.pairs > MAX_PAIRS: return _fail("bunting_candidate_limit")
		var result: Dictionary = _candidate(proof,original,assembly,candidate,half,volumes,run)
		if result.get("ready",false): return result
		if run.cancelled or result.reason == "bunting_work_limit": return result
		rejection_counts[result.reason] = int(rejection_counts.get(result.reason,0))+1
	var reason := "no_rooted_bunting_endpoint_pair" if candidates.is_empty() else "bunting_tested_placements_rejected"
	return _fail(reason,{"leftFaces":left.size(),"rightFaces":right.size(),"testedCandidates":candidates.size(),"rejections":rejection_counts,
		"scope":"Bounded tested placements only; rejection is not a geometric infeasibility proof."})

static func _candidate(proof, original: Dictionary, assembly: Dictionary, candidate: Dictionary, half: Vector3, volumes: Array[AABB], run: Run) -> Dictionary:
	var old: Dictionary = original[assembly.ropeId]
	var record: Dictionary = old.duplicate(true)
	if not candidate.existing:
		record.position.x = (float(candidate.low)+float(candidate.high))*0.5
		record.position.y = candidate.get("y",old.position.y)
		record.position.z = candidate.get("z",old.position.z)
		record.size.x = float(candidate.high)-float(candidate.low)
	var rope = _part(record)
	var facts: Array[Dictionary] = []
	for index: int in range(2):
		var anchor = candidate.a.part if index == 0 else candidate.b.part
		var local_x: float = -rope.size.x*0.5+half.x if index == 0 else rope.size.x*0.5-half.x
		var fact := {"anchorId":anchor.id,"contactMode":"attachment_socket","localMountCenter":Vector3(local_x,0,0),"localMountHalfExtents":half}
		# The shared socket API proves its eight corners inside rooted masonry;
		# separately constrain those corners to the actual thin rope volume.
		if absf(local_x)+half.x > rope.size.x*0.5 or half.y > rope.size.y*0.5 or half.z > rope.size.z*0.5 or not proof.has_rooted_attachment_socket(rope,fact):
			return _fail("bunting_socket_not_housed")
		facts.append(fact)
	record.physicalIntent = "facade_attachment"
	record.recipe["physicalIntent"] = "facade_attachment"
	record.recipe["physicalRequiredAnchorPartIds"] = [candidate.a.part.id,candidate.b.part.id]
	record.recipe["physicalRequiredAnchorFacts"] = facts
	var records: Array[Dictionary] = [record]
	for id: String in assembly.pennantIds:
		var pennant: Dictionary = original[id].duplicate(true)
		if not candidate.existing:
			var ratio: float = (pennant.position.x-old.position.x)/old.size.x
			pennant.position.x = record.position.x+ratio*record.size.x
			pennant.position.y += record.position.y-old.position.y
			pennant.position.z += record.position.z-old.position.z
		# Size, relative Y/Z and sag, rotations, material and count stay exact.
		# A shortened span must fit the unchanged pennants, never shrink them.
		records.append(pennant)
	for first: int in range(1,records.size()):
		for second: int in range(first+1,records.size()):
			var spacing: Dictionary = _clear(_part(records[first]),_pose(_part(records[second])),run)
			if not spacing.ready:
				if run.cancelled or spacing.reason == "bunting_work_limit": return spacing
				return _fail("bunting_pennants_overlap")
	for index: int in range(records.size()):
		var member = _part(records[index])
		if assembly.has("placementDomain"):
			if not _inside_domain(member,assembly.placementDomain.bounds,half.x*2.0+SOCKET_INSET,index==0):
				return _fail("bunting_outside_placement_domain")
		for obstacle in proof.parts:
			if obstacle.id == assembly.ropeId or obstacle.id in assembly.pennantIds: continue
			# Roof dressing remains visible solid geometry even when it is not a
			# gameplay collider. Never put a relocated rope through that roof.
			if not obstacle.collision_enabled and obstacle.physical_intent != "roof_attachment" and not obstacle.kind.begins_with("roof") and obstacle.semantic not in ["citadel_bunting_rope","citadel_bunting"]: continue
			if index == 0 and obstacle.id in [candidate.a.part.id,candidate.b.part.id]:
				# Only rope end caps can meet these axis-aligned opposing faces:
				# their whole solids lie outside the open interval between faces.
				# Socket proof above certifies each cap; pennants get NO exemption.
				continue
			var clear: Dictionary = _clear(member,_pose(obstacle),run)
			if not clear.ready: return clear
		for volume: AABB in volumes:
			var clear: Dictionary = _clear(member,Transform3D(Basis.from_scale(volume.size),volume.get_center()),run)
			if not clear.ready: return clear
	var changes: Array[Dictionary] = []
	for value: Dictionary in records:
		if var_to_bytes(value) != var_to_bytes(original[value.id]): changes.append(value)
	return {"ready":true,"changes":changes,"endpoints":{"ropeId":assembly.ropeId,
		"anchorIds":[candidate.a.part.id,candidate.b.part.id],"facts":facts,
		"start":Vector3(rope.position.x-rope.size.x*0.5,rope.position.y,rope.position.z),
		"end":Vector3(rope.position.x+rope.size.x*0.5,rope.position.y,rope.position.z),"preservedGeometry":candidate.existing}}

static func _clear(member, obstacle: Transform3D, run: Run) -> Dictionary:
	if not run.step("bunting_clearance"): return _fail("cancelled")
	run.comparisons += 1
	if run.comparisons > MAX_COMPARISONS: return _fail("bunting_work_limit")
	var measured: Dictionary = Admission.measure(_pose(member),obstacle)
	return {"ready":true} if measured.get("valid",false) and measured.get("clear",false) else _fail("bunting_span_blocked")

## The producer bounds placement to the actual market and explicitly owns both
## opposing faces. Face intersections generate finite candidates, not a spatial
## search grid. The entire assembly still has to fit the envelope and clear.
static func _domain_candidates(a: Dictionary, b: Dictionary, rope: Dictionary, half: Vector3, embed: float, bounds: AABB) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# Construct strictly between the shared minimum socket inset and the
	# declared cap maximum, so represented floats need no tolerance waiver.
	var constructed_embed: float = embed-(SOCKET_INSET-Blueprint.STAIR_HOUSED_JOINT_INSET)*0.5
	var low: float = a.face-constructed_embed
	var high: float = b.face+constructed_embed
	if a.face >= b.face or a.face < bounds.position.x or b.face > bounds.end.x: return result
	# Keep the candidate strictly inside socket limits after float conversion.
	var margin := Vector3(0,half.y+SOCKET_INSET*2.0,half.z+SOCKET_INSET*2.0)
	var start: Vector3 = a.bounds.position.max(b.bounds.position).max(bounds.position)+margin
	var end: Vector3 = a.bounds.end.min(b.bounds.end).min(bounds.end)-margin
	if start.y >= end.y or start.z >= end.z: return result
	var ys: Array[float] = [clampf(rope.position.y,start.y,end.y),(start.y+end.y)*0.5]
	var zs: Array[float] = [clampf(rope.position.z,start.z,end.z),(start.z+end.z)*0.5]
	var seen: Dictionary = {}
	for y: float in ys:
		for z: float in zs:
			var key := Vector2(y,z)
			if seen.has(key): continue
			seen[key] = true
			var center := Vector3((low+high)*0.5,y,z)
			result.append({"a":a,"b":b,"low":low,"high":high,"y":y,"z":z,
				"cost":center.distance_squared_to(rope.position)+pow(high-low-rope.size.x,2),"existing":false})
	return result

static func _inside_domain(member, bounds: AABB, cap_limit: float, is_rope: bool) -> bool:
	# Compare represented endpoints to explicit scalar limits. Do not expand an
	# AABB with separately rounded position/size and accidentally widen a cap.
	var pose := _pose(member)
	for x: float in [-0.5,0.5]:
		for y: float in [-0.5,0.5]:
			for z: float in [-0.5,0.5]:
				var point: Vector3 = pose*Vector3(x,y,z)
				var cap: float = cap_limit if is_rope else 0.0
				if point.x < float(bounds.position.x)-cap or point.x > float(bounds.end.x)+cap: return false
				if point.y < bounds.position.y or point.y > bounds.end.y or point.z < bounds.position.z or point.z > bounds.end.z: return false
	return true

static func _valid_domain(value: Variant, original: Dictionary) -> bool:
	if not value is Dictionary or value.size() != 3 or not value.get("bounds") is AABB or not _valid_bounds(value.bounds): return false
	var ids: Dictionary = {}
	for key: String in ["leftAnchorIds","rightAnchorIds"]:
		if not value.get(key) is Array or value[key].is_empty() or value[key].size() > MAX_FACES: return false
		for id: Variant in value[key]:
			if not id is String or not original.has(id) or ids.has(id): return false
			ids[id] = true
	return true

static func _part(record: Dictionary):
	var part = Part.new(record)
	# Preserve represented thin geometry, not constructor minimum-size policy.
	part.size = record.size
	return part

static func _pose(part) -> Transform3D:
	return Transform3D(Basis.from_euler(part.rotation)*Basis.from_scale(part.size),part.position)

static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() and bounds.end.is_finite() and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

static func _protected_volumes(values: Array) -> Dictionary:
	var volumes: Array[AABB] = []
	for value: Variant in values:
		# Ordinary door sweeps carry name/moving fields alongside their exact
		# envelope. Preparation and terminal verification use the SAME contract.
		var bounds: Variant = value.get("bounds") if value is Dictionary else value
		if not bounds is AABB or not _valid_bounds(bounds): return _fail("invalid_bunting_protected_volume")
		volumes.append(bounds)
	return {"ready":true,"volumes":volumes}

static func _valid_source(source) -> bool:
	if not source is Blueprint or source.parts.size() > MAX_PARTS: return false
	var ids: Dictionary = {}
	for part in source.parts:
		if not part is Part or part.id.is_empty() or ids.has(part.id) or not source.has_finite_positive_bounds(part): return false
		ids[part.id] = true
	return true

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	return {"ready":false,"reason":reason} if detail.is_empty() else {"ready":false,"reason":reason,"detail":detail}
