extends SceneTree

const ProviderScript := preload("res://scripts/world/OrdinaryStructureStaticSectionProvider.gd")
const Adapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const SourceRosterScript := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")

class FixtureMain extends Node:
	var CELL := 1.35
	var TOWN_REGION_CELLS := 64
	var STRUCTURE_REGION_CELLS := 128
	var STRUCTURE_SPAWN_CHANCE := 0.0
	var seed_text := "ordinary-static-provider-contract"
	var town_region_cache: Dictionary = {}
	var blocks: Dictionary = {}


class FixtureStructure extends RefCounted:
	var main: Object
	var ordinary_visual_sources: Dictionary = {}
	var removed_generated_structure_blocks: Dictionary = {}
	var ordinary_visual_revision := 1
	var regional_source_generation := 1
	var regional_source_revision := 1
	var generated_structures: Dictionary = {}

	func region_dependency_scheduling_revision(bounds: Rect2i) -> Array:
		return [ordinary_visual_revision, regional_source_generation,
			regional_source_revision, bounds]

	func _regional_town_bounds(town: Dictionary) -> Rect2i:
		return Rect2i(Vector2i(int(town.get("x", 0)), int(town.get("z", 0))),
			Vector2i(int(town.get("width", 16)), int(town.get("depth", 16))))

	func town_key_for(town: Dictionary) -> String:
		return String(town.get("key", "0,0"))

	func _ordinary_visual_block_key(source_id: String, cell: Vector3i,
			block_type: String) -> String:
		return "%s|%d,%d,%d|%s" % [source_id, cell.x, cell.y, cell.z, block_type]

	func _ordinary_visible_renderable(root_node: Node) -> Node3D:
		if root_node is MeshInstance3D and (root_node as MeshInstance3D).mesh != null:
			return root_node as Node3D
		for child_value: Variant in root_node.get_children():
			if child_value is Node:
				var found := _ordinary_visible_renderable(child_value)
				if found != null: return found
		return null


