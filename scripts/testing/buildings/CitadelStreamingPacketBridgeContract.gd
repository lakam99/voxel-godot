extends "res://scripts/testing/buildings/CitadelPublicationServiceContract.gd"

## Actual frozen-source demand bridge: WorldStreamingCoordinator discovers the
## closure from StructureSystem, then MainCore applies that retained request to
## CitadelPublicationService. No test supplies a site group ID.
const TARGET_TILE := Vector2i(199,-337)

class StreamingRuntime extends Node3D:
	var retained := {}
	func set_retained_gameplay_chunks(value: Dictionary) -> void: retained=value.duplicate()

class NavigationDemandProbe extends RefCounted:
	var next_id := 1
	var requests := {}
	func request_tiles(keys: Array, priority: int, reason: String) -> int:
		if keys.is_empty() or priority<0 or reason.is_empty(): return 0
		var id := next_id; next_id+=1
		requests[id]={"keys":keys.duplicate(),"priority":priority,"reason":reason}
		return id
	func replace_tiles(id: int, keys: Array, priority: int, reason: String) -> bool:
		if not requests.has(id) or keys.is_empty() or priority<0 or reason.is_empty(): return false
		requests[id]={"keys":keys.duplicate(),"priority":priority,"reason":reason}
		return true
	func release_region(id: int) -> void: requests.erase(id)
	func advance(_budget_usec := 0) -> void: pass

func _initialize() -> void:
	call_deferred("_run_bridge")

func _sorted_ids(value: Array) -> Array[String]:
	var result: Array[String] = []
	for item in value: result.append(String(item))
	result.sort()
	return result

func _priority_identity(value) -> Array[String]:
	var result: Array[String] = []
	if value is Dictionary:
		for key in value:
			result.append("%s:%d" % [String(key),int(value[key])])
	result.sort()
	return result

func _retained_manifest_identity(retained: Dictionary) -> String:
	var admission: Array[String] = []
	for key: Vector2i in retained.get("admissionKeys",[]): admission.append("%d,%d" % [key.x,key.y])
	admission.sort()
	var navigation := _sorted_ids(retained.get("navigationTileKeys",[]))
	var sites: Array[Dictionary] = []
	for site: Dictionary in retained.get("sites",[]):
		var binding: Dictionary = site.get("binding",{})
		sites.append({"siteId":String(binding.get("siteId","")),"sourceKey":String(binding.get("sourceKey","")),
			"generation":int(binding.get("generation",0)),"ownerId":int(site.get("ownerId",0)),
			"priority":int(site.get("priority",4)),"groupIds":_sorted_ids(site.get("groupIds",[])),
			"foregroundGroupIds":_sorted_ids(site.get("foregroundGroupIds",[])),
			"foregroundNavigationTileKeys":_sorted_ids(site.get("foregroundNavigationTileKeys",[])),
			"navigationTilePriorities":_priority_identity(site.get("navigationTilePriorities",{}))})
	sites.sort_custom(func(a: Dictionary,b: Dictionary): return JSON.stringify(a)<JSON.stringify(b))
	return JSON.stringify({"ownerId":int(retained.get("ownerId",0)),"priority":int(retained.get("priority",4)),
		"bounds":retained.get("bounds",Rect2i()),"admissionKeys":admission,
		"navigationTileKeys":navigation,
		"navigationTilePriorities":_priority_identity(retained.get("navigationTilePriorities",{})),"sites":sites})

