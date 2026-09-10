extends RefCounted
class_name RuntimePerformanceMonitor

const WINDOW_SECONDS := 10.0
const SPIKE_THRESHOLD_MS := 33.0
const MAX_FRAME_SAMPLES := 900

var clock_seconds := 0.0
var frame_start_usec := 0
var in_frame := false
var frame_sections := {}
var frame_counters := {}
var last_frame_sections := {}
var last_frame_counters := {}
var last_section_ms := {}
var max_section_ms := {}
var counters := {}
var frame_samples := []
var last_frame_ms := 0.0
var last_spike := {}

func reset() -> void:
    frame_start_usec = 0
    in_frame = false
    frame_sections = {}
    frame_counters = {}
    last_frame_sections = {}
    last_frame_counters = {}
    last_section_ms = {}
    max_section_ms = {}
    counters = {}
    frame_samples = []
    last_frame_ms = 0.0
    last_spike = {}

func begin_frame(delta: float) -> void:
    clock_seconds += maxf(0.0, delta)
    frame_start_usec = Time.get_ticks_usec()
    in_frame = true
    frame_sections = {}
    frame_counters = {}

func end_frame() -> float:
    if not in_frame:
        return last_frame_ms
    last_frame_ms = _duration_ms(frame_start_usec)
    last_frame_sections = frame_sections.duplicate(true)
    last_frame_counters = frame_counters.duplicate(true)
    _push_frame_sample(last_frame_ms, last_frame_sections, last_frame_counters)
    if last_frame_ms >= SPIKE_THRESHOLD_MS:
        _record_spike(last_frame_ms, last_frame_sections)
    in_frame = false
    return last_frame_ms

func begin_section(_name: String) -> int:
    return Time.get_ticks_usec()

func end_section(name: String, start_usec: int) -> float:
    var duration := _duration_ms(start_usec)
    observe_duration(name, duration)
    return duration

func observe_duration(name: String, duration_ms: float) -> float:
    if name == "":
        return duration_ms
    last_section_ms[name] = duration_ms
    max_section_ms[name] = maxf(float(max_section_ms.get(name, 0.0)), duration_ms)
    if in_frame:
        frame_sections[name] = float(frame_sections.get(name, 0.0)) + duration_ms
    return duration_ms

func observe_external_duration(name: String, duration_ms: float) -> float:
    if name == "":
        return duration_ms
    last_section_ms[name] = duration_ms
    max_section_ms[name] = maxf(float(max_section_ms.get(name, 0.0)), duration_ms)
    return duration_ms

func increment_counter(name: String, amount := 1) -> void:
    if name == "":
        return
    counters[name] = int(counters.get(name, 0)) + amount
    if in_frame:
        frame_counters[name] = int(frame_counters.get(name, 0)) + amount

func summary() -> Dictionary:
    var values := []
    for sample in frame_samples:
        values.append(float((sample as Dictionary).get("ms", 0.0)))
    return {
        "frameMetricScope": "Main game script _process callback only; excludes rendering, physics and other nodes. Not total frame latency.",
        "frameMs": last_frame_ms,
        "frameP50Ms": _percentile(values, 0.50),
        "frameP95Ms": _percentile(values, 0.95),
        "frameP99Ms": _percentile(values, 0.99),
        "frameMaxMs": _max_value(values),
        "lastSpikeReason": String(last_spike.get("reason", "")),
        "lastSpikeFrameMs": float(last_spike.get("frameMs", 0.0)),
        "lastSpikeTopSections": last_spike.get("topSections", []),
        "sections": last_section_ms.duplicate(true),
        "sectionMaxMs": max_section_ms.duplicate(true),
        "lastFrameSections": last_frame_sections.duplicate(true),
        "counters": counters.duplicate(true),
        "lastFrameCounters": last_frame_counters.duplicate(true),
        "sampleCount": frame_samples.size()
    }

func section_ms(name: String) -> float:
    return float(last_section_ms.get(name, 0.0))

func section_max_ms(name: String) -> float:
    return float(max_section_ms.get(name, 0.0))

func counter_value(name: String) -> int:
    return int(counters.get(name, 0))

func _duration_ms(start_usec: int) -> float:
    return float(Time.get_ticks_usec() - start_usec) / 1000.0

func _push_frame_sample(frame_ms: float, sections: Dictionary, frame_counter_snapshot: Dictionary) -> void:
    frame_samples.append({
        "time": clock_seconds,
        "ms": frame_ms,
        "sections": sections.duplicate(true),
        "counters": frame_counter_snapshot.duplicate(true)
    })
    while frame_samples.size() > MAX_FRAME_SAMPLES:
        frame_samples.pop_front()
    while not frame_samples.is_empty() and clock_seconds - float((frame_samples[0] as Dictionary).get("time", 0.0)) > WINDOW_SECONDS:
        frame_samples.pop_front()

func _record_spike(frame_ms: float, sections: Dictionary) -> void:
    var top := _top_sections(sections, 12)
    var reason := "frame"
    if not top.is_empty():
        reason = String((top[0] as Dictionary).get("name", "frame"))
    last_spike = {
        "time": clock_seconds,
        "frameMs": frame_ms,
        "reason": reason,
        "topSections": top
    }

func _top_sections(sections: Dictionary, limit: int) -> Array:
    var rows := []
    for key in sections.keys():
        rows.append({
            "name": String(key),
            "ms": float(sections[key])
        })
    rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a.get("ms", 0.0)) > float(b.get("ms", 0.0))
    )
    var result := []
    for index in range(mini(limit, rows.size())):
        result.append(rows[index])
    return result

func _percentile(values: Array, ratio: float) -> float:
    if values.is_empty():
        return 0.0
    var sorted := values.duplicate()
    sorted.sort()
    var index := clampi(ceili(float(sorted.size()) * ratio) - 1, 0, sorted.size() - 1)
    return float(sorted[index])

func _max_value(values: Array) -> float:
    var result := 0.0
    for value in values:
        result = maxf(result, float(value))
    return result
