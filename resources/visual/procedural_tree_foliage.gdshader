shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

global uniform vec3 environment_wind_direction;
global uniform float environment_wind_strength;
global uniform float environment_wind_gust_strength;
global uniform float environment_wind_gust_frequency;
global uniform float environment_wind_time;

uniform vec4 leaf_color : source_color = vec4(0.24, 0.46, 0.16, 1.0);
uniform vec4 leaf_shadow_color : source_color = vec4(0.075, 0.18, 0.065, 1.0);
uniform float main_bend_meters : hint_range(0.0, 1.0) = 0.46;
uniform float flutter_meters : hint_range(0.0, 0.25) = 0.085;

varying float leaf_variation;

void vertex() {
    vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 wind_direction = normalize(environment_wind_direction + vec3(0.0001, 0.0, 0.0001));
    vec3 wind_tangent = vec3(-wind_direction.z, 0.0, wind_direction.x);
    float phase = INSTANCE_CUSTOM.r * 6.2831853 + COLOR.g * 6.2831853;
    float weight = clamp(INSTANCE_CUSTOM.g * COLOR.r, 0.0, 1.0);
    float spatial_phase = dot(world_position.xz, vec2(0.036, -0.029));
    float gust = 0.68 + (0.5 + 0.5 * sin(environment_wind_time * environment_wind_gust_frequency * 2.65 + phase * 1.19)) * environment_wind_gust_strength;
    float main_wave = sin(environment_wind_time * (0.82 + environment_wind_gust_frequency * 0.31) + phase + spatial_phase);
    float flutter = sin(environment_wind_time * (3.2 + environment_wind_gust_frequency * 1.9) + phase * 2.1 + spatial_phase * 1.7);
    world_position += wind_direction * main_wave * gust * environment_wind_strength * main_bend_meters * weight;
    world_position += wind_tangent * flutter * flutter_meters * weight * (environment_wind_strength * 0.42 + environment_wind_gust_strength);
    world_position.y += abs(flutter) * flutter_meters * weight * 0.14;
    VERTEX = (inverse(MODEL_MATRIX) * vec4(world_position, 1.0)).xyz;
    leaf_variation = clamp((COLOR.b + INSTANCE_CUSTOM.b) * 0.5, 0.0, 1.0);
}

void fragment() {
    if (!FRONT_FACING) {
        NORMAL = -NORMAL;
    }
    float lightness = mix(0.78, 1.16, leaf_variation);
    ALBEDO = mix(leaf_shadow_color.rgb, leaf_color.rgb * lightness, 0.58 + leaf_variation * 0.32);
    ROUGHNESS = 0.88;
}
