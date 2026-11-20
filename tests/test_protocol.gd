extends TestCase
## The binary protocol: fields round trip, decoding is strict, records have
## the sizes the bandwidth budget counts on, and deltas resolve to the states
## sent.


func test_bits_round_trip() -> void:
	var w := BitWriter.new()
	w.write_bits(5, 3)
	w.write_signed(-3, 5)
	w.write_bool(true)
	w.write_u64(-7046029254386353131)
	w.write_float32(1.5)
	w.write_string("привет", 7)
	w.write_bits(0xFFFFFFFF, 32)
	var r := BitReader.new(w.bytes())
	check_equal(r.read_bits(3), 5, "bits")
	check_equal(r.read_signed(5), -3, "signed")
	check_equal(r.read_bool(), true, "bool")
	check_equal(r.read_u64(), -7046029254386353131, "u64")
	check_equal(r.read_float32(), 1.5, "float")
	check_equal(r.read_string(7, 64), "привет", "string")
	check_equal(r.read_bits(32), 0xFFFFFFFF, "32 bits")
	check_equal(r.finish(), "", "finish")


func test_strict_decoding() -> void:
	var hello := Messages.Hello.new()
	hello.protocol_version = Protocol.VERSION
	hello.name = "Alice"
	var data := Protocol.encode(hello)
	var longer := data.duplicate()
	longer.append(0)
	check_equal(Protocol.decode_into(Messages.Hello.new(), longer), BitReader.TRAILING_DATA, "trailing byte")
	var shorter := data.slice(0, data.size() - 1)
	check(Protocol.decode_into(Messages.Hello.new(), shorter) != "", "a short hello decodes")
	var padded := data.duplicate()
	padded[padded.size() - 1] |= 0x80
	check(Protocol.decode_into(Messages.Hello.new(), padded) != "", "nonzero padding decodes")
	var nan := BitWriter.new()
	nan.write_bits(0x7FC00000, 32)
	var reader := BitReader.new(nan.bytes())
	reader.read_float32()
	check_equal(reader.error, BitReader.INVALID_FLOAT, "NaN")
	var bad_utf8 := BitWriter.new()
	bad_utf8.write_bits(2, 6)
	bad_utf8.write_bits(0xC0, 8)
	bad_utf8.write_bits(0x80, 8)
	reader = BitReader.new(bad_utf8.bytes())
	reader.read_string(6, 32)
	check_equal(reader.error, BitReader.INVALID_TEXT, "overlong UTF-8")


func _messages() -> Array:
	var token := PackedByteArray()
	for i in 16:
		token.append(i * 7 + 1)
	var hello := Messages.Hello.new()
	hello.protocol_version = Protocol.VERSION
	hello.build = 123456789
	hello.name = "Игрок"
	hello.password = "secret"
	hello.token = token
	var welcome := Messages.Welcome.new()
	welcome.player = 15
	welcome.session_token = token
	welcome.tick_rate = 60
	welcome.snapshot_rate = 20
	welcome.server_tick = 0xFFFFFFF0
	welcome.map = "prototype"
	welcome.map_hash = -1
	welcome.tuning_hash = 42
	welcome.match_seed = -7723592293110705685
	var reject := Messages.Reject.new()
	reject.reason = Messages.Reject.Reason.FULL
	reject.message = "the server is full"
	var input := InputPacket.new()
	input.has_ack = true
	input.ack_sequence = 65535
	input.ack_bits = 0x80000001
	for i in 3:
		var command := InputCommand.create(1000 + i, 1, -1, 3.0, -0.5, InputCommand.FIRE | InputCommand.SPRINT)
		command.weapon = 2
		command.view_delta = 9
		command.view_frac = 200
		input.commands.append(command)
	var confirm := Messages.HitConfirm.new()
	confirm.tick = 77
	confirm.victim = SoldierSet.make_id(300, 2)
	confirm.zone = Hitboxes.Zone.HEAD
	confirm.damage = 50
	confirm.killed = true
	var damage := Messages.Damage.new()
	damage.tick = 78
	damage.attacker = SoldierSet.make_id(1, 15)
	damage.yaw = 255
	damage.zone = Hitboxes.Zone.LIMB
	damage.damage = 19
	var death := Messages.Death.new()
	death.tick = 79
	death.victim = SoldierSet.make_id(4, 1)
	death.killer = SoldierSet.make_id(5, 3)
	death.victim_team = Game.Team.RED
	death.killer_team = Game.Team.BLUE
	death.victim_name = "Rook 4"
	death.killer_name = "Alice"
	death.weapon = WeaponTuning.Kind.RIFLE
	death.zone = Hitboxes.Zone.TORSO
	var certificate := Messages.Certificate.new()
	certificate.pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
	var launch := Messages.Launch.new()
	launch.tick = 4400
	launch.projectile = 65535
	launch.kind = WeaponTuning.Kind.GRENADE
	launch.owner = SoldierSet.make_id(9, 2)
	launch.position = Vector3(-40.5, 2.25, 30.125)
	launch.velocity = Vector3(3.5, 6.0, -15.25)
	var blast := Messages.Blast.new()
	blast.tick = 4568
	blast.projectile = 65535
	blast.kind = WeaponTuning.Kind.GRENADE
	blast.position = Vector3(-38.0, 0.95, 18.5)
	return [hello, welcome, reject, Messages.Ready.new(), Messages.Respawn.new(), input, confirm, damage, death,
		Messages.CertificateRequest.new(), certificate, _snapshot(), launch, blast]


