extends SceneTree

const Snapshot := preload("res://scripts/testing/VisibleWorldPropSourceSnapshot.gd")

class ControllerFixture extends RefCounted:
    var _owners: Dictionary = {}

class LedgerFixture extends RefCounted:
    var _sources: Dictionary = {}

class MainFixture extends Node:
    var chunks: Dictionary = {}
    var pending_chunk_prop_spawns: Dictionary = {}
    var visible_world_demand_controller: Object
    var horizon_ecology_source: Object
    var player: Node3D
    var seed_text := "snapshot-seed"
    var underground_visuals_required := false
    func visible_world_underground_visuals_required() -> bool:
        return underground_visuals_required

class HorizonFixture extends RefCounted:
    var states: Dictionary = {}
    var roots: Dictionary = {}
    func source_for(key: Vector2i) -> Node3D:
        return roots.get(key) as Node3D


func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var main := MainFixture.new()
    root.add_child(main)
    main.player = Node3D.new()
    main.add_child(main.player)
    main.visible_world_demand_controller = ControllerFixture.new()
    main.horizon_ecology_source = HorizonFixture.new()
    var current := Vector2i(1, 0)
    var ring := Vector2i(2, 2)
    for key in [current, ring]:
        var chunk := Node3D.new()
        main.add_child(chunk)
        main.chunks[key] = chunk
        main.pending_chunk_prop_spawns[key] = {"chunk": chunk, "phase": "props",
            "propIndex": 7, "detailIndex": 0,
            "undergroundVolumeFloorScan": {"chunkSize": 28,
                "columnIndex": 17, "scanY": 6},
            "undergroundCandidates": [Vector3i(1, -2, 0)],
            "undergroundScanCellsProcessed": 134,
            "undergroundScanLastSliceCells": 16,
            "undergroundScanRestartCount": 2}
    var ledger := LedgerFixture.new()
    var view := {"chunkKeys": [current], "propSources": {}, "propJobs": {},
        "missingChunkSources": {}, "lastProp": {}, "ledger": ledger,
        "nearBounds": Rect2i(-1, -1, 3, 3), "demandRevision": 4,
        "viewRevision": 2}
    (main.visible_world_demand_controller as ControllerFixture)._owners["player"] = {
        "current": view, "pending": {}}
    var first: Dictionary = Snapshot.capture(main)
    var first_row: Dictionary = first.views.current.rows[0]
    if first_row.diagnosticStage != "producer_scan_incomplete" \
            or not bool(first_row.physicalProducerPending) \
            or bool(first_row.undergroundVisualsRequired) \
            or int(first_row.physicalUndergroundScanCellsProcessed) != 134 \
            or int(first_row.physicalUndergroundScanLastSliceCells) != 16 \
            or int(first_row.physicalUndergroundScanColumn) != 17 \
            or int(first_row.physicalUndergroundScanY) != 6 \
            or int(first_row.physicalUndergroundScanColumnsTotal) != 784 \
            or int(first_row.physicalUndergroundCandidateCount) != 1 \
            or int(first_row.physicalUndergroundScanRestarts) != 2 \
            or int(first.ring.physicalOwners) != 1 \
            or int(first.ring.surfaceComplete) != 0:
        push_error("prop source snapshot lost underground scan progress or ring ownership")
        quit(1)
        return
    var horizon_root := Node3D.new()
    main.add_child(horizon_root)
    horizon_root.set_meta("chunk_surface_candidate_scan_complete", true)
    (main.horizon_ecology_source as HorizonFixture).roots[current] = horizon_root
    var handed_off: Dictionary = Snapshot.capture(main)
    var handoff_row: Dictionary = handed_off.views.current.rows[0]
    if handoff_row.manifestSourceOwner != "horizon" \
            or not bool(handoff_row.requiredSourceScanComplete) \
            or bool(handoff_row.physicalSurfaceScanComplete):
        push_error("prop source snapshot did not select the retained far horizon owner")
        quit(1)
        return
    var current_chunk: Node3D = main.chunks[current]
    current_chunk.set_meta("chunk_surface_candidate_scan_complete", true)
    var ring_chunk: Node3D = main.chunks[ring]
    ring_chunk.set_meta("chunk_surface_candidate_scan_complete", true)
    view.propSources[current] = true
    var source_identity := "chunk-props:snapshot-seed:1,0"
    ledger._sources[source_identity + ":props"] = {"complete": true, "candidates": {}}
    var completed: Dictionary = Snapshot.capture(main)
    var completed_row: Dictionary = completed.views.current.rows[0]
    if completed_row.diagnosticStage != "manifest_submitted" \
            or completed_row.manifestSourceOwner != "physical" \
            or int(completed_row.ledgerSourceKindsComplete) != 1 \
            or int(completed.ring.surfaceComplete) != 1:
        push_error("prop source snapshot did not report submitted ledger and ring completion")
        quit(1)
        return
    main.underground_visuals_required = true
    var below_ground: Dictionary = Snapshot.capture(main)
    var below_row: Dictionary = below_ground.views.current.rows[0]
    if not bool(below_row.undergroundVisualsRequired) \
            or bool(below_row.requiredSourceScanComplete):
        push_error("below-ground visual snapshot did not require full underground scan")
        quit(1)
        return
    (main.chunks[current] as Node3D).set_meta("chunk_prop_candidate_scan_complete", true)
    var underground_complete: Dictionary = Snapshot.capture(main)
    if not bool(underground_complete.views.current.rows[0].requiredSourceScanComplete):
        push_error("below-ground visual snapshot ignored completed full scan")
        quit(1)
        return
    print("visible_world_prop_source_snapshot_contract: passed")
    main.queue_free()
    quit(0)
