extends SceneTree
## Synthetic SceneTree/service contract only. Real portal/controller/traffic/
## traversal owners, real traffic grants and queues; crossing records are
## explicitly injected state, NOT a live NPC crossing or gameplay acceptance.
const Service = preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const Portal = preload("res://scripts/npc_ai/interactions/DoorPortal.gd")
const Traffic = preload("res://scripts/npc_ai/traffic/TrafficReservationService.gd")
const Traversal = preload("res://scripts/npc_ai/interactions/DoorTraversalExecutor.gd")

class Owner extends Node3D:
	var traffic_reservations
	var door_traversal
	var revisions: Array = []
	func emit_door_state_revision(leaf: Node, open: bool, reason: String, revision: int) -> void:
		revisions.append({"leaf":leaf.get_instance_id(),"open":open,"reason":reason,"revision":revision})

var checks := {}
var metrics := {}

func _initialize() -> void: call_deferred("_run")

func check(label: String, passed: bool) -> void:
	checks[label]=passed
	if not passed: print("DOOR UNREGISTRATION FAILURE ",label)

func fixture() -> Dictionary:
	var owner := Owner.new()
	root.add_child(owner)
	var service := Service.new()
	var traffic := Traffic.new()
	var traversal := Traversal.new()
	owner.traffic_reservations=traffic
	owner.door_traversal=traversal
	service.setup(null,owner)
	traversal.setup(service,traffic)
	return {"owner":owner,"service":service,"traffic":traffic,"traversal":traversal}

func leaf(c: Dictionary, id: String, index := 0, origin := Vector3.ZERO) -> StaticBody3D:
	var door := StaticBody3D.new()
	door.name="DoorLeaf"+str(index)
	door.position=origin+Vector3(index*1.35,0,0)
	door.set_meta("cell",Vector3i(index,0,0))
	door.set_meta("door_portal_id",id)
	door.set_meta("door_group_id",id)
	door.set_meta("door_public_access",true)
	door.set_meta("closed_rotation",0.0)
	var pivot := Node3D.new()
	pivot.name="DoorPivot"
	door.add_child(pivot)
	var collision := CollisionShape3D.new()
	collision.shape=BoxShape3D.new()
	door.add_child(collision)
	c.owner.add_child(door)
	check("register_"+id+"_"+str(index),c.service.register_door(door)==id)
	return door

func close_fixture(c: Dictionary, label: String) -> void:
	c.service.clear()
	c.traversal.active_crossings.clear()
	c.traversal.door_portals=null
	c.traversal.traffic_reservations=null
	c.service.owner=null
	c.service.main=null
	c.owner.traffic_reservations=null
	c.owner.door_traversal=null
	c.owner.free()
	check(label+"_registry_cleared",c.service.portals.is_empty() and c.service.controllers.is_empty() and c.service.door_to_portal.is_empty())

func geometry(portal) -> Dictionary:
	return {"threshold":portal.threshold_bounds,"sweep":portal.sweep_bounds,"clearance":portal.clearance_bounds,"slots":portal.approach_slots.duplicate(true),"axis":portal.crossing_axis}

func logical(portal) -> Dictionary:
	return {"state":portal.state,"revision":portal.state_revision,"locked":portal.locked,"jammed":portal.jammed,"destroyed":portal.destroyed,"unloaded":portal.unloaded,"holds":portal.open_holds.duplicate(true),"queue":portal.queued_actors.duplicate(true),"active":portal.active_crossing.duplicate(true)}

func seed_portal_state(c: Dictionary, door: Node, id: String) -> void:
	c.service.request_door_state(door,true)
	var portal = c.service.portals[id]
	portal.hold("shared-actor")
	portal.queue("waiting-actor","z-")
	portal.active_crossing={"actorId":"shared-actor","portalId":id,"direction":"z+","syntheticInjected":true}
	c.service.schedule_close_for_portal(id,99.0)

