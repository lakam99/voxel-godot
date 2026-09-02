extends RefCounted

## Read-only review planning from the already generated recipe and seat graph.
## It adds no parts, offsets, supports, materials or success metadata to source.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const Furniture = preload("res://scripts/buildings/FurnishingPlan.gd")
const DependencyMap = preload("res://scripts/testing/buildings/CitadelFacadeVisualDependencyMap.gd")
const ROOT := "res://artifacts/citadel-visual-reset/"
const INPUTS := {
	"candidate": ["facade-whole-candidate-09/facade-candidate.bin", "36ed79a46e014afd35c78fdf54cbbbb88730241165bd72c3c9491c8c7eb4d004"],
	"aggregate": ["facade-combined-comparison-v2-aggregate/report.json", "bd751591532358550435ed3a3fa99f110cff4b9a5c11876c976474af1a99beda"],
	"contacts": ["facade-combined-contact-reader-01/report.json", "311e748b747bc43e5c659ddeac680f24d653c4382d6164d8127d2d5f5b3d2568"],
	"dependencies": ["facade-capture-dependencies-01/report.json", "cf54ce26122b9395a63d5c5ec618e984a5363b350a9e7d168e84ca8698b0fb2e"],
	"capture": ["facade-combined-cpu-standard-01/report.json", "3d2784e1b424e5b5bac0235fe253c259f7b11cacf52871aa7482529e2a49ec3f"]}
const MAX_INPUT := 32 * 1024 * 1024
const MAX_NEW := 32

static func digest(value: Variant) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()

static func read_input(key: String) -> Dictionary:
	if not INPUTS.has(key): return {}
	var path: String = ROOT + INPUTS[key][0]
	if FileAccess.get_sha256(path) != INPUTS[key][1]: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var count := file.get_length()
	if count <= 0 or count > MAX_INPUT:
		file.close()
		return {}
	var bytes := file.get_buffer(count)
	var complete := bytes.size() == count and file.get_error() == OK
	file.close()
	var value: Variant = bytes_to_var(bytes) if key == "candidate" else JSON.parse_string(bytes.get_string_from_utf8())
	if not complete or not value is Dictionary or FileAccess.get_sha256(path) != INPUTS[key][1]: return {}
	if key == "candidate" and var_to_bytes(value) != bytes: return {}
	return value

static func inputs_current(identity: Dictionary) -> bool:
	if identity.is_empty() or identity.size() > 512: return false
	for key in INPUTS:
		if FileAccess.get_sha256(ROOT + INPUTS[key][0]) != INPUTS[key][1]: return false
	for path in identity:
		if not path is String or not path.begins_with("res://scripts/") or not identity[path] is String: return false
		var actual := FileAccess.get_sha256(path)
		if actual != identity[path] and not DependencyMap.accepts(path, identity[path], actual): return false
	return true

