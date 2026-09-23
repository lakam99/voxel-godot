extends RefCounted
class_name ActiveSurfacePropOwnerBundle

## Admission for owner-local N4 inputs only. Terrain pins, structure halos and
## final publication are separate dependencies; this is never a ready manifest.
const SCHEMA_VERSION := 1
const BiomeSnapshotScript := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const VisualSnapshotScript := preload("res://scripts/visual/ActiveVisualAssetSnapshot.gd")
const RemovedSnapshotScript := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")

static func capture(main: Object) -> Dictionary:
	if main == null or not is_instance_valid(main):
		return _failed("main_missing")
	var owner_id := main.get_instance_id()
	var seed: Variant = main.get("seed_text")
	var catalog := main.get("biome_environment_catalog") as BiomeEnvironmentCatalog
	var visuals := main.get("visual_asset_registry") as VisualAssetRegistry
	var animated := main.get("animated_asset_registry") as AnimatedAssetRegistry
	if not seed is String or (seed as String).is_empty() \
			or catalog == null or visuals == null or animated == null:
		return _failed("owner_sources_missing")
	var biome: Dictionary = BiomeSnapshotScript.capture(catalog)
	var visual: Dictionary = VisualSnapshotScript.capture(visuals)
	var presentation := animated.capture_active_presentation()
	var removed: Dictionary = RemovedSnapshotScript.capture(main)
	if not bool(biome.get("ok", false)) or not bool(visual.get("ok", false)) \
			or not bool(presentation.get("ok", false)) or not bool(removed.get("ok", false)):
		return _failed("source_not_ready")
	if not is_instance_valid(main) or main.get_instance_id() != owner_id \
			or main.get("seed_text") != seed \
			or main.get("biome_environment_catalog") != catalog \
			or main.get("visual_asset_registry") != visuals \
			or main.get("animated_asset_registry") != animated \
			or not BiomeSnapshotScript.is_current(catalog, biome) \
			or not VisualSnapshotScript.is_current(visuals, visual) \
			or not animated.presentation_capture_is_current(presentation) \
			or not RemovedSnapshotScript.is_current(main, removed):
		return _failed("source_changed_during_capture")
	return {"ok": true, "schemaVersion": SCHEMA_VERSION, "complete": false,
		"scope": "owner_catalogs_and_removals_only", "ownerInstanceId": owner_id,
		"seed": seed, "biome": biome.duplicate(true), "visual": visual.duplicate(true),
		"presentation": presentation.duplicate(true), "removed": removed.duplicate(true)}

static func is_current(main: Object, bundle: Dictionary) -> bool:
	if main == null or not is_instance_valid(main) or not bool(bundle.get("ok", false)) \
			or bundle.get("schemaVersion") != SCHEMA_VERSION \
			or bundle.get("complete") != false \
			or bundle.get("scope") != "owner_catalogs_and_removals_only" \
			or bundle.get("ownerInstanceId") != main.get_instance_id() \
			or bundle.get("seed") != main.get("seed_text"):
		return false
	var catalog := main.get("biome_environment_catalog") as BiomeEnvironmentCatalog
	var visuals := main.get("visual_asset_registry") as VisualAssetRegistry
	var animated := main.get("animated_asset_registry") as AnimatedAssetRegistry
	return catalog != null and visuals != null and animated != null \
		and bundle.get("biome") is Dictionary and bundle.get("visual") is Dictionary \
		and bundle.get("presentation") is Dictionary and bundle.get("removed") is Dictionary \
		and BiomeSnapshotScript.is_current(catalog, bundle.biome) \
		and VisualSnapshotScript.is_current(visuals, bundle.visual) \
		and animated.presentation_capture_is_current(bundle.presentation) \
		and RemovedSnapshotScript.is_current(main, bundle.removed)

static func _failed(reason: String) -> Dictionary:
	return {"ok": false, "complete": false, "reason": reason}
