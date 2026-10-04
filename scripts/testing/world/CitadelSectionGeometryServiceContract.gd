extends SceneTree
## Synthetic service bridge contract. It exercises the public producer-to-section
## snapshot handoff with retained packet-shaped values, not a native install.

const Service := preload("res://scripts/world/CitadelPublicationService.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

class PacketPublisher extends RefCounted:
	var publication_site_id := "site-a"
	var member_binding := "record-binding-1"
	var receipt_live := true
	var packet_source_id := "building:site-a:part-1:0,0:material-tier-digest:source"
	var packet_material: StandardMaterial3D
	var packet_mesh: BoxMesh
	var segment_record: Dictionary
	var recipe: Dictionary
	var published_nodes: Array = []
	var _physical_packet_bindings_by_part_id := {"part-1":"record-binding-1"}
	var _chunk_static_packet_expected := {}
	var _chunk_static_packet_pending_expected: Dictionary = {}
	var _chunk_static_packet_recipes := {}

	func _init() -> void:
		packet_material = StandardMaterial3D.new()
		packet_material.albedo_color = Color(0.4, 0.3, 0.2, 1.0)
		packet_mesh = BoxMesh.new()
		var buffer: Array[float] = []
		buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)),
			Color.WHITE, Color.WHITE))
		buffer.make_read_only()
		segment_record = {"segmentId":"segment-0", "buffer":buffer,
			"bounds":AABB(Vector3(1.5, 1.5, 1.5), Vector3.ONE), "instanceCount":1}
		segment_record.make_read_only()
		var segments := {0:segment_record}
		segments.make_read_only()
		recipe = {"sourceId":packet_source_id, "sourcePartId":"part-1",
			"sourceRevision":member_binding, "ownerCell":Vector2i.ZERO,
			"renderChunkKey":Vector2i.ZERO, "materialKey":"stone",
			"material":packet_material, "mesh":packet_mesh,
			"renderTier":"structural", "preparedSegments":segments,
			"packetInstanceCount":1}
		recipe.make_read_only()
		_chunk_static_packet_expected = {"part-1":{packet_source_id:{
			"ownerCell":Vector2i.ZERO, "generation":3,
			"sourceRevision":member_binding,
			"packetDigest":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}}}
		_chunk_static_packet_recipes = {packet_source_id:recipe}

	func has_pending_static_flush() -> bool:
		return false

	func chunk_static_packet_receipt_live(part_id: String, source_id: String) -> bool:
		return receipt_live and part_id == "part-1" and source_id == packet_source_id


class FixtureService extends "res://scripts/world/CitadelPublicationService.gd":
	var census_fixture: Dictionary
	var owner_fixture: Dictionary

	func capture_static_section_sources(_world_id: String, _section_keys: Array) -> Dictionary:
		return census_fixture

	func _current_packet_publisher_for_site(_site_id: String) -> Dictionary:
		return owner_fixture


