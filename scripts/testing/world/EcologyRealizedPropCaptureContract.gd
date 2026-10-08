extends SceneTree

const MainScript := preload("res://scripts/Main.gd")
const Ledger := preload("res://scripts/world/EcologySourceValueLedger.gd")
const EcologyAdapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")

var checks: Dictionary = {}

func _init() -> void:
	call_deferred("run")


func check(name: String, condition: bool) -> void:
	checks[name] = condition


func _main_with_materials(seed: String) -> Variant:
	var main := MainScript.new()
	main.seed_text = seed
	main.removed_props = {}
	main.removed_props_revision = 0
	var materials: Dictionary = {}
	for key in ["rock", "oreBase", "copperOre", "ironOre", "copperOreGlow",
			"ironOreGlow", "aloePatch", "mushroomCluster", "mushroomCap",
			"frostHerbPatch", "berryBush", "berryFruit"]:
		materials[key] = StandardMaterial3D.new()
	main.materials = materials
	return main


func _capture_parent(seed: String, category: String, prop_id: String,
		ledger: Object, revision_authority: Variant, scan_revision := "") -> Node3D:
	var parent := Node3D.new()
	root.add_child(parent)
	var chunk_revision := String(revision_authority.call(
		"_ecology_chunk_source_revision", Vector2i.ZERO))
	ledger.configure(seed, Vector2i.ZERO, chunk_revision, 0)
	parent.set_meta("static_ecology_source_value_ledger", ledger)
	parent.set_meta("ecology_capture_context", {
		"producer":"surface_spawn" if category != "underground_props" else "underground_exposed_floor_scan",
		"category":category, "chunkX":0, "chunkZ":0, "terrainRevision":-1,
		"attemptIndex":3, "sourceCell":Vector3i(4, -8, 9),
		"scanRevision":scan_revision})
	return parent


func _candidates(ledger: Object) -> Array:
	return ledger.snapshot().get("candidates", [])


