extends "res://scripts/testing/buildings/CitadelMarketPlacementProbe.gd"

## Frozen-source contract invokes the SHARED recipe adapter, never a copied
## search or a selected transform from a previous report.
func _extra_checks(report: Dictionary, blueprint, _boxes: Dictionary, groups: Array, _claimed: Dictionary) -> void:
	var group: Dictionary = groups[2]
	var result: Dictionary = Urban.plan_household_on_paving(blueprint, group.allIds,
		Vector3(0.0, 0.0, -float(group.layoutSpec.depth)))
	var preserved := result.duplicate(true)
	if result.get("transform") is Transform3D:
		var transform: Transform3D = result.transform
		preserved["transform"] = {"origin": transform.origin,
			"basis": [transform.basis.x, transform.basis.y, transform.basis.z]}
	report["sharedRecipeResult"] = preserved
	report["extraChecksCompleted"] = bool(result.get("ready", false))
