extends RefCounted
class_name GameLaunchOptions

## Explicit session-only launch policy. Never saved or inferred from test seeds.
static func parse(arguments: PackedStringArray) -> Dictionary:
	var result := {"skipTutorial":false,"forceDaytime":false,"forceClearWeather":false}
	for argument: String in arguments:
		match argument.to_lower().replace("-", ""):
			"skiptutorial": result.skipTutorial=true
			"forcedaytime": result.forceDaytime=true
			"forceclearweather": result.forceClearWeather=true
	result.make_read_only()
	return result
