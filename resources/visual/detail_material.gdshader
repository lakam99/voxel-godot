shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float tint_strength : hint_range(0.0, 1.0) = 0.28;
uniform float wind_strength : hint_range(0.0, 0.08) = 0.0;

global uniform vec3 environment_wind_direction;
global uniform float environment_wind_strength;
global uniform float environment_wind_gust_strength;
global uniform float environment_wind_gust_frequency;
global uniform float environment_wind_time;

void vertex() {
    float wind_weight = clamp(UV2.x, 0.0, 1.0);
    float phase = INSTANCE_CUSTOM.x * 6.2831853;
    vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 wind_direction = normalize(environment_wind_direction + vec3(0.0001, 0.0, 0.0001));
    float spatial_phase = dot(world_position.xz, vec2(0.083, -0.071));
    float sway = sin(environment_wind_time * (1.05 + environment_wind_gust_frequency * 0.55) + phase + spatial_phase);
    float gust = 0.5 + 0.5 * sin(environment_wind_time * environment_wind_gust_frequency * 3.1 + phase * 1.7 + spatial_phase * 0.65);
    float response = 0.58 + environment_wind_strength * 1.15 + gust * environment_wind_gust_strength;
    world_position += wind_direction * sway * wind_strength * wind_weight * response;
    VERTEX = (inverse(MODEL_MATRIX) * vec4(world_position, 1.0)).xyz;
}

void fragment() {
    vec3 tint = mix(vec3(1.0), COLOR.rgb, tint_strength);
    ALBEDO = base_color.rgb * tint;
    ROUGHNESS = roughness;
}
