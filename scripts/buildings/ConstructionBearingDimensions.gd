extends RefCounted

## Shared construction dimensions, not tolerances or structural-proof waivers.
const LOWER_BEARING_HEIGHT := 0.24
const LOWER_CORBEL_SOCKET_HALF := Vector3(0.07, 0.04, 0.07)
const CONNECTION_PADDING := 0.02
const GRAVITY_PATCH_MAX_HALF := 0.06
const GRAVITY_PATCH_EDGE_INSET := 0.06

static func gravity_patch_half(size: Vector3) -> Vector2:
	return Vector2(minf(GRAVITY_PATCH_MAX_HALF, size.x * 0.5 - GRAVITY_PATCH_EDGE_INSET),
		minf(GRAVITY_PATCH_MAX_HALF, size.z * 0.5 - GRAVITY_PATCH_EDGE_INSET))
