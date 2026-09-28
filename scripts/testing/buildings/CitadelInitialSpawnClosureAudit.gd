extends SceneTree

## Read-only compact-source audit for the requested initial spawn safety area.
## It deliberately stops before source admission, dense tile production, scene
## publication, navigation registration, or any gameplay system.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Streaming = preload("res://scripts/world/WorldStreamingCoordinator.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-source-profile-32/source.bin"
const INPUT_SHA := "42f3c7b2ff1dee451f98dbd286c1a2d346c9e0033326f578ec8a6fea75418067"
const BINDING := {"siteId":"citadel-site-v1:16:atlas-3376622889:-2,-2", "sourceKey":"60d35570a40a438f232245e244ab5e4115883a0ff9bb4444588afabcf09705de", "generation":1}
const WORLD_ORIGIN := Vector3(-4500.9,41.85,-3800.25)
const SPAWN_CELL := Vector2i(-3382,-2815)
const CAPSULE_BOUNDS := Rect2i(Vector2i(-3383,-2816),Vector2i(2,2))
const SUPPORTED_FAMILIES := ["jointed_paving","normal"]

class Deadline extends RefCounted:
	var started := Time.get_ticks_msec()
	func checkpoint(_stage: String) -> bool: return Time.get_ticks_msec()-started < 120000

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var report := _audit()
	var output := OS.get_environment("CITADEL_INITIAL_SPAWN_CLOSURE_AUDIT_REPORT")
	if output.is_empty() or not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("CITADEL INITIAL SPAWN CLOSURE AUDIT ",JSON.stringify({"passed":report.get("passed",false),"summary":report.get("summary",{})}))
	quit(0 if report.get("passed",false) else 1)

