# Story Data Contracts

Story systems exchange deterministic facts. Dialogue and generated prose may
decorate these facts, but must never determine mechanics.

## Stable Story Region ID

Story regions initially use the existing `TOWN_REGION_CELLS` grid. Negative
coordinates must use floor division, not truncation toward zero.

```gdscript
var region_x := floori(float(cell.x) / float(TOWN_REGION_CELLS))
var region_z := floori(float(cell.y) / float(TOWN_REGION_CELLS))
var region_id := "r:%d,%d" % [region_x, region_z]
```

## Story Event Envelope

Required envelope shape:

```gdscript
{
    "schemaVersion": 1,
    "type": "landmark_discovered",
    "subjectId": "ruin:12,-8",
    "regionId": "r:2,0",
    "dedupeKey": "discover:ruin:12,-8",
    "worldTime": 1842.5,
    "position": [12.0, 18.0, -8.0],
    "payload": {
        "landmarkType": "ruin"
    }
}
```

Rules:

- `schemaVersion` is currently `1`.
- `type` is required.
- `subjectId` identifies the gameplay entity or fact.
- `regionId` is required for regional events when known.
- `dedupeKey` is required for one-time facts.
- Repeated events may omit `dedupeKey` and update counters instead.
- Events contain facts, not prose.
- Events must be emitted from source operations such as successful discovery,
  crafting, acquisition, placement, interaction, or tutorial completion.
- Events must not be emitted from HUD polling or display refresh.

## Region Story Record

```gdscript
{
    "schemaVersion": 1,
    "generationVersion": 1,
    "id": "r:2,0",
    "regionX": 2,
    "regionZ": 0,
    "seed": 9384234,
    "dominantBiome": "forest",
    "state": "rumored",
    "worldmark": {
        "id": "worldmark:r:2,0",
        "definitionId": "gloam_hart",
        "domain": "storm_and_light",
        "condition": "bound",
        "desire": "silence_the_old_lanterns",
        "publicBeliefId": "gloam_hart_public",
        "hiddenTruthId": "gloam_hart_truth",
        "foundClueIds": [],
        "preparationFlags": {},
        "encounterState": {},
        "resolution": ""
    },
    "settlement": {
        "tier": 0,
        "flags": {}
    },
    "generatedText": {}
}
```

Region records are generated deterministically from stable inputs and then saved.
Once a generated record exists in save data, it must not be silently regenerated
with different facts.

## Story Snapshot

The optional story snapshot is additive save data under the existing save
version. `SaveSystem.SAVE_VERSION` remains `1` until an explicit migration path
is implemented and tested.

```gdscript
{
    "schemaVersion": 1,
    "campaign": {},
    "regionRecords": {},
    "quests": {},
    "settlements": {},
    "processedDedupeKeys": [],
    "generatedText": {},
    "debugRecentEvents": []
}
```

Rules:

- Old saves with no `story` field must load as valid empty story state.
- Story data must be optional and additive.
- Dedupe data must be bounded.
- Debug event history must be capped and non-authoritative.
- Save/load must not replay one-time rewards, clue discoveries, resolution
  choices, NPC spawns, or encounter rewards.

## Quest State

```gdscript
{
    "id": "story.gloam_hart.signs",
    "status": "active",
    "stage": "find_clues",
    "tracked": true,
    "facts": {
        "ordinaryCluesFound": 1,
        "historyClueFound": false,
        "boundaryStonesRetuned": 0
    },
    "optionalObjectives": {
        "learn_old_compact": false
    }
}
```

Quest rules:

- Story quests are separate from `ObjectiveSystem` and `ContractSystem`.
- `ObjectiveSystem` remains broad progression.
- `ContractSystem` remains generic town work.
- Dialogue text must not control quest state.
- Quest transitions must be idempotent.

## Settlement State

Settlement tiers:

```text
0 - struggling
1 - secure
2 - growing
3 - connected
```

Example flags:

```text
trade_route_open
smith_arrived
guard_patrol_active
bakery_open
festival_available
wildlife_returned
remembers_worldmark_resolution
```

Settlement rules:

- No permanent off-screen destruction.
- Settlements may change only through visible events, explicit player choices,
  or reversible simulation states.
- Aftermath must be idempotent and reconstructable from saved state.

## Generated Text Cache

Generated text is cached by stable request key.

The request key must include enough deterministic facts to distinguish the
request, such as region ID, Worldmark definition, NPC ID, knowledge scope, quest
stage, and text purpose.

Generated text may be rejected and replaced by authored templates when:

- JSON is malformed.
- Schema validation fails.
- unsupported mechanics are invented.
- hidden facts leak to an NPC or player-facing text.
- text exceeds length limits.
- the optional provider is unavailable or times out.

Templates are mandatory fallbacks for every text request.