var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var world := FixtureMain.new()
	root.add_child(world)
	for z in range(-2, 2):
		for x in range(-2, 2):
			world.town_region_cache[Vector2i(x, z)] = {}
	world.town_region_cache[Vector2i.ZERO] = {
		"key":"0,0", "x":-4, "z":-4, "width":24, "depth":24}
	var system := FixtureStructure.new()
	system.main = world
	var source_id := "town:0,0"
	var cell := Vector3i(2, 0, 3)
	var body := _make_body(source_id, cell, "stoneBlock")
	body.position = Vector3(cell) * world.CELL
	world.add_child(body)
	world.blocks[cell] = body
	system.ordinary_visual_sources[source_id] = {
		"completed":true, "expected":{cell:"stoneBlock"},
		"omitted":{}, "failed":{}, "revision":2}
	var provider := ProviderScript.new()
	var configured: Dictionary = provider.configure("seed:ordinary-provider", system, world)
	check("provider_binds_to_structure_and_world_authorities", configured.get("status") == "ready", configured)
	var first := _capture_until_settled(provider, "seed:ordinary-provider", Vector3i.ZERO)
	var section_row: Dictionary = first.get("sections", {}).get(Vector3i.ZERO, {})
	var prepared: Dictionary = first.get("preparedSections", {}).get(Vector3i.ZERO, {})
	check("section_census_is_complete_and_geometry_is_bound_to_source_revision",
		first.get("status") == "complete" and section_row.get("status") == "complete"
		and section_row.get("sourcePartIds", []).size() == 1
		and prepared.get("inputs", []).size() == 1
		and prepared.get("declarations", []).size() == 1
		and prepared.get("preparedSegments", []).size() == 1
		and prepared.get("resourceBindings", {}).size() == 1,
		{"status":first.get("status", ""), "reason":first.get("reason", ""),
			"memberIds":section_row.get("sourcePartIds", []),
			"inputCount":prepared.get("inputs", []).size()})
	var member_id := String(section_row.get("sourcePartIds", [""])[0]) \
		if not section_row.get("sourcePartIds", []).is_empty() else ""
	var expected_part_id := "ordinary:%s:cell:%d,%d,%d" % [source_id, cell.x, cell.y, cell.z]
	check("stable_member_id_and_readonly_20_float_input",
		member_id == expected_part_id and prepared.get("inputs", []).size() == 1
		and prepared.inputs[0].is_read_only() and prepared.inputs[0].buffer.is_read_only()
		and prepared.inputs[0].buffer.size() == 20,
		{"memberId":member_id, "expected":expected_part_id})
	var roster := SourceRosterScript.new()
	var roster_bound: Dictionary = roster.bind_world("seed:ordinary-provider", [ProviderScript.PROVIDER_ID])
	var registered: Dictionary = roster.register_provider(ProviderScript.PROVIDER_ID,
		provider, "capture_static_section_sources")
	var roster_result: Dictionary = roster.capture_sections([Vector3i.ZERO])
	check("provider_satisfies_exact_static_section_roster_contract",
		roster_bound.get("status") == "ready" and registered.get("status") == "ready"
		and roster_result.get("status") == "complete"
		and roster_result.expectedContributorsBySection.get(Vector3i.ZERO, []).has(member_id),
		roster_result)
	var first_coverage := String(section_row.get("coverageRevision", ""))
	var acknowledged: Dictionary = provider.acknowledge_section_install(Vector3i.ZERO, first_coverage)
	check("membership_baseline_advances_only_on_explicit_install_ack",
		acknowledged.get("status") == "acknowledged"
		and int(acknowledged.get("memberCount", 0)) == 1,
		acknowledged)
	var boundary_cell := Vector3i(16, 0, 3)
	var boundary_body := _make_body(source_id, boundary_cell, "stoneBlock")
	boundary_body.position = Vector3(boundary_cell) * world.CELL
	world.add_child(boundary_body)
	world.blocks[boundary_cell] = boundary_body
	system.ordinary_visual_sources[source_id].expected[boundary_cell] = "stoneBlock"
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var boundary_sections := _capture_sections_until_settled(provider,
		"seed:ordinary-provider", [Vector3i.ZERO, Vector3i(1, 0, 0)])
	var west_row: Dictionary = boundary_sections.get("sections", {}).get(Vector3i.ZERO, {})
	var east_row: Dictionary = boundary_sections.get("sections", {}).get(Vector3i(1, 0, 0), {})
	var boundary_part_id := "ordinary:%s:cell:%d,%d,%d" % [source_id,
		boundary_cell.x, boundary_cell.y, boundary_cell.z]
	var boundary_mesh := boundary_body.get_child(0) as MeshInstance3D
	var west_bounds := AABB(Vector3.ZERO, Vector3.ONE * Grid.SECTION_SIZE_METERS)
	var boundary_world_bounds: AABB = boundary_mesh.global_transform * boundary_mesh.mesh.get_aabb()
	var boundary_overlaps_west := boundary_world_bounds.intersects(west_bounds)
	var west_members: Array = west_row.get("sourcePartIds", [])
	var east_members: Array = east_row.get("sourcePartIds", [])
	check("boundary_spanning_geometry_has_one_center_owned_section_member",
		boundary_sections.get("status") == "complete" and boundary_overlaps_west
		and not west_members.has(boundary_part_id) and east_members.has(boundary_part_id),
		{"status":boundary_sections.get("status", ""),
			"overlapsWestSection":boundary_overlaps_west,
			"westMembers":west_members, "eastMembers":east_members})
	var boundary_ack := provider.acknowledge_section_install(Vector3i(1, 0, 0),
		String(east_row.get("coverageRevision", "")))
	var boundary_removed_key := system._ordinary_visual_block_key(source_id,
		boundary_cell, "stoneBlock")
	system.removed_generated_structure_blocks[boundary_removed_key] = true
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var boundary_removal := _capture_sections_until_settled(provider,
		"seed:ordinary-provider", [Vector3i.ZERO, Vector3i(1, 0, 0)])
	var west_tombstones: Array = boundary_removal.get("removalsBySection", {}).get(Vector3i.ZERO, [])
	var east_tombstones: Array = boundary_removal.get("removalsBySection", {}).get(Vector3i(1, 0, 0), [])
	check("single_center_owned_boundary_source_removes_in_its_one_section_only",
		boundary_ack.get("status") == "acknowledged"
		and boundary_removal.get("status") == "complete"
		and west_tombstones.is_empty() and east_tombstones.size() == 1
		and String(east_tombstones[0].get("sourceId", "")) == boundary_part_id
		and String(east_tombstones[0].get("sourcePartId", "")) == boundary_part_id
		and String(east_tombstones[0].get("authoritySourceId", "")) == source_id,
		{"westTombstones":west_tombstones, "eastTombstones":east_tombstones})
	var boundary_empty_row: Dictionary = boundary_removal.get("sections", {}).get(Vector3i(1, 0, 0), {})
	provider.acknowledge_section_install(Vector3i(1, 0, 0),
		String(boundary_empty_row.get("coverageRevision", "")))
	var mesh_instance := body.get_child(0) as MeshInstance3D
	mesh_instance.position.x = world.CELL * 1.1
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var excessive_support := _capture_until_settled(provider, "seed:ordinary-provider", Vector3i.ZERO)
	check("visual_extending_beyond_discovery_margin_keeps_section_pending",
		excessive_support.get("status") == "pending"
		and String(excessive_support.get("reason", "")) == "ordinary_geometry_horizontal_support_exceeds_section_query",
		excessive_support)
	mesh_instance.position.x = 0.0
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var restored := _capture_until_settled(provider, "seed:ordinary-provider", Vector3i.ZERO)
	check("restored_in_bounds_visual_can_be_recaptured",
		restored.get("status") == "complete", restored)
	var collider := CollisionShape3D.new()
	collider.shape = BoxShape3D.new()
	body.add_child(collider)
	check("capturing_static_visual_keeps_live_collision_and_body_authority",
		body.get_parent() == world and collider.get_parent() == body
		and world.blocks.get(cell) == body,
		{"bodyLive":body.get_parent() == world, "colliderLive":collider.get_parent() == body})

	var unsupported_cell := Vector3i(3, 0, 3)
	var chest := _make_body(source_id, unsupported_cell, "chest")
	chest.position = Vector3(unsupported_cell) * world.CELL
	world.add_child(chest)
	world.blocks[unsupported_cell] = chest
	system.ordinary_visual_sources[source_id].expected[unsupported_cell] = "chest"
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var unsupported: Dictionary = _capture_until_pending(provider, "seed:ordinary-provider", Vector3i.ZERO)
	check("unsupported_interactive_member_prevents_false_complete_section",
		unsupported.get("status") == "pending"
		and String(unsupported.get("reason", "")) == "ordinary_geometry_block_type_not_migrated",
		unsupported)

	var removed_key := system._ordinary_visual_block_key(source_id, cell, "stoneBlock")
	system.removed_generated_structure_blocks[removed_key] = true
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var after_remove := _capture_until_pending(provider, "seed:ordinary-provider", Vector3i.ZERO)
	check("durable_removal_emits_retryable_section_tombstone",
		after_remove.get("status") == "pending"
		and String(after_remove.get("reason", "")) == "ordinary_geometry_block_type_not_migrated",
		after_remove)
	# The unsupported chest remains a current census member; remove it as well to
	# expose an explicit empty replacement and the prior installed stone tombstone.
	var chest_key := system._ordinary_visual_block_key(source_id, unsupported_cell, "chest")
	system.removed_generated_structure_blocks[chest_key] = true
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var empty_after_remove := _capture_until_settled(provider, "seed:ordinary-provider", Vector3i.ZERO)
	var empty_row: Dictionary = empty_after_remove.get("sections", {}).get(Vector3i.ZERO, {})
	var tombstones: Array = empty_after_remove.get("removalsBySection", {}).get(Vector3i.ZERO, [])
	check("all_removed_generated_members_produce_explicit_empty_and_revisioned_tombstones",
		empty_after_remove.get("status") == "complete" and empty_row.get("status") == "empty"
		and tombstones.size() == 1 and String(tombstones[0].get("sourcePartId", "")) == member_id
		and String(tombstones[0].get("sourceId", "")) == member_id
		and String(tombstones[0].get("authoritySourceId", "")) == source_id
		and String(tombstones[0].get("sourceRevision", "")).length() == 64,
		{"status":empty_after_remove.get("status", ""), "row":empty_row, "tombstones":tombstones})
	var ack_empty := provider.acknowledge_section_install(Vector3i.ZERO,
		String(empty_row.get("coverageRevision", "")))
	var after_ack := _capture_until_settled(provider, "seed:ordinary-provider", Vector3i.ZERO)
	check("accepted_empty_replacement_consumes_tombstone", ack_empty.get("status") == "acknowledged"
		and after_ack.get("removalsBySection", {}).get(Vector3i.ZERO, []).is_empty(), after_ack)

	var passed := true
	for row: Dictionary in checks:
		if not bool(row.passed): passed = false
	var report := {"schema":"ordinary-structure-static-section-provider-contract/v1",
		"evidenceLevel":"synthetic_authority_census_and_prepared_geometry_contract",
		"complete":true, "passed":passed, "checkCount":checks.size(), "checks":checks,
		"doesNotProve":"native upload or receipt, production registration, save/reload, headed visual parity, or performance"}
	var report_path := OS.get_environment("VOXEL_ORDINARY_STATIC_SECTION_PROVIDER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("ORDINARY STATIC SECTION PROVIDER ", JSON.stringify(report))
	world.queue_free()
	quit(0 if passed else 1)


func _capture_until_settled(provider: Object, world_id: String,
		section: Vector3i) -> Dictionary:
	var result: Dictionary = {}
	for _iteration in range(128):
		result = provider.capture_static_section_sources(world_id, [section])
		if result.get("status") != "pending": return result
	return result


func _capture_sections_until_settled(provider: Object, world_id: String,
		sections: Array[Vector3i]) -> Dictionary:
	var result: Dictionary = {}
	for _iteration in range(256):
		result = provider.capture_static_section_sources(world_id, sections)
		if result.get("status") != "pending": return result
	return result


func _capture_until_pending(provider: Object, world_id: String,
		section: Vector3i) -> Dictionary:
	return _capture_until_settled(provider, world_id, section)


func _make_body(source_id: String, cell: Vector3i, block_type: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("cell", cell)
	body.set_meta("block_type", block_type)
	body.set_meta("generated", true)
	body.set_meta("generated_visual_source_id", source_id)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	visual.material_override = StandardMaterial3D.new()
	body.add_child(visual)
	return body


func check(name: String, passed: bool, details: Dictionary) -> void:
	checks.append({"name":name, "passed":passed, "details":{
		"status":String(details.get("status", "")),
		"reason":String(details.get("reason", "")),
		"memberCount":int(details.get("memberCount", -1)),
		"providerId":String(details.get("providerId", ""))}})
