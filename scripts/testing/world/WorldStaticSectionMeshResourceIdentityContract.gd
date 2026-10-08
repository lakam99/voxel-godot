extends SceneTree

const Assembler := preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const MaterialFingerprint := preload("res://scripts/world/StaticRenderMaterialFingerprint.gd")
const REPORT_ENV := "VOXEL_SECTION_MESH_RESOURCE_IDENTITY_REPORT"

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var first_mesh := BoxMesh.new()
	var equivalent_mesh := BoxMesh.new()
	var same_fingerprint := MeshFingerprint.inspect(first_mesh)
	var equivalent_fingerprint := MeshFingerprint.inspect(equivalent_mesh)
	var same_resource_key := "building-mesh:" + String(same_fingerprint.get("contentDigest", ""))
	var canonical_meshes: Dictionary = {}
	var canonical_digests: Dictionary = {}
	var canonical_materials: Dictionary = {}
	var canonical_material_digests: Dictionary = {}
	var canonical_compatibility: Dictionary = {}
	var first_result := _merge_one("provider-a", "batch-a", same_resource_key,
		String(same_fingerprint.get("contentDigest", "")), first_mesh,
		canonical_compatibility, canonical_materials, canonical_material_digests,
		canonical_meshes, canonical_digests)
	var duplicate_result := _merge_one("provider-b", "batch-b", same_resource_key,
		String(equivalent_fingerprint.get("contentDigest", "")), equivalent_mesh,
		canonical_compatibility, canonical_materials, canonical_material_digests,
		canonical_meshes, canonical_digests)
	_check("distinct_mesh_resources_with_same_verified_content_share_canonical_binding",
		first_mesh != equivalent_mesh
		and same_fingerprint.get("status") == "ready"
		and same_fingerprint.get("contentDigest") == equivalent_fingerprint.get("contentDigest")
		and first_result.get("status") == "ready"
		and duplicate_result.get("status") == "ready"
		and canonical_meshes.get(same_resource_key) == first_mesh
		and canonical_digests.get(same_resource_key) == same_fingerprint.get("contentDigest"),
		{"first":first_result, "duplicate":duplicate_result,
			"sameContentDigest":same_fingerprint.get("contentDigest", ""),
			"distinctObjectIds":[first_mesh.get_instance_id(), equivalent_mesh.get_instance_id()],
			"canonicalResourceId":canonical_meshes.get(same_resource_key).get_instance_id()
				if canonical_meshes.get(same_resource_key) is Mesh else 0})

	var different_mesh := BoxMesh.new()
	different_mesh.size = Vector3(2.0, 2.0, 2.0)
	var different_fingerprint := MeshFingerprint.inspect(different_mesh)
	var conflicting_result := _merge_one("provider-c", "batch-c", same_resource_key,
		String(different_fingerprint.get("contentDigest", "")), different_mesh,
		canonical_compatibility, canonical_materials, canonical_material_digests,
		canonical_meshes, canonical_digests)
	_check("different_verified_content_cannot_reuse_existing_resource_key",
		different_fingerprint.get("status") == "ready"
		and different_fingerprint.get("contentDigest") != same_fingerprint.get("contentDigest")
		and conflicting_result.get("status") == "failed"
		and conflicting_result.get("reason") == "cross_domain_mesh_binding_conflict:" + same_resource_key
		and canonical_meshes.get(same_resource_key) == first_mesh,
		{"result":conflicting_result,
			"existingDigest":canonical_digests.get(same_resource_key, ""),
			"incomingDigest":different_fingerprint.get("contentDigest", ""),
			"canonicalResourceId":canonical_meshes.get(same_resource_key).get_instance_id()
				if canonical_meshes.get(same_resource_key) is Mesh else 0})
	var shared_mesh := BoxMesh.new()
	var shared_mesh_fingerprint: Dictionary = MeshFingerprint.inspect(shared_mesh)
	var first_material := StandardMaterial3D.new()
	var equivalent_material := StandardMaterial3D.new()
	var material_digest := String(MaterialFingerprint.inspect(first_material).get("contentDigest", ""))
	var equivalent_material_digest := String(MaterialFingerprint.inspect(equivalent_material).get("contentDigest", ""))
	var shared_material_key := "timber_beam:0.000|" + material_digest
	var canonical_material_mesh_key := "building-mesh:" + String(shared_mesh_fingerprint.get("contentDigest", ""))
	var canonical_materials_by_key: Dictionary = {}
	var canonical_material_digests_by_key: Dictionary = {}
	var material_meshes: Dictionary = {}
	var material_mesh_digests: Dictionary = {}
	var material_compatibility: Dictionary = {}
	var first_material_result := _merge_one("material-provider-a", "material-batch-a",
		canonical_material_mesh_key, String(shared_mesh_fingerprint.get("contentDigest", "")),
		shared_mesh, material_compatibility, canonical_materials_by_key,
		canonical_material_digests_by_key, material_meshes, material_mesh_digests,
		first_material, shared_material_key)
	var duplicate_material_result := _merge_one("material-provider-b", "material-batch-b",
		canonical_material_mesh_key, String(shared_mesh_fingerprint.get("contentDigest", "")),
		shared_mesh, material_compatibility, canonical_materials_by_key,
		canonical_material_digests_by_key, material_meshes, material_mesh_digests,
		equivalent_material, shared_material_key)
	_check("distinct_material_resources_with_same_verified_content_share_canonical_binding",
		first_material != equivalent_material and material_digest == equivalent_material_digest
		and first_material_result.get("status") == "ready"
		and duplicate_material_result.get("status") == "ready"
		and canonical_materials_by_key.get(shared_material_key) == first_material
		and canonical_material_digests_by_key.get(shared_material_key) == material_digest,
		{"first":first_material_result, "duplicate":duplicate_material_result,
			"sameContentDigest":material_digest,
			"distinctObjectIds":[first_material.get_instance_id(), equivalent_material.get_instance_id()],
			"canonicalResourceId":canonical_materials_by_key.get(shared_material_key).get_instance_id()
				if canonical_materials_by_key.get(shared_material_key) is Material else 0})
	var different_material := StandardMaterial3D.new()
	different_material.albedo_color = Color(0.15, 0.73, 0.31, 1.0)
	var different_material_digest := String(MaterialFingerprint.inspect(different_material).get("contentDigest", ""))
	var semantic_material_key := "ordinary-material:" \
		+ "0000000000000000000000000000000000000000000000000000000000000000"
	var semantic_materials: Dictionary = {}
	var semantic_material_digests: Dictionary = {}
	var semantic_meshes: Dictionary = {}
	var semantic_mesh_digests: Dictionary = {}
	var semantic_compatibility: Dictionary = {}
	var semantic_first_result := _merge_one("semantic-provider-a", "semantic-batch-a",
		canonical_material_mesh_key, String(shared_mesh_fingerprint.get("contentDigest", "")),
		shared_mesh, semantic_compatibility, semantic_materials,
		semantic_material_digests, semantic_meshes, semantic_mesh_digests,
		first_material, semantic_material_key)
	var semantic_conflict_result := _merge_one("semantic-provider-b", "semantic-batch-b",
		canonical_material_mesh_key, String(shared_mesh_fingerprint.get("contentDigest", "")),
		shared_mesh, semantic_compatibility, semantic_materials,
		semantic_material_digests, semantic_meshes, semantic_mesh_digests,
		different_material, semantic_material_key)
	_check("ordinary_digest_suffix_is_opaque_but_content_conflict_is_rejected",
		semantic_first_result.get("status") == "ready"
		and semantic_conflict_result.get("status") == "failed"
		and semantic_conflict_result.get("reason") \
			== "cross_domain_material_binding_conflict:" + semantic_material_key
		and semantic_materials.get(semantic_material_key) == first_material,
		{"first":semantic_first_result, "conflict":semantic_conflict_result,
			"providerKeySuffix":semantic_material_key.get_slice(":", 1),
			"assemblerDigest":semantic_material_digests.get(semantic_material_key, ""),
			"incomingDigest":different_material_digest})

	first_mesh=null
	equivalent_mesh=null
	different_mesh=null
	first_material=null
	equivalent_material=null
	different_material=null
	shared_mesh=null
	var passed := true
	for check_name: String in checks:
		if not bool(checks[check_name].get("passed", false)):
			passed=false
	_write_report({"schema":"world-static-section-mesh-resource-identity-contract/v1",
		"passed":passed, "checkCount":checks.size(), "checks":checks,
		"evidenceLevel":"synthetic_resource_identity_contract",
		"doesNotProve":["production section assembly or native installation"]})
	quit(0 if passed else 1)


