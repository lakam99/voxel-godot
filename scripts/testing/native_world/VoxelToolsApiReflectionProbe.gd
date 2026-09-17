extends SceneTree

const REQUIRED_CLASSES := [
	"VoxelTerrain",
	"VoxelViewer",
	"VoxelBuffer",
	"VoxelGenerator",
	"VoxelGeneratorScript",
	"VoxelStream",
	"VoxelStreamScript",
	"VoxelTool"
]

const OBSERVED_CLASSES := [
	"VoxelBuffer",
	"VoxelData",
	"VoxelEngine",
	"VoxelFormat",
	"VoxelGenerator",
	"VoxelGeneratorFlat",
	"VoxelGeneratorGraph",
	"VoxelGeneratorImage",
	"VoxelGeneratorNoise2D",
	"VoxelGeneratorScript",
	"VoxelInstancer",
	"VoxelLodTerrain",
	"VoxelMesher",
	"VoxelMesherBlocky",
	"VoxelMesherCubes",
	"VoxelMesherTransvoxel",
	"VoxelNode",
	"VoxelStream",
	"VoxelStreamRegionFiles",
	"VoxelStreamScript",
	"VoxelTerrain",
	"VoxelTerrainLarge",
	"VoxelTool",
	"VoxelToolBuffer",
	"VoxelToolLodTerrain",
	"VoxelToolMultipassGenerator",
	"VoxelToolTerrain",
	"VoxelViewer"
]

const CAPABILITY_QUERIES := [
	{
		"id": "project_collision_artifact_injection_for_specific_block",
		"classes": ["VoxelTerrain", "VoxelTerrainLarge"],
		"exactCandidateNames": [
			"install_collision_artifact", "install_collision_block",
			"set_collision_block", "set_collision_block_shape",
			"set_collision_mesh", "set_collision_shape"
		],
		"keywordTokens": ["collision", "block"]
	},
	{
		"id": "exact_collision_install_or_physics_acknowledgement",
		"classes": ["VoxelTerrain", "VoxelTerrainLarge"],
		"exactCandidateNames": [
			"collision_artifact_installed", "collision_block_acknowledged",
			"collision_block_installed", "get_collision_install_receipt",
			"physics_sync_completed"
		],
		"keywordTokens": ["collision", "ack", "install", "physics", "sync"]
	},
	{
		"id": "viewer_native_task_hard_cap",
		"classes": ["VoxelViewer"],
		"exactCandidateNames": [
			"max_pending_tasks", "max_task_count", "native_task_budget",
			"pending_task_limit", "task_budget", "task_cap"
		],
		"keywordTokens": ["task", "queue", "pending", "budget", "cap"]
	},
	{
		"id": "terrain_generator_or_stream_assignment",
		"classes": ["VoxelTerrain", "VoxelTerrainLarge"],
		"exactCandidateNames": ["generator", "set_generator", "stream", "set_stream"],
		"keywordTokens": ["generator", "stream"]
	}
]

const ABSENCE_INTERPRETATION := (
	"An unobserved candidate means only that no matching member was present in "
	+ "the reflected ClassDB surface of the installed library loaded by this Godot "
	+ "process. It is not proof of universal impossibility: a capability may exist "
	+ "outside ClassDB, under another name or composition, in another build/configuration, "
	+ "or in another plugin or engine version."
)


func _initialize() -> void:
	call_deferred("_run_probe")


