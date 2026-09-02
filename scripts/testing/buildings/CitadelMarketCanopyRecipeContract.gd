extends "res://scripts/testing/buildings/CitadelMarketVisualPreparationContract.gd"

## Frozen-source prototype only. Builds real frame geometry after candidate
## placement; does not claim that new frame/internal content clearance passes.
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")

func _run() -> void:
	var path := OS.get_environment("VOXEL_MARKET_CANOPY_RECIPE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path):
		quit(2)
		return
	var prepared: Dictionary = Visual._prepare_frozen_recipe(OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE"), true)
	var report := {"ready": false, "passed": false, "frames": [], "evidenceLevel": "frozen_source_recipe_prototype",
		"doesNotProve": "Not integrated. No published mesh/internal-content clearance, visuals, access, physics, or gameplay acceptance. New frames built after provisional layout; layout clearance must include their complete geometry before integration."}
	if prepared.get("ready", false):
		var b = prepared.blueprint
		report["frames"] = prepared.canopies
		report["storageLayouts"] = prepared.storageLayouts
		report["terminals"] = prepared.terminals
		report["localWalkPlan"] = prepared.localWalkPlan
		report["ready"] = report.frames.size() == prepared.plans.size() and report.frames.all(func(row): return row.ready)
		if report.ready:
			var reviewed_source: Dictionary = b.snapshot()
			b.physical_parts_by_id.clear()
			for part in b.parts:
				b.physical_parts_by_id[part.id] = part
			var physical: Dictionary = b.validate_physical_integrity()
			report["physical"] = physical
			report["violations"] = physical.violations.size()
			report["baselineViolations"] = prepared.baselinePhysical.violations.size()
			report["addedViolations"] = physical.violations.filter(func(row): return not prepared.baselinePhysical.violations.has(row))
			report["removedViolations"] = prepared.baselinePhysical.violations.filter(func(row): return not physical.violations.has(row))
			# Re-run the real furniture planner on an independent composed copy;
			# compare with the immutable baseline artifact, not empty metadata.
			var archive := FileAccess.open(OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE"), FileAccess.READ)
			var frozen: Dictionary = archive.get_var(false).output
			archive.close()
			var snapshot: Dictionary = b.snapshot()
			var furniture_source = Visual.FrozenBlueprint.new(snapshot.id, snapshot.seed, snapshot.style)
			furniture_source.recipe = snapshot.recipe.duplicate(true)
			furniture_source.rooms = snapshot.rooms.duplicate(true)
			for record in snapshot.parts:
				var copy = furniture_source.add_part(record)
				copy.physical_intent = record.physicalIntent
			var furniture = Furniture.build(furniture_source, int(prepared.fixture.furnitureSeed))
			report["furnitureCount"] = 0 if furniture == null else furniture.parts.size()
			report["furnitureSnapshotPreserved"] = furniture != null and not furniture.parts.is_empty() and var_to_bytes(furniture.snapshot()) == var_to_bytes(frozen.furnitureSnapshot)
			report["reservationLimitation"] = "Baseline reservations are empty; furniture equality is not occupied-access or gameplay evidence."
			var comparison_path := OS.get_environment("VOXEL_MARKET_REVIEWED_COMPARE").strip_edges().simplify_path()
			if not comparison_path.is_empty():
				if not comparison_path.is_absolute_path() or FileAccess.get_sha256(comparison_path) != "e43b972eface80bbcbc015ef55ac0c21a5cb99083dcfa9aabbb5a407f9832038":
					printerr("Reviewed shop comparison requires the immutable pre-extraction artifact")
					quit(2)
					return
				var reference_file := FileAccess.open(comparison_path, FileAccess.READ)
				var reference: Dictionary = reference_file.get_var(false)
				reference_file.close()
				var actual := {"fixture": prepared.fixture, "sourceSnapshot": reviewed_source, "resolvedSnapshot": b.snapshot(),
					"physicalValidation": physical, "furnitureSnapshot": furniture.snapshot(),
					"protectedReservations": furniture.protected_access_reservations.duplicate(true)}
				var parity: Dictionary = {}
				for key in actual: parity[key] = var_to_bytes(actual[key]) == var_to_bytes(reference[key])
				report["reviewedExactParity"] = parity
				report["ready"] = report.ready and parity.values().all(func(value): return value)
			var reviewed_path := OS.get_environment("VOXEL_MARKET_REVIEWED_SNAPSHOT").strip_edges().simplify_path()
			if not reviewed_path.is_empty():
				if not reviewed_path.is_absolute_path() or FileAccess.file_exists(reviewed_path) or not DirAccess.dir_exists_absolute(reviewed_path.get_base_dir()) or furniture == null:
					printerr("Refusing invalid/existing reviewed snapshot destination")
					quit(2)
					return
				var evidence := FileAccess.open(reviewed_path, FileAccess.WRITE)
				if evidence == null:
					quit(2)
					return
				evidence.store_var({"schemaVersion": 1, "provenance": "critic_reviewed_market_terminal_headed05",
					"fixture": prepared.fixture, "sourceSnapshot": reviewed_source, "resolvedSnapshot": b.snapshot(),
					"physicalValidation": physical, "furnitureSnapshot": furniture.snapshot(),
					"protectedReservations": furniture.protected_access_reservations.duplicate(true)}, false)
				evidence.close()
				report["reviewedSnapshot"] = reviewed_path
				report["reviewedSnapshotSha256"] = FileAccess.get_sha256(reviewed_path)
			report["passed"] = physical.passed
	else:
		report["preparationFailure"] = prepared
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.close()
	# Diagnostic completion is distinct from physical acceptance.
	quit(0 if report.ready else 1)
