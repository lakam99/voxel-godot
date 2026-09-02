# Upper-façade bearing: representative clearance study

The zero-failure goal remains active. Current verified physical count is 317.
This study is read-only source/record evidence, not a geometry repair or live
collision test. It rejects one proposed fix and identifies a visual decision.

## Current representative geometry

Source: `scripts/buildings/CitadelUrbanPocComposer.gd:add_street_house` and
`artifacts/citadel-visual-reset/facade-mount-diagnostic-01/report.json`, selected
part snapshots for `urban_row_00_left`, seed 208159, scale 1.25.

- Ground/foundation top: 0.620.
- Stone base height: 1.674 (`min(2.1, 6.2 * 0.27)`), top 2.294.
- Interior floor: centre 0.730, thickness 0.200, top 0.830.
- Upper façade centre X: -2.527795; thickness 0.300.
- House foundation street edge X: approximately -2.857795.
- Declared doorway height: 2.500 above ground; access width: 1.860.
- Player collision capsule height: 1.720 (`PlayerController.gd`); production
  default NPC standing height is also 1.720 (`NpcConstants.gd`, read-only).

A 0.240-deep interior cross-bearer directly below the upper façade would leave
`2.294 - 0.240 - 0.830 = 1.224` vertical clearance. This is less than the
actual standing capsule height. A continuous base-level façade sill also
crosses the taller door opening. Neither is an acceptable generic repair.

The existing 0.620 overhang is intentional visual geometry; its inner wall
face misses the lower stone outer face by 0.320. Merely choosing a nearby wall
as an anchor or declaring a lateral masonry contact a timber joint does not
supply the missing load path.

## Dimensioned exterior-support candidate — NOT IMPLEMENTED

A post-supported frontage avoids putting low beams across the interior.
Candidate dimensions are design-study inputs, not structural adequacy claims:

- Four timber posts, 0.240 square, centred on façade X -2.527795.
- Corner post Z: -39.36868 and -30.27868.
- Inner post Z: -36.02368 and -33.62368, i.e. centre Z +/- 1.200.
- Post top Y: 2.054; bottom must come from a certified footing top.
- Two sill segments at Y 2.054–2.294, X thickness 0.300, with both ends
  supported. Their inner ends must respect the full declared door access.

Post rear edges stay 0.070 outside the declared room boundary; inner post
edges leave 2.160 width versus the 1.860 access. Those simple separations do
not establish door-sweep, exterior-prop, collision or lane-traversal clearance.
The posts are outside the existing house foundation. No bearing beneath them
is proven by the selected snapshots. Contact with paving is not enough:
an independently rooted structural footing is required.

Required load path: grounded footing to post, post to sill, sill to solid
piers and real opening headers, then upper panels. Finite downward-bearing
patches and missing/moved/ungrounded/cyclic-support negatives must verify it.
Panels nearer the doorway, windows and higher openings still need proper
headers; this candidate does not promise to resolve all 163 failing panels.

## Critic and user decision

Independent critic accepted this as a legitimate *design-study candidate*,
not approved implementation. Visible posts would turn the open recess into
a post-supported frontage and introduce street collision. Wall/roof planes
and furniture records can remain unchanged, but appearance is not identical.
The main agent requested explicit user agreement asynchronously before changing
that architectural feature. No posts, footings, sills or collision were added.

While that choice is pending, other independently justified mounting defects
may be repaired. The zero-failure objective is not redefined around those
smaller repairs. No headed test was launched for this study, and no navigation
code or tolerances were changed.
