shader_type spatial;
render_mode cull_disabled;

uniform sampler2D color_map : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D orm_map : filter_linear_mipmap_anisotropic;
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
	// Atlas tiles are in the same order as PARTS in source/outfit_atlas.py.
	vec2 tile_uv = UV * vec2(4.0, 2.0);
	vec2 tile = floor(tile_uv);
	int layout_kind = int(tile.x + tile.y * 4.0);
	vec2 authored_uv = (fract(tile_uv) - 0.015625) / 0.96875;
	float patch = 0.0;
	if (layout_kind == 5) {
		// Tint the crown. Keep the visor and the webbing adjustment strap olive.
		float crown = authored_uv.x < 0.56
			? smoothstep(0.433, 0.449, authored_uv.y) * (1.0 - smoothstep(0.846, 0.870, authored_uv.y))
			: smoothstep(0.535, 0.577, authored_uv.y) * (1.0 - smoothstep(0.803, 0.825, authored_uv.y));
		patch = crown * 0.93;
	} else if (layout_kind == 3) {
		vec2 rear_size = vec2(0.109, 0.079);
		vec2 front_size = vec2(0.098, 0.063);
		patch = max(panel(authored_uv, vec2(0.270, 0.231), rear_size, 0.0),
		            panel(authored_uv, vec2(0.340, 0.900), front_size, 0.0));
	} else if (layout_kind == 4) {
		vec2 size = vec2(0.040, 0.043);
		patch = max(panel(authored_uv, vec2(0.101, 0.236), size, 0.48),
		            panel(authored_uv, vec2(0.102, 0.347), size, -0.48));
	}
	float luminance = dot(source, vec3(0.2126, 0.7152, 0.0722));
	float detail = clamp(0.49 + 4.3 * luminance, 0.61, 0.90);
	vec3 dyed = mix(team_color.rgb * detail, source * 1.6, 0.20);
	ALBEDO = mix(source, dyed, patch * team_color.a);
	AO = orm.r;
	ROUGHNESS = orm.g;
	METALLIC = orm.b;
	SPECULAR = 0.5;
	NORMAL_MAP = texture(normal_map, UV).rgb;
	if (layout_kind == 1) {
		NORMAL_MAP_DEPTH = 0.57143;
	} else if (layout_kind == 2) {
		NORMAL_MAP_DEPTH = 0.82743;
	} else if (layout_kind == 4 || layout_kind == 6) {
		NORMAL_MAP_DEPTH = 0.85791;
	} else {
		NORMAL_MAP_DEPTH = 1.0;
	}
}
