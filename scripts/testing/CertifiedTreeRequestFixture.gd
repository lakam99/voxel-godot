extends RefCounted
class_name CertifiedTreeRequestFixture

## Test support that admits a request through the production catalog snapshot
## and request builder. It preserves caller dimensions only when the production
## profile envelope accepts them; it never clamps an out-of-domain fixture.

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const ActiveSnapshotScript := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const RequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const AdmissionScript := preload("res://scripts/environment/TreeRequestAdmission.gd")

static var _catalog
static var _snapshot: Dictionary = {}
static var _builder


static func prepare_request(source: Dictionary) -> Dictionary:
	if not _ensure_catalog_snapshot():
		return {"status": "failed", "reason": "test_biome_catalog_unavailable"}
	var biome := String(source.get("biome", "default")).strip_edges().to_lower()
	var tree_id := String(source.get("treeId", "")).strip_edges()
	var world_seed := String(source.get("worldSeed", "test-tree-request-fixture"))
	if tree_id.is_empty():
		return {"status": "failed", "reason": "fixture_tree_id_missing"}
	var profile = _catalog.profile_for_biome(biome)
	if profile == null:
		return {"status": "failed", "reason": "fixture_profile_missing:%s" % biome}
	var fallback_height := float(source.get("visualHeight", 4.0))
	var candidate: Dictionary = _builder.build(profile, biome, tree_id, fallback_height,
		Vector2i.ZERO, world_seed, _snapshot)
	if candidate.is_empty():
		return {"status": "failed", "reason": "canonical_request_builder_failed:%s" % biome}
	var requested_architecture := String(source.get("architecture", ""))
	if not requested_architecture.is_empty() \
			and requested_architecture != String(candidate.get("architecture", "")):
		return {"status": "failed", "reason": "fixture_architecture_outside_selected_profile:%s:%s" \
			% [requested_architecture, candidate.get("architecture", "")]}
	var requested_grammar := String(source.get("speciesGrammar", ""))
	if not requested_grammar.is_empty() \
			and requested_grammar != String(candidate.get("speciesGrammar", "")):
		return {"status": "failed", "reason": "fixture_grammar_outside_selected_profile:%s:%s" \
			% [requested_grammar, candidate.get("speciesGrammar", "")]}
	candidate["treeId"] = tree_id
	candidate["worldSeed"] = world_seed
	candidate["biome"] = biome
	for key: String in ["geneticSeed", "growthStage", "maturity", "canopyDensity",
			"renderLodTier", "presentation", "worldPosition", "worldRotationY",
			"treeWorldPosition", "publicationPriority"]:
		if source.has(key):
			candidate[key] = source[key]
	for key: String in ["visualHeight", "trunkRadius", "canopyRadius"]:
		if source.has(key):
			candidate[key] = source[key]
	if source.has("collisionHeight"):
		var collision_height := float(source.collisionHeight)
		if not is_finite(collision_height) or collision_height < 1.0 \
				or collision_height > float(candidate.get("visualHeight", 0.0)):
			return {"status": "failed", "reason": "fixture_collision_height_outside_production_request"}
		candidate["collisionHeight"] = collision_height
	var admission := AdmissionScript.validate_request(candidate, _snapshot)
	if String(admission.get("status", "")) != "ready":
		return {"status": "failed", "reason": String(admission.get("reason", "fixture_request_not_admitted"))}
	return {"status": "ready", "request": candidate}


static func prepare_or_fail(source: Dictionary) -> Dictionary:
	var prepared := prepare_request(source)
	if String(prepared.get("status", "")) != "ready":
		push_error("Certified tree request fixture rejected: %s" % String(prepared.get("reason", "unknown")))
		return {}
	return prepared.get("request", {}) as Dictionary


static func _ensure_catalog_snapshot() -> bool:
	if _catalog != null and not _snapshot.is_empty():
		return true
	_catalog = CatalogScript.new()
	if not _catalog.setup():
		_catalog = null
		return false
	_snapshot = ActiveSnapshotScript.capture(_catalog)
	if not bool(_snapshot.get("ok", false)):
		_catalog = null
		_snapshot = {}
		return false
	_builder = RequestBuilderScript.new()
	return true
