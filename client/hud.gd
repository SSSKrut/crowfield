class_name Hud
extends Control
## Hud draws the client's screen over the world: the crosshair or the scope,
## the weapon and its rounds, health, the death screen, the feedback of
## combat, the information lines, the network graph and the messages of the
## connection. The app sets the fields every frame and calls queue_redraw().
## Sizes are those of a 720 pixels high screen, scaled to the viewport.

const _Feedback := preload("res://client/feedback.gd")
const _BODY := preload("res://assets/type/Barlow-Medium.ttf")
const _DISPLAY := preload("res://assets/type/BarlowCondensed-Bold.ttf")

const TEAM_COLORS := {Game.Team.BLUE: Color8(60, 110, 220), Game.Team.RED: Color8(210, 70, 60)}
## NO_TEAM_COLOR is the accent used before a soldier joins a team.
const NO_TEAM_COLOR := Color8(202, 147, 55)

const WHITE := Color8(245, 244, 232)
const LIGHT_GRAY := Color8(200, 200, 200)
const GOLD := Color8(235, 198, 123)
const ORANGE := Color8(255, 161, 0)
const RED := Color8(230, 41, 55)
const YELLOW := Color8(253, 249, 0)
const PANEL := Color8(14, 24, 29, 222)
const PANEL_EDGE := Color8(121, 146, 149, 112)
const INK := Color8(12, 17, 21, 235)
const COMBAT_STRIP := Color8(34, 38, 43, 232)
const FLAG_CELL := Color8(20, 24, 29)
const STRIP_HEIGHT := 22.0
const FLAG_CELL_WIDTH := 31.0
## BASELINE is where text sits below its top, as a share of its size.
const BASELINE := 0.8

## lines are the information lines in the top left corner.
var lines: PackedStringArray = []
## arsenal is the player's predicted weapons, null before its soldier exists.
var arsenal: Arsenal
var weapons: WeaponSet
## spread is the cone of the next shot in radians, fov the field of view of
## the world camera in degrees, and aim how far the weapon is at the sights,
## from 0 to 1; scoped replaces the crosshair with the view of a scope.
var spread := 0.0
var fov := 75.0
var aim := 0.0
var scoped := false
## health and the ticks left until the respawn of a dead soldier, shown while
## the player has a soldier.
var health := 0
var respawn_ticks := 0
var has_soldier := false
var dead := false
var team: int = Game.Team.NONE
var team_colors := TEAM_COLORS
var feedback: _Feedback
## view_yaw is where the player looks, for the direction of hits.
var view_yaw := 0.0
## net_graph is shown when set; jumps are the clock jumps of the session.
var net_graph: NetGraph
var jumps := 0
## reconnect_lines tell of a lost connection; empty while there is none.
var reconnect_lines: PackedStringArray = []
var match_state: MatchState
var scoreboard_open := false:
	set(value):
		if value and not scoreboard_open:
			_scoreboard_page = 0
		scoreboard_open = value
var _scoreboard_session := -1
var _scoreboard_revision := -1
var _scoreboard_complete := false
var _scoreboard_local := -1
var _scoreboard_page := 0
var _scoreboard_teams: Array[Array] = [[], []]
var _scoreboard_duplicates: Dictionary[String, int] = {}
var replay_available := false
var reinforcement := ""
var map_scene: MapScene
var feet := Vector3.ZERO
## vehicle is the tank the player drives, or null; gun_marker is where on the
## screen its gun points, off the screen when it points behind; prompt is a
## hint under the middle of the screen.
var vehicle: Vehicle
var gun_marker := Vector2(-1, -1)
var prompt := ""

var _font: Font
var _scale := 1.0


func _init() -> void:
	name = "Hud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = _BODY


## Keep projected flag names clear of the score strip.
func flag_label_exclusion() -> Rect2:
	var layout_scale := _layout_scale()
	return _score_strip(layout_scale).grow(13 * layout_scale)


func _layout_scale() -> float:
	return clampf(size.y / 720.0, 0.75, 4.0)