func single_and_identity() -> void:
	var c := fixture()
	var door := leaf(c,"single")
	var portal = c.service.portals.single
	var controller = c.service.controllers.single
	seed_portal_state(c,door,"single")
	var before_revision: int=c.owner.revisions.size()
	var spoof := StaticBody3D.new()
	spoof.set_meta("door_portal_id","single")
	c.owner.add_child(spoof)
	var before := logical(portal)
	var unknown: Dictionary=c.service.unregister_door(spoof)
	check("spoof_absent_not_registered",unknown.status=="absent" and c.service.door_to_portal.size()==1)
	check("spoof_preserves_known_portal",c.service.portals.single==portal and logical(portal)==before)
	var null_result: Dictionary=c.service.unregister_door(null)
	check("null_failed_closed",null_result.status=="failed" and null_result.reason=="invalid_door")
	# A registered node's spoofed metadata must not redirect its cleanup.
	door.set_meta("door_portal_id","not-the-registry-id")
	var result: Dictionary=c.service.unregister_door(door)
	check("single_receipt",result.status=="unregistered" and result.portalId=="single" and result.portalRemoved and result.remainingLeaves==0)
	check("single_before_free",is_instance_valid(door) and door.get_parent()==c.owner)
	check("single_maps_and_close_removed",not c.service.portals.has("single") and not c.service.controllers.has("single") and not c.service.door_to_portal.has(door.get_instance_id()) and not c.service.scheduled_closes.has("single"))
	check("single_old_portal_ownership_empty",portal.leaf_nodes.is_empty() and portal.open_holds.is_empty() and portal.queued_actors.is_empty() and portal.active_crossing.is_empty())
	check("single_no_destroy_state",not portal.destroyed and not door.get_meta("destroyed",false))
	check("single_no_state_callbacks",c.owner.revisions.size()==before_revision)
	check("single_detached_controller",controller.portal==null and not controller.state_changed_callback.is_valid())
	check("single_retired_not_traversable",portal.unloaded and String(portal.state)=="unloaded")
	check("duplicate_absent",c.service.unregister_door(door).status=="absent")
	door.free()
	var fresh := leaf(c,"single",2)
	check("fresh_portal_and_controller",c.service.portals.single!=portal and c.service.controllers.single!=controller)
	check("fresh_closed_unheld",String(c.service.portals.single.state)=="closed" and c.service.portals.single.open_holds.is_empty() and c.service.portals.single.queued_actors.is_empty() and c.service.portals.single.active_crossing.is_empty() and not c.service.scheduled_closes.has("single"))
	check("fresh_unregister",c.service.unregister_door(fresh).status=="unregistered")
	close_fixture(c,"single")

