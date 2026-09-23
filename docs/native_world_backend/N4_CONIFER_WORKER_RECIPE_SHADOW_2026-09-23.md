# N4 conifer worker-recipe shadow

`NativeConiferWorkerRecipeBuilder` now composes the already-oracled raw
Norway-spruce grammar and source-space reducer with worker-request
normalization, height/radius adaptation, render LOD reduction, impostor
selection, v10 identity/signature, trunk collider dimensions and selected
interaction facts. This is a pure-core typed result, not a scene recipe or
production tree-publication callback.

The direct `TreeSpawnService.build_recipe_for_worker` Godot oracle covers
young/mature, near/mid/far, review, runtime/review impostor, Unicode
genetic fallback and a defaulted empty grammar. Native tests assert exact
signatures, topology, ordered branch/foliage selections, budgets and sampled
geometry/wind. The empty grammar initially exposed a migration mismatch:
GDScript defaults it to `norway_spruce`; the native boundary now does too.
The focused native worker suite passed 4/4 before that small normalization
addition. The final combined native gate at
`artifacts/native-world-backend/n3-multipage-n4-conifer-worker-02/report.json`
passes 477/477 debug and release tests, adapter smokes, and 100% pure-core
line/function/branch coverage. The direct Godot oracle for the empty grammar
returns the same v10 signature and ordered selection hashes as the explicit
grammar case.

Independent review found this is not yet a drop-in tree recipe: the typed
result lacks `crownHabit`, continuous-bole flags, the full `renderLod` and
`interactionFacts` schemas, and the branch/foliage dictionaries read by
`TreePublicationQueue` and `ProceduralTreeVisualFactory`. Those fields,
scene/render conversion, trunk collision publication and live visual
acceptance remain N4 work. Non-conifer families, nonfinite inputs, malformed
UTF-8 and full Unicode casefold/whitespace normalization are not admitted by
this typed conifer-only API. No production caller or script authority changes.
