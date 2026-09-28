extends SceneTree
## Synthetic service fixtures with REAL NavigationServer regions and door links.
## No bake, NPC movement, legacy route query, main-world or headed acceptance.
## Autonomy processing is disabled: only its public lifecycle methods are tested.
const Nav = preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const Config = preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const Descriptor = preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const Autonomy = preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const Constants = preload("res://scripts/npc_ai/NpcConstants.gd")
const ChangeBus = preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const TARGET := "door:a"
const SIBLINGS := ["door:a:child", "door:ab", "other:door:a"]
const SOURCE_PATHS := [
	"res://scripts/npc_ai/navigation/NavmeshWorldService.gd",
	"res://scripts/npc_ai/NpcAutonomySystem.gd",
	"res://scripts/NpcSystem.gd",
	"res://scripts/npc_ai/interactions/SmartObjectService.gd",
	"res://scripts/npc_ai/interactions/DoorPortalService.gd",
	"res://scripts/npc_ai/interactions/DoorPortal.gd",
	"res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd",
	"res://scripts/npc_ai/navigation/NavigationChangeBus.gd",
	"res://scripts/npc_ai/NpcConstants.gd",
	"res://scripts/testing/buildings/DoorNavigationRetirementContract.gd"
]

var checks: Dictionary = {}
var details: Dictionary = {}

class SyntheticFailOnceNav extends "res://scripts/npc_ai/navigation/NavmeshWorldService.gd":
	var forget_calls: int = 0
	func forget_door_portal(portal_id: String) -> Dictionary:
		forget_calls += 1
		if forget_calls == 1: return {"status":"failed", "reason":"synthetic_once"}
		return super.forget_door_portal(portal_id)

func _initialize() -> void: call_deferred("run")

func check(label: String, passed: bool) -> void:
	checks[label] = passed
	if not passed: print("DOOR NAV RETIREMENT FAILURE ", label)

func sources() -> Dictionary:
	var result := {}
	for path: String in SOURCE_PATHS: result[path] = FileAccess.get_sha256(path)
	return result

func map_ids() -> Array:
	var result: Array = []
	for value: RID in NavigationServer3D.get_maps(): result.append(value.get_id())
	result.sort()
	return result

func server_ids(service, method: String) -> Array:
	var result: Array = []
	for value: RID in NavigationServer3D.call(method, service.navigation_map): result.append(value.get_id())
	result.sort()
	return result

func sync(service) -> void:
	service.sync_navigation_map_if_dirty()
	await physics_frame
	await process_frame

func descriptor(region: String, x: float, portals: Array):
	# Same separated two-surface/link construction as the established NPC
	# door-link service fixture; no raster/native bake or overlap workaround.
	var result = Descriptor.create(region, region, AABB(Vector3(x - 1.5, -0.1, -1.5), Vector3(3, 1.2, 5.7)))
	result.add_walkable_surface(region + ":left", Vector3(x, 0, 0), Vector3(1.35, 0.05, 1.35))
	result.add_walkable_surface(region + ":right", Vector3(x, 0, 2.7), Vector3(1.35, 0.05, 1.35))
	result.add_blocker(region + ":blocker", AABB(Vector3(x + 1, 0, 4), Vector3(0.2, 1, 0.2)))
	result.add_semantic_anchor(region + ":anchor", "work", Vector3(x, 0, 0))
	for id: String in portals:
		result.add_door_portal(id, Vector3(x, 0, 0.65), Vector3(x, 0, 2.05), {"state":"closed", "openable":true})
		result.add_door_link(region + ":left", region + ":right", id, {"cost":1.0, "actionId":"open"})
	return result

func fixture() -> Dictionary:
	var service = Nav.new()
	service.setup(Config.from_value("navmesh", "door-retirement-contract"))
	var a = descriptor("door-retirement-region-a", 0, [TARGET, SIBLINGS[0], SIBLINGS[1]])
	var b = descriptor("door-retirement-region-b", 10, [TARGET, SIBLINGS[2]])
	check("fixture_region_a_installed", service.register_chunk_descriptor(a).installed)
	check("fixture_region_b_installed", service.register_chunk_descriptor(b).installed)
	return {"service":service, "a":a, "b":b}

func region_facts(service) -> Dictionary:
	var result := {}
	for id: String in service.descriptors_by_region:
		var value = service.descriptors_by_region[id]
		result[id] = {"rid":service.region_rids_by_region[id].get_id(),
			"bounds":value.bounds, "surfaces":value.walkable_surfaces.duplicate(true),
			"blockers":value.blockers.duplicate(true), "anchors":value.semantic_anchors.duplicate(true),
			"state":service.region_states[id]}
	return result

