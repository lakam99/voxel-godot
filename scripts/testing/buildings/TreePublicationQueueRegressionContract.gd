extends "res://scripts/testing/TreePublicationQueueContractRunner.gd"
## Artifact adapter only: executes the existing queue contract unchanged.
func run_contract() -> void:
	await super.run_contract()
	var path := OS.get_environment("TREE_QUEUE_REGRESSION_OUTPUT")
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file == null: quit(2); return
	var passed := true
	for result: Dictionary in results: passed = passed and result.passed
	file.store_string(JSON.stringify({"passed":passed,"results":results,
		"queueSourceSha256":FileAccess.get_sha256("res://scripts/environment/TreePublicationQueue.gd"),
		"contractSourceSha256":FileAccess.get_sha256("res://scripts/testing/TreePublicationQueueContractRunner.gd"),
		"evidenceLevel":"unchanged existing tree queue contract; not normal-runtime visual acceptance"},"\t"))
	file.close()
