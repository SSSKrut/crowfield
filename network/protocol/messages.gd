class_name Messages
## Messages are the small messages of the protocol: the handshake on the
## control channel, and the events of combat, which go on the reliable events
## channel only to the players they concern (ARCHITECTURE.md, 6.3): every
## client sees hits and deaths of all soldiers from the snapshots, and the
## events add what only the people involved need, and what a kill feed needs.


## Hello is the first message of a client on the control channel.
class Hello:
	var protocol_version := 0
	var build := 0
	var name := ""
	var password := ""
	## token is the session token of a player returning after a lost
	## connection; empty for a new player.
	var token := PackedByteArray()

	func type() -> int:
		return Protocol.Type.HELLO

	func write(w: BitWriter) -> String:
		var error := Protocol.check_text("name", name, Protocol.MAX_NAME_BYTES)
		if error == "":
			error = Protocol.check_text("password", password, Protocol.MAX_PASSWORD_BYTES)
		if error == "" and not token.is_empty() and (token.size() != 16 or token.count(0) == 16):
			error = "a token has 16 bytes, not all zero"
		if error != "":
			return error
		w.write_bits(protocol_version, 16)
		w.write_u64(build)
		w.write_string(name, Protocol.NAME_LENGTH_BITS)
		w.write_string(password, Protocol.PASSWORD_LENGTH_BITS)
		w.write_bool(not token.is_empty())
		if not token.is_empty():
			w.write_bytes(token)
		return ""

	func read(r: BitReader) -> void:
		protocol_version = r.read_bits(16)
		build = r.read_u64()
		name = r.read_string(Protocol.NAME_LENGTH_BITS, Protocol.MAX_NAME_BYTES)
		password = r.read_string(Protocol.PASSWORD_LENGTH_BITS, Protocol.MAX_PASSWORD_BYTES)
		token = PackedByteArray()
		if r.read_bool():
			token = r.read_bytes(16)
			if r.error == "" and token.count(0) == 16:
				r.fail("a zero token is written as none")


## Welcome accepts a client. The client must refuse to play when the tick
## rate, map hash or tuning hash differ from its own: its prediction would not
## match.
class Welcome:
	var player := 0
	var session_token := PackedByteArray()
	var tick_rate := 0
	## snapshot_rate tells the client how far apart snapshots are, which sets
	## its interpolation delay.
	var snapshot_rate := 0
	var server_tick := 0
	var map := ""
	var map_hash := 0
	var tuning_hash := 0
	var match_seed := 0

	func type() -> int:
		return Protocol.Type.WELCOME

	func write(w: BitWriter) -> String:
		if player < 0 or player >= Game.MAX_PLAYERS:
			return "player %d is out of range" % player
		if session_token.size() != 16:
			return "a session token has 16 bytes"
		var error := Protocol.check_text("map", map, Protocol.MAX_MAP_BYTES)
		if error != "":
			return error
		w.write_bits(player, Protocol.PLAYER_BITS)
		w.write_bytes(session_token)
		w.write_bits(tick_rate, 8)
		w.write_bits(snapshot_rate, 8)
		w.write_bits(server_tick, 32)
		w.write_string(map, Protocol.MAP_LENGTH_BITS)
		w.write_u64(map_hash)
		w.write_u64(tuning_hash)
		w.write_u64(match_seed)
		return ""

	func read(r: BitReader) -> void:
		player = r.read_bits(Protocol.PLAYER_BITS)
		session_token = r.read_bytes(16)
		tick_rate = r.read_bits(8)
		snapshot_rate = r.read_bits(8)
		server_tick = r.read_bits(32)
		map = r.read_string(Protocol.MAP_LENGTH_BITS, Protocol.MAX_MAP_BYTES)
		map_hash = r.read_u64()
		tuning_hash = r.read_u64()
		match_seed = r.read_u64()


## Reject refuses a client; message is shown to the player.
class Reject:
	enum Reason { VERSION = 1, FULL, PASSWORD, BAD_REQUEST }
	const REASON_NAMES := {1: "incompatible version", 2: "server is full", 3: "wrong password", 4: "bad request"}

	var reason := 0
	var message := ""

	func type() -> int:
		return Protocol.Type.REJECT

	func reason_name() -> String:
		return REASON_NAMES.get(reason, "reject reason %d" % reason)

	func write(w: BitWriter) -> String:
		var error := Protocol.check_text("reject message", message, Protocol.MAX_REJECT_MESSAGE_BYTES)
		if error != "":
			return error
		w.write_bits(reason, 8)
		w.write_string(message, Protocol.REJECT_LENGTH_BITS)
		return ""

	func read(r: BitReader) -> void:
		reason = r.read_bits(8)
		message = r.read_string(Protocol.REJECT_LENGTH_BITS, Protocol.MAX_REJECT_MESSAGE_BYTES)


## Ready tells the server that the client has loaded the map and can spawn.
class Ready:
	func type() -> int:
		return Protocol.Type.READY

	func write(_w: BitWriter) -> String:
		return ""

	func read(_r: BitReader) -> void:
		pass


## Respawn asks the server to place the player's soldier at a spawn point
## again, a debug aid of solo play.
class Respawn:
	func type() -> int:
		return Protocol.Type.RESPAWN

	func write(_w: BitWriter) -> String:
		return ""

	func read(_r: BitReader) -> void:
		pass


