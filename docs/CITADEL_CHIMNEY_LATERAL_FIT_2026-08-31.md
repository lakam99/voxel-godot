# Citadel chimney lateral-fit source milestone

The sole gate-one failure was not the chimney, roof, gables, furniture, or
navigation. The generated `urban_street_banner_01` crossed the centered attic
bearing corridor. Ignoring that noncolliding banner would create visible
interpenetration, while moving it would regress an authored visual transform.

`ChimneyBearingRecipe` now keeps the historical centered full two-gable member
first. When blocked, it derives lateral candidate centers from every source and
protected bound that overlaps the bearing's YZ slab. Candidates retain the full
timber width and are bounded by a minimum0.06m half-patch at the chimney and each
gable. Ranking is smallest absolute shift, then stable lower coordinate. Existing
one-gable fallback remains after all two-gable fits. No house, banner, seed, or
coordinate is named by the recipe.

The exact accepted fit shifts the hidden bearer -0.184125m. Its X bounds become
approximately6.370..7.090 while the unchanged banner remains7.140..7.260. The
chimney overlap remains approximately0.536m. The chimney, banner, roofs, gables,
facades, furniture and reservations do not move.

Evidence:

- `chimney-bearing-lateral-07`:233/233 source/service checks. Centered fixtures,
  obstruction on either side, deterministic reversed ordering, finite rooted
  seats after apply, and no-valid-offset atomic rejection all pass.
- `chimney-current-candidate-04`: exact SHA-bound accumulated candidate moves
  from one failure to zero, adds exactly one bearer, changes only the chimney
  seat declarations, and adds no failure or violation.
- Input SHA:
  `4a428f1dfc4b7302e2f4d3fd07b84c0610a45446fcdb8fa9c9fc0aa15714b800`.
- Gate-zero candidate SHA:
  `2bfd4b30123589b4ebe1d3a51c0cd3e525552c217dda594d45472b9903c0c05b`.
- Both credited runs: functional exit0, empty stderr, no timeout/forced cleanup,
  authoritative owned-process zero and clean cleanup.
- Protected NPC/navigation diff remains empty.

This is source-only. It does not prove ordinary-composer integration, published
mesh/contact, rendered roof appearance, engineering capacity, gameplay,
navigation, performance, or headed acceptance. No headed test was run. The
independent critic accepts the narrow source gate-zero evidence.
