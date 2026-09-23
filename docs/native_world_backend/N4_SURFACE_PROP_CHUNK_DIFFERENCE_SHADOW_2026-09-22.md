# N4 surface-prop chunk difference shadow checkpoint

Status: verified pure-core shadow witness. No generated-feature footprint or
production `removedProps` admission is claimed.

`NativeSurfacePropChunkDifference` compares two source-ordered 28-attempt
streams and their SPO1 placement sets against one pinned effective terrain,
world, generation, chunk, environment receipt and structure-exclusion
revision. It recomputes each placement digest against that pin, rejects stale
or mismatched inputs, and records changed ordinals with both durable IDs,
outcomes, tombstones, anchors, source-attempt digests and RNG boundaries. The
witness digest binds all 28 before/after source attempts, both placement
digests and final RNG states, including changes inside ore, forage and
wildlife recipes that might leave an anchor unchanged. It explicitly returns
`channel_footprints_complete=false` and cannot be passed to `WorldDeltaStore`
as an all-channel invalidation catalog.

Focused LLVM component run: 5/5 tests, 175/175 lines, 30/30 functions and
90/90 branches in the new implementation. Integrated command:
`node tools/run-native-world-backend-tests.mjs --run-name
n4-chunk-difference-01`. Its report at
`artifacts/native-world-backend/n4-chunk-difference-01/report.json` passed
412/412 debug and 412/412 release standalone tests, editor and isolated
release-adapter smokes, and strict pure-core coverage of 9,194/9,194 lines,
1,249/1,249 functions and 5,398/5,398 branches. The report records source
inventory, installed binary identities and denominator validation.

The new tests use synthetic admitted source inputs. The independent direct
Godot removed-root and ore-child source-order oracles remain separate targets
(`n4-removed-root-rng-oracle-02` and `n4-ore-child-shift-oracle-01`); this
component result does not assert exact native/Godot IDs or final-state parity
for those oracle setups, nor headed visual, collision, harvest, navigation or
save/reload acceptance. Independent read-only review found no actionable
correctness defect within the shadow scope and confirmed the type cannot be
mistaken for a complete footprint receipt.

Caller/deletion audit: no normal-gameplay caller uses this witness; the
surface and underground prop loops, `MainSaveState` and `WorldDeltaStore`
production policy remain unchanged. No production authority is eligible for
deletion here. Complete typed publication definitions for every changed
surface family, an atomic 28-attempt cutover, before/after render/collision/
navigation/terrain-source occupancy, underground ID coverage and live v2
checkpoint acceptance are still required before N4/N3 cutover. Gate 5 remains
open.
