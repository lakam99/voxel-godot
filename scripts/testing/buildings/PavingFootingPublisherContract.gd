extends SceneTree

## Synthetic source-service / actual CPU publication arguments only. No GPU
## readback, physics frames, navigation, source placement or visual acceptance.
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Assembly = preload("res://scripts/buildings/PavingFootingAssemblyRecipe.gd")
const Geometry = preload("res://scripts/buildings/SettledCobbleGeometry.gd")

class Capture:
	extends Publisher
	var rows: Array = []
	var requests: Array = []
	func material_for_id(id: String, variation := 0.0) -> Material:
		requests.append([id, variation])
		return super.material_for_id(id, variation)
	func add_mesh_batch(parent: Node3D, mesh: Mesh, transforms: Array, material: Material, label: String, custom: Array = []) -> MultiMeshInstance3D:
		for index in range(transforms.size()):
			rows.append({"mesh": mesh, "transform": static_visual_part_transform * transforms[index] if static_visual_collecting else transforms[index], "custom": custom[index] if custom.size() == transforms.size() else "unexpected_generated_custom", "material": material, "label": label})
		return super.add_mesh_batch(parent, mesh, transforms, material, label, custom)
	func add_box_visual(parent: Node3D, size: Vector3, position: Vector3, material: Material, label: String) -> void:
		var transform: Transform3D = Transform3D(Basis.IDENTITY.scaled(size), position)
		rows.append({"mesh": unit_box, "transform": static_visual_part_transform * transform if static_visual_collecting else transform, "custom": Color(0.5, 0.5, 0.5, 1) if static_visual_collecting else null, "material": material, "label": label})
		super.add_box_visual(parent, size, position, material, label)
	func add_mesh_visual(parent: Node3D, mesh: Mesh, size: Vector3, position: Vector3, material: Material, label: String) -> void:
		var transform: Transform3D = Transform3D(Basis.IDENTITY.scaled(size), position)
		rows.append({"mesh": mesh, "transform": static_visual_part_transform * transform if static_visual_collecting else transform, "custom": null, "material": material, "label": label})
		super.add_mesh_visual(parent, mesh, size, position, material, label)

var checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks.append({"label": label, "passed": passed})

func _run() -> void:
	var output: String = OS.get_environment("VOXEL_PAVING_FOOTING_PUBLISHER_REPORT")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var started: int = Time.get_ticks_msec()
	var source = Blueprint.new("synthetic_paving_publisher", 41, "timber")
	source.recipe = {"sourceBlueprintId": "synthetic_canonical_history"}
	var finish = source.add_part({"id": "finish", "kind": "foundation", "material": "cobblestone", "collision": false,
		"position": Vector3(0, 0.0625, 0), "size": Vector3(4, 0.125, 4), "recipe": {"pavingFamily": "civic_setts"}})
	var foot = source.add_part({"id": "foot", "kind": "beam", "material": "stone_foundation", "collision": true,
		"position": Vector3(0, 0.25, 0), "size": Vector3(0.25, 0.5, 0.25)})
	var before: PackedByteArray = var_to_bytes(source.snapshot())
	var prepared: Dictionary = Assembly.prepare(source, [finish.id], [foot], 0.01)
	_check("actual_assembly_synthetic_geometry_ready", bool(prepared.get("ready", false)))
	_check("assembly_source_unchanged", before == var_to_bytes(source.snapshot()))
	if bool(prepared.get("ready", false)):
		finish.recipe.pavingFootingJoints = prepared.joints.finish.duplicate(true)
		var snapshot: Dictionary = source.snapshot()
		for static_mode in [false, true]:
			_payload_controls(snapshot, static_mode)
			_uncut_controls(snapshot, static_mode)
		_prebegin_controls(snapshot)
		_stale_controls(snapshot)
		_bound_foot_controls(snapshot)
		_limit_controls(snapshot)
	var passed: bool = checks.all(func(row): return row.passed)
	var report: Dictionary = {"passed": passed, "checks": checks, "checkCount": checks.size(), "elapsedMsec": Time.get_ticks_msec() - started,
		"assemblyReason": prepared.get("reason", ""), "publisherSha256": FileAccess.get_sha256("res://scripts/buildings/BuildingPartPublisher.gd"),
		"evidenceLevel": "synthetic_source_service_and_actual_CPU_publication_arguments",
		"doesNotProve": "No GPU instance readback, shader execution, live collision, actual frame transaction, navigation, visual or placement acceptance."}
	var file: FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if passed else 2)

