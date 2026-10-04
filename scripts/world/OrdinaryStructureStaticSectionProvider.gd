extends RefCounted
class_name OrdinaryStructureStaticSectionProvider

## Section-source census and prepared geometry for generated ordinary
## structures. StructureSystem remains authoritative for generated membership,
## removals, collision and interaction. This provider only adapts the existing
## visible static geometry into immutable section candidate values.

const Adapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const SourceCapture := preload("res://scripts/world/OrdinaryStructureVisualSourceCapture.gd")
const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

const PROVIDER_ID := "ordinary-structures"
const SCHEMA := "ordinary-structure-static-section-provider/v1"
const MAX_SECTIONS_PER_CAPTURE := 8
const DISCOVERY_MARGIN_CELLS := int(Adapter.MAX_HORIZONTAL_SUPPORT_CELLS)
const DISCOVERY_ATOMS_PER_TURN := 128
const MEMBERS_PER_TURN := 32

var _world_id := ""
var _system_ref: WeakRef
var _system_id := 0
var _main_ref: WeakRef
var _main_id := 0
var _jobs: Dictionary = {}
var _installed_members_by_section: Dictionary = {}
var _latest_by_section: Dictionary = {}


func configure(world_id: String, structure_system: Object, main: Object) -> Dictionary:
	if world_id.strip_edges().is_empty() or not is_instance_valid(structure_system) \
			or not is_instance_valid(main) or structure_system.get("main") != main:
		return _failed("invalid_ordinary_section_provider_owner")
	if not structure_system.has_method("region_dependency_scheduling_revision") \
			or not structure_system.has_method("_ordinary_visual_block_key"):
		return _failed("ordinary_section_provider_authority_contract_missing")
	if not _world_id.is_empty() and (_world_id != world_id \
			or _system_id != structure_system.get_instance_id() \
			or _main_id != main.get_instance_id()):
		return _failed("ordinary_section_provider_already_bound")
	_world_id = world_id
	_system_ref = weakref(structure_system)
	_system_id = structure_system.get_instance_id()
	_main_ref = weakref(main)
	_main_id = main.get_instance_id()
	return {"status":"ready", "providerId":PROVIDER_ID, "worldId":_world_id}


## Implements StaticSectionSourceRoster.capture_method. A section is complete
## only after deterministic source discovery is described, every intersecting
## expected visual has either a supported immutable geometry input or a
## durable-removal tombstone, and the source capture still matches its owner.
func capture_static_section_sources(world_id: String,
		requested_sections: Array) -> Dictionary:
	var context := _context(world_id)
	if context.is_empty() or requested_sections.is_empty() \
			or requested_sections.size() > MAX_SECTIONS_PER_CAPTURE:
		return _pending("ordinary_section_provider_world_or_query_invalid")
	var sections: Array[Vector3i] = []
	for value: Variant in requested_sections:
		if not value is Vector3i or value in sections:
			return _failed("invalid_or_duplicate_ordinary_section_key")
		sections.append(value)
	sections.sort_custom(_section_less)
	var section_rows: Dictionary = {}
	var source_revisions: Dictionary = {}
	var prepared_sections: Dictionary = {}
	var authority_rows: Array = []
	for section: Vector3i in sections:
		var section_id := _section_id(section)
		var job: Dictionary = _jobs.get(section_id, {})
		if job.is_empty() or not _job_is_current(job, context):
			job = _begin_job(section, context)
			if job.get("status") != "pending":
				return job
			_jobs[section_id] = job
		var advanced := _advance_job(job, context)
		if advanced.get("status") != "complete":
			if advanced.get("status") == "failed" or bool(advanced.get("restart", false)):
				_jobs.erase(section_id)
			return advanced
		var snapshot: Dictionary = advanced.snapshot
		_latest_by_section[section_id] = snapshot
		var member_ids: Array[String] = snapshot.memberIds.duplicate()
		member_ids.sort()
		member_ids.make_read_only()
		var coverage_revision := _coverage_revision(section, snapshot)
		if coverage_revision.is_empty():
			return _failed("ordinary_section_coverage_revision_failed")
		var status := "empty" if member_ids.is_empty() else "complete"
		var row := {"status":status, "sourcePartIds":member_ids,
			"coverageRevision":coverage_revision}
		row.make_read_only()
		section_rows[section] = row
		for part_id: String in member_ids:
			var revision := String(snapshot.sourceRevisions.get(part_id, ""))
			if revision.is_empty():
				return _failed("ordinary_section_member_revision_missing", {
					"sourcePartId":part_id})
			if source_revisions.has(part_id) and String(source_revisions[part_id]) != revision:
				return _failed("ordinary_section_member_revision_conflict", {
					"sourcePartId":part_id})
			source_revisions[part_id] = revision
		prepared_sections[section] = snapshot.prepared
		authority_rows.append([[section.x, section.y, section.z],
			String(snapshot.discoveryRevision), coverage_revision])
	var authority_digest := _sha256(var_to_bytes([SCHEMA, _world_id, authority_rows]))
	if authority_digest.is_empty():
		return _failed("ordinary_section_authority_revision_failed")
	var revisions: Dictionary = {}
	for section: Vector3i in sections:
		var snapshot: Dictionary = _latest_by_section[_section_id(section)]
		var revision: String = String(section_rows[section].coverageRevision)
		revisions[section] = _removals_for(section, snapshot, revision)
	section_rows.make_read_only()
	source_revisions.make_read_only()
	prepared_sections.make_read_only()
	revisions.make_read_only()
	sections.make_read_only()
	var result := {"status":"complete", "schema":SCHEMA,
		"providerId":PROVIDER_ID, "worldId":_world_id,
		"authorityRevision":authority_digest,
		"sections":section_rows, "sourceRevisions":source_revisions,
		"preparedSections":prepared_sections,
		"removalsBySection":revisions}
	result.make_read_only()
	return result


