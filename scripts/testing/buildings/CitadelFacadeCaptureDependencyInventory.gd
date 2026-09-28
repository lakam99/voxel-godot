extends SceneTree

## Read-only artifact inventory. Does not admit publication or waive drift.
const INPUTS := {
	"old_standard": ["facade-paving-cpu-after-standard-02/cpu.bin", "62c70c9829ead5bb32aed94e07cfa79e478357491ad3718fcf24c9028f752d3a"],
	"new_standard": ["facade-combined-cpu-standard-01/cpu.bin", "9483770c6bf8335449951657f780bfe1fea8c4b30e9eb9c3886733c7492244bb"],
	"old_static": ["facade-paving-cpu-after-static-02/cpu.bin", "8fc6ee675af41a63c818286dd30777cc753a07d5b1c7767b6aafdee38a484cca"],
	"new_static": ["facade-combined-cpu-static-01/cpu.bin", "fd04163c70737ec407c446d09af7ba46fb583dc5c599c96f4f1b4b7239567dcb"]}

func _initialize() -> void:
	call_deferred("_run")

func _identity(key: String) -> Dictionary:
	var spec: Array = INPUTS[key]
	var path: String = "res://artifacts/citadel-visual-reset/" + spec[0]
	if FileAccess.get_sha256(path) != spec[1]: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var size := file.get_length()
	if size <= 0 or size > 268435456:
		file.close()
		return {}
	var bytes := file.get_buffer(size)
	var complete := bytes.size() == size and file.get_error() == OK
	file.close()
	var value: Variant = bytes_to_var(bytes)
	if not complete or not value is Dictionary or var_to_bytes(value) != bytes or FileAccess.get_sha256(path) != spec[1]: return {}
	return value.get("implementationIdentity", {}).duplicate(true)

func _run() -> void:
	var path := OS.get_environment("VOXEL_CAPTURE_DEPENDENCY_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var identities: Dictionary = {}
	var drift: Dictionary = {}
	for key in INPUTS:
		identities[key] = _identity(key)
		if identities[key].is_empty():
			quit(2)
			return
		var rows: Array = []
		for source_path in identities[key]:
			var current := FileAccess.get_sha256(source_path)
			if current != identities[key][source_path]: rows.append({"path": source_path, "captured": identities[key][source_path], "current": current})
		drift[key] = rows
	var report := {"diagnosticCompleted": true, "publicationAcceptance": false, "inputBindings": INPUTS, "identities": identities, "currentDrift": drift,
		"sameOldModeIdentity": identities.old_standard == identities.old_static, "sameNewModeIdentity": identities.new_standard == identities.new_static,
		"doesNotProve": "This inventory does not approve reuse or waive any changed dependency; call-path and actual payload parity review remain required."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if written else 2)
