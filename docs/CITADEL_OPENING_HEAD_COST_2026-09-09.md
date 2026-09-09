# Opening-head source cost investigation

Production remains at 1ffc04e; no cache or source behavior changed.
The existing pinned opening producer was replayed with an empty furnishing
policy, as in CitadelOpeningHeadOrderedReplay. This is component evidence,
not complete candidate or gameplay acceptance.

Input: candidate21-opening-producer-02/input.bin under
artifacts/citadel-runtime-integration, SHA-256
36ba4b715af39c9fad9cffcd7953c5f591afba1881daee61cedc6addf242bd80.

An artifact-only copy of OpeningHeadBandRecipe substitutes a diagnostic
Blueprint subclass. It always calls the original support resolver; no result
is reused. It records ordered candidate fingerprints for every distinct grid
origin touched by the target's actual bottom samples, plus target inputs.
This observes possible local repetition, not a validated production cache key.

```text
node tools/run-building-contract.mjs -Contract res://artifacts/citadel-runtime-integration/support-local-observation-src/Run.gd -OutputDirectory artifacts/citadel-runtime-integration/support-local-observation-02 -ReportEnvironment LOCAL_SUPPORT_REPORT -TimeoutSeconds 120
```

The first run, support-local-observation-01, passed three checks, clean owned
zero: baseline ready, observed ready and complete byte-identical result.
1387 support queries included 174 repeated local identities. Those repeated
resolutions cost only 61.7ms against 133.5ms identity overhead and 23MB of
retained hex key characters. Baseline was 8.458s; observed was 8.656s.
This rejects that proposed optimization for this stage.

Run02 added section timers to the same artifact copy and again passed all
three checks with clean owned zero. Baseline 8.584s, observed 8.746s:

| Measured section | Seconds |
| --- | ---: |
| ReplacementAdmission.evaluate | 4.071 |
| Connections.prepare | 1.007 |
| Foreign-solid admission | 0.725 |
| All observed support resolution | 0.490 |
| Piece clearance | 0.132 |

These are component wall timings, not exclusive profiler totals. They cover
only this historical producer and synthetic empty furnishing policy. Complete
result parity rules out diagnostic output changes, not all timing interference.
The two observed runs retained every physical and clearance decision.

Next inspect OpeningHeadReplacementAdmission.evaluate and its occupancy/seam
coverage work for repeated full-source transforms or volume subdivision. Do not
weaken foreign-solid, aperture or unchanged-volume witnesses. No additional
headed run is warranted until a falsifiable production improvement is ready.
The latest headed arrival remains about 171s; the 90s goal remains open.
