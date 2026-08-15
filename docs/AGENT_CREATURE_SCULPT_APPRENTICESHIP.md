# Agent Creature Sculpt Apprenticeship

This workflow creates authored NPC clothing, hair, and creatures. It is not used for procedurally generated trees or for the existing runtime tree pipeline.

## Purpose

An agent must not export a creature because it has executed Blender operations. It must first establish species-correct anatomy in untextured clay renders, receive an independent critique against the supplied references, revise the actual mesh, and repeat until the critic accepts the anatomy.

## Roles

| Role | Responsibility |
| --- | --- |
| Apprentice | Builds the mesh in Blender, records decisions, applies revisions, and never self-accepts an asset. |
| Veteran critic | Uses the references and review renders to identify proportion, silhouette, landmark, and surface-form failures. The critic is intentionally independent of the builder. |
| Asset gate | Admits an export only after the critic accepts the clay anatomy, the native-sculpt proof is non-zero, and runtime requirements are completed. |

## Required Inputs

1. A reference pack with a side view plus at least one additional useful view.
2. A brief containing pose, scale, intended game role, and prohibited readings.
3. A landmark sheet naming cranial, spine, limb, and paw landmarks before geometry is built.
4. A review scene that produces front, side, rear, top, and three-quarter clay renders under neutral lighting.

## Regional Anatomy Evidence

Before revising a body region, build a compact evidence pack for that region rather than relying on whole-animal photographs alone.

1. Combine live species-matched photographs, weight-bearing closeups, and skeletal evidence. Muscle diagrams may explain landmarks but never overrule live silhouette evidence.
2. Tag every source by species/subspecies, region, view, pose, age/body condition when known, source URL, license, and modeling purpose.
3. Normalize selected references to at most 1600 pixels, hash-deduplicate them, and generate one regional contact sheet. Do not retain bulk full-resolution downloads.
4. The apprentice receives the regional sheet while editing. The critic receives the same regional sheet plus whole-animal targets and identical clay views.
5. Record conclusions as named landmarks and measurable relationships in the learning journal. Images support decisions; they do not replace the written anatomical rule.
6. Image generation is hypothesis visualization only. It is never anatomical authority.

For the brown bear, the required packs are `face`, `shoulders`, `forelegs`, `feet`, `back`, `rear`, `legs`, and `skeleton`. Rebuild them with `tools/blender/build_bear_anatomy_reference_library.py`.

## Apprentice Loop

1. **Landmarks** — Choose a neutral weight-bearing pose and establish the skull, eye, ear, shoulder, chest, pelvis, limb-joint, paw, and tail-root locations. Stop if a landmark is a guess that cannot be justified from a reference.
2. **Primary forms** — Build a continuous anatomical mass. Construction volumes may be used only as disposable scaffolding; the reviewed result must not read as assembled primitives.
3. **Secondary forms** — Establish bone planes, sockets, joints, pads, creases, and compression. Do not add fur, color, wrinkles, accessories, or dramatic lighting to conceal incomplete anatomy.
4. **Clay review** — Render all five required views. Check framing before critique; a cropped head or paw is a failed review, not a pass by omission.
5. **Veteran critique** — Supply the references and every clay render. The critic returns `REJECT` or `PASS`, a detailed difference list, and a prioritized revision list.
6. **Revision** — Change the source mesh only. Record what changed, re-render the complete set, and return to critique. No export, retopo, rig, texture, or runtime integration occurs while the status is `REJECT`.
7. **Admission** — After a `PASS`, perform and verify a native Blender Sculpt Mode operation, then retopologize, UV unwrap, rig, export, and run Godot validation as separate stages.

## Frozen Checkpoint Contract

Once the user and critic identify the strongest whole-creature checkpoint, preserve it as the comparison authority. Record its protected landmarks and reject any descendant that weakens them, even when topology metrics improve.

For the bear, permanent locks include the muzzle projection, nasal bridge, nose pad, forehead stop, brow, eye sockets, cheek, jowl, jaw, chin, ear roots, cranial width, neck ruff, withers, scapular plane, chest break, ribcage, belly, pelvis, rump, tail root, elbows, wrists, hocks, and weight-bearing limb taper. Global smoothing or global remeshing after this lock is prohibited.

Before every procedural sculpt operation:

1. Normalize object transforms or explicitly convert every sample and target into one declared coordinate space.
2. Define the editable anatomical crop and prove zero displacement outside it.
3. Perform one anatomical operation only.
4. Compare against the frozen checkpoint in identical views.
5. Reject the operation if silhouette or landmark hierarchy regresses.

For high-risk local work, split the operation into two critic gates:

1. Create a geometry-free preflight that colors the exact faces or vertices selected by the proposed mask.
2. Render that mask from every camera capable of revealing accidental scope.
3. Require critic approval of the mask before applying displacement.
4. Store the approved face indices on the source object and do not remask during the sculpt pass.
5. Report maximum displacement, outside-mask displacement, boundary displacement, and topology-defect delta.

Coordinate bounds describe intent but do not prove visible-surface selection on fused or layered meshes. Use BVH first-hit tests from the actual evidence camera direction when overhangs, internal sheets, or overlapping forms can satisfy the same coordinate gate. Displace along a declared fixed direction or fitted target field unless mesh normals have been independently validated for that crop.

## Critic Standard

