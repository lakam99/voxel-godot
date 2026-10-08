extends SceneTree
## Synthetic retirement faults around REAL scene job/building/furniture publishers.
## Tiny prepared proof receipts, tree visuals and registry are explicit fixtures;
## not procedural tree, runtime navigation, harvest, save or headed acceptance.
const Job = preload("res://scripts/buildings/BuildingScenePublicationJob.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Fixtures = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const SOURCE_PATHS := [
	"res://scripts/buildings/BuildingScenePublicationJob.gd",
	"res://scripts/buildings/BuildingPartPublisher.gd",
	"res://scripts/buildings/FurnishingPublisher.gd",
	"res://scripts/buildings/BuildingPublicationPreparation.gd",
	"res://scripts/buildings/BuildingPublicationWorker.gd",
	"res://scripts/testing/buildings/BuildingSceneTreeRetirementContract.gd"]

class SyntheticTreeOwner extends Node3D:
	var target: WeakRef
	var mode := "normal"
	var registry: Dictionary = {}
	var bodies: Array[WeakRef] = []
	var children: Dictionary = {}
	var attempts := 0
	var effects := 0
	var all_intact := true
	var nested: Dictionary = {}
	var nested_unchanged := false
	var moved: WeakRef
	var original_parent: WeakRef
	var publish_cancel := false
	var durable_removed: Dictionary = {}
	var missing_calls := 0
	var missing_mode := "normal"
	func tree_publication_proof(body: Variant, include_installed := true) -> Dictionary:
		if not is_instance_valid(body): return {"status":"failed", "reason":"synthetic_tree_owner_lost"}
		var reference: Variant = registry.get("prop:" + String(body.get_meta("prop_id", "")))
		var ready := reference is WeakRef and reference.get_ref() == body \
			and body.get_node_or_null("GeneratedTreeVisual") != null
		return {"status":"ready" if ready else "pending", "bodyInstanceId":body.get_instance_id(),
			"sourcePrepared":ready, "installed":ready and include_installed}
	func tree_source_is_durably_removed(prop_id: String) -> bool: return durable_removed.has(prop_id)

	static func child_ids(node: Node) -> Array:
		var ids: Array = []
		for child: Node in node.get_children(true):
			ids.append(child.get_instance_id())
			ids.append_array(child_ids(child))
		return ids

	func publish(parent: Node3D, id: String, position: Vector3, _biome: String, _request: Dictionary, yaw: float) -> Dictionary:
		var body := StaticBody3D.new()
		body.position = position
		body.rotation.y = yaw
		body.set_meta("prop_id", id)
		body.set_meta("tree_visual_state", "published")
		var shape := CollisionShape3D.new()
		shape.shape = BoxShape3D.new()
		body.add_child(shape)
		var visual := Node3D.new()
		visual.name = "GeneratedTreeVisual"
		visual.add_child(Node3D.new())
		body.add_child(visual)
		parent.add_child(body)
		bodies.append(weakref(body))
		children[body.get_instance_id()] = child_ids(body)
		registry["prop:" + id] = weakref(body)
		if publish_cancel: target.get_ref().cancel()
		return {"status":"published", "body":body}

	func retire(id: String, body: StaticBody3D) -> Variant:
		attempts += 1
		if body == null:
			missing_calls += 1
			var live: WeakRef = registry.get("prop:" + id)
			if not durable_removed.has(id) or (live != null and is_instance_valid(live.get_ref())):
				return {"status":"failed", "reason":"synthetic_missing_removal_authority_or_live_replacement"}
			if missing_mode == "pending": return {"status":"pending_budget"}
			if missing_mode == "wrong_id": return {"status":"absent", "objectId":"prop:wrong"}
			if missing_mode == "cancel_once" and missing_calls == 1: target.get_ref().cancel()
			return {"status":"absent", "objectId":"prop:" + id}
		all_intact = all_intact and body.is_inside_tree() and children[body.get_instance_id()] == child_ids(body)
		if mode == "pending": return {"status":"pending_budget"}
		if mode == "failed": return {"status":"failed", "reason":"synthetic_registry_unavailable"}
		if mode == "void": return null
		if mode == "malformed": return {"status":"ready"}
		if mode == "wrong_id": return {"status":"unregistered", "objectId":"prop:wrong"}
		if mode == "absent_wrong_id": return {"status":"absent", "objectId":"prop:wrong"}
		var existed: bool = registry.erase("prop:" + id)
		if existed: effects += 1
		var job = target.get_ref()
		if mode in ["cancel_once", "nested_once"] and attempts == 1:
			if mode == "cancel_once": job.cancel()
			var before: Dictionary = job.status()
			nested = job.advance(4000)
			nested_unchanged = before == job.status() and job._tree_retirement_claims.has(body.get_instance_id()) and child_ids(body) == children[body.get_instance_id()]
		if mode in ["reparent_once", "root_move_once"] and attempts == 1:
			var node: Node = body if mode == "reparent_once" else job.own_node_root()
			moved = weakref(node)
			original_parent = weakref(node.get_parent())
			node.reparent(self)
		if mode == "free_body_once" and attempts == 1: body.free()
		if mode == "free_root_once" and attempts == 1: job.own_node_root().free()
		return {"status":"unregistered" if existed else "absent", "objectId":"prop:" + id}

	func legacy_retire(id: String, body: StaticBody3D) -> void:
		retire(id, body)

