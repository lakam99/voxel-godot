extends CanvasLayer

# The same opaque loading presentation as the HUD, available before world or
# inventory setup. Main owns readiness; this component only displays progress.
const PanelBuilder := preload("res://scripts/GameHudPanelBuilder.gd")
const GAME_THEME := preload("res://resources/ui/game_theme.tres")
var loading_overlay: Control
var loading_label: Label

func _ready() -> void:
	layer = 9 # The title menu remains above this during menu-driven startup.
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = GAME_THEME
	add_child(root)
	PanelBuilder.build_loading_overlay(self, root)
	loading_overlay.show()
	set_message("Preparing world")

func set_message(message: String) -> void:
	if loading_label != null:
		loading_label.text = message