func _score_strip(layout_scale: float) -> Rect2:
	var width := clampf(size.x * 0.36, 180 * layout_scale, 460 * layout_scale)
	width = minf(width, size.x)
	return Rect2((size.x - width) / 2, size.y * 0.03, width, STRIP_HEIGHT * layout_scale)


func _draw() -> void:
	_scale = _layout_scale()
	if scoreboard_open:
		_draw_scoreboard()
		return
	if vehicle != null:
		_draw_crosshair()
		_draw_vehicle()
	elif arsenal != null:
		if scoped:
			_draw_scope()
		else:
			_draw_crosshair()
		_draw_arsenal()
	if has_soldier:
		if dead:
			_draw_death()
		else:
			_draw_health()
	if feedback != null:
		_draw_feedback()
	for i in lines.size():
		_text(lines[i], Vector2(18, 18 + 26 * i) * _scale, 18, WHITE)
	if net_graph != null:
		net_graph.draw(self, _font, jumps, Vector2(18, size.y / _scale - (2 * 70 + 150)) * _scale, _scale)
	if not reconnect_lines.is_empty():
		for i in reconnect_lines.size():
			_text(reconnect_lines[i], Vector2(18, 160 + 28 * i) * _scale, 22, ORANGE)
	if match_state != null and map_scene != null:
		_draw_match()
	if prompt != "":
		_centered(prompt, Vector2(size.x / 2, size.y * 0.7), 19, WHITE)


func _draw_match() -> void:
	var strip := _score_strip(_scale)
	var blue_flags := 0
	var red_flags := 0
	for flag in match_state.flags:
		blue_flags += int(flag.owner == Game.Team.BLUE)
		red_flags += int(flag.owner == Game.Team.RED)
	var cell_width := FLAG_CELL_WIDTH * _scale
	var track_width := strip.size.x * 0.5 - cell_width
	var track_left := strip.position.x + cell_width
	var track_right := strip.end.x - cell_width
	var text_y := strip.position.y + 3 * _scale
	var blue_fill := team_color(Game.Team.BLUE).darkened(0.22)
	var red_fill := team_color(Game.Team.RED).darkened(0.22)
	var blue_length := track_width * _score_share(match_state.blue_score)
	var red_length := track_width * _score_share(match_state.red_score)
	draw_rect(strip, COMBAT_STRIP)
	draw_rect(Rect2(track_left, strip.position.y, blue_length, strip.size.y), blue_fill)
	draw_rect(Rect2(track_right - red_length, strip.position.y, red_length, strip.size.y), red_fill)
	draw_rect(Rect2(track_left + track_width, strip.position.y, _scale, strip.size.y), FLAG_CELL)
	draw_rect(Rect2(strip.position, Vector2(cell_width, strip.size.y)), FLAG_CELL)
	draw_rect(Rect2(track_right, strip.position.y, cell_width, strip.size.y), FLAG_CELL)
	_draw_flag_count(Vector2(strip.position.x + cell_width / 2, text_y), blue_flags, Game.Team.BLUE)
	_draw_flag_count(Vector2(strip.end.x - cell_width / 2, text_y), red_flags, Game.Team.RED)
	_centered(str(match_state.blue_score), Vector2(track_left + track_width / 2, text_y), 16, WHITE, _DISPLAY)
	_centered(str(match_state.red_score), Vector2(track_right - track_width / 2, text_y), 16, WHITE, _DISPLAY)

	if match_state.result != MatchState.Result.ACTIVE:
		_draw_result()
	elif has_soldier and not dead:
		_draw_objective_context()


static func _score_share(score: int) -> float:
	return clampf(float(score) / MatchState.SCORE_TO_WIN, 0.0, 1.0)


func _draw_flag_count(center: Vector2, count: int, side: int) -> void:
	var tint := team_color(side).lightened(0.50)
	_box(center, -10, 4, 1, 9, tint)
	_box(center, -9, 4, 5, 5, tint)
	_text(str(count), center, 16, tint, _DISPLAY)


