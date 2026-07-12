extends RefCounted
class_name StartupReadinessResult

const STATUS_READY := "ready"
const STATUS_PENDING := "pending"
const STATUS_FAILED := "failed"
const VALID_STATUSES := [STATUS_READY, STATUS_PENDING, STATUS_FAILED]

static func ready(manifest: Dictionary, metrics := {}) -> Dictionary:
	return make(STATUS_READY, "", manifest, [], metrics)

static func pending(reason: String, manifest: Dictionary, pending_items: Array, metrics := {}) -> Dictionary:
	return make(STATUS_PENDING, reason, manifest, pending_items, metrics)

static func failed(reason: String, manifest := {}, pending_items := [], metrics := {}) -> Dictionary:
	return make(
		STATUS_FAILED,
		reason,
		manifest if manifest is Dictionary else {},
		pending_items if pending_items is Array else [],
		metrics
	)

static func make(status: String, reason: String, manifest: Dictionary, pending_items: Array, metrics := {}) -> Dictionary:
	var normalized_status := status.strip_edges()
	var normalized_pending: Array = pending_items.duplicate(true)
	return {
		"ok": normalized_status == STATUS_READY,
		"status": normalized_status,
		"reason": reason.strip_edges(),
		"manifest": manifest.duplicate(true),
		"pending": normalized_pending,
		"metrics": metrics.duplicate(true) if metrics is Dictionary else {}
	}

static func validate(value) -> Dictionary:
	var problems: Array[String] = []
	if not (value is Dictionary):
		return {"ok": false, "problems": ["startup result must be a dictionary"]}
	var result: Dictionary = value
	for key in ["ok", "status", "reason", "manifest", "pending", "metrics"]:
		if not result.has(key):
			problems.append("missing %s" % key)
	var status := String(result.get("status", ""))
	if not VALID_STATUSES.has(status):
		problems.append("invalid startup status: %s" % status)
	if not (result.get("manifest", {}) is Dictionary):
		problems.append("manifest must be a dictionary")
	if not (result.get("pending", []) is Array):
		problems.append("pending must be an array")
	if not (result.get("metrics", {}) is Dictionary):
		problems.append("metrics must be a dictionary")
	var pending_items: Array = result.get("pending", []) if result.get("pending", []) is Array else []
	if status == STATUS_READY:
		if not bool(result.get("ok", false)):
			problems.append("ready result must set ok=true")
		if not pending_items.is_empty():
			problems.append("ready result must not contain pending items")
	elif status == STATUS_PENDING:
		if bool(result.get("ok", true)):
			problems.append("pending result must set ok=false")
		if String(result.get("reason", "")).strip_edges() == "":
			problems.append("pending result must include a reason")
		if pending_items.is_empty():
			problems.append("pending result must identify pending requirements")
	elif status == STATUS_FAILED:
		if bool(result.get("ok", true)):
			problems.append("failed result must set ok=false")
		if String(result.get("reason", "")).strip_edges() == "":
			problems.append("failed result must include a reason")
	return {"ok": problems.is_empty(), "problems": problems}
