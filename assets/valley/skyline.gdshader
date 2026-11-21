shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform sampler2D meadow : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D shale : source_color, filter_linear_mipmap, repeat_enable;

varying vec3 landscape_position;
varying vec3 landscape_normal;

void vertex() {
	landscape_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	landscape_normal = mat3(MODEL_MATRIX) * NORMAL;
}

void fragment() {
	vec3 normal = normalize(landscape_normal);
	vec2 land = landscape_position.xz;
	vec2 diagonal = vec2(dot(land, vec2(0.88, 0.48)), dot(land, vec2(-0.48, 0.88)));
	float canopy = texture(meadow, diagonal * 0.024).r;
	float rock_detail = texture(shale, diagonal * 0.059).r;
	float tree_cover = smoothstep(0.31, 0.57, COLOR.r + (canopy - 0.5) * 0.56);
	float exposed = smoothstep(0.15, 0.41, 1.0 - normal.y + COLOR.g * 0.20 + (rock_detail - 0.5) * 0.18);
	vec3 heath = mix(vec3(0.24, 0.30, 0.21), vec3(0.36, 0.36, 0.25), COLOR.g);
	vec3 woodland = vec3(0.141, 0.220, 0.172) * (0.67 + 0.70 * canopy);
	vec3 rock = vec3(0.40, 0.405, 0.35) * (0.77 + 0.47 * rock_detail);
	vec3 local = mix(mix(heath, woodland, tree_cover), rock, exposed);
	float diffuse = max(0.0, dot(normal, vec3(0.72, 0.38, 0.58)));
	local *= 0.79 + diffuse * 0.41;
	float edge = 1.0 - smoothstep(130.0, 252.0, length(land));
	local = mix(local, vec3(0.42, 0.49, 0.40), edge * 0.52);
	float distance_from_view = distance(CAMERA_POSITION_WORLD, landscape_position);
	float haze = 1.0 - exp(-distance_from_view * 0.00158);
	vec3 distant_air = mix(vec3(0.44, 0.53, 0.54), vec3(0.46, 0.57, 0.65), COLOR.b);
	ALBEDO = mix(local, distant_air, haze);
}
