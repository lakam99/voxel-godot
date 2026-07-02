extends SceneTree

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35

var results: Array[Dictionary] = []
var main: Node3D
var structure_system
var seed := ""

func _init() -> void:
    call_deferred("run")

func run() -> void:
    seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
    if seed == "":
        seed = "atlas-1492"
    OS.set_environment("VOXEL_TEST_SEED", seed)
    main = MAIN_SCENE.instantiate()
    root.add_child(main)
    await wait_frames(90)
    structure_system = main.get("structure_system") if main != null else null
    test_scene_ready()
    test_cave_plan_determinism()
    test_cave_graph_varies_across_regions()
    test_cave_candidate_types()
    test_subsurface_material_queries()
    test_cave_update_around_generation()
    test_cave_build_interior_and_book_loot()
    test_subsurface_excavation_save_load()
    test_cave_save_load_persistence()
    save_report()
    quit(0 if all_passed() else 1)

func test_scene_ready() -> void:
    add_result("cave_scene_ready", main != null and structure_system != null, "main + structure_system present")

func test_cave_plan_determinism() -> void:
    if structure_system == null:
        add_result("cave_plan_determinism", false, "structure system missing")
        return
    var sample: Dictionary = structure_system.call("find_cave_plan_sample", "cliff", 10, false)
    if sample.is_empty():
        add_result("cave_plan_determinism", false, "no cliff cave plan")
        return
    var region: Vector2i = sample.get("region", Vector2i.ZERO)
    var kind := String(sample.get("kind", "cliff"))
    var plan_a: Dictionary = structure_system.call("cave_plan_for_region", region.x, region.y, kind, false)
    var plan_b: Dictionary = structure_system.call("cave_plan_for_region", region.x, region.y, kind, false)
    var signature_a := cave_plan_signature(plan_a)
    var signature_b := cave_plan_signature(plan_b)
    var stable := JSON.stringify(signature_a) == JSON.stringify(signature_b)
    add_result(
        "cave_plan_determinism",
        not plan_a.is_empty() and stable,
        "region=%s signatureA=%s signatureB=%s" % [JSON.stringify(vec2i(region)), JSON.stringify(signature_a), JSON.stringify(signature_b)]
    )

func test_cave_candidate_types() -> void:
    if structure_system == null:
        add_result("cave_candidate_types", false, "structure system missing")
        return
    var cliff: Dictionary = structure_system.call("find_cave_plan_sample", "cliff", 10, false)
    var underground: Dictionary = structure_system.call("find_cave_plan_sample", "underground", 18, false)
    var cliff_ok := not cliff.is_empty() and String(cliff.get("kind", "")) == "cliff" and float(cliff.get("entranceVariation", 0.0)) >= 1.0
    var underground_ok := not underground.is_empty() and String(underground.get("kind", "")) == "underground"
    add_result(
        "cave_candidate_types",
        cliff_ok and underground_ok,
        "cliff=%s underground=%s" % [JSON.stringify(sanitize_plan_summary(cliff)), JSON.stringify(sanitize_plan_summary(underground))]
    )

func test_subsurface_material_queries() -> void:
    var subsurface = main.get("subsurface_system") if main != null else null
    if subsurface == null:
        add_result("subsurface_material_queries", false, "subsurface system missing")
        return
    var cell := Vector2i(12, -18)
    var surface_y := float(main.call("terrain_height_cell", cell.x, cell.y))
    var surface_cell := Vector3i(cell.x, roundi((surface_y - CELL * 0.35) / CELL), cell.y)
    var above_cell := Vector3i(cell.x, roundi((surface_y + CELL * 4.0) / CELL), cell.y)
    var deep_cell := Vector3i(cell.x, roundi((surface_y - CELL * 12.0) / CELL), cell.y)
    var surface_material_a := String(subsurface.call("subsurface_material_at", surface_cell))
    var surface_material_b := String(subsurface.call("subsurface_material_at", surface_cell))
    var above_material := String(subsurface.call("subsurface_material_at", above_cell))
    var deep_material := String(subsurface.call("subsurface_material_at", deep_cell))
    var biome := String(subsurface.call("subsurface_biome_at", surface_cell))
    var passed := surface_material_a == surface_material_b \
        and surface_material_a != "" \
        and surface_material_a != "air" \
        and above_material == "air" \
        and (deep_material == "stone" or deep_material == "copperOre" or deep_material == "ironOre") \
        and biome != ""
    add_result(
        "subsurface_material_queries",
        passed,
        "surface=%s above=%s deep=%s biome=%s cell=%s" % [surface_material_a, above_material, deep_material, biome, JSON.stringify(sanitize(surface_cell))]
    )

func test_cave_graph_varies_across_regions() -> void:
    if structure_system == null:
        add_result("cave_graph_varies_across_regions", false, "structure system missing")
        return
    var signatures := {}
    var sampled := []
    var failures := []
    for rx in range(-8, 9):
        for rz in range(-8, 9):
            var plan: Dictionary = structure_system.call("cave_plan_for_region", rx, rz, "", false)
            if plan.is_empty():
                continue
            var summary := cave_graph_summary(plan)
            var node_count := int(summary.get("nodeCount", 0))
            var edge_count := int(summary.get("edgeCount", 0))
            var branch_count := int(summary.get("branchCount", 0))
            var dead_end_count := int(summary.get("deadEndCount", 0))
            var route_metrics := cave_graph_route_metrics(plan)
            if node_count < 6 or edge_count < 6 or branch_count < 1 or dead_end_count < 1 or not cave_route_metrics_passed(route_metrics):
                failures.append({
                    "region": { "x": rx, "z": rz },
                    "summary": summary,
                    "route": route_metrics
                })
            var signature := "%d:%d:%d:%d:%s" % [
                node_count,
                edge_count,
                branch_count,
                dead_end_count,
                JSON.stringify(summary.get("nodeRoles", []))
            ]
            signatures[signature] = true
            sampled.append({
                "region": { "x": rx, "z": rz },
                "id": String(plan.get("id", "")),
                "signature": signature,
                "summary": summary
            })
            if sampled.size() >= 10:
                break
        if sampled.size() >= 10:
            break
    var passed := sampled.size() >= 3 and signatures.size() >= 2 and failures.is_empty()
    add_result(
        "cave_graph_varies_across_regions",
        passed,
        "sampled=%d uniqueSignatures=%d failures=%s samples=%s" % [sampled.size(), signatures.size(), JSON.stringify(failures), JSON.stringify(sampled)]
    )

func test_cave_update_around_generation() -> void:
    if structure_system == null:
        add_result("cave_update_around_generation", false, "structure system missing")
        return
    cleanup_generated_blocks()
    var snapshot = main.call("snapshot_height_edits") if main.has_method("snapshot_height_edits") else []
    structure_system.call("reset")
    var natural_plan: Dictionary = structure_system.call("find_cave_plan_sample", "", 12, true)
    if natural_plan.is_empty():
        add_result("cave_update_around_generation", true, "seed has no natural cave spawn in focused search radius")
        restore_height_edits(snapshot)
        return
    structure_system.call("update_around", natural_plan.get("entranceCell", Vector2i.ZERO))
    var records: Dictionary = structure_system.call("cave_records_snapshot")
    var found := records.has(String(natural_plan.get("id", "")))
    add_result(
        "cave_update_around_generation",
        found,
        "natural=%s records=%s" % [String(natural_plan.get("id", "")), JSON.stringify(sanitize(records))]
    )
    cleanup_generated_blocks()
    restore_height_edits(snapshot)