class SyntheticReceiver extends RefCounted:
	var host: SyntheticTreeOwner
	func _init(value: SyntheticTreeOwner) -> void: host = value
	func retire(id: String, body: StaticBody3D) -> Variant: return host.retire(id, body)

var checks: Dictionary = {}
var external_cleanup: Array = []
var worker = Worker.new()

func _initialize() -> void: call_deferred("run")

func check(label: String, value: bool) -> void:
	checks[label] = value
	if not value: print("TREE RETIREMENT FAILURE ", label)

func hashes() -> Dictionary:
	var result := {}
	for path: String in SOURCE_PATHS: result[path] = FileAccess.get_sha256(path)
	return result

func fixture(label: String, required := true, count := 1, publish_cancel := false) -> Dictionary:
	var host := SyntheticTreeOwner.new()
	root.add_child(host)
	host.publish_cancel = publish_cancel
	var parent := Node3D.new()
	host.add_child(parent)
	var binding := {"siteId":"tree-retirement:" + label, "sourceKey":"synthetic-source", "generation":1}
	Fixtures.freeze(binding)
	var profile: Dictionary = Fixtures.profile()
	profile.siteId = binding.siteId
	profile.origin = Vector3(10, 0, 20)
	Fixtures.freeze(profile)
	var blueprint = Blueprint.new("synthetic-tree-retirement", 1, "timber")
	blueprint.add_part({"id":"post", "kind":"post", "material":"timber_beam", "size":Vector3(0.2, 1, 0.2), "position":Vector3(0, 0.5, 0)})
	var trees: Array = []
	for index in range(count): trees.append({"id":str(index), "position":Vector3(2 + index * 2, 0, 0), "rotationY":0.0, "treeRequest":{"biome":"town"}})
	blueprint.recipe["landscapeTrees"] = trees
	var prepared := Preparation.PreparedSource.new()
	prepared._binding = binding
	prepared._payload = {"blueprint":blueprint, "furnishingPlan":Plan.new("tiny", 1, blueprint.id), "physicalIntegrity":{"passed":true}, "raisedRouteCoverage":{"passed":true}, "preparationUsec":0, "routeUsec":0, "physicalUsec":0}
	var job = Job.new()
	host.target = weakref(job)
	if required: check(label + "_bind", job.set_tree_retire_callback(host.retire, true))
	else: check(label + "_bind_default", job.set_tree_retire_callback(host.legacy_retire))
	check(label + "_begin", job.begin(prepared, profile, binding, parent, host.publish).status == "pending_budget")
	for index in range(2000):
		if job.status().sceneReady or job.status().status in ["failed", "cancelled"]: break
		job.advance(4000)
	check(label + "_publication", job.status().status == "cancelled" if publish_cancel else job.status().sceneReady)
	check(label + "_real_building_published", job.status().counts.buildingParts == 1)
	return {"job":job, "host":host, "parent":parent}

