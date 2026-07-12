extends RefCounted
class_name NpcOrderAcceptance

const STATUS_ACCEPTED := "accepted"
const STATUS_REJECTED := "rejected"
const STATUS_CANCELLED := "cancelled"
const VALID_STATUSES := [STATUS_ACCEPTED, STATUS_REJECTED, STATUS_CANCELLED]

# Acceptance proves that intent was retained. Route readiness remains a separate authority.
static func accepted(order_id: String, order_kind: String, reason := "") -> Dictionary:
	return make(STATUS_ACCEPTED, order_id, order_kind, reason, "")

static func rejected(order_kind: String, reason: String, failure_reason: String) -> Dictionary:
	return make(STATUS_REJECTED, "", order_kind, reason, failure_reason)

static func cancelled(order_id: String, order_kind: String, reason: String) -> Dictionary:
	return make(STATUS_CANCELLED, order_id, order_kind, reason, "")

static func make(status: String, order_id: String, order_kind: String, reason: String, failure_reason: String) -> Dictionary:
	var normalized_status := status.strip_edges()
	return {
		"ok": normalized_status == STATUS_ACCEPTED,
		"accepted": normalized_status == STATUS_ACCEPTED,
		"status": normalized_status,
		"orderId": order_id.strip_edges(),
		"orderKind": order_kind.strip_edges(),
		"reason": reason.strip_edges(),
		"failureReason": failure_reason.strip_edges(),
		"routeReadinessOwnedSeparately": true
	}

static func from_scripted_order(order) -> Dictionary:
	if not (order is Dictionary):
		return rejected("", "invalid_order", "order_not_dictionary")
	var value: Dictionary = order
	var lifecycle_state := String(value.get("state", "")).to_upper()
	var order_id := String(value.get("id", ""))
	var order_kind := String(value.get("kind", ""))
	var reason := String(value.get("reason", ""))
	if lifecycle_state in ["PENDING", "ACTIVE", "ARRIVED"]:
		return accepted(order_id, order_kind, reason)
	if lifecycle_state == "CANCELLED":
		return cancelled(order_id, order_kind, reason)
	return rejected(order_kind, reason, String(value.get("failureReason", lifecycle_state.to_lower())))

static func validate(value) -> Dictionary:
	var problems: Array[String] = []
	if not (value is Dictionary):
		return {"ok": false, "problems": ["order acceptance must be a dictionary"]}
	var result: Dictionary = value
	for key in ["ok", "accepted", "status", "orderId", "orderKind", "reason", "failureReason", "routeReadinessOwnedSeparately"]:
		if not result.has(key):
			problems.append("missing %s" % key)
	var status := String(result.get("status", ""))
	if not VALID_STATUSES.has(status):
		problems.append("invalid order acceptance status: %s" % status)
	if String(result.get("orderKind", "")).strip_edges() == "":
		problems.append("missing orderKind")
	if not bool(result.get("routeReadinessOwnedSeparately", false)):
		problems.append("route readiness must remain separately owned")
	for forbidden_key in ["routeState", "routeStatus", "routeReady", "routeReason"]:
		if result.has(forbidden_key):
			problems.append("order acceptance must not contain %s" % forbidden_key)
	if status == STATUS_ACCEPTED:
		if not bool(result.get("ok", false)) or not bool(result.get("accepted", false)):
			problems.append("accepted result must set ok=true and accepted=true")
		if String(result.get("orderId", "")).strip_edges() == "":
			problems.append("accepted result must include orderId")
	else:
		if bool(result.get("ok", true)) or bool(result.get("accepted", true)):
			problems.append("non-accepted result must set ok=false and accepted=false")
	if status == STATUS_REJECTED and String(result.get("failureReason", "")).strip_edges() == "":
		problems.append("rejected result must include failureReason")
	return {"ok": problems.is_empty(), "problems": problems}
