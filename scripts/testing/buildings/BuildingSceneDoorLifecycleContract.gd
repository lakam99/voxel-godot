extends SceneTree
## Synthetic job/scene lifecycle contract. Real building, smart-object, portal,
## traffic and traversal owners; tiny prepared proof receipts are synthetic.
## No nav/autonomy host, gameplay, source-generation or headed acceptance.
const Job = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Fixtures = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Smart = preload("res://scripts/npc_ai/interactions/SmartObjectService.gd")
const Doors = preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const Traffic = preload("res://scripts/npc_ai/traffic/TrafficReservationService.gd")
const Traversal = preload("res://scripts/npc_ai/interactions/DoorTraversalExecutor.gd")

class Host extends Node3D:
	var smart = Smart.new()
	var portals = Doors.new()
	var traffic_reservations = Traffic.new()
	var door_traversal = Traversal.new()
	var target: WeakRef
	var register_mode := "normal"
	var retire_mode := "normal"
	var fail_on := 1
	var attempts := 0
	var real_registrations := 0
	var retire_attempts := 0
	var registrations_by_body: Dictionary = {}
	var retirements_by_body: Dictionary = {}
	var candidates: Array[WeakRef] = []
	var original_children: Dictionary = {}
	var trace: Array = []
	var intact_before_retire := true
	var identity_before_call := true
	var claim_before_call := true
	var shared_survivor: StaticBody3D
	var saved_registration
	var tree_calls := 0
	var nested_receipt: Dictionary = {}
	var nested_ownership_unchanged := false
	var nested_children_intact := false
	var actual_unregister_effects := 0
	var reparent_target: Node3D

	func setup() -> void:
		portals.setup(null, self)
		smart.setup(self, portals)
		door_traversal.setup(portals, traffic_reservations)

	func emit_door_state_revision(_leaf: Node, _open: bool, _reason: String, _revision: int) -> void:
		pass # Deliberately no navigation callback in this service-level host.

	static func child_ids(node: Node) -> Array:
		var result: Array = []
		for child in node.get_children(true):
			result.append(child.get_instance_id())
			result.append_array(child_ids(child))
		return result

	func register_door(body: Node) -> Dictionary:
		attempts += 1
		var id: int = body.get_instance_id()
		var portal_id := String(body.get_meta("door_portal_id", ""))
		identity_before_call = identity_before_call and not portal_id.is_empty() and body.is_inside_tree()
		var job = target.get_ref()
		var claim: Dictionary = job._door_claims.get(id, {})
		claim_before_call = claim_before_call and claim.get("portalId") == portal_id \
			and claim.get("body") is WeakRef and claim.body.get_ref() == body
		if not original_children.has(id):
			candidates.append(weakref(body))
			original_children[id] = child_ids(body)
		trace.append(["register", id, portal_id])
		if register_mode == "pending_once" and attempts == 1:
			return {"status":"pending_budget", "sideEffects":false}
		if register_mode == "pending_unspecified":
			return {"status":"pending_budget"}
		if register_mode == "fail_before" and attempts == fail_on:
			return {"status":"failed", "reason":"injected_before_registration"}
		if register_mode == "grouped" and shared_survivor == null:
			shared_survivor = StaticBody3D.new()
			shared_survivor.name = "ExternalSurvivingLeaf"
			shared_survivor.set_meta("door_portal_id", portal_id)
			shared_survivor.set_meta("door_group_id", portal_id)
			shared_survivor.position = Vector3(2, 0, 0)
			add_child(shared_survivor)
			smart.register_door(shared_survivor)
		var registered: String = smart.register_door(body)
		real_registrations += 1
		registrations_by_body[id] = int(registrations_by_body.get(id, 0)) + 1
		if register_mode == "grouped":
			saved_registration = smart.registrations[registered]
			# Explicit synthetic ownership data: not an actor crossing claim.
			saved_registration.metadata["contract_marker"] = {"keep":[1, 2]}
			portals.portals[registered].hold("synthetic-survivor-owner")
		if register_mode == "cancel_after":
			target.get_ref().cancel()
		if register_mode in ["nested_register", "reparent_register"]:
			var before: Dictionary = job.status()
			var children_before := child_ids(body)
			nested_receipt = job.advance(4000)
			nested_ownership_unchanged = before == job.status() and job._door_claims[id].body.get_ref() == body
			nested_children_intact = children_before == child_ids(body)
			if register_mode == "reparent_register":
				# Synthetic foreign-parent violation after real registration. The
				# exact owned root still exists and must take normal teardown.
				reparent_target = Node3D.new()
				reparent_target.name = "UnownedReparentTarget"
				add_child(reparent_target)
				job.own_node_root().reparent(reparent_target)
		if register_mode == "fail_after" and attempts == fail_on:
			return {"status":"failed", "reason":"injected_after_registration"}
		if register_mode == "wrong_id":
			return {"status":"registered", "portalId":registered + ":wrong"}
		if register_mode == "pending_after":
			return {"status":"pending_budget", "sideEffects":true}
		if register_mode == "lose_root_after":
			# Intentionally violate the owner contract. The job MUST NOT claim
			# retirement; the harness later performs explicit external cleanup.
			target.get_ref().own_node_root().free()
		return {"status":"registered", "portalId":registered}

	func retire_door(body: Node) -> Dictionary:
		retire_attempts += 1
		var id: int = body.get_instance_id()
		intact_before_retire = intact_before_retire and body.is_inside_tree() \
			and original_children.has(id) and not original_children[id].is_empty() \
			and original_children[id] == child_ids(body)
		trace.append(["retire", id, child_ids(body)])
		if retire_mode == "pending": return {"status":"pending_budget", "reason":"injected_pending"}
		if retire_mode == "failure": return {"status":"failed", "reason":"injected_failure"}
		if retire_mode == "malformed": return {"status":"ready"}
		var result: Dictionary = smart.unregister_door(body)
		if result.get("status") == "unregistered": actual_unregister_effects += 1
		if retire_mode == "reentrant_once" and retire_attempts == 1:
			var job = target.get_ref()
			job.cancel()
			var before: Dictionary = job.status()
			var children_before := child_ids(body)
			nested_receipt = job.advance(4000)
			nested_ownership_unchanged = before == job.status() and job._door_claims.has(id)
			nested_children_intact = body.is_inside_tree() and children_before == child_ids(body)
			# Side effect occurred, but this attempt did not acknowledge cleanup.
			# The next call must obtain absent from THE SAME real registry.
			return {"status":"pending_budget", "reason":"synthetic_retry_after_nested_cancel"}
		if retire_mode == "failure_after":
			return {"status":"failed", "reason":"injected_after_unregister"}
		if retire_mode == "wrong_id":
			return {"status":"unregistered", "portalId":"wrong-portal"}
		if result.get("status") in ["unregistered", "absent"]:
			retirements_by_body[id] = int(retirements_by_body.get(id, 0)) + 1
		return result

	func tree_publish(_parent: Node3D, _id: String, _position: Vector3, _biome: String, _request: Dictionary, _yaw: float) -> Dictionary:
		tree_calls += 1
		return {"status":"rejected", "reason":"fixture_has_no_trees"}

	func tree_retire(_id: String, _body: Node) -> void:
		pass

	func close_services() -> void:
		# Test-fixture cleanup only, never counted as job retirement evidence.
		smart.clear()
		smart.owner = null
		smart.door_portals = null
		door_traversal.door_portals = null
		door_traversal.traffic_reservations = null
		portals.owner = null
		portals.main = null
		saved_registration = null

