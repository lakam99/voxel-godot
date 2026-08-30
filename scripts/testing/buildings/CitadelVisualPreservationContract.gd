extends SceneTree

# SOURCE-ARTIFACT PARITY CAPTURE ONLY. Run this exact external --script in each
# project; res:// dependencies deliberately resolve against that project's root.
# No Main, NPC, publisher, NavigationServer, mesh, physics world, or API override.
# Actual planners retain their own internal layout analysis; none is substituted.
const CastleBuilder = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const UrbanComposer = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const FurniturePlanner = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const SEED: int = 208159
const SCALE: float = 1.25
const FURNITURE_SEED: int = SEED * 7919 + 37
const MAX_PARTS: int = 20000
const MAX_CONTAINER: int = 100000
const MAX_DEPTH: int = 64
const MAX_VALUES: int = 6000000
# Cumulative bytes streamed through hashes, not an allocated snapshot buffer.
# Compound captures include five full snapshots plus separate part/recipe hashes.
# The measured 4M-value prefix alone streams 217 MB; retain bounded headroom.
const MAX_CANONICAL_BYTES: int = 402653184
const MAX_STRING_CHARS: int = 262144
const MAX_REPORT_BYTES: int = 196608
const MAX_ELAPSED_USEC: int = 180000000
const SOURCE_PATHS: Array[String] = [
	"res://scripts/buildings/CastleCompoundBlueprintBuilder.gd",
	"res://scripts/buildings/CitadelUrbanPocComposer.gd",
	"res://scripts/buildings/CastleFurnishingPlanner.gd",
	"res://scripts/buildings/BuildingBlueprint.gd",
	"res://scripts/buildings/BuildingPart.gd",
	"res://scripts/buildings/FurnishingPlan.gd",
	"res://scripts/buildings/FurnishingPart.gd",
	"res://scripts/buildings/BuildingInteriorProgram.gd",
	"res://scripts/buildings/CottageBlueprintBuilder.gd",
	"res://scripts/buildings/CottageFurnishingPlanner.gd",
	"res://scripts/buildings/LandmarkBuildingRecipeSampler.gd",
	"res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd",
	"res://scripts/buildings/LandmarkFurnishingPlanner.gd",
	"res://scripts/buildings/ConstructionMaterialCatalog.gd",
	"res://scripts/buildings/BuildingPartPublisher.gd",
	"res://scripts/buildings/FurnishingPublisher.gd",
	"res://scripts/buildings/SurfaceHistoryField.gd",
	"res://scripts/testing/buildings/CastleWalkthroughRunner.gd",
	"res://scripts/testing/buildings/CitadelUrbanPocRunner.gd"
]

var started_usec: int = 0
var selected_seed: int = SEED
var selected_scale: float = SCALE
var selected_variant: String = "urban"
var progress_file: FileAccess = null
var failed: bool = false
var values_seen: int = 0
var canonical_bytes: int = 0
var report: Dictionary = {
	"schema": "citadel-visual-preservation/v1", "evidenceLevel": "source_artifact_contract",
	"complete": false, "artifactComplete": false, "passed": false, "parityCompared": false,
	"seed": SEED, "scale": SCALE, "furnishingSeed": FURNITURE_SEED,
	"variant": "urban",
	"context": {"biome": "forest", "siteKey": "river-citadel", "citadelScale": SCALE},
	"stages": {}, "errors": [],
	"scope": "One actual seeded castle build, optional urban composition, physical record resolution, and actual furniture planning. Compare the same variant/seed/scale across projects with this identical script and engine build.",
	"stageLabelScope": "Five historical labels retained for both variants. compound_shell is the initial build; urban_shell is the selected shell (unchanged compound when variant=compound); urban_shell_resolved, urban_furniture and urban_shell_after_furniture describe that selected shell and its actual plan. Compound skips only UrbanComposer and retains courtyard residences.",
	"doesNotProve": "No rendered-image/material/shader/mesh equivalence, instantiated trees/lights, live collision, NPC behavior, navigation, performance or gameplay acceptance. Complete means capture succeeded, not parity passed.",
	"ordering": "CastleWalkthroughRunner.build_castle_blueprint context -> CitadelUrbanPocComposer.compose ONLY for urban -> physical record resolution used by BuildingPartPublisher validation -> CastleFurnishingPlanner.build(seed*7919+37). No scene publication. Urban runner tree/light instantiation is excluded; its source tree-placement/lantern records remain hashed.",
	"canonicalization": "v1: SHA256 of recursively framed typed Variant bytes; dictionary keys sorted by typed scalar encoding, arrays retain order, no numeric rounding, no snapshot field filtering. Objects/RIDs/callables/signals rejected. Physical caches are excluded by the production snapshot API; protected furnishing access reservations are added explicitly.",
	"budgetScope": "Fixed one-seed workload; serializer caps and elapsed checks between production calls. Synchronous production methods cannot be preempted here: launcher must impose a wall-clock timeout."
}


