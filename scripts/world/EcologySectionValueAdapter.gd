extends RefCounted
class_name EcologySectionValueAdapter

## Converts canonical surface-detail instance values into immutable inputs for
## the shared static-section partitioner. This is intentionally not a complete
## ecology provider: current producer snapshots omit compiled tree geometry,
## natural harvestable props, and underground static props, so the full ecology
## census must remain pending.

const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstanceAttributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const TreeAdapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const CitadelGeometryAdapter := preload("res://scripts/world/CitadelSectionGeometryAdapter.gd")

const REQUIRED_ECOLOGY_CATEGORIES := [
	"trees_foliage_geometry",
	"surface_detail_instances",
	"surface_rocks",
	"ore",
	"forage",
	"underground_props"
]
const STATIC_PROP_CATEGORIES := ["surface_rocks", "ore", "forage", "underground_props"]
const TREE_SECTION_SOURCE_REVISION_SCHEMA := "ecology-tree-section-source/v1"
const STATIC_PROP_SECTION_SOURCE_REVISION_SCHEMA := "ecology-static-prop-section-source/v1"

const SCHEMA := "ecology-section-value-adapter/v1"
const PIPELINE_REVISION := "ecology_static_detail_pipeline/v1"
const PROVIDER_ID := "ecology_and_static_props"

var _world_id := ""
var _main_authority_ref: WeakRef
var _latest_by_section: Dictionary = {}


func configure(world_id: String) -> Dictionary:
	if world_id.strip_edges().is_empty():
		return _failed("invalid_ecology_provider_world")
	if not _world_id.is_empty() and _world_id != world_id:
		return _failed("ecology_provider_already_bound")
	if _world_id.is_empty():
		_latest_by_section.clear()
	_world_id = world_id
	return {"status":"ready", "worldId":_world_id}


## Bind the game authority that owns the seeded chunk producer. Membership
## still comes from its finalized value snapshot, not a scene-tree scan.
func bind_main_authority(main: Object) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method("detail_mesh") \
			or not main.has_method("detail_material") \
			or not main.has_method("_ecology_chunk_source_revision"):
		return _failed("ecology_main_authority_contract_missing")
	var previous: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if is_instance_valid(previous) and previous.get_instance_id() != main.get_instance_id():
		return _failed("ecology_main_authority_owner_replaced")
	_main_authority_ref = weakref(main)
	return {"status":"ready", "ownerInstanceId":main.get_instance_id()}


## Implements StaticSectionSourceRoster.capture_method exactly. Missing chunk
## owners, incomplete producer categories, or absent prepared geometry are
## pending; this provider never infers empty from an absent ledger entry.
func capture_static_section_sources(world_id: String,
		requested_sections: Array) -> Dictionary:
	if world_id != _world_id or _world_id.is_empty() or requested_sections.is_empty():
		return _pending("ecology_provider_world_or_query_invalid")
	var sections: Array[Vector3i] = []
	for value: Variant in requested_sections:
		if not value is Vector3i or value in sections:
			return _failed("invalid_or_duplicate_ecology_section")
		sections.append(value)
	var required_chunks: Dictionary = {}
	for section: Vector3i in sections:
		for chunk: Vector2i in Grid.stream_chunk_keys_intersecting_section(section):
			required_chunks[chunk] = true
	var chunk_keys: Array[Vector2i] = []
	for chunk_value: Variant in required_chunks:
		chunk_keys.append(Vector2i(chunk_value))
	chunk_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	var source_revisions: Dictionary = {}
	var members_by_section: Dictionary = {}
	var tombstone_revision_by_source: Dictionary = {}
	var authority_rows: Array = []
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return _pending("ecology_main_authority_unavailable")
	var trees_by_prop_id := _current_tree_publications(main)
	for chunk: Vector2i in chunk_keys:
		var production := _capture_production_chunk(chunk, false)
		if production.get("status") != "ready":
			return production
		var snapshot: Dictionary = production.snapshot
		var removed_ids: Dictionary = production.get("removedPropIds", {})
		var chunk_owner_instance_id := int(production.get("chunkOwnerInstanceId", 0))
		var chunk_to_world: Transform3D = production.get("chunkToWorld", Transform3D.IDENTITY)
		var chunk_candidates: Variant = snapshot.get("candidates", null)
		if not chunk_candidates is Array:
			return _pending("ecology_candidate_membership_snapshot_missing", {"chunk":chunk})
		var category_missing := _missing_categories(snapshot,
			bool(production.get("undergroundRequired", true)))
		if not category_missing.is_empty():
			return _pending("ecology_static_category_coverage_incomplete", {
				"chunk":chunk, "missingCategories":category_missing})
		var scoped_removal_snapshot: Dictionary = production.get("removedSnapshot", {})
		var removal_identity := String(scoped_removal_snapshot.get("contentIdentity", ""))
		if removal_identity.is_empty():
			return _pending("ecology_removed_props_snapshot_identity_missing", {"chunk":chunk})
		authority_rows.append([[chunk.x, chunk.y], chunk_owner_instance_id,
			String(snapshot.get("contentRevision", "")),
			String(snapshot.get("sourceRevision", "")), removal_identity])
		for candidate_value: Variant in snapshot.get("candidates", []):
			if not candidate_value is Dictionary:
				return _pending("ecology_candidate_record_invalid", {"chunk":chunk})
			var candidate: Dictionary = candidate_value
			var candidate_kind := String(candidate.get("kind", ""))
			if candidate_kind == "realized_static_prop" \
					and String(candidate.get("category", "")) == "underground_props" \
					and not bool(production.get("undergroundRequired", true)):
				continue
			var source_id := String(candidate.get("sourceId", ""))
			var prop_id := String(candidate.get("propId", ""))
			# _capture_production_chunk validated every candidate digest before
			# returning this immutable source snapshot. Do not canonicalize/hash
			# the same records again while assigning them to section owners.
			if source_id.is_empty() or String(candidate.get("contentRevision", "")).is_empty():
				return _pending("ecology_candidate_membership_revision_invalid", {
					"chunk":chunk, "sourceId":source_id})
			if not prop_id.is_empty() and removed_ids.has(prop_id):
				tombstone_revision_by_source[source_id] = _value_digest([
					"ecology-removed-source/v1", world_id, source_id, prop_id])
				continue
			var candidate_revision := ""
			var candidate_sections: Array[Vector3i] = []
			match candidate_kind:
				"surface_detail":
					var transform_value: Variant = candidate.get("transform", null)
					var bounds_value: Variant = candidate.get("localBounds", null)
					var detail_mesh_value: Variant = _detail_candidate_mesh_if_current(main, candidate)
					if not transform_value is Transform3D or not _valid_transform(transform_value) \
							or not bounds_value is AABB or not _valid_bounds(bounds_value) \
							or not detail_mesh_value is Mesh:
						return _pending("ecology_surface_detail_candidate_uncompiled", {
							"chunk":chunk, "sourceId":source_id})
					# Match partition ownership from the exact source mesh bounds.
					# Reversing the producer's transformed AABB is lossy for transformed bounds.
					candidate_sections.append(_surface_detail_census_section_key(
						detail_mesh_value as Mesh, chunk_to_world, transform_value))
					candidate_revision = _value_digest([
						"ecology-section-member/v1", world_id,
						String(snapshot.get("sourceRevision", "")),
						String(candidate.get("contentRevision", ""))])
				"realized_static_prop":
					var status := String(candidate.get("renderStatus", ""))
					var transform_value: Variant = candidate.get("transform", null)
					var bounds_value: Variant = candidate.get("localBounds", null)
					var category := String(candidate.get("category", ""))
					if status != "ready" or category not in STATIC_PROP_CATEGORIES \
							or not transform_value is Transform3D or not _valid_transform(transform_value) \
							or not bounds_value is AABB or not _valid_bounds(bounds_value) \
							or not _static_prop_member_values_valid(candidate) \
							or not _static_prop_resources_are_renderable(
								production.get("resourceBindings", {}), candidate):
						return _pending("ecology_static_prop_candidate_incomplete", {
							"chunk":chunk, "sourceId":source_id})
					for member_value: Variant in candidate.get("renderMembers", []):
						var member: Dictionary = member_value
						var member_transform: Transform3D = member.get("transform", Transform3D.IDENTITY)
						var inverse_member_bounds: AABB = member.get("localBounds", AABB())
						# Producer members store meshBounds * memberTransform. Reverse
						# that inverse transform before following the runtime instance.
						var member_mesh_bounds: AABB = member_transform * inverse_member_bounds
						var member_world_transform: Transform3D = chunk_to_world * transform_value * member_transform
						var member_world_bounds: AABB = member_world_transform * member_mesh_bounds
						candidate_sections.append(Grid.key_for_world_position(
							member_world_bounds.get_center()))
					candidate_revision = _static_prop_source_revision(world_id, snapshot,
						candidate)
				"trees_foliage":
					if not _tree_family_proof_valid(snapshot):
						return _pending("ecology_tree_family_membership_proof_unavailable", {"chunk":chunk})
					var transform_value: Variant = candidate.get("transform", null)
					var bounds_value: Variant = candidate.get("localBounds", null)
					if not transform_value is Transform3D or not _valid_transform(transform_value) \
							or not bounds_value is AABB or not _valid_bounds(bounds_value):
						return _pending("ecology_tree_membership_bounds_unavailable", {
							"chunk":chunk, "sourceId":source_id})
					var tree_prop_id := String(candidate.get("propId", ""))
					var tree_publication: Dictionary = trees_by_prop_id.get(tree_prop_id, {})
					var tree_revision := _tree_census_source_revision(candidate,
						tree_publication)
					if tree_revision.is_empty():
						return _pending("ecology_tree_queue_geometry_not_committed", {
							"chunk":chunk, "sourceId":source_id})
					candidate_sections = _tree_census_section_keys(tree_publication)
					if candidate_sections.is_empty():
						return _pending("ecology_tree_queue_geometry_not_committed", {
							"chunk":chunk, "sourceId":source_id})
					candidate_revision = tree_revision
				"_":
					return _pending("ecology_candidate_kind_not_censusable", {
						"chunk":chunk, "sourceId":source_id, "kind":candidate_kind})
			if candidate_sections.is_empty():
				return _pending("ecology_candidate_membership_bounds_empty", {
					"chunk":chunk, "sourceId":source_id})
			for section_key: Vector3i in candidate_sections:
				if section_key in sections:
					if not _append_section_member(members_by_section, source_revisions,
						section_key, source_id, candidate_revision):
						return _failed("ecology_section_source_revision_conflict")
		for tombstone_value: Variant in snapshot.get("tombstones", []):
			if tombstone_value is Dictionary:
				var tombstone_source_id := String(tombstone_value.get("sourceId", ""))
				if not tombstone_source_id.is_empty():
					tombstone_revision_by_source[tombstone_source_id] = _value_digest([
						"ecology-tombstone/v1", world_id, tombstone_source_id,
						String(tombstone_value.get("reason", ""))])
		if not _production_chunk_owner_is_current(main, chunk, production):
			return _pending("ecology_chunk_owner_changed_during_census", {"chunk":chunk})
	var section_rows: Dictionary = {}
	var removals_by_section: Dictionary = {}
	var current_by_section: Dictionary = {}
	for section: Vector3i in sections:
		var ids: Array = members_by_section.get(section, []).duplicate()
		ids.sort()
		ids.make_read_only()
		var digest_rows: Array = []
		for source_id: String in ids:
			digest_rows.append([source_id, String(source_revisions.get(source_id, ""))])
		var coverage_revision := _value_digest([SCHEMA, world_id, section, digest_rows, authority_rows])
		section_rows[section] = {"status":"empty" if ids.is_empty() else "complete",
			"sourcePartIds":ids, "coverageRevision":coverage_revision}
		current_by_section[section] = source_revisions_for_ids(ids, source_revisions)
		var removals: Array[Dictionary] = []
		var previous: Dictionary = _latest_by_section.get(section, {})
		for old_source_id_value: Variant in previous.keys():
			var old_source_id := String(old_source_id_value)
			if ids.has(old_source_id) or source_revisions.has(old_source_id):
				continue
			var removal_revision := String(tombstone_revision_by_source.get(old_source_id, ""))
			if removal_revision.is_empty():
				removal_revision = _value_digest(["ecology-authoritative-absence/v1",
					world_id, old_source_id, authority_rows])
			removals.append({"sourceId":old_source_id, "sourcePartId":old_source_id,
				"sectionKey":section, "sourceRevision":removal_revision})
		removals.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.sourcePartId) < String(b.sourcePartId))
		removals_by_section[section] = removals
	var authority_revision := _value_digest([SCHEMA, world_id, authority_rows, section_rows])
	var requested_source_revisions: Dictionary = {}
	for section: Vector3i in sections:
		for source_id_value: Variant in members_by_section.get(section, []):
			var source_id := String(source_id_value)
			if source_revisions.has(source_id):
				requested_source_revisions[source_id] = source_revisions[source_id]
	for section: Vector3i in sections:
		_latest_by_section[section] = current_by_section.get(section, {})
	section_rows.make_read_only()
	requested_source_revisions.make_read_only()
	removals_by_section.make_read_only()
	return {"status":"complete", "schema":SCHEMA, "providerId":PROVIDER_ID,
		"worldId":world_id, "authorityRevision":authority_revision,
		"sections":section_rows, "sourceRevisions":requested_source_revisions,
		"preparedSections":{}, "removalsBySection":removals_by_section}