func link_ids(service, id: String) -> Array:
	var result: Array = []
	for record: Dictionary in service.door_link_records_by_portal.get(id, []):
		var rid: RID = record.get("rid", RID())
		result.append(rid.get_id())
	result.sort()
	return result

func sibling_facts(service) -> Dictionary:
	var result := {}
	for id: String in SIBLINGS:
		result[id] = {"records":service.door_link_records_by_portal.get(id, []).duplicate(true),
			"state":service.door_portal_states.get(id, {}).duplicate(true)}
	return result

func seed_marker(service, id: String) -> WeakRef:
	# This marker has no external strong owner after this call. Losing all state
	# references is checked separately from server-link membership.
	var marker := RefCounted.new()
	var reference: WeakRef = weakref(marker)
	service.set_door_portal_state(id, "open", {"marker":marker, "locked":false})
	return reference

func no_target_records(service, id: String) -> bool:
	if service.door_portal_states.has(id) or service.door_link_records_by_portal.has(id): return false
	for records: Array in service.door_link_records_by_region.values():
		for record: Dictionary in records:
			if record.get("portalId") == id: return false
	return true

func close_nav(service, baseline: Array, label: String) -> void:
	service.clear()
	await physics_frame
	await process_frame
	check(label + "_map_released", map_ids() == baseline)
	check(label + "_rid_records_empty", service.region_rids_by_region.is_empty() and service.door_link_records_by_region.is_empty() and service.door_link_records_by_portal.is_empty())

func exact_removal_case() -> void:
	var baseline := map_ids()
	var c := fixture()
	var service = c.service
	for id: String in SIBLINGS: service.set_door_portal_state(id, "closed", {"openable":true, "marker":id})
	var reference := seed_marker(service, TARGET)
	await sync(service)
	var regions := region_facts(service)
	var server_regions := server_ids(service, "map_get_regions")
	var siblings := sibling_facts(service)
	var original_links := server_ids(service, "map_get_links")
	var removed_links := link_ids(service, TARGET)
	var original_topology: int = service.topology_revision
	var before_a: Dictionary = c.a.to_summary()
	var before_b: Dictionary = c.b.to_summary()
	check("exact_real_links_before", original_links.size() == 5 and removed_links.size() == 2 and reference.get_ref() != null)
	var receipt: Dictionary = service.call("forget_door_portal", TARGET)
	details.exactReceipt = receipt
	check("exact_receipt", receipt.get("status") == "forgotten" and receipt.get("portalId") == TARGET and receipt.get("removedLinks") == 2 and receipt.get("stateRemoved") == true)
	check("exact_regions_reported", receipt.get("affectedRegions") == ["door-retirement-region-a", "door-retirement-region-b"])
	check("exact_indexes_cleared", no_target_records(service, TARGET))
	check("exact_state_reference_released", reference.get_ref() == null)
	check("exact_prefix_siblings_unchanged", siblings == sibling_facts(service))
	check("exact_region_geometry_unchanged", regions == region_facts(service) and service.topology_revision == original_topology)
	check("exact_input_descriptors_unchanged", before_a == c.a.to_summary() and before_b == c.b.to_summary())
	await sync(service)
	var expected: Array = original_links.duplicate()
	for id: int in removed_links: expected.erase(id)
	check("exact_server_links_removed_only", server_ids(service, "map_get_links") == expected)
	check("exact_server_regions_unchanged", server_ids(service, "map_get_regions") == server_regions)
	check("exact_installed_link_count", service.installed_door_link_count == 3)
	var revision: int = service.dynamic_revision
	var again: Dictionary = service.call("forget_door_portal", TARGET)
	check("exact_repeat_absent", again.get("status") == "absent" and again.get("removedLinks") == 0 and service.dynamic_revision == revision)
	check("exact_empty_rejected", service.call("forget_door_portal", "").get("status") == "rejected")
	check("exact_no_route_query", service.path_query_count == 0)
	check("exact_retained_descriptors_filtered", service.descriptors_by_region[c.a.region_id].door_links.size() == 2 and service.descriptors_by_region[c.b.region_id].door_links.size() == 1 and not service._door_descriptor_regions_by_portal.has(TARGET))
	check("exact_descriptor_geometry_identity", is_same(service.descriptors_by_region[c.a.region_id].walkable_surfaces, c.a.walkable_surfaces) and is_same(service.descriptors_by_region[c.a.region_id].blockers, c.a.blockers))
	# Explicit dirty-queue fixture; exercise the ordinary retained-descriptor
	# rebuild path rather than installing an externally stale descriptor.
	for id: String in service.descriptors_by_region:
		service.dirty_regions_by_region[id] = {"reason":"synthetic_rebuild_after_forget"}
		service.dirty_region_queue.append(id)
	var rebuilt: Array = service.process_dirty_regions(2, 0)
	await sync(service)
	check("exact_dirty_rebuild_no_resurrection", rebuilt.size() == 2 and no_target_records(service, TARGET) and server_ids(service, "map_get_links").size() == 3)
	# Same-ID source genuinely returning is allowed, using the original source
	# descriptor as the fixture's explicit re-entry submission.
	check("exact_reentry_installed", service.register_chunk_descriptor(c.a).installed)
	await sync(service)
	check("exact_reentry_links_restored", link_ids(service, TARGET).size() == 1 and server_ids(service, "map_get_links").size() == 4)
	await close_nav(service, baseline, "exact")

