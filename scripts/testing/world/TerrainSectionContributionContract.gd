extends SceneTree

const Publisher = preload("res://scripts/terrain/TerrainSectionShadowPublisher.gd")
const Assembler = preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const TerrainMeshingService = preload("res://scripts/TerrainMeshingService.gd")
const PacketOwner = preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession = preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const ProductionMain = preload("res://scripts/MainSetupScene.gd")

const WORLD := "seed:terrain-section-contribution-contract"
const SECTION := Vector3i.ZERO
const SOURCE_PART := "resident-terrain:0,0,0:part"
const SOURCE_REVISION := "terrain-source-r1"
const PROVIDER_REVISION := "terrain-provider-r1"
const COVERAGE_REVISION := "terrain-coverage-r1"
const SECTION_SIZE := 16
const REPORT_ENV := "VOXEL_TERRAIN_SECTION_CONTRIBUTION_REPORT"

class FakeMesher extends RefCounted:
	var mesh: Mesh
	var on_build: Callable
	func build_mesh(_voxel_buffer: VoxelBuffer, _materials: Array) -> Mesh:
		if on_build.is_valid():
			on_build.call()
		return mesh

class FakeTerrain extends RefCounted:
	var mesher: FakeMesher
	var material_override: Material

class FakeRuntime extends RefCounted:
	var main: Node
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
		return proof is Dictionary and proof.is_read_only() \
			and proof.get("sectionKey") == SECTION \
			and int(proof.get("volumeRevision", -1)) == 7 \
			and int(proof.get("fluidRevision", -1)) == 9 \
			and not String(proof.get("signature", "")).is_empty()

	func request_terrain_section_fluid_probe(_section: Vector3i) -> Dictionary:
		return {"status":"queued"}

	func capture_resident_terrain_mesh_block(_section: Vector3i) -> Dictionary:
		copied = true
		return capture

	func terrain_capture_authority_is_current(_capture: Dictionary) -> bool:
		return source_revision == SOURCE_REVISION and provider_revision == PROVIDER_REVISION

class TestMain extends Node3D:
	var terrain_meshing_service
	var materials: Dictionary = {}
	var terrain_material: Material
	var world_static_section_coordinator
	var section_owner: Node3D
	var section_backend: Node3D
	var chunks: Dictionary = {}
	var pov_revision := 14
	var bump_pov_on_next_mesh := false

	func get_static_section_render_owner(owner_cell: Vector2i,
			_create_if_missing: bool) -> Dictionary:
		if owner_cell != Vector2i.ZERO or not is_instance_valid(section_owner) \
				or not is_instance_valid(section_backend):
			return {"status":"pending", "reason":"fixture_section_owner_unavailable"}
		return {"status":"ready", "owner":section_owner, "backend":section_backend}

	func current_translucent_pov_snapshot(section_key: Vector3i) -> Dictionary:
		return {"status":"ready", "sectionKey":section_key,
			"cameraPosition":Vector3(7.0, 6.0, 8.0),
			"povClass":Vector3i.ZERO, "revision":pov_revision}

	func advance_test_pov() -> void:
		if bump_pov_on_next_mesh:
			bump_pov_on_next_mesh = false
			pov_revision += 1

class CensusMain extends Node:
	var seed_text := "terrain-census-contract"
	var seed_hash := 73
	var world_generation_system := CensusWorldGeneration.new()

class CensusFluidVolume extends RefCounted:
	var revision := 7
	var fluid_revision := 9
	var section_revisions := {Vector3i.ZERO:11}

	func exact_fluid_section_revision(section_key: Vector3i) -> int:
		return int(section_revisions.get(section_key, 0))

	func exact_fluid_payload_bounds(start_x: int, start_z: int, chunk_size: int,
			min_y: int, max_y: int) -> Dictionary:
		var low_y := mini(min_y, max_y)
		var high_y := maxi(min_y, max_y)
		var safe_size := maxi(1, chunk_size)
		var min_cell := Vector3i(start_x - 1, low_y - 1, start_z - 1)
		var max_cell := Vector3i(start_x + safe_size, high_y + 1, start_z + safe_size)
		return {"status":"ready", "minCell":min_cell, "maxCell":max_cell}

class CensusWorldGeneration extends RefCounted:
	var terrain_volume_service = CensusFluidVolume.new()

class TerrainCensusRuntime extends "res://scripts/terrain/VoxelTerrainRuntime.gd":
	var probe_request_count := 0

	func generation_context_current() -> bool:
		return true

	func _terrain_section_source_revision(section_key: Vector3i,
			fluid_signature := "") -> String:
		return "terrain:%d,%d,%d:%s" % [section_key.x, section_key.y,
			section_key.z, fluid_signature]

	func request_terrain_section_fluid_probe(_section_key: Vector3i) -> Dictionary:
		probe_request_count += 1
		return {"status":"queued"}