## Common-provider contribution for the source values this adapter can render.
## It is usable only after the provider's full static ecology census is complete;
## today's producer snapshot omits tree geometry and other static families, so
## this entry remains retryable pending instead of submitting a partial section.
func capture_static_section_contribution(census: Dictionary,
		section_key: Vector3i) -> Dictionary:
	if census.get("status") != "complete" or census.get("worldId") != _world_id \
			or not census.get("sections", []).has(section_key) \
			or not census.get("sourceProviderIds") is Dictionary \
			or not census.get("sourceRevisions") is Dictionary \
			or not census.get("expectedContributorsBySection") is Dictionary \
			or not census.get("providerCoverageRevisions") is Dictionary \
			or not census.get("providerSnapshotRevisions") is Dictionary:
		return _pending("ecology_contribution_census_unavailable")
	var provider_sources: Array[String] = []
	var expected_values: Variant = census.expectedContributorsBySection.get(section_key, null)
	if not expected_values is Array:
		return _pending("ecology_contribution_section_roster_missing")
	for source_id_value: Variant in expected_values:
		if not source_id_value is String:
			return {"status":"failed", "reason":"ecology_contribution_source_id_invalid"}
		var source_id := String(source_id_value)
		if String(census.sourceProviderIds.get(source_id, "")) == PROVIDER_ID:
			provider_sources.append(source_id)
	provider_sources.sort()
	var coverage_by_provider: Variant = census.providerCoverageRevisions.get(PROVIDER_ID, null)
	if not coverage_by_provider is Dictionary:
		return _pending("ecology_contribution_coverage_revision_missing")
	var coverage_revision := String(coverage_by_provider.get(section_key, ""))
	var authority_revision := String(census.providerSnapshotRevisions.get(PROVIDER_ID, ""))
	if coverage_revision.is_empty() or authority_revision.is_empty():
		return _pending("ecology_contribution_coverage_revision_missing")
	var detail_inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var mesh_bindings: Dictionary = {}
	var material_bindings: Dictionary = {}
	var represented_sources: Dictionary = {}
	var captured_source_revisions: Dictionary = {}
	for chunk: Vector2i in _chunks_for_section(section_key):
		var production := _capture_production_chunk(chunk)
		if production.get("status") != "ready":
			return production
		var removed_ids: Dictionary = production.get("removedPropIds", {})
		var prepared := prepare_surface_detail(production.snapshot,
			production.bindings, production.chunkToWorld, _world_id,
			production.unsupportedDetailTypes,
			bool(production.get("undergroundRequired", true)), removed_ids)
		if prepared.get("status") != "prepared" \
				or not prepared.get("unsupportedCandidateIds", []).is_empty():
			return _pending("ecology_surface_detail_candidate_unrenderable", {
				"chunk":chunk,
				"unsupportedCandidateIds":prepared.get("unsupportedCandidateIds", [])})
		if not _tree_family_proof_valid(production.snapshot):
			return _pending("ecology_tree_family_membership_proof_unavailable", {"chunk":chunk})
		if not prepared.get("missingCategories", []).is_empty():
			return _pending("ecology_static_category_coverage_incomplete", {
				"chunk":chunk, "missingCategories":prepared.missingCategories})
		for input_value: Variant in prepared.get("inputs", []):
			var input: Dictionary = input_value
			var source_id := String(input.get("sourceId", ""))
			if not provider_sources.has(source_id):
				continue
			if represented_sources.has(source_id):
				return {"status":"failed", "reason":"ecology_contribution_duplicate_source"}
			represented_sources[source_id] = true
			detail_inputs.append(input)
			captured_source_revisions[source_id] = String(
				prepared.get("sourceRevisions", {}).get(source_id, ""))
		var static_prepared := _prepare_realized_static_props(production.snapshot,
			production.get("resourceBindings", {}), production.chunkToWorld, _world_id,
			bool(production.get("undergroundRequired", true)), removed_ids)
		if static_prepared.get("status") != "ready":
			return static_prepared
		for input_value: Variant in static_prepared.get("inputs", []):
			if not input_value is Dictionary:
				continue
			var static_input: Dictionary = input_value
			var source_id := String(static_input.get("sourceId", ""))
			if Vector3i(static_input.get("sectionKey", Vector3i.ZERO)) != section_key \
					or not provider_sources.has(source_id):
				continue
			if represented_sources.has(source_id):
				# One prop can contribute multiple mesh members to one section.
				if String(captured_source_revisions.get(source_id, "")) \
						!= String(static_input.get("sourceRevision", "")):
					return {"status":"failed", "reason":"ecology_contribution_duplicate_source_revision"}
			else:
				represented_sources[source_id] = true
				captured_source_revisions[source_id] = String(static_input.get("sourceRevision", ""))
			var contribution_input: Dictionary = static_input.duplicate(false)
			contribution_input.erase("sectionKey")
			contribution_input.make_read_only()
			detail_inputs.append(contribution_input)
		for batch_key_value: Variant in static_prepared.get("compatibilityByKey", {}):
			var batch_key := String(batch_key_value)
			var static_compatibility: Dictionary = static_prepared.compatibilityByKey[batch_key_value]
			if compatibility_by_key.has(batch_key) \
					and compatibility_by_key[batch_key] != static_compatibility:
				return {"status":"failed", "reason":"ecology_contribution_batch_conflict"}
			compatibility_by_key[batch_key] = static_compatibility
		for mesh_key_value: Variant in static_prepared.get("meshBindings", {}):
			mesh_bindings[String(mesh_key_value)] = static_prepared.meshBindings[mesh_key_value]
		for material_key_value: Variant in static_prepared.get("materialBindings", {}):
			material_bindings[String(material_key_value)] = static_prepared.materialBindings[material_key_value]
		for candidate_value: Variant in production.snapshot.get("candidates", []):
			if not candidate_value is Dictionary \
					or String(candidate_value.get("kind", "")) != "trees_foliage":
				continue
			var candidate: Dictionary = candidate_value
			var source_id := String(candidate.get("sourceId", ""))
			var prop_id := String(candidate.get("propId", ""))
			if not prop_id.is_empty() and removed_ids.has(prop_id):
				continue
			if not provider_sources.has(source_id):
				continue
			var tree_capture := _capture_tree_candidate(candidate)
			if tree_capture.get("status") != "ready":
				return tree_capture
			var tree_revision := _tree_section_source_revision(candidate, tree_capture)
			if tree_revision.is_empty():
				return _pending("ecology_tree_source_revision_missing", {"sourceId":source_id})
			if represented_sources.has(source_id):
				return {"status":"failed", "reason":"ecology_contribution_duplicate_source"}
			represented_sources[source_id] = true
			captured_source_revisions[source_id] = tree_revision
			for tree_output_value: Variant in tree_capture.get("partition", {}).get("outputs", []):
				if not tree_output_value is Dictionary \
						or Vector3i(tree_output_value.get("sectionKey", Vector3i.ZERO)) != section_key:
					continue
				var tree_output: Dictionary = tree_output_value
				var tree_segment: Variant = tree_output.get("segment", null)
				if not tree_segment is Dictionary:
					return _pending("ecology_tree_section_partition_output_missing", {
						"sourceId":source_id})
				var section_origin := Grid.origin_for_key(section_key)
				var tree_input := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
					"sourceId":source_id, "sourcePartId":source_id,
					"ownerCell":tree_segment.get("ownerCell", tree_capture.get("ownerCell", Vector2i.ZERO)),
					"sourceToWorld":Transform3D(Basis.IDENTITY, Vector3(section_origin)),
					"sourceRevision":tree_revision,
					"meshLocalBounds":tree_segment.get("meshLocalBounds", AABB()),
					"batchKey":String(tree_output.get("batchKey", "")),
					"segmentId":"tree-section:" + _value_digest([
						source_id, tree_revision, String(tree_output.get("segmentId", ""))]),
					"buffer":tree_segment.get("buffer", []),
					"instanceCount":int(tree_segment.get("instanceCount", 0))}
				tree_input.make_read_only()
				detail_inputs.append(tree_input)
			for batch_key_value: Variant in tree_capture.get("compatibilityByKey", {}):
				var batch_key := String(batch_key_value)
				var tree_compatibility: Dictionary = tree_capture.compatibilityByKey[batch_key_value]
				if compatibility_by_key.has(batch_key) \
						and compatibility_by_key[batch_key] != tree_compatibility:
					return {"status":"failed", "reason":"ecology_contribution_batch_conflict"}
				compatibility_by_key[batch_key] = tree_compatibility
			for mesh_key_value: Variant in tree_capture.get("meshBindings", {}):
				mesh_bindings[String(mesh_key_value)] = tree_capture.meshBindings[mesh_key_value]
			for material_key_value: Variant in tree_capture.get("materialBindings", {}):
				material_bindings[String(material_key_value)] = tree_capture.materialBindings[material_key_value]
		for batch_key_value: Variant in prepared.compatibilityByKey:
			var batch_key := String(batch_key_value)
			if compatibility_by_key.has(batch_key) \
					and compatibility_by_key[batch_key] != prepared.compatibilityByKey[batch_key]:
				return {"status":"failed", "reason":"ecology_contribution_batch_conflict"}
			compatibility_by_key[batch_key] = prepared.compatibilityByKey[batch_key]
		for mesh_key_value: Variant in prepared.meshBindings:
			mesh_bindings[String(mesh_key_value)] = prepared.meshBindings[mesh_key_value]
		for material_key_value: Variant in prepared.materialBindings:
			material_bindings[String(material_key_value)] = prepared.materialBindings[material_key_value]
	for source_id: String in provider_sources:
		if not represented_sources.has(source_id):
			return _pending("ecology_contribution_member_value_missing", {"sourceId":source_id})
	detail_inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if String(a.sourceId) != String(b.sourceId):
			return String(a.sourceId) < String(b.sourceId)
		return String(a.segmentId) < String(b.segmentId))
	var authority_source_revisions: Dictionary = {}
	for source_id: String in provider_sources:
		var revision := String(census.sourceRevisions.get(source_id, ""))
		if revision.is_empty():
			return _pending("ecology_contribution_member_revision_missing", {"sourceId":source_id})
		var captured_revision := String(captured_source_revisions.get(source_id, ""))
		if captured_revision != revision:
			return _pending("ecology_contribution_member_revision_stale", {
				"sourceId":source_id})
		authority_source_revisions[source_id] = revision
	detail_inputs.make_read_only()
	authority_source_revisions.make_read_only()
	compatibility_by_key.make_read_only()
	mesh_bindings.make_read_only()
	material_bindings.make_read_only()
	var contribution := {"providerId":PROVIDER_ID, "sectionKey":section_key,
		"coverageRevision":coverage_revision, "authorityRevision":authority_revision,
		"authoritySourceRevisions":authority_source_revisions,
		"inputs":detail_inputs, "compatibilityByKey":compatibility_by_key,
		"materialBindings":material_bindings, "meshBindings":mesh_bindings,
		"resourceBindings":{}}
	contribution.resourceBindings.make_read_only()
	contribution.make_read_only()
	return {"status":"ready", "contribution":contribution}


