extends Node3D
class_name AudioEffectsSystem

const SAMPLE_RATE := 22050
const MAX_VISUAL_EFFECTS := 160
const SFX_POOL_SIZE := 8
const WAV_PATHS := {
    "rainLoop": "res://assets/audio/sfx/rain_loop.wav",
    "woodChop": "res://assets/audio/sfx/wood_chop.wav",
    "knock": "res://assets/audio/sfx/knock.wav",
    "doorOpen": "res://assets/audio/sfx/door_open.wav",
    "doorClose": "res://assets/audio/sfx/door_close.wav",
    "chestOpen": "res://assets/audio/sfx/chest_open.wav",
    "tutorialTownDay": "res://assets/audio/bgm/tutorial_town_day.wav",
    "gameDay2": "res://assets/audio/bgm/game_day_2.wav"
}
const DAYTIME_MUSIC_TRACKS := ["tutorialTownDay", "gameDay2"]
const STREAM_PATHS := {
    "natureDay": "res://assets/audio/sfx/nature_day.mp3",
    "nightWind": "res://assets/audio/sfx/night_wind.mp3"
}

var enabled := true
var player: AudioStreamPlayer
var sfx_players: Array[AudioStreamPlayer] = []
var sfx_cursor := 0
var rain_player: AudioStreamPlayer
var knock_player: AudioStreamPlayer
var music_player: AudioStreamPlayer
var nature_player: AudioStreamPlayer
var night_player: AudioStreamPlayer
var rain_volume_db := -60.0
var rain_target_volume_db := -60.0
var music_volume_db := -60.0
var music_target_volume_db := -60.0
var nature_volume_db := -60.0
var nature_target_volume_db := -60.0
var night_volume_db := -60.0
var night_target_volume_db := -60.0
var ambient_rain_amount := 0.0
var ambient_nature_amount := 0.0
var ambient_night_amount := 0.0
var knock_looping := false
var knock_repeat_timer := 0.0
var current_music := ""
var current_music_source := ""
var streams := {}
var daytime_music_tracks := []
var last_played := ""
var play_count := 0
var visual_effects: Array = []
var visual_effect_pool: Array[MeshInstance3D] = []
var material_cache := {}
var effect_mesh: SphereMesh
var effect_nodes_created := 0
var effect_nodes_reused := 0

func _ready() -> void:
    for i in range(SFX_POOL_SIZE):
        var sfx_player := AudioStreamPlayer.new()
        sfx_player.name = "SfxPlayer_%02d" % i
        add_child(sfx_player)
        sfx_players.append(sfx_player)
    player = sfx_players[0]
    rain_player = AudioStreamPlayer.new()
    rain_player.name = "RainAmbience"
    rain_player.volume_db = rain_volume_db
    add_child(rain_player)
    knock_player = AudioStreamPlayer.new()
    knock_player.name = "IntroDoorKnock"
    knock_player.volume_db = -1.5
    add_child(knock_player)
    music_player = AudioStreamPlayer.new()
    music_player.name = "Music"
    music_player.volume_db = music_volume_db
    add_child(music_player)
    nature_player = AudioStreamPlayer.new()
    nature_player.name = "NatureAmbience"
    nature_player.volume_db = nature_volume_db
    add_child(nature_player)
    night_player = AudioStreamPlayer.new()
    night_player.name = "NightAmbience"
    night_player.volume_db = night_volume_db
    add_child(night_player)
    build_streams()
    if streams.has("rainLoop"):
        rain_player.stream = streams["rainLoop"]
    if streams.has("knock"):
        knock_player.stream = streams["knock"]
    setup_effect_mesh()
    set_process(true)

func _exit_tree() -> void:
    shutdown_audio()

func shutdown_audio() -> void:
    set_process(false)
    knock_looping = false
    knock_repeat_timer = 0.0
    for sfx_player in sfx_players:
        release_audio_player(sfx_player)
    release_audio_player(rain_player)
    release_audio_player(knock_player)
    release_audio_player(music_player)
    release_audio_player(nature_player)
    release_audio_player(night_player)
    streams.clear()
    daytime_music_tracks.clear()
    current_music = ""
    current_music_source = ""
    visual_effects.clear()
    visual_effect_pool.clear()
    material_cache.clear()
    effect_mesh = null

