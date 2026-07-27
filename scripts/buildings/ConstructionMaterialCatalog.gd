extends RefCounted
class_name ConstructionMaterialCatalog

## Shared material vocabulary for construction parts. A material is not only a
## colour: part builders select it alongside a semantic shape and collision
## recipe. This stays intentionally separate from terrain voxel materials.

const BUILDING_SHADER := preload("res://resources/visual/building_material.gdshader")

const DEFINITIONS := {
	"timber_board": {
		"base": Color(0.48, 0.245, 0.105), "accent": Color(0.27, 0.115, 0.042),
		"roughness": 0.88, "breakup": 0.14, "grid": 0.035,
		"grain": 0.34, "grain_scale": 15.5, "grain_color": Color(0.115, 0.040, 0.012)
	},
	"timber_beam": {
		"base": Color(0.29, 0.125, 0.045), "accent": Color(0.17, 0.060, 0.018),
		"roughness": 0.90, "breakup": 0.10, "grid": 0.02,
		"grain": 0.28, "grain_scale": 12.0, "grain_color": Color(0.09, 0.028, 0.008)
	},
	"painted_door": {
		"base": Color(0.075, 0.285, 0.295), "accent": Color(0.030, 0.120, 0.130),
		"roughness": 0.74, "breakup": 0.10, "grid": 0.02,
		"grain": 0.22, "grain_scale": 16.0, "grain_color": Color(0.018, 0.050, 0.055)
	},
	"brass": {
		"base": Color(0.78, 0.50, 0.14), "accent": Color(0.38, 0.20, 0.045),
		"roughness": 0.42, "breakup": 0.05, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"linen": {
		"base": Color(0.79, 0.73, 0.59), "accent": Color(0.55, 0.49, 0.37),
		"roughness": 0.96, "breakup": 0.12, "grid": 0.0,
		"grain": 0.08, "grain_scale": 20.0, "grain_color": Color(0.46, 0.39, 0.29)
	},
	"wool_moss": {
		"base": Color(0.25, 0.43, 0.24), "accent": Color(0.12, 0.25, 0.13),
		"roughness": 0.98, "breakup": 0.16, "grid": 0.0,
		"grain": 0.12, "grain_scale": 14.0, "grain_color": Color(0.10, 0.18, 0.08)
	},
	"wool_rust": {
		"base": Color(0.57, 0.18, 0.10), "accent": Color(0.32, 0.07, 0.035),
		"roughness": 0.98, "breakup": 0.14, "grid": 0.0,
		"grain": 0.10, "grain_scale": 14.0, "grain_color": Color(0.22, 0.045, 0.02)
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
		"base": Color(0.66, 0.40, 0.12), "accent": Color(0.20, 0.43, 0.42),
		"roughness": 0.72, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
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
		"base": Color(0.54, 0.205, 0.120), "accent": Color(0.35, 0.095, 0.052),
		"roughness": 0.92, "breakup": 0.20, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"fired_brick_light": {
		"base": Color(0.60, 0.245, 0.145), "accent": Color(0.38, 0.105, 0.060),
		"roughness": 0.92, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"fired_brick_dark": {
		"base": Color(0.36, 0.090, 0.052), "accent": Color(0.22, 0.045, 0.025),
		"roughness": 0.94, "breakup": 0.18, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"mortar": {
		"base": Color(0.245, 0.225, 0.200), "accent": Color(0.165, 0.150, 0.132),
		"roughness": 0.96, "breakup": 0.10, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"stone_foundation": {
		"base": Color(0.34, 0.37, 0.35), "accent": Color(0.20, 0.23, 0.21),
		"roughness": 0.94, "breakup": 0.24, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"roof_shingle": {
		"base": Color(0.17, 0.205, 0.19), "accent": Color(0.09, 0.115, 0.105),
		"roughness": 0.91, "breakup": 0.16, "grid": 0.02,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK
	},
	"window_glass": {
		"base": Color(0.34, 0.68, 0.76, 0.62), "accent": Color(0.72, 0.88, 0.90, 0.62),
		"roughness": 0.20, "breakup": 0.04, "grid": 0.0,
		"grain": 0.0, "grain_scale": 1.0, "grain_color": Color.BLACK,
		"transparent": true
	}
}


static func definition_for(material_id: String) -> Dictionary:
	var normalized := material_id.strip_edges().to_lower()
	var definition: Dictionary = DEFINITIONS.get(normalized, DEFINITIONS["stone_foundation"])
	return definition.duplicate(true)


static func create_material(material_id: String, variation := 0.0) -> Material:
	var definition := definition_for(material_id)
	if bool(definition.get("transparent", false)):
		var glass := StandardMaterial3D.new()
		glass.albedo_color = definition.get("base", Color(0.4, 0.7, 0.8, 0.55)) as Color
		glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass.roughness = float(definition.get("roughness", 0.2))
		glass.metallic_specular = 0.58
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
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
	return material
