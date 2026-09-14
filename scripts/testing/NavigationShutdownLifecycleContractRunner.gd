extends SceneTree

const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const BuildingClearanceScript := preload("res://scripts/buildings/layout/BuildingLayoutClearance.gd")
const RoutePublicationAdapter := preload("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
const NavigationPublicationWorkerScript := preload("res://scripts/npc_ai/navigation/NavigationPublicationWorker.gd")
const NavigationPublicationSourceScript := preload("res://scripts/npc_ai/navigation/NavigationPublicationSource.gd")
const FiniteBoundsAdapter := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const CaptureCursor := preload("res://scripts/npc_ai/navigation/NavigationTileCapture.gd")
const FilterKernel := preload("res://scripts/npc_ai/navigation/NavigationTileFilter.gd")

class SyntheticPublicationWorld extends RefCounted:
	var seed_text := "async-contract-seed-a"
	var runtime_perf_monitor = null

class SyntheticPublicationOwner extends RefCounted:
	var main = SyntheticPublicationWorld.new()
	var source_key := "async-contract-source:1"
	var source_key_delay_usec := 0
	func navmesh_tile_source_key_for_tile(_tile: String) -> String:
		if source_key_delay_usec > 0: OS.delay_usec(source_key_delay_usec)
		return source_key

class SyntheticQueuedPublicationOwner extends SyntheticPublicationOwner:
	var captured := {}
	var capture_calls: Array[String] = []
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		capture_calls.append(key)
		if captured.has(key): return captured[key].duplicate(false)
		var x: int = int(key.get_slice(",",0))*16
		var snapshot := {"tileKey":key,"publicationStatus":"ready","sourceKey":source_key,
			"worldSeed":main.seed_text,"sourceRevision":1,
			"surfaces":[{"cell":Vector3i(x,0,0),"spanIndex":0,"worldPosition":Vector3(x*1.35,0,0)}]}
		snapshot["publicationSource"] = NavigationPublicationSourceScript.new().capture(snapshot)
		snapshot["publicationOwner"] = weakref(self)
		captured[key] = snapshot
		return snapshot.duplicate(false)

class SyntheticPendingCaptureOwner extends SyntheticPublicationOwner:
	var active_capture_queries := 0
	var capture_releases := 0
	var active_tile := "0,0"
	var capture_calls: Array[String] = []
	func active_navigation_capture_tile() -> String:
		active_capture_queries += 1
		return active_tile
	func active_navigation_capture_source(tile_key: String) -> Dictionary:
		if tile_key != active_tile or active_tile.is_empty(): return {}
		return {"sourceKey":source_key,"sources":[]}
	func release_navigation_capture_slot(expected_tile := "", expected_source := "") -> void:
		if not expected_tile.is_empty() and expected_tile != active_tile: return
		if not expected_source.is_empty() and expected_source != source_key: return
		capture_releases += 1
		active_tile = ""
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		capture_calls.append(key)
		return {"tileKey":key,"publicationStatus":"pending","reason":"navigation_capture_pending"}

class SyntheticFrameBudgetCaptureOwner extends SyntheticPublicationOwner:
	var active_tile := "0,0"
	var capture_calls: Array[String] = []
	var frame_budget_used := true
	func active_navigation_capture_tile() -> String:
		return active_tile
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		capture_calls.append(key)
		return {"tileKey":key,"publicationStatus":"pending",
			"reason":"navigation_capture_frame_budget_used" if frame_budget_used else "navigation_capture_pending"}

class PendingSourceFixture extends SyntheticQueuedPublicationOwner:
	var ready := false
	func _init() -> void: source_key = "pending-source-contract:1"
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		if key=="0,0" and not ready:
			return {"tileKey":key,"publicationStatus":"pending","reason":"fixture_source_pending"}
		return super.build_navmesh_tile_snapshot(key)

class RejectingInstallFixture extends NavmeshWorldServiceScript:
	var reject_install := true
	func register_tile_snapshot(snapshot: Dictionary) -> Dictionary:
		if reject_install: return {"status":"rejected","reason":"synthetic_install_rejection","installed":false}
		return super.register_tile_snapshot(snapshot)

class ExpensiveIdlePublicationService extends NavmeshWorldServiceScript:
	var idle_advance_calls := 0
	func advance_publication(_budget_usec := 4000) -> Dictionary:
		idle_advance_calls += 1
		OS.delay_usec(1000)
		return {"status":"idle"}
	func active_publication_request() -> Dictionary:
		return {"tileKey":"","status":"idle"}
	func publication_sync_pending() -> bool:
		return false

const REGION_COUNT := 17
const LINK_COUNT := 16

var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var baseline_maps := navigation_map_ids()
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.default_config())
	for index in range(REGION_COUNT):
		var descriptor = NavigationBakeDescriptorScript.create(
			"shutdown-contract-region-%d" % index,
			"shutdown-contract-tile-%d" % index
		)
		var center := Vector3(float(index) * 2.0, 0.0, 0.0)
		descriptor.add_walkable_surface("surface-%d" % index, center, Vector3(1.35, 0.05, 1.35))
		if index < LINK_COUNT:
			var portal_id := "shutdown-contract-door-%d" % index
			descriptor.add_door_portal(portal_id, center + Vector3(-0.4, 0.0, 0.0), center + Vector3(0.4, 0.0, 0.0))
			descriptor.add_door_link("from-%d" % index, "to-%d" % index, portal_id)
		service.register_chunk_descriptor(descriptor)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var before_release: Dictionary = service.stats()
	add_result(
		"fixture_owns_expected_navigation_resources",
		int(before_release.get("installedRegionCount", 0)) == REGION_COUNT and int(before_release.get("installedDoorLinkCount", 0)) == LINK_COUNT,
		before_release
	)
	service.clear()
	await physics_frame
	await process_frame
	await physics_frame
	var after_release: Dictionary = service.stats()
	var final_maps := navigation_map_ids()
	add_result(
		"clear_releases_owned_navigation_map",
		final_maps == baseline_maps,
		{"baselineMaps": baseline_maps, "finalMaps": final_maps, "stats": after_release}
	)
	add_result(
		"clear_releases_all_service_rid_records",
		not bool(after_release.get("hasNavigationMap", true)) and int(after_release.get("installedRegionCount", -1)) == 0 and int(after_release.get("installedDoorLinkCount", -1)) == 0,
		after_release
	)
	await verify_clear_flushes_before_map_release()
	await verify_autonomy_reset_keeps_navmesh_owner()
	await verify_tile_publication_receipts()
	await verify_grouped_door_publication_receipts()
	verify_source_rectangle_coverage()
	await verify_conforming_grid_obstacle_route()
	await verify_canonical_grid_tile_seam_route()
	verify_publication_rectangle_clearance()
	await verify_finite_live_collision_bounds()
	await verify_pending_source_retention()
	verify_retained_priority_promotion()
	verify_navmesh_queue_owner_release()
	await verify_active_capture_foreground_arbitration()
	await verify_unqueued_capture_continuation_precedes_foreground()
	verify_idle_publication_does_not_consume_capture_deadline()
	await verify_large_frontier_foreground_arbitration()
	await verify_capture_continuation_and_locality()
	await verify_capture_synchronous_entry_proof()
	await verify_navigation_worker_parity_and_ownership()
	await verify_filter_input_lifecycle()
	await verify_accepted_tile_state_contract()
	await verify_accepted_last_tile_scheduler()
	await verify_async_navigation_service_lifecycle()
	await verify_owned_publication_queue_progress()
	verify_incremental_prop_navigation_cache_locality()
	await verify_capture_retirement_publication_handoff()
	await verify_direct_capture_source_handoff()
	await verify_async_navigation_orphaned_recapture()
	await verify_prepared_navigation_portal_filter_retirement()
	write_report()
	quit(0 if failures() == 0 else 1)

func verify_navmesh_queue_owner_release() -> void:
	# Production queue bookkeeping with synthetic source/service facts. This
	# proves co-ownership and completion retention, not live route traversal.
	var service := ExpensiveIdlePublicationService.new()
	service.setup()
	var world := SyntheticQueuedPublicationOwner.new()
	var publisher := RoutePublicationAdapter.new()
	publisher.world = world
	publisher.main = world.main
	publisher.navmesh_world = service
	var regional_a := {"kind":"regional_streaming","id":"fixture:a"}
	var regional_b := {"kind":"regional_streaming","id":"fixture:b"}
	var source := world.source_key
	publisher.queue_navmesh_tile_publish("0,0",false,regional_a)
	publisher.queue_navmesh_tile_publish("0,0",false,regional_b)
	var shared_before: Dictionary = publisher.queued_navmesh_tile_contexts.get("0,0",{})
	var owners_before: Dictionary = publisher._queue_owner_keys_for_context(shared_before)
	var first_release := publisher.release_navmesh_tile_publish_owner("0,0",regional_a)
	var retained_after_first := publisher.queued_navmesh_tile_source_keys.has("0,0")
	var second_release := publisher.release_navmesh_tile_publish_owner("0,0",regional_b)
	add_result("regional_queue_releases_only_after_last_idle_owner",first_release and second_release \
		and owners_before.size()==2 and retained_after_first \
		and not publisher.queued_navmesh_tile_source_keys.has("0,0"),{
		"ownersBefore":owners_before.keys(),"retainedAfterFirst":retained_after_first})

	publisher.queue_navmesh_tile_publish("1,0",false,regional_a)
	publisher._enqueue_navmesh_tile_publish("1,0",source,true,{
		"reason":"ensure_route_tiles","actorId":"fixture-route"})
	publisher.release_navmesh_tile_publish_owner("1,0",regional_a)
	var route_owners := publisher._queue_owner_keys_for_context(
		publisher.queued_navmesh_tile_contexts.get("1,0",{}))
	add_result("regional_release_preserves_coalesced_route_owner",
		publisher.queued_navmesh_tile_source_keys.has("1,0") \
		and route_owners.keys()==["route:fixture-route"],{"owners":route_owners.keys()})

	publisher.queue_navmesh_tile_publish("2,0",false)
	var anonymous_release := publisher.release_navmesh_tile_publish_owner("2,0",regional_a)
	add_result("unknown_external_queue_owner_fails_closed",not anonymous_release \
		and publisher.queued_navmesh_tile_source_keys.has("2,0"),{
		"owners":publisher._queue_owner_keys_for_context(
			publisher.queued_navmesh_tile_contexts.get("2,0",{})).keys()})

	var capture_world := SyntheticPendingCaptureOwner.new()
	publisher.invalidate()
	publisher.world = capture_world
	publisher.main = capture_world.main
	publisher.queue_navmesh_tile_publish("0,0",true,regional_a)
	var active_release := publisher.release_navmesh_tile_publish_owner("0,0",regional_a)
	var retained_context: Dictionary = publisher.queued_navmesh_tile_contexts.get("0,0",{}).duplicate(true)
	var retained_while_active := active_release and bool(retained_context.get("discardAfterCompletion",false)) \
		and publisher.queued_navmesh_tile_source_keys.has("0,0")
	capture_world.active_tile = ""
	publisher._restore_queued_navmesh_tile("0,0",capture_world.source_key,true,retained_context)
	add_result("ownerless_active_capture_finishes_before_retry_is_discarded",retained_while_active \
		and not publisher.queued_navmesh_tile_source_keys.has("0,0"),{
		"retainedWhileActive":retained_while_active,"captureReleases":capture_world.capture_releases})

	capture_world.active_tile = "0,0"
	publisher.queue_navmesh_tile_publish("0,0",true,regional_a)
	publisher.release_navmesh_tile_publish_owner("0,0",regional_a)
	publisher._enqueue_navmesh_tile_publish("0,0",capture_world.source_key,true,{
		"reason":"ensure_route_tiles","actorId":"late-route"})
	var late_context: Dictionary = publisher.queued_navmesh_tile_contexts.get("0,0",{})
	add_result("new_route_demand_clears_deferred_regional_discard",
		not bool(late_context.get("discardAfterCompletion",false)) \
		and publisher._queue_owner_keys_for_context(late_context).has("route:late-route"),late_context)
	publisher.invalidate()
	publisher.world = null
	publisher.main = null
	publisher.navmesh_world = null
	service.clear()

func verify_incremental_prop_navigation_cache_locality() -> void:
	# Service-level cache ownership contract. This does not prove live prop
	# publication or NPC traversal; it proves exact-tile invalidation only.
	var world := SyntheticFiniteBoundsWorld.new()
	var adapter := SyntheticFiniteBoundsAdapter.new()
	adapter.setup(null,world)
	adapter.cached_revision = "10"
	adapter.static_snapshot_revision = 10
	adapter.navmesh_tile_revision_by_key = {"0,0":10,"1,0":10}
	var changed_key := "0,0|changed"
	var retained_key := "1,0|retained"
	adapter.navmesh_tile_snapshot_cache = {
		changed_key:{"tileKey":"0,0","marker":"changed"},
		retained_key:{"tileKey":"1,0","marker":"retained"}
	}
	adapter.navmesh_tile_snapshot_cache_order = [changed_key,retained_key]
	var unrelated_source_before: String = adapter.navmesh_tile_source_key_for_tile("1,0")
	adapter._mark_incremental_static_change("0,0")
	var local_passed: bool = not adapter.navmesh_tile_snapshot_cache.has(changed_key) \
		and adapter.navmesh_tile_snapshot_cache.has(retained_key) \
		and adapter.navmesh_tile_snapshot_cache_order == [retained_key] \
		and adapter.navmesh_tile_source_key_for_tile("1,0") == unrelated_source_before \
		and adapter.navmesh_tile_source_key_for_tile("0,0") != unrelated_source_before
	add_result("incremental_prop_change_invalidates_only_affected_navigation_tile",local_passed,
		{"remainingCacheKeys":adapter.navmesh_tile_snapshot_cache.keys(),
			"changedSource":adapter.navmesh_tile_source_key_for_tile("0,0"),
			"unrelatedSource":adapter.navmesh_tile_source_key_for_tile("1,0")})
	adapter._mark_incremental_static_change("")
	add_result("unscoped_static_change_keeps_conservative_full_invalidation",
		adapter.navmesh_tile_snapshot_cache.is_empty() and adapter.navmesh_tile_snapshot_cache_order.is_empty(),{})
	adapter.main = null
	world.free()

func verify_source_rectangle_coverage() -> void:
	# Synthetic geometry/ownership contract, not a live traversal claim.
	var service = NavmeshWorldServiceScript.new()
	var surfaces: Array = []
	for spec in [[0,0,0,"a"],[1,0,0,"a"],[0,1,0,"a"],[0,0,2,"a"],[2,0,0,"b"]]:
		var x: float=spec[0]; var z: float=spec[1]; var y: float=spec[2]
		surfaces.append({"id":"cell-%d" % surfaces.size(),"supportId":spec[3],"walkable":true,
			"polygon":[Vector3(x,y,z),Vector3(x,y,z+1),Vector3(x+1,y,z+1),Vector3(x+1,y,z)]})
	var before := var_to_bytes(surfaces)
	var ownership := {}
	var polygons: Array = service._navigation_mesh_polygons_for_surfaces(surfaces,ownership)
	add_result("source_rectangle_merge_retains_every_identity",ownership.size()==5 and polygons.size()==4,{"owners":ownership,"polygonCount":polygons.size()})
	add_result("source_rectangle_merge_preserves_input",before==var_to_bytes(surfaces),{})
	var area := 0.0
	var covers_hole := false
	for polygon: Array in polygons:
		var bounds := AABB(polygon[0],Vector3.ZERO)
		for point: Vector3 in polygon: bounds=bounds.expand(point)
		area+=bounds.size.x*bounds.size.z
		if polygon[0].y==0 and Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)).has_point(Vector2(1.5,1.5)): covers_hole=true
	add_result("source_rectangle_union_preserves_area_and_holes",area==5.0 and not covers_hole,{"area":area,"coversHole":covers_hole})
	add_result("source_rectangle_height_and_owner_separation",ownership["cell-0"]!=ownership["cell-3"] and ownership["cell-1"]!=ownership["cell-4"],{})
	var bowtie: Array = surfaces[0].polygon.duplicate()
	var point: Vector3 = bowtie[1]; bowtie[1]=bowtie[2]; bowtie[2]=point
	add_result("source_rectangle_invalid_order_not_reinterpreted",service._source_rectangle(surfaces[0],bowtie).is_empty(),{})
	var slope: Array = surfaces[0].polygon.duplicate()
	slope[1].y=1.0
	add_result("source_rectangle_nonplanar_not_reinterpreted",service._source_rectangle(surfaces[0],slope).is_empty(),{})
	var grade: Array = []
	for x: float in [0.0,1.0]:
		grade.append({"id":"grade-%d" % int(x),"supportId":"grade","polygon":[Vector3(x,0,0),Vector3(x,1,1),Vector3(x+1,1,1),Vector3(x+1,0,0)]})
	var grade_owners := {}
	var merged: Array = service._navigation_mesh_polygons_for_surfaces(grade,grade_owners)
	add_result("source_rectangle_grade_cross_sections_preserved",merged.size()==1 and merged[0]==[Vector3(0,0,0),Vector3(0,1,1),Vector3(2,1,1),Vector3(2,0,0)] and grade_owners.size()==2,{})
	var adjacent: Array = [surfaces[0].duplicate(true),surfaces[1].duplicate(true)]
	adjacent[0].supportId="part-left"; adjacent[1].supportId="part-right"
	for item: Dictionary in adjacent: item.geometryGroupId="same-revision-bound-building"
	var adjacent_owners := {}
	var combined: Array = service._navigation_mesh_polygons_for_surfaces(adjacent,adjacent_owners)
	add_result("source_rectangle_declared_group_keeps_part_identities",combined.size()==1 and adjacent_owners.size()==2 and adjacent[0].supportId=="part-left" and adjacent[1].supportId=="part-right",{})

func verify_conforming_grid_obstacle_route() -> void:
	# Synthetic service contract using the real mesh preparation and
	# NavigationServer map. A partial wall forces the route through a turn where
	# greedy rectangles meet at T-junctions; it does not prove live NPC movement.
	var baseline_maps := navigation_map_ids()
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.default_config())
	var descriptor = NavigationBakeDescriptorScript.create("region:chunk:obstacle-contract", "obstacle-contract")
	var cell_size: float = preload("res://scripts/npc_ai/NpcConstants.gd").CELL_SIZE
	for z in range(9):
		for x in range(9):
			if x == 4 and z >= 2 and z <= 6:
				continue
			descriptor.add_walkable_surface("obstacle-cell:%d,%d" % [x,z],
				Vector3(float(x)*cell_size,0.0,float(z)*cell_size),
				Vector3(cell_size,0.05,cell_size), {"cell":Vector3i(x,0,z)})
	var ownership := {}
	var polygons: Array = service._navigation_mesh_polygons_for_surfaces(descriptor.walkable_surfaces,ownership)
	var installed: Dictionary = service.register_chunk_descriptor(descriptor,"obstacle-contract:1")
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var start := Vector3(cell_size,0.0,cell_size*4.0)
	var target := Vector3(cell_size*7.0,0.0,cell_size*4.0)
	var region_rid: RID = service.region_rids_by_region.get(descriptor.region_id,RID())
	var path := PackedVector3Array()
	var endpoints_owned := false
	for frame in 120:
		endpoints_owned = region_rid.is_valid() \
			and NavigationServer3D.map_get_closest_point_owner(service.navigation_map,start)==region_rid \
			and NavigationServer3D.map_get_closest_point_owner(service.navigation_map,target)==region_rid
		if endpoints_owned:
			path=NavigationServer3D.map_get_path(service.navigation_map,start,target,true)
			if not path.is_empty(): break
		await physics_frame
	var reaches_target := path.size()>=3 and path[-1].distance_to(target)<=cell_size*0.1
	var turns_around_wall := false
	for point: Vector3 in path:
		if absf(point.z-start.z)>=cell_size*2.0:
			turns_around_wall=true
			break
	add_result("grid_rectangle_compaction_retains_conforming_edges",
		polygons.size()<descriptor.walkable_surfaces.size() and ownership.size()==descriptor.walkable_surfaces.size(),
		{"surfaceCount":descriptor.walkable_surfaces.size(),"polygonCount":polygons.size(),"ownerCount":ownership.size()})
	add_result("navigation_server_routes_around_grid_obstacle",
		installed.get("installed",false) and endpoints_owned and reaches_target and turns_around_wall,
		{"installed":installed,"endpointsOwned":endpoints_owned,"path":Array(path)})
	service.clear()
	await physics_frame
	await process_frame
	add_result("grid_obstacle_contract_releases_navigation_map",navigation_map_ids()==baseline_maps,
		{"baselineMaps":baseline_maps,"finalMaps":navigation_map_ids()})

func verify_canonical_grid_tile_seam_route() -> void:
	# Two separately compiled tile regions must expose the same cell-sized edge
	# segments. This is a synthetic NavigationServer seam contract.
	var baseline_maps := navigation_map_ids()
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.default_config())
	var cell_size: float = preload("res://scripts/npc_ai/NpcConstants.gd").CELL_SIZE
	var descriptors := []
	var registrations := []
	for tile_x in 2:
		var tile_key := "%d,0" % tile_x
		var descriptor = NavigationBakeDescriptorScript.create("region:chunk:seam-%s" % tile_key,"seam-%s" % tile_key)
		for z in 16:
			for local_x in 16:
				var x := tile_x*16+local_x
				descriptor.add_walkable_surface("seam-cell:%d,%d" % [x,z],
					Vector3(float(x)*cell_size,0.0,float(z)*cell_size),
					Vector3(cell_size,0.05,cell_size),{"cell":Vector3i(x,0,z)})
		registrations.append(service.register_chunk_descriptor(descriptor,"seam-source:%d" % tile_x))
		descriptors.append(descriptor)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var start := Vector3(14.0*cell_size,0.0,8.0*cell_size)
	var target := Vector3(17.0*cell_size,0.0,8.0*cell_size)
	var path := PackedVector3Array()
	var endpoint_owners := []
	for frame in 120:
		endpoint_owners=[NavigationServer3D.map_get_closest_point_owner(service.navigation_map,start),
			NavigationServer3D.map_get_closest_point_owner(service.navigation_map,target)]
		if endpoint_owners[0]==service.region_rids_by_region.get(descriptors[0].region_id,RID()) \
				and endpoint_owners[1]==service.region_rids_by_region.get(descriptors[1].region_id,RID()):
			path=NavigationServer3D.map_get_path(service.navigation_map,start,target,true)
			if not path.is_empty(): break
		await physics_frame
	var left_polygons: Array = service._navigation_mesh_polygons_for_surfaces(descriptors[0].walkable_surfaces)
	var right_polygons: Array = service._navigation_mesh_polygons_for_surfaces(descriptors[1].walkable_surfaces)
	add_result("canonical_grid_perimeter_keeps_flat_tiles_compact_and_bounded",
		left_polygons.size()==1 and right_polygons.size()==1 \
			and left_polygons[0].size()==4 and right_polygons[0].size()==4,
		{"leftPolygonCount":left_polygons.size(),"rightPolygonCount":right_polygons.size(),
			"leftPerimeterVertices":left_polygons.map(func(polygon): return polygon.size()),
			"rightPerimeterVertices":right_polygons.map(func(polygon): return polygon.size())})
	add_result("navigation_server_routes_across_canonical_grid_tile_seam",
		path.size()>=2 and path[-1].distance_to(target)<=cell_size*0.1,
		{"path":Array(path),"endpointOwners":endpoint_owners,"registrations":registrations,
			"regionRids":service.region_rids_by_region.duplicate(),"stats":service.stats()})
	service.clear()
	await physics_frame
	await process_frame
	add_result("grid_tile_seam_contract_releases_navigation_map",navigation_map_ids()==baseline_maps,
		{"baselineMaps":baseline_maps,"finalMaps":navigation_map_ids()})