func _initialize() -> void:
	call_deferred("_run")


func _require(condition: bool, reason: String) -> bool:
	if not condition:
		failed = true
		if report["errors"].size() < 16:
			report["errors"].append(reason)
	return condition


func _time_ok() -> bool:
	return _require(Time.get_ticks_usec() - started_usec <= MAX_ELAPSED_USEC, "elapsed_capture_limit")


func _progress(phase: String) -> void:
	if progress_file == null:
		return
	progress_file.store_line(JSON.stringify({"phase": phase, "runToken": report["runToken"],
		"variant": selected_variant,
		"seed": selected_seed, "scale": selected_scale, "elapsedUsec": Time.get_ticks_usec() - started_usec,
		"utc": Time.get_datetime_string_from_system(true), "failed": failed}))
	progress_file.flush()
	_require(progress_file.get_error() == OK, "progress_write_failed")


func _parse_arguments() -> bool:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var index: int = 0
	var seen: Dictionary = {}
	while index < args.size():
		var option: String = args[index]
		if not _require(option in ["--seed", "--citadel-scale", "--variant"] and not seen.has(option) and index + 1 < args.size(), "invalid_or_duplicate_argument"):
			return false
		seen[option] = true
		var value: String = args[index + 1]
		if option == "--seed":
			if not _require(value.is_valid_int() and value.to_int() in [208158, 208159], "supported_seeds_are_208158_208159"):
				return false
			selected_seed = value.to_int()
		elif option == "--variant":
			if not _require(value in ["urban", "compound"], "variant_must_be_urban_or_compound"):
				return false
			selected_variant = value
		else:
			if not _require(value.is_valid_float() and value.to_float() == SCALE, "reviewed_scale_is_1.25"):
				return false
			selected_scale = value.to_float()
		index += 2
	report["seed"] = selected_seed
	report["scale"] = selected_scale
	report["variant"] = selected_variant
	report["furnishingSeed"] = selected_seed * 7919 + 37
	report["context"]["citadelScale"] = selected_scale
	return true


func _scalar_supported(value: Variant) -> bool:
	return typeof(value) in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING,
		TYPE_STRING_NAME, TYPE_NODE_PATH, TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_RECT2,
		TYPE_RECT2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_TRANSFORM2D, TYPE_VECTOR4,
		TYPE_VECTOR4I, TYPE_PLANE, TYPE_QUATERNION, TYPE_AABB, TYPE_BASIS,
		TYPE_TRANSFORM3D, TYPE_PROJECTION, TYPE_COLOR]


func _scalar_bytes(value: Variant) -> PackedByteArray:
	if not _require(_scalar_supported(value), "unsupported_scalar_type:%d" % typeof(value)):
		return PackedByteArray()
	if typeof(value) in [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH]:
		if not _require(String(value).length() <= MAX_STRING_CHARS, "scalar_string_limit"):
			return PackedByteArray()
	return var_to_bytes(value)


