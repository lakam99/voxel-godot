extends RefCounted

## Test-only admission that never dispatches or retires shared source work.
func advance() -> Dictionary:
	return {"status":"pending", "failure":""}
