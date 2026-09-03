extends SceneTree
## Synthetic thin-binding evidence: real NpcSystem public methods and real
## Autonomy/SmartObject/Portal services, with no Main boot, agents or processing.
## Main's tree builder is an explicit capture stub, NOT procedural-tree proof.
const Bindings = preload("res://scripts/world/GeneratedStructureRuntimeBindings.gd")
const Npcs = preload("res://scripts/NpcSystem.gd")
const Autonomy = preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const Smart = preload("res://scripts/npc_ai/interactions/SmartObjectService.gd")
const Portals = preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")

class MainFixture extends Node3D:
	const CELL := 1.35
	var npc_system
	var player
	var startup_loading_active := false
	var runtime_loading_active := false
	var tree_publication_queue = null # Explicitly no queued work in capture-only fixtures.
	var runtime_perf_monitor = null
	var removed_props := {"durable-existing":true}
	var tree_receipt: Dictionary = {}
	var tree_capture: Dictionary = {}
	var tree_calls := 0
	func make_tree_from_runtime_request(parent: Node3D, prop_id: String, position: Vector3, biome: String, request: Dictionary, rotation_y: float) -> Dictionary:
		tree_calls+=1
		tree_capture={"parent":parent,"id":prop_id,"position":position,"biome":biome,"request":request,"rotationY":rotation_y}
		return tree_receipt

var checks: Dictionary = {}
var details: Dictionary = {}

func _initialize() -> void: call_deferred("_run")
func check(label: String, passed: bool) -> void:
	checks[label]=passed
	if not passed: print("RUNTIME BINDINGS FAILURE ",label)

func fixture() -> Dictionary:
	var main := MainFixture.new()
	root.add_child(main)
	var npc := Npcs.new()
	main.add_child(npc)
	npc.set_process(false); npc.set_physics_process(false)
	npc.main=main
	main.npc_system=npc
	# Do not call NpcSystem.setup/ensure_components or Autonomy.setup: those
	# initialize unrelated gameplay. Wire only the actual shared lifecycle APIs.
	var autonomy := Autonomy.new()
	npc.add_child(autonomy)
	autonomy.set_process(false); autonomy.set_physics_process(false)
	npc.autonomy_system=autonomy
	autonomy.npc_system=npc; autonomy.main=main
	autonomy.door_portals.setup(null,autonomy)
	autonomy.smart_objects.setup(autonomy,autonomy.door_portals)
	autonomy.door_traversal.setup(autonomy.door_portals,autonomy.traffic_reservations,autonomy.bottleneck_classifier,autonomy.traffic_priority_policy,autonomy.wait_for_graph)
	var binding := Bindings.new()
	return {"main":main,"npc":npc,"autonomy":autonomy,"binding":binding}

func close(c: Dictionary, label: String) -> void:
	check(label+"_no_agents_or_queries",c.npc.npcs.is_empty() and c.autonomy.navmesh_world.path_query_count==0)
	c.autonomy.smart_objects.clear()
	c.autonomy.shutdown_for_process_exit()
	c.autonomy.main=null; c.autonomy.npc_system=null
	c.npc.autonomy_system=null; c.npc.main=null
	c.main.tree_capture={}; c.main.tree_receipt={}; c.main.npc_system=null
	c.main.free()
	check(label+"_freed_main_unavailable",not c.binding.available() and c.binding._main.get_ref()==null)

