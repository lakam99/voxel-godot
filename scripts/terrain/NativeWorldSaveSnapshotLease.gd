extends RefCounted
class_name NativeWorldSaveSnapshotLease

## Producer-issued lifetime/revision lease for a decoded save-v2 snapshot.
## The producer MUST invalidate before changing any nested volume data and
## MUST NOT mutate that subtree while the lease is valid. Godot Dictionary
## and Array values are mutable, so this API cannot freeze them itself.

var _owner
var _volume: Dictionary = {}
var _volume_revision := -1
var _lease_revision := 1
var _valid := false
var _invalid_reason := ""

func acquire(owner, volume: Dictionary) -> bool:
	if _valid or owner == null or volume.is_empty(): return false
	if not volume.get("revision", null) is int or int(volume.revision) < 0: return false
	_owner = owner
	_volume = volume
	_volume_revision = int(volume.revision)
	_valid = true
	return true

func is_valid_for(volume: Dictionary) -> bool:
	return _valid and is_same(volume, _volume) \
		and int(volume.get("revision", -1)) == _volume_revision

func invalidate(reason: String = "snapshot_mutated") -> Dictionary:
	if _valid:
		_valid = false
		_invalid_reason = reason if not reason.is_empty() else "snapshot_mutated"
		_lease_revision += 1
	return {"valid": false, "reason": _invalid_reason, "revision": _lease_revision}

func lease_revision() -> int:
	return _lease_revision

func invalid_reason() -> String:
	return _invalid_reason

func retained_owner():
	return _owner

func release_after_drain() -> void:
	_valid = false
	_owner = null
	_volume = {}