class Receiver extends RefCounted:
	var host: Host
	func _init(value: Host) -> void: host = value
	func register_door(body: Node) -> Dictionary: return host.register_door(body)
	func retire_door(body: Node) -> Dictionary: return host.retire_door(body)

var checks: Dictionary = {}
var traces: Dictionary = {}
var worker = Worker.new()
var external_cleanup_cases: Array[String] = []
const SOURCE_PATHS := [
	"res://scripts/buildings/BuildingScenePublicationJob.gd",
	"res://scripts/buildings/BuildingPartPublisher.gd",
	"res://scripts/buildings/BuildingPublicationPreparation.gd",
	"res://scripts/buildings/BuildingPublicationWorker.gd",
	"res://scripts/npc_ai/interactions/SmartObjectService.gd",
	"res://scripts/npc_ai/interactions/DoorPortalService.gd",
	"res://scripts/npc_ai/interactions/DoorPortal.gd",
	"res://scripts/npc_ai/interactions/DoorController.gd",
	"res://scripts/npc_ai/interactions/DoorTraversalExecutor.gd",
	"res://scripts/npc_ai/traffic/TrafficReservationService.gd",
	"res://scripts/testing/buildings/BuildingSceneDoorLifecycleContract.gd"
]

func source_hashes() -> Dictionary:
	var result := {}
	for path: String in SOURCE_PATHS: result[path] = FileAccess.get_sha256(path)
	return result

