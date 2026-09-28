extends "res://scripts/testing/buildings/CitadelPublicationServiceContract.gd"

## Frozen-source integration evidence. It starts only after the real ten-group
## packet and `navigation_tile_sources` receipt succeeds, then drives the normal
## coordinator queue and frame boundary until NavmeshWorldService acknowledges it.
const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const NpcRouteCoordinatorAdapterScript := preload("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")

class NavigationOwner extends Owner:
	# This contract owns synthetic flat terrain and an actual frozen Citadel
	# structure packet. Declare that boundary explicitly now that MainCore gates
	# production capture on terrain publication readiness.
	func navigation_terrain_publication_readiness(bounds: Rect2i) -> Dictionary:
		return {"status":"ready","reason":"synthetic_flat_terrain_ready","bounds":bounds}
	func surface_y_at_cell(_cell: Vector3i) -> float:
		# MainCore's non-booting base returns sea-floor zero. Put this declared
		# synthetic terrain above the real water-clearance threshold so the filter
		# exercises region installation rather than authoritative-empty handling.
		return WATER_LEVEL + 4.0

func owner() -> Owner:
	var value := NavigationOwner.new()
	value.seed_text = SEED
	root.add_child(value)
	value.set_process(false)
	value.set_physics_process(false)
	value.structure_system = ObservedStructures.new()
	value.structure_system.citadel_terrain_admission = ObservedAdmission.new()
	value.structure_system.setup(value)
	value.structure_system.citadel_terrain_admission.finalize_town_inputs({})
	return value

func _initialize() -> void:
	call_deferred("_run_acknowledgement")

func packet_tile() -> Vector2i:
	return ACTUAL_PACKET_TILE

func packet_group_ids() -> Array[String]:
	return ACTUAL_PACKET_TILE_GROUPS

func _shutdown_navigation(service) -> Dictionary:
	service.request_publication_shutdown()
	var deadline := Time.get_ticks_msec()+30000
	var state: Dictionary = {}
	while Time.get_ticks_msec()<deadline:
		await process_frame
		state=service.advance_publication()
		if bool(state.get("shutdownComplete",false)): break
	return state

func _run_acknowledgement() -> void:
	var target_tile := packet_tile()
	var target_groups := packet_group_ids()
	var receipt: Dictionary = await actual_packet_tile_receipt(true,target_tile,target_groups)
	var value: Owner = receipt.get("owner") as Owner
	receipt.erase("owner")
	var result := {"sourceReceipt":receipt,"acknowledged":false,"queueDrained":false,"sourceKey":"","state":{},"iterations":{},"trace":[]}
	if not bool(receipt.get("ready",false)) or value==null:
		check("actual_packet_source_receipt",false)
	else:
		check("actual_packet_source_receipt",true)
		var tile_key := "%d,%d" % [target_tile.x,target_tile.y]
		var world := GeneratedWorldNavigationAdapterScript.new()
		world.setup(null,value)
		var navigation := NavmeshWorldServiceScript.new()
		navigation.setup()
		world.bind_navigation_publication_service(navigation)
		var coordinator := NpcRouteCoordinatorAdapterScript.new()
		coordinator.setup(null,value,world)
		# The coordinator normally receives this from NpcAutonomySystem. The
		# contract binds the same service explicitly, without constructing NPCs.
		coordinator.navmesh_world=navigation
		var source_key := world.navmesh_tile_source_key_for_tile(tile_key)
		result.sourceKey=source_key
		check("navigation_source_key_is_bound",not source_key.is_empty())
		var queued := coordinator.queue_navmesh_tile_publish(tile_key,true)
		check("coordinator_queue_accepted",queued)
		var deadline := Time.get_ticks_msec()+120000
		var state: Dictionary = {}
		while Time.get_ticks_msec()<deadline:
			coordinator.begin_frame()
			state=navigation.accepted_tile_state(tile_key,source_key,value.seed_text,world)
			var trace := {"state":String(state.get("status","")),"reason":String(state.get("reason","")),
				"queued":coordinator.queued_navmesh_tile_keys.size(),"syncPending":navigation.publication_sync_pending()}
			if result.trace.is_empty() or result.trace.back()!=trace: result.trace.append(trace)
			if state.get("status")=="acknowledged" and coordinator.queued_navmesh_tile_keys.is_empty(): break
			await process_frame
		result.state={"status":state.get("status",""),"reason":state.get("reason",""),"receipt":state.get("receipt",{}),
			"acceptedSerial":state.get("acceptedSerial",0),"installationSerial":state.get("installationSerial",-1)}
		result.acknowledged=state.get("status")=="acknowledged"
		result.queueDrained=coordinator.queued_navmesh_tile_keys.is_empty()
		var region_id := "region:chunk:"+tile_key
		var region_rid: RID = navigation.region_rids_by_region.get(region_id,RID())
		var descriptor = navigation.descriptors_by_region.get(region_id,null)
		var installed_surface_count := (descriptor.walkable_surfaces as Array).size() if descriptor!=null else 0
		var region_installed := region_rid.is_valid()
		result.iterations={"map":NavigationServer3D.map_get_iteration_id(navigation.navigation_map),
			"region":NavigationServer3D.region_get_iteration_id(region_rid) if region_installed else 0,"regionInstalled":region_installed,
			"installedSurfaceCount":installed_surface_count}
		check("accepted_tile_acknowledged",result.acknowledged)
		check("coordinator_queue_drained",result.queueDrained)
		check("accepted_receipt_binds_exact_source",String(state.get("receipt",{}).get("sourceKey",""))==source_key \
			and String(receipt.get("navigation",{}).get("sources",[{}])[0].get("binding",{}).get("sourceKey",""))==String(receipt.get("binding",{}).get("sourceKey","")))
		check("navigation_map_iteration_positive",int(result.iterations.map)>0)
		check("navigation_region_iteration_positive",bool(result.iterations.regionInstalled) and int(result.iterations.region)>0)
		check("installed_navigation_surfaces_nonempty",not bool(state.get("empty",true)) and installed_surface_count>0)
		var shutdown: Dictionary = await _shutdown_navigation(navigation)
		check("navigation_shutdown_drained",bool(shutdown.get("shutdownComplete",false)))
		coordinator.shutdown_for_process_exit()
		coordinator=null
		world=null
		navigation=null
	if value!=null:
		await close(value,"actual_packet_tile_navigation")
	var report := {"schema":"citadel-actual-packet-tile-navigation-acknowledgement-contract/v1","complete":true,
		"passed":not checks.values().has(false),"checks":checks,"result":result,
		"doesNotProve":"No NPC spawn, route query, motor movement, door interaction, headed runtime, visual, save, or gameplay acceptance."}
	var file := FileAccess.open(OS.get_environment("CITADEL_PACKET_TILE_NAVIGATION_ACK_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("ACTUAL PACKET TILE NAVIGATION ACKNOWLEDGEMENT ",JSON.stringify({"passed":report.passed,"status":result.state.get("status","")}))
	quit(0 if report.passed else 1)
