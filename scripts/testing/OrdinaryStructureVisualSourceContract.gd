extends SceneTree

const StructureScript := preload("res://scripts/StructureSystem.gd")

class FixtureWorld extends Node:
	var seed_text := "ordinary-visual-contract"
	var TOWN_REGION_CELLS := 64
	var STRUCTURE_REGION_CELLS := 64
	var STRUCTURE_SPAWN_CHANCE := 0.0
	var TOWN_RADIUS_CELLS := 12
	var blocks: Dictionary = {}
	var town_region_cache: Dictionary = {}
	var include_town := true

	func town_region(x: int, z: int) -> Dictionary:
		if include_town and x == 0 and z == 0:
			return {"regionX": 0, "regionZ": 0, "centerX": 0, "centerZ": 0,
				"radius": 12, "level": 0.0}
		return {}

var checks: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var world := FixtureWorld.new()
	root.add_child(world)
	for z in range(-2, 2):
		for x in range(-2, 2):
			world.town_region_cache[Vector2i(x, z)] = world.town_region(x, z)
	var source = StructureScript.new()
	source.main = world
	source.town_manifest_publish_states["0,0"] = {"status": "published", "generationAttempts": 1}
	var bounds := Rect2i(Vector2i(-2, -2), Vector2i(5, 5))
	var source_id := "town:0,0"
	var cell := Vector3i.ZERO
	var body := StaticBody3D.new()
	body.set_meta("cell", cell)
	body.set_meta("block_type", "stoneBlock")
	body.set_meta("generated", true)
	body.set_meta("generated_visual_source_id", source_id)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	body.add_child(mesh)
	world.add_child(body)
	world.blocks[cell] = body
	source._begin_ordinary_visual_source(source_id)
	source.active_structure_visual_source_id = source_id
	source._record_ordinary_visual_block(cell, "stoneBlock", body)
	source.active_structure_visual_source_id = ""
	var pending: Dictionary = source.region_ordinary_visual_source(bounds)
	check("emitted_live_block_waits_for_producer_completion",
		pending.status == "pending" and pending.pendingSourceIds.has(source_id), pending)
	source._complete_ordinary_visual_source(source_id)
	var complete: Dictionary = source.region_ordinary_visual_source(bounds)
	check("completed_emission_has_exact_installed_candidate",
		complete.status == "described" and complete.candidateCount == 1
		and complete.candidates[0].owner == body and complete.candidates[0].installed, complete)
	var repeated: Dictionary = source.region_ordinary_visual_source(bounds)
	check("unchanged_source_revision_is_stable",
		complete.sourceRevision == repeated.sourceRevision, repeated)
	var capture := source.begin_region_ordinary_visual_source_capture(bounds)
	var captured: Dictionary = {}
	var budget_slices := 0
	for step in 256:
		captured = capture.advance(1, 3000)
		if captured.get("reason") == "ordinary_visual_capture_budget":
			budget_slices += 1
		if captured.get("status") != "pending" \
				or captured.get("reason") != "ordinary_visual_capture_budget":
			break
	check("bounded_producer_matches_synchronous_source",
		captured.get("status") == "described" and budget_slices > 0
		and captured.get("sourceRevision") == complete.sourceRevision
		and int(captured.get("candidateCount", -1)) == 1
		and captured.candidates[0].candidateId == complete.candidates[0].candidateId
		and (captured.candidates[0].owner as WeakRef).get_ref() == body
		and (captured.candidates[0].representation as WeakRef).get_ref() == mesh, captured)
	var changed_capture := source.begin_region_ordinary_visual_source_capture(bounds)
	changed_capture.advance(1, 3000)
	source.ordinary_visual_revision += 1
	var changed: Dictionary = changed_capture.advance(1, 3000)
	check("bounded_producer_restarts_after_source_revision_change",
		changed.get("status") == "pending"
		and changed.get("reason") == "ordinary_visual_capture_source_changed", changed)
	source.ordinary_visual_revision -= 1
	var owner_capture := source.begin_region_ordinary_visual_source_capture(bounds)
	var validating := false
	for step in 256:
		var slice: Dictionary = owner_capture.advance(1, 3000)
		if slice.get("stage") == "validate":
			validating = true
			break
		if slice.get("reason") != "ordinary_visual_capture_budget": break
	var replacement := StaticBody3D.new()
	replacement.set_meta("generated_visual_source_id", source_id)
	replacement.set_meta("block_type", "stoneBlock")
	var replacement_mesh := MeshInstance3D.new()
	replacement_mesh.mesh = BoxMesh.new()
	replacement.add_child(replacement_mesh)
	world.add_child(replacement)
	world.blocks[cell] = replacement
	var stale_owner: Dictionary = owner_capture.advance(1, 3000)
	check("bounded_producer_rejects_replaced_live_block",
		validating and stale_owner.get("status") == "pending"
		and stale_owner.get("reason") == "ordinary_visual_capture_owner_changed", stale_owner)
	world.blocks[cell] = body
	replacement.queue_free()
	world.blocks.erase(cell)
	var missing: Dictionary = source.region_ordinary_visual_source(bounds)
	check("missing_emitted_owner_cannot_become_empty",
		missing.status == "described" and missing.candidateCount == 1
		and missing.candidates[0].owner == null and not missing.candidates[0].installed, missing)
	source.generated_visual_block_removed(body)
	var removed: Dictionary = source.region_ordinary_visual_source(bounds)
	check("durable_removal_retires_exact_candidate",
		removed.status == "described" and removed.candidateCount == 0
		and removed.sourceRevision != complete.sourceRevision, removed)
	var saved: Array = source.snapshot_removed_generated_structure_blocks()
	var restored = StructureScript.new()
	restored.restore_removed_generated_structure_blocks(saved)
	check("generated_removal_round_trips_additively",
		saved.size() == 1 and restored.generated_visual_block_is_removed(source_id, cell, "stoneBlock"),
		{"saved": saved})
	restored.main = world
	restored.town_manifest_publish_states["0,0"] = {"status": "published", "generationAttempts": 1}
	restored._begin_ordinary_visual_source(source_id)
	restored.active_structure_visual_source_id = source_id
	restored._record_ordinary_visual_block(cell, "stoneBlock", null)
	restored.active_structure_visual_source_id = ""
	restored._complete_ordinary_visual_source(source_id)
	var restored_omission: Dictionary = restored.region_ordinary_visual_source(bounds)
	check("saved_edit_is_authoritative_output_omission",
		restored_omission.status == "described" and restored_omission.candidateCount == 0,
		restored_omission)
	var unexpected = StructureScript.new()
	unexpected.main = world
	unexpected.town_manifest_publish_states["0,0"] = {"status": "published", "generationAttempts": 1}
	unexpected._begin_ordinary_visual_source(source_id)
	unexpected.active_structure_visual_source_id = source_id
	unexpected._record_ordinary_visual_block(cell, "stoneBlock", null)
	unexpected.active_structure_visual_source_id = ""
	unexpected._complete_ordinary_visual_source(source_id)
	var rejected: Dictionary = unexpected.region_ordinary_visual_source(bounds)
	check("unexplained_missing_output_cannot_be_empty_success",
		rejected.status == "pending" and rejected.pendingSourceIds.has(source_id + ":unaccepted_block_output"),
		rejected)
	var occupied = StructureScript.new()
	occupied.main = world
	occupied.town_manifest_publish_states["0,0"] = {"status": "published", "generationAttempts": 1}
	var player_block := StaticBody3D.new()
	player_block.set_meta("player_placed",true)
	world.add_child(player_block)
	occupied._begin_ordinary_visual_source(source_id)
	occupied.active_structure_visual_source_id = source_id
	occupied._record_ordinary_visual_block(cell, "stoneBlock", player_block)
	occupied.active_structure_visual_source_id = ""
	occupied._complete_ordinary_visual_source(source_id)
	var occupied_result: Dictionary = occupied.region_ordinary_visual_source(bounds)
	check("existing_player_output_is_explicit_omission",
		occupied_result.status == "described" and occupied_result.candidateCount == 0,
		occupied_result)
	world.include_town = false
	for key in world.town_region_cache:
		world.town_region_cache[key] = {}
	var absent: Dictionary = source.region_ordinary_visual_source(bounds)
	check("deterministic_absence_is_authoritative_empty",
		absent.status == "described" and absent.sourceCount == 0 and absent.candidateCount == 0, absent)
	var passed := true
	for result in checks:
		if not bool(result.passed): passed = false
	var report := {"schema": "ordinary-structure-visual-source-contract/v1",
		"evidenceLevel": "synthetic_producer_receipt_contract", "complete": true,
		"passed": passed, "checkCount": checks.size(), "checks": checks}
	var report_path := OS.get_environment("VOXEL_ORDINARY_VISUAL_SOURCE_REPORT")
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	world.queue_free()
	quit(0 if passed else 1)

func check(name: String, passed: bool, details: Dictionary) -> void:
	checks.append({"name": name, "passed": passed,
		"details": {"status": details.get("status", ""),
			"reason": details.get("reason", ""),
			"candidateCount": details.get("candidateCount", -1),
			"pendingSourceIds": details.get("pendingSourceIds", []),
			"sourceRevision": details.get("sourceRevision", "")}})
