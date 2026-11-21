shader_type spatial;
render_mode cull_disabled, specular_disabled, shadows_disabled;

varying float growth;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float reach = 1.0 - smoothstep(27.0, 42.0, distance(CAMERA_POSITION_WORLD.xz, origin.xz));
	growth = clamp(VERTEX.y * 3.4, 0.0, 1.0);
	float sway = sin(TIME * 1.47 + origin.x * 0.27 + origin.z * 0.21) * 0.040;
	VERTEX.x += sway * growth * growth;
	VERTEX.y *= reach;
}

void fragment() {
	ALBEDO = COLOR.rgb * mix(0.63, 1.13, growth);
	BACKLIGHT = COLOR.rgb * 0.20;
	ROUGHNESS = 0.97;
}