func release_audio_player(audio_player: AudioStreamPlayer) -> void:
    if audio_player == null or not is_instance_valid(audio_player):
        return
    if audio_player.playing:
        audio_player.stop()
    audio_player.stream = null

func build_streams() -> void:
    streams["strike"] = make_tone_stream([150.0], 0.055, "square")
    streams["break"] = make_tone_stream([220.0, 330.0, 480.0], 0.07, "triangle")
    streams["woodChop"] = load_wav_or_fallback("woodChop", make_tone_stream([86.0, 132.0], 0.08, "saw"))
    streams["knock"] = load_wav_or_fallback("knock", make_tone_stream([125.0, 118.0, 132.0], 0.12, "triangle"))
    streams["doorOpen"] = load_wav_or_fallback("doorOpen", make_tone_stream([260.0, 190.0], 0.13, "saw"))
    streams["doorClose"] = load_wav_or_fallback("doorClose", make_tone_stream([150.0, 72.0], 0.11, "triangle"))
    streams["chestOpen"] = load_wav_or_fallback("chestOpen", make_tone_stream([380.0, 205.0], 0.12, "triangle"))
    streams["rainLoop"] = load_wav_or_fallback("rainLoop", make_noise_stream(1.2), true)
    streams["tutorialTownDay"] = load_wav_or_fallback("tutorialTownDay", make_tone_stream([220.0], 0.02, "sine"), true)
    var tutorial_day_stream := streams["tutorialTownDay"] as AudioStreamWAV
    streams["gameDay2"] = load_wav_or_fallback("gameDay2", tutorial_day_stream, true)
    daytime_music_tracks.clear()
    for track in DAYTIME_MUSIC_TRACKS:
        if streams.has(track):
            daytime_music_tracks.append(track)
    if not daytime_music_tracks.is_empty():
        streams["daytime"] = streams[daytime_music_tracks[0]]
    var nature_stream := load_imported_stream("natureDay")
    if nature_stream != null:
        streams["natureDay"] = nature_stream
    var night_stream := load_imported_stream("nightWind")
    if night_stream != null:
        streams["nightWind"] = night_stream
    streams["pickup"] = make_tone_stream([540.0, 760.0], 0.06, "triangle")
    streams["craft"] = make_tone_stream([360.0, 540.0, 720.0], 0.06, "triangle")
    streams["place"] = make_tone_stream([240.0], 0.08, "triangle")
    streams["shoot"] = make_tone_stream([620.0, 340.0], 0.055, "triangle")
    streams["eat"] = make_noise_stream(0.08)
    streams["damage"] = make_tone_stream([82.0, 68.0], 0.10, "saw")
    streams["enemyHit"] = make_tone_stream([112.0], 0.07, "saw")
    streams["defeat"] = make_tone_stream([180.0, 260.0, 420.0, 620.0], 0.075, "triangle")
    streams["level"] = make_tone_stream([330.0, 440.0, 660.0, 880.0], 0.09, "triangle")

func setup_effect_mesh() -> void:
    effect_mesh = SphereMesh.new()
    effect_mesh.radius = 0.065
    effect_mesh.height = 0.095
    effect_mesh.radial_segments = 6
    effect_mesh.rings = 3

func play(name: String) -> void:
    if not enabled or streams.is_empty() or not streams.has(name):
        return
    last_played = name
    play_count += 1
    var sfx_player := acquire_sfx_player()
    if sfx_player == null:
        return
    sfx_player.stream = streams[name]
    sfx_player.pitch_scale = randf_range(0.985, 1.015)
    sfx_player.play()