func _chunks_for_section(section_key: Vector3i) -> Array[Vector2i]:
	var unique: Dictionary = {}
	for chunk_value: Variant in Grid.stream_chunk_keys_intersecting_section(section_key):
		if chunk_value is Vector2i:
			unique[chunk_value] = true
	var result: Array[Vector2i] = []
	for chunk_value: Variant in unique:
		result.append(Vector2i(chunk_value))
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	return result


func _capture_tree_candidate(candidate: Dictionary) -> Dictionary:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return _pending("ecology_main_authority_unavailable")
	var queue: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue):
		return _pending("ecology_tree_publication_queue_unavailable")
	var prop_id := String(candidate.get("propId", ""))
	var source_id := String(candidate.get("sourceId", ""))
	if prop_id.is_empty() or source_id.is_empty():
		return _pending("ecology_tree_candidate_identity_missing")
	var records_value: Variant = queue.get("published_lod_records")
	if not records_value is Array:
		return _pending("ecology_tree_queue_records_unavailable")
	var body: StaticBody3D
	for record_value: Variant in records_value:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		var request_value: Variant = record.get("request", {})
		var body_ref := record.get("body") as WeakRef
		var record_body: Variant = body_ref.get_ref() if body_ref != null else null
		if request_value is Dictionary and String(request_value.get("treeId", "")) == prop_id \
				and is_instance_valid(record_body) \
				and int(record.get("bodyInstanceId", 0)) == record_body.get_instance_id() \
				and String(record_body.get_meta("prop_id", "")) == prop_id:
			body = record_body as StaticBody3D
			break
	if not is_instance_valid(body):
		return _pending("ecology_tree_queue_geometry_not_committed", {"sourceId":source_id})
	var removed_snapshot := RemovedProps.capture_for_ids(main, [prop_id])
	if not bool(removed_snapshot.get("ok", false)):
		return _pending("ecology_tree_removed_props_snapshot_unavailable", {"sourceId":source_id})
	var captured: Dictionary = TreeAdapter.capture_from_queue_record(queue, main, _world_id,
		body, removed_snapshot)
	if captured.get("status") == "ready":
		captured["bodyGlobalTransform"] = body.global_transform
		captured["bodyInstanceId"] = body.get_instance_id()
	return captured


