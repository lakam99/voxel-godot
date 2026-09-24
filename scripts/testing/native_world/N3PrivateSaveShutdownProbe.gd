extends "res://scripts/MainCore.gd"

var streaming_dispatches := 0

func apply_streaming_region_demand(_advance_budget_usec := 4000) -> bool:
	streaming_dispatches += 1
	return false