var _mesh: ArrayMesh
var _material: StandardMaterial3D
var _production_materials: Dictionary = {}
var _production_material_owner: Node
var _queued_fluid_contribution: Dictionary = {}
var _checks: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_build_resources()
	_run_terrain_fluid_source_census_contract()
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
	var retry_publisher = Publisher.new()
	retry_publisher.setup(retry_runtime)
	retry_publisher.capture_contribution(_census(), SECTION)
	retry_runtime.terrain_section_fluid_proofs.clear()
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
	var current_no_fluid_proof := {"sectionKey":SECTION, "hasFluid":false,
		"volumeRevision":7, "fluidRevision":9, "signature":"fluid-r1"}
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
	var fluid_request: Dictionary = fluid_publisher.capture_contribution(_census(), SECTION)
	var fluid_result: Dictionary = fluid_publisher.advance()
	_check("fluid_bearing_section_stays_pending_without_exact_payload_or_current_pov",
		fluid_request.get("status") == "pending"
		and fluid_request.get("reason") == "section_translucent_pov_snapshot_unavailable"
		and fluid_result.get("status") == "idle"
		and not fluid_runtime.copied,
		{"request":fluid_request, "advance":fluid_result})
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
	_run_real_native_fluid_candidate_install()
	_finish()


func _run_terrain_fluid_source_census_contract() -> void:
	var runtime := TerrainCensusRuntime.new()
	runtime.authority_ready = true
	runtime.main = CensusMain.new()
	var fluid_proof := _production_fluid_proof(true)
	runtime.terrain_section_fluid_proofs[SECTION] = fluid_proof
	var world_id := "seed:terrain-census-contract:73"
	var fluid_census: Dictionary = runtime.capture_static_section_sources(world_id, [SECTION])
	var source_part_id := runtime._terrain_section_source_part_id(SECTION)
	var fluid_revision := String(fluid_census.get("sourceRevisions", {}).get(source_part_id, ""))
	_check("production_terrain_census_admits_current_fluid_source_revision",
		fluid_census.get("status") == "complete"
		and fluid_census.get("sections", {}).get(SECTION, {}).get("status") == "complete"
		and fluid_census.get("sections", {}).get(SECTION, {}).get("sourcePartIds", []).has(source_part_id)
		and not fluid_revision.is_empty(),
		{"census":fluid_census, "sourcePartId":source_part_id})
	var fluid_volume = runtime.main.world_generation_system.terrain_volume_service
	fluid_volume.fluid_revision = 10
	var changed_fluid_proof := _production_fluid_proof(true, 10)
	runtime.terrain_section_fluid_proofs[SECTION] = changed_fluid_proof
	var changed_fluid_census: Dictionary = runtime.capture_static_section_sources(world_id, [SECTION])
	_check("fluid_signature_change_invalidates_terrain_source_revision",
		changed_fluid_census.get("status") == "complete"
		and String(changed_fluid_census.get("sourceRevisions", {}).get(source_part_id, ""))
		!= fluid_revision,
		{"before":fluid_revision, "after":changed_fluid_census.get(
			"sourceRevisions", {}).get(source_part_id, "")})
	fluid_volume.section_revisions[SECTION] = 12
	var stale_census: Dictionary = runtime.capture_static_section_sources(world_id, [SECTION])
	_check("production_terrain_census_keeps_stale_fluid_pending_and_retryable",
		stale_census.get("status") == "pending"
		and stale_census.get("reason") == "terrain_exact_fluid_section_probe_pending"
		and bool(stale_census.get("retryable", false))
		and runtime.probe_request_count == 1,
		{"census":stale_census, "probeRequests":runtime.probe_request_count})
	fluid_volume.section_revisions[SECTION] = 11
	var mutable_nested_proof := _production_fluid_proof(true, 10, false)
	runtime.terrain_section_fluid_proofs[SECTION] = mutable_nested_proof
	var mutable_census: Dictionary = runtime.capture_static_section_sources(world_id, [SECTION])
	_check("production_terrain_census_rejects_mutable_nested_fluid_proof",
		mutable_census.get("status") == "pending"
		and mutable_census.get("reason") == "terrain_exact_fluid_section_probe_pending",
		{"census":mutable_census})
	var missing_target_proof := _production_fluid_proof(true, 10, true, false)
	runtime.terrain_section_fluid_proofs[SECTION] = missing_target_proof
	var missing_target_census: Dictionary = runtime.capture_static_section_sources(world_id, [SECTION])
	_check("production_terrain_census_requires_exact_target_section_revision",
		missing_target_census.get("status") == "pending"
		and missing_target_census.get("reason") == "terrain_exact_fluid_section_probe_pending",
		{"census":missing_target_census})
	var truncated_dependency_proof := _production_fluid_proof(true,
		10, true, true, "truncated")
	runtime.terrain_section_fluid_proofs[SECTION] = truncated_dependency_proof
	var truncated_dependency_census: Dictionary = runtime.capture_static_section_sources(
		world_id, [SECTION])
	_check("production_terrain_census_rejects_truncated_current_dependency_set",
		truncated_dependency_census.get("status") == "pending"
		and truncated_dependency_census.get("reason") == "terrain_exact_fluid_section_probe_pending",
		{"dependencyCount":truncated_dependency_proof.get("sectionRevisions", []).size(),
		"census":truncated_dependency_census})
	var extra_dependency_proof := _production_fluid_proof(true,
		10, true, true, "extra")
	runtime.terrain_section_fluid_proofs[SECTION] = extra_dependency_proof
	var extra_dependency_census: Dictionary = runtime.capture_static_section_sources(
		world_id, [SECTION])
	_check("production_terrain_census_rejects_out_of_bounds_dependency_row",
		extra_dependency_census.get("status") == "pending"
		and extra_dependency_census.get("reason") == "terrain_exact_fluid_section_probe_pending",
		{"dependencyCount":extra_dependency_proof.get("sectionRevisions", []).size(),
		"census":extra_dependency_census})
	var duplicate_dependency_proof := _production_fluid_proof(true,
		10, true, true, "duplicate")
	runtime.terrain_section_fluid_proofs[SECTION] = duplicate_dependency_proof
	var duplicate_dependency_census: Dictionary = runtime.capture_static_section_sources(
		world_id, [SECTION])
	_check("production_terrain_census_rejects_duplicate_dependency_row",
		duplicate_dependency_census.get("status") == "pending"
		and duplicate_dependency_census.get("reason") == "terrain_exact_fluid_section_probe_pending",
		{"dependencyCount":duplicate_dependency_proof.get("sectionRevisions", []).size(),
		"census":duplicate_dependency_census})
	var malformed_fields: Array[Dictionary] = [
		{"field":"volumeRevision", "value":"7"},
		{"field":"fluidRevision", "value":9.0},
		{"field":"sectionRevision", "value":"11"},
		{"field":"signature", "value":123}
	]
	var malformed_proofs_rejected := true
	var malformed_results: Array[Dictionary] = []
	for malformed_case: Dictionary in malformed_fields:
		var malformed_proof := _malformed_production_fluid_proof(
			String(malformed_case.field), malformed_case.value)
		runtime.terrain_section_fluid_proofs[SECTION] = malformed_proof
		var malformed_census: Dictionary = runtime.capture_static_section_sources(world_id, [SECTION])
		var rejected: bool = not runtime._terrain_section_fluid_proof_is_current(SECTION, malformed_proof) \
			and malformed_census.get("status") == "pending" \
			and malformed_census.get("reason") == "terrain_exact_fluid_section_probe_pending"
		malformed_proofs_rejected = malformed_proofs_rejected and rejected
		malformed_results.append({"field":malformed_case.field,
			"predicateRejected":not runtime._terrain_section_fluid_proof_is_current(
				SECTION, malformed_proof), "census":malformed_census})
	_check("production_terrain_census_rejects_coercible_revision_and_signature_types",
		malformed_proofs_rejected, {"cases":malformed_results})
	var current_empty_proof := _production_fluid_proof(false, 10)
	runtime.terrain_section_fluid_proofs[SECTION] = current_empty_proof
	var empty_census: Dictionary = runtime.capture_static_section_sources(world_id, [SECTION])
	_check("current_exact_no_fluid_proof_is_admitted_as_explicit_empty_source",
		empty_census.get("status") == "complete"
		and runtime._terrain_section_fluid_proof_is_current(SECTION, current_empty_proof)
		and not bool(current_empty_proof.get("hasFluid", true)),
		{"census":empty_census, "proof":current_empty_proof})
	_run_finalized_production_fluid_signature_contract()
	runtime.terrain_section_fluid_proofs.erase(SECTION)
	var missing_census: Dictionary = runtime.capture_static_section_sources(world_id, [SECTION])
	_check("production_terrain_census_never_treats_missing_fluid_proof_as_empty",
		missing_census.get("status") == "pending"
		and missing_census.get("reason") == "terrain_exact_fluid_section_probe_pending"
		and bool(missing_census.get("retryable", false))
		and runtime.probe_request_count == 11,
		{"census":missing_census, "probeRequests":runtime.probe_request_count})
	runtime.main.free()
	runtime.free()
	_run_queued_fluid_contribution_contract()