func test_cave_build_interior_and_book_loot() -> void:
    if structure_system == null:
        add_result("cave_build_interior_and_book_loot", false, "structure system missing")
        return
    cleanup_generated_blocks()
    var snapshot = main.call("snapshot_height_edits") if main.has_method("snapshot_height_edits") else []
    structure_system.call("reset")
    var plan: Dictionary = structure_system.call("find_cave_plan_sample", "cliff", 10, false)
    if plan.is_empty():
        add_result("cave_build_interior_and_book_loot", false, "no cliff cave plan")
        restore_height_edits(snapshot)
        return
    var contiguous := bool(structure_system.call("cave_plan_is_contiguous", plan))
    var rng := RandomNumberGenerator.new()
    rng.seed = 51093
    structure_system.call("build_cave", plan, rng)
    var summary := cave_block_summary(plan)
    var graph_summary := cave_graph_summary(plan)
    var route_metrics := cave_graph_route_metrics(plan)
    var terrain_summary := cave_terrain_summary(plan)
    var mouth_access_summary := cave_mouth_access_summary(plan)
    var negative_y_summary := cave_negative_y_growth_summary(plan)
    var navigation_summary := cave_navigation_summary(plan)
    var world_volume_summary := cave_world_volume_summary(plan)
    var subsurface = main.get("subsurface_system") if main != null else null
    var patch_summary: Dictionary = subsurface.call("cave_patch_summary", String(plan.get("id", ""))) if subsurface != null and subsurface.has_method("cave_patch_summary") else {}
    var wall_integrity: Dictionary = subsurface.call("cave_wall_integrity_summary", plan) if subsurface != null and subsurface.has_method("cave_wall_integrity_summary") else {}
    var roof_integrity: Dictionary = subsurface.call("cave_roof_integrity_summary", plan) if subsurface != null and subsurface.has_method("cave_roof_integrity_summary") else {}
    var floor_level := float(plan.get("level", 0.0))
    var ceiling_level := float(plan.get("ceilingLevel", floor_level))
    var surface_level := float(plan.get("surfaceLevel", ceiling_level))
    var passed := contiguous \
        and int(graph_summary.get("nodeCount", 0)) >= 5 \
        and int(graph_summary.get("edgeCount", 0)) >= 5 \
        and int(graph_summary.get("branchCount", 0)) >= 1 \
        and int(graph_summary.get("deadEndCount", 0)) >= 1 \
        and int(graph_summary.get("narrowEdgeCount", 0)) >= 1 \
        and bool(graph_summary.get("finalChestInFinalChamber", false)) \
        and cave_route_metrics_passed(route_metrics) \
        and bool(patch_summary.get("hasNode", false)) \
        and bool(patch_summary.get("sharedCollision", false)) \
        and String(patch_summary.get("geometryAuthority", "")) == "subsurface_solid_air_volume" \
        and bool(wall_integrity.get("passed", false)) \
        and bool(roof_integrity.get("passed", false)) \
        and int(summary.get("interiorShells", 0)) == 1 \
        and int(summary.get("interiorMeshes", 0)) >= 1 \
        and int(summary.get("interiorCollisionBodies", 0)) >= 1 \
        and int(summary.get("interiorPlayerBlockingBodies", 0)) == int(summary.get("interiorCollisionBodies", -1)) \
        and int(summary.get("supportFrames", 0)) >= 1 \
        and int(summary.get("supportFrames", 0)) <= 2 \
        and int(summary.get("interiorCaveLayerVisuals", 0)) >= 1 \
        and int(summary.get("interiorNonCaveLayerVisuals", 0)) == 0 \
        and float(summary.get("floorHeightRange", 0.0)) >= 0.35 \
        and float(summary.get("maxFloorNeighborStep", 999.0)) <= CELL * 1.10 \
        and int(summary.get("torches", 0)) >= 2 \
        and int(summary.get("torches", 0)) <= 6 \
        and int(summary.get("smallTorches", 0)) == int(summary.get("torches", 0)) \
        and int(summary.get("wallMountedTorches", 0)) == int(summary.get("torches", 0)) \
        and int(summary.get("validWallTorchNormals", 0)) == int(summary.get("torches", 0)) \
        and int(summary.get("surfaceAlignedWallTorches", 0)) == int(summary.get("torches", 0)) \
        and float(summary.get("minWallTorchBaseHeight", 0.0)) >= CELL * 0.90 \
        and float(summary.get("maxWallTorchSurfaceError", 999.0)) <= CELL * 0.04 \
        and float(summary.get("minWallTorchVisibleBackInset", 0.0)) >= CELL * 0.035 \
        and int(summary.get("caveBlockNonCaveLayerVisuals", 0)) == 0 \
        and int(summary.get("pathBlocks", 0)) == 0 \
        and int(summary.get("wallBlocks", 0)) == 0 \
        and int(summary.get("finalChests", 0)) == 1 \
        and bool(summary.get("finalChestHasCraftingBook", false)) \
        and int(terrain_summary.get("openingCells", 0)) > 0 \
        and int(terrain_summary.get("editedOpeningCells", 0)) == 0 \
        and int(terrain_summary.get("editedInteriorWalkableCells", 999)) == 0 \
        and int(terrain_summary.get("editedPortalCells", 0)) == 0 \
        and int(terrain_summary.get("hiddenPortalCells", 0)) > 0 \
        and int(terrain_summary.get("hiddenPortalCells", 0)) <= int(terrain_summary.get("portalCells", 999)) \
        and float(terrain_summary.get("openingToWalkableRatio", 1.0)) <= 0.45 \
        and int(terrain_summary.get("stoneOverridePortalCells", 0)) == 0 \
        and int(terrain_summary.get("propExclusionCells", 0)) > int(terrain_summary.get("hiddenPortalCells", 0)) \
        and cave_mouth_access_passed(mouth_access_summary) \
        and bool(world_volume_summary.get("passed", false)) \
        and bool(navigation_summary.get("recordFound", false)) \
        and int(navigation_summary.get("recordWalkableCells", 0)) == int(terrain_summary.get("walkableCells", 0)) \
        and int(navigation_summary.get("lookupMatchedSampleCells", 0)) >= 3 \
        and int(navigation_summary.get("navmeshCaveTaggedSampleCells", 0)) >= 3 \
        and surface_level > ceiling_level \
        and ceiling_level > floor_level
    add_result(
        "cave_build_interior_and_book_loot",
        passed,
        "contiguous=%s graph=%s route=%s summary=%s patch=%s wall=%s roof=%s terrain=%s mouth=%s volume=%s negativeY=%s navigation=%s plan=%s" % [str(contiguous), JSON.stringify(graph_summary), JSON.stringify(route_metrics), JSON.stringify(summary), JSON.stringify(patch_summary), JSON.stringify(wall_integrity), JSON.stringify(roof_integrity), JSON.stringify(terrain_summary), JSON.stringify(mouth_access_summary), JSON.stringify(world_volume_summary), JSON.stringify(negative_y_summary), JSON.stringify(navigation_summary), JSON.stringify(sanitize_plan_summary(plan))]
    )
    cleanup_generated_blocks()
    restore_height_edits(snapshot)

func test_subsurface_excavation_save_load() -> void:
    var subsurface = main.get("subsurface_system") if main != null else null
    if subsurface == null:
        add_result("subsurface_excavation_save_load", false, "subsurface system missing")
        return
    if subsurface.has_method("reset"):
        subsurface.call("reset")
    var surface_y := float(main.call("terrain_height_cell", 20, 20))
    var center := Vector3(20.0 * CELL, surface_y - CELL * 0.65, 20.0 * CELL)
    var brush: Dictionary = subsurface.call("add_excavation_brush", center, CELL * 1.35, "")
    var center_cell := Vector3i(20, roundi(center.y / CELL), 20)
    var air_after_brush := not bool(subsurface.call("subsurface_is_solid", center_cell))
    var snapshot: Dictionary = subsurface.call("snapshot")
    subsurface.call("reset")
    var solid_after_reset := bool(subsurface.call("subsurface_is_solid", center_cell))
    subsurface.call("restore", snapshot)
    var air_after_restore := not bool(subsurface.call("subsurface_is_solid", center_cell))
    var saved_count := array_size(snapshot.get("excavationBrushes", []))
    add_result(
        "subsurface_excavation_save_load",
        air_after_brush and solid_after_reset and air_after_restore and saved_count == 1 and String(brush.get("id", "")) != "",
        "brush=%s savedCount=%d airAfterBrush=%s solidAfterReset=%s airAfterRestore=%s" % [JSON.stringify(sanitize(brush)), saved_count, str(air_after_brush), str(solid_after_reset), str(air_after_restore)]
    )

