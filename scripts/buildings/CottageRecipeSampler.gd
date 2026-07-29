extends RefCounted
class_name CottageRecipeSampler

## Pure seeded recipe sampler. It decides a cottage's construction facts before
## any scene node, mesh or furnishing is made, so replay never depends on
## publication order or mutable RNG state.


static func sample(seed: int, requested_style := "timber") -> Dictionary:
	var style := requested_style.strip_edges().to_lower()
	if style not in ["timber", "masonry"]:
		style = "timber"
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed) * 1103515245 + 12345
	var width := snappedf(rng.randf_range(7.8, 10.4), 0.20)
	var depth := snappedf(rng.randf_range(5.8, 8.0), 0.20)
	var wall_height := snappedf(rng.randf_range(3.20, 3.95), 0.05)
	var foundation_height := 0.48
	var wall_thickness := 0.26
	var roof_rise := snappedf(rng.randf_range(1.92, 2.78), 0.05)
	var roof_overhang := snappedf(rng.randf_range(0.42, 0.62), 0.02)
	var door_width := snappedf(rng.randf_range(1.18, 1.46), 0.02)
	var door_height := minf(wall_height - 0.52, snappedf(rng.randf_range(2.20, 2.52), 0.02))
	var door_x := snappedf(rng.randf_range(-width * 0.30, -width * 0.08), 0.02)
	var divider_x := snappedf(rng.randf_range(-0.28, 0.32), 0.02)
	var divider_gap := snappedf(rng.randf_range(1.00, 1.34), 0.02)
	var window_height := snappedf(rng.randf_range(1.02, minf(1.34, wall_height - 1.12)), 0.02)
	var window_center_y := foundation_height + wall_height * rng.randf_range(0.54, 0.64)
	var front_window_width := snappedf(rng.randf_range(1.12, 1.54), 0.02)
	# Keep the exterior front window clear of both the entry leaf and the interior
	# room divider: a valid aperture cannot terminate inside another wall volume.
	var front_window_min_x := maxf(door_x + door_width * 0.5 + front_window_width * 0.5 + 0.34, divider_x + front_window_width * 0.5 + 0.30)
	var front_window_max_x := width * 0.5 - front_window_width * 0.5 - 0.34
	var front_window_x := snappedf(lerpf(front_window_min_x, maxf(front_window_min_x, front_window_max_x), rng.randf()), 0.02)
	var side_window_length := snappedf(rng.randf_range(1.18, 1.68), 0.02)
	var side_window_margin := side_window_length * 0.5 + 0.38
	var left_window_z := snappedf(rng.randf_range(-depth * 0.5 + side_window_margin, depth * 0.5 - side_window_margin), 0.02)
	var right_window_z := snappedf(rng.randf_range(-depth * 0.5 + side_window_margin, depth * 0.5 - side_window_margin), 0.02)
	var furnishing_profiles: Array[String] = ["hearth_social", "quiet_study", "compact_home"]
	var furnishing_profile: String = furnishing_profiles[rng.randi_range(0, furnishing_profiles.size() - 1)]
	return {
		"family": "cottage",
		"seed": seed,
		"style": style,
		"width": width,
		"depth": depth,
		"wallHeight": wall_height,
		"wallThickness": wall_thickness,
		"foundationHeight": foundation_height,
		"roofRise": roof_rise,
		"roofOverhang": roof_overhang,
		"doorWidth": door_width,
		"doorHeight": door_height,
		"doorX": door_x,
		"dividerX": divider_x,
		"dividerGap": divider_gap,
		"windowHeight": window_height,
		"windowCenterY": window_center_y,
		"frontWindowX": front_window_x,
		"frontWindowWidth": front_window_width,
		"leftWindowZ": left_window_z,
		"rightWindowZ": right_window_z,
		"sideWindowLength": side_window_length,
		"materialVariation": float(abs(seed) % 13) / 100.0 - 0.06,
		"furnishingProfile": furnishing_profile
	}
