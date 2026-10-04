extends SceneTree

const Publisher = preload("res://scripts/terrain/TerrainSectionShadowPublisher.gd")
const Assembler = preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")

const WORLD := "seed:terrain-section-contribution-contract"
const SECTION := Vector3i.ZERO
const SOURCE_PART := "resident-terrain:0,0,0:part"
const SOURCE_REVISION := "terrain-source-r1"
const PROVIDER_REVISION := "terrain-provider-r1"
const COVERAGE_REVISION := "terrain-coverage-r1"
const REPORT_ENV := "VOXEL_TERRAIN_SECTION_CONTRIBUTION_REPORT"

class FakeMesher extends RefCounted:
	var mesh: Mesh
	func build_mesh(_voxel_buffer: VoxelBuffer, _materials: Array) -> Mesh:
		return mesh

class FakeTerrain extends RefCounted:
	var mesher: FakeMesher
	var material_override: Material

class FakeRuntime extends RefCounted:
	var terrain: FakeTerrain
	var terrain_section_fluid_proofs: Dictionary = {}
	var provider_revision := PROVIDER_REVISION
	var source_revision := SOURCE_REVISION
	var copied := false
	var capture: Dictionary

	func _terrain_section_source_part_id(_section: Vector3i) -> String:
		return SOURCE_PART

	func capture_static_section_sources(world_id: String, _sections: Array) -> Dictionary:
		if world_id != WORLD:
			return {"status":"pending", "reason":"world_changed", "retryable":true}
		var coverage := {SECTION:{"status":"complete", "coverageRevision":COVERAGE_REVISION,
			"sourcePartIds":_readonly_values([SOURCE_PART])}}
		coverage.make_read_only()
		var revisions := {SOURCE_PART:source_revision}
		revisions.make_read_only()
		return {"status":"complete", "worldId":WORLD,
			"authorityRevision":provider_revision, "sourceRevisions":revisions,
			"sections":coverage}

	static func _readonly_values(values: Array) -> Array:
		var copy := values.duplicate()
		copy.make_read_only()
		return copy

	func _terrain_section_fluid_proof_is_current(_section: Vector3i, proof: Variant) -> bool:
		return proof is Dictionary and proof.is_read_only()

	func request_terrain_section_fluid_probe(_section: Vector3i) -> Dictionary:
		return {"status":"queued"}

	func capture_resident_terrain_mesh_block(_section: Vector3i) -> Dictionary:
		copied = true
		return capture

	func terrain_capture_authority_is_current(_capture: Dictionary) -> bool:
		return source_revision == SOURCE_REVISION and provider_revision == PROVIDER_REVISION