## Build section-local instance inputs from the surface-detail records already
## emitted by the deterministic chunk detail producer. `binding_by_source`
## maps the record's meshSource + material identity to the actual production
## Mesh, stable mesh key, pipeline revision, and material key. No visual Node is
## scanned and no RNG is consumed.
static func prepare_surface_detail(snapshot: Dictionary, binding_by_source: Dictionary,
		chunk_to_world := Transform3D.IDENTITY, world_id := "",
		unsupported_detail_types: Array[String] = [],
		underground_required := true, removed_prop_ids: Dictionary = {}) -> Dictionary:
	var validation := _validate_snapshot(snapshot)
	if validation.get("status") != "ready":
		return validation
	snapshot = _freeze_value(snapshot)
	if not binding_by_source.is_read_only():
		return _failed("mutable_detail_binding_map")
	if world_id.strip_edges().is_empty():
		return _failed("surface_detail_world_identity_missing")
	var chunk_value: Variant = snapshot.get("chunk")
	if not chunk_value is Vector2i:
		return _failed("invalid_ecology_chunk_key")
	var chunk: Vector2i = chunk_value
	var source_revision := String(snapshot.get("sourceRevision", ""))
	if not _valid_transform(chunk_to_world):
		return _failed("invalid_surface_detail_chunk_transform")
	var source_to_world: Transform3D = chunk_to_world
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var material_resources_by_key: Dictionary = {}
	var mesh_resources_by_key: Dictionary = {}
	var source_revisions: Dictionary = {}
	var candidate_ids: Array[String] = []
	var unsupported_candidate_ids: Array[String] = []
	var candidates: Array = snapshot.get("candidates", [])
	for candidate_value: Variant in candidates:
		if not candidate_value is Dictionary:
			return _failed("invalid_ecology_candidate")
		var candidate: Dictionary = candidate_value
		var prop_id := String(candidate.get("propId", ""))
		if not prop_id.is_empty() and removed_prop_ids.has(prop_id):
			continue
		if String(candidate.get("kind", "")) != "surface_detail":
			continue
		var source_id := String(candidate.get("sourceId", ""))
		var detail_type := String(candidate.get("detailType", ""))
		var mesh_source := String(candidate.get("meshSource", ""))
		var candidate_revision := String(candidate.get("contentRevision", ""))
		var transform_value: Variant = candidate.get("transform")
		var bounds_value: Variant = candidate.get("localBounds")
		var layer_values: Variant = candidate.get("renderLayers")
		var material_values: Variant = candidate.get("materials")
		if source_id.is_empty() or detail_type.is_empty() or mesh_source.is_empty() \
				or candidate_revision.is_empty() or not transform_value is Transform3D \
				or not bounds_value is AABB or not layer_values is Array \
				or layer_values.size() != 1 or not material_values is Array \
				or material_values.size() != 1:
			return _failed("incomplete_surface_detail_source_value")
		var stable_id_prefix := "%s:detail:%d,%d:%s:" % [
			String(snapshot.get("worldSeed", "")), chunk.x, chunk.y, detail_type]
		if not source_id.begins_with(stable_id_prefix) \
				or _candidate_digest(candidate) != candidate_revision:
			return _failed("surface_detail_identity_or_revision_mismatch")
		if candidate_ids.has(source_id):
			return _failed("duplicate_surface_detail_source_id")
		candidate_ids.append(source_id)
		if detail_type in unsupported_detail_types:
			unsupported_candidate_ids.append(source_id)
			continue
		var bound_candidate_revision := _value_digest([
			"ecology-section-member/v1", world_id, source_revision,
			candidate_revision])
		if bound_candidate_revision.is_empty():
			return _failed("surface_detail_bound_revision_failed")
		var binding_key := _binding_key(mesh_source, String(material_values[0]))
		var binding_value: Variant = binding_by_source.get(binding_key)
		if not binding_value is Dictionary or not binding_value.is_read_only():
			return _pending("surface_detail_mesh_material_binding_missing", {"sourceId":source_id,
				"bindingKey":binding_key})
		var binding: Dictionary = binding_value
		var mesh_value: Variant = binding.get("mesh")
		var material_value: Variant = binding.get("material")
		var mesh_key := String(binding.get("meshResourceKey", ""))
		var material_key := String(binding.get("materialKey", ""))
		var material_digest := String(binding.get("materialContentDigest", ""))
		var pipeline_revision := String(binding.get("pipelineRevision", PIPELINE_REVISION))
		if not mesh_value is Mesh or not material_value is Material \
				or mesh_key.is_empty() or material_key.is_empty() \
				or material_digest.length() != 64 or not material_digest.is_valid_hex_number(false) \
				or pipeline_revision.is_empty() \
				or material_key != String(material_values[0]) \
				or mesh_source != String(binding.get("meshSource", mesh_source)):
			return _failed("surface_detail_binding_identity_mismatch")
		if _material_digest(material_value) != material_digest:
			return _pending("surface_detail_material_resource_changed", {"sourceId":source_id})
		var render_layer := _supported_surface_detail_layer(material_value,
			String(layer_values[0]))
		if render_layer.is_empty():
			return _pending("surface_detail_render_layer_not_supported", {"sourceId":source_id,
				"renderLayer":String(layer_values[0])})
		var mesh_bounds: AABB = mesh_value.get_aabb()
		if not _valid_bounds(mesh_bounds) or not _valid_transform(transform_value):
			return _failed("invalid_surface_detail_geometry")
		var captured_bounds: AABB = bounds_value
		if not (mesh_bounds * transform_value).is_equal_approx(captured_bounds):
			return _failed("surface_detail_bounds_disagree_with_mesh")
		var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(mesh_value)
		if mesh_fingerprint.get("status") != "ready":
			return _pending("surface_detail_mesh_fingerprint_unavailable", {"sourceId":source_id,
				"reason":String(mesh_fingerprint.get("reason", "unknown"))})
		var digest := String(mesh_fingerprint.get("contentDigest", ""))
		var visibility_end := float(candidate.get("visibilityRangeEnd", 0.0))
		var fade_margin := float(binding.get("fadeMargin", 12.0))
		var cast_shadows := String(candidate.get("shadowCasting", "off")) != "off"
		var compatibility := _compatibility(String(material_values[0]), material_key,
			material_digest,
			mesh_key, digest, pipeline_revision, render_layer, mesh_bounds,
			cast_shadows, visibility_end, fade_margin)
		if compatibility.is_empty():
			return _failed("surface_detail_compatibility_invalid")
		var batch_key := String(compatibility.batchKey)
		if compatibility_by_key.has(batch_key) and compatibility_by_key[batch_key] != compatibility:
			return _failed("surface_detail_batch_compatibility_conflict")
		compatibility_by_key[batch_key] = compatibility
		material_resources_by_key[String(compatibility.materialKey)] = binding.get("material")
		mesh_resources_by_key[mesh_key] = mesh_value
		var transform: Transform3D = transform_value
		var color_value: Variant = candidate.get("instanceColor")
		var custom_value: Variant = candidate.get("customData")
		if not color_value is Color or not custom_value is Color:
			return _failed("surface_detail_instance_variation_missing")
		var instance_buffer := _encode_instance(transform, custom_value, color_value)
		instance_buffer.make_read_only()
		var instance_input := {
			"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
			"sourceId":source_id,
			"sourcePartId":source_id,
			"sourceRevision":bound_candidate_revision,
			"ownerCell":chunk,
			"sourceToWorld":source_to_world,
			"meshLocalBounds":mesh_bounds,
			"batchKey":batch_key,
			"segmentId":"ecology-detail:" + (source_id + "\n" + bound_candidate_revision).sha256_text(),
			"buffer":instance_buffer,
			"instanceCount":1
		}
		instance_input.make_read_only()
		inputs.append(instance_input)
		source_revisions[source_id] = bound_candidate_revision
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.sourceId) < String(b.sourceId))
	inputs.make_read_only()
	compatibility_by_key.make_read_only()
	material_resources_by_key.make_read_only()
	mesh_resources_by_key.make_read_only()
	source_revisions.make_read_only()
	var partition_result: Dictionary = {}
	if inputs.is_empty():
		partition_result = {"status":"ready", "outputs":[], "sourceRevisions":{},
			"impactedSectionKeys":[], "inputInstanceCount":0, "outputInstanceCount":0}
	else:
		var partition_envelope: Dictionary = Partitioner.partition(inputs)
		if partition_envelope.get("status") != "ready":
			return _failed("surface_detail_partition_failed:" + String(partition_envelope.get("reason", "unknown")))
		partition_result = partition_envelope.get("result", {})
		if not partition_result is Dictionary or not partition_result.is_read_only():
			return _failed("surface_detail_partition_result_invalid")
	var sections := _section_membership(partition_result.get("outputs", []))
	return {
		"status":"prepared" if unsupported_candidate_ids.is_empty() else "prepared_partial",
		"schema":SCHEMA,
		"producerRevision":source_revision,
		"chunk":chunk,
		"candidateIds":candidate_ids,
		"unsupportedCandidateIds":unsupported_candidate_ids,
		"inputs":inputs,
		"partition":partition_result,
		"compatibilityByKey":compatibility_by_key,
		"materialBindings":material_resources_by_key,
		"meshBindings":mesh_resources_by_key,
		"sourceRevisions":source_revisions,
		"sections":sections,
		"censusStatus":"pending",
		"censusReason":"ecology_static_category_coverage_incomplete",
		"missingCategories":_missing_categories(snapshot, underground_required)
	}


## The complete domain provider must account for all deterministic static
## ecology sources, including explicit empties. Current producer snapshots are
## partial, so this response fails closed even when surface detail is compiled.
static func _validate_snapshot(snapshot: Dictionary) -> Dictionary:
	if String(snapshot.get("schema", "")) != "ecology-source-values/v1" \
			or String(snapshot.get("worldSeed", "")).is_empty() \
			or not snapshot.get("chunk") is Vector2i \
			or String(snapshot.get("sourceRevision", "")).is_empty() \
			or String(snapshot.get("contentRevision", "")).is_empty() \
			or not snapshot.get("candidates") is Array:
		return _failed("invalid_or_mutable_ecology_source_snapshot")
	for candidate_value: Variant in snapshot.candidates:
		if not candidate_value is Dictionary:
			return _failed("mutable_or_invalid_ecology_candidate")
		if String(candidate_value.get("contentRevision", "")) != _candidate_digest(candidate_value):
			return _failed("ecology_candidate_revision_mismatch")
	var snapshot_copy := snapshot.duplicate(true)
	var expected_snapshot_revision := String(snapshot_copy.get("contentRevision", ""))
	snapshot_copy.erase("contentRevision")
	# MainPlaytestTools adds this lifecycle field after the producer ledger has
	# sealed its digest. Freshness is checked against the live source authority,
	# never accepted from this advisory marker.
	snapshot_copy.erase("status")
	# Runtime ownership is validated separately from deterministic content.
	snapshot_copy.erase("producerOwnerInstanceId")
	if expected_snapshot_revision != _value_digest(snapshot_copy):
		return _failed("ecology_snapshot_revision_mismatch")
	return {"status":"ready"}


