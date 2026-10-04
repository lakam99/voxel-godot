extends SceneTree

const Assembler := preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const REPORT_ENV := "VOXEL_WHOLE_SECTION_ASSEMBLER_REPORT"
const WORLD := "seed:whole-section-assembler-contract"
const SECTION := Vector3i.ZERO

var checks: Dictionary = {}
var mesh: ArrayMesh
var material: StandardMaterial3D
var batch_key := ""
var compatibility: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_shared_batch()
	var census := _census(["terrain:0,0,0", "ordinary:town-a:cell-0"],
		{"terrain:0,0,0":"terrain-r1", "ordinary:town-a:cell-0":"ordinary-r1"})
	var contributions := _contributions(census)
	var assembled: Dictionary = Assembler.assemble(census, SECTION, contributions, 1)
	var candidate: Dictionary = assembled.get("candidate", {})
	var snapshot: Dictionary = candidate.get("candidate", {}).get("snapshot", {})
	_check("cross_domain_inputs_share_one_partition_and_batch",
		assembled.get("status") == "ready" and assembled.get("providerCount") == 2
		and assembled.get("sourceCount") == 2 and assembled.get("inputCount") == 2
		and assembled.get("batchCount") == 1 and snapshot.get("contributorCount") == 2
		and snapshot.get("batchCount") == 1,
		{"assembly":assembled, "snapshotBatchCount":snapshot.get("batchCount", -1)})
	_check("candidate_is_complete_immutable_renderer_envelope",
		candidate.is_read_only()
		and candidate.get("schema") == Assembler.SCHEMA
		and candidate.get("candidate", {}).get("schema") == SnapshotBuilder.SCHEMA
		and candidate.get("contentManifestDigest", "").length() == 64
		and snapshot.get("renderLayers", []).size() == 3,
		{"schema":candidate.get("schema", ""), "digest":candidate.get("contentManifestDigest", ""),
		"layerCount":snapshot.get("renderLayers", []).size()})
	var missing_provider: Dictionary = Assembler.assemble(census, SECTION,
		_read_only([contributions[0]]), 2)
	_check("missing_provider_is_retryable_without_partial_candidate",
		missing_provider.get("status") == "pending"
		and bool(missing_provider.get("retryable", false)), missing_provider)
	var stale_source := _contributions(census)
	var stale_row: Dictionary = stale_source[0].duplicate(false)
	stale_row["authorityRevision"] = "stale-provider-revision"
	stale_row.make_read_only()
	var stale: Array = [stale_row, stale_source[1]]
	stale.make_read_only()
	var stale_result: Dictionary = Assembler.assemble(census, SECTION, stale, 3)
	_check("stale_provider_authority_is_retryable", stale_result.get("status") == "pending"
		and stale_result.get("reason") == "section_provider_authority_revision_mismatch", stale_result)
	var empty_census := _census([], {})
	var empty_contributions := _contributions(empty_census)
	var empty_result: Dictionary = Assembler.assemble(empty_census, SECTION, empty_contributions, 4)
	var empty_candidate: Dictionary = empty_result.get("candidate", {})
	var empty_snapshot: Dictionary = empty_candidate.get("candidate", {}).get("snapshot", {})
	_check("all_providers_must_attest_explicit_empty_section",
		empty_result.get("status") == "ready" and empty_candidate.is_read_only()
		and empty_snapshot.get("contributorCount") == 0
		and empty_snapshot.get("renderLayers", []).size() == 3,
		{"assembly":empty_result, "snapshot":empty_snapshot})
	var conflict_source := _contributions(census)
	var conflict_row: Dictionary = conflict_source[1].duplicate(false)
	var bad_compat := compatibility.duplicate(false)
	bad_compat["visibilityRangeEnd"] = 999.0
	bad_compat.make_read_only()
	var bad_compat_map := {batch_key:bad_compat}
	bad_compat_map.make_read_only()
	conflict_row["compatibilityByKey"] = bad_compat_map
	conflict_row.make_read_only()
	var conflict: Array = [conflict_source[0], conflict_row]
	conflict.make_read_only()
	var conflict_result: Dictionary = Assembler.assemble(census, SECTION, conflict, 5)
	_check("cross_domain_batch_compatibility_conflict_fails_closed",
		conflict_result.get("status") == "failed"
		and conflict_result.get("reason", "").begins_with("cross_domain_batch_compatibility_conflict"),
		conflict_result)
	_finish()


func _build_shared_batch() -> void:
	mesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, -0.5), Vector3(0.0, 0.0, 0.5)])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	material = StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.6, 0.4)
	var fingerprint: Dictionary = MeshFingerprint.inspect(mesh)
	var mesh_digest := String(fingerprint.get("contentDigest", ""))
	var mesh_resource_key := "contract-shared-triangle"
	var pipeline := "whole-section-contract-v1"
	var mesh_key := "%s|pipeline=%s|layer=opaque|sort=none" % [mesh_resource_key, pipeline]
	var bounds := mesh.get_aabb()
	var raw := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":"contract:foliage", "renderTier":"detail",
		"meshResourceKey":mesh_resource_key, "meshKey":mesh_key,
		"meshContentDigest":mesh_digest, "meshLocalBounds":bounds,
		"pipelineRevision":pipeline, "renderLayer":"opaque",
		"translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":240.0, "fadeMargin":12.0}
	batch_key = SnapshotBuilder.batch_compatibility_key(raw)
	raw["batchKey"] = batch_key
	raw["compatibilityKey"] = batch_key
	raw.make_read_only()
	compatibility = raw


