# Structural support-query replay

BuildingSupportResolutionMemo is used only for private proof copies inside one
CitadelStructuralCompletionRecipe.prepare_later transaction. It reuses sample
support records, never a physical validation report, root reachability, frame,
seat, joint or dependency proof. Existing cancellation callbacks still run.

At each resolve, exact bytes bind the complete ordered finite indexed candidate
pool: ID, position, rotation, size, collision, classified intent and root flag.
Target keys bind ID, geometry, classified intent, required supports, enclosing
support policy and excluded support ID. Duplicate IDs disable reuse. The target
must belong to the current proof. Records are copied on storage and retrieval;
no part objects, shared mutable coverage or saved/global caches are retained.
A changed pool discards prior records. Entries are bounded at10000. Cancellation
during or after resolution clears the transaction map. Use outside resolution
falls back to the original resolver.

## Evidence

All artifacts below are under artifacts/citadel-runtime-integration.

- candidate-recipe-32: observation only, every original query executed. Two
  exact3055-query replays consumed2.080s and2.121s resolver CPU. Identity work
  cost roughly0.11s per proof. Total125.657s; all4555 physical checks passed.
- support-memo-01:23 checks, exact full-source report/snapshot cold and warm,
  returned-coverage mutation isolation,12 changed-input comparisons and
  cancellation during support resolution, validation parts and completion.
  Cold3.015s, warm0.872s. Rotated inputs remain in the complete bound pool.
- candidate-recipe-33:114.527s total,111.012s source preparation,2.871s
  independent physical validation. All4555 physical checks, zero violations.
  Five3055-query replays:15275 hits. First two proofs had6094 misses in total.
  Identity work total0.788s. The independent final proof does not use this memo.
- source-diff-27-32 and source-diff-27-33: only civicClearance/elapsedUsec differs.

Commands:
```
node tools/run-building-contract.mjs -Contract BuildingSupportQueryDifferential.gd -OutputDirectory artifacts/citadel-runtime-integration/support-memo-01 -ReportEnvironment SUPPORT_QUERY_REPORT -TimeoutSeconds 60
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-33 -Seed atlas-3376622889 -CandidateRegion '-2,-2' -ExpectedRecipeSeed 1393179273 -ExpectReady
```

All runs exited cleanly with owned-process zero. Source33 is11.130s faster than
the observation run; the earlier uninstrumented31 run was120.702s. These are
single-run observations, not controlled statistical benchmarks. The source
support checkpoint interval fell to23.936s; intervals are not exclusive CPU
profiles. No90-second or new headed gameplay acceptance claim.

The diagnostic runner retains at most32 support-identity summaries. They do not
enter generated source, acceptance decisions or durable state. The memo was
added only after actual repeated input identities were measured. Neighborhood
reuse across changed candidate pools is not implemented.
