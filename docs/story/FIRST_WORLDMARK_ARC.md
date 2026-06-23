# First Worldmark Arc: The Storm That Stays

This document defines the first authored vertical slice for the story system.

## Arc Title

The Storm That Stays

## Worldmark

The Gloam Hart, Worldmark of the Ringing Storm.

## Public Belief

The Hart hates fire and is sending creatures to extinguish the frontier
lanterns.

## Hidden Truth

The oldest lantern network contains material taken from the Hart or from a
shrine bound to it. Reactivating the network causes pain, disorients wildlife,
and keeps the regional storm circling.

## Regional Signs

Ordinary signs:

1. Pale antler-shaped scars on trees.
2. Boundary stones that ring or vibrate during rain.
3. Broken lantern equipment pushed away from the forest rather than toward town.

Historical sign:

4. A journal, shrine inscription, or abandoned survey record explaining the old
   compact and the lantern material.

The historical sign unlocks the nonlethal release resolution. Mandatory
preparation alone unlocks combat.

## Arc Flow

1. Complete the tutorial rescue and return inside the lantern perimeter.
2. Dawn arrives, but the storm remains fixed over a distant region.
3. Speak with Mira.
4. Speak with Sera.
5. Travel to the affected forest or taiga region.
6. Discover at least two of three ordinary clues.
7. Discover the optional historical clue to unlock the release route.
8. Prepare a countermeasure using existing crafting and ward systems where
   practical.
9. Retune or repair two boundary stones.
10. Enter the Worldmark encounter.
11. Slay the Hart or release it from the old network.
12. Return to the starter town.
13. Watch settlement and regional aftermath unfold over one or two in-game days.

## Preparation Direction

The first implementation should reuse existing vocabulary where practical:

- `nightShard`
- `wardLantern`
- `surveyLens`
- `wardTonic`
- shrines
- crafting stations

Only add a new countermeasure item if reuse would produce confusing or brittle
behavior.

## Resolution: Slay

Mechanical and narrative consequences:

- greater immediate town confidence and safety
- unique combat-oriented reward or recipe
- fewer hostile events
- wildlife returns more slowly or remains reduced
- some NPCs approve
- some NPCs are unsettled

The slay path must not award the same stewardship/navigation benefit as the
release path.

## Resolution: Release

Mechanical and narrative consequences:

- wildlife and natural ambience return sooner
- nature, traversal, navigation, or stewardship-oriented reward
- the Hart may appear harmlessly in the distance later
- some guards remain concerned
- no trophy weapon equivalent

The release path is available only when the historical clue is known and the
mandatory preparation conditions are satisfied.

## Shared Aftermath

Over one or two in-game days:

- the fixed storm clears
- hostile pressure decreases
- starter settlement moves from tier 0, struggling, to tier 1, secure
- new dialogue appears
- one route or trade link opens
- one service, resident, or work activity appears
- the town records the chosen resolution
- a small celebration, shared meal, repaired public space, or similar cozy scene
  occurs

Aftermath must be communicated through world state and NPC reactions, not a
giant morality score.

## Integration Constraints

- Do not overwrite visual or animation systems.
- Do not add another `Main*.gd` inheritance layer.
- Do not let dialogue strings drive quest authority.
- Do not replace existing objectives or contracts.
- Do not break `SAVE_VERSION == 1` compatibility.
- Do not consume or reorder base world-generation RNG.
- Do not duplicate clues, rewards, NPCs, enemies, or resolution state on reload.
- Do not spawn the Worldmark encounter before the encounter phase.