func verify_publication_rectangle_clearance() -> void:
	# Synthetic shape contract. A corner blocker misses the diagonal but not
	# the full published area; a contained blocker need not touch its perimeter.
	var clearance = BuildingClearanceScript.new()
	var corner := [Vector3(0.9,0,-0.1),Vector3(0.9,0,0.1),Vector3(1.1,0,0.1),Vector3(1.1,0,-0.1)]
	add_result("publication_rectangle_rejects_off_diagonal_corner",clearance._footprint_intersects_rectangle(Vector2.ZERO,Vector2.ONE,corner,0.0),{})
	add_result("publication_rectangle_preserves_segment_predicate",not clearance._footprint_intersects_segment(Vector2.ZERO,Vector2.ONE,corner,0.0),{})
	var enclosed := [Vector3(0.1,0,0.6),Vector3(0.1,0,0.8),Vector3(0.3,0,0.8),Vector3(0.3,0,0.6)]
	add_result("publication_rectangle_rejects_contained_blocker",clearance._footprint_intersects_rectangle(Vector2.ZERO,Vector2.ONE,enclosed,0.0),{})
	add_result("publication_rectangle_preserves_clear_separation",not clearance._footprint_intersects_rectangle(Vector2(3,3),Vector2(4,4),corner,0.52),{})

class SyntheticFiniteBoundsWorld extends Node3D:
	var seed_text := "synthetic-finite-live-collider-bounds"
	var WATER_LEVEL := -1000.0
	var blocks := {}
	var prop_root: Node3D
	var structure_system = null
	var runtime_perf_monitor = null
	var world_generation_system = null
	var player = null
	func surface_y_at_cell(_cell) -> float: return 0.0

class SyntheticFiniteBoundsAdapter extends FiniteBoundsAdapter:
	# Only the smart-object lookup is synthetic; scan/event/record/index/source
	# publication are the actual adapter code under test.
	var fixture_props := {}
	var fixture_collision_reads: Array[String] = []
	func _registered_prop_node(object_id: String) -> Node3D:
		return fixture_props.get(object_id)
	func _collision_records_for_body(body: Node, cell: Vector2i, block_type: String, is_door: bool) -> Array[Dictionary]:
		fixture_collision_reads.append(body.name)
		return super._collision_records_for_body(body,cell,block_type,is_door)

class SyntheticCaptureGeneration extends RefCounted:
	var generated_site_profiles: Array = []
	var terrain_volume_service = null

class SyntheticCaptureVolume extends RefCounted:
	var revision := 0

class SyntheticEntryProofStructures extends RefCounted:
	# Simulated physical-proof availability, not a structure publication receipt.
	# No source revision changes when this proof becomes pending.
	var proof_pending := false
	func navigation_tile_sources(_tile: Vector2i) -> Dictionary:
		if proof_pending:
			return {"status":"pending","reason":"synthetic_structure_physical_proof_pending"}
		return {"status":"ready","sources":[]}

class SyntheticEntryProofAdapter extends SyntheticFiniteBoundsAdapter:
	var source_reads := 0
	var fail_proof_at := ""
	var mutation_count := 0
	func building_navigation_sources(tile_key: String) -> Dictionary:
		source_reads += 1
		return super.building_navigation_sources(tile_key)
	func _fail_proof_once(boundary: String) -> void:
		if fail_proof_at != boundary: return
		fail_proof_at = ""
		mutation_count += 1
		main.structure_system.proof_pending = true
	func _height_for_cell_with_caches(cell: Vector2i, heights: Dictionary, projections: Dictionary) -> float:
		var value: float = super._height_for_cell_with_caches(cell,heights,projections)
		_fail_proof_once("slice")
		return value
	func _navmesh_door_summary_for_tile(snapshot: Dictionary, tile_key: String, source_sites: Array[String] = [], capture_heights: Dictionary = {}, capture_projections: Dictionary = {}) -> Dictionary:
		var value: Dictionary = super._navmesh_door_summary_for_tile(snapshot,tile_key,source_sites,capture_heights,capture_projections)
		_fail_proof_once("seal")
		return value

class SyntheticEntryProofService extends NavmeshWorldServiceScript:
	var mutation_count := 0
	var retired_capture_id := 0
	var retired_capture_steps := -1
	func accepted_tile_state(tile_key: String, source_key: String, world_seed: String, owner) -> Dictionary:
		var result: Dictionary = super.accepted_tile_state(tile_key,source_key,world_seed,owner)
		# The real owner check ran. Simulate an intervening validation callback
		# invalidating physical proof before the adapter regains control.
		if mutation_count == 0:
			mutation_count += 1
			owner.main.structure_system.proof_pending = true
		return result
	func retire_navigation_payload(payload: Dictionary) -> void:
		# Observe only scalars in this synchronous call, before worker retirement.
		var cursor = payload.get("capture")
		if cursor != null:
			retired_capture_id = cursor.get_instance_id()
			retired_capture_steps = int(cursor.profile.steps)
		super.retire_navigation_payload(payload)