func test_cave_save_load_persistence() -> void:
    if structure_system == null or main == null or not main.has_method("create_save_snapshot"):
        add_result("cave_save_load_persistence", false, "missing save-capable main or structure system")
        return
    cleanup_generated_blocks()
    var snapshot = main.call("snapshot_height_edits") if main.has_method("snapshot_height_edits") else []
    structure_system.call("reset")
    var plan: Dictionary = structure_system.call("find_cave_plan_sample", "cliff", 10, false)
    if plan.is_empty():
        add_result("cave_save_load_persistence", false, "no cliff cave plan")
        restore_height_edits(snapshot)
        return
    var rng := RandomNumberGenerator.new()
    rng.seed = 72177
    structure_system.call("build_cave", plan, rng)
    var cave_id := String(plan.get("id", ""))
    var chest := cave_final_chest_node(plan)
    if chest == null:
        add_result("cave_save_load_persistence", false, "final cave chest missing before save")
        cleanup_generated_blocks()
        restore_height_edits(snapshot)
        return
    chest.set_meta("storage_slots", cave_test_slots())
    var save_snapshot: Dictionary = main.call("create_save_snapshot")
    var cave_entries: Array = save_snapshot.get("caves", []) if save_snapshot.get("caves", []) is Array else []
    var snapshot_has_mutated_chest := cave_snapshot_has_slot(cave_entries, cave_id, "stones", 7)
    cleanup_generated_blocks()
    structure_system.call("restore_caves", save_snapshot.get("caves", []))
    var restored_records: Dictionary = structure_system.call("cave_records_snapshot") if structure_system.has_method("cave_records_snapshot") else {}
    var restored_navigation: Dictionary = structure_system.call("cave_navigation_records_snapshot") if structure_system.has_method("cave_navigation_records_snapshot") else {}
    var restored_chest := cave_final_chest_node(plan)
    var restored_summary := cave_block_summary(plan)
    var restored_terrain := cave_terrain_summary(plan)
    var restored_mouth_access := cave_mouth_access_summary(plan)
    var restored_negative_y := cave_negative_y_growth_summary(plan)
    var restored_navigation_summary := cave_navigation_summary(plan)
    var restored_world_volume := cave_world_volume_summary(plan)
    var restored_slot_ok := cave_chest_has_slot(restored_chest, "stones", 7)
    var generated_regions_value = structure_system.get("generated_caves")
    var generated_regions: Dictionary = generated_regions_value if generated_regions_value is Dictionary else {}
    var restored_region_marked := generated_regions.has(plan.get("region", Vector2i.ZERO))
    var passed := snapshot_has_mutated_chest \
        and restored_records.has(cave_id) \
        and restored_navigation.has(cave_id) \
        and restored_region_marked \
        and restored_chest != null \
        and restored_slot_ok \
        and int(restored_summary.get("interiorShells", 0)) == 1 \
        and int(restored_summary.get("interiorCollisionBodies", 0)) >= 1 \
        and int(restored_summary.get("interiorPlayerBlockingBodies", 0)) == int(restored_summary.get("interiorCollisionBodies", -1)) \
        and int(restored_summary.get("supportFrames", 0)) >= 1 \
        and int(restored_summary.get("supportFrames", 0)) <= 2 \
        and int(restored_summary.get("interiorNonCaveLayerVisuals", 0)) == 0 \
        and float(restored_summary.get("floorHeightRange", 0.0)) >= 0.35 \
        and float(restored_summary.get("maxFloorNeighborStep", 999.0)) <= CELL * 1.10 \
        and int(restored_summary.get("smallTorches", 0)) == int(restored_summary.get("torches", 0)) \
        and int(restored_summary.get("wallMountedTorches", 0)) == int(restored_summary.get("torches", 0)) \
        and int(restored_summary.get("validWallTorchNormals", 0)) == int(restored_summary.get("torches", 0)) \
        and int(restored_summary.get("surfaceAlignedWallTorches", 0)) == int(restored_summary.get("torches", 0)) \
        and float(restored_summary.get("minWallTorchBaseHeight", 0.0)) >= CELL * 0.90 \
        and float(restored_summary.get("maxWallTorchSurfaceError", 999.0)) <= CELL * 0.04 \
        and float(restored_summary.get("minWallTorchVisibleBackInset", 0.0)) >= CELL * 0.035 \
        and int(restored_summary.get("caveBlockNonCaveLayerVisuals", 0)) == 0 \
        and int(restored_summary.get("finalChests", 0)) == 1 \
        and int(restored_terrain.get("editedInteriorWalkableCells", 999)) == 0 \
        and int(restored_terrain.get("editedPortalCells", 0)) == 0 \
        and int(restored_terrain.get("hiddenPortalCells", 0)) > 0 \
        and int(restored_terrain.get("hiddenPortalCells", 0)) <= int(restored_terrain.get("portalCells", 999)) \
        and float(restored_terrain.get("openingToWalkableRatio", 1.0)) <= 0.45 \
        and int(restored_terrain.get("stoneOverridePortalCells", 0)) == 0 \
        and int(restored_terrain.get("propExclusionCells", 0)) > int(restored_terrain.get("hiddenPortalCells", 0)) \
        and cave_mouth_access_passed(restored_mouth_access) \
        and bool(restored_world_volume.get("passed", false)) \
        and bool(restored_navigation_summary.get("recordFound", false)) \
        and int(restored_navigation_summary.get("lookupMatchedSampleCells", 0)) >= 3 \
        and int(restored_navigation_summary.get("navmeshCaveTaggedSampleCells", 0)) >= 3
    add_result(
        "cave_save_load_persistence",
        passed,
        "snapshotHasMutatedChest=%s restoredSlot=%s restoredRegionMarked=%s records=%s navigation=%s summary=%s terrain=%s mouth=%s volume=%s negativeY=%s navigationSummary=%s caveEntries=%s plan=%s" % [
            str(snapshot_has_mutated_chest),
            str(restored_slot_ok),
            str(restored_region_marked),
            JSON.stringify(restored_records.keys()),
            JSON.stringify(restored_navigation.keys()),
            JSON.stringify(restored_summary),
            JSON.stringify(restored_terrain),
            JSON.stringify(restored_mouth_access),
            JSON.stringify(restored_world_volume),
            JSON.stringify(restored_negative_y),
            JSON.stringify(restored_navigation_summary),
            JSON.stringify(sanitize(cave_entries)),
            JSON.stringify(sanitize_plan_summary(plan))
        ]
    )
    cleanup_generated_blocks()
    restore_height_edits(snapshot)

func cave_graph_summary(plan: Dictionary) -> Dictionary:
    var nodes: Array = plan.get("caveNodes", [])
    var edges: Array = plan.get("caveEdges", [])
    var final_id := String(plan.get("finalChamberId", ""))
    var final_cell: Vector2i = plan.get("finalChamberCell", Vector2i.ZERO)
    var final_radius := 0
    var node_roles := []
    var min_edge_radius := INF
    var narrow_edge_count := 0
    for node_value in nodes:
        if not (node_value is Dictionary):
            continue
        var node: Dictionary = node_value
        node_roles.append(String(node.get("kind", "")))
        if String(node.get("id", "")) == final_id:
            final_radius = int(node.get("radius", 0))
    for edge_value in edges:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var radius := float(edge.get("radius", 0.0))
        min_edge_radius = minf(min_edge_radius, radius)
        if radius <= 1.75:
            narrow_edge_count += 1
    var chest_cell: Vector2i = plan.get("finalChestCell", Vector2i.ZERO)
    var chest_distance := Vector2(float(chest_cell.x - final_cell.x), float(chest_cell.y - final_cell.y)).length()
    return {
        "nodeCount": nodes.size(),
        "edgeCount": edges.size(),
        "branchCount": cave_array_size(plan, "branchChamberIds"),
        "deadEndCount": cave_array_size(plan, "deadEndChamberIds"),
        "caveTier": String(plan.get("caveTier", "normal")),
        "nodeRoles": node_roles,
        "minEdgeRadius": snappedf(0.0 if min_edge_radius == INF else min_edge_radius, 0.001),
        "narrowEdgeCount": narrow_edge_count,
        "finalChestInFinalChamber": chest_distance <= float(final_radius + 1)
    }

func cave_graph_route_metrics(plan: Dictionary) -> Dictionary:
    var edges: Array = plan.get("caveEdges", [])
    var graph := {}
    for edge_value in edges:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var from_id := String(edge.get("from", ""))
        var to_id := String(edge.get("to", ""))
        if from_id == "" or to_id == "":
            continue
        var center_cells = edge.get("centerCells", [])
        var cost := maxi(1, center_cells.size() if center_cells is Array else 1)
        if not graph.has(from_id):
            graph[from_id] = []
        if not graph.has(to_id):
            graph[to_id] = []
        var from_edges: Array = graph[from_id]
        var to_edges: Array = graph[to_id]
        from_edges.append({ "to": to_id, "cost": cost })
        to_edges.append({ "to": from_id, "cost": cost })
        graph[from_id] = from_edges
        graph[to_id] = to_edges
    var final_id := String(plan.get("finalChamberId", "final"))
    var distances := { "entrance": 0.0 }
    var visited := {}
    while true:
        var current := ""
        var best_distance := INF
        for key in distances.keys():
            var node_id := String(key)
            if visited.has(node_id):
                continue
            var distance := float(distances.get(node_id, INF))
            if distance < best_distance:
                best_distance = distance
                current = node_id
        if current == "" or current == final_id:
            break
        visited[current] = true
        var links: Array = graph.get(current, [])
        for link_value in links:
            if not (link_value is Dictionary):
                continue
            var link: Dictionary = link_value
            var next_id := String(link.get("to", ""))
            var next_distance := best_distance + float(link.get("cost", 1))
            if next_distance < float(distances.get(next_id, INF)):
                distances[next_id] = next_distance
    var route_cost := float(distances.get(final_id, INF))
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var final_cell: Vector2i = plan.get("finalChestCell", plan.get("finalChamberCell", entrance))
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var delta := final_cell - entrance
    var straight_distance := Vector2(float(delta.x), float(delta.y)).length()
    var final_depth := delta.x * inward.x + delta.y * inward.y
    var minimum_route_cells := int(plan.get("minimumRouteCells", 72))
    var minimum_final_depth := maxi(42, int(plan.get("pathLength", 0)))
    return {
        "caveTier": String(plan.get("caveTier", "normal")),
        "shortestRouteCells": int(round(route_cost)) if route_cost < INF else 0,
        "minimumRouteCells": minimum_route_cells,
        "straightDistanceCells": snappedf(straight_distance, 0.001),
        "routeDirectness": snappedf(route_cost / maxf(1.0, straight_distance), 0.001) if route_cost < INF else 0.0,
        "finalDepthCells": final_depth,
        "minimumFinalDepthCells": minimum_final_depth,
        "pathLength": int(plan.get("pathLength", 0))
    }

func cave_route_metrics_passed(metrics: Dictionary) -> bool:
    return int(metrics.get("shortestRouteCells", 0)) >= int(metrics.get("minimumRouteCells", 0)) \
        and float(metrics.get("routeDirectness", 0.0)) >= 1.12 \
        and int(metrics.get("finalDepthCells", 0)) >= int(metrics.get("minimumFinalDepthCells", 0))

func cave_plan_signature(plan: Dictionary) -> Dictionary:
    if plan.is_empty():
        return {}
    var node_signature := []
    for node_value in plan.get("caveNodes", []):
        if not (node_value is Dictionary):
            continue
        var node: Dictionary = node_value
        node_signature.append({
            "id": String(node.get("id", "")),
            "kind": String(node.get("kind", "")),
            "cell": vec2i(node.get("cell", Vector2i.ZERO)),
            "radius": int(node.get("radius", 0))
        })
    var edge_signature := []
    for edge_value in plan.get("caveEdges", []):
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        edge_signature.append({
            "id": String(edge.get("id", "")),
            "from": String(edge.get("from", "")),
            "to": String(edge.get("to", "")),
            "centerHash": cave_cell_array_hash(edge.get("centerCells", []))
        })
    return {
        "summary": sanitize_plan_summary(plan),
        "nodes": node_signature,
        "edges": edge_signature,
        "pathHash": cave_cell_array_hash(plan.get("pathCells", [])),
        "chamberHash": cave_cell_array_hash(plan.get("chamberCells", []))
    }

