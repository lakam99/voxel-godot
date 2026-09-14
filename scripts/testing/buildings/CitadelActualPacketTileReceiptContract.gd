extends "res://scripts/testing/buildings/CitadelPublicationServiceContract.gd"

## Runs only the actual frozen ten-group packet tile path from the service
## contract. The parent owns source injection, lifecycle cleanup and the exact
## production packet/navigation service methods.
func _initialize() -> void:
	call_deferred("_run_tile")

func _run_tile() -> void:
	var result: Dictionary = await actual_packet_tile_receipt(false,ACTUAL_PACKET_TILE,ACTUAL_PACKET_TILE_GROUPS,ACTUAL_PACKET_GROUP)
	var report := {"schema":"citadel-actual-packet-tile-receipt-contract/v1","complete":true,
		"passed":result.get("ready",false) and not checks.values().has(false),"checks":checks,"result":result,
		"doesNotProve":"No NavigationServer registration, route query, NPC movement, headed runtime, visual, save, or gameplay acceptance."}
	var file := FileAccess.open(OS.get_environment("CITADEL_PACKET_TILE_RECEIPT_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("ACTUAL PACKET TILE RECEIPT ",JSON.stringify({"passed":report.passed,"ready":result.get("ready",false)}))
	quit(0 if report.passed else 1)
