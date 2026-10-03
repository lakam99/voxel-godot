extends RefCounted
class_name SaveSystem

const SAVE_VERSION := 2
const ACTIVE_SEED_KEY := "__activeSeed"
const SLOT_MAGIC := "VBW2"

var path := "user://voxel_biome_world_saves.bin"
var async_save_thread: Thread = null
var last_async_save_result := {}
# File read and binary decode timing for the most recent slot read.
var last_binary_read_decode_ms := 0.0
var last_binary_file_read_ms := 0.0
var last_binary_encode_write_ms := 0.0
var last_binary_read_bytes := 0
var async_jobs_started := 0
var async_jobs_completed := 0
var async_jobs_failed := 0

func _init(path_value := "user://voxel_biome_world_saves.bin") -> void:
    path = path_value
    _purge_incompatible_saves()

func load(seed_text: String) -> Dictionary:
    poll_async_save(true)
    var slot_save := _read_slot_save(seed_text)
    return slot_save

func active_seed(fallback := "") -> String:
    var active_path := _active_seed_path()
    if FileAccess.file_exists(active_path):
        var file := FileAccess.open(active_path, FileAccess.READ)
        if file != null:
            var value := file.get_as_text().strip_edges()
            file.close()
            if value != "" and value != ACTIVE_SEED_KEY:
                return value
    return fallback

func set_active_seed(seed_text: String) -> bool:
    if seed_text == "":
        return false
    return _write_text_atomic(_active_seed_path(), seed_text)

func save(seed_text: String, snapshot: Dictionary) -> bool:
    if seed_text == "" or snapshot.is_empty():
        return false
    poll_async_save(true)
    var payload := _prepared_snapshot(seed_text, snapshot, true)
    var encode_start := Time.get_ticks_usec()
    var bytes := _encode_snapshot(payload)
    var encode_ms := float(Time.get_ticks_usec() - encode_start) / 1000.0
    var write_start := Time.get_ticks_usec()
    var ok := _write_bytes_atomic(_slot_path(seed_text), bytes)
    if ok:
        ok = set_active_seed(seed_text)
    last_binary_encode_write_ms = encode_ms + float(Time.get_ticks_usec() - write_start) / 1000.0
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
    last_binary_encode_write_ms = float(last_async_save_result.get("encodeWriteMs", last_binary_encode_write_ms))
    return last_async_save_result.duplicate(true)

func has_async_save_pending() -> bool:
    return async_save_thread != null and async_save_thread.is_alive()

func delete(seed_text: String) -> bool:
    poll_async_save(true)
    var removed_slot := _remove_path(_slot_path(seed_text))
    _remove_path(_legacy_slot_path(seed_text))
    if active_seed("") == seed_text:
        _remove_path(_active_seed_path())
    return removed_slot

func stats() -> Dictionary:
    return {
        "asyncPending": has_async_save_pending(),
        "asyncStarted": async_jobs_started,
        "asyncCompleted": async_jobs_completed,
        "asyncFailed": async_jobs_failed,
        "lastReadParseMs": last_binary_read_decode_ms + last_binary_file_read_ms,
        "lastReadFileMs": last_binary_file_read_ms,
        "lastBinaryDecodeMs": last_binary_read_decode_ms,
        "lastReadBytes": last_binary_read_bytes,
        "lastEncodeWriteMs": last_binary_encode_write_ms,
        "lastBinaryEncodeWriteMs": last_binary_encode_write_ms,
        "lastAsync": last_async_save_result.duplicate(true)
    }

func _read_binary_file(read_path: String) -> Dictionary:
    last_binary_file_read_ms = 0.0
    last_binary_read_decode_ms = 0.0
    last_binary_read_bytes = 0
    if not FileAccess.file_exists(read_path):
        return {}
    var file := FileAccess.open(read_path, FileAccess.READ)
    if file == null: return {}
    last_binary_read_bytes = file.get_length()
    var file_read_started := Time.get_ticks_usec()
    var bytes := file.get_buffer(last_binary_read_bytes)
    file.close()
    last_binary_file_read_ms = float(Time.get_ticks_usec() - file_read_started) / 1000.0
    var magic := SLOT_MAGIC.to_utf8_buffer()
    if bytes.size() <= magic.size(): return {}
    for index in range(magic.size()):
        if bytes[index] != magic[index]: return {}
    var payload_bytes := PackedByteArray()
    for index in range(magic.size(), bytes.size()):
        payload_bytes.append(bytes[index])
    var decode_started := Time.get_ticks_usec()
    var decoded: Variant = bytes_to_var(payload_bytes)
    last_binary_read_decode_ms = float(Time.get_ticks_usec() - decode_started) / 1000.0
    return _validated_save(decoded)

