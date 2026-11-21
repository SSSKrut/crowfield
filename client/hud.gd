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
var replay_available := false
var map_scene: MapScene
var feet := Vector3.ZERO

var _font: Font
var _scale := 1.0


func _init() -> void:
	name = "Hud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = _BODY


func _draw() -> void:
	_scale = clampf(size.y / 720.0, 0.75, 4.0)
	if arsenal != null:
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


func _draw_match() -> void:
	var center := Vector2(size.x / 2.0, 18 * _scale)
	var blue := team_color(Game.Team.BLUE).lightened(0.30)
	var red := team_color(Game.Team.RED).lightened(0.30)
	var show_bearings := has_soldier and not dead and match_state.result == MatchState.Result.ACTIVE
	var footer := 97 if show_bearings else 79
	_box(center, -183, 0, 366, footer, PANEL)
	_box(center, -183, 0, 366, 1, PANEL_EDGE)
	var clock := "%d:%02d" % [match_state.seconds / 60, match_state.seconds % 60]
	_text("BLUE", center + Vector2(-167, 11) * _scale, 15, blue, _DISPLAY)
	_text("RED", center + Vector2(167 * _scale - _measure("RED", 15, _DISPLAY), 11 * _scale), 15, red, _DISPLAY)
	_centered(str(match_state.blue_score), center + Vector2(-98, 4) * _scale, 32, WHITE, _DISPLAY)
	_centered(str(match_state.red_score), center + Vector2(98, 4) * _scale, 32, WHITE, _DISPLAY)
	_centered(clock, center + Vector2(0, 6) * _scale, 26, WHITE, _DISPLAY)
	_box(center, -183, 36, 366, 1, PANEL_EDGE)
	for index in map_scene.flags.size():
		var flag := match_state.flags[index]
		var x := (index - 1) * 122
		var tint := GOLD if flag.contested else team_colors.get(flag.owner, LIGHT_GRAY) as Color
		_box(center, x - 53, 38, 106, 2, tint)
		_centered(map_scene.flags[index].name, center + Vector2(x, 45) * _scale, 16, WHITE)
		var status := "NEUTRAL" if flag.owner == Game.Team.NONE else Game.team_name(flag.owner).to_upper()
		var status_tint := tint
		if flag.contested:
			status = "CONTESTED"
		elif flag.challenger != Game.Team.NONE and flag.progress > 0:
			status_tint = team_color(flag.challenger)
			if flag.owner == team and team != Game.Team.NONE:
				status = "LOSING %d%%" % flag.progress
				status_tint = GOLD
			else:
				status = "%s TAKING %d%%" % [Game.team_name(flag.challenger).to_upper(), flag.progress]
		_centered(status, center + Vector2(x, 62) * _scale, 12, status_tint.lightened(0.30), _DISPLAY)
		if show_bearings:
			_draw_flag_bearing(map_scene.flags[index], center + Vector2(x, 84) * _scale)
	_box(center, -48, footer + 2, 96, 22, PANEL)
	_centered("%d KILLS" % match_state.kills, center + Vector2(0, footer + 4) * _scale, 16, WHITE, _DISPLAY)
	if match_state.result != MatchState.Result.ACTIVE:
		_draw_result()
	elif has_soldier and not dead:
		_draw_capture()


## The arrow turns with the player, including when the flag is behind them.
func _draw_flag_bearing(zone: MapScene.Zone, center: Vector2) -> void:
	if zone.contains_flag_position(feet):
		_centered("AT FLAG", center + Vector2(0, -7) * _scale, 13, LIGHT_GRAY, _DISPLAY)
		return
	var offset := zone.center - feet
	var angle := atan2(offset.x, -offset.z) - view_yaw
	var forward := Vector2(sin(angle), -cos(angle))
	var side := forward.orthogonal()
	var origin := center - Vector2(16, 0) * _scale
	draw_colored_polygon(PackedVector2Array([
		origin + forward * (6 * _scale),
		origin + (side * 4 - forward * 4) * _scale,
		origin + (forward * -2) * _scale,
		origin + (-side * 4 - forward * 4) * _scale,
	]), WHITE)
	var meters := roundi(Vector2(offset.x, offset.z).length())
	_text("%d m" % meters, center + Vector2(-5, -7) * _scale, 13, LIGHT_GRAY, _DISPLAY)


func _draw_capture() -> void:
	for index in map_scene.flags.size():
		var zone := map_scene.flags[index]
		if not zone.contains_flag_position(feet):
			continue
		var flag := match_state.flags[index]
		var label := "Holding " + zone.name
		if flag.contested:
			label = zone.name + " contested"
		elif flag.challenger == team or flag.owner != team:
			label = "Capturing " + zone.name
		var center := Vector2(size.x / 2.0, size.y * 0.70)
		_box(center, -142, 0, 284, 38, PANEL)
		_centered(label, center + Vector2(0, 8) * _scale, 19, WHITE)
		if flag.challenger != Game.Team.NONE:
			_box(center, -130, 31, 260, 3, Color8(255, 255, 255, 65))
			_box(center, -130, 31, 260.0 * flag.progress / 100.0, 3, GOLD if flag.contested else team_color(flag.challenger))
		break


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
		center + Vector2(0, 0) * _scale, 22, WHITE)
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
	draw_string(face, position + Vector2(0, BASELINE * scaled), text, HORIZONTAL_ALIGNMENT_LEFT, -1, scaled, color)


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


