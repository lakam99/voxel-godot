extends SceneTree

const Oracle := preload("res://scripts/testing/native_world/N3EffectiveTerrainOracle.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var golden_sha_before := FileAccess.get_sha256(Oracle.GOLDENS_PATH)
	var goldens: Dictionary = Oracle.load_goldens()
	var profiles: Array = Oracle.site_profiles_from_goldens(goldens) if bool(goldens.get("ok", true)) else []
	var world_spec: Dictionary = goldens.get("world", {}) if goldens.get("world") is Dictionary else {}
	var world: Dictionary = Oracle.build_world(
		String(world_spec.get("seed", "")), profiles, Oracle.town_overrides_from_goldens(goldens))
	var samples: Dictionary = Oracle.sample_all(world, goldens)
	var comparison: Dictionary = Oracle.compare_to_goldens(samples, goldens)
	var counts := {}
	for channel in ["surfaceColumns", "cellCenters", "latticeNumeric", "worldNumeric", "surfaceProjectionNumeric"]:
		var rows = samples.get(channel, [])
		counts[channel] = rows.size() if rows is Array else -1
	var report := {
		"schema": "n3-effective-terrain-oracle-contract/v1",
		"passed": bool(comparison.get("ok", false)) \
			and profiles.size() == (world_spec.get("siteProfiles", []) as Array).size() \
			and counts == {
				"surfaceColumns": 10,
				"cellCenters": 11,
				"latticeNumeric": 11,
				"worldNumeric": 6,
				"surfaceProjectionNumeric": 9,
			} \
			and golden_sha_before == FileAccess.get_sha256(Oracle.GOLDENS_PATH),
		"querySetId": String((goldens.get("querySet", {}) as Dictionary).get("id", "")),
		"siteProfileCount": profiles.size(),
		"queryCounts": counts,
		"mismatchCount": int(comparison.get("mismatchCount", -1)),
		"mismatches": comparison.get("mismatches", []),
		"goldensSha256": golden_sha_before,
		"goldensUnchanged": golden_sha_before == FileAccess.get_sha256(Oracle.GOLDENS_PATH),
		"forbiddenNativePathsUsed": bool(samples.get("forbiddenNativePathsUsed", true)),
	}
	print(JSON.stringify(report))
	quit(0 if bool(report.passed) and not bool(report.forbiddenNativePathsUsed) else 1)
