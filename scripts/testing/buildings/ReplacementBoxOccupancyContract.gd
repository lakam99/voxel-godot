extends SceneTree

## Synthetic scalar64 source-box algebra only; no publication/live acceptance.
const Occupancy = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
var _checks: Dictionary = {}
var _evidence: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_REPLACEMENT_BOX_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var unit: Array = [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
	var left: Array = [0.0, 0.0, 0.0, 0.5, 1.0, 1.0]
	var right: Array = [0.5, 0.0, 0.0, 1.0, 1.0, 1.0]
	_checks["public_valid_positive"] = Occupancy.valid(unit)
	_checks["coordinate_bound_inclusive"] = Occupancy.valid([-100000.0, 0.0, 0.0, 100000.0, 1.0, 1.0])
	_checks["intersection_exact"] = Occupancy.intersection(unit, left) == left
	_checks["intersection_touch_is_empty"] = Occupancy.intersection(left, right).is_empty()
	_checks["intersection_symmetric"] = Occupancy.intersection(unit, left) == Occupancy.intersection(left, unit)
	_cover("exact_union_shared_face", unit, [left, right], [])
	_cover("partial_exact_residual", unit, [left], [right])
	_cover("empty_solids", unit, [], [unit])
	_cover("touching_external_face", unit, [[1.0, 0.0, 0.0, 2.0, 1.0, 1.0]], [unit])
	_cover("touching_external_edge", unit, [[1.0, 1.0, 0.0, 2.0, 2.0, 1.0]], [unit])
	_cover("touching_external_corner", unit, [[1.0, 1.0, 1.0, 2.0, 2.0, 2.0]], [unit])
	_cover("overlapping_union", unit, [[0.0, 0.0, 0.0, 0.75, 1.0, 1.0], [0.25, 0.0, 0.0, 1.0, 1.0, 1.0]], [])
	_cover("containing_solid", unit, [[-1.0, -1.0, -1.0, 2.0, 2.0, 2.0]], [])
	# Keep these endpoints scalar64: Vector3/AABB would erase this gap.
	var gap_end: float = 0.5 + 1.0e-8
	var separated_right: Array = [gap_end, 0.0, 0.0, 1.0, 1.0, 1.0]
	var gap: Array = [0.5, 0.0, 0.0, gap_end, 1.0, 1.0]
	_checks["gap_is_positive_scalar64"] = gap_end > 0.5
	_cover("gap_1e_minus8_not_waived", unit, [left, separated_right], [gap])
	_removed("gap_difference_exact", [unit], [left, separated_right], [gap])
	_removed("original_minus_itself_empty", [unit], [unit], [])
	_removed("original_minus_empty_identity", [unit], [], [unit])
	_removed("empty_original", [], [unit], [])
	_removed("partial_retention", [unit], [left], [right])
	_removed("disjoint_retention_identity", [unit], [[2.0, 0.0, 0.0, 3.0, 1.0, 1.0]], [unit])
	_removed("split_original_retained_union_identity", [left, right], [unit], [])
	var islands: Array = [[0.0, 0.0, 0.0, 0.25, 1.0, 1.0], [0.75, 0.0, 0.0, 1.0, 1.0, 1.0]]
	_removed("two_original_islands_identity", islands, [], islands)
	var stripes: Array = [[0.25, 0.0, 0.0, 0.375, 1.0, 1.0], [0.625, 0.0, 0.0, 0.75, 1.0, 1.0]]
	var reversed: Array = stripes.duplicate(true)
	reversed.reverse()
	_checks["cover_order_reversal_exact"] = var_to_bytes(Occupancy.cover(unit, stripes)) == var_to_bytes(Occupancy.cover(unit, reversed))
	var reverse_islands: Array = islands.duplicate(true)
	reverse_islands.reverse()
	_checks["removed_both_orders_exact"] = var_to_bytes(Occupancy.removed(islands, stripes)) == var_to_bytes(Occupancy.removed(reverse_islands, reversed))
	_invalid_controls(unit)
	# Preserve scalar types and signed-zero encoding at the public boundary.
	var edge_boxes: Array = [[-100000, -0.0, 0, 100000.0, 1, 1.0],
		[0, 0.0, -0.0, 1, 1.0, 1], [1.0, 0, 0, 2, 1, 1],
		[-100000.0, -1, -1, -99999, 0.0, 0], [99999, 0, 0, 100000, 1, 1]]
	for a in edge_boxes:
		for b in edge_boxes:
			var expected: Array = []
			for axis in range(3): expected.append(maxf(a[axis], b[axis]))
			for axis in range(3): expected.append(minf(a[axis + 3], b[axis + 3]))
			if not Occupancy.valid(expected): expected = []
			_checks["endpoint_encoding_%d_%d" % [edge_boxes.find(a), edge_boxes.find(b)]] = var_to_bytes(Occupancy.intersection(a,b)) == var_to_bytes(expected)
	var work := {"steps": Occupancy.MAX_WORK - 1}
	var limited := Occupancy._difference([unit], [[2,0,0,3,1,1],[3,0,0,4,1,1]], work)
	_checks["exact_work_boundary"] = limited.get("reason") == "work_limit" and work.steps == Occupancy.MAX_WORK
	_checks["declared_cell_cap"] = Occupancy.MAX_CELLS == 4096
	var too_many: Array = []
	for index in range(4097): too_many.append(unit.duplicate())
	_rejected("cover_source_limit", Occupancy.cover(unit, too_many), "uncovered")
	_rejected("removed_original_limit", Occupancy.removed(too_many, []), "cells")
	_rejected("removed_retained_limit", Occupancy.removed([unit], too_many), "cells")
	# 51 positive slab cuts leave 18^3=5832 disjoint cells: bounded input,
	# deliberately above the output cap. No large stress workload or cap bypass.
	var domain: Array = [0.0, 0.0, 0.0, 36.0, 36.0, 36.0]
	var slabs: Array = []
	for axis in range(3):
		for index in range(17):
			var slab: Array = domain.duplicate()
			slab[axis] = float(index * 2 + 1)
			slab[axis + 3] = float(index * 2 + 2)
			slabs.append(slab)
	_rejected("cover_fragment_limit", Occupancy.cover(domain, slabs), "uncovered")
	_rejected("removed_fragment_limit", Occupancy.removed([domain], slabs), "cells")
	_prepared_controls(unit,edge_boxes,domain,slabs,too_many)
	_finish(path)

func _cover(name: String, region: Array, solids: Array, expected: Array) -> void:
	var frozen: PackedByteArray = var_to_bytes([region, solids])
	var result: Dictionary = Occupancy.cover(region, solids)
	_checks[name] = result.get("ready", false) and result.get("covered") == expected.is_empty() and _cells_exact(result.get("uncovered"), expected)
	_checks[name + "_immutable"] = frozen == var_to_bytes([region, solids])
	_checks[name + "_repeat"] = var_to_bytes(result) == var_to_bytes(Occupancy.cover(region, solids))
	var prepared = Occupancy.prepare_solids(solids)
	_checks[name + "_prepared_exact"] = prepared != null and var_to_bytes(result) == var_to_bytes(Occupancy.cover_prepared(region,prepared))
	_checks[name + "_prepared_repeat_exact"] = prepared != null and var_to_bytes(result) == var_to_bytes(Occupancy.cover_prepared(region,prepared)) \
		and frozen == var_to_bytes([region,solids])
	_evidence[name] = result

func _prepared_controls(unit: Array, edge_boxes: Array, domain: Array, slabs: Array, too_many: Array) -> void:
	# Reuse the actual immutable owner artifact across different scalar queries;
	# all complete output dictionaries, including work and ordered cells, match.
	var integer_box: Array[int] = [0,0,0,1,1,1]
	var float_box: Array[float] = [-0.0,0.0,0.0,1.0,1.0,1.0]
	var mixed: Array = [float_box,integer_box,edge_boxes[0].duplicate()]
	var frozen: PackedByteArray = var_to_bytes(mixed)
	var prepared = Occupancy.prepare_solids(mixed)
	_checks["prepared_source_types_signed_zero_and_order_preserved"] = prepared != null \
		and var_to_bytes(prepared._solids)==var_to_bytes(Occupancy._sorted(mixed)) and frozen==var_to_bytes(mixed)
	_checks["prepared_nested_values_are_frozen_owned_copies"] = prepared != null and prepared._solids.is_read_only() \
		and prepared._solids.all(func(box): return box.is_read_only() and not mixed.any(func(source): return is_same(box,source)))
	for index in range(edge_boxes.size()):
		_checks["prepared_mixed_endpoint_query_%d" % index] = var_to_bytes(Occupancy.cover(edge_boxes[index],mixed)) \
			==var_to_bytes(Occupancy.cover_prepared(edge_boxes[index],prepared))
	var source: Array = [[0.0,0.0,0.0,0.5,1.0,1.0]]
	var original: Dictionary = Occupancy.cover(unit,source)
	var retained = Occupancy.prepare_solids(source)
	source[0][3] = 1.0
	source.append([2,0,0,3,1,1])
	source.reverse()
	_checks["prepared_isolated_from_nested_and_outer_caller_mutation"] = var_to_bytes(original)==var_to_bytes(Occupancy.cover_prepared(unit,retained)) \
		and var_to_bytes(original)!=var_to_bytes(Occupancy.cover(unit,source))
	var changed_result: Dictionary = Occupancy.cover_prepared(unit,retained)
	changed_result.uncovered[0][0] = -7.0
	changed_result.uncovered.append(unit.duplicate())
	_checks["prepared_result_mutation_cannot_change_next_query"] = var_to_bytes(original)==var_to_bytes(Occupancy.cover_prepared(unit,retained))
	var new_prepared = Occupancy.prepare_solids(source)
	_checks["prepared_new_owner_uses_current_source"] = var_to_bytes(Occupancy.cover(unit,source))==var_to_bytes(Occupancy.cover_prepared(unit,new_prepared))
	var unsealed := Occupancy.PreparedSolids.new()
	var tampered = Occupancy.prepare_solids(source)
	tampered._solids = []
	var invalid: Dictionary = Occupancy.cover(unit,[null])
	_checks["prepared_unsealed_and_rebound_artifacts_rejected"] = var_to_bytes(Occupancy.cover_prepared(unit,unsealed))==var_to_bytes(invalid) \
		and var_to_bytes(Occupancy.cover_prepared(unit,tampered))==var_to_bytes(invalid) \
		and var_to_bytes(Occupancy.cover_prepared(unit,{"ready":true,"solids":source}))==var_to_bytes(invalid)
	_checks["prepared_source_cap_exact"] = Occupancy.prepare_solids(too_many)==null \
		and var_to_bytes(Occupancy.cover(unit,too_many))==var_to_bytes(Occupancy.cover_prepared(unit,Occupancy.prepare_solids(too_many)))
	_checks["prepared_fragment_failure_exact"] = var_to_bytes(Occupancy.cover(domain,slabs)) \
		==var_to_bytes(Occupancy.cover_prepared(domain,Occupancy.prepare_solids(slabs)))
	_evidence["preparedScope"] = "Only sorted immutable solids are reused. Region subtraction, work counters, output ordering and all original limits run afresh for every query; this is not a spatial filter or a cross-source cache."

func _removed(name: String, original: Array, retained: Array, expected: Array) -> void:
	var frozen: PackedByteArray = var_to_bytes([original, retained])
	var result: Dictionary = Occupancy.removed(original, retained)
	_checks[name] = result.get("ready", false) and _cells_exact(result.get("cells"), expected)
	_checks[name + "_immutable"] = frozen == var_to_bytes([original, retained])
	_checks[name + "_repeat"] = var_to_bytes(result) == var_to_bytes(Occupancy.removed(original, retained))
	_evidence[name] = result

func _cells_exact(value: Variant, expected: Array) -> bool:
	if not value is Array or value.size() != expected.size() or value.size() > 4096: return false
	var unmatched: Array = expected.duplicate(true)
	for cell: Variant in value:
		if not cell is Array or cell.size() != 6: return false
		for axis in range(3):
			if not (cell[axis] is float or cell[axis] is int) or not (cell[axis + 3] is float or cell[axis + 3] is int): return false
			if not is_finite(cell[axis]) or not is_finite(cell[axis + 3]) or cell[axis] >= cell[axis + 3]: return false
		var index: int = unmatched.find(cell)
		if index < 0: return false
		unmatched.remove_at(index)
	return unmatched.is_empty()

func _invalid_controls(unit: Array) -> void:
	var invalid: Array = [[], [0.0], [0.0, 0.0, 0.0, 0.0, 1.0, 1.0], [1.0, 0.0, 0.0, 0.0, 1.0, 1.0],
		[0.0, 0.0, 0.0, INF, 1.0, 1.0], [NAN, 0.0, 0.0, 1.0, 1.0, 1.0], ["0", 0.0, 0.0, 1.0, 1.0, 1.0],
		[false, 0.0, 0.0, 1.0, 1.0, 1.0], [0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 2.0],
		[-100000.000001, 0.0, 0.0, 1.0, 1.0, 1.0], [0.0, 0.0, 0.0, 100000.000001, 1.0, 1.0]]
	for index in range(invalid.size()):
		var box: Array = invalid[index]
		var frozen: PackedByteArray = var_to_bytes(box)
		_checks["public_valid_rejects_%d" % index] = not Occupancy.valid(box)
		_checks["intersection_invalid_rejects_%d" % index] = Occupancy.intersection(unit, box).is_empty() and Occupancy.intersection(box, unit).is_empty()
		_rejected("invalid_region_%d" % index, Occupancy.cover(box, [unit]), "uncovered")
		_rejected("invalid_solid_even_after_cover_%d" % index, Occupancy.cover(unit, [unit, box]), "uncovered")
		_checks["prepared_invalid_region_exact_%d" % index] = var_to_bytes(Occupancy.cover(box,[unit])) \
			==var_to_bytes(Occupancy.cover_prepared(box,Occupancy.prepare_solids([unit])))
		_checks["prepared_invalid_solid_even_after_cover_exact_%d" % index] = Occupancy.prepare_solids([unit,box])==null \
			and var_to_bytes(Occupancy.cover(unit,[unit,box]))==var_to_bytes(Occupancy.cover_prepared(unit,Occupancy.prepare_solids([unit,box])))
		_rejected("invalid_original_%d" % index, Occupancy.removed([box], []), "cells")
		_rejected("invalid_retained_even_empty_original_%d" % index, Occupancy.removed([], [box]), "cells")
		_checks["invalid_input_immutable_%d" % index] = frozen == var_to_bytes(box)
	_rejected("nonarray_solid", Occupancy.cover(unit, [null]), "uncovered")
	_rejected("nonarray_original", Occupancy.removed(["not_box"], []), "cells")

func _rejected(name: String, result: Dictionary, cells_key: String) -> void:
	_checks[name] = result.get("ready") == false and not String(result.get("reason", "")).is_empty() and result.get(cells_key, []).is_empty() and not result.get("covered", false)
	_evidence[name] = {"ready": result.get("ready"), "reason": result.get("reason"), "returnedCells": result.get(cells_key, []).size()}

func _finish(path: String) -> void:
	var passed: bool = not _checks.is_empty() and _checks.values().all(func(v): return v == true)
	var report: Dictionary = {"passed": passed, "evidenceLevel": "synthetic_source_scalar64_box_algebra_only", "checks": _checks, "results": _evidence,
		"limitations": "Pure helper controls only. No actual house, collision publication, rendered geometry, GPU, navigation or live gameplay proof; no tolerance added to any comparison."}
	var bytes: PackedByteArray = JSON.stringify(report, "  ").to_utf8_buffer()
	if FileAccess.file_exists(path) or bytes.size() > 1024 * 1024:
		quit(2)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_length() == bytes.size()
	file.close()
	var hash_context := HashingContext.new()
	written = written and hash_context.start(HashingContext.HASH_SHA256) == OK
	if written:
		written = hash_context.update(bytes) == OK
		if written: written = FileAccess.get_sha256(path) == hash_context.finish().hex_encode()
	quit(0 if passed and written else 2)
