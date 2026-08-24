shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.6, 0.6, 0.55, 1.0);
uniform vec4 accent_color : source_color = vec4(0.45, 0.45, 0.42, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.86;
uniform float breakup_strength : hint_range(0.0, 0.45) = 0.16;
uniform float grid_strength : hint_range(0.0, 0.35) = 0.10;
uniform float scale = 2.4;
uniform vec4 grain_color : source_color = vec4(0.20, 0.10, 0.04, 1.0);
uniform float grain_strength : hint_range(0.0, 0.55) = 0.0;
uniform float grain_scale = 13.0;
uniform float grain_warp = 2.2;
uniform float masonry_strength : hint_range(0.0, 1.0) = 0.0;
uniform float age_strength : hint_range(0.0, 1.0) = 0.0;
uniform float damp_strength : hint_range(0.0, 1.0) = 0.0;
uniform float moss_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 moss_color : source_color = vec4(0.12, 0.18, 0.08, 1.0);
uniform float detail_scale = 5.0;
uniform float cobble_strength : hint_range(0.0, 1.0) = 0.0;
uniform float roof_strength : hint_range(0.0, 1.0) = 0.0;
uniform float repair_strength : hint_range(0.0, 1.0) = 0.0;
uniform float repair_phase = 0.0;
uniform vec4 repair_host_base : source_color = vec4(0.6, 0.6, 0.55, 1.0);
uniform vec4 repair_host_accent : source_color = vec4(0.45, 0.45, 0.42, 1.0);

varying vec3 v_world_pos;
varying vec3 v_world_normal;
varying vec3 v_local_pos;
varying float v_piece_variation;
varying float v_event_runoff;
varying float v_event_threshold;
varying float v_route_lateral;
varying float v_event_root;
varying float v_event_canopy;
varying float v_piece_repair_blend;
varying float v_longest_local_axis;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.55;
    for (int octave = 0; octave < 4; octave++) {
        value += value_noise(p) * amplitude;
        p = p * 2.03 + vec2(17.1, 9.2);
        amplitude *= 0.48;
    }
    return value;
}

void vertex() {
    v_local_pos = VERTEX;
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
    v_piece_variation = hash21(MODEL_MATRIX[3].xz + vec2(17.0, 41.0)) * 2.0 - 1.0;
    v_event_runoff = INSTANCE_CUSTOM.r;
    float packed_route = floor(INSTANCE_CUSTOM.g * 255.0 + 0.5);
    v_event_threshold = floor(packed_route / 16.0) / 15.0;
    v_route_lateral = mod(packed_route, 16.0) / 15.0;
    v_event_root = INSTANCE_CUSTOM.b;
    v_event_canopy = INSTANCE_CUSTOM.a;
	v_piece_repair_blend = repair_strength > 0.001 ? mix(0.34, 0.92, hash21(MODEL_MATRIX[3].xz + vec2(repair_phase, repair_phase * 3.1))) : 0.0;
    vec3 local_scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
    v_longest_local_axis = local_scale.x >= local_scale.y && local_scale.x >= local_scale.z ? 0.0 : (local_scale.y >= local_scale.z ? 1.0 : 2.0);
}

