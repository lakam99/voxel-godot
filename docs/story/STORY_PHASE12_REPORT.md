# Story Phase 12 Report

## Changed files

- `scripts/story/campaign/FrontierCampaignSpine.gd`
- `scripts/story/StoryDirector.gd`
- `scripts/story/testing/StoryPlaytestRunner.gd`
- `docs/story/STORY_PHASE12_REPORT.md`

## New story system responsibilities

- `FrontierCampaignSpine` is the finite campaign-state layer above regional Worldmark stories.
- It defines the three-act campaign structure:
  - Act I: Beyond the Lantern Line.
  - Act II: The Far Roads.
  - Act III: The Old Compact.
- It owns authored anchor revelations for the old frontier network and Old Compact.
- It deterministically selects finite anchor regions from the world seed without requiring every generated region for campaign completion.
- It tracks recurring-character records, relationship scores, encounter counts, and stable memory flags.
- It marks campaign completion while keeping `endlessWorldContinues` and `regionalStoriesEnabled` true.
- `StoryDirector` composes the campaign spine as a child node, forwards story events to it, and includes it in debug/snapshot/restore data.

## Event hooks added

- No HUD polling hooks were added.
- `StoryDirector.ingest_event()` now forwards accepted source events to `FrontierCampaignSpine`.
- Campaign spine milestone events:
  - `tutorial_final_rescue_complete`
  - `story_worldmark_resolved`
  - `campaign_anchor_reached`
  - `campaign_revelation_found`
  - `recurring_character_met`
  - `recurring_character_memory`
  - `campaign_principles_chosen`
- The test verifies post-campaign `story_region_entered` events still ingest and count normally.

## Save/load behavior

- `SAVE_VERSION` remains `1`.
- Campaign spine data is optional under `story.campaignSpine`.
- Old saves without `story.campaignSpine` restore to default empty campaign spine state.
- Campaign act, anchors, revelations, recurring-character memory, selected principles, completion state, and endless-play flags round-trip through the existing save snapshot.
- Regional records still generate after campaign completion.

## Deterministic test results

- `.\tools\story\run-story-playtest.ps1 -ReportPath artifacts\story\phase12-story-playtest-report.json`
- Result: passed, 45 results, 0 failures.
- Added `phase12_campaign_spine_progression_and_endless_play`.
- The Phase 12 regression verified 4 deterministic anchors, stable reselection, act progression through Act I/II/III/post-campaign, campaign completion, recurring-character memory, save/load equality, no prophecy/bloodline framing, and post-campaign regional event ingestion.

## Playtest result count/failures

- `.\tools\run-playtest.ps1 -ReportPath artifacts\story\phase12-playtest-report.json`
- Result: passed, 166 results, 0 failures.

## Risks and TODOs

- Phase 12 provides campaign-state and authored anchor infrastructure; it does not yet add bespoke world props, UI screens, or bespoke quest chains for the Act II and Act III anchors.
- Anchor events currently rely on source systems or future content to emit `campaign_anchor_reached` and related campaign events.
- The broad playtest still logs existing NPC freed-instance/ObjectDB shutdown warnings; the JSON report passes with 0 failures.
