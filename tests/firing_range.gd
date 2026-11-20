extends "res://tests/harness.gd"
## FiringRange is a server with one player, the shooter, whose assault rifle
## neither scatters nor kicks, and bots placed by hand as targets. Commands of
## the shooter go straight into its input buffer, as forged by any client.

var shooter: ServerPlayer
var client: Client


func _init(configure: Callable = Callable()) -> void:
	var rules := Rules.new()
	var rifle := rules.weapons.assault_rifle
	rifle.hip_spread = 0
	rifle.move_spread = 0
	rifle.bloom = 0
	rifle.kick_pitch = 0
	rifle.kick_yaw = 0
	super(func(settings: ServerSettings) -> void:
		# Places of players that never join leave slots for the targets. The
		# shooter sends no datagrams: its commands come straight.
		settings.max_players = 4
		settings.snapshot_rate = 20
		settings.input_timeout = 1e6
		if configure.is_valid():
			configure.call(settings), rules)
	client = join("shooter")
	shooter = player(client)
	step(10)


## target puts a bot soldier of a team on the range.
func target(team: int, position: Vector3) -> int:
	var soldier := Soldier.new()
	soldier.team = team
	soldier.controller = Game.Controller.BOT
	soldier.bot = 999
	soldier.alive = true
	soldier.grounded = true
	soldier.position = position
	soldier.health = Game.MAX_HEALTH
	soldier.arsenal = Arsenal.create(Arsenal.default_loadout(), server.rules.weapons)
	return server.soldiers.add(soldier)


func health(id: int) -> int:
	return server.soldiers.get_soldier(id).health


func shooter_soldier() -> Soldier:
	return server.soldiers.get_soldier(shooter.soldier)


## aim returns the yaw and pitch from the shooter's eye to a point.
func aim(at: Vector3) -> Vector2:
	var eye := shooter_soldier().position + Vector3(0, server.rules.movement.eye_height, 0)
	var to := at - eye
	return Vector2(atan2(to.x, -to.z), atan2(to.y, Vector2(to.x, to.z).length()))


## fire shoots once at a point by a player who saw the world back ticks before
## its command, and waits for the weapon to be ready again.
func fire(at: Vector3, back: int = 0) -> void:
	var angles := aim(at)
	var command := InputCommand.create(server.tick, 0, 0, angles.x, angles.y, InputCommand.FIRE)
	command.view_delta = back
	shooter.put_input(command, server.tick)
	# The trigger is released at the next tick: without a command the server
	# repeats the last one, and an assault rifle would keep firing.
	shooter.put_input(InputCommand.create(server.tick + 1, 0, 0, angles.x, angles.y, 0), server.tick)
	if back > 0:
		step(1)
		shooter_soldier().arsenal.cooldown = 0
	else:
		step(server.rules.weapons.assault_rifle.fire_interval())


## forge queues a command for the shooter's coming tick and runs it.
func forge(command: InputCommand) -> void:
	command.tick = server.tick
	shooter.put_input(command, server.tick)
	step(1)


## forged makes a command with the raw fields a client may send.
static func forged(buttons: int = 0, weapon: int = 0, pitch: int = 8000, forward: int = 0, right: int = 0) -> InputCommand:
	var command := InputCommand.new()
	command.buttons = buttons
	command.weapon = weapon
	command.pitch = pitch
	command.move_forward = forward
	command.move_right = right
	return command
