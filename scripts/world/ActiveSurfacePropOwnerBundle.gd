extends RefCounted
class_name ActiveSurfacePropOwnerBundle

## Admission for owner-local N4 inputs only. Terrain pins, structure halos and
## final publication are separate dependencies; this is never a ready manifest.
const SCHEMA_VERSION := 1
const BiomeSnapshotScript := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const VisualSnapshotScript := preload("res://scripts/visual/ActiveVisualAssetSnapshot.gd")
const RemovedSnapshotScript := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const StructureChunkScript := preload("res://scripts/world/ActiveStructureExclusionChunkSnapshot.gd")
const EffectiveTerrainPinScript := preload("res://scripts/world/ActiveEffectiveTerrainChunkPin.gd")

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
		# These catalog snapshots contain sealed owner aliases. Deep-copying them
		# would replace their publication identity even when their values agree.
		"seed": seed, "biome": biome, "visual": visual,
		"presentation": presentation, "removed": removed.duplicate(true)}

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

static func capture_chunk(main: Object, chunk: Vector2i) -> Dictionary:
	var owner := capture(main)
	if not bool(owner.get("ok", false)):
		return _failed("owner_sources_not_ready")
	var structures: Variant = main.get("structure_system")
	if not structures is Object or not is_instance_valid(structures) \
			or structures.get("main") != main:
		return _failed("structure_owner_mismatch")
	var exclusions: Dictionary = StructureChunkScript.capture(structures, chunk)
	if not bool(exclusions.get("ok", false)) \
			or exclusions.get("admissionSeed") != owner.seed \
			or not is_current(main, owner) \
			or main.get("structure_system") != structures \
			or structures.get("main") != main \
			or not StructureChunkScript.is_current(structures, exclusions):
		return _failed("chunk_sources_changed_or_not_ready")
	return {"ok": true, "schemaVersion": SCHEMA_VERSION, "complete": false,
		"scope": "owner_and_structure_chunk_only", "chunk": chunk,
		"owner": owner, "exclusions": exclusions.duplicate(true)}

static func chunk_is_current(main: Object, bundle: Dictionary) -> bool:
	if main == null or not is_instance_valid(main) or not bool(bundle.get("ok", false)) \
			or bundle.get("schemaVersion") != SCHEMA_VERSION \
			or bundle.get("complete") != false \
			or bundle.get("scope") != "owner_and_structure_chunk_only" \
			or not bundle.get("chunk") is Vector2i \
			or not bundle.get("owner") is Dictionary \
			or not bundle.get("exclusions") is Dictionary:
		return false
	var structures: Variant = main.get("structure_system")
	return structures is Object and is_instance_valid(structures) \
		and structures.get("main") == main \
		and bundle.exclusions.get("chunk") == bundle.chunk \
		and bundle.exclusions.get("admissionSeed") == bundle.owner.get("seed") \
		and is_current(main, bundle.owner) \
		and StructureChunkScript.is_current(structures, bundle.exclusions)

static func capture_terrain_chunk(main: Object, chunk: Vector2i, backend: Object) -> Dictionary:
	var sources := capture_chunk(main, chunk)
	if not bool(sources.get("ok", false)):
		return _failed("chunk_sources_not_ready")
	var terrain: Dictionary = EffectiveTerrainPinScript.capture(backend, String(sources.owner.seed), chunk)
	if not bool(terrain.get("ok", false)) \
			or not chunk_is_current(main, sources) \
			or not EffectiveTerrainPinScript.is_current(backend, String(sources.owner.seed), terrain):
		return _failed("terrain_or_chunk_changed_during_capture")
	return {"ok":true, "schemaVersion":SCHEMA_VERSION, "complete":false,
		"scope":"owner_structure_and_effective_terrain_chunk_only", "chunk":chunk,
		"sources":sources, "terrain":terrain.duplicate(true)}

static func terrain_chunk_is_current(main: Object, backend: Object, bundle: Dictionary) -> bool:
	return main != null and is_instance_valid(main) and bool(bundle.get("ok", false)) \
		and bundle.get("schemaVersion") == SCHEMA_VERSION \
		and bundle.get("complete") == false \
		and bundle.get("scope") == "owner_structure_and_effective_terrain_chunk_only" \
		and bundle.get("chunk") is Vector2i \
		and bundle.get("sources") is Dictionary and bundle.get("terrain") is Dictionary \
		and bundle.sources.get("chunk") == bundle.chunk \
		and bundle.terrain.get("chunk") == bundle.chunk \
		and chunk_is_current(main, bundle.sources) \
		and EffectiveTerrainPinScript.is_current(backend, String(bundle.sources.owner.seed), bundle.terrain)

## Exact historical N4 value ABI, projected from current sealed publications.
## Keep the original bundle for freshness checks; native receipts do not prove it.
static func native_admission_projection(main: Object, bundle: Dictionary) -> Dictionary:
	if not is_current(main, bundle):
		return _failed("owner_bundle_stale")
	var catalog := main.get("biome_environment_catalog") as BiomeEnvironmentCatalog
	var biome := native_biome_projection(catalog, bundle.biome)
	if not bool(biome.get("ok", false)):
		return biome
	var visual: Dictionary = bundle.visual
	var receipt: Dictionary = visual.ownerReceipt
	var native_visual := {"ok":true, "schemaVersion":1,
		"ownerReceipt":{"owner_id":int(receipt.ownerInstanceId),
			"revision":int(receipt.publicationRevision), "ready":true,
			"catalog":biome.ownerReceipt},
		"assets":visual.assets, "families":visual.families,
		"disabledIds":visual.disabledIds, "sceneCache":visual.sceneCache}
	native_visual["contentIdentity"] = JSON.stringify({
		"domain":"visual_asset_registry_active_values", "schemaVersion":1,
		"assets":visual.assets, "families":visual.families,
		"disabledIds":visual.disabledIds, "sceneCache":visual.sceneCache}).sha256_text()
	return {"ok":true, "schemaVersion":SCHEMA_VERSION, "complete":false,
		"scope":"owner_catalogs_and_removals_only", "ownerInstanceId":bundle.ownerInstanceId,
		"seed":bundle.seed, "biome":biome, "visual":native_visual,
		"presentation":bundle.presentation, "removed":bundle.removed}

static func native_biome_projection(catalog: BiomeEnvironmentCatalog,
		snapshot: Dictionary) -> Dictionary:
	if not BiomeSnapshotScript.is_current(catalog, snapshot):
		return _failed("biome_publication_stale")
	var receipt: Dictionary = catalog.published_catalog_snapshot().ownerReceipt
	return {"ok":true, "schemaVersion":1,
		"ownerReceipt":{"owner_id":int(receipt.ownerInstanceId),
			"revision":int(receipt.publicationRevision), "ready":true},
		"fallbackId":snapshot.fallbackId, "contentIdentity":snapshot.contentIdentity,
		"profiles":snapshot.profiles}

static func _failed(reason: String) -> Dictionary:
	return {"ok": false, "complete": false, "reason": reason}
