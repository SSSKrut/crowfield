shader_type spatial;
render_mode cull_disabled;

uniform sampler2D color_map : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D orm_map : filter_linear_mipmap_anisotropic;
uniform float normal_scale = 1.0;
uniform float roughness_scale = 1.0;
uniform float specular_scale = 0.5;
uniform bool vest;
instance uniform vec4 team_color : source_color = vec4(0.26, 0.52, 0.83, 0.0);

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
	// Recolor the existing rectangular sleeve and plate insignia in the atlas.
	float patch = vest
		? max(panel(UV, vec2(0.270, 0.275), vec2(0.060, 0.026), 0.0),
		      panel(UV, vec2(0.340, 0.933), vec2(0.062, 0.017), 0.0))
		: max(panel(UV, vec2(0.101, 0.236), vec2(0.023, 0.021), 0.48),
		      panel(UV, vec2(0.102, 0.347), vec2(0.022, 0.022), -0.48));
	float detail = clamp(0.55 + 3.0 * dot(source, vec3(0.2126, 0.7152, 0.0722)), 0.62, 0.92);
	ALBEDO = mix(source, team_color.rgb * detail, patch * team_color.a);
	AO = orm.r;
	ROUGHNESS = orm.g * roughness_scale;
	METALLIC = orm.b;
	SPECULAR = specular_scale;
	NORMAL_MAP = texture(normal_map, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
}
