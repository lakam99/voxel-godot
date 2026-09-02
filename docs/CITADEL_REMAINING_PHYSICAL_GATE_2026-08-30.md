# Remaining Citadel physical gate: diagnostic and action record

Date: 2026-08-30. Worktree: `voxel-biome-world-godot-citadel-visuals`.
AGENTS.md and MANIFESTO.md govern this work. This record documents read-only
analysis of existing evidence; no new engine run or implementation is claimed.
Only this new document was written for this recording task.

## Frozen baseline: 328 violations

Source: `artifacts/citadel-visual-reset/upper-trim-contract-01/report.json`,
`afterViolations`; seed 208159, scale 1.25. The physical gate is false:
208 structural-mass failures and 120 facade-attachment failures.
This is the post-upper-stud/floor-beam repair baseline, not a measurement of
the main task's ongoing corner-frame/lintel changes.

| Family | Failures |
| --- | ---: |
| Upper facade panels | 163 |
| House roof halves | 28 |
| House chimneys | 14 |
| House projecting-bay backing | 3 |
| House corner frames | 11 |
| House upper studs | 2 |
| House floor beams | 4 |
| House street braces | 13 |
| House door brackets | 16 |
| House door lintels | 6 |
| House eaves | 14 |
| House firewood | 17 |
| House sign arms | 5 |
| House projecting-bay attachments | 3 |
| Market knees | 12 |
| Market canopy ridges | 3 |
| Terminal brackets | 6 |
| Terminal lintels | 3 |
| Terminal sign arms | 3 |
| Bunting ropes | 2 |
| **Total** | **328** |

The 163 upper-facade failures comprise 154 row-house panels plus nine
`urban_civic_house_wall` panels. Market and terminal members are separate
producer families; a street-house mounting fix does not repair them.

## Shared geometry finding

In `scripts/buildings/CitadelUrbanPocComposer.gd`, `add_street_house` and
`add_recessed_facade_mass` produce, with `s = street_side`:

```text
lower_outer_x = center.x + s * width/2
upper_outer_x = lower_outer_x + s * 0.62
upper_inner_x = upper_outer_x - s * 0.30
presentation_facade_x = upper_outer_x + s * 0.14
```

For these houses, the upper wall is 0.30 thick. Its inner face therefore
misses the lower stone outer face by **0.32**, and its outer face projects
**0.62** beyond the stone. Neither correcting trim nor declaring a lateral
contact supplies downward bearing across that gap. Some existing panels
contact rooted side shells, but contact alone is not a certified masonry
load path. Six repaired studs/floor beams still lack rooted anchors in the
baseline despite contacting their own facade.

## Bounded trim candidate: status and proof

The main task is already patching corner frames and a lintel and running its
diagnostic, per the main agent's status update. No result from that work is claimed
here. Record its eventual report separately from the frozen 328 baseline.

The corner-frame candidate replaces only the X expression
`facade_x + s*0.05` with `upper_facade_x + s*0.05`. With frame thickness 0.24,
the nearest edge changes from a 0.07 gap to 0.07 embedment in the upper wall.
Dimensions, materials, Y/Z, collision=false, roof and room geometry stay fixed.
The lower portion still misses the stone by 0.55: these remain attached trim,
not grounded load-bearing posts. Eleven baseline failures are in this family;
eleven removals are not promised. The frame calculation does not certify the
lintel's separate geometry or anchor.

Require exact intended-only transform changes, zero-margin own-wall contact,
rooted anchors, moved/removed/ungrounded-anchor negative controls, unchanged
furniture/rooms/collision records, and no added violations. Inspect targeted
before/after images; this preserves massing, not identical trim pixels.

## Genuine jetty design implications

The next high-impact structural candidate is a shared jetty assembly, not a
nearest-contact assignment or an arbitrary list of support IDs:

- Cross-bearers need a real backspan into the house and two downward-bearing
  seats on rear and front stone walls before projecting to the upper facade.
  A short outward shelf touching only the front wall is not equivalent.