## Called only after the section coordinator accepts the installed replacement.
## Keeping this separate prevents an unaccepted candidate from consuming its
## tombstone and losing the retryable removal demand.
func acknowledge_section_install(section_key: Vector3i,
		coverage_revision: String) -> Dictionary:
	var section_id := _section_id(section_key)
	var snapshot: Dictionary = _latest_by_section.get(section_id, {})
	if snapshot.is_empty() or coverage_revision.is_empty() \
			or _coverage_revision(section_key, snapshot) != coverage_revision:
		return _failed("ordinary_section_install_acknowledgement_stale")
	var installed: Dictionary = {}
	var declarations: Variant = snapshot.prepared.get("declarations", [])
	if not declarations is Array:
		return _failed("ordinary_section_install_declarations_missing")
	for declaration_value: Variant in declarations:
		if not declaration_value is Dictionary:
			return _failed("ordinary_section_install_declaration_invalid")
		var declaration: Dictionary = declaration_value
		var part_id := String(declaration.get("sourcePartId", ""))
		var source_id := String(declaration.get("sourceId", ""))
		var authority_source_id := String(declaration.get("authoritySourceId", ""))
		var revision := String(declaration.get("sourceRevision", ""))
		if part_id.is_empty() or source_id != part_id or authority_source_id.is_empty() \
				or revision.is_empty() \
				or String(snapshot.sourceRevisions.get(part_id, "")) != revision \
				or installed.has(part_id):
			return _failed("ordinary_section_install_declaration_binding_invalid", {
				"sourcePartId":part_id, "sourceId":source_id})
		installed[part_id] = {"sourceId":source_id,
			"authoritySourceId":authority_source_id, "sourceRevision":revision}
	if installed.size() != snapshot.sourceRevisions.size():
		return _failed("ordinary_section_install_member_declaration_count_mismatch")
	installed.make_read_only()
	_installed_members_by_section[section_id] = {
		"coverageRevision":coverage_revision, "members":installed}
	return {"status":"acknowledged", "section":section_key,
		"coverageRevision":coverage_revision, "memberCount":installed.size()}