func _copy(snapshot: Dictionary):
	var b = Blueprint.new(snapshot.id, snapshot.seed, snapshot.style)
	b.recipe = snapshot.recipe.duplicate(true)
	for record in snapshot.parts:
		var part = b.add_part(record)
		part.physical_intent = record.physicalIntent
		# find_part reads this index; add_part alone intentionally does not fill
		# it. Test setup needs lookup before begin_publication's validation pass.
		b.physical_parts_by_id[part.id] = part
	return b

func _parent() -> Node3D:
	var node: Node3D = Node3D.new()
	root.add_child(node)
	return node

func _dispose(publisher, parent: Node3D) -> void:
	publisher.clear_published()
	parent.free()

func _payload_controls(snapshot: Dictionary, static_mode: bool) -> void:
	var b = _copy(snapshot)
	var parent: Node3D = _parent()
	var publisher = Capture.new()
	var ready: bool = publisher.begin_publication(b, parent, {"batchStaticParts": static_mode})
	var tag: String = "static" if static_mode else "standard"
	_check(tag + "_committed_rebuild_ready", ready)
	_check(tag + "_prepare_no_nodes_counts_materials", parent.get_child_count() == 0 and publisher.published_part_count == 0 and publisher.material_cache.is_empty() and publisher.requests.is_empty())
	if not ready:
		_dispose(publisher, parent)
		return
	var before: PackedByteArray = var_to_bytes(b.snapshot())
	var artifact: Dictionary = publisher._paving_artifacts.finish.artifact
	var finish = b.find_part("finish")
	var body = publisher.publish_part(finish, parent)
	var expected: Array = []
	var changed: int = 0
	var native: int = 0
	var variation: float = publisher.variation_for(finish)
	for entry in artifact.entries:
		var original: Dictionary = entry.original
		var mesh: Mesh = publisher.unit_box if entry.unchanged else entry.mesh
		if mesh == null: continue
		if entry.unchanged: native += 1
		else: changed += 1
		var id: String = original.materialKey if original.group == "bed" else (finish.material_id if original.group == "regular" else "worn_cobble")
		var tint: float = variation - 0.025 if original.group == "bed" else (variation if original.group == "regular" else variation - 0.016)
		var custom: Variant = original.customData
		if original.group == "bed" and static_mode: custom = Color(0.5, 0.5, 0.5, 1)
		var label: String = "CobbleJointBed" if original.group == "bed" else ("SettledCobbleStones" if original.group == "regular" else "WornSettledCobbleStones")
		expected.append({"mesh": mesh, "transform": artifact.sourceTransform * original.localTransform if static_mode else original.localTransform,
			"custom": custom, "material": publisher.material_cache.get("%s:%0.3f" % [id, tint]), "label": label})
	_check(tag + "_all_ordered_native_and_changed_payloads_exact", expected == publisher.rows)
	_check(tag + "_both_native_and_changed_exercised", native > 0 and changed > 0)
	_check(tag + "_bed_custom_convention", not publisher.rows.is_empty() and publisher.rows[0].custom == (Color(0.5, 0.5, 0.5, 1) if static_mode else null))
	_check(tag + "_original_parent_frame", static_mode or (body != null and body.position == finish.position and body.rotation == finish.rotation))
	var requests: Array = [[artifact.entries[0].original.materialKey, variation - 0.025], [finish.material_id, variation]]
	if artifact.entries.any(func(entry): return entry.original.group == "worn"): requests.append(["worn_cobble", variation - 0.016])
	_check(tag + "_material_input_order_exact", publisher.requests == requests)
	_check(tag + "_publish_source_unchanged_and_no_finish_collision", before == var_to_bytes(b.snapshot()) and publisher.collision_count == 0)
	_check(tag + "_direct_part_not_whole_publication_completion", not bool(publisher.summary().pavingFootingPublication.complete))
	_dispose(publisher, parent)

