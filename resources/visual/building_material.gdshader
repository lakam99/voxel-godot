shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.6, 0.6, 0.55, 1.0);
uniform vec4 accent_color : source_color = vec4(0.45, 0.45, 0.42, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.86;
uniform float breakup_strength : hint_range(0.0, 0.45) = 0.16;
uniform float grid_strength : hint_range(0.0, 0.35) = 0.10;
uniform float scale = 2.4;

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

void vertex() {
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
    vec3 n = normalize(v_world_normal);
    vec2 sample_axis = abs(n.y) > 0.55 ? v_world_pos.xz : (abs(n.x) > abs(n.z) ? v_world_pos.zy : v_world_pos.xy);
    float noise_value = value_noise(sample_axis * scale);
    float face_light = mix(0.88, 1.08, clamp(n.y * 0.5 + 0.5, 0.0, 1.0));
    vec2 grid = abs(fract(sample_axis * 0.72) - vec2(0.5));
    float mortar = 1.0 - smoothstep(0.45, 0.50, max(grid.x, grid.y)) * grid_strength;
    vec3 color = mix(base_color.rgb, accent_color.rgb, noise_value * breakup_strength);
    ALBEDO = clamp(color * face_light * mortar, vec3(0.0), vec3(1.0));
    ROUGHNESS = roughness;
    SPECULAR = 0.16;
}
