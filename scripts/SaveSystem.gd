extends RefCounted
class_name SaveSystem

const SAVE_VERSION := 2
const ACTIVE_SEED_KEY := "__activeSeed"

var path := "user://voxel_biome_world_saves.json"
var async_save_thread: Thread = null
var last_async_save_result := {}
var last_json_read_parse_ms := 0.0
var last_json_stringify_write_ms := 0.0
var async_jobs_started := 0
var async_jobs_completed := 0
var async_jobs_failed := 0

func _init(path_value := "user://voxel_biome_world_saves.json") -> void:
    path = path_value
    _purge_incompatible_saves()

func read_all() -> Dictionary:
    return _read_json_file(path)

func write_all(saves: Dictionary) -> bool:
    var stringify_start := Time.get_ticks_usec()
    var text := JSON.stringify(saves)
    var stringify_ms := float(Time.get_ticks_usec() - stringify_start) / 1000.0
    var write_start := Time.get_ticks_usec()
    var ok := _write_text_atomic(path, text)
    last_json_stringify_write_ms = stringify_ms + float(Time.get_ticks_usec() - write_start) / 1000.0
    return ok

func load(seed_text: String) -> Dictionary:
    poll_async_save(true)
    var slot_save := _read_slot_save(seed_text)
    if not slot_save.is_empty():
        return slot_save
    var save: Variant = read_all().get(seed_text, {})
    return _validated_save(save)

func active_seed(fallback := "") -> String:
    var active_path := _active_seed_path()
    if FileAccess.file_exists(active_path):
        var file := FileAccess.open(active_path, FileAccess.READ)
        if file != null:
            var value := file.get_as_text().strip_edges()
            file.close()
            if value != "" and value != ACTIVE_SEED_KEY:
                return value
    var saves := read_all()
    var value := String(saves.get(ACTIVE_SEED_KEY, fallback))
    return value if value != ACTIVE_SEED_KEY else fallback

func set_active_seed(seed_text: String) -> bool:
    if seed_text == "":
        return false
    return _write_text_atomic(_active_seed_path(), seed_text)

func save(seed_text: String, snapshot: Dictionary) -> bool:
    if seed_text == "" or snapshot.is_empty():
        return false
    poll_async_save(true)
    var payload := _prepared_snapshot(seed_text, snapshot, true)
    var stringify_start := Time.get_ticks_usec()
    var text := JSON.stringify(payload)
    var stringify_ms := float(Time.get_ticks_usec() - stringify_start) / 1000.0
    var write_start := Time.get_ticks_usec()
    var ok := _write_text_atomic(_slot_path(seed_text), text)
    if ok:
        ok = set_active_seed(seed_text)
    last_json_stringify_write_ms = stringify_ms + float(Time.get_ticks_usec() - write_start) / 1000.0
    return ok

func save_async(seed_text: String, snapshot: Dictionary) -> bool:
    if seed_text == "" or snapshot.is_empty():
        return false
    poll_async_save(false)
    if has_async_save_pending():
        return false
    var payload := _prepared_snapshot(seed_text, snapshot, false)
    var job := {
        "seed": seed_text,
        "slotPath": _slot_path(seed_text),
        "activeSeedPath": _active_seed_path(),
        "snapshot": payload
    }
    async_save_thread = Thread.new()
    var err := async_save_thread.start(Callable(self, "_thread_write_slot_save").bind(job))
    if err != OK:
        async_save_thread = null
        return false
    async_jobs_started += 1
    return true

func poll_async_save(wait := false) -> Dictionary:
    if async_save_thread == null:
        return {}
    if not wait and async_save_thread.is_alive():
        return {}
    var result = async_save_thread.wait_to_finish()
    async_save_thread = null
    last_async_save_result = result if result is Dictionary else { "ok": false, "reason": "missing_thread_result" }
    async_jobs_completed += 1
    if not bool(last_async_save_result.get("ok", false)):
        async_jobs_failed += 1
    last_json_stringify_write_ms = float(last_async_save_result.get("stringifyWriteMs", last_json_stringify_write_ms))
    return last_async_save_result.duplicate(true)

func has_async_save_pending() -> bool:
    return async_save_thread != null and async_save_thread.is_alive()

func delete(seed_text: String) -> bool:
    poll_async_save(true)
    var removed_slot := _remove_path(_slot_path(seed_text))
    var legacy_changed := false
    var saves := read_all()
    if saves.has(seed_text):
        saves.erase(seed_text)
        legacy_changed = true
    if String(saves.get(ACTIVE_SEED_KEY, "")) == seed_text:
        saves.erase(ACTIVE_SEED_KEY)
        legacy_changed = true
    var legacy_ok := true
    if legacy_changed:
        legacy_ok = write_all(saves)
    if active_seed("") == seed_text:
        _remove_path(_active_seed_path())
    return removed_slot and legacy_ok

func stats() -> Dictionary:
    return {
        "asyncPending": has_async_save_pending(),
        "asyncStarted": async_jobs_started,
        "asyncCompleted": async_jobs_completed,
        "asyncFailed": async_jobs_failed,
        "lastReadParseMs": last_json_read_parse_ms,
        "lastStringifyWriteMs": last_json_stringify_write_ms,
        "lastAsync": last_async_save_result.duplicate(true)
    }

func _read_json_file(read_path: String) -> Dictionary:
    var started := Time.get_ticks_usec()
    if not FileAccess.file_exists(read_path):
        last_json_read_parse_ms = float(Time.get_ticks_usec() - started) / 1000.0
        return {}
    var file := FileAccess.open(read_path, FileAccess.READ)
    if file == null:
        last_json_read_parse_ms = float(Time.get_ticks_usec() - started) / 1000.0
        return {}
    var text := file.get_as_text()
    file.close()
    var parsed: Variant = JSON.parse_string(text)
    last_json_read_parse_ms = float(Time.get_ticks_usec() - started) / 1000.0
    if parsed is Dictionary:
        return parsed
    return {}