func acquire_sfx_player() -> AudioStreamPlayer:
    if sfx_players.is_empty():
        return player
    for i in range(sfx_players.size()):
        sfx_cursor = (sfx_cursor + 1) % sfx_players.size()
        var candidate := sfx_players[sfx_cursor]
        if not candidate.playing:
            return candidate
    return sfx_players[sfx_cursor]

func update_weather_ambience(weather: Dictionary) -> void:
    if not enabled or rain_player == null or not streams.has("rainLoop"):
        ambient_rain_amount = 0.0
        rain_target_volume_db = -60.0
        return
    var weather_kind := String(weather.get("kind", "clear"))
    ambient_rain_amount = clampf(float(weather.get("intensity", 0.0)), 0.0, 1.0) if weather_kind == "rain" else 0.0
    if ambient_rain_amount > 0.025:
        rain_target_volume_db = lerpf(-33.0, -10.0, ambient_rain_amount)
        if not rain_player.playing:
            rain_volume_db = -60.0
            rain_player.volume_db = rain_volume_db
            var offset := random_stream_offset(streams["rainLoop"], 0.35)
            rain_player.play(offset)
    else:
        rain_target_volume_db = -60.0

func update_nature_ambience(state: Dictionary) -> void:
    if not enabled or nature_player == null or not streams.has("natureDay"):
        ambient_nature_amount = 0.0
        nature_target_volume_db = -60.0
        return
    ambient_nature_amount = clampf(float(state.get("amount", 0.0)), 0.0, 1.0)
    if ambient_nature_amount > 0.025:
        nature_target_volume_db = clampf(float(state.get("volumeDb", -20.0)), -42.0, -8.0)
        if not nature_player.playing:
            nature_volume_db = -60.0
            nature_player.volume_db = nature_volume_db
            nature_player.stream = streams["natureDay"]
            var offset := random_stream_offset(streams["natureDay"], 0.5)
            nature_player.play(offset)
    else:
        nature_target_volume_db = -60.0

func update_night_ambience(state: Dictionary) -> void:
    if not enabled or night_player == null or not streams.has("nightWind"):
        ambient_night_amount = 0.0
        night_target_volume_db = -60.0
        return
    ambient_night_amount = clampf(float(state.get("amount", 0.0)), 0.0, 1.0)
    if ambient_night_amount > 0.025:
        night_target_volume_db = clampf(float(state.get("volumeDb", -28.0)), -48.0, -14.0)
        if not night_player.playing:
            night_volume_db = -60.0
            night_player.volume_db = night_volume_db
            night_player.stream = streams["nightWind"]
            var offset := random_stream_offset(streams["nightWind"], 0.25)
            night_player.play(offset)
    else:
        night_target_volume_db = -60.0

func update_music(state: Dictionary) -> void:
    var requested := String(state.get("track", ""))
    if not enabled or music_player == null or not streams.has(requested):
        requested = ""
    if requested != current_music:
        current_music = requested
        current_music_source = ""
        if current_music != "":
            music_player.stream = stream_for_music(current_music)
            music_volume_db = -60.0
            music_player.volume_db = music_volume_db
            music_player.play()
    if current_music == "":
        music_target_volume_db = -60.0
    else:
        music_target_volume_db = clampf(float(state.get("volumeDb", -14.0)), -42.0, -5.0)
        if not music_player.playing:
            music_player.play()

func start_knock_loop() -> void:
    if not enabled or knock_player == null or not streams.has("knock"):
        return
    knock_looping = true
    knock_repeat_timer = 0.0
    if not knock_player.playing:
        play_knock_bang()

func stop_knock_loop() -> void:
    knock_looping = false
    knock_repeat_timer = 0.0
    if knock_player and knock_player.playing:
        knock_player.stop()

func play_knock_bang() -> void:
    if knock_player == null or not streams.has("knock"):
        return
    last_played = "knock"
    play_count += 1
    knock_player.stream = streams["knock"]
    knock_player.pitch_scale = randf_range(0.96, 1.04)
    knock_player.play()
    knock_repeat_timer = randf_range(0.32, 0.70)

