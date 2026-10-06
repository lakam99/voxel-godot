extends SceneTree

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const SnapshotScript := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const DirectOracleScript := preload("res://scripts/testing/BiomeEnvironmentSnapshotOracle.gd")

var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var catalog = CatalogScript.new()
	check("unready_rejected", not bool(SnapshotScript.capture(catalog).get("ok", false)))
	check("catalog_ready", catalog.setup())
	var captured: Dictionary = SnapshotScript.capture(catalog)
	check("active_capture_ready", bool(captured.get("ok", false)))
	var direct = DirectOracleScript.new()
	var oracle: Dictionary = direct.snapshot()
	var semantic: Array[Dictionary] = []
	for row in oracle.get("profiles", []):
		semantic.append(direct.semantic_fields(row))
	var expected := direct.sha256_text(JSON.stringify({"domain": "biome_environment_resolved_catalog",
		"schemaVersion": 1, "fallbackId": oracle.get("fallbackId", ""), "profiles": semantic}))
	direct.free()
	check("active_matches_direct_resolved_digest", captured.get("contentIdentity") == expected)
	check("active_matches_direct_resolved_rows", captured.get("profiles") == semantic)
	check("initial_receipt_current", SnapshotScript.is_current(catalog, captured))
	var publication: Dictionary = catalog.published_catalog_snapshot()
	check("publication_envelope_frozen_values_only", _value_graph_is_frozen_values(publication))
	check("publication_read_returns_same_alias", is_same(publication, catalog.published_catalog_snapshot()))
	check("capture_returns_published_payload_alias", is_same(captured, publication.get("payload", {})))
	var seals_before_reads := int(catalog.snapshot_seal_count)
	var serializations_before_reads := int(catalog.snapshot_serialization_count)
	var repeated_reads_same_alias := true
	for index in range(12):
		repeated_reads_same_alias = repeated_reads_same_alias \
			and is_same(catalog.published_catalog_snapshot(), publication) \
			and is_same(SnapshotScript.capture(catalog), captured)
	check("repeated_reads_do_not_reseal_or_reserialize", repeated_reads_same_alias \
		and catalog.snapshot_seal_count == seals_before_reads \
		and catalog.snapshot_serialization_count == serializations_before_reads)
	var alpine_path := "res://resources/visual/biomes/alpine.tres"
	var cached_alpine := load(alpine_path) as BiomeEnvironmentProfile
	var cached_scale := float(cached_alpine.tree_scale)
	var owner_scale := float(catalog.profile_values_for_biome("alpine").get("tree_scale", -1.0))
	var alpine_copy = catalog.profile_for_biome("alpine")
	alpine_copy.tree_scale = cached_scale + 0.125
	alpine_copy.tree_families = PackedStringArray(["mutated_copy_only"])
	check("profile_copy_mutation_isolated_from_owner", catalog.profile_values_for_biome("alpine").get("tree_scale") == owner_scale \
		and SnapshotScript.is_current(catalog, captured))
	check("profile_copy_mutation_isolated_from_resource_loader", cached_alpine.tree_scale == cached_scale \
		and not cached_alpine.tree_families.has("mutated_copy_only"))
	var prior_envelope: Dictionary = catalog.published_catalog_snapshot()
	check("invalid_reload_rejected", not catalog.setup(["res://resources/visual/biomes/does-not-exist.tres"]))
	check("invalid_reload_retains_prior_publication", catalog.is_ready() \
		and is_same(prior_envelope, catalog.published_catalog_snapshot()) \
		and SnapshotScript.is_current(catalog, captured))
	var original_digest := String(prior_envelope.get("contentDigest", ""))
	var original_receipt: Dictionary = prior_envelope.get("ownerReceipt", {})
	check("same_content_reload_keeps_semantic_identity", catalog.setup() \
		and catalog.published_catalog_snapshot().get("contentDigest") == original_digest)
	check("same_content_reload_advances_owner_receipt", catalog.published_catalog_snapshot().get("ownerReceipt") != original_receipt \
		and not SnapshotScript.is_current(catalog, captured))
	var restored_capture: Dictionary = SnapshotScript.capture(catalog)
	var cached_original_scale := float(cached_alpine.tree_scale)
	cached_alpine.tree_scale = cached_original_scale + 0.25
	check("resource_loader_source_mutation_does_not_change_published_owner", SnapshotScript.is_current(catalog, restored_capture) \
		and catalog.profile_values_for_biome("alpine").get("tree_scale") == owner_scale)
	check("explicit_reload_publishes_changed_resource_content", catalog.setup() \
		and catalog.published_catalog_snapshot().get("contentDigest") != original_digest)
	check("changed_content_invalidates_previous_receipt", not SnapshotScript.is_current(catalog, restored_capture))
	cached_alpine.tree_scale = cached_original_scale
	check("restoring_source_and_reloading_restores_semantic_identity", catalog.setup() \
		and catalog.published_catalog_snapshot().get("contentDigest") == original_digest)
	var passed := true
	for result in results:
		passed = passed and bool(result.passed)
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-active-biome-snapshot-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({"finished": true, "passed": passed, "evidenceLevel": "contract",
		"scope": "Active catalog value capture and staleness only; not native adapter or live gameplay.",
		"resultCount": results.size(), "results": results, "directDigest": expected,
		"capturedDigest": captured.get("contentIdentity", "")}, "  "))
	file.close()
	quit(0 if passed else 1)

func check(name: String, passed: bool) -> void:
	results.append({"name": name, "passed": passed})

func _value_graph_is_frozen_values(value: Variant) -> bool:
	if value is Dictionary:
		var dictionary: Dictionary = value
		if not dictionary.is_read_only():
			return false
		for key in dictionary.keys():
			if not key is String or not _value_graph_is_frozen_values(dictionary[key]):
				return false
		return true
	if value is Array:
		var array: Array = value
		if not array.is_read_only():
			return false
		for item in array:
			if not _value_graph_is_frozen_values(item):
				return false
		return true
	return typeof(value) in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING]