func double_survivor() -> void:
	var c := fixture()
	var left := leaf(c,"double",0)
	var right := leaf(c,"double",1)
	seed_portal_state(c,left,"double")
	var portal = c.service.portals.double
	var controller = c.service.controllers.double
	var grant: Dictionary=c.traffic.request_portal_crossing(portal,"shared-actor","z+",{"ownerGeneration":1,"duration":10.0,"latestStart":0.0})
	var wait: Dictionary=c.traffic.request_portal_crossing(portal,"waiting-actor","z-",{"ownerGeneration":1,"duration":1.0,"latestStart":0.0})
	check("double_actual_grant_queue",grant.get("ok",false) and not wait.get("ok",false) and c.traffic.queued_owners_for_portal("double").has("waiting-actor"))
	c.traversal.active_crossings["synthetic:double"]={"portalId":"double","actorId":"shared-actor","groupId":grant.get("groupId",""),"syntheticInjected":true}
	var traffic_before := portal_traffic(c,"double")
	var crossings_before: Dictionary=c.traversal.active_crossings.duplicate(true)
	var expected := logical(portal)
	var revision_count: int=c.owner.revisions.size()
	var survivor_meta := {"open":right.get_meta("open"),"state":right.get_meta("door_state"),"revision":right.get_meta("door_state_revision"),"pivot":right.get_node("DoorPivot").transform}
	var reference := Portal.new()
	reference.add_leaf(right)
	var expected_geometry := geometry(reference)
	var result: Dictionary=c.service.unregister_door(left)
	check("double_survivor_receipt",result.status=="unregistered" and result.portalId=="double" and not result.portalRemoved and result.remainingLeaves==1)
	check("double_same_controller_and_portal",c.service.controllers.double==controller and c.service.portals.double==portal and controller.portal==portal)
	check("double_logical_state_preserved",logical(portal)==expected)
	check("double_survivor_geometry",geometry(portal)==expected_geometry and portal.leaf_nodes==[right] and portal.leaf_ids==[String(right.name)] and portal.leaf_cells==[Vector3i(1,0,0)])
	check("double_survivor_registry",c.service.door_to_portal.size()==1 and c.service.door_to_portal.get(right.get_instance_id())=="double")
	check("double_survivor_visual_state",right.get_meta("open")==survivor_meta.open and right.get_meta("door_state")==survivor_meta.state and right.get_meta("door_state_revision")==survivor_meta.revision and right.get_node("DoorPivot").transform==survivor_meta.pivot)
	check("double_scheduled_close_preserved",c.service.scheduled_closes.get("double")==99.0)
	check("double_no_callback",c.owner.revisions.size()==revision_count)
	check("double_nonlast_traffic_preserved",portal_traffic(c,"double")==traffic_before and c.traversal.active_crossings==crossings_before)
	left.free()
	result=c.service.unregister_door(right)
	check("double_last_removed",result.status=="unregistered" and result.portalRemoved and result.remainingLeaves==0 and c.service.portals.is_empty() and c.service.controllers.is_empty() and c.service.scheduled_closes.is_empty())
	check("double_last_state_cleared",portal.open_holds.is_empty() and portal.queued_actors.is_empty() and portal.active_crossing.is_empty())
	check("double_last_traffic_cleared",c.traffic.reservations_by_id.is_empty() and c.traffic.queues_by_resource.is_empty() and c.traversal.active_crossings.is_empty())
	close_fixture(c,"double")

func portal_traffic(c: Dictionary, id: String) -> Dictionary:
	var reservations := {}
	for key in c.traffic.reservations_by_id:
		var reservation = c.traffic.reservations_by_id[key]
		if reservation.metadata.get("portalId")==id: reservations[key]=reservation.to_summary()
	var queues := {}
	for spec: Dictionary in c.traffic.classifier.portal_resources(c.service.portals[id],"z+"):
		if c.traffic.queues_by_resource.has(spec.resourceId): queues[spec.resourceId]=c.traffic.queues_by_resource[spec.resourceId].duplicate(true)
	# Include both directions, not prefix matching.
	for spec: Dictionary in c.traffic.classifier.portal_resources(c.service.portals[id],"z-"):
		if c.traffic.queues_by_resource.has(spec.resourceId): queues[spec.resourceId]=c.traffic.queues_by_resource[spec.resourceId].duplicate(true)
	return {"reservations":reservations,"queues":queues}

