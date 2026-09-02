extends SceneTree

## Synthetic session lifecycle only: two jambs already clear their sealed opening.
## Real publisher descriptors/context; no full building, clipping or gameplay gate.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Declaration = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const Session = preload("res://scripts/buildings/MasonryAperturePublication.gd")
const Preparation = preload("res://scripts/testing/buildings/CitadelOpeningHeadVisualPreparation.gd")
const KEY := "synthetic_front"
const MAX_TURNS := 4096
var _checks: Dictionary = {}
var _runs: Array = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_MASONRY_PUBLICATION_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var small: Dictionary = _complete("small_budget", 25)
	var large: Dictionary = _complete("large_budget_drain", 4000)
	_checks["budget_independent_artifact"] = small.ready and large.ready and small.signature == large.signature
	for budget: int in [0, -1, 4001]:
		var b = _fixture()
		var publisher = _publisher(b)
		var session = Session.new()
		var begun: bool = session.begin(b, publisher)
		_checks["invalid_budget:" + str(budget)] = begun and session.advance(publisher, budget) == "failed" and session.reason == "invalid_slice_budget" and _hidden(session, b.parts)
	for mode: String in ["missing_collection", "missing_declaration"]:
		var b = _fixture()
		if mode == "missing_collection": b.recipe.erase("facadeApertures")
		else: b.recipe.facadeApertures.erase(KEY)
		var publisher = _publisher(b)
		var session = Session.new()
		_checks[mode + ":begin_rejected"] = not session.begin(b, publisher) and session.state == "failed" and not session.reason.is_empty() and _hidden(session, b.parts)
	for phase: String in ["pending", "ready"]:
		for mode: String in ["source_geometry", "source_remove", "source_rename", "source_replace", "marker_remove", "marker_rename", "marker_replace", "declaration_remove", "declaration_rename", "declaration_replace", "history", "publisher_identity"]:
			_stale(phase, mode)
	_direct_rejection()
	_pending_unmarked()
	_peer_after_ready()
	_extra_membership_after_ready()
	_declaration_stages()
	_aggregate_injection()
	_unit_snapshot_lifecycle()
	_unit_snapshot_boundaries()
	var passed: bool = _checks.values().all(func(value): return value == true)
	var report: Dictionary = {"passed": passed, "checks": _checks, "runs": _runs,
		"evidenceLevel": "synthetic_CPU_masonry_publication_session_contract",
		"limitations": "Two already-clear synthetic jambs; proves session lifecycle, immutable artifacts and rejection guards only. Aggregate controls inject near-cap counters: synthetic guard units, not stress/performance evidence. No intersecting-brick clipping, published positive geometry, mortar/collider clearance, GPU, normal integration or gameplay acceptance."}
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)

func _fixture():
	var b = Blueprint.new("synthetic_masonry_session", 17, "stone")
	b.recipe = {"sourceBlueprintId": "synthetic_canonical_masonry", "facadeApertures": {}}
	for index: int in range(2):
		b.add_part({"id": KEY + "_jamb_" + str(index), "kind": "wall", "material": "stone_foundation", "collision": true,
			"semantic": "synthetic_masonry_jamb", "position": Vector3(0, 0, -0.75 if index == 0 else 0.75), "size": Vector3(0.4, 1, 0.5),
			"recipe": {"masonryApertureSource": KEY, "variation": 0.0}})
	var input: Dictionary = {"centerY": 0.0, "centerZ": 0.0, "height": 1.0, "width": 0.75}
	var record: Dictionary = {"producerPrefix": KEY, "semantic": "synthetic_masonry_jamb", "wallDomain": AABB(Vector3(-0.2, -0.5, -1), Vector3(0.4, 1, 2)),
		"openings": [{"id": KEY + "_opening_000", "input": input, "fullVolume": AABB(Vector3(-0.2, -0.5, -0.375), Vector3(0.4, 1, 0.75))}]}
	b.recipe.facadeApertures[KEY] = Declaration.seal(record, b.parts)
	return b

func _publisher(b):
	var publisher = Publisher.new()
	publisher.source_blueprint_id = publisher.canonical_source_blueprint_id(b)
	publisher.surface_history.configure(b.recipe, b.parts)
	return publisher

func _hidden(session, parts: Array) -> bool:
	for part in parts:
		if not session.artifact(part).is_empty(): return false
	return true