func burst(position: Vector3, color: Color, count := 8) -> void:
    for i in range(count):
        if visual_effects.size() >= MAX_VISUAL_EFFECTS:
            var stale: Dictionary = visual_effects.pop_front()
            recycle_effect_node(stale)
        var instance := acquire_effect_node(color)
        var base_scale := randf_range(0.72, 1.18)
        instance.global_position = position + Vector3(randf() - 0.5, randf() * 0.3, randf() - 0.5) * 0.35
        instance.scale = Vector3.ONE * base_scale
        visual_effects.append({
            "node": instance,
            "velocity": Vector3(randf() - 0.5, 0.75 + randf() * 1.8, randf() - 0.5) * 2.4,
            "life": 0.55 + randf() * 0.35,
            "max_life": 0.90,
            "base_scale": base_scale
        })

func acquire_effect_node(color: Color) -> MeshInstance3D:
    var instance: MeshInstance3D
    if visual_effect_pool.is_empty():
        instance = MeshInstance3D.new()
        instance.name = "EffectParticle_%03d" % effect_nodes_created
        instance.mesh = effect_mesh
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        add_child(instance)
        effect_nodes_created += 1
    else:
        instance = visual_effect_pool.pop_back()
        effect_nodes_reused += 1
    instance.visible = true
    instance.material_override = material_for(color)
    return instance

func recycle_effect_node(effect: Dictionary) -> void:
    var node := effect.get("node") as MeshInstance3D
    if node == null or not is_instance_valid(node):
        return
    node.visible = false
    node.scale = Vector3.ZERO
    if visual_effect_pool.size() < MAX_VISUAL_EFFECTS:
        visual_effect_pool.append(node)

func _process(delta: float) -> void:
    update_ambient_players(delta)
    update_knock_loop(delta)
    for effect in visual_effects.duplicate():
        var node := effect.get("node") as Node3D
        if node == null or not is_instance_valid(node):
            visual_effects.erase(effect)
            continue
        var velocity: Vector3 = effect.get("velocity", Vector3.ZERO)
        velocity.y -= 5.6 * delta
        node.global_position += velocity * delta
        effect["velocity"] = velocity
        effect["life"] = float(effect.get("life", 0.0)) - delta
        var max_life := maxf(0.01, float(effect.get("max_life", 0.90)))
        var base_scale := float(effect.get("base_scale", 1.0))
        node.scale = Vector3.ONE * base_scale * clampf(float(effect.get("life", 0.0)) / max_life, 0.05, 1.0)
        if float(effect.get("life", 0.0)) <= 0.0:
            recycle_effect_node(effect)
            visual_effects.erase(effect)

func update_ambient_players(delta: float) -> void:
    if rain_player != null:
        rain_volume_db = lerpf(rain_volume_db, rain_target_volume_db, clampf(delta * 3.5, 0.0, 1.0))
        rain_player.volume_db = rain_volume_db
        if rain_target_volume_db <= -59.0 and rain_volume_db <= -58.5 and rain_player.playing:
            rain_player.stop()
    if music_player != null:
        music_volume_db = lerpf(music_volume_db, music_target_volume_db, clampf(delta * 1.4, 0.0, 1.0))
        music_player.volume_db = music_volume_db
        if music_target_volume_db <= -59.0 and music_volume_db <= -58.5 and music_player.playing:
            music_player.stop()
    if nature_player != null:
        nature_volume_db = lerpf(nature_volume_db, nature_target_volume_db, clampf(delta * 2.0, 0.0, 1.0))
        nature_player.volume_db = nature_volume_db
        if nature_target_volume_db <= -59.0 and nature_volume_db <= -58.5 and nature_player.playing:
            nature_player.stop()
    if night_player != null:
        night_volume_db = lerpf(night_volume_db, night_target_volume_db, clampf(delta * 2.0, 0.0, 1.0))
        night_player.volume_db = night_volume_db
        if night_target_volume_db <= -59.0 and night_volume_db <= -58.5 and night_player.playing:
            night_player.stop()

