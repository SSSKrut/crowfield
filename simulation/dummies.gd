class_name Dummies
extends RefCounted
## Dummies are bot soldiers without AI: they walk to random points of the map,
## so that networking and drawing meet many soldiers before real bots exist.
## They have no physics capsule; a ray per dummy finds the ground under it.

## A dummy steps over this much, like the stairs; anything taller blocks it.
const STEP_HEIGHT := 0.5
const DROP_HEIGHT := 1.0
## Dummies keep this far from each other.
const SPACING := 1.2
## OPEN_CELL is the size of the cells of the map of open floor.
const OPEN_CELL := 0.5

var _server: Server
var _soldiers := PackedInt32Array()
var _targets := PackedVector3Array()
## _respawn_at is the tick when a dead dummy comes back.
var _respawn_at := PackedInt64Array()
var _random := RandomNumberGenerator.new()
var _speed: float
var _area: float
## _deaths is the share of a death owed to the deaths a second asked for.
var _deaths := 0.0
## _open marks the cells of the play area whose floor lies at zero with nothing
## above it: there the ray of a dummy on the floor would find the floor at
## zero, so it needs no ray. _cells is the number of cells along a side.
var _open := PackedByteArray()
var _cells := 0


func _init(server: Server) -> void:
	_server = server
	_random.seed = server.match_seed ^ 53456
	_speed = server.rules.movement.walk_speed
	_area = server.scene.play_area
	_map_open_floor()


## _map_open_floor casts a ray from above at every corner of every cell once:
## a cell is open when all of them meet the floor at zero.
func _map_open_floor() -> void:
	_cells = ceili(2 * _area / OPEN_CELL)
	var corners := PackedByteArray()
	corners.resize((_cells + 1) * (_cells + 1))
	for z in _cells + 1:
		for x in _cells + 1:
			var at := Vector3(-_area + x * OPEN_CELL, 10, -_area + z * OPEN_CELL)
			var down := _server.cast_ray(at, Vector3.DOWN, 11, Game.LAYER_STATIC)
			corners[z * (_cells + 1) + x] = 1 if down >= 0 and absf(10 - down) < 1e-3 else 0
	_open.resize(_cells * _cells)
	for z in _cells:
		for x in _cells:
			var row := z * (_cells + 1) + x
			_open[z * _cells + x] = corners[row] & corners[row + 1] & corners[row + _cells + 1] & corners[row + _cells + 2]


## _floor_at returns the height of the ground under a dummy at next, or -INF
## for a wall or a ledge: from the map of open floor, or by a ray from the
## height of a step.
func _floor_at(next: Vector3) -> float:
	var x := floori((next.x + _area) / OPEN_CELL)
	var z := floori((next.z + _area) / OPEN_CELL)
	if next.y == 0.0 and x >= 0 and z >= 0 and x < _cells and z < _cells and _open[z * _cells + x] == 1:
		return 0.0
	var ground := _server.cast_ray(next + Vector3(0, STEP_HEIGHT, 0), Vector3.DOWN, STEP_HEIGHT + DROP_HEIGHT, Game.LAYER_STATIC)
	if ground <= 0:
		return -INF
	return next.y + STEP_HEIGHT - ground


func count() -> int:
	return _soldiers.size()


func spawn_all(how_many: int) -> void:
	_soldiers.resize(how_many)
	_targets.resize(how_many)
	_respawn_at.resize(how_many)
	for i in how_many:
		_spawn(i, Game.Team.BLUE if i % 2 == 0 else Game.Team.RED)


## _spawn puts dummy i on the map as a new soldier of the team.
func _spawn(i: int, team: int) -> void:
	var soldier := Soldier.new()
	soldier.team = team
	soldier.controller = Game.Controller.BOT
	soldier.bot = i
	soldier.alive = true
	soldier.grounded = true
	soldier.position = _floor_point()
	soldier.health = Game.MAX_HEALTH
	soldier.arsenal = Arsenal.create(Arsenal.default_loadout(), _server.rules.weapons)
	_soldiers[i] = _server.soldiers.add(soldier)
	_targets[i] = _open_point()


