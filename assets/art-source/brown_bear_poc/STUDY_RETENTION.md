# Brown Bear Study Retention

The learning record is the journal, scripts, reports, and critic decisions—not hundreds of duplicate `.blend` files and full-resolution review renders.

Heavy payloads are retained only for milestone authorities and the current open iteration:

- iteration 058: preferred facial/profile source
- iteration 182: frozen whole-bear authority (`iteration-182-continuous-forepaw-planes`)
- iteration 246: accepted forepaw digits
- iteration 253: accepted forelimb root
- iteration 274: accepted ears
- iteration 284: accepted mouth/lower lip
- iteration 289: current accepted whole-bear source
- iteration 513: accepted shoulder authority
- iteration 531: accepted forelimb/carpus authority
- iteration 589: accepted grounded forepaw load envelope
- iteration 663: critic-approved forepaw primary-form authority
- iteration 670: critic-approved hindlimb primary-form authority
- iteration 672: critic-approved pelvis/rump primary-form authority
- iteration 674: critic-approved hindquarter placement authority
- current open iteration: active diagnostic only; once accepted or rejected, preserve its report, script, critic decision, and only the minimum representative renders

Every iteration keeps its lightweight JSON reports. Modeling scripts remain the reproducible transformation history, and `LEARNING_JOURNAL.md` summarizes critic findings and failed branches.

Run after a critic cycle:

```bash
python3 tools/blender/prune_bear_studies.py --apply
```

Run without `--apply` to preview reclaimable bytes. The script never removes Markdown, JSON, Python, or the pinned milestone payloads.

For a closed rejected latest iteration, remove its `.blend` files and yaw sweep after copying two or three decisive failure renders into its root. The journal is the durable learning authority; duplicate renders and reconstructable Blender payloads are not.
