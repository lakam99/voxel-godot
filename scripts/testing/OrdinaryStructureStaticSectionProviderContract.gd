extends SceneTree

const ProviderScript := preload("res://scripts/world/OrdinaryStructureStaticSectionProvider.gd")
const Adapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const SourceRosterScript := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const StructureScript := preload("res://scripts/StructureSystem.gd")
const VisualRecipe := preload("res://scripts/world/OrdinaryStructureBlockVisualRecipe.gd")
const SourceCaptureScript := preload("res://scripts/world/OrdinaryStructureVisualSourceCapture.gd")
const CoordinatorScript := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const AssetRegistryScript := preload("res://scripts/visual/StaticItemAssetRegistry.gd")
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
	var static_item_asset_registry: Object
	var world_static_section_coordinator: Object

	func _init() -> void:
		block_root = self
		materials["roofWood"].albedo_color = Color(0.38, 0.19, 0.08)
		materials["roofStone"].albedo_color = Color(0.25, 0.27, 0.30)
		materials["trimWood"].albedo_color = Color(0.22, 0.10, 0.04)
		materials["trimStone"].albedo_color = Color(0.13, 0.15, 0.17)
		static_item_asset_registry = AssetRegistryScript.new()
		static_item_asset_registry.setup()

	func block_visual_mesh(_key: String) -> Mesh:
		if not meshes.has("base"):
			meshes.base = BoxMesh.new()
		return meshes.base

	func block_visual_material(key: String) -> Material:
		return materials.get(key, materials.stoneBlock)

	func block_shadow_policy(material_key: String) -> int:
		if material_key in ["glass", "flame", "furnaceGlow", "wardLantern",
			"sanctuaryBeacon", "riftAnchor", "copperOreGlow", "ironOreGlow"]:
			return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	func block_collision_profile(_block_type: String) -> Dictionary:
		return {"size":Vector3.ONE * CELL * 0.96, "offset":Vector3.ZERO}


class FixtureReceiptAuthority extends RefCounted:
	var current_receipts: Dictionary = {}

	func install(section_key: Vector3i, receipt: Dictionary) -> void:
		current_receipts[section_key] = receipt

	func installed_section_receipt_is_current(section_key: Vector3i,
			receipt: Dictionary) -> bool:
		return current_receipts.get(section_key, {}) == receipt


class FixtureLeaseCoordinator extends CoordinatorScript:
	var stale_receipts: Dictionary = {}
	var fail_next_release := false

	func _cancel_pending_production_candidate(section_key: Vector3i) -> Dictionary:
		if fail_next_release:
			fail_next_release = false
			return {"status":"rollback_failed", "sectionKey":section_key}
		return super._cancel_pending_production_candidate(section_key)

	func installed_section_receipt_is_current(section_key: Vector3i,
			receipt: Dictionary) -> bool:
		return not stale_receipts.has(section_key) \
			and _production_candidate_receipts.get(section_key, {}) == receipt


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

	func generated_visual_block_is_removed(source_id: String, cell: Vector3i,
			block_type: String) -> bool:
		return removed_generated_structure_blocks.has(_ordinary_visual_block_key(source_id, cell, block_type))

	func _ordinary_visible_renderable(root_node: Node) -> Node3D:
		if root_node is MeshInstance3D and (root_node as MeshInstance3D).mesh != null:
			return root_node as Node3D
		for child_value: Variant in root_node.get_children():
			if child_value is Node:
				var found := _ordinary_visible_renderable(child_value)
				if found != null: return found
		return null


var checks: Array[Dictionary] = []
var legacy_accent_fallback_calls := 0


func _initialize() -> void:
	call_deferred("run")