var _mesh: ArrayMesh
var _material: StandardMaterial3D
var _checks: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_build_resources()
	var runtime := _runtime(false)
	var publisher = Publisher.new()
	publisher.setup(runtime)
	var request: Dictionary = publisher.capture_contribution(_census(), SECTION)
	_check("contribution_preparation_is_bounded_and_retryable",
		request.get("status") == "pending" and bool(request.get("retryable", false))
		and not runtime.copied,
		{"result":request})
	publisher.advance()
	_check("capture_is_admitted_in_its_own_frame_step", runtime.copied,
		{"captureStage":true})
	publisher.advance()
	var ready: Dictionary = publisher.capture_contribution(_census(), SECTION)
	var contribution: Dictionary = ready.get("contribution", {})
	_check("sealed_transvoxel_contribution_matches_roster_revision",
		ready.get("status") == "ready" and contribution.is_read_only()
		and contribution.get("providerId") == "terrain"
		and contribution.get("sectionKey") == SECTION
		and contribution.get("authorityRevision") == PROVIDER_REVISION
		and contribution.get("coverageRevision") == COVERAGE_REVISION
		and contribution.get("authoritySourceRevisions", {}).get(SOURCE_PART) == SOURCE_REVISION
		and contribution.get("inputs", []).size() == 1,
		{"result":ready})
	var assembled: Dictionary = Assembler.assemble(_full_census(), SECTION,
		_readonly_array([contribution]), 1)
	_check("terrain_value_enters_shared_cross_domain_assembler",
		assembled.get("status") == "ready"
		and assembled.get("candidate", {}).get("candidate", {}).get("snapshot", {})
			.get("contributorCount") == 1,
		{"result":assembled})
	var mixed_census := _census()
	var mixed_expected := {SECTION:_readonly_array([
		SOURCE_PART, "building:structure:part", "ecology:prop:part"])}
	mixed_expected.make_read_only()
	mixed_census["expectedContributorsBySection"] = mixed_expected
	mixed_census.make_read_only()
	var mixed_runtime := _runtime(false)
	var mixed_publisher = Publisher.new()
	mixed_publisher.setup(mixed_runtime)
	var mixed_request: Dictionary = mixed_publisher.capture_contribution(mixed_census, SECTION)
	mixed_publisher.advance()
	mixed_publisher.advance()
	var mixed_result: Dictionary = mixed_publisher.capture_contribution(mixed_census, SECTION)
	_check("terrain_contribution_accepts_its_source_in_a_cross_domain_roster",
		mixed_request.get("status") == "pending"
		and mixed_result.get("status") == "ready"
		and mixed_result.get("contribution", {}).get(
			"authoritySourceRevisions", {}).get(SOURCE_PART) == SOURCE_REVISION,
		{"initial":mixed_request, "result":mixed_result})
	var retry_runtime := _runtime(false)
	retry_runtime.terrain_section_fluid_proofs.clear()
	var retry_publisher = Publisher.new()
	retry_publisher.setup(retry_runtime)
	retry_publisher.capture_contribution(_census(), SECTION)
	var deferred_retry: Dictionary = retry_publisher.advance()
	var queued_retry: Dictionary = retry_publisher._contribution_requests[0] \
		if not retry_publisher._contribution_requests.is_empty() else {}
	_check("fluid_defer_keeps_an_independent_complete_retry_identity",
		deferred_retry.get("status") == "pending"
		and deferred_retry.get("reason") == "terrain_exact_fluid_section_probe_pending"
		and retry_publisher._active_contribution.is_empty()
		and queued_retry.get("sectionKey") == SECTION
		and String(queued_retry.get("worldId", "")) == WORLD
		and String(queued_retry.get("providerRevision", "")) == PROVIDER_REVISION
		and String(queued_retry.get("coverageRevision", "")) == COVERAGE_REVISION
		and String(queued_retry.get("sourcePartId", "")) == SOURCE_PART
		and String(queued_retry.get("sourceRevision", "")) == SOURCE_REVISION,
		{"result":deferred_retry, "queuedRetry":queued_retry})
	var current_no_fluid_proof := {"hasFluid":false, "signature":"fluid-r1"}
	current_no_fluid_proof.make_read_only()
	retry_runtime.terrain_section_fluid_proofs[SECTION] = current_no_fluid_proof
	retry_publisher.advance()
	retry_publisher.advance()
	var retried_contribution: Dictionary = retry_publisher.capture_contribution(
		_census(), SECTION)
	_check("deferred_fluid_request_retries_to_a_sealed_contribution",
		retried_contribution.get("status") == "ready"
		and retry_runtime.copied
		and retried_contribution.get("contribution", {}).is_read_only(),
		{"result":retried_contribution})
	var fluid_runtime := _runtime(true)
	var fluid_publisher = Publisher.new()
	fluid_publisher.setup(fluid_runtime)
	fluid_publisher.capture_contribution(_census(), SECTION)
	var fluid_result: Dictionary = fluid_publisher.advance()
	_check("fluid_bearing_section_stays_pending_without_translucent_sorting",
		fluid_result.get("status") == "pending"
		and fluid_result.get("reason") == "terrain_fluid_section_layer_not_supported"
		and not fluid_runtime.copied,
		{"result":fluid_result})
	var stale_runtime := _runtime(false)
	var stale_publisher = Publisher.new()
	stale_publisher.setup(stale_runtime)
	stale_publisher.capture_contribution(_census(), SECTION)
	stale_runtime.provider_revision = "terrain-provider-r2"
	var stale_result: Dictionary = stale_publisher.advance()
	_check("provider_revision_change_discards_queued_capture",
		stale_result.get("status") == "pending"
		and stale_result.get("reason") == "terrain_contribution_census_changed_before_capture"
		and not stale_runtime.copied,
		{"result":stale_result})
	_finish()

