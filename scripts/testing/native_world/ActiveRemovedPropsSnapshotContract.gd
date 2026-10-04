extends SceneTree

const MainScript := preload("res://scripts/Main.gd")
const SnapshotScript := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func check(name: String, passed: bool) -> void:
	results.append({"name": name, "passed": passed})
	if not passed:
		push_error("removed props capture: " + name)

func run() -> void:
	var main = MainScript.new()
	main.seed_text = "capture-seed"
	main.removed_props = {"rock:child1": true, "tree:parent": true, "é-tree": false}
	var captured: Dictionary = SnapshotScript.capture(main)
	check("capture_ready", bool(captured.get("ok", false)))
	check("sorted_parent_child_unicode", captured.get("ids") == ["rock:child1", "tree:parent", "é-tree"])
	check("initial_current", SnapshotScript.is_current(main, captured))
	var scoped := SnapshotScript.capture_for_ids(main, ["tree:parent", "not-removed"])
	check("scoped_capture_contains_only_matching_requested_tombstones",
		bool(scoped.get("ok", false)) and scoped.get("scope") == "requested_ids" \
		and scoped.get("checkedIds") == ["not-removed", "tree:parent"] \
		and scoped.get("ids") == ["tree:parent"] \
		and SnapshotScript.is_current_for_ids(main, scoped, ["tree:parent", "not-removed"]))
	main.removed_props["unrelated:prop"] = true
	check("scoped_snapshot_ignores_unrelated_removed_prop",
		SnapshotScript.is_current_for_ids(main, scoped, ["tree:parent", "not-removed"]))
	main.removed_props.erase("unrelated:prop")
	main.removed_props.erase("tree:parent")
	check("scoped_snapshot_rejects_changed_candidate_removal",
		not SnapshotScript.is_current_for_ids(main, scoped, ["tree:parent", "not-removed"]))
	main.removed_props["tree:parent"] = true
	main.restore_removed_props(captured.ids)
	check("same_content_restore_invalidates", not SnapshotScript.is_current(main, captured))
	captured = SnapshotScript.capture(main)
	check("same_content_restore_recaptured", SnapshotScript.is_current(main, captured))
	main.removed_props["rock:child2"] = true
	check("in_place_add_invalidates", not SnapshotScript.is_current(main, captured))
	main.removed_props.erase("rock:child2")
	check("restored_content_revalidates", SnapshotScript.is_current(main, captured))
	var changed := captured.duplicate(true)
	(changed.ids as Array)[0] = "tampered"
	check("tampered_rows_rejected", not SnapshotScript.is_current(main, changed))
	changed = captured.duplicate(true)
	changed.contentIdentity = "tampered"
	check("tampered_digest_rejected", not SnapshotScript.is_current(main, changed))
	main.seed_text = "other-seed"
	check("seed_change_invalidates", not SnapshotScript.is_current(main, captured))
	main.seed_text = "capture-seed"
	main.restore_removed_props(["new:parent", "new:child1"])
	check("restore_invalidates", not SnapshotScript.is_current(main, captured))
	var restored: Dictionary = SnapshotScript.capture(main)
	check("restore_recaptured", restored.get("ids") == ["new:child1", "new:parent"])
	main.restore_removed_props(restored.ids)
	check("same_content_reload_invalidates", not SnapshotScript.is_current(main, restored))
	restored = SnapshotScript.capture(main)
	main.removed_props.clear()
	check("reset_invalidates", not SnapshotScript.is_current(main, restored))
	var empty_before_reset: Dictionary = SnapshotScript.capture(main)
	main.reset_runtime_world_state(false)
	check("same_empty_content_runtime_reset_invalidates", not SnapshotScript.is_current(main, empty_before_reset) \
		and main.removed_props.is_empty())
	main.removed_props[42] = true
	check("non_string_key_rejected", not bool(SnapshotScript.capture(main).get("ok", false)))
	main.removed_props = {"": true}
	check("empty_id_rejected", not bool(SnapshotScript.capture(main).get("ok", false)))
	main.removed_props = {"x".repeat(1025): true}
	check("id_byte_limit_rejected", not bool(SnapshotScript.capture(main).get("ok", false)))
	main.removed_props = {"é".repeat(512): true}
	check("utf8_byte_limit_accepted", bool(SnapshotScript.capture(main).get("ok", false)))
	var other = MainScript.new()
	other.seed_text = main.seed_text
	other.removed_props = main.removed_props.duplicate(true)
	var same_content: Dictionary = SnapshotScript.capture(main)
	check("cross_main_rejected", not SnapshotScript.is_current(other, same_content))
	main.free()
	other.free()
	var passed := true
	for result in results:
		passed = passed and bool(result.passed)
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-active-removed-props-snapshot-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({"finished": true, "passed": passed, "evidenceLevel": "contract",
		"scope": "Capture and freshness only; not native conversion or live gameplay.",
		"resultCount": results.size(), "results": results}, "  "))
	file.close()
	quit(0 if passed else 1)