func sparse_case(mode: String) -> void:
	var baseline := map_ids()
	var service = Nav.new()
	service.setup(Config.default_config())
	var reference: WeakRef
	if mode == "state_only": reference = seed_marker(service, TARGET)
	else:
		var value = descriptor("sparse-region", 0, [TARGET])
		check(mode + "_installed", service.register_chunk_descriptor(value).installed)
		if mode == "region_index_only": service.door_link_records_by_portal.erase(TARGET)
		if mode == "portal_index_only": service.door_link_records_by_region.erase("sparse-region")
		if mode == "duplicate_record":
			# Explicit corruption fixture: two references to one real RID. Cleanup
			# must not double-free it or decrement the installed count twice.
			service.door_link_records_by_portal[TARGET].append(service.door_link_records_by_portal[TARGET][0])
	await sync(service)
	var receipt: Dictionary = service.call("forget_door_portal", TARGET)
	var expected := 0 if mode == "state_only" else 1
	check(mode + "_receipt", receipt.get("status") == "forgotten" and receipt.get("removedLinks") == expected)
	check(mode + "_no_retained_records", no_target_records(service, TARGET))
	if reference != null: check(mode + "_marker_released", reference.get_ref() == null)
	await sync(service)
	check(mode + "_server_links_empty", server_ids(service, "map_get_links").is_empty() and service.installed_door_link_count == 0)
	await close_nav(service, baseline, mode)

func autonomy_fixture():
	var owner = Autonomy.new()
	owner.navigation_backend_config = Config.from_value("navmesh", "door-retirement-contract")
	owner.navmesh_world.setup(owner.navigation_backend_config)
	root.add_child(owner)
	owner.set_physics_process(false)
	# Real services constructed by autonomy; no actors or Main world. Wire only
	# the normal shared door owners used by the public lifecycle API under test.
	owner.door_portals.setup(null, owner)
	owner.smart_objects.setup(owner, owner.door_portals)
	owner.door_traversal.setup(owner.door_portals, owner.traffic_reservations, owner.bottleneck_classifier, owner.traffic_priority_policy, owner.wait_for_graph)
	return owner