func finite_fixture_body(parent: Node3D, shape: Shape3D, id: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "FiniteBounds_"+id
	body.set_meta("kind","prop")
	body.set_meta("material","tree")
	body.set_meta("prop_id",id)
	var collider := CollisionShape3D.new()
	collider.name = "Collider"
	collider.shape = shape
	body.add_child(collider)
	parent.add_child(body)
	return body

func verify_finite_live_collision_bounds() -> void:
	# Bounded synthetic collider/publication evidence, not gameplay acceptance.
	var world := SyntheticFiniteBoundsWorld.new()
	world.prop_root = Node3D.new()
	world.add_child(world.prop_root)
	get_root().add_child(world)
	var adapter := SyntheticFiniteBoundsAdapter.new()
	adapter.setup(null,world)
	var box := BoxShape3D.new()
	box.size = Vector3(2,6,4)
	var sphere := SphereShape3D.new()
	sphere.radius = 2.0
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.5
	cylinder.height = 4.0
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.5
	capsule.height = 4.0
	var shapes: Array[Shape3D] = [box,sphere,cylinder,capsule]
	var expected: Array[Vector3] = [Vector3(1,3,2),Vector3(2,2,2),Vector3(0.5,2,0.5),Vector3(0.5,2,0.5)]
	for index in range(shapes.size()):
		var id := "primitive-%d" % index
		var body := finite_fixture_body(world.prop_root,shapes[index],id)
		body.position = Vector3(6,10,-3)
		var collider := body.get_node("Collider") as CollisionShape3D
		collider.position = Vector3(1,2,3)
		var result: Dictionary = adapter._collect_collision_records(body,Vector2i(4,-2),"prop",false)
		var records: Array = result.get("records",[])
		var bounds: AABB = adapter._collision_record_bounds(records[0]) if records.size()==1 else AABB()
		add_result("finite_bounds_primitive_%d" % index,result.get("status")=="ready" and records.size()==1
			and bounds.position.is_equal_approx(Vector3(7,12,0)-expected[index])
			and bounds.size.is_equal_approx(expected[index]*2.0),{"bounds":bounds})
		# 90 degree rotation distinguishes axial height from radius for both
		# cylinder and capsule, and catches the old box centre-plane omission.
		collider.rotation.z = PI*0.5
		result = adapter._collect_collision_records(body,Vector2i(4,-2),"prop",false)
		records = result.get("records",[])
		bounds = adapter._collision_record_bounds(records[0]) if records.size()==1 else AABB()
		var rotated_extent := Vector3(expected[index].y,expected[index].x,expected[index].z)
		add_result("finite_bounds_rotated_%d" % index,bounds.position.is_equal_approx(Vector3(7,12,0)-rotated_extent)
			and bounds.size.is_equal_approx(rotated_extent*2.0),{"bounds":bounds})
		world.prop_root.remove_child(body)
		body.free()
	var trunk := CylinderShape3D.new()
	trunk.radius=0.5; trunk.height=2.0
	var prop := finite_fixture_body(world.prop_root,trunk,"retry-prop")
	(prop.get_node("Collider") as CollisionShape3D).position.y=1.0
	adapter.fixture_props["prop:retry-prop"]=prop
	adapter.build_snapshot({},true,true)
	var initial: Array = adapter.cached_static_collision_records.duplicate(true)
	var old_id := String(initial[0].id) if initial.size()==1 else ""
	adapter._remove_cached_prop_object("prop:retry-prop")
	var removed_clean := adapter.cached_static_collision_records.is_empty() and adapter.cached_static_collision_by_cell.is_empty()
	adapter.apply_navigation_events([{"tileKey":"0,0","revision":10,
		"changeKinds":["prop_created"],"objectIds":["prop:retry-prop"]}])
	var incremental: Array = adapter.cached_static_collision_records
	var same_records: bool = incremental.size()==1 and initial.size()==1 and incremental[0]==initial[0]
	add_result("finite_bounds_initial_incremental_identity_and_removal",removed_clean and same_records
		and old_id=="static:0,0:FiniteBounds_retry-prop:fallback",{})
	var clearance := BuildingClearanceScript.new()
	var support := {"sourcePartId":"synthetic-floor"}
	var low := Vector2(-0.1,-0.1)
	var high := Vector2(0.1,0.1)
	var at_trunk := clearance._building_support_navigation_blocker_from_records(incremental,support,0.0,low,high,0.0,[],true)
	var above_trunk := clearance._building_support_navigation_blocker_from_records(incremental,support,3.0,low,high,0.0,[],true)
	add_result("finite_bounds_actual_overlap_blocks_above_trunk_clear",not at_trunk.is_empty() and above_trunk.is_empty(),{})
	add_result("finite_bounds_probe_xz_predicates_preserved",adapter._point_inside_collision_record(Vector3(0,20,0),incremental[0])
		and adapter._segment_intersects_collision_record(Vector3(-2,20,0),Vector3(2,20,0),incremental[0]),{})
	var second := CollisionShape3D.new()
	second.shape=trunk
	second.position=Vector3(4,1,0)
	prop.add_child(second)
	var compound: Dictionary=adapter._collect_collision_records(prop,Vector2i.ZERO,"prop",false)
	var compound_bounds: AABB=adapter._collision_record_bounds(compound.records[0])
	second.disabled=true
	var disabled: Dictionary=adapter._collect_collision_records(prop,Vector2i.ZERO,"prop",false)
	add_result("finite_bounds_compound_union_disabled_and_identity",compound.records.size()==1 and compound.records[0].id==old_id
		and compound_bounds.position.is_equal_approx(Vector3(-0.5,0,-0.5))
		and compound_bounds.size.is_equal_approx(Vector3(5,2,1))
		and adapter._collision_record_bounds(disabled.records[0]).size.is_equal_approx(Vector3(1,2,1)),{})
	second.free()
	var collider := prop.get_node("Collider") as CollisionShape3D
	var unsupported := ConvexPolygonShape3D.new()
	unsupported.points=PackedVector3Array([Vector3.ZERO,Vector3.RIGHT,Vector3.UP,Vector3.BACK])
	collider.shape=unsupported
	adapter.apply_navigation_events([{"tileKey":"0,0","revision":11,
		"changeKinds":["prop_created"],"objectIds":["prop:retry-prop"]}])
	var rejected: Dictionary=adapter.build_navmesh_tile_snapshot("0,0")
	add_result("finite_bounds_unsupported_source_failed_not_empty_success",rejected.get("publicationStatus")=="failed"
		and rejected.get("collisionError",{}).get("reason")=="unsupported_navigation_collision_shape"
		and not rejected.has("surfaces") and adapter.navmesh_tile_snapshot_cache.is_empty(),rejected)
	# Same retained request, corrected source; recovery must republish actual
	# finite records, advance revision, and never cache the prior error as empty.
	var failed_revision := adapter.static_snapshot_revision
	collider.shape=trunk
	var recovered: Dictionary=await wait_for_navigation_capture(adapter,"0,0")
	add_result("finite_bounds_source_correction_retry",recovered.get("publicationStatus")=="ready"
		and adapter.collision_source_errors.is_empty() and adapter.static_snapshot_revision>failed_revision
		and adapter.cached_static_collision_records.size()==1
		and is_equal_approx(adapter.cached_static_collision_records[0].maxY,2.0),{"status":recovered.get("publicationStatus")})
	collider.shape=null
	var missing: Dictionary=adapter._collect_collision_records(prop,Vector2i.ZERO,"prop",false)
	add_result("finite_bounds_missing_shape_explicit",missing.get("error",{}).get("reason")=="missing_navigation_collision_shape",missing)
	collider.shape=unsupported
	adapter._collision_records_for_body(prop,Vector2i.ZERO,"prop",false)
	adapter._remove_cached_prop_object("prop:retry-prop")
	adapter.fixture_props.clear()
	prop.free()
	adapter.invalidate()
	var after_removal: Dictionary=await wait_for_navigation_capture(adapter,"0,0")
	add_result("finite_bounds_failed_owner_removed_retry",after_removal.get("publicationStatus")=="ready"
		and adapter.collision_source_errors.is_empty() and adapter.cached_static_collision_records.is_empty(),{})
	adapter.main=null
	world.free()
	await process_frame


func wait_for_navigation_capture(adapter, tile_key: String) -> Dictionary:
	var deadline := Time.get_ticks_msec()+5000
	var result: Dictionary = adapter.build_navmesh_tile_snapshot(tile_key)
	while result.get("publicationStatus") == "pending" and Time.get_ticks_msec()<deadline:
		await process_frame
		result = adapter.build_navmesh_tile_snapshot(tile_key)
	return result

func verify_capture_continuation_and_locality() -> void:
	# Synthetic flat-height and collision inventories. Compare the unchanged
	# filter's full ordered inventory with the resumable localized input. This
	# does not prove generated terrain, scene movement or runtime frame pacing.
	var world := SyntheticFiniteBoundsWorld.new()
	world.prop_root = Node3D.new()
	world.add_child(world.prop_root)
	get_root().add_child(world)
	var adapter := SyntheticFiniteBoundsAdapter.new()
	adapter.setup(null,world)
	# The authoritative live block registry is deliberately world-sized. Only
	# two entries belong to tile 0,0, and their insertion order is significant.
	for index in range(1024):
		var far_before := Node.new()
		far_before.name = "FarBefore_%04d" % index
		far_before.set_meta("cell",Vector3i(1000+index,0,1000))
		far_before.set_meta("block_type","torch")
		world.prop_root.add_child(far_before)
		world.blocks["far-before-%04d" % index] = far_before
	var local_block_cell := Vector2i(4,4)
	var local_block_shape := BoxShape3D.new()
	local_block_shape.size = Vector3(1,2,1)
	var local_block := finite_fixture_body(world.prop_root,local_block_shape,"live-block")
	local_block.position = Vector3(local_block_cell.x*1.35,0,local_block_cell.y*1.35)
	local_block.set_meta("cell",Vector3i(local_block_cell.x,0,local_block_cell.y))
	local_block.set_meta("block_type","woodBlock")
	(local_block.get_node("Collider") as CollisionShape3D).position.y = 1.0
	world.blocks["local-block"] = local_block
	var local_door_cell := Vector2i(5,4)
	var local_door_shape := BoxShape3D.new()
	local_door_shape.size = Vector3(1,2,0.3)
	var local_door := finite_fixture_body(world.prop_root,local_door_shape,"live-door")
	local_door.position = Vector3(local_door_cell.x*1.35,0,local_door_cell.y*1.35)
	local_door.set_meta("cell",Vector3i(local_door_cell.x,0,local_door_cell.y))
	local_door.set_meta("block_type","door")
	local_door.set_meta("door_state","closed")
	(local_door.get_node("Collider") as CollisionShape3D).position.y = 1.0
	world.blocks["local-door"] = local_door
	for index in range(1024):
		var far_after := Node.new()
		far_after.name = "FarAfter_%04d" % index
		far_after.set_meta("cell",Vector3i(3000+index,0,1000))
		far_after.set_meta("block_type","torch")
		world.prop_root.add_child(far_after)
		world.blocks["far-after-%04d" % index] = far_after
	adapter.build_snapshot({},true,true)
	# The capture must read current collider facts, not the collision bounds that
	# existed when the static block-key partition was built.
	(local_block.get_node("Collider") as CollisionShape3D).position.x = 0.25
	var records: Array[Dictionary] = []
	for index in range(1024):
		var far_center := Vector3(1000.0+float(index)*2.0,0,1000.0)
		records.append({"id":"far-before-%04d" % index,"cell":Vector2i(100,100),"blockType":"woodBlock",
			"minX":far_center.x-0.4,"maxX":far_center.x+0.4,"minY":0.0,"maxY":2.0,
			"minZ":far_center.z-0.4,"maxZ":far_center.z+0.4,"inflation":0.52})
	for spec: Array in [["local",Vector3(1.35,0,0)], ["duplicate",Vector3(1.35,20,0)]]:
		var center: Vector3 = spec[1]
		records.append({"id":String(spec[0]),"cell":Vector2i(100,100),"blockType":"woodBlock",
			"minX":center.x-0.4,"maxX":center.x+0.4,"minY":center.y,"maxY":center.y+2.0,
			"minZ":center.z-0.4,"maxZ":center.z+0.4,"inflation":0.52})
	# One record spans the complete tile and appears in hundreds of index buckets;
	# it must remain one occurrence at its original inventory position.
	records.append({"id":"spanning","cell":Vector2i(100,100),"blockType":"woodBlock",
		"minX":-4.0,"maxX":25.0,"minY":40.0,"maxY":42.0,
		"minZ":-4.0,"maxZ":25.0,"inflation":0.52})
	for index in range(1024):
		var far_center := Vector3(1000.0+float(index)*2.0,0,1100.0)
		records.append({"id":"far-after-%04d" % index,"cell":Vector2i(100,100),"blockType":"woodBlock",
			"minX":far_center.x-0.4,"maxX":far_center.x+0.4,"minY":0.0,"maxY":2.0,
			"minZ":far_center.z-0.4,"maxZ":far_center.z+0.4,"inflation":0.52})
	for spec: Array in [["duplicate",Vector3(2.7,0,0)], ["edge",Vector3(21.8,0,0)]]:
		var center: Vector3 = spec[1]
		records.append({"id":String(spec[0]),"cell":Vector2i(100,100),"blockType":"woodBlock",
			"minX":center.x-0.4,"maxX":center.x+0.4,"minY":center.y,"maxY":center.y+2.0,
			"minZ":center.z-0.4,"maxZ":center.z+0.4,"inflation":0.52})
	adapter.cached_static_collision_records = records
	adapter._rebuild_navigation_capture_static_collision_order()
	adapter.cached_static_collision_by_cell = adapter._collision_index_for_records(records)
	var full: Dictionary = adapter._navmesh_filter_live_snapshot("0,0")
	adapter.height_cache.clear()
	adapter.terrain_projection_cache.clear()
	adapter.fixture_collision_reads.clear()
	var primed: Dictionary = prime_entry_proof_capture(adapter)
	add_result("resumable_capture_parity_starts_with_existing_pending_cursor",primed.status=="pending",primed)
	var result: Dictionary = await wait_for_navigation_capture(adapter,"0,0")
	var captured: Dictionary = result.get("publicationInput",{})
	var capture_profile: Dictionary = adapter._navigation_capture.profile.duplicate(true) if adapter._navigation_capture != null else {}
	if captured.get("status") != "prepared":
		add_result("resumable_capture_locality_admitted",false,result)
		adapter.release_navigation_capture_cache()
		adapter.main = null
		world.free()
		return
	var reference_input: Dictionary = captured.filterInput.duplicate(false)
	reference_input.staticCollision = full.staticCollision
	var reference: Dictionary = NavigationPublicationSourceScript.new().capture_filter_input(result,reference_input)
	var kernel := FilterKernel.new()
	var actual: Dictionary = kernel.compile(captured.filterInput,captured.snapshot,Callable())
	var expected: Dictionary = kernel.compile(reference.filterInput,reference.snapshot,Callable())
	add_result("resumable_capture_preserves_exact_filter_output_and_duplicate_order",
		actual.get("ready",false) and expected.get("ready",false)
		and var_to_bytes(actual.snapshot)==var_to_bytes(expected.snapshot)
		and captured.filterInput.staticCollision.size()==6
		and full.staticCollision.size()==2054, {})
	var captured_order: Array[String] = []
	var capture_has_internal_order := false
	for record: Dictionary in captured.filterInput.staticCollision:
		captured_order.append(String(record.get("id", "")))
		capture_has_internal_order = capture_has_internal_order or record.has(adapter.NAVIGATION_CAPTURE_ORDER_KEY)
	add_result("capture_spatial_collision_index_excludes_unrelated_inventory_and_preserves_spanning_duplicate_order",
		capture_profile.get("collisionInventoryCount")==2053
		and capture_profile.get("collisionCandidateCount")==5
		and capture_profile.get("collisionCandidateVisits")==5
		and capture_profile.get("collisionOverlayVisits")==1
		and captured_order.slice(0,5)==["local","duplicate","spanning","duplicate","edge"]
		and not capture_has_internal_order,
		{"profile":capture_profile,"capturedOrder":captured_order})
	var block_fact: Dictionary = captured.filterInput.staticCollision.back()
	add_result("capture_spatial_block_index_bounds_visits_preserves_order_and_reads_live_colliders",
		capture_profile.get("blockInventoryCount")==2050
		and capture_profile.get("blockCandidateCount")==2
		and capture_profile.get("blockCandidateVisits")==2
		and capture_profile.get("blockColliderReads")==2
		and adapter.fixture_collision_reads==["FiniteBounds_live-block","FiniteBounds_live-door"]
		and result.get("publicationDoorOwners",{}).has(local_door_cell)
		and String(block_fact.get("blockType",""))=="woodBlock"
		and is_equal_approx(float(block_fact.get("maxX",0.0)),local_block.position.x+0.75),
		{"profile":capture_profile,"collisionReads":adapter.fixture_collision_reads,
			"blockFact":block_fact,"doorOwnerRetained":result.get("publicationDoorOwners",{}).has(local_door_cell)})
	add_result("capture_height_cache_stays_private",adapter.height_cache.is_empty()
		and adapter.terrain_projection_cache.is_empty(),
		{"heightCacheKeys":adapter.height_cache.keys(),"projectionCacheKeys":adapter.terrain_projection_cache.keys()})
	var locality_source: String = adapter.navmesh_tile_source_key_for_tile("0,0")
	var locality_cursor := CaptureCursor.new()
	locality_cursor.begin(adapter,"0,0",locality_source,world.seed_text,[])
	var locality_first: Dictionary = locality_cursor.advance(adapter,1,locality_source)
	var first_steps: int = int(locality_cursor.profile.steps)
	var captured_global_revision: int = locality_cursor._static_revision
	adapter._mark_incremental_static_change("9,9")
	var after_unrelated_source: String = adapter.navmesh_tile_source_key_for_tile("0,0")
	while locality_cursor.advanced_this_process_frame(): await process_frame
	var locality_second: Dictionary = locality_cursor.advance(adapter,1,after_unrelated_source)
	add_result("capture_unrelated_tile_revision_preserves_same_cursor_and_progress",
		locality_first.status=="pending" and locality_second.status=="pending"
		and captured_global_revision!=adapter.static_snapshot_revision
		and after_unrelated_source==locality_source
		and locality_cursor.current_from_entry_source(adapter,after_unrelated_source)
		and int(locality_cursor.profile.steps)>first_steps,
		{"capturedGlobalRevision":captured_global_revision,"currentGlobalRevision":adapter.static_snapshot_revision,
			"sourceBefore":locality_source,"sourceAfter":after_unrelated_source,
			"stepsBefore":first_steps,"stepsAfter":locality_cursor.profile.steps})
	adapter._mark_incremental_static_change("0,0")
	add_result("capture_own_tile_revision_still_rejects_retained_cursor",
		not locality_cursor.current_from_entry_source(adapter,locality_source)
		and adapter.navmesh_tile_source_key_for_tile("0,0")!=locality_source,{})
	locality_cursor.detach_live_records()
	locality_cursor = null
	var cursor := CaptureCursor.new()
	cursor.begin(adapter,"0,0",adapter.navmesh_tile_source_key_for_tile("0,0"),world.seed_text,[])
	cursor.advance(adapter,1)
	world.seed_text += "-replacement"
	var stale: Dictionary = cursor.advance(adapter,4000)
	add_result("capture_rejects_replaced_world_before_publication",stale.status=="stale"
		and stale.reason=="navigation_source_changed_during_capture",{})
	cursor.detach_live_records()
	cursor = CaptureCursor.new()
	cursor.begin(adapter,"0,0",adapter.navmesh_tile_source_key_for_tile("0,0"),world.seed_text,[])
	world.world_generation_system = SyntheticCaptureGeneration.new()
	add_result("capture_rejects_generator_absence_to_presence",not cursor.current(adapter),{})
	cursor.detach_live_records()
	cursor = CaptureCursor.new()
	cursor.begin(adapter,"0,0",adapter.navmesh_tile_source_key_for_tile("0,0"),world.seed_text,[])
	world.world_generation_system.terrain_volume_service = SyntheticCaptureVolume.new()
	add_result("capture_rejects_volume_absence_to_presence",not cursor.current(adapter),{})
	cursor.detach_live_records()
	cursor = null
	adapter.release_navigation_capture_cache()
	adapter.main = null
	world.free()
	await process_frame

func entry_proof_capture_identity(adapter) -> int:
	# Confine the borrowed cursor to this synchronous frame.
	var cursor = adapter._navigation_capture
	return cursor.get_instance_id() if cursor != null else 0

func prime_entry_proof_capture(adapter) -> Dictionary:
	# Real begin/advance establishes an already-visited pending cursor. A tiny
	# budget does not replace any phase, source record or process-frame identity.
	var cursor := CaptureCursor.new()
	cursor.begin(adapter,"0,0",adapter.navmesh_tile_source_key_for_tile("0,0"),adapter.main.seed_text,[])
	var progress: Dictionary = cursor.advance(adapter,1)
	adapter._navigation_capture = cursor
	return {"status":progress.status,"cursorId":cursor.get_instance_id(),"steps":cursor.profile.steps}

func entry_proof_revision_facts(adapter) -> Array:
	# Physical-proof availability is intentionally absent from these cheap epochs.
	return [adapter.static_snapshot_revision,adapter.semantic_revision,adapter.door_state_revision,
		adapter.navmesh_tile_revision_by_key.get("0,0"),adapter.navmesh_tile_semantic_revision_by_key.get("0,0"),
		adapter.navmesh_tile_door_revision_by_key.get("0,0"),adapter.navmesh_tile_load_revision_by_key.get("0,0")]

func close_entry_proof_fixture(adapter, world: Node3D, label: String, service = null) -> void:
	if service == null: service = NavmeshWorldServiceScript.new()
	# Use the existing retirement owner even for the no-service capture case.
	adapter.bind_navigation_publication_service(service)
	adapter.release_navigation_capture_cache()
	service.request_publication_shutdown()
	var shutdown: Dictionary = await wait_for_service_publication(service,true)
	add_result(label+"_owned_retirement_drained",shutdown.get("shutdownComplete",false),shutdown)
	adapter.main = null
	world.free()
	await process_frame

func verify_capture_synchronous_entry_proof() -> void:
	# Synthetic callback/ownership contract. Existing full-inventory filter
	# equality above independently protects geometry and ordered duplicate facts.
	var world := SyntheticFiniteBoundsWorld.new()
	world.prop_root = Node3D.new()
	world.add_child(world.prop_root)
	world.structure_system = SyntheticEntryProofStructures.new()
	get_root().add_child(world)
	var adapter := SyntheticEntryProofAdapter.new()
	adapter.setup(null,world)
	adapter.build_snapshot({},true,true)
	var primed: Dictionary = prime_entry_proof_capture(adapter)
	add_result("entry_proof_fixture_has_existing_pending_cursor",primed.status=="pending" and primed.steps==1,primed)
	if primed.status!="pending":
		await close_entry_proof_fixture(adapter,world,"entry_proof_failed_setup")
		return
	adapter.source_reads = 0
	var scheduling_tile: String = adapter.active_navigation_capture_tile()
	add_result("entry_proof_active_capture_scheduling_uses_retained_identity_without_physical_source_read",
		scheduling_tile=="0,0" and adapter.source_reads==0 and entry_proof_capture_identity(adapter)==primed.cursorId,
		{"tileKey":scheduling_tile,"reads":adapter.source_reads})
	var frame: int = Engine.get_process_frames()
	adapter.source_reads = 0
	var first: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	var first_reads: int = adapter.source_reads
	adapter.source_reads = 0
	var second: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	var second_reads: int = adapter.source_reads
	add_result("entry_proof_same_frame_calls_defer_before_physical_source_read",first.get("publicationStatus")=="pending"
		and second==first and first.get("reason")=="navigation_capture_frame_budget_used"
		and first_reads==0 and second_reads==0 and Engine.get_process_frames()==frame
		and entry_proof_capture_identity(adapter)==primed.cursorId,
		{"firstReads":first_reads,"secondReads":second_reads,"sameFrame":Engine.get_process_frames()==frame})
	var epochs: Array = entry_proof_revision_facts(adapter)
	world.structure_system.proof_pending = true
	adapter.source_reads = 0
	var deferred_changed: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	while Engine.get_process_frames()==frame: await process_frame
	adapter.source_reads = 0
	var changed: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	var changed_retained: bool = changed.get("publicationStatus")=="pending" and changed.get("reason")=="navigation_capture_pending" \
		or changed.get("publicationStatus")=="ready" and changed.get("publicationInput",{}).get("status")=="prepared"
	add_result("entry_proof_next_frame_reuses_retained_identity_before_acceptance",deferred_changed.get("reason")=="navigation_capture_frame_budget_used"
		and changed_retained and adapter.source_reads==0 and epochs==entry_proof_revision_facts(adapter),
		{"reads":adapter.source_reads,"reason":changed.get("reason")})
	world.structure_system.proof_pending = false
	var deadline: int = Time.get_ticks_msec()+5000
	var capture: Dictionary = {}
	var reads_exact := true
	var calls := 0
	while Time.get_ticks_msec()<deadline:
		await process_frame
		adapter.source_reads = 0
		capture = adapter.build_navmesh_tile_snapshot("0,0")
		calls += 1
		reads_exact = reads_exact and adapter.source_reads==0
		if capture.get("publicationStatus")!="pending": break
	var prepared: bool = capture.get("publicationInput",{}).get("status")=="prepared"
	add_result("entry_proof_continuing_slice_uses_revision_identity_until_seal",prepared and reads_exact and calls>0,
		{"calls":calls,"finalReads":adapter.source_reads,"status":capture.get("publicationStatus")})
	if prepared:
		var compiled: Dictionary = FilterKernel.new().compile(capture.publicationInput.filterInput,capture.publicationInput.snapshot,Callable())
		add_result("entry_proof_completed_capture_preserves_flat_terrain_output",compiled.get("ready",false)
			and compiled.snapshot.surfaces.size()==256 and capture.publicationInput.filterInput.terrainCells.size()==256
		and adapter.height_cache.is_empty() and adapter.terrain_projection_cache.is_empty(),{})
		compiled = {}
	capture = {}; first = {}; second = {}; changed = {}
	await close_entry_proof_fixture(adapter,world,"entry_proof_reuse")
	await verify_entry_proof_service_reads()
	for boundary: String in ["slice","seal"]:
		await verify_entry_proof_callback_mutation(boundary)

func verify_entry_proof_service_reads() -> void:
	var world := SyntheticFiniteBoundsWorld.new()
	world.prop_root = Node3D.new()
	world.add_child(world.prop_root)
	world.structure_system = SyntheticEntryProofStructures.new()
	get_root().add_child(world)
	var adapter := SyntheticEntryProofAdapter.new()
	adapter.setup(null,world)
	adapter.build_snapshot({},true,true)
	var primed: Dictionary = prime_entry_proof_capture(adapter)
	var service := NavmeshWorldServiceScript.new()
	# The real service validates the owner and returns absent without creating
	# a map or receipt. Its callback is part of the production capture entry.
	adapter.bind_navigation_publication_service(service)
	var frame: int = Engine.get_process_frames()
	adapter.source_reads = 0
	var first: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	var first_reads: int = adapter.source_reads
	adapter.source_reads = 0
	var second: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	var second_reads: int = adapter.source_reads
	add_result("entry_proof_real_service_same_frame_calls_defer_without_source_reads",primed.status=="pending"
		and first.get("publicationStatus")=="pending" and second==first
		and first.get("reason")=="navigation_capture_frame_budget_used" and first_reads==0 and second_reads==0
		and Engine.get_process_frames()==frame and entry_proof_capture_identity(adapter)==primed.cursorId,
		{"firstReads":first_reads,"secondReads":second_reads})
	var deadline: int = Time.get_ticks_msec()+5000
	var capture: Dictionary = {}
	var reads_exact := true
	var calls := 0
	while Time.get_ticks_msec()<deadline:
		await process_frame
		adapter.source_reads = 0
		capture = adapter.build_navmesh_tile_snapshot("0,0")
		calls += 1
		reads_exact = reads_exact and adapter.source_reads==0
		if capture.get("publicationStatus")!="pending": break
	add_result("entry_proof_real_service_absent_lookup_does_not_repeat_preflight",reads_exact and calls>0
		and capture.get("publicationInput",{}).get("status")=="prepared"
		and service._accepted_tile_sources.is_empty() and service.region_rids_by_region.is_empty()
		and service.active_publication_request().tileKey=="",
		{"calls":calls,"finalReads":adapter.source_reads,"status":capture.get("publicationStatus")})
	adapter.source_reads=0
	var admission: Dictionary = service.register_tile_snapshot(capture)
	add_result("entry_proof_real_service_revalidates_physical_source_at_acceptance",
		admission.get("status")=="pending" and adapter.source_reads==1,
		{"reads":adapter.source_reads,"status":admission.get("status"),"reason":admission.get("reason")})
	capture = {}; first = {}; second = {}
	await close_entry_proof_fixture(adapter,world,"entry_proof_real_service",service)

func verify_entry_proof_callback_mutation(boundary: String) -> void:
	var world := SyntheticFiniteBoundsWorld.new()
	world.prop_root = Node3D.new()
	world.add_child(world.prop_root)
	world.structure_system = SyntheticEntryProofStructures.new()
	get_root().add_child(world)
	var adapter := SyntheticEntryProofAdapter.new()
	adapter.setup(null,world)
	adapter.build_snapshot({},true,true)
	var primed: Dictionary = prime_entry_proof_capture(adapter)
	var epochs: Array = entry_proof_revision_facts(adapter)
	var service = NavmeshWorldServiceScript.new()
	adapter.bind_navigation_publication_service(service)
	adapter.fail_proof_at = boundary
	var deadline: int = Time.get_ticks_msec()+5000
	var result: Dictionary = {}
	var mutations := 0
	while Time.get_ticks_msec()<deadline and mutations==0:
		await process_frame
		result = adapter.build_navmesh_tile_snapshot("0,0")
		mutations = adapter.mutation_count
		if result.get("publicationStatus")!="pending": break
	while result.get("publicationStatus")=="pending" and Time.get_ticks_msec()<deadline:
		await process_frame
		result=adapter.build_navmesh_tile_snapshot("0,0")
	adapter.source_reads=0
	var admission: Dictionary = service.register_tile_snapshot(result) if result.get("publicationStatus")=="ready" else {}
	add_result("entry_proof_"+boundary+"_callback_defers_physical_loss_to_acceptance",primed.status=="pending" and mutations==1
		and result.get("publicationInput",{}).get("status")=="prepared"
		and admission.get("status")=="pending" and admission.get("reason")=="navigation_source_owner_changed"
		and adapter.source_reads==1 and service._accepted_tile_sources.is_empty()
		and epochs==entry_proof_revision_facts(adapter),
		{"mutations":mutations,"reads":adapter.source_reads,"capture":result.get("publicationStatus"),
			"admission":admission.get("status"),"reason":admission.get("reason")})
	add_result("entry_proof_"+boundary+"_rejected_acceptance_keeps_retryable_capture",
		entry_proof_capture_identity(adapter)==primed.cursorId and not adapter.navmesh_tile_snapshot_cache.is_empty(),{})
	result = {}
	await close_entry_proof_fixture(adapter,world,"entry_proof_"+boundary,service)

func verify_retained_priority_promotion() -> void:
	# Synthetic scheduling contract, not evidence of live movement.
	var adapter := RoutePublicationAdapter.new()
	adapter._enqueue_navmesh_tile_publish("0,0", "promotion:1", false,
		{"actorId":"ordinary-worker", "activeJobRoute":true, "routePriority":180})
	adapter._enqueue_navmesh_tile_publish("1,0", "background:1", false)
	adapter.deferred_navmesh_tile_keys["0,0"] = true
	var original: Dictionary = adapter.queued_navmesh_tile_contexts["0,0"].duplicate(true)
	var promoted := adapter.promote_queued_navmesh_tile_priority("0,0", "promotion:1")
	add_result("retained_priority_promotes_without_replacing_route_context", promoted
		and adapter.queued_navmesh_tile_priority_keys.has("0,0")
		and adapter.queued_navmesh_tile_contexts["0,0"] == original
		and adapter.queued_navmesh_tile_keys.front() == "0,0"
		and not adapter.deferred_navmesh_tile_keys.has("0,0"), {})
	adapter.deferred_navmesh_tile_keys["0,0"] = true
	adapter._resort_navmesh_tile_queue()
	var order := adapter.queued_navmesh_tile_keys.duplicate()
	adapter.promote_queued_navmesh_tile_priority("0,0", "promotion:1")
	add_result("repeated_priority_visit_preserves_retry_round_and_age",
		adapter.deferred_navmesh_tile_keys.has("0,0")
		and adapter.queued_navmesh_tile_keys == order
		and adapter.queued_navmesh_tile_contexts["0,0"] == original, {})
	var ready_retry := adapter.retry_ready_queued_navmesh_tile_priority("0,0", "promotion:1")
	add_result("ready_regional_priority_reenters_current_retry_round_without_replacing_context",
		ready_retry and not adapter.deferred_navmesh_tile_keys.has("0,0")
		and adapter.queued_navmesh_tile_keys.front() == "0,0"
		and adapter.queued_navmesh_tile_contexts["0,0"] == original, {})
	adapter.set_queued_navmesh_tile_regional_priority("0,0","promotion:1",1)
	adapter._enqueue_navmesh_tile_publish("3,0","regional-zero:1",true)
	var zero_context: Dictionary = adapter.queued_navmesh_tile_contexts["3,0"].duplicate(true)
	var zero_ranked := adapter.set_queued_navmesh_tile_regional_priority("3,0","regional-zero:1",0)
	add_result("regional_zero_ranks_ahead_of_older_priority_one_without_losing_queue_identity",
		zero_ranked and adapter.queued_navmesh_tile_keys.front()=="3,0"
		and int(adapter.queued_navmesh_tile_contexts["3,0"].regionalPriority)==0
		and int(adapter.queued_navmesh_tile_contexts["3,0"].queueSequence)==int(zero_context.queueSequence)
		and adapter.queued_navmesh_tile_source_keys["0,0"]=="promotion:1", {})
	add_result("priority_promotion_rejects_stale_or_absent_source",
		not adapter.promote_queued_navmesh_tile_priority("1,0", "stale")
		and not adapter.promote_queued_navmesh_tile_priority("2,0", "absent")
		and not adapter.retry_ready_queued_navmesh_tile_priority("1,0", "background:1")
		and not adapter.queued_navmesh_tile_priority_keys.has("1,0")
		and not adapter.queued_navmesh_tile_source_keys.has("2,0"), {})

func verify_active_capture_foreground_arbitration() -> void:
	# Synthetic capture scheduling with the real queue/service. This does not
	# prove capture geometry, worker throughput, or live actor movement.
	# Finish the preceding fixture's queued map removal before the baseline.
	await physics_frame
	await process_frame
	await physics_frame
	var baseline_maps := navigation_map_ids()
	var owner := SyntheticPendingCaptureOwner.new()
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	var publisher := RoutePublicationAdapter.new()
	publisher.world = owner
	publisher.main = owner.main
	publisher.navmesh_world = service
	for index in range(8):
		publisher._enqueue_navmesh_tile_publish("%d,0" % index,owner.source_key,true,
			{"reason":"external_queue","marker":index})
	var sources := publisher.queued_navmesh_tile_source_keys.duplicate()
	var contexts := publisher.queued_navmesh_tile_contexts.duplicate(true)
	var priorities := publisher.queued_navmesh_tile_priority_keys.duplicate()
	var processed := publisher._process_queued_navmesh_tile_publishes(6,0,true)
	add_result("foreground_ineligible_active_capture_is_visited_once",processed==0
		and owner.active_capture_queries==1 and owner.capture_calls.is_empty(),
		{"captureQueries":owner.active_capture_queries,"captureCalls":owner.capture_calls.duplicate()})
	add_result("foreground_ineligible_capture_preserves_all_retained_demand",
		publisher.queued_navmesh_tile_keys.size()==8
		and publisher.queued_navmesh_tile_source_keys==sources
		and publisher.queued_navmesh_tile_contexts==contexts
		and publisher.queued_navmesh_tile_priority_keys==priorities
		and publisher.deferred_navmesh_tile_keys.is_empty(),{})
	processed = publisher._process_queued_navmesh_tile_publishes(1,0,false)
	add_result("ordinary_visit_resumes_owned_capture_once_without_losing_context",processed==0
		and owner.active_capture_queries==2 and owner.capture_calls==["0,0"]
		and publisher.queued_navmesh_tile_keys.size()==8
		and publisher.queued_navmesh_tile_source_keys==sources
		and publisher.queued_navmesh_tile_contexts==contexts
		and publisher.queued_navmesh_tile_priority_keys==priorities
		and publisher.deferred_navmesh_tile_keys.has("0,0")
		and service.active_publication_request().tileKey=="",{})
	publisher.invalidate()
	add_result("queue_invalidation_releases_owned_capture_with_cancelled_demand",
		owner.capture_releases==1 and owner.active_tile.is_empty()
		and publisher.queued_navmesh_tile_keys.is_empty()
		and publisher.queued_navmesh_tile_source_keys.is_empty()
		and publisher.queued_navmesh_tile_contexts.is_empty()
		and publisher.queued_navmesh_tile_priority_keys.is_empty()
		and publisher.deferred_navmesh_tile_keys.is_empty(),{})
	service.request_publication_shutdown()
	var shutdown := await wait_for_service_publication(service,true)
	await physics_frame
	var final_maps := navigation_map_ids()
	add_result("active_capture_arbitration_fixture_releases_owned_resources",
		shutdown.shutdownComplete and final_maps==baseline_maps,
		{"baselineMaps":baseline_maps,"finalMaps":final_maps,"shutdown":shutdown})

func verify_idle_publication_does_not_consume_capture_deadline() -> void:
	# Reproduce the production frame order: a foreground route owns retained
	# capture demand while the compiler/upload queue is idle. Its maintenance
	# method is deliberately more expensive than the 750-usec frame allowance.
	# Queue scheduling must inspect its cheap identity and give the capture the
	# slice instead of repeatedly spending the entire deadline on idle polling.
	var owner := SyntheticFrameBudgetCaptureOwner.new()
	owner.frame_budget_used = true
	var service := ExpensiveIdlePublicationService.new()
	var publisher := RoutePublicationAdapter.new()
	publisher.world = owner
	publisher.main = owner.main
	publisher.navmesh_world = service
	publisher._enqueue_navmesh_tile_publish("0,0",owner.source_key,true,
		{"activeJobRoute":true,"actorId":"worker:home:deadline","simulationLod":"active","routePriority":180})
	publisher.begin_frame()
	add_result("idle_publication_maintenance_cannot_starve_retained_capture",service.idle_advance_calls==0
		and owner.capture_calls==["0,0","0,0"] and publisher.queued_navmesh_tile_keys==["0,0"]
		and publisher.last_navmesh_tile_queue_debug.size()==2
		and publisher.last_navmesh_tile_queue_debug[0].get("reason")=="navigation_capture_frame_budget_used"
		and publisher.last_navmesh_tile_queue_debug[1].get("reason")=="navigation_capture_frame_budget_used",
		{"idleAdvanceCalls":service.idle_advance_calls,"captureCalls":owner.capture_calls,
		"queue":publisher.queued_navmesh_tile_keys,"debug":publisher.last_navmesh_tile_queue_debug})

func verify_unqueued_capture_continuation_precedes_foreground() -> void:
	# A direct caller may own a valid cursor before it has placed that tile in the
	# shared queue. Reproduce the runtime failure with a competing foreground home
	# route: begin_frame must adopt and advance the owner, retain the competitor,
	# and never ask the blocked tile to displace the cursor.
	var owner := SyntheticPendingCaptureOwner.new()
	var service := NavmeshWorldServiceScript.new()
	service.setup()
	var publisher := RoutePublicationAdapter.new()
	publisher.world = owner
	publisher.main = owner.main
	publisher.navmesh_world = service
	var foreground_context := {"activeJobRoute":true,"actorId":"worker:home:foreground",
		"simulationLod":"active","routePriority":180}
	publisher._enqueue_navmesh_tile_publish("1,0",owner.source_key,true,foreground_context)
	var foreground_identity: Dictionary = publisher.queued_navmesh_tile_contexts["1,0"]
	publisher.begin_frame()
	add_result("unqueued_capture_owner_is_retained_and_advanced_before_competing_foreground",owner.capture_calls==["0,0"]
		and publisher.queued_navmesh_tile_keys.has("0,0") and publisher.queued_navmesh_tile_keys.has("1,0")
		and publisher.queued_navmesh_tile_source_keys.get("0,0")==owner.source_key
		and publisher.deferred_navmesh_tile_keys.has("0,0")
		and is_same(foreground_identity,publisher.queued_navmesh_tile_contexts["1,0"]),
		{"captureCalls":owner.capture_calls,"queued":publisher.queued_navmesh_tile_keys,
		"sources":publisher.queued_navmesh_tile_source_keys,"debug":publisher.last_navmesh_tile_queue_debug})
	publisher.invalidate()
	service.request_publication_shutdown()
	var shutdown := await wait_for_service_publication(service,true)
	add_result("unqueued_capture_continuation_cancellation_releases_all_demand",shutdown.shutdownComplete
		and owner.capture_releases==1 and owner.active_tile.is_empty()
		and publisher.queued_navmesh_tile_keys.is_empty(),shutdown)

func verify_large_frontier_foreground_arbitration() -> void:
	# Production may retain a wide streaming frontier while one foreground actor
	# needs the capture slot. Selection must leave unrelated request contexts
	# untouched and visit only the eligible request in this turn.
	var owner := SyntheticPendingCaptureOwner.new()
	owner.active_tile = ""
	var service := NavmeshWorldServiceScript.new()
	service.setup()
	var publisher := RoutePublicationAdapter.new()
	publisher.world = owner
	publisher.main = owner.main
	publisher.navmesh_world = service
	for index in range(256):
		publisher._enqueue_navmesh_tile_publish("%d,0" % index,owner.source_key,true,
			{"reason":"external_queue","marker":index})
	var untouched_context: Dictionary = publisher.queued_navmesh_tile_contexts["0,0"]
	var foreground_key := "256,0"
	publisher._enqueue_navmesh_tile_publish(foreground_key,owner.source_key,true,
		{"activeJobRoute":true,"actorId":"worker:home:1","simulationLod":"active","routePriority":180})
	var begun := Time.get_ticks_usec()
	var processed := publisher._process_queued_navmesh_tile_publishes(1,750,true)
	var elapsed := Time.get_ticks_usec()-begun
	add_result("large_frontier_foreground_selection_visits_only_eligible_request",processed==0
		and owner.capture_calls==[foreground_key] and publisher.queued_navmesh_tile_keys.size()==257
		and is_same(untouched_context,publisher.queued_navmesh_tile_contexts["0,0"]),
		{"elapsedUsec":elapsed,"captureCalls":owner.capture_calls.duplicate(),
			"retainedCount":publisher.queued_navmesh_tile_keys.size()})
	publisher.invalidate()
	service.request_publication_shutdown()
	await wait_for_service_publication(service,true)

func verify_pending_source_retention() -> void:
	# Synthetic producer, real frozen source, worker, queue, server and sync.
	# Eventual acknowledgement replaces the old same-call marker assumption.
	var producer := PendingSourceFixture.new()
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	var adapter := RoutePublicationAdapter.new()
	adapter.world = producer
	adapter.main = producer.main
	adapter.navmesh_world = service
	for key: String in ["0,0","1,0"]:
		adapter._enqueue_navmesh_tile_publish(key,producer.navmesh_tile_source_key_for_tile(key),true)
	adapter._process_queued_navmesh_tile_publishes(2)
	add_result("pending_source_retains_demand_without_empty_cache",adapter.queued_navmesh_tile_keys.has("0,0") and not adapter.empty_navmesh_tile_keys.has("0,0") and not adapter.published_navmesh_tile_keys.has("0,0"),{})
	var acknowledged: bool = await drive_publisher_acknowledgement(adapter,"1,0")
	add_result("pending_source_does_not_starve_ready_tile",acknowledged and service.accepted_tile_state("1,0",producer.source_key,producer.main.seed_text,producer).status=="acknowledged"
		and adapter.queued_navmesh_tile_keys.has("0,0"),{})
	var rejected: Dictionary = service.register_tile_snapshot(producer.build_navmesh_tile_snapshot("0,0"))
	add_result("pending_source_cannot_create_empty_installation",rejected.status=="pending" and not service.descriptors_by_region.has("region:chunk:0,0"),{})
	producer.ready = true
	acknowledged = await drive_publisher_acknowledgement(adapter,"0,0")
	var receipt: Dictionary = service.tile_publication_readiness("0,0",producer.navmesh_tile_source_key_for_tile("0,0"))
	add_result("pending_source_retry_installs_when_owner_ready",acknowledged and not adapter.queued_navmesh_tile_keys.has("0,0") and receipt.status=="ready",{"status":receipt.status,"reason":receipt.reason})
	service.request_publication_shutdown()
	var drained: Dictionary = await wait_for_service_publication(service,true)
	add_result("pending_source_prepared_service_drains_before_replacement",drained.get("shutdownComplete",false),drained)
	var rejecting_service := RejectingInstallFixture.new()
	rejecting_service.setup()
	adapter.navmesh_world = rejecting_service
	adapter._enqueue_navmesh_tile_publish("2,0",producer.navmesh_tile_source_key_for_tile("2,0"),true)
	await process_frame
	var processed: int = adapter._process_queued_navmesh_tile_publishes(2)
	add_result("rejected_install_retains_demand_without_success_cache",processed==0 and adapter.queued_navmesh_tile_keys.has("2,0") and not adapter.empty_navmesh_tile_keys.has("2,0") and not adapter.published_navmesh_tile_keys.has("2,0"),{"processed":processed,"queued":adapter.queued_navmesh_tile_keys.has("2,0"),"published":adapter.published_navmesh_tile_keys.has("2,0")})
	rejecting_service.reject_install = false
	acknowledged = await drive_publisher_acknowledgement(adapter,"2,0")
	receipt = rejecting_service.tile_publication_readiness("2,0",producer.navmesh_tile_source_key_for_tile("2,0"))
	add_result("rejected_install_retries_through_real_service",acknowledged and receipt.status=="ready" and not adapter.queued_navmesh_tile_keys.has("2,0"),{"status":receipt.status,"reason":receipt.reason})
	rejecting_service.request_publication_shutdown()
	drained = await wait_for_service_publication(rejecting_service,true)
	add_result("rejected_install_prepared_service_drains_all_work",drained.get("shutdownComplete",false),drained)
	adapter.navmesh_world = null
	adapter.world = null
	adapter.main = null

func navigation_worker_fixture() -> Dictionary:
	# Bounded synthetic input, deliberately not a generated-world or movement
	# fixture. The separated parts exercise owner, height, hole and grade rules.
	var snapshot := {"tileKey":"worker-contract", "sourceRevision":7, "semanticRevision":2,
		"surfaces":[{"cell":Vector3i.ZERO,"spanIndex":0},{"cell":Vector3i(1,0,0),"spanIndex":0},
			{"cell":Vector3i(4,0,0),"spanIndex":0,"blocked":true}],
		"buildingSurfaces":[], "semanticRegions":[{"id":"worker-room","kind":"interior","position":Vector3(10.5,0,0.5)}],
		"doorPortals":[{"id":"worker-door","entrance":Vector3(-0.4,0,0),"exit":Vector3(0.4,0,0)}],
		"doorLinks":[{"id":"worker-door-link","portalId":"worker-door","from":"terrain-a","to":"terrain-b"}],
		"crossingLinks":[{"id":"worker-crossing","ownerTileKey":"worker-contract","kind":"stair_ramp",
			"start":Vector3(18.5,0,0),"end":Vector3(18.5,1,1)}]}
	for spec in [[10,0,0,"room"],[11,0,0,"room"],[10,1,0,"room"],[10,0,3,"upper"],[14,0,0,"separate"]]:
		var x: float = spec[0]; var z: float = spec[1]; var y: float = spec[2]
		snapshot.buildingSurfaces.append({"id":"worker-part-%d" % snapshot.buildingSurfaces.size(),
			"supportId":spec[3],"walkable":true,
			"polygon":[Vector3(x,y,z),Vector3(x,y,z+1),Vector3(x+1,y,z+1),Vector3(x+1,y,z)]})
	for x: float in [18.0,19.0]:
		snapshot.buildingSurfaces.append({"id":"worker-grade-%d" % int(x),"supportId":"grade","walkable":true,
			"polygon":[Vector3(x,0,0),Vector3(x,1,1),Vector3(x+1,1,1),Vector3(x+1,0,0)]})
	return snapshot

func freeze_worker_fixture(value) -> void:
	# Fixture setup only: never pass scene owners or mutable source aliases to
	# the real worker. Do not use the production freezer to validate itself.
	if value is Dictionary:
		for key in value: freeze_worker_fixture(value[key])
		value.make_read_only()
	elif value is Array:
		for item in value: freeze_worker_fixture(item)
		value.make_read_only()

func wait_for_navigation_worker(worker, shutting_down := false) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 5000
	var state: Dictionary = worker.poll()
	while Time.get_ticks_msec() < deadline:
		if state.get("shutdownComplete",false) if shutting_down else not String(state.get("completedStatus","")).is_empty():
			return state
		await process_frame
		state = worker.poll()
	return state

func verify_navigation_worker_parity_and_ownership() -> void:
	# Actual worker and NavigationServer installation; synthetic source only.
	# No physics-backed crossing, live gameplay or performance claim follows.
	# Finish preceding fixtures' queued map removals before taking our baseline.
	await physics_frame
	await process_frame
	await physics_frame
	var baseline_maps := navigation_map_ids()
	var main_thread := OS.get_thread_caller_id()
	var snapshot := navigation_worker_fixture()
	var descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(snapshot)
	var expected_signature: String = descriptor.stable_signature()
	var service = NavmeshWorldServiceScript.new()
	var expected_owners := {}
	var expected_mesh = service._build_navigation_mesh(descriptor,expected_owners)
	var expected_vertices: PackedVector3Array = expected_mesh.get_vertices()
	var expected_polygons: Array[PackedInt32Array] = []
	for index in expected_mesh.get_polygon_count(): expected_polygons.append(expected_mesh.get_polygon(index))
	var source := {"status":"prepared","snapshot":snapshot,"profile":{"evidenceLevel":"synthetic_contract"}}
	freeze_worker_fixture(source)
	var source_bytes := var_to_bytes(source)
	var worker := NavigationPublicationWorkerScript.new()
	var binding := {"siteId":"worker-contract","sourceKey":"worker-source:7","generation":7}
	var wrong_binding := binding.duplicate()
	wrong_binding.generation = 8
	var invalid: Dictionary = worker.dispatch(source.duplicate(),binding)
	add_result("navigation_worker_rejects_mutable_envelope",invalid.status=="failed",invalid)
	var dispatched: Dictionary = worker.dispatch(source,binding)
	var token := int(dispatched.get("token",0))
	add_result("navigation_worker_dispatch_is_deferred",dispatched.status=="queued" and worker.take_result(token,binding).status=="pending" and worker._thread==null,{"status":dispatched.status})
	var duplicate: Dictionary = worker.dispatch(source,binding)
	add_result("navigation_worker_duplicate_binding_reuses_token",duplicate.get("duplicate",false) and duplicate.token==token,duplicate)
	add_result("navigation_worker_retains_other_demand_as_busy",worker.dispatch(source,wrong_binding).status=="busy",{})
	var state := await wait_for_navigation_worker(worker)
	add_result("navigation_worker_finishes_bounded_preparation",state.completedStatus=="ready",state)
	add_result("navigation_worker_wrong_binding_cannot_consume",worker.take_result(token,wrong_binding).status=="stale_token" and worker.take_result(token+1,binding).status=="stale_token",{})
	var taken: Dictionary = worker.take_result(token,binding)
	var result: Dictionary = taken.get("result",{})
	var holder = result.get("prepared")
	if holder == null:
		add_result("navigation_worker_produces_prepared_holder",false,{"status":taken.get("status"),"reason":result.get("reason")})
		worker.request_shutdown()
		state = await wait_for_navigation_worker(worker,true)
		add_result("navigation_worker_failed_preparation_drains",state.shutdownComplete,state)
		return
	add_result("navigation_worker_result_is_one_shot",taken.status=="consumed" and worker.take_result(token,binding).status=="stale_token",{})
	add_result("navigation_holder_rejects_wrong_binding",holder.take(wrong_binding).is_empty(),{})
	var payload: Dictionary = holder.take(binding)
	var prepared = payload.get("descriptor")
	add_result("navigation_holder_exact_binding_is_one_shot",prepared!=null and holder.take(binding).is_empty()
		and is_same(payload.get("acceptedSource"),source),{})
	if prepared == null:
		worker.retire_external_payload({"workerResult":result,"payload":payload})
		taken={}; result={}; holder=null; payload={}
		worker.request_shutdown()
		state = await wait_for_navigation_worker(worker,true)
		add_result("navigation_worker_failed_holder_drains",state.shutdownComplete,state)
		return
	var geometry: Dictionary = prepared.prepared_geometry()
	add_result("navigation_worker_compiles_and_releases_input_off_main",int(geometry.get("threadId",-1))>0 and int(geometry.get("threadId",-1))!=main_thread and int(state.lastInputReleaseThreadId)>0 and int(state.lastInputReleaseThreadId)!=main_thread,{"mainThread":main_thread,"compileThread":geometry.get("threadId"),"inputReleaseThread":state.lastInputReleaseThreadId})
	add_result("navigation_worker_canonical_signature_parity",prepared.preparation_valid() and prepared.stable_signature()==expected_signature,{"expectedHash":expected_signature.sha256_text(),"actualHash":prepared.stable_signature().sha256_text()})
	add_result("navigation_worker_geometry_and_ownership_parity",geometry.get("vertices")==expected_vertices and geometry.get("polygons")==expected_polygons and geometry.get("surfacePolygons")==expected_owners,{"surfaceCount":expected_owners.size(),"polygonCount":expected_polygons.size()})
	add_result("navigation_worker_fixture_keeps_all_source_parts",expected_owners.size()==9 and expected_polygons.size()==6 and prepared.blockers.size()==1 and prepared.semantic_anchors.size()==1,{})
	add_result("navigation_worker_source_unchanged_and_output_sealed",source_bytes==var_to_bytes(source) and prepared.walkable_surfaces.is_read_only() and prepared.walkable_surfaces[0].is_read_only() and geometry.is_read_only() and geometry.surfacePolygons.is_read_only() and geometry.polygons.is_read_only(),{})
	service.setup(NavigationBackendConfigScript.default_config())
	var installed: Dictionary = service.register_chunk_descriptor(prepared,binding.sourceKey)
	var pending: Dictionary = service.tile_publication_readiness(prepared.tile_key,binding.sourceKey)
	add_result("navigation_worker_install_waits_for_real_ack",installed.get("installed",false) and pending.status=="pending" and pending.reason=="installation_sync_pending",{"installStatus":installed.get("status"),"reason":pending.reason})
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var receipt: Dictionary = service.tile_publication_readiness(prepared.tile_key,binding.sourceKey,expected_owners.keys(),["worker-door-link","worker-crossing"])
	add_result("navigation_worker_actual_revision_and_ownership_receipt",receipt.status=="ready" and receipt.sourceRevision==7 and receipt.signature==expected_signature and receipt.completeSurfaceCoverage,{"status":receipt.status,"reason":receipt.reason,"sourceRevision":receipt.get("sourceRevision"),"missingSurfaces":receipt.get("missingSurfaceIds"),"missingLinks":receipt.get("missingLinkIds")})
	var region: String = prepared.region_id
	var installed_rid: RID = service.region_rids_by_region.get(region,RID())
	var metadata_only: Dictionary = service.register_tile_snapshot({"tileKey":prepared.tile_key,"centerCell":Vector3i.ZERO,"sourceKey":"demand-only"})
	var retained: Dictionary = service.tile_publication_readiness(prepared.tile_key,binding.sourceKey)
	add_result("navigation_metadata_demand_cannot_replace_real_region",metadata_only.get("status")=="rejected" and metadata_only.get("reason")=="missing_tile_surface_source" and service.region_rids_by_region.get(region,RID())==installed_rid and retained.status=="ready" and retained.installationSerial==receipt.installationSerial,{"status":metadata_only.get("status"),"reason":metadata_only.get("reason"),"retainedStatus":retained.status})
	prepared.revision = 8
	var rejected: Dictionary = service.register_chunk_descriptor(prepared,"changed-source")
	add_result("navigation_worker_mutated_header_cannot_replace_install",not prepared.preparation_valid() and prepared.stable_signature().is_empty() and rejected.get("reason")=="prepared_navigation_source_changed" and service.region_rids_by_region.get(region,RID())==installed_rid and service._tile_publication_receipts[region].sourceKey==binding.sourceKey,{"status":rejected.get("status"),"reason":rejected.get("reason")})
	prepared.revision = 7
	var prepared_weak: WeakRef = weakref(prepared)
	service.clear()
	await physics_frame
	add_result("navigation_worker_service_clear_releases_all_rids",navigation_map_ids()==baseline_maps and service.descriptors_by_region.is_empty() and service._tile_publication_receipts.is_empty(),{"baselineMaps":baseline_maps,"finalMaps":navigation_map_ids(),"descriptors":service.descriptors_by_region.size(),"receipts":service._tile_publication_receipts.size()})
	# clear() now transfers its prepared-descriptor reference to the service's
	# retirement worker. Drain that owner before testing our final external alias.
	service.request_publication_shutdown()
	var service_shutdown := await wait_for_service_publication(service,true)
	add_result("navigation_worker_service_owned_retirement_drained",service_shutdown.get("shutdownComplete",false),service_shutdown)
	var retirement := {"descriptor":prepared,"workerResult":result,"payload":payload}
	var accepted := worker.retire_external_payload(retirement)
	add_result("navigation_worker_accepts_detached_descriptor_retirement",accepted,{})
	# Relinquish every strong prepared-output alias before retirement starts.
	prepared=null; geometry={}; retirement={}; holder=null; result={}; taken={}; payload={}
	descriptor=null; expected_mesh=null; source={}; snapshot={}
	worker.request_shutdown()
	state = await wait_for_navigation_worker(worker,true)
	add_result("navigation_worker_shutdown_joins_and_retires_off_main",accepted and state.shutdownComplete and not state.busy and not state.workerRunning and not state.retirementPending and int(state.lastRetirementThreadId)>0 and int(state.lastRetirementThreadId)!=main_thread and prepared_weak.get_ref()==null,state)

func filter_input_navigation_snapshot(owner, revision := 1, empty := false) -> Dictionary:
	# Synthetic values only; production admission, filtering and publication run
	# unchanged. One statically blocked cell proves that input is not output.
	var snapshot := {"publicationStatus":"ready","tileKey":"0,0","regionId":"region:chunk:0,0",
		"worldSeed":owner.main.seed_text,"sourceKey":owner.source_key,"sourceRevision":revision,"semanticRevision":0}
	var input := {"waterLevel":0.0,"terrainCells":[],"staticCollision":[],
		"buildingTiles":[],"doorPortals":[],"doorLinks":[],"diagnostics":{}}
	for z in 16:
		for x in 16:
			input.terrainCells.append({"cell":Vector2i(x,z),"height":-1.0 if empty else 1.35,
				"door":{},"staticBlocked":x==1 and z==0,"staticEvidence":{},
				"propBlocked":false,"propEvidence":{},"path":false})
	snapshot["publicationInput"] = NavigationPublicationSourceScript.new().capture_filter_input(snapshot,input)
	snapshot["publicationOwner"] = weakref(owner)
	return snapshot

func verify_filter_input_lifecycle() -> void:
	# Synthetic source/lifecycle evidence only. Reuse the real worker, queue,
	# server and existing bounded waits; this does not prove live movement.
	var owner = SyntheticPublicationOwner.new()
	var snapshot := filter_input_navigation_snapshot(owner)
	var source: Dictionary = snapshot.publicationInput
	var input_bytes := var_to_bytes(source)
	add_result("filter_input_identity_and_nested_immutability",source.get("status")=="prepared"
		and source.is_read_only() and source.snapshot.is_read_only() and source.filterInput.is_read_only()
		and source.filterInput.terrainCells.is_read_only() and source.filterInput.terrainCells[1].is_read_only()
		and source.filterInput.terrainCells[1].staticEvidence.is_read_only()
		and source.snapshot.sourceKey==owner.source_key and source.snapshot.worldSeed==owner.main.seed_text
		and source.profile.captureMode=="filter_input" and not snapshot.has("surfaces"),{})
	var mismatched := snapshot.duplicate(false)
	mismatched.sourceKey = "wrong-outer-source"
	var service := NavmeshWorldServiceScript.new()
	service.setup()
	var rejected: Dictionary = service.register_tile_snapshot(mismatched)
	add_result("filter_input_outer_identity_cannot_override_capture",rejected.get("status")=="failed"
		and rejected.get("reason")=="navigation_capture_identity_mismatch"
		and service.active_publication_request().tileKey=="",rejected)
	var requested: Dictionary = service.register_tile_snapshot(snapshot)
	var held := await wait_for_service_prepared_without_upload(service,snapshot)
	var prepared_weak: WeakRef = weakref(service._publication_queue._descriptor) if service._publication_queue._descriptor!=null else null
	var original_owner: WeakRef = weakref(owner)
	owner = null
	await process_frame
	service.advance_publication(0)
	add_result("filter_input_lost_owner_cancels_before_acceptance",requested.get("status")=="pending"
		and held.get("reason")=="navigation_upload_pending" and original_owner.get_ref()==null
		and service._publication_queue.stats().binding.is_empty() and service._accepted_tile_sources.is_empty()
		and service.region_rids_by_region.is_empty(),{"heldReason":held.get("reason")})
	owner = SyntheticPublicationOwner.new()
	var replacement := filter_input_navigation_snapshot(owner,101)
	var install := await drive_async_navigation_install(service,replacement)
	var receipt := await async_navigation_receipt(service,replacement)
	var accepted: Dictionary = service.accepted_tile_source("0,0",owner.source_key,owner.main.seed_text,owner)
	var accepted_snapshot: Dictionary = accepted.get("source",{}).get("snapshot",{})
	add_result("filter_input_fresh_owner_accepts_exact_worker_facts",install.installed and receipt.get("status")=="ready"
		and accepted_snapshot.get("sourceRevision")==101 and accepted_snapshot.get("surfaces",[]).size()==255
		and not accepted_snapshot.get("surfaces",[]).any(func(row: Dictionary):return row.cell.x==1 and row.cell.z==0)
		and is_same(accepted.get("source"),replacement.get("publicationSource"))
		and accepted.is_read_only() and accepted_snapshot.is_read_only()
		and prepared_weak!=null and prepared_weak.get_ref()==null,install)
	var recaptured := filter_input_navigation_snapshot(owner,102)
	var cached: Dictionary = service.register_tile_snapshot(recaptured)
	add_result("filter_input_local_identity_reuses_accepted_installation",cached.get("cached",false)
		and cached.get("installed",false) and recaptured.get("sourceRevision")==101
		and recaptured.get("publicationAcceptedSerial")==accepted.get("serial")
		and is_same(recaptured.get("publicationSource"),accepted.get("source"))
		and source.filterInput.terrainCells.size()==256 and not source.snapshot.has("surfaces")
		and var_to_bytes(source)==input_bytes,{})
	var old_key: String = owner.source_key
	owner.source_key = "filter-empty-source:2"
	add_result("filter_input_stale_source_cannot_supply_accepted_facts",
		service.accepted_tile_source("0,0",old_key,owner.main.seed_text,owner).is_empty(),{})
	var empty_request := filter_input_navigation_snapshot(owner,2,true)
	requested = service.register_tile_snapshot(empty_request)
	var empty_pending: bool = requested.get("status")=="pending" and not empty_request.has("surfaces")
	install = await drive_async_navigation_install(service,empty_request)
	var empty_accepted: Dictionary = service.accepted_tile_source("0,0",owner.source_key,owner.main.seed_text,owner)
	add_result("filter_input_empty_requires_worker_acceptance",empty_pending and install.status=="empty"
		and empty_accepted.get("empty",false) and empty_request.has("publicationAcceptedSerial")
		and empty_request.get("surfaces",["missing"]).is_empty()
		and empty_request.get("buildingSurfaces",["missing"]).is_empty()
		and not service.region_rids_by_region.has("region:chunk:0,0"),install)
	# Relinquish borrowed facts before shutdown retires accepted output.
	accepted={}; accepted_snapshot={}; empty_accepted={}; replacement={}; recaptured={}; empty_request={}
	service.request_publication_shutdown()
	var shutdown := await wait_for_service_publication(service,true)
	add_result("filter_input_shutdown_drains_accepted_and_cancelled_payloads",shutdown.get("shutdownComplete",false)
		and service._accepted_tile_sources.is_empty() and service.descriptors_by_region.is_empty(),shutdown)
	# A queued filter capture must retire even if filtering never starts.
	var worker := NavigationPublicationWorkerScript.new()
	var binding := {"siteId":"0,0","sourceKey":source.snapshot.sourceKey,"generation":1}
	var dispatched: Dictionary = worker.dispatch(source,binding)
	var token := int(dispatched.get("token",0))
	var cancelled: bool = worker.cancel(token)
	add_result("filter_input_queued_cancel_invalidates_token",dispatched.status=="queued" and cancelled
		and worker.take_result(token,binding).status=="stale_token" and worker._thread==null,{})
	source={}; snapshot={}; mismatched={}
	worker.request_shutdown()
	var state := await wait_for_navigation_worker(worker,true)
	add_result("filter_input_queued_cancel_retires_off_main",state.get("shutdownComplete",false)
		and int(state.get("lastRetirementThreadId",-1))>0
		and int(state.get("lastRetirementThreadId",-1))!=OS.get_thread_caller_id(),state)

func accepted_state_facts(state: Dictionary) -> Dictionary:
	# Do not put borrowed source graphs into reports or retain them over a yield.
	return {"status":state.get("status"),"reason":state.get("reason"),"sourceOwned":state.get("sourceOwned",false),
		"empty":state.get("empty",false),"acceptedSerial":state.get("acceptedSerial",0),
		"installationSerial":state.get("installationSerial",-1),"receipt":state.get("receipt",{}).duplicate()}

func wait_for_acknowledged_state(service, owner, tile_key: String) -> Dictionary:
	var deadline: int = Time.get_ticks_msec()+5000
	var facts: Dictionary = {}
	while Time.get_ticks_msec()<deadline:
		var state: Dictionary = service.accepted_tile_state(tile_key,owner.source_key,owner.main.seed_text,owner)
		facts = accepted_state_facts(state)
		state = {}
		if facts.status in ["acknowledged","invalid"]: return facts
		await process_frame
	return facts

func drive_publisher_acknowledgement(publisher, tile_key: String) -> bool:
	var deadline: int = Time.get_ticks_msec()+5000
	while Time.get_ticks_msec()<deadline:
		await process_frame
		publisher.begin_frame()
		var state: Dictionary = publisher.navmesh_world.accepted_tile_state(tile_key,
			publisher.world.navmesh_tile_source_key_for_tile(tile_key),publisher.main.seed_text,publisher.world)
		var ready: bool = state.status=="acknowledged" and not publisher.queued_navmesh_tile_keys.has(tile_key)
		state = {}
		if ready: return true
	return false

func verify_accepted_tile_state_contract() -> void:
	# Synthetic source with real compiler, installation and server mutation.
	# This is an ownership/synchronization contract, never route acceptance.
	await physics_frame
	var baseline_maps: Array[String] = navigation_map_ids()
	var service := NavmeshWorldServiceScript.new()
	service.setup()
	var completion_events: Array = []
	service.accepted_tile_changed.connect(func(tile: String, source: String, seed: String, owner_id: int, serial: int, present: bool):
		completion_events.append({"tile":tile,"source":source,"seed":seed,"ownerId":owner_id,"serial":serial,"present":present}))
	var owner := SyntheticPublicationOwner.new()
	var snapshot: Dictionary = filter_input_navigation_snapshot(owner)
	var absent: Dictionary = service.accepted_tile_state("0,0",owner.source_key,owner.main.seed_text,owner)
	add_result("accepted_state_missing_source_is_absent_without_work",absent.status=="absent" and not absent.sourceOwned
		and service.active_publication_request().tileKey=="" and not service.publication_sync_pending(),accepted_state_facts(absent))
	var install: Dictionary = await drive_async_navigation_install(service,snapshot)
	add_result("accepted_state_fixture_owns_real_prepared_installation",install.installed,install)
	if not install.installed:
		snapshot = {}
		service.request_publication_shutdown()
		await wait_for_service_publication(service,true)
		return
	var state: Dictionary = service.accepted_tile_state("0,0",owner.source_key,owner.main.seed_text,owner)
	var accepted_serial: int = int(state.acceptedSerial)
	var scheduling: Dictionary = service.accepted_tile_scheduling_hint("0,0",owner.main.seed_text,owner)
	add_result("accepted_installation_emits_one_value_only_completion_before_sync",
		completion_events.size()==1 and completion_events[0].present and completion_events[0].serial==accepted_serial
		and scheduling.get("serial")==accepted_serial and scheduling.get("sourceKey")==owner.source_key,completion_events.duplicate())
	var installation_serial: int = int(state.installationSerial)
	var prepared_count: int = service._publication_queue.prepared_count
	var dirty_serial: int = service.navigation_map_dirty_serial
	var synced_serial: int = service.navigation_map_synced_serial
	add_result("accepted_state_owned_before_sync_is_retained_not_acknowledged",state.status=="retained"
		and state.reason=="installation_sync_pending" and state.sourceOwned and state.receipt.status=="pending"
		and service.publication_sync_pending(),accepted_state_facts(state))
	add_result("accepted_source_wrapper_keeps_same_borrowed_source_before_sync",
		is_same(service.accepted_tile_source("0,0",owner.source_key,owner.main.seed_text,owner),state.accepted),{})
	var cached: Dictionary = service.register_tile_snapshot(snapshot.duplicate(false))
	var repeated: Dictionary = service.accepted_tile_state("0,0",owner.source_key,owner.main.seed_text,owner)
	add_result("cached_installation_does_not_repeat_completion_event",completion_events.size()==1,completion_events.duplicate())
	add_result("accepted_state_reads_and_cached_reuse_do_not_sync_or_reprepare",cached.get("cached",false)
		and repeated.acceptedSerial==accepted_serial and repeated.installationSerial==installation_serial
		and service._publication_queue.prepared_count==prepared_count
		and service.navigation_map_dirty_serial==dirty_serial and service.navigation_map_synced_serial==synced_serial
		and service.active_publication_request().tileKey=="",accepted_state_facts(repeated))
	state = {}; repeated = {}; cached = {}
	service.sync_navigation_map_if_dirty()
	var acknowledged: Dictionary = await wait_for_acknowledged_state(service,owner,"0,0")
	add_result("accepted_state_acknowledges_same_source_after_explicit_sync",acknowledged.status=="acknowledged"
		and acknowledged.acceptedSerial==accepted_serial and acknowledged.installationSerial==installation_serial
		and acknowledged.receipt.status=="ready" and not service.publication_sync_pending(),acknowledged)
	var region: String = "region:chunk:0,0"
	var region_rid: RID = service.region_rids_by_region[region]
	NavigationServer3D.region_set_enabled(region_rid,false)
	service._mark_navigation_map_dirty(); service.sync_navigation_map_if_dirty()
	await physics_frame
	state = service.accepted_tile_state("0,0",owner.source_key,owner.main.seed_text,owner)
	add_result("accepted_state_disabled_region_retains_source_without_ready",state.status=="retained"
		and state.sourceOwned and state.reason=="installed_region_disabled" and state.acceptedSerial==accepted_serial,accepted_state_facts(state))
	state = {}
	NavigationServer3D.region_set_enabled(region_rid,true)
	service._mark_navigation_map_dirty(); service.sync_navigation_map_if_dirty()
	await physics_frame
	NavigationServer3D.map_set_active(service.navigation_map,false)
	service._mark_navigation_map_dirty(); service.sync_navigation_map_if_dirty()
	await physics_frame
	state = service.accepted_tile_state("0,0",owner.source_key,owner.main.seed_text,owner)
	add_result("accepted_state_inactive_map_retains_source_without_ready",state.status=="retained"
		and state.sourceOwned and state.reason=="navigation_map_inactive",accepted_state_facts(state))
	state = {}
	NavigationServer3D.map_set_active(service.navigation_map,true)
	service._mark_navigation_map_dirty(); service.sync_navigation_map_if_dirty()
	await physics_frame
	var other_owner := SyntheticPublicationOwner.new()
	state = service.accepted_tile_state("0,0",owner.source_key,owner.main.seed_text,other_owner)
	add_result("accepted_state_wrong_owner_cannot_borrow_installation",state.status=="absent" and not state.sourceOwned
		and state.accepted.is_empty(),accepted_state_facts(state))
	state = {}
	var original_seed: String = owner.main.seed_text
	owner.main.seed_text += "-changed"
	state = service.accepted_tile_state("0,0",owner.source_key,original_seed,owner)
	add_result("accepted_state_changed_seed_invalidates_source",state.status=="invalid" and not state.sourceOwned,accepted_state_facts(state))
	owner.main.seed_text = original_seed
	state = {}
	var descriptor = service.descriptors_by_region[region]
	var metadata: Dictionary = descriptor.metadata
	descriptor.metadata = {}
	state = service.accepted_tile_state("0,0",owner.source_key,original_seed,owner)
	add_result("accepted_state_replaced_descriptor_field_invalidates_source",state.status=="invalid" and not state.sourceOwned
		and state.reason=="prepared_navigation_source_changed",accepted_state_facts(state))
	descriptor.metadata = metadata
	descriptor = null; metadata = {}; state = {}
	service.dirty_regions_by_region[region] = {"reason":"synthetic_dirty_source"}
	state = service.accepted_tile_state("0,0",owner.source_key,original_seed,owner)
	add_result("accepted_state_dirty_source_rejects_cached_ownership",state.status=="invalid" and not state.sourceOwned
		and state.reason=="navigation_accepted_source_dirty",accepted_state_facts(state))
	service.dirty_regions_by_region.erase(region); state = {}
	var original_map: RID = service.navigation_map
	service.navigation_map = RID() # Missing local owner; the real map stays alive.
	state = service.accepted_tile_state("0,0",owner.source_key,original_seed,owner)
	add_result("accepted_state_missing_map_rejected_before_rid_queries",state.status=="invalid" and not state.sourceOwned
		and state.reason=="installed_map_lost",accepted_state_facts(state))
	service.navigation_map = original_map; state = {}
	NavigationServer3D.region_set_map(region_rid,RID())
	service._mark_navigation_map_dirty(); service.sync_navigation_map_if_dirty()
	await physics_frame
	state = service.accepted_tile_state("0,0",owner.source_key,original_seed,owner)
	add_result("accepted_state_detached_region_rejects_cached_ownership",state.status=="invalid" and not state.sourceOwned
		and state.reason=="installed_region_lost",accepted_state_facts(state))
	state = {}
	NavigationServer3D.region_set_map(region_rid,original_map)
	service._mark_navigation_map_dirty(); service.sync_navigation_map_if_dirty()
	await physics_frame
	owner.source_key = "accepted-empty-replacement:2"
	snapshot = filter_input_navigation_snapshot(owner,2,true)
	install = await drive_async_navigation_install(service,snapshot,region_rid)
	state = service.accepted_tile_state("0,0",owner.source_key,original_seed,owner)
	var empty_serial: int = int(state.acceptedSerial)
	add_result("empty_replacement_retires_predecessor_and_emits_new_completion",
		completion_events.size()==3 and not completion_events[1].present and completion_events[1].serial==accepted_serial
		and completion_events[2].present and completion_events[2].serial==empty_serial,completion_events.duplicate())
	var empty_installation: int = int(state.installationSerial)
	add_result("accepted_empty_replacement_retains_removal_sync_barrier",install.status=="empty" and state.status=="retained"
		and state.empty and state.sourceOwned and state.reason=="installation_sync_pending"
		and empty_installation>installation_serial and service.publication_sync_pending()
		and not service.region_rids_by_region.has(region),accepted_state_facts(state))
	add_result("accepted_empty_keeps_public_nonempty_receipt_pending",service.tile_publication_readiness("0,0",owner.source_key).status!="ready",{})
	state = {}
	service.sync_navigation_map_if_dirty()
	acknowledged = await wait_for_acknowledged_state(service,owner,"0,0")
	add_result("accepted_empty_acknowledges_same_source_after_retirement_sync",acknowledged.status=="acknowledged"
		and acknowledged.empty and acknowledged.acceptedSerial==empty_serial and acknowledged.installationSerial==empty_installation
		and acknowledged.receipt.status=="ready" and service._publication_queue.prepared_count==prepared_count+1
		and service.region_rids_by_region.is_empty(),acknowledged)
	snapshot = {}
	service.request_publication_shutdown()
	var shutdown: Dictionary = await wait_for_service_publication(service,true)
	add_result("accepted_state_shutdown_clears_sources_and_sync_obligations",shutdown.get("shutdownComplete",false)
		and service._accepted_tile_sources.is_empty() and not service.publication_sync_pending(),shutdown)
	add_result("shutdown_retires_exact_completion_and_clears_scheduling_hint",
		completion_events.size()==4 and not completion_events[3].present and completion_events[3].serial==empty_serial
		and service.accepted_tile_scheduling_hint("0,0",owner.main.seed_text,owner).is_empty(),completion_events.duplicate())
	service = NavmeshWorldServiceScript.new()
	service.setup()
	owner = SyntheticPublicationOwner.new()
	snapshot = filter_input_navigation_snapshot(owner,1,true)
	install = await drive_async_navigation_install(service,snapshot)
	acknowledged = await wait_for_acknowledged_state(service,owner,"0,0")
	add_result("first_authoritative_empty_needs_no_fake_region_or_sync_serial",install.status=="empty"
		and acknowledged.status=="acknowledged" and acknowledged.empty and acknowledged.installationSerial==0
		and service.region_rids_by_region.is_empty() and not service.publication_sync_pending()
		and service.tile_publication_readiness("0,0",owner.source_key).status!="ready",acknowledged)
	snapshot = {}
	service.request_publication_shutdown()
	shutdown = await wait_for_service_publication(service,true)
	await physics_frame
	add_result("accepted_state_contract_releases_real_worker_and_maps",shutdown.get("shutdownComplete",false)
		and service._publication_queue.worker._thread==null and navigation_map_ids()==baseline_maps,shutdown)

func verify_accepted_last_tile_scheduler() -> void:
	# A real prepared last tile, with zero other work to accidentally drive sync.
	await physics_frame
	var baseline_maps: Array[String] = navigation_map_ids()
	var owner := SyntheticQueuedPublicationOwner.new()
	var service := NavmeshWorldServiceScript.new()
	service.setup()
	var publisher := RoutePublicationAdapter.new()
	publisher.world = owner; publisher.main = owner.main; publisher.navmesh_world = service
	publisher._enqueue_navmesh_tile_publish("0,0",owner.source_key,true)
	var deadline: int = Time.get_ticks_msec()+5000
	var facts: Dictionary = {}
	while Time.get_ticks_msec()<deadline:
		await process_frame
		publisher._process_queued_navmesh_tile_publishes(1,4000)
		var state: Dictionary = service.accepted_tile_state("0,0",owner.source_key,owner.main.seed_text,owner)
		facts = accepted_state_facts(state)
		state = {}
		if facts.sourceOwned: break
	var prepared_count: int = service._publication_queue.prepared_count
	var uploaded_count: int = service._publication_queue.uploaded_count
	add_result("last_tile_handoff_leaves_sync_obligation_without_queue_or_worker",facts.status=="retained"
		and facts.reason=="installation_sync_pending" and publisher.queued_navmesh_tile_keys.is_empty()
		and service.active_publication_request().tileKey=="" and not publisher.published_navmesh_tile_keys.has("0,0")
		and service.publication_sync_pending(),facts)
	var acknowledged: bool = await drive_publisher_acknowledgement(publisher,"0,0")
	var current: Dictionary = service.accepted_tile_state("0,0",owner.source_key,owner.main.seed_text,owner)
	add_result("last_tile_normal_tick_syncs_and_accepts_without_rebuilding",acknowledged and current.status=="acknowledged"
		and current.acceptedSerial==facts.acceptedSerial and current.installationSerial==facts.installationSerial
		and publisher.queued_navmesh_tile_keys.is_empty() and service._publication_queue.prepared_count==prepared_count
		and service._publication_queue.uploaded_count==uploaded_count and prepared_count==1 and uploaded_count==1
		and not service.publication_sync_pending(),accepted_state_facts(current))
	current = {}
	owner.captured.clear()
	publisher.invalidate()
	service.request_publication_shutdown()
	var shutdown: Dictionary = await wait_for_service_publication(service,true)
	await physics_frame
	add_result("last_tile_acknowledgement_contract_drains_owned_resources",shutdown.get("shutdownComplete",false)
		and service._publication_queue.worker._thread==null and navigation_map_ids()==baseline_maps,shutdown)
	publisher.world = null; publisher.main = null; publisher.navmesh_world = null

func async_navigation_snapshot(owner, revision: int, include_filter_portal := false) -> Dictionary:
	# Synthetic separated source parts force three or more upload segments.
	# The real capture factory, worker, upload queue and service remain unmocked.
	var snapshot := {"tileKey":"async-contract","sourceKey":owner.source_key,
		"worldSeed":owner.main.seed_text,"sourceRevision":revision,"surfaces":[],"buildingSurfaces":[]}
	for index in 257:
		var x := float(index % 17)*2.0
		var z := floorf(float(index)/17.0)*2.0
		var y := float(revision)*0.25
		snapshot.buildingSurfaces.append({"id":"async-part-%d" % index,"supportId":"async-support-%d" % index,
			"walkable":true,"polygon":[Vector3(x,y,z),Vector3(x,y,z+1),Vector3(x+1,y,z+1),Vector3(x+1,y,z)]})
	if include_filter_portal:
		var height := float(revision)*0.25
		snapshot["doorPortals"] = [{"id":"async-filter-door","entrance":Vector3(0.5,height,0.5),"exit":Vector3(2.5,height,0.5)}]
		snapshot["doorLinks"] = [{"id":"async-filter-link","portalId":"async-filter-door","from":"async-part-0","to":"async-part-1"}]
	snapshot["publicationSource"] = NavigationPublicationSourceScript.new().capture(snapshot)
	snapshot["publicationOwner"] = weakref(owner)
	return snapshot

func recapture_async_navigation_snapshot(snapshot: Dictionary, global_revision: int) -> Dictionary:
	# Synthetic cache eviction/recapture: change only the global observation
	# counter, preserving the complete local source identity and all geometry.
	# async_navigation_snapshot(revision) also changes heights, so cannot model it.
	var recaptured: Dictionary = snapshot.publicationSource.snapshot.duplicate(true)
	recaptured.sourceRevision = global_revision
	recaptured["publicationSource"] = NavigationPublicationSourceScript.new().capture(recaptured)
	recaptured["publicationOwner"] = snapshot.publicationOwner
	return recaptured

func wait_for_service_publication(service, shutdown := false) -> Dictionary:
	var deadline := Time.get_ticks_msec()+5000
	var state: Dictionary = {}
	while Time.get_ticks_msec()<deadline:
		await process_frame
		state = service.advance_publication()
		var worker_state: Dictionary = state.get("worker",{})
		if shutdown:
			if state.get("shutdownComplete",false): return state
		elif not state.get("busy",true):
			return state
	return state

func wait_for_service_prepared_without_upload(service, snapshot: Dictionary) -> Dictionary:
	# A zero upload budget holds a real completed packet at a deterministic
	# cancellation point. This is scheduling/ownership evidence, not performance.
	var deadline := Time.get_ticks_msec()+5000
	var state: Dictionary = {}
	while Time.get_ticks_msec()<deadline:
		await process_frame
		state = service.advance_publication(0)
		if state.get("reason")=="navigation_upload_pending" or state.get("status")=="failed": return state
		# A previous installed packet may still be retiring. Retain and retry
		# demand exactly as a real caller must when the one owned slot is busy.
		service.register_tile_snapshot(snapshot)
	return state

func drive_async_navigation_install(service, snapshot: Dictionary, prior_rid := RID()) -> Dictionary:
	var deadline := Time.get_ticks_msec()+5000
	var result := {"installed":false}
	var previous_upload := 0
	var partial_frames := 0
	var max_segment := 0
	var repeated_frame_stable := true
	var previous_region_preserved := true
	var region := NavigationBakeDescriptorScript.chunk_region_id(String(snapshot.tileKey))
	while Time.get_ticks_msec()<deadline:
		await process_frame
		var state: Dictionary = service.advance_publication()
		var upload := int(state.get("uploadPolygon",0))
		max_segment = maxi(max_segment,upload-previous_upload)
		previous_upload = upload
		if upload>0 and upload<257: partial_frames += 1
		var repeated: Dictionary = service.advance_publication()
		repeated_frame_stable = repeated_frame_stable and repeated.get("uploadPolygon")==state.get("uploadPolygon") and repeated.get("preparedCount")==state.get("preparedCount")
		if prior_rid.is_valid(): previous_region_preserved = previous_region_preserved and service.region_rids_by_region.get(region,RID())==prior_rid
		result = service.register_tile_snapshot(snapshot)
		if result.get("installed",false) or result.get("status") in ["empty","failed","rejected"]: break
	return {"installed":result.get("installed",false),"status":result.get("status","timeout"),"reason":result.get("reason",""),
		"partialFrames":partial_frames,"maxSegment":max_segment,"repeatedFrameStable":repeated_frame_stable,"previousRegionPreserved":previous_region_preserved}

func async_navigation_receipt(service, snapshot: Dictionary) -> Dictionary:
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	return service.tile_publication_readiness(String(snapshot.tileKey),String(snapshot.sourceKey))

func verify_async_navigation_service_lifecycle() -> void:
	# Synthetic lifecycle contract only; no generated-world, NPC traversal or
	# frame-pacing acceptance. Every installed region uses the real server.
	await physics_frame
	await process_frame
	var baseline_maps := navigation_map_ids()
	var owner = SyntheticPublicationOwner.new()
	var snapshot := async_navigation_snapshot(owner,1)
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	var service_id: int = service.get_instance_id()
	var region := NavigationBakeDescriptorScript.chunk_region_id(String(snapshot.tileKey))
	var requested: Dictionary = service.register_tile_snapshot(snapshot)
	add_result("async_navigation_request_uses_frozen_source_and_defers_install",snapshot.publicationSource.status=="prepared" and snapshot.publicationSource.is_read_only() and requested.get("status")=="pending" and not requested.get("installed",false) and not service.region_rids_by_region.has(region),{"status":requested.get("status"),"reason":requested.get("reason")})
	var recapture_held := await wait_for_service_prepared_without_upload(service,snapshot)
	var original_binding: Dictionary = recapture_held.get("binding",{}).duplicate()
	var original_epoch: int = service._publication_queue.worker._epoch
	var original_prepared: WeakRef = weakref(service._publication_queue._descriptor) if service._publication_queue._descriptor!=null else null
	var recaptured := recapture_async_navigation_snapshot(snapshot,101)
	add_result("async_navigation_global_recapture_preserves_local_source_and_geometry",recaptured.publicationSource.status=="prepared" and recaptured.sourceRevision!=snapshot.sourceRevision and recaptured.sourceKey==snapshot.sourceKey and recaptured.worldSeed==snapshot.worldSeed and recaptured.buildingSurfaces==snapshot.buildingSurfaces and recaptured.surfaces==snapshot.surfaces,{"originalRevision":snapshot.sourceRevision,"recapturedRevision":recaptured.sourceRevision})
	requested = service.register_tile_snapshot(recaptured)
	var after_recapture: Dictionary = service._publication_queue.stats()
	add_result("async_navigation_global_recapture_preserves_pre_upload_packet",recapture_held.get("reason")=="navigation_upload_pending" and requested.get("status")=="pending" and after_recapture.binding==original_binding and service._publication_queue.worker._epoch==original_epoch and original_prepared!=null and original_prepared.get_ref()!=null and original_prepared.get_ref()==service._publication_queue._descriptor and after_recapture.uploadPolygon==0 and after_recapture.preparedCount==1 and after_recapture.retiredBatchCount==0,{"status":requested.get("status"),"binding":after_recapture.binding,"epoch":service._publication_queue.worker._epoch,"preparedCount":after_recapture.preparedCount})
	snapshot = recaptured
	var install := await drive_async_navigation_install(service,snapshot)
	add_result("async_navigation_upload_is_segmented_once_per_frame",install.installed and install.partialFrames>=2 and install.maxSegment<=128 and install.repeatedFrameStable,install)
	add_result("async_navigation_global_recapture_installs_original_preparation_once",install.installed and service._publication_queue.stats().preparedCount==1 and service._publication_queue.stats().uploadedCount==1 and service._publication_queue.worker._epoch==original_epoch and original_prepared!=null and original_prepared.get_ref()==service.descriptors_by_region.get(region) and service._publication_bindings.get(region,{})==original_binding,{"installed":install.installed,"preparedCount":service._publication_queue.stats().preparedCount,"uploadedCount":service._publication_queue.stats().uploadedCount})
	var first := await async_navigation_receipt(service,snapshot)
	var installed_descriptor = service.descriptors_by_region.get(region)
	var compile_thread := int(installed_descriptor.prepared_geometry().get("threadId",-1)) if installed_descriptor!=null else -1
	add_result("async_navigation_worker_install_has_revision_matched_ack",first.get("status")=="ready" and first.get("sourceRevision")==1 and first.get("completeSurfaceCoverage",false) and compile_thread>0 and compile_thread!=OS.get_thread_caller_id(),{"status":first.get("status"),"reason":first.get("reason"),"compileThread":compile_thread})
	installed_descriptor = null
	var old_rid: RID = service.region_rids_by_region.get(region,RID())
	recaptured = recapture_async_navigation_snapshot(snapshot,102)
	requested = service.register_tile_snapshot(recaptured)
	var recaptured_receipt := await async_navigation_receipt(service,recaptured)
	add_result("async_navigation_installed_global_recapture_reuses_exact_installation",requested.get("installed",false) and requested.get("cached",false) and recaptured_receipt.get("status")=="ready" and recaptured_receipt.get("sourceRevision")==1 and recaptured_receipt.get("installationSerial")==first.get("installationSerial") and service.region_rids_by_region.get(region,RID())==old_rid and original_prepared!=null and original_prepared.get_ref()==service.descriptors_by_region.get(region) and service._publication_bindings.get(region,{})==original_binding and service._publication_queue.stats().preparedCount==1 and service._publication_queue.stats().uploadedCount==1 and service._publication_queue.worker._epoch==original_epoch,{"cached":requested.get("cached",false),"status":recaptured_receipt.get("status"),"installationSerial":recaptured_receipt.get("installationSerial")})
	owner.source_key = "async-contract-source:2"
	snapshot = async_navigation_snapshot(owner,2)
	requested = service.register_tile_snapshot(snapshot)
	add_result("async_navigation_replacement_retains_old_region_while_pending",requested.get("status")=="pending" and old_rid.is_valid() and service.region_rids_by_region.get(region,RID())==old_rid,{"status":requested.get("status")})
	install = await drive_async_navigation_install(service,snapshot,old_rid)
	var replacement := await async_navigation_receipt(service,snapshot)
	add_result("async_navigation_replacement_swaps_after_complete_upload",install.installed and install.previousRegionPreserved and replacement.get("status")=="ready" and replacement.get("sourceRevision")==2 and int(replacement.get("installationSerial",0))>int(first.get("installationSerial",0)) and service.region_rids_by_region.get(region,RID())!=old_rid,install)
	old_rid = service.region_rids_by_region.get(region,RID())
	owner.source_key = "async-contract-source:3"
	snapshot = async_navigation_snapshot(owner,3)
	service.register_tile_snapshot(snapshot)
	var held := await wait_for_service_prepared_without_upload(service,snapshot)
	add_result("async_navigation_cancellation_fixture_holds_real_prepared_packet",held.get("reason")=="navigation_upload_pending" and held.get("uploadPolygon")==0,held)
	snapshot = recapture_async_navigation_snapshot(snapshot,103)
	requested = service.register_tile_snapshot(snapshot)
	add_result("async_navigation_recaptured_local_source_remains_pending_before_change",requested.get("status")=="pending" and service._publication_queue.stats().binding==held.get("binding",{}),{"status":requested.get("status")})
	owner.source_key = "async-contract-source:4"
	var same_frame_stale: Dictionary = service.advance_publication(0)
	add_result("async_navigation_same_frame_advance_rejects_changed_owner_source",same_frame_stale.binding.is_empty()
		and service.region_rids_by_region.get(region,RID())==old_rid,{})
	var idle := await wait_for_service_publication(service)
	requested = service.register_tile_snapshot(snapshot)
	add_result("async_navigation_stale_source_cancelled_without_old_region_loss",idle.get("binding",{}).is_empty() and not idle.get("worker",{}).get("busy",true) and requested.get("reason")=="navigation_source_owner_changed" and service.region_rids_by_region.get(region,RID())==old_rid and service.tile_publication_readiness(String(snapshot.tileKey),String(snapshot.sourceKey)).get("status")!="ready",{"status":requested.get("status"),"reason":requested.get("reason")})
	snapshot = async_navigation_snapshot(owner,4)
	service.register_tile_snapshot(snapshot)
	install = await drive_async_navigation_install(service,snapshot,old_rid)
	var current := await async_navigation_receipt(service,snapshot)
	add_result("async_navigation_retry_after_stale_source_installs_current_revision",install.installed and current.get("status")=="ready" and current.get("sourceRevision")==4,install)
	old_rid = service.region_rids_by_region.get(region,RID())
	owner.source_key = "async-contract-source:5"
	snapshot = async_navigation_snapshot(owner,5)
	service.register_tile_snapshot(snapshot)
	held = await wait_for_service_prepared_without_upload(service,snapshot)
	var owner_weak: WeakRef = weakref(owner)
	owner = null
	idle = await wait_for_service_publication(service)
	add_result("async_navigation_lost_weak_owner_cancels_prepared_packet",held.get("reason")=="navigation_upload_pending" and owner_weak.get_ref()==null and idle.get("binding",{}).is_empty() and not idle.get("worker",{}).get("busy",true) and service.region_rids_by_region.get(region,RID())==old_rid and service.tile_publication_readiness(String(snapshot.tileKey),String(snapshot.sourceKey)).get("status")!="ready",{"binding":idle.get("binding"),"workerBusy":idle.get("worker",{}).get("busy")})
	owner = SyntheticPublicationOwner.new()
	owner.main.seed_text = "async-contract-seed-b"
	owner.source_key = "async-contract-source:4"
	snapshot = async_navigation_snapshot(owner,4)
	requested = service.register_tile_snapshot(snapshot)
	add_result("async_navigation_equal_revision_other_seed_not_cached",requested.get("status")=="pending" and not requested.get("cached",false),{"status":requested.get("status")})
	install = await drive_async_navigation_install(service,snapshot,old_rid)
	var other_seed := await async_navigation_receipt(service,snapshot)
	add_result("async_navigation_other_seed_requires_fresh_installation",install.installed and other_seed.get("status")=="ready" and int(other_seed.get("installationSerial",0))>int(current.get("installationSerial",0)) and service.region_rids_by_region.get(region,RID())!=old_rid and String(service._publication_bindings.get(region,{}).get("sourceKey","")).begins_with(owner.main.seed_text+"|"),{"installed":install.installed,"previousSerial":current.get("installationSerial"),"currentSerial":other_seed.get("installationSerial")})
	owner.source_key = "async-contract-source:6"
	snapshot = async_navigation_snapshot(owner,6)
	service.register_tile_snapshot(snapshot)
	held = await wait_for_service_prepared_without_upload(service,snapshot)
	service.begin_publication_reset()
	add_result("async_navigation_reset_cannot_finish_before_retirement",not service.finish_publication_reset() and service.register_tile_snapshot(snapshot).get("status")=="pending" and service.region_rids_by_region.is_empty(),{})
	idle = await wait_for_service_publication(service)
	var reset_finished: bool = service.finish_publication_reset()
	service.setup()
	owner.source_key = "async-contract-source:7"
	snapshot = async_navigation_snapshot(owner,7)
	service.register_tile_snapshot(snapshot)
	install = await drive_async_navigation_install(service,snapshot)
	current = await async_navigation_receipt(service,snapshot)
	add_result("async_navigation_reset_drains_then_reuses_same_service",held.get("reason")=="navigation_upload_pending" and reset_finished and not idle.get("busy",true) and service.get_instance_id()==service_id and install.installed and current.get("status")=="ready" and current.get("sourceRevision")==7,install)
	var installed_weak: WeakRef = weakref(service.descriptors_by_region.get(region))
	owner.source_key = "async-contract-source:8"
	snapshot = async_navigation_snapshot(owner,8)
	service.register_tile_snapshot(snapshot)
	held = await wait_for_service_prepared_without_upload(service,snapshot)
	var pending_weak: WeakRef = weakref(service._publication_queue._descriptor)
	service.request_publication_shutdown()
	add_result("async_navigation_shutdown_detaches_both_installed_and_pending",held.get("reason")=="navigation_upload_pending" and service.descriptors_by_region.is_empty() and service.region_rids_by_region.is_empty() and not service._publication_queue.stats().shutdownComplete,{})
	var shutdown := await wait_for_service_publication(service,true)
	await physics_frame
	var worker_state: Dictionary = shutdown.get("worker",{})
	add_result("async_navigation_shutdown_joins_all_owned_work_and_releases_payloads",shutdown.get("shutdownComplete",false) and not worker_state.get("busy",true) and not worker_state.get("workerRunning",true) and not worker_state.get("retirementPending",true) and service._publication_queue.worker._thread==null and installed_weak!=null and installed_weak.get_ref()==null and pending_weak!=null and pending_weak.get_ref()==null and navigation_map_ids()==baseline_maps and int(worker_state.get("lastRetirementThreadId",-1))>0 and int(worker_state.get("lastRetirementThreadId",-1))!=OS.get_thread_caller_id(),shutdown)

func verify_owned_publication_queue_progress() -> void:
	# Synthetic producer, real shared queue, owned worker and server install.
	var baseline_maps := navigation_map_ids()
	# A resumable cursor may advance only once per rendered frame. The queue can
	# contain many retained tiles, but its attempts budget must not spin on the
	# sole active cursor after the adapter reports that frame's slice consumed.
	var budget_owner := SyntheticFrameBudgetCaptureOwner.new()
	var budget_service = NavmeshWorldServiceScript.new()
	budget_service.setup()
	var budget_publisher := RoutePublicationAdapter.new()
	budget_publisher.world = budget_owner
	budget_publisher.main = budget_owner.main
	budget_publisher.navmesh_world = budget_service
	budget_publisher._enqueue_navmesh_tile_publish("0,0",budget_owner.source_key,true)
	budget_publisher._enqueue_navmesh_tile_publish("1,0",budget_owner.source_key,true)
	var budget_processed := budget_publisher._process_queued_navmesh_tile_publishes(2,4000)
	add_result("owned_publication_frame_budget_yields_once_and_retains_all_demand",budget_processed==0
		and budget_owner.capture_calls==["0,0"] and budget_publisher.queued_navmesh_tile_keys.size()==2
		and budget_publisher.queued_navmesh_tile_keys.has("0,0") and budget_publisher.queued_navmesh_tile_keys.has("1,0"),
		{"captureCalls":budget_owner.capture_calls,"queued":budget_publisher.queued_navmesh_tile_keys})
	await process_frame
	budget_owner.frame_budget_used=false
	budget_publisher._process_queued_navmesh_tile_publishes(2,4000)
	add_result("owned_publication_frame_budget_resumes_active_capture_next_frame",budget_owner.capture_calls==["0,0","0,0"]
		and budget_publisher.queued_navmesh_tile_keys.size()==2,
		{"captureCalls":budget_owner.capture_calls,"queued":budget_publisher.queued_navmesh_tile_keys})
	budget_service.request_publication_shutdown()
	await wait_for_service_publication(budget_service,true)
	var owner := SyntheticQueuedPublicationOwner.new()
	var snapshot := async_navigation_snapshot(owner,1)
	owner.captured[snapshot.tileKey] = snapshot
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	service.register_tile_snapshot(snapshot)
	var held := await wait_for_service_prepared_without_upload(service,snapshot)
	var publisher := RoutePublicationAdapter.new()
	publisher.world = owner
	publisher.main = owner.main
	publisher.navmesh_world = service
	publisher._enqueue_navmesh_tile_publish("1,0",owner.source_key,true)
	var processed := publisher._process_queued_navmesh_tile_publishes(1,4000)
	add_result("owned_publication_pending_slot_does_not_capture_unrelated_tiles",held.reason=="navigation_upload_pending"
		and processed==0 and owner.capture_calls.is_empty() and publisher.queued_navmesh_tile_keys==["1,0"],{})
	var state := held
	for frame in range(60):
		await process_frame
		state = service.advance_publication()
		if state.status=="ready": break
	# A ready result must be completion debt: an expensive final owner proof may
	# exceed the nominal slice, but it must execute once and install this frame.
	processed = publisher._process_queued_navmesh_tile_publishes(1,4000)
	add_result("owned_publication_missing_caller_retains_other_demand",state.status=="ready" and processed==0
		and owner.capture_calls.is_empty() and publisher.queued_navmesh_tile_keys==["1,0"],{})
	publisher._enqueue_navmesh_tile_publish(snapshot.tileKey,owner.source_key,false)
	processed = publisher._process_queued_navmesh_tile_publishes(1,4000,true)
	add_result("owned_publication_preserves_foreground_filter",processed==0 and owner.capture_calls.is_empty()
		and publisher.queued_navmesh_tile_keys.has(snapshot.tileKey) and publisher.queued_navmesh_tile_keys.has("1,0"),{})
	owner.source_key_delay_usec = 5000
	processed = publisher._process_queued_navmesh_tile_publishes(1,1)
	owner.source_key_delay_usec = 0
	var retained: Dictionary = service.accepted_tile_state(String(snapshot.tileKey),owner.source_key,owner.main.seed_text,owner)
	var owned_before_sync: bool = retained.status=="retained" and retained.sourceOwned and processed==1
	var retained_serial: int = int(retained.acceptedSerial)
	var first_capture_matches: bool = owner.capture_calls==[snapshot.tileKey]
	retained = {}
	var acknowledged: bool = await drive_publisher_acknowledgement(publisher,String(snapshot.tileKey))
	var receipt: Dictionary = service.tile_publication_readiness(String(snapshot.tileKey),owner.source_key)
	var current: Dictionary = service.accepted_tile_state(String(snapshot.tileKey),owner.source_key,owner.main.seed_text,owner)
	add_result("owned_publication_installs_ready_slot_after_budget_exhaustion_before_unrelated_capture",owned_before_sync and acknowledged
		and first_capture_matches and receipt.status=="ready" and current.acceptedSerial==retained_serial,receipt)
	current = {}
	acknowledged = await drive_publisher_acknowledgement(publisher,"1,0")
	add_result("owned_publication_releases_slot_to_retained_next_tile",acknowledged
		and owner.capture_calls.has("1,0") and owner.capture_calls.front()==snapshot.tileKey and publisher.queued_navmesh_tile_keys.is_empty(),{})
	owner.source_key = "async-contract-source:2"
	snapshot = async_navigation_snapshot(owner,2)
	owner.captured[snapshot.tileKey] = snapshot
	service.register_tile_snapshot(snapshot)
	held = await wait_for_service_prepared_without_upload(service,snapshot)
	# Explicit synthetic fault injection at the real owned upload boundary.
	# This checks failure scheduling, not a generated-geometry failure.
	service._publication_queue._state = "failed"
	service._publication_queue._reason = "synthetic_upload_failure"
	publisher._enqueue_navmesh_tile_publish("2,0",owner.source_key,true)
	publisher._enqueue_navmesh_tile_publish(snapshot.tileKey,owner.source_key,false)
	publisher._process_queued_navmesh_tile_publishes(1,4000)
	var failure_reported := false
	for record: Dictionary in publisher.last_navmesh_tile_queue_debug:
		if record.get("tile")==snapshot.tileKey and record.get("status")=="failed" and record.get("reason")=="synthetic_upload_failure":
			failure_reported = true
	acknowledged = await drive_publisher_acknowledgement(publisher,"2,0")
	add_result("synthetic_failed_owned_slot_reports_failure_and_retains_retry_without_starving_next",held.reason=="navigation_upload_pending"
		and failure_reported and acknowledged and publisher.queued_navmesh_tile_keys.has(snapshot.tileKey)
		and publisher.published_navmesh_tile_keys.get(snapshot.tileKey,"")!=snapshot.tileKey+"|"+owner.source_key
		and service.accepted_tile_state("2,0",owner.source_key,owner.main.seed_text,owner).status=="acknowledged",{"failureReported":failure_reported})
	service.request_publication_shutdown()
	var shutdown := await wait_for_service_publication(service,true)
	await physics_frame
	add_result("owned_publication_queue_fixture_drains_resources",shutdown.shutdownComplete
		and navigation_map_ids()==baseline_maps,shutdown)

func verify_async_navigation_orphaned_recapture() -> void:
	# Separate same-frame owner-loss contract; keep ordinary advance-driven
	# lost-owner cancellation coverage in the lifecycle fixture above intact.
	var baseline_maps := navigation_map_ids()
	var owner = SyntheticPublicationOwner.new()
	var snapshot := async_navigation_snapshot(owner,1)
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	service.register_tile_snapshot(snapshot)
	var held := await wait_for_service_prepared_without_upload(service,snapshot)
	var orphaned_prepared: WeakRef = weakref(service._publication_queue._descriptor) if service._publication_queue._descriptor!=null else null
	var orphaned_epoch: int = service._publication_queue.worker._epoch
	var owner_weak: WeakRef = weakref(owner)
	owner = null
	var replacement_owner = SyntheticPublicationOwner.new()
	var replacement_capture := recapture_async_navigation_snapshot(snapshot,101)
	replacement_capture.publicationOwner = weakref(replacement_owner)
	var requested: Dictionary = service.register_tile_snapshot(replacement_capture)
	add_result("async_navigation_same_frame_replacement_owner_cannot_adopt_orphan",held.get("reason")=="navigation_upload_pending" and owner_weak.get_ref()==null and orphaned_prepared!=null and requested.get("status")=="pending" and not requested.get("installed",false) and service._publication_queue._descriptor==null and service._publication_queue.stats().binding.is_empty() and service._publication_queue.worker._epoch>orphaned_epoch and service.region_rids_by_region.is_empty(),{"status":requested.get("status"),"epoch":service._publication_queue.worker._epoch})
	var install := await drive_async_navigation_install(service,replacement_capture)
	var receipt := await async_navigation_receipt(service,replacement_capture)
	add_result("async_navigation_replacement_owner_retries_with_fresh_preparation",install.installed and receipt.get("status")=="ready" and receipt.get("sourceRevision")==101 and service._publication_queue.stats().preparedCount==2 and orphaned_prepared!=null and orphaned_prepared.get_ref()==null,install)
	service.request_publication_shutdown()
	var shutdown := await wait_for_service_publication(service,true)
	await physics_frame
	add_result("async_navigation_orphaned_recapture_drains_owned_resources",shutdown.get("shutdownComplete",false) and navigation_map_ids()==baseline_maps,shutdown)

func verify_prepared_navigation_portal_filter_retirement() -> void:
	# Synthetic service contract: deleting declared portal data is not a live
	# door interaction. Geometry, worker retirement and server receipts are real.
	await physics_frame
	await process_frame
	var baseline_maps := navigation_map_ids()
	var owner = SyntheticPublicationOwner.new()
	var snapshot := async_navigation_snapshot(owner,1,true)
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	var region := NavigationBakeDescriptorScript.chunk_region_id(String(snapshot.tileKey))
	service.register_tile_snapshot(snapshot)
	var install := await drive_async_navigation_install(service,snapshot)
	var first := await async_navigation_receipt(service,snapshot)
	var door_receipt: Dictionary = service.tile_publication_readiness(String(snapshot.tileKey),String(snapshot.sourceKey),[],["async-filter-link"])
	add_result("prepared_portal_fixture_installs_real_owned_link",install.installed and door_receipt.get("status")=="ready" and service.door_link_records_by_portal.has("async-filter-door"),{"install":install,"receiptStatus":door_receipt.get("status")})
	var prepared = service.descriptors_by_region.get(region)
	if prepared==null:
		service.request_publication_shutdown()
		await wait_for_service_publication(service,true)
		return
	var prepared_weak: WeakRef = weakref(prepared)
	var original_signature: String = prepared.stable_signature()
	var old_rid: RID = service.region_rids_by_region.get(region,RID())
	var forgotten: Dictionary = service.forget_door_portal("async-filter-door")
	var shell = service.descriptors_by_region.get(region)
	add_result("prepared_portal_filter_preserves_geometry_without_mutating_source",shell!=null and shell.get_script()==NavigationBakeDescriptorScript and is_same(shell.walkable_surfaces,prepared.walkable_surfaces) and shell.door_portals.is_empty() and shell.door_links.is_empty() and prepared.stable_signature()==original_signature and prepared.door_portals.size()==1 and int(forgotten.get("removedLinks",0))==1 and not service.door_link_records_by_portal.has("async-filter-door") and service.region_rids_by_region.get(region,RID())==old_rid,{"removedLinks":forgotten.get("removedLinks"),"filteredDescriptors":forgotten.get("filteredDescriptors")})
	prepared = null
	var idle := await wait_for_service_publication(service)
	var retirement_thread := int(idle.get("worker",{}).get("lastRetirementThreadId",-1))
	add_result("prepared_portal_filter_retires_old_descriptor_on_owned_worker",not idle.get("busy",true) and prepared_weak.get_ref()==null and retirement_thread>0 and retirement_thread!=OS.get_thread_caller_id(),{"retirementThread":retirement_thread,"mainThread":OS.get_thread_caller_id()})
	service._mark_dirty_region(region,{"tileKey":snapshot.tileKey,"revision":2},"synthetic_portal_removal")
	var rebuilds: int = service.rebuild_count
	var rebuilt := false
	for frame in 3:
		await process_frame
		for result: Dictionary in service.process_dirty_regions(1,4000):
			if result.get("status") in ["rebuilt","installed"]: rebuilt=true
	var stale: Dictionary = service.tile_publication_readiness(String(snapshot.tileKey),String(snapshot.sourceKey))
	add_result("prepared_portal_shell_cannot_take_synchronous_dirty_path",not rebuilt and service.rebuild_count==rebuilds and service.dirty_regions_by_region.has(region) and service.region_rids_by_region.get(region,RID())==old_rid and int(service._tile_publication_receipts.get(region,{}).get("installationSerial",0))==int(first.get("installationSerial",0)) and stale.get("status")!="ready",{"rebuilt":rebuilt,"rebuildCountDelta":service.rebuild_count-rebuilds,"oldReceiptStatus":stale.get("status"),"oldReceiptReason":stale.get("reason")})
	owner.source_key = "async-contract-source:2"
	snapshot = async_navigation_snapshot(owner,2)
	var requested: Dictionary = service.register_tile_snapshot(snapshot)
	add_result("prepared_portal_replacement_requires_fresh_worker_source",requested.get("status")=="pending" and service.region_rids_by_region.get(region,RID())==old_rid,{"status":requested.get("status")})
	install = await drive_async_navigation_install(service,snapshot,old_rid)
	var fresh := await async_navigation_receipt(service,snapshot)
	var replacement = service.descriptors_by_region.get(region)
	add_result("prepared_portal_fresh_revision_replaces_and_acknowledges",install.installed and install.previousRegionPreserved and fresh.get("status")=="ready" and fresh.get("sourceRevision")==2 and fresh.get("completeSurfaceCoverage",false) and int(fresh.get("installationSerial",0))>int(first.get("installationSerial",0)) and not service.dirty_regions_by_region.has(region) and replacement!=null and replacement.has_method("prepared_geometry") and replacement.door_links.is_empty() and not service.door_link_records_by_portal.has("async-filter-door"),{"install":install,"status":fresh.get("status"),"sourceRevision":fresh.get("sourceRevision")})
	shell=null; replacement=null
	service.request_publication_shutdown()
	var shutdown := await wait_for_service_publication(service,true)
	await physics_frame
	add_result("prepared_portal_filter_shutdown_drains_owned_resources",shutdown.get("shutdownComplete",false) and not shutdown.get("busy",true) and service._publication_queue.worker._thread==null and navigation_map_ids()==baseline_maps,shutdown)

func verify_autonomy_reset_keeps_navmesh_owner() -> void:
	var baseline_maps := navigation_map_ids()
	var autonomy = NpcAutonomySystemScript.new()
	root.add_child(autonomy)
	var shared_navmesh_world = autonomy.get("navmesh_world")
	autonomy.clear()
	var reset_navmesh_world = autonomy.get("navmesh_world")
	add_result(
		"autonomy_reset_preserves_navmesh_service_identity",
		shared_navmesh_world == reset_navmesh_world,
		{
			"initialServiceId": shared_navmesh_world.get_instance_id() if shared_navmesh_world != null else -1,
			"resetServiceId": reset_navmesh_world.get_instance_id() if reset_navmesh_world != null else -1
		}
	)
	if reset_navmesh_world != null:
		var descriptor = NavigationBakeDescriptorScript.create("autonomy-reset-region", "autonomy-reset-tile")
		descriptor.add_walkable_surface("autonomy-reset-surface", Vector3.ZERO, Vector3(1.35, 0.05, 1.35))
		reset_navmesh_world.register_chunk_descriptor(descriptor)
		reset_navmesh_world.sync_navigation_map_if_dirty()
	await physics_frame
	autonomy.queue_free()
	await process_frame
	await physics_frame
	add_result(
		"autonomy_reset_owner_releases_navigation_resources_on_delete",
		navigation_map_ids() == baseline_maps,
		{"baselineMaps": baseline_maps, "finalMaps": navigation_map_ids()}
	)

func verify_clear_flushes_before_map_release() -> void:
	var baseline_maps := navigation_map_ids()
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.default_config())
	var descriptor = NavigationBakeDescriptorScript.create("shutdown-flush-region", "shutdown-flush-tile")
	descriptor.add_walkable_surface("shutdown-flush-surface", Vector3.ZERO, Vector3(1.35, 0.05, 1.35))
	service.register_chunk_descriptor(descriptor)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	service.clear()
	await physics_frame
	await process_frame
	await physics_frame
	add_result(
		"clear_flushes_navigation_removals_before_map_release",
		navigation_map_ids() == baseline_maps,
		{"baselineMaps": baseline_maps, "finalMaps": navigation_map_ids(), "stats": service.stats()}
	)