func _begin_job(section: Vector3i, context: Dictionary) -> Dictionary:
	var capture = SourceCapture.new()
	var bounds := _discovery_bounds(section)
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return _failed("ordinary_section_discovery_bounds_invalid")
	capture.begin(context.system, bounds)
	if capture.advance(1, 1000).get("status") == "failed":
		return _failed("ordinary_section_source_discovery_failed")
	return {"status":"pending", "phase":"discover", "section":section,
		"bounds":bounds, "capture":capture, "candidateIndex":0,
		"seed":String(context.main.get("seed_text")),
		"ordinaryRevision":int(context.system.get("ordinary_visual_revision")),
		"generation":int(context.system.get("regional_source_generation")),
		"regionalRevision":int(context.system.get("regional_source_revision")),
		"dependencyRevision":context.system.call("region_dependency_scheduling_revision", bounds),
		"inputs":[], "sourceRevisions":{}, "resourcesByBatch":{},
		"meshBindings":{}, "materialBindings":{},
		"compatibilityByKey":{}, "sourceRows":{},
		"discoveryRevision":"", "snapshot":{}}


func _advance_job(job: Dictionary, context: Dictionary) -> Dictionary:
	var capture = job.get("capture")
	if not is_instance_valid(capture) or not _job_is_current(job, context):
		return _pending("ordinary_section_source_revision_changed", {
			"section":job.get("section", Vector3i.ZERO)})
	if String(job.phase) == "discover":
		var discovered: Dictionary = capture.advance(DISCOVERY_ATOMS_PER_TURN, 3000)
		if discovered.get("status") == "pending":
			var reason := String(discovered.get("reason", "ordinary_section_discovery_budget"))
			return _pending(reason, {
			"section":job.section, "stage":String(discovered.get("stage", "discover")),
				"cursor":int(discovered.get("cursor", 0)),
				"restart":reason != "ordinary_visual_capture_budget"})
		if discovered.get("status") == "failed":
			return _failed(String(discovered.get("reason", "ordinary_section_discovery_failed")))
		if discovered.get("status") != "described":
			return _pending(String(discovered.get("reason", "ordinary_section_discovery_incomplete")), {
				"section":job.section})
		job.discoveryRevision = String(discovered.get("sourceRevision", ""))
		if job.discoveryRevision.is_empty() or not discovered.get("candidates") is Array:
			return _failed("ordinary_section_discovery_manifest_invalid")
		job.candidates = discovered.candidates
		job.phase = "capture_geometry"
		return _pending("ordinary_section_geometry_capture_pending", {
			"section":job.section, "candidateCount":job.candidates.size()})
	if String(job.phase) == "capture_geometry":
		var processed := 0
		while int(job.candidateIndex) < job.candidates.size() and processed < MEMBERS_PER_TURN:
			var raw_value: Variant = job.candidates[int(job.candidateIndex)]
			job.candidateIndex = int(job.candidateIndex) + 1
			processed += 1
			if not raw_value is Dictionary:
				return _failed("ordinary_section_source_candidate_invalid")
			var raw: Dictionary = raw_value
			if not _candidate_intersects_section(raw, Vector3i(job.section), context.main):
				continue
			var source_id := String(raw.get("sourceId", ""))
			var cell_value: Variant = raw.get("cell")
			if source_id.is_empty() or not cell_value is Vector3i:
				return _failed("ordinary_section_source_candidate_identity_invalid")
			var captured := Adapter.capture_block(context.system, context.main,
				source_id, Vector3i(cell_value))
			if captured.get("status") == "empty":
				continue
			if captured.get("status") != "ready":
				job.candidateIndex = int(job.candidateIndex) - 1
				return _pending(String(captured.get("reason", "ordinary_section_member_geometry_pending")), {
					"sourceId":source_id, "cell":cell_value,
					"blockType":String(raw.get("blockType", ""))})
			var input: Dictionary = captured.sourceInput
			var part_id := String(input.get("sourcePartId", ""))
			if part_id.is_empty() or job.sourceRows.has(part_id):
				return _failed("ordinary_section_duplicate_or_missing_source_part")
			var resource := {"mesh":captured.mesh, "material":captured.material,
				"meshDigest":String(captured.meshDigest),
				"materialDigest":String(captured.materialDigest)}
			resource.make_read_only()
			var batch_key := String(input.get("batchKey", ""))
			if batch_key.is_empty():
				return _failed("ordinary_section_batch_key_missing")
			job.resourcesByBatch[batch_key] = resource
			job.compatibilityByKey[batch_key] = captured.compatibility
			job.meshBindings[String(captured.compatibility.meshResourceKey)] = captured.mesh
			job.materialBindings[String(captured.compatibility.materialKey)] = captured.material
			job.sourceRevisions[part_id] = String(input.get("sourceRevision", ""))
			job.sourceRows[part_id] = {"input":input, "manifest":captured.manifest,
				"mesh":captured.mesh, "material":captured.material,
				"compatibility":captured.compatibility}
		if int(job.candidateIndex) < job.candidates.size():
			return _pending("ordinary_section_geometry_capture_budget", {
				"section":job.section, "cursor":int(job.candidateIndex),
				"candidateCount":job.candidates.size()})
		if not capture.eligible_for(context.system, job.bounds) \
				or not _job_is_current(job, context):
			return _pending("ordinary_section_source_revision_changed", {
				"section":job.section})
		var inputs: Array[Dictionary] = []
		for row_value: Variant in job.sourceRows.values():
			var row: Dictionary = row_value
			inputs.append(row.input)
		inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.sourcePartId) < String(b.sourcePartId))
		inputs.make_read_only()
		var partitioned: Dictionary = Partitioner.partition(inputs)
		if partitioned.get("status") != "ready":
			return _failed("ordinary_section_partition_failed:" + String(partitioned.get("reason", "unknown")))
		var partition: Dictionary = partitioned.get("result", {})
		var section: Vector3i = job.section
		var member_ids: Dictionary = {}
		for output_value: Variant in partition.get("outputs", []):
			if not output_value is Dictionary:
				return _failed("ordinary_section_partition_output_invalid")
			var output: Dictionary = output_value
			if output.get("sectionKey") == section:
				var part_id := String(output.get("sourcePartId", ""))
				if part_id.is_empty() or not job.sourceRows.has(part_id):
					return _failed("ordinary_section_partition_member_unbound")
				member_ids[part_id] = true
		var ordered_ids: Array[String] = []
		for part_id_value: Variant in member_ids:
			ordered_ids.append(String(part_id_value))
		ordered_ids.sort()
		var owned_inputs: Array[Dictionary] = []
		var owned_compatibility: Dictionary = {}
		var owned_resources: Dictionary = {}
		var owned_meshes: Dictionary = {}
		var owned_materials: Dictionary = {}
		var owned_revisions: Dictionary = {}
		var declarations: Array[Dictionary] = []
		var prepared_segments: Array[Dictionary] = []
		for part_id: String in ordered_ids:
			var source_row: Dictionary = job.sourceRows[part_id]
			var input: Dictionary = source_row.input
			var compatibility: Dictionary = source_row.compatibility
			owned_inputs.append(input)
			var batch_key := String(input.batchKey)
			owned_compatibility[batch_key] = compatibility
			owned_resources[batch_key] = job.resourcesByBatch[batch_key]
			owned_meshes[String(compatibility.meshResourceKey)] = job.meshBindings[String(compatibility.meshResourceKey)]
			owned_materials[String(compatibility.materialKey)] = job.materialBindings[String(compatibility.materialKey)]
			owned_revisions[part_id] = String(input.sourceRevision)
			var segment_declaration := _segment_declaration(input, compatibility)
			segment_declaration.make_read_only()
			var segment_declarations: Array[Dictionary] = [segment_declaration]
			segment_declarations.make_read_only()
			var declaration := {"sourceId":String(input.sourceId),
			"sourcePartId":part_id, "sourceRevision":String(input.sourceRevision),
			"authoritySourceId":String(input.get("authoritySourceId", "")),
			"sourceToWorld":input.sourceToWorld, "ownerCell":input.ownerCell,
				"segments":segment_declarations}
			declaration.make_read_only()
			declarations.append(declaration)
			prepared_segments.append(input)
		owned_inputs.make_read_only()
		owned_compatibility.make_read_only()
		owned_resources.make_read_only()
		owned_meshes.make_read_only()
		owned_materials.make_read_only()
		owned_revisions.make_read_only()
		declarations.make_read_only()
		prepared_segments.make_read_only()
		var owned_partition: Dictionary = Partitioner.partition(owned_inputs).get("result", {})
		if owned_partition.is_empty():
			return _failed("ordinary_section_owned_partition_missing")
		var prepared := {"schema":SCHEMA, "sectionKey":section,
			"coverageScope":"ordinary_generated_static_geometry",
			"memberIds":ordered_ids, "sourceRevisions":owned_revisions,
			"inputs":owned_inputs, "declarations":declarations,
			"preparedSegments":prepared_segments,
			"partition":owned_partition,
			"compatibilityByKey":owned_compatibility,
			"resourceBindings":owned_resources,
			"meshBindings":owned_meshes,
			"materialBindings":owned_materials}
		prepared.memberIds.make_read_only()
		prepared.make_read_only()
		var source_rows: Array = []
		for part_id: String in ordered_ids:
			source_rows.append([part_id, String(owned_revisions[part_id])])
		var tombstones: Array[Dictionary] = []
		tombstones.make_read_only()
		var snapshot := {"sectionKey":section, "discoveryRevision":String(job.discoveryRevision),
			"memberIds":ordered_ids, "sourceRevisions":owned_revisions,
			"sourceRows":source_rows, "prepared":prepared, "tombstones":tombstones}
		snapshot.memberIds.make_read_only()
		snapshot.sourceRows.make_read_only()
		snapshot.make_read_only()
		job.snapshot = snapshot
		job.phase = "complete"
		return {"status":"complete", "snapshot":snapshot}
	if String(job.phase) == "complete":
		if not _job_is_current(job, context) or not capture.eligible_for(context.system, job.bounds):
			return _pending("ordinary_section_source_revision_changed", {
				"section":job.section})
		return {"status":"complete", "snapshot":job.snapshot}
	return _failed("ordinary_section_provider_job_phase_invalid")


