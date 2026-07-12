extends RefCounted
class_name TownRuntimeManifest

const SCHEMA_VERSION := 1
const STATUS_VALID := "valid"
const STATUS_INVALID := "invalid"

const REQUIRED_HOME_CELLS := [
	"homeCell",
	"porchCell",
	"doorCell",
	"interiorLandingCell",
	"interiorMinCell",
	"interiorMaxCell"
]

static func requirements_from_actor_specs(actor_specs: Array) -> Dictionary:
	var problems: Array[String] = []
	var required_keys := {}
	var actor_assignments := {}
	var actor_ids := {}
	for index in range(actor_specs.size()):
		var value = actor_specs[index]
		if not (value is Dictionary):
			problems.append("actorSpecs[%d] must be a dictionary" % index)
			continue
		var spec: Dictionary = value
		var actor_id := String(spec.get("id", "")).strip_edges()
		if actor_id == "":
			problems.append("actorSpecs[%d] is missing id" % index)
		elif actor_ids.has(actor_id):
			problems.append("duplicate actor id: %s" % actor_id)
		else:
			actor_ids[actor_id] = true
		if not bool(spec.get("requiresHome", true)):
			continue
		if not spec.has("homeKey"):
			problems.append("actor %s is missing required homeKey" % (actor_id if actor_id != "" else str(index)))
			continue
		var home_key := int(spec.get("homeKey", -1))
		if home_key < 0:
			problems.append("actor %s has invalid homeKey %d" % [actor_id if actor_id != "" else str(index), home_key])
			continue
		required_keys[home_key] = true
		if actor_id != "":
			actor_assignments[actor_id] = home_key
	var keys: Array = required_keys.keys()
	keys.sort()
	return {
		"ok": problems.is_empty(),
		"requiredHomeKeys": keys,
		"actorHomeAssignments": actor_assignments,
		"problems": problems
	}

static func build(
	seed_value: String,
	town_key: String,
	center: Vector2i,
	generation_revision: int,
	required_home_keys: Array,
	home_records: Array,
	door_portal_ids: Array,
	pending_structure_ops := 0
) -> Dictionary:
	var build_problems: Array[String] = []
	var homes_by_key := {}
	var source_home_key_counts := {}
	var source_stable_id_counts := {}
	var source_door_portal_id_counts := {}
	for index in range(home_records.size()):
		var value = home_records[index]
		if not (value is Dictionary):
			build_problems.append("homeRecords[%d] must be a dictionary" % index)
			continue
		var record := normalize_home_record(value)
		var home_key := int(record.get("homeKey", -1))
		if home_key < 0:
			build_problems.append("homeRecords[%d] has invalid homeKey" % index)
			continue
		var key := home_key_string(home_key)
		source_home_key_counts[key] = int(source_home_key_counts.get(key, 0)) + 1
		var stable_id := String(record.get("stableId", "")).strip_edges()
		if stable_id != "":
			source_stable_id_counts[stable_id] = int(source_stable_id_counts.get(stable_id, 0)) + 1
		var door_portal_id := String(record.get("doorPortalId", "")).strip_edges()
		if door_portal_id != "":
			source_door_portal_id_counts[door_portal_id] = int(source_door_portal_id_counts.get(door_portal_id, 0)) + 1
		if not homes_by_key.has(key):
			homes_by_key[key] = record
	var manifest := {
		"schemaVersion": SCHEMA_VERSION,
		"townKey": town_key.strip_edges(),
		"seed": seed_value,
		"center": center,
		"generationRevision": generation_revision,
		"requiredHomeKeys": sorted_unique_ints(required_home_keys),
		"homesByKey": homes_by_key,
		"doorPortalIds": sorted_unique_strings(door_portal_ids),
		"pendingStructureOps": maxi(int(pending_structure_ops), 0),
		"sourceHomeKeyCounts": source_home_key_counts,
		"sourceStableIdCounts": source_stable_id_counts,
		"sourceDoorPortalIdCounts": source_door_portal_id_counts,
		"buildProblems": build_problems,
		"ready": false,
		"failureReasons": [],
		"pendingReasons": []
	}
	var validation := validate(manifest)
	manifest["failureReasons"] = (validation.get("problems", []) as Array).duplicate()
	if int(manifest.get("pendingStructureOps", 0)) > 0:
		manifest["pendingReasons"] = ["required_structure_operations_pending"]
	manifest["ready"] = bool(validation.get("ok", false)) and (manifest.get("pendingReasons", []) as Array).is_empty()
	return manifest