func _snapshot() -> Snapshot:
	var snapshot := Snapshot.new()
	snapshot.sequence = 513
	snapshot.server_tick = 9000
	var player := snapshot.player
	player.processed = true
	player.last_processed_tick = 8998
	player.input_lead = 2
	player.soldier = SoldierSet.make_id(0, 1)
	player.position = Vector3(1.25, 0.5, -3.75)
	player.velocity = Vector3(0, -0.5, 8)
	player.health = 0
	player.respawn = 120
	player.arsenal = Arsenal.create(Arsenal.default_loadout(), WeaponSet.create_default())
	player.arsenal.action = Arsenal.Action.RELOADING
	player.arsenal.action_ticks = 30
	player.arsenal.bloom = 0.01
	for soldier in _soldiers():
		snapshot.soldiers.append(SoldierRecord.create(SoldierState.create(soldier), null, 0))
	snapshot.removed = PackedInt32Array([SoldierSet.make_id(40, 2)])
	return snapshot


func _soldiers() -> Array[Soldier]:
	var list: Array[Soldier] = []
	for i in 3:
		var soldier := Soldier.new()
		soldier.id = SoldierSet.make_id(i * 9 + 1, 1 + i)
		soldier.team = Game.Team.BLUE if i % 2 == 0 else Game.Team.RED
		soldier.controller = Game.Controller.BOT if i > 0 else Game.Controller.PLAYER
		soldier.alive = i != 2
		soldier.grounded = true
		soldier.position = Vector3(10.5 * i - 3, 0.25 * i, -7.125 + i)
		soldier.velocity = Vector3(4.5, 0, -1.25 * i)
		soldier.yaw = 0.7 * i
		soldier.pitch = -0.2
		soldier.arsenal = Arsenal.holding(WeaponTuning.Kind.PISTOL)
		soldier.shots = 17
		soldier.hit_count = 9
		soldier.hit_box = 6
		soldier.hit_yaw = 2.0
		list.append(soldier)
	return list


func test_messages_round_trip() -> void:
	for message in _messages():
		var data := Protocol.encode(message)
		if not check(not data.is_empty(), "%s does not encode" % Protocol.type_name(message.type())):
			continue
		var decoded: Variant = Protocol.decode(data)
		if not check(decoded is Object, "%s does not decode: %s" % [Protocol.type_name(message.type()), str(decoded)]):
			continue
		check_equal(Protocol.encode(decoded), data, "%s encodes back" % Protocol.type_name(message.type()))


## A message that decodes encodes back to the same bytes, and garbage never
## breaks the decoder: corrupted messages are decoded and checked.
func test_fuzz_decoding() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 7
	var seeds: Array[PackedByteArray] = []
	for message in _messages():
		seeds.append(Protocol.encode(message))
	var decoded := 0
	for round in 3000:
		var data: PackedByteArray = seeds[random.randi_range(0, seeds.size() - 1)].duplicate()
		for flips in random.randi_range(1, 4):
			match random.randi_range(0, 2):
				0:
					var at := random.randi_range(0, data.size() - 1)
					data[at] ^= 1 << random.randi_range(0, 7)
				1:
					data.resize(maxi(1, data.size() - random.randi_range(1, 3)))
				2:
					data.append(random.randi_range(0, 255))
		var message: Variant = Protocol.decode(data)
		if message is Object:
			decoded += 1
			check_equal(Protocol.encode(message), data, "decoded %s encodes back" % Protocol.type_name(message.type()))
	check(decoded > 100, "only %d corrupted messages decoded; the fuzzing does not reach deep" % decoded)


