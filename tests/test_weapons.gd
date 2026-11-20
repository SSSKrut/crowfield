extends TestCase
## The weapons: rates, single fire, reloads, switching, dry fire, a spread that
## repeats, the kick, falloff and the tuning files.

var _weapons := WeaponSet.create_default()
var _arsenal := Arsenal.create(Arsenal.default_loadout(), _weapons)
var _tick := 0


## _step steps the soldier's weapons the way run_command does, standing.
func _step(buttons: int, slot: int) -> WeaponStep:
	var command := InputCommand.create(_tick, 0, 0, 0, 0, buttons)
	command.weapon = slot
	var result := _arsenal.step(_weapons, command, 0.0, false, Arsenal.shot_seed(1, 0x1001, _tick))
	_tick += 1
	return result


## _run steps the same buttons for count ticks and returns [the ticks it fired
## at, counted from the first, and the events].
func _run(count: int, buttons: int, slot: int) -> Array:
	var shots := PackedInt32Array()
	var events := 0
	for i in count:
		var result := _step(buttons, slot)
		events |= result.events
		if result.has(Arsenal.EVENT_FIRED):
			shots.append(i)
	return [shots, events]


func test_default_weapons_are_valid() -> void:
	check_equal(_weapons.validate(), "", "default weapons")
	check_equal(Rules.new().validate(), "", "default rules")


func test_weapon_hash_changes_with_every_field() -> void:
	var seen := {_weapons.hash_value(): "default"}
	check_equal(_weapons.hash_value(), WeaponSet.create_default().hash_value(), "a stable hash")
	for kind in range(1, WeaponTuning.KINDS):
		for field in WeaponTuning.FIELDS:
			var changed := WeaponSet.create_default()
			var tuning := changed.get_tuning(kind)
			var value: Variant = tuning.get(field)
			if value is bool:
				tuning.set(field, not value)
			elif value is int:
				tuning.set(field, value + 1)
			else:
				tuning.set(field, value + 0.25)
			var name := "%s %s" % [WeaponTuning.kind_name(kind), field]
			var hash := changed.hash_value()
			check(not seen.has(hash), "changing %s gives the same hash as %s" % [name, seen.get(hash, "")])
			seen[hash] = name


func test_rules_hash_covers_movement_and_weapons() -> void:
	var base := Rules.new()
	var moved := Rules.new()
	moved.movement.walk_speed += 1
	var armed := Rules.new()
	armed.weapons.pistol.damage += 1
	check(base.hash_value() != moved.hash_value() and base.hash_value() != armed.hash_value() and moved.hash_value() != armed.hash_value(),
		"the rules hash misses a change")


func _tuning_file(content: String) -> String:
	var path := OS.get_user_data_dir().path_join("weapons-test-%d.json" % Time.get_ticks_usec())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	cleanup(func() -> void: DirAccess.remove_absolute(path))
	return path


func test_load_weapons_overrides_defaults() -> void:
	var weapons := WeaponSet.create_default()
	check_equal(weapons.load_json(_tuning_file('{"rifle": {"damage": 60, "magazine": 5}}')), "", "loading")
	check(weapons.rifle.damage == 60 and weapons.rifle.magazine == 5 and weapons.pistol.damage == _weapons.pistol.damage,
		"loaded rifle %s/%s" % [weapons.rifle.damage, weapons.rifle.magazine])
	var bad := {
		"unknown weapon": '{"flamethrower": {"damage": 60}}',
		"no pellets": '{"shotgun": {"pellets": 0}}',
		"a grenade without a fuse": '{"grenade": {"fuse": 0}}',
		"a blast inside out": '{"rocket_launcher": {"blast_inner": 7}}',
		"a medkit that heals nothing": '{"medkit": {"heal": 0}}',
		"an unknown use": '{"pistol": {"use": 3}}',
		"unknown field": '{"pistol": {"damge": 60}}',
		"empty magazine": '{"pistol": {"magazine": 0}}',
		"huge magazine": '{"pistol": {"magazine": 300}}',
		"slow reload": '{"rifle": {"reload_time": 5}}',
		"falloff order": '{"rifle": {"falloff_end": 50}}',
		"fractional magazine": '{"rifle": {"magazine": 5.5}}',
	}
	for name in bad:
		check(WeaponSet.create_default().load_json(_tuning_file(bad[name])) != "", "%s: accepted" % name)