func _run_finalized_production_fluid_signature_contract() -> void:
	var service := preload("res://scripts/TerrainVolumeService.gd").new()
	service.revision = 7
	service.fluid_revision = 9
	service.section_revisions[SECTION] = 11
	var dependency_keys: Array[Vector3i] = []
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				dependency_keys.append(Vector3i(x, y, z))
	var payload: Dictionary = service.finalized_exact_fluid_payload_from_state({
		"sectionKeys":dependency_keys, "volumeRevision":7, "fluidRevision":9,
		"minCell":Vector3i(-1, -1, -1), "maxCell":Vector3i(16, 16, 16),
		"hasFluid":false})
	var immutable_rows: Array[Dictionary] = []
	for row_value: Variant in payload.get("sectionRevisions", []):
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value.duplicate()
		row.make_read_only()
		immutable_rows.append(row)
	immutable_rows.make_read_only()
	var proof := {"schema":"terrain-fluid-section-proof/v2",
		"sectionKey":SECTION, "hasFluid":false, "volumeRevision":7,
		"fluidRevision":9, "boundsInclusive":true,
		"minCell":payload.get("minCell"), "maxCell":payload.get("maxCell"),
		"sectionRevisions":immutable_rows,
		"signature":String(payload.get("signature", ""))}
	proof.make_read_only()
	var runtime := TerrainCensusRuntime.new()
	runtime.authority_ready = true
	runtime.main = CensusMain.new()
	runtime.main.world_generation_system.terrain_volume_service = service
	var valid := runtime._terrain_section_fluid_proof_is_current(SECTION, proof)
	var forged_bounds: Dictionary = proof.duplicate(false)
	forged_bounds["minCell"] = SECTION * SECTION_SIZE
	forged_bounds["maxCell"] = SECTION * SECTION_SIZE + Vector3i.ONE * (SECTION_SIZE - 1)
	forged_bounds["sectionRevisions"] = _readonly_array([immutable_rows[13]])
	var forged_signature_parts := PackedStringArray(["0,0,0:11"])
	forged_bounds["signature"] = "exact-fluid-v2:%s" % Marshalls.raw_to_base64(
		var_to_bytes(["exact-fluid-capture/v2", 7, 9,
			forged_bounds.minCell, forged_bounds.maxCell, forged_signature_parts])).sha256_text()
	forged_bounds.make_read_only()
	_check("production_fluid_signature_binds_exact_bounds_and_complete_rows",
		payload.get("signature", "").begins_with("exact-fluid-v2:")
		and payload.get("sectionRevisions", []).size() == 27
		and valid
		and not runtime._terrain_section_fluid_proof_is_current(SECTION, forged_bounds),
		{"signature":payload.get("signature", ""),
		"dependencyCount":payload.get("sectionRevisions", []).size(),
		"validProductionProof":valid,
		"forgedSignatureBindsToNarrowBounds":String(forged_bounds.signature)
			== "exact-fluid-v2:%s" % Marshalls.raw_to_base64(var_to_bytes([
				"exact-fluid-capture/v2", 7, 9, forged_bounds.minCell,
				forged_bounds.maxCell, forged_signature_parts])).sha256_text(),
		"forgedBoundsAccepted":runtime._terrain_section_fluid_proof_is_current(
			SECTION, forged_bounds)})
	runtime.main.free()
	runtime.free()


