extends RefCounted

## Source-only geometry observation. It cannot authorize production clearance.
const MAX_FRAGMENTS := 4096

static func covers(footprint: Rect2, rectangles: Array[Rect2], continuation: Callable) -> Dictionary:
	var remaining: Array[Rect2]=[footprint]
	for support: Rect2 in rectangles:
		var next: Array[Rect2]=[]
		for region: Rect2 in remaining:
			if continuation.is_valid() and not bool(continuation.call("courtyard_coverage_probe")): return {"ready":false,"reason":"cancelled"}
			var cut := region.intersection(support)
			if not cut.has_area():
				next.append(region)
			else:
				for fragment: Rect2 in [Rect2(region.position,Vector2(cut.position.x-region.position.x,region.size.y)),Rect2(Vector2(cut.end.x,region.position.y),Vector2(region.end.x-cut.end.x,region.size.y)),Rect2(Vector2(cut.position.x,region.position.y),Vector2(cut.size.x,cut.position.y-region.position.y)),Rect2(Vector2(cut.position.x,cut.end.y),Vector2(cut.size.x,region.end.y-cut.end.y))]:
					if fragment.has_area(): next.append(fragment)
			if next.size()>MAX_FRAGMENTS: return {"ready":false,"reason":"courtyard_support_coverage_limit"}
		remaining=next
		if remaining.is_empty(): return {"ready":true}
	return {"ready":false,"reason":"courtyard_support_coverage_gap","uncovered":remaining}
