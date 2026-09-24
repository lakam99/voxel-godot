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

## 2026-09-24 bounded replacement handoff checkpoint

`NativeTerrainRuntimeOwner` now exposes the planner's leased,
frame-budgeted begin/advance/cancel replacement API. Its service fixture
drives a 27-block request through that API and verifies the same owner and
publisher receive it. This is an inert owner boundary: production
`VoxelTerrainRuntime` has not adopted the owner, and the older synchronous
`replace_demand` entry point remains for existing fixture callers. It is not
N3 production cutover or streaming performance acceptance.

An independent review found that superseding active request A with queued B,
then requesting C before A drained, silently replaced B's token and payload.
The replacement now returns `replacement_successor_slot_occupied` with
`accepted:false`, `retryable:true`, and the two retained tokens. It does not
consume a token or take ownership of C. The producer keeps C and retries after
B reaches a terminal result. The focused contract proves A→B→C, B publication,
and C's eventual retry; no request disappears.

Focused commands passed with Dummy audio and `VOXEL_DISABLE_AUDIO_PLAYBACK=1`:

- `node tools/run-n3-terrain-demand-replacement.mjs` —
  `artifacts/native-world-backend/n3-terrain-demand-replacement-1790212784046-9b193263/report.json`;
  maximum 256 work units per advance. This is a planner contract, not physical
  publication evidence.
- `node tools/run-n3-terrain-runtime-owner.mjs` —
  `artifacts/native-world-backend/n3-terrain-runtime-owner-1790212773403-3be7561a/report.json`;
  service-level owner/publication handoff only.
- `node tools/run-project-compile-smoke.mjs` — passed after project import.

Each completed runner reported natural exit and authoritative zero owned
processes in its watchdog receipt. This fresh worktree had no installed
GDExtension DLLs or Godot import cache. The Voxel Tools and custom native DLLs
used for the service fixture were copied from the existing isolated N3
worktree, then this project was imported. Those DLLs were **not rebuilt from
this checkout's source**, so the service run does not certify current native
source/binary identity. No C++ file changed in this checkpoint. A current
debug/release build and source-bound receipt remain required before native
cutover evidence. Godot's generated import metadata was restored; only the
four intended source/test files and this ledger are part of the checkpoint.
