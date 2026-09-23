# N3 responsive Main native-load initializer boundary

Status: the synchronous Main hook is removed. A pure-core incremental typed
volume builder is committed. This tranche adds a staging-only GDExtension
begin/append and bounded-disposal surface, but does not link/run a new DLL
because the existing Godot-cpp build cache is incomplete. No worker
finalization, native Main New Game/Continue initialization, frame-cadence
acceptance, or gameplay cutover is claimed.

## Builder-only milestone

Commit `10fff20985a10d0eeb638863a62230f35b473b21` adds
`NativeTerrainVolumeV2ImportBuilder`: it freezes the terrainVolume v1/section
size 16/revision identity, accepts strictly canonical typed chunks with a
default 256-record per-call ceiling and 65,536 total records, rejects malformed
or out-of-order input, permits safe abandonment, and reuses the existing
complete v2 validator from `finalize()`. Finalization is explicitly whole-
volume worker-only work. Direct focused MSVC debug and release builds each ran
five component contract cases successfully (5/5), including a full
65,536-record/16-section import split into 4,096-cell batches and public final
validation. The source receipt runner initially stopped before build due a
Windows raw-versus-upstream LF license-hash false mismatch; runner fix
`c285fc1` is now on the branch. LLVM coverage remained unavailable because the
pinned LLVM coverage tools were not installed. There is still no adapter
binding or runtime import evidence attached to that core-only milestone.

## Staging adapter and bounded cleanup tranche

The current source adds `begin_terrain_volume_v2_import`, bounded
`append_terrain_volume_v2_import`, `cancel_terrain_volume_v2_import`, and
`drain_terrain_volume_v2_import`. Begin returns a generation token required by
every later append/cancel/drain/status call; stale tokens fail without mutation
so late old transactions cannot affect a replacement import. The bridge caps
each append at 256 cell records, converts Godot Variants only on the calling
thread, passes typed records to the pure core with the existing independent
per-cell metadata budget, and does not expose `finalize()` or initialize a
backend state. New Game and Continue backend initialization both refuse to
start while an import retains data; after bounded drain, initialization can
proceed normally. These cardinality caps do not bound CPU time.
Cancellation and malformed-input rejection retain prior data;
each explicit drain disposes at most 64 records/section rows. Current
pure-core focused debug and release contracts each pass 6/6, including
complete-validator failure retaining records for two bounded disposal calls.
The exact adapter translation unit compiled successfully as a
single SCons target. A whole extension build was stopped when it began
rebuilding the uncached Godot-cpp generated bindings, so the GDScript adapter
contract was not run against a newly linked DLL. Only syntax validation ran:

```powershell
& 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' `
  --headless --path . `
  --script scripts/testing/native_world/NativeTerrainVolumeV2ImportAdapterContract.gd `
  --check-only
```

After a debug DLL containing this adapter source has been built, the focused
runtime fixture should be run from the project root with:

```powershell
$env:VWB_TERRAIN_IMPORT_ADAPTER_REPORT = (Join-Path (Get-Location) 'artifacts/native-world-backend/n3-incremental-volume-v2/adapter-contract-report.json')
& 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' `
  --headless --path . `
  --script scripts/testing/native_world/NativeTerrainVolumeV2ImportAdapterContract.gd
```

That runtime command and report have not yet been executed/produced; the
adapter method bindings, 100/256-record calls, cancellation/rejection cleanup,
the two-record per-cell metadata-budget parity case, and reported timing fields
remain an explicit verification gap. The 256-record cap bounds record
cardinality, not CPU cost for pathological metadata: each state still admits
up to 4,096 native metadata nodes (with bounded depth/container/string sizes),
and an append can contain many such states. Gate 5 runtime frame cadence is
therefore unproven. The 100-record, 256-record, and per-cell metadata fixture
timings, when available, are diagnostic only and cannot be treated as Main-
frame responsiveness acceptance.

The adapter's `ownerMustBeRetainedUntilDrain` response is a caller contract,
not enforced self-ownership. A `NativeWorldBackend` destroyed with an
undrained builder still frees its remaining native records synchronously in
its destructor. Therefore callers must keep a reference and pump drain to
completion; destruction of a live/abandoned import is teardown-only and is
not evidence of bounded cleanup. The adapter is not connected to Main, so
this limitation is a hard blocker for any production use until a retaining
owner/retirement mechanism is designed and tested.

## Why the prototype was withdrawn

The prior prototype called `begin_native_terrain_load_preparation()` from
`MainCore._run_deferred_startup_boot()`. That helper synchronously called
`save_terrain_volume_deltas()`, built a v2 source request, and invoked
`NativeTerrainLoadTransaction.start()`. The transaction deep-duplicated the
request and called `NativeWorldBackend.initialize_from_save_v2()` in the same
Main callback. The native adapter preflights the whole section array, walks
every cell record, parses all records into a native vector, and constructs the
world state and shaping registry before returning. Splitting later calls to
`advance()` across frames cannot bound this start call.

