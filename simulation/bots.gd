class_name Bots
extends RefCounted
## Bots are the soldiers the server drives itself (ARCHITECTURE.md, 8). A bot
## has no capsule and no commands from a connection: it walks the paths of the
## navigation mesh and stands on the ground the map gives under it. It obeys
## the rules of combat of a human: it sees through nothing, aims by turning
## and fires the same weapons, with their spread, kick and magazines, and its
## shots are tested like any other.
##
## Each bot is a small state machine (8.5):
## - ADVANCE: it walks to a place of the map worth fighting for, stays there a
##   while looking about, and picks the next one;
## - ENGAGE: it sees an enemy, turns to it, waits out its reaction and fires in
##   bursts, standing or stepping aside, until the enemy dies or hides; a far
##   enemy, or one beyond the reach of its gun, it closes on in rushes,
##   shooting between them; now and then it fires a rocket or throws a
##   grenade;
## - SEARCH: it goes to where it last saw the enemy.
## A bot thinks four times a second, staggered over the ticks: it looks for
## enemies within its view, nearest first, with rays to them on a budget per
## tick. Aim and fire run every tick. A bot sees its target as it was a
## reaction time ago, from the pose history of lag compensation, and its aim
## wanders off and settles back like a hand's (8.5). A hit makes it look for
## the shooter, and a bot out of the fight heals itself with a medkit.
##
## A bot is born with one gun, and as often as not one thing more: a pistol, a
## rocket launcher, grenades or a medkit. Passive bots only walk, for load
## tests.

enum State { ADVANCE, ENGAGE, SEARCH }

const THINK_TICKS := 15
## A bot sees enemies within VIEW_RANGE and VIEW_ANGLE of where it looks, and
## any enemy within NOTICE_RANGE.
const VIEW_RANGE := 90.0
const VIEW_ANGLE := deg_to_rad(65.0)
const NOTICE_RANGE := 7.0
## A bot looks at no more than LOOKS enemies in a thought, nearest first.
const LOOKS := 3
const RAYS_PER_TICK := 64
const PATHS_PER_TICK := 4
## An engaged bot checks that it still sees its target this often, and gives
## up on it, to search, after not seeing it this long.
const SIGHT_TICKS := 6
const LOSE_TICKS := 40
const SEARCH_TICKS := 6 * Game.TICK_RATE
## A hit makes a bot look for the shooter in every direction this long.
const ALERT_TICKS := 3 * Game.TICK_RATE
const REACTION := Vector2(0.22, 0.45)
const TURN_SPEED := deg_to_rad(400.0)
## Aim at the infantry chest and check for a visible helmet over cover.
const AIM_HEIGHT := 1.17
const HEAD_HEIGHT := 1.64
## The aim error starts at ACQUIRE_ERROR on a new target and settles towards
## STEADY_ERROR in about SETTLE seconds, wandering by NOISE every tick. Each
## bot has a hand of its own: its errors are its skill times these.
const ACQUIRE_ERROR := deg_to_rad(7.0)
const STEADY_ERROR := deg_to_rad(0.9)
const SETTLE := 0.6
const SKILL := Vector2(0.75, 1.35)
const NOISE := deg_to_rad(0.25)
## A bot fires once its aim, without the error, is this close to the target.
const FIRE_CONE := deg_to_rad(8.0)
## Beyond RIFLE_RANGE a bot takes the rifle, closer the assault rifle; it
## aims down the sights beyond AIM_RANGE and steps aside within STRAFE_RANGE.
const RIFLE_RANGE := 55.0
## The weapons a bot is born with: a gun, and with EXTRA_CHANCE one thing
## more, by these weights.
const GUNS := [[WeaponTuning.Kind.ASSAULT_RIFLE, 50], [WeaponTuning.Kind.RIFLE, 22], [WeaponTuning.Kind.SHOTGUN, 28]]
const EXTRAS := [[WeaponTuning.Kind.PISTOL, 25], [WeaponTuning.Kind.ROCKET_LAUNCHER, 25], [WeaponTuning.Kind.GRENADE, 30],
	[WeaponTuning.Kind.MEDKIT, 20]]
const EXTRA_CHANCE := 0.55
## A gun is worth firing within its REACH; beyond it the bot closes in, and
## with a shotgun it rushes beyond SHOTGUN_PUSH.
const REACH := {WeaponTuning.Kind.ASSAULT_RIFLE: 120.0, WeaponTuning.Kind.RIFLE: 250.0, WeaponTuning.Kind.PISTOL: 50.0,
	WeaponTuning.Kind.SHOTGUN: 28.0}
const SHOTGUN_PUSH := 14.0
## A bot fires a rocket at an enemy within ROCKET_RANGE, or throws a grenade
## within GRENADE_RANGE, with the chances below, looked at once a second;
## after either it waits SPECIAL_PAUSE seconds, and gives up one it could not
## make in SPECIAL_TICKS.
const ROCKET_RANGE := Vector2(12, 120)
const GRENADE_RANGE := Vector2(8, 28)
const ROCKET_CHANCE := 0.5
const GRENADE_CHANCE := 0.45
const SPECIAL_PAUSE := Vector2(5, 10)
const SPECIAL_TICKS := 3 * Game.TICK_RATE
## A rocket is aimed this high over the feet of its target, to burst by them.
const ROCKET_HEIGHT := 0.3
## A bot out of the fight takes its medkit below HEAL_BELOW health, HEAL_CALM
## ticks after its last wound.
const HEAL_BELOW := 60
const HEAL_CALM := 2 * Game.TICK_RATE
const AIM_RANGE := 14.0
const STRAFE_RANGE := 30.0
## Beyond PUSH_RANGE a bot rushes towards its target along the mesh for a
## second or two, then holds to shoot for a few.
const PUSH_RANGE := 35.0
## A bot steps over this much, like stairs; anything taller blocks it, and it
## does not step off a ledge higher than DROP_HEIGHT.
const STEP_HEIGHT := 0.5
const DROP_HEIGHT := 1.0
## Bots keep this far from each other; a bot looks for the others near it
## every PUSH_TICKS ticks.
const SPACING := 1.2
const PUSH_TICKS := 3
## Give the first advance a job before bots settle into opportunistic fights.
const OPENING_TICKS := 20 * Game.TICK_RATE
const OPENING_CONTACT_RANGE := 11.0
## The lead soldier closes on a hostile or unclaimed crossing while the rest
## of the squad can take longer shots from the approach.
const POINT_CONTACT_RANGE := 16.0
## Casualties can reinforce their own crossing, but cannot jump from a
## distant fight into a held lane.
const REINFORCEMENT_RANGE := 30.0
## One adjacent relief assignment per side, held long enough to reach the next crossing.
const RELIEF_TICKS := 15 * Game.TICK_RATE
const REINFORCEMENT_INTERVAL := 3 * Game.TICK_RATE
## A bot that gets nowhere in STUCK_TICKS gives up its way.
const STUCK_TICKS := 2 * Game.TICK_RATE
## OPEN_CELL is the size of the cells of the map of open ground.
const OPEN_CELL := 1.0
const NAMES := ["Rook", "Jackdaw", "Magpie", "Raven", "Jay", "Chough", "Crow", "Nutcracker", "Treepie", "Grackle",
	"Starling", "Shrike", "Kestrel", "Merlin", "Harrier", "Buzzard"]