func _production_fluid_proof(has_fluid: bool, fluid_revision := 9,
		freeze_nested := true, include_target_section := true,
		dependency_shape := "complete") -> Dictionary:
	var min_cell := Vector3i(-1, -1, -1)
	var max_cell := Vector3i(16, 16, 16)
	var rows: Array[Dictionary] = []
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var dependency_key := Vector3i(x, y, z)
				if not include_target_section and dependency_key == SECTION:
					continue
				if dependency_shape == "truncated" and dependency_key == Vector3i(-1, 0, 0):
					continue
				var row := {"sectionKey":dependency_key,
					"revision":11 if dependency_key == SECTION else 0}
				if freeze_nested:
					row.make_read_only()
				rows.append(row)
	if dependency_shape == "extra":
		var extra_row := {"sectionKey":Vector3i(2, 0, 0), "revision":0}
		if freeze_nested:
			extra_row.make_read_only()
		rows.append(extra_row)
	if dependency_shape == "duplicate":
		var duplicate_row := {"sectionKey":SECTION, "revision":11}
		if freeze_nested:
			duplicate_row.make_read_only()
		rows.append(duplicate_row)
	if freeze_nested:
		rows.make_read_only()
	var signature_sections: Array[Vector3i] = []
	var revision_by_section: Dictionary = {}
	for row_value: Dictionary in rows:
		if not revision_by_section.has(row_value.sectionKey):
			signature_sections.append(row_value.sectionKey)
		revision_by_section[row_value.sectionKey] = row_value.revision
	signature_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var signature_parts := PackedStringArray()
	for dependency_key: Vector3i in signature_sections:
		var key_text := "%d,%d,%d" % [dependency_key.x, dependency_key.y, dependency_key.z]
		signature_parts.append("%s:%d" % [key_text, int(revision_by_section[dependency_key])])
	var signature := "exact-fluid-v2:%s" % Marshalls.raw_to_base64(var_to_bytes([
		"exact-fluid-capture/v2", 7, fluid_revision, min_cell, max_cell,
		signature_parts])).sha256_text()
	var proof := {"schema":"terrain-fluid-section-proof/v2",
		"sectionKey":SECTION, "hasFluid":has_fluid, "volumeRevision":7,
		"fluidRevision":fluid_revision, "boundsInclusive":true,
		"minCell":min_cell, "maxCell":max_cell,
		"sectionRevisions":rows, "signature":signature}
	proof.make_read_only()
	return proof