func _drain(session, publisher, parts: Array, budget: int, label: String) -> bool:
	var hidden: bool = true
	var turns: int = 0
	var started: int = Time.get_ticks_msec()
	while session.state == "pending_budget" and turns < MAX_TURNS and Time.get_ticks_msec() - started < 10000:
		hidden = hidden and _hidden(session, parts)
		session.advance(publisher, budget)
		if session.state != "ready": hidden = hidden and _hidden(session, parts)
		turns += 1
	_checks[label + ":no_artifact_until_all_ready"] = hidden
	return session.state == "ready"

func _complete(label: String, budget: int) -> Dictionary:
	var b = _fixture()
	var publisher = _publisher(b)
	var before: PackedByteArray = var_to_bytes(b.snapshot())
	var context: PackedByteArray = Session.context_binding(publisher)
	var by_id: Dictionary = {}
	for part in b.parts: by_id[part.id] = part
	_checks[label + ":sealed_fixture"] = Declaration.validate(b.recipe.facadeApertures[KEY], by_id)
	var begun: bool = publisher.prepare_masonry_apertures(b)
	var session = publisher._masonry_preparation
	_checks[label + ":prepare_pending"] = begun and session.state == "pending_budget" and _hidden(session, b.parts)
	_checks[label + ":lazy_snapshot_capture"] = session._unit_snapshot == null and session.metrics.get("unitBoxArrayReadCount", 0) == 0
	var ready: bool = begun and _drain(session, publisher, b.parts, budget, label)
	var artifacts: Array = []
	var all_ready: bool = ready
	if ready:
		for part in b.parts:
			all_ready = all_ready and session.ready_for(part, publisher)
			var artifact: Dictionary = session.artifact(part)
			all_ready = all_ready and not artifact.is_empty() and not artifact.entries.is_empty()
			artifacts.append(artifact)
	_checks[label + ":all_ready_with_bricks"] = all_ready and session.metrics.parts == 2 and session.metrics.bricks > 0
	_checks[label + ":one_unit_read_all_bricks_reuse"] = all_ready and session.metrics.get("unitBoxArrayReadCount") == 1 and session.metrics.get("unitBoxTemplateHits") == session.metrics.bricks
	_checks[label + ":caller_and_context_immutable"] = before == var_to_bytes(b.snapshot()) and context == Session.context_binding(publisher)
	_runs.append({"name": label, "state": session.state, "reason": session.reason, "metrics": session.metrics.duplicate()})
	return {"ready": all_ready, "signature": var_to_bytes(_canonical(artifacts))}

func _stale(phase: String, mode: String) -> void:
	var b = _fixture()
	var publisher = _publisher(b)
	var begun: bool = publisher.prepare_masonry_apertures(b)
	var session = publisher._masonry_preparation
	var retained: Array = b.parts.duplicate()
	var label: String = phase + ":" + mode
	if phase == "ready": begun = begun and _drain(session, publisher, retained, 4000, label)
	var part = retained[0]
	match mode:
		"source_geometry": part.position.y += 0.125
		"source_remove": b.parts.erase(part)
		"source_rename": part.id += "_renamed"
		"source_replace": b.parts[0] = Blueprint.BuildingPartScript.new(part.snapshot())
		"marker_remove": part.recipe.erase("masonryApertureSource")
		"marker_rename":
			part.recipe["renamedMasonryApertureSource"] = part.recipe.masonryApertureSource
			part.recipe.erase("masonryApertureSource")
		"marker_replace": part.recipe.masonryApertureSource = "foreign"
		"declaration_remove": b.recipe.facadeApertures.erase(KEY)
		"declaration_rename":
			b.recipe.facadeApertures[KEY + "_renamed"] = b.recipe.facadeApertures[KEY]
			b.recipe.facadeApertures.erase(KEY)
		"declaration_replace": b.recipe.facadeApertures[KEY] = {"producerPrefix": KEY}
		"history": publisher.surface_history.history_events.append({"kind": "synthetic_context_change"})
		"publisher_identity": publisher.source_blueprint_id += "_changed"
	if phase == "pending": session.advance(publisher, 4000)
	var parent: Node3D = Node3D.new()
	var body: StaticBody3D = publisher.publish_part(part, parent)
	_checks[label + ":no_stale_children"] = body == null and parent.get_child_count() == 0
	parent.free()
	_checks[label + ":stale_failed_without_artifacts"] = begun and session.state == "failed" and not session.reason.is_empty() and _hidden(session, retained)