func _run_probe() -> void:
	var report_path := OS.get_environment("VOXEL_TOOLS_API_PROBE_REPORT").strip_edges()
	var run_token := OS.get_environment("VOXEL_TOOLS_API_PROBE_RUN_TOKEN").strip_edges()
	if report_path.is_empty() or run_token.is_empty() or FileAccess.file_exists(report_path):
		quit(2)
		return

	var classes := []
	var missing_required := []
	for class_name_value in OBSERVED_CLASSES:
		var class_name_text := String(class_name_value)
		classes.append(_class_record(class_name_text))
	for class_name_value in REQUIRED_CLASSES:
		var class_name_text := String(class_name_value)
		if not ClassDB.class_exists(class_name_text):
			missing_required.append(class_name_text)

	var provided_identity = JSON.parse_string(
		OS.get_environment("VOXEL_TOOLS_API_PROBE_IDENTITY_JSON")
	)
	if not provided_identity is Dictionary:
		provided_identity = {}

	var executable_path := OS.get_executable_path()
	var report := {
		"schema": "voxel-tools-classdb-reflection/v1",
		"runnerId": "voxel_tools_api_reflection_probe",
		"evidenceLevel": "read-only ClassDB reflection; no gameplay or API invocation",
		"finished": true,
		"passed": missing_required.is_empty(),
		"runToken": run_token,
		"missingRequiredClasses": missing_required,
		"requiredClasses": REQUIRED_CLASSES,
		"observedClassNames": OBSERVED_CLASSES,
		"classes": classes,
		"capabilityCandidateObservations": _capability_observations(classes),
		"absenceInterpretation": ABSENCE_INTERPRETATION,
		"godot": {
			"version": Engine.get_version_info(),
			"runtimeExecutablePath": executable_path,
			"runtimeExecutableSha256": FileAccess.get_sha256(executable_path)
		},
		"providedIdentity": provided_identity
	}

	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		quit(3)
		return
	file.store_string(JSON.stringify(report, "\t", true, true) + "\n")
	file.close()
	quit(0 if bool(report.passed) else 1)


func _class_record(class_name_text: String) -> Dictionary:
	if not ClassDB.class_exists(class_name_text):
		return {
			"name": class_name_text,
			"exists": false,
			"parentClass": "",
			"declared": _empty_members(),
			"includingInherited": _empty_members()
		}
	return {
		"name": class_name_text,
		"exists": true,
		"parentClass": String(ClassDB.get_parent_class(class_name_text)),
		"declared": _members(class_name_text, true),
		"includingInherited": _members(class_name_text, false)
	}


func _empty_members() -> Dictionary:
	return {
		"methods": [], "properties": [], "signals": [],
		"integerConstants": [], "enums": []
	}


func _members(class_name_text: String, declared_only: bool) -> Dictionary:
	var methods := []
	for method_value in ClassDB.class_get_method_list(class_name_text, declared_only):
		methods.append(_callable_record(method_value))
	methods.sort_custom(_named_record_less)

	var properties := []
	for property_value in ClassDB.class_get_property_list(class_name_text, declared_only):
		properties.append(_property_record(property_value))
	properties.sort_custom(_named_record_less)

	var signals := []
	for signal_value in ClassDB.class_get_signal_list(class_name_text, declared_only):
		signals.append(_callable_record(signal_value))
	signals.sort_custom(_named_record_less)

	var constants := []
	var constant_names := Array(ClassDB.class_get_integer_constant_list(class_name_text, declared_only))
	constant_names.sort()
	for constant_name_value in constant_names:
		var constant_name_text := String(constant_name_value)
		constants.append({
			"name": constant_name_text,
			"valueDecimal": str(ClassDB.class_get_integer_constant(class_name_text, constant_name_text))
		})

	var enums := []
	var enum_names := Array(ClassDB.class_get_enum_list(class_name_text, declared_only))
	enum_names.sort()
	for enum_name_value in enum_names:
		var enum_name_text := String(enum_name_value)
		var enum_constants := []
		var enum_constant_names := Array(
			ClassDB.class_get_enum_constants(class_name_text, enum_name_text, declared_only)
		)
		enum_constant_names.sort()
		for constant_name_value in enum_constant_names:
			var constant_name_text := String(constant_name_value)
			enum_constants.append({
				"name": constant_name_text,
				"valueDecimal": str(
					ClassDB.class_get_integer_constant(class_name_text, constant_name_text)
				)
			})
		enums.append({"name": enum_name_text, "constants": enum_constants})

	return {
		"methods": methods,
		"properties": properties,
		"signals": signals,
		"integerConstants": constants,
		"enums": enums
	}


