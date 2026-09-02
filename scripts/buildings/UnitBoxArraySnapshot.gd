extends RefCounted

## One publication owner's exact native unit-box arrays. No reconstructed
## vertices, global cache or source fallback. A changed source invalidates it.
const MAX_PROPERTIES := 128
var _box: BoxMesh
var _binding := PackedByteArray()
var _arrays: Array = []
var _array_digest := ""
var _attempted := false
var _valid := false

func capture(box: BoxMesh, telemetry: Dictionary = {}) -> bool:
	if _attempted: return false
	_attempted = true
	var binding := source_binding(box)
	if binding.is_empty() or box.size != Vector3.ONE or box.get_surface_count() != 1: return false
	var arrays := read_arrays(box, telemetry)
	if arrays.size() != Mesh.ARRAY_MAX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array or arrays[Mesh.ARRAY_VERTEX].size() != 24: return false
	if source_binding(box) != binding: return false
	_box = box
	_binding = binding
	_arrays = arrays
	_array_digest = digest(arrays)
	_valid = true
	return true

func matches(box: BoxMesh) -> bool:
	if not _valid: return false
	if box != _box or source_binding(box) != _binding or digest(_arrays) != _array_digest:
		_valid = false
	return _valid

func arrays_for(box: BoxMesh) -> Array:
	return _arrays if matches(box) else []

static func source_binding(box: BoxMesh, bind_identity: bool = true) -> PackedByteArray:
	if box == null or box.get_class() != "BoxMesh" or box.get_script() != null: return PackedByteArray()
	var properties := box.get_property_list()
	if properties.size() > MAX_PROPERTIES: return PackedByteArray()
	var records: Array = []
	for property: Dictionary in properties:
		if (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0: continue
		var value: Variant = box.get(property.name)
		# Material references do not supply primitive vertex arrays; a replacement
		# still invalidates conservatively. Native geometry parameters bind by value.
		if value is Resource: value = [value.get_class(), value.get_instance_id()]
		records.append([property.name, value])
	return var_to_bytes([box.get_instance_id() if bind_identity else 0, records])

static func read_arrays(box: BoxMesh, telemetry: Dictionary = {}) -> Array:
	var started: int = Time.get_ticks_usec() if not telemetry.is_empty() else 0
	var arrays: Array = box.surface_get_arrays(0)
	if not telemetry.is_empty():
		var elapsed := Time.get_ticks_usec() - started
		telemetry["unitBoxArrayReadCount"] = int(telemetry.get("unitBoxArrayReadCount", 0)) + 1
		telemetry["unitBoxArrayReadUsec"] = int(telemetry.get("unitBoxArrayReadUsec", 0)) + elapsed
		telemetry["maxUnitBoxArrayReadUsec"] = maxi(int(telemetry.get("maxUnitBoxArrayReadUsec", 0)), elapsed)
	return arrays

static func digest(value: Variant) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()