## Bot is what a bot keeps between ticks.
class Bot:
	var index := 0
	var soldier := 0
	var state: int = State.ADVANCE
	var think_at := 0
	var goal := Vector3.ZERO
	var path := PackedVector3Array()
	var corner := 0
	## linger_until is when a bot that reached its goal moves on.
	var linger_until := 0
	var sprint := true
	var target := 0
	var seen_at := -1000
	var last_seen := Vector3.ZERO
	var noticed_at := 0
	var check_at := 0
	var reaction := 0
	var aim_error := Vector2.ZERO
	var burst_until := 0
	var rest_until := 0
	var strafe := 0.0
	var strafe_until := 0
	var push_until := 0
	var hold_until := 0
	## special is the slot of the rocket launcher or the grenade a bot is
	## about to use, or -1; it gives up at special_until and may start
	## another at special_at.
	var special := -1
	var special_until := 0
	var special_at := 0
	var weapon := 0
	var attacker := 0
	var hurt_at := -1000
	var progress_at := 0
	var progress_from := Vector3.ZERO
	var respawn_at := 0
	## Assigned Valley lane. Openings use the same home lane by slot on each side.
	var lane := -1
	## skill scales the aim errors of the bot: below one it aims better.
	var skill := 1.0
	## push keeps the bot clear of the others, as last found.
	var push := Vector3.ZERO
	## reload asks an idle bot to reload its weapon.
	var reload := false

var bots: Array[Bot] = []
var _server: Server
var _scene: MapScene
var _rules: Rules
var _random := RandomNumberGenerator.new()
var _area: float
var _ai: bool
var _rays := 0
var _paths := 0
## _deaths is the share of a death owed to the deaths a second asked for.
var _deaths := 0.0
## The living soldiers of each team this tick, for the eyes of the bots.
var _team_ids: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]
var _team_positions: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array(), PackedVector3Array()]
## _open marks the cells of the play area where nothing stands on the ground,
## so that the ground there is the terrain, or the floor at zero of a map
## without terrain; there a bot needs no ray to find it. _cells is the number
## of cells along a side.
var _open := PackedByteArray()
var _cells := 0
var _eye := 1.55
var _aim_settle := 0.0
var _opening_until := -1
var _next_relief_review := 0
var _reinforcement_at: Dictionary[Vector2i, int] = {}


func _init(server: Server) -> void:
	_server = server
	_scene = server.scene
	_rules = server.rules
	_random.seed = server.match_seed ^ 53456
	_area = _scene.play_area
	_ai = server.settings.bot_ai
	_eye = _rules.movement.eye_height
	_aim_settle = exp(-1.0 / (SETTLE * Game.TICK_RATE))
	_map_open_ground()


func count() -> int:
	return bots.size()


## name_of is how the kill feed calls bot number index.
static func name_of(index: int) -> String:
	var name: String = NAMES[index % NAMES.size()]
	if index >= NAMES.size():
		name += " %d" % (index / NAMES.size() + 1)
	return name


func spawn_all(how_many: int) -> void:
	for i in how_many:
		var bot := Bot.new()
		bot.index = i
		bot.skill = _random.randf_range(SKILL.x, SKILL.y)
		var team := Game.Team.BLUE if i % 2 == 0 else Game.Team.RED
		if _ai and _scene.name == "valley" and _server.flag_match != null:
			bot.lane = _home_lane(bot, team)
		bots.append(bot)
		_spawn(bot, team)


func reset_for_round() -> void:
	_opening_until = -1
	_next_relief_review = 0
	_reinforcement_at.clear()
	var count := bots.size()
	for bot in bots:
		_server.soldiers.remove(bot.soldier)
	bots.clear()
	spawn_all(count)


## First deployment is at home. A casualty may return behind a safe crossing.
func _spawn(bot: Bot, team: int, reinforcement: Vector3 = Vector3.INF) -> void:
	var soldier := Soldier.new()
	soldier.team = team
	soldier.controller = Game.Controller.BOT
	soldier.bot = bot.index
	soldier.alive = true
	soldier.grounded = true
	var zone := _scene.zone_of(team)
	if reinforcement.is_finite():
		soldier.position = reinforcement
		soldier.yaw = Game.yaw_of(-reinforcement)
	elif zone.radius > 0:
		soldier.position = _server.spawn_point(team, _random)
		soldier.yaw = Game.yaw_of(-zone.center)
	else:
		soldier.position = _floor_point()
		soldier.yaw = _random.randf() * TAU
	soldier.health = Game.MAX_HEALTH
	soldier.arsenal = Arsenal.create(_loadout(), _rules.weapons)
	bot.soldier = _server.soldiers.add(soldier)
	bot.special = -1
	bot.special_at = _server.tick + _random.randi_range(2 * Game.TICK_RATE, 5 * Game.TICK_RATE)
	bot.state = State.ADVANCE
	bot.path = PackedVector3Array()
	bot.corner = 0
	bot.target = 0
	bot.attacker = 0
	bot.hurt_at = -1000
	bot.weapon = 0
	bot.linger_until = 0
	bot.think_at = _server.tick + 1 + bot.index % THINK_TICKS
	bot.progress_at = _server.tick
	bot.progress_from = soldier.position


## _loadout picks the weapons of a new bot: a gun, and maybe one thing more.
func _loadout() -> PackedInt32Array:
	var loadout := PackedInt32Array([_pick(GUNS)])
	if _random.randf() < EXTRA_CHANCE:
		loadout.append(_pick(EXTRAS))
	return loadout


func _pick(weighted: Array) -> int:
	var total := 0
	for entry: Array in weighted:
		total += entry[1]
	var roll := _random.randi_range(1, total)
	for entry: Array in weighted:
		roll -= entry[1]
		if roll <= 0:
			return entry[0]
	return weighted[0][0]


## died records when a dead bot comes back.
func died(index: int, back: int) -> void:
	if index >= 0 and index < bots.size():
		bots[index].respawn_at = back


