extends RefCounted
class_name TerrainGenerationFailureAuthority

var mutex := Mutex.new()
var first_failure: Dictionary = {}


func report_failure(code: String, details: Dictionary = {}) -> bool:
	mutex.lock()
	var changed := false
	if first_failure.is_empty():
		first_failure = {
			"code": code,
			"details": details.duplicate(true),
			"reportedUsec": Time.get_ticks_usec()
		}
		changed = true
	mutex.unlock()
	return changed


func has_failure() -> bool:
	mutex.lock()
	var failed := not first_failure.is_empty()
	mutex.unlock()
	return failed


func snapshot() -> Dictionary:
	mutex.lock()
	var result := first_failure.duplicate(true)
	mutex.unlock()
	return result