class ReceiptService extends NavmeshWorldServiceScript:
	var install_calls := 0
	# Existing virtual signature deliberately remains two arguments.
	func _install_region(region_id: String, descriptor) -> Dictionary:
		install_calls += 1
		return super._install_region(region_id, descriptor)

func receipt_descriptor(tile_key: String, revision := 3):
	var descriptor = NavigationBakeDescriptorScript.create(NavigationBakeDescriptorScript.chunk_region_id(tile_key), tile_key)
	descriptor.revision = revision
	var cell_size := float(NavmeshWorldServiceScript.CELL)
	descriptor.add_walkable_surface("owned-a", Vector3.ZERO, Vector3(cell_size, 0.05, cell_size), {"cell":Vector3i.ZERO})
	descriptor.add_walkable_surface("owned-b", Vector3(cell_size,0,0), Vector3(cell_size,0.05,cell_size), {"cell":Vector3i(1,0,0)})
	descriptor.add_walkable_surface("not-emitted", Vector3(8,0,0), Vector3.ONE, {"walkable":false})
	descriptor.add_door_portal("receipt-door", Vector3(-0.4,0,0), Vector3(0.4,0,0))
	descriptor.add_door_link("owned-a", "owned-b", "receipt-door", {"id":"receipt-link"})
	descriptor.add_door_portal("failed-door", Vector3.ZERO, Vector3.ZERO)
	descriptor.add_door_link("owned-a", "owned-b", "failed-door", {"id":"not-installed-link"})
	return descriptor

