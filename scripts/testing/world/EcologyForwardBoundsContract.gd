extends SceneTree
## Focused producer geometry contract; proves AABB placement against transformed raw corners.

const MainPlaytestToolsScript := preload("res://scripts/MainPlaytestTools.gd")
const MainInteractionFlowScript := preload("res://scripts/MainInteractionFlow.gd")
const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const DetailSourceBuilder := preload("res://scripts/world/EcologyDetailSourceValueBuilder.gd")
const SectionGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SourceLedger := preload("res://scripts/world/EcologySourceValueLedger.gd")


class InvalidationRecorder:
	extends Node
	var received_bounds := AABB()
	var received := false

	func invalidate_visible_static_source(_provider: String, _source_id: String,
			_revision: String, bounds: AABB) -> void:
		received_bounds = bounds
		received = true

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.7, 0.8, 1.1)
	var raw_bounds: AABB = mesh.get_aabb()
	var material := StandardMaterial3D.new()
	var main_tools: Node = MainPlaytestToolsScript.new()
	var interaction_flow: Node = MainInteractionFlowScript.new()
	interaction_flow.set("materials", {"testMaterial":material})

	var local_transform := Transform3D(
		Basis.from_euler(Vector3(0.31, -0.57, 0.19)).scaled(Vector3(1.8, 0.65, 1.25)),
		Vector3(0.7, -0.2, 0.55))
	var captured_member: Dictionary = main_tools.call("ecology_render_member",
		"contract-member", mesh, local_transform, "testMaterial", "opaque", material)
	_check("realized_member_carries_raw_mesh_and_forward_member_bounds",
		captured_member.get("meshBounds") == raw_bounds
		and _boxes_close(captured_member.get("localBounds", AABB()),
			_bounds_from_transformed_corners(raw_bounds, local_transform)))

	var recipe := {"identity":"box", "version":1, "primitive":"box",
		"parameters":{"size":mesh.size}}
	var recipe_member: Dictionary = interaction_flow.call("_source_render_member",
		"recipe-member", "", recipe, local_transform, "testMaterial", [], "opaque")
	_check("recipe_member_matches_independent_raw_corner_transform",
		recipe_member.get("meshBounds") == raw_bounds
		and _boxes_close(recipe_member.get("localBounds", AABB()),
			_bounds_from_transformed_corners(raw_bounds, local_transform)))

	var detail_transform := Transform3D(
		Basis.from_euler(Vector3(-0.24, 0.48, 0.37)).scaled(Vector3(0.72, 1.9, 1.3)),
		Vector3(21.4, 0.15, 21.25))
	var detail_inputs := {"worldId":"bounds-world", "worldSeed":"bounds-seed",
		"sourceChunkKey":"-16,-16", "chunkX":-16, "chunkZ":-16,
		"chunkOrigin":Vector3(-21.6, 0.0, -21.6),
		"revisions":{"terrain":"terrain-r1", "structure":"structure-r1",
			"details":"details-r1"},
		"generationStatus":"complete", "batchesComplete":true}
	var resolvers := {
		"mesh":func(_detail_type: String) -> Mesh: return mesh,
		"meshSurface":func(_detail_type: String, _surface_index: int) -> Mesh: return mesh,
		"materialKey":func(_detail_type: String, _surface_index: int) -> String:
			return "testMaterial",
		"material":func(_detail_type: String, _surface_index: int) -> Material:
			return material,
		"renderLayer":func(_mat: Material, _detail_type: String, _surface_index: int) -> String:
			return "opaque",
		"meshContentDigest":func(_mesh: Mesh) -> String: return "a".repeat(64),
		"materialContentDigest":func(_mat: Material) -> String: return "b".repeat(64),
		"instanceColor":func(_detail_type: String, _transform: Transform3D, _index: int) -> Color:
			return Color.WHITE,
		"instancePhase":func(_detail_type: String, _transform: Transform3D, _index: int) -> float:
			return 0.25,
		"visibilityRangeEnd":func(_detail_type: String) -> float: return 48.0
	}
	var detail_result: Dictionary = DetailSourceBuilder.build_rows(detail_inputs,
		{"grass":[detail_transform]}, resolvers)
	var detail_rows: Array = detail_result.get("rows", [])
	var detail_row: Dictionary = detail_rows[0] if not detail_rows.is_empty() else {}
	var detail_expected := _bounds_from_transformed_corners(raw_bounds,
		detail_transform)
	_check("detail_source_row_carries_raw_and_forward_local_bounds",
		detail_result.get("status", "") == "ready" and detail_rows.size() == 1
		and detail_row.get("meshBounds") == raw_bounds
		and _boxes_close(detail_row.get("localBounds", AABB()), detail_expected))

	var chunk_translation := Transform3D(Basis.IDENTITY, detail_inputs.chunkOrigin)
	var detail_world_expected := _bounds_from_transformed_corners(raw_bounds,
		chunk_translation * detail_transform)
	var proof_policy := {"status":"ready", "revision":"bounds-policy-r1",
		"digest":"c".repeat(64), "families":{"details":{"status":"bounded",
			"maxHorizontalSupportMeters":100.0, "maxVerticalSupportMeters":100.0},
			"forage":{"status":"bounded", "maxHorizontalSupportMeters":100.0,
				"maxVerticalSupportMeters":100.0}}}
	var detail_source_row := detail_row.duplicate(true)
	detail_source_row["sourceOrigin"] = detail_inputs.chunkOrigin + detail_transform.origin
	var proof_state := {"startX":-16, "startZ":-16, "supportPolicy":proof_policy,
		"influencePolicyRevision":"bounds-policy-r1",
		"influencePolicyDigest":"c".repeat(64)}
	main_tools.call("_prove_ecology_source_row_bounds", proof_state,
		detail_source_row, "details")
	var detail_proof: Dictionary = detail_source_row.get("supportProof", {})
	_check("detail_support_proof_uses_composed_chunk_transform_once",
		detail_proof.get("status", "") == "ready"
		and _boxes_close(detail_proof.get("worldBounds", AABB()), detail_world_expected))
	var intersected_sections := SectionGrid.keys_intersecting_bounds(detail_world_expected)
	_check("negative_chunk_detail_bounds_cross_section_boundary",
		detail_world_expected.position.x < 0.0 and detail_world_expected.end.x > 0.0
		and detail_world_expected.position.z < 0.0 and detail_world_expected.end.z > 0.0
		and intersected_sections.size() > 1)

	var body_position := Vector3(21.4, 0.35, 21.25)
	var body_rotation := Vector3(0.0, 0.43, 0.0)
	var member_transform := Transform3D(
		Basis.from_euler(Vector3(0.21, -0.16, 0.35)).scaled(Vector3(0.8, 1.4, 0.95)),
		Vector3(0.45, 0.2, 0.32))
	var body_to_chunk := Transform3D(Basis.from_euler(body_rotation), body_position)
	var static_world_expected := _bounds_from_transformed_corners(raw_bounds,
		chunk_translation * body_to_chunk * member_transform)
	var static_row := {"position":body_position, "bodyRotation":body_rotation,
		"sourceOrigin":detail_inputs.chunkOrigin + body_position,
		"renderMembers":[{"meshBounds":raw_bounds,
			"localBounds":_bounds_from_transformed_corners(raw_bounds, member_transform),
			"transform":member_transform}]}
	main_tools.call("_prove_ecology_source_row_bounds", proof_state, static_row, "forage")
	var static_proof: Dictionary = static_row.get("supportProof", {})
	_check("static_member_support_proof_composes_raw_mesh_body_and_chunk_once",
		static_proof.get("status", "") == "ready"
		and _boxes_close(static_proof.get("worldBounds", AABB()), static_world_expected))

	var structure_system: RefCounted = StructureSystemScript.new()
	var ordinary_parent := Node3D.new()
	ordinary_parent.transform = Transform3D(
		Basis.from_euler(Vector3(-0.13, 0.24, 0.09)).scaled(Vector3(0.95, 1.1, 1.3)),
		Vector3(-1.2, 0.6, 2.4))
	var ordinary_body := StaticBody3D.new()
	var ordinary_mesh := MeshInstance3D.new()
	ordinary_mesh.mesh = mesh
	ordinary_mesh.transform = Transform3D(
		Basis.from_euler(Vector3(0.28, -0.41, 0.17)).scaled(Vector3(1.1, 1.6, 0.7)),
		Vector3(-0.3, 0.4, 0.8))
	ordinary_body.transform = Transform3D(Basis.from_euler(Vector3(0.18, 0.36, -0.12)),
		Vector3(0.5, -0.1, -0.7))
	ordinary_body.add_child(ordinary_mesh)
	ordinary_parent.add_child(ordinary_body)
	root.add_child(ordinary_parent)
	await process_frame
	var ordinary_expected := _bounds_from_transformed_corners(raw_bounds,
		ordinary_mesh.global_transform)
	var ordinary_actual: AABB = structure_system.call(
		"_ordinary_visual_block_world_bounds", ordinary_body)
	_check("ordinary_structure_invalidation_uses_forward_global_bounds",
		_boxes_close(ordinary_actual, ordinary_expected))
	ordinary_parent.queue_free()
	structure_system = null
	await process_frame

	var realized_parent := Node3D.new()
	realized_parent.transform = Transform3D(
		Basis.from_euler(Vector3(0.07, -0.22, 0.11)).scaled(Vector3(1.0, 0.9, 1.2)),
		Vector3(1.1, 0.4, -0.8))
	main_tools.set("seed_text", "bounds-seed")
	main_tools.set("removed_props", {})
	var source_ledger: Object = SourceLedger.new()
	var context_chunk := Vector2i(-2, -3)
	var source_revision := String(main_tools.call(
		"_ecology_chunk_source_revision", context_chunk))
	source_ledger.configure("bounds-seed", context_chunk, source_revision, 0, 7)
	realized_parent.set_meta("static_ecology_source_value_ledger", source_ledger)
	realized_parent.set_meta("ecology_capture_context", {
		"producer":"surface_spawn", "category":"forage",
		"chunkX":context_chunk.x, "chunkZ":context_chunk.y,
		"terrainRevision":7, "attemptIndex":3, "sourceCell":Vector3i(-4, 2, -7),
		"scanRevision":""})
	var recorder := InvalidationRecorder.new()
	root.add_child(realized_parent)
	root.add_child(recorder)
	main_tools.set("world_static_section_coordinator", recorder)
	var realized_body := StaticBody3D.new()
	realized_body.set_meta("prop_id", "bounds-prop")
	realized_body.transform = Transform3D(
		Basis.from_euler(Vector3(0.0, 0.62, 0.0)).scaled(Vector3(0.85, 1.25, 1.1)),
		Vector3(4.3, 1.0, 5.1))
	var realized_member_transform := Transform3D(
		Basis.from_euler(Vector3(0.16, 0.1, -0.27)).scaled(Vector3(1.2, 0.75, 1.4)),
		Vector3(0.55, 0.28, -0.35))
	var realized_member: Dictionary = main_tools.call("ecology_render_member",
		"realized-part", mesh, realized_member_transform,
		"testMaterial", "opaque", material)
	var realized_mesh_instance := MeshInstance3D.new()
	realized_mesh_instance.mesh = mesh
	realized_mesh_instance.transform = realized_member_transform
	realized_body.add_child(realized_mesh_instance)
	realized_parent.add_child(realized_body)
	await process_frame
	var realized_world_expected := _bounds_from_transformed_corners(raw_bounds,
		realized_mesh_instance.global_transform)
	var recorded: bool = main_tools.call("_record_realized_ecology_prop",
		realized_parent, realized_body, "forage", [realized_member])
	var realized_snapshot: Dictionary = source_ledger.snapshot(false)
	var realized_candidates: Array = realized_snapshot.get("candidates", [])
	var realized_candidate: Dictionary = realized_candidates[0] \
		if not realized_candidates.is_empty() else {}
	var realized_local_expected := _bounds_from_transformed_corners(raw_bounds,
		realized_member_transform)
	_check("realized_prop_keeps_body_local_member_union_and_invalidates_forward_world_bounds",
		recorded and realized_candidates.size() == 1 and recorder.received
		and _boxes_close(realized_candidate.get("localBounds", AABB()), realized_local_expected)
		and _boxes_close(realized_body.get_meta("static_ecology_source_bounds", AABB()),
			realized_world_expected)
		and _boxes_close(recorder.received_bounds, realized_world_expected))
	realized_parent.queue_free()
	recorder.queue_free()
	await process_frame

	main_tools.free()
	interaction_flow.free()
	_finish()