func _audit() -> Dictionary:
	var report := {"schema":"citadel-initial-spawn-closure-audit/v1","complete":false,"passed":false,
		"evidenceLevel":"actual_frozen_source_compact_spawn_safety_tile_closure_audit","seed":"atlas-3376622889","region":Vector2i(-2,-2),
		"spawnCell":SPAWN_CELL,"binding":BINDING.duplicate(),"fixture":{"path":INPUT,"sha256":INPUT_SHA},
		"doesNotProve":"No source admission, dense navigation output, scene or collision publication, NavigationServer acknowledgement, route, NPC movement, player collision, startup, or headed gameplay."}
	if FileAccess.get_sha256(INPUT)!=INPUT_SHA: report.reason="fixture_sha256"; return report
	var file := FileAccess.open(INPUT,FileAccess.READ)
	var value: Variant = file.get_var(false) if file!=null else null
	if file!=null: file.close()
	if not value is Dictionary or value.get("ready")!=true or not value.get("blueprint") is Dictionary or not value.get("furnishingPlan") is Dictionary or not value.get("accessReservations") is Array:
		report.reason="fixture_shape"; return report
	var source: Dictionary=value
	var building: Dictionary=source.blueprint.duplicate(true)
	var furnishing: Dictionary=source.furnishingPlan.duplicate(true)
	furnishing["accessReservations"]=source.accessReservations.duplicate(true)
	building.make_read_only(); furnishing.make_read_only()
	var prepared: Dictionary=Preparation.prepare_publication_base(building,furnishing,BINDING,{"origin":WORLD_ORIGIN},Deadline.new().checkpoint)
	if not prepared.get("ready",false) or prepared.get("base")==null: report.reason=prepared.get("reason","publication_base_failed"); return report
	var base=prepared.base
	var census: Dictionary=Preparation.classify_physical_group_packet_eligibility(base.description.publication_groups,base.building_source,base.furnishing_source)
	if not census.get("ready",false): report.reason=census.get("reason","packet_census_failed"); return report
	var tile_cells: int=int(base.description.NAV_TILE_CELLS)
	if tile_cells<=0: report.reason="invalid_navigation_tile_size"; return report
	var bounds: Rect2i=Streaming.playable_bounds(Vector3(float(SPAWN_CELL.x)*Streaming.CELL,0.0,float(SPAWN_CELL.y)*Streaming.CELL))
	var capsule_requirements: Dictionary=base.description.regional_group_requirements(CAPSULE_BOUNDS)
	if capsule_requirements.get("status")!="described": report.reason="capsule_closure_"+String(capsule_requirements.get("reason","not_described")); return report
	var reference_started := Time.get_ticks_usec()
	var reference_requirements: Dictionary=base.description._legacy_regional_group_requirements(CAPSULE_BOUNDS)
	var reference_usec := Time.get_ticks_usec()-reference_started
	var indexed_regions: Dictionary={}
	var reference_regions: Dictionary={}
	for rectangle: Rect2i in capsule_requirements.get("dependencyBounds",[]): indexed_regions[rectangle]=true
	for rectangle: Rect2i in reference_requirements.get("dependencyBounds",[]): reference_regions[rectangle]=true
	var parity: bool = reference_requirements.get("status")=="described" \
		and capsule_requirements.groupIds==reference_requirements.groupIds \
		and capsule_requirements.groupMemberIds==reference_requirements.groupMemberIds \
		and capsule_requirements.crossingIds==reference_requirements.crossingIds \
		and capsule_requirements.missingSourceIds==reference_requirements.missingSourceIds \
		and capsule_requirements.unresolvedCrossingIds==reference_requirements.unresolvedCrossingIds \
		and indexed_regions.size()==reference_regions.size()
	for rectangle: Rect2i in indexed_regions: parity=parity and reference_regions.has(rectangle)
	var moving_started := Time.get_ticks_usec()
	var moving_max_usec := 0
	for index: int in range(128):
		var query := Rect2i(CAPSULE_BOUNDS.position+Vector2i(index%8,floori(float(index)/8.0)%8),CAPSULE_BOUNDS.size)
		var query_started := Time.get_ticks_usec()
		var moving: Dictionary=base.description.regional_group_requirements(query)
		moving_max_usec=maxi(moving_max_usec,Time.get_ticks_usec()-query_started)
		if moving.get("status")!="described": report.reason="moving_index_query_failed"; return report
	# Match the production player retention request, including its 16-cell
	# reversal margin. A fast capsule lookup alone cannot catch repeated closure
	# expansion across the 8x8-ish tile area that moves with the player.
	var broad_bounds := bounds.grow(16)
	var broad_started := Time.get_ticks_usec()
	var broad_requirements: Dictionary=base.description.regional_group_requirements(broad_bounds)
	var broad_indexed_usec := Time.get_ticks_usec()-broad_started
	broad_started=Time.get_ticks_usec()
	var broad_spatial_crossings: Dictionary=base.description.requirements(broad_bounds,{},true,true)
	var broad_spatial_crossings_usec := Time.get_ticks_usec()-broad_started
	broad_started=Time.get_ticks_usec()
	var broad_spatial_only: Dictionary=base.description.requirements(broad_bounds,{},true,false)
	var broad_spatial_only_usec := Time.get_ticks_usec()-broad_started
	broad_started=Time.get_ticks_usec()
	var broad_reference: Dictionary=base.description._legacy_regional_group_requirements(broad_bounds)
	var broad_reference_usec := Time.get_ticks_usec()-broad_started
	broad_started=Time.get_ticks_usec()
	var broad_scheduling: Dictionary=base.description.regional_scheduling_requirements(broad_bounds)
	var broad_scheduling_usec := Time.get_ticks_usec()-broad_started
	var broad_indexed_regions: Dictionary={}
	var broad_reference_regions: Dictionary={}
	for rectangle: Rect2i in broad_requirements.get("dependencyBounds",[]): broad_indexed_regions[rectangle]=true
	for rectangle: Rect2i in broad_reference.get("dependencyBounds",[]): broad_reference_regions[rectangle]=true
	var broad_scheduling_regions: Dictionary={}
	for rectangle: Rect2i in broad_scheduling.get("dependencyBounds",[]): broad_scheduling_regions[rectangle]=true
	var broad_scheduling_parity: bool=broad_scheduling.get("status")=="described" \
		and broad_scheduling.get("groupIds",[])==broad_reference.get("groupIds",[]) \
		and broad_reference.get("crossingIds",[]).all(func(id): return broad_scheduling.get("crossingIds",[]).has(id)) \
		and broad_reference.get("missingSourceIds",[]).all(func(id): return broad_scheduling.get("missingSourceIds",[]).has(id)) \
		and broad_reference.get("unresolvedCrossingIds",[]).all(func(id): return broad_scheduling.get("unresolvedCrossingIds",[]).has(id)) \
		and broad_reference_regions.keys().all(func(rectangle): return broad_scheduling_regions.has(rectangle))
	var broad_parity: bool=broad_requirements.get("status")=="described" and broad_reference.get("status")=="described" \
		and broad_requirements.groupIds==broad_reference.groupIds \
		and broad_requirements.groupMemberIds==broad_reference.groupMemberIds \
		and broad_requirements.crossingIds==broad_reference.crossingIds \
		and broad_requirements.missingSourceIds==broad_reference.missingSourceIds \
		and broad_requirements.unresolvedCrossingIds==broad_reference.unresolvedCrossingIds \
		and broad_indexed_regions.size()==broad_reference_regions.size() \
		and broad_indexed_regions.keys().all(func(rectangle): return broad_reference_regions.has(rectangle))
	report["regionalIndex"]={"ready":base.description.regional_tile_index_ready,
		"tileCount":base.description.regional_tile_requirements.size(),
		"deepReadOnly":base.description.regional_tile_requirements.is_read_only(),
		"capsuleReferenceParity":parity,"legacyCapsuleUsec":reference_usec,
		"groupParity":capsule_requirements.groupIds==reference_requirements.groupIds,
		"memberParity":capsule_requirements.groupMemberIds==reference_requirements.groupMemberIds,
		"crossingParity":capsule_requirements.crossingIds==reference_requirements.crossingIds,
		"missingParity":capsule_requirements.missingSourceIds==reference_requirements.missingSourceIds,
		"unresolvedParity":capsule_requirements.unresolvedCrossingIds==reference_requirements.unresolvedCrossingIds,
		"regionParity":indexed_regions.size()==reference_regions.size() and indexed_regions.keys().all(func(rectangle): return reference_regions.has(rectangle)),
		"indexedGroupCount":capsule_requirements.groupIds.size(),"referenceGroupCount":reference_requirements.groupIds.size(),
		"missingIndexedGroups":reference_requirements.groupIds.filter(func(id): return not capsule_requirements.groupIds.has(id)),
		"extraIndexedGroups":capsule_requirements.groupIds.filter(func(id): return not reference_requirements.groupIds.has(id)),
		"missingIndexedRegions":reference_regions.keys().filter(func(rectangle): return not indexed_regions.has(rectangle)),
		"extraIndexedRegions":indexed_regions.keys().filter(func(rectangle): return not reference_regions.has(rectangle)),
		"indexedCrossingIds":capsule_requirements.crossingIds,"referenceCrossingIds":reference_requirements.crossingIds,
		"movingQueryCount":128,"movingTotalUsec":Time.get_ticks_usec()-moving_started,"movingMaxUsec":moving_max_usec,
		"broadBounds":broad_bounds,"broadParity":broad_parity,"broadIndexedUsec":broad_indexed_usec,
		"broadSchedulingUsec":broad_scheduling_usec,"broadSchedulingParity":broad_scheduling_parity,
		"broadSchedulingCrossingCount":broad_scheduling.get("crossingIds",[]).size(),
		"broadSpatialCrossingsUsec":broad_spatial_crossings_usec,"broadSpatialOnlyUsec":broad_spatial_only_usec,
		"broadSpatialCrossingCount":broad_spatial_crossings.get("crossingIds",[]).size(),
		"broadSpatialPartCount":broad_spatial_only.get("partIds",[]).size(),
		"broadReferenceUsec":broad_reference_usec,"broadGroupCount":broad_requirements.get("groupIds",[]).size(),
		"broadReferenceGroupCount":broad_reference.get("groupIds",[]).size(),
		"broadMissingGroups":broad_reference.get("groupIds",[]).filter(func(id): return not broad_requirements.get("groupIds",[]).has(id)),
		"broadExtraGroups":broad_requirements.get("groupIds",[]).filter(func(id): return not broad_reference.get("groupIds",[]).has(id)),
		"broadMemberParity":broad_requirements.get("groupMemberIds",[])==broad_reference.get("groupMemberIds",[]),
		"broadCrossingParity":broad_requirements.get("crossingIds",[])==broad_reference.get("crossingIds",[]),
		"broadIndexedCrossingIds":broad_requirements.get("crossingIds",[]),
		"broadReferenceCrossingIds":broad_reference.get("crossingIds",[]),
		"broadMissingParity":broad_requirements.get("missingSourceIds",[])==broad_reference.get("missingSourceIds",[]),
		"broadUnresolvedParity":broad_requirements.get("unresolvedCrossingIds",[])==broad_reference.get("unresolvedCrossingIds",[]),
		"broadMissingRegions":broad_reference_regions.keys().filter(func(rectangle): return not broad_indexed_regions.has(rectangle)),
		"broadExtraRegions":broad_indexed_regions.keys().filter(func(rectangle): return not broad_reference_regions.has(rectangle)),
		"broadTileCount":broad_requirements.get("navigationTileKeys",[]).size()}
	if not base.description.regional_tile_index_ready or base.description.regional_tile_requirements.is_empty() \
			or not base.description.regional_tile_requirements.is_read_only() or not parity or not broad_parity or not broad_scheduling_parity:
		report.reason="regional_membership_index_invalid"; return report
	var low:=Vector2i(floori(float(bounds.position.x)/float(tile_cells)),floori(float(bounds.position.y)/float(tile_cells)))
	var high:=Vector2i(floori(float(bounds.end.x-1)/float(tile_cells)),floori(float(bounds.end.y-1)/float(tile_cells)))
	var rows: Array[Dictionary]=[]
	var any_complete_packet := false
	var complete_packet_count := 0
	var total_groups := {}
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var tile:=Vector2i(x,z)
			var closure: Dictionary=base.description.physical_group_requirements(Rect2i(tile*tile_cells,Vector2i.ONE*tile_cells))
			if closure.get("status")!="described": report.reason="tile_closure_"+String(closure.get("reason","not_described")); return report
			var ids: Array=closure.get("groupIds",[]).duplicate(); ids.sort()
			var blockers := {"aperture":0,"door":0,"furniture":0,"tree":0,"unsupported":0}
			var families := {"normal":0,"jointed_paving":0}
			var static_only := 0
			var all_eligible := true
			var all_representable := true
			for raw_id in ids:
				var id:=String(raw_id); total_groups[id]=true
				var entry: Dictionary=census.groups.get(id,{})
				if not entry.get("eligible",false):
					all_eligible=false
					for raw_reason in entry.get("reasons",[]):
						var reason:=String(raw_reason)
						blockers[reason]=int(blockers.get(reason,0))+1
				var has_family := false
				for raw_family in entry.get("families",[]):
					var family:=String(raw_family); has_family=true
					if not SUPPORTED_FAMILIES.has(family): all_representable=false
					else: families[family]=int(families.get(family,0))+1
				if not has_family and entry.get("eligible",false): static_only+=1
			var candidate: bool=not ids.is_empty() and all_eligible and all_representable
			any_complete_packet = any_complete_packet or candidate
			if candidate: complete_packet_count+=1
			rows.append({"tileKey":"%d,%d" % [x,z],"bounds":Rect2i(tile*tile_cells,Vector2i.ONE*tile_cells),"groupIds":ids,"groupCount":ids.size(),
				"packetEligibility":{"allGroupsEligible":all_eligible,"blockerGroupCounts":blockers,"familyGroupCounts":families,"eligibleStaticOnlyGroupCount":static_only,
				"completePacketPathSupported":candidate}})
	var spawn_tile:=Vector2i(floori(float(SPAWN_CELL.x)/float(tile_cells)),floori(float(SPAWN_CELL.y)/float(tile_cells)))
	report["safetyBounds"]=bounds; report["navigationTileCells"]=tile_cells; report["spawnTileKey"]="%d,%d" % [spawn_tile.x,spawn_tile.y]
	report["capsuleClosure"]={"bounds":CAPSULE_BOUNDS,"navigationTileKeys":capsule_requirements.get("navigationTileKeys",[]),
		"groupIds":capsule_requirements.get("groupIds",[]),"crossingIds":capsule_requirements.get("crossingIds",[]),
		"dependencyBounds":capsule_requirements.get("dependencyBounds",[]),"requiredCrossingCount":capsule_requirements.get("requiredCrossings",{}).size()}
	report["tiles"]=rows; report["summary"]={"tileCount":rows.size(),"uniqueClosureGroupCount":total_groups.size(),"anyCompletePacketClosure":any_complete_packet,
		"completePacketClosureCount":complete_packet_count}
	report.complete=true; report.passed=not rows.is_empty()
	return report