func door(owner: Node, id: String, x: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = Vector3(x, 0, 0)
	body.set_meta("door_portal_id", id)
	body.set_meta("door_group_id", id)
	body.set_meta("door_public_access", true)
	var collider := CollisionShape3D.new()
	collider.shape = BoxShape3D.new()
	body.add_child(collider)
	owner.add_child(body)
	return body

func close_autonomy(owner, baseline: Array, label: String) -> void:
	owner.smart_objects.clear()
	owner.shutdown_for_process_exit()
	owner.free()
	await physics_frame
	await process_frame
	check(label + "_maps_released", map_ids() == baseline)

func autonomy_door_case() -> void:
	var baseline := map_ids()
	var owner = autonomy_fixture()
	check("autonomy_real_navmesh_backend", owner.navigation_backend_config.use_navmesh() and owner.navmesh_world.navigation_map.is_valid())
	check("autonomy_door_api_present", owner.has_method("notify_door_unregistered"))
	if not owner.has_method("notify_door_unregistered"):
		await close_autonomy(owner, baseline, "autonomy_missing")
		return
	var a := door(owner, TARGET, 0)
	var b := door(owner, TARGET, 1.35)
	check("autonomy_register_a", owner.register_door(a) == TARGET)
	check("autonomy_register_b", owner.register_door(b) == TARGET)
	var value = descriptor("autonomy-region", 0, [TARGET, SIBLINGS[0]])
	check("autonomy_nav_installed", owner.navmesh_world.register_chunk_descriptor(value).installed)
	await sync(owner.navmesh_world)
	var target_links := link_ids(owner.navmesh_world, TARGET)
	var sibling_links := link_ids(owner.navmesh_world, SIBLINGS[0])
	var first: Dictionary = owner.call("notify_door_unregistered", b)
	details.autonomySurvivorReceipt = first
	check("autonomy_survivor_receipt", first.get("status") == "unregistered" and first.get("portalRemoved") == false)
	check("autonomy_survivor_representative", owner.smart_objects.registrations[TARGET].node == a)
	check("autonomy_survivor_nav_node", owner.navmesh_world.door_portal_states.get(TARGET, {}).get("door") == a)
	check("autonomy_survivor_links_preserved", link_ids(owner.navmesh_world, TARGET) == target_links)
	check("autonomy_removed_leaf_intact", b.is_inside_tree() and b.get_child_count() == 1 and not b.get_meta("destroyed", false))
	b.free()
	var last: Dictionary = owner.call("notify_door_unregistered", a)
	details.autonomyFinalReceipt = last
	check("autonomy_last_receipt", last.get("status") == "unregistered" and last.get("portalRemoved") == true)
	check("autonomy_last_navigation_receipt", last.get("navigationRetirement", {}).get("status") == "forgotten" and last.get("navigationRetirement", {}).get("removedLinks") == 1)
	check("autonomy_last_all_registrations_gone", not owner.smart_objects.registrations.has(TARGET) and not owner.door_portals.portals.has(TARGET) and no_target_records(owner.navmesh_world, TARGET))
	check("autonomy_last_node_not_destroyed", a.is_inside_tree() and a.get_child_count() == 1 and not a.get_meta("destroyed", false))
	await sync(owner.navmesh_world)
	check("autonomy_exact_server_survivor", server_ids(owner.navmesh_world, "map_get_links") == sibling_links)
	a.free()
	check("autonomy_no_route_query", owner.navmesh_world.path_query_count == 0)
	await close_autonomy(owner, baseline, "autonomy")

func prop(owner: Node, id: String, x: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = Vector3(x, 0, 0)
	body.set_meta("kind", "prop")
	body.set_meta("prop_id", id)
	body.set_meta("material", "tree")
	body.set_meta("drop", "logs")
	body.set_meta("drop_count", 3)
	owner.add_child(body)
	return body

func prop_case(depleted: bool) -> void:
	var label := "prop_depleted" if depleted else "prop_available"
	var baseline := map_ids()
	var owner = autonomy_fixture()
	check(label + "_api_present", owner.has_method("notify_prop_unloaded"))
	if not owner.has_method("notify_prop_unloaded"):
		await close_autonomy(owner, baseline, label)
		return
	var id := "streamed-tree"
	var object_id := "prop:" + id
	var old := prop(owner, id, 0)
	owner.notify_prop_created(id, old)
	var registration = owner.smart_objects.registrations[object_id]
	if depleted:
		# Explicit preexisting durable-state fixture, not a harvest simulation.
		owner.smart_objects.mark_registration_removed(registration, "synthetic_preexisting_depletion")
	owner.change_bus.flush_frame()
	var revision_before: int = owner.change_bus.monotonic_revision
	var expected_bounds := AABB(old.global_position - Vector3.ONE * Constants.CELL_SIZE * 0.5, Vector3.ONE * Constants.CELL_SIZE)
	var receipt: Dictionary = owner.call("notify_prop_unloaded", id, old)
	details[label] = receipt
	check(label + "_receipt", receipt.get("status") == ("absent" if depleted else "unregistered") and receipt.get("objectId") == object_id)
	check(label + "_not_destroyed", old.is_inside_tree() and not old.get_meta("destroyed", false))
	check(label + "_depletion_preserved", registration.depleted == depleted)
	check(label + "_unbound", registration.node == null and registration.metadata.get("stale", false))
	check(label + "_no_event_before_exit", owner.change_bus.pending_count() == 0 and owner.change_bus.monotonic_revision == revision_before)
	var repeated: Dictionary = owner.call("notify_prop_unloaded", id, old)
	check(label + "_repeat_absent", repeated.get("status") == "absent")
	old.free()
	check(label + "_exactly_one_exit_event", owner.change_bus.monotonic_revision == revision_before + 1)
	var events: Array = owner.change_bus.flush_frame()
	var expected_tiles: Array = ChangeBus.tile_keys_for_bounds(expected_bounds)
	var actual_tiles: Array = []
	var events_exact := not events.is_empty()
	for event: Dictionary in events:
		actual_tiles.append(event.tileKey)
		events_exact = events_exact and event.bounds == expected_bounds and event.changeKinds == ["prop_removed"] and event.objectIds == [object_id] and event.coalescedCount == 1
	actual_tiles.sort()
	check(label + "_exit_bounds_and_identity", events_exact and actual_tiles == expected_tiles)
	var fresh := prop(owner, id, 0)
	owner.notify_prop_created(id, fresh)
	var current = owner.smart_objects.registrations[object_id]
	check(label + "_same_registration", is_same(current, registration))
	check(label + "_fresh_node_bound", current.node == fresh and not current.metadata.get("stale", false))
	check(label + "_depletion_after_reentry", current.depleted == depleted)
	check(label + "_availability_after_reentry", owner.smart_objects.registration_is_live(current) == (not depleted))
	var availability: Dictionary = owner.smart_objects.object_available(object_id)
	check(label + "_public_availability", availability.get("ok") == (not depleted) and availability.get("reason") == ("resource_depleted" if depleted else "available"))
	await close_autonomy(owner, baseline, label)

func stale_prop_case() -> void:
	var baseline := map_ids()
	var owner = autonomy_fixture()
	if not owner.has_method("notify_prop_unloaded"):
		check("stale_prop_api_present", false)
		await close_autonomy(owner, baseline, "stale_prop")
		return
	var old := prop(owner, "same-id", 0)
	owner.notify_prop_created("same-id", old)
	var fresh := prop(owner, "same-id", 1)
	owner.notify_prop_created("same-id", fresh)
	var registration = owner.smart_objects.registrations["prop:same-id"]
	var before: Dictionary = owner.change_bus.pending_by_tile.duplicate(true)
	var revision: int = owner.change_bus.monotonic_revision
	var receipt: Dictionary = owner.call("notify_prop_unloaded", "same-id", old)
	details.stalePropReceipt = receipt
	check("stale_prop_receipt", receipt.get("status") == "failed" and receipt.get("reason") == "object_binding_mismatch")
	check("stale_prop_replacement_preserved", registration.node == fresh and owner.smart_objects.registration_is_live(registration) and not registration.depleted)
	check("stale_prop_no_nav_removal", owner.change_bus.monotonic_revision == revision and before == owner.change_bus.pending_by_tile)
	old.free()
	check("stale_prop_old_exit_isolated", registration.node == fresh and owner.smart_objects.registration_is_live(registration))
	await close_autonomy(owner, baseline, "stale_prop")

func deferred_prop_exit_case(reset_registry: bool) -> void:
	var label := "prop_exit_reset" if reset_registry else "prop_exit_replacement"
	var baseline := map_ids()
	var owner = autonomy_fixture()
	var old := prop(owner, "pending-exit", 0)
	owner.notify_prop_created("pending-exit", old)
	var receipt: Dictionary = owner.notify_prop_unloaded("pending-exit", old)
	check(label + "_unregistered", receipt.get("status") == "unregistered" and owner._pending_prop_unloads.has(old.get_instance_id()))
	# Keep the old real registry alive explicitly in the reset fixture: identity,
	# not merely expiration of the WeakRef, must isolate the new registry.
	var old_registry = owner.smart_objects
	if reset_registry: owner.clear()
	var fresh := prop(owner, "pending-exit", 2)
	owner.notify_prop_created("pending-exit", fresh)
	owner.change_bus.flush_frame()
	var revision: int = owner.change_bus.monotonic_revision
	old.free()
	check(label + "_no_old_exit_event", owner.change_bus.pending_count() == 0 and owner.change_bus.monotonic_revision == revision)
	var registration = owner.smart_objects.registrations["prop:pending-exit"]
	check(label + "_fresh_registration_live", registration.node == fresh and owner.smart_objects.registration_is_live(registration) and not registration.depleted)
	if reset_registry:
		check(label + "_registry_replaced", not is_same(old_registry, owner.smart_objects))
		old_registry.clear()
	old_registry = null
	await close_autonomy(owner, baseline, label)

func synthetic_door_retry_case(replace: bool) -> void:
	var label := "synthetic_door_retry_replaced" if replace else "synthetic_door_retry"
	var baseline := map_ids()
	var owner = autonomy_fixture()
	owner.navmesh_world.clear()
	var nav := SyntheticFailOnceNav.new()
	nav.setup(owner.navigation_backend_config)
	owner.navmesh_world = nav
	var old := door(owner, TARGET, 0)
	check(label + "_registered", owner.register_door(old) == TARGET)
	check(label + "_installed", nav.register_chunk_descriptor(descriptor("retry-region", 0, [TARGET])).installed)
	await sync(nav)
	var revision: int = owner.change_bus.monotonic_revision
	var first: Dictionary = owner.notify_door_unregistered(old)
	check(label + "_pending_not_acknowledged", first.get("status") == "pending_budget" and nav.forget_calls == 1)
	check(label + "_intact_and_retained", old.is_inside_tree() and old.get_child_count() == 1 and nav.door_portal_states.has(TARGET) and link_ids(nav, TARGET).size() == 1)
	check(label + "_no_early_invalidation", owner.change_bus.monotonic_revision == revision)
	if replace:
		var fresh := door(owner, TARGET, 2)
		check(label + "_replacement_registered", owner.register_door(fresh) == TARGET)
		var retry: Dictionary = owner.notify_door_unregistered(old)
		check(label + "_old_retry_rejected", retry.get("status") == "failed" and retry.get("reason") == "door_retirement_portal_replaced" and nav.forget_calls == 1)
		check(label + "_replacement_preserved", owner.smart_objects.registrations[TARGET].node == fresh and nav.door_portal_states[TARGET].door == fresh and link_ids(nav, TARGET).size() == 1)
	else:
		var retry: Dictionary = owner.notify_door_unregistered(old)
		check(label + "_retry_acknowledged", retry.get("status") == "unregistered" and retry.get("navigationRetirement", {}).get("status") == "forgotten" and nav.forget_calls == 2)
		check(label + "_no_target", no_target_records(nav, TARGET))
		await sync(nav)
		check(label + "_server_link_released", server_ids(nav, "map_get_links").is_empty())
	# Failed replacement fixture is explicitly closed by whole-owner shutdown,
	# not declared a successful old-door retirement.
	await close_autonomy(owner, baseline, label)

func run() -> void:
	var output := OS.get_environment("DOOR_NAVIGATION_RETIREMENT_OUTPUT")
	if output.is_empty(): quit(2); return
	var started := Time.get_ticks_usec()
	var source_before := sources()
	var probe = Nav.new()
	check("forget_api_present", probe.has_method("forget_door_portal"))
	check("server_observation_api_present", NavigationServer3D.has_method("map_get_links") and NavigationServer3D.has_method("map_get_regions"))
	probe = null
	if checks.forget_api_present and checks.server_observation_api_present:
		await exact_removal_case()
		for mode: String in ["state_only", "links_only", "region_index_only", "portal_index_only", "duplicate_record"]: await sparse_case(mode)
		await autonomy_door_case()
		await prop_case(false)
		await prop_case(true)
		await stale_prop_case()
		await deferred_prop_exit_case(false)
		await deferred_prop_exit_case(true)
		await synthetic_door_retry_case(false)
		await synthetic_door_retry_case(true)
	check("source_files_unchanged", source_before == sources())
	var failures: Array = []
	for label: String in checks:
		if not checks[label]: failures.append(label)
	var report := {"passed":failures.is_empty(), "checkCount":checks.size(), "failureCount":failures.size(),
		"checks":checks, "failures":failures, "details":details, "sourceSha256":source_before,
		"elapsedUsec":Time.get_ticks_usec() - started,
		"evidenceLevel":"headless real NavigationServer/shared-service lifecycle with synthetic descriptors; no route/gameplay acceptance",
		"limits":["No query on freed RIDs; release observations use synchronized map link membership and service indexes.",
			"Region identity and descriptor geometry preserved; no raster bake or NPC movement.",
			"Dirty rebuild uses filtered retained descriptors; external stale descriptor submission is not distinguished from legitimate re-entry.",
			"Two retry controls explicitly substitute a fail-once Nav subclass; all other server and autonomy fixtures use real services.",
			"Prop depletion is explicit initial fixture state; no harvesting, rewards or save acceptance."]}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "\t")); file.close()
	print("DOOR NAV RETIREMENT checks=", checks.size(), " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