func _direct_rejection() -> void:
	for method: String in ["publish_part", "publish_static_part", "publish_visual", "publish_brick_wall"]:
		var b = _fixture()
		var publisher = _publisher(b)
		var parent: Node3D = Node3D.new()
		publisher.call(method, b.parts[0], parent)
		_checks["direct_without_session:" + method] = parent.get_child_count() == 0 and publisher.published_part_count == 0 and publisher.collision_count == 0 and publisher._masonry_preparation != null and publisher._masonry_preparation.state == "failed" and publisher._masonry_preparation.reason == "unprepared_direct_masonry_publication"
		parent.free()

func _pending_unmarked() -> void:
	var b = _fixture()
	b.parts[1].recipe.erase("masonryApertureSource")
	var publisher = _publisher(b)
	var begun: bool = publisher.prepare_masonry_apertures(b)
	var session = publisher._masonry_preparation
	var parent: Node3D = Node3D.new()
	for method: String in ["publish_part", "publish_static_part", "publish_visual", "publish_brick_wall"]:
		publisher.call(method, b.parts[1], parent)
		_checks["pending_unmarked:" + method] = begun and parent.get_child_count() == 0 and publisher.published_part_count == 0 and publisher.collision_count == 0 and session.state == "pending_budget" and session.reason.is_empty() and _hidden(session, b.parts)
	parent.free()
	_checks["pending_unmarked:still_resumable"] = begun and _drain(session, publisher, b.parts, 4000, "pending_unmarked_resume")

func _peer_after_ready() -> void:
	for mode: String in ["moved", "replaced"]:
		var b = _fixture()
		# This peer is geometry-bound but deliberately NOT a prepared request.
		b.parts[1].recipe.erase("masonryApertureSource")
		var publisher = _publisher(b)
		var begun: bool = publisher.prepare_masonry_apertures(b)
		var session = publisher._masonry_preparation
		var ready: bool = begun and _drain(session, publisher, b.parts, 4000, "peer_" + mode)
		var source_before: PackedByteArray = var_to_bytes(b.parts[0].snapshot())
		if mode == "moved": b.parts[1].position.y += 0.125
		else: b.parts[1] = Blueprint.BuildingPartScript.new(b.parts[1].snapshot())
		var parent: Node3D = Node3D.new()
		var body: StaticBody3D = publisher.publish_part(b.parts[0], parent)
		var expected: String = "stale_aperture_geometry" if mode == "moved" else "stale_aperture_peer"
		_checks["ready_unmarked_peer:" + mode] = ready and body == null and parent.get_child_count() == 0 and session.state == "failed" and session.reason == expected and _hidden(session, b.parts) and source_before == var_to_bytes(b.parts[0].snapshot())
		parent.free()

func _aggregate_injection() -> void:
	# Explicit synthetic near-cap injection; only ordinary tiny-fixture units run.
	var limits: Dictionary = {"bricks": Session.MAX_BRICKS, "vertices": Session.MAX_VERTICES, "fragments": Session.MAX_FRAGMENTS, "work": Session.MAX_WORK}
	for metric: String in limits:
		var b = _fixture()
		var publisher = _publisher(b)
		var begun: bool = publisher.prepare_masonry_apertures(b)
		var session = publisher._masonry_preparation
		var injected: int = int(limits[metric]) - (1 if metric in ["bricks", "vertices"] else 0)
		session.metrics[metric] = injected
		var turns: int = 0
		while session.state == "pending_budget" and turns < 32:
			session.advance(publisher, 4000)
			turns += 1
		var expected: String = "aggregate_brick_limit" if metric == "bricks" else "aggregate_resource_limit"
		_checks["synthetic_near_cap_injection:" + metric] = begun and session.state == "failed" and session.reason == expected and _hidden(session, b.parts) and session._artifacts.is_empty() and session._current.is_empty() and session._solids.is_empty()
		_runs.append({"name": "synthetic_near_cap_injection:" + metric, "injectedCounter": injected, "cap": limits[metric], "state": session.state, "reason": session.reason, "advanceCalls": turns})