func _initialize() -> void: call_deferred("run")

func check(label: String, value: bool) -> void:
	checks[label] = value
	if not value: print("SCENE DOOR LIFECYCLE FAILURE ", label)

func fixture(count := 1, site := "scene-door-site") -> Dictionary:
	var host := Host.new()
	root.add_child(host)
	host.setup()
	var parent := Node3D.new()
	host.add_child(parent)
	var binding := {"siteId":site, "sourceKey":"scene-door-source", "generation":1}
	Fixtures.freeze(binding)
	var profile: Dictionary = Fixtures.profile()
	profile.siteId = site
	profile.origin = Vector3(10, 0, 20)
	Fixtures.freeze(profile)
	var blueprint = Blueprint.new("synthetic-scene-doors", 1, "timber")
	for index in range(count):
		blueprint.add_part({"id":"door-" + str(index), "kind":"door", "material":"timber",
			"size":Vector3(0.7, 1.8, 0.12), "position":Vector3(index * 1.1, 0.9, 0)})
	var prepared := Preparation.PreparedSource.new()
	prepared._binding = binding
	prepared._payload = {"blueprint":blueprint, "furnishingPlan":Plan.new("tiny-door-furniture", 1, blueprint.id),
		"physicalIntegrity":{"passed":true}, "raisedRouteCoverage":{"passed":true},
		"preparationUsec":0, "routeUsec":0, "physicalUsec":0}
	var job = Job.new()
	host.target = weakref(job)
	return {"host":host, "parent":parent, "binding":binding, "profile":profile, "prepared":prepared, "job":job}

func start(c: Dictionary, label: String, receiver: Object = null) -> void:
	var target: Object = c.host if receiver == null else receiver
	check(label + "_callbacks_bound", c.job.call("set_door_callbacks", Callable(target, "register_door"), Callable(target, "retire_door")))
	check(label + "_tree_cleanup_bound", c.job.set_tree_retire_callback(c.host.tree_retire))
	var begun: Dictionary = c.job.begin(c.prepared, c.profile, c.binding, c.parent, c.host.tree_publish)
	check(label + "_begun", begun.status == "pending_budget")
	c.prepared = null

func advance_terminal(c: Dictionary, label: String) -> Dictionary:
	var state: Dictionary = c.job.status()
	for index in range(4000):
		if state.sceneReady or state.status in ["failed", "cancelled"]: break
		state = c.job.advance(4000)
	check(label + "_terminal_reached", state.sceneReady or state.status in ["failed", "cancelled"])
	return state

func all_once(values: Dictionary, expected: int) -> bool:
	if values.size() != expected: return false
	for count in values.values():
		if count != 1: return false
	return true

func nodes_intact(host: Host) -> bool:
	for reference: WeakRef in host.candidates:
		var body: Node = reference.get_ref() as Node
		if not is_instance_valid(body) or not body.is_inside_tree(): return false
		if host.original_children[body.get_instance_id()] != Host.child_ids(body): return false
	return not host.candidates.is_empty()