static func _freeze_value(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen: Dictionary = {}
		for key: Variant in value:
			frozen[key] = _freeze_value(value[key])
		frozen.make_read_only()
		return frozen
	if value is Array:
		var frozen: Array = []
		for item: Variant in value:
			frozen.append(_freeze_value(item))
		frozen.make_read_only()
		return frozen
	return value


static func _missing_categories(snapshot: Dictionary,
		underground_required := true) -> Array[String]:
	var available: Array = snapshot.get("coverage", [])
	var complete: Variant = snapshot.get("completeCategories", [])
	var missing: Array[String] = []
	for category: String in REQUIRED_ECOLOGY_CATEGORIES:
		if category == "underground_props" and not underground_required:
			continue
		var covered: bool = category in available or category in complete
		if category == "trees_foliage_geometry":
			covered = _tree_family_proof_valid(snapshot)
		if not covered:
			missing.append(category)
	return missing


static func _section_membership(outputs: Array) -> Dictionary:
	var members: Dictionary = {}
	var revisions: Dictionary = {}
	for output_value: Variant in outputs:
		if not output_value is Dictionary:
			continue
		var output: Dictionary = output_value
		var key: Variant = output.get("sectionKey")
		var source_id := String(output.get("sourceId", ""))
		if not key is Vector3i or source_id.is_empty():
			continue
		if not members.has(key):
			members[key] = []
		members[key].append(source_id)
		revisions[source_id] = String(output.get("sourceRevision", ""))
	var keys: Array = members.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var sealed: Dictionary = {}
	for key: Vector3i in keys:
		var ids: Array = members[key]
		ids.sort()
		ids.make_read_only()
		var digest_rows: Array = []
		for source_id: String in ids:
			digest_rows.append([source_id, String(revisions[source_id])])
		sealed[key] = {"status":"complete", "sourcePartIds":ids,
			"coverageRevision":JSON.stringify([key.x, key.y, key.z, digest_rows]).sha256_text()}
		sealed[key].make_read_only()
	sealed.make_read_only()
	return sealed


static func _binding_key(mesh_source: String, material_id: String) -> String:
	return mesh_source + "|" + material_id


static func _render_layer(producer_layer: String) -> String:
	if producer_layer == "alpha_scissor":
		return "cutout"
	if producer_layer == "opaque":
		return "opaque"
	return ""


static func _encode_instance(transform: Transform3D, custom: Color, color: Color) -> Array[float]:
	var encoded: PackedFloat32Array = InstanceAttributes.encode(transform, custom, color)
	var result: Array[float] = []
	for value: float in encoded:
		result.append(value)
	return result


static func _compatibility(producer_material: String, material_key: String,
		material_content_digest: String, mesh_resource_key: String,
		mesh_digest: String, pipeline_revision: String,
		render_layer: String, mesh_bounds: AABB, cast_shadows: bool,
		visibility_end: float, fade_margin: float) -> Dictionary:
	if producer_material.is_empty() or material_key.is_empty() \
			or material_content_digest.length() != 64 \
			or not material_content_digest.is_valid_hex_number(false) \
			or mesh_resource_key.is_empty() \
			or mesh_digest.length() != 64 or pipeline_revision.is_empty() \
			or render_layer not in ["opaque", "cutout"] or not _valid_bounds(mesh_bounds) \
			or visibility_end < 0.0 or fade_margin < 0.0:
		return {}
	var mesh_key := "%s|pipeline=%s|layer=%s|sort=none" % [
		mesh_resource_key, pipeline_revision, render_layer]
	var result := {"materialKey":material_key + "|sha256=" + material_content_digest,
		# Native section backend tiers are silhouette/structural/detail/horizon.
		# Surface-detail meshes use the shared detail budget even though their
		# source authority is environment ecology.
		"renderTier":"detail",
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"meshResourceKey":mesh_resource_key, "meshKey":mesh_key,
		"meshContentDigest":mesh_digest, "meshLocalBounds":mesh_bounds,
		"pipelineRevision":pipeline_revision, "renderLayer":render_layer,
		"translucentSortPolicy":"none", "castShadows":cast_shadows,
		"visibilityRangeEnd":visibility_end, "fadeMargin":fade_margin,
		"batchKey":"", "compatibilityKey":""}
	var batch_key := SnapshotBuilder.batch_compatibility_key(result)
	if batch_key.is_empty():
		return {}
	result["batchKey"] = batch_key
	result["compatibilityKey"] = batch_key
	result.make_read_only()
	return result


func _capture_production_chunk(chunk_key: Vector2i,
		include_resource_bindings := true) -> Dictionary:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return _pending("ecology_main_authority_unavailable", {"chunk":chunk_key})
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary:
		return _pending("ecology_chunk_owner_map_unavailable", {"chunk":chunk_key})
	var chunk_node: Node3D = chunks_value.get(chunk_key) as Node3D
	if not is_instance_valid(chunk_node):
		return _pending("ecology_chunk_owner_unavailable", {"chunk":chunk_key})
	var snapshot_value: Variant = chunk_node.get_meta("static_ecology_source_value_snapshot", {})
	if not snapshot_value is Dictionary:
		return _pending("ecology_chunk_source_snapshot_missing_or_stale", {"chunk":chunk_key})
	var snapshot: Dictionary = snapshot_value
	var candidate_prop_ids: Array[String] = []
	for candidate_value: Variant in snapshot.get("candidates", []):
		if not candidate_value is Dictionary:
			continue
		var candidate_prop_id := String(candidate_value.get("propId", ""))
		if not candidate_prop_id.is_empty() and candidate_prop_id not in candidate_prop_ids:
			candidate_prop_ids.append(candidate_prop_id)
	var removed_snapshot := RemovedProps.capture_for_ids(main, candidate_prop_ids)
	if not bool(removed_snapshot.get("ok", false)):
		return _pending("ecology_removed_props_snapshot_unavailable", {"chunk":chunk_key})
	var underground_required := true
	if main.has_method("visible_world_underground_visuals_required"):
		underground_required = bool(main.call("visible_world_underground_visuals_required"))
	if String(snapshot.get("contentScope", "complete")) == "surface_pending_underground" \
			and underground_required:
		return _pending("ecology_underground_snapshot_deferred_until_underground_view", {
			"chunk":chunk_key, "deferredCategories":snapshot.get("deferredCategories", [])})
	var expected_world_id := "seed:%s:%d" % [String(main.get("seed_text")),
		int(main.get("seed_hash"))]
	if _validate_snapshot(snapshot).get("status") != "ready" \
			or _world_id != expected_world_id \
			or snapshot.get("chunk") != chunk_key \
			or int(snapshot.get("producerOwnerInstanceId", 0)) != chunk_node.get_instance_id() \
			or String(snapshot.get("worldSeed", "")) != String(main.get("seed_text")) \
			or String(snapshot.get("sourceRevision", "")) != String(main.call(
				"_ecology_chunk_source_revision", chunk_key)):
		return _pending("ecology_chunk_source_snapshot_revision_stale", {"chunk":chunk_key,
			"snapshotProducerOwnerInstanceId":int(snapshot.get("producerOwnerInstanceId", 0)),
			"currentProducerOwnerInstanceId":chunk_node.get_instance_id(),
			"snapshotRemovedPropsRevision":int(snapshot.get("removedPropsRevision", -1)),
			"currentRemovedPropsRevision":int(main.get("removed_props_revision")),
			"snapshotSourceRevision":String(snapshot.get("sourceRevision", "")),
			"currentSourceRevision":String(main.call("_ecology_chunk_source_revision", chunk_key)),
			"snapshotValidation":_validate_snapshot(snapshot)})
	var removed_prop_ids: Dictionary = {}
	for prop_id_value: Variant in removed_snapshot.get("ids", []):
		removed_prop_ids[String(prop_id_value)] = true
	removed_prop_ids.make_read_only()
	if not include_resource_bindings:
		var census_resource_bindings: Variant = chunk_node.get_meta(
			"static_ecology_render_resource_bindings", {})
		if not census_resource_bindings is Dictionary:
			return _pending("ecology_static_prop_resource_binding_map_unavailable", {
				"chunk":chunk_key})
		return {"status":"ready", "snapshot":snapshot,
			"chunkToWorld":chunk_node.global_transform,
			"undergroundRequired":underground_required,
			"removedPropIds":removed_prop_ids,
			"removedSnapshot":removed_snapshot,
			"resourceBindings":census_resource_bindings,
			"chunkOwnerInstanceId":chunk_node.get_instance_id(),
			"chunkOwner":weakref(chunk_node)}
	var bindings: Dictionary = {}
	var resource_bindings_value: Variant = chunk_node.get_meta(
		"static_ecology_render_resource_bindings", {})
	if not resource_bindings_value is Dictionary:
		return _pending("ecology_static_prop_resource_binding_map_unavailable", {"chunk":chunk_key})
	var resource_bindings: Dictionary = resource_bindings_value.duplicate(false)
	for binding_value: Variant in resource_bindings.values():
		if not binding_value is Dictionary:
			return _pending("ecology_static_prop_resource_binding_unsealed", {"chunk":chunk_key})
		if not binding_value.is_read_only():
			binding_value.make_read_only()
	resource_bindings.make_read_only()
	var detail_bindings: Dictionary = {}
	var unsupported_detail_types: Array[String] = []
	for candidate_value: Variant in snapshot.get("candidates", []):
		if candidate_value is Dictionary and String(candidate_value.get("kind", "")) == "surface_detail":
			var candidate: Dictionary = candidate_value
			var detail_type := String(candidate.get("detailType", ""))
			var mesh_source := String(candidate.get("meshSource", ""))
			var material_values: Variant = candidate.get("materials", [])
			if detail_type.is_empty() or mesh_source.is_empty() \
					or not material_values is Array or material_values.size() != 1:
				unsupported_detail_types.append(detail_type)
				continue
			var material_key := String(material_values[0])
			var surface_index := int(candidate.get("surfaceIndex", -1))
			var binding_identity := mesh_source + "|" + material_key
			if detail_bindings.has(binding_identity):
				continue
			var mesh: Variant
			var material_value: Variant
			var mesh_resource_key := ""
			if surface_index >= 0:
				if not main.has_method("detail_mesh_surface") \
						or not main.has_method("detail_surface_material") \
						or not main.has_method("detail_surface_material_key"):
					unsupported_detail_types.append(detail_type)
					continue
				mesh = main.call("detail_mesh_surface", detail_type, surface_index)
				material_value = main.call("detail_surface_material", detail_type, surface_index)
				var actual_material_key := String(main.call(
					"detail_surface_material_key", detail_type, surface_index))
				if actual_material_key.is_empty() or actual_material_key != material_key:
					unsupported_detail_types.append(detail_type)
					continue
				mesh_resource_key = "environment.detail.%s.surface.%d/v1" % [detail_type, surface_index]
			else:
				# Contract fixtures may still exercise legacy single-surface inputs.
				# Production creator records always carry the actual surface index.
				mesh = main.call("detail_mesh", detail_type)
				material_value = main.call("detail_material", detail_type)
				mesh_resource_key = "environment.detail.%s/v1" % detail_type
			if not mesh is Mesh or not material_value is Material:
				unsupported_detail_types.append(detail_type)
				continue
			var material_digest := _material_digest(material_value)
			if material_digest.is_empty():
				unsupported_detail_types.append(detail_type)
				continue
			var binding := {"mesh":mesh, "material":material_value,
				"meshSource":mesh_source, "meshResourceKey":mesh_resource_key,
				"materialKey":material_key, "materialContentDigest":material_digest,
				"pipelineRevision":PIPELINE_REVISION, "fadeMargin":12.0}
			binding.make_read_only()
			bindings[binding_identity] = binding
			detail_bindings[binding_identity] = true
	bindings.make_read_only()
	unsupported_detail_types.sort()
	if not RemovedProps.is_current_for_ids(main, removed_snapshot, candidate_prop_ids):
		return _pending("ecology_removed_props_changed_during_capture", {"chunk":chunk_key})
	return {"status":"ready", "snapshot":snapshot, "bindings":bindings,
		"resourceBindings":resource_bindings,
		"chunkToWorld":chunk_node.global_transform,
		"unsupportedDetailTypes":unsupported_detail_types,
		"undergroundRequired":underground_required,
		"removedPropIds":removed_prop_ids,
		"removedSnapshot":removed_snapshot,
		"chunkOwnerInstanceId":chunk_node.get_instance_id(),
		"chunkOwner":weakref(chunk_node)}


## Build a census-only view of already committed tree queue records. No mesh
## fingerprint, instance encoding, or section partition is performed here.
func _current_tree_publications(main: Object) -> Dictionary:
	var publications: Dictionary = {}
	var queue: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue):
		return publications
	var records_value: Variant = queue.get("published_lod_records")
	if not records_value is Array:
		return publications
	for record_value: Variant in records_value:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		var body_reference := record.get("body") as WeakRef
		var body: Variant = body_reference.get_ref() if body_reference != null else null
		var request: Variant = record.get("request", {})
		if not is_instance_valid(body) or not body is StaticBody3D \
				or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
				or not request is Dictionary:
			continue
		var prop_id := String((request as Dictionary).get("treeId", ""))
		if prop_id.is_empty():
			continue
		if publications.has(prop_id):
			publications[prop_id] = {"ambiguous":true}
		else:
			publications[prop_id] = {"record":record, "body":body}
	return publications