func _malformed_production_fluid_proof(field: String, value: Variant) -> Dictionary:
	var proof: Dictionary = _production_fluid_proof(true).duplicate(false)
	if field == "sectionRevision":
		var row := {"sectionKey":SECTION, "revision":value}
		row.make_read_only()
		var rows: Array[Dictionary] = [row]
		rows.make_read_only()
		proof["sectionRevisions"] = rows
	else:
		proof[field] = value
	proof.make_read_only()
	return proof


func _run_queued_fluid_contribution_contract() -> void:
	var main_node := TestMain.new()
	var meshing_service = TerrainMeshingService.new()
	meshing_service.setup(main_node)
	main_node.terrain_meshing_service = meshing_service
	main_node.materials = _production_materials
	main_node.world_static_section_coordinator = main_node
	get_root().add_child(main_node)
	var runtime := _runtime(true)
	runtime.main = main_node
	var publisher = Publisher.new()
	publisher.setup(runtime)
	var missing_payload_admission: Dictionary = publisher.capture_contribution(_census(), SECTION)
	var missing_payload: Dictionary = publisher.advance()
	var fluid_payload := _one_water_cell_payload()
	var proof: Dictionary = _current_fluid_proof()
	runtime.terrain_section_fluid_proofs[SECTION] = proof
	var retained: Dictionary = publisher.retain_exact_fluid_payload(SECTION,
		fluid_payload, proof)
	main_node.pov_revision = 0
	var missing_pov: Dictionary = publisher.capture_contribution(_census(), SECTION)
	main_node.pov_revision = 14
	var admission: Dictionary = publisher.capture_contribution(_census(), SECTION)
	var capture_step: Dictionary = publisher.advance()
	main_node.bump_pov_on_next_mesh = true
	runtime.terrain.mesher.on_build = Callable(main_node, "advance_test_pov")
	var build_step: Dictionary = publisher.advance()
	var stale_pov_retry: Dictionary = publisher.advance()
	var prepared: Dictionary = publisher.capture_contribution(_census(), SECTION)
	var contribution: Dictionary = prepared.get("contribution", {})
	_queued_fluid_contribution = contribution
	var contribution_inputs: Array = contribution.get("inputs", [])
	var contribution_pov_revision := -1
	var compatibility_values: Dictionary = contribution.get("compatibilityByKey", {})
	for compatibility_value: Variant in compatibility_values.values():
		if not compatibility_value is Dictionary:
			continue
		var descriptor: Dictionary = (compatibility_value as Dictionary).get(
			"translucentSortDescriptor", {})
		if not descriptor.is_empty():
			contribution_pov_revision = int(descriptor.get("povRevision", -1))
	_check("exact_current_fluid_proof_and_payload_reach_sealed_terrain_contribution",
		missing_payload_admission.get("status") == "pending"
		and missing_payload.get("status") == "pending"
		and missing_payload.get("reason") == "terrain_exact_fluid_candidate_payload_evicted"
		and bool(missing_payload.get("retryable", false))
		and retained.get("status") == "ready"
		and missing_pov.get("status") == "pending"
		and publisher._contribution_requests.size() == 0
		and admission.get("status") == "pending"
		and capture_step.get("stage") == "mesh_prepare"
		and build_step.get("status") == "pending"
		and build_step.get("reason") == "terrain_translucent_pov_changed_after_mesh_prepare"
		and stale_pov_retry.get("status") == "prepared"
		and prepared.get("status") == "ready"
		and contribution.is_read_only()
		and contribution_inputs.size() == 2
		and String(contribution_inputs[1].get("renderLayer", "")) == "translucent"
		and contribution_pov_revision == 15,
		{"missingPayloadAdmission":missing_payload_admission,
		"missingPayload":missing_payload, "retained":retained,
		"missingPov":missing_pov, "admission":admission,
		"captureStep":capture_step,
		"buildStep":build_step, "stalePovRetry":stale_pov_retry, "prepared":prepared,
		"contributionPovRevision":contribution_pov_revision})
	main_node.free()