func respawn_dead() -> void:
	for bot in bots:
		var soldier := _server.soldiers.get_soldier(bot.soldier)
		if soldier.alive or _server.tick < bot.respawn_at:
			continue
		var team := soldier.team
		var reinforcement := _bot_reinforcement(bot, soldier)
		_server.soldiers.remove(bot.soldier)
		_spawn(bot, team, reinforcement)


func _bot_reinforcement(bot: Bot, soldier: Soldier) -> Vector3:
	if not _front_active():
		return _server.reinforcement_point(soldier.team, soldier.position, REINFORCEMENT_RANGE)
	var key := Vector2i(soldier.team, bot.lane)
	if _server.tick < _reinforcement_at.get(key, 0):
		return Vector3.INF
	var site := _server.reinforcement_point(soldier.team, soldier.position, REINFORCEMENT_RANGE, bot.lane)
	if site.is_finite():
		_reinforcement_at[key] = _server.tick + REINFORCEMENT_INTERVAL
	return site


## hurt tells a bot it was hit by a shooter: it turns to look for it.
func hurt(index: int, shooter: int) -> void:
	if not _ai or index < 0 or index >= bots.size():
		return
	var bot := bots[index]
	bot.attacker = shooter
	bot.hurt_at = _server.tick
	bot.aim_error += Vector2(_random.randf_range(-1, 1), _random.randf_range(-1, 1)) * ACQUIRE_ERROR * 0.3
	if bot.state != State.ENGAGE:
		bot.think_at = mini(bot.think_at, _server.tick + 1)


## kill kills bots at the rate of the settings, each by a random hit, as if
## shot, so that clients have deaths to show.
func kill() -> void:
	if _server.settings.bot_deaths <= 0 or bots.is_empty():
		return
	# There are only this many bots to kill in one tick. Discard excess
	# attempts so an extreme debug rate cannot stall the simulation.
	_deaths = minf(_deaths + _server.settings.bot_deaths / Game.TICK_RATE, bots.size())
	while _deaths >= 1:
		_deaths -= 1
		var soldier := _server.soldiers.get_soldier(bots[_random.randi_range(0, bots.size() - 1)].soldier)
		if not soldier.alive:
			continue
		soldier.hit_count += 1
		soldier.hit_box = _random.randi_range(0, Hitboxes.COUNT - 1)
		soldier.hit_yaw = _random.randf() * TAU
		_server.damage(soldier, Game.MAX_HEALTH)


## update runs the bots for a tick: the living ones think when their turn
## comes, then move, aim and fire.
func update() -> void:
	var round := _server.flag_match
	if _ai and round != null:
		if not round.started:
			return
		if _opening_until < 0:
			_opening_until = _server.tick + OPENING_TICKS
	_rays = RAYS_PER_TICK
	_paths = PATHS_PER_TICK
	if _ai:
		_gather_teams()
	if _front_active() and not bots.is_empty() and _server.tick >= _next_relief_review:
		_next_relief_review = _server.tick + RELIEF_TICKS
		_review_front()
	var soldiers := _server.soldiers
	var tick := _server.tick
	for bot in bots:
		var soldier := soldiers.at(bot.soldier & (SoldierSet.MAX_SOLDIERS - 1))
		if soldier == null or not soldier.alive:
			continue
		if _ai and tick >= bot.think_at and _rays > 0:
			_think(bot, soldier)
		match bot.state:
			State.ENGAGE:
				_fight(bot, soldier)
			_:
				_walk(bot, soldier)
				_arm(bot, soldier, _mend(bot, soldier))


func _gather_teams() -> void:
	for team in 3:
		_team_ids[team].resize(0)
		_team_positions[team].resize(0)
	var soldiers := _server.soldiers
	for slot in soldiers.slots():
		var soldier := soldiers.at(slot)
		if soldier != null and soldier.alive and soldier.team > 0 and soldier.team < 3:
			_team_ids[soldier.team].append(soldier.id)
			_team_positions[soldier.team].append(soldier.position)


# Thinking.


## _think looks for an enemy and chooses what to do. An engaged bot keeps its
## target while it sees it; the others take the nearest enemy they see.
func _think(bot: Bot, soldier: Soldier) -> void:
	var tick := _server.tick
	bot.think_at = tick + THINK_TICKS
	if bot.state == State.ENGAGE:
		return
	bot.reload = _wants_reload(soldier)
	var seen := _look(bot, soldier)
	if seen != 0:
		_engage(bot, soldier, seen)
		return
	if tick - bot.hurt_at < ALERT_TICKS and bot.state != State.SEARCH:
		# Shot by someone unseen: look where the shot came from.
		var shooter := _server.soldiers.get_soldier(bot.attacker)
		if shooter != null and shooter.alive:
			_search(bot, shooter.position)
			return
	if bot.state == State.SEARCH and tick - bot.seen_at > SEARCH_TICKS:
		bot.state = State.ADVANCE
		bot.path = PackedVector3Array()


## _look returns the enemy a bot sees, or 0: of those within its view, the
## nearest few, the one that shot it first, each tried with a ray.
func _look(bot: Bot, soldier: Soldier) -> int:
	var enemies := _team_ids[_enemy_of(soldier.team)]
	var positions := _team_positions[_enemy_of(soldier.team)]
	var forward := Vector2(sin(soldier.yaw), -cos(soldier.yaw))
	var alert := _server.tick - bot.hurt_at < ALERT_TICKS
	var cos_view := cos(VIEW_ANGLE)
	var view_range := _contact_range(bot, soldier, alert)
	var near_ids: Array[int] = []
	var near_distances: Array[float] = []
	var from := soldier.position
	for k in enemies.size():
		var to := positions[k] - from
		var flat := Vector2(to.x, to.z)
		var distance := flat.length()
		if distance > view_range:
			continue
		if distance > NOTICE_RANGE and not alert and flat.dot(forward) < cos_view * distance:
			continue
		if enemies[k] == bot.attacker and alert:
			distance = 0.0
		var at := near_ids.size()
		while at > 0 and near_distances[at - 1] > distance:
			at -= 1
		if at >= LOOKS:
			continue
		near_ids.insert(at, enemies[k])
		near_distances.insert(at, distance)
		if near_ids.size() > LOOKS:
			near_ids.pop_back()
			near_distances.pop_back()
	for id in near_ids:
		if _rays <= 0:
			bot.think_at = _server.tick + 1
			return 0
		var enemy := _server.soldiers.get_soldier(id)
		if _sees(soldier, enemy):
			return id
	return 0


