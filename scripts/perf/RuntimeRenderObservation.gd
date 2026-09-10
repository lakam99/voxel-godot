extends Node
## Opt-in observer owned by a playtest. Never changes generation or gameplay.
## Cadence is time between RenderingServer updates, not display presentation.
const MAX_PHASES := 32
const BIN_MS := 0.1
const LAST_BIN := 10000

class Distribution extends RefCounted:
	var bins := PackedInt64Array()
	var count := 0
	var total := 0.0
	var maximum := 0.0
	var over_33 := 0
	var over_100 := 0
	func _init() -> void:
		bins.resize(LAST_BIN + 1)
	func observe(value: float) -> void:
		if not is_finite(value) or value < 0.0: return
		count += 1
		total += value
		maximum = maxf(maximum, value)
		if value > 33.0: over_33 += 1
		if value > 100.0: over_100 += 1
		bins[mini(LAST_BIN, ceili(value / BIN_MS))] += 1
	func percentile(ratio: float) -> Variant:
		if count == 0: return null
		var wanted := ceili(count * ratio)
		var accumulated := 0
		for index in bins.size():
			accumulated += bins[index]
			if accumulated >= wanted:
				# Overflow cannot honestly report a bounded percentile.
				return null if index == LAST_BIN else index * BIN_MS
		return null
	func summary() -> Dictionary:
		return {"samples":count, "meanMs":total / count if count > 0 else null,
			"p50Ms":percentile(0.50), "p95Ms":percentile(0.95), "p99Ms":percentile(0.99),
			"maxMs":maximum if count > 0 else null, "over33ms":over_33,
			"over100ms":over_100, "overflowSamples":bins[LAST_BIN]}

var phase := "startup"
var _viewport: WeakRef
var _phases: Dictionary = {}
var _last_draw_usec := 0
var _last_phase := ""
var _draws := 0
var _running := false
var _available := false
var _observer_cpu_usec := 0
var _observer_max_usec := 0
var _size := Vector2i.ZERO
var _observed_size := Vector2i.ZERO
var _size_changes := 0
var _render_target_size := Vector2i.ZERO
var _render_scale := 0.0
var _render_configuration_changes := 0
var _renderer := ""
var _overall_cadence := Distribution.new()
var _boundary_cadence := Distribution.new()

func start(viewport: Viewport) -> bool:
	if _running or not is_instance_valid(viewport): return false
	_viewport = weakref(viewport)
	_size = Vector2i(viewport.get_visible_rect().size)
	_renderer = RenderingServer.get_current_rendering_method()
	_available = DisplayServer.get_name() != "headless"
	if not _available: return false
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
	RenderingServer.frame_post_draw.connect(_after_draw)
	_running = true
	return true

