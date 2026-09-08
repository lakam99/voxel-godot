extends "res://scripts/testing/buildings/CitadelBuntingStageDiagnostic.gd"
const Domain = preload("res://scripts/buildings/CitadelExteriorBuntingDomain.gd")
func _work() -> Dictionary:
	state.begin_phase("recognition_diagnostic", 10000)
	if FileAccess.get_sha256(_input_path()) != _input_sha(): return {"passed": false, "checks": {"pinned": false}}
	var file := FileAccess.open(_input_path(), FileAccess.READ)
	if file == null: return {"passed": false, "checks": {"read": false}}
	var input: Dictionary = file.get_var(false); file.close()
	var b = Heads.Copy.copy_blueprint(input.blueprint)
	var observations := {}; var parts: Array = []
	for p in b.parts:
		if p.semantic == "citadel_civic_landmark":
			Domain.declare(p, "landmark", 0)
			observations.landmark = Domain._producer_landmark(b, p)
			parts.append(p.snapshot())
		if p.semantic == "castle_keep_forecourt_pavilion":
			var side := -1 if p.position.x < 0 else 1
			Domain.declare(p, "forecourt_pavilion", side)
			observations[p.id] = Domain._producer_pavilion(b, p, side)
			parts.append(p.snapshot())
	for room: Dictionary in b.rooms:
		if room.get("role") == "courtyard": observations.courtyard = Domain._producer_courtyard(b, room)
	var palace: Dictionary = b.recipe.castleGrammar.palaceGrammar
	observations.layoutHashMatches = JSON.stringify(palace.forecourtLayout).sha256_text() == palace.forecourtLayoutHash
	observations.layoutSides = []
	for row: Dictionary in palace.forecourtLayout:
		observations.layoutSides.append({"type": typeof(row.side), "value": row.side, "integerMembership": row.side in [-1, 1], "floatMembership": float(row.side) in [-1.0, 1.0]})
	return {"passed": true, "checks": {"pinned": true, "deadline": state.checkpoint("recognition_completed")}, "observations": observations,
		"association": Domain.association(b), "parts": parts, "grammar": b.recipe.castleGrammar,
		"scope": "Pinned old geometry with explicitly synthetic receipt stamping to diagnose producer recognition. No actual producer receipts or acceptance."}