var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var section := Vector3i.ZERO
	var world_id := "seed:citadel-service-contract:1"
	var source_id := "citadel:site-a:member:building:part-1:section:0,0,0"
	var source_revision := "citadel-census-revision"
	var census := {"status":"complete", "worldId":world_id,
		"authorityRevision":"authority-revision",
		"sourceRevisions":{source_id:source_revision},
		"sections":{section:{"status":"complete", "coverageRevision":"coverage-revision",
			"sourcePartIds":[source_id]}}}
	var publisher := PacketPublisher.new()
	var service := FixtureService.new()
	service.census_fixture = census
	service.owner_fixture = {"status":"ready", "publisher":publisher,
		"sourceToWorld":Transform3D(Basis.IDENTITY, Vector3(10, 0, 10))}
	var candidate: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 11)
	check("live_service_bridge_emits_shared_candidate_snapshot_from_packet_recipe",
		candidate.get("status") == "ready"
		and candidate.get("schema") == "citadel-section-geometry-candidate/v1"
		and candidate.get("packetGroupCount") == 1
		and candidate.get("replacements", []).size() == 1
		and candidate.get("replacements", [])[0].get("snapshot", {}).get("instanceCount") == 1
		and candidate.get("resourceBindings", {}).size() == 1,
		candidate)
	check("candidate_explicitly_retains_legacy_render_and_gameplay_owners",
		candidate.get("legacyVisualPolicy") == "retain_until_shared_coordinator_native_receipt_acknowledged"
		and String(candidate.get("evidenceScope", "")).contains("no native install"), candidate)
	var roster_census := {"status":"complete", "worldId":world_id,
		"providerSnapshotRevisions":{"blueprint_buildings":"authority-revision"},
		"providerCoverageRevisions":{"blueprint_buildings":{section:"coverage-revision"}},
		"sourceRevisions":{source_id:source_revision}}
	var contribution_result: Dictionary = service.capture_static_section_contribution(
		roster_census, section)
	var contribution: Dictionary = contribution_result.get("contribution", {})
	check("citadel_packet_geometry_enters_common_immutable_provider_contribution",
		contribution_result.get("status") == "ready" and contribution.is_read_only()
		and contribution.get("providerId") == "blueprint_buildings"
		and contribution.get("authoritySourceRevisions", {}).get(source_id, "") == source_revision
		and contribution.get("inputs", []).size() == 1
		and contribution.get("resourceBindings", {}).size() == 1,
		{"capture":contribution_result, "inputCount":contribution.get("inputs", []).size()})
	var legacy_visual := MeshInstance3D.new()
	legacy_visual.mesh = BoxMesh.new()
	get_root().add_child(legacy_visual)
	publisher.published_nodes = [legacy_visual]
	var unidentified_legacy: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 15)
	check("unidentified_legacy_visual_membership_stays_pending",
		unidentified_legacy.get("status") == "pending"
		and unidentified_legacy.get("reason") == "citadel_legacy_visual_member_identity_unavailable",
		unidentified_legacy)
	legacy_visual.set_meta("building_source_part_id", "part-1")
	var same_member_legacy: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 16)
	check("same_member_legacy_visual_stays_pending_until_native_acknowledgement",
		same_member_legacy.get("status") == "pending"
		and same_member_legacy.get("reason") == "citadel_member_has_unmigrated_legacy_visual",
		same_member_legacy)
	legacy_visual.free()
	publisher.published_nodes.clear()
	publisher.receipt_live = false
	var stale_receipt: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 12)
	check("stale_legacy_packet_receipt_stays_pending",
		stale_receipt.get("status") == "pending"
		and stale_receipt.get("reason") == "citadel_packet_group_revision_or_receipt_stale",
		stale_receipt)
	var tree_source_id := "citadel:site-a:member:tree:oak-1:section:0,0,0"
	service.census_fixture = {"status":"complete", "worldId":world_id,
		"authorityRevision":"authority-revision",
		"sourceRevisions":{tree_source_id:"tree-revision"},
		"sections":{section:{"status":"complete", "coverageRevision":"tree-coverage",
			"sourcePartIds":[tree_source_id]}}}
	var tree_candidate: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 13)
	check("tree_member_without_static_packet_adapter_stays_pending",
		tree_candidate.get("status") == "pending"
		and tree_candidate.get("reason") == "citadel_member_kind_has_no_prepared_static_packet",
		tree_candidate)
	service.census_fixture = {"status":"complete", "worldId":world_id,
		"authorityRevision":"authority-revision",
		"sourceRevisions":{},
		"sections":{section:{"status":"empty", "coverageRevision":"empty-coverage",
			"sourcePartIds":[]}}}
	var empty_candidate: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 14)
	check("explicit_empty_census_builds_zero_content_shared_snapshot",
		empty_candidate.get("status") == "ready"
		and empty_candidate.get("replacements", []).size() == 1
		and empty_candidate.get("replacements", [])[0].get("snapshot", {}).get("instanceCount") == 0,
		empty_candidate)
	var report := {"schema":"citadel-section-geometry-service-contract/v1",
		"complete":checks.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false))),
		"passed":checks.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false))),
		"checkCount":checks.size(),
		"evidenceLevel":"synthetic_service_to_prepared_packet_section_snapshot_contract",
		"checks":checks}
	var report_path := OS.get_environment("VOXEL_CITADEL_SECTION_SERVICE_REPORT")
	if report_path.is_empty():
		push_error("VOXEL_CITADEL_SECTION_SERVICE_REPORT is required")
		quit(2)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write Citadel section service report: " + report_path)
		quit(2)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if report.passed else 1)


func check(name: String, passed: bool, evidence: Dictionary) -> void:
	checks.append({"name":name, "passed":passed, "evidence":evidence})
	if not passed:
		push_error("Citadel section service contract failed: " + name + " " + str(evidence))
