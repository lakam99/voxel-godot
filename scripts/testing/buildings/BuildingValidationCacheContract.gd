extends SceneTree

## Synthetic cache contract only. Main must also compare the frozen full handoff
## against the original git script and profile the real shared source.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
class Uncached extends "res://scripts/buildings/BuildingBlueprint.gd":
	func _begin_validation_cache() -> bool: return false
class Observed extends "res://scripts/buildings/BuildingBlueprint.gd":
	var nested_cache_preserved := false
	func resolve_physical_contracts() -> void:
		var nested := _validation_cache_active
		super.resolve_physical_contracts()
		nested_cache_preserved = nested and _validation_cache_active and not _validation_transforms.is_empty()
var checks: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var cached = _fixture(Observed.new())
	var uncached = _fixture(Uncached.new())
	_compare("initial", cached, uncached)
	checks["nested_resolve_preserves_validate_cache"] = cached.nested_cache_preserved
	checks["ordinary_fixture_passes"] = cached.validate_physical_integrity().passed
	checks["all_original_samples_retained"] = cached.parts[1].recipe.physicalSupportCoverage.size() == 9 and cached.parts[2].recipe.physicalSupportCoverage.size() == 25
	for b in [cached, uncached]:
		b.parts[0].position += Vector3(0.3, 0.2, -0.1)
		b.parts[0].rotation = Vector3(0.1, 0.2, 0.3)
		b.parts[0].size = Vector3(10, 1.2, 11)
	var changed = cached.parts[0]
	var transform := Transform3D(Basis.from_euler(changed.rotation), changed.position)
	checks["direct_mutation_after_pass_is_fresh"] = cached.part_transform(changed) == transform and cached.part_inverse_transform(changed) == transform.affine_inverse() and cached.transformed_part_bounds(changed) == uncached.transformed_part_bounds(uncached.parts[0]) and _clean(cached)
	for stage in ["move", "rotate_resize", "collision", "duplicate_id", "cycle", "remove"]:
		for b in [cached, uncached]:
			match stage:
				"move": b.parts[1].position.x += 16.0
				"rotate_resize":
					b.parts[1].rotation = Vector3(0.17, -0.43, 0.08)
					b.parts[1].size = Vector3(1.7, 0.4, 2.1)
				"collision": b.parts[0].collision_enabled = false
				"duplicate_id": b.add_part({"id": "root", "position": Vector3(-12, 4, -12), "size": Vector3.ONE, "kind": "beam"})
				"cycle":
					b.parts[1].recipe["physicalRequiredSeatPartIds"] = ["mass"]
					b.parts[2].recipe["physicalRequiredSeatPartIds"] = ["floor"]
				"remove": b.parts.remove_at(0)
		_compare(stage, cached, uncached)
		var p = cached.parts[0]
		checks[stage + "_direct_transform_fresh"] = cached.part_transform(p) == Transform3D(Basis.from_euler(p.rotation), p.position)
		checks[stage + "_direct_inverse_fresh"] = cached.part_inverse_transform(p) == Transform3D(Basis.from_euler(p.rotation), p.position).affine_inverse()
		checks[stage + "_direct_bounds_fresh"] = cached.transformed_part_bounds(p) == uncached.transformed_part_bounds(uncached.parts[0])
		cached.resolve_physical_contracts()
		uncached.resolve_physical_contracts()
		checks[stage + "_direct_resolve_exact_clean"] = var_to_bytes(cached.snapshot()) == var_to_bytes(uncached.snapshot()) and _clean(cached)
		_compare(stage + "_repeat", cached, uncached)
	_neighbor_contract()
	var passed := checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": checks, "scope": "synthetic_same_proofs_cache_on_off_not_independent_old_script_or_full_source_acceptance"}
	var encoded := JSON.stringify(report, "\t")
	print(encoded)
	var path := OS.get_environment("VOXEL_BUILDING_VALIDATION_CACHE_REPORT")
	if not path.is_empty():
		if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()): quit(2); return
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null: quit(2); return
		file.store_string(encoded); file.flush()
		var ok := file.get_error() == OK
		file.close()
		if not ok: quit(2); return
	quit(0 if passed else 1)

func _fixture(b):
	b.add_part({"id": "root", "kind": "foundation", "position": Vector3(-4, 0.5, -4), "size": Vector3(12, 1, 12)})
	b.add_part({"id": "floor", "kind": "floor", "position": Vector3(-4, 1.1, -4), "size": Vector3(4, 0.2, 4)})
	b.add_part({"id": "mass", "kind": "beam", "position": Vector3(-4, 1.7, -4), "size": Vector3(1, 1, 1)})
	b.add_part({"id": "trim", "kind": "beam", "position": Vector3(-4, 1.7, -4), "size": Vector3(0.2, 0.4, 0.2), "rotation": Vector3(0.2, 0.4, 0.1), "collision": false})
	b.parts.append(null)
	return b

func _compare(label: String, cached, uncached) -> void:
	checks[label + "_checks_exact"] = var_to_bytes(cached.validate_physical_integrity()) == var_to_bytes(uncached.validate_physical_integrity())
	checks[label + "_snapshot_exact"] = var_to_bytes(cached.snapshot()) == var_to_bytes(uncached.snapshot())
	checks[label + "_cache_released"] = _clean(cached) and _clean(uncached)

func _clean(b) -> bool:
	return not b._validation_cache_active and b._validation_transforms.is_empty() and b._validation_inverses.is_empty() and b._validation_bounds.is_empty() and b._validation_neighbors.is_empty()

func _neighbor_contract() -> void:
	var b = _fixture(Blueprint.new())
	b.resolve_physical_contracts()
	var points := [Vector3(-4.01, 0, -4.01), Vector3(-4, 0, -4), Vector3(-0.01, 9, -0.01), Vector3.ZERO]
	var expected: Array = points.map(func(point): return b.structural_candidates_near(point))
	var owner: bool = b._begin_validation_cache()
	b.resolve_physical_contracts()
	checks["direct_nested_resolve_keeps_owner"] = b._validation_cache_active
	for i in range(points.size()):
		var actual: Array = b.structural_candidates_near(points[i])
		checks["neighbor_%d_order_dedup_exact" % i] = actual == expected[i] and b.structural_candidates_near(points[i]) == expected[i]
	checks["neighbor_cache_reuses_negative_grid_cell"] = b._validation_neighbors.has(Vector2i(-1, -1))
	var same_id = b.add_part({"id": "root", "position": Vector3(30, 2, 30), "rotation": Vector3(0.1, 0.2, 0.3), "size": Vector3(2, 3, 4)})
	checks["geometry_keys_are_objects_not_ids"] = b.part_transform(same_id) != b.part_transform(b.parts[0]) and b.transformed_part_bounds(same_id) != b.transformed_part_bounds(b.parts[0])
	b._end_validation_cache(owner)
	checks["explicit_owner_releases_every_cache"] = _clean(b)