func _callable_record(value) -> Dictionary:
	var info: Dictionary = value if value is Dictionary else {}
	var arguments := []
	for argument_value in info.get("args", []):
		arguments.append(_property_record(argument_value))
	var defaults := []
	for default_value in info.get("default_args", []):
		defaults.append(_variant_record(default_value))
	return {
		"name": String(info.get("name", "")),
		"flags": int(info.get("flags", 0)),
		"return": _property_record(info.get("return", {})),
		"arguments": arguments,
		"defaultArguments": defaults
	}


func _property_record(value) -> Dictionary:
	var info: Dictionary = value if value is Dictionary else {}
	var variant_type := int(info.get("type", TYPE_NIL))
	return {
		"name": String(info.get("name", "")),
		"type": variant_type,
		"typeName": type_string(variant_type),
		"className": String(info.get("class_name", "")),
		"hint": int(info.get("hint", PROPERTY_HINT_NONE)),
		"hintString": String(info.get("hint_string", "")),
		"usage": int(info.get("usage", PROPERTY_USAGE_NONE))
	}


func _variant_record(value) -> Dictionary:
	var variant_type := typeof(value)
	var normalized = value
	match variant_type:
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			pass
		TYPE_STRING_NAME:
			normalized = String(value)
		TYPE_VECTOR2:
			normalized = {"x": value.x, "y": value.y}
		TYPE_VECTOR2I:
			normalized = {"x": value.x, "y": value.y}
		TYPE_VECTOR3:
			normalized = {"x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR3I:
			normalized = {"x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			normalized = {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		_:
			normalized = str(value)
	return {
		"type": variant_type,
		"typeName": type_string(variant_type),
		"value": normalized
	}


func _named_record_less(left, right) -> bool:
	return String(left.get("name", "")) < String(right.get("name", ""))


func _capability_observations(classes: Array) -> Array:
	var class_records := {}
	for class_value in classes:
		var class_record: Dictionary = class_value
		class_records[String(class_record.get("name", ""))] = class_record
	var observations := []
	for query_value in CAPABILITY_QUERIES:
		var query: Dictionary = query_value
		var exact_names := {}
		for candidate_value in query.get("exactCandidateNames", []):
			exact_names[String(candidate_value).to_lower()] = true
		var tokens := []
		for token_value in query.get("keywordTokens", []):
			tokens.append(String(token_value).to_lower())
		var exact_matches := []
		var keyword_matches := []
		for class_name_value in query.get("classes", []):
			var class_name_text := String(class_name_value)
			var class_record: Dictionary = class_records.get(class_name_text, {})
			var members: Dictionary = class_record.get("includingInherited", _empty_members())
			for kind in ["methods", "properties", "signals", "integerConstants"]:
				for member_value in members.get(kind, []):
					var member: Dictionary = member_value
					var member_name := String(member.get("name", ""))
					var lower_name := member_name.to_lower()
					var match_record := {
						"class": class_name_text, "kind": kind, "name": member_name
					}
					if exact_names.has(lower_name):
						exact_matches.append(match_record)
					for token in tokens:
						if lower_name.contains(token):
							keyword_matches.append(match_record)
							break
		exact_matches.sort_custom(_member_match_less)
		keyword_matches.sort_custom(_member_match_less)
		observations.append({
			"id": String(query.get("id", "")),
			"classes": query.get("classes", []),
			"exactCandidateNames": query.get("exactCandidateNames", []),
			"exactMatches": exact_matches,
			"keywordTokens": query.get("keywordTokens", []),
			"keywordMatches": keyword_matches,
			"exactCandidateObservation": (
				"observed_in_reflected_classdb_surface"
				if not exact_matches.is_empty()
				else "not_observed_in_reflected_classdb_surface"
			),
			"interpretation": ABSENCE_INTERPRETATION
		})
	return observations


func _member_match_less(left, right) -> bool:
	for field in ["class", "kind", "name"]:
		var left_value := String(left.get(field, ""))
		var right_value := String(right.get(field, ""))
		if left_value != right_value:
			return left_value < right_value
	return false
