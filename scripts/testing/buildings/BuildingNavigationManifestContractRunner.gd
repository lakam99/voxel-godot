extends SceneTree

## Focused VOX-223 source contract.  It proves that the construction blueprint
## produces deterministic, source-addressable walkable supports, physical
## stair links, and construction/furnishing collision facts. It deliberately
## does not claim live NPC movement or navmesh traversal; the Citadel Life
## fixture remains that evidence level.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const FurnishingNavigationManifestBuilderScript := preload("res://scripts/buildings/FurnishingNavigationManifestBuilder.gd")
const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const SEEDS: Array[int] = [208158, 208159, 306701]
const CELL := NpcConstantsScript.CELL_SIZE

var failures: Array[String] = []
var report_path := ""


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_BUILDING_NAVIGATION_MANIFEST_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/building-navigation-manifest-contract.json")
	var rows: Array[Dictionary] = []
	var negative_contracts := {
		"missingPassageProvenance": verify_missing_passage_provenance_rejected(),
		"thirdPassageEntry": verify_third_passage_entry_rejected(),
		"mismatchedPassageEntries": verify_mismatched_passage_entries_rejected(),
		"undersizedPassage": verify_undersized_passage_rejected(),
		"undersizedPassageHeight": verify_undersized_passage_height_rejected(),
		"blockedAdjacentSupports": verify_blocked_adjacent_supports_rejected(),
		"shallowDeclaredTransition": verify_shallow_declared_transition_published(),
		"missingRequiredDoorEgress": verify_missing_required_door_egress_rejected(),
		"blockedRequiredDoorEgress": verify_blocked_required_door_egress_rejected(),
		"substitutedDoorEgressPaving": verify_substituted_door_egress_paving_rejected(),
		"rotatedDoorEgressNearMiss": verify_rotated_door_egress_near_miss_accepted()
	}
	var negatives_only := OS.get_environment("VOXEL_BUILDING_NAVIGATION_MANIFEST_NEGATIVES_ONLY") == "1"
	if negatives_only:
		var negative_report := {
			"runnerId": "building_navigation_manifest_contract",
			"evidenceLevel": "contract",
			"scope": "Focused negative contracts only; this does not execute seeded compound coverage or prove live movement.",
			"negativeContracts": negative_contracts,
			"passed": failures.is_empty(),
			"failures": failures
		}
		write_report(negative_report)
		print(JSON.stringify(negative_report))
		quit(0 if failures.is_empty() else 1)
		return
	for seed in SEEDS:
		rows.append(verify_seed(seed))
	var interior_passage_link_count := 0
	for row in rows:
		interior_passage_link_count += int(row.get("interiorPassageLinkCount", 0))
	check(interior_passage_link_count > 0, "navigation manifest contract published no collision-backed interior passage links across its seed set")
	var report := {
		"runnerId": "building_navigation_manifest_contract",
		"evidenceLevel": "contract",
		"scope": "Deterministic BuildingPart- and FurnishingPart-derived support, stair-link, doorway-anchor, rotated collision-footprint, and collision facts for layered buildings. It does not prove NavMesh installation, CharacterBody3D movement, live door traversal, or Citadel Life behavior.",
		"seeds": SEEDS,
		"negativeContracts": negative_contracts,
		"passed": failures.is_empty(),
		"rows": rows,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func verify_missing_passage_provenance_rejected() -> Dictionary:
	var blueprint = BuildingBlueprintScript.new("building_navigation_missing_passage_provenance", 17, "timber")
	blueprint.add_part({
		"id": "shared_floor",
		"kind": "floor",
		"material": "timber_board",
		"position": Vector3(0.0, 0.10, 0.0),
		"size": Vector3(4.0, 0.20, 4.0),
		"collision": true,
		"recipe": {"navigationRole": "walkable_support", "physicalIntent": "walkable_surface"}
	})
	var undeclared_passage := {"id": "undeclared", "kind": "interior_passage", "position": Vector3.ZERO, "size": Vector3(1.50, 2.10, 2.20)}
	blueprint.set_room_records([
		{"id": "left", "bounds": AABB(Vector3(-2.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [undeclared_passage]},
		{"id": "right", "bounds": AABB(Vector3(0.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [undeclared_passage]}
	])
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var rejections: Array = manifest.get("interiorPassageRejections", []) as Array
	var rejected_for_missing_provenance := rejections.any(func(value) -> bool:
		return value is Dictionary and String((value as Dictionary).get("reason", "")) == "passage_provenance_missing"
	)
	check((manifest.get("interiorPassageLinks", []) as Array).is_empty(), "missing-provenance passage emitted an inferred navigation link")
	check(rejected_for_missing_provenance, "missing-provenance passage did not fail closed with a provenance rejection")
	return {"passed": (manifest.get("interiorPassageLinks", []) as Array).is_empty() and rejected_for_missing_provenance, "rejections": rejections}


func verify_third_passage_entry_rejected() -> Dictionary:
	var blueprint = passage_negative_blueprint("building_navigation_third_passage_entry")
	var passage := {"id": "overdeclared", "kind": "interior_passage", "position": Vector3.ZERO, "size": Vector3(1.50, 2.10, 2.20), "crossingAxis": Vector3.RIGHT, "supportPartId": "shared_floor"}
	var left_passage := passage.duplicate(true)
	left_passage["endpointSide"] = -1
	var right_passage := passage.duplicate(true)
	right_passage["endpointSide"] = 1
	blueprint.set_room_records([
		{"id": "left", "bounds": AABB(Vector3(-2.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [left_passage]},
		{"id": "right", "bounds": AABB(Vector3(0.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [right_passage]},
		{"id": "malformed_extra", "bounds": AABB(Vector3(-1.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [right_passage]}
	])
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var rejections: Array = manifest.get("interiorPassageRejections", []) as Array
	var rejected := rejections.any(func(value) -> bool:
		return value is Dictionary and String((value as Dictionary).get("reason", "")) == "passage_requires_exactly_two_entries"
	)
	var no_links := (manifest.get("interiorPassageLinks", []) as Array).is_empty()
	check(no_links, "three-entry passage silently published only its furthest pair")
	check(rejected, "three-entry passage did not fail closed")
	return {"passed": no_links and rejected, "rejections": rejections}


func verify_undersized_passage_rejected() -> Dictionary:
	var blueprint = passage_negative_blueprint("building_navigation_undersized_passage")
	var passage := {"id": "undersized", "kind": "interior_passage", "position": Vector3.ZERO, "size": Vector3(0.60, 2.10, 2.20), "crossingAxis": Vector3.RIGHT, "supportPartId": "shared_floor"}
	var left_passage := passage.duplicate(true)
	left_passage["endpointSide"] = -1
	var right_passage := passage.duplicate(true)
	right_passage["endpointSide"] = 1
	blueprint.set_room_records([
		{"id": "left", "bounds": AABB(Vector3(-2.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [left_passage]},
		{"id": "right", "bounds": AABB(Vector3(0.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [right_passage]}
	])
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var rejections: Array = manifest.get("interiorPassageRejections", []) as Array
	var rejected := rejections.any(func(value) -> bool:
		return value is Dictionary and String((value as Dictionary).get("reason", "")) == "passage_clearance_undersized"
	)
	var no_links := (manifest.get("interiorPassageLinks", []) as Array).is_empty()
	check(no_links, "undersized passage published a navigation link")
	check(rejected, "undersized passage disappeared without a rejection")
	return {"passed": no_links and rejected, "rejections": rejections}


func verify_mismatched_passage_entries_rejected() -> Dictionary:
	var blueprint = passage_negative_blueprint("building_navigation_mismatched_passage_entries")
	var left_passage := {"id": "mismatched", "kind": "interior_passage", "position": Vector3(-0.20, 0.0, 0.0), "size": Vector3(1.50, 2.10, 2.20), "crossingAxis": Vector3.RIGHT, "endpointSide": -1, "supportPartId": "shared_floor"}
	var right_passage := left_passage.duplicate(true)
	right_passage["position"] = Vector3(0.20, 0.0, 0.0)
	right_passage["endpointSide"] = 1
	blueprint.set_room_records([
		{"id": "left", "bounds": AABB(Vector3(-2.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [left_passage]},
		{"id": "right", "bounds": AABB(Vector3(0.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [right_passage]}
	])
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var rejections: Array = manifest.get("interiorPassageRejections", []) as Array
	var rejected := rejections.any(func(value) -> bool:
		return value is Dictionary and String((value as Dictionary).get("reason", "")) == "passage_entry_geometry_mismatch"
	)
	var no_links := (manifest.get("interiorPassageLinks", []) as Array).is_empty()
	check(no_links, "distinct same-cell apertures were paired into one passage")
	check(rejected, "distinct same-cell apertures did not fail closed")
	return {"passed": no_links and rejected, "rejections": rejections}


func verify_undersized_passage_height_rejected() -> Dictionary:
	var blueprint = passage_negative_blueprint("building_navigation_undersized_passage_height")
	var passage := {"id": "low", "kind": "interior_passage", "position": Vector3.ZERO, "size": Vector3(1.50, 0.40, 2.20), "crossingAxis": Vector3.RIGHT, "supportPartId": "shared_floor"}
	var left_passage := passage.duplicate(true)
	left_passage["endpointSide"] = -1
	var right_passage := passage.duplicate(true)
	right_passage["endpointSide"] = 1
	blueprint.set_room_records([
		{"id": "left", "bounds": AABB(Vector3(-2.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [left_passage]},
		{"id": "right", "bounds": AABB(Vector3(0.0, 0.0, -2.0), Vector3(2.0, 3.0, 4.0)), "accesses": [right_passage]}
	])
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var rejections: Array = manifest.get("interiorPassageRejections", []) as Array
	var rejected := rejections.any(func(value) -> bool:
		return value is Dictionary and String((value as Dictionary).get("reason", "")) == "passage_height_undersized"
	)
	var no_links := (manifest.get("interiorPassageLinks", []) as Array).is_empty()
	check(no_links, "undersized-height passage published a navigation link")
	check(rejected, "undersized-height passage disappeared without a rejection")
	return {"passed": no_links and rejected, "rejections": rejections}


func passage_negative_blueprint(blueprint_id: String):
	var blueprint = BuildingBlueprintScript.new(blueprint_id, 19, "timber")
	blueprint.add_part({
		"id": "shared_floor",
		"kind": "floor",
		"material": "timber_board",
		"position": Vector3(0.0, 0.10, 0.0),
		"size": Vector3(4.0, 0.20, 4.0),
		"collision": true,
		"recipe": {"navigationRole": "walkable_support", "physicalIntent": "walkable_surface"}
	})
	return blueprint


func verify_shallow_declared_transition_published() -> Dictionary:
	var blueprint = BuildingBlueprintScript.new("building_navigation_shallow_transition", 29, "timber")
	blueprint.add_part({
		"id": "lower_floor",
		"kind": "floor",
		"material": "timber_board",
		"position": Vector3(0.0, 0.10, -1.20),
		"size": Vector3(2.40, 0.20, 1.60),
		"collision": true,
		"recipe": {"navigationRole": "walkable_support"}
	})
	blueprint.add_part({
		"id": "upper_floor",
		"kind": "floor",
		"material": "timber_board",
		"position": Vector3(0.0, 0.16, 1.20),
		"size": Vector3(2.40, 0.20, 1.60),
		"collision": true,
		"recipe": {"navigationRole": "walkable_support"}
	})
	var ramp_length := 1.20
	var rise := 0.06
	blueprint.add_part({
		"id": "declared_shallow_ramp",
		"kind": "ramp",
		"material": "timber_board",
		"position": Vector3(0.0, 0.13, 0.0),
		"size": Vector3(1.40, 0.14, ramp_length),
		"rotation": Vector3(-atan2(rise, ramp_length), 0.0, 0.0),
		"collision": true,
		"recipe": {
			"navigationRole": "transition",
			"navigationStartSupportPartId": "lower_floor",
			"navigationEndSupportPartId": "upper_floor"
		}
	})
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var links: Array = manifest.get("verticalLinks", []) as Array
	var link: Dictionary = links[0] as Dictionary if links.size() == 1 else {}
	var published := links.size() == 1 \
		and String(link.get("startSupportPartId", "")) == "lower_floor" \
		and String(link.get("endSupportPartId", "")) == "upper_floor" \
		and not String(link.get("startSupportId", "")).is_empty() \
		and not String(link.get("endSupportId", "")).is_empty()
	check(published, "an explicitly declared shallow transition was omitted from the navigation manifest")
	return {"passed": published, "verticalLinks": links}


func verify_missing_required_door_egress_rejected() -> Dictionary:
	var blueprint = CottageBlueprintBuilderScript.build(208159, "timber")
	for part in blueprint.parts:
		if part != null and String(part.id) == "front_entry_ramp":
			part.recipe["navigationEndSupportPartId"] = "missing_entry_threshold"
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var front_door: Dictionary = {}
	for door_value in manifest.get("doors", []) as Array:
		if door_value is Dictionary and String((door_value as Dictionary).get("sourcePartId", "")) == "front_door":
			front_door = door_value as Dictionary
			break
	var egress_resolution: Dictionary = front_door.get("egressResolution", {}) as Dictionary
	var rejected := not front_door.is_empty() \
		and not bool(front_door.get("sourcePortalReady", false)) \
		and not bool(egress_resolution.get("resolved", false)) \
		and String(egress_resolution.get("reason", "")) == "required_egress_transition_unresolved"
	check(rejected, "door portal remained ready after its required ramp-to-threshold landing was removed")
	return {"passed": rejected, "door": front_door}


func verify_blocked_required_door_egress_rejected() -> Dictionary:
	var blueprint = CottageBlueprintBuilderScript.build(208159, "timber")
	var ramp = blueprint.parts.filter(func(part) -> bool: return part != null and String(part.id) == "front_entry_ramp").front()
	var ramp_basis := Basis.from_euler(ramp.rotation)
	var upper_endpoint: Vector3 = ramp.position + ramp_basis * Vector3(0.0, ramp.size.y * 0.5, ramp.size.z * 0.5)
	blueprint.add_part({
		"id": "mutated_entry_jamb",
		"kind": "wall",
		"material": "timber_board",
		"position": upper_endpoint + Vector3.UP * 0.90,
		"size": Vector3(0.24, 1.80, 0.24),
		"collision": true,
		"recipe": {"navigationRole": "structural_mass"}
	})
	var parent_transform := Transform3D(Basis.from_euler(Vector3(0.0, 0.37, 0.0)), Vector3(13.0, 2.5, -7.0))
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint, parent_transform)
	var door := door_fact_for_source_part(manifest, "front_door")
	var egress_resolution: Dictionary = door.get("egressResolution", {}) as Dictionary
	var link := vertical_link_for_source_part(manifest, "front_entry_ramp")
	var adapter_diagnostics := GeneratedWorldNavigationAdapterScript.building_navigation_link_resolution_contract(manifest, [], [String(link.get("id", ""))])
	var published_links := GeneratedWorldNavigationAdapterScript.building_navigation_snapshot_link_contract(manifest, [], [String(link.get("id", ""))])
	var adapter_resolution: Dictionary = adapter_diagnostics[0] as Dictionary if adapter_diagnostics.size() == 1 else {}
	var manifest_end_resolution: Dictionary = (link.get("endpointCertification", {}) as Dictionary).get("end", {}) as Dictionary
	var rejected := not bool(door.get("sourcePortalReady", false)) \
		and not bool(egress_resolution.get("resolved", false)) \
		and not bool(adapter_resolution.get("accepted", true)) \
		and published_links.is_empty() \
		and String(manifest_end_resolution.get("reason", "")) == "endpoint_collision_blocked" \
		and String((adapter_resolution.get("endResolution", {}) as Dictionary).get("reason", "")) == "endpoint_collision_blocked"
	check(rejected, "transformed doorway remained ready when a jamb occupied its required ramp landing")
	return {"passed": rejected, "door": door, "link": link, "adapterResolution": adapter_resolution, "publishedLinks": published_links}


func verify_substituted_door_egress_paving_rejected() -> Dictionary:
	var blueprint = CottageBlueprintBuilderScript.build(208159, "timber")
	var source_paving = blueprint.parts.filter(func(part) -> bool: return part != null and String(part.id) == "front_entry_paving").front()
	blueprint.add_part({
		"id": "neighbor_paving",
		"kind": "foundation",
		"material": "cobblestone",
		"position": source_paving.position,
		"size": source_paving.size,
		"collision": true,
		"recipe": {"navigationRole": "walkable_support"}
	})
	for part in blueprint.parts:
		if part != null and String(part.id) == "front_entry_ramp":
			part.recipe["navigationStartSupportPartId"] = "neighbor_paving"
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var door := door_fact_for_source_part(manifest, "front_door")
	var egress_resolution: Dictionary = door.get("egressResolution", {}) as Dictionary
	var link := vertical_link_for_source_part(manifest, "front_entry_ramp")
	var adapter_diagnostics := GeneratedWorldNavigationAdapterScript.building_navigation_link_resolution_contract(manifest, [], [String(link.get("id", ""))])
	var published_links := GeneratedWorldNavigationAdapterScript.building_navigation_snapshot_link_contract(manifest, [], [String(link.get("id", ""))])
	var adapter_resolution: Dictionary = adapter_diagnostics[0] as Dictionary if adapter_diagnostics.size() == 1 else {}
	var rejected := not bool(door.get("sourcePortalReady", false)) \
		and not bool(egress_resolution.get("resolved", false)) \
		and String(((link.get("endpointCertification", {}) as Dictionary)).get("reason", "")) == "egress_support_owner_mismatch" \
		and not bool(adapter_resolution.get("accepted", true)) \
		and String(adapter_resolution.get("reason", "")) == "egress_support_owner_mismatch" \
		and published_links.is_empty()
	check(rejected, "doorway accepted a neighboring paving support that is not owned by its egress recipe")
	return {"passed": rejected, "door": door, "link": link, "adapterResolution": adapter_resolution, "publishedLinks": published_links}


func verify_rotated_door_egress_near_miss_accepted() -> Dictionary:
	var blueprint = CottageBlueprintBuilderScript.build(208159, "timber")
	var parent_transform := Transform3D(Basis.from_euler(Vector3(0.0, 0.37, 0.0)), Vector3(13.0, 2.5, -7.0))
	var manifest := BuildingNavigationManifestBuilderScript.build(blueprint, parent_transform)
	var link := vertical_link_for_source_part(manifest, "front_entry_ramp")
	var adapter_diagnostics := GeneratedWorldNavigationAdapterScript.building_navigation_link_resolution_contract(manifest, [], [String(link.get("id", ""))])
	var published_links := GeneratedWorldNavigationAdapterScript.building_navigation_snapshot_link_contract(manifest, [], [String(link.get("id", ""))])
	var adapter_resolution: Dictionary = adapter_diagnostics[0] as Dictionary if adapter_diagnostics.size() == 1 else {}
	var published_link: Dictionary = published_links[0] as Dictionary if published_links.size() == 1 else {}
	var start_resolution: Dictionary = adapter_resolution.get("startResolution", {}) as Dictionary
	var end_resolution: Dictionary = adapter_resolution.get("endResolution", {}) as Dictionary
	var passed := bool(adapter_resolution.get("accepted", false)) \
		and String(start_resolution.get("supportId", "")) == String(link.get("startSupportId", "")) \
		and String(end_resolution.get("supportId", "")) == String(link.get("endSupportId", "")) \
		and (start_resolution.get("position", Vector3.INF) as Vector3).is_equal_approx(link.get("start", Vector3.ZERO) as Vector3) \
		and (end_resolution.get("position", Vector3.INF) as Vector3).is_equal_approx(link.get("end", Vector3.ZERO) as Vector3) \
		and published_links.size() == 1 \
		and String(published_link.get("startSupportId", "")) == String(link.get("startSupportId", "")) \
		and String(published_link.get("endSupportId", "")) == String(link.get("endSupportId", "")) \
		and (published_link.get("start", Vector3.INF) as Vector3).is_equal_approx(link.get("start", Vector3.ZERO) as Vector3) \
		and (published_link.get("end", Vector3.INF) as Vector3).is_equal_approx(link.get("end", Vector3.ZERO) as Vector3)
	check(passed, "rotated cottage near-miss did not produce matching manifest/runtime egress endpoints")
	return {"passed": passed, "link": link, "adapterResolution": adapter_resolution, "publishedLinks": published_links}


func door_fact_for_source_part(manifest: Dictionary, source_part_id: String) -> Dictionary:
	for door_value in manifest.get("doors", []) as Array:
		if door_value is Dictionary and String((door_value as Dictionary).get("sourcePartId", "")) == source_part_id:
			return door_value as Dictionary
	return {}


func vertical_link_for_source_part(manifest: Dictionary, source_part_id: String) -> Dictionary:
	for link_value in manifest.get("verticalLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("sourcePartId", "")) == source_part_id:
			return link_value as Dictionary
	return {}


func verify_blocked_adjacent_supports_rejected() -> Dictionary:
	var blueprint = BuildingBlueprintScript.new("building_navigation_blocked_adjacent_supports", 23, "masonry")
	blueprint.add_part({
		"id": "test_residence__left_floor",
		"kind": "floor",
		"material": "timber_board",
		"position": Vector3(-1.0, 0.10, 0.0),
		"size": Vector3(2.0, 0.20, 4.0),
		"collision": true,
		"recipe": {"navigationRole": "walkable_support", "physicalIntent": "walkable_surface"}
	})
	blueprint.add_part({
		"id": "test_residence__right_floor",
		"kind": "floor",
		"material": "timber_board",
		"position": Vector3(1.0, 0.10, 0.0),
		"size": Vector3(2.0, 0.20, 4.0),
		"collision": true,
		"recipe": {"navigationRole": "walkable_support", "physicalIntent": "walkable_surface"}
	})
	var clear_manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var clear_supports: Array = clear_manifest.get("supports", []) as Array
	check(clear_supports.size() == 2, "adjacent-support mutation did not publish two floor supports")
	if clear_supports.size() != 2:
		return {"passed": false, "reason": "missing_test_supports"}
	var left_support_id := support_id_for_source_part(clear_supports, "test_residence__left_floor")
	var probes := [
		{"id": "left", "position": Vector3(-1.20, 0.24, 0.0)},
		{"id": "right", "position": Vector3(1.20, 0.24, 0.0)}
	]
	var clear_connectivity := GeneratedWorldNavigationAdapterScript.source_support_connectivity(clear_manifest, [], left_support_id, probes, 1.25)
	blueprint.add_part({
		"id": "test_wall",
		"kind": "wall",
		"material": "stone_foundation",
		"position": Vector3(0.0, 1.20, 0.0),
		"size": Vector3(0.10, 2.40, 4.20),
		"collision": true,
		"recipe": {"navigationRole": "structural_mass", "physicalIntent": "structural_mass"}
	})
	var blocked_manifest := BuildingNavigationManifestBuilderScript.build(blueprint)
	var blocked_connectivity := GeneratedWorldNavigationAdapterScript.source_support_connectivity(blocked_manifest, [], left_support_id, probes, 1.25)
	var clear_reachable := bool(clear_connectivity.get("reachable", false))
	var blocked_rejected := not bool(blocked_connectivity.get("reachable", false)) and String(blocked_connectivity.get("reason", "")) == "collision_screened_support_disconnected"
	check(clear_reachable, "adjacent published supports were disconnected before the wall mutation")
	check(blocked_rejected, "wall mutation did not disconnect adjacent published supports through source_support_connectivity")
	return {"passed": clear_reachable and blocked_rejected, "clearConnectivity": clear_connectivity, "blockedConnectivity": blocked_connectivity}


func support_id_for_source_part(supports: Array, source_part_id: String) -> String:
	for support_value in supports:
		if support_value is Dictionary and String((support_value as Dictionary).get("sourcePartId", "")) == source_part_id:
			return String((support_value as Dictionary).get("id", ""))
	return ""


func verify_seed(seed: int) -> Dictionary:
	var context := {
		"biome": "forest",
		"siteKey": "building-navigation-contract",
		"citadelScale": 1.25
	}
	var first_blueprint = CastleCompoundBlueprintBuilderScript.build(seed, context)
	var replay_blueprint = CastleCompoundBlueprintBuilderScript.build(seed, context)
	var parent_transform := Transform3D(Basis.from_euler(Vector3(0.0, 0.37, 0.0)), Vector3(13.0, 2.5, -7.0))
	var manifest := BuildingNavigationManifestBuilderScript.build(first_blueprint, parent_transform)
	var replay := BuildingNavigationManifestBuilderScript.build(replay_blueprint, parent_transform)
	var furnishing_plan = CastleFurnishingPlannerScript.build(first_blueprint, seed * 7919 + 37)
	var furnishing_replay = CastleFurnishingPlannerScript.build(replay_blueprint, seed * 7919 + 37)
	var furnishing_manifest := FurnishingNavigationManifestBuilderScript.build(furnishing_plan, parent_transform)
	var furnishing_manifest_replay := FurnishingNavigationManifestBuilderScript.build(furnishing_replay, parent_transform)
	check(JSON.stringify(manifest) == JSON.stringify(replay), "seed %d navigation manifest is not deterministic" % seed)
	check(JSON.stringify(furnishing_manifest) == JSON.stringify(furnishing_manifest_replay), "seed %d furnishing navigation manifest is not deterministic" % seed)
	var source_ids := {}
	for id_value in manifest.get("sourcePartIds", []):
		source_ids[String(id_value)] = true
	var supports: Array = manifest.get("supports", []) as Array
	var links: Array = manifest.get("verticalLinks", []) as Array
	var support_seam_links: Array = manifest.get("supportSeamLinks", []) as Array
	var interior_passage_links: Array = manifest.get("interiorPassageLinks", []) as Array
	var interior_passage_rejections: Array = manifest.get("interiorPassageRejections", []) as Array
	var doors: Array = manifest.get("doors", []) as Array
	var collision_parts: Array = manifest.get("staticCollision", []) as Array
	var furnishing_collision_parts: Array = furnishing_manifest.get("staticCollision", []) as Array
	var manor_tower_passages := {}
	var required_manor_passages := {
		"manor_lower_floor_to_bridge": ["__manor_main_lower_floor", "__manor_lower_tower_bridge"],
		"manor_lower_bridge_to_stair": ["__manor_lower_tower_bridge", "__manor_stair_tower_floor"],
		"manor_solar_floor_to_bridge": ["__manor_solar_upper_floor", "__manor_solar_tower_bridge"],
		"manor_solar_bridge_to_stair": ["__manor_solar_tower_bridge", "__manor_stair_exit_0"]
	}
	var support_part_ids := {}
	for support_value in manifest.get("supports", []) as Array:
		if support_value is Dictionary:
			support_part_ids[String((support_value as Dictionary).get("sourcePartId", ""))] = true
	check(not supports.is_empty(), "seed %d published no walkable building supports" % seed)
	check(not links.is_empty(), "seed %d published no physical stair/ramp links" % seed)
	check(int(manifest.get("supportCount", -1)) == supports.size(), "seed %d support count disagrees with support facts" % seed)
	check(int(manifest.get("verticalLinkCount", -1)) == links.size(), "seed %d link count disagrees with link facts" % seed)
	check(int(manifest.get("supportSeamLinkCount", -1)) == support_seam_links.size(), "seed %d support seam link count disagrees with link facts" % seed)
	check(int(manifest.get("interiorPassageLinkCount", -1)) == interior_passage_links.size(), "seed %d interior passage link count disagrees with link facts" % seed)
	check(int(manifest.get("interiorPassageRejectionCount", -1)) == interior_passage_rejections.size(), "seed %d interior passage rejection count disagrees with rejection facts" % seed)
	check(interior_passage_rejections.is_empty(), "seed %d has rejected production interior passages: %s" % [seed, JSON.stringify(interior_passage_rejections)])
	check(int(manifest.get("doorCount", -1)) == doors.size(), "seed %d door count disagrees with door facts" % seed)
	check(int(manifest.get("staticCollisionCount", -1)) == collision_parts.size(), "seed %d construction collision count disagrees with collision facts" % seed)
	check(int(furnishing_manifest.get("staticCollisionCount", -1)) == furnishing_collision_parts.size(), "seed %d furnishing collision count disagrees with collision facts" % seed)
	for collision_value in collision_parts:
		if collision_value is Dictionary:
			var collision: Dictionary = collision_value
			check(not support_part_ids.has(String(collision.get("sourcePartId", ""))), "seed %d emits a walkable support as a static navigation blocker" % seed)
	var support_ids := {}
	var supports_by_id := {}
	var elevations := {}
	for support_value in supports:
		if not (support_value is Dictionary):
			check(false, "seed %d has malformed support fact" % seed)
			continue
		var support: Dictionary = support_value
		var support_id := String(support.get("id", ""))
		var source_part_id := String(support.get("sourceCollisionPartId", ""))
		check(not support_id.is_empty() and not support_ids.has(support_id), "seed %d has missing/duplicate support id %s" % [seed, support_id])
		check(source_ids.has(source_part_id), "seed %d support %s does not cite a collision source part" % [seed, support_id])
		check((support.get("polygon", []) as Array).size() >= 3, "seed %d support %s lacks a physical top polygon" % [seed, support_id])
		var normal: Vector3 = support.get("floorNormal", Vector3.ZERO) as Vector3
		check(normal.y >= 0.68, "seed %d support %s is not physically walkable" % [seed, support_id])
		var position: Vector3 = support.get("worldPosition", Vector3.ZERO) as Vector3
		elevations[roundi(position.y * 10.0)] = true
		support_ids[support_id] = true
		supports_by_id[support_id] = support
	check(elevations.size() >= 3, "seed %d did not expose multiple physical walkable elevations" % seed)
	for link_value in links:
		if not (link_value is Dictionary):
			check(false, "seed %d has malformed vertical link" % seed)
			continue
		var link: Dictionary = link_value
		var link_id := String(link.get("id", ""))
		var source_part_id := String(link.get("sourceCollisionPartId", ""))
		var start_support_id := String(link.get("startSupportId", ""))
		var end_support_id := String(link.get("endSupportId", ""))
		var start: Vector3 = link.get("start", Vector3.ZERO) as Vector3
		var end: Vector3 = link.get("end", Vector3.ZERO) as Vector3
		check(not link_id.is_empty(), "seed %d has an unnamed vertical link" % seed)
		check(source_ids.has(source_part_id), "seed %d vertical link %s does not cite a collision source part" % [seed, link_id])
		check(supports_by_id.has(start_support_id), "seed %d vertical link %s lacks a lower landing support" % [seed, link_id])
		check(supports_by_id.has(end_support_id), "seed %d vertical link %s lacks an upper landing support" % [seed, link_id])
		if supports_by_id.has(start_support_id):
			check(String((supports_by_id[start_support_id] as Dictionary).get("kind", "")) != "ramp", "seed %d vertical link %s anchors its lower endpoint to itself" % [seed, link_id])
		if supports_by_id.has(end_support_id):
			check(String((supports_by_id[end_support_id] as Dictionary).get("kind", "")) != "ramp", "seed %d vertical link %s anchors its upper endpoint to itself" % [seed, link_id])
		var minimum_rise := 0.01 if bool(link.get("declaredTransition", false)) else 0.10
		check(end.y > start.y + minimum_rise, "seed %d vertical link %s is not an ascending physical transition" % [seed, link_id])
		check_navigation_link_tiles(seed, "vertical", link)
	for link_value in support_seam_links:
		if not (link_value is Dictionary):
			check(false, "seed %d has malformed support seam link" % seed)
			continue
		var link: Dictionary = link_value
		var link_id := String(link.get("id", ""))
		var source_part_id := String(link.get("sourceCollisionPartId", ""))
		var support_id := String(link.get("supportId", ""))
		var start: Vector3 = link.get("start", Vector3.ZERO) as Vector3
		var end: Vector3 = link.get("end", Vector3.ZERO) as Vector3
		var tile_keys: Array = link.get("tileKeys", []) as Array
		check(not link_id.is_empty(), "seed %d has an unnamed support seam link" % seed)
		check(source_ids.has(source_part_id), "seed %d support seam link %s does not cite a collision source part" % [seed, link_id])
		check(supports_by_id.has(support_id), "seed %d support seam link %s cites an unknown support" % [seed, link_id])
		check(start.distance_to(end) > 0.10, "seed %d support seam link %s has coincident endpoints" % [seed, link_id])
		check(tile_keys.size() >= 2, "seed %d support seam link %s does not span navigation tiles" % [seed, link_id])
		check_navigation_link_tiles(seed, "support seam", link)
		if supports_by_id.has(support_id):
			var support: Dictionary = supports_by_id[support_id] as Dictionary
			check(point_within_support_xz(start, support), "seed %d support seam link %s start falls outside its support" % [seed, link_id])
			check(point_within_support_xz(end, support), "seed %d support seam link %s end falls outside its support" % [seed, link_id])
	for link_value in interior_passage_links:
		if not (link_value is Dictionary):
			check(false, "seed %d has malformed interior passage link" % seed)
			continue
		var link: Dictionary = link_value
		var link_id := String(link.get("id", ""))
		var access_id := String(link.get("sourceAccessId", ""))
		var room_ids: Array = link.get("roomIds", []) as Array
		var first_support_id := String(link.get("firstSupportId", ""))
		var second_support_id := String(link.get("secondSupportId", ""))
		var first_support_part_id := String(link.get("firstSupportPartId", ""))
		var second_support_part_id := String(link.get("secondSupportPartId", ""))
		var start: Vector3 = link.get("start", Vector3.ZERO) as Vector3
		var end: Vector3 = link.get("end", Vector3.ZERO) as Vector3
		check(not link_id.is_empty(), "seed %d has an unnamed interior passage link" % seed)
		check(not access_id.is_empty(), "seed %d interior passage link %s lacks its source access" % [seed, link_id])
		check(room_ids.size() == 2 and String(room_ids[0]) != String(room_ids[1]), "seed %d interior passage link %s does not connect two rooms" % [seed, link_id])
		check(supports_by_id.has(first_support_id), "seed %d interior passage link %s cites an unknown first support" % [seed, link_id])
		check(supports_by_id.has(second_support_id), "seed %d interior passage link %s cites an unknown second support" % [seed, link_id])
		check(start.distance_to(end) > 0.10, "seed %d interior passage link %s has coincident endpoints" % [seed, link_id])
		check_navigation_link_tiles(seed, "interior passage", link)
		if supports_by_id.has(first_support_id):
			check(point_within_support_xz(start, supports_by_id[first_support_id] as Dictionary), "seed %d interior passage link %s start falls outside its support" % [seed, link_id])
		if supports_by_id.has(second_support_id):
			check(point_within_support_xz(end, supports_by_id[second_support_id] as Dictionary), "seed %d interior passage link %s end falls outside its support" % [seed, link_id])
		if required_manor_passages.has(access_id):
			manor_tower_passages[access_id] = manor_tower_passages.get(access_id, 0) + 1
			check(first_support_part_id != second_support_part_id, "seed %d manor passage %s does not bridge distinct physical supports" % [seed, link_id])
			var expected_suffixes: Array = required_manor_passages.get(access_id, []) as Array
			check(first_support_part_id.ends_with(String(expected_suffixes[0])), "seed %d manor passage %s has the wrong first declared support" % [seed, link_id])
			check(second_support_part_id.ends_with(String(expected_suffixes[1])), "seed %d manor passage %s has the wrong second declared support" % [seed, link_id])
	for required_access_id_value in required_manor_passages.keys():
		var required_access_id := String(required_access_id_value)
		check(int(manor_tower_passages.get(required_access_id, 0)) > 0, "seed %d published no %s manor passage links" % [seed, required_access_id])
	var source_portal_count := 0
	for door_value in doors:
		if not (door_value is Dictionary):
			check(false, "seed %d has malformed doorway fact" % seed)
			continue
		var door: Dictionary = door_value
		var source_part_id := String(door.get("sourceCollisionPartId", ""))
		var interior: Vector3 = door.get("interior", Vector3.ZERO) as Vector3
		var exterior: Vector3 = door.get("exterior", Vector3.ZERO) as Vector3
		check(source_ids.has(source_part_id), "seed %d doorway does not cite a source door part" % seed)
		if bool(door.get("sourcePortalReady", false)):
			source_portal_count += 1
			check(interior.distance_to(exterior) >= 0.50, "seed %d doorway %s has coincident source anchors" % [seed, source_part_id])
			var interior_support_id := String(door.get("interiorSupportId", ""))
			var exterior_support_id := String(door.get("exteriorSupportId", ""))
			check(not interior_support_id.is_empty() and not exterior_support_id.is_empty(), "seed %d doorway %s lacks source support anchors" % [seed, source_part_id])
			check(supports_by_id.has(interior_support_id), "seed %d doorway %s cites an unknown interior support" % [seed, source_part_id])
			check(supports_by_id.has(exterior_support_id), "seed %d doorway %s cites an unknown exterior support" % [seed, source_part_id])
			if supports_by_id.has(interior_support_id):
				check(point_within_support_xz(interior, supports_by_id[interior_support_id] as Dictionary), "seed %d doorway %s interior anchor falls outside its support" % [seed, source_part_id])
			if supports_by_id.has(exterior_support_id):
				check(point_within_support_xz(exterior, supports_by_id[exterior_support_id] as Dictionary), "seed %d doorway %s exterior anchor falls outside its support" % [seed, source_part_id])
	check(source_portal_count > 0, "seed %d published no source-supported doorway anchors" % seed)
	for collision_value in collision_parts:
		if not (collision_value is Dictionary):
			check(false, "seed %d has malformed construction collision fact" % seed)
			continue
		var collision: Dictionary = collision_value
		var source_part_id := String(collision.get("sourceCollisionPartId", ""))
		var bounds: AABB = collision.get("bounds", AABB()) as AABB
		var footprint: Array = collision.get("footprint", []) as Array
		check(source_ids.has(source_part_id), "seed %d construction collision does not cite a source part" % seed)
		check(bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0, "seed %d construction collision %s lacks physical bounds" % [seed, source_part_id])
		check(footprint.size() == 4 and footprint.all(func(point) -> bool: return point is Vector3), "seed %d construction collision %s lacks an exact rotated footprint" % [seed, source_part_id])
	var furnishing_source_ids := {}
	for part in furnishing_plan.parts:
		if part != null and bool(part.collision_enabled):
			furnishing_source_ids[String(part.id)] = true
	for collision_value in furnishing_collision_parts:
		if not (collision_value is Dictionary):
			check(false, "seed %d has malformed furnishing collision fact" % seed)
			continue
		var collision: Dictionary = collision_value
		var source_part_id := String(collision.get("sourceCollisionPartId", ""))
		var bounds: AABB = collision.get("bounds", AABB()) as AABB
		var footprint: Array = collision.get("footprint", []) as Array
		check(furnishing_source_ids.has(source_part_id), "seed %d furnishing collision does not cite a source part" % seed)
		check(bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0, "seed %d furnishing collision %s lacks physical bounds" % [seed, source_part_id])
		check(footprint.size() == 4 and footprint.all(func(point) -> bool: return point is Vector3), "seed %d furnishing collision %s lacks an exact rotated footprint" % [seed, source_part_id])
	return {
		"seed": seed,
		"blueprintParts": first_blueprint.parts.size() if first_blueprint != null else 0,
		"supportCount": supports.size(),
		"verticalLinkCount": links.size(),
		"supportSeamLinkCount": support_seam_links.size(),
		"interiorPassageLinkCount": interior_passage_links.size(),
		"interiorPassageRejectionCount": interior_passage_rejections.size(),
		"manorTowerPassageCounts": manor_tower_passages,
		"doorCount": doors.size(),
		"sourcePortalCount": source_portal_count,
		"supportElevationCount": elevations.size(),
		"constructionCollisionCount": collision_parts.size(),
		"furnishingCollisionCount": furnishing_collision_parts.size()
	}


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func check_navigation_link_tiles(seed: int, kind: String, link: Dictionary) -> void:
	var link_id := String(link.get("id", ""))
	var start: Vector3 = link.get("start", Vector3.INF) as Vector3
	var end: Vector3 = link.get("end", Vector3.INF) as Vector3
	var tile_keys: Array = link.get("tileKeys", []) as Array
	var start_tile_key := String(link.get("startTileKey", ""))
	var end_tile_key := String(link.get("endTileKey", ""))
	var owner_tile_key := String(link.get("ownerTileKey", ""))
	check(not start_tile_key.is_empty(), "seed %d %s link %s lacks a start tile" % [seed, kind, link_id])
	check(not end_tile_key.is_empty(), "seed %d %s link %s lacks an end tile" % [seed, kind, link_id])
	check(not owner_tile_key.is_empty(), "seed %d %s link %s lacks an owner tile" % [seed, kind, link_id])
	if start.is_finite():
		check(start_tile_key == navigation_tile_key_for_position(start), "seed %d %s link %s start tile does not contain its endpoint" % [seed, kind, link_id])
	if end.is_finite():
		check(end_tile_key == navigation_tile_key_for_position(end), "seed %d %s link %s end tile does not contain its endpoint" % [seed, kind, link_id])
	check(owner_tile_key == start_tile_key, "seed %d %s link %s owner is not its start endpoint tile" % [seed, kind, link_id])
	check(tile_keys.has(start_tile_key), "seed %d %s link %s omits its start tile from coverage" % [seed, kind, link_id])
	check(tile_keys.has(end_tile_key), "seed %d %s link %s omits its end tile from coverage" % [seed, kind, link_id])


func navigation_tile_key_for_position(position: Vector3) -> String:
	var tile_cells := NpcConstantsScript.NAV_TILE_CELL_SIZE
	var cell_x := roundi(position.x / CELL)
	var cell_z := roundi(position.z / CELL)
	return "%d,%d" % [
		floori(float(cell_x) / float(tile_cells)),
		floori(float(cell_z) / float(tile_cells))
	]


func point_within_support_xz(position: Vector3, support: Dictionary) -> bool:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return false
	var inside := false
	var previous: Vector3 = polygon[polygon.size() - 1] if polygon[polygon.size() - 1] is Vector3 else Vector3.ZERO
	for point_value in polygon:
		if not (point_value is Vector3):
			return false
		var point: Vector3 = point_value
		var crosses := (point.z > position.z) != (previous.z > position.z)
		if crosses:
			var denominator := previous.z - point.z
			if absf(denominator) > 0.000001:
				var x_at_z := (previous.x - point.x) * (position.z - point.z) / denominator + point.x
				if position.x < x_at_z:
					inside = not inside
		previous = point
	return inside


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