func _draw_objective_context() -> void:
	for index in map_scene.flags.size():
		var zone := map_scene.flags[index]
		if not zone.contains_flag_position(feet):
			continue
		var flag := match_state.flags[index]
		if not flag.contested and (flag.challenger != team or team == Game.Team.NONE or flag.owner == team):
			continue
		var tint := GOLD if flag.contested else team_color(team).lightened(0.50)
		var verb := "Contesting" if flag.contested else "Capturing"
		var center := Vector2(size.x * 0.5, size.y * 0.80)
		var track_width := clampf(size.x * 0.18 / _scale, 126, 230)
		_centered("%s %s" % [verb, zone.name], center, 17, WHITE, _DISPLAY)
		_box(center, -track_width / 2, 21, track_width, 3, COMBAT_STRIP)
		_box(center, -track_width / 2, 21, track_width * flag.progress / 100, 3, tint)
		return
	if not reinforcement.is_empty():
		_centered(reinforcement, Vector2(size.x * 0.5, size.y * 0.80), 16, WHITE)


func _match_clock() -> String:
	return "%d:%02d" % [match_state.seconds / 60, match_state.seconds % 60]


func sync_scoreboard(session: ClientSession) -> void:
	var id := session.get_instance_id()
	if id == _scoreboard_session and session.scoreboard_revision == _scoreboard_revision:
		return
	_scoreboard_session = id
	_scoreboard_revision = session.scoreboard_revision
	_scoreboard_complete = session.scoreboard_complete
	_scoreboard_local = session.welcome.player
	for rows in _scoreboard_teams:
		rows.clear()
	_scoreboard_duplicates.clear()
	if not _scoreboard_complete:
		return
	for row in session.scoreboard_rows.values():
		_scoreboard_teams[row.team - Game.Team.BLUE].append(row)
		if not row.is_bot():
			var key := _scoreboard_name(row).to_lower()
			_scoreboard_duplicates[key] = _scoreboard_duplicates.get(key, 0) + 1
	for rows in _scoreboard_teams:
		rows.sort_custom(_scoreboard_order)
	_scoreboard_page = mini(_scoreboard_page, _scoreboard_pages() - 1)


func turn_scoreboard_page(direction: int) -> void:
	_scoreboard_page = clampi(_scoreboard_page + direction, 0, _scoreboard_pages() - 1)


func _scoreboard_order(a: ScoreboardUpdate.Row, b: ScoreboardUpdate.Row) -> bool:
	if (a.id == _scoreboard_local) != (b.id == _scoreboard_local):
		return a.id == _scoreboard_local
	if a.kills != b.kills:
		return a.kills > b.kills
	if a.deaths != b.deaths:
		return a.deaths < b.deaths
	return a.id < b.id


func _scoreboard_rows_per_page() -> int:
	var layout_scale := clampf(size.y / 720.0, 0.75, 4.0)
	return clampi(floori((size.y / layout_scale - 168) / 21.0), 1, 24)


func _scoreboard_pages() -> int:
	var team_size := maxi(_scoreboard_teams[0].size(), _scoreboard_teams[1].size())
	return maxi(1, ceili(float(team_size) / _scoreboard_rows_per_page()))


