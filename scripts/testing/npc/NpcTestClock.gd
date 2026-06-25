extends RefCounted
class_name NpcTestClock

const CLOCK_DISPLAY_OFFSET := 0.25
const DAWN_START_CLOCK := 5.25 / 24.0
const DAY_FULL_CLOCK := 7.0 / 24.0
const DUSK_START_CLOCK := 18.25 / 24.0
const NIGHT_FULL_CLOCK := 20.25 / 24.0

var time_of_day := 0.25
var frozen := false

func set_hour(hour: float) -> void:
	time_of_day = fposmod(hour / 24.0 - CLOCK_DISPLAY_OFFSET, 1.0)

func set_canonical_day() -> void:
	time_of_day = 0.25

func set_canonical_night() -> void:
	time_of_day = 0.75

func freeze() -> void:
	frozen = true

func unfreeze() -> void:
	frozen = false

func advance_hours(hours: float) -> void:
	if frozen:
		return
	time_of_day = fposmod(time_of_day + hours / 24.0, 1.0)

func display_phase() -> float:
	return fposmod(time_of_day + CLOCK_DISPLAY_OFFSET, 1.0)

func display_hour() -> float:
	return display_phase() * 24.0

func schedule_state() -> String:
	var phase := display_phase()
	if phase >= NIGHT_FULL_CLOCK or phase < DAWN_START_CLOCK:
		return "night"
	if phase < DAY_FULL_CLOCK:
		return "dawn"
	if phase >= DUSK_START_CLOCK:
		return "dusk"
	return "day"

func snapshot() -> Dictionary:
	return {
		"timeOfDay": time_of_day,
		"clockPhase": display_phase(),
		"displayHour": display_hour(),
		"scheduleState": schedule_state(),
		"frozen": frozen
	}