static func validate(value) -> Dictionary:
	var problems: Array[String] = []
	var missing_required_home_keys: Array[int] = []
	var duplicate_home_keys: Array[int] = []
	if not (value is Dictionary):
		return validation_result(["manifest must be a dictionary"], [], [])
	var manifest: Dictionary = value
	if contains_live_object(manifest):
		problems.append("manifest must not contain live Object references")
	if int(manifest.get("schemaVersion", 0)) != SCHEMA_VERSION:
		problems.append("schemaVersion must be %d" % SCHEMA_VERSION)
	var town_key := String(manifest.get("townKey", "")).strip_edges()
	if town_key == "":
		problems.append("missing townKey")
	if String(manifest.get("seed", "")) == "":
		problems.append("missing seed")
	if not (manifest.get("center") is Vector2i):
		problems.append("center must be Vector2i")
	if int(manifest.get("generationRevision", -1)) < 0:
		problems.append("generationRevision must be non-negative")
	if int(manifest.get("pendingStructureOps", -1)) < 0:
		problems.append("pendingStructureOps must be non-negative")
	for build_problem in manifest.get("buildProblems", []):
		problems.append(String(build_problem))
	var required_keys := sorted_unique_ints(manifest.get("requiredHomeKeys", []))
	if not (manifest.get("requiredHomeKeys", []) is Array):
		problems.append("requiredHomeKeys must be an array")
	var source_counts: Dictionary = manifest.get("sourceHomeKeyCounts", {}) if manifest.get("sourceHomeKeyCounts", {}) is Dictionary else {}
	for key_value in source_counts.keys():
		if int(source_counts.get(key_value, 0)) > 1:
			var duplicate_key := int(String(key_value))
			duplicate_home_keys.append(duplicate_key)
			problems.append("duplicate homeKey %d" % duplicate_key)
	duplicate_home_keys.sort()
	for stable_id_value in dictionary_keys_sorted(manifest.get("sourceStableIdCounts", {})):
		var stable_id := String(stable_id_value)
		var stable_counts: Dictionary = manifest.get("sourceStableIdCounts", {})
		if int(stable_counts.get(stable_id, 0)) > 1:
			problems.append("duplicate stableId: %s" % stable_id)
	for portal_id_value in dictionary_keys_sorted(manifest.get("sourceDoorPortalIdCounts", {})):
		var portal_id := String(portal_id_value)
		var portal_counts: Dictionary = manifest.get("sourceDoorPortalIdCounts", {})
		if int(portal_counts.get(portal_id, 0)) > 1:
			problems.append("duplicate doorPortalId: %s" % portal_id)
	var homes_by_key: Dictionary = manifest.get("homesByKey", {}) if manifest.get("homesByKey", {}) is Dictionary else {}
	if not (manifest.get("homesByKey", {}) is Dictionary):
		problems.append("homesByKey must be a dictionary")
	var portal_ids := sorted_unique_strings(manifest.get("doorPortalIds", []))
	if not (manifest.get("doorPortalIds", []) is Array):
		problems.append("doorPortalIds must be an array")
	for home_key_value in required_keys:
		var home_key := int(home_key_value)
		var key := home_key_string(home_key)
		if not homes_by_key.has(key):
			missing_required_home_keys.append(home_key)
			problems.append("missing required homeKey %d" % home_key)
	for key_value in dictionary_keys_sorted(homes_by_key):
		var key := String(key_value)
		if not key.is_valid_int():
			problems.append("homesByKey contains non-integer key: %s" % key)
			continue
		var home_key := int(key)
		var record_value = homes_by_key.get(key)
		if not (record_value is Dictionary):
			problems.append("home %d must be a dictionary" % home_key)
			continue
		validate_home_record(home_key, record_value, town_key, portal_ids, problems)
	return validation_result(problems, missing_required_home_keys, duplicate_home_keys, {
		"requiredHomeCount": required_keys.size(),
		"providedHomeCount": homes_by_key.size(),
		"doorPortalCount": portal_ids.size(),
		"pendingStructureOps": int(manifest.get("pendingStructureOps", 0))
	})

static func normalize_home_record(value: Dictionary) -> Dictionary:
	var record := value.duplicate(true)
	record["homeKey"] = int(record.get("homeKey", record.get("buildingIndex", -1)))
	record["stableId"] = String(record.get("stableId", "")).strip_edges()
	record["townKey"] = String(record.get("townKey", "")).strip_edges()
	record["doorPortalId"] = String(record.get("doorPortalId", "")).strip_edges()
	if record.get("homeRouteCells", []) is Array:
		record["homeRouteCells"] = (record.get("homeRouteCells", []) as Array).duplicate()
	return record