- A preliminary section is 0.24 by 0.24, top at
  `ground_y + base_height`, with actual top-wall pockets and seat surfaces
  at `ground_y + base_height - 0.24`. These are candidate dimensions, not
  established structural adequacy or collision acceptance.
- Derive positions from solid pier intervals in the opening partition, not
  house names or seeds. Preserve the entire door opening and clearance.
- Add genuinely supported facade ledgers and opening headers where needed.
  Supporting the lowest panels alone does not prove transfers across window
  and door openings or solve roofs, chimneys and projecting bays.
- Publish finite transformed downward-bearing patches at both stone seats.
  Use housed-joint facts only for actual geometrically certified joints;
  lateral masonry contact must not be relabeled as fictional housed joinery.

Backspans, pockets and ledgers change real collision and may occupy furnished
space or headroom. They must have matching visible geometry and authoritative
collision. Keep exterior planes, silhouette, openings and furniture placement;
reject or redesign a candidate that intersects furniture or required clearance.
Do not move/delete furniture or add invisible support to obtain a passing gate.

## Staged actions toward zero

1. Finish and independently verify the bounded frame/lintel diagnostic. Record
   the actual removed/added violation IDs and a fresh remaining inventory;
   retain failures rather than declaring an expected count achieved.
2. Before collision-changing jetty implementation, establish applicable
   unchanged-baseline NPC/navigation regression and real headed generated-world
   evidence as required by MANIFESTO.md. A regression is a stop-and-report event,
   not permission to alter protected navigation.
3. Prove one representative shared jetty assembly through real geometry and
   existing gravity-bearing contracts. Test missing/moved seats, ungrounded
   roots, insufficient bearing patches, cyclic support and blocked openings.
   Then cover both street sides, generated dimensions and fresh seeds.
4. Verify the full facade load path, including opening headers; measure rather
   than assume downstream trim improvements. Address roof/chimney/bay bearing
   and separate market/terminal/attachment families in bounded follow-up steps.
5. After each meaningful geometry change, repeat source contracts, actual
   collision-backed movement/regression coverage and visual/furniture checks.
   Preserve room/furnishing snapshots and check physical intersections too:
   identical furniture records alone do not prove an unobstructed interior.
6. Final acceptance requires an actual zero-violation report and enforced
   publication gating, not the existing publication bypass. Preserve all
   tolerances, classifications and support requirements. Include headed
   day/night/interior evidence and relevant runtime/performance coverage;
   a source-only pass cannot substitute for gameplay acceptance.

No stage promises a particular reduction or that one assembly will reach zero.

## Evidence references and limits

All paths below are relative to this clean visuals worktree:

- `artifacts/citadel-visual-reset/upper-trim-contract-01/report.json`:
  exact 328 inventory, 56 own-facade trim contacts, 50 rooted trim pieces;
  source/geometry contract only. Adjacent `stdout.log`, `stderr.log` and
  `watchdog.json` record execution and cleanup.
- `artifacts/citadel-visual-reset/physical-timebox-contact-fix-03/report.json`:
  earlier selected part geometry, inferred support records and
  `selectedGeometricContactsNotLoadProof`; predates the upper-trim repair.
- `artifacts/citadel-visual-reset/upper-trim-capture-01/report.json` and
  `screenshots/`: existing headed visual evidence, not full acceptance;
  publication bypass and known camera/window issues remain documented.
  Its `watchdog.json` records execution/cleanup.
- `docs/CITADEL_UPPER_TRIM_REPAIR_2026-08-30.md` and
  `docs/CITADEL_PHYSICAL_GATE_TIMEBOX_2026-08-30.md`: prior commands, scope,
  preservation checks, measured outcomes and limitations.
- `scripts/buildings/CitadelUrbanPocComposer.gd` and
  `scripts/buildings/BuildingBlueprint.gd`: producer geometry and existing
  transformed-contact, gravity-bearing and rooted-support contracts.

This is a diagnostic/action record. It neither reports fresh test results nor
authorizes navigation changes or weakens the physical publication gate.