func verify_tile_publication_receipts() -> void:
	var baseline_maps := navigation_map_ids()
	var service := ReceiptService.new()
	service.setup(NavigationBackendConfigScript.default_config())
	var tile := "receipt-tile"
	var descriptor = receipt_descriptor(tile)
	var region_id: String = descriptor.region_id
	var install: Dictionary = service.register_chunk_descriptor(descriptor, "source-a")
	var first: Dictionary = service.tile_publication_readiness(tile, "source-a", ["owned-a","owned-b"], ["receipt-link"])
	add_result("receipt_pending_before_explicit_sync", first.status=="pending" and first.reason=="installation_sync_pending", first)
	add_result("receipt_legacy_virtual_installer_preserved", service.install_calls==1 and install.installed, install)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var ready: Dictionary = service.tile_publication_readiness(tile, "source-a", ["owned-a","owned-b"], ["receipt-link"])
	add_result("receipt_exact_after_real_install_sync", ready.status=="ready" and ready.sourceKey=="source-a" and ready.sourceRevision==3 and ready.signature==descriptor.stable_signature() and ready.installationSerial>0 and ready.completeSurfaceCoverage and ready.missingDeclaredSurfaceIds.is_empty(), ready)
	var held: Dictionary = service._tile_publication_receipts[region_id]
	add_result("receipt_merged_surface_ownership", held.surfaces.get("owned-a",-1)==held.surfaces.get("owned-b",-2) and held.polygonCount==1, {"surfaces":held.surfaces,"polygonCount":held.polygonCount})
	add_result("receipt_deep_readonly_values", held.is_read_only() and held.surfaces.is_read_only() and held.links.is_read_only() and held.links["receipt-link"].is_read_only(), {})
	var missing_surface: Dictionary = service.tile_publication_readiness(tile, "source-a", ["not-emitted"])
	var missing_link: Dictionary = service.tile_publication_readiness(tile, "source-a", [], ["not-installed-link"])
	add_result("receipt_requires_emitted_surface_not_descriptor_count", missing_surface.status=="failed" and missing_surface.missingSurfaceIds==["not-emitted"], missing_surface)
	add_result("receipt_requires_installed_link_not_descriptor_count", missing_link.status=="failed" and missing_link.missingLinkIds==["not-installed-link"], missing_link)
	var invalid: Dictionary = service.tile_publication_readiness(tile, "")
	add_result("receipt_empty_expected_key_rejected", invalid.status=="failed", invalid)
	var cached: Dictionary = service.register_chunk_descriptor(receipt_descriptor(tile), "source-a")
	add_result("receipt_exact_cached_registration", cached.get("cached",false) and service.install_calls==1 and service._tile_publication_receipts[region_id]==held, cached)
	var original_center: Vector3 = descriptor.walkable_surfaces[0].center
	descriptor.walkable_surfaces[0].center = Vector3(0,0.1,0)
	var mutated: Dictionary = service.tile_publication_readiness(tile, "source-a")
	add_result("receipt_mutable_descriptor_change_rejected", mutated.status=="failed" and mutated.reason=="installed_descriptor_changed", mutated)
	descriptor.walkable_surfaces[0].center = original_center
	var changed_key: Dictionary = service.register_chunk_descriptor(receipt_descriptor(tile), "source-b")
	var pending_b: Dictionary = service.tile_publication_readiness(tile, "source-b")
	add_result("receipt_same_signature_new_key_fresh_install", not changed_key.get("cached",false) and service.install_calls==2 and pending_b.status=="pending" and pending_b.installationSerial>ready.installationSerial and pending_b.signature==ready.signature, pending_b)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var ready_b: Dictionary = service.tile_publication_readiness(tile, "source-b")
	add_result("receipt_replacement_ack_and_old_key_stale", ready_b.status=="ready" and service.tile_publication_readiness(tile,"source-a").status!="ready" and held.sourceKey=="source-a", ready_b)
	# Empty versus nonempty source keys cannot inherit or relabel a receipt.
	service.register_chunk_descriptor(receipt_descriptor(tile), "")
	add_result("receipt_empty_key_does_not_inherit_bound_install", service.install_calls==3 and service._tile_publication_receipts[region_id].sourceKey=="" and service.tile_publication_readiness(tile,"source-b").status!="ready", {})
	service.register_chunk_descriptor(receipt_descriptor(tile,4), "source-c")
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var revision_c: Dictionary = service.tile_publication_readiness(tile,"source-c")
	add_result("receipt_new_revision_bound", revision_c.status=="ready" and revision_c.sourceRevision==4, revision_c)
	service._mark_dirty_region(region_id, {"tileKey":tile,"revision":5}, "contract_edit")
	add_result("receipt_dirty_not_ready", service.tile_publication_readiness(tile,"source-c").reason=="tile_dirty", {})
	service.process_dirty_regions(1,4000)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	add_result("receipt_rebuild_does_not_reuse_old_source_binding", service.tile_publication_readiness(tile,"source-c").status!="ready" and service._tile_publication_receipts[region_id].sourceKey=="", {})
	service.register_chunk_descriptor(receipt_descriptor(tile,5), "source-d")
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var map_rid: RID = service.navigation_map
	service.navigation_map = RID()
	add_result("receipt_lost_map_rejected_without_invalid_rid_query", service.tile_publication_readiness(tile,"source-d").reason=="installed_map_lost", {})
	service.navigation_map = map_rid
	var region_rid: RID = service.region_rids_by_region[region_id]
	NavigationServer3D.region_set_map(region_rid, RID())
	service._mark_navigation_map_dirty()
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	add_result("receipt_actual_detached_region_rejected", service.tile_publication_readiness(tile,"source-d").reason=="installed_region_lost", {})
	NavigationServer3D.region_set_map(region_rid, map_rid)
	service._mark_navigation_map_dirty()
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var link_rid: RID = service._tile_publication_receipts[region_id].links["receipt-link"].rid
	NavigationServer3D.link_set_map(link_rid, RID())
	service._mark_navigation_map_dirty()
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	add_result("receipt_actual_detached_required_link_rejected", service.tile_publication_readiness(tile,"source-d",[],["receipt-link"]).reason=="required_links_missing", {})
	NavigationServer3D.link_set_map(link_rid, map_rid)
	service._mark_navigation_map_dirty()
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	service.unregister_chunk(region_id)
	add_result("receipt_unregister_erases_installation", not service._tile_publication_receipts.has(region_id) and service.tile_publication_readiness(tile,"source-d").status=="pending", {})
	var unloaded = receipt_descriptor(tile)
	unloaded.loaded=false
	service.register_chunk_descriptor(unloaded,"unloaded")
	add_result("receipt_unloaded_never_ready", service.tile_publication_readiness(tile,"unloaded").reason=="tile_unloaded" and not service._tile_publication_receipts.has(region_id), {})
	var empty = NavigationBakeDescriptorScript.create(region_id,tile)
	service.register_chunk_descriptor(empty,"empty")
	add_result("receipt_empty_never_ready", service.tile_publication_readiness(tile,"empty").status!="ready" and not service._tile_publication_receipts.has(region_id), {})
	# Duplicate source IDs in one merged cell are not complete ownership proof,
	# even though another source surface and a real merged polygon are present.
	var incomplete = receipt_descriptor(tile)
	incomplete.walkable_surfaces.append(incomplete.walkable_surfaces[0].duplicate())
	service.register_chunk_descriptor(incomplete,"incomplete")
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var incomplete_ready: Dictionary = service.tile_publication_readiness(tile,"incomplete")
	add_result("receipt_default_exposes_incomplete_declared_coverage", incomplete_ready.status=="ready" and not incomplete_ready.completeSurfaceCoverage and incomplete_ready.missingDeclaredSurfaceIds==["owned-a"] and service.tile_publication_readiness(tile,"incomplete",["owned-a"]).status=="failed", incomplete_ready)
	# Cancellation is the owner's existing unregister/clear path, including
	# cancellation before synchronization. No alternate cancellation protocol.
	service.register_chunk_descriptor(receipt_descriptor(tile),"cancel")
	service.unregister_chunk(region_id)
	add_result("receipt_cancel_before_sync_retains_no_install", service._tile_publication_receipts.is_empty(), {})
	var snapshot := {"tileKey":"snapshot-receipt","sourceKey":"snapshot-key","sourceRevision":7,
		"surfaces":[{"cell":Vector3i.ZERO,"spanIndex":0}]}
	service.register_tile_snapshot(snapshot)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var snapshot_ready: Dictionary = service.tile_publication_readiness("snapshot-receipt","snapshot-key",["surface:snapshot-receipt:0,0,0:0"])
	for frame in 60:
		if snapshot_ready.status!="pending": break
		await physics_frame
		snapshot_ready=service.tile_publication_readiness("snapshot-receipt","snapshot-key",["surface:snapshot-receipt:0,0,0:0"])
	add_result("receipt_snapshot_source_key_forwarded", snapshot_ready.status=="ready" and snapshot_ready.sourceRevision==7, snapshot_ready)
	service.clear()
	await physics_frame
	add_result("receipt_clear_releases_all_owned_state", service._tile_publication_receipts.is_empty() and navigation_map_ids()==baseline_maps and held.is_read_only() and held.sourceKey=="source-a", {})
	service.setup(NavigationBackendConfigScript.default_config())
	service.register_chunk_descriptor(receipt_descriptor(tile),"restart")
	add_result("receipt_clear_resets_sync_acknowledgement", service.tile_publication_readiness(tile,"restart").reason=="installation_sync_pending", {})
	service.clear()
	await physics_frame

