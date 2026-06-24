shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float macro_scale = 0.030;
uniform float macro_strength = 0.075;
uniform float slope_rock_strength = 0.30;
uniform float side_value_strength = 0.10;
uniform float snow_start = 58.0;
uniform float snow_end = 86.0;
uniform float snow_strength = 0.32;
uniform float albedo_boost = 1.24;
uniform float shadow_fill = 0.0;
uniform int terrain_local_light_count = 0;
uniform vec4 terrain_local_light_positions[12];
uniform vec4 terrain_local_light_colors[12];
uniform float terrain_local_light_strength = 0.11;
uniform float terrain_local_light_max = 0.18;
uniform vec3 rock_tint : source_color = vec3(0.44, 0.47, 0.43);
uniform vec3 snow_tint : source_color = vec3(0.86, 0.90, 0.86);
uniform float roughness_value = 0.90;
uniform float specular_value = 0.14;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

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

vec3 terrain_local_light(vec3 world_pos, vec3 normal_world) {
    vec3 total = vec3(0.0);
    float upness = smoothstep(0.06, 0.46, normal_world.y);
    for (int i = 0; i < 12; i++) {
        if (i >= terrain_local_light_count) {
            break;
        }
        vec4 light_pos_range = terrain_local_light_positions[i];
        vec4 light_color_energy = terrain_local_light_colors[i];
        vec3 to_light = light_pos_range.xyz - world_pos;
        float light_range = max(light_pos_range.w, 0.001);
        float dist = length(to_light);
        float distance_falloff = clamp(1.0 - dist / light_range, 0.0, 1.0);
        distance_falloff *= distance_falloff;
        vec3 light_dir = to_light / max(dist, 0.001);
        float wrapped = clamp((dot(normal_world, light_dir) + 0.35) / 1.35, 0.0, 1.0);
        total += light_color_energy.rgb * light_color_energy.a * distance_falloff * wrapped * upness;
    }
    return min(total * terrain_local_light_strength, vec3(terrain_local_light_max));
}

void vertex() {
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
    vec3 normal_world = normalize(v_world_normal);
    float upness = clamp(normal_world.y, 0.0, 1.0);
    float slope = 1.0 - upness;
    float macro = value_noise(v_world_pos.xz * macro_scale);
    float macro_value = mix(1.0 - macro_strength, 1.0 + macro_strength, macro);

    vec3 color = COLOR.rgb;
    float rock_mix = smoothstep(0.34, 0.86, slope) * slope_rock_strength;
    color = mix(color, rock_tint, rock_mix);

    float altitude = smoothstep(snow_start, snow_end, v_world_pos.y);
    float cold_face = smoothstep(0.12, 0.72, upness);
    color = mix(color, snow_tint, altitude * cold_face * snow_strength);

    float side_value = mix(1.0 - side_value_strength, 1.0, upness);
    vec3 final_color = clamp(color * macro_value * side_value * albedo_boost, vec3(0.0), vec3(1.0));
    ALBEDO = final_color;
    EMISSION = final_color * shadow_fill + final_color * terrain_local_light(v_world_pos, normal_world);
    ROUGHNESS = roughness_value;
    SPECULAR = specular_value;
}