func traffic_isolation() -> void:
	var c := fixture()
	var a := leaf(c,"a")
	var child := leaf(c,"a:child",1,Vector3(10,0,0))
	seed_portal_state(c,a,"a")
	seed_portal_state(c,child,"a:child")
	var granted := {}
	for id: String in ["a","a:child"]:
		var portal = c.service.portals[id]
		var grant: Dictionary=c.traffic.request_portal_crossing(portal,"shared-actor","z+",{"ownerGeneration":1,"duration":10.0,"earliestStart":0.0,"latestStart":0.0})
		check(id+"_real_traffic_granted",grant.get("ok",false))
		granted[id]=grant
		var wait: Dictionary=c.traffic.request_portal_crossing(portal,"waiting-actor","z-",{"ownerGeneration":1,"duration":1.0,"earliestStart":0.0,"latestStart":0.0})
		check(id+"_real_traffic_queued",not wait.get("ok",false) and c.traffic.queued_owners_for_portal(id).has("waiting-actor"))
		# Crossings are injected only to exercise exact executor retirement scope.
		c.traversal.active_crossings["synthetic:"+id]={"portalId":id,"actorId":"shared-actor","groupId":String(grant.get("groupId","")),"syntheticInjected":true}
	var child_portal = c.service.portals["a:child"]
	var before := portal_traffic(c,"a:child")
	var child_state := logical(child_portal)
	var child_controller = c.service.controllers["a:child"]
	var child_crossing: Dictionary=c.traversal.active_crossings["synthetic:a:child"].duplicate(true)
	var actor_request: Dictionary=c.traffic.owner_requests["waiting-actor"].duplicate(true)
	var other_wait: Array=c.traffic.wait_graph.waiter_to_blockers.get("waiting-actor",[]).duplicate()
	c.traffic.cycle_resolution_by_owner["waiting-actor"]={"kind":"retreat","syntheticInjected":true,"portalId":"a:child"}
	var target_wait: Dictionary=c.traffic.request_portal_crossing(c.service.portals.a,"target-only-waiter","z-",{"ownerGeneration":1,"duration":1.0,"latestStart":0.0})
	check("traffic_target_only_wait_real",not target_wait.get("ok",false) and c.traffic.owner_requests.has("target-only-waiter"))
	c.traffic.cycle_resolution_by_owner["target-only-waiter"]={"kind":"retreat","syntheticInjected":true,"portalId":"a"}
	var callbacks: int=c.owner.revisions.size()
	var result: Dictionary=c.service.unregister_door(a)
	check("traffic_last_leaf_removed",result.status=="unregistered" and result.portalRemoved)
	check("traffic_prefix_child_exact",portal_traffic(c,"a:child")==before)
	check("traffic_same_actor_other_crossing",c.traversal.active_crossings.size()==1 and c.traversal.active_crossings.get("synthetic:a:child")==child_crossing)
	check("traffic_child_controller_state_preserved",c.service.controllers["a:child"]==child_controller and logical(child_portal)==child_state and c.service.scheduled_closes.get("a:child")==99.0)
	check("traffic_unrelated_owner_request_preserved",c.traffic.owner_requests.get("waiting-actor")==actor_request)
	check("traffic_unrelated_wait_cycle_preserved",c.traffic.wait_graph.waiter_to_blockers.get("waiting-actor",[])==other_wait and c.traffic.cycle_resolution_by_owner.has("waiting-actor"))
	check("traffic_target_wait_cycle_request_removed",not c.traffic.owner_requests.has("target-only-waiter") and not c.traffic.wait_graph.waiter_to_blockers.has("target-only-waiter") and not c.traffic.cycle_resolution_by_owner.has("target-only-waiter"))
	var target_left := false
	for reservation in c.traffic.reservations_by_id.values(): target_left=target_left or reservation.metadata.get("portalId")=="a"
	check("traffic_target_grants_removed",not target_left and not c.traffic.reservations_by_group.has(granted.a.groupId))
	check("traffic_target_queue_removed",c.traffic.queued_owners_for_portal("a").is_empty())
	check("traffic_no_destroy_callbacks",c.owner.revisions.size()==callbacks and not child_portal.destroyed)
	check("traffic_child_last_removed",c.service.unregister_door(child).portalRemoved)
	check("traffic_all_portal_ownership_drained",c.traffic.reservations_by_id.is_empty() and c.traffic.reservations_by_group.is_empty() and c.traffic.reservations_by_resource.is_empty() and c.traffic.queues_by_resource.is_empty() and c.traversal.active_crossings.is_empty())
	check("traffic_last_wait_policy_drained",c.traffic.owner_requests.is_empty() and c.traffic.wait_graph.waiter_to_blockers.is_empty() and c.traffic.cycle_resolution_by_owner.is_empty())
	metrics.traffic=c.traffic.stats()
	close_fixture(c,"traffic")

