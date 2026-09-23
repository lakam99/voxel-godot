extends SceneTree

const MainScript := preload("res://scripts/Main.gd")
const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const VisualScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const AnimatedScript := preload("res://scripts/visual/AnimatedAssetRegistry.gd")
const BundleScript := preload("res://scripts/world/ActiveSurfacePropOwnerBundle.gd")

var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func check(name: String, passed: bool) -> void:
	results.append({"name": name, "passed": passed})
	if not passed:
		push_error("surface owner bundle: " + name)

func run() -> void:
	var main = MainScript.new()
	main.seed_text = "bundle-seed"
	main.removed_props = {"bundle-seed:1,2:0": true}
	check("unready_rejected", not bool(BundleScript.capture(main).get("ok", false)))
	var catalog = CatalogScript.new()
	var visual = VisualScript.new()
	var animated = AnimatedScript.new()
	check("catalog_ready", catalog.setup())
	check("visual_ready", visual.setup(catalog))
	check("animated_ready", animated.setup())
	main.biome_environment_catalog = catalog
	main.visual_asset_registry = visual
	main.animated_asset_registry = animated
	var bundle: Dictionary = BundleScript.capture(main)
	check("bundle_captured", bool(bundle.get("ok", false)))
	check("explicitly_incomplete", bundle.get("complete") == false \
		and bundle.get("scope") == "owner_catalogs_and_removals_only")
	check("initial_current", BundleScript.is_current(main, bundle))
	var forged_complete := bundle.duplicate(true)
	forged_complete.complete = true
	check("complete_claim_rejected", not BundleScript.is_current(main, forged_complete))
	var tampered := bundle.duplicate(true)
	(tampered.removed.ids as Array)[0] = "tampered"
	check("nested_removal_tamper_rejected", not BundleScript.is_current(main, tampered))
	var other = MainScript.new()
	other.seed_text = main.seed_text
	other.removed_props = main.removed_props.duplicate(true)
	other.biome_environment_catalog = catalog
	other.visual_asset_registry = visual
	other.animated_asset_registry = animated
	check("cross_main_rejected", not BundleScript.is_current(other, bundle))
	other.free()
	var original_seed: String = main.seed_text
	main.seed_text = "replacement-seed"
	check("seed_change_rejected", not BundleScript.is_current(main, bundle))
	main.seed_text = original_seed
	main.restore_removed_props(["bundle-seed:1,2:0"])
	check("same_content_restore_rejected", not BundleScript.is_current(main, bundle))
	var recaptured: Dictionary = BundleScript.capture(main)
	check("recapture_current", BundleScript.is_current(main, recaptured))
	var other_visual = VisualScript.new()
	check("replacement_visual_ready", other_visual.setup(catalog))
	main.visual_asset_registry = other_visual
	check("registry_replacement_rejected", not BundleScript.is_current(main, recaptured))
	main.free()
	var passed := true
	for item in results:
		passed = passed and bool(item.passed)
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-active-surface-owner-bundle-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({"finished": true, "passed": passed,
		"evidenceLevel": "contract", "resultCount": results.size(), "results": results,
		"scope": "Owner catalog/removal capture and freshness only; no terrain pin, structure halo, native manifest or gameplay."}, "  "))
	file.close()
	quit(0 if passed else 1)