func cave_cell_array_hash(values) -> int:
    var hash := 17
    if not (values is Array):
        return hash
    for value in values:
        if not (value is Vector2i):
            continue
        var cell: Vector2i = value
        hash = int((hash * 31 + cell.x * 92821 + cell.y * 68917) & 0x7fffffff)
    return hash

func cave_block_summary(plan: Dictionary) -> Dictionary:
    var blocks_value = main.get("blocks") if main != null else {}
    var blocks: Dictionary = blocks_value if blocks_value is Dictionary else {}
    var path_blocks := 0
    var wall_blocks := 0
    var torches := 0
    var small_torches := 0
    var wall_mounted_torches := 0
    var valid_wall_torch_normals := 0
    var min_wall_torch_base_height := INF
    var surface_aligned_wall_torches := 0
    var max_wall_torch_surface_error := 0.0
    var min_wall_torch_visible_back_inset := INF
    var final_chests := 0
    var final_chest_has_book := false
    var cave_block_layer_summary := { "visuals": 0, "nonCaveLayerVisuals": 0 }
    for block_value in blocks.values():
        var block := block_value as Node
        if block == null or String(block.get_meta("generatedTier", "")) != "cave":
            continue
        add_cave_layer_summary(cave_block_layer_summary, block)
        var block_type := String(block.get_meta("block_type", ""))
        var role := String(block.get_meta("caveRole", ""))
        if block_type == "cobblestonePath":
            path_blocks += 1
        if role == "wall" or role == "entrance_arch" or role == "ore_vein":
            wall_blocks += 1
        if block_type == "torch":
            torches += 1
            if float(block.get_meta("torchVisualScale", 1.0)) <= 0.36:
                small_torches += 1
            if bool(block.get_meta("torchWallMount", false)):
                wall_mounted_torches += 1
                var torch_floor_level := float(block.get_meta("structureLevel", plan.get("level", 0.0)))
                min_wall_torch_base_height = minf(min_wall_torch_base_height, float(block.global_position.y) - torch_floor_level)
                min_wall_torch_visible_back_inset = minf(min_wall_torch_visible_back_inset, wall_torch_visible_back_inset(block))
                if block.has_meta("torchWallSurfaceX") and block.has_meta("torchWallSurfaceZ"):
                    var block3d := block as Node3D
                    if block3d == null:
                        continue
                    var surface := Vector2(float(block.get_meta("torchWallSurfaceX")), float(block.get_meta("torchWallSurfaceZ")))
                    var actual := Vector2(float(block3d.global_position.x), float(block3d.global_position.z))
                    var surface_error := actual.distance_to(surface)
                    max_wall_torch_surface_error = maxf(max_wall_torch_surface_error, surface_error)
                    if surface_error <= CELL * 0.04:
                        surface_aligned_wall_torches += 1
            var wall_normal := Vector2i(int(block.get_meta("torchWallNormalX", 0)), int(block.get_meta("torchWallNormalZ", 0)))
            if abs(wall_normal.x) + abs(wall_normal.y) == 1:
                valid_wall_torch_normals += 1
        if block_type == "chest" and role == "final_chest":
            final_chests += 1
            final_chest_has_book = final_chest_has_book or chest_has_crafting_book(block)
    var edits_value = main.get("height_edits") if main != null else {}
    var edits: Dictionary = edits_value if edits_value is Dictionary else {}
    var interior := cave_interior_summary(plan)
    return {
        "pathBlocks": path_blocks,
        "wallBlocks": wall_blocks,
        "torches": torches,
        "smallTorches": small_torches,
        "wallMountedTorches": wall_mounted_torches,
        "validWallTorchNormals": valid_wall_torch_normals,
        "minWallTorchBaseHeight": snappedf(0.0 if min_wall_torch_base_height == INF else min_wall_torch_base_height, 0.001),
        "surfaceAlignedWallTorches": surface_aligned_wall_torches,
        "maxWallTorchSurfaceError": snappedf(max_wall_torch_surface_error, 0.001),
        "minWallTorchVisibleBackInset": snappedf(0.0 if min_wall_torch_visible_back_inset == INF else min_wall_torch_visible_back_inset, 0.001),
        "finalChests": final_chests,
        "finalChestHasCraftingBook": final_chest_has_book,
        "heightEditCells": edits.size(),
        "finalChestCell": vec2i(plan.get("finalChestCell", Vector2i.ZERO)),
        "interiorShells": int(interior.get("shells", 0)),
        "interiorMeshes": int(interior.get("meshes", 0)),
        "interiorCollisionBodies": int(interior.get("collisionBodies", 0)),
        "interiorPlayerBlockingBodies": int(interior.get("playerBlockingBodies", 0)),
        "supportFrames": int(interior.get("supportFrames", 0)),
        "interiorCaveLayerVisuals": int(interior.get("caveLayerVisuals", 0)),
        "interiorNonCaveLayerVisuals": int(interior.get("nonCaveLayerVisuals", 0)),
        "floorHeightRange": float(interior.get("floorHeightRange", 0.0)),
        "maxFloorNeighborStep": float(interior.get("maxFloorNeighborStep", 0.0)),
        "caveBlockVisuals": int(cave_block_layer_summary.get("visuals", 0)),
        "caveBlockNonCaveLayerVisuals": int(cave_block_layer_summary.get("nonCaveLayerVisuals", 0))
    }

func cave_terrain_summary(plan: Dictionary) -> Dictionary:
    var edits_value = main.get("height_edits") if main != null else {}
    var edits: Dictionary = edits_value if edits_value is Dictionary else {}
    var walkable_cells: Array = structure_system.call("cave_walkable_cells", plan, false)
    var opening_cells: Array = structure_system.call("cave_terrain_opening_cells", plan)
    var portal_cells: Array = structure_system.call("cave_mouth_portal_cells", plan) if structure_system.has_method("cave_mouth_portal_cells") else []
    var shaping_cells: Array = structure_system.call("cave_shaping_cells", plan)
    var opening_lookup := {}
    for cell_value in opening_cells:
        if cell_value is Vector2i:
            opening_lookup[cell_value] = true
    var portal_lookup := {}
    for cell_value in portal_cells:
        if cell_value is Vector2i:
            portal_lookup[cell_value] = true
    var edited_opening_cells := 0
    for cell_value in opening_cells:
        var cell: Vector2i = cell_value
        if edits.has(cell):
            edited_opening_cells += 1
    var edited_portal_cells := 0
    for cell_value in portal_cells:
        var cell: Vector2i = cell_value
        if edits.has(cell):
            edited_portal_cells += 1
    var edited_walkable_cells := 0
    var edited_interior_walkable_cells := 0
    for cell_value in walkable_cells:
        var cell: Vector2i = cell_value
        if not edits.has(cell):
            continue
        edited_walkable_cells += 1
        if not opening_lookup.has(cell) and not portal_lookup.has(cell):
            edited_interior_walkable_cells += 1
    var stone_override_cells := 0
    var stone_override_portal_cells := 0
    var stone_override_shaping_cells := 0
    var hidden_portal_cells := 0
    for cell_value in opening_cells:
        var cell: Vector2i = cell_value
        if String(structure_system.call("terrain_material_override_for_cell", cell.x, cell.y)) == "stone":
            stone_override_cells += 1
    for cell_value in portal_cells:
        var cell: Vector2i = cell_value
        if String(structure_system.call("terrain_material_override_for_cell", cell.x, cell.y)) == "stone":
            stone_override_portal_cells += 1
        if world_generation_hidden_for_cell(cell):
            hidden_portal_cells += 1
    var prop_exclusion_cells := 0
    for cell_value in shaping_cells:
        var cell: Vector2i = cell_value
        if String(structure_system.call("terrain_material_override_for_cell", cell.x, cell.y)) == "stone":
            stone_override_shaping_cells += 1
        if structure_system.has_method("blocks_natural_prop_at_cell") and bool(structure_system.call("blocks_natural_prop_at_cell", cell.x, cell.y)):
            prop_exclusion_cells += 1
    var walkable_count := maxi(1, walkable_cells.size())
    return {
        "walkableCells": walkable_cells.size(),
        "openingCells": opening_cells.size(),
        "portalCells": portal_cells.size(),
        "shapingCells": shaping_cells.size(),
        "editedOpeningCells": edited_opening_cells,
        "editedPortalCells": edited_portal_cells,
        "editedWalkableCells": edited_walkable_cells,
        "editedInteriorWalkableCells": edited_interior_walkable_cells,
        "openingToWalkableRatio": snappedf(float(opening_cells.size()) / float(walkable_count), 0.001),
        "portalToWalkableRatio": snappedf(float(portal_cells.size()) / float(walkable_count), 0.001),
        "hiddenPortalCells": hidden_portal_cells,
        "stoneOverrideCells": stone_override_cells,
        "stoneOverridePortalCells": stone_override_portal_cells,
        "stoneOverrideShapingCells": stone_override_shaping_cells,
        "propExclusionCells": prop_exclusion_cells
    }