func _run_bridge() -> void:
	var source := load_actual()
	var report := {"tileKey":"%d,%d" % [TARGET_TILE.x,TARGET_TILE.y],"expectedGroups":[],"retainedRequest":{},"packetTrace":[],"packetRevision":-1,"stableRevision":-1,"retainedManifestTrace":[]}
	check("fixture_frozen",not source.is_empty() and source.is_read_only())
	if source.is_empty():
		_finish(report,null)
		return
	var value := owner()
	var structures = value.structure_system
	var service = structures.citadel_publication
	var parent := Node3D.new()
	var trees := PacketTrees.new()
	value.add_child(parent)
	check("scene_publication_configured",service.configure_scene_publication(parent,trees.publish,trees.retire))
	inject(structures.citadel_terrain_admission,REGION,source)
	source={}
	var runtime := StreamingRuntime.new()
	var navigation := NavigationDemandProbe.new()
	value.voxel_terrain_runtime=runtime
	value.world_streaming.configure(SEED,{"terrain":runtime,"structures":structures,"navigation":navigation})
	value.streaming_applied_revision=-1
	var bounds := Rect2i(TARGET_TILE*16,Vector2i.ONE*16)
	var request_id := value.world_streaming.request_region(bounds,0,"actual_packet_bridge")
	check("streaming_request_admitted",request_id>0)
	var expected: Array[String] = []
	var retained := {}
	var packet_seen := false
	var legacy_preparation_seen := false
	var publication_base_seen := false
	var bootstrap_seen := false
	var initial_unresolved_request_seen := false
	var legacy_scene_seen := false
	var publication_base_revision := -1
	var bootstrap_revision := -1
	var described_revision := -1
	var packet_revision := -1
	var retained_manifest := ""
	var retained_manifest_stable := true
	var stable_manifest_frames := 0
	var deadline := Time.get_ticks_msec()+120000
	while request_id>0 and Time.get_ticks_msec()<deadline:
		# The public MainCore bridge is the only source-request setter here.
		value.apply_streaming_region_demand()
		structures.advance_citadel_publication(bounds,true)
		value.world_streaming.advance()
		var described: Dictionary = service._described.get(REGION,{})
		if not described.is_empty() and expected.is_empty():
			var closure: Dictionary = described.description.physical_group_requirements(bounds)
			if closure.get("status")=="described":
				expected=_sorted_ids(closure.get("groupIds",[]))
				described_revision=value.world_streaming.revision()
		var requests: Array = value.world_streaming.retained_source_requests()
		if requests.size()==1:
			retained=requests[0]
			if expected.is_empty() and (retained.get("sites",[]) as Array).is_empty():
				initial_unresolved_request_seen=true
		var entry: Dictionary = service._scenes.get(REGION,{})
		var job = entry.get("job",null)
		var inflight_kind := String(service._inflight.get("kind",""))
		var state := {"inflight":inflight_kind,"phase":String(job.status_count().get("phase","") if job!=null else ""),
			"streamingRevision":value.world_streaming.revision(),"expectedCount":expected.size(),"retainedSiteCount":(retained.get("sites",[]) as Array).size(),
			"prepared":service._prepared.has(REGION),"bootstrap":service._packet_bootstrap_bases.has(REGION),"sceneCount":service._scenes.size(),
			"sceneCallbacksReady":service._scene_callbacks_ready(),"failures":service._failures.duplicate(true)}
		if report.packetTrace.is_empty() or report.packetTrace.back()!=state: report.packetTrace.append(state)
		if inflight_kind=="publication_base":
			publication_base_seen=true
			if publication_base_revision<0: publication_base_revision=value.world_streaming.revision()
		if service._packet_bootstrap_bases.has(REGION):
			bootstrap_seen=true
			if bootstrap_revision<0: bootstrap_revision=value.world_streaming.revision()
		if not entry.is_empty() and not bool(entry.get("packetMode",false)): legacy_scene_seen=true
		if inflight_kind=="preparation": legacy_preparation_seen=true
		if inflight_kind=="physical_group_packet":
			packet_seen=true
			if packet_revision<0: packet_revision=value.world_streaming.revision()
		if not expected.is_empty() and retained.get("sites",[]) is Array and retained.sites.size()==1 \
				and _sorted_ids(retained.sites[0].get("groupIds",[]))==expected:
			var identity := _retained_manifest_identity(retained)
			if retained_manifest.is_empty(): retained_manifest=identity
			elif retained_manifest!=identity: retained_manifest_stable=false
			if report.retainedManifestTrace.is_empty() or report.retainedManifestTrace.back()!=identity:
				report.retainedManifestTrace.append(identity)
			stable_manifest_frames+=1
		if not expected.is_empty() and packet_seen and stable_manifest_frames>=4: break
		await process_frame
	report.expectedGroups=expected
	report.retainedRequest=retained
	report.packetRevision=packet_revision
	report.stableRevision=value.world_streaming.revision()
	report.publicationBaseRevision=publication_base_revision
	report.bootstrapRevision=bootstrap_revision
	report.describedRevision=described_revision
	var expected_key := "%d,%d" % [TARGET_TILE.x,TARGET_TILE.y]
	var source_binding: Dictionary = structures.citadel_terrain_admission.source_state(REGION).binding
	var retained_site := {}
	for site: Dictionary in retained.get("sites",[]):
		if site.get("binding",{})==source_binding: retained_site=site; break
	check("source_derived_nonempty_closure",expected.size()==18)
	check("streaming_request_contains_target_navigation_key",retained.get("navigationTileKeys",[]).has(expected_key))
	check("streaming_request_contains_exact_source_binding",retained_site.get("binding",{})==source_binding)
	check("streaming_request_preserves_complete_source_derived_closure",_sorted_ids(retained_site.get("groupIds",[]))==expected)
	check("maincore_applied_same_manifest_to_service",service._retained_consumers.size()==1 \
		and _retained_manifest_identity(service._retained_consumers[0])==_retained_manifest_identity(retained)
		and service._retained_consumers[0].navigationTileKeys.has(expected_key)
		and value.streaming_applied_revision==value.world_streaming.revision())
	check("tile_only_demand_bootstraps_publication_base_before_packet",initial_unresolved_request_seen
		and publication_base_seen and bootstrap_seen
		and publication_base_revision>=0 and bootstrap_revision>=publication_base_revision
		and described_revision>=bootstrap_revision and packet_revision>=described_revision)
	check("bootstrap_did_not_enter_legacy_scene_preparation",not legacy_preparation_seen)
	check("bootstrap_did_not_create_legacy_scene",not legacy_scene_seen)
	check("citadel_service_enters_physical_packet_route",packet_seen)
	check("packet_route_keeps_exact_retained_manifest_stable",packet_revision>=0 and stable_manifest_frames>=4 \
		and retained_manifest_stable and report.retainedManifestTrace.size()==1)
	await _finish(report,value)

func _finish(report: Dictionary, value) -> void:
	if value!=null:
		value.world_streaming.configure("")
		var runtime = value.voxel_terrain_runtime
		value.voxel_terrain_runtime=null
		if is_instance_valid(runtime): runtime.free()
		await close(value,"streaming_packet_bridge")
	var output := {"schema":"citadel-streaming-packet-bridge-contract/v1","complete":true,
		"passed":not checks.values().has(false),"checks":checks,"result":report,
		"doesNotProve":"No NavigationServer acknowledgement, route query, NPC movement, headed runtime, visual, save, or gameplay acceptance."}
	var file := FileAccess.open(OS.get_environment("CITADEL_STREAMING_PACKET_BRIDGE_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t")); file.close()
	print("CITADEL STREAMING PACKET BRIDGE ",JSON.stringify({"passed":output.passed,"groups":report.expectedGroups.size()}))
	quit(0 if output.passed else 1)