func _read_slot_save(seed_text: String) -> Dictionary:
    return _validated_save(_read_json_file(_slot_path(seed_text)))

func _validated_save(save) -> Dictionary:
    if not (save is Dictionary):
        return {}
    var save_data: Dictionary = save
    if int(save_data.get("version", 0)) != SAVE_VERSION:
        return {}
    return save_data

func _purge_incompatible_saves() -> void:
    var saves := read_all()
    var changed := false
    var active_seed := String(saves.get(ACTIVE_SEED_KEY, ""))
    for key_value in saves.keys():
        var key := String(key_value)
        if key == ACTIVE_SEED_KEY:
            continue
        if _validated_save(saves[key]).is_empty():
            saves.erase(key)
            changed = true
    if active_seed != "" and (_read_slot_save(active_seed).is_empty() and _validated_save(saves.get(active_seed, {})).is_empty()):
        saves.erase(ACTIVE_SEED_KEY)
        changed = true
    if changed:
        write_all(saves)
    _purge_incompatible_slot_saves()
    var active_path := _active_seed_path()
    if FileAccess.file_exists(active_path):
        var file := FileAccess.open(active_path, FileAccess.READ)
        var active_value := ""
        if file != null:
            active_value = file.get_as_text().strip_edges()
            file.close()
        if active_value == "" or _read_slot_save(active_value).is_empty():
            _remove_path(active_path)

func _purge_incompatible_slot_saves() -> void:
    var directory_path := path.get_base_dir()
    var directory := DirAccess.open(directory_path)
    if directory == null:
        return
    var file_name := path.get_file()
    var stem := file_name.substr(0, file_name.length() - 5) if file_name.ends_with(".json") else file_name
    var slot_prefix := "%s_slot_" % stem
    directory.list_dir_begin()
    var entry_name := directory.get_next()
    while entry_name != "":
        if not directory.current_is_dir() and entry_name.begins_with(slot_prefix) and entry_name.ends_with(".json"):
            var candidate_path := directory_path.path_join(entry_name)
            if _validated_save(_read_json_file(candidate_path)).is_empty():
                _remove_path(candidate_path)
        entry_name = directory.get_next()
    directory.list_dir_end()

func _prepared_snapshot(seed_text: String, snapshot: Dictionary, deep := true) -> Dictionary:
    var payload := snapshot.duplicate(deep)
    payload["seed"] = seed_text
    payload["version"] = SAVE_VERSION
    payload["savedAtUnix"] = Time.get_unix_time_from_system()
    return payload

func _thread_write_slot_save(job: Dictionary) -> Dictionary:
    var stringify_start := Time.get_ticks_usec()
    var text := JSON.stringify(job.get("snapshot", {}))
    var stringify_ms := float(Time.get_ticks_usec() - stringify_start) / 1000.0
    var write_start := Time.get_ticks_usec()
    var ok := _write_text_atomic(String(job.get("slotPath", "")), text)
    if ok:
        ok = _write_text_atomic(String(job.get("activeSeedPath", "")), String(job.get("seed", "")))
    var write_ms := float(Time.get_ticks_usec() - write_start) / 1000.0
    return {
        "ok": ok,
        "seed": String(job.get("seed", "")),
        "stringifyMs": stringify_ms,
        "writeMs": write_ms,
        "stringifyWriteMs": stringify_ms + write_ms
    }

func _slot_path(seed_text: String) -> String:
    var safe_seed := _safe_seed_component(seed_text)
    if path.ends_with(".json"):
        return "%s_slot_%s.json" % [path.substr(0, path.length() - 5), safe_seed]
    return "%s_slot_%s.json" % [path, safe_seed]

func _active_seed_path() -> String:
    if path.ends_with(".json"):
        return "%s_active_seed.txt" % path.substr(0, path.length() - 5)
    return "%s_active_seed.txt" % path

func _safe_seed_component(seed_text: String) -> String:
    var result := seed_text.strip_edges()
    for needle in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", " ", "."]:
        result = result.replace(needle, "_")
    if result == "":
        result = "default"
    return result

func _write_text_atomic(target_path: String, text: String) -> bool:
    if target_path == "":
        return false
    var temp_path := "%s.tmp" % target_path
    _ensure_parent_dir(target_path)
    _remove_path(temp_path)
    var file := FileAccess.open(temp_path, FileAccess.WRITE)
    if file == null:
        return false
    file.store_string(text)
    file.close()
    var absolute_temp := ProjectSettings.globalize_path(temp_path)
    var absolute_target := ProjectSettings.globalize_path(target_path)
    var err := DirAccess.rename_absolute(absolute_temp, absolute_target)
    if err == OK:
        return true
    if FileAccess.file_exists(target_path):
        DirAccess.remove_absolute(absolute_target)
    err = DirAccess.rename_absolute(absolute_temp, absolute_target)
    return err == OK

func _remove_path(remove_path: String) -> bool:
    if remove_path == "":
        return false
    if not FileAccess.file_exists(remove_path):
        return true
    return DirAccess.remove_absolute(ProjectSettings.globalize_path(remove_path)) == OK

func _ensure_parent_dir(target_path: String) -> void:
    var absolute_path := ProjectSettings.globalize_path(target_path)
    var directory := absolute_path.get_base_dir()
    if directory != "":
        DirAccess.make_dir_recursive_absolute(directory)