func _uncut_controls(snapshot: Dictionary, static_mode: bool) -> void:
	var b = _copy(snapshot)
	var finish = b.find_part("finish")
	finish.recipe.erase("pavingFootingJoints")
	var publisher = Capture.new()
	var oracle = Capture.new()
	var parent: Node3D = _parent()
	var other: Node3D = _parent()
	_check("uncut_begin_%s" % static_mode, publisher.begin_publication(b, parent) and oracle.begin_publication(b, other))
	oracle.unit_box = publisher.unit_box
	# Identical retained material objects let the oracle compare complete payload
	# arguments without replacing material fields by names or resource IDs.
	oracle.material_cache = publisher.material_cache
	for recorder in [publisher, oracle]:
		recorder.static_visual_collecting = static_mode
		recorder.static_visual_part_transform = b.part_transform(finish)
	publisher.publish_settled_cobble(finish, parent)
	var geometry: Dictionary = Geometry.describe_source(finish, oracle.surface_history, oracle.source_blueprint_id)
	var bed: Dictionary = geometry.bed
	# Explicit old emission sequence, no duplicated paving geometry formula.
	oracle.add_box_visual(other, bed.size, bed.position, oracle.material_for_id(bed.materialId, oracle.variation_for(finish) - 0.025), "CobbleJointBed")
	oracle.add_mesh_batch(other, oracle.unit_box, geometry.regularTransforms, oracle.material_for(finish), "SettledCobbleStones", geometry.regularCustomData)
	if not geometry.wornTransforms.is_empty(): oracle.add_mesh_batch(other, oracle.unit_box, geometry.wornTransforms, oracle.material_for_id("worn_cobble", oracle.variation_for(finish) - 0.016), "WornSettledCobbleStones", geometry.wornCustomData)
	_check("uncut_original_payload_material_sequence_%s" % static_mode, publisher.rows == oracle.rows and publisher.requests == oracle.requests)
	_check("uncut_no_new_readiness_fields_%s" % static_mode, not publisher.summary().has("pavingFootingPublication"))
	_dispose(publisher, parent)
	_dispose(oracle, other)

func _prebegin_controls(snapshot: Dictionary) -> void:
	for mode in ["missing_foot", "duplicate_foot", "collision_finish", "nan_joint", "missing_hash", "false_hash", "moved_foot", "moved_finish", "canonical_history_changed"]:
		var b = _copy(snapshot)
		var finish = b.find_part("finish")
		match mode:
			"missing_foot": finish.recipe.pavingFootingJoints.footPartIds = ["absent"]
			"duplicate_foot": finish.recipe.pavingFootingJoints.footPartIds = ["foot", "foot"]
			"collision_finish": finish.collision_enabled = true
			"nan_joint": finish.recipe.pavingFootingJoints.nominalJoint = NAN
			"missing_hash": finish.recipe.pavingFootingJoints.erase("geometryDigest")
			"false_hash": finish.recipe.pavingFootingJoints.geometryDigest = "0".repeat(64)
			"moved_foot": b.find_part("foot").position.x += 0.125
			"moved_finish": finish.position.x += 0.125
			"canonical_history_changed": b.recipe.sourceBlueprintId = "different_history"
		var committed: PackedByteArray = var_to_bytes(finish.recipe.pavingFootingJoints)
		var publisher = Capture.new()
		var parent: Node3D = _parent()
		_check(mode + "_prebegin_reject", not publisher.begin_publication(b, parent))
		publisher.publish_part(finish, parent)
		publisher.publish_static_part(finish, parent)
		publisher.publish_visual(finish, parent)
		publisher.publish_settled_cobble(finish, parent)
		var result: Dictionary = publisher.finish_publication(b, parent)
		_check(mode + "_atomic_no_fallback", parent.get_child_count() == 0 and publisher.rows.is_empty() and publisher.requests.is_empty() and publisher.published_part_count == 0 and publisher.collision_count == 0 and not bool(result.pavingFootingPublication.complete))
		_check(mode + "_never_replaces_committed_expectation", committed == var_to_bytes(finish.recipe.pavingFootingJoints))
		_dispose(publisher, parent)

func _stale_controls(snapshot: Dictionary) -> void:
	for mode in ["no_begin", "foot", "finish", "recipe", "history_part", "history_object", "declaration_removed", "replacement_object"]:
		var b = _copy(snapshot)
		var finish = b.find_part("finish")
		var publisher = Capture.new()
		var parent: Node3D = _parent()
		if mode != "no_begin":
			var ready: bool = publisher.begin_publication(b, parent)
			_check(mode + "_initially_prepared", ready)
			if not ready:
				_dispose(publisher, parent)
				continue
		match mode:
			"foot": b.find_part("foot").position.x += 0.125
			"finish": finish.position.z += 0.125
			"recipe": b.recipe["newHistoryFact"] = 1
			"history_part": b.add_part({"id": "new_window", "kind": "window", "position": Vector3(0, 1, 0)})
			"history_object": publisher.surface_history.history_events.append({"kind": "synthetic_changed"})
			"declaration_removed": finish.recipe.erase("pavingFootingJoints")
			"replacement_object": finish = _copy(snapshot).find_part("finish")
		publisher.publish_part(finish, parent)
		_check(mode + "_direct_failclosed_before_body", not publisher._paving_failure.is_empty() and parent.get_child_count() == 0 and publisher.published_part_count == 0 and publisher.requests.is_empty())
		var next: int = publisher.publish_part_batch(b, parent, 0, 10)
		_check(mode + "_batch_no_false_progress", next == 0 and publisher.incremental_published_parts == 0 and not bool(publisher.finish_publication(b, parent).pavingFootingPublication.complete))
		_dispose(publisher, parent)