func _runtime(has_fluid: bool) -> FakeRuntime:
	var fake := FakeRuntime.new()
	fake.terrain = FakeTerrain.new()
	var mesher := FakeMesher.new()
	mesher.mesh = _mesh
	fake.terrain.mesher = mesher
	fake.terrain.material_override = _material
	var fluid := {"hasFluid":has_fluid, "signature":"fluid-r1"}
	fluid.make_read_only()
	fake.terrain_section_fluid_proofs[SECTION] = fluid
	var bytes_sdf := PackedByteArray()
	bytes_sdf.resize(19 * 19 * 19 * 2)
	var bytes_indices := PackedByteArray()
	bytes_indices.resize(19 * 19 * 19)
	var bytes_data5 := PackedByteArray()
	bytes_data5.resize(19 * 19 * 19)
	fake.capture = {"status":"ready", "schema":"resident-terrain-mesh-block/v1",
		"block":SECTION, "size":Vector3i.ONE * 19, "sdf16Le":bytes_sdf,
		"indices8":bytes_indices, "data5_8":bytes_data5,
		"payloadDigest":"fixture", "sourceRevision":SOURCE_REVISION}
	fake.capture.make_read_only()
	return fake

func _census() -> Dictionary:
	var source_revisions := {SOURCE_PART:SOURCE_REVISION}
	source_revisions.make_read_only()
	var coverage_by_section := {SECTION:COVERAGE_REVISION}
	coverage_by_section.make_read_only()
	var provider_coverage := {"terrain":coverage_by_section}
	provider_coverage.make_read_only()
	var provider_revisions := {"terrain":PROVIDER_REVISION}
	provider_revisions.make_read_only()
	var expected_by_section := {SECTION:_readonly_array([SOURCE_PART])}
	expected_by_section.make_read_only()
	return {"status":"complete", "worldId":WORLD,
		"sourceRevisions":source_revisions,
		"providerSnapshotRevisions":provider_revisions,
		"providerCoverageRevisions":provider_coverage,
		"expectedContributorsBySection":expected_by_section}

func _full_census() -> Dictionary:
	var base := _census()
	var provider_ids := {SOURCE_PART:"terrain"}
	provider_ids.make_read_only()
	var rems := {}
	rems.make_read_only()
	var result := {"status":"complete", "worldId":WORLD,
		"sections":_readonly_array([SECTION]),
		"sourceRevisions":base.sourceRevisions,
		"sourceProviderIds":provider_ids,
		"providerSnapshotRevisions":base.providerSnapshotRevisions,
		"providerCoverageRevisions":base.providerCoverageRevisions,
		"expectedContributorsBySection":base.expectedContributorsBySection,
		"removalRevisions":rems, "censusDigest":"terrain-census-r1"}
	result.make_read_only()
	return result

func _build_resources() -> void:
	_mesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0.2, 0.2, 0.2), Vector3(0.8, 0.2, 0.2), Vector3(0.2, 0.8, 0.8)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_material = StandardMaterial3D.new()

func _check(name: String, passed: bool, detail: Dictionary) -> void:
	_checks[name] = {"passed":passed, "detail":detail}

func _finish() -> void:
	var passed := true
	for value: Variant in _checks.values():
		passed = passed and bool(value.get("passed", false))
	var report := {"schema":"terrain_section_contribution_contract/v1",
		"passed":passed, "checkCount":_checks.size(),
		"checks":_checks,
		"evidenceLevel":"synthetic_terrain_provider_and_shared_assembler_contract",
		"limitations":["does not read live VoxelData", "does not prove fluid rendering",
			"does not install a normal-world section or prove gameplay visuals"]}
	var path := OS.get_environment(REPORT_ENV)
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if passed else 1)

static func _readonly_array(values: Array) -> Array:
	var copy := values.duplicate()
	copy.make_read_only()
	return copy