void fragment() {
    vec3 n = normalize(v_world_normal);
    vec2 sample_axis = abs(n.y) > 0.55 ? v_world_pos.xz : (abs(n.x) > abs(n.z) ? v_world_pos.zy : v_world_pos.xy);
    vec2 local_axis = abs(n.y) > 0.55 ? v_local_pos.xz : (abs(n.x) > abs(n.z) ? v_local_pos.zy : v_local_pos.xy);
    float camera_distance = distance(CAMERA_POSITION_WORLD, v_world_pos);
    float detail_fade = 1.0 - smoothstep(24.0, 78.0, camera_distance);
    float noise_value = fbm(sample_axis * scale);
	float weather_noise = fbm(sample_axis * 0.72 + vec2(29.0, 7.0));
	float surface_height = noise_value * breakup_strength * 0.16;
    float face_light = mix(0.88, 1.08, clamp(n.y * 0.5 + 0.5, 0.0, 1.0));
    vec2 grid = abs(fract(sample_axis * 0.72) - vec2(0.5));
    float mortar = 1.0 - smoothstep(0.45, 0.50, max(grid.x, grid.y)) * grid_strength;
    vec3 color = mix(base_color.rgb, accent_color.rgb, noise_value * breakup_strength);
    color *= 1.0 + v_piece_variation * (0.045 + masonry_strength * 0.115 + grain_strength * 0.020) * detail_fade;
    float cobble_joint = 0.0;
    float cobble_mineral = 0.0;
    float cobble_broken = 0.0;
    float traffic_wear = 0.0;
    if (cobble_strength > 0.001) {
        vec2 cobble_warp = vec2(
            value_noise(sample_axis * 0.19 + vec2(17.0, 41.0)),
            value_noise(sample_axis * 0.23 + vec2(71.0, 11.0))
        ) - vec2(0.5);
        vec2 cobble_uv = sample_axis * vec2(2.52, 3.18) + cobble_warp * 0.52;
        float cobble_row = floor(cobble_uv.y);
        cobble_uv.x += mod(cobble_row, 2.0) * 0.46 + sin(cobble_row * 1.73) * 0.19;
        vec2 cobble_id = floor(cobble_uv);
        float stone_shape = hash21(cobble_id + vec2(cobble_row * 0.13, 0.0));
        vec2 cobble_cell = fract(cobble_uv) - vec2(0.5);
        cobble_cell += (vec2(hash21(cobble_id + 5.7), hash21(cobble_id + 19.3)) - vec2(0.5)) * 0.10;
        vec2 stone_extent = vec2(mix(0.29, 0.45, stone_shape), mix(0.22, 0.37, hash21(cobble_id + 29.1)));
        vec2 rounded_box = abs(cobble_cell) - stone_extent;
        float cobble_distance = length(max(rounded_box, vec2(0.0))) + min(max(rounded_box.x, rounded_box.y), 0.0) - 0.075;
        cobble_joint = smoothstep(-0.015, 0.045, cobble_distance);
        cobble_mineral = fbm((cobble_id + vec2(cobble_row * 0.17, 0.0)) * 1.73);
        cobble_broken = smoothstep(0.90, 0.985, hash21(cobble_id * 1.71 + 43.0));
        float center_footfall = 1.0 - smoothstep(0.65, 2.55, abs(local_axis.x));
        float left_wheel = 1.0 - smoothstep(0.16, 0.54, abs(abs(local_axis.x) - 1.48));
        float length_breakup = mix(0.55, 1.0, smoothstep(0.28, 0.72, fbm(vec2(local_axis.y * 0.09, 8.3))));
        float route_x = abs(fract(sample_axis.x * 0.052 + 0.19) - 0.5);
        float route_y = abs(fract(sample_axis.y * 0.067 + 0.31) - 0.5);
        float directional_route = 1.0 - smoothstep(0.035, 0.16, min(route_x, route_y));
        float route_breakup = mix(0.52, 1.0, smoothstep(0.30, 0.70, fbm(sample_axis * vec2(0.035, 0.12) + vec2(91.0, 27.0))));
		float centerline_wear = 1.0 - smoothstep(0.08, 0.56, v_route_lateral);
		float rut_wear = 1.0 - smoothstep(0.06, 0.22, abs(v_route_lateral - 0.44));
		float route_pattern = max(centerline_wear * 0.48, rut_wear * 0.84) * route_breakup;
		// Stone breakage is intrinsic material detail, but traffic wear must be
		// earned by a recipe route or an actual threshold event. Noise only varies
		// the intensity inside that published corridor; it cannot invent a route.
		traffic_wear = max(route_pattern * length_breakup * v_event_threshold, cobble_broken * 0.28 * v_event_threshold);
        vec3 cobble_color = mix(base_color.rgb * 0.82, base_color.rgb * 1.12, cobble_mineral);
        cobble_color = mix(cobble_color, cobble_color * vec3(0.76, 0.69, 0.57), traffic_wear * 0.34);
        cobble_color = mix(cobble_color, accent_color.rgb * 0.82, cobble_broken * 0.35);
        color = mix(color, cobble_color, cobble_strength * (1.0 - cobble_joint));
        color = mix(color, accent_color.rgb * 0.88, cobble_joint * cobble_strength * 0.72);
		surface_height += cobble_strength * ((1.0 - cobble_joint) * (0.28 + cobble_mineral * 0.12 - traffic_wear * 0.075 - cobble_broken * 0.12) - cobble_joint * 0.16);
    }
    if (masonry_strength > 0.001) {
        float mineral = fbm(sample_axis * detail_scale + vec2(3.7, 11.9));
        float pitting = smoothstep(0.67, 0.92, fbm(sample_axis * detail_scale * 2.7));
        float edge_distance = max(abs(local_axis.x), abs(local_axis.y));
        float worn_edge = smoothstep(0.40, 0.50, edge_distance) * (0.45 + mineral * 0.55);
        float block_family = clamp(v_piece_variation * 0.5 + 0.5, 0.0, 1.0);
        float replacement_block = smoothstep(0.72, 0.91, block_family) * smoothstep(0.64, 0.92, mineral);
        float repair_cluster = repair_strength * smoothstep(0.08, 0.98, v_piece_variation);
        float pale_block = smoothstep(0.08, 0.28, block_family) * (1.0 - pitting);
        vec3 family_tint = mix(color * vec3(0.79, 0.76, 0.69), color * vec3(1.10, 1.035, 0.91), block_family);
        color = mix(color, family_tint, masonry_strength * 0.33 * detail_fade);
        color = mix(color, accent_color.rgb, masonry_strength * (mineral * 0.22 + pitting * 0.24 + replacement_block * 0.32) * detail_fade);
        color = mix(color, base_color.rgb * 1.13, pale_block * masonry_strength * 0.17 * detail_fade);
		if (repair_strength > 0.001) {
			float repair_blend = clamp(v_piece_repair_blend, 0.0, 1.0);
			float repair_tone_noise = value_noise(floor(v_world_pos.xz * 1.41) + vec2(43.0, 97.0));
			vec3 host_tone = mix(repair_host_base.rgb, repair_host_accent.rgb, mineral * 0.46 + pitting * 0.18);
			vec3 replacement_tone = mix(color * vec3(0.78, 0.81, 0.73), color * vec3(1.14, 1.08, 0.91), repair_tone_noise);
			color = mix(host_tone, replacement_tone, repair_blend);
		}
        color = mix(color, base_color.rgb * 1.10, worn_edge * masonry_strength * (0.10 + v_event_runoff * 0.16) * detail_fade);
		float joint_weather = masonry_strength * v_event_runoff * (0.18 + pitting * 0.42 + mineral * 0.18);
		color = mix(color, moss_color.rgb * vec3(0.84, 0.94, 0.72), joint_weather * moss_strength * 0.48 * detail_fade);
		surface_height += masonry_strength * detail_fade * (mineral * 0.12 - pitting * 0.20 - replacement_block * 0.12 - repair_cluster * 0.22 + worn_edge * 0.06);
    }
    if (grain_strength > 0.001) {
		vec2 wood_axis = v_longest_local_axis < 0.5
			? vec2(v_local_pos.y + v_local_pos.z * 0.31, v_local_pos.x)
			: (v_longest_local_axis < 1.5
				? vec2(v_local_pos.x + v_local_pos.z * 0.31, v_local_pos.y)
				: vec2(v_local_pos.x + v_local_pos.y * 0.31, v_local_pos.z));
		float grain_noise = fbm(wood_axis * 1.55 + v_world_pos.xz * 0.025);
		float major_grain = smoothstep(0.84, 0.985, abs(sin((wood_axis.y + grain_noise * 0.055) * grain_scale + grain_noise * grain_warp)));
		float fine_grain = smoothstep(0.935, 0.998, abs(sin((wood_axis.x * 0.30 + wood_axis.y * 1.35) * grain_scale * 2.0 + grain_noise * 2.2)));
        float grain = major_grain * 0.56 + fine_grain * 0.14;
        color = mix(color, grain_color.rgb, clamp(grain * grain_strength * detail_fade, 0.0, 1.0));
		surface_height += grain * grain_strength * detail_fade * 0.12;
		float split = smoothstep(0.955, 0.992, fbm(vec2(wood_axis.y * 0.7, wood_axis.x * 5.6) * grain_scale));
        color = mix(color, grain_color.rgb * 0.58, split * grain_strength * age_strength * 0.38);
		float knot_field = value_noise(floor(wood_axis * vec2(1.7, 0.42)) + vec2(37.0, 13.0));
		float knot = smoothstep(0.955, 0.992, knot_field) * smoothstep(0.24, 0.02, abs(fract(wood_axis.y * 0.28) - 0.5));
        color = mix(color, grain_color.rgb * 0.42, knot * grain_strength * 0.72 * detail_fade);
        float end_weather = smoothstep(0.34, 0.50, max(abs(local_axis.x), abs(local_axis.y)));
        color = mix(color, color * vec3(0.72, 0.68, 0.60), end_weather * age_strength * grain_strength * 0.24 * detail_fade);
		float timber_damp = damp_strength * v_event_runoff * (0.22 + weather_noise * 0.36);
		float timber_silvering = age_strength * v_event_runoff * (0.18 + weather_noise * 0.32);
		color = mix(color, color * vec3(0.50, 0.60, 0.52), timber_damp * grain_strength * 0.40);
		color = mix(color, color * vec3(1.18, 1.12, 0.94), timber_silvering * grain_strength * 0.22);
    }
    float vertical_surface = 1.0 - smoothstep(0.45, 0.82, abs(n.y));
	float runoff_noise = fbm(vec2(sample_axis.x * 0.62, sample_axis.y * 0.075) + vec2(13.0, 41.0));
	float rain_streak = v_event_runoff * mix(0.64, 1.0, runoff_noise) * vertical_surface;
	float mineral_leach = v_event_runoff * masonry_strength * age_strength * smoothstep(0.58, 0.86, fbm(vec2(sample_axis.x * 0.24, sample_axis.y * 0.11) + vec2(7.0, 97.0)));
	color *= 1.0 - age_strength * rain_streak * 0.18;
	color = mix(color, accent_color.rgb * 0.72, mineral_leach * 0.22 * detail_fade);
	if (roof_strength > 0.001) {
		float roof_damp = v_event_runoff * (0.18 + weather_noise * 0.32);
		float roof_lichen = smoothstep(0.62, 0.90, weather_noise) * v_event_runoff;
		color = mix(color, color * vec3(0.48, 0.60, 0.56), roof_damp * roof_strength * 0.38);
		color = mix(color, moss_color.rgb * vec3(0.76, 0.92, 0.68), roof_lichen * roof_strength * 0.28);
	}
	float broad_moss = moss_strength * v_event_runoff * smoothstep(0.42, 0.74, weather_noise);
    float cobble_edge = smoothstep(0.37, 0.50, max(abs(local_axis.x), abs(local_axis.y)));
    float drainage_field = fbm(sample_axis * 0.115 + vec2(61.0, 23.0));
    float sheltered_field = fbm(sample_axis * 0.23 + vec2(101.0, 37.0));
    float drainage_pocket = smoothstep(0.57, 0.79, drainage_field) * smoothstep(0.42, 0.70, sheltered_field);
    float joint_growth = cobble_joint * smoothstep(0.30, 0.68, weather_noise) * (0.16 + cobble_edge * 0.72 + drainage_pocket * 0.52);
    float edge_growth = cobble_edge * smoothstep(0.48, 0.76, sheltered_field) * (0.24 + drainage_pocket * 0.48);
    float worn_clearance = smoothstep(0.46, 0.78, fbm(sample_axis * 0.08 + vec2(7.0, 113.0)));
	float canopy_moisture = v_event_canopy;
	float route_clearance = smoothstep(0.18, 0.64, v_event_threshold);
	float typed_deposition = max(v_event_canopy, max(v_event_root, v_event_runoff));
	float cobble_growth = cobble_strength * moss_strength * (joint_growth * 1.35 + edge_growth * 1.18 + drainage_pocket * 0.38) * typed_deposition * mix(1.0, 0.08, route_clearance);
	float moss_mask = mix(broad_moss, cobble_growth, cobble_strength);
	float litter_noise = fbm(sample_axis * 0.44 + vec2(151.0, 67.0));
	float canopy_joint_darkening = cobble_strength * canopy_moisture * (0.12 + cobble_joint * 0.34 + drainage_pocket * 0.24) * mix(1.0, 0.04, route_clearance);
	float leaf_litter = cobble_strength * smoothstep(0.54, 0.76, litter_noise) * (cobble_joint * 0.42 + cobble_edge * 0.38 + drainage_pocket * 0.48) * canopy_moisture * mix(1.0, 0.06, route_clearance);
	float soil_stain = cobble_strength * (v_event_runoff * (0.10 + cobble_edge * 0.30) + traffic_wear * 0.34) * mix(1.0, 0.45, route_clearance);
	color = mix(color, color * vec3(0.58, 0.62, 0.50), clamp(canopy_joint_darkening, 0.0, 0.42));
	color = mix(color, vec3(0.145, 0.092, 0.043), clamp(leaf_litter * 0.82 + soil_stain * 0.34, 0.0, 0.46));
    color = mix(color, moss_color.rgb, clamp(moss_mask, 0.0, 0.72));
    ALBEDO = clamp(color * face_light * mortar, vec3(0.0), vec3(1.0));
    ROUGHNESS = clamp(roughness + masonry_strength * 0.03 + moss_mask * 0.08, 0.0, 1.0);
    SPECULAR = 0.16;
	vec2 relief_gradient = vec2(dFdx(surface_height), dFdy(surface_height));
	NORMAL_MAP = vec3(clamp(0.5 - relief_gradient.x * 1.8, 0.0, 1.0), clamp(0.5 - relief_gradient.y * 1.8, 0.0, 1.0), 1.0);
	NORMAL_MAP_DEPTH = clamp((masonry_strength * 0.62 + cobble_strength * 0.78 + grain_strength * 0.34) * detail_fade, 0.0, 0.82);
}
