extends RefCounted
class_name NavigationBackendConfig

const BACKEND_CUSTOM := "custom"
const BACKEND_NAVMESH := "navmesh"
const ENV_BACKEND := "VOXEL_NPC_NAV_BACKEND"

var backend := BACKEND_CUSTOM
var source := "default"

static func default_config():
	return from_value(BACKEND_CUSTOM, "default")

static func from_environment(default_backend := BACKEND_CUSTOM):
	var value := OS.get_environment(ENV_BACKEND)
	if value == "":
		value = default_backend
		return from_value(value, "default")
	return from_value(value, "environment")

static func from_value(value: String, source_value := "explicit"):
	var config = load("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd").new()
	config.backend = normalize_backend(value)
	config.source = source_value
	return config

static func normalize_backend(value: String) -> String:
	var normalized := value.strip_edges().to_lower()
	if normalized == BACKEND_NAVMESH:
		return BACKEND_NAVMESH
	return BACKEND_CUSTOM

static func valid_backend(value: String) -> bool:
	var normalized := value.strip_edges().to_lower()
	return normalized == BACKEND_CUSTOM or normalized == BACKEND_NAVMESH

func use_navmesh() -> bool:
	return backend == BACKEND_NAVMESH

func to_summary() -> Dictionary:
	return {
		"backend": backend,
		"source": source,
		"navmeshEnabled": use_navmesh()
	}