func verify_grouped_door_publication_receipts() -> void:
	# Synthetic double-leaf source, real worker/upload/server acknowledgements.
	# Sharing a portal/routing ID does not make two distinct leaf crossings one.
	var baseline_maps := navigation_map_ids()
	var owner := SyntheticPublicationOwner.new()
	var snapshot := {"worldSeed":owner.main.seed_text,"tileKey":"0,0","sourceKey":owner.source_key,
		"sourceRevision":1,"surfaces":[{"cell":Vector3i.ZERO},{"cell":Vector3i(1,0,0)}],
		"doorPortals":[],"doorLinks":[]}
	var required: Array = []
	for x in 2:
		var start := Vector3(x*1.35,0,-1.35)
		var end := Vector3(x*1.35,0,1.35)
		var cell := Vector2i(x,0)
		snapshot.doorPortals.append({"id":"double-door","cell":cell,"entrance":start,"exit":end})
		var link := {"id":"door-link:double-door:0,0","portalId":"double-door","cell":cell,"start":start,"end":end}
		snapshot.doorLinks.append(link)
		required.append(link.duplicate())
	snapshot["publicationSource"] = NavigationPublicationSourceScript.new().capture(snapshot)
	snapshot["publicationOwner"] = weakref(owner)
	var service := NavmeshWorldServiceScript.new()
	service.setup()
	var install := await drive_async_navigation_install(service,snapshot)
	await async_navigation_receipt(service,snapshot)
	var ready := service.tile_publication_readiness("0,0",owner.source_key,[],required)
	var receipt: Dictionary = service._tile_publication_receipts.get("region:chunk:0,0",{})
	add_result("grouped_door_receipt_proves_both_distinct_leaf_sources",install.installed and ready.status=="ready" and receipt.get("doorLinkSources",[]).size()==2,{"install":install,"receipt":ready})
	var ambiguous := service.tile_publication_readiness("0,0",owner.source_key,[],[required[0].id])
	add_result("grouped_door_unqualified_routing_id_is_not_leaf_proof",ambiguous.status=="failed" and ambiguous.reason=="required_links_missing",ambiguous)
	var wrong: Dictionary = required[0].duplicate()
	wrong.cell = Vector2i(2,0)
	var changed := service.tile_publication_readiness("0,0",owner.source_key,[],[wrong])
	add_result("grouped_door_receipt_rejects_wrong_source_cell",changed.status=="failed" and changed.reason=="required_links_missing",changed)
	wrong = required[0].duplicate()
	wrong.end = required[1].end
	changed = service.tile_publication_readiness("0,0",owner.source_key,[],[wrong])
	add_result("grouped_door_receipt_rejects_mixed_leaf_endpoints",changed.status=="failed" and changed.reason=="required_links_missing",changed)
	var sources: Array = receipt.get("doorLinkSources",[])
	if sources.size()==2:
		var rid := RID()
		for source: Dictionary in sources:
			if source.cell == required[1].cell: rid = source.rid
		NavigationServer3D.link_set_map(rid,RID())
		service._mark_navigation_map_dirty()
		service.sync_navigation_map_if_dirty()
		await wait_for_installed_navigation(service)
		var missing := service.tile_publication_readiness("0,0",owner.source_key,[],required)
		add_result("grouped_door_receipt_requires_every_live_leaf_rid",missing.status=="failed" and missing.missingLinkIds==[required[1]],missing)
		NavigationServer3D.link_set_map(rid,service.navigation_map)
		service._mark_navigation_map_dirty()
		service.sync_navigation_map_if_dirty()
		await wait_for_installed_navigation(service)
	var duplicate: Dictionary = snapshot.publicationSource.snapshot.duplicate(true)
	owner.source_key = "double-door-duplicate:2"
	duplicate.sourceKey = owner.source_key
	duplicate.sourceRevision = 2
	duplicate.doorLinks.append(duplicate.doorLinks[0].duplicate())
	duplicate["publicationSource"] = NavigationPublicationSourceScript.new().capture(duplicate)
	duplicate["publicationOwner"] = weakref(owner)
	install = await drive_async_navigation_install(service,duplicate)
	await async_navigation_receipt(service,duplicate)
	var repeated := service.tile_publication_readiness("0,0",owner.source_key,[],required)
	add_result("grouped_door_identical_source_duplicates_remain_ambiguous",install.installed and repeated.status=="failed" and repeated.reason=="required_link_source_ambiguous",repeated)
	service.request_publication_shutdown()
	var shutdown := await wait_for_service_publication(service,true)
	await physics_frame
	add_result("grouped_door_publication_shutdown_releases_owned_maps",shutdown.get("shutdownComplete",false) and navigation_map_ids()==baseline_maps,shutdown)

