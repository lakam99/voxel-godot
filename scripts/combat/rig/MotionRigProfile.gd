extends RefCounted
class_name MotionRigProfile

## Declarative anatomy mapping for motion presentation. A profile knows a
## body rig's semantic affordances, but has no knowledge of combat rules,
## source bodies, scenes, physics, damage, or named hostile families.

const CORE_REQUIREMENTS: Array[String] = ["root", "torso", "lead_appendage", "counterbalance"]

var id := ""
var skeleton_path := NodePath("MotionSkeleton")
var role_bindings: Dictionary = {}
var metadata: Dictionary = {}


func _init(values: Dictionary = {}) -> void:
	id = String(values.get("id", "motion_rig")).strip_edges().to_lower()
	skeleton_path = NodePath(String(values.get("skeletonPath", "MotionSkeleton")))
	metadata = (values.get("metadata", {}) as Dictionary).duplicate(true)
	var raw_roles: Dictionary = values.get("roles", {}) as Dictionary
	for raw_role in raw_roles.keys():
		var role := normalized_role(String(raw_role))
		if role.is_empty():
			continue
		var raw_bindings = raw_roles.get(raw_role, [])
		var bindings: Array = []
		if raw_bindings is Dictionary:
			raw_bindings = [raw_bindings]
		for raw_binding in raw_bindings:
			if not (raw_binding is Dictionary):
				continue
			var binding := normalized_binding(raw_binding as Dictionary)
			if not String(binding.get("bone", "")).is_empty():
				bindings.append(binding)
		if not bindings.is_empty():
			role_bindings[role] = bindings


func normalized_role(value: String) -> String:
	return value.strip_edges().to_lower()


func normalized_binding(raw: Dictionary) -> Dictionary:
	var axis: Vector3 = raw.get("axis", Vector3.RIGHT) as Vector3
	if axis.length_squared() <= 0.000001:
		axis = Vector3.RIGHT
	var rest_direction: Vector3 = raw.get("restDirection", Vector3.DOWN) as Vector3
	if rest_direction.length_squared() <= 0.000001:
		rest_direction = Vector3.DOWN
	return {
		"bone": String(raw.get("bone", "")).strip_edges(),
		"axis": axis.normalized(),
		"motionAlign": bool(raw.get("motionAlign", false)),
		"restDirection": rest_direction.normalized(),
		"maxDegrees": clampf(float(raw.get("maxDegrees", 18.0)), 0.0, 170.0),
		"weight": clampf(float(raw.get("weight", 1.0)), -2.0, 2.0),
		"sign": -1.0 if float(raw.get("sign", 1.0)) < 0.0 else 1.0
	}


func bindings_for(role: String) -> Array:
	var normalized := normalized_role(role)
	var raw: Array = role_bindings.get(normalized, []) as Array
	return raw.duplicate(true)


func resolved_role(requirement: String, side: float) -> String:
	var normalized := normalized_role(requirement)
	if normalized == "lead_appendage":
		return "lead_left" if side < 0.0 else "lead_right"
	if normalized == "counterbalance":
		return "counter_left" if side < 0.0 else "counter_right"
	return normalized


func supports_requirement(requirement: String) -> bool:
	var normalized := normalized_role(requirement)
	if normalized in ["lead_appendage", "counterbalance"]:
		return not bindings_for(resolved_role(normalized, -1.0)).is_empty() and not bindings_for(resolved_role(normalized, 1.0)).is_empty()
	return not bindings_for(normalized).is_empty()


func validate(skeleton: Skeleton3D, requirements: Array[String] = CORE_REQUIREMENTS) -> Dictionary:
	var errors: Array[String] = []
	var available: Dictionary = {}
	if skeleton == null or not is_instance_valid(skeleton):
		errors.append("missing Skeleton3D at %s" % str(skeleton_path))
		return {"valid": false, "errors": errors, "availableRequirements": available}
	var used_by_bone: Dictionary = {}
	for requirement in requirements:
		var normalized_requirement := normalized_role(String(requirement))
		if normalized_requirement in ["lead_appendage", "counterbalance"]:
			for side in [-1.0, 1.0]:
				validate_role_bindings(skeleton, resolved_role(normalized_requirement, side), used_by_bone, errors)
			available[normalized_requirement] = supports_requirement(normalized_requirement)
		else:
			validate_role_bindings(skeleton, normalized_requirement, used_by_bone, errors)
			available[normalized_requirement] = supports_requirement(normalized_requirement)
	return {"valid": errors.is_empty(), "errors": errors, "availableRequirements": available}


func validate_role_bindings(skeleton: Skeleton3D, role: String, used_by_bone: Dictionary, errors: Array[String]) -> void:
	var bindings := bindings_for(role)
	if bindings.is_empty():
		errors.append("missing required semantic role '%s'" % role)
		return
	for binding in bindings:
		var bone := String((binding as Dictionary).get("bone", ""))
		if skeleton.find_bone(bone) < 0:
			errors.append("role '%s' references absent bone '%s'" % [role, bone])
			continue
		if used_by_bone.has(bone):
			errors.append("bone '%s' is bound by both '%s' and '%s'" % [bone, String(used_by_bone[bone]), role])
			continue
		used_by_bone[bone] = role


func snapshot() -> Dictionary:
	return {
		"id": id,
		"skeletonPath": str(skeleton_path),
		"roles": role_bindings.duplicate(true),
		"metadata": metadata.duplicate(true)
	}
