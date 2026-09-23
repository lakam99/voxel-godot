extends RefCounted
class_name NativeTerrainCollisionWindowSource

## Parameterless source facade for one deterministic spatial partition.
## The broker owns the native producer and durable retirement handshake.
var _broker
var _window_token := ""

func setup(broker, window_token: String) -> Dictionary:
	if _broker != null or broker == null or window_token.is_empty():
		return {"status":"failed", "reason":"collision_window_source_invalid"}
	_broker = broker
	_window_token = window_token
	return {"status":"ready", "windowToken":_window_token}

func collision_source_snapshot() -> Dictionary:
	if _broker == null: return {"status":"failed", "reason":"collision_window_source_inactive"}
	return _broker.collision_window_source_snapshot(_window_token)

func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
	if _broker == null: return {"status":"failed", "reason":"collision_window_source_inactive"}
	return _broker.collision_window_artifact_row(_window_token, block, identity)

func detach() -> void:
	_broker = null