func drain(c: Dictionary, label: String) -> void:
	for index in range(4000):
		if c.job.status().retirementReady: break
		c.job.advance(4000)
	check(label + "_job_retired", c.job.status().retirementReady and c.job.own_node_root() == null)
	if not c.job.status().retirementReady: return
	var payload: Dictionary = c.job.take_retirement_payload()
	check(label + "_payload_once", not payload.is_empty() and c.job.take_retirement_payload().is_empty())
	check(label + "_retirement_accepted", worker.retire_external_payload(payload))
	payload = {}
	var deadline := Time.get_ticks_msec() + 5000
	while worker.poll().busy and Time.get_ticks_msec() < deadline: await process_frame
	check(label + "_worker_drained", not worker.poll().busy)
	check(label + "_before_children", c.host.intact_before_retire)
	check(label + "_parent_empty", c.parent.get_child_count() == 0)

func close(c: Dictionary, label: String, external := false) -> void:
	traces[label] = c.host.trace.duplicate(true)
	if external: external_cleanup_cases.append(label)
	c.host.close_services()
	c.host.free()
	c.host = null
	c.parent = null
	c.prepared = null
	c.job = null

func success_case(count: int, suffix := "") -> void:
	var label := "success_" + str(count) + suffix
	var c := fixture(count, "scene-door-site" + suffix)
	start(c, label)
	var state := advance_terminal(c, label)
	check(label + "_ready", state.sceneReady and not state.gameplayReady)
	check(label + "_registered_once", all_once(c.host.registrations_by_body, count))
	check(label + "_claim_precedes_callback", c.host.claim_before_call and c.host.identity_before_call)
	check(label + "_status_registered", state.counts.doorsRegistered == count and state.counts.doorClaims == count and state.doorLifecycleConfigured)
	for portal_id: String in c.host.smart.registrations:
		check(label + "_site_identity_" + portal_id, portal_id.begins_with("building:scene-door-site" + suffix + ":"))
	check(label + "_actual_children", nodes_intact(c.host))
	for index in range(3): c.job.advance(4000)
	check(label + "_ready_no_repeat", c.host.attempts == count)
	c.job.cancel()
	await drain(c, label)
	check(label + "_unregistered_once", all_once(c.host.retirements_by_body, count))
	check(label + "_claims_acknowledged", c.job.status().counts.doorClaims == 0 and c.job.status().counts.doorsRetired == count)
	check(label + "_registries_empty", c.host.smart.registrations.is_empty() and c.host.portals.portals.is_empty() and c.host.portals.door_to_portal.is_empty())
	check(label + "_no_tree_work", c.host.tree_calls == 0)
	close(c, label)

func registration_case(mode: String, fail_on := 1) -> void:
	var label := "register_" + mode + "_" + str(fail_on)
	var c := fixture(3)
	c.host.register_mode = mode
	c.host.fail_on = fail_on
	start(c, label)
	var state := advance_terminal(c, label)
	if mode == "pending_once":
		check(label + "_ready_after_retry", state.sceneReady and c.host.attempts == 4 and c.host.real_registrations == 3)
		check(label + "_retry_not_duplicate", all_once(c.host.registrations_by_body, 3))
	else:
		check(label + "_not_ready", not state.sceneReady and state.status in ["failed", "cancelled"])
		check(label + "_no_later_candidate", c.host.attempts == fail_on)
	check(label + "_claim_precedes_callback", c.host.claim_before_call)
	if mode == "cancel_after":
		check(label + "_cancelled_receipt_not_accepted", state.counts.doorsRegistered == 0)
	c.job.cancel()
	await drain(c, label)
	check(label + "_every_candidate_retired", all_once(c.host.retirements_by_body, c.host.original_children.size()))
	check(label + "_no_registration_leak", c.host.smart.registrations.is_empty() and c.host.portals.portals.is_empty())
	close(c, label)

