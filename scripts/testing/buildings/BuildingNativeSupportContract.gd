extends SceneTree
const Blueprint=preload("res://scripts/buildings/BuildingBlueprint.gd")
const Memo=preload("res://scripts/buildings/BuildingSupportResolutionMemo.gd")
class Custom extends "res://scripts/buildings/BuildingBlueprint.gd":
	pass
var checks:Dictionary={}
func _initialize() -> void:
	checks["native_registered"]=ClassDB.class_exists("BuildingSupportKernel")
	if checks.native_registered: _exercise()
	var file:=FileAccess.open(OS.get_environment("BUILDING_NATIVE_SUPPORT_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":not checks.values().has(false),"checks":checks,"scope":"Synthetic native support ownership/failure/parity contract; not gameplay acceptance."},"\t"));file.close()
	quit(1 if checks.values().has(false) else 0)
func _fixture(proof):
	proof.add_part({"id":"root","kind":"foundation","position":Vector3(0,0.5,0),"size":Vector3(4,1,4)})
	proof.add_part({"id":"floor","kind":"floor","position":Vector3(0,1.1,0),"size":Vector3(2,0.2,2)})
	proof.add_part({"id":"mass","kind":"wall","position":Vector3(0,1.7,0),"size":Vector3.ONE})
	return proof
func _clean(proof) -> bool:
	return proof._native_support_queries==null and not proof._native_support_resolving and not proof._native_support_decided
func _exercise() -> void:
	var native=_fixture(Blueprint.new());var reference=_fixture(Custom.new())
	var report:Dictionary=native.validate_physical_integrity()
	checks["full_report_and_snapshot_exact"]=var_to_bytes(report)==var_to_bytes(reference.validate_physical_integrity()) and var_to_bytes(native.snapshot())==var_to_bytes(reference.snapshot())
	checks["native_queries_executed"]=native._native_support_query_count==34
	checks["custom_subclass_preserved"]=reference._native_support_query_count==0
	var extreme=_fixture(Blueprint.new());var extreme_reference=_fixture(Custom.new())
	for proof in [extreme,extreme_reference]:
		for part in proof.parts:part.position.y=1.0e30
	checks["extreme_coordinates_preserve_original_path"]=var_to_bytes(extreme.validate_physical_integrity())==var_to_bytes(extreme_reference.validate_physical_integrity()) and extreme._native_support_query_count==0 and _clean(extreme)
	checks["owner_exit_clears_native"]=_clean(native)
	var memo=_fixture(Memo.new());memo.validate_physical_integrity()
	checks["memo_cold_uses_native"]=memo._native_support_query_count>0
	memo.validate_physical_integrity()
	checks["memo_warm_avoids_kernel"]=memo._native_support_query_count==0 and memo.observations.hits==2
	var owner:bool=native._begin_validation_cache()
	native.resolve_physical_contracts()
	var count:int=native._native_support_query_count
	native.parts[-1].recipe["physicalSupportsPartId"]="floor"
	reference.parts[-1].recipe["physicalSupportsPartId"]="floor"
	checks["direct_query_fresh_with_outer_cache"]=var_to_bytes(native.structural_support_at(native.parts[-1],Vector3(0,1.2,0)))==var_to_bytes(reference.structural_support_at(reference.parts[-1],Vector3(0,1.2,0))) and native._native_support_query_count==count and _clean(native)
	native._end_validation_cache(owner)
	for phase in ["move","remove","reorder"]:
		for proof in [native,reference]:
			match phase:
				"move":proof.parts[0].position.x+=10
				"remove":proof.parts.remove_at(0)
				"reorder":proof.parts.reverse()
		checks["mutation_"+phase]=var_to_bytes(native.validate_physical_integrity())==var_to_bytes(reference.validate_physical_integrity()) and var_to_bytes(native.snapshot())==var_to_bytes(reference.snapshot()) and _clean(native)
	for nested in [false,true]:
		var proof=_fixture(Blueprint.new())
		var outer:bool=proof._begin_validation_cache() if nested else false
		var cancelled:Dictionary=proof.validate_physical_integrity_cancellable(func(stage):return not (stage=="physical_resolve_support" and proof._native_support_query_count>0))
		checks["cancel_after_native_%s"%nested]=cancelled.get("cancelled",false) and _clean(proof) and proof._validation_cache_active==nested
		if nested:proof._end_validation_cache(outer)
	var broken=_fixture(Blueprint.new())
	var failed:Dictionary=broken.validate_physical_integrity_cancellable(func(stage):
		if stage=="physical_resolve_support" and broken._native_support_queries!=null:
			for part in broken.parts:broken._native_support_queries._indices[part]=-1
		return true)
	checks["kernel_error_is_explicit_not_cancellation"]=not failed.passed and not failed.get("cancelled",true) and failed.violations==["native_support_query:invalid_target_index"] and _clean(broken) and not broken._validation_cache_active
	var kernel=ClassDB.instantiate("BuildingSupportKernel")
	checks["protocol_matches_float_precision"]=kernel.protocol_version()==1
	checks["unconfigured_rejected"]=kernel.query(PackedInt32Array(),0,Vector3.ZERO,0.05,0.26).get("nativeSupportError")=="unconfigured_kernel"
	checks["malformed_configuration_rejected"]=not kernel.configure([{}])
