extends "res://scripts/testing/buildings/BuildingPublicationPreparationContract.gd"
## Additional tiny synthetic entry/retirement controls; no full-source replay.

class RejectInitializedMasonry extends "res://scripts/buildings/BuildingPartPublisher.gd":
	var initialized := false
	func prepare_masonry_apertures(blueprint) -> bool:
		initialized = super.prepare_masonry_apertures(blueprint)
		return false # Explicit synthetic failure AFTER the real initializer.

func _run() -> void:
	report.evidenceLevel = "synthetic_publication_entry_and_retirement_contract"
	var parent := Node3D.new()
	root.add_child(parent)
	var source := _jointed_failure_source()
	checks.source_ready = source.ready
	if not source.ready: parent.free(); _finish(); return
	var publisher := RejectInitializedMasonry.new()
	var failed: Dictionary = publisher.begin_prepared_publication(source.prepared,parent,BINDING,{"progressCallback":func(_progress):return true})
	checks.real_masonry_initialized_before_rejection = publisher.initialized
	checks.failed_has_retirement_payload = not failed.ready and failed.has("retirementPayload")
	if failed.has("retirementPayload"):
		var payload: Dictionary = failed.retirementPayload
		var state: Dictionary = payload.scenePreparation
		checks.real_paving_state_transferred = state.pavingBlueprint==payload.blueprint and not state.pavingArtifacts.is_empty() and not state.pavingParts.is_empty()
		checks.real_masonry_source_transferred = state.masonry!=null and state.masonry._blueprint==payload.blueprint
		checks.real_masonry_initialized_ready = state.masonry.state=="ready"
		checks.callback_transferred = state.progressCallback.is_valid() and not publisher.incremental_progress_callback.is_valid()
		checks.publisher_detached = publisher._masonry_preparation==null and publisher._paving_blueprint==null \
			and publisher._paving_artifacts.is_empty() and publisher._paving_source_parts.is_empty() \
			and publisher.physical_integrity.is_empty() and publisher.raised_route_coverage.is_empty()
		payload = {}; state = {}
	failed.clear(); source.clear()
	checks.retirement_disposal_leaves_no_publisher_source = publisher._masonry_preparation==null and publisher._paving_blueprint==null
	publisher.clear_published(); publisher=null
	var legacy := Publisher.new()
	var authority := Authority.new()
	var b := Blueprint.new("synthetic_legacy",7,"timber")
	b.recipe={"pavingTreatments":[{"id":"retained_treatment"}]}
	var before := var_to_bytes(b.snapshot())
	checks.legacy_direct_begin_ready = legacy.begin_publication(b,parent,{"structuralAuthorityBlueprint":authority,"progressCallback":func(_progress):return true})
	checks.legacy_direct_separate_authority_once = authority.calls==1 and legacy.physical_integrity=={"passed":false,"syntheticSeparateAuthority":true}
	checks.legacy_constant_compatibility = Publisher.CastleCompoundBlueprintBuilderScript==Castle
	checks.legacy_treatments_nonempty = legacy.paving_treatments.size()==1
	legacy.clear_published()
	checks.legacy_clear_preserves_nonempty_source_array = var_to_bytes(b.snapshot())==before and b.recipe.pavingTreatments.size()==1
	checks.legacy_clear_releases_callback = not legacy.incremental_progress_callback.is_valid()
	legacy=null
	parent.free()
	await process_frame
	_finish()