func _contact_range(bot: Bot, soldier: Soldier, alert: bool) -> float:
	if bot.state != State.ADVANCE or alert:
		return VIEW_RANGE
	if _opening_until > _server.tick:
		var assigned := _opening_flag(bot, soldier.team)
		return VIEW_RANGE if assigned.contains_flag_position(soldier.position) else OPENING_CONTACT_RANGE
	if _front_active() and bot.index / 2 < _scene.flags.size():
		var flag := _server.flag_match.state.flags[bot.lane]
		var assigned := _scene.flags[bot.lane]
		if _lane_pressure(flag, soldier.team) > 0 and not assigned.contains_flag_position(soldier.position):
			return POINT_CONTACT_RANGE
	return VIEW_RANGE


## _sees tells whether a soldier's eye sees the body or the head of a soldier
## standing at a point, by rays through the static world.
func _sees(soldier: Soldier, target: Soldier) -> bool:
	var eye := soldier.position + Vector3(0, _eye, 0)
	if target.vehicle != 0:
		# A driver is seen by its tank, whose own armour does not hide it.
		if _rays <= 0:
			return false
		_rays -= 1
		var hull := target.position + Vector3.UP * Vehicle.HULL_CENTER.y
		var length := eye.distance_to(hull)
		return _server.cast_ray(eye, (hull - eye) / length, length, Game.LAYER_STATIC) < 0
	for box in [1, 0]:
		if _rays <= 0:
			return false
		_rays -= 1
		var point := Hitboxes.center(box, target.position, target.yaw, true) if target.crouched \
			else target.position + Vector3.UP * (AIM_HEIGHT if box == 1 else HEAD_HEIGHT)
		var distance := eye.distance_to(point)
		var hit := _server.cast_ray(eye, (point - eye) / distance, distance, Game.LAYER_STATIC | Game.LAYER_VEHICLE)
		if hit < 0:
			return true
	return false


func _engage(bot: Bot, soldier: Soldier, enemy: int) -> void:
	var tick := _server.tick
	var target := _server.soldiers.get_soldier(enemy)
	if bot.state != State.ENGAGE or bot.target != enemy:
		bot.noticed_at = tick
		bot.reaction = roundi(_random.randf_range(REACTION.x, REACTION.y) * Game.TICK_RATE)
		var turn := absf(Game.remainder(_yaw_to(soldier, target.position) - soldier.yaw))
		bot.aim_error = Vector2.from_angle(_random.randf() * TAU) * ACQUIRE_ERROR * bot.skill * (1.0 + turn)
		bot.burst_until = 0
		bot.rest_until = tick + bot.reaction
	bot.state = State.ENGAGE
	bot.target = enemy
	bot.seen_at = tick
	bot.last_seen = target.position
	bot.check_at = tick + SIGHT_TICKS


func _search(bot: Bot, at: Vector3) -> void:
	_end_special(bot)
	bot.state = State.SEARCH
	bot.target = 0
	bot.goal = at
	bot.sprint = false
	bot.seen_at = _server.tick
	bot.path = PackedVector3Array()


static func _enemy_of(team: int) -> int:
	return Game.Team.RED if team == Game.Team.BLUE else Game.Team.BLUE


# Fighting.


## _fight is a tick of an engaged bot: it checks its target, turns to it with
## its error, picks a weapon by the distance, fires in bursts and steps aside;
## or it fires a rocket or throws a grenade, standing.
func _fight(bot: Bot, soldier: Soldier) -> void:
	var tick := _server.tick
	var target := _server.soldiers.get_soldier(bot.target)
	if target == null or not target.alive:
		_end_special(bot)
		bot.state = State.ADVANCE
		bot.target = 0
		bot.think_at = tick + 1
		bot.linger_until = tick + _random.randi_range(Game.TICK_RATE, 2 * Game.TICK_RATE)
		bot.path = PackedVector3Array()
		_halt(soldier)
		_arm(bot, soldier, 0)
		return
	if tick >= bot.check_at and _rays > 0:
		bot.check_at = tick + SIGHT_TICKS
		if _sees(soldier, target):
			bot.seen_at = tick
			bot.last_seen = target.position
	if tick - bot.seen_at > LOSE_TICKS:
		_search(bot, bot.last_seen)
		_arm(bot, soldier, 0)
		return
	# The bot sees its target as it was a reaction ago.
	var seen := target.position
	var seen_yaw := target.yaw
	var seen_crouched := target.crouched
	var pose := _server.history.at(target.id, tick - 1 - bot.reaction)
	if not pose.is_empty():
		seen = pose[0]
		seen_yaw = pose[1]
		seen_crouched = pose[3]
	var eye := soldier.position + Vector3(0, _eye, 0)
	var point := Hitboxes.center(1, seen, seen_yaw, true) if seen_crouched else seen + Vector3.UP * AIM_HEIGHT
	if target.vehicle != 0:
		# A rocket goes for the hull of a tank, not under it.
		seen += Vector3.UP * (Vehicle.HULL_CENTER.y - ROCKET_HEIGHT)
	var distance := eye.distance_to(point)
	_plan_special(bot, soldier, distance)
	if bot.special < 0:
		_choose_weapon(bot, soldier, distance)
	var tuning := _rules.weapons.get_tuning(soldier.arsenal.weapons[bot.weapon])
	var angles := _aim(eye, seen, point, target.velocity, tuning)
	if angles == Vector2.INF:
		# A grenade cannot reach that far.
		_end_special(bot)
		_choose_weapon(bot, soldier, distance)
		tuning = _rules.weapons.get_tuning(soldier.arsenal.weapons[bot.weapon])
		angles = _aim(eye, seen, point, target.velocity, null)
	bot.aim_error = bot.aim_error * _aim_settle + Vector2(_random.randf_range(-1, 1), _random.randf_range(-1, 1)) * NOISE
	var steady := STEADY_ERROR * bot.skill * (1.0 + Game.horizontal_length(soldier.velocity) / _rules.movement.walk_speed)
	if bot.aim_error.length() < steady:
		bot.aim_error = bot.aim_error.normalized() * steady if bot.aim_error != Vector2.ZERO else Vector2(steady, 0)
	_turn(soldier, angles.x + bot.aim_error.x, angles.y + bot.aim_error.y)
	var on_target := absf(Game.remainder(soldier.yaw - angles.x)) < FIRE_CONE and absf(soldier.pitch - angles.y) < FIRE_CONE
	var ready := on_target and tick - bot.seen_at <= SIGHT_TICKS and tick >= bot.noticed_at + bot.reaction
	if bot.special >= 0:
		_halt(soldier)
		var arsenal := soldier.arsenal
		var armed := arsenal.current == bot.special and arsenal.action == Arsenal.Action.READY and arsenal.cooldown == 0
		var fired := _arm(bot, soldier, InputCommand.FIRE if ready and armed else 0)
		if fired or tick >= bot.special_until:
			_end_special(bot)
		return
	var kind := soldier.arsenal.weapons[bot.weapon]
	var reach: float = REACH.get(kind, 100.0)
	var push := minf(SHOTGUN_PUSH if kind == WeaponTuning.Kind.SHOTGUN else PUSH_RANGE, reach)
	if _rush(bot, soldier, distance, push, kind == WeaponTuning.Kind.SHOTGUN):
		_arm(bot, soldier, 0)
		return
	_dodge(bot, soldier, distance)
	var buttons := 0
	if distance > AIM_RANGE:
		buttons |= InputCommand.AIM
	if ready and distance <= reach and _burst(bot, soldier, distance):
		buttons |= InputCommand.FIRE
	_arm(bot, soldier, buttons)


