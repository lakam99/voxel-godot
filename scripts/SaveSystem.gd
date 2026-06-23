extends RefCounted
class_name SaveSystem

const SAVE_VERSION := 1
const ACTIVE_SEED_KEY := "__activeSeed"

var path := "user://voxel_biome_world_saves.json"

func _init(path_value := "user://voxel_biome_world_saves.json") -> void:
    path = path_value

func read_all() -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {}
    var text := file.get_as_text()
    file.close()
    var parsed: Variant = JSON.parse_string(text)
    if parsed is Dictionary:
        return parsed
    return {}

func write_all(saves: Dictionary) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return false
    file.store_string(JSON.stringify(saves))
    file.close()
    return true

func load(seed_text: String) -> Dictionary:
    var save: Variant = read_all().get(seed_text, {})
    if not (save is Dictionary):
        return {}
    var save_data: Dictionary = save
    if int(save_data.get("version", 0)) != SAVE_VERSION:
        return {}
    return save_data

func active_seed(fallback := "") -> String:
    var saves := read_all()
    var value := String(saves.get(ACTIVE_SEED_KEY, fallback))
    return value if value != ACTIVE_SEED_KEY else fallback

func set_active_seed(seed_text: String) -> bool:
    if seed_text == "":
        return false
    var saves := read_all()
    saves[ACTIVE_SEED_KEY] = seed_text
    return write_all(saves)

func save(seed_text: String, snapshot: Dictionary) -> bool:
    if seed_text == "" or snapshot.is_empty():
        return false
    var saves := read_all()
    snapshot["seed"] = seed_text
    snapshot["version"] = SAVE_VERSION
    snapshot["savedAtUnix"] = Time.get_unix_time_from_system()
    saves[seed_text] = snapshot
    saves[ACTIVE_SEED_KEY] = seed_text
    return write_all(saves)

func delete(seed_text: String) -> bool:
    var saves := read_all()
    if not saves.has(seed_text):
        return true
    saves.erase(seed_text)
    if String(saves.get(ACTIVE_SEED_KEY, "")) == seed_text:
        saves.erase(ACTIVE_SEED_KEY)
    return write_all(saves)