func freed_peer_control() -> void:
	var c := fixture()
	var live := leaf(c,"freed-peer")
	var peer := leaf(c,"freed-peer",1)
	var peer_id := peer.get_instance_id()
	var portal = c.service.portals["freed-peer"]
	peer.free()
	var result: Dictionary=c.service.unregister_door(live)
	check("freed_peer_pruned_before_last_removal",result.status=="unregistered" and result.portalRemoved and result.remainingLeaves==0 and not c.service.door_to_portal.has(peer_id))
	check("freed_peer_closed_to_future_use",portal.unloaded and portal.leaf_nodes.is_empty() and c.service.portals.is_empty() and is_instance_valid(live))
	metrics.freedPeer={"receipt":result,"staleRegistryEntry":c.service.door_to_portal.has(peer_id)}
	close_fixture(c,"freed_peer")

func latest_wait_target_control() -> void:
	var c := fixture()
	var target := leaf(c,"latest-wait")
	var other := leaf(c,"latest-wait:child",1,Vector3(10,0,0))
	seed_portal_state(c,other,"latest-wait:child")
	var other_portal = c.service.portals["latest-wait:child"]
	var other_grant: Dictionary=c.traffic.request_portal_crossing(other_portal,"same-actor","z+",{"ownerGeneration":1,"duration":10.0,"latestStart":0.0})
	check("latest_wait_other_grant_real",other_grant.get("ok",false))
	# Synthetic executor ownership corresponds to that real unrelated grant.
	c.traversal.active_crossings["synthetic:latest-other"]={"portalId":"latest-wait:child","actorId":"same-actor","groupId":other_grant.get("groupId",""),"syntheticInjected":true}
	var target_portal = c.service.portals["latest-wait"]
	var blocker: Dictionary=c.traffic.request_portal_crossing(target_portal,"blocking-actor","z+",{"ownerGeneration":1,"duration":10.0,"latestStart":0.0})
	var latest: Dictionary=c.traffic.request_portal_crossing(target_portal,"same-actor","z-",{"ownerGeneration":1,"duration":1.0,"latestStart":0.0})
	check("latest_wait_target_real_queue",blocker.get("ok",false) and not latest.get("ok",false) and c.traffic.queued_owners_for_portal("latest-wait").has("same-actor"))
	check("latest_wait_target_request_and_graph",c.traffic.owner_requests["same-actor"].metadata.portalId=="latest-wait" and c.traffic.wait_graph.waiter_to_blockers.get("same-actor",[]).has("blocking-actor"))
	c.traffic.cycle_resolution_by_owner["same-actor"]={"kind":"retreat","syntheticInjected":true,"portalId":"latest-wait"}
	var old_traffic := portal_traffic(c,"latest-wait:child")
	var old_state := logical(other_portal)
	var old_crossings: Dictionary=c.traversal.active_crossings.duplicate(true)
	var other_controller = c.service.controllers["latest-wait:child"]
	var result: Dictionary=c.service.unregister_door(target)
	check("latest_wait_target_removed",result.status=="unregistered" and result.portalRemoved)
	check("latest_wait_unrelated_grants_exact",portal_traffic(c,"latest-wait:child")==old_traffic and c.traffic.reservations_by_group.has(other_grant.groupId))
	check("latest_wait_same_actor_other_executor_exact",c.traversal.active_crossings==old_crossings)
	check("latest_wait_other_controller_holds_exact",c.service.controllers["latest-wait:child"]==other_controller and logical(other_portal)==old_state)
	check("latest_wait_only_target_policy_removed",not c.traffic.owner_requests.has("same-actor") and not c.traffic.wait_graph.waiter_to_blockers.has("same-actor") and not c.traffic.cycle_resolution_by_owner.has("same-actor") and c.traffic.queued_owners_for_portal("latest-wait").is_empty())
	check("latest_wait_other_leaf_alive",is_instance_valid(other) and is_instance_valid(target))
	check("latest_wait_other_last_removed",c.service.unregister_door(other).portalRemoved)
	check("latest_wait_final_traffic_empty",c.traffic.reservations_by_id.is_empty() and c.traffic.queues_by_resource.is_empty() and c.traversal.active_crossings.is_empty())
	close_fixture(c,"latest_wait")

