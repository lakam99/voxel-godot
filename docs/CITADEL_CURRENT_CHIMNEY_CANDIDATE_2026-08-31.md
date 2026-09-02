# Current accumulated chimney bearing candidate

Input is the critic-accepted lower-bearing candidate
`300d1f30da4701fbf477244d81858c904d4f9dc5a5822db728e6059a003d2b8b`
with57 physical failures and all152 original furnishings.

`chimney-current-candidate-01` is diagnostic RED only: it measured11 viable and
3 blocked current failed chimneys and57 ->46/no-added, but expected only the
later duplicate-bearer rejection. Applied chimneys become non-plain first, so
the actual fail-closed reason is `incompatible_chimney`. No candidate was written.

The corrected test accepts only `incompatible_chimney` or
`chimney_bearing_already_present` and requires exact staged-snapshot immutability.
`chimney-current-candidate-02` passes: exactly14 failed chimney IDs selected,
11accepted,3 explicit `bearer_intrudes_source`,57 ->46, no added failures,
all accepted chimneys/bearers pass, furniture/reservations and prior archive
fields exact, functional0/empty stderr/owned cleanupzero. Output SHA:
`8e8b41ee3154f752ecbba63f3678413a88526008b72bf904bcbf8cfb3f575f59`.

This is source-only candidate evidence. No integration, publication, rendered
appearance, engineering load, gameplay, NPC/navigation or headed acceptance.
