extends SceneTree

## Exact production producer subset, not a composed source or physical proof.
const Sampler = preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Field = preload("res://scripts/world/CitadelSiteField.gd")
const Site = preload("res://scripts/world/CitadelSitePreparation.gd")
var output: String
var deadline: int
var worker: Thread

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output = OS.get_environment("CITADEL_CIVIC_WALL_OUTPUT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):
		quit(2)
		return
	deadline = Time.get_ticks_msec() + 30000
	worker = Thread.new()
	if worker.start(_work) != OK:
		quit(2)
		return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "  "))
	file.flush()
	var saved: bool = file.get_error() == OK
	file.close()
	print("Civic wall producer subset completed=", report.diagnosticCompleted, " cases=", report.cases.size())
	quit(0 if saved and report.diagnosticCompleted else 1)

func _hashes() -> Dictionary:
	var result: Dictionary = {}
	for folder: String in ["res://scripts/buildings", "res://scripts/world"]:
		for name: String in DirAccess.get_files_at(folder):
			if name.ends_with(".gd"):
				var path: String = folder.path_join(name)
				result[path] = FileAccess.get_sha256(path)
	result[get_script().resource_path] = FileAccess.get_sha256(get_script().resource_path)
	return result

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var hashes := _hashes()
	var cases: Array = []
	for item: Dictionary in [{"region": Vector2i(-1, 0), "seed": 541151883, "biome": "forest"}, {"region": Vector2i(0, -1), "seed": 1747969299, "biome": "plains"}]:
		if Time.get_ticks_msec() >= deadline: break
		cases.append(_case(item))
	var changed: Array = []
	var after := _hashes()
	for path: String in hashes:
		if hashes[path] != after.get(path): changed.append(path)
	return {"diagnosticCompleted": cases.size() == 2 and cases.all(func(row): return row.get("ready", false)) and changed.is_empty() and Time.get_ticks_msec() < deadline,
		"evidenceLevel": "production sampler and curtain/civic producer subset only", "cases": cases,
		"sourceHashes": hashes, "changedSources": changed, "elapsedUsec": Time.get_ticks_usec() - started,
		"internalDeadlineSeconds": 30, "physicalProofPerformed": false, "fullSourceEquivalent": false,
		"limitations": "Center biomes are supplied from recorded public-recipe inputs, not resurveyed. No courtyard planning, other buildings, shop changes, retained paving, facade completion, furniture, full physical proof, SceneNodes, or publication. AABB extents are produced part envelopes, not exact roof solids. Does not reproduce the proposed opening-head connection itself."}

