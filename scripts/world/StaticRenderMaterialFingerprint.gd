extends RefCounted
## Canonical identity for immutable materials admitted to static render batches.
## Hash evaluated shader uniforms or stored BaseMaterial values and texture data,
## matching the renderer input rather than a serialized-resource envelope.

const SCHEMA := "chunk-render-material-content/v1"


static func inspect(material: Material) -> Dictionary:
	if not is_instance_valid(material):
		return {"status":"failed", "reason":"material_unavailable"}
	var digest := _material_digest(material)
	if digest.length() != 64:
		return {"status":"failed", "reason":"material_content_digest_failed"}
	return {"status":"ready", "schema":SCHEMA, "contentDigest":digest}


static func _material_digest(material: Material) -> String:
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var shader := shader_material.shader
		if shader == null or shader.code.is_empty():
			return ""
		var uniforms: Array = []
		for uniform_value: Variant in shader.get_shader_uniform_list():
			if not uniform_value is Dictionary:
				return ""
			var name := String(uniform_value.get("name", ""))
			if name.begins_with("global_"):
				continue
			var parameter: Variant = shader_material.get_shader_parameter(name)
			var canonical_parameter: Variant = _canonical_shader_parameter(
				shader.code, name, parameter)
			if parameter is Texture2D:
				var texture_digest := _texture_digest(parameter as Texture2D)
				if texture_digest.is_empty():
					return ""
				canonical_parameter = ["texture2d", texture_digest]
			elif not _shader_digest_value_supported(parameter):
				return ""
			uniforms.append([name, canonical_parameter])
		uniforms.sort_custom(func(a: Array, b: Array) -> bool:
			return String(a[0]) < String(b[0]))
		return Marshalls.raw_to_base64(var_to_bytes([shader.code, uniforms])).sha256_text()
	if material is BaseMaterial3D:
		var values: Array = []
		for property_value: Variant in material.get_property_list():
			if not property_value is Dictionary:
				return ""
			var name := String(property_value.get("name", ""))
			if name.is_empty() or name.begins_with("resource_") \
					or name in ["script", "resource_local_to_scene", "resource_name"]:
				continue
			var value: Variant = material.get(name)
			var canonical_value: Variant = value
			if value is Texture2D:
				var texture_digest := _texture_digest(value as Texture2D)
				if texture_digest.is_empty():
					return ""
				canonical_value = ["texture2d", texture_digest]
			elif value is Resource or value is Object or value is Callable \
					or not _material_digest_value_supported(value):
				return ""
			values.append([name, canonical_value])
		values.sort_custom(func(a: Array, b: Array) -> bool:
			return String(a[0]) < String(b[0]))
		return Marshalls.raw_to_base64(var_to_bytes([material.get_class(), values])).sha256_text()
	return ""


static func _shader_digest_value_supported(value: Variant) -> bool:
	return value == null or value is bool or value is int or value is float \
		or value is String or value is Color or value is Vector2 or value is Vector3 \
		or value is Vector4


## Godot may return null for an unset uniform before shader compilation, then
## materialize that uniform's declared default after rendering. Hash both
## states as the same declared default; explicit non-default overrides remain
## distinct and therefore invalidate stale candidates.
static func _canonical_shader_parameter(shader_code: String, name: String,
		parameter: Variant) -> Variant:
	var entry := _shader_uniform_default(shader_code, name)
	if entry.is_empty():
		return parameter
	var default_value: Variant = _parse_shader_default(String(entry.get("type", "")),
		String(entry.get("expression", "")))
	if parameter == null:
		return ["shader_default", String(entry.type), String(entry.expression)]
	if default_value != null and _shader_parameter_equals_default(parameter, default_value):
		return ["shader_default", String(entry.type), String(entry.expression)]
	return parameter


