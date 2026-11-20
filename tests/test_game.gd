extends TestCase
## The shared game code: commands as they travel, the hitboxes, the grid of
## soldiers and the set they live in.


func test_input_command_quantization_round_trip() -> void:
	for c in [[1.0, 0.0, 0.0, 0.0], [-1.0, 1.0, PI / 2, 0.5], [0.3, -0.7, 3 * PI / 2, -1.45], [0.0, 0.0, TAU - 0.0001, PI / 2]]:
		var command := InputCommand.create(7, c[0], c[1], c[2], c[3], InputCommand.SPRINT)
		check_near(command.forward_axis(), c[0], 1.0 / 127 + 1e-6, "forward of %s" % [c])
		check_near(command.right_axis(), c[1], 1.0 / 127 + 1e-6, "right of %s" % [c])
		check(absf(Game.remainder(command.yaw_radians() - c[2])) <= TAU / 65536, "yaw %f became %f" % [c[2], command.yaw_radians()])
		check_near(command.pitch_radians(), c[3], PI / 2 / 32767 + 1e-6, "pitch of %s" % [c])
		check(command.tick == 7 and command.has(InputCommand.SPRINT) and not command.has(InputCommand.JUMP), "tick or buttons changed")


func test_input_command_wraps_and_clamps() -> void:
	check_equal(InputCommand.create(0, 0, 0, -PI / 2, 0, 0).yaw, InputCommand.create(0, 0, 0, 3 * PI / 2, 0, 0).yaw, "a negative yaw wraps")
	check_equal(InputCommand.create(0, 0, 0, 4 * PI, 0, 0).yaw, 0, "two full turns wrap to zero")
	var command := InputCommand.create(0, 5, -5, 0, 3, 0xFFFF)
	check(command.move_forward == 127 and command.move_right == -127 and command.pitch == 32767, "values were not clamped")
	check_equal(command.buttons, InputCommand.KNOWN_BUTTONS, "buttons")


func test_input_command_sanitize() -> void:
	var command := InputCommand.new()
	command.move_forward = -128
	command.move_right = -128
	command.pitch = -32768
	command.buttons = 0xFFFF
	command.weapon = 200
	command.sanitize()
	check(command.move_forward == -127 and command.move_right == -127 and command.pitch == -32767
		and command.buttons == InputCommand.KNOWN_BUTTONS and command.weapon == InputCommand.MAX_WEAPON_SLOT, "sanitized command")
	check(command.forward_axis() == -1 and command.right_axis() == -1 and command.pitch_radians() >= -PI / 2 - 1e-6, "the sanitized command leaves the range")


func test_repeated_command_drops_one_off_actions() -> void:
	var command := InputCommand.create(10, 1, -1, 2, 0.3,
		InputCommand.JUMP | InputCommand.SPRINT | InputCommand.FIRE | InputCommand.RELOAD | InputCommand.INTERACT)
	var repeated := command.repeated(11)
	var want := command.copy()
	want.tick = 11
	want.buttons = InputCommand.SPRINT | InputCommand.FIRE
	check(repeated.equals(want), "repeated buttons %d tick %d" % [repeated.buttons, repeated.tick])


func test_ray_enters_capsules_and_spheres() -> void:
	var capsule := [Vector3(0, 1, 0), Vector3(0, 2, 0), 0.5]
	var sphere := [Vector3(3, 1, 0), Vector3(3, 1, 0), 0.25]
	for c in [
		["side of the body", capsule, Vector3(-5, 1.5, 0), Vector3(1, 0, 0), 4.5],
		["top cap from above", capsule, Vector3(0, 5, 0), Vector3(0, -1, 0), 2.5],
		["bottom cap along the axis", capsule, Vector3(0, -3, 0), Vector3(0, 1, 0), 3.5],
		["past the side", capsule, Vector3(-5, 1.5, 0.6), Vector3(1, 0, 0), -1.0],
		["away from it", capsule, Vector3(-5, 1.5, 0), Vector3(-1, 0, 0), -1.0],
		["from inside", capsule, Vector3(0, 1.4, 0.1), Vector3(1, 0, 0), -1.0],
		["sphere", sphere, Vector3(3, 1, -4), Vector3(0, 0, 1), 3.75],
		["past the sphere", sphere, Vector3(3, 1.3, -4), Vector3(0, 0, 1), -1.0],
	]:
		var box: Array = c[1]
		var got := Hitboxes.ray_capsule(c[2], c[3], box[0], box[1], box[2])
		check((got < 0) == (c[4] < 0) and (got < 0 or absf(got - c[4]) <= 1e-5), "%s: %.4f, want %.4f" % [c[0], got, c[4]])


