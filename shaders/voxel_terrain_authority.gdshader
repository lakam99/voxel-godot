shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

varying flat vec4 material_indices;
varying flat vec4 material_weights;
varying vec3 world_position;

vec4 decode_8bit_vec4(float value) {
	uint packed = floatBitsToUint(value);
	return vec4(
		float(packed & uint(0xff)),
		float((packed >> uint(8)) & uint(0xff)),
		float((packed >> uint(16)) & uint(0xff)),
		float((packed >> uint(24)) & uint(0xff))
	);
}

vec3 material_color(float index) {
	if (index < 0.5) return vec3(0.36, 0.52, 0.30);
	if (index < 1.5) return vec3(0.34, 0.55, 0.28);
	if (index < 2.5) return vec3(0.36, 0.25, 0.16);
	if (index < 3.5) return vec3(0.39, 0.40, 0.38);
	if (index < 4.5) return vec3(0.72, 0.63, 0.39);
	if (index < 5.5) return vec3(0.78, 0.83, 0.83);
	if (index < 6.5) return vec3(0.19, 0.20, 0.21);
	if (index < 7.5) return vec3(0.12, 0.13, 0.14);
	if (index < 8.5) return vec3(0.51, 0.39, 0.31);
	if (index < 9.5) return vec3(0.43, 0.43, 0.40);
	if (index < 10.5) return vec3(0.23, 0.24, 0.23);
	if (index < 11.5) return vec3(0.48, 0.45, 0.42);
	if (index < 12.5) return vec3(0.31, 0.57, 0.61);
	if (index < 13.5) return vec3(0.56, 0.34, 0.18);
	if (index < 14.5) return vec3(0.28, 0.31, 0.20);
	return vec3(0.20, 0.36, 0.45);
}

float terrain_variation(vec3 position) {
	return fract(sin(dot(floor(position * 0.72), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void vertex() {
	material_indices = decode_8bit_vec4(CUSTOM1.x);
	material_weights = decode_8bit_vec4(CUSTOM1.y) / 255.0;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 weights = material_weights;
	weights /= max(0.00001, weights.x + weights.y + weights.z + weights.w);
	vec3 color =
		material_color(material_indices.x) * weights.x +
		material_color(material_indices.y) * weights.y +
		material_color(material_indices.z) * weights.z +
		material_color(material_indices.w) * weights.w;
	float upward = clamp(NORMAL.y * 0.5 + 0.5, 0.0, 1.0);
	float variation = mix(0.92, 1.06, terrain_variation(world_position));
	ALBEDO = color * mix(0.72, 1.0, upward) * variation;
	ROUGHNESS = 0.94;
	SPECULAR = 0.18;
}
