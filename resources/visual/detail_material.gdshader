shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float tint_strength : hint_range(0.0, 1.0) = 0.28;
uniform float wind_strength : hint_range(0.0, 0.08) = 0.0;

void vertex() {
    float wind_weight = clamp(UV2.x, 0.0, 1.0);
    float phase = INSTANCE_CUSTOM.x * 6.2831853;
    float sway = sin(TIME * 1.35 + phase + VERTEX.x * 2.7 + VERTEX.z * 1.9) * wind_strength * wind_weight;
    VERTEX.x += sway;
}

void fragment() {
    vec3 tint = mix(vec3(1.0), COLOR.rgb, tint_strength);
    ALBEDO = base_color.rgb * tint;
    ROUGHNESS = roughness;
}