func _put(hash_context: HashingContext, bytes: PackedByteArray) -> void:
	canonical_bytes += bytes.size()
	if not _require(canonical_bytes <= MAX_CANONICAL_BYTES, "canonical_byte_limit"):
		return
	_require(hash_context.update(bytes) == OK, "hash_update_failed")


func _feed(hash_context: HashingContext, value: Variant, depth: int = 0) -> void:
	if failed:
		return
	values_seen += 1
	if not _require(depth <= MAX_DEPTH and values_seen <= MAX_VALUES, "canonical_depth_or_value_limit"):
		return
	if values_seen % 4096 == 0 and not _time_ok():
		return
	if value is Dictionary:
		if not _require(value.size() <= MAX_CONTAINER, "dictionary_entry_limit"):
			return
		var sorted_keys: Array[String] = []
		var original_keys: Dictionary = {}
		for key: Variant in value:
			var encoded: String = _scalar_bytes(key).hex_encode()
			if failed or not _require(not original_keys.has(encoded), "canonical_dictionary_key_collision"):
				return
			sorted_keys.append(encoded)
			original_keys[encoded] = key
		sorted_keys.sort()
		_put(hash_context, var_to_bytes(["dictionary", value.size()]))
		for encoded: String in sorted_keys:
			var key: Variant = original_keys[encoded]
			_feed(hash_context, key, depth + 1)
			_feed(hash_context, value[key], depth + 1)
	elif value is Array or typeof(value) in [TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY,
		TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY,
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY,
		TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY]:
		if not _require(value.size() <= MAX_CONTAINER, "array_entry_limit"):
			return
		_put(hash_context, var_to_bytes(["sequence", typeof(value), value.size()]))
		for item: Variant in value:
			_feed(hash_context, item, depth + 1)
	else:
		var bytes: PackedByteArray = _scalar_bytes(value)
		if not failed:
			_put(hash_context, var_to_bytes(["scalar", bytes.size()]))
			_put(hash_context, bytes)


func _fingerprint(value: Variant) -> String:
	if failed:
		return ""
	var hash_context: HashingContext = HashingContext.new()
	if not _require(hash_context.start(HashingContext.HASH_SHA256) == OK, "hash_start_failed"):
		return ""
	_feed(hash_context, value)
	return "" if failed else hash_context.finish().hex_encode()


