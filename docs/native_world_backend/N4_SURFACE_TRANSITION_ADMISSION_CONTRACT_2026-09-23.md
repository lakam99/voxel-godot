# N4 source-ordered surface transition admission contract

Status: cutover contract, not an implemented transaction or gameplay pass.

The current `WorldDeltaStore` footprint catalog can invalidate the static
footprint of an edited generated ID. That is not sufficient for ordinary
surface props. `MainPlaytestTools.spawn_chunk_prop_attempt` and its native
ordered stream share one RNG across 28 attempts. A parent tombstone skips
classification and recipe draws; an ore-child tombstone skips its child draws.
Either can change later IDs, families, anchors and physical shapes. The
existing `NativeSurfacePropChunkDifference` witnesses this suffix change but
explicitly has incomplete channel footprints. Consequently, no ordinary
surface-prop tombstone may be admitted to production merely by filling a
static `NativeGeneratedFeatureFootprintCatalog` entry for the edited ID.

## Required native transaction

For an affected ordinary surface chunk, one native owner must prepare an
immutable transition under an unchanged terrain/source pin:

1. Bind the current world physical identity, owner generation, terrain and
   shaping revisions, biome/environment catalog, rock visual catalog,
   wildlife presentation catalog, structure exclusion source and exact tree
   halo admission. Bind the *before* world-delta revision and feature snapshot
   digest and the proposed *after* feature snapshot digest.
2. Recompute the complete before and after 28-attempt ordered streams,
   placements and typed feature manifests. Compare every ordinal and every
   ore child, not only IDs added to or removed from the tombstone set. Retain
   both final RNG states and both manifest digests in the receipt.
3. Derive changed render, collision, navigation and terrain-source regions
   from the union of the old and new typed artifacts. A channel known to be
   empty must be declared empty; a channel whose geometry or owner is not yet
   known must block admission, not masquerade as empty. Expand to exact
   section/seam neighborhoods, bound memory and work, and sort/deduplicate
   the result canonically. Tree blockers may alter neighboring chunks, so
   changed halo consumers must be included before the receipt is complete.
4. Commit the feature snapshot, transition receipt, section invalidation and
   transaction journal atomically only if the expected revision and every
   source/owner identity still match. Preserve the strong exception guarantee:
   a stale, incomplete, over-budget or rejected preparation changes nothing.
   Reversal is a new before/after transaction, not reuse of an old footprint.

The save remains the current v2 list of opaque `removedProps` IDs. It stores
player-made deltas, not footprints or a regenerated world. Continue must
recreate and validate the same native source/transition facts before admitting
those IDs; no GDScript fallback may silently accept them.

## Geometry and ownership still required

The N4 manifest has initial physical declarations for rocks (sphere), ore
children (individual spheres), forage (sphere), wildlife (box) and admitted
trees (trunk cylinder). Those facts alone do not prove all-channel section
footprints. Ordinary props do not edit terrain volume, so their terrain-source
channel is intentionally empty. Forage can have a physical collider without
being an NPC navigation blocker. Tree canopy and buttresses are non-colliding.
Wildlife bodies move after spawn; their continuing collision ownership is a
dynamic actor lifecycle, not an immutable spawn-section footprint. Render
bounds for selected assets and complete native tree family grammar, exact
navigation occupancy policy, live owner freshness and structure/citadel plus
underground feature families remain to be supplied before general
`removedProps` cutover.

The static catalog may still serve a feature family proven independent of
source-order effects, but it must not be treated as the ordinary surface
transition authority. No production caller uses the native manifest or
catalog today. This document does not authorize changing the protected NPC
route stack; navigation publication must consume the eventual source artifact
through its established contract.