func update_knock_loop(delta: float) -> void:
    if not knock_looping or knock_player == null:
        return
    if knock_player.playing:
        return
    knock_repeat_timer -= delta
    if knock_repeat_timer <= 0.0:
        play_knock_bang()

func stats() -> Dictionary:
    return {
        "lastPlayed": last_played,
        "playCount": play_count,
        "rainAmount": ambient_rain_amount,
        "rainVolumeDb": rain_volume_db,
        "natureAmount": ambient_nature_amount,
        "natureVolumeDb": nature_volume_db,
        "naturePlaying": nature_player.playing if nature_player else false,
        "nightAmount": ambient_night_amount,
        "nightVolumeDb": night_volume_db,
        "nightPlaying": night_player.playing if night_player else false,
        "currentMusic": current_music,
        "currentMusicSource": current_music_source,
        "musicPlaying": music_player.playing if music_player else false,
        "musicVolumeDb": music_volume_db,
        "hasTutorialTownDayBgm": streams.has("tutorialTownDay"),
        "tutorialTownDayBgmLength": streams["tutorialTownDay"].get_length() if streams.has("tutorialTownDay") else 0.0,
        "hasGameDay2Bgm": streams.has("gameDay2"),
        "gameDay2BgmLength": streams["gameDay2"].get_length() if streams.has("gameDay2") else 0.0,
        "daytimeMusicTrackCount": daytime_music_tracks.size(),
        "knockLooping": knock_looping,
        "visualEffects": visual_effects.size(),
        "effectPool": visual_effect_pool.size(),
        "effectNodesCreated": effect_nodes_created,
        "effectNodesReused": effect_nodes_reused
    }

func material_for(color: Color) -> StandardMaterial3D:
    var key := "%0.2f,%0.2f,%0.2f" % [color.r, color.g, color.b]
    if material_cache.has(key):
        return material_cache[key]
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.emission_enabled = true
    material.emission = color.darkened(0.18)
    material.roughness = 0.58
    material_cache[key] = material
    return material

func load_wav_or_fallback(name: String, fallback: AudioStreamWAV, loop := false) -> AudioStreamWAV:
    var path := String(WAV_PATHS.get(name, ""))
    var loaded := load_pcm_wav(path, loop)
    if loaded != null:
        return loaded
    return fallback

func stream_for_music(track: String) -> AudioStream:
    if track == "daytime" and not daytime_music_tracks.is_empty():
        current_music_source = String(daytime_music_tracks.pick_random())
        return streams[current_music_source] as AudioStream
    current_music_source = track
    return streams[track] as AudioStream

func load_imported_stream(name: String) -> AudioStream:
    var path := String(STREAM_PATHS.get(name, ""))
    if path == "":
        return null
    if path.get_extension().to_lower() == "mp3":
        return load_mp3_stream(path)
    var stream := load(path)
    if stream is AudioStream:
        return stream
    return null

func load_mp3_stream(path: String) -> AudioStreamMP3:
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.is_empty():
        return null
    var stream := AudioStreamMP3.new()
    stream.data = bytes
    stream.loop = true
    return stream

func load_pcm_wav(path: String, loop := false) -> AudioStreamWAV:
    if path == "":
        return null
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.size() < 44:
        return null
    if not matches_fourcc(bytes, 0, 82, 73, 70, 70) or not matches_fourcc(bytes, 8, 87, 65, 86, 69):
        return null
    var cursor := 12
    var channels := 0
    var sample_rate := 0
    var bits_per_sample := 0
    var data_offset := -1
    var data_size := 0
    while cursor + 8 <= bytes.size():
        var chunk_size := read_u32_le(bytes, cursor + 4)
        if matches_fourcc(bytes, cursor, 102, 109, 116, 32):
            if cursor + 24 > bytes.size():
                return null
            var audio_format := read_u16_le(bytes, cursor + 8)
            channels = read_u16_le(bytes, cursor + 10)
            sample_rate = read_u32_le(bytes, cursor + 12)
            bits_per_sample = read_u16_le(bytes, cursor + 22)
            if audio_format != 1:
                return null
        elif matches_fourcc(bytes, cursor, 100, 97, 116, 97):
            data_offset = cursor + 8
            data_size = min(chunk_size, bytes.size() - data_offset)
            break
        cursor += 8 + chunk_size + (chunk_size % 2)
    if data_offset < 0 or data_size <= 0 or sample_rate <= 0 or channels < 1 or channels > 2 or bits_per_sample != 16:
        return null
    var data := PackedByteArray()
    data.resize(data_size)
    for i in range(data_size):
        data[i] = bytes[data_offset + i]
    var stream := AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_16_BITS
    stream.mix_rate = sample_rate
    stream.stereo = channels == 2
    stream.data = data
    if loop:
        stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
        stream.loop_begin = 0
        stream.loop_end = int(data_size / (channels * 2))
    return stream