func retirement_retry_case(mode: String) -> void:
	var label := "retire_" + mode
	var c := fixture()
	start(c, label)
	check(label + "_initial_ready", advance_terminal(c, label).sceneReady)
	c.host.retire_mode = mode
	c.job.cancel()
	for index in range(30): c.job.advance(4000)
	check(label + "_retained_with_children", nodes_intact(c.host))
	check(label + "_blocked_not_retired", not c.job.status().retirementReady and not String(c.job.status().cleanupReason).is_empty())
	check(label + "_no_payload", c.job.take_retirement_payload().is_empty())
	if mode in ["failure_after", "wrong_id"]:
		check(label + "_side_effect_not_ack", c.host.smart.registrations.is_empty() and c.job.status().counts.doorClaims == 1)
	else:
		check(label + "_registration_still_live", c.host.smart.registrations.size() == 1 and c.host.portals.portals.size() == 1)
	c.host.retire_mode = "normal"
	await drain(c, label)
	check(label + "_successful_ack_once", all_once(c.host.retirements_by_body, 1))
	close(c, label)

func grouped_case() -> void:
	var c := fixture()
	c.host.register_mode = "grouped"
	start(c, "grouped")
	check("grouped_initial_ready", advance_terminal(c, "grouped").sceneReady)
	var portal_id := String(c.host.shared_survivor.get_meta("door_portal_id"))
	check("grouped_candidate_representative", c.host.saved_registration.node != c.host.shared_survivor)
	c.job.cancel()
	await drain(c, "grouped")
	check("grouped_survivor_live", is_instance_valid(c.host.shared_survivor) and c.host.shared_survivor.is_inside_tree())
	check("grouped_same_registration", is_same(c.host.smart.registrations.get(portal_id), c.host.saved_registration))
	check("grouped_representative_rebound", c.host.saved_registration.node == c.host.shared_survivor)
	check("grouped_marker_preserved", c.host.saved_registration.metadata.get("contract_marker") == {"keep":[1, 2]})
	check("grouped_hold_preserved", c.host.portals.portals[portal_id].open_holds.has("synthetic-survivor-owner"))
	check("grouped_survivor_cleanup", c.host.smart.unregister_door(c.host.shared_survivor).portalRemoved)
	close(c, "grouped")

func callback_binding_case() -> void:
	var c := fixture()
	check("callbacks_half_register_rejected", not c.job.call("set_door_callbacks", c.host.register_door, Callable()))
	check("callbacks_half_retire_rejected", not c.job.call("set_door_callbacks", Callable(), c.host.retire_door))
	check("callbacks_invalid_pair_not_configured", not c.job.status().doorLifecycleConfigured)
	check("callbacks_bound_custom_rejected", not c.job.call("set_door_callbacks", Callable(c.host, "register_door").bind(1), c.host.retire_door))
	check("callbacks_idle_retire_only_rejected", not c.job.call("set_door_retire_callback", c.host.retire_door))
	start(c, "callbacks")
	check("callbacks_active_rebind_rejected", not c.job.call("set_door_callbacks", c.host.register_door, c.host.retire_door))
	check("callbacks_ready", advance_terminal(c, "callbacks").sceneReady)
	check("callbacks_ready_retire_rebind_rejected", not c.job.call("set_door_retire_callback", c.host.retire_door))
	c.job.cancel()
	check("callbacks_teardown_pair_rebind_rejected", not c.job.call("set_door_callbacks", c.host.register_door, c.host.retire_door))
	check("callbacks_teardown_invalid_recovery_rejected", not c.job.call("set_door_retire_callback", Callable()))
	await drain(c, "callbacks")
	close(c, "callbacks")

func recovery_case() -> void:
	var c := fixture()
	var receiver := Receiver.new(c.host)
	start(c, "recovery", receiver)
	check("recovery_ready", advance_terminal(c, "recovery").sceneReady)
	var reference: WeakRef = weakref(receiver)
	receiver = null
	check("recovery_receiver_gone", reference.get_ref() == null)
	c.job.cancel()
	for index in range(20): c.job.advance(4000)
	check("recovery_blocked_intact", nodes_intact(c.host) and not c.job.status().retirementReady and not String(c.job.status().cleanupReason).is_empty())
	check("recovery_no_early_payload", c.job.take_retirement_payload().is_empty())
	check("recovery_retire_only_rebound", c.job.call("set_door_retire_callback", c.host.retire_door))
	await drain(c, "recovery")
	check("recovery_no_register_replay", c.host.attempts == 1 and all_once(c.host.retirements_by_body, 1))
	check("recovery_registries_empty", c.host.smart.registrations.is_empty() and c.host.portals.door_to_portal.is_empty())
	close(c, "recovery")