func test_automatic_fires_at_its_rate() -> void:
	var shots: PackedInt32Array = _run(Game.TICK_RATE, InputCommand.FIRE, 0)[0]
	check(shots.size() == 10 and shots[0] == 0 and shots[1] == 6 and shots[9] == 54,
		"an assault rifle held for a second fired at ticks %s, want every 6th from 0" % shots)
	check(_arsenal.magazine[0] == 20 and _arsenal.reserve[0] == 120, "ammo %d/%d after 10 shots" % [_arsenal.magazine[0], _arsenal.reserve[0]])


func test_semi_automatic_fires_once_per_pull() -> void:
	_run(_weapons.rifle.equip_ticks(), 0, 1)
	var held: PackedInt32Array = _run(Game.TICK_RATE, InputCommand.FIRE, 1)[0]
	check_equal(held.size(), 1, "rifle shots while held for a second")
	# A pull during the cooldown fires when the cooldown ends, if still held.
	_run(1, 0, 1)
	check_equal((_run(1, InputCommand.FIRE, 1)[0] as PackedInt32Array).size(), 1, "shots of a new pull")
	_run(1, 0, 1)
	var interval := _weapons.rifle.fire_interval()
	var shots: PackedInt32Array = _run(interval, InputCommand.FIRE, 1)[0]
	check(shots.size() == 1 and shots[0] == interval - 2, "a pull right after a shot fired at %s, want when the cooldown ends" % shots)


func test_repeated_commands_do_not_pull_again() -> void:
	_run(_weapons.pistol.equip_ticks(), 0, 2)
	var command := InputCommand.create(_tick, 0, 0, 0, 0, InputCommand.FIRE | InputCommand.RELOAD)
	command.weapon = 2
	var fired := 0
	for i in Game.TICK_RATE:
		var result := _arsenal.step(_weapons, command, 0.0, false, 0)
		if result.has(Arsenal.EVENT_FIRED):
			fired += 1
		if result.has(Arsenal.EVENT_RELOAD_STARTED) and fired == 0:
			fail("reloaded a full magazine")
		command = command.repeated(command.tick + 1)
	check_equal(fired, 1, "pistol shots while its command was repeated")


func test_empty_magazine_reloads_on_the_pull() -> void:
	var reload := _weapons.assault_rifle.reload_ticks()
	var result := _run(30 * 6 + 1, InputCommand.FIRE, 0)
	if not check((result[0] as PackedInt32Array).size() == 30 and result[1] & Arsenal.EVENT_RELOAD_STARTED,
			"%d shots, events %d: want the magazine emptied and a reload" % [(result[0] as PackedInt32Array).size(), result[1]]):
		return
	check(_arsenal.action == Arsenal.Action.RELOADING and _arsenal.action_ticks == reload, "action %d with %d ticks left" % [_arsenal.action, _arsenal.action_ticks])
	result = _run(reload, InputCommand.FIRE, 0)
	var shots: PackedInt32Array = result[0]
	check(result[1] & Arsenal.EVENT_RELOADED and shots.size() == 1 and shots[0] == reload - 1,
		"after the reload: shots %s, events %d; want a shot on the last tick" % [shots, result[1]])
	check(_arsenal.magazine[0] == 29 and _arsenal.reserve[0] == 90, "ammo %d/%d after reloading and one shot" % [_arsenal.magazine[0], _arsenal.reserve[0]])


func test_reload_button_tops_up_the_magazine() -> void:
	_run(5 * 6, InputCommand.FIRE, 0)
	check(_run(1, InputCommand.RELOAD, 0)[1] & Arsenal.EVENT_RELOAD_STARTED, "reload did not start")
	# Fire is ignored while reloading.
	check_equal((_run(_weapons.assault_rifle.reload_ticks() - 1, InputCommand.FIRE, 0)[0] as PackedInt32Array).size(), 0, "shots while reloading")
	check(_run(1, 0, 0)[1] & Arsenal.EVENT_RELOADED, "the reload did not end in time")
	check(_arsenal.magazine[0] == 30 and _arsenal.reserve[0] == 115, "ammo %d/%d after topping up 5 rounds" % [_arsenal.magazine[0], _arsenal.reserve[0]])
	check(not _run(1, InputCommand.RELOAD, 0)[1] & Arsenal.EVENT_RELOAD_STARTED, "reloaded a full magazine")