func _extra_membership_after_ready() -> void:
	for mode: String in ["duplicate_peer", "renamed_unmarked_replacement"]:
		var b = _fixture()
		var publisher = _publisher(b)
		var begun: bool = publisher.prepare_masonry_apertures(b)
		var session = publisher._masonry_preparation
		var ready: bool = begun and _drain(session, publisher, b.parts, 4000, mode)
		var target = b.parts[0]
		if mode == "duplicate_peer":
			b.parts.append(Blueprint.BuildingPartScript.new(b.parts[1].snapshot()))
		else:
			target = Blueprint.BuildingPartScript.new(target.snapshot())
			target.id += "_new_identity"
			target.recipe.erase("masonryApertureSource")
			b.parts[0] = target
		var parent := Node3D.new()
		var body = publisher.publish_part(target, parent)
		_checks[mode + ":rejected_before_emission"] = ready and body == null and parent.get_child_count() == 0 and session.state == "failed" and session.reason == "stale_source_membership" and _hidden(session, b.parts)
		parent.free()

func _declaration_stages() -> void:
	for phase: String in ["before_seal_validation", "after_seal_validation"]:
		for mutation: String in ["position", "rotation", "size", "material", "collision", "semantic", "kind", "id", "resealed_declaration"]:
			var b = _fixture()
			b.parts[1].recipe.erase("masonryApertureSource")
			var publisher = _publisher(b)
			var begun: bool = publisher.prepare_masonry_apertures(b)
			var session = publisher._masonry_preparation
			var staged: bool = begun and session.metrics.declarationsValidated == 0
			if phase == "after_seal_validation":
				var turns := 0
				while session.state == "pending_budget" and session.metrics.declarationsValidated == 0 and turns < 128:
					session.advance(publisher, 1)
					turns += 1
				staged = staged and session.state == "pending_budget" and session.metrics.declarationsValidated == 1
			var peer = b.parts[1]
			match mutation:
				"position": peer.position.y += 0.0625
				"rotation": peer.rotation.x += 0.0625
				"size": peer.size.z += 0.0625
				"material": peer.material_id = "painted_brick_ochre"
				"collision": peer.collision_enabled = not peer.collision_enabled
				"semantic": peer.semantic += "_changed"
				"kind": peer.kind = "beam"
				"id": peer.id += "_changed"
				"resealed_declaration":
					peer.position.y += 0.0625
					var record: Dictionary = b.recipe.facadeApertures[KEY].duplicate(true)
					record.erase("sourceBinding")
					record.erase("partIds")
					b.recipe.facadeApertures[KEY] = Declaration.seal(record, b.parts)
			var turns := 0
			while session.state == "pending_budget" and turns < MAX_TURNS:
				session.advance(publisher, 4000)
				turns += 1
			_checks[phase + ":" + mutation] = staged and session.state == "failed" and not session.reason.is_empty() and _hidden(session, b.parts)

func _unit_snapshot_lifecycle() -> void:
	for phase: String in ["pending", "ready"]:
		for mode: String in ["replace", "resize", "corrupt", "owner_gone"]:
			var b = _fixture()
			var publisher = _publisher(b)
			var begun: bool = publisher.prepare_masonry_apertures(b)
			var session = publisher._masonry_preparation
			var label := "unit_snapshot:" + phase + ":" + mode
			session.advance(publisher, 1)
			var staged: bool = begun and session._unit_snapshot != null and session.state == "pending_budget"
			if phase == "ready": staged = staged and _drain(session, publisher, b.parts, 4000, label)
			var original: BoxMesh = publisher.unit_box
			var consumer = _publisher(b)
			match mode:
				"replace":
					publisher.unit_box = BoxMesh.new()
					publisher.unit_box.size = Vector3.ONE
				"resize": publisher.unit_box.size = Vector3(2, 1, 1)
				"corrupt": session._unit_snapshot._arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array()
				"owner_gone": publisher = null
			if phase == "pending":
				_drain(session, publisher if publisher != null else consumer, b.parts, 4000, label + ":mutated")
			else: session.ready_for(b.parts[0], consumer)
			_checks[label + ":failed_hidden"] = staged and session.state == "failed" and not session.reason.is_empty() and _hidden(session, b.parts)
			if publisher != null:
				publisher.unit_box = original
				original.size = Vector3.ONE
			_checks[label + ":no_revival_or_readback"] = session.advance(consumer, 4000) == "failed" and session.metrics.get("unitBoxArrayReadCount") == 1 and _hidden(session, b.parts)
	var b = _fixture()
	var owner = _publisher(b)
	var begun: bool = owner.prepare_masonry_apertures(b)
	var session = owner._masonry_preparation
	var ready: bool = begun and _drain(session, owner, b.parts, 4000, "borrowed_artifacts")
	var consumer = _publisher(b)
	_checks["unit_snapshot:borrowed_consumer_keeps_original_owner"] = ready and consumer.unit_box != owner.unit_box and session.ready_for(b.parts[0], consumer) and not session.artifact(b.parts[0]).is_empty()