func _bound_foot_controls(snapshot: Dictionary) -> void:
	# Each entry point gets a FRESH prepared session. A previous failed finish
	# publication must not prime the sticky error and conceal a foot bypass.
	for entry in ["part", "static", "visual", "batch"]:
		for mode in ["unchanged", "moved", "replacement", "renamed"]:
			var b = _copy(snapshot)
			var publisher = Capture.new()
			var parent: Node3D = _parent()
			var ready: bool = publisher.begin_publication(b, parent)
			var label: String = "bound_foot_%s_%s" % [entry, mode]
			_check(label + "_fresh_ready", ready)
			if not ready:
				_dispose(publisher, parent)
				continue
			var foot = b.find_part("foot")
			var foot_index: int = b.parts.find(foot)
			if mode == "moved": foot.position.x += 0.125
			elif mode == "replacement":
				foot = _copy(snapshot).find_part("foot")
				# Direct calls get a byte-identical imposter not in the source.
				# Batch calls get that imposter in the actual source array instead.
				if entry == "batch":
					b.parts[foot_index] = foot
					b.physical_parts_by_id[foot.id] = foot
			elif mode == "renamed": foot.id = "renamed_bound_foot"
			var next_index: int = foot_index
			match entry:
				"part": publisher.publish_part(foot, parent)
				"static": publisher.publish_static_part(foot, parent)
				"visual": publisher.publish_visual(foot, parent)
				"batch": next_index = publisher.publish_part_batch(b, parent, foot_index, 1)
			if mode == "unchanged":
				_check(label + "_allowed_without_finish_artifact", publisher._paving_failure.is_empty() and not publisher._paving_artifacts.has(foot.id) and not publisher.rows.is_empty() and parent.get_child_count() > 0)
				_check(label + "_normal_counts", publisher.collision_count == (0 if entry == "visual" else 1) and (entry != "batch" or (next_index == foot_index + 1 and publisher.incremental_published_parts == 1)))
			else:
				_check(label + "_reject_before_any_emission", not publisher._paving_failure.is_empty() and parent.get_child_count() == 0 and publisher.rows.is_empty() and publisher.requests.is_empty() and publisher.published_nodes.is_empty() and publisher.static_visual_batches.is_empty())
				_check(label + "_no_counts_or_progress", publisher.published_part_count == 0 and publisher.collision_count == 0 and publisher.visual_batch_count == 0 and publisher.incremental_published_parts == 0 and next_index == foot_index)
				_check(label + "_finish_remains_failed", not bool(publisher.finish_publication(b, parent).pavingFootingPublication.complete))
			_dispose(publisher, parent)
	# An undeclared, unbound ordinary part still supports the old direct API.
	var ordinary = _copy(snapshot).find_part("foot")
	var direct = Capture.new()
	var parent: Node3D = _parent()
	direct.publish_part(ordinary, parent)
	_check("unbound_ordinary_foot_no_begin_still_allowed", direct._paving_failure.is_empty() and direct.published_part_count == 1 and direct.collision_count == 1 and not direct.rows.is_empty() and not direct.summary().has("pavingFootingPublication"))
	_dispose(direct, parent)


func _limit_controls(snapshot: Dictionary) -> void:
	for mode in ["five_finishes", "seventeen_unique_feet"]:
		var b = _copy(snapshot)
		if mode == "five_finishes":
			for index in range(4):
				var record: Dictionary = snapshot.parts[0].duplicate(true)
				record.id = "extra_finish_%d" % index
				b.add_part(record)
		else:
			var second: Dictionary = snapshot.parts[0].duplicate(true)
			second.id = "second_finish"
			var finish2 = b.add_part(second)
			var ids: Array = ["foot"]
			for index in range(16):
				var record: Dictionary = snapshot.parts[1].duplicate(true)
				record.id = "extra_foot_%d" % index
				b.add_part(record)
				ids.append(record.id)
			b.find_part("finish").recipe.pavingFootingJoints.footPartIds = ids.slice(0, 16)
			finish2.recipe.pavingFootingJoints.footPartIds = [ids[16]]
		var publisher = Capture.new()
		var parent: Node3D = _parent()
		_check(mode + "_aggregate_limit_before_preparation", not publisher.begin_publication(b, parent) and publisher._paving_artifacts.is_empty() and publisher._paving_blueprint == null and parent.get_child_count() == 0 and publisher.requests.is_empty())
		_dispose(publisher, parent)
