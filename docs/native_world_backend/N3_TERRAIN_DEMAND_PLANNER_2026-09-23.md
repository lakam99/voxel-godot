# N3 terrain demand planner checkpoint

`NativeTerrainDemandPlanner.gd` is a pure composed planner for the next N3
production seam. It does not install terrain or change `VoxelTerrainRuntime`.
It accepts the primary viewer, named startup/secondary/handoff/retained
viewers, retained gameplay chunks, foreground gameplay chunks, and current
vertical bounds. Source identities are stable (`viewer:<kind>:<id>` and
`chunk:<kind>:<x>:<z>`), but their one reference-counted data-block union is
owned by a **single** stable native publisher consumer ID. This avoids multiple
publishers racing the backend's one shared prepared-result pump.

The planner converts world positions through the production 1.35 m cell
scale, 16-cell mesh grid, and 28-cell gameplay chunks. A conservative XZ
viewer rectangle and one whole data-block halo on all axes ensure it never
omits a mesh input because of unfavorable grid alignment. Each sorted,
acknowledged desired-set delta has at most 128 data blocks; simultaneous
add/remove handoffs use 64 of each. Foreground safety demand precedes primary,
retained, and optional viewer demand. A rejected delta replays identically;
the next source replacement waits for its acknowledgement. A proposed union
above the adapter's 32,768-entry hard cap returns `pending` without replacing
the previous desired set, so the caller must retain and retry that proposal
after viewer retirement. It is not a promise that the engine has published
those blocks or that prepared bytes fit.

Focused contract: `node tools/run-n3-terrain-demand-planner.mjs` passed at
`artifacts/native-world-backend/n3-terrain-demand-planner-1790169513568-20fdb969/report.json`
(owned process: `artifacts/node-tools/process-runs/godot-iID7bi/watchdog.json`).
The actual runtime constants yield 1,183 startup data keys in ten bounded
deltas, 3,150 full-height primary keys, and 8,204 for a disjoint 128-distance
startup auxiliary. Retained and foreground chunk sources overlapping that
primary do not duplicate keys. The contract also proves stable source IDs,
duplicate-source rejection, priority, 64/64 moved-viewer handoff, explicit
ack/retry, and non-mutating over-cap rejection. This is headless planning
evidence only, not streaming or gameplay acceptance.

The single publisher now has `apply_data_block_delta(add, remove)`, with a
ready acknowledgement meaning only that the desired-set mutation was retained.
Its focused headed fixture accepted two incremental additions totaling 129
data keys on top of an existing 27-key halo, then idempotently removed them.
It also passed a linked 1,183-key startup primary desired-set handoff in ten
bounded additions and ten removals, with no native registrations or physical
publication in that large-union phase. Report:
`artifacts/native-world-backend/n3-native-terrain-publisher-1790169703390-0bb46b8b/report.json`.
The publisher tracks only as-yet-unregistered keys in its source-admission
retry list, so pumping does not rescan thousands of already registered keys.
It does not physically publish the full primary viewer. The publisher remains
responsible for native request retries, generation-specific insertion and
physics receipts, and delayed release until actual engine unload. The runtime
must feed real viewer/foreground/retained inputs and retain an over-cap
candidate until it can admit that viewer safely. The planner's conservative
rectangle may overfetch; measure the exact engine residency and frame cost
before narrowing it, never omit active mesh inputs to chase a smaller count.
