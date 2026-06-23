shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.22, 0.68, 0.72);
uniform vec3 deep_color : source_color = vec3(0.06, 0.34, 0.54);
uniform vec3 foam_color : source_color = vec3(0.72, 0.90, 0.86);
uniform vec3 overcast_tint : source_color = vec3(0.34, 0.62, 0.64);
uniform vec3 sunset_tint : source_color = vec3(0.96, 0.58, 0.36);
uniform float cloud_cover = 0.22;
uniform float weather_intensity = 0.0;
uniform float day_factor = 1.0;
uniform float sunset_warmth = 0.0;
uniform float wave_time = 0.0;
uniform float wave_scale_a = 0.060;
uniform float wave_scale_b = 0.135;
uniform float wave_height = 0.045;
uniform float alpha_base = 0.90;
uniform float fresnel_strength = 0.08;
uniform float roughness_value = 0.82;
uniform float specular_value = 0.14;

varying vec3 v_world_pos;
varying float v_wave_mix;

float hash21(vec2 p) {
    p = fract(p * vec2(127.1, 311.7));
    p += dot(p, p + 37.17);
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
    vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float wave_a = sin((world.x + wave_time * 5.5) * wave_scale_a + world.z * 0.025);
    float wave_b = cos((world.z - wave_time * 3.4) * wave_scale_b + world.x * 0.040);
    float wave = wave_a * 0.58 + wave_b * 0.42;
    VERTEX.y += wave * wave_height;
    v_wave_mix = wave * 0.5 + 0.5;
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    float broad = value_noise(v_world_pos.xz * 0.018 + vec2(wave_time * 0.004, -wave_time * 0.003));
    float small = value_noise(v_world_pos.xz * 0.105 + vec2(-wave_time * 0.018, wave_time * 0.013));
    float depth_mix = smoothstep(0.22, 0.92, broad * 0.72 + small * 0.28);
    vec3 color = mix(shallow_color, deep_color, depth_mix);

    float weather_mix = clamp(cloud_cover * 0.26 + weather_intensity * 0.22, 0.0, 0.46);
    color = mix(color, overcast_tint, weather_mix);
    color = mix(color, sunset_tint, clamp(sunset_warmth * 0.18, 0.0, 0.24));
    color *= mix(0.58, 1.0, day_factor);

    float foam = smoothstep(0.78, 0.98, small) * (0.06 + weather_intensity * 0.08);
    float wave_glint = smoothstep(0.70, 1.0, v_wave_mix) * 0.04 * day_factor;
    color = mix(color, foam_color, foam + wave_glint);

    float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.4);
    ALBEDO = color;
    ALPHA = clamp(alpha_base + fresnel * fresnel_strength - weather_intensity * 0.04, 0.78, 0.95);
    ROUGHNESS = roughness_value;
    SPECULAR = specular_value;
}