func leaf(c: Dictionary, id: String, x: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position=Vector3(x,0,0)
	body.set_meta("door_portal_id",id)
	body.set_meta("door_group_id",id)
	body.set_meta("door_public_access",true)
	var shape := CollisionShape3D.new()
	shape.shape=BoxShape3D.new()
	body.add_child(shape)
	c.main.add_child(body)
	return body

func door_case(grouped: bool) -> void:
	var label := "grouped" if grouped else "single"
	var c := fixture()
	check(label+"_configured",c.binding.configure(c.main) and c.binding.available())
	check(label+"_same_configuration_idempotent",c.binding.configure(c.main))
	check(label+"_weak_capture_fields",c.binding._main is WeakRef and c.binding._npc is WeakRef and c.binding._autonomy is WeakRef and c.binding._smart is WeakRef and c.binding._portals is WeakRef)
	var first := leaf(c,"runtime-door",0)
	var result: Dictionary=c.binding.register_door(first)
	check(label+"_first_actual_registered",result=={"status":"registered","portalId":"runtime-door"} and c.autonomy.door_portals.door_to_portal.has(first.get_instance_id()) and c.autonomy.door_portals.portal_for_door(first).leaf_nodes.has(first))
	var last: StaticBody3D=first
	if grouped:
		last=leaf(c,"runtime-door",1.35)
		check(label+"_second_actual_registered",c.binding.register_door(last).status=="registered")
	var registration = c.autonomy.smart_objects.registrations["runtime-door"]
	registration.metadata["syntheticKeep"]={"nested":[1,2]}
	var before_metadata: Dictionary=registration.metadata.duplicate(true)
	var revision: int=c.autonomy.change_bus.monotonic_revision
	var repeated: Dictionary=c.binding.register_door(first)
	check(label+"_register_idempotent_receipt",repeated==result)
	check(label+"_no_smart_reset_or_new_event",is_same(registration,c.autonomy.smart_objects.registrations["runtime-door"]) and registration.metadata==before_metadata and c.autonomy.change_bus.monotonic_revision==revision)
	check(label+"_public_npc_deferred_flush",c.npc.navigation_change_flush_pending)
	if grouped:
		var survivor: Dictionary=c.binding.retire_door(last)
		check(label+"_nonlast_exact_receipt",survivor.status=="unregistered" and survivor.portalId=="runtime-door" and not survivor.portalRemoved and survivor.remainingLeaves==1)
		check(label+"_survivor_registration_preserved",is_same(registration,c.autonomy.smart_objects.registrations["runtime-door"]) and registration.node==first and registration.metadata==before_metadata)
		check(label+"_nonlast_not_freed",last.is_inside_tree() and last.get_child_count()==1 and not last.get_meta("destroyed",false))
		last.free()
	var final: Dictionary=c.binding.retire_door(first)
	check(label+"_final_exact_receipt",final.status=="unregistered" and final.portalId=="runtime-door" and final.portalRemoved and final.remainingLeaves==0)
	check(label+"_final_registries_empty",c.autonomy.smart_objects.registrations.is_empty() and c.autonomy.door_portals.portals.is_empty() and c.autonomy.door_portals.door_to_portal.is_empty())
	check(label+"_final_not_freed_or_destroyed",first.is_inside_tree() and first.get_child_count()==1 and not first.get_meta("destroyed",false))
	revision=c.autonomy.change_bus.monotonic_revision
	check(label+"_repeat_retirement_absent",c.binding.retire_door(first).status=="absent" and c.autonomy.change_bus.monotonic_revision==revision)
	first.free()
	check(label+"_null_door_rejected",c.binding.register_door(null).status=="failed" and c.binding.retire_door(null).status=="failed")
	close(c,label)

func replacement_cases() -> void:
	for kind: String in ["smart","portals"]:
		var c := fixture()
		check(kind+"_configured",c.binding.configure(c.main))
		var original_smart = c.autonomy.smart_objects
		var original_portals = c.autonomy.door_portals
		if kind=="smart":
			c.autonomy.smart_objects=Smart.new()
			c.autonomy.smart_objects.setup(c.autonomy,original_portals)
		else:
			c.autonomy.door_portals=Portals.new()
			c.autonomy.door_portals.setup(null,c.autonomy)
			original_smart.door_portals=c.autonomy.door_portals
		check(kind+"_replacement_unavailable",not c.binding.available())
		check(kind+"_cannot_recapture_silently",not c.binding.configure(c.main))
		var body := leaf(c,"replacement-door",0)
		var revision: int=c.autonomy.change_bus.monotonic_revision
		check(kind+"_register_rejected",c.binding.register_door(body).reason=="runtime_bindings_unavailable")
		check(kind+"_retire_rejected",c.binding.retire_door(body).reason=="runtime_bindings_unavailable")
		check(kind+"_tree_publish_rejected",c.binding.publish_tree(c.main,"tree",Vector3.ZERO,"forest",{},0.0).status=="failed" and c.main.tree_calls==0)
		check(kind+"_tree_retire_rejected",c.binding.retire_tree("tree",body).status=="failed")
		check(kind+"_new_registry_untouched",c.autonomy.smart_objects.registrations.is_empty() and c.autonomy.door_portals.portals.is_empty() and c.autonomy.change_bus.monotonic_revision==revision)
		c.autonomy.smart_objects=original_smart
		c.autonomy.door_portals=original_portals
		original_smart.door_portals=original_portals
		check(kind+"_original_identity_still_bound",c.binding.available())
		close(c,kind)

func tree_forwarding() -> void:
	var c := fixture()
	check("tree_forward_configured",c.binding.configure(c.main))
	var numbers: Array[int]=[3,1,7]
	var request := {"family":"synthetic-capture","typed":numbers,"nested":{"position":Vector3(1,2,3)},"packed":PackedFloat32Array([0.25,1.5])}
	var original := var_to_bytes(request)
	var body := StaticBody3D.new()
	c.main.add_child(body)
	for status: String in ["deferred","skipped","published"]:
		c.main.tree_receipt={"status":status,"reason":"synthetic_capture_receipt","body":body if status=="published" else null,"extra":{"preserve":[2,1]}}
		var result: Dictionary=c.binding.publish_tree(c.main,"exact-tree",Vector3(2,0,4),"oak",request,0.75)
		check(status+"_same_receipt",is_same(result,c.main.tree_receipt))
		check(status+"_exact_arguments",c.main.tree_capture.parent==c.main and c.main.tree_capture.id=="exact-tree" and c.main.tree_capture.position==Vector3(2,0,4) and c.main.tree_capture.biome=="oak" and c.main.tree_capture.rotationY==0.75)
		check(status+"_recipe_no_copy_or_mutation",is_same(request,c.main.tree_capture.request) and var_to_bytes(request)==original)
	check("tree_forward_calls_exact",c.main.tree_calls==3)
	check("tree_forward_body_preserved",c.main.tree_receipt.body==body and body.is_inside_tree())
	close(c,"tree_forward")

func tree_unbind(depleted: bool) -> void:
	var label := "depleted_tree" if depleted else "available_tree"
	var c := fixture()
	check(label+"_configured",c.binding.configure(c.main))
	var body := StaticBody3D.new()
	body.set_meta("kind","prop"); body.set_meta("prop_id","bound-tree")
	body.set_meta("material","tree"); body.set_meta("drop","logs"); body.set_meta("drop_count",3)
	c.main.add_child(body)
	c.npc.notify_navigation_prop_created("bound-tree",body)
	var registration = c.autonomy.smart_objects.registrations["prop:bound-tree"]
	if depleted: c.autonomy.smart_objects.mark_registration_removed(registration,"synthetic_preexisting_depletion")
	var durable: Dictionary=c.main.removed_props.duplicate(true)
	var result: Dictionary=c.binding.retire_tree("bound-tree",body)
	check(label+"_actual_unload_receipt",result.status==("absent" if depleted else "unregistered") and result.objectId=="prop:bound-tree")
	check(label+"_registration_retained_unbound",is_same(registration,c.autonomy.smart_objects.registrations["prop:bound-tree"]) and registration.node==null and registration.metadata.get("stale",false))
	check(label+"_depletion_preserved",registration.depleted==depleted)
	check(label+"_no_harvest_or_free",c.main.removed_props==durable and body.is_inside_tree() and not body.get_meta("destroyed",false))
	check(label+"_repeat_absent",c.binding.retire_tree("bound-tree",body).status=="absent")
	body.free()
	check(label+"_depletion_after_exit",registration.depleted==depleted)
	close(c,label)

func durably_removed_missing_tree() -> void:
	var c := fixture()
	check("harvest_absence_configured",c.binding.configure(c.main))
	var before: Dictionary=c.main.removed_props.duplicate(true)
	var revision: int=c.autonomy.change_bus.monotonic_revision
	check("harvest_existing_delta_ack",c.binding.retire_tree("durable-existing",null)=={"status":"absent","objectId":"prop:durable-existing"})
	check("harvest_unknown_id_rejected",c.binding.retire_tree("unknown-tree",null).status=="failed")
	check("harvest_empty_id_rejected",c.binding.retire_tree("",null).status=="failed")
	c.main.removed_props.erase("durable-existing")
	check("harvest_missing_delta_rejected",c.binding.retire_tree("durable-existing",null).status=="failed")
	c.main.removed_props["durable-existing"]=true # Explicit preexisting save-delta fixture, not simulated harvest.
	var replacement := StaticBody3D.new()
	replacement.set_meta("kind","prop"); replacement.set_meta("prop_id","durable-existing")
	replacement.set_meta("material","tree"); replacement.set_meta("drop","logs")
	c.main.add_child(replacement)
	c.autonomy.smart_objects.register_resource(replacement)
	var registration = c.autonomy.smart_objects.registrations["prop:durable-existing"]
	var metadata: Dictionary=registration.metadata.duplicate(true)
	check("harvest_live_replacement_rejected",c.binding.retire_tree("durable-existing",null).status=="failed")
	check("harvest_replacement_untouched",registration.node==replacement and registration.metadata==metadata and replacement.is_inside_tree())
	# A queued-for-deletion replacement is still a live Node until exit: reject.
	replacement.queue_free()
	check("harvest_queued_replacement_rejected",c.binding.retire_tree("durable-existing",null).status=="failed")
	# Free synchronously to test the same real smart tree_exiting unbinding path.
	replacement.free()
	check("harvest_delta_after_actual_exit_ack",c.binding.retire_tree("durable-existing",null)=={"status":"absent","objectId":"prop:durable-existing"})
	check("harvest_no_new_durable_state",c.main.removed_props==before)
	check("harvest_no_queue_or_navigation_side_effect",c.main.tree_publication_queue==null and c.autonomy.change_bus.monotonic_revision==revision)
	close(c,"harvest_absence")

func construction_guard() -> void:
	var c := fixture()
	check("construction_configured",c.binding.configure(c.main))
	var reservation := Rect2i(-1,-1,3,3)
	check("construction_missing_player_denied",not c.binding.construction_allowed(reservation))
	var player := CharacterBody3D.new()
	c.main.add_child(player)
	c.main.player=player
	player.set_physics_process(true) # Synthetic active flag, no motion script.
	check("construction_missing_collider_denied",not c.binding.construction_allowed(reservation))
	var collider := CollisionShape3D.new()
	collider.name="PlayerCollider"
	var capsule := CapsuleShape3D.new()
	capsule.radius=0.42; capsule.height=1.72
	collider.shape=capsule
	collider.position.y=0.86
	player.add_child(collider)
	var initial: Transform3D=player.transform
	check("construction_inside_active_denied",not c.binding.construction_allowed(reservation))
	check("construction_guard_does_not_move_player",player.transform==initial)
	check("construction_empty_reservation_denied",not c.binding.construction_allowed(Rect2i()))
	player.position.x=20.0*c.main.CELL
	check("construction_outside_allowed",c.binding.construction_allowed(reservation))
	collider.position.x=-player.position.x
	check("construction_uses_actual_collider_center",not c.binding.construction_allowed(reservation))
	collider.position.x=0.0
	player.position.x=-20.0*c.main.CELL
	check("construction_negative_outside_allowed",c.binding.construction_allowed(reservation))
	player.position.x=4.0*c.main.CELL
	check("construction_unscaled_outside",c.binding.construction_allowed(reservation))
	collider.scale=Vector3(8,1,2)
	check("construction_actual_scaled_radius_blocks",not c.binding.construction_allowed(reservation))
	collider.rotation.y=PI*0.5
	check("construction_rotated_xz_scale",c.binding.construction_allowed(reservation))
	collider.scale=Vector3.ONE; collider.rotation=Vector3.ZERO
	player.position=Vector3.ZERO
	player.set_physics_process(false)
	check("construction_disabled_without_loading_denied",not c.binding.construction_allowed(reservation))
	c.main.startup_loading_active=true
	check("construction_disabled_startup_allowed",c.binding.construction_allowed(reservation))
	c.main.startup_loading_active=false; c.main.runtime_loading_active=true
	check("construction_disabled_runtime_loading_allowed",c.binding.construction_allowed(reservation))
	player.set_physics_process(true)
	check("construction_active_runtime_loading_denied",not c.binding.construction_allowed(reservation))
	c.main.runtime_loading_active=false; c.main.startup_loading_active=true
	check("construction_active_startup_loading_denied",not c.binding.construction_allowed(reservation))
	player.set_physics_process(false)
	collider.shape=BoxShape3D.new()
	check("construction_loading_requires_capsule",not c.binding.construction_allowed(reservation))
	collider.shape=capsule
	collider.rotation.x=0.3
	check("construction_tilt_not_radius_guessed",not c.binding.construction_allowed(reservation))
	collider.rotation=Vector3.ZERO
	var smart = c.autonomy.smart_objects
	c.autonomy.smart_objects=Smart.new()
	check("construction_registry_replacement_denied",not c.binding.construction_allowed(reservation))
	c.autonomy.smart_objects=smart
	close(c,"construction")

func _run() -> void:
	var started := Time.get_ticks_msec()
	var blank := Bindings.new()
	check("unconfigured_unavailable",not blank.available() and not blank.configure(null))
	door_case(false)
	door_case(true)
	replacement_cases()
	tree_forwarding()
	tree_unbind(false)
	tree_unbind(true)
	durably_removed_missing_tree()
	construction_guard()
	var failures: Array=[]
	for label: String in checks:
		if not checks[label]: failures.append(label)
	var hashes: Dictionary={}
	for path: String in ["scripts/world/GeneratedStructureRuntimeBindings.gd","scripts/NpcSystem.gd","scripts/npc_ai/NpcAutonomySystem.gd","scripts/npc_ai/interactions/DoorPortalService.gd","scripts/npc_ai/interactions/SmartObjectService.gd","scripts/testing/buildings/GeneratedStructureRuntimeBindingsContract.gd"]:
		hashes[path]=FileAccess.get_sha256("res://"+path)
	var report := {"schema":"generated-structure-runtime-bindings/v1","complete":true,"passed":failures.is_empty(),"checkCount":checks.size(),"checks":checks,"failures":failures,"sourceHashes":hashes,"elapsedMsec":Time.get_ticks_msec()-started,
		"evidenceLevel":"Synthetic Main capture host, actual NpcSystem public lifecycle forwarding and Autonomy/SmartObject/Portal services with processing disabled",
		"doesNotProve":"No Main boot, procedural-tree recipe/publication, source generation, gameplay readiness, active actors, movement/navigation queries, or headed acceptance. Depletion is explicit preexisting synthetic state. Weak Main storage is inspected; Node death is liveness evidence, not RefCounted lifetime proof."}
	var path := OS.get_environment("GENERATED_STRUCTURE_RUNTIME_BINDINGS_OUTPUT")
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:
		push_error("Cannot write GENERATED_STRUCTURE_RUNTIME_BINDINGS_OUTPUT: "+path)
		quit(1)
		return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("RUNTIME BINDINGS COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"failures":failures}))
	quit(0 if report.passed else 1)
