extends Node

const SEED := "release-gate-1492"
const INITIALIZE_SCHEMA := "n3-native-world-backend-initialize-from-save-v2/v1"
const TYPED_TRANSACTION_SCHEMA := "n3-native-typed-cell-transaction/v1"
const DURABLE_TRANSACTION_SCHEMA := "n3-native-durable-cell-transaction/v1"
const EXTENSION_PATH := "res://addons/terrain_meshing_backend/terrain_meshing_backend.gdextension"

var failures: Array[String] = []
var checks: Dictionary = {}


func check(label: String, passed: bool) -> void:
	checks[label] = passed
	if not passed:
		failures.append(label)


func initialization() -> Dictionary:
	return {
		"schema": INITIALIZE_SCHEMA,
		"seedText": SEED,
		"saveSeedText": SEED,
		"revisions": {
			"sourceSchema": 2,
			"terrainGenerator": 1,
			"biomeRegionField": 2,
			"latticeQuery": 1,
			"cellCenterQuery": 1,
			"surfaceColumnQuery": 1,
		},
		"constants": {
			"cellSizeMeters": 1.35,
			"cellCenterOffsetCells": 0.5,
			"worldBottomCellY": -64,
			"waterLevelMeters": 11.1,
			"minimumSurfaceMeters": 4.0,
			"maximumSurfaceMeters": 120.0,
		},
		"sitePolicy": {
			"sourcePolicyRevision": 1,
			"surveyGenerationPolicyRevision": 1,
			"ordinaryRegionCells": 140,
			"ordinarySpawnChance": 0.08,
			"townOverrides": [],
		},
		"terrainVolume": imported_volume(),
	}


func imported_volume() -> Dictionary:
	var cell := [-17, -1, -1]
	var section := [-2, -1, -1]
	var local := [15, 15, 15]
	return {
		"schemaVersion": 1,
		"sectionSize": 16,
		"revision": 7,
		"sections": [{
			"schemaVersion": 1,
			"sectionKey": section,
			"originCell": [-32, -16, -16],
			"revision": 6,
			"cells": [{
				"cell": cell,
				"local": local,
				"state": {
					"cell": cell,
					"sectionKey": section,
					"localCell": local,
					"blockId": "release_gate.imported",
					"material": "stone",
					"biome": "deep_underground",
					"solid": true,
					"density": 1.25,
					"fluid": "",
					"light": {"sky": 3, "block": 11},
					"metadata": {"saveDelta": true, "source": "release_export_gate", "nested": [1, true, "kept"]},
					"editReason": "release_export_gate_import",
					"generated": false,
					"edited": true,
				},
			}],
		}],
	}


func native_state(block_id: String, edit_reason: String, save_delta: bool) -> Dictionary:
	return {
		"materialId": 3,
		"biomeId": 12,
		"solid": true,
		"density": 1.5,
		"fluidId": 0,
		"light": Vector2i(2, 9),
		"metadata": {"saveDelta": save_delta, "source": "release_export_gate"},
		"blockId": block_id,
		"editReason": edit_reason,
	}


