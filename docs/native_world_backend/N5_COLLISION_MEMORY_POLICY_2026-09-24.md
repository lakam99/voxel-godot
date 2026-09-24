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
deep-copies the configured limits into a new canonical policy at setup; later
mutation of the caller's policy object cannot alter admission. Setup also
requires a caller-unique instance nonce. Ledger identity binds schema, caller
epoch, nonce, and frozen policy identity, so tokens and release acks from two
same-epoch ledger objects with distinct nonces are not interchangeable. This
pure component validates that a nonce is present; the future coordinator owns
process/restart uniqueness and must never reuse it.
Ledger tuple fields are length-framed before hashing, so colons and Unicode in
caller epochs/nonces cannot make different tuples share an identity. Every
pre-mutation audit recomputes that identity from schema, epoch, nonce, and the
frozen policy; direct or constituent-field corruption fails closed.

The ledger charges candidates before allocation. Entries transition through
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

Every mutation first derives authoritative aggregate/window charges, semantic
index entries, body-instance ownership, valid state/frame facts, and sequence
continuity from the reservation set. Each reservation retains a bounded
canonical copy of its admitted source rows; the audit recompiles the policy
receipt from those rows rather than trusting stored charges or body counts. It
also reapplies reservation, per-request, per-window, and aggregate policy caps.
Any mismatch—including a coherently edited receipt/counter/index—fails closed
without further mutation. The body-owner index is global across every
reservation in one admission-ledger instance, not across independent ledgers;
the future coordinator must therefore use one ledger for the ownership domain.
A body instance remains owned until exact deferred-free ack.

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
rounding, overflow, frozen configuration, intrinsic validation before capacity,
exact caps, retryable denial, old+candidate overlap, all state transitions,
same-epoch ledger isolation, global body ownership, owner/ledger/body/frame
proof, deferred retention, replay rejection, derived corrupted-ledger
fail-closure, and zero-reservation drain. It remains a pure Godot contract; it
does not measure or prove actual engine allocation size, physics-server memory,
or teardown.

Historical focused result: **PASS** on 2026-09-24 with Godot 4.6.1, Dummy audio, engine
exit `0`, no parse failures, no contract failures, and authoritative owned-job
membership zero at exact source commit
`50035944ef575b72c764bef80796fac176f8dc8f` (based on
`259d1f17a0f0d0036090f68529525f1eadc729a6`). Independent shadow review then
classified that exact commit **NO-GO** because its integrity/policy/ledger/body
isolation was incomplete. Therefore the historical PASS is not evidence for
the current repair. The runner now writes the exact Git commit and
SHA-256 of every policy/admission/contract/runner source into its report, and
fails unless those hashes, the commit, v2 schema, evidence level, and negative
production diagnostic flags match its own just-computed values.

```text
report:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\native-world-backend\n5-collision-memory-policy-1790240435380-61f43003\report.json

owned watchdog:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\node-tools\process-runs\godot-2FEus5\watchdog.json
```

Exploratory repaired focused result: **PASS** on 2026-09-24, engine exit `0`, schema and
source attestation matched, no failures, cleanup passed, and authoritative
owned-job membership reached zero. The repair was an uncommitted diff atop
`50035944ef575b72c764bef80796fac176f8dc8f`, so the exact tested authority is
the commit plus this source map:

```text
scripts/terrain/NativeCollisionMemoryPolicy.gd
1ee4369cb1c137183d287af90976c7384956f680e8cbbb01f88a4b9f671953ce

scripts/terrain/NativeCollisionMemoryAdmission.gd
397c71eef218ce190c8727b29849736b6168b7a115910b40d9b2f0c78e00ea07

scripts/testing/native_world/N5CollisionMemoryPolicyContract.gd
7879e2c7f07cf751d0cb4f1646eb793a32f9b8cc0df82739a093c67c9d0df2b4

tools/run-n5-collision-memory-policy-contract.mjs
726d6bad5fa7d5d4ddbffa851d3e80eedb03508c3672a2312c5a01dc1957d347
```

That run is not promotable evidence: its runner only compared the pre-run hash
map echoed through the report and did not re-hash after Godot exited. The
hardened runner now freezes its source-freeze helper and both launch helpers as
well as the four contract sources, recomputes all seven hashes and `HEAD` after
exit, requires
`pre == report == post`, reports every drifted path (or `git:HEAD`), and fails
on any drift. A new source-frozen run is still required.

```text
report:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\native-world-backend\n5-collision-memory-policy-1790242641702-5dd18493\report.json

owned watchdog:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\node-tools\process-runs\godot-wgc715\watchdog.json
```

This PASS remains bounded pure policy/ledger evidence. It does not configure
production caps, wire a production owner, measure physics-server memory, prove
engine teardown, close N5, or close Gate 5.

Historical source-frozen repaired result: **PASS** on 2026-09-24. Pre-run, report, and
post-run `HEAD` were all
`50035944ef575b72c764bef80796fac176f8dc8f`; all seven frozen hashes matched;
`changedPaths` was empty. The v2 report had zero failures and retained
`productionWired:false` and `productionCapsConfigured:false`. The owned
watchdog proved job membership zero, and an independent post-run CIM process
query found zero residual Godot/core-test processes.

```text
scripts/terrain/NativeCollisionMemoryPolicy.gd
1ee4369cb1c137183d287af90976c7384956f680e8cbbb01f88a4b9f671953ce
scripts/terrain/NativeCollisionMemoryAdmission.gd
397c71eef218ce190c8727b29849736b6168b7a115910b40d9b2f0c78e00ea07
scripts/testing/native_world/N5CollisionMemoryPolicyContract.gd
7879e2c7f07cf751d0cb4f1646eb793a32f9b8cc0df82739a093c67c9d0df2b4
tools/run-n5-collision-memory-policy-contract.mjs
cb293d097618173daa5245d91318f8b610a634165a339688ba91b0a0d98fb829
tools/lib/godot-process.mjs
2ffec3b281ca1a8e67499927498c496f0529f3dec1bc165cd5f8eb58f381cf38
tools/lib/voxel-tool-runtime.mjs
369d74359d70def1025ef7e3f645cb79b93da237376fff34fd48b9c6b775973c
tools/lib/n5-collision-memory-source-freeze.mjs
5c31cb849bfe5371db25b438662d9c0786da35fa0c87e694285b898087d0eb8c
```

```text
report:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\native-world-backend\n5-collision-memory-policy-1790243290365-50dfdd3a\report.json

owned watchdog:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\node-tools\process-runs\godot-OjD4nQ\watchdog.json
```

This source-frozen PASS promotes only the pure policy/admission precursor. It
does not change the production limitations above. It is stale for the current
diff because the subsequent derived-identity and runner-envelope repairs change
frozen sources; a new runner-envelope PASS is required before promotion.

The source-freeze/envelope Node contract is durably recorded as **8/8 PASS**:

```text
command:
node --test tools/tests/n5-collision-memory-source-freeze.test.mjs

TAP result:
C:\Users\arkam\.codex\worktrees\n5-active-byte-audit\voxel-biome-world-godot\artifacts\native-world-backend\n5-collision-memory-source-freeze-node-2026-09-24.tap
```

Those Node cases prove unchanged/drifted source inventories, HEAD drift,
inventory mismatch, bounded cold-start configuration, and runner-envelope green,
drift, and diagnostic-flag semantics. They do not parse or execute GDScript and
do not replace the pending source-frozen Godot contract.