func _record_legacy_accent_fallback() -> void:
	legacy_accent_fallback_calls += 1


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
	check("successful_corner_recipe_suppresses_legacy_accent_fallback",
		corner_recipe.get("status") == "ready"
		and not VisualRecipe.invoke_legacy_accent_fallback(true,
			Callable(self, "_record_legacy_accent_fallback"))
		and legacy_accent_fallback_calls == 0
		and corner_members.size() == 3,
		{"recipeStatus":corner_recipe.get("status", ""),
			"recipeSegments":corner_ids,
			"fallbackCalls":legacy_accent_fallback_calls})
	var unsupported_accent_recipe: Dictionary = VisualRecipe.resolve_member(world,
		"glass", Vector3i.ZERO, StructureScript._sealed_ordinary_visual_value({
			"accentRole":"windowFrame", "windowAxis":"x"}))
	check("pending_recipe_keeps_legacy_window_accent_fallback_enabled",
		unsupported_accent_recipe.get("status") == "pending"
		and VisualRecipe.invoke_legacy_accent_fallback(false,
			Callable(self, "_record_legacy_accent_fallback"))
		and legacy_accent_fallback_calls == 1,
		unsupported_accent_recipe)
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
	var expected_family_by_type := {
		"bed":"section_static", "campfire":"separate_dynamic",
		"chest":"separate_dynamic", "cobblestonePath":"section_static",
		"copperVein":"section_static", "door":"separate_dynamic",
		"furnace":"separate_dynamic", "glass":"section_static",
		"ironVein":"section_static", "spikeTrap":"section_static",
		"stoneBlock":"section_static", "torch":"separate_dynamic",
		"traderStall":"section_static", "woodBlock":"section_static",
		"workbench":"section_static"}
	var inventory := VisualRecipe.generated_block_type_inventory()
	var expected_types: Array[String] = []
	for expected_type_value: Variant in expected_family_by_type:
		expected_types.append(String(expected_type_value))
	expected_types.sort()
	var inventory_matches := inventory == expected_types
	for block_type: String in expected_family_by_type:
		var family := VisualRecipe.classify_generated_block_type(block_type)
		inventory_matches = inventory_matches and block_type in inventory \
			and family.get("status") == "classified" \
			and family.get("family") == expected_family_by_type[block_type] \
			and not String(family.get("owner", "")).is_empty()
	var unknown_family := VisualRecipe.classify_generated_block_type("futureUnknownBlock")
	check("every_current_generated_block_type_has_explicit_family_and_owner",
		inventory_matches and unknown_family.get("status") == "unknown" \
		and unknown_family.get("family") == "unknown"
		and String(unknown_family.get("reason", "")) \
		== "ordinary_generated_block_family_unclassified",
		{"inventory":inventory, "expected":expected_family_by_type,
			"unknown":unknown_family})
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
	var roster_member_identity := ""
	for identity_key_value: Variant in roster_result.get("sourceIdentities", {}):
		var identity: Dictionary = roster_result.sourceIdentities[identity_key_value]
		if String(identity.get("sourceId", "")) == member_id \
				and String(identity.get("sourcePartId", "")) == member_id:
			roster_member_identity = String(identity_key_value)
	var contribution_result: Dictionary = provider.capture_static_section_contribution(
		roster_result, Vector3i.ZERO)
	var contribution: Dictionary = contribution_result.get("contribution", {})
	var contribution_inputs: Array = contribution.get("inputs", [])
	var first_contribution_source := String(contribution_inputs[0].get("sourcePartId", "")) \
		if not contribution_inputs.is_empty() else ""
	check("provider_satisfies_exact_static_section_roster_contract",
		roster_bound.get("status") == "ready" and registered.get("status") == "ready"
		and roster_result.get("status") == "complete"
		and not roster_member_identity.is_empty()
		and roster_result.expectedContributorsBySection.get(Vector3i.ZERO, []).has(
			roster_member_identity),
		{"status":roster_result.get("status", ""),
			"providerIds":roster_result.get("providerIds", []),
			"expectedContributors":roster_result.get("expectedContributorsBySection", {}).get(
				Vector3i.ZERO, []), "memberId":member_id,
			"rosterMemberIdentity":roster_member_identity,
			"sourceRevisions":roster_result.get("sourceRevisions", {})})
	check("provider_returns_same_sealed_geometry_for_cross_domain_assembly",
		contribution_result.get("status") == "ready" and contribution.is_read_only()
		and contribution.get("providerId") == ProviderScript.PROVIDER_ID
		and contribution.get("authoritySourceRevisions", {}).get(roster_member_identity, "") \
			== String(roster_result.sourceRevisions.get(roster_member_identity, ""))
		and contribution.get("inputs", []).size() == 2
		and contribution.get("inputs", [])[0].get("sourcePartId", "") == member_id
		and contribution.get("compatibilityByKey", {}).size() == 1
		and contribution.get("resourceBindings", {}).size() == 1,
		{"status":contribution_result.get("status", ""),
			"reason":contribution_result.get("reason", ""),
			"providerId":contribution.get("providerId", ""),
			"sealed":contribution.is_read_only(),
			"authorityRevision":contribution.get("authoritySourceRevisions", {}),
			"expectedAuthorityRevision":roster_result.get("sourceRevisions", {}).get(
				roster_member_identity, ""),
			"inputCount":contribution.get("inputs", []).size(),
			"firstInputSource":first_contribution_source,
			"expectedMemberId":member_id,
			"compatibilityCount":contribution.get("compatibilityByKey", {}).size(),
			"resourceCount":contribution.get("resourceBindings", {}).size()})
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
	var boundary_cell := Vector3i(16, 8, 3)
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
	var west_prepared: Dictionary = boundary_sections.get("preparedSections", {}).get(
		Vector3i.ZERO, {})
	var east_prepared: Dictionary = boundary_sections.get("preparedSections", {}).get(
		Vector3i(1, 0, 0), {})
	var boundary_identity := ProviderScript._source_part_identity_key(
		boundary_part_id, boundary_part_id)
	var west_support_ranges: Array = west_prepared.get(
		"supportRangesBySource", {}).get(boundary_identity, [])
	var center_draw_inputs: Array = east_prepared.get("inputs", [])
	check("boundary_geometry_has_support_member_and_one_center_owned_draw",
		boundary_sections.get("status") == "complete" and boundary_overlaps_west
		and west_members.has(boundary_part_id) and east_members.has(boundary_part_id)
		and not _prepared_inputs_contain_source_part(west_prepared, boundary_part_id)
		and center_draw_inputs.size() == 1
		and west_support_ranges.size() == 1
		and west_support_ranges[0].get("supportSectionKey") == Vector3i.ZERO
		and west_support_ranges[0].get("geometryOwnerSection") == Vector3i(1, 0, 0)
		and center_draw_inputs[0].get("sourcePartId") == boundary_part_id,
		{"status":boundary_sections.get("status", ""),
			"overlapsWestSection":boundary_overlaps_west,
			"westMembers":west_members, "eastMembers":east_members,
			"westGeometryInputCount":west_prepared.get("inputs", []).size(),
			"westSupportRanges":west_support_ranges,
			"centerDrawInputCount":center_draw_inputs.size(),
			"westPreparedMemberIds":west_prepared.get("memberIds", []),
			"eastPreparedMemberIds":east_prepared.get("memberIds", []),
			"westPreparedInputCount":west_prepared.get("inputs", []).size(),
			"eastPreparedInputCount":east_prepared.get("inputs", []).size(),
			"westSupportOwnerSections":west_support_ranges,
			"eastSupportSectionKeys":east_prepared.get(
				"supportRangesBySource", {}).get(boundary_identity, [])})
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
	var receipt_authority := FixtureReceiptAuthority.new()
	world.world_static_section_coordinator = receipt_authority
	var east_receipt := _installed_receipt(Vector3i(1, 0, 0))
	receipt_authority.install(Vector3i(1, 0, 0), east_receipt)
	var boundary_ack := provider.acknowledge_section_install(Vector3i(1, 0, 0),
		String(east_row.get("coverageRevision", "")),
		east_receipt)
	var one_receipt_keeps_boundary_visible: bool = boundary_ack.get("status") == "pending" \
		and boundary_mesh.visible \
		and not boundary_ack.get("visualClosures", []).is_empty()
	var west_receipt := _installed_receipt(Vector3i.ZERO)
	receipt_authority.install(Vector3i.ZERO, west_receipt)
	var west_ack := provider.acknowledge_section_install(Vector3i.ZERO,
		String(west_row.get("coverageRevision", "")), west_receipt)
	var pending_closures: Array = boundary_ack.get("visualClosures", [])
	var pending_closure: Dictionary = pending_closures[0] \
		if not pending_closures.is_empty() else {}
	check("all_current_section_receipts_close_cross_section_visual_retirement",
		west_ack.get("status") == "acknowledged" and not boundary_mesh.visible,
		{"status":west_ack.get("status", ""),
			"reason":west_ack.get("reason", ""),
			"visible":boundary_mesh.visible,
			"retiredVisualCount":west_ack.get("retiredVisualCount", 0)})
	check("one_live_section_receipt_cannot_retire_cross_section_visual",
		one_receipt_keeps_boundary_visible,
		{"status":boundary_ack.get("status", ""),
			"reason":boundary_ack.get("reason", ""),
			"visibleAfterFirstReceipt":one_receipt_keeps_boundary_visible,
			"requiredSections":pending_closure.get("requiredSections", []),
			"waitingSections":pending_closure.get("waitingSections", [])})
	var release_supported := provider.has_method("release_section_install")
	check("ordinary_provider_exposes_exact_release_lifecycle", release_supported, {})
	if release_supported:
		var gameplay_owner: Node = boundary_mesh.get_parent()
		var owner_children_before := gameplay_owner.get_child_count()
		var rebound: Dictionary = provider.configure("seed:replacement-world", system, world)
		check("bound_provider_rejects_cross_world_reuse_without_changing_claim",
			rebound.get("status") == "failed"
			and provider._installed_members_by_section.has("0,0,0"), rebound)
		var distinct_visual := MeshInstance3D.new()
		distinct_visual.mesh = boundary_mesh.mesh
		distinct_visual.visible = false
		distinct_visual.set_meta("ordinary_structure_section_owned", true)
		world.add_child(distinct_visual)
		distinct_visual.global_transform = boundary_mesh.global_transform
		var invalid_release: Dictionary = provider.call("release_section_install",
			Vector3i.ZERO, String(west_row.coverageRevision), {})
		var wrong_coverage: Dictionary = provider.call("release_section_install",
			Vector3i.ZERO, "wrong-coverage", west_receipt)
		check("invalid_or_wrong_coverage_release_preserves_current_claim",
			invalid_release.get("status") == "pending"
			and wrong_coverage.get("status") == "acknowledged"
			and provider._installed_members_by_section.has("0,0,0")
			and not boundary_mesh.visible, invalid_release)
		var replacement_receipt := west_receipt.duplicate(true)
		replacement_receipt["generation"] = 2
		replacement_receipt.make_read_only()
		receipt_authority.install(Vector3i.ZERO, replacement_receipt)
		provider.acknowledge_section_install(Vector3i.ZERO,
			String(west_row.coverageRevision), replacement_receipt)
		var foreign_owner_receipt := replacement_receipt.duplicate(true)
		foreign_owner_receipt["chunkInstanceId"] = 987654
		foreign_owner_receipt.make_read_only()
		var foreign_release: Dictionary = provider.call("release_section_install",
			Vector3i.ZERO, String(west_row.coverageRevision), foreign_owner_receipt)
		check("different_renderer_owner_cannot_release_identical_geometry_claim",
			foreign_release.get("status") == "acknowledged" and not boundary_mesh.visible
			and provider._installed_members_by_section.has("0,0,0"), foreign_release)
		var delayed: Dictionary = provider.call("release_section_install", Vector3i.ZERO,
			String(west_row.coverageRevision), west_receipt)
		check("delayed_old_release_preserves_replacement_and_hidden_visual",
			delayed.get("status") == "acknowledged" and not boundary_mesh.visible
			and provider._installed_members_by_section.has("0,0,0"), delayed)
		receipt_authority.current_receipts.erase(Vector3i.ZERO)
		var released: Dictionary = provider.call("release_section_install", Vector3i.ZERO,
			String(west_row.coverageRevision), replacement_receipt)
		check("support_section_release_restores_crossing_visual_without_freeing_owner",
			released.get("status") == "acknowledged" and boundary_mesh.visible
			and boundary_mesh.get_parent() == gameplay_owner
			and gameplay_owner.get_child_count() == owner_children_before
			and not provider._installed_members_by_section.has("0,0,0"), released)
		check("release_does_not_unhide_distinct_same_geometry_visual",
			boundary_mesh.visible and not distinct_visual.visible
			and distinct_visual.get_parent() == world, released)
		distinct_visual.free()
		receipt_authority.install(Vector3i.ZERO, replacement_receipt)
		var replay: Dictionary = provider.acknowledge_section_install(Vector3i.ZERO,
			String(west_row.coverageRevision), replacement_receipt)
		check("released_section_replay_closes_retirement_again",
			replay.get("status") == "acknowledged" and not boundary_mesh.visible, replay)
		receipt_authority.current_receipts.erase(Vector3i(1, 0, 0))
		var owner_release: Dictionary = provider.call("release_section_install",
			Vector3i(1, 0, 0), String(east_row.coverageRevision), east_receipt)
		receipt_authority.current_receipts.erase(Vector3i.ZERO)
		provider.call("release_section_install", Vector3i.ZERO,
			String(west_row.coverageRevision), replacement_receipt)
		var duplicate_release: Dictionary = provider.call("release_section_install",
			Vector3i.ZERO, String(west_row.coverageRevision), replacement_receipt)
		check("last_release_drops_crossing_closure_and_duplicate_release_is_idempotent",
			owner_release.get("status") == "acknowledged" and boundary_mesh.visible
			and duplicate_release.get("status") == "acknowledged"
			and not provider._visual_retirement_closures.has(str(boundary_mesh.get_instance_id()))
			and not provider._visual_closure_keys_by_section.has("1,0,0"), duplicate_release)
		receipt_authority.install(Vector3i(1, 0, 0), east_receipt)
		provider.acknowledge_section_install(Vector3i(1, 0, 0),
			String(east_row.coverageRevision), east_receipt)
		# Restore the original fixture token before the unchanged tombstone cases.
		receipt_authority.install(Vector3i.ZERO, west_receipt)
		provider.acknowledge_section_install(Vector3i.ZERO,
			String(west_row.coverageRevision), west_receipt)
	var hidden_boundary_sections := _capture_sections_until_settled(provider,
		"seed:ordinary-provider", [Vector3i.ZERO, Vector3i(1, 0, 0)])
	var hidden_sections: Dictionary = hidden_boundary_sections.get("sections", {})
	var hidden_prepared: Dictionary = hidden_boundary_sections.get("preparedSections", {})
	check("retired_boundary_visual_replays_from_actual_mesh_support",
		west_ack.get("status") == "acknowledged"
		and not boundary_mesh.visible
		and hidden_boundary_sections.get("status") == "complete"
		and hidden_sections.get(Vector3i.ZERO, {}).get(
			"sourcePartIds", []).has(boundary_part_id)
		and hidden_sections.get(Vector3i(1, 0, 0), {}).get(
			"sourcePartIds", []).has(boundary_part_id)
		and not _prepared_inputs_contain_source_part(
			hidden_prepared.get(Vector3i.ZERO, {}), boundary_part_id)
		and hidden_prepared.get(Vector3i(1, 0, 0), {}).get("inputs", []).size() == 1,
		{"status":hidden_boundary_sections.get("status", ""),
			"reason":hidden_boundary_sections.get("reason", ""),
			"westAckStatus":west_ack.get("status", ""),
			"westMembers":hidden_sections.get(Vector3i.ZERO, {}).get("sourcePartIds", []),
			"eastMembers":hidden_sections.get(Vector3i(1, 0, 0), {}).get("sourcePartIds", []),
			"westPreparedMemberIds":hidden_prepared.get(Vector3i.ZERO, {}).get("memberIds", []),
			"eastPreparedMemberIds":hidden_prepared.get(Vector3i(1, 0, 0), {}).get("memberIds", []),
			"westPreparedInputCount":hidden_prepared.get(Vector3i.ZERO, {}).get(
				"inputs", []).size(),
			"eastPreparedInputCount":hidden_prepared.get(Vector3i(1, 0, 0), {}).get(
				"inputs", []).size(),
			"westSupportOwnerSections":west_support_ranges,
			"eastSupportSectionKeys":hidden_prepared.get(Vector3i(1, 0, 0), {}).get(
				"supportRangesBySource", {}).get(boundary_identity, [])})
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
	check("boundary_support_and_center_members_retire_with_section_tombstones",
		west_ack.get("status") == "acknowledged"
		and boundary_removal.get("status") == "complete"
		and west_tombstones.size() == 1 and east_tombstones.size() == 1
		and String(west_tombstones[0].get("sourceId", "")) == boundary_part_id
		and String(east_tombstones[0].get("sourceId", "")) == boundary_part_id
		and String(west_tombstones[0].get("sourcePartId", "")) == boundary_part_id
		and String(east_tombstones[0].get("sourcePartId", "")) == boundary_part_id
		and String(west_tombstones[0].get("authoritySourceId", "")) == source_id
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
	var boundary_west_empty_row: Dictionary = boundary_removal.get("sections", {}).get(Vector3i.ZERO, {})
	var west_removal_ack := provider.acknowledge_section_install(Vector3i.ZERO,
		String(boundary_west_empty_row.get("coverageRevision", "")),
		_installed_receipt(Vector3i.ZERO))
	var east_removal_ack := provider.acknowledge_section_install(Vector3i(1, 0, 0),
		String(boundary_empty_row.get("coverageRevision", "")),
		_installed_receipt(Vector3i(1, 0, 0)))
	check("both_support_and_geometry_owner_tombstones_require_live_receipts",
		west_removal_ack.get("status") == "acknowledged"
		and east_removal_ack.get("status") == "acknowledged",
		{"west":west_removal_ack.get("status", ""),
			"east":east_removal_ack.get("status", "")})
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
		and String(unsupported.get("reason", "")) \
		== "ordinary_geometry_dynamic_family_requires_separate_owner",
		unsupported)
	var unknown_cell := Vector3i(4, 0, 4)
	var unknown_body := _make_body(world, source_id, unknown_cell, "futureUnknownBlock")
	unknown_body.position = Vector3(unknown_cell) * world.CELL
	world.add_child(unknown_body)
	world.blocks[unknown_cell] = unknown_body
	system.ordinary_visual_sources[source_id].expected[unknown_cell] = "futureUnknownBlock"
	system.ordinary_visual_sources[source_id].visualRecipeInputs[unknown_cell] = \
		_visual_recipe_input("futureUnknownBlock")
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var unknown_capture := Adapter.capture_block(system, world, source_id, unknown_cell)
	check("unknown_generated_family_stays_pending_instead_of_empty_coverage",
		unknown_capture.get("status") == "pending"
		and String(unknown_capture.get("reason", "")) \
		== "ordinary_geometry_block_family_unknown",
		unknown_capture)

	var removed_key := system._ordinary_visual_block_key(source_id, cell, "stoneBlock")
	system.removed_generated_structure_blocks[removed_key] = true
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var after_remove := _capture_until_pending(provider, "seed:ordinary-provider", Vector3i.ZERO)
	check("durable_removal_keeps_dynamic_chest_pending_for_separate_owner",
		after_remove.get("status") == "pending"
		and String(after_remove.get("reason", "")) == "ordinary_geometry_dynamic_family_requires_separate_owner",
		after_remove)
	# The unsupported chest remains a current census member; remove it as well to
	# expose an explicit empty replacement and the prior installed stone tombstone.
	var chest_key := system._ordinary_visual_block_key(source_id, unsupported_cell, "chest")
	system.removed_generated_structure_blocks[chest_key] = true
	system.ordinary_visual_sources[source_id].revision += 1
	system.ordinary_visual_revision += 1
	var unknown_only_section := _capture_until_pending(provider,
		"seed:ordinary-provider", Vector3i.ZERO)
	check("unknown_family_alone_cannot_become_empty_section_coverage",
		unknown_only_section.get("status") == "pending"
		and String(unknown_only_section.get("reason", "")) \
		== "ordinary_geometry_block_family_unknown",
		unknown_only_section)
	var unknown_key := system._ordinary_visual_block_key(source_id, unknown_cell,
		"futureUnknownBlock")
	system.removed_generated_structure_blocks[unknown_key] = true
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
	await _run_opaque_family_provider_receipt_integration()
	_run_ordinary_geometry_owner_support_lease_contract()

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