func _segment_declaration(input: Dictionary, compatibility: Dictionary) -> Dictionary:
	return {"segmentId":String(input.segmentId),
		"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":String(compatibility.materialKey),
		"renderTier":String(compatibility.renderTier),
		"meshKey":String(compatibility.meshResourceKey),
		"meshContentDigest":String(compatibility.meshContentDigest),
		"meshLocalBounds":compatibility.meshLocalBounds,
		"pipelineRevision":String(compatibility.pipelineRevision),
		"renderLayer":String(compatibility.renderLayer),
		"translucentSortPolicy":String(compatibility.translucentSortPolicy),
		"castShadows":bool(compatibility.castShadows),
		"visibilityRangeEnd":float(compatibility.visibilityRangeEnd),
		"fadeMargin":float(compatibility.fadeMargin),
		"compatibilityKey":String(compatibility.batchKey)}


func _discovery_bounds(section: Vector3i) -> Rect2i:
	var margin := DISCOVERY_MARGIN_CELLS
	var low_x := section.x * Grid.SECTION_SIZE_CELLS - margin
	var low_z := section.z * Grid.SECTION_SIZE_CELLS - margin
	var size := Grid.SECTION_SIZE_CELLS + margin * 2
	return Rect2i(Vector2i(low_x, low_z), Vector2i(size, size))


