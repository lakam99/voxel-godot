# Exact facade partition boundaries

Candidate 21 failed on `urban_row_03_left_upper_facade_010`. The original and
trimmed panel have the same scalar top, 8.659762859344482, and reconstructed
AABB top, 8.65976333618164. The declared opening begins at 8.659762382507324.
Thus the original producer already intrudes by 4.76837158203125e-7 in scalar
geometry and 9.5367431640625e-7 in reconstructed bounds. The later retained-panel
fit preserves that existing upper edge; it does not introduce the defect.

`FacadeApertureDeclaration` seals producer geometry against later mutation.
Its seal is not an aperture-exclusion test. No clearance tolerance was changed.

## Construction change

The existing partition topology and ordering remain. Each cell's Y/Z construction
interval is bounded by its intended partition planes and the stored declared
aperture planes. These are shared partition planes across the facade, including
cells above/below or beside the same opening. Stored centers/extents fit inside
those bounds under scalar faces, center/size AABBs and corner-derived AABBs.
The part constructor's minimum dimension is enforced before emission, then the
constructed part is checked. At most 16 construction attempts are permitted;
unrepresentable intervals fail explicitly.

Panels and their declaration are staged before commit. Recessed shell walls and
their facade also stage together. Failure returns through the existing street
house boolean contract, whose production callers reject it. This does not make
the entire street-house builder transactional: earlier house parts can exist
when that builder returns false, as before.

The exact captured before/after comparison preserves all 4,440 part IDs/order,
rooms, aperture inputs/domains/part memberships, and non-partition geometry.
498 partition panels have Y/Z position or extent changes; the largest coordinate
or extent delta is 0.000010251998901367188. Material, collision, rotation, variation
and X geometry remain unchanged. Declaration seals change with their source.
This comparison does not claim complete metadata parity or visual acceptance.

## Evidence

All directories are under `artifacts/citadel-runtime-integration/`.

| Directory | Result and scope |
|---|---|
| candidate21-opening-boundary-01 | Exact original/retained numeric boundary observation |
| facade-partition-geometry-07 | 268 synthetic producer/interval checks, including 64 translated layouts, original cell IDs/order/variation and late-failure atomicity |
| candidate21-aperture-audit-01 | Cold captured snapshot: zero missing declared parts and zero AABB aperture intersections; diagnostic completion only |
| candidate21-opening-ordered-01 | All 16 heads pass with synthetic empty furnishing policy; 16.726 seconds |
| facade-partition-body-01 | Six checks covering all 16 historical captured replacement-body occupancy cases |
| candidate21-policy-capture-01 | Eight checks; exact production structural-call source and policy captured in 47.928 seconds |
| candidate21-policy-capture-01-source | Before/after audit of 1,113 inputs, including production dependencies, engine/native inputs, wrapper, mirror and pinned origin; unchanged file inventory |
| candidate21-opening-policy-01 | Five checks; all 16 heads pass in order with actual captured 178 furniture parts, zero access reservations and production headroom; 17.857 seconds |
| candidate21-facade-delta-01 | Five exact before/after geometry/declaration checks described above |

These successful runs have clean logs, natural exit 0, no forced cleanup and
authoritative owned zero. Policy replay verifies both source and policy immutability.
Node evidence-helper tests pass 3/3, including changed/missing files, file-set
changes, unreadable inventories and swapped origin associations.

Commands use the owned Node runner:

`node tools/run-building-contract.mjs -Contract <Script>.gd -OutputDirectory artifacts/citadel-runtime-integration/<fresh-directory> -ReportEnvironment <ENV> -TimeoutSeconds <seconds>`

| Script | Environment | Seconds |
|---|---|---:|
| CitadelOpeningHeadBoundaryProbe | CITADEL_OPENING_BOUNDARY_REPORT | 30 |
| FacadePartitionGeometryContract | FACADE_PARTITION_REPORT | 45 |
| CitadelFacadeApertureAudit | CITADEL_APERTURE_AUDIT_REPORT | 30 |
| CitadelOpeningHeadOrderedReplay | CITADEL_ORDERED_OPENING_REPORT | 110 |
| CitadelOpeningHeadBodyOccupancyContract | VOXEL_OPENING_HEAD_BODY_OCCUPANCY_REPORT | 90 |
| CitadelOpeningHeadPolicyReplay | CITADEL_ORDERED_OPENING_REPORT | 110 |
| CitadelFacadeProducerDeltaContract | CITADEL_FACADE_DELTA_REPORT | 30 |

Exact policy capture uses
`node tools/run-citadel-structural-policy-capture.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate21-policy-capture-01`.
It checks a generated offline Composer copy differing only by class-name removal
and redirecting the structural dependency to a capture stub. The stub saves the
actual source/policy and returns cancelled, never a publishable result.
Captured policy/source SHA256:
`d6df2eeff4044d85d41cd46e1dc9b200740a01b3abd36455b6536ceb3514a903`.

## Failed attempts and limits

Initial interval tests exposed reconstruction rounding requiring a measured
extent reduction, then corner-derived AABB reconstruction needing its own check.
Those failures were corrected in construction, not hidden by tolerance. Run06
failed parsing a newly added test variable; run07 fixes its explicit type.

Producer capture01 was stopped through its owned watchdog when review required
the transaction/minimum guards. It proves no acceptance. Capture02 exited
naturally with code1: the failed house itself passed, but its broad live-object
lookup check returned false. A separate frozen audit found no geometry hits.
The next exact-policy capture recorded missing/stale `find_part` index examples
while the bounds cache was inactive. The production structural path copies the
source snapshot and rebuilds that index; do not confuse the temporary caller
index with its captured geometry, or report capture02 as passing.

Full candidate construction, independent physical proof, exact site admission,
publication preparation and headed Main.tscn inspection remain required. No
NPC/navigation, gameplay or headed acceptance is claimed here.

Final harsh read-only review returned PASS for the producer change, independently
verifying the 268-check contract, actual-policy ordered replay and geometry delta.
It approved a focused commit followed by one Candidate22 source run at unchanged
540/450/60-second budgets, on the same atlas-3376622889 / (-2,-2) / 1393179273
identity. This is not headed GO.
