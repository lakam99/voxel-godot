# Story Canon

This document captures the narrative constraints for Voxel Biome World story
work. It is authoritative for later story, quest, Worldmark, dialogue, and
procedural text implementation.

## Core Fantasy

Venture into the unknown, understand what has claimed the land, and make
civilization possible again.

The player improves the frontier through practical work: repairing, building,
feeding people, mapping routes, learning the land, protecting others, and
resolving regional threats.

## Tone

The intended tone is cozy but dangerous.

Towns are warm, practical, and human. The wilderness is beautiful, lonely,
mythic, and sometimes frightening. The game is not grimdark.

Coziness must be shown through concrete town life:

- meals
- repairs
- letters
- useful work
- celebrations
- returning wildlife
- ordinary residents living more safely

Coziness must not be represented only by reducing danger.

## Player Identity

The player is not important because of prophecy, bloodline, lineage, hidden
royalty, secret cosmic titles, or chosen-one framing.

The player becomes important by doing useful work and earning trust. Keep the
player's past lightly defined unless the user later chooses a specific
background.

## Civilization And Wilderness

Civilization is fragile, but it is not automatically morally correct.

The wilderness is dangerous, but it is not automatically evil, empty, or waiting
to be conquered. Some regional conflicts must be caused or worsened by old
settlements, old technology, broken agreements, or current human mistakes.

The player builds safety through understanding and stewardship, not only through
combat.

Prohibited framing:

- wilderness equals evil
- towns are always right because they are towns
- every strange creature must be slain
- every regional problem is solved by conquest
- rebuilding means erasing the non-human world

## Worldmarks

A Worldmark is both a regional entity and the mark its presence leaves on the
land.

A Worldmark must causally affect at least one gameplay-facing regional system:

- weather
- ecology
- enemies
- landmarks
- settlement behavior
- resources
- travel

A Worldmark is not merely a random boss in a room. Not every Worldmark is evil.
Some may be slain, healed, released, relocated, bound, or bargained with.

Every Worldmark must define:

- domain
- condition
- desire
- visible signs
- public belief
- hidden truth
- preparation requirements
- one or more resolution methods
- aftermath

## Procedural Narrative Rules

Mechanics and canon facts are deterministic game data. Generated prose may
decorate those facts but may never create them.

Prose must not control:

- quest requirements
- item costs
- boss stats
- weaknesses
- rewards
- NPC alive/dead state
- location existence
- settlement state
- region facts
- combat rules

Generated prose may not invent proper nouns, rewards, objectives, locations, or
mechanics that are not present in structured input data.

Once generated prose is accepted, it must be cached in the save by a stable key
and must not silently mutate between sessions.

The complete game must remain playable without an LLM or any prose-generation
service.

## First Authored Direction

The first vertical slice is The Storm That Stays, centered on The Gloam Hart,
Worldmark of the Ringing Storm.

Its core lesson is that the frontier lantern network is not simply good and the
forest threat is not simply evil. The public belief is that the Hart hates fire
and sends creatures to extinguish lanterns. The hidden truth is that old lantern
materials or shrine materials taken from the Hart's domain are causing pain and
keeping the storm circling.

The first arc must support both a combat resolution and a release resolution,
with consequences communicated through the world and NPC reactions rather than a
giant morality score.