func _prepared_inputs_contain_source_part(prepared: Dictionary,
		source_part_id: String) -> bool:
	for input_value: Variant in prepared.get("inputs", []):
		if input_value is Dictionary \
				and String(input_value.get("sourcePartId", "")) == source_part_id:
			return true
	return false


func _run_ordinary_geometry_owner_support_lease_contract() -> void:
	var coordinator = FixtureLeaseCoordinator.new()
	var owner_section := Vector3i(1, 0, 1)
	var support_a := Vector3i.ZERO
	var support_b := Vector3i(1, 0, 0)
	var owner_cell: Vector2i = Grid.chunk_key_for_section(owner_section)
	var source_id := "ordinary-structure:test-building"
	var source_revision := "ordinary-revision-7"
	var member_id := "ordinary:test-building:segment:roof"
	var receipt_owner := {"generation":17, "sectionKey":owner_section}
	var world_bounds := AABB(Vector3(20, 1, 20), Vector3(4, 2, 4))
	var mesh_digest := "ab".repeat(32)
	var geometry_range := {"sourceId":source_id, "sourcePartId":source_id,
		"sourceRevision":source_revision, "sourceSegmentId":member_id, "sourceInstance":0,
		"geometryOwnerSection":owner_section, "worldBounds":world_bounds,
		"meshContentDigest":mesh_digest}
	var owner_manifest := {"sourceId":source_id, "sourcePartId":source_id,
		"sourceRevision":source_revision, "geometrySourceRanges":[geometry_range]}
	var old_owner_candidate := {"generation":17,
		"drawCount":1, "candidate":{"snapshot":{"manifest":[owner_manifest]}}}
	coordinator._production_candidates_by_section[owner_section] = old_owner_candidate
	coordinator._production_candidate_receipts[owner_section] = receipt_owner
	coordinator._committed_candidates[owner_section] = {"generation":17,
		"packetDigest":"old-valid-render"}
	var support_rows: Dictionary = {}
	for support_section: Vector3i in [support_a, support_b]:
		support_rows[support_section] = {
			"ownershipPolicy":"ordinary_center_geometry_owner/aabb_support_sections_v1",
			"supportSectionKey":support_section, "geometryOwnerSection":owner_section,
			"memberId":member_id, "sourceSegmentId":member_id,
			"sourceRevision":source_revision, "sourceId":source_id, "sourcePartId":source_id,
			"sourceInstance":0, "worldBounds":world_bounds, "meshContentDigest":mesh_digest}
	for support_section: Vector3i in [support_a, support_b]:
		var receipt := {"generation":23, "sectionKey":support_section}
		var manifest_row := {"sourceId":source_id, "sourceRevision":source_revision,
			"supportRanges":[support_rows[support_section]]}
		coordinator._visible_section_demands[support_section] = {
			"stage":"installed", "supportDemands":{}}
		coordinator._production_candidates_by_section[support_section] = {
			"generation":23, "candidate":{"snapshot":{"manifest":[manifest_row]}}}
		coordinator._production_candidate_receipts[support_section] = receipt
	var first := coordinator.reconcile_ordinary_geometry_support_owner_demands()
	var owner_state: Dictionary = coordinator._visible_section_demands.get(owner_section, {})
	var initial_support_count: int = owner_state.get("supportDemands", {}).size()
	var initial_draw_count: int = int(old_owner_candidate.get("drawCount", 0))
	var old_candidate_retained: bool = coordinator._production_candidates_by_section.get(
		owner_section, {}) == old_owner_candidate \
		and coordinator._committed_candidates.get(owner_section, {}).get("packetDigest", "") \
			== "old-valid-render"
	var withdrawn := coordinator.withdraw_visible_section_demand(owner_section)
	var still_resident: bool = coordinator._visible_section_demands.has(owner_section) \
		and coordinator._production_candidates_by_section.has(owner_section)
	check("ordinary_support_sections_share_one_retained_geometry_owner_draw",
		first.get("status") == "ready" and first.get("ownerCells", {}).has(owner_cell)
		and initial_support_count == 2 and initial_draw_count == 1
		and old_candidate_retained and withdrawn.get("status") == "retained_by_support_lease"
		and withdrawn.get("supportDemandCount") == 2 and still_resident,
		{"status":first.get("status", ""), "ownerCell":owner_cell,
			"supportDemandCount":initial_support_count, "drawCount":initial_draw_count,
			"withdrawStatus":withdrawn.get("status", ""),
			"oldRenderRetained":old_candidate_retained})
	for field: String in ["sourceSegmentId", "sourceInstance", "meshContentDigest", "worldBounds", "sourceRevision"]:
		var stale_support: Dictionary = support_rows[support_a].duplicate(false)
		match field:
			"sourceInstance": stale_support[field] = 99
			"worldBounds": stale_support[field] = AABB(Vector3.ZERO, Vector3.ONE)
			_: stale_support[field] = "wrong-value"
		check("installed_owner_geometry_rejects_wrong_" + field,
			not CoordinatorScript._static_geometry_support_matches_proof(stale_support, geometry_range),
			{"field":field})
	owner_manifest["geometrySourceRanges"] = []
	var missing_owner_geometry := coordinator.reconcile_ordinary_geometry_support_owner_demands()
	check("current_native_receipt_without_matching_owner_geometry_stays_pending",
		missing_owner_geometry.get("status") == "pending"
		and missing_owner_geometry.get("waitingOwnerSections", {}).has(owner_section)
		and missing_owner_geometry.get("ownerCells", {}).has(owner_cell), missing_owner_geometry)
	owner_manifest["geometrySourceRanges"] = [geometry_range]
	coordinator.stale_receipts[support_a] = true
	var after_stale := coordinator.reconcile_ordinary_geometry_support_owner_demands()
	owner_state = coordinator._visible_section_demands.get(owner_section, {})
	var count_after_stale: int = owner_state.get("supportDemands", {}).size()
	check("stale_support_receipt_releases_only_its_ordinary_owner_lease",
		after_stale.get("ownerCells", {}).has(owner_cell) and count_after_stale == 1
		and coordinator._production_candidates_by_section.has(owner_section),
		{"ownerCells":after_stale.get("ownerCells", {}).keys(),
			"remainingLeaseCount":count_after_stale,
			"oldRenderRetained":coordinator._production_candidates_by_section.has(owner_section)})
	coordinator._visible_section_demands.erase(support_b)
	coordinator._production_candidate_receipts.erase(support_b)
	coordinator.fail_next_release = true
	var failed_release := coordinator.reconcile_ordinary_geometry_support_owner_demands()
	check("failed_support_release_retains_retry_and_owner_residency",
		failed_release.get("status") == "pending"
		and failed_release.get("ownerCells", {}).has(owner_cell)
		and coordinator._ordinary_geometry_owner_support_demands.size() == 1
		and coordinator._visible_section_demands.get(owner_section, {}).get("supportDemands", {}).size() == 1,
		failed_release)
	var after_last_support_unload := coordinator.reconcile_ordinary_geometry_support_owner_demands()
	check("owner_renderer_demand_releases_after_last_support_unloads",
		after_last_support_unload.get("ownerCells", {}).is_empty()
		and not coordinator._visible_section_demands.has(owner_section)
		and coordinator._production_candidates_by_section.has(owner_section),
		{"ownerCells":after_last_support_unload.get("ownerCells", {}).keys(),
			"ownerDemandRetained":coordinator._visible_section_demands.has(owner_section),
			"oldRenderRetainedUntilOwnerRetirement":coordinator._production_candidates_by_section.has(
				owner_section)})


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


