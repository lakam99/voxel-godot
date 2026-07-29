extends RefCounted
class_name BuildingFamilyCatalog

## The semantic vocabulary for generated construction. A family definition
## describes what a building can be before a blueprint decides its exact
## footprint, openings, rooms, or material variation. It is shared by PoCs and
## future settlement publication; no family is a pre-authored scene.

const DEFINITIONS := {
	"cottage": {
		"landmarkRole": "home",
		"minimumTier": "hamlet",
		"widthRange": Vector2(7.8, 10.4),
		"depthRange": Vector2(5.8, 8.0),
		"storeyRange": Vector2i(1, 1),
		"defaultStyle": "timber",
		"roomProgram": ["hearth", "sleeping"]
	},
	"town_hall": {
		"landmarkRole": "civic",
		"minimumTier": "town",
		"widthRange": Vector2(22.0, 30.0),
		"depthRange": Vector2(14.0, 20.0),
		"storeyRange": Vector2i(1, 1),
		"defaultStyle": "masonry",
		"roomProgram": ["public_hall", "hearth", "notice_archive", "steward_office", "store"]
	},
	"manor": {
		"landmarkRole": "residential_landmark",
		"minimumTier": "town",
		"widthRange": Vector2(16.0, 24.0),
		"depthRange": Vector2(12.0, 18.0),
		"storeyRange": Vector2i(2, 3),
		"defaultStyle": "timber",
		"roomProgram": ["entry_hall", "dining", "kitchen", "private_chamber", "bedroom", "store"]
	},
	"keep": {
		"landmarkRole": "fortified_core",
		"minimumTier": "city",
		"widthRange": Vector2(20.0, 44.0),
		"depthRange": Vector2(18.0, 40.0),
		"storeyRange": Vector2i(3, 8),
		"defaultStyle": "masonry",
		"roomProgram": ["guard_hall", "armory", "great_hall", "private_chamber", "store", "roof_watch"]
	},
	"gatehouse": {
		"landmarkRole": "fortification_gate",
		"minimumTier": "city",
		"widthRange": Vector2(9.0, 19.0),
		"depthRange": Vector2(7.0, 15.0),
		"storeyRange": Vector2i(2, 5),
		"defaultStyle": "masonry",
		"roomProgram": ["gate_passage", "guard_room", "roof_watch"]
	},
	"tower": {
		"landmarkRole": "fortification_tower",
		"minimumTier": "city",
		"widthRange": Vector2(5.4, 10.8),
		"depthRange": Vector2(5.4, 10.8),
		"storeyRange": Vector2i(3, 8),
		"defaultStyle": "masonry",
		"roomProgram": ["guard_room", "roof_watch"]
	},
	"curtain_wall": {
		"landmarkRole": "fortification_wall",
		"minimumTier": "city",
		"widthRange": Vector2(32.0, 110.0),
		"depthRange": Vector2(1.2, 1.8),
		"storeyRange": Vector2i(1, 1),
		"defaultStyle": "masonry",
		"roomProgram": []
	},
	"courtyard": {
		"landmarkRole": "fortification_courtyard",
		"minimumTier": "city",
		"widthRange": Vector2(40.0, 110.0),
		"depthRange": Vector2(34.0, 96.0),
		"storeyRange": Vector2i(0, 0),
		"defaultStyle": "masonry",
		"roomProgram": ["courtyard"]
	}
}

const COMPOUND_MEMBERS := {
	"castle": ["gatehouse", "curtain_wall", "tower", "tower", "tower", "tower", "courtyard", "keep"]
}


static func normalize_family(value: String) -> String:
	var family := value.strip_edges().to_lower()
	return family if DEFINITIONS.has(family) else "cottage"


static func definition_for(value: String) -> Dictionary:
	return (DEFINITIONS.get(normalize_family(value), DEFINITIONS["cottage"]) as Dictionary).duplicate(true)


static func family_ids() -> Array[String]:
	var result: Array[String] = []
	for family in DEFINITIONS.keys():
		result.append(String(family))
	result.sort()
	return result


static func compound_member_families(compound_id: String) -> Array[String]:
	var normalized := compound_id.strip_edges().to_lower()
	var raw_members: Array = COMPOUND_MEMBERS.get(normalized, []) as Array
	var members: Array[String] = []
	for member in raw_members:
		var family := normalize_family(String(member))
		if family != "cottage" or String(member).strip_edges().to_lower() == "cottage":
			members.append(family)
	return members


static func is_compound(value: String) -> bool:
	return COMPOUND_MEMBERS.has(value.strip_edges().to_lower())
