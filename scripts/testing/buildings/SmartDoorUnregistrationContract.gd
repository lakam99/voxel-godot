extends SceneTree
## Independent synthetic SmartObject/DoorPortal SceneTree controls. No inherited
## suite counts, live actor behavior, route/autonomy changes or headed evidence.
const Smart = preload("res://scripts/npc_ai/interactions/SmartObjectService.gd")
const Doors = preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const Request = preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")

class Listener extends RefCounted:
	var exits := {}
	func exiting(id: int) -> void: exits[id]=int(exits.get(id,0))+1

var checks := {}
var details := {}

func _initialize() -> void: call_deferred("_run")

func check(label: String, passed: bool) -> void:
	checks[label]=passed
	if not passed: print("SMART DOOR FAILURE ",label)

func fixture() -> Dictionary:
	var parent := Node3D.new()
	root.add_child(parent)
	var portals := Doors.new()
	portals.setup(null)
	var smart := Smart.new()
	smart.setup(null,portals)
	return {"parent":parent,"portals":portals,"smart":smart,"listener":Listener.new()}

func leaf(c: Dictionary, id: String, index: int, smart_registration := true) -> Node3D:
	var node := Node3D.new()
	node.name="SyntheticLeaf"+str(index)
	node.position=Vector3(index*1.35,0,0)
	node.set_meta("cell",Vector3i(index,0,0))
	node.set_meta("door_portal_id",id)
	node.set_meta("door_group_id",id)
	c.parent.add_child(node)
	node.tree_exiting.connect(c.listener.exiting.bind(node.get_instance_id()))
	var metadata := {"custom":{"keep":[1,2,3]},"position":Vector3.ZERO,"requiresApproach":false,"capacity":2,"slots":{"slot:0":{"slotId":"slot:0","capacity":2,"occupants":[],"position":Vector3.ZERO}}}
	var registered: String=c.smart.register_door(node,metadata) if smart_registration else c.portals.register_door(node)
	check(id+"_registered_"+str(index),registered==id)
	return node

func callback(smart, id: String, node: Node) -> Callable:
	return Callable(smart,"_on_registered_node_tree_exiting").bind(id,node.get_instance_id())

func registration_data(registration) -> Dictionary:
	return {"metadata":registration.metadata.duplicate(true),"slots":registration.slots.duplicate(true),"reservations":registration.reservations.duplicate(true),"depleted":registration.depleted}

func indexes(smart) -> Dictionary:
	return {"kind":smart.index_by_kind.duplicate(true),"available":smart.available_index_by_kind.duplicate(true),"depleted":smart.depleted_index_by_kind.duplicate(true),"tile":smart.index_by_tile.duplicate(true),"chunk":smart.index_by_chunk.duplicate(true),"region":smart.index_by_region.duplicate(true),"town":smart.index_by_town.duplicate(true),"layer":smart.index_by_layer.duplicate(true)}

func indexed_anywhere(smart, id: String) -> bool:
	for index: Dictionary in indexes(smart).values():
		for bucket: Dictionary in index.values():
			if bucket.has(id): return true
	return false

func reserve(c: Dictionary, id: String) -> void:
	var request = Request.make(&"reserve",id,"synthetic-actor",{"action":"use"})
	request.actor_kind="npc"
	var result = c.smart.reserve_interaction(request)
	check(id+"_real_smart_reservation",String(result.status)=="succeeded" and c.smart.registrations[id].reservations.size()==1)

func close(c: Dictionary, label: String) -> void:
	c.smart.clear()
	c.parent.free()
	c.smart.door_portals=null
	check(label+"_cleared",c.smart.registrations.is_empty() and c.portals.portals.is_empty())

