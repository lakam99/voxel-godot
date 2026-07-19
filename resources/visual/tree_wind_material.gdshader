shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

global uniform vec3 environment_wind_direction;
global uniform float environment_wind_strength;
global uniform float environment_wind_gust_strength;
global uniform float environment_wind_gust_frequency;
global uniform float environment_wind_time;

uniform vec4 base_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.82;
uniform float main_bend_meters : hint_range(0.0, 1.0) = 0.48;
uniform float detail_flutter_meters : hint_range(0.0, 0.2) = 0.075;
uniform float bark_enabled : hint_range(0.0, 1.0) = 0.0;
uniform vec4 bark_accent_color : source_color = vec4(0.16, 0.08, 0.035, 1.0);
uniform float bark_grain_contrast : hint_range(0.0, 1.0) = 0.38;

instance uniform float tree_phase = 0.0;
instance uniform float tree_stiffness : hint_range(0.5, 1.5) = 1.0;
instance uniform float tree_response : hint_range(0.0, 2.0) = 1.0;
instance uniform vec2 bark_scale = vec2(1.0);

void vertex() {
    vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 wind_direction = normalize(environment_wind_direction + vec3(0.0001, 0.0, 0.0001));
    vec3 wind_tangent = vec3(-wind_direction.z, 0.0, wind_direction.x);
    float bend_weight = clamp(COLOR.r, 0.0, 1.0);
    float authored_phase = COLOR.g * 6.2831853;
    float flutter_weight = clamp(COLOR.b, 0.0, 1.0);
    float spatial_phase = dot(world_position.xz, vec2(0.031, -0.027));
    float main_wave = sin(environment_wind_time * (0.72 + environment_wind_gust_frequency * 0.32) + tree_phase + spatial_phase);
    float gust_wave = 0.5 + 0.5 * sin(environment_wind_time * environment_wind_gust_frequency * 2.7 + tree_phase * 1.37 + spatial_phase * 0.63);
    float response = tree_response / max(tree_stiffness, 0.25);
    float main_offset = bend_weight * main_bend_meters * environment_wind_strength * response;
    main_offset *= main_wave * (0.72 + gust_wave * environment_wind_gust_strength);
    float flutter = sin(environment_wind_time * (2.8 + environment_wind_gust_frequency * 2.2) + authored_phase + tree_phase * 1.71 + spatial_phase * 2.0);
    float flutter_offset = flutter_weight * detail_flutter_meters * response;
    flutter_offset *= flutter * (environment_wind_strength * 0.42 + environment_wind_gust_strength);
    world_position += wind_direction * main_offset;
    world_position += wind_tangent * flutter_offset;
    world_position.y += abs(flutter_offset) * 0.18;
    VERTEX = (inverse(MODEL_MATRIX) * vec4(world_position, 1.0)).xyz;
}

void fragment() {
    vec2 bark_uv = UV * bark_scale;
    float long_grain = sin(bark_uv.x * 31.415926 + sin(bark_uv.y * 1.65) * 1.18);
    float fine_grain = sin(bark_uv.x * 75.398224 + bark_uv.y * 3.4) * 0.32;
    float furrow = smoothstep(0.02, 0.82, 0.5 + 0.5 * (long_grain + fine_grain));
    vec3 bark_color = mix(bark_accent_color.rgb, base_color.rgb, 0.46 + furrow * bark_grain_contrast);
    ALBEDO = mix(base_color.rgb, bark_color, bark_enabled);
    ROUGHNESS = roughness;
}
