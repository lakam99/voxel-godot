extends RefCounted
class_name BuildingBlueprint

const BuildingPartScript := preload("res://scripts/buildings/BuildingPart.gd")

var id := ""
var seed := 0
var style := "timber"
var recipe: Dictionary = {}
var rooms: Array = []
var parts: Array = []


func _init(blueprint_id := "", blueprint_seed := 0, blueprint_style := "timber") -> void:
	id = blueprint_id
	seed = blueprint_seed
	style = blueprint_style


func add_part(values: Dictionary) -> BuildingPart:
	var part = BuildingPartScript.new(values)
	parts.append(part)
	return part


func set_recipe(values: Dictionary) -> void:
	recipe = values.duplicate(true)


func set_room_records(values: Array) -> void:
	rooms.clear()
	for value in values:
		if value is Dictionary:
			rooms.append((value as Dictionary).duplicate(true))


func part_snapshots() -> Array:
	var result: Array = []
	for part in parts:
		if part != null and part.has_method("snapshot"):
			result.append(part.snapshot())
	return result


func snapshot() -> Dictionary:
	return {
		"id": id,
		"seed": seed,
		"style": style,
		"recipe": recipe.duplicate(true),
		"rooms": rooms.duplicate(true),
		"parts": part_snapshots()
	}


func deterministic_signature() -> String:
	return JSON.stringify(snapshot())