func _run_opaque_family_provider_receipt_integration() -> void:
	var family_world := FixtureMain.new()
	root.add_child(family_world)
	for z in range(-2, 2):
		for x in range(-2, 2):
			family_world.town_region_cache[Vector2i(x, z)] = {}
	family_world.town_region_cache[Vector2i.ZERO] = {
		"key":"0,0", "x":-4, "z":-4, "width":24, "depth":24}
	var family_system := FixtureStructure.new()
	family_system.main = family_world
	var source_id := "town:0,0"
	var block_types: Array[String] = ["cobblestonePath", "stoneBlock", "woodBlock",
		"workbench", "bed", "traderStall", "spikeTrap", "copperVein", "ironVein"]
	var expected_member_counts := {"cobblestonePath":1, "stoneBlock":1,
		"woodBlock":1, "workbench":9, "bed":4, "traderStall":11,
		"spikeTrap":10, "copperVein":6, "ironVein":6}
	var expected_cells: Dictionary = {}
	var recipe_inputs: Dictionary = {}
	var cell_positions: Array[Vector3i] = [Vector3i(2, 4, 2), Vector3i(5, 4, 2),
		Vector3i(8, 4, 2), Vector3i(11, 4, 2), Vector3i(14, 4, 2),
		Vector3i(2, 4, 5), Vector3i(5, 4, 5), Vector3i(8, 4, 5),
		Vector3i(11, 4, 5)]
	var collision_shapes: Array[CollisionShape3D] = []
	for index in block_types.size():
		var block_type := block_types[index]
		var cell := cell_positions[index]
		var body := _make_body(family_world, source_id, cell, block_type)
		body.position = Vector3(cell) * family_world.CELL
		var profile: Dictionary = family_world.block_collision_profile(block_type)
		var collider_shape := BoxShape3D.new()
		collider_shape.size = profile.get("size", Vector3.ONE * family_world.CELL * 0.96)
		var collider := CollisionShape3D.new()
		collider.shape = collider_shape
		collider.position = profile.get("offset", Vector3.ZERO)
		body.add_child(collider)
		collision_shapes.append(collider)
		family_world.add_child(body)
		family_world.blocks[cell] = body
		expected_cells[cell] = block_type
		recipe_inputs[cell] = _visual_recipe_input(block_type)
	family_system.ordinary_visual_sources[source_id] = {
		"completed":true, "expected":expected_cells,
		"visualRecipeInputs":recipe_inputs, "omitted":{}, "failed":{}, "revision":1}
	var provider := ProviderScript.new()
	var configured: Dictionary = provider.configure("seed:ordinary-family-receipt",
		family_system, family_world)
	var capture := _capture_until_settled(provider, "seed:ordinary-family-receipt",
		Vector3i.ZERO)
	var section_row: Dictionary = capture.get("sections", {}).get(Vector3i.ZERO, {})
	var prepared: Dictionary = capture.get("preparedSections", {}).get(Vector3i.ZERO, {})
	var actual_instance_count := int(prepared.get("inputs", []).size())
	var expected_instance_count := 0
	for count_value: Variant in expected_member_counts.values():
		expected_instance_count += int(count_value)
	var family_manifest_rows: Array[Dictionary] = []
	var all_family_manifests_exact := true
	for index in block_types.size():
		var block_type := block_types[index]
		var cell: Vector3i = cell_positions[index]
		var body := family_world.blocks.get(cell) as StaticBody3D
		var source_part_id := "ordinary:%s:cell:%d,%d,%d" % [source_id,
			cell.x, cell.y, cell.z]
		var owner_input_count := 0
		var owner_inputs_opaque := true
		var owner_inputs_shadow_match := true
		for input_value: Variant in prepared.get("inputs", []):
			if not input_value is Dictionary:
				owner_inputs_opaque = false
				continue
			var input: Dictionary = input_value
			if String(input.get("sourcePartId", "")) != source_part_id:
				continue
			owner_input_count += 1
			owner_inputs_opaque = owner_inputs_opaque \
				and String(input.get("renderLayer", "")) == "opaque" \
				and String(input.get("translucentSortPolicy", "")) == "none"
			var matching_visual: MeshInstance3D
			for child: Node in body.get_children():
				if child is MeshInstance3D and String(child.get_meta(
					"ordinary_structure_recipe_segment_id", "")).is_empty() == false \
					and String(input.get("segmentId", "")).ends_with(":" + String(
						child.get_meta("ordinary_structure_recipe_segment_id", ""))):
					matching_visual = child as MeshInstance3D
					break
			owner_inputs_shadow_match = owner_inputs_shadow_match \
				and is_instance_valid(matching_visual) \
				and bool(input.get("castShadows", false)) \
					== (matching_visual.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		var body_visual_count := 0
		var body_visuals_visible := true
		for child: Node in body.get_children():
			if child is MeshInstance3D:
				body_visual_count += 1
				body_visuals_visible = body_visuals_visible and child.visible
		var expected_count := int(expected_member_counts[block_type])
		var row_passed := owner_input_count == expected_count \
			and body_visual_count == expected_count and owner_inputs_opaque \
			and body_visuals_visible and owner_inputs_shadow_match
		all_family_manifests_exact = all_family_manifests_exact and row_passed
		family_manifest_rows.append({"blockType":block_type,
			"sourcePartId":source_part_id, "inputCount":owner_input_count,
			"expectedInputCount":expected_count,
			"liveRecipeVisualCount":body_visual_count,
			"allInputsOpaque":owner_inputs_opaque,
			"packetShadowsMatchLiveVisuals":owner_inputs_shadow_match,
			"allOldVisualsVisible":body_visuals_visible, "passed":row_passed})
	var members_ready: bool = capture.get("status") == "complete" \
		and configured.get("status") == "ready" \
		and section_row.get("status") == "complete" \
		and section_row.get("sourcePartIds", []).size() == block_types.size() \
		and actual_instance_count == expected_instance_count \
		and prepared.get("preparedSegments", []).size() == expected_instance_count
	var all_visuals_visible_before_ack := true
	var live_collision_count := 0
	for cell_value: Variant in expected_cells:
		var body := family_world.blocks.get(cell_value) as StaticBody3D
		for child: Node in body.get_children():
			if child is MeshInstance3D and not child.visible:
				all_visuals_visible_before_ack = false
			if child is CollisionShape3D and is_instance_valid(child.shape):
				live_collision_count += 1
	check("all_opaque_families_enter_provider_manifest_with_complete_recipe_members",
		members_ready and all_family_manifests_exact and all_visuals_visible_before_ack \
			and live_collision_count == block_types.size(),
		{"status":capture.get("status", ""), "reason":capture.get("reason", ""),
			"sourceCount":section_row.get("sourcePartIds", []).size(),
			"expectedSourceCount":block_types.size(),
			"memberCount":actual_instance_count,
			"expectedMemberCount":expected_instance_count,
			"assetRegistryReady":family_world.static_item_asset_registry.is_ready(),
			"families":family_manifest_rows,
			"allOldVisualsVisibleBeforeAck":all_visuals_visible_before_ack,
			"liveCollisionCount":live_collision_count})
	var coverage_revision := String(section_row.get("coverageRevision", ""))
	var shadow_owner := family_world.blocks.get(cell_positions[7]) as StaticBody3D
	var shadow_visual: MeshInstance3D
	for child: Node in shadow_owner.get_children():
		if child is MeshInstance3D and String(child.get_meta(
			"ordinary_structure_recipe_segment_id", "")) == "ore_glint_-0.18":
			shadow_visual = child as MeshInstance3D
			break
	var original_shadow_setting := shadow_visual.cast_shadow
	shadow_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var stale_shadow_ack: Dictionary = provider.acknowledge_section_install(
		Vector3i.ZERO, coverage_revision, _installed_receipt(Vector3i.ZERO))
	shadow_visual.cast_shadow = original_shadow_setting
	check("live_shadow_policy_change_rejects_stale_install_receipt",
		stale_shadow_ack.get("status") == "pending" \
			and stale_shadow_ack.get("reason") == "ordinary_section_live_visual_member_stale"
			and shadow_visual.cast_shadow == original_shadow_setting,
		stale_shadow_ack)
	var acknowledged: Dictionary = provider.acknowledge_section_install(
		Vector3i.ZERO, coverage_revision, _installed_receipt(Vector3i.ZERO))
	var all_visuals_retired_after_ack := true
	var all_gameplay_owners_retained := true
	var live_collision_count_after_ack := 0
	for cell_value: Variant in expected_cells:
		var body := family_world.blocks.get(cell_value) as StaticBody3D
		all_gameplay_owners_retained = all_gameplay_owners_retained \
			and is_instance_valid(body) and body.is_inside_tree() \
			and body.get_meta("cell", null) == cell_value \
			and family_world.blocks.get(cell_value) == body
		for child: Node in body.get_children():
			if child is MeshInstance3D and child.visible:
				all_visuals_retired_after_ack = false
			if child is CollisionShape3D and is_instance_valid(child.shape):
				live_collision_count_after_ack += 1
	check("only_exact_provider_receipt_retires_family_visuals_and_retains_live_owners",
		acknowledged.get("status") == "acknowledged" \
			and all_visuals_retired_after_ack and all_gameplay_owners_retained \
			and live_collision_count_after_ack == collision_shapes.size(),
		{"status":acknowledged.get("status", ""),
			"reason":acknowledged.get("reason", ""),
			"allReplacementVisualsRetired":all_visuals_retired_after_ack,
			"allGameplayOwnersRetained":all_gameplay_owners_retained,
			"collisionCount":live_collision_count_after_ack,
			"expectedCollisionCount":collision_shapes.size()})
	family_world.queue_free()


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
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if bool(member.get("castShadows", true)) \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	for key in ["assetRegistryReady", "families", "expectedSourceCount",
		"expectedMemberCount", "allOldVisualsVisibleBeforeAck",
		"liveCollisionCount", "allReplacementVisualsRetired",
		"allGameplayOwnersRetained", "collisionCount", "expectedCollisionCount",
		"visible", "retiredVisualCount", "requiredSections", "waitingSections",
		"providerIds", "expectedContributors", "memberId", "rosterMemberIdentity",
		"sourceRevisions",
		"overlapsWestSection", "westMembers", "eastMembers",
		"westGeometryInputCount", "westSupportRanges", "centerDrawInputCount",
		"westPreparedMemberIds", "eastPreparedMemberIds",
		"westPreparedInputCount", "eastPreparedInputCount",
		"westSupportOwnerSections", "eastSupportSectionKeys",
		"sealed", "authorityRevision", "expectedAuthorityRevision", "inputCount",
		"firstInputSource", "expectedMemberId", "compatibilityCount", "resourceCount"]:
		if details.has(key): evidence[key] = details[key]
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
