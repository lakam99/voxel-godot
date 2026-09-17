extends SceneTree

const NpcSystemScript := preload("res://scripts/NpcSystem.gd")

func _initialize() -> void:
    var checks: Array[Dictionary] = []
    var root := Node3D.new()
    root.name = "ForageSelectionRoot"
    get_root().add_child(root)

    var farther := candidate(root, "Farther", "forage-c", Vector3(4.0, 0.0, 0.0))
    var tied_b := candidate(root, "TiedB", "forage-b", Vector3(2.0, 0.0, 0.0))
    var tied_a := candidate(root, "TiedA", "forage-a", Vector3(-2.0, 0.0, 0.0))
    var first := NpcSystemScript.deterministic_forage_candidate(
        [farther, tied_b, tied_a] as Array[Node3D], Vector3.ZERO
    )
    var reordered := NpcSystemScript.deterministic_forage_candidate(
        [tied_a, farther, tied_b] as Array[Node3D], Vector3.ZERO
    )
    check(checks, "nearest_then_stable_identity_is_deterministic", first == tied_a and reordered == tied_a)
    check(checks, "nearest_candidate_wins_before_identity", NpcSystemScript.deterministic_forage_candidate(
        [farther, tied_b] as Array[Node3D], Vector3(3.8, 0.0, 0.0)
    ) == farther)

    tied_a.set_meta("npc_unreachable_forager_contract", true)
    var retry_candidates: Array[Node3D] = []
    for value in [tied_a, tied_b, farther]:
        var value_node := value as Node3D
        if not bool(value_node.get_meta("npc_unreachable_forager_contract", false)):
            retry_candidates.append(value_node)
    check(checks, "unreachable_candidate_removal_progresses_to_next_stable_choice",
        NpcSystemScript.deterministic_forage_candidate(retry_candidates, Vector3.ZERO) == tied_b)

    var path_b := Node3D.new()
    path_b.name = "PathB"
    path_b.position = Vector3(0.0, 0.0, 3.0)
    root.add_child(path_b)
    var path_a := Node3D.new()
    path_a.name = "PathA"
    path_a.position = Vector3(0.0, 0.0, -3.0)
    root.add_child(path_a)
    check(checks, "scene_path_is_stable_fallback_without_source_id",
        NpcSystemScript.deterministic_forage_candidate([path_b, path_a] as Array[Node3D], Vector3.ZERO) == path_a)

    var source := FileAccess.get_file_as_string("res://scripts/NpcSystem.gd")
    var selection_source := function_source(source, "func find_forage_target", "func filter_forage_candidates")
    check(checks, "selection_does_not_call_route_cost_or_eager_pathing_ranker",
        not selection_source.contains("route_cost") and not selection_source.contains("choose_forage_target"))
    check(checks, "selection_preserves_cache_filter_and_cache_write",
        selection_source.contains("cached_resource_target_for_entry(entry, \"forage\")") \
        and selection_source.contains("filter_forage_candidates(entry, candidates)") \
        and selection_source.contains("remember_cached_resource_target(entry, \"forage\", chosen)"))
    var validity_source := function_source(source, "func is_valid_forage_node", "func forager_target_cooldown_active")
    check(checks, "production_validity_keeps_unreachable_and_cooldown_rejection",
        validity_source.contains("forager_unreachable_meta_key(entry)") \
        and validity_source.contains("forager_target_cooldown_active(entry, node)"))

    var passed := checks.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false)))
    var report_path := OS.get_environment("VOXEL_FORAGE_SELECTION_CONTRACT_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/test-runners/forage-target-selection-contract.json")
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify({
            "schemaVersion": 1,
            "runnerId": "forage_target_selection_contract",
            "evidenceLevel": "pure_and_static_contract",
            "passed": passed,
            "failureCount": checks.filter(func(row: Dictionary) -> bool: return not bool(row.get("passed", false))).size(),
            "checks": checks,
            "doesNotProve": "No live NPC route execution, resource harvesting, movement, or headed frame-time acceptance."
        }, "  "))
        file.close()
    root.queue_free()
    quit(0 if passed else 1)

func candidate(root: Node3D, node_name: String, prop_id: String, position: Vector3) -> Node3D:
    var node := Node3D.new()
    node.name = node_name
    node.position = position
    node.set_meta("prop_id", prop_id)
    root.add_child(node)
    return node

func function_source(source: String, start_marker: String, end_marker: String) -> String:
    var start := source.find(start_marker)
    if start < 0:
        return ""
    var finish := source.find(end_marker, start + start_marker.length())
    return source.substr(start, finish - start) if finish >= 0 else source.substr(start)

func check(checks: Array[Dictionary], name: String, passed: bool) -> void:
    checks.append({"name": name, "passed": passed})