func _draw_scoreboard() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color8(8, 13, 16, 105))
	if not _scoreboard_complete:
		_centered("Loading scoreboard…", size * 0.5, 24, WHITE, _DISPLAY)
		return
	var width := minf(804, size.x / _scale - 32)
	var team_size := maxi(_scoreboard_teams[0].size(), _scoreboard_teams[1].size())
	var page_size := _scoreboard_rows_per_page()
	var height := 128 + 21 * mini(page_size, team_size)
	var panel := (size - Vector2(width, height) * _scale) * 0.5
	_draw_scoreboard_shade(panel.y, panel.y + height * _scale)
	_text("Scoreboard", panel, 28, WHITE, _DISPLAY)
	if match_state != null:
		var clock := _match_clock()
		_text(clock, panel + Vector2(width * _scale - _measure(clock, 20, _DISPLAY), 5 * _scale), 20, LIGHT_GRAY, _DISPLAY)
	var team_width := (width - 32) / 2.0
	var page := mini(_scoreboard_page, _scoreboard_pages() - 1)
	_draw_scoreboard_team(panel, team_width, Game.Team.BLUE, page, page_size)
	_draw_scoreboard_team(panel + Vector2((team_width + 32) * _scale, 0), team_width, Game.Team.RED, page, page_size)
	var footer := panel + Vector2(0, height - 18) * _scale
	if _scoreboard_pages() > 1:
		_text("Wheel or Page Up / Down", footer, 15, LIGHT_GRAY)
		_centered("%d / %d" % [page + 1, _scoreboard_pages()], Vector2(size.x * 0.5, footer.y), 16, WHITE, _DISPLAY)
	var close_hint := "Release Tab"
	_text(close_hint, footer + Vector2(width * _scale - _measure(close_hint, 15), 0), 15, LIGHT_GRAY)


func _draw_scoreboard_team(panel: Vector2, width: float, side: int, page: int, page_size: int) -> void:
	var tint := team_color(side).lightened(0.48)
	var right := panel.x + width * _scale
	var kill_x := right - 68 * _scale
	var death_x := right - 19 * _scale
	var rows: Array = _scoreboard_teams[side - Game.Team.BLUE]
	_text(Game.team_name(side).capitalize(), panel + Vector2(0, 39) * _scale, 24, tint, _DISPLAY)
	if match_state != null:
		var score := str(match_state.blue_score if side == Game.Team.BLUE else match_state.red_score)
		_text(score, Vector2(right - _measure(score, 24, _DISPLAY), panel.y + 39 * _scale), 24, tint, _DISPLAY)
	_box(panel, 0, 70, width, 1, tint)
	var labels_y := panel.y + 76 * _scale
	_text("Name", Vector2(panel.x, labels_y), 14, LIGHT_GRAY)
	_centered("Kills", Vector2(kill_x, labels_y), 14, LIGHT_GRAY)
	_centered("Deaths", Vector2(death_x, labels_y), 14, LIGHT_GRAY)
	var tag_x := kill_x - 49 * _scale
	var start := page * page_size
	var end := mini(rows.size(), start + page_size)
	for index in range(start, end):
		var row: ScoreboardUpdate.Row = rows[index]
		var y := panel.y + (98 + (index - start) * 21) * _scale
		var own := row.id == _scoreboard_local
		if own:
			draw_rect(Rect2(panel.x - 4 * _scale, y - 2 * _scale, width * _scale + 4 * _scale, 20 * _scale),
				Color(tint, 0.19))
		var label := _scoreboard_display_name(row, tag_x - panel.x - 6 * _scale)
		_text(label, Vector2(panel.x, y), 16, WHITE)
		if own or row.is_bot():
			_text("YOU" if own else "BOT", Vector2(tag_x, y + _scale), 12, tint if own else LIGHT_GRAY, _DISPLAY)
		_centered(str(row.kills), Vector2(kill_x, y), 16, WHITE, _DISPLAY)
		_centered(str(row.deaths), Vector2(death_x, y), 16, LIGHT_GRAY, _DISPLAY)


func _scoreboard_name(row: ScoreboardUpdate.Row) -> String:
	var label := row.name.strip_escapes().strip_edges()
	return "Player" if label.is_empty() else label


func _scoreboard_display_name(row: ScoreboardUpdate.Row, width: float) -> String:
	var label := _scoreboard_name(row)
	var suffix := ""
	if not row.is_bot() and _scoreboard_duplicates.get(label.to_lower(), 0) > 1:
		suffix = " · %02d" % (row.id + 1)
	if _measure(label + suffix, 16) <= width:
		return label + suffix
	while label.length() > 1 and _measure(label + "…" + suffix, 16) > width:
		label = label.left(-1)
	return label + "…" + suffix


