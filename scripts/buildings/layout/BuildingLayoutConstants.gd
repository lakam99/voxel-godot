extends RefCounted

## Captured visual-donor dimensions and layout policies; NOT runtime NPC policy.
## Donor NpcConstants.gd SHA256: AAF9BE8F62BE94576158275A4E14517575CC0DC13C2785CD3B2483FB9220B76B
## Keep these separate so restoring runtime NPC code cannot move furniture,
## entrances, terraces, or sampled clearance. Values and snap function unchanged.

const CELL_SIZE := 1.35
const ROUTINE_TARGET_SNAP_DISTANCE := CELL_SIZE * 1.65
const ROUTINE_START_SNAP_DISTANCE := CELL_SIZE * 3.1
const NAV_TILE_CELL_SIZE := 16
const DEFAULT_NPC_RADIUS := 0.42
const DEFAULT_NPC_STANDING_HEIGHT := 1.72
const DEFAULT_NPC_STEP_UP := 1.24
const DEFAULT_PERSONAL_SPACE_MARGIN := 0.10
const TRAFFIC_RETREAT_CLEARANCE := DEFAULT_NPC_RADIUS * 2.0 + DEFAULT_PERSONAL_SPACE_MARGIN
const NAVIGATION_TRANSITION_PHASE_RADIUS := 0.18


static func route_snap_distances(route_kind: String, arrival_radius: float, routine_snap_enabled := true) -> Dictionary:
	var target_snap := maxf(arrival_radius, CELL_SIZE * 0.95)
	var start_snap := target_snap
	if routine_snap_enabled and route_kind in ["guard", "work", "forage", "job", "idle", "move"]:
		target_snap = maxf(target_snap, ROUTINE_TARGET_SNAP_DISTANCE)
		start_snap = maxf(start_snap, ROUTINE_START_SNAP_DISTANCE)
	return {"start": start_snap, "target": target_snap}