func _bounds_from_transformed_corners(bounds: AABB, transform: Transform3D) -> AABB:
	var first := transform * bounds.position
	var minimum := first
	var maximum := first
	for x: float in [bounds.position.x, bounds.end.x]:
		for y: float in [bounds.position.y, bounds.end.y]:
			for z: float in [bounds.position.z, bounds.end.z]:
				var point := transform * Vector3(x, y, z)
				minimum = minimum.min(point)
				maximum = maximum.max(point)
	return AABB(minimum, maximum - minimum)


func _boxes_close(left_value: Variant, right_value: AABB) -> bool:
	return left_value is AABB \
		and (left_value as AABB).position.distance_to(right_value.position) < 0.00001 \
		and (left_value as AABB).size.distance_to(right_value.size) < 0.00001


func _check(name: String, passed: bool) -> void:
	checks[name] = passed
	if not passed:
		push_error("Ecology forward bounds contract failed: %s" % name)


func _finish() -> void:
	var passed_count := 0
	var failed: Array[String] = []
	for name_value: Variant in checks:
		if bool(checks[name_value]):
			passed_count += 1
		else:
			failed.append(String(name_value))
	var report := {"schema":"ecology-forward-bounds-contract/v1",
		"evidenceLevel":"production_source_geometry_contract",
		"passed":not checks.is_empty() and passed_count == checks.size(),
		"checkCount":checks.size(), "passedCount":passed_count,
		"failedChecks":failed, "checks":checks}
	var report_path := OS.get_environment("ECOLOGY_FORWARD_BOUNDS_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if report.passed else 1)
