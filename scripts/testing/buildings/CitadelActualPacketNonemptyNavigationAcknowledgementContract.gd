extends "res://scripts/testing/buildings/CitadelActualPacketTileNavigationAcknowledgementContract.gd"

## Smallest frozen-source packet closure whose base-derived producer emits
## walkable surfaces. The parent retains the source through real navigation
## acknowledgement and owns all queue/service assertions.
const NONEMPTY_TILE := Vector2i(199,-337)
const NONEMPTY_GROUP_IDS: Array[String] = [
	"building:castle_compound_foundation_segment_00",
	"building:castle_tower_04_back",
	"building:castle_tower_04_battlement_back_0",
	"building:castle_tower_04_battlement_back_1",
	"building:castle_tower_04_battlement_back_2",
	"building:castle_tower_04_battlement_back_3",
	"building:castle_tower_04_battlement_back_4",
	"building:castle_tower_04_battlement_back_5",
	"building:castle_tower_04_battlement_back_6",
	"building:castle_tower_04_battlement_back_7",
	"building:castle_tower_04_battlement_left_7",
	"building:castle_tower_04_battlement_right_7",
	"building:castle_tower_04_floor",
	"building:castle_tower_04_foundation",
	"building:castle_tower_04_front",
	"building:castle_tower_04_left",
	"building:castle_tower_04_right",
	"building:castle_tower_04_roof_deck"
]

func packet_tile() -> Vector2i:
	return NONEMPTY_TILE

func packet_group_ids() -> Array[String]:
	return NONEMPTY_GROUP_IDS