func world_generation_hidden_for_cell(cell: Vector2i) -> bool:
    var world_generation = main.get("world_generation_system") if main != null else null
    if world_generation != null and world_generation.has_method("surface_quad_hidden_for_cell3"):
        return bool(world_generation.call("surface_quad_hidden_for_cell3", Vector3i(cell.x, 0, cell.y)))
    if main != null and main.has_method("terrain_quad_hidden_for_cell"):
        return bool(main.call("terrain_quad_hidden_for_cell", cell.x, cell.y))
    if structure_system != null and structure_system.has_method("terrain_quad_hidden_for_cell"):
        return bool(structure_system.call("terrain_quad_hidden_for_cell", cell.x, cell.y))
    return false

func cave_ground_height_for_cell(plan: Dictionary, cell: Vector2i, current_y: float) -> float:
    var point := cave_cell_world2(cell)
    if main != null and main.has_method("ground_height_at_world"):
        var ground_value = main.call("ground_height_at_world", point.x, point.y, current_y)
        if ground_value is float or ground_value is int:
            var ground_y := float(ground_value)
            if not is_nan(ground_y):
                return ground_y
    if main != null and main.has_method("terrain_height_cell"):
        return float(main.call("terrain_height_cell", cell.x, cell.y))
    return current_y

func cave_mouth_access_summary(plan: Dictionary) -> Dictionary:
    if main == null or structure_system == null:
        return { "reason": "missing main or structure system" }
    var builder = structure_system.get("cave_interior_builder")
    if builder == null or not builder.has_method("floor_point") or not builder.has_method("ceiling_point"):
        return { "reason": "missing cave interior builder samplers" }
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var approach_depth := int(plan.get("entranceApproachDepth", 7))
    var interior_depth := int(plan.get("entranceOpenDepth", 7))
    var portal_cells: Array = structure_system.call("cave_mouth_portal_cells", plan) if structure_system.has_method("cave_mouth_portal_cells") else []
    var hidden_portal_cells := 0
    for cell_value in portal_cells:
        if not (cell_value is Vector2i):
            continue
        var portal_cell: Vector2i = cell_value
        if world_generation_hidden_for_cell(portal_cell):
            hidden_portal_cells += 1
    var outside_min := INF
    var outside_max := -INF
    for depth in range(-approach_depth, 1):
        for lateral in range(-1, 2):
            var outside_cell: Vector2i = entrance + inward * int(depth) + right * int(lateral)
            var outside_point := cave_cell_world2(outside_cell)
            var outside_current_y := float(main.call("terrain_height_cell", outside_cell.x, outside_cell.y))
            var outside_floor_value = builder.call("floor_point", plan, outside_point)
            if outside_floor_value is Vector3:
                outside_current_y = float((outside_floor_value as Vector3).y) + CELL
            var h := cave_ground_height_for_cell(plan, outside_cell, outside_current_y)
            outside_min = minf(outside_min, h)
            outside_max = maxf(outside_max, h)
    var max_center_step := 0.0
    var previous_y := INF
    var min_clearance := INF
    var min_cover_after_portal := INF
    var covered_samples := 0
    var front_open_columns := 0
    var jagged_mouth_rows := 0
    var blocked_center_samples := 0
    var exterior_shell_samples := 0
    var mouth_rows_checked := 0
    var arch_center_clearance := 0.0
    var arch_side_clearance := 0.0
    var front_floor_gap := 0.0
    var mouth_width := float(plan.get("entranceMouthHalfWidth", 0.0))
    var front_depth_cells := cave_mouth_front_depth_cells(plan, approach_depth)
    var mouth_envelope := cave_plan_mouth_envelope(plan)
    if builder.has_method("rendered_shell_inside_at_point"):
        var lateral_limit := ceili(mouth_width + 0.5)
        for exterior_depth in range(-approach_depth, 0):
            for lateral in range(-lateral_limit, lateral_limit + 1):
                var exterior_cell: Vector2i = entrance + inward * int(exterior_depth) + right * int(lateral)
                var exterior_point := cave_cell_world2(exterior_cell)
                if bool(builder.call("rendered_shell_inside_at_point", plan, exterior_point)):
                    exterior_shell_samples += 1
        var row_depth_limit := mini(4, interior_depth)
        for row_depth in range(0, row_depth_limit + 1):
            var open_laterals: Array[int] = []
            for lateral in range(-lateral_limit, lateral_limit + 1):
                var sample_cell: Vector2i = entrance + inward * int(row_depth) + right * int(lateral)
                var sample_point := cave_cell_world2(sample_cell)
                if bool(builder.call("rendered_shell_inside_at_point", plan, sample_point)):
                    open_laterals.append(lateral)
            if open_laterals.is_empty():
                jagged_mouth_rows += 1
                continue
            mouth_rows_checked += 1
            var min_lateral := open_laterals[0]
            var max_lateral := open_laterals[0]
            var open_lookup := {}
            for lateral_value in open_laterals:
                min_lateral = mini(min_lateral, lateral_value)
                max_lateral = maxi(max_lateral, lateral_value)
                open_lookup[lateral_value] = true
            if row_depth == 0:
                front_open_columns = open_laterals.size()
            if min_lateral > 0 or max_lateral < 0:
                jagged_mouth_rows += 1
            else:
                for lateral in range(min_lateral, max_lateral + 1):
                    if not open_lookup.has(lateral):
                        jagged_mouth_rows += 1
                        break
            var center_point := cave_cell_world2(entrance + inward * int(row_depth))
            if not bool(builder.call("rendered_shell_inside_at_point", plan, center_point)):
                blocked_center_samples += 1
        var center_floor_value = builder.call("floor_point", plan, cave_cell_world2(entrance))
        var center_ceiling_value = builder.call("ceiling_point", plan, cave_cell_world2(entrance))
        if center_floor_value is Vector3 and center_ceiling_value is Vector3:
            arch_center_clearance = float((center_ceiling_value as Vector3).y - (center_floor_value as Vector3).y)
            var center_floor_y := float((center_floor_value as Vector3).y)
            front_floor_gap = absf(cave_ground_height_for_cell(plan, entrance, center_floor_y + CELL) - center_floor_y)
        var side_lateral := maxi(1, roundi(mouth_width * 0.82))
        var side_cell := entrance + right * side_lateral
        var side_floor_value = builder.call("floor_point", plan, cave_cell_world2(side_cell))
        var side_ceiling_value = builder.call("ceiling_point", plan, cave_cell_world2(side_cell))
        if side_floor_value is Vector3 and side_ceiling_value is Vector3:
            arch_side_clearance = float((side_ceiling_value as Vector3).y - (side_floor_value as Vector3).y)
    for depth in range(-mini(3, approach_depth), interior_depth + 5):
        var cell: Vector2i = entrance + inward * int(depth)
        var point := cave_cell_world2(cell)
        var floor_value = builder.call("floor_point", plan, point)
        var ceiling_value = builder.call("ceiling_point", plan, point)
        var floor_y := float((floor_value as Vector3).y) if floor_value is Vector3 else float(plan.get("level", 0.0))
        var ceiling_y := float((ceiling_value as Vector3).y) if ceiling_value is Vector3 else float(plan.get("ceilingLevel", floor_y + CELL * 3.0))
        var ground_y := cave_ground_height_for_cell(plan, cell, floor_y + CELL) if depth < 0 else floor_y
        if previous_y != INF:
            max_center_step = maxf(max_center_step, absf(ground_y - previous_y))
        previous_y = ground_y
        if depth >= 0:
            min_clearance = minf(min_clearance, ceiling_y - floor_y)
        if depth > interior_depth:
            covered_samples += 1
            min_cover_after_portal = minf(min_cover_after_portal, effective_cave_surface_height_cell(plan, cell) - ceiling_y)
    return {
        "portalCells": portal_cells.size(),
        "hiddenPortalCells": hidden_portal_cells,
        "outsideHeightRange": snappedf(0.0 if outside_min == INF else outside_max - outside_min, 0.001),
        "maxCenterRouteStep": snappedf(max_center_step, 0.001),
        "minPlayerClearance": snappedf(0.0 if min_clearance == INF else min_clearance, 0.001),
        "minCoverAfterPortal": snappedf(0.0 if min_cover_after_portal == INF else min_cover_after_portal, 0.001),
        "coveredSamplesAfterPortal": covered_samples,
        "mouthHalfWidth": snappedf(mouth_width, 0.001),
        "mouthArchHeight": snappedf(float(plan.get("entranceMouthArchHeight", 0.0)), 0.001),
        "mouthEnvelope": sanitize(mouth_envelope),
        "mouthFitsMoundEnvelope": cave_mouth_envelope_passed(mouth_envelope, mouth_width),
        "minimumFrontOpenColumns": cave_min_front_open_columns(mouth_width),
        "frontDepthCells": front_depth_cells,
        "mouthFloorLevel": snappedf(float(plan.get("mouthFloorLevel", plan.get("level", 0.0))), 0.001),
        "frontOpenColumns": front_open_columns,
        "mouthRowsChecked": mouth_rows_checked,
        "jaggedMouthRows": jagged_mouth_rows,
        "blockedCenterSamples": blocked_center_samples,
        "exteriorShellSamples": exterior_shell_samples,
        "frontArchCenterClearance": snappedf(arch_center_clearance, 0.001),
        "frontArchSideClearance": snappedf(arch_side_clearance, 0.001),
        "frontArchRise": snappedf(arch_center_clearance - arch_side_clearance, 0.001),
        "frontFloorGap": snappedf(front_floor_gap, 0.001),
        "entranceCell": vec2i(entrance)
    }