func _census(parts: Array[String], revisions: Dictionary) -> Dictionary:
	var provider_ids := {"terrain:0,0,0":"terrain",
		"ordinary:town-a:cell-0":"ordinary"}
	var section_parts: Array[String] = parts.duplicate()
	section_parts.sort()
	section_parts.make_read_only()
	var expected := {SECTION:section_parts}
	expected.make_read_only()
	var revs := revisions.duplicate()
	revs.make_read_only()
	var providers := {"terrain":"terrain-authority-r1", "ordinary":"ordinary-authority-r1"}
	providers.make_read_only()
	var coverage := {
		"terrain":{SECTION:"terrain-coverage-r1"},
		"ordinary":{SECTION:"ordinary-coverage-r1"}}
	for provider_id in coverage:
		coverage[provider_id].make_read_only()
	coverage.make_read_only()
	provider_ids.make_read_only()
	var result := {"status":"complete", "worldId":WORLD,
		"sections":[SECTION], "sourceRevisions":revs,
		"sourceProviderIds":provider_ids, "expectedContributorsBySection":expected,
		"providerSnapshotRevisions":providers, "providerCoverageRevisions":coverage,
		"removalRevisions":{}, "censusDigest":"contract-census-r1"}
	result.sections.make_read_only()
	result.removalRevisions.make_read_only()
	result.make_read_only()
	return result


func _contributions(census: Dictionary) -> Array:
	var result: Array = []
	for provider_id: String in ["terrain", "ordinary"]:
		var parts := _parts_for_provider(census, provider_id)
		var inputs: Array = []
		var authority_revisions := {}
		for part_id: String in parts:
			var revision := String(census.sourceRevisions.get(part_id, ""))
			authority_revisions[part_id] = revision
			inputs.append(_input(provider_id, part_id, revision))
		inputs.make_read_only()
		authority_revisions.make_read_only()
		var compat := {}
		var mats := {}
		var meshes := {}
		var resources := {}
		if not inputs.is_empty():
			compat[batch_key] = compatibility
			mats["contract:foliage"] = material
			meshes["contract-shared-triangle"] = mesh
			resources[batch_key] = {"material":material, "mesh":mesh}
		compat.make_read_only()
		mats.make_read_only()
		meshes.make_read_only()
		resources.make_read_only()
		var row := {"providerId":provider_id, "sectionKey":SECTION,
			"coverageRevision":String(census.providerCoverageRevisions[provider_id][SECTION]),
			"authorityRevision":String(census.providerSnapshotRevisions[provider_id]),
			"authoritySourceRevisions":authority_revisions, "inputs":inputs,
			"compatibilityByKey":compat, "materialBindings":mats,
			"meshBindings":meshes, "resourceBindings":resources}
		row.make_read_only()
		result.append(row)
	result.make_read_only()
	return result


func _parts_for_provider(census: Dictionary, provider_id: String) -> Array[String]:
	var result: Array[String] = []
	for part_value: Variant in census.expectedContributorsBySection[SECTION]:
		var part_id := String(part_value)
		if String(census.sourceProviderIds[part_id]) == provider_id:
			result.append(part_id)
	return result


func _input(provider_id: String, part_id: String, revision: String) -> Dictionary:
	var buffer: Array[float] = []
	for value: float in Attributes.encode(Transform3D.IDENTITY, Color.WHITE):
		buffer.append(value)
	buffer.make_read_only()
	var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"sourceId":part_id, "sourcePartId":part_id,
		"sourceRevision":revision,
		"ownerCell":Grid.logical_owner_cell_for_world_position(Vector3(1, 0, 1)),
		"sourceToWorld":Transform3D(Basis.IDENTITY,
			Vector3(2.0 if provider_id == "terrain" else 4.0, 0.0, 2.0)),
		"meshLocalBounds":mesh.get_aabb(), "batchKey":batch_key,
		"segmentId":part_id + ":triangle", "buffer":buffer, "instanceCount":1}
	input.make_read_only()
	return input


func _read_only(values: Array) -> Array:
	values.make_read_only()
	return values


func _check(name: String, passed: bool, evidence: Variant) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _finish() -> void:
	var failures: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)):
			failures.append(name)
	var report := {"schema":"world-static-section-candidate-assembler-contract/v1",
		"complete":true, "passed":failures.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failures,
		"evidenceLevel":"synthetic_whole_section_candidate_contract",
		"doesNotProve":"native section installation, real provider parity, old representation retention, collision/interactions, saves, gameplay, or performance."}
	var path := OS.get_environment(REPORT_ENV)
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if failures.is_empty() else 1)