func _run_real_native_fluid_candidate_install() -> void:
	var main_node := TestMain.new()
	main_node.terrain_material = _material
	main_node.materials = _production_materials
	var service = TerrainMeshingService.new()
	service.setup(main_node)
	main_node.terrain_meshing_service = service
	var runtime := _runtime(false)
	runtime.main = main_node
	main_node.name = "TerrainFluidInstallWorld"
	get_root().add_child(main_node)
	current_scene = main_node
	var publisher = Publisher.new()
	publisher.setup(runtime)
	var built_by_kind: Dictionary = {}
	var candidate_by_kind: Dictionary = {}
	for fluid_case: Dictionary in [
		{"kind":"water", "typeId":1},
		{"kind":"lava", "typeId":2}]:
		var fluid_kind := String(fluid_case.kind)
		var built: Dictionary = publisher._build_candidate(runtime.capture, SOURCE_PART,
			SOURCE_REVISION, _one_water_cell_payload(int(fluid_case.typeId)), _test_pov_snapshot())
		var contribution: Dictionary = built.get("contribution", {}).duplicate(false)
		contribution["authorityRevision"] = PROVIDER_REVISION
		contribution["coverageRevision"] = COVERAGE_REVISION
		contribution.make_read_only()
		var candidate_result: Dictionary = Assembler.assemble(_full_census(), SECTION,
			_readonly_array([contribution]), 73)
		var candidate_snapshot: Dictionary = candidate_result.get("candidate", {}).get("candidate", {}).get("snapshot", {})
		var matching_batch: Dictionary = {}
		for batch_value: Variant in candidate_snapshot.get("batches", {}).values():
			if batch_value is Dictionary and String((batch_value as Dictionary).get("materialKey", "")) == "production-fluid:%s" % fluid_kind:
				matching_batch = batch_value
		var material := _production_materials.get(fluid_kind) as Material
		var material_key := String(matching_batch.get("materialKey", ""))
		var candidate_material_bindings: Dictionary = candidate_result.get("candidate", {}).get(
			"materialBindings", {})
		var candidate_material: Material = candidate_material_bindings.get(material_key) as Material
		_check("production_%s_material_candidate_matches_translucent_camera_policy" % fluid_kind,
			built.get("status") == "ready" and candidate_result.get("status") == "ready"
			and not matching_batch.is_empty() and candidate_material != null
			and candidate_material.get_class() == material.get_class()
			and _render_layer_expected_batches(candidate_snapshot, "translucent") == 1
			and String(matching_batch.get("renderLayer", "")) == "translucent"
			and String(matching_batch.get("transparencySortPolicy", "")) == "camera_depth",
			{"buildStatus":built.get("status", ""),
			"candidateStatus":candidate_result.get("status", ""),
			"materialType":material.get_class() if material != null else "missing",
			"candidateMaterialType":candidate_material.get_class() if candidate_material != null else "missing",
			"materialTransparency":(material as BaseMaterial3D).transparency
				if material is BaseMaterial3D else "shader-defined",
			"batch":matching_batch})
		built_by_kind[fluid_kind] = built
		candidate_by_kind[fluid_kind] = candidate_result
		if fluid_kind == "water" and not _queued_fluid_contribution.is_empty():
			candidate_by_kind[fluid_kind] = Assembler.assemble(_full_census(), SECTION,
				_readonly_array([_queued_fluid_contribution]), 73)
	runtime.terrain_section_fluid_proofs[SECTION] = _current_fluid_proof()
	runtime.terrain.mesher.mesh = ArrayMesh.new()
	var fluid_only_built: Dictionary = publisher._build_candidate(runtime.capture,
		SOURCE_PART, SOURCE_REVISION, _one_water_cell_payload(), _test_pov_snapshot())
	var fluid_only_contribution: Dictionary = fluid_only_built.get("contribution", {}).duplicate(false)
	fluid_only_contribution["authorityRevision"] = PROVIDER_REVISION
	fluid_only_contribution["coverageRevision"] = COVERAGE_REVISION
	fluid_only_contribution.make_read_only()
	var fluid_only_candidate: Dictionary = Assembler.assemble(_full_census(), SECTION,
		_readonly_array([fluid_only_contribution]), 74)
	var fluid_only_snapshot: Dictionary = fluid_only_candidate.get("candidate", {}) \
		.get("candidate", {}).get("snapshot", {})
	_check("fluid_only_section_keeps_translucent_candidate_when_sdf_mesh_is_empty",
		fluid_only_built.get("status") == "ready"
		and fluid_only_built.get("mesh") == null
		and fluid_only_candidate.get("status") == "ready"
		and _render_layer_expected_batches(fluid_only_snapshot, "opaque") == 0
		and _render_layer_expected_batches(fluid_only_snapshot, "translucent") == 1,
		{"build":fluid_only_built, "candidateStatus":fluid_only_candidate.get("status", ""),
		"candidateReason":fluid_only_candidate.get("reason", ""),
		"layers":fluid_only_snapshot.get("renderLayers", [])})
	var built: Dictionary = built_by_kind.get("water", {})
	var candidate_result: Dictionary = candidate_by_kind.get("water", {})
	var contribution: Dictionary = _queued_fluid_contribution
	var envelope: Dictionary = candidate_result.get("candidate", {}).get("candidate", {})
	var snapshot: Dictionary = envelope.get("snapshot", {})
	var translucent_batches := 0
	for batch_value: Variant in snapshot.get("batches", {}).values():
		if batch_value is Dictionary and String((batch_value as Dictionary).get("renderLayer", "")) == "translucent":
			translucent_batches += 1
	var chunk := Node3D.new()
	chunk.name = "Chunk_0_0"
	main_node.add_child(chunk)
	main_node.chunks[Vector2i.ZERO] = chunk
	var attached: Dictionary = PacketOwner.attach_to_chunk(chunk)
	main_node.section_owner = chunk
	main_node.section_backend = attached.get("backend") as Node3D
	var install_status := "not_started"
	var install_reason := String(attached.get("reason", ""))
	var descriptor_reason := "not_checked"
	var install_pov_revision := int(_test_pov_snapshot().get("revision", -1))
	for batch_value: Variant in snapshot.get("batches", {}).values():
		if batch_value is Dictionary and String((batch_value as Dictionary).get(
				"renderLayer", "")) == "translucent":
			var descriptor: Dictionary = (batch_value as Dictionary).get(
				"translucentSortDescriptor", {})
			install_pov_revision = int(descriptor.get("povRevision", install_pov_revision))
	if built.get("status") == "ready" and candidate_result.get("status") == "ready" \
			and attached.get("status") == "ready":
		var session := InstallSession.new()
		for batch_value: Variant in snapshot.get("batches", {}).values():
			if batch_value is Dictionary and String((batch_value as Dictionary).get("renderLayer", "")) == "translucent":
				var batch: Dictionary = batch_value
				var descriptor_check: Dictionary = session._validate_translucent_sort_descriptor(
					batch, candidate_result.get("candidate", {}).get("meshBindings", {}).get(
						String(batch.get("meshKey", ""))), SECTION, 73)
				descriptor_reason = String(descriptor_check.get("reason", "ready"))
		var begun: Dictionary = session.begin(attached.backend, chunk, envelope,
			candidate_result.get("candidate", {}).get("materialBindings", {}),
			candidate_result.get("candidate", {}).get("meshBindings", {}))
		install_status = String(begun.get("status", "failed"))
		install_reason = String(begun.get("reason", ""))
		if begun.get("status") == "begun":
			for _step in range(32):
				var advanced: Dictionary = session.advance(8, install_pov_revision)
				install_status = String(advanced.get("status", "failed"))
				install_reason = String(advanced.get("reason", ""))
				if install_status != "pending":
					break
	_check("real_native_fluid_candidate_reaches_layer_manifest_and_install_receipt",
		built.get("status") == "ready" and contribution.is_read_only()
		and contribution.get("inputs", []).size() == 2
		and candidate_result.get("status") == "ready"
		and _render_layer_expected_batches(snapshot, "translucent") == 1
		and translucent_batches == 1 and install_status == "installed",
		{"buildStatus":built.get("status", ""), "buildReason":built.get("reason", ""),
		"assemblerStatus":candidate_result.get("status", ""),
		"assemblerReason":candidate_result.get("reason", ""),
		"translucentBatchCount":translucent_batches,
		"descriptorValidation":descriptor_reason,
		"installStatus":install_status, "installReason":install_reason})
	if is_instance_valid(chunk):
		chunk.queue_free()
	main_node.free()


