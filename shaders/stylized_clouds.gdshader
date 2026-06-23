shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform vec3 cloud_tint : source_color = vec3(1.0, 0.94, 0.80);
uniform float alpha = 0.36;

void fragment() {
    ALBEDO = cloud_tint * COLOR.rgb;
    ALPHA = alpha * COLOR.a;
}
