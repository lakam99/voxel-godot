# Remaining support-query repetition

At bebacba, the latest headed citadel scene-ready observation is 161.035s.
The 90-second usable-arrival target remains unmet. This investigation changes
no production behavior and does not claim a load-time improvement.

## Rejected small changes

Evidence directories below are under artifacts/citadel-runtime-integration.
masonry-guard-cost-02 replayed final source39 through ordinary publication
evaluation before preparing masonry. Omitting the second metadata walk for
standard BuildingPart instances reduced three passes over 1,438 guards from
0.839s to 0.554s. This does not explain the larger publication cost and was not
promoted. masonry-guard-cost-01 omitted evaluation and its derived physical
metadata; its smaller timings do not represent the production guard workload.

typed-support-cost-01 compared current physical validation to an artifact-only
copy with explicitly typed candidate loop variables. It was slower: 2.303s
versus 2.184s. Both report and resolved-snapshot bytes matched. No typing change
was promoted. All diagnostic launches exited cleanly with owned zero.

## Full source observation

candidate-recipe-40 ran the production source generator with a temporary,
opt-in observer around support resolution. The observer generated identities
after classification/indexing, using the existing memo's ordered candidate and
target fields, with duplicate-ID eligibility. Canonical record encodings were
hashed only for diagnostic grouping. Production reuse would require exact
bindings; these hashes are not authority.

Each completed proof emitted one bounded JSONL record with its query identities,
resolution times, implementation and one stack capture. Identity construction,
stack capture and file writing were outside the query timer. No result was
reused or altered. All temporary BuildingBlueprint changes were removed after
owned-zero termination; git diff then showed no production change.

The Node candidate runner used the ordinary pinned seed atlas-3376622889,
region -2,-2, recipe seed 1393179273, output candidate-recipe-40 and -ExpectReady.
Its wrapper supplied CITADEL_POOL_TRACE pointing at the absolute
artifacts/citadel-runtime-integration/support-pool-trace-01.jsonl path.
The artifact helper is support-local-observation-src/PoolProbe.gd.

The trace contains 192 completed proofs, with no cancellation or truncation:

- Support resolution: 17.316662s.
- Identity construction: 0.908968s, excluding stack capture and file writing.
- Hash-matched repeated queries: 24,437, taking 5.884041s including already
  memoized calls. This is not an achievable speedup estimate.
- Repetition outside BuildingSupportResolutionMemo: 3.169779s. Almost all is
  concentrated in two calls: row 185, MasonryPartyWallBearingRecipe.prepare_context,
  3,055 queries / 1.593825s; and row 188, CitadelBuntingAnchorRecipe._prepare,
  3,055 queries / 1.571880s.

Both calls have the same ordered structural-candidate and target identities as
the preceding memoized proof. The bunting proof removes declared dressing, but
the measured structural pool remains unchanged. This does not authorize reusing
rootedness, dependency checks or whole validation reports. Those must continue
to run on the dressing-removed proof.

Memo row 150 also repeats an earlier pool, spending 1.842752s on its first call.
Reusing across that earlier facade boundary would require broader ownership
work; it is outside the proposed initial change. The other uncached repetitions
total about four milliseconds and are not worthwhile targets.

source-diff-27-40 found only civicClearance/elapsedUsec changed. Source40's
physical.json exactly matches source39's. The instrumented run and comparison
terminated cleanly with owned zero. Instrumented wall time is not a production
performance measurement, and no additional headed run was appropriate after
restoring the unchanged implementation.

The next candidate is scoped reuse of the existing private completion memo for
the party-wall and bunting proof copies, preserving fresh public defaults,
exact pool/target bindings, cancellation and independent root/dependency checks.
It remains a proposal pending implementation and verification.
