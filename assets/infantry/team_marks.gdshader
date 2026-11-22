shader_type spatial;
render_mode cull_disabled;

uniform sampler2D color_map : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D orm_map : filter_linear_mipmap_anisotropic;
uniform float normal_scale = 1.0;
uniform float roughness_scale = 1.0;
uniform float specular_scale = 0.5;
uniform int layout_kind;
uniform vec4 team_color : source_color = vec4(0.26, 0.52, 0.83, 0.0);

float panel(vec2 coordinate, vec2 center, vec2 half_size, float angle) {
	vec2 rotation = vec2(cos(angle), sin(angle));
	vec2 offset = coordinate - center;
	vec2 aligned = vec2(dot(offset, rotation), dot(offset, vec2(-rotation.y, rotation.x)));
	vec2 inset = half_size - abs(aligned);
	float edge = min(inset.x, inset.y);
	float pixel = max(fwidth(edge), 0.001);
	return smoothstep(-pixel, pixel, edge);
}

void fragment() {
	vec3 source = texture(color_map, UV).rgb;
	vec3 orm = texture(orm_map, UV).rgb;
	float patch;
	if (layout_kind == 2) {
		// Tint the crown. Keep the visor and the webbing adjustment strap olive.
		float crown = UV.x < 0.56
			? smoothstep(0.433, 0.449, UV.y) * (1.0 - smoothstep(0.846, 0.870, UV.y))
			: smoothstep(0.535, 0.577, UV.y) * (1.0 - smoothstep(0.803, 0.825, UV.y));
		patch = crown * 0.93;
	} else if (layout_kind == 1) {
		vec2 rear_size = vec2(0.109, 0.079);
		vec2 front_size = vec2(0.098, 0.063);
		patch = max(panel(UV, vec2(0.270, 0.231), rear_size, 0.0),
		            panel(UV, vec2(0.340, 0.900), front_size, 0.0));
	} else {
		vec2 size = vec2(0.040, 0.043);
		patch = max(panel(UV, vec2(0.101, 0.236), size, 0.48),
		            panel(UV, vec2(0.102, 0.347), size, -0.48));
	}
	float luminance = dot(source, vec3(0.2126, 0.7152, 0.0722));
	float detail = clamp(0.49 + 4.3 * luminance, 0.61, 0.90);
	vec3 dyed = mix(team_color.rgb * detail, source * 1.6, 0.20);
	ALBEDO = mix(source, dyed, patch * team_color.a);
	AO = layout_kind == 2 ? 1.0 : orm.r;
	ROUGHNESS = layout_kind == 2 ? roughness_scale : orm.g * roughness_scale;
	METALLIC = layout_kind == 2 ? 0.0 : orm.b;
	SPECULAR = specular_scale;
	NORMAL_MAP = texture(normal_map, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
}
