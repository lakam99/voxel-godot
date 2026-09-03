# Civic house / curtain-wall source failure

Starting checkpoint: clean `codex/citadel-visuals-clean` at `b9c3ed8`.
The previous goal turn made progress: committed source repair and teleport
selection, then isolated a second candidate's source failure in ordinary Main.
The goal remains correct ordinary-game citadel spawning; it is not achieved.

## Exact failure capture

The existing headless public-recipe diagnostic now accepts an explicit world
seed, region and expected recipe seed. Defaults preserve its original candidate.
The production field must agree with the expected recipe before construction.
`CaptureFailure` is separate from `ExpectReady` and caller-blueprint capture.
It uses the existing 450-second source ceiling and 540-second owned watchdog,
with no independent proof. This is a bounded inventoried-failure capture, not
a production or headed timeout change and never recipe success.

The watcher permits one exact inventoried facade-error header across both logs.
It stops on a second header, any unexpected error or warning. Counts reset on
each complete log scan rather than accumulating rereads. Five controls execute
the actual wrapper watcher extracted from its syntax tree, including repeated
polls of one header, duplicate same/other-log headers and unexpected errors.

```powershell
./tools/test-candidate-recipe-error-watcher.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-watcher-01
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-identity-01 -CaptureFailure -CandidateRegion '-1,0' -ExpectedRecipeSeed 1
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-06 -CaptureFailure -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

The identity negative control correctly rejects with `candidate_identity_mismatch`,
zero callbacks, natural exit1 and owned zero. The five synthetic watcher cases
pass; they do not launch Godot or prove source construction.

Critic-approved `candidate-recipe-06` faithfully reproduces the failure in
176.099514s using forest context, scale1.25, site
`citadel-site-v1:14:atlas-30895044:-1,0`. One exact expected engine error, natural
exit0, zero owned processes and unchanged context. All750 measured sources
remained unchanged during this capture. Exit0 means diagnostic reproduction;
both `passed` and `recipePassed` remain false.

Read the full `failure.json` / typed `failure.bin`, not only the compact reason
chain. Also inspect `input.json`, `report.json`, `timings.json`, verification,
source-hash audit, parse/runtime logs and watchdogs under the run directory.
Failure BIN SHA256:
`6d3751c3e08b963dc7f068d5ca00e1524bcfefc73444e99eaa05d2491333bd3c`.

- Failed house: `urban_civic_house_wall`, after one completed house.
- Rule: `no_clear_connection_in_socket_domain` in opening-head completion.
- Gable: `urban_civic_house_wall_upper_shell_side_-1`.
- Nine attempted connection positions, all blocked by `castle_right_wall_wall`.
- Each reports greatest-axis gap `-0.399995595216751m`; this is real overlap,
  not precision noise. It is not the required displacement of the whole house.
- Direct masonry-seat alternative reports `no_direct_masonry_geometry`.

Static producer inspection finds fixed civic-house center X56 while the curtain
position derives from seeded courtyard width. A correction must use actual
transformed geometry and complete house extents, preserve already-clear layouts,
and avoid neighbours/access/civic props before dependent rooms, doors and
furniture are generated. Connection admission and terminal physical validation
must remain unchanged. No production placement change or successful spawn is
claimed by this diagnostic checkpoint. No headed retry is approved.