func cave_mouth_access_passed(summary: Dictionary) -> bool:
    return int(summary.get("portalCells", 0)) > 0 \
        and int(summary.get("hiddenPortalCells", 0)) > 0 \
        and int(summary.get("hiddenPortalCells", 0)) <= int(summary.get("portalCells", 999)) \
        and bool(summary.get("mouthFitsMoundEnvelope", false)) \
        and float(summary.get("outsideHeightRange", 999.0)) <= CELL * 1.25 \
        and float(summary.get("maxCenterRouteStep", 999.0)) <= CELL * 0.85 \
        and float(summary.get("minPlayerClearance", 0.0)) >= CELL * 2.05 \
        and int(summary.get("coveredSamplesAfterPortal", 0)) > 0 \
        and float(summary.get("minCoverAfterPortal", -999.0)) >= CELL * 0.35 \
        and float(summary.get("mouthHalfWidth", 0.0)) >= 1.75 \
        and int(summary.get("frontOpenColumns", 0)) >= int(summary.get("minimumFrontOpenColumns", 3)) \
        and int(summary.get("mouthRowsChecked", 0)) >= 4 \
        and int(summary.get("jaggedMouthRows", 999)) == 0 \
        and int(summary.get("blockedCenterSamples", 999)) == 0 \
        and int(summary.get("exteriorShellSamples", 999)) <= int(summary.get("minimumFrontOpenColumns", 3)) * maxi(2, int(summary.get("frontDepthCells", 2))) \
        and float(summary.get("frontFloorGap", 999.0)) <= CELL * 0.30 \
        and float(summary.get("frontArchRise", 0.0)) >= CELL * 0.40

func cave_min_front_open_columns(mouth_width: float) -> int:
    return maxi(3, floori(maxf(1.75, mouth_width) * 1.45))

func cave_mouth_front_depth_cells(plan: Dictionary, fallback_approach_depth: int) -> int:
    var subsurface = main.get("subsurface_system") if main != null else null
    if subsurface != null and subsurface.has_method("cave_mouth_front_depth"):
        return maxi(1, ceili(absf(float(subsurface.call("cave_mouth_front_depth", plan)))))
    return maxi(1, mini(4, fallback_approach_depth))

func cave_plan_mouth_envelope(plan: Dictionary) -> Dictionary:
    var envelope_value = plan.get("mouthEnvelope", {})
    if envelope_value is Dictionary and not (envelope_value as Dictionary).is_empty():
        return envelope_value as Dictionary
    if structure_system != null and structure_system.has_method("cave_mouth_envelope_summary"):
        return structure_system.call("cave_mouth_envelope_summary", plan)
    return {}

func cave_mouth_envelope_passed(envelope: Dictionary, mouth_width: float) -> bool:
    if envelope.is_empty():
        return false
    var selected_width := float(envelope.get("selectedHalfWidth", envelope.get("probeHalfWidth", mouth_width)))
    var requested_width := float(envelope.get("requestedHalfWidth", selected_width))
    return bool(envelope.get("passed", false)) \
        and absf(selected_width - mouth_width) <= 0.05 \
        and selected_width <= requested_width + 0.01 \
        and float(envelope.get("minRoofMargin", -999.0)) >= float(envelope.get("requiredRoofMargin", 999.0)) \
        and float(envelope.get("minSideMargin", -999.0)) >= float(envelope.get("requiredSideMargin", 999.0))

func cave_negative_y_growth_summary(plan: Dictionary) -> Dictionary:
    if main == null or structure_system == null:
        return { "sampleCount": 0, "reason": "missing main or structure system" }
    var builder = structure_system.get("cave_interior_builder")
    if builder == null or not builder.has_method("floor_point") or not builder.has_method("ceiling_point"):
        return { "sampleCount": 0, "reason": "missing cave interior builder samplers" }
    var edits_value = main.get("height_edits")
    var edits: Dictionary = edits_value if edits_value is Dictionary else {}
    var opening_cells: Array = structure_system.call("cave_terrain_opening_cells", plan)
    var opening_lookup := {}
    for cell_value in opening_cells:
        if cell_value is Vector2i:
            opening_lookup[cell_value] = true
    var portal_cells: Array = structure_system.call("cave_mouth_portal_cells", plan) if structure_system.has_method("cave_mouth_portal_cells") else []
    for cell_value in portal_cells:
        if cell_value is Vector2i:
            opening_lookup[cell_value] = true
    var raised_edit_cells := 0
    var max_edit_raise := 0.0
    for cell_value in opening_cells:
        if not (cell_value is Vector2i):
            continue
        var opening_cell: Vector2i = cell_value
        if not edits.has(opening_cell):
            continue
        var base_height := cave_base_height_cell(opening_cell)
        var edit_height := float(edits[opening_cell])
        var raise_amount := edit_height - base_height
        if raise_amount > 0.025:
            raised_edit_cells += 1
            max_edit_raise = maxf(max_edit_raise, raise_amount)
    var walkable_cells: Array = structure_system.call("cave_walkable_cells", plan, false)
    var sample_count := 0
    var exposed_ceiling_cells := 0
    var positive_y_ceiling_cells := 0
    var floor_above_terrain_cells := 0
    var min_terrain_cover := INF
    var max_ceiling_above_terrain := -INF
    var min_floor_clearance := INF
    var total_cover := 0.0
    var worst_cell := Vector2i.ZERO
    var required_cover := CELL * 1.85
    var max_samples := 360
    var stride := maxi(1, ceili(float(walkable_cells.size()) / float(max_samples)))
    var index := 0
    for cell_value in walkable_cells:
        index += 1
        if index % stride != 0:
            continue
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        if opening_lookup.has(cell):
            continue
        var point := cave_cell_world2(cell)
        var floor_value = builder.call("floor_point", plan, point)
        var ceiling_value = builder.call("ceiling_point", plan, point)
        if not (floor_value is Vector3) or not (ceiling_value is Vector3):
            continue
        var terrain_y := effective_cave_surface_height_cell(plan, cell)
        var floor_y := float((floor_value as Vector3).y)
        var ceiling_y := float((ceiling_value as Vector3).y)
        var cover := terrain_y - ceiling_y
        var floor_clearance := terrain_y - floor_y
        sample_count += 1
        total_cover += cover
        if cover < min_terrain_cover:
            min_terrain_cover = cover
            worst_cell = cell
        max_ceiling_above_terrain = maxf(max_ceiling_above_terrain, ceiling_y - terrain_y)
        min_floor_clearance = minf(min_floor_clearance, floor_clearance)
        if cover < required_cover:
            exposed_ceiling_cells += 1
        if ceiling_y > terrain_y + 0.025:
            positive_y_ceiling_cells += 1
        if floor_y > terrain_y + 0.025:
            floor_above_terrain_cells += 1
    var entrance_cell: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var final_cell: Vector2i = plan.get("finalChamberCell", entrance_cell)
    var entrance_floor_value = builder.call("floor_point", plan, cave_cell_world2(entrance_cell))
    var final_floor_value = builder.call("floor_point", plan, cave_cell_world2(final_cell))
    var entrance_floor_y := float((entrance_floor_value as Vector3).y) if entrance_floor_value is Vector3 else float(plan.get("level", 0.0))
    var final_floor_y := float((final_floor_value as Vector3).y) if final_floor_value is Vector3 else float(plan.get("level", 0.0))
    var route_drop_y := entrance_floor_y - final_floor_y
    var available_drop := maxf(0.0, float(plan.get("level", 0.0)) + 0.22 - (float(main.WATER_LEVEL) + CELL * 1.45))
    var required_route_drop := minf(CELL * 1.25, available_drop * 0.45)
    if required_route_drop < CELL * 0.45 and available_drop >= CELL * 0.70:
        required_route_drop = CELL * 0.45
    return {
        "sampleCount": sample_count,
        "requiredTerrainCover": snappedf(required_cover, 0.001),
        "minTerrainCover": snappedf(0.0 if min_terrain_cover == INF else min_terrain_cover, 0.001),
        "averageTerrainCover": snappedf(0.0 if sample_count == 0 else total_cover / float(sample_count), 0.001),
        "maxCeilingAboveTerrain": snappedf(0.0 if max_ceiling_above_terrain == -INF else max_ceiling_above_terrain, 0.001),
        "minFloorClearance": snappedf(0.0 if min_floor_clearance == INF else min_floor_clearance, 0.001),
        "exposedCeilingCells": exposed_ceiling_cells,
        "positiveYCeilingCells": positive_y_ceiling_cells,
        "floorAboveTerrainCells": floor_above_terrain_cells,
        "raisedTerrainEditCells": raised_edit_cells,
        "maxTerrainEditRaise": snappedf(max_edit_raise, 0.001),
        "entranceFloorY": snappedf(entrance_floor_y, 0.001),
        "finalFloorY": snappedf(final_floor_y, 0.001),
        "routeDropY": snappedf(route_drop_y, 0.001),
        "requiredRouteDropY": snappedf(required_route_drop, 0.001),
        "availableDropY": snappedf(available_drop, 0.001),
        "worstCoverCell": vec2i(worst_cell)
    }