static func _shader_uniform_default(shader_code: String, uniform_name: String) -> Dictionary:
	if uniform_name.is_empty() or not uniform_name.is_valid_identifier():
		return {}
	var regex := RegEx.new()
	var pattern := "(?m)^\\s*uniform\\s+([A-Za-z_][A-Za-z0-9_]*)\\s+" \
		+ uniform_name + "(?:\\s*:[^=;\\r\\n]+)?\\s*=\\s*([^;]+);"
	if regex.compile(pattern) != OK:
		return {}
	var found := regex.search(shader_code)
	if found == null:
		return {}
	return {"type":found.get_string(1), "expression":found.get_string(2).strip_edges()}


static func _parse_shader_default(type_name: String, expression: String) -> Variant:
	var value := expression.strip_edges()
	if type_name == "bool":
		if value == "true": return true
		if value == "false": return false
		return null
	if type_name in ["int", "uint"]:
		var number: Variant = _parse_shader_number(value)
		return int(number) if number != null else null
	if type_name == "float":
		return _parse_shader_number(value)
	var open := value.find("(")
	if open < 0 or not value.ends_with(")"):
		return null
	var constructor := value.substr(0, open).strip_edges()
	var expected_components := 0
	if constructor in ["vec2", "ivec2", "uvec2"]: expected_components = 2
	elif constructor in ["vec3", "ivec3", "uvec3"]: expected_components = 3
	elif constructor in ["vec4", "ivec4", "uvec4"]: expected_components = 4
	else: return null
	var component_text := value.substr(open + 1, value.length() - open - 2)
	var components: Array = []
	for component_value: String in component_text.split(","):
		var number: Variant = _parse_shader_number(component_value.strip_edges())
		if number == null: return null
		components.append(number)
	if components.size() == 1:
		while components.size() < expected_components:
			components.append(components[0])
	if components.size() != expected_components:
		return null
	if constructor.begins_with("ivec") or constructor.begins_with("uvec"):
		var integers: Array[int] = []
		for component: Variant in components: integers.append(int(component))
		match expected_components:
			2: return Vector2i(integers[0], integers[1])
			3: return Vector3i(integers[0], integers[1], integers[2])
			4: return Vector4i(integers[0], integers[1], integers[2], integers[3])
	match expected_components:
		2: return Vector2(float(components[0]), float(components[1]))
		3: return Vector3(float(components[0]), float(components[1]), float(components[2]))
		4: return Color(float(components[0]), float(components[1]),
			float(components[2]), float(components[3]))
	return null


static func _parse_shader_number(value: String) -> Variant:
	var normalized := value.strip_edges().trim_suffix("f").trim_suffix("u")
	var regex := RegEx.new()
	if regex.compile("^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$") != OK \
			or regex.search(normalized) == null:
		return null
	return float(normalized)


static func _shader_parameter_equals_default(parameter: Variant,
		default_value: Variant) -> bool:
	if parameter is float and default_value is float:
		return is_equal_approx(float(parameter), float(default_value))
	if parameter is Vector2 and default_value is Vector2:
		return parameter.is_equal_approx(default_value)
	if parameter is Vector3 and default_value is Vector3:
		return parameter.is_equal_approx(default_value)
	if parameter is Vector4 and default_value is Vector4:
		return parameter.is_equal_approx(default_value)
	if parameter is Color and default_value is Color:
		return parameter.is_equal_approx(default_value)
	return parameter == default_value


static func _material_digest_value_supported(value: Variant) -> bool:
	return value == null or value is bool or value is int or value is float \
		or value is String or value is Color or value is Vector2 or value is Vector3 \
		or value is Vector4 or value is Vector2i or value is Vector3i \
		or value is Rect2 or value is Quaternion or value is Basis \
		or value is Transform3D or value is AABB


static func _texture_digest(texture: Texture2D) -> String:
	if not is_instance_valid(texture):
		return ""
	var image := texture.get_image()
	if image == null or image.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var identity := var_to_bytes([texture.get_class(), image.get_width(),
		image.get_height(), image.get_format(), image.has_mipmaps()])
	if context.update(identity) != OK or context.update(image.get_data()) != OK:
		return ""
	return context.finish().hex_encode()