func _tree_census_source_revision(candidate: Dictionary,
		publication: Dictionary) -> String:
	if publication.is_empty() or bool(publication.get("ambiguous", false)):
		return ""
	var record_value: Variant = publication.get("record", null)
	var body_value: Variant = publication.get("body", null)
	if not record_value is Dictionary or not body_value is StaticBody3D:
		return ""
	var record: Dictionary = record_value
	var body: StaticBody3D = body_value
	var request: Variant = record.get("request", {})
	var members: Variant = record.get("sectionValueMembers", null)
	var tier := String(record.get("tier", ""))
	var recipe_signature := String(record.get("recipeSignature", ""))
	var prop_id := String(candidate.get("propId", ""))
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main) or not request is Dictionary or prop_id.is_empty() \
			or String((request as Dictionary).get("treeId", "")) != prop_id \
			or String((request as Dictionary).get("worldSeed", "")) \
				!= String(main.get("seed_text")) \
			or String(body.get_meta("prop_id", "")) != prop_id \
			or not ((request as Dictionary).get("treeWorldPosition", Vector3.INF) is Vector3) \
			or not ((request as Dictionary).get("treeWorldPosition", Vector3.INF) as Vector3).is_equal_approx(body.global_position) \
			or bool(record.get("rebuildPending", false)) \
			or recipe_signature.is_empty() or tier.is_empty() \
			or tier != String((request as Dictionary).get("renderLodTier", "")) \
			or tier != String(body.get_meta("tree_render_lod_tier", "")) \
			or recipe_signature != String(body.get_meta("tree_recipe_signature", "")) \
			or String(body.get_meta("tree_visual_state", "")) != "published" \
			or String(body.get_meta("visual_source", "")) != "procedural_tree_recipe" \
			or not body.is_inside_tree() or body.is_queued_for_deletion() \
			or not members is Array or not members.is_read_only() or members.is_empty():
		return ""
	var bole_count := 0
	for member_value: Variant in members:
		if not member_value is Dictionary or not member_value.is_read_only():
			return ""
		var member: Dictionary = member_value
		var role := String(member.get("role", ""))
		if role == "bole":
			bole_count += 1
		if role not in ["bole", "branches", "foliage"] \
				or not member.get("mesh", null) is Mesh \
				or not member.get("material", null) is Material \
				or not member.get("localTransform", null) is Transform3D \
				or not member.get("transforms", null) is Array \
				or not member.get("colors", null) is Array \
				or not member.get("customData", null) is Array:
			return ""
	if bole_count != 1:
		return ""
	var candidate_revision := String(candidate.get("contentRevision", ""))
	if candidate_revision.is_empty():
		return ""
	var grouped := TreeAdapter._members_by_role(members)
	if grouped.get("status") != "ready":
		return ""
	var raw_member_revision := TreeAdapter.raw_member_content_revision(grouped.members)
	return _tree_section_source_revision_for_values(candidate, recipe_signature,
		tier, body.global_transform, body.get_instance_id(), raw_member_revision)


func _tree_section_source_revision(candidate: Dictionary,
		captured: Dictionary) -> String:
	var producer_revision := String(captured.get("producerRevision", ""))
	var tier := String(captured.get("renderLodTier", ""))
	var body_transform: Variant = captured.get("bodyGlobalTransform", null)
	var body_instance_id := int(captured.get("bodyInstanceId", 0))
	var raw_member_revision := String(captured.get("rawMemberContentRevision", ""))
	if producer_revision.is_empty() or tier.is_empty() \
			or not body_transform is Transform3D or body_instance_id <= 0 \
			or raw_member_revision.is_empty():
		return ""
	return _tree_section_source_revision_for_values(candidate, producer_revision,
		tier, body_transform as Transform3D, body_instance_id, raw_member_revision)


func _tree_section_source_revision_for_values(candidate: Dictionary,
		producer_revision: String, tier: String, body_transform: Transform3D,
		body_instance_id: int, raw_member_revision: String) -> String:
	if producer_revision.is_empty() or tier.is_empty() or body_instance_id <= 0 \
			or raw_member_revision.is_empty():
		return ""
	var candidate_revision := String(candidate.get("contentRevision", ""))
	return _value_digest([TREE_SECTION_SOURCE_REVISION_SCHEMA, _world_id,
		String(candidate.get("sourceId", "")), candidate_revision,
		producer_revision, tier, body_transform, body_instance_id,
		raw_member_revision])


## Census section ownership from committed queue values only. This mirrors the
## shared partitioner's center rule without fingerprinting, encoding attributes,
## building tree geometry, or invoking TreeAdapter.partition.
func _tree_census_section_keys(publication: Dictionary) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var body_value: Variant = publication.get("body", null)
	var record_value: Variant = publication.get("record", null)
	if not body_value is StaticBody3D or not record_value is Dictionary:
		return result
	var body: StaticBody3D = body_value
	var record: Dictionary = record_value
	var members_value: Variant = record.get("sectionValueMembers", null)
	if not members_value is Array or not members_value.is_read_only():
		return result
	for member_value: Variant in members_value:
		if not member_value is Dictionary:
			return []
		var member: Dictionary = member_value
		var mesh_value: Variant = member.get("mesh", null)
		var local_transform_value: Variant = member.get("localTransform", null)
		var transforms_value: Variant = member.get("transforms", null)
		var colors_value: Variant = member.get("colors", null)
		var custom_data_value: Variant = member.get("customData", null)
		if not mesh_value is Mesh or not local_transform_value is Transform3D \
				or not (local_transform_value as Transform3D).is_finite() \
				or not transforms_value is Array or not transforms_value.is_read_only() \
				or not colors_value is Array or not colors_value.is_read_only() \
				or not custom_data_value is Array or not custom_data_value.is_read_only() \
				or transforms_value.size() == 0 \
				or transforms_value.size() != colors_value.size() \
				or transforms_value.size() != custom_data_value.size():
			return []
		var mesh_bounds: AABB = (mesh_value as Mesh).get_aabb()
		if not _valid_bounds(mesh_bounds):
			return []
		for index: int in range(transforms_value.size()):
			var member_transform_value: Variant = transforms_value[index]
			if not member_transform_value is Transform3D \
					or not (member_transform_value as Transform3D).is_finite() \
					or not colors_value[index] is Color \
					or not custom_data_value[index] is Color:
				return []
			var world_transform: Transform3D = body.global_transform \
				* (local_transform_value as Transform3D) \
				* (member_transform_value as Transform3D)
			var world_bounds: AABB = world_transform * mesh_bounds
			if not _valid_bounds(world_bounds):
				return []
			var section_key := Grid.key_for_world_position(world_bounds.get_center())
			if section_key not in result:
				result.append(section_key)
	return result


func _static_prop_source_revision(world_id: String, snapshot: Dictionary,
		candidate: Dictionary) -> String:
	var candidate_revision := String(candidate.get("contentRevision", ""))
	var producer_revision := String(snapshot.get("sourceRevision", ""))
	if candidate_revision.is_empty() or producer_revision.is_empty():
		return ""
	return _value_digest([STATIC_PROP_SECTION_SOURCE_REVISION_SCHEMA,
		world_id, producer_revision, candidate_revision])


func _static_prop_member_values_valid(candidate: Dictionary) -> bool:
	var members: Variant = candidate.get("renderMembers", null)
	var body_transform: Variant = candidate.get("transform", null)
	if not members is Array or members.is_empty() or not body_transform is Transform3D \
			or not _valid_transform(body_transform):
		return false
	var member_ids: Dictionary = {}
	var union_bounds := AABB()
	var has_bounds := false
	for member_value: Variant in members:
		if not member_value is Dictionary:
			return false
		var member: Dictionary = member_value
		var member_id := String(member.get("memberId", ""))
		var transform: Variant = member.get("transform", null)
		var bounds: Variant = member.get("localBounds", null)
		if member_id.is_empty() or member_ids.has(member_id) \
				or String(member.get("meshContentDigest", "")).length() != 64 \
				or String(member.get("materialContentDigest", "")).length() != 64 \
				or not transform is Transform3D or not _valid_transform(transform) \
				or not bounds is AABB or not _valid_bounds(bounds) \
				or String(member.get("materialKey", "")).is_empty() \
				or String(member.get("renderLayer", "")).is_empty():
			return false
		member_ids[member_id] = true
		var transformed_bounds: AABB = bounds * (body_transform as Transform3D)
		union_bounds = transformed_bounds if not has_bounds else union_bounds.merge(transformed_bounds)
		has_bounds = true
	return has_bounds and union_bounds.is_equal_approx(candidate.get("localBounds", AABB()))


