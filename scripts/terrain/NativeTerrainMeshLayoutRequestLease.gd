extends RefCounted
class_name NativeTerrainMeshLayoutRequestLease

## Planner-issued O(1) snapshot lease. The planner prevents accepted-plan
## replacement while this lease is live; each builder advance also verifies
## object identity, logical revision, and closure token before reading input.
var _required_order: Array = []
var _revision := -1
var _closure_token := ""
var _valid := false

func acquire(required_order: Array, revision: int, closure_token: String) -> bool:
	if _valid or revision <= 0:
		return false
	_required_order = required_order
	_revision = revision
	_closure_token = closure_token
	_valid = true
	return true

func is_valid_for(required_order: Array, revision: int, closure_token: String) -> bool:
	return _valid and is_same(required_order, _required_order) \
		and revision == _revision and closure_token == _closure_token

func invalidate() -> void:
	_valid = false

func release_after_drain() -> void:
	_valid = false
	_required_order = []
	_revision = -1
	_closure_token = ""
