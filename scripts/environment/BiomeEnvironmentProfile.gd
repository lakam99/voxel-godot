extends Resource
class_name BiomeEnvironmentProfile

@export_group("Identity and generated assets")
@export var biome_id := "default"
@export var tree_families := PackedStringArray(["broadleaf_tree"])
@export var rock_families := PackedStringArray(["rock"])
@export var tree_scale := 1.0
@export var rock_scale := 1.0

@export_group("Existing placement behavior")
@export_range(0.0, 1.0) var tree_chance := 0.02
@export_range(0.0, 1.0) var rock_base_chance := 0.08
@export_range(0.0, 1.0) var forage_chance := 0.0
@export_range(0.0, 1.0) var wildlife_chance := 0.0
@export var forage_material := "berryBush"
@export var forage_drop := "berries"
@export var forage_drop_min := 2
@export var forage_drop_max := 4
@export var forage_radius := 0.56

@export_group("Weather")
@export_range(0.0, 1.0) var weather_precip := 0.36
@export_range(0.0, 1.0) var weather_clouds := 0.36
@export var cold_weather := false

@export_group("Ground detail")
@export var detail_types := PackedStringArray(["grass", "flower", "pebble"])
@export var detail_thresholds := PackedFloat32Array([0.62, 0.84, 1.0])
@export var detail_y_offsets := PackedFloat32Array([0.19, 0.15, 0.05])
@export var detail_scale_mins := PackedFloat32Array([0.62, 0.82, 0.50])
@export var detail_scale_maxs := PackedFloat32Array([1.18, 1.18, 0.95])
@export var detail_max_height_above_water := 1000000.0

@export_group("Canopy extension seam")
@export var tree_height_min := 0.0
@export var tree_height_max := 0.0
@export var crown_radius_min := 0.0
@export var crown_radius_max := 0.0
@export var trunk_radius_min := 0.0
@export var trunk_radius_max := 0.0
@export_range(0.0, 1.0) var old_growth_chance := 0.0
@export_range(0.0, 2.0) var wind_response := 1.0
@export_range(0.0, 1.0) var canopy_density := 0.0
@export var natural_prop_exclusion_margin := 0.0
@export var tree_visibility_range := 260.0
@export var tree_shadow_range := 180.0

func forage_spec() -> Dictionary:
	return {
		"material": forage_material,
		"drop": forage_drop,
		"drop_min": forage_drop_min,
		"drop_max": forage_drop_max,
		"radius": forage_radius
	}
