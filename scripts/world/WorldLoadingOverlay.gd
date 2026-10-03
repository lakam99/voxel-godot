extends CanvasLayer

# The same opaque loading presentation as the HUD, available before world or
# inventory setup. Main owns readiness; this component only displays progress.
const PanelBuilder := preload("res://scripts/GameHudPanelBuilder.gd")
const GAME_THEME := preload("res://resources/ui/game_theme.tres")
var loading_overlay: Control
var loading_label: Label
var loading_progress_bar: ProgressBar
var loading_elapsed := 0.0
var loading_base_message := "Preparing world"

func _ready() -> void:
	layer = 9 # The title menu remains above this during menu-driven startup.
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = GAME_THEME
	add_child(root)
	PanelBuilder.build_loading_overlay(self, root)
	loading_overlay.show()
	loading_elapsed = 0.0
	set_message("Preparing world")

func _process(delta: float) -> void:
	if loading_overlay == null or not loading_overlay.visible or loading_label == null:
		return
	loading_elapsed += maxf(delta, 0.0)
	var seconds := int(loading_elapsed)
	var dots := ".".repeat(int(floor(loading_elapsed * 2.0)) % 4)
	loading_label.text = "%s%s · %02d:%02d" % [loading_base_message, dots, seconds / 60, seconds % 60]

func set_message(message: String) -> void:
	loading_base_message = message
	if loading_label != null:
		loading_label.text = message
	if loading_progress_bar != null:
		loading_progress_bar.visible = false

func set_progress(message: String, completed: int, total: int) -> void:
	set_message(message)
	if loading_progress_bar == null or not is_instance_valid(loading_progress_bar):
		return
	loading_progress_bar.visible = total > 0
	loading_progress_bar.value = clampf(float(completed) / float(maxi(1, total)), 0.0, 1.0)