The critic rejects an asset if any clay view reads as a generic mammal, a person in an animal suit, an assembled primitive, or a mesh that works only from one camera. For a brown bear, the critic specifically checks a low short neck, cranial wedge, broad shoulder hump, front-heavy thorax, rounded pelvis, articulated limbs, plantigrade paws, recessed eyes, small rear-set ears, and a silhouette that survives thumbnail scale.

## Authority Before Repair

Before any local sculpt or retopology, render object-ID evidence from side and both three-quarter views. Ray hits are advisory only: overlapping anatomy and internal fused shells can make outside-in and center-out samples select the wrong surface. A mask must identify the visible owning object, remain bilateral where appropriate, and avoid every locked silhouette and anatomical junction.

If two bounded displacement attempts reproduce shelves or terraces, stop that branch. If an excision boundary crosses inherited nonmanifold or folded topology, do not force a patch onto it. Escalate to a larger trustworthy domain. For a defective trunk this means a separately authored watertight cross-section cage, validated against orthographic silhouettes, with locked head and limb vertices remaining byte-for-byte unchanged.

Replacement order is mandatory: construct the new authority, prove watertightness and anatomical coverage, prove all overlaps are hidden in side/front/rear/top/ventral and both three-quarter views, and only then remove superseded source faces. Rectangular centroid deletion, Boolean concealment, and coincident-shell acceptance are prohibited.

Before preserving a body part from a fused sculpt, prove that it has a closed, seed-connected, anatomically placed extraction loop. Sweep candidate frontiers through the intended cut band and reject loops that merge limbs, include chest or belly sheets, self-intersect, or appear in review-camera first hits. If limb seeds merge into the body before a valid bilateral loop appears, treat the fused part as non-extractable and rebuild the complete part as a branch of the clean continuous body cage.

For a realistic brown-bear forelimb, measure shoulder-to-ground length from the shoulder center. Shoulder-to-elbow is `0.31–0.36L`, elbow-to-carpus is `0.36–0.41L`, and carpus-to-ground is `0.08–0.12L`. Relative to shoulder width, the upper arm is `0.78–0.88`, elbow `0.70–0.80`, proximal forearm `0.48–0.58`, distal forearm `0.38–0.46`, carpus `0.31–0.40`, and paw `0.42–0.50`. The paw is also `1.15–1.35` times distal-forearm width and `0.90–1.10` times proximal-forearm width. These relationships are anatomy gates, not permission to use visible cylinders; the shoulder, axillary saddle, olecranon, forearm taper, heel, and toe fan must still read as continuous sculpted form.

## Study Retention

After every completed critic cycle, run `python3 tools/blender/prune_bear_studies.py --apply`. Preserve the learning journal, this pipeline, modeling scripts, all JSON reports, accepted milestone `.blend` authorities, and only the latest active diagnostic. Rejected and superseded `.blend` files and full-resolution review renders are temporary evidence and must not accumulate. A failed branch is summarized in the journal before its heavy payload is removed.

## Evidence And States

Studies live under `assets/art-source/<asset-id>/studies/<iteration>/`. Every study contains its `.blend`, all clay renders, a report, and a linkable journal entry.

| State | Meaning |
| --- | --- |
| `pending_critic_review` | A clay study exists but has not been independently judged. |
| `rejected` | The critic identified material anatomy or review failures. This output is training evidence, not a source asset. |
| `anatomy_approved` | The critic accepted the untextured mesh. Retopo and rig may start. |
| `production_approved` | Native sculpt proof, retopo, rig, export, and runtime validation also pass. |

## Journal Discipline

After every critique, add an entry to the asset journal with the iteration, evidence, decision, observed failures, mesh changes, and a reusable rule. Do not write vague statements such as "improved anatomy." A useful entry says what landmark or silhouette was wrong, how it changed, and whether the next render proved the change.
### Continuous Section Fields

- Sculpt deformations that cross a torso, garment, or hair mass must be parameterized in the native section coordinates: longitudinal station and circumferential angle. Do not deform by world-space height when the intended form follows an anatomical quadrant.
- A `smootherstep` interpolation applied independently between every control pair is not a true spline: it forces zero derivative at every knot and can create repeated ribs or scallops under raking light. Use monotone cubic Hermite tangents with zero derivatives only at intentional boundaries or extrema.
- Blend section exponents continuously. Hard switches between dorsal, lateral, and ventral exponents create latitude seams even on dense watertight cages.
- Validation geometry is not sculpt authority. A damaged predecessor can provide a binary occlusion mask, but fitting the replacement to it copies shelves, channels, and nonmanifold artifacts into the new surface.
- Numeric clearance never overrides visual curvature. Require isolated silhouette, raking-light, topology, lock-displacement, and binary overlap evidence as separate gates.
# Artifact Retention

- Preserve compact knowledge: the learning journal, critic decisions, machine-readable reports, generator scripts, and named source authorities.
- Treat rejected `.blend` files and review renders as a bounded cache, not project history. Delete them after their reproducible lesson and measurements are recorded.
- Keep heavy payloads only for named authorities, irreplaceable rejection evidence, and the latest open iteration. Use `tools/blender/prune_bear_studies.py --apply` at closed critique boundaries.
- Measure the studies directory before starting another expensive branch. Unexpected growth blocks further generation until the cache is pruned or the retained payload is justified.