## Validate resource availability and declared layer without inspecting resource
## contents. Fingerprints and stale-resource rejection remain contribution work.
func _static_prop_resources_are_renderable(resource_bindings: Variant,
		candidate: Dictionary) -> bool:
	if not resource_bindings is Dictionary:
		return false
	var source_id := String(candidate.get("sourceId", ""))
	for member_value: Variant in candidate.get("renderMembers", []):
		if not member_value is Dictionary:
			return false
		var member: Dictionary = member_value
		var member_id := String(member.get("memberId", ""))
		var binding_value: Variant = resource_bindings.get(source_id + "|" + member_id, null)
		if not binding_value is Dictionary or not binding_value.is_read_only():
			return false
		var mesh_value: Variant = binding_value.get("mesh", null)
		var material_value: Variant = binding_value.get("material", null)
		if not mesh_value is Mesh or not material_value is Material \
				or String(binding_value.get("materialKey", "")) \
					!= String(member.get("materialKey", "")) \
				or _supported_ecology_layer(material_value,
					String(member.get("renderLayer", ""))).is_empty():
			return false
	return true


func _detail_candidate_mesh_if_current(main: Object, candidate: Dictionary) -> Mesh:
	if not _detail_candidate_resource_is_current(main, candidate):
		return null
	var detail_type := String(candidate.get("detailType", ""))
	var surface_index := int(candidate.get("surfaceIndex", -1))
	var mesh: Variant = main.call("detail_mesh_surface", detail_type, surface_index) \
		if surface_index >= 0 else main.call("detail_mesh", detail_type)
	return mesh as Mesh if mesh is Mesh else null


static func _surface_detail_census_section_key(mesh: Mesh,
		source_to_world: Transform3D, local_transform: Transform3D) -> Vector3i:
	return Grid.key_for_world_position(
		source_to_world * local_transform * mesh.get_aabb().get_center())


func _detail_candidate_resource_is_current(main: Object, candidate: Dictionary) -> bool:
	var detail_type := String(candidate.get("detailType", ""))
	var material_keys: Variant = candidate.get("materials", null)
	var render_layers: Variant = candidate.get("renderLayers", null)
	var mesh_source := String(candidate.get("meshSource", ""))
	if detail_type.is_empty() or mesh_source.is_empty() \
			or not material_keys is Array or material_keys.size() != 1 \
			or not render_layers is Array or render_layers.size() != 1:
		return false
	var surface_index := int(candidate.get("surfaceIndex", -1))
	var mesh: Variant = null
	var material: Variant = null
	var material_key := String(material_keys[0])
	if surface_index >= 0:
		if not main.has_method("detail_mesh_surface") \
				or not main.has_method("detail_surface_material") \
				or not main.has_method("detail_surface_material_key"):
			return false
		mesh = main.call("detail_mesh_surface", detail_type, surface_index)
		material = main.call("detail_surface_material", detail_type, surface_index)
		if String(main.call("detail_surface_material_key", detail_type,
				surface_index)) != material_key:
			return false
	else:
		if not main.has_method("detail_mesh") or not main.has_method("detail_material"):
			return false
		mesh = main.call("detail_mesh", detail_type)
		material = main.call("detail_material", detail_type)
	if not mesh is Mesh or not material is Material:
		return false
	if _supported_surface_detail_layer(material, String(render_layers[0])).is_empty():
		return false
	if surface_index >= 0 and (mesh as Mesh).get_surface_count() <= 0:
		return false
	var bounds_value: Variant = candidate.get("localBounds", null)
	var transform_value: Variant = candidate.get("transform", null)
	return bounds_value is AABB and transform_value is Transform3D \
		and ((mesh as Mesh).get_aabb() * (transform_value as Transform3D)).is_equal_approx(bounds_value)


func _production_chunk_owner_is_current(main: Object, chunk_key: Vector2i,
		production: Dictionary) -> bool:
	var chunks_value: Variant = main.get("chunks")
	var owner_reference := production.get("chunkOwner") as WeakRef
	var captured_owner: Variant = owner_reference.get_ref() if owner_reference != null else null
	if not chunks_value is Dictionary or not is_instance_valid(captured_owner) \
			or chunks_value.get(chunk_key, null) != captured_owner \
			or int(production.get("chunkOwnerInstanceId", 0)) != captured_owner.get_instance_id():
		return false
	var current_snapshot: Variant = captured_owner.get_meta("static_ecology_source_value_snapshot", {})
	var captured_snapshot: Variant = production.get("snapshot", {})
	if not current_snapshot is Dictionary or not captured_snapshot is Dictionary \
			or String(current_snapshot.get("contentRevision", "")) \
				!= String(captured_snapshot.get("contentRevision", "")) \
			or not RemovedProps.is_current_for_ids(main,
				production.get("removedSnapshot", {}),
				production.get("removedSnapshot", {}).get("checkedIds", [])):
		return false
	return true


func _prepare_realized_static_props(snapshot: Dictionary, resource_bindings_value: Variant,
		chunk_to_world: Transform3D, world_id: String,
		underground_required := true, removed_prop_ids: Dictionary = {}) -> Dictionary:
	if not resource_bindings_value is Dictionary or not resource_bindings_value.is_read_only():
		return _pending("ecology_static_prop_resource_binding_map_unsealed", {
			"chunk":snapshot.get("chunk", Vector2i.ZERO)})
	var resource_bindings: Dictionary = resource_bindings_value
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var mesh_bindings: Dictionary = {}
	var material_bindings: Dictionary = {}
	var source_revisions: Dictionary = {}
	for candidate_value: Variant in snapshot.get("candidates", []):
		if not candidate_value is Dictionary \
				or String(candidate_value.get("kind", "")) != "realized_static_prop":
			continue
		var candidate: Dictionary = candidate_value
		var source_id := String(candidate.get("sourceId", ""))
		var prop_id := String(candidate.get("propId", ""))
		if not prop_id.is_empty() and removed_prop_ids.has(prop_id):
			continue
		if String(candidate.get("category", "")) == "underground_props" \
				and not underground_required:
			continue
		if String(candidate.get("renderStatus", "")) != "ready":
			return _pending("ecology_static_prop_render_pending", {
				"sourceId":source_id,
				"reason":String(candidate.get("pendingReason", "unknown"))})
		var category := String(candidate.get("category", ""))
		var candidate_revision := String(candidate.get("contentRevision", ""))
		var body_transform_value: Variant = candidate.get("transform", null)
		var members_value: Variant = candidate.get("renderMembers", null)
		if source_id.is_empty() or candidate_revision.is_empty() \
				or not body_transform_value is Transform3D or not _valid_transform(body_transform_value) \
				or not members_value is Array or members_value.is_empty():
			return _pending("ecology_static_prop_candidate_incomplete", {"sourceId":source_id})
		var resolved_rows: Array[Dictionary] = []
		for member_value: Variant in members_value:
			if not member_value is Dictionary:
				return _pending("ecology_static_prop_member_invalid", {"sourceId":source_id})
			var member: Dictionary = member_value
			var member_id := String(member.get("memberId", ""))
			var binding_value: Variant = resource_bindings.get(source_id + "|" + member_id, null)
			if member_id.is_empty() or not binding_value is Dictionary:
				return _pending("ecology_static_prop_member_resource_missing", {
					"sourceId":source_id, "memberId":member_id})
			var mesh_value: Variant = binding_value.get("mesh", null)
			var material_value: Variant = binding_value.get("material", null)
			if not mesh_value is Mesh or not material_value is Material:
				return _pending("ecology_static_prop_resource_type_unsupported", {
					"sourceId":source_id, "memberId":member_id})
			var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(mesh_value)
			var mesh_digest := String(mesh_fingerprint.get("contentDigest", ""))
			var expected_mesh_digest := String(member.get("meshContentDigest", ""))
			var material_digest := _material_digest(material_value)
			if mesh_fingerprint.get("status") != "ready" \
					or mesh_digest != expected_mesh_digest \
					or material_digest.is_empty() \
					or material_digest != String(member.get("materialContentDigest", "")) \
					or mesh_digest != String(binding_value.get("meshContentDigest", "")) \
					or material_digest != String(binding_value.get("materialContentDigest", "")):
				return _pending("ecology_static_prop_resource_fingerprint_stale", {
					"sourceId":source_id, "memberId":member_id})
			var render_layer := _supported_ecology_layer(material_value,
				String(member.get("renderLayer", "")))
			if render_layer.is_empty():
				return _pending("ecology_static_prop_material_layer_unsupported", {
					"sourceId":source_id, "memberId":member_id})
			var local_member_transform: Variant = member.get("transform", null)
			var member_bounds_value: Variant = member.get("localBounds", null)
			var mesh_bounds: AABB = mesh_value.get_aabb()
			if not local_member_transform is Transform3D \
					or not _valid_transform(local_member_transform) \
					or not member_bounds_value is AABB \
					or not (mesh_bounds * local_member_transform).is_equal_approx(member_bounds_value) \
					or not _valid_bounds(mesh_bounds):
				return _pending("ecology_static_prop_member_bounds_or_transform_invalid", {
					"sourceId":source_id, "memberId":member_id})
			var material_key := String(member.get("materialKey", ""))
			if material_key != String(binding_value.get("materialKey", "")):
				return _pending("ecology_static_prop_material_binding_identity_stale", {
					"sourceId":source_id, "memberId":member_id})
			var mesh_resource_key := "ecology.runtime.%s/v1" % mesh_digest
			var compatibility := _compatibility(material_key, material_key, material_digest,
				mesh_resource_key, mesh_digest, PIPELINE_REVISION, render_layer,
				mesh_bounds, true, 0.0, 0.0)
			if compatibility.is_empty():
				return _pending("ecology_static_prop_compatibility_unsupported", {
					"sourceId":source_id, "memberId":member_id})
			var compatibility_key := String(compatibility.batchKey)
			if compatibility_by_key.has(compatibility_key) \
					and compatibility_by_key[compatibility_key] != compatibility:
				return _failed("ecology_static_prop_batch_compatibility_conflict")
			compatibility_by_key[compatibility_key] = compatibility
			mesh_bindings[mesh_resource_key] = mesh_value
			material_bindings[String(compatibility.materialKey)] = material_value
			resolved_rows.append({"memberId":member_id, "meshDigest":mesh_digest,
				"materialDigest":material_digest, "renderLayer":render_layer,
				"transform":local_member_transform, "meshBounds":mesh_bounds,
				"compatibility":compatibility, "meshResourceKey":mesh_resource_key,
				"materialKey":String(compatibility.materialKey),
				"sourceSection":Grid.key_for_world_position(chunk_to_world *
					(body_transform_value * local_member_transform * mesh_bounds.get_center()))})
		var producer_revision := String(snapshot.get("sourceRevision", ""))
		var source_revision := _static_prop_source_revision(world_id, snapshot, candidate)
		if source_revision.is_empty():
			return _failed("ecology_static_prop_source_revision_failed", {"sourceId":source_id})
		if source_revisions.has(source_id) and String(source_revisions[source_id]) != source_revision:
			return _failed("ecology_static_prop_source_revision_conflict", {"sourceId":source_id})
		source_revisions[source_id] = source_revision
		for row: Dictionary in resolved_rows:
			var local_transform: Transform3D = body_transform_value * row.transform
			var buffer: Array[float] = _encode_instance(local_transform, Color.TRANSPARENT, Color.WHITE)
			buffer.make_read_only()
			var input := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
				"sourceId":source_id, "sourcePartId":source_id,
				"sourceRevision":source_revision,
				"ownerCell":Vector2i(snapshot.get("chunk", Vector2i.ZERO)),
				"sourceToWorld":chunk_to_world,
				"meshLocalBounds":row.meshBounds,
				"batchKey":String(row.compatibility.batchKey),
				"segmentId":"ecology-static:%s:%s" % [row.memberId, source_revision],
				"buffer":buffer, "instanceCount":1,
				"sectionKey":Vector3i(row.sourceSection)}
			input.make_read_only()
			inputs.append(input)
	inputs.make_read_only()
	compatibility_by_key.make_read_only()
	mesh_bindings.make_read_only()
	material_bindings.make_read_only()
	source_revisions.make_read_only()
	return {"status":"ready", "inputs":inputs,
		"compatibilityByKey":compatibility_by_key, "meshBindings":mesh_bindings,
		"materialBindings":material_bindings, "sourceRevisions":source_revisions,
		"candidateIds":source_revisions.keys()}