## Fade the score rows into the live scene above and below.
func _draw_scoreboard_shade(top: float, bottom: float) -> void:
	var fade := 68 * _scale
	var tint := Color8(8, 13, 16, 119)
	var clear := Color(tint, 0)
	draw_rect(Rect2(0, top, size.x, bottom - top), tint)
	draw_polygon(PackedVector2Array([Vector2(0, top - fade), Vector2(size.x, top - fade), Vector2(size.x, top), Vector2(0, top)]),
		PackedColorArray([clear, clear, tint, tint]))
	draw_polygon(PackedVector2Array([Vector2(0, bottom), Vector2(size.x, bottom), Vector2(size.x, bottom + fade), Vector2(0, bottom + fade)]),
		PackedColorArray([tint, tint, clear, clear]))


func _draw_result() -> void:
	var center := size / 2.0
	var title := "ROUND DRAWN"
	var tint := WHITE
	match match_state.result:
		MatchState.Result.BLUE:
			title = "BLUE WINS"
			tint = team_color(Game.Team.BLUE).lightened(0.3)
		MatchState.Result.RED:
			title = "RED WINS"
			tint = team_color(Game.Team.RED).lightened(0.3)
	_box(center, -232, -100, 464, 200, PANEL)
	_box(center, -232, -100, 464, 3, tint)
	_centered(title, center + Vector2(0, -74) * _scale, 56, tint, _DISPLAY)
	_centered("%d – %d   ·   %d kills" % [match_state.blue_score, match_state.red_score, match_state.kills],
		center, 22, WHITE)
	var action := "Enter  Play again    ·    Esc  Match menu" if replay_available else "Esc  Match menu"
	_centered(action, center + Vector2(0, 47) * _scale, 16, LIGHT_GRAY)


func _centered(text: String, center: Vector2, font_size: int, color: Color, face: Font = _BODY) -> void:
	_text(text, center - Vector2(_measure(text, font_size, face) / 2.0, 0), font_size, color, face)


func team_color(of: int) -> Color:
	return team_colors.get(of, NO_TEAM_COLOR)


## _text draws text with its top left corner at position, at a size of the
## 720 pixel screen: capitals and digits fill the size from the top, as the
## layout expects.
func _text(text: String, position: Vector2, font_size: int, color: Color, face: Font = _BODY) -> void:
	var scaled := maxi(1, roundi(font_size * _scale))
	var baseline := position + Vector2(0, BASELINE * scaled)
	var outline := Color(INK, INK.a * color.a)
	draw_string_outline(face, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, scaled, maxi(2, roundi(3 * _scale)), outline)
	draw_string(face, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, scaled, color)


## _measure is the width of text in screen pixels.
func _measure(text: String, font_size: int, face: Font = _BODY) -> float:
	return face.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(1, roundi(font_size * _scale))).x


## _box draws a rectangle given in pixels of the 720 pixel screen relative to
## an anchor in screen pixels.
func _box(anchor: Vector2, x: float, y: float, width: float, height: float, color: Color) -> void:
	draw_rect(Rect2(anchor + Vector2(x, y) * _scale, Vector2(width, height) * _scale), color)


## _draw_crosshair draws four ticks around the middle of the screen, as far
## apart as the spread of the next shot at the field of view. Aiming down the
## sights shrinks it to a dot.
func _draw_crosshair() -> void:
	var center := size / 2
	var gap := tan(spread) / tan(deg_to_rad(fov) / 2) * size.y / 2
	gap = maxf(3 * _scale, gap)
	var tint := Color(1, 1, 1, 1 - aim)
	var length := 8 * _scale
	var thickness := 2 * _scale
	if tint.a > 0:
		draw_rect(Rect2(center.x - gap - length, center.y - thickness / 2, length, thickness), tint)
		draw_rect(Rect2(center.x + gap, center.y - thickness / 2, length, thickness), tint)
		draw_rect(Rect2(center.x - thickness / 2, center.y - gap - length, thickness, length), tint)
		draw_rect(Rect2(center.x - thickness / 2, center.y + gap, thickness, length), tint)
	draw_circle(center, 1.5 * _scale, Color8(255, 255, 255, 200))


