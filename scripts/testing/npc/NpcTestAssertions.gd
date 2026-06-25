extends RefCounted
class_name NpcTestAssertions

static func approx_equal(actual: float, expected: float, tolerance := 0.0001) -> bool:
	return absf(actual - expected) <= tolerance

static func stable_hash(text: String) -> int:
	var value := 2166136261
	for i in range(text.length()):
		value = int((value ^ text.unicode_at(i)) * 16777619) & 0x7fffffff
	return value

static func rng_seed(world_seed: String, npc_id: String, domain: String, phase: String) -> int:
	return stable_hash("%s|%s|%s|%s" % [world_seed, npc_id, domain, phase])

static func deterministic_sequence(seed_value: int, count: int) -> Array[int]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var values: Array[int] = []
	for i in range(count):
		values.append(rng.randi())
	return values

static func stable_sorted_strings(values: Array) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy

static func required_report_schema_keys() -> Array[String]:
	return [
		"schemaVersion",
		"suite",
		"caseFilter",
		"timeMode",
		"seed",
		"branch",
		"gitCommit",
		"engineVersion",
		"startedUtc",
		"finishedUtc",
		"durationSeconds",
		"resultCount",
		"failureCount",
		"results",
		"metrics",
		"artifacts"
	]

static func dictionary_has_keys(value: Dictionary, required_keys: Array[String]) -> bool:
	for key in required_keys:
		if not value.has(key):
			return false
	return true
