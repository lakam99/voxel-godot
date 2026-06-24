# Story Phase 13 Report

## Changed files

- `scripts/story/text/NarrativeTextProvider.gd`
- `scripts/story/text/TemplateNarrativeTextProvider.gd`
- `scripts/story/text/LocalLlmNarrativeTextProvider.gd`
- `scripts/story/testing/Phase13NarrativeTextProviderTests.gd`
- `scripts/story/StoryDirector.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE13_REPORT.md`

## New story system responsibilities

- `NarrativeTextProvider` defines the structured request contract, stable request key, deterministic template text, strict JSON response validation, length checks, hidden-fact leakage rejection, unsupported-claim rejection, and stable text hashing.
- `TemplateNarrativeTextProvider` covers every current text request purpose with deterministic authored fallback text.
- `LocalLlmNarrativeTextProvider` is optional and disabled by default. It accepts validated local responses, caches accepted prose by stable request key, and falls back to templates when unavailable, timed out, malformed, or unsafe.
- `StoryDirector.narrative_text()` routes requests through the configured provider and persists accepted text in existing `story.generatedText.narrativeText`.
- `Phase13NarrativeTextProviderTests` keeps provider-contract tests out of the broad playtest runner.

## Event hooks added

- No gameplay event hooks were added in Phase 13.
- No HUD polling hooks were added.
- Narrative text generation is request-driven and does not control quest state, rewards, locations, item costs, NPC life state, boss stats, or other mechanics.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- Accepted local prose is cached under optional `story.generatedText.narrativeText`.
- Missing service and rejected output do not change gameplay state and do not require save migration.
- Cached accepted prose round-trips through existing save/load behavior by stable request key.

## Deterministic test results

- `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase13-story-playtest-report.json`
- Result: passed, 46 results, 0 failures.
- Phase 13 coverage:
  - template coverage for rumor, dialogue variant, Worldmark title, journal prose, letter, aftermath reflection, settlement flavor, and site discovery;
  - service disabled fallback;
  - timeout fallback;
  - malformed JSON fallback;
  - schema failure fallback;
  - hidden-knowledge leakage rejection;
  - unsupported claim rejection;
  - accepted local text caching;
  - save/load cache stability.

## Playtest result count/failures

- `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase13-playtest-report.json`
- Result: passed, 166 results, 0 failures.
- The broad suite ran with no local companion service available; gameplay remained fully playable.

## Risks and TODOs

- No HTTP or socket companion service was required for this phase, so no RedWeb service was added.
- The local provider currently uses a test-injectable local response path rather than a live model process.
- Future companion work must keep the same strict JSON validation, local-only binding, short timeout, cancellation, and deterministic template fallback rules.
- The broad playtest still logs existing NPC freed-instance/ObjectDB shutdown warnings; the JSON report passes with 0 failures.
