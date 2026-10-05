extends SceneTree

const ProviderScript := preload("res://scripts/world/OrdinaryStructureStaticSectionProvider.gd")
const Adapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const SourceRosterScript := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const StructureScript := preload("res://scripts/StructureSystem.gd")
const VisualRecipe := preload("res://scripts/world/OrdinaryStructureBlockVisualRecipe.gd")
const SourceCaptureScript := preload("res://scripts/world/OrdinaryStructureVisualSourceCapture.gd")
const CoordinatorScript := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const EXPECTED_CAPTURE_PHASES := ["town_regions", "standalone_regions", "sources",
	"cells", "sort_cells", "hash", "validate"]


func _visual_recipe_input(block_type: String, options: Dictionary = {}) -> Dictionary:
	var sealed_options: Dictionary = StructureScript._sealed_ordinary_visual_value(options)
	var result := {"schema":"ordinary-structure-visual-recipe-input/v1",
		"blockType":block_type, "options":sealed_options,
		"digest":StructureScript._ordinary_visual_recipe_digest(block_type, sealed_options)}
	result.make_read_only()
	return result

class FixtureMain extends Node3D:
	var CELL := 1.35
	var TOWN_REGION_CELLS := 64
	var STRUCTURE_REGION_CELLS := 128
	var STRUCTURE_SPAWN_CHANCE := 0.0
	var seed_text := "ordinary-static-provider-contract"
	var town_region_cache: Dictionary = {}
	var blocks: Dictionary = {}
	var block_root: Node3D
	var meshes: Dictionary = {}
	var materials: Dictionary = {"stoneBlock":StandardMaterial3D.new(),
		"woodBlock":StandardMaterial3D.new(), "cobblestonePath":StandardMaterial3D.new(),
		"roofWood":StandardMaterial3D.new(), "roofStone":StandardMaterial3D.new(),
		"trimWood":StandardMaterial3D.new(), "trimStone":StandardMaterial3D.new()}

	func _init() -> void:
		block_root = self
		materials["roofWood"].albedo_color = Color(0.38, 0.19, 0.08)
		materials["roofStone"].albedo_color = Color(0.25, 0.27, 0.30)
		materials["trimWood"].albedo_color = Color(0.22, 0.10, 0.04)
		materials["trimStone"].albedo_color = Color(0.13, 0.15, 0.17)

	func block_visual_mesh(_key: String) -> Mesh:
		if not meshes.has("base"):
			meshes.base = BoxMesh.new()
		return meshes.base

	func block_visual_material(key: String) -> Material:
		return materials.get(key, materials.stoneBlock)

	func block_collision_profile(_block_type: String) -> Dictionary:
		return {"size":Vector3.ONE * CELL * 0.96, "offset":Vector3.ZERO}


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
	var timing_probe = SourceCaptureScript.new()
	timing_probe.begin_membership(system, Rect2i(Vector2i.ZERO, Vector2i.ONE))
	var first_timing_slice: Dictionary = timing_probe.advance(1, 3000)
	var second_timing_slice: Dictionary = timing_probe.advance(1, 3000)
	var first_slice_usec: Dictionary = first_timing_slice.get("slicePhaseUsec", {})
	var second_slice_usec: Dictionary = second_timing_slice.get("slicePhaseUsec", {})
	var first_cumulative_usec: Dictionary = first_timing_slice.get("phaseUsec", {})
	var second_cumulative_usec: Dictionary = second_timing_slice.get("phaseUsec", {})
	var first_phase_keys: Array[String] = []
	var second_phase_keys: Array[String] = []
	for key_value: Variant in first_slice_usec:
		first_phase_keys.append(String(key_value))
	for key_value: Variant in second_slice_usec:
		second_phase_keys.append(String(key_value))
	first_phase_keys.sort()
	second_phase_keys.sort()
	var expected_phase_keys: Array[String] = []
	for phase_value: Variant in EXPECTED_CAPTURE_PHASES:
		expected_phase_keys.append(String(phase_value))
	expected_phase_keys.sort()
	var phase_usec_nonnegative := true
	for phase_name: String in EXPECTED_CAPTURE_PHASES:
		if int(first_slice_usec.get(phase_name, -1)) < 0 \
				or int(second_slice_usec.get(phase_name, -1)) < 0:
			phase_usec_nonnegative = false
	check("budget_slices_report_bounded_fixed_stage_timing_and_stable_cumulative_totals",
		first_timing_slice.get("reason") == "ordinary_visual_capture_budget"
		and second_timing_slice.get("reason") == "ordinary_visual_capture_budget"
		and first_phase_keys == expected_phase_keys
		and second_phase_keys == expected_phase_keys
		and first_slice_usec.is_read_only() and second_slice_usec.is_read_only()
		and first_cumulative_usec.is_read_only() and second_cumulative_usec.is_read_only()
		and phase_usec_nonnegative
		and int(second_cumulative_usec.get("town_regions", 0))
			>= int(first_cumulative_usec.get("town_regions", 0)),
		{"first":first_timing_slice, "second":second_timing_slice})
	var corner_recipe: Dictionary = VisualRecipe.resolve_member(world, "woodBlock",
		Vector3i(0, 0, 0), StructureScript._sealed_ordinary_visual_value({
			"accentRole":"cornerTimber", "cornerX":-1, "cornerZ":1,
			"cornerTrimMaterial":"trimWood"}))
	var corner_members: Array = corner_recipe.get("members", [])
	var corner_ids: Array[String] = []
	for member_value: Variant in corner_members:
		if member_value is Dictionary:
			corner_ids.append(String(member_value.get("segmentId", "")))
	check("opaque_corner_timber_accent_matches_live_visual_members",
		corner_recipe.get("status") == "ready" and corner_ids == [
			"base", "corner_timber_x", "corner_timber_z"]
		and corner_members.size() == 3
		and corner_members[1].meshLocalTransform.origin == Vector3(
			-world.CELL * 0.50, 0.0, world.CELL * 0.43)
		and corner_members[2].meshLocalTransform.origin == Vector3(
			-world.CELL * 0.43, 0.0, world.CELL * 0.50), corner_recipe)
	var fence_recipe: Dictionary = VisualRecipe.resolve_member(world, "woodBlock",
		Vector3i(0, 0, 0), StructureScript._sealed_ordinary_visual_value({
			"accentRole":"fencePost", "fenceAxis":"z",
			"fenceTrimMaterial":"trimWood"}))
	var fence_members: Array = fence_recipe.get("members", [])
	var fence_ids: Array[String] = []
	for member_value: Variant in fence_members:
		if member_value is Dictionary:
			fence_ids.append(String(member_value.get("segmentId", "")))
	check("opaque_fence_accent_captures_post_and_both_axis_correct_rails",
		fence_recipe.get("status") == "ready" and fence_ids == [
			"base", "fence_post", "fence_rail_0", "fence_rail_1"]
		and fence_members.size() == 4
		and fence_members[2].meshLocalTransform.basis.get_scale().is_equal_approx(Vector3(
			world.CELL * 0.14, world.CELL * 0.12, world.CELL * 1.04)
			)
		and is_equal_approx(fence_members[2].meshLocalTransform.origin.y,
			world.CELL * 0.18)
		and is_equal_approx(fence_members[3].meshLocalTransform.origin.y,
			-world.CELL * 0.18),
		fence_recipe)
	var source_id := "town:0,0"
	var cell := Vector3i(2, 0, 3)
	var roof_options := {"roofRole":"ridge", "roofAxis":"x", "roofEdgeX":-1,
		"roofEdgeZ":1, "roofAccent":"chimney"}
	var body := _make_body(world, source_id, cell, "stoneBlock", roof_options)
	body.position = Vector3(cell) * world.CELL
	world.add_child(body)
	world.blocks[cell] = body
	system.ordinary_visual_sources[source_id] = {
		"completed":true, "expected":{cell:"stoneBlock"},
		"visualRecipeInputs":{cell:_visual_recipe_input("stoneBlock", roof_options)},
		"omitted":{}, "failed":{}, "revision":2}
	var provider := ProviderScript.new()
	var configured: Dictionary = provider.configure("seed:ordinary-provider", system, world)
	check("provider_binds_to_structure_and_world_authorities", configured.get("status") == "ready", configured)
	var first := _capture_until_settled(provider, "seed:ordinary-provider", Vector3i.ZERO)
	var section_row: Dictionary = first.get("sections", {}).get(Vector3i.ZERO, {})
	var prepared: Dictionary = first.get("preparedSections", {}).get(Vector3i.ZERO, {})
	var prepared_inputs: Array = prepared.get("inputs", [])
	var prepared_input: Dictionary = prepared_inputs[0] if not prepared_inputs.is_empty() \
		and prepared_inputs[0] is Dictionary else {}
	check("section_census_is_complete_and_geometry_is_bound_to_source_revision",
		first.get("status") == "complete" and section_row.get("status") == "complete"
		and section_row.get("sourcePartIds", []).size() == 1
		and prepared.get("inputs", []).size() == 2
		and String(prepared_input.get("visualRecipeDigest", "")).length() == 64
		and prepared_input.get("visualRecipeInput", {}).is_read_only()
		and prepared.get("declarations", []).size() == 1
		and prepared.get("preparedSegments", []).size() == 2
		and prepared.get("declarations", [])[0].get("segments", []).size() == 2
		and prepared.get("resourceBindings", {}).size() == 1,
		{"status":first.get("status", ""), "reason":first.get("reason", ""),
			"memberIds":section_row.get("sourcePartIds", []),
			"inputCount":prepared.get("inputs", []).size()})
	var census_values_are_deeply_sealed := true
	for entry_value: Variant in provider._membership_censuses.values():
		var cached_entry: Dictionary = entry_value
		if not _sealed_value_tree(cached_entry.get("census", {})):
			census_values_are_deeply_sealed = false
	check("shared_membership_cache_contains_only_deeply_sealed_values",
		provider.membership_census_stats().get("cachedEntryCount", 0) > 0
		and census_values_are_deeply_sealed,
		provider.membership_census_stats())
	var member_id := String(section_row.get("sourcePartIds", [""])[0]) \
		if not section_row.get("sourcePartIds", []).is_empty() else ""
	var expected_part_id := "ordinary:%s:cell:%d,%d,%d" % [source_id, cell.x, cell.y, cell.z]
	check("stable_member_id_and_section_owned_readonly_roof_segment_inputs",
		member_id == expected_part_id and prepared.get("inputs", []).size() == 2
		and prepared.inputs[0].is_read_only() and prepared.inputs[0].buffer.is_read_only()
		and prepared.inputs[0].buffer.size() == 20,
		{"memberId":member_id, "expected":expected_part_id})
	var roster := SourceRosterScript.new()
	var roster_bound: Dictionary = roster.bind_world("seed:ordinary-provider", [ProviderScript.PROVIDER_ID])
	var registered: Dictionary = roster.register_provider(ProviderScript.PROVIDER_ID,
		provider, "capture_static_section_sources")
	var roster_result: Dictionary = roster.capture_sections([Vector3i.ZERO])
	var contribution_result: Dictionary = provider.capture_static_section_contribution(
		roster_result, Vector3i.ZERO)
	var contribution: Dictionary = contribution_result.get("contribution", {})
	check("provider_satisfies_exact_static_section_roster_contract",
		roster_bound.get("status") == "ready" and registered.get("status") == "ready"
		and roster_result.get("status") == "complete"
		and roster_result.expectedContributorsBySection.get(Vector3i.ZERO, []).has(member_id),
		roster_result)
	check("provider_returns_same_sealed_geometry_for_cross_domain_assembly",
		contribution_result.get("status") == "ready" and contribution.is_read_only()
		and contribution.get("providerId") == ProviderScript.PROVIDER_ID
		and contribution.get("authoritySourceRevisions", {}).get(member_id, "") \
			== String(roster_result.sourceRevisions.get(member_id, ""))
		and contribution.get("inputs", []).size() == 2
		and contribution.get("inputs", [])[0].get("sourcePartId", "") == member_id
		and contribution.get("compatibilityByKey", {}).size() == 1
		and contribution.get("resourceBindings", {}).size() == 1,
		{"status":contribution_result.get("status", ""),
			"reason":contribution_result.get("reason", ""),
			"inputCount":contribution.get("inputs", []).size()})
	var first_coverage := String(section_row.get("coverageRevision", ""))
	var rejected_receipt := {}
	rejected_receipt.make_read_only()
	var rejected_ack := provider.acknowledge_section_install(Vector3i.ZERO,
		first_coverage, rejected_receipt)
	check("missing_native_receipt_keeps_the_body_visual_visible",
		rejected_ack.get("status") == "failed"
		and (body.get_child(0) as MeshInstance3D).visible,
		rejected_ack)
	var replaced_body := _make_body(world, source_id, cell, "stoneBlock", roof_options)
	replaced_body.position = body.position
	world.add_child(replaced_body)
	world.blocks[cell] = replaced_body
	var stale_owner_ack := provider.acknowledge_section_install(Vector3i.ZERO,
		first_coverage, _installed_receipt(Vector3i.ZERO))
	check("replaced_body_owner_keeps_old_visual_visible_and_ack_retryable",
		stale_owner_ack.get("status") == "pending"
		and String(stale_owner_ack.get("reason", "")) == "ordinary_section_live_owner_revision_changed"
		and (body.get_child(0) as MeshInstance3D).visible,
		stale_owner_ack)
	var stale_contribution: Dictionary = provider.capture_static_section_contribution(
		roster_result, Vector3i.ZERO)
	check("replacement_owner_invalidates_prepared_contribution_snapshot",
		stale_contribution.get("status") == "pending"
		and String(stale_contribution.get("reason", ""))
			== "ordinary_section_contribution_live_owner_stale"
		and (body.get_child(0) as MeshInstance3D).visible,
		stale_contribution)
	world.blocks[cell] = body
	replaced_body.queue_free()
	var owner_rebuilt: Dictionary = _capture_until_settled(provider,
		"seed:ordinary-provider", Vector3i.ZERO)
	var rebuilt_contribution: Dictionary = provider.capture_static_section_contribution(
		roster_result, Vector3i.ZERO)
	check("replacement_owner_is_recaptured_before_contributing_geometry",
		owner_rebuilt.get("status") == "complete"
		and rebuilt_contribution.get("status") == "ready",
		{"status":owner_rebuilt.get("status", ""),
			"contributionStatus":rebuilt_contribution.get("status", ""),
			"reason":rebuilt_contribution.get("reason", "")})
	var acknowledged: Dictionary = provider.acknowledge_section_install(Vector3i.ZERO,
		first_coverage, _installed_receipt(Vector3i.ZERO))
	var visible_roof_segments: Array[String] = []
	for child: Node in body.get_children():
		if child is MeshInstance3D and child.visible:
			visible_roof_segments.append(String(child.get_meta(
				"ordinary_structure_recipe_segment_id", "")))
	visible_roof_segments.sort()
	var expected_remaining_roof_segments: Array[String] = [
		"roof_base", "roof_eave_x", "roof_eave_z", "roof_ridge_bar"]
	check("membership_baseline_advances_only_on_explicit_install_ack",
		acknowledged.get("status") == "acknowledged"
		and int(acknowledged.get("memberCount", 0)) == 1
		and visible_roof_segments == expected_remaining_roof_segments
		and body.is_inside_tree(),
		{"status":String(acknowledged.get("status", "")),
			"reason":String(acknowledged.get("reason", "")),
			"visibleSegments":visible_roof_segments})
	var geometry_cache_before_lower: Dictionary = provider.membership_census_stats()
	var lower_roof_section := _capture_until_settled(provider,
		"seed:ordinary-provider", Vector3i(0, -1, 0))
	var geometry_cache_after_lower: Dictionary = provider.membership_census_stats()
	var lower_roof_row: Dictionary = lower_roof_section.get("sections", {}).get(
		Vector3i(0, -1, 0), {})
	var lower_roof_ack := provider.acknowledge_section_install(Vector3i(0, -1, 0),
		String(lower_roof_row.get("coverageRevision", "")),
		_installed_receipt(Vector3i(0, -1, 0)))
	var all_roof_members_retired := true
	for child: Node in body.get_children():
		if child is MeshInstance3D and child.visible:
			all_roof_members_retired = false
	check("cross_section_roof_visuals_retire_only_after_each_owned_section_receipt",
		lower_roof_section.get("status") == "complete"
		and lower_roof_row.get("sourcePartIds", []).has(member_id)
		and lower_roof_section.get("preparedSections", {}).get(
			Vector3i(0, -1, 0), {}).get("inputs", []).size() == 4
		and lower_roof_ack.get("status") == "acknowledged"
		and all_roof_members_retired,
		{"sectionStatus":lower_roof_section.get("status", ""),
			"reason":lower_roof_section.get("reason", ""),
			"segmentCount":lower_roof_section.get("preparedSections", {}).get(
				Vector3i(0, -1, 0), {}).get("inputs", []).size(),
			"ackStatus":lower_roof_ack.get("status", ""),
			"allMembersRetired":all_roof_members_retired})
	check("adjacent_vertical_section_reuses_the_complete_source_capture",
		int(geometry_cache_after_lower.get("geometryCaptureCacheHits", 0)) \
			> int(geometry_cache_before_lower.get("geometryCaptureCacheHits", 0))
		and geometry_cache_after_lower.get("geometryCaptureCacheEntries", 0) > 0,
		geometry_cache_after_lower)
	var cache_before_resource_change: Dictionary = provider.membership_census_stats()
	var cached_recipe := _visual_recipe_input("stoneBlock", roof_options)
	var cached_raw := {"sourceId":source_id, "sourceRevision":2,
		"cell":cell, "blockType":"stoneBlock",
		"recipeDigest":String(cached_recipe.get("digest", ""))}
	var geometry_cache_hit := provider._capture_or_reuse_block({"system":system,
		"main":world}, cached_raw, cell, "stoneBlock")
	var cached_mesh: Mesh = world.block_visual_mesh("stoneBlock")
	cached_mesh.emit_changed()
	var cache_after_resource_change: Dictionary = provider.membership_census_stats()
	var geometry_cache_rebuild := provider._capture_or_reuse_block({"system":system,
		"main":world}, cached_raw, cell, "stoneBlock")
	var cache_after_rebuild: Dictionary = provider.membership_census_stats()
	check("resource_changed_invalidates_capture_cache_before_reuse",
		geometry_cache_hit.get("status") == "ready" \
		and int(cache_after_resource_change.get("geometryCaptureCacheEntries", 0)) \
			< int(cache_before_resource_change.get("geometryCaptureCacheEntries", 0)) \
		and geometry_cache_rebuild.get("status") == "ready" \
		and int(cache_after_rebuild.get("geometryCaptureCacheMisses", 0)) \
			> int(cache_after_resource_change.get("geometryCaptureCacheMisses", 0)),
		{"hitStatus":geometry_cache_hit.get("status", ""),
			"rebuildStatus":geometry_cache_rebuild.get("status", ""),
			"before":cache_before_resource_change,
			"afterChange":cache_after_resource_change,
			"afterRebuild":cache_after_rebuild})
	var boundary_cell := Vector3i(16, 0, 3)
	var boundary_body := _make_body(world, source_id, boundary_cell, "stoneBlock")
	boundary_body.position = Vector3(boundary_cell) * world.CELL
	world.add_child(boundary_body)
	world.blocks[boundary_cell] = boundary_body
	system.ordinary_visual_sources[source_id].expected[boundary_cell] = "stoneBlock"
	system.ordinary_visual_sources[source_id].visualRecipeInputs[boundary_cell] = \
		_visual_recipe_input("stoneBlock")
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var overlap_stats_before: Dictionary = provider.membership_census_stats()
	var boundary_sections := _capture_sections_until_settled(provider,
		"seed:ordinary-provider", [Vector3i.ZERO, Vector3i(1, 0, 0)])
	var overlap_stats_after: Dictionary = provider.membership_census_stats()
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
	check("overlapping_sections_share_one_resumable_membership_census",
		int(overlap_stats_after.get("buildCount", 0))
			== int(overlap_stats_before.get("buildCount", 0)) + 1
		and int(overlap_stats_after.get("overlapReuseCount", 0))
			== int(overlap_stats_before.get("overlapReuseCount", 0)) + 1
		and int(overlap_stats_after.get("memberRowsBuilt", 0))
			>= int(overlap_stats_before.get("memberRowsBuilt", 0)) + 2,
		{"buildsBefore":overlap_stats_before.get("buildCount", 0),
			"buildsAfter":overlap_stats_after.get("buildCount", 0),
			"overlapReusesBefore":overlap_stats_before.get("overlapReuseCount", 0),
			"overlapReusesAfter":overlap_stats_after.get("overlapReuseCount", 0),
			"memberRowsBefore":overlap_stats_before.get("memberRowsBuilt", 0),
			"memberRowsAfter":overlap_stats_after.get("memberRowsBuilt", 0)})
	var boundary_ack := provider.acknowledge_section_install(Vector3i(1, 0, 0),
		String(east_row.get("coverageRevision", "")),
		_installed_receipt(Vector3i(1, 0, 0)))
	var hidden_boundary_sections := _capture_sections_until_settled(provider,
		"seed:ordinary-provider", [Vector3i.ZERO, Vector3i(1, 0, 0)])
	var hidden_sections: Dictionary = hidden_boundary_sections.get("sections", {})
	check("retired_boundary_visual_replays_from_actual_mesh_support",
		boundary_ack.get("status") == "acknowledged"
		and not boundary_mesh.visible
		and hidden_boundary_sections.get("status") == "complete"
		and not hidden_sections.get(Vector3i.ZERO, {}).get(
			"sourcePartIds", []).has(boundary_part_id)
		and hidden_sections.get(Vector3i(1, 0, 0), {}).get(
			"sourcePartIds", []).has(boundary_part_id),
		{"status":hidden_boundary_sections.get("status", ""),
			"reason":hidden_boundary_sections.get("reason", ""),
			"westMembers":hidden_sections.get(Vector3i.ZERO, {}).get("sourcePartIds", []),
			"eastMembers":hidden_sections.get(Vector3i(1, 0, 0), {}).get("sourcePartIds", [])})
	var boundary_removed_key := system._ordinary_visual_block_key(source_id,
		boundary_cell, "stoneBlock")
	system.removed_generated_structure_blocks[boundary_removed_key] = true
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var tombstone_stats_before: Dictionary = provider.membership_census_stats()
	var boundary_removal := _capture_sections_until_settled(provider,
		"seed:ordinary-provider", [Vector3i.ZERO, Vector3i(1, 0, 0)])
	var tombstone_stats_after: Dictionary = provider.membership_census_stats()
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
	check("tombstone_revision_rebuilds_shared_membership_census",
		int(tombstone_stats_after.get("buildCount", 0))
			== int(tombstone_stats_before.get("buildCount", 0)) + 1
		and int(tombstone_stats_after.get("memberRowsBuilt", 0))
			< int(tombstone_stats_before.get("memberRowsBuilt", 0)) + 2,
		{"buildsBefore":tombstone_stats_before.get("buildCount", 0),
			"buildsAfter":tombstone_stats_after.get("buildCount", 0),
			"memberRowsBefore":tombstone_stats_before.get("memberRowsBuilt", 0),
			"memberRowsAfter":tombstone_stats_after.get("memberRowsBuilt", 0),
			"tombstones":east_tombstones.size()})
	var boundary_empty_row: Dictionary = boundary_removal.get("sections", {}).get(Vector3i(1, 0, 0), {})
	provider.acknowledge_section_install(Vector3i(1, 0, 0),
		String(boundary_empty_row.get("coverageRevision", "")),
		_installed_receipt(Vector3i(1, 0, 0)))
	var out_of_bounds_options := roof_options.duplicate()
	out_of_bounds_options["world_x"] = float(cell.x) * world.CELL + world.CELL * 1.1
	var out_of_bounds_position := Vector3(out_of_bounds_options.world_x,
		float(cell.y) * world.CELL, float(cell.z) * world.CELL)
	body.position = out_of_bounds_position
	system.ordinary_visual_sources[source_id].visualRecipeInputs[cell] = \
		_visual_recipe_input("stoneBlock", out_of_bounds_options)
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var excessive_support := _capture_until_settled(provider, "seed:ordinary-provider", Vector3i.ZERO)
	check("visual_extending_beyond_discovery_margin_keeps_section_pending",
		excessive_support.get("status") == "pending"
		and String(excessive_support.get("reason", "")) == "ordinary_geometry_horizontal_support_exceeds_section_query",
		excessive_support)
	body.position = Vector3(cell) * world.CELL
	system.ordinary_visual_sources[source_id].visualRecipeInputs[cell] = \
		_visual_recipe_input("stoneBlock", roof_options)
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
	var chest := _make_body(world, source_id, unsupported_cell, "chest")
	chest.position = Vector3(unsupported_cell) * world.CELL
	world.add_child(chest)
	world.blocks[unsupported_cell] = chest
	system.ordinary_visual_sources[source_id].expected[unsupported_cell] = "chest"
	system.ordinary_visual_sources[source_id].visualRecipeInputs[unsupported_cell] = \
		_visual_recipe_input("chest")
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
		String(empty_row.get("coverageRevision", "")),
		_installed_receipt(Vector3i.ZERO))
	var after_ack := _capture_until_settled(provider, "seed:ordinary-provider", Vector3i.ZERO)
	check("accepted_empty_replacement_consumes_tombstone", ack_empty.get("status") == "acknowledged"
		and after_ack.get("removalsBySection", {}).get(Vector3i.ZERO, []).is_empty(), after_ack)

	var throughput_source: Dictionary = system.ordinary_visual_sources[source_id]
	var throughput_expected: Dictionary = throughput_source.get("expected", {})
	var throughput_recipes: Dictionary = throughput_source.get("visualRecipeInputs", {})
	for index in range(33):
		var throughput_cell := Vector3i(4 + index % 8, 0, 4 + int(index / 8))
		var throughput_body := _make_body(world, source_id, throughput_cell, "stoneBlock")
		throughput_body.position = Vector3(throughput_cell) * world.CELL
		world.add_child(throughput_body)
		world.blocks[throughput_cell] = throughput_body
		throughput_expected[throughput_cell] = "stoneBlock"
		throughput_recipes[throughput_cell] = _visual_recipe_input("stoneBlock")
	throughput_source["revision"] = int(throughput_source.get("revision", 0)) + 1
	system.ordinary_visual_revision += 1
	var geometry_before: Dictionary = provider.membership_census_stats()
	var first_geometry_slice: Dictionary = provider.capture_static_section_sources(
		"seed:ordinary-provider", [Vector3i.ZERO])
	var first_geometry_stats: Dictionary = provider.membership_census_stats()
	var first_progress: Dictionary = first_geometry_stats.get("lastGeometryProgress", {})
	var progress_hit_slice_budget: bool = first_geometry_slice.get("status") == "pending" \
		and String(first_geometry_slice.get("reason", "")) \
		== "ordinary_section_geometry_capture_budget" \
		and int(first_progress.get("cursorAfter", 0)) > int(first_progress.get("cursorBefore", 0))
	var restarts_before_token_change := int(first_geometry_stats.get("geometryJobRestartCount", 0))
	var invalidations_before_token_change := int(
		first_geometry_stats.get("geometryJobInvalidationCount", 0))
	throughput_source["revision"] = int(throughput_source.get("revision", 0)) + 1
	system.ordinary_visual_revision += 1
	var restarted_geometry_slice: Dictionary = provider.capture_static_section_sources(
		"seed:ordinary-provider", [Vector3i.ZERO])
	var restarted_geometry_stats: Dictionary = provider.membership_census_stats()
	var restarted_progress: Dictionary = restarted_geometry_stats.get("lastGeometryProgress", {})
	check("geometry_cursor_progress_is_resumable_and_token_change_invalidates_once",
		progress_hit_slice_budget
		and int(restarted_geometry_stats.get("geometryJobRestartCount", 0))
			== restarts_before_token_change + 1
		and int(restarted_geometry_stats.get("geometryJobInvalidationCount", 0))
			== invalidations_before_token_change + 1
		and int(restarted_progress.get("cursorBefore", -1)) == 0
		and int(restarted_progress.get("cursorAfter", 0)) > 0,
		{"firstStatus":first_geometry_slice.get("status", ""),
			"firstReason":first_geometry_slice.get("reason", ""),
			"firstProgress":first_progress,
			"restartedStatus":restarted_geometry_slice.get("status", ""),
			"restartedProgress":restarted_progress,
			"geometryBefore":geometry_before,
			"geometryAfter":restarted_geometry_stats})
	var completed_throughput_capture := _capture_until_settled(provider,
		"seed:ordinary-provider", Vector3i.ZERO)
	var final_geometry_stats: Dictionary = provider.membership_census_stats()
	var final_progress: Dictionary = final_geometry_stats.get("lastGeometryProgress", {})
	var final_stage_stats: Dictionary = final_geometry_stats.get("censusStageUsec", {})
	check("geometry_continuation_completes_with_monotonic_bounded_counters",
		completed_throughput_capture.get("status") == "complete"
		and int(final_geometry_stats.get("geometryAdvanceCount", 0))
			> int(geometry_before.get("geometryAdvanceCount", 0))
		and int(final_geometry_stats.get("geometryCursorAdvanceCount", 0))
			>= int(first_progress.get("cursorAfter", 0))
		and int(final_geometry_stats.get("geometryJobCompleteCount", 0)) > 0
		and final_progress.get("cursorAfter", 0) == final_progress.get("candidateCount", -1)
		and final_stage_stats.is_read_only(),
		{"status":completed_throughput_capture.get("status", ""),
			"geometryStats":final_geometry_stats})
	await _run_coordinator_throughput_integration()

	var passed := true
	for row: Dictionary in checks:
		if not bool(row.passed): passed = false
	var report := {"schema":"ordinary-structure-static-section-provider-contract/v1",
		"evidenceLevel":"synthetic_real_coordinator_and_ordinary_provider_geometry_contract",
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


## Exercises the real visible-demand scheduler with the production ordinary
## provider. Each loop iteration advances the coordinator exactly once, then
## waits for the next engine frame before retrying its continuation.
func _run_coordinator_throughput_integration() -> void:
	var integration_world := FixtureMain.new()
	root.add_child(integration_world)
	for z in range(-2, 2):
		for x in range(-2, 2):
			integration_world.town_region_cache[Vector2i(x, z)] = {}
	integration_world.town_region_cache[Vector2i.ZERO] = {
		"key":"0,0", "x":-4, "z":-4, "width":24, "depth":24}
	var integration_system := FixtureStructure.new()
	integration_system.main = integration_world
	var integration_source_id := "town:0,0"
	var expected: Dictionary = {}
	var recipe_inputs: Dictionary = {}
	for index in range(33):
		var cell := Vector3i(4 + index % 8, 0, 4 + int(index / 8))
		var body := _make_body(integration_world, integration_source_id, cell, "stoneBlock")
		body.position = Vector3(cell) * integration_world.CELL
		integration_world.add_child(body)
		integration_world.blocks[cell] = body
		expected[cell] = "stoneBlock"
		recipe_inputs[cell] = _visual_recipe_input("stoneBlock")
	integration_system.ordinary_visual_sources[integration_source_id] = {
		"completed":true, "expected":expected, "visualRecipeInputs":recipe_inputs,
		"omitted":{}, "failed":{}, "revision":1}

	var integration_provider := ProviderScript.new()
	var provider_bound: Dictionary = integration_provider.configure(
		"seed:ordinary-coordinator-integration", integration_system, integration_world)
	var coordinator = CoordinatorScript.new()
	var coordinator_bound: Dictionary = coordinator.configure(
		"seed:ordinary-coordinator-integration")
	var roster_bound: Dictionary = coordinator.configure_source_roster(
		[ProviderScript.PROVIDER_ID])
	var provider_registered: Dictionary = coordinator.register_source_provider(
		ProviderScript.PROVIDER_ID, integration_provider, "capture_static_section_sources")
	var target_section := Vector3i.ZERO
	var competing_initial_section := Vector3i(1, 0, 0)
	var target_requested: Dictionary = coordinator.request_visible_section_demand(
		target_section, 1, 10.0)
	var first_attempt: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
	var first_attempt_section := Vector3i(-999, -999, -999)
	if first_attempt.get("results", []).size() == 1:
		first_attempt_section = first_attempt.results[0].sectionKey
	var competing_requested: Dictionary = coordinator.request_visible_section_demand(
		competing_initial_section, 1, 0.0)
	var target_progress_history: Array[Dictionary] = []
	var advanced_sections: Array[String] = [str(first_attempt_section)]
	var first_stats: Dictionary = integration_provider.membership_census_stats()
	var first_progress: Dictionary = first_stats.get("lastGeometryProgress", {})
	var prior_advance_count := int(first_stats.get("geometryAdvanceCount", 0))
	if String(first_progress.get("sectionKey", "")) == "0,0,0":
		target_progress_history.append({
			"advanceCount":prior_advance_count,
			"cursorBefore":int(first_progress.get("cursorBefore", -1)),
			"cursorAfter":int(first_progress.get("cursorAfter", -1)),
			"candidateCount":int(first_progress.get("candidateCount", -1)),
			"status":String(first_progress.get("status", "")),
			"reason":String(first_progress.get("reason", ""))})
	var competing_initial_was_serviced := false
	for _frame_attempt in range(16):
		await process_frame
		var turn: Dictionary = coordinator.advance_visible_section_candidate_demands(1)
		if turn.get("results", []).size() == 1:
			var advanced_section: Vector3i = turn.results[0].sectionKey
			advanced_sections.append(str(advanced_section))
			if advanced_section == competing_initial_section:
				competing_initial_was_serviced = true
		var stats: Dictionary = integration_provider.membership_census_stats()
		var progress: Dictionary = stats.get("lastGeometryProgress", {})
		var advance_count := int(stats.get("geometryAdvanceCount", 0))
		if advance_count > prior_advance_count \
				and String(progress.get("sectionKey", "")) == "0,0,0":
			target_progress_history.append({
				"advanceCount":advance_count,
				"cursorBefore":int(progress.get("cursorBefore", -1)),
				"cursorAfter":int(progress.get("cursorAfter", -1)),
				"candidateCount":int(progress.get("candidateCount", -1)),
				"status":String(progress.get("status", "")),
				"reason":String(progress.get("reason", ""))})
		prior_advance_count = advance_count
		var demand_state: Dictionary = coordinator._visible_section_demands.get(
			target_section, {})
		if String(demand_state.get("stage", "")) == "candidate_queued":
			break

	var final_stats: Dictionary = integration_provider.membership_census_stats()
	var target_state: Dictionary = coordinator._visible_section_demands.get(
		target_section, {})
	var cursor_monotonic := not target_progress_history.is_empty()
	for index in range(1, target_progress_history.size()):
		if int(target_progress_history[index].cursorAfter) \
				< int(target_progress_history[index - 1].cursorAfter):
			cursor_monotonic = false
	var first_target_cursor := int(target_progress_history[0].cursorAfter) \
		if not target_progress_history.is_empty() else -1
	var last_target_progress: Dictionary = target_progress_history[-1] \
		if not target_progress_history.is_empty() else {}
	var setup_ready: bool = provider_bound.get("status") == "ready" \
		and coordinator_bound.get("status") == "ready" \
		and roster_bound.get("status") == "ready" \
		and provider_registered.get("status") == "ready" \
		and target_requested.get("status") == "queued" \
		and competing_requested.get("status") == "queued"
	check("coordinator_one_attempt_per_frame_drains_real_33_member_ordinary_job",
		setup_ready and first_attempt.get("attemptCount") == 1 \
		and first_attempt_section == target_section \
		and competing_initial_was_serviced \
		and target_state.get("stage") == "candidate_queued" \
		and not target_progress_history.is_empty() \
		and first_target_cursor > 0 and first_target_cursor < 33 \
		and last_target_progress.get("cursorAfter") == 33 \
		and last_target_progress.get("candidateCount") == 33 \
		and last_target_progress.get("status") == "complete" \
		and cursor_monotonic \
		and final_stats.get("geometryJobRestartCount") == 0 \
		and final_stats.get("geometryJobInvalidationCount") == 0 \
		and final_stats.get("geometryJobCompleteCount") >= 1,
		{"status":String(target_state.get("stage", "")),
			"reason":String(target_state.get("lastReason", "")),
			"memberCount":33, "providerId":ProviderScript.PROVIDER_ID,
			"targetCandidateCount":int(last_target_progress.get("candidateCount", -1)),
			"targetProgressHistory":target_progress_history,
			"advancedSections":advanced_sections,
			"geometryJobRestartCount":int(final_stats.get("geometryJobRestartCount", -1)),
			"geometryJobInvalidationCount":int(final_stats.get("geometryJobInvalidationCount", -1)),
			"geometryJobCompleteCount":int(final_stats.get("geometryJobCompleteCount", -1))})
	integration_world.queue_free()


func _installed_receipt(section: Vector3i) -> Dictionary:
	var receipt := {"status":"installed", "sectionKey":section,
		"contentManifestDigest":"synthetic-contract-manifest"}
	receipt.make_read_only()
	return receipt


func _make_body(world: FixtureMain, source_id: String, cell: Vector3i,
		block_type: String, options: Dictionary = {}) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("cell", cell)
	body.set_meta("block_type", block_type)
	body.set_meta("generated", true)
	body.set_meta("generated_visual_source_id", source_id)
	var sealed_options: Dictionary = StructureScript._sealed_ordinary_visual_value(options)
	var recipe: Dictionary = VisualRecipe.resolve_member(world, block_type, cell, sealed_options)
	var content_digest := String(recipe.get("contentDigest", ""))
	body.set_meta("ordinary_structure_recipe_content_digest", content_digest)
	for member_value: Variant in recipe.get("members", []):
		if not member_value is Dictionary:
			continue
		var member: Dictionary = member_value
		var visual := MeshInstance3D.new()
		visual.name = String(member.get("visualName", ""))
		visual.mesh = member.get("mesh")
		visual.material_override = member.get("material")
		visual.transform = member.get("meshLocalTransform", Transform3D.IDENTITY)
		visual.set_meta("ordinary_structure_recipe_segment_id",
			String(member.get("segmentId", "")))
		visual.set_meta("ordinary_structure_recipe_content_digest", content_digest)
		body.add_child(visual)
	return body


func check(name: String, passed: bool, details: Dictionary) -> void:
	var evidence := {"status":String(details.get("status", "")),
		"reason":String(details.get("reason", "")),
		"memberCount":int(details.get("memberCount", -1)),
		"providerId":String(details.get("providerId", "")),
		"allRoofMembersRetired":bool(details.get("allRoofMembersRetired", false)),
		"visibleSegments":details.get("visibleSegments", [])}
	for key in ["targetCandidateCount", "targetProgressHistory", "advancedSections",
			"geometryJobRestartCount", "geometryJobInvalidationCount",
			"geometryJobCompleteCount"]:
		if details.has(key): evidence[key] = details[key]
	checks.append({"name":name, "passed":passed, "details":evidence})


func _sealed_value_tree(value: Variant) -> bool:
	if value is Object or value is RID or value is Callable:
		return false
	if value is Dictionary:
		var dictionary: Dictionary = value
		if not dictionary.is_read_only(): return false
		for key: Variant in dictionary:
			if not _sealed_value_tree(key) or not _sealed_value_tree(dictionary[key]):
				return false
		return true
	if value is Array:
		var array: Array = value
		if not array.is_read_only(): return false
		for item: Variant in array:
			if not _sealed_value_tree(item): return false
		return true
	return typeof(value) < TYPE_PACKED_BYTE_ARRAY