func intact(host: SyntheticTreeOwner) -> bool:
	for reference: WeakRef in host.bodies:
		var body: Node = reference.get_ref() as Node
		if not is_instance_valid(body) or SyntheticTreeOwner.child_ids(body) != host.children[body.get_instance_id()]: return false
	return true

func first_retire(c: Dictionary) -> void:
	for index in range(2000):
		if c.host.attempts > 0: break
		c.job.advance(1)

func drain(c: Dictionary, label: String) -> void:
	for index in range(2000):
		if c.job.status().retirementReady: break
		c.job.advance(4000)
	check(label + "_retired", c.job.status().retirementReady and c.job.own_node_root() == null)
	if not c.job.status().retirementReady: return
	var payload: Dictionary = c.job.take_retirement_payload()
	check(label + "_payload_once", not payload.is_empty() and c.job.take_retirement_payload().is_empty())
	check(label + "_worker_accepted", worker.retire_external_payload(payload))
	payload = {}
	var deadline := Time.get_ticks_msec() + 5000
	while worker.poll().busy and Time.get_ticks_msec() < deadline: await process_frame
	check(label + "_worker_zero", not worker.poll().busy)
	check(label + "_intact_at_every_callback", c.host.all_intact)
	check(label + "_registry_empty", c.host.registry.is_empty())
	check(label + "_one_effect_per_body", c.host.effects == c.host.bodies.size())
	c.host.free()

func fault_case(mode: String) -> void:
	var c := fixture(mode)
	c.host.mode = mode
	c.job.cancel()
	first_retire(c)
	check(mode + "_held", not c.job.status().retirementReady and c.job._tree_retirement_claims.size() == 1 and intact(c.host))
	check(mode + "_no_payload", c.job.take_retirement_payload().is_empty())
	check(mode + "_reason", c.job.status().cleanupReason == "tree_retirement_not_acknowledged")
	var attempts: int = c.host.attempts
	c.job.advance(4000)
	check(mode + "_retry_preserves", c.host.attempts == attempts + 1 and intact(c.host) and c.host.effects == 0)
	c.host.mode = "normal"
	await drain(c, mode)

func reentrant_case(mode: String) -> void:
	var c := fixture(mode)
	c.host.mode = mode
	c.job.cancel()
	first_retire(c)
	if mode == "cancel_once":
		check(mode + "_held_after_effect", c.job._tree_retirement_claims.size() == 1 and intact(c.host) and c.host.effects == 1)
		check(mode + "_reason", c.job.status().cleanupReason == "tree_retirement_reentered")
	check(mode + "_nested_rejected", c.host.nested.get("reason") == "reentrant_advance" and c.host.nested_unchanged)
	await drain(c, mode)

func ownership_case(mode: String) -> void:
	var c := fixture(mode)
	c.host.mode = mode
	c.job.cancel()
	first_retire(c)
	check(mode + "_held", not c.job.status().retirementReady and c.job._tree_retirement_claims.size() == 1 and c.job.take_retirement_payload().is_empty())
	check(mode + "_owner_lost_reason", c.job.status().cleanupReason == "tree_retirement_owner_lost")
	if mode in ["free_body_once", "free_root_once"]:
		for index in range(30): c.job.advance(4000)
		check(mode + "_never_false_retirement", not c.job.status().retirementReady and c.job._tree_retirement_claims.size() == 1)
		external_cleanup.append(mode)
		c.host.free() # Deliberate contract violation; not job retirement evidence.
	else:
		check(mode + "_children_intact", intact(c.host))
		c.host.moved.get_ref().reparent(c.host.original_parent.get_ref())
		c.host.mode = "normal"
		await drain(c, mode)

