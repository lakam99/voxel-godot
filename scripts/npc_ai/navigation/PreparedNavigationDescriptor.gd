extends "res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd"
class_name PreparedNavigationDescriptor

## Worker-owned descriptor and final CPU buffers. Installation can verify the
## sealed source identity without serializing all surface geometry each frame.
const Geometry = preload("res://scripts/npc_ai/navigation/NavigationMeshPreparation.gd")
const FIELDS := ["region_id","tile_key","bounds","revision","loaded","metadata",
	"walkable_surfaces","blockers","semantic_anchors","door_portals","door_links","crossing_links"]
var _identity := {}
var _signature := ""
var _geometry := {}

func prepare_from(descriptor, continuation: Callable) -> bool:
	if not _identity.is_empty(): return false
	for field: String in FIELDS:
		set(field,descriptor.get(field))
		if not _freeze(get(field),continuation): return false
	_geometry = Geometry.new().compile(walkable_surfaces,continuation)
	if _geometry.is_empty(): return false
	_signature = super.stable_signature()
	if continuation.is_valid() and not continuation.call("navigation_descriptor_sealed"): return false
	for field: String in FIELDS: _identity[field] = get(field)
	_identity.make_read_only()
	return true

func preparation_valid() -> bool:
	if _identity.is_empty() or _signature.is_empty() or _geometry.is_empty(): return false
	for field: String in FIELDS:
		var value = get(field)
		if value is Array or value is Dictionary:
			if not is_same(value,_identity[field]) or not value.is_read_only(): return false
		elif value != _identity[field]: return false
	return true

func prepared_geometry() -> Dictionary:
	return _geometry if preparation_valid() else {}

func stable_signature() -> String:
	return _signature if preparation_valid() else ""

static func _freeze(value, continuation: Callable) -> bool:
	if continuation.is_valid() and not continuation.call("navigation_descriptor_freeze"): return false
	if value is Dictionary:
		for key in value:
			if not _freeze(value[key],continuation): return false
		value.make_read_only()
	elif value is Array:
		for item in value:
			if not _freeze(item,continuation): return false
		value.make_read_only()
	elif value is Object or value is Callable or value is Signal or value is RID:
		return false
	return true