## A soldier ten metres ahead, seen from the front, the side and the back:
## shots at the height of the head, the body and the legs hit those zones, and
## a shot past the hands misses.
func test_hitboxes_follow_the_soldier() -> void:
	for yaw in [0.0, PI / 2, PI, -2.5]:
		var position := Vector3(3, 0.5, -10)
		for c in [[1.6, 0.0, Hitboxes.Zone.HEAD], [1.05, 0.0, Hitboxes.Zone.TORSO], [0.7, 0.0, Hitboxes.Zone.TORSO],
				[0.3, 0.26, Hitboxes.Zone.LIMB], [0.6, 1.2, Hitboxes.Zone.NONE]]:
			var sideways := absf(sin(yaw)) > 0.9
			# From the side the arm covers the lower body, and the legs stand one
			# behind the other.
			if sideways and c[0] == 0.7:
				continue
			var origin := Vector3(3 + c[1], 0.5 + c[0], 0)
			if sideways and c[2] == Hitboxes.Zone.LIMB:
				origin.x = 3
			var hit := Hitboxes.ray(origin, Vector3(0, 0, -1), 100, position, yaw)
			var zone := Hitboxes.Zone.NONE if hit.is_empty() else Hitboxes.zone_of(hit[1])
			check_equal(zone, c[2], "yaw %.1f, height %.2f: zone" % [yaw, c[0]])
			if not hit.is_empty():
				check(hit[0] >= 8.5 and hit[0] <= 10, "yaw %.1f, height %.2f: hit at %.2f m, the soldier stands at 10" % [yaw, c[0], hit[0]])
		check(Hitboxes.ray(Vector3(3, 1.5, 0), Vector3(0, 0, -1), 5, position, yaw).is_empty(), "yaw %.1f: a shot reaching 5 m hit a soldier at 10" % yaw)


func test_hitboxes_stay_within_their_reach() -> void:
	for yaw in [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0]:
		for i in Hitboxes.COUNT:
			for end: Vector3 in [Hitboxes.A[i], Hitboxes.B[i]]:
				var at := Hitboxes.place(end, Vector3.ZERO, yaw)
				var reach: float = Vector2(at.x, at.z).length() + Hitboxes.RADII[i]
				check(reach <= Hitboxes.REACH, "yaw %.0f: hitbox %d reaches %.2f m out" % [yaw, i, reach])


func _random_set(random: RandomNumberGenerator) -> SoldierSet:
	var soldiers := SoldierSet.new(300)
	for i in 300:
		var soldier := Soldier.new()
		soldier.position = Vector3(random.randf() * 100 - 50, random.randf() * 3, random.randf() * 100 - 50)
		soldiers.add(soldier)
	return soldiers


func test_soldier_grid_finds_exactly_the_neighbours() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 8
	var soldiers := _random_set(random)
	var grid := SoldierGrid.new(4)
	grid.rebuild(soldiers)
	for round in 200:
		var center := Vector3(random.randf() * 120 - 60, 0, random.randf() * 120 - 60)
		var radius := random.randf() * 20
		var want := {}
		for soldier in soldiers.all():
			var dx := soldier.position.x - center.x
			var dz := soldier.position.z - center.z
			if dx * dx + dz * dz <= radius * radius:
				want[soldier.id] = true
		var found := grid.near(center, radius)
		for k in found:
			if not want.has(grid.ids[k]) or soldiers.get_soldier(grid.ids[k]).position != grid.positions[k]:
				fail("near %s within %.1f: unexpected 0x%04x" % [center, radius, grid.ids[k]])
				return
		if found != want.size():
			fail("near %s within %.1f: found %d of %d" % [center, radius, found, want.size()])
			return


## along_ray finds exactly the soldiers within the margin of a ray's track,
## whatever its direction and length, including rays that start outside the
## occupied part of the grid or stand straight up.
func test_soldier_grid_finds_exactly_the_soldiers_along_a_ray() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 3
	var soldiers := _random_set(random)
	var grid := SoldierGrid.new(4)
	grid.rebuild(soldiers)
	for i in 300:
		var origin := Vector3(random.randf() * 200 - 100, 1, random.randf() * 200 - 100)
		var direction := Game.view_direction(random.randf() * 7, random.randf() * 2 - 1)
		if i % 50 == 0:
			direction = Vector3.UP
		var length := random.randf() * 150
		var margin := random.randf() * 10
		var want := {}
		var flat := sqrt(direction.x * direction.x + direction.z * direction.z)
		for soldier in soldiers.all():
			var dx := soldier.position.x - origin.x
			var dz := soldier.position.z - origin.z
			if flat > 1e-6:
				var along := clampf((dx * direction.x + dz * direction.z) / flat, 0, length * flat)
				dx -= direction.x / flat * along
				dz -= direction.z / flat * along
			if dx * dx + dz * dz <= margin * margin:
				want[soldier.id] = true
		var found := grid.along_ray(origin, direction, length, margin)
		var seen := {}
		for k in found:
			seen[grid.ids[k]] = true
		# Rounding at the very edge of the margin may go either way.
		for id in want:
			if not seen.has(id):
				var at := soldiers.get_soldier(id).position
				fail("ray %d from %s: missed 0x%04x at %s" % [i, origin, id, at])
				return
		for id in seen:
			if not want.has(id):
				fail("ray %d from %s: unexpected 0x%04x" % [i, origin, id])
				return


func test_soldier_set_reuses_slots_with_new_generations() -> void:
	var soldiers := SoldierSet.new(2)
	var first := soldiers.add(Soldier.new())
	var second := soldiers.add(Soldier.new())
	check_equal(soldiers.add(Soldier.new()), 0, "a soldier past the capacity")
	check(soldiers.remove(first), "removing a soldier")
	check(not soldiers.remove(first), "removing it twice")
	var again := soldiers.add(Soldier.new())
	check(SoldierSet.slot_of(again) == SoldierSet.slot_of(first) and again != first, "a reused slot keeps the identifier 0x%04x" % again)
	check(soldiers.get_soldier(first) == null and soldiers.get_soldier(again) != null and soldiers.get_soldier(second) != null,
		"a stale identifier still resolves")
	check_equal(soldiers.count(), 2, "count")
	# Generations run from 1 to 15 and wrap past zero.
	for i in 20:
		soldiers.remove(again)
		again = soldiers.add(Soldier.new())
		check(SoldierSet.generation_of(again) >= 1, "generation zero")