## _aim is the yaw and pitch from the eye to hit a target seen standing at a
## point, moving at a velocity, with a weapon: at the point of its body with a
## gun, at its feet where a rocket will meet it, or the throw of a grenade that
## lands by it. It is Vector2.INF where a throw cannot reach.
static func _aim(eye: Vector3, seen: Vector3, body_point: Vector3, velocity: Vector3, tuning: WeaponTuning) -> Vector2:
	if tuning == null or tuning.use != WeaponTuning.Use.PROJECTILE:
		var body := body_point - eye
		return Vector2(Game.yaw_of(body), atan2(body.y, Vector2(body.x, body.z).length()))
	var at := seen
	if tuning.bounce <= 0:
		var flight := eye.distance_to(seen) / tuning.projectile_speed
		at = seen + Vector3(velocity.x, 0, velocity.z) * flight + Vector3(0, ROCKET_HEIGHT, 0)
	return lob(eye, at, tuning)


## lob is the yaw and pitch that sends a projectile of a weapon from a point
## to land on another, on the lower of the two arcs that reach it, or
## Vector2.INF when none does.
static func lob(from: Vector3, to: Vector3, tuning: WeaponTuning) -> Vector2:
	var offset := to - from
	var across := Vector2(offset.x, offset.z).length()
	var yaw := Game.yaw_of(offset)
	var speed := tuning.projectile_speed
	var gravity := tuning.projectile_gravity
	if gravity <= 0 or across < 1e-3:
		return Vector2(yaw, atan2(offset.y, across))
	var root := speed * speed * speed * speed - gravity * (gravity * across * across + 2 * offset.y * speed * speed)
	if root < 0:
		return Vector2.INF
	return Vector2(yaw, atan((speed * speed - sqrt(root)) / (gravity * across)))


## _plan_special decides, once a second, whether a bot fires a rocket or
## throws a grenade at an enemy at a distance, and takes it in hand.
func _plan_special(bot: Bot, soldier: Soldier, distance: float) -> void:
	var tick := _server.tick
	if bot.special >= 0 or tick < bot.special_at:
		return
	bot.special_at = tick + Game.TICK_RATE
	var arsenal := soldier.arsenal
	for slot in Arsenal.MAX_LOADOUT:
		if arsenal.magazine[slot] + arsenal.reserve[slot] == 0:
			continue
		var wanted := false
		match arsenal.weapons[slot]:
			WeaponTuning.Kind.ROCKET_LAUNCHER:
				wanted = distance >= ROCKET_RANGE.x and distance <= ROCKET_RANGE.y and _random.randf() < ROCKET_CHANCE
			WeaponTuning.Kind.GRENADE:
				wanted = distance >= GRENADE_RANGE.x and distance <= GRENADE_RANGE.y and _random.randf() < GRENADE_CHANCE
		if wanted:
			bot.special = slot
			bot.weapon = slot
			bot.special_until = tick + SPECIAL_TICKS
			return


func _end_special(bot: Bot) -> void:
	if bot.special < 0:
		return
	bot.special = -1
	bot.special_at = _server.tick + roundi(_random.randf_range(SPECIAL_PAUSE.x, SPECIAL_PAUSE.y) * Game.TICK_RATE)


## _mend has a wounded bot out of the fight take its medkit and use it, and
## put it away again; it returns the buttons it presses.
func _mend(bot: Bot, soldier: Soldier) -> int:
	var arsenal := soldier.arsenal
	var slot := _slot_of(arsenal, WeaponTuning.Kind.MEDKIT)
	if slot < 0:
		return 0
	if soldier.health >= HEAL_BELOW or _server.tick - bot.hurt_at < HEAL_CALM or arsenal.magazine[slot] == 0:
		if bot.weapon == slot:
			bot.weapon = _best_gun(arsenal, 30.0)
		return 0
	bot.weapon = slot
	if arsenal.current == slot and arsenal.action == Arsenal.Action.READY and arsenal.cooldown == 0:
		return InputCommand.FIRE
	return 0


static func _slot_of(arsenal: Arsenal, kind: int) -> int:
	for slot in Arsenal.MAX_LOADOUT:
		if arsenal.weapons[slot] == kind:
			return slot
	return -1


## _rush moves a bot that fights a target farther than push towards it, in
## rushes along the mesh with holds to shoot between them; a bot with a
## shotgun, which does nothing far away, runs and hardly holds. It returns
## whether the bot rushes this tick, when it does not shoot.
func _rush(bot: Bot, soldier: Soldier, distance: float, push: float, charge: bool = false) -> bool:
	var tick := _server.tick
	if distance <= push:
		bot.push_until = 0
		return false
	if tick >= bot.push_until and tick >= bot.hold_until and _paths > 0:
		_paths -= 1
		bot.path = _server.navigation.path(soldier.position, bot.last_seen)
		bot.corner = 1
		bot.push_until = tick + _random.randi_range(70, 150)
		bot.hold_until = bot.push_until + (_random.randi_range(10, 40) if charge else _random.randi_range(90, 210))
	if tick >= bot.push_until or bot.path.size() < 2 or bot.corner >= bot.path.size():
		return false
	var speed := _rules.movement.sprint_speed if charge else _rules.movement.walk_speed
	if not _follow(bot, soldier, speed):
		bot.push_until = tick
	return true


## _burst tells whether a bot holds the trigger this tick: an automatic weapon
## fires in bursts with rests between, longer the farther the target; a
## weapon that is not fires a shot at a time with a pause to settle.
func _burst(bot: Bot, soldier: Soldier, distance: float) -> bool:
	var tick := _server.tick
	if tick < bot.rest_until:
		return false
	if tick < bot.burst_until:
		return true
	if bot.burst_until > bot.rest_until:
		# The burst is over: rest.
		var rest := 0.15 + distance / 120.0
		bot.rest_until = tick + roundi(_random.randf_range(rest, rest * 2.5) * Game.TICK_RATE)
		return false
	var tuning := _rules.weapons.get_tuning(soldier.arsenal.weapon())
	var length := 1
	if tuning != null and tuning.automatic:
		var seconds := clampf(0.7 - distance / 80.0, 0.12, 0.6)
		length = roundi(_random.randf_range(seconds * 0.6, seconds * 1.4) * Game.TICK_RATE)
	bot.burst_until = tick + maxi(1, length)
	return true


