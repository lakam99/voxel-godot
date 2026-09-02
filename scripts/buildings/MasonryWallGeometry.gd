extends RefCounted

## Shared existing masonry-core geometry. Decorative brick courses surround
## this bed; structural recipes must not assume the gap behind them is solid.
static func bed_size(size: Vector3) -> Vector3:
	var bed := size
	bed.x = maxf(0.02, size.x - minf(0.16, size.x * 0.30))
	bed.z = maxf(0.02, size.z - minf(0.16, size.z * 0.30))
	return bed