## CertificateRequest asks a server for its certificate before anything else;
## the server answers with Certificate and closes the connection. A client
## that has not met the server learns the certificate it then pins
## (ARCHITECTURE.md, 6.11).
class CertificateRequest:
	func type() -> int:
		return Protocol.Type.CERTIFICATE_REQUEST

	func write(_w: BitWriter) -> String:
		return ""

	func read(_r: BitReader) -> void:
		pass


class Certificate:
	const MAX_BYTES := 8192
	## pem is the certificate of the server, PEM encoded.
	var pem := ""

	func type() -> int:
		return Protocol.Type.CERTIFICATE

	func write(w: BitWriter) -> String:
		var error := Protocol.check_text("certificate", pem, MAX_BYTES)
		if error != "":
			return error
		w.write_string(pem, 14)
		return ""

	func read(r: BitReader) -> void:
		pem = r.read_string(14, MAX_BYTES)


## HitConfirm tells a shooter that its shot hurt a soldier, for the hit
## marker; killed when the shot killed it.
class HitConfirm:
	var tick := 0
	var victim := 0
	var zone := 0
	var damage := 0
	var killed := false

	func type() -> int:
		return Protocol.Type.HIT_CONFIRM

	func write(w: BitWriter) -> String:
		var error := Protocol.check_soldier("victim", victim)
		if error != "":
			return error
		if zone < 0 or zone >= 1 << Protocol.ZONE_BITS:
			return "unknown zone %d" % zone
		w.write_bits(tick, 32)
		w.write_bits(victim, 16)
		w.write_bits(zone, Protocol.ZONE_BITS)
		w.write_bits(damage, 8)
		w.write_bool(killed)
		return ""

	func read(r: BitReader) -> void:
		tick = r.read_bits(32)
		victim = Protocol.read_soldier(r)
		zone = r.read_bits(Protocol.ZONE_BITS)
		damage = r.read_bits(8)
		killed = r.read_bool()


## Damage tells a player that its soldier was hurt: by whom, and from where,
## as the yaw the shot travelled along, in 256 steps of a turn.
class Damage:
	var tick := 0
	var attacker := 0
	var yaw := 0
	var zone := 0
	var damage := 0

	func type() -> int:
		return Protocol.Type.DAMAGE

	func write(w: BitWriter) -> String:
		var error := Protocol.check_soldier("attacker", attacker)
		if error != "":
			return error
		if zone < 0 or zone >= 1 << Protocol.ZONE_BITS:
			return "unknown zone %d" % zone
		w.write_bits(tick, 32)
		w.write_bits(attacker, 16)
		w.write_bits(yaw, 8)
		w.write_bits(zone, Protocol.ZONE_BITS)
		w.write_bits(damage, 8)
		return ""

	func read(r: BitReader) -> void:
		tick = r.read_bits(32)
		attacker = Protocol.read_soldier(r)
		yaw = r.read_bits(8)
		zone = r.read_bits(Protocol.ZONE_BITS)
		damage = r.read_bits(8)


## Death tells every player of a death a human took part in, for the kill
## feed and the death screen. Names come with it: clients know soldiers, not
## whose they are.
class Death:
	var tick := 0
	var victim := 0
	var killer := 0
	var victim_team := 0
	var killer_team := 0
	var victim_name := ""
	var killer_name := ""
	var weapon := 0
	var zone := 0

	func type() -> int:
		return Protocol.Type.DEATH

	func write(w: BitWriter) -> String:
		for error in [
			Protocol.check_soldier("victim", victim), Protocol.check_soldier("killer", killer),
			Protocol.check_text("victim name", victim_name, Protocol.MAX_NAME_BYTES),
			Protocol.check_text("killer name", killer_name, Protocol.MAX_NAME_BYTES),
		]:
			if error != "":
				return error
		if victim_team > Game.Team.RED or killer_team > Game.Team.RED or weapon >= 1 << Protocol.WEAPON_BITS or zone >= 1 << Protocol.ZONE_BITS:
			return "death with a team, weapon or zone out of range"
		w.write_bits(tick, 32)
		w.write_bits(victim, 16)
		w.write_bits(killer, 16)
		w.write_bits(victim_team, Protocol.TEAM_BITS)
		w.write_bits(killer_team, Protocol.TEAM_BITS)
		w.write_string(victim_name, Protocol.NAME_LENGTH_BITS)
		w.write_string(killer_name, Protocol.NAME_LENGTH_BITS)
		w.write_bits(weapon, Protocol.WEAPON_BITS)
		w.write_bits(zone, Protocol.ZONE_BITS)
		return ""

	func read(r: BitReader) -> void:
		tick = r.read_bits(32)
		victim = Protocol.read_soldier(r)
		killer = Protocol.read_soldier(r)
		victim_team = r.read_bits(Protocol.TEAM_BITS)
		killer_team = r.read_bits(Protocol.TEAM_BITS)
		if r.error == "" and (victim_team > Game.Team.RED or killer_team > Game.Team.RED):
			r.fail("unknown team")
		victim_name = r.read_string(Protocol.NAME_LENGTH_BITS, Protocol.MAX_NAME_BYTES)
		killer_name = r.read_string(Protocol.NAME_LENGTH_BITS, Protocol.MAX_NAME_BYTES)
		weapon = r.read_bits(Protocol.WEAPON_BITS)
		zone = r.read_bits(Protocol.ZONE_BITS)