## _choose_weapon takes the gun that suits the distance best, of those with
## rounds left: the shotgun up close, the rifle far away, the assault rifle
## between, the pistol when nothing else is left. It keeps a weapon it has
## just taken until it is ready, and one it reloads.
func _choose_weapon(bot: Bot, soldier: Soldier, distance: float) -> void:
	var arsenal := soldier.arsenal
	if arsenal.action == Arsenal.Action.EQUIPPING:
		return
	var best := _best_gun(arsenal, distance)
	if best < 0 or best == bot.weapon:
		return
	if arsenal.action == Arsenal.Action.RELOADING and arsenal.current == bot.weapon and _is_gun(arsenal.weapons[bot.weapon]):
		return
	bot.weapon = best


## _best_gun is the slot of the gun with rounds best at a distance, or -1.
static func _best_gun(arsenal: Arsenal, distance: float) -> int:
	var best := -1
	var best_score := 0.0
	for slot in Arsenal.MAX_LOADOUT:
		var kind := arsenal.weapons[slot]
		if not _is_gun(kind) or arsenal.magazine[slot] + arsenal.reserve[slot] == 0:
			continue
		var score := 0.0
		match kind:
			WeaponTuning.Kind.SHOTGUN:
				score = 5.0 if distance < 15 else (2.0 if distance < REACH[kind] else 0.2)
			WeaponTuning.Kind.RIFLE:
				score = 4.0 if distance > RIFLE_RANGE else 1.0
			WeaponTuning.Kind.ASSAULT_RIFLE:
				score = 3.0 if distance < 90 else 1.5
			WeaponTuning.Kind.PISTOL:
				score = 0.8 if distance < 40 else 0.3
		if score > best_score:
			best = slot
			best_score = score
	return best


static func _is_gun(kind: int) -> bool:
	return REACH.has(kind)


## _dodge steps a bot aside while it fights near, or after a hit, and stands
## it still to shoot far; it stays on the ground it can walk.
func _dodge(bot: Bot, soldier: Soldier, distance: float) -> void:
	var tick := _server.tick
	var close := distance < STRAFE_RANGE or tick - bot.hurt_at < Game.TICK_RATE
	if not close:
		_halt(soldier)
		return
	if tick >= bot.strafe_until:
		bot.strafe = [-1.0, 1.0][_random.randi() % 2] if _random.randf() < 0.8 else 0.0
		bot.strafe_until = tick + _random.randi_range(40, 100)
	if bot.strafe == 0.0:
		_halt(soldier)
		return
	var right := Vector3(cos(soldier.yaw), 0, sin(soldier.yaw))
	var speed := _rules.movement.walk_speed * 0.55
	if not _step(soldier, right * bot.strafe * speed):
		bot.strafe = -bot.strafe
		_halt(soldier)


## _arm works the weapons of a bot for a tick with the buttons it holds, and
## returns whether it fired. A bot that is not fighting reloads a weapon half
## empty, when its thought asks; an idle arsenal needs no tick.
func _arm(bot: Bot, soldier: Soldier, buttons: int) -> bool:
	var arsenal := soldier.arsenal
	if buttons == 0 and arsenal.action == Arsenal.Action.READY and arsenal.cooldown == 0 and arsenal.current == bot.weapon \
			and arsenal.bloom == 0.0 and arsenal.kick_pitch == 0.0 and arsenal.kick_yaw == 0.0:
		if not bot.reload:
			return false
		bot.reload = false
		buttons = InputCommand.RELOAD
	var tick := _server.tick
	var command := InputCommand.create(tick, 0, 0, soldier.yaw, soldier.pitch, buttons)
	command.weapon = bot.weapon
	var speed := Game.horizontal_length(soldier.velocity) / _rules.movement.sprint_speed
	var result := arsenal.step(_rules.weapons, command, speed, false, Arsenal.shot_seed(_server.match_seed, soldier.id, tick),
		soldier.health < Game.MAX_HEALTH)
	if not result.has(Arsenal.EVENT_FIRED):
		return false
	result.shot.origin = soldier.position + Vector3(0, _eye, 0)
	_server.queue_shot(soldier, result.shot, tick - 1)
	return true


func _wants_reload(soldier: Soldier) -> bool:
	var arsenal := soldier.arsenal
	var tuning := _rules.weapons.get_tuning(arsenal.weapon())
	return tuning != null and arsenal.magazine[arsenal.current] * 2 < tuning.magazine and arsenal.reserve[arsenal.current] > 0


# Walking.


## _walk moves a bot along its way at a run, or a walk while it searches: to
## a goal it picks, where it lingers, looking about.
func _walk(bot: Bot, soldier: Soldier) -> void:
	var tick := _server.tick
	if bot.path.is_empty() or bot.corner >= bot.path.size():
		if bot.state == State.SEARCH and not bot.path.is_empty():
			# Nobody where the enemy was.
			bot.state = State.ADVANCE
			bot.linger_until = tick + _random.randi_range(Game.TICK_RATE, 3 * Game.TICK_RATE)
			bot.path = PackedVector3Array()
		if tick < bot.linger_until:
			_halt(soldier)
			_look_about(bot, soldier)
			return
		if _paths <= 0:
			_halt(soldier)
			return
		_paths -= 1
		if bot.state != State.SEARCH:
			if _opening_until > tick:
				bot.goal = _flag_approach(_opening_flag(bot, soldier.team))
				bot.sprint = true
			elif _front_active():
				var flag := _server.flag_match.state.flags[bot.lane]
				bot.goal = _front_goal(bot, soldier.team, flag)
				bot.sprint = flag.owner != soldier.team or flag.contested or flag.challenger != Game.Team.NONE
			else:
				bot.goal = _pick_goal(soldier)
				bot.sprint = _random.randf() < 0.75
		bot.path = _server.navigation.path(soldier.position, bot.goal)
		bot.corner = 1
		bot.progress_at = tick
		bot.progress_from = soldier.position
		if bot.path.size() < 2:
			bot.path = PackedVector3Array()
			bot.linger_until = tick + Game.TICK_RATE
			_halt(soldier)
			return
	var speed := _rules.movement.sprint_speed if bot.sprint and bot.state == State.ADVANCE else _rules.movement.walk_speed
	if _follow(bot, soldier, speed):
		_turn(soldier, Game.yaw_of(soldier.velocity), 0.0)
	elif not bot.path.is_empty() and bot.state == State.ADVANCE:
		bot.linger_until = tick + _linger()
	if tick - bot.progress_at >= STUCK_TICKS:
		if soldier.position.distance_to(bot.progress_from) < 1.0 and tick >= bot.linger_until:
			bot.path = PackedVector3Array()
			bot.linger_until = 0
		bot.progress_at = tick
		bot.progress_from = soldier.position