func _capture_stage(label: String, artifact: Object, furnishing: bool = false) -> void:
	if failed or not _require(artifact != null and artifact.has_method("snapshot"), label + ":missing_artifact"):
		return
	var parts: Variant = artifact.get("parts")
	if not _require(parts is Array and parts.size() > 0 and parts.size() <= MAX_PARTS, label + ":part_count_or_type"):
		return
	for part: Variant in parts:
		if not _require(part is Object and part.has_method("snapshot"), label + ":invalid_part"):
			return
	var snapshot_value: Variant = artifact.call("snapshot")
	if not _require(snapshot_value is Dictionary, label + ":snapshot_type"):
		return
	var snapshot: Dictionary = snapshot_value
	if not _require(snapshot.get("parts") is Array and snapshot["parts"].size() == parts.size(), label + ":snapshot_dropped_parts"):
		return
	if furnishing:
		if not _require(artifact.has_method("access_reservations_snapshot"), "missing_reservations_api"):
			return
		var reservations: Variant = artifact.call("access_reservations_snapshot")
		if not _require(reservations is Array, "reservations_type"):
			return
		snapshot["protectedAccessReservations"] = reservations
	var kinds: Dictionary = {}
	var materials: Dictionary = {}
	var collision_count: int = 0
	for part: Variant in parts:
		var kind: String = String(part.get("archetype" if furnishing else "kind"))
		var material: String = String(part.get("material_id"))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		materials[material] = int(materials.get(material, 0)) + 1
		if part.get("collision_enabled") == true:
			collision_count += 1
	if not _require(kinds.size() <= 128 and materials.size() <= 128, "histogram_limit"):
		return
	var stage: Dictionary = {"partCount": parts.size(), "collisionPartCount": collision_count,
		"kindCounts": kinds, "materialCounts": materials, "snapshotSha256": _fingerprint(snapshot),
		"partsSha256": _fingerprint(snapshot["parts"])}
	if furnishing:
		stage["protectedAccessReservationCount"] = snapshot["protectedAccessReservations"].size()
	else:
		if not _require(snapshot.get("recipe") is Dictionary and snapshot.get("rooms") is Array, label + ":recipe_rooms_type"):
			return
		stage["roomCount"] = snapshot["rooms"].size()
		stage["recipeSha256"] = _fingerprint(snapshot["recipe"])
		stage["roomsSha256"] = _fingerprint(snapshot["rooms"])
	report["stages"][label] = stage
	if furnishing and selected_variant == "compound":
		var other_interior_count: int = 0
		for kind: String in ["table", "chair", "bench", "chest", "cabinet", "shelf"]:
			other_interior_count += int(kinds.get(kind, 0))
		report["compoundFurnitureCoverage"] = {"bedCount": int(kinds.get("bed", 0)),
			"otherInteriorCount": other_interior_count,
			"otherInteriorArchetypes": ["table", "chair", "bench", "chest", "cabinet", "shelf"],
			"reservationCount": snapshot["protectedAccessReservations"].size()}
		_require(int(kinds.get("bed", 0)) > 0, "compound_missing_beds")
		_require(other_interior_count > 0, "compound_missing_other_interior_furniture")
		_require(snapshot["protectedAccessReservations"].size() > 0, "compound_missing_access_reservations")


func _capture() -> void:
	# Small serializer controls: order-sensitive lists, order-insensitive mappings,
	# typed scalar identity, and sub-display-precision coordinate changes.
	_require(_fingerprint({"a": 1, "b": 2}) == _fingerprint({"b": 2, "a": 1}), "dictionary_order_control")
	_require(_fingerprint([1, 2]) != _fingerprint([2, 1]), "array_order_control")
	_require(_fingerprint(1) != _fingerprint(1.0), "scalar_type_control")
	_require(_fingerprint(Vector3(1, 2, 3)) != _fingerprint(Vector3(1.0001, 2, 3)), "coordinate_control")
	if failed:
		return
	_progress("compound_build_begin")
	if failed:
		return
	var blueprint = CastleBuilder.build(selected_seed, report["context"].duplicate(true))
	if not _time_ok():
		return
	_progress("compound_snapshot_begin")
	_capture_stage("compound_shell", blueprint)
	if failed:
		return
	if selected_variant == "urban":
		_progress("urban_compose_begin")
		var composed = UrbanComposer.compose(blueprint, selected_seed)
		if not _require(is_same(composed, blueprint), "composer_did_not_return_same_blueprint") or not _time_ok():
			return
	else:
		_progress("compound_retained_without_urban_composition")
	_progress("urban_snapshot_begin")
	_capture_stage("urban_shell", blueprint)
	if failed:
		return
	# This is the actual record-mutating preparation called first by the
	# publisher's validate_physical_integrity. No publisher/readiness is simulated.
	_progress("physical_record_resolution_begin")
	blueprint.resolve_physical_contracts()
	if not _time_ok():
		return
	_progress("resolved_snapshot_begin")
	_capture_stage("urban_shell_resolved", blueprint)
	if failed:
		return
	_progress("furniture_build_begin")
	var furniture = FurniturePlanner.build(blueprint, selected_seed * 7919 + 37)
	if not _time_ok():
		return
	_progress("furniture_snapshot_begin")
	_capture_stage("urban_furniture", furniture, true)
	# Preserve any actual planner-induced shell recipe/room/part changes too.
	_capture_stage("urban_shell_after_furniture", blueprint)
	_require(root.get_child_count() == 0, "unexpected_scene_children")