func test_switching_weapons_takes_time_and_stops_the_reload() -> void:
	_run(6, InputCommand.FIRE, 0)
	_run(1, InputCommand.RELOAD, 0)
	check(_run(1, InputCommand.FIRE, 2)[1] & Arsenal.EVENT_EQUIP_STARTED, "no switch to the pistol")
	var equip := _weapons.pistol.equip_ticks()
	var shots: PackedInt32Array = _run(equip, InputCommand.FIRE, 2)[0]
	check(shots.size() == 1 and shots[0] == equip - 1, "pistol shots %s while equipping for %d ticks" % [shots, equip])
	check(_arsenal.weapon() == WeaponTuning.Kind.PISTOL and _arsenal.magazine[0] == 29,
		"holding %s, assault rifle magazine %d: the reload should have stopped" % [WeaponTuning.kind_name(_arsenal.weapon()), _arsenal.magazine[0]])
	var events: int = _run(1, 0, 7)[1]
	check(events == 0 and _arsenal.current == 2, "a slot out of the loadout switched to %d" % _arsenal.current)


func test_dry_fire_once_per_pull() -> void:
	_arsenal.magazine[0] = 0
	_arsenal.reserve[0] = 0
	var events: int = _run(10, InputCommand.FIRE, 0)[1]
	check(events & Arsenal.EVENT_DRY_FIRE and not events & Arsenal.EVENT_RELOAD_STARTED, "events %d with no rounds at all" % events)
	var dry := 0
	for i in 3:
		if _step(0, 0).events != 0:
			fail("events without a pull")
		if _step(InputCommand.FIRE, 0).has(Arsenal.EVENT_DRY_FIRE):
			dry += 1
	check_equal(dry, 3, "dry clicks for 3 pulls")


func test_spread_is_repeatable_and_within_its_cone() -> void:
	for aim in [0, InputCommand.AIM]:
		var widest := 0.0
		for seed in 200:
			var command := InputCommand.create(0, 0, 0, 1, 0.2, InputCommand.FIRE | aim)
			var first := Arsenal.create(Arsenal.default_loadout(), _weapons).step(_weapons, command, 0.0, false, Arsenal.mix64(seed))
			var again := Arsenal.create(Arsenal.default_loadout(), _weapons).step(_weapons, command, 0.0, false, Arsenal.mix64(seed))
			if first.shot.direction != again.shot.direction:
				fail("the same seed scattered differently")
				return
			var view := Game.view_direction(command.yaw_radians(), command.pitch_radians())
			widest = maxf(widest, acos(minf(1.0, view.dot(first.shot.direction))))
		var spread := deg_to_rad(_weapons.assault_rifle.aim_spread if aim else _weapons.assault_rifle.hip_spread)
		check(widest <= spread * 1.01 and widest >= spread * 0.8, "aim %s: widest shot %.4f rad off, spread %.4f" % [aim != 0, widest, spread])


func test_kick_climbs_and_settles() -> void:
	_run(Game.TICK_RATE, InputCommand.FIRE, 0)
	check(_arsenal.kick_pitch >= deg_to_rad(_weapons.assault_rifle.kick_pitch) and _arsenal.bloom > 0,
		"kick %.4f and bloom %.4f after a burst" % [_arsenal.kick_pitch, _arsenal.bloom])
	_run(3 * Game.TICK_RATE, 0, 0)
	check(_arsenal.kick_pitch == 0 and _arsenal.kick_yaw == 0 and _arsenal.bloom == 0,
		"kick %.6f/%.6f and bloom %.6f after 3 s of rest" % [_arsenal.kick_pitch, _arsenal.kick_yaw, _arsenal.bloom])


func test_damage_falls_off_with_distance() -> void:
	var rifle := _weapons.assault_rifle
	for c in [[0.0, 25.0], [30.0, 25.0], [55.0, 20.0], [80.0, 15.0], [500.0, 15.0]]:
		check_near(rifle.damage_at(c[0]), c[1], 1e-4, "damage at %.0f m" % c[0])


func test_hit_damage_by_zone() -> void:
	var rifle := _weapons.assault_rifle
	for c in [[Hitboxes.Zone.HEAD, 10.0, 50], [Hitboxes.Zone.TORSO, 10.0, 25], [Hitboxes.Zone.LIMB, 10.0, 19],
			[Hitboxes.Zone.TORSO, 300.0, 15], [Hitboxes.Zone.LIMB, 300.0, 11]]:
		check_equal(rifle.hit_damage(c[0], c[1]), c[2], "%s at %.0f m" % [Hitboxes.zone_name(c[0]), c[1]])
	# Two body shots of the rifle and one in the head kill.
	check(_weapons.rifle.hit_damage(Hitboxes.Zone.TORSO, 50) * 2 >= Game.MAX_HEALTH and _weapons.rifle.hit_damage(Hitboxes.Zone.HEAD, 50) >= Game.MAX_HEALTH,
		"the rifle does not kill with two body shots or one in the head")
