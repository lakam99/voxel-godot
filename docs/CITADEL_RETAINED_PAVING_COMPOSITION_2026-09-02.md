# Retained paving in actual citadel composition

Branch `codex/citadel-visuals-clean`, starting clean `7234f50`. This connects the
previously reviewed source helper to `CitadelUrbanPocComposer`; no protected NPC,
navigation, tree, terrain, save or runtime-publication owner changes.

## Source change

The existing prune decisions now copy the real grounded roots they remove.
After shops finish, surviving collision-backed courtyard paving is selected by
its production semantic. Current furniture, room/interior, access and every door
primitive sweep are normalized into validated reservations. Portcullis and
ordinary doors use their respective shared geometry recipes.

Preparation remains private. The append commit rejects changes to ordered
existing part records, rooms or recipe data, and uses the established complete
transaction validator before mutation. Original part objects survive. A callback
can cancel after preparation and before any retained geometry is committed.
Successful no-op output adds no diagnostics and preserves the complete old
handoff. Non-noop diagnostics contain bounded source/part IDs, not retired
blueprints or transient runtime state.

Ordinary structural completion remains unchanged. Its failure cannot return a
publishable blueprint through the shared source preparation boundary.

## Evidence

All paths below are under `artifacts/citadel-runtime-integration/`.

| Evidence | Actual result | Limit |
| --- | --- | --- |
| `retained-composer-contract-02` | 17/17 synthetic adapter checks | Distant-door fixtures test sweep input handling, not crossing or sweep-intersection rejection |
| `retained-composer-adapter-01` | 7/7 actual post-shop source checks, including unchanged inputs, exact commit and original object identity | Cached source adapter, not full composition |
| `retained-precommit-cancel-01` | 6/6; callback stops at the precommit boundary, no new bearings or later stage, no blueprint in failed handoff | Actual composition from cached pre-urban source; not live worker shutdown or bounded cancellation latency |
| `source-parity-06` | 8/8; full source API output byte-exact to approved reference | One reference recipe seed, no live visuals |
| `actual-site-source-04` | Full source gate **still fails**, but only on the civic sign; three paving failures are gone | Not a valid candidate or successful live spawn |

Synthetic replay, using a fresh output path:

```powershell
./tools/run-citadel-retained-paving-composer-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/retained-composer-contract-02
```

Full source runs use the existing owned scene watchdog, Godot 4.6.1 headless,
`-Scene '--script'`, and the following `-SceneArguments`:

- `res://artifacts/citadel-runtime-integration/source-parity-06/profile.gd`
- `res://artifacts/citadel-runtime-integration/actual-site-source-04/run.gd`

Each directory contains its exact command in `watchdog.json`, stdout/stderr and
JSON report. The actual candidate also has `launch.json`, `progress.json` and
typed `result.bin`. Replay must first use fresh script/output prefixes. Both
full runs retain the existing 450-second watchdog; it was not increased.

Reference `237207443`, forest / river-citadel, scale `1.25`: complete output is
6,748,364 bytes, 4,649 building parts and 146 furnishings, unchanged including
source diagnostics and reservations. Preparation measured 236.292 seconds.

Actual world `atlas-1492`, region `(1,-3)`, centre `(3236,-5431)`, recipe
`1298433643`, scale `1.25`: the real prune captured 96 roots and added 18 bearing
parts for paving `02`, `04`, `80`. The final `failedIds` and detailed physical
failure inventory contain only `urban_civic_house_east_sign_arm`. Source hashes
remain stable through the 288.054-second run. No blueprint or terrain profile is
returned. The deliberate `structural_completion_unresolved` error remains in
stderr, and functional exit is **1**, not a relabeled pass.

Reference and focused successes have natural exit 0 and empty stderr. All
inspected owned jobs, including the deliberate actual-candidate failure, report
clean cleanup and authoritative zero processes. Concurrent source timings are
diagnostic measurements, not gameplay-frame or isolated performance acceptance.
No headed test was launched.

## Review and remaining scope

The independent critic approved this focused wiring and its final evidence.
That approval does not cover live spawning or headed readiness. Sign source
placement is being investigated separately; neither its correction bound nor
invalid-site policy was changed. The actual site remains unavailable until its
source gate passes. Normal-world admission/publication, streaming/unload,
save/reload and critic-approved visual/player traversal acceptance remain open.
