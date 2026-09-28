extends RefCounted
class_name NativeTerrainDemandRequestLease

## O(1) producer-issued lifetime/revision lease for an immutable demand request.
## Godot arrays/dictionaries remain mutable; the producer MUST invalidate the
## lease before mutating any nested request value and keep the request stable
## until the planner reports ready or drained cancellation/supersede.

var _owner
var _primary: Dictionary = {}
var _other_viewers: Array = []
var _retained_chunks: Array = []
var _foreground_chunks: Array = []
var _vertical_bounds := Vector2i.ZERO
var _request_revision := -1
var _lease_revision := 1
var _valid := false

func acquire(owner, primary: Dictionary, other_viewers: Array,
		retained_chunks: Array, foreground_chunks: Array,
		vertical_bounds: Vector2i, request_revision: int) -> bool:
	if _valid or owner == null or request_revision < 0:
		return false
	_owner = owner
	_primary = primary
	_other_viewers = other_viewers
	_retained_chunks = retained_chunks
	_foreground_chunks = foreground_chunks
	_vertical_bounds = vertical_bounds
	_request_revision = request_revision
	_valid = true
	return true

func is_valid_for(primary: Dictionary, other_viewers: Array,
		retained_chunks: Array, foreground_chunks: Array,
		vertical_bounds: Vector2i, request_revision: int) -> bool:
	return _valid and is_same(primary, _primary) \
		and is_same(other_viewers, _other_viewers) \
		and is_same(retained_chunks, _retained_chunks) \
		and is_same(foreground_chunks, _foreground_chunks) \
		and vertical_bounds == _vertical_bounds \
		and request_revision == _request_revision

func invalidate() -> Dictionary:
	_valid = false
	_lease_revision += 1
	return {"valid":false, "revision":_lease_revision}

func lease_revision() -> int:
	return _lease_revision

func retained_owner():
	return _owner

## Caller releases owner-side references after a terminal transaction result.
## This lease intentionally never destroys producer-owned request data.
func release_after_drain() -> void:
	_valid = false
	_owner = null
	_primary = {}
	_other_viewers = []
	_retained_chunks = []
	_foreground_chunks = []