func grouped(remove_representative: bool) -> void:
	var id := "representative" if remove_representative else "nonrepresentative"
	var c := fixture()
	var left := leaf(c,id,0)
	var right := leaf(c,id,1)
	# Existing register_door replacement semantics are intentionally unchanged:
	# actors/reservations begin only AFTER this fixture's complete group setup.
	var reg = c.smart.registrations[id]
	check(id+"_initial_last_leaf_representative",reg.node==right)
	reserve(c,id)
	c.smart._index_registration(reg) # Explicit indexed-existing-registration case.
	var unrelated := Node3D.new()
	c.parent.add_child(unrelated)
	c.smart.register_object("unrelated","workstation",unrelated,{"position":Vector3(100,0,0)})
	var untouched = c.smart.registrations.unrelated
	var untouched_data := registration_data(untouched)
	c.smart.completed_effects["replay"]={"objectId":id,"effectApplied":true,"syntheticSavedEffect":17}
	c.smart.completed_effects["other-replay"]={"objectId":"unrelated","effectApplied":true}
	c.smart.last_release_by_object[id]={"old":true}
	c.smart.last_release_by_object.unrelated={"retain":true}
	c.smart.query_cache["synthetic-cache"]={"objects":[id]}
	var old_indexes := indexes(c.smart)
	var data := registration_data(reg)
	var completed: Dictionary=c.smart.completed_effects.duplicate(true)
	var old_revision: int=reg.revision
	var service_revision: int=c.smart.revision_counter
	var removed: Node=right if remove_representative else left
	var survivor: Node=left if remove_representative else right
	var removed_id := removed.get_instance_id()
	var survivor_id := survivor.get_instance_id()
	var result: Dictionary=c.smart.unregister_door(removed)
	check(id+"_nonlast_receipt",result.status=="unregistered" and not result.portalRemoved and result.remainingLeaves==1)
	check(id+"_same_registration",c.smart.registrations[id]==reg and reg.node==survivor)
	check(id+"_metadata_slots_reservations_exact",registration_data(reg)==data)
	check(id+"_indexes_preserved",indexes(c.smart)==old_indexes)
	check(id+"_removed_callback_disconnected",not removed.tree_exiting.is_connected(callback(c.smart,id,removed)))
	check(id+"_survivor_callback_connected",survivor.tree_exiting.is_connected(callback(c.smart,id,survivor)))
	check(id+"_unrelated_listener_preserved",removed.tree_exiting.is_connected(c.listener.exiting.bind(removed_id)))
	if remove_representative:
		check(id+"_revision_advanced_once",reg.revision==service_revision+1 and c.smart.revision_counter==service_revision+1)
		check(id+"_query_cache_invalidated",c.smart.query_cache.is_empty())
	else:
		check(id+"_revision_unchanged",reg.revision==old_revision and c.smart.revision_counter==service_revision)
		check(id+"_query_cache_unchanged",c.smart.query_cache.has("synthetic-cache"))
	removed.free()
	check(id+"_old_leaf_free_listener_once",c.listener.exits.get(removed_id)==1)
	check(id+"_old_leaf_free_does_not_unbind_survivor",c.smart.has_live_registration(id) and reg.node==survivor and registration_data(reg)==data)
	check(id+"_other_registration_untouched",c.smart.registrations.unrelated==untouched and registration_data(untouched)==untouched_data)
	result=c.smart.unregister_door(survivor)
	check(id+"_final_receipt",result.status=="unregistered" and result.portalRemoved and result.remainingLeaves==0)
	check(id+"_final_unbound_erased",not c.smart.registrations.has(id) and reg.node==null and reg.metadata.get("stale",false) and not reg.metadata.get("available",true) and not reg.depleted and reg.reservations.is_empty())
	check(id+"_final_slot_occupants_empty",reg.slots.values().all(func(slot): return slot.get("occupants",[]).is_empty()))
	check(id+"_final_index_release_erased",not indexed_anywhere(c.smart,id) and not c.smart.last_release_by_object.has(id))
	check(id+"_other_release_preserved",c.smart.last_release_by_object.unrelated=={"retain":true})
	check(id+"_completed_effects_preserved",c.smart.completed_effects==completed)
	check(id+"_final_callback_disconnected",not survivor.tree_exiting.is_connected(callback(c.smart,id,survivor)))
	var final_revision: int=c.smart.revision_counter
	var final_registration_revision: int=reg.revision
	var final_cache: Dictionary=c.smart.query_cache.duplicate(true)
	var final_indexes:=indexes(c.smart)
	var repeated: Dictionary=c.smart.unregister_door(survivor)
	check(id+"_duplicate_absent",repeated.status=="absent")
	check(id+"_duplicate_no_revision_cache_effect_change",c.smart.revision_counter==final_revision and reg.revision==final_registration_revision and c.smart.query_cache==final_cache and c.smart.completed_effects==completed and indexes(c.smart)==final_indexes and not c.smart.registrations.has(id) and not c.smart.last_release_by_object.has(id))
	var fresh := leaf(c,id,2)
	var fresh_reg = c.smart.registrations[id]
	check(id+"_reused_id_new_live_registration",fresh_reg!=reg and fresh_reg.node==fresh and c.smart.has_live_registration(id) and fresh_reg.reservations.is_empty())
	# Keep the old leaf alive until its ID has been reused; its eventual exit
	# must not unbind the replacement registration or consume old effects.
	survivor.free()
	check(id+"_old_survivor_exit_preserves_reused_id",c.listener.exits.get(survivor_id)==1 and c.smart.registrations[id]==fresh_reg and c.smart.has_live_registration(id))
	var replay = Request.make(&"complete",id,"synthetic-actor")
	replay.request_id="replay"
	var replay_result=c.smart.complete_interaction(replay)
	check(id+"_replay_not_reapplied",String(replay_result.reason)=="idempotent_replay" and not replay_result.metrics.effectApplied and c.smart.completed_effects==completed)
	check(id+"_fresh_final_unregister",c.smart.unregister_door(fresh).status=="unregistered")
	close(c,id)

