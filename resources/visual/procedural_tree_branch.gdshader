shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

global uniform vec3 environment_wind_direction;
global uniform float environment_wind_strength;
global uniform float environment_wind_gust_strength;
global uniform float environment_wind_gust_frequency;
global uniform float environment_wind_time;
global uniform float environment_daylight;

uniform vec4 bark_color : source_color = vec4(0.29, 0.16, 0.075, 1.0);
uniform vec4 bark_dark : source_color = vec4(0.105, 0.052, 0.022, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.91;
uniform float wind_bend_meters : hint_range(0.0, 1.0) = 0.32;
uniform bool geometry_baked_taper = false;
uniform float baked_axial_length : hint_range(0.1, 128.0) = 1.0;
uniform float baked_bark_variation : hint_range(0.0, 1.0) = 0.5;
uniform float bark_daylight_readability : hint_range(0.0, 0.50) = 0.32;

varying vec2 bark_coordinates;
varying float bark_variation;

void vertex() {
    float axial = clamp(VERTEX.y + 0.5, 0.0, 1.0);
    if (geometry_baked_taper) {
        axial = clamp(UV.y, 0.0, 1.0);
    }
    float radial_angle = atan(VERTEX.z, VERTEX.x) / 6.2831853 + 0.5;
    float physical_length = length(MODEL_MATRIX[1].xyz);
    float tip_ratio = clamp(INSTANCE_CUSTOM.r, 0.03, 1.0);
    if (!geometry_baked_taper) {
        VERTEX.xz *= mix(1.0, tip_ratio, smoothstep(0.0, 1.0, axial));
    }

    vec3 world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 wind_direction = normalize(environment_wind_direction + vec3(0.0001, 0.0, 0.0001));
    float phase = INSTANCE_CUSTOM.b * 6.2831853;
    float height_weight = INSTANCE_CUSTOM.g * smoothstep(0.0, 1.0, axial);
    float spatial_phase = dot(world_position.xz, vec2(0.028, -0.024));
    float gust = 0.68 + (0.5 + 0.5 * sin(environment_wind_time * environment_wind_gust_frequency * 2.3 + phase)) * environment_wind_gust_strength;
    float wave = sin(environment_wind_time * (0.70 + environment_wind_gust_frequency * 0.28) + phase + spatial_phase);
    world_position += wind_direction * wave * gust * environment_wind_strength * wind_bend_meters * height_weight;
    VERTEX = (inverse(MODEL_MATRIX) * vec4(world_position, 1.0)).xyz;

    bark_coordinates = vec2(
        (geometry_baked_taper ? UV.x : radial_angle) * 5.0,
        axial * max(1.0, geometry_baked_taper ? baked_axial_length : physical_length) * 0.72
    );
    bark_variation = geometry_baked_taper ? baked_bark_variation : INSTANCE_CUSTOM.a;
}

void fragment() {
    float long_furrow = sin(bark_coordinates.x * 6.2831853 + sin(bark_coordinates.y * 0.72) * 1.35);
    float fine_furrow = sin(bark_coordinates.x * 14.7 - bark_coordinates.y * 1.8) * 0.34;
    float ridges = smoothstep(-0.72, 0.86, long_furrow + fine_furrow);
    float variation = mix(0.88, 1.12, bark_variation);
    ALBEDO = mix(bark_dark.rgb, bark_color.rgb * variation, 0.34 + ridges * 0.58);
    // Dense procedural crowns can fully shadow a playable, harvestable trunk.
    // Preserve dark nights while supplying a daylight-only material floor so
    // a harvestable trunk remains visibly bark-like, rather than black, under
    // its own mature canopy at normal melee clearance.
    float daylight_readability = smoothstep(0.18, 0.68, environment_daylight);
    EMISSION = ALBEDO * bark_daylight_readability * daylight_readability;
    ROUGHNESS = roughness;
}