The startup hook also missed the explicit flows: the visible New Game handler
uses `start_new_game_staged()` / `run_new_game_staged()`, and runtime Continue
uses `run_runtime_world_load_staged()`. Those paths replace seed/save state
separately. A startup-only transaction could therefore be stale or absent for
the user-requested operation it was meant to prepare.

Existing empty-volume contract reports recorded 548 and 684 microseconds for
the entire Main helper start, with measured callback work up to 37 and 75
microseconds in their small fixture. These are diagnostic observations of an
empty durable volume and a fixture page adapter only. They do not represent a
populated Continue save, the save-volume snapshot copy, visible frame cadence,
or a normal Main loading journey. They must not be used to accept this design
as responsive. The reports are retained at:

- `artifacts/native-world-backend/n3-main-load-transaction-1790184038547-5d878912/report.json`
- `artifacts/native-world-backend/n3-main-load-transaction-1790184976712-32755042/report.json`

## Safe integration boundary

Keep the script generation/query/collision/save authorities unchanged until a
future staged import exists. Do not invoke `NativeWorldBackend` or copy a
large Godot `Dictionary`/`Array` from a worker thread: the GDExtension adapter
uses Godot Variants, and a worker copy would move or duplicate the unbounded
work rather than prove it bounded. The loader must own an immutable input
revision throughout preparation and cancellation.

The next viable Stage A shape is:

1. The selected Main operation freezes world identity and the exact v2 save
   input. New Game uses the canonical empty durable volume. Continue preserves
   the loaded save's `terrainVolume` precedence and resolves historical v2
   `terrain` columns before any playable readiness claim.
2. Main extracts/validates durable section records from an authoritative
   paged/cursor source in bounded batches. The staging GDExtension bridge
   accepts bounded typed batches but does not finalize/import a backend state;
   its caller-owned cleanup contract is not production-safe until undrained
   destruction cannot cause a large frame-thread free. Each batch is
   converted immediately to native-owned POD/value records; do not first call
   `save_all_section_deltas()` and deep-copy the complete volume. Bound record
   count and measured time per frame, retain cursor/retry state, and measure
   the extraction itself.
3. A native worker constructs the backend state and shaping registry from
   detached immutable native values only. It must not read Nodes, GDScript,
   Godot Variants, or mutable save containers. Check cancellation between
   bounded construction phases where possible.
4. Main polls progress once per frame. Cancel/reset invalidates the transaction
   epoch but retains all input and worker-owned payloads until worker exit and
   any Citadel source leases have acknowledged retirement. Do not clear the
   owner and call that drained. Join only after an authoritative worker-finished
   acknowledgement; account for any remaining join and destruction time.
5. The ready native owner is committed only if transaction ID, seed/source
   identity, save revision and cancellation epoch still match. Until then, the
   existing script authority remains the sole production authority. New Game,
   Continue, replacement load, failure, cancel and shutdown must all use the
   same retained owner lifecycle; no synchronous fallback is allowed.

The current fixture-fed `NativeTerrainLoadTransaction` intentionally supports
cancellation only before its first `advance()`. After page/admission advancement
it fails closed with `active_source_cancellation_unsupported` and retains its
backend; it does not claim that source workers drained. This limitation blocks
any Main integration until it is replaced with lease-aware cancellation and
retirement acknowledgement. The focused service contract proves this rejection
path using a held test adapter, not cancellation of a real active worker.

Do not broaden this checkpoint into a terrain publisher or change gameplay
readiness. That requires later parity, collision installation/physics
acknowledgement, save export and atomic authority-switch gates.

## Responsive acceptance for a future integration

Total load duration is diagnostic and may exceed 90 seconds. For every measured
cold and Continue launch, use the fixed `gate5-responsive-loading-2026-09-23`
envelope: first visible loading frame within 1,000 ms of menu input, loading
frame-gap p99 at most 33 ms and maximum at most 100 ms, full-loading Main
callback maximum at most 33 ms, and source-owned completed-work heartbeat gap
at most 5,000 ms including input-to-first-work and last-work-to-ready. Report
snapshot extraction, request building, native parse/build, page admission,
commit/publication, and retirement separately. A small service contract or
Main callback timing alone is not headed frame-cadence acceptance.

Focused lifecycle tests must include cancellation before work, after a real
page/source request is active, during result construction/retirement, and
generation replacement. They must prove all leases drain only after the
corresponding queue token/payload is absent, stale completions cannot publish,
and owner release does not synchronously destroy the large last alias on Main.
Exercise both explicit staged New Game and Continue inputs. The final Gate 5
loading matrix remains required after the complete migration; this design note
does not reduce it.
