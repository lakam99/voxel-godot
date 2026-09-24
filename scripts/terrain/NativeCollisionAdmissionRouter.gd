extends RefCounted
class_name NativeCollisionAdmissionRouter

const CoordinatorScript := preload("res://scripts/terrain/NativeWindowedCollisionCoordinator.gd")

## MainCore-facing aggregate admission contract. Production construction must
## wrap NativeWindowedCollisionCoordinator, never a per-window barrier.
var _aggregate: Object
var _identity: Dictionary = {}

func setup(aggregate: Object, identity: Dictionary) -> Dictionary:
	if _aggregate != null or aggregate == null \
			or not aggregate is CoordinatorScript or identity.is_empty():
		return {"status":"failed", "reason":"aggregate_admission_router_inputs_invalid"}
	for method in ["is_active", "can_unbind", "physical_receipt", "admit_motion",
			"admit_placement", "register_moving_actor"]:
		if not aggregate.has_method(method):
			return {"status":"failed", "reason":"aggregate_admission_contract_missing",
				"method":method}
	_aggregate = aggregate
	_identity = identity.duplicate(true)
	return {"status":"ready"}

func is_aggregate_admission_router() -> bool:
	return _aggregate != null

func matches_identity(identity: Dictionary) -> bool:
	return _aggregate != null and identity == _identity

func is_active() -> bool:
	return _aggregate != null and bool(_aggregate.call("is_active"))

func is_admission_ready() -> bool:
	if not is_active(): return false
	var receipt: Dictionary = _aggregate.call("physical_receipt", _identity)
	var provenance: Dictionary = receipt.get("provenance", {})
	var aggregate: Dictionary = receipt.get("aggregate", {})
	return bool(receipt.get("ready", false)) \
		and provenance.get("requestIdentity") == _identity \
		and int(receipt.get("physicsFrame", -1)) >= 0 \
		and int(aggregate.get("requiredBlockCount", 0)) > 0 \
		and int(aggregate.get("windowCount", 0)) > 0 \
		and not String(aggregate.get("logicalClosureToken", "")).is_empty() \
		and not String(aggregate.get("layoutToken", "")).is_empty() \
		and String(provenance.get("logicalClosureToken", "")) \
			== String(aggregate.get("logicalClosureToken", "")) \
		and String(provenance.get("layoutToken", "")) \
			== String(aggregate.get("layoutToken", ""))

func physical_receipt() -> Dictionary:
	if not is_active(): return {"ready":false, "reason":"aggregate_admission_inactive"}
	var receipt: Dictionary = _aggregate.call("physical_receipt", _identity)
	if not bool(receipt.get("ready", false)) or not is_admission_ready():
		return {"ready":false, "reason":receipt.get("reason", "aggregate_physical_closure_invalid")}
	return receipt

func can_unbind() -> bool:
	return _aggregate != null and bool(_aggregate.call("can_unbind"))

func admit_motion(actor: PhysicsBody3D, motion: Vector3) -> bool:
	return is_admission_ready() and bool(_aggregate.call("admit_motion", actor, motion))

func admit_placement(actor: PhysicsBody3D, transform: Transform3D) -> bool:
	return is_admission_ready() \
		and bool(_aggregate.call("admit_placement", actor, transform))

func register_moving_actor(actor: PhysicsBody3D) -> bool:
	return is_admission_ready() \
		and bool(_aggregate.call("register_moving_actor", actor))