static func load_review() -> Dictionary:
	var source := read_input("candidate")
	var aggregate := read_input("aggregate")
	var contacts := read_input("contacts")
	var dependencies := read_input("dependencies")
	var capture := read_input("capture")
	if source.is_empty() or aggregate.is_empty() or contacts.is_empty() or dependencies.is_empty() or capture.is_empty(): return _fail("bound_input")
	var identity: Dictionary = dependencies.get("identities", {}).get("new_standard", {})
	if not inputs_current(identity): return _fail("current_publication_dependency")
	if aggregate.get("status") != "comparison_aggregate_complete_review_pending" or aggregate.get("requestedStageCompleted") != true or aggregate.get("requiredJobCount") != 38 or aggregate.get("pairCount") != 284736: return _fail("aggregate_scope")
	if contacts.get("rawContactRowCount") != 92 or contacts.get("pairCount") != 284736 or contacts.get("classificationUnchanged") != true or contacts.get("candidateSource", {}).get("sha256") != INPUTS.candidate[1]: return _fail("contact_scope")
	if capture.get("requestedStageCompleted") != true or capture.get("inputSha256") != INPUTS.candidate[1] or capture.get("cycle", {}).get("complete") != true: return _fail("capture_scope")
	if source.get("provenance") != "successful_full_facade_recipe_contract" or source.get("mainShardPassed") != true or source.get("partIds", []).size() != 16 or source.get("memberIds", []).size() != 5 or source.get("furnitureSnapshot", {}).get("parts", []).size() != 152: return _fail("candidate_scope")
	var before: String = digest(source)
	var plan := build_groups(source.afterSnapshot, source.partIds, source.memberIds)
	if not plan.ready or plan.groups.size() != 4 or plan.footCount != 5: return _fail("group_coverage:" + String(plan.get("reason", "")))
	var b = Copy.copy_blueprint(source.afterSnapshot)
	if var_to_bytes(b.snapshot()) != var_to_bytes(source.afterSnapshot): return _fail("blueprint_copy")
	var snapshot: Dictionary = source.furnitureSnapshot
	var furniture = Furniture.new(snapshot.id, int(snapshot.seed), snapshot.sourceBlueprintId)
	furniture.egress_diagnostics = snapshot.egressDiagnostics.duplicate(true)
	# Preserve exact existing access policy order; this is not generation or a
	# placement exemption. Every copied part still goes through add_part checks.
	for reservation in source.protectedReservations: furniture.protected_access_reservations.append(reservation)
	for record in snapshot.parts:
		if furniture.add_part(record) == null: return _fail("furniture_access_copy")
	if var_to_bytes(furniture.snapshot()) != var_to_bytes(snapshot) or var_to_bytes(furniture.protected_access_reservations) != var_to_bytes(source.protectedReservations): return _fail("furniture_copy")
	if digest(source) != before or not inputs_current(identity): return _fail("inputs_mutated")
	return {"ready": true, "blueprint": b, "furniture": furniture, "groups": plan.groups, "footCount": plan.footCount,
		"fixture": source.fixture, "identity": identity, "bindings": INPUTS, "dependencyMapping": DependencyMap.proof(), "sourceDigest": digest(source.afterSnapshot),
		"expectedPublishedSourceDigest": capture.cycle.postValidationDigest,
		"furnitureDigest": digest([snapshot, source.protectedReservations]), "newPartIds": source.partIds.duplicate(), "servedPartIds": source.memberIds.duplicate()}