func cave_negative_y_growth_passed(summary: Dictionary) -> bool:
    return int(summary.get("sampleCount", 0)) > 0 \
        and int(summary.get("raisedTerrainEditCells", 999)) == 0 \
        and int(summary.get("positiveYCeilingCells", 999)) == 0 \
        and int(summary.get("floorAboveTerrainCells", 999)) == 0 \
        and int(summary.get("exposedCeilingCells", 999)) == 0 \
        and float(summary.get("minTerrainCover", -999.0)) >= float(summary.get("requiredTerrainCover", CELL * 0.35)) \
        and float(summary.get("routeDropY", 0.0)) >= float(summary.get("requiredRouteDropY", 0.0))

func cave_base_height_cell(cell: Vector2i) -> float:
    if main != null and main.has_method("base_height_cell"):
        return float(main.call("base_height_cell", cell.x, cell.y))
    if main != null and main.has_method("terrain_height_cell"):
        return float(main.call("terrain_height_cell", cell.x, cell.y))
    return 0.0

func effective_cave_surface_height_cell(plan: Dictionary, cell: Vector2i) -> float:
    var subsurface = main.get("subsurface_system") if main != null else null
    if subsurface != null and subsurface.has_method("surface_height_for_cell"):
        return float(subsurface.call("surface_height_for_cell", cell.x, cell.y))
    if main != null and main.has_method("terrain_height_cell"):
        return float(main.call("terrain_height_cell", cell.x, cell.y))
    return cave_base_height_cell(cell)

func cave_cell_world2(cell: Vector2i) -> Vector2:
    return Vector2(float(cell.x) * CELL, float(cell.y) * CELL)

func cave_world_volume_summary(plan: Dictionary) -> Dictionary:
    if main == null or structure_system == null:
        return { "passed": false, "reason": "missing main or structure system" }
    var world_generation = main.get("world_generation_system")
    if world_generation == null or not world_generation.has_method("solid_at_world"):
        return { "passed": false, "reason": "missing world generation solid sampler" }
    if not main.has_method("biome_at_world"):
        return { "passed": false, "reason": "missing world biome sampler" }
    var builder = structure_system.get("cave_interior_builder")
    if builder == null or not builder.has_method("floor_point") or not builder.has_method("ceiling_point"):
        return { "passed": false, "reason": "missing cave interior builder samplers" }
    var walkable_cells: Array = structure_system.call("cave_walkable_cells", plan, false)
    var sample_count := 0
    var cave_biome_samples := 0
    var air_samples := 0
    var non_cave_samples: Array = []
    var solid_samples: Array = []
    var stride := maxi(1, walkable_cells.size() / 12)
    for index in range(0, walkable_cells.size(), stride):
        if sample_count >= 12:
            break
        var cell_value = walkable_cells[index]
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var point := cave_cell_world2(cell)
        var floor_value = builder.call("floor_point", plan, point)
        var ceiling_value = builder.call("ceiling_point", plan, point)
        if not (floor_value is Vector3) or not (ceiling_value is Vector3):
            continue
        var floor_y := float((floor_value as Vector3).y)
        var ceiling_y := float((ceiling_value as Vector3).y)
        var sample_y := minf(ceiling_y - CELL * 0.25, floor_y + CELL * 0.72)
        if sample_y <= floor_y + CELL * 0.10:
            sample_y = lerpf(floor_y, ceiling_y, 0.5)
        var sample_pos := Vector3(point.x, sample_y, point.y)
        var biome := String(main.call("biome_at_world", sample_pos))
        var is_solid := bool(world_generation.call("solid_at_world", sample_pos))
        sample_count += 1
        if biome == "cave":
            cave_biome_samples += 1
        elif non_cave_samples.size() < 5:
            non_cave_samples.append({ "cell": vec2i(cell), "biome": biome })
        if not is_solid:
            air_samples += 1
        elif solid_samples.size() < 5:
            solid_samples.append({ "cell": vec2i(cell), "position": vec3(sample_pos) })
    return {
        "passed": sample_count >= 3 and cave_biome_samples == sample_count and air_samples == sample_count,
        "sampleCount": sample_count,
        "caveBiomeSamples": cave_biome_samples,
        "airSamples": air_samples,
        "nonCaveSamples": non_cave_samples,
        "solidSamples": solid_samples
    }

func wall_torch_visible_back_inset(torch: Node) -> float:
    if torch == null:
        return 0.0
    var max_back := -INF
    for child in torch.get_children():
        var visual := child as MeshInstance3D
        if visual == null:
            continue
        if visual.name != "WallTorchBackplate" and visual.name != "WallTorchSocket":
            continue
        max_back = maxf(max_back, visual.position.z + absf(visual.scale.z) * 0.5)
    return 0.0 if max_back == -INF else max_back

func cave_navigation_summary(plan: Dictionary) -> Dictionary:
    var cave_id := String(plan.get("id", ""))
    var records: Dictionary = structure_system.call("cave_navigation_records_snapshot") if structure_system.has_method("cave_navigation_records_snapshot") else {}
    var record: Dictionary = records.get(cave_id, {}) if records.has(cave_id) else {}
    var record_walkable: Array = record.get("walkableCells", []) if record.has("walkableCells") else []
    var samples: Array[Vector2i] = cave_navigation_sample_cells(plan)
    var lookup_matches := 0
    for cell in samples:
        if String(structure_system.call("cave_navigation_id_for_cell", cell.x, cell.y)) == cave_id:
            lookup_matches += 1
    var navmesh_tagged := cave_navmesh_cave_tagged_sample_count(samples)
    return {
        "recordFound": not record.is_empty(),
        "recordWalkableCells": record_walkable.size(),
        "recordNodeCount": array_size(record.get("graphNodes", [])),
        "recordEdgeCount": array_size(record.get("graphEdges", [])),
        "sampleCells": vec2i_array(samples),
        "lookupMatchedSampleCells": lookup_matches,
        "navmeshCaveTaggedSampleCells": navmesh_tagged
    }

func cave_navigation_sample_cells(plan: Dictionary) -> Array[Vector2i]:
    var samples: Array[Vector2i] = []
    samples.append(plan.get("entranceCell", Vector2i.ZERO))
    samples.append(plan.get("finalChamberCell", Vector2i.ZERO))
    var nodes_value = plan.get("caveNodes", [])
    if nodes_value is Array:
        for node_value in nodes_value:
            if not (node_value is Dictionary):
                continue
            var node: Dictionary = node_value
            if String(node.get("kind", "")) == "dead_end":
                samples.append(node.get("cell", Vector2i.ZERO))
                break
    var path_value = plan.get("pathCells", [])
    if path_value is Array and not (path_value as Array).is_empty():
        var path_cells: Array = path_value
        var middle_cell: Vector2i = path_cells[int(path_cells.size() / 2)]
        samples.append(middle_cell)
    var unique: Array[Vector2i] = []
    var seen := {}
    for cell in samples:
        if seen.has(cell):
            continue
        seen[cell] = true
        unique.append(cell)
    return unique

func cave_navmesh_cave_tagged_sample_count(samples: Array[Vector2i]) -> int:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return 0
    var pathing = npc_system.get("pathing")
    if pathing == null:
        return 0
    if pathing.has_method("ensure_ready"):
        pathing.ensure_ready()
    var navigation_world = pathing.get("navigation_world")
    if navigation_world == null or not navigation_world.has_method("build_snapshot") or not navigation_world.has_method("_navmesh_surface_for_cell"):
        return 0
    var snapshot: Dictionary = navigation_world.call("build_snapshot", {}, true, true)
    var tagged := 0
    for cell in samples:
        var surface: Dictionary = navigation_world.call("_navmesh_surface_for_cell", snapshot, cell)
        var tags: Array = surface.get("traversalTags", []) if not surface.is_empty() else []
        if tags.has("cave"):
            tagged += 1
    return tagged

func cave_interior_summary(plan: Dictionary) -> Dictionary:
    var nodes_value = structure_system.get("cave_interior_nodes") if structure_system != null else {}
    var nodes: Dictionary = nodes_value if nodes_value is Dictionary else {}
    var cave_id := String(plan.get("id", ""))
    var shells := 0
    var meshes := 0
    var collision_bodies := 0
    var player_blocking_bodies := 0
    var support_frames := 0
    var layer_summary := { "visuals": 0, "nonCaveLayerVisuals": 0 }
    for node_value in nodes.values():
        var node := node_value as Node
        if node == null or not is_instance_valid(node):
            continue
        if String(node.get_meta("caveId", "")) != cave_id:
            continue
        shells += 1
        meshes += count_cave_interior_visuals(node)
        collision_bodies += count_cave_interior_bodies(node)
        player_blocking_bodies += count_cave_interior_player_blocking_bodies(node)
        support_frames += count_cave_support_frames(node)
        add_cave_layer_summary(layer_summary, node)
    var floor_summary := cave_floor_variation_summary(plan)
    return {
        "shells": shells,
        "meshes": meshes,
        "collisionBodies": collision_bodies,
        "playerBlockingBodies": player_blocking_bodies,
        "supportFrames": support_frames,
        "caveLayerVisuals": int(layer_summary.get("visuals", 0)) - int(layer_summary.get("nonCaveLayerVisuals", 0)),
        "nonCaveLayerVisuals": int(layer_summary.get("nonCaveLayerVisuals", 0)),
        "floorHeightRange": float(floor_summary.get("range", 0.0)),
        "maxFloorNeighborStep": float(floor_summary.get("maxNeighborStep", 0.0))
    }