func survivor_exit_and_stale() -> void:
	for mode: String in ["survivor_exit","freed_representative","freed_unsignalled","depleted"]:
		var c := fixture()
		var first := leaf(c,mode,0)
		var representative := leaf(c,mode,1)
		var third: Node3D
		if mode in ["freed_representative","freed_unsignalled"]: third=leaf(c,mode,2,false)
		var reg=c.smart.registrations[mode]
		reserve(c,mode)
		if mode=="freed_unsignalled":
			# Explicit missed-signal fixture: retain an actual freed Node in the
			# typed registration field to exercise the untyped disconnect guard.
			representative.tree_exiting.disconnect(callback(c.smart,mode,representative))
			var old_data:=registration_data(reg)
			representative.free()
			check(mode+"_actual_freed_reference",not is_instance_valid(reg.node) and not reg.metadata.get("stale",false))
			var result: Dictionary=c.smart.unregister_door(first)
			check(mode+"_safe_rebind",result.status=="unregistered" and reg.node==third and registration_data(reg)==old_data)
			check(mode+"_connected",third.tree_exiting.is_connected(callback(c.smart,mode,third)))
			c.smart.unregister_door(third)
		elif mode=="freed_representative":
			# The normal signal has already marked this registration stale. Rebind
			# after dead-peer pruning must NOT resurrect metadata or reservations.
			representative.free()
			var stale_data:=registration_data(reg)
			check(mode+"_initial_unbound",reg.metadata.get("stale",false) and reg.reservations.is_empty())
			var result: Dictionary=c.smart.unregister_door(first)
			check(mode+"_survivor_bound_without_resurrection",result.status=="unregistered" and result.remainingLeaves==1 and reg.node==third and registration_data(reg)==stale_data and not c.smart.has_live_registration(mode))
			check(mode+"_fresh_callback_connected",third.tree_exiting.is_connected(callback(c.smart,mode,third)))
			c.smart.unregister_door(third)
		elif mode=="depleted":
			c.smart.mark_registration_removed(reg,"synthetic_preexisting_depletion")
			var stale_data:=registration_data(reg)
			var result: Dictionary=c.smart.unregister_door(representative)
			check(mode+"_not_resurrected",result.status=="unregistered" and reg.node==first and registration_data(reg)==stale_data and not c.smart.has_live_registration(mode))
			c.smart.unregister_door(first)
		else:
			c.smart.unregister_door(representative)
			check(mode+"_rebound_live",reg.node==first and c.smart.has_live_registration(mode))
			first.free()
			check(mode+"_actual_exit_unbinds",reg.node==null and reg.metadata.get("stale",false) and reg.reservations.is_empty() and not c.smart.has_live_registration(mode))
		close(c,mode)

