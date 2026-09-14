extends RefCounted

## Exact scalar interval accounting for axis-aligned replacement solids.
## A covered intersection means old occupancy was retained, never that the
## intersection is clear or that it provides a structural bearing.
const MAX_CELLS := 4096
const MAX_WORK := 250000

# Only this owner's factory binds a validated, sorted, privately copied list.
# Both levels are frozen; a replaced member array invalidates the binding.
class PreparedSolids extends RefCounted:
	var _solids: Array = []
	var _bound_solids: Array = []
	func valid_binding() -> bool:
		return _solids.is_read_only() and is_same(_solids,_bound_solids)

static func cover(region: Array, solids: Array) -> Dictionary:
	if not valid(region) or not _valid_list(solids): return _fail("invalid_box_input")
	return _cover_sorted(region,_sorted(solids))

static func prepare_solids(solids: Array) -> PreparedSolids:
	if not _valid_list(solids): return null
	var sorted: Array = _sorted(solids)
	for box: Array in sorted: box.make_read_only()
	sorted.make_read_only()
	var prepared := PreparedSolids.new()
	prepared._solids = sorted
	prepared._bound_solids = sorted
	return prepared

static func cover_prepared(region: Array, prepared) -> Dictionary:
	if not valid(region) or not prepared is PreparedSolids or not prepared.valid_binding(): return _fail("invalid_box_input")
	return _cover_sorted(region,prepared._solids)

static func _cover_sorted(region: Array, sorted_solids: Array) -> Dictionary:
	var work := {"steps": 0}
	var result := _difference([region.duplicate()], sorted_solids, work)
	if not result.ready: return result
	return {"ready": true, "covered": result.cells.is_empty(), "uncovered": _sorted(result.cells), "work": work.steps, "reason": ""}

static func removed(original: Array, retained: Array) -> Dictionary:
	if not _valid_list(original) or not _valid_list(retained): return _fail("invalid_box_input")
	var work := {"steps": 0}
	var union: Array = []
	for box: Array in _sorted(original):
		var fresh := _difference([box.duplicate()], union, work)
		if not fresh.ready: return fresh
		union.append_array(fresh.cells)
		if union.size() > MAX_CELLS: return _fail("cell_limit")
	var result := _difference(union, _sorted(retained), work)
	if not result.ready: return result
	return {"ready": true, "cells": _sorted(result.cells), "work": work.steps, "reason": ""}

static func valid(box: Variant) -> bool:
	if not box is Array or box.size() != 6: return false
	for value: Variant in box:
		if not (value is float or value is int) or not is_finite(float(value)) or absf(float(value)) > 100000.0: return false
	for axis in range(3):
		if box[axis] >= box[axis + 3]: return false
	return true

static func intersection(first: Array, second: Array) -> Array:
	if not valid(first) or not valid(second): return []
	return _intersection_validated(first, second)

# Internal subtraction starts with validated boxes. Min/max and strict splits
# preserve finite, bounded endpoints; do not revalidate every unchanged pair.
static func _intersection_validated(first: Array, second: Array) -> Array:
	var result: Array = []
	for axis in range(3):
		var low := maxf(first[axis], second[axis])
		if low >= minf(first[axis + 3], second[axis + 3]): return []
		result.append(low)
	for axis in range(3): result.append(minf(first[axis + 3], second[axis + 3]))
	return result

static func _valid_list(boxes: Array) -> bool:
	return boxes.size() <= MAX_CELLS and boxes.all(func(box): return valid(box))

static func _sorted(boxes: Array) -> Array:
	var result := boxes.duplicate(true)
	result.sort_custom(func(a, b):
		for index in range(6):
			if a[index] != b[index]: return a[index] < b[index]
		return false)
	return result

static func _difference(regions: Array, solids: Array, work: Dictionary) -> Dictionary:
	var cells: Array = regions.duplicate(true)
	for solid: Array in solids:
		var next: Array = []
		for cell: Array in cells:
			if work.steps >= MAX_WORK: return _fail("work_limit")
			work.steps += 1
			var overlap := _intersection_validated(cell, solid)
			if overlap.is_empty():
				next.append(cell)
			else:
				var remainder := cell.duplicate()
				for axis in range(3):
					if overlap[axis] > remainder[axis]:
						var low := remainder.duplicate()
						low[axis + 3] = overlap[axis]
						next.append(low)
						remainder[axis] = overlap[axis]
					if overlap[axis + 3] < remainder[axis + 3]:
						var high := remainder.duplicate()
						high[axis] = overlap[axis + 3]
						next.append(high)
						remainder[axis + 3] = overlap[axis + 3]
			if next.size() > MAX_CELLS: return _fail("cell_limit")
		cells = next
		if cells.is_empty(): break
	return {"ready": true, "cells": cells}

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "covered": false, "reason": reason}
