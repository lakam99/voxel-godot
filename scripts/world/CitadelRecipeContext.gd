extends RefCounted
class_name CitadelRecipeContext

static func from_manifest(manifest: Dictionary, cell_size: float) -> Dictionary:
	var site_id := String(manifest.get("id", "")).strip_edges()
	var blueprint_seed := int(manifest.get("blueprintSeed", 0))
	var profile := String(manifest.get("citadelProfile", "")).strip_edges()
	var scale_value: Variant = manifest.get("citadelScale", null)
	var envelope_value: Variant = manifest.get("blueprintEnvelopeRadiusCells", null)
	var terrain: Dictionary = manifest.get("terrain", {}) if manifest.get("terrain", {}) is Dictionary else {}
	var biome := String(terrain.get("biome", "")).strip_edges()
	if site_id.is_empty() or blueprint_seed == 0 or profile != "standard" or not (scale_value is float or scale_value is int) or not is_equal_approx(float(scale_value), 1.0) or not (envelope_value is float or envelope_value is int) or int(envelope_value) <= 0 or biome.is_empty() or cell_size <= 0.0:
		return {"ok": false, "reason": "incomplete_citadel_recipe_context"}
	var origin := Vector3(float(int(manifest.get("centerX", 0))) * cell_size, float(manifest.get("level", 0.0)), float(int(manifest.get("centerZ", 0))) * cell_size)
	var context := {"biome": biome, "siteKey": site_id, "citadelScale": float(scale_value), "citadelProfile": profile, "blueprintEnvelopeRadiusCells": int(envelope_value), "worldOrigin": origin, "cellSize": cell_size}
	var signature := "%d|%s|%s|%.2f|%s|%d|%.5f,%.5f,%.5f|%.5f" % [blueprint_seed, site_id, biome, float(scale_value), profile, int(envelope_value), origin.x, origin.y, origin.z, cell_size]
	return {"ok": true, "blueprintSeed": blueprint_seed, "context": context, "signature": signature}