func unrelated_registration_controls() -> void:
	for mode: String in ["missing","non-door","unknown","null"]:
		var c:=fixture()
		var door:=leaf(c,mode,0,mode in ["missing","non-door"])
		var reg
		if mode=="non-door":
			c.smart.register_object(mode,"workstation",null,{"position":Vector3.ZERO,"custom":[9]})
			reg=c.smart.registrations[mode]
			reserve(c,mode)
		elif mode=="missing": c.smart.registrations.erase(mode)
		var before:=registration_data(reg) if reg!=null else {}
		var old_revision: int=c.smart.revision_counter
		var old_indexes:=indexes(c.smart)
		var argument: Node=door
		if mode=="unknown":
			argument=Node3D.new()
			argument.set_meta("door_portal_id",mode)
			c.parent.add_child(argument)
		elif mode=="null": argument=null
		var result: Dictionary=c.smart.unregister_door(argument)
		if mode in ["missing","non-door"]:
			check(mode+"_portal_cleaned",result.status=="unregistered" and result.portalRemoved and not c.portals.portals.has(mode))
		else:
			check(mode+"_delegate_receipt",result.status==("absent" if mode=="unknown" else "failed"))
			check(mode+"_portal_untouched",c.portals.portals.has(mode))
		check(mode+"_smart_indexes_revision_unchanged",indexes(c.smart)==old_indexes and c.smart.revision_counter==old_revision)
		if reg!=null:
			check(mode+"_registration_exact",c.smart.registrations[mode]==reg and reg.node==null and registration_data(reg)==before)
		if mode in ["missing","non-door"]:
			check(mode+"_old_callback_removed",not door.tree_exiting.is_connected(callback(c.smart,mode,door)))
			if mode=="missing":
				c.smart.register_object(mode,"workstation",null,{"position":Vector3.ZERO,"custom":[9]})
				reg=c.smart.registrations[mode]
				reserve(c,mode)
				before=registration_data(reg)
			var old_id:=door.get_instance_id()
			door.free()
			check(mode+"_old_exit_listener_preserved",c.listener.exits.get(old_id)==1)
			check(mode+"_null_anchor_survives_old_exit",c.smart.registrations[mode]==reg and c.smart.has_live_registration(mode) and registration_data(reg)==before and reg.node==null)
		close(c,mode)

func _run() -> void:
	var started:=Time.get_ticks_msec()
	grouped(false)
	grouped(true)
	survivor_exit_and_stale()
	unrelated_registration_controls()
	var failures: Array=[]
	for label in checks:
		if not checks[label]: failures.append(label)
	var hashes: Dictionary={}
	for path: String in ["scripts/npc_ai/interactions/SmartObjectService.gd","scripts/npc_ai/interactions/SmartObjectRegistration.gd","scripts/npc_ai/interactions/DoorPortalService.gd","scripts/npc_ai/interactions/DoorPortal.gd","scripts/testing/buildings/SmartDoorUnregistrationContract.gd"]:
		hashes[path]=FileAccess.get_sha256("res://"+path)
	var report: Dictionary={"schema":"smart-door-unregistration-contract/v1","complete":true,"passed":failures.is_empty(),"checkCount":checks.size(),"checks":checks,"failures":failures,"sourceHashes":hashes,"elapsedMsec":Time.get_ticks_msec()-started,"evidenceLevel":"independent synthetic SmartObject/DoorPortal service and actual Node exit signals","doesNotProve":"No live actors/routes/autonomy, player door interaction, headed gameplay, or fix to preexisting repeated register_door replacement behavior. Completed-effect entries are synthetic replay fixtures."}
	var file:=FileAccess.open(OS.get_environment("SMART_DOOR_UNREGISTRATION_OUTPUT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("SMART DOOR COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size(),"failures":failures}))
	quit(0 if report.passed else 1)
