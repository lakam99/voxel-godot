# Visual Phase 9 Report

## Scope

Phase 9 gives the HUD a coherent visual identity without changing the 3D renderer or world visuals.

- Added one root HUD theme resource at `res://resources/ui/game_theme.tres`.
- Added `HudStyleFactory` to build shared panel, button, slot, progress, tooltip, dialogue, and label variations from that theme.
- Hid seed, chunk count, coordinates, and build label behind the existing performance/debug HUD toggle.
- Reworked hotbar rendering so slot buttons are created once and updated in place.
- Preserved inventory drag/drop, slot press signals, equipment slots, crafting, utility UI, menus, dialogue, and keyboard shortcuts.

## Verification

- `.\tools\run-playtest.ps1`
  - 150 passed, 0 failed.
  - Added coverage:
    - `debug_readouts_gated`
    - `hud_theme_applied`
    - `hotbar_reuses_slots`
- `.\tools\run-world-signature.ps1`
  - World signature matches `artifacts\baselines\world-signature\atlas-1492.json`.
- `.\tools\run-visual-captures.ps1`
  - Captures written to `artifacts\visual\latest`.
  - Checked `hud_gameplay.png`: normal HUD no longer exposes seed/chunks/coords/build label, and selected hotbar slot has an obvious frame.
  - Checked `forest_midnight.png`: night capture remains readable and 3D visuals were not altered by this phase.

## Notes

- The normal status readout now shows only game title, biome, and time. Debug data returns when the performance/debug overlay is opened.
- Procedural item icons are unchanged; this pass styles their slot frames and drag previews.
- `run-world-signature.ps1` still prints the existing ObjectDB leak warning at shutdown, but exits successfully with a matching signature.
