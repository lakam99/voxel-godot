# N5 collision memory policy precursor — 2026-09-24

Status: pure contract only. It is not wired to the artifact broker, resident
collision owner, window coordinator, Main, or the production runtime. It sets
no production byte limits and does not close N5 or Gate 5.

## Authority and formula

`NativeCollisionMemoryPolicy` defines one versioned checked formula. A caller
must explicitly configure every cost and cap after measurements; there are no
fallback/default production values. Source vertex bytes are `vertexCount * 12`
for float32 `Vector3` values. Physical charged bytes are:

```text
rowEntryBytes
+ (bodyEntryBytes when nonempty)
+ ceil(vertexCount / verticesPerShape) * shapeEntryBytes
+ sourceVertexBytes * physicsPayloadMultiplier
```

Every multiplication and addition rejects signed-64-bit overflow. Empty rows
retain a row-entry charge. A configured policy has a stable identity derived
from the formula version and every configuration field. Shape ceiling uses
integer quotient/remainder only; it never converts large counts to float.

`NativeCollisionMemoryAdmission` is a pure physical reservation ledger. It
charges candidates before allocation. Entries transition through
`candidate_reserved`, `candidate_constructed`, `live_current`, and
`retired_deferred`. Old live and replacement candidate charges overlap. A cap
occupied by other reservations returns retryable backpressure without mutation;
a single request larger than its window cap is terminally invalid.

Constructed/live resources cannot release directly. Their charge remains until
an exact acknowledgement proves a later physics frame and process frame, the
same ledger/window/owner epoch and queued frames, exact absence of every retired
body instance, no observed retired collider, and removal of the deferred entry.
Wrong, early, partial, foreign, or replayed acknowledgements fail closed.
Semantic reservation keys remain occupied until final release, issued tokens
are structural ledger-identity plus checked monotonic sequence values, and
release itself revalidates the window, aggregate, and semantic-index accounting
before mutating the ledger. There is no lifetime token-history set: sequence
high-water state is constant-size. A drained ledger is terminal for its epoch;
the owner must create a new ledger object with a new epoch rather than resetting
or rotating one in place.

## Intended staged integration

The next reviewed stage must measure actual closure rows and physics shape
counts before choosing caps. Source-row accounting belongs to
`NativeTerrainArtifactRequests`; physical reservations across owners belong to
one coordinator-owned admission ledger. `NativeResidentCollisionOwner` must
retain deferred body/shape entries until it can construct the exact release
acknowledgement. The window coordinator must then cursorize source requests and
64-row publication batches against an immutable layout/source ticket.

Until that integration and a real 4,913-block physical run pass, the earlier
four-window/eight-artifact fixture remains a partial baseline only.

## Focused contract

Planned command, after the shared Godot lane is released:

```powershell
$env:VOXEL_DISABLE_AUDIO_PLAYBACK='1'
node tools/run-n5-collision-memory-policy-contract.mjs
```

The contract covers formula identity, exact empty/nonempty charges, shape
rounding, overflow, immutable configuration, exact caps, retryable denial,
old+candidate overlap, all state transitions, owner/ledger/body/frame proof,
deferred retention, replay rejection, corrupted-ledger fail-closure, and
zero-reservation drain. It remains a pure Godot contract; it does not prove
engine allocation size or teardown.

Focused result: **PASS** on 2026-09-24 with Godot 4.6.1, Dummy audio, engine
exit `0`, no parse failures, no contract failures, and authoritative owned-job
membership zero. This is bounded pure policy/ledger evidence only; the report
explicitly records `productionWired:false` and `productionCapsConfigured:false`.

```text
report:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\native-world-backend\n5-collision-memory-policy-1790240435380-61f43003\report.json

owned watchdog:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\node-tools\process-runs\godot-2FEus5\watchdog.json
```