func handoff_cached_input(adapter, tile_key: String) -> Dictionary:
	for request: Dictionary in adapter.navmesh_tile_snapshot_cache.values():
		if request.get("tileKey") == tile_key:
			return request.get("publicationInput",{})
	return {}

func verify_capture_retirement_publication_handoff() -> void:
	# Synthetic flat terrain, real capture, retirement, compiler, coordinator and
	# NavigationServer receipts. This proves ownership/continuation, not gameplay.
	var baseline_maps := navigation_map_ids()
	var world := SyntheticFiniteBoundsWorld.new()
	world.prop_root = Node3D.new()
	world.add_child(world.prop_root)
	get_root().add_child(world)
	var adapter := SyntheticFiniteBoundsAdapter.new()
	adapter.setup(null,world)
	var service := NavmeshWorldServiceScript.new()
	service.setup()
	adapter.bind_navigation_publication_service(service)
	var publisher := RoutePublicationAdapter.new()
	publisher.world = adapter
	publisher.main = world
	publisher.navmesh_world = service
	# Cancel an actual unused capture to put real payload retirement ahead of
	# the queued batch, without inventing an accepted result or worker packet.
	var unused: Dictionary = await wait_for_navigation_capture(adapter,"-1,0")
	var unused_ready: bool = unused.get("publicationInput",{}).get("status") == "prepared"
	var unused_cursor: WeakRef = weakref(adapter._navigation_capture) if adapter._navigation_capture != null else null
	unused = {}
	adapter.release_navigation_capture_cache()
	var queued_keys: Array[String] = []
	for tile_x in range(8): queued_keys.append("%d,0" % tile_x)
	for key: String in queued_keys:
		publisher._enqueue_navmesh_tile_publish(key,adapter.navmesh_tile_source_key_for_tile(key),true)
	var inputs: Dictionary = {}
	var cursors: Dictionary = {}
	var pending_owned: bool = true
	var input_identity_stable: bool = true
	var detached_after_seal: bool = true
	var advance_preceded_capture: bool = true
	var saw_retirement: bool = service._publication_queue.stats().get("retiredBatchCount",0)>0
	var demand_retained: bool = true
	var saw_first_handoff: bool = false
	var first_handoff_kept_next_demand: bool = false
	var first_handoff_facts: Array[Dictionary] = []
	var final_state_facts: Array[Dictionary] = []
	var final_acknowledged_count: int = 0
	var deadline: int = Time.get_ticks_msec()+15000
	while Time.get_ticks_msec()<deadline:
		await process_frame
		# Match the runtime ordering: this frame's only worker advance happens
		# before the capture can finish and before register_tile_snapshot retries.
		var advanced: Dictionary = service.advance_publication()
		advance_preceded_capture = advance_preceded_capture and service._publication_queue.advanced_this_frame()
		saw_retirement = saw_retirement or bool(advanced.get("worker",{}).get("retirementPending",false)) \
			or int(advanced.get("retiredBatchCount",0))>0
		publisher.begin_frame()
		var accepted_count: int = 0
		var source_owned_count: int = 0
		var unowned_queued_count: int = 0
		var frame_state_facts: Array[Dictionary] = []
		for key: String in queued_keys:
			var source_key: String = adapter.navmesh_tile_source_key_for_tile(key)
			var state: Dictionary = service.accepted_tile_state(key,source_key,world.seed_text,adapter)
			var queued_current: bool = publisher.queued_navmesh_tile_keys.has(key) \
				and publisher.queued_navmesh_tile_source_keys.get(key,"")==source_key
			demand_retained = demand_retained and (queued_current or bool(state.sourceOwned))
			var facts: Dictionary = accepted_state_facts(state)
			facts["tileKey"] = key
			facts["queuedCurrentSource"] = queued_current
			frame_state_facts.append(facts)
			if state.sourceOwned:
				source_owned_count += 1
				if state.status=="acknowledged" and not publisher.queued_navmesh_tile_keys.has(key): accepted_count += 1
				state = {}
				continue
			if queued_current: unowned_queued_count += 1
			state = {}
			var input: Dictionary = handoff_cached_input(adapter,key)
			if input.is_empty(): continue
			if inputs.has(key): input_identity_stable = input_identity_stable and is_same(inputs[key],input)
			else: inputs[key] = input
			var current = adapter._navigation_capture
			pending_owned = pending_owned and current != null and current.tile_key == key and current.status == "ready"
			if current != null and current.tile_key == key:
				if not cursors.has(key): cursors[key] = weakref(current)
				else: pending_owned = pending_owned and cursors[key].get_ref() == current
				detached_after_seal = detached_after_seal and current._records.is_empty() and current._block_keys.is_empty() \
					and current._overlay.is_empty() and current.snapshot.blocked.is_empty() and current.snapshot.doors.is_empty()
			current = null
			input = {}
		# The sole worker advances once per frame, so the first source handoff
		# precedes the rest of the retained batch. Any tile may finish first; server
		# acknowledgement is independent of the remaining queue.
		if not saw_first_handoff and source_owned_count==1:
			saw_first_handoff = true
			first_handoff_kept_next_demand = unowned_queued_count==queued_keys.size()-1
			first_handoff_facts = frame_state_facts.duplicate(true)
		final_state_facts = frame_state_facts
		final_acknowledged_count = accepted_count
		if accepted_count == queued_keys.size(): break
	add_result("capture_handoff_advances_worker_before_capture_with_real_retirement",unused_ready \
		and unused_cursor != null and saw_retirement and advance_preceded_capture,{})
	add_result("capture_handoff_retains_exact_sealed_input_and_owned_slot_until_ack",inputs.size()==queued_keys.size() \
		and cursors.size()==queued_keys.size() and input_identity_stable and pending_owned and detached_after_seal,
		{"capturedTiles":inputs.keys(),"inputIdentityStable":input_identity_stable,"pendingOwned":pending_owned})
	# The normal publisher tick must synchronize even its final pending tile.
	await wait_for_installed_navigation(service)
	var receipts_ready: bool = true
	var compiled_off_main: bool = true
	var final_receipt_facts: Array[Dictionary] = []
	for key: String in queued_keys:
		var source_key: String = adapter.navmesh_tile_source_key_for_tile(key)
		var receipt: Dictionary = service.tile_publication_readiness(key,source_key)
		var accepted: Dictionary = service.accepted_tile_source(key,source_key,world.seed_text,adapter)
		var descriptor = service.descriptors_by_region.get(NavigationBakeDescriptorScript.chunk_region_id(key))
		var thread_id: int = int(descriptor.prepared_geometry().get("threadId",-1)) if descriptor != null else -1
		receipts_ready = receipts_ready and receipt.get("status")=="ready" and receipt.get("completeSurfaceCoverage",false) \
			and not accepted.is_empty() and accepted.source.snapshot.surfaces.size()==256
		compiled_off_main = compiled_off_main and thread_id>0 and thread_id!=OS.get_thread_caller_id()
		final_receipt_facts.append({"tileKey":key,"status":receipt.get("status"),"reason":receipt.get("reason"),
			"completeSurfaceCoverage":receipt.get("completeSurfaceCoverage",false),"sourceOwned":not accepted.is_empty(),
			"surfaceCount":accepted.source.snapshot.surfaces.size() if not accepted.is_empty() else 0,"threadId":thread_id})
		accepted = {}
		descriptor = null
	var publication_state: Dictionary = service._publication_queue.stats()
	publication_state["handoffContract"] = {"demandRetained":demand_retained,"sawFirstHandoff":saw_first_handoff,
		"firstHandoffKeptNextDemand":first_handoff_kept_next_demand,"acknowledgedBeforeReceiptWait":final_acknowledged_count,
		"receiptsReady":receipts_ready,"compiledOffMain":compiled_off_main,"queueEmpty":publisher.queued_navmesh_tile_keys.is_empty(),
		"captureReleased":adapter._navigation_capture==null,"firstHandoff":first_handoff_facts,
		"finalStates":final_state_facts,"finalReceipts":final_receipt_facts}
	add_result("capture_handoff_two_queued_tiles_reach_real_worker_and_server_acceptance",receipts_ready \
		and compiled_off_main and demand_retained and saw_first_handoff and first_handoff_kept_next_demand \
		and final_acknowledged_count==queued_keys.size() and publisher.queued_navmesh_tile_keys.is_empty() \
		and adapter._navigation_capture == null and publication_state.preparedCount==queued_keys.size() \
		and publication_state.uploadedCount==queued_keys.size(),publication_state)
	inputs = {}
	# Deliver one real terrain revision through both production event consumers.
	# The old prepared descriptor stays dirty until the normal publisher installs
	# the fresh source; it must not make the current request permanently invalid.
	var original_key: String = adapter.navmesh_tile_source_key_for_tile("0,0")
	var previous: Dictionary = service.accepted_tile_state("0,0",original_key,world.seed_text,adapter)
	var previous_serial: int = int(previous.acceptedSerial)
	previous = {}
	var source_event := {"tileKey":"0,0","changeKinds":["terrain_edit"],"revision":adapter.static_snapshot_revision+1}
	service.apply_navigation_events([source_event])
	adapter.apply_navigation_events([source_event])
	var replacement_key: String = adapter.navmesh_tile_source_key_for_tile("0,0")
	var replacement_state: Dictionary = service.accepted_tile_state("0,0",replacement_key,world.seed_text,adapter)
	var stale_state: Dictionary = service.accepted_tile_state("0,0",original_key,world.seed_text,adapter)
	add_result("capture_handoff_fresh_source_is_retryable_while_predecessor_dirty",replacement_key!=original_key
		and service.dirty_regions_by_region.has("region:chunk:0,0") and replacement_state.status=="absent"
		and replacement_state.reason=="navigation_accepted_source_obsolete" and not replacement_state.sourceOwned
		and stale_state.status=="invalid" and not stale_state.sourceOwned,accepted_state_facts(replacement_state))
	replacement_state = {}; stale_state = {}
	publisher._enqueue_navmesh_tile_publish("0,0",replacement_key,true)
	var replacement_acknowledged: bool = await drive_publisher_acknowledgement(publisher,"0,0")
	replacement_state = service.accepted_tile_state("0,0",replacement_key,world.seed_text,adapter)
	var replacement_receipt: Dictionary = service.tile_publication_readiness("0,0",replacement_key)
	add_result("capture_handoff_source_revision_recaptures_and_acknowledges_normally",replacement_acknowledged
		and replacement_state.status=="acknowledged" and replacement_state.acceptedSerial>previous_serial
		and replacement_receipt.status=="ready" and not service.dirty_regions_by_region.has("region:chunk:0,0")
		and service._publication_queue.prepared_count==queued_keys.size()+1 and service._publication_queue.uploaded_count==queued_keys.size()+1
		and adapter._navigation_capture==null,accepted_state_facts(replacement_state))
	replacement_state = {}
	# Chunk loading changes only this tile's publication identity. An unrelated
	# in-flight capture keeps its exact owner; reading the source repeatedly
	# cannot restart that cursor or invent another source revision.
	var load_old_key: String = adapter.navmesh_tile_source_key_for_tile("0,0")
	var unrelated_key: String = adapter.navmesh_tile_source_key_for_tile("1,0")
	var shared_static: int = adapter.static_snapshot_revision
	var shared_semantic: int = adapter.semantic_revision
	var unrelated_capture_key: String = adapter.navmesh_tile_source_key_for_tile("40,0")
	var unrelated_header: Dictionary = adapter.build_navmesh_tile_snapshot("40,0")
	var unrelated_cursor: WeakRef = weakref(adapter._navigation_capture) if adapter._navigation_capture!=null else null
	unrelated_header = {}
	var load_event := {"tileKey":"0,0","changeKinds":["chunk_loaded"],"revision":adapter.last_event_revision+1}
	service.apply_navigation_events([load_event])
	adapter.apply_navigation_events([load_event])
	var first_load_key: String = adapter.navmesh_tile_source_key_for_tile("0,0")
	# The real service dirties every delivered entry, including equal revisions.
	# The owner must issue another local identity for that repeated delivery.
	service.apply_navigation_events([load_event])
	adapter.apply_navigation_events([load_event])
	var load_key: String = adapter.navmesh_tile_source_key_for_tile("0,0")
	replacement_state = service.accepted_tile_state("0,0",load_key,world.seed_text,adapter)
	add_result("capture_handoff_chunk_load_revises_only_its_source_and_preserves_other_cursor",first_load_key!=load_old_key and load_key!=first_load_key
		and adapter.navmesh_tile_source_key_for_tile("0,0")==load_key and replacement_state.status=="absent"
		and adapter.navmesh_tile_source_key_for_tile("1,0")==unrelated_key
		and adapter.static_snapshot_revision==shared_static and adapter.semantic_revision==shared_semantic
		and unrelated_cursor!=null and unrelated_cursor.get_ref()!=null
		and adapter._navigation_capture==unrelated_cursor.get_ref() and adapter._navigation_capture.tile_key=="40,0",
		accepted_state_facts(replacement_state))
	replacement_state = {}
	adapter.release_navigation_capture_slot("40,0",unrelated_capture_key)
	publisher._enqueue_navmesh_tile_publish("0,0",load_key,true)
	var load_acknowledged: bool = await drive_publisher_acknowledgement(publisher,"0,0")
	replacement_state = service.accepted_tile_state("0,0",load_key,world.seed_text,adapter)
	add_result("capture_handoff_chunk_loaded_source_reaches_ordinary_worker_acknowledgement",load_acknowledged
		and replacement_state.status=="acknowledged" and service.tile_publication_readiness("0,0",load_key).status=="ready"
		and not service.dirty_regions_by_region.has("region:chunk:0,0")
		and service._publication_queue.prepared_count==queued_keys.size()+2 and service._publication_queue.uploaded_count==queued_keys.size()+2,
		accepted_state_facts(replacement_state))
	replacement_state = {}
	# A sealed source whose caller disappears must be releasable before any
	# worker accepts it. Wrong identities must not cancel the current owner.
	var cancelled: Dictionary = await wait_for_navigation_capture(adapter,"20,0")
	var cancel_key: String = String(cancelled.get("sourceKey",""))
	var cancelled_cursor: WeakRef = weakref(adapter._navigation_capture) if adapter._navigation_capture != null else null
	adapter.release_navigation_capture_slot("21,0",cancel_key)
	adapter.release_navigation_capture_slot("20,0",cancel_key+"-wrong")
	add_result("capture_handoff_wrong_binding_cannot_release_sealed_owner",cancelled_cursor != null \
		and adapter._navigation_capture == cancelled_cursor.get_ref() and adapter.active_navigation_capture_tile()=="20,0",{})
	publisher._enqueue_navmesh_tile_publish("20,0",cancel_key,true)
	publisher.invalidate()
	add_result("capture_handoff_cancelled_demand_releases_slot_without_acceptance",cancelled.get("publicationInput",{}).get("status")=="prepared" \
		and adapter.active_navigation_capture_tile().is_empty() and publisher.queued_navmesh_tile_keys.is_empty() \
		and service.accepted_tile_source("20,0",cancel_key,world.seed_text,adapter).is_empty(),{})
	cancelled = {}
	# The original stale header must fail the real owner check; it cannot become
	# an accepted tile after a source change merely because its input is sealed.
	var stale: Dictionary = await wait_for_navigation_capture(adapter,"30,0")
	var stale_key: String = String(stale.get("sourceKey",""))
	var stale_cursor: WeakRef = weakref(adapter._navigation_capture) if adapter._navigation_capture != null else null
	adapter.invalidate()
	var rejected: Dictionary = service.register_tile_snapshot(stale)
	add_result("capture_handoff_source_change_rejects_sealed_header_before_ack",stale_cursor != null \
		and rejected.get("reason")=="navigation_source_owner_changed" and adapter.active_navigation_capture_tile().is_empty() \
		and service.accepted_tile_source("30,0",stale_key,world.seed_text,adapter).is_empty(),
		{"status":rejected.get("status"),"reason":rejected.get("reason")})
	stale = {}
	service.begin_publication_reset()
	var drained: Dictionary = await wait_for_service_publication(service)
	var released: bool = unused_cursor != null and unused_cursor.get_ref()==null \
		and cancelled_cursor != null and cancelled_cursor.get_ref()==null and stale_cursor != null and stale_cursor.get_ref()==null
	for reference: WeakRef in cursors.values(): released = released and reference.get_ref()==null
	add_result("capture_handoff_reset_drains_all_cursors_inputs_and_acceptances",not drained.get("busy",true) \
		and service.finish_publication_reset() and released and adapter.navmesh_tile_snapshot_cache.is_empty() \
		and service._accepted_tile_sources.is_empty() and service.descriptors_by_region.is_empty(),drained)
	service.request_publication_shutdown()
	var shutdown: Dictionary = await wait_for_service_publication(service,true)
	await physics_frame
	add_result("capture_handoff_shutdown_releases_owned_threads_and_navigation_maps",shutdown.get("shutdownComplete",false) \
		and service._publication_queue.worker._thread==null and navigation_map_ids()==baseline_maps \
		and int(shutdown.get("worker",{}).get("lastRetirementThreadId",-1))>0 \
		and int(shutdown.get("worker",{}).get("lastRetirementThreadId",-1))!=OS.get_thread_caller_id(),shutdown)
	publisher.world = null
	publisher.main = null
	publisher.navmesh_world = null
	adapter.main = null
	world.free()
	await process_frame

