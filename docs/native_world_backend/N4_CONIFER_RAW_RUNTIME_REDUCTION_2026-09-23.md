# N4 conifer source-space runtime reduction shadow

`NativeConiferRawRuntimeReducer` ports the active
`TreeSpawnService.reduce_raw_runtime_recipe` source-space boundary for the
native raw conifer graph. It computes the same density/LOD render budgets,
retains order-zero wood plus graph-safe supporting ancestry, and retains the
first foliage anchor per represented segment before evenly selecting extras.
Its output is selected raw branches/foliage and source counts, **not** an
adapted worker recipe or scene artifact.

Eight independent direct-Godot cases from
`native/world_backend/tests/native_conifer_raw_runtime_reducer_oracle.gd`
match branch/foliage budgets, source counts, selected counts and complete
ordered selection hashes across ages, near/mid/far LOD and density. Review
caught an initial silent [0.2, 1] density clamp: the direct GDScript service
does not clamp, although its upstream normalized worker request normally does.
The clamp was removed; cases at -0.25, 0.10 and 2.00 now match Godot. The
native API rejects nonfinite/extreme values before unsafe integer conversion
and rejects non-ASCII tier text rather than mistranslating Godot Unicode
normalization. Synthetic malformed graph/foliage cases are unit coverage,
not live tree acceptance.

The focused C++ suite passes 3/3 with 113/113 lines, 10/10 functions and
98/98 branches covered. The aggregate
`artifacts/native-world-backend/n3-multipage-n4-conifer-reduction-01/report.json`
passes 473/473 debug and release tests, adapter smokes and strict 100%
pure-core coverage. Review found no remaining mismatch in this bounded
source-space contract after the density correction.

Production `TreeSpawnService` still normalizes requests, adapts geometry and
radii, applies a second render reduction/impostor policy, computes runtime
signatures and interaction facts, and publishes visuals separately from trunk
collision. Those steps need native ports and direct-service/visual/collision
evidence before N4 cutover. No tree script recipe or collider authority is
deleted here; N4 remains open.