## The sizes of records that the architecture counts on (6.6).
func test_record_sizes() -> void:
	var soldiers := _soldiers()
	var human := SoldierRecord.create(SoldierState.create(soldiers[0]), null, 0)
	var bot := SoldierRecord.create(SoldierState.create(soldiers[1]), null, 0)
	check_equal(SoldierRecord.slot_bits(0) + human.body_bits(), 166, "full record of a human")
	check_equal(SoldierRecord.slot_bits(0) + bot.body_bits(), 138, "full record of a bot")
	var standing := SoldierRecord.create(bot.state, bot.state.copy(), 1)
	check_equal(SoldierRecord.slot_bits(0) + standing.body_bits(), 25, "delta of a standing bot")
	var moved_soldier := soldiers[1].copy()
	moved_soldier.position += Vector3(1, 0, 0)
	var moved := SoldierRecord.create(SoldierState.create(moved_soldier), bot.state, 1)
	check(moved.fields == SoldierRecord.FIELD_MOVE, "a bot that walked a metre carries only its move: fields %d" % moved.fields)


func test_deltas_resolve_to_the_state_sent() -> void:
	var soldiers := _soldiers()
	var baselines := Baselines.new()
	var base := SoldierState.create(soldiers[0])
	baselines.store(10, base)
	var later := soldiers[0].copy()
	later.position += Vector3(0.3, 0.1, -40)
	later.yaw += 0.5
	later.shots += 1
	var state := SoldierState.create(later)
	var record := SoldierRecord.create(state, base, 3)
	check(record.base == 3 and record.fields & SoldierRecord.FIELD_MOVE != 0, "a delta with a move: base %d fields %d" % [record.base, record.fields])
	var resolved: Variant = baselines.resolve(13, record)
	check(resolved is SoldierState and resolved.equals(state), "the delta resolves to %s" % str(resolved))
	var far := later.copy()
	far.position = Vector3(1500, 0, 0)
	var jumped := SoldierRecord.create(SoldierState.create(far), base, 3)
	check_equal(jumped.fields & (SoldierRecord.FIELD_POSITION | SoldierRecord.FIELD_MOVE), SoldierRecord.FIELD_POSITION, "a long jump carries the position")
	var missing: Variant = baselines.resolve(14, record)
	check(missing is String, "a delta on a base never received resolves")


func test_baselines_keep_the_newest() -> void:
	var baselines := Baselines.new()
	var state := SoldierState.create(_soldiers()[0])
	for sequence in [65530, 65531, 65532, 65533, 65534, 65535, 0, 1, 2]:
		baselines.store(sequence, state)
	var record := SoldierRecord.create(state, state, 1)
	check(baselines.resolve(3, record) is SoldierState, "the newest base, across the wrap, is kept")
	record.base = 9
	check(baselines.resolve(3, record) is String, "the oldest base, past the history, is forgotten")


func test_packer_counts_exact_sizes() -> void:
	var snapshot := _snapshot()
	var records := snapshot.soldiers.duplicate()
	var packer := SnapshotPacker.new()
	packer.reset(snapshot, Snapshot.BUDGET)
	records.reverse()
	var base := SoldierState.create(_soldiers()[1])
	for record in records:
		check(packer.add(record.state, base, 2), "a record does not fit an empty datagram")
	var size := packer.finish()
	var data := Protocol.encode(snapshot)
	check_equal(data.size(), size, "packed size")
	var decoded := Snapshot.new()
	check_equal(Protocol.decode_into(decoded, data), "", "the packed snapshot decodes")
	var baselines := Baselines.new()
	baselines.store((snapshot.sequence - 2) & 0xFFFF, base)
	for i in decoded.soldiers.size():
		var resolved: Variant = baselines.resolve(snapshot.sequence, decoded.soldiers[i])
		check(resolved is SoldierState and resolved.equals(snapshot.out_states[i]), "soldier %d resolves to what was packed" % i)
	packer.reset(snapshot, 20)
	check(not packer.add(records[0].state, null, 0), "a record fits 20 bytes with the player state")
