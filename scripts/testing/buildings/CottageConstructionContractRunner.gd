extends SceneTree

## Focused VOX-207 contract/benchmark. This is deliberately a construction
## authority test: it proves that both styles replay the same material-aware
## blueprint into their physical and visual parts. It does not claim live-town
## or player interaction coverage.

const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")

const SEED := 207154
const BENCHMARK_SAMPLES := 16

var report_path := ""
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_COTTAGE_CONSTRUCTION_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/cottage-construction-contract.json")

	var styles: Array[Dictionary] = []
	for style in ["timber", "masonry"]:
		styles.append(verify_style(style))
	var benchmark := benchmark_publication()
	var passed := failures.is_empty()
	var report := {
		"runnerId": "cottage_construction_contract",
		"evidenceLevel": "contract+headless-microbenchmark",
		"scope": "Deterministic cottage blueprint replay plus publication from the same BuildingPart records. The timing rows measure isolated fixture build/publication work and do not prove live town streaming frame pacing.",
		"passed": passed,
		"seed": SEED,
		"styles": styles,
		"benchmark": benchmark,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if passed else 1)


func verify_style(style: String) -> Dictionary:
	var source = CottageBlueprintBuilderScript.build(SEED, style)
	var replay = CottageBlueprintBuilderScript.build(SEED, style)
	var different_seed = CottageBlueprintBuilderScript.build(SEED + 1, style)
	var deterministic: bool = source.deterministic_signature() == replay.deterministic_signature()
	var seed_sensitive: bool = source.deterministic_signature() != different_seed.deterministic_signature()
	check(deterministic, "%s blueprint failed deterministic replay" % style)
	check(seed_sensitive, "%s blueprint did not encode its seeded identity" % style)
	var source_validation := validate_source_parts(source, style)
	var fixture := Node3D.new()
	get_root().add_child(fixture)
	var publisher = BuildingPartPublisherScript.new()
	var publication: Dictionary = publisher.publish(source, fixture)
	var publication_validation := validate_publication(source, fixture, publication, style)
	fixture.free()
	return {
		"style": style,
		"signature": source.deterministic_signature().hash(),
		"partCount": source.parts.size(),
		"deterministicReplay": deterministic,
		"seedSensitive": seed_sensitive,
		"source": source_validation,
		"publication": publication,
		"publicationValidation": publication_validation
	}


func validate_source_parts(blueprint, style: String) -> Dictionary:
	var ids := {}
	var expected_collision_count := 0
	var door_found := false
	var entry_ramp_found := false
	var split_front_foundation_parts := 0
	var window_count := 0
	var window_parts: Array = []
	var brick_wall_count := 0
	for part in blueprint.parts:
		check(part != null, "%s blueprint contains a null part" % style)
		if part == null:
			continue
		check(not ids.has(part.id), "%s blueprint repeats part id %s" % [style, part.id])
		ids[part.id] = true
		check(part.size.x > 0.0 and part.size.y > 0.0 and part.size.z > 0.0, "%s part %s has invalid occupied volume" % [style, part.id])
		if part.collision_enabled:
			expected_collision_count += 1
		if part.semantic == "door":
			door_found = true
			check(part.material_id == "painted_door", "%s door does not retain its distinct material" % style)
			check(part.collision_enabled, "%s door lost its physical construction volume" % style)
		if part.semantic == "entry_ramp":
			entry_ramp_found = true
			check(part.collision_enabled, "%s entry ramp lost its physical construction volume" % style)
			check(part.kind == "ramp", "%s entry ramp was no longer published as a ramp part" % style)
		if String(part.id) in ["foundation_front_left", "foundation_front_right"]:
			split_front_foundation_parts += 1
		if part.semantic == "window":
			window_count += 1
			window_parts.append(part)
			check(part.collision_enabled, "%s window lost its physical glass volume" % style)
		if part.kind == "wall" and part.material_id == "fired_brick":
			brick_wall_count += 1
	check(door_found, "%s blueprint has no semantic door part" % style)
	check(entry_ramp_found, "%s blueprint has no physical entry ramp" % style)
	check(split_front_foundation_parts == 2, "%s blueprint does not split the front foundation around its doorway" % style)
	check(not ids.has("foundation_front"), "%s blueprint restored a solid foundation through the doorway" % style)
	check(window_count >= 3, "%s blueprint does not expose its window parts" % style)
	for window in window_parts:
		var window_bounds := part_bounds(window)
		for wall in blueprint.parts:
			if wall == null or wall.kind != "wall":
				continue
			check(not positive_volume_overlap(window_bounds, part_bounds(wall)), "%s wall %s still fills the opening for window %s" % [style, String(wall.id), String(window.id)])
	if style == "masonry":
		check(brick_wall_count > 0, "masonry blueprint has no brick wall parts")
	else:
		check(brick_wall_count == 0, "timber blueprint unexpectedly uses brick wall parts")
	return {
		"uniquePartIds": ids.size(),
		"expectedCollisionParts": expected_collision_count,
		"entryRamp": entry_ramp_found,
		"splitFrontFoundationParts": split_front_foundation_parts,
		"windowParts": window_count,
		"brickWallParts": brick_wall_count
	}