static func validate_home_record(home_key: int, value: Dictionary, town_key: String, portal_ids: Array, problems: Array[String]) -> void:
	var prefix := "home %d" % home_key
	if int(value.get("homeKey", -1)) != home_key:
		problems.append("%s homeKey does not match its manifest key" % prefix)
	if String(value.get("stableId", "")).strip_edges() == "":
		problems.append("%s is missing stableId" % prefix)
	if String(value.get("townKey", "")) != town_key:
		problems.append("%s belongs to wrong townKey" % prefix)
	for field in REQUIRED_HOME_CELLS:
		if not (value.get(field) is Vector2i):
			problems.append("%s.%s must be Vector2i" % [prefix, field])
	var portal_id := String(value.get("doorPortalId", "")).strip_edges()
	if portal_id == "":
		problems.append("%s is missing doorPortalId" % prefix)
	elif not portal_ids.has(portal_id):
		problems.append("%s doorPortalId is not published by the manifest" % prefix)
	var route_value = value.get("homeRouteCells", [])
	if not (route_value is Array):
		problems.append("%s.homeRouteCells must be an array" % prefix)
		return
	var route: Array = route_value
	if route.is_empty():
		problems.append("%s.homeRouteCells must not be empty" % prefix)
		return
	for index in range(route.size()):
		if not (route[index] is Vector2i):
			problems.append("%s.homeRouteCells[%d] must be Vector2i" % [prefix, index])
	if not required_cells_are_valid(value):
		return
	var interior_min: Vector2i = value.get("interiorMinCell")
	var interior_max: Vector2i = value.get("interiorMaxCell")
	if interior_min.x > interior_max.x or interior_min.y > interior_max.y:
		problems.append("%s strict interior bounds are inverted" % prefix)
	else:
		for field in ["interiorLandingCell", "homeCell"]:
			var cell: Vector2i = value.get(field)
			if not cell_inside_bounds(cell, interior_min, interior_max):
				problems.append("%s.%s is outside strict interior bounds" % [prefix, field])
	var porch_index := route.find(value.get("porchCell"))
	var door_index := route.find(value.get("doorCell"))
	var landing_index := route.find(value.get("interiorLandingCell"))
	var home_index := route.find(value.get("homeCell"))
	if porch_index < 0 or door_index < 0 or landing_index < 0 or home_index < 0:
		problems.append("%s.homeRouteCells must contain porch, door, landing, and home cells" % prefix)
	elif not (porch_index <= door_index and door_index <= landing_index and landing_index <= home_index):
		problems.append("%s.homeRouteCells has incoherent semantic order" % prefix)

static func stable_json(value) -> String:
	return JSON.stringify(canonical_data(value))

static func canonical_data(value):
	if value is Vector2i:
		return {"x": value.x, "z": value.y}
	if value is Vector3i:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Dictionary:
		var source: Dictionary = value
		var key_names: Array[String] = []
		var values_by_name := {}
		for key_value in source.keys():
			var key_name := String(key_value)
			key_names.append(key_name)
			values_by_name[key_name] = source[key_value]
		key_names.sort()
		var result := {}
		for key_name in key_names:
			result[key_name] = canonical_data(values_by_name[key_name])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(canonical_data(item))
		return result
	return value

static func validation_result(problems: Array, missing_keys: Array, duplicate_keys: Array, metrics := {}) -> Dictionary:
	return {
		"ok": problems.is_empty(),
		"status": STATUS_VALID if problems.is_empty() else STATUS_INVALID,
		"problems": problems.duplicate(),
		"missingRequiredHomeKeys": missing_keys.duplicate(),
		"duplicateHomeKeys": duplicate_keys.duplicate(),
		"metrics": metrics.duplicate(true) if metrics is Dictionary else {}
	}

static func required_cells_are_valid(record: Dictionary) -> bool:
	for field in REQUIRED_HOME_CELLS:
		if not (record.get(field) is Vector2i):
			return false
	return true

static func cell_inside_bounds(cell: Vector2i, minimum: Vector2i, maximum: Vector2i) -> bool:
	return cell.x >= minimum.x and cell.x <= maximum.x and cell.y >= minimum.y and cell.y <= maximum.y

static func sorted_unique_ints(values) -> Array:
	var unique := {}
	if values is Array:
		for value in values:
			unique[int(value)] = true
	var result: Array = unique.keys()
	result.sort()
	return result

static func sorted_unique_strings(values) -> Array:
	var unique := {}
	if values is Array:
		for value in values:
			var text := String(value).strip_edges()
			if text != "":
				unique[text] = true
	var result: Array = unique.keys()
	result.sort()
	return result

static func home_key_string(home_key: int) -> String:
	return str(home_key)

static func dictionary_keys_sorted(value) -> Array:
	if not (value is Dictionary):
		return []
	var result: Array = (value as Dictionary).keys()
	result.sort()
	return result

static func contains_live_object(value) -> bool:
	if value is Object:
		return true
	if value is Dictionary:
		for item in (value as Dictionary).values():
			if contains_live_object(item):
				return true
	if value is Array:
		for item in value:
			if contains_live_object(item):
				return true
	return false
