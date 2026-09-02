extends SceneTree

## Source-only inventory prompted by actual headed03 occlusion. Does not move
## geometry or certify mesh intersections from source boxes.
const Visual = preload("res://scripts/testing/buildings/CitadelMarketRecipeVisual.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_TERMINAL_OCCLUSION_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path):
		quit(2)
		return
	var prepared: Dictionary = Visual._prepare_frozen_recipe(OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE"), true)
	var report := {"sourceProbeComplete": false, "evidenceLevel": "source_only_terminal_occlusion_inventory", "bays": []}
	if prepared.get("ready", false):
		var b = prepared.blueprint
		for setup in prepared.terminals.setups:
			var counter = b.find_part(String(setup.prefix) + "_counter")
			var bounds: AABB = b.transformed_part_bounds(counter)
			var overlaps: Array = []
			var vertical_column: Array = []
			for part in b.parts:
				if part.id == counter.id: continue
				var other: AABB = b.transformed_part_bounds(part)
				var overlap := bounds.end.min(other.end) - bounds.position.max(other.position)
				var fact := {"id": part.id, "kind": part.kind, "semantic": part.semantic, "bounds": other, "collision": part.collision_enabled}
				if overlap.x > 0 and overlap.y > 0 and overlap.z > 0: overlaps.append(fact)
				if other.position.x <= counter.position.x and other.end.x >= counter.position.x and other.position.z <= counter.position.z and other.end.z >= counter.position.z and other.end.y >= bounds.position.y:
					vertical_column.append(fact)
			report.bays.append({"prefix": setup.prefix, "counter": counter.snapshot(), "counterBounds": bounds,
				"frameSupport": b.find_part(String(setup.supportId)).snapshot(), "sourceBoxOverlaps": overlaps, "verticalColumn": vertical_column})
		report.sourceProbeComplete = true
	else:
		report["preparationFailure"] = prepared
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(Visual._serializable(report), "\t"))
	file.close()
	quit(0 if report.sourceProbeComplete else 1)