## _follow moves a bot a tick along its path at a speed, clear of the others.
## It returns false at the end of the path, and against a wall, where it
## drops the path. A bot has no body to keep it off walls: one pressed against
## a wall steps back onto the mesh.
func _follow(bot: Bot, soldier: Soldier, speed: float) -> bool:
	var corner := bot.path[bot.corner]
	var to := Vector3(corner.x - soldier.position.x, 0, corner.z - soldier.position.z)
	var distance := to.length()
	while distance < 0.6 and bot.corner + 1 < bot.path.size():
		bot.corner += 1
		corner = bot.path[bot.corner]
		to = Vector3(corner.x - soldier.position.x, 0, corner.z - soldier.position.z)
		distance = to.length()
	if distance < 0.6:
		bot.corner = bot.path.size()
		_halt(soldier)
		return false
	var direction := to / distance
	if (_server.tick + bot.index) % PUSH_TICKS == 0:
		bot.push = _away_from_others(soldier)
	var velocity := (direction + bot.push).normalized() * speed
	if not _step(soldier, velocity) and not _step(soldier, direction * speed):
		bot.path = PackedVector3Array()
		_halt(soldier)
		_step_back(soldier)
		return false
	return true


## _step_back moves a soldier that strayed off the mesh, against a wall, to
## the nearest point on it.
func _step_back(soldier: Soldier) -> void:
	var back := _server.navigation.closest(soldier.position)
	var offset := Vector3(back.x - soldier.position.x, 0, back.z - soldier.position.z)
	if offset.length() < 0.02 or offset.length() > 1.0:
		return
	var floor := _floor_at(soldier.position + offset, soldier.position.y)
	if floor != -INF:
		soldier.position = Vector3(back.x, floor, back.z)


## _linger is how long a bot stays at a goal it reached: a passive one walks
## on at once.
func _linger() -> int:
	if not _ai:
		return 0
	var minimum := Game.TICK_RATE * 2
	if _server.flag_match != null and _server.flag_match.started:
		minimum = FlagMatch.CAPTURE_TICKS
	return _random.randi_range(minimum, 7 * Game.TICK_RATE)


## _look_about turns a bot that waits now and then to another direction.
func _look_about(bot: Bot, soldier: Soldier) -> void:
	if _front_active() and bot.state == State.ADVANCE:
		var heading := -signf(_scene.spawn_of(soldier.team).z)
		var sweep := 0.6 * sin(float(_server.tick + bot.index * 11) * 0.028)
		_turn(soldier, Game.yaw_of(Vector3(sweep, 0, heading)), 0.0)
		return
	if (_server.tick + bot.index * 7) % 90 == 0:
		bot.aim_error = Vector2(_random.randf_range(-1.2, 1.2), 0)
	var wanted := soldier.yaw + clampf(bot.aim_error.x, -TURN_SPEED / Game.TICK_RATE, TURN_SPEED / Game.TICK_RATE) * 0.25
	bot.aim_error.x *= 0.95
	_turn(soldier, wanted, 0.0)


## _pick_goal chooses where a bot goes next: a random point of a place worth
## fighting for, now and then the enemy's base.
func _pick_goal(soldier: Soldier) -> Vector3:
	var zone: MapScene.Zone
	var round := _server.flag_match
	if _ai and round != null and round.started and round.state.result == MatchState.Result.ACTIVE:
		return _flag_approach(_flag_goal(soldier.team, round))
	if _scene.objectives.is_empty() or (_ai and _random.randf() < 0.12):
		zone = _scene.zone_of(_enemy_of(soldier.team))
	else:
		zone = _scene.objectives[_random.randi_range(0, _scene.objectives.size() - 1)]
	var offset := Vector2.from_angle(_random.randf() * TAU) * sqrt(_random.randf()) * zone.radius
	return _server.navigation.closest(zone.center + Vector3(offset.x, 0.5, offset.y))


func _flag_approach(zone: MapScene.Zone) -> Vector3:
	var approach := Vector2.from_angle(_random.randf() * TAU) * zone.radius * _random.randf() * 0.4
	return _server.navigation.closest(zone.center + Vector3(approach.x, 0.5, approach.y))


## Each two-bot pair gets one lane. Rotate the lane order for Red as the
## map is rotated, so the near bridge is the same job for either team.
func _opening_flag(bot: Bot, team: int) -> MapScene.Zone:
	return _scene.flags[_home_lane(bot, team)]


func _home_lane(bot: Bot, team: int) -> int:
	var count := _scene.flags.size()
	var lane := (bot.index / 2 + 1) % count
	return lane if team == Game.Team.BLUE else count - 1 - lane


func _front_active() -> bool:
	var round := _server.flag_match
	return _ai and _scene.name == "valley" and round != null \
		and _opening_until >= 0 and _server.tick >= _opening_until \
		and round.started and round.state.result == MatchState.Result.ACTIVE


## Most of each squad stays assigned to its crossing. At each review, one
## idle reserve per side can leave a secure owned crossing to help next door.
func _review_front() -> void:
	var round := _server.flag_match
	var count := round.zones.size()
	for team: int in [Game.Team.BLUE, Game.Team.RED]:
		var choice: Bot
		var destination := -1
		var highest := 0
		for bot in bots:
			var soldier := _server.soldiers.get_soldier(bot.soldier)
			if soldier.team != team:
				continue
			var home := _home_lane(bot, team)
			if bot.index / 2 / count < 2 or not soldier.alive or bot.state != State.ADVANCE:
				continue
			if _lane_pressure(round.state.flags[home], team) != 0:
				continue
			for next in [home - 1, home + 1]:
				if next < 0 or next >= count:
					continue
				var pressure := _lane_pressure(round.state.flags[next], team)
				if pressure > highest:
					choice = bot
					destination = next
					highest = pressure
		for bot in bots:
			var soldier := _server.soldiers.get_soldier(bot.soldier)
			if soldier.team != team:
				continue
			var next := destination if bot == choice else _home_lane(bot, team)
			if bot.lane == next:
				continue
			bot.lane = next
			if bot.state == State.ADVANCE:
				bot.path = PackedVector3Array()
				bot.linger_until = 0


