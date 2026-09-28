extends RefCounted
class_name GeneratedSiteProfileStore

## One session's append-only terrain input. Native workers acquire one immutable
## array per block; no worker reads an array while the owner is appending to it.
## Admission owns validation and proves additions affect no admitted terrain.
var _mutex := Mutex.new()
var _profiles: Array = []
var _seed: String

func _init(world_seed: String = "") -> void:
	_seed = world_seed
	_profiles.make_read_only()

func snapshot() -> Array:
	_mutex.lock()
	var result := _profiles
	_mutex.unlock()
	return result

func world_seed() -> String:
	return _seed

func append_prepared_profile(profile: Dictionary) -> bool:
	# The caller consumes a successful immutable CitadelSiteBuildQueue receipt.
	# Full mask validation happened on that worker, not in a gameplay frame.
	if not profile.is_read_only() or profile.get("worldSeed") != _seed:
		return false
	for field in ["supportMask", "distanceCells", "groundRootPoints"]:
		if not profile.get(field) is Array or not profile[field].is_read_only(): return false
	_mutex.lock()
	for previous: Dictionary in _profiles:
		if previous.siteId == profile.siteId or (previous.envelopeCells as Rect2i).intersects(profile.envelopeCells):
			_mutex.unlock()
			return false
	var next := _profiles.duplicate()
	next.append(profile)
	next.sort_custom(func(a, b): return String(a.siteId) < String(b.siteId))
	next.make_read_only()
	_profiles = next
	_mutex.unlock()
	return true