func _case(item: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var candidate: Dictionary = Field.candidate_for_region("atlas-30895044", item.region)
	if candidate.get("recipeSeed") != item.seed: return {"ready": false, "reason": "candidate_identity_mismatch"}
	var context := {"biome": item.biome, "siteKey": candidate.siteId, "citadelScale": Site.SCALE}
	# Exact build_with_diagnostics pre-sampler normalization (not sampler defaults).
	var builder_context: Dictionary = context.duplicate(true)
	builder_context["settlementTier"] = "city"
	builder_context["style"] = "masonry"
	var compound: Dictionary = Sampler.sample_compound(item.seed, "castle", builder_context)
	var grammar: Dictionary = compound.castleGrammar
	var members: Array = compound.members
	var courtyard: Dictionary = Castle.member_recipe(members, "courtyard")
	var gatehouse: Dictionary = Castle.member_recipe(members, "gatehouse")
	var towers: Array = Castle.member_recipes(members, "tower")
	# Same fallback expressions and argument order as Castle.build_from_compound.
	var width := float(grammar.get("courtyardWidth", courtyard.get("width", 46.0)))
	var depth := float(grammar.get("courtyardDepth", courtyard.get("depth", 42.0)))
	var span := float(grammar.get("towerSpan", (towers[0] as Dictionary).get("width", 6.4) if not towers.is_empty() else 6.4))
	var count := clampi(int(grammar.get("towerCount", 4)), 4, 8)
	var height := float(grammar.get("wallHeight", float(gatehouse.get("floorHeight", 3.6)) * 1.70))
	var tower_height := float(grammar.get("towerHeightBase", float((towers[0] as Dictionary).get("floorHeight", 3.6)) * 3.4 if not towers.is_empty() else 12.4))
	var specs: Array = Castle.tower_specs_for_grammar(item.seed, width, depth, count, span, tower_height, float(grammar.get("towerHeightVariation", 0.16)), int(grammar.get("towerPhase", 0)))
	var north := Castle.tower_span_for_role(specs, "northeast", span)
	var south := Castle.tower_span_for_role(specs, "southwest", span)
	var material := String((grammar.get("citadelMasonry", {}) as Dictionary).get("fortification", "fired_brick"))
	var variation := float(int(item.seed) % 19) / 100.0 - 0.09
	var b = Blueprint.new("compound.castle.%d.%s" % [item.seed, candidate.siteId], item.seed, "masonry")
	b.set_recipe({"castleGrammar": grammar.duplicate(true), "foundationHeight": 0.62})
	Castle.add_curtain_z_segment(b, "castle_right_wall", width * 0.5, -depth * 0.5 + north * 0.5, depth * 0.5 - south * 0.5, height, 0.62, variation, material)
	# Composer intentionally uses the grammar keepDepth directly, not Castle's clamp.
	var compose_depth := float(grammar.get("courtyardDepth", 84.0))
	var keep_depth := float(grammar.get("keepDepth", 28.0))
	var keep_center := compose_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14))
	var keep_front := keep_center - keep_depth * 0.5
	var front := -compose_depth * 0.5
	var layout: Dictionary = Urban.sample_urban_layout(item.seed, grammar, front, keep_front, 0.62)
	b.recipe["urbanPoc"] = layout
	var reset: Dictionary = Urban.reset_street_house_structural_manifest(b)
	if not reset.ready: return reset
	var produced: Dictionary = Urban.add_civic_quarter(b, front, keep_front, 0.62, variation, layout)
	if not produced.ready: return produced
	# find_part reads the physical-proof index; this subset deliberately has not
	# run physical resolution. Inspect actual producer objects directly.
	var wall = null
	for part in b.parts:
		if part.id == "castle_right_wall_wall": wall = part
	if wall == null: return {"ready": false, "reason": "missing_wall"}
	var wall_bounds: AABB = b.transformed_part_bounds(wall)
	var records: Array = []
	var extents: Dictionary = {}
	for part in b.parts:
		if not part.id.begins_with("urban_civic_house_"): continue
		var bounds: AABB = b.transformed_part_bounds(part)
		var owner: String = "urban_civic_house_wall" if part.id.begins_with("urban_civic_house_wall_") else "urban_civic_house_east"
		extents[owner] = (extents[owner] as AABB).merge(bounds) if extents.has(owner) else bounds
		var overlap: Vector3 = bounds.end.min(wall_bounds.end) - bounds.position.max(wall_bounds.position)
		records.append({"producerPrefix": owner, "part": part.snapshot(), "bounds": bounds,
			"inwardXClearance": float(wall_bounds.position.x) - float(bounds.end.x), "signedAabbOverlap": overlap,
			"positiveAabbOverlap": overlap.x > 0.0 and overlap.y > 0.0 and overlap.z > 0.0})
	var snapshot: Dictionary = b.snapshot()
	var typed_path := output.get_base_dir().path_join("subset-%d.bin" % item.seed)
	var file := FileAccess.open(typed_path, FileAccess.WRITE)
	if file == null: return {"ready": false, "reason": "snapshot_open_failed"}
	file.store_var({"compound": compound, "blueprint": snapshot, "rawContext": context, "builderContext": builder_context}, false)
	file.flush()
	var saved: bool = file.get_error() == OK
	file.close()
	var historical: Dictionary = _historical(snapshot) if item.seed == 1747969299 else {"performed": false, "reason": "failed_public_recipe_does_not_export_blueprint"}
	return {"ready": saved and (not historical.get("performed", false) or historical.get("bindingValid", false)), "recipeSeed": item.seed, "region": item.region, "rawContext": context, "builderContext": builder_context, "candidate": candidate,
		"sampledGrammar": grammar, "towerSpecs": specs, "urbanLayout": layout, "civicReceipt": produced,
		"arguments": {"width": width, "depth": depth, "wallHeight": height, "foundationHeight": 0.62, "variation": variation,
			"northEastSpan": north, "southWestSpan": south, "keepDepth": keep_depth, "keepCenterZ": keep_center, "keepFrontZ": keep_front, "frontZ": front},
		"wall": wall.snapshot(), "wallBounds": wall_bounds, "wallInnerFaceX": wall_bounds.position.x,
		"housePieceBounds": extents, "houseParts": records, "partCount": b.parts.size(), "subsetFile": typed_path,
		"historicalComparison": historical,
		"subsetSha256": FileAccess.get_sha256(typed_path), "elapsedUsec": Time.get_ticks_usec() - started}

func _historical(snapshot: Dictionary) -> Dictionary:
	var path := "res://artifacts/citadel-runtime-integration/candidate-recipe-02/caller-blueprint.bin"
	var expected := "114a393279c1ae7676fca8f3ca9a9d7688c86c8cb0d587dbe203ab2a8d0a66b3"
	var actual := FileAccess.get_sha256(path)
	if actual != expected: return {"performed": true, "bindingValid": false, "reason": "historical_hash_mismatch"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"performed": true, "bindingValid": false, "reason": "historical_open_failed"}
	var raw: Variant = file.get_var(false)
	var valid: bool = file.get_error() == OK and raw is Dictionary and raw.get("parts") is Array
	file.close()
	if not valid: return {"performed": true, "bindingValid": false, "reason": "historical_decode_failed"}
	var index: Dictionary = {}
	for record: Dictionary in raw.parts: index[record.id] = record
	var compared: Array = []
	for record: Dictionary in snapshot.parts:
		if record.id != "castle_right_wall_wall" and not String(record.id).begins_with("urban_civic_house_"): continue
		var old: Dictionary = index.get(record.id, {})
		var changed: Array = []
		for key: String in ["id", "kind", "material", "position", "rotation", "size", "collision", "semantic"]:
			if var_to_bytes(record.get(key)) != var_to_bytes(old.get(key)): changed.append(key)
		compared.append({"id": record.id, "found": not old.is_empty(), "geometryIdentityExact": changed.is_empty(), "changedGeometryFields": changed,
			"fullRecordExact": var_to_bytes(record) == var_to_bytes(old)})
	return {"performed": true, "bindingValid": true, "path": path, "sha256": actual, "records": compared,
		"allGeometryIdentityExact": compared.all(func(row): return row.geometryIdentityExact),
		"qualification": "Historical pre-structural failed caller, prior to row packing and threshold fixes. This compares only curtain/civic producer records, not complete composition or physical facts."}

func _json(value: Variant) -> Variant:
	if value is Vector3: return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector2i or value is Vector2: return {"x": value.x, "y": value.y}
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size), "end": _json(value.end)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array:
		var result: Array = []
		for child: Variant in value: result.append(_json(child))
		return result
	return value