func _render_layer_expected_batches(snapshot: Dictionary, layer_name: String) -> int:
	for row_value: Variant in snapshot.get("renderLayers", []):
		if row_value is Dictionary and String((row_value as Dictionary).get("layer", "")) == layer_name:
			return int((row_value as Dictionary).get("expectedBatchCount", 0))
	return -1


func _one_water_cell_payload(fluid_type_id: int = 1) -> Dictionary:
	const HALO_SIZE := SECTION_SIZE + 2
	var solid := PackedByteArray()
	var fluids := PackedByteArray()
	solid.resize(HALO_SIZE * HALO_SIZE * HALO_SIZE)
	fluids.resize(HALO_SIZE * HALO_SIZE * HALO_SIZE)
	var local := Vector3i(5, 4, 7) - Vector3i(-1, -1, -1)
	var index := local.y + HALO_SIZE * (local.x + HALO_SIZE * local.z)
	fluids[index] = fluid_type_id
	var cells := {"size":Vector3i.ONE * HALO_SIZE, "solid":solid,
		"fluidTypeIds":fluids}
	cells.make_read_only()
	var revision_row := {"sectionKey":SECTION, "revision":7}
	revision_row.make_read_only()
	var revisions: Array[Dictionary] = [revision_row]
	revisions.make_read_only()
	var fluid_schema := {"none":0, "water":1, "lava":2}
	fluid_schema.make_read_only()
	var payload := {"schemaVersion":1, "immutable":true,
		"sectionSize":SECTION_SIZE, "cellSize":1.35, "terrainStepCells":1,
		"fluidStepCells":1, "stepCells":1, "chunkSize":SECTION_SIZE,
		"startX":0, "startZ":0, "minY":0, "maxY":SECTION_SIZE - 1,
		"minCell":Vector3i(-1, -1, -1), "maxCell":Vector3i(SECTION_SIZE, SECTION_SIZE, SECTION_SIZE),
		"boundsInclusive":true, "revision":7, "fluidRevision":9,
		"sectionRevisions":revisions, "signature":"fluid-r1",
		"hasFluid":true, "fluidCellCount":1, "fluidTypeSchema":fluid_schema,
		"cells":cells, "sections":[]}
	payload.make_read_only()
	return payload


