extends SceneTree

const TRANSACTION = preload("res://scripts/terrain/NativeTerrainLoadTransaction.gd")
const SOURCE = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const MAIN = preload("res://scripts/MainCore.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const PENDING_PAGES = preload("res://scripts/testing/native_world/PendingPages.gd")

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var started_usec := Time.get_ticks_usec()
	var main = MAIN.new()
	main.seed_text = "native-main-load-transaction-contract"
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {},
		{"regionCells":main.STRUCTURE_REGION_CELLS, "spawnChance":main.STRUCTURE_SPAWN_CHANCE})
	var source: Dictionary = SOURCE.from_main_with_save_volume(main,
		{"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]})
	check(source.get("status") == "ready", "frozen source envelope ready")
	var transaction = TRANSACTION.new()
	var admission = main.structure_system.citadel_terrain_admission
	var policy := {"regionCells":main.STRUCTURE_REGION_CELLS,
		"spawnChance":main.STRUCTURE_SPAWN_CHANCE}
	var backend = ClassDB.instantiate("NativeWorldBackend")
	var initialized: Dictionary = backend.initialize_from_save_v2(source.request)
	check(initialized.get("status") == "ready", "native source initializes")
	var test_pages = PENDING_PAGES.new()
	var held_page := Vector2i(0, 0)
	var begin: Dictionary = transaction.start_backend(backend, admission, held_page)
	test_pages.configure(backend, held_page, 8)
	check(transaction._set_page_adapter_for_test(test_pages),
		"fixture page adapter binds within retained transaction")
	var initial_id := int(transaction.snapshot().get("transactionId", 0))
	check(begin.get("status") == "pending" and initial_id != 0,
		"Main-facing transaction starts pending without a terrain publisher")
	var saw_pending := false
	var became_ready := false
	var max_frame_usec := 0
	for frame in range(8):
		var frame_started := Time.get_ticks_usec()
		var state: Dictionary = transaction.advance()
		max_frame_usec = maxi(max_frame_usec, Time.get_ticks_usec() - frame_started)
		var snapshot: Dictionary = transaction.snapshot()
		check(int(snapshot.get("transactionId", -1)) == initial_id,
			"same transaction instance retained across advances")
		if state.get("status") == "pending": saw_pending = true
		check(state.get("status") == "pending", "held page remains pending")
		await process_frame
	check(saw_pending, "page admission exposed and retained pending state")
	check(transaction.snapshot().get("state") == "pending",
		"transaction instance remains live while page dependency is held")
	# The production admission worker resolves the real native shaping request.
	for frame in range(360):
		var stepped: Dictionary = transaction.advance()
		if stepped.get("status") == "ready":
			became_ready = true
			break
		if stepped.get("status") == "failed": break
		await process_frame
	check(became_ready, "retained native load transaction reaches page ready")
	var ready_snapshot: Dictionary = transaction.snapshot()
	check(int(ready_snapshot.get("backendInstanceId", 0)) != 0
		and ready_snapshot.get("state") == "ready", "ready transaction retains one backend")
	var pending_cancel = TRANSACTION.new()
	# Separate admission with a deterministic held queue request exercises cancel
	# while the native page has not been admitted.
	var cancel_structures = STRUCTURES.new()
	cancel_structures.citadel_terrain_admission.configure(main.seed_text, {}, policy)
	cancel_structures.citadel_terrain_admission.finalize_town_inputs({})
	var cancel_admission = cancel_structures.citadel_terrain_admission
	var cancelled_setup := pending_cancel.start(source.request, cancel_admission,
		Vector2i(0, 0))
	check(cancelled_setup.get("status") == "pending", "second load remains pending for cancel test")
	var cancel_started := Time.get_ticks_usec()
	var cancelled: Dictionary = pending_cancel.cancel()
	var cancel_usec := Time.get_ticks_usec() - cancel_started
	check(cancelled.get("status") == "ready" and cancelled.get("drained") == true
		and pending_cancel.snapshot().get("state") == "drained"
		and int(pending_cancel.snapshot().get("backendInstanceId", -1)) == 0,
		"pending cancellation drains and releases its backend")
	check(pending_cancel.advance().get("status") == "failed",
		"drained cancellation cannot resume the transaction")
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	var report := {"schema":"n3-main-terrain-load-transaction/v1",
		"passed":failures.is_empty(), "productionCutover":false,
		"evidenceLevel":"Main-facing native loading service contract",
		"failures":failures,
		"metrics":{"elapsedUsec":elapsed_usec, "advanceCount":ready_snapshot.get("advanceCount", 0),
			"maxAdvanceUsec":ready_snapshot.get("maxAdvanceUsec", 0),
			"maxFrameWorkUsec":max_frame_usec, "cancelDrainUsec":cancel_usec},
		"identities":{"transactionId":initial_id,
			"sourceIdentity":ready_snapshot.get("sourceIdentity", {}),
			"backendInstanceId":ready_snapshot.get("backendInstanceId", 0)}}
	var path := OS.get_environment("VWB_MAIN_LOAD_TRANSACTION_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	main.free()
	quit(0 if report.passed else 1)