## _draw_scope covers the screen but a round view with a reticle.
func _draw_scope() -> void:
	var center := size / 2
	var radius := 0.44 * size.y
	var outer := size.length()
	draw_arc(center, (radius + outer) / 2, 0, TAU, 128, Color(0, 0, 0), outer - radius + 2)
	draw_arc(center, radius - 3 * _scale, 0, TAU, 128, Color8(10, 10, 10, 200), 6 * _scale, true)
	var line := Color8(10, 10, 10, 230)
	var gap := 12 * _scale
	var width := 2 * _scale
	draw_rect(Rect2(center.x - radius, center.y - width / 2, radius - gap, width), line)
	draw_rect(Rect2(center.x + gap, center.y - width / 2, radius - gap, width), line)
	draw_rect(Rect2(center.x - width / 2, center.y + gap, width, radius - gap), line)
	draw_rect(Rect2(center.x - width / 2, center.y - radius, width, radius - gap), line)
	draw_circle(center, 1.5 * _scale, RED)


## Keep the magazine and reserve in the corner, with progress while busy.
func _draw_arsenal() -> void:
	var kind := arsenal.weapon()
	var tuning := weapons.get_tuning(kind) if weapons != null else null
	if tuning == null:
		return
	var corner := Vector2(size.x - 15 * _scale, size.y - 29 * _scale)
	var magazine := arsenal.magazine[arsenal.current]
	var rounds := str(magazine)
	var reserve := "/ %d" % arsenal.reserve[arsenal.current]
	var reserve_width := _measure(reserve, 13, _DISPLAY) / _scale
	var rounds_width := _measure(rounds, 17, _DISPLAY) / _scale
	var width := maxf(65.0, reserve_width + rounds_width + 17)
	var tint := WHITE
	if magazine == 0:
		tint = RED.lightened(0.22)
	elif magazine <= tuning.magazine / 4:
		tint = ORANGE
	_box(corner, -width, 0, width, 20, COMBAT_STRIP)
	_text(reserve, corner + Vector2(-reserve_width - 7, 4) * _scale, 13, LIGHT_GRAY, _DISPLAY)
	_text(rounds, corner + Vector2(-reserve_width - rounds_width - 12, 2) * _scale, 17, tint, _DISPLAY)

	if arsenal.action != Arsenal.Action.READY:
		var total := tuning.equip_ticks()
		var label := "Equipping"
		if arsenal.action == Arsenal.Action.RELOADING:
			total = tuning.reload_ticks()
			label = "Reloading"
		var done := clampf(1.0 - float(arsenal.action_ticks) / maxi(1, total), 0.0, 1.0)
		_box(corner, -width, 18, width * done, 2, GOLD)
		_text(label, corner + Vector2(-_measure(label, 15), -18 * _scale), 15, GOLD)


## _draw_vehicle marks where the gun of the player's tank points, which the
## turret turns towards the crosshair, and shows the tank's armour and the
## loading of its gun in the bottom right corner.
func _draw_vehicle() -> void:
	if gun_marker.x >= 0:
		var loaded := vehicle.reload == 0
		draw_arc(gun_marker, 9 * _scale, 0, TAU, 32, WHITE if loaded else GOLD, 2 * _scale, true)
		draw_circle(gun_marker, 1.5 * _scale, WHITE)
	var corner := Vector2(size.x - 24 * _scale, size.y - 23 * _scale)
	var share := clampf(float(vehicle.health) / Vehicle.MAX_HEALTH, 0.0, 1.0)
	var armour := str(vehicle.health)
	var total := "/ %d" % Vehicle.MAX_HEALTH
	var total_width := _measure(total, 19, _DISPLAY)
	_text(total, corner + Vector2(-total_width, -19 * _scale), 19, LIGHT_GRAY, _DISPLAY)
	_text(armour, corner + Vector2(-total_width - _measure(armour, 34, _DISPLAY) - 6 * _scale, -32 * _scale), 34,
		WHITE if share >= 0.35 else ORANGE, _DISPLAY)
	var loading := 1.0 - float(vehicle.reload) / Vehicle.reload_ticks()
	var label := "Tank  ·  gun ready" if vehicle.reload == 0 else "Tank  ·  loading"
	_box(corner, -112, 3, 112, 4, INK)
	_box(corner, -111, 4, 110 * clampf(loading, 0.0, 1.0), 2, GOLD if vehicle.reload > 0 else WHITE)
	_text(label, corner + Vector2(-_measure(label, 15), -50 * _scale), 15, GOLD if vehicle.reload > 0 else LIGHT_GRAY)