func _test_pov_snapshot() -> Dictionary:
	return {"status":"ready", "sectionKey":SECTION,
		"cameraPosition":Vector3(7.0, 6.0, 8.0),
		"povClass":Vector3i.ZERO, "revision":14}


func _runtime(has_fluid: bool) -> FakeRuntime:
	var fake := FakeRuntime.new()
	fake.terrain = FakeTerrain.new()
	var mesher := FakeMesher.new()
	mesher.mesh = _mesh
	fake.terrain.mesher = mesher
	fake.terrain.material_override = _material
	var fluid := {"sectionKey":SECTION, "hasFluid":has_fluid,
		"volumeRevision":7, "fluidRevision":9, "signature":"fluid-r1"}
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


func _current_fluid_proof() -> Dictionary:
	var proof := {"sectionKey":SECTION, "hasFluid":true,
		"volumeRevision":7, "fluidRevision":9, "signature":"fluid-r1"}
	proof.make_read_only()
	return proof

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
	_production_material_owner = ProductionMain.new()
	_production_material_owner.setup_materials()
	_production_materials = _production_material_owner.materials.duplicate()
	var water_material := _production_materials.get("water") as ShaderMaterial
	var water_shader_code := water_material.shader.code if water_material != null else ""
	var lava_material := _production_materials.get("lava") as BaseMaterial3D
	_check("production_fluid_materials_express_their_translucent_intent",
		water_material != null and water_shader_code.contains("blend_mix")
		and lava_material != null
		and lava_material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA
		and is_equal_approx(lava_material.albedo_color.a, 0.92),
		{"waterMaterial":water_material.get_class() if water_material != null else "missing",
		"waterBlendModePresent":water_shader_code.contains("blend_mix"),
		"lavaMaterial":lava_material.get_class() if lava_material != null else "missing",
		"lavaTransparency":lava_material.transparency if lava_material != null else -1,
		"lavaAlpha":lava_material.albedo_color.a if lava_material != null else -1.0})
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
	if is_instance_valid(_production_material_owner):
		_production_material_owner.free()
	quit(0 if passed else 1)

static func _readonly_array(values: Array) -> Array:
	var copy := values.duplicate()
	copy.make_read_only()
	return copy