func direct_handoff_capture_facts(adapter) -> Dictionary:
	# Keep a cursor's strong reference inside a synchronous helper frame.
	var cursor = adapter._navigation_capture
	if cursor == null: return {"id":0,"tileKey":"","status":""}
	return {"id":cursor.get_instance_id(),"tileKey":cursor.tile_key,"status":cursor.status}

func direct_handoff_capture_reference(adapter) -> WeakRef:
	var cursor = adapter._navigation_capture
	return weakref(cursor) if cursor != null else null

func direct_handoff_capture_released(reference: WeakRef) -> bool:
	return reference != null and reference.get_ref() == null

func direct_handoff_input_matches(adapter, request: Dictionary) -> bool:
	return is_same(handoff_cached_input(adapter,"0,0"),request.get("publicationInput",{}))

func direct_handoff_accepted_facts(service, adapter, source_key: String) -> Dictionary:
	# Export scalar receipt facts, never the borrowed accepted source graph.
	var state: Dictionary = service.accepted_tile_state("0,0",source_key,adapter.main.seed_text,adapter)
	var facts: Dictionary = accepted_state_facts(state)
	facts["surfaceCount"] = state.accepted.source.snapshot.surfaces.size() if state.sourceOwned else -1
	var descriptor = service.descriptors_by_region.get("region:chunk:0,0")
	facts["threadId"] = int(descriptor.prepared_geometry().get("threadId",-1)) if descriptor != null else -1
	return facts

func verify_direct_capture_source_handoff() -> void:
	# Synthetic terrain, real capture/filter/worker/server ownership. The real
	# publisher remains idle throughout: no selector/release/tick drives the act.
	for mode: String in ["retained","acknowledged","empty"]:
		await verify_direct_capture_source_handoff_case(mode)

func verify_direct_capture_source_handoff_case(mode: String) -> void:
	var label: String = "direct_capture_handoff_"+mode
	var baseline_maps: Array[String] = navigation_map_ids()
	var world := SyntheticFiniteBoundsWorld.new()
	if mode == "empty": world.WATER_LEVEL = 1.0
	world.prop_root = Node3D.new()
	world.add_child(world.prop_root)
	get_root().add_child(world)
	var adapter := SyntheticFiniteBoundsAdapter.new()
	adapter.setup(null,world)
	var service := NavmeshWorldServiceScript.new()
	service.setup()
	adapter.bind_navigation_publication_service(service)
	var publisher := RoutePublicationAdapter.new()
	publisher.world = adapter
	publisher.main = world
	publisher.navmesh_world = service
	var primed: Dictionary = prime_entry_proof_capture(adapter)
	var predecessor: WeakRef = direct_handoff_capture_reference(adapter)
	var pending_b: Dictionary = adapter.build_navmesh_tile_snapshot("1,0")
	var pending_facts: Dictionary = direct_handoff_capture_facts(adapter)
	var pending_preserved: bool = primed.status=="pending" and primed.steps==1 \
		and pending_b.get("reason")=="navigation_capture_slot_busy" and pending_facts.id==primed.cursorId \
		and pending_facts.tileKey=="0,0" and publisher.queued_navmesh_tile_keys.is_empty()
	add_result(label+"_pending_predecessor_keeps_slot",pending_preserved,
		{"primed":primed,"requestStatus":pending_b.get("publicationStatus"),"reason":pending_b.get("reason"),"capture":pending_facts})
	pending_b = {}
	var snapshot_a: Dictionary = await wait_for_navigation_capture(adapter,"0,0")
	var source_a: String = String(snapshot_a.get("sourceKey",""))
	var sealed_b: Dictionary = adapter.build_navmesh_tile_snapshot("1,0")
	var sealed_facts: Dictionary = direct_handoff_capture_facts(adapter)
	var sealed_preserved: bool = snapshot_a.get("publicationInput",{}).get("status")=="prepared" \
		and sealed_b.get("reason")=="navigation_capture_slot_busy" and sealed_facts.id==primed.cursorId \
		and sealed_facts.status=="ready" and direct_handoff_input_matches(adapter,snapshot_a) \
		and publisher.queued_navmesh_tile_keys.is_empty()
	add_result(label+"_sealed_unsubmitted_predecessor_keeps_exact_input",sealed_preserved,
		{"capture":sealed_facts,"requestStatus":sealed_b.get("publicationStatus"),"reason":sealed_b.get("reason")})
	sealed_b = {}
	if not pending_preserved or not sealed_preserved:
		snapshot_a = {}
		publisher.world = null; publisher.main = null; publisher.navmesh_world = null
		await close_entry_proof_fixture(adapter,world,label,service)
		return
	# This helper advances/registers the actual worker result; it never calls
	# the publisher or an Adapter selector and does not explicitly synchronize.
	var install: Dictionary = await drive_async_navigation_install(service,snapshot_a)
	snapshot_a = {}
	if mode == "acknowledged":
		service.sync_navigation_map_if_dirty()
		await wait_for_installed_navigation(service)
	var accepted_before: Dictionary = direct_handoff_accepted_facts(service,adapter,source_a)
	var public_before: Dictionary = service.tile_publication_readiness("0,0",source_a)
	var expected_state: String = "retained" if mode=="retained" else "acknowledged"
	var expected_surfaces: int = 0 if mode=="empty" else 256
	var installed: bool = install.status=="empty" if mode=="empty" else bool(install.installed)
	var source_owned: bool = installed and accepted_before.sourceOwned and accepted_before.status==expected_state \
		and accepted_before.empty==(mode=="empty") and accepted_before.surfaceCount==expected_surfaces \
		and accepted_before.threadId>0 and accepted_before.threadId!=OS.get_thread_caller_id() \
		and publisher.queued_navmesh_tile_keys.is_empty() and direct_handoff_capture_facts(adapter).id==primed.cursorId
	var public_readiness_valid: bool = public_before.status=="ready" if mode=="acknowledged" else public_before.status!="ready"
	add_result(label+"_real_source_owned_before_direct_successor",source_owned and public_readiness_valid,
		{"install":install,"accepted":accepted_before,"publicStatus":public_before.status,"publicReason":public_before.get("reason")})
	# The regression act is this public request alone. Source ownership, even
	# before server acknowledgement, must release A without a queued visit.
	var first_b: Dictionary = adapter.build_navmesh_tile_snapshot("1,0")
	var successor: Dictionary = direct_handoff_capture_facts(adapter)
	var successor_started: bool = first_b.get("reason")!="navigation_capture_slot_busy" \
		and first_b.get("publicationStatus") in ["pending","ready"] \
		and successor.id!=0 and successor.id!=primed.cursorId and successor.tileKey=="1,0" \
		and publisher.queued_navmesh_tile_keys.is_empty()
	add_result(label+"_direct_successor_claims_slot_without_queue_visit",successor_started,
		{"status":first_b.get("publicationStatus"),"reason":first_b.get("reason"),"capture":successor})
	first_b = {}
	var snapshot_b: Dictionary = await wait_for_navigation_capture(adapter,"1,0")
	var accepted_after: Dictionary = direct_handoff_accepted_facts(service,adapter,source_a)
	add_result(label+"_successor_seals_without_losing_predecessor_source",successor_started \
		and snapshot_b.get("publicationInput",{}).get("status")=="prepared" \
		and snapshot_b.get("sourceKey")==adapter.navmesh_tile_source_key_for_tile("1,0") \
		and accepted_after.sourceOwned and accepted_after.acceptedSerial==accepted_before.acceptedSerial \
		and accepted_after.surfaceCount==expected_surfaces and publisher.queued_navmesh_tile_keys.is_empty(),
		{"status":snapshot_b.get("publicationStatus"),"accepted":accepted_after})
	snapshot_b = {}
	publisher.world = null; publisher.main = null; publisher.navmesh_world = null
	# Explicit release is cleanup only, after every direct-request assertion.
	await close_entry_proof_fixture(adapter,world,label,service)
	await physics_frame
	var retired: Dictionary = service._publication_queue.stats()
	var retirement_thread: int = int(retired.get("worker",{}).get("lastRetirementThreadId",-1))
	add_result(label+"_retirement_releases_predecessor_and_maps",direct_handoff_capture_released(predecessor) \
		and retirement_thread>0 and retirement_thread!=OS.get_thread_caller_id() and navigation_map_ids()==baseline_maps,
		{"predecessorReleased":direct_handoff_capture_released(predecessor),"retirementThreadId":retirement_thread,
		"maps":navigation_map_ids(),"baselineMaps":baseline_maps})

func wait_for_installed_navigation(service) -> void:
	# Registration synchronization may finish after more than one physics frame.
	# Wait for actual region acknowledgements; assertions still reject missing data.
	for frame in 60:
		var pending := false
		for rid in service.region_rids_by_region.values():
			if NavigationServer3D.region_get_iteration_id(rid)<=0: pending=true
		if not pending: return
		await physics_frame

func navigation_map_ids() -> Array[String]:
	var ids: Array[String] = []
	var maps_value = NavigationServer3D.get_maps()
	if maps_value is Array:
		for map_value in maps_value:
			if map_value is RID:
				ids.append(str(map_value))
	ids.sort()
	return ids

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func failures() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func write_report() -> void:
	var report := {
		"runnerId": "navigation_shutdown_lifecycle_contract",
		"evidenceLevel": "service_contract",
		"passed": failures() == 0,
		"resultCount": results.size(),
		"failureCount": failures(),
		"results": results
	}
	var path := OS.get_environment("VOXEL_NAVIGATION_SHUTDOWN_REPORT").strip_edges()
	if path != "":
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
	print(JSON.stringify(report))