## Draw health as a number over its remaining share.
func _draw_health() -> void:
	var corner := Vector2(15 * _scale, size.y - 29 * _scale)
	var share := clampf(float(health) / Game.MAX_HEALTH, 0.0, 1.0)
	var low := share < 0.35
	var fill := ORANGE.darkened(0.42) if low else team_color(team).darkened(0.22)
	_box(corner, 0, 0, 92, 20, COMBAT_STRIP)
	_box(corner, 0, 0, 92 * share, 20, fill)
	_text("+  %d" % health, corner + Vector2(7, 2) * _scale, 17, ORANGE if low else WHITE, _DISPLAY)


## _draw_death tells the dead player who killed it and when it comes back.
func _draw_death() -> void:
	var middle := size.y / 2
	draw_rect(Rect2(0, middle - 70 * _scale, size.x, 140 * _scale), Color8(0, 0, 0, 120))
	var title := "KILLED"
	_text(title, Vector2((size.x - _measure(title, 48)) / 2, middle - 58 * _scale), 48, RED)
	var killer := feedback.killed_by if feedback != null else ""
	_text(killer, Vector2((size.x - _measure(killer, 22)) / 2, middle - 4 * _scale), 22, WHITE)
	var back := "Back in the fight in %.1f s" % (float(respawn_ticks) / Game.TICK_RATE)
	_text(back, Vector2((size.x - _measure(back, 22)) / 2, middle + 28 * _scale), 22, LIGHT_GRAY)


## _draw_feedback draws the red flash of a hit, the arcs that point to the
## shooters, and the hit marker on the crosshair.
func _draw_feedback() -> void:
	var f := feedback
	var center := size / 2
	if f.flash > 0:
		var alpha := 110.0 / 255.0 * f.flash / _Feedback.HURT_FLASH
		var strong := Color(200.0 / 255.0, 0, 0, alpha)
		var clear := Color(200.0 / 255.0, 0, 0, 0)
		var band := size.y / 5
		draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, band), Vector2(0, band)]),
			PackedColorArray([strong, strong, clear, clear]))
		draw_polygon(PackedVector2Array([Vector2(0, size.y - band), Vector2(size.x, size.y - band), Vector2(size.x, size.y), Vector2(0, size.y)]),
			PackedColorArray([clear, clear, strong, strong]))
	for mark in f.hurt:
		# Straight ahead is up on the screen; the arc's angle counts from the
		# right, clockwise, as the screen's Y points down.
		var angle := Game.remainder(mark.yaw - view_yaw) - PI / 2
		var alpha := 220.0 / 255.0 * (1 - mark.age / _Feedback.HURT_TIME)
		draw_arc(center, 117 * _scale, angle - deg_to_rad(22), angle + deg_to_rad(22), 16, Color(230.0 / 255.0, 30.0 / 255.0, 30.0 / 255.0, alpha), 14 * _scale, true)
	if f.marker > 0:
		var tint := WHITE
		var reach := 10.0
		if f.marker_head:
			tint = GOLD
		if f.marker_kill:
			tint = RED
			reach = 14.0
		tint.a = minf(1.0, 2 * f.marker / _Feedback.MARKER_TIME)
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			draw_line(center + corner * 5 * _scale, center + corner * reach * _scale, tint, 2.5 * _scale, true)
