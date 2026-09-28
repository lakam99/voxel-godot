extends RefCounted
## Pure material requests. Main-thread resolution retains original cache keys
## and first-request order; workers never instantiate Materials.
const Catalog = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")

static func family_variation(part, source_id: String, variation: float) -> float:
	var tokens := String(part.id).split("_", false)
	var family_token_count := mini(4, tokens.size())
	var family_key := "_".join(tokens.slice(0, family_token_count))
	var family_index := posmod((source_id + ":" + family_key).hash(), 5)
	var family_offsets := [-0.042, -0.021, 0.0, 0.018, 0.039]
	return variation + float(family_offsets[family_index])

static func ordinary(material_id: String, variation: float) -> Dictionary:
	var request := {"key":"%s:%0.3f" % [material_id,variation], "materialId":material_id,
		"variation":variation, "parameters":{}}
	request.parameters.make_read_only()
	request.make_read_only()
	return request

static func repair(part, host_material_id: String, source_id: String, host_variation: float) -> Dictionary:
	var host_definition := Catalog.definition_for(host_material_id)
	var tint := clampf(host_variation, -0.12, 0.12)
	var host_base: Color = host_definition.get("base", Color.WHITE) as Color
	var host_accent: Color = host_definition.get("accent", Color.WHITE) as Color
	var parameters := {
		"repair_strength":1.0,
		"repair_phase":float(posmod((source_id + ":repair:" + String(part.id)).hash(), 4093)) / 4093.0,
		"repair_host_base":host_base.lightened(maxf(0.0, tint)).darkened(maxf(0.0, -tint)),
		"repair_host_accent":host_accent.lightened(maxf(0.0, tint * 0.7)).darkened(maxf(0.0, -tint * 0.7))}
	parameters.make_read_only()
	var request := {"key":"masonry_repair:%s:%0.3f" % [host_material_id,host_variation],
		"materialId":"repair_stone","variation":host_variation + 0.035,"parameters":parameters}
	request.make_read_only()
	return request