func _run() -> void:
	var path: String = OS.get_environment("VOXEL_CITADEL_VISUAL_PRESERVATION_REPORT")
	var progress_path: String = OS.get_environment("VOXEL_CITADEL_VISUAL_PRESERVATION_PROGRESS")
	var token: String = OS.get_environment("VOXEL_CITADEL_VISUAL_PRESERVATION_TOKEN")
	if path.is_empty() or not path.is_absolute_path() or FileAccess.file_exists(path) \
		or DirAccess.dir_exists_absolute(path) or progress_path.is_empty() or not progress_path.is_absolute_path() \
		or FileAccess.file_exists(progress_path) or DirAccess.dir_exists_absolute(progress_path) \
		or path.simplify_path().to_lower() == progress_path.simplify_path().to_lower() \
		or token.is_empty() or token.length() > 512:
		printerr("Require distinct fresh absolute VOXEL_CITADEL_VISUAL_PRESERVATION_REPORT / PROGRESS paths and nonempty TOKEN <=512 characters; no overwrite.")
		quit(2)
		return
	started_usec = Time.get_ticks_usec()
	report["runToken"] = token
	var arguments_ok: bool = _parse_arguments()
	progress_file = FileAccess.open(progress_path, FileAccess.WRITE)
	if progress_file == null:
		printerr("Cannot create visual preservation progress: ", FileAccess.get_open_error())
		quit(2)
		return
	_progress("capture_setup")
	report["engineVersion"] = Engine.get_version_info()
	report["projectRoot"] = ProjectSettings.globalize_path("res://")
	var own_path: String = get_script().resource_path
	report["scriptPath"] = own_path
	report["scriptSha256"] = FileAccess.get_sha256(own_path)
	var sources: Dictionary = {}
	for source_path: String in SOURCE_PATHS:
		var digest: String = FileAccess.get_sha256(source_path)
		_require(digest.length() == 64, "missing_source:" + source_path)
		sources[source_path] = digest
	report["sourceSha256"] = sources
	report["sourceIdentityScope"] = "Named artifact owners and publisher/runner context only; not a transitive dependency closure. Launcher must freeze each project independently. Different source hashes do not alone imply different artifacts."
	_require(DisplayServer.get_name() == "headless" and root.get_child_count() == 0, "standalone_headless_required")
	if not failed:
		_capture()
	_require(report["stages"].size() == 5, "incomplete_stage_set")
	_require(report["scriptSha256"].length() == 64, "missing_external_script_identity")
	_progress("capture_finished")
	progress_file.close()
	progress_file = null
	report["artifactComplete"] = not failed
	report["complete"] = not failed
	report["passed"] = not failed
	report["status"] = "artifact_complete" if not failed else "incomplete"
	report["elapsedUsec"] = Time.get_ticks_usec() - started_usec
	report["serialization"] = {"visitedValues": values_seen, "canonicalBytes": canonical_bytes,
		"maxValues": MAX_VALUES, "maxCanonicalBytes": MAX_CANONICAL_BYTES, "maxDepth": MAX_DEPTH,
		"maxParts": MAX_PARTS, "reportByteLimit": MAX_REPORT_BYTES}
	var bytes: PackedByteArray = JSON.stringify(report).to_utf8_buffer()
	if bytes.size() > MAX_REPORT_BYTES:
		report = {"runToken": token, "complete": false, "artifactComplete": false, "passed": false,
			"status": "incomplete", "reason": "report_byte_limit", "attemptedBytes": bytes.size()}
		bytes = JSON.stringify(report).to_utf8_buffer()
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		printerr("Report appeared during capture; refusing overwrite.")
		quit(2)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("Cannot create visual preservation report: ", FileAccess.get_open_error())
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var error: Error = file.get_error()
	var written: int = file.get_length()
	file.close()
	print("SOURCE ARTIFACT capture complete=%s; cross-project parity not evaluated" % report["complete"])
	quit(2 if not arguments_ok or error != OK or written != bytes.size() else (0 if report["complete"] else 1))
