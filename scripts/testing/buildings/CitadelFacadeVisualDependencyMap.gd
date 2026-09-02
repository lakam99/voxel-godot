extends RefCounted

## One reviewed camera-only source change, not a general dependency exemption.
## Reversing that exact span must reconstruct the entire historical file hash.
## All publication/preparation/init code outside the camera span stays exact.
const PATH := "res://scripts/testing/buildings/CitadelUrbanPocRunner.gd"
const OLD := "c6e67d412b73c933bd9a25fd01a92a0cf7dec025cd82d65a6e331891681c7bc9"
const NEW := "c697d93dc81c5f1d543b537ff9ff6c99433dde2a18be1c9c116856ca10737ce7"
const ROOT := "res://artifacts/citadel-visual-reset/"
const PROJECTION := "facade-camera-dependency-01/projection.json"
const PROJECTION_SHA := "776de5deb8909d1771ccfbbf62d8886dc9a1759078b4760055b4f80cfc160031"
const CONTROLS := {
	"facade-camera-legacy-01/report.json": "11f86e49a770ca88e97d761acb959099f76080f098e1eeb390e119e7535018e7",
	"facade-camera-incremental-01/report.json": "e73ae092896e0913449a70766c77ee96f8d600846ec5a4432cc58145811387d8"}

static func accepts(path: String, expected: String, actual: String) -> bool:
	return path == PATH and expected == OLD and actual == NEW and proof().get("ready", false)

static func proof() -> Dictionary:
	var value := _read(PROJECTION, PROJECTION_SHA)
	if value.is_empty() or value.get("oldSha256") != OLD or value.get("newSha256") != NEW or value.get("path") != PATH or value.get("projectedSha256") != OLD: return {}
	if FileAccess.get_sha256(PATH) != NEW: return {}
	var current := FileAccess.get_file_as_string(PATH)
	var legacy: String = Marshalls.base64_to_raw(value.get("legacySectionBase64", "")).get_string_from_utf8()
	if legacy.is_empty() or legacy.sha256_text() != value.get("legacySectionSha256"): return {}
	var start := current.find("## Opaque, single-runner camera job.")
	var finish := current.find("func append_camera_pose_rejection(")
	if start < 0 or finish <= start or start != current.rfind("## Opaque, single-runner camera job.") or finish != current.rfind("func append_camera_pose_rejection("): return {}
	var projected := current.substr(0, start) + legacy + current.substr(finish)
	if projected.sha256_text() != OLD or projected.to_utf8_buffer().size() != 41396: return {}
	for path in CONTROLS:
		var report := _read(path, String(CONTROLS[path]).to_lower())
		if report.get("passed") != true: return {}
	if FileAccess.get_sha256(PATH) != NEW or FileAccess.get_sha256(ROOT + PROJECTION) != PROJECTION_SHA: return {}
	return {"ready": true, "path": PATH, "recordedSha256": OLD, "currentSha256": NEW,
		"projectedWholeFileSha256": projected.sha256_text(), "projectionArtifactSha256": PROJECTION_SHA,
		"scope": "camera_job_class_and_camera_selection_methods_only", "controlReports": CONTROLS,
		"doesNotProve": "No full-scene visibility, GPU appearance, physical gate or integration acceptance."}

static func _read(relative: String, expected: String) -> Dictionary:
	var path := ROOT + relative
	if FileAccess.get_sha256(path) != expected: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	if file.get_length() <= 0 or file.get_length() > 65536:
		file.close()
		return {}
	var text := file.get_as_text()
	file.close()
	var value: Variant = JSON.parse_string(text)
	return value if value is Dictionary and FileAccess.get_sha256(path) == expected else {}