func validate_publication(blueprint, fixture: Node3D, publication: Dictionary, style: String) -> Dictionary:
	var bodies := {}
	for child in fixture.get_children():
		if child is StaticBody3D:
			var body := child as StaticBody3D
			bodies[String(body.get_meta("building_part_id", ""))] = body
	check(int(publication.get("publishedPartCount", -1)) == blueprint.parts.size(), "%s publisher omitted a source part" % style)
	check(bodies.size() == blueprint.parts.size(), "%s scene has a body count that differs from its source records" % style)
	var expected_collision_count := 0
	for part in blueprint.parts:
		if part == null:
			continue
		var body: StaticBody3D = bodies.get(part.id, null) as StaticBody3D
		check(body != null, "%s source part %s has no published body" % [style, part.id])
		if body == null:
			continue
		check(String(body.get_meta("building_material", "")) == part.material_id, "%s part %s changed material during publication" % [style, part.id])
		check(String(body.get_meta("building_semantic", "")) == part.semantic, "%s part %s changed semantic during publication" % [style, part.id])
		var collision_shapes := collision_shape_count(body)
		if part.collision_enabled:
			expected_collision_count += 1
			check(collision_shapes == 1, "%s physical part %s lost or duplicated collision" % [style, part.id])
		else:
			check(collision_shapes == 0, "%s non-physical part %s gained collision" % [style, part.id])
		check(body.get_child_count() > collision_shapes, "%s part %s has no visual publication" % [style, part.id])
	check(int(publication.get("collisionPartCount", -1)) == expected_collision_count, "%s collision summary diverges from source records" % style)
	var door: StaticBody3D = bodies.get("front_door", null) as StaticBody3D
	check(door != null and door.find_child("DoorFrameLeft", true, false) != null and door.find_child("DoorHandle", true, false) != null, "%s door lost its readable frame or handle" % style)
	check(door != null and door.find_child("DoorPivot", false, false) != null, "%s door lost the shared controller pivot" % style)
	check(door != null and door.find_child("DoorInteraction", false, false) != null, "%s door lost its interaction proxy" % style)
	check(door != null and String(door.get_meta("door_portal_id", "")) != "", "%s door lost its shared portal identity" % style)
	if style == "masonry":
		for part in blueprint.parts:
			if part == null or part.kind != "wall" or part.material_id != "fired_brick":
				continue
			var wall_body: StaticBody3D = bodies.get(part.id, null) as StaticBody3D
			var mortar: MeshInstance3D = wall_body.find_child("MortarBed", true, false) as MeshInstance3D if wall_body != null else null
			check(mortar != null, "masonry part %s has no mortar bed" % part.id)
			if mortar == null:
				continue
			var thin_axis_is_z: bool = part.size.x >= part.size.z
			var mortar_depth: float = mortar.scale.z if thin_axis_is_z else mortar.scale.x
			var wall_depth: float = part.size.z if thin_axis_is_z else part.size.x
			check(mortar_depth < wall_depth, "masonry part %s has coplanar mortar and brick faces" % part.id)
	return {
		"publishedBodyCount": bodies.size(),
		"expectedCollisionParts": expected_collision_count,
		"visualBatchCount": int(publication.get("visualBatchCount", 0))
	}


func benchmark_publication() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for style in ["timber", "masonry"]:
		var blueprint_samples: Array[int] = []
		var publication_samples: Array[int] = []
		var visual_recipe_samples: Array[int] = []
		var visual_batches: Array[int] = []
		for index in range(BENCHMARK_SAMPLES):
			var started := Time.get_ticks_usec()
			var blueprint = CottageBlueprintBuilderScript.build(SEED + index, style)
			blueprint_samples.append(Time.get_ticks_usec() - started)
			var fixture := Node3D.new()
			var publisher = BuildingPartPublisherScript.new()
			var publication: Dictionary = publisher.publish(blueprint, fixture)
			publication_samples.append(int(publication.get("publicationUsec", 0)))
			visual_recipe_samples.append(int(publication.get("recipeBuildUsec", 0)))
			visual_batches.append(int(publication.get("visualBatchCount", 0)))
			fixture.free()
		rows.append({
			"style": style,
			"sampleCount": BENCHMARK_SAMPLES,
			"blueprintBuildTimingUsec": timing_stats(blueprint_samples),
			"partPublicationTimingUsec": timing_stats(publication_samples),
			"visualRecipeTimingUsec": timing_stats(visual_recipe_samples),
			"visualBatchCounts": visual_batches
		})
	return rows


func collision_shape_count(body: StaticBody3D) -> int:
	var count := 0
	for child in body.get_children():
		if child is CollisionShape3D:
			count += 1
	return count


func part_bounds(part) -> AABB:
	return AABB(part.position - part.size * 0.5, part.size)


func positive_volume_overlap(first: AABB, second: AABB) -> bool:
	# Construction pieces may share a jamb/header edge exactly. Only overlapping
	# volume means a wall has incorrectly survived inside a window aperture.
	var epsilon := 0.0001
	return first.position.x < second.end.x - epsilon and first.end.x > second.position.x + epsilon and first.position.y < second.end.y - epsilon and first.end.y > second.position.y + epsilon and first.position.z < second.end.z - epsilon and first.end.z > second.position.z + epsilon


func timing_stats(raw: Array[int]) -> Dictionary:
	var samples: Array[int] = raw.duplicate()
	samples.sort()
	var total := 0
	for sample in samples:
		total += sample
	return {
		"averageUsec": float(total) / float(maxi(1, samples.size())),
		"p50Usec": percentile(samples, 0.50),
		"p95Usec": percentile(samples, 0.95),
		"maxUsec": samples.back() if not samples.is_empty() else 0
	}


func percentile(samples: Array[int], fraction: float) -> int:
	if samples.is_empty():
		return 0
	return samples[clampi(ceili(float(samples.size()) * fraction) - 1, 0, samples.size() - 1)]


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
