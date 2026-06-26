# World Signature Baseline

`atlas-1492.json` is the tracked deterministic world-generation baseline used by `tools/run-world-signature.ps1`.

Do not untrack or delete it as generated save data. Normal signature output belongs under ignored folders such as `artifacts/world-signature/` or `artifacts/test-runners/`.

The runner refuses to compare against a locally modified baseline, and refuses to write generated output directly inside `artifacts/baselines/`. To refresh the tracked baseline intentionally, first investigate the drift, restore or commit any previous baseline decision, then run:

```powershell
.\tools\run-world-signature.ps1 -UpdateBaseline
```