func _unit_snapshot_boundaries() -> void:
	for mode: String in ["replace", "owner_gone"]:
		var b = _fixture()
		var publisher = _publisher(b)
		var begun: bool = publisher.prepare_masonry_apertures(b)
		var session = publisher._masonry_preparation
		var turns := 0
		while session.state == "pending_budget" and session._part_cursor < session._requests.size() and turns < MAX_TURNS:
			session.advance(publisher, 1)
			turns += 1
		var staged: bool = begun and session.state == "pending_budget" and session._part_cursor == session._requests.size() and session.metrics.finalValidationUsec == 0
		var consumer = _publisher(b)
		if mode == "replace":
			publisher.unit_box = BoxMesh.new()
			publisher.unit_box.size = Vector3.ONE
		else: publisher = null
		_checks["finalization_only:" + mode] = staged and session.advance(consumer, 4000) == "failed" and session.metrics.get("unitBoxArrayReadCount") == 1 and _hidden(session, b.parts)
	for mode: String in ["replace", "flip_faces"]:
		var b = _fixture()
		var publisher = _publisher(b)
		var begun: bool = publisher.prepare_masonry_apertures(b)
		var session = publisher._masonry_preparation
		var identity: String = Preparation.unadvanced_masonry_identity(publisher)
		if mode == "replace":
			publisher.unit_box = BoxMesh.new()
			publisher.unit_box.size = Vector3.ONE
		else: publisher.unit_box.flip_faces = true
		_checks["pre_capture:" + mode + ":handoff_rejected"] = begun and not identity.is_empty() and Preparation.unadvanced_masonry_identity(publisher).is_empty()
		_checks["pre_capture:" + mode + ":no_adoption_or_readback"] = session.advance(publisher, 4000) == "failed" and session.metrics.get("unitBoxArrayReadCount", 0) == 0 and _hidden(session, b.parts)
	for boundary: String in ["final_handoff", "unmarked_emission", "borrowed_emission"]:
		var b = _fixture()
		b.add_part({"id": "ordinary_beam", "kind": "beam", "material": "timber", "position": Vector3(5, 0, 0), "size": Vector3.ONE})
		var publisher = _publisher(b)
		var begun: bool = publisher.prepare_masonry_apertures(b)
		var session = publisher._masonry_preparation
		var ready: bool = begun and _drain(session, publisher, b.parts, 4000, boundary)
		var before: Dictionary = Preparation.geometry_identity(publisher)
		var consumer = publisher
		if boundary == "borrowed_emission":
			consumer = _publisher(b)
			consumer._masonry_preparation = session
		consumer.unit_box.flip_faces = true
		if boundary == "final_handoff":
			_checks[boundary + ":changed_unit_rejected"] = ready and not before.is_empty() and Preparation.geometry_identity(publisher).is_empty() and session.state == "failed"
		else:
			var parent := Node3D.new()
			var body: StaticBody3D = consumer.publish_part(b.parts[2], parent)
			_checks[boundary + ":changed_unit_rejected"] = ready and body == null and parent.get_child_count() == 0 and session.state == "failed" and _hidden(session, b.parts)
			parent.free()

func _canonical(value: Variant) -> Variant:
	if value is Mesh:
		var surfaces: Array = []
		for index: int in range(value.get_surface_count()): surfaces.append(value.surface_get_arrays(index))
		return {"meshSurfaces": surfaces}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[key] = _canonical(value[key])
		return result
	if value is Array: return value.map(_canonical)
	return value
