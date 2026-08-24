extends RefCounted
class_name ConstructionMaterialCatalog

## Shared material vocabulary for construction parts. A material is not only a
## colour: part builders select it alongside a semantic shape and collision
## recipe. This stays intentionally separate from terrain voxel materials.

const BUILDING_SHADER := preload("res://resources/visual/building_material.gdshader")

const DEFINITIONS := {
	"timber_board": {
		"base": Color(0.305, 0.182, 0.090), "accent": Color(0.105, 0.047, 0.018),
		"roughness": 0.88, "breakup": 0.14, "grid": 0.035,
		"grain": 0.34, "grain_scale": 11.5, "grain_color": Color(0.062, 0.018, 0.006),
		"age": 0.70, "damp": 0.22
	},
	"timber_beam": {
		"base": Color(0.135, 0.060, 0.020), "accent": Color(0.032, 0.012, 0.004),
		"roughness": 0.90, "breakup": 0.10, "grid": 0.02,
		"grain": 0.30, "grain_scale": 9.5, "grain_color": Color(0.040, 0.012, 0.004),
		"age": 0.76, "damp": 0.28
	},
	"painted_door": {
		"base": Color(0.075, 0.285, 0.295), "accent": Color(0.030, 0.120, 0.130),
		"roughness": 0.74, "breakup": 0.10, "grid": 0.02,
		"grain": 0.22, "grain_scale": 16.0, "grain_color": Color(0.018, 0.050, 0.055)
	},
	"ironwork": {
		"base": Color(0.115, 0.135, 0.145), "accent": Color(0.045, 0.060, 0.068),
		"roughness": 0.60, "breakup": 0.08, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"brass": {
		"base": Color(0.78, 0.50, 0.14), "accent": Color(0.38, 0.20, 0.045),
		"roughness": 0.42, "breakup": 0.05, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"linen": {
		"base": Color(0.465, 0.395, 0.285), "accent": Color(0.245, 0.195, 0.125),
		"roughness": 0.96, "breakup": 0.12, "grid": 0.0,
		"grain": 0.08, "grain_scale": 20.0, "grain_color": Color(0.46, 0.39, 0.29)
	},
	"wool_moss": {
		"base": Color(0.155, 0.245, 0.135), "accent": Color(0.060, 0.125, 0.052),
		"roughness": 0.98, "breakup": 0.16, "grid": 0.0,
		"grain": 0.12, "grain_scale": 14.0, "grain_color": Color(0.035, 0.075, 0.025),
		"age": 0.46, "damp": 0.10
	},
	"wool_rust": {
		"base": Color(0.295, 0.095, 0.050), "accent": Color(0.125, 0.030, 0.014),
		"roughness": 0.98, "breakup": 0.14, "grid": 0.0,
		"grain": 0.10, "grain_scale": 14.0, "grain_color": Color(0.075, 0.015, 0.006),
		"age": 0.50, "damp": 0.08
	},
	"ceramic_glaze": {
		"base": Color(0.22, 0.48, 0.52), "accent": Color(0.08, 0.23, 0.27),
		"roughness": 0.46, "breakup": 0.06, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"book_leather": {
		"base": Color(0.33, 0.11, 0.07), "accent": Color(0.15, 0.035, 0.020),
		"roughness": 0.82, "breakup": 0.12, "grid": 0.0,
		"grain": 0.05, "grain_scale": 18.0, "grain_color": Color(0.09, 0.018, 0.01)
	},
	"painted_decor": {
		"base": Color(0.405, 0.125, 0.068), "accent": Color(0.185, 0.045, 0.030),
		"roughness": 0.88, "breakup": 0.22, "grid": 0.0,
		"grain": 0.08, "grain_scale": 18.0, "grain_color": Color(0.095, 0.018, 0.010),
		"age": 0.56, "damp": 0.10
	},
	"candle_wax": {
		"base": Color(0.93, 0.80, 0.43), "accent": Color(0.68, 0.47, 0.16),
		"roughness": 0.68, "breakup": 0.05, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"candle_flame": {
		"base": Color(1.0, 0.42, 0.08), "roughness": 0.18,
		"emission": Color(1.0, 0.14, 0.012), "emission_energy": 2.5
	},
	"fired_brick": {
		"base": Color(0.275, 0.128, 0.082), "accent": Color(0.118, 0.047, 0.028),
		"roughness": 0.92, "breakup": 0.20, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"masonry": 0.86, "age": 0.66, "damp": 0.46, "moss": 0.14
	},
	"fired_brick_light": {
		"base": Color(0.420, 0.235, 0.158), "accent": Color(0.220, 0.092, 0.052),
		"roughness": 0.92, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"masonry": 0.84, "age": 0.56, "damp": 0.40, "moss": 0.10
	},
	"fired_brick_dark": {
		"base": Color(0.235, 0.082, 0.052), "accent": Color(0.100, 0.028, 0.016),
		"roughness": 0.94, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"masonry": 0.88, "age": 0.70, "damp": 0.50, "moss": 0.16
	},
	# City masonry is still individually published brick, not a flat paint overlay.
	# Castle grammar selects these as a civic palette per seed; residences then
	# derive a façade colour from that same palette and their stable lot id.
	"painted_brick_ochre": {
		"base": Color(0.365, 0.295, 0.190), "accent": Color(0.175, 0.125, 0.055),
		"roughness": 0.91, "breakup": 0.19, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK, "masonry": 0.76, "age": 0.60, "damp": 0.40, "moss": 0.13
	},
	"painted_brick_sage": {
		"base": Color(0.245, 0.285, 0.225), "accent": Color(0.090, 0.145, 0.090),
		"roughness": 0.91, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK, "masonry": 0.76, "age": 0.64, "damp": 0.44, "moss": 0.20
	},
	"painted_brick_azure": {
		"base": Color(0.225, 0.270, 0.290), "accent": Color(0.075, 0.120, 0.140),
		"roughness": 0.90, "breakup": 0.17, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK, "masonry": 0.76, "age": 0.66, "damp": 0.46, "moss": 0.15
	},
	"painted_brick_rose": {
		"base": Color(0.355, 0.225, 0.195), "accent": Color(0.165, 0.065, 0.050),
		"roughness": 0.92, "breakup": 0.19, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK, "masonry": 0.76, "age": 0.62, "damp": 0.42, "moss": 0.13
	},
	"painted_brick_plum": {
		"base": Color(0.275, 0.230, 0.285), "accent": Color(0.105, 0.060, 0.125),
		"roughness": 0.91, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK, "masonry": 0.76, "age": 0.64, "damp": 0.44, "moss": 0.13
	},
	"painted_brick_cream": {
		"base": Color(0.425, 0.380, 0.285), "accent": Color(0.215, 0.185, 0.105),
		"roughness": 0.94, "breakup": 0.16, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK, "masonry": 0.76, "age": 0.62, "damp": 0.42, "moss": 0.13
	},
	"mortar": {
		"base": Color(0.365, 0.350, 0.315), "accent": Color(0.245, 0.225, 0.195),
		"roughness": 0.98, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.42, "damp": 0.30
	},
	"window_recess": {
		"base": Color(0.038, 0.047, 0.045), "accent": Color(0.012, 0.016, 0.015),
		"roughness": 0.96, "breakup": 0.12, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.40, "damp": 0.20
	},
	"stone_foundation": {
		"base": Color(0.285, 0.300, 0.275), "accent": Color(0.175, 0.188, 0.165),
		"roughness": 0.94, "breakup": 0.24, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"masonry": 0.92, "age": 0.62, "damp": 0.46, "moss": 0.20, "detail_scale": 3.8
	},
	"repair_stone": {
		"base": Color(0.420, 0.425, 0.385), "accent": Color(0.235, 0.255, 0.225),
		"roughness": 0.97, "breakup": 0.28, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"masonry": 0.94, "age": 0.70, "damp": 0.48, "moss": 0.18, "detail_scale": 3.6
	},
	"aged_castle_stone": {
		"base": Color(0.305, 0.315, 0.292), "accent": Color(0.160, 0.174, 0.150),
		"roughness": 0.97, "breakup": 0.30, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"masonry": 1.0, "age": 0.84, "damp": 0.58, "moss": 0.30, "detail_scale": 3.1,
		"moss_color": Color(0.075, 0.125, 0.050)
	},
	"cobblestone": {
		"base": Color(0.235, 0.245, 0.205), "accent": Color(0.095, 0.110, 0.075),
		"roughness": 0.97, "breakup": 0.34, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"masonry": 0.96, "age": 0.78, "damp": 0.52, "moss": 0.68, "detail_scale": 4.8, "cobble": 1.0,
		"moss_color": Color(0.075, 0.165, 0.040)
	},
	"worn_cobble": {
		"base": Color(0.220, 0.205, 0.160), "accent": Color(0.095, 0.082, 0.052),
		"roughness": 0.98, "breakup": 0.38, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"masonry": 0.96, "age": 0.86, "damp": 0.48, "moss": 0.28, "detail_scale": 5.2, "cobble": 1.0,
		"moss_color": Color(0.072, 0.140, 0.035)
	},
	"drainage_stain": {
		"base": Color(0.105, 0.105, 0.075), "accent": Color(0.055, 0.060, 0.040),
		"roughness": 0.99, "breakup": 0.40, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.92, "damp": 0.90, "moss": 0.55, "moss_color": Color(0.065, 0.110, 0.035)
	},
	"limewash_repair": {
		"base": Color(0.455, 0.405, 0.305), "accent": Color(0.245, 0.205, 0.135),
		"roughness": 0.99, "breakup": 0.30, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.68, "damp": 0.36, "moss": 0.10
	},
	"ground_soil": {
		"base": Color(0.205, 0.165, 0.105), "accent": Color(0.110, 0.078, 0.042),
		"roughness": 0.99, "breakup": 0.32, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.72, "damp": 0.48, "moss": 0.30, "moss_color": Color(0.095, 0.155, 0.055)
	},
	"leaf_litter": {
		"base": Color(0.225, 0.145, 0.060), "accent": Color(0.105, 0.058, 0.022),
		"roughness": 0.99, "breakup": 0.38, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.78, "damp": 0.34, "moss": 0.14, "moss_color": Color(0.085, 0.135, 0.045)
	},
	"wall_growth": {
		"base": Color(0.105, 0.165, 0.055), "accent": Color(0.042, 0.080, 0.026),
		"roughness": 0.99, "breakup": 0.36, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.72, "damp": 0.48, "moss": 0.52, "moss_color": Color(0.075, 0.135, 0.038)
	},
	"roof_shingle": {
		"base": Color(0.125, 0.150, 0.145), "accent": Color(0.052, 0.070, 0.066),
		"roughness": 0.91, "breakup": 0.16, "grid": 0.02,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.58, "damp": 0.24, "moss": 0.16, "roof": 1.0, "moss_color": Color(0.075, 0.125, 0.055)
	},
	"roof_slate_weathered": {
		"base": Color(0.092, 0.126, 0.134), "accent": Color(0.032, 0.058, 0.061),
		"roughness": 0.96, "breakup": 0.25, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.86, "damp": 0.52, "moss": 0.26, "roof": 1.0, "moss_color": Color(0.060, 0.112, 0.048)
	},
	"roof_slate_cap": {
		"base": Color(0.105, 0.132, 0.136), "accent": Color(0.040, 0.058, 0.060),
		"roughness": 0.94, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"age": 0.74, "damp": 0.40, "moss": 0.16, "roof": 1.0, "moss_color": Color(0.060, 0.108, 0.046)
	},
	"window_glass": {
		# Keep the cool glint while allowing an exterior reader to see the actual
		# furnished rooms beyond the opening rather than a blue opaque pane.
		"base": Color(0.34, 0.68, 0.76, 0.018), "accent": Color(0.72, 0.88, 0.90, 0.018),
		"roughness": 0.20, "breakup": 0.04, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"transparent": true
	},
	"window_warm_glass": {
		"base": Color(0.92, 0.54, 0.20, 0.024), "accent": Color(1.0, 0.78, 0.34, 0.024),
		"roughness": 0.28, "breakup": 0.05, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"transparent": true, "emission": Color(1.0, 0.30, 0.055), "emission_energy": 0.04
	}
}


static func definition_for(material_id: String) -> Dictionary:
	var normalized := material_id.strip_edges().to_lower()
	var definition: Dictionary = DEFINITIONS.get(normalized, DEFINITIONS["stone_foundation"])
	return definition.duplicate(true)


static func is_masonry_material(material_id: String) -> bool:
	var normalized := material_id.strip_edges().to_lower()
	return normalized.begins_with("fired_brick") or normalized.begins_with("painted_brick_") or normalized in ["stone_foundation", "aged_castle_stone"]


static func is_cobble_material(material_id: String) -> bool:
	return material_id.strip_edges().to_lower() in ["cobblestone", "worn_cobble"]


static func create_material(material_id: String, variation := 0.0) -> Material:
	var definition := definition_for(material_id)
	if bool(definition.get("transparent", false)):
		var glass := StandardMaterial3D.new()
		glass.albedo_color = definition.get("base", Color(0.4, 0.7, 0.8, 0.55)) as Color
		glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass.roughness = float(definition.get("roughness", 0.2))
		glass.metallic_specular = 0.58
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
		glass.emission_enabled = true
		glass.emission = definition.get("emission", Color(0.075, 0.18, 0.21)) as Color
		glass.emission_energy_multiplier = float(definition.get("emission_energy", 0.32))
		return glass
	if definition.has("emission"):
		var emissive := StandardMaterial3D.new()
		emissive.albedo_color = definition.get("base", Color.WHITE) as Color
		emissive.roughness = float(definition.get("roughness", 0.35))
		emissive.emission_enabled = true
		emissive.emission = definition.get("emission", Color.WHITE) as Color
		emissive.emission_energy_multiplier = float(definition.get("emission_energy", 1.0))
		return emissive
	var material := ShaderMaterial.new()
	material.shader = BUILDING_SHADER
	var tint := clampf(variation, -0.12, 0.12)
	var base: Color = definition.get("base", Color.WHITE) as Color
	var accent: Color = definition.get("accent", Color.WHITE) as Color
	material.set_shader_parameter("base_color", base.lightened(maxf(0.0, tint)).darkened(maxf(0.0, -tint)))
	material.set_shader_parameter("accent_color", accent.lightened(maxf(0.0, tint * 0.7)).darkened(maxf(0.0, -tint * 0.7)))
	material.set_shader_parameter("roughness", float(definition.get("roughness", 0.9)))
	material.set_shader_parameter("breakup_strength", float(definition.get("breakup", 0.12)))
	material.set_shader_parameter("grid_strength", float(definition.get("grid", 0.0)))
	material.set_shader_parameter("scale", 2.6)
	material.set_shader_parameter("grain_strength", float(definition.get("grain", 0.0)))
	material.set_shader_parameter("grain_scale", float(definition.get("grain_scale", 12.0)))
	material.set_shader_parameter("grain_color", definition.get("grain_color", Color.BLACK))
	material.set_shader_parameter("grain_warp", 2.2)
	material.set_shader_parameter("masonry_strength", float(definition.get("masonry", 0.0)))
	material.set_shader_parameter("age_strength", float(definition.get("age", 0.0)))
	material.set_shader_parameter("damp_strength", float(definition.get("damp", 0.0)))
	material.set_shader_parameter("moss_strength", float(definition.get("moss", 0.0)))
	material.set_shader_parameter("moss_color", definition.get("moss_color", Color(0.11, 0.17, 0.075)))
	material.set_shader_parameter("detail_scale", float(definition.get("detail_scale", 5.0)))
	material.set_shader_parameter("cobble_strength", float(definition.get("cobble", 0.0)))
	material.set_shader_parameter("roof_strength", float(definition.get("roof", 0.0)))
	return material