func direct_resource_control() -> void:
	var c := fixture()
	var door := leaf(c,"direct-resource")
	var resources: Array=[{"resourceId":"portal:direct-resource:threshold","resourceKind":"door_threshold","capacity":1,"direction":"z+"}]
	var blocker: Dictionary=c.traffic.request_resources("direct-blocker",resources,{"ownerGeneration":1,"groupId":"direct-blocker-group","duration":10.0,"latestStart":0.0})
	var span: Dictionary=c.traffic.request_span("direct-waiter","unrelated-span",{"ownerGeneration":1,"duration":10.0,"latestStart":0.0})
	var span_ids: Array=c.traffic.reservations_by_group.get(span.groupId,[]).duplicate()
	var before := {}
	for id in span_ids: before[id]=c.traffic.reservations_by_id[id].to_summary()
	var wait: Dictionary=c.traffic.request_resources("direct-waiter",resources,{"ownerGeneration":1,"groupId":"direct-wait-group","duration":1.0,"latestStart":0.0})
	check("direct_resource_real_grant_and_wait",blocker.get("ok",false) and span.get("ok",false) and not wait.get("ok",false) and c.traffic.queued_owners_for_portal("direct-resource").has("direct-waiter"))
	check("direct_resource_request_no_portal_metadata",not c.traffic.owner_requests["direct-waiter"].get("metadata",{}).has("portalId"))
	c.traffic.cycle_resolution_by_owner["direct-waiter"]={"kind":"retreat","syntheticInjected":true}
	var result: Dictionary=c.service.unregister_door(door)
	check("direct_resource_unregistered",result.status=="unregistered" and result.portalRemoved)
	check("direct_resource_waiter_policy_cleared",not c.traffic.owner_requests.has("direct-waiter") and not c.traffic.wait_graph.waiter_to_blockers.has("direct-waiter") and not c.traffic.cycle_resolution_by_owner.has("direct-waiter") and c.traffic.queued_owners_for_portal("direct-resource").is_empty())
	var after := {}
	for id in span_ids:
		if c.traffic.reservations_by_id.has(id): after[id]=c.traffic.reservations_by_id[id].to_summary()
	check("direct_resource_same_actor_span_exact",not before.is_empty() and after==before and c.traffic.reservations_by_group.get(span.groupId)==span_ids)
	check("direct_resource_target_groups_removed",not c.traffic.reservations_by_group.has("direct-blocker-group") and not c.traffic.reservations_by_group.has("direct-wait-group"))
	c.traffic.release_group(span.groupId,"synthetic_fixture_cleanup")
	check("direct_resource_final_grants_empty",c.traffic.reservations_by_id.is_empty())
	close_fixture(c,"direct_resource")

func _run() -> void:
	var started:=Time.get_ticks_msec()
	single_and_identity()
	double_survivor()
	traffic_isolation()
	freed_peer_control()
	latest_wait_target_control()
	direct_resource_control()
	var failures: Array=[]
	for label in checks:
		if not checks[label]: failures.append(label)
	var hashes := {}
	for path: String in ["scripts/npc_ai/interactions/DoorPortalService.gd","scripts/npc_ai/interactions/DoorPortal.gd","scripts/npc_ai/interactions/DoorController.gd","scripts/npc_ai/interactions/DoorTraversalExecutor.gd","scripts/npc_ai/traffic/TrafficReservationService.gd","scripts/testing/buildings/DoorUnregistrationContract.gd"]:
		hashes[path]=FileAccess.get_sha256("res://"+path)
	var report := {"schema":"door-unregistration-contract/v1","complete":true,"passed":failures.is_empty(),"checkCount":checks.size(),"checks":checks,"failures":failures,"metrics":metrics,"sourceHashes":hashes,"elapsedMsec":Time.get_ticks_msec()-started,"evidenceLevel":"synthetic SceneTree and real door/traffic service contract; executor crossing records injected","doesNotProve":"No live NPC approach/crossing, player door interaction, navigation, scene activation or headed gameplay acceptance."}
	var file:=FileAccess.open(OS.get_environment("DOOR_UNREGISTRATION_OUTPUT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("DOOR UNREGISTRATION COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"failures":failures}))
	quit(0 if report.passed else 1)
