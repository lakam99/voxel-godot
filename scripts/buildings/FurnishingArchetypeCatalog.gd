extends RefCounted
class_name FurnishingArchetypeCatalog

## Shared vocabulary for generated interiors. A planner selects semantic
## furnishings from this catalogue; the publisher owns their visual detail and
## one FurnishingPart remains the authority for footprint and collision.


static func definition(archetype_id: String) -> Dictionary:
	match archetype_id.strip_edges().to_lower():
		"bench":
			return {
				"archetype": "bench", "material": "timber_board",
				"size": Vector3(1.86, 0.84, 0.52), "semantic": "seating_bench",
				"clearance": 0.08
			}
		"sideboard":
			return {
				"archetype": "sideboard", "material": "timber_beam",
				"size": Vector3(1.72, 1.12, 0.48), "semantic": "storage_sideboard",
				"clearance": 0.10, "interactionClearance": 0.86
			}
		"lectern":
			return {
				"archetype": "lectern", "material": "timber_beam",
				"size": Vector3(0.72, 1.30, 0.56), "semantic": "reading_lectern",
				"clearance": 0.08
			}
		"map_table":
			return {
				"archetype": "map_table", "material": "timber_board",
				"size": Vector3(1.96, 0.88, 1.18), "semantic": "map_worktable",
				"clearance": 0.10
			}
		"workbench":
			return {
				"archetype": "workbench", "material": "timber_board",
				"size": Vector3(2.14, 0.90, 0.86), "semantic": "craft_workbench",
				"clearance": 0.10
			}
		"crate_stack":
			return {
				"archetype": "crate_stack", "material": "timber_board",
				"size": Vector3(0.92, 1.06, 0.74), "semantic": "stored_crates",
				"clearance": 0.08, "interactionClearance": 0.72
			}
		"barrel_stack":
			return {
				"archetype": "barrel_stack", "material": "timber_beam",
				"size": Vector3(0.86, 1.12, 0.86), "semantic": "stored_barrels",
				"clearance": 0.08, "interactionClearance": 0.70
			}
		"display_plinth":
			return {
				"archetype": "display_plinth", "material": "stone_foundation",
				"size": Vector3(0.82, 1.18, 0.82), "semantic": "civic_display",
				"clearance": 0.08
			}
		"dais":
			return {
				"archetype": "dais", "material": "timber_beam",
				"size": Vector3(4.10, 0.42, 1.68), "semantic": "raised_civic_dais",
				"clearance": 0.08
			}
		"civic_rug":
			return {
				"archetype": "rug", "material": "wool_rust",
				"size": Vector3(6.90, 0.035, 3.22), "semantic": "civic_woven_rug",
				"collision": false, "reserve": false
			}
		"aisle_runner":
			return {
				"archetype": "rug", "material": "wool_moss",
				"size": Vector3(1.76, 0.035, 4.86), "semantic": "woven_aisle_runner",
				"collision": false, "reserve": false
			}
		"coat_rack":
			return {
				"archetype": "coat_rack", "material": "timber_beam",
				"size": Vector3(0.56, 1.72, 0.56), "semantic": "entry_coat_rack",
				"clearance": 0.06
			}
		"planter":
			return {
				"archetype": "planter", "material": "ceramic_glaze",
				"size": Vector3(0.58, 0.88, 0.58), "semantic": "interior_planter",
				"clearance": 0.06
			}
		"wall_sconce":
			return {
				"archetype": "wall_sconce", "material": "brass",
				"size": Vector3(0.22, 0.48, 0.18), "semantic": "wall_light",
				"collision": false, "mountHeight": 2.12
			}
		"wall_banner":
			return {
				"archetype": "wall_banner", "material": "wool_rust",
				"size": Vector3(0.88, 1.62, 0.08), "semantic": "heraldic_wall_banner",
				"collision": false, "mountHeight": 2.54
			}
	return {}


static func is_known(archetype_id: String) -> bool:
	return not definition(archetype_id).is_empty()
