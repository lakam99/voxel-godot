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

class SyntheticPublicationWorld extends RefCounted:
	var seed_text := "async-contract-seed-a"

class SyntheticPublicationOwner extends RefCounted:
	var main = SyntheticPublicationWorld.new()
	var source_key := "async-contract-source:1"
	func navmesh_tile_source_key_for_tile(_tile: String) -> String: return source_key

class SyntheticQueuedPublicationOwner extends SyntheticPublicationOwner:
	var captured := {}
	var capture_calls: Array[String] = []
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		capture_calls.append(key)
		if captured.has(key): return captured[key]
		var x := int(key.get_slice(",",0))*16
		return {"tileKey":key,"publicationStatus":"ready","sourceKey":source_key,
			"surfaces":[{"cell":Vector3i(x,0,0),"spanIndex":0,"worldPosition":Vector3(x*1.35,0,0)}]}

class PendingSourceFixture extends RefCounted:
	var ready := false
	func navmesh_tile_source_key_for_tile(_key: String) -> String: return "pending-source-contract:1"
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		if key=="0,0" and not ready:
			return {"tileKey":key,"publicationStatus":"pending","reason":"fixture_source_pending"}
		var x := int(key.get_slice(",",0))*16
		return {"tileKey":key,"publicationStatus":"ready","sourceKey":navmesh_tile_source_key_for_tile(key),
			"surfaces":[{"cell":Vector3i(x,0,0),"spanIndex":0,"worldPosition":Vector3(x*1.35,0,0)}]}

class RejectingInstallFixture extends NavmeshWorldServiceScript:
	var reject_install := true
	func register_tile_snapshot(snapshot: Dictionary) -> Dictionary:
		if reject_install: return {"status":"rejected","reason":"synthetic_install_rejection","installed":false}
		return super.register_tile_snapshot(snapshot)

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
	verify_publication_rectangle_clearance()
	await verify_finite_live_collision_bounds()
	await verify_pending_source_retention()
	await verify_navigation_worker_parity_and_ownership()
	await verify_async_navigation_service_lifecycle()
	await verify_owned_publication_queue_progress()
	await verify_async_navigation_orphaned_recapture()
	await verify_prepared_navigation_portal_filter_retirement()
	write_report()
	quit(0 if failures() == 0 else 1)

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
	func _registered_prop_node(object_id: String) -> Node3D:
		return fixture_props.get(object_id)

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
	var recovered: Dictionary=adapter.build_navmesh_tile_snapshot("0,0")
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
	var after_removal: Dictionary=adapter.build_navmesh_tile_snapshot("0,0")
	add_result("finite_bounds_failed_owner_removed_retry",after_removal.get("publicationStatus")=="ready"
		and adapter.collision_source_errors.is_empty() and adapter.cached_static_collision_records.is_empty(),{})
	adapter.main=null
	world.free()
	await process_frame