func count_cave_interior_visuals(node: Node) -> int:
    var count := 0
    if node is MeshInstance3D and (node.name == "CaveInteriorVisual" or node.name == "SubsurfaceCaveVisual") and (node as MeshInstance3D).mesh != null:
        count += 1
    for child in node.get_children():
        count += count_cave_interior_visuals(child)
    return count

func count_cave_interior_bodies(node: Node) -> int:
    var count := 0
    if node is StaticBody3D and (node.name == "CaveInteriorBody" or node.name == "SubsurfaceCaveBody"):
        count += 1
    for child in node.get_children():
        count += count_cave_interior_bodies(child)
    return count

func count_cave_interior_player_blocking_bodies(node: Node) -> int:
    var count := 0
    if node is StaticBody3D and (node.name == "CaveInteriorBody" or node.name == "SubsurfaceCaveBody"):
        var body := node as StaticBody3D
        if (int(body.collision_layer) & 1) != 0:
            count += 1
    for child in node.get_children():
        count += count_cave_interior_player_blocking_bodies(child)
    return count

func count_cave_support_frames(node: Node) -> int:
    var count := 0
    if String(node.get_meta("caveRole", "")) == "support_frame":
        count += 1
    for child in node.get_children():
        count += count_cave_support_frames(child)
    return count

func add_cave_layer_summary(summary: Dictionary, node: Node) -> void:
    if node is VisualInstance3D:
        summary["visuals"] = int(summary.get("visuals", 0)) + 1
        if int((node as VisualInstance3D).layers) != 2:
            summary["nonCaveLayerVisuals"] = int(summary.get("nonCaveLayerVisuals", 0)) + 1
    for child in node.get_children():
        add_cave_layer_summary(summary, child)

func cave_floor_variation_summary(plan: Dictionary) -> Dictionary:
    if structure_system == null:
        return {}
    var builder = structure_system.get("cave_interior_builder")
    if builder == null or not builder.has_method("floor_variation_summary"):
        return {}
    return builder.call("floor_variation_summary", plan)

func chest_has_crafting_book(chest: Node) -> bool:
    if chest == null or not chest.has_meta("storage_slots"):
        return false
    var slots: Array = chest.get_meta("storage_slots")
    for slot in slots:
        if not (slot is Dictionary):
            continue
        var item_id := String(slot.get("item", ""))
        if (item_id.begins_with("craftingBook") or item_id.begins_with("rareBook")) and int(slot.get("count", 0)) > 0:
            return true
    return false

func cave_final_chest_node(plan: Dictionary) -> Node:
    var blocks_value = main.get("blocks") if main != null else {}
    var blocks: Dictionary = blocks_value if blocks_value is Dictionary else {}
    var cave_id := String(plan.get("id", ""))
    for block_value in blocks.values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("generatedTier", "")) == "cave" \
            and String(block.get_meta("caveId", "")) == cave_id \
            and String(block.get_meta("caveRole", "")) == "final_chest":
            return block
    return null

func cave_test_slots() -> Array:
    var slots := []
    for i in range(12):
        slots.append({ "item": "", "count": 0 })
    slots[0] = { "item": "stones", "count": 7 }
    slots[1] = { "item": "craftingBookStone", "count": 1 }
    return slots

func cave_chest_has_slot(chest: Node, item_id: String, count: int) -> bool:
    if chest == null or not chest.has_meta("storage_slots"):
        return false
    var slots_value = chest.get_meta("storage_slots")
    if not (slots_value is Array):
        return false
    for slot_value in slots_value:
        if not (slot_value is Dictionary):
            continue
        var slot: Dictionary = slot_value
        if String(slot.get("item", "")) == item_id and int(slot.get("count", 0)) == count:
            return true
    return false

func cave_snapshot_has_slot(cave_entries: Array, cave_id: String, item_id: String, count: int) -> bool:
    for entry_value in cave_entries:
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        if String(entry.get("id", "")) != cave_id:
            continue
        var slots_value = entry.get("finalChestSlots", [])
        if not (slots_value is Array):
            return false
        for slot_value in slots_value:
            if not (slot_value is Dictionary):
                continue
            var slot: Dictionary = slot_value
            if String(slot.get("item", "")) == item_id and int(slot.get("count", 0)) == count:
                return true
    return false

func cleanup_generated_blocks() -> void:
    if main == null:
        return
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return
    var blocks: Dictionary = blocks_value
    for key in blocks.keys().duplicate():
        var block := blocks[key] as Node
        if block != null and bool(block.get_meta("generated", false)):
            block.queue_free()
            blocks.erase(key)
    cleanup_cave_interiors()

func cleanup_cave_interiors() -> void:
    if structure_system == null:
        return
    var nodes_value = structure_system.get("cave_interior_nodes")
    if not (nodes_value is Dictionary):
        return
    var nodes: Dictionary = nodes_value
    for node_key in nodes.keys().duplicate():
        var node := nodes[node_key] as Node
        if node != null and is_instance_valid(node):
            node.queue_free()
        nodes.erase(node_key)

func restore_height_edits(snapshot) -> void:
    if main != null and main.has_method("restore_height_edits"):
        main.call("restore_height_edits", snapshot)

func add_result(name: String, passed: bool, details := "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func all_passed() -> bool:
    for result in results:
        if not bool(result.get("passed", false)):
            return false
    return true

func save_report() -> void:
    var report := {
        "schemaVersion": 1,
        "testId": "cave_generation_integration",
        "seed": seed,
        "finished": true,
        "passed": all_passed(),
        "evidenceLevel": "integration",
        "scope": "Procedural cave generator, structure block metadata, terrain shaping, and cave chest loot; not player visual acceptance.",
        "resultCount": results.size(),
        "failureCount": failure_count(),
        "results": results
    }
    var report_path := OS.get_environment("VOXEL_CAVE_GENERATION_REPORT")
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/caves/cave-generation-report.json")
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(report, "  "))
        file.close()
    print(JSON.stringify(report, "  "))

func failure_count() -> int:
    var count := 0
    for result in results:
        if not bool(result.get("passed", false)):
            count += 1
    return count

func wait_frames(count: int) -> void:
    for i in range(count):
        await process_frame

func cave_array_size(plan: Dictionary, key: String) -> int:
    var value = plan.get(key, [])
    return value.size() if value is Array else 0

func array_size(value) -> int:
    return value.size() if value is Array else 0

func sanitize_plan_summary(plan: Dictionary) -> Dictionary:
    if plan.is_empty():
        return {}
    return {
        "id": String(plan.get("id", "")),
        "kind": String(plan.get("kind", "")),
        "caveTier": String(plan.get("caveTier", "normal")),
        "moundBacked": bool(plan.get("moundBacked", false)),
        "region": vec2i(plan.get("region", Vector2i.ZERO)),
        "entranceCell": vec2i(plan.get("entranceCell", Vector2i.ZERO)),
        "finalChamberCell": vec2i(plan.get("finalChamberCell", Vector2i.ZERO)),
        "finalChestCell": vec2i(plan.get("finalChestCell", Vector2i.ZERO)),
        "surfaceLevel": snappedf(float(plan.get("surfaceLevel", 0.0)), 0.001),
        "floorLevel": snappedf(float(plan.get("level", 0.0)), 0.001),
        "ceilingLevel": snappedf(float(plan.get("ceilingLevel", 0.0)), 0.001),
        "entranceMouthHalfWidth": snappedf(float(plan.get("entranceMouthHalfWidth", 0.0)), 0.001),
        "entranceMouthArchHeight": snappedf(float(plan.get("entranceMouthArchHeight", 0.0)), 0.001),
        "mouthEnvelope": sanitize(cave_plan_mouth_envelope(plan)),
        "pathLength": int(plan.get("pathLength", 0)),
        "minimumRouteCells": int(plan.get("minimumRouteCells", 0)),
        "chamberRadius": int(plan.get("chamberRadius", 0)),
        "nodeCount": cave_array_size(plan, "caveNodes"),
        "edgeCount": cave_array_size(plan, "caveEdges"),
        "branchCount": cave_array_size(plan, "branchChamberIds"),
        "deadEndCount": cave_array_size(plan, "deadEndChamberIds"),
        "entranceVariation": snappedf(float(plan.get("entranceVariation", 0.0)), 0.001)
    }

func sanitize(value):
    if value is Vector2i:
        return vec2i(value)
    if value is Vector3i:
        return { "x": value.x, "y": value.y, "z": value.z }
    if value is Vector3:
        return { "x": snappedf(value.x, 0.001), "y": snappedf(value.y, 0.001), "z": snappedf(value.z, 0.001) }
    if value is Array:
        var result := []
        for item in value:
            result.append(sanitize(item))
        return result
    if value is Dictionary:
        var result := {}
        for key in value.keys():
            var key_text := ""
            if key is Vector2i:
                key_text = "%d,%d" % [key.x, key.y]
            elif key is Vector3i:
                key_text = "%d,%d,%d" % [key.x, key.y, key.z]
            else:
                key_text = str(key)
            result[key_text] = sanitize(value[key])
        return result
    return value

func vec2i(value: Vector2i) -> Dictionary:
    return { "x": value.x, "z": value.y }

func vec3(value: Vector3) -> Dictionary:
    return { "x": snappedf(value.x, 0.001), "y": snappedf(value.y, 0.001), "z": snappedf(value.z, 0.001) }

func vec2i_array(values: Array[Vector2i]) -> Array:
    var result := []
    for value in values:
        result.append(vec2i(value))
    return result