func _read_slot_save(seed_text: String) -> Dictionary:
    var save := _read_binary_file(_slot_path(seed_text))
    if not save.is_empty() and String(save.get("seed", "")) != seed_text:
        return {}
    return save

func _validated_save(save) -> Dictionary:
    if not (save is Dictionary):
        return {}
    var save_data: Dictionary = save
    if int(save_data.get("version", 0)) != SAVE_VERSION:
        return {}
    return save_data

func _purge_incompatible_saves() -> void:
    _purge_legacy_json_saves()
    _purge_incompatible_slot_saves()
    var active_path := _active_seed_path()
    _remove_path("%s.tmp" % active_path)
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
    var stem := _save_stem()
    var slot_prefix := "%s_slot_" % stem.get_file()
    directory.list_dir_begin()
    var entry_name := directory.get_next()
    while entry_name != "":
        if not directory.current_is_dir() and entry_name.begins_with(slot_prefix) and entry_name.ends_with(".bin.tmp"):
            _remove_path(directory_path.path_join(entry_name))
        elif not directory.current_is_dir() and entry_name.begins_with(slot_prefix) and entry_name.ends_with(".bin"):
            var candidate_path := directory_path.path_join(entry_name)
            var candidate := _read_binary_file(candidate_path)
            if candidate.is_empty():
                _remove_path(candidate_path)
        entry_name = directory.get_next()
    directory.list_dir_end()

func _purge_legacy_json_saves() -> void:
    _remove_path(_save_stem() + ".json")
    _remove_path(_save_stem() + ".json.tmp")
    var directory_path := path.get_base_dir()
    var directory := DirAccess.open(directory_path)
    if directory == null: return
    var slot_prefix := "%s_slot_" % _save_stem().get_file()
    directory.list_dir_begin()
    var entry_name := directory.get_next()
    while entry_name != "":
        if not directory.current_is_dir() and entry_name.begins_with(slot_prefix) \
                and (entry_name.ends_with(".json") or entry_name.ends_with(".json.tmp")):
            _remove_path(directory_path.path_join(entry_name))
        entry_name = directory.get_next()
    directory.list_dir_end()

func _prepared_snapshot(seed_text: String, snapshot: Dictionary, deep := true) -> Dictionary:
    var payload := snapshot.duplicate(deep)
    payload["seed"] = seed_text
    payload["version"] = SAVE_VERSION
    payload["savedAtUnix"] = Time.get_unix_time_from_system()
    return payload

func _thread_write_slot_save(job: Dictionary) -> Dictionary:
    var encode_start := Time.get_ticks_usec()
    var bytes := _encode_snapshot(job.get("snapshot", {}))
    var encode_ms := float(Time.get_ticks_usec() - encode_start) / 1000.0
    var write_start := Time.get_ticks_usec()
    var ok := _write_bytes_atomic(String(job.get("slotPath", "")), bytes)
    if ok:
        ok = _write_text_atomic(String(job.get("activeSeedPath", "")), String(job.get("seed", "")))
    var write_ms := float(Time.get_ticks_usec() - write_start) / 1000.0
    return {
        "ok": ok,
        "seed": String(job.get("seed", "")),
        "encodeMs": encode_ms,
        "writeMs": write_ms,
        "encodeWriteMs": encode_ms + write_ms
    }

func _slot_path(seed_text: String) -> String:
    var safe_seed := _safe_seed_component(seed_text)
    return "%s_slot_%s.bin" % [_save_stem(), safe_seed]

func _legacy_slot_path(seed_text: String) -> String:
    return "%s_slot_%s.json" % [_save_stem(), _safe_seed_component(seed_text)]

func _save_stem() -> String:
    if path.ends_with(".json") or path.ends_with(".bin"):
        return path.substr(0, path.length() - 5)
    return path

func _active_seed_path() -> String:
    return "%s_active_seed.txt" % _save_stem()

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

func _encode_snapshot(snapshot: Variant) -> PackedByteArray:
    var bytes := SLOT_MAGIC.to_utf8_buffer()
    bytes.append_array(var_to_bytes(snapshot))
    return bytes

func _write_bytes_atomic(target_path: String, bytes: PackedByteArray) -> bool:
    if target_path == "": return false
    var temp_path := "%s.tmp" % target_path
    _ensure_parent_dir(target_path)
    _remove_path(temp_path)
    var file := FileAccess.open(temp_path, FileAccess.WRITE)
    if file == null: return false
    file.store_buffer(bytes)
    file.close()
    var absolute_temp := ProjectSettings.globalize_path(temp_path)
    var absolute_target := ProjectSettings.globalize_path(target_path)
    var err := DirAccess.rename_absolute(absolute_temp, absolute_target)
    if err == OK: return true
    if FileAccess.file_exists(target_path): DirAccess.remove_absolute(absolute_target)
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