static func _supported_ecology_layer(material: Material, declared_layer: String) -> String:
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader != null and not shader.code.is_empty() \
				and not shader.code.contains("ALPHA") \
				and not shader.code.contains("discard") \
				and not shader.code.contains("blend_") \
				and declared_layer == "opaque":
			return "opaque"
		return ""
	if not material is BaseMaterial3D:
		return ""
	var base := material as BaseMaterial3D
	if base.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
			and base.albedo_color.a >= 0.999 and declared_layer == "opaque":
		return "opaque"
	if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR \
			and declared_layer == "cutout":
		return "cutout"
	return ""


static func _supported_surface_detail_layer(material: Material,
		declared_layer: String) -> String:
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader == null or shader.resource_path != \
				"res://resources/visual/detail_material.gdshader" \
				or shader.code.is_empty() or shader.code.contains("ALPHA") \
				or shader.code.contains("discard") or shader.code.contains("blend_"):
			return ""
		return "opaque" if declared_layer == "opaque" else ""
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		if base.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
				and base.albedo_color.a >= 0.999 and declared_layer == "opaque":
			return "opaque"
		if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR \
				and declared_layer == "alpha_scissor":
			return "cutout"
	return ""


static func _append_section_member(members_by_section: Dictionary, source_revisions: Dictionary,
		section_key: Vector3i, source_id: String, source_revision: String) -> bool:
	if source_id.is_empty() or source_revision.is_empty():
		return false
	if source_revisions.has(source_id) and String(source_revisions[source_id]) != source_revision:
		return false
	source_revisions[source_id] = source_revision
	if not members_by_section.has(section_key):
		members_by_section[section_key] = []
	var ids: Array = members_by_section[section_key]
	if source_id not in ids:
		ids.append(source_id)
	return true


static func _tree_family_proof_valid(snapshot: Dictionary) -> bool:
	var proof_value: Variant = snapshot.get("treeFamilyProof", null)
	if not proof_value is Dictionary or not bool(proof_value.get("producerComplete", false)):
		return false
	if String(proof_value.get("sourceRevision", "")) != String(snapshot.get("sourceRevision", "")) \
			or proof_value.get("chunk", null) != snapshot.get("chunk", null):
		return false
	var expected: Array[String] = []
	for candidate_value: Variant in snapshot.get("candidates", []):
		if candidate_value is Dictionary and String(candidate_value.get("kind", "")) == "trees_foliage":
			expected.append(String(candidate_value.get("sourceId", "")))
	expected.sort()
	var declared: Array[String] = []
	for source_id_value: Variant in proof_value.get("sourceIds", []):
		declared.append(String(source_id_value))
	declared.sort()
	if expected != declared:
		return false
	var payload: Dictionary = proof_value.duplicate(true)
	var recorded_digest := String(payload.get("contentRevision", ""))
	payload.erase("contentRevision")
	return not recorded_digest.is_empty() and recorded_digest == _value_digest(payload)


static func source_revisions_for_ids(source_ids: Array, all_revisions: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for source_id_value: Variant in source_ids:
		var source_id := String(source_id_value)
		if all_revisions.has(source_id):
			result[source_id] = all_revisions[source_id]
	return result


static func _material_digest(material: Material) -> String:
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var shader := shader_material.shader
		if shader == null or shader.code.is_empty():
			return ""
		var uniforms: Array = []
		for uniform_value: Variant in shader.get_shader_uniform_list():
			if not uniform_value is Dictionary:
				return ""
			var name := String(uniform_value.get("name", ""))
			if name.begins_with("global_"):
				continue
			var parameter: Variant = shader_material.get_shader_parameter(name)
			var canonical_parameter: Variant = parameter
			if parameter is Texture2D:
				var texture_digest := _texture_digest(parameter as Texture2D)
				if texture_digest.is_empty():
					return ""
				canonical_parameter = ["texture2d", texture_digest]
			elif not _shader_digest_value_supported(parameter):
				return ""
			uniforms.append([name, canonical_parameter])
		uniforms.sort_custom(func(a: Array, b: Array) -> bool:
			return String(a[0]) < String(b[0]))
		return Marshalls.raw_to_base64(var_to_bytes([shader.code, uniforms])).sha256_text()
	if material is BaseMaterial3D:
		var values: Array = []
		for property_value: Variant in material.get_property_list():
			if not property_value is Dictionary:
				return ""
			var name := String(property_value.get("name", ""))
			if name.is_empty() or name.begins_with("resource_") \
					or name in ["script", "resource_local_to_scene", "resource_name"]:
				continue
			var value: Variant = material.get(name)
			var canonical_value: Variant = value
			if value is Texture2D:
				var texture_digest := _texture_digest(value as Texture2D)
				if texture_digest.is_empty():
					return ""
				canonical_value = ["texture2d", texture_digest]
			elif value is Resource or value is Object or value is Callable:
				return ""
			elif not _material_digest_value_supported(value):
				return ""
			values.append([name, canonical_value])
		values.sort_custom(func(a: Array, b: Array) -> bool:
			return String(a[0]) < String(b[0]))
		return Marshalls.raw_to_base64(var_to_bytes([material.get_class(), values])).sha256_text()
	var identity := CitadelGeometryAdapter._material_identity(material)
	return String(identity.get("digest", ""))


static func _shader_digest_value_supported(value: Variant) -> bool:
	return value == null or value is bool or value is int or value is float \
		or value is String or value is Color or value is Vector2 or value is Vector3 \
		or value is Vector4


static func _material_digest_value_supported(value: Variant) -> bool:
	return value == null or value is bool or value is int or value is float \
		or value is String or value is Color or value is Vector2 or value is Vector3 \
		or value is Vector4 or value is Vector2i or value is Vector3i \
		or value is Rect2 or value is Quaternion or value is Basis \
		or value is Transform3D or value is AABB


static func _texture_digest(texture: Texture2D) -> String:
	if not is_instance_valid(texture):
		return ""
	var image := texture.get_image()
	if image == null or image.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var identity := var_to_bytes([texture.get_class(), image.get_width(),
		image.get_height(), image.get_format(), image.has_mipmaps()])
	if context.update(identity) != OK or context.update(image.get_data()) != OK:
		return ""
	return context.finish().hex_encode()


static func _candidate_digest(candidate: Dictionary) -> String:
	var value := candidate.duplicate(true)
	value.erase("contentRevision")
	return _value_digest(value)


static func _value_digest(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(JSON.stringify(_canonical(value)).to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


static func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var entries: Array = []
		for key: Variant in keys:
			entries.append([_canonical(key), _canonical(value[key])])
		return entries
	if value is Array:
		var entries: Array = []
		for item: Variant in value:
			entries.append(_canonical(item))
		return entries
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Transform3D:
		return [value.basis.x.x, value.basis.x.y, value.basis.x.z,
			value.basis.y.x, value.basis.y.y, value.basis.y.z,
			value.basis.z.x, value.basis.z.y, value.basis.z.z,
			value.origin.x, value.origin.y, value.origin.z]
	if value is AABB:
		return [_canonical(value.position), _canonical(value.size)]
	return value


static func _valid_transform(transform: Transform3D) -> bool:
	return transform.origin.is_finite() and transform.basis.x.is_finite() \
		and transform.basis.y.is_finite() and transform.basis.z.is_finite() \
		and absf(transform.basis.determinant()) > 0.000001


static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0 \
		and bounds.end.is_finite()


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


static func _failed(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"failed", "reason":reason, "retryable":false}
	result.merge(detail, true)
	return result
