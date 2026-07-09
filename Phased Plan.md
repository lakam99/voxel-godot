Phased Plan
Phase 1: Introduce the contract without changing behavior much.
Create NpcRouteAuthority and route result types. Wrap the current navmesh planner behind it. No movement code should treat generic pending as equivalent to blocked or unreachable.
Phase 2: Add audit-only collision probing.
For every route the current system accepts, run the new probe and record whether it would have passed. This gives hard evidence before flipping authority.
Phase 3: Make probing mandatory for ready.
A route can no longer become executable unless the full static collision probe passes. Generated-cell bridge routes and descriptor-direct shortcuts may remain only in diagnostics or synthetic tests.
Phase 4: Move tile readiness out of route planning.
Route planning should not opportunistically publish tiles and then half-accept the route. A nav-data service should say: ready, still loading, or unavailable. Missing tiles produce pending_nav_data, not unreachable_static.
Phase 5: Movement consumes only leases.
NpcRouteMovementController follows leases, keeps the old lease while replacement is pending, and reports real collisions back to the authority. Repeated live collision invalidates or repairs the lease.
Phase 6: Door, home, and forager proof.
Home routes must lease the door action, cross into strict interior space, clear threshold, and release the door. Foragers should request reachable roam routes outside town when no forage target is currently route-ready.
Phase 7: Delete the old ambiguity.
Once live acceptance passes, collapse or remove the old production authority paths in NpcRouteCoordinatorAdapter. Keep NpcPathing.gd as a facade only.