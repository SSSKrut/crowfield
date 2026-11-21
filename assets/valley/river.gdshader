shader_type spatial;
render_mode cull_disabled, shadows_disabled, specular_disabled;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz;
	vec2 flow = p - vec2(TIME * 0.53, 0.0);
	float broad = sin(dot(flow, vec2(0.89, 3.24)) + sin(flow.x * 0.49 + flow.y) + 0.5 * sin(flow.x * 0.72 - flow.y * 1.1)) * 0.46;
	float ripples = sin(dot(flow, vec2(2.33, -4.11))) * 0.25;
	float current = sin(dot(flow, vec2(0.21, 5.52)) + sin(dot(flow, vec2(0.26, 1.91)))) * 0.29;
	float glint = pow(max(0.0, broad + ripples + current), 3.6);
	float broken = 0.45 + 0.55 * sin(p.x * 0.24 + sin(p.y * 0.51)) * sin(p.y * 0.40 + p.x * 0.26);
	float rim = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 3.0);
	float center = sin(0.031 * p.x) * 7.0;
	float shore = smoothstep(5.7, 8.2, abs(p.y - center) + broad * 0.32);
	ALBEDO = mix(vec3(0.075, 0.185, 0.207), vec3(0.23, 0.34, 0.35), rim * 0.75 + shore * 0.15);
	ALBEDO += vec3(0.11, 0.16, 0.15) * glint * broken;
	EMISSION = vec3(0.025, 0.041, 0.044) * (0.45 + glint * broken);
	NORMAL_MAP = vec3(0.50 + broad * 0.08, 0.50 + current * 0.09, 0.95);
	ROUGHNESS = 0.34 + shore * 0.19;
	ALPHA = clamp(0.66 + rim * 0.27 + glint * 0.14 - shore * 0.17, 0.0, 1.0);
}
