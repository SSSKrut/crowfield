shader_type spatial;
render_mode specular_disabled;

// The vertex colour carries how worn the ground is in red, a slow variation of
// the sand in green and how steep it is in blue, as on the valley.
uniform sampler2D sand : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D hardpan : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stone : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz;
	vec2 diagonal = vec2(dot(p, vec2(0.91, 0.41)), dot(p, vec2(-0.41, 0.91)));
	vec3 broad = texture(sand, diagonal * 0.045).rgb;
	vec3 grain = texture(sand, p * 0.31).rgb;
	float pan_grain = texture(hardpan, p * 0.17).r;
	float stone_grain = texture(stone, diagonal * 0.3).r;
	// Wind ripples run across the open sand and fade where it is worn.
	float ripple = sin(dot(p, vec2(0.83, 0.55)) * 3.1 + sin(p.y * 0.37 + p.x * 0.11) * 1.7);
	float bare = smoothstep(0.22, 0.82, COLOR.r + (pan_grain - 0.5) * 0.37);
	float rock = smoothstep(0.25, 0.85, COLOR.b + (stone_grain - 0.5) * 0.25);

	vec3 dune = mix(vec3(0.60, 0.45, 0.29), vec3(0.72, 0.57, 0.38), COLOR.g);
	dune *= 0.60 + 0.46 * dot(broad, vec3(0.333)) + 0.36 * dot(grain, vec3(0.333));
	dune *= 1.0 + 0.05 * ripple * (1.0 - bare);
	vec3 pan = vec3(0.55, 0.44, 0.33) * (0.74 + 0.48 * pan_grain);
	vec3 rocky = vec3(0.50, 0.37, 0.27) * (0.66 + 0.62 * stone_grain);

	ALBEDO = mix(mix(dune, pan, bare), rocky, rock);
	ROUGHNESS = 0.96;
}