func receiver_case() -> void:
	var c := fixture("receiver_loss")
	var receiver := SyntheticReceiver.new(c.host)
	check("receiver_rebind", c.job.set_tree_retire_callback(receiver.retire, true))
	check("required_no_downgrade", not c.job.set_tree_retire_callback(c.host.legacy_retire))
	receiver = null
	c.job.cancel()
	for index in range(100):
		c.job.advance(1)
		if not c.job.status().cleanupReason.is_empty(): break
	check("receiver_loss_preserves", c.host.attempts == 0 and intact(c.host) and not c.job.status().retirementReady and c.job.status().cleanupReason == "tree_retire_callback_lost")
	check("receiver_repair_same_registry", c.job.set_tree_retire_callback(c.host.retire, true))
	await drain(c, "receiver_loss")

func missing_body_case(mode: String) -> void:
	var label := "synthetic_missing_" + mode
	var c := fixture(label)
	var body: StaticBody3D = c.host.bodies[0].get_ref() as StaticBody3D
	var id := String(body.get_meta("prop_id"))
	# Explicit AFTER-ready durable-harvest state fixture. No harvesting actor,
	# drops, tool interaction or live acceptance is simulated or claimed.
	check(label + "_was_ready", c.job.status().sceneReady)
	c.host.registry.erase("prop:" + id)
	c.host.effects += 1
	body.free()
	if mode != "unknown": c.host.durable_removed[id] = true
	c.host.missing_mode = mode
	var replacement: StaticBody3D
	if mode == "replacement":
		replacement = StaticBody3D.new()
		c.host.add_child(replacement)
		c.host.registry["prop:" + id] = weakref(replacement)
	if mode == "root_lost": c.job.own_node_root().free()
	c.job.cancel()
	for index in range(2000):
		if c.host.missing_calls > 0: break
		c.job.advance(1)
	check(label + "_null_callback_observed", c.host.missing_calls == 1)
	if mode in ["unknown", "replacement", "pending", "wrong_id", "cancel_once"]:
		check(label + "_claim_retained", not c.job.status().retirementReady and c.job._tree_retirement_claims.size() == 1 and c.job.take_retirement_payload().is_empty())
		if mode == "replacement":
			check(label + "_replacement_untouched", is_instance_valid(replacement) and replacement.is_inside_tree() and c.host.registry["prop:" + id].get_ref() == replacement)
			# Explicit fixture intervention, not a successful old-ID unregister.
			c.host.registry.erase("prop:" + id)
			replacement.free()
		c.host.durable_removed[id] = true
		c.host.missing_mode = "normal"
	await drain(c, label)

func run() -> void:
	var output := OS.get_environment("BUILDING_SCENE_TREE_RETIREMENT_OUTPUT")
	if output.is_empty(): quit(2); return
	var source_before := hashes()
	var started := Time.get_ticks_usec()
	for mode: String in ["pending", "failed", "void", "malformed", "wrong_id", "absent_wrong_id"]: await fault_case(mode)
	for mode: String in ["cancel_once", "nested_once"]: await reentrant_case(mode)
	for mode: String in ["reparent_once", "root_move_once", "free_body_once", "free_root_once"]: await ownership_case(mode)
	await receiver_case()
	for mode: String in ["durable", "unknown", "replacement", "pending", "wrong_id", "cancel_once", "root_lost"]: await missing_body_case(mode)
	for required: bool in [false, true]:
		var label := "required_two" if required else "legacy_void_two"
		var c := fixture(label, required, 2)
		c.job.cancel()
		await drain(c, label)
	var cancelled := fixture("publish_cancel", true, 1, true)
	check("publish_cancel_claim_retained", cancelled.job._tree_retirement_claims.size() == 1)
	await drain(cancelled, "publish_cancel")
	check("sources_unchanged", source_before == hashes())
	var failures: Array = []
	for label: String in checks:
		if not checks[label]: failures.append(label)
	var report := {"passed":failures.is_empty(), "checkCount":checks.size(), "failureCount":failures.size(), "checks":checks, "failures":failures, "sourceSha256":source_before, "elapsedUsec":Time.get_ticks_usec() - started, "externalFixtureCleanup":external_cleanup, "evidenceLevel":"synthetic fault/retirement contract; real job and building/furniture publishers; synthetic tree/registry and prepared proofs"}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "\t")); file.close()
	print("TREE RETIREMENT checks=", checks.size(), " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