func _candidate_intersects_section(candidate: Dictionary, section: Vector3i,
		main: Object) -> bool:
	var section_origin := Grid.origin_for_key(section)
	var section_bounds := AABB(section_origin, Vector3.ONE * Grid.SECTION_SIZE_METERS)
	var owner_ref: WeakRef = candidate.get("owner") as WeakRef
	var body: Node3D = owner_ref.get_ref() as Node3D if owner_ref != null else null
	if is_instance_valid(body):
		var stack: Array[Node] = [body]
		var found_mesh := false
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			for child_value: Variant in node.get_children():
				if child_value is Node:
					stack.append(child_value)
			if node is MeshInstance3D:
				var mesh_node := node as MeshInstance3D
				if mesh_node.visible and mesh_node.is_visible_in_tree() and mesh_node.mesh != null:
					found_mesh = true
					if section_bounds.intersects(mesh_node.global_transform * mesh_node.mesh.get_aabb()):
						return true
		if found_mesh:
			return false
	var cell_value: Variant = candidate.get("cell")
	if not cell_value is Vector3i:
		return true
	var scale := float(main.get("CELL"))
	if not is_finite(scale) or scale <= 0.0:
		return true
	var cell: Vector3i = cell_value
	var fallback_bounds := AABB(Vector3(cell) * scale, Vector3.ONE * scale)
	return section_bounds.intersects(fallback_bounds)


