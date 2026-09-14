# World streaming maturity Gate 0 snapshot

Date: 2026-09-14
Gate status: **COMPLETE**
Implementation status: **UNTESTED WIP PRESERVATION; NOT RELEASE-READY**

## Preserved state

- Active worktree: `C:/Users/arkam/Documents/Codex/2026-06-18/goal-develop-a-3d-voxel-seed/outputs/voxel-biome-world-godot-citadel-visuals`
- Source branch: `codex/world-streaming-architecture`
- Source HEAD before snapshot: `d69323d5780d3baf3a0b9f6710a6b7478d0bafb8`
- Snapshot commit: `94d823cdbad8425553c0a76b3f4e4fc5f2d662a3`
- Snapshot commit message: `WIP: preserve all Citadel streaming work before maturity migration`
- Migration branch: `codex/world-streaming-maturity-migration`
- The migration branch was created from the snapshot commit in the same worktree. `git merge-base --is-ancestor 94d823cdbad8425553c0a76b3f4e4fc5f2d662a3 HEAD` exited zero immediately after the switch.
- The sibling app checkout, master checkout, detached controls and other worktrees were not staged, switched, edited, reset, cleaned, pushed or merged.

## Pre-snapshot inventory

The exact path inventory is recoverable from:

```powershell
git show --stat --summary 94d823cdbad8425553c0a76b3f4e4fc5f2d662a3
git show --name-status --format= 94d823cdbad8425553c0a76b3f4e4fc5f2d662a3
```

Before staging:

- 13 tracked files were modified.
- 200 files were untracked: this migration plan, `scripts/world/GeneratedContentViewPriority.gd`, and 198 `.gd.uid` files.
- The tracked diff contained 438 insertions and 96 deletions.
- No deletions were present.

After `git add -A`, the staged snapshot contained 213 files: 13 modified and 200 added, with 1,030 insertions and 96 deletions. `git diff --cached --check` passed. A focused staged-content scan found no private-key blocks, credential assignments, authorization headers, GitHub token patterns or OpenAI-style secret-token patterns.

Ignored artifacts and native build caches remained in place and were not force-added. No Node or Godot process with this worktree in its command line was active before staging.

## Native dependency and binary identity

All hashes are SHA-256.

| Input or binary | Bytes | SHA-256 |
|---|---:|---|
| `native/terrain_meshing/godot-cpp-revision.txt` | 41 | `8fb9243c859ca35fb5406d6e3395ad0b2540cd90bb92ee0082d882c61305ecbc` |
| `native/terrain_meshing/SConstruct` | 1,564 | `f77b3e401edf33b4eef30ba43677ec0f9905307e71e2715459df0359f6802cbd` |
| `native/terrain_meshing/godot-cpp/gdextension/extension_api.json` | 6,965,055 | `53d37f85be32b6d10fb2266ca51f6ef0c3a55728acdb7c8301b1458a93c00943` |
| `addons/terrain_meshing_backend/terrain_meshing_backend.gdextension` | 880 | `6d4c88bb6d02b3a302e5907528c82310a1213c75b17a2ee0b7c6d391e26355c1` |
| Debug DLL, native and installed copies | 485,376 | `50e6004d539dff92f30e136f9a6298a32e4f3fda84dd522907015d8ee31e4571` |
| Release DLL, native and installed copies | 456,192 | `fb02febd19cc41ad32f0b9a793ce67689cb0ce290d01152d4979e7abc14959ee` |

The pinned revision file and nested `godot-cpp` checkout both resolve to `ba0edfed90512ec64aba51d4295a3e7e30112f86`. The nested checkout reported `master...origin/master` with no local changes.

## Known failures preserved with the snapshot

- The primary fixed-seed approach report remains performance-rejected: presentation p50 358.3 ms, p95 508.1 ms, p99 550.6 ms and max 579.216 ms, with 83 of 150 intervals above 100 ms.
- The same report labels the service scene ready while publication remains incomplete: 4,094 of 4,098 physical groups complete, four deferred, `packet_wait`, and `sceneReady=false`.
- Three civic recipe assertions were already known to fail identically at detached `d69323d` and the candidate: `streetRecipeRecordsByteExact`, `independently_clear_street_layout_retains_full_legacy_parity`, and `commons_recipe_tracks_generated_row_and_clears_two_seed_layouts`.
- The snapshot includes incomplete, not performance-accepted streaming work and generated UID files by explicit Gate 0 instruction. It must not be described as tested or promoted.

## Commands and evidence

Read-only inventory and verification commands:

```powershell
git worktree list --porcelain
git branch --show-current
git rev-parse HEAD
git status --short --branch
git diff --stat
git ls-files --others --exclude-standard
git show-ref --verify --quiet refs/heads/codex/world-streaming-maturity-migration
git diff --cached --stat
git diff --cached --name-status
git diff --cached --check
git -C native/terrain_meshing/godot-cpp rev-parse HEAD
git -C native/terrain_meshing/godot-cpp status --short --branch
```

State-changing commands authorized by Gate 0:

```powershell
git add -A
git commit -m "WIP: preserve all Citadel streaming work before maturity migration"
git switch -c codex/world-streaming-maturity-migration
```

Existing ignored evidence remains under `artifacts/citadel-runtime-integration/`, including the fixed-seed reports named in the migration plan. This checked-in record is the compact Gate 0 evidence summary if ignored artifacts are unavailable.

## Evidence limits and next action

Gate 0 deliberately ran no compilation, contract suite, headed playtest or performance benchmark. It proves preservation, branch ancestry and a clean handoff point only; it proves no gameplay, visual, collision, navigation or performance behavior.

Before G1 implementation, freeze the new branch source, compile it, and run the applicable unchanged NPC regression baseline required by `MANIFESTO.md`. Begin with the preserved bad-run evidence and G1A movement attribution. Do not patch protected route, motor, door-execution or traffic behavior without additional explicit scope.
