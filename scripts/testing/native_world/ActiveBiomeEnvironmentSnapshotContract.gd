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
	var tampered_row: Dictionary = captured.duplicate(true)
	((tampered_row.profiles as Array)[0] as Dictionary)["tree_scale"] = {"value": 999.0}
	check("tampered_row_not_current", not SnapshotScript.is_current(catalog, tampered_row))
	var tampered_fallback: Dictionary = captured.duplicate(true)
	tampered_fallback.fallbackId = "alpine"
	check("tampered_fallback_not_current", not SnapshotScript.is_current(catalog, tampered_fallback))
	var tampered_schema: Dictionary = captured.duplicate(true)
	tampered_schema.schemaVersion = 2
	check("tampered_schema_not_current", not SnapshotScript.is_current(catalog, tampered_schema))
	var tampered_receipt: Dictionary = captured.duplicate(true)
	tampered_receipt.ownerReceipt.revision = int(tampered_receipt.ownerReceipt.revision) + 1
	check("tampered_receipt_not_current", not SnapshotScript.is_current(catalog, tampered_receipt))
	var tampered_identity: Dictionary = captured.duplicate(true)
	tampered_identity.contentIdentity = "not-the-content"
	check("tampered_identity_not_current", not SnapshotScript.is_current(catalog, tampered_identity))
	var old_row: Dictionary = (captured.get("profiles", []) as Array)[0]
	var old_scale: Dictionary = old_row.get("tree_scale", {})
	var alpine = catalog.profile_for_biome("alpine")
	var original_scale: float = alpine.tree_scale
	alpine.tree_scale = original_scale + 0.125
	check("mutable_resource_invalidates_content", not SnapshotScript.is_current(catalog, captured))
	var changed: Dictionary = SnapshotScript.capture(catalog)
	check("mutation_changes_digest_without_receipt", changed.get("contentIdentity") != captured.get("contentIdentity") \
		and changed.get("ownerReceipt") == captured.get("ownerReceipt"))
	check("capture_is_value_copy", old_scale == ((captured.get("profiles", []) as Array)[0] as Dictionary).get("tree_scale") \
		and old_scale != ((changed.get("profiles", []) as Array)[0] as Dictionary).get("tree_scale"))
	alpine.tree_scale = original_scale
	check("restored_content_revalidates", SnapshotScript.is_current(catalog, captured))
	var original_families: PackedStringArray = alpine.tree_families
	alpine.tree_families = PackedStringArray()
	check("invalid_profile_rejected", not bool(SnapshotScript.capture(catalog).get("ok", false)))
	alpine.tree_families = original_families
	var original_id: String = alpine.biome_id
	alpine.biome_id = "other"
	check("changed_biome_identity_rejected", not bool(SnapshotScript.capture(catalog).get("ok", false)))
	alpine.biome_id = original_id
	check("setup_revision_invalidates", catalog.setup() and not SnapshotScript.is_current(catalog, captured))
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