func optional_callbacks_case() -> void:
	var c := fixture()
	check("optional_default_unconfigured", not c.job.status().doorLifecycleConfigured)
	var begun: Dictionary = c.job.begin(c.prepared, c.profile, c.binding, c.parent, c.host.tree_publish)
	c.prepared = null
	check("optional_begun", begun.status == "pending_budget")
	check("optional_construction_ready", advance_terminal(c, "optional").sceneReady and c.host.attempts == 0)
	c.job.cancel()
	await drain(c, "optional")
	check("optional_no_door_cleanup_calls", c.host.retire_attempts == 0)
	close(c, "optional")

func nested_registration_cases() -> void:
	for mode: String in ["nested_register", "reparent_register"]:
		var c := fixture()
		c.host.register_mode = mode
		start(c, mode)
		var state := advance_terminal(c, mode)
		check(mode + "_nested_rejected", c.host.nested_receipt.get("status") == "rejected" and c.host.nested_receipt.get("reason") == "reentrant_advance")
		check(mode + "_nested_no_ownership_change", c.host.nested_ownership_unchanged and c.host.nested_children_intact)
		check(mode + "_one_registration", c.host.real_registrations == 1 and all_once(c.host.registrations_by_body, 1))
		if mode == "nested_register":
			check(mode + "_outer_ready", state.sceneReady and state.counts.doorsRegistered == 1)
		else:
			check(mode + "_outer_failed", state.status == "failed" and not state.sceneReady and state.reason == "registered_door_owner_changed")
			check(mode + "_receipt_not_accepted", state.counts.doorsRegistered == 0)
		c.job.cancel()
		await drain(c, mode)
		check(mode + "_one_cleanup", c.host.actual_unregister_effects == 1 and all_once(c.host.retirements_by_body, 1))
		check(mode + "_registry_empty", c.host.smart.registrations.is_empty() and c.host.portals.portals.is_empty())
		if mode == "reparent_register":
			check(mode + "_foreign_parent_preserved", is_instance_valid(c.host.reparent_target) and c.host.reparent_target.is_inside_tree() and c.host.reparent_target.get_child_count() == 0)
		close(c, mode)

func nested_retirement_case() -> void:
	var c := fixture()
	start(c, "nested_retire")
	check("nested_retire_initial_ready", advance_terminal(c, "nested_retire").sceneReady)
	c.host.retire_mode = "reentrant_once"
	c.job.cancel()
	for index in range(100):
		c.job.advance(4000)
		if c.host.retire_attempts > 0: break
	check("nested_retire_nested_rejected", c.host.nested_receipt.get("status") == "rejected" and c.host.nested_receipt.get("reason") == "reentrant_advance")
	check("nested_retire_nested_ownership_intact", c.host.nested_ownership_unchanged and c.host.nested_children_intact)
	check("nested_retire_no_free_before_ack", nodes_intact(c.host) and not c.job.status().retirementReady and c.job.status().counts.doorClaims == 1)
	check("nested_retire_no_early_payload", c.job.take_retirement_payload().is_empty())
	check("nested_retire_effect_once_unacknowledged", c.host.actual_unregister_effects == 1 and c.host.retirements_by_body.is_empty() and c.host.smart.registrations.is_empty())
	await drain(c, "nested_retire")
	check("nested_retire_absent_retry_once", c.host.retire_attempts == 2 and c.host.actual_unregister_effects == 1 and all_once(c.host.retirements_by_body, 1))
	check("nested_retire_one_claim_acknowledged", c.job.status().counts.doorsRetired == 1 and c.job.status().counts.doorClaims == 0)
	close(c, "nested_retire")