static func build_groups(snapshot: Dictionary, new_ids: Array, served_ids: Array) -> Dictionary:
	if not snapshot.get("parts") is Array or snapshot.parts.size() > 10000 or new_ids.is_empty() or new_ids.size() > MAX_NEW or served_ids.is_empty() or served_ids.size() > MAX_NEW: return _fail("collection_limit")
	var records: Dictionary = {}
	for record in snapshot.parts:
		if not record is Dictionary or not record.get("id") is String or records.has(record.id) or not record.get("recipe") is Dictionary: return _fail("source_schema")
		for key in ["physicalRequiredSeatPartIds", "physicalRequiredAnchorPartIds"]:
			var declared: Variant = record.recipe.get(key, [])
			if not declared is Array or declared.size() > MAX_NEW: return _fail("reference_schema")
			var seen: Dictionary = {}
			for reference in declared:
				if not reference is String or reference.is_empty() or seen.has(reference): return _fail("reference_schema")
				seen[reference] = true
		var joint: Variant = record.recipe.get("pavingFootingJoints", {})
		if not joint is Dictionary or not joint.get("footPartIds", []) is Array: return _fail("joint_schema")
		records[record.id] = record
	var new_set: Dictionary = {}
	var served_set: Dictionary = {}
	for id in new_ids:
		if not id is String or not records.has(id) or new_set.has(id) or not _finite_bounds(bounds(records[id])): return _fail("new_member_schema")
		new_set[id] = true
	for id in served_ids:
		if not id is String or not records.has(id) or new_set.has(id) or served_set.has(id) or not _finite_bounds(bounds(records[id])): return _fail("served_member_schema")
		served_set[id] = true
	var edges: Dictionary = {}
	for id in new_ids: edges[id] = []
	for id in new_ids:
		for reference in references(records[id]):
			if not records.has(reference): return _fail("unresolved_reference")
			if new_set.has(reference):
				if not edges[id].has(reference): edges[id].append(reference)
				if not edges[reference].has(id): edges[reference].append(id)
	var served_by: Dictionary = {}
	for id in served_ids:
		var supports: Array = records[id].recipe.get("physicalRequiredSeatPartIds", [])
		if supports.any(func(value): return not records.has(value)): return _fail("unresolved_reference")
		var selected: Array = supports.filter(func(value): return new_set.has(value))
		if selected.size() != 1: return _fail("served_panel_requires_one_reviewed_bearer")
		served_by[id] = selected[0]
	var remaining: Array = new_ids.duplicate()
	remaining.sort()
	var groups: Array = []
	var total_feet := 0
	while not remaining.is_empty():
		var group_ids: Array = []
		var pending: Array = [remaining[0]]
		while not pending.is_empty():
			var id: String = pending.pop_back()
			if group_ids.has(id): continue
			group_ids.append(id)
			remaining.erase(id)
			pending.append_array(edges[id])
		group_ids.sort()
		var panels: Array = served_ids.filter(func(id): return group_ids.has(served_by[id]))
		panels.sort()
		if panels.is_empty(): return _fail("unserved_or_orphan_new_member")
		var box: AABB = bounds(records[group_ids[0]])
		for id in group_ids + panels: box = box.merge(bounds(records[id]))
		var feet: Array = []
		for id in group_ids:
			var record: Dictionary = records[id]
			if not Materials.is_masonry_material(String(record.get("material", ""))): continue
			if record.get("kind") not in ["beam", "foundation"] or record.get("collision") != true or record.get("physicalIntent") != "structural_mass": return _fail("invalid_foot_role")
			var supports: Array = record.recipe.get("physicalRequiredSeatPartIds", [])
			if supports.is_empty() or supports.any(func(value): return new_set.has(value) or not records.has(value)): return _fail("invalid_foot_support")
			var finishes: Array = []
			for candidate in snapshot.parts:
				if candidate.recipe.get("pavingFootingJoints", {}).get("footPartIds", []).has(id): finishes.append(candidate.id)
			finishes.sort()
			var foot_box: AABB = bounds(record)
			feet.append({"footId": id, "supportIds": supports.duplicate(), "finishIds": finishes, "bounds": foot_box.grow(foot_box.size.y * 0.75)})
		if feet.is_empty(): return _fail("no_declared_foot")
		total_feet += feet.size()
		groups.append({"id": "frame_%02d" % groups.size(), "partIds": group_ids, "servedIds": panels, "footInterfaces": feet, "bounds": box})
	return {"ready": true, "groups": groups, "footCount": total_feet, "coveredNewCount": new_set.size(), "coveredServedCount": served_set.size()}

static func references(record: Dictionary) -> Array:
	var result: Array = []
	for key in ["physicalRequiredSeatPartIds", "physicalRequiredAnchorPartIds"]:
		for id in record.recipe.get(key, []):
			if not result.has(id): result.append(id)
	return result

static func bounds(record: Dictionary) -> AABB:
	if not record.get("position") is Vector3 or not record.get("size") is Vector3 or not record.get("rotation") is Vector3: return AABB()
	return Transform3D(Basis.from_euler(record.rotation), record.position) * AABB(-record.size * 0.5, record.size)

static func _finite_bounds(box: AABB) -> bool:
	return box.position.is_finite() and box.end.is_finite() and box.size.x > 0 and box.size.y > 0 and box.size.z > 0

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