## _draw_arsenal shows the weapon in hand and its rounds in the bottom right
## corner, the reload, and the slots of the loadout.
func _draw_arsenal() -> void:
	var kind := arsenal.weapon()
	var tuning := weapons.get_tuning(kind) if weapons != null else null
	if tuning == null:
		return
	var corner := Vector2(size.x - 24 * _scale, size.y - 24 * _scale)
	var magazine := arsenal.magazine[arsenal.current]
	var reserve := "/ %d" % arsenal.reserve[arsenal.current]
	var rounds := str(magazine)
	var reserve_width := _measure(reserve, 22, _DISPLAY)
	var rounds_width := _measure(rounds, 51, _DISPLAY)
	var tint := WHITE
	if magazine == 0:
		tint = RED
	elif magazine <= tuning.magazine / 4:
		tint = ORANGE
	_box(corner, -220, -103, 220, 103, PANEL)
	_box(corner, -220, -103, 220, 1, PANEL_EDGE)
	var label: String = WeaponTuning.LABELS[kind].to_upper()
	_text(label, corner + Vector2(-206, -92) * _scale, 18, LIGHT_GRAY, _DISPLAY)
	_text(reserve, corner + Vector2(-14 * _scale - reserve_width, -46 * _scale), 22, LIGHT_GRAY, _DISPLAY)
	_text(rounds, corner + Vector2(-24 * _scale - reserve_width - rounds_width, -68 * _scale), 51, tint, _DISPLAY)
	if arsenal.action != Arsenal.Action.READY:
		var total := tuning.equip_ticks()
		var action := "EQUIPPING"
		if arsenal.action == Arsenal.Action.RELOADING:
			total = tuning.reload_ticks()
			action = "RELOADING"
		var done := 1.0 - float(arsenal.action_ticks) / maxi(1, total)
		_box(corner, -220, -3, 220, 3, PANEL_EDGE)
		_box(corner, -220, -3, 220 * done, 3, GOLD)
		_text(action, corner + Vector2(-206, -22) * _scale, 14, GOLD, _DISPLAY)
	var x := corner.x - 220 * _scale
	for slot in Arsenal.MAX_LOADOUT:
		var held := arsenal.weapons[slot]
		if held == WeaponTuning.Kind.NONE:
			continue
		var slot_text := "%d %s" % [slot + 1, WeaponTuning.LABELS[held]]
		var color := WHITE if slot == arsenal.current else Color8(200, 200, 200, 155)
		x -= _measure(slot_text, 15) + 14 * _scale
		_text(slot_text, Vector2(x, corner.y - 17 * _scale), 15, color)


## _draw_health shows the health of the own soldier in the bottom left corner,
## and the team it fights for: the soldiers of the other colour are enemies.
func _draw_health() -> void:
	var corner := Vector2(24 * _scale, size.y - 24 * _scale)
	var label := Game.team_name(team).to_upper() + " TEAM"
	var team_tint := team_color(team).lightened(0.32)
	_box(corner, 0, -93, 178, 93, PANEL)
	_box(corner, 0, -93, 178, 2, team_tint)
	_text(label, corner + Vector2(12, -81) * _scale, 17, team_tint, _DISPLAY)
	var share := clampf(float(health) / Game.MAX_HEALTH, 0.0, 1.0)
	var health_tint := WHITE if share >= 0.35 else ORANGE
	_text(str(health), corner + Vector2(12, -58) * _scale, 43, health_tint, _DISPLAY)
	_text("HEALTH", corner + Vector2(90, -32) * _scale, 14, LIGHT_GRAY, _DISPLAY)
	_box(corner, 12, -10, 154, 3, PANEL_EDGE)
	_box(corner, 12, -10, 154 * share, 3, team_tint if share >= 0.35 else ORANGE)

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
## shooters, the hit marker on the crosshair and the kill feed.
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
	var right := size.x - 24 * _scale
	var y := 140 * _scale
	for line in f.feed:
		var weapon := "[" + WeaponTuning.kind_name(line.weapon).to_upper() + "]"
		if line.head:
			weapon += " HEADSHOT"
		var parts := [[line.killer, team_color(line.killer_team)], ["  " + weapon + "  ", LIGHT_GRAY], [line.victim, team_color(line.victim_team)]]
		var total := 0.0
		for part in parts:
			total += _measure(part[0], 18)
		var background := Color8(120, 100, 20, 140) if line.own else PANEL
		draw_rect(Rect2(right - total - 8 * _scale, y - 4 * _scale, total + 16 * _scale, 26 * _scale), background)
		var x := right - total
		for part in parts:
			_text(part[0], Vector2(x, y), 18, part[1])
			x += _measure(part[0], 18)
		y += 30 * _scale