func verify_pending_source_retention() -> void:
	# Synthetic source producer with the real publication queue and service.
	# No actor movement or route acceptance is inferred.
	var producer := PendingSourceFixture.new()
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	var adapter := RoutePublicationAdapter.new()
	adapter.world = producer
	adapter.navmesh_world = service
	for key: String in ["0,0","1,0"]:
		adapter._enqueue_navmesh_tile_publish(key,producer.navmesh_tile_source_key_for_tile(key),true)
	var processed := adapter._process_queued_navmesh_tile_publishes(2)
	add_result("pending_source_retains_demand_without_empty_cache",adapter.queued_navmesh_tile_keys.has("0,0") and not adapter.empty_navmesh_tile_keys.has("0,0") and not adapter.published_navmesh_tile_keys.has("0,0"),{})
	add_result("pending_source_does_not_starve_ready_tile",processed==1 and adapter.published_navmesh_tile_keys.has("1,0"),{})
	var rejected: Dictionary = service.register_tile_snapshot(producer.build_navmesh_tile_snapshot("0,0"))
	add_result("pending_source_cannot_create_empty_installation",rejected.status=="pending" and not service.descriptors_by_region.has("region:chunk:0,0"),{})
	producer.ready = true
	await process_frame
	processed = adapter._process_queued_navmesh_tile_publishes(2)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var receipt := service.tile_publication_readiness("0,0",producer.navmesh_tile_source_key_for_tile("0,0"))
	add_result("pending_source_retry_installs_when_owner_ready",processed==1 and not adapter.queued_navmesh_tile_keys.has("0,0") and receipt.status=="ready",{"status":receipt.status,"reason":receipt.reason})
	service.clear()
	var rejecting_service := RejectingInstallFixture.new()
	rejecting_service.setup()
	adapter.navmesh_world = rejecting_service
	adapter._enqueue_navmesh_tile_publish("2,0",producer.navmesh_tile_source_key_for_tile("2,0"),true)
	await process_frame
	processed = adapter._process_queued_navmesh_tile_publishes(2)
	add_result("rejected_install_retains_demand_without_success_cache",processed==0 and adapter.queued_navmesh_tile_keys.has("2,0") and not adapter.empty_navmesh_tile_keys.has("2,0") and not adapter.published_navmesh_tile_keys.has("2,0"),{"processed":processed,"queued":adapter.queued_navmesh_tile_keys.has("2,0"),"published":adapter.published_navmesh_tile_keys.has("2,0")})
	rejecting_service.reject_install = false
	await process_frame
	processed = adapter._process_queued_navmesh_tile_publishes(2)
	rejecting_service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(rejecting_service)
	receipt = rejecting_service.tile_publication_readiness("2,0",producer.navmesh_tile_source_key_for_tile("2,0"))
	add_result("rejected_install_retries_through_real_service",processed==1 and receipt.status=="ready" and not adapter.queued_navmesh_tile_keys.has("2,0"),{"processed":processed,"status":receipt.status,"reason":receipt.reason})
	rejecting_service.clear()

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
	add_result("navigation_holder_rejects_wrong_binding",holder.take(wrong_binding)==null,{})
	var prepared = holder.take(binding)
	add_result("navigation_holder_exact_binding_is_one_shot",prepared!=null and holder.take(binding)==null,{})
	if prepared == null:
		worker.retire_external_payload(result)
		taken={}; result={}; holder=null
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
	var retirement := {"descriptor":prepared,"workerResult":result}
	var accepted := worker.retire_external_payload(retirement)
	add_result("navigation_worker_accepts_detached_descriptor_retirement",accepted,{})
	# Relinquish every strong prepared-output alias before retirement starts.
	prepared=null; geometry={}; retirement={}; holder=null; result={}; taken={}
	descriptor=null; expected_mesh=null; source={}; snapshot={}
	worker.request_shutdown()
	state = await wait_for_navigation_worker(worker,true)
	add_result("navigation_worker_shutdown_joins_and_retires_off_main",accepted and state.shutdownComplete and not state.busy and not state.workerRunning and not state.retirementPending and int(state.lastRetirementThreadId)>0 and int(state.lastRetirementThreadId)!=main_thread and prepared_weak.get_ref()==null,state)

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
		if result.get("installed",false) or result.get("status") in ["failed","rejected"]: break
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
	var owner := SyntheticQueuedPublicationOwner.new()
	var snapshot := async_navigation_snapshot(owner,1)
	owner.captured[snapshot.tileKey] = snapshot
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	service.register_tile_snapshot(snapshot)
	var held := await wait_for_service_prepared_without_upload(service,snapshot)
	var publisher := RoutePublicationAdapter.new()
	publisher.world = owner
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
	processed = publisher._process_queued_navmesh_tile_publishes(1,4000)
	add_result("owned_publication_missing_caller_retains_other_demand",state.status=="ready" and processed==0
		and owner.capture_calls.is_empty() and publisher.queued_navmesh_tile_keys==["1,0"],{})
	publisher._enqueue_navmesh_tile_publish(snapshot.tileKey,owner.source_key,false)
	processed = publisher._process_queued_navmesh_tile_publishes(1,4000,true)
	add_result("owned_publication_preserves_foreground_filter",processed==0 and owner.capture_calls.is_empty()
		and publisher.queued_navmesh_tile_keys.has(snapshot.tileKey) and publisher.queued_navmesh_tile_keys.has("1,0"),{})
	processed = publisher._process_queued_navmesh_tile_publishes(1,4000)
	var receipt := await async_navigation_receipt(service,snapshot)
	add_result("owned_publication_installs_ready_slot_before_unrelated_capture",processed==1
		and owner.capture_calls==[snapshot.tileKey] and receipt.status=="ready"
		and publisher.queued_navmesh_tile_keys==["1,0"] and service.active_publication_request().tileKey=="",receipt)
	await process_frame
	processed = publisher._process_queued_navmesh_tile_publishes(1,4000)
	add_result("owned_publication_releases_slot_to_retained_next_tile",processed==1
		and owner.capture_calls==[snapshot.tileKey,"1,0"] and publisher.queued_navmesh_tile_keys.is_empty(),{})
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
	for frame in range(60):
		if publisher.published_navmesh_tile_keys.get("2,0","")=="2,0|"+owner.source_key: break
		await process_frame
		publisher._process_queued_navmesh_tile_publishes(1,4000)
	add_result("synthetic_failed_owned_slot_reports_failure_and_retains_retry_without_starving_next",held.reason=="navigation_upload_pending"
		and failure_reported and publisher.queued_navmesh_tile_keys.has(snapshot.tileKey)
		and publisher.published_navmesh_tile_keys.get(snapshot.tileKey,"")!=snapshot.tileKey+"|"+owner.source_key
		and publisher.published_navmesh_tile_keys.get("2,0","")=="2,0|"+owner.source_key,{"failureReported":failure_reported})
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