## died records when a dead dummy comes back.
func died(i: int, back: int) -> void:
	if i >= 0 and i < _respawn_at.size():
		_respawn_at[i] = back


func respawn_dead() -> void:
	for i in _soldiers.size():
		var soldier := _server.soldiers.get_soldier(_soldiers[i])
		if soldier.alive or _server.tick < _respawn_at[i]:
			continue
		var team := soldier.team
		_server.soldiers.remove(_soldiers[i])
		_spawn(i, team)


## kill kills dummies at the rate of the settings, each by a random hit, as if
## shot, so that clients have deaths to show.
func kill() -> void:
	if _server.settings.dummy_deaths <= 0 or _soldiers.is_empty():
		return
	_deaths += _server.settings.dummy_deaths / Game.TICK_RATE
	while _deaths >= 1:
		_deaths -= 1
		var soldier := _server.soldiers.get_soldier(_soldiers[_random.randi_range(0, _soldiers.size() - 1)])
		if not soldier.alive:
			continue
		soldier.hit_count += 1
		soldier.hit_box = _random.randi_range(0, Hitboxes.COUNT - 1)
		soldier.hit_yaw = _random.randf() * TAU
		_server.damage(soldier, Game.MAX_HEALTH)


## _floor_point picks a random spawn point for a dummy on the open floor: not
## inside an obstacle and not on top of one, where it could not leave.
func _floor_point() -> Vector3:
	while true:
		var point := _open_point()
		var down := _server.cast_ray(point + Vector3(0, 10, 0), Vector3.DOWN, 11, Game.LAYER_STATIC)
		if down >= 0 and 10 - down < 0.05:
			point.y = 10 - down
			return point
	return Vector3.ZERO


## _open_point picks a random point of the play area away from the spawn of
## the players. A target may lie in an obstacle: the dummy turns away when it
## gets there.
func _open_point() -> Vector3:
	var spawn := _server.scene.spawn
	while true:
		var point := Vector3((_random.randf() * 2 - 1) * _area, 0, (_random.randf() * 2 - 1) * _area)
		var dx := point.x - spawn.x
		var dz := point.z - spawn.z
		if dx * dx + dz * dz > 4:
			return point
	return Vector3.ZERO


## move walks every living dummy towards its target and away from its
## neighbours, and finds the ground under its next step. A ray that starts
## inside geometry means a wall, and no ground within the drop means a ledge:
## either way the dummy stays and picks another target.
func move() -> void:
	var grid := _server.grid
	var soldiers := _server.soldiers
	for i in _soldiers.size():
		var soldier := soldiers.at(_soldiers[i] & (SoldierSet.MAX_SOLDIERS - 1))
		if not soldier.alive:
			continue
		var to_target := _targets[i] - soldier.position
		to_target.y = 0
		if Game.horizontal_length(to_target) < 0.5:
			_targets[i] = _open_point()
			to_target = _targets[i] - soldier.position
			to_target.y = 0
		var direction := to_target / maxf(Game.horizontal_length(to_target), 1e-6)
		var near := grid.near(soldier.position, SPACING)
		for k in near:
			var away := soldier.position - grid.positions[k]
			away.y = 0
			var distance := Game.horizontal_length(away)
			if grid.ids[k] != soldier.id and distance > 1e-3:
				direction += away * ((SPACING - distance) / (SPACING * distance))
		var velocity := direction * (_speed / maxf(Game.horizontal_length(direction), 1e-6))
		var next := soldier.position + velocity * Game.TICK_DELTA
		next.x = clampf(next.x, -_area, _area)
		next.z = clampf(next.z, -_area, _area)
		soldier.yaw = atan2(velocity.x, -velocity.z)
		var floor := _floor_at(next)
		if floor == -INF:
			soldier.velocity = Vector3.ZERO
			_targets[i] = _open_point()
			continue
		next.y = floor
		soldier.velocity = (next - soldier.position) * Game.TICK_RATE
		soldier.position = next