func _job_is_current(job: Dictionary, context: Dictionary) -> bool:
	if context.is_empty() or job.is_empty() or not job.get("bounds") is Rect2i:
		return false
	return String(context.main.get("seed_text")) == String(job.get("seed", 
		context.main.get("seed_text"))) \
		and int(context.system.get("ordinary_visual_revision")) == int(job.get("ordinaryRevision", -1)) \
		and int(context.system.get("regional_source_generation")) == int(job.get("generation", -1)) \
		and int(context.system.get("regional_source_revision")) == int(job.get("regionalRevision", \
			context.system.get("regional_source_revision"))) \
		and context.system.call("region_dependency_scheduling_revision", job.bounds) == job.get("dependencyRevision")


func _context(world_id: String) -> Dictionary:
	if world_id != _world_id or _world_id.is_empty():
		return {}
	var system: Object = _system_ref.get_ref() if _system_ref != null else null
	var main: Object = _main_ref.get_ref() if _main_ref != null else null
	if not is_instance_valid(system) or not is_instance_valid(main) \
			or system.get_instance_id() != _system_id or main.get_instance_id() != _main_id \
			or system.get("main") != main:
		return {}
	return {"system":system, "main":main}


func _coverage_revision(section: Vector3i, snapshot: Dictionary) -> String:
	var context := _context(_world_id)
	if context.is_empty(): return ""
	var payload := [SCHEMA, _world_id, section, String(snapshot.discoveryRevision),
		int(context.system.get("ordinary_visual_revision")), snapshot.sourceRows]
	return _sha256(var_to_bytes(payload))


func _removals_for(section: Vector3i, snapshot: Dictionary,
		coverage_revision: String) -> Array[Dictionary]:
	var previous: Dictionary = _installed_members_by_section.get(_section_id(section), {})
	var old_members: Dictionary = previous.get("members", {})
	var current_members: Dictionary = snapshot.get("sourceRevisions", {})
	var removals: Array[Dictionary] = []
	var old_ids: Array[String] = []
	for part_id_value: Variant in old_members:
		old_ids.append(String(part_id_value))
	old_ids.sort()
	var context := _context(_world_id)
	var authority_serial := int(context.system.get("ordinary_visual_revision")) if not context.is_empty() else -1
	for part_id: String in old_ids:
		if current_members.has(part_id): continue
		var prior_member: Dictionary = old_members.get(part_id, {})
		var source_id := String(prior_member.get("sourceId", ""))
		var authority_source_id := String(prior_member.get("authoritySourceId", ""))
		if source_id.is_empty():
			continue
		var revision := _sha256(var_to_bytes([SCHEMA, _world_id, section, part_id,
			String(prior_member.get("sourceRevision", "")), authority_serial, coverage_revision]))
		var row := {"sourceId":source_id, "sourcePartId":part_id,
			"authoritySourceId":authority_source_id, "sourceRevision":revision,
			"sectionKey":section, "reason":"ordinary_generated_visual_removed"}
		row.make_read_only()
		removals.append(row)
	removals.make_read_only()
	return removals


func _section_id(section: Vector3i) -> String:
	return "%d,%d,%d" % [section.x, section.y, section.z]


func _section_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "worldId":_world_id,
		"providerId":PROVIDER_ID, "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


func _failed(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"failed", "worldId":_world_id,
		"providerId":PROVIDER_ID, "reason":reason, "retryable":false}
	result.merge(detail, true)
	return result
