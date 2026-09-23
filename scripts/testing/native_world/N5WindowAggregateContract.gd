extends SceneTree

const AGGREGATE = preload("res://scripts/terrain/NativeWindowedCollisionReadiness.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var identity := {"ownerGeneration":7, "sourceRevision":3,
		"sourceEpoch":"aggregate-source", "cancellationEpoch":4,
		"sourceIdentity":{"hex":"aggregate-source-hash"}}
	var source_identity := {"hex":"aggregate-source-hash"}
	var required: Array[Vector3i] = []
	var groups := {}
	for z in range(17):
		for y in range(17):
			for x in range(17):
				var block := Vector3i(x, y, z)
				var id := Vector3i(x / 16, y / 16, z / 16)
				required.append(block)
				if not groups.has(id): groups[id] = []
				groups[id].append(block)
	var ids: Array[Vector3i] = []
	for id in groups: ids.append(id)
	ids.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	var windows := []
	var receipts := {}
	for index in range(ids.size()):
		var id: Vector3i = ids[index]
		var local_token := "window:%d,%d,%d" % [id.x, id.y, id.z]
		var window := {"id":id, "blocks":groups[id],
			"closureToken":local_token, "windowToken":local_token,
			"windowIndex":index, "identity":identity.duplicate(true),
			"localCurrentProof":{"kind":"native_current_revision",
				"throughGlobalRevision":3, "digest":"current:%s" % local_token}}
		windows.append(window)
		receipts[id] = _receipt(identity, source_identity, window)
	var layout := {"status":"ready", "schema":"n3-mesh-window-layout/v1",
		"logicalDemandRevision":21, "logicalClosureToken":"full-4913",
		"layoutToken":"layout-4913", "requiredBlockCount":required.size(),
		"requiredBlocks":required, "windowEdgeBlocks":16,
		"maxWindowBlocks":4096, "windowCount":windows.size(),
		"sourceIdentity":source_identity, "identity":identity,
		"windows":windows}
	var full: Dictionary = AGGREGATE.evaluate(layout, receipts)
	var missing_receipts: Dictionary = receipts.duplicate(true)
	missing_receipts.erase(ids[-1])
	var missing: Dictionary = AGGREGATE.evaluate(layout, missing_receipts)
	var stale_receipts: Dictionary = receipts.duplicate(true)
	stale_receipts[ids[0]].provenance.membershipProvenance.windowToken = "wrong-window"
	var stale: Dictionary = AGGREGATE.evaluate(layout, stale_receipts)
	var duplicate_layout: Dictionary = layout.duplicate(true)
	duplicate_layout.windows[1].blocks[0] = duplicate_layout.windows[0].blocks[0]
	var duplicate: Dictionary = AGGREGATE.evaluate(duplicate_layout, receipts)
	var expanded_layout: Dictionary = layout.duplicate(true)
	var remote := Vector3i(32, 0, 0)
	var remote_window := {"id":Vector3i(2, 0, 0), "blocks":[remote],
		"closureToken":"remote-window", "windowToken":"remote-window",
		"windowIndex":expanded_layout.windows.size(),
		"identity":identity.duplicate(true),
		"localCurrentProof":{"kind":"native_current_revision",
			"throughGlobalRevision":3, "digest":"current:remote-window"}}
	expanded_layout.requiredBlocks.append(remote)
	expanded_layout.requiredBlockCount += 1
	expanded_layout.windows.append(remote_window)
	expanded_layout.windowCount += 1
	expanded_layout.logicalDemandRevision += 1
	expanded_layout.logicalClosureToken = "full-4914"
	expanded_layout.layoutToken = "layout-4914"
	var expanded_pending: Dictionary = AGGREGATE.evaluate(expanded_layout, receipts)
	var expanded_receipts: Dictionary = receipts.duplicate(true)
	expanded_receipts[remote_window.id] = _receipt(identity, source_identity,
		remote_window)
	var expanded_ready: Dictionary = AGGREGATE.evaluate(expanded_layout,
		expanded_receipts)
	var edited_layout: Dictionary = layout.duplicate(true)
	edited_layout.identity.sourceRevision = 4
	edited_layout.layoutToken = "layout-distant-edit"
	for window in edited_layout.windows:
		window.localCurrentProof.kind = "verified_native_affected_mesh_exclusion/v1"
		window.localCurrentProof.throughGlobalRevision = 4
		window.localCurrentProof.digest = "native-verified:%s" % window.windowToken
	var retained_ready: Dictionary = AGGREGATE.evaluate(edited_layout, receipts)
	var unproved_layout: Dictionary = edited_layout.duplicate(true)
	unproved_layout.windows[0].localCurrentProof.digest = ""
	var unproved: Dictionary = AGGREGATE.evaluate(unproved_layout, receipts)
	var passed: bool = required.size() == 4913 and windows.size() == 8 \
		and (groups[Vector3i.ZERO] as Array).size() == 4096 \
		and full.get("status") == "ready" \
		and missing.get("status") == "pending" \
		and missing.get("reason") == "collision_window_physics_pending" \
		and stale.get("status") == "pending" \
		and stale.get("reason") == "collision_window_receipt_stale" \
		and duplicate.get("status") == "failed" \
		and duplicate.get("reason") == "collision_window_union_invalid" \
		and expanded_pending.get("status") == "pending" \
		and expanded_ready.get("status") == "ready" \
		and retained_ready.get("status") == "ready" \
		and unproved.get("status") == "pending" \
		and unproved.get("reason") == "collision_window_local_proof_stale"
	var report := {"schema":"n5-window-aggregate-contract/v1",
		"passed":passed, "evidenceLevel":"synthetic aggregate contract",
		"productionCutover":false, "requiredBlockCount":required.size(),
		"windowCount":windows.size(), "largestWindowBlockCount":4096,
		"full":full, "missing":missing, "stale":stale,
		"duplicate":duplicate, "expandedPending":expanded_pending,
		"expandedReady":expanded_ready,
		"retainedAfterVerifiedEdit":retained_ready,
		"unprovedEdit":unproved}
	var path := OS.get_environment("N5_WINDOW_AGGREGATE_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	quit(0 if passed else 1)

func _receipt(identity: Dictionary, source_identity: Dictionary,
		window: Dictionary) -> Dictionary:
	return {"ready":true, "physicsFrame":10,
		"residentBlockCount":window.blocks.size(),
		"residentBlocks":window.blocks.duplicate(),
		"provenance":{"requestIdentity":identity.duplicate(true),
			"sourceIdentity":source_identity.duplicate(true),
			"membershipProvenance":{"authority":"pinned_demand",
				"demandRevision":0, "closureToken":window.closureToken,
				"windowToken":window.windowToken}}}