func unresolved_case(mode: String) -> void:
	var label := "unresolved_" + mode
	var c := fixture()
	var receiver := Receiver.new(c.host)
	if mode == "root": c.host.register_mode = "lose_root_after"
	start(c, label, receiver)
	var state := advance_terminal(c, label)
	if mode == "receiver":
		check(label + "_initial_ready", state.sceneReady)
		var reference: WeakRef = weakref(receiver)
		receiver = null
		check(label + "_weak_receiver_released", reference.get_ref() == null)
	if mode == "claim":
		check(label + "_initial_ready", state.sceneReady)
		c.host.candidates[0].get_ref().free() # Explicit external owner violation.
	c.job.cancel()
	for index in range(30): c.job.advance(4000)
	check(label + "_not_retired", not c.job.status().retirementReady)
	check(label + "_cleanup_reason", not String(c.job.status().cleanupReason).is_empty())
	check(label + "_no_retirement_payload", c.job.take_retirement_payload().is_empty())
	if mode == "receiver": check(label + "_children_retained", nodes_intact(c.host))
	else: check(label + "_registration_claim_remains", c.host.portals.door_to_portal.size() == 1 and c.job.status().counts.doorClaims == 1)
	receiver = null
	# This is deliberately NOT drain(): external fixture cleanup does not turn
	# an unresolved job into a successful production teardown.
	close(c, label, true)

func run() -> void:
	var output := OS.get_environment("BUILDING_SCENE_DOOR_LIFECYCLE_OUTPUT")
	if output.is_empty(): quit(2); return
	var sources_before := source_hashes()
	var started := Time.get_ticks_usec()
	var probe = Job.new()
	check("door_api_present", probe.has_method("set_door_callbacks"))
	probe = null
	if checks.door_api_present:
		await success_case(1)
		await success_case(2)
		for mode: String in ["pending_once", "pending_unspecified", "pending_after", "wrong_id", "cancel_after", "fail_before", "fail_after"]:
			await registration_case(mode)
		await registration_case("fail_after", 2)
		for mode: String in ["pending", "failure", "malformed", "failure_after", "wrong_id"]: await retirement_retry_case(mode)
		await grouped_case()
		await callback_binding_case()
		await recovery_case()
		await optional_callbacks_case()
		await nested_registration_cases()
		await nested_retirement_case()
		unresolved_case("receiver")
		unresolved_case("root")
		unresolved_case("claim")
		# New independent job/holder after earlier retirements; no consumed reuse.
		await success_case(1, "-fresh-independent")
	worker.request_shutdown()
	var deadline := Time.get_ticks_msec() + 5000
	while not worker.poll().shutdownComplete and Time.get_ticks_msec() < deadline: await process_frame
	check("worker_shutdown", worker.poll().shutdownComplete)
	check("fixture_scene_empty", root.get_child_count() == 0)
	check("sources_unchanged", sources_before == source_hashes())
	var failures: Array = []
	for label: String in checks:
		if not checks[label]: failures.append(label)
	var report := {"evidenceLevel":"synthetic scene-job/shared-door lifecycle; no nav, source or gameplay acceptance",
		"checks":checks, "checkCount":checks.size(), "failureCount":failures.size(), "failures":failures,
		"traces":traces, "externalFixtureCleanupOnly":external_cleanup_cases,
		"sourceSha256":sources_before, "elapsedUsec":Time.get_ticks_usec() - started,
		"recoveryRebindCoverage":"teardown-only set_door_retire_callback; registration never resumed", "passed":failures.is_empty(),
		"jobSha256":FileAccess.get_sha256("res://scripts/buildings/BuildingScenePublicationJob.gd"),
		"contractSha256":FileAccess.get_sha256("res://scripts/testing/buildings/BuildingSceneDoorLifecycleContract.gd")}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "\t")); file.close()
	print("SCENE DOOR LIFECYCLE checks=", checks.size(), " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