func run() -> void:
	var seed := "realized-prop-contract"
	var baseline: Variant = _main_with_materials(seed)
	var captured: Variant = _main_with_materials(seed)
	var source_revision := String(captured.call(
		"_ecology_chunk_source_revision", Vector2i.ZERO))
	var shader_material := ShaderMaterial.new()
	var shader_member: Dictionary = captured.ecology_render_member("test", BoxMesh.new(),
		Transform3D.IDENTITY, "unknown_shader", "opaque", shader_material)
	check("unknown_shader_material_render_layer_stays_pending",
		shader_member.get("status") == "pending" \
		and shader_member.get("reason") == "shader_prop_render_semantics_unsupported" \
		and String(shader_member.get("renderLayer", "")).is_empty())
	var baseline_parent := Node3D.new()
	root.add_child(baseline_parent)
	var ledger: Object = Ledger.new()
	var captured_parent := _capture_parent(seed, "ore", "ore", ledger, captured)
	var baseline_rng := RandomNumberGenerator.new()
	var captured_rng := RandomNumberGenerator.new()
	baseline_rng.seed = 9371
	captured_rng.seed = 9371
	var baseline_nodes: Array = baseline.make_ore_cluster(baseline_parent,
		"ore-source", Vector3(3.0, 5.0, 7.0), "copperOre", baseline_rng, 2)
	var captured_nodes: Array = captured.make_ore_cluster(captured_parent,
		"ore-source", Vector3(3.0, 5.0, 7.0), "copperOre", captured_rng, 2)
	var captured_ore_body := captured_nodes[0] as StaticBody3D
	var captured_ore_bounds: Variant = captured_ore_body.get_meta("static_ecology_source_bounds", null) \
		if is_instance_valid(captured_ore_body) else null
	check("realized_prop_body_exports_stable_source_identity_and_world_bounds",
		is_instance_valid(captured_ore_body) \
		and String(captured_ore_body.get_meta("static_ecology_source_id", "")) \
			== "%s:ore:ore-source" % seed \
		and captured_ore_bounds is AABB and captured_ore_bounds.size.x > 0.0 \
		and captured_ore_bounds.size.y > 0.0 and captured_ore_bounds.size.z > 0.0)
	var ore_proof := {"producer":"surface_spawn", "chunk":Vector2i.ZERO,
		"sourceRevision":ledger.source_revision, "scanRevision":"", "producerComplete":true}
	var ore_completion_accepted: bool = ledger.mark_category_complete("ore", ore_proof)
	var ore_values := _candidates(ledger)
	var all_ore_members_complete := ore_values.size() == 2
	for candidate_value: Variant in ore_values:
		if not candidate_value is Dictionary:
			all_ore_members_complete = false
			continue
		var candidate: Dictionary = candidate_value
		all_ore_members_complete = all_ore_members_complete \
			and candidate.get("category") == "ore" \
			and candidate.get("provenance", {}).get("sourceCell") == Vector3i(4, -8, 9) \
			and candidate.get("provenance", {}).get("sourceRevision") == ledger.source_revision \
			and candidate.get("renderStatus") == "ready" \
			and candidate.get("renderMembers", []).size() == 9
	check("ore_creator_outputs_record_all_realized_members_with_source_provenance",
		all_ore_members_complete)
	check("ore_capture_does_not_change_rng_or_scene_creator_results",
		baseline_rng.state == captured_rng.state \
		and baseline_nodes.size() == captured_nodes.size() \
		and baseline_nodes[0].transform.is_equal_approx(captured_nodes[0].transform) \
		and baseline_nodes[1].transform.is_equal_approx(captured_nodes[1].transform))
	check("ore_family_completion_requires_its_current_chunk_proof", ore_completion_accepted)
	var ore_snapshot: Dictionary = ledger.snapshot()
	check("ore_category_proof_is_sealed_into_chunk_snapshot",
		ore_snapshot.get("completeCategories", []).has("ore") \
		and ore_snapshot.get("categoryProofs", {}).get("ore", {}).get("completeRevision", "").length() == 64)

	var forage_ledger: Object = Ledger.new()
	var forage_parent := _capture_parent(seed, "forage", "forage", forage_ledger,
		captured)
	var forage_baseline_rng := RandomNumberGenerator.new()
	var forage_capture_rng := RandomNumberGenerator.new()
	forage_baseline_rng.seed = 442
	forage_capture_rng.seed = 442
	var forage_baseline: Variant = baseline.make_forage(baseline_parent,
		"forage-source", Vector3(2.0, 1.0, 4.0), "swamp", forage_baseline_rng)
	var forage_captured: Variant = captured.make_forage(forage_parent,
		"forage-source", Vector3(2.0, 1.0, 4.0), "swamp", forage_capture_rng)
	var forage_values := _candidates(forage_ledger)
	check("forage_creator_outputs_record_the_produced_mesh_members",
		forage_values.size() == 1 \
		and forage_values[0].get("renderStatus") == "ready" \
		and forage_values[0].get("renderMembers", []).size() >= 1)
	check("forage_capture_preserves_rng_and_returned_body_transform",
		forage_baseline_rng.state == forage_capture_rng.state \
		and is_instance_valid(forage_baseline) and is_instance_valid(forage_captured) \
		and forage_baseline.transform.is_equal_approx(forage_captured.transform))

	var underground_ledger: Object = Ledger.new()
	var underground_parent := _capture_parent(seed, "underground_props", "underground",
		underground_ledger, captured, "terrain-floor-scan-r7")
	var underground_rng := RandomNumberGenerator.new()
	underground_rng.seed = 51
	captured.make_ore(underground_parent, "underground:ore:4,-8,9",
		Vector3(4.0, -7.0, 9.0), "ironOre", underground_rng)
	var underground_proof_without_scan := {"producer":"underground_exposed_floor_scan",
		"chunk":Vector2i.ZERO, "sourceRevision":underground_ledger.source_revision,
		"scanRevision":"", "producerComplete":true}
	var underground_proof_with_scan := underground_proof_without_scan.duplicate()
	underground_proof_with_scan["scanRevision"] = "terrain-floor-scan-r7"
	check("underground_empty_proof_without_scan_revision_is_rejected",
		not underground_ledger.mark_category_complete("underground_props",
			underground_proof_without_scan))
	check("underground_category_requires_and_accepts_current_scan_proof",
		underground_ledger.mark_category_complete("underground_props", underground_proof_with_scan))
	var underground_values := _candidates(underground_ledger)
	check("underground_creator_record_includes_authoritative_scan_revision",
		underground_values.size() == 1 \
		and underground_values[0].get("provenance", {}).get("scanRevision") == "terrain-floor-scan-r7")

	var fallback_parent := Node3D.new()
	root.add_child(fallback_parent)
	var fallback_baseline_parent := Node3D.new()
	root.add_child(fallback_baseline_parent)
	var fallback_ledger: Object = Ledger.new()
	var fallback_main: Variant = _main_with_materials(seed)
	var fallback_baseline_main: Variant = _main_with_materials(seed)
	fallback_parent.set_meta("static_ecology_source_value_ledger", fallback_ledger)
	var fallback_source_revision := String(fallback_main.call(
		"_ecology_chunk_source_revision", Vector2i.ZERO))
	fallback_ledger.configure(seed, Vector2i.ZERO, fallback_source_revision, 0)
	fallback_parent.set_meta("ecology_capture_context", {
		"producer":"surface_spawn", "category":"surface_rocks", "chunkX":0, "chunkZ":0,
		"terrainRevision":-1, "attemptIndex":0, "sourceCell":Vector3i.ZERO})
	fallback_main.visual_asset_registry = null
	fallback_baseline_main.visual_asset_registry = null
	var rock_rng := RandomNumberGenerator.new()
	var baseline_rock_rng := RandomNumberGenerator.new()
	rock_rng.seed = 88
	baseline_rock_rng.seed = 88
	var rock_body: StaticBody3D = fallback_main.make_rock(fallback_parent,
		"rock-source", Vector3(1.0, 2.0, 3.0), rock_rng)
	var baseline_rock_body: StaticBody3D = fallback_baseline_main.make_rock(
		fallback_baseline_parent, "rock-source", Vector3(1.0, 2.0, 3.0), baseline_rock_rng)
	var rock_proof := {"producer":"surface_spawn", "chunk":Vector2i.ZERO,
		"sourceRevision":fallback_ledger.source_revision, "producerComplete":true}
	var rock_completion_accepted: bool = fallback_ledger.mark_category_complete("surface_rocks", rock_proof)
	var rock_values := _candidates(fallback_ledger)
	check("fallback_rock_creator_records_exact_primitive_mesh_transform",
		rock_values.size() == 1 \
		and rock_values[0].get("renderStatus") == "ready" \
		and rock_values[0].get("renderMembers", []).size() == 1 \
		and rock_values[0].get("renderMembers", [])[0].get("materialKey") == "rock" \
		and rock_values[0].get("transform") == rock_body.transform)
	check("rock_capture_preserves_rng_and_creator_transform",
		baseline_rock_rng.state == rock_rng.state \
		and baseline_rock_body.transform.is_equal_approx(rock_body.transform))
	check("fallback_rock_category_has_explicit_producer_completion",
		rock_completion_accepted)

	var removal_ledger: Object = Ledger.new()
	removal_ledger.configure(seed, Vector2i.ZERO, source_revision, 4)
	var removal_candidate := {"sourceId":"forage-source", "propId":"durable-forage-id",
		"kind":"realized_static_prop", "category":"forage", "renderStatus":"ready",
		"renderMembers":[{"memberId":"mushroom_cap", "meshContentDigest":"a".repeat(64),
			"transform":Transform3D.IDENTITY, "meshBounds":AABB(Vector3.ZERO, Vector3.ONE),
			"localBounds":AABB(Vector3.ZERO, Vector3.ONE),
			"materialKey":"mushroomCap", "renderLayer":"opaque"}],
		"provenance":{"sourceRevision":source_revision, "chunk":Vector2i.ZERO,
			"creatorOutputComplete":true}}
	check("ledger_accepts_realized_prop_source_for_durable_removal",
		removal_ledger.record_candidate(removal_candidate))
	removal_ledger.apply_removed_props({"durable-forage-id":true}, 5)
	var removed_snapshot: Dictionary = removal_ledger.snapshot()
	check("durable_removal_replaces_candidate_with_truthful_tombstone",
		removed_snapshot.get("candidates", []).is_empty() \
		and removed_snapshot.get("tombstones", []).size() == 1 \
		and removed_snapshot.get("tombstones", [])[0].get("reason") == "removed_props" \
		and removed_snapshot.get("removedPropsRevision") == 5)

	var pending_ledger: Object = Ledger.new()
	pending_ledger.configure(seed, Vector2i.ZERO, source_revision, 0)
	var pending_candidate := {"sourceId":"generated-rock-source", "propId":"generated-rock",
		"kind":"realized_static_prop", "category":"surface_rocks", "renderStatus":"pending",
		"renderMembers":[], "pendingReason":"generated_rock_scene_member_values_not_bound",
		"provenance":{"sourceRevision":source_revision, "chunk":Vector2i.ZERO,
			"creatorOutputComplete":true}}
	check("unsupported_generated_rock_is_retained_as_pending",
		pending_ledger.record_candidate(pending_candidate))
	var stale_proof := {"producer":"surface_spawn", "chunk":Vector2i.ZERO,
		"sourceRevision":"stale-source-revision", "producerComplete":true}
	var current_proof := stale_proof.duplicate()
	current_proof["sourceRevision"] = source_revision
	check("stale_revision_and_pending_render_block_category_completion",
		not pending_ledger.mark_category_complete("surface_rocks", stale_proof) \
		and not pending_ledger.mark_category_complete("surface_rocks", current_proof))
	var terrain_bound_ledger: Object = Ledger.new()
	terrain_bound_ledger.configure(seed, Vector2i.ZERO, source_revision, 0, 7)
	var wrong_terrain_proof := {"producer":"surface_spawn", "chunk":Vector2i.ZERO,
		"sourceRevision":source_revision, "terrainRevision":8, "producerComplete":true}
	check("completion_proof_rejects_stale_terrain_revision",
		not terrain_bound_ledger.mark_category_complete("ore", wrong_terrain_proof))
	var split_ledger: Object = Ledger.new()
	split_ledger.configure(seed, Vector2i.ZERO, source_revision, 0, -1)
	for category: String in ["surface_rocks", "ore", "forage"]:
		var surface_proof := {"producer":"surface_spawn", "chunk":Vector2i.ZERO,
			"sourceRevision":source_revision, "terrainRevision":-1,
			"producerComplete":true}
		check("surface_family_%s_completion_proof" % category,
			split_ledger.mark_category_complete(category, surface_proof))
	var surface_snapshot: Dictionary = split_ledger.snapshot(false,
		"surface_pending_underground")
	var surface_missing: Array[String] = EcologyAdapter._missing_categories(
		surface_snapshot, false)
	var underground_missing: Array[String] = EcologyAdapter._missing_categories(
		surface_snapshot, true)
	check("surface_scope_defers_underground_without_claiming_empty",
		surface_snapshot.get("deferredCategories", []).has("underground_props") \
		and surface_missing.is_empty() \
		and underground_missing == ["underground_props"])
	var underground_proof := {"producer":"underground_exposed_floor_scan",
		"chunk":Vector2i.ZERO, "sourceRevision":source_revision,
		"terrainRevision":-1, "scanRevision":"floor-scan-r3",
		"producerComplete":true}
	check("surface_snapshot_leaves_ledger_open_for_underground_completion",
		split_ledger.mark_category_complete("underground_props", underground_proof))
	var full_scope_snapshot: Dictionary = split_ledger.snapshot()
	check("completed_underground_snapshot_replaces_deferred_surface_scope",
		full_scope_snapshot.get("contentScope") == "complete" \
		and full_scope_snapshot.get("deferredCategories", []).is_empty() \
		and full_scope_snapshot.get("completeCategories", []).has("underground_props"))

	var report_path := OS.get_environment("ECOLOGY_REALIZED_PROP_CAPTURE_REPORT")
	if report_path.is_empty():
		report_path = "user://ecology-realized-prop-capture-report.json"
	var report := {"schema":"ecology-realized-prop-capture-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"oreMemberCount":ore_values.size(),
		"forageMemberCount":forage_values.size(),
		"undergroundMemberCount":underground_values.size(),
		"fallbackRockMemberCount":rock_values.size(),
		"evidenceLevel":"real_production_static_ecology_creator_outputs_with_rng_replay"}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write ecology realized prop report: " + report_path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	baseline_parent.free()
	captured_parent.free()
	underground_parent.free()
	fallback_parent.free()
	fallback_baseline_parent.free()
	for main_value: Variant in [baseline, captured, fallback_main, fallback_baseline_main]:
		if is_instance_valid(main_value):
			main_value.free()
	await process_frame
	quit(0 if report.passed else 1)
