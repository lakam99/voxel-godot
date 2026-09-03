extends RefCounted

## Producer-authored membership only. Neither contact nor rootedness is proved
## here; CitadelBuntingAnchorRecipe and terminal physical validation own those.
const KEY := "citadelBuntingAssemblies"
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_PARTS := 10000
const MAX_ASSEMBLIES := 16
const MAX_PENNANTS := 128
const ROPE_SEMANTIC := "citadel_bunting_rope"
const PENNANT_SEMANTIC := "citadel_bunting"

## Declare the complete producer collection once its parts have been emitted.
## Replacement is atomic; unrelated recipe fields and all geometry stay exact.
static func declare(source, records: Array) -> Dictionary:
	var checked: Dictionary = _validate(source,records)
	if not checked.ready: return checked
	source.recipe[KEY] = checked.records.duplicate(true)
	return checked

## Explicit [] is valid only when there are no rope/pennant semantic members.
## Missing metadata is not implicitly an empty declaration.
static func read(source) -> Dictionary:
	if not source is Blueprint: return _fail("invalid_bunting_manifest_source")
	if not source.recipe.has(KEY): return _fail("missing_bunting_manifest")
	return _validate(source,source.recipe[KEY])

static func _validate(source, collection: Variant) -> Dictionary:
	if not source is Blueprint or source.parts.size() > MAX_PARTS:
		return _fail("invalid_bunting_manifest_source")
	if not collection is Array or collection.size() > MAX_ASSEMBLIES:
		return _fail("invalid_bunting_manifest_collection")
	var parts: Dictionary = {}
	var expected: Dictionary = {}
	for part in source.parts:
		if not part is Part or not _valid_id(part.id) or parts.has(part.id):
			return _fail("invalid_or_duplicate_bunting_source_id")
		parts[part.id] = part
		if part.semantic not in [ROPE_SEMANTIC,PENNANT_SEMANTIC]: continue
		var kind: String = "beam" if part.semantic == ROPE_SEMANTIC else "pennant"
		if part.kind != kind or part.collision_enabled or not source.has_finite_positive_bounds(part):
			return _fail("invalid_bunting_member_geometry",part.id)
		expected[part.id] = part.semantic
	var covered: Dictionary = {}
	var pennant_count := 0
	for record: Variant in collection:
		if not record is Dictionary or record.size() != 2 or not record.has("ropeId") or not record.has("pennantIds"):
			return _fail("invalid_bunting_manifest_record")
		if not _valid_id(record.ropeId) or not record.pennantIds is Array or record.pennantIds.is_empty() or record.pennantIds.size() > MAX_PENNANTS:
			return _fail("invalid_bunting_manifest_members")
		if not expected.has(record.ropeId) or expected[record.ropeId] != ROPE_SEMANTIC:
			return _fail("missing_or_wrong_bunting_rope",record.ropeId)
		if covered.has(record.ropeId): return _fail("duplicate_bunting_manifest_member",record.ropeId)
		covered[record.ropeId] = true
		for id: Variant in record.pennantIds:
			if not _valid_id(id): return _fail("invalid_bunting_manifest_members")
			if not expected.has(id) or expected[id] != PENNANT_SEMANTIC:
				return _fail("missing_or_wrong_bunting_pennant",id)
			if covered.has(id): return _fail("duplicate_bunting_manifest_member",id)
			covered[id] = true
			pennant_count += 1
	if covered.size() != expected.size(): return _fail("incomplete_bunting_manifest_coverage")
	return {"ready":true,"records":collection.duplicate(true),"ropeCount":collection.size(),"pennantCount":pennant_count}

static func _valid_id(value: Variant) -> bool:
	return value is String and not value.is_empty() and value == value.strip_edges()

static func _fail(reason: String, id: String = "") -> Dictionary:
	return {"ready":false,"reason":reason} if id.is_empty() else {"ready":false,"reason":reason,"partId":id}