static func _lane_pressure(flag: MatchState.Flag, team: int) -> int:
	if flag.contested or (flag.challenger != Game.Team.NONE and flag.challenger != team):
		return 3
	if flag.owner != Game.Team.NONE and flag.owner != team:
		return 2
	return 0 if flag.owner == team else 1


## Squads use several distinct points on a crossing. Hold on the friendly
## half and push into the capture area when the objective changes hands.
func _front_goal(bot: Bot, team: int, flag: MatchState.Flag) -> Vector3:
	var zone := _scene.flags[bot.lane]
	var rank := bot.index / 2 / _scene.flags.size()
	var home_side := 1.0 if _scene.spawn_of(team).z > zone.center.z else -1.0
	var width := zone.radius * (0.29 if bot.lane == 1 else 0.15)
	var across := width * float(rank % 3 - 1)
	var depth := zone.radius * (0.46 + 0.19 * float(rank % 2)) if flag.owner == team \
		else zone.radius * (0.17 - 0.34 * float(rank % 2))
	var aim := zone.center + Vector3(home_side * across, 0.5, home_side * depth)
	return _server.navigation.closest(aim)


func _flag_goal(team: int, round: FlagMatch) -> MapScene.Zone:
	# A mix of attack and defense keeps some bots spread across the crossings.
	if _random.randf() < 0.75:
		var start := _random.randi_range(0, round.zones.size() - 1)
		for offset in round.zones.size():
			var index := (start + offset) % round.zones.size()
			if round.state.flags[index].owner != team:
				return round.zones[index]
	return round.zones[_random.randi_range(0, round.zones.size() - 1)]


## _away_from_others is the push that keeps a bot clear of the soldiers near it.
func _away_from_others(soldier: Soldier) -> Vector3:
	var grid := _server.grid
	var push := Vector3.ZERO
	var near := grid.near(soldier.position, SPACING)
	for k in near:
		var away := soldier.position - grid.positions[k]
		away.y = 0
		var distance := Game.horizontal_length(away)
		if grid.ids[k] != soldier.id and distance > 1e-3:
			push += away * ((SPACING - distance) / (SPACING * distance))
	return push


## _step moves a soldier by a velocity for a tick onto the ground there. It
## does not move it, and returns false, into a wall or off a ledge.
func _step(soldier: Soldier, velocity: Vector3) -> bool:
	var next := soldier.position + velocity * Game.TICK_DELTA
	next.x = clampf(next.x, -_area, _area)
	next.z = clampf(next.z, -_area, _area)
	var floor := _floor_at(next, soldier.position.y)
	if floor == -INF:
		return false
	next.y = floor
	soldier.velocity = (next - soldier.position) * Game.TICK_RATE
	soldier.position = next
	return true


func _halt(soldier: Soldier) -> void:
	soldier.velocity = Vector3.ZERO


## _turn turns a soldier towards a yaw and pitch, no faster than a bot turns.
func _turn(soldier: Soldier, yaw: float, pitch: float) -> void:
	var most := TURN_SPEED / Game.TICK_RATE
	soldier.yaw = Game.remainder(soldier.yaw + clampf(Game.remainder(yaw - soldier.yaw), -most, most))
	soldier.pitch = clampf(soldier.pitch + clampf(pitch - soldier.pitch, -most, most), -1.4, 1.4)


static func _yaw_to(soldier: Soldier, at: Vector3) -> float:
	return Game.yaw_of(at - soldier.position)


# The ground.


## _map_open_ground marks the cells of the play area where the ground is
## known without a ray: on a map with terrain, those no box stands over; on a
## map without, those whose every corner meets the floor at zero from above.
func _map_open_ground() -> void:
	_cells = ceili(2 * _area / OPEN_CELL)
	_open.resize(_cells * _cells)
	if _scene.terrain != null:
		_open.fill(1)
		for box in _scene.boxes:
			var bounds := box.transform * AABB(-box.half_extents, 2 * box.half_extents)
			var low := _cell_of(bounds.position - Vector3(0.6, 0, 0.6))
			var high := _cell_of(bounds.end + Vector3(0.6, 0, 0.6))
			for z in range(maxi(low.y, 0), mini(high.y + 1, _cells)):
				for x in range(maxi(low.x, 0), mini(high.x + 1, _cells)):
					_open[z * _cells + x] = 0
		return
	var corners := PackedByteArray()
	corners.resize((_cells + 1) * (_cells + 1))
	for z in _cells + 1:
		for x in _cells + 1:
			var at := Vector3(-_area + x * OPEN_CELL, 10, -_area + z * OPEN_CELL)
			var down := _server.cast_ray(at, Vector3.DOWN, 11, Game.LAYER_STATIC)
			corners[z * (_cells + 1) + x] = 1 if down >= 0 and absf(10 - down) < 1e-3 else 0
	for z in _cells:
		for x in _cells:
			var row := z * (_cells + 1) + x
			_open[z * _cells + x] = corners[row] & corners[row + 1] & corners[row + _cells + 1] & corners[row + _cells + 2]


func _cell_of(at: Vector3) -> Vector2i:
	return Vector2i(floori((at.x + _area) / OPEN_CELL), floori((at.z + _area) / OPEN_CELL))


## _floor_at returns the height of the ground under a bot stepping to next
## from the height from, or -INF for a wall or a ledge: from the terrain or
## the floor in an open cell, or by a ray from the height of a step.
func _floor_at(next: Vector3, from: float) -> float:
	var x := floori((next.x + _area) / OPEN_CELL)
	var z := floori((next.z + _area) / OPEN_CELL)
	if x >= 0 and z >= 0 and x < _cells and z < _cells and _open[z * _cells + x] == 1:
		var ground := _scene.ground_at(next.x, next.z)
		if absf(ground - from) <= STEP_HEIGHT:
			return ground
	var start := Vector3(next.x, from + STEP_HEIGHT, next.z)
	var down := _server.cast_ray(start, Vector3.DOWN, STEP_HEIGHT + DROP_HEIGHT, Game.LAYER_STATIC)
	if down <= 0:
		return -INF
	return start.y - down


## _floor_point picks a random point of the open ground of a map whose zones
## are points, to spawn a bot anywhere.
func _floor_point() -> Vector3:
	for attempt in 100:
		var point := Vector3(_random.randf_range(-_area, _area), 0, _random.randf_range(-_area, _area))
		var spawn := _scene.spawn
		if Vector2(point.x - spawn.x, point.z - spawn.z).length() < 2:
			continue
		var cell := _cell_of(point)
		if _open[cell.y * _cells + cell.x] == 1:
			point.y = _scene.ground_at(point.x, point.z)
			return point
	return _scene.spawn