func _merge_one(provider_id: String, batch_key: String, mesh_resource_key: String,
		mesh_digest: String, mesh: Mesh, merged_compatibility: Dictionary,
		merged_materials: Dictionary, merged_material_content_digests: Dictionary,
		merged_meshes: Dictionary, merged_mesh_content_digests: Dictionary,
		material_override: Material = null, material_key_override: String = "") -> Dictionary:
	var material: Material = material_override if is_instance_valid(material_override) \
		else StandardMaterial3D.new()
	var material_fingerprint: Dictionary = MaterialFingerprint.inspect(material)
	var material_digest := String(material_fingerprint.get("contentDigest", ""))
	var material_key := material_key_override if not material_key_override.is_empty() \
		else "contract-material:" + material_digest
	var mesh_key := mesh_resource_key + "|pipeline=static|layer=opaque"
	var compatibility := {"batchKey":batch_key, "materialKey":material_key,
		"meshKey":mesh_key, "meshResourceKey":mesh_resource_key,
		"meshContentDigest":mesh_digest}
	compatibility.make_read_only()
	var provider_compatibility := {batch_key:compatibility}
	var mesh_bindings := {mesh_key:mesh}
	var material_bindings := {material_key:material}
	return Assembler.merge_provider_render_resources({"meshBindings":mesh_bindings,
		"materialBindings":material_bindings, "resourceBindings":{}},
		provider_compatibility, merged_compatibility, merged_materials,
		merged_material_content_digests, merged_meshes, merged_mesh_content_digests)


func _check(name: String, passed: bool, evidence: Dictionary) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _write_report(report: Dictionary) -> void:
	var report_path := OS.get_environment(REPORT_ENV)
	if report_path.is_empty():
		push_error("Missing report output environment variable: " + REPORT_ENV)
		return
	var parent_path := report_path.get_base_dir()
	var absolute_parent := ProjectSettings.globalize_path(parent_path)
	if DirAccess.make_dir_recursive_absolute(absolute_parent) != OK:
		push_error("Could not create report directory: " + absolute_parent)
		return
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not open report path: " + report_path)
		return
	file.store_string(JSON.stringify(report, "\t"))