func json_semantic_value(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort_custom(func(left: Variant, right: Variant) -> bool: return String(left) < String(right))
		var normalized := {}
		for key in keys:
			normalized[String(key)] = json_semantic_value(value[key])
		return normalized
	if value is Array:
		var normalized: Array = []
		for item in value:
			normalized.append(json_semantic_value(item))
		return normalized
	if value is int or value is float:
		return float(value)
	return value


func _ready() -> void:
	call_deferred("run")


func run() -> void:
	var version := Engine.get_version_info()
	var features := {
		"release": OS.has_feature("release"),
		"template": OS.has_feature("template"),
		"debug": OS.has_feature("debug"),
		"editor": OS.has_feature("editor"),
		"editorHint": Engine.is_editor_hint(),
	}
	check("release_feature", bool(features.release))
	check("template_feature", bool(features.template))
	check("debug_feature_absent", not bool(features.debug))
	check("editor_feature_absent", not bool(features.editor))
	check("editor_hint_absent", not bool(features.editorHint))
	check("engine_version", int(version.get("major", -1)) == 4
		and int(version.get("minor", -1)) == 6
		and int(version.get("patch", -1)) == 1
		and String(version.get("status", "")) == "stable"
		and String(version.get("hash", "")) == "14d19694e0c88a3f9e82d899a0400f27a24c176e")
	var extension_load_status := GDExtensionManager.load_extension(EXTENSION_PATH)
	check("extension_load_ok", extension_load_status == GDExtensionManager.LOAD_STATUS_OK)
	check("adapter_registered", ClassDB.class_exists("NativeWorldBackend"))

	var backend = ClassDB.instantiate("NativeWorldBackend") if ClassDB.class_exists("NativeWorldBackend") else null
	check("adapter_instantiated", backend != null)
	var initial_status: Dictionary = backend.status() if backend != null and backend.has_method("status") else {}
	check("shadow_only", initial_status.get("shadowOnly") == true
		and initial_status.get("productionCutover") == false)
	check("save_methods_bound", backend != null
		and backend.has_method("initialize_from_save_v2")
		and backend.has_method("export_terrain_volume_v2"))

	var imported := imported_volume()
	var restore: Dictionary = backend.initialize_from_save_v2(initialization()) if backend != null else {}
	check("save_v2_restore_ready", restore.get("status") == "ready"
		and int(restore.get("terrainDeltaRevision", -1)) == 0)
	var first_export: Dictionary = backend.export_terrain_volume_v2() if backend != null else {}
	check("save_v2_export_ready", first_export.get("status") == "ready")
	check("save_v2_exact_roundtrip", json_semantic_value(first_export.get("terrainVolume", {})) == json_semantic_value(imported)
		and int(first_export.get("persistedRevision", -1)) == 7)

	var overlay_request := {
		"schema": TYPED_TRANSACTION_SCHEMA,
		"transactionId": "release-gate:overlay",
		"expectedRevision": 0,
		"operations": [{
			"namespace": "scene_overlay",
			"kind": "set",
			"cell": Vector3i(7, 8, 9),
			"state": native_state("release_gate.overlay", "release_gate_overlay", false),
		}],
	}
	var overlay_commit: Dictionary = backend.commit_typed_cells(overlay_request) if backend != null else {}
	var overlay_export: Dictionary = backend.export_terrain_volume_v2() if backend != null else {}
	check("overlay_commit_ready", overlay_commit.get("status") == "ready"
		and overlay_commit.get("commitStatus") == "committed"
		and int(overlay_commit.get("revision", -1)) == 1)
	check("overlay_excluded_from_save", json_semantic_value(overlay_export.get("terrainVolume", {})) == json_semantic_value(imported)
		and int(overlay_export.get("persistedRevision", -1)) == 7
		and int(overlay_export.get("terrainDeltaRevision", -1)) == 1)

	var durable_request := {
		"schema": DURABLE_TRANSACTION_SCHEMA,
		"transactionId": "release-gate:durable",
		"expectedRevision": 1,
		"operations": [{
			"kind": "set",
			"cell": Vector3i(-17, -1, -1),
			"state": native_state("release_gate.updated", "release_gate_durable", true),
		}],
	}
	var durable_commit: Dictionary = backend.commit_durable_cells(durable_request) if backend != null else {}
	var final_export: Dictionary = backend.export_terrain_volume_v2() if backend != null else {}
	var final_volume: Dictionary = final_export.get("terrainVolume", {}) if final_export.get("terrainVolume", {}) is Dictionary else {}
	var final_sections: Array = final_volume.get("sections", []) if final_volume.get("sections", []) is Array else []
	var final_cells: Array = final_sections[0].get("cells", []) if final_sections.size() == 1 and final_sections[0] is Dictionary else []
	var final_state: Dictionary = final_cells[0].get("state", {}) if final_cells.size() == 1 and final_cells[0] is Dictionary else {}
	check("durable_commit_ready", durable_commit.get("status") == "ready"
		and durable_commit.get("commitStatus") == "committed"
		and int(durable_commit.get("revision", -1)) == 2)
	check("durable_export_updated", final_export.get("status") == "ready"
		and int(final_export.get("terrainDeltaRevision", -1)) == 2
		and int(final_export.get("persistedRevision", -1)) == 8
		and int(final_volume.get("revision", -1)) == 8
		and final_state.get("blockId") == "release_gate.updated")

	backend = null
	await get_tree().process_frame
	var report := {
		"schema": "native-world-backend-release-save-v2-probe/v1",
		"passed": failures.is_empty(),
		"evidenceLevel": "isolated-release-export-shadow-adapter",
		"productionCutover": false,
		"shadowOnly": true,
		"engineVersion": version,
		"features": features,
		"extensionLoadStatus": extension_load_status,
		"checks": checks,
		"failures": failures,
	}
	var report_path := OS.get_environment("VWB_RELEASE_SAVE_V2_REPORT")
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	get_tree().quit(0 if bool(report.passed) else 1)