func random_stream_offset(stream: AudioStream, margin := 0.0) -> float:
    if stream == null:
        return 0.0
    var length := stream.get_length()
    if length <= margin * 2.0:
        return 0.0
    return randf_range(margin, length - margin)

func matches_fourcc(bytes: PackedByteArray, offset: int, a: int, b: int, c: int, d: int) -> bool:
    return offset + 3 < bytes.size() and bytes[offset] == a and bytes[offset + 1] == b and bytes[offset + 2] == c and bytes[offset + 3] == d

func read_u16_le(bytes: PackedByteArray, offset: int) -> int:
    if offset + 1 >= bytes.size():
        return 0
    return int(bytes[offset]) | (int(bytes[offset + 1]) << 8)

func read_u32_le(bytes: PackedByteArray, offset: int) -> int:
    if offset + 3 >= bytes.size():
        return 0
    return int(bytes[offset]) | (int(bytes[offset + 1]) << 8) | (int(bytes[offset + 2]) << 16) | (int(bytes[offset + 3]) << 24)

func make_tone_stream(frequencies: Array, segment_duration: float, wave := "sine") -> AudioStreamWAV:
    var sample_count := maxi(1, int(SAMPLE_RATE * segment_duration * frequencies.size()))
    var data := PackedByteArray()
    data.resize(sample_count * 2)
    var sample_index := 0
    for frequency_value in frequencies:
        var frequency := float(frequency_value)
        var segment_samples := maxi(1, int(SAMPLE_RATE * segment_duration))
        for i in range(segment_samples):
            if sample_index >= sample_count:
                break
            var t := float(i) / float(SAMPLE_RATE)
            var env := 1.0 - float(i) / float(segment_samples)
            var value := waveform(frequency, t, wave) * env * 0.28
            write_sample(data, sample_index, value)
            sample_index += 1
    return make_wav(data)

func make_noise_stream(duration: float) -> AudioStreamWAV:
    var sample_count := maxi(1, int(SAMPLE_RATE * duration))
    var data := PackedByteArray()
    data.resize(sample_count * 2)
    for i in range(sample_count):
        var env := 1.0 - float(i) / float(sample_count)
        write_sample(data, i, (randf() * 2.0 - 1.0) * env * 0.20)
    return make_wav(data)

func waveform(frequency: float, t: float, wave: String) -> float:
    var phase := fposmod(t * frequency, 1.0)
    if wave == "square":
        return 1.0 if phase < 0.5 else -1.0
    if wave == "saw":
        return phase * 2.0 - 1.0
    if wave == "triangle":
        return 1.0 - abs(phase * 4.0 - 2.0)
    return sin(TAU * frequency * t)

func write_sample(data: PackedByteArray, sample_index: int, value: float) -> void:
    var sample := clampi(int(value * 32767.0), -32768, 32767)
    if sample < 0:
        sample = 65536 + sample
    var offset := sample_index * 2
    data[offset] = sample & 0xff
    data[offset + 1] = (sample >> 8) & 0xff

func make_wav(data: PackedByteArray) -> AudioStreamWAV:
    var stream := AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_16_BITS
    stream.mix_rate = SAMPLE_RATE
    stream.stereo = false
    stream.data = data
    return stream