func _after_draw() -> void:
	var now := Time.get_ticks_usec()
	var viewport = _viewport.get_ref() if _viewport != null else null
	if not is_instance_valid(viewport):
		stop()
		return
	_draws += 1
	var current_size := Vector2i(viewport.get_visible_rect().size)
	if _draws > 1 and current_size != _observed_size: _size_changes += 1
	_observed_size = current_size
	# Window texture.get_size() applies canvas stretch again in Godot 4.6.1:
	# a 1920x1080 window with 1280x720 UI reports 2880x1620, while get_image()
	# correctly returns 1920x1080. Use the actual window/subviewport dimensions.
	var output_size: Vector2i = viewport.size if viewport is Window or viewport is SubViewport else Vector2i.ZERO
	var scale_3d: float = viewport.scaling_3d_scale
	if _draws > 1 and (output_size != _render_target_size or scale_3d != _render_scale):
		_render_configuration_changes += 1
	_render_target_size = output_size
	_render_scale = scale_3d
	var label := phase if _phases.has(phase) or _phases.size() < MAX_PHASES else "overflow"
	if not _phases.has(label):
		_phases[label] = {"cadence":Distribution.new(), "renderCpu":Distribution.new(),
			"renderGpu":Distribution.new(), "frameSetupCpu":Distribution.new(),
			"drawCallsMax":0, "primitivesMax":0, "shadowDrawCallsMax":0,
			"shadowPrimitivesMax":0, "renderSamples":0, "gpuUnavailableSamples":0,
			"staticMemoryMaxBytes":0,
			"firstUsec":now, "lastUsec":now}
	var bucket: Dictionary = _phases[label]
	bucket.staticMemoryMaxBytes = maxi(bucket.staticMemoryMaxBytes,int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	bucket.lastUsec = now
	if _last_draw_usec > 0:
		var interval_ms := float(now - _last_draw_usec) / 1000.0
		_overall_cadence.observe(interval_ms)
		if _last_phase != label: _boundary_cadence.observe(interval_ms)
	# Do not attribute the interval spanning a phase transition to either phase.
	if _last_draw_usec > 0 and _last_phase == label:
		bucket.cadence.observe(float(now - _last_draw_usec) / 1000.0)
	_last_draw_usec = now
	_last_phase = label
	if _draws > 2:
		var rid: RID = viewport.get_viewport_rid()
		var cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid)
		var gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
		bucket.renderCpu.observe(cpu)
		if gpu > 0.0: bucket.renderGpu.observe(gpu)
		else: bucket.gpuUnavailableSamples += 1
		bucket.frameSetupCpu.observe(RenderingServer.get_frame_setup_time_cpu())
		bucket.renderSamples += 1
		bucket.drawCallsMax = maxi(bucket.drawCallsMax, RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME))
		bucket.primitivesMax = maxi(bucket.primitivesMax, RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME))
		bucket.shadowDrawCallsMax = maxi(bucket.shadowDrawCallsMax, RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME))
		bucket.shadowPrimitivesMax = maxi(bucket.shadowPrimitivesMax, RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME))
	var elapsed := Time.get_ticks_usec() - now
	_observer_cpu_usec += elapsed
	_observer_max_usec = maxi(_observer_max_usec, elapsed)

func summary() -> Dictionary:
	var result: Dictionary = {}
	for label in _phases:
		var bucket: Dictionary = _phases[label]
		result[label] = {"cadence":bucket.cadence.summary(), "renderCpu":bucket.renderCpu.summary(),
			"renderGpu":bucket.renderGpu.summary(), "frameSetupCpu":bucket.frameSetupCpu.summary(),
			"drawCallsMax":bucket.drawCallsMax, "primitivesMax":bucket.primitivesMax,
			"shadowDrawCallsMax":bucket.shadowDrawCallsMax, "shadowPrimitivesMax":bucket.shadowPrimitivesMax,
			"renderSamples":bucket.renderSamples, "gpuUnavailableSamples":bucket.gpuUnavailableSamples,
			"staticMemoryMaxBytes":bucket.staticMemoryMaxBytes if bucket.staticMemoryMaxBytes>0 else null,
			"observedSpanMs":float(bucket.lastUsec-bucket.firstUsec)/1000.0}
	return {"schema":"runtime_render_observation/v1", "available":_available,
		"initialViewportSize":[_size.x,_size.y], "viewportSize":[_observed_size.x,_observed_size.y],
		"viewportSizeChanges":_size_changes, "renderer":_renderer,
		"renderTargetSize":[_render_target_size.x,_render_target_size.y], "renderScale3D":_render_scale,
		"renderConfigurationChanges":_render_configuration_changes,
		"sizeScope":"Viewport size is logical UI coordinates; renderTargetSize is the window/subviewport output size before scaling_3d_scale.",
		"overallCadence":_overall_cadence.summary(), "phaseBoundaryCadence":_boundary_cadence.summary(),
		"cadenceScope":"Monotonic intervals between frame_post_draw callbacks; not OS presentation timing. Phase-boundary intervals included overall and excluded only from individual phases.",
		"renderScope":"Last available root-viewport CPU/GPU measurements; GPU results may be delayed. Not frame-aligned with script or cadence samples. Frame setup CPU reported separately.",
		"percentileResolutionMs":BIN_MS, "percentileOverflowAtMs":LAST_BIN*BIN_MS,
		"observerCpuUsec":_observer_cpu_usec, "observerMaxUsec":_observer_max_usec,
		"phases":result}

func stop() -> void:
	if not _running: return
	_running = false
	if RenderingServer.frame_post_draw.is_connected(_after_draw):
		RenderingServer.frame_post_draw.disconnect(_after_draw)
	var viewport = _viewport.get_ref() if _viewport != null else null
	if is_instance_valid(viewport):
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), false)
	_viewport = null

func _exit_tree() -> void:
	stop()
