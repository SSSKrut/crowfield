shader_type spatial;
render_mode specular_disabled;

uniform sampler2D meadow : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D track : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D shale : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz;
	vec2 diagonal = vec2(dot(p, vec2(0.91, 0.41)), dot(p, vec2(-0.41, 0.91)));
	float field = sin(p.x * 0.16 + p.y * 0.11) * sin(p.x * 0.08 - p.y * 0.13);
	float grass_grain = texture(meadow, diagonal * 0.31).r;
	float rut_grain = texture(track, p * 0.42).r;
	float stone_grain = texture(shale, diagonal * 0.34).r;
	float bare = smoothstep(0.22, 0.82, COLOR.r + (rut_grain - 0.5) * 0.37);
	float rock = smoothstep(0.19, 0.85, COLOR.b + (stone_grain - 0.5) * 0.25);
	float wet_bank = smoothstep(-0.18, -1.40, world_position.y);

	vec3 grass = mix(vec3(0.17, 0.22, 0.16), vec3(0.31, 0.35, 0.21), COLOR.g);
	grass *= 0.80 + 0.64 * grass_grain + 0.11 * field;
	vec3 dirt = vec3(0.38, 0.32, 0.23) * (0.72 + 0.57 * rut_grain);
	vec3 damp = vec3(0.21, 0.23, 0.19) * (0.7 + 0.60 * rut_grain);
	vec3 stone = vec3(0.32, 0.34, 0.32) * (0.68 + 0.67 * stone_grain);

	ALBEDO = mix(mix(mix(grass, dirt, bare), damp, wet_bank), stone, rock);
	ROUGHNESS = mix(0.94, 0.77, wet_bank);
}
