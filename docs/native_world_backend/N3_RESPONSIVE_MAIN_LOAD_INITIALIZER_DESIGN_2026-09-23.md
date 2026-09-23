# N3 responsive Main native-load initializer boundary

Status: design checkpoint; the synchronous Main hook is removed. No native
Main New Game/Continue initialization, frame-cadence acceptance, or gameplay
cutover is claimed.

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
   paged/cursor source in bounded batches. Each batch is converted immediately
   to native-owned POD/value records; do not first call
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
